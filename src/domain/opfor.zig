//! Opposing forces (Stage 12D.5). Adaptation of AtB's OpFor generation (MekHQ
//! `AtBScenario`/`AtBDynamicScenarioFactory` force generation, abridged):
//! the enemy on a contract is a force of its own — a number of lances off
//! the enemy house's RAT at a rolled skill level — rolled when the offer is
//! posted, so the board can show what you would be walking into. A weak
//! company taking a planetary assault meets a planetary assault.
//! Data in data/tables/opfor.zon.

const std = @import("std");
const types = @import("types.zig");
const chassis = @import("chassis.zig");
const contract = @import("contract.zig");
const rat = @import("rat.zig");
const rng_mod = @import("../sim/rng.zig");
const tuning = @import("tuning.zig").t;
const autoresolve = @import("autoresolve.zig");

pub const KindRow = struct { kind: []const u8, lances_min: u8, lances_max: u8, quality_mod: i8 };

pub const Table = struct {
    by_kind: []const KindRow,
    lance_size: u8,
    pirate_quality_mod: i8,
    green_max: u8,
    regular_max: u8,
    veteran_max: u8,
    reinforcement_bp_per_month: types.Bp,
    reinforcement_months_cap: u8,
};

pub const table: Table = @import("opfor_zon");

pub fn rowFor(kind: contract.ContractKind) KindRow {
    for (table.by_kind) |r| if (std.mem.eql(u8, r.kind, @tagName(kind))) return r;
    return .{ .kind = @tagName(kind), .lances_min = 3, .lances_max = 4, .quality_mod = 0 };
}

/// What was rolled for a contract's opposition.
pub const Force = struct {
    lances: u8,
    quality: types.ExperienceLevel,
    /// Summed BV of one representative lance off the house's RAT.
    lance_bv: i64,
    /// Its tonnage: shown beside the skulls.
    lance_tons: u32 = 0,

    pub fn bv(self: Force) i64 {
        return self.lance_bv * self.lances;
    }
};

/// Gunnery/piloting by the enemy's skill level (AtB: green 5/6, regular
/// 4/5, veteran 3/4, elite 2/3).
pub fn skills(q: types.ExperienceLevel) [2]u8 {
    return switch (q) {
        .green => .{ 5, 6 },
        .regular => .{ 4, 5 },
        .veteran => .{ 3, 4 },
        .elite => .{ 2, 3 },
    };
}

pub fn qualityFromRoll(r: i32) types.ExperienceLevel {
    if (r <= table.green_max) return .green;
    if (r <= table.regular_max) return .regular;
    if (r <= table.veteran_max) return .veteran;
    return .elite;
}

/// AtB weight-class roll (2d6) on a named stream.
pub fn weightClass(rng: *rng_mod.Rng, stream: rng_mod.Stream) chassis.WeightClass {
    return switch (rng.roll2d6(stream)) {
        2, 3, 4 => .light,
        5, 6, 7, 8 => .medium,
        9, 10, 11 => .heavy,
        else => .assault,
    };
}

/// Roll the opposition for a contract: lances by kind, quality on 2d6,
/// and one lance's BV off the enemy house's RAT in the campaign year.
pub fn roll(rng: *rng_mod.Rng, stream: rng_mod.Stream, kind: contract.ContractKind, enemy_key: []const u8, year: u16) Force {
    const row = rowFor(kind);
    const lances = rng.random(stream).intRangeAtMost(u8, row.lances_min, @max(row.lances_min, row.lances_max));
    const pirates = std.mem.eql(u8, enemy_key, "PER");
    const q = qualityFromRoll(@as(i32, rng.roll2d6(stream)) + row.quality_mod + (if (pirates) table.pirate_quality_mod else 0));
    var lance_bv: i64 = 0;
    var lance_tons: u32 = 0;
    for (0..table.lance_size) |_| {
        const d = rat.roll(rng, stream, enemy_key, weightClass(rng, stream), year);
        lance_bv += d.bv;
        lance_tons += d.tonnage;
    }
    return .{ .lances = lances, .quality = q, .lance_bv = lance_bv, .lance_tons = lance_tons };
}

/// The pool an attrition contract grinds down: the force plus its
/// reinforcements over the term.
pub fn poolBv(force_bv: i64, length_months: u8) i64 {
    const months: types.Bp = @min(length_months, table.reinforcement_months_cap);
    return types.applyBp(force_bv, 10_000 + table.reinforcement_bp_per_month * months);
}

/// B1 (docs/p3c-economy-design.md §8.E): number of OpFor hulls to draw from the
/// filtered pool. For a garrison probe, cap at one lance; otherwise scale by
/// the contract's enemy lance count (floored at 1).
pub fn drawSize(pool_len: usize, enemy_lances: u8, garrison_probe: bool) usize {
    const lances: usize = if (garrison_probe) 1 else @max(1, enemy_lances);
    return @min(pool_len, lances * table.lance_size);
}

