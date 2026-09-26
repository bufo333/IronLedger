//! Table of organization and equipment (ARCH §9.3 capacity slots): company
//! and lance counts, HQ and company capacity, support lances, unit
//! placement and moves, and company membership.
//!
//! MekHQ counterpart: none for per-HQ capacity slots (`docs/mekhq-map.md`,
//! HQ capacity slots row).

const std = @import("std");
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const force_mod = @import("../domain/force.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const founding = @import("founding.zig");

/// Combat companies currently assigned to an HQ.
pub fn companiesAtHq(gs: *GameState, hq_id: types.HqId) u32 {
    var n: u32 = 0;
    var it = gs.forces.iterator();
    while (it.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon == .company and f.supplying_hq == hq_id) n += 1;
    }
    return n;
}

/// Combat (mek/air) lances under a company.
pub fn combatLancesOf(gs: *GameState, company: types.ForceId) u32 {
    const f = gs.forces.getPtr(company) orelse return 0;
    var n: u32 = 0;
    for (f.children.items) |cid| {
        const c = gs.forces.getPtr(cid) orelse continue;
        if (c.isCombatLance()) n += 1;
    }
    return n;
}

/// Air wings of the companies assigned to an HQ.
pub fn airCompaniesAtHq(gs: *GameState, hq_id: types.HqId) u32 {
    var n: u32 = 0;
    var it = gs.forces.iterator();
    while (it.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon != .air_company) continue;
        const co = gs.forces.getPtr(f.parent) orelse continue;
        if (co.supplying_hq == hq_id) n += 1;
    }
    return n;
}

/// The company's air wing, if raised.
pub fn airCompanyOf(gs: *GameState, company: types.ForceId) ?types.ForceId {
    const f = gs.forces.getPtr(company) orelse return null;
    for (f.children.items) |cid| {
        const c = gs.forces.getPtr(cid) orelse continue;
        if (c.echelon == .air_company) return cid;
    }
    return null;
}

/// The company's support echelon (Omega Company), if any.
pub fn supportCompanyOf(gs: *GameState, company: types.ForceId) ?types.ForceId {
    const f = gs.forces.getPtr(company) orelse return null;
    for (f.children.items) |cid| {
        const c = gs.forces.getPtr(cid) orelse continue;
        if (c.echelon == .support_company) return cid;
    }
    return null;
}

/// Lances under a force of one echelon (air lances of a wing, support
/// lances of a support company).
pub fn lancesOfEchelon(gs: *GameState, parent: types.ForceId, echelon: force_mod.Echelon) u32 {
    const f = gs.forces.getPtr(parent) orelse return 0;
    var n: u32 = 0;
    for (f.children.items) |cid| {
        const c = gs.forces.getPtr(cid) orelse continue;
        if (c.echelon == echelon) n += 1;
    }
    return n;
}

pub const AssignHqError = error{ UnknownForce, UnknownHq, NotACompany, CapacityFull, TooManyLances };

/// Assign a company to an HQ, enforcing the HQ's capacity slots
/// (ARCH §9.3): companies per HQ and lances per company.
pub fn assignCompanyToHq(gs: *GameState, company: types.ForceId, hq_id: types.HqId) AssignHqError!void {
    const f = gs.forces.getPtr(company) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    const cap = hq.capacity();
    const already = companiesAtHq(gs, hq_id) - @intFromBool(f.supplying_hq == hq_id);
    if (already >= cap.combat_companies) return error.CapacityFull;
    if (combatLancesOf(gs, company) > cap.lances_per_company) return error.TooManyLances;
    f.supplying_hq = hq_id;
}

/// The company's support lance of one trade under its Omega, if raised.
/// (Membership predicates are tested in this file.)
pub fn supportLance(gs: *GameState, company: types.ForceId, kind: force_mod.SupportLanceKind) ?*force_mod.Force {
    const co = gs.forces.getPtr(company) orelse return null;
    for (co.children.items) |cid| {
        const omega = gs.forces.getPtr(cid) orelse continue;
        if (omega.echelon != .support_company) continue;
        for (omega.children.items) |sid| {
            const sl = gs.forces.getPtr(sid) orelse continue;
            if (sl.echelon == .support_lance and sl.support_kind == kind) return sl;
        }
    }
    return null;
}

