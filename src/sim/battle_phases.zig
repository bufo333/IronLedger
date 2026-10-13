//! The phased engagement's rules (ARCH §7 "The phased engagement"): the
//! fixed phase dice, each phase's verdict and hits, the orders legal at a
//! pause, the exact odds of the next phase, and the battle lock. Every phase
//! is a slice of the one battle model: the power ratio, the scenario, the
//! ROE roll and `tuning.battle.outcome_at`; there is no second engine.
//! `battle.zig` prepares the engagement and applies the consequences.
//! No MekHQ counterpart: MekHQ's ACAR resolves a scenario without pauses
//! (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const force = @import("../domain/force.zig");
const autoresolve = @import("../domain/autoresolve.zig");
const phase_mod = @import("../domain/battle_phase.zig");
const battle_report = @import("../domain/battle_report.zig");
const operation = @import("../domain/operation.zig");
const rng_mod = @import("rng.zig");
const GameState = @import("state.zig").GameState;
const commands = @import("commands.zig");
const operations = @import("operations.zig");

const Order = phase_mod.Order;
const Lever = phase_mod.Lever;
const Pause = phase_mod.Pause;
const PhaseReport = phase_mod.PhaseReport;
const PhaseRecord = phase_mod.PhaseRecord;
const Odds = phase_mod.Odds;
const NextPhase = phase_mod.NextPhase;

/// The engagement's phase dice, drawn once at a fixed position of the
/// `.battle` stream, before any draw that depends on orders. Every course of
/// orders consumes exactly these four 2d6, so an earlier phase is never
/// re-rolled and the draws after them stay in their order.
pub const Dice = struct {
    contact: u8,
    decisive: u8,
    /// The decisive re-roll a pilot's Edge buys.
    edge: u8,
    /// Pursuit after a held field, or covering the recovery after a lost one.
    pursuit: u8,

    /// Draws contact, decisive, Edge and pursuit, in that order.
    pub fn draw(rng: *rng_mod.Rng) Dice {
        const contact = rng.roll2d6(.battle);
        const decisive = rng.roll2d6(.battle);
        const edge = rng.roll2d6(.battle);
        const pursuit = rng.roll2d6(.battle);
        return .{ .contact = contact, .decisive = decisive, .edge = edge, .pursuit = pursuit };
    }
};

/// The die-free modifiers every phase roll shares.
pub const Mods = struct {
    /// `battle.ratioBonus`, clamped in close terrain.
    ratio_bonus: i32,
    /// Scenario, recon, environment, task, tempo and intervention modifiers.
    scenario_mod: i32,
};

/// The roll modifier of a rules of engagement (ARCH §7 withdrawal
/// thresholds, `tuning.loss.roe`).
pub fn roeRoll(roe: force.Roe) i32 {
    const rt = tuning.loss.roe;
    return switch (roe) {
        .hold => rt.hold_roll,
        .standard => 0,
        .cautious => rt.cautious_roll,
    };
}

pub const ContactBand = enum { won, even, lost };

/// How contact went: the roll, its margin over `phases.par`, its band, and
/// the hit share and momentum the band carries.
pub const Contact = struct {
    roll: i32,
    margin: i32,
    band: ContactBand,
    momentum: i32,
    hit_pct: i32,
};

/// The band a contact margin falls in (`tuning.battle.phases.contact`).
fn contactBand(margin: i32) ContactBand {
    const p = tuning.battle.phases.contact;
    return if (margin >= p.won_margin) .won else if (margin <= p.lost_margin) .lost else .even;
}

/// The momentum a contact band carries into the decisive roll.
fn contactMomentum(band: ContactBand) i32 {
    const p = tuning.battle.phases.contact;
    return switch (band) {
        .won => p.won_momentum,
        .even => p.even_momentum,
        .lost => p.lost_momentum,
    };
}

/// Contact: contact die + power ratio + scenario + the ROE roll in force
/// when contact is joined, banded by margin (`tuning.battle.phases.contact`).
pub fn contactVerdict(die: u8, mods: Mods, roe: force.Roe) Contact {
    const p = tuning.battle.phases;
    const roll = @as(i32, die) + mods.ratio_bonus + mods.scenario_mod + roeRoll(roe);
    const margin = roll - p.par;
    const band = contactBand(margin);
    return .{
        .roll = roll,
        .margin = margin,
        .band = band,
        .momentum = contactMomentum(band),
        .hit_pct = switch (band) {
            .won => p.contact.won_hit_pct,
            .even => p.contact.even_hit_pct,
            .lost => p.contact.lost_hit_pct,
        },
    };
}

/// Hits `pct` percent of an engaged line takes, rounded down.
pub fn lineHits(engaged: usize, pct: i32) u32 {
    if (pct <= 0) return 0;
    return @intCast(engaged * @as(usize, @intCast(pct)) / 100);
}

/// Hits a pursuit or a rearguard costs: `pct` of the line, at least one hit
/// when it costs anything.
pub fn extraHits(engaged: usize, pct: i32) u32 {
    if (pct <= 0 or engaged == 0) return 0;
    return @max(1, lineHits(engaged, pct));
}

/// The engagement verdict a roll earns (`tuning.battle.outcome_at`).
pub fn outcomeAt(roll: i32) autoresolve.Outcome {
    const at = tuning.battle.outcome_at;
    if (roll >= at.decisive_victory) return .decisive_victory;
    if (roll >= at.victory) return .victory;
    if (roll >= at.draw) return .draw;
    if (roll >= at.defeat) return .defeat;
    return .rout;
}

fn decisiveRoll(die: u8, mods: Mods, roe: force.Roe, momentum: i32, lever_mod: i32) i32 {
    return @as(i32, die) + mods.ratio_bonus + mods.scenario_mod + roeRoll(roe) + momentum + lever_mod;
}

pub const Decisive = struct {
    roll: i32,
    margin: i32,
    outcome: autoresolve.Outcome,
    edge_used: bool,
};

/// The decisive phase: decisive die + power ratio + scenario + the ROE roll
/// in force + contact momentum + the contact-pause levers' modifier
/// (`decisiveMod`), banded by `tuning.battle.outcome_at`. A roll that loses
/// the fight is re-rolled once on the Edge die when a pilot in the line has
/// Edge to spend (ARCH §7).
pub fn decisiveVerdict(dice: Dice, mods: Mods, roe: force.Roe, momentum: i32, lever_mod: i32, edge_available: bool) Decisive {
    var roll = decisiveRoll(dice.decisive, mods, roe, momentum, lever_mod);
    var edge_used = false;
    if (roll < tuning.battle.outcome_at.draw and edge_available) {
        roll = decisiveRoll(dice.edge, mods, roe, momentum, lever_mod);
        edge_used = true;
    }
    return .{ .roll = roll, .margin = roll - tuning.battle.phases.par, .outcome = outcomeAt(roll), .edge_used = edge_used };
}

/// A draw fought under cautious ROE is a withdrawal: the company gives up
/// the field rather than holding it (ARCH §7 withdrawal thresholds).
pub fn cautiousWithdrawal(outcome: autoresolve.Outcome, roe: force.Roe) bool {
    return outcome == .draw and roe == .cautious;
}

/// The company holds the field after the decisive phase.
pub fn heldField(outcome: autoresolve.Outcome, roe: force.Roe) bool {
    return outcome.heldField() and !cautiousWithdrawal(outcome, roe);
}

pub const Hits = struct {
    hits: u32,
    hit_pct: u32,
    /// A reserve lance clamped a bad share to the draw level (P4e).
    reserve_steadied: bool,
};

/// Hits the whole line takes by the end of the decisive phase: the outcome's
/// share (`tuning.battle.hit_pct`), more for a lost stand under hold, less
/// for a cautious company already pulling back, clamped to the draw share by
/// a reserve lance, and at least one hit short of a decisive victory.
pub fn decisiveHits(outcome: autoresolve.Outcome, roe: force.Roe, reserve_present: bool, engaged: usize) Hits {
    const tb = tuning.battle;
    const rt = tuning.loss.roe;
    const base_hit_pct: i32 = switch (outcome) {
        inline else => |o| @field(tb.hit_pct, @tagName(o)),
    };
    const lost_fight = outcome.isLoss();
    var hit_pct: u32 = @intCast(@max(0, base_hit_pct + if (!lost_fight) 0 else switch (roe) {
        .hold => rt.hold_hits_pct,
        .standard => 0,
        .cautious => rt.cautious_hits_pct,
    }));
    const reserve_floor: u32 = @intCast(tb.hit_pct.draw);
    const reserve_steadied = reserve_present and lost_fight and hit_pct > reserve_floor;
    if (reserve_steadied) hit_pct = reserve_floor;
    const hits: u32 = @intCast(@max(
        @as(usize, if (outcome == .decisive_victory) 0 else 1),
        engaged * hit_pct / 100,
    ));
    return .{ .hits = hits, .hit_pct = hit_pct, .reserve_steadied = reserve_steadied };
}

pub const Pursuit = struct {
    band: phase_mod.PursuitBand,
    margin: i32,
    enemy_loss_bonus_pct: u8,
    extra_hit_pct: i32,
};

/// A pursuit after a held field, on the pursuit die
/// (`tuning.battle.phases.pursuit`).
pub fn pursuitVerdict(die: u8) Pursuit {
    const p = tuning.battle.phases.pursuit;
    const roll: i32 = die;
    const band: phase_mod.PursuitBand = if (roll >= p.clean_at) .clean else if (roll >= p.costly_at) .costly else .repulsed;
    return .{
        .band = band,
        .margin = roll - tuning.battle.phases.par,
        .enemy_loss_bonus_pct = if (band == .repulsed) 0 else p.enemy_loss_bonus_pct,
        .extra_hit_pct = if (band == .clean) 0 else p.extra_hit_pct,
    };
}

