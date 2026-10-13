//! Phased-engagement record types (ARCH §7 "The phased engagement"). An
//! engagement is fought as contact → decisive → pursuit or withdrawal; the
//! commander's order at each pause and the report the pause showed are kept
//! as fields, so a save taken mid-battle resumes the same fight.
//!
//! Rule owners live in `src/sim/battle_phases.zig`; this module holds only
//! the values they produce and the persisted battle-in-progress record.
//! No MekHQ counterpart: MekHQ's ACAR resolves a scenario without pauses
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const force = @import("force.zig");
const autoresolve = @import("autoresolve.zig");
const operation = @import("operation.zig");

/// A named slice of the engagement. `contact` and `decisive` end on a pause;
/// `pursuit` (after a held field) and `withdrawal` (a lost field, or a
/// withdrawal after contact) end the battle.
pub const Phase = enum {
    contact,
    decisive,
    pursuit,
    withdrawal,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .contact => "contact",
            .decisive => "decisive",
            .pursuit => "pursuit",
            .withdrawal => "withdrawal",
        };
    }
};

/// Where a battle in progress stands: paused after contact, or after the
/// decisive phase. A battle that is due but not yet engaged has no record.
pub const Pause = enum {
    contact,
    decisive,

    pub fn phase(self: Pause) Phase {
        return switch (self) {
            .contact => .contact,
            .decisive => .decisive,
        };
    }
};

/// A battle order. `roe` changes the rules of engagement for the next phase
/// and is recorded on the battle, never written to the company's standing
/// ROE, so replaying the orders gives the same fight. `commit_reserve` and
/// `intervene` are the contact-pause levers (`Lever`): they change the
/// decisive phase only, and nothing live until the battle publishes.
pub const Order = union(enum) {
    /// Fight the contact phase.
    engage,
    /// Fight the decisive phase.
    press_on,
    /// Give up the field: after contact, or after a lost decisive phase.
    withdraw,
    /// After a held field: run the enemy down.
    pursue,
    /// After a held field: end the battle as it stands.
    consolidate,
    /// After a lost field: cover the recovery of the wrecks.
    cover_recovery,
    roe: force.Roe,
    /// At the contact pause: send the reserve-tasked lance in.
    commit_reserve,
    /// At the contact pause: spend command capacity on an intervention.
    intervene: operation.Intervention,

    pub const Kind = std.meta.Tag(Order);

    pub fn label(self: Order) []const u8 {
        return switch (self) {
            .engage => "engage",
            .press_on => "press on",
            .withdraw => "withdraw",
            .pursue => "pursue",
            .consolidate => "consolidate",
            .cover_recovery => "cover the recovery",
            .roe => |r| switch (r) {
                .hold => "ROE hold",
                .standard => "ROE standard",
                .cautious => "ROE cautious",
            },
            .commit_reserve => "commit the reserve",
            .intervene => |k| switch (k) {
                .emergency_recon => "call emergency recon",
                .reinforce => "call reinforce",
                .air_cover => "call air cover",
                .field_repair => "call field repair",
            },
        };
    }
};

/// A lever pulled at the contact pause: the reserve committed, or one
/// command-capacity intervention called. Each is given at most once in a
/// battle. The tag names are the persisted lever kinds.
pub const Lever = enum {
    commit_reserve,
    emergency_recon,
    reinforce,
    air_cover,
    field_repair,

    /// The lever `given` pulls; null for an order that pulls none.
    pub fn of(given: Order) ?Lever {
        return switch (given) {
            .commit_reserve => .commit_reserve,
            .intervene => |k| switch (k) {
                inline else => |tag| @field(Lever, @tagName(tag)),
            },
            .engage, .press_on, .withdraw, .pursue, .consolidate, .cover_recovery, .roe => null,
        };
    }

    /// The order that pulls this lever.
    pub fn order(self: Lever) Order {
        return switch (self) {
            .commit_reserve => .commit_reserve,
            inline else => |tag| .{ .intervene = @field(operation.Intervention, @tagName(tag)) },
        };
    }
};

/// What the next phase is, for the odds a pause shows.
pub const NextPhase = enum {
    /// The decisive roll: bands are `autoresolve.Outcome` in declaration order.
    decisive,
    /// A pursuit: bands are `PursuitBand` in declaration order.
    pursuit,
    /// Covering the recovery: bands are `CoverBand` in declaration order.
    cover,

    /// Bands this next phase has.
    pub fn bands(self: NextPhase) usize {
        return switch (self) {
            .decisive => @typeInfo(autoresolve.Outcome).@"enum".fields.len,
            .pursuit => @typeInfo(PursuitBand).@"enum".fields.len,
            .cover => @typeInfo(CoverBand).@"enum".fields.len,
        };
    }

    /// Name of band `index` (declaration order of the band enum).
    pub fn bandLabel(self: NextPhase, index: usize) []const u8 {
        return switch (self) {
            .decisive => @tagName(@as(autoresolve.Outcome, @enumFromInt(index))),
            .pursuit => @tagName(@as(PursuitBand, @enumFromInt(index))),
            .cover => @tagName(@as(CoverBand, @enumFromInt(index))),
        };
    }
};

