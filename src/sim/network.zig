//! The HQ network (Stage 9D, ARCH §9.5): HQs are nodes, player-established
//! supply links are edges with a level (charter → scheduled → dedicated),
//! a weekly tonnage cap, and upkeep. Shipments route over links hop by hop
//! — every hop costs delay and freight unless the intermediary is a real
//! hub — and a link at capacity refuses more freight until next week.
//! No MekHQ counterpart: the supply network is this game's extension
//! (docs/mekhq-map.md). The HqLink entity lives in `domain/hq_link.zig`.

const std = @import("std");
const types = @import("../domain/types.zig");
const logistics = @import("../econ/logistics.zig");
const planet_mod = @import("../domain/planet.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const founding = @import("founding.zig");
const hq_link = @import("../domain/hq_link.zig");
const lift_mod = @import("lift.zig");
const toe = @import("toe.zig");
const commands = @import("commands.zig");

pub const HqLink = hq_link.HqLink;

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

/// Tonnage-aware best route between two HQs (ARCH §9.5).
/// Enumerates simple paths over the HQ link graph (few nodes). A path is
/// feasible when every linked hop has weekly room for `tons`. Among feasible
/// paths, chooses: minimum `routeDays`, then minimum `routeCostMultBp`, then
/// lexicographically smallest HQ-id sequence (stable tiebreak). Falls back to
/// a direct charter only when no linked path is feasible and
/// `tons <= logistics.linkTonsPerWeek(1)` (D2 cap); otherwise `error.NoRoute`.
/// All allocation is in `alloc` (caller's arena); no mutation.
pub fn routeBetween(gs: *GameState, from: types.HqId, to: types.HqId, tons: u32, alloc: std.mem.Allocator) RouteError![]RouteHop {
    var out: std.ArrayListUnmanaged(RouteHop) = .empty;
    if (from == to) return out.toOwnedSlice(alloc);

    const n = gs.hqs.count();
    const keys = gs.hqs.keys();
    const start = indexOf(keys, from) orelse return error.NoRoute;
    const goal = indexOf(keys, to) orelse return error.NoRoute;

    // DFS state: visited flags, current path, best feasible path found.
    var visited = try alloc.alloc(bool, n);
    defer alloc.free(visited);
    @memset(visited, false);
    var current: std.ArrayListUnmanaged(RouteHop) = .empty;
    defer current.deinit(alloc);
    var best: std.ArrayListUnmanaged(RouteHop) = .empty;
    defer best.deinit(alloc);
    var has_best = false;
    var best_days: u32 = std.math.maxInt(u32);
    var best_cost: types.Bp = std.math.maxInt(types.Bp);

    // The DFS context holds all mutable state the recursive explore step needs.
    const Ctx = struct {
        gs: *GameState,
        keys: []const types.HqId,
        tons: u32,
        goal: usize,
        alloc: std.mem.Allocator,
        visited: []bool,
        current: *std.ArrayListUnmanaged(RouteHop),
        best: *std.ArrayListUnmanaged(RouteHop),
        has_best: *bool,
        best_days: *u32,
        best_cost: *types.Bp,

        /// Returns true when path `a` beats path `b` on the tiebreak
        /// (lexicographically smaller HQ-id sequence).
        fn idSeqLt(a: []const RouteHop, b: []const RouteHop) bool {
            const len = @min(a.len, b.len);
            for (a[0..len], b[0..len]) |ah, bh| {
                const ai = @intFromEnum(ah.to);
                const bi = @intFromEnum(bh.to);
                if (ai < bi) return true;
                if (ai > bi) return false;
            }
            return a.len < b.len;
        }

        fn explore(self: @This(), cur: usize) !void {
            if (cur == self.goal) {
                // Check feasibility: every linked hop must have room for `tons`.
                for (self.current.items) |h| {
                    const li = h.link_index orelse continue;
                    const l = self.gs.hq_links.items[li];
                    if (l.tons_this_week + self.tons > l.tonsPerWeek()) return;
                }
                const days = routeDays(self.current.items);
                const cost = routeCostMultBp(self.current.items);
                const better = !self.has_best.* or
                    days < self.best_days.* or
                    (days == self.best_days.* and cost < self.best_cost.*) or
                    (days == self.best_days.* and cost == self.best_cost.* and
                        idSeqLt(self.current.items, self.best.items));
                if (better) {
                    self.has_best.* = true;
                    self.best_days.* = days;
                    self.best_cost.* = cost;
                    self.best.clearRetainingCapacity();
                    try self.best.appendSlice(self.alloc, self.current.items);
                }
                return;
            }
            // Try every link from `cur` to an unvisited neighbour.
            for (self.gs.hq_links.items, 0..) |l, li| {
                const other: ?types.HqId = if (l.a == self.keys[cur]) l.b else if (l.b == self.keys[cur]) l.a else null;
                const oi = indexOf(self.keys, other orelse continue) orelse continue;
                if (self.visited[oi]) continue;
                const a = planet_mod.find(self.gs.hqs.values()[cur].planet_key) orelse continue;
                const b = planet_mod.find(self.gs.hqs.values()[oi].planet_key) orelse continue;
                const via = self.gs.hqs.values()[oi];
                const is_final = oi == self.goal;
                const hop = RouteHop{
                    .from = self.keys[cur],
                    .to = self.keys[oi],
                    .hop = .{
                        .jumps = planet_mod.jumpsBetween(a, b),
                        .link_level = l.level,
                        .via_warehouse = if (is_final) 0 else via.effectiveFacilityLevel(.warehouse),
                        .via_spaceport = if (is_final) 0 else via.effectiveFacilityLevel(.spaceport),
                    },
                    .link_index = li,
                };
                self.visited[oi] = true;
                try self.current.append(self.alloc, hop);
                try self.explore(oi);
                _ = self.current.pop();
                self.visited[oi] = false;
            }
        }
    };

    visited[start] = true;
    const ctx = Ctx{
        .gs = gs,
        .keys = keys,
        .tons = tons,
        .goal = goal,
        .alloc = alloc,
        .visited = visited,
        .current = &current,
        .best = &best,
        .has_best = &has_best,
        .best_days = &best_days,
        .best_cost = &best_cost,
    };
    try ctx.explore(start);

    if (has_best) {
        try out.appendSlice(alloc, best.items);
        return out.toOwnedSlice(alloc);
    }

    // No feasible linked path: charter fallback, capped at level-1 capacity (D2).
    if (tons > logistics.linkTonsPerWeek(1)) return error.NoRoute;
    const a = planet_mod.find(gs.hqs.values()[start].planet_key) orelse return error.NoRoute;
    const b = planet_mod.find(gs.hqs.values()[goal].planet_key) orelse return error.NoRoute;
    try out.append(alloc, .{ .from = from, .to = to, .hop = .{ .jumps = planet_mod.jumpsBetween(a, b), .link_level = 1 }, .link_index = null });
    return out.toOwnedSlice(alloc);
}

fn indexOf(keys: []const types.HqId, id: types.HqId) ?usize {
    for (keys, 0..) |k, i| {
        if (k == id) return i;
    }
    return null;
}

/// Whether `tons` more fits every linked hop of the route this week.
/// Pure: books nothing.
pub fn fitsThroughput(gs: *const GameState, route: []const RouteHop, tons: u32) bool {
    for (route) |h| {
        const li = h.link_index orelse continue;
        const l = gs.hq_links.items[li];
        if (l.tons_this_week + tons > l.tonsPerWeek()) return false;
    }
    return true;
}

/// Book `tons` on every linked hop of the route. Cannot fail: the caller
/// has checked `fitsThroughput` against the same state.
pub fn commitThroughput(gs: *GameState, route: []const RouteHop, tons: u32) void {
    for (route) |h| {
        const li = h.link_index orelse continue;
        gs.hq_links.items[li].tons_this_week += tons;
    }
}

/// Check and book in one step: refused if any link is at capacity this
/// week, and nothing is reserved then. For callers with nothing to
/// validate in between.
pub fn reserveThroughput(gs: *GameState, route: []const RouteHop, tons: u32) error{ThroughputExceeded}!void {
    if (!fitsThroughput(gs, route, tons)) return error.ThroughputExceeded;
    commitThroughput(gs, route, tons);
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

/// Assign a company to an HQ (capacity slots enforced).
pub fn assignCompany(gs: *GameState, company: types.ForceId, hq: types.HqId) !void {
    toe.assignCompanyToHq(gs, company, hq) catch |err| switch (err) {
        error.UnknownForce => return error.UnknownForce,
        error.UnknownHq => return error.UnknownHq,
        error.NotACompany => return error.NotACompany,
        error.CapacityFull => return error.CapacityFull,
        error.TooManyLances => return error.TooManyLances,
        error.ArtilleryAttached => return error.ArtilleryAttached,
    };
}

/// Establish or raise a supply link between two HQs.
pub fn establishLink(gs: *GameState, a: types.HqId, b: types.HqId, level: u8) !void {
    // Validate — no mutation.
    if (gs.hqs.getPtr(a) == null or gs.hqs.getPtr(b) == null) return error.UnknownHq;
    if (a == b) return error.SameForce;
    if (level == 0 or level > 3) return error.BadLevel;
    const existing = findLink(gs, a, b);
    const from_level: u8 = if (existing) |e| e.level else 0;
    if (level <= from_level) return error.BadLevel;
    // A dedicated line is your own jumpship on the run.
    if (level >= logistics.dedicated_link_level and !lift_mod.ownsCrewedJumpshipAt(gs, a, b)) return error.NoJumpship;
    const cost = hq_link.linkCost(level) - hq_link.linkCost(from_level);
    if (gs.treasuryBalance(.outfit) < cost) return error.InsufficientTreasury;

    // Prepare — fallible, still no mutation.
    try gs.reserveLedger(1);
    var date_buf: [10]u8 = undefined;
    const line = try std.fmt.allocPrint(gs.allocator(), "{s} [network] supply link level {d} between hq:{d} and hq:{d}", .{ gs.clock.date.text(&date_buf), level, @intFromEnum(a), @intFromEnum(b) });
    try gs.reserveLog(1);
    if (existing == null) try gs.hq_links.ensureUnusedCapacity(gs.allocator(), 1);

    // Commit — no fallible operation past this point.
    gs.ledger.transactions.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .amount = -cost,
        .category = .transport_charter,
        .note = "supply link established",
    });
    gs.funds += -cost;
    if (existing) |e| {
        e.level = level;
    } else {
        gs.hq_links.appendAssumeCapacity(.{ .a = a, .b = b, .level = level, .established_day = gs.clock.day_index });
    }
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .delivery,
        .company = .none,
        .hq = b,
        .contract = .none,
        .text = line,
    });
}

