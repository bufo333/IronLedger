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

    /// Days from 0000-01-01, the earliest date the year holds, to this one:
    /// how many times `prev` can step back from it. Year 0 is a leap year,
    /// as every year divisible by 400 is.
    pub fn daysSinceEarliest(self: Date) u32 {
        const y: u32 = self.year;
        const before_year: u32 = if (y == 0) 0 else 365 * y + (y - 1) / 4 - (y - 1) / 100 + (y - 1) / 400 + 1;
        var before_month: u32 = 0;
        for (1..self.month) |m| before_month += daysInMonth(self.year, @intCast(m));
        return before_year + before_month + self.day - 1;
    }

    /// The day before; the inverse of `next`. 0000-01-01 has none; callers
    /// bound their steps by `daysSinceEarliest`.
    pub fn prev(self: Date) Date {
        var d = self;
        if (d.day > 1) {
            d.day -= 1;
            return d;
        }
        if (d.month > 1) {
            d.month -= 1;
        } else {
            d.month = 12;
            d.year -= 1;
        }
        d.day = daysInMonth(d.year, d.month);
        return d;
    }

    pub fn isPayday(self: Date) bool {
        return self.day == 1;
    }

    /// Days from this date to the next 1st of the month. On a payday it is
    /// the following month's: today's payday has already been paid.
    pub fn daysUntilNextPayday(self: Date) u32 {
        return @as(u32, daysInMonth(self.year, self.month)) - self.day + 1;
    }

    /// Whole calendar months in the `elapsed_days` before this date: the
    /// largest `k` such that the `k` months preceding this date's month hold
    /// no more than `elapsed_days` days together. From one 1st of the month
    /// to a later 1st it is exactly the number of months between them.
    /// Counting stops at year 1, so the result is bounded for any input. Pure.
    pub fn wholeMonthsBack(self: Date, elapsed_days: u32) u32 {
        var remaining = elapsed_days;
        var year = self.year;
        var month = self.month;
        var months: u32 = 0;
        while (true) {
            if (month == 1) {
                if (year <= 1) return months;
                year -= 1;
                month = 12;
            } else month -= 1;
            const length = daysInMonth(year, month);
            if (remaining < length) return months;
            remaining -= length;
            months += 1;
        }
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

    /// The calendar date of `day`, counted back from today (rule 55).
    /// `FutureDay` for a day after today, which has no date yet;
    /// `BeforeEarliestDate` when more days lie between it and today than
    /// today's date has since 0000-01-01, which only an inconsistent clock
    /// asks for.
    pub fn dateOf(self: Clock, day: u32) error{ FutureDay, BeforeEarliestDate }!Date {
        if (day > self.day_index) return error.FutureDay;
        const elapsed = self.day_index - day;
        if (elapsed > self.date.daysSinceEarliest()) return error.BeforeEarliestDate;
        var d = self.date;
        for (0..elapsed) |_| d = d.prev();
        return d;
    }
};

test "dateOf counts back across month, year and leap-day ends, and has no date for a future day" {
    var c: Clock = .{ .date = .{ .year = 3024, .month = 2, .day = 27 }, .day_index = 5 };
    const start = c;
    // Two years on, past a year end and the 3024 leap day.
    for (0..730) |_| c.advance();
    try std.testing.expectEqual(start.date, try c.dateOf(start.day_index));
    try std.testing.expectEqual(Date{ .year = 3024, .month = 2, .day = 29 }, try c.dateOf(start.day_index + 2));
    try std.testing.expectEqual(Date{ .year = 3024, .month = 3, .day = 1 }, try c.dateOf(start.day_index + 3));
    try std.testing.expectEqual(Date{ .year = 3024, .month = 12, .day = 31 }, try c.dateOf(start.day_index + 308));
    try std.testing.expectEqual(Date{ .year = 3025, .month = 1, .day = 1 }, try c.dateOf(start.day_index + 309));
    try std.testing.expectEqual(c.date, try c.dateOf(c.day_index));
    try std.testing.expectError(error.FutureDay, c.dateOf(c.day_index + 1));
    // Every day back agrees with stepping forward.
    var d = start.date;
    for (start.day_index..c.day_index + 1) |day| {
        try std.testing.expectEqual(d, try c.dateOf(@intCast(day)));
        d = d.next();
    }
}

test "daysSinceEarliest counts every day stepped forward from 0000-01-01, across leap and century years" {
    const earliest: Date = .{ .year = 0, .month = 1, .day = 1 };
    try std.testing.expectEqual(@as(u32, 0), earliest.daysSinceEarliest());
    // Year 0 is leap (366 days), 1–3 are not, 4 is; 100 is not, 400 is.
    try std.testing.expectEqual(@as(u32, 366), (Date{ .year = 1, .month = 1, .day = 1 }).daysSinceEarliest());
    try std.testing.expectEqual(@as(u32, 366 + 3 * 365), (Date{ .year = 4, .month = 1, .day = 1 }).daysSinceEarliest());
    var d = earliest;
    var n: u32 = 0;
    while (d.year < 405) : (n += 1) {
        try std.testing.expectEqual(n, d.daysSinceEarliest());
        d = d.next();
    }
    // Near the campaign era, against the same stepping.
    d = .{ .year = 2999, .month = 12, .day = 31 };
    n = d.daysSinceEarliest();
    while (d.year < 3101) : (n += 1) {
        try std.testing.expectEqual(n, d.daysSinceEarliest());
        d = d.next();
    }
}

