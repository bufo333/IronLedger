//! Readiness: operational-status predicates for hulls and forces (ARCH §4).
//! MekHQ counterpart: unit readiness checks; see docs/mekhq-map.md.

const std = @import("std");
const GameState = @import("state.zig").GameState;
const unit_mod = @import("../domain/unit.zig");
const force_mod = @import("../domain/force.zig");
const types = @import("../domain/types.zig");

/// Ready to act today: the hull can take the field and its crew is fit
/// for duty. Support modifiers, MASH beds, the battle line and
/// fieldable strength all count hulls by this test.
pub fn unitOperational(gs: *GameState, u: *const unit_mod.Unit) bool {
    if (!u.standsInLine()) return false;
    const crew = gs.person(u.pilot) orelse return false;
    return crew.isAvailable(gs.clock.day_index);
}

/// At least one of the force's own hulls is operational.
pub fn forceOperational(gs: *GameState, f: *const force_mod.Force) bool {
    for (f.units.items) |uid| {
        const u = gs.unit(uid) orelse continue;
        if (unitOperational(gs, u)) return true;
    }
    return false;
}

/// The company has at least one operational, piloted aerospace fighter in its
/// air wing (P4g: air_cover intervention gate and battle.zig has_air_cover).
/// Single owner (rule 20): both battle.zig and operations.zig call this.
pub fn companyHasOperationalFighter(gs: *GameState, company: types.ForceId) bool {
    const c = gs.force(company) orelse return false;
    for (c.children.items) |child_id| {
        const child = gs.force(child_id) orelse continue;
        if (child.echelon != .air_company) continue;
        for (child.children.items) |al_id| {
            const al = gs.force(al_id) orelse continue;
            for (al.units.items) |uid| {
                const u = gs.unit(uid) orelse continue;
                if (u.kind == .aerospace and unitOperational(gs, u)) return true;
            }
        }
    }
    return false;
}

// ------------------------------------------------------------------ tests

test "ready hull plus available crew is operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const pid = try gs.hirePerson("T", "R", .mekwarrior);
    const fid = try gs.createForce("Alpha", .lance, .none);
    const toe = @import("toe.zig");
    try toe.assignUnit(&gs, uid, fid, pid);
    const u = gs.unit(uid).?;
    try std.testing.expect(unitOperational(&gs, u));
}

test "missing crew (pilot .none) is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const u = gs.unit(uid).?;
    // No pilot assigned — u.pilot is .none by default.
    try std.testing.expect(!unitOperational(&gs, u));
}

test "wounded crew is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const pid = try gs.hirePerson("T", "R", .mekwarrior);
    const fid = try gs.createForce("Alpha", .lance, .none);
    const toe = @import("toe.zig");
    try toe.assignUnit(&gs, uid, fid, pid);
    gs.person(pid).?.status = .wounded;
    const u = gs.unit(uid).?;
    try std.testing.expect(!unitOperational(&gs, u));
}

test "crew on leave is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const pid = try gs.hirePerson("T", "R", .mekwarrior);
    const fid = try gs.createForce("Alpha", .lance, .none);
    const toe = @import("toe.zig");
    try toe.assignUnit(&gs, uid, fid, pid);
    // Mark crew on leave for a future day past the clock.
    gs.person(pid).?.leave_until_day = gs.clock.day_index + 10;
    const u = gs.unit(uid).?;
    try std.testing.expect(!unitOperational(&gs, u));
}

test "destroyed hull is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const pid = try gs.hirePerson("T", "R", .mekwarrior);
    const fid = try gs.createForce("Alpha", .lance, .none);
    const toe = @import("toe.zig");
    try toe.assignUnit(&gs, uid, fid, pid);
    gs.unit(uid).?.status = .destroyed;
    const u = gs.unit(uid).?;
    try std.testing.expect(!unitOperational(&gs, u));
}

test "force with one operational hull is operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const pid = try gs.hirePerson("T", "R", .mekwarrior);
    const fid = try gs.createForce("Alpha", .lance, .none);
    const toe = @import("toe.zig");
    try toe.assignUnit(&gs, uid, fid, pid);
    const f = gs.force(fid).?;
    try std.testing.expect(forceOperational(&gs, f));
}

test "empty force is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const fid = try gs.createForce("Empty", .lance, .none);
    const f = gs.force(fid).?;
    try std.testing.expect(!forceOperational(&gs, f));
}

test "force with stale unit id (missing unit) is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8 });
    defer gs.deinit();
    const fid = try gs.createForce("Ghost", .lance, .none);
    const f = gs.force(fid).?;
    // Append a unit id that was never added to gs.units.
    const ghost_id: types.UnitId = @enumFromInt(9999);
    try f.units.append(gs.allocator(), ghost_id);
    try std.testing.expect(!forceOperational(&gs, f));
}

test "force where all units are non-operational is not operational" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    const pid = try gs.hirePerson("T", "R", .mekwarrior);
    const fid = try gs.createForce("Alpha", .lance, .none);
    const toe = @import("toe.zig");
    try toe.assignUnit(&gs, uid, fid, pid);
    // Destroy the only hull.
    gs.unit(uid).?.status = .destroyed;
    const f = gs.force(fid).?;
    try std.testing.expect(!forceOperational(&gs, f));
}
