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
const merc_company_mod = @import("../domain/merc_company.zig");
const roster_gen = @import("../gen/roster_gen.zig");
const faction_mod = @import("../domain/faction.zig");

/// Who is evaluating a black-market listing offer.
pub const BuyerKind = enum { player, pirate, merc_company };

/// Single owner of the "can buyer X take listing Y" rule (rule 20/3).
/// Returns true iff: (1) the listing is a black-market offer, (2) its
/// visibility window has opened (`available_after <= current_day`), AND
/// (3) `buyer` can reach `listing.planet_key`.
///
/// Reach rules (docs/p3f-faction-loop-design.md §2.3, §4; shipped P3f.3
/// per owner decision):
///   .pirate       — reaches worlds whose faction == "PER" only.
///   .merc_company — reaches worlds whose faction != "PER" only.
///   .player       — reaches a world that is one of its HQ worlds, or a
///                   world where one of its companies is deployed on an
///                   active contract.
/// Gates (1) and (2) are buyer-independent. An empty or unknown
/// `listing.planet_key` (HQ-board/abstraction black-market offers) is
/// unreachable by any buyer. `gs` is read only for the `.player` branch.
pub fn buyerEligible(gs: *const GameState, listing: market.Listing, buyer: BuyerKind, current_day: u32) bool {
    if (!listing.black_market) return false;
    if (listing.available_after > current_day) return false;
    const planet = planet_mod.find(listing.planet_key) orelse return false;
    switch (buyer) {
        // "PER" literal: precedent at contract_market.zig:1131.
        .pirate => return std.mem.eql(u8, planet.faction, "PER"),
        .merc_company => return !std.mem.eql(u8, planet.faction, "PER"),
        .player => {
            for (gs.hqs.values()) |h| {
                if (std.mem.eql(u8, h.planet_key, listing.planet_key)) return true;
            }
            for (gs.contracts.values()) |c| {
                if (c.status == .active and c.assigned_company != .none and
                    std.mem.eql(u8, c.planet_key, listing.planet_key)) return true;
            }
            return false;
        },
    }
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
///   - The first `min(len, enemy_recovery_capacity)` hulls re-home into their
///     explicit source roster (faction or merc company).
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
    source_owner: hull_instance_mod.HullOwner,
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

    const prior_owner_key = switch (source_owner) {
        .faction => |key| key,
        .merc_company => |id| gs.merc_companies.getPtr(id).?.faction_key,
        else => unreachable,
    };
    const effective_cap: usize = if (worlds_len == 0) wrecks.len else recovered_n;
    const dispersed = wrecks[effective_cap..];
    const recovered = wrecks[0..effective_cap];

    // ---- Prepare (fallible; no draw; no logical gs mutation) ----
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, recovered.len + dispersed.len);
    try gs.market_listings.ensureUnusedCapacity(alloc, dispersed.len);
    if (recovered.len > 0) switch (source_owner) {
        .faction => |key| {
            const gop = try gs.faction_rosters.getOrPut(alloc, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.ensureUnusedCapacity(alloc, recovered.len);
        },
        .merc_company => |id| {
            const gop = try gs.merc_company_rosters.getOrPut(alloc, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.ensureUnusedCapacity(alloc, recovered.len);
        },
        else => unreachable,
    };

    // ---- Commit (infallible from here) ----
    var next_listing: u32 = gs.next_listing_id;

    // Recovery returns wrecks to their explicit source owner, not merely its faction.
    if (recovered.len > 0) switch (source_owner) {
        .faction => |key| {
            const roster = gs.faction_rosters.getPtr(key).?;
            for (recovered) |hid| {
                const inst = gs.hull_instances.getPtr(hid).?;
                inst.owner = source_owner;
                inst.status = .active;
                for (gs.hull_ownership_history.items) |*h| {
                    if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = battle_day;
                }
                gs.hull_ownership_history.appendAssumeCapacity(.{
                    .hull_instance_id = hid,
                    .from_day = battle_day,
                    .to_day = 0,
                    .acquisition_type = .transfer,
                    .prior_owner_key = prior_owner_key,
                });
                roster.appendAssumeCapacity(hid);
            }
        },
        .merc_company => |id| {
            const roster = gs.merc_company_rosters.getPtr(id).?;
            for (recovered) |hid| {
                const inst = gs.hull_instances.getPtr(hid).?;
                inst.owner = source_owner;
                inst.status = .active;
                for (gs.hull_ownership_history.items) |*h| {
                    if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = battle_day;
                }
                gs.hull_ownership_history.appendAssumeCapacity(.{
                    .hull_instance_id = hid,
                    .from_day = battle_day,
                    .to_day = 0,
                    .acquisition_type = .transfer,
                    .prior_owner_key = prior_owner_key,
                });
                roster.appendAssumeCapacity(hid);
            }
        },
        else => unreachable,
    };

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
        // Open a transfer interval naming the original source affiliation.
        gs.hull_ownership_history.appendAssumeCapacity(.{
            .hull_instance_id = hid,
            .from_day = battle_day,
            .to_day = 0,
            .acquisition_type = .transfer,
            .prior_owner_key = prior_owner_key,
        });

        const listing = makeDispersedListing(gs, hid, lid, worlds[widx], battle_day, delay);
        gs.market_listings.appendAssumeCapacity(listing);
    }

    gs.next_listing_id = next_listing;
    // gs.rng is NOT written here — the caller commits it.
}

