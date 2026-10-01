//! Operation command handlers and tick sub-step (P4c).
//! Failure-atomic: validate (no mutation) → reserve every log slot and
//! pre-format lines → commit infallibly (appendAssumeCapacity / direct assignment).
//! Follows the validate→reserve→commit pattern (rule 7, 11-13).
//! Imports downward only: domain/* and operations.zig (rule 5).
//! No MekHQ counterpart (P4 operations design §5).

const std = @import("std");
const arc_mod = @import("../domain/arc.zig");
const operation_mod = @import("../domain/operation.zig");
const contract_mod = @import("../domain/contract.zig");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;
const operations = @import("operations.zig");
const commands = @import("commands.zig");

const Error = commands.Error;

// ---- Tuning: operation outcome effects -----------------------------------

/// Score delta per outcome band for a resolved non-combat operation. // TUNE
fn bandScoreDelta(band: operation_mod.OutcomeBand) i32 {
    return switch (band) {
        .decisive => 3, // TUNE
        .success => 2, // TUNE
        .partial => 1, // TUNE
        .setback => -1, // TUNE
        .failure => -2, // TUNE
        .none => 0,
    };
}

/// VP delta per outcome band for a resolved non-combat operation. // TUNE
fn bandVpDelta(band: operation_mod.OutcomeBand) i32 {
    return switch (band) {
        .decisive => 3, // TUNE
        .success => 2, // TUNE
        .partial => 0, // TUNE
        .setback => -1, // TUNE
        .failure => -3, // TUNE
        .none => 0,
    };
}

/// Standing delta per outcome band. // TUNE
fn bandStandingDelta(band: operation_mod.OutcomeBand) i32 {
    return switch (band) {
        .decisive => 1, // TUNE
        .success => 1, // TUNE
        .partial => 0, // TUNE
        .setback => -1, // TUNE
        .failure => -1, // TUNE
        .none => 0,
    };
}

/// Score delta for a finale by key. // TUNE
fn finaleScoreDelta(key: []const u8) i32 {
    if (std.mem.eql(u8, key, "held")) return 2; // TUNE
    if (std.mem.eql(u8, key, "fell")) return -3; // TUNE
    return 0;
}

/// VP delta for a finale. // TUNE
fn finaleVpDelta(key: []const u8) i32 {
    if (std.mem.eql(u8, key, "held")) return 3; // TUNE
    if (std.mem.eql(u8, key, "fell")) return -5; // TUNE
    return 0;
}

/// Standing delta for a finale. // TUNE
fn finaleStandingDelta(key: []const u8) i32 {
    if (std.mem.eql(u8, key, "held")) return 2; // TUNE
    if (std.mem.eql(u8, key, "fell")) return -2; // TUNE
    return 0;
}

// ---- Helper: look up a contract in the active map -----------------------

fn findActiveContract(gs: *GameState, id: types.ContractId) Error!*contract_mod.Contract {
    const c = gs.contracts.getPtr(id) orelse return error.UnknownContract;
    if (c.status != .active) return error.UnknownContract;
    return c;
}

// ---- pub fn execCommitOperation ----------------------------------------

pub fn execCommitOperation(gs: *GameState, args: @FieldType(commands.Command, "commit_operation")) Error!commands.Result {
    const cid = args.contract;
    const oid = args.operation;

    // ---- VALIDATE: no mutation ----
    const c = try findActiveContract(gs, cid);

    // Find op by id.
    var op_ptr: ?*operation_mod.Operation = null;
    for (c.operations.items) |*op| if (op.id == oid) {
        op_ptr = op;
        break;
    };
    const op = op_ptr orelse return error.UnknownOperation;
    if (op.state != .available) return error.OperationUnavailable;

    const t = operation_mod.findTemplate(op.template_key) orelse return error.UnknownOperation;
    if (!operations.operationEligible(gs, c, t)) return error.OperationUnavailable;

    if (t.combat) {
        if (!c.hasOpfor()) return error.OperationNoOpposition;
        if (operations.committedCombatOp(c) != null) return error.OperationBusy;
    }

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] committed operation: {s}", .{
        gs.clock.date.text(&date_buf),
        t.name,
    });

    // ---- COMMIT: infallible ----
    op.state = .committed;
    op.committed_day = gs.clock.day_index;
    if (t.combat) {
        const due = gs.clock.day_index + @as(u32, t.expected_days);
        c.next_battle_day = @min(c.next_battle_day orelse std.math.maxInt(u32), due);
        c.orders_day = null;
    }
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
}

