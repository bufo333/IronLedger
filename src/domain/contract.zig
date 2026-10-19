//! Contracts: the 12 AtB contract types with CamOps payment terms.
//! MekHQ counterpart: `mission/AtBContract.java` + `market/ContractMarket` (docs/mekhq-map.md).
//! Stage 4 implements the market and lifecycle; the math primitives live here.

const std = @import("std");
const types = @import("types.zig");
const tuning = @import("tuning.zig").t;
const operation = @import("operation.zig");
const situation_mod = @import("situation.zig");

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

    /// "garrison duty" — the kind as the screens print it.
    pub fn label(self: ContractKind) []const u8 {
        return switch (self) {
            .garrison_duty => "garrison duty",
            .cadre_duty => "cadre duty",
            .security_duty => "security duty",
            .riot_duty => "riot duty",
            .planetary_assault => "planetary assault",
            .relief_duty => "relief duty",
            .guerrilla_warfare => "guerrilla warfare",
            .pirate_hunting => "pirate hunting",
            .diversionary_raid => "diversionary raid",
            .objective_raid => "objective raid",
            .recon_raid => "recon raid",
            .extraction_raid => "extraction raid",
        };
    }

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

    /// CamOps operations/employment multiplier, basis points; the values
    /// are unchecked against the CamOps contract payment table.
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

/// Which side of its backing conflict a position serves
/// (docs/p5d-conflict-world-design.md §A "Player offers per side", §C).
/// A standing conflict's employer is its defender. Persisted by tag name.
pub const ConflictSide = enum {
    aggressor,
    defender,

    /// "aggressor" — the side as the screens print it.
    pub fn label(self: ConflictSide) []const u8 {
        return @tagName(self);
    }

    pub fn other(self: ConflictSide) ConflictSide {
        return switch (self) {
            .aggressor => .defender,
            .defender => .aggressor,
        };
    }
};

/// Who runs the show (AtB/CamOps command rights). Integrated: the
/// employer's officers command — more fights, half the salvage, harder
/// grading, no training lances, scouts pulled into the line, +10% pay.
/// Independent: your war, your salvage, fewer fights, −5% pay.
pub const CommandRights = enum {
    integrated,
    house,
    liaison,
    independent,

    const t = @import("tuning.zig").t.contract.rights;

    pub fn gapDelta(self: CommandRights) i32 {
        return switch (self) {
            .integrated => t.gap_delta.integrated,
            .house => t.gap_delta.house,
            .liaison => t.gap_delta.liaison,
            .independent => t.gap_delta.independent,
        };
    }

    pub fn salvageShareBp(self: CommandRights) types.Bp {
        return switch (self) {
            .integrated => t.salvage_share_bp.integrated,
            .house => t.salvage_share_bp.house,
            .liaison => t.salvage_share_bp.liaison,
            .independent => t.salvage_share_bp.independent,
        };
    }

    pub fn payBp(self: CommandRights) types.Bp {
        return switch (self) {
            .integrated => t.pay_bp.integrated,
            .house => t.pay_bp.house,
            .liaison => t.pay_bp.liaison,
            .independent => t.pay_bp.independent,
        };
    }

    /// Score a defeat costs; integrated employers grade harder.
    pub fn defeatScore(self: CommandRights) i32 {
        return if (self == .integrated) t.integrated_defeat_score else -1;
    }

    /// Training lances sit out fights — unless the employer commands.
    pub fn allowsTrainingLances(self: CommandRights) bool {
        return self != .integrated;
    }

    /// Integrated command pulls scouts into the line: no recon bonus.
    pub fn overridesScouting(self: CommandRights) bool {
        return self == .integrated;
    }

    /// Integrated command sets the rules of engagement: the
    /// employer's officers do not let a company pull back early.
    pub fn overridesRoe(self: CommandRights) bool {
        return self == .integrated;
    }

    /// One line for the screens.
    pub fn describe(self: CommandRights) []const u8 {
        return switch (self) {
            .integrated => "integrated: their officers command — fights every ~2 days sooner, salvage ×0.5, defeats −2, no training lances, scouts in the line, pay +10%",
            .house => "house: their staff sets the tempo — fights a day sooner, salvage ×0.75, pay +5%",
            .liaison => "liaison: an observer rides along — salvage ×0.9",
            .independent => "independent: your war — fewer fights (+2 days), full salvage, pay −5%",
        };
    }
};

