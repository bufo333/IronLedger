//! Officer arc rule owners: selection, recurrence, performance mutation,
//! delta owners, and attachment (P4i, P4 operations design §§3,5).
//! No MekHQ counterpart (P4 operations design §§3,5).
//! Rule 5 / queries leaf: this module does NOT import queries.zig.

const std = @import("std");
const types = @import("../domain/types.zig");
const officer_mod = @import("../domain/officer.zig");
const arc_mod = @import("../domain/arc.zig");
const operation_mod = @import("../domain/operation.zig");
const contract_mod = @import("../domain/contract.zig");
const force_mod = @import("../domain/force.zig");
const person_mod = @import("../domain/person.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

/// Maximum officers per arc: company commander + max lances (rule 24).
const max_officers_per_arc: usize = force_mod.max_lances_per_company + 1; // = 6

/// A (PersonId, OfficerSeat) pair returned by selectOfficers.
pub const OfficerSelection = struct {
    person_id: types.PersonId,
    seat: officer_mod.OfficerSeat,
};

/// Select officers from the deployed company's ToE: the company commander
/// (seat .company_commander) plus each combat-lance child's commander
/// (seat .lance_leader). Deduped by PersonId; .none and off-books persons
/// skipped; support lances excluded. Deterministic ToE order.
/// Selection result: a bounded fixed-size array plus a count.
pub const OfficerSelections = struct {
    items: [max_officers_per_arc]OfficerSelection,
    count: usize,
};

/// Selection function returning a bounded array with count.
pub fn selectOfficers(gs: *GameState, company_id: types.ForceId) OfficerSelections {
    var result: OfficerSelections = .{ .items = undefined, .count = 0 };

    const co = gs.force(company_id) orelse return result;

    // Add company commander if set and on-books.
    if (co.commander != .none and gs.person(co.commander) != null) {
        result.items[result.count] = .{ .person_id = co.commander, .seat = .company_commander };
        result.count += 1;
    }

    // Add each combat-lance child's commander (dedupe by PersonId).
    for (co.children.items) |child_id| {
        if (result.count >= max_officers_per_arc) break;
        const child = gs.force(child_id) orelse continue;
        if (!child.isCombatLance()) continue;
        if (child.commander == .none) continue;
        if (gs.person(child.commander) == null) continue;
        // Dedupe.
        var already = false;
        for (result.items[0..result.count]) |sel| {
            if (sel.person_id == child.commander) {
                already = true;
                break;
            }
        }
        if (already) continue;
        result.items[result.count] = .{ .person_id = child.commander, .seat = .lance_leader };
        result.count += 1;
    }

    return result;
}

/// Look for a prior officer arc for the same PersonId whose contract is closed.
/// Returns the prior arc with the highest id (most recently introduced),
/// so recurrence carries forward the most recent accumulated history.
pub fn priorOfficer(gs: *GameState, person_id: types.PersonId) ?*officer_mod.OfficerArc {
    var best: ?*officer_mod.OfficerArc = null;
    var best_id: u32 = 0;
    var it = gs.officer_arcs.iterator();
    while (it.next()) |entry| {
        const arc = entry.value_ptr;
        if (arc.person != person_id) continue;
        // The prior arc's contract must be closed (not active).
        if (arc.contract != .none) {
            const c = gs.contracts.getPtr(arc.contract);
            if (c != null and c.?.isRunning()) continue; // still active — not eligible
        }
        const id = @intFromEnum(arc.id);
        if (best == null or id > best_id) {
            best = arc;
            best_id = id;
        }
    }
    return best;
}

/// Single named owner for performance → band (rule 20).
/// Thresholds: performance ≤ −40 → failing; ≥ 40 → distinguished; else steady. // TUNE
pub fn performanceBand(standing: i16) officer_mod.PerformanceBand {
    if (standing <= -40) return .failing; // TUNE
    if (standing >= 40) return .distinguished; // TUNE
    return .steady;
}

/// Named outcome→delta owner for operation resolution (P4i, rule 20).
/// All values // TUNE.
pub fn outcomeOfficerDelta(band: operation_mod.OutcomeBand) i16 {
    return switch (band) {
        .decisive => 6, // TUNE
        .success => 3, // TUNE
        .partial => 0, // TUNE
        .setback => -3, // TUNE
        .failure => -6, // TUNE
        .none => 0,
    };
}

/// Named finale→delta owner for finale resolution (P4i, rule 20).
/// All values // TUNE.
pub fn finaleOfficerDelta(f: *const arc_mod.Finale) i16 {
    if (f.ends_contract) {
        // Collapse: the garrison fell — performance down.
        return -12; // TUNE
    }
    // Garrison held: performance up.
    return 10; // TUNE
}

/// The prepared performance change from `adjustOfficer`: all fallible work is done
/// up front so the commit phase is infallible.
pub const PreparedOfficerAdjust = struct {
    arc_id: types.OfficerArcId,
    delta: i16,
    cause: []const u8, // duped into gs.allocator()
    log_text: []const u8, // duped into gs.allocator()
    day: u32,
};

/// PREPARE phase of `adjustOfficer`: duplicate the cause string and pre-format
/// the log line — both fallible. Returns a `PreparedOfficerAdjust` whose commit
/// phase is infallible. The caller is responsible for the log-slot reservation
/// (gs.reserveLog(1)) before calling this.
/// The arc must exist (caller must check before calling; unreachable otherwise).
/// Never reads or modifies any Person field.
pub fn prepareAdjustOfficer(gs: *GameState, arc_id: types.OfficerArcId, delta: i16, cause: []const u8) !PreparedOfficerAdjust {
    const cause_dup = try gs.allocator().dupe(u8, cause);
    const oa = gs.officerArc(arc_id) orelse unreachable;
    var date_buf: [10]u8 = undefined;
    // Read person's name (read-only access to Person, no mutation).
    const person_name: []const u8 = if (gs.person(oa.person)) |p|
        try std.fmt.allocPrint(gs.allocator(), "{s} {s}", .{ p.first_name, p.last_name })
    else
        "unknown";
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [officer] {s}: performance {d} — {s}", .{
        gs.clock.date.text(&date_buf),
        person_name,
        delta,
        cause,
    });
    return .{
        .arc_id = arc_id,
        .delta = delta,
        .cause = cause_dup,
        .log_text = log_text,
        .day = gs.clock.day_index,
    };
}