/// Single owner of the monthly NPC black-market consumption rule
/// (rule 20/76/77; docs/p3f-faction-loop-design.md §4.1).
///
/// Called from tick.zig runMarkets on day == 1, after faction_surplus.runMonthly
/// (so NPCs see freshly minted listings). Draw order: pirates (PER) first, then
/// each active merc company in gs.merc_companies.keys() order (insertion order ==
/// MercCompanyId order);
/// within each buyer the listing is chosen by a .market draw over the remaining
/// eligible set. Asset-safety: no player funds, forces, or units are touched.
/// gs.rng committed only on success (rules 7/11-13).
/// Each NPC buyer is evaluated with its own BuyerKind, so per-buyer reach
/// gating applies (pirates→PER worlds, mercs→non-PER worlds); the
/// kind==.unit and hull_instance_id!=.none guard excludes legacy abstraction
/// black-market offers and part listings (rule 1).
pub fn runNpcBlackMarketDraw(gs: *GameState) !void {
    const day = gs.clock.day_index;
    const alloc = gs.allocator();

    // Locate the PER faction key (fail-closed if absent).
    const per_row = faction_mod.find("PER") orelse return;
    const per_key = per_row.key; // static catalogue memory

    // Build the ordered buyer list on a fixed stack buffer:
    // entry 0 = pirate (PER), then one active merc company in insertion order.
    const max_buyers: usize = 256 + 1;
    const BuyerEntry = struct {
        kind: BuyerKind,
        merc_id: types.MercCompanyId, // .none for pirate
    };
    var buyers_buf: [max_buyers]BuyerEntry = undefined;
    var buyers_len: usize = 0;
    buyers_buf[buyers_len] = .{ .kind = .pirate, .merc_id = .none };
    buyers_len += 1;
    const merc_keys = gs.merc_companies.keys();
    var mercs_count: usize = 0;
    for (merc_keys) |merc_id| {
        if (mercs_count == max_buyers - 1) break;
        const company = gs.merc_companies.getPtr(merc_id) orelse unreachable;
        if (company.dissolved_day != 0) continue;
        buyers_buf[buyers_len] = .{ .kind = .merc_company, .merc_id = merc_id };
        buyers_len += 1;
        mercs_count += 1;
    }

    // ---- Prepare (fallible; no logical gs mutation) ----
    var rng_copy = gs.rng;

    // Consumed marker: one bool per listing, prevents two buyers from
    // taking the same hull (rule 1).
    const consumed = try alloc.alloc(bool, gs.market_listings.items.len);
    @memset(consumed, false);

    // Build consumption plan: for each buyer in order, build that buyer's
    // per-buyer eligible set from the not-yet-consumed listings and draw up
    // to npc_black_market_draws_per_month. Pirates reach only PER worlds;
    // mercs reach only non-PER worlds (buyerEligible reach rules; disjoint
    // sets). kind==.unit and hull_instance_id!=.none exclude legacy
    // abstraction offers and part listings (rule 1).
    const Plan = struct { buyer_idx: usize, listing_idx: usize };
    var plan: std.ArrayListUnmanaged(Plan) = .empty;
    for (0..buyers_len) |bi| {
        var elig: std.ArrayListUnmanaged(usize) = .empty;
        for (gs.market_listings.items, 0..) |l, i| {
            if (consumed[i]) continue;
            if (!buyerEligible(gs, l, buyers_buf[bi].kind, day)) continue;
            if (l.kind != .unit) continue;
            if (l.hull_instance_id == .none) continue;
            try elig.append(alloc, i);
        }
        if (elig.items.len == 0) continue;
        const take = @min(tuning.market.npc_black_market_draws_per_month, elig.items.len);
        for (0..take) |_| {
            const j = rng_copy.random(.market).uintLessThan(usize, elig.items.len);
            const idx = elig.items[j];
            try plan.append(alloc, .{ .buyer_idx = bi, .listing_idx = idx });
            consumed[idx] = true;
            _ = elig.swapRemove(j);
        }
    }

    if (plan.items.len == 0) return;

    // Count per-buyer takes from the plan.
    var pirate_take: usize = 0;
    var merc_takes_buf: [max_buyers - 1]usize = [_]usize{0} ** (max_buyers - 1);
    for (plan.items) |entry| {
        if (entry.buyer_idx == 0) {
            pirate_take += 1;
        } else {
            merc_takes_buf[entry.buyer_idx - 1] += 1;
        }
    }
    var distinct_mercs: usize = 0;
    for (0..mercs_count) |mi| {
        if (merc_takes_buf[mi] > 0) distinct_mercs += 1;
    }

    // Reserve capacity: one ownership history row per consumed hull.
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, plan.items.len);

    // Reserve PER roster capacity.
    if (pirate_take > 0) {
        try gs.faction_rosters.ensureUnusedCapacity(alloc, 1);
        const gop = try gs.faction_rosters.getOrPut(alloc, per_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.ensureUnusedCapacity(alloc, pirate_take);
    }

    // Reserve merc roster capacities (ensureUnusedCapacity on the map first to
    // prevent rehash invalidating existing pointers during successive getOrPuts).
    if (distinct_mercs > 0) {
        try gs.merc_company_rosters.ensureUnusedCapacity(alloc, distinct_mercs);
        for (0..mercs_count) |mi| {
            if (merc_takes_buf[mi] == 0) continue;
            const merc_id = buyers_buf[mi + 1].merc_id;
            const gop = try gs.merc_company_rosters.getOrPut(alloc, merc_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.ensureUnusedCapacity(alloc, merc_takes_buf[mi]);
            // Do NOT retain gop.value_ptr across additional getOrPut calls
            // (rehash hazard); re-fetch via getPtr in the commit phase.
        }
    }

    // ---- Commit (infallible: no allocation past this point) ----
    for (plan.items) |entry| {
        const l = gs.market_listings.items[entry.listing_idx];
        const hid = l.hull_instance_id;
        const inst = gs.hull_instances.getPtr(hid).?;

        if (entry.buyer_idx == 0) {
            // Pirate (PER) acquisition.
            inst.owner = .{ .faction = per_key };
            inst.status = .active;
            for (gs.hull_ownership_history.items) |*h| {
                if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = day;
            }
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = day,
                .to_day = 0,
                .acquisition_type = .transfer,
                .prior_owner_key = "market", // static string literal — no dupe needed
            });
            gs.faction_rosters.getPtr(per_key).?.appendAssumeCapacity(hid);
        } else {
            // Merc company acquisition.
            const merc_id = buyers_buf[entry.buyer_idx].merc_id;
            inst.owner = .{ .merc_company = merc_id };
            inst.status = .active;
            for (gs.hull_ownership_history.items) |*h| {
                if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = day;
            }
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = day,
                .to_day = 0,
                .acquisition_type = .transfer,
                .prior_owner_key = "market",
            });
            gs.merc_company_rosters.getPtr(merc_id).?.appendAssumeCapacity(hid);
        }
    }

    // Remove consumed listings infallibly: sort by listing_idx descending so
    // each orderedRemove does not shift any remaining consumed index.
    std.mem.sort(Plan, plan.items, {}, struct {
        fn desc(_: void, a: Plan, b: Plan) bool {
            return a.listing_idx > b.listing_idx;
        }
    }.desc);
    for (plan.items) |entry| {
        _ = gs.market_listings.orderedRemove(entry.listing_idx);
    }

    gs.rng = rng_copy;
}

