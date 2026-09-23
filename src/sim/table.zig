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

/// A row from a cell list literal (which would otherwise die with the
/// statement that made it).
pub fn row(alloc: std.mem.Allocator, r: []const []const u8) !Row {
    return alloc.dupe([]const u8, r);
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
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += len;
        n += 1;
    }
    return n;
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
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        try out.appendSlice(alloc, text[i..@min(text.len, i + len)]);
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
