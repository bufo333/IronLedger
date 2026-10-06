//! Merc-company lifecycle: monthly liquidation of insolvent or bankrupt
//! companies, hull-buy toward full strength, and replacement spawn.
//! Design: docs/p3f-faction-loop-design.md §5.
//! No MekHQ counterpart (docs/mekhq-map.md).
//! Pure: no I/O, no wall clock, no global state (ARCH rule 2).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const rng_mod = @import("rng.zig");
const market = @import("../econ/market.zig");
const chassis_mod = @import("../domain/chassis.zig");
const part_mod = @import("../domain/part.zig");
const hull_instance_mod = @import("../domain/hull_instance.zig");
const rivals = @import("rivals.zig");
const roster_gen = @import("../gen/roster_gen.zig");
const rival_mod = @import("../domain/rival.zig");
const faction_mod = @import("../domain/faction.zig");
const black_market = @import("black_market.zig");
const merc_company_mod = @import("../domain/merc_company.zig");
const logo = @import("../domain/logo.zig");
const logo_name = @import("../gen/logo_name.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

/// Single owner of merc-company liquidation (rule 20/76).
/// Deterministic, no RNG. Transfers every hull in the company's roster to
/// `.market` ownership and appends a regular (non-black-market) listing at
/// factory-fresh pricing. Sets `dissolved_day` to `day`.
///
/// Failure-atomic (rules 7, 11-13): reserve phase is entirely fallible;
/// commit phase is infallible. On OOM the caller's stateHash is unchanged.
pub fn liquidateMercCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    company_id: types.MercCompanyId,
    day: u32,
) !void {
    const mc = gs.merc_companies.getPtr(company_id) orelse return;
    const listing_days = tuning.market.faction_surplus_listing_days;

    // Prepare: count roster length.
    const roster_len: usize = if (gs.merc_company_rosters.get(company_id)) |r| r.items.len else 0;

    // Reserve capacity for all mutations before any commit.
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, roster_len);
    try gs.market_listings.ensureUnusedCapacity(alloc, roster_len);

    // Pre-build listings (no gs mutation yet).
    const built_listings = try alloc.alloc(market.Listing, roster_len);
    const mc_faction_key = mc.faction_key; // static catalog memory or arena — no dupe needed

    if (roster_len > 0) {
        const roster = gs.merc_company_rosters.get(company_id).?;
        var next_lid = gs.next_listing_id;
        for (roster.items, 0..) |hid, i| {
            const inst = gs.hull_instances.getPtr(hid) orelse continue;
            const ch = chassis_mod.find(inst.base_key) orelse continue;
            // Compute avg weapon cost (docs/p3f-faction-loop-design.md §3.4 // TUNE).
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
            const factory_cond: market.HullCondition = .{
                .armor_pct = 100,
                .quality = .f,
                .damaged_slots = 0,
                .destroyed_slots = 0,
                .missing_components = 0,
            };
            const lid: types.ListingId = @enumFromInt(next_lid);
            next_lid += 1;
            built_listings[i] = .{
                .kind = .unit,
                .item_key = ch.key,
                .rarity = ch.rarity,
                .price = market.hullPrice(ch.cost, avg_weapon, factory_cond, 10_000),
                .id = lid,
                .black_market = false,
                .hq = .none,
                .planet_key = "",
                .condition = null,
                .listed_day = day,
                .expires_day = day + listing_days,
                .hull_instance_id = hid,
            };
        }
    }

    // Commit (infallible from here).
    if (roster_len > 0) {
        const roster = gs.merc_company_rosters.getPtr(company_id).?;
        for (roster.items, 0..) |hid, i| {
            const inst = gs.hull_instances.getPtr(hid) orelse continue;
            _ = chassis_mod.find(inst.base_key) orelse continue;
            // Transfer ownership: merc_company → market.
            inst.owner = .market;
            // Close the open ownership interval.
            for (gs.hull_ownership_history.items) |*h| {
                if (h.hull_instance_id == hid and h.to_day == 0) h.to_day = day;
            }
            // Open a transfer interval naming the company's faction as prior owner.
            gs.hull_ownership_history.appendAssumeCapacity(.{
                .hull_instance_id = hid,
                .from_day = day,
                .to_day = 0,
                .acquisition_type = .transfer,
                .prior_owner_key = mc_faction_key, // static key — no dupe needed
            });
            gs.market_listings.appendAssumeCapacity(built_listings[i]);
        }
        roster.clearRetainingCapacity();
        gs.next_listing_id += @intCast(roster_len);
    }
    gs.merc_companies.getPtr(company_id).?.dissolved_day = day;
}

