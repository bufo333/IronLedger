//! Events & the decision inbox (ARCH §8) — turn-based.
//!
//! Time never stops for an event. Auto events apply during the tick and go
//! to the log; decision events land in the INBOX with a deadline some days
//! out. The player resolves them between turns; past the deadline the
//! default option applies automatically (and the log notes it). Ignoring
//! your inbox is a choice with consequences, not an impossibility.

const std = @import("std");
const types = @import("../domain/types.zig");

pub const EventKind = enum {
    // Garrison-class deck:
    quiet_month,
    pirate_raid,
    disease_outbreak,
    logistics_failure,
    civil_disturbance,
    sports_riot,
    bonus_payment,
    equipment_cache,
    off_contract_request,
    // Combat-class deck:
    betrayal,
    supply_interdiction,
    enemy_reinforcements,
    heavy_fighting,
    intel_windfall,
    captured_salvage,
    local_support_offer,
    daring_opportunity,
    // Weekly deck (Stage 12): smaller happenings between the monthly ones.
    quiet_week,
    local_festival,
    press_visit,
    training_exercise,
    smuggler_offer,
    employer_inspection,
    ambush_warning,
    prisoner_exchange,
    night_raid,
    supply_cache,
    bad_weather,
    field_promotion,
    // Stage 12.22, hooked into faction standing:
    black_market_contact,
    salvage_dispute,
    /// Personnel (Stage 12.25): someone restless hands in notice.
    notice_given,
    /// A prisoner of war held by the company (12B.7).
    prisoner_held,
    /// One of yours left behind on a lost field, held by the enemy (12D.3).
    mia_held,
    /// Raiders waiting at the jump point for an unescorted company (12D.9).
    jump_interdiction,
    /// The field is held and the enemy is off balance (12G.6): press the
    /// advance, or consolidate and put the company back together.
    press_or_consolidate,
    /// The field is lost and hulls and people are still out there
    /// (12G.6): go back for them tonight, or let them go.
    recovery_push,

    /// Does this decision hold the turn (ARCH §6)? The test is what the
    /// decision disposes of, not how big it feels: a battle decision
    /// spends hulls, people and the contract's tempo and has no safe
    /// default to lapse to, so time waits for it. Everything else —
    /// money, fatigue, standing, a bonus — defaults at its deadline,
    /// because ignoring your inbox is a choice, not an impossibility.
    pub fn blocksTurn(self: EventKind) bool {
        return switch (self) {
            .press_or_consolidate, .recovery_push => true,
            else => false,
        };
    }
};

/// One consequence of an event option. Relative where it must scale
/// (contract pay), absolute where flat money reads better.
pub const Effect = union(enum) {
    cash: types.CBills,
    cash_monthly_pct: i16, // % of the contract's monthly_net
    reputation: i16,
    morale: i8, // applied to everyone in the company
    fatigue: u8,
    xp_all: u16,
    score: i16, // contract success score (drives Stage 7 outcomes)
    damage_random_units: u8, // N line-lance hulls take abstract battle wear
    damage_convoy_units: u8, // N support-echelon vehicles (trucks, ambulances) take wear
    parts_windfall: u8, // salvaged spares into the pool
    supply_loss: types.CBills, // posted as a supplies expense
    /// Standing with the contract's employer (Stage 12.22).
    employer_standing: i16,
    /// Stock landed in the company's field stores (munitions off the books).
    field_stock: struct { key: []const u8, qty: u16 },
    // Personnel effects (Stage 12.25) act on the event's `person`.
    /// Permanent raise, percent of the current salary; they stay.
    raise_pct: u8,
    /// One-off bonus of N months' salary from the outfit; they stay.
    retention_bonus_months: u8,
    /// They leave; seats are vacated.
    let_go,
    /// They leave, and the halls are asked for a replacement in the same
    /// role (hired into the same company if one is listed).
    replace_from_hall,
    // Prisoner effects (12B.7) act on the event's `person`, a POW.
    /// Their house pays by experience; they go home.
    ransom_prisoner,
    /// Released unpaid: +2 standing with their house.
    release_prisoner,
    /// A loyalty roll; success puts them on your payroll as a mekwarrior.
    recruit_prisoner,
    // Missing-in-action effects (12D.3) act on the event's `person`, one of
    // yours held by the house in their `faction`.
    /// Pay their captors the ransom table's price; they come home.
    ransom_mia,
    /// Hand over a prisoner of that house you hold; they come home.
    exchange_mia,
    /// Missing, presumed dead: the company mourns.
    write_off_mia,
    /// Fight it out (12D.6): a real engagement against the contract's
    /// opposition, resolved on the spot.
    engagement,
    /// The employer takes the company's most battered line hull as
    /// "collateral" (12D.9) — off the books for good.
    seize_hull,
    /// Days added to a company's transit (12D.9: waiting raiders out).
    delay_arrival: u8,
    /// The next engagement on this contract comes in N days rather than
    /// when the usual gap would have put it (12G.6).
    next_battle_in: u8,
    /// One more recovery roll for every hull and pilot the event's battle
    /// left on the field (12G.6), at a price in fatigue and risk.
    recovery_push,
};

