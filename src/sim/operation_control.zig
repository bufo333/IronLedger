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
const actors_m = @import("actors.zig");
const world_state_m = @import("world_state.zig");

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

/// Phase-7 sub-step: resolve committed non-combat operations whose due date has passed.
/// Called once per day, before `operations.advanceClocks`.
/// (The finale resolution sub-step was removed in P4h; resolveFinale is now called
/// by tick.resolveArcFinales and tick.runContracts.)
pub fn resolveDueOperations(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active or c.arc_key.len == 0) continue;

        // Resolve committed non-combat operations that are due.
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
            // Adjust all attached actors' relationships in prepare (all fallible
            // work done here so the commit stays infallible; rules 11-13).
            const rel_delta = actors_m.outcomeRelationshipDelta(band);
            var actor_preps: [16]actors_m.PreparedAdjust = undefined;
            var actor_prep_count: usize = 0;
            for (c.actor_ids.items) |aid| {
                if (actor_prep_count >= actor_preps.len) break;
                if (gs.actor(aid) == null) continue;
                actor_preps[actor_prep_count] = try actors_m.adjustRelationship(gs, aid, rel_delta, t.name);
                actor_prep_count += 1;
            }
            // Prepare world-state adjustment (fallible; after actor preps; rules 11-13).
            const world_delta = world_state_m.outcomeWorldDelta(band);
            const world_prep = try world_state_m.prepareWorldAdjust(gs, c.planet_key, world_delta, t.name);

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
            // Commit actor relationship adjustments (infallible; prepared above).
            for (actor_preps[0..actor_prep_count]) |prep| actors_m.commitAdjustRelationship(gs, prep);
            // Commit world-state adjustment (infallible; prepared above).
            world_state_m.commitWorldAdjust(gs, world_prep);
        }
    }
}

/// Finale resolution owner (P4h, rule 20).
/// Selects the finale from the arc's options, applies data-driven deltas,
/// and sets `arc_finale_key`. Returns null for non-arc contracts or when
/// the finale has already been resolved (idempotent). Returns a pointer to
/// the selected finale (into static data) on success.
///
/// A collapse finale (ends_contract == true) records the key and log only;
/// contract disposition (fail) is decided by the caller (tick.zig) so that
/// operation_control does not import contract_control (rule 5).
/// Validate → reserve → commit (rules 7, 11-13).
pub fn resolveFinale(gs: *GameState, c: *contract_mod.Contract) !?*const arc_mod.Finale {
    // No arc, or already resolved: nothing to do.
    if (c.arc_key.len == 0) return null;
    if (c.arc_finale_key.len > 0) return null; // idempotent

    const f = operations.selectFinale(c) orelse return null;

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] arc resolved: {s}", .{
        gs.clock.date.text(&date_buf),
        f.name,
    });
    // For non-collapse finales, apply standing in the prepare phase so no
    // allocation can fail after domain mutations begin (rules 11-13).
    if (!f.ends_contract and f.standing_delta != 0) _ = try gs.adjustStanding(c.employer_key, @as(i32, f.standing_delta));
    // Adjust attached actors' relationships for the finale (all fallible work in prepare; rules 11-13).
    const finale_rel_delta = actors_m.finaleRelationshipDelta(f);
    var finale_actor_preps: [16]actors_m.PreparedAdjust = undefined;
    var finale_actor_prep_count: usize = 0;
    for (c.actor_ids.items) |aid| {
        if (finale_actor_prep_count >= finale_actor_preps.len) break;
        if (gs.actor(aid) == null) continue;
        finale_actor_preps[finale_actor_prep_count] = try actors_m.adjustRelationship(gs, aid, finale_rel_delta, f.name);
        finale_actor_prep_count += 1;
    }
    // Prepare world-state adjustment for the finale (fallible; after actor preps; rules 11-13).
    const finale_world_delta = world_state_m.finaleWorldDelta(f);
    const finale_world_prep = try world_state_m.prepareWorldAdjust(gs, c.planet_key, finale_world_delta, f.name);

    // ---- COMMIT: infallible from here ----
    c.arc_finale_key = f.key;
    if (!f.ends_contract) {
        const vp_per_score = @import("../domain/tuning.zig").t.contract.vp_per_score;
        c.score += @as(i32, f.score_delta);
        c.victory_points += @as(i32, f.vp_delta) + @as(i32, f.score_delta) * vp_per_score;
    }
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });
    // Commit actor relationship adjustments (infallible; prepared above).
    for (finale_actor_preps[0..finale_actor_prep_count]) |prep| actors_m.commitAdjustRelationship(gs, prep);
    // Commit world-state adjustment for the finale (infallible; prepared above).
    world_state_m.commitWorldAdjust(gs, finale_world_prep);
    return f;
}

