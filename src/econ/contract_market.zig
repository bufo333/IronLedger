//! Contract market: monthly offer generation filtered by influence rings
//! (ARCH §9.2). Mirrors MekHQ `market/ContractMarket` with CamOps payment
//! terms; extended with per-place visibility and beachhead flagging.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const contract = @import("../domain/contract.zig");
const planet = @import("../domain/planet.zig");
const market = @import("market.zig");
const logistics = @import("logistics.zig");
const GameState = @import("../sim/state.zig").GameState;
const unit_mod = @import("../domain/unit.zig");
const hq_mod = @import("../domain/hq.zig");
const person_mod = @import("../domain/person.zig");
const person_gen = @import("../gen/person_gen.zig");

/// Employer payment multiplier by faction, basis points. // TUNE
pub fn employerMultBp(faction_key: []const u8) types.Bp {
    return @import("../domain/faction.zig").get(faction_key).pay_bp; // data/tables/factions.zon (12B.9)
}

/// Standing payment multiplier (Stage 12.21): ±25 bp per point of a
/// house's standing, so ±25% at the extremes.
pub fn standingPayBp(standing: i32) types.Bp {
    return 10_000 + @as(types.Bp, standing) * tuning.contract.standing_pay_bp_per_point;
}

/// Reputation payment multiplier: ±0.5% per point, clamped. // TUNE
/// The five Successor States (12C.7): the employers an F-rated outfit
/// cannot get in front of.
pub fn isGreatHouse(faction_key: []const u8) bool {
    const houses = [_][]const u8{ "LC", "DC", "FS", "CC", "FWL" };
    for (houses) |h| if (std.mem.eql(u8, h, faction_key)) return true;
    return false;
}

/// Employers price contracts off your operating costs with a market margin
/// on top (CamOps' negotiation environment, abstracted).
pub const market_margin_bp: types.Bp = tuning.market.market_margin_bp; // ×1.8

/// AtB-flavored contract-type roll, widened (play feedback: boards were a
/// wall of garrison duty): garrison work is still the most common single
/// kind, but every kind in the book turns up, and `refresh` caps any one
/// kind at a third of the board.
fn rollKind(gs: *GameState) contract.ContractKind {
    const roll = gs.rng.roll2d6(.market);
    const coin = gs.rng.random(.market).boolean();
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
    if (kind.isGarrisonClass() and gs.rng.random(.market).boolean()) return "PER";
    // The faction table's foes (12B.9): a house fights its neighbours.
    const foes = @import("../domain/faction.zig").get(employer).foes;
    if (foes.len == 0) return "PER";
    return foes[gs.rng.random(.market).uintLessThan(usize, foes.len)];
}

/// Best visibility of a world across all owned HQs; returns the distance to
/// the HQ that grants it.
fn bestVisibility(gs: *GameState, world: *const planet.Planet) struct { market.OfferVisibility, u32 } {
    var best: market.OfferVisibility = .hidden;
    var best_dist: u32 = std.math.maxInt(u32);
    var it = gs.hqs.iterator();
    while (it.next()) |entry| {
        const hq = entry.value_ptr;
        const hq_world = planet.find(hq.planet_key) orelse continue;
        const dist = planet.distanceLy(hq_world, world);
        const vis = market.visibilityFor(dist, hq.influenceLy());
        const better = switch (vis) {
            .in_ring => best != .in_ring,
            .beachhead => best == .hidden,
            .hidden => false,
        };
        if (better or (vis == best and dist < best_dist)) {
            best = vis;
            best_dist = dist;
        }
    }
    return .{ best, best_dist };
}

