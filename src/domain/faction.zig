//! Factions (Stage 12B.9). Adaptation of MekHQ `universe/Faction` (factions.xml)
//! abridged to 3025: the five Great Houses, the near Periphery states,
//! ComStar and the pirate/periphery bucket. Data in data/tables/factions.zon:
//! name, Map colour, capital system, foes for the contract market, employer
//! pay multiplier, whether the faction hires mercenaries,
//! manufacturing chassis (provisional — see docs/p3c-economy-design.md §3),
//! replenishment rate (hulls per year), and conflict sensitivity (basis points).

const std = @import("std");
const types = @import("types.zig");

pub const Color = enum { blue, red, yellow, green, magenta, cyan, white, grey };

pub const FactionRow = struct {
    key: []const u8,
    name: []const u8,
    color: Color,
    capital: []const u8,
    foes: []const []const u8,
    pay_bp: types.Bp,
    hires: bool,
    /// Chassis `key`s this faction manufactures (references into data/chassis.zon).
    /// Empty slice = manufactures nothing (salvage only).
    /// Provisional values derived from RAT heavy+assault pools — // TUNE.
    /// See docs/p3c-economy-design.md §3.
    manufacturing_chassis: []const []const u8,
    /// Whole battlemechs the faction's lines add to its own roster per year.
    /// Annual integer (rule 25); P3e.6 accounting derives the per-month figure.
    /// 0 for factions with an empty manufacturing list. // TUNE
    replenishment_hulls_per_year: u16,
    /// Basis points governing how sharply faction conflict reduces surplus
    /// flow to market (docs/p3c-economy-design.md §3). Range 0..=100_000. // TUNE
    conflict_sensitivity_bp: types.Bp,
};

pub const table: []const FactionRow = @import("factions_zon");

pub fn find(key: []const u8) ?*const FactionRow {
    for (table) |*f| if (std.mem.eql(u8, f.key, key)) return f;
    return null;
}

/// The bucket unknown keys fall into.
pub fn get(key: []const u8) *const FactionRow {
    return find(key) orelse find("PER").?;
}

/// Off the Inner Sphere's factory floors: anyone but the five
/// Great Houses and ComStar.
pub fn isPeriphery(key: []const u8) bool {
    const core = [_][]const u8{ "LC", "DC", "FS", "CC", "FWL", "CS" };
    for (core) |c| if (std.mem.eql(u8, c, key)) return false;
    return true;
}

pub fn name(key: []const u8) []const u8 {
    return get(key).name;
}

test "data: factions load; every foe is a faction; the houses hire and ComStar does not" {
    try std.testing.expect(table.len >= 12);
    for (table) |f| for (f.foes) |foe| try std.testing.expect(find(foe) != null);
    try std.testing.expect(get("LC").hires and !get("CS").hires);
    try std.testing.expectEqualStrings("Periphery / pirates", get("nobody").name);
}

test "data: every manufacturing chassis key resolves and is a mek; conflict_sensitivity_bp in range" {
    const chassis = @import("chassis.zig");
    for (table) |f| {
        for (f.manufacturing_chassis) |key| {
            const c = chassis.find(key) orelse {
                std.debug.print("faction {s}: unknown chassis key {s}\n", .{ f.key, key });
                return error.TestUnexpectedResult;
            };
            if (c.kind != .mek) {
                std.debug.print("faction {s}: chassis {s} is not a mek\n", .{ f.key, key });
                return error.TestUnexpectedResult;
            }
        }
        if (f.conflict_sensitivity_bp < 0 or f.conflict_sensitivity_bp > 100_000) {
            std.debug.print("faction {s}: conflict_sensitivity_bp {} out of range 0..=100_000\n", .{ f.key, f.conflict_sensitivity_bp });
            return error.TestUnexpectedResult;
        }
    }
}
