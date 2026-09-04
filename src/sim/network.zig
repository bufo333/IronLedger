//! The HQ network (Stage 9D, ARCH §9.5): HQs are nodes, player-established
//! supply links are edges with a level (charter → scheduled → dedicated),
//! a weekly tonnage cap, and upkeep. Shipments route over links hop by hop
//! — every hop costs delay and freight unless the intermediary is a real
//! hub — and a link at capacity refuses more freight until next week.

const std = @import("std");
const types = @import("../domain/types.zig");
const logistics = @import("../econ/logistics.zig");
const planet_mod = @import("../domain/planet.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

pub const HqLink = struct {
    a: types.HqId,
    b: types.HqId,
    level: u8, // 1 charter, 2 scheduled, 3 dedicated jumpship
    tons_this_week: u32 = 0,
    established_day: u32,

    pub fn connects(self: HqLink, x: types.HqId, y: types.HqId) bool {
        return (self.a == x and self.b == y) or (self.a == y and self.b == x);
    }

    /// Weekly tonnage the link can move. // TUNE
    pub fn capacityPerWeek(self: HqLink) u32 {
        return logistics.linkThroughputPerWeek(self.level) * 4;
    }

    /// Monthly upkeep by level. // TUNE
    pub fn monthlyCost(self: HqLink) types.CBills {
        return @as(types.CBills, self.level) * 60_000;
    }
};

/// One-time cost to establish or raise a link to `level`. // TUNE
pub fn linkCost(level: u8) types.CBills {
    return @as(types.CBills, level) * @as(types.CBills, level) * 250_000;
}

pub fn findLink(gs: *GameState, a: types.HqId, b: types.HqId) ?*HqLink {
    for (gs.hq_links.items) |*l| {
        if (l.connects(a, b)) return l;
    }
    return null;
}

/// A hop in a resolved route, with the link it rides (null = charter).
pub const RouteHop = struct {
    from: types.HqId,
    to: types.HqId,
    hop: logistics.Hop,
    link_index: ?usize,
};

pub const RouteError = error{NoRoute} || std.mem.Allocator.Error;

/// Shortest link path between two HQs (BFS; few nodes). Each hop carries
/// the link level and the pass-through HQ's hub quality. No path → charter
/// direct at level 1 (expensive, slow, but it moves).
pub fn routeBetween(gs: *GameState, from: types.HqId, to: types.HqId, alloc: std.mem.Allocator) RouteError![]RouteHop {
    var out: std.ArrayListUnmanaged(RouteHop) = .empty;
    if (from == to) return out.toOwnedSlice(alloc);

    const n = gs.hqs.count();
    const keys = gs.hqs.keys();
    var prev = try alloc.alloc(?usize, n);
    defer alloc.free(prev);
    var via_link = try alloc.alloc(?usize, n);
    defer alloc.free(via_link);
    var visited = try alloc.alloc(bool, n);
    defer alloc.free(visited);
    @memset(prev, null);
    @memset(via_link, null);
    @memset(visited, false);

    var queue: std.ArrayListUnmanaged(usize) = .empty;
    defer queue.deinit(alloc);
    const start = indexOf(keys, from) orelse return error.NoRoute;
    const goal = indexOf(keys, to) orelse return error.NoRoute;
    visited[start] = true;
    try queue.append(alloc, start);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (cur == goal) break;
        for (gs.hq_links.items, 0..) |l, li| {
            const other: ?types.HqId = if (l.a == keys[cur]) l.b else if (l.b == keys[cur]) l.a else null;
            const oi = indexOf(keys, other orelse continue) orelse continue;
            if (visited[oi]) continue;
            visited[oi] = true;
            prev[oi] = cur;
            via_link[oi] = li;
            try queue.append(alloc, oi);
        }
    }

    if (!visited[goal]) {
        // Charter direct: one hop, level 1, no hub help.
        const a = planet_mod.find(gs.hqs.values()[start].planet_key) orelse return error.NoRoute;
        const b = planet_mod.find(gs.hqs.values()[goal].planet_key) orelse return error.NoRoute;
        try out.append(alloc, .{ .from = from, .to = to, .hop = .{ .jumps = planet_mod.jumpsBetween(a, b), .link_level = 1 }, .link_index = null });
        return out.toOwnedSlice(alloc);
    }

    // Walk back, then reverse.
    var path: std.ArrayListUnmanaged(usize) = .empty;
    defer path.deinit(alloc);
    var cur: usize = goal;
    while (cur != start) {
        try path.append(alloc, cur);
        cur = prev[cur].?;
    }
    try path.append(alloc, start);
    std.mem.reverse(usize, path.items);

    for (path.items[0 .. path.items.len - 1], 0..) |ci, i| {
        const ni = path.items[i + 1];
        const li = via_link[ni].?;
        const l = gs.hq_links.items[li];
        const a = planet_mod.find(gs.hqs.values()[ci].planet_key) orelse return error.NoRoute;
        const b = planet_mod.find(gs.hqs.values()[ni].planet_key) orelse return error.NoRoute;
        // Pass-through quality: the HQ this hop arrives at (intermediaries
        // matter; the final destination handles its own dock).
        const via = gs.hqs.values()[ni];
        const is_final = i + 2 == path.items.len;
        try out.append(alloc, .{
            .from = keys[ci],
            .to = keys[ni],
            .hop = .{
                .jumps = planet_mod.jumpsBetween(a, b),
                .link_level = l.level,
                .via_warehouse = if (is_final) 0 else via.effectiveFacilityLevel(.warehouse),
                .via_spaceport = if (is_final) 0 else via.effectiveFacilityLevel(.spaceport),
            },
            .link_index = li,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn indexOf(keys: []const types.HqId, id: types.HqId) ?usize {
    for (keys, 0..) |k, i| {
        if (k == id) return i;
    }
    return null;
}

/// Reserve tonnage on every link of a route; refused if any link is at
/// capacity this week (nothing reserved in that case).
pub fn reserveThroughput(gs: *GameState, route: []const RouteHop, tons: u32) error{ThroughputExceeded}!void {
    for (route) |h| {
        const li = h.link_index orelse continue;
        const l = gs.hq_links.items[li];
        if (l.tons_this_week + tons > l.capacityPerWeek()) return error.ThroughputExceeded;
    }
    for (route) |h| {
        const li = h.link_index orelse continue;
        gs.hq_links.items[li].tons_this_week += tons;
    }
}

pub fn resetWeeklyThroughput(gs: *GameState) void {
    for (gs.hq_links.items) |*l| l.tons_this_week = 0;
}

pub fn routeDays(route: []const RouteHop) u32 {
    var total: u32 = 0;
    for (route) |h| {
        const one = [_]logistics.Hop{h.hop};
        total += logistics.routeDelayDays(&one);
    }
    return @max(3, total);
}

pub fn routeCostMultBp(route: []const RouteHop) types.Bp {
    var mult: types.Bp = 10_000;
    for (route) |h| {
        const one = [_]logistics.Hop{h.hop};
        mult = @divTrunc(mult * logistics.routeCostMultBp(&one), 10_000);
        if (h.link_index == null) mult = @divTrunc(mult * 15_000, 10_000); // charter premium
    }
    return mult;
}

test "routes follow links, charter when there are none, and links cap tonnage" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 41 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .quartermaster);
    const home = gs.hqs.keys()[0];
    const far = try gs.foundHq("Frontier", .field, "alkaid");
    const mid = try gs.foundHq("Waypoint", .field, "skye");

    // No links: charter direct, one expensive hop.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const charter = try routeBetween(&gs, home, far, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), charter.len);
    try std.testing.expect(charter[0].link_index == null);

    // Link home—mid and mid—far: the route goes through the waypoint.
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = mid, .level = 2, .established_day = 0 });
    try gs.hq_links.append(gs.allocator(), .{ .a = mid, .b = far, .level = 1, .established_day = 0 });
    const linked = try routeBetween(&gs, home, far, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), linked.len);
    try std.testing.expectEqual(mid, linked[0].to);

    // Throughput: the charter link moves 40t/week; 30 + 20 overflows.
    try reserveThroughput(&gs, linked, 30);
    try std.testing.expectError(error.ThroughputExceeded, reserveThroughput(&gs, linked, 20));
    resetWeeklyThroughput(&gs);
    try reserveThroughput(&gs, linked, 20);
}
