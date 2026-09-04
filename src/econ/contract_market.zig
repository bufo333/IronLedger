//! Contract market: monthly offer generation filtered by influence rings
//! (ARCH §9.2). Mirrors MekHQ `market/ContractMarket` with CamOps payment
//! terms; extended with per-place visibility and beachhead flagging.

const std = @import("std");
const types = @import("../domain/types.zig");
const contract = @import("../domain/contract.zig");
const planet = @import("../domain/planet.zig");
const market = @import("market.zig");
const logistics = @import("logistics.zig");
const GameState = @import("../sim/state.zig").GameState;
const hq_mod = @import("../domain/hq.zig");
const person_mod = @import("../domain/person.zig");
const person_gen = @import("../gen/person_gen.zig");

/// Employer payment multiplier by faction, basis points. // TUNE
pub fn employerMultBp(faction_key: []const u8) types.Bp {
    const table = [_]struct { []const u8, types.Bp }{
        .{ "LC", 10_500 }, // Lyran money is good money
        .{ "FS", 11_000 },
        .{ "DC", 10_000 },
        .{ "CC", 9_500 },
        .{ "FWL", 10_000 },
        .{ "PER", 8_000 },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row[0], faction_key)) return row[1];
    }
    return 10_000;
}

/// Reputation payment multiplier: ±0.5% per point, clamped. // TUNE
pub fn reputationMultBp(reputation: i32) types.Bp {
    return std.math.clamp(10_000 + @as(types.Bp, reputation) * 50, 8_000, 13_000);
}

/// Employers price contracts off your operating costs with a market margin
/// on top (CamOps' negotiation environment, abstracted). // TUNE
pub const market_margin_bp: types.Bp = 18_000; // ×1.8

/// AtB-flavored contract-type roll: garrison work dominates the boards.
fn rollKind(gs: *GameState) contract.ContractKind {
    return switch (gs.rng.roll2d6(.market)) {
        2 => .guerrilla_warfare,
        3 => .recon_raid,
        4 => .pirate_hunting,
        5 => .objective_raid,
        6, 7, 8 => .garrison_duty,
        9 => .cadre_duty,
        10 => .security_duty,
        11 => .riot_duty,
        else => .planetary_assault,
    };
}

fn pickEnemy(gs: *GameState, employer: []const u8, kind: contract.ContractKind) []const u8 {
    // Garrison-class work is as often about pirates as neighbors.
    if (kind.isGarrisonClass() and gs.rng.random(.market).boolean()) return "PER";
    const foes: []const []const u8 = if (std.mem.eql(u8, employer, "LC"))
        &.{ "DC", "FWL" }
    else if (std.mem.eql(u8, employer, "DC"))
        &.{ "LC", "FS" }
    else if (std.mem.eql(u8, employer, "FS"))
        &.{ "DC", "CC" }
    else if (std.mem.eql(u8, employer, "CC"))
        &.{ "FS", "FWL" }
    else if (std.mem.eql(u8, employer, "FWL"))
        &.{ "LC", "CC" }
    else
        &.{"PER"};
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

    // Employers price off what fielding your outfit costs per month:
    // payroll, hulls, and expected maintenance consumables.
    const ops_cost = gs.monthlyPayroll() + hullUpkeep(gs) + maintenanceEstimate(gs);
    const base = types.applyBp(@max(ops_cost, 50_000), market_margin_bp);

    const offer_count = market.contractOfferCount(gs.reputation, best_comms);
    var attempts: u32 = 0;
    while (gs.contract_offers.items.len < offer_count and attempts < 40) : (attempts += 1) {
        const world = &planet.catalog[gs.rng.random(.market).uintLessThan(usize, planet.catalog.len)];
        const vis = bestVisibility(gs, world);
        if (vis[0] == .hidden) continue;

        const kind = rollKind(gs);
        const length_variance: i32 = @as(i32, gs.rng.roll2d6(.market)) - 7;
        const length: u8 = @intCast(std.math.clamp(
            @as(i32, kind.baseLengthMonths()) + length_variance,
            2,
            30,
        ));

        // Beachhead employers pay a premium — nobody else will go. // TUNE
        var pay = contract.monthlyPayment(base, kind, employerMultBp(world.faction), reputationMultBp(gs.reputation));
        if (vis[0] == .beachhead) pay = types.applyBp(pay, 13_000);
        // A cooling employer (Stage 9E breach): half the offers, 70% pay.
        if (gs.factionCooling(world.faction)) {
            if (gs.rng.random(.market).boolean()) continue;
            pay = types.applyBp(pay, 7_000);
        }

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
                .command_rights = switch (gs.rng.roll2d6(.market)) {
                    2, 3, 4 => .integrated,
                    5, 6, 7 => .house,
                    8, 9, 10 => .liaison,
                    else => .independent,
                },
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
    // local industry (rich worlds undercut). // TUNE
    const industry_bp: types.Bp = 12_000 - 400 * @as(types.Bp, world.industry);
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

    // Rare slots: components, heavy weapons — maybe this month, maybe not.
    const rare_slots: u32 = if (thin) 1 else 2 + warehouse;
    const r = gs.rng.random(.market);
    for (0..rare_slots) |_| {
        var def = &part_mod.catalog[r.uintLessThan(usize, part_mod.catalog.len)];
        var tries: u8 = 0;
        while (def.rarity == .common and tries < 6) : (tries += 1) {
            def = &part_mod.catalog[r.uintLessThan(usize, part_mod.catalog.len)];
        }
        if (!market.listingAppears(&gs.rng, def.rarity, world.industry, warehouse)) continue;
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
        const design = &chassis_mod.catalog[r.uintLessThan(usize, chassis_mod.catalog.len)];
        if (!market.listingAppears(&gs.rng, design.rarity, world.industry, warehouse)) continue;
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

    // Support vehicles are always on offer at a regional or brigade board
    // (Stage 12): trucks are how a company's field capacity grows, so they
    // are a staple line, new, at list price, two at a time.
    if (!thin) {
        const support_keys = [_][]const u8{ "CGT-3", "SVT-1", "MASH-27" };
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
    .mekwarrior,    .mekwarrior,    .tech_mek,        .tech_mek, .tech_mechanic,   .vehicle_crew,
    .astech,        .astech,        .medic,           .doctor,   .admin_logistics, .admin_hr,
    .admin_finance, .admin_command, .admin_transport,
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
        if (roll < 8) continue; // quiet day at the hall // TUNE
        const arrivals: u32 = if (roll >= 12) 2 else 1;
        for (0..arrivals) |_| {
            // A short desk gets every other arrival until it is staffed.
            const role = if (shortAdminRole(gs, hq)) |short| (if (gs.rng.roll2d6(.market) >= 7) short else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)]) else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)];
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
    }
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
            // A short desk gets every other arrival until it is staffed.
            const role = if (shortAdminRole(gs, hq)) |short| (if (gs.rng.roll2d6(.market) >= 7) short else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)]) else hall_roles[gs.rng.random(.market).uintLessThan(usize, hall_roles.len)];
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

test "no HQ, no reputation, no offers" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6 });
    defer gs.deinit();
    try refresh(&gs);
    try std.testing.expectEqual(@as(usize, 0), gs.contract_offers.items.len);
}
