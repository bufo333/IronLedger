//! Monthly faction manufacturing and surplus-to-market flow (P3e.6,
//! docs/p3c-economy-design.md §4 "Market — monthly surplus").
//! MekHQ counterpart: `UnitMarket` wholesale regeneration (docs/mekhq-map.md).
//! Pure sim logic: no I/O, no wall clock. RNG via the .market stream.
//! The one owner of the manufacture-and-list rule (rule 20).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const faction_mod = @import("../domain/faction.zig");
const planet_mod = @import("../domain/planet.zig");
const chassis_mod = @import("../domain/chassis.zig");
const part_mod = @import("../domain/part.zig");
const hull_instance_mod = @import("../domain/hull_instance.zig");
const market = @import("../econ/market.zig");
const roster_gen = @import("../gen/roster_gen.zig");
const GameState = @import("state.zig").GameState;

/// The one owner of the monthly manufacture-and-list rule (rule 20/3).
/// For each manufacturing faction (replenishment_hulls_per_year > 0), mints
/// the month's hull output into the faction pool, then flows any surplus
/// above operational need onto the market board, throttled by world conflict.
///
/// Failure-atomic per faction (rules 7, 11–13): a failing allocator in the
/// prepare phase leaves all GameState fields for that faction unchanged;
/// already-committed factions from earlier loop iterations remain (each
/// faction iteration is independently atomic — partial success across
/// factions is acceptable and matches the plan's per-faction semantics).
pub fn runMonthly(gs: *GameState) !void {
    const day = gs.clock.day_index;
    const from_day = day -| types.days_per_month;
    const year = gs.clock.date.year;
    const seed_years = tuning.generation.faction_roster_seed_years;
    const listing_days = tuning.market.faction_surplus_listing_days;
    const alloc = gs.allocator();

    for (faction_mod.table) |*f| {
        if (f.replenishment_hulls_per_year == 0) continue;

        const output = market.factionManufacturedBetween(
            from_day,
            day,
            f.replenishment_hulls_per_year,
        );
        if (output == 0) continue;

        // Pool state before this month's inflow.
        const pool_size: u32 = if (gs.faction_rosters.get(f.key)) |r|
            @intCast(r.items.len)
        else
            0;
        const need = market.operationalNeed(f.replenishment_hulls_per_year, seed_years);
        const pool_after: u32 = pool_size + output;
        const surplus: u32 = if (pool_after > need) pool_after - need else 0;
        const conflict = conflictBp(gs, f.key);
        // Cap to_market at output: only newly manufactured hulls flow to market
        // (docs/p3c-economy-design.md §4 "of them" = of the minted hulls). // TUNE
        const to_market: u32 = @min(
            market.surplusThroughput(surplus, conflict, f.conflict_sensitivity_bp),
            output,
        );

        // ---- Prepare (all fallible work; gs.* is not mutated) ----
        // Each hull: 1 initial ownership row.
        // Each surplus hull: 1 additional transfer row when moving to market.
        try gs.hull_instances.ensureUnusedCapacity(alloc, output);
        try gs.hull_ownership_history.ensureUnusedCapacity(alloc, output + to_market);

        // Ensure the faction's roster entry exists and has capacity for the inflow.
        const roster_gop = try gs.faction_rosters.getOrPut(alloc, f.key);
        if (!roster_gop.found_existing) roster_gop.value_ptr.* = .empty;
        try roster_gop.value_ptr.ensureUnusedCapacity(alloc, output);

        try gs.market_listings.ensureUnusedCapacity(alloc, to_market);

        // Draw from an rng copy so gs.rng is only updated on success (rule 12).
        var rng_copy = gs.rng;
        var next_id = gs.next_hull_instance_id;
        var next_listing = gs.next_listing_id;

        // Pre-build HullInstance values (including loadout — fallible).
        const built = try alloc.alloc(hull_instance_mod.HullInstance, output);
        for (built) |*inst| {
            inst.* = hull_instance_mod.HullInstance{};
        }
        for (0..output) |idx| {
            const hid: types.HullInstanceId = @enumFromInt(next_id);
            next_id += 1;
            const ch = roster_gen.rollFactionPoolOne(&rng_copy, .market, f.key, year);
            var inst: hull_instance_mod.HullInstance = .{
                .id = hid,
                .base_key = ch.key, // static catalogue memory
                .status = .active,
                .intro_year = ch.intro_year,
                .pre_campaign = false,
                .owner = .{ .faction = f.key }, // static catalogue key
            };
            for (ch.loadout) |slot| {
                try inst.loadout.append(alloc, .{ .part_key = slot.part });
            }
            built[idx] = inst;
        }

        // Pre-build Listing values for surplus hulls (the last to_market in built).
        const built_listings = try alloc.alloc(market.Listing, to_market);
        for (0..to_market) |li| {
            const surplus_idx = output - to_market + li;
            const inst = &built[surplus_idx];
            const ch = chassis_mod.find(inst.base_key).?; // static catalogue — always present
            // Compute avg weapon cost from chassis loadout (design §4 pricing // TUNE).
            var weapon_value: types.CBills = 0;
            var weapon_count: u32 = 0;
            for (ch.loadout) |slot| if (slot.class == .weapon) {
                weapon_value += part_mod.cost(slot.part);
                weapon_count += 1;
            };
            const avg_weapon: types.CBills = if (weapon_count > 0)
                @divTrunc(weapon_value, weapon_count)
            else
                50_000;
            const price_roll = market.priceRollBp(&rng_copy, .market);
            // Factory-fresh hull: no degradation shown in the listing (condition null).
            // Price computed from a perfect-condition hull (armor 100%, quality F, no damage).
            const factory_cond: market.HullCondition = .{
                .armor_pct = 100,
                .quality = .f,
                .damaged_slots = 0,
                .destroyed_slots = 0,
                .missing_components = 0,
            };
            const lid: types.ListingId = @enumFromInt(next_listing);
            next_listing += 1;
            built_listings[li] = .{
                .kind = .unit,
                .item_key = ch.key, // static catalogue memory
                .rarity = ch.rarity,
                .price = market.hullPrice(ch.cost, avg_weapon, factory_cond, price_roll),
                .id = lid,
                .listed_day = day,
                .expires_day = day + listing_days,
                .condition = null, // factory fresh — no condition degradation (design §4)
                .hull_instance_id = inst.id,
            };
        }

        // ---- Commit (infallible: no allocation can fail past this point) ----
        // Insert all minted hulls into the faction pool.
        for (built) |inst| {
            gs.hull_instances.putAssumeCapacity(inst.id, inst);
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = inst.id,
                .from_day = day,
                .to_day = 0,
                .acquisition_type = .initial,
                .prior_owner_key = f.key, // static catalogue memory (no dupe needed)
            });
            roster_gop.value_ptr.appendAssumeCapacity(inst.id);
        }

        // Move surplus hulls (the last to_market in built) from pool to market.
        for (0..to_market) |li| {
            const surplus_idx = output - to_market + li;
            const hid = built[surplus_idx].id;
            const listing = built_listings[li];

            // Pop this hull from the roster: pop from end (they were just appended there).
            const roster = roster_gop.value_ptr;
            std.debug.assert(roster.items.len > 0);
            std.debug.assert(roster.items[roster.items.len - 1 - (to_market - 1 - li)] == hid);
            // Remove by swapping with the appropriate tail element, then truncate.
            // Since we appended output hulls in order, the surplus ones are at the end.
            // Pop them in reverse order to keep indices stable.
            _ = roster.orderedRemove(roster.items.len - (to_market - li));

            // Transfer ownership: faction → market.
            const inst_ptr = gs.hull_instances.getPtr(hid).?;
            inst_ptr.owner = .market;
            // Close the initial ownership interval.
            for (gs.hull_ownership_history.items) |*h| {
                if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = day;
            }
            // Open a transfer interval naming the faction as prior owner.
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = day,
                .to_day = 0,
                .acquisition_type = .transfer,
                .prior_owner_key = f.key, // static catalogue memory
            });

            // Append the prepared listing.
            gs.market_listings.appendAssumeCapacity(listing);
        }

        // Update counters last (infallible).
        gs.next_hull_instance_id = next_id;
        gs.next_listing_id = next_listing;
        gs.rng = rng_copy;
    }
}