/// Single owner of "buy eligible hulls toward full strength" (rule 20/76).
/// Shared by `spawnReplacementCompany` and the monthly `runMercLifecycle` tick.
///
/// Target T = tuning.generation.merc_company_hulls_each. If the company's
/// current roster length >= T, returns immediately (no-op). Draws eligible
/// listings from `gs.market_listings` (unit listings with a HullInstance,
/// reachable by the company per `black_market.buyerEligible` or non-black-market),
/// until T hulls are held or the affordable-eligible set is exhausted.
///
/// Does NOT write `gs.rng` — the caller commits the rng copy.
/// Failure-atomic (rules 7, 11-13).
pub fn buyHullsForCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    company_id: types.MercCompanyId,
    day: u32,
    rng: *rng_mod.Rng,
) !void {
    const T = tuning.generation.merc_company_hulls_each;
    const mc = gs.merc_companies.getPtr(company_id) orelse return;

    const current_n: usize = if (gs.merc_company_rosters.get(company_id)) |r| r.items.len else 0;
    if (current_n >= T) return;

    // Build the eligible-listing index set (no gs mutation; uses arena allocator).
    var elig: std.ArrayListUnmanaged(usize) = .empty;
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.kind != .unit) continue;
        if (l.hull_instance_id == .none) continue;
        const eligible = !l.black_market or black_market.buyerEligible(gs, l, .merc_company, day);
        if (eligible) try elig.append(alloc, i);
    }

    // Draw-and-plan: collect purchase plan from the eligible set.
    var cb = mc.cbills;
    var want: usize = T - current_n;
    const Plan = struct { listing_idx: usize };
    var plan: std.ArrayListUnmanaged(Plan) = .empty;
    while (want > 0 and elig.items.len > 0) {
        const j = rng.random(.market).uintLessThan(usize, elig.items.len);
        const li = elig.items[j];
        const listing = gs.market_listings.items[li];
        if (listing.price <= cb) {
            try plan.append(alloc, .{ .listing_idx = li });
            cb -= listing.price;
            want -= 1;
        }
        // An unaffordable draw is consumed from the working set (matches runNpcBlackMarketDraw).
        _ = elig.swapRemove(j);
    }

    if (plan.items.len == 0) return;

    // Reserve capacity.
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, plan.items.len);
    try gs.merc_company_rosters.ensureUnusedCapacity(alloc, 1);
    const gop = try gs.merc_company_rosters.getOrPut(alloc, company_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.ensureUnusedCapacity(alloc, plan.items.len);

    // Commit (infallible).
    var total_spent: types.CBills = 0;
    for (plan.items) |entry| {
        const l = gs.market_listings.items[entry.listing_idx];
        const hid = l.hull_instance_id;
        const inst = gs.hull_instances.getPtr(hid).?;
        inst.owner = .{ .merc_company = company_id };
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
        gs.merc_company_rosters.getPtr(company_id).?.appendAssumeCapacity(hid);
        total_spent += l.price;
    }
    gs.merc_companies.getPtr(company_id).?.cbills -= total_spent;

    // Remove consumed listings by descending index (as runNpcBlackMarketDraw does).
    std.mem.sort(Plan, plan.items, {}, struct {
        fn desc(_: void, a: Plan, b: Plan) bool {
            return a.listing_idx > b.listing_idx;
        }
    }.desc);
    for (plan.items) |entry| {
        _ = gs.market_listings.orderedRemove(entry.listing_idx);
    }
}

