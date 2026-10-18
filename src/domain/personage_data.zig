//! Data personages: the canon and authored figures a campaign seats in
//! place of procedural ones when its start year falls in their era window
//! (docs/p5d-conflict-world-design.md §B, §H). Data in
//! data/tables/personages.zon. A row's provenance is internal: tests and
//! save validation read it, and no display does.
//! No MekHQ counterpart: MekHQ has no persistent political figures
//! (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("tuning.zig").t;
const planet = @import("planet.zig");
const faction = @import("faction.zig");
const personage = @import("personage.zig");

/// A house or line two or more rows belong to; rows that share a family
/// are kin (decision K2).
pub const Family = struct {
    key: []const u8,
    name: []const u8,
};

pub const Row = struct {
    /// Stable key a save stores in `personage.key`; never renamed.
    key: []const u8,
    role: personage.Role,
    first_name: []const u8,
    last_name: []const u8,
    /// Display title, such as "Archon of the Lyran Commonwealth".
    title: []const u8,
    faction_key: []const u8,
    seat_planet_key: []const u8,
    /// A `families` key, or "" for none.
    family_key: []const u8,
    motives: []const personage.Motive,
    ambition: u8,
    /// Start years, inclusive, in which a campaign seats this row.
    era_from_year: u16,
    era_to_year: u16,
    /// `canon` or `authored`.
    provenance: personage.Provenance,
};

pub const Table = struct {
    families: []const Family,
    rows: []const Row,
};

pub const table: Table = @import("personages_zon");

/// The row with this key, or null. The row lives in static table memory.
pub fn find(key: []const u8) ?*const Row {
    for (table.rows) |*row| {
        if (std.mem.eql(u8, row.key, key)) return row;
    }
    return null;
}

/// Whether a campaign that starts in `start_year` seats this row (decision Y1).
pub fn inWindow(row: *const Row, start_year: u16) bool {
    return row.era_from_year <= start_year and start_year <= row.era_to_year;
}

/// A row's motives as the set a personage holds.
pub fn motiveSet(row: *const Row) personage.Motives {
    var m = personage.Motives.initEmpty();
    for (row.motives) |motive| m.insert(motive);
    return m;
}

/// The year every stock row's window covers, the setting's reference year
/// (docs/p5d-conflict-world-design.md §H).
pub const reference_year: u16 = 3025;

fn familyListed(key: []const u8) bool {
    for (table.families) |f| if (std.mem.eql(u8, f.key, key)) return true;
    return false;
}

fn keyShaped(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    return true;
}

fn windowsOverlap(a: *const Row, b: *const Row) bool {
    return a.era_from_year <= b.era_to_year and b.era_from_year <= a.era_to_year;
}

// A broken row fails the build with the table's name (rule 58). Markup
// safety and name-pool collisions are checked where the sim reads the
// table (`sim/personages.zig`).
comptime {
    @setEvalBranchQuota(2_000_000);
    const file = "data/tables/personages.zon: ";
    for (table.families, 0..) |f, i| {
        if (!keyShaped(f.key)) @compileError(file ++ "a family key is empty or not lowercase [a-z0-9_]: '" ++ f.key ++ "'");
        if (f.name.len == 0) @compileError(file ++ "family has an empty name: " ++ f.key);
        for (table.families[0..i]) |earlier| {
            if (std.mem.eql(u8, f.key, earlier.key)) @compileError(file ++ "duplicate family key: " ++ f.key);
        }
    }
    for (table.rows, 0..) |*row, i| {
        const k = row.key;
        if (!keyShaped(k)) @compileError(file ++ "a row key is empty or not lowercase [a-z0-9_]: '" ++ k ++ "'");
        for (table.rows[0..i]) |earlier| {
            if (std.mem.eql(u8, k, earlier.key)) @compileError(file ++ "duplicate key: " ++ k);
        }
        if (faction.find(k) != null or planet.find(k) != null) @compileError(file ++ "key collides with a faction or planet key: " ++ k);
        if (row.first_name.len == 0 or row.last_name.len == 0) @compileError(file ++ "empty name: " ++ k);
        if (row.title.len == 0) @compileError(file ++ "empty title: " ++ k);
        if (row.provenance == .procedural) @compileError(file ++ "provenance must be canon or authored: " ++ k);
        const f = faction.find(row.faction_key) orelse @compileError(file ++ "unknown faction '" ++ row.faction_key ++ "': " ++ k);
        const seat = planet.find(row.seat_planet_key) orelse @compileError(file ++ "unknown seat '" ++ row.seat_planet_key ++ "': " ++ k);
        if (row.family_key.len > 0 and !familyListed(row.family_key)) @compileError(file ++ "unknown family '" ++ row.family_key ++ "': " ++ k);
        switch (row.role) {
            .planetary_ruler => if (!personage.worldHasRuler(seat) or !std.mem.eql(u8, seat.faction, f.key))
                @compileError(file ++ "a planetary_ruler must sit on a hiring world of its own faction: " ++ k),
            .faction_leader => if (!personage.factionHasLeader(f) or !std.mem.eql(u8, seat.key, f.capital))
                @compileError(file ++ "a faction_leader must sit on its leader-bearing faction's capital: " ++ k),
            .heir, .family, .intelligence_chief => {},
        }
        for (row.motives, 0..) |m, j| {
            for (row.motives[0..j]) |earlier| if (earlier == m) @compileError(file ++ "a motive repeats: " ++ k);
        }
        if (!personage.motivesValid(motiveSet(row))) @compileError(file ++ "motive count out of range: " ++ k);
        if (row.ambition > tuning.politics.ambition_max) @compileError(file ++ "ambition above politics.ambition_max: " ++ k);
        if (!(row.era_from_year <= reference_year and reference_year <= row.era_to_year)) @compileError(file ++ "era window does not cover the reference year: " ++ k);
        for (table.rows[0..i]) |*earlier| {
            if (earlier.role != row.role or !windowsOverlap(earlier, row)) continue;
            const clash = switch (row.role) {
                .planetary_ruler => std.mem.eql(u8, earlier.seat_planet_key, row.seat_planet_key),
                .faction_leader => std.mem.eql(u8, earlier.faction_key, row.faction_key),
                .heir, .family, .intelligence_chief => false,
            };
            if (clash) @compileError(file ++ "two rows hold one seat in overlapping windows: " ++ earlier.key ++ ", " ++ k);
        }
    }
}

test "every stock row resolves its seat and family and covers the reference year" {
    for (table.rows) |*row| {
        try std.testing.expectEqual(row, find(row.key).?);
        try std.testing.expect(inWindow(row, reference_year));
        try std.testing.expect(planet.find(row.seat_planet_key) != null);
        if (row.family_key.len > 0) try std.testing.expect(familyListed(row.family_key));
        try std.testing.expect(personage.motivesValid(motiveSet(row)));
    }
    try std.testing.expect(find("nosuchkey") == null);
}

test "an era window is inclusive at both ends" {
    const row: Row = .{ .key = "x", .role = .heir, .first_name = "A", .last_name = "B", .title = "T", .faction_key = "LC", .seat_planet_key = "tharkad", .family_key = "", .motives = &.{ .honor, .reform }, .ambition = 1, .era_from_year = 3020, .era_to_year = 3025, .provenance = .authored };
    try std.testing.expect(inWindow(&row, 3020));
    try std.testing.expect(inWindow(&row, 3025));
    try std.testing.expect(!inWindow(&row, 3019));
    try std.testing.expect(!inWindow(&row, 3026));
}
