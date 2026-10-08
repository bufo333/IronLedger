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
    _: std.mem.Allocator,
    company_id: types.MercCompanyId,
    day: u32,
) !void {
    if (!gs.merc_companies.contains(company_id)) return;
    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    var next_listing_id = gs.next_listing_id;
    const listings = try planLiquidation(transaction_alloc, gs, company_id, day, &next_listing_id);
    const actions = [_]LifecycleAction{.{ .liquidate = .{
        .company_id = company_id,
        .listings = listings,
    } }};
    const stage = try stageLifecycleCommit(gs, transaction_alloc, &actions, next_listing_id, gs.next_merc_company_id, day);
    gs.replaceLifecycleArena(transaction_arena);
    commitLifecycleStage(gs, stage);
}

/// Single owner of "buy eligible hulls toward full strength" (rule 20/76).
/// Uses the same purchase plan and staged lifecycle commit as replacement spawn
/// and the monthly `runMercLifecycle` tick.
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
    const company = gs.merc_companies.get(company_id) orelse return;
    const roster_len = if (gs.merc_company_rosters.get(company_id)) |roster| roster.items.len else 0;
    if (roster_len >= tuning.generation.merc_company_hulls_each) return;

    var scratch_arena = std.heap.ArenaAllocator.init(alloc);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var listings = std.ArrayListUnmanaged(PlannedListing).empty;
    try listings.ensureTotalCapacity(scratch, gs.market_listings.items.len);
    for (gs.market_listings.items) |listing| listings.appendAssumeCapacity(.{ .listing = listing });

    var planned_company = PlannedCompany{
        .id = company_id,
        .cbills = company.cbills,
        .roster_len = roster_len,
        .dissolved_day = company.dissolved_day,
        .logo_key = company.logo_key,
    };
    var rng_copy = rng.*;
    const buy = try planBuy(scratch, gs, &listings, &planned_company, day, &rng_copy);
    if (buy.purchases.len == 0) {
        rng.* = rng_copy;
        return;
    }

    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    const actions = [_]LifecycleAction{.{ .buy = buy }};
    const stage = try stageLifecycleCommit(gs, transaction_alloc, &actions, gs.next_listing_id, gs.next_merc_company_id, day);
    gs.replaceLifecycleArena(transaction_arena);
    commitLifecycleStage(gs, stage);
    rng.* = rng_copy;
}

/// Single owner of replacement merc company spawn (rule 20/76).
/// Draws the next archetype and hiring faction in the same order as
/// `seedMercCompanies`. Picks the first logo from `logo.all_keys` not held
/// by any active (dissolved_day == 0) company and never the player's reserved
/// `player_logo_key`. Sets cbills to `merc_replacement_cbill_floor` and uses
/// the shared purchase plan to form the hull pool from market supply.
///
/// Does NOT write `gs.rng` — the caller commits the rng copy.
pub fn spawnReplacementCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    day: u32,
    rng: *rng_mod.Rng,
) !types.MercCompanyId {
    var scratch_arena = std.heap.ArenaAllocator.init(alloc);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var listings = std.ArrayListUnmanaged(PlannedListing).empty;
    try listings.ensureTotalCapacity(scratch, gs.market_listings.items.len);
    for (gs.market_listings.items) |listing| listings.appendAssumeCapacity(.{ .listing = listing });
    var companies = std.ArrayListUnmanaged(PlannedCompany).empty;
    try companies.ensureTotalCapacity(scratch, gs.merc_companies.count() + 1);
    for (gs.merc_companies.keys(), gs.merc_companies.values()) |id, company| {
        companies.appendAssumeCapacity(.{
            .id = id,
            .cbills = company.cbills,
            .roster_len = if (gs.merc_company_rosters.get(id)) |roster| roster.items.len else 0,
            .dissolved_day = company.dissolved_day,
            .logo_key = company.logo_key,
        });
    }

    var rng_copy = rng.*;
    var next_company_id = gs.next_merc_company_id;
    const replacement = try planReplacement(scratch, gs, &companies, &listings, day, &rng_copy, &next_company_id);
    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    var actions = [_]LifecycleAction{.{ .spawn = replacement }};
    try allocateReplacementNames(transaction_alloc, &actions);
    const stage = try stageLifecycleCommit(gs, transaction_alloc, &actions, gs.next_listing_id, next_company_id, day);
    gs.replaceLifecycleArena(transaction_arena);
    commitLifecycleStage(gs, stage);
    rng.* = rng_copy;
    return replacement.company.id;
}

