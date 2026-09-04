//! The player character: origin faction and pre-command profession
//! (character creation, chosen alongside company creation). Origin decides
//! where the outfit stands up — the starter HQ lands on a weighted-random
//! world in the commander's faction space. Profession grants one small
//! permanent edge (2%, // TUNE): enough to feel, never enough to replace
//! good logistics.

const std = @import("std");
const types = @import("types.zig");

pub const Faction = enum {
    LC, // Lyran Commonwealth
    DC, // Draconis Combine
    FS, // Federated Suns
    CC, // Capellan Confederation
    FWL, // Free Worlds League

    pub fn key(self: Faction) []const u8 {
        return @tagName(self);
    }

    pub fn fullName(self: Faction) []const u8 {
        return switch (self) {
            .LC => "Lyran Commonwealth",
            .DC => "Draconis Combine",
            .FS => "Federated Suns",
            .CC => "Capellan Confederation",
            .FWL => "Free Worlds League",
        };
    }
};

pub const Profession = enum {
    quartermaster, // ran supply chains: logistics/freight costs −2%
    paymaster, // ran the books: payroll −2%
    chief_engineer, // ran the hangar: repair & maintenance costs −2%
    line_officer, // led from the cockpit: fatigue recovery +2%

    pub fn description(self: Profession) []const u8 {
        return switch (self) {
            .quartermaster => "freight & supply costs -2%",
            .paymaster => "payroll -2%",
            .chief_engineer => "repair & maintenance costs -2%",
            .line_officer => "fatigue recovery +2%",
        };
    }
};

/// The cost/rate hooks a profession can touch.
pub const BonusKind = enum { freight, payroll, repair, fatigue_recovery };

pub const bonus_bp: types.Bp = 200; // 2% // TUNE

pub const Commander = struct {
    name: []const u8,
    origin: Faction,
    profession: Profession,

    /// Multiplier for a cost category in basis points (10_000 = neutral).
    /// Costs shrink; recovery rates grow.
    pub fn costMultBp(self: *const Commander, kind: BonusKind) types.Bp {
        const matches = switch (kind) {
            .freight => self.profession == .quartermaster,
            .payroll => self.profession == .paymaster,
            .repair => self.profession == .chief_engineer,
            .fatigue_recovery => self.profession == .line_officer,
        };
        if (!matches) return 10_000;
        return if (kind == .fatigue_recovery) 10_000 + bonus_bp else 10_000 - bonus_bp;
    }
};

test "profession grants exactly one 2% edge" {
    const cmdr: Commander = .{ .name = "Erik Kalmar", .origin = .CC, .profession = .paymaster };
    try std.testing.expectEqual(@as(types.Bp, 9_800), cmdr.costMultBp(.payroll));
    try std.testing.expectEqual(@as(types.Bp, 10_000), cmdr.costMultBp(.freight));
    try std.testing.expectEqual(@as(types.Bp, 10_000), cmdr.costMultBp(.repair));

    const medic: Commander = .{ .name = "A", .origin = .LC, .profession = .line_officer };
    try std.testing.expectEqual(@as(types.Bp, 10_200), medic.costMultBp(.fatigue_recovery));
    try std.testing.expectEqual(@as(types.Bp, 10_000), medic.costMultBp(.payroll));
}