// ---- pub fn execDeclineOperation ----------------------------------------

pub fn execDeclineOperation(gs: *GameState, args: @FieldType(commands.Command, "decline_operation")) Error!commands.Result {
    const cid = args.contract;
    const oid = args.operation;

    // ---- VALIDATE: no mutation ----
    const c = try findActiveContract(gs, cid);

    var op_ptr: ?*operation_mod.Operation = null;
    for (c.operations.items) |*op| if (op.id == oid) {
        op_ptr = op;
        break;
    };
    const op = op_ptr orelse return error.UnknownOperation;
    if (op.state != .available) return error.OperationUnavailable;

    const t = operation_mod.findTemplate(op.template_key) orelse return error.UnknownOperation;

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] declined operation: {s} — {s}", .{
        gs.clock.date.text(&date_buf),
        t.name,
        t.decline_note,
    });

    // ---- COMMIT: infallible ----
    op.state = .declined;
    op.resolved_day = gs.clock.day_index;
    c.escalation_clock +|= operations.declineClockDelta(t);
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
}

// ---- pub fn resolveDueOperations ----------------------------------------

/// Phase-7 sub-step: resolve committed non-combat operations whose due date
/// has passed, and select the arc finale at the terminal beat.
/// Called once per day, before `operations.advanceClocks`.
pub fn resolveDueOperations(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active or c.arc_key.len == 0) continue;

        // (a) Resolve committed non-combat operations that are due.
        for (c.operations.items) |*op| {
            if (op.state != .committed) continue;
            const t = operation_mod.findTemplate(op.template_key) orelse continue;
            if (t.combat) continue; // combat ops are resolved by battle.zig
            const due = (op.committed_day orelse continue) + @as(u32, t.expected_days);
            if (gs.clock.day_index < due) continue;

            // Reserve + pre-format before any mutation (rule 13).
            try gs.reserveLog(1);
            const band = operations.outcomeBand(operations.nonCombatScore(gs, c, t));
            const score_d = bandScoreDelta(band);
            const vp_d = bandVpDelta(band);
            const clock_d = operations.outcomeClockDelta(band);
            const standing_d = bandStandingDelta(band);
            var date_buf: [10]u8 = undefined;
            const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] operation resolved: {s} ({s})", .{
                gs.clock.date.text(&date_buf),
                t.name,
                @tagName(band),
            });
            // Apply standing in the prepare phase so no allocation can fail
            // after domain mutations begin; the entry is created here if absent
            // (rules 11-13: prepare must complete before the first mutation).
            if (standing_d != 0) _ = try gs.adjustStanding(c.employer_key, standing_d);

            // Commit: infallible from here.
            op.state = .resolved;
            op.resolved_day = gs.clock.day_index;
            op.outcome = band;
            c.score += score_d;
            c.victory_points += vp_d;
            if (clock_d < 0) {
                const relief: u16 = @intCast(@min(@as(i32, c.escalation_clock), -clock_d));
                c.escalation_clock -= relief;
            } else {
                c.escalation_clock +|= @as(u16, @intCast(clock_d));
            }
            gs.event_log.appendAssumeCapacity(.{
                .day = gs.clock.day_index,
                .category = .contract,
                .company = c.assigned_company,
                .contract = c.id,
                .text = log_text,
            });
        }

        // (b) Finale resolution: at the terminal beat, if not yet selected.
        if (c.arc_finale_key.len > 0) continue; // already resolved
        const a = arc_mod.find(c.arc_key) orelse continue;
        if (c.arc_beat >= a.beats.len) continue;
        const beat = a.beats[c.arc_beat];
        if (beat.escalation_threshold != 0) continue; // not terminal yet

        const finale = operations.selectFinale(c) orelse continue;

        // Reserve + pre-format before any mutation (rule 13).
        try gs.reserveLog(1);
        const s_d = finaleScoreDelta(finale.key);
        const vp_d = finaleVpDelta(finale.key);
        const std_d = finaleStandingDelta(finale.key);
        var date_buf: [10]u8 = undefined;
        const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] arc resolved: {s}", .{
            gs.clock.date.text(&date_buf),
            finale.name,
        });
        // Apply standing in the prepare phase so no allocation can fail
        // after domain mutations begin (rules 11-13).
        if (std_d != 0) _ = try gs.adjustStanding(c.employer_key, std_d);

        // Commit: infallible from here.
        c.arc_finale_key = finale.key;
        c.score += s_d;
        c.victory_points += vp_d;
        gs.event_log.appendAssumeCapacity(.{
            .day = gs.clock.day_index,
            .category = .contract,
            .company = c.assigned_company,
            .contract = c.id,
            .text = log_text,
        });
    }
}