/// Per-hull engagement outcome for a drawn OpFor hull (docs/p3c-economy-design.md §8.E).
/// combat_ineffective is an engagement outcome, NOT a HullStatus member;
/// HullStatus stays { active, permanently_destroyed } — no new member.
pub const OpforHullOutcome = enum { destroyed, combat_ineffective, surviving };

/// Draw one outcome for a drawn OpFor hull on the given stream, keyed on the
/// engagement outcome band (docs/p3c-economy-design.md §8.E).
/// One .battle draw: uintLessThan(u8, 100).
pub fn hullOutcome(rng: *rng_mod.Rng, stream: rng_mod.Stream, outcome: autoresolve.Outcome) OpforHullOutcome {
    // Extract the two thresholds for this band. Each opfor_outcome field is an
    // anonymous struct of the same shape; use inline else to index by tag name
    // and extract each u8 field (avoids nominal-type mismatch across branches).
    const destroyed_pct: u8 = switch (outcome) {
        inline else => |o| @field(tuning.battle.opfor_outcome, @tagName(o)).destroyed_pct,
    };
    const ineffective_pct: u8 = switch (outcome) {
        inline else => |o| @field(tuning.battle.opfor_outcome, @tagName(o)).ineffective_pct,
    };
    const pct_roll = rng.random(stream).uintLessThan(u8, 100);
    if (pct_roll < destroyed_pct) return .destroyed;
    if (pct_roll < destroyed_pct + ineffective_pct) return .combat_ineffective;
    return .surviving;
}

test "drawSize: B1 formula — non-garrison scales lances, garrison caps at one lance, pool_len clamp, lances floor" {
    // Non-garrison: pool_len large enough, result = lances * lance_size.
    try std.testing.expectEqual(@as(usize, 2 * table.lance_size), drawSize(100, 2, false));
    // Lances floored at 1 when enemy_lances == 0.
    try std.testing.expectEqual(@as(usize, 1 * table.lance_size), drawSize(100, 0, false));
    // Garrison probe caps at 1 lance regardless of enemy_lances.
    try std.testing.expectEqual(@as(usize, 1 * table.lance_size), drawSize(100, 3, true));
    // pool_len clamp: smaller pool wins.
    try std.testing.expectEqual(@as(usize, 2), drawSize(2, 4, false));
    // Garrison probe also clamped by pool.
    try std.testing.expectEqual(@as(usize, 1), drawSize(1, 3, true));
}

test "hullOutcome: each outcome is one of three; tuning bands are well-formed" {
    // Verify each tuning band has destroyed_pct + ineffective_pct <= 100 and
    // destroyed_pct non-increasing from decisive_victory to rout.
    const bands = tuning.battle.opfor_outcome;
    const ordered = [_]struct { d: u8, i: u8 }{
        .{ .d = bands.decisive_victory.destroyed_pct, .i = bands.decisive_victory.ineffective_pct },
        .{ .d = bands.victory.destroyed_pct, .i = bands.victory.ineffective_pct },
        .{ .d = bands.draw.destroyed_pct, .i = bands.draw.ineffective_pct },
        .{ .d = bands.defeat.destroyed_pct, .i = bands.defeat.ineffective_pct },
        .{ .d = bands.rout.destroyed_pct, .i = bands.rout.ineffective_pct },
    };
    for (ordered) |b| try std.testing.expect(@as(u16, b.d) + b.i <= 100);
    for (1..ordered.len) |j| try std.testing.expect(ordered[j].d <= ordered[j - 1].d);
    // Every outcome is one of three.
    var rng = rng_mod.Rng.init(42);
    inline for (@typeInfo(autoresolve.Outcome).@"enum".fields) |f| {
        const oc: autoresolve.Outcome = @enumFromInt(f.value);
        const result = hullOutcome(&rng, .battle, oc);
        try std.testing.expect(result == .destroyed or result == .combat_ineffective or result == .surviving);
    }
}

test "data: every contract kind has an opfor row and rolls within it" {
    inline for (@typeInfo(contract.ContractKind).@"enum".fields) |f| {
        var found = false;
        for (table.by_kind) |r| if (std.mem.eql(u8, r.kind, f.name)) {
            found = true;
            try std.testing.expect(r.lances_min >= 1 and r.lances_min <= r.lances_max);
        };
        try std.testing.expect(found);
    }
    // Quality bands climb: green below regular below veteran (elite above).
    try std.testing.expect(table.green_max < table.regular_max and table.regular_max < table.veteran_max);
    var rng = rng_mod.Rng.init(125);
    for (0..50) |_| {
        const f = roll(&rng, .market, .planetary_assault, "DC", 3025);
        try std.testing.expect(f.lances >= 4 and f.lances <= 5);
        try std.testing.expect(f.lance_bv > 0);
    }
    // Pirates skew green.
    var green: u32 = 0;
    for (0..200) |_| {
        if (roll(&rng, .market, .pirate_hunting, "PER", 3025).quality == .green) green += 1;
    }
    try std.testing.expect(green > 80);
    try std.testing.expect(poolBv(10_000, 12) == poolBv(10_000, 6));
    try std.testing.expect(poolBv(10_000, 2) < poolBv(10_000, 6));
}
