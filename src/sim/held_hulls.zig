//! Hull custody: enemy capture and recovery, sale, stripping and cold storage (ARCH section 4, section 9.8).
//! MekHQ counterpart: battle salvage and hull recovery (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;
const posture = @import("posture.zig");
const market_mod = @import("../econ/market.zig");
const commands = @import("commands.zig");

/// The enemy dragged this hull off a field we lost: it leaves
/// the books exactly as `removeUnit` would — no bill, no bay, no
/// lance, invisible to every walker over `units` — but the hull
/// itself is kept in `held_hulls`, because a recovery raid can win it
/// back. The crew slots are cleared: our
/// people are not in it any more, whatever became of them.
pub fn holdUnit(gs: *GameState, unit_id: types.UnitId, by: []const u8, battle: types.BattleId) !void {
    // -- prepare: reserve capacity in the destination --
    try gs.held_hulls.ensureUnusedCapacity(gs.allocator(), 1);

    // -- commit: no allocation can fail past this point --
    gs.detachUnit(unit_id);
    var entry = gs.units.fetchOrderedRemove(unit_id) orelse return;
    const from_force = entry.value.force;
    entry.value.force = .none;
    entry.value.pilot = .none;
    entry.value.tech = .none;
    gs.held_hulls.appendAssumeCapacity(.{
        .unit = entry.value,
        .by = by,
        .day = gs.clock.day_index,
        .battle = battle,
        .from_force = from_force,
    });
}

/// Won back: the hull comes off the limbo list and onto the
/// books, back in the lance it was taken from if that lance still
/// exists. It comes back as it left — a wreck for the depot, not a
/// runner. Returns false if nobody holds that hull.
pub fn releaseHull(gs: *GameState, unit_id: types.UnitId) !bool {
    const i = blk: {
        for (gs.held_hulls.items, 0..) |h, n| if (h.unit.id == unit_id) break :blk n;
        return false;
    };

    // -- prepare: reserve capacity in every destination --
    try gs.units.ensureUnusedCapacity(gs.allocator(), 1);
    const from_force = gs.held_hulls.items[i].from_force;
    if (gs.forces.getPtr(from_force)) |f| try f.units.ensureUnusedCapacity(gs.allocator(), 1);

    // -- commit: no allocation can fail past this point --
    var held = gs.held_hulls.orderedRemove(i);
    if (gs.forces.getPtr(held.from_force)) |f| {
        held.unit.force = held.from_force;
        f.units.appendAssumeCapacity(unit_id);
    }
    gs.units.putAssumeCapacity(unit_id, held.unit);
    return true;
}

test "holding removes the hull from its lance and live unit map" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6006 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    const lance = gs.unit(taken).?.force;
    const seats_before = gs.forces.getPtr(lance).?.units.items.len;
    try holdUnit(&gs, taken, "DC", @enumFromInt(1));
    // Hull is gone from the live map and the lance.
    try std.testing.expect(gs.unit(taken) == null);
    try std.testing.expectEqual(seats_before - 1, gs.forces.getPtr(lance).?.units.items.len);
    try std.testing.expect(gs.heldHull(taken) != null);
}

test "release restores the hull to the original surviving lance" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6006 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    const lance = gs.unit(taken).?.force;
    const seats_before = gs.forces.getPtr(lance).?.units.items.len;
    try holdUnit(&gs, taken, "DC", @enumFromInt(1));
    try std.testing.expect(try releaseHull(&gs, taken));
    try std.testing.expect(gs.heldHull(taken) == null);
    try std.testing.expectEqual(lance, gs.unit(taken).?.force);
    try std.testing.expectEqual(seats_before, gs.forces.getPtr(lance).?.units.items.len);
}

test "a second release returns false" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6006 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    try holdUnit(&gs, taken, "DC", @enumFromInt(1));
    try std.testing.expect(try releaseHull(&gs, taken));
    // Asking twice is not an error and wins nothing the second time.
    try std.testing.expect(!try releaseHull(&gs, taken));
}

test "a failed holdUnit allocation leaves state unchanged" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 6007 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };

    const before = digest.stateHash(&gs);

    // Block every further allocation. held_hulls is empty (zero capacity),
    // so ensureUnusedCapacity(1) must allocate and fails.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, holdUnit(&gs, taken, "DC", @enumFromInt(1)));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

