//! The Map screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Style = app.Style;
const factions = app.factions;
const layout = app.layout;
const q = app.q;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const s = &self.screen;
    const b = self.body();
    const view = try q.map(al, g);
    if (view.worlds.len == 0) return;
    if (self.map_cursor >= view.worlds.len) self.map_cursor = 0;
    const mw: u16 = if (layout.wide(b.w)) layout.three_quarters.of(b.w) else b.w;
    const inner = s.pane(.{ .x = b.x, .y = b.y, .w = mw, .h = b.h }, .{ .title = try std.fmt.allocPrint(al, "STAR MAP · colour by {s}", .{@tagName(self.map_color)}), .focused = true, .right_title = try std.fmt.allocPrint(al, "{d} worlds · {d} in ring · {d} beachhead · {d} dark · zoom ×{d}  {s}", .{ view.worlds.len, view.in_ring, view.in_band, view.dark, self.map_zoom, try app.keys.paneTitle(al, &legend, 0) }) });
    const cw = view.worlds[self.map_cursor];
    const geom = App.mapGeom(view, inner, self.map_zoom, .{ cw.x, cw.y });
    var offscreen: u32 = 0;
    for (view.worlds) |w| if (!geom.inside(geom.cell(w.x, w.y))) {
        offscreen += 1;
    };
    // rings and beachhead bands
    for (view.hqs) |h| {
        var k: usize = 0;
        while (k < 720) : (k += 1) {
            const ang = @as(f64, @floatFromInt(k)) * std.math.pi / 360.0;
            const rr: f64 = @floatFromInt(h.ring_ly);
            const bb: f64 = @floatFromInt(h.ring_ly + view.band_ly);
            const c1 = geom.cell(h.x + @as(i32, @intFromFloat(rr * @cos(ang))), h.y + @as(i32, @intFromFloat(rr * @sin(ang))));
            if (geom.inside(c1)) s.put(c1[0], c1[1], '.', .dim);
            const c2 = geom.cell(h.x + @as(i32, @intFromFloat(bb * @cos(ang))), h.y + @as(i32, @intFromFloat(bb * @sin(ang))));
            if (geom.inside(c2)) s.put(c2[0], c2[1], ',', .dim);
        }
    }
    for (view.worlds, 0..) |w, i| {
        const c = geom.cell(w.x, w.y);
        if (!geom.inside(c)) continue;
        const is_cursor = i == self.map_cursor;
        const marked = w.hq_here != .none or w.offers_here > 0 or w.companies_here > 0 or w.worked > 0;
        const mark: u21 = if (w.hq_here != .none) '@' else if (is_cursor) '*' else if (self.map_zoom > 1 or marked) 'o' else '·';
        // Colour by the chosen political/economic lens.
        const lens: Style = switch (self.map_color) {
            .faction => App.factionStyle(w.faction),
            .industry => if (w.industry >= 4) .good else if (w.industry >= 2) .normal else .dim,
            .standing => if (w.standing >= 25) .good else if (w.standing > 0) .green else if (w.standing <= -40) .crit else if (w.standing < 0) .amber else .dim,
            .activity => if (w.hq_here != .none) .amber else if (w.companies_here > 0) .good else if (w.offers_here > 0) .yellow else if (w.worked > 0) .purple else .dim,
        };
        const mst: Style = if (is_cursor) .sel else if (w.hq_here != .none and self.map_color != .activity) .amber else lens;
        s.put(c[0], c[1], mark, mst);
        // Names: every world when zoomed in, otherwise only the ones that matter.
        if (self.map_zoom > 1 or marked or is_cursor) {
            const nst: Style = if (is_cursor) .sel else if (w.band == .dark) .dim else lens;
            const nw: u16 = @intCast(@max(0, @min(@as(i32, @intCast(w.name.len)), inner.x + inner.w - c[0] - 2)));
            _ = s.text(c[0] + 2, c[1], nw, w.name, nst);
            if (w.worked > 0 and w.hq_here == .none) s.put(c[0] + 3 + @as(i32, nw), c[1], '=', .purple);
            if (w.offers_here > 0) s.put(c[0] + 3 + @as(i32, nw), c[1], '^', .amber);
            if (w.companies_here > 0 and w.hq_here == .none) s.put(c[0] + 3 + @as(i32, nw), c[1], '+', .good);
            continue;
        }
        const nw: u16 = 0;
        if (w.worked > 0 and w.hq_here == .none) s.put(c[0] + 3 + @as(i32, nw), c[1], '=', .purple);
        if (w.offers_here > 0) s.put(c[0] + 3 + @as(i32, nw), c[1], '^', .amber);
        if (w.companies_here > 0 and w.hq_here == .none) s.put(c[0] + 3 + @as(i32, nw), c[1], '+', .good);
    }
    if (mw < b.w) {
        const colour_legend: []const u8 = switch (self.map_color) {
            .faction => try q.factionKeyLine(al),
            .industry => "{g}bright = industry 4–5{/}   normal = 2–3   {d}dim = backwater{/}",
            .standing => "{g}green = favoured{/}   {a}amber = below zero{/}   {c}red = shunned{/}   {d}dim = neutral{/}",
            .activity => "{a}@ HQ{/}   {g}+ company{/}   {a}^ offers{/}   {p}= worked{/}   {d}dim = nothing yet{/}",
        };
        s.textPad(inner.x, inner.y + inner.h - 1, inner.w, if (offscreen > 0) try std.fmt.allocPrint(al, "{s}   {{d}}· names show at zoom ×2 ·{{/}} {{a}}{d} off screen{{/}}", .{ colour_legend, offscreen }) else try std.fmt.allocPrint(al, "{s}   {{d}}· names show at zoom ×2{{/}}", .{colour_legend}), .normal);
    } else {
        const w = view.worlds[self.map_cursor];
        s.textPad(inner.x, inner.y + inner.h - 1, inner.w, try std.fmt.allocPrint(al, "{{a}}{s}{{/}} {s} · ind {d} · {d} LY · {s} · {d} offers", .{
            w.name,        w.faction, w.industry, w.dist_ly,
            switch (w.band) {
                .ring => "{g}in ring{/}",
                .beachhead => "{a}beachhead{/}",
                .dark => "{d}out of reach{/}",
            },
            w.offers_here,
        }), .normal);
    }

    if (mw < b.w) {
        const w = view.worlds[self.map_cursor];
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        try rows.appendSlice(al, try q.worldDetail(al, g, &view, &w));
        const side_h: u16 = layout.major.of(b.h);
        self.listPane(.{ .x = b.x + mw, .y = b.y, .w = b.w - mw, .h = side_h }, "WORLD", rows.items, 1, false, false);
        var reach: std.ArrayListUnmanaged([]const u8) = .empty;
        try reach.append(al, try std.fmt.allocPrint(al, "in ring         {d} worlds", .{view.in_ring}));
        try reach.append(al, try std.fmt.allocPrint(al, "beachhead band  {d} worlds  {{a}}×1.3 pay{{/}}", .{view.in_band}));
        try reach.append(al, try std.fmt.allocPrint(al, "out of reach    {d} worlds", .{view.dark}));
        try reach.append(al, "");
        for (view.hqs) |h| try reach.append(al, try std.fmt.allocPrint(al, "{s}  ring {d} LY (+{d} band)", .{ q.clip(try h.name.markup(al), 24), h.ring_ly, view.band_ly }));
        try reach.append(al, "");
        try reach.append(al, "{d}rings grow with comms and spaceport levels{/}");
        if (self.map_color == .faction) {
            // The legend in full: every key on the map with its name.
            try reach.append(al, "");
            try reach.append(al, "factions   {d}key · colour · name{/}");
            try reach.appendSlice(al, try q.factionRows(al));
        }
        self.listPane(.{ .x = b.x + mw, .y = b.y + side_h, .w = b.w - mw, .h = b.h - side_h }, if (self.map_color == .faction) "REACH · FACTIONS" else "REACH", reach.items, 2, false, false);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    try self.mapPan(0, if (delta > 0) -1 else 1);
}