// ---- C4b exec wrappers ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execAssignCompany(gs: *GameState, a: @FieldType(Command, "assign_company")) Error!Result {
    assignCompany(gs, a.company, a.hq) catch |err| return @errorCast(err);
    return .{};
}

pub fn execLink(gs: *GameState, l: @FieldType(Command, "link")) Error!Result {
    establishLink(gs, l.a, l.b, l.level) catch |err| return @errorCast(err);
    return .{};
}

test "routes follow links, charter when there are none, and links cap tonnage" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 41 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const home = gs.seat();
    const far = try founding.foundHq(&gs, "Frontier", .field, "alkaid");
    const mid = try founding.foundHq(&gs, "Waypoint", .field, "skye");

    // No links: charter direct (tons=20 ≤ D2 cap of 40).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const charter = try routeBetween(&gs, home, far, 20, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), charter.len);
    try std.testing.expect(charter[0].link_index == null);

    // Charter refused over the D2 cap (> 40 t/week).
    try std.testing.expectError(error.NoRoute, routeBetween(&gs, home, far, 50, arena.allocator()));

    // Link home—mid and mid—far: the route goes through the waypoint.
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = mid, .level = 2, .established_day = 0 });
    try gs.hq_links.append(gs.allocator(), .{ .a = mid, .b = far, .level = 1, .established_day = 0 });
    const linked = try routeBetween(&gs, home, far, 20, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), linked.len);
    try std.testing.expectEqual(mid, linked[0].to);

    // Throughput: the charter link moves 40t/week; 30 + 20 overflows.
    try reserveThroughput(&gs, linked, 30);
    try std.testing.expectError(error.ThroughputExceeded, reserveThroughput(&gs, linked, 20));
    resetWeeklyThroughput(&gs);
    try reserveThroughput(&gs, linked, 20);

    // Saturated linked path: fall back to charter (A15 regression).
    // Saturate the mid-far hop so the only linked path is infeasible.
    gs.hq_links.items[1].tons_this_week = gs.hq_links.items[1].tonsPerWeek();
    const fallback = try routeBetween(&gs, home, far, 10, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), fallback.len);
    try std.testing.expect(fallback[0].link_index == null); // charter fallback
    resetWeeklyThroughput(&gs);

    // Add a direct home—far link; a saturated shorter direct hop routes
    // through the feasible longer path via mid.
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 1, .established_day = 0 });
    gs.hq_links.items[2].tons_this_week = gs.hq_links.items[2].tonsPerWeek(); // saturate direct link
    const detour = try routeBetween(&gs, home, far, 10, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), detour.len);
    try std.testing.expectEqual(mid, detour[0].to); // routes via mid, not the saturated direct
}