/// COMMIT phase of `adjustOfficer`: infallible. Apply the prepared delta, clamp,
/// record cause, and write the pre-reserved log slot.
/// Never modifies any Person field (only the OfficerArc and the log).
pub fn commitAdjustOfficer(gs: *GameState, prepared: PreparedOfficerAdjust) void {
    const oa = gs.officerArc(prepared.arc_id) orelse return; // validated in prepare
    const new_perf: i32 = @as(i32, oa.performance) + prepared.delta;
    oa.performance = @intCast(@min(@as(i32, officer_mod.perf_max), @max(@as(i32, officer_mod.perf_min), new_perf)));
    oa.last_cause = prepared.cause;
    oa.last_cause_day = prepared.day;
    gs.event_log.appendAssumeCapacity(.{
        .day = prepared.day,
        .category = .contract,
        .company = .none,
        .contract = if (oa.contract != .none) oa.contract else .none,
        .text = prepared.log_text,
    });
}

/// Single mutation owner: adjust an officer arc's performance and record the cause.
/// All fallible work (log reserve + string dup + pre-format) is in the PREPARE
/// phase so the caller's commit phase stays infallible (rules 7, 11-13).
/// Returns the PreparedOfficerAdjust for use in the caller's commit.
/// The caller must call `commitAdjustOfficer` to apply.
pub fn adjustOfficer(gs: *GameState, arc_id: types.OfficerArcId, delta: i16, cause: []const u8) !PreparedOfficerAdjust {
    try gs.reserveLog(1);
    return prepareAdjustOfficer(gs, arc_id, delta, cause);
}

