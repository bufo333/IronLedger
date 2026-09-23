//! The HQ screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

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
    const title = try std.fmt.allocPrint(al, "hq:{d} {s} · {s} · ring {d} LY · funds {s} · staff {d}/{d}", .{ @intFromEnum(id), h.name, h.tier, h.ring_ly, try q.money(al, h.funds), h.staff_assigned, h.staff_required });
    const lw: u16 = if (layout.extraWide(b.w)) layout.hq_detail.of(b.w) else b.w;
    const top_h: u16 = if (lw < b.w) b.h else layout.major.of(b.h);
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = lw, .h = top_h }, .{ .title = title, .focused = self.focus == 0, .right_title = "[ ] switch HQ  [u] upgrade  [S] autostaff" });
    self.screen.lines(inner, detail, App.firstRow(self.cur(0).*, inner.h), if (self.focus == 0) self.cur(0).* else null);

    const hallv = try q.hall(al, g, id, self.hall_filter);
    const hall_note: []const u8 = if (hallv.total_at_hq == 0) "{d}no candidates today — the hall churns daily{/}" else "{d}no candidates match this filter{/}";
    const hall_title = try std.fmt.allocPrint(al, "HIRING HALL · filter {{a}}{s}{{/}} · {d} of {d}", .{ @tagName(self.hall_filter), hallv.rows.len, hallv.total_at_hq });
    const hr: Rect = if (lw < b.w) .{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = b.h } else .{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = b.h - top_h };
    const hinner = self.screen.pane(hr, .{ .title = hall_title, .focused = self.focus == 1, .right_title = "[f] next filter  [F] previous  [Enter] hire" });
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

pub fn enter(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        if (self.focus != 1) return;
        const id: types.HqId = @enumFromInt(self.hqSelId(g));
        const hallv = try q.hall(al, g, id, self.hall_filter);
        if (hallv.rows.len == 0) return;
        const row = hallv.rows[@min(self.cur(1).*, hallv.rows.len - 1)];
        _ = try self.execSay(.{ .hire_candidate = row.index }, .good, "hired candidate [{d}]", .{row.index});

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const n = (try q.hqList(al, g)).len;
        switch (ch) {
            ']' => if (n > 0) {
                self.hq_sel = (self.hq_sel + 1) % n;
            },
            '[' => if (n > 0) {
                self.hq_sel = (self.hq_sel + n - 1) % n;
            },
            'u' => {
                // The facility rows sit right under the header in the
                // HQ pane: with the cursor on one, upgrade it directly.
                const hid: types.HqId = @enumFromInt(self.hqSelId(g));
                const c = self.cur(0).*;
                const under_cursor = if (self.focus == 0) try q.hqFacilityAtRow(al, g, hid, c) else null;
                if (under_cursor) |kind| {
                    const rows = try q.upgrades(al, g, hid);
                    for (rows) |r| if (r.kind == kind) {
                        if (!r.possible) {
                            self.say(.amber, "{s}: {s}", .{ @tagName(kind), r.reason });
                            return;
                        }
                    };
                    _ = try self.execSay(.{ .upgrade_facility = .{ .hq = hid, .kind = kind } }, .good, "{s} upgrade started — paperwork first, then construction; watch PROJECTS", .{@tagName(kind)});
                    return;
                }
                self.openModal(.{ .upgrade = hid });
            },
            'S' => {
                _ = try self.execSay(.{ .autostaff = @enumFromInt(self.hqSelId(g)) }, .good, "back office staffed to requirement", .{});
            },
            'T' => {
                // Field HQ → regional (the footer and the tier line promised this key).
                const hid: types.HqId = @enumFromInt(self.hqSelId(g));
                const name = try al.dupe(u8, q.hqName(g, hid));
                _ = try self.execSay(.{ .upgrade_tier = hid }, .good, "{s} → regional HQ: paperwork first, then construction — watch PROJECTS; S autostaff when it lands", .{name});
            },
            'h' => {
                self.focus = 1;
                self.say(.dim, "hiring hall: j/k pick, Enter hires, f/F changes the filter", .{});
            },
            'f' => {
                self.hall_filter = self.hall_filter.next();
                self.focus = 1;
                self.cur(1).* = 0;
            },
            'F' => {
                self.hall_filter = self.hall_filter.prev();
                self.focus = 1;
                self.cur(1).* = 0;
            },
            'b' => {
                self.openModal(.{ .pick_part = .{ .purpose = .fabricate, .site = .{ .hq = @enumFromInt(self.hqSelId(g)) } } });
            },
            '$' => self.modal = .{ .confirm = .{ .kind = .sell_hq, .id = self.hqSelId(g) } },
            else => {},
        }

}