test "fitsThroughput is the one cap gate; reserveThroughput books atomically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5101 });
    defer gs.deinit();
    // Add a level-1 link directly; no route planning required to test the cap.
    try gs.hq_links.append(gs.allocator(), .{
        .a = @enumFromInt(1),
        .b = @enumFromInt(2),
        .level = 1,
        .established_day = 0,
    });
    const cap = gs.hq_links.items[0].tonsPerWeek();
    const hop: logistics.Hop = .{ .jumps = 1, .link_level = 1, .via_warehouse = 0, .via_spaceport = 0 };
    const route = [_]RouteHop{.{ .from = @enumFromInt(1), .to = @enumFromInt(2), .hop = hop, .link_index = 0 }};
    // Exactly at capacity fits; one ton over does not.
    try std.testing.expect(fitsThroughput(&gs, &route, cap));
    try std.testing.expect(!fitsThroughput(&gs, &route, cap + 1));
    // reserveThroughput books the tons and commits them.
    const half = cap / 2;
    try reserveThroughput(&gs, &route, half);
    try std.testing.expectEqual(half, gs.hq_links.items[0].tons_this_week);
    try std.testing.expect(fitsThroughput(&gs, &route, cap - half));
    try std.testing.expect(!fitsThroughput(&gs, &route, cap - half + 1));
    // An overfill is atomically refused: tons_this_week is unchanged.
    try std.testing.expectError(error.ThroughputExceeded, reserveThroughput(&gs, &route, cap - half + 1));
    try std.testing.expectEqual(half, gs.hq_links.items[0].tons_this_week);
}

