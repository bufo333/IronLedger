//! Column tables for the screens (Stage 12F). No MekHQ counterpart.
//! A query builds one — column names and cells of markup text — and the
//! client lays it out for the width it has: the TUI (`screen.table`)
//! pins the first column and scrolls the rest, the CLI prints it at its
//! natural width (`render`). No query pads a column, so a header and its
//! rows can never disagree, and no screen has a fixed width.

const std = @import("std");

pub const Align = enum { left, right };

pub const Col = struct {
    name: []const u8,
    justify: Align = .left,
    /// Drop rank when the table is wider than its rect: 0 never drops;
    /// higher ranks drop before lower ones, before any column scrolls.
    drop: u8 = 0,
};

/// One cell per column, markup allowed (`{a}…{/}`).
pub const Row = []const []const u8;

pub const Table = struct {
    cols: []const Col,
    rows: []const Row,

    pub const empty: Table = .{ .cols = &.{}, .rows = &.{} };

    /// The natural width of each column: the widest of its name and cells.
    pub fn widths(self: Table, alloc: std.mem.Allocator) ![]u16 {
        const w = try alloc.alloc(u16, self.cols.len);
        for (self.cols, 0..) |c, i| w[i] = @intCast(cells(c.name));
        for (self.rows) |r| for (r, 0..) |cell, i| {
            if (i < w.len) w[i] = @max(w[i], @as(u16, @intCast(cells(cell))));
        };
        return w;
    }

    /// Header and rows as lines at natural width, two spaces between
    /// columns — for the CLI and for tests.
    pub fn render(self: Table, alloc: std.mem.Allocator) ![]const []const u8 {
        const w = try self.widths(alloc);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var line: std.ArrayListUnmanaged(u8) = .empty;
        for (self.cols, 0..) |c, i| {
            if (i > 0) try line.appendSlice(alloc, "  ");
            try line.appendSlice(alloc, try pad(alloc, c.name, w[i], c.justify));
        }
        try out.append(alloc, try line.toOwnedSlice(alloc));
        for (self.rows) |r| {
            for (self.cols, 0..) |c, i| {
                if (i > 0) try line.appendSlice(alloc, "  ");
                try line.appendSlice(alloc, try pad(alloc, if (i < r.len) r[i] else "", w[i], c.justify));
            }
            try out.append(alloc, std.mem.trimEnd(u8, try line.toOwnedSlice(alloc), " "));
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Columns shown in `avail` cells, in order: droppable columns leave,
/// highest `drop` rank first and the rightmost among equals, until the
/// rest fit side by side with `gap` between them or none is left to drop.
/// Whatever still does not fit scrolls. The first column is pinned and
/// never drops.
pub fn visibleColumns(alloc: std.mem.Allocator, t: Table, w: []const u16, avail: u16, gap: u16) ![]usize {
    var vis: std.ArrayListUnmanaged(usize) = .empty;
    for (0..t.cols.len) |i| try vis.append(alloc, i);
    while (true) {
        var need: usize = 0;
        for (vis.items, 0..) |ci, j| need += w[ci] + (if (j > 0) gap else 0);
        if (need <= avail) break;
        var victim: ?usize = null;
        for (vis.items, 0..) |ci, j| {
            if (ci == 0 or t.cols[ci].drop == 0) continue;
            if (victim == null or t.cols[ci].drop >= t.cols[vis.items[victim.?]].drop) victim = j;
        }
        _ = vis.orderedRemove(victim orelse break);
    }
    return vis.toOwnedSlice(alloc);
}

/// A row from a cell list literal (which would otherwise die with the
/// statement that made it).
pub fn row(alloc: std.mem.Allocator, r: []const []const u8) !Row {
    return alloc.dupe([]const u8, r);
}

/// A progress bar of `buf.len` cells: `#` filled, `-` empty, clamped at
/// both ends and empty for a zero or negative denominator. The one bar in
/// the game (rule 12) — `queries` writes them into row text, `tui/screen`
/// draws them as meters, and both read this. Lives here beside `marks`
/// for the same reason the tag set does: it is a presentation primitive
/// the sim and the frontends must agree on, and nothing below `queries`
/// may import a frontend (rule 2).
pub fn bar(buf: []u8, num: i64, den: i64) []const u8 {
    const width = buf.len;
    const filled: usize = if (den <= 0) 0 else @intCast(@min(@as(i64, @intCast(width)), @divTrunc(@max(0, num) * @as(i64, @intCast(width)), den)));
    @memset(buf[0..filled], '#');
    @memset(buf[filled..], '-');
    return buf;
}

/// The inline markup tags (docs/coding-contract.md rule 16): amber, good,
/// critical, selected, dim, tab, purple, and the close. Declared here
/// once; `screen.Style.fromMarkup` maps them to styles.
pub const marks = "agcsdtp/";

pub fn isMark(c: u8) bool {
    return std.mem.indexOfScalar(u8, marks, c) != null;
}

/// Visible cells of markup text: code points, less the `{x}` tokens.
pub fn cells(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{' and i + 2 < s.len and s[i + 2] == '}' and isMark(s[i + 1])) {
            i += 3;
            continue;
        }
        i += nextGlyph(s, i).len;
        n += 1;
    }
    return n;
}

/// One drawable character of screen text and the bytes it takes.
pub const Glyph = struct { cp: u21, len: usize };

/// The glyph starting at `s[i]`. Invalid or truncated UTF-8 is U+FFFD, and
/// C0 and C1 controls and DEL are `?`, so screen text can never carry a
/// terminal control. The width `cells` measures and the glyphs the screen
/// draws both come from here.
pub fn nextGlyph(s: []const u8, i: usize) Glyph {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + len > s.len) return .{ .cp = 0xFFFD, .len = s.len - i };
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return .{ .cp = 0xFFFD, .len = len };
    const control = cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0);
    return .{ .cp = if (control) '?' else cp, .len = len };
}

