//! Company autogeneration, following MekHQ's AtB company generator
//! (`universe/generators/companyGenerators/`): a mek company is 3 lances of
//! 4 meks, with officers, techs sized to the hangar, and admin/medical staff
//! sized to the roster. Stage 3 adds chassis selection by faction/era/weight
//! tables and full person generation.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const force = @import("../domain/force.zig");
const person = @import("../domain/person.zig");
const chassis = @import("../domain/chassis.zig");
const rng_mod = @import("../sim/rng.zig");
const GameState = @import("../sim/state.zig").GameState;

/// Experience distribution for generated pilots (AtB-style weighted roll on
/// 2d6: most crews Regular, tails Green/Veteran, Elite rare).
pub fn rollExperience(rng: *rng_mod.Rng) types.ExperienceLevel {
    return rollExperienceWithBonus(rng, 0);
}

pub fn rollExperienceWithBonus(rng: *rng_mod.Rng, bonus: i32) types.ExperienceLevel {
    const roll = @as(i32, rng.roll2d6(.generation)) + bonus;
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

/// The manning table (12B.11): every role a company of this shape wants,
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
pub fn rollWeightClass(rng: *rng_mod.Rng) chassis.WeightClass {
    const roll = rng.roll2d6(.generation);
    const tg = tuning.generation;
    return if (roll <= tg.weight_light_max) .light else if (roll <= tg.weight_medium_max) .medium else if (roll <= tg.weight_heavy_max) .heavy else .assault;
}

/// The starter company's line lances (12E.1): lights and mediums only, so
/// the founding level-1 mek bay can rebuild everything the outfit fields;
/// heavies and assaults come later, off the boards and the battlefield.
pub fn starterWeightClass(rng: *rng_mod.Rng) chassis.WeightClass {
    return if (rng.roll2d6(.generation) <= tuning.generation.starter_light_max) .light else .medium;
}

/// Max tonnage for the recon lance's scout meks.
pub const scout_max_tonnage = tuning.generation.scout_max_tonnage;

/// Generate a full starter company into the campaign:
///   - 3 line lances × 4 meks (light/medium RAT rolls, 12E.1) with pilots
///   - a 4th Recon Lance of light scouts (≤40t, mostly 20–35t)
///   - an attached "Omega Company" support echelon: salvage, MASH (with
///     medics), logistics, and security lances (ARCH §9.3)
///   - the support tail (techs/mechanics/astechs/medical/admin) on staff
/// Starting forces are granted, not purchased — MekHQ's company generator
/// likewise hands you the TO&E (financing options later).
pub fn generateInto(gs: *GameState, name: []const u8) !types.ForceId {
    const company_id = try gs.createForce(name, .company, .none);
    var scratch: [32]*const chassis.Chassis = undefined;

    // Line lances: rolled weight class, uniform within class.
    const lance_names = [_][]const u8{ "1st Lance", "2nd Lance", "3rd Lance" };
    for (lance_names) |lance_name| {
        const lance_id = try gs.createForce(lance_name, .lance, company_id);
        for (0..force.lance_size) |_| {
            const class = starterWeightClass(&gs.rng);
            // The house you come from fields what it fields (12B.8 RAT).
            const home: []const u8 = if (gs.commander) |c| c.origin.key() else "PER";
            const design = @import("../domain/rat.zig").roll(&gs.rng, .generation, home, class, gs.clock.date.year);

            const unit_id = try gs.addUnit(design.key);
            const pilot_id = try gs.recruitGenerated(.mekwarrior);
            try gs.assignUnit(unit_id, lance_id, pilot_id);
        }
    }

    // Recon lance: light scouts only — feeds recon_quality in autoresolve.
    const recon_id = try gs.createForce("Recon Lance", .lance, company_id);
    gs.force(recon_id).?.role = .scouting;
    const scouts = chassis.scoutPool(scout_max_tonnage, gs.clock.date.year, &scratch);
    for (0..force.lance_size) |_| {
        const design = scouts[gs.rng.random(.generation).uintLessThan(usize, scouts.len)];
        const unit_id = try gs.addUnit(design.key);
        const pilot_id = try gs.recruitGenerated(.mekwarrior);
        try gs.assignUnit(unit_id, recon_id, pilot_id);
    }

    // Omega Company: the support echelon that wins battles (ARCH §9.3).
    const omega_id = try gs.createForce("Omega Company", .support_company, company_id);
    const support_plan = [_]struct {
        name: []const u8,
        kind: force.SupportLanceKind,
        chassis_key: []const u8,
        crew_role: person.Role,
        attached_medics: u8,
    }{
        .{ .name = "Salvage Lance", .kind = .salvage, .chassis_key = "SVT-1", .crew_role = .vehicle_crew, .attached_medics = 0 },
        .{ .name = "MASH Lance", .kind = .mash, .chassis_key = "MASH-27", .crew_role = .vehicle_crew, .attached_medics = 4 },
        .{ .name = "Logistics Lance", .kind = .transport, .chassis_key = "CGT-3", .crew_role = .vehicle_crew, .attached_medics = 0 },
        .{ .name = "Security Lance", .kind = .security, .chassis_key = "SEC-PLT", .crew_role = .infantry, .attached_medics = 0 },
    };
    for (support_plan) |plan| {
        const lance_id = try gs.createForce(plan.name, .support_lance, omega_id);
        gs.force(lance_id).?.support_kind = plan.kind;
        for (0..force.lance_size) |_| {
            const unit_id = try gs.addUnit(plan.chassis_key);
            const crew_id = try gs.recruitGenerated(plan.crew_role);
            try gs.assignUnit(unit_id, lance_id, crew_id);
        }
        for (0..plan.attached_medics) |_| {
            const id = try gs.recruitGenerated(.medic);
            gs.person(id).?.assigned_force = lance_id;
        }
    }

    // The tail: staff posted to the company (not a lance). 16 meks now, and
    // mechanics for the truck park (1 per 2 vehicles).
    // Hire the manning table's support half; the crews and the MASH
    // lance's own medics were recruited with their hulls above.
    const tally: HullTally = .{ .meks = force.lance_size * 4, .vehicles = force.lance_size * 3, .platoons = force.lance_size };
    for (staffNeeds(tally)) |entry| {
        if (entry.role.isCombat() or entry.role == .tech_aero) continue;
        for (0..entry.need) |_| {
            const id = try gs.recruitGenerated(entry.role);
            gs.person(id).?.assigned_force = company_id;
        }
    }

    // Every hull gets its tech (Stage 9C.2): the tail is sized for it.
    _ = try gs.autoAssign(company_id);
    _ = try @import("../sim/personnel.zig").refreshRanks(gs); // 12B.4: officers by seat
    return company_id;
}

test "a mek company needs a real support tail" {
    const staff = supportStaffFor(12, 12);
    try std.testing.expectEqual(@as(u32, 12), staff.techs);
    try std.testing.expectEqual(@as(u32, 72), staff.astechs);
    try std.testing.expectEqual(@as(u32, 1), staff.doctors);
    try std.testing.expect(staff.total() > 12); // the tail outnumbers the teeth
}

test "generateInto builds the full starter force and is deterministic" {
    var hashes: [2]u64 = undefined;
    for (&hashes) |*out| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 31337 });
        defer gs.deinit();
        const co = try generateInto(&gs, "Able Company");

        // 1 company + 4 mek lances + Omega + 4 support lances = 10 forces;
        // 16 meks + 16 support units = 32 units.
        try std.testing.expectEqual(@as(usize, 10), gs.forces.count());
        try std.testing.expectEqual(@as(usize, 32), gs.units.count());

        const company = gs.force(co).?;
        try std.testing.expectEqual(@as(usize, 5), company.children.items.len);

        var recon_seen = false;
        var support_lances: u32 = 0;
        for (company.children.items) |child_id| {
            const child = gs.force(child_id).?;
            switch (child.echelon) {
                .lance => {
                    try std.testing.expectEqual(@as(usize, 4), child.units.items.len);
                    for (child.units.items) |uid| {
                        const u = gs.unit(uid).?;
                        try std.testing.expect(u.pilot != .none);
                        try std.testing.expectEqual(child_id, gs.person(u.pilot).?.assigned_force);
                    }
                    if (child.role == .scouting) {
                        recon_seen = true;
                        // Scout lance: light meks only, ≤40t.
                        for (child.units.items) |uid| {
                            const design = @import("../domain/chassis.zig").find(gs.unit(uid).?.chassis_key).?;
                            try std.testing.expect(design.tonnage <= scout_max_tonnage);
                            try std.testing.expectEqual(@import("../domain/unit.zig").UnitKind.mek, design.kind);
                        }
                    }
                },
                .support_company => {
                    // Omega: 4 typed support lances of 4 units each.
                    try std.testing.expectEqual(@as(usize, 4), child.children.items.len);
                    for (child.children.items) |sl_id| {
                        const sl = gs.force(sl_id).?;
                        try std.testing.expect(sl.support_kind != null);
                        try std.testing.expectEqual(@as(usize, 4), sl.units.items.len);
                        support_lances += 1;
                    }
                },
                else => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expect(recon_seen);
        try std.testing.expectEqual(@as(u32, 4), support_lances);
        // The tail outnumbers the teeth.
        try std.testing.expect(gs.people.count() > 120);
        out.* = gs.hash();
    }
    try std.testing.expectEqual(hashes[0], hashes[1]);
}

test "experience roll is 2d6-shaped" {
    var rng = rng_mod.Rng.init(1234);
    var counts = [_]u32{0} ** 4;
    for (0..10_000) |_| counts[@intFromEnum(rollExperience(&rng))] += 1;
    // Regular (6–9 on 2d6) must dominate; Elite (12) must be rare but present.
    try std.testing.expect(counts[1] > counts[0]);
    try std.testing.expect(counts[1] > counts[2]);
    try std.testing.expect(counts[3] > 0 and counts[3] < counts[2]);
}

test "12E.1: the starter company fields lights and mediums only — the founding bay rebuilds them all" {
    for ([_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 }) |seed| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer gs.deinit();
        _ = try gs.createCommander("T", .LC, .line_officer);
        const co = try generateInto(&gs, "Alpha");
        var it = gs.units.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr;
            if (u.kind != .mek or gs.companyOf(u.force) != co) continue;
            const class = chassis.find(u.chassis_key).?.weightClass();
            try std.testing.expect(class == .light or class == .medium);
        }
    }
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