/// Single owner of the monthly pirate-pool trickle rule (rule 20/76/77;
/// docs/p3f-faction-loop-design.md §2.6, §7 delivery table).
///
/// Called from tick.zig runMarkets on day == 1, after runNpcBlackMarketDraw.
/// Mints a fractional monthly share of tuning.generation.pirate_replenishment_hulls_per_year
/// new hulls into faction_rosters["PER"] via the PER RAT, advancing the .rosters
/// stream. Independent of the market (does not consume listings; creates fresh hulls).
/// gs.rng committed only on success (rules 7/11-13).
pub fn runPirateReplenishment(gs: *GameState) !void {
    const day = gs.clock.day_index;
    const from_day = day -| types.days_per_month;
    const year = gs.clock.date.year;
    const alloc = gs.allocator();

    // Locate PER; fail-closed if absent (matches seedPirateRoster).
    const per_row = faction_mod.find("PER") orelse return;
    const per_key = per_row.key; // static catalogue memory

    const output = market.factionManufacturedBetween(
        from_day,
        day,
        tuning.generation.pirate_replenishment_hulls_per_year,
    );
    if (output == 0) return; // no draw, no rng commit, no mutation

    // ---- Prepare (fallible) ----
    var rng_copy = gs.rng;
    var next_id = gs.next_hull_instance_id;

    try gs.hull_instances.ensureUnusedCapacity(alloc, output);
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, output);
    try gs.faction_rosters.ensureUnusedCapacity(alloc, 1);
    const roster_gop = try gs.faction_rosters.getOrPut(alloc, per_key);
    if (!roster_gop.found_existing) roster_gop.value_ptr.* = .empty;
    try roster_gop.value_ptr.ensureUnusedCapacity(alloc, output);

    // Pre-build HullInstance values (loadout appends are fallible — must happen here
    // in the prepare phase, before any gs mutation).
    const built = try alloc.alloc(hull_instance_mod.HullInstance, output);
    for (built) |*inst| inst.* = hull_instance_mod.HullInstance{};
    for (0..output) |idx| {
        const hid: types.HullInstanceId = @enumFromInt(next_id);
        next_id += 1;
        const ch = roster_gen.rollFactionPoolOne(&rng_copy, .rosters, per_key, year);
        var inst: hull_instance_mod.HullInstance = .{
            .id = hid,
            .base_key = ch.key, // static catalogue memory
            .status = .active,
            .intro_year = ch.intro_year,
            .pre_campaign = false, // minted during the campaign (unlike seedPirateRoster)
            .owner = .{ .faction = per_key }, // static catalogue key
        };
        for (ch.loadout) |slot| {
            try inst.loadout.append(alloc, .{ .part_key = slot.part });
        }
        built[idx] = inst;
    }

    // ---- Commit (infallible: no allocation past this point) ----
    const roster = roster_gop.value_ptr;
    for (built) |inst| {
        gs.hull_instances.putAssumeCapacity(inst.id, inst);
        gs.hull_ownership_history.appendAssumeCapacity(.{
            .hull_instance_id = inst.id,
            .from_day = day,
            .to_day = 0,
            .acquisition_type = .initial,
            .prior_owner_key = per_key, // static catalogue key — no dupe needed
        });
        roster.appendAssumeCapacity(inst.id);
    }
    gs.next_hull_instance_id = next_id;
    gs.rng = rng_copy;
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
    try disperseEnemyWrecks(&gs, gs.allocator(), buf[0..n], .{ .faction = faction_key }, battle_day, battle_planet, &rng);

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
    try disperseEnemyWrecks(&gs, gs.allocator(), wrecks, .{ .faction = faction_key }, battle_day, battle_planet, &rng);

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