pub const Cover = struct {
    band: phase_mod.CoverBand,
    margin: i32,
    extra_hit_pct: i32,
};

/// Covering the recovery after a lost field, on the pursuit die
/// (`tuning.battle.phases.cover`). The recovery bonus itself belongs to
/// `battle_recovery.situation`.
pub fn coverVerdict(die: u8) Cover {
    const p = tuning.battle.phases.cover;
    const roll: i32 = die;
    const band: phase_mod.CoverBand = if (roll >= p.clean_at) .clean else .costly;
    return .{ .band = band, .margin = roll - tuning.battle.phases.par, .extra_hit_pct = if (band == .clean) 0 else p.extra_hit_pct };
}

/// The orders a commander may give at a pause; `pause` null is an engagement
/// that is due and not yet engaged. The levers (`commit_reserve`,
/// `intervene`) are contact-pause orders only: the decisive pause leads to a
/// pursuit or a rearguard on the bare pursuit die, which no lever reaches.
pub fn legalOrders(pause: ?Pause, held_field: bool) []const Order.Kind {
    const p = pause orelse return &.{.engage};
    return switch (p) {
        .contact => &.{ .press_on, .withdraw, .roe, .commit_reserve, .intervene },
        .decisive => if (held_field) &.{ .pursue, .consolidate } else &.{ .cover_recovery, .withdraw },
    };
}

pub fn orderLegal(pause: ?Pause, held_field: bool, order: Order) bool {
    for (legalOrders(pause, held_field)) |kind| if (kind == std.meta.activeTag(order)) return true;
    return false;
}

/// What one intervention needs, read from live state at engagement start.
pub const InterventionAvailability = struct {
    /// Its asset gate holds (`operations.interventionGate`).
    gate: bool = false,
    /// It was applied to the operation before battle
    /// (`operations.interventionApplied`).
    applied: bool = false,
    /// The employer reserves it (`operations.interventionReservedByEmployer`).
    reserved: bool = false,
};

/// What the commander may pull at the contact pause, read from live state
/// at engagement start (`battle.leverAvailability`) and from the
/// engagement's weather. The battle lock keeps it unchanged until the
/// battle publishes.
pub const Availability = struct {
    /// A reserve-tasked lance of the committed combat operation is
    /// operational (`readiness.forceOperational`).
    reserve_ready: bool = false,
    interventions: std.EnumArray(operation.Intervention, InterventionAvailability) = .initFill(.{}),
    /// Command capacity the commander may spend
    /// (`operations.commandCapacityAvailable`).
    capacity: u8 = 0,
    /// The engagement's weather grounds aircraft
    /// (`terrain.Environment.groundsAir`).
    air_grounded: bool = false,
};

/// Why a contact-pause lever is refused; `IllegalOrder` is a second
/// reserve commitment.
pub const LeverError = error{
    IllegalOrder,
    ReserveUnavailable,
    InterventionGateUnmet,
    InterventionAlreadyApplied,
    InsufficientCommandCapacity,
    InterventionReservedByEmployer,
    AirCoverGrounded,
};

/// Command capacity a lever spends: an intervention's
/// `operations.interventionCost`; committing the reserve spends none.
pub fn leverCost(lever: Lever) u8 {
    return switch (lever) {
        .commit_reserve => 0,
        inline else => |tag| operations.interventionCost(@field(operation.Intervention, @tagName(tag))),
    };
}

/// The most decisive-roll points one lever may add: the span of the 2d6 it
/// modifies (2..12). Every lever's `leverMod` lies in `0..max_lever_mod`, a
/// `data:` check every build runs, so `decisiveMod` stays within
/// `max_levers * max_lever_mod` and every decisive-roll sum is defined
/// (rules 25, 58).
pub const max_lever_mod: i32 = 12 - 2;

/// The decisive-roll points a lever adds, in `0..max_lever_mod`:
/// `tuning.battle.phases.reserve.commit_roll` for the reserve; for an
/// intervention, exactly what its profile adds before battle
/// (`operations.interventionProfile`), here to the decisive phase alone.
pub fn leverMod(lever: Lever) i32 {
    return switch (lever) {
        .commit_reserve => tuning.battle.phases.reserve.commit_roll,
        inline else => |tag| blk: {
            const profile = operations.interventionProfile(@field(operation.Intervention, @tagName(tag)));
            break :blk profile.surprise_reduction + profile.prepared_roll_bonus;
        },
    };
}

/// The decisive-roll modifier the levers among `orders` add: the one owner
/// of the term `run`, `nextPhaseOdds` and the report checks read.
pub fn decisiveMod(orders: []const Order) i32 {
    var sum: i32 = 0;
    for (orders) |o| if (Lever.of(o)) |lever| {
        sum += leverMod(lever);
    };
    return sum;
}

/// Command capacity the levers among `orders` spend.
pub fn capacitySpent(orders: []const Order) u8 {
    var sum: u8 = 0;
    for (orders) |o| if (Lever.of(o)) |lever| {
        sum +|= leverCost(lever);
    };
    return sum;
}

/// The reserve is committed among `orders`.
pub fn reserveCommitted(orders: []const Order) bool {
    for (orders) |o| if (o == .commit_reserve) return true;
    return false;
}

/// Whether a contact-pause lever may be pulled after the levers `given`
/// earlier at this pause (ARCH §7 "The phased engagement"). Each lever is
/// pulled once. The reserve needs an operational reserve lance. An
/// intervention is refused, in this order, when the employer reserves it,
/// when it is air cover in weather that grounds aircraft, when it was
/// applied before battle, when its gate is unmet, and when the capacity left
/// after the earlier interventions is below its cost. An order that pulls no
/// lever is not checked here. Pure.
pub fn leverAllowed(avail: Availability, given: []const Order, order: Order) LeverError!void {
    const lever = Lever.of(order) orelse return;
    for (given) |g| if (Lever.of(g) == lever) return switch (lever) {
        .commit_reserve => error.IllegalOrder,
        else => error.InterventionAlreadyApplied,
    };
    switch (order) {
        .commit_reserve => if (!avail.reserve_ready) return error.ReserveUnavailable,
        .intervene => |kind| {
            const a = avail.interventions.get(kind);
            if (a.reserved) return error.InterventionReservedByEmployer;
            if (kind == .air_cover and avail.air_grounded) return error.AirCoverGrounded;
            if (a.applied) return error.InterventionAlreadyApplied;
            if (!a.gate) return error.InterventionGateUnmet;
            if (avail.capacity -| capacitySpent(given) < leverCost(lever)) return error.InsufficientCommandCapacity;
        },
        .engage, .press_on, .withdraw, .pursue, .consolidate, .cover_recovery, .roe => unreachable,
    }
}

/// The exact odds of the next phase: every 2d6 result of its die (and of the
/// Edge die after a losing decisive roll, when Edge is available) counted
/// into its band; a decisive roll carries the levers' `lever_mod`. Pure;
/// consumes no RNG.
pub fn nextPhaseOdds(next: NextPhase, mods: Mods, roe: force.Roe, momentum: i32, lever_mod: i32, edge_available: bool) Odds {
    var odds: Odds = .{ .next = next };
    for (1..7) |a| for (1..7) |b| {
        const die: u8 = @intCast(a + b);
        switch (next) {
            .decisive => {
                if (decisiveRoll(die, mods, roe, momentum, lever_mod) < tuning.battle.outcome_at.draw and edge_available) {
                    for (1..7) |c| for (1..7) |d| {
                        const edge_die: u8 = @intCast(c + d);
                        const v = decisiveVerdict(.{ .contact = 0, .decisive = die, .edge = edge_die, .pursuit = 0 }, mods, roe, momentum, lever_mod, true);
                        odds.counts[@intFromEnum(v.outcome)] += 1;
                    };
                } else {
                    const v = decisiveVerdict(.{ .contact = 0, .decisive = die, .edge = 0, .pursuit = 0 }, mods, roe, momentum, lever_mod, false);
                    odds.counts[@intFromEnum(v.outcome)] += 36;
                }
            },
            .pursuit => odds.counts[@intFromEnum(pursuitVerdict(die).band)] += 1,
            .cover => odds.counts[@intFromEnum(coverVerdict(die).band)] += 1,
        }
    };
    for (odds.counts) |n| odds.total += n;
    return odds;
}

/// What the engagement brings to its phases, fixed at engagement start.
pub const Inputs = struct {
    mods: Mods,
    /// The rules of engagement in force when contact is joined.
    roe: force.Roe,
    /// Hulls in the line.
    engaged: usize,
    /// A pilot in the line has Edge to spend.
    edge_available: bool,
    /// A reserve-tasked lance stands behind the line (P4e).
    reserve_present: bool,
    /// What the contact-pause levers may draw on.
    avail: Availability = .{},
};

pub const max_phases = 3;

/// Every lever can be pulled once in a battle.
pub const max_levers = @typeInfo(Lever).@"enum".fields.len;

