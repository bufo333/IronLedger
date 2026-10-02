//! Operation rule owners: arc eligibility, operation eligibility, quotes,
//! outcome resolution, escalation-clock advancement, and finale selection.
//! Every rule is owned here; callers call these functions, never re-derive
//! the logic (rules 3, 20).
//! No MekHQ counterpart (P4 operations design §§5-8).

const std = @import("std");
const arc_mod = @import("../domain/arc.zig");
const operation_mod = @import("../domain/operation.zig");
const contract_mod = @import("../domain/contract.zig");
const types = @import("../domain/types.zig");
const GameState = @import("state.zig").GameState;
const readiness = @import("readiness.zig");
const toe = @import("toe.zig");
const hq_ops = @import("hq_ops.zig");

/// Quote returned by `operationQuote` for a single operation template.
pub const Quote = struct {
    /// Expected days to resolution (tuning data, not a guarantee). // TUNE
    expected_days: u16,
    /// Legal intents for this template × command rights combination (rule 20).
    /// Points to a module-level constant; owned by `legalIntents`.
    legal_intents: []const operation_mod.Intent,
    /// The one intent the employer has mandated (integrated command rights only).
    /// Null when the commander has a free choice.
    mandated: ?operation_mod.Intent,
};

// --- Intent legal-set constants (docs/p4-operations-design.md §6 decision 2) ---
// Module-level so the slices have static lifetime; `legalIntents` returns pointers to them.
const combat_intents = [_]operation_mod.Intent{ .preserve_force, .secure_objective, .break_enemy, .protect_assets, .secure_intelligence, .recover };
const noncombat_intents = [_]operation_mod.Intent{ .secure_objective, .protect_assets, .secure_intelligence, .recover };
const integrated_intents = [_]operation_mod.Intent{.secure_objective};

/// Rule owner: the intent mandated by `integrated` command rights (docs/p4-operations-design.md §6 decision 2).
/// Integrated employers command the objective; the commander has no choice.
pub fn mandatedIntent(combat: bool) operation_mod.Intent {
    _ = combat; // the mandated intent is the same regardless of template type // TUNE
    return .secure_objective;
}

/// Rule owner: the set of legal intents for this template × command-rights combination.
/// `integrated` returns a single-element slice (the mandated intent).
/// `house`/`liaison`/`independent` return the full set for the template type.
/// Returned slice points to a module-level constant; lifetime is static (rule 26).
pub fn legalIntents(combat: bool, rights: contract_mod.CommandRights) []const operation_mod.Intent {
    if (rights == .integrated) return &integrated_intents;
    return if (combat) &combat_intents else &noncombat_intents;
}

/// Rule owner: is the given intent legal for this template × command-rights combination?
/// Consumer predicate — callers use this rather than inspecting the legal set (rule 20).
pub fn intentLegal(c: *const contract_mod.Contract, t: *const operation_mod.OperationTemplate, intent: operation_mod.Intent) bool {
    for (legalIntents(t.combat, c.terms.command_rights)) |li| if (li == intent) return true;
    return false;
}

/// Intent profile: deterministic post-roll modifiers applied when a committed combat
/// operation has this intent (docs/p4-operations-design.md §6 decision 3, rule 57).
/// All values are // TUNE — balance balance balance; no RNG involved.
pub const IntentProfile = struct {
    /// Basis-point multiplier for the score contribution of the engagement (10_000 = ×1.0). // TUNE
    score_bp: i32,
    /// Basis-point multiplier for the VP contribution of the engagement (10_000 = ×1.0). // TUNE
    vp_bp: i32,
    /// Whether the salvage claim is permitted for this intent. // TUNE
    salvage_allowed: bool,
    /// Extra fatigue added to the company after the engagement. // TUNE
    fatigue_add: u8,
};

/// Rule owner: the intent profile for a committed combat operation (rule 20).
/// All return values are // TUNE balance constants.
pub fn intentProfile(intent: operation_mod.Intent) IntentProfile {
    return switch (intent) {
        .preserve_force => .{ .score_bp = 7_000, .vp_bp = 7_000, .salvage_allowed = false, .fatigue_add = 0 }, // TUNE: retreat focus reduces scoring; forgo salvage
        .secure_objective => .{ .score_bp = 10_000, .vp_bp = 10_000, .salvage_allowed = true, .fatigue_add = 0 }, // TUNE: baseline
        .break_enemy => .{ .score_bp = 13_000, .vp_bp = 13_000, .salvage_allowed = true, .fatigue_add = 2 }, // TUNE: aggressive push earns more and is exhausting
        .protect_assets => .{ .score_bp = 10_000, .vp_bp = 10_500, .salvage_allowed = false, .fatigue_add = 0 }, // TUNE: protecting assets focuses effort, forgoes salvage
        .secure_intelligence => .{ .score_bp = 9_000, .vp_bp = 10_500, .salvage_allowed = false, .fatigue_add = 0 }, // TUNE: intel focus reduces raw score
        .recover => .{ .score_bp = 8_500, .vp_bp = 9_000, .salvage_allowed = false, .fatigue_add = 1 }, // TUNE: recovery mission reduces scoring and adds fatigue
    };
}

/// Rule owner: did the operation succeed given the resolved intent and outcome band?
/// Success is intent-relative (docs/p4-operations-design.md §6 decision 4, rule 20).
/// `none` always returns false (not yet resolved).
pub fn operationSucceeded(intent: operation_mod.Intent, band: operation_mod.OutcomeBand) bool {
    if (band == .none) return false;
    return switch (intent) {
        .preserve_force => band != .failure, // TUNE: succeeds short of a rout
        .secure_objective => band == .success or band == .decisive, // TUNE: needs at least a win
        .break_enemy => band == .success or band == .decisive, // TUNE: needs victory or decisive
        .protect_assets => band != .failure and band != .setback, // TUNE: partial or better
        .secure_intelligence => band != .failure and band != .setback, // TUNE: partial or better
        .recover => band != .failure and band != .setback, // TUNE: partial or better
    };
}

/// Rule owner: is the given arc eligible for this contract kind?
/// An arc is eligible when the kind's tag name appears in arc.kinds.
pub fn arcEligible(a: *const arc_mod.Arc, kind: contract_mod.ContractKind) bool {
    const tag = @tagName(kind);
    for (a.kinds) |k| if (std.mem.eql(u8, k, tag)) return true;
    return false;
}

/// Rule owner: the single arc eligible for a contract kind at acceptance,
/// or null when none applies. Deterministic in P4b (exactly one arc per
/// garrison/security vertical slice); when several become eligible later
/// this takes an rng stream (P4 design §6 — not added until first roll).
pub fn selectArcKeyFor(kind: contract_mod.ContractKind) ?[]const u8 {
    for (0..arc_mod.table.arcs.len) |i| {
        const a = &arc_mod.table.arcs[i];
        if (arcEligible(a, kind)) return a.key;
    }
    return null;
}

/// Rule owner: may this operation be offered now?
/// Gates (P4b): contract is active, arc_key non-empty, template's arc_key
/// matches the contract's arc_key. command_rights gate is a stub (P4g).
pub fn operationEligible(gs: *const GameState, c: *const contract_mod.Contract, t: *const operation_mod.OperationTemplate) bool {
    _ = gs;
    if (c.status != .active) return false;
    if (c.arc_key.len == 0) return false;
    if (!std.mem.eql(u8, t.arc_key, c.arc_key)) return false;
    return true; // command_rights gate: stub true (P4g adds it)
}

/// Rule owner: the quote (expected days, stakes) for one operation on a contract.
/// Pure (rule 26); exposes legal intents and any mandate for planning views.
pub fn operationQuote(gs: *const GameState, c: *const contract_mod.Contract, t: *const operation_mod.OperationTemplate) Quote {
    _ = gs;
    const li = legalIntents(t.combat, c.terms.command_rights);
    const mandated: ?operation_mod.Intent = if (c.terms.command_rights == .integrated)
        mandatedIntent(t.combat)
    else
        null;
    return .{
        .expected_days = t.expected_days,
        .legal_intents = li,
        .mandated = mandated,
    };
}

/// Rule owner: map a resolution score to an outcome band (pure; no roll).
/// Score < 0 → failure; 0-4 → setback; 5-9 → partial; 10-14 → success;
/// >= 15 → decisive. All boundaries carry // TUNE.
pub fn outcomeBand(score: i32) operation_mod.OutcomeBand {
    if (score < 0) return .failure; // TUNE
    if (score < 5) return .setback; // TUNE
    if (score < 10) return .partial; // TUNE
    if (score < 15) return .success; // TUNE
    return .decisive; // TUNE
}

/// Rule owner: escalation ticks accrued per active day for a contract's arc.
/// Deterministic daily accumulation; no RNG (design §6, P4c adds first roll).
pub fn escalationStep(c: *const contract_mod.Contract) u16 {
    _ = c;
    return 1; // TUNE: 1 escalation tick per active contract day
}

