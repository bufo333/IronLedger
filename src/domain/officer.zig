//! Persistent officer arcs and the task-performance model.
//! No MekHQ counterpart (P4 operations design §§3,5); officer arcs ride on
//! existing personnel (ROADMAP P4h.6).

const std = @import("std");
const types = @import("types.zig");

/// The ToE seat that selected this officer.
pub const OfficerSeat = enum {
    company_commander,
    lance_leader,

    /// Short display label.
    pub fn label(self: OfficerSeat) []const u8 {
        return switch (self) {
            .company_commander => "company commander",
            .lance_leader => "lance leader",
        };
    }
};

/// Derived performance band from task-performance standing (rule 20).
pub const PerformanceBand = enum {
    failing,
    steady,
    distinguished,

    /// Short display label.
    pub fn label(self: PerformanceBand) []const u8 {
        return switch (self) {
            .failing => "failing",
            .steady => "steady",
            .distinguished => "distinguished",
        };
    }
};

/// Bounds for task-performance standing (rule 24 single named constant).
pub const perf_min: i16 = -100; // TUNE
pub const perf_max: i16 = 100; // TUNE

/// One persistent officer arc, attached when an arc contract is accepted.
/// Rides on an existing payroll Person (the company's commander or a lance
/// leader); never creates or modifies any Person field.
pub const OfficerArc = struct {
    id: types.OfficerArcId = .none,
    /// The payroll Person this arc tracks (the ToE-selected officer).
    person: types.PersonId = .none,
    /// The contract this arc was introduced on.
    contract: types.ContractId = .none,
    /// The ToE seat that selected this officer.
    seat: OfficerSeat = .lance_leader,
    /// Signed task-performance standing (clamped to perf_min..perf_max).
    performance: i16 = 0,
    /// How many contracts this officer has had arcs on.
    encounters: u16 = 1,
    /// Short cause label for the most recent performance change (markup-safe).
    last_cause: []const u8 = "",
    /// Day the most recent performance change was recorded.
    last_cause_day: u32 = 0,
    /// True when this arc carries forward a prior arc's performance.
    recurring: bool = false,
};

// ---- Tests -----------------------------------------------------------------

test "OfficerArc defaults" {
    const a: OfficerArc = .{};
    try std.testing.expectEqual(types.OfficerArcId.none, a.id);
    try std.testing.expectEqual(types.PersonId.none, a.person);
    try std.testing.expectEqual(types.ContractId.none, a.contract);
    try std.testing.expectEqual(OfficerSeat.lance_leader, a.seat);
    try std.testing.expectEqual(@as(i16, 0), a.performance);
    try std.testing.expectEqual(@as(u16, 1), a.encounters);
    try std.testing.expectEqualStrings("", a.last_cause);
    try std.testing.expectEqual(@as(u32, 0), a.last_cause_day);
    try std.testing.expectEqual(false, a.recurring);
}

test "OfficerSeat and PerformanceBand labels" {
    try std.testing.expectEqualStrings("company commander", OfficerSeat.company_commander.label());
    try std.testing.expectEqualStrings("lance leader", OfficerSeat.lance_leader.label());
    try std.testing.expectEqualStrings("failing", PerformanceBand.failing.label());
    try std.testing.expectEqualStrings("steady", PerformanceBand.steady.label());
    try std.testing.expectEqualStrings("distinguished", PerformanceBand.distinguished.label());
}

test "perf_min and perf_max constants" {
    try std.testing.expectEqual(@as(i16, -100), perf_min);
    try std.testing.expectEqual(@as(i16, 100), perf_max);
    try std.testing.expect(perf_min < 0);
    try std.testing.expect(perf_max > 0);
}
