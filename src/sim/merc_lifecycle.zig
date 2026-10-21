//! Merc-company lifecycle: monthly dissolution of companies that have run out
//! of cash, line and commitments, hull-buy toward full strength, the
//! understrength record, and replacement spawn.
//! Design: docs/p3f-faction-loop-design.md §5; docs/p5d-conflict-world-design.md §L7.
//! No MekHQ counterpart (docs/mekhq-map.md).
//! Pure: no I/O, no wall clock, no global state (ARCH rule 2).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const rng_mod = @import("rng.zig");
const market = @import("../econ/market.zig");
const chassis_mod = @import("../domain/chassis.zig");
const force = @import("../domain/force.zig");
const part_mod = @import("../domain/part.zig");
const unit = @import("../domain/unit.zig");
const hull_instance_mod = @import("../domain/hull_instance.zig");
const rivals = @import("rivals.zig");
const roster_gen = @import("../gen/roster_gen.zig");
const rival_mod = @import("../domain/rival.zig");
const faction_mod = @import("../domain/faction.zig");
const black_market = @import("black_market.zig");
const merc_company_mod = @import("../domain/merc_company.zig");
const merc_band = @import("../domain/merc_band.zig");
const logo = @import("../domain/logo.zig");
const merc_identity = @import("merc_identity.zig");
const logo_name = @import("../gen/logo_name.zig");
const planet = @import("../domain/planet.zig");
const npc_base = @import("npc_base.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

/// Single owner of merc-company liquidation (rule 20/76).
/// Deterministic, no RNG. Transfers every hull in the company's roster to
/// `.market` ownership and appends a regular (non-black-market) listing at
/// factory-fresh pricing, and drops the arrival of each listed hull still
/// travelling to the base. Sets `dissolved_day` to `day` and logs the
/// dissolution with its `dissolutionCause`, or `liquidated` when that rule
/// does not hold.
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
    const cause = (try dissolutionCause(gs, company_id)) orelse .liquidated;
    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    var next_listing_id = gs.next_listing_id;
    const listings = try planLiquidation(transaction_alloc, gs, company_id, day, &next_listing_id);
    const actions = [_]LifecycleAction{.{ .liquidate = .{
        .company_id = company_id,
        .cause = cause,
        .listings = listings,
    } }};
    const stage = try stageLifecycleCommit(gs, transaction_alloc, &actions, next_listing_id, gs.next_merc_company_id, gs.next_hull_instance_id, day);
    const log = try prepareLifecycleLog(gs, transaction_alloc, &actions);
    gs.replaceLifecycleArena(transaction_arena);
    commitLifecycleStage(gs, stage);
    gs.commitLogBatch(log);
}

/// Single owner of "buy eligible hulls toward full strength" (rule 20/76).
/// Uses the same purchase plan and staged lifecycle commit as replacement spawn
/// and the monthly `runMercLifecycle` tick.
///
/// The selector maintains a mek target, temporary vehicle line substitutions,
/// and a bounded aerospace reserve from eligible market listings its base
/// reaches (`npc_base.listingReachable`). It returns without a draw when no
/// affordable, reachable candidate can fill the next slot. A hull bought off
/// the base world is recorded in `GameState.merc_hull_arrivals` until it
/// arrives.
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
    var scratch_arena = std.heap.ArenaAllocator.init(alloc);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var listings = std.ArrayListUnmanaged(PlannedListing).empty;
    try listings.ensureTotalCapacity(scratch, gs.market_listings.items.len);
    for (gs.market_listings.items) |listing| listings.appendAssumeCapacity(.{ .listing = listing });

    var planned_company = try plannedCompany(gs, company_id, company);
    var rng_copy = rng.*;
    var next_hull_instance_id = gs.next_hull_instance_id;
    const buy = try planBuy(scratch, gs, &listings, &planned_company, day, &rng_copy, &next_hull_instance_id);
    if (buy.purchases.len == 0) {
        rng.* = rng_copy;
        return;
    }

    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    const actions = [_]LifecycleAction{.{ .buy = buy }};
    const stage = try stageLifecycleCommit(gs, transaction_alloc, &actions, gs.next_listing_id, gs.next_merc_company_id, next_hull_instance_id, day);
    gs.replaceLifecycleArena(transaction_arena);
    commitLifecycleStage(gs, stage);
    rng.* = rng_copy;
}

/// Single owner of replacement merc company spawn (rule 20/76).
/// Draws the next archetype, hiring faction and identity in the same order
/// as `seedMercCompanies`, then its base (`npc_base.drawBase`, on `.rivals`)
/// before its founding buy, which reaches from that base; its `ready_day`
/// is `day`. Its logo is `merc_identity.firstUnusedLogo`: the first
/// catalog key no company, active or dissolved, has ever held and never the
/// player's reserved `player_logo_key`, or `""` once the catalog is used up.
/// Its name is `merc_identity.unitName`, distinct from every company's name.
/// It is founded at `merc_band.replacementBand` with that band's capital
/// (docs/p5d-conflict-world-design.md §L8) and uses
/// the shared purchase plan to form the hull pool from market supply. Its
/// `understrength_since` is `day` when that buy leaves it below its line,
/// else null. The company holds a roster entry, empty when nothing was
/// bought, and its founding is logged. Planning and the taken-name list use
/// an arena over `gs.scratch()`, released on return (rule 78); `alloc` is
/// unused.
///
/// Does NOT write `gs.rng` — the caller commits the rng copy.
pub fn spawnReplacementCompany(
    gs: *GameState,
    alloc: std.mem.Allocator,
    day: u32,
    rng: *rng_mod.Rng,
) !types.MercCompanyId {
    _ = alloc;
    var scratch_arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var listings = std.ArrayListUnmanaged(PlannedListing).empty;
    try listings.ensureTotalCapacity(scratch, gs.market_listings.items.len);
    for (gs.market_listings.items) |listing| listings.appendAssumeCapacity(.{ .listing = listing });
    var companies = std.ArrayListUnmanaged(PlannedCompany).empty;
    try companies.ensureTotalCapacity(scratch, gs.merc_companies.count() + 1);
    for (gs.merc_companies.keys(), gs.merc_companies.values()) |id, company| {
        companies.appendAssumeCapacity(try plannedCompany(gs, id, company));
    }

    var rng_copy = rng.*;
    var next_company_id = gs.next_merc_company_id;
    var next_hull_instance_id = gs.next_hull_instance_id;
    const replacement = try planReplacement(scratch, gs, &companies, &listings, day, &rng_copy, &next_company_id, &next_hull_instance_id);
    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    var actions = [_]LifecycleAction{.{ .spawn = replacement }};
    try allocateReplacementNames(transaction_alloc, scratch, gs, &actions);
    const stage = try stageLifecycleCommit(gs, transaction_alloc, &actions, gs.next_listing_id, next_company_id, next_hull_instance_id, day);
    const log = try prepareLifecycleLog(gs, transaction_alloc, &actions);
    gs.replaceLifecycleArena(transaction_arena);
    commitLifecycleStage(gs, stage);
    gs.commitLogBatch(log);
    rng.* = rng_copy;
    return replacement.company.id;
}

const PlannedListing = struct {
    listing: market.Listing,
    available: bool = true,
    /// The seller of a liquidation listing planned earlier in this pass,
    /// whose ownership interval is staged but not committed
    /// (`liquidationSeller`); null for a listing already on the board, whose
    /// hull's open interval names its seller (`npc_base.listingSource`).
    staged_seller: ?[]const u8 = null,
};

/// The faction that sells a liquidated company's hulls, named by each hull's
/// new open ownership interval: the company's own
/// (docs/p5d-conflict-world-design.md M1).
fn liquidationSeller(company: merc_company_mod.MercCompany) []const u8 {
    return company.faction_key;
}

const PlannedCompany = struct {
    id: types.MercCompanyId,
    band: *const merc_band.Band,
    /// The company's base world (`npc_base.companyBase`).
    base: *const planet.Planet,
    cbills: types.CBills,
    counts: rivals.MercHullCounts,
    dissolved_day: u32,
    logo_key: []const u8,
};

/// A stored company's planning record. `CorruptSave` for an unknown band or
/// base (rule 1).
fn plannedCompany(gs: *const GameState, id: types.MercCompanyId, company: merc_company_mod.MercCompany) error{CorruptSave}!PlannedCompany {
    return .{
        .id = id,
        .band = try rivals.mercCompanyBand(company),
        .base = try npc_base.companyBase(company),
        .cbills = company.cbills,
        .counts = rivals.mercCompanyHullCounts(gs, id),
        .dissolved_day = company.dissolved_day,
        .logo_key = company.logo_key,
    };
}

const PurchaseAcquisition = union(enum) { transfer: types.HullInstanceId, mint: types.HullInstanceId };

