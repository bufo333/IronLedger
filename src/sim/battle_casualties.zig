//! Shared conventional and artillery operating-crew casualties.
//! MekHQ counterpart: battle casualty adaptation (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const report = @import("../domain/battle_report.zig");
const GameState = @import("state.zig").GameState;
const medical = @import("medical.zig");
const personnel = @import("personnel.zig");

pub const Hit = struct { outcome: report.CrewOutcome = .{}, name: []const u8 = "", wounded: u8 = 0, kia: u8 = 0 };

/// Apply the ordinary battle crew hit rule to the actual person identity.
/// Source: ARCH section 7 and existing battle tuning. Battle follow-up dice retain
/// their order; injury-location dice use medical. Caller owns compound preparation.
pub fn apply(gs: *GameState, id: types.PersonId, severity: u8, has_mash: bool) !Hit {
    var result: Hit = .{};
    const p = gs.person(id) orelse return result;
    if (p.status != .active) return result;
    const tb = tuning.battle;
    const tough = p.has("toughness");
    const raw_severity: u8 = if (severity >= tb.wound_crippling_severity) 3 else if (severity >= tb.wound_serious_severity) 2 else 1;
    const wound_severity: u8 = @max(1, raw_severity -| @as(u8, @intFromBool(tough)));
    if (severity >= tb.kill_severity and !has_mash and !tough) {
        result.name = try p.rankedName(gs.allocator());
        _ = try personnel.depart(gs, id, .kia, 0, "");
        result.kia = 1;
        gs.stats.people_kia += 1;
        result.outcome.fate = .kia;
    } else if (severity >= tb.cookoff_severity) {
        result.outcome.wound = try medical.inflict(gs, id, .combat, wound_severity, "battle");
    } else if (severity >= tb.slot_hit_severity) {
        const need: u8 = if (has_mash) tb.wound_target_mash else tb.wound_target;
        if (gs.rng.roll2d6(.battle) >= need) result.outcome.wound = try medical.inflict(gs, id, .combat, wound_severity, "battle");
    }
    if (result.outcome.wound != null) {
        result.wounded = 1;
        result.name = try p.rankedName(gs.allocator());
    }
    return result;
}

test "shared crew hit records actual casualty identity and clears asset references" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try gs.hirePerson("Actual", "Crew", .vehicle_crew);
    const unit = try gs.addUnit("SCP-1N");
    gs.unit(unit).?.pilot = id;
    const result = try apply(&gs, id, tuning.battle.kill_severity, false);
    try std.testing.expectEqual(report.CrewOutcome.Fate.kia, result.outcome.fate);
    try std.testing.expectEqual(@as(u8, 1), result.kia);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.people_kia);
    try std.testing.expectEqual(types.PersonId.none, gs.unit(unit).?.pilot);
    try std.testing.expect(std.mem.indexOf(u8, result.name, "Actual Crew") != null);
    const repeated = try apply(&gs, id, tuning.battle.kill_severity, false);
    try std.testing.expectEqual(@as(u8, 0), repeated.kia);
}
