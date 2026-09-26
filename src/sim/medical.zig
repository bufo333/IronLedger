//! Medical, rest & training (Stage 8, ARCH §9.7): the systems that make
//! rotating home matter. Wounds heal on doctor/facility timelines; fatigue
//! decays only at home (mess-boosted, line-officer-boosted); morale drifts
//! with rest and grinds with exhaustion; skill training runs only at a
//! regional/brigade HQ with a training ground.
//! MekHQ counterpart: the medical system and advanced medical injuries
//! (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const GameState = @import("state.zig").GameState;
const hq_ops = @import("hq_ops.zig");
const sites = @import("sites.zig");
const toe = @import("toe.zig");

/// Days of training to improve a skill one step.
pub const training_days = tuning.medical.training_days;

/// Training program length at `hq_id`: each HR admin there shortens it,
/// down to `training_min_days`.
pub fn trainingDaysFor(gs: *GameState, hq_id: types.HqId) u32 {
    if (gs.hqs.getPtr(hq_id) == null) return training_days;
    const hr = hq_ops.hqStaff(gs, hq_id, .admin_hr);
    return @max(tuning.medical.training_min_days, training_days -| tuning.medical.training_days_per_hr_staff * hr.count);
}

pub const WoundCause = enum { combat, accident };

/// Where a wound lands (MekHQ `InjuryUtil` hit locations,
/// collapsed to 2d6): head and internal on the extremes, limbs in the
/// middle. Accidents in the bay break arms, legs and ribs, not skulls.
pub fn rollLocation(gs: *GameState, cause: WoundCause) person_mod.InjuryLocation {
    const roll = gs.rng.roll2d6(.medical);
    const combat: person_mod.InjuryLocation = switch (roll) {
        2 => .head,
        3, 4 => .internal,
        5, 6 => .torso,
        7 => .left_leg,
        8 => .right_leg,
        9 => .left_arm,
        10 => .right_arm,
        11 => .torso,
        else => .head,
    };
    if (cause == .combat) return combat;
    return switch (combat) {
        .head => .right_arm,
        .internal => .torso,
        else => |loc| loc,
    };
}

/// Wound someone: they leave duty with a new injury of `severity` (1
/// light, 2 serious, 3 crippling) at a rolled location. A crippling head
/// or internal wound is permanent on 2d6 ≤ `tuning.medical.permanent_target`
/// (`.medical` stream). Healing starts when the medbay admits them.
pub fn inflict(gs: *GameState, person_id: types.PersonId, cause: WoundCause, severity: u8, why: []const u8) !void {
    const p = gs.person(person_id) orelse return;
    if (p.status == .kia) return;
    const location = rollLocation(gs, cause);
    const permanent = severity >= 3 and (location == .head or location == .internal) and gs.rng.roll2d6(.medical) <= tuning.medical.permanent_target;
    try p.injuries.append(gs.allocator(), .{
        .location = location,
        .severity = @min(severity, 3),
        .incurred_day = gs.clock.day_index,
        .permanent = permanent,
    });
    p.status = .wounded;
    p.wound_heal_day = null; // triage again with the new wound
    if (!gs.auto_admit) p.medbay_admitted = false;
    _ = try @import("personnel.zig").checkAwards(gs, person_id); // the Wound Badge
    try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medbay] {s} wounded ({s}): {s} {s}{s}", .{
        try p.fullName(gs.allocator()), why, severityLabel(severity), @tagName(location),
        if (permanent) " — permanent" else "",
    });
}

pub fn severityLabel(severity: u8) []const u8 {
    return switch (severity) {
        0, 1 => "light",
        2 => "serious",
        else => "crippling",
    };
}

/// Is this person's posting currently deployed?
fn isDeployed(gs: *GameState, p: *const person_mod.Person) bool {
    return gs.isCompanyDeployed(gs.companyOf(p.assigned_force));
}

/// Where a fresh wound is treated: a home HQ's hospital, a MASH lance in
/// the field, or the field with no MASH.
pub const Care = enum { home, field_mash, field };

/// A company in the field has MASH care when one of its MASH trucks is
/// operational.
pub fn companyFieldsMash(gs: *GameState, company: types.ForceId) bool {
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.kind == .mash and gs.companyOf(u.force) == company and gs.unitOperational(u)) return true;
    }
    return false;
}

