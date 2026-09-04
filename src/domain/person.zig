//! Personnel: roles, skills, salaries, status.
//! Mirrors MekHQ `personnel/Person.java`; salaries follow the CamOps table
//! (MekHQ default values). Stage 2 fleshes this out.

const std = @import("std");
const types = @import("types.zig");

pub const Role = enum {
    mekwarrior,
    vehicle_crew,
    aero_pilot,
    ba_trooper,
    infantry,
    tech_mek,
    tech_mechanic,
    tech_aero,
    tech_ba,
    astech,
    doctor,
    medic,
    admin_command,
    admin_logistics,
    admin_transport,
    admin_hr,
    admin_finance,
    dropship_crew,
    jumpship_crew,

    /// CamOps base monthly salary in C-bills (MekHQ defaults), before the
    /// experience multiplier.
    pub fn baseSalary(self: Role) types.CBills {
        return switch (self) {
            .mekwarrior, .aero_pilot => 1_500,
            .vehicle_crew => 900,
            .ba_trooper => 960,
            .infantry => 750,
            .tech_mek, .tech_aero, .tech_ba => 800,
            .tech_mechanic => 640,
            .astech => 400,
            .doctor => 1_500,
            .medic => 400,
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => 500,
            .dropship_crew, .jumpship_crew => 750,
        };
    }

    /// The skill a role's competence is measured by.
    pub fn primarySkill(self: Role) types.SkillType {
        return switch (self) {
            .mekwarrior => .gunnery_mek,
            .vehicle_crew => .gunnery_vee,
            .aero_pilot => .gunnery_aero,
            .ba_trooper, .infantry => .small_arms,
            .tech_mek, .tech_ba => .tech_mek,
            .tech_mechanic => .tech_mechanic,
            .tech_aero => .tech_aero,
            .astech => .astech,
            .doctor => .doctor,
            .medic => .medtech,
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => .admin,
            .dropship_crew, .jumpship_crew => .piloting_aero,
        };
    }

    pub fn isAdmin(self: Role) bool {
        return switch (self) {
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => true,
            else => false,
        };
    }

    pub fn isCombat(self: Role) bool {
        return switch (self) {
            .mekwarrior, .vehicle_crew, .aero_pilot, .ba_trooper, .infantry => true,
            else => false,
        };
    }
};

pub const Status = enum { active, wounded, mia, kia, retired, resigned, pow };

pub const Injury = struct {
    location: enum { head, torso, left_arm, right_arm, left_leg, right_leg, internal },
    severity: u8,
    incurred_day: u32,
    heal_done_day: ?u32 = null,
    doctor: types.PersonId = .none,
    permanent: bool = false,
};

