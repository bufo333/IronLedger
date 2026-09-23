//! Shared primitive types: typed IDs, money, core enums.
//! See ARCHITECTURE.md §5.

const std = @import("std");

/// All money is integer C-bills. No floats in the ledger, ever.
pub const CBills = i64;

/// Basis points (1/100 of a percent) for all multiplier math, so payment
/// formulas stay in integer arithmetic. 10_000 bp == ×1.0.
pub const Bp = i64;

/// ×1.0 in basis points: the whole of something (full severance, no
/// multiplier).
pub const full_bp: Bp = 10_000;

/// "×1.47": a basis-point multiplier as the screens print it.
pub fn bpText(buf: []u8, bp: Bp) []const u8 {
    const whole: u32 = @intCast(@divTrunc(bp, full_bp));
    const frac: u32 = @intCast(@divTrunc(@mod(bp, full_bp), 100));
    return std.fmt.bufPrint(buf, "×{d}.{d:0>2}", .{ whole, frac }) catch "×?";
}

/// Basis points as a whole percentage (3_000 → 30).
pub fn bpPercent(bp: Bp) i64 {
    return @divTrunc(bp, 100);
}

/// The campaign calendar's arithmetic months and years (the rendered date
/// follows the real calendar; tenure, terms and ages count in these).
pub const days_per_month: u32 = 30;
pub const days_per_year: u32 = 365;

pub fn applyBp(amount: CBills, bp: Bp) CBills {
    return @divTrunc(amount * bp, 10_000);
}

// Typed IDs: non-exhaustive enums over u32 — copyable, comparable, and
// impossible to pass a PersonId where a UnitId is expected.
pub const PersonId = enum(u32) { none = 0, _ };
pub const UnitId = enum(u32) { none = 0, _ };
pub const ForceId = enum(u32) { none = 0, _ };
pub const ContractId = enum(u32) { none = 0, _ };
pub const HqId = enum(u32) { none = 0, _ };
/// One queued inbox event (Stage 12G.1). The inbox is answered by id, not
/// by row: resolving one event shifts every index after it.
pub const EventId = enum(u32) { none = 0, _ };
/// One resolved engagement (Stage 12G.3): the grouping key the campaign
/// log never had, so an AAR's lines can be gathered without reading its
/// prose.
pub const BattleId = enum(u32) { none = 0, _ };

/// Skill catalog, following MekHQ's SkillType. Lower level = better
/// (target-number convention: a 3/4 mekwarrior has gunnery 3, piloting 4).
pub const SkillType = enum {
    gunnery_mek,
    piloting_mek,
    gunnery_vee,
    driving_vee,
    gunnery_aero,
    piloting_aero,
    anti_mek,
    small_arms,
    tech_mek,
    tech_mechanic,
    tech_aero,
    tech_ba,
    astech,
    doctor,
    medtech,
    admin,
    negotiation,
    leadership,
    tactics,
    strategy,
};

/// Green/Regular/Veteran/Elite, as in MekHQ.
pub const ExperienceLevel = enum(u8) {
    green = 0,
    regular = 1,
    veteran = 2,
    elite = 3,

    /// Derive from combined gunnery+piloting (or the tech/support analog).
    /// Approximation of MekHQ's mapping; refine in Stage 2.
    pub fn fromCombatSkills(gunnery: u8, piloting: u8) ExperienceLevel {
        const total: u16 = @as(u16, gunnery) + piloting;
        if (total <= 5) return .elite;
        if (total <= 7) return .veteran;
        if (total <= 9) return .regular;
        return .green;
    }

    /// CamOps salary multiplier, in basis points (MekHQ defaults).
    pub fn salaryMultBp(self: ExperienceLevel) Bp {
        return switch (self) {
            .green => 6_000, // ×0.6
            .regular => 10_000, // ×1.0
            .veteran => 16_000, // ×1.6
            .elite => 32_000, // ×3.2
        };
    }
};

/// Part & unit quality grades, CamOps A (worst) .. F (best) as used by MekHQ
/// maintenance rules.
pub const Quality = enum(u8) {
    a = 0,
    b = 1,
    c = 2,
    d = 3,
    e = 4,
    f = 5,

    /// Maintenance target-number modifier (MekHQ: A=+3 .. F=-2).
    pub fn maintenanceModifier(self: Quality) i8 {
        return switch (self) {
            .a => 3,
            .b => 2,
            .c => 1,
            .d => 0,
            .e => -1,
            .f => -2,
        };
    }
};

pub const SupplyClass = enum { parts, ammo, medical, provisions, personnel };

/// How a salvage claim is spent (12G.6). The haul is a BV budget and the
/// wrecks on offer cost BV, so the commander is trading one heavy hull
/// against several light ones against a crate of spares.
pub const SalvagePlan = enum { heaviest, most_hulls, parts_only };

/// Where physical stock sits (Stage 9B): the outfit's fallback depot (no HQ
/// yet), an HQ warehouse, or a deployed company's field stores (which
/// travel with it, capped by its logistics trucks).
pub const Site = union(enum) {
    outfit,
    hq: HqId,
    company: ForceId,
};

/// Market rarity tiers (ARCH §9.8): how often an item appears in a site
/// market's refresh. Lives here (not econ/) so chassis/part catalog data can
/// carry it.
pub const Rarity = enum {
    common,
    uncommon,
    rare,
    very_rare,

    /// 2d6 availability target per refresh roll (roll + modifiers ≥ target
    /// ⇒ the item appears).
    pub fn availabilityTarget(self: Rarity) u8 {
        const t = @import("tuning.zig").t.market.rarity_target;
        return switch (self) {
            .common => t.common,
            .uncommon => t.uncommon,
            .rare => t.rare,
            .very_rare => t.very_rare,
        };
    }
};

test "basis point math stays in integers" {
    try std.testing.expectEqual(@as(CBills, 1_500), applyBp(1_500, 10_000));
    try std.testing.expectEqual(@as(CBills, 900), applyBp(1_500, 6_000));
    try std.testing.expectEqual(@as(CBills, 4_800), applyBp(1_500, 32_000));
}

test "experience level derivation" {
    try std.testing.expectEqual(ExperienceLevel.elite, ExperienceLevel.fromCombatSkills(2, 3));
    try std.testing.expectEqual(ExperienceLevel.veteran, ExperienceLevel.fromCombatSkills(3, 4));
    try std.testing.expectEqual(ExperienceLevel.regular, ExperienceLevel.fromCombatSkills(4, 5));
    try std.testing.expectEqual(ExperienceLevel.green, ExperienceLevel.fromCombatSkills(5, 6));
}

test "one multiplier and one percent rendering for basis points" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("×1.47", bpText(&buf, 14_700));
    try std.testing.expectEqualStrings("×0.80", bpText(&buf, 8_000));
    try std.testing.expectEqual(@as(i64, 30), bpPercent(3_000));
}