/// How a finished engagement went, for the consequences and the report.
pub const Final = struct {
    records: [max_phases]PhaseRecord = undefined,
    record_count: usize = 0,
    outcome: autoresolve.Outcome,
    held_field: bool,
    /// The company gave up the field: a withdrawal after contact or a
    /// cautious draw (`cautiousWithdrawal`).
    withdrew: bool,
    /// Hits the line takes over the whole battle.
    hits: u32,
    /// The share of the line hit, for the carrier's exposure.
    hit_pct: u32,
    reserve_steadied: bool,
    edge_used: bool,
    /// The ROE in force at the end: the report's ROE.
    roe: force.Roe,
    /// The ROE the wreck recovery rolls under: cautious after a withdrawal
    /// following contact.
    recovery_roe: force.Roe,
    /// The commander covered the recovery (`battle_recovery.situation`).
    covered: bool = false,
    enemy_loss_bonus_pct: u8 = 0,
    /// The reserve was committed at the contact pause.
    reserve_committed: bool = false,
    lever_records: [max_levers]battle_report.BattleLever = undefined,
    lever_count: usize = 0,

    pub fn phases(self: *const Final) []const PhaseRecord {
        return self.records[0..self.record_count];
    }

    /// The levers pulled at the contact pause, in the order given.
    pub fn levers(self: *const Final) []const battle_report.BattleLever {
        return self.lever_records[0..self.lever_count];
    }

    fn push(self: *Final, record: PhaseRecord) void {
        self.records[self.record_count] = record;
        self.record_count += 1;
    }
};

/// How the contact pause ended: the ROE in force, and `end`, the index of
/// the order that left it (`orders.len` when the battle still stands there).
const ContactPause = struct { roe: force.Roe, end: usize };

/// The contact pause: ROE changes and levers, each legal there and each
/// lever allowed (`leverAllowed`) after the ones before it, until an order
/// presses on or withdraws.
fn contactPause(in: Inputs, orders: []const Order) LeverError!ContactPause {
    var roe = in.roe;
    var i: usize = 1;
    while (i < orders.len) : (i += 1) {
        if (!orderLegal(.contact, false, orders[i])) return error.IllegalOrder;
        switch (orders[i]) {
            .roe => |r| roe = r,
            .commit_reserve, .intervene => try leverAllowed(in.avail, orders[1..i], orders[i]),
            .press_on, .withdraw => break,
            .engage, .pursue, .consolidate, .cover_recovery => unreachable,
        }
    }
    return .{ .roe = roe, .end = i };
}

/// The decisive phase under the contact pause's ROE and levers: its verdict,
/// and the hits the line has taken by its end, which a committed reserve no
/// longer clamps. Records the phase on `final` and returns the pause it
/// reaches.
fn decisivePhase(in: Inputs, dice: Dice, contact: Contact, contact_hits: u32, roe: force.Roe, given: []const Order, final: *Final) PhaseReport {
    const lever_mod = decisiveMod(given);
    const committed = reserveCommitted(given);
    const decisive = decisiveVerdict(dice, in.mods, roe, contact.momentum, lever_mod, in.edge_available);
    const total = decisiveHits(decisive.outcome, roe, in.reserve_present and !committed, in.engaged);
    const so_far = @max(contact_hits, total.hits);
    const held = heldField(decisive.outcome, roe);
    final.outcome = decisive.outcome;
    final.held_field = held;
    final.withdrew = cautiousWithdrawal(decisive.outcome, roe);
    final.hits = so_far;
    final.hit_pct = total.hit_pct;
    final.reserve_steadied = total.reserve_steadied;
    final.edge_used = decisive.edge_used;
    final.recovery_roe = roe;
    final.push(.{ .phase = .decisive, .order = .press_on, .roe = roe, .ratio_bonus = in.mods.ratio_bonus, .scenario_mod = in.mods.scenario_mod, .roe_roll = roeRoll(roe), .momentum = contact.momentum, .lever_mod = lever_mod, .margin = decisive.margin, .hits = so_far - contact_hits });
    return .{
        .pause = .decisive,
        .margin = decisive.margin,
        .hits = so_far,
        .momentum = contact.momentum,
        .roe = roe,
        .outcome = decisive.outcome,
        .held_field = held,
        .odds = nextPhaseOdds(if (held) .pursuit else .cover, in.mods, roe, contact.momentum, lever_mod, in.edge_available),
        .lever_mod = lever_mod,
        .reserve_committed = committed,
        .capacity_spent = capacitySpent(given),
    };
}

/// The order that ends the battle after the decisive phase: a pursuit or a
/// covered recovery on the pursuit die, a consolidation, or a withdrawal.
fn terminalPhase(in: Inputs, dice: Dice, held: bool, roe: force.Roe, last: Order, final: *Final) error{IllegalOrder}!void {
    if (!orderLegal(.decisive, held, last)) return error.IllegalOrder;
    switch (last) {
        .pursue => {
            const p = pursuitVerdict(dice.pursuit);
            const extra = extraHits(in.engaged, p.extra_hit_pct);
            final.hits += extra;
            final.enemy_loss_bonus_pct = p.enemy_loss_bonus_pct;
            final.push(.{ .phase = .pursuit, .order = last, .roe = roe, .margin = p.margin, .hits = extra });
        },
        .consolidate => final.push(.{ .phase = .pursuit, .order = last, .roe = roe }),
        .cover_recovery => {
            const cv = coverVerdict(dice.pursuit);
            const extra = extraHits(in.engaged, cv.extra_hit_pct);
            final.hits += extra;
            final.covered = true;
            final.push(.{ .phase = .withdrawal, .order = last, .roe = roe, .margin = cv.margin, .hits = extra });
        },
        .withdraw => final.push(.{ .phase = .withdrawal, .order = last, .roe = roe }),
        .engage, .press_on, .roe, .commit_reserve, .intervene => unreachable,
    }
}

pub const Course = union(enum) {
    paused: PhaseReport,
    finished: Final,
};

/// The engagement's course under an ordered list of orders: a pure function
/// of what it brings, its fixed dice and the orders. Returns the pause the
/// last order reached, or the finished verdict; `error.IllegalOrder` when an
/// order is not legal where it is given (`legalOrders`), and a lever's own
/// refusal when `leverAllowed` refuses it. The levers consume no die.
pub fn run(in: Inputs, dice: Dice, orders: []const Order) LeverError!Course {
    if (orders.len == 0 or !orderLegal(null, false, orders[0])) return error.IllegalOrder;
    const contact = contactVerdict(dice.contact, in.mods, in.roe);
    const contact_hits = lineHits(in.engaged, contact.hit_pct);
    var final: Final = .{
        .outcome = .draw,
        .held_field = false,
        .withdrew = false,
        .hits = contact_hits,
        .hit_pct = @intCast(@max(0, contact.hit_pct)),
        .reserve_steadied = false,
        .edge_used = false,
        .roe = in.roe,
        .recovery_roe = in.roe,
    };
    final.push(.{ .phase = .contact, .order = .engage, .roe = in.roe, .ratio_bonus = in.mods.ratio_bonus, .scenario_mod = in.mods.scenario_mod, .roe_roll = roeRoll(in.roe), .margin = contact.margin, .hits = contact_hits });

    const pause = try contactPause(in, orders);
    const given = orders[1..pause.end];
    for (given) |o| if (Lever.of(o)) |lever| {
        final.lever_records[final.lever_count] = .{ .lever = lever, .cost = leverCost(lever), .roll_mod = leverMod(lever) };
        final.lever_count += 1;
    };
    final.reserve_committed = reserveCommitted(given);
    if (pause.end == orders.len) {
        const lever_mod = decisiveMod(given);
        return .{ .paused = .{
            .pause = .contact,
            .margin = contact.margin,
            .hits = contact_hits,
            .momentum = contact.momentum,
            .roe = pause.roe,
            .odds = nextPhaseOdds(.decisive, in.mods, pause.roe, contact.momentum, lever_mod, in.edge_available),
            .lever_mod = lever_mod,
            .reserve_committed = final.reserve_committed,
            .capacity_spent = capacitySpent(given),
        } };
    }
    final.roe = pause.roe;
    if (orders[pause.end] == .withdraw) {
        // A lever pulled and then abandoned still spent its capacity; it
        // added nothing to a fight not fought.
        if (pause.end + 1 != orders.len) return error.IllegalOrder;
        final.withdrew = true;
        final.recovery_roe = .cautious;
        final.push(.{ .phase = .withdrawal, .order = .withdraw, .roe = pause.roe });
        return .{ .finished = final };
    }

    const decisive = decisivePhase(in, dice, contact, contact_hits, pause.roe, given, &final);
    const next = pause.end + 1;
    if (next == orders.len) return .{ .paused = decisive };
    if (next + 1 != orders.len) return error.IllegalOrder;
    try terminalPhase(in, dice, decisive.held_field, pause.roe, orders[next], &final);
    return .{ .finished = final };
}

/// The order an unattended script gives at the pause `latest` shows (null:
/// not yet engaged): engage, press on, then consolidate a held field or
/// withdraw from a lost one.
pub fn defaultOrder(latest: ?*const PhaseReport) Order {
    const r = latest orelse return .engage;
    return switch (r.pause) {
        .contact => .press_on,
        .decisive => if (r.held_field) .consolidate else .withdraw,
    };
}

