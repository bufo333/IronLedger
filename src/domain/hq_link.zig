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

    /// Monthly upkeep by level; a dedicated line (level 3) rides your own
    /// jumpship, whose carry cost is already on the hangar ledger.
    pub fn monthlyCost(self: HqLink) types.CBills {
        if (self.level >= 3) return 0;
        return @as(types.CBills, self.level) * tuning.network.upkeep_per_level;
    }
};

/// One-time cost to establish or raise a link to `level`.
pub fn linkCost(level: u8) types.CBills {
    return @as(types.CBills, level) * @as(types.CBills, level) * tuning.network.link_cost_per_level_sq;
}
