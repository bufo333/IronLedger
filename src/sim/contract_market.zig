//! Contract market: monthly offer generation filtered by influence rings
//! (ARCH §9.2). MekHQ counterpart: `market/ContractMarket`, with CamOps
//! payment terms; adds per-place visibility and beachhead flagging (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const contract = @import("../domain/contract.zig");
const planet = @import("../domain/planet.zig");
const market = @import("../econ/market.zig");
const logistics = @import("../econ/logistics.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const founding = @import("founding.zig");
const hq_ops = @import("hq_ops.zig");
const treasury = @import("treasury.zig");
const unit_mod = @import("../domain/unit.zig");
const hq_mod = @import("../domain/hq.zig");
const person_mod = @import("../domain/person.zig");
const person_gen = @import("../gen/person_gen.zig");
const rating = @import("rating.zig");
const chassis_mod = @import("../domain/chassis.zig");
const force_mod = @import("../domain/force.zig");
const toe = @import("toe.zig");
const lift_mod = @import("lift.zig");
const personnel = @import("personnel.zig");
const posture = @import("posture.zig");
const commands = @import("commands.zig");
const commander = @import("../domain/commander.zig");
const black_market = @import("black_market.zig");
const conventional_market = @import("conventional_market.zig");

/// Employer payment multiplier by faction, basis points (data/tables/factions.zon).
pub fn employerMultBp(faction_key: []const u8) types.Bp {
    return @import("../domain/faction.zig").get(faction_key).pay_bp;
}

/// Standing payment multiplier: ±25 bp per point of a
/// house's standing, so ±25% at the extremes.
pub fn standingPayBp(standing: i32) types.Bp {
    return 10_000 + @as(types.Bp, standing) * tuning.contract.standing_pay_bp_per_point;
}

/// The five Successor States: the employers an F-rated outfit
/// cannot get in front of.  Delegates to the single-owner set
/// `commander.Faction.isHouse` (C11m).
pub fn isGreatHouse(faction_key: []const u8) bool {
    return commander.Faction.isHouse(faction_key);
}

/// Employers price contracts off your operating costs with a market margin
/// on top (CamOps' negotiation environment, abstracted).
pub const market_margin_bp: types.Bp = tuning.market.market_margin_bp; // ×1.8

/// AtB-flavored contract-type roll, widened: garrison work is the most
/// common single kind, but every kind in the book turns up, and `refresh`
/// caps any one kind at a third of the board.
fn rollKind(gs: *GameState) contract.ContractKind {
    const roll = gs.rng.roll2d6(.market);
    const coin = gs.rng.random(.market).boolean(); // TUNE: design split of cadre vs security, riot vs relief within the AtB 2d6 kind table
    return switch (roll) {
        2 => .guerrilla_warfare,
        3 => .recon_raid,
        4 => .pirate_hunting,
        5 => .objective_raid,
        6, 7 => .garrison_duty,
        8 => if (coin) .cadre_duty else .security_duty,
        9 => if (coin) .riot_duty else .relief_duty,
        10 => .extraction_raid,
        11 => .diversionary_raid,
        else => .planetary_assault,
    };
}

fn pickEnemy(gs: *GameState, employer: []const u8, kind: contract.ContractKind) []const u8 {
    // Garrison-class work is as often about pirates as neighbors.
    if (kind.isGarrisonClass() and gs.rng.random(.market).boolean()) return "PER"; // TUNE: pirates vs neighbour
    // The faction table's foes: a house fights its neighbours.
    const foes = @import("../domain/faction.zig").get(employer).foes;
    if (foes.len == 0) return "PER";
    return foes[gs.rng.random(.market).uintLessThan(usize, foes.len)]; // uniform pick from faction's foe list
}

/// Pay multiplier for an offer's opposition: its combat power
/// against the kind's norm (midpoint lances of `reference_lance_bv` at
/// regular skill). A veteran five-lance force pays more than a green four.
pub fn threatPayBp(kind: contract.ContractKind, lances: u8, quality: types.ExperienceLevel, lance_bv: i64) types.Bp {
    const opfor = @import("../domain/opfor.zig");
    const Element = @import("../domain/autoresolve.zig").Element;
    const t = tuning.contract;
    const row = opfor.rowFor(kind);
    const sk = opfor.skills(quality);
    const enemy = (Element{ .base_strength = lance_bv * lances, .avg_gunnery = sk[0], .avg_piloting = sk[1] }).effectivePower(.{});
    const mid: i64 = @divTrunc(@as(i64, row.lances_min) + row.lances_max, 2);
    const norm = (Element{ .base_strength = t.reference_lance_bv * @max(1, mid) }).effectivePower(.{});
    if (norm <= 0) return 10_000;
    const threat_bp: i64 = @divTrunc(enemy * 10_000, norm);
    const delta = std.math.clamp(@divTrunc((threat_bp - 10_000) * t.threat_pay_weight_bp, 10_000), -@as(i64, t.threat_pay_cap_bp), @as(i64, t.threat_pay_cap_bp));
    return @intCast(10_000 + delta);
}

/// Regenerate the offer board (monthly, and once at campaign start).
/// Reputation reaches only as far as your rings: hidden worlds offer nothing.
pub fn refresh(gs: *GameState) !void {
    gs.contract_offers.clearRetainingCapacity();
    if (gs.hqs.count() == 0) return;

    // Employers price off what fielding ONE company costs per month —
    // payroll, hulls and expected maintenance consumables, spread over the
    // combat companies on the books. A contract hires one company; pricing
    // it off the whole outfit would pay every company for all of them at once.
    const base = types.applyBp(@max(perCompanyOpsCost(gs), tuning.market.min_ops_cost), types.applyBp(market_margin_bp, gs.diff().contract_pay_bp)); // difficulty

    // The Dragoons rating sets how many come calling, who, and at what pay.
    const rt = tuning.rating;
    const rating_idx = try rating.currentIndex(gs);
    // One board per HQ: each posts work inside its own ring and
    // beachhead band, for the companies based there; its comms set how many
    // come calling, and a field HQ hears half as much.
    for (gs.hqs.keys()) |hq_id| {
        const hq = gs.hqs.getPtr(hq_id).?;
        const hq_world = planet.find(hq.planet_key) orelse continue;
        const board_start = gs.contract_offers.items.len;
        var offer_count = market.contractOfferCount(rating_idx, hq.effectiveFacilityLevel(.comms));
        if (hq.tier == .field) offer_count = @max(1, offer_count / 2);
        var attempts: u32 = 0;
        while (gs.contract_offers.items.len - board_start < offer_count and attempts < 1000) : (attempts += 1) {
            const world = &planet.catalog[gs.rng.random(.market).uintLessThan(usize, planet.catalog.len)]; // uniform pick from world catalog
            if (!@import("../domain/faction.zig").get(world.faction).hires) continue; // ComStar posts nothing
            const dist = planet.distanceLy(hq_world, world);
            const seen = market.visibilityFor(dist, hq.influenceLy());
            if (seen == .hidden) continue;
            const vis: struct { market.OfferVisibility, u32 } = .{ seen, dist };

            // Great Houses do not hire an F-rated outfit, and nobody hands
            // one a planetary assault.
            if (rating_idx < rt.house_min_index and isGreatHouse(world.faction)) continue;
            var kind = rollKind(gs);
            if (kind == .planetary_assault and rating_idx < rt.assault_min_index) kind = .garrison_duty;
            // A mix, not a wall of garrison duty: no kind takes
            // more than a third of the board, and the garrison class — garrison,
            // cadre, security, riot: long, quiet, event-driven — no more than half,
            // so raids and assaults are always on offer.
            const kind_cap: usize = @max(2, @as(usize, offer_count) / 3);
            const class_cap: usize = @max(2, @as(usize, offer_count) / 2);
            var same: usize = 0;
            var same_class: usize = 0;
            for (gs.contract_offers.items[board_start..]) |o| {
                if (o.kind == kind) same += 1;
                if (o.kind.isGarrisonClass()) same_class += 1;
            }
            if (same >= kind_cap) continue;
            if (kind.isGarrisonClass() and same_class >= class_cap) continue;
            const length_variance: i32 = @as(i32, gs.rng.roll2d6(.market)) - 7;
            const length: u8 = @intCast(std.math.clamp(
                @as(i32, kind.baseLengthMonths()) + length_variance,
                2,
                30,
            ));

            // Beachhead employers pay a premium — nobody else will go.
            var pay = contract.monthlyPayment(base, kind, employerMultBp(world.faction), rating.payBp(rating_idx));
            if (vis[0] == .beachhead) pay = types.applyBp(pay, tuning.market.beachhead_pay_bp);
            // A cooling employer (after a breach): half the offers, 70% pay.
            if (gs.factionCooling(world.faction)) {
                if (gs.rng.random(.market).boolean()) continue; // TUNE: project-chosen "half the offers" odds
                pay = types.applyBp(pay, tuning.market.cooling_pay_bp);
            }
            // Standing: a house that thinks well of you pays more and
            // one that doesn't shuns you like a cooling employer.
            const standing = gs.standing(world.faction);
            if (standing <= -tuning.contract.standing_shun_depth and gs.rng.random(.market).boolean()) continue; // TUNE: project-chosen "half the offers" odds
            pay = types.applyBp(pay, standingPayBp(standing));
            // Command rights: the employer pays for the reins.
            const rights: contract.CommandRights = switch (gs.rng.roll2d6(.market)) {
                2, 3, 4 => .integrated,
                5, 6, 7 => .house,
                8, 9, 10 => .liaison,
                else => .independent,
            };
            pay = types.applyBp(pay, rights.payBp());

            // The opposition is a force of its own, rolled now so the
            // board can say what the job is up against.
            const enemy_key = pickEnemy(gs, world.faction, kind);
            const opfor = @import("../domain/opfor.zig").roll(&gs.rng, .market, kind, enemy_key, gs.clock.date.year);
            // Harder work pays more: the employer prices the opposition.
            pay = types.applyBp(pay, threatPayBp(kind, opfor.lances, opfor.quality, opfor.lance_bv));
            try gs.contract_offers.append(gs.allocator(), .{
                .id = @enumFromInt(gs.next_contract_id),
                .kind = kind,
                .employer_key = world.faction,
                .enemy_key = enemy_key,
                .enemy_lances = opfor.lances,
                .enemy_quality = opfor.quality,
                .enemy_lance_bv = opfor.lance_bv,
                .enemy_lance_tons = opfor.lance_tons,
                .offer_hq = hq_id,
                .planet_key = world.key,
                .dist_ly = vis[1],
                .beachhead = vis[0] == .beachhead,
                .terms = .{
                    .length_months = length,
                    .base_pay_month = pay,
                    .advance_pct = tuning.contract.advance_pct,
                    .signing_bonus = if (gs.rng.roll2d6(.market) >= tuning.contract.signing_bonus_target) @divTrunc(pay, tuning.contract.signing_bonus_divisor) else 0,
                    .transport_pct = @intCast(@as(u32, gs.rng.roll2d6(.market) -| 2) * tuning.contract.transport_pct_per_pip),
                    // Straight support: the employer ships you supplies monthly
                    // (goods, not cash).
                    .overhead_pct = blk: {
                        const r = gs.rng.roll2d6(.market);
                        break :blk if (r >= tuning.contract.overhead_full_at) @as(u8, 100) else if (r >= tuning.contract.overhead_half_at) 50 else if (r >= tuning.contract.overhead_quarter_at) 25 else 0;
                    },
                    .battle_loss_pct = if (gs.rng.roll2d6(.market) >= tuning.contract.battle_loss_target) tuning.contract.battle_loss_pct else 0,
                    .salvage_pct = @intCast(@as(u32, gs.rng.roll2d6(.market) -| 2) * tuning.contract.salvage_pct_per_pip),
                    // Salvage exchange: the employer keeps the wrecks and pays cash.
                    .salvage_exchange = gs.rng.random(.market).uintLessThan(u32, tuning.contract.salvage_exchange_in) == 0, // TUNE: salvage_exchange_in constant named in tuning
                    .command_rights = rights,
                },
            });
            gs.next_contract_id += 1;
        }
    }
}

/// Monthly board refresh at the HQ (ARCH §9.8): hull listings
/// persist until bought or aged out (other buyers exist) and new hulls
/// arrive to fill the lot; staples are restocked; rare slots re-roll.
pub fn refreshListings(gs: *GameState) !void {
    const day = gs.clock.day_index;
    // Age out: expired hulls vanish; all part lines are regenerated.
    // For surplus listings backed by a real HullInstance still owned by .market,
    // return the hull to its originating faction pool before removing the listing
    // (rule 1 — no orphaned market-owned hulls without a backing listing).
    var i: usize = 0;
    while (i < gs.market_listings.items.len) {
        const l = gs.market_listings.items[i];
        if (l.kind == .part or l.expires_day <= day or l.company != .none) {
            if (l.kind == .unit and l.hull_instance_id != .none) {
                if (gs.hull_instances.get(l.hull_instance_id)) |inst| {
                    if (std.meta.activeTag(inst.owner) == .market) {
                        try gs.returnMarketHullToFaction(l.hull_instance_id);
                    }
                }
            }
            _ = gs.market_listings.orderedRemove(i);
        } else i += 1;
    }
    // Every HQ has a board; field HQs are thin.
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| try refreshBoard(gs, entry.value_ptr.id);
    // Every contract world has a thin board of its own.
    var cit = gs.contracts.iterator();
    while (cit.next()) |entry| if (entry.value_ptr.status == .active) try refreshContractWorld(gs, entry.value_ptr);
}

/// The contract world's hull board (ARCH §9.8 "buy a local
/// replacement"): a few hulls off the world's own house table, at the
/// field markup, for the deployed company's local funds — the grace window
/// after a mauling has somewhere to shop.
pub fn refreshContractWorld(gs: *GameState, c: *const contract.Contract) !void {
    const world = planet.find(c.planet_key) orelse return;
    const day = gs.clock.day_index;
    const home = gs.homeHqFor(c.assigned_company);
    for (0..tuning.market.contract_planet_slots) |_| {
        const design = @import("../domain/rat.zig").roll(&gs.rng, .market, world.faction, @import("../gen/company_gen.zig").rollWeightClass(&gs.rng, .market), gs.clock.date.year);
        if (!market.listingAppears(&gs.rng, design.rarity, world.industry, 0, 0, .market)) continue;
        const cond = market.rollHullCondition(&gs.rng, .market);
        const price_roll = market.priceRollBp(&gs.rng, .market);
        var weapon_value: types.CBills = 0;
        var weapons: types.CBills = 0;
        for (design.loadout) |slot| if (slot.class == .weapon) {
            weapon_value += @import("../domain/part.zig").cost(slot.part);
            weapons += 1;
        };
        const avg_weapon = if (weapons > 0) @divTrunc(weapon_value, weapons) else 50_000;
        try gs.market_listings.append(gs.allocator(), .{
            .id = @enumFromInt(gs.next_listing_id),
            .kind = .unit,
            .item_key = design.key,
            .rarity = design.rarity,
            .price = types.applyBp(market.hullPrice(design.cost, avg_weapon, cond, price_roll), tuning.finance.field_markup_bp),
            .listed_day = day,
            .expires_day = day + tuning.market.hull_listing_days,
            .condition = cond,
            .hq = home,
            .company = c.assigned_company,
        });
        gs.next_listing_id += 1;
    }
}

fn refreshBoard(gs: *GameState, hq_id: types.HqId) !void {
    const hq = gs.hqs.getPtr(hq_id) orelse return;
    const world = planet.find(hq.planet_key) orelse return;
    const warehouse = hq.effectiveFacilityLevel(.warehouse);
    const day = gs.clock.day_index;
    const part_mod = @import("../domain/part.zig");
    const thin = hq.tier == .field;

    // Staples: weapons, armor, munitions, supplies — always here, priced by
    // local industry (rich worlds undercut).
    const industry_bp: types.Bp = tuning.market.staple_price_base_bp - tuning.market.staple_price_per_industry_bp * @as(types.Bp, world.industry);
    for (market.staple_keys) |key| {
        const def = part_mod.find(key) orelse continue;
        try gs.market_listings.append(gs.allocator(), .{
            .id = @enumFromInt(gs.next_listing_id),
            .kind = .part,
            .item_key = def.key,
            .rarity = def.rarity,
            .price = types.applyBp(def.cost, if (thin) industry_bp + 2_000 else industry_bp),
            .quantity = if (thin) 5 else 20,
            .staple = true,
            .listed_day = day,
            .expires_day = day + tuning.market.hull_listing_days,
            .hq = hq_id,
        });
        gs.next_listing_id += 1;
    }

    // The black market: where the hall gossips and the comms
    // reach, a fence sometimes has something off the books.
    {
        const bm = tuning.market;
        if (hq.effectiveFacilityLevel(.hiring_hall) >= 1 and hq.effectiveFacilityLevel(.comms) >= bm.black_market_comms and gs.rng.roll2d6(.market) >= bm.black_market_target) {
            const rr = gs.rng.random(.market);
            if (rr.boolean()) { // TUNE: hull vs scarce-part split
                // A rare hull, whatever house built it.
                var buf: [64]*const chassis_mod.Chassis = undefined;
                const pool = chassis_mod.ofWeightClass(if (rr.boolean()) .heavy else .assault, gs.clock.date.year, &buf); // TUNE: heavy vs assault split
                var pick: ?*const chassis_mod.Chassis = null;
                for (pool) |c| if (c.rarity == .rare or c.rarity == .very_rare) {
                    if (pick == null or rr.uintLessThan(u8, 3) == 0) pick = c; // TUNE: reservoir sample over rare pool
                };
                if (pick) |c| {
                    try gs.market_listings.append(gs.allocator(), .{
                        .id = @enumFromInt(gs.next_listing_id),
                        .kind = .unit,
                        .item_key = c.key,
                        .rarity = c.rarity,
                        .price = types.applyBp(c.cost, bm.black_market_price_bp),
                        .hq = hq_id,
                        .listed_day = day,
                        .expires_day = day + bm.black_market_days,
                        // TUNE: black-market condition bands
                        .condition = .{ .armor_pct = @intCast(60 + rr.uintLessThan(u8, 40)), .quality = if (rr.boolean()) .c else .d, .damaged_slots = rr.uintLessThan(u8, 2), .destroyed_slots = 0, .missing_components = 0 },
                        .black_market = true,
                    });
                    gs.next_listing_id += 1;
                }
            } else {
                // A scarce part (availability D or worse).
                var pick: ?*const part_mod.PartDef = null;
                for (part_mod.catalog) |*def| if (@intFromEnum(def.availability) >= @intFromEnum(part_mod.Availability.d) and def.intro_year <= gs.clock.date.year) {
                    if (pick == null or rr.uintLessThan(u8, 3) == 0) pick = def; // TUNE: reservoir sample over scarce catalog
                };
                if (pick) |def| {
                    try gs.market_listings.append(gs.allocator(), .{
                        .id = @enumFromInt(gs.next_listing_id),
                        .kind = .part,
                        .item_key = def.key,
                        .rarity = def.rarity,
                        .price = types.applyBp(def.cost, bm.black_market_price_bp),
                        .hq = hq_id,
                        .quantity = 1,
                        .listed_day = day,
                        .expires_day = day + bm.black_market_days,
                        .black_market = true,
                    });
                    gs.next_listing_id += 1;
                }
            }
        }
    }

    // Rare slots: components, heavy weapons — maybe this month, maybe not.
    const rare_slots: u32 = if (thin) 1 else 2 + warehouse;
    const r = gs.rng.random(.market);
    for (0..rare_slots) |_| {
        var def = &part_mod.catalog[r.uintLessThan(usize, part_mod.catalog.len)]; // uniform pick from part catalog
        var tries: u8 = 0;
        while (def.rarity == .common and tries < 6) : (tries += 1) {
            def = &part_mod.catalog[r.uintLessThan(usize, part_mod.catalog.len)]; // uniform pick, re-roll common up to 6 times
        }
        // Sourcing: scarce parts, periphery shelves, comms reach.
        const src = part_mod.sourcing(def, @import("../domain/faction.zig").isPeriphery(world.faction), hq.effectiveFacilityLevel(.comms));
        if (!market.listingAppears(&gs.rng, def.rarity, world.industry, warehouse, src.total(), .market)) continue;
        const price_roll = market.priceRollBp(&gs.rng, .market);
        try gs.market_listings.append(gs.allocator(), .{
            .id = @enumFromInt(gs.next_listing_id),
            .kind = .part,
            .item_key = def.key,
            .rarity = def.rarity,
            .price = types.applyBp(def.cost, price_roll),
            .quantity = r.intRangeAtMost(u32, 1, 2), // TUNE: rare-slot quantity band
            .listed_day = day,
            .expires_day = day + tuning.market.hull_listing_days,
            .hq = hq_id,
        });
        gs.next_listing_id += 1;
    }

    // Hulls: fill the lot to its size with new arrivals, each with a rolled
    // condition and a stay of 2–4 months.
    const lot_size: u32 = if (thin) 1 else 2 + warehouse;
    var hulls: u32 = 0;
    for (gs.market_listings.items) |l| {
        if (l.kind == .unit and l.hq == hq_id and !l.staple and l.company == .none) hulls += 1;
    }
    var attempts: u32 = 0;
    while (hulls < lot_size and attempts < 12) : (attempts += 1) {
        // Meks off the local house's table, the odd combat vehicle
        // from anywhere; fighters and ships have their own slot below.
        if (r.uintLessThan(u8, 4) == 0) { // TUNE: vehicle vs mek lot ratio (1-in-4)
            if (try conventional_market.appendOffer(gs, hq_id, world.industry, warehouse, .vehicle)) hulls += 1;
            continue;
        }
        const design = @import("../domain/rat.zig").roll(&gs.rng, .market, world.faction, @import("../gen/company_gen.zig").rollWeightClass(&gs.rng, .market), gs.clock.date.year);
        if (!market.listingAppears(&gs.rng, design.rarity, world.industry, warehouse, 0, .market)) continue;
        const cond = market.rollHullCondition(&gs.rng, .market);
        const price_roll = market.priceRollBp(&gs.rng, .market);
        var weapon_value: types.CBills = 0;
        var weapons: types.CBills = 0;
        for (design.loadout) |slot| {
            if (slot.class == .weapon) {
                weapon_value += part_mod.cost(slot.part);
                weapons += 1;
            }
        }
        const avg_weapon = if (weapons > 0) @divTrunc(weapon_value, weapons) else 50_000;
        try gs.market_listings.append(gs.allocator(), .{
            .id = @enumFromInt(gs.next_listing_id),
            .kind = .unit,
            .item_key = design.key,
            .rarity = design.rarity,
            .price = market.hullPrice(design.cost, avg_weapon, cond, price_roll),
            .listed_day = day,
            .expires_day = day + tuning.market.offer_days_base + @as(u32, gs.rng.roll2d6(.market)) * tuning.market.offer_days_per_pip,
            .condition = cond,
            .hq = hq_id,
        });
        gs.next_listing_id += 1;
        hulls += 1;
    }

    // The transport slot: a spaceport of some size sees a fighter, a
    // dropship or a jumpship for sale now and then — one attempt per
    // refresh, at the design's rarity; fighters at list, ships scaled by
    // transport_price_bp. New hulls; ships need a berth to buy.
    const port = hq.effectiveFacilityLevel(.spaceport);
    if (!thin and port >= 2) {
        var already = false;
        for (gs.market_listings.items) |l| {
            if (l.kind != .unit or l.hq != hq_id or l.staple) continue;
            if (chassis_mod.find(l.item_key)) |d| if (d.kind != .mek) {
                already = true;
            };
        }
        if (!already) {
            const comms = hq.effectiveFacilityLevel(.comms);
            const kind: unit_mod.UnitKind = if (port >= 4 and comms >= 3 and r.uintLessThan(u8, 3) == 0) .jumpship else if (port >= 3 and r.boolean()) .dropship else .aerospace; // TUNE: transport kind odds by port/comms tier
            if (kind == .aerospace) {
                _ = try conventional_market.appendOffer(gs, hq_id, world.industry, port, .aerospace);
            } else {
                var buf: [16]*const chassis_mod.Chassis = undefined;
                const pool = chassis_mod.ofKind(kind, gs.clock.date.year, &buf);
                if (pool.len > 0) {
                    const design = pool[r.uintLessThan(usize, pool.len)]; // uniform pick from transport pool
                    if (market.listingAppears(&gs.rng, design.rarity, world.industry, port, 0, .market)) {
                        const price_roll = market.priceRollBp(&gs.rng, .market);
                        const base = types.applyBp(design.cost, market.transport_price_bp);
                        try gs.market_listings.append(gs.allocator(), .{
                            .id = @enumFromInt(gs.next_listing_id),
                            .kind = .unit,
                            .item_key = design.key,
                            .rarity = design.rarity,
                            .price = types.applyBp(base, price_roll),
                            .listed_day = day,
                            .expires_day = day + tuning.market.offer_days_base + @as(u32, gs.rng.roll2d6(.market)) * tuning.market.offer_days_per_pip,
                            .hq = hq_id,
                        });
                        gs.next_listing_id += 1;
                    }
                }
            }
        }
    }

    // Support vehicles are always on offer at a regional or brigade board:
    // trucks are how a company's field capacity grows, so they
    // are a staple line, new, at list price, two at a time.
    if (!thin) {
        const support_keys = [_][]const u8{ "CGT-3", "SVT-1", "MASH-27", "SEC-PLT" };
        for (support_keys) |key| {
            var present = false;
            for (gs.market_listings.items) |l| {
                if (l.kind == .unit and l.hq == hq_id and l.staple and std.mem.eql(u8, l.item_key, key)) present = true;
            }
            if (present) continue;
            const design = chassis_mod.find(key) orelse continue;
            try gs.market_listings.append(gs.allocator(), .{
                .id = @enumFromInt(gs.next_listing_id),
                .kind = .unit,
                .item_key = design.key,
                .rarity = .common,
                .price = design.cost,
                .hq = hq_id,
                .quantity = 2,
                .staple = true,
                .listed_day = day,
                .expires_day = day + tuning.market.staple_listing_days,
            });
            gs.next_listing_id += 1;
        }
    }
}

/// Who walks into a hiring hall: combat crews and techs most often, then
/// medical and every back-office desk, so every desk can be filled.
const hall_roles = [_]person_mod.Role{
    .mekwarrior,    .mekwarrior,    .tech_mek,        .tech_mek,   .tech_mechanic,   .vehicle_crew,
    .astech,        .astech,        .medic,           .doctor,     .admin_logistics, .admin_hr,
    .admin_finance, .admin_command, .admin_transport, .aero_pilot, .tech_aero,       .dropship_crew,
    .jumpship_crew,
};

/// A walk-in the hall chooses: a short desk or trade gets every other
/// arrival until it is staffed, else any hall role.
fn arrivalRole(gs: *GameState, hq: *const hq_mod.Hq) person_mod.Role {
    // Dice order matters for replays: the short-desk roll first, the
    // pick from the hall roles only when it is needed.
    if (shortRole(gs, hq)) |short| if (gs.rng.roll2d6(.market) >= 7) return short;
    return hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)]; // uniform pick from hall roles
}