const PlannedListing = struct {
    listing: market.Listing,
    available: bool = true,
};

const PlannedCompany = struct {
    id: types.MercCompanyId,
    cbills: types.CBills,
    roster_len: usize,
    dissolved_day: u32,
    logo_key: []const u8,
};

const Purchase = struct {
    listing_index: usize,
    hull_instance_id: types.HullInstanceId,
    price: types.CBills,
};

const BuyPlan = struct {
    company_id: types.MercCompanyId,
    purchases: []const Purchase,
    remove_order: []const Purchase,
};

const ReplacementPlan = struct {
    company: merc_company_mod.MercCompany,
    unit_name_parts: struct { last: []const u8, noun: []const u8 },
    buy: ?BuyPlan,
};

const HullChange = struct {
    id: types.HullInstanceId,
    owner: hull_instance_mod.HullOwner,
    status: ?hull_instance_mod.HullStatus = null,
};

const LifecycleStage = struct {
    merc_companies: std.AutoArrayHashMapUnmanaged(types.MercCompanyId, merc_company_mod.MercCompany),
    merc_company_rosters: std.AutoArrayHashMapUnmanaged(types.MercCompanyId, std.ArrayListUnmanaged(types.HullInstanceId)),
    market_listings: std.ArrayListUnmanaged(market.Listing),
    hull_ownership_history: std.ArrayListUnmanaged(hull_instance_mod.HullOwnershipHistory),
    hull_changes: std.ArrayListUnmanaged(HullChange),
    next_listing_id: u32,
    next_merc_company_id: u32,
};

const LifecycleAction = union(enum) {
    buy: BuyPlan,
    liquidate: struct {
        company_id: types.MercCompanyId,
        listings: []const market.Listing,
    },
    spawn: ReplacementPlan,
    replace: struct {
        dissolved_id: types.MercCompanyId,
        liquidation_listings: []const market.Listing,
        replacement: ReplacementPlan,
    },
};

/// Monthly lifecycle pass (docs/p3f-faction-loop-design.md §5).
/// It stages the complete initial-company pass in reclaimable scratch memory,
/// then reserves persistent storage and commits every action with the staged
/// RNG state. Company iteration and draw order match the monthly lifecycle
/// rule; replacements are not processed until the next pass.
pub fn runMercLifecycle(gs: *GameState) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const day = gs.clock.day_index;
    const initial = gs.merc_companies.count();

    var listings = std.ArrayListUnmanaged(PlannedListing).empty;
    try listings.ensureTotalCapacity(scratch, gs.market_listings.items.len);
    for (gs.market_listings.items) |listing| listings.appendAssumeCapacity(.{ .listing = listing });

    var companies = std.ArrayListUnmanaged(PlannedCompany).empty;
    try companies.ensureTotalCapacity(scratch, gs.merc_companies.count());
    for (gs.merc_companies.keys(), gs.merc_companies.values()) |id, mc| {
        companies.appendAssumeCapacity(.{
            .id = id,
            .cbills = mc.cbills,
            .roster_len = if (gs.merc_company_rosters.get(id)) |roster| roster.items.len else 0,
            .dissolved_day = mc.dissolved_day,
            .logo_key = mc.logo_key,
        });
    }

    var actions = std.ArrayListUnmanaged(LifecycleAction).empty;
    var rng_copy = gs.rng;
    var next_listing_id = gs.next_listing_id;
    var next_company_id = gs.next_merc_company_id;

    for (0..initial) |i| {
        const company = &companies.items[i];
        if (company.dissolved_day != 0) continue;

        if (rivals.mercCompanyInsolvent(gs, company.id) or company.cbills < 0) {
            const liquidation_listings = try planLiquidation(scratch, gs, company.id, day, &next_listing_id);
            for (liquidation_listings) |listing| try listings.append(scratch, .{ .listing = listing });
            company.dissolved_day = day;

            const replacement = try planReplacement(
                scratch,
                gs,
                &companies,
                &listings,
                day,
                &rng_copy,
                &next_company_id,
            );
            try actions.append(scratch, .{ .replace = .{
                .dissolved_id = company.id,
                .liquidation_listings = liquidation_listings,
                .replacement = replacement,
            } });
        } else if (company.roster_len < tuning.generation.merc_company_hulls_each) {
            const buy = try planBuy(scratch, gs, &listings, company, day, &rng_copy);
            if (buy.purchases.len > 0) try actions.append(scratch, .{ .buy = buy });
        }
    }

    if (actions.items.len == 0) return;

    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    try allocateReplacementNames(transaction_alloc, actions.items);
    const stage = try stageLifecycleCommit(gs, transaction_alloc, actions.items, next_listing_id, next_company_id, day);
    gs.replaceLifecycleArena(transaction_arena);

    commitLifecycleStage(gs, stage);
    gs.rng = rng_copy;
}