/// Rule owner: the finale selected from the arc's options given the current
/// escalation clock. Selects the eligible finale with the highest min_clock
/// (i.e. the most dramatic outcome the clock earned); falls back to min_clock==0.
/// P4b stub (returns min_clock==0 only) is replaced here (P4c).
pub fn selectFinale(c: *const contract_mod.Contract) ?*const arc_mod.Finale {
    const a = arc_mod.find(c.arc_key) orelse return null;
    // Walk the finales; keep the one with the highest min_clock that is ≤ the clock.
    var best: ?*const arc_mod.Finale = null;
    for (0..a.finales.len) |i| {
        const f = &a.finales[i];
        if (f.min_clock == 0) {
            if (best == null) best = f; // fallback
        } else if (f.min_clock <= c.escalation_clock) {
            if (best == null or f.min_clock > best.?.min_clock) best = f;
        }
    }
    return best;
}

/// Rule owner: map an engagement outcome to an OutcomeBand (pure, no roll).
/// decisive_victory/victory → success; draw → partial; defeat → setback; rout → failure.
pub fn combatBand(outcome: @import("../domain/autoresolve.zig").Outcome) operation_mod.OutcomeBand {
    return switch (outcome) {
        .decisive_victory => .decisive, // TUNE
        .victory => .success, // TUNE
        .draw => .partial, // TUNE
        .defeat => .setback, // TUNE
        .rout => .failure, // TUNE
    };
}

/// Rule owner: deterministic non-combat resolution score for one operation.
/// Inputs: base + command_rights term + employer_standing term + intent term (all // TUNE).
/// Pure; no RNG (docs/p4-operations-design.md §6, P4c non-combat is deterministic).
pub fn nonCombatScore(gs: *GameState, c: *const contract_mod.Contract, t: *const operation_mod.OperationTemplate, intent: operation_mod.Intent) i32 {
    _ = t;
    const base: i32 = 8; // TUNE: default non-combat outcome
    const rights_bonus: i32 = @divTrunc(c.terms.command_rights.gapDelta() * -1, 2); // TUNE: independent rights help negotiation
    const standing_bonus: i32 = @divTrunc(gs.standing(c.employer_key), 20); // TUNE: standing/20 bonus
    const intent_mod: i32 = switch (intent) {
        .preserve_force => -3, // TUNE: holding back does not advance the operation's goal
        .secure_objective => 0, // TUNE: baseline
        .break_enemy => -2, // TUNE: aggression is wasteful in non-combat work
        .protect_assets => 2, // TUNE: protection aligns with non-combat operations
        .secure_intelligence => 2, // TUNE: intelligence gathering aligns with non-combat work
        .recover => 1, // TUNE: recovery is compatible with non-combat operations
    };
    return base + rights_bonus + standing_bonus + intent_mod;
}

/// Rule owner: how the escalation clock moves after a resolved operation.
/// Relief (negative) for success/decisive; pressure (positive) for failure/setback/partial;
/// neutral for none. // TUNE
pub fn outcomeClockDelta(band: operation_mod.OutcomeBand) i32 {
    return switch (band) {
        .decisive => -6, // TUNE
        .success => -3, // TUNE
        .partial => 0, // TUNE
        .setback => 4, // TUNE
        .failure => 8, // TUNE
        .none => 0,
    };
}

/// Rule owner: clock pressure applied when a player declines an operation.
/// Promotes the "pressure_increase" decline_note label to a typed tuned effect.
pub fn declineClockDelta(t: *const operation_mod.OperationTemplate) u16 {
    const pressure_increase_note = "pressure_increase";
    const base: u16 = 3; // TUNE: default decline clock bump
    const high: u16 = 6; // TUNE: named "pressure_increase" bump
    return if (std.mem.eql(u8, t.decline_note, pressure_increase_note)) high else base;
}

/// Find the first committed combat operation on this contract, if any.
pub fn committedCombatOp(c: *const contract_mod.Contract) ?*operation_mod.Operation {
    for (c.operations.items) |*op| {
        if (op.state != .committed) continue;
        const t = operation_mod.findTemplate(op.template_key) orelse continue;
        if (t.combat) return op;
    }
    return null;
}

// ---- Lance task owners (docs/p4-operations-design.md §7, rule 20) ------

// Module-level task-set constants (static lifetime; `legalTasks` returns pointers to them).
const all_tasks = [_]operation_mod.LanceTask{ .screen, .main_effort, .reserve, .escort, .objective_security, .recovery, .recon };
const integrated_tasks = [_]operation_mod.LanceTask{ .main_effort, .objective_security, .recovery }; // TUNE: integrated command restricts the task set

/// Rule owner: the set of legal tasks for a combat × command-rights combination
/// (docs/p4-operations-design.md §7 decision 6, rule 20).
/// Non-combat operations return an empty set; `integrated` returns the restricted set.
/// Returned slice points to a module-level constant; lifetime is static (rule 26).
pub fn legalTasks(combat: bool, rights: contract_mod.CommandRights) []const operation_mod.LanceTask {
    if (!combat) return &.{};
    if (rights == .integrated) return &integrated_tasks; // TUNE: integrated employers command the line
    return &all_tasks;
}

/// Rule owner: is the given task legal for this combat × command-rights combination?
/// Consumer predicate — callers use this rather than inspecting the legal set (rule 20).
pub fn taskLegal(combat: bool, rights: contract_mod.CommandRights, task: operation_mod.LanceTask) bool {
    return std.mem.indexOfScalar(operation_mod.LanceTask, legalTasks(combat, rights), task) != null;
}

/// Rule owner: does the company have the capability required for this task?
/// (docs/p4-operations-design.md §7, rule 20). Pure capability check; no RNG.
pub fn taskCapabilitySatisfied(gs: *GameState, c: *const contract_mod.Contract, task: operation_mod.LanceTask) bool {
    return switch (task) {
        .recovery => blk: {
            // Recovery requires an operational salvage support lance. // TUNE
            const sl = toe.supportLance(gs, c.assigned_company, .salvage) orelse break :blk false;
            break :blk readiness.forceOperational(gs, sl);
        },
        .escort => true, // capability check deferred to P4f // TUNE
        else => true, // all other tasks: always satisfied // TUNE
    };
}

/// Rule owner: is this lance eligible to receive this task on this operation?
/// (docs/p4-operations-design.md §7 decision 6, rule 20).
/// Returns false (not an error) for any failing check; the caller decides the refusal text.
pub fn taskEligible(gs: *GameState, c: *const contract_mod.Contract, op: *const operation_mod.Operation, lance: types.ForceId, task: operation_mod.LanceTask) bool {
    // Op must be committed and combat.
    if (op.state != .committed) return false;
    const t = operation_mod.findTemplate(op.template_key) orelse return false;
    if (!t.combat) return false;
    // Lance must be a direct combat child of the assigned company.
    const company = gs.force(c.assigned_company) orelse return false;
    // Company must not be returning home (in-transit).
    if (company.return_eta_day != null) return false;
    var is_child = false;
    for (company.children.items) |child_id| {
        if (child_id == lance) {
            is_child = true;
            break;
        }
    }
    if (!is_child) return false;
    const lance_force = gs.force(lance) orelse return false;
    if (!lance_force.isCombatLance()) return false;
    // Lance must be operational.
    if (!readiness.forceOperational(gs, lance_force)) return false;
    // Task must be legal and capability satisfied.
    if (!taskLegal(t.combat, c.terms.command_rights, task)) return false;
    if (!taskCapabilitySatisfied(gs, c, task)) return false;
    return true;
}

/// Per-task battle modifiers (docs/p4-operations-design.md §7, rule 20).
/// All values // TUNE — balance constants.
pub const TaskProfile = struct {
    /// Basis-point multiplier for this lance's line power contribution. // TUNE
    line_power_bp: i32,
    /// Additive bonus to scenario_mod (reduces enemy surprise). // TUNE
    surprise_reduction: i32,
    /// This lance acts as a reserve (floor on bad opening hit_pct). // TUNE
    reserve: bool,
    /// Recovery roll modifier for recoverWrecks. // TUNE
    recovery_bonus: i32,
    /// Additive basis-point bonus to op success score. // TUNE
    op_success_bonus: i32,
    /// Suppresses convoy hit when present. // TUNE
    convoy_protect: bool,
    /// Exposure rating (informational; for future use). // TUNE
    exposure: i32,
};

/// Rule owner: the task profile for a committed combat operation (rule 20).
/// All return values are // TUNE balance constants.
pub fn taskProfile(task: operation_mod.LanceTask) TaskProfile {
    return switch (task) {
        .main_effort => .{ .line_power_bp = 12_000, .surprise_reduction = 0, .reserve = false, .recovery_bonus = 0, .op_success_bonus = 0, .convoy_protect = false, .exposure = 200 }, // TUNE
        .screen => .{ .line_power_bp = 10_000, .surprise_reduction = 2, .reserve = false, .recovery_bonus = 0, .op_success_bonus = 0, .convoy_protect = false, .exposure = 100 }, // TUNE
        .recon => .{ .line_power_bp = 10_000, .surprise_reduction = 3, .reserve = false, .recovery_bonus = 0, .op_success_bonus = 0, .convoy_protect = false, .exposure = 50 }, // TUNE
        .reserve => .{ .line_power_bp = 10_000, .surprise_reduction = 0, .reserve = true, .recovery_bonus = 0, .op_success_bonus = 0, .convoy_protect = false, .exposure = 0 }, // TUNE
        .escort => .{ .line_power_bp = 8_000, .surprise_reduction = 0, .reserve = false, .recovery_bonus = 0, .op_success_bonus = 0, .convoy_protect = true, .exposure = 150 }, // TUNE
        .recovery => .{ .line_power_bp = 9_000, .surprise_reduction = 0, .reserve = false, .recovery_bonus = 2, .op_success_bonus = 0, .convoy_protect = false, .exposure = 50 }, // TUNE
        .objective_security => .{ .line_power_bp = 11_000, .surprise_reduction = 0, .reserve = false, .recovery_bonus = 0, .op_success_bonus = 200, .convoy_protect = false, .exposure = 100 }, // TUNE
    };
}

