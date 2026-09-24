//! Cell buffer and drawing primitives for the TUI (docs/tui.md
//! "Rendering"): every frame is composed into a grid of cells by
//! arithmetic — panes at computed rectangles, text padded or clipped to
//! its pane — then flushed as ANSI. Styles are semantic (amber, good,
//! critical, selected, dim) so the client holds on any terminal theme.
//! Inline markup `{a}…{/}` uses the tag set of docs/tui_mockup_gen.py so
//! query text can carry emphasis. Pure: no I/O except `flush`.

const std = @import("std");
const table_mod = @import("game").table;
const term = @import("term.zig");
pub const Table = table_mod.Table;

pub const Style = enum(u8) {
    normal,
    dim,
    amber,
    good,
    crit,
    sel, // cursor row / focused pane title
    tab, // active tab
    purple,
    box, // borders
    focus, // the focused pane's border line
    // Political colours for the star map.
    blue,
    red,
    yellow,
    green,
    magenta,
    cyan,
    white,
    grey,

    fn sgr(self: Style) []const u8 {
        return switch (self) {
            .normal => term.sgr.reset,
            .dim => term.sgr.dim,
            .amber => term.sgr.amber,
            .good => term.sgr.good,
            .crit => term.sgr.crit,
            .sel => term.sgr.sel,
            .tab => term.sgr.tab,
            .purple => term.sgr.purple,
            .box => term.sgr.box,
            .focus => term.sgr.focus,
            .blue => term.sgr.blue,
            .red => term.sgr.red,
            .yellow => term.sgr.yellow,
            .green => term.sgr.green,
            .magenta => term.sgr.magenta,
            .cyan => term.sgr.cyan,
            .white => term.sgr.white,
            .grey => term.sgr.grey,
        };
    }

    /// The style behind a `{x}` tag; the tag set is `table.marks`.
    fn fromMarkup(c: u8) ?Style {
        return switch (c) {
            'a' => .amber,
            'g' => .good,
            'c' => .crit,
            's' => .sel,
            'd' => .dim,
            't' => .tab,
            'p' => .purple,
            '/' => .normal,
            else => null,
        };
    }
};

pub const Rgb = term.Rgb;

/// Two vertical pixels per cell: drawn as `▀` with fg = top, bg = bottom.
pub const Pixels = struct { top: Rgb, bottom: Rgb };

pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .normal,
    px: ?Pixels = null,
};

const png = @import("png.zig");

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    /// The pane's inner area (inside the border, one column of padding).
    pub fn inner(self: Rect) Rect {
        if (self.w < 4 or self.h < 2) return .{ .x = self.x, .y = self.y, .w = 0, .h = 0 };
        return .{ .x = self.x + 2, .y = self.y + 1, .w = self.w - 4, .h = self.h - 2 };
    }
};

