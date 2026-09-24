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

test "every contract kind has an opfor row and rolls within it" {
    inline for (@typeInfo(contract.ContractKind).@"enum".fields) |f| {
        var found = false;
        for (table.by_kind) |r| if (std.mem.eql(u8, r.kind, f.name)) {
            found = true;
            try std.testing.expect(r.lances_min >= 1 and r.lances_min <= r.lances_max);
        };
        try std.testing.expect(found);
    }
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
