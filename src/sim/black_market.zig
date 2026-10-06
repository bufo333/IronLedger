//! Black-market dispersed listing placement: eligibility predicate, listing
//! constructor, and lost-field wreck dispersal. MekHQ counterpart: AtB black
//! market / `market/UnitMarket` grey-market offers (docs/mekhq-map.md).
//! Design: docs/p3f-faction-loop-design.md §2.3, §3.
//! Pure: no I/O, no wall clock, no global state (ARCH rule 2).

const std = @import("std");
const types = @import("../domain/types.zig");
const market = @import("../econ/market.zig");
const GameState = @import("state.zig").GameState;
const rng_mod = @import("rng.zig");
const chassis_mod = @import("../domain/chassis.zig");
const part_mod = @import("../domain/part.zig");
const planet_mod = @import("../domain/planet.zig");
const tuning = @import("../domain/tuning.zig").t;
const hull_instance_mod = @import("../domain/hull_instance.zig");

/// Who is evaluating a black-market listing offer.
pub const BuyerKind = enum { player, pirate, merc_company };

/// Single owner of the "can buyer X take listing Y" rule (rule 20/3).
/// Returns true iff the listing is a black-market offer whose visibility
/// window has opened on the given day.
/// `gs` and `buyer` are retained for the P3f.3 per-buyer reach gate on
/// listing.planet_key; until then every black-market world is reachable
/// by every buyer.
pub fn buyerEligible(gs: *const GameState, listing: market.Listing, buyer: BuyerKind, current_day: u32) bool {
    _ = gs;
    _ = buyer;
    if (!listing.black_market) return false;
    if (listing.available_after > current_day) return false;
    // P3f.3 fills per-buyer reach gating of listing.planet_key.
    return true;
}

/// Single owner of dispersed black-market listing construction (rule 20).
/// Prices the wreck at factory-fresh hullPrice (deterministic — no RNG draw;
/// docs/p3f-faction-loop-design.md §3.4 // TUNE).  `gs` is read-only for
/// the hull lookup.
pub fn makeDispersedListing(
    gs: *const GameState,
    hull_instance_id: types.HullInstanceId,
    listing_id: types.ListingId,
    planet_key: []const u8,
    battle_day: u32,
    delay_days: u32,
) market.Listing {
    const inst = gs.hull_instances.getPtr(hull_instance_id).?;
    const ch = chassis_mod.find(inst.base_key).?; // static catalogue — always present for a pool hull
    // Compute avg weapon cost from chassis loadout (design §3.4 pricing // TUNE).
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
    // Factory-fresh hull: no degradation shown in the listing (condition null).
    // Price computed from a perfect-condition hull (armor 100%, quality F, no damage).
    const factory_cond: market.HullCondition = .{
        .armor_pct = 100,
        .quality = .f,
        .damaged_slots = 0,
        .destroyed_slots = 0,
        .missing_components = 0,
    };
    return market.Listing{
        .kind = .unit,
        .item_key = ch.key, // static catalogue memory
        .rarity = ch.rarity,
        .price = market.hullPrice(ch.cost, avg_weapon, factory_cond, 10_000),
        .id = listing_id,
        .black_market = true,
        .planet_key = planet_key,
        .available_after = battle_day + delay_days,
        .hull_instance_id = hull_instance_id,
        .company = .none,
        .hq = .none,
        .condition = null,
    };
}