/// The support lance under a company's Omega that a support hull
/// belongs in, by trade: MASH rigs to the MASH lance, salvage trucks to
/// salvage, cargo trucks to transport, platoons to security.
pub fn supportLanceFor(gs: *GameState, company: types.ForceId, u: *const unit_mod.Unit) ?types.ForceId {
    const want: force_mod.SupportLanceKind = switch (u.kind) {
        .mash => .mash,
        .cargo => if (std.mem.eql(u8, u.chassis_key, "SVT-1")) .salvage else .transport,
        .infantry => .security,
        else => return null,
    };
    return if (supportLance(gs, company, want)) |sl| sl.id else null;
}

/// Move a hull into a company: the first lance with a seat free, else
/// the company's own pool. The pilot rides along; the old tech stays
/// behind (transfers cost coverage until reassigned).
pub fn placeUnitInCompany(gs: *GameState, unit_id: types.UnitId, company: types.ForceId) !void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    // Leave the old force's roster.
    if (gs.forces.getPtr(u.force)) |old| {
        for (old.units.items, 0..) |id, i| {
            if (id == unit_id) {
                _ = old.units.orderedRemove(i);
                break;
            }
        }
    }
    var dest = company;
    if (gs.forces.getPtr(company)) |co| {
        if (u.kind == .aerospace) {
            // Fighters go to the air wing's first lance with room.
            if (airCompanyOf(gs, company)) |wing_id| {
                const wing = gs.forces.getPtr(wing_id).?;
                for (wing.children.items) |cid| {
                    const lance = gs.forces.getPtr(cid) orelse continue;
                    if (lance.echelon == .air_lance and lance.units.items.len < force_mod.lance_size) {
                        dest = cid;
                        break;
                    }
                }
            }
        } else if (u.kind == .mek or u.kind == .vehicle) {
            for (co.children.items) |cid| {
                const lance = gs.forces.getPtr(cid) orelse continue;
                if (lance.echelon == .lance and lance.units.items.len < force_mod.lance_size) {
                    dest = cid;
                    break;
                }
            }
        } else if (supportLanceFor(gs, company, u)) |sid| {
            // Trucks, ambulances and platoons join the support lance of
            // their trade.
            dest = sid;
        }
    }
    u.force = dest;
    // A bought wreck lands as damaged, not ready.
    if (u.status == .in_transit) u.status = if (u.needsDepot()) .damaged else .ready;
    u.tech = .none;
    if (gs.forces.getPtr(dest)) |d| try d.units.append(gs.allocator(), unit_id);
    if (gs.person(u.pilot)) |p| p.assigned_force = dest;
}

/// Move a hull between forces (lance ↔ lance, into a support lance, or
/// straight under a company): roster lists and the pilot's posting
/// follow it; the tech seat is kept.
pub fn moveUnitToForce(gs: *GameState, unit_id: types.UnitId, force_id: types.ForceId) !void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    const dest = gs.forces.getPtr(force_id) orelse return error.UnknownForce;
    if (gs.forces.getPtr(u.force)) |old| {
        for (old.units.items, 0..) |id, i| {
            if (id == unit_id) {
                _ = old.units.orderedRemove(i);
                break;
            }
        }
    }
    u.force = force_id;
    try dest.units.append(gs.allocator(), unit_id);
    if (gs.person(u.pilot)) |p| p.assigned_force = force_id;
}

pub const AssignError = error{ UnknownUnit, UnknownPerson, UnknownForce } || std.mem.Allocator.Error;

/// Put a unit in a lance and a pilot in the unit, keeping all three
/// views (unit.force, force.units, person.assigned_force) consistent.
pub fn assignUnit(gs: *GameState, unit_id: types.UnitId, force_id: types.ForceId, pilot_id: types.PersonId) AssignError!void {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    const f = gs.force(force_id) orelse return error.UnknownForce;
    u.force = force_id;
    try f.units.append(gs.allocator(), unit_id);
    if (pilot_id != .none) {
        const p = gs.person(pilot_id) orelse return error.UnknownPerson;
        u.pilot = pilot_id;
        p.assigned_force = force_id;
    }
}

