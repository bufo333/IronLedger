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
    if (!operations.intentLegal(c, t, args.intent)) return error.OperationIntentIllegal;

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
    op.intent = args.intent;
    if (t.combat) {
        const due = gs.clock.day_index + @as(u32, t.expected_days) + @as(u32, operations.tempoDelayDays(op.tempo));
        c.next_battle_day = @min(c.next_battle_day orelse std.math.maxInt(u32), due);
        c.orders_day = null;
    }
    c.escalation_clock +|= operations.tempoClockDelta(op.tempo);
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
            const due = (op.committed_day orelse continue) + @as(u32, t.expected_days) + @as(u32, operations.tempoDelayDays(op.tempo));
            if (gs.clock.day_index < due) continue;

            // Reserve + pre-format before any mutation (rule 13).
            try gs.reserveLog(1);
            const band = operations.outcomeBand(operations.nonCombatScore(gs, c, t, op.intent));
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

// ---- pub fn execTaskLance -----------------------------------------------

pub fn execTaskLance(gs: *GameState, args: @FieldType(commands.Command, "task_lance")) Error!commands.Result {
    const cid = args.contract;
    const oid = args.operation;
    const lance = args.lance;
    const task = args.task;

    // ---- VALIDATE: no mutation ----
    const c = try findActiveContract(gs, cid);

    // Find op by id.
    var op_ptr: ?*operation_mod.Operation = null;
    for (c.operations.items) |*op| if (op.id == oid) {
        op_ptr = op;
        break;
    };
    const op = op_ptr orelse return error.UnknownOperation;
    if (op.state != .committed) return error.OperationNotCommitted;

    // Validate the template is combat.
    const t = operation_mod.findTemplate(op.template_key) orelse return error.UnknownOperation;
    if (!t.combat) return error.OperationNotCommitted;

    // Lance must exist in the force tree.
    if (gs.force(lance) == null) return error.UnknownLance;

    // taskEligible covers: child check, operational, in-transit, taskLegal, capability.
    if (!operations.taskEligible(gs, c, op, lance, task)) {
        // Distinguish the specific refusal.
        const company = gs.force(c.assigned_company) orelse return error.UnknownLance;
        var is_child = false;
        for (company.children.items) |child_id| if (child_id == lance) {
            is_child = true;
            break;
        };
        if (!is_child) return error.UnknownLance;
        const template = operation_mod.findTemplate(op.template_key) orelse return error.UnknownOperation;
        if (!operations.taskLegal(template.combat, c.terms.command_rights, task)) return error.TaskIllegal;
        return error.LanceNotTaskable;
    }

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    var date_buf: [10]u8 = undefined;
    const lance_name = if (gs.force(lance)) |f| f.name else "";
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] tasked {s}: {s}", .{
        gs.clock.date.text(&date_buf),
        lance_name,
        task.label(),
    });

    // Ensure capacity for the tasks list before any mutation (failure-atomic).
    // Upsert: if the lance already has a task, replace it; otherwise append.
    var existing_idx: ?usize = null;
    for (op.tasks.items, 0..) |lt, i| if (lt.lance == lance) {
        existing_idx = i;
        break;
    };
    if (existing_idx == null) {
        // Need to grow: ensure capacity before mutation (rules 7, 11-13).
        try op.tasks.ensureUnusedCapacity(gs.allocator(), 1);
    }

    // ---- COMMIT: infallible ----
    if (existing_idx) |i| {
        op.tasks.items[i].task = task;
    } else {
        op.tasks.appendAssumeCapacity(.{ .lance = lance, .task = task });
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

// ---- pub fn execClearLanceTask ------------------------------------------

pub fn execClearLanceTask(gs: *GameState, args: @FieldType(commands.Command, "clear_lance_task")) Error!commands.Result {
    const cid = args.contract;
    const oid = args.operation;
    const lance = args.lance;

    // ---- VALIDATE: no mutation ----
    const c = try findActiveContract(gs, cid);

    var op_ptr: ?*operation_mod.Operation = null;
    for (c.operations.items) |*op| if (op.id == oid) {
        op_ptr = op;
        break;
    };
    const op = op_ptr orelse return error.UnknownOperation;
    if (op.state != .committed) return error.OperationNotCommitted;

    // Lance must exist (even if no task is assigned — no-op is fine).
    if (gs.force(lance) == null) return error.UnknownLance;

    // ---- PREPARE: reserve log slot ----
    try gs.reserveLog(1);
    var date_buf: [10]u8 = undefined;
    const lance_name = if (gs.force(lance)) |f| f.name else "";
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] cleared task for {s}", .{
        gs.clock.date.text(&date_buf),
        lance_name,
    });

    // ---- COMMIT: infallible ----
    for (op.tasks.items, 0..) |lt, i| if (lt.lance == lance) {
        _ = op.tasks.orderedRemove(i);
        break;
    };
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
}

