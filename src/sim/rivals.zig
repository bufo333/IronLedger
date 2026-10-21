//! Rival company rule owners: generation, recurrence, standing mutation,
//! delta owners, and attachment (P4i, P4 operations design §§3,5).
//! No MekHQ counterpart (P4 operations design §§3,5).
//! Rule 5 / queries leaf: this module does NOT import queries.zig.

const std = @import("std");
const types = @import("../domain/types.zig");
const rival_mod = @import("../domain/rival.zig");
const arc_mod = @import("../domain/arc.zig");
const operation_mod = @import("../domain/operation.zig");
const contract_mod = @import("../domain/contract.zig");
const rng_mod = @import("rng.zig");
const person_gen = @import("../gen/person_gen.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const merc_company_mod = @import("../domain/merc_company.zig");
const merc_band = @import("../domain/merc_band.zig");
const chassis_mod = @import("../domain/chassis.zig");
const force = @import("../domain/force.zig");
const unit = @import("../domain/unit.zig");
const tuning = @import("../domain/tuning.zig").t;
const npc_base = @import("npc_base.zig");

/// Generate rival names and identity using the `.rivals` RNG stream (rule 57).
/// Deterministic per seed; drawing does not perturb `.actors`, `.battle`, or `.generation`.
pub fn generateRival(gs: *GameState, archetype_key: []const u8, faction_key: []const u8, id_for: types.RivalId) !rival_mod.Rival {
    const archetype = rival_mod.find(archetype_key) orelse return error.UnknownArchetype;
    const r = gs.rng.random(.rivals);
    const first = person_gen.names.first[r.uintLessThan(usize, person_gen.names.first.len)];
    const last = person_gen.names.last[r.uintLessThan(usize, person_gen.names.last.len)];
    const side = std.meta.stringToEnum(rival_mod.FactionSide, archetype.faction_side) orelse .employer;
    const doctrine = std.meta.stringToEnum(rival_mod.RivalDoctrine, archetype.doctrine) orelse .cautious;
    const unit_name = try std.fmt.allocPrint(gs.allocator(), "{s} {s}", .{ last, archetype.unit_noun });
    return .{
        .id = id_for,
        .archetype_key = archetype_key,
        .commander_first = first,
        .commander_last = last,
        .unit_name = unit_name,
        .faction_key = faction_key,
        .side = side,
        .doctrine = doctrine,
        .contract = .none,
        .standing = 0,
        .encounters = 1,
        .last_cause = "",
        .last_cause_day = 0,
        .recurring = false,
    };
}

/// Look for a prior rival with the same (faction, archetype) whose contract is
/// closed. Returns the prior rival with the highest id (most recently introduced),
/// so recurrence carries forward the most recent accumulated history.
pub fn priorRival(gs: *GameState, faction_key: []const u8, archetype_key: []const u8) ?*rival_mod.Rival {
    var best: ?*rival_mod.Rival = null;
    var best_id: u32 = 0;
    var it = gs.rivals.iterator();
    while (it.next()) |entry| {
        const rv = entry.value_ptr;
        if (!std.mem.eql(u8, rv.faction_key, faction_key)) continue;
        if (!std.mem.eql(u8, rv.archetype_key, archetype_key)) continue;
        // The prior rival's contract must be closed (not active).
        if (rv.contract != .none) {
            const c = gs.contracts.getPtr(rv.contract);
            if (c != null and c.?.isRunning()) continue; // still active — not eligible
        }
        const id = @intFromEnum(rv.id);
        if (best == null or id > best_id) {
            best = rv;
            best_id = id;
        }
    }
    return best;
}

/// Single named owner for standing → status (rule 20).
/// Thresholds: standing ≤ −40 → hostile; ≥ 40 → allied; else active. // TUNE
pub fn statusFor(standing: i16) rival_mod.RivalStatus {
    if (standing <= -40) return .hostile; // TUNE
    if (standing >= 40) return .allied; // TUNE
    return .active;
}

/// Single named owner: sum of chassis BV over the `.active` hulls in a
/// merc company's pool that it can field today (`npc_base.hullFieldable`:
/// none still travelling to its base) (docs/p3c-economy-design.md §4, §8.G;
/// docs/p5d-conflict-world-design.md §L1; rule 20/24).
/// Returns 0 when the id has no roster entry (no campaign company).
/// Pure, no allocation, no I/O.
pub fn mercCompanyFieldableBv(gs: *GameState, id: types.MercCompanyId) i64 {
    const roster = gs.merc_company_rosters.get(id) orelse return 0;
    var total: i64 = 0;
    for (roster.items) |hid| {
        const inst = gs.hull_instances.getPtr(hid) orelse continue;
        if (inst.status != .active) continue;
        if (!npc_base.hullFieldable(gs, hid, gs.clock.day_index)) continue;
        const ch = chassis_mod.find(inst.base_key) orelse continue;
        total += @as(i64, ch.bv);
    }
    return total;
}

/// Single named owner: a merc company is insolvent when it HAS a roster
/// and its fieldable BV is below the insolvency threshold
/// (docs/p3c-economy-design.md §4 "Rival insolvency", §8.G; rule 20/24).
/// Every campaign company has a roster entry (`GameState.merc_company_rosters`),
/// so a company with no hulls is insolvent; an id with no entry is not.
pub fn mercCompanyInsolvent(gs: *GameState, id: types.MercCompanyId) bool {
    return gs.merc_company_rosters.getPtr(id) != null and
        mercCompanyFieldableBv(gs, id) < tuning.generation.merc_company_insolvency_bv;
}

/// Single owner of "may this merc company be a contract OpFor" (rule 20).
/// Eligible iff active (dissolved_day == 0), solvent (!mercCompanyInsolvent),
/// and the active meks it can field today (`mercCompanyFieldableCounts`)
/// reach its band's `merc_band.lineTarget` (docs/p5d-conflict-world-design.md
/// §L1, §L8, D23). Vehicles and aerospace hulls contribute BV but never
/// satisfy mek readiness. A company with no roster entry, or whose
/// `band_key` names no band, is under strength → ineligible (rule 1).
pub fn mercCompanyEligibleAsOpFor(gs: *GameState, id: types.MercCompanyId) bool {
    const mc = gs.merc_companies.getPtr(id) orelse return false;
    if (mc.dissolved_day != 0) return false;
    if (mercCompanyInsolvent(gs, id)) return false;
    const band = merc_band.find(mc.band_key) orelse return false;
    return !mercCompanyUnderstrength(band, mercCompanyFieldableCounts(gs, id));
}

/// Single owner of "is a merc company of `band` with `counts` below its line"
/// (rule 20/3): its active meks fall short of `merc_band.lineTarget`
/// (docs/p5d-conflict-world-design.md §L7 step 5, §L8). Vehicles and
/// aerospace hulls never count toward it. OpFor readiness, the mek purchase
/// target and the dissolution runway all read this one test. Pure.
pub fn mercCompanyUnderstrength(band: *const merc_band.Band, counts: MercHullCounts) bool {
    return counts.meks < merc_band.lineTarget(band);
}

/// Single owner of "does this merc company hold an active commitment"
/// (rule 20; docs/p5d-conflict-world-design.md §L7 "Dissolution", C1): some
/// rival naming it sits on a contract that `isRunning()`, the same test
/// `priorRival` applies. The rival overlay stands for the §D commitment
/// records; callers rely only on this answer, never on the overlay. Pure.
pub fn mercCompanyCommitted(gs: *const GameState, id: types.MercCompanyId) bool {
    if (id == .none) return false;
    for (gs.rivals.values()) |rv| {
        if (rv.merc_company_id != id) continue;
        const contract = gs.contracts.getPtr(rv.contract) orelse continue;
        if (contract.isRunning()) return true;
    }
    return false;
}

/// Active hulls in a merc company's roster, by procurement kind.
pub const MercHullCounts = struct {
    meks: usize = 0,
    vehicles: usize = 0,
    aerospace: usize = 0,

    /// Count one hull of `kind`; kinds outside procurement are ignored.
    pub fn add(self: *MercHullCounts, kind: unit.UnitKind) void {
        switch (kind) {
            .mek => self.meks += 1,
            .vehicle => self.vehicles += 1,
            .aerospace => self.aerospace += 1,
            else => {},
        }
    }
};

/// Count the `.active` hulls a merc company owns, by chassis kind, those
/// still travelling to its base included: the procurement need, the
/// understrength record and the dissolution runway read owned strength, so
/// a hull in transit fills its slot and is not bought twice. Other kinds and
/// unknown chassis are not counted; an id with no roster entry counts zero.
/// Pure.
pub fn mercCompanyHullCounts(gs: *const GameState, id: types.MercCompanyId) MercHullCounts {
    return countHulls(gs, id, false);
}

/// Count the `.active` hulls a merc company can field today, by chassis
/// kind: `mercCompanyHullCounts` less the hulls still travelling to its base
/// (`npc_base.hullFieldable`; docs/p5d-conflict-world-design.md §L1 "not
/// fieldable before"). OpFor readiness reads it. Pure.
pub fn mercCompanyFieldableCounts(gs: *const GameState, id: types.MercCompanyId) MercHullCounts {
    return countHulls(gs, id, true);
}

fn countHulls(gs: *const GameState, id: types.MercCompanyId, fieldable_only: bool) MercHullCounts {
    const roster = gs.merc_company_rosters.get(id) orelse return .{};
    var counts: MercHullCounts = .{};
    for (roster.items) |hid| {
        const inst = gs.hull_instances.get(hid) orelse continue;
        if (inst.status != .active) continue;
        if (fieldable_only and !npc_base.hullFieldable(gs, hid, gs.clock.day_index)) continue;
        const chassis = chassis_mod.find(inst.base_key) orelse continue;
        counts.add(chassis.kind);
    }
    return counts;
}

/// The band row of a merc company's `band_key`. Seeding, replacement and
/// loading always set a known key, so an unknown one is a broken state
/// invariant: `CorruptSave`, never a default band (rule 1).
pub fn mercCompanyBand(company: merc_company_mod.MercCompany) error{CorruptSave}!*const merc_band.Band {
    return merc_band.find(company.band_key) orelse error.CorruptSave;
}

/// Single owner of "does a merc company of `band` with `counts` still want a
/// hull of `kind`" (rule 20/3). Meks fill the band's `merc_band.lineTarget`;
/// vehicles fill line positions meks leave open only in a band whose
/// `vehicles_fill_line` allows it; aerospace fills the air reserve; no other
/// kind is procured. Targets: docs/p5d-conflict-world-design.md §L8 and D23
/// (line and mek) and docs/p2-conventional-combat-design.md §NPC Policy (air
/// reserve). Pure.
pub fn mercCompanyNeedsHull(band: *const merc_band.Band, counts: MercHullCounts, kind: unit.UnitKind) bool {
    const line_target = merc_band.lineTarget(band);
    const air_target: usize = @as(usize, tuning.generation.merc_company_air_reserve_lances) * force.lance_size;
    return switch (kind) {
        .mek => mercCompanyUnderstrength(band, counts),
        .vehicle => band.vehicles_fill_line and counts.meks + counts.vehicles < line_target,
        .aerospace => counts.aerospace < air_target,
        else => false,
    };
}

/// Named outcome→delta owner for operation resolution (P4i, rule 20).
/// All values // TUNE.
pub fn outcomeRivalStandingDelta(band: operation_mod.OutcomeBand) i16 {
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
pub fn finaleRivalStandingDelta(f: *const arc_mod.Finale) i16 {
    if (f.ends_contract) {
        // Collapse: the garrison fell — standing down.
        return -12; // TUNE
    }
    // Garrison held: standing up.
    return 10; // TUNE
}

/// The prepared standing change from `adjustRival`: all fallible work is done
/// up front so the commit phase is infallible.
pub const PreparedRivalAdjust = struct {
    rival_id: types.RivalId,
    delta: i16,
    cause: []const u8, // duped into gs.allocator()
    log_text: []const u8, // duped into gs.allocator()
    day: u32,
};

/// PREPARE phase of `adjustRival`: duplicate the cause string and pre-format
/// the log line — both fallible. Returns a `PreparedRivalAdjust` whose commit
/// phase is infallible. The caller is responsible for the log-slot reservation
/// (gs.reserveLog(1)) before calling this.
/// The rival must exist (caller must check before calling; unreachable otherwise).
pub fn prepareAdjustRival(gs: *GameState, rival_id: types.RivalId, delta: i16, cause: []const u8) !PreparedRivalAdjust {
    const cause_dup = try gs.allocator().dupe(u8, cause);
    const rv = gs.rival(rival_id) orelse unreachable;
    var date_buf: [10]u8 = undefined;
    const log_text = try std.fmt.allocPrint(gs.allocator(), "{s} [rival] {s}: standing {d} — {s}", .{
        gs.clock.date.text(&date_buf),
        rv.unit_name,
        delta,
        cause,
    });
    return .{
        .rival_id = rival_id,
        .delta = delta,
        .cause = cause_dup,
        .log_text = log_text,
        .day = gs.clock.day_index,
    };
}

/// COMMIT phase of `adjustRival`: infallible. Apply the prepared delta, clamp,
/// recompute status (implicitly through standing), record cause, and write the
/// pre-reserved log slot.
pub fn commitAdjustRival(gs: *GameState, prepared: PreparedRivalAdjust) void {
    const rv = gs.rival(prepared.rival_id) orelse return; // validated in prepare
    const new_standing: i32 = @as(i32, rv.standing) + prepared.delta;
    rv.standing = @intCast(@min(@as(i32, rival_mod.rival_max), @max(@as(i32, rival_mod.rival_min), new_standing)));
    rv.last_cause = prepared.cause;
    rv.last_cause_day = prepared.day;
    gs.event_log.appendAssumeCapacity(.{
        .day = prepared.day,
        .category = .contract,
        .company = .none,
        .contract = if (rv.contract != .none) rv.contract else .none,
        .text = prepared.log_text,
    });
}

/// Single mutation owner: adjust a rival's standing and record the cause.
/// All fallible work (log reserve + string dup + pre-format) is in the PREPARE
/// phase so the caller's commit phase stays infallible (rules 7, 11-13).
/// Returns the PreparedRivalAdjust for use in the caller's commit.
/// The caller must call `commitAdjustRival` to apply.
pub fn adjustRival(gs: *GameState, rival_id: types.RivalId, delta: i16, cause: []const u8) !PreparedRivalAdjust {
    try gs.reserveLog(1);
    return prepareAdjustRival(gs, rival_id, delta, cause);
}

/// Maximum number of rivals that can be attached per arc (capacity ceiling).
const max_rivals_per_arc: usize = 16;

/// Attach rivals for all archetypes in the rival table that cover this arc's key.
/// Each rival is first checked for recurrence; if a prior rival of the same
/// (faction, archetype) is found on a closed contract, it is carried forward.
/// id_start is the CURRENT next_rival_id from the caller's snapshot; this
/// function assigns ids from id_start upward but does NOT advance the counter
/// — the caller's commit phase advances gs.next_rival_id (rules 7, 11-13).
/// Failure-atomic: on any error, neither c.rival_ids nor gs.rivals changes.
pub fn instantiateRivals(gs: *GameState, c: *contract_mod.Contract, id_start: u32) !void {
    if (c.arc_key.len == 0) return;

    // Collect archetypes for this arc (stack-only; bounded at max_rivals_per_arc).
    var arch_keys: [max_rivals_per_arc][]const u8 = undefined;
    var arch_count: usize = 0;
    for (rival_mod.table.archetypes) |a| {
        if (arch_count >= max_rivals_per_arc) break;
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
    // PREPARE: generate all rivals + reserve map capacity.
    // None of these steps mutate gs.rivals or c.rival_ids.
    var prepared: [max_rivals_per_arc]rival_mod.Rival = undefined;
    var prep_count: usize = 0;
    var next_id: u32 = id_start;
    for (arch_keys[0..arch_count]) |arch_key| {
        // Enemy-side archetypes belong to the enemy faction; all others to the employer.
        const arch = rival_mod.find(arch_key).?; // validated when collecting arch_keys above
        const side = std.meta.stringToEnum(rival_mod.FactionSide, arch.faction_side) orelse .employer;
        const faction_key = if (side == .enemy) c.enemy_key else c.employer_key;
        const id: types.RivalId = @enumFromInt(next_id);
        var rv: rival_mod.Rival = undefined;
        // Check recurrence: same (faction, archetype) on a closed contract.
        if (priorRival(gs, faction_key, arch_key)) |prior| {
            // Carry forward: same name and standing.
            rv = prior.*;
            rv.id = id;
            rv.contract = c.id;
            rv.recurring = true;
            rv.encounters += 1;
        } else {
            rv = try generateRival(gs, arch_key, faction_key, id);
            rv.contract = c.id;
            // encounters = 1 is set by generateRival
        }
        // Draw a merc company from the world pool (docs/p3c-economy-design.md §8.B).
        // Only eligible companies (active, solvent, at full strength) are candidates
        // (P3f.4): count-then-pick to preserve RNG-draw count and selection order
        // (rules 1, 7, 11-13).
        // Guard: leave .none when no eligible company exists (no partial truth, rule 1).
        {
            var eligible: usize = 0;
            for (gs.merc_companies.keys()) |key| {
                if (mercCompanyEligibleAsOpFor(gs, key)) eligible += 1;
            }
            if (eligible > 0) {
                const pick = gs.rng.random(.rivals).uintLessThan(usize, eligible);
                var seen: usize = 0;
                for (gs.merc_companies.keys()) |key| {
                    if (mercCompanyEligibleAsOpFor(gs, key)) {
                        if (seen == pick) {
                            rv.merc_company_id = key;
                            break;
                        }
                        seen += 1;
                    }
                }
            }
        }
        prepared[prep_count] = rv;
        prep_count += 1;
        next_id += 1;
    }
    // Reserve map capacity before any mutation.
    try gs.rivals.ensureUnusedCapacity(alloc, prep_count);
    // Reserve rival_ids list capacity on the contract copy.
    try c.rival_ids.ensureUnusedCapacity(alloc, prep_count);

    // COMMIT: infallible from here.
    for (prepared[0..prep_count]) |rv| {
        gs.rivals.putAssumeCapacity(rv.id, rv);
        c.rival_ids.appendAssumeCapacity(rv.id);
    }
}

/// All rivals attached to this contract (by their ids stored on the contract).
/// Returns a caller-owned slice from the arena allocator.
pub fn attachedRivals(alloc: std.mem.Allocator, gs: *GameState, c: *const contract_mod.Contract) ![]rival_mod.Rival {
    var out: std.ArrayListUnmanaged(rival_mod.Rival) = .empty;
    for (c.rival_ids.items) |id| {
        if (gs.rival(id)) |rv| try out.append(alloc, rv.*);
    }
    return out.toOwnedSlice(alloc);
}

// ---- Tests -----------------------------------------------------------------

test "generateRival: deterministic per seed, and drawing it does not perturb .actors or .battle streams" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs.deinit();

    // Sample several battle rolls before to get a reference.
    var ref_battle: std.ArrayListUnmanaged(u8) = .empty;
    defer ref_battle.deinit(std.testing.allocator);
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs2.deinit();
    for (0..5) |_| try ref_battle.append(std.testing.allocator, gs2.rng.roll2d6(.battle));

    // Sample several actor rolls before to get a reference.
    var ref_actors: std.ArrayListUnmanaged(u8) = .empty;
    defer ref_actors.deinit(std.testing.allocator);
    for (0..5) |_| try ref_actors.append(std.testing.allocator, gs2.rng.roll2d6(.actors));

    // Generate rivals on gs (draws from .rivals stream).
    const id1: types.RivalId = @enumFromInt(1);
    const rv1 = try generateRival(&gs, "enemy_raiders", "DC", id1);
    const rv2 = try generateRival(&gs, "rival_garrison", "LC", @enumFromInt(2));
    try gs.commitRival(rv1);
    try gs.commitRival(rv2);

    // Battle stream must be unperturbed.
    for (ref_battle.items) |expected| {
        try std.testing.expectEqual(expected, gs.rng.roll2d6(.battle));
    }
    // Actors stream must be unperturbed.
    for (ref_actors.items) |expected| {
        try std.testing.expectEqual(expected, gs.rng.roll2d6(.actors));
    }

    // Same seed → same names (determinism).
    var gs3 = GameState.init(std.testing.allocator, .{ .seed = 42 });
    defer gs3.deinit();
    const b1 = try generateRival(&gs3, "enemy_raiders", "DC", id1);
    try std.testing.expectEqualStrings(rv1.commander_first, b1.commander_first);
    try std.testing.expectEqualStrings(rv1.commander_last, b1.commander_last);
}

test "statusFor: thresholds for representative standings" {
    const cases = [_]struct { standing: i16, expected: rival_mod.RivalStatus }{
        .{ .standing = -100, .expected = .hostile },
        .{ .standing = -40, .expected = .hostile },
        .{ .standing = -39, .expected = .active },
        .{ .standing = 0, .expected = .active },
        .{ .standing = 39, .expected = .active },
        .{ .standing = 40, .expected = .allied },
        .{ .standing = 100, .expected = .allied },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.expected, statusFor(c.standing));
    }
}

test "outcomeRivalStandingDelta and finaleRivalStandingDelta: monotonic TUNE invariants" {
    const ds = outcomeRivalStandingDelta(.decisive);
    const s = outcomeRivalStandingDelta(.success);
    const f = outcomeRivalStandingDelta(.failure);
    const setback = outcomeRivalStandingDelta(.setback);
    // Success directions: decisive ≥ success > 0
    try std.testing.expect(ds >= s);
    try std.testing.expect(s > 0);
    // Failure directions: failure < setback < 0
    try std.testing.expect(f < setback);
    try std.testing.expect(setback < 0);

    // Finale deltas.
    const held: arc_mod.Finale = .{ .key = "held", .name = "Held", .min_clock = 0, .ends_contract = false };
    const fell: arc_mod.Finale = .{ .key = "fell", .name = "Fell", .min_clock = 40, .ends_contract = true };
    try std.testing.expect(finaleRivalStandingDelta(&held) > 0);
    try std.testing.expect(finaleRivalStandingDelta(&fell) < 0);
}

test "adjustRival: clamps to +-100, records cause and day, recomputes status" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();

    const id: types.RivalId = @enumFromInt(1);
    try gs.commitRival(.{
        .id = id,
        .archetype_key = "enemy_raiders",
        .unit_name = "Smith Raiders",
        .faction_key = "DC",
        .standing = 95,
    });

    const prep = try adjustRival(&gs, id, 20, "big_win");
    commitAdjustRival(&gs, prep);
    try std.testing.expectEqual(@as(i16, rival_mod.rival_max), gs.rival(id).?.standing); // clamped to 100
    try std.testing.expectEqualStrings("big_win", gs.rival(id).?.last_cause);
    try std.testing.expectEqual(gs.clock.day_index, gs.rival(id).?.last_cause_day);
    // Status matches statusFor(100) = allied.
    try std.testing.expectEqual(rival_mod.RivalStatus.allied, statusFor(gs.rival(id).?.standing));

    const prep2 = try adjustRival(&gs, id, -200, "collapse");
    commitAdjustRival(&gs, prep2);
    try std.testing.expectEqual(@as(i16, rival_mod.rival_min), gs.rival(id).?.standing); // clamped to -100
    // Status matches statusFor(-100) = hostile.
    try std.testing.expectEqual(rival_mod.RivalStatus.hostile, statusFor(gs.rival(id).?.standing));
}