/// Regenerate the offer board (monthly, and once at campaign start).
/// Reputation reaches only as far as your rings: hidden worlds offer nothing.
pub fn refresh(gs: *GameState) !void {
    gs.contract_offers.clearRetainingCapacity();
    if (gs.hqs.count() == 0) return;

    var best_comms: u8 = 0;
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| {
        best_comms = @max(best_comms, entry.value_ptr.effectiveFacilityLevel(.comms));
    }

    // Employers price off what fielding ONE company costs per month —
    // payroll, hulls and expected maintenance consumables, spread over the
    // combat companies on the books. A contract hires one company; pricing
    // it off the whole outfit paid every company for all of them at once
    // (play feedback: 98 M in the bank after twenty years).
    const base = types.applyBp(@max(perCompanyOpsCost(gs), tuning.market.min_ops_cost), market_margin_bp);

    // The Dragoons rating (12C.7) sets how many come calling, who, and at what pay.
    const queries = @import("../sim/queries.zig");
    const rt = tuning.rating;
    const rating_idx = queries.ratingIndex(queries.ratingScore(gs));
    const offer_count = market.contractOfferCount(rating_idx, best_comms);
    var attempts: u32 = 0;
    while (gs.contract_offers.items.len < offer_count and attempts < 1000) : (attempts += 1) {
        const world = &planet.catalog[gs.rng.random(.market).uintLessThan(usize, planet.catalog.len)];
        if (!@import("../domain/faction.zig").get(world.faction).hires) continue; // ComStar posts nothing
        const vis = bestVisibility(gs, world);
        if (vis[0] == .hidden) continue;

        // Great Houses do not hire an F-rated outfit, and nobody hands
        // one a planetary assault.
        if (rating_idx < rt.house_min_index and isGreatHouse(world.faction)) continue;
        var kind = rollKind(gs);
        if (kind == .planetary_assault and rating_idx < rt.assault_min_index) kind = .garrison_duty;
        // A mix, not a wall of garrison duty (play feedback): no kind takes
        // more than a third of the board, and the garrison class — garrison,
        // cadre, security, riot: long, quiet, event-driven — no more than half,
        // so raids and assaults are always on offer.
        const kind_cap: usize = @max(2, @as(usize, offer_count) / 3);
        const class_cap: usize = @max(2, @as(usize, offer_count) / 2);
        var same: usize = 0;
        var same_class: usize = 0;
        for (gs.contract_offers.items) |o| {
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
        var pay = contract.monthlyPayment(base, kind, employerMultBp(world.faction), queries.ratingPayBp(rating_idx));
        if (vis[0] == .beachhead) pay = types.applyBp(pay, tuning.market.beachhead_pay_bp);
        // A cooling employer (Stage 9E breach): half the offers, 70% pay.
        if (gs.factionCooling(world.faction)) {
            if (gs.rng.random(.market).boolean()) continue;
            pay = types.applyBp(pay, tuning.market.cooling_pay_bp);
        }
        // Standing (12.21): a house that thinks well of you pays more and
        // one that doesn't shuns you like a cooling employer.
        const standing = gs.standing(world.faction);
        if (standing <= -tuning.contract.standing_shun_depth and gs.rng.random(.market).boolean()) continue;
        pay = types.applyBp(pay, standingPayBp(standing));
        // Command rights (12B.1): the employer pays for the reins.
        const rights: contract.CommandRights = switch (gs.rng.roll2d6(.market)) {
            2, 3, 4 => .integrated,
            5, 6, 7 => .house,
            8, 9, 10 => .liaison,
            else => .independent,
        };
        pay = types.applyBp(pay, rights.payBp());

        try gs.contract_offers.append(gs.allocator(), .{
            .id = .none, // assigned on acceptance
            .kind = kind,
            .employer_key = world.faction,
            .enemy_key = pickEnemy(gs, world.faction, kind),
            .planet_key = world.key,
            .dist_ly = vis[1],
            .beachhead = vis[0] == .beachhead,
            .terms = .{
                .length_months = length,
                .base_pay_month = pay,
                .advance_pct = 25,
                .signing_bonus = if (gs.rng.roll2d6(.market) >= 10) @divTrunc(pay, 2) else 0,
                .transport_pct = @intCast(@as(u32, gs.rng.roll2d6(.market) -| 2) * 10), // 0–100%
                // Straight support: the employer ships you supplies monthly
                // (Stage 9B delivers goods, not cash). // TUNE
                .overhead_pct = switch (gs.rng.roll2d6(.market)) {
                    2...7 => 0,
                    8, 9 => 25,
                    10, 11 => 50,
                    else => 100,
                },
                .battle_loss_pct = if (gs.rng.roll2d6(.market) >= 8) 30 else 0,
                .salvage_pct = @intCast(@as(u32, gs.rng.roll2d6(.market) -| 2) * 5), // 0–50%
                // Salvage exchange (12B.2): the employer keeps the wrecks and pays cash.
                .salvage_exchange = gs.rng.random(.market).uintLessThan(u32, tuning.contract.salvage_exchange_in) == 0,
                .command_rights = rights,
            },
        });
    }
}

/// Monthly board refresh at the HQ (ARCH §9.8, Stage 9C.3): hull listings
/// persist until bought or aged out (other buyers exist) and new hulls
/// arrive to fill the lot; staples are restocked; rare slots re-roll.
pub fn refreshListings(gs: *GameState) !void {
    const day = gs.clock.day_index;
    // Age out: expired hulls vanish; all part lines are regenerated.
    var i: usize = 0;
    while (i < gs.market_listings.items.len) {
        const l = gs.market_listings.items[i];
        if (l.kind == .part or l.expires_day <= day) {
            _ = gs.market_listings.orderedRemove(i);
        } else i += 1;
    }
    // Every HQ has a board (Stage 9D); field HQs are thin.
    var hit = gs.hqs.iterator();
    while (hit.next()) |entry| try refreshBoard(gs, entry.value_ptr.id);
}

fn refreshBoard(gs: *GameState, hq_id: types.HqId) !void {
    const hq = gs.hqs.getPtr(hq_id) orelse return;
    const world = planet.find(hq.planet_key) orelse return;
    const warehouse = hq.effectiveFacilityLevel(.warehouse);
    const day = gs.clock.day_index;
    const chassis_mod = @import("../domain/chassis.zig");
    const part_mod = @import("../domain/part.zig");
    const thin = hq.tier == .field;

    // Staples: weapons, armor, munitions, supplies — always here, priced by
    // local industry (rich worlds undercut).
    const industry_bp: types.Bp = tuning.market.staple_price_base_bp - tuning.market.staple_price_per_industry_bp * @as(types.Bp, world.industry);
    for (market.staple_keys) |key| {
        const def = part_mod.find(key) orelse continue;
        try gs.market_listings.append(gs.allocator(), .{
            .kind = .part,
            .item_key = def.key,
            .rarity = def.rarity,
            .price = types.applyBp(def.cost, if (thin) industry_bp + 2_000 else industry_bp),
            .quantity = if (thin) 5 else 20,
            .staple = true,
            .listed_day = day,
            .expires_day = day + 31,
            .hq = hq_id,
        });
    }

    // The black market (12C.17): where the hall gossips and the comms
    // reach, a fence sometimes has something off the books.
    {
        const bm = tuning.market;
        if (hq.effectiveFacilityLevel(.hiring_hall) >= 1 and hq.effectiveFacilityLevel(.comms) >= bm.black_market_comms and gs.rng.roll2d6(.market) >= bm.black_market_target) {
            const rr = gs.rng.random(.market);
            if (rr.boolean()) {
                // A rare hull, whatever house built it.
                var buf: [64]*const chassis_mod.Chassis = undefined;
                const pool = chassis_mod.ofWeightClass(if (rr.boolean()) .heavy else .assault, gs.clock.date.year, &buf);
                var pick: ?*const chassis_mod.Chassis = null;
                for (pool) |c| if (c.rarity == .rare or c.rarity == .very_rare) {
                    if (pick == null or rr.uintLessThan(u8, 3) == 0) pick = c;
                };
                if (pick) |c| try gs.market_listings.append(gs.allocator(), .{
                    .kind = .unit,
                    .item_key = c.key,
                    .rarity = c.rarity,
                    .price = types.applyBp(c.cost, bm.black_market_price_bp),
                    .hq = hq_id,
                    .listed_day = day,
                    .expires_day = day + bm.black_market_days,
                    .condition = .{ .armor_pct = @intCast(60 + rr.uintLessThan(u8, 40)), .quality = if (rr.boolean()) .c else .d, .damaged_slots = rr.uintLessThan(u8, 2), .destroyed_slots = 0, .missing_components = 0 },
                    .black_market = true,
                });
            } else {
                // A scarce part (availability D or worse).
                var pick: ?*const part_mod.PartDef = null;
                for (part_mod.catalog) |*def| if (@intFromEnum(def.availability) >= @intFromEnum(part_mod.Availability.d) and def.intro_year <= gs.clock.date.year) {
                    if (pick == null or rr.uintLessThan(u8, 3) == 0) pick = def;
                };
                if (pick) |def| try gs.market_listings.append(gs.allocator(), .{
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
            }
        }
    }

    // Rare slots: components, heavy weapons — maybe this month, maybe not.
    const rare_slots: u32 = if (thin) 1 else 2 + warehouse;
    const r = gs.rng.random(.market);
    for (0..rare_slots) |_| {
        var def = &part_mod.catalog[r.uintLessThan(usize, part_mod.catalog.len)];
        var tries: u8 = 0;
        while (def.rarity == .common and tries < 6) : (tries += 1) {
            def = &part_mod.catalog[r.uintLessThan(usize, part_mod.catalog.len)];
        }
        // Sourcing (12C.14): scarce parts, periphery shelves, comms reach.
        const src = part_mod.sourcing(def, @import("../domain/faction.zig").isPeriphery(world.faction), hq.effectiveFacilityLevel(.comms));
        if (!market.listingAppears(&gs.rng, def.rarity, world.industry, warehouse, src.total())) continue;
        const price_roll: types.Bp = 10_000 + (@as(types.Bp, gs.rng.roll2d6(.market)) - 7) * 500;
        try gs.market_listings.append(gs.allocator(), .{
            .kind = .part,
            .item_key = def.key,
            .rarity = def.rarity,
            .price = types.applyBp(def.cost, price_roll),
            .quantity = r.intRangeAtMost(u32, 1, 2),
            .listed_day = day,
            .expires_day = day + 31,
            .hq = hq_id,
        });
    }

    // Hulls: fill the lot to its size with new arrivals, each with a rolled
    // condition and a stay of 2–4 months.
    const lot_size: u32 = if (thin) 1 else 2 + warehouse;
    var hulls: u32 = 0;
    for (gs.market_listings.items) |l| {
        if (l.kind == .unit and l.hq == hq_id and !l.staple) hulls += 1;
    }
    var attempts: u32 = 0;
    while (hulls < lot_size and attempts < 12) : (attempts += 1) {
        // Meks off the local house's table (12B.8), the odd combat vehicle
        // from anywhere; fighters and ships have their own slot below.
        const design = if (r.uintLessThan(u8, 4) == 0) blk: {
            var vbuf: [32]*const chassis_mod.Chassis = undefined;
            const vehicles = chassis_mod.ofKind(.vehicle, gs.clock.date.year, &vbuf);
            if (vehicles.len == 0) continue;
            break :blk vehicles[r.uintLessThan(usize, vehicles.len)];
        } else @import("../domain/rat.zig").roll(&gs.rng, .market, world.faction, @import("../gen/company_gen.zig").rollWeightClass(&gs.rng), gs.clock.date.year);
        if (!market.listingAppears(&gs.rng, design.rarity, world.industry, warehouse, 0)) continue;
        const cond = market.rollHullCondition(&gs.rng);
        const price_roll: types.Bp = 10_000 + (@as(types.Bp, gs.rng.roll2d6(.market)) - 7) * 500;
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
            .kind = .unit,
            .item_key = design.key,
            .rarity = design.rarity,
            .price = market.hullPrice(design.cost, avg_weapon, cond, price_roll),
            .listed_day = day,
            .expires_day = day + 60 + @as(u32, gs.rng.roll2d6(.market)) * 5,
            .condition = cond,
            .hq = hq_id,
        });
        hulls += 1;
    }

    // The transport slot (Stage 12.15): a spaceport of some size sees a
    // fighter, a dropship or a jumpship for sale now and then — one
    // attempt per refresh, at the design's rarity, priced by
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
            const kind: unit_mod.UnitKind = if (port >= 4 and comms >= 3 and r.uintLessThan(u8, 3) == 0) .jumpship else if (port >= 3 and r.boolean()) .dropship else .aerospace;
            var buf: [16]*const chassis_mod.Chassis = undefined;
            const pool = chassis_mod.ofKind(kind, gs.clock.date.year, &buf);
            if (pool.len > 0) {
                const design = pool[r.uintLessThan(usize, pool.len)];
                if (market.listingAppears(&gs.rng, design.rarity, world.industry, port, 0)) {
                    const price_roll: types.Bp = 10_000 + (@as(types.Bp, gs.rng.roll2d6(.market)) - 7) * 500;
                    const base = if (design.kind == .aerospace) design.cost else types.applyBp(design.cost, market.transport_price_bp);
                    try gs.market_listings.append(gs.allocator(), .{
                        .kind = .unit,
                        .item_key = design.key,
                        .rarity = design.rarity,
                        .price = types.applyBp(base, price_roll),
                        .listed_day = day,
                        .expires_day = day + 60 + @as(u32, gs.rng.roll2d6(.market)) * 5,
                        .hq = hq_id,
                    });
                }
            }
        }
    }

    // Support vehicles are always on offer at a regional or brigade board
    // (Stage 12): trucks are how a company's field capacity grows, so they
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
                .kind = .unit,
                .item_key = design.key,
                .rarity = .common,
                .price = design.cost,
                .hq = hq_id,
                .quantity = 2,
                .staple = true,
                .listed_day = day,
                .expires_day = day + 3650,
            });
        }
    }
}