test "disperseEnemyWrecks: recovered merc-company wrecks return to their company roster" {
    var gs = GameState.init(testing.allocator, .{ .seed = 7204 });
    defer gs.deinit();

    const merc_id: types.MercCompanyId = @enumFromInt(1);
    const faction_key = "DC";
    const battle_day: u32 = 300;
    try gs.merc_companies.put(gs.allocator(), merc_id, .{
        .id = merc_id,
        .faction_key = faction_key,
    });

    const n: u32 = tuning.market.enemy_recovery_capacity;
    const wrecks = try testing.allocator.alloc(types.HullInstanceId, n);
    defer testing.allocator.free(wrecks);
    for (wrecks, 0..) |*hid, i| {
        hid.* = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hid.*, .{
            .id = hid.*,
            .base_key = "LCT-1V",
            .owner = .{ .merc_company = merc_id },
            .status = .active,
        });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid.*,
            .from_day = 0,
            .to_day = 0,
            .acquisition_type = .initial,
            .prior_owner_key = faction_key,
        });
        _ = i;
    }

    var rng = rng_mod.Rng.init(7204);
    try disperseEnemyWrecks(&gs, gs.allocator(), wrecks, .{ .merc_company = merc_id }, battle_day, "galatea", &rng);

    const roster = gs.merc_company_rosters.get(merc_id).?;
    try testing.expectEqual(@as(usize, n), roster.items.len);
    for (wrecks) |hid| {
        const inst = gs.hull_instances.getPtr(hid).?;
        try testing.expectEqual(hull_instance_mod.OwnerType.merc_company, std.meta.activeTag(inst.owner));
    }
    try testing.expect(gs.faction_rosters.get(faction_key) == null);
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
        if (disperseEnemyWrecks(&gs, gs.allocator(), wrecks, .{ .faction = faction_key }, battle_day, battle_planet, &rng)) |_| {
            // Success: state must have changed.
            try testing.expect(digest.stateHash(&gs) != before);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(before, digest.stateHash(&gs));
        }
    }
}