pub const Person = struct {
    id: types.PersonId,
    first_name: []const u8,
    last_name: []const u8,
    callsign: ?[]const u8 = null,
    role: Role,
    secondary_role: ?Role = null,
    xp: u32 = 0,
    status: Status = .active,
    /// Skill levels keyed by SkillType; absent = untrained.
    skills: std.AutoHashMapUnmanaged(types.SkillType, u8) = .empty,
    fatigue: u8 = 0,
    morale: u8 = 50,
    recruited_day: u32 = 0,
    salary_override: ?types.CBills = null,
    assigned_force: types.ForceId = .none,
    /// HQ staff posting (Stage 9C back office): admins here run the HQ.
    posted_hq: types.HqId = .none,
    /// Tech-time budget per week (techs only; Stage 9C.2). // TUNE
    weekly_hours: u16 = 40,
    /// Medbay: higher heals first when beds/doctors are short.
    medbay_priority: u8 = 0,
    /// R&R: unavailable until this day, fatigue decays double.
    leave_until_day: ?u32 = null,
    /// Set by the medical system once a doctor triages the wound (Stage 8).
    wound_heal_day: ?u32 = null,
    /// A wound only starts healing once the player admits them (the
    /// `admit` command) — untreated wounded block the turn (Stage 12).
    medbay_admitted: bool = false,
    /// In-progress training program (regional/brigade HQ only, ARCH §9.7).
    training: ?struct { skill: types.SkillType, done_day: u32 } = null,

    pub fn deinit(self: *Person, alloc: std.mem.Allocator) void {
        self.skills.deinit(alloc);
    }

    /// Fit for duty today: active, not on leave.
    pub fn isAvailable(self: *const Person, day: u32) bool {
        if (self.status != .active) return false;
        if (self.leave_until_day) |until| if (day < until) return false;
        return true;
    }

    pub fn skill(self: *const Person, s: types.SkillType) ?u8 {
        return self.skills.get(s);
    }

    /// Combat crews rate on gunnery+piloting; support roles on their primary
    /// skill counted twice (so level 4 ⇒ Regular, 3 ⇒ Veteran, matching the
    /// combat convention). Refined in Stage 2.
    pub fn experience(self: *const Person) types.ExperienceLevel {
        return switch (self.role) {
            .mekwarrior => .fromCombatSkills(self.skill(.gunnery_mek) orelse 7, self.skill(.piloting_mek) orelse 8),
            .vehicle_crew => .fromCombatSkills(self.skill(.gunnery_vee) orelse 7, self.skill(.driving_vee) orelse 8),
            .aero_pilot => .fromCombatSkills(self.skill(.gunnery_aero) orelse 7, self.skill(.piloting_aero) orelse 8),
            .ba_trooper, .infantry => fromSupportSkill(self.skill(.small_arms)),
            .tech_mek, .tech_ba => fromSupportSkill(self.skill(.tech_mek)),
            .tech_mechanic => fromSupportSkill(self.skill(.tech_mechanic)),
            .tech_aero => fromSupportSkill(self.skill(.tech_aero)),
            .astech => fromSupportSkill(self.skill(.astech)),
            .doctor => fromSupportSkill(self.skill(.doctor)),
            .medic => fromSupportSkill(self.skill(.medtech)),
            .admin_command, .admin_logistics, .admin_transport, .admin_hr, .admin_finance => fromSupportSkill(self.skill(.admin)),
            .dropship_crew, .jumpship_crew => .regular,
        };
    }

    fn fromSupportSkill(level: ?u8) types.ExperienceLevel {
        const l = level orelse 7;
        return types.ExperienceLevel.fromCombatSkills(l, l);
    }

    /// Monthly salary: CamOps base × experience multiplier, unless overridden.
    pub fn monthlySalary(self: *const Person) types.CBills {
        if (self.salary_override) |s| return s;
        return types.applyBp(self.role.baseSalary(), self.experience().salaryMultBp());
    }
};

// ------------------------------------------------------------ xp progression
// XP is earned anywhere (monthly service, scenarios, tech work); spending it
// to improve a skill happens only through a training program at a regional/
// brigade HQ (ARCH §9.7, Stage 8 wires the gate). The machinery lives here.

/// XP cost to improve a skill TO `new_level` (lower level = better, combat
/// convention). Costs double per step toward mastery. // TUNE
pub fn improveCost(new_level: u8) u32 {
    if (new_level >= 5) return 4;
    return @as(u32, 8) << @intCast(4 - new_level);
}

pub const TrainError = error{ NotTrained, InsufficientXp, AlreadyMastered };

/// Spend XP to improve an existing skill by one step. The Stage 8 training
/// system calls this after validating HQ + program time.
pub fn spendXpToImprove(p: *Person, skill_type: types.SkillType) TrainError!void {
    const current = p.skill(skill_type) orelse return TrainError.NotTrained;
    if (current == 0) return TrainError.AlreadyMastered;
    const cost = improveCost(current - 1);
    if (p.xp < cost) return TrainError.InsufficientXp;
    p.xp -= cost;
    p.skills.putAssumeCapacity(skill_type, current - 1);
}