// ------------------------------------------------------------------ tests

test "execCommitOperation: available → committed, sets committed_day" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });

    const result = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid });
    _ = result;

    const op = &c.operations.items[0];
    try testing.expectEqual(operation_mod.OperationState.committed, op.state);
    try testing.expectEqual(@as(?u32, gs.clock.day_index), op.committed_day);
}

test "execCommitOperation: combat op sets next_battle_day" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .enemy_lances = 2,
        .enemy_lance_bv = 5000,
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(2);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
    });

    _ = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid });

    const t = operation_mod.findTemplate("repel_probe").?;
    const expected_day = gs.clock.day_index + @as(u32, t.expected_days);
    try testing.expectEqual(@as(?u32, expected_day), c.next_battle_day);
}

test "execCommitOperation: refuses non-active contract, unknown op, non-available state, combat-no-opfor, already-committed-combat" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    // Non-active contract.
    const cid_offer: types.ContractId = @enumFromInt(99);
    try gs.contracts.put(gs.allocator(), cid_offer, .{
        .id = cid_offer,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .offer,
    });
    try testing.expectError(error.UnknownContract, execCommitOperation(&gs, .{ .contract = cid_offer, .operation = @enumFromInt(1) }));

    // Active contract.
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });

    // Unknown operation id.
    try testing.expectError(error.UnknownOperation, execCommitOperation(&gs, .{ .contract = cid, .operation = @enumFromInt(999) }));

    // Op in non-available state.
    c.operations.items[0].state = .committed;
    try testing.expectError(error.OperationUnavailable, execCommitOperation(&gs, .{ .contract = cid, .operation = oid }));
    c.operations.items[0].state = .available;

    // Combat op with no opfor.
    const oid2: types.OperationId = @enumFromInt(2);
    try c.operations.append(gs.allocator(), .{
        .id = oid2,
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
    });
    try testing.expectError(error.OperationNoOpposition, execCommitOperation(&gs, .{ .contract = cid, .operation = oid2 }));

    // Add opfor; first combat op committed; second should be refused.
    c.enemy_lances = 2;
    c.enemy_lance_bv = 5000;
    _ = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid2 });
    const oid3: types.OperationId = @enumFromInt(3);
    try c.operations.append(gs.allocator(), .{
        .id = oid3,
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
    });
    try testing.expectError(error.OperationBusy, execCommitOperation(&gs, .{ .contract = cid, .operation = oid3 }));
}

test "execDeclineOperation: available → declined, clock rises" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .escalation_clock = 0,
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });

    const t = operation_mod.findTemplate("negotiate_terms").?;
    const expected_delta = operations.declineClockDelta(t);

    _ = try execDeclineOperation(&gs, .{ .contract = cid, .operation = oid });

    const op = &c.operations.items[0];
    try testing.expectEqual(operation_mod.OperationState.declined, op.state);
    try testing.expectEqual(@as(?u32, gs.clock.day_index), op.resolved_day);
    try testing.expectEqual(expected_delta, c.escalation_clock);
}

