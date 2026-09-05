//! Terrain and weather (Stage 12C.10). Mirrors MekHQ `PlanetaryConditions`
//! / AtB weather and terrain rolls, abridged. Data in data/tables/terrain.zon.

const std = @import("std");
const rng_mod = @import("../sim/rng.zig");
const planet_mod = @import("planet.zig");

pub const Terrain = enum { plains, hills, forest, urban, badlands, jungle, tundra };
pub const Weather = enum { clear, rain, snow, storm, night, dust };

pub const TerrainRow = struct { kind: Terrain, name: []const u8, close: bool, harsh: bool, recon_mod: i8 };
pub const WeatherRow = struct { kind: Weather, name: []const u8, roll_mod: i8, grounds_air: bool, harsh: bool };
pub const Table = struct { terrain: []const TerrainRow, weather: []const WeatherRow, weather_2d6: [11]Weather };

pub const table: Table = @import("terrain_zon");

pub fn terrainRow(kind: Terrain) *const TerrainRow {
    for (table.terrain) |*t| if (t.kind == kind) return t;
    return &table.terrain[0];
}

pub fn weatherRow(kind: Weather) *const WeatherRow {
    for (table.weather) |*w| if (w.kind == kind) return w;
    return &table.weather[0];
}

/// A world's terrain class: the catalogue's word when it has one, else a
/// stable pick from the world's key (every world fights the same way
/// every time).
pub fn terrainOf(p: *const planet_mod.Planet) Terrain {
    if (p.terrain) |t| return t;
    const h = std.hash.Wyhash.hash(0x7e44a1, p.key);
    return @enumFromInt(h % @typeInfo(Terrain).@"enum".fields.len);
}

/// The weather for one battle: 2d6 on the table, coloured by the ground.
pub fn rollWeather(rng: *rng_mod.Rng, stream: rng_mod.Stream, terrain: Terrain) Weather {
    const roll = rng.roll2d6(stream);
    var w = table.weather_2d6[roll - 2];
    if (w == .rain and terrain == .tundra) w = .snow;
    if (w == .rain and terrain == .badlands) w = .dust;
    return w;
}

/// Where and in what the fight happened.
pub const Environment = struct {
    terrain: Terrain = .plains,
    weather: Weather = .clear,

    pub fn close(self: Environment) bool {
        return terrainRow(self.terrain).close;
    }
    pub fn groundsAir(self: Environment) bool {
        return weatherRow(self.weather).grounds_air;
    }
    pub fn reconMod(self: Environment) i8 {
        return terrainRow(self.terrain).recon_mod;
    }
    pub fn rollMod(self: Environment) i8 {
        return weatherRow(self.weather).roll_mod;
    }
    /// Fatigue points the conditions add on top of the fight.
    pub fn fatigue(self: Environment) u8 {
        return @as(u8, @intFromBool(terrainRow(self.terrain).harsh)) + @intFromBool(weatherRow(self.weather).harsh);
    }
};

test "12C.10: terrain is stable per world, weather follows the ground, the tables cover every kind" {
    inline for (@typeInfo(Terrain).@"enum".fields) |f| try std.testing.expectEqual(@as(Terrain, @enumFromInt(f.value)), terrainRow(@enumFromInt(f.value)).kind);
    inline for (@typeInfo(Weather).@"enum".fields) |f| try std.testing.expectEqual(@as(Weather, @enumFromInt(f.value)), weatherRow(@enumFromInt(f.value)).kind);
    const terra = planet_mod.find("terra").?;
    try std.testing.expectEqual(terrainOf(terra), terrainOf(terra));
    try std.testing.expectEqual(Terrain.urban, terrainOf(planet_mod.find("luthien").?));
    var rng = rng_mod.Rng.init(3);
    for (0..30) |_| {
        const w = rollWeather(&rng, .battle, .tundra);
        try std.testing.expect(w != .rain and w != .dust);
    }
    const storm: Environment = .{ .terrain = .jungle, .weather = .storm };
    try std.testing.expect(storm.close() and storm.groundsAir());
    try std.testing.expectEqual(@as(u8, 2), storm.fatigue());
}