/// Days a walk-in or a floor top-up stays on the board; the crowd
/// `refreshCandidates` lists lingers longer (tuning.market).
const walkin_days: u32 = tuning.market.hall_walkin_days;
const refresh_days: u32 = tuning.market.hall_refresh_days;

/// Put one candidate on an HQ's board: rolled to the outfit's recruit
/// bonus, asking a signing bonus by experience, gone after `ttl_days`.
fn listCandidate(gs: *GameState, hq: *const hq_mod.Hq, role: person_mod.Role, ttl_days: u32) !void {
    const spec = person_gen.generateWithBonus(&gs.rng, .market, role, personnel.recruitBonus(gs, hq.id));
    const salary = types.applyBp(role.baseSalary(), spec.experience.salaryMultBp());
    try gs.candidates.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_candidate_id),
        .hq = hq.id,
        .spec = spec,
        .asking_bonus = salary * (tuning.market.asking_bonus_base_months + @as(types.CBills, @intFromEnum(spec.experience))),
        .listed_day = gs.clock.day_index,
        .expires_day = gs.clock.day_index + ttl_days,
    });
    gs.next_candidate_id += 1;
}

/// An admin desk this HQ is short on, if any — the hall favours it.
fn shortAdminRole(gs: *GameState, hq: *const hq_mod.Hq) ?person_mod.Role {
    for (hq.staffRequired().desks()) |d| if (hq_ops.hqStaff(gs, hq.id, d.role).count < d.need) return d.role;
    return null;
}

/// The role the outfit is shortest of at this HQ: a short desk
/// first, then the largest gap in the manning tables of the companies
/// supplied here (pooled roles excepted — astechs and medics are hired to
/// complement, not recruited). Word gets round: half the walk-ins are
/// people who heard the outfit is hiring that trade.
fn shortRole(gs: *GameState, hq: *const hq_mod.Hq) ?person_mod.Role {
    if (shortAdminRole(gs, hq)) |r| return r;
    var best: ?person_mod.Role = null;
    var best_gap: u32 = 0;
    var fit = gs.forces.iterator();
    while (fit.next()) |e| {
        const f = e.value_ptr;
        if (f.echelon != .company or f.supplying_hq != hq.id) continue;
        for (personnel.manningNeeds(gs, f.id)) |n| {
            if (personnel.isPooledRole(n.role)) continue;
            const gap = n.need -| personnel.manningHave(gs, f.id, n.role);
            if (gap > best_gap) {
                best_gap = gap;
                best = n.role;
            }
        }
    }
    return best;
}

