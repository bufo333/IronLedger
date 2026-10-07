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
/// by any active (dissolved_day == 0) company and never the player's reserved
/// `player_logo_key`. Sets cbills to `merc_replacement_cbill_floor` and calls
/// `buyHullsForCompany` to form the hull pool from market supply.
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

    // Pick the first logo key not held by any active company and not reserved for the player.
    var chosen_logo: []const u8 = "";
    for (logo.all_keys) |key| {
        if (gs.player_logo_key.len > 0 and std.mem.eql(u8, key, gs.player_logo_key)) continue; // reserved for the player
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
    new_roster: ?std.ArrayListUnmanaged(types.HullInstanceId) = null,
};

const ReplacementPlan = struct {
    company: merc_company_mod.MercCompany,
    unit_name_parts: struct { last: []const u8, noun: []const u8 },
    buy: ?BuyPlan,
};

const LifecycleAction = union(enum) {
    buy: BuyPlan,
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

    try prepareLifecycleCommit(gs, actions.items);
    try allocateReplacementNames(gs, actions.items);

    for (actions.items) |action| switch (action) {
        .buy => |buy| commitBuy(gs, buy, day),
        .replace => |replace| {
            commitLiquidation(gs, replace.dissolved_id, replace.liquidation_listings, day);
            commitReplacement(gs, replace.replacement, day);
        },
    };
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

fn prepareLifecycleCommit(gs: *GameState, actions: []LifecycleAction) !void {
    const alloc = gs.allocator();
    var history_count: usize = 0;
    var listing_count: usize = 0;
    var company_count: usize = 0;
    var roster_count: usize = 0;
    for (actions) |*action| switch (action.*) {
        .buy => |*buy| {
            history_count += buy.purchases.len;
            try prepareBuyRoster(gs, alloc, buy, &roster_count);
        },
        .replace => |*replace| {
            history_count += replace.liquidation_listings.len;
            listing_count += replace.liquidation_listings.len;
            company_count += 1;
            if (replace.replacement.buy) |*buy| {
                history_count += buy.purchases.len;
                try prepareBuyRoster(gs, alloc, buy, &roster_count);
            }
        },
    };
    try gs.hull_ownership_history.ensureUnusedCapacity(alloc, history_count);
    try gs.market_listings.ensureUnusedCapacity(alloc, listing_count);
    try gs.merc_companies.ensureUnusedCapacity(alloc, company_count);
    try gs.merc_company_rosters.ensureUnusedCapacity(alloc, roster_count);
}

fn prepareBuyRoster(gs: *GameState, alloc: std.mem.Allocator, buy: *BuyPlan, new_rosters: *usize) !void {
    if (gs.merc_company_rosters.getPtr(buy.company_id)) |roster| {
        try roster.ensureUnusedCapacity(alloc, buy.purchases.len);
    } else {
        var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        try roster.ensureUnusedCapacity(alloc, buy.purchases.len);
        buy.new_roster = roster;
        new_rosters.* += 1;
    }
}

fn allocateReplacementNames(gs: *GameState, actions: []LifecycleAction) !void {
    for (actions) |*action| switch (action.*) {
        .replace => |*replace| {
            replace.replacement.company.unit_name = try std.fmt.allocPrint(
                gs.allocator(),
                "{s} {s}",
                replace.replacement.unit_name_parts,
            );
        },
        .buy => {},
    };
}

fn commitLiquidation(gs: *GameState, company_id: types.MercCompanyId, listings: []const market.Listing, day: u32) void {
    const mc = gs.merc_companies.getPtr(company_id).?;
    const roster = gs.merc_company_rosters.getPtr(company_id) orelse unreachable;
    for (roster.items, 0..) |hid, i| {
        const inst = gs.hull_instances.getPtr(hid).?;
        inst.owner = .market;
        for (gs.hull_ownership_history.items) |*history| {
            if (history.hull_instance_id == hid and history.to_day == 0) history.to_day = day;
        }
        gs.hull_ownership_history.appendAssumeCapacity(.{ .hull_instance_id = hid, .from_day = day, .acquisition_type = .transfer, .prior_owner_key = mc.faction_key });
        gs.market_listings.appendAssumeCapacity(listings[i]);
    }
    roster.clearRetainingCapacity();
    gs.next_listing_id += @intCast(listings.len);
    mc.dissolved_day = day;
}

fn commitReplacement(gs: *GameState, replacement: ReplacementPlan, day: u32) void {
    gs.merc_companies.putAssumeCapacity(replacement.company.id, replacement.company);
    gs.next_merc_company_id += 1;
    if (replacement.buy) |buy| commitBuy(gs, buy, day);
}

fn commitBuy(gs: *GameState, buy: BuyPlan, day: u32) void {
    if (buy.new_roster) |roster| gs.merc_company_rosters.putAssumeCapacity(buy.company_id, roster);
    var spent: types.CBills = 0;
    const roster = gs.merc_company_rosters.getPtr(buy.company_id).?;
    for (buy.purchases) |purchase| {
        const inst = gs.hull_instances.getPtr(purchase.hull_instance_id).?;
        inst.owner = .{ .merc_company = buy.company_id };
        inst.status = .active;
        for (gs.hull_ownership_history.items) |*history| {
            if (history.hull_instance_id == purchase.hull_instance_id and history.to_day == 0) history.to_day = day;
        }
        gs.hull_ownership_history.appendAssumeCapacity(.{ .hull_instance_id = purchase.hull_instance_id, .from_day = day, .acquisition_type = .transfer, .prior_owner_key = "market" });
        roster.appendAssumeCapacity(purchase.hull_instance_id);
        spent += purchase.price;
    }
    gs.merc_companies.getPtr(buy.company_id).?.cbills -= spent;
    for (buy.remove_order) |purchase| {
        _ = gs.market_listings.orderedRemove(indexOfPurchasedHull(gs.market_listings.items, purchase.hull_instance_id));
    }
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
    try spawnReplacementCompany(&gs, alloc, 10, &rng);

    const new_id: types.MercCompanyId = @enumFromInt(1);
    const spawned = gs.merc_companies.getPtr(new_id) orelse return error.TestFailed;
    // Spawned company must not use the player's reserved logo.
    try std.testing.expect(!std.mem.eql(u8, spawned.logo_key, logo.all_keys[0]));
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
    // under-strength purchase; every preparation failure preserves the digest.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 4004 });
        try seedLifecycleAtomicityFixture(&gs);
        const before = digest.stateHash(&gs);

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
            gs.deinit();
        }
    }
}