const Purchase = struct {
    listing_index: usize,
    listing_id: types.ListingId,
    price: types.CBills,
    acquisition: PurchaseAcquisition,
    /// The day the hull reaches the buyer's base (`npc_base.deliveryArrival`);
    /// null when it is bought on the base world and fieldable at once.
    arrive_day: ?u32,
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

const LifecycleStage = struct {
    merc_companies: std.AutoArrayHashMapUnmanaged(types.MercCompanyId, merc_company_mod.MercCompany),
    merc_company_rosters: std.AutoArrayHashMapUnmanaged(types.MercCompanyId, std.ArrayListUnmanaged(types.HullInstanceId)),
    market_listings: std.ArrayListUnmanaged(market.Listing),
    hull_ownership_history: std.ArrayListUnmanaged(hull_instance_mod.HullOwnershipHistory),
    hull_instances: std.AutoArrayHashMapUnmanaged(types.HullInstanceId, hull_instance_mod.HullInstance),
    merc_hull_arrivals: std.AutoArrayHashMapUnmanaged(types.HullInstanceId, u32),
    next_listing_id: u32,
    next_merc_company_id: u32,
    next_hull_instance_id: u32,
};

const LifecycleAction = union(enum) {
    buy: BuyPlan,
    liquidate: struct {
        company_id: types.MercCompanyId,
        cause: DissolutionCause,
        listings: []const market.Listing,
    },
    spawn: ReplacementPlan,
    replace: struct {
        dissolved_id: types.MercCompanyId,
        cause: DissolutionCause,
        liquidation_listings: []const market.Listing,
        replacement: ReplacementPlan,
    },
    /// A surviving company's new `understrength_since`, judged after its buy.
    record_understrength: struct {
        company_id: types.MercCompanyId,
        since: ?u32,
    },
};

/// Why a merc company dissolved, as its campaign-log line names it.
pub const DissolutionCause = union(enum) {
    /// Cash below zero, below its band's line for at least
    /// `npc_understrength_runway_months` whole months, and no active
    /// commitment, all at once (`dissolutionCause`).
    runway_exhausted: struct { understrength_months: u32 },
    /// Liquidated directly while the runway rule did not hold.
    liquidated,
};

/// Single owner of the dissolution rule (docs/p5d-conflict-world-design.md §L7
/// "Dissolution"; rule 20): a company dissolves only when all three hold
/// together on the campaign day: its C-bills are below zero; it has been below
/// its band's line (`rivals.mercCompanyUnderstrength`) since its recorded
/// `understrength_since`, at least `npc_understrength_runway_months` whole
/// calendar months ago (`clock.Date.wholeMonthsBack`); and it holds no
/// active commitment (`rivals.mercCompanyCommitted`). Low fieldable BV alone
/// never dissolves a company. Null keeps it. `CorruptSave` for an unknown
/// band or an `understrength_since` after today (rule 1). Pure.
pub fn dissolutionCause(gs: *const GameState, company_id: types.MercCompanyId) error{CorruptSave}!?DissolutionCause {
    const company = gs.merc_companies.get(company_id) orelse return null;
    if (company.cbills >= 0) return null;
    const band = try rivals.mercCompanyBand(company);
    if (!rivals.mercCompanyUnderstrength(band, rivals.mercCompanyHullCounts(gs, company_id))) return null;
    const since = company.understrength_since orelse return null;
    const day = gs.clock.day_index;
    if (since > day) return error.CorruptSave;
    const months = gs.clock.date.wholeMonthsBack(day - since);
    if (months < tuning.generation.npc_understrength_runway_months) return null;
    if (rivals.mercCompanyCommitted(gs, company_id)) return null;
    return .{ .runway_exhausted = .{ .understrength_months = months } };
}

/// A surviving company's `understrength_since` after a monthly pass, judged
/// on its post-buy `counts` (docs/p5d-conflict-world-design.md §L7 step 5):
/// the recorded day is kept while it stays below its line, `day` starts one,
/// and reaching the line clears it. Pure.
fn understrengthSince(band: *const merc_band.Band, counts: rivals.MercHullCounts, recorded: ?u32, day: u32) ?u32 {
    if (!rivals.mercCompanyUnderstrength(band, counts)) return null;
    return recorded orelse day;
}

/// The campaign-log body of a merc company's founding (rule 28): its unit
/// name, commander and faction key. The log adds the date.
pub fn foundingLine(alloc: std.mem.Allocator, company: merc_company_mod.MercCompany) ![]const u8 {
    return std.fmt.allocPrint(alloc, "[merc] {s} founded: commander {s} {s}, faction {s}", .{ company.unit_name, company.commander_first, company.commander_last, company.faction_key });
}

/// The campaign-log body of a merc company's dissolution (rule 28): its unit
/// name and cause. A runway dissolution names its three conditions with the
/// actual months below the line. The log adds the date.
pub fn dissolutionLine(alloc: std.mem.Allocator, company: merc_company_mod.MercCompany, cause: DissolutionCause) ![]const u8 {
    return switch (cause) {
        .runway_exhausted => |runway| std.fmt.allocPrint(alloc, "[merc] {s} dissolved: bankrupt, understrength {d} months, no commitment", .{ company.unit_name, runway.understrength_months }),
        .liquidated => std.fmt.allocPrint(alloc, "[merc] {s} dissolved: liquidated", .{company.unit_name}),
    };
}

/// Prepare the lifecycle lines of `actions` in action order: a dissolution
/// before its replacement's founding; buys and understrength records log
/// nothing. Bodies are formatted
/// in `alloc` and copied into the campaign arena by the final allocation, so
/// call this last, after staging (rule 12).
fn prepareLifecycleLog(gs: *GameState, alloc: std.mem.Allocator, actions: []const LifecycleAction) !GameState.PreparedLogBatch {
    var bodies = std.ArrayListUnmanaged([]const u8).empty;
    for (actions) |action| switch (action) {
        .buy, .record_understrength => {},
        .liquidate => |liquidation| try bodies.append(alloc, try dissolutionLine(alloc, gs.merc_companies.get(liquidation.company_id).?, liquidation.cause)),
        .spawn => |replacement| try bodies.append(alloc, try foundingLine(alloc, replacement.company)),
        .replace => |replace| {
            try bodies.append(alloc, try dissolutionLine(alloc, gs.merc_companies.get(replace.dissolved_id).?, replace.cause));
            try bodies.append(alloc, try foundingLine(alloc, replace.replacement.company));
        },
    };
    return gs.prepareLogBatch(.market, .{}, bodies.items);
}

/// Monthly lifecycle pass (docs/p3f-faction-loop-design.md §5;
/// docs/p5d-conflict-world-design.md §L7).
/// Each initially active company, in id order, either dissolves under
/// `dissolutionCause` and is replaced, or plans its buy and then records its
/// `understrength_since` from the post-buy counts. A replacement carries the
/// pass day when its founding buy leaves it below its line.
/// It stages the complete initial-company pass in reclaimable scratch memory,
/// then reserves persistent storage and commits every action, an
/// understrength record alone included, with the staged RNG state and its
/// campaign-log lines. The commit also drops every hull arrival whose day
/// has come (`npc_base.hullFieldable`), so a pass with nothing else to do
/// still commits when one is due. Company iteration and draw order match the
/// monthly lifecycle rule; replacements are not processed until the next
/// pass.
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
        companies.appendAssumeCapacity(try plannedCompany(gs, id, mc));
    }

    var actions = std.ArrayListUnmanaged(LifecycleAction).empty;
    var rng_copy = gs.rng;
    var next_listing_id = gs.next_listing_id;
    var next_company_id = gs.next_merc_company_id;
    var next_hull_instance_id = gs.next_hull_instance_id;

    for (0..initial) |i| {
        const company = &companies.items[i];
        if (company.dissolved_day != 0) continue;

        if (try dissolutionCause(gs, company.id)) |cause| {
            const liquidation_listings = try planLiquidation(scratch, gs, company.id, day, &next_listing_id);
            // Later buyers in this pass see these listings before their
            // seller's interval is committed.
            const seller = liquidationSeller(gs.merc_companies.get(company.id).?);
            for (liquidation_listings) |listing| try listings.append(scratch, .{ .listing = listing, .staged_seller = seller });
            company.dissolved_day = day;

            const replacement = try planReplacement(
                scratch,
                gs,
                &companies,
                &listings,
                day,
                &rng_copy,
                &next_company_id,
                &next_hull_instance_id,
            );
            try actions.append(scratch, .{ .replace = .{
                .dissolved_id = company.id,
                .cause = cause,
                .liquidation_listings = liquidation_listings,
                .replacement = replacement,
            } });
        } else {
            const buy = try planBuy(scratch, gs, &listings, company, day, &rng_copy, &next_hull_instance_id);
            if (buy.purchases.len > 0) try actions.append(scratch, .{ .buy = buy });
            const recorded = gs.merc_companies.get(company.id).?.understrength_since;
            const since = understrengthSince(company.band, company.counts, recorded, day);
            if (!std.meta.eql(since, recorded)) try actions.append(scratch, .{ .record_understrength = .{ .company_id = company.id, .since = since } });
        }
    }

    if (actions.items.len == 0 and !arrivalsDue(gs, day)) return;

    const transaction_arena = try gs.lifecycleArena();
    errdefer gs.discardLifecycleArena(transaction_arena);
    const transaction_alloc = transaction_arena.arena.allocator();
    try allocateReplacementNames(transaction_alloc, scratch, gs, actions.items);
    const stage = try stageLifecycleCommit(gs, transaction_alloc, actions.items, next_listing_id, next_company_id, next_hull_instance_id, day);
    const log = try prepareLifecycleLog(gs, transaction_alloc, actions.items);
    gs.replaceLifecycleArena(transaction_arena);

    commitLifecycleStage(gs, stage);
    gs.commitLogBatch(log);
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

fn planReplacement(scratch: std.mem.Allocator, gs: *GameState, companies: *std.ArrayListUnmanaged(PlannedCompany), listings: *std.ArrayListUnmanaged(PlannedListing), day: u32, rng: *rng_mod.Rng, next_company_id: *u32, next_hull_instance_id: *u32) !ReplacementPlan {
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
    // The founding buy reaches from the base, so the base is drawn first.
    const base = npc_base.drawBase(rng, faction.key) orelse return error.CorruptSave;
    // `companies` holds every company, dissolved ones and this pass's earlier
    // replacements included, so no key is ever handed out twice.
    const held = try scratch.alloc([]const u8, companies.items.len);
    for (companies.items, held) |company, *key| key.* = company.logo_key;
    const logo_key = merc_identity.firstUnusedLogo(gs.player_logo_key, held);

    const id: types.MercCompanyId = @enumFromInt(next_company_id.*);
    next_company_id.* += 1;
    const band = merc_band.replacementBand();
    var company = PlannedCompany{ .id = id, .band = band, .base = base, .cbills = band.capital_cbills, .counts = .{}, .dissolved_day = 0, .logo_key = logo_key };
    try companies.append(scratch, company);
    const buy = try planBuy(scratch, gs, listings, &company, day, rng, next_hull_instance_id);
    companies.items[companies.items.len - 1].counts = company.counts;
    companies.items[companies.items.len - 1].cbills = company.cbills;
    return .{
        .company = .{ .id = id, .archetype_key = archetype.key, .commander_first = identity.first, .commander_last = identity.last, .faction_key = faction.key, .side = identity.side, .doctrine = identity.doctrine, .cbills = band.capital_cbills, .founded_day = day, .logo_key = logo_key, .band_key = band.key, .understrength_since = understrengthSince(band, company.counts, null, day), .home_planet_key = base.key, .ready_day = day },
        .unit_name_parts = .{ .last = identity.last, .noun = archetype.unit_noun },
        .buy = if (buy.purchases.len > 0) buy else null,
    };
}

/// Select one NPC procurement intent. Priority is mek, vehicle substitution,
/// then aerospace reserve; candidate order is the market board's stable order.
/// A listing the company's base cannot reach is never a candidate
/// (`npc_base.listingReachable`; docs/p5d-conflict-world-design.md D21).
/// Failed availability, affordability or reach searches draw no RNG. The
/// purchase carries the hull's `npc_base.deliveryArrival` from its source.
fn selectNpcProcurement(scratch: std.mem.Allocator, gs: *GameState, listings: *std.ArrayListUnmanaged(PlannedListing), company: *PlannedCompany, day: u32, rng: *rng_mod.Rng, next_hull_instance_id: *u32) !?Purchase {
    const counts = company.counts;
    const band = company.band;
    var wanted_kind: unit.UnitKind = if (rivals.mercCompanyNeedsHull(band, counts, .mek)) .mek else if (rivals.mercCompanyNeedsHull(band, counts, .vehicle)) .vehicle else if (rivals.mercCompanyNeedsHull(band, counts, .aerospace)) .aerospace else return null;
    var candidates = std.ArrayListUnmanaged(usize).empty;
    collect: while (true) {
        for (listings.items, 0..) |planned, i| {
            const listing = planned.listing;
            if (!planned.available or listing.kind != .unit or listing.price > company.cbills) continue;
            if (listing.available_after > day) continue;
            if (listing.black_market and !black_market.buyerEligible(gs, listing, .merc_company, day)) continue;
            const chassis = chassis_mod.find(listing.item_key) orelse continue;
            if (chassis.kind != wanted_kind) continue;
            if (wanted_kind == .mek and listing.hull_instance_id == .none) continue;
            if ((wanted_kind == .vehicle or wanted_kind == .aerospace) and !chassis_mod.conventionalMarketEligible(chassis, gs.clock.date.year)) continue;
            if (!try npc_base.listingReachable(gs, company.base, listing, planned.staged_seller)) continue;
            try candidates.append(scratch, i);
        }
        if (candidates.items.len > 0) break :collect;
        if (wanted_kind == .mek and rivals.mercCompanyNeedsHull(band, counts, .vehicle)) {
            wanted_kind = .vehicle;
            continue :collect;
        }
        if (wanted_kind != .aerospace and rivals.mercCompanyNeedsHull(band, counts, .aerospace)) {
            wanted_kind = .aerospace;
            continue :collect;
        }
        return null;
    }
    if (candidates.items.len == 0) return null;
    const listing_index = candidates.items[rng.random(.market).uintLessThan(usize, candidates.items.len)];
    const listing = listings.items[listing_index].listing;
    const source = try npc_base.listingSource(gs, listing, listings.items[listing_index].staged_seller);
    const acquisition: PurchaseAcquisition = if (listing.hull_instance_id == .none) blk: {
        if (next_hull_instance_id.* == std.math.maxInt(u32)) return error.HullInstanceIdExhausted;
        const id: types.HullInstanceId = @enumFromInt(next_hull_instance_id.*);
        next_hull_instance_id.* += 1;
        break :blk .{ .mint = id };
    } else .{ .transfer = listing.hull_instance_id };
    listings.items[listing_index].available = false;
    company.cbills -= listing.price;
    switch (wanted_kind) {
        .mek => company.counts.meks += 1,
        .vehicle => company.counts.vehicles += 1,
        .aerospace => company.counts.aerospace += 1,
        else => unreachable,
    }
    return .{ .listing_index = listing_index, .listing_id = listing.id, .price = listing.price, .acquisition = acquisition, .arrive_day = npc_base.deliveryArrival(source.origin(), company.base, day) };
}

fn planBuy(scratch: std.mem.Allocator, gs: *GameState, listings: *std.ArrayListUnmanaged(PlannedListing), company: *PlannedCompany, day: u32, rng: *rng_mod.Rng, next_hull_instance_id: *u32) !BuyPlan {
    var purchases = std.ArrayListUnmanaged(Purchase).empty;
    while (try selectNpcProcurement(scratch, gs, listings, company, day, rng, next_hull_instance_id)) |purchase| {
        try purchases.append(scratch, purchase);
    }
    const remove_order = try scratch.dupe(Purchase, purchases.items);
    std.mem.sort(Purchase, remove_order, {}, struct {
        fn descending(_: void, a: Purchase, b: Purchase) bool {
            return a.listing_index > b.listing_index;
        }
    }.descending);
    return .{ .company_id = company.id, .purchases = try purchases.toOwnedSlice(scratch), .remove_order = remove_order };
}

/// Name every replacement in `actions`, in action order, through
/// `merc_identity.unitName` against every existing company name and the names
/// given to earlier replacements in the same pass. Names live in `alloc`, the
/// transaction arena; the taken list lives in the operation's `scratch` and is
/// released on return (rule 78).
fn allocateReplacementNames(alloc: std.mem.Allocator, scratch: std.mem.Allocator, gs: *const GameState, actions: []LifecycleAction) !void {
    var taken = std.ArrayListUnmanaged([]const u8).empty;
    defer taken.deinit(scratch);
    var taken_listed = false;
    for (actions) |*action| {
        const replacement: *ReplacementPlan = switch (action.*) {
            .spawn => |*replacement| replacement,
            .replace => |*replace| &replace.replacement,
            .buy, .liquidate, .record_understrength => continue,
        };
        if (!taken_listed) {
            try taken.ensureTotalCapacity(scratch, gs.merc_companies.count() + actions.len);
            for (gs.merc_companies.values()) |company| taken.appendAssumeCapacity(company.unit_name);
            taken_listed = true;
        }
        const parts = replacement.unit_name_parts;
        replacement.company.unit_name = try merc_identity.unitName(alloc, taken.items, parts.last, parts.noun);
        taken.appendAssumeCapacity(replacement.company.unit_name);
    }
}

