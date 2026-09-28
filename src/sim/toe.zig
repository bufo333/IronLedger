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
const commands = @import("commands.zig");
const starter_company = @import("starter_company.zig");
const contract_market = @import("contract_market.zig");
const hq_ops = @import("hq_ops.zig");
const posture = @import("posture.zig");
const market_mod = @import("../econ/market.zig");
const personnel = @import("personnel.zig");
const sites = @import("sites.zig");
const hq_mod = @import("../domain/hq.zig");

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

/// Test helper: directly set a facility level on an HQ, bypassing the
/// normal upgrade path. Used in tests that need a specific facility level
/// without running a full construction project.
pub fn setFacilityLevel(gs: *GameState, hq_id: types.HqId, kind: hq_mod.FacilityKind, level: u8) !void {
    const h = gs.hqs.getPtr(hq_id).?;
    for (h.facilities.items) |*f| if (f.kind == kind) {
        f.level = level;
        h.staff_assigned = 999;
        return;
    };
    try h.facilities.append(gs.allocator(), .{ .kind = kind, .level = level });
    h.staff_assigned = 999;
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

// ---- C4b forces command handlers moved from commands.zig ----

const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execNewCompany(gs: *GameState, name: @FieldType(Command, "new_company")) Error!Result {
    // First HQ with a free combat-company slot;
    // no HQ yet (tests, pre-commander) → unassigned.
    const hq_id = hq_ops.hqWithCompanySlot(gs, .none);
    if (hq_id == .none and gs.hqs.count() > 0) return Error.CapacityFull;
    return newCompanyAt(gs, name, hq_id);
}

pub fn execNewCompanyAt(gs: *GameState, n: @FieldType(Command, "new_company_at")) Error!Result {
    if (gs.hqs.getPtr(n.hq) == null) return Error.UnknownHq;
    return newCompanyAt(gs, n.name, n.hq);
}

/// The skeleton a raised company starts from: the HQ's lance cap in empty
/// line lances (the last one a recon lance when there are four or more),
/// and an empty Omega Company of salvage, MASH, logistics and security
/// lances — the same shape as a generated starter company, with nothing
/// in it yet.
pub fn raiseCompany(gs: *GameState, name: []const u8, hq_id: types.HqId) Error!Result {
    const hq = gs.hqs.getPtr(hq_id) orelse return Error.UnknownHq;
    if (companiesAtHq(gs, hq_id) >= hq.capacity().combat_companies) return Error.CapacityFull;
    const id = try gs.createForce(name, .company, .none);
    const n: usize = @max(3, hq.capacity().lances_per_company);
    const names = [_][]const u8{ "1st Lance", "2nd Lance", "3rd Lance", "4th Lance", "5th Lance" };
    for (0..n) |i| {
        const recon = i + 1 == n and n >= 4;
        const lid = try gs.createForce(if (recon) "Recon Lance" else names[i], .lance, id);
        if (recon) gs.force(lid).?.role = .scouting;
    }
    const omega = try gs.createForce("Omega Company", .support_company, id);
    const plan = [_]struct { []const u8, force_mod.SupportLanceKind }{
        .{ "Salvage Lance", .salvage }, .{ "MASH Lance", .mash }, .{ "Logistics Lance", .transport }, .{ "Security Lance", .security },
    };
    for (plan) |entry| {
        const lid = try gs.createForce(entry[0], .support_lance, omega);
        gs.force(lid).?.support_kind = entry[1];
    }
    assignCompanyToHq(gs, id, hq_id) catch |err| switch (err) {
        error.CapacityFull => return Error.CapacityFull,
        error.TooManyLances => return Error.TooManyLances,
        else => return Error.UnknownHq,
    };
    try gs.log(.decision, .{ .company = id, .hq = hq_id }, "[raise] {s} raised at {s}: {d} empty line lances and a support echelon — buy hulls, hire crews", .{ name, hq.name, n });
    return .{ .created_force = id };
}

fn newCompanyAt(gs: *GameState, name: []const u8, hq_id: types.HqId) Error!Result {
    // Check the slot BEFORE generating 160 people for a company that has
    // nowhere to live.
    if (hq_id != .none) {
        const hq = gs.hqs.getPtr(hq_id) orelse return Error.UnknownHq;
        if (companiesAtHq(gs, hq_id) >= hq.capacity().combat_companies) return Error.CapacityFull;
    }
    const id = try starter_company.generateInto(gs, name);
    if (hq_id != .none) {
        assignCompanyToHq(gs, id, hq_id) catch |err| switch (err) {
            error.CapacityFull => return Error.CapacityFull,
            error.TooManyLances => return Error.TooManyLances,
            else => return Error.UnknownHq,
        };
    }
    // Employers price contracts off your fielded force — standing up a
    // company changes every quote on the board.
    try contract_market.refresh(gs);
    return .{ .created_force = id };
}

pub fn execMoveUnit(gs: *GameState, m: @FieldType(Command, "move_unit")) Error!Result {
    const u = gs.unit(m.unit) orelse return Error.UnknownUnit;
    const dest = gs.force(m.force) orelse return Error.UnknownForce;
    if (dest.echelon != .lance and dest.echelon != .support_lance and dest.echelon != .company and dest.echelon != .air_lance) return Error.NotACompany;
    const co = gs.companyOf(m.force);
    if (co == .none) return Error.NotACompany;
    const from_co = gs.companyOf(u.force);
    // A hull already with the company can change lances wherever the
    // company is, so a hull shipped to it in the field can be placed
    // there; joining from outside waits
    // for the company to be home — `transfer_unit` ships it there.
    if (from_co != co and !posture.isCompanyHome(gs, co)) return Error.CompanyDeployed;
    if (from_co != .none and from_co != co) return Error.SameForce; // use transfer_unit between companies
    if (dest.isCombatLance() and dest.units.items.len >= force_mod.lance_size) return Error.TooManyLances;
    if (u.status == .in_transit) return Error.Unavailable;
    if (dest.echelon == .air_lance and u.kind != .aerospace) return Error.WrongHullKind;
    if (dest.echelon == .lance and u.kind != .mek and u.kind != .vehicle) return Error.WrongHullKind; // mixed mek/vehicle lances are AtB-legal
    if (u.kind.isTransport()) return Error.WrongHullKind; // ships hold berths, not lance slots
    try moveUnitToForce(gs, m.unit, m.force);
    return .{};
}

pub fn execNewLance(gs: *GameState, nl: @FieldType(Command, "new_lance")) Error!Result {
    const co = gs.force(nl.company) orelse return Error.UnknownForce;
    if (co.echelon != .company) return Error.NotACompany;
    if (nl.name.len == 0) return Error.UnknownForce;
    const hq = gs.hqs.getPtr(co.supplying_hq);
    switch (nl.kind) {
        .line => {
            const cap: u32 = if (hq) |h| h.capacity().lances_per_company else 3;
            if (lancesOfEchelon(gs, nl.company, .lance) >= cap) return Error.TooManyLances;
            const id = try gs.createForce(nl.name, .lance, nl.company);
            return .{ .created_force = id };
        },
        .air => {
            const wing = airCompanyOf(gs, nl.company) orelse return Error.NoAirSlot;
            if (lancesOfEchelon(gs, wing, .air_lance) >= force_mod.max_air_lances) return Error.TooManyLances;
            const id = try gs.createForce(nl.name, .air_lance, wing);
            return .{ .created_force = id };
        },
        .support => |kind| {
            const h = hq orelse return Error.NoSupportSlot;
            const omega = supportCompanyOf(gs, nl.company) orelse return Error.NoSupportSlot;
            if (!h.supportLanceAllowed(kind)) return Error.NoSupportSlot;
            if (lancesOfEchelon(gs, omega, .support_lance) >= h.capacity().support_lances) return Error.NoSupportSlot;
            const id = try gs.createForce(nl.name, .support_lance, omega);
            gs.force(id).?.support_kind = kind;
            return .{ .created_force = id };
        },
    }
}

pub fn execRaiseAirCompany(gs: *GameState, company: @FieldType(Command, "raise_air_company")) Error!Result {
    const co = gs.force(company) orelse return Error.UnknownForce;
    if (co.echelon != .company) return Error.NotACompany;
    if (airCompanyOf(gs, company) != null) return Error.NoAirSlot;
    const h = gs.hqs.getPtr(co.supplying_hq) orelse return Error.NoHq;
    if (airCompaniesAtHq(gs, h.id) >= h.capacity().air_companies) return Error.NoAirSlot;
    const hq_id = h.id;
    const wing = try gs.createForce("Air Wing", .air_company, company);
    _ = try gs.createForce("1st Air Lance", .air_lance, wing);
    // Re-fetch: creating forces may have moved the map's storage.
    const co_now = gs.force(company).?;
    try gs.log(.decision, .{ .company = company, .hq = hq_id }, "[raise] {s} stands up an air wing at {s} — buy fighters, hire aero pilots and techs", .{ co_now.name, gs.hqs.getPtr(hq_id).?.name });
    return .{ .created_force = wing };
}

/// Why a hull cannot be moved to another company right now, or null:
/// the transfer refuses on it and the company picker dims every row on it.
pub fn transferBlock(gs: *GameState, u: *const unit_mod.Unit) ?[]const u8 {
    if (posture.isCompanyDeployed(gs, gs.companyOf(u.force))) return "its company is deployed";
    if (u.status == .in_transit) return "it is in transit";
    if (u.inShop()) return "it is in the depot";
    return null;
}

pub fn transferUnit(gs: *GameState, unit_id: types.UnitId, to_company: types.ForceId) Error!Result {
    const u = gs.unit(unit_id) orelse return Error.UnknownUnit;
    const dest = gs.force(to_company) orelse return Error.UnknownForce;
    if (dest.echelon != .company) return Error.NotACompany;
    const from_company = gs.companyOf(u.force);
    if (from_company == to_company) return Error.SameForce;
    if (transferBlock(gs, u)) |why| return if (std.mem.eql(u8, why, "its company is deployed")) Error.UnitDeployed else Error.Unavailable;

    const days = sites.travelDays(gs, from_company, to_company);
    if (days == 0) {
        try placeUnitInCompany(gs, unit_id, to_company);
        return .{ .in_transit = false };
    }
    // Ship it: leaves the old roster now, joins the new one on arrival.
    try gs.unit_transfers.ensureUnusedCapacity(gs.allocator(), 1);
    if (gs.forces.getPtr(u.force)) |old| {
        for (old.units.items, 0..) |id, i| {
            if (id == unit_id) {
                _ = old.units.orderedRemove(i);
                break;
            }
        }
    }
    u.force = .none;
    u.status = .in_transit;
    u.tech = .none;
    if (gs.person(u.pilot)) |p| {
        p.assigned_force = to_company;
        p.leave_until_day = gs.clock.day_index + days;
    }
    try gs.unit_transfers.append(gs.allocator(), .{ .unit = unit_id, .to_company = to_company, .eta_day = gs.clock.day_index + days });
    try gs.log(.delivery, .{ .company = to_company }, "[transfer] {s} shipped, arrives in {d} days", .{ u.chassis_key, days });
    return .{ .in_transit = true };
}

pub fn execRenameOutfit(gs: *GameState, name: @FieldType(Command, "rename_outfit")) Error!Result {
    gs.outfit_name = try gs.allocator().dupe(u8, name);
    return .{};
}

pub fn execRenameForce(gs: *GameState, r: @FieldType(Command, "rename_force")) Error!Result {
    const f = gs.force(r.force) orelse return Error.UnknownForce;
    f.name = try gs.allocator().dupe(u8, r.name);
    return .{};
}

pub fn execSetEmblem(gs: *GameState, e: @FieldType(Command, "set_emblem")) Error!Result {
    const f = gs.force(e.force) orelse return Error.UnknownForce;
    f.emblem = try gs.allocator().dupe(u8, e.image);
    return .{};
}

pub fn execSetOutfitEmblem(gs: *GameState, image: @FieldType(Command, "set_outfit_emblem")) Error!Result {
    const copy = try gs.allocator().dupe(u8, image);
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (e.value_ptr.echelon == .company) {
        e.value_ptr.emblem = copy;
    };
    return .{};
}

pub fn execSetRoe(gs: *GameState, r: @FieldType(Command, "set_roe")) Error!Result {
    const f = gs.force(r.company) orelse return Error.UnknownForce;
    if (f.echelon != .company) return Error.NotACompany;
    f.roe = r.roe;
    try gs.log(.contract, .{ .company = r.company }, "[roe] {s}: {s}", .{ f.name, r.roe.describe() });
    return .{};
}

pub fn execSetRole(gs: *GameState, r: @FieldType(Command, "set_role")) Error!Result {
    const f = gs.force(r.force) orelse return Error.UnknownForce;
    if (!f.isCombatLance()) return Error.NotACompany;
    f.role = r.role;
    return .{};
}

pub fn execCycleRoe(gs: *GameState, co: @FieldType(Command, "cycle_roe")) Error!Result {
    const f = gs.force(co) orelse return Error.UnknownForce;
    if (f.echelon != .company) return Error.NotACompany;
    const next = f.roe.next();
    _ = try commands.execute(gs, .{ .set_roe = .{ .company = co, .roe = next } });
    return .{ .roe = next };
}

pub fn execCycleRole(gs: *GameState, fid: @FieldType(Command, "cycle_role")) Error!Result {
    const f = gs.force(fid) orelse return Error.UnknownForce;
    if (!f.isCombatLance()) return Error.NotACompany;
    const next = f.role.next();
    _ = try commands.execute(gs, .{ .set_role = .{ .force = fid, .role = next } });
    return .{ .role = next };
}

pub fn execRecallIdle(gs: *GameState, company: @FieldType(Command, "recall_idle")) Error!Result {
    const f = gs.force(company) orelse return Error.UnknownForce;
    if (f.echelon != .company) return Error.NotACompany;
    if (posture.isCompanyHome(gs, company)) return Error.AlreadyHome;
    if (posture.isCompanyDeployed(gs, company)) return Error.UnderContract;
    return commands.execute(gs, .{ .recall_company = company });
}

pub fn execDisbandCompany(gs: *GameState, co: @FieldType(Command, "disband_company")) Error!Result {
    const f = gs.forces.getPtr(co) orelse return Error.UnknownForce;
    if (f.echelon != .company) return Error.NotACompany;
    if (!posture.isCompanyHome(gs, co)) return Error.CompanyDeployed;
    const name = f.name;
    var total: types.CBills = f.local_funds;
    // Hulls under the subtree, then people, then the forces.
    var uids: std.ArrayListUnmanaged(types.UnitId) = .empty;
    defer uids.deinit(gs.scratch());
    var uit = gs.units.iterator();
    while (uit.next()) |e| if (gs.companyOf(e.value_ptr.force) == co) try uids.append(gs.scratch(), e.value_ptr.id);
    for (uids.items) |uid| {
        total += try market_mod.unitSaleValue(gs.scratch(), gs.unit(uid).?);
        gs.removeUnit(uid);
    }
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        if (personInCompany(gs, p, co) and p.isOnBooks()) {
            _ = try personnel.depart(gs, p.id, .resigned, types.full_bp, "severance (disbanded)");
            p.assigned_force = .none;
        }
    }
    var fids: std.ArrayListUnmanaged(types.ForceId) = .empty;
    defer fids.deinit(gs.scratch());
    var fit = gs.forces.iterator();
    while (fit.next()) |e| if (gs.companyOf(e.value_ptr.id) == co) try fids.append(gs.scratch(), e.value_ptr.id);
    for (fids.items) |fid| _ = gs.forces.orderedRemove(fid);
    // Nothing may keep pointing at a company that no longer exists:
    // its standing orders, its resupply plan, the goods on the road
    // to it and the hulls on their way to join it.
    var pi: usize = 0;
    while (pi < gs.policies.items.len) {
        if (std.meta.eql(gs.policies.items[pi].entity, .{ .company = co })) _ = gs.policies.orderedRemove(pi) else pi += 1;
    }
    pi = 0;
    while (pi < gs.supply_policies.items.len) {
        if (gs.supply_policies.items[pi].company == co) _ = gs.supply_policies.orderedRemove(pi) else pi += 1;
    }
    for (gs.part_orders.items) |*o| if (o.inFlight() and std.meta.eql(o.dest, .{ .company = co })) {
        o.status = .cancelled;
    };
    pi = 0;
    while (pi < gs.unit_transfers.items.len) {
        if (gs.unit_transfers.items[pi].to_company == co) _ = gs.unit_transfers.orderedRemove(pi) else pi += 1;
    }
    // Money already dispatched to the disbanded company still lands — at the outfit.
    for (gs.fund_couriers.items) |*c| if (std.meta.eql(c.to, .{ .company = co })) {
        c.to = .outfit;
    };
    hq_ops.refreshHqStaffing(gs);
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = total, .category = .unit_sale, .note = "company disbanded" });
    try gs.log(.market, .{}, "[sale] {s} disbanded: {d} hulls sold, people released, {d} raised", .{ name, uids.items.len, total });
    return .{};
}

