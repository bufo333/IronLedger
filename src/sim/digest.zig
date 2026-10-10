//! A canonical digest of any plain value: every field, every element, every
//! map entry. `stateHash` feeds each persisted field of a campaign through
//! it, so a change to any saved number moves the golden master. MekHQ has
//! no counterpart (it has no determinism harness) (docs/mekhq-map.md).
//!
//! Canonical means independent of how the value was built: a slice or list
//! digests its length and then each element in order; a map (array hash
//! map or hash map) digests its length and the wrapping sum of one
//! sub-digest per entry, so a map rebuilt in another insertion order (as a
//! load does) digests the same. Pointers other than slices, allocators and untagged unions are
//! refused at compile time: none of them has a canonical value.

const std = @import("std");
const GameState = @import("state.zig").GameState;

const Hasher = std.hash.Wyhash;

/// A field the golden master covers: persisted or derived
/// (`GameState.field_persistence`); session and scratch fields cannot move it.
fn hashed(comptime name: []const u8) bool {
    @setEvalBranchQuota(20_000);
    return switch (GameState.persistenceOf(name)) {
        .persisted, .derived => true,
        .session, .scratch => false,
    };
}

test "artillery acquisition placement freight offers counters and catalogue all affect state hash" {
    const artillery = @import("artillery.zig");
    const founding = @import("founding.zig");
    const types = @import("../domain/types.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    const bought = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    const original = gs.artillery_formations.get(bought.artillery_formation).?;
    const hash = stateHash(&gs);
    const f = gs.artillery_formations.getPtr(bought.artillery_formation).?;
    f.paid_price += 1;
    try std.testing.expect(hash != stateHash(&gs));
    f.* = original;
    f.acquisition_day += 1;
    try std.testing.expect(hash != stateHash(&gs));
    f.* = original;
    f.hull = @enumFromInt(@intFromEnum(original.hull) + 1);
    try std.testing.expect(hash != stateHash(&gs));
    f.* = original;
    f.placement = .{ .company = @enumFromInt(1) };
    try std.testing.expect(hash != stateHash(&gs));
    const freight: @import("../domain/artillery_formation.zig").Freight = .{ .from_hq = home, .to_hq = @enumFromInt(2), .dispatch_day = 0, .eta_day = 3, .paid_cost = 10 };
    f.placement = .{ .freight = freight };
    const moving = stateHash(&gs);
    inline for (@typeInfo(@TypeOf(freight)).@"struct".fields) |field| {
        f.placement = .{ .freight = freight };
        const T = @TypeOf(@field(f.placement.freight, field.name));
        if (T == types.HqId) @field(f.placement.freight, field.name) = @enumFromInt(@intFromEnum(@field(freight, field.name)) + 1) else @field(f.placement.freight, field.name) += 1;
        try std.testing.expect(moving != stateHash(&gs));
    }
    f.* = original;
    gs.artillery_offers.items[0].available = true;
    try std.testing.expect(hash != stateHash(&gs));
    gs.artillery_offers.items[0].available = false;
    gs.next_artillery_offer_id += 1;
    try std.testing.expect(hash != stateHash(&gs));
    gs.next_artillery_offer_id -= 1;
    gs.next_artillery_formation_id += 1;
    try std.testing.expect(hash != stateHash(&gs));
    gs.next_artillery_formation_id -= 1;
    gs.hull_instances.getPtr(original.hull).?.catalogue = .chassis;
    try std.testing.expect(hash != stateHash(&gs));
}

/// The golden master: a digest of every persisted and derived field of a
/// campaign, RNG words and `next_*_id` counters included. Two runs with the
/// same seed and command script produce the same hash, and a save loads
/// back to the hash it was saved at (ARCH §13).
pub fn stateHash(gs: *const GameState) u64 {
    var h = Hasher.init(0x42544d43); // "BTMC"
    inline for (@typeInfo(GameState).@"struct".fields) |f| {
        if (comptime hashed(f.name)) {
            update(&h, f.name);
            update(&h, @field(gs, f.name));
        }
    }
    return h.final();
}

/// Test projection of campaigns without artillery combat, excluding only the
/// optional artillery report field introduced at format 63. Every other gameplay
/// field, identity and named RNG word remains covered by the base representation.
pub fn nonArtilleryReferenceHash(gs: *const GameState) u64 {
    std.debug.assert(@import("builtin").is_test);
    var h = Hasher.init(0x42544d43);
    inline for (@typeInfo(GameState).@"struct".fields) |f| {
        if (comptime hashed(f.name)) {
            update(&h, f.name);
            if (comptime std.mem.eql(u8, f.name, "battle_reports")) {
                update(&h, @as(u64, gs.battle_reports.kept.items.len));
                for (gs.battle_reports.kept.items) |r| {
                    std.debug.assert(r.artillery == null);
                    inline for (@typeInfo(@TypeOf(r)).@"struct".fields) |field| {
                        if (comptime !std.mem.eql(u8, field.name, "artillery")) update(&h, @field(r, field.name));
                    }
                }
            } else update(&h, @field(gs, f.name));
        }
    }
    return h.final();
}

/// The path to the first hashed value that differs between two campaigns
/// ("candidates[2].skills"), for a round-trip test to name what did not
/// survive; null when nothing does.
pub fn firstStateDifference(a: *const GameState, b: *const GameState, buf: []u8) ?[]const u8 {
    inline for (@typeInfo(GameState).@"struct".fields) |f| {
        if (comptime hashed(f.name)) {
            const name_len = @min(f.name.len, buf.len);
            @memcpy(buf[0..name_len], f.name[0..name_len]);
            if (firstDifference(buf[name_len..], @field(a, f.name), @field(b, f.name))) |rest| return buf[0 .. name_len + rest.len];
        }
    }
    return null;
}

pub fn update(h: *Hasher, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => h.update(&[_]u8{@intFromBool(value)}),
        .int, .float => {
            const v = value;
            h.update(std.mem.asBytes(&v));
        },
        .@"enum" => update(h, @intFromEnum(value)),
        .optional => if (value) |v| {
            h.update(&[_]u8{1});
            update(h, v);
        } else h.update(&[_]u8{0}),
        .array => for (value) |e| update(h, e),
        .pointer => |p| switch (p.size) {
            .slice => {
                update(h, @as(u64, value.len));
                if (p.child == u8) h.update(value) else for (value) |e| update(h, e);
            },
            else => @compileError("digest: no canonical value for pointer type " ++ @typeName(T)),
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("digest: untagged union " ++ @typeName(T));
            update(h, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| update(h, payload),
            }
        },
        .@"struct" => |s| {
            if (comptime isArrayHashMap(T)) return updateArrayHashMap(h, value);
            if (comptime isHashMap(T)) return updateMap(h, value);
            if (comptime isArrayList(T)) return update(h, value.items);
            if (T == std.mem.Allocator) @compileError("digest: an allocator is not state");
            inline for (s.fields) |f| update(h, @field(value, f.name));
        },
        else => @compileError("digest: unsupported type " ++ @typeName(T)),
    }
}

