//! Conflicts: the persisted record of one political war over a world
//! (docs/p5d-conflict-world-design.md §C, P5d.1e). Who backs each side,
//! the §A timeline fixed at opening, the rolled defender and aggressor
//! forces, and the outcome once resolved; the status is derived from the
//! days. The pure rules every conflict obeys live here; opening,
//! progression and resolution are `sim/politics.zig`'s.
//! No MekHQ counterpart: MekHQ has no persistent political conflicts
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const tuning = @import("tuning.zig").t;
const opfor = @import("opfor.zig");

/// A party backing one side (§B "Power"): a faction and the personage acting
/// for it.
pub const Power = struct {
    /// A `factions.zon` key.
    faction_key: []const u8,
    personage: types.PersonageId,
};

/// A side's rolled force (§A "The opposing force is built from records").
pub const Force = opfor.Force;

/// How a resolved conflict ended. Persisted by tag name.
pub const Outcome = enum {
    aggressor_won,
    defender_held,
};

/// Where a conflict stands on a day (§A timeline). Derived by `status`,
/// never stored.
pub const Status = enum {
    /// Opened and secret: the defender does not know.
    preparing,
    /// Discovered: the defender knows a strike is coming.
    threatened,
    /// The strike has landed and the fighting runs.
    open,
    resolved,
};

pub const Conflict = struct {
    id: types.ConflictId,
    /// The `political_events.zon` row that opened it.
    template_key: []const u8,
    /// The `planets.zon` key of the world fought over.
    planet_key: []const u8,
    aggressor: Power,
    defender: Power,
    /// The personage whose scheme opened it: the aggressor's or the
    /// defender's personage, as its template's side names.
    instigator: types.PersonageId,
    /// The aggressor faction's world nearest the target, which the strike
    /// force leaves from (§A, D19).
    staging_planet_key: []const u8,
    /// The §A days: `opened_day < discovery_day < strike_day < expires_day`.
    opened_day: u32,
    discovery_day: u32,
    strike_day: u32,
    expires_day: u32,
    /// The defender's garrison, rolled at opening (§A local forces).
    local_force: Force,
    /// The aggressor's house force (§A, D19).
    strike_force: Force,
    /// Null until resolution.
    outcome: ?Outcome = null,
};

/// A conflict's status on `day` (§A timeline): `resolved` once it has an
/// outcome; otherwise `preparing` before `discovery_day`, `threatened`
/// before `strike_day`, and `open` from it. The one status owner.
pub fn status(c: *const Conflict, day: u32) Status {
    if (c.outcome != null) return .resolved;
    if (day < c.discovery_day) return .preparing;
    if (day < c.strike_day) return .threatened;
    return .open;
}

/// The aggressor's chance to win an NPC-only resolution, in basis points
/// (§C resolution; decision E4): `strike BV / (strike BV + local BV)` of
/// `types.full_bp`, rounded down. Certain when only the local force has no
/// BV, nil when only the strike force has none, and even when both have
/// none. Exact over every force a save holds (lance BV up to the i64
/// maximum, up to 255 lances): the sums are taken in i128, so no BV
/// overflows. Pure.
pub fn aggressorWinChanceBp(strike: Force, local: Force) types.Bp {
    const s = forceBv(strike);
    const l = forceBv(local);
    if (s == 0 and l == 0) return @divTrunc(types.full_bp, 2);
    return @intCast(@divTrunc(s * types.full_bp, s + l));
}

/// A force's whole BV, `Force.bv` widened to i128 so the largest saved
/// force (i64 maximum × 255 lances) and the chance's scaled sum fit.
/// Negative lance BV counts as none.
fn forceBv(f: Force) i128 {
    return @as(i128, @max(0, f.lance_bv)) * f.lances;
}

/// The day the defender learns of a conflict (§A discovery, D12; decision
/// E6): the earlier of the intelligence day, `opened + intel_lag −
/// chief_cut`, and the detection day, `strike − detection_lead_days`. All
/// in days; `chief_cut` is 0 without a defender intelligence chief. Pure.
pub fn discoveryDay(opened: u32, intel_lag: u32, chief_cut: u32, strike: u32) u32 {
    const intelligence = (opened + intel_lag) -| chief_cut;
    const detection = strike -| tuning.politics.detection_lead_days;
    return @min(intelligence, detection);
}

