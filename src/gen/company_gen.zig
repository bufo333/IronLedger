//! Company autogeneration, following MekHQ's AtB company generator
//! (`universe/generators/companyGenerators/`): a mek company is 3 lances of
//! 4 meks, with officers, techs sized to the hangar, and admin/medical staff
//! sized to the roster. Stage 3 adds chassis selection by faction/era/weight
//! tables and full person generation.

const std = @import("std");
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

pub fn supportStaffFor(mek_count: u32, combat_personnel: u32) SupportStaff {
    const techs = mek_count;
    const doctors = std.math.divCeil(u32, combat_personnel, 25) catch unreachable;
    return .{
        .techs = techs,
        .astechs = techs * 6,
        .doctors = doctors,
        .medics = doctors * 4,
        // Command, logistics, transport, HR — one each per company minimum.
        .admins = @max(4, combat_personnel / 10),
    };
}

/// RAT weight-class roll for one mek, 2d6 (AtB flavor: mediums dominate a
/// line company, assaults are prizes). // TUNE
pub fn rollWeightClass(rng: *rng_mod.Rng) chassis.WeightClass {
    return switch (rng.roll2d6(.generation)) {
        2, 3, 4 => .light,
        5, 6, 7, 8 => .medium,
        9, 10, 11 => .heavy,
        else => .assault,
    };
}

/// Max tonnage for the recon lance's scout meks. // TUNE
pub const scout_max_tonnage = 40;

/// Generate a full starter company into the campaign:
///   - 3 line lances × 4 meks (RAT weight-class rolls) with pilots
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
            const class = rollWeightClass(&gs.rng);
            const pool = chassis.ofWeightClass(class, &scratch);
            const design = pool[gs.rng.random(.generation).uintLessThan(usize, pool.len)];

            const unit_id = try gs.addUnit(design.key);
            const pilot_id = try gs.recruitGenerated(.mekwarrior);
            try gs.assignUnit(unit_id, lance_id, pilot_id);
        }
    }

    // Recon lance: light scouts only — feeds recon_quality in autoresolve.
    const recon_id = try gs.createForce("Recon Lance", .lance, company_id);
    gs.force(recon_id).?.role = .scouting;
    const scouts = chassis.scoutPool(scout_max_tonnage, &scratch);
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
    const mek_count: u32 = force.lance_size * 4;
    const vehicle_count: u32 = force.lance_size * 3; // salvage + mash + logistics
    const combat_personnel: u32 = mek_count + vehicle_count + force.lance_size;
    const staff = supportStaffFor(mek_count, combat_personnel);
    const staff_plan = [_]struct { person.Role, u32 }{
        .{ .tech_mek, staff.techs },          .{ .astech, staff.astechs },
        .{ .tech_mechanic, vehicle_count / 2 }, .{ .doctor, staff.doctors },
        .{ .medic, staff.medics },            .{ .admin_command, 1 },
        .{ .admin_logistics, 1 },             .{ .admin_transport, 1 },
        .{ .admin_hr, staff.admins -| 3 },
    };
    for (staff_plan) |entry| {
        for (0..entry[1]) |_| {
            const id = try gs.recruitGenerated(entry[0]);
            gs.person(id).?.assigned_force = company_id;
        }
    }

    // Every hull gets its tech (Stage 9C.2): the tail is sized for it.
    _ = try gs.autoAssign(company_id);
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