pub const Screen = struct {
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cells: []Cell,
    /// Emit 24-bit SGR for pixel cells; otherwise the nearest of the 256-colour cube.
    truecolor: bool = true,
    /// Replace box-drawing and block glyphs with ASCII (`--ascii`).
    ascii: bool = false,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const cells = try alloc.alloc(Cell, @as(usize, cols) * rows);
        @memset(cells, .{});
        return .{ .alloc = alloc, .cols = cols, .rows = rows, .cells = cells };
    }

    pub fn deinit(self: *Screen) void {
        self.alloc.free(self.cells);
    }

    /// The new buffer is allocated before the old one is freed: on failure
    /// the screen keeps its old size and buffer.
    pub fn resize(self: *Screen, cols: u16, rows: u16) !void {
        const fresh = try self.alloc.alloc(Cell, @as(usize, cols) * rows);
        self.alloc.free(self.cells);
        self.cells = fresh;
        self.cols = cols;
        self.rows = rows;
        self.clear();
    }

    pub fn clear(self: *Screen) void {
        @memset(self.cells, .{});
    }

    pub fn full(self: *Screen) Rect {
        return .{ .x = 0, .y = 0, .w = self.cols, .h = self.rows };
    }

    pub fn put(self: *Screen, x: i32, y: i32, ch: u21, style: Style) void {
        if (x < 0 or y < 0 or x >= self.cols or y >= self.rows) return;
        self.cells[@as(usize, @intCast(y)) * self.cols + @as(usize, @intCast(x))] = .{ .ch = ch, .style = style };
    }

    pub fn get(self: *const Screen, x: u16, y: u16) Cell {
        return self.cells[@as(usize, y) * self.cols + x];
    }

    /// Write markup text at (x, y), clipped to `width` cells; returns the
    /// number of visible cells consumed. `base` is the style outside markup.
    pub fn text(self: *Screen, x: i32, y: i32, width: u16, s: []const u8, base: Style) u16 {
        var style = base;
        var col: i32 = x;
        const limit: i32 = x + @as(i32, width);
        var t: table_mod.Tokenizer = .{ .s = s };
        while (t.next()) |tok| {
            const cp = switch (tok) {
                .mark => |m| {
                    const st = Style.fromMarkup(m).?; // every tag in `marks` has a style (tested)
                    style = if (st == .normal) base else st;
                    continue;
                },
                .glyph => |g| g,
            };
            if (col >= limit) break;
            // Skulls fall back to letters under --ascii, and a replaced
            // byte to a question mark.
            const glyph: u21 = if (self.ascii) switch (cp) {
                '☠' => 'X',
                '◐' => 'x',
                0xFFFD => '?',
                else => cp,
            } else cp;
            self.put(col, y, glyph, style);
            col += 1;
        }
        return @intCast(@max(0, col - x));
    }

    /// Write text padded with spaces to exactly `width` cells.
    pub fn textPad(self: *Screen, x: i32, y: i32, width: u16, s: []const u8, base: Style) void {
        const used = self.text(x, y, width, s, base);
        var c: i32 = x + used;
        while (c < x + @as(i32, width)) : (c += 1) self.put(c, y, ' ', base);
    }

    /// Fill a rect with a style (used for selected rows and modals).
    pub fn fill(self: *Screen, r: Rect, ch: u21, style: Style) void {
        var yy: u16 = 0;
        while (yy < r.h) : (yy += 1) {
            var xx: u16 = 0;
            while (xx < r.w) : (xx += 1) self.put(r.x + xx, r.y + yy, ch, style);
        }
    }

    pub const PaneOpts = struct {
        title: []const u8 = "",
        right_title: []const u8 = "",
        focused: bool = false,
        double: bool = false,
    };

    /// Draw a bordered pane; returns its inner rect.
    pub fn pane(self: *Screen, r: Rect, opts: PaneOpts) Rect {
        if (r.w < 2 or r.h < 2) return r.inner();
        const a = self.ascii;
        const h: u21 = if (a) (if (opts.double) '=' else '-') else if (opts.double) '═' else '─';
        const v: u21 = if (a) '|' else if (opts.double) '║' else '│';
        const tl: u21 = if (a) '+' else if (opts.double) '╔' else '┌';
        const tr: u21 = if (a) '+' else if (opts.double) '╗' else '┐';
        const bl: u21 = if (a) '+' else if (opts.double) '╚' else '└';
        const br: u21 = if (a) '+' else if (opts.double) '╝' else '┘';
        const x0: i32 = r.x;
        const y0: i32 = r.y;
        const x1: i32 = r.x + r.w - 1;
        const y1: i32 = r.y + r.h - 1;
        // Clear everything inside the border, padding columns included, so a
        // modal never shows the screen beneath it.
        self.fill(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, ' ', .normal);
        const tstyle: Style = if (opts.focused) .sel else .box;
        const line_style: Style = if (opts.focused) .focus else .box;
        var x: i32 = x0 + 1;
        while (x < x1) : (x += 1) {
            self.put(x, y0, h, line_style);
            self.put(x, y1, h, .box);
        }
        var y: i32 = y0 + 1;
        while (y < y1) : (y += 1) {
            self.put(x0, y, v, .box);
            self.put(x1, y, v, .box);
        }
        self.put(x0, y0, tl, .box);
        self.put(x1, y0, tr, .box);
        self.put(x0, y1, bl, .box);
        self.put(x1, y1, br, .box);
        if (opts.title.len > 0 and r.w > 6) {
            const avail: u16 = r.w - 4;
            self.put(x0 + 1, y0, ' ', tstyle);
            const n = self.text(x0 + 2, y0, avail, opts.title, tstyle);
            self.put(x0 + 2 + n, y0, ' ', tstyle);
        }
        if (opts.right_title.len > 0) {
            const len: i32 = @intCast(visibleLen(opts.right_title));
            const start = x1 - 2 - len;
            if (start > x0 + 2) {
                self.put(start - 1, y0, ' ', .dim);
                _ = self.text(start, y0, @intCast(len), opts.right_title, .dim);
                self.put(start + len, y0, ' ', .dim);
            }
        }
        return r.inner();
    }

    /// Lines into a pane's inner rect, one per row, padded; a cursor row
    /// (if any) is painted selected.
    pub fn lines(self: *Screen, inner: Rect, items: []const []const u8, first: usize, cursor: ?usize) void {
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = first + row;
            const y: i32 = inner.y + row;
            if (idx < items.len) {
                const st: Style = if (cursor != null and cursor.? == idx) .sel else .normal;
                self.textPad(inner.x, y, inner.w, items[idx], st);
            } else {
                self.textPad(inner.x, y, inner.w, "", .normal);
            }
        }
    }

    pub const TableView = struct {
        /// Columns out of view left of the pinned one's neighbour, and right of the edge.
        hidden_left: usize,
        hidden_right: usize,
    };

    /// Lay a table into `inner`: column names on the first line,
    /// rows from `first` below, the cursor row selected. The first column
    /// is pinned; `col_scroll` columns after it are hidden to the left,
    /// clamped so the view never scrolls past the last column. A column
    /// at the edge is clipped, not dropped, so a wide cell is never
    /// silently missing.
    pub fn table(self: *Screen, alloc: std.mem.Allocator, inner: Rect, t: Table, first: usize, cursor: ?usize, col_scroll: *usize) !TableView {
        const none: TableView = .{ .hidden_left = 0, .hidden_right = 0 };
        if (inner.h == 0 or inner.w == 0 or t.cols.len == 0) return none;
        const w = try t.widths(alloc);
        const gap: u16 = 2;
        // Droppable columns leave before anything scrolls; `vis` is what
        // remains, and the scroll below runs over it.
        const vis = try table_mod.visibleColumns(alloc, t, w, inner.w, gap);
        const pin_w: u16 = @min(w[0], inner.w);
        const rest_w: usize = if (inner.w > pin_w + gap) inner.w - pin_w - gap else 0;
        // The smallest scroll at which every remaining column fits.
        var max_scroll: usize = if (vis.len > 1) vis.len - 2 else 0;
        var k: usize = 1;
        while (k < vis.len) : (k += 1) {
            var need: usize = 0;
            for (vis[k..], 0..) |ci, j| need += w[ci] + (if (j > 0) gap else 0);
            if (need <= rest_w) {
                max_scroll = k - 1;
                break;
            }
        }
        col_scroll.* = @min(col_scroll.*, max_scroll);
        const start = 1 + col_scroll.*;
        const edge: i32 = @as(i32, inner.x) + inner.w;

        var hidden_right: usize = 0;
        var line: usize = 0;
        while (line < inner.h) : (line += 1) {
            const y: i32 = inner.y + @as(i32, @intCast(line));
            const row_idx: ?usize = if (line == 0) null else first + line - 1;
            const base: Style = if (line == 0) .dim else if (cursor != null and row_idx.? == cursor.?) .sel else .normal;
            self.textPad(inner.x, y, inner.w, "", base);
            if (row_idx != null and row_idx.? >= t.rows.len) continue;
            const r: ?table_mod.Row = if (row_idx) |ri| t.rows[ri] else null;
            var x: i32 = inner.x;
            var vi: usize = 0;
            while (vi < vis.len) : (vi += if (vi == 0) start else 1) {
                const ci = vis[vi];
                if (x >= edge) {
                    if (line == 0) hidden_right += 1;
                    continue;
                }
                const cell: []const u8 = if (r) |rr| (if (ci < rr.len) rr[ci] else "") else t.cols[ci].name;
                const avail: u16 = @intCast(@min(@as(i32, w[ci]), edge - x));
                _ = self.text(x, y, avail, try table_mod.pad(alloc, cell, w[ci], t.cols[ci].justify), base);
                x += @as(i32, w[ci]) + gap;
            }
        }
        const view: TableView = .{ .hidden_left = col_scroll.*, .hidden_right = hidden_right };
        if (view.hidden_left > 0 or view.hidden_right > 0) {
            // Scroll hint over the header's right end.
            var buf: [48]u8 = undefined;
            const la: []const u8 = if (self.ascii) "<" else "◀";
            const ra: []const u8 = if (self.ascii) ">" else "▶";
            const hint = if (view.hidden_left > 0 and view.hidden_right > 0)
                // best-effort: a scroll marker in a fixed buffer; too long leaves it blank.
                std.fmt.bufPrint(&buf, " {s} {d} · {d} {s} ", .{ la, view.hidden_left, view.hidden_right, ra }) catch ""
            else if (view.hidden_left > 0)
                // best-effort: a scroll marker in a fixed buffer; too long leaves it blank.
                std.fmt.bufPrint(&buf, " {s} {d} ", .{ la, view.hidden_left }) catch ""
            else
                // best-effort: a scroll marker in a fixed buffer; too long leaves it blank.
                std.fmt.bufPrint(&buf, " {d} {s} ", .{ view.hidden_right, ra }) catch "";
            const hl: i32 = @intCast(visibleLen(hint));
            if (hl < inner.w) _ = self.text(edge - hl, inner.y, @intCast(hl), hint, .amber);
        }
        return view;
    }

    /// Draw an image into a rect as half-block colour cells (two vertical
    /// pixels per cell), fitting the whole picture with a 2:1 cell aspect.
    pub fn blit(self: *Screen, r: Rect, img: *const png.Image) void {
        if (r.w == 0 or r.h == 0 or img.width == 0 or img.height == 0) return;
        // Fit: cells are ~half as wide as tall, so a square image wants cols = 2 × rows.
        var rows: u32 = r.h;
        var cols: u32 = @min(@as(u32, r.w), rows * 2 * img.width / img.height);
        if (cols == 0) cols = 1;
        rows = @min(rows, @max(1, cols * img.height / (2 * img.width)));
        const ox: u32 = r.x + (r.w - @as(u16, @intCast(cols))) / 2;
        const oy: u32 = r.y + (r.h - @as(u16, @intCast(rows))) / 2;
        var cy: u32 = 0;
        while (cy < rows) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cols) : (cx += 1) {
                const top = avg(img, cx, cy * 2, cols, rows * 2);
                const bottom = avg(img, cx, cy * 2 + 1, cols, rows * 2);
                self.cells[(oy + cy) * self.cols + ox + cx] = .{ .ch = ' ', .style = .normal, .px = .{ .top = top, .bottom = bottom } };
            }
        }
    }

    fn avg(img: *const png.Image, cx: u32, py: u32, cols: u32, prows: u32) Rgb {
        const x0 = cx * img.width / cols;
        const x1 = @max(x0 + 1, (cx + 1) * img.width / cols);
        const y0 = py * img.height / prows;
        const y1 = @max(y0 + 1, (py + 1) * img.height / prows);
        var sum: [3]u64 = .{ 0, 0, 0 };
        var n: u64 = 0;
        var y = y0;
        while (y < y1 and y < img.height) : (y += 1) {
            var x = x0;
            while (x < x1 and x < img.width) : (x += 1) {
                const p = img.pixel(x, y);
                sum[0] += p[0];
                sum[1] += p[1];
                sum[2] += p[2];
                n += 1;
            }
        }
        if (n == 0) return .{ 0, 0, 0 };
        return .{ @intCast(sum[0] / n), @intCast(sum[1] / n), @intCast(sum[2] / n) };
    }

    /// Emit the whole frame (turn-based UI: a full repaint per event is
    /// cheap and never leaves artifacts).
    pub fn flush(self: *Screen, out: *std.Io.Writer) !void {
        try term.cursorHome(out);
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            try term.cursorTo(out, y + 1, 1);
            var cur: ?Style = null;
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const c = self.get(x, y);
                if (c.px) |p| {
                    try term.paintPair(out, self.truecolor, p.top, p.bottom, if (self.ascii) "#" else "▀");
                    cur = null;
                    continue;
                }
                if (cur == null or cur.? != c.style) {
                    try out.writeAll(c.style.sgr());
                    cur = c.style;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.ch, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                try out.writeAll(buf[0..n]);
            }
        }
        try term.resetStyle(out);
        try out.flush();
    }
};