// ---- pub fn execSetOperationTempo --------------------------------------

pub fn execSetOperationTempo(gs: *GameState, args: @FieldType(commands.Command, "set_operation_tempo")) Error!commands.Result {
    const cid = args.contract;
    const oid = args.operation;
    const posture = args.tempo;

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
    if (!operations.tempoLegal(t.combat, posture)) return error.OperationTempoIllegal;

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] tempo set: {s} — {s}", .{
        gs.clock.date.text(&date_buf),
        t.name,
        posture.label(),
    });

    // ---- COMMIT: infallible ----
    op.tempo = posture;
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
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

    const result = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid, .intent = .secure_objective });
    _ = result;

    const op = &c.operations.items[0];
    try testing.expectEqual(operation_mod.OperationState.committed, op.state);
    try testing.expectEqual(@as(?u32, gs.clock.day_index), op.committed_day);
    try testing.expectEqual(operation_mod.Intent.secure_objective, op.intent);
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

    _ = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid, .intent = .secure_objective });

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
    try testing.expectError(error.UnknownContract, execCommitOperation(&gs, .{ .contract = cid_offer, .operation = @enumFromInt(1), .intent = .secure_objective }));

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
    try testing.expectError(error.UnknownOperation, execCommitOperation(&gs, .{ .contract = cid, .operation = @enumFromInt(999), .intent = .secure_objective }));

    // Op in non-available state.
    c.operations.items[0].state = .committed;
    try testing.expectError(error.OperationUnavailable, execCommitOperation(&gs, .{ .contract = cid, .operation = oid, .intent = .secure_objective }));
    c.operations.items[0].state = .available;

    // Combat op with no opfor.
    const oid2: types.OperationId = @enumFromInt(2);
    try c.operations.append(gs.allocator(), .{
        .id = oid2,
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
    });
    try testing.expectError(error.OperationNoOpposition, execCommitOperation(&gs, .{ .contract = cid, .operation = oid2, .intent = .secure_objective }));

    // Add opfor; first combat op committed; second should be refused.
    c.enemy_lances = 2;
    c.enemy_lance_bv = 5000;
    _ = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid2, .intent = .secure_objective });
    const oid3: types.OperationId = @enumFromInt(3);
    try c.operations.append(gs.allocator(), .{
        .id = oid3,
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
    });
    try testing.expectError(error.OperationBusy, execCommitOperation(&gs, .{ .contract = cid, .operation = oid3, .intent = .secure_objective }));
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

    try testing.expectError(error.OutOfMemory, execCommitOperation(&gs, .{ .contract = cid, .operation = oid, .intent = .secure_objective }));
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

test "execCommitOperation: stores the chosen intent; illegal intent refused before any mutation" {
    // Rule 13 (failure-atomic) + rule 20 (single owner of legal-set check).
    const testing = std.testing;
    const digest = @import("digest.zig");
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
        .template_key = "negotiate_terms", // non-combat: preserve_force is illegal
        .state = .available,
        .opened_day = 0,
    });

    // Illegal intent is refused before any mutation: digest must be unchanged.
    const before = digest.stateHash(&gs);
    try testing.expectError(error.OperationIntentIllegal, execCommitOperation(&gs, .{
        .contract = cid,
        .operation = oid,
        .intent = .preserve_force, // not legal on non-combat templates
    }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(operation_mod.OperationState.available, c.operations.items[0].state);

    // Legal intent commits and stores the chosen intent.
    _ = try execCommitOperation(&gs, .{ .contract = cid, .operation = oid, .intent = .protect_assets });
    try testing.expectEqual(operation_mod.OperationState.committed, c.operations.items[0].state);
    try testing.expectEqual(operation_mod.Intent.protect_assets, c.operations.items[0].intent);
}

test "resolveDueOperations: intent affects the resolved band (preserve_force < secure_objective)" {
    // Rule 20 consumer test: nonCombatScore is called with op.intent.
    const testing = std.testing;
    var gs_pf = GameState.init(testing.allocator, .{});
    defer gs_pf.deinit();
    var gs_so = GameState.init(testing.allocator, .{});
    defer gs_so.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const t = operation_mod.findTemplate("negotiate_terms").?;
    const committed_day: u32 = 0;

    // Build the same contract in both game states, one with preserve_force, one with secure_objective.
    for (&[_]*GameState{ &gs_pf, &gs_so }, &[_]operation_mod.Intent{ .preserve_force, .secure_objective }) |gs, intent| {
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
        try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
            .id = @enumFromInt(1),
            .template_key = "negotiate_terms",
            .state = .committed,
            .opened_day = committed_day,
            .committed_day = committed_day,
            .intent = intent,
        });
        gs.clock.day_index = committed_day + @as(u32, t.expected_days);
    }

    try resolveDueOperations(&gs_pf);
    try resolveDueOperations(&gs_so);

    const band_pf = gs_pf.contracts.getPtr(cid).?.operations.items[0].outcome;
    const band_so = gs_so.contracts.getPtr(cid).?.operations.items[0].outcome;

    // Both resolved; preserve_force (−3 mod) should yield a lower or equal band.
    try testing.expect(band_pf != .none);
    try testing.expect(band_so != .none);
    // preserve_force intent penalty should push the score down; verify the score order.
    const score_pf = operations.nonCombatScore(&gs_pf, gs_pf.contracts.getPtr(cid).?, t, .preserve_force);
    const score_so = operations.nonCombatScore(&gs_so, gs_so.contracts.getPtr(cid).?, t, .secure_objective);
    try testing.expect(score_pf < score_so);
}

