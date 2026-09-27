//! The player character: origin faction and pre-command profession
//! (character creation, chosen alongside company creation). Origin decides
//! where the outfit stands up — the starter HQ lands on a weighted-random
//! world in the commander's faction space. Profession grants one small
//! permanent edge (tuning.commander.bonus_bp): enough to feel, never enough to replace
//! good logistics.
//! MekHQ counterpart: the campaign commander, a flagged person; the
//! character creation is an adaptation (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("tuning.zig").t;
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

    pub fn isHouse(k: []const u8) bool {
        inline for (@typeInfo(Faction).@"enum".fields) |f| if (std.mem.eql(u8, f.name, k)) return true;
        return false;
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

pub const bonus_bp: types.Bp = tuning.commander.bonus_bp; // 2%

pub const Commander = struct {
    name: []const u8,
    origin: Faction,
    profession: Profession,
};

/// Multiplier for a cost category in basis points (10_000 = neutral).
/// Costs shrink; recovery rates grow. Returns neutral when no commander.
pub fn costMultBp(cmdr: ?Commander, kind: BonusKind) types.Bp {
    const c = cmdr orelse return 10_000;
    const matches = switch (kind) {
        .freight => c.profession == .quartermaster,
        .payroll => c.profession == .paymaster,
        .repair => c.profession == .chief_engineer,
        .fatigue_recovery => c.profession == .line_officer,
    };
    if (!matches) return 10_000;
    return if (kind == .fatigue_recovery) 10_000 + bonus_bp else 10_000 - bonus_bp;
}

test "profession grants exactly one 2% edge" {
    // null commander → neutral across all categories
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(null, .payroll));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(null, .freight));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(null, .repair));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(null, .fatigue_recovery));

    // paymaster: payroll down, others neutral
    const paym: Commander = .{ .name = "Erik Kalmar", .origin = .CC, .profession = .paymaster };
    try std.testing.expectEqual(@as(types.Bp, 9_800), costMultBp(paym, .payroll));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(paym, .freight));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(paym, .repair));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(paym, .fatigue_recovery));

    // quartermaster: freight down, others neutral
    const qm: Commander = .{ .name = "B", .origin = .DC, .profession = .quartermaster };
    try std.testing.expectEqual(@as(types.Bp, 9_800), costMultBp(qm, .freight));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(qm, .payroll));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(qm, .repair));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(qm, .fatigue_recovery));

    // chief_engineer: repair down, others neutral
    const eng: Commander = .{ .name = "C", .origin = .FS, .profession = .chief_engineer };
    try std.testing.expectEqual(@as(types.Bp, 9_800), costMultBp(eng, .repair));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(eng, .payroll));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(eng, .freight));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(eng, .fatigue_recovery));

    // line_officer: fatigue_recovery up, others neutral
    const lo: Commander = .{ .name = "A", .origin = .LC, .profession = .line_officer };
    try std.testing.expectEqual(@as(types.Bp, 10_200), costMultBp(lo, .fatigue_recovery));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(lo, .payroll));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(lo, .freight));
    try std.testing.expectEqual(@as(types.Bp, 10_000), costMultBp(lo, .repair));
}