/// Return the task assigned to this lance on the operation, or null.
pub fn lanceTask(op: *const operation_mod.Operation, lance: types.ForceId) ?operation_mod.LanceTask {
    for (op.tasks.items) |lt| if (lt.lance == lance) return lt.task;
    return null;
}

/// Apply the lance's task line-power scaling (or return base_power unchanged).
/// Pure; no RNG. Applied in playerSideIn (rule 20).
pub fn lanceTaskPower(op: *const operation_mod.Operation, lance: types.ForceId, base_power: i64) i64 {
    const t = lanceTask(op, lance) orelse return base_power;
    return types.applyBp(base_power, taskProfile(t).line_power_bp);
}

/// Aggregate task modifiers for the opening roll and aftermath (not per-lance).
pub const TaskMods = struct {
    surprise_reduction: i32 = 0,
    reserve_present: bool = false,
    recovery_bonus: i32 = 0,
    escort_present: bool = false,
    objective_bonus: i32 = 0,
};

/// Rule owner: aggregate task modifiers across all assignments on the committed op
/// (docs/p4-operations-design.md §7, rule 20). Deterministic; no RNG.
pub fn operationTaskMods(gs: *GameState, c: *const contract_mod.Contract, op: *const operation_mod.Operation) TaskMods {
    _ = gs;
    _ = c;
    var mods: TaskMods = .{};
    for (op.tasks.items) |lt| {
        const p = taskProfile(lt.task);
        mods.surprise_reduction += p.surprise_reduction;
        if (p.reserve) mods.reserve_present = true;
        mods.recovery_bonus += p.recovery_bonus;
        if (p.convoy_protect) mods.escort_present = true;
        mods.objective_bonus += p.op_success_bonus;
    }
    return mods;
}

/// Rule owner: did this tasked lance succeed given the engagement outcome
/// and whether the field was held? (docs/p4-operations-design.md §7, rule 20).
pub fn taskSucceeded(task: operation_mod.LanceTask, band: operation_mod.OutcomeBand, held_field: bool) bool {
    return switch (task) {
        .main_effort, .objective_security => band != .failure and band != .setback, // TUNE: needs at least partial
        .reserve => held_field, // TUNE: succeeded if the field was not lost
        .escort, .screen, .recon => band != .failure, // TUNE: anything short of a rout
        .recovery => band == .success or band == .decisive, // TUNE: needs a win to recover
    };
}

// ---- Tempo owners (docs/p4-operations-design.md §7 decision 7, P4f, rule 20) --

// Module-level constants (static lifetime; `tempoLegal` returns values from these).
const legal_tempo_combat = [_]operation_mod.TempoPosture{ .advance, .recon, .prepare, .delay };
const legal_tempo_noncombat = [_]operation_mod.TempoPosture{ .advance, .delay };

/// Rule owner: is the given tempo posture legal for this operation type?
/// `prepare` and `recon` are combat-only; `advance` and `delay` are always legal.
pub fn tempoLegal(combat: bool, posture: operation_mod.TempoPosture) bool {
    const set: []const operation_mod.TempoPosture = if (combat) &legal_tempo_combat else &legal_tempo_noncombat;
    for (set) |p| if (p == posture) return true;
    return false;
}

/// Rule owner: the set of legal tempo postures for a given operation type.
/// Returned slice points to a module-level constant; lifetime is static (rule 26).
pub fn legalTempo(combat: bool) []const operation_mod.TempoPosture {
    return if (combat) &legal_tempo_combat else &legal_tempo_noncombat;
}

/// Tempo profile: deterministic battle-phase modifiers applied when a committed
/// combat operation has this tempo posture (P4f, rule 20). All values // TUNE.
pub const TempoProfile = struct {
    /// Additive bonus to scenario_mod (reduces enemy surprise). // TUNE
    surprise_reduction: i32,
    /// Additive bonus to scenario_mod (preparation increases readiness). // TUNE
    prepared_roll_bonus: i32,
};

/// Rule owner: the tempo profile for a committed operation (rule 20).
/// `advance` always returns all-zero so pre-P4f outcomes are unchanged.
/// All return values are // TUNE balance constants.
pub fn tempoProfile(posture: operation_mod.TempoPosture) TempoProfile {
    return switch (posture) {
        .advance => .{ .surprise_reduction = 0, .prepared_roll_bonus = 0 }, // TUNE: baseline — no change
        .recon => .{ .surprise_reduction = 2, .prepared_roll_bonus = 0 }, // TUNE: recon cuts enemy surprise
        .prepare => .{ .surprise_reduction = 0, .prepared_roll_bonus = 2 }, // TUNE: preparation improves readiness
        .delay => .{ .surprise_reduction = 0, .prepared_roll_bonus = 0 }, // TUNE: delay delays, no direct battle mod
    };
}

/// Rule owner: added days before operation resolution for this posture.
/// `advance` = 0 so no change to existing operations (P4f, rule 20). // TUNE
pub fn tempoDelayDays(posture: operation_mod.TempoPosture) u16 {
    return switch (posture) {
        .advance => 0, // TUNE: no delay — act at once
        .recon => 7, // TUNE: one week to gather intelligence
        .prepare => 7, // TUNE: one week to prepare a position
        .delay => 14, // TUNE: two weeks — significant operational pause
    };
}

/// Rule owner: escalation-clock pressure added at commit for this posture.
/// `advance` = 0 so no change to existing operations (P4f, rule 20). // TUNE
pub fn tempoClockDelta(posture: operation_mod.TempoPosture) u16 {
    return switch (posture) {
        .advance => 0, // TUNE: no additional escalation — act immediately
        .recon => 3, // TUNE: short delay costs some escalation pressure
        .prepare => 3, // TUNE: moderate delay — preparation costs escalation
        .delay => 6, // TUNE: delay is costlier — higher escalation pressure
    };
}

/// Rule owner: aggregate tempo modifiers for the opening roll (P4f, rule 20).
/// Returns `tempoProfile(op.tempo)` for the committed op.
/// Deterministic; no RNG.
pub fn operationTempoMods(op: *const operation_mod.Operation) TempoProfile {
    return tempoProfile(op.tempo);
}

/// Instantiate the opening operation(s) onto a pre-commit local contract copy.
/// `id_start` is the first ID to assign; the caller (commit phase) is
/// responsible for advancing `gs.next_operation_id` after all fallible steps
/// succeed (rules 7, 11-13: the counter must not advance before commit).
/// Failure-atomic: reserves list capacity before assigning any IDs, so an
/// OOM returns without mutating live GameState.
pub fn instantiateOpening(gs: *GameState, c: *contract_mod.Contract, id_start: u32) !void {
    if (c.arc_key.len == 0) return;
    const a = arc_mod.find(c.arc_key) orelse return;
    // Reserve capacity first — the only fallible step — before any id
    // is assigned (failure-atomic, rules 7, 11-13).
    try c.operations.ensureUnusedCapacity(gs.allocator(), a.opening.len);
    // Infallible from here: capacity guaranteed, ids assigned in order.
    for (a.opening, 0..) |tkey, i| {
        const id: types.OperationId = @enumFromInt(id_start + @as(u32, @intCast(i)));
        c.operations.appendAssumeCapacity(.{
            .id = id,
            .template_key = tkey,
            .state = .available,
            .opened_day = gs.clock.day_index,
        });
    }
}

/// Phase-7 sub-step: advance each active, arc-bearing contract's escalation
/// clock by one tick per day, and advance the beat when the threshold is
/// crossed. Failure-atomic per contract: the log slot is reserved before any
/// clock or beat mutation (rules 17, 69).
pub fn advanceClocks(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active or c.arc_key.len == 0) continue;
        const a = arc_mod.find(c.arc_key) orelse continue;
        if (c.arc_beat >= a.beats.len) continue;
        const beat = a.beats[c.arc_beat];
        // Terminal beat (threshold 0) waits for finale selection (P4h).
        if (beat.escalation_threshold == 0) continue;

        const step = escalationStep(c);
        const will_advance = (c.escalation_clock + step >= beat.escalation_threshold) and
            (c.arc_beat + 1 < a.beats.len);

        if (will_advance) {
            // Reserve log and pre-format before any mutation (rule 17).
            try gs.reserveLog(1);
            var date_buf: [10]u8 = undefined;
            const log_text = try std.fmt.allocPrint(
                gs.allocator(),
                "{s} [arc] {s}: beat advances to {s} (clock {d}/{d})",
                .{
                    gs.clock.date.text(&date_buf),
                    a.name,
                    a.beats[c.arc_beat + 1].name,
                    c.escalation_clock + step,
                    beat.escalation_threshold,
                },
            );
            // Infallible from here.
            // Reset the clock relative to the beat's threshold so the next
            // beat's threshold measures elapsed time from this transition point
            // (not cumulative from acceptance).  Excess ticks carry over.
            c.escalation_clock = (c.escalation_clock + step) - beat.escalation_threshold;
            c.arc_beat += 1;
            gs.event_log.appendAssumeCapacity(.{
                .day = gs.clock.day_index,
                .category = .contract,
                .company = c.assigned_company,
                .contract = c.id,
                .text = log_text,
            });
        } else {
            c.escalation_clock += step;
        }
    }
}

