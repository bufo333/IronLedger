//! Factions (Stage 12B.9). Mirrors MekHQ `universe/Faction` (factions.xml)
//! abridged to 3025: the five Great Houses, the near Periphery states,
//! ComStar and the pirate/periphery bucket. Data in data/tables/factions.zon:
//! name, Map colour, capital system, foes for the contract market, employer
//! pay multiplier, and whether the faction hires mercenaries.

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

/// Off the Inner Sphere's factory floors (12C.14): anyone but the five
/// Great Houses and ComStar.
pub fn isPeriphery(key: []const u8) bool {
    const core = [_][]const u8{ "LC", "DC", "FS", "CC", "FWL", "CS" };
    for (core) |c| if (std.mem.eql(u8, c, key)) return false;
    return true;
}

pub fn name(key: []const u8) []const u8 {
    return get(key).name;
}

test "factions load; every foe is a faction; the houses hire and ComStar does not" {
    try std.testing.expect(table.len >= 12);
    for (table) |f| for (f.foes) |foe| try std.testing.expect(find(foe) != null);
    try std.testing.expect(get("LC").hires and !get("CS").hires);
    try std.testing.expectEqualStrings("Periphery / pirates", get("nobody").name);
}