test "buyerEligible: black_market flag and available_after window gates (buyer-independent)" {
    // Rule 67: buyerEligible gates (1) black_market flag and (2) available_after
    // window are buyer-independent and evaluated before reach. Table exercises
    // each gate independently. The reach dimension is covered by the dedicated
    // reach tests below.
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

    for (cases) |c| {
        if (c.want) {
            // want=true: use a PER world with .pirate buyer so reach is satisfied.
            // Isolates gates (1) and (2) from the reach dimension.
            const listing = market.Listing{
                .kind = .unit,
                .item_key = "SHD-2H",
                .rarity = .common,
                .price = 0,
                .black_market = c.black_market,
                .available_after = c.available_after,
                .planet_key = "antallos",
            };
            try std.testing.expectEqual(c.want, buyerEligible(&gs, listing, .pirate, current_day));
        } else {
            // want=false: these rows fail at gate (1) or (2), before reach.
            // Buyer-independent: verify all three buyer kinds return false.
            const buyers = [_]BuyerKind{ .player, .pirate, .merc_company };
            const listing = market.Listing{
                .kind = .unit,
                .item_key = "SHD-2H",
                .rarity = .common,
                .price = 0,
                .black_market = c.black_market,
                .available_after = c.available_after,
            };
            for (buyers) |buyer| {
                try std.testing.expectEqual(c.want, buyerEligible(&gs, listing, buyer, current_day));
            }
        }
    }
}