fn stageLifecycleCommit(
    gs: *const GameState,
    alloc: std.mem.Allocator,
    actions: []const LifecycleAction,
    next_listing_id: u32,
    next_merc_company_id: u32,
    next_hull_instance_id: u32,
    day: u32,
) !LifecycleStage {
    var stage = LifecycleStage{
        .merc_companies = .empty,
        .merc_company_rosters = .empty,
        .market_listings = .empty,
        .hull_ownership_history = .empty,
        .hull_instances = .empty,
        .merc_hull_arrivals = .empty,
        .next_listing_id = next_listing_id,
        .next_merc_company_id = next_merc_company_id,
        .next_hull_instance_id = next_hull_instance_id,
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
    try stage.hull_instances.ensureTotalCapacity(alloc, gs.hull_instances.count());
    for (gs.hull_instances.keys(), gs.hull_instances.values()) |id, source| {
        var hull = source;
        hull.loadout = .empty;
        try hull.loadout.appendSlice(alloc, source.loadout.items);
        stage.hull_instances.putAssumeCapacity(id, hull);
    }
    // An arrival whose day has come is dropped: the hull is fieldable.
    try stage.merc_hull_arrivals.ensureTotalCapacity(alloc, gs.merc_hull_arrivals.count());
    for (gs.merc_hull_arrivals.keys(), gs.merc_hull_arrivals.values()) |hull_id, arrive_day| {
        if (!npc_base.hullFieldable(gs, hull_id, day)) stage.merc_hull_arrivals.putAssumeCapacity(hull_id, arrive_day);
    }

    for (actions) |action| switch (action) {
        .buy => |buy| try stageBuy(&stage, alloc, buy, day),
        .liquidate => |liquidation| try stageLiquidation(&stage, alloc, liquidation.company_id, liquidation.listings, day),
        .spawn => |replacement| try stageReplacement(&stage, alloc, replacement, day),
        .replace => |replace| {
            try stageLiquidation(&stage, alloc, replace.dissolved_id, replace.liquidation_listings, day);
            try stageReplacement(&stage, alloc, replace.replacement, day);
        },
        .record_understrength => |record| stage.merc_companies.getPtr(record.company_id).?.understrength_since = record.since,
    };
    return stage;
}

fn stageLiquidation(stage: *LifecycleStage, alloc: std.mem.Allocator, company_id: types.MercCompanyId, listings: []const market.Listing, day: u32) !void {
    const company = stage.merc_companies.getPtr(company_id).?;
    if (stage.merc_company_rosters.getPtr(company_id)) |roster| {
        for (roster.items, 0..) |hull_id, i| {
            stage.hull_instances.getPtr(hull_id).?.owner = .market;
            closeOwnershipHistory(&stage.hull_ownership_history, hull_id, day);
            try stage.hull_ownership_history.append(alloc, .{
                .hull_instance_id = hull_id,
                .from_day = day,
                .acquisition_type = .transfer,
                .prior_owner_key = liquidationSeller(company.*),
            });
            try stage.market_listings.append(alloc, listings[i]);
            // A liquidated hull still travelling to the base is listed where
            // it is; it has no arrival any more (false when it had arrived).
            _ = stage.merc_hull_arrivals.orderedRemove(hull_id);
        }
        roster.clearRetainingCapacity();
    }
    company.dissolved_day = day;
}

fn stageReplacement(stage: *LifecycleStage, alloc: std.mem.Allocator, replacement: ReplacementPlan, day: u32) !void {
    try stage.merc_companies.put(alloc, replacement.company.id, replacement.company);
    // A company holds its roster entry from spawn, even with nothing bought.
    try stage.merc_company_rosters.put(alloc, replacement.company.id, .empty);
    if (replacement.buy) |buy| try stageBuy(stage, alloc, buy, day);
}

fn stageBuy(stage: *LifecycleStage, alloc: std.mem.Allocator, buy: BuyPlan, day: u32) !void {
    if (!stage.merc_company_rosters.contains(buy.company_id)) {
        try stage.merc_company_rosters.put(alloc, buy.company_id, .empty);
    }
    var spent: types.CBills = 0;
    const roster = stage.merc_company_rosters.getPtr(buy.company_id).?;
    for (buy.purchases) |purchase| {
        const hull_id = switch (purchase.acquisition) {
            .transfer => |id| blk: {
                const hull = stage.hull_instances.getPtr(id).?;
                hull.owner = .{ .merc_company = buy.company_id };
                hull.status = .active;
                closeOwnershipHistory(&stage.hull_ownership_history, id, day);
                try stage.hull_ownership_history.append(alloc, .{ .hull_instance_id = id, .from_day = day, .acquisition_type = .transfer, .prior_owner_key = "market" });
                break :blk id;
            },
            .mint => |id| blk: {
                const listing = findListing(stage.market_listings.items, purchase.listing_id).?;
                const chassis = chassis_mod.find(listing.item_key).?;
                var hull: hull_instance_mod.HullInstance = .{
                    .id = id,
                    .base_key = chassis.key,
                    .status = .active,
                    .intro_year = chassis.intro_year,
                    .owner = .{ .merc_company = buy.company_id },
                };
                try hull.loadout.ensureTotalCapacity(alloc, chassis.loadout.len);
                for (chassis.loadout) |slot| hull.loadout.appendAssumeCapacity(.{ .part_key = slot.part });
                try stage.hull_instances.put(alloc, id, hull);
                try stage.hull_ownership_history.append(alloc, .{ .hull_instance_id = id, .from_day = day, .acquisition_type = .purchase, .prior_owner_key = "market" });
                break :blk id;
            },
        };
        try roster.append(alloc, hull_id);
        if (purchase.arrive_day) |arrive_day| try stage.merc_hull_arrivals.put(alloc, hull_id, arrive_day);
        spent += purchase.price;
    }
    stage.merc_companies.getPtr(buy.company_id).?.cbills -= spent;
    for (buy.remove_order) |purchase| {
        _ = stage.market_listings.orderedRemove(indexOfListing(stage.market_listings.items, purchase.listing_id));
    }
}

fn closeOwnershipHistory(history: *std.ArrayListUnmanaged(hull_instance_mod.HullOwnershipHistory), hull_id: types.HullInstanceId, day: u32) void {
    for (history.items) |*entry| {
        if (entry.hull_instance_id == hull_id and entry.isOpen()) entry.close(day);
    }
}

fn commitLifecycleStage(gs: *GameState, stage: LifecycleStage) void {
    gs.merc_companies = stage.merc_companies;
    gs.merc_company_rosters = stage.merc_company_rosters;
    gs.releaseMercCompanyRosterLifecycleArena();
    gs.market_listings = stage.market_listings;
    gs.hull_ownership_history = stage.hull_ownership_history;
    gs.hull_instances = stage.hull_instances;
    gs.merc_hull_arrivals = stage.merc_hull_arrivals;
    gs.next_listing_id = stage.next_listing_id;
    gs.next_merc_company_id = stage.next_merc_company_id;
    gs.next_hull_instance_id = stage.next_hull_instance_id;
}

/// Whether some hull arrival is due on `day` (`npc_base.hullFieldable`), so
/// the monthly pass must commit to drop it.
fn arrivalsDue(gs: *const GameState, day: u32) bool {
    for (gs.merc_hull_arrivals.keys()) |hull_id| {
        if (npc_base.hullFieldable(gs, hull_id, day)) return true;
    }
    return false;
}

fn findListing(listings: []const market.Listing, id: types.ListingId) ?market.Listing {
    for (listings) |listing| if (listing.id == id) return listing;
    return null;
}

fn indexOfListing(listings: []const market.Listing, id: types.ListingId) usize {
    for (listings, 0..) |listing, i| if (listing.id == id) return i;
    unreachable;
}

// ---- Tests -----------------------------------------------------------------

const digest = @import("digest.zig");
const founding = @import("founding.zig");

/// The band of the fixture companies below: one whose line takes vehicles, so
/// vehicle substitution applies to them.
const test_band = "band_3";

fn testLineTarget() usize {
    return merc_band.lineTarget(merc_band.find(test_band).?);
}

/// The base of the fixture companies below, all of faction DC: the DC
/// capital, so a DC-sold wholesale listing is delivered on their base world
/// and fieldable at once (`npc_base.listingSource`).
const test_base = "luthien";

/// Make a market hull a DC-sold wholesale listing's hull: its one open
/// ownership interval names DC.
fn sellAsDcSurplusForTest(gs: *GameState, hull_id: types.HullInstanceId) !void {
    try gs.hull_ownership_history.append(gs.allocator(), .{ .hull_instance_id = hull_id, .acquisition_type = .initial, .prior_owner_key = "DC" });
}

/// A field HQ on the fixture base world: its board carries the fixtures'
/// minted conventional listings where the companies stand.
fn baseBoardForTest(gs: *GameState) !types.HqId {
    return boardOnForTest(gs, test_base);
}

/// A field HQ on `world`, whose board stands there.
fn boardOnForTest(gs: *GameState, world: []const u8) !types.HqId {
    const id: types.HqId = @enumFromInt(gs.next_hq_id);
    gs.next_hq_id += 1;
    try gs.hqs.put(gs.allocator(), id, .{ .id = id, .name = "Board", .tier = .field, .planet_key = world });
    return id;
}

/// A market LCT-1V on `board`'s board at `price`, its listing on that world.
fn listMekOnBoardForTest(gs: *GameState, board: types.HqId, price: types.CBills) !types.HullInstanceId {
    const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
    try sellAsDcSurplusForTest(gs, hull_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = price, .hq = board, .hull_instance_id = hull_id });
    gs.next_listing_id += 1;
    return hull_id;
}

/// A DC-sold world-less LCT-1V at `price`: wholesale from Luthien.
fn listDcSurplusMekForTest(gs: *GameState, price: types.CBills) !types.HullInstanceId {
    const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
    try sellAsDcSurplusForTest(gs, hull_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = price, .hull_instance_id = hull_id });
    gs.next_listing_id += 1;
    return hull_id;
}

/// The first catalog world of `faction_key` (any faction when null) other
/// than `from` whose distance from it is within `min_ly`..`max_ly`,
/// inclusive.
fn worldAtForTest(faction_key: ?[]const u8, from: []const u8, min_ly: u32, max_ly: u32) !*const planet.Planet {
    const origin = planet.find(from).?;
    for (planet.catalog) |*p| {
        if (p == origin) continue;
        if (faction_key) |key| if (!std.mem.eql(u8, p.faction, key)) continue;
        const ly = planet.distanceLy(origin, p);
        if (ly >= min_ly and ly <= max_ly) return p;
    }
    return error.TestUnexpectedResult;
}

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
        .band_key = test_band,
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
            .to_day = null,
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
        .band_key = test_band,
        .dissolved_day = 0,
    });
    const hid: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V", .owner = .{ .merc_company = mcid } });
    try gs.hull_ownership_history.append(alloc, .{
        .hull_instance_id = hid,
        .from_day = 0,
        .to_day = null,
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
        .band_key = test_band,
        .dissolved_day = 0,
        .cbills = cbills_start,
        .home_planet_key = test_base,
    });

    // Add 2 affordable regular listings (< cbills) and 1 unaffordable.
    const h1: types.HullInstanceId = @enumFromInt(1);
    const h2: types.HullInstanceId = @enumFromInt(2);
    const h3: types.HullInstanceId = @enumFromInt(3);
    try gs.hull_instances.put(alloc, h1, .{ .id = h1, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_instances.put(alloc, h2, .{ .id = h2, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_instances.put(alloc, h3, .{ .id = h3, .base_key = "JR7-D", .owner = .market });
    for ([_]types.HullInstanceId{ h1, h2, h3 }) |h| try sellAsDcSurplusForTest(&gs, h);
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
    // Company is still under its band's line target.
    try std.testing.expect(roster.items.len < testLineTarget());
}

test "selectNpcProcurement: affordable mek beats affordable vehicle" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2026 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Procurement Co", .faction_key = "DC", .band_key = test_band, .cbills = 10, .home_planet_key = test_base });
    const board = try baseBoardForTest(&gs);
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    for (0..testLineTarget() - 1) |_| {
        const id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), id, .{ .id = id, .base_key = "LCT-1V", .owner = .{ .merc_company = company_id } });
        try roster.append(gs.allocator(), id);
    }
    try gs.merc_company_rosters.put(gs.allocator(), company_id, roster);
    const backed_mek: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), backed_mek, .{ .id = backed_mek, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_ownership_history.append(gs.allocator(), .{ .hull_instance_id = backed_mek, .acquisition_type = .initial, .prior_owner_key = "DC" });
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = backed_mek });
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(2), .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1, .hq = board });
    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);
    const counts = rivals.mercCompanyHullCounts(&gs, company_id);
    try std.testing.expectEqual(@as(usize, testLineTarget()), counts.meks);
    try std.testing.expectEqual(@as(usize, 0), counts.vehicles);
    try std.testing.expectEqual(@as(usize, 1), gs.market_listings.items.len);
    try std.testing.expectEqualStrings("SCP-1N", gs.market_listings.items[0].item_key);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = company_id }, gs.hull_instances.get(backed_mek).?.owner);
    try std.testing.expectEqual(@as(?u32, 1), gs.hull_ownership_history.items[0].to_day);
    try std.testing.expectEqual(hull_instance_mod.AcquisitionType.transfer, gs.hull_ownership_history.items[1].acquisition_type);
    try std.testing.expectEqualStrings("market", gs.hull_ownership_history.items[1].prior_owner_key);
}

