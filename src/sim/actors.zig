//! Actor rule owners: generation, recurrence, relationship mutation, delta
//! owners, attachment, and conversion boundary (P4i, P4 operations design §§3,5).
//! No MekHQ counterpart (P4 operations design §§3,5).
//! Rule 5 / queries leaf: this module does NOT import queries.zig.

const std = @import("std");
const types = @import("../domain/types.zig");
const actor_mod = @import("../domain/actor.zig");
const arc_mod = @import("../domain/arc.zig");
const operation_mod = @import("../domain/operation.zig");
const contract_mod = @import("../domain/contract.zig");
const rng_mod = @import("rng.zig");
const person_gen = @import("../gen/person_gen.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

/// A delta to one relationship dimension from a named cause.
pub const RelDelta = struct {
    trust: i16 = 0,
    debt: i16 = 0,
    respect: i16 = 0,
    hostility: i16 = 0,
};

/// Generate actor names using the `.actors` RNG stream (rule 57).
/// Deterministic per seed; drawing does not perturb `.battle` or `.generation`.
pub fn generateActor(gs: *GameState, archetype_key: []const u8, faction_key: []const u8, id_for: types.ActorId) !actor_mod.Actor {
    const archetype = actor_mod.find(archetype_key) orelse return error.UnknownArchetype;
    const r = gs.rng.random(.actors);
    const first = person_gen.names.first[r.uintLessThan(usize, person_gen.names.first.len)];
    const last = person_gen.names.last[r.uintLessThan(usize, person_gen.names.last.len)];
    const side = std.meta.stringToEnum(actor_mod.FactionSide, archetype.faction_side) orelse .employer;
    return .{
        .id = id_for,
        .archetype_key = archetype_key,
        .first_name = first,
        .last_name = last,
        .faction_key = faction_key,
        .side = side,
        .contract = .none,
        .trust = 0,
        .debt = 0,
        .respect = 0,
        .hostility = 0,
        .last_cause = "",
        .last_cause_day = 0,
        .recurring = false,
    };
}

/// Look for a prior actor with the same (faction, archetype) whose contract is
/// closed. Used at arc attachment to make an actor "recur" (P4h §3 recurrence).
/// Returns the first match found (insertion order), or null.
pub fn priorRelationship(gs: *GameState, faction_key: []const u8, archetype_key: []const u8) ?*actor_mod.Actor {
    var it = gs.actors.iterator();
    while (it.next()) |entry| {
        const a = entry.value_ptr;
        if (!std.mem.eql(u8, a.faction_key, faction_key)) continue;
        if (!std.mem.eql(u8, a.archetype_key, archetype_key)) continue;
        // The prior actor's contract must be closed (not active).
        if (a.contract != .none) {
            const c = gs.contracts.getPtr(a.contract);
            if (c != null and c.?.isRunning()) continue; // still active — not eligible
        }
        return a;
    }
    return null;
}

/// Clamp a value to the actor relationship range.
fn clampRel(v: i32) i16 {
    return @intCast(@min(@as(i32, actor_mod.rel_max), @max(@as(i32, actor_mod.rel_min), v)));
}

/// The prepared relationship change from `adjustRelationship`: all fallible
/// work is done up front so the commit phase is infallible.
pub const PreparedAdjust = struct {
    actor_id: types.ActorId,
    delta: RelDelta,
    cause: []const u8, // duped into gs.allocator()
    log_text: []const u8, // duped into gs.allocator()
    day: u32,
};

/// PREPARE phase of `adjustRelationship`: duplicate the cause string and
/// pre-format the log line — both fallible. Returns a `PreparedAdjust` whose
/// commit phase is infallible. The caller is responsible for the log-slot
/// reservation (gs.reserveLog(1)) before calling this.
/// The actor must exist (caller must check before calling; unreachable otherwise).
pub fn prepareAdjustRelationship(gs: *GameState, actor_id: types.ActorId, delta: RelDelta, cause: []const u8) !PreparedAdjust {
    const cause_dup = try gs.allocator().dupe(u8, cause);
    const a = gs.actor(actor_id) orelse unreachable;
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [actor] {s} {s}: trust {d} debt {d} respect {d} hostility {d} — {s}", .{
        gs.clock.date.text(&date_buf),
        a.first_name,
        a.last_name,
        delta.trust,
        delta.debt,
        delta.respect,
        delta.hostility,
        cause,
    });
    return .{
        .actor_id = actor_id,
        .delta = delta,
        .cause = cause_dup,
        .log_text = log_text,
        .day = gs.clock.day_index,
    };
}