/// The defender's local-force lances (§A local forces): the rolled lances
/// plus one per `local_force_security_per_lance` points of world security,
/// toward zero, never below one. `security` is the world's
/// `world_states` security, 0 for a world without a row. Pure.
pub fn localForceLances(rolled: u8, security: i16) u8 {
    const per_lance: i32 = tuning.politics.local_force_security_per_lance;
    const lances: i32 = @as(i32, rolled) + @divTrunc(@as(i32, security), per_lance);
    return @intCast(std.math.clamp(lances, 1, std.math.maxInt(u8)));
}

// The timeline bounds every draw keeps: with these, `opened < discovery <
// strike < expires` holds for every conflict `politics.runSchemes` opens.
// A chance is a share of 10 000 bp and loyalty sits on the 1–100 scale.
comptime {
    const pol = tuning.politics;
    const file = "data/tables/tuning.zon: politics.";
    if (pol.scheme_prep_days_min > pol.scheme_prep_days_max) @compileError(file ++ "scheme_prep_days_min must not exceed scheme_prep_days_max");
    if (pol.intel_lag_days_min > pol.intel_lag_days_max) @compileError(file ++ "intel_lag_days_min must not exceed intel_lag_days_max");
    if (pol.fight_days_min > pol.fight_days_max) @compileError(file ++ "fight_days_min must not exceed fight_days_max");
    if (!(pol.scheme_prep_days_min > pol.detection_lead_days and pol.detection_lead_days >= 1))
        @compileError(file ++ "scheme_prep_days_min must exceed detection_lead_days, which must be at least 1");
    if (!(pol.intel_lag_days_min > pol.intel_chief_cut_days)) @compileError(file ++ "intel_lag_days_min must exceed intel_chief_cut_days");
    if (pol.fight_days_min < 1) @compileError(file ++ "fight_days_min must be at least 1");
    if (pol.local_force_security_per_lance == 0) @compileError(file ++ "local_force_security_per_lance must be positive");
    if (pol.secession_loyalty_max < 1 or pol.secession_loyalty_max > 100) @compileError(file ++ "secession_loyalty_max must lie in 1..100");
    if (pol.schemes_per_month < 1 or pol.max_open_conflicts < 1) @compileError(file ++ "schemes_per_month and max_open_conflicts must be positive");
}

test "status follows the days and the outcome" {
    var c: Conflict = .{
        .id = @enumFromInt(1),
        .template_key = "border_grab",
        .planet_key = "skye",
        .aggressor = .{ .faction_key = "FWL", .personage = @enumFromInt(1) },
        .defender = .{ .faction_key = "LC", .personage = @enumFromInt(2) },
        .instigator = @enumFromInt(1),
        .staging_planet_key = "atreus",
        .opened_day = 10,
        .discovery_day = 30,
        .strike_day = 50,
        .expires_day = 90,
        .local_force = .{ .lances = 1, .quality = .regular, .lance_bv = 1, .lance_tons = 1 },
        .strike_force = .{ .lances = 1, .quality = .regular, .lance_bv = 1, .lance_tons = 1 },
    };
    try std.testing.expectEqual(Status.preparing, status(&c, 10));
    try std.testing.expectEqual(Status.preparing, status(&c, 29));
    try std.testing.expectEqual(Status.threatened, status(&c, 30));
    try std.testing.expectEqual(Status.threatened, status(&c, 49));
    try std.testing.expectEqual(Status.open, status(&c, 50));
    try std.testing.expectEqual(Status.open, status(&c, 90));
    c.outcome = .defender_held;
    try std.testing.expectEqual(Status.resolved, status(&c, 10));
    try std.testing.expectEqual(Status.resolved, status(&c, 90));
}

test "the aggressor's chance is its share of the two forces' BV" {
    const lance = struct {
        fn of(lances: u8, bv: i64) Force {
            return .{ .lances = lances, .quality = .regular, .lance_bv = bv, .lance_tons = 0 };
        }
    }.of;
    try std.testing.expectEqual(@as(types.Bp, 5_000), aggressorWinChanceBp(lance(2, 3_000), lance(3, 2_000)));
    // 1 × 1 000 against 3 × 1 000: a quarter.
    try std.testing.expectEqual(@as(types.Bp, 2_500), aggressorWinChanceBp(lance(1, 1_000), lance(3, 1_000)));
    // Lopsided and rounded down: 1 000 against 2 000 is 3 333 bp.
    try std.testing.expectEqual(@as(types.Bp, 3_333), aggressorWinChanceBp(lance(1, 1_000), lance(1, 2_000)));
    try std.testing.expectEqual(types.full_bp, aggressorWinChanceBp(lance(2, 1_000), lance(1, 0)));
    try std.testing.expectEqual(@as(types.Bp, 0), aggressorWinChanceBp(lance(1, 0), lance(2, 1_000)));
    try std.testing.expectEqual(@divTrunc(types.full_bp, 2), aggressorWinChanceBp(lance(1, 0), lance(1, 0)));
}

