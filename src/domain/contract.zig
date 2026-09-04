//! Contracts: the 12 AtB contract types with CamOps payment terms.
//! Mirrors MekHQ `mission/AtBContract.java` + `market/ContractMarket`.
//! Stage 4 implements the market and lifecycle; the math primitives live here.

const std = @import("std");
const types = @import("types.zig");

pub const ContractKind = enum {
    garrison_duty,
    cadre_duty,
    security_duty,
    riot_duty,
    planetary_assault,
    relief_duty,
    guerrilla_warfare,
    pirate_hunting,
    diversionary_raid,
    objective_raid,
    recon_raid,
    extraction_raid,

    /// Garrison-class contracts are long, low-combat, and event-driven
    /// (ARCH §5/§8); the rest are battle-heavy.
    pub fn isGarrisonClass(self: ContractKind) bool {
        return switch (self) {
            .garrison_duty, .cadre_duty, .security_duty, .riot_duty => true,
            else => false,
        };
    }

    /// Typical contract length in months (AtB defaults; market rolls vary it).
    pub fn baseLengthMonths(self: ContractKind) u8 {
        return switch (self) {
            .garrison_duty => 18,
            .cadre_duty => 12,
            .security_duty => 6,
            .riot_duty => 4,
            .planetary_assault => 9,
            .relief_duty => 9,
            .guerrilla_warfare => 24,
            .pirate_hunting => 6,
            .diversionary_raid, .objective_raid, .recon_raid, .extraction_raid => 3,
        };
    }

    /// CamOps operations/employment multiplier, basis points.
    /// TODO(stage-4): verify each value against CamOps contract payment table.
    pub fn operationsMultBp(self: ContractKind) types.Bp {
        return switch (self) {
            .cadre_duty => 8_000, // ×0.8
            .garrison_duty => 10_000, // ×1.0
            .security_duty => 12_000, // ×1.2
            .riot_duty => 10_000, // ×1.0
            .planetary_assault => 15_000, // ×1.5
            .relief_duty => 14_000, // ×1.4
            .guerrilla_warfare => 21_000, // ×2.1
            .pirate_hunting => 10_000, // ×1.0
            .diversionary_raid => 18_000, // ×1.8
            .objective_raid => 16_000, // ×1.6
            .recon_raid => 16_000, // ×1.6
            .extraction_raid => 16_000, // ×1.6
        };
    }
};

pub const CommandRights = enum { integrated, house, liaison, independent };

pub const ContractStatus = enum { offer, accepted, transit, active, completed, breached, failed };

/// Financial terms, CamOps-style. Percentages as integers (25 = 25%).
pub const Terms = struct {
    length_months: u8,
    base_pay_month: types.CBills, // already includes all multipliers
    advance_pct: u8 = 25,
    signing_bonus: types.CBills = 0,
    transport_pct: u8 = 0, // employer share of transport costs
    overhead_pct: u8 = 0, // overhead compensation / straight support
    battle_loss_pct: u8 = 0,
    salvage_pct: u8 = 0,
    salvage_exchange: bool = false,
    command_rights: CommandRights = .independent,

    pub fn totalBasePay(self: Terms) types.CBills {
        return self.base_pay_month * self.length_months;
    }

    pub fn advanceAmount(self: Terms) types.CBills {
        return @divTrunc(self.totalBasePay() * self.advance_pct, 100);
    }
};

