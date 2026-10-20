//! News items: the persisted record of one political happening the outfit
//! heard of (docs/p5d-conflict-world-design.md §K "News"; P5d.1g). An item
//! stores its kind, the conflict it tells of, the presence that heard it
//! and its text, rendered once when it broke; its day, distance and
//! severity are derived from its conflict here, never stored (rule 80).
//! Reach is `sim/news.zig`'s, emission `sim/politics.zig`'s.
//! No MekHQ counterpart: MekHQ has no political news (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const planet = @import("planet.zig");
const conflict = @import("conflict.zig");

/// Which public day of an offensive conflict an item tells (§A, §K
/// "Evaluation"): its discovery, the strike, or its resolution. Persisted
/// by tag name.
pub const NewsKind = enum { discovery, strike, resolution };

/// How much an item matters (§K "News"): notable and major items belong in
/// the stop screen's digest.
pub const Severity = enum { routine, notable, major };

/// What heard an item: an HQ, or a company on the world it stands on
/// (`posture.companyWorld`). Persisted by tag name.
pub const PresenceKind = enum { hq, company };

/// An item's severity (§K "News"; decision D11): a discovery and a strike
/// are notable, a resolution major. No kind is routine. Pure.
pub fn severity(kind: NewsKind) Severity {
    return switch (kind) {
        .discovery, .strike => .notable,
        .resolution => .major,
    };
}

pub const NewsItem = struct {
    id: types.NewsId,
    kind: NewsKind,
    conflict: types.ConflictId,
    /// The presence nearest the conflict's world on the day it broke
    /// (`news.newsReach`), fixed then and never back-filled.
    reach_from: PresenceKind,
    /// That presence's world, a `planets.zon` key.
    reach_from_planet_key: []const u8,
    /// The sentence the item's `[politics]` log line carries: plain text,
    /// never markup (rule 41); screens escape it.
    text: []const u8,
};

/// The day an item tells of: its conflict's `discovery_day`, `strike_day`
/// or `expires_day` for its kind. Null when the conflict has no such day (a
/// standing need has no strike or end). Pure.
pub fn day(item: *const NewsItem, c: *const conflict.Conflict) ?u32 {
    return switch (item.kind) {
        .discovery => c.discovery_day,
        .strike => c.strike_day,
        .resolution => c.expires_day,
    };
}

/// How far the item travelled: `planet.distanceLy` from its conflict's
/// world to the world it was heard on, in light-years. Null when either
/// world is not in the catalogue. Pure.
pub fn reachLy(item: *const NewsItem, c: *const conflict.Conflict) ?u32 {
    const world = planet.find(c.planet_key) orelse return null;
    const from = planet.find(item.reach_from_planet_key) orelse return null;
    return planet.distanceLy(world, from);
}

test "a discovery and a strike are notable, a resolution major, and none is routine" {
    try std.testing.expectEqual(Severity.notable, severity(.discovery));
    try std.testing.expectEqual(Severity.notable, severity(.strike));
    try std.testing.expectEqual(Severity.major, severity(.resolution));
    for (std.enums.values(NewsKind)) |kind| try std.testing.expect(severity(kind) != .routine);
}

test "an item's day is its conflict's day for its kind, and its distance the worlds' apart" {
    const force: conflict.Force = .{ .lances = 1, .quality = .regular, .lance_bv = 1, .lance_tons = 1 };
    var c: conflict.Conflict = .{
        .id = @enumFromInt(3),
        .template_key = "border_grab",
        .planet_key = "skye",
        .aggressor = .{ .faction_key = "FWL", .personage = @enumFromInt(1) },
        .defender = .{ .faction_key = "LC", .personage = @enumFromInt(2) },
        .instigator = @enumFromInt(1),
        .staging_planet_key = "atreus",
        .opened_day = 10,
        .discovery_day = 30,
        .strike_day = 50,
        .expires_day = 90,
        .local_force = force,
        .strike_force = force,
    };
    var item: NewsItem = .{ .id = @enumFromInt(1), .kind = .discovery, .conflict = c.id, .reach_from = .hq, .reach_from_planet_key = "galatea", .text = "x" };
    try std.testing.expectEqual(@as(?u32, 30), day(&item, &c));
    item.kind = .strike;
    try std.testing.expectEqual(@as(?u32, 50), day(&item, &c));
    item.kind = .resolution;
    try std.testing.expectEqual(@as(?u32, 90), day(&item, &c));
    // A standing need has neither a strike nor an end.
    c.strike_day = null;
    c.expires_day = null;
    try std.testing.expectEqual(@as(?u32, null), day(&item, &c));
    item.kind = .strike;
    try std.testing.expectEqual(@as(?u32, null), day(&item, &c));
    item.kind = .discovery;
    try std.testing.expectEqual(@as(?u32, 30), day(&item, &c));

    try std.testing.expectEqual(planet.distanceLy(planet.find("skye").?, planet.find("galatea").?), reachLy(&item, &c).?);
    item.reach_from_planet_key = "skye";
    try std.testing.expectEqual(@as(?u32, 0), reachLy(&item, &c));
    item.reach_from_planet_key = "nowhere";
    try std.testing.expectEqual(@as(?u32, null), reachLy(&item, &c));
}