const Action = enum { pan_left, pan_right, zoom_in, zoom_out, colours, found, offers };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('h'), .action = .pan_left, .label = "pan", .group = .navigate, .shown = "h l", .title = 0, .help = "pan the map west / east (j k and the arrows pan too)" },
    .{ .match = app.keys.Match.char('l'), .action = .pan_right, .label = "pan east", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('+'), .action = .zoom_in, .label = "zoom", .group = .navigate, .shown = "+ -", .title = 0, .help = "zoom in / out (names show at zoom ×2)" },
    .{ .match = app.keys.Match.char('='), .action = .zoom_in, .label = "zoom in", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('-'), .action = .zoom_out, .label = "zoom out", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('c'), .action = .colours, .label = "colours", .group = .navigate, .title = 0, .help = "colour the map by faction, industry, standing or activity" },
    .{ .match = app.keys.Match.char('f'), .action = .found, .label = "found HQ here", .group = .act, .title = 0, .help = "found an HQ on the world under the cursor (fills the command line)" },
    .{ .match = app.keys.Match.char('o'), .action = .offers, .label = "offers here", .group = .act, .title = 0, .help = "open the contract board" },
    .{ .match = .{ .key = .enter }, .action = .offers, .label = "contract board", .group = .act, .show_footer = false, .show_help = false },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = &self.gs.?;
    switch (hit.action) {
        .pan_left => try self.mapPan(-1, 0),
        .pan_right => try self.mapPan(1, 0),
        .zoom_in => self.map_zoom = @min(8, self.map_zoom * 2),
        .zoom_out => self.map_zoom = @max(1, self.map_zoom / 2),
        .colours => self.map_color = switch (self.map_color) {
            .faction => .industry,
            .industry => .standing,
            .standing => .activity,
            .activity => .faction,
        },
        .found => {
            const view = try q.map(al, g);
            if (view.worlds.len == 0) return true;
            var buf: [96]u8 = undefined;
            self.openCommand(std.fmt.bufPrint(&buf, "found {s} ", .{view.worlds[@min(self.map_cursor, view.worlds.len - 1)].key}) catch "found ");
        },
        .offers => self.switchTab(.contracts),
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the map bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "+ and - zoom the star map, and o jumps to the contract board" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .map);
    try app.pressForTest(c, .{ .char = '+' });
    try std.testing.expectEqual(@as(u8, 2), c.app.map_zoom);
    try app.pressForTest(c, .{ .char = '-' });
    try std.testing.expectEqual(@as(u8, 1), c.app.map_zoom);
    try app.pressForTest(c, .{ .char = 'o' });
    try std.testing.expectEqual(app.Tab.contracts, c.app.tab);
}
