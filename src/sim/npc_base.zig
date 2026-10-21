//! NPC merc company operating base, current world, market reach and hull
//! arrival: the one owner of where a world merc company is based, where it
//! stands, which listings it can buy, and when a hull it bought off its base
//! world can be fielded (docs/p5d-conflict-world-design.md §A "NPC company
//! location", §L1 "Operating base"; decisions D20, D21). P5d.1h.
//! No MekHQ counterpart: MekHQ has no persistent NPC companies
//! (docs/mekhq-map.md). Pure: it draws only from the random source its
//! caller passes and mutates nothing.

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const planet = @import("../domain/planet.zig");
const faction = @import("../domain/faction.zig");
const market = @import("../econ/market.zig");
const logistics = @import("../econ/logistics.zig");
const merc_company_mod = @import("../domain/merc_company.zig");
const rng_mod = @import("rng.zig");
const GameState = @import("state.zig").GameState;

const Planet = planet.Planet;

/// A new company's base (§L1 "drawn at seed on `.rivals`"): one `.rivals`
/// draw of a world of `faction_key`, weighted by industry in catalog order
/// (`planet.weightedPickByFaction`, the starter HQ's rule). Null only when
/// the faction has no world; callers treat that as `CorruptSave`, never a
/// default world (rule 1).
pub fn drawBase(rng: *rng_mod.Rng, faction_key: []const u8) ?*const Planet {
    return planet.weightedPickByFaction(rng, .rivals, faction_key);
}

/// The base a company stored before schema v76 is given on migration, a
/// documented compatibility value (rule 51; docs/p5d-conflict-world-design.md
/// §L1): its faction's capital when that world is the faction's own,
/// otherwise the faction's world nearest the capital (`planet.distanceLy`),
/// ties to the earlier in catalog order. Null when the faction is unknown,
/// its capital is off the map, or it has no world. Catalog-computed: no RNG,
/// no seed; usable at compile time.
pub fn compatibilityBase(faction_key: []const u8) ?*const Planet {
    const row = faction.find(faction_key) orelse return null;
    return compatibilityBaseIn(planet.catalog, row.capital, faction_key);
}

fn compatibilityBaseIn(catalog: []const Planet, capital_key: []const u8, faction_key: []const u8) ?*const Planet {
    @setEvalBranchQuota(100_000);
    const capital = for (catalog) |*p| {
        if (std.mem.eql(u8, p.key, capital_key)) break p;
    } else return null;
    if (std.mem.eql(u8, capital.faction, faction_key)) return capital;
    var best: ?*const Planet = null;
    var best_ly: u32 = 0;
    for (catalog) |*p| {
        if (!std.mem.eql(u8, p.faction, faction_key)) continue;
        const ly = planet.distanceLy(capital, p);
        if (best == null or ly < best_ly) {
            best = p;
            best_ly = ly;
        }
    }
    return best;
}

/// The company's base world (`MercCompany.home_planet_key`). `CorruptSave`
/// when the key names no catalog world (rule 1).
pub fn companyBase(company: merc_company_mod.MercCompany) error{CorruptSave}!*const Planet {
    return planet.find(company.home_planet_key) orelse error.CorruptSave;
}

/// The world the company stands on today (§A "location_planet_key"): its
/// base, because no NPC company moves. A catalog key.
pub fn currentWorld(company: merc_company_mod.MercCompany) []const u8 {
    return company.home_planet_key;
}

/// Whether a listing on `world` is within a company's market reach from
/// `base` (D21): at most `npc_market_reach_ly` light-years, inclusive, in
/// `planet.distanceLy`'s whole light-years.
pub fn withinMarketReach(base: *const Planet, world: *const Planet) bool {
    return planet.distanceLy(base, world) <= tuning.generation.npc_market_reach_ly;
}

/// Where a listing's hull comes from for an NPC buyer.
pub const Source = union(enum) {
    /// The listing stands on this world: a black-market world, an HQ board's
    /// world or a contract world.
    located: *const Planet,
    /// A world-less faction-surplus or liquidation listing: the seller's
    /// wholesale offer, delivered from this capital of the faction its hull's
    /// open ownership interval names.
    wholesale: *const Planet,

    /// The world a bought hull travels from.
    pub fn origin(self: Source) *const Planet {
        return switch (self) {
            .located, .wholesale => |world| world,
        };
    }
};