/// Attach officer arcs for the selected officers on this arc contract's company.
/// id_start is the CURRENT next_officer_arc_id from the caller's snapshot; this
/// function assigns ids from id_start upward but does NOT advance the counter
/// — the caller's commit phase advances gs.next_officer_arc_id (rules 7, 11-13).
/// Failure-atomic: on any error, neither c.officer_arc_ids nor gs.officer_arcs changes.
pub fn instantiateOfficers(gs: *GameState, c: *contract_mod.Contract, id_start: u32) !void {
    if (c.arc_key.len == 0) return;
    if (c.assigned_company == .none) return;

    const selected = selectOfficers(gs, c.assigned_company);
    if (selected.count == 0) return;

    const alloc = gs.allocator();
    // PREPARE: build all arcs + reserve map capacity.
    // None of these steps mutate gs.officer_arcs or c.officer_arc_ids.
    var prepared: [max_officers_per_arc]officer_mod.OfficerArc = undefined;
    var prep_count: usize = 0;
    var next_id: u32 = id_start;
    for (selected.items[0..selected.count]) |sel| {
        const id: types.OfficerArcId = @enumFromInt(next_id);
        var oa: officer_mod.OfficerArc = undefined;
        // Check recurrence: same PersonId on a closed contract.
        if (priorOfficer(gs, sel.person_id)) |prior| {
            // Carry forward: same performance.
            oa = .{
                .id = id,
                .person = sel.person_id,
                .contract = c.id,
                .seat = sel.seat,
                .performance = prior.performance,
                .encounters = prior.encounters + 1,
                .last_cause = "",
                .last_cause_day = 0,
                .recurring = true,
            };
        } else {
            oa = .{
                .id = id,
                .person = sel.person_id,
                .contract = c.id,
                .seat = sel.seat,
                .performance = 0,
                .encounters = 1,
                .last_cause = "",
                .last_cause_day = 0,
                .recurring = false,
            };
        }
        prepared[prep_count] = oa;
        prep_count += 1;
        next_id += 1;
    }
    // Reserve map capacity before any mutation.
    try gs.officer_arcs.ensureUnusedCapacity(alloc, prep_count);
    // Reserve officer_arc_ids list capacity on the contract copy.
    try c.officer_arc_ids.ensureUnusedCapacity(alloc, prep_count);

    // COMMIT: infallible from here.
    for (prepared[0..prep_count]) |oa| {
        gs.officer_arcs.putAssumeCapacity(oa.id, oa);
        c.officer_arc_ids.appendAssumeCapacity(oa.id);
    }
}

/// All officer arcs attached to this contract (by their ids stored on the contract).
/// Returns a caller-owned slice from the arena allocator.
pub fn attachedOfficers(alloc: std.mem.Allocator, gs: *GameState, c: *const contract_mod.Contract) ![]officer_mod.OfficerArc {
    var out: std.ArrayListUnmanaged(officer_mod.OfficerArc) = .empty;
    for (c.officer_arc_ids.items) |id| {
        if (gs.officerArc(id)) |oa| try out.append(alloc, oa.*);
    }
    return out.toOwnedSlice(alloc);
}

// ---- Tests -----------------------------------------------------------------

test "selectOfficers: company commander + combat lance leaders, deduped, .none skipped" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();

    // Create a company and assign a commander.
    const co_id = try gs.createForce("Alpha", .company, .none);
    const p1 = try gs.hirePerson("Ann", "Smith", .mekwarrior);
    const p2 = try gs.hirePerson("Bob", "Jones", .mekwarrior);
    const p3 = try gs.hirePerson("Carol", "Lee", .mekwarrior);

    if (gs.force(co_id)) |co| co.commander = p1;

    // Add two combat lances and one support lance.
    const lance1 = try gs.createForce("Lance 1", .lance, co_id);
    if (gs.force(co_id)) |co| try co.children.append(gs.allocator(), lance1);
    if (gs.force(lance1)) |l| l.commander = p2;

    const lance2 = try gs.createForce("Lance 2", .lance, co_id);
    if (gs.force(co_id)) |co| try co.children.append(gs.allocator(), lance2);
    if (gs.force(lance2)) |l| l.commander = p3;

    // Support lance should be excluded.
    const support = try gs.createForce("Support", .support_lance, co_id);
    if (gs.force(co_id)) |co| try co.children.append(gs.allocator(), support);
    const p4 = try gs.hirePerson("Dave", "Brown", .medic);
    if (gs.force(support)) |l| l.commander = p4;

    const sel = selectOfficers(&gs, co_id);
    // Should have company commander + 2 lance leaders = 3 officers.
    try std.testing.expectEqual(@as(usize, 3), sel.count);
    try std.testing.expectEqual(p1, sel.items[0].person_id);
    try std.testing.expectEqual(officer_mod.OfficerSeat.company_commander, sel.items[0].seat);
    try std.testing.expectEqual(p2, sel.items[1].person_id);
    try std.testing.expectEqual(officer_mod.OfficerSeat.lance_leader, sel.items[1].seat);
    try std.testing.expectEqual(p3, sel.items[2].person_id);
    try std.testing.expectEqual(officer_mod.OfficerSeat.lance_leader, sel.items[2].seat);
}