test "hulls move between lances at home; a new lance respects the HQ's lance cap" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 33 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .FS, .profession = .chief_engineer } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // A bought truck joins the company in the first line lance with room…
    const truck = try gs.addUnit("CGT-3");
    _ = try commands.execute(&gs, .{ .transfer_unit = .{ .unit = truck, .to_company = co } });
    // …and can be moved into the logistics lance.
    const log_lance: types.ForceId = if (supportLance(&gs, co, .transport)) |l| l.id else .none;
    try std.testing.expect(log_lance != .none);
    _ = try commands.execute(&gs, .{ .move_unit = .{ .unit = truck, .force = log_lance } });
    try std.testing.expectEqual(log_lance, gs.unit(truck).?.force);
    // Three line lances plus the recon lance fill a level-1 bay's four; the
    // fifth needs a level-3 mek bay.
    try std.testing.expectEqual(@as(u32, 4), combatLancesOf(&gs, co));
    try std.testing.expectError(Error.TooManyLances, commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "5th Lance" } }));
    const hq = gs.hqs.getPtr(gs.hqs.keys()[0]).?;
    for (hq.facilities.items) |*f| if (f.kind == .mek_bay) {
        f.level = 3;
    };
    hq_ops.refreshHqStaffing(&gs);
    if (hq.staff_assigned < hq.staffRequired().total()) _ = try commands.execute(&gs, .{ .autostaff = hq.id });
    _ = try commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "5th Lance" } });
    try std.testing.expectEqual(@as(u32, 5), combatLancesOf(&gs, co));
}

