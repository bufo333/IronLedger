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
const rng_mod = @import("rng.zig");
const GameState = @import("state.zig").GameState;
const commands = @import("commands.zig");

const Order = phase_mod.Order;
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

fn decisiveRoll(die: u8, mods: Mods, roe: force.Roe, momentum: i32) i32 {
    return @as(i32, die) + mods.ratio_bonus + mods.scenario_mod + roeRoll(roe) + momentum;
}

pub const Decisive = struct {
    roll: i32,
    margin: i32,
    outcome: autoresolve.Outcome,
    edge_used: bool,
};

/// The decisive phase: decisive die + power ratio + scenario + the ROE roll
/// in force + contact momentum, banded by `tuning.battle.outcome_at`. A roll
/// that loses the fight is re-rolled once on the Edge die when a pilot in the
/// line has Edge to spend (ARCH §7).
pub fn decisiveVerdict(dice: Dice, mods: Mods, roe: force.Roe, momentum: i32, edge_available: bool) Decisive {
    var roll = decisiveRoll(dice.decisive, mods, roe, momentum);
    var edge_used = false;
    if (roll < tuning.battle.outcome_at.draw and edge_available) {
        roll = decisiveRoll(dice.edge, mods, roe, momentum);
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
/// that is due and not yet engaged.
pub fn legalOrders(pause: ?Pause, held_field: bool) []const Order.Kind {
    const p = pause orelse return &.{.engage};
    return switch (p) {
        .contact => &.{ .press_on, .withdraw, .roe },
        .decisive => if (held_field) &.{ .pursue, .consolidate } else &.{ .cover_recovery, .withdraw },
    };
}

pub fn orderLegal(pause: ?Pause, held_field: bool, order: Order) bool {
    for (legalOrders(pause, held_field)) |kind| if (kind == std.meta.activeTag(order)) return true;
    return false;
}

/// The exact odds of the next phase: every 2d6 result of its die (and of the
/// Edge die after a losing decisive roll, when Edge is available) counted
/// into its band. Pure; consumes no RNG.
pub fn nextPhaseOdds(next: NextPhase, mods: Mods, roe: force.Roe, momentum: i32, edge_available: bool) Odds {
    var odds: Odds = .{ .next = next };
    for (1..7) |a| for (1..7) |b| {
        const die: u8 = @intCast(a + b);
        switch (next) {
            .decisive => {
                if (decisiveRoll(die, mods, roe, momentum) < tuning.battle.outcome_at.draw and edge_available) {
                    for (1..7) |c| for (1..7) |d| {
                        const edge_die: u8 = @intCast(c + d);
                        const v = decisiveVerdict(.{ .contact = 0, .decisive = die, .edge = edge_die, .pursuit = 0 }, mods, roe, momentum, true);
                        odds.counts[@intFromEnum(v.outcome)] += 1;
                    };
                } else {
                    const v = decisiveVerdict(.{ .contact = 0, .decisive = die, .edge = 0, .pursuit = 0 }, mods, roe, momentum, false);
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
};

pub const max_phases = 3;

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

    pub fn phases(self: *const Final) []const PhaseRecord {
        return self.records[0..self.record_count];
    }

    fn push(self: *Final, record: PhaseRecord) void {
        self.records[self.record_count] = record;
        self.record_count += 1;
    }
};

pub const Course = union(enum) {
    paused: PhaseReport,
    finished: Final,
};

/// The engagement's course under an ordered list of orders: a pure function
/// of what it brings, its fixed dice and the orders. Returns the pause the
/// last order reached, or the finished verdict; `error.IllegalOrder` when an
/// order is not legal where it is given (`legalOrders`).
pub fn run(in: Inputs, dice: Dice, orders: []const Order) error{IllegalOrder}!Course {
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

    // The contact pause: ROE changes, then press on or withdraw.
    var roe = in.roe;
    var i: usize = 1;
    while (i < orders.len) : (i += 1) {
        if (!orderLegal(.contact, false, orders[i])) return error.IllegalOrder;
        switch (orders[i]) {
            .roe => |r| roe = r,
            else => break,
        }
    }
    if (i == orders.len) return .{ .paused = .{
        .pause = .contact,
        .margin = contact.margin,
        .hits = contact_hits,
        .momentum = contact.momentum,
        .roe = roe,
        .odds = nextPhaseOdds(.decisive, in.mods, roe, contact.momentum, in.edge_available),
    } };
    final.roe = roe;
    if (orders[i] == .withdraw) {
        if (i + 1 != orders.len) return error.IllegalOrder;
        final.withdrew = true;
        final.recovery_roe = .cautious;
        final.push(.{ .phase = .withdrawal, .order = .withdraw, .roe = roe });
        return .{ .finished = final };
    }

    // The decisive phase.
    const decisive = decisiveVerdict(dice, in.mods, roe, contact.momentum, in.edge_available);
    const total = decisiveHits(decisive.outcome, roe, in.reserve_present, in.engaged);
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
    final.push(.{ .phase = .decisive, .order = .press_on, .roe = roe, .ratio_bonus = in.mods.ratio_bonus, .scenario_mod = in.mods.scenario_mod, .roe_roll = roeRoll(roe), .momentum = contact.momentum, .margin = decisive.margin, .hits = so_far - contact_hits });
    i += 1;
    if (i == orders.len) return .{ .paused = .{
        .pause = .decisive,
        .margin = decisive.margin,
        .hits = so_far,
        .momentum = contact.momentum,
        .roe = roe,
        .outcome = decisive.outcome,
        .held_field = held,
        .odds = nextPhaseOdds(if (held) .pursuit else .cover, in.mods, roe, contact.momentum, in.edge_available),
    } };

    // Pursuit or withdrawal ends the battle.
    const last = orders[i];
    if (i + 1 != orders.len or !orderLegal(.decisive, held, last)) return error.IllegalOrder;
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
        .engage, .press_on, .roe => unreachable,
    }
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
/// no order ended the battle, each report's pause, verdict, field and odds
/// agree with the order that reached it, and the record stands at its last
/// report's pause. The loader refuses anything else (rule 47).
pub fn recordConsistent(record: *const phase_mod.BattleInProgress) bool {
    if (record.steps.items.len == 0) return false;
    var pause: ?Pause = null;
    var held = false;
    for (record.steps.items) |step| {
        const r = step.report;
        if (!orderLegal(pause, held, step.order)) return false;
        const reached: Pause = switch (step.order) {
            .engage => .contact,
            .roe => |roe| blk: {
                if (r.roe != roe) return false;
                break :blk .contact;
            },
            .press_on => .decisive,
            .withdraw, .pursue, .consolidate, .cover_recovery => return false,
        };
        if (r.pause != reached) return false;
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
/// report's. Only a concession or a forfeit fights no phase
/// (`unfoughtConsistent`). The loader refuses anything else (rule 47).
pub fn reportPhasesConsistent(report: *const battle_report.BattleReport) bool {
    const phases = report.phases;
    if (phases.len == 0) return unfoughtConsistent(report);
    if (report.conceded) return false;
    const contact = phases[0];
    if (contact.phase != .contact or contact.order != .engage) return false;
    if (contact.roe_roll != roeRoll(contact.roe) or contact.momentum != 0) return false;
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
            // The decisive die or, after a losing roll, the Edge die.
            if (!marginFeasible(d.margin, &.{ d.ratio_bonus, d.scenario_mod, d.roe_roll, d.momentum })) return false;
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
        .engage, .press_on, .roe => return false,
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
    try std.testing.expectEqual(autoresolve.Outcome.victory, decisiveVerdict(dice, test_mods, .standard, 0, false).outcome);
    try std.testing.expectEqual(autoresolve.Outcome.draw, decisiveVerdict(dice, test_mods, .standard, -(at.victory - at.draw), false).outcome);
    // A winning roll keeps its die even with Edge on hand.
    try std.testing.expect(!decisiveVerdict(dice, test_mods, .standard, 0, true).edge_used);
    const losing: Dice = .{ .contact = 7, .decisive = 2, .edge = 12, .pursuit = 7 };
    const spent = decisiveVerdict(losing, test_mods, .standard, 0, true);
    try std.testing.expect(spent.edge_used);
    try std.testing.expectEqual(outcomeAt(12), spent.outcome);
    try std.testing.expectEqual(autoresolve.Outcome.rout, decisiveVerdict(losing, test_mods, .standard, 0, false).outcome);
    // Consumer: the course's decisive pause shows the same verdict.
    const course = try run(test_inputs, dice, &.{ .engage, .press_on });
    try std.testing.expectEqual(decisiveVerdict(dice, test_mods, .standard, contactVerdict(7, test_mods, .standard).momentum, false).outcome, course.paused.outcome.?);
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
    const decisive = decisiveVerdict(dice, test_mods, .standard, contactVerdict(2, test_mods, .standard).momentum, false);
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
            inline else => |k| @unionInit(Order, @tagName(k), {}),
        };
        _ = try run(test_inputs, dice, &.{ .engage, order });
    }
}

test "nextPhaseOdds counts every die result into a band and agrees with the verdict it predicts" {
    const odds = nextPhaseOdds(.decisive, test_mods, .standard, 0, false);
    try std.testing.expectEqual(@as(u16, 36 * 36), odds.total);
    var sum: u32 = 0;
    for (odds.counts) |n| sum += n;
    try std.testing.expectEqual(@as(u32, odds.total), sum);
    // Eleven or more on 2d6 is 3 in 36.
    try std.testing.expectEqual(@as(u16, 3 * 36), odds.counts[@intFromEnum(autoresolve.Outcome.decisive_victory)]);
    // Edge on hand moves odds out of the losing bands.
    const edged = nextPhaseOdds(.decisive, test_mods, .standard, 0, true);
    try std.testing.expect(edged.counts[@intFromEnum(autoresolve.Outcome.rout)] < odds.counts[@intFromEnum(autoresolve.Outcome.rout)]);
    const pursuit = nextPhaseOdds(.pursuit, test_mods, .standard, 0, false);
    try std.testing.expectEqual(@as(u16, 36), pursuit.total);
    // Consumer: the contact pause shows the odds under the ROE in force.
    const dice: Dice = .{ .contact = 7, .decisive = 7, .edge = 7, .pursuit = 7 };
    const course = try run(test_inputs, dice, &.{ .engage, .{ .roe = .hold } });
    const momentum = contactVerdict(7, test_mods, .standard).momentum;
    try std.testing.expectEqualDeep(nextPhaseOdds(.decisive, test_mods, .hold, momentum, false), course.paused.odds);
    try std.testing.expect(!std.meta.eql(nextPhaseOdds(.decisive, test_mods, .standard, momentum, false), course.paused.odds));
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
    };
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
