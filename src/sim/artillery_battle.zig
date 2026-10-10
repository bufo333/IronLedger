//! Physical artillery participation and staged engagement effects.
//! No MekHQ numerical counterpart: docs/p2-artillery-battle-design.md owns policy.

const std = @import("std");
const types = @import("../domain/types.zig");
const rules = @import("../domain/artillery_combat.zig");
const slots = @import("../domain/artillery_operations.zig");
const formation = @import("../domain/artillery_formation.zig");
const catalogue = @import("../domain/artillery_catalogue.zig");
const report = @import("../domain/battle_report.zig");
const autoresolve = @import("../domain/autoresolve.zig");
const contract = @import("../domain/contract.zig");
const scenario = @import("../domain/scenario.zig");
const force = @import("../domain/force.zig");
const tuning = @import("../domain/tuning.zig").t;
const GameState = @import("state.zig").GameState;
const artillery = @import("artillery.zig");
const operations = @import("artillery_operations.zig");
const crew = @import("artillery_crew.zig");
const sites = @import("sites.zig");
const casualties = @import("battle_casualties.zig");
const recovery = @import("battle_recovery.zig");
const personnel = @import("personnel.zig");

/// Physical participation excludes every transit/pool/remote/terminal state but
/// includes a physically deployed carrier with a queued job. Source: combat design.
pub fn physicallyPresent(gs: *GameState, f: *const formation.Formation, c: *const contract.Contract) bool {
    if (f.placement != .company or f.placement.company != c.assigned_company) return false;
    const site = operations.operationSite(gs, f) orelse return false;
    const world = sites.sitePlanetKey(gs, site) orelse return false;
    return std.mem.eql(u8, world, c.planet_key);
}

/// Capture the company's attachment and operating identities before casualties
/// clear seats. Absent attachment is null; physical presence is independent of fire.
pub fn snapshot(gs: *GameState, c: *const contract.Contract, no_fire: rules.NoFire) !?report.ArtilleryResult {
    for (gs.artillery_formations.values()) |*f| {
        if (f.placement != .company or f.placement.company != c.assigned_company) continue;
        const present = physicallyPresent(gs, f, c);
        var result: report.ArtilleryResult = .{
            .formation = f.id,
            .hull = f.hull,
            .catalogue_key = artillery.carrier().key,
            .catalogue_name = artillery.carrier().name,
            .physical_participation = present,
            .readiness = if (present) operations.readinessBlock(gs, f) else .not_present,
            .no_fire = no_fire,
            .slots_before = f.slots,
            .slots_after = f.slots,
            .rounds_before = rules.loadedRounds(&f.slots),
            .rounds_after = rules.loadedRounds(&f.slots),
            .armor_before = f.armor_pct,
            .armor_after = f.armor_pct,
        };
        const site = operations.operationSite(gs, f);
        for (&result.seats, slots.seats, f.crew) |*row, seat, id| {
            row.* = .{ .seat = seat, .person = id };
            if (gs.person(id)) |p| {
                row.name = try p.rankedName(gs.allocator());
                row.present = present and p.isOnBooks() and site != null and crew.personPresent(gs, p, site.?);
            }
        }
        return result;
    }
    return null;
}

/// Pure ready-carrier power, using existing skill/condition/quality ownership.
/// Source: combat design, Participation and firing. No RNG, stock or IDs consumed.
pub fn effectivePower(gs: *GameState, f: *const formation.Formation) ?i64 {
    if (!operations.operationalReadiness(gs, f)) return null;
    const gunner = gs.person(f.crew[@intFromEnum(slots.Seat.gunner)]) orelse return null;
    const driver = gs.person(f.crew[@intFromEnum(slots.Seat.driver)]) orelse return null;
    var fatigue: u32 = 0;
    var morale: u32 = 0;
    for (f.crew) |id| {
        const p = gs.person(id) orelse return null;
        fatigue += p.fatigue;
        morale += p.morale;
    }
    const element: autoresolve.Element = .{
        .base_strength = (catalogue.calculated(artillery.carrier()) catch unreachable).bv,
        .avg_gunnery = autoresolve.effectiveCrewSkill(gunner, gunner.skill(.gunnery_vee).?, false),
        .avg_piloting = autoresolve.effectiveCrewSkill(driver, driver.skill(.driving_vee).?, true),
        .avg_condition_pct = f.armor_pct,
        .avg_quality = f.quality,
    };
    return element.effectivePower(.{ .avg_fatigue = @intCast(fatigue / slots.crew_count), .avg_morale = @intCast(morale / slots.crew_count) });
}