fn planLiquidation(scratch: std.mem.Allocator, gs: *const GameState, company_id: types.MercCompanyId, day: u32, next_listing_id: *u32) ![]const market.Listing {
    const roster = gs.merc_company_rosters.get(company_id) orelse return &.{};
    var result = try scratch.alloc(market.Listing, roster.items.len);
    for (roster.items, 0..) |hid, i| {
        const inst = gs.hull_instances.get(hid).?;
        const ch = chassis_mod.find(inst.base_key).?;
        var weapon_value: types.CBills = 0;
        var weapon_count: u32 = 0;
        for (ch.loadout) |slot| if (slot.class == .weapon) {
            weapon_value += part_mod.cost(slot.part);
            weapon_count += 1;
        };
        const average_weapon = if (weapon_count > 0) @divTrunc(weapon_value, weapon_count) else 50_000;
        result[i] = .{
            .kind = .unit,
            .item_key = ch.key,
            .rarity = ch.rarity,
            .price = market.hullPrice(ch.cost, average_weapon, .{
                .armor_pct = 100,
                .quality = .f,
                .damaged_slots = 0,
                .destroyed_slots = 0,
                .missing_components = 0,
            }, 10_000),
            .id = @enumFromInt(next_listing_id.*),
            .black_market = false,
            .hq = .none,
            .planet_key = "",
            .listed_day = day,
            .expires_day = day + tuning.market.faction_surplus_listing_days,
            .hull_instance_id = hid,
        };
        next_listing_id.* += 1;
    }
    return result;
}

fn planReplacement(scratch: std.mem.Allocator, gs: *const GameState, companies: *std.ArrayListUnmanaged(PlannedCompany), listings: *std.ArrayListUnmanaged(PlannedListing), day: u32, rng: *rng_mod.Rng, next_company_id: *u32) !ReplacementPlan {
    var hiring_faction_idx: [32]usize = undefined;
    var num_hiring: usize = 0;
    for (faction_mod.table, 0..) |*f, i| if (f.hires) {
        hiring_faction_idx[num_hiring] = i;
        num_hiring += 1;
    };
    std.debug.assert(num_hiring > 0);

    const archetype = &rival_mod.table.archetypes[rng.random(.rivals).uintLessThan(usize, rival_mod.table.archetypes.len)];
    const faction = &faction_mod.table[hiring_faction_idx[rng.random(.rivals).uintLessThan(usize, num_hiring)]];
    const identity = roster_gen.rollMercCompanyIdentity(rng, .rivals, archetype, faction.key);
    var logo_key: []const u8 = "";
    for (logo.all_keys) |key| {
        if (gs.player_logo_key.len > 0 and std.mem.eql(u8, key, gs.player_logo_key)) continue;
        var held = false;
        for (companies.items) |company| if (company.dissolved_day == 0 and std.mem.eql(u8, company.logo_key, key)) {
            held = true;
            break;
        };
        if (!held) {
            logo_key = key;
            break;
        }
    }

    const id: types.MercCompanyId = @enumFromInt(next_company_id.*);
    next_company_id.* += 1;
    var company = PlannedCompany{ .id = id, .cbills = tuning.generation.merc_replacement_cbill_floor, .roster_len = 0, .dissolved_day = 0, .logo_key = logo_key };
    try companies.append(scratch, company);
    const buy = try planBuy(scratch, gs, listings, &company, day, rng);
    companies.items[companies.items.len - 1].roster_len = company.roster_len;
    companies.items[companies.items.len - 1].cbills = company.cbills;
    return .{
        .company = .{ .id = id, .archetype_key = archetype.key, .commander_first = identity.first, .commander_last = identity.last, .faction_key = faction.key, .side = identity.side, .doctrine = identity.doctrine, .cbills = tuning.generation.merc_replacement_cbill_floor, .founded_day = day, .logo_key = logo_key },
        .unit_name_parts = .{ .last = identity.last, .noun = archetype.unit_noun },
        .buy = if (buy.purchases.len > 0) buy else null,
    };
}