test "xp costs double toward mastery" {
    try std.testing.expectEqual(@as(u32, 4), improveCost(5));
    try std.testing.expectEqual(@as(u32, 8), improveCost(4));
    try std.testing.expectEqual(@as(u32, 16), improveCost(3));
    try std.testing.expectEqual(@as(u32, 32), improveCost(2));
    try std.testing.expectEqual(@as(u32, 128), improveCost(0));
}

test "spending xp improves a skill and drains the pool" {
    var p: Person = .{ .id = @enumFromInt(1), .first_name = "Kai", .last_name = "Allard", .role = .mekwarrior };
    defer p.deinit(std.testing.allocator);
    try p.skills.put(std.testing.allocator, .gunnery_mek, 4);
    p.xp = 20;

    try std.testing.expectError(TrainError.NotTrained, spendXpToImprove(&p, .piloting_mek));
    try std.testing.expectError(TrainError.NotTrained, spendXpToImprove(&p, .doctor));

    try spendXpToImprove(&p, .gunnery_mek); // 4 → 3 costs 16
    try std.testing.expectEqual(@as(?u8, 3), p.skill(.gunnery_mek));
    try std.testing.expectEqual(@as(u32, 4), p.xp);
    try std.testing.expectError(TrainError.InsufficientXp, spendXpToImprove(&p, .gunnery_mek));
}

// ------------------------------------------------------- fatigue (ARCH §9.7)
// Fatigue accrues when a contract ends without rotating through a regional
// HQ, never decays in the field, and decays weekly at a regional HQ. It caps
// at 100: degraded, never spiraling. Applied to every person attached to the
// deploying company.

pub const max_fatigue = 100;

/// Fatigue gained at the end of a contract, scaled by how long it ran and
/// how hard it fought: a quiet garrison wears lightly, a bloody raid
/// campaign wears hard. // TUNE
pub fn contractFatigueGain(length_months: u8, battles_fought: u8, casualties_pct: u8) u8 {
    const gain: u32 = @as(u32, length_months) +
        @as(u32, battles_fought) * 3 +
        @as(u32, casualties_pct) / 5;
    return @intCast(@min(gain, 50));
}

/// Weekly fatigue recovery at a regional/brigade HQ; a better mess means
/// better R&R. In the field: zero. // TUNE
pub fn fatigueDecayPerWeek(mess_level: u8) u8 {
    return 5 + 2 * mess_level;
}

pub fn applyFatigue(current: u8, gain: u8) u8 {
    return @min(max_fatigue, @as(u32, current) + gain);
}

test "quiet garrisons wear lightly, bloody campaigns wear hard" {
    const garrison = contractFatigueGain(18, 1, 2); // long but quiet
    const raid = contractFatigueGain(3, 8, 25); // short and vicious
    try std.testing.expect(raid > garrison);
    try std.testing.expectEqual(@as(u8, 50), contractFatigueGain(24, 20, 100)); // capped per contract
    try std.testing.expectEqual(@as(u8, max_fatigue), applyFatigue(90, 40)); // capped overall
}

test "the mess hall earns its keep at home" {
    try std.testing.expect(fatigueDecayPerWeek(3) > fatigueDecayPerWeek(0));
}

test "salary follows CamOps table with experience multiplier" {
    var p: Person = .{ .id = @enumFromInt(1), .first_name = "Natasha", .last_name = "K", .role = .mekwarrior };
    defer p.deinit(std.testing.allocator);
    try p.skills.put(std.testing.allocator, .gunnery_mek, 2);
    try p.skills.put(std.testing.allocator, .piloting_mek, 3);
    try std.testing.expectEqual(types.ExperienceLevel.elite, p.experience());
    try std.testing.expectEqual(@as(types.CBills, 4_800), p.monthlySalary()); // 1500 × 3.2
}