/// Single owner of replacement merc company spawn (rule 20/76).
/// Draws the next archetype and hiring faction in the same order as
/// `seedMercCompanies`. Picks the first logo from `logo.all_keys` not held
/// by any active (dissolved_day == 0) company. Sets cbills to
/// `merc_replacement_cbill_floor` and calls `buyHullsForCompany` to form
/// the hull pool from market supply.
///
/// Does NOT write `gs.rng` — the caller commits the rng copy.
pub fn spawnReplacementCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    day: u32,
    rng: *rng_mod.Rng,
) !void {
    const tg = tuning.generation;

    // Collect hiring factions (static catalog, stack-local; max 32 as in roster_seed).
    var hiring_faction_idx: [32]usize = undefined;
    var num_hiring: usize = 0;
    for (faction_mod.table, 0..) |*f, i| {
        if (f.hires) {
            hiring_faction_idx[num_hiring] = i;
            num_hiring += 1;
        }
    }
    if (num_hiring == 0) return;

    // Draw archetype and hiring faction on .rivals stream (same order as seedMercCompanies).
    const archetype_idx = rng.random(.rivals).uintLessThan(usize, rival_mod.table.archetypes.len);
    const archetype = &rival_mod.table.archetypes[archetype_idx];
    const fi = hiring_faction_idx[rng.random(.rivals).uintLessThan(usize, num_hiring)];
    const f = &faction_mod.table[fi];

    // Draw identity.
    const identity = roster_gen.rollMercCompanyIdentity(rng, .rivals, archetype, f.key);

    // Pick the first logo key not held by any active company.
    var chosen_logo: []const u8 = "";
    for (logo.all_keys) |key| {
        var held = false;
        var mc_it = gs.merc_companies.iterator();
        while (mc_it.next()) |entry| {
            const mc = entry.value_ptr;
            if (mc.dissolved_day == 0 and std.mem.eql(u8, mc.logo_key, key)) {
                held = true;
                break;
            }
        }
        if (!held) {
            chosen_logo = key; // static all_keys memory — no dupe needed
            break;
        }
    }

    // Allocate unit_name (arena lifetime = campaign lifetime).
    const unit_name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ identity.last, archetype.unit_noun });

    const new_id: types.MercCompanyId = @enumFromInt(gs.next_merc_company_id);

    // Reserve map capacity before insert.
    try gs.merc_companies.ensureUnusedCapacity(alloc, 1);

    // Commit.
    gs.merc_companies.putAssumeCapacity(new_id, merc_company_mod.MercCompany{
        .id = new_id,
        .archetype_key = archetype.key, // static catalog memory
        .commander_first = identity.first, // static names table memory
        .commander_last = identity.last, // static names table memory
        .unit_name = unit_name,
        .faction_key = f.key, // static catalog memory
        .side = identity.side,
        .doctrine = identity.doctrine,
        .cbills = tg.merc_replacement_cbill_floor,
        .founded_day = day,
        .dissolved_day = 0,
        .logo_key = chosen_logo,
    });
    gs.next_merc_company_id += 1;

    // Buy hulls from market supply toward full strength.
    try buyHullsForCompany(gs, alloc, new_id, day, rng);
}

/// Monthly lifecycle pass (rule 76/77; docs/p3f-faction-loop-design.md §5).
/// For each pre-existing company:
///   - Skip already-dissolved companies.
///   - If insolvent (mercCompanyInsolvent) or bankrupt (cbills < 0): liquidate
///     then spawn a replacement.
///   - Else if under strength (roster.len < merc_company_hulls_each): buy
///     hulls toward full strength.
///
/// Draw order: companies iterated by insertion index (stable under append;
/// existing indices do not move when spawn appends). Replacements appended
/// this pass are skipped (only `initial` companies are processed).
/// RNG committed per company action (bounded non-atomicity on OOM, matching
/// `faction_surplus.runMonthly`'s per-iteration model).
pub fn runMercLifecycle(gs: *GameState) !void {
    const alloc = gs.allocator();
    const day = gs.clock.day_index;
    const initial = gs.merc_companies.count();

    for (0..initial) |i| {
        const id = gs.merc_companies.keys()[i];
        const mc = gs.merc_companies.getPtr(id).?;
        if (mc.dissolved_day != 0) continue;

        if (rivals.mercCompanyInsolvent(gs, id) or mc.cbills < 0) {
            var rc = gs.rng;
            try liquidateMercCompany(gs, alloc, id, day);
            try spawnReplacementCompany(gs, alloc, day, &rc);
            gs.rng = rc;
        } else {
            const roster_len: usize = if (gs.merc_company_rosters.get(id)) |r| r.items.len else 0;
            if (roster_len < tuning.generation.merc_company_hulls_each) {
                var rc = gs.rng;
                try buyHullsForCompany(gs, alloc, id, day, &rc);
                gs.rng = rc;
            }
        }
    }
}

// ---- Tests -----------------------------------------------------------------

const digest = @import("digest.zig");
const founding = @import("founding.zig");