test "buyerEligible: pirate reaches PER worlds, merc companies reach non-PER worlds" {
    // Rule 67: reach-rule table. For each of the eight black-market worlds,
    // pirate→PER only; merc_company→non-PER only (disjoint sets). One invariant,
    // one table (test proportionality). gs not needed for these two buyer kinds.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57101 });
    defer gs.deinit();

    const current_day: u32 = 100;
    const Row = struct { key: []const u8, is_per: bool };
    const worlds = [_]Row{
        .{ .key = "antallos", .is_per = true },
        .{ .key = "tortuga_prime", .is_per = true },
        .{ .key = "star_s_end", .is_per = true },
        .{ .key = "herotitus", .is_per = true },
        .{ .key = "galatea", .is_per = false },
        .{ .key = "solaris7", .is_per = false },
        .{ .key = "outreach", .is_per = false },
        .{ .key = "canopus4", .is_per = false },
    };

    for (worlds) |w| {
        const listing = market.Listing{
            .kind = .unit,
            .item_key = "SHD-2H",
            .rarity = .common,
            .price = 0,
            .black_market = true,
            .available_after = 0,
            .planet_key = w.key,
        };
        try std.testing.expectEqual(w.is_per, buyerEligible(&gs, listing, .pirate, current_day));
        try std.testing.expectEqual(!w.is_per, buyerEligible(&gs, listing, .merc_company, current_day));
    }
}

test "buyerEligible: player reaches HQ worlds and active-contract worlds only" {
    // Rule 67: player reach branches. HQ world → true; active-contract deployed
    // world → true; unrelated world → false; transit contract (non-active) → false.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57102 });
    defer gs.deinit();

    const current_day: u32 = 100;
    const hq_id: types.HqId = @enumFromInt(1);
    const contract_id: types.ContractId = @enumFromInt(1);
    const transit_id: types.ContractId = @enumFromInt(2);
    const force_id: types.ForceId = @enumFromInt(1);

    // HQ on galatea.
    try gs.hqs.put(gs.allocator(), hq_id, .{
        .id = hq_id,
        .name = "Test HQ",
        .tier = .field,
        .planet_key = "galatea",
    });
    // Active contract with a deployed company on solaris7.
    try gs.contracts.put(gs.allocator(), contract_id, .{
        .id = contract_id,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "Bandits",
        .planet_key = "solaris7",
        .terms = .{ .length_months = 6, .base_pay_month = 0 },
        .status = .active,
        .assigned_company = force_id,
    });
    // Transit contract on outreach: transit != active → no reach.
    try gs.contracts.put(gs.allocator(), transit_id, .{
        .id = transit_id,
        .kind = .garrison_duty,
        .employer_key = "FWL",
        .enemy_key = "Bandits",
        .planet_key = "outreach",
        .terms = .{ .length_months = 6, .base_pay_month = 0 },
        .status = .transit,
        .assigned_company = force_id,
    });

    const mkL = struct {
        fn f(pk: []const u8) market.Listing {
            return .{ .kind = .unit, .item_key = "SHD-2H", .rarity = .common, .price = 0, .black_market = true, .available_after = 0, .planet_key = pk };
        }
    }.f;

    // HQ world: reachable.
    try std.testing.expect(buyerEligible(&gs, mkL("galatea"), .player, current_day));
    // Active-contract deployed world: reachable.
    try std.testing.expect(buyerEligible(&gs, mkL("solaris7"), .player, current_day));
    // Unrelated world: not reachable.
    try std.testing.expect(!buyerEligible(&gs, mkL("antallos"), .player, current_day));
    // Transit contract world (non-active): not reachable.
    try std.testing.expect(!buyerEligible(&gs, mkL("outreach"), .player, current_day));
}

