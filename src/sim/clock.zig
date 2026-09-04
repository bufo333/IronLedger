//! Campaign calendar and the daily tick pipeline (ARCH §6).
//! Mirrors MekHQ `Campaign.newDay()`, decomposed into ordered phases.

const std = @import("std");

/// Proleptic Gregorian date. BattleTech uses the same calendar in 3025.
pub const Date = struct {
    year: u16,
    month: u8, // 1–12
    day: u8, // 1–31

    pub const campaign_default: Date = .{ .year = 3025, .month = 1, .day = 1 };

    pub fn isLeapYear(year: u16) bool {
        return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    }

    pub fn daysInMonth(year: u16, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) @as(u8, 29) else 28,
            else => unreachable,
        };
    }

    pub fn next(self: Date) Date {
        var d = self;
        d.day += 1;
        if (d.day > daysInMonth(d.year, d.month)) {
            d.day = 1;
            d.month += 1;
            if (d.month > 12) {
                d.month = 1;
                d.year += 1;
            }
        }
        return d;
    }

    pub fn isPayday(self: Date) bool {
        return self.day == 1;
    }
};

/// The ordered phases of one campaign day. Order is part of the spec:
/// e.g. shipments must arrive (travel) before supply consumption, and
/// battles resolve after contract events may have spawned them.
pub const DayPhase = enum {
    travel,
    supply_consumption,
    medical,
    acquisition_and_markets,
    maintenance, // weekly per unit
    training,
    contract_events,
    battle_resolution,
    morale_fatigue,
    finances, // payday on the 1st
    decisions, // surface queued player decisions; pause auto-advance
};

pub const Clock = struct {
    date: Date = Date.campaign_default,
    day_index: u32 = 0, // days since campaign start; the canonical timestamp

    pub fn advance(self: *Clock) void {
        self.date = self.date.next();
        self.day_index += 1;
    }
};

test "date rollover incl. leap year" {
    var d: Date = .{ .year = 3024, .month = 2, .day = 28 };
    d = d.next();
    try std.testing.expectEqual(Date{ .year = 3024, .month = 2, .day = 29 }, d); // 3024 is a leap year
    d = .{ .year = 3025, .month = 12, .day = 31 };
    try std.testing.expectEqual(Date{ .year = 3026, .month = 1, .day = 1 }, d.next());
}

test "phases are in spec order" {
    try std.testing.expect(@intFromEnum(DayPhase.travel) < @intFromEnum(DayPhase.supply_consumption));
    try std.testing.expect(@intFromEnum(DayPhase.contract_events) < @intFromEnum(DayPhase.battle_resolution));
    try std.testing.expect(@intFromEnum(DayPhase.finances) < @intFromEnum(DayPhase.decisions));
}