/// A battle record could have been produced by the battle order command:
/// it starts with `engage`, every order was legal at the pause before it,
/// no lever was pulled twice, no order ended the battle, each report's
/// pause, verdict, field and odds agree with the order that reached it, its
/// lever modifier, reserve commitment and capacity spent are the owners'
/// sums over the levers given so far (`decisiveMod`, `reserveCommitted`,
/// `capacitySpent`), and the record stands at its last report's pause.
/// Whether each lever was allowed is the replay's to check
/// (`battle.validateInProgress`). The loader refuses anything else (rule 47).
pub fn recordConsistent(record: *const phase_mod.BattleInProgress) bool {
    if (record.steps.items.len == 0) return false;
    var pause: ?Pause = null;
    var held = false;
    var pulled = std.EnumSet(Lever).initEmpty();
    var lever_mod: i32 = 0;
    var spent: u8 = 0;
    for (record.steps.items) |step| {
        const r = step.report;
        if (!orderLegal(pause, held, step.order)) return false;
        const reached: Pause = switch (step.order) {
            .engage => .contact,
            .roe => |roe| blk: {
                if (r.roe != roe) return false;
                break :blk .contact;
            },
            .commit_reserve, .intervene => blk: {
                const lever = Lever.of(step.order).?;
                if (pulled.contains(lever)) return false;
                pulled.insert(lever);
                lever_mod += leverMod(lever);
                spent +|= leverCost(lever);
                break :blk .contact;
            },
            .press_on => .decisive,
            .withdraw, .pursue, .consolidate, .cover_recovery => return false,
        };
        if (r.pause != reached) return false;
        if (r.lever_mod != lever_mod or r.capacity_spent != spent or r.reserve_committed != pulled.contains(.commit_reserve)) return false;
        switch (reached) {
            .contact => if (r.outcome != null or r.held_field or r.odds.next != .decisive) return false,
            .decisive => {
                const outcome = r.outcome orelse return false;
                if (r.held_field != heldField(outcome, r.roe)) return false;
                if (r.odds.next != @as(NextPhase, if (r.held_field) .pursuit else .cover)) return false;
            },
        }
        var sum: u32 = 0;
        for (r.odds.counts, 0..) |n, band| {
            if (band >= r.odds.next.bands() and n != 0) return false;
            sum += n;
        }
        if (r.odds.total == 0 or sum != r.odds.total) return false;
        pause = r.pause;
        held = r.held_field;
    }
    return record.phase == pause.?;
}

/// A battle report's fought phases are a whole course `run` could have
/// finished, agreeing with the verdict the report carries: contact under
/// `engage`, then a withdrawal, or the decisive phase and an order legal
/// after it. The decisive phase carries the contact band's momentum, its
/// margin earns the report's outcome, and with its ROE the field, the
/// withdrawal and the report's ROE follow; an unrolled phase carries no
/// figures, a costed one hits exactly when its die costs, every rolled
/// phase's margin needs a die 2d6 can show, and the phases' hits sum to the
/// report's. The levers are each pulled once at their owners' cost and
/// modifier (`leversConsistent`), and the decisive phase's lever modifier is
/// their sum; a withdrawal after contact may carry levers that added
/// nothing. Only a concession or a forfeit fights no phase
/// (`unfoughtConsistent`), and it pulls no lever. The loader refuses
/// anything else (rule 47).
pub fn reportPhasesConsistent(report: *const battle_report.BattleReport) bool {
    const phases = report.phases;
    if (phases.len == 0) return report.levers.len == 0 and unfoughtConsistent(report);
    if (report.conceded) return false;
    if (!leversConsistent(report.levers)) return false;
    const contact = phases[0];
    if (contact.phase != .contact or contact.order != .engage) return false;
    if (contact.roe_roll != roeRoll(contact.roe) or contact.momentum != 0 or contact.lever_mod != 0) return false;
    if (!marginFeasible(contact.margin, &.{ contact.ratio_bonus, contact.scenario_mod, contact.roe_roll })) return false;
    var hits: u64 = contact.hits;
    switch (phases.len) {
        2 => {
            const w = phases[1];
            if (!std.meta.eql(w, PhaseRecord{ .phase = .withdrawal, .order = .withdraw, .roe = w.roe })) return false;
            if (report.outcome != .draw or report.held_field or !report.withdrew or report.roe != w.roe) return false;
        },
        3 => {
            const d = phases[1];
            const last = phases[2];
            if (d.phase != .decisive or d.order != .press_on or d.roe_roll != roeRoll(d.roe)) return false;
            if (d.ratio_bonus != contact.ratio_bonus or d.scenario_mod != contact.scenario_mod) return false;
            if (d.momentum != contactMomentum(contactBand(contact.margin))) return false;
            var lever_sum: i64 = 0;
            for (report.levers) |l| lever_sum += l.roll_mod;
            if (d.lever_mod != lever_sum) return false;
            // The decisive die or, after a losing roll, the Edge die.
            if (!marginFeasible(d.margin, &.{ d.ratio_bonus, d.scenario_mod, d.roe_roll, d.momentum, d.lever_mod })) return false;
            const roll = std.math.cast(i32, @as(i64, d.margin) + tuning.battle.phases.par) orelse return false;
            const outcome = outcomeAt(roll);
            const held = heldField(outcome, d.roe);
            if (report.outcome != outcome or report.held_field != held or report.withdrew != cautiousWithdrawal(outcome, d.roe) or report.roe != d.roe) return false;
            if (last.roe != d.roe or !orderLegal(.decisive, held, last.order) or !terminalConsistent(last)) return false;
            hits += @as(u64, d.hits) + last.hits;
        },
        else => return false,
    }
    return hits == report.hits_taken;
}

/// A report's levers: at most one of each, each at its owner's cost and
/// decisive-roll modifier (`leverCost`, `leverMod`).
fn leversConsistent(levers: []const battle_report.BattleLever) bool {
    if (levers.len > max_levers) return false;
    var pulled = std.EnumSet(Lever).initEmpty();
    for (levers) |l| {
        if (pulled.contains(l.lever)) return false;
        pulled.insert(l.lever);
        if (l.cost != leverCost(l.lever) or l.roll_mod != leverMod(l.lever)) return false;
    }
    return true;
}

/// A report with no fought phase is a concession or a forfeit as
/// `battle.concede` and `battle.forfeit` write it: a conceded defeat on a
/// lost field, or a bloodless victory on a held one; no power was measured,
/// and the fight cost and earned nothing.
fn unfoughtConsistent(r: *const battle_report.BattleReport) bool {
    const verdict = if (r.conceded) r.outcome == .defeat and !r.held_field else r.outcome == .victory and r.held_field;
    return verdict and !r.withdrew and r.player_power == 0 and r.enemy_power == 0 and
        r.hits_taken == 0 and r.destroyed == 0 and r.wounded == 0 and r.kia == 0 and
        r.lost_hulls == 0 and r.missing == 0 and r.hulls.len == 0 and r.battle_loss_comp == 0 and
        r.enemy_destroyed_bv == 0 and r.kills_credited == 0 and r.prisoners == 0;
}

/// A rolled phase's margin is one a 2d6 die can earn: margin + par less the
/// die-free modifiers lies in the 2d6 range. Checked arithmetic, so no
/// stored figure can overflow into the range.
fn marginFeasible(margin: i32, mods: []const i32) bool {
    var die: i64 = @as(i64, margin) + tuning.battle.phases.par;
    for (mods) |m| die -= m;
    return die >= rng_mod.roll2d6_min and die <= rng_mod.roll2d6_max;
}

/// The phase that ends a battle after the decisive one, as `run` records it:
/// a consolidation or a withdrawal rolls nothing; a pursuit or a covered
/// recovery rolls the pursuit die, a die 2d6 can show, and takes hits
/// exactly when its band costs.
fn terminalConsistent(last: PhaseRecord) bool {
    const unrolled: PhaseRecord = .{ .phase = last.phase, .order = last.order, .roe = last.roe };
    const rolled_phase: phase_mod.Phase = switch (last.order) {
        .consolidate => return last.phase == .pursuit and std.meta.eql(last, unrolled),
        .withdraw => return last.phase == .withdrawal and std.meta.eql(last, unrolled),
        .pursue => .pursuit,
        .cover_recovery => .withdrawal,
        .engage, .press_on, .roe, .commit_reserve, .intervene => return false,
    };
    if (last.phase != rolled_phase or !marginFeasible(last.margin, &.{})) return false;
    const die: u8 = @intCast(@as(i64, last.margin) + tuning.battle.phases.par);
    const extra_hit_pct = if (last.order == .pursue) pursuitVerdict(die).extra_hit_pct else coverVerdict(die).extra_hit_pct;
    const rolled: PhaseRecord = .{ .phase = last.phase, .order = last.order, .roe = last.roe, .margin = last.margin, .hits = last.hits };
    return std.meta.eql(last, rolled) and (last.hits > 0) == (extra_hit_pct > 0);
}

/// The engagement the commander has started and not finished, if any.
pub fn inProgress(gs: *const GameState) ?*const phase_mod.BattleInProgress {
    if (gs.battles_in_progress.items.len == 0) return null;
    return &gs.battles_in_progress.items[0];
}

/// The battle lock (ARCH §6 "The battle lock"): while a battle is in
/// progress only battle orders run. Every other command mutates gameplay
/// state the replay reads, so it is refused with `error.BattleInProgress`.
pub fn commandAllowedDuringBattle(cmd: commands.Command) bool {
    return switch (cmd) {
        .battle_order => true,
        else => false,
    };
}

/// A whole fought course that earns `outcome` under standard ROE with no
/// modifiers and no hits, for a hand-built test report: an even contact, the
/// lowest decisive die that earns the outcome, and a consolidation or a
/// withdrawal. The report takes `heldField(outcome, .standard)` and no hits.
pub fn courseForTest(comptime outcome: autoresolve.Outcome) []const PhaseRecord {
    const course = comptime blk: {
        const p = tuning.battle.phases;
        const momentum = contactMomentum(contactBand(0));
        var die: i32 = rng_mod.roll2d6_min;
        while (die <= rng_mod.roll2d6_max and outcomeAt(die + momentum) != outcome) die += 1;
        if (die > rng_mod.roll2d6_max) @compileError("no die earns " ++ @tagName(outcome));
        const held = heldField(outcome, .standard);
        break :blk [max_phases]PhaseRecord{
            .{ .phase = .contact, .order = .engage, .roe = .standard },
            .{ .phase = .decisive, .order = .press_on, .roe = .standard, .momentum = momentum, .margin = die + momentum - p.par },
            .{ .phase = if (held) .pursuit else .withdrawal, .order = if (held) .consolidate else .withdraw, .roe = .standard },
        };
    };
    return &course;
}

