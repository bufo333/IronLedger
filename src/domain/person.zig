//! Personnel: roles, skills, salaries, status.
//! Mirrors MekHQ `personnel/Person.java`; salaries follow the CamOps table
//! (MekHQ default values). Stage 2 fleshes this out.

const std = @import("std");
const tuning = @import("tuning.zig").t;
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

    pub fn isTech(self: Role) bool {
        return switch (self) {
            .tech_mek, .tech_mechanic, .tech_aero, .tech_ba => true,
            else => false,
        };
    }
};

pub const Status = enum { active, wounded, mia, kia, retired, resigned, pow, released };

pub const InjuryLocation = enum { head, torso, left_arm, right_arm, left_leg, right_leg, internal };

/// One wound (Stage 12.16, MekHQ advanced medical `Injury`): where, how
/// bad (1 light … 3 crippling), when, and when a doctor expects it closed.
/// A permanent injury stays on the record after it heals and costs the
/// crew a point of skill (`permanentPenalty`).
pub const Injury = struct {
    location: InjuryLocation,
    severity: u8,
    incurred_day: u32,
    heal_done_day: ?u32 = null,
    doctor: types.PersonId = .none,
    permanent: bool = false,
    healed: bool = false,
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
    /// Tech-time budget per week (techs only; Stage 9C.2).
    weekly_hours: u16 = tuning.person.weekly_hours,
    /// Medbay: higher heals first when beds/doctors are short.
    medbay_priority: u8 = 0,
    /// R&R: unavailable until this day, fatigue decays double.
    leave_until_day: ?u32 = null,
    /// Set by the medical system once a doctor triages the wound (Stage 8):
    /// the day the last open injury closes (mirror of `healDoneDay`).
    wound_heal_day: ?u32 = null,
    /// Rank (12B.4): set by seat and experience each payday unless pinned
    /// by `promote`. Scales pay through `monthlySalary`.
    rank: @import("rank.zig").Rank = .private,
    rank_pinned: bool = false,
    /// Service record (12B.5): kill credits, battles fought, tours served,
    /// tours graded outstanding, and the awards earned (keys into
    /// data/tables/awards.zon).
    kills: u32 = 0,
    kill_bv: u32 = 0,
    battles: u32 = 0,
    tours: u32 = 0,
    outstanding_tours: u32 = 0,
    awards: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Special abilities (12B.6), keys into data/tables/abilities.zon; Edge
    /// is spent once per contract.
    abilities: std.ArrayListUnmanaged([]const u8) = .empty,
    edge_spent: bool = false,
    /// House of origin (12B.7): set for prisoners of war, empty for your own.
    faction: []const u8 = "",
    /// Shares in contract profit (12C.3, AtB shares): refreshed each payday
    /// from tenure, founding and rank; paid out pro rata at completion.
    shares: u8 = 0,
    /// Per-location injuries (Stage 12.16); open ones keep the person in
    /// the medbay, permanent ones stay on the record.
    injuries: std.ArrayListUnmanaged(Injury) = .empty,
    /// A wound only starts healing once the player admits them (the
    /// `admit` command) — untreated wounded block the turn (Stage 12).
    medbay_admitted: bool = false,
    /// In-progress training program (regional/brigade HQ only, ARCH §9.7).
    training: ?struct { skill: types.SkillType, done_day: u32 } = null,

    pub fn deinit(self: *Person, alloc: std.mem.Allocator) void {
        self.skills.deinit(alloc);
        self.injuries.deinit(alloc);
        self.awards.deinit(alloc);
        self.abilities.deinit(alloc);
    }

    pub fn has(self: *const Person, ability_key: []const u8) bool {
        for (self.abilities.items) |a| if (std.mem.eql(u8, a, ability_key)) return true;
        return false;
    }

    pub fn hasAward(self: *const Person, key: []const u8) bool {
        for (self.awards.items) |a| if (std.mem.eql(u8, a, key)) return true;
        return false;
    }

    /// The counter an award checks (12B.5).
    pub fn counter(self: *const Person, kind: @import("award.zig").Counter, day: u32) u32 {
        return switch (kind) {
            .kills => self.kills,
            .kill_bv => self.kill_bv,
            .battles => self.battles,
            .wounded => @intCast(self.injuries.items.len + @as(usize, @intFromBool(self.status == .wounded))),
            .tours => self.tours,
            .outstanding_tours => self.outstanding_tours,
            .service_years => self.tenureMonths(day) / 12,
        };
    }

    /// Injuries still healing.
    pub fn openInjuries(self: *const Person) u32 {
        var n: u32 = 0;
        for (self.injuries.items) |i| if (!i.healed) {
            n += 1;
        };
        return n;
    }

    /// The day the last open injury closes (null: nothing triaged yet).
    pub fn healDoneDay(self: *const Person) ?u32 {
        var latest: ?u32 = null;
        for (self.injuries.items) |i| {
            if (i.healed) continue;
            const d = i.heal_done_day orelse continue;
            latest = @max(latest orelse 0, d);
        }
        return latest;
    }

    /// Lasting damage (MekHQ advanced medical modifiers, approximated):
    /// every permanent head or internal injury costs one skill point in the
    /// cockpit. // TUNE
    pub fn permanentPenalty(self: *const Person) u8 {
        var n: u8 = 0;
        for (self.injuries.items) |i| {
            if (i.permanent and (i.location == .head or i.location == .internal)) n += 1;
        }
        return n;
    }

    /// Months on the payroll.
    pub fn tenureMonths(self: *const Person, day: u32) u32 {
        return (day -| self.recruited_day) / 30;
    }

    /// Restless (Stage 12.20): low morale or deep fatigue — the flags the
    /// turnover roll counts. 0 = content.
    pub fn restlessness(self: *const Person) u8 {
        var n: u8 = 0;
        if (self.morale < tuning.person.restless_morale) n += 1;
        if (self.fatigue > tuning.person.exhausted_fatigue) n += 1;
        // A stake in the outfit (12C.3) keeps people at the table.
        return n -| (self.shares / tuning.person.shares_per_restless);
    }

    /// On the books from day one (12C.3): founders hold more shares and
    /// (12C.5) stand by the outfit.
    pub fn isFounder(self: *const Person) bool {
        return self.recruited_day == 0;
    }

    /// What this person's stake should be today (12C.3).
    pub fn sharesDue(self: *const Person, day: u32) u8 {
        const t = tuning.person;
        if (self.status != .active and self.status != .wounded) return 0;
        const eligible = self.role.isCombat() or self.role.isTech();
        if (!eligible) return 0;
        var n: u8 = 0;
        if (self.isFounder()) n = t.shares_founder else if (self.tenureMonths(day) >= t.shares_tenure_months) n = t.shares_base;
        if (n == 0) return 0;
        const rank_v = @intFromEnum(self.rank);
        const sgt = @intFromEnum(@import("rank.zig").Rank.sergeant);
        if (rank_v > sgt) n += rank_v - sgt;
        return n;
    }

    /// CamOps fatigue band (12C.1): what tiredness costs in the cockpit.
    pub fn fatigueBand(self: *const Person) FatigueBand {
        const t = tuning.person;
        if (self.fatigue >= t.fatigue_spent) return .spent;
        if (self.fatigue >= t.exhausted_fatigue) return .exhausted;
        if (self.fatigue >= t.fatigue_tired) return .tired;
        return .fresh;
    }

    /// Points added to gunnery and piloting targets by fatigue (12C.1).
    pub fn fatiguePenalty(self: *const Person) u8 {
        return self.fatigueBand().penalty();
    }

    /// Spent: unfit for a seat while anyone fresher is free (12C.1).
    pub fn isUnfit(self: *const Person) bool {
        return self.fatigueBand() == .spent;
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
        return types.applyBp(types.applyBp(self.role.baseSalary(), self.experience().salaryMultBp()), self.rank.payBp());
    }

    /// What the outfit owes when this person leaves (12C.2): a month's
    /// pay per full year served, capped. Under a year: nothing.
    pub fn severance(self: *const Person, day: u32) types.CBills {
        const t = tuning.person;
        const years = self.tenureMonths(day) / 12;
        const months = @min(years * t.severance_months_per_year, t.severance_cap_months);
        const full = self.monthlySalary() * @as(types.CBills, months);
        // Shareholders (12C.3) already hold a stake: half the payout.
        return if (self.shares > 0) @divTrunc(full, 2) else full;
    }

    /// "Sgt. Lori Kalmar" for rosters and AARs.
    pub fn rankedName(self: *const Person, alloc: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ self.rank.abbrev(), self.first_name, self.last_name });
    }
};

