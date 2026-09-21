//! Contract difficulty in skulls (Stage 12E.3). No MekHQ counterpart: the
//! half-skull scale of HBS BattleTech, computed — not rolled — from the
//! power ratio the battle model itself uses, so the rating and the dice
//! agree. Data in data/tables/skulls.zon.

const std = @import("std");
const types = @import("types.zig");

pub const Band = struct { min_ratio_bp: types.Bp, half_skulls: u8 };

pub const Table = struct {
    bands: []const Band,
    outmatched_below_bp: types.Bp,
    warn_half_skulls: u8,
};

pub const table: Table = @import("skulls_zon");

/// Half skulls for a power ratio (own ÷ enemy, basis points).
pub fn fromRatioBp(ratio_bp: types.Bp) u8 {
    for (table.bands) |b| if (ratio_bp >= b.min_ratio_bp) return b.half_skulls;
    return table.bands[table.bands.len - 1].half_skulls;
}

/// Own ÷ enemy power in basis points (an enemy of nothing is no fight).
pub fn ratioBp(own_power: i64, enemy_power: i64) types.Bp {
    if (enemy_power <= 0) return 100_000;
    return @intCast(@min(100_000, @divTrunc(own_power * 10_000, enemy_power)));
}

pub fn outmatched(ratio_bp: types.Bp) bool {
    return ratio_bp < table.outmatched_below_bp;
}

/// "3.5" / "3" for half skulls.
pub fn number(buf: []u8, half: u8) []const u8 {
    return if (half % 2 == 0)
        std.fmt.bufPrint(buf, "{d}", .{half / 2}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d}.5", .{half / 2}) catch "?";
}

/// Chance (percent) that 2d6 + `mod` lands at or above `target`.
pub fn chanceAtLeast(target: i32, mod: i32) u32 {
    var hits: u32 = 0;
    for (1..7) |a| for (1..7) |b| {
        if (@as(i32, @intCast(a + b)) + mod >= target) hits += 1;
    };
    return hits * 100 / 36;
}

test "12E.3: skull bands run from half a skull to five, and line up with the battle's ratio bonus" {
    // Monotone: more power, fewer skulls.
    var last: u8 = 0;
    var r: types.Bp = 20_000;
    while (r >= 3_000) : (r -= 50) {
        const h = fromRatioBp(r);
        try std.testing.expect(h >= last);
        last = h;
    }
    // The ratio-bonus edges (battle.ratioBonus): 150/125/110/91/76/60 %.
    try std.testing.expectEqual(@as(u8, 1), fromRatioBp(15_000)); // +3
    try std.testing.expectEqual(@as(u8, 3), fromRatioBp(12_500)); // +2
    try std.testing.expectEqual(@as(u8, 5), fromRatioBp(11_000)); // +1
    try std.testing.expectEqual(@as(u8, 6), fromRatioBp(9_100)); // 0: three skulls, even
    try std.testing.expectEqual(@as(u8, 6), fromRatioBp(10_900));
    try std.testing.expectEqual(@as(u8, 8), fromRatioBp(7_600)); // −1
    try std.testing.expect(fromRatioBp(9_000) > 6);
    try std.testing.expect(outmatched(5_900) and !outmatched(6_000)); // −3
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("3.5", number(&buf, 7));
    try std.testing.expectEqualStrings("3", number(&buf, 6));
    try std.testing.expectEqual(@as(u32, 41), chanceAtLeast(8, 0)); // 15/36
    try std.testing.expectEqual(@as(u32, 100), chanceAtLeast(2, 0));
}