// ---------------------------------------------------------------- tests

const test_mods: Mods = .{ .ratio_bonus = 0, .scenario_mod = 0 };
const test_inputs: Inputs = .{ .mods = test_mods, .roe = .standard, .engaged = 12, .edge_available = false, .reserve_present = false };

test "contactVerdict bands the margin and the battle course carries its hits and momentum" {
    const p = tuning.battle.phases;
    const won = contactVerdict(@intCast(p.par + p.contact.won_margin), test_mods, .standard);
    try std.testing.expectEqual(ContactBand.won, won.band);
    try std.testing.expectEqual(p.contact.won_momentum, won.momentum);
    const lost = contactVerdict(@intCast(p.par + p.contact.lost_margin), test_mods, .standard);
    try std.testing.expectEqual(ContactBand.lost, lost.band);
    const even = contactVerdict(@intCast(p.par), test_mods, .standard);
    try std.testing.expectEqual(ContactBand.even, even.band);
    // The ROE roll moves the margin.
    try std.testing.expectEqual(won.margin + roeRoll(.hold), contactVerdict(@intCast(p.par + p.contact.won_margin), test_mods, .hold).margin);
    // Consumer: the course's contact pause shows the verdict's hits and momentum.
    const course = try run(test_inputs, .{ .contact = @intCast(p.par + p.contact.lost_margin), .decisive = 7, .edge = 7, .pursuit = 7 }, &.{.engage});
    try std.testing.expectEqual(lineHits(12, lost.hit_pct), course.paused.hits);
    try std.testing.expectEqual(lost.momentum, course.paused.momentum);
    try std.testing.expectEqual(lost.margin, course.paused.margin);
}

test "decisiveVerdict reads outcome_at, carries momentum and spends Edge only on a lost roll" {
    const at = tuning.battle.outcome_at;
    const dice: Dice = .{ .contact = 7, .decisive = @intCast(at.victory), .edge = 12, .pursuit = 7 };
    try std.testing.expectEqual(autoresolve.Outcome.victory, decisiveVerdict(dice, test_mods, .standard, 0, 0, false).outcome);
    try std.testing.expectEqual(autoresolve.Outcome.draw, decisiveVerdict(dice, test_mods, .standard, -(at.victory - at.draw), 0, false).outcome);
    // The levers' modifier moves the roll as momentum does.
    try std.testing.expectEqual(autoresolve.Outcome.draw, decisiveVerdict(dice, test_mods, .standard, 0, -(at.victory - at.draw), false).outcome);
    // A winning roll keeps its die even with Edge on hand.
    try std.testing.expect(!decisiveVerdict(dice, test_mods, .standard, 0, 0, true).edge_used);
    const losing: Dice = .{ .contact = 7, .decisive = 2, .edge = 12, .pursuit = 7 };
    const spent = decisiveVerdict(losing, test_mods, .standard, 0, 0, true);
    try std.testing.expect(spent.edge_used);
    try std.testing.expectEqual(outcomeAt(12), spent.outcome);
    try std.testing.expectEqual(autoresolve.Outcome.rout, decisiveVerdict(losing, test_mods, .standard, 0, 0, false).outcome);
    // Consumer: the course's decisive pause shows the same verdict.
    const course = try run(test_inputs, dice, &.{ .engage, .press_on });
    try std.testing.expectEqual(decisiveVerdict(dice, test_mods, .standard, contactVerdict(7, test_mods, .standard).momentum, 0, false).outcome, course.paused.outcome.?);
}

test "decisiveHits owns the hit share; the course lands the larger of contact and decisive" {
    const h = decisiveHits(.rout, .hold, false, 20);
    try std.testing.expectEqual(@as(u32, @intCast(tuning.battle.hit_pct.rout + tuning.loss.roe.hold_hits_pct)), h.hit_pct);
    const steadied = decisiveHits(.rout, .standard, true, 20);
    try std.testing.expect(steadied.reserve_steadied);
    try std.testing.expectEqual(@as(u32, @intCast(tuning.battle.hit_pct.draw)), steadied.hit_pct);
    try std.testing.expectEqual(@as(u32, 0), decisiveHits(.decisive_victory, .standard, false, 1).hits);
    try std.testing.expectEqual(@as(u32, 1), decisiveHits(.victory, .standard, false, 1).hits);
    // Consumer: a finished course's hits are max(contact, decisive) plus nothing for a consolidation.
    const dice: Dice = .{ .contact = 2, .decisive = 9, .edge = 7, .pursuit = 7 };
    const done = (try run(test_inputs, dice, &.{ .engage, .press_on, .consolidate })).finished;
    const contact_hits = lineHits(12, contactVerdict(2, test_mods, .standard).hit_pct);
    const decisive = decisiveVerdict(dice, test_mods, .standard, contactVerdict(2, test_mods, .standard).momentum, 0, false);
    try std.testing.expectEqual(@max(contact_hits, decisiveHits(decisive.outcome, .standard, false, 12).hits), done.hits);
}

test "pursuitVerdict and coverVerdict band the pursuit die; the course adds their hits" {
    const p = tuning.battle.phases;
    try std.testing.expectEqual(phase_mod.PursuitBand.clean, pursuitVerdict(@intCast(p.pursuit.clean_at)).band);
    try std.testing.expectEqual(phase_mod.PursuitBand.costly, pursuitVerdict(@intCast(p.pursuit.costly_at)).band);
    try std.testing.expectEqual(phase_mod.PursuitBand.repulsed, pursuitVerdict(@intCast(p.pursuit.costly_at - 1)).band);
    try std.testing.expectEqual(@as(u8, 0), pursuitVerdict(2).enemy_loss_bonus_pct);
    try std.testing.expectEqual(phase_mod.CoverBand.costly, coverVerdict(@intCast(p.cover.clean_at - 1)).band);
    try std.testing.expectEqual(@as(i32, 0), coverVerdict(12).extra_hit_pct);
    try std.testing.expectEqual(@as(u32, 1), extraHits(1, 10));
    try std.testing.expectEqual(@as(u32, 0), extraHits(12, 0));
    // Consumer: a won field pursued on a costly die lands the extra hits and the loss bonus.
    const held: Dice = .{ .contact = 7, .decisive = 12, .edge = 7, .pursuit = @intCast(p.pursuit.costly_at) };
    const consolidated = (try run(test_inputs, held, &.{ .engage, .press_on, .consolidate })).finished;
    const pursued = (try run(test_inputs, held, &.{ .engage, .press_on, .pursue })).finished;
    try std.testing.expectEqual(consolidated.hits + extraHits(12, p.pursuit.extra_hit_pct), pursued.hits);
    try std.testing.expectEqual(p.pursuit.enemy_loss_bonus_pct, pursued.enemy_loss_bonus_pct);
    // A lost field covered on a costly die pays the rearguard's hits and rolls covered.
    const lost: Dice = .{ .contact = 7, .decisive = 2, .edge = 7, .pursuit = @intCast(p.cover.clean_at - 1) };
    const withdrawn = (try run(test_inputs, lost, &.{ .engage, .press_on, .withdraw })).finished;
    const covered = (try run(test_inputs, lost, &.{ .engage, .press_on, .cover_recovery })).finished;
    try std.testing.expect(covered.covered and !withdrawn.covered);
    try std.testing.expectEqual(withdrawn.hits + extraHits(12, p.cover.extra_hit_pct), covered.hits);
}

test "legalOrders: the course refuses an order that is not legal where it is given" {
    try std.testing.expect(orderLegal(null, false, .engage));
    try std.testing.expect(!orderLegal(null, false, .press_on));
    try std.testing.expect(orderLegal(.contact, false, .{ .roe = .cautious }));
    try std.testing.expect(!orderLegal(.contact, false, .pursue));
    try std.testing.expect(orderLegal(.decisive, true, .pursue) and !orderLegal(.decisive, true, .withdraw));
    try std.testing.expect(orderLegal(.decisive, false, .withdraw) and !orderLegal(.decisive, false, .consolidate));
    const dice: Dice = .{ .contact = 7, .decisive = 12, .edge = 7, .pursuit = 7 };
    try std.testing.expectError(error.IllegalOrder, run(test_inputs, dice, &.{.press_on}));
    try std.testing.expectError(error.IllegalOrder, run(test_inputs, dice, &.{ .engage, .pursue }));
    try std.testing.expectError(error.IllegalOrder, run(test_inputs, dice, &.{ .engage, .press_on, .withdraw }));
    try std.testing.expectError(error.IllegalOrder, run(test_inputs, dice, &.{ .engage, .withdraw, .press_on }));
    // Every order the owner lists at a pause, the course accepts there.
    for (legalOrders(.contact, false)) |kind| {
        const order: Order = switch (kind) {
            .roe => .{ .roe = .hold },
            .intervene => .{ .intervene = .reinforce },
            inline else => |k| @unionInit(Order, @tagName(k), {}),
        };
        _ = try run(test_open_inputs, dice, &.{ .engage, order });
    }
    // A lever is a contact-pause order only: not before contact, not at the decisive pause.
    for ([_]Order{ .commit_reserve, .{ .intervene = .air_cover } }) |lever| {
        try std.testing.expect(!orderLegal(null, false, lever) and !orderLegal(.decisive, true, lever) and !orderLegal(.decisive, false, lever));
        try std.testing.expectError(error.IllegalOrder, run(test_open_inputs, dice, &.{lever}));
        try std.testing.expectError(error.IllegalOrder, run(test_open_inputs, dice, &.{ .engage, .press_on, lever }));
    }
}

