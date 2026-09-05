//! Awards (Stage 12B.5). Mirrors MekHQ `personnel/Award`: named ribbons
//! earned automatically when a counter on the person crosses a threshold
//! (data/tables/awards.zon). Each carries a small morale bump.

const std = @import("std");

pub const Counter = enum { kills, kill_bv, battles, wounded, tours, outstanding_tours, service_years };

pub const AwardRow = struct {
    key: []const u8,
    name: []const u8,
    kind: Counter,
    threshold: u32,
    morale: u8,
};

pub const table: []const AwardRow = @import("awards_zon");

pub fn find(key: []const u8) ?*const AwardRow {
    for (table) |*a| if (std.mem.eql(u8, a.key, key)) return a;
    return null;
}

test "the awards table loads with unique keys and positive thresholds" {
    try std.testing.expect(table.len >= 8);
    for (table, 0..) |a, i| {
        try std.testing.expect(a.threshold > 0);
        for (table[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.key, b.key));
    }
    try std.testing.expect(find("ace") != null);
}