/// Order-independent fold for open-addressing hash maps (e.g. `AutoHashMapUnmanaged`).
/// Two maps with the same entries in any insertion order produce the same hash.
fn updateMap(h: *Hasher, map: anytype) void {
    update(h, @as(u64, map.count()));
    var sum: u64 = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        var e = Hasher.init(0);
        update(&e, entry.key_ptr.*);
        update(&e, entry.value_ptr.*);
        sum +%= e.final();
    }
    update(h, sum);
}

/// Ordered hash for array hash maps (e.g. `AutoArrayHashMapUnmanaged`,
/// `StringArrayHashMapUnmanaged`). Their iteration order is insertion order —
/// the order RNG, seating and collections consume — and is gameplay-significant
/// (rule 2, 53). Two maps with the same entries in a different insertion order
/// produce different hashes, so a digest distinguishes materially different
/// campaigns (rule 4 reviewer check).
fn updateArrayHashMap(h: *Hasher, map: anytype) void {
    update(h, @as(u64, map.count()));
    var it = map.iterator();
    while (it.next()) |entry| {
        update(h, entry.key_ptr.*);
        update(h, entry.value_ptr.*);
    }
}

/// Array hash maps (`AutoArrayHashMapUnmanaged`, `StringArrayHashMapUnmanaged`,
/// and their managed variants): have `KV`, `iterator`, and an `entries` field.
fn isArrayHashMap(comptime T: type) bool {
    return @hasDecl(T, "KV") and @hasDecl(T, "iterator") and @hasField(T, "entries");
}