// ---- Command-capacity and intervention owners (P4g, rule 20) ----------------

/// Rule owner: the supplying HQ for a contract's assigned company.
/// Location-sensitive rule: only the home HQ counts (rule 22).
pub fn commandCapacityHq(gs: *GameState, c: *const contract_mod.Contract) types.HqId {
    return gs.homeHqFor(c.assigned_company);
}

/// Rule owner: monthly command-capacity grant from the supplying HQ and
/// the global commander. Deterministic; no RNG (P4g). // TUNE
pub fn commandGrant(gs: *GameState, c: *const contract_mod.Contract) u8 {
    const max_grant: u8 = 8; // TUNE: absolute ceiling on the monthly grant
    const hq_id = commandCapacityHq(gs, c);
    const hq = gs.hqs.getPtr(hq_id) orelse return 2;
    var grant: u32 = 2; // TUNE: base grant
    if (gs.commander != null) grant += 1; // TUNE: commander present
    // +1 per 2 admin_command desks staffed at the supplying HQ. // TUNE
    const cmd_staff = hq_ops.hqStaff(gs, hq_id, .admin_command).count;
    grant += cmd_staff / 2; // TUNE
    if (hq.effectiveFacilityLevel(.comms) >= 2) grant += 1; // TUNE: comms ≥ 2
    return @intCast(@min(max_grant, grant));
}

/// Rule owner: carry-over ceiling = grant × 2. // TUNE
pub fn commandCap(gs: *GameState, c: *const contract_mod.Contract) u8 {
    return commandGrant(gs, c) *| 2; // TUNE
}

/// Rule owner: capacity withheld by the employer based on command rights.
/// Integrated employers reserve more attention for their own demands (P4g). // TUNE
pub fn employerReserved(rights: contract_mod.CommandRights) u8 {
    return switch (rights) {
        .integrated => 2, // TUNE: integrated employer withholds 2
        .house => 1, // TUNE: house liaison withholds 1
        .liaison, .independent => 0, // TUNE: independent commands withold nothing
    };
}

/// Rule owner: command capacity the player may actually spend on the current contract.
pub fn commandCapacityAvailable(c: *const contract_mod.Contract) u8 {
    return c.command_capacity -| employerReserved(c.terms.command_rights);
}

/// Rule owner: command-capacity cost per intervention type (P4g). // TUNE
pub fn interventionCost(kind: operation_mod.Intervention) u8 {
    return switch (kind) {
        .emergency_recon => 1, // TUNE
        .reinforce => 2, // TUNE: costs more — needs a reserve lance
        .air_cover => 1, // TUNE
        .field_repair => 1, // TUNE
    };
}

/// Deterministic battle-phase modifiers applied when this intervention is active.
/// Feeds the two existing `scenario_mod` knobs (P4g, rule 20). All values // TUNE.
pub const InterventionProfile = struct {
    /// Additive bonus to scenario_mod (reduces enemy surprise). // TUNE
    surprise_reduction: i32,
    /// Additive bonus to scenario_mod (preparation increases readiness). // TUNE
    prepared_roll_bonus: i32,
};

/// Rule owner: the intervention profile for one intervention type (P4g, rule 20).
/// All values // TUNE.
pub fn interventionProfile(kind: operation_mod.Intervention) InterventionProfile {
    return switch (kind) {
        .emergency_recon => .{ .surprise_reduction = 2, .prepared_roll_bonus = 0 }, // TUNE
        .reinforce => .{ .surprise_reduction = 0, .prepared_roll_bonus = 2 }, // TUNE
        .air_cover => .{ .surprise_reduction = 0, .prepared_roll_bonus = 1 }, // TUNE
        .field_repair => .{ .surprise_reduction = 0, .prepared_roll_bonus = 2 }, // TUNE
    };
}

/// Rule owner: is this intervention already applied to the operation?
pub fn interventionApplied(op: *const operation_mod.Operation, kind: operation_mod.Intervention) bool {
    for (op.interventions.items) |iv| if (iv == kind) return true;
    return false;
}

