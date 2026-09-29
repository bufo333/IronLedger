//! Lift: transport availability and berth queries (ARCH §4).
//! MekHQ counterpart: none; transport availability is checked inline
//! across AtB (`docs/mekhq-map.md`).

const std = @import("std");
const unit_mod = @import("../domain/unit.zig");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;
const posture = @import("posture.zig");
const toe = @import("toe.zig");
const chassis_mod = @import("../domain/chassis.zig");

/// Transports of one kind holding a berth at an HQ.
pub fn transportsBerthedAt(gs: *GameState, hq_id: types.HqId, kind: unit_mod.UnitKind) u32 {
    var n: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.kind == kind and u.berth_hq == hq_id and u.status != .destroyed) n += 1;
    }
    return n;
}

/// A ship is fit to sail when it is berthed, ready, crewed and not
/// already carrying a company (its `force` is set for the tour).
pub fn transportAvailable(gs: *GameState, u: *const unit_mod.Unit) bool {
    if (!u.kind.isTransport() or u.status != .ready or u.force != .none) return false;
    const crew = gs.person(u.pilot) orelse return false;
    return crew.isAvailable(gs.clock.day_index);
}

/// A crewed jumpship berthed at either end of a link (the dedicated
/// line of a level-3 supply link, GAMEPLAY "requires owning one").
pub fn ownsCrewedJumpshipAt(gs: *GameState, a: types.HqId, b: types.HqId) bool {
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.kind != .jumpship or (u.berth_hq != a and u.berth_hq != b)) continue;
        if (u.status == .destroyed) continue;
        const crew = gs.person(u.pilot) orelse continue;
        if (crew.isAvailable(gs.clock.day_index)) return true;
    }
    return false;
}

/// A crewed dropship in the company's own hangar: it lifts and escorts
/// the company on the way in.
pub fn hasCrewedDropship(gs: *GameState, company: types.ForceId) bool {
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.kind == .dropship and u.force == company and u.pilot != .none) return true;
    }
    return false;
}

pub const LiftPlan = struct {
    needed: u32 = 0,
    carried: u32 = 0,
    covered_bp: types.Bp = 0,
    own_jumpship: bool = false,
    ships: u32 = 0,
};

/// Query-only lift plan: what the outfit's own ships can carry for
/// a company, without committing any ship movements. Used by rating,
/// queries, and test code. Explicit error set: only allocation can fail.
pub fn planLiftQuery(gs: *GameState, company_id: types.ForceId) error{OutOfMemory}!LiftPlan {
    var plan: LiftPlan = .{};
    var need: [3]u32 = .{ 0, 0, 0 };
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != company_id or u.isParked() or u.status == .in_transit) continue;
        const bay = u.kind.bayKind() orelse continue;
        need[@intFromEnum(bay)] += 1;
    }
    plan.needed = need[0] + need[1] + need[2];
    if (plan.needed == 0) return plan;
    const at_home = posture.isCompanyHome(gs, company_id);
    const home = gs.homeHqFor(company_id);
    var have: [3]u32 = .{ 0, 0, 0 };
    var ships: std.ArrayListUnmanaged(types.UnitId) = .empty;
    defer ships.deinit(gs.scratch());
    var sit = gs.units.iterator();
    while (sit.next()) |e| {
        const u = e.value_ptr;
        if (!u.kind.isTransport() or u.status == .destroyed) continue;
        const usable = if (at_home) (u.berth_hq == home and transportAvailable(gs, u)) else u.force == company_id;
        if (!usable) continue;
        const design = chassis_mod.find(u.chassis_key) orelse continue;
        switch (u.kind) {
            .dropship => {
                const adds = @min(design.mek_bays, need[0] -| have[0]) + @min(design.asf_bays, need[1] -| have[1]) + @min(design.vehicle_bays, need[2] -| have[2]);
                if (adds == 0) continue;
                have[0] += design.mek_bays;
                have[1] += design.asf_bays;
                have[2] += design.vehicle_bays;
                plan.ships += 1;
                try ships.append(gs.scratch(), u.id);
            },
            .jumpship => plan.own_jumpship = true,
            else => {},
        }
    }
    plan.carried = @min(have[0], need[0]) + @min(have[1], need[1]) + @min(have[2], need[2]);
    plan.covered_bp = @intCast(@as(u64, plan.carried) * 10_000 / plan.needed);
    return plan;
}