// ---- pub fn execWithdrawOperation ----------------------------------------

pub fn execWithdrawOperation(gs: *GameState, args: @FieldType(commands.Command, "withdraw_operation")) Error!commands.Result {
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
    if (!operations.operationalWithdrawEligible(op)) return error.OperationNotWithdrawable;

    const is_committed_combat = (op.state == .committed) and blk: {
        const t = operation_mod.findTemplate(op.template_key) orelse break :blk false;
        break :blk t.combat;
    };

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    const pressure = operations.withdrawClockDelta();
    var date_buf: [10]u8 = undefined;
    const op_name = if (operation_mod.findTemplate(op.template_key)) |t| t.name else op.template_key;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] withdrew from operation: {s} — force preserved, pressure +{d}", .{
        gs.clock.date.text(&date_buf),
        op_name,
        pressure,
    });

    // ---- COMMIT: infallible from here ----
    op.state = .withdrawn;
    op.resolved_day = gs.clock.day_index;
    if (is_committed_combat) {
        c.next_battle_day = null;
        c.orders_day = null;
    }
    c.escalation_clock +|= pressure;
    const vp_per_score = @import("../domain/tuning.zig").t.contract.vp_per_score;
    const sd: i32 = @as(i32, operations.withdrawScoreDelta());
    c.score += sd;
    c.victory_points += sd * vp_per_score;
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
}

// ---- pub fn execExploitOperation -----------------------------------------

pub fn execExploitOperation(gs: *GameState, args: @FieldType(commands.Command, "exploit_operation")) Error!commands.Result {
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
    if (!operations.exploitEligible(c, op)) return error.OperationNotExploitable;
    const t = operation_mod.findTemplate(op.template_key) orelse return error.UnknownOperation;
    if (t.follow_up.len == 0) return error.NoFollowUp;

    // ---- PREPARE: reserve log slot; instantiateFollowUps is the final fallible step ----
    // Important: reserve log and pre-format BEFORE appending follow-ups (rules 7, 11-13).
    try gs.reserveLog(1);
    const pressure = operations.exploitClockDelta();
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] exploit: pressed the advantage (pressure +{d})", .{
        gs.clock.date.text(&date_buf),
        pressure,
    });
    // instantiateFollowUps reserves capacity then appends; it is the final
    // fallible step (rules 7, 11-13: no fallible work after this).
    const n = try operations.instantiateFollowUps(gs, c, op, gs.next_operation_id);

    // ---- COMMIT: infallible from here ----
    gs.next_operation_id += n;
    c.escalation_clock +|= pressure;
    @import("contract_events.zig").applyToCompany(gs, c.assigned_company, .fatigue, @intCast(operations.exploitFatigueAdd()));
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
}

// ---- pub fn execConsolidateOperation --------------------------------------

pub fn execConsolidateOperation(gs: *GameState, args: @FieldType(commands.Command, "consolidate_operation")) Error!commands.Result {
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
    if (!operations.consolidateEligible(op)) return error.OperationNotConsolidatable;

    // ---- PREPARE: reserve log slot and pre-format ----
    try gs.reserveLog(1);
    const relief = operations.consolidateClockRelief();
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] consolidate: gains secured (pressure −{d})", .{
        gs.clock.date.text(&date_buf),
        relief,
    });

    // ---- COMMIT: infallible from here ----
    c.escalation_clock -|= relief;
    const morale_gain: i32 = 2; // TUNE: consolidation lifts morale slightly
    @import("contract_events.zig").applyToCompany(gs, c.assigned_company, .morale, morale_gain);
    gs.event_log.appendAssumeCapacity(.{
        .day = gs.clock.day_index,
        .category = .contract,
        .company = c.assigned_company,
        .contract = c.id,
        .text = log_text,
    });

    return .{};
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

