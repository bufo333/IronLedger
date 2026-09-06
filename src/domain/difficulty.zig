//! Difficulty (12.32): four levels on the BattleTech experience ladder,
//! loaded at comptime from data/tables/difficulty.zon and type-checked
//! here. A level scales the economy and the opposition — contract margin,
//! fabrication premium, purchase markup, enemy strength, turnover
//! pressure — and never the dice: skill rolls, repair odds and healing are
//! the sim's physics on every level. MekHQ counterpart: none directly;
//! CampaignOptions' economy sliders come closest.

const std = @import("std");
const types = @import("types.zig");

pub const Level = enum(u8) {
    green,
    regular,
    veteran,
    elite,

    pub fn next(self: Level) Level {
        return @enumFromInt((@intFromEnum(self) + 1) % 4);
    }
};

pub const Row = struct {
    key: []const u8,
    name: []const u8,
    contract_pay_bp: types.Bp,
    fab_cost_bp: types.Bp,
    purchase_bp: types.Bp,
    enemy_bp: types.Bp,
    turnover_delta: i32,
    blurb: []const u8,
};

pub const Table = struct {
    levels: []const Row,
};

pub const table: Table = @import("difficulty_zon");

/// The row for a level; the table is in enum order.
pub fn get(level: Level) *const Row {
    return &table.levels[@intFromEnum(level)];
}

/// "×1.47" for a basis-point multiplier (unsigned on purpose: a padded
/// signed fraction prints its sign).
pub fn multText(buf: []u8, bp: types.Bp) []const u8 {
    const whole: u32 = @intCast(@divTrunc(bp, 10_000));
    const frac: u32 = @intCast(@divTrunc(@mod(bp, 10_000), 100));
    return std.fmt.bufPrint(buf, "×{d}.{d:0>2}", .{ whole, frac }) catch "×?";
}

pub fn parse(name: []const u8) ?Level {
    return std.meta.stringToEnum(Level, name);
}

test "the table lists every level in enum order, and regular is the game as tuned" {
    try std.testing.expectEqual(@as(usize, 4), table.levels.len);
    inline for (@typeInfo(Level).@"enum".fields) |f| {
        try std.testing.expectEqualStrings(f.name, table.levels[f.value].key);
    }
    const r = get(.regular);
    try std.testing.expectEqual(@as(types.Bp, 10_000), r.contract_pay_bp);
    try std.testing.expectEqual(@as(types.Bp, 10_000), r.fab_cost_bp);
    try std.testing.expectEqual(@as(i32, 0), r.turnover_delta);
    // Harder pays less and costs more, monotonically.
    var i: usize = 1;
    while (i < table.levels.len) : (i += 1) {
        try std.testing.expect(table.levels[i].contract_pay_bp < table.levels[i - 1].contract_pay_bp);
        try std.testing.expect(table.levels[i].fab_cost_bp > table.levels[i - 1].fab_cost_bp);
        try std.testing.expect(table.levels[i].enemy_bp > table.levels[i - 1].enemy_bp);
    }
    try std.testing.expectEqual(Level.regular, parse("regular").?);
    try std.testing.expectEqual(Level.green, Level.elite.next());
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("×1.47", multText(&buf, 14_700));
    try std.testing.expectEqualStrings("×0.61", multText(&buf, 6_100));
}