/// The source of a listing (D21, and the wholesale rule for world-less
/// listings): a dispersed listing's `planet_key` world; else a
/// contract-world board's world, its company's running contract's
/// (`GameState.deploymentContract`); else an HQ board's HQ world; else
/// wholesale from the capital of its seller. The seller is `staged_seller`
/// when given: the faction key of a world-less listing whose ownership
/// interval its caller has staged but not committed, as for a liquidation
/// planned earlier in the same lifecycle pass. Otherwise it is the faction
/// named by the open ownership interval of the listing's hull.
/// `CorruptSave` when a world, HQ, deployment, hull, open interval or
/// faction does not resolve (rule 1). Reads only.
pub fn listingSource(gs: *GameState, listing: market.Listing, staged_seller: ?[]const u8) error{CorruptSave}!Source {
    if (listing.planet_key.len > 0) return .{ .located = planet.find(listing.planet_key) orelse return error.CorruptSave };
    // A contract-world listing also names the home HQ whose board shows it;
    // it stands on the contract world.
    if (listing.company != .none) {
        const contract = gs.deploymentContract(listing.company) orelse return error.CorruptSave;
        return .{ .located = planet.find(contract.planet_key) orelse return error.CorruptSave };
    }
    if (listing.hq != .none) {
        const hq = gs.hqs.getPtr(listing.hq) orelse return error.CorruptSave;
        return .{ .located = planet.find(hq.planet_key) orelse return error.CorruptSave };
    }
    if (listing.hull_instance_id == .none) return error.CorruptSave;
    if (!gs.hull_instances.contains(listing.hull_instance_id)) return error.CorruptSave;
    const seller = staged_seller orelse for (gs.hull_ownership_history.items) |entry| {
        if (entry.hull_instance_id == listing.hull_instance_id and entry.isOpen()) break entry.prior_owner_key;
    } else return error.CorruptSave;
    const row = faction.find(seller) orelse return error.CorruptSave;
    return .{ .wholesale = planet.find(row.capital) orelse return error.CorruptSave };
}

/// Whether a company based on `base` can buy `listing` (D21): a wholesale
/// listing always, a located one only `withinMarketReach`. The black-market
/// buyer gates (`black_market.buyerEligible`) apply on top. `staged_seller`
/// and `CorruptSave` as for `listingSource`. Reads only.
pub fn listingReachable(gs: *GameState, base: *const Planet, listing: market.Listing, staged_seller: ?[]const u8) error{CorruptSave}!bool {
    return switch (try listingSource(gs, listing, staged_seller)) {
        .located => |world| withinMarketReach(base, world),
        .wholesale => true,
    };
}

/// The day a hull bought on `day` from `origin` reaches a company based on
/// `base` (§A "one travel rule"): null when it is bought on the base world,
/// else `day + logistics.deliveryDays(origin, base)`, the player's
/// hull-delivery days for the same route (`contract_market.buyHullFor`).
pub fn deliveryArrival(origin: *const Planet, base: *const Planet, day: u32) ?u32 {
    if (origin == base) return null;
    return day + logistics.deliveryDays(origin, base);
}

/// The day a hull still travelling to its company's base on `day` arrives
/// (§L1): its arrival day when that is after `day`, else null. Reads only.
pub fn enRouteUntil(gs: *const GameState, hull: types.HullInstanceId, day: u32) ?u32 {
    const arrive_day = gs.merc_hull_arrivals.get(hull) orelse return null;
    return if (arrive_day > day) arrive_day else null;
}

/// Whether a merc company can field `hull` on `day` (§L1 "not fieldable
/// before"): it is not `enRouteUntil` a later day. Reads only.
pub fn hullFieldable(gs: *const GameState, hull: types.HullInstanceId, day: u32) bool {
    return enRouteUntil(gs, hull, day) == null;
}

/// Whether a company can muster on `day` (§A "ready_day"): its ready day
/// has come.
pub fn readyOn(company: merc_company_mod.MercCompany, day: u32) bool {
    return company.ready_day <= day;
}

/// A loaded campaign's bases, ready days and arrivals keep every invariant
/// their producers keep (rule 47; docs/p5d-conflict-world-design.md §L1).
/// Runs after the merc-company, roster and hull loads. `CorruptSave` for: a
/// `home_planet_key` that is empty or names no catalog world; a base not of
/// the company's own faction; a `ready_day` before `founded_day`; an arrival
/// for an unknown hull, a hull no merc company owns, a hull its owner's
/// roster does not hold, or a hull of a dissolved company.
pub fn validate(gs: *const GameState) error{CorruptSave}!void {
    for (gs.merc_companies.values()) |company| {
        const base = try companyBase(company);
        if (!std.mem.eql(u8, base.faction, company.faction_key)) return error.CorruptSave;
        if (company.ready_day < company.founded_day) return error.CorruptSave;
    }
    for (gs.merc_hull_arrivals.keys()) |hull_id| {
        const hull = gs.hull_instances.get(hull_id) orelse return error.CorruptSave;
        const owner = switch (hull.owner) {
            .merc_company => |id| id,
            else => return error.CorruptSave,
        };
        const company = gs.merc_companies.get(owner) orelse return error.CorruptSave;
        if (company.dissolved_day != 0) return error.CorruptSave;
        const roster = gs.merc_company_rosters.get(owner) orelse return error.CorruptSave;
        if (std.mem.indexOfScalar(types.HullInstanceId, roster.items, hull_id) == null) return error.CorruptSave;
    }
}