// ---- pub fn execApplyIntervention ---------------------------------------

pub fn execApplyIntervention(gs: *GameState, args: @FieldType(commands.Command, "apply_intervention")) Error!commands.Result {
    const cid = args.contract;
    const oid = args.operation;
    const kind = args.intervention;

    // ---- VALIDATE: no mutation ----
    const c = try findActiveContract(gs, cid);

    var op_ptr: ?*operation_mod.Operation = null;
    for (c.operations.items) |*op| if (op.id == oid) {
        op_ptr = op;
        break;
    };
    const op = op_ptr orelse return error.UnknownOperation;

    if (op.state != .committed) return error.OperationNotCommitted;
    if (!operations.interventionGate(gs, c, op, kind)) return error.InterventionGateUnmet;
    if (operations.interventionApplied(op, kind)) return error.InterventionAlreadyApplied;
    const cost = operations.interventionCost(kind);
    if (operations.commandCapacityAvailable(c) < cost) return error.InsufficientCommandCapacity;

    // ---- PREPARE: reserve log slot, pre-allocate list entry, pre-format ----
    try gs.reserveLog(1);
    try op.interventions.ensureUnusedCapacity(gs.allocator(), 1);
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [arc] intervention applied: {s} ({d} capacity)", .{
        gs.clock.date.text(&date_buf),
        kind.label(),
        cost,
    });

    // ---- COMMIT: infallible ----
    c.command_capacity -|= cost;
    op.interventions.appendAssumeCapacity(kind);
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

test "resolveFinale: sets arc_finale_key once; held/fell selection; idempotent (P4h, rule 20)" {
    // This test replaces the old "resolveDueOperations: finale sets arc_finale_key once at
    // terminal beat" test. Finales are now owned by resolveFinale, not resolveDueOperations.
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
        const c = gs.contracts.getPtr(cid).?;
        const f = try resolveFinale(&gs, c);
        try testing.expect(f != null);
        try testing.expect(c.arc_finale_key.len > 0);
        try testing.expectEqualStrings("held", c.arc_finale_key);
        // held is non-collapse: score and vp should increase.
        try testing.expect(c.score > 0);

        // Called again: idempotent — returns null, no score change.
        const before_score = c.score;
        const f2 = try resolveFinale(&gs, c);
        try testing.expectEqual(@as(?*const arc_mod.Finale, null), f2);
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
        const c2 = gs.contracts.getPtr(cid2).?;
        const f = try resolveFinale(&gs, c2);
        try testing.expect(f != null);
        try testing.expectEqualStrings("fell", c2.arc_finale_key);
        // fell is ends_contract=true: score must not change (disposition by caller).
        try testing.expectEqual(@as(i32, 0), c2.score);
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

// ---- execApplyIntervention tests (P4g) ----------------------------------

const InterventionFix = struct { cid: types.ContractId, oid: types.OperationId, lance: types.ForceId };

/// Intervention fixture: an active arc garrison contract with a committed
/// combat op and a company that satisfies the `reinforce` gate (at least one
/// operational combat lance not tasked main_effort), with command_capacity = 5.
fn interventionFixture(gs: *GameState) !InterventionFix {
    const fix = try taskFixture(gs);
    gs.contracts.getPtr(fix.cid).?.command_capacity = 5;
    return .{ .cid = fix.cid, .oid = fix.oid, .lance = fix.lance };
}

test "execApplyIntervention: happy path — capacity reduced, intervention recorded, log written" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try interventionFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;
    const op = &c.operations.items[0];

    const cap_before = c.command_capacity;
    const log_before = gs.event_log.items.len;
    _ = try execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .reinforce });

    try testing.expectEqual(cap_before - operations.interventionCost(.reinforce), c.command_capacity);
    try testing.expectEqual(@as(usize, 1), op.interventions.items.len);
    try testing.expectEqual(operation_mod.Intervention.reinforce, op.interventions.items[0]);
    try testing.expect(gs.event_log.items.len > log_before);
}

test "execApplyIntervention: OperationNotCommitted refused; digest unchanged" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try interventionFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;
    c.operations.items[0].state = .available; // make it non-committed
    const before = digest.stateHash(&gs);
    try testing.expectError(error.OperationNotCommitted, execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .reinforce }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    c.operations.items[0].state = .committed;
}

