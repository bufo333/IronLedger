//! Cell buffer and drawing primitives for the TUI (docs/tui.md
//! "Rendering"): every frame is composed into a grid of cells by
//! arithmetic — panes at computed rectangles, text padded or clipped to
//! its pane — then flushed as ANSI. Styles are semantic (amber, good,
//! critical, selected, dim) so the client holds on any terminal theme.
//! Inline markup `{a}…{/}` matches the mockup generator's so query text
//! can carry emphasis. Pure: no I/O except `flush`.

const std = @import("std");

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

    fn sgr(self: Style) []const u8 {
        return switch (self) {
            .normal => "\x1b[0m",
            .dim => "\x1b[0;90m",
            .amber => "\x1b[0;33m",
            .good => "\x1b[0;32m",
            .crit => "\x1b[0;31m",
            .sel => "\x1b[0;30;46m",
            .tab => "\x1b[0;1;30;43m",
            .purple => "\x1b[0;35m",
            .box => "\x1b[0;37m",
        };
    }

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

pub const Rgb = [3]u8;

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

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const cells = try alloc.alloc(Cell, @as(usize, cols) * rows);
        @memset(cells, .{});
        return .{ .alloc = alloc, .cols = cols, .rows = rows, .cells = cells };
    }

    pub fn deinit(self: *Screen) void {
        self.alloc.free(self.cells);
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16) !void {
        self.alloc.free(self.cells);
        self.cells = try self.alloc.alloc(Cell, @as(usize, cols) * rows);
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
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == '{') {
                // markup token: `{a}` … `{/}`
                const rest = it.bytes[it.i..];
                if (rest.len >= 2 and rest[1] == '}') {
                    if (Style.fromMarkup(rest[0])) |st| {
                        style = if (st == .normal) base else st;
                        it.i += 2;
                        continue;
                    }
                }
            }
            if (col >= limit) break;
            self.put(col, y, cp, style);
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
        const h: u21 = if (opts.double) '═' else '─';
        const v: u21 = if (opts.double) '║' else '│';
        const tl: u21 = if (opts.double) '╔' else '┌';
        const tr: u21 = if (opts.double) '╗' else '┐';
        const bl: u21 = if (opts.double) '╚' else '└';
        const br: u21 = if (opts.double) '╝' else '┘';
        const x0: i32 = r.x;
        const y0: i32 = r.y;
        const x1: i32 = r.x + r.w - 1;
        const y1: i32 = r.y + r.h - 1;
        self.fill(r.inner(), ' ', .normal);
        const tstyle: Style = if (opts.focused) .sel else .box;
        var x: i32 = x0 + 1;
        while (x < x1) : (x += 1) {
            self.put(x, y0, h, tstyle);
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

    fn c256(c: Rgb) u8 {
        const r: u8 = @intCast((@as(u16, c[0]) * 5 + 127) / 255);
        const g: u8 = @intCast((@as(u16, c[1]) * 5 + 127) / 255);
        const b: u8 = @intCast((@as(u16, c[2]) * 5 + 127) / 255);
        return 16 + 36 * r + 6 * g + b;
    }

    /// Emit the whole frame (turn-based UI: a full repaint per event is
    /// cheap and never leaves artifacts).
    pub fn flush(self: *Screen, out: *std.Io.Writer) !void {
        try out.writeAll("\x1b[H");
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            try out.print("\x1b[{d};1H", .{y + 1});
            var cur: ?Style = null;
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const c = self.get(x, y);
                if (c.px) |p| {
                    if (self.truecolor) {
                        try out.print("\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}m▀", .{ p.top[0], p.top[1], p.top[2], p.bottom[0], p.bottom[1], p.bottom[2] });
                    } else {
                        try out.print("\x1b[0;38;5;{d};48;5;{d}m▀", .{ c256(p.top), c256(p.bottom) });
                    }
                    cur = null;
                    continue;
                }
                if (cur == null or cur.? != c.style) {
                    try out.writeAll(c.style.sgr());
                    cur = c.style;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.ch, &buf) catch 1;
                try out.writeAll(buf[0..n]);
            }
        }
        try out.writeAll("\x1b[0m");
        try out.flush();
    }
};

/// Cells a markup string occupies.
pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '{') {
            const rest = it.bytes[it.i..];
            if (rest.len >= 2 and rest[1] == '}' and Style.fromMarkup(rest[0]) != null) {
                it.i += 2;
                continue;
            }
        }
        n += 1;
    }
    return n;
}

/// Progress bar text: `#` filled, `-` empty.
pub fn bar(buf: []u8, num: i64, den: i64) []const u8 {
    const width = buf.len;
    const filled: usize = if (den <= 0) 0 else @intCast(@min(@as(i64, @intCast(width)), @divTrunc(@max(0, num) * @as(i64, @intCast(width)), den)));
    @memset(buf[0..filled], '#');
    @memset(buf[filled..], '-');
    return buf;
}

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

test "bar fills proportionally" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("#####-----", bar(&buf, 50, 100));
    try std.testing.expectEqualStrings("----------", bar(&buf, 0, 0));
}