test "priorRival: recurrence lookup — closed-contract-only, highest-id wins, faction and archetype must both match" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();

    const id1: types.RivalId = @enumFromInt(1);
    const rv1: rival_mod.Rival = .{
        .id = id1,
        .archetype_key = "enemy_raiders",
        .unit_name = "Test Raiders",
        .faction_key = "DC",
        .contract = .none, // no active contract
        .standing = 20,
    };
    try gs.commitRival(rv1);

    // Prior with same faction+archetype and no active contract should be found.
    const prior = priorRival(&gs, "DC", "enemy_raiders");
    try std.testing.expect(prior != null);
    try std.testing.expectEqual(@as(i16, 20), prior.?.standing);

    // Different faction → no match.
    try std.testing.expect(priorRival(&gs, "LC", "enemy_raiders") == null);
    // Different archetype → no match.
    try std.testing.expect(priorRival(&gs, "DC", "rival_garrison") == null);
}

test "priorRival: multi-prior returns the most-recently-introduced rival (highest id)" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8 });
    defer gs.deinit();

    for ([_]u32{ 1, 2, 3 }) |raw_id| {
        const rid: types.RivalId = @enumFromInt(raw_id);
        const rv: rival_mod.Rival = .{
            .id = rid,
            .archetype_key = "enemy_raiders",
            .unit_name = "Test Raiders",
            .faction_key = "DC",
            .contract = .none,
            .standing = @intCast(raw_id * 10),
        };
        try gs.commitRival(rv);
    }

    const prior = priorRival(&gs, "DC", "enemy_raiders");
    try std.testing.expect(prior != null);
    try std.testing.expectEqual(@as(types.RivalId, @enumFromInt(3)), prior.?.id);
    try std.testing.expectEqual(@as(i16, 30), prior.?.standing);
}