/// Who walks into a hiring hall: combat crews and techs most often, then
/// medical and every back-office desk (Stage 12: finance, command and
/// transport admins were missing, so those desks could never be filled).
const hall_roles = [_]person_mod.Role{
    .mekwarrior,    .mekwarrior,    .tech_mek,        .tech_mek,      .tech_mechanic, .vehicle_crew,
    .astech,        .astech,        .medic,           .doctor,        .admin_logistics, .admin_hr,
    .admin_finance, .admin_command, .admin_transport, .aero_pilot,    .tech_aero,     .dropship_crew,
    .jumpship_crew,
};

/// An admin desk this HQ is short on, if any — the hall favours it.
fn shortAdminRole(gs: *GameState, hq: *const hq_mod.Hq) ?person_mod.Role {
    const req = hq.staffRequired();
    const desks = [_]struct { role: person_mod.Role, need: u32 }{
        .{ .role = .admin_command, .need = req.admin },
        .{ .role = .admin_logistics, .need = req.logistics },
        .{ .role = .admin_hr, .need = req.hr },
        .{ .role = .admin_finance, .need = req.finance },
    };
    for (desks) |d| if (gs.hqStaff(hq.id, d.role).count < d.need) return d.role;
    return null;
}

/// The role the outfit is shortest of at this HQ (12B.13): a short desk
/// first, then the largest gap in the manning tables of the companies
/// supplied here (pooled roles excepted — astechs and medics are hired to
/// complement, not recruited). Word gets round: half the walk-ins are
/// people who heard the outfit is hiring that trade.
fn shortRole(gs: *GameState, hq: *const hq_mod.Hq) ?person_mod.Role {
    if (shortAdminRole(gs, hq)) |r| return r;
    const personnel = @import("../sim/personnel.zig");
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

/// Daily hiring-hall churn (Stage 9C.3): people move fast. Each turn some
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
        const hr = gs.hqStaff(hq.id, .admin_hr).count;
        const roll = @as(u32, gs.rng.roll2d6(.market)) + hall + hr / 2;
        if (roll < tuning.market.hall_arrival_target) continue; // quiet day at the hall
        // A bigger hall draws a bigger crowd: one walk-in per hall level, one
        // more on a boxcars day.
        const arrivals: u32 = hall + @as(u32, if (roll >= 12) 1 else 0);
        for (0..arrivals) |_| {
            // A short desk or trade gets every other arrival until it is staffed.
            const role = if (shortRole(gs, hq)) |short| (if (gs.rng.roll2d6(.market) >= 7) short else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)]) else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)];
            const spec = person_gen.generateWithBonus(&gs.rng, role, gs.recruitBonus());
            const salary = types.applyBp(role.baseSalary(), spec.experience.salaryMultBp());
            try gs.candidates.append(gs.allocator(), .{
                .hq = hq.id,
                .spec = spec,
                .asking_bonus = salary * (1 + @as(types.CBills, @intFromEnum(spec.experience))),
                .listed_day = day,
                .expires_day = day + 14,
            });
        }
        _ = try topUpHall(gs, hq); // 12B.10: the board never runs dry
    }
}