pub const Option = struct {
    label: []const u8,
    effects: []const Effect = &.{},
};

pub const Event = struct {
    /// Stamped by `EventQueue.push`; `.none` until then.
    id: types.EventId = .none,
    day: u32,
    kind: EventKind,
    contract: types.ContractId = .none,
    company: types.ForceId = .none,
    /// Personnel events: who this is about.
    person: types.PersonId = .none,
    /// Battle decisions (12G.6): the engagement this is about, so the
    /// answer can be applied against that fight's record.
    battle: types.BattleId = .none,
    /// Empty = auto event (applied at roll time, never queued).
    options: []const Option = &.{},
    /// Applied automatically at the deadline if the player never answers.
    default_choice: usize = 0,
    deadline_day: u32 = 0,
    chosen: ?usize = null,

    pub fn needsDecision(self: *const Event) bool {
        return self.options.len > 0 and self.chosen == null;
    }

    /// Unanswered and holding the turn (12G.6).
    pub fn holdsTurn(self: *const Event) bool {
        return self.needsDecision() and self.kind.blocksTurn();
    }
};

/// The decision inbox: pending events awaiting the player, oldest first.
pub const EventQueue = struct {
    pending: std.ArrayListUnmanaged(Event) = .empty,
    /// Stamped onto each event as it is queued, so an answer names an
    /// event rather than a row (12G.1). Never reused within a campaign.
    next_id: u32 = 1,

    pub fn deinit(self: *EventQueue, alloc: std.mem.Allocator) void {
        self.pending.deinit(alloc);
    }

    /// Queue an event, stamping it with the next id. Callers leave
    /// `ev.id` unset; the queue owns the numbering.
    pub fn push(self: *EventQueue, alloc: std.mem.Allocator, ev: Event) !void {
        var stamped = ev;
        stamped.id = @enumFromInt(self.next_id);
        self.next_id += 1;
        try self.pending.append(alloc, stamped);
    }

    /// The pending event with this id, or null once it has been answered
    /// or has expired. Every consumer looks an event up this way — a row
    /// index is only ever a cursor position (rule 17).
    pub fn find(self: *EventQueue, id: types.EventId) ?*Event {
        if (id == .none) return null;
        for (self.pending.items) |*ev| if (ev.id == id) return ev;
        return null;
    }

    /// Where that event sits today, for the one caller that must remove it.
    pub fn indexOf(self: *const EventQueue, id: types.EventId) ?usize {
        if (id == .none) return null;
        for (self.pending.items, 0..) |ev, i| if (ev.id == id) return i;
        return null;
    }

    /// After a load, resume numbering past everything restored.
    pub fn resumeIds(self: *EventQueue) void {
        var max: u32 = 0;
        for (self.pending.items) |ev| max = @max(max, @intFromEnum(ev.id));
        self.next_id = max + 1;
    }

    /// The oldest pending decision that holds the turn, if any (12G.6).
    /// One place decides; `advance` and the checklist both read it.
    pub fn blocking(self: *const EventQueue) ?*const Event {
        for (self.pending.items) |*ev| if (ev.holdsTurn()) return ev;
        return null;
    }

    pub fn unresolvedCount(self: *const EventQueue) usize {
        var n: usize = 0;
        for (self.pending.items) |ev| {
            if (ev.needsDecision()) n += 1;
        }
        return n;
    }
};

test "events carry options with typed effects" {
    const ev: Event = .{
        .day = 3,
        .kind = .off_contract_request,
        .deadline_day = 10,
        .options = &.{
            .{ .label = "Accept", .effects = &.{ .{ .cash_monthly_pct = 150 }, .{ .reputation = -2 } } },
            .{ .label = "Decline", .effects = &.{.{ .reputation = 1 }} },
        },
        .default_choice = 1,
    };
    try std.testing.expect(ev.needsDecision());
    try std.testing.expectEqual(@as(usize, 2), ev.options.len);
}