/// The single owner of the faction conflict-pressure query (rule 22).
/// Sums enemy_influence + infrastructure_strain − employer_control over all
/// world_states on planets owned by this faction, converts to basis points
/// (×100 per dimension unit; docs/p3c-economy-design.md §4 // TUNE), and
/// clamps to 0..=100_000. Returns 0 when the faction owns no world_state
/// entries (no pressure → full surplus flow).
fn conflictBp(gs: *const GameState, faction_key: []const u8) types.Bp {
    var raw: i64 = 0;
    var it = gs.world_states.iterator();
    while (it.next()) |e| {
        const planet = planet_mod.find(e.key_ptr.*) orelse continue;
        if (!std.mem.eql(u8, planet.faction, faction_key)) continue;
        const ws = e.value_ptr;
        raw += @as(i64, ws.enemy_influence) +
            @as(i64, ws.infrastructure_strain) -
            @as(i64, ws.employer_control);
    }
    // Map world_state scale (-100..100 per dimension) to basis points (×100). // TUNE
    const bp: i64 = raw * 100;
    return @intCast(std.math.clamp(bp, 0, 100_000));
}

// ---- Tests ---------------------------------------------------------------

const testing = std.testing;
const digest = @import("digest.zig");
const world_state_mod = @import("../domain/world_state.zig");