/// A pursuit's result on its die: the enemy run down cleanly, run down at a
/// cost, or the pursuit repulsed.
pub const PursuitBand = enum { clean, costly, repulsed };

/// Covering the recovery: the rearguard holds cleanly, or pays in hits.
pub const CoverBand = enum { clean, costly };

/// The most bands any next phase has.
pub const max_bands = 5;

/// Exact odds of the next phase under the orders in force: `counts[i]` of
/// `total` equally likely dice results fall in band `i` of `next`.
pub const Odds = struct {
    next: NextPhase = .decisive,
    counts: [max_bands]u16 = @splat(0),
    total: u16 = 0,
};

/// What a pause shows: the phase last fought, the hits taken so far (not yet
/// landed: nothing is applied until the battle ends), and the odds of the
/// next phase under the orders in force.
pub const PhaseReport = struct {
    pause: Pause,
    /// The last fought phase's roll less `tuning.battle.phases.par`.
    margin: i32,
    /// Hits the line has taken so far.
    hits: u32,
    /// Carried from contact into the decisive roll.
    momentum: i32,
    /// The rules of engagement for the next phase.
    roe: force.Roe,
    /// The decisive verdict; null at the contact pause.
    outcome: ?autoresolve.Outcome = null,
    /// The field is held after the decisive phase.
    held_field: bool = false,
    odds: Odds = .{},
    /// The decisive-roll modifier the levers given so far add.
    lever_mod: i32 = 0,
    /// The reserve is committed: the decisive phase runs without its clamp.
    reserve_committed: bool = false,
    /// Command capacity the interventions given so far spend.
    capacity_spent: u8 = 0,
};

/// One order given and the pause it led to.
pub const Step = struct {
    order: Order,
    report: PhaseReport,
};

/// An engagement the commander has started and not finished. Persisted: the
/// battle lock (`battle_phases.commandAllowedDuringBattle`) keeps live state
/// unchanged between orders, so replaying `steps` from live state reaches
/// the same pause after a save, a load or a restart.
pub const BattleInProgress = struct {
    contract: types.ContractId,
    /// The pause reached; always `steps[len - 1].report.pause`.
    phase: Pause,
    steps: std.ArrayListUnmanaged(Step) = .empty,

    /// The report of the pause the battle stands at.
    pub fn latest(self: *const BattleInProgress) *const PhaseReport {
        return &self.steps.items[self.steps.items.len - 1].report;
    }
};

/// One fought phase on the after-action record: the order given at it, the
/// die-free modifiers it was fought under, its margin and the hits it added.
pub const PhaseRecord = struct {
    phase: Phase,
    order: Order,
    roe: force.Roe,
    ratio_bonus: i32 = 0,
    scenario_mod: i32 = 0,
    roe_roll: i32 = 0,
    momentum: i32 = 0,
    /// The decisive roll's lever modifier; zero in every other phase.
    lever_mod: i32 = 0,
    margin: i32 = 0,
    hits: u32 = 0,
};

test "every lever is pulled by exactly one order, and other orders pull none" {
    inline for (@typeInfo(Lever).@"enum".fields) |field| {
        const lever: Lever = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?Lever, lever), Lever.of(lever.order()));
    }
    try std.testing.expectEqual(@as(?Lever, .air_cover), Lever.of(.{ .intervene = .air_cover }));
    for ([_]Order{ .engage, .press_on, .withdraw, .pursue, .consolidate, .cover_recovery, .{ .roe = .hold } }) |order| {
        try std.testing.expectEqual(@as(?Lever, null), Lever.of(order));
    }
}

test "odds bands are named in the declaration order of their enum" {
    try std.testing.expectEqual(@as(usize, 5), NextPhase.decisive.bands());
    try std.testing.expectEqualStrings("decisive_victory", NextPhase.decisive.bandLabel(0));
    try std.testing.expectEqualStrings("rout", NextPhase.decisive.bandLabel(4));
    try std.testing.expectEqualStrings("repulsed", NextPhase.pursuit.bandLabel(2));
    try std.testing.expectEqual(@as(usize, 2), NextPhase.cover.bands());
    inline for (.{ NextPhase.decisive, NextPhase.pursuit, NextPhase.cover }) |next| try std.testing.expect(next.bands() <= max_bands);
}

test "the latest report is the last step's" {
    var record: BattleInProgress = .{ .contract = @enumFromInt(1), .phase = .decisive };
    defer record.steps.deinit(std.testing.allocator);
    try record.steps.append(std.testing.allocator, .{ .order = .engage, .report = .{ .pause = .contact, .margin = 1, .hits = 1, .momentum = 0, .roe = .standard } });
    try record.steps.append(std.testing.allocator, .{ .order = .press_on, .report = .{ .pause = .decisive, .margin = 2, .hits = 3, .momentum = 0, .roe = .standard, .outcome = .victory, .held_field = true } });
    try std.testing.expectEqual(Pause.decisive, record.latest().pause);
    try std.testing.expectEqual(@as(u32, 3), record.latest().hits);
}
