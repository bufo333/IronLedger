//! The Map screen (docs/engineering-contract.md rule 35): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the Interstellar Map tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Rect = app.Rect;
const Screen = app.Screen;
const Style = app.Style;
const factions = app.factions;
const layout = app.layout;
const q = app.q;

/// A cell is territory of the nearest catalogue world within this many LY
/// (ties to catalogue order): about the 75th percentile of the catalogue's
/// nearest-neighbour spacing (median 27 LY, 90th percentile 54).
const territory_reach_ly: i64 = 45;
/// The interior wash marks one cell in this many along a row, shifted half
/// a step on alternate rows, so most of the land stays blank for names.
const lattice_step: usize = 4;
/// The least zoom a focus key (`w`, `H`) shows.
const focus_zoom: u8 = 4;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = self.state();
    const s = &self.screen;
    const b = self.body();
    const view = try q.map(al, g);
    if (view.worlds.len == 0) return;
    if (self.map_cursor >= view.worlds.len) self.map_cursor = 0;
    const outer = mapRect(self);
    if (!self.map_framed) frameDefault(self, view, outer.inner());
    const inner = s.pane(outer, .{ .title = try std.fmt.allocPrint(al, "STAR MAP · colour by {s}", .{@tagName(self.map_color)}), .focused = self.paneFocused(0), .right_title = try std.fmt.allocPrint(al, "{d} worlds · {d} in ring · {d} beachhead · {d} dark · zoom ×{d}  {s}", .{ view.worlds.len, view.in_ring, view.in_band, view.dark, self.map_zoom, try app.keys.paneTitle(al, &legend, 0) }) });
    const cw = view.worlds[self.map_cursor];
    const geom = App.mapGeom(view, inner, self.map_zoom, .{ cw.x, cw.y });
    if (self.map_color == .faction) try drawTerritory(s, al, view, geom);
    drawReach(s, view, geom);
    const offscreen = drawWorlds(self, view, geom);
    if (outer.w < b.w) {
        const colour_legend: []const u8 = switch (self.map_color) {
            .faction => try q.factionKeyLine(al),
            .industry => "{g}bright = industry 4–5{/}   normal = 2–3   {d}dim = backwater{/}",
            .standing => "{g}green = favoured{/}   {a}amber = below zero{/}   {c}red = shunned{/}   {d}dim = neutral{/}",
            .activity => "{a}@ HQ{/}   {g}+ company{/}   {a}^ offers{/}   {p}= worked{/}   {d}dim = nothing yet{/}",
        };
        s.textPad(inner.x, inner.y + inner.h - 1, inner.w, if (offscreen > 0) try std.fmt.allocPrint(al, "{s}   {{d}}· names show at zoom ×2 ·{{/}} {{a}}{d} off screen{{/}}", .{ colour_legend, offscreen }) else try std.fmt.allocPrint(al, "{s}   {{d}}· names show at zoom ×2{{/}}", .{colour_legend}), .normal);
        try drawSide(self, view, outer.w);
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
}

/// The star map pane: three quarters of a wide body beside the side panes,
/// all of a narrow one.
fn mapRect(self: *App) Rect {
    const b = self.body();
    return .{ .x = b.x, .y = b.y, .w = if (layout.wide(b.w)) layout.three_quarters.of(b.w) else b.w, .h = b.h };
}

/// The first Map draw of a campaign frames its first HQ (lowest id): the
/// cursor on that HQ's world, at the closest zoom that shows its whole ring
/// and beachhead band. With no HQ the view stays as it is.
fn frameDefault(self: *App, view: q.Map, inner: Rect) void {
    self.map_framed = true;
    if (view.hqs.len == 0) return;
    const h = view.hqs[0];
    self.map_cursor = h.world;
    self.map_zoom = for ([_]u8{ 8, 4, 2 }) |zoom| {
        if (reachFits(view, inner, zoom, h)) break zoom;
    } else 1;
}

/// The four extreme points of the HQ's reach, ring plus beachhead band
/// east, west, north and south, fall inside the view centred on it.
fn reachFits(view: q.Map, inner: Rect, zoom: u8, h: q.MapHq) bool {
    const geom = App.mapGeom(view, inner, zoom, .{ h.x, h.y });
    const r: i32 = @intCast(h.ring_ly + view.band_ly);
    for ([_][2]i32{ .{ h.x - r, h.y }, .{ h.x + r, h.y }, .{ h.x, h.y - r }, .{ h.x, h.y + r } }) |p| {
        if (!geom.inside(geom.cell(p[0], p[1]))) return false;
    }
    return true;
}