pub const Preview = struct { target: u8, maximum_reduction: i64 };

/// Pure maximum possible opening reduction; accuracy remains uncertain.
/// Source: combat design, Participation and firing. Uses actual contract locality.
pub fn preview(gs: *GameState, c: *const contract.Contract, recon: u8, enemy_power: i64) ?Preview {
    for (gs.artillery_formations.values()) |*f| {
        if (!physicallyPresent(gs, f, c)) continue;
        const power = effectivePower(gs, f) orelse return null;
        const gunner = gs.person(f.crew[@intFromEnum(slots.Seat.gunner)]).?;
        return .{ .target = rules.firingTarget(autoresolve.effectiveCrewSkill(gunner, gunner.skill(.gunnery_vee).?, false), recon), .maximum_reduction = rules.suppressedPower(enemy_power, power) };
    }
    return null;
}

/// Spend one loaded salvo and one battle-stream accuracy roll before the opposed
/// roll. Source: combat design. Suppression is temporary power, never destroyed BV.
pub fn fire(gs: *GameState, result: *?report.ArtilleryResult, recon: u8, enemy_power: i64) i64 {
    const r = if (result.*) |*value| value else return enemy_power;
    r.enemy_power_before = enemy_power;
    r.enemy_power_after = enemy_power;
    if (!r.physical_participation) {
        r.no_fire = .not_present;
        return enemy_power;
    }
    if (r.readiness != null) {
        r.no_fire = .not_ready;
        return enemy_power;
    }
    if (enemy_power <= 0) {
        r.no_fire = .zero_enemy_power;
        return enemy_power;
    }
    const f = gs.artillery_formations.getPtr(r.formation).?;
    const power = effectivePower(gs, f).?;
    const gunner = gs.person(f.crew[@intFromEnum(slots.Seat.gunner)]).?;
    r.target = rules.firingTarget(autoresolve.effectiveCrewSkill(gunner, gunner.skill(.gunnery_vee).?, false), recon);
    r.carrier_power = power;
    _ = rules.spendRound(&f.slots, .long_tom) orelse unreachable;
    r.fired_rounds[@intFromEnum(slots.Family.long_tom)] = rules.salvo_rounds;
    r.accuracy_roll = gs.rng.roll2d6(.battle);
    r.fire = if (r.accuracy_roll.? >= r.target.?) .hit else .miss;
    r.no_fire = .none;
    r.suppressed_power = if (r.fire == .hit) rules.suppressedPower(enemy_power, power) else 0;
    r.enemy_power_after = enemy_power - r.suppressed_power;
    return r.enemy_power_after.?;
}

pub const Loss = struct { wounded: u8 = 0, kia: u8 = 0, destroyed: u8 = 0, lost: u32 = 0, missing: u32 = 0 };

fn wrecked(f: *const formation.Formation) bool {
    return f.armor_pct == 0 and f.slots[@intFromEnum(slots.Slot.chassis)].condition == .destroyed;
}

