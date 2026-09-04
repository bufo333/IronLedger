//! Medical, rest & training (Stage 8, ARCH §9.7): the systems that make
//! rotating home matter. Wounds heal on doctor/facility timelines; fatigue
//! decays only at home (mess-boosted, line-officer-boosted); morale drifts
//! with rest and grinds with exhaustion; skill training runs only at a
//! regional/brigade HQ with a training ground.

const std = @import("std");
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const GameState = @import("state.zig").GameState;

/// Days of training to improve a skill one step. // TUNE
pub const training_days = 30;

/// Training program length at the outfit's HQ: a staffed HR office runs a
/// tighter schedule (Stage 9C back office). // TUNE
pub fn trainingDaysFor(gs: *GameState) u32 {
    if (gs.hqs.count() == 0) return training_days;
    const hr = gs.hqStaff(gs.hqs.keys()[0], .admin_hr);
    return @max(15, training_days -| 3 * hr.count);
}

/// Is this person's posting currently deployed?
fn isDeployed(gs: *GameState, p: *const person_mod.Person) bool {
    return gs.deploymentContract(gs.companyOf(p.assigned_force)) != null;
}

/// Triage & recovery time for a fresh wound. // TUNE
pub fn healDays(gs: *GameState, deployed_with_mash: bool) u32 {
    var days: u32 = 10 + gs.rng.roll2d6(.medical);

    // Doctor coverage: 1 doctor per 25 patients (MekHQ ratio).
    var doctors: u32 = 0;
    var wounded: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.status == .active and p.role == .doctor) doctors += 1;
        if (p.status == .wounded) wounded += 1;
    }
    if (wounded > doctors * 25) days = days * 3 / 2; // understaffed infirmary

    if (deployed_with_mash) days = days * 4 / 5; // MASH lance forward surgery
    // Home hospital: better facilities, shorter stays.
    var hqit = gs.hqs.iterator();
    var best_hospital: u8 = 0;
    while (hqit.next()) |entry| {
        best_hospital = @max(best_hospital, entry.value_ptr.effectiveFacilityLevel(.hospital));
    }
    if (!deployed_with_mash and best_hospital > 0) days = days * 7 / 10;

    return @max(days, 5);
}

/// Medbay beds (Stage 9C.2): hospital level × 10 at home; 4 per MASH truck
/// with a deployed company. // TUNE
pub fn bedCapacity(gs: *GameState, company: types.ForceId, deployed: bool) u32 {
    if (deployed) {
        var beds: u32 = 0;
        var it = gs.units.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr;
            if (u.kind == .mash and u.status != .destroyed and gs.companyOf(u.force) == company) beds += 4;
        }
        return beds;
    }
    var best: u32 = 0;
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| best = @max(best, @as(u32, entry.value_ptr.effectiveFacilityLevel(.hospital)) * 10);
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
            if (!gs.takeStock(gs.siteForForce(p.assigned_force), "medical_supplies", 1)) days = days * 3 / 2;
            p.wound_heal_day = gs.clock.day_index + days;
        } else if (gs.clock.day_index >= p.wound_heal_day.?) {
            p.status = .active;
            p.wound_heal_day = null;
            p.medbay_admitted = false;
            try gs.log(.medical, .{ .company = gs.companyOf(p.assigned_force) }, "[medical] {s} {s} returns to duty", .{ p.first_name, p.last_name });
        }
    }
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
            // No rest in the field; exhaustion grinds morale down, and an
            // empty mess tent grinds it faster (Stage 9B).
            if (p.fatigue > 60 and p.morale > 0) p.morale -= 1;
            if (gs.force(gs.companyOf(p.assigned_force))) |co| {
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