// ---- Tests -----------------------------------------------------------------

const founding = @import("founding.zig");

fn testWorld(key: []const u8, faction_key: []const u8, x: i32) Planet {
    return .{ .key = key, .name = key, .faction = faction_key, .x = x, .y = 0, .industry = 1 };
}

test "withinMarketReach is inclusive: 59 and 60 light-years reach, 61 does not" {
    try std.testing.expectEqual(@as(u32, 60), tuning.generation.npc_market_reach_ly);
    const base = testWorld("base", "LC", 0);
    for ([_]struct { x: i32, reached: bool }{ .{ .x = 59, .reached = true }, .{ .x = 60, .reached = true }, .{ .x = 61, .reached = false } }) |case| {
        const world = testWorld("world", "LC", case.x);
        try std.testing.expectEqual(@as(u32, @intCast(case.x)), planet.distanceLy(&base, &world));
        try std.testing.expectEqual(case.reached, withinMarketReach(&base, &world));
    }
}

test "compatibilityBase is each hiring faction's capital, but Star's End for the Periphery, 263 light-years from Galatea" {
    for (faction.table) |row| {
        if (!row.hires) continue;
        const base = compatibilityBase(row.key) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(row.key, base.faction);
        if (std.mem.eql(u8, row.key, "PER")) {
            try std.testing.expectEqualStrings("star_s_end", base.key);
            try std.testing.expectEqual(@as(u32, 263), planet.distanceLy(planet.find(row.capital).?, base));
        } else {
            try std.testing.expectEqualStrings(row.capital, base.key);
        }
    }
    // The Periphery's capital is not a Periphery world, so step 2 decides it.
    try std.testing.expectEqualStrings("LC", planet.find(faction.find("PER").?.capital).?.faction);
    try std.testing.expectEqual(@as(?*const Planet, null), compatibilityBase("XX"));
}

test "compatibilityBase breaks a distance tie by catalog order and has none for a faction without a world" {
    const catalog = [_]Planet{
        testWorld("capital", "AA", 0),
        testWorld("far", "BB", 50),
        testWorld("west", "BB", -20),
        testWorld("east", "BB", 20),
    };
    try std.testing.expectEqualStrings("west", compatibilityBaseIn(&catalog, "capital", "BB").?.key);
    try std.testing.expectEqualStrings("capital", compatibilityBaseIn(&catalog, "capital", "AA").?.key);
    try std.testing.expectEqual(@as(?*const Planet, null), compatibilityBaseIn(&catalog, "capital", "CC"));
    try std.testing.expectEqual(@as(?*const Planet, null), compatibilityBaseIn(&catalog, "nowhere", "BB"));
}

test "drawBase draws one .rivals value for a world of the faction, and none for a faction without a world" {
    var rng = rng_mod.Rng.init(4200);
    var other = rng;
    const base = drawBase(&rng, "DC").?;
    try std.testing.expectEqualStrings("DC", base.faction);
    try std.testing.expectEqual(planet.weightedPickByFaction(&other, .rivals, "DC").?, base);
    try std.testing.expectEqual(other, rng);
    try std.testing.expectEqual(@as(?*const Planet, null), drawBase(&rng, "XX"));
}

test "deliveryArrival is nothing on the base world and the player's delivery days elsewhere" {
    const tharkad = planet.find("tharkad").?;
    const skye = planet.find("skye").?;
    try std.testing.expectEqual(@as(?u32, null), deliveryArrival(tharkad, tharkad, 40));
    const days = logistics.deliveryDays(skye, tharkad);
    try std.testing.expect(days > 0);
    try std.testing.expectEqual(@as(?u32, 40 + days), deliveryArrival(skye, tharkad, 40));
}