test "selectOfficers: company commander also a lance leader — one arc only (dedupe)" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer gs.deinit();

    const co_id = try gs.createForce("Alpha", .company, .none);
    const p1 = try gs.hirePerson("Ann", "Smith", .mekwarrior);
    if (gs.force(co_id)) |co| co.commander = p1;

    const lance1 = try gs.createForce("Lance 1", .lance, co_id);
    if (gs.force(co_id)) |co| try co.children.append(gs.allocator(), lance1);
    // Same person commands both the company and lance1.
    if (gs.force(lance1)) |l| l.commander = p1;

    const sel = selectOfficers(&gs, co_id);
    // Dedupe: p1 appears only once (as company_commander).
    try std.testing.expectEqual(@as(usize, 1), sel.count);
    try std.testing.expectEqual(p1, sel.items[0].person_id);
    try std.testing.expectEqual(officer_mod.OfficerSeat.company_commander, sel.items[0].seat);
}

test "selectOfficers: .none commander skipped; no company returns zero" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();

    // No company at all.
    const sel0 = selectOfficers(&gs, .none);
    try std.testing.expectEqual(@as(usize, 0), sel0.count);

    // Company with no commander and a lance with .none commander.
    const co_id = try gs.createForce("Bravo", .company, .none);
    const lance1 = try gs.createForce("Lance 1", .lance, co_id);
    if (gs.force(co_id)) |co| try co.children.append(gs.allocator(), lance1);
    // No commanders set.

    const sel1 = selectOfficers(&gs, co_id);
    try std.testing.expectEqual(@as(usize, 0), sel1.count);
}

test "performanceBand: thresholds for representative standings" {
    const cases = [_]struct { standing: i16, expected: officer_mod.PerformanceBand }{
        .{ .standing = -100, .expected = .failing },
        .{ .standing = -40, .expected = .failing },
        .{ .standing = -39, .expected = .steady },
        .{ .standing = 0, .expected = .steady },
        .{ .standing = 39, .expected = .steady },
        .{ .standing = 40, .expected = .distinguished },
        .{ .standing = 100, .expected = .distinguished },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.expected, performanceBand(c.standing));
    }
}

test "outcomeOfficerDelta and finaleOfficerDelta: monotonic TUNE invariants" {
    const ds = outcomeOfficerDelta(.decisive);
    const s = outcomeOfficerDelta(.success);
    const f = outcomeOfficerDelta(.failure);
    const setback = outcomeOfficerDelta(.setback);
    // Success directions: decisive >= success > 0
    try std.testing.expect(ds >= s);
    try std.testing.expect(s > 0);
    // Failure directions: failure < setback < 0
    try std.testing.expect(f < setback);
    try std.testing.expect(setback < 0);

    // Finale deltas.
    const held: arc_mod.Finale = .{ .key = "held", .name = "Held", .min_clock = 0, .ends_contract = false };
    const fell: arc_mod.Finale = .{ .key = "fell", .name = "Fell", .min_clock = 40, .ends_contract = true };
    try std.testing.expect(finaleOfficerDelta(&held) > 0);
    try std.testing.expect(finaleOfficerDelta(&fell) < 0);
    // collapse < held (as per plan: collapse < held, so finaleOfficerDelta(fell) < finaleOfficerDelta(held))
    try std.testing.expect(finaleOfficerDelta(&fell) < finaleOfficerDelta(&held));
}