pub const Contract = struct {
    id: types.ContractId,
    kind: ContractKind,
    employer_key: []const u8,
    enemy_key: []const u8,
    planet_key: []const u8,
    terms: Terms,
    status: ContractStatus = .offer,
    assigned_company: types.ForceId = .none,
    start_day: ?u32 = null,
    /// Running success score; drives completion outcome & reputation delta.
    score: i32 = 0,
    // Influence context at offer time (ARCH §9.2/§9.6):
    dist_ly: u32 = 0,
    beachhead: bool = false,
    // Lifecycle (transit → active → complete):
    transit_days: u32 = 0,
    arrive_day: ?u32 = null,
    end_day: ?u32 = null,
    /// Monthly payment while active (base minus the advance's share).
    monthly_net: types.CBills = 0,
    /// Next scheduled engagement (combat-class contracts, Stage 7).
    next_battle_day: ?u32 = null,
    /// Wear bookkeeping for the rotation loop (ARCH §9.7, Stage 8).
    battles_fought: u8 = 0,
    casualties: u8 = 0,
    // Victory model (Stage 9E, ARCH §7): hold until the end date, or grind
    // an opposition force pool down across however many battles it takes.
    objective: ObjectiveKind = .duration,
    committed_bv: i64 = 0, // the player's combat BV at acceptance
    enemy_pool_bv: i64 = 0,
    enemy_pool_remaining: i64 = 0,
    victory_points: i32 = 0,
    /// Day the company first fell below half its committed strength; the
    /// grace window to buy local replacements runs from here.
    ineffective_since: ?u32 = null,
    breach_day: ?u32 = null,

    pub fn poolDestroyedPct(self: *const Contract) u32 {
        if (self.enemy_pool_bv <= 0) return 0;
        const destroyed = self.enemy_pool_bv - self.enemy_pool_remaining;
        return @intCast(@min(100, @divTrunc(destroyed * 100, self.enemy_pool_bv)));
    }

    /// Attrition objective substantially met: eligible for `complete`.
    pub fn objectivesMet(self: *const Contract) bool {
        return self.objective == .attrition and self.poolDestroyedPct() >= 75;
    }
};

pub const ObjectiveKind = enum { duration, attrition };

pub fn objectiveFor(kind: ContractKind) ObjectiveKind {
    return if (kind.isGarrisonClass()) .duration else .attrition;
}

/// Opposition force pool for an attrition contract, relative to the
/// committed force and scaled by length (longer campaigns face more). // TUNE
pub fn enemyPoolBp(kind: ContractKind, length_months: u8) types.Bp {
    const per_month: types.Bp = @divTrunc(enemyStrengthBp(kind), 2);
    return enemyStrengthBp(kind) + per_month * @as(types.Bp, @min(6, length_months));
}

/// Enemy strength relative to the player's committed force, by contract
/// kind, basis points (ARCH §7). // TUNE
pub fn enemyStrengthBp(kind: ContractKind) types.Bp {
    return switch (kind) {
        .recon_raid, .pirate_hunting => 8_000,
        .extraction_raid, .guerrilla_warfare => 9_000,
        .objective_raid, .diversionary_raid, .security_duty, .riot_duty => 10_000,
        .relief_duty => 11_000,
        .planetary_assault => 13_000,
        .garrison_duty, .cadre_duty => 6_000, // rare pirate probes only
    };
}

/// Monthly base payment (CamOps): the force's monthly peacetime cost ×
/// operations × employer × reputation multipliers.
pub fn monthlyPayment(
    force_monthly_cost: types.CBills,
    kind: ContractKind,
    employer_mult_bp: types.Bp,
    reputation_mult_bp: types.Bp,
) types.CBills {
    var pay = types.applyBp(force_monthly_cost, kind.operationsMultBp());
    pay = types.applyBp(pay, employer_mult_bp);
    pay = types.applyBp(pay, reputation_mult_bp);
    return pay;
}

test "garrison classification" {
    try std.testing.expect(ContractKind.garrison_duty.isGarrisonClass());
    try std.testing.expect(!ContractKind.objective_raid.isGarrisonClass());
}

test "payment multiplier chain" {
    // 1M/month force cost, planetary assault (×1.5), generous employer (×1.2),
    // solid reputation (×1.1) → 1.98M/month.
    const pay = monthlyPayment(1_000_000, .planetary_assault, 12_000, 11_000);
    try std.testing.expectEqual(@as(types.CBills, 1_980_000), pay);
}

test "advance is a percentage of total base pay" {
    const t: Terms = .{ .length_months = 12, .base_pay_month = 500_000, .advance_pct = 25 };
    try std.testing.expectEqual(@as(types.CBills, 6_000_000), t.totalBasePay());
    try std.testing.expectEqual(@as(types.CBills, 1_500_000), t.advanceAmount());
}