/// Daily hiring-hall churn: people move fast. Each turn some
/// candidates walk out and, on a good roll, someone new walks in.
pub fn churnCandidates(gs: *GameState) !void {
    const day = gs.clock.day_index;

    var i: usize = 0;
    while (i < gs.candidates.items.len) {
        const c = gs.candidates.items[i];
        if (c.expires_day <= day or gs.rng.roll2d6(.market) <= 3) {
            _ = gs.candidates.swapRemove(i); // took another job
        } else i += 1;
    }

    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        const hall = hq.effectiveFacilityLevel(.hiring_hall);
        if (hall == 0) continue;
        const hr = hq_ops.hqStaff(gs, hq.id, .admin_hr).count;
        const roll = @as(u32, gs.rng.roll2d6(.market)) + hall + hr / 2;
        if (roll < tuning.market.hall_arrival_target) continue; // quiet day at the hall
        // A bigger hall draws a bigger crowd: one walk-in per hall level, one
        // more on a boxcars day.
        const arrivals: u32 = hall + @as(u32, if (roll >= 12) 1 else 0);
        for (0..arrivals) |_| try listCandidate(gs, hq, arrivalRole(gs, hq), walkin_days);
        _ = try topUpHall(gs, hq); // the board never runs dry
    }
}

/// The floor under every board: a hall that dips under the floor for a
/// role gets a fresh walk-in of that role the same day — hull-seat crews
/// and astechs `hall_floor_combat` deep, everyone else `hall_floor`.
pub fn topUpHall(gs: *GameState, hq: *const hq_mod.Hq) !u32 {
    if (hq.effectiveFacilityLevel(.hiring_hall) == 0) return 0;
    var added: u32 = 0;
    inline for (@typeInfo(person_mod.Role).@"enum".fields) |f| {
        const role: person_mod.Role = @enumFromInt(f.value);
        const floor: u32 = if (role.hallCombatFloor()) tuning.market.hall_floor_combat else tuning.market.hall_floor;
        var have: u32 = 0;
        for (gs.candidates.items) |c| if (c.hq == hq.id and c.spec.role == role) {
            have += 1;
        };
        while (have < floor) : (have += 1) {
            try listCandidate(gs, hq, role, walkin_days);
            added += 1;
        }
    }
    return added;
}

/// Fill every HQ's hiring hall (the day the campaign opens): count by
/// hiring-hall level + HR staff; they move on after `hall_refresh_days`.
pub fn refreshCandidates(gs: *GameState) !void {
    const day = gs.clock.day_index;

    // Expire the stale.
    var i: usize = 0;
    while (i < gs.candidates.items.len) {
        if (gs.candidates.items[i].expires_day <= day) {
            _ = gs.candidates.swapRemove(i);
        } else i += 1;
    }

    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| {
        const hq = entry.value_ptr;
        const hall = hq.effectiveFacilityLevel(.hiring_hall);
        if (hall == 0) continue;
        const hr = hq_ops.hqStaff(gs, hq.id, .admin_hr).count;
        const count: u32 = 2 + hall + hr / 2;
        for (0..count) |_| try listCandidate(gs, hq, arrivalRole(gs, hq), refresh_days);
    }
}

/// The outfit's monthly running cost divided by its combat companies: what
/// an employer reckons one company costs to keep in the field.
pub fn perCompanyOpsCost(gs: *GameState) types.CBills {
    const ops_cost = treasury.monthlyPayroll(gs) + treasury.monthlyHullUpkeep(gs) + maintenanceEstimate(gs);
    var companies: i64 = 0;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        companies += 1;
    };
    return @divTrunc(ops_cost, @max(1, companies));
}

/// Expected monthly maintenance consumables: `maintenance.monthlyConsumablesEstimate`.
fn maintenanceEstimate(gs: *GameState) types.CBills {
    return @import("maintenance.zig").monthlyConsumablesEstimate(gs);
}

// ---- C4b exec wrappers ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

/// Resolve a contract offer by typed ContractId; returns its index or null.
fn findOffer(gs: *GameState, offer_id: types.ContractId) ?usize {
    for (gs.contract_offers.items, 0..) |o, i| {
        if (o.id == offer_id) return i;
    }
    return null;
}

/// Resolve a market listing by typed ListingId; returns its index or null.
fn findListing(gs: *GameState, lid: types.ListingId) ?usize {
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.id == lid) return i;
    }
    return null;
}

/// Resolve a hiring-hall candidate by typed CandidateId; returns its index or null.
fn findCandidate(gs: *GameState, cid: types.CandidateId) ?usize {
    for (gs.candidates.items, 0..) |c, i| {
        if (c.id == cid) return i;
    }
    return null;
}

pub fn execNegotiate(gs: *GameState, n: @FieldType(Command, "negotiate")) Error!Result {
    const offer_index = findOffer(gs, n.offer) orelse return Error.NoSuchOffer;
    const outcome = negotiate(gs, offer_index, n.term) catch |err| return @errorCast(err);
    return .{ .negotiation = switch (outcome) {
        .improved => .improved,
        .hardened => .hardened,
        .withdrawn => .withdrawn,
    } };
}

pub fn execBuyListing(gs: *GameState, buy: @FieldType(Command, "buy_listing")) Error!Result {
    const index = findListing(gs, buy.listing) orelse return Error.NoSuchListing;
    const res = buyListing(gs, index, buy.buyer) catch |err| return @errorCast(err);
    return .{ .unit = res.unit, .fraud = res.fraud };
}

pub fn execBuyHullFor(gs: *GameState, b: @FieldType(Command, "buy_hull_for")) Error!Result {
    const res = buyHullFor(gs, b.listing, b.company, b.lance) catch |err| return @errorCast(err);
    return .{ .unit = res.unit, .eta_days = res.eta_days, .fraud = res.fraud };
}

pub fn execBuySupportHull(gs: *GameState, b: @FieldType(Command, "buy_support_hull")) Error!Result {
    const res = buySupportHull(gs, b.company, b.kind) catch |err| return @errorCast(err);
    return .{ .unit = res.unit, .eta_days = res.eta_days, .fraud = res.fraud };
}

pub fn execHireCandidate(gs: *GameState, cid: @FieldType(Command, "hire_candidate")) Error!Result {
    const index = findCandidate(gs, cid) orelse return Error.NoSuchCandidate;
    const id = hireCandidate(gs, index) catch |err| return @errorCast(err);
    return .{ .hired = id };
}

test "refresh only offers work inside rings or the beachhead band" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "Erik Kalmar", .CC, .quartermaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha Company");

    try refresh(&gs);
    try std.testing.expect(gs.contract_offers.items.len >= 1);

    const hq = gs.hqs.values()[0];
    const hq_world = planet.find(hq.planet_key).?;
    for (gs.contract_offers.items) |offer| {
        const world = planet.find(offer.planet_key).?;
        const dist = planet.distanceLy(hq_world, world);
        try std.testing.expect(dist <= hq.influenceLy() + market.beachhead_band_ly);
        try std.testing.expectEqual(dist > hq.influenceLy(), offer.beachhead);
        try std.testing.expect(offer.terms.base_pay_month > 0);
        try std.testing.expect(offer.terms.length_months >= 2);
    }
}

test "hulls persist across refreshes, staples are always stocked" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 19 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    try refreshListings(&gs);

    // Support vehicles are a staple hull line at every regional board.
    var trucks = false;
    for (gs.market_listings.items) |l| {
        if (l.kind == .unit and l.staple and std.mem.eql(u8, l.item_key, "CGT-3")) trucks = true;
    }
    try std.testing.expect(trucks);
    // Every staple line is on the board.
    for (market.staple_keys) |key| {
        var found = false;
        for (gs.market_listings.items) |l| {
            if (l.staple and std.mem.eql(u8, l.item_key, key)) found = true;
        }
        try std.testing.expect(found);
    }

    // Hulls listed today survive next month's refresh (they haven't aged out)...
    var first_hull: ?[]const u8 = null;
    var first_expiry: u32 = 0;
    for (gs.market_listings.items) |l| {
        if (l.kind == .unit and first_hull == null) {
            first_hull = l.item_key;
            first_expiry = l.expires_day;
        }
    }
    if (first_hull) |key| {
        gs.clock.day_index += 31;
        try refreshListings(&gs);
        var still = false;
        for (gs.market_listings.items) |l| {
            if (l.kind == .unit and std.mem.eql(u8, l.item_key, key) and l.expires_day == first_expiry) still = true;
        }
        try std.testing.expect(still);
        // ...and vanish once other buyers have had their months.
        gs.clock.day_index = first_expiry + 1;
        try refreshListings(&gs);
        var gone = true;
        for (gs.market_listings.items) |l| {
            if (l.kind == .unit and l.expires_day == first_expiry) gone = false;
        }
        try std.testing.expect(gone);
    }
}

test "hiring halls churn daily" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .DC, .paymaster);
    try refreshCandidates(&gs);
    var arrivals: u32 = 0;
    var departures: u32 = 0;
    for (0..60) |_| {
        const before = gs.candidates.items.len;
        gs.clock.day_index += 1;
        try churnCandidates(&gs);
        const after = gs.candidates.items.len;
        if (after > before) arrivals += 1;
        if (after < before) departures += 1;
    }
    try std.testing.expect(arrivals > 5);
    try std.testing.expect(departures > 5);
}

test "every admin desk walks into the hall, short desks first" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 21 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .DC, .paymaster);
    // The fresh commander's HQ has no finance clerk; the hall must offer one.
    var seen_finance = false;
    var seen_command = false;
    for (0..40) |_| {
        try refreshCandidates(&gs);
        for (gs.candidates.items) |c| {
            if (c.spec.role == .admin_finance) seen_finance = true;
            if (c.spec.role == .admin_command) seen_command = true;
        }
        gs.clock.day_index += 7;
    }
    try std.testing.expect(seen_finance);
    try std.testing.expect(seen_command);
}

test "an F-rated outfit hears only from the periphery and never gets a planetary assault" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 127 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    gs.funds = -1;
    gs.reputation = -100; // record −40, treasury −20 …
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.role.isCombat()) {
        try e.value_ptr.skills.put(gs.allocator(), e.value_ptr.role.primarySkill(), 7); // … and green as grass: firmly F
    };
    try std.testing.expectEqual(@as(u8, 0), try rating.currentIndex(&gs));
    gs.contract_offers.clearRetainingCapacity();
    try refresh(&gs);
    for (gs.contract_offers.items) |o| {
        try std.testing.expect(!isGreatHouse(o.employer_key));
        try std.testing.expect(o.kind != .planetary_assault);
    }
    try std.testing.expectEqual(@as(types.Bp, 8_000), rating.payBp(0));
    try std.testing.expectEqual(@as(types.Bp, 13_000), rating.payBp(5));
}

test "a wired HQ with a hall eventually hears from a fence; a firebase never does" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1217 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const hq = gs.seat();
    // Comms up to the line.
    const h = gs.hqs.getPtr(hq).?;
    var has_comms = false;
    for (h.facilities.items) |*f| if (f.kind == .comms) {
        f.level = @max(f.level, tuning.market.black_market_comms);
        has_comms = true;
    };
    if (!has_comms) try h.facilities.append(gs.allocator(), .{ .kind = .comms, .level = tuning.market.black_market_comms });
    h.staff_assigned = 999;
    var seen = false;
    for (0..40) |_| {
        gs.market_listings.clearRetainingCapacity();
        try refreshBoard(&gs, hq);
        for (gs.market_listings.items) |l| if (l.black_market) {
            seen = true;
            try std.testing.expect(l.expires_day - l.listed_day == tuning.market.black_market_days);
        };
        if (seen) break;
    }
    try std.testing.expect(seen);
}

test "no HQ, no reputation, no offers" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6 });
    defer gs.deinit();
    try refresh(&gs);
    try std.testing.expectEqual(@as(usize, 0), gs.contract_offers.items.len);
}

test "the transport slot opens with the spaceport; ordinary lots are meks only" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 21 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    // Spaceport 1: never a fighter or ship, however many refreshes.
    for (0..12) |_| {
        gs.clock.day_index += 31;
        try refreshListings(&gs);
        for (gs.market_listings.items) |l| if (l.kind == .unit) {
            const d = chassis_mod.find(l.item_key).?;
            const k = d.kind;
            try std.testing.expect(k == .mek or k == .vehicle or l.staple);
            if (k == .vehicle) try std.testing.expect(chassis_mod.conventionalMarketEligible(d, gs.clock.date.year));
        };
    }
    // Spaceport 4 + comms 3, staffed: over a year something non-mek shows up.
    const hq = &gs.hqs.values()[0];
    for (hq.facilities.items) |*f| {
        if (f.kind == .spaceport) f.level = 4;
        if (f.kind == .comms) f.level = 3;
    }
    hq.staff_assigned = 999;
    var seen = false;
    for (0..24) |_| {
        gs.clock.day_index += 31;
        try refreshListings(&gs);
        for (gs.market_listings.items) |l| if (l.kind == .unit and !l.staple) {
            const d = chassis_mod.find(l.item_key).?;
            if (d.kind != .mek) {
                seen = true;
                if (d.kind == .vehicle or d.kind == .aerospace) try std.testing.expect(chassis_mod.conventionalMarketEligible(d, gs.clock.date.year));
                if (d.kind.isTransport()) try std.testing.expect(l.price < d.cost); // scaled by transport_price_bp
            }
        };
    }
    try std.testing.expect(seen);
}

test "the hiring hall always has a few of every role" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1210 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    gs.candidates.clearRetainingCapacity();
    try churnCandidates(&gs);
    const hq = gs.seat();
    inline for (@typeInfo(person_mod.Role).@"enum".fields) |f| {
        const role: person_mod.Role = @enumFromInt(f.value);
        var have: u32 = 0;
        for (gs.candidates.items) |c| if (c.hq == hq and c.spec.role == role) {
            have += 1;
        };
        try std.testing.expect(have >= 1);
        if (role == .mekwarrior or role == .tech_mek) try std.testing.expect(have >= 2);
    }
    // Hire every mekwarrior; tomorrow the board has at least two again.
    var i: usize = 0;
    while (i < gs.candidates.items.len) {
        if (gs.candidates.items[i].spec.role == .mekwarrior) _ = gs.candidates.swapRemove(i) else i += 1;
    }
    try churnCandidates(&gs);
    var mw: u32 = 0;
    for (gs.candidates.items) |c| if (c.hq == hq and c.spec.role == .mekwarrior) {
        mw += 1;
    };
    try std.testing.expect(mw >= 2);
}