/// One exposed-carrier hit after ordinary hits; canonical slot and present-seat
/// draws precede the shared casualty owner. Source: combat design, Carrier exposure.
pub fn applyExposure(gs: *GameState, result: *?report.ArtilleryResult, hit_pct: u32, has_mash: bool) !Loss {
    const r = if (result.*) |*value| value else return .{};
    if (!r.physical_participation) return .{};
    const f = gs.artillery_formations.getPtr(r.formation).?;
    const was_wrecked = wrecked(f);
    r.damage = if (was_wrecked) .recoverable else .unhit;
    if (operations.defensiveReadiness(gs, f)) r.fired_rounds[@intFromEnum(slots.Family.machine_gun)] = rules.defensiveFire(&f.slots, hit_pct);
    r.exposure_percent = rules.exposurePercent(hit_pct, r.fired_rounds[@intFromEnum(slots.Family.machine_gun)]);
    if (r.exposure_percent.? == 0) return .{};
    r.exposure_roll = gs.rng.random(.battle).uintLessThan(u8, @intCast(rules.percent_scale));
    if (r.exposure_roll.? >= r.exposure_percent.?) return .{};
    const severity = gs.rng.roll2d6(.battle);
    r.severity = severity;
    if (severity >= tuning.battle.slot_hit_severity) r.struck_slot = slots.descriptors[gs.rng.random(.battle).uintLessThan(usize, slots.descriptors.len)].slot;
    const hit = rules.carrierHit(f.armor_pct, f.slots, severity, r.struck_slot);
    f.armor_pct = hit.armor_pct;
    f.slots = hit.slots;
    var loss: Loss = .{};
    r.damage = .damaged;
    if (hit.wrecked) {
        r.newly_wrecked = !was_wrecked;
        r.cause = hit.cause;
        r.damage = if (hit.terminal) .permanently_destroyed else .recoverable;
        loss.destroyed = @intFromBool(r.newly_wrecked);
        gs.stats.hulls_lost += loss.destroyed;
    }
    var candidates: [slots.seats.len]usize = undefined;
    var count: usize = 0;
    for (r.seats, 0..) |seat, index| {
        const p = gs.person(seat.person) orelse continue;
        if (seat.present and p.isOnBooks()) {
            candidates[count] = index;
            count += 1;
        }
    }
    if (count > 0) {
        const index = candidates[gs.rng.random(.battle).uintLessThan(usize, count)];
        r.struck_seat = r.seats[index].seat;
        const casualty = try casualties.apply(gs, r.seats[index].person, severity, has_mash);
        r.seats[index].outcome = casualty.outcome;
        loss.wounded = casualty.wounded;
        loss.kia = casualty.kia;
    }
    return loss;
}

/// Combined recovery counts ordinary and carrier wrecks once. Lost-field terminal
/// crew escape follows conventional recovery, in canonical seat order. Source: combat design.
pub fn recover(gs: *GameState, result: *?report.ArtilleryResult, c: *const contract.Contract, battle_scenario: *const scenario.Scenario, outcome: autoresolve.Outcome, roe: force.Roe, held_field: bool, has_salvage: bool, trucks: i64, combined_wrecks: i64) !Loss {
    const r = if (result.*) |*value| value else return .{};
    if (!r.physical_participation) return .{};
    const f = gs.artillery_formations.getPtr(r.formation).?;
    var loss: Loss = .{};
    if (r.damage == .recoverable and !held_field) {
        const roll = @as(i32, gs.rng.roll2d6(.battle)) + recovery.situation(gs, c, battle_scenario, outcome, roe, has_salvage, trucks, combined_wrecks);
        r.recovery = .{ .roll = roll, .target = tuning.loss.recovery_target };
        if (roll >= tuning.loss.recovery_target) r.damage = .recovered else {
            r.damage = .scuttled;
            r.cause = .scrap;
        }
    }
    const terminal = r.damage == .permanently_destroyed or r.damage == .scuttled;
    if (terminal) {
        loss.lost = 1;
        if (!held_field) for (&r.seats) |*seat| {
            if (!seat.present) continue;
            const escape = recovery.escapeRoll(gs, seat.person, outcome) orelse continue;
            seat.escape = escape;
            if (escape.roll < escape.target) {
                try recovery.captureMissing(gs, seat.person, c);
                seat.outcome.fate = .missing;
                loss.missing += 1;
            }
        };
        try artillery.destroy(gs, f.id);
    }
    r.compensation_basis = rules.damageValue(f.paid_price, r.severity orelse 0, r.newly_wrecked, terminal);
    r.armor_after = f.armor_pct;
    r.slots_after = f.slots;
    r.rounds_after = rules.loadedRounds(&f.slots);
    for (&r.lost_rounds, r.rounds_before, r.fired_rounds, r.rounds_after) |*lost, before, fired, after| lost.* = before - fired - after;
    return loss;
}