/// What a negotiation round can move: one step each.
pub const NegotiableTerm = enum {
    advance, // 25% → 50%
    salvage, // +10 points (cap 60)
    transport, // +20 points (cap 100)
    support, // overhead/straight support +25 (cap 100)
    rights, // one step toward independent
    pay, // +10%
};

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

    /// Apply one negotiated step. Returns false when the term is already at its cap.
    pub fn improve(self: *Terms, term: NegotiableTerm) bool {
        const nc = tuning.contract;
        switch (term) {
            .advance => {
                if (self.advance_pct >= nc.negotiate_advance_cap_pct) return false;
                self.advance_pct = nc.negotiate_advance_cap_pct;
            },
            .salvage => {
                if (self.salvage_pct >= nc.negotiate_salvage_cap_pct) return false;
                self.salvage_pct = @min(nc.negotiate_salvage_cap_pct, self.salvage_pct + nc.negotiate_salvage_step_pct);
            },
            .transport => {
                if (self.transport_pct >= nc.negotiate_transport_cap_pct) return false;
                self.transport_pct = @min(nc.negotiate_transport_cap_pct, self.transport_pct + nc.negotiate_transport_step_pct);
            },
            .support => {
                if (self.overhead_pct >= nc.negotiate_overhead_cap_pct) return false;
                self.overhead_pct = @min(nc.negotiate_overhead_cap_pct, self.overhead_pct + nc.negotiate_overhead_step_pct);
            },
            .rights => {
                if (self.command_rights == .independent) return false;
                self.command_rights = @enumFromInt(@intFromEnum(self.command_rights) + 1);
            },
            .pay => self.base_pay_month = types.applyBp(self.base_pay_month, nc.negotiation_pay_step_bp),
        }
        return true;
    }

    pub fn totalBasePay(self: Terms) types.CBills {
        return self.base_pay_month * self.length_months;
    }

    pub fn advanceAmount(self: Terms) types.CBills {
        return types.applyPct(self.totalBasePay(), self.advance_pct);
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
    /// Next scheduled engagement (combat-class contracts).
    next_battle_day: ?u32 = null,
    /// The engagement day the commander confirmed battle orders for; the
    /// contact warning stands until it matches `next_battle_day`.
    orders_day: ?u32 = null,
    /// Wear bookkeeping for the rotation loop (ARCH §9.7).
    battles_fought: u8 = 0,
    casualties: u8 = 0,
    // Victory model (ARCH §7): hold until the end date, or grind
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
    /// One negotiation round per offer: spent, whatever the outcome.
    negotiated: bool = false,
    /// The opposing force, rolled with the offer: lances brought to
    /// an engagement, their skill level, and one lance's BV off the enemy
    /// house's RAT. Zero lances = no rolled opposition (`hasOpfor` false);
    /// the enemy is sized to the company.
    enemy_lances: u8 = 0,
    enemy_quality: types.ExperienceLevel = .regular,
    enemy_lance_bv: i64 = 0,
    /// One enemy lance's tonnage, for the board's "your 610t vs ~720t".
    enemy_lance_tons: u32 = 0,
    /// The HQ whose board posted this offer: only companies based
    /// there may take it. `.none` = no posting HQ; any company may take it.
    offer_hq: types.HqId = .none,
    /// The arc archetype drawn for this contract ("" = none). Validated
    /// against arc.table on load, like employer_key.
    arc_key: []const u8 = "",
    /// Current beat index into the arc's beats slice.
    arc_beat: u8 = 0,
    /// Accumulated escalation pressure (deterministic daily accrual). // TUNE
    escalation_clock: u16 = 0,
    /// The finale key the arc resolved to; "" until the terminal beat resolves.
    arc_finale_key: []const u8 = "",
    /// Instantiated operations for this contract, in creation order.
    operations: std.ArrayListUnmanaged(operation.Operation) = .empty,
    /// Current command-capacity pool for this contract's arc.
    /// Deterministic monthly cadence (P4g); 0 = none available.
    command_capacity: u8 = 0,
    /// Persistent actors attached to this contract by its arc (P4i).
    actor_ids: std.ArrayListUnmanaged(types.ActorId) = .empty,
    /// Persistent rival companies attached to this contract by its arc (P4i).
    rival_ids: std.ArrayListUnmanaged(types.RivalId) = .empty,
    /// Persistent officer arcs attached to this contract by its arc (P4i).
    officer_arc_ids: std.ArrayListUnmanaged(types.OfficerArcId) = .empty,
    /// Every situation this contract raised, in the order raised; each
    /// comes up at most once per contract.
    situations: std.ArrayListUnmanaged(situation_mod.SituationRecord) = .empty,
    /// The conflict that posted this position (docs/p5d-conflict-world-design.md
    /// §C "No contract without a backer"): its `side` faction is
    /// `employer_key`. `.none` only on an offer or contract a schema v73
    /// store held, which has no backer.
    conflict_id: types.ConflictId = .none,
    /// The side of `conflict_id` the position serves; `.defender` when there
    /// is no backer.
    side: ConflictSide = .defender,
    /// The day the backer wants the company on the world (§A): the
    /// conflict's strike day; null for a standing conflict's position and
    /// when there is no backer.
    on_station_by: ?u32 = null,
    /// The last day the position may be accepted (§A posting cadence;
    /// `contract_market.closeDay`); null when it closes at the next month
    /// start instead.
    close_day: ?u32 = null,

    /// The company is out on it: in transit to the world or on station.
    pub fn isRunning(self: *const Contract) bool {
        return self.status == .transit or self.status == .active;
    }

    /// Holds its backing conflict's position (docs/p5d-conflict-world-design.md
    /// §A "Both sides"): accepted, in transit or on station.
    pub fn holdsPosition(self: *const Contract) bool {
        return self.status == .accepted or self.isRunning();
    }

    /// Over, one way or another: completed, breached or failed.
    pub fn isClosed(self: *const Contract) bool {
        return self.status == .completed or self.status == .breached or self.status == .failed;
    }

    pub fn hasOpfor(self: *const Contract) bool {
        return self.enemy_lances > 0 and self.enemy_lance_bv > 0;
    }

    /// The opposition's strength in a typical engagement.
    pub fn opforBv(self: *const Contract) i64 {
        return self.enemy_lance_bv * self.enemy_lances;
    }

    pub fn poolDestroyedPct(self: *const Contract) u32 {
        if (self.enemy_pool_bv <= 0) return 0;
        const destroyed = self.enemy_pool_bv - self.enemy_pool_remaining;
        return @intCast(@min(100, @divTrunc(destroyed * 100, self.enemy_pool_bv)));
    }

    /// The verdict the employer writes on a completed tour:
    /// by victory points — outstanding ≥ 50 (+3 rep), strong ≥ 25 (+2),
    /// satisfactory ≥ 0 (+1), poor < 0 (0 rep). Failure is separate: a
    /// score of −5 or worse at end of term is a breach on performance.
    pub const Grade = enum { poor, satisfactory, strong, outstanding };

    pub fn gradeOf(self: *const Contract) Grade {
        const t = @import("tuning.zig").t.contract;
        if (self.victory_points >= t.grade_outstanding_vp) return .outstanding;
        if (self.victory_points >= t.grade_strong_vp) return .strong;
        if (self.victory_points >= 0) return .satisfactory;
        return .poor;
    }

    pub fn grade(self: *const Contract) []const u8 {
        return @tagName(self.gradeOf());
    }

    /// Score at which the employer declares performance failure at term.
    pub const fail_score: i32 = -5;

    /// Attrition objective substantially met: eligible for `complete`.
    pub fn objectivesMet(self: *const Contract) bool {
        return self.objective == .attrition and self.poolDestroyedPct() >= @import("tuning.zig").t.contract.attrition_met_pct;
    }

    /// Whether the payday on `payday_day` pays this contract its monthly
    /// net, projected through the day's order (ARCH §6): the contract phase
    /// runs before finances, so a term ending on the payday completes unpaid
    /// and a company arriving by the payday is on station and paid. It sees
    /// only the scheduled lifecycle: breaches, combat completion and arrival
    /// delays not yet rolled are not projected.
    pub fn paidOnPayday(self: *const Contract, payday_day: u32) bool {
        return switch (self.status) {
            .active => if (self.end_day) |end| end > payday_day else true,
            .transit => if (self.arrive_day) |arrive| arrive <= payday_day and arrive + termDays(self.terms.length_months) > payday_day else false,
            .offer, .accepted, .completed, .breached, .failed => false,
        };
    }
};