/// Cells a markup string occupies (`table.cells` is the one counter).
pub const visibleLen = table_mod.cells;

/// Word-wrap markup text to `width` cells. A colour open at a break is
/// closed at the line's end and reopened on the next, so each line draws
/// on its own. A word wider than the line gets a line to itself (clipped).
pub fn wrap(alloc: std.mem.Allocator, s: []const u8, width: usize) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    var cells: usize = 0;
    var open: ?u8 = null; // markup letter in force at the end of `line`
    var words = std.mem.tokenizeScalar(u8, s, ' ');
    while (words.next()) |word| {
        const w = visibleLen(word);
        if (cells > 0 and cells + 1 + w > width) {
            if (open != null) try line.appendSlice(alloc, "{/}");
            try out.append(alloc, try line.toOwnedSlice(alloc));
            cells = 0;
            if (open) |m| try line.appendSlice(alloc, &.{ '{', m, '}' });
        }
        if (cells > 0) {
            try line.append(alloc, ' ');
            cells += 1;
        }
        try line.appendSlice(alloc, word);
        cells += w;
        // Track the colour the word leaves open.
        var t: table_mod.Tokenizer = .{ .s = word };
        while (t.next()) |tok| switch (tok) {
            .mark => |m| open = if (m == '/') null else m,
            .glyph => {},
        };
    }
    if (cells > 0 or line.items.len > 0) try out.append(alloc, try line.toOwnedSlice(alloc));
    return out.toOwnedSlice(alloc);
}