/// Extra operating XP only for a fired salvo; company-wide morale/fatigue remain
/// ordinary aftermath effects. Source: combat design, Rewards and accounting.
pub fn reward(gs: *GameState, result: *?report.ArtilleryResult, score_delta: i32) !void {
    const r = if (result.*) |*value| value else return;
    if (r.fire == .not_fired) return;
    for (&r.seats) |*seat| {
        const p = gs.person(seat.person) orelse continue;
        if (!seat.present or !p.isOnBooks()) continue;
        p.battles +|= 1;
        p.xp += p.xpGain(gs.clock.day_index, if (score_delta > 0) tuning.battle.xp_scored else tuning.battle.xp_fought);
        seat.xp_participation = true;
        _ = try personnel.checkAwards(gs, p.id);
    }
}

/// Retain one zero-kill physical history record for each real participating fight.
/// Source: combat design, Terminal history. No record for concession or forfeit.
pub fn recordHistory(gs: *GameState, result: ?report.ArtilleryResult, battle: types.BattleId, cid: types.ContractId) !void {
    const r = result orelse return;
    if (!r.physical_participation) return;
    var damaged: u8 = 0;
    var destroyed: u8 = 0;
    for (r.slots_before, r.slots_after) |before, after| {
        if (before.condition == after.condition) continue;
        damaged += @intFromBool(after.condition == .damaged);
        destroyed += @intFromBool(after.condition == .destroyed);
    }
    try gs.hull_combat_records.append(gs.allocator(), .{
        .hull_instance_id = r.hull,
        .battle_id = battle,
        .contract_id = cid,
        .hits_taken = @intFromBool(r.severity != null),
        .armor_lost = r.armor_before -| r.armor_after,
        .slots_damaged = damaged,
        .slots_destroyed = destroyed,
        .destroyed = r.newly_wrecked or r.damage == .permanently_destroyed or r.damage == .scuttled,
        .cause = r.cause,
    });
}

fn testContract(gs: *GameState, id: types.ArtilleryFormationId) contract.Contract {
    return .{ .id = @enumFromInt(1), .kind = .recon_raid, .employer_key = "LC", .enemy_key = "PER", .planet_key = gs.seatPlanetKey().?, .assigned_company = gs.artillery_formations.get(id).?.placement.company, .terms = .{ .length_months = 6, .base_pay_month = 400_000 } };
}

test "salvo consumes canonical loaded round and preview consumes no stream or warehouse package" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.getPtr(id).?;
    f.last_maintenance_day = 0;
    f.slots[@intFromEnum(slots.Slot.long_tom_bin_2)].rounds = 3;
    const c = testContract(&gs, id);
    const before = digest.stateHash(&gs);
    const maximum = preview(&gs, &c, 2, 10000).?;
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    var result = try snapshot(&gs, &c, .not_ready);
    var expected = gs.rng;
    const roll = expected.roll2d6(.battle);
    const reduced = fire(&gs, &result, 2, 10000);
    try std.testing.expectEqual(roll, result.?.accuracy_roll.?);
    try std.testing.expectEqual(maximum.target, result.?.target.?);
    try std.testing.expectEqual(expected, gs.rng);
    try std.testing.expectEqual(@as(u16, 2), f.slots[@intFromEnum(slots.Slot.long_tom_bin_2)].rounds);
    try std.testing.expectEqual(@as(i64, 10000) - result.?.suppressed_power, reduced);
    _ = try recover(&gs, &result, &c, scenario.roll(&expected, .battle, c.kind), .victory, .standard, true, false, 0, 0);
    try reward(&gs, &result, 1);
    try recordHistory(&gs, result, @enumFromInt(1), c.id);
    try std.testing.expectEqual(@as(u16, 1), result.?.fired_rounds[0]);
    try std.testing.expectEqual(@as(u16, 0), result.?.lost_rounds[0]);
    for (result.?.seats) |seat| {
        try std.testing.expect(seat.xp_participation);
        try std.testing.expectEqual(@as(u32, 1), gs.person(seat.person).?.battles);
    }
    try std.testing.expectEqual(@as(u16, 0), gs.hull_combat_records.items[0].kills);
}

