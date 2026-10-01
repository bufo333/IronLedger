//! Campaign calendar: date and clock primitives (ARCH §6).
//! MekHQ counterpart: calendar day tracking in `Campaign.java` (docs/mekhq-map.md).

const std = @import("std");

/// Proleptic Gregorian date. BattleTech uses the same calendar in 3025.
pub const Date = struct {
    year: u16,
    month: u8, // 1–12
    day: u8, // 1–31

    pub const campaign_default: Date = .{ .year = 3025, .month = 1, .day = 1 };

    /// "3025-01-01": the one rendering of a date, for logs, saves and screens.
    pub fn text(self: Date, buf: *[10]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day }) catch "????-??-??";
    }

    pub fn textAlloc(self: Date, alloc: std.mem.Allocator) ![]const u8 {
        var buf: [10]u8 = undefined;
        return alloc.dupe(u8, self.text(&buf));
    }

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

    /// True when the date values are calendar-legal for a BattleTech
    /// campaign (rule 47). Guards the `unreachable` branch in
    /// `daysInMonth` so a tampered month-13 row is rejected before it
    /// reaches undefined behaviour.
    pub fn valid(self: Date) bool {
        if (self.year < 3000 or self.year > 4000) return false;
        if (self.month < 1 or self.month > 12) return false;
        if (self.day < 1 or self.day > daysInMonth(self.year, self.month)) return false;
        return true;
    }
};

pub const Clock = struct {
    date: Date = Date.campaign_default,
    day_index: u32 = 0, // days since campaign start; the canonical timestamp

    pub fn advance(self: *Clock) void {
        self.date = self.date.next();
        self.day_index += 1;
    }
};

/// "today" when `eta_day <= now_day`, else "d{eta} ({N} days)" with
/// `N = eta_day − now_day` — the one owner for ETA/arrival display
/// (rules 24, 28). Both transit rows and the returning-company line
/// call this so the wording cannot diverge.
pub fn etaText(alloc: std.mem.Allocator, eta_day: u32, now_day: u32) ![]const u8 {
    if (eta_day <= now_day) return alloc.dupe(u8, "today");
    const n = eta_day - now_day;
    return std.fmt.allocPrint(alloc, "d{d} ({d} days)", .{ eta_day, n });
}

test "etaText: today, future, and exact boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("today", try etaText(a, 10, 10));
    try std.testing.expectEqualStrings("today", try etaText(a, 9, 10));
    try std.testing.expectEqualStrings("d15 (5 days)", try etaText(a, 15, 10));
    try std.testing.expectEqualStrings("d11 (1 days)", try etaText(a, 11, 10));
}

test "date rollover incl. leap year" {
    var d: Date = .{ .year = 3024, .month = 2, .day = 28 };
    d = d.next();
    try std.testing.expectEqual(Date{ .year = 3024, .month = 2, .day = 29 }, d); // 3024 is a leap year
    d = .{ .year = 3025, .month = 12, .day = 31 };
    try std.testing.expectEqual(Date{ .year = 3026, .month = 1, .day = 1 }, d.next());
}

test "Date.valid rejects out-of-range values and accepts legal ones" {
    try std.testing.expect(Date.campaign_default.valid()); // 3025-01-01
    try std.testing.expect(!(Date{ .year = 3025, .month = 0, .day = 1 }).valid()); // month 0
    try std.testing.expect(!(Date{ .year = 3025, .month = 13, .day = 1 }).valid()); // month 13
    try std.testing.expect(!(Date{ .year = 3025, .month = 1, .day = 0 }).valid()); // day 0
    try std.testing.expect(!(Date{ .year = 3025, .month = 1, .day = 32 }).valid()); // day 32
    try std.testing.expect((Date{ .year = 3025, .month = 2, .day = 28 }).valid());
    try std.testing.expect(!(Date{ .year = 3025, .month = 2, .day = 29 }).valid()); // 3025 not leap
    try std.testing.expect((Date{ .year = 3024, .month = 2, .day = 29 }).valid()); // 3024 is leap
}

test "one date rendering, zero-padded" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("3025-01-01", Date.campaign_default.text(&buf));
    const d: Date = .{ .year = 3026, .month = 12, .day = 9 };
    try std.testing.expectEqualStrings("3026-12-09", d.text(&buf));
}
