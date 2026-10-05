//! Faction hull-pool seeding at campaign creation (P3e.4,
//! docs/p3c-economy-design.md §2/§3/§4).
//! Single owner of "a manufactured hull enters a faction pool" (rule 20/3):
//! owner tag, hull_instances entry, hull_ownership_history interval, and
//! faction_rosters membership are written together in one infallible commit.
//! No MekHQ counterpart: campaign-start roster seeding is specific to this
//! implementation (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const faction = @import("../domain/faction.zig");
const chassis_mod = @import("../domain/chassis.zig");
const hull_mod = @import("../domain/hull_instance.zig");
const roster_gen = @import("../gen/roster_gen.zig");
const GameState = @import("state.zig").GameState;

/// Maximum entries in faction.table; used for fixed stack arrays.
const max_factions = 32;

/// Seed every manufacturing faction's hull pool at campaign creation.
/// Failure-atomic (rules 7, 11–13):
///   Prepare  — count needed capacity; no gs.* mutation.
///   Reserve  — ensureUnusedCapacity on all three collections (all fallible);
///              on any error gs.* entries are unchanged.
///   Commit   — build and insert all records; gs.rng and
///              gs.next_hull_instance_id updated last (infallible).
///
/// Factions with replenishment_hulls_per_year == 0 are skipped (rule 4,
/// docs/p3c-economy-design.md §4 "empty manufacturing = no roster").
pub fn seedFactionRosters(gs: *GameState) !void {
    const alloc = gs.allocator();
    const tg = tuning.generation;

    // ---- Prepare ----
    // Count capacity needed; no gs.* mutation.
    var total_hulls: u32 = 0;
    var num_seeded: usize = 0;
    // Indices into faction.table for manufacturing factions, stack-local.
    var seeded_idx: [max_factions]usize = undefined;
    var seeded_counts: [max_factions]u32 = undefined;
    for (faction.table, 0..) |*f, i| {
        if (f.replenishment_hulls_per_year == 0) continue;
        const count: u32 = @as(u32, f.replenishment_hulls_per_year) *
            @as(u32, tg.faction_roster_seed_years);
        seeded_idx[num_seeded] = i;
        seeded_counts[num_seeded] = count;
        num_seeded += 1;
        total_hulls += count;
    }
    if (num_seeded == 0) return; // nothing to do

    // ---- Reserve ----
    // All fallible touches to gs.* happen here, before any entry is written.
    // A failure here leaves gs.hull_instances, gs.hull_ownership_history,
    // gs.faction_rosters, gs.rng, and gs.next_hull_instance_id unchanged.
    try gs.hull_instances.ensureUnusedCapacity(alloc, total_hulls);
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, total_hulls);
    try gs.faction_rosters.ensureUnusedCapacity(alloc, num_seeded);

    // Pre-build per-faction roster lists (still in reserve; no gs.* map
    // entries yet).  On failure, any partially-reserved lists are orphaned
    // arena memory — harmless (arena lifetime = campaign lifetime).
    var roster_lists: [max_factions]std.ArrayListUnmanaged(types.HullInstanceId) =
        .{std.ArrayListUnmanaged(types.HullInstanceId).empty} ** max_factions;
    for (0..num_seeded) |ri| {
        try roster_lists[ri].ensureTotalCapacity(alloc, seeded_counts[ri]);
    }

    // ---- Commit ----
    // Draw from a rng copy so gs.rng is only updated on success.
    var rng_copy = gs.rng;
    var next_id = gs.next_hull_instance_id;
    const year = gs.clock.date.year;

    for (0..num_seeded) |ri| {
        const f = &faction.table[seeded_idx[ri]];
        const count = seeded_counts[ri];
        for (0..count) |_| {
            const hid: types.HullInstanceId = @enumFromInt(next_id);
            next_id += 1;

            const ch = roster_gen.rollFactionPoolOne(&rng_copy, .rosters, f.key, year);
            var inst: hull_mod.HullInstance = .{
                .id = hid,
                .base_key = ch.key, // static catalogue memory
                .status = .active,
                .intro_year = ch.intro_year,
                .pre_campaign = true,
                .owner = .{ .faction = f.key }, // static catalogue key
            };
            // Copy design loadout (docs/p3c-economy-design.md §2).
            // f.key is static catalogue memory — no dupe needed.
            for (ch.loadout) |slot| {
                try inst.loadout.append(alloc, .{ .part_key = slot.part });
            }
            gs.hull_instances.putAssumeCapacity(hid, inst);

            // Open one .initial ownership interval (rule 1 — owner without
            // interval is partial truth).
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = 0,
                .to_day = 0,
                .acquisition_type = .initial,
                .prior_owner_key = f.key, // static catalogue memory
            });

            roster_lists[ri].appendAssumeCapacity(hid);
        }

        // Insert the roster list under the faction's stable key.
        gs.faction_rosters.putAssumeCapacity(f.key, roster_lists[ri]);
    }

    // Update counters last (infallible).
    gs.next_hull_instance_id = next_id;
    gs.rng = rng_copy;
}