/// Single owner of the lost-field terminal-disposition rule for drawn enemy
/// wrecks (docs/p3f-faction-loop-design.md §3, design §8 invariants; rule 20/76).
///
/// Called by battle.resolveEngagement after writeHullCombatRecords, only on
/// the pool path and only on a lost field (`pool_path and !held_field`). At
/// that point each hull in `wrecks` is pool-removed, `.active`, enemy-owned,
/// and absent from any roster — the limbo state §3.1 describes. This function
/// gives every such hull exactly one terminal disposition:
///   - The first `min(len, enemy_recovery_capacity)` hulls re-home into
///     `faction_rosters[enemy_faction_key]`.
///   - The remainder transfer to `.market` and surface as dispersed
///     black-market listings on worlds other than the battle world.
///
/// Draw order (rule 6 / .battle stream): recovery split is in pool order
/// (no draw); for each dispersed hull in order: (a) draw world index, then
/// (b) draw delay.
///
/// Failure-atomic (rules 7/69): all fallible reserves happen before any draw
/// or gs mutation; a failing reserve leaves `gs` unchanged and `rng` advanced
/// not at all.  `gs.rng` is never written here — the caller commits it.
pub fn disperseEnemyWrecks(
    gs: *GameState,
    alloc: std.mem.Allocator,
    wrecks: []const types.HullInstanceId,
    enemy_faction_key: []const u8,
    battle_day: u32,
    battle_planet_key: []const u8,
    rng: *rng_mod.Rng,
) !void {
    if (wrecks.len == 0) return;

    const cap: usize = tuning.market.enemy_recovery_capacity;
    const recovered_n = @min(wrecks.len, cap);

    // Build eligible-world list into a fixed stack buffer (no allocation needed).
    var worlds: [16][]const u8 = undefined;
    var worlds_len: usize = 0;
    for (planet_mod.catalog) |*p| {
        if (p.black_market and !std.mem.eql(u8, p.key, battle_planet_key)) {
            worlds[worlds_len] = p.key;
            worlds_len += 1;
        }
    }

    // Precondition guard: an empty enemy key is a programming error.
    // Fall back by routing all hulls through recovery (all get roster entry).
    // An empty world list routes dispersed hulls through recovery too, so
    // every hull still reaches a terminal state (rule 1).
    const effective_cap: usize = if (enemy_faction_key.len == 0 or worlds_len == 0)
        wrecks.len // route all to recovery
    else
        recovered_n;
    const dispersed = wrecks[effective_cap..];
    const recovered = wrecks[0..effective_cap];

    // ---- Prepare (fallible; no draw; no logical gs mutation) ----
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, recovered.len + dispersed.len);
    try gs.market_listings.ensureUnusedCapacity(alloc, dispersed.len);
    if (recovered.len > 0 and enemy_faction_key.len > 0) {
        const gop = try gs.faction_rosters.getOrPut(alloc, enemy_faction_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.ensureUnusedCapacity(alloc, recovered.len);
    }

    // ---- Commit (infallible from here) ----
    var next_listing: u32 = gs.next_listing_id;

    // Recovery: re-home into the enemy faction roster.
    if (recovered.len > 0 and enemy_faction_key.len > 0) {
        const roster = gs.faction_rosters.getPtr(enemy_faction_key).?;
        for (recovered) |hid| {
            const inst = gs.hull_instances.getPtr(hid).?;
            inst.owner = .{ .faction = enemy_faction_key };
            inst.status = .active;
            // Close the open ownership interval.
            for (gs.hull_ownership_history.items) |*h| {
                if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = battle_day;
            }
            // Open a transfer interval naming the enemy faction as prior owner.
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = battle_day,
                .to_day = 0,
                .acquisition_type = .transfer,
                .prior_owner_key = enemy_faction_key, // static key — no dupe needed
            });
            roster.appendAssumeCapacity(hid);
        }
    }

    // Dispersal: transfer to .market and build a black-market listing.
    for (dispersed) |hid| {
        // Draw: world index, then delay (documented draw order — rule 6 / .battle stream).
        const widx = rng.random(.battle).uintLessThan(usize, worlds_len);
        const delay = rng.random(.battle).intRangeAtMost(
            u32,
            tuning.market.black_market_delay_days_min,
            tuning.market.black_market_delay_days_max,
        );
        const lid: types.ListingId = @enumFromInt(next_listing);
        next_listing += 1;

        const inst = gs.hull_instances.getPtr(hid).?;
        inst.owner = .market;
        inst.status = .active;
        // Close the open ownership interval.
        for (gs.hull_ownership_history.items) |*h| {
            if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = battle_day;
        }
        // Open a transfer interval naming the enemy faction as prior owner.
        gs.hull_ownership_history.appendAssumeCapacity(.{
            .hull_instance_id = hid,
            .from_day = battle_day,
            .to_day = 0,
            .acquisition_type = .transfer,
            .prior_owner_key = enemy_faction_key, // static key — no dupe needed
        });

        const listing = makeDispersedListing(gs, hid, lid, worlds[widx], battle_day, delay);
        gs.market_listings.appendAssumeCapacity(listing);
    }

    gs.next_listing_id = next_listing;
    // gs.rng is NOT written here — the caller commits it.
}

// ---- Tests ---------------------------------------------------------------

const testing = std.testing;
const digest = @import("digest.zig");