/// Rule owner: may this intervention be applied to this committed combat operation?
/// Gates: op must be committed+combat, and the kind's distinct asset gate holds (P4g).
pub fn interventionGate(gs: *GameState, c: *const contract_mod.Contract, op: *const operation_mod.Operation, kind: operation_mod.Intervention) bool {
    if (op.state != .committed) return false;
    const t = operation_mod.findTemplate(op.template_key) orelse return false;
    if (!t.combat) return false;
    return switch (kind) {
        .emergency_recon => blk: {
            // Needs an operational scouting/recon lance OR comms ≥ 1 at the supplying HQ.
            const company = gs.force(c.assigned_company) orelse break :blk false;
            for (company.children.items) |child_id| {
                const child = gs.force(child_id) orelse continue;
                if (child.echelon == .lance and child.role == .scouting and readiness.forceOperational(gs, child))
                    break :blk true;
            }
            const hq_id = commandCapacityHq(gs, c);
            const hq = gs.hqs.getPtr(hq_id) orelse break :blk false;
            break :blk hq.effectiveFacilityLevel(.comms) >= 1;
        },
        .reinforce => blk: {
            // Needs an operational combat child lance not already tasked main_effort.
            const company = gs.force(c.assigned_company) orelse break :blk false;
            for (company.children.items) |child_id| {
                const child = gs.force(child_id) orelse continue;
                if (!child.isCombatLance()) continue;
                if (!readiness.forceOperational(gs, child)) continue;
                // Must not already be tasked main_effort on this op.
                const task = lanceTask(op, child_id);
                if (task != null and task.? == .main_effort) continue;
                break :blk true;
            }
            break :blk false;
        },
        .air_cover => blk: {
            // Needs an operational, piloted fighter in the company's air wing.
            // Single owner: readiness.companyHasOperationalFighter (rule 20, P4g).
            break :blk readiness.companyHasOperationalFighter(gs, c.assigned_company);
        },
        .field_repair => blk: {
            // Needs an assigned, operational tech with the deployed company
            // (unit.tech slot filled by an available person). Rule 20: single owner.
            var uit = gs.units.iterator();
            while (uit.next()) |entry| {
                const u = entry.value_ptr;
                if (gs.companyOf(u.force) != c.assigned_company) continue;
                if (u.tech == .none) continue;
                const tech = gs.person(u.tech) orelse continue;
                if (tech.isAvailable(gs.clock.day_index)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Rule owner: aggregate intervention modifiers for the opening roll (P4g, rule 20).
/// Sums interventionProfile over op.interventions. Deterministic; no RNG.
pub fn operationInterventionMods(op: *const operation_mod.Operation) InterventionProfile {
    var mods: InterventionProfile = .{ .surprise_reduction = 0, .prepared_roll_bonus = 0 };
    for (op.interventions.items) |iv| {
        const p = interventionProfile(iv);
        mods.surprise_reduction += p.surprise_reduction;
        mods.prepared_roll_bonus += p.prepared_roll_bonus;
    }
    return mods;
}

/// Rule owner: markup-safe comma-joined intervention labels (P4g, rule 20).
/// Used by the AAR snapshot and queries; returns "" when none.
pub fn interventionSummary(alloc: std.mem.Allocator, op: *const operation_mod.Operation) ![]const u8 {
    if (op.interventions.items.len == 0) return "";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (op.interventions.items, 0..) |iv, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, iv.label());
    }
    return buf.toOwnedSlice(alloc);
}

/// Phase-7 sub-step: monthly command-capacity refresh on payday.
/// Iterates active arc contracts; tops up command_capacity up to commandCap.
/// Failure-atomic per contract: reserves the log slot before any mutation (rule 17).
pub fn refreshCommandCapacity(gs: *GameState) !void {
    var it = gs.contracts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr;
        if (c.status != .active or c.arc_key.len == 0) continue;
        const grant = commandGrant(gs, c);
        const cap = commandCap(gs, c);
        const new_cap = @min(cap, c.command_capacity +| grant);
        if (new_cap == c.command_capacity) continue; // nothing to log if unchanged
        // Reserve log and pre-format before any mutation (rule 17).
        try gs.reserveLog(1);
        var date_buf: [10]u8 = undefined;
        const log_text = try std.fmt.allocPrint(
            gs.allocator(),
            "{s} [arc] command capacity: {d}/{d}",
            .{ gs.clock.date.text(&date_buf), new_cap, cap },
        );
        // Infallible from here.
        c.command_capacity = new_cap;
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

test "selectArcKeyFor: garrison/security select the slice arc; raid kinds select none" {
    const testing = std.testing;
    // Garrison-class kinds that should select the fracturing_garrison arc.
    try testing.expectEqualStrings("fracturing_garrison", selectArcKeyFor(.garrison_duty).?);
    try testing.expectEqualStrings("fracturing_garrison", selectArcKeyFor(.security_duty).?);
    // Combat-heavy kinds that should select nothing.
    try testing.expectEqual(@as(?[]const u8, null), selectArcKeyFor(.objective_raid));
    try testing.expectEqual(@as(?[]const u8, null), selectArcKeyFor(.planetary_assault));
    try testing.expectEqual(@as(?[]const u8, null), selectArcKeyFor(.recon_raid));
}

test "operationEligible: gates on active status, non-empty arc_key, and matching arc" {
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const tmpl = operation_mod.findTemplate("negotiate_terms").?;

    // Gate 1: inactive contract is ineligible.
    var c_offer: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .offer,
        .arc_key = "fracturing_garrison",
    };
    try testing.expect(!operationEligible(&gs, &c_offer, tmpl));

    // Gate 2: active contract with empty arc_key is ineligible.
    var c_no_arc: contract_mod.Contract = .{
        .id = @enumFromInt(2),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .arc_key = "",
    };
    try testing.expect(!operationEligible(&gs, &c_no_arc, tmpl));

    // Gate 3: active contract with mismatched arc_key is ineligible.
    var c_wrong_arc: contract_mod.Contract = .{
        .id = @enumFromInt(3),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .arc_key = "some_other_arc",
    };
    try testing.expect(!operationEligible(&gs, &c_wrong_arc, tmpl));

    // Eligible: active + matching arc_key.
    var c_ok: contract_mod.Contract = .{
        .id = @enumFromInt(4),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
    };
    try testing.expect(operationEligible(&gs, &c_ok, tmpl));
}

test "outcomeBand: boundary table" {
    const testing = std.testing;
    try testing.expectEqual(operation_mod.OutcomeBand.failure, outcomeBand(-1));
    try testing.expectEqual(operation_mod.OutcomeBand.failure, outcomeBand(-100));
    try testing.expectEqual(operation_mod.OutcomeBand.setback, outcomeBand(0));
    try testing.expectEqual(operation_mod.OutcomeBand.setback, outcomeBand(4));
    try testing.expectEqual(operation_mod.OutcomeBand.partial, outcomeBand(5));
    try testing.expectEqual(operation_mod.OutcomeBand.partial, outcomeBand(9));
    try testing.expectEqual(operation_mod.OutcomeBand.success, outcomeBand(10));
    try testing.expectEqual(operation_mod.OutcomeBand.success, outcomeBand(14));
    try testing.expectEqual(operation_mod.OutcomeBand.decisive, outcomeBand(15));
    try testing.expectEqual(operation_mod.OutcomeBand.decisive, outcomeBand(100));
}

test "escalationStep and advanceClocks: clock accrues and beat advances at threshold" {
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const a = arc_mod.find("fracturing_garrison").?;
    const threshold = a.beats[0].escalation_threshold; // 30

    // Insert an active garrison contract with the slice arc.
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
        .arc_beat = 0,
        .escalation_clock = 0,
    });

    // Advance threshold-1 days: clock should be threshold-1, beat still 0.
    var day: u16 = 0;
    while (day < threshold - 1) : (day += 1) {
        try advanceClocks(&gs);
    }
    {
        const c = gs.contracts.getPtr(cid).?;
        try testing.expectEqual(@as(u16, threshold - 1), c.escalation_clock);
        try testing.expectEqual(@as(u8, 0), c.arc_beat);
    }

    // One more day: clock reaches threshold, beat advances to 1; clock resets
    // to 0 (excess = 0 here since clock was exactly threshold - 1).
    try advanceClocks(&gs);
    {
        const c = gs.contracts.getPtr(cid).?;
        try testing.expectEqual(@as(u16, 0), c.escalation_clock);
        try testing.expectEqual(@as(u8, 1), c.arc_beat);
    }

    // Beat 1 should last its own escalation_threshold days (20), not advance
    // immediately because the cumulative clock already exceeds it.
    const beat1_threshold = a.beats[1].escalation_threshold; // 20
    var day2: u16 = 0;
    while (day2 < beat1_threshold - 1) : (day2 += 1) {
        try advanceClocks(&gs);
    }
    {
        const c = gs.contracts.getPtr(cid).?;
        try testing.expectEqual(@as(u16, beat1_threshold - 1), c.escalation_clock);
        try testing.expectEqual(@as(u8, 1), c.arc_beat);
    }
    // One more day: beat advances to 2.
    try advanceClocks(&gs);
    {
        const c = gs.contracts.getPtr(cid).?;
        try testing.expectEqual(@as(u8, 2), c.arc_beat);
    }

    // A contract with no arc_key is untouched.
    const cid2: types.ContractId = @enumFromInt(2);
    try gs.contracts.put(gs.allocator(), cid2, .{
        .id = cid2,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 300_000 },
        .status = .active,
        .arc_key = "",
    });
    try advanceClocks(&gs);
    {
        const c2 = gs.contracts.getPtr(cid2).?;
        try testing.expectEqual(@as(u16, 0), c2.escalation_clock);
        try testing.expectEqual(@as(u8, 0), c2.arc_beat);
    }
}

test "instantiateOpening: consumer agreement with arc opening keys" {
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    // Build a local contract copy with the garrison arc.
    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .transit,
        .arc_key = "fracturing_garrison",
    };
    const before_oid = gs.next_operation_id;
    try instantiateOpening(&gs, &c, gs.next_operation_id);
    // instantiateOpening must not advance the counter — that is the commit
    // phase's responsibility (rules 7, 11-13).
    try testing.expectEqual(before_oid, gs.next_operation_id);
    try testing.expect(c.operations.items.len > 0);

    // Every instantiated template_key is in the arc's opening list.
    const a = arc_mod.find("fracturing_garrison").?;
    for (c.operations.items) |op| {
        var found = false;
        for (a.opening) |ok| {
            if (std.mem.eql(u8, ok, op.template_key)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    // A contract with no arc gets no operations.
    var c2: contract_mod.Contract = .{
        .id = @enumFromInt(2),
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 300_000 },
        .status = .transit,
        .arc_key = "",
    };
    try instantiateOpening(&gs, &c2, gs.next_operation_id);
    try testing.expectEqual(@as(usize, 0), c2.operations.items.len);
}

test "instantiateOpening: failure-atomic under injected OOM" {
    const testing = std.testing;
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = @import("state.zig").GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .transit,
        .arc_key = "fracturing_garrison",
    };
    const before_id = gs.next_operation_id;

    // Block all further arena allocations so ensureUnusedCapacity fails before
    // any ID is assigned (failure-atomic: no mutation on OOM).
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, instantiateOpening(&gs, &c, gs.next_operation_id));
    // next_operation_id unchanged — no IDs consumed before the OOM.
    try testing.expectEqual(before_id, gs.next_operation_id);
    // No operations appended to the local copy.
    try testing.expectEqual(@as(usize, 0), c.operations.items.len);
}

test "instantiateOpening: caller owns the id counter increment" {
    // The prepare phase calls instantiateOpening with gs.next_operation_id;
    // the counter must remain unchanged until the commit phase advances it.
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .transit,
        .arc_key = "fracturing_garrison",
    };
    const id_start = gs.next_operation_id;
    try instantiateOpening(&gs, &c, id_start);

    // Counter must not have advanced — that belongs to the commit phase.
    try testing.expectEqual(id_start, gs.next_operation_id);

    // Operations are assigned sequential IDs from id_start.
    const a = arc_mod.find("fracturing_garrison").?;
    try testing.expectEqual(a.opening.len, c.operations.items.len);
    for (c.operations.items, 0..) |op, i| {
        try testing.expectEqual(id_start + @as(u32, @intCast(i)), @intFromEnum(op.id));
    }

    // Simulated commit: the caller advances the counter.
    gs.next_operation_id += @as(u32, @intCast(c.operations.items.len));
    try testing.expectEqual(id_start + @as(u32, @intCast(a.opening.len)), gs.next_operation_id);
}

test "combatBand: maps engagement outcome to OutcomeBand" {
    const testing = std.testing;
    try testing.expectEqual(operation_mod.OutcomeBand.decisive, combatBand(.decisive_victory));
    try testing.expectEqual(operation_mod.OutcomeBand.success, combatBand(.victory));
    try testing.expectEqual(operation_mod.OutcomeBand.partial, combatBand(.draw));
    try testing.expectEqual(operation_mod.OutcomeBand.setback, combatBand(.defeat));
    try testing.expectEqual(operation_mod.OutcomeBand.failure, combatBand(.rout));
}

test "outcomeClockDelta: success/decisive relieve, failure/setback pressure, partial neutral" {
    const testing = std.testing;
    try testing.expect(outcomeClockDelta(.decisive) < 0);
    try testing.expect(outcomeClockDelta(.success) < 0);
    try testing.expectEqual(@as(i32, 0), outcomeClockDelta(.partial));
    try testing.expect(outcomeClockDelta(.setback) > 0);
    try testing.expect(outcomeClockDelta(.failure) > 0);
    try testing.expect(outcomeClockDelta(.failure) >= outcomeClockDelta(.setback));
}

