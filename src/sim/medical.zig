//! Medical, rest & training (Stage 8, ARCH §9.7): the systems that make
//! rotating home matter. Wounds heal on doctor/facility timelines; fatigue
//! decays only at home (mess-boosted, line-officer-boosted); morale drifts
//! with rest and grinds with exhaustion; skill training runs only at a
//! regional/brigade HQ with a training ground.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const GameState = @import("state.zig").GameState;

/// Days of training to improve a skill one step.
pub const training_days = tuning.medical.training_days;

/// Training program length at the outfit's HQ: a staffed HR office runs a
/// tighter schedule (Stage 9C back office).
pub fn trainingDaysFor(gs: *GameState) u32 {
    if (gs.hqs.count() == 0) return training_days;
    const hr = gs.hqStaff(gs.hqs.keys()[0], .admin_hr);
    return @max(tuning.medical.training_min_days, training_days -| tuning.medical.training_days_per_hr_staff * hr.count);
}

pub const WoundCause = enum { combat, accident };

/// Where a wound lands (Stage 12.16; MekHQ `InjuryUtil` hit locations,
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
/// or internal wound is permanent on 2d6 ≤ 4 (`.medical` stream). Healing
/// starts when the medbay admits them. // TUNE
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
    _ = try @import("personnel.zig").checkAwards(gs, person_id); // 12B.5: the Wound Badge
    try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medbay] {s} {s} wounded ({s}): {s} {s}{s}", .{
        p.first_name, p.last_name, why, severityLabel(severity), @tagName(location), if (permanent) " — permanent" else "",
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
    return gs.deploymentContract(gs.companyOf(p.assigned_force)) != null;
}

/// Triage & recovery time for a fresh wound.
pub fn healDays(gs: *GameState, deployed_with_mash: bool) u32 {
    const m = tuning.medical;
    var days: u32 = m.heal_base_days + gs.rng.roll2d6(.medical);

    // Doctor coverage: 1 doctor per 25 patients (MekHQ ratio); medics
    // (12B.11) each carry a few patients of their own.
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

    if (deployed_with_mash) days = @intCast(types.applyBp(days, m.mash_bp)); // MASH lance forward surgery
    // Home hospital: better facilities, shorter stays.
    var hqit = gs.hqs.iterator();
    var best_hospital: u8 = 0;
    while (hqit.next()) |entry| {
        best_hospital = @max(best_hospital, entry.value_ptr.effectiveFacilityLevel(.hospital));
    }
    if (!deployed_with_mash and best_hospital > 0) days = @intCast(types.applyBp(days, m.hospital_bp));

    return @max(days, m.heal_min_days);
}

/// Medbay beds (Stage 9C.2): hospital level × 10 at home; 4 per MASH truck
/// with a deployed company.
pub fn bedCapacity(gs: *GameState, company: types.ForceId, deployed: bool) u32 {
    if (deployed) {
        var beds: u32 = 0;
        var it = gs.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.kind == .mash and u.status != .destroyed and gs.companyOf(u.force) == company) beds += tuning.medical.beds_per_mash;
        }
        // Medics (12B.11): staffing the MASH trucks, a bed each up to
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
    defer patients.deinit(std.heap.page_allocator);
    var pit = gs.people.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .wounded or p.wound_heal_day == null) continue;
        try patients.append(std.heap.page_allocator, .{
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
    var home_beds = bedCapacity(gs, .none, false);
    for (patients.items) |pt| {
        if (pt.deployed) {
            // Field: MASH beds per company, first come first served.
            const beds = bedCapacity(gs, pt.company, true);
            var used: u32 = 0;
            for (patients.items) |other| {
                if (other.deployed and other.company == pt.company and other.priority >= pt.priority and other.id != pt.id) used += 1;
            }
            if (used >= beds) gs.person(pt.id).?.wound_heal_day.? += 1;
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
            // runs its own morning round (Stage 12 auto-admit).
            if (!p.medbay_admitted) {
                if (!gs.auto_admit) continue;
                p.medbay_admitted = true;
                try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medbay] {s} {s} admitted (auto)", .{ p.first_name, p.last_name });
            }
            // MASH coverage only helps if their company fields a MASH lance
            // in the field; at home the hospital takes over. Triage consumes
            // a ton of medical supplies from wherever they lie (Stage 9B);
            // an empty dispensary heals half again as slowly.
            const deployed = isDeployed(gs, p);
            var days = healDays(gs, deployed);
            if (!gs.takeStock(gs.siteForForce(p.assigned_force), "medical_supplies", 1)) days = @intCast(types.applyBp(days, tuning.medical.no_supplies_bp));
            if (p.has("iron_man")) days = @max(3, days * 3 / 4); // 12B.6
            // A wound with no record behind it (older saves, event
            // effects): one light internal injury stands in for it.
            if (p.openInjuries() == 0) try p.injuries.append(gs.allocator(), .{ .location = .internal, .severity = 1, .incurred_day = gs.clock.day_index });
            // Every open injury closes on its own day: serious ones take
            // half again as long, crippling ones twice as long. // TUNE
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
            try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medical] {s} {s} returns to duty{s}", .{ p.first_name, p.last_name, if (lasting > 0) " — with a permanent injury on the record" else "" });
        }
    }
}