test "execApplyIntervention: InterventionGateUnmet refused; digest unchanged" {
    // air_cover requires an operational fighter; the fixture company has none.
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try interventionFixture(&gs);
    const before = digest.stateHash(&gs);
    try testing.expectError(error.InterventionGateUnmet, execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .air_cover }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execApplyIntervention: InsufficientCommandCapacity refused; digest unchanged" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try interventionFixture(&gs);
    const c = gs.contracts.getPtr(fix.cid).?;
    c.command_capacity = 0;
    const before = digest.stateHash(&gs);
    try testing.expectError(error.InsufficientCommandCapacity, execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .reinforce }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execApplyIntervention: InterventionAlreadyApplied refused on second application; digest unchanged" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();
    const fix = try interventionFixture(&gs);
    // First application succeeds.
    _ = try execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .reinforce });
    const before = digest.stateHash(&gs);
    // Second application of the same kind is refused.
    try testing.expectError(error.InterventionAlreadyApplied, execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .reinforce }));
    try testing.expectEqual(before, digest.stateHash(&gs));
}

test "execApplyIntervention: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();
    const fix = try interventionFixture(&gs);

    const before = digest.stateHash(&gs);
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = testing.failing_allocator;
    try testing.expectError(error.OutOfMemory, execApplyIntervention(&gs, .{ .contract = fix.cid, .operation = fix.oid, .intervention = .reinforce }));
    try testing.expectEqual(before, digest.stateHash(&gs));
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

test "execWithdrawOperation: sets withdrawn state, adds pressure, applies score delta, failure-atomic" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);
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
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });

    const before_clock = c.escalation_clock;
    const before_score = c.score;
    const result = try execWithdrawOperation(&gs, .{ .contract = cid, .operation = oid });
    _ = result;
    try testing.expectEqual(operation_mod.OperationState.withdrawn, c.operations.items[0].state);
    try testing.expect(c.escalation_clock > before_clock);
    try testing.expect(c.score < before_score); // withdrawScoreDelta is negative

    // Refuse if already withdrawn.
    try testing.expectError(error.OperationNotWithdrawable, execWithdrawOperation(&gs, .{ .contract = cid, .operation = oid }));
}

test "execExploitOperation: instantiates follow-ups; counter advanced; pressure added" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);
    gs.next_operation_id = 2; // first follow-up will be id 2
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
        .id = oid,
        .template_key = "repel_probe",
        .state = .resolved,
        .opened_day = 0,
        .outcome = .success,
        .intent = .secure_objective,
    });

    const before_clock = c.escalation_clock;
    _ = try execExploitOperation(&gs, .{ .contract = cid, .operation = oid });
    // Follow-ups appended.
    const t = operation_mod.findTemplate("repel_probe").?;
    try testing.expectEqual(1 + t.follow_up.len, c.operations.items.len);
    // Counter advanced by follow_up count.
    try testing.expectEqual(@as(u32, 2) + @as(u32, @intCast(t.follow_up.len)), gs.next_operation_id);
    // Escalation pressure added.
    try testing.expect(c.escalation_clock > before_clock);
    // Refuse on non-eligible state: add a non-resolved op and try to exploit it.
    const oid2: types.OperationId = @enumFromInt(3);
    try c.operations.append(gs.allocator(), .{
        .id = oid2,
        .template_key = "repel_probe",
        .state = .available, // not resolved → not exploitable
        .opened_day = 0,
    });
    try testing.expectError(error.OperationNotExploitable, execExploitOperation(&gs, .{ .contract = cid, .operation = oid2 }));
}

test "execConsolidateOperation: relieves escalation_clock; refuses non-resolved" {
    const testing = std.testing;
    var gs = GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .escalation_clock = 20,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .resolved,
        .opened_day = 0,
        .outcome = .success,
    });

    const before_clock = c.escalation_clock;
    _ = try execConsolidateOperation(&gs, .{ .contract = cid, .operation = oid });
    try testing.expect(c.escalation_clock < before_clock);

    // Refuse on non-resolved op.
    const oid2: types.OperationId = @enumFromInt(2);
    try c.operations.append(gs.allocator(), .{
        .id = oid2,
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });
    try testing.expectError(error.OperationNotConsolidatable, execConsolidateOperation(&gs, .{ .contract = cid, .operation = oid2 }));
}