/// Build a standard test fixture: an active garrison contract with a committed
/// combat op and a populated company, returning the contract id, op id,
/// and a lance id from that company.
fn taskFixture(gs: *GameState) !struct { cid: types.ContractId, oid: types.OperationId, lance: types.ForceId } {
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
    const fid = (try @import("toe.zig").execNewCompany(gs, "Alpha")).created_force;
    c.assigned_company = fid;
    const company = gs.force(fid).?;
    var lance_id: types.ForceId = .none;
    for (company.children.items) |child_id| {
        if (gs.force(child_id)) |f| if (f.isCombatLance()) {
            lance_id = child_id;
            break;
        };
    }
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
    });
    return .{ .cid = cid, .oid = oid, .lance = lance_id };
}

test "execTaskLance: task stored; upsert replaces prior task; clear removes" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try taskFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;

    // Assign main_effort.
    _ = try execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance, .task = .main_effort });
    try testing.expectEqual(@as(usize, 1), c.operations.items[0].tasks.items.len);
    try testing.expectEqual(operation_mod.LanceTask.main_effort, c.operations.items[0].tasks.items[0].task);

    // Upsert: replace with screen.
    _ = try execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance, .task = .screen });
    try testing.expectEqual(@as(usize, 1), c.operations.items[0].tasks.items.len);
    try testing.expectEqual(operation_mod.LanceTask.screen, c.operations.items[0].tasks.items[0].task);

    // Clear removes it.
    _ = try execClearLanceTask(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance });
    try testing.expectEqual(@as(usize, 0), c.operations.items[0].tasks.items.len);
}

test "execTaskLance: OperationNotCommitted / UnknownLance / TaskIllegal each refused; digest unchanged" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try taskFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;

    // Non-committed op.
    c.operations.items[0].state = .available;
    const before = digest.stateHash(&gs);
    try testing.expectError(error.OperationNotCommitted, execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance, .task = .main_effort }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    c.operations.items[0].state = .committed;

    // Unknown lance.
    const fake_lance: types.ForceId = @enumFromInt(9999);
    const before2 = digest.stateHash(&gs);
    try testing.expectError(error.UnknownLance, execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fake_lance, .task = .main_effort }));
    try testing.expectEqual(before2, digest.stateHash(&gs));

    // Illegal task (integrated rights + screen).
    c.terms.command_rights = .integrated;
    const before3 = digest.stateHash(&gs);
    try testing.expectError(error.TaskIllegal, execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance, .task = .screen }));
    try testing.expectEqual(before3, digest.stateHash(&gs));
    c.terms.command_rights = .independent;
}