test "routeCostMultBp owns the per-hop freight cost; charter adds the premium" {
    const hop: logistics.Hop = .{ .jumps = 1, .link_level = 1, .via_warehouse = 0, .via_spaceport = 0 };
    // A single linked hop must equal logistics.routeCostMultBp for the same hop.
    const linked = [_]RouteHop{.{ .from = @enumFromInt(1), .to = @enumFromInt(2), .hop = hop, .link_index = 0 }};
    const one_hop = [_]logistics.Hop{hop};
    try std.testing.expectEqual(logistics.routeCostMultBp(&one_hop), routeCostMultBp(&linked));
    // A charter hop (link_index == null) carries the 15_000 bp premium on top.
    const charter_r = [_]RouteHop{.{ .from = @enumFromInt(1), .to = @enumFromInt(2), .hop = hop, .link_index = null }};
    const charter_cost = routeCostMultBp(&charter_r);
    const linked_cost = routeCostMultBp(&linked);
    try std.testing.expectEqual(@divTrunc(linked_cost * 15_000, 10_000), charter_cost);
    // Two identical linked hops compose multiplicatively.
    const two = [_]RouteHop{
        .{ .from = @enumFromInt(1), .to = @enumFromInt(2), .hop = hop, .link_index = 0 },
        .{ .from = @enumFromInt(2), .to = @enumFromInt(3), .hop = hop, .link_index = 1 },
    };
    try std.testing.expectEqual(@divTrunc(linked_cost * linked_cost, 10_000), routeCostMultBp(&two));
}

test "establishLink leaves funds, ledger and hq_links unchanged when allocation fails" {
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 9109 });
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const home = gs.seat();
    const far = try founding.foundHq(&gs, "Frontier", .field, "alkaid");

    // Guarantee funds cover linkCost(2) so the failure is OOM, not InsufficientTreasury.
    gs.funds = 1_000_000_000;

    const before = digest.stateHash(&gs);
    const links_before = gs.hq_links.items.len;
    const funds_before = gs.funds;

    // Block every further allocation so reserveLedger or allocPrint fails.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try std.testing.expectError(error.OutOfMemory, establishLink(&gs, home, far, 2));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectEqual(links_before, gs.hq_links.items.len);
    try std.testing.expectEqual(funds_before, gs.funds);
}

test "attached artillery blocks changed home assignment at owner network and command boundaries" {
    const artillery = @import("artillery.zig");
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const home = gs.seat();
    const other = try founding.foundHq(&gs, "Other", .regional, "skye");
    const co = try gs.createForce("Company", .company, .none);
    try toe.assignCompanyToHq(&gs, co, home);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    const bought = try commands.execute(&gs, .{ .buy_artillery = .{ .hq = home, .offer = gs.artillery_offers.items[0].id } });
    _ = try commands.execute(&gs, .{ .attach_artillery = .{ .formation = bought.artillery_formation, .company = co } });
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ArtilleryAttached, toe.assignCompanyToHq(&gs, co, other));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectError(error.ArtilleryAttached, assignCompany(&gs, co, other));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try std.testing.expectError(error.ArtilleryAttached, commands.execute(&gs, .{ .assign_company = .{ .company = co, .hq = other } }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    _ = try commands.execute(&gs, .{ .assign_company = .{ .company = co, .hq = home } });
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    _ = try commands.execute(&gs, .{ .detach_artillery = bought.artillery_formation });
    _ = try commands.execute(&gs, .{ .assign_company = .{ .company = co, .hq = other } });
    try std.testing.expectEqual(other, gs.homeHqFor(co));
}
