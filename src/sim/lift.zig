//! Lift: transport availability and berth queries (ARCH §4).
//! MekHQ counterpart: none; transport availability is checked inline
//! across AtB (`docs/mekhq-map.md`).

const std = @import("std");
const unit_mod = @import("../domain/unit.zig");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;
const posture = @import("posture.zig");
const toe = @import("toe.zig");
const artillery = @import("artillery.zig");
const artillery_dom = @import("../domain/artillery_formation.zig");
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

/// A ship's crew is fit for duty today: pilot slot is filled and that
/// person is available. The single check `transportAvailable`,
/// `ownsCrewedJumpshipAt` and `hasCrewedDropship` all share.
pub fn crewFit(gs: *GameState, u: *const unit_mod.Unit) bool {
    const crew = gs.person(u.pilot) orelse return false;
    return crew.isAvailable(gs.clock.day_index);
}

/// A ship is fit to sail when it is berthed, ready, crewed and not
/// already carrying a company (its `force` is set for the tour).
pub fn transportAvailable(gs: *GameState, u: *const unit_mod.Unit) bool {
    if (!u.kind.isTransport() or u.status != .ready or u.force != .none) return false;
    return crewFit(gs, u);
}

/// A crewed jumpship berthed at either end of a link (the dedicated
/// line of a level-3 supply link, GAMEPLAY "requires owning one").
pub fn ownsCrewedJumpshipAt(gs: *GameState, a: types.HqId, b: types.HqId) bool {
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.kind != .jumpship or (u.berth_hq != a and u.berth_hq != b)) continue;
        if (u.status == .destroyed) continue;
        if (crewFit(gs, u)) return true;
    }
    return false;
}

/// A crewed, live dropship in the company's own force: it lifts and
/// escorts the company on the way in.
pub fn hasCrewedDropship(gs: *GameState, company: types.ForceId) bool {
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.kind == .dropship and u.force == company and !u.isParked() and crewFit(gs, u)) return true;
    }
    return false;
}

/// Shared bay demand for query and committing lift; artillery uses the explicit
/// vehicle-bay abstraction in docs/p2-artillery-acquisition-design.md.
pub fn companyLiftDemand(gs: *GameState, company_id: types.ForceId) [3]u32 {
    var need: [3]u32 = .{ 0, 0, 0 };
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        if (gs.companyOf(u.force) != company_id or u.isParked() or u.status == .in_transit) continue;
        const bay = u.kind.bayKind() orelse continue;
        need[@intFromEnum(bay)] += 1;
    }
    need[2] += artillery.attachedCount(gs, company_id) * artillery_dom.carrier_vehicle_bays;
    return need;
}

test "artillery bay demand agrees with query and commit and requires matching ship bays" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try @import("founding.zig").createCommander(&gs, "T", .LC, .quartermaster);
    const co = try gs.createForce("Company", .company, .none);
    try toe.assignCompanyToHq(&gs, co, home);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    const bought = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    try std.testing.expectEqual(@as(u32, 0), companyLiftDemand(&gs, co)[2]);
    _ = try artillery.attach(&gs, .{ .formation = bought.artillery_formation, .company = co });
    const ship = try gs.addUnit("UNION");
    gs.unit(ship).?.berth_hq = home;
    gs.unit(ship).?.pilot = try gs.hirePerson("Fit", "Pilot", .dropship_crew);
    const demand = companyLiftDemand(&gs, co);
    const query = try planLiftQuery(&gs, co);
    const committed = try planLift(&gs, co, true);
    try std.testing.expectEqual(artillery_dom.carrier_vehicle_bays, demand[2]);
    try std.testing.expectEqualDeep(query, committed);
    const bays = chassis_mod.find("UNION").?.vehicle_bays;
    try std.testing.expectEqual(@min(@as(u32, bays), demand[2]), committed.carried);
    try std.testing.expectEqual(if (bays == 0) types.ForceId.none else co, gs.unit(ship).?.force);
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
    const need = companyLiftDemand(gs, company_id);
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
    const need = companyLiftDemand(gs, company_id);
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

test "hasCrewedDropship: fit crewed dropship true; destroyed/mothballed/unfit/none false" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 81 });
    defer gs.deinit();
    const founding = @import("founding.zig");
    const commands = @import("commands.zig");
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;

    // Add a Leopard dropship and a fit pilot; assign the ship to the company.
    const ds_id = try gs.addUnit("LEOPARD");
    const pid = try gs.hirePerson("D", "R", .dropship_crew);
    const ds = gs.units.getPtr(ds_id).?;
    ds.pilot = pid;
    ds.force = co;
    try std.testing.expect(hasCrewedDropship(&gs, co));

    // Destroyed hull: false.
    ds.status = .destroyed;
    try std.testing.expect(!hasCrewedDropship(&gs, co));

    // Mothballed hull: false.
    ds.status = .mothballed;
    try std.testing.expect(!hasCrewedDropship(&gs, co));

    // Restore to ready, but wound the pilot: false.
    ds.status = .ready;
    gs.person(pid).?.status = .wounded;
    try std.testing.expect(!hasCrewedDropship(&gs, co));

    // On leave: false.
    gs.person(pid).?.status = .active;
    gs.person(pid).?.leave_until_day = gs.clock.day_index + 30;
    try std.testing.expect(!hasCrewedDropship(&gs, co));

    // Restore fit: true again.
    gs.person(pid).?.leave_until_day = null;
    try std.testing.expect(hasCrewedDropship(&gs, co));

    // No pilot: false.
    ds.pilot = .none;
    try std.testing.expect(!hasCrewedDropship(&gs, co));
}

test "crewFit is shared: fit berthed transport is transportAvailable; fit berthed jumpship passes ownsCrewedJumpshipAt" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 82 });
    defer gs.deinit();
    const founding = @import("founding.zig");
    const commands = @import("commands.zig");
    _ = try founding.createCommander(&gs, "T", .LC, .paymaster);
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    const hq_id = gs.seat();

    // A ready berthed Leopard dropship with a fit pilot.
    const dp_id = try gs.addUnit("LEOPARD");
    const dp_pid = try gs.hirePerson("D", "R", .dropship_crew);
    const dp = gs.units.getPtr(dp_id).?;
    dp.pilot = dp_pid;
    dp.berth_hq = hq_id;
    try std.testing.expect(crewFit(&gs, dp));
    try std.testing.expect(transportAvailable(&gs, dp));

    // A ready berthed Invader jumpship with a fit pilot.
    const js_id = try gs.addUnit("INVADER");
    const js_pid = try gs.hirePerson("J", "R", .jumpship_crew);
    const js = gs.units.getPtr(js_id).?;
    js.pilot = js_pid;
    js.berth_hq = hq_id;
    try std.testing.expect(crewFit(&gs, js));
    try std.testing.expect(ownsCrewedJumpshipAt(&gs, hq_id, .none));
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