/// The floor under every board (12B.10, play feedback: "if people leave
/// there are not always people in the hiring hall"): a hall that dips
/// under the floor for a role gets a fresh walk-in of that role the same
/// day — combat crews and techs two deep, everyone else one.
pub fn topUpHall(gs: *GameState, hq: *const hq_mod.Hq) !u32 {
    if (hq.effectiveFacilityLevel(.hiring_hall) == 0) return 0;
    const day = gs.clock.day_index;
    var added: u32 = 0;
    inline for (@typeInfo(person_mod.Role).@"enum".fields) |f| {
        const role: person_mod.Role = @enumFromInt(f.value);
        const combat = switch (role) {
            .mekwarrior, .vehicle_crew, .aero_pilot, .tech_mek, .tech_mechanic, .tech_aero, .astech => true,
            else => false,
        };
        const floor: u32 = if (combat) tuning.market.hall_floor_combat else tuning.market.hall_floor;
        var have: u32 = 0;
        for (gs.candidates.items) |c| if (c.hq == hq.id and c.spec.role == role) {
            have += 1;
        };
        while (have < floor) : (have += 1) {
            const spec = person_gen.generateWithBonus(&gs.rng, role, gs.recruitBonus());
            const salary = types.applyBp(role.baseSalary(), spec.experience.salaryMultBp());
            try gs.candidates.append(gs.allocator(), .{
                .hq = hq.id,
                .spec = spec,
                .asking_bonus = salary * (1 + @as(types.CBills, @intFromEnum(spec.experience))),
                .listed_day = day,
                .expires_day = day + 14,
            });
            added += 1;
        }
    }
    return added;
}