test "liquidateMercCompany: transfers hulls to market, clears roster, sets dissolved_day" {
    // Rule 67: each hull becomes .market-owned with a regular (non-black-market) listing;
    // roster is cleared; dissolved_day == day; next_listing_id advanced by N.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 1001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();

    const mcid: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, mcid, merc_company_mod.MercCompany{
        .id = mcid,
        .archetype_key = "enemy_raiders",
        .unit_name = "Doomed Co",
        .faction_key = "DC",
        .dissolved_day = 0,
    });

    const N: usize = 3;
    var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    for (0..N) |i| {
        const hid: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(alloc, hid, .{
            .id = hid,
            .base_key = "LCT-1V",
            .status = .active,
            .owner = .{ .merc_company = mcid },
        });
        gs.hull_ownership_history.append(alloc, .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = 0,
            .acquisition_type = .initial,
            .prior_owner_key = "DC",
        }) catch @panic("OOM");
        try roster.append(alloc, hid);
    }
    try gs.merc_company_rosters.put(alloc, mcid, roster);
    gs.next_merc_company_id = 2;
    gs.next_hull_instance_id = @intCast(N + 1);

    const before_lid = gs.next_listing_id;
    try liquidateMercCompany(&gs, alloc, mcid, 30);

    // dissolved_day set.
    try std.testing.expectEqual(@as(u32, 30), gs.merc_companies.getPtr(mcid).?.dissolved_day);
    // Roster is cleared.
    try std.testing.expectEqual(@as(usize, 0), gs.merc_company_rosters.get(mcid).?.items.len);
    // next_listing_id advanced by N.
    try std.testing.expectEqual(before_lid + N, gs.next_listing_id);
    // Every hull is now .market-owned with a regular listing.
    for (0..N) |i| {
        const hid: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        const inst = gs.hull_instances.getPtr(hid).?;
        try std.testing.expectEqual(hull_instance_mod.HullOwner.market, inst.owner);
    }
    try std.testing.expectEqual(N, gs.market_listings.items.len);
    for (gs.market_listings.items) |l| {
        try std.testing.expect(!l.black_market);
        try std.testing.expect(l.hull_instance_id != .none);
    }
}

test "liquidateMercCompany: OOM atomicity — stateHash unchanged on failure" {
    // Rule 69: a failing allocator injected at index 0 leaves stateHash unchanged
    // (all reserve allocations are in the prepare phase; commit is infallible).
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 1002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();

    const mcid: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, mcid, merc_company_mod.MercCompany{
        .id = mcid,
        .archetype_key = "enemy_raiders",
        .unit_name = "Doomed Co",
        .faction_key = "DC",
        .dissolved_day = 0,
    });
    const hid: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V", .owner = .{ .merc_company = mcid } });
    try gs.hull_ownership_history.append(alloc, .{
        .hull_instance_id = hid,
        .from_day = 0,
        .to_day = 0,
        .acquisition_type = .initial,
        .prior_owner_key = "DC",
    });
    var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    try roster.append(alloc, hid);
    try gs.merc_company_rosters.put(alloc, mcid, roster);

    const hash_before = digest.stateHash(&gs);
    // Fail the very first allocation (the built_listings slice in the reserve phase).
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const result = liquidateMercCompany(&gs, failing.allocator(), mcid, 30);
    try std.testing.expectError(error.OutOfMemory, result);
    // State must be unchanged.
    try std.testing.expectEqual(hash_before, digest.stateHash(&gs));
}