/// Open-addressing hash maps (`AutoHashMapUnmanaged`, etc.): have `KV`,
/// `iterator`, and a `metadata` field (no `entries`).
fn isHashMap(comptime T: type) bool {
    return @hasDecl(T, "KV") and @hasDecl(T, "iterator") and @hasField(T, "metadata") and !@hasField(T, "entries");
}

fn isArrayList(comptime T: type) bool {
    return @hasField(T, "items") and @hasField(T, "capacity") and @typeInfo(T).@"struct".fields.len == 2;
}

/// The path to the first place two values of one type differ ("[3].name",
/// ".skills"), written into `buf`; null when they digest the same. It
/// descends structs, unions, optionals and equal-length slices, lists and
/// arrays, and stops at a map or at a length that differs.
pub fn firstDifference(buf: []u8, a: anytype, b: @TypeOf(a)) ?[]const u8 {
    if (of(a) == of(b)) return null;
    var w: std.Io.Writer = .fixed(buf);
    descend(&w, a, b);
    return w.buffered();
}

fn descend(w: *std.Io.Writer, a: anytype, b: @TypeOf(a)) void {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .optional => if (a != null and b != null) descend(w, a.?, b.?),
        .array => for (a, b, 0..) |x, y, i| if (of(x) != of(y)) {
            // best-effort: a diagnostic path in a fixed buffer truncates.
            w.print("[{d}]", .{i}) catch {};
            return descend(w, x, y);
        },
        .pointer => |p| if (p.size == .slice and p.child != u8 and a.len == b.len) {
            for (a, b, 0..) |x, y, i| if (of(x) != of(y)) {
                // best-effort: a diagnostic path in a fixed buffer truncates.
                w.print("[{d}]", .{i}) catch {};
                return descend(w, x, y);
            };
        },
        .@"union" => if (std.meta.activeTag(a) == std.meta.activeTag(b)) switch (a) {
            inline else => |x, tag| {
                // best-effort: a diagnostic path in a fixed buffer truncates.
                w.print(".{s}", .{@tagName(tag)}) catch {};
                descend(w, x, @field(b, @tagName(tag)));
            },
        },
        .@"struct" => |s| {
            if (comptime isHashMap(T)) return; // folded; can't descend into a fold
            if (comptime isArrayHashMap(T)) {
                // Ordered: descend into each entry by index for better diagnostics.
                if (a.count() != b.count()) return;
                var ia = a.iterator();
                var ib = b.iterator();
                var i: usize = 0;
                while (ia.next()) |ea| {
                    const eb = ib.next().?;
                    if (of(ea.key_ptr.*) != of(eb.key_ptr.*) or of(ea.value_ptr.*) != of(eb.value_ptr.*)) {
                        // best-effort: a diagnostic path in a fixed buffer truncates.
                        w.print("[{d}]", .{i}) catch {};
                        return;
                    }
                    i += 1;
                }
                return;
            }
            if (comptime isArrayList(T)) return descend(w, a.items, b.items);
            inline for (s.fields) |f| if (of(@field(a, f.name)) != of(@field(b, f.name))) {
                // best-effort: a diagnostic path in a fixed buffer truncates.
                w.print(".{s}", .{f.name}) catch {};
                return descend(w, @field(a, f.name), @field(b, f.name));
            };
        },
        else => {},
    }
}

fn of(value: anytype) u64 {
    var h = Hasher.init(0);
    update(&h, value);
    return h.final();
}

test "a session field cannot move the golden master; a persisted one does" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 45 });
    defer gs.deinit();
    const before = stateHash(&gs);
    gs.campaign_id = 99; // session: the store's row
    try std.testing.expectEqual(before, stateHash(&gs));
    gs.reputation += 1; // persisted
    try std.testing.expect(stateHash(&gs) != before);
    try std.testing.expectEqual(GameState.Persistence.session, comptime GameState.persistenceOf("campaign_id"));
}

