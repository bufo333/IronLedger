//! Ranks (Stage 12B.4). Adaptation of MekHQ `personnel/ranks/Ranks`: one
//! mercenary ladder from data/tables/ranks.zon: a title on the roster and
//! a CamOps pay multiplier. Seats decide officers (company commander →
//! Captain, lance leaders → Lieutenant); everyone else ranks by experience
//! unless the player pinned a rank with `promote`.

const std = @import("std");
const types = @import("types.zig");

pub const Rank = enum(u8) {
    recruit,
    private,
    corporal,
    sergeant,
    master_sergeant,
    lieutenant,
    captain,
    major,
    colonel,

    pub fn row(self: Rank) RankRow {
        return table[@intFromEnum(self)];
    }
    pub fn name(self: Rank) []const u8 {
        return self.row().name;
    }
    pub fn abbrev(self: Rank) []const u8 {
        return self.row().abbrev;
    }
    pub fn payBp(self: Rank) types.Bp {
        return self.row().pay_bp;
    }
    pub fn isOfficer(self: Rank) bool {
        return self.row().officer;
    }

    /// The enlisted rank experience earns.
    pub fn forExperience(xp: types.ExperienceLevel) Rank {
        return switch (xp) {
            .green => .private,
            .regular => .corporal,
            .veteran => .sergeant,
            .elite => .master_sergeant,
        };
    }
};

pub const RankRow = struct {
    key: []const u8,
    name: []const u8,
    abbrev: []const u8,
    pay_bp: types.Bp,
    officer: bool,
};

pub const table: []const RankRow = @import("ranks_zon");

// `Rank.row` indexes the table by the enum: a ladder of the wrong length
// fails the build with the table's name (a mod's ranks.zon too).
comptime {
    const ranks = @typeInfo(Rank).@"enum".fields.len;
    if (table.len != ranks) @compileError(std.fmt.comptimePrint("data/tables/ranks.zon: {d} rows for {d} ranks; one row per rank, in order", .{ table.len, ranks }));
}

test "data: the ladder has one row per rank in enum order, climbs in pay, and officers start at lieutenant" {
    // `Rank.row` indexes the table by the enum: a short or reordered ladder
    // is out of bounds or mispays, so it fails the build here.
    try std.testing.expectEqual(@typeInfo(Rank).@"enum".fields.len, table.len);
    inline for (@typeInfo(Rank).@"enum".fields) |f| {
        try std.testing.expectEqualStrings(f.name, table[f.value].key);
    }
    for (table[1..], table[0 .. table.len - 1]) |row, below| {
        try std.testing.expect(row.pay_bp >= below.pay_bp);
        try std.testing.expect(row.officer or !below.officer);
    }
    try std.testing.expect(!Rank.master_sergeant.isOfficer() and Rank.lieutenant.isOfficer());
}

test "experience earns the enlisted rank" {
    try std.testing.expectEqual(Rank.sergeant, Rank.forExperience(.veteran));
}