/// The care a person's wound gets today.
pub fn careFor(gs: *GameState, p: *const person_mod.Person) Care {
    const company = gs.companyOf(p.assigned_force);
    if (!gs.isCompanyDeployed(company)) return .home;
    return if (companyFieldsMash(gs, company)) .field_mash else .field;
}

/// Triage & recovery time for a fresh wound.
pub fn healDays(gs: *GameState, care: Care) u32 {
    const m = tuning.medical;
    var days: u32 = m.heal_base_days + gs.rng.roll2d6(.medical);

    // Doctor coverage: 1 doctor per 25 patients (MekHQ ratio); medics
    // each carry a few patients of their own.
    var doctors: u32 = 0;
    var medics: u32 = 0;
    var wounded: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status == .active and p.role == .doctor) doctors += 1;
        if (p.status == .active and p.role == .medic) medics += 1;
        if (p.status == .wounded) wounded += 1;
    }
    if (wounded > doctors * m.patients_per_doctor + medics * m.patients_per_medic) days = @intCast(types.applyBp(days, m.understaffed_bp)); // understaffed infirmary

    if (care == .field_mash) days = @intCast(types.applyBp(days, m.mash_bp)); // MASH lance forward surgery
    // Home hospital: any hospital in the outfit shortens the stay.
    var hqit = gs.hqs.iterator();
    var best_hospital: u8 = 0;
    while (hqit.next()) |entry| {
        best_hospital = @max(best_hospital, entry.value_ptr.effectiveFacilityLevel(.hospital));
    }
    if (care == .home and best_hospital > 0) days = @intCast(types.applyBp(days, m.hospital_bp));

    return @max(days, m.heal_min_days);
}

/// Medbay beds: the outfit's best hospital level × 10 at home; for a
/// deployed company, 4 per operational MASH truck plus its medics.
pub fn bedCapacity(gs: *GameState, company: types.ForceId, deployed: bool) u32 {
    if (deployed) {
        var beds: u32 = 0;
        var it = gs.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.kind == .mash and gs.companyOf(u.force) == company and gs.unitOperational(u)) beds += tuning.medical.beds_per_mash;
        }
        // Medics: staffing the MASH trucks, a bed each up to
        // doubling the trucks; without trucks, an aid station of one bed
        // per two medics.
        var medics: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |e| if (e.value_ptr.status == .active and e.value_ptr.role == .medic and gs.companyOf(e.value_ptr.assigned_force) == company) {
            medics += 1;
        };
        return beds + (if (beds > 0) @min(medics, beds) else medics / 2);
    }
    var best: u32 = 0;
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| best = @max(best, @as(u32, entry.value_ptr.effectiveFacilityLevel(.hospital)) * tuning.medical.beds_per_hospital_level);
    return best;
}