fn planBuy(scratch: std.mem.Allocator, gs: *const GameState, listings: *std.ArrayListUnmanaged(PlannedListing), company: *PlannedCompany, day: u32, rng: *rng_mod.Rng) !BuyPlan {
    var eligible = std.ArrayListUnmanaged(usize).empty;
    for (listings.items, 0..) |listing, i| {
        if (!listing.available or listing.listing.kind != .unit or listing.listing.hull_instance_id == .none) continue;
        if (!listing.listing.black_market or black_market.buyerEligible(gs, listing.listing, .merc_company, day)) try eligible.append(scratch, i);
    }
    var purchases = std.ArrayListUnmanaged(Purchase).empty;
    var cbills = company.cbills;
    var want = tuning.generation.merc_company_hulls_each - company.roster_len;
    while (want > 0 and eligible.items.len > 0) {
        const pick = rng.random(.market).uintLessThan(usize, eligible.items.len);
        const listing_index = eligible.items[pick];
        const listing = listings.items[listing_index].listing;
        if (listing.price <= cbills) {
            try purchases.append(scratch, .{ .listing_index = listing_index, .hull_instance_id = listing.hull_instance_id, .price = listing.price });
            listings.items[listing_index].available = false;
            cbills -= listing.price;
            want -= 1;
        }
        _ = eligible.swapRemove(pick);
    }
    company.cbills = cbills;
    company.roster_len += purchases.items.len;
    const remove_order = try scratch.dupe(Purchase, purchases.items);
    std.mem.sort(Purchase, remove_order, {}, struct {
        fn descending(_: void, a: Purchase, b: Purchase) bool {
            return a.listing_index > b.listing_index;
        }
    }.descending);
    return .{ .company_id = company.id, .purchases = try purchases.toOwnedSlice(scratch), .remove_order = remove_order };
}

fn allocateReplacementNames(alloc: std.mem.Allocator, actions: []LifecycleAction) !void {
    for (actions) |*action| switch (action.*) {
        .spawn => |*replacement| try allocateReplacementName(alloc, replacement),
        .replace => |*replace| {
            try allocateReplacementName(alloc, &replace.replacement);
        },
        .buy, .liquidate => {},
    };
}

fn allocateReplacementName(alloc: std.mem.Allocator, replacement: *ReplacementPlan) !void {
    replacement.company.unit_name = try std.fmt.allocPrint(
        alloc,
        "{s} {s}",
        replacement.unit_name_parts,
    );
}

