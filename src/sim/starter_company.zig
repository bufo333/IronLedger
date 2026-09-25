//! The starter company, generated into a new campaign: three line lances
//! and a recon lance of meks with their pilots, an Omega support company
//! (salvage, MASH, logistics, security) and the support tail on staff,
//! following MekHQ's AtB company generator
//! (`universe/generators/companyGenerators/`). The rolls and the manning
//! table are pure and live in `gen/company_gen.zig`; this module writes
//! into `GameState`, so it lives in the sim. Only campaign creation and
//! tests call it: companies raised later start empty.

const std = @import("std");
const types = @import("../domain/types.zig");
const force = @import("../domain/force.zig");
const person = @import("../domain/person.zig");
const chassis = @import("../domain/chassis.zig");
const company_gen = @import("../gen/company_gen.zig");
const GameState = @import("state.zig").GameState;
const personnel = @import("personnel.zig");
const digest = @import("digest.zig");

/// Generate a full starter company into the campaign:
///   - 3 line lances × 4 meks (light/medium RAT rolls) with pilots
///   - a 4th Recon Lance of scouts (≤ `generation.scout_max_tonnage`)
///   - an attached "Omega Company" support echelon: salvage, MASH (with
///     medics), logistics, and security lances (ARCH §9.3)
///   - the support tail (techs/mechanics/astechs/medical/admin) on staff
/// Starting forces are granted, not purchased — MekHQ's company generator
/// likewise hands you the TO&E.
pub fn generateInto(gs: *GameState, name: []const u8) !types.ForceId {
    const company_id = try gs.createForce(name, .company, .none);
    var scratch: [32]*const chassis.Chassis = undefined;

    // Line lances: rolled weight class, uniform within class.
    const lance_names = [_][]const u8{ "1st Lance", "2nd Lance", "3rd Lance" };
    for (lance_names) |lance_name| {
        const lance_id = try gs.createForce(lance_name, .lance, company_id);
        for (0..force.lance_size) |_| {
            const class = company_gen.starterWeightClass(&gs.rng);
            // The house you come from fields what it fields.
            const home: []const u8 = if (gs.commander) |c| c.origin.key() else "PER";
            const design = @import("../domain/rat.zig").roll(&gs.rng, .generation, home, class, gs.clock.date.year);

            const unit_id = try gs.addUnit(design.key);
            const pilot_id = try personnel.recruitGenerated(gs, .mekwarrior, gs.homeHqFor(company_id), .generation);
            try gs.assignUnit(unit_id, lance_id, pilot_id);
        }
    }

    // Recon lance: light scouts only — feeds recon_quality in autoresolve.
    const recon_id = try gs.createForce("Recon Lance", .lance, company_id);
    gs.force(recon_id).?.role = .scouting;
    const scouts = chassis.scoutPool(company_gen.scout_max_tonnage, gs.clock.date.year, &scratch);
    for (0..force.lance_size) |_| {
        const design = scouts[gs.rng.random(.generation).uintLessThan(usize, scouts.len)];
        const unit_id = try gs.addUnit(design.key);
        const pilot_id = try personnel.recruitGenerated(gs, .mekwarrior, gs.homeHqFor(company_id), .generation);
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
            const crew_id = try personnel.recruitGenerated(gs, plan.crew_role, gs.homeHqFor(company_id), .generation);
            try gs.assignUnit(unit_id, lance_id, crew_id);
        }
        for (0..plan.attached_medics) |_| {
            const id = try personnel.recruitGenerated(gs, .medic, gs.homeHqFor(company_id), .generation);
            gs.person(id).?.assigned_force = lance_id;
        }
    }

    // The tail, posted to the company rather than a lance: the manning
    // table's support half. Crews and the MASH lance's medics came with
    // their hulls above.
    const tally: company_gen.HullTally = .{ .meks = force.lance_size * 4, .vehicles = force.lance_size * 3, .platoons = force.lance_size };
    for (company_gen.staffNeeds(tally)) |entry| {
        if (entry.role.isCombat() or entry.role == .tech_aero) continue;
        for (0..entry.need) |_| {
            const id = try personnel.recruitGenerated(gs, entry.role, gs.homeHqFor(company_id), .generation);
            gs.person(id).?.assigned_force = company_id;
        }
    }

    // Every hull gets its tech: the tail is sized for it.
    _ = try gs.autoAssign(company_id);
    _ = try personnel.refreshRanks(gs); // officers by seat
    return company_id;
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
                            try std.testing.expect(design.tonnage <= company_gen.scout_max_tonnage);
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
        out.* = digest.stateHash(&gs);
    }
    try std.testing.expectEqual(hashes[0], hashes[1]);
}

test "the starter company fields lights and mediums only — the founding bay rebuilds them all" {
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