test "resolveDueOperations: resolves exactly at committed_day + expected_days, not before" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .escalation_clock = 5,
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    const committed_day: u32 = gs.clock.day_index;
    const t = operation_mod.findTemplate("negotiate_terms").?;
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = committed_day,
        .committed_day = committed_day,
    });

    // One day before due: not resolved yet.
    gs.clock.day_index = committed_day + @as(u32, t.expected_days) - 1;
    try resolveDueOperations(&gs);
    try testing.expectEqual(operation_mod.OperationState.committed, c.operations.items[0].state);

    // Exactly at due day: resolves.
    gs.clock.day_index = committed_day + @as(u32, t.expected_days);
    try resolveDueOperations(&gs);
    try testing.expectEqual(operation_mod.OperationState.resolved, c.operations.items[0].state);
    try testing.expect(c.operations.items[0].outcome != .none);
    try testing.expectEqual(@as(?u32, gs.clock.day_index), c.operations.items[0].resolved_day);
}

test "resolveDueOperations: finale sets arc_finale_key once at terminal beat" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const a = arc_mod.find("fracturing_garrison").?;
    // Find the terminal beat index (escalation_threshold == 0).
    var terminal_beat: u8 = 0;
    for (a.beats, 0..) |b, i| if (b.escalation_threshold == 0) {
        terminal_beat = @intCast(i);
    };

    // Held finale (low clock → held).
    {
        const cid: types.ContractId = @enumFromInt(1);
        try gs.contracts.put(gs.allocator(), cid, .{
            .id = cid,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .arc_key = "fracturing_garrison",
            .arc_beat = terminal_beat,
            .escalation_clock = 0, // below fell threshold → "held"
        });
        try resolveDueOperations(&gs);
        const c = gs.contracts.getPtr(cid).?;
        try testing.expect(c.arc_finale_key.len > 0);
        try testing.expectEqualStrings("held", c.arc_finale_key);

        // Called again: no change (already resolved).
        const before_score = c.score;
        try resolveDueOperations(&gs);
        try testing.expectEqual(before_score, c.score);
    }

    // Fell finale (high clock → fell).
    {
        const cid2: types.ContractId = @enumFromInt(2);
        // Find the fell finale's min_clock.
        var fell_min: u16 = 40;
        for (a.finales) |f| if (f.min_clock > 0) {
            fell_min = f.min_clock;
        };
        try gs.contracts.put(gs.allocator(), cid2, .{
            .id = cid2,
            .kind = .garrison_duty,
            .employer_key = "LC",
            .enemy_key = "DC",
            .planet_key = "galatea",
            .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
            .status = .active,
            .arc_key = "fracturing_garrison",
            .arc_beat = terminal_beat,
            .escalation_clock = fell_min,
        });
        try resolveDueOperations(&gs);
        const c2 = gs.contracts.getPtr(cid2).?;
        try testing.expectEqualStrings("fell", c2.arc_finale_key);
    }
}

test "execCommitOperation: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });

    const before = digest.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, execCommitOperation(&gs, .{ .contract = cid, .operation = oid }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(operation_mod.OperationState.available, c.operations.items[0].state);
}

test "execDeclineOperation: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .escalation_clock = 5,
    });
    const c = gs.contracts.getPtr(cid).?;
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });

    const before = digest.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, execDeclineOperation(&gs, .{ .contract = cid, .operation = oid }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(operation_mod.OperationState.available, c.operations.items[0].state);
    try testing.expectEqual(@as(u16, 5), c.escalation_clock);
}

test "resolveDueOperations: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const committed_day: u32 = 0;
    const t = operation_mod.findTemplate("negotiate_terms").?;
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = committed_day,
        .committed_day = committed_day,
    });

    gs.clock.day_index = committed_day + @as(u32, t.expected_days);
    const before = digest.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, resolveDueOperations(&gs));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(operation_mod.OperationState.committed, c.operations.items[0].state);
}