/// Length of a contract's term on station, in days: the months the terms
/// run on the campaign's month length (`types.days_per_month`).
pub fn termDays(length_months: u8) u32 {
    return @as(u32, length_months) * types.days_per_month;
}

pub const ObjectiveKind = enum { duration, attrition };

pub fn objectiveFor(kind: ContractKind) ObjectiveKind {
    return if (kind.isGarrisonClass()) .duration else .attrition;
}

/// Opposition force pool for an attrition contract, relative to the
/// committed force and scaled by length (longer campaigns face more;
/// tuning.contract.pool_*).
pub fn enemyPoolBp(kind: ContractKind, length_months: u8) types.Bp {
    const t = @import("tuning.zig").t.contract;
    const per_month: types.Bp = @divTrunc(enemyStrengthBp(kind), t.pool_per_month_divisor);
    return enemyStrengthBp(kind) + per_month * @as(types.Bp, @min(t.pool_months_cap, length_months));
}

/// Enemy strength relative to the player's committed force, by contract
/// kind, basis points (ARCH §7; tuning.contract.enemy_strength_bp).
pub fn enemyStrengthBp(kind: ContractKind) types.Bp {
    const e = @import("tuning.zig").t.contract.enemy_strength_bp;
    return switch (kind) {
        inline else => |k| @field(e, @tagName(k)),
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

test "command rights trade pay for tempo and salvage" {
    try std.testing.expect(CommandRights.integrated.payBp() > CommandRights.independent.payBp());
    try std.testing.expect(CommandRights.integrated.salvageShareBp() < CommandRights.independent.salvageShareBp());
    try std.testing.expect(CommandRights.integrated.gapDelta() < CommandRights.independent.gapDelta());
    try std.testing.expectEqual(@as(i32, -2), CommandRights.integrated.defeatScore());
    try std.testing.expectEqual(@as(i32, -1), CommandRights.house.defeatScore());
    try std.testing.expect(!CommandRights.integrated.allowsTrainingLances());
    try std.testing.expect(CommandRights.liaison.allowsTrainingLances());
}

test "negotiated steps move one term and stop at the named cap" {
    const nc = @import("tuning.zig").t.contract;
    var t: Terms = .{ .length_months = 6, .base_pay_month = 100_000, .salvage_pct = 50, .command_rights = .liaison };
    try std.testing.expect(t.improve(.advance));
    try std.testing.expectEqual(nc.negotiate_advance_cap_pct, t.advance_pct);
    try std.testing.expect(!t.improve(.advance));
    try std.testing.expect(t.improve(.salvage));
    try std.testing.expectEqual(nc.negotiate_salvage_cap_pct, t.salvage_pct);
    try std.testing.expect(!t.improve(.salvage));
    try std.testing.expect(t.improve(.rights));
    try std.testing.expectEqual(CommandRights.independent, t.command_rights);
    try std.testing.expect(!t.improve(.rights));
    try std.testing.expect(t.improve(.pay));
    try std.testing.expectEqual(@as(types.CBills, 110_000), t.base_pay_month);
    // Transport: step from near-cap stops at cap.
    var t2: Terms = .{ .length_months = 6, .base_pay_month = 100_000, .transport_pct = nc.negotiate_transport_cap_pct - nc.negotiate_transport_step_pct };
    try std.testing.expect(t2.improve(.transport));
    try std.testing.expectEqual(nc.negotiate_transport_cap_pct, t2.transport_pct);
    try std.testing.expect(!t2.improve(.transport));
    // Support (overhead): step from near-cap stops at cap.
    var t3: Terms = .{ .length_months = 6, .base_pay_month = 100_000, .overhead_pct = nc.negotiate_overhead_cap_pct - nc.negotiate_overhead_step_pct };
    try std.testing.expect(t3.improve(.support));
    try std.testing.expectEqual(nc.negotiate_overhead_cap_pct, t3.overhead_pct);
    try std.testing.expect(!t3.improve(.support));
}

test "a payday pays the contracts on station that day, after arrivals and term ends" {
    const payday: u32 = 31;
    var c: Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 1, .base_pay_month = 100_000 },
        .status = .active,
    };
    c.end_day = payday + 1;
    try std.testing.expect(c.paidOnPayday(payday)); // ends after the payday
    c.end_day = payday;
    try std.testing.expect(!c.paidOnPayday(payday)); // completes first, unpaid
    c.end_day = null;
    try std.testing.expect(c.paidOnPayday(payday));

    c.status = .transit;
    c.arrive_day = payday;
    try std.testing.expect(c.paidOnPayday(payday)); // on station first, paid; a one-month term too
    c.arrive_day = payday + 1;
    try std.testing.expect(!c.paidOnPayday(payday));
    c.arrive_day = null;
    try std.testing.expect(!c.paidOnPayday(payday));
    // A term that would already have run out by the payday is not paid.
    c.arrive_day = payday - termDays(1);
    try std.testing.expect(!c.paidOnPayday(payday));

    c.end_day = null;
    for ([_]ContractStatus{ .completed, .breached, .failed, .offer, .accepted }) |status| {
        c.status = status;
        c.arrive_day = payday;
        try std.testing.expect(!c.paidOnPayday(payday));
    }
    try std.testing.expectEqual(@as(u32, 6 * types.days_per_month), termDays(6));
}