test "declineClockDelta: pressure_increase note > 0, others > 0 too" {
    const testing = std.testing;
    const tmpl = operation_mod.findTemplate("negotiate_terms").?; // pressure_increase
    const delta = declineClockDelta(tmpl);
    try testing.expect(delta > 0);
    // repel_probe also has pressure_increase; same result.
    const repel = operation_mod.findTemplate("repel_probe").?;
    try testing.expect(declineClockDelta(repel) > 0);
}

test "selectFinale: below min_clock threshold returns held (min_clock==0); at threshold returns fell" {
    const testing = std.testing;
    const a = arc_mod.find("fracturing_garrison").?;
    // Identify the finales: one with min_clock 0 (held), one with min_clock 40 (fell).
    var held_key: []const u8 = "";
    var fell_key: []const u8 = "";
    var fell_min: u16 = 0;
    for (a.finales) |f| {
        if (f.min_clock == 0) held_key = f.key;
        if (f.min_clock > 0) {
            fell_key = f.key;
            fell_min = f.min_clock;
        }
    }
    try testing.expect(held_key.len > 0 and fell_key.len > 0);

    var c_low: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .arc_key = "fracturing_garrison",
        .escalation_clock = fell_min - 1, // below the threshold
    };
    const f_low = selectFinale(&c_low).?;
    try testing.expectEqualStrings(held_key, f_low.key);

    var c_high: contract_mod.Contract = .{
        .id = @enumFromInt(2),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .arc_key = "fracturing_garrison",
        .escalation_clock = fell_min, // exactly at the threshold
    };
    const f_high = selectFinale(&c_high).?;
    try testing.expectEqualStrings(fell_key, f_high.key);
}

test "legalIntents / mandatedIntent / intentLegal: legal set × CommandRights" {
    // Rule 20 owner test: legalIntents owns the set; intentLegal agrees with it.
    const testing = std.testing;

    // integrated: exactly one legal intent (the mandated one); all others illegal.
    const integrated_combat = legalIntents(true, .integrated);
    try testing.expectEqual(@as(usize, 1), integrated_combat.len);
    try testing.expectEqual(operation_mod.Intent.secure_objective, integrated_combat[0]);
    try testing.expectEqual(operation_mod.Intent.secure_objective, mandatedIntent(true));
    try testing.expectEqual(operation_mod.Intent.secure_objective, mandatedIntent(false));

    // non-integrated combat: all 6 intents legal.
    const ind_combat = legalIntents(true, .independent);
    try testing.expectEqual(@as(usize, 6), ind_combat.len);

    // non-integrated non-combat: 4 intents; preserve_force and break_enemy excluded.
    const ind_noncombat = legalIntents(false, .independent);
    try testing.expectEqual(@as(usize, 4), ind_noncombat.len);
    for (ind_noncombat) |li| {
        try testing.expect(li != .preserve_force and li != .break_enemy);
    }

    // intentLegal: returns true iff the intent is in the legal set.
    var c_ind: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000, .command_rights = .independent },
        .status = .active,
    };
    var c_integrated: contract_mod.Contract = c_ind;
    c_integrated.terms.command_rights = .integrated;

    const t_combat = operation_mod.findTemplate("repel_probe").?;
    const t_noncombat = operation_mod.findTemplate("negotiate_terms").?;

    // Independent + combat: all 6 legal.
    try testing.expect(intentLegal(&c_ind, t_combat, .preserve_force));
    try testing.expect(intentLegal(&c_ind, t_combat, .break_enemy));

    // Independent + non-combat: preserve_force and break_enemy not legal.
    try testing.expect(!intentLegal(&c_ind, t_noncombat, .preserve_force));
    try testing.expect(!intentLegal(&c_ind, t_noncombat, .break_enemy));
    try testing.expect(intentLegal(&c_ind, t_noncombat, .secure_objective));
    try testing.expect(intentLegal(&c_ind, t_noncombat, .recover));

    // Integrated: only secure_objective legal.
    try testing.expect(intentLegal(&c_integrated, t_combat, .secure_objective));
    try testing.expect(!intentLegal(&c_integrated, t_combat, .preserve_force));
    try testing.expect(!intentLegal(&c_integrated, t_combat, .break_enemy));
}

test "intentProfile: internal consistency — break_enemy ≥ preserve_force; preserve_force salvage gated" {
    // Rule 20 owner test: profile fields satisfy documented invariants (rule 67).
    const testing = std.testing;
    const pf = intentProfile(.preserve_force);
    const be = intentProfile(.break_enemy);
    const so = intentProfile(.secure_objective);

    // break_enemy must score more than preserve_force (rule 20 / design §6).
    try testing.expect(be.score_bp >= pf.score_bp);
    try testing.expect(be.vp_bp >= pf.vp_bp);

    // preserve_force: salvage not allowed (must withdraw from salvage).
    try testing.expect(!pf.salvage_allowed);

    // secure_objective: salvage allowed (baseline).
    try testing.expect(so.salvage_allowed);

    // break_enemy: salvage allowed (pressing the advantage).
    try testing.expect(be.salvage_allowed);

    // break_enemy adds fatigue; preserve_force does not.
    try testing.expect(be.fatigue_add > 0);
    try testing.expectEqual(@as(u8, 0), pf.fatigue_add);
}

test "operationSucceeded: preserve_force / break_enemy / secure_objective verdicts" {
    // Rule 20 owner test: verdict is intent-relative (rule 67).
    const testing = std.testing;

    // preserve_force: succeeds short of a rout (failure only = no).
    try testing.expect(!operationSucceeded(.preserve_force, .failure));
    try testing.expect(operationSucceeded(.preserve_force, .setback));
    try testing.expect(operationSucceeded(.preserve_force, .partial));
    try testing.expect(operationSucceeded(.preserve_force, .success));
    try testing.expect(operationSucceeded(.preserve_force, .decisive));

    // break_enemy: only on victory/decisive.
    try testing.expect(!operationSucceeded(.break_enemy, .failure));
    try testing.expect(!operationSucceeded(.break_enemy, .setback));
    try testing.expect(!operationSucceeded(.break_enemy, .partial));
    try testing.expect(operationSucceeded(.break_enemy, .success));
    try testing.expect(operationSucceeded(.break_enemy, .decisive));

    // secure_objective: success or decisive only.
    try testing.expect(!operationSucceeded(.secure_objective, .failure));
    try testing.expect(!operationSucceeded(.secure_objective, .partial));
    try testing.expect(operationSucceeded(.secure_objective, .success));
    try testing.expect(operationSucceeded(.secure_objective, .decisive));

    // .none always false.
    try testing.expect(!operationSucceeded(.preserve_force, .none));
    try testing.expect(!operationSucceeded(.secure_objective, .none));
}

test "nonCombatScore: intent term moves the score; preserve_force < secure_objective < protect_assets" {
    // Rule 20 owner test (rule 67): intent modifier is applied.
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const t = operation_mod.findTemplate("negotiate_terms").?;
    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
    };

    const score_pf = nonCombatScore(&gs, &c, t, .preserve_force);
    const score_so = nonCombatScore(&gs, &c, t, .secure_objective);
    const score_pa = nonCombatScore(&gs, &c, t, .protect_assets);

    // preserve_force < secure_objective (baseline) < protect_assets.
    try testing.expect(score_pf < score_so);
    try testing.expect(score_so < score_pa);
}

test "advanceClocks: failure-atomic under injected OOM at log reservation" {
    const testing = std.testing;
    const digest = @import("digest.zig");

    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = @import("state.zig").GameState.init(outer.allocator(), .{});
    defer gs.deinit();

    const a = arc_mod.find("fracturing_garrison").?;
    const threshold = a.beats[0].escalation_threshold;

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
        .arc_beat = 0,
        .escalation_clock = threshold - 1,
    });

    const before = digest.stateHash(&gs);

    // Block all further arena allocations so reserveLog(1) fails before any
    // clock or beat mutation (rule 17 failure-atomic, rule 69).
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, advanceClocks(&gs));
    // Digest unchanged: neither clock nor beat was mutated.
    try testing.expectEqual(before, digest.stateHash(&gs));
    {
        const c = gs.contracts.getPtr(cid).?;
        try testing.expectEqual(@as(u16, threshold - 1), c.escalation_clock);
        try testing.expectEqual(@as(u8, 0), c.arc_beat);
    }
}

test "legalTasks / taskLegal: non-combat → empty; combat independent → all 7; integrated → restricted" {
    const testing = std.testing;
    // Non-combat: empty regardless of rights.
    try testing.expectEqual(@as(usize, 0), legalTasks(false, .independent).len);
    try testing.expectEqual(@as(usize, 0), legalTasks(false, .integrated).len);
    // Combat + independent: all 7 tasks.
    const ind = legalTasks(true, .independent);
    try testing.expectEqual(@as(usize, 7), ind.len);
    // Combat + integrated: only main_effort, objective_security, recovery.
    const integ = legalTasks(true, .integrated);
    try testing.expectEqual(@as(usize, 3), integ.len);
    var has_main = false;
    var has_obj = false;
    var has_rec = false;
    for (integ) |t| {
        if (t == .main_effort) has_main = true;
        if (t == .objective_security) has_obj = true;
        if (t == .recovery) has_rec = true;
    }
    try testing.expect(has_main and has_obj and has_rec);
    // taskLegal agrees.
    try testing.expect(taskLegal(true, .independent, .screen));
    try testing.expect(taskLegal(true, .integrated, .main_effort));
    try testing.expect(!taskLegal(true, .integrated, .screen));
    try testing.expect(!taskLegal(false, .independent, .main_effort));
}

