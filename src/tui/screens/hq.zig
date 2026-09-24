//! The HQ screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! No MekHQ counterpart: the HQ network is this game's extension
//! (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Rect = app.Rect;
const layout = app.layout;
const q = app.q;
const types = app.types;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const hqs = try q.hqList(al, g);
    if (hqs.len == 0) return;
    App.clampIdx(&self.hq_sel, hqs.len);
    const h = hqs[self.hq_sel];
    const id = h.id;
    const detail = try q.hqDetail(al, g, id);
    const title = try std.fmt.allocPrint(al, "hq:{d} {s} · {s} · ring {d} LY · funds {s} · staff {d}/{d}", .{ @intFromEnum(id), try h.name.markup(al), h.tier, h.ring_ly, try q.money(al, h.funds), h.staff_assigned, h.staff_required });
    const lw: u16 = if (layout.extraWide(b.w)) layout.hq_detail.of(b.w) else b.w;
    const top_h: u16 = if (lw < b.w) b.h else layout.major.of(b.h);
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = lw, .h = top_h }, .{ .title = title, .focused = self.focus == 0, .right_title = try app.keys.paneTitle(al, &legend, 0) });
    self.screen.lines(inner, detail, App.firstRow(self.cur(0).*, inner.h), if (self.focus == 0) self.cur(0).* else null);

    const hallv = try q.hall(al, g, id, self.hall_filter);
    const hall_note: []const u8 = if (hallv.total_at_hq == 0) "{d}no candidates today — the hall churns daily{/}" else "{d}no candidates match this filter{/}";
    const hall_title = try std.fmt.allocPrint(al, "HIRING HALL · filter {{a}}{s}{{/}} · {d} of {d}", .{ @tagName(self.hall_filter), hallv.rows.len, hallv.total_at_hq });
    const hr: Rect = if (lw < b.w) .{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = b.h } else .{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = b.h - top_h };
    const hinner = self.screen.pane(hr, .{ .title = hall_title, .focused = self.focus == 1, .right_title = try app.keys.paneTitle(al, &legend, 1) });
    try self.tableOrNote(hinner, try q.tableOf(al, q.hall_cols, hallv.rows), 1, self.focus == 1, hall_note);
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const id: types.HqId = @enumFromInt(self.hqSelId(g));
    if (self.focus == 0) {
        const detail = try q.hqDetail(al, g, id);
        self.moveCursor(0, delta, detail.len);
    } else {
        const hallv = try q.hall(al, g, id, self.hall_filter);
        self.moveCursor(1, delta, hallv.rows.len);
    }
}