/// Seed N hull instances into a faction limbo state: owner = .{ .faction = key },
/// status = .active, open ownership interval (to_day = 0), NOT in any roster.
/// Returns a slice of the seeded HullInstanceIds (arena-owned by the caller's alloc).
fn seedLimboWrecks(
    gs: *GameState,
    alloc: std.mem.Allocator,
    faction_key: []const u8,
    n: u32,
    base_key: []const u8,
) ![]types.HullInstanceId {
    const ids = try alloc.alloc(types.HullInstanceId, n);
    for (0..n) |i| {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hid, .{
            .id = hid,
            .base_key = base_key,
            .owner = .{ .faction = faction_key },
            .status = .active,
        });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = 0,
            .acquisition_type = .initial,
            .prior_owner_key = faction_key,
        });
        ids[i] = hid;
    }
    return ids;
}

test "disperseEnemyWrecks: recovers up to capacity, disperses the remainder to other black-market worlds" {
    // Rule 67: split/placement/window invariants.
    // N = enemy_recovery_capacity + 3 wrecks; battle world = "solaris7" (a black-market world).
    // Expect: exactly enemy_recovery_capacity hulls recovered into faction roster;
    // the remaining 3 get market listings on a black-market world != "solaris7",
    // available_after in [battle_day+min, battle_day+max], hull_instance_id set.
    var gs = GameState.init(testing.allocator, .{ .seed = 7201 });
    defer gs.deinit();

    const faction_key = "DC";
    const battle_day: u32 = 100;
    const battle_planet = "solaris7";
    const cap: u32 = tuning.market.enemy_recovery_capacity;
    const n: u32 = cap + 3;

    // Pre-insert enemy faction roster entry so getOrPut never needs to grow the map.
    {
        const gop = try gs.faction_rosters.getOrPut(gs.allocator(), faction_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
    }

    var buf: [32]types.HullInstanceId = undefined;
    const wrecks = try seedLimboWrecks(&gs, testing.allocator, faction_key, n, "LCT-1V");
    defer testing.allocator.free(wrecks);
    std.mem.copyForwards(types.HullInstanceId, buf[0..n], wrecks[0..n]);

    var rng = rng_mod.Rng.init(7201);
    try disperseEnemyWrecks(&gs, gs.allocator(), buf[0..n], faction_key, battle_day, battle_planet, &rng);

    // Check recovered hulls.
    const roster = gs.faction_rosters.get(faction_key).?;
    try testing.expectEqual(cap, @as(u32, @intCast(roster.items.len)));
    for (buf[0..cap]) |hid| {
        const inst = gs.hull_instances.getPtr(hid).?;
        try testing.expectEqual(hull_instance_mod.OwnerType.faction, std.meta.activeTag(inst.owner));
        var found = false;
        for (roster.items) |rid| if (rid == hid) {
            found = true;
            break;
        };
        try testing.expect(found);
    }

    // Check dispersed listings.
    try testing.expectEqual(@as(u32, 3), @as(u32, @intCast(gs.market_listings.items.len)));
    for (buf[cap..n], gs.market_listings.items) |hid, listing| {
        const inst = gs.hull_instances.getPtr(hid).?;
        try testing.expectEqual(hull_instance_mod.OwnerType.market, std.meta.activeTag(inst.owner));
        try testing.expect(listing.black_market);
        try testing.expect(!std.mem.eql(u8, listing.planet_key, battle_planet));
        try testing.expect(listing.available_after >= battle_day + tuning.market.black_market_delay_days_min);
        try testing.expect(listing.available_after <= battle_day + tuning.market.black_market_delay_days_max);
        try testing.expectEqual(hid, listing.hull_instance_id);
        // Verify planet_key is a known black-market world.
        var is_bm_world = false;
        for (planet_mod.catalog) |*p| {
            if (p.black_market and std.mem.eql(u8, p.key, listing.planet_key)) {
                is_bm_world = true;
                break;
            }
        }
        try testing.expect(is_bm_world);
    }
    // next_listing_id advanced by 3.
    try testing.expectEqual(@as(u32, 1 + 3), gs.next_listing_id);
    _ = &gs; // suppress unused warning
}

test "disperseEnemyWrecks: every pool wreck reaches exactly one terminal disposition (rule 1 regression)" {
    // Rule 68: the rule-1 leak regression. Reconstruct the exact limbo state,
    // call, then assert no hull is owner==.faction while absent from the roster,
    // and every input wreck is either recovered (in roster) or dispersed
    // (owner==.market with a matching listing).
    var gs = GameState.init(testing.allocator, .{ .seed = 7202 });
    defer gs.deinit();

    const faction_key = "LC";
    const battle_day: u32 = 200;
    const battle_planet = "galatea";
    const n: u32 = tuning.market.enemy_recovery_capacity + 2;

    {
        const gop = try gs.faction_rosters.getOrPut(gs.allocator(), faction_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
    }

    const wrecks = try seedLimboWrecks(&gs, testing.allocator, faction_key, n, "LCT-1V");
    defer testing.allocator.free(wrecks);

    var rng = rng_mod.Rng.init(7202);
    try disperseEnemyWrecks(&gs, gs.allocator(), wrecks, faction_key, battle_day, battle_planet, &rng);

    // Verify: no hull in the input is still owner==.faction while absent from roster.
    const roster = gs.faction_rosters.get(faction_key).?;
    for (wrecks) |hid| {
        const inst = gs.hull_instances.getPtr(hid).?;
        switch (inst.owner) {
            .faction => {
                // Must be present in roster.
                var found = false;
                for (roster.items) |rid| if (rid == hid) {
                    found = true;
                    break;
                };
                try testing.expect(found);
            },
            .market => {
                // Must have a matching listing.
                var found = false;
                for (gs.market_listings.items) |l| {
                    if (l.hull_instance_id == hid) {
                        found = true;
                        break;
                    }
                }
                try testing.expect(found);
            },
            else => try testing.expect(false), // unexpected owner type
        }
    }
}

test "disperseEnemyWrecks: a failing allocator leaves stateHash unchanged" {
    // Rule 69: failure-atomicity. Sweep fail_index from 0; every OOM must leave
    // stateHash unchanged. First success must change the hash.
    // Pattern from faction_surplus.zig atomicity test (contract rule 69).
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();

    const faction_key = "DC";
    const battle_day: u32 = 50;
    const battle_planet = "antallos";
    const n: u32 = tuning.market.enemy_recovery_capacity + 1;

    var gs = GameState.init(outer.allocator(), .{ .seed = 7203 });
    gs.clock.day_index = battle_day;

    // Pre-insert the enemy roster entry so getOrPut never creates a new key.
    {
        const gop = try gs.faction_rosters.getOrPut(gs.allocator(), faction_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
    }

    // Seed wrecks using the outer arena allocator.
    const wrecks = try seedLimboWrecks(&gs, outer.allocator(), faction_key, n, "LCT-1V");

    // Pre-reserve capacity on all arrays disperseEnemyWrecks will touch, so
    // ensureUnusedCapacity inside the call is a no-op and only the fresh
    // alloc paths go through the failing allocator.
    try gs.hull_ownership_history.ensureUnusedCapacity(gs.allocator(), n * 2 + 4);
    try gs.market_listings.ensureUnusedCapacity(gs.allocator(), n + 4);
    try gs.faction_rosters.getPtr(faction_key).?.ensureUnusedCapacity(gs.allocator(), n + 4);

    const before = digest.stateHash(&gs);

    var i: usize = 0;
    while (true) : (i += 1) {
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();

        var rng = rng_mod.Rng.init(7203 + @as(u64, i));
        if (disperseEnemyWrecks(&gs, gs.allocator(), wrecks, faction_key, battle_day, battle_planet, &rng)) |_| {
            // Success: state must have changed.
            try testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

test "buyerEligible: black_market flag and available_after gate access for all BuyerKinds" {
    // Rule 67: buyerEligible is the single owner of the black-market listing
    // eligibility predicate. Table-driven over the two axes:
    // {black_market true/false} x {available_after <= current_day / >}.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57100 });
    defer gs.deinit();

    const current_day: u32 = 50;

    const Case = struct {
        black_market: bool,
        available_after: u32,
        want: bool,
    };
    const cases = [_]Case{
        .{ .black_market = true, .available_after = 0, .want = true },
        .{ .black_market = true, .available_after = 50, .want = true },
        .{ .black_market = true, .available_after = 51, .want = false },
        .{ .black_market = false, .available_after = 0, .want = false },
        .{ .black_market = false, .available_after = 50, .want = false },
    };
    const buyers = [_]BuyerKind{ .player, .pirate, .merc_company };

    for (cases) |c| {
        const listing = market.Listing{
            .kind = .unit,
            .item_key = "SHD-2H",
            .rarity = .common,
            .price = 0,
            .black_market = c.black_market,
            .available_after = c.available_after,
        };
        for (buyers) |buyer| {
            const got = buyerEligible(&gs, listing, buyer, current_day);
            try std.testing.expectEqual(c.want, got);
        }
    }
}