test "buyHullsForCompany: buys affordable+eligible hulls, spends cbills, asset-safe" {
    // Rule 67: buys only affordable+eligible hulls, spends cbills exactly,
    // leaves company under strength if market is thin, touches no player assets.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();

    const mcid: types.MercCompanyId = @enumFromInt(1);
    const cbills_start: types.CBills = 10_000_000;
    try gs.merc_companies.put(alloc, mcid, merc_company_mod.MercCompany{
        .id = mcid,
        .archetype_key = "enemy_raiders",
        .unit_name = "Buying Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .cbills = cbills_start,
    });

    // Add 2 affordable regular listings (< cbills) and 1 unaffordable.
    const h1: types.HullInstanceId = @enumFromInt(1);
    const h2: types.HullInstanceId = @enumFromInt(2);
    const h3: types.HullInstanceId = @enumFromInt(3);
    try gs.hull_instances.put(alloc, h1, .{ .id = h1, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_instances.put(alloc, h2, .{ .id = h2, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_instances.put(alloc, h3, .{ .id = h3, .base_key = "JR7-D", .owner = .market });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = h1, .from_day = 0, .to_day = 0, .acquisition_type = .transfer, .prior_owner_key = "market" });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = h2, .from_day = 0, .to_day = 0, .acquisition_type = .transfer, .prior_owner_key = "market" });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = h3, .from_day = 0, .to_day = 0, .acquisition_type = .transfer, .prior_owner_key = "market" });
    const cheap_price: types.CBills = 500_000;
    const expensive_price: types.CBills = 50_000_000; // unaffordable
    try gs.market_listings.append(alloc, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = cheap_price, .id = @enumFromInt(1), .hull_instance_id = h1, .black_market = false });
    try gs.market_listings.append(alloc, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = cheap_price, .id = @enumFromInt(2), .hull_instance_id = h2, .black_market = false });
    try gs.market_listings.append(alloc, .{ .kind = .unit, .item_key = "JR7-D", .rarity = .uncommon, .price = expensive_price, .id = @enumFromInt(3), .hull_instance_id = h3, .black_market = false });
    gs.next_listing_id = 4;

    const initial_funds = gs.funds;
    var rng_copy = gs.rng;
    try buyHullsForCompany(&gs, alloc, mcid, 1, &rng_copy);

    // Bought the two affordable hulls; player funds unchanged.
    const mc = gs.merc_companies.getPtr(mcid).?;
    const roster = gs.merc_company_rosters.get(mcid) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), roster.items.len);
    try std.testing.expectEqual(cbills_start - 2 * cheap_price, mc.cbills);
    try std.testing.expectEqual(initial_funds, gs.funds);
    // Company is still under strength (2 < merc_company_hulls_each=8).
    try std.testing.expect(roster.items.len < tuning.generation.merc_company_hulls_each);
}

test "buyHullsForCompany: OOM atomicity — stateHash unchanged on failure" {
    // Rule 69: a failing allocator at index 0 leaves stateHash unchanged.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();

    const mcid: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, mcid, merc_company_mod.MercCompany{
        .id = mcid,
        .archetype_key = "enemy_raiders",
        .unit_name = "Buying Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .cbills = 10_000_000,
    });
    const h1: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(alloc, h1, .{ .id = h1, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = h1, .from_day = 0, .to_day = 0, .acquisition_type = .transfer, .prior_owner_key = "market" });
    try gs.market_listings.append(alloc, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 500_000, .id = @enumFromInt(1), .hull_instance_id = h1, .black_market = false });

    const hash_before = digest.stateHash(&gs);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var rng = gs.rng;
    const result = buyHullsForCompany(&gs, failing.allocator(), mcid, 1, &rng);
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(hash_before, digest.stateHash(&gs));
}

test "spawnReplacementCompany: unique id, founded_day, dissolved_day==0, cbills==floor, logo distinct from active" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();

    // Seed one active company with the first logo key to verify the spawn picks a different one.
    const existing_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, existing_id, merc_company_mod.MercCompany{
        .id = existing_id,
        .archetype_key = "enemy_raiders",
        .unit_name = "Existing Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .logo_key = logo.all_keys[0],
    });
    gs.next_merc_company_id = 2;

    var rng = gs.rng;
    try spawnReplacementCompany(&gs, alloc, 60, &rng);

    // A new company was added.
    try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
    const new_id: types.MercCompanyId = @enumFromInt(2);
    const spawned = gs.merc_companies.getPtr(new_id) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 60), spawned.founded_day);
    try std.testing.expectEqual(@as(u32, 0), spawned.dissolved_day);
    try std.testing.expectEqual(tuning.generation.merc_replacement_cbill_floor, spawned.cbills);
    // Logo is not the one held by the existing active company.
    try std.testing.expect(!std.mem.eql(u8, spawned.logo_key, logo.all_keys[0]));
    // next_merc_company_id advanced.
    try std.testing.expectEqual(@as(u32, 3), gs.next_merc_company_id);
}

