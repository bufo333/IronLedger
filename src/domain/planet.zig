//! Star map: curated planet catalog (data/planets.zon), distances, and
//! faction-weighted world selection. Adaptation of MekHQ `universe/Planet` /
//! `planets.xml`: drastically curated (ARCH §9.1).

const std = @import("std");
const rng_mod = @import("../sim/rng.zig");

pub const Planet = struct {
    key: []const u8,
    name: []const u8,
    faction: []const u8, // LC / DC / FS / CC / FWL / PER
    x: i32, // LY offset on the map plane
    y: i32,
    industry: u8, // 0–5: local markets, acquisition, local-purchase easing
    /// Terrain class; null = derived from the key (`terrain.terrainOf`).
    terrain: ?@import("terrain.zig").Terrain = null,
};

pub const catalog: []const Planet = @import("planets_zon");

pub fn find(key: []const u8) ?*const Planet {
    for (catalog) |*p| {
        if (std.mem.eql(u8, p.key, key)) return p;
    }
    return null;
}

/// Straight-line distance, rounded to the nearest light-year, in integer
/// arithmetic (rules math never floats): the floor square root, rounded
/// up when the remainder passes the half-way mark.
pub fn distanceLy(a: *const Planet, b: *const Planet) u32 {
    const dx: i64 = a.x - b.x;
    const dy: i64 = a.y - b.y;
    const d2: u64 = @intCast(dx * dx + dy * dy);
    const r: u64 = std.math.sqrt(d2);
    return @intCast(if (d2 - r * r > r) r + 1 else r);
}

/// Jump legs to cover a distance (standard hops, `tuning.logistics.ly_per_jump`).
pub fn jumpsForLy(ly: u32) u32 {
    return std.math.divCeil(u32, ly, @import("tuning.zig").t.logistics.ly_per_jump) catch unreachable;
}

/// Jump legs for a route between two worlds.
pub fn jumpsBetween(a: *const Planet, b: *const Planet) u32 {
    return jumpsForLy(distanceLy(a, b));
}

/// Weighted-random world in one faction's space — how the starter HQ lands
/// "at home" for the commander's origin (industry-rich worlds more likely).
pub fn weightedPickByFaction(rng: *rng_mod.Rng, stream: rng_mod.Stream, faction_key: []const u8) ?*const Planet {
    var total: u32 = 0;
    for (catalog) |*p| {
        if (std.mem.eql(u8, p.faction, faction_key)) total += p.industry + 1;
    }
    if (total == 0) return null;
    var pick = rng.random(stream).uintLessThan(u32, total);
    for (catalog) |*p| {
        if (!std.mem.eql(u8, p.faction, faction_key)) continue;
        const w = p.industry + 1;
        if (pick < w) return p;
        pick -= w;
    }
    unreachable;
}

test "every world's faction is in the factions table and every capital is on the map" {
    const faction = @import("faction.zig");
    try std.testing.expect(catalog.len >= 150);
    for (catalog) |p| try std.testing.expect(faction.find(p.faction) != null);
    for (faction.table) |f| {
        if (find(f.capital) == null) {
            std.debug.print("faction {s}: capital {s} not on the map\n", .{ f.key, f.capital });
            return error.TestUnexpectedResult;
        }
    }
    // The original worlds keep their keys so saves still resolve.
    for ([_][]const u8{ "galatea", "solaris7", "skye", "new_home", "outreach", "zebebelgenubi" }) |k| try std.testing.expect(find(k) != null);
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
        const world = weightedPickByFaction(&rng, .generation, "CC").?;
        try std.testing.expectEqualStrings("CC", world.faction);
    }
    try std.testing.expect(weightedPickByFaction(&rng, .generation, "COMSTAR") == null);
}