test "an array hash map digests differently when insertion order differs" {
    // Array hash maps are gameplay-order-significant (rule 2, 53): two
    // campaigns that differ only in the order their id map was populated
    // are materially different and must produce different digests (rule 4).
    const a = std.testing.allocator;
    var one: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
    defer one.deinit(a);
    var two: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
    defer two.deinit(a);
    try one.put(a, 1, "alpha");
    try one.put(a, 2, "bravo");
    try two.put(a, 2, "bravo");
    try two.put(a, 1, "alpha");
    // Same entries, different insertion order → different digest.
    try std.testing.expect(of(one) != of(two));
    // A value change still moves the digest.
    var three: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
    defer three.deinit(a);
    try three.put(a, 1, "alpha");
    try three.put(a, 2, "charlie");
    try std.testing.expect(of(one) != of(three));
}

test "an open-addressing hash map digests the same regardless of insertion order" {
    // Plain hash maps (AutoHashMapUnmanaged) fold entries order-independently
    // because their insertion order is genuinely nondeterministic (e.g. Person.skills).
    const a = std.testing.allocator;
    var one: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer one.deinit(a);
    var two: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer two.deinit(a);
    try one.put(a, 1, 10);
    try one.put(a, 2, 20);
    try two.put(a, 2, 20);
    try two.put(a, 1, 10);
    // Same entries, different insertion order → same digest.
    try std.testing.expectEqual(of(one), of(two));
    // A value change still moves the digest.
    try two.put(a, 2, 99);
    try std.testing.expect(of(one) != of(two));
}

test "every field, element and string byte moves the digest" {
    const a = std.testing.allocator;
    const Row = struct { id: u16, name: []const u8, tag: ?enum { x, y }, pay: union(enum) { none, amount: i64 } };
    var list: std.ArrayListUnmanaged(Row) = .empty;
    defer list.deinit(a);
    try list.append(a, .{ .id = 1, .name = "Kell", .tag = .x, .pay = .{ .amount = 5 } });
    const base = of(list);
    list.items[0].name = "Kelm";
    try std.testing.expect(of(list) != base);
    list.items[0].name = "Kell";
    list.items[0].pay = .{ .amount = 6 };
    try std.testing.expect(of(list) != base);
    list.items[0].pay = .{ .amount = 5 };
    list.items[0].tag = null;
    try std.testing.expect(of(list) != base);
    list.items[0].tag = .x;
    try std.testing.expectEqual(base, of(list));
    var buf: [64]u8 = undefined;
    const other = [_]Row{ list.items[0], .{ .id = 2, .name = "Ryn", .tag = null, .pay = .none } };
    var changed = other;
    changed[1].name = "Rin";
    try std.testing.expectEqualStrings("[1].name", firstDifference(&buf, @as([]const Row, &other), @as([]const Row, &changed)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), firstDifference(&buf, @as([]const Row, &other), @as([]const Row, &other)));
    // Splitting one string into two is not the same value.
    try std.testing.expect(of([_][]const u8{ "ab", "c" }) != of([_][]const u8{ "a", "bc" }));
}