/// medical phase, daily: triage new wounds, discharge the healed, and —
/// when beds are short — let priority decide whose recovery runs today.
pub fn runDailyHealing(gs: *GameState) !void {
    // Leave expires.
    var lit = gs.people.iterator();
    while (lit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.leave_until_day) |until| if (gs.clock.day_index >= until) {
            p.leave_until_day = null;
        };
    }

    // Beds: rank the wounded by priority, then by soonest discharge; those
    // past the bed count wait (their timers slip a day).
    const Patient = struct { id: types.PersonId, priority: u8, heal_day: u32, deployed: bool, company: types.ForceId };
    var patients: std.ArrayListUnmanaged(Patient) = .empty;
    defer patients.deinit(gs.scratch());
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .wounded or p.wound_heal_day == null) continue;
        try patients.append(gs.scratch(), .{
            .id = p.id,
            .priority = p.medbay_priority,
            .heal_day = p.wound_heal_day.?,
            .deployed = isDeployed(gs, p),
            .company = gs.companyOf(p.assigned_force),
        });
    }
    std.mem.sort(Patient, patients.items, {}, struct {
        fn lt(_: void, a: Patient, b: Patient) bool {
            if (a.priority != b.priority) return a.priority > b.priority;
            return a.heal_day < b.heal_day;
        }
    }.lt);
    // One pass in that order: each patient takes a bed while any are left
    // at home or in their company's field beds.
    var home_beds = bedCapacity(gs, .none, false);
    var field_left: std.AutoHashMapUnmanaged(types.ForceId, u32) = .empty;
    defer field_left.deinit(gs.scratch());
    for (patients.items) |pt| {
        if (pt.deployed) {
            const left = try field_left.getOrPut(gs.scratch(), pt.company);
            if (!left.found_existing) left.value_ptr.* = bedCapacity(gs, pt.company, true);
            if (left.value_ptr.* > 0) {
                left.value_ptr.* -= 1;
            } else gs.person(pt.id).?.wound_heal_day.? += 1;
        } else if (home_beds > 0) {
            home_beds -= 1;
        } else {
            gs.person(pt.id).?.wound_heal_day.? += 1;
        }
    }

    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .wounded) continue;
        if (p.wound_heal_day == null) {
            // Nobody heals in a corridor: the player admits the wounded
            // (`admit`), and only then does triage run — unless the medbay
            // runs its own morning round (`gs.auto_admit`).
            if (!p.medbay_admitted) {
                if (!gs.auto_admit) continue;
                p.medbay_admitted = true;
                try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medbay] {s} admitted (auto)", .{try p.fullName(gs.allocator())});
            }
            // Triage consumes a ton of medical supplies from wherever they
            // lie; an empty dispensary heals half again as slowly.
            var days = healDays(gs, careFor(gs, p));
            if (!gs.takeStock(sites.siteForForce(gs, p.assigned_force), "medical_supplies", 1)) days = @intCast(types.applyBp(days, tuning.medical.no_supplies_bp));
            if (p.has("iron_man")) days = @max(tuning.medical.iron_man_min_days, @as(u32, @intCast(types.applyBp(days, tuning.medical.iron_man_heal_bp))));
            // A wound with no record behind it (saves before schema v7,
            // event effects): one light internal injury stands in for it.
            if (p.openInjuries() == 0) try p.injuries.append(gs.allocator(), .{ .location = .internal, .severity = 1, .incurred_day = gs.clock.day_index });
            // Every open injury closes on its own day: serious ones take
            // half again as long, crippling ones twice as long: days × (severity + 1) / 2.
            for (p.injuries.items) |*inj| {
                if (inj.healed or inj.heal_done_day != null) continue;
                inj.heal_done_day = gs.clock.day_index + days * (@as(u32, inj.severity) + 1) / 2;
            }
            p.wound_heal_day = p.healDoneDay() orelse gs.clock.day_index + days;
        } else if (gs.clock.day_index >= p.wound_heal_day.?) {
            p.status = .active;
            p.wound_heal_day = null;
            p.medbay_admitted = false;
            // Close the record: permanent injuries stay, the rest are history.
            var lasting: u32 = 0;
            var i: usize = 0;
            while (i < p.injuries.items.len) {
                if (p.injuries.items[i].permanent) {
                    p.injuries.items[i].healed = true;
                    lasting += 1;
                    i += 1;
                } else _ = p.injuries.orderedRemove(i);
            }
            try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medical] {s} returns to duty{s}", .{ try p.fullName(gs.allocator()), if (lasting > 0) " — with a permanent injury on the record" else "" });
        }
    }
}

/// Payday turnover (AtB retirement/defection rolls, abstracted): anyone
/// at `age_retire` retires, seats vacated so the checklist shows the hole.
/// The restless — morale under the line, fatigue over it — with a year on
/// the payroll roll 2d6 against a target that climbs with every
/// complaint; a miss queues notice in the inbox. Deployed people wait for
/// the tour to end. Returns retirements plus notices queued.
pub fn runMonthlyTurnover(gs: *GameState) !u32 {
    const t = tuning.person;
    const day = gs.clock.day_index;
    var notices: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active) continue;
        // Nobody walks out mid-contract: notice waits for the tour to end.
        if (isDeployed(gs, p)) continue;
        // Age: past the line they hang up the neurohelmet.
        const age = p.ageYears(day);
        if (age != null and age.? >= t.age_retire) {
            const company = gs.companyOf(p.assigned_force);
            const paid = try @import("personnel.zig").depart(gs, p.id, .retired, types.full_bp, "retirement payout");
            try gs.log(.rotation, .{ .company = company, .hq = p.posted_hq }, "[turnover] {s} ({s}) retires at {d}{s}", .{ try p.fullName(gs.allocator()), @tagName(p.role), age.?, if (paid > 0) try std.fmt.allocPrint(gs.allocator(), " — {d} c-bills paid out", .{paid}) else "" });
            notices += 1;
            continue;
        }
        const restless = turnoverRisk(p, day);
        if (restless == 0) continue;
        const roll = gs.rng.roll2d6(.medical);
        if (roll >= t.turnover_target + gs.diff().turnover_delta + restless) continue; // difficulty
        // Notice, not a disappearance: the inbox offers a raise, a
        // bonus, a replacement from the hall, or the door.
        try @import("contract_events.zig").queueNotice(gs, p.id);
        notices += 1;
    }
    return notices;
}