test "gradeOf maps victory_points to the correct grade; objectivesMet fires at the threshold" {
    const tuning_t = @import("tuning.zig").t.contract;
    var c: Contract = .{
        .id = @enumFromInt(1),
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
    };
    // Grade boundaries.
    c.victory_points = tuning_t.grade_outstanding_vp;
    try std.testing.expectEqual(Contract.Grade.outstanding, c.gradeOf());
    c.victory_points = tuning_t.grade_strong_vp;
    try std.testing.expectEqual(Contract.Grade.strong, c.gradeOf());
    c.victory_points = 0;
    try std.testing.expectEqual(Contract.Grade.satisfactory, c.gradeOf());
    c.victory_points = -1;
    try std.testing.expectEqual(Contract.Grade.poor, c.gradeOf());
    // gradeOf → grade() agree.
    try std.testing.expectEqualStrings("poor", c.grade());
    // objectivesMet: only for attrition objective at threshold.
    c.objective = .attrition;
    c.enemy_pool_bv = 1000;
    c.enemy_pool_remaining = 1000; // 0% destroyed
    try std.testing.expect(!c.objectivesMet());
    // Destroy enough to hit the threshold (pool_destroyed_pct >= attrition_met_pct).
    const needed_pct = tuning_t.attrition_met_pct;
    c.enemy_pool_remaining = @intCast(c.enemy_pool_bv - @divTrunc(c.enemy_pool_bv * needed_pct, 100));
    try std.testing.expect(c.objectivesMet());
    // Duration objective never meets via objectivesMet.
    c.objective = .duration;
    try std.testing.expect(!c.objectivesMet());
}