test "the board is a mix: at least offers_min offers, no kind over a third of them" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 610 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "Erik Kalmar", .LC, .quartermaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha Company");
    try refresh(&gs);
    const n = gs.contract_offers.items.len;
    try std.testing.expect(n >= tuning.market.offers_min and n <= tuning.market.offers_max);
    const cap = @max(2, n / 3);
    inline for (@typeInfo(contract.ContractKind).@"enum".fields) |f| {
        const kind: contract.ContractKind = @enumFromInt(f.value);
        var same: usize = 0;
        for (gs.contract_offers.items) |o| if (o.kind == kind) {
            same += 1;
        };
        try std.testing.expect(same <= cap);
    }
    // … and the garrison class fills at most half of it.
    var garrison_class: usize = 0;
    for (gs.contract_offers.items) |o| if (o.kind.isGarrisonClass()) {
        garrison_class += 1;
    };
    try std.testing.expect(garrison_class <= @max(2, n / 2));
}

test "offers are priced per company — a second company does not double every contract's pay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 96 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const one = perCompanyOpsCost(&gs);
    _ = try @import("starter_company.zig").generateInto(&gs, "Bravo");
    const two = perCompanyOpsCost(&gs);
    // Two like companies: the per-company figure barely moves (HQ overhead is shared).
    try std.testing.expect(two < one);
    try std.testing.expect(two * 10 > one * 6);
    // The whole-outfit figure roughly doubles.
    const whole = treasury.monthlyPayroll(&gs) + treasury.monthlyHullUpkeep(&gs) + maintenanceEstimate(&gs);
    try std.testing.expect(whole > @divTrunc(two * 18, 10));
}

