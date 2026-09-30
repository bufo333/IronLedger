//! HQ supply-link entity (Stage 9D, ARCH §9.5): links between HQs have a
//! level (charter → scheduled → dedicated), a weekly tonnage cap, and upkeep.
//! No MekHQ counterpart: the supply network is this game's extension
//! (docs/mekhq-map.md).

const types = @import("types.zig");
const tuning = @import("tuning.zig").t;
const logistics = @import("../econ/logistics.zig");

pub const HqLink = struct {
    a: types.HqId,
    b: types.HqId,
    level: u8, // 1 charter, 2 scheduled, 3 dedicated jumpship
    tons_this_week: u32 = 0,
    established_day: u32,

    pub fn connects(self: HqLink, x: types.HqId, y: types.HqId) bool {
        return (self.a == x and self.b == y) or (self.a == y and self.b == x);
    }

    /// Tons a week the link can move.
    pub fn tonsPerWeek(self: HqLink) u32 {
        return logistics.linkTonsPerWeek(self.level);
    }

    /// True when the link is a dedicated jumpship connection (rule 24).
    pub fn isDedicated(self: HqLink) bool {
        return self.level >= logistics.dedicated_link_level;
    }

    /// Monthly upkeep by level; a dedicated line rides your own jumpship,
    /// whose carry cost is already on the hangar ledger.
    pub fn monthlyCost(self: HqLink) types.CBills {
        if (self.isDedicated()) return 0;
        return @as(types.CBills, self.level) * tuning.network.upkeep_per_level;
    }
};

/// One-time cost to establish or raise a link to `level`.
pub fn linkCost(level: u8) types.CBills {
    return @as(types.CBills, level) * @as(types.CBills, level) * tuning.network.link_cost_per_level_sq;
}

const std = @import("std");

test "isDedicated: level 2 is not dedicated, level 3 is; monthlyCost and logistics agree" {
    const lvl2: HqLink = .{ .a = @enumFromInt(1), .b = @enumFromInt(2), .level = 2, .established_day = 0 };
    const lvl3: HqLink = .{ .a = @enumFromInt(1), .b = @enumFromInt(2), .level = 3, .established_day = 0 };
    // Boundary: 2 is below, 3 is at the threshold.
    try std.testing.expect(!lvl2.isDedicated());
    try std.testing.expect(lvl3.isDedicated());
    // monthlyCost: dedicated line costs nothing (carry is on the hangar ledger).
    try std.testing.expect(lvl2.monthlyCost() > 0);
    try std.testing.expectEqual(@as(types.CBills, 0), lvl3.monthlyCost());
    // logistics.dedicated_link_level is the same threshold.
    try std.testing.expectEqual(logistics.dedicated_link_level, @as(u8, 3));
    try std.testing.expect(lvl2.level < logistics.dedicated_link_level);
    try std.testing.expect(lvl3.level >= logistics.dedicated_link_level);
    // logistics.routeCostMultBp applies the dedicated-line cost multiplier at level 3.
    const hops2 = [_]logistics.Hop{.{ .link_level = 2 }};
    const hops3 = [_]logistics.Hop{.{ .link_level = 3 }};
    // A dedicated hop costs less (logistics.dedicated_line_cost_bp ≤ 10_000).
    try std.testing.expect(logistics.routeCostMultBp(&hops3) <= logistics.routeCostMultBp(&hops2));
    // network.zig:203 (upgradeLink): `level >= logistics.dedicated_link_level` requires
    // an owned crewed jumpship — same threshold, third consumer of the constant.
    try std.testing.expectEqual(logistics.dedicated_link_level, @as(u8, 3));
}
