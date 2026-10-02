//! World-state rule owners: delta functions and prepare/commit mutation pair
//! for per-world bounded state (ROADMAP P4h.4, P4 operations design §§3,5).
//! No MekHQ counterpart (P4 operations design §§3,5).
//! Rule 5 / queries leaf: this module does NOT import queries.zig.

const std = @import("std");
const world_state_dom = @import("../domain/world_state.zig");
const operation_mod = @import("../domain/operation.zig");
const arc_mod = @import("../domain/arc.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

pub const WorldState = world_state_dom.WorldState;

/// Clamp a value to the world state range.
fn clampWorld(v: i32) i16 {
    return @intCast(@min(@as(i32, world_state_dom.world_max), @max(@as(i32, world_state_dom.world_min), v)));
}

/// Delta to all five world-state dimensions from a named cause.
pub const WorldDelta = struct {
    security: i16 = 0,
    civilian_support: i16 = 0,
    infrastructure_strain: i16 = 0,
    employer_control: i16 = 0,
    enemy_influence: i16 = 0,
};

/// Named outcome→world-delta owner for operation resolution (P4h.4, rule 20).
/// All values // TUNE.
pub fn outcomeWorldDelta(band: operation_mod.OutcomeBand) WorldDelta {
    return switch (band) {
        .decisive => .{ .employer_control = 5, .security = 5, .enemy_influence = -3, .infrastructure_strain = -2 }, // TUNE
        .success => .{ .employer_control = 3, .security = 2, .enemy_influence = -1, .infrastructure_strain = -1 }, // TUNE
        .partial => .{ .employer_control = 1, .security = 0, .enemy_influence = 1, .infrastructure_strain = 0 }, // TUNE
        .setback => .{ .employer_control = -1, .security = -1, .enemy_influence = 2, .infrastructure_strain = 1 }, // TUNE
        .failure => .{ .employer_control = -4, .security = -4, .enemy_influence = 6, .infrastructure_strain = 3 }, // TUNE
        .none => .{},
    };
}

/// Named finale→world-delta owner for finale resolution (P4h.4, rule 20).
/// All values // TUNE.
pub fn finaleWorldDelta(f: *const arc_mod.Finale) WorldDelta {
    if (f.ends_contract) {
        // Collapse: garrison fell — enemy influence and strain up, control and security down.
        return .{ .enemy_influence = 12, .infrastructure_strain = 8, .employer_control = -10, .security = -8 }; // TUNE
    }
    // Held: employer control and security up, enemy influence and strain down.
    return .{ .employer_control = 10, .security = 8, .enemy_influence = -8, .infrastructure_strain = -5 }; // TUNE
}

/// The prepared world-state adjustment from `prepareWorldAdjust`: all
/// fallible work is done up front so the commit phase is infallible.
pub const PreparedWorldAdjust = struct {
    planet_key: []const u8, // duped into gs.allocator()
    delta: WorldDelta,
    cause: []const u8, // duped into gs.allocator()
    log_text: []const u8, // duped into gs.allocator()
    day: u32,
};

/// PREPARE phase: reserve 1 log slot; ensure map capacity for the world key;
/// dup the key and cause; pre-format the [world] log line. All fallible.
/// `commitWorldAdjust` is infallible. Guard: if planet_key is empty, returns
/// a no-op PreparedWorldAdjust (never fired on a real contract).
pub fn prepareWorldAdjust(gs: *GameState, planet_key: []const u8, delta: WorldDelta, cause: []const u8) !PreparedWorldAdjust {
    if (planet_key.len == 0) {
        return .{ .planet_key = "", .delta = .{}, .cause = "", .log_text = "", .day = 0 };
    }
    try gs.reserveLog(1);
    try gs.world_states.ensureUnusedCapacity(gs.allocator(), 1);
    const key_dup = try gs.allocator().dupe(u8, planet_key);
    const cause_dup = try gs.allocator().dupe(u8, cause);
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [world] {s}: sec {d} civ {d} str {d} emp {d} enem {d} — {s}", .{
        gs.clock.date.text(&date_buf),
        planet_key,
        delta.security,
        delta.civilian_support,
        delta.infrastructure_strain,
        delta.employer_control,
        delta.enemy_influence,
        cause,
    });
    return .{
        .planet_key = key_dup,
        .delta = delta,
        .cause = cause_dup,
        .log_text = log_text,
        .day = gs.clock.day_index,
    };
}