test "company operating estimate consumes the shared artillery carrying owner" {
    const artillery = @import("artillery.zig");
    const unit = @import("../domain/unit.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    const estimate = perCompanyOpsCost(&gs);
    const liquidation = try treasury.liquidationValue(std.testing.allocator, &gs);
    const bought = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    try std.testing.expectEqual(unit.monthlyCarryCost(.vehicle), artillery.monthlyCarry(&gs));
    try std.testing.expectEqual(estimate + artillery.monthlyCarry(&gs), perCompanyOpsCost(&gs));
    try std.testing.expectEqual(liquidation + artillery.saleValue(gs.artillery_formations.getPtr(bought.artillery_formation).?), try treasury.liquidationValue(std.testing.allocator, &gs));
    _ = try artillery.sell(&gs, bought.artillery_formation);
    try std.testing.expectEqual(estimate, perCompanyOpsCost(&gs));
    try std.testing.expectEqual(liquidation, try treasury.liquidationValue(std.testing.allocator, &gs));
}

pub const NegotiateOutcome = enum { improved, hardened, withdrawn };

/// Can this company take this offer? An offer belongs to the board
/// of the HQ that posted it: only companies based there (their home HQ)
/// may accept — from home, or redeploying from wherever they stand. Offers
/// saved before schema v24 carry no board and are open to anyone.
pub fn offerEligible(gs: *GameState, offer: *const contract.Contract, company: types.ForceId) bool {
    if (offer.offer_hq == .none) return true;
    return gs.homeHqFor(company) == offer.offer_hq;
}

/// The HQ whose board posted this offer: `offer.offer_hq` when present,
/// else the seat (covers pre-schema-v24 offers with `.none`).
/// Negotiation reads the command office at this HQ (C10 B1, rule 22).
pub fn offerBoardHq(gs: *GameState, offer: *const contract.Contract) types.HqId {
    if (offer.offer_hq != .none and gs.hqs.getPtr(offer.offer_hq) != null) return offer.offer_hq;
    return gs.seat();
}

/// CamOps negotiation, one round per offer: 2d6 + reputation edge
/// + the command office's skill edge against a target eased by standing
/// with the employer. Success moves the chosen term a step; a miss hardens
/// the pay; a natural 2 and the employer walks away.
pub fn negotiate(gs: *GameState, offer_index: usize, term: contract.NegotiableTerm) error{ NoSuchOffer, AlreadyNegotiated, TermAtCap, OutOfMemory }!NegotiateOutcome {
    if (offer_index >= gs.contract_offers.items.len) return error.NoSuchOffer;
    const c = &gs.contract_offers.items[offer_index];
    if (c.negotiated) return error.AlreadyNegotiated;
    var probe = c.terms;
    if (!probe.improve(term)) return error.TermAtCap;
    const t = tuning.contract;
    const board_hq: types.HqId = offerBoardHq(gs, c);
    const office = if (board_hq != .none) hq_ops.hqStaff(gs, board_hq, .admin_command) else hq_ops.StaffSummary{};
    const office_edge: i32 = if (office.count == 0) -1 else person_mod.skillRollBonus(office.best_skill);
    // The letter at the table: F −2 … A* +3.
    const rep_edge: i32 = @as(i32, try rating.currentIndex(gs)) - tuning.rating.negotiation_offset;
    const target: i32 = t.negotiation_target - @divTrunc(gs.standing(c.employer_key), t.negotiation_standing_per);
    const raw = gs.rng.roll2d6(.market);
    const total: i32 = @as(i32, raw) + office_edge + rep_edge;
    c.negotiated = true;
    const ctx: state_mod.LogCtx = .{};
    if (raw == 2) {
        try gs.log(.contract, ctx, "[negotiation] {s} {s} on {s}: the employer walks away from the table (natural 2)", .{ c.employer_key, @tagName(c.kind), c.planet_key });
        _ = gs.contract_offers.orderedRemove(offer_index);
        return .withdrawn;
    }
    if (total >= target) {
        _ = c.terms.improve(term);
        try gs.log(.contract, ctx, "[negotiation] {s} {s} on {s}: {s} improved ({d}+{d}+{d} vs {d}) — advance {d}%, salvage {d}%, transport {d}%, support {d}%, {s} rights, {d}/mo", .{
            c.employer_key, @tagName(c.kind), c.planet_key, @tagName(term), raw, office_edge, rep_edge, target, c.terms.advance_pct, c.terms.salvage_pct, c.terms.transport_pct, c.terms.overhead_pct, @tagName(c.terms.command_rights), c.terms.base_pay_month,
        });
        return .improved;
    }
    c.terms.base_pay_month = types.applyBp(c.terms.base_pay_month, t.negotiation_fail_pay_bp);
    try gs.log(.contract, ctx, "[negotiation] {s} {s} on {s}: they hold firm on {s} and shave the pay 5% ({d}+{d}+{d} vs {d})", .{ c.employer_key, @tagName(c.kind), c.planet_key, @tagName(term), raw, office_edge, rep_edge, target });
    return .hardened;
}

// ---- C4b market command handlers moved from commands.zig ----

/// Result returned by buy operations.
pub const BuyResult = struct {
    unit: types.UnitId = .none,
    eta_days: u32 = 0,
    /// The black-market fence took the money; no unit/stock resulted (rule 33).
    /// Ephemeral — not persisted, not in the digest (rule 45).
    fraud: bool = false,
};

/// Purchase a dispersed black-market hull through an HQ at its listed world.
/// All fallible state changes are prepared before payment, listing removal, or
/// the market RNG stream commits.
fn buyDispersedListingAtHq(gs: *GameState, index: usize, listing: market.Listing, price: types.CBills, hq: types.HqId) !BuyResult {
    if (listing.kind != .unit) return error.NoSuchListing;
    const world = planet.find(listing.planet_key) orelse return error.NoSuchListing;
    var staged_rng = gs.rng;
    const roll = staged_rng.roll2d6(.market);
    const fraud = roll <= tuning.market.black_market_fraud_target;
    const posting = try gs.prepareTreasuryPosting(.{ .hq = hq }, .{
        .day = gs.clock.day_index,
        .amount = -price,
        .category = .unit_purchase,
        .hq = hq,
        .note = "black market",
    });
    const house_change = if (!std.mem.eql(u8, world.faction, "PER"))
        try gs.prepareStandingAdjustment(world.faction, if (fraud) -tuning.market.black_market_standing_loss else -1)
    else
        null;
    const pirate_change = if (fraud) null else try gs.prepareStandingAdjustment("PER", 1);
    const hull_return = if (fraud and listing.hull_instance_id != .none)
        try gs.prepareMarketHullReturn(listing.hull_instance_id)
    else
        null;
    const hull_transfer = if (!fraud and listing.hull_instance_id != .none)
        try gs.prepareHullTransfer(listing.hull_instance_id, .player, "market", .salvage)
    else
        null;
    var prepared_unit: ?GameState.PreparedUnit = null;
    var acquisition: ?GameState.PreparedHullAcquisition = null;
    if (!fraud) {
        var unit = try gs.prepareUnit(listing.item_key);
        if (listing.condition) |cond| market.applyHullCondition(&unit.unit, cond, staged_rng.random(.market));
        if (listing.hull_instance_id == .none) acquisition = try gs.prepareHullAcquisition(&unit.unit, "unknown");
        prepared_unit = unit;
    }
    const house_now = if (house_change) |change| change.value else 0;
    const pirate_now = if (pirate_change) |change| change.value else 0;
    const log = if (fraud)
        try gs.prepareLog(.market, .{ .hq = hq }, "[black market] the fence vanished with {s} c-bills — no {s} (2d6 = {d}); {s} standing −{d} → {d}", .{ try types.moneyText(gs.allocator(), price), listing.item_key, roll, world.faction, tuning.market.black_market_standing_loss, house_now })
    else
        try gs.prepareLog(.market, .{ .hq = hq }, "[black market] {s} changed hands for {s} c-bills, no questions asked — {s} standing −1 → {d}, pirates +1 → {d}", .{ listing.item_key, try types.moneyText(gs.allocator(), price), world.faction, house_now, pirate_now });

    gs.commitTreasuryPosting(posting);
    gs.rng = staged_rng;
    _ = gs.market_listings.orderedRemove(index);
    if (house_change) |change| gs.commitStandingAdjustment(change);
    if (pirate_change) |change| gs.commitStandingAdjustment(change);
    gs.commitLog(log);
    if (fraud) {
        if (hull_return) |prepared| gs.commitMarketHullReturn(prepared);
        return .{ .fraud = true };
    }
    const uid = gs.commitPreparedUnit(prepared_unit.?);
    const bought = gs.unit(uid).?;
    if (acquisition) |prepared| _ = gs.commitHullAcquisition(bought, prepared) else {
        bought.hull_instance_id = listing.hull_instance_id;
        gs.commitHullTransfer(hull_transfer.?);
    }
    return .{ .unit = uid };
}

/// Whether a listing belongs to the selected buyer's market board. HQ listings
/// without an owner belong to the outfit seat's board.
pub fn listingOnBoard(gs: *const GameState, listing: market.Listing, buyer: types.Site) bool {
    switch (buyer) {
        .outfit => return false,
        .hq => |hq| {
            if (listing.company != .none) return false;
            if (listing.hq != .none) return listing.hq == hq;
            if (!listing.black_market or listing.planet_key.len == 0) return hq == gs.seat();
            const board_hq = gs.hqs.getPtr(hq) orelse return false;
            return black_market.buyerEligible(gs, listing, .player, gs.clock.day_index) and
                std.mem.eql(u8, board_hq.planet_key, listing.planet_key);
        },
        .company => |company| {
            var deployment: ?*const contract.Contract = null;
            for (gs.contracts.values()) |*candidate| {
                if (candidate.status == .active and candidate.assigned_company == company) {
                    deployment = candidate;
                    break;
                }
            }
            if (listing.company != .none) return deployment != null and listing.company == company;
            if (!listing.black_market or listing.planet_key.len == 0 or
                !black_market.buyerEligible(gs, listing, .player, gs.clock.day_index) or
                black_market.playerHqAt(gs, listing) != .none) return false;
            return if (deployment) |active| std.mem.eql(u8, active.planet_key, listing.planet_key) else false;
        },
    }
}

/// Purchase an abstraction-path board hull into an HQ hangar. The prepared
/// instance and provenance row make payment, listing removal, and identity one
/// infallible commit.
fn buyAbstractionHullAtHq(gs: *GameState, index: usize, listing: market.Listing, price: types.CBills, hq: types.HqId, berth_kind: ?unit_mod.UnitKind) !BuyResult {
    var staged_rng = gs.rng;
    var prepared_unit = try gs.prepareUnit(listing.item_key);
    if (listing.condition) |condition| market.applyHullCondition(&prepared_unit.unit, condition, staged_rng.random(.market));
    const prepared_hull = try gs.prepareHullAcquisition(&prepared_unit.unit, "unknown");
    const posting = try gs.prepareTreasuryPosting(.{ .hq = hq }, .{
        .day = gs.clock.day_index,
        .amount = -price,
        .category = .unit_purchase,
        .hq = hq,
        .note = listing.item_key,
    });
    const log = try gs.prepareLog(.market, .{ .hq = hq }, "[market] bought {s} ({s}) for {d}{s}", .{
        listing.item_key,
        if (listing.condition) |condition| condition.label() else "new",
        price,
        if (berth_kind != null) " — berthed here" else "",
    });

    gs.commitTreasuryPosting(posting);
    gs.rng = staged_rng;
    const current = &gs.market_listings.items[index];
    if (listing.staple and current.quantity > 1) current.quantity -= 1 else _ = gs.market_listings.orderedRemove(index);
    const uid = gs.commitPreparedUnit(prepared_unit);
    const bought = gs.unit(uid).?;
    _ = gs.commitHullAcquisition(bought, prepared_hull);
    if (berth_kind != null) bought.berth_hq = hq;
    gs.commitLog(log);
    return .{ .unit = uid };
}

fn buyContractWorldHull(gs: *GameState, index: usize, listing: market.Listing, price: types.CBills, company: types.ForceId, c: *const contract.Contract) !BuyResult {
    var staged_rng = gs.rng;
    var prepared_unit = try gs.prepareUnit(listing.item_key);
    if (listing.condition) |condition| market.applyHullCondition(&prepared_unit.unit, condition, staged_rng.random(.market));
    const acquisition = if (listing.hull_instance_id == .none)
        try gs.prepareHullAcquisition(&prepared_unit.unit, "unknown")
    else
        null;
    const transfer = if (listing.hull_instance_id != .none)
        try gs.prepareHullTransfer(listing.hull_instance_id, .player, "market", .salvage)
    else
        null;
    const placement = try toe.prepareCompanyPoolPlacement(gs, company);
    const company_force = gs.force(company).?;
    const posting = try gs.prepareTreasuryPosting(.{ .company = company }, .{ .day = gs.clock.day_index, .amount = -price, .category = .unit_purchase, .company = company, .contract = c.id, .note = listing.item_key });
    const log = try gs.prepareLog(.market, .{ .company = company, .contract = c.id }, "[market] {s} bought {s} ({s}) on {s} for {d} from local funds — seat a pilot and a tech", .{
        company_force.name, listing.item_key, if (listing.condition) |condition| condition.label() else "new", c.planet_key, price,
    });

    gs.commitTreasuryPosting(posting);
    gs.rng = staged_rng;
    _ = gs.market_listings.orderedRemove(index);
    const uid = gs.commitPreparedUnit(prepared_unit);
    const bought = gs.unit(uid).?;
    if (acquisition) |prepared| _ = gs.commitHullAcquisition(bought, prepared) else {
        bought.hull_instance_id = listing.hull_instance_id;
        gs.commitHullTransfer(transfer.?);
    }
    toe.commitCompanyPoolPlacement(gs, uid, placement);
    gs.commitLog(log);
    return .{ .unit = uid };
}

fn buyExistingHullAtHq(gs: *GameState, index: usize, listing: market.Listing, price: types.CBills, hq: types.HqId, berth_kind: ?unit_mod.UnitKind) !BuyResult {
    const prepared_unit = try gs.prepareUnit(listing.item_key);
    const transfer = try gs.prepareHullTransfer(listing.hull_instance_id, .player, "market", .salvage);
    const posting = try gs.prepareTreasuryPosting(.{ .hq = hq }, .{ .day = gs.clock.day_index, .amount = -price, .category = .unit_purchase, .hq = hq, .note = listing.item_key });
    const log = try gs.prepareLog(.market, .{ .hq = hq }, "[market] bought {s} ({s}) for {d}{s}", .{ listing.item_key, if (listing.condition) |condition| condition.label() else "new", price, if (berth_kind != null) " — berthed here" else "" });

    gs.commitTreasuryPosting(posting);
    const current = &gs.market_listings.items[index];
    if (listing.staple and current.quantity > 1) current.quantity -= 1 else _ = gs.market_listings.orderedRemove(index);
    const uid = gs.commitPreparedUnit(prepared_unit);
    const bought = gs.unit(uid).?;
    bought.hull_instance_id = listing.hull_instance_id;
    if (berth_kind != null) bought.berth_hq = hq;
    gs.commitHullTransfer(transfer);
    gs.commitLog(log);
    return .{ .unit = uid };
}

/// Buy a listing from the selected market board.
pub fn buyListing(gs: *GameState, index: usize, buyer: types.Site) !BuyResult {
    if (index >= gs.market_listings.items.len) return error.NoSuchListing;
    const listing = gs.market_listings.items[index];
    if (!listingOnBoard(gs, listing, buyer)) return error.NoSuchListing;
    const price = types.applyBp(listing.price, gs.diff().purchase_bp); // difficulty
    const selected_hq = switch (buyer) {
        .hq => |hq| hq,
        else => .none,
    };
    const selected_company = switch (buyer) {
        .company => |company| company,
        else => .none,
    };
    if (listing.black_market and listing.planet_key.len > 0 and listing.hull_instance_id != .none and selected_hq != .none) {
        return buyDispersedListingAtHq(gs, index, listing, price, selected_hq);
    }
    // The contract world's board: the company buys where it
    // stands, from its local funds, and the hull joins it there.
    if (selected_company != .none) {
        const c = gs.deploymentContract(selected_company) orelse return error.NoSuchListing;
        const co = selected_company;
        if (c.status != .active) return error.NoSuchListing;
        if (gs.treasuryBalance(.{ .company = co }) < price) return error.CompanyFundsShort;
        if (listing.company != .none) {
            if (listing.kind == .part) {
                const stock = gs.stockMap(.{ .company = co }) orelse return error.NoSuchListing;
                _ = std.math.add(u32, gs.stockCount(.{ .company = co }, listing.item_key), listing.quantity) catch return error.StockOverflow;
                try stock.ensureUnusedCapacity(gs.allocator(), 1);
                const posting = try gs.prepareTreasuryPosting(.{ .company = co }, .{
                    .day = gs.clock.day_index,
                    .amount = -price,
                    .category = .parts,
                    .company = co,
                    .contract = c.id,
                    .note = listing.item_key,
                });
                const log = try gs.prepareLog(.market, .{ .company = co, .contract = c.id }, "[market] {s} bought {d} × {s} on {s} for {d} from local funds", .{
                    if (gs.force(co)) |f| f.name else "company", listing.quantity, listing.item_key, c.planet_key, price,
                });
                gs.commitTreasuryPosting(posting);
                _ = gs.market_listings.orderedRemove(index);
                try gs.addStock(.{ .company = co }, listing.item_key, listing.quantity);
                gs.commitLog(log);
                return .{};
            }
            return buyContractWorldHull(gs, index, listing, price, co, c);
        }
        const world = planet.find(listing.planet_key) orelse return error.NoSuchListing;
        if (listing.hull_instance_id == .none) return error.NoSuchListing;
        const bm = tuning.market;
        var staged_rng = gs.rng;
        const roll = staged_rng.roll2d6(.market);
        const fraud = roll <= bm.black_market_fraud_target;
        const posting = try gs.prepareTreasuryPosting(.{ .company = co }, .{
            .day = gs.clock.day_index,
            .amount = -price,
            .category = .unit_purchase,
            .company = co,
            .contract = c.id,
            .note = listing.item_key,
        });
        const house_change = if (!std.mem.eql(u8, world.faction, "PER"))
            try gs.prepareStandingAdjustment(world.faction, if (fraud) -bm.black_market_standing_loss else -1)
        else
            null;
        const pirate_change = if (fraud) null else try gs.prepareStandingAdjustment("PER", 1);
        const hull_return = if (fraud)
            try gs.prepareMarketHullReturn(listing.hull_instance_id)
        else
            null;
        var prepared_unit: ?GameState.PreparedUnit = null;
        const hull_transfer = if (!fraud)
            try gs.prepareHullTransfer(listing.hull_instance_id, .player, "market", .salvage)
        else
            null;
        if (!fraud) {
            var unit = try gs.prepareUnit(listing.item_key);
            if (listing.condition) |cond| market.applyHullCondition(&unit.unit, cond, staged_rng.random(.market));
            prepared_unit = unit;
            var forces = gs.forces.iterator();
            while (forces.next()) |entry| try entry.value_ptr.units.ensureUnusedCapacity(gs.allocator(), 1);
        }
        const house_now = if (house_change) |change| change.value else 0;
        const pirate_now = if (pirate_change) |change| change.value else 0;
        const log = if (fraud)
            try gs.prepareLog(.market, .{ .company = co, .contract = c.id }, "[black market] the fence vanished with {s} c-bills — no {s} (2d6 = {d}); {s} standing −{d} → {d}", .{ try types.moneyText(gs.allocator(), price), listing.item_key, roll, world.faction, bm.black_market_standing_loss, house_now })
        else
            try gs.prepareLog(.market, .{ .company = co, .contract = c.id }, "[black market] {s} changed hands for {s} c-bills, no questions asked — {s} standing −1 → {d}, pirates +1 → {d}", .{ listing.item_key, try types.moneyText(gs.allocator(), price), world.faction, house_now, pirate_now });

        // Every allocation and formatted entry is owned before money, the listing,
        // standings, or the hull can change.
        gs.commitTreasuryPosting(posting);
        gs.rng = staged_rng;
        _ = gs.market_listings.orderedRemove(index);
        if (house_change) |change| gs.commitStandingAdjustment(change);
        if (pirate_change) |change| gs.commitStandingAdjustment(change);
        gs.commitLog(log);
        if (fraud) {
            if (hull_return) |prepared| gs.commitMarketHullReturn(prepared);
            return .{ .fraud = true };
        }
        const uid = gs.commitPreparedUnit(prepared_unit.?);
        const bought_co = gs.unit(uid).?;
        bought_co.hull_instance_id = listing.hull_instance_id;
        gs.commitHullTransfer(hull_transfer.?);
        try toe.placeUnitInCompanyPool(gs, uid, co);
        return .{ .unit = uid };
    }
    // The board's own HQ pays and receives.
    const hq_id = selected_hq;
    // Transports need a berth at the board's HQ.
    var berth_kind: ?unit_mod.UnitKind = null;
    if (listing.kind == .unit) if (chassis_mod.find(listing.item_key)) |design| if (design.kind.isTransport()) {
        const h = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
        const cap = h.capacity();
        const berths: u32 = if (design.kind == .dropship) cap.dropship_berths else cap.jumpship_berths;
        if (lift_mod.transportsBerthedAt(gs, hq_id, design.kind) >= berths) return error.NoBerth;
        berth_kind = design.kind;
    };
    if (gs.treasuryBalance(.{ .hq = hq_id }) < price) return error.HqTreasuryShort;
    if (listing.kind == .unit and !listing.black_market and listing.hull_instance_id == .none) {
        return buyAbstractionHullAtHq(gs, index, listing, price, hq_id, berth_kind);
    }
    if (listing.kind == .unit and !listing.black_market and listing.hull_instance_id != .none) {
        return buyExistingHullAtHq(gs, index, listing, price, hq_id, berth_kind);
    }
    if (listing.kind == .unit and listing.black_market) {
        if (listing.planet_key.len > 0) return buyDispersedListingAtHq(gs, index, listing, price, hq_id);
        const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
        const world = planet.find(hq.planet_key) orelse return error.NoSuchListing;
        var local_listing = listing;
        local_listing.planet_key = world.key;
        return buyDispersedListingAtHq(gs, index, local_listing, price, hq_id);
    }
    try treasury.debit(gs, .{ .hq = hq_id }, .{
        .day = gs.clock.day_index,
        .amount = -price,
        .category = if (listing.kind == .unit) .unit_purchase else .parts,
        .hq = hq_id,
        .note = if (listing.black_market) "black market" else listing.item_key,
    });
    // Off the books: the fence may vanish with the money, and
    // the house notices either way; the pirates approve.
    if (listing.black_market) {
        const bm = tuning.market;
        const world_faction: []const u8 = if (gs.hqs.getPtr(hq_id)) |h| (if (planet.find(h.planet_key)) |w| w.faction else "PER") else "PER";
        const roll = gs.rng.roll2d6(.market);
        _ = gs.market_listings.orderedRemove(index);
        if (roll <= bm.black_market_fraud_target) {
            if (listing.planet_key.len > 0 and listing.hull_instance_id != .none) try gs.returnMarketHullToFaction(listing.hull_instance_id);
            const now = if (!std.mem.eql(u8, world_faction, "PER")) try gs.adjustStanding(world_faction, -bm.black_market_standing_loss) else 0;
            try gs.log(.market, .{ .hq = hq_id }, "[black market] the fence vanished with {s} c-bills — no {s} (2d6 = {d}); {s} standing −{d} → {d}", .{ try types.moneyText(gs.allocator(), price), listing.item_key, roll, world_faction, bm.black_market_standing_loss, now });
            return .{ .fraud = true };
        }
        const house_now = if (!std.mem.eql(u8, world_faction, "PER")) try gs.adjustStanding(world_faction, -1) else 0;
        const pirate_now = try gs.adjustStanding("PER", 1);
        try gs.log(.market, .{ .hq = hq_id }, "[black market] {s} changed hands for {s} c-bills, no questions asked — {s} standing −1 → {d}, pirates +1 → {d}", .{ listing.item_key, try types.moneyText(gs.allocator(), price), world_faction, house_now, pirate_now });
        switch (listing.kind) {
            .unit => {
                const uid = try gs.addUnit(listing.item_key);
                const bought_bm = gs.unit(uid).?;
                if (listing.hull_instance_id != .none) {
                    bought_bm.hull_instance_id = listing.hull_instance_id;
                    try gs.transferHullOwnership(listing.hull_instance_id, .player, "market", .salvage);
                } else {
                    if (listing.condition) |cond| market.applyHullCondition(bought_bm, cond, gs.rng.random(.market));
                    try gs.recordHullAcquisition(bought_bm, .purchase, "unknown");
                }
                return .{ .unit = uid };
            },
            .part => try gs.addStock(.{ .hq = hq_id }, listing.item_key, listing.quantity),
        }
        return .{};
    }
    switch (listing.kind) {
        .unit => {
            // Staple hull lines (support trucks) sell one at a time.
            const l = &gs.market_listings.items[index];
            if (listing.staple and l.quantity > 1) l.quantity -= 1 else _ = gs.market_listings.orderedRemove(index);
            const uid = try gs.addUnit(listing.item_key);
            const bought_hq = gs.unit(uid).?;
            if (listing.hull_instance_id != .none) {
                // Surplus listing: a real HullInstance already exists — link it and
                // transfer ownership market → player (pattern from takeSalvage).
                // Condition and acquisition record are on the pre-existing instance.
                bought_hq.hull_instance_id = listing.hull_instance_id;
                try gs.transferHullOwnership(listing.hull_instance_id, .player, "market", .salvage);
            } else {
                // Abstraction-path listing: no pre-existing instance; apply condition
                // and record acquisition as usual.
                if (listing.condition) |cond| market.applyHullCondition(bought_hq, cond, gs.rng.random(.market));
                try gs.recordHullAcquisition(bought_hq, .purchase, "unknown");
            }
            if (berth_kind != null) bought_hq.berth_hq = hq_id;
            try gs.log(.market, .{ .hq = hq_id }, "[market] bought {s} ({s}) for {d}{s}", .{
                listing.item_key, if (listing.condition) |c| c.label() else "new", price,
                if (berth_kind != null) " — berthed here" else "",
            });
            return .{ .unit = uid };
        },
        .part => {
            // Staple lines sell by the unit and stay listed until empty.
            try gs.addStock(.{ .hq = hq_id }, listing.item_key, 1);
            const l = &gs.market_listings.items[index];
            if (l.quantity > 1) l.quantity -= 1 else _ = gs.market_listings.orderedRemove(index);
        },
    }
    return .{};
}

/// Buy a hull listing for a specific company.
pub fn buyHullFor(gs: *GameState, listing: usize, company: types.ForceId, lance: types.ForceId) !BuyResult {
    const dest = gs.force(company) orelse return error.UnknownForce;
    if (dest.echelon != .company) return error.NotACompany;
    if (listing >= gs.market_listings.items.len) return error.NoSuchListing;
    const l = gs.market_listings.items[listing];
    if (l.kind != .unit or l.company != .none) return error.NoSuchListing;
    const board_hq: types.HqId = if (l.hq != .none) l.hq else gs.seat();
    const home = gs.homeHqFor(company);
    const from = if (gs.hqs.getPtr(board_hq)) |h| planet.find(h.planet_key) else null;
    const to = if (gs.hqs.getPtr(home)) |h| planet.find(h.planet_key) else null;
    const days: u32 = if (from != null and to != null) logistics.deliveryDays(from.?, to.?) else 0;
    const lance_ok = if (gs.force(lance)) |lf| (gs.companyOf(lance) == company and (lf.echelon != .lance or lf.units.items.len < force_mod.lance_size)) else false;
    const raise_log = if (days == 0)
        try gs.prepareLog(.market, .{ .company = company }, "[raise] {s} #{d} joins {s}", .{ l.item_key, gs.next_unit_id, dest.name })
    else
        try gs.prepareLog(.market, .{ .company = company }, "[raise] {s} #{d} bought at {s} — {d} days to {s}", .{ l.item_key, gs.next_unit_id, gs.hqs.getPtr(board_hq).?.name, days, dest.name });
    if (days == 0) {
        if (lance_ok) {
            try gs.force(lance).?.units.ensureUnusedCapacity(gs.allocator(), 1);
        } else {
            // placeUnitInCompany may select any eligible child force based on the
            // purchased hull's kind, so reserve every possible destination first.
            try dest.units.ensureUnusedCapacity(gs.allocator(), 1);
            for (dest.children.items) |child| try gs.force(child).?.units.ensureUnusedCapacity(gs.allocator(), 1);
        }
    } else try gs.unit_transfers.ensureUnusedCapacity(gs.allocator(), 1);
    // A defrauded purchase creates no hull and returns none: there is
    // nothing to place.
    const buy_res = try buyListing(gs, listing, .{ .hq = board_hq });
    const uid = buy_res.unit;
    if (uid == .none) return .{ .fraud = buy_res.fraud };
    if (days == 0) {
        if (lance_ok) toe.moveUnitToForce(gs, uid, lance) catch unreachable else toe.placeUnitInCompany(gs, uid, company) catch unreachable;
    } else {
        const u = gs.unit(uid).?;
        u.status = .in_transit;
        gs.unit_transfers.appendAssumeCapacity(.{ .unit = uid, .to_company = company, .eta_day = gs.clock.day_index + days });
    }
    gs.commitLog(raise_log);
    return .{ .unit = uid, .eta_days = days };
}

/// Buy one support hull of a kind off the company's home board.
pub fn buySupportHull(gs: *GameState, company: types.ForceId, kind: force_mod.SupportLanceKind) !BuyResult {
    const f = gs.force(company) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;
    const home = gs.homeHqFor(company);
    const key = kind.hullKey();
    var idx: ?usize = null;
    for (gs.market_listings.items, 0..) |li, i| if (li.kind == .unit and li.staple and li.hq == home and std.mem.eql(u8, li.item_key, key)) {
        idx = i;
    };
    const listing = idx orelse return error.StapleOffBoard;
    const sl: types.ForceId = if (toe.supportLance(gs, company, kind)) |sl2| sl2.id else .none;
    return buyHullFor(gs, listing, company, sl);
}

/// Hire a candidate off the hall board; returns the new PersonId.
pub fn hireCandidate(gs: *GameState, index: usize) !types.PersonId {
    // -- validate --
    if (index >= gs.candidates.items.len) return error.NoSuchCandidate;
    const cand = gs.candidates.items[index];
    if (cand.asking_bonus > 0 and gs.treasuryBalance(.outfit) < cand.asking_bonus)
        return error.InsufficientTreasury;

    // -- prepare: reserve the ledger slot for the debit before any mutation --
    if (cand.asking_bonus > 0) try gs.reserveLedger(1);

    // -- commit: atomic hire first, then guaranteed debit, then hall removal --
    const id = try personnel.hireFromSpec(gs, cand.spec);
    if (cand.asking_bonus > 0) {
        gs.ledger.transactions.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .amount = -cand.asking_bonus,
            .category = .payroll,
            .note = "signing bonus",
        });
        gs.funds -= cand.asking_bonus;
    }
    _ = gs.candidates.orderedRemove(index);
    return id;
}