/// Does this person serve under this company (any force in its tree)?
pub fn personInCompany(gs: *GameState, p: *const person_mod.Person, company: types.ForceId) bool {
    return company != .none and gs.companyOf(p.assigned_force) == company;
}

/// Head count assigned under one company's subtree (active + wounded).
pub fn companyHeadcount(gs: *GameState, company_id: types.ForceId) u32 {
    var n: u32 = 0;
    var it = gs.people.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        // Prisoners eat too.
        if (!(p.isOnBooks() or p.status == .pow)) continue;
        if (personInCompany(gs, p, company_id)) n += 1;
    }
    return n;
}

test "everyone under the company is in it; nobody else is" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var co: types.ForceId = .none;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        co = e.value_ptr.id;
    };
    var pit = gs.people.iterator();
    var in_co: u32 = 0;
    while (pit.next()) |e| if (personInCompany(&gs, e.value_ptr, co)) {
        in_co += 1;
    };
    try std.testing.expect(in_co > 0 and in_co == companyHeadcount(&gs, co));
    try std.testing.expect(supportLance(&gs, co, .mash) != null);
}

test "assign_company refuses CapacityFull exactly at the HQ's combat-company cap, and succeeds below it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const commands = @import("commands.zig");

    const hq_id = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const cap = gs.hqs.getPtr(hq_id).?.capacity();
    try std.testing.expectEqual(@as(u32, 1), cap.combat_companies);

    // Below capacity, the command assigns the HQ's one open slot.
    const resident = try gs.createForce("Alpha", .company, .none);
    try std.testing.expectEqual(@as(u32, 0), companiesAtHq(&gs, hq_id));
    _ = try commands.execute(&gs, .{ .assign_company = .{ .company = resident, .hq = hq_id } });
    try std.testing.expectEqual(@as(u32, 1), companiesAtHq(&gs, hq_id));

    // At the cap, the same command refuses CapacityFull and leaves the
    // outsider unassigned.
    const outsider = try gs.createForce("Outsider", .company, .none);
    const before_rng = gs.rng;
    try std.testing.expectError(error.CapacityFull, commands.execute(&gs, .{ .assign_company = .{ .company = outsider, .hq = hq_id } }));
    try std.testing.expectEqual(cap.combat_companies, companiesAtHq(&gs, hq_id));
    try std.testing.expectEqual(types.HqId.none, gs.force(outsider).?.supplying_hq);
    // assignCompanyToHq draws no RNG; the stream stays untouched too.
    try std.testing.expectEqual(before_rng, gs.rng);

    // A second, empty HQ sits below its own cap: the same company is
    // accepted there.
    const second_hq = try founding.foundHq(&gs, "Second", .regional, "alkaid");
    try std.testing.expectEqual(@as(u32, 0), companiesAtHq(&gs, second_hq));
    try assignCompanyToHq(&gs, outsider, second_hq);
    try std.testing.expectEqual(@as(u32, 1), companiesAtHq(&gs, second_hq));
}

test "hqWithCompanySlot never returns an HQ at its combat-company cap" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const hq_ops = @import("hq_ops.zig");

    const hq_id = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const cap = gs.hqs.getPtr(hq_id).?.capacity();
    const resident = try gs.createForce("Alpha", .company, .none);
    try assignCompanyToHq(&gs, resident, hq_id);
    try std.testing.expectEqual(cap.combat_companies, companiesAtHq(&gs, hq_id));

    // With only the full HQ standing, there is no slot anywhere.
    try std.testing.expectEqual(types.HqId.none, hq_ops.hqWithCompanySlot(&gs, hq_id));

    // Once a second HQ has room, the preferred (full) HQ is skipped for it.
    const second_hq = try founding.foundHq(&gs, "Second", .regional, "alkaid");
    const found = hq_ops.hqWithCompanySlot(&gs, hq_id);
    try std.testing.expectEqual(second_hq, found);
    try std.testing.expect(companiesAtHq(&gs, found) < gs.hqs.getPtr(found).?.capacity().combat_companies);
}