/// How much of a company the outfit's own ships can lift.
/// At home: the crewed, idle ships berthed at the home HQ. Away (a
/// redeploy from the field): the ships already carrying it. `commit`
/// marks the ships as sailing with the company (`force` = company).
pub fn planLift(gs: *GameState, company_id: types.ForceId, commit: bool) !LiftPlan {
    var plan: LiftPlan = .{};
    var need: [3]u32 = .{ 0, 0, 0 };
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != company_id or u.isParked() or u.status == .in_transit) continue;
        const bay = u.kind.bayKind() orelse continue;
        need[@intFromEnum(bay)] += 1;
    }
    plan.needed = need[0] + need[1] + need[2];
    if (plan.needed == 0) return plan;
    const at_home = posture.isCompanyHome(gs, company_id);
    const home = gs.homeHqFor(company_id);
    var have: [3]u32 = .{ 0, 0, 0 };
    var ships: std.ArrayListUnmanaged(types.UnitId) = .empty;
    defer ships.deinit(gs.scratch());
    var sit = gs.units.iterator();
    while (sit.next()) |e| {
        const u = e.value_ptr;
        if (!u.kind.isTransport() or u.status == .destroyed) continue;
        const usable = if (at_home) (u.berth_hq == home and transportAvailable(gs, u)) else u.force == company_id;
        if (!usable) continue;
        const design = chassis_mod.find(u.chassis_key) orelse continue;
        switch (u.kind) {
            .dropship => {
                // Only ships that carry something come along.
                const adds = @min(design.mek_bays, need[0] -| have[0]) + @min(design.asf_bays, need[1] -| have[1]) + @min(design.vehicle_bays, need[2] -| have[2]);
                if (adds == 0) continue;
                have[0] += design.mek_bays;
                have[1] += design.asf_bays;
                have[2] += design.vehicle_bays;
                plan.ships += 1;
                try ships.append(gs.scratch(), u.id);
            },
            .jumpship => plan.own_jumpship = true,
            else => {},
        }
    }
    plan.carried = @min(have[0], need[0]) + @min(have[1], need[1]) + @min(have[2], need[2]);
    plan.covered_bp = @intCast(@as(u64, plan.carried) * 10_000 / plan.needed);
    if (commit and at_home) {
        // Reserve the destination force's unit capacity for every ship
        // before the move loop: if the reservation fails, no hull moves
        // (all-or-nothing). moveUnitToForce's internal ensureUnusedCapacity(1)
        // is then a no-op, so catch unreachable is sound (rules 11–13).
        if (gs.forces.getPtr(company_id)) |dest| try dest.units.ensureUnusedCapacity(gs.allocator(), ships.items.len);
        for (ships.items) |sid| toe.moveUnitToForce(gs, sid, company_id) catch unreachable;
    }
    return plan;
}

pub fn commitLift(gs: *GameState, company_id: types.ForceId) !LiftPlan {
    return planLift(gs, company_id, true);
}

test "planLiftQuery returns the same plan as planLift(commit=false) with OOM-only errors" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "Q", .LC, .paymaster);
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    // Compile-time proof that the error set is exactly OutOfMemory.
    comptime std.debug.assert(@typeInfo(@typeInfo(@TypeOf(planLiftQuery)).@"fn".return_type.?).error_union.error_set == error{OutOfMemory});
    const q = try planLiftQuery(&gs, co);
    const p = try planLift(&gs, co, false);
    try std.testing.expectEqual(q.needed, p.needed);
    try std.testing.expectEqual(q.carried, p.carried);
    try std.testing.expectEqual(q.covered_bp, p.covered_bp);
    try std.testing.expectEqual(q.own_jumpship, p.own_jumpship);
    try std.testing.expectEqual(q.ships, p.ships);
}