/// First matching candidate at one actual HQ, in stable hall order.
/// Source: artillery operations design, Crew and personnel policy.
pub fn hallCandidateFor(gs: *const GameState, role: person_mod.Role, hq: types.HqId) ?usize {
    for (gs.candidates.items, 0..) |c, i| if (c.hq == hq and c.spec.role == role) return i;
    return null;
}

/// Hire only from the company's actual home HQ hall; no remote candidate grant.
pub fn hireRoleFromHall(gs: *GameState, role: person_mod.Role, company: types.ForceId) !bool {
    const index = hallCandidateFor(gs, role, gs.homeHqFor(company)) orelse return false;
    const id = try hireCandidate(gs, index);
    gs.person(id).?.assigned_force = company;
    return true;
}

test "hireCandidate leaves funds, people and the hall unchanged when the hire allocation fails" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 4401 });
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    gs.funds = 10_000_000;
    try gs.candidates.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_candidate_id),
        .hq = gs.seat(),
        .spec = person_gen.generate(&gs.rng, .market, .mekwarrior),
        .asking_bonus = 500_000,
        .listed_day = 0,
        .expires_day = 400,
    });
    gs.next_candidate_id += 1;

    // Pre-reserve exactly one spare ledger slot so reserveLedger succeeds
    // but the hire's own alloc (name dupe) fires the OOM.
    try gs.ledger.transactions.ensureTotalCapacityPrecise(gs.allocator(), gs.ledger.transactions.items.len + 1);

    const before = digest.stateHash(&gs);

    // Block all further allocations.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, hireCandidate(&gs, 0));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "a veteran five-lance opposition pays more than a green four-lance one" {
    const hard = threatPayBp(.planetary_assault, 5, .veteran, 4_500);
    const soft = threatPayBp(.planetary_assault, 4, .green, 3_500);
    try std.testing.expect(hard > 10_000);
    try std.testing.expect(soft < 10_000);
    try std.testing.expect(hard <= 10_000 + tuning.contract.threat_pay_cap_bp);
    try std.testing.expect(soft >= 10_000 - tuning.contract.threat_pay_cap_bp);
    // The norm itself pays as tuned.
    const norm = threatPayBp(.objective_raid, 3, .regular, tuning.contract.reference_lance_bv);
    try std.testing.expect(norm >= 9_900 and norm <= 10_100);
}

test "a black-market buy is a fraud or a sale, and the house notices either way" {
    const planet_mod = @import("../domain/planet.zig");
    var fraud = false;
    var sale = false;
    var seed: u64 = 1;
    while ((!fraud or !sale) and seed < 60) : (seed += 1) {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
        const hq = gs.seat();
        gs.hqs.getPtr(hq).?.funds = 100_000_000;
        const faction = planet_mod.find(gs.hqs.getPtr(hq).?.planet_key).?.faction;
        const standing_before = gs.standing(faction);
        const pirates_before = gs.standing("PER");
        const len_before = gs.market_listings.items.len;
        const new_lid: types.ListingId = @enumFromInt(gs.next_listing_id);
        try gs.market_listings.append(gs.allocator(), .{ .id = new_lid, .kind = .part, .item_key = "ppc", .rarity = .uncommon, .price = 600_000, .hq = hq, .listed_day = 0, .expires_day = 10, .black_market = true });
        gs.next_listing_id += 1;
        const before = gs.stockCount(.{ .hq = hq }, "ppc");
        const funds = gs.hqs.getPtr(hq).?.funds;
        const res = try commands.execute(&gs, .{ .buy_listing = .{ .listing = new_lid, .buyer = .{ .hq = hq } } });
        try std.testing.expectEqual(funds - 600_000, gs.hqs.getPtr(hq).?.funds); // paid either way
        try std.testing.expectEqual(len_before, gs.market_listings.items.len); // the offer is gone either way
        if (gs.stockCount(.{ .hq = hq }, "ppc") == before) {
            fraud = true;
            // Result.fraud must be set so frontends can report it truthfully (rule 34).
            try std.testing.expect(res.fraud);
            try std.testing.expect(gs.standing(faction) < standing_before);
        } else {
            sale = true;
            try std.testing.expect(!res.fraud);
            try std.testing.expect(gs.standing("PER") > pirates_before);
        }
    }
    try std.testing.expect(fraud and sale);
}

test "a dispersed black-market listing requires player presence on its planet" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.seat();
    gs.hqs.getPtr(hq).?.funds = 100_000_000;
    const listing_id: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{
        .id = listing_id,
        .kind = .unit,
        .item_key = "LCT-1V",
        .rarity = .common,
        .price = 500_000,
        .black_market = true,
        .planet_key = "antallos",
    });
    gs.next_listing_id += 1;
    const funds_before = gs.hqs.getPtr(hq).?.funds;
    const listings_before = gs.market_listings.items.len;

    try std.testing.expectError(commands.Error.NoSuchListing, commands.execute(&gs, .{ .buy_listing = .{ .listing = listing_id, .buyer = .{ .hq = hq } } }));
    try std.testing.expectEqual(funds_before, gs.hqs.getPtr(hq).?.funds);
    try std.testing.expectEqual(listings_before, gs.market_listings.items.len);
}

test "a dispersed listing bought through a local HQ uses that HQ treasury" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 75 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const seat = gs.seat();
    const local: types.HqId = @enumFromInt(99);
    try gs.hqs.put(gs.allocator(), local, .{ .id = local, .name = "Local", .tier = .field, .planet_key = "canopus4", .funds = 1_000_000 });
    const listing_id: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = listing_id, .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 500_000, .black_market = true, .planet_key = "canopus4" });
    const seat_funds = gs.hqs.getPtr(seat).?.funds;
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = listing_id, .buyer = .{ .hq = local } } });
    try std.testing.expectEqual(seat_funds, gs.hqs.getPtr(seat).?.funds);
    try std.testing.expectEqual(@as(types.CBills, 500_000), gs.hqs.getPtr(local).?.funds);
    try std.testing.expectEqual(local, gs.event_log.items[gs.event_log.items.len - 1].hq);
}

fn seedDispersedHqPurchaseFixture(gs: *GameState) !types.ListingId {
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq: types.HqId = @enumFromInt(99);
    try gs.hqs.put(gs.allocator(), hq, .{ .id = hq, .name = "Local", .tier = .field, .planet_key = "canopus4", .funds = 5_000_000 });
    const hull: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hull, .{ .id = hull, .base_key = "LCT-1V", .owner = .market });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hull,
        .from_day = gs.clock.day_index,
        .acquisition_type = .transfer,
        .prior_owner_key = "MOC",
    });
    const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{
        .id = listing,
        .kind = .unit,
        .item_key = "LCT-1V",
        .rarity = .common,
        .price = 500_000,
        .black_market = true,
        .planet_key = "canopus4",
        .hull_instance_id = hull,
    });
    gs.next_listing_id += 1;
    return listing;
}

test "a failed dispersed HQ fraud purchase changes no state" {
    const digest = @import("digest.zig");
    var seed: u64 = 1;
    while (true) : (seed += 1) {
        var probe = GameState.init(std.testing.allocator, .{ .seed = seed });
        _ = try seedDispersedHqPurchaseFixture(&probe);
        var staged_rng = probe.rng;
        const fraud = staged_rng.roll2d6(.market) <= tuning.market.black_market_fraud_target;
        probe.deinit();
        if (fraud) break;
    }

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = seed });
        const listing = try seedDispersedHqPurchaseFixture(&gs);
        const before = digest.stateHash(&gs);
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();

        if (commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .hq = @enumFromInt(99) } } })) |result| {
            try std.testing.expect(result.fraud);
            try std.testing.expect(digest.stateHash(&gs) != before);
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            gs.deinit();
        }
    }
}

test "buySupportHull returns StapleOffBoard when the staple line is off the board" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // Strip the market so no MASH hull is listed — the staple is off the board.
    gs.market_listings.clearAndFree(gs.allocator());
    try std.testing.expectError(commands.Error.StapleOffBoard, commands.execute(&gs, .{ .buy_support_hull = .{ .company = co, .kind = .mash } }));
}

test "a defrauded black-market hull purchase moves no hull the outfit already owns" {
    var seed: u64 = 1;
    var checked = false;
    while (!checked and seed < 80) : (seed += 1) {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
        const alpha = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
        const hq = gs.seat();
        gs.hqs.getPtr(hq).?.funds = 100_000_000;
        // The newest hull on the books sits unassigned in the pool.
        const pooled = try gs.addUnit("WSP-1A");
        try gs.market_listings.append(gs.allocator(), .{ .id = @enumFromInt(gs.next_listing_id), .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 500_000, .hq = hq, .listed_day = 0, .expires_day = 10, .black_market = true });
        gs.next_listing_id += 1;
        const units_before = gs.units.count();
        const res = try commands.execute(&gs, .{ .buy_hull_for = .{ .listing = gs.market_listings.items.len - 1, .company = alpha, .lance = .none } });
        if (gs.units.count() != units_before) continue; // a sale; walk on to a fraud
        checked = true;
        try std.testing.expectEqual(types.UnitId.none, res.unit);
        try std.testing.expectEqual(types.ForceId.none, gs.unit(pooled).?.force);
        try std.testing.expectEqual(@as(usize, 0), gs.unit_transfers.items.len);
    }
    try std.testing.expect(checked);
}

test "buying a wreck buys a project" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .chief_engineer } });
    gs.hqs.values()[0].funds = 50_000_000;

    // Plant a wreck listing so the test is deterministic.
    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 0,
        .expires_day = 90,
        .condition = .{ .armor_pct = 12, .quality = .a, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 2 },
    });
    gs.next_listing_id += 1;
    const wreck_lid: types.ListingId = gs.market_listings.items[gs.market_listings.items.len - 1].id;
    const units_before = gs.units.count();
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = wreck_lid, .buyer = .{ .hq = gs.seat() } } });
    try std.testing.expectEqual(units_before + 1, gs.units.count());

    const u = &gs.units.values()[gs.units.count() - 1];
    try std.testing.expectEqual(@as(u8, 12), u.armor_pct);
    try std.testing.expectEqual(types.Quality.a, u.quality);
    try std.testing.expect(u.needsDepot()); // missing structure → fabricate + bay
    var destroyed: u32 = 0;
    for (u.slots.items) |s| {
        if (s.class == .weapon and s.condition == .destroyed) destroyed += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), destroyed);

    // Staples sell by the unit and stay on the board.
    var staple_lid: ?types.ListingId = null;
    var staple_array_idx: ?usize = null;
    for (gs.market_listings.items, 0..) |l, i| {
        if (l.staple and std.mem.eql(u8, l.item_key, "ammo_lrm")) {
            staple_lid = l.id;
            staple_array_idx = i;
        }
    }
    const qty = gs.market_listings.items[staple_array_idx.?].quantity;
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = staple_lid.?, .buyer = .{ .hq = gs.seat() } } });
    try std.testing.expectEqual(qty - 1, gs.market_listings.items[staple_array_idx.?].quantity);
}