test "runMercLifecycle: (a) insolvent company liquidated+replaced, active count held; dissolved record persists" {
    // Rule 67/D-A: dissolved company stays in gs.merc_companies with dissolved_day != 0.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();
    gs.clock.advance(); // day_index = 1 (ensures we are past day 0)

    // Seed one insolvent company: has a roster but BV < threshold.
    const mc_insolvent: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, mc_insolvent, merc_company_mod.MercCompany{
        .id = mc_insolvent,
        .archetype_key = "enemy_raiders",
        .unit_name = "Insolvent Raiders",
        .faction_key = "DC",
        .dissolved_day = 0,
        .logo_key = logo.all_keys[0],
    });
    const h_bad: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(alloc, h_bad, .{ .id = h_bad, .base_key = "LCT-1V", .owner = .{ .merc_company = mc_insolvent } });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = h_bad, .from_day = 0, .to_day = 0, .acquisition_type = .initial, .prior_owner_key = "DC" });
    var r_bad: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    try r_bad.append(alloc, h_bad);
    try gs.merc_company_rosters.put(alloc, mc_insolvent, r_bad);
    gs.next_merc_company_id = 2;
    gs.next_hull_instance_id = 2;

    const before_active: usize = 1;
    try runMercLifecycle(&gs);

    // Dissolved record persists.
    try std.testing.expect(gs.merc_companies.contains(mc_insolvent));
    try std.testing.expect(gs.merc_companies.getPtr(mc_insolvent).?.dissolved_day != 0);

    // Active count is unchanged (one dissolved + one spawned = same active count).
    var active_count: usize = 0;
    var it = gs.merc_companies.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.dissolved_day == 0) active_count += 1;
    }
    try std.testing.expectEqual(before_active, active_count);
}

test "runMercLifecycle: (b) bankrupt company (cbills < 0) triggers liquidation even if not insolvent" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();
    gs.clock.advance();

    // A company with negative cbills but BV above the insolvency threshold.
    const mc_bankrupt: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, mc_bankrupt, merc_company_mod.MercCompany{
        .id = mc_bankrupt,
        .archetype_key = "enemy_raiders",
        .unit_name = "Bankrupt Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .cbills = -1,
        .logo_key = logo.all_keys[0],
    });
    // Give it enough BV to be solvent (above 2000 threshold).
    for (0..5) |i| {
        const hid: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V", .owner = .{ .merc_company = mc_bankrupt } });
        try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = hid, .from_day = 0, .to_day = 0, .acquisition_type = .initial, .prior_owner_key = "DC" });
    }
    // BV = 5 * 432 = 2160 >= 2000 (solvent by mercCompanyInsolvent definition).
    var rb: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    for (0..5) |i| try rb.append(alloc, @enumFromInt(1 + @as(u32, @intCast(i))));
    try gs.merc_company_rosters.put(alloc, mc_bankrupt, rb);
    gs.next_merc_company_id = 2;
    gs.next_hull_instance_id = 6;

    try runMercLifecycle(&gs);

    // Bankrupt company is dissolved despite being BV-solvent.
    try std.testing.expect(gs.merc_companies.getPtr(mc_bankrupt).?.dissolved_day != 0);
}

test "runMercLifecycle: (c) determinism — two same-seed campaigns hash equal after lifecycle" {
    const a = std.testing.allocator;
    var gs1 = GameState.init(a, .{ .seed = 4003 });
    defer gs1.deinit();
    var gs2 = GameState.init(a, .{ .seed = 4003 });
    defer gs2.deinit();

    // Build identical states on both.
    for ([_]*GameState{ &gs1, &gs2 }) |gs| {
        _ = try founding.createCommander(gs, "T", .LC, .line_officer);
        const alloc2 = gs.allocator();
        gs.clock.advance();

        const mc1: types.MercCompanyId = @enumFromInt(1);
        try gs.merc_companies.put(alloc2, mc1, merc_company_mod.MercCompany{
            .id = mc1,
            .archetype_key = "enemy_raiders",
            .unit_name = "Insolvent Raiders",
            .faction_key = "DC",
            .dissolved_day = 0,
            .logo_key = logo.all_keys[0],
        });
        const h_bad: types.HullInstanceId = @enumFromInt(1);
        try gs.hull_instances.put(alloc2, h_bad, .{ .id = h_bad, .base_key = "LCT-1V", .owner = .{ .merc_company = mc1 } });
        try gs.hull_ownership_history.append(alloc2, .{ .hull_instance_id = h_bad, .from_day = 0, .to_day = 0, .acquisition_type = .initial, .prior_owner_key = "DC" });
        var r: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        try r.append(alloc2, h_bad);
        try gs.merc_company_rosters.put(alloc2, mc1, r);
        gs.next_merc_company_id = 2;
        gs.next_hull_instance_id = 2;
    }

    try runMercLifecycle(&gs1);
    try runMercLifecycle(&gs2);

    try std.testing.expectEqual(digest.stateHash(&gs1), digest.stateHash(&gs2));
}