/// Progress bar text (`table.bar` is the one definition, as `visibleLen`
/// is for cell counting).
pub const bar = table_mod.bar;

test "text clips to width and honours markup" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    const used = s.text(0, 0, 5, "{a}abc{/}defgh", .normal);
    try std.testing.expectEqual(@as(u16, 5), used);
    try std.testing.expectEqual(Style.amber, s.get(0, 0).style);
    try std.testing.expectEqual(@as(u21, 'c'), s.get(2, 0).ch);
    try std.testing.expectEqual(Style.normal, s.get(3, 0).style);
    try std.testing.expectEqual(@as(u21, ' '), s.get(5, 0).ch); // clipped
    try std.testing.expectEqual(@as(usize, 8), visibleLen("{a}abc{/}defgh"));
}

test "pane borders land on the rect's edges" {
    var s = try Screen.init(std.testing.allocator, 20, 6);
    defer s.deinit();
    const inner = s.pane(.{ .x = 2, .y = 1, .w = 10, .h = 4 }, .{ .title = "T" });
    try std.testing.expectEqual(@as(u21, '┌'), s.get(2, 1).ch);
    try std.testing.expectEqual(@as(u21, '┘'), s.get(11, 4).ch);
    try std.testing.expectEqual(@as(u21, 'T'), s.get(4, 1).ch);
    try std.testing.expectEqual(@as(u16, 6), inner.w);
    try std.testing.expectEqual(@as(u16, 2), inner.h);
}