test "selectNpcProcurement: a later mek remains eligible after vehicle substitution" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2027 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Substitution Co", .faction_key = "DC", .band_key = test_band, .cbills = 10, .home_planet_key = test_base });
    const board = try baseBoardForTest(&gs);
    const mek: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    const later_mek: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), mek, .{ .id = mek, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_instances.put(gs.allocator(), later_mek, .{ .id = later_mek, .base_key = "LCT-1V", .owner = .market });
    try sellAsDcSurplusForTest(&gs, mek);
    try sellAsDcSurplusForTest(&gs, later_mek);
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 11, .hull_instance_id = mek });
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(2), .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1, .hq = board });
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(3), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = later_mek, .available_after = 2 });
    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);
    try std.testing.expectEqual(@as(usize, 0), rivals.mercCompanyHullCounts(&gs, company_id).meks);
    try std.testing.expectEqual(@as(usize, 1), rivals.mercCompanyHullCounts(&gs, company_id).vehicles);
    try std.testing.expectEqual(@as(usize, 2), gs.market_listings.items.len);
    try std.testing.expectEqual(mek, gs.market_listings.items[0].hull_instance_id);

    try buyHullsForCompany(&gs, a, company_id, 2, &rng);
    try std.testing.expectEqual(@as(usize, 1), rivals.mercCompanyHullCounts(&gs, company_id).meks);
    try std.testing.expectEqual(@as(usize, 1), rivals.mercCompanyHullCounts(&gs, company_id).vehicles);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = company_id }, gs.hull_instances.get(later_mek).?.owner);
}

test "selectNpcProcurement: fighters fill only the air reserve" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 20271 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Air Reserve Co", .faction_key = "DC", .band_key = test_band, .cbills = 100, .home_planet_key = test_base });
    const board = try baseBoardForTest(&gs);
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    for (0..testLineTarget()) |i| {
        const id: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(gs.allocator(), id, .{ .id = id, .base_key = "LCT-1V", .owner = .{ .merc_company = company_id } });
        try roster.append(gs.allocator(), id);
    }
    try gs.merc_company_rosters.put(gs.allocator(), company_id, roster);
    gs.next_hull_instance_id = @intCast(testLineTarget() + 1);
    const air_target = @as(usize, tuning.generation.merc_company_air_reserve_lances) * force.lance_size;
    for (0..air_target + 1) |i| {
        try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1 + @as(u32, @intCast(i))), .kind = .unit, .item_key = "TR-7", .rarity = .common, .price = 1, .hq = board });
    }

    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);

    const counts = rivals.mercCompanyHullCounts(&gs, company_id);
    try std.testing.expectEqual(@as(usize, testLineTarget()), counts.meks);
    try std.testing.expectEqual(@as(usize, 0), counts.vehicles);
    try std.testing.expectEqual(air_target, counts.aerospace);
    try std.testing.expectEqual(@as(usize, 1), gs.market_listings.items.len);
}

test "selectNpcProcurement: fighters never fill line positions" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 20273 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Fighter Only Co", .faction_key = "DC", .band_key = test_band, .cbills = 100, .home_planet_key = test_base });
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "TR-7", .rarity = .common, .price = 1, .hq = try baseBoardForTest(&gs) });

    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);

    const counts = rivals.mercCompanyHullCounts(&gs, company_id);
    try std.testing.expectEqual(@as(usize, 0), counts.meks);
    try std.testing.expectEqual(@as(usize, 0), counts.vehicles);
    try std.testing.expectEqual(@as(usize, 1), counts.aerospace);
    try std.testing.expectEqual(@as(usize, 0), gs.market_listings.items.len);
}

/// A company of `band_key` one mek short of its line target, its air reserve
/// full or empty, facing a market of one affordable minted vehicle (and one
/// affordable fighter while its reserve is short) and no mek.
fn seedBandProcurementFixture(gs: *GameState, band_key: []const u8, reserve_full: bool) !types.MercCompanyId {
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    const alloc = gs.allocator();
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Band Co", .faction_key = "DC", .band_key = band_key, .cbills = 100, .home_planet_key = test_base });
    const board = try baseBoardForTest(gs);
    const meks = merc_band.lineTarget(merc_band.find(band_key).?) - 1;
    const fighters = if (reserve_full) @as(usize, tuning.generation.merc_company_air_reserve_lances) * force.lance_size else 0;
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    for (0..meks + fighters) |i| {
        const id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        const key = if (i < meks) "LCT-1V" else "TR-7";
        try gs.hull_instances.put(alloc, id, .{ .id = id, .base_key = key, .owner = .{ .merc_company = company_id } });
        try roster.append(alloc, id);
    }
    try gs.merc_company_rosters.put(alloc, company_id, roster);
    try gs.market_listings.append(alloc, .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1, .hq = board });
    if (!reserve_full) try gs.market_listings.append(alloc, .{ .id = @enumFromInt(2), .kind = .unit, .item_key = "TR-7", .rarity = .common, .price = 1, .hq = board });
    return company_id;
}

test "selectNpcProcurement: a band that fills its line with meks only never buys a vehicle" {
    const a = std.testing.allocator;
    // band_4 under target with its reserve full: nothing to buy, no RNG draw.
    {
        var gs = GameState.init(a, .{ .seed = 2031 });
        defer gs.deinit();
        const company_id = try seedBandProcurementFixture(&gs, "band_4", true);
        const before = digest.stateHash(&gs);
        var rng = gs.rng;
        const rng_before = rng;
        try buyHullsForCompany(&gs, a, company_id, 1, &rng);
        try std.testing.expectEqual(before, digest.stateHash(&gs));
        try std.testing.expectEqual(rng_before, rng);
        try std.testing.expectEqual(@as(usize, 0), rivals.mercCompanyHullCounts(&gs, company_id).vehicles);
    }
    // band_4 under target with its reserve short: the fighter, never the vehicle.
    {
        var gs = GameState.init(a, .{ .seed = 2032 });
        defer gs.deinit();
        const company_id = try seedBandProcurementFixture(&gs, "band_4", false);
        var rng = gs.rng;
        try buyHullsForCompany(&gs, a, company_id, 1, &rng);
        const counts = rivals.mercCompanyHullCounts(&gs, company_id);
        try std.testing.expectEqual(@as(usize, 0), counts.vehicles);
        try std.testing.expectEqual(@as(usize, 1), counts.aerospace);
        try std.testing.expectEqual(@as(usize, 1), gs.market_listings.items.len);
        try std.testing.expectEqualStrings("SCP-1N", gs.market_listings.items[0].item_key);
    }
    // band_3 in the same market as the first case: it buys the vehicle.
    {
        var gs = GameState.init(a, .{ .seed = 2031 });
        defer gs.deinit();
        const company_id = try seedBandProcurementFixture(&gs, "band_3", true);
        var rng = gs.rng;
        try buyHullsForCompany(&gs, a, company_id, 1, &rng);
        try std.testing.expectEqual(@as(usize, 1), rivals.mercCompanyHullCounts(&gs, company_id).vehicles);
        try std.testing.expectEqual(@as(usize, 0), gs.market_listings.items.len);
    }
}

test "selectNpcProcurement: a full vehicle line does not block a later mek" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 20272 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Ground Co", .faction_key = "DC", .band_key = test_band, .cbills = 100, .home_planet_key = test_base });
    const board = try baseBoardForTest(&gs);
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    for (0..testLineTarget()) |i| {
        const id: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(gs.allocator(), id, .{ .id = id, .base_key = "SCP-1N", .owner = .{ .merc_company = company_id } });
        try roster.append(gs.allocator(), id);
        try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1 + @as(u32, @intCast(i))), .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1, .hq = board });
    }
    try gs.merc_company_rosters.put(gs.allocator(), company_id, roster);
    gs.next_hull_instance_id = @intCast(testLineTarget() + 1);
    const later_mek: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), later_mek, .{ .id = later_mek, .base_key = "LCT-1V", .owner = .market });
    try sellAsDcSurplusForTest(&gs, later_mek);
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(testLineTarget() + 1), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = later_mek });

    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);

    const counts = rivals.mercCompanyHullCounts(&gs, company_id);
    try std.testing.expectEqual(@as(usize, 1), counts.meks);
    try std.testing.expectEqual(@as(usize, testLineTarget()), counts.vehicles);
    try std.testing.expectEqual(@as(usize, 0), counts.aerospace);
    try std.testing.expectEqual(@as(usize, testLineTarget()), gs.market_listings.items.len);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = company_id }, gs.hull_instances.get(later_mek).?.owner);
}

test "selectNpcProcurement: a full vehicle line buys air reserve before a later mek" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 20274 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Air Reserve Substitution Co", .faction_key = "DC", .band_key = test_band, .cbills = 100, .home_planet_key = test_base });
    const board = try baseBoardForTest(&gs);
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    for (0..testLineTarget()) |i| {
        const id: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(gs.allocator(), id, .{ .id = id, .base_key = "SCP-1N", .owner = .{ .merc_company = company_id } });
        try roster.append(gs.allocator(), id);
    }
    try gs.merc_company_rosters.put(gs.allocator(), company_id, roster);
    gs.next_hull_instance_id = @intCast(testLineTarget() + 1);
    const later_mek: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), later_mek, .{ .id = later_mek, .base_key = "LCT-1V", .owner = .market });
    try sellAsDcSurplusForTest(&gs, later_mek);
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = later_mek, .available_after = 2 });
    const air_target = @as(usize, tuning.generation.merc_company_air_reserve_lances) * force.lance_size;
    for (0..air_target) |i| {
        try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(2 + @as(u32, @intCast(i))), .kind = .unit, .item_key = "TR-7", .rarity = .common, .price = 1, .hq = board });
    }

    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);
    var counts = rivals.mercCompanyHullCounts(&gs, company_id);
    try std.testing.expectEqual(@as(usize, 0), counts.meks);
    try std.testing.expectEqual(@as(usize, testLineTarget()), counts.vehicles);
    try std.testing.expectEqual(air_target, counts.aerospace);
    try std.testing.expectEqual(hull_instance_mod.HullOwner.market, gs.hull_instances.get(later_mek).?.owner);
    try std.testing.expectEqual(@as(usize, 1), gs.market_listings.items.len);

    try buyHullsForCompany(&gs, a, company_id, 2, &rng);
    counts = rivals.mercCompanyHullCounts(&gs, company_id);
    try std.testing.expectEqual(@as(usize, 1), counts.meks);
    try std.testing.expectEqual(@as(usize, testLineTarget()), counts.vehicles);
    try std.testing.expectEqual(air_target, counts.aerospace);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = company_id }, gs.hull_instances.get(later_mek).?.owner);
    try std.testing.expectEqual(@as(usize, 0), gs.market_listings.items.len);
}

test "selectNpcProcurement: minted vehicle has design loadout and purchase provenance" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2028 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Mint Co", .faction_key = "DC", .band_key = test_band, .cbills = 10, .home_planet_key = test_base });
    const minted_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1, .hq = try baseBoardForTest(&gs) });
    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);
    const hull = gs.hull_instances.get(minted_id).?;
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = company_id }, hull.owner);
    try std.testing.expectEqual(@as(usize, chassis_mod.find("SCP-1N").?.loadout.len), hull.loadout.items.len);
    try std.testing.expectEqual(hull_instance_mod.AcquisitionType.purchase, gs.hull_ownership_history.items[0].acquisition_type);
    try std.testing.expectEqualStrings("market", gs.hull_ownership_history.items[0].prior_owner_key);
}