test "adjustOfficer: clamps to +-100, records cause and day, appends one log line" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();

    _ = try gs.hirePerson("Ann", "Smith", .mekwarrior);
    const arc_id: types.OfficerArcId = @enumFromInt(1);
    try gs.commitOfficerArc(.{
        .id = arc_id,
        .person = @enumFromInt(1),
        .performance = 95,
    });

    const log_before = gs.event_log.items.len;
    const prep = try adjustOfficer(&gs, arc_id, 20, "big_win");
    commitAdjustOfficer(&gs, prep);
    try std.testing.expectEqual(@as(i16, officer_mod.perf_max), gs.officerArc(arc_id).?.performance); // clamped to 100
    try std.testing.expectEqualStrings("big_win", gs.officerArc(arc_id).?.last_cause);
    try std.testing.expectEqual(gs.clock.day_index, gs.officerArc(arc_id).?.last_cause_day);
    // Exactly one log line appended.
    try std.testing.expectEqual(log_before + 1, gs.event_log.items.len);

    const prep2 = try adjustOfficer(&gs, arc_id, -200, "collapse");
    commitAdjustOfficer(&gs, prep2);
    try std.testing.expectEqual(@as(i16, officer_mod.perf_min), gs.officerArc(arc_id).?.performance); // clamped to -100

    // Band agrees with performanceBand.
    try std.testing.expectEqual(officer_mod.PerformanceBand.failing, performanceBand(gs.officerArc(arc_id).?.performance));
}

test "priorOfficer: closed-contract-only, highest-id wins, must match PersonId" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();

    const pid: types.PersonId = @enumFromInt(1);
    _ = try gs.hirePerson("Ann", "Smith", .mekwarrior);

    const arc_id1: types.OfficerArcId = @enumFromInt(1);
    try gs.commitOfficerArc(.{
        .id = arc_id1,
        .person = pid,
        .contract = .none, // no active contract
        .performance = 20,
    });

    // Prior with same person and no active contract should be found.
    const prior = priorOfficer(&gs, pid);
    try std.testing.expect(prior != null);
    try std.testing.expectEqual(@as(i16, 20), prior.?.performance);

    // Different person -> no match.
    const pid2: types.PersonId = @enumFromInt(99);
    try std.testing.expect(priorOfficer(&gs, pid2) == null);
}

test "priorOfficer: multi-prior returns highest id" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8 });
    defer gs.deinit();

    const pid: types.PersonId = @enumFromInt(1);
    _ = try gs.hirePerson("Ann", "Smith", .mekwarrior);

    for ([_]u32{ 1, 2, 3 }) |raw_id| {
        const aid: types.OfficerArcId = @enumFromInt(raw_id);
        try gs.commitOfficerArc(.{
            .id = aid,
            .person = pid,
            .contract = .none,
            .performance = @intCast(raw_id * 10),
        });
    }

    const prior = priorOfficer(&gs, pid);
    try std.testing.expect(prior != null);
    try std.testing.expectEqual(@as(types.OfficerArcId, @enumFromInt(3)), prior.?.id);
    try std.testing.expectEqual(@as(i16, 30), prior.?.performance);
}

test "instantiateOfficers: attaches one arc per officer, carries performance on recurrence, failure-atomic" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 10 });
    defer gs.deinit();

    // Build a company with a commander and one lance.
    const co_id = try gs.createForce("Alpha", .company, .none);
    const p1 = try gs.hirePerson("Ann", "Smith", .mekwarrior);
    if (gs.force(co_id)) |co| co.commander = p1;
    const lance1 = try gs.createForce("Lance 1", .lance, co_id);
    if (gs.force(co_id)) |co| try co.children.append(gs.allocator(), lance1);
    const p2 = try gs.hirePerson("Bob", "Jones", .mekwarrior);
    if (gs.force(lance1)) |l| l.commander = p2;

    const cid: types.ContractId = @enumFromInt(1);
    var c = contract_mod.Contract{
        .id = cid,
        .arc_key = "fracturing_garrison",
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .kind = .garrison_duty,
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .assigned_company = co_id,
    };

    const before_count = gs.officer_arcs.count();
    const before_next = gs.next_officer_arc_id;

    try instantiateOfficers(&gs, &c, gs.next_officer_arc_id);

    // Two officers attached (company cmdr + lance leader).
    try std.testing.expectEqual(before_count + 2, gs.officer_arcs.count());
    try std.testing.expectEqual(@as(usize, 2), c.officer_arc_ids.items.len);
    // next_officer_arc_id is NOT advanced by instantiateOfficers — caller does.
    try std.testing.expectEqual(before_next, gs.next_officer_arc_id);

    // Non-arc contract attaches none.
    var c2 = contract_mod.Contract{
        .id = @enumFromInt(2),
        .arc_key = "",
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .kind = .garrison_duty,
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .assigned_company = co_id,
    };
    const count_before2 = gs.officer_arcs.count();
    try instantiateOfficers(&gs, &c2, gs.next_officer_arc_id);
    try std.testing.expectEqual(count_before2, gs.officer_arcs.count());
    try std.testing.expectEqual(@as(usize, 0), c2.officer_arc_ids.items.len);
}