test "runNpcBlackMarketDraw: pirates consume only PER-world listings, mercs only non-PER; asset-safety" {
    // Rule 67: consumer-agreement test. Seed 2 PER-world listings (antallos)
    // and 2 non-PER listings (galatea). Pirates (reach: PER only) take the
    // first; mercs (reach: non-PER only) take the second. Asset-safety: player
    // funds unchanged (rule 67, P3f.3 §7).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57103 });
    defer gs.deinit();

    // One merc company so buyers_buf includes a merc entry.
    const merc_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), merc_id, .{ .id = merc_id });

    const day: u32 = 30;
    gs.clock.day_index = day;

    // Seed 4 hull instances: 0–1 will back PER listings, 2–3 non-PER.
    var hull_ids: [4]types.HullInstanceId = undefined;
    for (0..4) |i| {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        hull_ids[i] = hid;
        try gs.hull_instances.put(gs.allocator(), hid, .{
            .id = hid,
            .base_key = "LCT-1V",
            .owner = .market,
            .status = .active,
        });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = 0,
            .acquisition_type = .transfer,
            .prior_owner_key = "DC",
        });
    }

    // Build listings: hull_ids[0,1] on "antallos" (PER), hull_ids[2,3] on "galatea" (non-PER).
    for (0..4) |i| {
        const pk: []const u8 = if (i < 2) "antallos" else "galatea";
        const lid: types.ListingId = @enumFromInt(gs.next_listing_id);
        gs.next_listing_id += 1;
        try gs.market_listings.append(gs.allocator(), .{
            .kind = .unit,
            .item_key = "LCT-1V",
            .rarity = .common,
            .price = 0,
            .black_market = true,
            .available_after = 0,
            .planet_key = pk,
            .hull_instance_id = hull_ids[i],
            .id = lid,
        });
    }

    const funds_before = gs.funds;

    try runNpcBlackMarketDraw(&gs);

    // Asset-safety: player funds unchanged.
    try std.testing.expectEqual(funds_before, gs.funds);

    // Pirate (PER) roster: every hull came from a PER-world listing (hull_ids[0] or [1]).
    if (gs.faction_rosters.get("PER")) |per_roster| {
        for (per_roster.items) |hid| {
            try std.testing.expect(hid == hull_ids[0] or hid == hull_ids[1]);
        }
    }

    // Merc company roster: every hull came from a non-PER listing (hull_ids[2] or [3]).
    if (gs.merc_company_rosters.get(merc_id)) |merc_roster| {
        for (merc_roster.items) |hid| {
            try std.testing.expect(hid == hull_ids[2] or hid == hull_ids[3]);
        }
    }

    // No PER-world hull in merc roster; no non-PER hull in pirate roster.
    if (gs.faction_rosters.get("PER")) |per_roster| {
        for (per_roster.items) |hid| {
            try std.testing.expect(hid != hull_ids[2] and hid != hull_ids[3]);
        }
    }
    if (gs.merc_company_rosters.get(merc_id)) |merc_roster| {
        for (merc_roster.items) |hid| {
            try std.testing.expect(hid != hull_ids[0] and hid != hull_ids[1]);
        }
    }
}

test "runNpcBlackMarketDraw: dissolved merc companies do not buy listings" {
    var gs = GameState.init(testing.allocator, .{ .seed = 57104 });
    defer gs.deinit();

    const merc_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), merc_id, .{ .id = merc_id, .dissolved_day = 1 });
    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hid, .{ .id = hid, .base_key = "LCT-1V", .owner = .market });
    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "LCT-1V",
        .rarity = .common,
        .price = 0,
        .black_market = true,
        .planet_key = "galatea",
        .hull_instance_id = hid,
    });

    try runNpcBlackMarketDraw(&gs);

    try testing.expectEqual(@as(usize, 1), gs.market_listings.items.len);
    try testing.expectEqual(hull_instance_mod.OwnerType.market, std.meta.activeTag(gs.hull_instances.getPtr(hid).?.owner));
    try testing.expect(gs.merc_company_rosters.get(merc_id) == null);
}
