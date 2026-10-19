//! A whole-campaign backup: an independent deep copy of a `GameState` that
//! the multi-day advance commands restore when they fail, because no
//! preparation can undo a day already committed, and that `create_commander`
//! restores when a step after the commander's creation fails (engineering
//! contract rule 11's rollback fallback, ARCHITECTURE.md §4). No MekHQ
//! counterpart is mapped (docs/mekhq-map.md).
//!
//! The copy covers the type set the golden-master digest accepts
//! (`digest.update`): scalars, enums, optionals, arrays, slices, lists,
//! array hash maps, hash maps, tagged unions and structs. Any other shape in
//! a persisted or derived field, and any session or scratch field `take`
//! does not handle by name, is a compile error, so a new field can be
//! neither shared with the live campaign nor dropped.

const std = @import("std");
const GameState = @import("state.zig").GameState;
const digest = @import("digest.zig");

/// An independent deep copy of `gs`, in a fresh arena over the campaign's
/// backing allocator. It shares no memory with `gs`, so it stays valid while
/// `gs` replaces or destroys its lifecycle arenas. RNG words, `next_*_id`
/// counters and every persisted field are copied exactly; the copy owns no
/// lifecycle arena and keeps `campaign_id`. Reads `gs` only. On
/// `OutOfMemory` the partial copy is freed. The caller hands the backup to
/// exactly one of `restore` or `discard`.
pub fn take(gs: *const GameState) error{OutOfMemory}!GameState {
    var backup: GameState = undefined;
    backup.arena = std.heap.ArenaAllocator.init(gs.arena.child_allocator);
    errdefer backup.arena.deinit();
    const al = backup.arena.allocator();
    inline for (@typeInfo(GameState).@"struct".fields) |f| {
        switch (comptime persistenceOf(f.name)) {
            .persisted, .derived => @field(backup, f.name) = try copy(al, @field(gs, f.name)),
            .session, .scratch => if (comptime std.mem.eql(u8, f.name, "arena")) {
                // Initialized above: the backup's own memory.
            } else if (comptime std.mem.eql(u8, f.name, "lifecycle_arena") or
                std.mem.eql(u8, f.name, "faction_roster_lifecycle_arena") or
                std.mem.eql(u8, f.name, "merc_company_roster_lifecycle_arena"))
            {
                // Everything the live lifecycle arenas own is copied into `arena`.
                @field(backup, f.name) = null;
            } else if (comptime std.mem.eql(u8, f.name, "campaign_id")) {
                backup.campaign_id = gs.campaign_id;
            } else @compileError("campaign_backup.take does not handle session or scratch field GameState." ++ f.name),
        }
    }
    return backup;
}

fn persistenceOf(comptime name: []const u8) GameState.Persistence {
    @setEvalBranchQuota(20_000);
    return GameState.persistenceOf(name);
}

/// Replace the live campaign with `backup`, which the caller gives up. The
/// live campaign's arena and lifecycle arenas are freed, so no pointer into
/// the campaign taken before the restore stays valid; `gs` keeps its
/// address. Cannot fail.
pub fn restore(gs: *GameState, backup: GameState) void {
    gs.deinit();
    gs.* = backup;
}

/// Free a backup that is no longer needed.
pub fn discard(backup: *GameState) void {
    backup.deinit();
}

/// A deep copy of `value` allocated from `al`. Array hash maps keep their
/// insertion order, which is gameplay order (rule 2).
fn copy(al: std.mem.Allocator, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => return value,
        .optional => return if (value) |v| try copy(al, v) else null,
        .array => {
            var out: T = undefined;
            for (&out, value) |*o, v| o.* = try copy(al, v);
            return out;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                const out = if (comptime p.sentinel()) |s| try al.allocSentinel(p.child, value.len, s) else try al.alloc(p.child, value.len);
                if (p.child == u8) {
                    @memcpy(out, value);
                } else for (out, value) |*o, v| {
                    o.* = try copy(al, v);
                }
                return out;
            },
            else => @compileError("campaign_backup: no deep copy for pointer type " ++ @typeName(T)),
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("campaign_backup: untagged union " ++ @typeName(T));
            return switch (value) {
                inline else => |payload, tag| @unionInit(T, @tagName(tag), try copy(al, payload)),
            };
        },
        .@"struct" => |s| {
            if (comptime digest.isArrayHashMap(T)) {
                var out = try value.clone(al);
                for (out.keys()) |*k| k.* = try copy(al, k.*);
                for (out.values()) |*v| v.* = try copy(al, v.*);
                return out;
            }
            if (comptime digest.isHashMap(T)) {
                var out = try value.clone(al);
                var it = out.iterator();
                while (it.next()) |e| {
                    e.key_ptr.* = try copy(al, e.key_ptr.*);
                    e.value_ptr.* = try copy(al, e.value_ptr.*);
                }
                return out;
            }
            if (comptime digest.isArrayList(T)) {
                const items = try copy(al, value.items);
                return .{ .items = items, .capacity = items.len };
            }
            if (T == std.mem.Allocator) @compileError("campaign_backup: an allocator is not state");
            var out: T = undefined;
            inline for (s.fields) |f| @field(out, f.name) = try copy(al, @field(value, f.name));
            return out;
        },
        else => @compileError("campaign_backup: unsupported type " ++ @typeName(T)),
    }
}