/// The territory style of the world owning map point `p`: the nearest
/// world within `territory_reach_ly`, ties to catalogue order; null beyond
/// reach and for a world outside Great House space.
fn ownerLand(view: q.Map, p: [2]i32) ?Style {
    var best: ?usize = null;
    var best_d2: i64 = territory_reach_ly * territory_reach_ly;
    for (view.worlds, 0..) |w, i| {
        const dx: i64 = w.x - p[0];
        const dy: i64 = w.y - p[1];
        const d2 = dx * dx + dy * dy;
        if (d2 < best_d2 or (best == null and d2 == best_d2)) {
            best = i;
            best_d2 = d2;
        }
    }
    const w = view.worlds[best orelse return null];
    if (!w.great_house) return null;
    return App.factionStyle(w.faction, .territory);
}

fn sameLand(a: ?Style, b: Style) bool {
    return if (a) |x| x == b else false;
}

/// Great House space, drawn first so everything else draws over it: `·`
/// in the owner house's territory style on every rim cell (a 4-neighbour
/// inside the pane has another owner house, or none) and on the sparse
/// interior lattice.
fn drawTerritory(s: *Screen, al: std.mem.Allocator, view: q.Map, geom: App.MapGeom) !void {
    const inner = geom.inner;
    const w: usize = inner.w;
    const h: usize = inner.h;
    const land = try al.alloc(?Style, w * h);
    for (0..h) |dy| for (0..w) |dx| {
        land[dy * w + dx] = ownerLand(view, geom.ly(.{ @as(i32, inner.x) + @as(i32, @intCast(dx)), @as(i32, inner.y) + @as(i32, @intCast(dy)) }));
    };
    for (0..h) |dy| for (0..w) |dx| {
        const i = dy * w + dx;
        const st = land[i] orelse continue;
        const rim = (dx > 0 and !sameLand(land[i - 1], st)) or (dx + 1 < w and !sameLand(land[i + 1], st)) or
            (dy > 0 and !sameLand(land[i - w], st)) or (dy + 1 < h and !sameLand(land[i + w], st));
        const lattice = (dx + (dy % 2) * (lattice_step / 2)) % lattice_step == 0;
        if (rim or lattice) s.put(@as(i32, inner.x) + @as(i32, @intCast(dx)), @as(i32, inner.y) + @as(i32, @intCast(dy)), '·', st);
    };
}

/// Each HQ's ring and beachhead band.
fn drawReach(s: *Screen, view: q.Map, geom: App.MapGeom) void {
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
}

