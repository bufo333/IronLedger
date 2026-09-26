//! Held hulls: enemy-captured hull limbo and recovery (ARCH §4).
//! MekHQ counterpart: battle salvage and hull recovery.

const std = @import("std");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;

/// The enemy dragged this hull off a field we lost: it leaves
/// the books exactly as `removeUnit` would — no bill, no bay, no
/// lance, invisible to every walker over `units` — but the hull
/// itself is kept in `held_hulls`, because a recovery raid can win it
/// back. The crew slots are cleared: our
/// people are not in it any more, whatever became of them.
pub fn holdUnit(gs: *GameState, unit_id: types.UnitId, by: []const u8, battle: types.BattleId) !void {
    gs.detachUnit(unit_id);
    var entry = gs.units.fetchOrderedRemove(unit_id) orelse return;
    const from_force = entry.value.force;
    entry.value.force = .none;
    entry.value.pilot = .none;
    entry.value.tech = .none;
    try gs.held_hulls.append(gs.allocator(), .{
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
    var held = gs.held_hulls.orderedRemove(i);
    if (gs.forces.getPtr(held.from_force)) |f| {
        held.unit.force = held.from_force;
        try f.units.append(gs.allocator(), unit_id);
    }
    try gs.units.put(gs.allocator(), unit_id, held.unit);
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