test "the aggressor's chance keeps its ratio at the largest forces a save holds" {
    // Rules 25, 47: a save holds any lance BV from 0 to the i64 maximum and
    // 1–255 lances (the `conflict` table's checks).
    const max_bv = std.math.maxInt(i64);
    const max_lances = std.math.maxInt(u8);
    const lance = struct {
        fn of(lances: u8, bv: i64) Force {
            return .{ .lances = lances, .quality = .regular, .lance_bv = bv, .lance_tons = 0 };
        }
    }.of;
    try std.testing.expectEqual(@divTrunc(types.full_bp, 2), aggressorWinChanceBp(lance(max_lances, max_bv), lance(max_lances, max_bv)));
    try std.testing.expectEqual(@divTrunc(types.full_bp, 2), aggressorWinChanceBp(lance(1, max_bv), lance(1, max_bv)));
    // 255 equal lances against one: 255 / 256 of the whole, rounded down.
    try std.testing.expectEqual(@as(types.Bp, @divTrunc(max_lances * types.full_bp, max_lances + 1)), aggressorWinChanceBp(lance(max_lances, max_bv), lance(1, max_bv)));
    try std.testing.expectEqual(types.full_bp, aggressorWinChanceBp(lance(max_lances, max_bv), lance(max_lances, 0)));
    try std.testing.expectEqual(@as(types.Bp, 0), aggressorWinChanceBp(lance(max_lances, 0), lance(max_lances, max_bv)));
    // A one-BV strike against the largest local force is not certain loss
    // by overflow but a share that rounds down to nil.
    try std.testing.expectEqual(@as(types.Bp, 0), aggressorWinChanceBp(lance(1, 1), lance(max_lances, max_bv)));
}

test "discovery is the earlier of intelligence and detection, and an intelligence chief brings it forward" {
    const lead = tuning.politics.detection_lead_days;
    const cut = tuning.politics.intel_chief_cut_days;
    // Intelligence wins: 100 + 20 is before 200 − lead.
    try std.testing.expectEqual(@as(u32, 120), discoveryDay(100, 20, 0, 200));
    // Detection wins: 100 + 90 is after 150 − lead.
    try std.testing.expectEqual(@as(u32, 150 - lead), discoveryDay(100, 90, 0, 150));
    // Rule 71: one plan, with and without a chief on the defender's side.
    // The chief's side learns `intel_chief_cut_days` sooner while
    // intelligence wins, and no sooner once detection already does.
    const without = discoveryDay(100, 20, 0, 200);
    const with = discoveryDay(100, 20, cut, 200);
    try std.testing.expectEqual(without - cut, with);
    try std.testing.expectEqual(discoveryDay(100, 90, 0, 150), discoveryDay(100, 90 + cut, cut, 150));
}

test "the local force gains a lance per security step, toward zero, and keeps at least one" {
    const per: i16 = @intCast(tuning.politics.local_force_security_per_lance);
    try std.testing.expectEqual(@as(u8, 3), localForceLances(3, 0));
    try std.testing.expectEqual(@as(u8, 3), localForceLances(3, per - 1));
    try std.testing.expectEqual(@as(u8, 4), localForceLances(3, per));
    try std.testing.expectEqual(@as(u8, 3), localForceLances(3, -(per - 1)));
    // The world-state range is ±100 (`world_state.world_min`, `world_max`).
    try std.testing.expectEqual(@as(u8, 3 + @as(u8, @intCast(@divTrunc(100, per)))), localForceLances(3, 100));
    try std.testing.expectEqual(@as(u8, @intCast(@max(1, 3 - @divTrunc(100, per)))), localForceLances(3, -100));
    try std.testing.expectEqual(@as(u8, 1), localForceLances(1, -100));
    try std.testing.expectEqual(@as(u8, 1), localForceLances(1, 0));
}