test "blit fits a square image at a 2:1 cell aspect and emits pixel cells" {
    var s = try Screen.init(std.testing.allocator, 20, 6);
    defer s.deinit();
    const bytes = @embedFile("testdata/rgb4x3.png");
    var img = try png.decode(std.testing.allocator, bytes);
    defer img.deinit(std.testing.allocator);
    s.blit(.{ .x = 0, .y = 0, .w = 20, .h = 6 }, &img);
    // 4×3 image in a 20×6 rect: 6 rows would need 16 cols → fits; 12 pixel rows sampled from 3.
    var painted: usize = 0;
    for (s.cells) |c| if (c.px != null) {
        painted += 1;
    };
    try std.testing.expect(painted > 0);
    try std.testing.expectEqual(Rgb{ 255, 0, 0 }, s.cells[(0) * 20 + 2].px.?.top);
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try s.flush(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "38;2;255;0;0") != null);
}

test "wrap breaks on spaces and carries an open colour across lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try wrap(a, "rating B  ·  {d}beachhead: ×1.3 pay · slow resupply{/} end", 16);
    for (w) |l| try std.testing.expect(visibleLen(l) <= 16);
    try std.testing.expectEqualStrings("rating B ·", w[0]);
    try std.testing.expectEqualStrings("{d}beachhead: ×1.3{/}", w[1]);
    try std.testing.expectEqualStrings("{d}pay · slow{/}", w[2]);
    try std.testing.expectEqualStrings("{d}resupply{/} end", w[3]);
}