test "lance roles: set on lances only, persisted on the force" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .DC, .profession = .line_officer } });
    const res = try commands.execute(&gs, .{ .new_company = "Alpha" });
    try std.testing.expectError(Error.NotACompany, commands.execute(&gs, .{ .set_role = .{ .force = res.created_force, .role = .training } }));
    const co = gs.force(res.created_force).?;
    var lance: types.ForceId = .none;
    for (co.children.items) |cid| if (gs.force(cid).?.echelon == .lance) {
        lance = cid;
        break;
    };
    _ = try commands.execute(&gs, .{ .set_role = .{ .force = lance, .role = .training } });
    try std.testing.expectEqual(force_mod.LanceRole.training, gs.force(lance).?.role);
}

test "identity commands: outfit and company names, emblem bytes" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();

    _ = try commands.execute(&gs, .{ .rename_outfit = "Kalmar's Free Legion" });
    try std.testing.expectEqualStrings("Kalmar's Free Legion", gs.outfit_name);

    const r = try commands.execute(&gs, .{ .new_company = "Alpha Company" });
    _ = try commands.execute(&gs, .{ .rename_force = .{ .force = r.created_force, .name = "The Iron Ledger" } });
    _ = try commands.execute(&gs, .{ .set_emblem = .{ .force = r.created_force, .image = "\x89PNG-fake-bytes" } });

    const f = gs.force(r.created_force).?;
    try std.testing.expectEqualStrings("The Iron Ledger", f.name);
    try std.testing.expect(f.emblem != null);
}