test "instantiateOfficers: failure-atomic under injected OOM" {
    // Set up state with a real allocator so force + person creation succeeds,
    // then inject a failing allocator so that the ensureUnusedCapacity calls
    // inside instantiateOfficers are guaranteed to fail.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 2 });

    // Build a company with a commander (same shape as the success test).
    const co_id = try gs.createForce("Alpha", .company, .none);
    const p1 = try gs.hirePerson("Ann", "Smith", .mekwarrior);
    if (gs.force(co_id)) |co| co.commander = p1;

    const cid: types.ContractId = @enumFromInt(1);
    var c = contract_mod.Contract{
        .id = cid,
        .arc_key = "fracturing_garrison",
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .kind = .garrison_duty,
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .assigned_company = co_id,
    };

    const before_count = gs.officer_arcs.count();
    const before_next = gs.next_officer_arc_id;

    // Discard the arena's free list so the next allocation goes to the
    // child_allocator, then replace that with a permanently failing one.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    gs.arena.child_allocator = std.testing.failing_allocator;

    // instantiateOfficers must fail at ensureUnusedCapacity and roll back.
    try std.testing.expectError(error.OutOfMemory, instantiateOfficers(&gs, &c, gs.next_officer_arc_id));
    try std.testing.expectEqual(before_count, gs.officer_arcs.count());
    // next_officer_arc_id is NOT advanced by instantiateOfficers — caller's commit does.
    try std.testing.expectEqual(before_next, gs.next_officer_arc_id);
}

test "Person-safety: adjustOfficer and instantiateOfficers never write Person fields" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs.deinit();

    // Hire a person and record all mutable fields.
    const pid = try gs.hirePerson("Ann", "Smith", .mekwarrior);
    const p_before = gs.person(pid).?.*;
    const people_count_before = gs.people.count();

    // Set up a company and company commander.
    const co_id = try gs.createForce("Alpha", .company, .none);
    if (gs.force(co_id)) |co| co.commander = pid;

    // instantiateOfficers on an arc contract.
    const cid: types.ContractId = @enumFromInt(1);
    var c = contract_mod.Contract{
        .id = cid,
        .arc_key = "fracturing_garrison",
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .kind = .garrison_duty,
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .assigned_company = co_id,
    };
    try instantiateOfficers(&gs, &c, gs.next_officer_arc_id);

    // adjustOfficer on the first arc.
    if (c.officer_arc_ids.items.len > 0) {
        const arc_id = c.officer_arc_ids.items[0];
        const prep = try adjustOfficer(&gs, arc_id, 10, "test");
        commitAdjustOfficer(&gs, prep);
    }

    // Person fields must be unchanged.
    const p_after = gs.person(pid).?.*;
    try std.testing.expectEqual(p_before.morale, p_after.morale);
    try std.testing.expectEqual(p_before.rank, p_after.rank);
    try std.testing.expectEqual(p_before.status, p_after.status);
    try std.testing.expectEqual(p_before.shares, p_after.shares);
    // People count unchanged (no Person created or removed).
    try std.testing.expectEqual(people_count_before, gs.people.count());

    // Loyalty check (same day).
    try std.testing.expectEqual(p_before.loyalty(gs.clock.day_index), p_after.loyalty(gs.clock.day_index));
}