test "every archived HQ field and active archive membership affects the complete digest" {
    const founding = @import("founding.zig");
    const hq_ops = @import("hq_ops.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const id = try founding.foundHq(&gs, "Other", .regional, "skye");
    const live = gs.hqs.get(id).?;
    const active_hash = stateHash(&gs);
    try hq_ops.sellHq(&gs, id);
    const archived = gs.retired_hqs.get(id).?;
    const base = stateHash(&gs);
    try std.testing.expect(active_hash != base);
    const h = gs.retired_hqs.getPtr(id).?;
    h.id = @enumFromInt(@intFromEnum(id) + 1);
    try std.testing.expect(base != stateHash(&gs));
    h.* = archived;
    h.name = "Renamed";
    try std.testing.expect(base != stateHash(&gs));
    h.* = archived;
    h.planet_key = "galatea";
    try std.testing.expect(base != stateHash(&gs));
    h.* = archived;
    h.tier = .brigade;
    try std.testing.expect(base != stateHash(&gs));
    h.* = archived;
    h.sold_day += 1;
    try std.testing.expect(base != stateHash(&gs));
    _ = gs.retired_hqs.orderedRemove(id);
    try std.testing.expect(base != stateHash(&gs));
    try gs.hqs.put(gs.allocator(), id, live);
    try std.testing.expect(base != stateHash(&gs));
}

test "every artillery operational field checkpoint and bay target affects the complete digest" {
    const operations = @import("artillery_operations.zig");
    const rules = @import("../domain/artillery_operations.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.getPtr(id).?;
    const original = f.*;
    const baseline = stateHash(&gs);
    f.quality = .b;
    try std.testing.expect(baseline != stateHash(&gs));
    f.* = original;
    f.armor_pct -= 1;
    try std.testing.expect(baseline != stateHash(&gs));
    f.* = original;
    f.last_maintenance_day = 0;
    try std.testing.expect(baseline != stateHash(&gs));
    f.* = original;
    f.tech = .none;
    try std.testing.expect(baseline != stateHash(&gs));
    for (rules.seats, 0..) |_, i| {
        f.* = original;
        f.crew[i] = .none;
        try std.testing.expect(baseline != stateHash(&gs));
    }
    for (rules.descriptors, 0..) |d, i| {
        f.* = original;
        f.slots[i].condition = .damaged;
        try std.testing.expect(baseline != stateHash(&gs));
        if (d.family != null) {
            f.* = original;
            f.slots[i].rounds = 1;
            try std.testing.expect(baseline != stateHash(&gs));
        }
    }
    f.* = original;
    gs.last_artillery_service_day = 0;
    try std.testing.expect(baseline != stateHash(&gs));
    gs.last_artillery_service_day = null;
    try gs.bay_jobs.append(gs.allocator(), .{ .hq = gs.seat(), .kind = .artillery_depot_repair, .artillery = id, .duration_days = 1, .queued_day = 0 });
    const queued = stateHash(&gs);
    gs.bay_jobs.items[0].artillery = .none;
    try std.testing.expect(queued != stateHash(&gs));
}

test "captured artillery combat payload and terminal placement affect the complete digest" {
    const operations = @import("artillery_operations.zig");
    const battle = @import("artillery_battle.zig");
    const reports = @import("../domain/battle_report.zig");
    const contracts = @import("../domain/contract.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const c: contracts.Contract = .{ .id = @enumFromInt(1), .kind = .recon_raid, .assigned_company = gs.artillery_formations.get(id).?.placement.company, .employer_key = "LC", .enemy_key = "DC", .planet_key = gs.seatPlanetKey().?, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } };
    const a = (try battle.snapshot(&gs, &c, .no_line_units)).?;
    const r: reports.BattleReport = .{ .id = @enumFromInt(1), .day = 0, .contract = c.id, .company = c.assigned_company, .kind = "", .enemy_key = "DC", .scenario = "", .terrain = "", .weather = "", .outcome = .rout, .artillery = a };
    try gs.battle_reports.record(gs.allocator(), r);
    const baseline = stateHash(&gs);
    const captured = &gs.battle_reports.kept.items[0].artillery.?;
    captured.fired_rounds[0] = 1;
    try std.testing.expect(baseline != stateHash(&gs));
    captured.* = a;
    captured.accuracy_roll = 7;
    try std.testing.expect(baseline != stateHash(&gs));
    captured.* = a;
    captured.seats[0].name = "Changed snapshot";
    try std.testing.expect(baseline != stateHash(&gs));
    captured.* = a;
    captured.seats[0].outcome.fate = .missing;
    try std.testing.expect(baseline != stateHash(&gs));
    captured.* = a;
    captured.slots_after[0].condition = .destroyed;
    try std.testing.expect(baseline != stateHash(&gs));
    captured.* = a;
    captured.compensation_basis = 1;
    try std.testing.expect(baseline != stateHash(&gs));
    captured.* = a;
    gs.artillery_formations.getPtr(id).?.placement = .destroyed;
    try std.testing.expect(baseline != stateHash(&gs));
}