test "air wings need a spaceport; fighters fly in air lances; support lances are facility-gated" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 15 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    const co = (try commands.execute(&gs, .{ .raise_company = .{ .name = "Bravo", .hq = hq } })).created_force;
    // Spaceport 1: no air slot.
    try std.testing.expectError(commands.Error.NoAirSlot, commands.execute(&gs, .{ .raise_air_company = co }));
    try std.testing.expectError(commands.Error.NoAirSlot, commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "Sky", .kind = .air } }));
    try setFacilityLevel(&gs, hq, .spaceport, 3);
    const wing = (try commands.execute(&gs, .{ .raise_air_company = co })).created_force;
    try std.testing.expectEqual(force_mod.Echelon.air_company, gs.force(wing).?.echelon);
    try std.testing.expectEqual(@as(u32, 1), lancesOfEchelon(&gs, wing, .air_lance));
    try std.testing.expectError(commands.Error.NoAirSlot, commands.execute(&gs, .{ .raise_air_company = co })); // one wing per company
    _ = try commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "2nd Air Lance", .kind = .air } });
    _ = try commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "3rd Air Lance", .kind = .air } });
    try std.testing.expectError(commands.Error.TooManyLances, commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "4th", .kind = .air } }));

    // A fighter goes to an air lance, never a line lance; a mek never to an air lance.
    const fighter = try gs.addUnit("SPR-H5");
    const mek = try gs.addUnit("LCT-1V");
    var line: types.ForceId = .none;
    var air: types.ForceId = .none;
    for (gs.force(co).?.children.items) |cid| if (gs.force(cid).?.echelon == .lance and line == .none) {
        line = cid;
    };
    for (gs.force(wing).?.children.items) |cid| if (air == .none) {
        air = cid;
    };
    try std.testing.expectError(commands.Error.WrongHullKind, commands.execute(&gs, .{ .move_unit = .{ .unit = fighter, .force = line } }));
    try std.testing.expectError(commands.Error.WrongHullKind, commands.execute(&gs, .{ .move_unit = .{ .unit = mek, .force = air } }));
    _ = try commands.execute(&gs, .{ .move_unit = .{ .unit = fighter, .force = air } });
    try std.testing.expectEqual(air, gs.unit(fighter).?.force);
    try placeUnitInCompany(&gs, try gs.addUnit("CSR-V12"), co);
    try std.testing.expectEqual(@as(usize, 2), gs.force(air).?.units.items.len);

    // Support lances: four staples fill the slot; a mess needs a mess hall.
    try std.testing.expectError(commands.Error.NoSupportSlot, commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "Mess", .kind = .{ .support = .mess } } }));
    try setFacilityLevel(&gs, hq, .mess, 2);
    const mess = (try commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "Mess Lance", .kind = .{ .support = .mess } } })).created_force;
    try std.testing.expectEqual(force_mod.SupportLanceKind.mess, gs.force(mess).?.support_kind.?);
    try std.testing.expectError(commands.Error.NoSupportSlot, commands.execute(&gs, .{ .new_lance = .{ .company = co, .name = "More", .kind = .{ .support = .salvage } } }));
}