/// COMMIT phase of `adjustRelationship`: infallible. Apply the prepared
/// delta, clamp, record cause, and write the pre-reserved log slot.
pub fn commitAdjustRelationship(gs: *GameState, prepared: PreparedAdjust) void {
    const a = gs.actor(prepared.actor_id) orelse return; // already validated in prepare
    a.trust = clampRel(@as(i32, a.trust) + prepared.delta.trust);
    a.debt = clampRel(@as(i32, a.debt) + prepared.delta.debt);
    a.respect = clampRel(@as(i32, a.respect) + prepared.delta.respect);
    a.hostility = clampRel(@as(i32, a.hostility) + prepared.delta.hostility);
    a.last_cause = prepared.cause;
    a.last_cause_day = prepared.day;
    gs.event_log.appendAssumeCapacity(.{
        .day = prepared.day,
        .category = .contract,
        .company = .none,
        .contract = if (a.contract != .none) a.contract else .none,
        .text = prepared.log_text,
    });
}

/// Single mutation owner: adjust an actor's relationship dimensions and record
/// the cause. All fallible work (log reserve + string dup + pre-format) is in
/// the PREPARE phase so the caller's commit phase stays infallible (rules 7,
/// 11-13). Returns the PreparedAdjust for use in the caller's commit.
/// The caller must call `commitAdjustRelationship` to apply.
pub fn adjustRelationship(gs: *GameState, actor_id: types.ActorId, delta: RelDelta, cause: []const u8) !PreparedAdjust {
    try gs.reserveLog(1);
    return prepareAdjustRelationship(gs, actor_id, delta, cause);
}

/// Named outcome→delta owner for operation resolution (P4h.3, rule 20).
/// Returns the relationship delta for the attached actor when an operation
/// resolves with the given outcome band. All values // TUNE.
pub fn outcomeRelationshipDelta(band: operation_mod.OutcomeBand) RelDelta {
    return switch (band) {
        .decisive => .{ .trust = 5, .respect = 5, .hostility = -3 }, // TUNE
        .success => .{ .trust = 3, .respect = 2, .hostility = -1 }, // TUNE
        .partial => .{ .trust = 1, .respect = 0, .hostility = 1 }, // TUNE
        .setback => .{ .trust = -1, .respect = -1, .hostility = 2 }, // TUNE
        .failure => .{ .trust = -4, .respect = -4, .hostility = 6 }, // TUNE
        .none => .{},
    };
}

/// Named finale→delta owner for finale resolution (P4h.3, rule 20).
/// All values // TUNE.
pub fn finaleRelationshipDelta(f: *const arc_mod.Finale) RelDelta {
    if (f.ends_contract) {
        // Collapse finale: the garrison fell — hostility up, trust down.
        return .{ .trust = -10, .respect = -8, .hostility = 15 }; // TUNE
    }
    // Garrison held: trust and respect up.
    return .{ .trust = 8, .respect = 6, .hostility = -5 }; // TUNE
}

/// Maximum number of actors that can be attached per arc (capacity ceiling).
const max_actors_per_arc: usize = 16;