const Action = enum { prev_hq, next_hq, upgrade, tier, autostaff, open_hall, filter_next, filter_prev, hire, fabricate, sell };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('['), .action = .prev_hq, .label = "switch HQ", .group = .navigate, .shown = "[ ]", .title = 0, .help = "previous / next HQ" },
    .{ .match = app.keys.Match.char(']'), .action = .next_hq, .label = "next HQ", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('u'), .action = .upgrade, .label = "upgrade", .group = .act, .title = 0, .help = "upgrade the facility under the cursor (elsewhere: pick one)" },
    .{ .match = app.keys.Match.char('T'), .action = .tier, .label = "tier", .group = .act, .help = "raise a field HQ to regional" },
    .{ .match = app.keys.Match.char('S'), .action = .autostaff, .label = "autostaff", .group = .act, .title = 0, .help = "staff the back office to requirement" },
    .{ .match = app.keys.Match.char('h'), .action = .open_hall, .label = "hiring hall", .group = .navigate, .show_footer = false },
    .{ .match = app.keys.Match.char('f'), .action = .filter_next, .label = "next filter", .group = .navigate, .title = 1, .help = "hall filter forward (F: back)" },
    .{ .match = app.keys.Match.char('F'), .action = .filter_prev, .label = "previous", .group = .navigate, .title = 1, .show_help = false },
    .{ .match = .{ .key = .enter }, .action = .hire, .label = "hire", .group = .act, .pane = 1, .help = "hire the candidate under the cursor" },
    .{ .match = app.keys.Match.char('b'), .action = .fabricate, .label = "fabricate", .group = .act, .help = "fabricate a component at this HQ's bay" },
    .{ .match = app.keys.Match.char('$'), .action = .sell, .label = "sell HQ", .group = .money },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = &self.gs.?;
    const n = (try q.hqList(al, g)).len;
    switch (hit.action) {
        .next_hq => if (n > 0) {
            self.hq_sel = (self.hq_sel + 1) % n;
        },
        .prev_hq => if (n > 0) {
            self.hq_sel = (self.hq_sel + n - 1) % n;
        },
        .upgrade => {
            // The facility rows sit right under the header in the
            // HQ pane: with the cursor on one, upgrade it directly.
            const hid: types.HqId = @enumFromInt(self.hqSelId(g));
            const c = self.cur(0).*;
            const detail = try q.hqDetailView(al, g, hid);
            const under_cursor = if (self.focus == 0 and c < detail.facility.len) detail.facility[c] else null;
            if (under_cursor) |kind| {
                const rows = try q.upgrades(al, g, hid);
                for (rows) |r| if (r.kind == kind) {
                    if (!r.possible) {
                        self.say(.amber, "{s}: {s}", .{ @tagName(kind), r.reason });
                        return true;
                    }
                };
                _ = try self.execSay(.{ .upgrade_facility = .{ .hq = hid, .kind = kind } }, .good, "{s} upgrade started — paperwork first, then construction; watch PROJECTS", .{@tagName(kind)});
                return true;
            }
            self.openModal(.{ .upgrade = hid });
        },
        .autostaff => {
            _ = try self.execSay(.{ .autostaff = @enumFromInt(self.hqSelId(g)) }, .good, "back office staffed to requirement", .{});
        },
        .tier => {
            const hid: types.HqId = @enumFromInt(self.hqSelId(g));
            const name = try al.dupe(u8, try q.hqName(self.a(), g, hid));
            _ = try self.execSay(.{ .upgrade_tier = hid }, .good, "{s} → regional HQ: paperwork first, then construction — watch PROJECTS", .{name});
        },
        .open_hall => self.focus = 1,
        .filter_next => {
            self.hall_filter = self.hall_filter.next();
            self.focus = 1;
            self.cur(1).* = 0;
        },
        .filter_prev => {
            self.hall_filter = self.hall_filter.prev();
            self.focus = 1;
            self.cur(1).* = 0;
        },
        .hire => {
            const id: types.HqId = @enumFromInt(self.hqSelId(g));
            const hallv = try q.hall(al, g, id, self.hall_filter);
            if (hallv.rows.len == 0) return true;
            const row = hallv.rows[@min(self.cur(1).*, hallv.rows.len - 1)];
            _ = try self.execSay(.{ .hire_candidate = row.index }, .good, "hired candidate [{d}]", .{row.index});
        },
        .fabricate => {
            self.openModal(.{ .pick_part = .{ .purpose = .fabricate, .site = .{ .hq = @enumFromInt(self.hqSelId(g)) } } });
        },
        .sell => self.modal = .{ .confirm = .{ .kind = .sell_hq, .id = self.hqSelId(g) } },
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the HQ bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "u on a facility row acts on the facility the detail query puts under the cursor" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .hq);
    const g = &c.app.gs.?;
    const id: app.types.HqId = @enumFromInt(c.app.hqSelId(g));
    const detail = try q.hqDetailView(c.app.a(), g, id);
    const row = for (detail.facility, 0..) |f, i| {
        if (f != null) break i;
    } else return error.TestUnexpectedResult;
    const kind = detail.facility[row].?;
    c.app.cur(0).* = row;
    try app.pressForTest(c, .{ .char = 'u' });
    // Started or refused, the line names the facility the row showed.
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), @tagName(kind)) != null or std.mem.startsWith(u8, c.app.msg.slice(), "refused"));
    try std.testing.expect(c.app.modal == .none); // a facility row upgrades directly, no picker
}