/// How many restless flags a person carries into the payday roll: none
/// under a year's tenure, morale and fatigue flags plus one for age;
/// founders stand by the outfit unless truly miserable, and each loyalty
/// modifier (founder included) cancels a flag. Zero means they do not
/// roll. The checklist counts who will roll from the same function.
pub fn turnoverRisk(p: *const person_mod.Person, day: u32) u8 {
    const t = tuning.person;
    if (p.tenureMonths(day) < t.turnover_min_tenure_months) return 0;
    var restless = p.restlessness();
    const age = p.ageYears(day);
    if (age != null and age.? >= t.age_old) restless += 1;
    const loyal = p.loyalty(day);
    if (loyal.founder and p.morale >= t.founder_morale_floor) return 0;
    return restless -| loyal.count();
}

/// training phase, daily: finish programs that came due.
pub fn runDailyTraining(gs: *GameState) !void {
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        const t = p.training orelse continue;
        if (gs.clock.day_index < t.done_day) continue;
        p.training = null;
        person_mod.spendXpToImprove(p, t.skill) catch |err| {
            try gs.log(.training, .{ .company = gs.companyOf(p.assigned_force) }, "[training] {s} washed out of {s} training ({s})", .{
                try p.fullName(gs.allocator()), @tagName(t.skill), @errorName(err),
            });
            continue;
        };
        try gs.log(.training, .{ .company = gs.companyOf(p.assigned_force) }, "[training] {s} completes {s} training (now {d})", .{
            try p.fullName(gs.allocator()), @tagName(t.skill), p.skill(t.skill).?,
        });
    }
}

/// morale_fatigue phase, weekly: rest at home, grind in the field, and the
/// rotation reset that clears a company's deployment debt.
pub fn runWeeklyRest(gs: *GameState) !void {
    const tp = tuning.person;

    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (!p.isOnBooks()) continue;

        if (isDeployed(gs, p)) {
            const company = gs.companyOf(p.assigned_force);
            const contract = gs.deploymentContract(company);
            const garrison = if (contract) |c| c.kind.isGarrisonClass() else false;
            if (garrison) {
                // Garrison duty is nearly home: barracks and a town.
                // Fatigue recovers at a share of the home rate — the mess
                // lance stands in for the mess hall — and spirits hold.
                const mess_lance = if (toe.supportLance(gs, company, .mess)) |l| l.units.items.len > 0 else false;
                const field_decay: u32 = @intCast(types.applyBp(person_mod.fatigueDecayPerWeek(if (mess_lance) 1 else 0), tuning.person.garrison_rest_bp));
                p.addFatigue(-@as(i32, @intCast(@min(field_decay, 255))));
                if (p.morale < tuning.person.morale_garrison_lift_below and p.fatigue <= tuning.person.fatigue_grind) p.addMorale(1);
            }
            // Exhaustion grinds morale down, and a hungry company grinds
            // faster; combat tours get no rest at all.
            if (p.fatigue > tuning.person.fatigue_grind) p.addMorale(-1); // Cool Under Fire shrugs a one-point grind off entirely
            if (gs.force(company)) |co| {
                if (co.supply_shortage_days > 0) p.addMorale(-2);
            }
        } else {
            // Rest at home is the home HQ's: its mess sets the recovery
            // rate, its HR staff keep spirits up.
            const home = gs.homeHqOf(p);
            const mess: u8 = if (gs.hqs.getPtr(home)) |h| h.effectiveFacilityLevel(.mess) else 0;
            const decay: u32 = @intCast(types.applyBp(person_mod.fatigueDecayPerWeek(mess), gs.commanderMultBp(.fatigue_recovery)));
            const hr_bonus: u8 = if (gs.hqs.getPtr(home) != null) @intCast(@min(tp.hr_morale_bonus_max, hq_ops.hqStaff(gs, home, .admin_hr).count / tp.hr_morale_admins_per_point)) else 0;
            // On leave: double recovery.
            const on_leave = p.leave_until_day != null and gs.clock.day_index < p.leave_until_day.?;
            p.addFatigue(-@as(i32, @intCast(@min(if (on_leave) decay * 2 else decay, 255))));
            // Rested spirits drift toward content (50), mess food helps.
            const target: u8 = tuning.person.morale_content + 2 * mess + hr_bonus;
            if (p.morale < target) p.addMorale(1);
            if (p.fatigue > tuning.person.fatigue_grind) p.addMorale(-1);
        }
    }

    // Rotation reset: an undeployed company whose people are rested clears
    // its deployment debt (ARCH §9.7).
    var fit = gs.forces.iterator();
    while (fit.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon != .company or f.contracts_since_rotation == 0) continue;
        if (gs.isCompanyDeployed(f.id)) continue;

        const crew = @import("personnel.zig").companyCrewStats(gs, f.id);
        if (crew.heads > 0 and crew.avg_fatigue <= tuning.person.fatigue_rested) {
            f.contracts_since_rotation = 0;
            f.last_rotation_day = gs.clock.day_index;
            try gs.log(.rotation, .{ .company = f.id }, "[rotation] {s} is rested and reset — ready for a fresh deployment", .{f.name});
        }
    }
}

