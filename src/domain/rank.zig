//! Ranks (Stage 12B.4). Mirrors MekHQ `personnel/ranks/Ranks` with one
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

test "the ladder matches the enum, climbs in pay, and officers start at lieutenant" {
    try std.testing.expectEqual(@typeInfo(Rank).@"enum".fields.len, table.len);
    inline for (@typeInfo(Rank).@"enum".fields) |f| {
        const r: Rank = @enumFromInt(f.value);
        try std.testing.expectEqualStrings(f.name, r.row().key);
    }
    try std.testing.expect(Rank.colonel.payBp() > Rank.private.payBp());
    try std.testing.expect(!Rank.master_sergeant.isOfficer() and Rank.lieutenant.isOfficer());
    try std.testing.expectEqual(Rank.sergeant, Rank.forExperience(.veteran));
}