/// Hiring-hall boards (Stage 9C.2): weekly candidates per HQ, count and
/// quality by hiring-hall level + HR staff; they move on after three weeks.
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
        const hr = gs.hqStaff(hq.id, .admin_hr).count;
        const count: u32 = 2 + hall + hr / 2;
        for (0..count) |_| {
            // A short desk or trade gets every other arrival until it is staffed.
            const role = if (shortRole(gs, hq)) |short| (if (gs.rng.roll2d6(.market) >= 7) short else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)]) else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)];
            const spec = person_gen.generateWithBonus(&gs.rng, role, gs.recruitBonus());
            const salary = types.applyBp(role.baseSalary(), spec.experience.salaryMultBp());
            try gs.candidates.append(gs.allocator(), .{
                .hq = hq.id,
                .spec = spec,
                .asking_bonus = salary * (1 + @as(types.CBills, @intFromEnum(spec.experience))), // TUNE
                .listed_day = day,
                .expires_day = day + 21,
            });
        }
    }
}

/// The outfit's monthly running cost divided by its combat companies: what
/// an employer reckons one company costs to keep in the field.
pub fn perCompanyOpsCost(gs: *GameState) types.CBills {
    const ops_cost = gs.monthlyPayroll() + hullUpkeep(gs) + maintenanceEstimate(gs);
    var companies: i64 = 0;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        companies += 1;
    };
    return @divTrunc(ops_cost, @max(1, companies));
}