test "wounds heal; the field is slower than a home hospital" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 21 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster); // HQ has hospital lv1
    const id = try gs.hirePerson("Lori", "Kalmar", .mekwarrior);
    _ = try gs.hirePerson("Ivan", "Petrov", .doctor);

    const p = gs.person(id).?;
    p.status = .wounded;
    p.medbay_admitted = true;
    try runDailyHealing(&gs); // triage
    try std.testing.expect(p.wound_heal_day != null);

    // Advance past the heal date: back to duty.
    gs.clock.day_index = p.wound_heal_day.? + 1;
    try runDailyHealing(&gs);
    try std.testing.expectEqual(person_mod.Status.active, p.status);
}

test "fatigue decays only at home, faster with a line officer" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 22 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
    const id = try gs.hirePerson("A", "B", .mekwarrior);
    gs.person(id).?.fatigue = 60;

    for (0..4) |_| try runWeeklyRest(&gs);
    const rested = gs.person(id).?.fatigue;
    try std.testing.expect(rested < 60);

    // Same person under a paymaster recovers slower (no 2% edge).
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 22 });
    defer gs2.deinit();
    _ = try gs2.createCommander("T", .LC, .paymaster);
    const id2 = try gs2.hirePerson("A", "B", .mekwarrior);
    gs2.person(id2).?.fatigue = 60;
    for (0..4) |_| try runWeeklyRest(&gs2);
    try std.testing.expect(gs2.person(id2).?.fatigue >= rested);
}

test "rested companies reset their rotation debt" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 23 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    gs.force(co).?.contracts_since_rotation = 2;
    const id = try gs.hirePerson("A", "B", .mekwarrior);
    gs.person(id).?.assigned_force = co;
    gs.person(id).?.fatigue = 40;

    for (0..12) |_| try runWeeklyRest(&gs);
    try std.testing.expectEqual(@as(u16, 0), gs.force(co).?.contracts_since_rotation);
    try std.testing.expect(gs.force(co).?.last_rotation_day != null);
}