/// Payday turnover (Stage 12.20; AtB retirement/defection rolls,
/// abstracted): the restless — morale under the line, fatigue over it —
/// with a year on the payroll roll 2d6 against a target that climbs with
/// every complaint; a miss is notice handed in. Long service retires
/// instead. Seats are vacated so the checklist shows the hole. Returns
/// how many left.
pub fn runMonthlyTurnover(gs: *GameState) !u32 {
    const t = tuning.person;
    const day = gs.clock.day_index;
    var notices: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active) continue;
        if (p.tenureMonths(day) < t.turnover_min_tenure_months) continue;
        // Nobody walks out mid-contract: notice waits for the tour to end.
        if (isDeployed(gs, p)) continue;
        const restless = p.restlessness();
        if (restless == 0) continue;
        const roll = gs.rng.roll2d6(.medical);
        if (roll >= t.turnover_target + restless) continue;
        // Notice, not a disappearance (12.25): the inbox offers a raise, a
        // bonus, a replacement from the hall, or the door.
        try @import("contract_events.zig").queueNotice(gs, p.id);
        notices += 1;
    }
    return notices;
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
            try gs.log(.training, .{ .company = gs.companyOf(p.assigned_force) }, "[training] {s} {s} washed out of {s} training ({s})", .{
                p.first_name, p.last_name, @tagName(t.skill), @errorName(err),
            });
            continue;
        };
        try gs.log(.training, .{ .company = gs.companyOf(p.assigned_force) }, "[training] {s} {s} completes {s} training (now {d})", .{
            p.first_name, p.last_name, @tagName(t.skill), p.skill(t.skill).?,
        });
    }
}

