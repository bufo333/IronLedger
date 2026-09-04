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
    damage_random_units: u8, // N units take abstract battle wear
    parts_windfall: u8, // salvaged spares into the pool
    supply_loss: types.CBills, // posted as a supplies expense
};

pub const Option = struct {
    label: []const u8,
    effects: []const Effect = &.{},
};

pub const Event = struct {
    day: u32,
    kind: EventKind,
    contract: types.ContractId = .none,
    company: types.ForceId = .none,
    /// Empty = auto event (applied at roll time, never queued).
    options: []const Option = &.{},
    /// Applied automatically at the deadline if the player never answers.
    default_choice: usize = 0,
    deadline_day: u32 = 0,
    chosen: ?usize = null,

    pub fn needsDecision(self: *const Event) bool {
        return self.options.len > 0 and self.chosen == null;
    }
};

/// The decision inbox: pending events awaiting the player, oldest first.
pub const EventQueue = struct {
    pending: std.ArrayListUnmanaged(Event) = .empty,

    pub fn deinit(self: *EventQueue, alloc: std.mem.Allocator) void {
        self.pending.deinit(alloc);
    }

    pub fn push(self: *EventQueue, alloc: std.mem.Allocator, ev: Event) !void {
        try self.pending.append(alloc, ev);
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