test "taskProfile: internal consistency invariants" {
    const testing = std.testing;
    const me = taskProfile(.main_effort);
    const es = taskProfile(.escort);
    const rv = taskProfile(.reserve);
    const rn = taskProfile(.recon);
    const sc = taskProfile(.screen);
    const os = taskProfile(.objective_security);
    const rc = taskProfile(.recovery);
    // main_effort has line_power_bp > 10_000.
    try testing.expect(me.line_power_bp > 10_000);
    // escort has lower line_power_bp and convoy_protect.
    try testing.expect(es.line_power_bp < 10_000);
    try testing.expect(es.convoy_protect);
    // reserve.reserve == true.
    try testing.expect(rv.reserve);
    // recon.surprise_reduction > screen.surprise_reduction.
    try testing.expect(rn.surprise_reduction > sc.surprise_reduction);
    // objective_security has op_success_bonus > 0.
    try testing.expect(os.op_success_bonus > 0);
    // recovery has recovery_bonus > 0.
    try testing.expect(rc.recovery_bonus > 0);
}

test "taskEligible: representative refusals and accept case" {
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
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
    const oid: types.OperationId = @enumFromInt(1);
    try c.operations.append(gs.allocator(), .{
        .id = oid,
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
    });

    // Build a company with a combat lance and pilot.
    const fid = (try @import("toe.zig").execNewCompany(&gs, "Alpha")).created_force;
    c.assigned_company = fid;
    const company = gs.force(fid).?;
    // Find a combat lance.
    var lance_id: types.ForceId = .none;
    for (company.children.items) |cid2| {
        if (gs.force(cid2)) |f| if (f.isCombatLance()) {
            lance_id = cid2;
            break;
        };
    }
    try testing.expect(lance_id != .none);
    const op = &c.operations.items[0];

    // Refusal: op not committed.
    try testing.expect(!taskEligible(&gs, c, op, lance_id, .main_effort));

    // Commit the op.
    op.state = .committed;
    op.committed_day = 0;

    // Refusal: non-combat op.
    var noncombat_op: operation_mod.Operation = .{
        .id = @enumFromInt(2),
        .template_key = "negotiate_terms",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 0,
    };
    try testing.expect(!taskEligible(&gs, c, &noncombat_op, lance_id, .main_effort));

    // Refusal: lance not a child of company (use a fake id).
    const fake_lance: types.ForceId = @enumFromInt(9999);
    try testing.expect(!taskEligible(&gs, c, op, fake_lance, .main_effort));

    // Accept: committed combat op, real lance.
    try testing.expect(taskEligible(&gs, c, op, lance_id, .main_effort));

    // Refusal: in-transit (return_eta_day set on the force).
    gs.force(fid).?.return_eta_day = 100;
    try testing.expect(!taskEligible(&gs, c, op, lance_id, .main_effort));
    gs.force(fid).?.return_eta_day = null;

    // Refusal: integrated rights + screen (restricted task set).
    c.terms.command_rights = .integrated;
    try testing.expect(!taskEligible(&gs, c, op, lance_id, .screen));
    // integrated + main_effort: legal.
    try testing.expect(taskEligible(&gs, c, op, lance_id, .main_effort));
    c.terms.command_rights = .independent;
}

test "taskSucceeded: representative verdicts" {
    const testing = std.testing;
    // main_effort / objective_security: need at least partial.
    try testing.expect(!taskSucceeded(.main_effort, .failure, false));
    try testing.expect(!taskSucceeded(.main_effort, .setback, false));
    try testing.expect(taskSucceeded(.main_effort, .partial, false));
    try testing.expect(taskSucceeded(.objective_security, .success, true));
    // reserve: need held_field.
    try testing.expect(taskSucceeded(.reserve, .failure, true));
    try testing.expect(!taskSucceeded(.reserve, .success, false));
    // escort / screen / recon: anything but failure.
    try testing.expect(!taskSucceeded(.escort, .failure, false));
    try testing.expect(taskSucceeded(.escort, .setback, false));
    try testing.expect(taskSucceeded(.screen, .partial, true));
    try testing.expect(taskSucceeded(.recon, .success, false));
    // recovery: needs a win.
    try testing.expect(!taskSucceeded(.recovery, .partial, true));
    try testing.expect(taskSucceeded(.recovery, .success, true));
    try testing.expect(taskSucceeded(.recovery, .decisive, false));
}

test "lanceTaskPower / operationTaskMods: tasked lance scales power; aggregate reflects assignments" {
    const testing = std.testing;
    var op: operation_mod.Operation = .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
    };
    const lid1: types.ForceId = @enumFromInt(1);
    const lid2: types.ForceId = @enumFromInt(2);

    // No task: power unchanged.
    try testing.expectEqual(@as(i64, 1000), lanceTaskPower(&op, lid1, 1000));

    // Assign main_effort to lid1: scales by 12000/10000 = ×1.2.
    try op.tasks.append(testing.allocator, .{ .lance = lid1, .task = .main_effort });
    defer op.tasks.deinit(testing.allocator);
    const p1 = lanceTaskPower(&op, lid1, 1000);
    try testing.expect(p1 > 1000); // main_effort line_power_bp = 12000 > 10000

    // Assign reserve to lid2.
    try op.tasks.append(testing.allocator, .{ .lance = lid2, .task = .reserve });

    // Aggregate: reserve_present, main_effort surprise_reduction=0.
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
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
    });
    const c = gs.contracts.getPtr(cid).?;
    const mods = operationTaskMods(&gs, c, &op);
    try testing.expect(mods.reserve_present);
    try testing.expectEqual(@as(i32, 0), mods.surprise_reduction); // main_effort has 0
}

test "tempoLegal: advance/delay always legal; recon/prepare combat-only" {
    const testing = std.testing;
    // advance and delay are always legal.
    try testing.expect(tempoLegal(true, .advance));
    try testing.expect(tempoLegal(false, .advance));
    try testing.expect(tempoLegal(true, .delay));
    try testing.expect(tempoLegal(false, .delay));
    // recon and prepare are combat-only.
    try testing.expect(tempoLegal(true, .recon));
    try testing.expect(!tempoLegal(false, .recon));
    try testing.expect(tempoLegal(true, .prepare));
    try testing.expect(!tempoLegal(false, .prepare));
    // legalTempo agrees.
    try testing.expectEqual(@as(usize, 4), legalTempo(true).len);
    try testing.expectEqual(@as(usize, 2), legalTempo(false).len);
}

test "tempoProfile: advance all-zero; recon surprise > 0; prepare bonus > 0; delay all-zero" {
    const testing = std.testing;
    const adv = tempoProfile(.advance);
    try testing.expectEqual(@as(i32, 0), adv.surprise_reduction);
    try testing.expectEqual(@as(i32, 0), adv.prepared_roll_bonus);
    const rec = tempoProfile(.recon);
    try testing.expect(rec.surprise_reduction > 0);
    try testing.expectEqual(@as(i32, 0), rec.prepared_roll_bonus);
    const prep = tempoProfile(.prepare);
    try testing.expectEqual(@as(i32, 0), prep.surprise_reduction);
    try testing.expect(prep.prepared_roll_bonus > 0);
    const del = tempoProfile(.delay);
    try testing.expectEqual(@as(i32, 0), del.surprise_reduction);
    try testing.expectEqual(@as(i32, 0), del.prepared_roll_bonus);
}

test "tempoClockDelta: advance 0; others > 0; delay >= recon/prepare" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 0), tempoClockDelta(.advance));
    try testing.expect(tempoClockDelta(.recon) > 0);
    try testing.expect(tempoClockDelta(.prepare) > 0);
    try testing.expect(tempoClockDelta(.delay) >= tempoClockDelta(.recon));
    try testing.expect(tempoClockDelta(.delay) >= tempoClockDelta(.prepare));
}

test "tempoDelayDays: advance == 0; others > 0" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 0), tempoDelayDays(.advance));
    try testing.expect(tempoDelayDays(.recon) > 0);
    try testing.expect(tempoDelayDays(.prepare) > 0);
    try testing.expect(tempoDelayDays(.delay) > 0);
}