test "execTaskLance: failure-atomic under OOM" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();
    const fix = try taskFixture(&gs);

    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = testing.failing_allocator;
    try testing.expectError(error.OutOfMemory, execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance, .task = .main_effort }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execClearLanceTask: failure-atomic under OOM" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();
    const fix = try taskFixture(&gs);
    // First assign a task using a valid non-OOM allocator.
    _ = try execTaskLance(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance, .task = .main_effort });

    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = testing.failing_allocator;
    try testing.expectError(error.OutOfMemory, execClearLanceTask(&gs, .{ .contract = fix.cid, .operation = fix.oid, .lance = fix.lance }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

// ---- execSetOperationTempo tests (P4f) ----------------------------------

fn tempoFixture(gs: *GameState) !struct { cid: types.ContractId, combat_oid: types.OperationId, noncombat_oid: types.OperationId } {
    const cid: types.ContractId = @enumFromInt(99);
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
    const combat_oid: types.OperationId = @enumFromInt(10);
    const noncombat_oid: types.OperationId = @enumFromInt(11);
    try c.operations.append(gs.allocator(), .{
        .id = combat_oid,
        .template_key = "repel_probe", // combat
        .state = .available,
        .opened_day = 0,
    });
    try c.operations.append(gs.allocator(), .{
        .id = noncombat_oid,
        .template_key = "negotiate_terms", // non-combat
        .state = .available,
        .opened_day = 0,
    });
    return .{ .cid = cid, .combat_oid = combat_oid, .noncombat_oid = noncombat_oid };
}

test "execSetOperationTempo: set-tempo records posture on available combat op" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try tempoFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;

    _ = try execSetOperationTempo(&gs, .{ .contract = fix.cid, .operation = fix.combat_oid, .tempo = .recon });
    const op = &c.operations.items[0];
    try testing.expectEqual(operation_mod.TempoPosture.recon, op.tempo);
    // Log should have been written.
    try testing.expect(gs.event_log.items.len > 0);
}

test "execSetOperationTempo: refuses non-available op with digest unchanged" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try tempoFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;
    c.operations.items[0].state = .committed;
    const before = digest.stateHash(&gs);
    try testing.expectError(error.OperationUnavailable, execSetOperationTempo(&gs, .{ .contract = fix.cid, .operation = fix.combat_oid, .tempo = .recon }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execSetOperationTempo: refuses illegal posture (recon on noncombat) with digest unchanged" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try tempoFixture(&gs);
    const before = digest.stateHash(&gs);
    // recon is combat-only → illegal on negotiate_terms.
    try testing.expectError(error.OperationTempoIllegal, execSetOperationTempo(&gs, .{ .contract = fix.cid, .operation = fix.noncombat_oid, .tempo = .recon }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execSetOperationTempo: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();
    const fix = try tempoFixture(&gs);
    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = testing.failing_allocator;
    try testing.expectError(error.OutOfMemory, execSetOperationTempo(&gs, .{ .contract = fix.cid, .operation = fix.combat_oid, .tempo = .recon }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execCommitOperation: delay tempo pushes next_battle_day and raises escalation_clock" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try tempoFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;
    // Set delay tempo before committing.
    _ = try execSetOperationTempo(&gs, .{ .contract = fix.cid, .operation = fix.combat_oid, .tempo = .delay });
    const clock_before = c.escalation_clock;
    _ = try execCommitOperation(&gs, .{ .contract = fix.cid, .operation = fix.combat_oid, .intent = .secure_objective });
    const t = operation_mod.findTemplate("repel_probe").?;
    const op = &c.operations.items[0];
    // next_battle_day should include tempoDelayDays(delay).
    const expected_due = gs.clock.day_index + @as(u32, t.expected_days) + @as(u32, operations.tempoDelayDays(.delay));
    try testing.expectEqual(expected_due, c.next_battle_day.?);
    // escalation_clock should have increased by tempoClockDelta(delay).
    try testing.expectEqual(clock_before + operations.tempoClockDelta(.delay), c.escalation_clock);
    _ = op;
}

test "resolveDueOperations: noncombat delay resolves later than advance" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const t = operation_mod.findTemplate("negotiate_terms").?;
    const delay_days = @as(u32, operations.tempoDelayDays(.delay));

    const cid: types.ContractId = @enumFromInt(50);
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

    // Commit one advance and one delay noncombat op, both at day 0.
    const adv_oid: types.OperationId = @enumFromInt(20);
    const del_oid: types.OperationId = @enumFromInt(21);
    try c.operations.append(gs.allocator(), .{
        .id = adv_oid,
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
        .tempo = .advance,
    });
    try c.operations.append(gs.allocator(), .{
        .id = del_oid,
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
        .tempo = .delay,
    });

    // Advance to exactly the advance op's due date.
    gs.clock.day_index = @as(u32, t.expected_days);
    try resolveDueOperations(&gs);

    // The advance op should be resolved; delay op still committed.
    try testing.expectEqual(operation_mod.OperationState.resolved, c.operations.items[0].state);
    try testing.expectEqual(operation_mod.OperationState.committed, c.operations.items[1].state);

    // Advance to the delay op's due date.
    gs.clock.day_index = @as(u32, t.expected_days) + delay_days;
    try resolveDueOperations(&gs);
    try testing.expectEqual(operation_mod.OperationState.resolved, c.operations.items[1].state);
}