fn stageLifecycleCommit(
    gs: *const GameState,
    alloc: std.mem.Allocator,
    actions: []const LifecycleAction,
    next_listing_id: u32,
    next_merc_company_id: u32,
    day: u32,
) !LifecycleStage {
    var stage = LifecycleStage{
        .merc_companies = .empty,
        .merc_company_rosters = .empty,
        .market_listings = .empty,
        .hull_ownership_history = .empty,
        .hull_changes = .empty,
        .next_listing_id = next_listing_id,
        .next_merc_company_id = next_merc_company_id,
    };
    try stage.merc_companies.ensureTotalCapacity(alloc, gs.merc_companies.count());
    for (gs.merc_companies.keys(), gs.merc_companies.values()) |id, source| {
        var company = source;
        // A prior lifecycle transaction can own this name; each replacement
        // stage must own its copy before its predecessor is released.
        company.unit_name = try alloc.dupe(u8, source.unit_name);
        stage.merc_companies.putAssumeCapacity(id, company);
    }
    try stage.merc_company_rosters.ensureTotalCapacity(alloc, gs.merc_company_rosters.count());
    for (gs.merc_company_rosters.keys(), gs.merc_company_rosters.values()) |id, source| {
        var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        try roster.appendSlice(alloc, source.items);
        stage.merc_company_rosters.putAssumeCapacity(id, roster);
    }
    try stage.market_listings.appendSlice(alloc, gs.market_listings.items);
    try stage.hull_ownership_history.appendSlice(alloc, gs.hull_ownership_history.items);

    for (actions) |action| switch (action) {
        .buy => |buy| try stageBuy(&stage, alloc, buy, day),
        .liquidate => |liquidation| try stageLiquidation(&stage, alloc, liquidation.company_id, liquidation.listings, day),
        .spawn => |replacement| try stageReplacement(&stage, alloc, replacement, day),
        .replace => |replace| {
            try stageLiquidation(&stage, alloc, replace.dissolved_id, replace.liquidation_listings, day);
            try stageReplacement(&stage, alloc, replace.replacement, day);
        },
    };
    return stage;
}

fn stageLiquidation(stage: *LifecycleStage, alloc: std.mem.Allocator, company_id: types.MercCompanyId, listings: []const market.Listing, day: u32) !void {
    const company = stage.merc_companies.getPtr(company_id).?;
    if (stage.merc_company_rosters.getPtr(company_id)) |roster| {
        for (roster.items, 0..) |hull_id, i| {
            try stage.hull_changes.append(alloc, .{ .id = hull_id, .owner = .market });
            closeOwnershipHistory(&stage.hull_ownership_history, hull_id, day);
            try stage.hull_ownership_history.append(alloc, .{
                .hull_instance_id = hull_id,
                .from_day = day,
                .acquisition_type = .transfer,
                .prior_owner_key = company.faction_key,
            });
            try stage.market_listings.append(alloc, listings[i]);
        }
        roster.clearRetainingCapacity();
    }
    company.dissolved_day = day;
}

fn stageReplacement(stage: *LifecycleStage, alloc: std.mem.Allocator, replacement: ReplacementPlan, day: u32) !void {
    try stage.merc_companies.put(alloc, replacement.company.id, replacement.company);
    if (replacement.buy) |buy| try stageBuy(stage, alloc, buy, day);
}

fn stageBuy(stage: *LifecycleStage, alloc: std.mem.Allocator, buy: BuyPlan, day: u32) !void {
    if (!stage.merc_company_rosters.contains(buy.company_id)) {
        try stage.merc_company_rosters.put(alloc, buy.company_id, .empty);
    }
    var spent: types.CBills = 0;
    const roster = stage.merc_company_rosters.getPtr(buy.company_id).?;
    for (buy.purchases) |purchase| {
        try stage.hull_changes.append(alloc, .{ .id = purchase.hull_instance_id, .owner = .{ .merc_company = buy.company_id }, .status = .active });
        closeOwnershipHistory(&stage.hull_ownership_history, purchase.hull_instance_id, day);
        try stage.hull_ownership_history.append(alloc, .{ .hull_instance_id = purchase.hull_instance_id, .from_day = day, .acquisition_type = .transfer, .prior_owner_key = "market" });
        try roster.append(alloc, purchase.hull_instance_id);
        spent += purchase.price;
    }
    stage.merc_companies.getPtr(buy.company_id).?.cbills -= spent;
    for (buy.remove_order) |purchase| {
        _ = stage.market_listings.orderedRemove(indexOfPurchasedHull(stage.market_listings.items, purchase.hull_instance_id));
    }
}

