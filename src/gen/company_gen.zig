//! Company generation rolls and the manning table, following MekHQ's AtB
//! company generator (`universe/generators/companyGenerators/`):
//! experience and weight-class rolls on the caller's stream, and the
//! support staff a hangar and roster need. Pure: the starter company that
//! uses them is built in `sim/starter_company.zig`.
const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const force = @import("../domain/force.zig");
const person = @import("../domain/person.zig");
const chassis = @import("../domain/chassis.zig");
const rng_mod = @import("../sim/rng.zig");

/// Experience distribution for generated pilots (AtB-style weighted roll on
/// 2d6: most crews Regular, tails Green/Veteran, Elite rare).
pub fn rollExperience(rng: *rng_mod.Rng, stream: rng_mod.Stream) types.ExperienceLevel {
    return rollExperienceWithBonus(rng, stream, 0);
}

pub fn rollExperienceWithBonus(rng: *rng_mod.Rng, stream: rng_mod.Stream, bonus: i32) types.ExperienceLevel {
    const roll = @as(i32, rng.roll2d6(stream)) + bonus;
    if (roll <= 5) return .green;
    if (roll <= 9) return .regular;
    if (roll <= 11) return .veteran;
    return .elite;
}

/// Support staff requirements for a hangar of `mek_count` meks, MekHQ-style:
/// one tech per mek, six astechs per tech (a full tech team), plus admin,
/// medical, and command overhead.
pub const SupportStaff = struct {
    techs: u32,
    astechs: u32,
    doctors: u32,
    medics: u32,
    admins: u32,

    pub fn total(self: SupportStaff) u32 {
        return self.techs + self.astechs + self.doctors + self.medics + self.admins;
    }
};

/// What a company fields, counted for the manning table.
pub const HullTally = struct { meks: u32 = 0, vehicles: u32 = 0, platoons: u32 = 0, fighters: u32 = 0, mash: u32 = 0 };

pub const StaffNeed = struct { role: person.Role, need: u32, why: []const u8 };

/// The manning table: every role a company of this shape wants,
/// and why. The starter generator hires to it and `personnel.manningNeeds`
/// reads it back for a raised company, so the two never drift.
pub fn staffNeeds(t: HullTally) [14]StaffNeed {
    const combat = t.meks + t.vehicles + t.platoons;
    const staff = supportStaffFor(t.meks, combat);
    return .{
        .{ .role = .mekwarrior, .need = t.meks, .why = "one per mek" },
        .{ .role = .vehicle_crew, .need = t.vehicles, .why = "one per truck, rig or ambulance" },
        .{ .role = .infantry, .need = t.platoons, .why = "one per security platoon" },
        .{ .role = .aero_pilot, .need = t.fighters, .why = "one per fighter" },
        .{ .role = .tech_aero, .need = t.fighters, .why = "one per fighter" },
        .{ .role = .tech_mek, .need = staff.techs, .why = "one per mek" },
        .{ .role = .astech, .need = staff.astechs, .why = "six per mek tech (hours)" },
        .{ .role = .tech_mechanic, .need = t.vehicles / 2, .why = "one per two vehicles" },
        .{ .role = .doctor, .need = staff.doctors, .why = "one per 25 combat crew" },
        .{ .role = .medic, .need = staff.medics + (if (t.mash > 0) @as(u32, 4) else 0), .why = "each covers 5 patients and staffs a MASH bed; four per doctor, four more with the MASH lance" },
        .{ .role = .admin_command, .need = 1, .why = "company office" },
        .{ .role = .admin_logistics, .need = 1, .why = "company office" },
        .{ .role = .admin_transport, .need = 1, .why = "company office" },
        .{ .role = .admin_hr, .need = staff.admins -| 3, .why = "one per 10 combat crew beyond the office" },
    };
}

pub fn supportStaffFor(mek_count: u32, combat_personnel: u32) SupportStaff {
    const t = @import("../domain/tuning.zig").t.generation;
    const techs = mek_count;
    const doctors = std.math.divCeil(u32, combat_personnel, t.crew_per_doctor) catch unreachable;
    return .{
        .techs = techs,
        .astechs = techs * t.astechs_per_tech,
        .doctors = doctors,
        .medics = doctors * t.medics_per_doctor,
        // Command, logistics, transport, HR — one each per company minimum.
        .admins = @max(t.admins_min, combat_personnel / t.crew_per_admin),
    };
}

/// RAT weight-class roll for one mek, 2d6 (AtB flavor: mediums dominate a
/// line company, assaults are prizes; bands in tuning.generation).
pub fn rollWeightClass(rng: *rng_mod.Rng, stream: rng_mod.Stream) chassis.WeightClass {
    const roll = rng.roll2d6(stream);
    const tg = tuning.generation;
    return if (roll <= tg.weight_light_max) .light else if (roll <= tg.weight_medium_max) .medium else if (roll <= tg.weight_heavy_max) .heavy else .assault;
}

/// The starter company's line lances: lights and mediums only, so
/// the founding level-1 mek bay can rebuild everything the outfit fields;
/// heavies and assaults come later, off the boards and the battlefield.
pub fn starterWeightClass(rng: *rng_mod.Rng) chassis.WeightClass {
    return if (rng.roll2d6(.generation) <= tuning.generation.starter_light_max) .light else .medium;
}

/// Max tonnage for the recon lance's scout meks.
pub const scout_max_tonnage = tuning.generation.scout_max_tonnage;

test "a mek company needs a real support tail" {
    const staff = supportStaffFor(12, 12);
    try std.testing.expectEqual(@as(u32, 12), staff.techs);
    try std.testing.expectEqual(@as(u32, 72), staff.astechs);
    try std.testing.expectEqual(@as(u32, 1), staff.doctors);
    try std.testing.expect(staff.total() > 12); // the tail outnumbers the teeth
}

test "experience roll is 2d6-shaped" {
    var rng = rng_mod.Rng.init(1234);
    var counts = [_]u32{0} ** 4;
    for (0..10_000) |_| counts[@intFromEnum(rollExperience(&rng, .generation))] += 1;
    // Regular (6–9 on 2d6) must dominate; Elite (12) must be rare but present.
    try std.testing.expect(counts[1] > counts[0]);
    try std.testing.expect(counts[1] > counts[2]);
    try std.testing.expect(counts[3] > 0 and counts[3] < counts[2]);
}

test "the manning table is one function: a raised company reads the generator's ratios back" {
    const needs = staffNeeds(.{ .meks = 16, .vehicles = 12, .platoons = 4 });
    var techs: u32 = 0;
    var admins: u32 = 0;
    for (needs) |n| {
        if (n.role == .tech_mek) techs = n.need;
        if (n.role.isAdmin()) admins += n.need;
    }
    try std.testing.expectEqual(@as(u32, 16), techs);
    try std.testing.expectEqual(supportStaffFor(16, 32).admins, admins);
}