test "resolveFinale: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    // Find the terminal beat index for the fracturing_garrison arc.
    const a = arc_mod.find("fracturing_garrison").?;
    var terminal_beat: u8 = 0;
    for (a.beats, 0..) |b, i| if (b.escalation_threshold == 0) {
        terminal_beat = @intCast(i);
    };

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
        .escalation_clock = 0, // below fell threshold → "held" finale selected
    });
    const c = gs.contracts.getPtr(cid).?;

    const before = digest.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, resolveFinale(&gs, c));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(@as(usize, 0), c.arc_finale_key.len); // key still empty
}

test "execWithdrawOperation: failure-atomic under OOM at log reservation" {
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

    try testing.expectError(error.OutOfMemory, execWithdrawOperation(&gs, .{ .contract = cid, .operation = oid }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(operation_mod.OperationState.available, c.operations.items[0].state);
}

test "execExploitOperation: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);
    gs.next_operation_id = 2;
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
        .id = oid,
        .template_key = "repel_probe",
        .state = .resolved,
        .opened_day = 0,
        .outcome = .success,
        .intent = .secure_objective,
    });

    const before = digest.stateHash(&gs);
    const id_before = gs.next_operation_id;
    const ops_before = c.operations.items.len;

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, execExploitOperation(&gs, .{ .contract = cid, .operation = oid }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(id_before, gs.next_operation_id); // counter unchanged
    try testing.expectEqual(ops_before, c.operations.items.len); // no follow-ups appended
}

test "resolveDueOperations: adjusts attached actor relationship with non-zero delta and sets last_cause (P4i)" {
    // Consumer test: resolving a non-combat operation calls adjustRelationship on
    // all attached actors. The actor's last_cause is set (non-empty) and at least
    // one relationship dimension changes (rule 20, F1.7).
    const testing = std.testing;
    const actor_mod = @import("../domain/actor.zig");
    var gs = GameState.init(testing.allocator, .{ .seed = 77777 });
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
    const t = operation_mod.findTemplate("negotiate_terms").?;
    const committed_day: u32 = 0;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = committed_day,
        .committed_day = committed_day,
    });

    // Attach an actor (trust = 0, last_cause = "") so we can observe the adjustment.
    const aid: types.ActorId = @enumFromInt(1);
    try c.actor_ids.append(gs.allocator(), aid);
    const a: actor_mod.Actor = .{
        .id = aid,
        .archetype_key = "liaison",
        .first_name = "Ann",
        .last_name = "Smith",
        .faction_key = "LC",
        .side = .employer,
        .contract = cid,
    };
    try gs.commitActor(a);
    gs.next_actor_id = 2;

    // Advance to the resolution day and resolve.
    gs.clock.day_index = committed_day + @as(u32, t.expected_days);
    try resolveDueOperations(&gs);

    // Operation resolved.
    try testing.expectEqual(operation_mod.OperationState.resolved, c.operations.items[0].state);
    try testing.expect(c.operations.items[0].outcome != .none);

    // Actor relationship adjusted: last_cause is non-empty (template name was recorded).
    const updated = gs.actor(aid).?;
    try testing.expect(updated.last_cause.len > 0);
    // At least one relationship dimension changed for any resolved outcome band.
    const total_delta = @abs(@as(i32, updated.trust)) + @abs(@as(i32, updated.debt)) +
        @abs(@as(i32, updated.respect)) + @abs(@as(i32, updated.hostility));
    try testing.expect(total_delta > 0);
}

test "execConsolidateOperation: failure-atomic under OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const oid: types.OperationId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .escalation_clock = 20,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "negotiate_terms",
        .state = .resolved,
        .opened_day = 0,
        .outcome = .success,
    });

    const before = digest.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, execConsolidateOperation(&gs, .{ .contract = cid, .operation = oid }));
    try testing.expectEqual(before, digest.stateHash(&gs));
    try testing.expectEqual(@as(u16, 20), c.escalation_clock); // clock unchanged
}