test "buyHullsForCompany: saturated minted hull ID refuses without mutation or RNG draw" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2030 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{
        .id = company_id,
        .archetype_key = "enemy_raiders",
        .unit_name = "Saturated Co",
        .faction_key = "DC",
        .band_key = test_band,
        .cbills = 10,
        .home_planet_key = test_base,
    });
    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .kind = .unit,
        .item_key = "SCP-1N",
        .rarity = .common,
        .price = 1,
        .hq = try baseBoardForTest(&gs),
    });
    gs.next_hull_instance_id = std.math.maxInt(u32);

    const state_before = digest.stateHash(&gs);
    const id_before = gs.next_hull_instance_id;
    var rng = gs.rng;
    const rng_before = rng;
    try std.testing.expectError(error.HullInstanceIdExhausted, buyHullsForCompany(&gs, a, company_id, 1, &rng));
    try std.testing.expectEqual(state_before, digest.stateHash(&gs));
    try std.testing.expectEqual(id_before, gs.next_hull_instance_id);
    try std.testing.expectEqual(rng_before, rng);
}

test "selectNpcProcurement: future listing admits no candidate, mutation, or RNG draw" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 2029 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const company_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), company_id, .{ .id = company_id, .archetype_key = "enemy_raiders", .unit_name = "Waiting Co", .faction_key = "DC", .band_key = test_band, .cbills = 10, .home_planet_key = test_base });
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(1), .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 1, .available_after = 2, .hq = try baseBoardForTest(&gs) });
    const before = digest.stateHash(&gs);
    var rng = gs.rng;
    const rng_before = rng;
    try buyHullsForCompany(&gs, a, company_id, 1, &rng);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(rng_before, rng);
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
        .band_key = test_band,
        .dissolved_day = 0,
        .cbills = 10_000_000,
        .home_planet_key = test_base,
    });
    const h1: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(alloc, h1, .{ .id = h1, .base_key = "LCT-1V", .owner = .market });
    try sellAsDcSurplusForTest(&gs, h1);
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
            .band_key = test_band,
            .cbills = 10_000_000,
            .home_planet_key = test_base,
        });
        try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
        try sellAsDcSurplusForTest(&gs, hull_id);
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

test "spawnReplacementCompany: unique id, founded_day, dissolved_day==0, lowest band and its capital, logo distinct from active" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const alloc = gs.allocator();
    // An empty market: the replacement buys nothing, so it keeps its founding capital.
    gs.market_listings.clearRetainingCapacity();

    // Seed one active company with the first logo key to verify the spawn picks a different one.
    const existing_id: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, existing_id, merc_company_mod.MercCompany{
        .id = existing_id,
        .archetype_key = "enemy_raiders",
        .unit_name = "Existing Co",
        .faction_key = "DC",
        .band_key = test_band,
        .dissolved_day = 0,
        .logo_key = logo.all_keys[0],
        .home_planet_key = test_base,
    });
    gs.next_merc_company_id = 2;

    var rng = gs.rng;
    const log_before = gs.event_log.items.len;
    const new_id = try spawnReplacementCompany(&gs, alloc, 60, &rng);

    // Exactly one founding line, naming the new company.
    try std.testing.expectEqual(log_before + 1, gs.event_log.items.len);
    const expected_line = try foundingLine(a, gs.merc_companies.get(new_id).?);
    defer a.free(expected_line);
    try std.testing.expect(std.mem.endsWith(u8, gs.event_log.items[log_before].text, expected_line));
    // Its roster entry exists from spawn.
    try std.testing.expect(gs.merc_company_rosters.contains(new_id));

    // A new company was added.
    try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
    try std.testing.expectEqual(@as(types.MercCompanyId, @enumFromInt(2)), new_id);
    const spawned = gs.merc_companies.getPtr(new_id) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 60), spawned.founded_day);
    try std.testing.expectEqual(@as(u32, 0), spawned.dissolved_day);
    const band = merc_band.replacementBand();
    try std.testing.expectEqual(&merc_band.table.bands[0], band);
    try std.testing.expectEqualStrings(band.key, spawned.band_key);
    try std.testing.expectEqual(band.capital_cbills, spawned.cbills);
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

test "spawnReplacementCompany never reuses a logo a dissolved company held" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3004 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const dissolved: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), dissolved, .{
        .id = dissolved,
        .archetype_key = "enemy_raiders",
        .unit_name = "Dissolved Co",
        .faction_key = "DC",
        .band_key = test_band,
        .dissolved_day = 5,
        .logo_key = logo.all_keys[0],
        .home_planet_key = test_base,
    });
    gs.next_merc_company_id = 2;

    var rng = gs.rng;
    const new_id = try spawnReplacementCompany(&gs, gs.allocator(), 10, &rng);
    try std.testing.expectEqualStrings(logo.all_keys[1], gs.merc_companies.get(new_id).?.logo_key);
}

test "spawnReplacementCompany founds logo-less companies under distinct names once the catalog is used up" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3005 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    // The player reserves the first key; active and dissolved companies hold the rest.
    gs.player_logo_key = logo.all_keys[0];
    for (logo.all_keys[1..], 1..) |key, i| {
        const id: types.MercCompanyId = @enumFromInt(@as(u32, @intCast(i)));
        try gs.merc_companies.put(gs.allocator(), id, .{
            .id = id,
            .archetype_key = "enemy_raiders",
            .unit_name = try std.fmt.allocPrint(gs.allocator(), "Holder {d}", .{i}),
            .faction_key = "DC",
            .band_key = test_band,
            .dissolved_day = if (i % 2 == 0) 5 else 0,
            .logo_key = key,
            .home_planet_key = test_base,
        });
    }
    gs.next_merc_company_id = @intCast(logo.all_keys.len);

    var rng = gs.rng;
    var spawned: [2]types.MercCompanyId = undefined;
    for (&spawned) |*id| {
        const log_before = gs.event_log.items.len;
        id.* = try spawnReplacementCompany(&gs, gs.allocator(), 10, &rng);
        const company = gs.merc_companies.get(id.*).?;
        try std.testing.expectEqualStrings("", company.logo_key);
        try std.testing.expect(gs.merc_company_rosters.contains(id.*));
        try std.testing.expectEqual(log_before + 1, gs.event_log.items.len);
        const line = try foundingLine(a, company);
        defer a.free(line);
        try std.testing.expect(std.mem.endsWith(u8, gs.event_log.items[log_before].text, line));
        for (gs.merc_companies.values()) |other| {
            if (other.id != id.*) try std.testing.expect(!std.ascii.eqlIgnoreCase(other.unit_name, company.unit_name));
        }
    }
    try std.testing.expect(spawned[0] != spawned[1]);
}

test "replacements named in one pass from the same parts take the base name, then II" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3006 });
    defer gs.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parts: @FieldType(ReplacementPlan, "unit_name_parts") = .{ .last = "Baxter", .noun = "Guard" };
    var actions = [_]LifecycleAction{
        .{ .spawn = .{ .company = .{}, .unit_name_parts = parts, .buy = null } },
        .{ .spawn = .{ .company = .{}, .unit_name_parts = parts, .buy = null } },
    };
    try allocateReplacementNames(arena.allocator(), a, &gs, &actions);
    try std.testing.expectEqualStrings("Baxter Guard", actions[0].spawn.company.unit_name);
    try std.testing.expectEqualStrings("Baxter Guard II", actions[1].spawn.company.unit_name);

    // A dissolved company still holds its name.
    const dissolved: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(gs.allocator(), dissolved, .{ .id = dissolved, .unit_name = "Baxter Guard", .dissolved_day = 5 });
    try allocateReplacementNames(arena.allocator(), a, &gs, &actions);
    try std.testing.expectEqualStrings("Baxter Guard II", actions[0].spawn.company.unit_name);
    try std.testing.expectEqualStrings("Baxter Guard III", actions[1].spawn.company.unit_name);
}

test "allocateReplacementNames: the taken list is scratch, released on every exit" {
    // Rule 78: the leak-checking testing allocator backs scratch, so a taken
    // list that outlived the call, on success or on failure, fails the test.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3006 });
    defer gs.deinit();
    const parts: @FieldType(ReplacementPlan, "unit_name_parts") = .{ .last = "Baxter", .noun = "Guard" };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var names = std.heap.ArenaAllocator.init(a);
        defer names.deinit();
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var actions = [_]LifecycleAction{
            .{ .spawn = .{ .company = .{}, .unit_name_parts = parts, .buy = null } },
            .{ .spawn = .{ .company = .{}, .unit_name_parts = parts, .buy = null } },
        };
        if (allocateReplacementNames(names.allocator(), failing.allocator(), &gs, &actions)) |_| {
            try std.testing.expectEqualStrings("Baxter Guard II", actions[1].spawn.company.unit_name);
            try std.testing.expect(failing.allocations > 0);
            try std.testing.expectEqual(failing.allocations, failing.deallocations);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(failing.allocations, failing.deallocations);
        }
    }
}

test "runMercLifecycle gives each replacement in a pass its own never-held logo" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4010 });
    defer gs.deinit();
    try seedLifecycleAtomicityFixture(&gs);
    // Companies 1 (all_keys[0]) and 3 (all_keys[2]) dissolve; 2 keeps all_keys[1].
    try runMercLifecycle(&gs);
    try std.testing.expectEqualStrings(logo.all_keys[3], gs.merc_companies.get(@enumFromInt(4)).?.logo_key);
    try std.testing.expectEqualStrings(logo.all_keys[4], gs.merc_companies.get(@enumFromInt(5)).?.logo_key);
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

test "spawnReplacementCompany: planning scratch comes from gs.scratch() and is released" {
    // Rule 78: a scratch arena over the campaign arena carves its chunks from
    // campaign storage and frees nothing through gs.scratch(). With no prior
    // lifecycle arena to release, every byte freed there is operation scratch.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    for (1..17) |i| {
        const id: types.MercCompanyId = @enumFromInt(@as(u32, @intCast(i)));
        try gs.merc_companies.put(gs.allocator(), id, .{
            .id = id,
            .archetype_key = "enemy_raiders",
            .unit_name = try std.fmt.allocPrint(gs.allocator(), "Holder {d}", .{i}),
            .faction_key = "DC",
            .band_key = test_band,
            .logo_key = logo.all_keys[i],
            .home_planet_key = test_base,
        });
    }
    gs.next_merc_company_id = 17;
    try std.testing.expect(gs.lifecycle_arena == null);
    try std.testing.expect(gs.merc_company_roster_lifecycle_arena == null);
    const planned_bytes = gs.market_listings.items.len * @sizeOf(PlannedListing) +
        (gs.merc_companies.count() + 1) * @sizeOf(PlannedCompany);
    var counting = std.testing.FailingAllocator.init(a, .{});
    gs.arena.child_allocator = counting.allocator();
    var rng = gs.rng;
    _ = try spawnReplacementCompany(&gs, gs.allocator(), 10, &rng);
    try std.testing.expect(counting.freed_bytes >= planned_bytes);
}

/// Advance `gs` day by day through `months` paydays, so the clock stands on
/// the 1st of a month as the monthly pass does.
fn advancePaydays(gs: *GameState, months: u32) void {
    var seen: u32 = 0;
    while (seen < months) {
        gs.clock.advance();
        if (gs.clock.date.isPayday()) seen += 1;
    }
}

/// The day index `months` whole calendar months before `gs`'s 1st-of-month
/// clock, by subtracting each preceding month's length.
fn dayMonthsBefore(gs: *const GameState, months: u32) u32 {
    var day = gs.clock.day_index;
    var year = gs.clock.date.year;
    var month = gs.clock.date.month;
    for (0..months) |_| {
        if (month == 1) {
            year -= 1;
            month = 12;
        } else month -= 1;
        day -= @import("../domain/clock.zig").Date.daysInMonth(year, month);
    }
    return day;
}

/// Put a `test_band` company with `meks` LCT-1V hulls (BV 432 each), `cbills`
/// and `understrength_since` into `gs` under `id`, with a roster entry.
fn putLifecycleCompany(gs: *GameState, id: u32, name: []const u8, meks: usize, cbills: types.CBills, since: ?u32) !types.MercCompanyId {
    const alloc = gs.allocator();
    const company_id: types.MercCompanyId = @enumFromInt(id);
    try gs.merc_companies.put(alloc, company_id, .{
        .id = company_id,
        .archetype_key = "enemy_raiders",
        .unit_name = name,
        .faction_key = "DC",
        .band_key = test_band,
        .cbills = cbills,
        .logo_key = logo.all_keys[id - 1],
        .understrength_since = since,
        .home_planet_key = test_base,
    });
    var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    for (0..meks) |_| {
        const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(alloc, hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .{ .merc_company = company_id } });
        try gs.hull_ownership_history.append(alloc, .{ .hull_instance_id = hull_id, .acquisition_type = .initial, .prior_owner_key = "DC" });
        try roster.append(alloc, hull_id);
    }
    try gs.merc_company_rosters.put(alloc, company_id, roster);
    gs.next_merc_company_id = @max(gs.next_merc_company_id, id + 1);
    return company_id;
}