/// Every world on screen with its name and markers, in the chosen lens;
/// returns how many worlds fall outside the view.
fn drawWorlds(self: *App, view: q.Map, geom: App.MapGeom) u32 {
    const s = &self.screen;
    const inner = geom.inner;
    var offscreen: u32 = 0;
    for (view.worlds, 0..) |w, i| {
        const c = geom.cell(w.x, w.y);
        if (!geom.inside(c)) {
            offscreen += 1;
            continue;
        }
        const is_cursor = i == self.map_cursor;
        const marked = w.hq_here != .none or w.offers_here > 0 or w.companies_here > 0 or w.worked > 0;
        const mark: u21 = if (w.hq_here != .none) '@' else if (is_cursor) '*' else 'o';
        // Colour by the chosen political/economic lens.
        const lens: Style = switch (self.map_color) {
            .faction => App.factionStyle(w.faction, .world).?, // every faction colour has a world style
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
            // The name stands clear of the territory wash on both sides.
            s.put(c[0] + 1, c[1], ' ', .normal);
            _ = s.text(c[0] + 2, c[1], nw, w.name, nst);
            s.put(c[0] + 2 + @as(i32, nw), c[1], ' ', .normal);
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
    return offscreen;
}

/// The WORLD pane on the cursor world and the REACH pane, right of a map
/// pane `mw` wide.
fn drawSide(self: *App, view: q.Map, mw: u16) !void {
    const al = self.a();
    const g = self.state();
    const b = self.body();
    {
        const w = view.worlds[self.map_cursor];
        var rows: std.ArrayListUnmanaged([]const u8) = .empty;
        try rows.appendSlice(al, try q.worldDetail(al, g, &view, &w));
        const side_h: u16 = layout.major.of(b.h);
        self.listPane(.{ .x = b.x + mw, .y = b.y, .w = b.w - mw, .h = side_h }, "WORLD", rows.items, 1, false, false);
        var reach: std.ArrayListUnmanaged([]const u8) = .empty;
        try reach.append(al, try std.fmt.allocPrint(al, "in ring         {d} worlds", .{view.in_ring}));
        var bp_bb: [16]u8 = undefined;
        try reach.append(al, try std.fmt.allocPrint(al, "beachhead band  {d} worlds  {{a}}{s} pay{{/}}", .{ view.in_band, app.types.bpText(&bp_bb, q.beachhead_pay_bp) }));
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

/// Move the cursor to world `world`, raise the zoom to at least
/// `focus_zoom`, and say where it went.
fn focusWorld(self: *App, world: usize, comptime fmt: []const u8, args: anytype) void {
    self.map_cursor = world;
    self.map_zoom = @max(self.map_zoom, focus_zoom);
    self.map_framed = true;
    self.say(.normal, fmt, args);
}

/// The distinct worlds of `worlds`, in first-seen order.
fn distinctWorlds(al: std.mem.Allocator, worlds: []const usize) ![]usize {
    var out: std.ArrayListUnmanaged(usize) = .empty;
    for (worlds) |w| if (std.mem.indexOfScalar(usize, out.items, w) == null) try out.append(al, w);
    return out.items;
}

/// The stop after the one the cursor is on, wrapping; the first stop when
/// the cursor is on none.
fn nextStop(stops: []const usize, cursor: usize) usize {
    const at = std.mem.indexOfScalar(usize, stops, cursor) orelse return 0;
    return (at + 1) % stops.len;
}

/// `w`: the next world where a company is on a running contract, in
/// contract id order.
fn focusContractWorld(self: *App) !void {
    const al = self.a();
    const view = try q.map(al, self.state());
    if (view.contracts.len == 0) return self.say(.dim, "no company is on contract", .{});
    const all = try al.alloc(usize, view.contracts.len);
    for (view.contracts, all) |c, *w| w.* = c.world;
    const stops = try distinctWorlds(al, all);
    const at = nextStop(stops, self.map_cursor);
    var here: usize = 0;
    var first: ?q.MapContract = null;
    for (view.contracts) |c| if (c.world == stops[at]) {
        here += 1;
        if (first == null) first = c;
    };
    const c = first.?; // every stop is some contract's world
    const more = if (here > 1) try std.fmt.allocPrint(al, " · {d} contracts here", .{here}) else "";
    focusWorld(self, stops[at], "contract world {d} of {d}: {s} — [{d}] co:{d} {s} ({s}){s}", .{
        at + 1,             stops.len,               view.worlds[stops[at]].name,
        @intFromEnum(c.id), @intFromEnum(c.company), try c.company_name.markup(al),
        @tagName(c.status), more,
    });
}

/// `H`: the next HQ's world, in HQ id order.
fn focusNextHq(self: *App) !void {
    const al = self.a();
    const view = try q.map(al, self.state());
    if (view.hqs.len == 0) return self.say(.dim, "the outfit has no HQ", .{});
    const all = try al.alloc(usize, view.hqs.len);
    for (view.hqs, all) |h, *w| w.* = h.world;
    const stops = try distinctWorlds(al, all);
    const at = nextStop(stops, self.map_cursor);
    const h = for (view.hqs) |h| {
        if (h.world == stops[at]) break h;
    } else unreachable; // every stop is some HQ's world
    focusWorld(self, stops[at], "HQ {d} of {d}: {s} on {s}", .{ at + 1, stops.len, try h.name.markup(al), view.worlds[stops[at]].name });
}

pub fn move(self: *App, delta: i32) anyerror!void {
    try self.mapPan(0, if (delta > 0) -1 else 1);
}

/// Horizontal-scroll hook called by `runGlobal` via the `scroll_h` registry
/// field: `dir > 0` pans east, `dir < 0` pans west.
pub fn scrollH(self: *App, dir: i32) anyerror!void {
    try self.mapPan(if (dir > 0) 1 else -1, 0);
}

const Action = enum { pan_left, pan_right, zoom_in, zoom_out, colours, contract_world, next_hq, found, offers };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('h'), .action = .pan_left, .label = "pan", .group = .navigate, .shown = "h l", .title = 0, .help = "pan the map west / east (j k and the arrows pan too)" },
    .{ .match = app.keys.Match.char('l'), .action = .pan_right, .label = "pan east", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('+'), .action = .zoom_in, .label = "zoom", .group = .navigate, .shown = "+ -", .title = 0, .help = "zoom in / out (names show at zoom ×2)" },
    .{ .match = app.keys.Match.char('='), .action = .zoom_in, .label = "zoom in", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('-'), .action = .zoom_out, .label = "zoom out", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('c'), .action = .colours, .label = "colours", .group = .navigate, .title = 0, .help = "colour the map by faction, industry, standing or activity" },
    .{ .match = app.keys.Match.char('w'), .action = .contract_world, .label = "contract world", .group = .navigate, .help = "move to the next world where a company is on contract" },
    .{ .match = app.keys.Match.char('H'), .action = .next_hq, .label = "HQ", .group = .navigate, .help = "move to the next HQ" },
    .{ .match = app.keys.Match.char('f'), .action = .found, .label = "found HQ here", .group = .act, .title = 0, .help = "found an HQ on the world under the cursor (fills the command line)" },
    .{ .match = app.keys.Match.char('o'), .action = .offers, .label = "offers here", .group = .act, .title = 0, .help = "open the contract board" },
    .{ .match = .{ .key = .enter }, .action = .offers, .label = "contract board", .group = .act, .show_footer = false, .show_help = false },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = self.state();
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
        .contract_world => try focusContractWorld(self),
        .next_hq => try focusNextHq(self),
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

test "w and H stay out of the Map pane title, which keeps its other keys" {
    const title = try app.keys.paneTitle(std.testing.allocator, &legend, 0);
    defer std.testing.allocator.free(title);
    try std.testing.expect(std.mem.indexOf(u8, title, "[w]") == null);
    try std.testing.expect(std.mem.indexOf(u8, title, "[H]") == null);
    try std.testing.expect(std.mem.indexOf(u8, title, "[c] colours") != null);
}

fn msgForTest(c: *app.ClientForTest) []const u8 {
    return c.app.msg.buf[0..c.app.msg.len];
}

fn worldForTest(view: q.Map, key: []const u8) usize {
    for (view.worlds, 0..) |w, i| if (std.mem.eql(u8, w.key, key)) return i;
    unreachable;
}

fn isLandForTest(st: Style) bool {
    return switch (st) {
        .blue_land, .red_land, .yellow_land, .green_land, .magenta_land => true,
        else => false,
    };
}

/// The cursor is on the first HQ's world, at the closest zoom showing its
/// reach: that zoom fits, and the next one up does not.
fn expectFramedForTest(c: *app.ClientForTest, view: q.Map) !void {
    const h = view.hqs[0];
    try std.testing.expect(c.app.map_framed);
    try std.testing.expectEqual(h.world, c.app.map_cursor);
    const inner = mapRect(&c.app).inner();
    const zoom = c.app.map_zoom;
    if (zoom > 1) try std.testing.expect(reachFits(view, inner, zoom, h));
    if (zoom < 8) try std.testing.expect(!reachFits(view, inner, zoom * 2, h));
}

test "the first Map draw frames the first HQ's reach at 200x50 and 80x24, a changed zoom stays, and a reopened campaign frames again" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const view = try q.map(arena.allocator(), c.app.state());
    try std.testing.expect(!c.app.map_framed);
    try toTab(c, .map);
    try expectFramedForTest(c, view);
    try std.testing.expect(c.app.map_zoom > 1);
    try app.pressForTest(c, .{ .char = '-' });
    const zoom = c.app.map_zoom;
    try toTab(c, .desk);
    try toTab(c, .map);
    try std.testing.expectEqual(zoom, c.app.map_zoom);
    try c.app.screen.resize(80, 24);
    try app.reopenCampaignForTest(c);
    try std.testing.expect(!c.app.map_framed);
    try toTab(c, .map);
    try expectFramedForTest(c, view);
}

test "with no HQ, framing leaves the cursor and zoom as they are" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var view = try q.map(arena.allocator(), c.app.state());
    view.hqs = &.{};
    c.app.map_cursor = 7;
    c.app.map_zoom = 2;
    frameDefault(&c.app, view, mapRect(&c.app).inner());
    try std.testing.expect(c.app.map_framed);
    try std.testing.expectEqual(@as(usize, 7), c.app.map_cursor);
    try std.testing.expectEqual(@as(u8, 2), c.app.map_zoom);
}

test "+ and - zoom the star map from the framed zoom down to x1 and up to x8, and o jumps to the contract board" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .map);
    while (c.app.map_zoom > 1) {
        const zoom = c.app.map_zoom;
        try app.pressForTest(c, .{ .char = '-' });
        try std.testing.expectEqual(zoom / 2, c.app.map_zoom);
    }
    try app.pressForTest(c, .{ .char = '-' });
    try std.testing.expectEqual(@as(u8, 1), c.app.map_zoom);
    for ([_]u8{ 2, 4, 8, 8 }) |zoom| {
        try app.pressForTest(c, .{ .char = '+' });
        try std.testing.expectEqual(zoom, c.app.map_zoom);
    }
    try app.pressForTest(c, .{ .char = 'o' });
    try std.testing.expectEqual(app.Tab.contracts, c.app.tab);
}