test "physical exposure uses contract world independently of firing job and remote readiness" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.getPtr(id).?;
    var c = testContract(&gs, id);
    f.last_maintenance_day = 0;
    f.slots[@intFromEnum(slots.Slot.long_tom_bin_1)].rounds = 5;
    try std.testing.expect(physicallyPresent(&gs, f, &c));
    try std.testing.expect(preview(&gs, &c, 0, 10000) != null);
    const far = try @import("founding.zig").foundHq(&gs, "Far", .regional, "caph");
    try gs.addStock(.{ .hq = far }, slots.packageKey(.long_tom), 4);
    c.planet_key = "caph";
    try std.testing.expect(!physicallyPresent(&gs, f, &c));
    try std.testing.expect(preview(&gs, &c, 0, 10000) == null);
    const company = f.placement.company;
    gs.force(company).?.location_planet = "caph";
    try std.testing.expect(physicallyPresent(&gs, f, &c));
    gs.force(company).?.return_eta_day = 10;
    try std.testing.expect(!physicallyPresent(&gs, f, &c));
    gs.force(company).?.return_eta_day = null;
    f.slots[@intFromEnum(slots.Slot.main_gun)].condition = .destroyed;
    f.slots[@intFromEnum(slots.Slot.machine_gun_bin)].rounds = 2;
    try std.testing.expect(operations.defensiveReadiness(&gs, f));
    try std.testing.expect(!operations.operationalReadiness(&gs, f));
    var result = try snapshot(&gs, &c, .not_ready);
    _ = try applyExposure(&gs, &result, 0, false);
    try std.testing.expectEqual(@as(?u8, null), result.?.exposure_roll);
    try std.testing.expectEqual(@as(u16, 0), result.?.fired_rounds[1]);
}

test "terminal loss closes provenance clears service and retains escaped crew identities" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.getPtr(id).?;
    f.slots[@intFromEnum(slots.Slot.long_tom_bin_1)].rounds = 5;
    const c = testContract(&gs, id);
    var result = try snapshot(&gs, &c, .not_ready);
    const lift_before = try @import("lift.zig").planLiftQuery(&gs, c.assigned_company);
    const liquid_before = try @import("treasury.zig").liquidationValue(gs.allocator(), &gs);
    const sale_before = artillery.saleValue(f);
    result.?.damage = .permanently_destroyed;
    result.?.newly_wrecked = true;
    result.?.cause = .ammo;
    var random = gs.rng;
    const loss = try recover(&gs, &result, &c, scenario.roll(&random, .battle, c.kind), .victory, .standard, true, false, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), loss.lost);
    try std.testing.expectEqual(@as(u16, 5), result.?.lost_rounds[0]);
    try std.testing.expectEqual(formation.Placement.destroyed, f.placement);
    try std.testing.expectEqual(@as(u32, 0), artillery.attachedCount(&gs, c.assigned_company));
    try std.testing.expectEqual(@as(types.CBills, 0), artillery.monthlyCarry(&gs));
    try std.testing.expectEqual(@as(types.CBills, 0), @import("artillery_service.zig").weeklyConsumablesTotal(&gs));
    try std.testing.expectEqual(lift_before.needed - formation.carrier_vehicle_bays, (try @import("lift.zig").planLiftQuery(&gs, c.assigned_company)).needed);
    try std.testing.expectEqual(liquid_before - sale_before, try @import("treasury.zig").liquidationValue(gs.allocator(), &gs));
    try std.testing.expectEqual(@as(types.CBills, 0), artillery.saleValue(f));
    try std.testing.expect(operations.serviceCapability(&gs, f) == null);
    const supply = try @import("field_supply.zig").plan(gs.allocator(), &gs, c.assigned_company, 0, 0, 0);
    for (supply.lines) |line| for (slots.families) |family| try std.testing.expect(!std.mem.eql(u8, line.key, slots.packageKey(family)));
    const digest = @import("digest.zig");
    const terminal_before = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryUnavailable, crew.unassign(&gs, .{ .formation = id, .seat = .gunner }));
    try std.testing.expectError(error.ArtilleryUnavailable, crew.unassignTech(&gs, id));
    try std.testing.expectEqual(terminal_before, digest.stateHash(&gs));
    for (result.?.seats) |seat| try std.testing.expect(gs.person(seat.person).?.isOnBooks());
    try artillery.validate(&gs);
}