/// morale_fatigue phase, weekly: rest at home, grind in the field, and the
/// rotation reset that clears a company's deployment debt.
pub fn runWeeklyRest(gs: *GameState) !void {
    // Best mess level across HQs feeds the recovery rate.
    var best_mess: u8 = 0;
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| {
        best_mess = @max(best_mess, entry.value_ptr.effectiveFacilityLevel(.mess));
    }
    const base_decay: u32 = person_mod.fatigueDecayPerWeek(best_mess);
    const decay: u32 = @intCast(types.applyBp(base_decay, gs.commanderMultBp(.fatigue_recovery)));
    // HR staff keep spirits up at home (Stage 9C). // TUNE
    const hr_bonus: u8 = if (gs.hqs.count() > 0) @intCast(@min(3, gs.hqStaff(gs.hqs.keys()[0], .admin_hr).count / 2)) else 0;

    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status != .active and p.status != .wounded) continue;

        if (isDeployed(gs, p)) {
            const company = gs.companyOf(p.assigned_force);
            const contract = gs.deploymentContract(company);
            const garrison = if (contract) |c| c.kind.isGarrisonClass() else false;
            if (garrison) {
                // Garrison duty is nearly home (12.30): barracks and a town.
                // Fatigue recovers at a share of the home rate — the mess
                // lance stands in for the mess hall — and spirits hold.
                var mess_lance = false;
                if (gs.force(company)) |co| for (co.children.items) |cid| if (gs.force(cid)) |ch| if (ch.echelon == .support_company) for (ch.children.items) |sl| if (gs.force(sl)) |l| if (l.support_kind == .mess and l.units.items.len > 0) {
                    mess_lance = true;
                };
                const field_decay: u32 = @intCast(types.applyBp(person_mod.fatigueDecayPerWeek(if (mess_lance) 1 else 0), tuning.person.garrison_rest_bp));
                p.fatigue -|= @intCast(@min(field_decay, 255));
                if (p.morale < 45 and p.fatigue <= 60) p.morale += 1;
            }
            // Exhaustion grinds morale down, and an empty mess tent grinds
            // it faster (Stage 9B); combat tours get no rest at all. Cool
            // Under Fire (12B.6) shrugs the grind off.
            if (p.fatigue > 60 and p.morale > 0 and !p.has("cool_under_fire")) p.morale -= 1;
            if (gs.force(company)) |co| {
                if (co.supply_shortage_days > 0) p.morale -|= 2;
            }
        } else {
            // On leave: double recovery (Stage 9C.2).
            const on_leave = p.leave_until_day != null and gs.clock.day_index < p.leave_until_day.?;
            p.fatigue -|= @intCast(@min(if (on_leave) decay * 2 else decay, 255));
            // Rested spirits drift toward content (50), mess food helps.
            const target: u8 = 50 + 2 * best_mess + hr_bonus;
            if (p.morale < target) p.morale += 1;
            if (p.fatigue > 60 and p.morale > 0) p.morale -= 1;
        }
    }

    // Rotation reset: an undeployed company whose people are rested clears
    // its deployment debt (ARCH §9.7).
    var fit = gs.forces.iterator();
    while (fit.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon != .company or f.contracts_since_rotation == 0) continue;
        if (gs.deploymentContract(f.id) != null) continue;

        var fatigue_sum: u32 = 0;
        var n: u32 = 0;
        var pit = gs.people.iterator();
        while (pit.next()) |pentry| {
            const p = pentry.value_ptr;
            if (p.status != .active) continue;
            var walk = p.assigned_force;
            const in_company = while (walk != .none) {
                if (walk == f.id) break true;
                walk = (gs.forces.getPtr(walk) orelse break false).parent;
            } else false;
            if (in_company) {
                fatigue_sum += p.fatigue;
                n += 1;
            }
        }
        if (n > 0 and fatigue_sum / n <= 10) {
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

test "12.16: injuries land by location, heal on their own days, and permanent ones scar the record" {
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

    // A wound with no record (legacy) gets one at triage.
    const other = try gs.hirePerson("Ana", "Ruiz", .mekwarrior);
    gs.person(other).?.status = .wounded;
    gs.person(other).?.medbay_admitted = true;
    try runDailyHealing(&gs);
    try std.testing.expectEqual(@as(u32, 1), gs.person(other).?.openInjuries());
}

test "12.20/12.25: the restless hand in notice after a year (an inbox decision), the content stay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1220 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    _ = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
    // Content and fresh: nobody stirs however low the dice.
    gs.clock.day_index = 400;
    try std.testing.expectEqual(@as(u32, 0), try runMonthlyTurnover(&gs));
    // Everyone miserable with a year in: notices land in the inbox, nobody has left yet.
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        e.value_ptr.morale = 5;
        e.value_ptr.fatigue = 90;
    }
    const notices = try runMonthlyTurnover(&gs);
    try std.testing.expect(notices > 0 and notices < gs.people.count());
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
    _ = try @import("../gen/company_gen.zig").generateInto(&fresh, "Alpha");
    var fit = fresh.people.iterator();
    while (fit.next()) |e| e.value_ptr.morale = 0;
    fresh.clock.day_index = 100;
    try std.testing.expectEqual(@as(u32, 0), try runMonthlyTurnover(&fresh));
}

test "12.30: garrison duty recovers fatigue in the field; a combat tour does not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1230 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .paymaster);
    const co = try @import("../gen/company_gen.zig").generateInto(&gs, "Alpha");
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

test "12B.11: medics add field beds and carry patients toward the doctor ratio" {
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
    // A MASH truck: 4 beds, plus one per medic up to doubling it.
    const truck = try gs.addUnit("MASH-27");
    try gs.moveUnitToForce(truck, co);
    try std.testing.expectEqual(@as(u32, 8), bedCapacity(&gs, co, true));
}