test "w visits the worlds of running contracts in id order and wraps, raising the zoom to x4, and says when none is running" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const view = try q.map(arena.allocator(), c.app.state());
    try toTab(c, .map);
    const terra = worldForTest(view, "terra");
    c.app.map_cursor = terra;
    c.app.map_zoom = 1;
    try app.pressForTest(c, .{ .char = 'w' });
    try std.testing.expectEqualStrings("no company is on contract", msgForTest(c));
    try std.testing.expectEqual(terra, c.app.map_cursor);
    try std.testing.expectEqual(@as(u8, 1), c.app.map_zoom);
    // Three running contracts on two worlds, and a finished one.
    try app.game.campaign_scripts.contractsForTest(c.app.state(), &.{
        .{ .id = 12, .planet_key = "galatea", .status = .active },
        .{ .id = 10, .planet_key = "galatea", .status = .transit },
        .{ .id = 11, .planet_key = "tharkad", .status = .active },
        .{ .id = 9, .planet_key = "tharkad", .status = .completed },
    });
    const galatea = worldForTest(view, "galatea");
    const tharkad = worldForTest(view, "tharkad");
    try app.pressForTest(c, .{ .char = 'w' });
    try std.testing.expectEqual(galatea, c.app.map_cursor);
    try std.testing.expectEqual(@as(u8, 4), c.app.map_zoom);
    try std.testing.expect(std.mem.startsWith(u8, msgForTest(c), "contract world 1 of 2: Galatea — [10] co:"));
    try std.testing.expect(std.mem.endsWith(u8, msgForTest(c), "(transit) · 2 contracts here"));
    try app.pressForTest(c, .{ .char = 'w' });
    try std.testing.expectEqual(tharkad, c.app.map_cursor);
    try std.testing.expect(std.mem.startsWith(u8, msgForTest(c), "contract world 2 of 2: Tharkad — [11] co:"));
    try std.testing.expect(std.mem.endsWith(u8, msgForTest(c), "(active)"));
    c.app.map_zoom = 8;
    try app.pressForTest(c, .{ .char = 'w' });
    try std.testing.expectEqual(galatea, c.app.map_cursor);
    try std.testing.expectEqual(@as(u8, 8), c.app.map_zoom);
}