test "instantiateRivals: enemy-side archetype gets enemy_key as faction_key" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();

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

    try instantiateRivals(&gs, &c, 1);
    try std.testing.expect(gs.rivals.count() > 0);

    // At least one enemy-side rival must have faction_key == "DC".
    var found_enemy = false;
    var it = gs.rivals.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.faction_key, "DC")) {
            found_enemy = true;
            break;
        }
    }
    try std.testing.expect(found_enemy);

    // Every rival's faction_key must match its archetype's side.
    it = gs.rivals.iterator();
    while (it.next()) |entry| {
        const rv = entry.value_ptr;
        if (rv.side == .enemy) {
            try std.testing.expectEqualStrings("DC", rv.faction_key);
        } else {
            try std.testing.expectEqualStrings("LC", rv.faction_key);
        }
    }
}

test "instantiateRivals: failure-atomic under injected OOM" {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var gs = GameState.init(fba.allocator(), .{ .seed = 2 });
    defer gs.deinit();

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

    const before_count = gs.rivals.count();
    const before_next = gs.next_rival_id;

    const result = instantiateRivals(&gs, &c, gs.next_rival_id);
    _ = result catch {};
    // next_rival_id is NOT advanced by instantiateRivals — only the caller's commit does.
    try std.testing.expectEqual(before_next, gs.next_rival_id);
    if (result) |_| {
        // Success path is fine.
    } else |_| {
        try std.testing.expectEqual(before_count, gs.rivals.count());
    }
}