test "one negotiation round per offer — improved, hardened, or withdrawn; never a second" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1233 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    try std.testing.expect(gs.contract_offers.items.len > 0);
    var improved: u32 = 0;
    var hardened: u32 = 0;
    var withdrawn: u32 = 0;
    var rounds: u32 = 0;
    while (rounds < 60) : (rounds += 1) {
        if (gs.contract_offers.items.len == 0) try refresh(&gs);
        const before = gs.contract_offers.items[0].terms;
        const offer0_id = gs.contract_offers.items[0].id;
        const r = try commands.execute(&gs, .{ .negotiate = .{ .offer = offer0_id, .term = .salvage } });
        switch (r.negotiation) {
            .improved => {
                improved += 1;
                try std.testing.expect(gs.contract_offers.items[0].terms.salvage_pct > before.salvage_pct);
                try std.testing.expectError(commands.Error.AlreadyNegotiated, commands.execute(&gs, .{ .negotiate = .{ .offer = offer0_id, .term = .pay } }));
            },
            .hardened => {
                hardened += 1;
                try std.testing.expect(gs.contract_offers.items[0].terms.base_pay_month < before.base_pay_month);
                try std.testing.expectError(commands.Error.AlreadyNegotiated, commands.execute(&gs, .{ .negotiate = .{ .offer = offer0_id, .term = .pay } }));
            },
            .withdrawn => withdrawn += 1,
            .none => unreachable,
        }
        // Clear the board so the next round sees fresh offers.
        gs.contract_offers.clearRetainingCapacity();
    }
    try std.testing.expect(improved > 0 and hardened > 0);
    // A term at its cap is refused before any dice are thrown.
    try refresh(&gs);
    gs.contract_offers.items[0].terms.advance_pct = 50;
    try std.testing.expectError(commands.Error.TermAtCap, commands.execute(&gs, .{ .negotiate = .{ .offer = gs.contract_offers.items[0].id, .term = .advance } }));
}

test "a contract-world hull purchase spends local funds and places the hull in the company pool" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1207 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const cid: types.ContractId = @enumFromInt(1207);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "hesperus_ii", .status = .active, .assigned_company = co, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
    gs.force(co).?.location_planet = "hesperus_ii";
    // Hesperus II builds meks: something turns up within a few tries.
    var tries: u32 = 0;
    var found_lid: ?types.ListingId = null;
    while (found_lid == null and tries < 20) : (tries += 1) {
        try refreshContractWorld(&gs, gs.contracts.getPtr(cid).?);
        for (gs.market_listings.items) |l| if (l.company == co) {
            found_lid = l.id;
        };
    }
    try std.testing.expect(found_lid != null);
    gs.force(co).?.local_funds = 50_000_000;
    const hq_funds = gs.hqs.values()[0].funds;
    const r = try commands.execute(&gs, .{ .buy_listing = .{ .listing = found_lid.?, .buyer = .{ .company = co } } });
    try std.testing.expectEqual(co, gs.unit(r.unit).?.force);
    var placed = false;
    for (gs.force(co).?.units.items) |unit_id| {
        if (unit_id == r.unit) placed = true;
    }
    try std.testing.expect(placed);
    try std.testing.expect(gs.force(co).?.local_funds < 50_000_000);
    try std.testing.expectEqual(hq_funds, gs.hqs.values()[0].funds);
    // Not a raise candidate, and gone with the contract at the next refresh.
    gs.contracts.getPtr(cid).?.status = .completed;
    try refreshListings(&gs);
    for (gs.market_listings.items) |l| try std.testing.expect(l.company == .none);
}

test "an insufficient-funds contract-world hull purchase leaves the complete digest unchanged" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12071 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const cid: types.ContractId = @enumFromInt(12071);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "hesperus_ii", .status = .active, .assigned_company = co, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
    const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = listing, .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 400_000, .company = co });
    gs.next_listing_id += 1;
    gs.force(co).?.local_funds = 0;
    const before = digest.stateHash(&gs);

    try std.testing.expectError(commands.Error.CompanyFundsShort, commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .company = co } } }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "a contract-world hull purchase is failure-atomic through company-pool placement" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 12072 });
        _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
        const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
        const cid: types.ContractId = @enumFromInt(12072);
        try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "hesperus_ii", .status = .active, .assigned_company = co, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
        const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
        try gs.market_listings.append(gs.allocator(), .{ .id = listing, .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 400_000, .company = co });
        gs.next_listing_id += 1;
        gs.force(co).?.local_funds = 5_000_000;
        const before = digest.stateHash(&gs);
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .company = co } } })) |result| {
            try std.testing.expectEqual(co, gs.unit(result.unit).?.force);
            try std.testing.expectEqual(result.unit, gs.force(co).?.units.items[0]);
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            gs.deinit();
        }
    }
}

test "a contract-world part purchase stocks the deployed company from local funds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1208 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const cid: types.ContractId = @enumFromInt(1208);
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "hesperus_ii", .status = .active, .assigned_company = co, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
    gs.force(co).?.location_planet = "hesperus_ii";
    const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = listing, .kind = .part, .item_key = "ammo_lrm", .rarity = .common, .price = 100, .quantity = 3, .company = co });
    gs.next_listing_id += 1;
    gs.force(co).?.local_funds = 1_000;
    const hq_funds = gs.hqs.values()[0].funds;
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .company = co } } });
    try std.testing.expectEqual(@as(u32, 3), gs.stockCount(.{ .company = co }, "ammo_lrm"));
    try std.testing.expectEqual(@as(types.CBills, 900), gs.force(co).?.local_funds);
    try std.testing.expectEqual(hq_funds, gs.hqs.values()[0].funds);
}

test "market purchases use the selected company or co-located HQ board" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1209 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const alpha = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const world = "canopus4";
    const company_hq: types.HqId = @enumFromInt(120);
    try gs.hqs.put(gs.allocator(), company_hq, .{ .id = company_hq, .name = "Company HQ", .tier = .field, .planet_key = gs.hqs.getPtr(gs.seat()).?.planet_key });
    const bravo = (try commands.execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = company_hq } })).created_force;
    try gs.contracts.put(gs.allocator(), @enumFromInt(12091), .{ .id = @enumFromInt(12091), .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = world, .status = .active, .assigned_company = alpha, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
    try gs.contracts.put(gs.allocator(), @enumFromInt(12092), .{ .id = @enumFromInt(12092), .kind = .objective_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = world, .status = .active, .assigned_company = bravo, .terms = .{ .length_months = 3, .base_pay_month = 100_000 } });
    gs.force(alpha).?.local_funds = 1_000;
    gs.force(bravo).?.local_funds = 1_000;
    const company_listing: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = company_listing, .kind = .unit, .item_key = "LCT-1V", .rarity = .common, .price = 100, .company = alpha });
    gs.next_listing_id += 1;
    const alpha_funds = gs.force(alpha).?.local_funds;
    const bravo_funds = gs.force(bravo).?.local_funds;
    try std.testing.expectError(commands.Error.NoSuchListing, commands.execute(&gs, .{ .buy_listing = .{ .listing = company_listing, .buyer = .{ .company = bravo } } }));
    try std.testing.expectEqual(alpha_funds, gs.force(alpha).?.local_funds);
    try std.testing.expectEqual(bravo_funds, gs.force(bravo).?.local_funds);
    const bought = try commands.execute(&gs, .{ .buy_listing = .{ .listing = company_listing, .buyer = .{ .company = alpha } } });
    try std.testing.expectEqual(alpha, gs.companyOf(gs.unit(bought.unit).?.force));
    try std.testing.expectEqual(alpha, gs.event_log.items[gs.event_log.items.len - 1].company);

    const first = gs.seat();
    const second: types.HqId = @enumFromInt(121);
    try gs.hqs.put(gs.allocator(), second, .{ .id = second, .name = "Second", .tier = .field, .planet_key = gs.hqs.getPtr(first).?.planet_key, .funds = 1_000 });
    gs.hqs.getPtr(first).?.funds = 1_000;
    const hq_listing: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{ .id = hq_listing, .kind = .part, .item_key = "ammo_lrm", .rarity = .common, .price = 100, .black_market = true, .planet_key = gs.hqs.getPtr(first).?.planet_key });
    gs.next_listing_id += 1;
    const first_funds = gs.hqs.getPtr(first).?.funds;
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = hq_listing, .buyer = .{ .hq = second } } });
    try std.testing.expectEqual(first_funds, gs.hqs.getPtr(first).?.funds);
    try std.testing.expectEqual(@as(types.CBills, 900), gs.hqs.getPtr(second).?.funds);
    try std.testing.expectEqual(second, gs.event_log.items[gs.event_log.items.len - 1].hq);
}

test "one board per HQ — offers inside its reach, taken only by companies based there" {
    const planet_mod = @import("../domain/planet.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1240 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const home = gs.seat();
    const alpha = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // A second base at the edge of the home ring, grown to host a company.
    const home_world = planet_mod.find(gs.hqs.getPtr(home).?.planet_key).?;
    var far_key: []const u8 = "";
    var far_dist: u32 = 0;
    for (planet_mod.catalog) |*p| {
        const d = planet_mod.distanceLy(p, home_world);
        if (d <= gs.hqs.getPtr(home).?.influenceLy() and d > far_dist) {
            far_dist = d;
            far_key = p.key;
        }
    }
    _ = try commands.execute(&gs, .{ .found_hq = .{ .name = "Far", .planet_key = far_key } });
    const far = gs.hqs.keys()[1];
    {
        const h = gs.hqs.getPtr(far).?;
        h.tier = .regional;
        try h.facilities.append(gs.allocator(), .{ .kind = hq_mod.FacilityKind.mek_bay, .level = 1 });
        h.staff_assigned = 999;
    }
    const bravo = (try commands.execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = far } })).created_force;
    try refresh(&gs);
    var on_home: u32 = 0;
    var on_far: u32 = 0;
    var far_offer: ?types.ContractId = null;
    var home_offer: ?types.ContractId = null;
    var far_offer_idx: ?usize = null;
    for (gs.contract_offers.items, 0..) |o, i| {
        const h = gs.hqs.getPtr(o.offer_hq) orelse return error.TestUnexpectedResult;
        const dist = planet_mod.distanceLy(planet_mod.find(h.planet_key).?, planet_mod.find(o.planet_key).?);
        try std.testing.expectEqual(dist, o.dist_ly);
        const market_mod = @import("../econ/market.zig");
        try std.testing.expect(dist <= h.influenceLy() + market_mod.beachhead_band_ly);
        if (o.offer_hq == home) {
            on_home += 1;
            home_offer = o.id;
        } else {
            on_far += 1;
            far_offer = o.id;
            far_offer_idx = i;
        }
    }
    try std.testing.expect(on_home > 0 and on_far > 0);
    // Alpha cannot take the far board's work; Bravo can.
    try std.testing.expect(!offerEligible(&gs, &gs.contract_offers.items[far_offer_idx.?], alpha));
    try std.testing.expectError(commands.Error.OutOfRange, commands.execute(&gs, .{ .accept_contract = .{ .offer = far_offer.?, .company = alpha } }));
    try std.testing.expectError(commands.Error.OutOfRange, commands.execute(&gs, .{ .accept_contract = .{ .offer = home_offer.?, .company = bravo } }));
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = far_offer.?, .company = bravo } });
    try std.testing.expect(gs.deploymentContract(bravo) != null);
}

test "isGreatHouse delegates to Faction.isHouse: all five houses and a periphery key agree" {
    // All five Successor States must be houses.
    for ([_][]const u8{ "LC", "DC", "FS", "CC", "FWL" }) |k| {
        try std.testing.expect(isGreatHouse(k));
        try std.testing.expect(commander.Faction.isHouse(k));
        try std.testing.expectEqual(commander.Faction.isHouse(k), isGreatHouse(k));
    }
    // A periphery faction is not a house.
    try std.testing.expect(!isGreatHouse("OWA"));
    try std.testing.expect(!commander.Faction.isHouse("OWA"));
    try std.testing.expectEqual(commander.Faction.isHouse("OWA"), isGreatHouse("OWA"));
}

test "offer ids survive removal of an earlier-indexed offer" {
    // Typed ContractId resolution must be index-independent: removing offer[0]
    // must not make the id of offer[1] unresolvable (C6f).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5050 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    try std.testing.expect(gs.contract_offers.items.len >= 2);
    // Record the second offer's id before any mutation.
    const second_id = gs.contract_offers.items[1].id;
    // Accept the first offer: it is removed from the offer list by swapRemove.
    const first_id = gs.contract_offers.items[0].id;
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = first_id, .company = co } });
    // The second offer is still addressable by its original typed id.
    try std.testing.expect(findOffer(&gs, second_id) != null);
}