test "injuries land by location, heal on their own days, and permanent ones scar the record" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1216 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const id = try gs.hirePerson("Lori", "Kalmar", .mekwarrior);
    _ = try gs.hirePerson("Ivan", "Petrov", .doctor);
    try gs.addStock(.{ .hq = gs.hqs.keys()[0] }, "medical_supplies", 10);

    try inflict(&gs, id, .combat, 1, "test");
    try inflict(&gs, id, .accident, 3, "test");
    const p = gs.person(id).?;
    try std.testing.expectEqual(person_mod.Status.wounded, p.status);
    try std.testing.expectEqual(@as(u32, 2), p.openInjuries());
    // Accidents never hit the head or the innards.
    try std.testing.expect(p.injuries.items[1].location != .head and p.injuries.items[1].location != .internal);
    try std.testing.expect(!p.injuries.items[1].permanent);

    p.medbay_admitted = true;
    try runDailyHealing(&gs); // triage
    const light = p.injuries.items[0].heal_done_day.?;
    const crippling = p.injuries.items[1].heal_done_day.?;
    try std.testing.expect(crippling > light);
    try std.testing.expectEqual(crippling, p.wound_heal_day.?);
    // The light wound closes first; still in the medbay for the other.
    gs.clock.day_index = light;
    try runDailyHealing(&gs);
    try std.testing.expectEqual(person_mod.Status.wounded, p.status);
    gs.clock.day_index = crippling;
    try runDailyHealing(&gs);
    try std.testing.expectEqual(person_mod.Status.active, p.status);
    try std.testing.expectEqual(@as(usize, 0), p.injuries.items.len); // nothing permanent: clean record

    // A permanent head wound survives healing and costs a skill point.
    try p.injuries.append(gs.allocator(), .{ .location = .head, .severity = 3, .incurred_day = gs.clock.day_index, .permanent = true });
    p.status = .wounded;
    p.medbay_admitted = true;
    try runDailyHealing(&gs);
    gs.clock.day_index = p.wound_heal_day.?;
    try runDailyHealing(&gs);
    try std.testing.expectEqual(person_mod.Status.active, p.status);
    try std.testing.expectEqual(@as(usize, 1), p.injuries.items.len);
    try std.testing.expect(p.injuries.items[0].healed);
    try std.testing.expectEqual(@as(u8, 1), p.permanentPenalty());
    try std.testing.expectEqual(@as(u32, 0), p.openInjuries());

    // A wound with no record gets one at triage.
    const other = try gs.hirePerson("Ana", "Ruiz", .mekwarrior);
    gs.person(other).?.status = .wounded;
    gs.person(other).?.medbay_admitted = true;
    try runDailyHealing(&gs);
    try std.testing.expectEqual(@as(u32, 1), gs.person(other).?.openInjuries());
}

test "the restless hand in notice after a year (an inbox decision), the content stay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1220 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    // Content and fresh (and all thirty, under the age flag): nobody
    // stirs however low the dice.
    gs.clock.day_index = 400;
    var ait = gs.people.iterator();
    while (ait.next()) |e| e.value_ptr.born_day = -30 * 365;
    try std.testing.expectEqual(@as(u32, 0), try runMonthlyTurnover(&gs));
    // Everyone miserable with a year in: notices land in the inbox, nobody has left yet.
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        e.value_ptr.morale = 5;
        e.value_ptr.fatigue = 90;
    }
    const notices = try runMonthlyTurnover(&gs);
    try std.testing.expect(notices > 0 and notices < gs.people.count());
    // Exhausted and unhappy is one in six a month (2d6 <= 4), not a stampede.
    const pct = notices * 100 / @as(u32, @intCast(gs.people.count()));
    try std.testing.expect(pct >= 6 and pct <= 30);
    try std.testing.expectEqual(@as(usize, notices), gs.event_queue.pending.items.len);
    var gone: u32 = 0;
    var rit = gs.people.iterator();
    while (rit.next()) |e| if (e.value_ptr.status != .active) {
        gone += 1;
    };
    try std.testing.expectEqual(@as(u32, 0), gone);
    // Another payday never queues a second notice for the same person.
    _ = try runMonthlyTurnover(&gs);
    for (gs.event_queue.pending.items, 0..) |a, i| for (gs.event_queue.pending.items[i + 1 ..]) |b| try std.testing.expect(a.person != b.person);
    // Under a year on the books: restless but rolls nothing.
    var fresh = GameState.init(std.testing.allocator, .{ .seed = 1221 });
    defer fresh.deinit();
    _ = try fresh.createCommander("T", .LC, .paymaster);
    _ = try @import("starter_company.zig").generateInto(&fresh, "Alpha");
    var fit = fresh.people.iterator();
    while (fit.next()) |e| e.value_ptr.morale = 0;
    fresh.clock.day_index = 100;
    try std.testing.expectEqual(@as(u32, 0), try runMonthlyTurnover(&fresh));
}