test "asset-safety: adjustRival and instantiateRivals never touch funds, forces, or units" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs.deinit();

    // Set up nonzero funds.
    gs.funds = 5_000_000;

    // Create a force with local_funds.
    const fid = try gs.createForce("Alpha", .company, .none);
    if (gs.forces.getPtr(fid)) |f| f.local_funds = 100_000;

    const initial_funds = gs.funds;
    const initial_forces = gs.forces.count();
    const initial_units = gs.units.count();
    const initial_hq_funds: i64 = blk: {
        var total: i64 = 0;
        var it = gs.hqs.iterator();
        while (it.next()) |e| total += e.value_ptr.funds;
        break :blk total;
    };

    // Set up a rival and adjust it.
    const rid: types.RivalId = @enumFromInt(1);
    const rv: rival_mod.Rival = .{
        .id = rid,
        .archetype_key = "enemy_raiders",
        .unit_name = "Test Raiders",
        .faction_key = "DC",
        .standing = 0,
    };
    try gs.commitRival(rv);

    const prep = try adjustRival(&gs, rid, 10, "test_cause");
    commitAdjustRival(&gs, prep);

    // instantiateRivals on an arc contract.
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
    try instantiateRivals(&gs, &c, 2);

    // Asset safety: none of these must have changed.
    try std.testing.expectEqual(initial_funds, gs.funds);
    try std.testing.expectEqual(initial_forces, gs.forces.count());
    try std.testing.expectEqual(initial_units, gs.units.count());

    var hq_funds_after: i64 = 0;
    var it = gs.hqs.iterator();
    while (it.next()) |e| hq_funds_after += e.value_ptr.funds;
    try std.testing.expectEqual(initial_hq_funds, hq_funds_after);

    // Force local_funds unchanged.
    if (gs.forces.getPtr(fid)) |f| {
        try std.testing.expectEqual(@as(i64, 100_000), f.local_funds);
    }
}