test "dateOf refuses a day further back than the calendar's earliest date rather than underflow the year" {
    const today = Date.campaign_default;
    const back = today.daysSinceEarliest();
    // Exactly as many days as today has since 0000-01-01 reach it.
    const exact: Clock = .{ .date = today, .day_index = back };
    try std.testing.expectEqual(Date{ .year = 0, .month = 1, .day = 1 }, try exact.dateOf(0));
    // One more has no date.
    const over: Clock = .{ .date = today, .day_index = back + 1 };
    try std.testing.expectError(error.BeforeEarliestDate, over.dateOf(0));
    try std.testing.expectEqual(Date{ .year = 0, .month = 1, .day = 1 }, try over.dateOf(1));
    // The widest interval a clock can hold.
    const widest: Clock = .{ .date = today, .day_index = std.math.maxInt(u32) };
    try std.testing.expectError(error.BeforeEarliestDate, widest.dateOf(1));
    try std.testing.expectError(error.BeforeEarliestDate, widest.dateOf(0));
    try std.testing.expectEqual(today, try widest.dateOf(std.math.maxInt(u32)));
}

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

test "wholeMonthsBack counts the preceding calendar months that fit the elapsed days" {
    const mar_3025: Date = .{ .year = 3025, .month = 3, .day = 1 };
    // Zero elapsed days is zero months.
    try std.testing.expectEqual(@as(u32, 0), mar_3025.wholeMonthsBack(0));
    // February 3025 has 28 days: one day short is no month, 28 is one.
    try std.testing.expectEqual(@as(u32, 0), mar_3025.wholeMonthsBack(27));
    try std.testing.expectEqual(@as(u32, 1), mar_3025.wholeMonthsBack(28));
    // January's 31 days follow February: 28 + 31 = 59 is two, 58 is one.
    try std.testing.expectEqual(@as(u32, 1), mar_3025.wholeMonthsBack(58));
    try std.testing.expectEqual(@as(u32, 2), mar_3025.wholeMonthsBack(59));
    // A 30-day month: April 3025.
    const may_3025: Date = .{ .year = 3025, .month = 5, .day = 1 };
    try std.testing.expectEqual(@as(u32, 0), may_3025.wholeMonthsBack(29));
    try std.testing.expectEqual(@as(u32, 1), may_3025.wholeMonthsBack(30));
    // A leap February: 3024 has a 29th.
    const mar_3024: Date = .{ .year = 3024, .month = 3, .day = 1 };
    try std.testing.expectEqual(@as(u32, 0), mar_3024.wholeMonthsBack(28));
    try std.testing.expectEqual(@as(u32, 1), mar_3024.wholeMonthsBack(29));
    // Across a year end: December precedes January.
    const jan_3026: Date = .{ .year = 3026, .month = 1, .day = 1 };
    try std.testing.expectEqual(@as(u32, 0), jan_3026.wholeMonthsBack(30));
    try std.testing.expectEqual(@as(u32, 1), jan_3026.wholeMonthsBack(31));
    try std.testing.expectEqual(@as(u32, 11), jan_3026.wholeMonthsBack(364));
    try std.testing.expectEqual(@as(u32, 12), jan_3026.wholeMonthsBack(365));
    // From one 1st to a later 1st, stepping the calendar day by day.
    var d: Date = .{ .year = 3024, .month = 11, .day = 1 };
    var elapsed: u32 = 0;
    var firsts: u32 = 0;
    while (firsts < 26) {
        d = d.next();
        elapsed += 1;
        if (d.isPayday()) {
            firsts += 1;
            try std.testing.expectEqual(firsts, d.wholeMonthsBack(elapsed));
        }
    }
    // The count is bounded at year 1.
    try std.testing.expectEqual(@as(u32, 0), (Date{ .year = 1, .month = 1, .day = 1 }).wholeMonthsBack(std.math.maxInt(u32)));
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

test "the next payday is the coming 1st, never today" {
    try std.testing.expectEqual(@as(u32, 31), (Date{ .year = 3025, .month = 1, .day = 1 }).daysUntilNextPayday());
    try std.testing.expectEqual(@as(u32, 1), (Date{ .year = 3025, .month = 1, .day = 31 }).daysUntilNextPayday());
    try std.testing.expectEqual(@as(u32, 28), (Date{ .year = 3025, .month = 2, .day = 1 }).daysUntilNextPayday());
    // Stepping that many days lands on a payday.
    var d: Date = .{ .year = 3025, .month = 2, .day = 10 };
    for (0..d.daysUntilNextPayday()) |_| d = d.next();
    try std.testing.expectEqual(Date{ .year = 3025, .month = 3, .day = 1 }, d);
}

test "isPayday fires on day 1 only; tick.zig gates payroll here" {
    // Consumer: tick.zig gates payroll on gs.clock.date.isPayday() (rule 24 one-owner).
    // Day 1 of any month is payday; every other day is not.
    const payday: Date = .{ .year = 3025, .month = 1, .day = 1 };
    const day2: Date = .{ .year = 3025, .month = 1, .day = 2 };
    const last: Date = .{ .year = 3025, .month = 1, .day = 31 };
    const mid: Date = .{ .year = 3025, .month = 6, .day = 15 };
    try std.testing.expect(payday.isPayday());
    try std.testing.expect(!day2.isPayday());
    try std.testing.expect(!last.isPayday());
    try std.testing.expect(!mid.isPayday());
    // The day after the last day of a month wraps to day 1 = payday.
    try std.testing.expect(last.next().isPayday());
    // Day 2 advanced once is day 3, not payday.
    try std.testing.expect(!day2.next().isPayday());
    // Boolean identity: isPayday() ↔ (day == 1); tick.zig:594 evaluates exactly this predicate.
    // Asserting equality proves owner and consumer cannot disagree.
    try std.testing.expectEqual(payday.day == 1, payday.isPayday());
    try std.testing.expectEqual(day2.day == 1, day2.isPayday());
}