/// A campaign with people and their skill maps, units with slots, forces,
/// HQs, a contract, offers, roster maps owned by lifecycle arenas, logs and
/// ledgers, a battle in progress and a battle report with its phases.
fn richCampaignForTest(gs: *GameState) !void {
    const founding = @import("founding.zig");
    const commands = @import("commands.zig");
    const contract_market = @import("contract_market.zig");
    const tick = @import("tick.zig");
    const phase = @import("../domain/battle_phase.zig");
    _ = try founding.createCommander(gs, "T", .LC, .paymaster);
    const co = try @import("starter_company.zig").generateInto(gs, "Alpha");
    _ = try contract_market.worldForTest(gs);
    // Month by month until a contract is taken and a monthly pass has
    // installed the roster maps' lifecycle arena.
    var accepted = false;
    for (0..24) |_| {
        if (!accepted) for (gs.contract_offers.items) |*offer| if (contract_market.offerEligible(gs, offer, co)) {
            _ = try commands.execute(gs, .{ .accept_contract = .{ .offer = offer.id, .company = co } });
            accepted = true;
            break;
        };
        if (accepted and gs.faction_roster_lifecycle_arena != null) break;
        try tick.advanceReading(gs, 30);
    }
    var steps: std.ArrayListUnmanaged(phase.Step) = .empty;
    try steps.append(gs.allocator(), .{ .order = .engage, .report = .{ .pause = .contact, .margin = 1, .hits = 1, .momentum = 0, .roe = .standard, .odds = .{ .counts = .{ 1, 1, 1, 1, 0 }, .total = 4 } } });
    try gs.battles_in_progress.append(gs.allocator(), .{ .contract = @enumFromInt(1), .phase = .contact, .steps = steps });
    const records = try gs.allocator().dupe(phase.PhaseRecord, &.{.{ .phase = .contact, .order = .engage, .roe = .standard }});
    try gs.battle_reports.record(gs.allocator(), .{ .id = @enumFromInt(gs.next_battle_id), .day = gs.clock.day_index, .contract = .none, .company = co, .kind = "objective_raid", .enemy_key = "DC", .scenario = "breakthrough", .terrain = "grasslands", .weather = "clear", .outcome = .victory, .phases = records });
    gs.next_battle_id += 1;
    gs.campaign_id = 7;
}

test "a backup digest-equals the campaign it copies and owns no lifecycle arena" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4200 });
    defer gs.deinit();
    try richCampaignForTest(&gs);
    try std.testing.expect(gs.people.count() > 1 and gs.units.count() > 0 and gs.contracts.count() > 0);
    try std.testing.expect(gs.units.values()[0].slots.items.len > 0);
    try std.testing.expect(gs.faction_rosters.count() > 0 and gs.faction_roster_lifecycle_arena != null);
    try std.testing.expect(gs.event_log.items.len > 0 and gs.ledger.transactions.items.len > 0);
    var backup = try take(&gs);
    defer discard(&backup);
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&backup));
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), digest.firstStateDifference(&gs, &backup, &buf));
    try std.testing.expectEqual(gs.campaign_id, backup.campaign_id);
    try std.testing.expect(backup.lifecycle_arena == null and backup.faction_roster_lifecycle_arena == null and backup.merc_company_roster_lifecycle_arena == null);
    // Independent storage: a change to the copy does not reach the campaign.
    try std.testing.expect(backup.event_log.items.ptr != gs.event_log.items.ptr);
    backup.event_log.items[0].day += 1;
    try std.testing.expect(digest.stateHash(&gs) != digest.stateHash(&backup));
}

test "a backup stays intact while the campaign replaces its lifecycle arenas, and restores to that state" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4200 });
    defer gs.deinit();
    try richCampaignForTest(&gs);
    gs.battles_in_progress.clearRetainingCapacity();
    const taken = digest.stateHash(&gs);
    var backup = try take(&gs);
    // Free the memory behind the live roster maps, as a monthly pass does
    // once it has installed their replacements. Reading the backup's
    // digest walks every roster it copied.
    try std.testing.expect(gs.faction_roster_lifecycle_arena != null);
    gs.replaceFactionRosterLifecycleArena(try gs.lifecycleArena());
    gs.replaceLifecycleArena(try gs.lifecycleArena());
    gs.releaseMercCompanyRosterLifecycleArena();
    try std.testing.expectEqual(taken, digest.stateHash(&backup));
    restore(&gs, backup);
    try std.testing.expectEqual(taken, digest.stateHash(&gs));
    // The restored campaign keeps playing on its own memory, through
    // monthly passes that install new lifecycle arenas.
    const day = gs.clock.day_index;
    try @import("tick.zig").advanceReading(&gs, 62);
    try std.testing.expect(gs.clock.day_index > day + 31);
}

test "a backup that runs out of memory frees what it copied and leaves the campaign unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4200 });
    defer gs.deinit();
    try richCampaignForTest(&gs);
    const before = digest.stateHash(&gs);
    const backing = gs.arena.child_allocator;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        const result = take(&gs);
        gs.arena.child_allocator = backing;
        if (result) |b| {
            var backup = b;
            discard(&backup);
            break;
        } else |err| try std.testing.expect(err == error.OutOfMemory);
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
    try std.testing.expect(fail_index > 0);
}