test "instantiateRivals: links each rival to an existing merc company, deterministically" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 11 });
    defer gs.deinit();

    // Insert three merc companies into the pool (via the arena so deinit frees them).
    // Each company must hold its band's line target in meks to be eligible as
    // OpFor (mercCompanyEligibleAsOpFor requires full strength).
    const alloc = gs.allocator();
    const band = merc_band.find("band_4").?;
    var next_hid: u32 = 1;
    for ([_]u32{ 1, 2, 3 }) |raw| {
        const mcid: types.MercCompanyId = @enumFromInt(raw);
        try gs.merc_companies.put(alloc, mcid, merc_company_mod.MercCompany{
            .id = mcid,
            .archetype_key = "enemy_raiders",
            .commander_first = "Ann",
            .commander_last = "Smith",
            .unit_name = "Smith Raiders",
            .faction_key = "DC",
            .side = .enemy,
            .doctrine = .aggressive,
            .band_key = band.key,
        });
        var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..merc_band.lineTarget(band)) |_| {
            const hid: types.HullInstanceId = @enumFromInt(next_hid);
            next_hid += 1;
            try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V" });
            try roster.append(alloc, hid);
        }
        try gs.merc_company_rosters.put(alloc, mcid, roster);
    }

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
    try instantiateRivals(&gs, &c, 1);

    // Every rival must have a non-.none merc_company_id that resolves.
    try std.testing.expect(gs.rivals.count() > 0);
    var it = gs.rivals.iterator();
    while (it.next()) |entry| {
        const rv = entry.value_ptr;
        try std.testing.expect(rv.merc_company_id != .none);
        try std.testing.expect(gs.merc_companies.getPtr(rv.merc_company_id) != null);
    }

    // Collect assignments from first run.
    var first_ids: std.ArrayListUnmanaged(types.RivalId) = .empty;
    defer first_ids.deinit(a);
    var first_mcids: std.ArrayListUnmanaged(types.MercCompanyId) = .empty;
    defer first_mcids.deinit(a);
    it = gs.rivals.iterator();
    while (it.next()) |entry| {
        try first_ids.append(a, entry.value_ptr.id);
        try first_mcids.append(a, entry.value_ptr.merc_company_id);
    }

    // Second GameState with the same seed and the same pool (mirror the hull seeding).
    var gs2 = GameState.init(a, .{ .seed = 11 });
    defer gs2.deinit();
    const alloc2 = gs2.allocator();
    var next_hid2: u32 = 1;
    for ([_]u32{ 1, 2, 3 }) |raw| {
        const mcid: types.MercCompanyId = @enumFromInt(raw);
        try gs2.merc_companies.put(alloc2, mcid, merc_company_mod.MercCompany{
            .id = mcid,
            .archetype_key = "enemy_raiders",
            .commander_first = "Ann",
            .commander_last = "Smith",
            .unit_name = "Smith Raiders",
            .faction_key = "DC",
            .side = .enemy,
            .doctrine = .aggressive,
            .band_key = band.key,
        });
        var roster2: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..merc_band.lineTarget(band)) |_| {
            const hid2: types.HullInstanceId = @enumFromInt(next_hid2);
            next_hid2 += 1;
            try gs2.hull_instances.put(alloc2, hid2, .{ .id = hid2, .base_key = "LCT-1V" });
            try roster2.append(alloc2, hid2);
        }
        try gs2.merc_company_rosters.put(alloc2, mcid, roster2);
    }
    var c2 = contract_mod.Contract{
        .id = cid,
        .arc_key = "fracturing_garrison",
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .kind = .garrison_duty,
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
    };
    try instantiateRivals(&gs2, &c2, 1);
    try std.testing.expectEqual(gs.rivals.count(), gs2.rivals.count());

    // Per-rival assignments must be identical (determinism).
    for (first_ids.items, first_mcids.items) |rid, mcid| {
        const rv2 = gs2.rivals.getPtr(rid) orelse return error.TestFailed;
        try std.testing.expectEqual(mcid, rv2.merc_company_id);
    }
}

