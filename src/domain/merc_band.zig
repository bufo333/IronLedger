//! NPC merc-company bands: the intrinsic company tier that sets a company's
//! line target, founding capital and vehicle substitution
//! (docs/p5d-conflict-world-design.md §L8, decisions D23–D25). Distinct from
//! the per-contract skull rating in `skulls.zig`. Data in
//! data/tables/merc_bands.zon. No MekHQ counterpart (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const force = @import("force.zig");
const logo = @import("logo.zig");

/// One band row from merc_bands.zon.
pub const Band = struct {
    /// Stable key a save stores in `merc_company.band_key`.
    key: []const u8,
    /// Display text (markup-safe).
    label: []const u8,
    /// Companies of this band seeded at campaign creation.
    seed_companies: u16,
    /// Line target in lances of `force.lance_size` meks.
    line_lances: u8,
    /// C-bills a company of this band is founded with.
    capital_cbills: types.CBills,
    /// Whether vehicles may fill line positions meks leave open.
    vehicles_fill_line: bool,
};

pub const Table = struct { bands: []const Band };

pub const table: Table = @import("merc_bands_zon");

/// The band row with this key, or null. The row lives in static table memory.
pub fn find(key: []const u8) ?*const Band {
    for (table.bands) |*band| {
        if (std.mem.eql(u8, band.key, key)) return band;
    }
    return null;
}

/// Single owner of a band's line and mek target: `line_lances` lances of
/// `force.lance_size` meks (§L8, D23).
pub fn lineTarget(band: *const Band) usize {
    return @as(usize, band.line_lances) * force.lance_size;
}

/// Companies seeded at campaign creation: the sum of every row's
/// `seed_companies` (D25).
pub fn seedTotal() usize {
    var total: usize = 0;
    for (table.bands) |band| total += band.seed_companies;
    return total;
}

/// The band a replacement company is founded at: the first, lowest row.
pub fn replacementBand() *const Band {
    return &table.bands[0];
}

// Every rule above reads a non-empty, keyed and positive table: a broken row
// fails the build with the table's name (rule 58).
comptime {
    @setEvalBranchQuota(10_000);
    if (table.bands.len == 0) @compileError("data/tables/merc_bands.zon: `bands` is empty; replacements are founded at the first row");
    for (table.bands, 0..) |band, i| {
        if (band.key.len == 0) @compileError("data/tables/merc_bands.zon: a band has an empty key");
        for (table.bands[0..i]) |earlier| {
            if (std.mem.eql(u8, band.key, earlier.key)) @compileError("data/tables/merc_bands.zon: duplicate key: " ++ band.key);
        }
        if (band.line_lances == 0) @compileError("data/tables/merc_bands.zon: line_lances is zero: " ++ band.key);
        if (band.capital_cbills <= 0) @compileError("data/tables/merc_bands.zon: capital_cbills is not positive: " ++ band.key);
    }
    if (seedTotal() == 0) @compileError("data/tables/merc_bands.zon: seed_companies sums to zero; no company is seeded");
    // Every seeded company and the player draw distinct logos.
    if (seedTotal() + 1 > logo.all_keys.len) @compileError("data/tables/merc_bands.zon: seed_companies sum + 1 exceeds the data/logos catalog; add more PNG files to data/logos/");
}

// Not a `data:` test: a mod may retune every number checked here.
test "the stock band table seeds the D25 mix of four-lance bands" {
    try std.testing.expectEqual(@as(usize, 4), table.bands.len);
    const expected = [_]struct { key: []const u8, seed: u16, capital: types.CBills, vehicles: bool }{
        .{ .key = "band_1_2", .seed = 3, .capital = 20_000_000, .vehicles = true },
        .{ .key = "band_3", .seed = 4, .capital = 35_000_000, .vehicles = true },
        .{ .key = "band_4", .seed = 3, .capital = 50_000_000, .vehicles = false },
        .{ .key = "band_5", .seed = 2, .capital = 75_000_000, .vehicles = false },
    };
    for (table.bands, expected) |*band, want| {
        try std.testing.expectEqualStrings(want.key, band.key);
        try std.testing.expectEqual(want.seed, band.seed_companies);
        try std.testing.expectEqual(want.capital, band.capital_cbills);
        try std.testing.expectEqual(want.vehicles, band.vehicles_fill_line);
        try std.testing.expectEqual(@as(usize, 16), lineTarget(band));
        try std.testing.expectEqual(band, find(band.key).?);
    }
    try std.testing.expectEqual(@as(usize, 12), seedTotal());
    try std.testing.expectEqualStrings("band_1_2", replacementBand().key);
    try std.testing.expect(find("band_6") == null);
}