test "a failed releaseHull allocation leaves state unchanged" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 6008 });
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    try holdUnit(&gs, taken, "DC", @enumFromInt(1));

    // Point the held hull at a fresh empty force whose units list has
    // zero capacity: ensureUnusedCapacity(1) on it must allocate.
    const empty_force = try gs.createForce("Recovery", .lance, .none);
    gs.held_hulls.items[0].from_force = empty_force;

    const before = digest.stateHash(&gs);

    // Block every further allocation. The units map has spare capacity
    // (one entry was removed by holdUnit), so its reservation succeeds.
    // But the empty force's units list has zero capacity, forcing an
    // allocation that fails.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, releaseHull(&gs, taken));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
}

// ---- C4b assets command handlers moved from commands.zig ----

const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execMothball(gs: *GameState, unit_id: @FieldType(Command, "mothball")) Error!Result {
    const u = gs.unit(unit_id) orelse return Error.UnknownUnit;
    if (u.status == .mothballed) return Error.AlreadyMothballed;
    if (posture.isCompanyDeployed(gs, gs.companyOf(u.force))) return Error.UnitDeployed;
    u.status = .mothballed;
    return .{};
}

pub fn execToggleMothball(gs: *GameState, unit_id: @FieldType(Command, "toggle_mothball")) Error!Result {
    const u = gs.unit(unit_id) orelse return Error.UnknownUnit;
    if (u.status == .mothballed) {
        _ = try commands.execute(gs, .{ .reactivate = unit_id });
        return .{ .mothballed = false };
    }
    _ = try commands.execute(gs, .{ .mothball = unit_id });
    return .{ .mothballed = true };
}

pub fn execSellUnit(gs: *GameState, unit_id: @FieldType(Command, "sell_unit")) Error!Result {
    const u = gs.unit(unit_id) orelse return Error.UnknownUnit;
    if (posture.isCompanyDeployed(gs, gs.companyOf(u.force))) return Error.UnitDeployed;
    const value = try market_mod.unitSaleValue(gs.allocator(), u);
    const key = u.chassis_key;
    gs.removeUnit(unit_id);
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = value, .category = .unit_sale, .note = key });
    try gs.log(.market, .{}, "[sale] {s} #{d} sold for {d}", .{ key, @intFromEnum(unit_id), value });
    return .{};
}

pub fn execStripUnit(gs: *GameState, unit_id: @FieldType(Command, "strip_unit")) Error!Result {
    const u = gs.unit(unit_id) orelse return Error.UnknownUnit;
    const company = gs.companyOf(u.force);
    if (posture.isCompanyDeployed(gs, company)) return Error.UnitDeployed;
    if (u.status == .in_transit or (company != .none and !posture.isCompanyHome(gs, company))) return Error.UnitAway;
    const hq_id = gs.homeHqFor(u.force);
    if (gs.hqs.getPtr(hq_id) == null) return Error.NoHq;
    const lines = try market_mod.stripParts(gs.allocator(), u);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (lines, 0..) |l, i| {
        try gs.addStock(.{ .hq = hq_id }, l.key, l.qty);
        try text.appendSlice(gs.allocator(), try std.fmt.allocPrint(gs.allocator(), "{s}{d}× {s}", .{ if (i > 0) ", " else "", l.qty, l.key }));
    }
    const key = u.chassis_key;
    gs.removeUnit(unit_id);
    try gs.log(.market, .{ .hq = hq_id }, "[strip] {s} #{d} stripped for parts into the warehouse: {s}", .{ key, @intFromEnum(unit_id), if (lines.len == 0) "nothing worth keeping" else text.items });
    return .{};
}

test "cold storage cuts the bill and takes real time to undo" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } }); // bays needed to wake hulls
    const uid = try gs.addUnit("AS7-D");
    gs.unit(uid).?.quality = .a; // neglected hull: slow wake-up

    _ = try commands.execute(&gs, .{ .mothball = uid });
    try std.testing.expectEqual(@as(i64, 400), gs.unit(uid).?.monthlyBill()); // 20% of the 2k mek rate
    try std.testing.expectError(Error.AlreadyMothballed, commands.execute(&gs, .{ .mothball = uid }));

    _ = try commands.execute(&gs, .{ .reactivate = uid });
    _ = try commands.execute(&gs, .{ .advance_days = 10 });
    try std.testing.expect(gs.unit(uid).?.status == .mothballed); // A-grade takes 22 bay-days
    _ = try commands.execute(&gs, .{ .advance_days = 16 });
    try std.testing.expect(gs.unit(uid).?.status == .ready);
}