test "instantiateRivals: empty merc-company pool leaves merc_company_id none" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    // gs.merc_companies is empty — the guard must fire and no draw is made.

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
    try instantiateRivals(&gs, &c, 1);

    try std.testing.expect(gs.rivals.count() > 0);
    var it = gs.rivals.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqual(types.MercCompanyId.none, entry.value_ptr.merc_company_id);
    }
}

test "mercCompanyFieldableBv: sums active-pool chassis BV; excludes permanently_destroyed; 0 for absent roster" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 99 });
    defer gs.deinit();
    const alloc = gs.allocator();

    const mc1: types.MercCompanyId = @enumFromInt(1);
    const mc2: types.MercCompanyId = @enumFromInt(2); // no roster entry — absent

    // Three hull instances for mc1: LCT-1V (BV=432), JR7-D (BV=875), PXH-1 (BV=1041).
    const h1: types.HullInstanceId = @enumFromInt(1);
    const h2: types.HullInstanceId = @enumFromInt(2);
    const h3: types.HullInstanceId = @enumFromInt(3);
    try gs.hull_instances.put(alloc, h1, .{ .id = h1, .base_key = "LCT-1V" }); // active by default
    try gs.hull_instances.put(alloc, h2, .{ .id = h2, .base_key = "JR7-D" });
    try gs.hull_instances.put(alloc, h3, .{ .id = h3, .base_key = "PXH-1" });

    // Insert mc1's roster with all three hulls.
    var roster: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    try roster.append(alloc, h1);
    try roster.append(alloc, h2);
    try roster.append(alloc, h3);
    try gs.merc_company_rosters.put(alloc, mc1, roster);

    // All active: expect 432 + 875 + 1041 = 2348.
    try std.testing.expectEqual(@as(i64, 2348), mercCompanyFieldableBv(&gs, mc1));

    // Mark h1 permanently_destroyed — its BV drops out: 875 + 1041 = 1916.
    gs.hull_instances.getPtr(h1).?.status = .permanently_destroyed;
    try std.testing.expectEqual(@as(i64, 1916), mercCompanyFieldableBv(&gs, mc1));

    // Absent roster entry → 0 (mc2 has no roster).
    try std.testing.expectEqual(@as(i64, 0), mercCompanyFieldableBv(&gs, mc2));
}

test "mercCompanyInsolvent: threshold boundary; absent roster is solvent" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 100 });
    defer gs.deinit();
    const alloc = gs.allocator();

    const mc_absent: types.MercCompanyId = @enumFromInt(1); // no roster — solvent
    const mc_insolvent: types.MercCompanyId = @enumFromInt(2); // roster with BV < threshold
    const mc_solvent: types.MercCompanyId = @enumFromInt(3); // roster with BV >= threshold

    // mc_insolvent: one hull with LCT-1V (BV=432) — well below 2000.
    const h1: types.HullInstanceId = @enumFromInt(10);
    try gs.hull_instances.put(alloc, h1, .{ .id = h1, .base_key = "LCT-1V" });
    var r_insolvent: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    try r_insolvent.append(alloc, h1);
    try gs.merc_company_rosters.put(alloc, mc_insolvent, r_insolvent);

    // mc_solvent: three hulls with LCT-1V+JR7-D+PXH-1 = 432+875+1041 = 2348 ≥ 2000.
    const h2: types.HullInstanceId = @enumFromInt(11);
    const h3: types.HullInstanceId = @enumFromInt(12);
    const h4: types.HullInstanceId = @enumFromInt(13);
    try gs.hull_instances.put(alloc, h2, .{ .id = h2, .base_key = "LCT-1V" });
    try gs.hull_instances.put(alloc, h3, .{ .id = h3, .base_key = "JR7-D" });
    try gs.hull_instances.put(alloc, h4, .{ .id = h4, .base_key = "PXH-1" });
    var r_solvent: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    try r_solvent.append(alloc, h2);
    try r_solvent.append(alloc, h3);
    try r_solvent.append(alloc, h4);
    try gs.merc_company_rosters.put(alloc, mc_solvent, r_solvent);

    // Absent roster → not insolvent (solvent by convention).
    try std.testing.expect(!mercCompanyInsolvent(&gs, mc_absent));
    // Below threshold → insolvent.
    try std.testing.expect(mercCompanyInsolvent(&gs, mc_insolvent));
    // At or above threshold (2348 >= 2000) → not insolvent.
    try std.testing.expect(!mercCompanyInsolvent(&gs, mc_solvent));
}

test "instantiateRivals: an insolvent merc company is not selected; a solvent one is" {
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 77 });
    defer gs.deinit();
    const alloc = gs.allocator();

    // Company A: has a roster with BV=432 (one LCT-1V) — insolvent (< 2000) and under strength.
    const mc_a: types.MercCompanyId = @enumFromInt(1);
    const mc_b: types.MercCompanyId = @enumFromInt(2);

    const band = merc_band.find("band_4").?;
    try gs.merc_companies.put(alloc, mc_a, merc_company_mod.MercCompany{
        .id = mc_a,
        .archetype_key = "enemy_raiders",
        .commander_first = "Bad",
        .commander_last = "Luck",
        .unit_name = "Bad Luck Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
        .band_key = band.key,
    });
    const ha: types.HullInstanceId = @enumFromInt(20);
    try gs.hull_instances.put(alloc, ha, .{ .id = ha, .base_key = "LCT-1V" }); // BV=432
    var ra: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    try ra.append(alloc, ha);
    try gs.merc_company_rosters.put(alloc, mc_a, ra);

    // Company B: holds its band's line target — solvent and at full strength (eligible).
    // Use LCT-1V for each hull; total BV = 432 per hull (well above 2000).
    try gs.merc_companies.put(alloc, mc_b, merc_company_mod.MercCompany{
        .id = mc_b,
        .archetype_key = "enemy_raiders",
        .commander_first = "Good",
        .commander_last = "Fortune",
        .unit_name = "Fortune Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .cautious,
        .band_key = band.key,
    });
    var rb: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
    for (0..merc_band.lineTarget(band)) |i| {
        const hb: types.HullInstanceId = @enumFromInt(21 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(alloc, hb, .{ .id = hb, .base_key = "LCT-1V" });
        try rb.append(alloc, hb);
    }
    try gs.merc_company_rosters.put(alloc, mc_b, rb);

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
    try instantiateRivals(&gs, &c, 1);

    // Every attached rival must link to the eligible company (B), never the insolvent one (A).
    try std.testing.expect(gs.rivals.count() > 0);
    var it = gs.rivals.iterator();
    while (it.next()) |entry| {
        const rv = entry.value_ptr;
        try std.testing.expect(rv.merc_company_id != mc_a);
        try std.testing.expectEqual(mc_b, rv.merc_company_id);
    }
}