test "a truck sent to a deployed company lands in its transport lance, and can still change lances out there" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 44 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // Alpha is away on a garrison contract.
    const cid: types.ContractId = @enumFromInt(901);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = gs.hqs.values()[0].planet_key,
        .status = .active,
        .assigned_company = co,
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
    });
    try std.testing.expect(gs.deploymentContract(co) != null);

    // A cargo truck arrives from the HQ: it joins the transport lance, not the company node.
    const truck = try gs.addUnit("CGT-3");
    try placeUnitInCompany(&gs, truck, co);
    const transport = supportLanceFor(&gs, co, gs.unit(truck).?).?;
    try std.testing.expectEqual(transport, gs.unit(truck).?.force);
    try std.testing.expectEqual(force_mod.SupportLanceKind.transport, gs.force(transport).?.support_kind.?);

    // Reshuffling inside the deployed company works; a salvage truck goes to salvage.
    const salvage: types.ForceId = if (supportLance(&gs, co, .salvage)) |l| l.id else .none;
    _ = try commands.execute(&gs, .{ .move_unit = .{ .unit = truck, .force = salvage } });
    try std.testing.expectEqual(salvage, gs.unit(truck).?.force);

    // Joining a deployed company from outside still waits for home.
    const outsider = try gs.addUnit("CGT-3");
    try std.testing.expectError(commands.Error.CompanyDeployed, commands.execute(&gs, .{ .move_unit = .{ .unit = outsider, .force = transport } }));
}

test "disbanding a company redirects its in-flight courier to the outfit treasury, not into the void" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 45 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    gs.funds = 5_000_000;
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(&gs, .{ .transfer = .{ .from = .outfit, .to = .{ .company = co }, .amount = 500_000 } });
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    const eta = gs.fund_couriers.items[0].eta_day;
    try std.testing.expect(eta > gs.clock.day_index);

    // Disband Alpha before the courier lands: the money must not vanish.
    _ = try commands.execute(&gs, .{ .disband_company = co });
    try std.testing.expectEqual(@as(usize, 1), gs.fund_couriers.items.len);
    try std.testing.expectEqual(state_mod.Treasury.outfit, gs.fund_couriers.items[0].to);
    try std.testing.expectEqual(@as(types.CBills, 500_000), gs.fund_couriers.items[0].amount);
    const funds_after_disband = gs.funds;

    while (gs.clock.day_index < eta) _ = try commands.execute(&gs, .{ .advance_days = 1 });
    try std.testing.expectEqual(@as(usize, 0), gs.fund_couriers.items.len);
    try std.testing.expectEqual(funds_after_disband + 500_000, gs.funds);
}