/// A running contract with one rival on `company_id`, so it holds an active
/// commitment (`rivals.mercCompanyCommitted`).
fn commitLifecycleCompany(gs: *GameState, company_id: types.MercCompanyId) !void {
    const alloc = gs.allocator();
    const contract_id: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(alloc, contract_id, .{
        .id = contract_id,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
    });
    try gs.rivals.put(alloc, @enumFromInt(1), .{ .id = @enumFromInt(1), .contract = contract_id, .merc_company_id = company_id });
}

fn findListingByHull(listings: []const market.Listing, hull_id: types.HullInstanceId) ?market.Listing {
    for (listings) |listing| if (listing.hull_instance_id == hull_id) return listing;
    return null;
}

fn activeMercCompanies(gs: *const GameState) usize {
    var active: usize = 0;
    for (gs.merc_companies.values()) |company| {
        if (company.dissolved_day == 0) active += 1;
    }
    return active;
}

test "runMercLifecycle: a low-BV company with cash survives, records today and still buys" {
    // §L7: low fieldable BV alone never dissolves a company that can pay.
    const a = std.testing.allocator;
    for ([_]usize{ 0, 1 }, 0..) |meks, case| {
        var gs = GameState.init(a, .{ .seed = 4001 + @as(u64, @intCast(case)) });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        gs.market_listings.clearRetainingCapacity();
        advancePaydays(&gs, 13);
        const id = try putLifecycleCompany(&gs, 1, "Thin Co", meks, 1, null);
        try std.testing.expect(rivals.mercCompanyInsolvent(&gs, id));
        // One affordable mek on the board: the company still tries its buy.
        const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
        try sellAsDcSurplusForTest(&gs, hull_id);
        try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = hull_id });
        gs.next_listing_id += 1;
        const log_before = gs.event_log.items.len;

        try runMercLifecycle(&gs);

        const company = gs.merc_companies.get(id).?;
        try std.testing.expectEqual(@as(u32, 0), company.dissolved_day);
        try std.testing.expectEqual(@as(?u32, gs.clock.day_index), company.understrength_since);
        try std.testing.expectEqual(meks + 1, rivals.mercCompanyHullCounts(&gs, id).meks);
        try std.testing.expectEqual(@as(types.CBills, 0), company.cbills);
        try std.testing.expectEqual(@as(usize, 1), gs.merc_companies.count());
        try std.testing.expectEqual(log_before, gs.event_log.items.len);
    }
}

test "runMercLifecycle: the runway boundary is 12 whole months, and each condition alone keeps a company" {
    const a = std.testing.allocator;
    const Case = struct { months: u32, cbills: types.CBills, meks: usize, committed: bool, dissolves: bool };
    const target = testLineTarget();
    for ([_]Case{
        .{ .months = 11, .cbills = -1, .meks = 1, .committed = false, .dissolves = false },
        .{ .months = 12, .cbills = -1, .meks = 1, .committed = false, .dissolves = true },
        .{ .months = 13, .cbills = -1, .meks = 1, .committed = false, .dissolves = true },
        // Cash: 13 months short of the line with C-bills on hand.
        .{ .months = 13, .cbills = 0, .meks = 1, .committed = false, .dissolves = false },
        // Line: 13 months recorded but back at its line now.
        .{ .months = 13, .cbills = -1, .meks = target, .committed = false, .dissolves = false },
        // Commitment: a rival on a running contract.
        .{ .months = 13, .cbills = -1, .meks = 1, .committed = true, .dissolves = false },
    }, 0..) |case, i| {
        var gs = GameState.init(a, .{ .seed = 4100 + @as(u64, @intCast(i)) });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        gs.market_listings.clearRetainingCapacity();
        advancePaydays(&gs, 14);
        const since = dayMonthsBefore(&gs, case.months);
        const id = try putLifecycleCompany(&gs, 1, "Runway Co", case.meks, case.cbills, since);
        if (case.committed) try commitLifecycleCompany(&gs, id);
        try std.testing.expectEqual(case.months, gs.clock.date.wholeMonthsBack(gs.clock.day_index - since));

        try runMercLifecycle(&gs);

        const company = gs.merc_companies.get(id).?;
        if (case.dissolves) {
            try std.testing.expectEqual(gs.clock.day_index, company.dissolved_day);
            try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
            try std.testing.expectEqual(@as(usize, 1), activeMercCompanies(&gs));
            const line = try dissolutionLine(a, company, .{ .runway_exhausted = .{ .understrength_months = case.months } });
            defer a.free(line);
            try std.testing.expect(std.mem.endsWith(u8, gs.event_log.items[gs.event_log.items.len - 2].text, line));
        } else {
            try std.testing.expectEqual(@as(u32, 0), company.dissolved_day);
            try std.testing.expectEqual(@as(usize, 1), gs.merc_companies.count());
            // A company back at its line has its record cleared; one still
            // short keeps the day it was first found short.
            const expected: ?u32 = if (case.meks >= target) null else since;
            try std.testing.expectEqual(expected, company.understrength_since);
        }
    }
}

test "runMercLifecycle: a company meeting all three conditions dissolves, lists its hulls and is replaced, with or without a roster" {
    const a = std.testing.allocator;
    for ([_]usize{ 5, 0 }, 0..) |meks, case| {
        var gs = GameState.init(a, .{ .seed = 4002 + @as(u64, @intCast(case)) });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        gs.market_listings.clearRetainingCapacity();
        advancePaydays(&gs, 13);
        const id = try putLifecycleCompany(&gs, 1, "Spent Co", meks, -1, dayMonthsBefore(&gs, 12));
        const hulls = try a.dupe(types.HullInstanceId, gs.merc_company_rosters.get(id).?.items);
        defer a.free(hulls);
        const log_before = gs.event_log.items.len;

        try runMercLifecycle(&gs);

        const company = gs.merc_companies.get(id).?;
        try std.testing.expectEqual(gs.clock.day_index, company.dissolved_day);
        try std.testing.expectEqual(@as(usize, 0), gs.merc_company_rosters.get(id).?.items.len);
        // One replacement is founded and the active count is held.
        try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
        try std.testing.expectEqual(@as(usize, 1), activeMercCompanies(&gs));
        const replacement_id: types.MercCompanyId = @enumFromInt(2);
        const replacement = gs.merc_companies.get(replacement_id).?;
        // Every hull it held went to the regular market, where the
        // replacement's founding buy may take it in the same pass.
        for (hulls) |hull_id| {
            const owner = gs.hull_instances.get(hull_id).?.owner;
            if (owner == .market) {
                try std.testing.expect(findListingByHull(gs.market_listings.items, hull_id) != null);
                try std.testing.expect(!findListingByHull(gs.market_listings.items, hull_id).?.black_market);
            } else {
                try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = replacement_id }, owner);
            }
            var listed_from_company = false;
            for (gs.hull_ownership_history.items) |entry| {
                if (entry.hull_instance_id == hull_id and entry.from_day == gs.clock.day_index and std.mem.eql(u8, entry.prior_owner_key, "DC")) listed_from_company = true;
            }
            try std.testing.expect(listed_from_company);
        }
        try std.testing.expectEqual(@as(u32, 0), replacement.dissolved_day);
        // The dissolution line, naming its cause, precedes the founding line.
        const lines = gs.event_log.items[log_before..];
        try std.testing.expectEqual(@as(usize, 2), lines.len);
        try std.testing.expect(std.mem.endsWith(u8, lines[0].text, "[merc] Spent Co dissolved: bankrupt, understrength 12 months, no commitment"));
        const founded = try foundingLine(a, replacement);
        defer a.free(founded);
        try std.testing.expect(std.mem.endsWith(u8, lines[1].text, founded));
    }
}

test "runMercLifecycle records understrength_since on the first short pass, keeps it, and clears it at the line" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4011 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    advancePaydays(&gs, 1);
    const first_day = gs.clock.day_index;
    const short = try putLifecycleCompany(&gs, 1, "Short Co", 3, 1_000, null);
    const recorded = try putLifecycleCompany(&gs, 2, "Recorded Co", 3, 1_000, 0);
    const full = try putLifecycleCompany(&gs, 3, "Full Co", testLineTarget(), 1_000, 0);

    try runMercLifecycle(&gs);
    // A first short pass records today; an earlier record stands; a company at
    // its line clears its record.
    try std.testing.expectEqual(@as(?u32, first_day), gs.merc_companies.get(short).?.understrength_since);
    try std.testing.expectEqual(@as(?u32, 0), gs.merc_companies.get(recorded).?.understrength_since);
    try std.testing.expectEqual(@as(?u32, null), gs.merc_companies.get(full).?.understrength_since);

    // A later short pass keeps the first day.
    advancePaydays(&gs, 1);
    try runMercLifecycle(&gs);
    try std.testing.expectEqual(@as(?u32, first_day), gs.merc_companies.get(short).?.understrength_since);

    // The pass's own buy brings the short company to its line: it ends null.
    const missing = testLineTarget() - 3;
    for (0..missing) |_| {
        const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
        try sellAsDcSurplusForTest(&gs, hull_id);
        try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = hull_id });
        gs.next_listing_id += 1;
    }
    gs.merc_companies.getPtr(recorded).?.cbills = 0;
    advancePaydays(&gs, 1);
    try runMercLifecycle(&gs);
    try std.testing.expectEqual(testLineTarget(), rivals.mercCompanyHullCounts(&gs, short).meks);
    try std.testing.expectEqual(@as(?u32, null), gs.merc_companies.get(short).?.understrength_since);
    try std.testing.expectEqual(@as(?u32, 0), gs.merc_companies.get(recorded).?.understrength_since);
}

test "runMercLifecycle commits a pass whose only change is understrength_since" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4012 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    advancePaydays(&gs, 1);
    const id = try putLifecycleCompany(&gs, 1, "Idle Co", 3, 1_000, null);
    const roster_before = gs.merc_company_rosters.get(id).?.items.len;
    const log_before = gs.event_log.items.len;
    const rng_before = gs.rng;
    const hash_before = digest.stateHash(&gs);

    try runMercLifecycle(&gs);

    try std.testing.expectEqual(@as(?u32, gs.clock.day_index), gs.merc_companies.get(id).?.understrength_since);
    try std.testing.expect(digest.stateHash(&gs) != hash_before);
    try std.testing.expectEqual(roster_before, gs.merc_company_rosters.get(id).?.items.len);
    try std.testing.expectEqual(@as(types.CBills, 1_000), gs.merc_companies.get(id).?.cbills);
    try std.testing.expectEqual(log_before, gs.event_log.items.len);
    try std.testing.expectEqual(rng_before, gs.rng);
    // Restoring the field restores the hash: nothing else changed.
    gs.merc_companies.getPtr(id).?.understrength_since = null;
    try std.testing.expectEqual(hash_before, digest.stateHash(&gs));
}

test "a replacement founded below its line carries its founding day" {
    const a = std.testing.allocator;
    // An empty market leaves the replacement short; enough meks bring it to its line.
    for ([_]bool{ false, true }, 0..) |stocked, case| {
        var gs = GameState.init(a, .{ .seed = 4013 + @as(u64, @intCast(case)) });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        gs.market_listings.clearRetainingCapacity();
        if (stocked) for (0..testLineTarget()) |_| {
            const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
            gs.next_hull_instance_id += 1;
            try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
            try sellAsDcSurplusForTest(&gs, hull_id);
            try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 1, .hull_instance_id = hull_id });
            gs.next_listing_id += 1;
        };
        advancePaydays(&gs, 13);
        _ = try putLifecycleCompany(&gs, 1, "Spent Co", 0, -1, dayMonthsBefore(&gs, 12));
        try runMercLifecycle(&gs);
        const replacement = gs.merc_companies.get(@enumFromInt(2)).?;
        const expected: ?u32 = if (stocked) null else gs.clock.day_index;
        try std.testing.expectEqual(expected, replacement.understrength_since);

        // spawnReplacementCompany founds by the same rule.
        var rng = gs.rng;
        const spawned = try spawnReplacementCompany(&gs, gs.allocator(), gs.clock.day_index, &rng);
        try std.testing.expectEqual(@as(?u32, gs.clock.day_index), gs.merc_companies.get(spawned).?.understrength_since);
    }
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
            .band_key = test_band,
            .dissolved_day = 0,
            .logo_key = logo.all_keys[0],
            .home_planet_key = test_base,
        });
        const h_bad: types.HullInstanceId = @enumFromInt(1);
        try gs.hull_instances.put(alloc2, h_bad, .{ .id = h_bad, .base_key = "LCT-1V", .owner = .{ .merc_company = mc1 } });
        try gs.hull_ownership_history.append(alloc2, .{ .hull_instance_id = h_bad, .from_day = 0, .to_day = null, .acquisition_type = .initial, .prior_owner_key = "DC" });
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