fn closeOwnershipHistory(history: *std.ArrayListUnmanaged(hull_instance_mod.HullOwnershipHistory), hull_id: types.HullInstanceId, day: u32) void {
    for (history.items) |*entry| {
        if (entry.hull_instance_id == hull_id and entry.to_day == 0) entry.to_day = day;
    }
}

fn commitLifecycleStage(gs: *GameState, stage: LifecycleStage) void {
    gs.merc_companies = stage.merc_companies;
    gs.merc_company_rosters = stage.merc_company_rosters;
    gs.releaseMercCompanyRosterLifecycleArena();
    gs.market_listings = stage.market_listings;
    gs.hull_ownership_history = stage.hull_ownership_history;
    for (stage.hull_changes.items) |change| {
        const hull = gs.hull_instances.getPtr(change.id).?;
        hull.owner = change.owner;
        if (change.status) |status| hull.status = status;
    }
    gs.next_listing_id = stage.next_listing_id;
    gs.next_merc_company_id = stage.next_merc_company_id;
}

fn indexOfPurchasedHull(listings: []const market.Listing, hull_instance_id: types.HullInstanceId) usize {
    for (listings, 0..) |listing, i| if (listing.hull_instance_id == hull_instance_id) return i;
    unreachable;
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
    // Fail the lifecycle arena's first staging allocation.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    gs.arena.child_allocator = failing.allocator();
    const result = liquidateMercCompany(&gs, alloc, mcid, 30);
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

test "buyHullsForCompany: late transaction OOM leaves no roster entry or retained allocation" {
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 2003 });
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        const company_id: types.MercCompanyId = @enumFromInt(1);
        const hull_id: types.HullInstanceId = @enumFromInt(1);
        try gs.merc_companies.put(gs.allocator(), company_id, .{
            .id = company_id,
            .archetype_key = "enemy_raiders",
            .unit_name = "Buying Co",
            .faction_key = "DC",
            .cbills = 10_000_000,
        });
        try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
        try gs.hull_ownership_history.append(gs.allocator(), .{ .hull_instance_id = hull_id, .from_day = 0, .acquisition_type = .transfer, .prior_owner_key = "market" });
        try gs.market_listings.append(gs.allocator(), .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .id = @enumFromInt(1), .hull_instance_id = hull_id });

        const before = digest.stateHash(&gs);
        const capacity_before = gs.arena.queryCapacity();
        const rosters_before = gs.merc_company_rosters.keys().ptr;
        var rng = gs.rng;
        const rng_before = rng;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (buyHullsForCompany(&gs, outer.allocator(), company_id, 1, &rng)) |_| {
            try std.testing.expect(gs.merc_company_rosters.contains(company_id));
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            try std.testing.expectEqual(capacity_before, gs.arena.queryCapacity());
            try std.testing.expectEqual(rosters_before, gs.merc_company_rosters.keys().ptr);
            try std.testing.expectEqual(rng_before, rng);
            gs.deinit();
        }
    }
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
    const new_id = try spawnReplacementCompany(&gs, alloc, 60, &rng);

    // A new company was added.
    try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
    try std.testing.expectEqual(@as(types.MercCompanyId, @enumFromInt(2)), new_id);
    const spawned = gs.merc_companies.getPtr(new_id) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 60), spawned.founded_day);
    try std.testing.expectEqual(@as(u32, 0), spawned.dissolved_day);
    try std.testing.expectEqual(tuning.generation.merc_replacement_cbill_floor, spawned.cbills);
    // Logo is not the one held by the existing active company.
    try std.testing.expect(!std.mem.eql(u8, spawned.logo_key, logo.all_keys[0]));
    // next_merc_company_id advanced.
    try std.testing.expectEqual(@as(u32, 3), gs.next_merc_company_id);
}

test "spawnReplacementCompany: never picks the player's reserved logo_key" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();

    // Reserve the first catalog key for the player (not held by any active company).
    gs.player_logo_key = logo.all_keys[0];
    gs.next_merc_company_id = 1;

    var rng = gs.rng;
    const new_id = try spawnReplacementCompany(&gs, alloc, 10, &rng);

    try std.testing.expectEqual(@as(types.MercCompanyId, @enumFromInt(1)), new_id);
    const spawned = gs.merc_companies.getPtr(new_id) orelse return error.TestFailed;
    // Spawned company must not use the player's reserved logo.
    try std.testing.expect(!std.mem.eql(u8, spawned.logo_key, logo.all_keys[0]));
}