test "H visits the HQ worlds in id order and wraps" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = try q.map(arena.allocator(), c.app.state());
    const first = before.hqs[0];
    const first_key = before.worlds[first.world].key;
    const other_key: []const u8 = if (std.mem.eql(u8, first_key, "galatea")) "tharkad" else "galatea";
    _ = try app.game.campaign_scripts.hqForTest(c.app.state(), other_key);
    const view = try q.map(arena.allocator(), c.app.state());
    try std.testing.expectEqual(@as(usize, 2), view.hqs.len);
    try toTab(c, .map);
    c.app.map_cursor = worldForTest(view, "terra");
    c.app.map_zoom = 1;
    try app.pressForTest(c, .{ .char = 'H' });
    try std.testing.expectEqual(first.world, c.app.map_cursor);
    try std.testing.expectEqual(@as(u8, 4), c.app.map_zoom);
    try std.testing.expect(std.mem.startsWith(u8, msgForTest(c), "HQ 1 of 2: "));
    try app.pressForTest(c, .{ .char = 'H' });
    try std.testing.expectEqual(worldForTest(view, other_key), c.app.map_cursor);
    const want = try std.fmt.allocPrint(arena.allocator(), "HQ 2 of 2: Local on {s}", .{view.worlds[worldForTest(view, other_key)].name});
    try std.testing.expectEqualStrings(want, msgForTest(c));
    try app.pressForTest(c, .{ .char = 'H' });
    try std.testing.expect(std.mem.startsWith(u8, msgForTest(c), "HQ 1 of 2: "));
}

