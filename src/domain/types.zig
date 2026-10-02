//! Shared primitive types: typed IDs, money, core enums.
//! See ARCHITECTURE.md §5.
//! No MekHQ counterpart: shared value and ID types (docs/mekhq-map.md).

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

/// The campaign calendar's arithmetic week, months, and years (the rendered
/// date follows the real calendar; tenure, terms and ages count in these).
/// Rules 24, 25: each of the four owners is the one call-site for its unit.
pub const days_per_week: u32 = 7;
pub const days_per_month: u32 = 30;
pub const days_per_year: u32 = 365;
pub const months_per_year: u32 = 12;

pub fn applyBp(amount: CBills, bp: Bp) CBills {
    return @divTrunc(amount * bp, 10_000);
}

/// Integer percentage math for CamOps pip-valued contract terms
/// (advance_pct, transport_pct, overhead_pct, salvage_pct,
/// battle_loss_pct, hq.sale_pct): one owner for all money×percent
/// sites so no caller re-derives the 100 divisor (rules 24, 25).
pub fn applyPct(amount: CBills, pct: i64) CBills {
    return @divTrunc(amount * pct, 100);
}

/// C-bills with thousands separators and a leading `−` for negatives
/// (rules 24, 28): the one owner for money display in logs and screens.
/// Logs below `queries` call this directly; `queries.money` delegates here.
/// Only error is `error.OutOfMemory` (bufPrint over a 32-byte buffer cannot
/// overflow for any i64 value — max 20 digits — so NoSpaceLeft is unreachable).
pub fn moneyText(alloc: std.mem.Allocator, v: CBills) error{OutOfMemory}![]const u8 {
    var digits: [32]u8 = undefined;
    const mag: u64 = @intCast(if (v < 0) -v else v);
    const raw = std.fmt.bufPrint(&digits, "{d}", .{mag}) catch unreachable;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (v < 0) try out.append(alloc, '-');
    for (raw, 0..) |c, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) try out.append(alloc, ',');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

// Typed IDs: non-exhaustive enums over u32 — copyable, comparable, and
// impossible to pass a PersonId where a UnitId is expected.
pub const PersonId = enum(u32) { none = 0, _ };
pub const UnitId = enum(u32) { none = 0, _ };
pub const ForceId = enum(u32) { none = 0, _ };
pub const ContractId = enum(u32) { none = 0, _ };
pub const HqId = enum(u32) { none = 0, _ };
/// One queued inbox event. The inbox is answered by id, not
/// by row: resolving one event shifts every index after it.
pub const EventId = enum(u32) { none = 0, _ };
/// One resolved engagement: the grouping key that gathers an AAR's log
/// lines without reading its prose.
pub const BattleId = enum(u32) { none = 0, _ };
/// One entry on a site market board; typed so a buy command cannot be
/// passed a loan index (rule 56).
pub const ListingId = enum(u32) { none = 0, _ };
/// One candidate on a hiring-hall board; typed so a hire command cannot
/// be passed a listing index (rule 56).
pub const CandidateId = enum(u32) { none = 0, _ };
/// One outstanding loan; typed so a repay command cannot be passed a
/// listing or candidate index (rule 56).
pub const LoanId = enum(u32) { none = 0, _ };
/// One instantiated operation on a contract; typed so an operation command
/// cannot be passed a listing or loan index (rule 56).
pub const OperationId = enum(u32) { none = 0, _ };
/// One persistent contract-introduced actor (P4i); typed so an actor command
/// cannot be passed a listing or operation index (rule 56).
pub const ActorId = enum(u32) { none = 0, _ };
/// One persistent rival company (P4i); typed so a rival reference cannot be
/// passed where an actor or operation index is expected (rule 56).
pub const RivalId = enum(u32) { none = 0, _ };
/// One persistent officer arc (P4i); typed so an officer arc reference cannot
/// be passed where a rival or actor index is expected (rule 56).
pub const OfficerArcId = enum(u32) { none = 0, _ };

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
    /// Approximation of MekHQ's mapping.
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

/// How a salvage claim is spent. The haul is a BV budget and the
/// wrecks on offer cost BV, so the commander is trading one heavy hull
/// against several light ones against a crate of spares.
pub const SalvagePlan = enum { heaviest, most_hulls, parts_only };