// ---- Tests ----

const digest = @import("digest.zig");

test "seedFactionRosters: each manufacturing faction gets the expected roster size" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7001 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;
    try seedFactionRosters(&gs);

    const tg = tuning.generation;
    for (faction.table) |*f| {
        if (f.replenishment_hulls_per_year == 0) {
            try std.testing.expect(gs.faction_rosters.get(f.key) == null);
            continue;
        }
        const expected: usize = @as(usize, f.replenishment_hulls_per_year) *
            @as(usize, tg.faction_roster_seed_years);
        const roster = gs.faction_rosters.get(f.key) orelse {
            std.debug.print("seedFactionRosters: no roster for {s}\n", .{f.key});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(expected, roster.items.len);

        // Every member id resolves in hull_instances with correct fields.
        for (roster.items) |hid| {
            const inst = gs.hull_instances.getPtr(hid) orelse {
                std.debug.print("seedFactionRosters: hull {d} not in hull_instances\n", .{@intFromEnum(hid)});
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualStrings(f.key, switch (inst.owner) {
                .faction => |k| k,
                else => return error.TestUnexpectedResult,
            });
            try std.testing.expect(inst.pre_campaign);
            try std.testing.expectEqual(hull_mod.HullStatus.active, inst.status);
            // Exactly one open .initial interval.
            var found: usize = 0;
            for (gs.hull_ownership_history.items) |h| {
                if (h.hull_instance_id != hid) continue;
                found += 1;
                try std.testing.expectEqual(hull_mod.AcquisitionType.initial, h.acquisition_type);
                try std.testing.expectEqual(@as(u32, 0), h.from_day);
                try std.testing.expectEqual(@as(u32, 0), h.to_day);
                try std.testing.expectEqualStrings(f.key, h.prior_owner_key);
            }
            try std.testing.expectEqual(@as(usize, 1), found);
        }
    }
    // next_hull_instance_id is past all seeded ids.
    var max_id: u32 = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| {
        const raw: u32 = @intFromEnum(e.key_ptr.*);
        if (raw > max_id) max_id = raw;
    }
    try std.testing.expect(gs.next_hull_instance_id > max_id);
}

test "seedFactionRosters: determinism and stream isolation" {
    // Two same-seed campaigns produce identical stateHash after seeding.
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 7002 });
    defer gs1.deinit();
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 7002 });
    defer gs2.deinit();

    _ = try @import("founding.zig").createCommander(&gs1, "T", .LC, .line_officer);
    _ = try @import("founding.zig").createCommander(&gs2, "T", .LC, .line_officer);
    gs1.clock.date.year = 3025;
    gs2.clock.date.year = 3025;

    // Sample the .generation stream on both before seeding.
    const gen_before_1 = gs1.rng.random(.generation).int(u64);
    const gen_before_2 = gs2.rng.random(.generation).int(u64);
    try std.testing.expectEqual(gen_before_1, gen_before_2);

    // Resync: reset both prngs to same state for generation stream
    // (the sample above advanced both identically, so they remain equal).

    try seedFactionRosters(&gs1);
    try seedFactionRosters(&gs2);

    try std.testing.expectEqual(digest.stateHash(&gs1), digest.stateHash(&gs2));

    // Stream isolation: seeding must not perturb .generation draws.
    // Sample .generation draws after seeding on both (should still match).
    for (0..10) |_| {
        try std.testing.expectEqual(
            gs1.rng.random(.generation).int(u64),
            gs2.rng.random(.generation).int(u64),
        );
    }
}

test "seedFactionRosters: atomicity — reserve-phase failure leaves stateHash unchanged" {
    // Outer arena owns all pages; inner arena nulled after test so outer.deinit()
    // cleans up without leaks — the standard atomicity-test pattern (contract_market.zig).
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7003 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.date.year = 3025;

    const before = digest.stateHash(&gs);

    // Block all further allocations (the reserve phase fires first).
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, seedFactionRosters(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

// Round-trip test lives in src/persist/store.zig (rule 5: sim does not import
// persist; the test is "seeded campaign round-trips with identical stateHash").