test "spawnReplacementCompany: late transaction OOM leaves no company or ID advance" {
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 3003 });
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        const before = digest.stateHash(&gs);
        const capacity_before = gs.arena.queryCapacity();
        const companies_before = gs.merc_companies.keys().ptr;
        var rng = gs.rng;
        const rng_before = rng;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (spawnReplacementCompany(&gs, outer.allocator(), 1, &rng)) |new_id| {
            try std.testing.expectEqual(@as(types.MercCompanyId, @enumFromInt(1)), new_id);
            try std.testing.expectEqual(@as(usize, 1), gs.merc_companies.count());
            try std.testing.expectEqual(@as(u32, 2), gs.next_merc_company_id);
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            try std.testing.expectEqual(capacity_before, gs.arena.queryCapacity());
            try std.testing.expectEqual(companies_before, gs.merc_companies.keys().ptr);
            try std.testing.expectEqual(rng_before, rng);
            gs.deinit();
        }
    }
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

test "runMercLifecycle: bankrupt company without a roster is dissolved and replaced" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4005 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.advance();

    const bankrupt: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), bankrupt, .{
        .id = bankrupt,
        .archetype_key = "enemy_raiders",
        .unit_name = "Empty Bankrupt Co",
        .faction_key = "DC",
        .cbills = -1,
        .logo_key = logo.all_keys[0],
    });
    gs.next_merc_company_id = 2;

    try runMercLifecycle(&gs);

    try std.testing.expectEqual(gs.clock.day_index, gs.merc_companies.getPtr(bankrupt).?.dissolved_day);
    try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
    const replacement: types.MercCompanyId = @enumFromInt(2);
    try std.testing.expect(gs.merc_companies.getPtr(replacement).?.dissolved_day == 0);
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

fn seedLifecycleAtomicityFixture(gs: *GameState) !void {
    const alloc = gs.allocator();
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    gs.clock.advance();

    const bankrupt: types.MercCompanyId = @enumFromInt(1);
    const under_strength: types.MercCompanyId = @enumFromInt(2);
    try gs.merc_companies.put(alloc, bankrupt, .{
        .id = bankrupt,
        .archetype_key = "enemy_raiders",
        .unit_name = "Bankrupt Co",
        .faction_key = "DC",
        .cbills = -1,
        .logo_key = logo.all_keys[0],
    });
    try gs.merc_companies.put(alloc, under_strength, .{
        .id = under_strength,
        .archetype_key = "enemy_raiders",
        .unit_name = "Buying Co",
        .faction_key = "DC",
        .cbills = 10_000_000,
        .logo_key = logo.all_keys[1],
    });

    for ([_]types.MercCompanyId{ bankrupt, under_strength }) |company_id| {
        var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..5) |_| {
            const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
            gs.next_hull_instance_id += 1;
            try gs.hull_instances.put(alloc, hull_id, .{
                .id = hull_id,
                .base_key = "LCT-1V",
                .owner = .{ .merc_company = company_id },
            });
            try gs.hull_ownership_history.append(alloc, .{
                .hull_instance_id = hull_id,
                .from_day = 0,
                .acquisition_type = .initial,
                .prior_owner_key = "DC",
            });
            try roster.append(alloc, hull_id);
        }
        try gs.merc_company_rosters.put(alloc, company_id, roster);
    }
    for (0..20) |_| {
        const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(alloc, hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
        try gs.hull_ownership_history.append(alloc, .{
            .hull_instance_id = hull_id,
            .from_day = 0,
            .acquisition_type = .transfer,
            .prior_owner_key = "market",
        });
        try gs.market_listings.append(alloc, .{
            .kind = .unit,
            .item_key = "LCT-1V",
            .rarity = .common,
            .price = 1,
            .id = @enumFromInt(gs.next_listing_id),
            .hull_instance_id = hull_id,
        });
        gs.next_listing_id += 1;
    }
    gs.next_merc_company_id = 3;
}