/// Every lever available: an operational reserve, every gate met, no
/// employer lock, flying weather and capacity to spare.
const test_open: Availability = .{
    .reserve_ready = true,
    .interventions = .initFill(.{ .gate = true }),
    .capacity = 255,
};
const test_open_inputs: Inputs = .{ .mods = test_mods, .roe = .standard, .engaged = 12, .edge_available = false, .reserve_present = true, .avail = test_open };

test "leverCost and leverMod are the interventions' own cost and profile; the reserve costs nothing and adds commit_roll" {
    inline for (@typeInfo(operation.Intervention).@"enum".fields) |field| {
        const kind: operation.Intervention = @enumFromInt(field.value);
        const lever = Lever.of(.{ .intervene = kind }).?;
        const profile = operations.interventionProfile(kind);
        try std.testing.expectEqual(operations.interventionCost(kind), leverCost(lever));
        try std.testing.expectEqual(profile.surprise_reduction + profile.prepared_roll_bonus, leverMod(lever));
    }
    try std.testing.expectEqual(@as(u8, 0), leverCost(.commit_reserve));
    try std.testing.expectEqual(tuning.battle.phases.reserve.commit_roll, leverMod(.commit_reserve));
    // decisiveMod, capacitySpent and reserveCommitted sum over the levers and skip every other order.
    const orders = [_]Order{ .engage, .{ .roe = .hold }, .commit_reserve, .{ .intervene = .reinforce }, .press_on };
    try std.testing.expectEqual(leverMod(.commit_reserve) + leverMod(.reinforce), decisiveMod(&orders));
    try std.testing.expectEqual(leverCost(.reinforce), capacitySpent(&orders));
    try std.testing.expect(reserveCommitted(&orders) and !reserveCommitted(orders[3..]));
}

test "data: every contact-pause lever adds decisive-roll points on the 2d6 scale" {
    for (std.enums.values(Lever)) |lever| {
        const points = leverMod(lever);
        try std.testing.expect(points >= 0 and points <= max_lever_mod);
    }
}

test "leverAllowed refuses each lever for its own reason, and the course refuses it the same way" {
    const dice: Dice = .{ .contact = 7, .decisive = 7, .edge = 7, .pursuit = 7 };
    const Case = struct { avail: Availability, given: []const Order, order: Order, err: LeverError };
    var reserved = test_open;
    reserved.interventions.getPtr(.reinforce).reserved = true;
    var grounded = test_open;
    grounded.air_grounded = true;
    var applied = test_open;
    applied.interventions.getPtr(.field_repair).applied = true;
    var gateless = test_open;
    gateless.interventions.getPtr(.emergency_recon).gate = false;
    var short = test_open;
    short.capacity = leverCost(.reinforce) + leverCost(.air_cover) - 1;
    var no_reserve = test_open;
    no_reserve.reserve_ready = false;
    const cases = [_]Case{
        .{ .avail = no_reserve, .given = &.{}, .order = .commit_reserve, .err = error.ReserveUnavailable },
        .{ .avail = test_open, .given = &.{.commit_reserve}, .order = .commit_reserve, .err = error.IllegalOrder },
        .{ .avail = reserved, .given = &.{}, .order = .{ .intervene = .reinforce }, .err = error.InterventionReservedByEmployer },
        .{ .avail = grounded, .given = &.{}, .order = .{ .intervene = .air_cover }, .err = error.AirCoverGrounded },
        .{ .avail = applied, .given = &.{}, .order = .{ .intervene = .field_repair }, .err = error.InterventionAlreadyApplied },
        .{ .avail = test_open, .given = &.{.{ .intervene = .field_repair }}, .order = .{ .intervene = .field_repair }, .err = error.InterventionAlreadyApplied },
        .{ .avail = gateless, .given = &.{}, .order = .{ .intervene = .emergency_recon }, .err = error.InterventionGateUnmet },
        .{ .avail = short, .given = &.{.{ .intervene = .reinforce }}, .order = .{ .intervene = .air_cover }, .err = error.InsufficientCommandCapacity },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, leverAllowed(case.avail, case.given, case.order));
        // Consumer: the course reaches the same refusal at the contact pause.
        var orders: [max_levers + 2]Order = undefined;
        orders[0] = .engage;
        @memcpy(orders[1 .. 1 + case.given.len], case.given);
        orders[1 + case.given.len] = case.order;
        var in = test_open_inputs;
        in.avail = case.avail;
        try std.testing.expectError(case.err, run(in, dice, orders[0 .. 2 + case.given.len]));
    }
    // Each refusal is its own: what one case refuses, the open availability allows,
    // and the capacity left is exactly enough for one more.
    try leverAllowed(test_open, &.{}, .{ .intervene = .air_cover });
    try leverAllowed(grounded, &.{}, .{ .intervene = .reinforce });
    short.capacity += 1;
    try leverAllowed(short, &.{.{ .intervene = .reinforce }}, .{ .intervene = .air_cover });
    // An order that pulls no lever is not a lever's to refuse.
    try leverAllowed(.{}, &.{}, .press_on);
}

test "the levers move only the decisive roll: the contact pause shows their odds, and the decisive phase their margin" {
    const at = tuning.battle.outcome_at;
    // A decisive die that falls one short of a victory without the levers.
    const momentum = contactVerdict(7, test_mods, .standard).momentum;
    const die: u8 = @intCast(at.victory - 1 - momentum);
    const dice: Dice = .{ .contact = 7, .decisive = die, .edge = 7, .pursuit = 7 };
    const levers = [_]Order{ .engage, .commit_reserve, .{ .intervene = .air_cover } };
    const lever_mod = decisiveMod(&levers);
    const paused = (try run(test_open_inputs, dice, &levers)).paused;
    const bare = (try run(test_open_inputs, dice, &.{.engage})).paused;
    // The contact pause stands: its margin, hits and momentum are contact's.
    try std.testing.expectEqual(Pause.contact, paused.pause);
    try std.testing.expectEqual(bare.margin, paused.margin);
    try std.testing.expectEqual(bare.hits, paused.hits);
    try std.testing.expectEqual(lever_mod, paused.lever_mod);
    try std.testing.expect(paused.reserve_committed);
    try std.testing.expectEqual(leverCost(.air_cover), paused.capacity_spent);
    // Owner and consumer agree on the recomputed odds.
    try std.testing.expectEqualDeep(nextPhaseOdds(.decisive, test_mods, .standard, momentum, lever_mod, false), paused.odds);
    try std.testing.expect(!std.meta.eql(bare.odds, paused.odds));
    // The decisive margin is higher by exactly the levers' modifier.
    const pressed = (try run(test_open_inputs, dice, &(levers ++ [_]Order{.press_on}))).paused;
    const plain = (try run(test_open_inputs, dice, &.{ .engage, .press_on })).paused;
    try std.testing.expectEqual(plain.margin + lever_mod, pressed.margin);
    try std.testing.expect(plain.outcome.? != .victory and pressed.outcome.?.heldField());
    try std.testing.expectEqual(lever_mod, pressed.lever_mod);
    // A withdrawal after levers lands only the contact hits and records the levers.
    const withdrawn = (try run(test_open_inputs, dice, &(levers ++ [_]Order{.withdraw}))).finished;
    try std.testing.expectEqual(bare.hits, withdrawn.hits);
    try std.testing.expectEqual(@as(usize, 2), withdrawn.levers().len);
    try std.testing.expectEqual(Lever.air_cover, withdrawn.levers()[1].lever);
    try std.testing.expectEqual(@as(i32, 0), withdrawn.phases()[1].lever_mod);
}

test "a committed reserve gives up its clamp: a losing roll lands more hits than with the reserve standing" {
    // A rout on the decisive die whatever the reserve adds.
    const dice: Dice = .{ .contact = 7, .decisive = 2, .edge = 2, .pursuit = 7 };
    const stood = (try run(test_open_inputs, dice, &.{ .engage, .press_on, .withdraw })).finished;
    const committed = (try run(test_open_inputs, dice, &.{ .engage, .commit_reserve, .press_on, .withdraw })).finished;
    try std.testing.expect(stood.outcome.isLoss() and committed.outcome.isLoss());
    try std.testing.expect(stood.reserve_steadied and !committed.reserve_steadied);
    try std.testing.expect(committed.reserve_committed and !stood.reserve_committed);
    // Owner and consumer agree: the clamp is decisiveHits' with the reserve present.
    try std.testing.expectEqual(@max(stood.phases()[0].hits, decisiveHits(stood.outcome, .standard, true, 12).hits), stood.hits);
    try std.testing.expectEqual(@max(committed.phases()[0].hits, decisiveHits(committed.outcome, .standard, false, 12).hits), committed.hits);
    try std.testing.expect(committed.hits > stood.hits);
}