test "territory marks every rim cell and the interior lattice, leaves space beyond reach blank, and meets another house at a rim" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const view = try q.map(al, c.app.state());
    var s = try Screen.init(std.testing.allocator, 200, 50);
    defer s.deinit();
    const inner: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 50 };
    const geom = App.mapGeom(view, inner, 1, null);
    try drawTerritory(&s, al, view, geom);
    var rim = false;
    var far = false;
    for (0..inner.h) |y| for (0..inner.w) |x| {
        const cell = s.get(@intCast(x), @intCast(y));
        if (isLandForTest(cell.style)) {
            try std.testing.expectEqual(@as(u21, '·'), cell.ch);
            if (x + 1 < inner.w) {
                const right = s.get(@intCast(x + 1), @intCast(y)).style;
                if (isLandForTest(right) and right != cell.style) rim = true;
            }
        }
        const p = geom.ly(.{ @intCast(x), @intCast(y) });
        const nearest = for (view.worlds) |w| {
            const dx: i64 = w.x - p[0];
            const dy: i64 = w.y - p[1];
            if (dx * dx + dy * dy <= territory_reach_ly * territory_reach_ly) break true;
        } else false;
        if (!nearest) {
            try std.testing.expectEqual(app.screen_mod.Cell{}, cell);
            far = true;
        }
    };
    try std.testing.expect(rim);
    try std.testing.expect(far);
    // Deep in Lyran space at x8: of any four cells along a row, one is on the lattice.
    s.clear();
    const tharkad = view.worlds[worldForTest(view, "tharkad")];
    const close = App.mapGeom(view, inner, 8, .{ tharkad.x, tharkad.y });
    try drawTerritory(&s, al, view, close);
    const at = close.cell(tharkad.x, tharkad.y);
    var washed: usize = 0;
    for (1..5) |k| if (s.get(@intCast(at[0] - @as(i32, @intCast(k))), @intCast(at[1])).style == .blue_land) {
        washed += 1;
    };
    try std.testing.expect(washed >= 1);
}

test "the faction lens draws territory under the worlds, the other lenses draw none, and a modal scrims it" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try c.app.loadTheme();
    try toTab(c, .map);
    const s = &c.app.screen;
    var land: ?struct { x: u16, y: u16 } = null;
    var cursor_seen = false;
    for (0..s.rows) |y| for (0..s.cols) |x| {
        const cell = s.get(@intCast(x), @intCast(y));
        if (isLandForTest(cell.style)) {
            try std.testing.expectEqual(@as(u21, '·'), cell.ch);
            if (land == null or x < land.?.x) land = .{ .x = @intCast(x), .y = @intCast(y) };
        }
        if (cell.style == .sel and (cell.ch == '*' or cell.ch == '@')) cursor_seen = true;
    };
    try std.testing.expect(cursor_seen);
    // The westernmost wash cell lies outside the centred Settings modal.
    const wash = land.?;
    try app.pressForTest(c, .{ .f = 12 });
    try std.testing.expect(c.app.modal == .settings);
    try std.testing.expectEqual(app.screen_mod.Cell{ .ch = '·', .style = .scrim }, s.get(wash.x, wash.y));
    try app.pressForTest(c, .escape);
    try app.pressForTest(c, .{ .char = 'c' });
    for (0..s.rows) |y| for (0..s.cols) |x| {
        try std.testing.expect(!isLandForTest(s.get(@intCast(x), @intCast(y)).style));
    };
}
