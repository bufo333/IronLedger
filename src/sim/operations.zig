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

/// Quote returned by `operationQuote` for a single operation template.
pub const Quote = struct {
    /// Expected days to resolution (tuning data, not a guarantee). // TUNE
    expected_days: u16,
};

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
pub fn operationQuote(gs: *const GameState, c: *const contract_mod.Contract, t: *const operation_mod.OperationTemplate) Quote {
    _ = gs;
    _ = c;
    return .{ .expected_days = t.expected_days };
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
/// Inputs: base + command_rights term + employer_standing term (all // TUNE).
/// Pure; no RNG (design §6 P4c: non-combat is deterministic).
pub fn nonCombatScore(gs: *GameState, c: *const contract_mod.Contract, t: *const operation_mod.OperationTemplate) i32 {
    _ = t;
    const base: i32 = 8; // TUNE: default non-combat outcome
    const rights_bonus: i32 = @divTrunc(c.terms.command_rights.gapDelta() * -1, 2); // TUNE: independent rights help negotiation
    const standing_bonus: i32 = @divTrunc(gs.standing(c.employer_key), 20); // TUNE: standing/20 bonus
    return base + rights_bonus + standing_bonus;
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