test "the old retire on payday with their payout; the merely older roll to leave" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 124 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const old = try gs.hirePerson("Grey", "Beard", .tech_mek);
    gs.clock.day_index = 400;
    gs.person(old).?.born_day = -66 * 365;
    const young = try gs.hirePerson("Young", "Gun", .mekwarrior);
    gs.person(young).?.born_day = -22 * 365;
    gs.person(young).?.morale = 100;
    const funds = gs.funds;
    _ = try runMonthlyTurnover(&gs);
    try std.testing.expectEqual(person_mod.Status.retired, gs.person(old).?.status);
    try std.testing.expect(gs.funds < funds); // a year in: one month's severance
    try std.testing.expectEqual(person_mod.Status.active, gs.person(young).?.status);
    // Past fifty and content: one restless flag from age alone, so they roll (some seeds notice).
    const older = try gs.hirePerson("Mid", "Career", .mekwarrior);
    gs.person(older).?.born_day = -55 * 365;
    gs.person(older).?.recruited_day = 1; // a year in, not a founder
    gs.person(older).?.morale = 100;
    var noticed = false;
    for (0..40) |_| {
        _ = try runMonthlyTurnover(&gs);
        for (gs.event_queue.pending.items) |ev| if (ev.person == older) {
            noticed = true;
        };
        if (noticed) break;
    }
    try std.testing.expect(noticed);
}

test "a founder never rolls while morale holds; a veteran's loyalty cancels a flag" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 125 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    gs.clock.day_index = 400;
    const founder = try gs.hirePerson("Day", "One", .mekwarrior);
    gs.person(founder).?.recruited_day = 0;
    gs.person(founder).?.morale = 20;
    gs.person(founder).?.fatigue = 100;
    const vet = try gs.hirePerson("Five", "Tours", .tech_mek);
    gs.person(vet).?.recruited_day = 1;
    gs.person(vet).?.tours = 5;
    gs.person(vet).?.morale = 100;
    gs.person(vet).?.fatigue = 100; // one flag, cancelled by the veteran modifier
    for (0..60) |_| {
        _ = try runMonthlyTurnover(&gs);
        for (gs.event_queue.pending.items) |ev| try std.testing.expect(ev.person != founder and ev.person != vet);
    }
    // Miserable founders do roll.
    gs.person(founder).?.morale = 0;
    var noticed = false;
    for (0..60) |_| {
        _ = try runMonthlyTurnover(&gs);
        for (gs.event_queue.pending.items) |ev| if (ev.person == founder) {
            noticed = true;
        };
        if (noticed) break;
    }
    try std.testing.expect(noticed);
}

test "garrison duty recovers fatigue in the field; a combat tour does not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1230 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 24, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    var pit = gs.people.iterator();
    while (pit.next()) |e| e.value_ptr.fatigue = 40;
    try runWeeklyRest(&gs);
    const pilot = gs.unit(gs.units.keys()[0]).?.pilot;
    try std.testing.expect(gs.person(pilot).?.fatigue < 40);
    // The same company on a raid: no recovery.
    gs.contracts.getPtr(@enumFromInt(1)).?.kind = .objective_raid;
    const before = gs.person(pilot).?.fatigue;
    try runWeeklyRest(&gs);
    try std.testing.expectEqual(before, gs.person(pilot).?.fatigue);
}

test "medics add field beds and carry patients toward the doctor ratio" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1211 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try gs.createForce("Alpha", .company, .none);
    // No MASH: two medics make one bed; four make two.
    try std.testing.expectEqual(@as(u32, 0), bedCapacity(&gs, co, true));
    for (0..4) |_| {
        const id = try gs.hirePerson("M", "Edic", .medic);
        gs.person(id).?.assigned_force = co;
    }
    try std.testing.expectEqual(@as(u32, 2), bedCapacity(&gs, co, true));
    // A crewed MASH truck: 4 beds, plus one per medic up to doubling it.
    const truck = try gs.addUnit("MASH-27");
    try toe.moveUnitToForce(&gs, truck, co);
    try std.testing.expectEqual(@as(u32, 2), bedCapacity(&gs, co, true)); // no crew, no truck beds
    gs.unit(truck).?.pilot = try gs.hirePerson("D", "River", .vehicle_crew);
    try std.testing.expectEqual(@as(u32, 8), bedCapacity(&gs, co, true));
}