// ------------------------------------------------------------ xp progression
// XP is earned anywhere (monthly service, scenarios, tech work); spending it
// to improve a skill happens only through a training program at a regional/
// brigade HQ (ARCH §9.7, Stage 8 wires the gate). The machinery lives here.

/// XP cost to improve a skill TO `new_level` (lower level = better, combat
/// convention). Costs double per step toward mastery.
pub fn improveCost(new_level: u8) u32 {
    if (new_level >= 5) return tuning.person.improve_cost_base / 2;
    return tuning.person.improve_cost_base << @intCast(4 - new_level);
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

pub const max_fatigue = tuning.person.max_fatigue;

/// CamOps fatigue bands (12C.1). MekHQ: `Fatigue` option thresholds.
pub const FatigueBand = enum {
    fresh,
    tired,
    exhausted,
    spent,

    pub fn penalty(self: FatigueBand) u8 {
        return switch (self) {
            .fresh => 0,
            .tired => 1,
            .exhausted => 2,
            .spent => 3,
        };
    }

    /// Markup colour for the TUI: green, amber, amber, red.
    pub fn markup(self: FatigueBand) []const u8 {
        return switch (self) {
            .fresh => "{g}",
            .tired => "{a}",
            .exhausted => "{a}",
            .spent => "{c}",
        };
    }
};

test "12C.3: shares from tenure, founding and rank; they calm restlessness and halve severance" {
    const t = tuning.person;
    var p: Person = .{ .id = @enumFromInt(1), .first_name = "A", .last_name = "B", .role = .mekwarrior, .recruited_day = 100 };
    try std.testing.expectEqual(@as(u8, 0), p.sharesDue(200)); // under a year, no stake
    try std.testing.expectEqual(t.shares_base, p.sharesDue(100 + t.shares_tenure_months * 30));
    p.rank = .lieutenant; // two above sergeant
    try std.testing.expectEqual(t.shares_base + 2, p.sharesDue(100 + t.shares_tenure_months * 30));
    var f: Person = .{ .id = @enumFromInt(2), .first_name = "F", .last_name = "O", .role = .tech_mek, .recruited_day = 0 };
    try std.testing.expectEqual(t.shares_founder, f.sharesDue(10));
    var clerk: Person = .{ .id = @enumFromInt(3), .first_name = "C", .last_name = "K", .role = .admin_hr, .recruited_day = 0 };
    try std.testing.expectEqual(@as(u8, 0), clerk.sharesDue(1000));
    // Three shares cancel one restless flag; a stake halves severance.
    f.morale = 0;
    f.fatigue = 100;
    try std.testing.expectEqual(@as(u8, 2), f.restlessness());
    f.shares = t.shares_per_restless;
    try std.testing.expectEqual(@as(u8, 1), f.restlessness());
    const day = 24 * 30;
    const without = f.monthlySalary() * 2;
    try std.testing.expectEqual(@divTrunc(without, 2), f.severance(day));
    f.shares = 0;
    try std.testing.expectEqual(without, f.severance(day));
}

test "12C.1: fatigue bands and their penalties" {
    var p: Person = .{ .id = @enumFromInt(1), .first_name = "A", .last_name = "B", .role = .mekwarrior };
    p.fatigue = 0;
    try std.testing.expectEqual(FatigueBand.fresh, p.fatigueBand());
    p.fatigue = tuning.person.fatigue_tired;
    try std.testing.expectEqual(@as(u8, 1), p.fatiguePenalty());
    p.fatigue = tuning.person.exhausted_fatigue;
    try std.testing.expectEqual(@as(u8, 2), p.fatiguePenalty());
    p.fatigue = tuning.person.fatigue_spent;
    try std.testing.expectEqual(@as(u8, 3), p.fatiguePenalty());
    try std.testing.expect(p.isUnfit());
}

/// Fatigue gained at the end of a contract, scaled by how long it ran and
/// how hard it fought: a quiet garrison wears lightly, a bloody raid
/// campaign wears hard.
pub fn contractFatigueGain(length_months: u8, battles_fought: u8, casualties_pct: u8) u8 {
    return contractFatigueGainFor(length_months, battles_fought, casualties_pct, false);
}

/// Garrison-class tours (12.30) wear a third as much per month: barracks,
/// hot food and a town, not a laager.
pub fn contractFatigueGainFor(length_months: u8, battles_fought: u8, casualties_pct: u8, garrison: bool) u8 {
    const months: u32 = if (garrison) @as(u32, length_months) / tuning.person.garrison_tour_months_divisor else length_months;
    const gain: u32 = months +
        @as(u32, battles_fought) * tuning.person.fatigue_per_battle +
        @as(u32, casualties_pct) / tuning.person.fatigue_casualty_divisor;
    return @intCast(@min(gain, tuning.person.fatigue_contract_cap));
}

/// Weekly fatigue recovery at a regional/brigade HQ; a better mess means
/// better R&R. In the field: zero.
pub fn fatigueDecayPerWeek(mess_level: u8) u8 {
    return tuning.person.fatigue_decay_base + tuning.person.fatigue_decay_per_mess * mess_level;
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

test "12.30: a long quiet garrison banks a third of a combat tour's fatigue" {
    try std.testing.expect(contractFatigueGainFor(24, 0, 0, true) < contractFatigueGainFor(24, 0, 0, false));
    try std.testing.expectEqual(@as(u8, 8), contractFatigueGainFor(24, 0, 0, true));
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

test "injuries: open ones set the discharge day, permanent head wounds cost skill" {
    var p: Person = .{ .id = @enumFromInt(1), .first_name = "A", .last_name = "B", .role = .mekwarrior };
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, null), p.healDoneDay());
    try p.injuries.append(std.testing.allocator, .{ .location = .left_leg, .severity = 1, .incurred_day = 0, .heal_done_day = 12 });
    try p.injuries.append(std.testing.allocator, .{ .location = .head, .severity = 3, .incurred_day = 0, .heal_done_day = 30, .permanent = true });
    try std.testing.expectEqual(@as(u32, 2), p.openInjuries());
    try std.testing.expectEqual(@as(?u32, 30), p.healDoneDay());
    p.injuries.items[1].healed = true;
    try std.testing.expectEqual(@as(?u32, 12), p.healDoneDay());
    try std.testing.expectEqual(@as(u8, 1), p.permanentPenalty());
}