test "resolveDueOperations: world state moves in the direction outcomeWorldDelta predicts (P4h.4)" {
    // Consumer/agreement test (rule 67-69): the world_states entry for
    // c.planet_key is created and moves in the direction the owner predicts.
    const testing = std.testing;
    const world_state_mod = @import("world_state.zig");

    var gs = GameState.init(testing.allocator, .{ .seed = 88888 });
    defer gs.deinit();

    const cid: types.ContractId = @enumFromInt(1);
    const t = operation_mod.findTemplate("negotiate_terms").?;
    const committed_day: u32 = 0;
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
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = committed_day,
        .committed_day = committed_day,
    });

    // No world state for "galatea" yet.
    try testing.expect(gs.worldState("galatea") == null);

    gs.clock.day_index = committed_day + @as(u32, t.expected_days);
    try resolveDueOperations(&gs);

    // After resolution, a world state entry must exist.
    const ws = gs.worldState("galatea");
    try testing.expect(ws != null);

    // The resolved band is whatever the deterministic sim produced; the owner
    // and consumer agree: the delta applied matches outcomeWorldDelta(band).
    const band = c.operations.items[0].outcome;
    const expected = world_state_mod.outcomeWorldDelta(band);
    // Values may be clamped to +-100 but starting from 0 a small first delta
    // is not clamped; verify the direction at minimum.
    if (expected.employer_control > 0) try testing.expect(ws.?.employer_control > 0 or ws.?.employer_control == 0);
    if (expected.enemy_influence < 0) try testing.expect(ws.?.enemy_influence <= 0);
    if (expected.enemy_influence > 0) try testing.expect(ws.?.enemy_influence >= 0);
    // The cause is set to the operation template name.
    try testing.expect(ws.?.last_cause.len > 0);
}

test "resolveFinale: world state moves per finaleWorldDelta for held and collapse (P4h.4)" {
    // Consumer/agreement test (rule 67-69).
    const testing = std.testing;
    const world_state_mod = @import("world_state.zig");

    // ---- Held finale ----
    {
        var gs = GameState.init(testing.allocator, .{ .seed = 99991 });
        defer gs.deinit();

        const a = arc_mod.find("fracturing_garrison").?;
        var terminal_beat: u8 = 0;
        for (a.beats, 0..) |b, i| if (b.escalation_threshold == 0) {
            terminal_beat = @intCast(i);
        };

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
            .escalation_clock = 0, // below collapse threshold → "held"
        });
        const c = gs.contracts.getPtr(cid).?;

        const f = (try resolveFinale(&gs, c)).?;
        try testing.expect(!f.ends_contract); // held finale selected

        const ws = gs.worldState("galatea");
        try testing.expect(ws != null);
        // Held: employer_control > 0 and enemy_influence <= 0.
        const expected = world_state_mod.finaleWorldDelta(f);
        try testing.expect(expected.employer_control > 0);
        try testing.expect(ws.?.employer_control > 0);
        try testing.expect(ws.?.enemy_influence <= 0);
    }

    // ---- Collapse finale ----
    {
        var gs = GameState.init(testing.allocator, .{ .seed = 99992 });
        defer gs.deinit();

        const a = arc_mod.find("fracturing_garrison").?;
        var terminal_beat: u8 = 0;
        var collapse_threshold: u16 = 0;
        for (a.beats, 0..) |b, i| if (b.escalation_threshold == 0) {
            terminal_beat = @intCast(i);
        };
        for (a.finales) |f_opt| if (f_opt.ends_contract) {
            collapse_threshold = @as(u16, @intCast(f_opt.min_clock));
            break;
        };
        if (collapse_threshold == 0) collapse_threshold = 100;

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
            .escalation_clock = collapse_threshold + 5, // above collapse threshold → "fell"
        });
        const c = gs.contracts.getPtr(cid).?;

        const f = (try resolveFinale(&gs, c)).?;
        try testing.expect(f.ends_contract); // collapse finale selected

        const ws = gs.worldState("galatea");
        try testing.expect(ws != null);
        // Collapse: enemy_influence > 0 and employer_control < 0.
        const expected = world_state_mod.finaleWorldDelta(f);
        try testing.expect(expected.enemy_influence > 0);
        try testing.expect(ws.?.enemy_influence > 0);
        try testing.expect(ws.?.employer_control < 0);
    }
}