test "commandGrant / commandCapacityHq: only the home HQ matters; comms moves grant" {
    // P4g rule owner: location-sensitive — only the supplying HQ contributes.
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    const hq_mod = @import("../domain/hq.zig");
    // Build two HQs: hq_a is the home for the company; hq_b is unrelated.
    const hq_a_id: types.HqId = @enumFromInt(1);
    const hq_b_id: types.HqId = @enumFromInt(2);
    try gs.hqs.put(gs.allocator(), hq_a_id, .{
        .id = hq_a_id,
        .name = "Seat",
        .tier = .field,
        .planet_key = "galatea",
    });
    try gs.hqs.put(gs.allocator(), hq_b_id, .{
        .id = hq_b_id,
        .name = "Other",
        .tier = .field,
        .planet_key = "galatea",
    });
    // Create a company assigned to hq_a.
    const co = (try @import("toe.zig").execNewCompany(&gs, "Alpha")).created_force;
    gs.force(co).?.supplying_hq = hq_a_id;

    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .arc_key = "fracturing_garrison",
        .assigned_company = co,
    };

    // commandCapacityHq must return hq_a.
    const hq_id = commandCapacityHq(&gs, &c);
    try testing.expectEqual(hq_a_id, hq_id);

    // Base grant ≥ 2.
    const base_grant = commandGrant(&gs, &c);
    try testing.expect(base_grant >= 2);

    // Give hq_b comms level 3 — must NOT change the grant (hq_a is the home HQ).
    const h_b = gs.hqs.getPtr(hq_b_id).?;
    try h_b.facilities.append(gs.allocator(), .{ .kind = hq_mod.FacilityKind.comms, .level = 3 });
    // Staff hq_b fully so its comms is effective — still must NOT affect hq_a's grant.
    h_b.staff_assigned = h_b.staffRequired().total();
    const grant_after_other_comms = commandGrant(&gs, &c);
    try testing.expectEqual(base_grant, grant_after_other_comms);

    // Give hq_a comms level 2 and enough staff so effective level ≥ 2 — grant must increase.
    const h_a = gs.hqs.getPtr(hq_a_id).?;
    try h_a.facilities.append(gs.allocator(), .{ .kind = hq_mod.FacilityKind.comms, .level = 2 });
    h_a.staff_assigned = h_a.staffRequired().total();
    const grant_with_comms = commandGrant(&gs, &c);
    try testing.expect(grant_with_comms > base_grant);
}

test "commandCap / refreshCommandCapacity: monthly refresh clamps to cap; non-arc contract untouched" {
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    // One arc contract.
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
        .command_capacity = 0,
    });

    // One non-arc contract — must be untouched.
    const cid2: types.ContractId = @enumFromInt(2);
    try gs.contracts.put(gs.allocator(), cid2, .{
        .id = cid2,
        .kind = .objective_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 300_000 },
        .status = .active,
        .arc_key = "",
        .command_capacity = 0,
    });

    try refreshCommandCapacity(&gs);
    {
        const c = gs.contracts.getPtr(cid).?;
        const grant = commandGrant(&gs, c);
        try testing.expect(c.command_capacity > 0);
        try testing.expect(c.command_capacity <= commandCap(&gs, c));
        // Refreshing again should not exceed the cap.
        c.command_capacity = commandCap(&gs, c); // set at cap
        const old = c.command_capacity;
        try refreshCommandCapacity(&gs);
        try testing.expectEqual(old, gs.contracts.getPtr(cid).?.command_capacity);
        _ = grant;
    }
    // Non-arc contract untouched.
    try testing.expectEqual(@as(u8, 0), gs.contracts.getPtr(cid2).?.command_capacity);
}

test "refreshCommandCapacity: failure-atomic under injected OOM at log reservation" {
    const testing = std.testing;
    var outer = std.heap.ArenaAllocator.init(testing.allocator);
    defer outer.deinit();
    var gs = @import("state.zig").GameState.init(outer.allocator(), .{});
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
        .command_capacity = 0,
    });

    const d = @import("digest.zig");
    const before = d.stateHash(&gs);

    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    try testing.expectError(error.OutOfMemory, refreshCommandCapacity(&gs));
    // Digest unchanged: no mutation occurred.
    try testing.expectEqual(before, d.stateHash(&gs));
}

test "employerReserved / commandCapacityAvailable: integrated withholds more than independent" {
    const testing = std.testing;
    try testing.expect(employerReserved(.integrated) > employerReserved(.independent));
    try testing.expect(employerReserved(.integrated) > 0);
    try testing.expectEqual(@as(u8, 0), employerReserved(.independent));

    // commandCapacityAvailable saturates at 0.
    var c: contract_mod.Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000, .command_rights = .integrated },
        .command_capacity = 1,
    };
    // With 1 capacity and integrated (reserves 2), available = 0.
    try testing.expectEqual(@as(u8, 0), commandCapacityAvailable(&c));
    c.terms.command_rights = .independent;
    try testing.expectEqual(@as(u8, 1), commandCapacityAvailable(&c));
}

test "interventionProfile / operationInterventionMods: aggregate mirrors sum" {
    const testing = std.testing;
    // Each profile has non-negative values.
    for ([_]operation_mod.Intervention{ .emergency_recon, .reinforce, .air_cover, .field_repair }) |iv| {
        const p = interventionProfile(iv);
        try testing.expect(p.surprise_reduction >= 0);
        try testing.expect(p.prepared_roll_bonus >= 0);
        try testing.expect(p.surprise_reduction > 0 or p.prepared_roll_bonus > 0);
    }
    // Aggregate over two interventions equals sum.
    var op: operation_mod.Operation = .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
    };
    try op.interventions.append(testing.allocator, .emergency_recon);
    defer op.interventions.deinit(testing.allocator);
    try op.interventions.append(testing.allocator, .reinforce);

    const mods = operationInterventionMods(&op);
    const p1 = interventionProfile(.emergency_recon);
    const p2 = interventionProfile(.reinforce);
    try testing.expectEqual(p1.surprise_reduction + p2.surprise_reduction, mods.surprise_reduction);
    try testing.expectEqual(p1.prepared_roll_bonus + p2.prepared_roll_bonus, mods.prepared_roll_bonus);
}

test "interventionGate: each of the four gates accept and refuse correctly" {
    const testing = std.testing;
    var gs = @import("state.zig").GameState.init(testing.allocator, .{});
    defer gs.deinit();

    // Build a minimal company by hand (no units, no lances) so all gates start refused.
    const co = try gs.createForce("Alpha", .company, .none);
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
        .assigned_company = co,
    });

    // Build a committed combat operation.
    var op: operation_mod.Operation = .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
    };
    const c = gs.contracts.getPtr(cid).?;

    // Non-committed op → all gates refuse.
    op.state = .available;
    try testing.expect(!interventionGate(&gs, c, &op, .emergency_recon));
    try testing.expect(!interventionGate(&gs, c, &op, .reinforce));
    try testing.expect(!interventionGate(&gs, c, &op, .air_cover));
    try testing.expect(!interventionGate(&gs, c, &op, .field_repair));
    op.state = .committed;

    // Both emergency_recon and reinforce refuse on a completely empty company.
    try testing.expect(!interventionGate(&gs, c, &op, .emergency_recon));
    try testing.expect(!interventionGate(&gs, c, &op, .reinforce));

    // Add a scouting lance with an operational unit.
    // emergency_recon passes; reinforce also passes (recon_lance is operational, not main_effort).
    const recon_lance = try gs.createForce("Recon", .lance, co);
    gs.force(recon_lance).?.role = .scouting;
    const uid_r = try gs.addUnit("LCT-1V");
    const pid_r = try gs.hirePerson("Rn", "Rd", .mekwarrior);
    try @import("toe.zig").assignUnit(&gs, uid_r, recon_lance, pid_r);
    try testing.expect(interventionGate(&gs, c, &op, .emergency_recon));
    try testing.expect(interventionGate(&gs, c, &op, .reinforce));

    // Task the only operational lance as main_effort → reinforce refused.
    try op.tasks.append(testing.allocator, .{ .lance = recon_lance, .task = .main_effort });
    defer op.tasks.deinit(testing.allocator);
    try testing.expect(!interventionGate(&gs, c, &op, .reinforce));
    // Clear the task so the rest of the test works with a free lance.
    op.tasks.clearRetainingCapacity();

    // air_cover: refuses without a fighter.
    try testing.expect(!interventionGate(&gs, c, &op, .air_cover));
    // Stand up an air wing with an operational, piloted fighter.
    const wing = try gs.createForce("Air Wing", .air_company, co);
    const air_lance = try gs.createForce("Sky Lance", .air_lance, wing);
    const uid_f = try gs.addUnit("SPR-H5");
    const pid_f = try gs.hirePerson("Av", "Avi", .aero_pilot);
    try @import("toe.zig").assignUnit(&gs, uid_f, air_lance, pid_f);
    try testing.expect(interventionGate(&gs, c, &op, .air_cover));

    // field_repair: refuses with no tech assigned.
    try testing.expect(!interventionGate(&gs, c, &op, .field_repair));

    // Regression (F2): a support company containing only an operational vehicle
    // (no tech assigned to any unit) must NOT satisfy the field_repair gate.
    // Before the fix, Loop 1 returned true for any operational non-mek unit in
    // a support lance; after the fix only the tech-assignment check (Loop 2) runs.
    const sup_co = try gs.createForce("Omega", .support_company, co);
    const sup_lance = try gs.createForce("Repair Lance", .support_lance, sup_co);
    const uid_veh = try gs.addUnit("SVT-1");
    const pid_veh = try gs.hirePerson("Drv", "One", .vehicle_crew);
    try @import("toe.zig").assignUnit(&gs, uid_veh, sup_lance, pid_veh);
    // The vehicle is operational but has no tech assigned; gate must still refuse.
    try testing.expect(!interventionGate(&gs, c, &op, .field_repair));

    // Assign a tech to a unit already in the company (the recon unit).
    const tech_pid = try gs.hirePerson("Tech", "Smith", .tech_mek);
    gs.unit(uid_r).?.tech = tech_pid;
    try testing.expect(interventionGate(&gs, c, &op, .field_repair));
}