test "nextPhaseOdds counts every die result into a band and agrees with the verdict it predicts" {
    const odds = nextPhaseOdds(.decisive, test_mods, .standard, 0, 0, false);
    try std.testing.expectEqual(@as(u16, 36 * 36), odds.total);
    var sum: u32 = 0;
    for (odds.counts) |n| sum += n;
    try std.testing.expectEqual(@as(u32, odds.total), sum);
    // Eleven or more on 2d6 is 3 in 36.
    try std.testing.expectEqual(@as(u16, 3 * 36), odds.counts[@intFromEnum(autoresolve.Outcome.decisive_victory)]);
    // Edge on hand moves odds out of the losing bands.
    const edged = nextPhaseOdds(.decisive, test_mods, .standard, 0, 0, true);
    try std.testing.expect(edged.counts[@intFromEnum(autoresolve.Outcome.rout)] < odds.counts[@intFromEnum(autoresolve.Outcome.rout)]);
    // A lever modifier moves odds out of the losing bands too.
    const levered = nextPhaseOdds(.decisive, test_mods, .standard, 0, 2, false);
    try std.testing.expect(levered.counts[@intFromEnum(autoresolve.Outcome.rout)] < odds.counts[@intFromEnum(autoresolve.Outcome.rout)]);
    const pursuit = nextPhaseOdds(.pursuit, test_mods, .standard, 0, 0, false);
    try std.testing.expectEqual(@as(u16, 36), pursuit.total);
    // Consumer: the contact pause shows the odds under the ROE in force.
    const dice: Dice = .{ .contact = 7, .decisive = 7, .edge = 7, .pursuit = 7 };
    const course = try run(test_inputs, dice, &.{ .engage, .{ .roe = .hold } });
    const momentum = contactVerdict(7, test_mods, .standard).momentum;
    try std.testing.expectEqualDeep(nextPhaseOdds(.decisive, test_mods, .hold, momentum, 0, false), course.paused.odds);
    try std.testing.expect(!std.meta.eql(nextPhaseOdds(.decisive, test_mods, .standard, momentum, 0, false), course.paused.odds));
}

test "a withdrawal after contact gives up the field on the contact hits alone" {
    const dice: Dice = .{ .contact = 2, .decisive = 2, .edge = 2, .pursuit = 2 };
    const out = (try run(test_inputs, dice, &.{ .engage, .withdraw })).finished;
    try std.testing.expect(out.withdrew and !out.held_field);
    try std.testing.expectEqual(autoresolve.Outcome.draw, out.outcome);
    try std.testing.expectEqual(force.Roe.cautious, out.recovery_roe);
    try std.testing.expectEqual(lineHits(12, contactVerdict(2, test_mods, .standard).hit_pct), out.hits);
    try std.testing.expectEqual(@as(usize, 2), out.phases().len);
    try std.testing.expectEqual(phase_mod.Phase.withdrawal, out.phases()[1].phase);
}

test "recordConsistent accepts what the course produces and refuses a forged record" {
    const a = std.testing.allocator;
    const dice: Dice = .{ .contact = 7, .decisive = 9, .edge = 7, .pursuit = 7 };
    var record: phase_mod.BattleInProgress = .{ .contract = @enumFromInt(1), .phase = .contact };
    defer record.steps.deinit(a);
    // Consumer: every pause the course reaches, recorded, is consistent.
    const orders = [_]Order{ .engage, .{ .roe = .cautious }, .press_on };
    for (orders, 1..) |order, n| {
        const report = (try run(test_inputs, dice, orders[0..n])).paused;
        try record.steps.append(a, .{ .order = order, .report = report });
        record.phase = report.pause;
        try std.testing.expect(recordConsistent(&record));
    }
    const good = record.steps.items[2];
    record.phase = .contact;
    try std.testing.expect(!recordConsistent(&record));
    record.phase = .decisive;
    record.steps.items[2].report.held_field = !good.report.held_field;
    try std.testing.expect(!recordConsistent(&record));
    record.steps.items[2] = good;
    record.steps.items[2].report.odds.total += 1;
    try std.testing.expect(!recordConsistent(&record));
    record.steps.items[2] = good;
    record.steps.items[2].order = .consolidate;
    try std.testing.expect(!recordConsistent(&record));
    record.steps.items[2] = good;
    record.steps.items[1].report.roe = .hold;
    try std.testing.expect(!recordConsistent(&record));
}

test "recordConsistent accepts the levers the course records and refuses forged lever figures or a repeat" {
    const a = std.testing.allocator;
    const dice: Dice = .{ .contact = 7, .decisive = 7, .edge = 7, .pursuit = 7 };
    var record: phase_mod.BattleInProgress = .{ .contract = @enumFromInt(1), .phase = .contact };
    defer record.steps.deinit(a);
    // Consumer: every pause the course reaches with levers, recorded, is consistent.
    const orders = [_]Order{ .engage, .commit_reserve, .{ .intervene = .reinforce }, .press_on };
    for (orders, 1..) |order, n| {
        const report = (try run(test_open_inputs, dice, orders[0..n])).paused;
        try record.steps.append(a, .{ .order = order, .report = report });
        record.phase = report.pause;
        try std.testing.expect(recordConsistent(&record));
    }
    // The decisive pause carries every lever's figures.
    try std.testing.expectEqual(decisiveMod(&orders), record.latest().lever_mod);
    try std.testing.expect(record.latest().reserve_committed);
    try std.testing.expectEqual(leverCost(.reinforce), record.latest().capacity_spent);
    for (record.steps.items, 0..) |good, i| {
        record.steps.items[i].report.lever_mod += 1;
        try std.testing.expect(!recordConsistent(&record));
        record.steps.items[i] = good;
        record.steps.items[i].report.capacity_spent +%= 1;
        try std.testing.expect(!recordConsistent(&record));
        record.steps.items[i] = good;
        record.steps.items[i].report.reserve_committed = !good.report.reserve_committed;
        try std.testing.expect(!recordConsistent(&record));
        record.steps.items[i] = good;
    }
    try std.testing.expect(recordConsistent(&record));
    // The same lever twice is never a course the command records.
    record.steps.items[2].order = .commit_reserve;
    try std.testing.expect(!recordConsistent(&record));
}

/// The fields a finished course gives its report (`battle.assembleReport`).
fn reportForTest(final: *const Final) battle_report.BattleReport {
    return .{
        .id = @enumFromInt(1),
        .day = 0,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "",
        .enemy_key = "",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = final.outcome,
        .held_field = final.held_field,
        .withdrew = final.withdrew,
        .roe = final.roe,
        .hits_taken = final.hits,
        .phases = final.phases(),
        .levers = final.levers(),
    };
}

test "reportPhasesConsistent accepts the levers a course records and refuses forged, repeated or unfought ones" {
    const dice: Dice = .{ .contact = 7, .decisive = 7, .edge = 7, .pursuit = 7 };
    // Consumer: a fought course with levers, and a withdrawal after them, are accepted.
    const fought = (try run(test_open_inputs, dice, &.{ .engage, .commit_reserve, .{ .intervene = .emergency_recon }, .press_on, .consolidate })).finished;
    const withdrawn = (try run(test_open_inputs, dice, &.{ .engage, .{ .intervene = .air_cover }, .withdraw })).finished;
    for ([_]*const Final{ &fought, &withdrawn }) |final| {
        const good = reportForTest(final);
        try std.testing.expect(good.levers.len > 0);
        try std.testing.expect(reportPhasesConsistent(&good));
        var levers: [max_levers]battle_report.BattleLever = undefined;
        @memcpy(levers[0..good.levers.len], good.levers);
        var forged = good;
        forged.levers = levers[0..good.levers.len];
        // A cost or a modifier other than the owners give.
        levers[0].cost += 1;
        try std.testing.expect(!reportPhasesConsistent(&forged));
        levers[0] = good.levers[0];
        levers[0].roll_mod += 1;
        try std.testing.expect(!reportPhasesConsistent(&forged));
        levers[0] = good.levers[0];
        // The same lever twice.
        levers[good.levers.len] = good.levers[0];
        forged.levers = levers[0 .. good.levers.len + 1];
        try std.testing.expect(!reportPhasesConsistent(&forged));
    }
    // A decisive phase whose lever modifier is not the levers' sum, or a report missing a lever.
    const good = reportForTest(&fought);
    var phases: [max_phases]PhaseRecord = undefined;
    @memcpy(&phases, good.phases);
    var forged = good;
    forged.phases = &phases;
    phases[1].lever_mod -= 1;
    phases[1].margin -= 1;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    @memcpy(&phases, good.phases);
    forged.levers = good.levers[0..1];
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged.levers = good.levers;
    // Contact carries no lever modifier.
    phases[0].lever_mod = 1;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    @memcpy(&phases, good.phases);
    try std.testing.expect(reportPhasesConsistent(&forged));
    // A concession or a forfeit fights no phase and pulls no lever.
    for ([_]bool{ true, false }) |conceded| {
        var unfought = unfoughtForTest(conceded);
        try std.testing.expect(reportPhasesConsistent(&unfought));
        unfought.levers = good.levers;
        try std.testing.expect(!reportPhasesConsistent(&unfought));
    }
}