/// Three `test_band` companies on the 1st of the 14th campaign month, all
/// below their line. Companies 1 and 3 have negative cash, no commitment and
/// an `understrength_since` 13 months back, so both dissolve; company 2 has
/// cash, a record from last month, and a market deep enough to reach its line,
/// so its buy clears that record. Half the meks are DC wholesale, half on a
/// board on a DC world within reach of the companies' base but off it, so
/// company 2's buy records arrivals; its first hull's arrival is due today.
/// Company 1 also holds a hull it bought through `buyHullsForCompany`, whose
/// open ownership interval names the market, so its liquidation listing has
/// a seller only once the pass stages it.
fn seedLifecycleAtomicityFixture(gs: *GameState) !void {
    const alloc = gs.allocator();
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    advancePaydays(gs, 13);

    const bankrupt: types.MercCompanyId = @enumFromInt(1);
    const under_strength: types.MercCompanyId = @enumFromInt(2);
    const drained: types.MercCompanyId = @enumFromInt(3);
    try gs.merc_companies.put(alloc, bankrupt, .{
        .id = bankrupt,
        .archetype_key = "enemy_raiders",
        .unit_name = "Bankrupt Co",
        .faction_key = "DC",
        .band_key = test_band,
        .cbills = -1,
        .logo_key = logo.all_keys[0],
        .understrength_since = dayMonthsBefore(gs, 13),
        .home_planet_key = test_base,
    });
    try gs.merc_companies.put(alloc, under_strength, .{
        .id = under_strength,
        .archetype_key = "enemy_raiders",
        .unit_name = "Buying Co",
        .faction_key = "DC",
        .band_key = test_band,
        .cbills = 10_000_000,
        .logo_key = logo.all_keys[1],
        .understrength_since = dayMonthsBefore(gs, 1),
        .home_planet_key = test_base,
    });
    try gs.merc_companies.put(alloc, drained, .{
        .id = drained,
        .archetype_key = "enemy_raiders",
        .unit_name = "Drained Co",
        .faction_key = "DC",
        .band_key = test_band,
        .cbills = -1,
        .logo_key = logo.all_keys[2],
        .understrength_since = dayMonthsBefore(gs, 13),
        .home_planet_key = test_base,
    });

    // Companies 1 and 2 hold five LCT-1V, company 3 one: all below the line.
    for ([_]types.MercCompanyId{ bankrupt, under_strength, drained }) |company_id| {
        var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..@as(usize, if (company_id == drained) 1 else 5)) |_| {
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
    // Company 1's one C-bill buys the only mek it can afford, then its debts
    // leave it bankrupt.
    gs.merc_companies.getPtr(bankrupt).?.cbills = 1;
    const bought = try listDcSurplusMekForTest(gs, 1);
    var rng = gs.rng;
    try buyHullsForCompany(gs, gs.scratch(), bankrupt, gs.clock.day_index, &rng);
    gs.rng = rng;
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = bankrupt }, gs.hull_instances.get(bought).?.owner);
    gs.merc_companies.getPtr(bankrupt).?.cbills = -1;
    try gs.merc_hull_arrivals.put(alloc, gs.merc_company_rosters.get(under_strength).?.items[0], gs.clock.day_index);
    // Enough meks for the first replacement's line and company 2's top-up.
    const nearby = try boardOnForTest(gs, (try worldAtForTest("DC", test_base, 1, tuning.generation.npc_market_reach_ly)).key);
    for (0..48) |i| {
        const hull_id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(alloc, hull_id, .{ .id = hull_id, .base_key = "LCT-1V", .owner = .market });
        try sellAsDcSurplusForTest(gs, hull_id);
        try gs.market_listings.append(alloc, .{
            .kind = .unit,
            .item_key = "LCT-1V",
            .rarity = .common,
            .price = 1,
            .id = @enumFromInt(gs.next_listing_id),
            .hull_instance_id = hull_id,
            .hq = if (i % 2 == 0) .none else nearby,
        });
        gs.next_listing_id += 1;
    }
    const board = try baseBoardForTest(gs);
    for (0..@as(usize, tuning.generation.merc_company_air_reserve_lances) * force.lance_size) |_| {
        try gs.market_listings.append(alloc, .{
            .kind = .unit,
            .item_key = "TR-7",
            .rarity = .common,
            .price = 1,
            .id = @enumFromInt(gs.next_listing_id),
            .hq = board,
        });
        gs.next_listing_id += 1;
    }
    gs.next_merc_company_id = 4;
}

test "runMercLifecycle logs each dissolution with its cause, then its replacement's founding" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4007 });
    defer gs.deinit();
    try seedLifecycleAtomicityFixture(&gs);
    const runway: DissolutionCause = .{ .runway_exhausted = .{ .understrength_months = 13 } };
    try std.testing.expectEqual(runway, (try dissolutionCause(&gs, @enumFromInt(1))).?);
    try std.testing.expectEqual(@as(?DissolutionCause, null), try dissolutionCause(&gs, @enumFromInt(2)));
    try std.testing.expectEqual(runway, (try dissolutionCause(&gs, @enumFromInt(3))).?);
    const log_before = gs.event_log.items.len;

    try runMercLifecycle(&gs);

    // Companies 1 and 3 dissolve in id order, replaced by 4 and 5; the
    // buying company 2 adds no line.
    const lines = gs.event_log.items[log_before..];
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    const expected = [_][]const u8{
        try dissolutionLine(a, gs.merc_companies.get(@enumFromInt(1)).?, runway),
        try foundingLine(a, gs.merc_companies.get(@enumFromInt(4)).?),
        try dissolutionLine(a, gs.merc_companies.get(@enumFromInt(3)).?, runway),
        try foundingLine(a, gs.merc_companies.get(@enumFromInt(5)).?),
    };
    defer for (expected) |line| a.free(line);
    for (lines, expected) |entry, line| {
        try std.testing.expect(std.mem.endsWith(u8, entry.text, line));
        try std.testing.expectEqual(gs.clock.day_index, entry.day);
        try std.testing.expectEqual(state_mod.LogCategory.market, entry.category);
    }
    try std.testing.expect(std.mem.endsWith(u8, lines[0].text, "[merc] Bankrupt Co dissolved: bankrupt, understrength 13 months, no commitment"));
    try std.testing.expect(std.mem.endsWith(u8, lines[2].text, "[merc] Drained Co dissolved: bankrupt, understrength 13 months, no commitment"));
    // Every company, dissolved or new, holds a roster entry.
    for (gs.merc_companies.keys()) |id| try std.testing.expect(gs.merc_company_rosters.contains(id));
}

test "liquidateMercCompany logs its dissolution as liquidated when no dissolution rule holds" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4008 });
    defer gs.deinit();
    try seedLifecycleAtomicityFixture(&gs);
    const solvent: types.MercCompanyId = @enumFromInt(2);
    const log_before = gs.event_log.items.len;
    try liquidateMercCompany(&gs, gs.allocator(), solvent, gs.clock.day_index);
    try std.testing.expectEqual(log_before + 1, gs.event_log.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gs.event_log.items[log_before].text, "[merc] Buying Co dissolved: liquidated"));
}

test "a replacement that bought nothing is insolvent and no OpFor, yet keeps its capital and survives the next month" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 4009 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    advancePaydays(&gs, 13);
    _ = try putLifecycleCompany(&gs, 1, "Empty Bankrupt Co", 0, -1, dayMonthsBefore(&gs, 12));

    try runMercLifecycle(&gs);
    const replacement: types.MercCompanyId = @enumFromInt(2);
    const founded_day = gs.clock.day_index;
    try std.testing.expectEqual(@as(usize, 0), gs.merc_company_rosters.get(replacement).?.items.len);
    try std.testing.expect(rivals.mercCompanyInsolvent(&gs, replacement));
    try std.testing.expect(!rivals.mercCompanyEligibleAsOpFor(&gs, replacement));

    advancePaydays(&gs, 1);
    const log_before = gs.event_log.items.len;
    try runMercLifecycle(&gs);
    const kept = gs.merc_companies.get(replacement).?;
    try std.testing.expectEqual(@as(u32, 0), kept.dissolved_day);
    try std.testing.expectEqual(merc_band.replacementBand().capital_cbills, kept.cbills);
    try std.testing.expectEqual(@as(?u32, founded_day), kept.understrength_since);
    try std.testing.expectEqual(@as(usize, 2), gs.merc_companies.count());
    try std.testing.expectEqual(log_before, gs.event_log.items.len);
}

test "runMercLifecycle: allocator failures leave a multi-action pass unchanged" {
    // Rule 69: the fixture executes two runway dissolutions with their
    // replacements and a separate under-strength purchase that clears its
    // `understrength_since`, records arrivals and drops a due one; every
    // preparation failure preserves gameplay (arrivals included), live
    // collection storage, and campaign-arena capacity.
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
        const hulls_before = gs.hull_instances.keys().ptr;
        const bankrupt_roster_before = gs.merc_company_rosters.get(@enumFromInt(1)).?.items.ptr;
        const under_strength_roster_before = gs.merc_company_rosters.get(@enumFromInt(2)).?.items.ptr;
        const due = gs.merc_company_rosters.get(@enumFromInt(2)).?.items[0];
        const arrivals_before = gs.merc_hull_arrivals.keys().ptr;

        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (runMercLifecycle(&gs)) |_| {
            try std.testing.expect(digest.stateHash(&gs) != before);
            try std.testing.expect(gs.merc_companies.getPtr(@enumFromInt(1)).?.dissolved_day != 0);
            try std.testing.expect(gs.merc_companies.getPtr(@enumFromInt(3)).?.dissolved_day != 0);
            try std.testing.expect(gs.merc_company_rosters.get(@enumFromInt(2)).?.items.len >= testLineTarget());
            try std.testing.expectEqual(@as(?u32, null), gs.merc_companies.get(@enumFromInt(2)).?.understrength_since);
            // The due arrival is dropped; off-world buys record theirs.
            try std.testing.expect(!gs.merc_hull_arrivals.contains(due));
            var recorded: usize = 0;
            for (gs.merc_hull_arrivals.keys()) |hull| recorded += @intFromBool(gs.hull_instances.get(hull).?.owner.merc_company == @as(types.MercCompanyId, @enumFromInt(2)));
            try std.testing.expect(recorded > 0);
            try npc_base.validate(&gs);
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
            try std.testing.expectEqual(hulls_before, gs.hull_instances.keys().ptr);
            try std.testing.expectEqual(bankrupt_roster_before, gs.merc_company_rosters.get(@enumFromInt(1)).?.items.ptr);
            try std.testing.expectEqual(under_strength_roster_before, gs.merc_company_rosters.get(@enumFromInt(2)).?.items.ptr);
            try std.testing.expectEqual(arrivals_before, gs.merc_hull_arrivals.keys().ptr);
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
        .band_key = test_band,
        .cbills = 1,
        .logo_key = logo.all_keys[0],
        .home_planet_key = test_base,
    });
    gs.next_merc_company_id = 2;
    try gs.hull_instances.put(gs.allocator(), hull_id, .{
        .id = hull_id,
        .base_key = "LCT-1V",
        .owner = .market,
    });
    try sellAsDcSurplusForTest(&gs, hull_id);
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
        // Reopen the DC interval, so the listing is DC surplus again.
        gs.hull_ownership_history.items[gs.hull_ownership_history.items.len - 1].to_day = null;
        try gs.market_listings.append(gs.allocator(), listing);
        gs.clock.advance();
        try runMercLifecycle(&gs);
        try std.testing.expectEqual(bytes_after_first_pass, debug_alloc.total_requested_bytes);
    }
}

const logistics = @import("../econ/logistics.zig");

test "a monthly buy takes a listing with a world only within its base's reach, and a wholesale one from any base" {
    // docs/p5d-conflict-world-design.md D21, M1; rule 71: two companies of one
    // band with equal cash and need, one based on the listing's world, the
    // other beyond 60 ly of it.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 7621 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    advancePaydays(&gs, 1);
    const far_world = try worldAtForTest("DC", test_base, 61, std.math.maxInt(u32));
    const far = try putLifecycleCompany(&gs, 1, "Far Co", testLineTarget() - 1, 1_000, null);
    gs.merc_companies.getPtr(far).?.home_planet_key = far_world.key;
    const near = try putLifecycleCompany(&gs, 2, "Near Co", testLineTarget() - 1, 1_000, null);
    const board = try baseBoardForTest(&gs);
    const located = try listMekOnBoardForTest(&gs, board, 1);

    // The far company plans first and cannot reach the listing; the near one takes it.
    try runMercLifecycle(&gs);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = near }, gs.hull_instances.get(located).?.owner);
    try std.testing.expectEqual(testLineTarget() - 1, rivals.mercCompanyHullCounts(&gs, far).meks);
    try std.testing.expectEqual(testLineTarget(), rivals.mercCompanyHullCounts(&gs, near).meks);
    // Bought on the near company's base world: fieldable at once.
    try std.testing.expect(!gs.merc_hull_arrivals.contains(located));

    // With only listings it cannot reach, the far company draws nothing.
    const out_of_reach = try listMekOnBoardForTest(&gs, board, 1);
    const before = digest.stateHash(&gs);
    var rng = gs.rng;
    const rng_before = rng;
    try buyHullsForCompany(&gs, a, far, gs.clock.day_index, &rng);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(rng_before, rng);

    // A wholesale listing reaches it, delivered from the DC capital.
    const wholesale = try listDcSurplusMekForTest(&gs, 1);
    const day = gs.clock.day_index;
    try buyHullsForCompany(&gs, a, far, day, &rng);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = far }, gs.hull_instances.get(wholesale).?.owner);
    try std.testing.expectEqual(hull_instance_mod.HullOwner.market, gs.hull_instances.get(out_of_reach).?.owner);
    try std.testing.expectEqual(day + logistics.deliveryDays(planet.find(test_base).?, far_world), gs.merc_hull_arrivals.get(wholesale).?);
    try npc_base.validate(&gs);
}