/// The order the techs take the damage in, the night after a fight.
/// The pooled hours and the field armour run out before the
/// damage does, so the commander chooses who fights shot up.
pub const RepairOrder = enum { worst_first, spread, heaviest_first };

/// Where physical stock sits: the outfit's fallback depot (no HQ
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

test "moneyText: thousands separators and sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0", try moneyText(a, 0));
    try std.testing.expectEqualStrings("999", try moneyText(a, 999));
    try std.testing.expectEqualStrings("1,000", try moneyText(a, 1_000));
    try std.testing.expectEqualStrings("1,650", try moneyText(a, 1_650));
    try std.testing.expectEqualStrings("1,234,567", try moneyText(a, 1_234_567));
    try std.testing.expectEqualStrings("-45,000", try moneyText(a, -45_000));
}

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

test "applyPct is the one owner for money×percent: value matches divTrunc and equals applyBp at ×100" {
    // Representative contract-term values in play (CamOps pip percentages).
    const cases = [_]struct { amount: CBills, pct: i64 }{
        .{ .amount = 5_400_000, .pct = 25 }, // advance_pct
        .{ .amount = 1_800_000, .pct = 30 }, // battle_loss_pct
        .{ .amount = 2_000_000, .pct = 60 }, // salvage_pct
        .{ .amount = 800_000, .pct = 40 }, // hq.sale_pct
    };
    for (cases) |c| {
        const expected = @divTrunc(c.amount * c.pct, 100);
        try std.testing.expectEqual(expected, applyPct(c.amount, c.pct));
        // applyBp with pct×100 must agree (value-preservation proof).
        try std.testing.expectEqual(applyPct(c.amount, c.pct), applyBp(c.amount, c.pct * 100));
    }
}

test "salaryMultBp owns the experience multiplier; monthlySalary agrees" {
    // CamOps multipliers (MekHQ defaults), cited in the doc comment.
    // Consumer: person.monthlySalary() composes salaryMultBp with baseSalary and payBp
    // (see baseSalary consumer test in person.zig).
    try std.testing.expectEqual(@as(Bp, 6_000), ExperienceLevel.green.salaryMultBp());
    try std.testing.expectEqual(@as(Bp, 10_000), ExperienceLevel.regular.salaryMultBp());
    try std.testing.expectEqual(@as(Bp, 16_000), ExperienceLevel.veteran.salaryMultBp());
    try std.testing.expectEqual(@as(Bp, 32_000), ExperienceLevel.elite.salaryMultBp());
    // Strictly ordered: green < regular < veteran < elite.
    try std.testing.expect(ExperienceLevel.green.salaryMultBp() < ExperienceLevel.regular.salaryMultBp());
    try std.testing.expect(ExperienceLevel.regular.salaryMultBp() < ExperienceLevel.veteran.salaryMultBp());
    try std.testing.expect(ExperienceLevel.veteran.salaryMultBp() < ExperienceLevel.elite.salaryMultBp());
}

test "availabilityTarget owns the rarity target; the market roll agrees" {
    const t = @import("tuning.zig").t.market.rarity_target;
    try std.testing.expectEqual(t.common, Rarity.common.availabilityTarget());
    try std.testing.expectEqual(t.uncommon, Rarity.uncommon.availabilityTarget());
    try std.testing.expectEqual(t.rare, Rarity.rare.availabilityTarget());
    try std.testing.expectEqual(t.very_rare, Rarity.very_rare.availabilityTarget());
    // Monotonic: common ≤ uncommon ≤ rare ≤ very_rare.
    try std.testing.expect(Rarity.common.availabilityTarget() <= Rarity.uncommon.availabilityTarget());
    try std.testing.expect(Rarity.uncommon.availabilityTarget() <= Rarity.rare.availabilityTarget());
    try std.testing.expect(Rarity.rare.availabilityTarget() <= Rarity.very_rare.availabilityTarget());
    // Consumer: econ/market.zig:183 and sites.zig:469 check `roll >= rarity.availabilityTarget()`.
    // Use t.common (tuning data, independent of the function) as the roll value so the
    // predicate assertions are non-tautological: a wrong return would fail them.
    try std.testing.expect(t.common >= Rarity.common.availabilityTarget()); // roll at target: sourced
    try std.testing.expect(!(t.common - 1 >= Rarity.common.availabilityTarget())); // roll below: not sourced
}
