//! Cell buffer and drawing primitives for the TUI (docs/tui.md
//! "Rendering"): every frame is composed into a grid of cells by
//! arithmetic — panes at computed rectangles, text padded or clipped to
//! its pane — then flushed as ANSI. Styles are semantic (amber, good,
//! critical, selected, dim) so the client holds on any terminal theme;
//! chrome roles (borders, titles, a modal's frame) take their SGR from the
//! look's palette (src/tui/theme.zig).
//! Inline markup `{a}…{/}` uses the tag set of docs/tui_mockup_gen.py so
//! query text can carry emphasis. Pure: no I/O except `flush`.
//! No MekHQ counterpart: MekHQ draws with Swing (docs/mekhq-map.md).

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
    // Chrome roles: their SGR comes from the screen's palette.
    box, // borders
    focus, // the focused pane's border line
    pane_title, // an unfocused pane's title
    modal_box, // a modal's border
    modal_title, // a modal's title band
    shadow, // a modal's shadow
    scrim, // everything beneath an open modal
    // Political colours for the star map.
    blue,
    red,
    yellow,
    green,
    magenta,
    cyan,
    white,
    grey,
    // Great House territory on the star map, faint.
    blue_land,
    red_land,
    yellow_land,
    green_land,
    magenta_land,

    /// The style's SGR: a chrome role's from `palette`, every other style's
    /// the same under every palette (rule 43).
    pub fn sgr(self: Style, palette: *const term.Palette) []const u8 {
        return switch (self) {
            .normal => term.sgr.reset,
            .dim => term.sgr.dim,
            .amber => term.sgr.amber,
            .good => term.sgr.good,
            .crit => term.sgr.crit,
            .sel => term.sgr.sel,
            .tab => term.sgr.tab,
            .purple => term.sgr.purple,
            .box => palette.box,
            .focus => palette.focus,
            .pane_title => palette.pane_title,
            .modal_box => palette.modal_box,
            .modal_title => palette.modal_title,
            .shadow => palette.shadow,
            .scrim => palette.scrim,
            .blue => term.sgr.blue,
            .red => term.sgr.red,
            .yellow => term.sgr.yellow,
            .green => term.sgr.green,
            .magenta => term.sgr.magenta,
            .cyan => term.sgr.cyan,
            .white => term.sgr.white,
            .grey => term.sgr.grey,
            .blue_land => term.sgr.blue_land,
            .red_land => term.sgr.red_land,
            .yellow_land => term.sgr.yellow_land,
            .green_land => term.sgr.green_land,
            .magenta_land => term.sgr.magenta_land,
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

/// How chrome is drawn (docs/tui.md "Rendering"): the chrome roles' SGR,
/// whether an open modal scrims the screen beneath it, and whether a modal
/// casts a shadow. Semantic styles never depend on it (rule 43).
pub const Look = struct {
    palette: *const term.Palette = &term.palette.classic,
    scrim: bool = false,
    shadow: bool = false,
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
    /// The theme's look; the client applies the stored theme before its
    /// first frame (src/tui/theme.zig).
    look: Look = .{},

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
            // Difficulty pips fall back to a letter under --ascii, and a
            // replaced byte to a question mark.
            const glyph: u21 = if (self.ascii) switch (cp) {
                '●' => 'O',
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
        /// The modal frame, the one every modal draws (rule 36): the double
        /// rule, the modal border and title roles, and the look's shadow.
        modal: bool = false,
    };

    /// Draw a bordered pane; returns its inner rect.
    pub fn pane(self: *Screen, r: Rect, opts: PaneOpts) Rect {
        if (r.w < 2 or r.h < 2) return r.inner();
        const a = self.ascii;
        const h: u21 = if (a) (if (opts.modal) '=' else '-') else if (opts.modal) '═' else '─';
        const v: u21 = if (a) '|' else if (opts.modal) '║' else '│';
        const tl: u21 = if (a) '+' else if (opts.modal) '╔' else '┌';
        const tr: u21 = if (a) '+' else if (opts.modal) '╗' else '┐';
        const bl: u21 = if (a) '+' else if (opts.modal) '╚' else '└';
        const br: u21 = if (a) '+' else if (opts.modal) '╝' else '┘';
        const x0: i32 = r.x;
        const y0: i32 = r.y;
        const x1: i32 = r.x + r.w - 1;
        const y1: i32 = r.y + r.h - 1;
        // Clear everything inside the border, padding columns included, so a
        // modal never shows the screen beneath it.
        self.fill(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, ' ', .normal);
        const border: Style = if (opts.modal) .modal_box else .box;
        const tstyle: Style = if (opts.modal) .modal_title else if (opts.focused) .sel else .pane_title;
        const line_style: Style = if (opts.modal) .modal_box else if (opts.focused) .focus else .box;
        var x: i32 = x0 + 1;
        while (x < x1) : (x += 1) {
            self.put(x, y0, h, line_style);
            self.put(x, y1, h, border);
        }
        var y: i32 = y0 + 1;
        while (y < y1) : (y += 1) {
            self.put(x0, y, v, border);
            self.put(x1, y, v, border);
        }
        self.put(x0, y0, tl, border);
        self.put(x1, y0, tr, border);
        self.put(x0, y1, bl, border);
        self.put(x1, y1, br, border);
        if (opts.modal and self.look.shadow) self.shadow(r);
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

    /// A modal's one-cell shadow right of and below `r`: `░`, or `.` under
    /// `--ascii` (docs/tui.md "Boundary rules"). It never takes the last
    /// row, the status line a modal's actions report on (docs/tui.md "The
    /// frame"); `put` clips it at the screen's right edge.
    fn shadow(self: *Screen, r: Rect) void {
        const g: u21 = if (self.ascii) '.' else '░';
        const right: i32 = @as(i32, r.x) + r.w;
        const below: i32 = @as(i32, r.y) + r.h;
        const status_row: i32 = @as(i32, self.rows) - 1;
        var y: i32 = @as(i32, r.y) + 1;
        while (y <= below and y < status_row) : (y += 1) self.put(right, y, g, .shadow);
        if (below >= status_row) return;
        var x: i32 = @as(i32, r.x) + 1;
        while (x < right) : (x += 1) self.put(x, below, g, .shadow);
    }

    /// Recede everything drawn so far behind a modal about to be drawn over
    /// it: every text cell takes `.scrim` and every pixel cell drops to half
    /// intensity. Nothing changes when the look has no scrim.
    pub fn scrim(self: *Screen) void {
        if (!self.look.scrim) return;
        for (self.cells) |*c| {
            if (c.px) |*p| {
                p.top = halfIntensity(p.top);
                p.bottom = halfIntensity(p.bottom);
            } else c.style = .scrim;
        }
    }

    fn halfIntensity(c: Rgb) Rgb {
        return .{ c[0] / 2, c[1] / 2, c[2] / 2 };
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
                    try out.writeAll(c.style.sgr(self.look.palette));
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

/// A look that scrims and casts shadows, for the frame tests.
const shadowed: Look = .{ .palette = &term.palette.standard, .scrim = true, .shadow = true };

test "a modal frame draws modal border and title roles and a shadow; an ordinary pane casts none" {
    var s = try Screen.init(std.testing.allocator, 30, 12);
    defer s.deinit();
    s.look = shadowed;
    _ = s.pane(.{ .x = 0, .y = 0, .w = 10, .h = 4 }, .{ .title = "P" });
    _ = s.pane(.{ .x = 0, .y = 5, .w = 10, .h = 4 }, .{ .title = "F", .focused = true });
    _ = s.pane(.{ .x = 12, .y = 1, .w = 10, .h = 5 }, .{ .title = "M", .modal = true });
    // The ordinary panes: plain borders, the pane-title and selected roles.
    try std.testing.expectEqual(Style.box, s.get(0, 1).style);
    try std.testing.expectEqual(Style.pane_title, s.get(2, 0).style);
    try std.testing.expectEqual(Style.focus, s.get(4, 5).style);
    try std.testing.expectEqual(Style.box, s.get(0, 6).style);
    try std.testing.expectEqual(Style.sel, s.get(2, 5).style);
    // Nothing right of or below them.
    for (0..9) |y| try std.testing.expectEqual(Cell{}, s.get(10, @intCast(y)));
    try std.testing.expectEqual(Cell{}, s.get(5, 4));
    // The modal: the double rule in the modal roles, title band included.
    try std.testing.expectEqual(Cell{ .ch = '╔', .style = .modal_box }, s.get(12, 1));
    try std.testing.expectEqual(Cell{ .ch = '║', .style = .modal_box }, s.get(21, 3));
    try std.testing.expectEqual(Cell{ .ch = '═', .style = .modal_box }, s.get(17, 5));
    try std.testing.expectEqual(Cell{ .ch = 'M', .style = .modal_title }, s.get(14, 1));
    try std.testing.expectEqual(Style.modal_title, s.get(13, 1).style);
    // Its shadow: the column right of it from its second row, and the row
    // below it from its second column, corner included.
    try std.testing.expectEqual(Cell{}, s.get(22, 1));
    for (2..7) |y| try std.testing.expectEqual(Cell{ .ch = '░', .style = .shadow }, s.get(22, @intCast(y)));
    try std.testing.expectEqual(Cell{}, s.get(12, 6));
    for (13..23) |x| try std.testing.expectEqual(Cell{ .ch = '░', .style = .shadow }, s.get(@intCast(x), 6));
}

test "a modal's shadow is a dot under --ascii, clipped at the right edge and kept off the status row" {
    var s = try Screen.init(std.testing.allocator, 20, 8);
    defer s.deinit();
    s.look = shadowed;
    s.ascii = true;
    // Flush right and down to the row above the status row: the shadow
    // column falls off the screen and the shadow row would be the status row.
    _ = s.pane(.{ .x = 10, .y = 2, .w = 10, .h = 5 }, .{ .title = "M", .modal = true });
    try std.testing.expectEqual(Cell{ .ch = '+', .style = .modal_box }, s.get(10, 2));
    try std.testing.expectEqual(Cell{ .ch = '=', .style = .modal_box }, s.get(15, 6));
    for (0..20) |x| try std.testing.expectEqual(Cell{}, s.get(@intCast(x), 7));
    // One row higher, the shadow row is drawn, in dots.
    s.clear();
    _ = s.pane(.{ .x = 2, .y = 1, .w = 10, .h = 5 }, .{ .title = "M", .modal = true });
    for (3..13) |x| try std.testing.expectEqual(Cell{ .ch = '.', .style = .shadow }, s.get(@intCast(x), 6));
    for (2..7) |y| try std.testing.expectEqual(Cell{ .ch = '.', .style = .shadow }, s.get(12, @intCast(y)));
    for (0..20) |x| try std.testing.expectEqual(Cell{}, s.get(@intCast(x), 7));
}

test "the scrim restyles every text cell and halves every pixel cell, and the modal drawn after it keeps its styles" {
    var s = try Screen.init(std.testing.allocator, 20, 6);
    defer s.deinit();
    s.look = shadowed;
    _ = s.text(0, 0, 20, "{a}amber{/} {c}crit{/}", .normal);
    _ = s.pane(.{ .x = 0, .y = 1, .w = 8, .h = 4 }, .{ .title = "P", .focused = true });
    s.cells[19] = .{ .px = .{ .top = .{ 200, 101, 0 }, .bottom = .{ 10, 255, 1 } } };
    s.scrim();
    for (s.cells, 0..) |c, i| {
        if (i == 19) {
            try std.testing.expectEqual(Pixels{ .top = .{ 100, 50, 0 }, .bottom = .{ 5, 127, 0 } }, c.px.?);
        } else try std.testing.expectEqual(Style.scrim, c.style);
    }
    try std.testing.expectEqual(@as(u21, 'a'), s.get(0, 0).ch);
    const inner = s.pane(.{ .x = 9, .y = 1, .w = 10, .h = 4 }, .{ .title = "M", .modal = true });
    _ = s.text(inner.x, inner.y, inner.w, "{g}ok{/}", .normal);
    try std.testing.expectEqual(Style.modal_box, s.get(9, 1).style);
    try std.testing.expectEqual(Style.modal_title, s.get(11, 1).style);
    try std.testing.expectEqual(Style.good, s.get(inner.x, inner.y).style);
    try std.testing.expectEqual(Style.normal, s.get(inner.x + 3, inner.y).style);
    try std.testing.expectEqual(Style.scrim, s.get(8, 2).style);
}

test "the default look is classic: no scrim, no shadow, and the base SGR for every style it had" {
    var s = try Screen.init(std.testing.allocator, 20, 8);
    defer s.deinit();
    _ = s.text(0, 0, 20, "{a}amber{/}", .normal);
    s.scrim();
    try std.testing.expectEqual(Style.amber, s.get(0, 0).style);
    _ = s.pane(.{ .x = 2, .y = 1, .w = 10, .h = 4 }, .{ .title = "M", .modal = true });
    for (0..8) |y| try std.testing.expectEqual(Cell{}, s.get(12, @intCast(y)));
    // The single-style chrome's bytes, pinned: every style that predates
    // the chrome roles, and the roles drawn as `box`.
    const p = s.look.palette;
    const pinned = [_]struct { style: Style, sgr: []const u8 }{
        .{ .style = .normal, .sgr = "\x1b[0m" },         .{ .style = .dim, .sgr = "\x1b[0;90m" },
        .{ .style = .amber, .sgr = "\x1b[0;33m" },       .{ .style = .good, .sgr = "\x1b[0;32m" },
        .{ .style = .crit, .sgr = "\x1b[0;31m" },        .{ .style = .sel, .sgr = "\x1b[0;30;46m" },
        .{ .style = .tab, .sgr = "\x1b[0;1;30;43m" },    .{ .style = .purple, .sgr = "\x1b[0;35m" },
        .{ .style = .box, .sgr = "\x1b[0;37m" },         .{ .style = .focus, .sgr = "\x1b[0;36m" },
        .{ .style = .blue, .sgr = "\x1b[0;94m" },        .{ .style = .red, .sgr = "\x1b[0;91m" },
        .{ .style = .yellow, .sgr = "\x1b[0;93m" },      .{ .style = .green, .sgr = "\x1b[0;92m" },
        .{ .style = .magenta, .sgr = "\x1b[0;95m" },     .{ .style = .cyan, .sgr = "\x1b[0;96m" },
        .{ .style = .white, .sgr = "\x1b[0;97m" },       .{ .style = .grey, .sgr = "\x1b[0;90m" },
        .{ .style = .pane_title, .sgr = "\x1b[0;37m" },  .{ .style = .modal_box, .sgr = "\x1b[0;37m" },
        .{ .style = .modal_title, .sgr = "\x1b[0;37m" },
    };
    for (pinned) |want| try std.testing.expectEqualStrings(want.sgr, want.style.sgr(p));
}

test "the territory styles are faint normal-intensity house colours" {
    const pinned = [_]struct { style: Style, sgr: []const u8 }{
        .{ .style = .blue_land, .sgr = "\x1b[0;2;34m" },
        .{ .style = .red_land, .sgr = "\x1b[0;2;31m" },
        .{ .style = .yellow_land, .sgr = "\x1b[0;2;33m" },
        .{ .style = .green_land, .sgr = "\x1b[0;2;32m" },
        .{ .style = .magenta_land, .sgr = "\x1b[0;2;35m" },
    };
    for (pinned) |want| try std.testing.expectEqualStrings(want.sgr, want.style.sgr(&term.palette.classic));
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
    const inner = s.pane(box, .{ .title = "LOG ENTRY", .modal = true });
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