test "runMercLifecycle: allocator failures leave a multi-action pass unchanged" {
    // Rule 69: the fixture executes a bankruptcy replacement and a separate
    // under-strength purchase; every preparation failure preserves gameplay,
    // live collection storage, and campaign-arena capacity.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 4004 });
        try seedLifecycleAtomicityFixture(&gs);
        const before = digest.stateHash(&gs);
        const capacity_before = gs.arena.queryCapacity();
        const companies_before = gs.merc_companies.keys().ptr;
        const rosters_before = gs.merc_company_rosters.keys().ptr;
        const listings_before = gs.market_listings.items.ptr;
        const history_before = gs.hull_ownership_history.items.ptr;
        const bankrupt_roster_before = gs.merc_company_rosters.get(@enumFromInt(1)).?.items.ptr;
        const under_strength_roster_before = gs.merc_company_rosters.get(@enumFromInt(2)).?.items.ptr;

        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (runMercLifecycle(&gs)) |_| {
            try std.testing.expect(digest.stateHash(&gs) != before);
            try std.testing.expect(gs.merc_companies.getPtr(@enumFromInt(1)).?.dissolved_day != 0);
            try std.testing.expectEqual(
                @as(usize, tuning.generation.merc_company_hulls_each),
                gs.merc_company_rosters.get(@enumFromInt(2)).?.items.len,
            );
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            try std.testing.expectEqual(capacity_before, gs.arena.queryCapacity());
            try std.testing.expectEqual(companies_before, gs.merc_companies.keys().ptr);
            try std.testing.expectEqual(rosters_before, gs.merc_company_rosters.keys().ptr);
            try std.testing.expectEqual(listings_before, gs.market_listings.items.ptr);
            try std.testing.expectEqual(history_before, gs.hull_ownership_history.items.ptr);
            try std.testing.expectEqual(bankrupt_roster_before, gs.merc_company_rosters.get(@enumFromInt(1)).?.items.ptr);
            try std.testing.expectEqual(under_strength_roster_before, gs.merc_company_rosters.get(@enumFromInt(2)).?.items.ptr);
            gs.deinit();
        }
    }
}

test "runMercLifecycle: repeated active monthly passes retain bounded staging memory" {
    var debug_alloc = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer std.testing.expect(debug_alloc.deinit() == .ok) catch @panic("leak");
    var gs = GameState.init(debug_alloc.allocator(), .{ .seed = 4006 });
    defer gs.deinit();
    gs.clock.advance();

    const company_id: types.MercCompanyId = @enumFromInt(1);
    const hull_id: types.HullInstanceId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{
        .id = company_id,
        .archetype_key = "enemy_raiders",
        .unit_name = "Under Strength Co",
        .faction_key = "DC",
        .cbills = 1,
        .logo_key = logo.all_keys[0],
    });
    gs.next_merc_company_id = 2;
    try gs.hull_instances.put(gs.allocator(), hull_id, .{
        .id = hull_id,
        .base_key = "LCT-1V",
        .owner = .market,
    });
    const listing = market.Listing{
        .kind = .unit,
        .item_key = "LCT-1V",
        .rarity = .common,
        .price = 1,
        .id = @enumFromInt(1),
        .hull_instance_id = hull_id,
    };
    try gs.market_listings.append(gs.allocator(), listing);

    try runMercLifecycle(&gs);
    const bytes_after_first_pass = debug_alloc.total_requested_bytes;

    for (0..3) |_| {
        gs.merc_companies.getPtr(company_id).?.cbills = 1;
        _ = gs.merc_company_rosters.orderedRemove(company_id);
        gs.hull_instances.getPtr(hull_id).?.owner = .market;
        _ = gs.hull_ownership_history.pop();
        try gs.market_listings.append(gs.allocator(), listing);
        gs.clock.advance();
        try runMercLifecycle(&gs);
        try std.testing.expectEqual(bytes_after_first_pass, debug_alloc.total_requested_bytes);
    }
}