/// Markup-safe pad or clip to `width` cells. A clipped cell keeps its
/// markup balanced by closing any open colour.
pub fn pad(alloc: std.mem.Allocator, text: []const u8, width: usize, al: Align) ![]const u8 {
    const n = cells(text);
    if (n == width) return text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (n < width) {
        if (al == .right) try out.appendNTimes(alloc, ' ', width - n);
        try out.appendSlice(alloc, text);
        if (al == .left) try out.appendNTimes(alloc, ' ', width - n);
        return out.toOwnedSlice(alloc);
    }
    var shown: usize = 0;
    var i: usize = 0;
    var open = false;
    while (i < text.len) {
        if (text[i] == '{' and i + 2 < text.len and text[i + 2] == '}' and isMark(text[i + 1])) {
            try out.appendSlice(alloc, text[i .. i + 3]);
            open = text[i + 1] != '/';
            i += 3;
            continue;
        }
        if (shown == width) break;
        const len = nextGlyph(text, i).len;
        try out.appendSlice(alloc, text[i .. i + len]);
        i += len;
        shown += 1;
    }
    if (open) try out.appendSlice(alloc, "{/}");
    return out.toOwnedSlice(alloc);
}

test "cells counts code points and skips markup" {
    try std.testing.expectEqual(@as(usize, 3), cells("a·b"));
    try std.testing.expectEqual(@as(usize, 4), cells("{a}☠ ☠{/}◐"));
    try std.testing.expectEqual(@as(usize, 3), cells("{x}"));
}

test "pad aligns and clips without splitting a character or a colour" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ab   ", try pad(a, "ab", 5, .left));
    try std.testing.expectEqualStrings("   ab", try pad(a, "ab", 5, .right));
    try std.testing.expectEqualStrings("{a}a·{/}", try pad(a, "{a}a·bc{/}", 2, .left));
    try std.testing.expectEqualStrings("{c}12{/}", try pad(a, "{c}1234", 2, .left));
}

test "render sizes every column to its widest cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Table = .{
        .cols = &.{ .{ .name = "kind" }, .{ .name = "pay", .justify = .right } },
        .rows = &.{ try row(a, &.{ "garrison duty", "1,200" }), try row(a, &.{ "raid", "{g}900{/}" }) },
    };
    const lines = try t.render(a);
    try std.testing.expectEqualStrings("kind             pay", lines[0]);
    try std.testing.expectEqualStrings("garrison duty  1,200", lines[1]);
    try std.testing.expectEqualStrings("raid             {g}900{/}", lines[2]);
}

test "bar fills proportionally and clamps at both ends" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("#####-----", bar(&buf, 50, 100));
    try std.testing.expectEqualStrings("----------", bar(&buf, 0, 0));
    try std.testing.expectEqualStrings("----------", bar(&buf, 50, -1)); // no denominator
    try std.testing.expectEqualStrings("----------", bar(&buf, -5, 100)); // no negative fill
    try std.testing.expectEqualStrings("##########", bar(&buf, 500, 100)); // never past full
}

test "droppable columns leave highest rank first, rightmost among equals, before anything scrolls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Table = .{
        .cols = &.{ .{ .name = "kind", .drop = 9 }, .{ .name = "total", .drop = 3 }, .{ .name = "world" }, .{ .name = "LY", .drop = 3 }, .{ .name = "mix", .drop = 1 } },
        .rows = &.{},
    };
    const w = [_]u16{ 4, 5, 5, 2, 3 };
    // Everything fits: 4+5+5+2+3 plus four gaps of 2 = 27.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, try visibleColumns(a, t, &w, 27, 2));
    // One short: the rightmost rank-3 column goes first.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4 }, try visibleColumns(a, t, &w, 26, 2));
    // Then the other rank 3, then the rank 1; the pinned column and the
    // undroppable one stay even when they still do not fit, and scroll.
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 4 }, try visibleColumns(a, t, &w, 16, 2));
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, try visibleColumns(a, t, &w, 11, 2));
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, try visibleColumns(a, t, &w, 5, 2));
}