// The Desk's LOG modal wraps an entry to `Rect.inner().w` and draws it in
// the pane that same rect makes; if the two ever disagreed the last word
// of a full line would be clipped away.
test "text wrapped to a pane's inner width draws without clipping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const box: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 6 };
    const rows = try wrap(a, "{d}d1234{/} {a}alpha bravo charlie delta echo{/}", box.inner().w);
    var s = try Screen.init(std.testing.allocator, box.w, box.h);
    defer s.deinit();
    const inner = s.pane(box, .{ .title = "LOG ENTRY", .double = true });
    try std.testing.expectEqual(inner.w, box.inner().w);
    s.lines(inner, rows, 0, null);
    try std.testing.expect(rows.len > 1); // it really did wrap
    for (rows, 0..) |l, i| {
        try std.testing.expect(visibleLen(l) <= inner.w);
        // The border still owns the last column: nothing was clipped onto it.
        try std.testing.expectEqual(@as(u21, '\u{2551}'), s.get(box.x + box.w - 1, inner.y + @as(u16, @intCast(i))).ch);
    }
}

test "table pins the first column, clamps the scroll and clips at the edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Screen.init(std.testing.allocator, 20, 3);
    defer s.deinit();
    const t: Table = .{
        .cols = &.{ .{ .name = "kind" }, .{ .name = "world" }, .{ .name = "pay", .justify = .right }, .{ .name = "note" } },
        .rows = &.{try table_mod.row(a, &.{ "raid", "Galatea", "1,200", "negotiated" })},
    };
    var scroll: usize = 0;
    const v = try s.table(a, s.full(), t, 0, 0, &scroll);
    // kind(4) + gap + world(7) + gap + pay(5) = 20: note is off the edge.
    try std.testing.expectEqual(@as(usize, 1), v.hidden_right);
    try std.testing.expectEqual(@as(u21, 'G'), s.get(6, 1).ch);
    try std.testing.expectEqual(Style.sel, s.get(0, 1).style);
    // Scrolling hides world; the note then fits, so a further scroll is clamped.
    scroll = 5;
    const v2 = try s.table(a, s.full(), t, 0, null, &scroll);
    try std.testing.expectEqual(@as(usize, 2), scroll);
    try std.testing.expectEqual(@as(usize, 0), v2.hidden_right);
    try std.testing.expectEqual(@as(u21, 'n'), s.get(6, 1).ch);
    try std.testing.expectEqual(@as(u21, 'r'), s.get(0, 1).ch);
}