/// Every MASH truck in the company mothballed: on the books, not rolling.
fn mothballMash(gs: *GameState, company: types.ForceId) void {
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.kind == .mash and gs.companyOf(u.force) == company) u.status = .mothballed;
    }
}

test "a MASH truck that cannot roll gives no field beds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7001 });
    defer gs.deinit();
    const f = try @import("contract_events.zig").damagedCompanyForTest(&gs, 0);
    const co = f.c.assigned_company;
    const rolling = bedCapacity(&gs, co, true);
    mothballMash(&gs, co);
    const parked = bedCapacity(&gs, co, true);
    try std.testing.expect(parked < rolling);
}

test "a deployed patient without a ready MASH lance heals slower than one with it" {
    var days: [2]u32 = undefined;
    for (&days, 0..) |*d, with_mash| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 7002 });
        defer gs.deinit();
        const f = try @import("contract_events.zig").damagedCompanyForTest(&gs, 0);
        const co = f.c.assigned_company;
        try std.testing.expect(gs.isCompanyDeployed(co));
        if (with_mash == 0) mothballMash(&gs, co);
        var patient: types.PersonId = .none;
        var it = gs.people.iterator();
        while (it.next()) |e| if (e.value_ptr.role == .mekwarrior and gs.companyOf(e.value_ptr.assigned_force) == co) {
            patient = e.key_ptr.*;
            break;
        };
        const p = gs.person(patient).?;
        p.status = .wounded;
        p.medbay_admitted = true;
        try runDailyHealing(&gs);
        d.* = p.wound_heal_day.? - gs.clock.day_index;
    }
    try std.testing.expect(days[0] > days[1]);
}

test "five tied field patients and four beds: exactly one waits" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7101 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try gs.createForce("Alpha", .company, .none);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    // Eight medics and no MASH truck: an aid station of four beds.
    for (0..8) |_| gs.person(try gs.hirePerson("M", "Edic", .medic)).?.assigned_force = co;
    try std.testing.expectEqual(@as(u32, 4), bedCapacity(&gs, co, true));
    const due = gs.clock.day_index + 10;
    var patients: [5]types.PersonId = undefined;
    for (&patients) |*id| {
        id.* = try gs.hirePerson("W", "Ounded", .mekwarrior);
        const p = gs.person(id.*).?;
        p.assigned_force = co;
        p.status = .wounded;
        p.medbay_admitted = true;
        p.wound_heal_day = due;
    }
    try runDailyHealing(&gs);
    var waiting: u32 = 0;
    for (patients) |id| waiting += @intFromBool(gs.person(id).?.wound_heal_day.? == due + 1);
    try std.testing.expectEqual(@as(u32, 1), waiting);
}

test "weekly rest uses the home HQ's mess, not the best mess in the outfit" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7602 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const seat = gs.hqs.keys()[0];
    const second = try gs.foundHq("Second", .regional, "alkaid");
    for (gs.hqs.getPtr(seat).?.facilities.items) |*f| {
        if (f.kind == .mess) f.level = 3;
    }
    gs.hqs.getPtr(seat).?.staff_assigned = 999;
    gs.hqs.getPtr(second).?.staff_assigned = 999;
    var tired: [2]types.PersonId = undefined;
    for ([_]types.HqId{ seat, second }, 0..) |hq, i| {
        const co = try gs.createForce(if (i == 0) "Alpha" else "Bravo", .company, .none);
        gs.force(co).?.supplying_hq = hq;
        const id = try gs.hirePerson("T", "Ired", .mekwarrior);
        gs.person(id).?.assigned_force = co;
        gs.person(id).?.fatigue = 60;
        tired[i] = id;
    }
    try runWeeklyRest(&gs);
    const rested_at_seat = 60 - gs.person(tired[0]).?.fatigue;
    const rested_at_second = 60 - gs.person(tired[1]).?.fatigue;
    try std.testing.expect(rested_at_seat > rested_at_second);
}