/// Attach actors for all archetypes in the arc that cover this arc's key.
/// Each actor is first checked for recurrence; if a prior actor of the same
/// (faction, archetype) is found on a closed contract, it is carried forward.
/// id_start is the CURRENT next_actor_id from the caller's snapshot; this
/// function assigns ids from id_start upward but does NOT advance the counter
/// — the caller's commit phase advances gs.next_actor_id (rules 7, 11-13).
/// The arc's archetypes are attached onto the local contract copy `c`.
/// Failure-atomic: on any error, neither c.actor_ids nor gs.actors changes.
pub fn instantiateActors(gs: *GameState, c: *contract_mod.Contract, id_start: u32) !void {
    if (c.arc_key.len == 0) return;

    // Collect archetypes for this arc (stack-only; bounded at max_actors_per_arc).
    var arch_keys: [max_actors_per_arc][]const u8 = undefined;
    var arch_count: usize = 0;
    for (actor_mod.table.archetypes) |a| {
        if (arch_count >= max_actors_per_arc) break;
        for (a.arcs) |arc_key| {
            if (std.mem.eql(u8, arc_key, c.arc_key)) {
                arch_keys[arch_count] = a.key;
                arch_count += 1;
                break;
            }
        }
    }
    if (arch_count == 0) return;

    const alloc = gs.allocator();
    // PREPARE: generate all actors + reserve map capacity.
    // None of these steps mutate gs.actors or c.actor_ids.
    var prepared: [max_actors_per_arc]actor_mod.Actor = undefined;
    var prep_count: usize = 0;
    var next_id: u32 = id_start;
    for (arch_keys[0..arch_count]) |arch_key| {
        const id: types.ActorId = @enumFromInt(next_id);
        var a: actor_mod.Actor = undefined;
        // Check recurrence: same (employer faction, archetype) on a closed contract.
        if (priorRelationship(gs, c.employer_key, arch_key)) |prior| {
            // Carry forward: same name and relationship values.
            a = prior.*;
            a.id = id;
            a.contract = c.id;
            a.recurring = true;
        } else {
            a = try generateActor(gs, arch_key, c.employer_key, id);
            a.contract = c.id;
        }
        prepared[prep_count] = a;
        prep_count += 1;
        next_id += 1;
    }
    // Reserve map capacity before any mutation.
    try gs.actors.ensureUnusedCapacity(alloc, prep_count);
    // Reserve actor_ids list capacity on the contract copy.
    try c.actor_ids.ensureUnusedCapacity(alloc, prep_count);

    // COMMIT: infallible from here.
    for (prepared[0..prep_count]) |a| {
        gs.actors.putAssumeCapacity(a.id, a);
        c.actor_ids.appendAssumeCapacity(a.id);
    }
}

/// All actors attached to this contract (by their ids stored on the contract).
/// Returns a caller-owned slice from the arena allocator.
pub fn attachedActors(alloc: std.mem.Allocator, gs: *GameState, c: *const contract_mod.Contract) ![]actor_mod.Actor {
    var out: std.ArrayListUnmanaged(actor_mod.Actor) = .empty;
    for (c.actor_ids.items) |id| {
        if (gs.actor(id)) |a| try out.append(alloc, a.*);
    }
    return out.toOwnedSlice(alloc);
}

/// Actor→Person boundary (rule 63). In this increment no conversion fires;
/// the typed "none" makes the boundary explicit and tested.
pub const ConversionKind = enum { none };

pub fn conversionAllowed(_: *const actor_mod.Actor) ConversionKind {
    return .none;
}

// ---- Tests -----------------------------------------------------------------

test "generateActor: deterministic per seed, and drawing it does not perturb .battle" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs.deinit();

    // Sample several battle rolls before to get a reference.
    var ref: std.ArrayListUnmanaged(u8) = .empty;
    defer ref.deinit(std.testing.allocator);
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs2.deinit();
    for (0..5) |_| try ref.append(std.testing.allocator, gs2.rng.roll2d6(.battle));

    // Generate actors on gs (draws from .actors stream).
    const id1: types.ActorId = @enumFromInt(1);
    const a1 = try generateActor(&gs, "liaison", "LC", id1);
    const a2 = try generateActor(&gs, "liaison", "LC", @enumFromInt(2));
    try gs.commitActor(a1);
    try gs.commitActor(a2);

    // Now check that battle rolls on gs still match the reference (stream independence).
    for (ref.items) |expected| {
        try std.testing.expectEqual(expected, gs.rng.roll2d6(.battle));
    }

    // Same seed → same names (determinism).
    var gs3 = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs3.deinit();
    const b1 = try generateActor(&gs3, "liaison", "LC", id1);
    try std.testing.expectEqualStrings(a1.first_name, b1.first_name);
    try std.testing.expectEqualStrings(a1.last_name, b1.last_name);
}

test "adjustRelationship: clamps to +-100, records cause and day" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();

    const id: types.ActorId = @enumFromInt(1);
    var a: actor_mod.Actor = .{ .id = id, .archetype_key = "liaison", .first_name = "Ann", .last_name = "Smith" };
    a.hostility = 95;
    try gs.commitActor(a);

    const prep = try adjustRelationship(&gs, id, .{ .hostility = 20 }, "big_win");
    commitAdjustRelationship(&gs, prep);
    try std.testing.expectEqual(@as(i16, 100), gs.actor(id).?.hostility); // clamped to 100
    try std.testing.expectEqualStrings("big_win", gs.actor(id).?.last_cause);
    try std.testing.expectEqual(gs.clock.day_index, gs.actor(id).?.last_cause_day);

    const prep2 = try adjustRelationship(&gs, id, .{ .trust = -200 }, "punish");
    commitAdjustRelationship(&gs, prep2);
    try std.testing.expectEqual(@as(i16, -100), gs.actor(id).?.trust); // clamped to -100

    // Consumer and owner agree on the clamping rule.
    const prep3 = try adjustRelationship(&gs, id, .{ .respect = 50, .trust = 50 }, "test");
    commitAdjustRelationship(&gs, prep3);
    try std.testing.expect(gs.actor(id).?.respect <= 100);
    try std.testing.expect(gs.actor(id).?.trust <= 100);
}