fn hullUpkeep(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| total += entry.value_ptr.monthlyBill();
    return total;
}

/// Expected monthly maintenance consumables (~4.33 weeks × price/2500).
fn maintenanceEstimate(gs: *GameState) types.CBills {
    var total: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status == .mothballed or u.kind == .infantry) continue;
        total += @divTrunc(u.purchase_price, 600);
    }
    return total;
}

test "refresh only offers work inside rings or the beachhead band" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try gs.createCommander("Erik Kalmar", .CC, .quartermaster);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha Company");

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

test "9C.3: hulls persist across refreshes, staples are always stocked" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 19 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .quartermaster);
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

test "9C.3: hiring halls churn daily" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .DC, .paymaster);
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

test "12: every admin desk walks into the hall, short desks first" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 21 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .DC, .paymaster);
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

test "12C.7: an F-rated outfit hears only from the periphery and never gets a planetary assault" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 127 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    gs.funds = -1;
    gs.reputation = -100; // record −40, treasury −20 …
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.role.isCombat()) {
        try e.value_ptr.skills.put(gs.allocator(), e.value_ptr.role.primarySkill(), 7); // … and green as grass: firmly F
    };
    const queries = @import("../sim/queries.zig");
    try std.testing.expectEqual(@as(u8, 0), queries.ratingIndex(queries.ratingScore(&gs)));
    gs.contract_offers.clearRetainingCapacity();
    try refresh(&gs);
    for (gs.contract_offers.items) |o| {
        try std.testing.expect(!isGreatHouse(o.employer_key));
        try std.testing.expect(o.kind != .planetary_assault);
    }
    try std.testing.expectEqual(@as(types.Bp, 8_000), queries.ratingPayBp(0));
    try std.testing.expectEqual(@as(types.Bp, 13_000), queries.ratingPayBp(5));
}