test "mercCompanyEligibleAsOpFor: active+band-target=true; dissolved=false; insolvent=false; under-strength=false" {
    // Rule 20/67: focused table test for the single OpFor eligibility owner.
    const a = std.testing.allocator;
    var gs = GameState.init(a, .{ .seed = 42 });
    defer gs.deinit();
    const alloc = gs.allocator();

    const band = merc_band.find("band_4").?;
    const n = merc_band.lineTarget(band);
    try std.testing.expectEqual(@as(usize, 16), n);

    // mc_active_full: dissolved_day==0, solvent, n active meks → eligible.
    const mc_full: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(alloc, mc_full, merc_company_mod.MercCompany{
        .id = mc_full,
        .archetype_key = "enemy_raiders",
        .unit_name = "Full Company",
        .faction_key = "DC",
        .dissolved_day = 0,
        .band_key = band.key,
    });
    {
        var r: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..n) |i| {
            const hid: types.HullInstanceId = @enumFromInt(100 + @as(u32, @intCast(i)));
            try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V" });
            try r.append(alloc, hid);
        }
        try gs.merc_company_rosters.put(alloc, mc_full, r);
    }
    try std.testing.expect(mercCompanyEligibleAsOpFor(&gs, mc_full));

    // mc_dissolved: dissolved_day != 0 → ineligible.
    const mc_dissolved: types.MercCompanyId = @enumFromInt(2);
    try gs.merc_companies.put(alloc, mc_dissolved, merc_company_mod.MercCompany{
        .id = mc_dissolved,
        .archetype_key = "enemy_raiders",
        .unit_name = "Dissolved Co",
        .faction_key = "DC",
        .dissolved_day = 30,
        .band_key = band.key,
    });
    {
        var r: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..n) |i| {
            const hid: types.HullInstanceId = @enumFromInt(200 + @as(u32, @intCast(i)));
            try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V" });
            try r.append(alloc, hid);
        }
        try gs.merc_company_rosters.put(alloc, mc_dissolved, r);
    }
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, mc_dissolved));

    // mc_insolvent: has a roster but BV < threshold → insolvent → ineligible.
    const mc_insolvent: types.MercCompanyId = @enumFromInt(3);
    try gs.merc_companies.put(alloc, mc_insolvent, merc_company_mod.MercCompany{
        .id = mc_insolvent,
        .archetype_key = "enemy_raiders",
        .unit_name = "Insolvent Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .band_key = band.key,
    });
    {
        // One hull with LCT-1V (BV=432) — well below insolvency threshold 2000.
        const hid: types.HullInstanceId = @enumFromInt(300);
        try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V" });
        var r: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        try r.append(alloc, hid);
        try gs.merc_company_rosters.put(alloc, mc_insolvent, r);
    }
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, mc_insolvent));

    // mc_under: active, solvent, but n-1 active meks → under-strength → ineligible.
    const mc_under: types.MercCompanyId = @enumFromInt(4);
    try gs.merc_companies.put(alloc, mc_under, merc_company_mod.MercCompany{
        .id = mc_under,
        .archetype_key = "enemy_raiders",
        .unit_name = "Under Strength Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .band_key = band.key,
    });
    {
        // n-1 meks: solvent but under-strength.
        var r: std.ArrayListUnmanaged(types.HullInstanceId) = .empty;
        for (0..n - 1) |i| {
            const hid: types.HullInstanceId = @enumFromInt(400 + @as(u32, @intCast(i)));
            try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V" });
            try r.append(alloc, hid);
        }
        try gs.merc_company_rosters.put(alloc, mc_under, r);
    }
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, mc_under));

    // n-1 meks plus a vehicle and an aerospace hull: still n-1 meks → ineligible.
    {
        const r = gs.merc_company_rosters.getPtr(mc_under).?;
        for ([_][]const u8{ "SCP-1N", "TR-7" }, 0..) |key, i| {
            const hid: types.HullInstanceId = @enumFromInt(450 + @as(u32, @intCast(i)));
            try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = key });
            try r.append(alloc, hid);
        }
    }
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, mc_under));

    // The nth mek reaches the band target → eligible.
    {
        const hid: types.HullInstanceId = @enumFromInt(499);
        try gs.hull_instances.put(alloc, hid, .{ .id = hid, .base_key = "LCT-1V" });
        try gs.merc_company_rosters.getPtr(mc_under).?.append(alloc, hid);
    }
    try std.testing.expect(mercCompanyEligibleAsOpFor(&gs, mc_under));

    // mc_absent: active, no roster entry → under-strength → ineligible (rule 1).
    const mc_absent: types.MercCompanyId = @enumFromInt(5);
    try gs.merc_companies.put(alloc, mc_absent, merc_company_mod.MercCompany{
        .id = mc_absent,
        .archetype_key = "enemy_raiders",
        .unit_name = "Absent Roster Co",
        .faction_key = "DC",
        .dissolved_day = 0,
        .band_key = band.key,
    });
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, mc_absent));

    // A full roster under a key that names no band has no target → ineligible.
    gs.merc_companies.getPtr(mc_full).?.band_key = "band_6";
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, mc_full));
    try std.testing.expectError(error.CorruptSave, mercCompanyBand(gs.merc_companies.get(mc_full).?));
}