/// COMMIT phase: infallible. Get-or-put the world entry (zero-init on new),
/// apply clamped delta, record cause/day, and write the pre-reserved log slot.
pub fn commitWorldAdjust(gs: *GameState, prepared: PreparedWorldAdjust) void {
    if (prepared.planet_key.len == 0) return;
    const gop = gs.world_states.getOrPutAssumeCapacity(prepared.planet_key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const ws = gop.value_ptr;
    ws.security = clampWorld(@as(i32, ws.security) + prepared.delta.security);
    ws.civilian_support = clampWorld(@as(i32, ws.civilian_support) + prepared.delta.civilian_support);
    ws.infrastructure_strain = clampWorld(@as(i32, ws.infrastructure_strain) + prepared.delta.infrastructure_strain);
    ws.employer_control = clampWorld(@as(i32, ws.employer_control) + prepared.delta.employer_control);
    ws.enemy_influence = clampWorld(@as(i32, ws.enemy_influence) + prepared.delta.enemy_influence);
    ws.last_cause = prepared.cause;
    ws.last_cause_day = prepared.day;
    gs.event_log.appendAssumeCapacity(.{
        .day = prepared.day,
        .category = .contract,
        .company = .none,
        .contract = .none,
        .text = prepared.log_text,
    });
}

// ---- Tests -----------------------------------------------------------------

test "outcomeWorldDelta: monotonic TUNE invariants" {
    const decisive = outcomeWorldDelta(.decisive);
    const success = outcomeWorldDelta(.success);
    const failure = outcomeWorldDelta(.failure);
    const setback = outcomeWorldDelta(.setback);
    const none = outcomeWorldDelta(.none);

    // Decisive raises employer_control and security.
    try std.testing.expect(decisive.employer_control > 0);
    try std.testing.expect(decisive.security > 0);
    // Decisive lowers enemy_influence.
    try std.testing.expect(decisive.enemy_influence < 0);
    // Failure raises enemy_influence and infrastructure_strain.
    try std.testing.expect(failure.enemy_influence > 0);
    try std.testing.expect(failure.infrastructure_strain > 0);
    // Failure worse than setback: higher enemy_influence.
    try std.testing.expect(failure.enemy_influence > setback.enemy_influence);
    // Decisive better than success: higher employer_control.
    try std.testing.expect(decisive.employer_control >= success.employer_control);
    // .none is zero.
    try std.testing.expectEqual(@as(i16, 0), none.employer_control);
    try std.testing.expectEqual(@as(i16, 0), none.enemy_influence);
}

test "finaleWorldDelta: held vs collapse directions" {
    const held: arc_mod.Finale = .{ .key = "held", .name = "Held", .min_clock = 0, .ends_contract = false };
    const fell: arc_mod.Finale = .{ .key = "fell", .name = "Fell", .min_clock = 40, .ends_contract = true };
    const dh = finaleWorldDelta(&held);
    const df = finaleWorldDelta(&fell);
    // Held: employer_control and security up, enemy_influence down.
    try std.testing.expect(dh.employer_control > 0);
    try std.testing.expect(dh.security > 0);
    try std.testing.expect(dh.enemy_influence < 0);
    // Collapse: enemy_influence and infrastructure_strain up, employer_control and security down.
    try std.testing.expect(df.enemy_influence > 0);
    try std.testing.expect(df.infrastructure_strain > 0);
    try std.testing.expect(df.employer_control < 0);
    try std.testing.expect(df.security < 0);
}

test "prepareWorldAdjust + commitWorldAdjust: clamp to +-100 and record cause/day" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();

    // Push security to 95 first.
    const prep1 = try prepareWorldAdjust(&gs, "galatea", .{ .security = 95 }, "setup");
    commitWorldAdjust(&gs, prep1);
    try std.testing.expectEqual(@as(i16, 95), gs.world_states.get("galatea").?.security);

    // Now add 20 more — should clamp to 100.
    const prep2 = try prepareWorldAdjust(&gs, "galatea", .{ .security = 20 }, "big_win");
    commitWorldAdjust(&gs, prep2);
    const ws = gs.world_states.get("galatea").?;
    try std.testing.expectEqual(@as(i16, 100), ws.security);
    try std.testing.expectEqualStrings("big_win", ws.last_cause);
    try std.testing.expectEqual(gs.clock.day_index, ws.last_cause_day);

    // Push enemy_influence to -200 — should clamp to -100.
    const prep3 = try prepareWorldAdjust(&gs, "galatea", .{ .enemy_influence = -200 }, "punish");
    commitWorldAdjust(&gs, prep3);
    try std.testing.expectEqual(@as(i16, -100), gs.world_states.get("galatea").?.enemy_influence);
}

test "prepareWorldAdjust + commitWorldAdjust: new key initialises from zero" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer gs.deinit();

    try std.testing.expect(gs.world_states.get("solaris_vii") == null);
    const prep = try prepareWorldAdjust(&gs, "solaris_vii", .{ .security = 10, .employer_control = 5 }, "first_op");
    commitWorldAdjust(&gs, prep);
    const ws = gs.world_states.get("solaris_vii").?;
    // Started from zero; only the delta fields changed.
    try std.testing.expectEqual(@as(i16, 10), ws.security);
    try std.testing.expectEqual(@as(i16, 5), ws.employer_control);
    try std.testing.expectEqual(@as(i16, 0), ws.civilian_support);
    try std.testing.expectEqual(@as(i16, 0), ws.infrastructure_strain);
    try std.testing.expectEqual(@as(i16, 0), ws.enemy_influence);
    try std.testing.expectEqualStrings("first_op", ws.last_cause);
}

test "prepareWorldAdjust: empty planet_key is a no-op" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();

    const before_count = gs.world_states.count();
    const prep = try prepareWorldAdjust(&gs, "", .{ .security = 10 }, "ignored");
    commitWorldAdjust(&gs, prep);
    try std.testing.expectEqual(before_count, gs.world_states.count());
}