test "reportPhasesConsistent accepts every course run finishes and refuses a truncated or forged one" {
    // Consumer: every finished course, over every die and order, is accepted
    // as the report the battle publishes from it.
    var finished: usize = 0;
    for (2..13) |die| for ([_]force.Roe{ .hold, .standard, .cautious }) |roe| {
        const dice: Dice = .{ .contact = @intCast(die), .decisive = @intCast(die), .edge = 12, .pursuit = @intCast(14 - die) };
        const in: Inputs = .{ .mods = test_mods, .roe = .standard, .engaged = 12, .edge_available = die % 2 == 0, .reserve_present = false };
        const courses = [_][]const Order{
            &.{ .engage, .withdraw },
            &.{ .engage, .{ .roe = roe }, .withdraw },
            &.{ .engage, .{ .roe = roe }, .press_on, .pursue },
            &.{ .engage, .{ .roe = roe }, .press_on, .consolidate },
            &.{ .engage, .{ .roe = roe }, .press_on, .cover_recovery },
            &.{ .engage, .{ .roe = roe }, .press_on, .withdraw },
        };
        for (courses) |orders| {
            const course = run(in, dice, orders) catch continue;
            const report = reportForTest(&course.finished);
            try std.testing.expect(reportPhasesConsistent(&report));
            finished += 1;
        }
        // And every one of them with every lever pulled first.
        var open = in;
        open.reserve_present = true;
        open.avail = test_open;
        const levers = [_]Order{ .engage, .commit_reserve, .{ .intervene = .emergency_recon }, .{ .intervene = .reinforce }, .{ .intervene = .air_cover }, .{ .intervene = .field_repair } };
        for (courses) |orders| {
            var levered: [levers.len + 3]Order = undefined;
            @memcpy(levered[0..levers.len], &levers);
            @memcpy(levered[levers.len .. levers.len + orders.len - 1], orders[1..]);
            const course = run(open, dice, levered[0 .. levers.len + orders.len - 1]) catch continue;
            const report = reportForTest(&course.finished);
            try std.testing.expectEqual(@as(usize, max_levers), report.levers.len);
            try std.testing.expect(reportPhasesConsistent(&report));
            finished += 1;
        }
    };
    try std.testing.expect(finished > 0);

    const dice: Dice = .{ .contact = 7, .decisive = 12, .edge = 7, .pursuit = 4 };
    const pursued = (try run(test_inputs, dice, &.{ .engage, .press_on, .pursue })).finished;
    const good = reportForTest(&pursued);
    try std.testing.expect(good.held_field and good.phases[2].hits > 0);
    var phases: [max_phases]PhaseRecord = undefined;
    @memcpy(&phases, good.phases);
    var forged = good;
    forged.phases = &phases;
    // Truncated: no terminal phase, or only contact.
    forged.phases = phases[0..2];
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged.phases = phases[0..1];
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged.phases = &phases;
    // A verdict the decisive margin does not earn, or a field it does not leave.
    forged.outcome = .rout;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged = good;
    forged.phases = &phases;
    forged.held_field = false;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged = good;
    forged.phases = &phases;
    // Hits the phases do not add up to.
    forged.hits_taken += 1;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged = good;
    forged.phases = &phases;
    // Momentum another contact band carries, and a costly pursuit taking no hits.
    phases[1].momentum += 1;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    @memcpy(&phases, good.phases);
    phases[2].hits = 0;
    forged.hits_taken -= good.phases[2].hits;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    forged = good;
    @memcpy(&phases, good.phases);
    forged.phases = &phases;
    // An order not legal after a held field, and the ROE changed after contact.
    phases[2].order = .cover_recovery;
    phases[2].phase = .withdrawal;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    @memcpy(&phases, good.phases);
    phases[2].roe = if (phases[1].roe == .hold) .standard else .hold;
    try std.testing.expect(!reportPhasesConsistent(&forged));
    @memcpy(&phases, good.phases);
    try std.testing.expect(reportPhasesConsistent(&forged));
}

/// A report with no phases, as `battle.concede` (conceded) or
/// `battle.forfeit` writes it.
fn unfoughtForTest(conceded: bool) battle_report.BattleReport {
    var r = reportForTest(&.{ .outcome = if (conceded) .defeat else .victory, .held_field = !conceded, .withdrew = false, .hits = 0, .hit_pct = 0, .reserve_steadied = false, .edge_used = false, .roe = .standard, .recovery_roe = .standard });
    r.conceded = conceded;
    return r;
}

test "reportPhasesConsistent: only a concession or a forfeit fights no phase" {
    const hulls = [_]battle_report.HullHit{.{ .unit = @enumFromInt(1), .chassis_key = "x", .chassis_name = "X", .armor_before = 90, .armor_after = 70 }};
    for ([_]bool{ true, false }) |conceded| {
        const genuine = unfoughtForTest(conceded);
        try std.testing.expect(reportPhasesConsistent(&genuine));
        // Anything a fight measured, cost or earned.
        inline for (.{ "player_power", "enemy_power", "hits_taken", "destroyed", "wounded", "kia", "lost_hulls", "missing", "battle_loss_comp", "enemy_destroyed_bv", "kills_credited", "prisoners" }) |field| {
            var forged = genuine;
            @field(forged, field) = 1;
            try std.testing.expect(!reportPhasesConsistent(&forged));
        }
        var forged = genuine;
        forged.hulls = &hulls;
        try std.testing.expect(!reportPhasesConsistent(&forged));
        forged = genuine;
        forged.withdrew = true;
        try std.testing.expect(!reportPhasesConsistent(&forged));
        // The other one-step verdict, or the other field, under this flag.
        forged = genuine;
        forged.outcome = if (conceded) .victory else .defeat;
        try std.testing.expect(!reportPhasesConsistent(&forged));
        forged = genuine;
        forged.held_field = conceded;
        try std.testing.expect(!reportPhasesConsistent(&forged));
    }
    // Consumer: a fought course's report stripped of its phases is refused,
    // and a concession cannot carry a fought course.
    const dice: Dice = .{ .contact = 7, .decisive = 9, .edge = 7, .pursuit = 7 };
    const course = (try run(test_inputs, dice, &.{ .engage, .press_on, .consolidate })).finished;
    var fought = reportForTest(&course);
    try std.testing.expect(reportPhasesConsistent(&fought));
    fought.conceded = true;
    try std.testing.expect(!reportPhasesConsistent(&fought));
    fought.conceded = false;
    fought.phases = &.{};
    try std.testing.expect(!reportPhasesConsistent(&fought));
}

test "courseForTest gives every outcome a course the report check accepts" {
    inline for (@typeInfo(autoresolve.Outcome).@"enum".fields) |field| {
        const outcome: autoresolve.Outcome = @enumFromInt(field.value);
        var r = reportForTest(&.{ .outcome = outcome, .held_field = heldField(outcome, .standard), .withdrew = false, .hits = 0, .hit_pct = 0, .reserve_steadied = false, .edge_used = false, .roe = .standard, .recovery_roe = .standard });
        r.phases = courseForTest(outcome);
        try std.testing.expect(reportPhasesConsistent(&r));
        r.held_field = !r.held_field;
        try std.testing.expect(!reportPhasesConsistent(&r));
    }
}

test "reportPhasesConsistent refuses a phase margin no 2d6 die earns" {
    // At each end of the 2d6 range, every rolled phase of a genuine course
    // is accepted, and the same phase one past that end is refused; the band
    // the margin falls in, and so every other figure, is unchanged.
    var checked: usize = 0;
    for ([_]struct { die: u8, past: i32 }{ .{ .die = rng_mod.roll2d6_min, .past = -1 }, .{ .die = rng_mod.roll2d6_max, .past = 1 } }) |end| {
        const dice: Dice = .{ .contact = end.die, .decisive = end.die, .edge = end.die, .pursuit = end.die };
        for ([_]Order{ .pursue, .cover_recovery }) |last| {
            const course = run(test_inputs, dice, &.{ .engage, .press_on, last }) catch continue;
            const good = reportForTest(&course.finished);
            try std.testing.expect(reportPhasesConsistent(&good));
            var phases: [max_phases]PhaseRecord = undefined;
            for (0..max_phases) |k| {
                @memcpy(&phases, good.phases);
                phases[k].margin += end.past;
                var forged = good;
                forged.phases = &phases;
                try std.testing.expect(!reportPhasesConsistent(&forged));
                checked += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2 * max_phases), checked);

    // A clean pursuit whose margin claims a die of 200, and margins so far
    // out that only checked arithmetic keeps them out of the range.
    const held: Dice = .{ .contact = 7, .decisive = 12, .edge = 7, .pursuit = 12 };
    const good = reportForTest(&(try run(test_inputs, held, &.{ .engage, .press_on, .pursue })).finished);
    try std.testing.expect(reportPhasesConsistent(&good));
    var phases: [max_phases]PhaseRecord = undefined;
    var forged = good;
    forged.phases = &phases;
    for ([_]i32{ 200 - tuning.battle.phases.par, std.math.maxInt(i32), std.math.minInt(i32) }) |margin| {
        @memcpy(&phases, good.phases);
        phases[2].margin = margin;
        try std.testing.expect(!reportPhasesConsistent(&forged));
    }
    // Modifiers that move the die out of range under an unchanged margin.
    for ([_]i32{ 100, -100, std.math.maxInt(i32), std.math.minInt(i32) }) |shift| {
        @memcpy(&phases, good.phases);
        phases[0].ratio_bonus = shift;
        phases[1].ratio_bonus = shift;
        try std.testing.expect(!reportPhasesConsistent(&forged));
    }
}

test "defaultOrder walks a battle to its end, legally at every pause" {
    try std.testing.expectEqual(Order.engage, defaultOrder(null));
    var report: PhaseReport = .{ .pause = .contact, .margin = 0, .hits = 0, .momentum = 0, .roe = .standard };
    try std.testing.expectEqual(Order.press_on, defaultOrder(&report));
    report = .{ .pause = .decisive, .margin = 0, .hits = 0, .momentum = 0, .roe = .standard, .outcome = .rout };
    try std.testing.expectEqual(Order.withdraw, defaultOrder(&report));
    report.held_field = true;
    try std.testing.expectEqual(Order.consolidate, defaultOrder(&report));
    // Consumer: the unattended course these orders give always finishes.
    for (2..13) |die| {
        const dice: Dice = .{ .contact = @intCast(die), .decisive = @intCast(die), .edge = 7, .pursuit = 7 };
        var orders: [max_phases]Order = undefined;
        orders[0] = defaultOrder(null);
        var n: usize = 1;
        while (true) switch (try run(test_inputs, dice, orders[0..n])) {
            .finished => break,
            .paused => |r| {
                try std.testing.expect(orderLegal(r.pause, r.held_field, defaultOrder(&r)));
                orders[n] = defaultOrder(&r);
                n += 1;
            },
        };
    }
}