/// Seed `n` hull instances into a faction's roster (for testing only).
fn seedTestFactionRoster(gs: *GameState, faction_key: []const u8, n: u32) !void {
    const alloc = gs.allocator();
    const gop = try gs.faction_rosters.getOrPut(alloc, faction_key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (0..n) |_| {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(alloc, hid, .{
            .id = hid,
            .base_key = "LCT-1V", // light mek, always in catalogue
            .owner = .{ .faction = faction_key },
        });
        try gs.hull_ownership_history.append(alloc, .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = 0,
            .acquisition_type = .initial,
            .prior_owner_key = faction_key,
        });
        try gop.value_ptr.append(alloc, hid);
    }
}

test "runMonthly: manufacturing faction with no pressure generates surplus listing" {
    // LC: rate=12, need=operationalNeed(12,2)=24.
    // Seed exactly 24 hulls → pool at need.
    // day_index=31, from=1: factionManufacturedBetween(1,31,12) = 1 hull out.
    // pool_after=25, surplus=1, conflict=0 → to_market=1.
    var gs = GameState.init(testing.allocator, .{ .seed = 5001 });
    defer gs.deinit();
    gs.clock.day_index = 31;
    gs.clock.date.year = 3025;

    const need: u32 = market.operationalNeed(12, tuning.generation.faction_roster_seed_years);
    try seedTestFactionRoster(&gs, "LC", need);

    const pool_before = gs.faction_rosters.get("LC").?.items.len;

    try runMonthly(&gs);

    // Pool grew by output (1) minus to_market (1) = same size (manufactured hull went directly to market).
    // Actually: we add output=1, then pop to_market=1, net = 0 change in roster size.
    const pool_after_run = gs.faction_rosters.get("LC").?.items.len;
    try testing.expectEqual(pool_before, pool_after_run); // net: +1 inflow −1 to market

    // Exactly one surplus listing with a hull_instance_id.
    var surplus_count: u32 = 0;
    for (gs.market_listings.items) |l| {
        if (l.hull_instance_id != .none) surplus_count += 1;
    }
    try testing.expectEqual(@as(u32, 1), surplus_count);

    // The listed hull's instance must have owner .market.
    const listing = gs.market_listings.items[0];
    try testing.expect(listing.hull_instance_id != .none);
    const inst = gs.hull_instances.getPtr(listing.hull_instance_id).?;
    try testing.expectEqual(hull_instance_mod.OwnerType.market, std.meta.activeTag(inst.owner));

    // The listing condition must be null (factory fresh).
    try testing.expect(listing.condition == null);
}

test "runMonthly: asymmetric locality — pressured faction lists fewer surplus hulls" {
    // Two factions: LC (no world pressure) and DC (enemy_influence=100 on luthien).
    // Both seeded at operational need → surplus = output = 1 each.
    // LC: conflict=0 → to_market=1.
    // DC: conflict=conflictBp from luthien (enemy_influence=100) → throttled → to_market=0.
    var gs = GameState.init(testing.allocator, .{ .seed = 5002 });
    defer gs.deinit();
    gs.clock.day_index = 31;
    gs.clock.date.year = 3025;

    const need: u32 = market.operationalNeed(12, tuning.generation.faction_roster_seed_years);
    try seedTestFactionRoster(&gs, "LC", need);
    try seedTestFactionRoster(&gs, "DC", need);

    // Add a world_state for luthien (DC planet) with high enemy_influence.
    try gs.world_states.put(gs.allocator(), "luthien", .{
        .enemy_influence = 100, // maximum pressure
        .infrastructure_strain = 0,
        .employer_control = 0,
    });

    try runMonthly(&gs);

    // Count surplus listings per faction.
    var lc_listings: u32 = 0;
    var dc_listings: u32 = 0;
    for (gs.market_listings.items) |l| {
        if (l.hull_instance_id == .none) continue;
        // Identify faction from hull instance owner history (prior_owner_key on initial row).
        for (gs.hull_ownership_history.items) |h| {
            if (h.hull_instance_id == l.hull_instance_id and
                h.acquisition_type == .transfer and h.to_day == 0)
            {
                if (std.mem.eql(u8, h.prior_owner_key, "LC")) lc_listings += 1;
                if (std.mem.eql(u8, h.prior_owner_key, "DC")) dc_listings += 1;
            }
        }
    }

    // LC (calm) must have more listings than DC (pressured).
    try testing.expect(lc_listings > dc_listings);
    try testing.expectEqual(@as(u32, 1), lc_listings);
    // DC: conflictBp = 100 * 100 = 10_000 bp; sensitivity_bp = 5_000;
    // applyBp(10_000, 5_000) = 5_000; pass_bp = 10_000 - 5_000 = 5_000;
    // surplusThroughput(1, 10_000, 5_000) = applyBp(1, 5_000) = 0 (integer floor).
    try testing.expectEqual(@as(u32, 0), dc_listings);
}