test "mercCompanyNeedsHull: meks fill the band target; vehicles only in a band that fills the line with them" {
    // Two bands that differ only in vehicle substitution (§L8, D23).
    const fills: merc_band.Band = .{ .key = "fills", .label = "fills", .seed_companies = 1, .line_lances = 4, .capital_cbills = 1, .vehicles_fill_line = true };
    const meks_only: merc_band.Band = .{ .key = "meks_only", .label = "meks only", .seed_companies = 1, .line_lances = 4, .capital_cbills = 1, .vehicles_fill_line = false };
    const air_target = @as(usize, tuning.generation.merc_company_air_reserve_lances) * force.lance_size;
    for ([_]*const merc_band.Band{ &fills, &meks_only }) |band| {
        try std.testing.expectEqual(@as(usize, 16), merc_band.lineTarget(band));
        // A mek is wanted at 15 meks, not at 16.
        try std.testing.expect(mercCompanyNeedsHull(band, .{ .meks = 15 }, .mek));
        try std.testing.expect(!mercCompanyNeedsHull(band, .{ .meks = 16 }, .mek));
        // A vehicle fills meks + vehicles = 15 only where the band allows it.
        try std.testing.expectEqual(band.vehicles_fill_line, mercCompanyNeedsHull(band, .{ .meks = 10, .vehicles = 5 }, .vehicle));
        try std.testing.expect(!mercCompanyNeedsHull(band, .{ .meks = 10, .vehicles = 6 }, .vehicle));
        // Aerospace is wanted below the unchanged air reserve in both.
        try std.testing.expect(mercCompanyNeedsHull(band, .{ .meks = 16, .aerospace = air_target - 1 }, .aerospace));
        try std.testing.expect(!mercCompanyNeedsHull(band, .{ .meks = 16, .aerospace = air_target }, .aerospace));
        // No other kind is procured.
        try std.testing.expect(!mercCompanyNeedsHull(band, .{}, .infantry));
    }
    try std.testing.expect(!mercCompanyNeedsHull(&meks_only, .{}, .vehicle));
}

test "mercCompanyEligibleAsOpFor: conventional BV does not satisfy the active-mek target" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 43 });
    defer gs.deinit();
    const id: types.MercCompanyId = @enumFromInt(1);
    const band = merc_band.find("band_3").?;
    try gs.merc_companies.put(gs.allocator(), id, .{ .id = id, .archetype_key = "enemy_raiders", .unit_name = "Reserve Co", .faction_key = "DC", .band_key = band.key });
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    for (0..merc_band.lineTarget(band)) |i| {
        const hull_id: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = "SCP-1N" });
        try roster.append(gs.allocator(), hull_id);
    }
    try gs.merc_company_rosters.put(gs.allocator(), id, roster);
    try std.testing.expect(mercCompanyFieldableBv(&gs, id) > 0);
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, id));
    for (roster.items) |hull_id| gs.hull_instances.getPtr(hull_id).?.base_key = "LCT-1V";
    try std.testing.expect(mercCompanyEligibleAsOpFor(&gs, id));
}

test "mercCompanyUnderstrength agrees with OpFor readiness at 15 and 16 meks; vehicles and fighters never count" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 44 });
    defer gs.deinit();
    const id: types.MercCompanyId = @enumFromInt(1);
    const band = merc_band.find("band_3").?;
    try std.testing.expectEqual(@as(usize, 16), merc_band.lineTarget(band));
    try gs.merc_companies.put(gs.allocator(), id, .{ .id = id, .archetype_key = "enemy_raiders", .unit_name = "Line Co", .faction_key = "DC", .band_key = band.key });
    var roster = std.ArrayListUnmanaged(types.HullInstanceId).empty;
    // 15 meks plus a vehicle and a fighter: one mek short, whatever else it holds.
    for (0..17) |i| {
        const hull_id: types.HullInstanceId = @enumFromInt(1 + @as(u32, @intCast(i)));
        const key = if (i < 15) "LCT-1V" else if (i == 15) "SCP-1N" else "TR-7";
        try gs.hull_instances.put(gs.allocator(), hull_id, .{ .id = hull_id, .base_key = key });
        try roster.append(gs.allocator(), hull_id);
    }
    try gs.merc_company_rosters.put(gs.allocator(), id, roster);
    try std.testing.expect(mercCompanyUnderstrength(band, mercCompanyHullCounts(&gs, id)));
    try std.testing.expect(!mercCompanyEligibleAsOpFor(&gs, id));
    try std.testing.expect(mercCompanyUnderstrength(band, .{ .meks = 15, .vehicles = 16, .aerospace = 16 }));

    // The 16th mek reaches the line: both owners flip together.
    const sixteenth: types.HullInstanceId = @enumFromInt(18);
    try gs.hull_instances.put(gs.allocator(), sixteenth, .{ .id = sixteenth, .base_key = "LCT-1V" });
    try gs.merc_company_rosters.getPtr(id).?.append(gs.allocator(), sixteenth);
    try std.testing.expect(!mercCompanyUnderstrength(band, mercCompanyHullCounts(&gs, id)));
    try std.testing.expect(mercCompanyEligibleAsOpFor(&gs, id));
}

test "mercCompanyCommitted: only a rival naming the company on a running contract commits it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 45 });
    defer gs.deinit();
    const alloc = gs.allocator();
    const company: types.MercCompanyId = @enumFromInt(1);
    const other: types.MercCompanyId = @enumFromInt(2);
    const contract_id: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(alloc, contract_id, .{
        .id = contract_id,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
    });
    try gs.rivals.put(alloc, @enumFromInt(1), .{ .id = @enumFromInt(1), .contract = contract_id, .merc_company_id = company });
    try gs.rivals.put(alloc, @enumFromInt(2), .{ .id = @enumFromInt(2), .contract = contract_id, .merc_company_id = .none });

    // Not running: offered, accepted, closed.
    for ([_]contract_mod.ContractStatus{ .offer, .accepted, .completed, .breached, .failed }) |status| {
        gs.contracts.getPtr(contract_id).?.status = status;
        try std.testing.expect(!mercCompanyCommitted(&gs, company));
    }
    // Running: in transit or active.
    for ([_]contract_mod.ContractStatus{ .transit, .active }) |status| {
        gs.contracts.getPtr(contract_id).?.status = status;
        try std.testing.expect(mercCompanyCommitted(&gs, company));
        // A rival naming another company, or none, commits nobody else.
        try std.testing.expect(!mercCompanyCommitted(&gs, other));
        try std.testing.expect(!mercCompanyCommitted(&gs, .none));
    }
    // A rival whose contract is gone commits nothing.
    gs.rivals.getPtr(@enumFromInt(1)).?.contract = @enumFromInt(9);
    try std.testing.expect(!mercCompanyCommitted(&gs, company));
}