test "table drops a droppable column instead of scrolling to it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Screen.init(std.testing.allocator, 20, 3);
    defer s.deinit();
    const t: Table = .{
        .cols = &.{ .{ .name = "kind" }, .{ .name = "total", .justify = .right, .drop = 1 }, .{ .name = "world" }, .{ .name = "pay", .justify = .right } },
        .rows = &.{try table_mod.row(a, &.{ "raid", "9,999", "Galatea", "1,200" })},
    };
    var scroll: usize = 0;
    const v = try s.table(a, s.full(), t, 0, null, &scroll);
    // Without "total", kind(4) + gap + world(7) + gap + pay(5) = 20 fits.
    try std.testing.expectEqual(@as(usize, 0), v.hidden_left + v.hidden_right);
    try std.testing.expectEqual(@as(u21, 'G'), s.get(6, 1).ch);
    try std.testing.expectEqual(@as(u21, '1'), s.get(15, 1).ch);
}

test "invalid UTF-8 draws a replacement character instead of crashing" {
    var s = try Screen.init(std.testing.allocator, 10, 1);
    defer s.deinit();
    _ = s.text(0, 0, 10, "a\xffb", .normal);
    try std.testing.expectEqual(@as(u21, 'a'), s.get(0, 0).ch);
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.get(1, 0).ch);
    try std.testing.expectEqual(@as(u21, 'b'), s.get(2, 0).ch);
    // A sequence cut off at the end of the string is one replacement too.
    _ = s.text(0, 0, 10, "ab\xe2\x82", .normal);
    try std.testing.expectEqual(@as(u21, 0xFFFD), s.get(2, 0).ch);
}

test "control characters draw as a question mark, never reach the terminal" {
    var s = try Screen.init(std.testing.allocator, 10, 1);
    defer s.deinit();
    _ = s.text(0, 0, 10, "a\x1b[31mb\x7f\xc2\x9b", .normal);
    try std.testing.expectEqual(@as(u21, '?'), s.get(1, 0).ch); // ESC
    try std.testing.expectEqual(@as(u21, '['), s.get(2, 0).ch);
    try std.testing.expectEqual(@as(u21, '?'), s.get(7, 0).ch); // DEL
    try std.testing.expectEqual(@as(u21, '?'), s.get(8, 0).ch); // C1 CSI
    // The width the tables measure is the width the screen draws.
    try std.testing.expectEqual(@as(usize, 9), table_mod.cells("a\x1b[31mb\x7f\xc2\x9b"));
}

test "a resize that cannot allocate keeps the old buffer" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var s = try Screen.init(failing.allocator(), 10, 3);
    defer s.deinit();
    try std.testing.expectError(error.OutOfMemory, s.resize(20, 5));
    try std.testing.expectEqual(@as(u16, 10), s.cols);
    s.put(9, 2, 'x', .normal);
    try std.testing.expectEqual(@as(u21, 'x'), s.get(9, 2).ch);
}

test "an escaped name draws literally inside a coloured span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = try Screen.init(std.testing.allocator, 12, 1);
    defer s.deinit();
    var b = table_mod.MarkupBuilder.init(arena.allocator());
    try b.appendMarkup("{c}");
    try b.appendPlain("{/}A");
    try b.appendMarkup("{/}");
    _ = s.text(0, 0, 12, try b.finish(), .normal);
    try std.testing.expectEqual(@as(u21, '{'), s.get(0, 0).ch);
    try std.testing.expectEqual(@as(u21, '/'), s.get(1, 0).ch);
    try std.testing.expectEqual(@as(u21, 'A'), s.get(3, 0).ch);
    for (0..4) |x| try std.testing.expectEqual(Style.crit, s.get(@intCast(x), 0).style);
}

test "every markup tag has a style" {
    for (table_mod.marks) |m| try std.testing.expect(Style.fromMarkup(m) != null);
    try std.testing.expect(Style.fromMarkup('x') == null);
}