test "outcomeRelationshipDelta and finaleRelationshipDelta: monotonic TUNE invariants" {
    // Success raises trust/respect, failure raises hostility.
    const ds = outcomeRelationshipDelta(.decisive);
    const s = outcomeRelationshipDelta(.success);
    const f = outcomeRelationshipDelta(.failure);
    const setback = outcomeRelationshipDelta(.setback);
    try std.testing.expect(ds.trust > 0);
    try std.testing.expect(s.trust > 0);
    try std.testing.expect(f.hostility > 0);
    try std.testing.expect(f.hostility > setback.hostility); // failure worse than setback
    try std.testing.expect(ds.trust >= s.trust); // decisive better

    // Finale deltas.
    const held: arc_mod.Finale = .{ .key = "held", .name = "Held", .min_clock = 0, .ends_contract = false };
    const fell: arc_mod.Finale = .{ .key = "fell", .name = "Fell", .min_clock = 40, .ends_contract = true };
    const dh = finaleRelationshipDelta(&held);
    const df2 = finaleRelationshipDelta(&fell);
    try std.testing.expect(dh.trust > 0);
    try std.testing.expect(df2.hostility > 0);
}

test "priorRelationship: recurrence lookup carries forward name and relationship" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();

    const id1: types.ActorId = @enumFromInt(1);
    const a1: actor_mod.Actor = .{
        .id = id1,
        .archetype_key = "liaison",
        .first_name = "Li",
        .last_name = "Vance",
        .faction_key = "LC",
        .contract = .none, // no active contract
        .trust = 30,
    };
    try gs.commitActor(a1);

    // Prior with same faction+archetype and no active contract should be found.
    const prior = priorRelationship(&gs, "LC", "liaison");
    try std.testing.expect(prior != null);
    try std.testing.expectEqualStrings("Li", prior.?.first_name);
    try std.testing.expectEqual(@as(i16, 30), prior.?.trust);

    // Different faction → no match.
    try std.testing.expect(priorRelationship(&gs, "FS", "liaison") == null);
    // Different archetype → no match.
    try std.testing.expect(priorRelationship(&gs, "LC", "local_official") == null);
}

test "conversionAllowed: returns .none for every actor" {
    const a: actor_mod.Actor = .{ .archetype_key = "liaison" };
    try std.testing.expectEqual(ConversionKind.none, conversionAllowed(&a));
    const b: actor_mod.Actor = .{ .archetype_key = "enemy_commander" };
    try std.testing.expectEqual(ConversionKind.none, conversionAllowed(&b));
}

test "instantiateActors: failure-atomic under injected OOM" {
    // Use a fixed-buffer allocator that exhausts after a small number of allocs.
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var gs = GameState.init(fba.allocator(), .{ .seed = 2 });
    defer gs.deinit();

    // Set up a contract with a valid arc key.
    const cid: types.ContractId = @enumFromInt(1);
    var c = contract_mod.Contract{
        .id = cid,
        .arc_key = "fracturing_garrison",
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .kind = .garrison_duty,
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
    };

    const before_count = gs.actors.count();
    const before_next = gs.next_actor_id;

    // With a tiny buffer this will OOM during preparation.
    const result = instantiateActors(&gs, &c, gs.next_actor_id);
    // Whether or not it errored, the invariant holds: counters unchanged.
    _ = result catch {};
    // next_actor_id is NOT advanced by instantiateActors — only the caller's commit does.
    try std.testing.expectEqual(before_next, gs.next_actor_id);
    // actors map unchanged or potentially has entries if prepare succeeded.
    // The critical invariant: if it errored, the map count must equal before.
    if (result) |_| {
        // Success path is fine.
    } else |_| {
        try std.testing.expectEqual(before_count, gs.actors.count());
    }
}