test "offerBoardHq returns the offer's own HQ, not the seat (C10-B1)" {
    // Two HQs: offerBoardHq must return the offer's board HQ for each offer,
    // so negotiate reads the correct command office. Asymmetric: one offer at
    // each HQ; the two boards are distinct.
    const founding_m = @import("founding.zig");
    const planet_mod = @import("../domain/planet.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9501 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const seat = gs.seat();
    // Second HQ inside the seat's influence ring so it generates board offers.
    const seat_world = planet_mod.find(gs.hqs.getPtr(seat).?.planet_key).?;
    var near_key: []const u8 = gs.hqs.getPtr(seat).?.planet_key;
    for (planet_mod.catalog) |*p| {
        const d = planet_mod.distanceLy(p, seat_world);
        if (d > 0 and d <= gs.hqs.getPtr(seat).?.influenceLy()) {
            near_key = p.key;
            break;
        }
    }
    const second = try founding_m.foundHq(&gs, "Second", .regional, near_key);
    gs.hqs.getPtr(second).?.staff_assigned = 999;
    _ = try commands.execute(&gs, .{ .new_company_at = .{ .name = "Bravo", .hq = second } });

    try refresh(&gs);
    // Find one offer at each HQ.
    var seat_offer_idx: ?usize = null;
    var second_offer_idx: ?usize = null;
    for (gs.contract_offers.items, 0..) |o, i| {
        if (o.offer_hq == seat and seat_offer_idx == null) seat_offer_idx = i;
        if (o.offer_hq == second and second_offer_idx == null) second_offer_idx = i;
    }
    if (seat_offer_idx == null or second_offer_idx == null) return; // no offers on both boards this seed

    // offerBoardHq returns each offer's own board HQ — proving negotiate
    // reads the correct board's office, not always the seat.
    const seat_offer = &gs.contract_offers.items[seat_offer_idx.?];
    const second_offer = &gs.contract_offers.items[second_offer_idx.?];
    try std.testing.expectEqual(seat, offerBoardHq(&gs, seat_offer));
    try std.testing.expectEqual(second, offerBoardHq(&gs, second_offer));
    // The two boards are distinct (asymmetric: each offer reads a different HQ).
    try std.testing.expect(offerBoardHq(&gs, seat_offer) != offerBoardHq(&gs, second_offer));
    // A pre-schema-v24 offer with .none board falls back to the seat.
    var legacy: @import("../domain/contract.zig").Contract = second_offer.*;
    legacy.offer_hq = .none;
    try std.testing.expectEqual(seat, offerBoardHq(&gs, &legacy));
}

test "buying a hull listing creates a HullInstance and an open purchase ownership row" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .chief_engineer } });
    gs.hqs.values()[0].funds = 50_000_000;
    gs.clock.day_index = 5;

    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 0,
        .expires_day = 90,
    });
    gs.next_listing_id += 1;
    const lid = gs.market_listings.items[gs.market_listings.items.len - 1].id;
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = lid, .buyer = .{ .hq = gs.seat() } } });

    // Bought unit must have a linked instance and a purchase ownership row.
    // Faction-pool rows seeded at campaign creation (P3e.4) precede it.
    const u = &gs.units.values()[gs.units.count() - 1];
    try std.testing.expect(u.hull_instance_id != .none);
    // The purchase row is the last entry; earlier entries belong to seeded faction hulls.
    const row = gs.hull_ownership_history.items[gs.hull_ownership_history.items.len - 1];
    try std.testing.expectEqual(u.hull_instance_id, row.hull_instance_id);
    try std.testing.expectEqual(@import("../domain/hull_instance.zig").AcquisitionType.purchase, row.acquisition_type);
    try std.testing.expectEqualStrings("unknown", row.prior_owner_key);
    try std.testing.expectEqual(@as(u32, 5), row.from_day);
    try std.testing.expectEqual(@as(?u32, null), row.to_day);
}

test "a funds-short buy refusal creates no HullInstance and no ownership row" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .chief_engineer } });
    gs.hqs.values()[0].funds = 0; // guaranteed short

    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 0,
        .expires_day = 90,
    });
    gs.next_listing_id += 1;
    const lid = gs.market_listings.items[gs.market_listings.items.len - 1].id;
    // Record the hull_ownership_history count before the failed buy (includes seeded faction-pool
    // rows from P3e.4 create_commander seeding); a failed buy must add nothing.
    const before_count = gs.hull_ownership_history.items.len;
    try std.testing.expectError(error.HqTreasuryShort, commands.execute(&gs, .{ .buy_listing = .{ .listing = lid, .buyer = .{ .hq = gs.seat() } } }));
    try std.testing.expectEqual(before_count, gs.hull_ownership_history.items.len);
    // No new unit added.
    for (gs.units.values()) |u| try std.testing.expectEqual(@import("../domain/types.zig").HullInstanceId.none, u.hull_instance_id);
}

test "abstraction listing purchase is failure-atomic at every preparation boundary" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 7304 });
        _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
        const hq = gs.seat();
        gs.hqs.getPtr(hq).?.funds = 5_000_000;
        const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
        try gs.market_listings.append(gs.allocator(), .{ .id = listing, .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 400_000, .hq = hq, .condition = .{ .armor_pct = 80, .quality = .c, .damaged_slots = 0, .destroyed_slots = 0, .missing_components = 0 } });
        gs.next_listing_id += 1;
        const before = digest.stateHash(&gs);
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .hq = hq } } })) |_| {
            try std.testing.expect(digest.stateHash(&gs) != before);
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            gs.deinit();
        }
    }
}

test "real-instance listing transfer is failure-atomic" {
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = 7305 });
        _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
        const hq = gs.seat();
        gs.hqs.getPtr(hq).?.funds = 5_000_000;
        const hull: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hull, .{ .id = hull, .base_key = "SCP-1N", .owner = .market });
        try gs.hull_ownership_history.append(gs.allocator(), .{ .hull_instance_id = hull, .acquisition_type = .transfer, .prior_owner_key = "LC" });
        const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
        try gs.market_listings.append(gs.allocator(), .{ .id = listing, .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 400_000, .hq = hq, .hull_instance_id = hull });
        gs.next_listing_id += 1;
        const before = digest.stateHash(&gs);
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .hq = hq } } })) |result| {
            try std.testing.expectEqual(hull, gs.unit(result.unit).?.hull_instance_id);
            try std.testing.expectEqual(@import("../domain/hull_instance.zig").OwnerType.player, std.meta.activeTag(gs.hull_instances.getPtr(hull).?.owner));
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            gs.deinit();
        }
    }
}

test "buying a surplus listing transfers the pre-existing HullInstance to the player" {
    // A surplus listing has hull_instance_id set; buying it must link the existing
    // instance to the new unit (no fresh instance minted) and set owner to .player.
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7401 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });
    gs.hqs.values()[0].funds = 50_000_000;
    gs.clock.day_index = 5;

    // Mint a HullInstance owned by .market (as faction_surplus.runMonthly would produce).
    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hid, .{
        .id = hid,
        .base_key = "SHD-2H",
        .owner = .market,
    });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 1,
        .to_day = null,
        .acquisition_type = .transfer,
        .prior_owner_key = "LC",
    });

    // Create a surplus listing with hull_instance_id set.
    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 0,
        .expires_day = 90,
        .hull_instance_id = hid,
    });
    gs.next_listing_id += 1;
    const lid = gs.market_listings.items[gs.market_listings.items.len - 1].id;

    const unit_count_before = gs.units.count();
    _ = try commands.execute(&gs, .{ .buy_listing = .{ .listing = lid, .buyer = .{ .hq = gs.seat() } } });

    // A unit was created.
    try std.testing.expectEqual(unit_count_before + 1, gs.units.count());
    // The bought unit must be linked to the pre-existing instance (not a fresh one).
    var found_unit = false;
    for (gs.units.values()) |u| {
        if (u.hull_instance_id == hid) {
            found_unit = true;
            break;
        }
    }
    try std.testing.expect(found_unit);
    // The instance must be owned by the player.
    const inst = gs.hull_instances.getPtr(hid).?;
    try std.testing.expectEqual(hull_mod.OwnerType.player, std.meta.activeTag(inst.owner));
    // The listing must be gone.
    for (gs.market_listings.items) |l| {
        try std.testing.expect(l.id != lid);
    }
}

test "buying a dispersed black-market hull transfers its existing HullInstance on sale" {
    const hull_mod = @import("../domain/hull_instance.zig");
    var seed: u64 = 1;
    var sold = false;
    while (!sold and seed < 80) : (seed += 1) {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });
        const hq = gs.seat();
        gs.hqs.getPtr(hq).?.funds = 50_000_000;
        gs.clock.day_index = 5;

        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hid, .{ .id = hid, .base_key = "SHD-2H", .owner = .market });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = 1,
            .acquisition_type = .transfer,
            .prior_owner_key = "LC",
        });
        const listing_id: types.ListingId = @enumFromInt(gs.next_listing_id);
        try gs.market_listings.append(gs.allocator(), .{
            .id = listing_id,
            .kind = .unit,
            .item_key = "SHD-2H",
            .rarity = .common,
            .price = 900_000,
            .black_market = true,
            .planet_key = gs.hqs.getPtr(hq).?.planet_key,
            .hull_instance_id = hid,
        });
        gs.next_listing_id += 1;
        const instances_before = gs.hull_instances.count();
        const history_before = gs.hull_ownership_history.items.len;

        const result = try commands.execute(&gs, .{ .buy_listing = .{ .listing = listing_id, .buyer = .{ .hq = hq } } });
        if (result.fraud) continue;
        sold = true;
        try std.testing.expectEqual(instances_before, gs.hull_instances.count());
        try std.testing.expectEqual(hid, gs.unit(result.unit).?.hull_instance_id);
        try std.testing.expectEqual(hull_mod.OwnerType.player, std.meta.activeTag(gs.hull_instances.getPtr(hid).?.owner));
        try std.testing.expectEqual(history_before + 1, gs.hull_ownership_history.items.len);
        try std.testing.expectEqual(@as(u32, gs.clock.day_index), gs.hull_ownership_history.items[history_before - 1].to_day);
        try std.testing.expectEqual(@as(?u32, null), gs.hull_ownership_history.items[history_before].to_day);
        for (gs.market_listings.items) |listing| try std.testing.expect(listing.id != listing_id);
    }
    try std.testing.expect(sold);
}

test "surplus listing age-out returns hull to originating faction pool" {
    // An unsold surplus listing expiring during refreshListings must return
    // the hull to the faction pool (owner .faction, re-present in faction_rosters).
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7402 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });
    gs.clock.day_index = 100;

    // Mint a market-owned HullInstance.
    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hid, .{
        .id = hid,
        .base_key = "SHD-2H",
        .owner = .market,
    });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 50,
        .to_day = null,
        .acquisition_type = .transfer,
        .prior_owner_key = "LC",
    });

    // Create a surplus listing that has already expired (expires_day < day_index=100).
    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 50,
        .expires_day = 80, // expired at day 80
        .hull_instance_id = hid,
    });
    gs.next_listing_id += 1;

    try refreshListings(&gs);

    // The expired surplus listing must be gone (refreshBoard may have added new board listings).
    for (gs.market_listings.items) |l| {
        if (l.hull_instance_id == hid) {
            return error.SurplusListingNotRemoved; // must not still be present
        }
    }
    // The hull must be back in the LC faction pool.
    const inst = gs.hull_instances.getPtr(hid).?;
    try std.testing.expectEqual(hull_mod.OwnerType.faction, std.meta.activeTag(inst.owner));
    if (gs.faction_rosters.get("LC")) |roster| {
        var found = false;
        for (roster.items) |rid| if (rid == hid) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    } else {
        try std.testing.expect(false); // roster must exist
    }
}

test "a dispersed listing survives refresh until its availability window opens" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7403 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });

    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hid, .{ .id = hid, .base_key = "SHD-2H", .owner = .market });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 10,
        .acquisition_type = .transfer,
        .prior_owner_key = "LC",
    });
    const listing = black_market.makeDispersedListing(&gs, hid, @enumFromInt(gs.next_listing_id), "canopus4", 10, 7);
    try gs.market_listings.append(gs.allocator(), listing);
    gs.next_listing_id += 1;
    gs.clock.day_index = listing.available_after - 1;

    try refreshListings(&gs);

    for (gs.market_listings.items) |current| {
        if (current.id == listing.id) {
            try std.testing.expectEqual(listing.expires_day, current.expires_day);
            return;
        }
    }
    return error.DispersedListingRemovedBeforeAvailability;
}

test "a deployed company buys dispersed black-market hulls with local funds and world standing" {
    const hull_mod = @import("../domain/hull_instance.zig");
    var fraud = false;
    var sale = false;
    var seed: u64 = 1;
    while ((!fraud or !sale) and seed < 80) : (seed += 1) {
        var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer outer.deinit();
        var gs = GameState.init(outer.allocator(), .{ .seed = seed });
        defer gs.deinit();
        _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });
        const company = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
        const contract_id: types.ContractId = @enumFromInt(7403);
        try gs.contracts.put(gs.allocator(), contract_id, .{
            .id = contract_id,
            .kind = .objective_raid,
            .employer_key = "MOC",
            .enemy_key = "DC",
            .planet_key = "canopus4",
            .status = .active,
            .assigned_company = company,
            .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        });
        gs.force(company).?.location_planet = "canopus4";
        gs.force(company).?.local_funds = 5_000_000;

        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(gs.allocator(), hid, .{ .id = hid, .base_key = "LCT-1V", .owner = .market });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = 0,
            .acquisition_type = .transfer,
            .prior_owner_key = "MOC",
        });
        const listing_id: types.ListingId = @enumFromInt(gs.next_listing_id);
        try gs.market_listings.append(gs.allocator(), .{
            .id = listing_id,
            .kind = .unit,
            .item_key = "LCT-1V",
            .rarity = .common,
            .price = 500_000,
            .black_market = true,
            .planet_key = "canopus4",
            .hull_instance_id = hid,
        });
        gs.next_listing_id += 1;

        const digest = @import("digest.zig");
        const before_failure = digest.stateHash(&gs);
        const original_allocator = gs.arena.child_allocator;
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        gs.arena.child_allocator = std.testing.failing_allocator;
        try std.testing.expectError(error.OutOfMemory, commands.execute(&gs, .{ .buy_listing = .{ .listing = listing_id, .buyer = .{ .company = company } } }));
        try std.testing.expectEqual(before_failure, digest.stateHash(&gs));
        gs.arena.child_allocator = original_allocator;

        const seat_funds = gs.hqs.getPtr(gs.seat()).?.funds;
        const local_funds = gs.force(company).?.local_funds;
        const moc_standing = gs.standing("MOC");
        const pirates_standing = gs.standing("PER");
        const units_before = gs.units.count();
        const result = try commands.execute(&gs, .{ .buy_listing = .{ .listing = listing_id, .buyer = .{ .company = company } } });

        try std.testing.expectEqual(seat_funds, gs.hqs.getPtr(gs.seat()).?.funds);
        try std.testing.expectEqual(local_funds - 500_000, gs.force(company).?.local_funds);
        if (result.fraud) {
            fraud = true;
            try std.testing.expectEqual(moc_standing - tuning.market.black_market_standing_loss, gs.standing("MOC"));
            try std.testing.expectEqual(pirates_standing, gs.standing("PER"));
            try std.testing.expectEqual(units_before, gs.units.count());
            try std.testing.expectEqual(hull_mod.OwnerType.faction, std.meta.activeTag(gs.hull_instances.getPtr(hid).?.owner));
            try std.testing.expect(gs.faction_rosters.get("MOC") != null);
        } else {
            sale = true;
            try std.testing.expectEqual(moc_standing - 1, gs.standing("MOC"));
            try std.testing.expectEqual(pirates_standing + 1, gs.standing("PER"));
            try std.testing.expectEqual(units_before + 1, gs.units.count());
            try std.testing.expectEqual(company, gs.companyOf(gs.unit(result.unit).?.force));
            try std.testing.expectEqual(hull_mod.OwnerType.player, std.meta.activeTag(gs.hull_instances.getPtr(hid).?.owner));
        }
        for (gs.market_listings.items) |current| try std.testing.expect(current.id != listing_id);
    }
    try std.testing.expect(fraud and sale);
}