test "a hull bought off the base world is owned at once but fieldable only from its arrival day, and the next monthly pass drops its arrival" {
    // docs/p5d-conflict-world-design.md §L1 "not fieldable before".
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 7622 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    advancePaydays(&gs, 1);
    const near_world = try worldAtForTest("DC", test_base, 1, tuning.generation.npc_market_reach_ly);
    const id = try putLifecycleCompany(&gs, 1, "Arriving Co", testLineTarget() - 2, 1_000, null);
    const off_world = try listMekOnBoardForTest(&gs, try boardOnForTest(&gs, near_world.key), 1);
    const on_world = try listMekOnBoardForTest(&gs, try baseBoardForTest(&gs), 1);
    const day = gs.clock.day_index;
    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, id, day, &rng);

    // The off-world hull arrives after the delivery days of its route; the
    // on-world one records nothing.
    const arrive_day = day + logistics.deliveryDays(near_world, planet.find(test_base).?);
    try std.testing.expect(arrive_day > day + 1);
    try std.testing.expectEqual(arrive_day, gs.merc_hull_arrivals.get(off_world).?);
    try std.testing.expect(!gs.merc_hull_arrivals.contains(on_world));
    try std.testing.expect(npc_base.hullFieldable(&gs, on_world, day));
    try npc_base.validate(&gs);

    const target = testLineTarget();
    const bv: i64 = chassis_mod.find("LCT-1V").?.bv;
    // The day before it arrives: owned, at the line, yet not fieldable.
    while (gs.clock.day_index < arrive_day - 1) gs.clock.advance();
    try std.testing.expectEqual(target, rivals.mercCompanyHullCounts(&gs, id).meks);
    try std.testing.expectEqual(target - 1, rivals.mercCompanyFieldableCounts(&gs, id).meks);
    try std.testing.expectEqual(@as(i64, @intCast(target - 1)) * bv, rivals.mercCompanyFieldableBv(&gs, id));
    try std.testing.expect(!rivals.mercCompanyEligibleAsOpFor(&gs, id));
    // On its arrival day: in every count.
    gs.clock.advance();
    try std.testing.expectEqual(arrive_day, gs.clock.day_index);
    try std.testing.expectEqual(target, rivals.mercCompanyFieldableCounts(&gs, id).meks);
    try std.testing.expectEqual(@as(i64, @intCast(target)) * bv, rivals.mercCompanyFieldableBv(&gs, id));
    try std.testing.expect(rivals.mercCompanyEligibleAsOpFor(&gs, id));
    // The next monthly pass drops the arrival, its only change.
    advancePaydays(&gs, 1);
    const log_before = gs.event_log.items.len;
    try runMercLifecycle(&gs);
    try std.testing.expectEqual(@as(usize, 0), gs.merc_hull_arrivals.count());
    try std.testing.expectEqual(log_before, gs.event_log.items.len);
}

test "a line full only counting hulls en route is not understrength and buys no duplicate" {
    // Owned strength drives need and the understrength record
    // (docs/p5d-conflict-world-design.md §L1, §L7).
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 7623 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    advancePaydays(&gs, 1);
    const id = try putLifecycleCompany(&gs, 1, "Waiting Co", testLineTarget(), 1_000, null);
    const en_route = gs.merc_company_rosters.get(id).?.items[0];
    try gs.merc_hull_arrivals.put(gs.allocator(), en_route, gs.clock.day_index + 40);
    const board = try baseBoardForTest(&gs);
    const spare = try listMekOnBoardForTest(&gs, board, 1);

    try runMercLifecycle(&gs);
    try std.testing.expectEqual(hull_instance_mod.HullOwner.market, gs.hull_instances.get(spare).?.owner);
    try std.testing.expectEqual(@as(?u32, null), gs.merc_companies.get(id).?.understrength_since);
    try std.testing.expectEqual(testLineTarget() - 1, rivals.mercCompanyFieldableCounts(&gs, id).meks);
    try std.testing.expect(gs.merc_hull_arrivals.contains(en_route));
}

test "liquidating a company lists its hull still en route and drops that hull's arrival" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 7624 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const id = try putLifecycleCompany(&gs, 1, "Folding Co", 3, 1_000, null);
    const en_route = gs.merc_company_rosters.get(id).?.items[1];
    try gs.merc_hull_arrivals.put(gs.allocator(), en_route, gs.clock.day_index + 9);
    try npc_base.validate(&gs);

    try liquidateMercCompany(&gs, gs.allocator(), id, gs.clock.day_index);
    try std.testing.expect(findListingByHull(gs.market_listings.items, en_route) != null);
    try std.testing.expectEqual(hull_instance_mod.HullOwner.market, gs.hull_instances.get(en_route).?.owner);
    try std.testing.expectEqual(@as(usize, 0), gs.merc_hull_arrivals.count());
    try npc_base.validate(&gs);
}

test "a dissolving company's hulls are offered wholesale from its own faction's capital to buyers later in the same pass" {
    // docs/p5d-conflict-world-design.md M1: a liquidation listing is the
    // liquidating company's wholesale offer. An LC company based on its
    // capital dissolves holding a hull first sold by DC and, in one case, a
    // hull it bought through `buyHullsForCompany` (open interval: the
    // market). Its replacement and a DC company based on the DC capital plan
    // after the liquidation in the same pass, before its LC interval is
    // committed; whoever buys a listed hull receives it from the LC capital.
    const a = std.testing.allocator;
    for ([_]bool{ true, false }) |bought_one| {
        errdefer std.debug.print("with a bought hull: {}\n", .{bought_one});
        var gs = GameState.init(a, .{ .seed = 7627 });
        defer gs.deinit();
        _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
        gs.market_listings.clearRetainingCapacity();
        const lc_capital = planet.find(faction_mod.find("LC").?.capital).?;
        const folding = try putLifecycleCompany(&gs, 1, "Folding Co", 1, 1, null);
        gs.merc_companies.getPtr(folding).?.faction_key = "LC";
        gs.merc_companies.getPtr(folding).?.home_planet_key = lc_capital.key;
        if (bought_one) {
            const bought = try listDcSurplusMekForTest(&gs, 1);
            var rng = gs.rng;
            try buyHullsForCompany(&gs, a, folding, gs.clock.day_index, &rng);
            gs.rng = rng;
            try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = folding }, gs.hull_instances.get(bought).?.owner);
        }
        const hulls = try a.dupe(types.HullInstanceId, gs.merc_company_rosters.get(folding).?.items);
        defer a.free(hulls);
        advancePaydays(&gs, 13);
        gs.merc_companies.getPtr(folding).?.cbills = -1;
        gs.merc_companies.getPtr(folding).?.understrength_since = dayMonthsBefore(&gs, 12);
        // A stale DC origin would read as this buyer's own base world.
        _ = try putLifecycleCompany(&gs, 2, "Buyer Co", testLineTarget() - 1, 1_000_000_000, null);
        try std.testing.expectEqualStrings(test_base, faction_mod.find("DC").?.capital);
        try npc_base.validate(&gs);
        const day = gs.clock.day_index;

        try runMercLifecycle(&gs);

        try std.testing.expectEqual(day, gs.merc_companies.get(folding).?.dissolved_day);
        var sold: usize = 0;
        for (hulls) |hull_id| {
            const owner = switch (gs.hull_instances.get(hull_id).?.owner) {
                .merc_company => |id| id,
                else => continue,
            };
            sold += 1;
            const base = try npc_base.companyBase(gs.merc_companies.get(owner).?);
            try std.testing.expectEqual(npc_base.deliveryArrival(lc_capital, base, day), gs.merc_hull_arrivals.get(hull_id));
        }
        try std.testing.expect(sold > 0);
        try npc_base.validate(&gs);
    }
}

test "a replacement is based on a world of its own faction, ready on its founding day, and its founding buy reaches from that base" {
    // docs/p5d-conflict-world-design.md §L1; decision M3.
    const a = std.testing.allocator;
    // A dry run on an empty market finds the base: it is drawn before the
    // founding buy, so the market a same-seed campaign holds cannot move it.
    var probe = GameState.init(a, .{ .seed = 7626 });
    defer probe.deinit();
    _ = try founding.createCommander(&probe, "T", .LC, .line_officer);
    probe.market_listings.clearRetainingCapacity();
    var probe_rng = probe.rng;
    const spawned_id = try spawnReplacementCompany(&probe, a, 30, &probe_rng);
    const spawned = probe.merc_companies.get(spawned_id).?;
    const base = planet.find(spawned.home_planet_key).?;
    try std.testing.expectEqualStrings(spawned.faction_key, base.faction);
    try std.testing.expectEqual(@as(u32, 30), spawned.founded_day);
    try std.testing.expectEqual(@as(u32, 30), spawned.ready_day);
    try npc_base.validate(&probe);

    var gs = GameState.init(a, .{ .seed = 7626 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    const far_world = for (planet.catalog) |*p| {
        if (planet.distanceLy(base, p) > tuning.generation.npc_market_reach_ly) break p;
    } else unreachable;
    const at_base = try listMekOnBoardForTest(&gs, try boardOnForTest(&gs, base.key), 1);
    const out_of_reach = try listMekOnBoardForTest(&gs, try boardOnForTest(&gs, far_world.key), 1);
    var rng = gs.rng;
    const id = try spawnReplacementCompany(&gs, a, 30, &rng);
    try std.testing.expectEqualStrings(base.key, gs.merc_companies.get(id).?.home_planet_key);
    try std.testing.expectEqual(hull_instance_mod.HullOwner{ .merc_company = id }, gs.hull_instances.get(at_base).?.owner);
    try std.testing.expectEqual(hull_instance_mod.HullOwner.market, gs.hull_instances.get(out_of_reach).?.owner);
    try npc_base.validate(&gs);
}

test "an NPC hull and the player's hull bought over the same route arrive after the same days" {
    // docs/p5d-conflict-world-design.md §A "one travel rule".
    const commands = @import("commands.zig");
    const a = std.testing.allocator;
    // The first seed whose starting world has another world within reach.
    var seed: u64 = 7625;
    var gs, const alpha, const home, const away = while (true) : (seed += 1) {
        if (seed > 7700) return error.TestUnexpectedResult;
        var g = GameState.init(a, .{ .seed = seed });
        errdefer g.deinit();
        _ = try commands.execute(&g, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
        const co = (try commands.execute(&g, .{ .new_company = "Alpha" })).created_force;
        const world = planet.find(g.hqs.get(g.homeHqFor(co)).?.planet_key).?;
        const near = worldAtForTest(null, world.key, 1, tuning.generation.npc_market_reach_ly) catch {
            g.deinit();
            continue;
        };
        break .{ g, co, world, near };
    };
    defer gs.deinit();
    const board = try boardOnForTest(&gs, away.key);
    gs.hqs.getPtr(board).?.funds = 100_000_000;
    const day = gs.clock.day_index;

    // The player buys on the away board for the company at home.
    try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 500_000, .hq = board, .expires_day = day + 30 });
    gs.next_listing_id += 1;
    const player = try commands.execute(&gs, .{ .buy_hull_for = .{ .listing = gs.market_listings.items.len - 1, .company = alpha } });
    try std.testing.expect(player.eta_days > 0);

    // An NPC company based on the same home world buys on the same board.
    const npc = try putLifecycleCompany(&gs, gs.next_merc_company_id, "Neighbour Co", testLineTarget() - 1, 1_000, null);
    gs.merc_companies.getPtr(npc).?.faction_key = home.faction;
    gs.merc_companies.getPtr(npc).?.home_planet_key = home.key;
    const hull = try listMekOnBoardForTest(&gs, board, 1);
    var rng = gs.rng;
    try buyHullsForCompany(&gs, a, npc, day, &rng);
    try std.testing.expectEqual(day + player.eta_days, gs.merc_hull_arrivals.get(hull).?);
}
