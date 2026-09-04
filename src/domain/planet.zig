//! Star map: curated planet catalog (data/planets.zon), distances, and
//! faction-weighted world selection. Mirrors MekHQ `universe/Planet` /
//! `planets.xml`, drastically curated (ARCH §9.1).

const std = @import("std");
const rng_mod = @import("../sim/rng.zig");

pub const Planet = struct {
    key: []const u8,
    name: []const u8,
    faction: []const u8, // LC / DC / FS / CC / FWL / PER
    x: i32, // LY offset on the map plane
    y: i32,
    industry: u8, // 0–5: local markets, acquisition, local-purchase easing
};

pub const catalog: []const Planet = @import("planets_zon");

pub fn find(key: []const u8) ?*const Planet {
    for (catalog) |*p| {
        if (std.mem.eql(u8, p.key, key)) return p;
    }
    return null;
}

pub fn distanceLy(a: *const Planet, b: *const Planet) u32 {
    const dx: f64 = @floatFromInt(a.x - b.x);
    const dy: f64 = @floatFromInt(a.y - b.y);
    return @intFromFloat(@round(@sqrt(dx * dx + dy * dy)));
}

/// Jump legs for a route between two worlds (standard 30-LY hops).
pub fn jumpsBetween(a: *const Planet, b: *const Planet) u32 {
    return std.math.divCeil(u32, distanceLy(a, b), 30) catch unreachable;
}

/// Weighted-random world in one faction's space — how the starter HQ lands
/// "at home" for the commander's origin (industry-rich worlds more likely).
pub fn weightedPickByFaction(rng: *rng_mod.Rng, faction_key: []const u8) ?*const Planet {
    var total: u32 = 0;
    for (catalog) |*p| {
        if (std.mem.eql(u8, p.faction, faction_key)) total += p.industry + 1;
    }
    if (total == 0) return null;
    var pick = rng.random(.generation).uintLessThan(u32, total);
    for (catalog) |*p| {
        if (!std.mem.eql(u8, p.faction, faction_key)) continue;
        const w = p.industry + 1;
        if (pick < w) return p;
        pick -= w;
    }
    unreachable;
}

test "map loads with unique keys and all five houses present" {
    try std.testing.expect(catalog.len >= 20);
    for (catalog, 0..) |p, i| {
        for (catalog[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, p.key, other.key));
        }
    }
    for ([_][]const u8{ "LC", "DC", "FS", "CC", "FWL" }) |f| {
        var found = false;
        for (catalog) |p| {
            if (std.mem.eql(u8, p.faction, f)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "distances and jumps" {
    const galatea = find("galatea").?;
    const solaris = find("solaris7").?;
    const d = distanceLy(galatea, solaris);
    try std.testing.expect(d >= 30 and d <= 40); // (-28,22) ≈ 35.6
    try std.testing.expectEqual(@as(u32, 2), jumpsBetween(galatea, solaris));
}

test "starter world lands in the commander's faction space" {
    var rng = rng_mod.Rng.init(11);
    for (0..50) |_| {
        const world = weightedPickByFaction(&rng, "CC").?;
        try std.testing.expectEqualStrings("CC", world.faction);
    }
    try std.testing.expect(weightedPickByFaction(&rng, "COMSTAR") == null);
}