test "listingSource locates world, HQ and contract-world listings, sends surplus and liquidation wholesale, and refuses what does not resolve" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7601 });
    defer gs.deinit();
    const home = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();
    const home_world = planet.find(gs.hqs.get(home).?.planet_key).?;

    const dispersed: market.Listing = .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .black_market = true, .planet_key = "skye" };
    try std.testing.expectEqual(Source{ .located = planet.find("skye").? }, try listingSource(&gs, dispersed, null));
    try std.testing.expectEqual(Source{ .located = home_world }, try listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hq = home }, null));

    // A contract-world board stands where its deployed company does, though
    // the listing also names the home HQ whose board shows it.
    const company: types.ForceId = @enumFromInt(77);
    const contract_id: types.ContractId = @enumFromInt(5);
    try gs.contracts.put(alloc, contract_id, .{ .id = contract_id, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "solaris7", .status = .active, .assigned_company = company, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } });
    try std.testing.expect(!std.mem.eql(u8, "solaris7", home_world.key));
    try std.testing.expectEqual(Source{ .located = planet.find("solaris7").? }, try listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hq = home, .company = company }, null));

    // Surplus and liquidation: wholesale from the seller's capital.
    const surplus: types.HullInstanceId = @enumFromInt(1);
    const liquidated: types.HullInstanceId = @enumFromInt(2);
    try gs.hull_instances.put(alloc, surplus, .{ .id = surplus, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_instances.put(alloc, liquidated, .{ .id = liquidated, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = surplus, .acquisition_type = .initial, .prior_owner_key = "DC" });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = liquidated, .from_day = 0, .to_day = 3, .acquisition_type = .initial, .prior_owner_key = "LC" });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = liquidated, .from_day = 3, .acquisition_type = .transfer, .prior_owner_key = "FS" });
    try std.testing.expectEqual(Source{ .wholesale = planet.find("luthien").? }, try listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = surplus }, null));
    try std.testing.expectEqual(Source{ .wholesale = planet.find("new_avalon").? }, try listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = liquidated }, null));
    // A staged seller, from a liquidation not yet committed, replaces the
    // hull's open interval (here FS).
    try std.testing.expectEqual(Source{ .wholesale = planet.find("tharkad").? }, try listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = liquidated }, "LC"));
    // A staged seller never applies to a listing that stands on a world.
    try std.testing.expectEqual(Source{ .located = planet.find("skye").? }, try listingSource(&gs, dispersed, "LC"));

    // What does not resolve is corruption, never a default world.
    const dangling_hull: types.HullInstanceId = @enumFromInt(9);
    const no_interval: types.HullInstanceId = @enumFromInt(3);
    try gs.hull_instances.put(alloc, no_interval, .{ .id = no_interval, .base_key = "LCT-1V", .owner = .market });
    const unknown_seller: types.HullInstanceId = @enumFromInt(4);
    try gs.hull_instances.put(alloc, unknown_seller, .{ .id = unknown_seller, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = unknown_seller, .acquisition_type = .initial, .prior_owner_key = "XX" });
    for ([_]market.Listing{
        .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .black_market = true, .planet_key = "nowhere" },
        .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hq = @enumFromInt(99) },
        .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .company = @enumFromInt(98) },
        .{ .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1 },
        .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = dangling_hull },
        .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = no_interval },
        .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = unknown_seller },
    }, 0..) |listing, i| {
        errdefer std.debug.print("unresolvable listing case {d}\n", .{i});
        try std.testing.expectError(error.CorruptSave, listingSource(&gs, listing, null));
    }
    // A staged seller still needs a known hull and names a known faction.
    try std.testing.expectError(error.CorruptSave, listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = dangling_hull }, "LC"));
    try std.testing.expectError(error.CorruptSave, listingSource(&gs, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = liquidated }, "XX"));

    // Reach: a located listing only within reach of the base, wholesale always.
    const luthien = planet.find("luthien").?;
    try std.testing.expect(!try listingReachable(&gs, luthien, dispersed, null));
    try std.testing.expect(try listingReachable(&gs, planet.find("skye").?, dispersed, null));
    try std.testing.expect(try listingReachable(&gs, planet.find("skye").?, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = surplus }, null));
    // A hull with no open interval is reachable once its seller is staged.
    try std.testing.expect(try listingReachable(&gs, luthien, .{ .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = no_interval }, "LC"));
}

test "hullFieldable admits a hull with no arrival or whose arrival day has come" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const hull: types.HullInstanceId = @enumFromInt(1);
    try std.testing.expect(hullFieldable(&gs, hull, 0));
    try gs.merc_hull_arrivals.put(gs.allocator(), hull, 10);
    try std.testing.expect(!hullFieldable(&gs, hull, 9));
    try std.testing.expectEqual(@as(?u32, 10), enRouteUntil(&gs, hull, 9));
    try std.testing.expect(hullFieldable(&gs, hull, 10));
    try std.testing.expectEqual(@as(?u32, null), enRouteUntil(&gs, hull, 10));
    try std.testing.expect(hullFieldable(&gs, @enumFromInt(2), 0));
    try std.testing.expect(!readyOn(.{ .ready_day = 5 }, 4));
    try std.testing.expect(readyOn(.{ .ready_day = 5 }, 5));
}