test "12C.17: a wired HQ with a hall eventually hears from a fence; a firebase never does" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1217 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const hq = gs.hqs.keys()[0];
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

test "12.15: the transport slot opens with the spaceport; ordinary lots are meks only" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 21 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .quartermaster);
    const chassis_mod = @import("../domain/chassis.zig");
    // Spaceport 1: never a fighter or ship, however many refreshes.
    for (0..12) |_| {
        gs.clock.day_index += 31;
        try refreshListings(&gs);
        for (gs.market_listings.items) |l| if (l.kind == .unit) {
            const k = chassis_mod.find(l.item_key).?.kind;
            try std.testing.expect(k == .mek or k == .vehicle or l.staple);
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
                if (d.kind.isTransport()) try std.testing.expect(l.price < d.cost); // scaled by transport_price_bp
            }
        };
    }
    try std.testing.expect(seen);
}

test "12B.10: the hiring hall always has a few of every role" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1210 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .quartermaster);
    gs.candidates.clearRetainingCapacity();
    try churnCandidates(&gs);
    const hq = gs.hqs.keys()[0];
    inline for (@typeInfo(person_mod.Role).@"enum".fields) |f| {
        const role: person_mod.Role = @enumFromInt(f.value);
        var have: u32 = 0;
        for (gs.candidates.items) |c| if (c.hq == hq and c.spec.role == role) {
            have += 1;
        };
        try std.testing.expect(have >= 1);
        if (role == .mekwarrior or role == .tech_mek) try std.testing.expect(have >= 2);
    }
    // Hire every mekwarrior; tomorrow the board has two again.
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
    _ = try gs.createCommander("Erik Kalmar", .LC, .quartermaster);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha Company");
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

test "play feedback: offers are priced per company — a second company does not double every contract's pay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 96 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .quartermaster);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    const one = perCompanyOpsCost(&gs);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Bravo");
    const two = perCompanyOpsCost(&gs);
    // Two like companies: the per-company figure barely moves (HQ overhead is now shared).
    try std.testing.expect(two < one);
    try std.testing.expect(two * 10 > one * 6);
    // And the whole-outfit figure, which the price used to be built on, roughly doubled.
    const whole = gs.monthlyPayroll() + hullUpkeep(&gs) + maintenanceEstimate(&gs);
    try std.testing.expect(whole > @divTrunc(two * 18, 10));
}
