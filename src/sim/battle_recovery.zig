//! Shared battlefield recovery situation and individual crew escape.
//! MekHQ counterpart: campaign wreck recovery adaptation (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const force = @import("../domain/force.zig");
const contract = @import("../domain/contract.zig");
const scenario = @import("../domain/scenario.zig");
const autoresolve = @import("../domain/autoresolve.zig");
const person = @import("../domain/person.zig");
const report = @import("../domain/battle_report.zig");
const GameState = @import("state.zig").GameState;
const operations = @import("operations.zig");
const lift = @import("lift.zig");
const personnel = @import("personnel.zig");
const contract_events = @import("contract_events.zig");

/// Shared recovery modifier for one battlefield and the combined ordinary and
/// carrier wreck population. Source: ARCH section 7 and existing loss tuning.
pub fn situation(gs: *GameState, c: *const contract.Contract, battle_scenario: *const scenario.Scenario, outcome: autoresolve.Outcome, roe: force.Roe, has_salvage: bool, trucks: i64, wrecks: i64) i32 {
    const t = tuning.loss;
    const rt = t.roe;
    const task_bonus = if (operations.committedCombatOp(c)) |op| operations.operationTaskMods(gs, c, op).recovery_bonus else 0;
    return (if (has_salvage) t.recovery_salvage_lance else 0) +
        (if (trucks >= wrecks and trucks > 0) t.recovery_trucks else 0) +
        (if (lift.hasCrewedDropship(gs, c.assigned_company)) t.recovery_dropship else 0) +
        (if (outcome == .rout) t.recovery_rout else 0) +
        battle_scenario.recovery_mod + gs.diff().recovery_mod + task_bonus + switch (roe) {
        .hold => rt.hold_recovery,
        .standard => 0,
        .cautious => rt.cautious_recovery,
    };
}

/// Existing vehicle/pilot escape rule, including the role's absent-skill fallback.
/// Source: ARCH section 7 and existing loss tuning. One battle-stream 2d6 draw.
pub fn escapeRoll(gs: *GameState, id: types.PersonId, outcome: autoresolve.Outcome) ?report.RecordedRoll {
    const p = gs.person(id) orelse return null;
    if (!p.isOnBooks()) return null;
    const skill_value = (if (p.role.pilotingSkill()) |skill| p.skill(skill) else null) orelse 5;
    const value = @as(i32, gs.rng.roll2d6(.battle)) + person.skillRollBonus(skill_value) + gs.diff().recovery_mod + (if (outcome == .rout) tuning.loss.recovery_rout else 0);
    return .{ .roll = value, .target = tuning.loss.escape_target };
}

/// Failed escape uses the ordinary departure/custody/decision owners.
/// Source: ARCH section 7. Caller stages the complete battle aftermath.
pub fn captureMissing(gs: *GameState, id: types.PersonId, c: *const contract.Contract) !void {
    const p = gs.person(id) orelse return error.UnknownPerson;
    if (!p.isOnBooks()) return;
    _ = try personnel.depart(gs, id, .mia, 0, "");
    p.faction = c.enemy_key;
    try contract_events.queueMissing(gs, id, c.assigned_company);
}

test "combined wreck population prevents duplicate truck sufficiency and escape uses actual role" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const c: contract.Contract = .{ .id = @enumFromInt(1), .kind = .recon_raid, .employer_key = "LC", .enemy_key = "DC", .planet_key = "galatea", .terms = .{ .length_months = 6, .base_pay_month = 400_000 } };
    var rng = gs.rng;
    const battle_scenario = scenario.roll(&rng, .battle, c.kind);
    const ordinary = situation(&gs, &c, battle_scenario, .defeat, .standard, false, 1, 1);
    const combined = situation(&gs, &c, battle_scenario, .defeat, .standard, false, 1, 2);
    try std.testing.expectEqual(tuning.loss.recovery_trucks, ordinary - combined);
    const id = try gs.hirePerson("Actual", "Crew", .vehicle_crew);
    gs.person(id).?.skills.clearRetainingCapacity();
    var expected = gs.rng;
    const draw = expected.roll2d6(.battle);
    const result = escapeRoll(&gs, id, .defeat).?;
    try std.testing.expectEqual(@as(i32, draw) + person.skillRollBonus(5) + gs.diff().recovery_mod, result.roll);
    try captureMissing(&gs, id, &c);
    try std.testing.expectEqual(person.Status.mia, gs.person(id).?.status);
    try std.testing.expectEqualStrings(c.enemy_key, gs.person(id).?.faction);
    try std.testing.expectEqual(id, gs.event_queue.pending.items[0].person);
}