test "runMonthly: zero-rate factions (PER, CS) produce nothing" {
    var gs = GameState.init(testing.allocator, .{ .seed = 5003 });
    defer gs.deinit();
    gs.clock.day_index = 365;
    gs.clock.date.year = 3025;
    // Seed a roster for PER and CS so the skipping is clearly about rate=0.
    try seedTestFactionRoster(&gs, "PER", 10);
    try seedTestFactionRoster(&gs, "CS", 10);

    const before = digest.stateHash(&gs);
    try runMonthly(&gs);
    // PER and CS have rate=0 → skip → no change (other factions may also run if
    // factionManufacturedBetween returns > 0 at day 365, so we only verify PER/CS
    // rosters and pool sizes didn't change for those keys — not a full hash invariant).
    // Verify their rosters are unchanged.
    const per_len = if (gs.faction_rosters.get("PER")) |r| r.items.len else 0;
    const cs_len = if (gs.faction_rosters.get("CS")) |r| r.items.len else 0;
    try testing.expectEqual(@as(usize, 10), per_len);
    try testing.expectEqual(@as(usize, 10), cs_len);
    _ = before; // hash may differ due to manufacturing factions running; that is correct
}

test "runMonthly: atomicity — any allocation failure leaves stateHash unchanged" {
    // Sweep fail_index from 0 upward; every OOM must leave the state bit-identical
    // to the pre-call snapshot. First success must change the state.
    // Pattern from roster_seed.zig atomicity test (contract rule 69).
    //
    // The null-arena trick replaces the child allocator each iteration to inject
    // failure at position i. Because the arena forgets all prior pages, arrays
    // that already have capacity must not need remap during runMonthly — otherwise
    // the ArenaAllocator panics on a null used_list. Pre-reserving capacity on
    // every array runMonthly will touch ensures ensureUnusedCapacity is a no-op
    // inside the loop; only the fresh alloc calls within prepare go through the
    // failing allocator.
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();

    // Seed LC at need so output=1 → surplus=1 → to_market=1 (LC rate=12,
    // day_index=31, conflict=0 at day 31 with no world_states). Also pre-insert empty roster entries for ALL
    // manufacturing factions so getOrPut inside runMonthly never needs to grow
    // the faction_rosters map (a remap of the map's backing array would panic
    // with a null used_list).
    var gs = GameState.init(outer.allocator(), .{ .seed = 5004 });
    gs.clock.day_index = 31;
    gs.clock.date.year = 3025;
    const need: u32 = market.operationalNeed(12, tuning.generation.faction_roster_seed_years);
    try seedTestFactionRoster(&gs, "LC", need);
    for (faction_mod.table) |*f| {
        if (f.replenishment_hulls_per_year == 0) continue;
        const gop = try gs.faction_rosters.getOrPut(gs.allocator(), f.key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
    }

    // Pre-reserve capacity on shared arrays so ensureUnusedCapacity in runMonthly
    // is a no-op (no remap through the null-arena) and the failing allocator only
    // sees the fresh alloc calls in the prepare phase.
    {
        var n_mfg: u32 = 0;
        for (faction_mod.table) |*f| if (f.replenishment_hulls_per_year > 0) {
            n_mfg += 1;
        };
        // Each faction: output ≤ 1 hull + 2 history rows + 1 listing.
        try gs.hull_instances.ensureUnusedCapacity(gs.allocator(), n_mfg + 4);
        try gs.hull_ownership_history.ensureUnusedCapacity(gs.allocator(), n_mfg * 2 + 4);
        try gs.market_listings.ensureUnusedCapacity(gs.allocator(), n_mfg + 4);
        var rit = gs.faction_rosters.iterator();
        while (rit.next()) |e| {
            try e.value_ptr.ensureUnusedCapacity(gs.allocator(), 2);
        }
    }

    const before = digest.stateHash(&gs);

    var i: usize = 0;
    while (true) : (i += 1) {
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();

        if (runMonthly(&gs)) |_| {
            // All allocations succeeded — state must have changed.
            try testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}