test "pool freight sold terminal outward and return transit never expose or fire a carrier" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.getPtr(id).?;
    const original = f.*;
    const c = testContract(&gs, id);
    for ([_]formation.Placement{
        .{ .hq_pool = gs.seat() },
        .{ .freight = .{ .from_hq = gs.seat(), .to_hq = @enumFromInt(2), .dispatch_day = 0, .eta_day = 1, .paid_cost = 0 } },
        .sold,
        .destroyed,
    }) |placement| {
        f.placement = placement;
        const before = digest.stateHash(&gs);
        try std.testing.expect(!physicallyPresent(&gs, f, &c));
        try std.testing.expect(preview(&gs, &c, 0, 10000) == null);
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
    f.* = original;
    var transit = c;
    transit.status = .transit;
    try gs.contracts.put(gs.allocator(), c.id, transit);
    try std.testing.expect(!physicallyPresent(&gs, f, &c));
    gs.contracts.getPtr(c.id).?.status = .completed;
    gs.force(c.assigned_company).?.return_eta_day = 1;
    try std.testing.expect(!physicallyPresent(&gs, f, &c));
    gs.force(c.assigned_company).?.return_eta_day = null;
    gs.hull_instances.getPtr(f.hull).?.owner = .market;
    try std.testing.expect(!physicallyPresent(&gs, f, &c));
}

test "seeded carrier hits recovery terminal evacuation and casualty snapshots satisfy captured validation" {
    var seen: [std.enums.values(rules.DamageOutcome).len]bool = @splat(false);
    var saw_missing = false;
    var saw_wound = false;
    var saw_kia = false;
    for (0..512) |seed| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        const id = try operations.fixtureForTest(&gs, true);
        const f = gs.artillery_formations.getPtr(id).?;
        f.armor_pct = if (seed % 2 == 0) 100 else 10;
        f.slots[@intFromEnum(slots.Slot.long_tom_bin_1)].rounds = 5;
        const c = testContract(&gs, id);
        var captured = try snapshot(&gs, &c, .not_ready);
        _ = try applyExposure(&gs, &captured, rules.percent_scale * rules.exposure_divisor, false);
        var random = gs.rng;
        const held = seed % 3 == 0;
        _ = try recover(&gs, &captured, &c, scenario.roll(&random, .battle, c.kind), .defeat, .standard, held, false, 0, 1);
        const a = captured.?;
        seen[@intFromEnum(a.damage)] = true;
        for (a.seats) |seat| {
            saw_missing = saw_missing or seat.outcome.fate == .missing;
            saw_wound = saw_wound or seat.outcome.wound != null;
            saw_kia = saw_kia or seat.outcome.fate == .kia;
        }
        const r: report.BattleReport = .{ .id = @enumFromInt(gs.next_battle_id), .day = 0, .contract = c.id, .company = c.assigned_company, .kind = "recon raid", .enemy_key = c.enemy_key, .scenario = "", .terrain = "", .weather = "", .outcome = .defeat, .held_field = held, .artillery = a };
        gs.next_battle_id += 1;
        try gs.battle_reports.record(gs.allocator(), r);
        try recordHistory(&gs, captured, r.id, r.contract);
        try artillery.validate(&gs);
    }
    for ([_]rules.DamageOutcome{ .damaged, .recoverable, .recovered, .scuttled, .permanently_destroyed }) |outcome| {
        if (!seen[@intFromEnum(outcome)]) std.debug.print("carrier outcome not exercised: {s}\n", .{@tagName(outcome)});
        try std.testing.expect(seen[@intFromEnum(outcome)]);
    }
    try std.testing.expect(saw_missing and saw_wound and saw_kia);
}
