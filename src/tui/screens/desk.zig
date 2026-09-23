//! The Desk screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const layout = app.layout;
const q = app.q;
const tab_names = app.tab_names;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const view = try q.desk(al, g, q.desk_log_rows);

    const top_h: u16 = @max(8, layout.minor.of(b.h));
    const emblem_w: u16 = if (b.w >= layout.emblem_cols) 44 else 0;
    const rest_w: u16 = b.w - emblem_w;
    const cl_w: u16 = rest_w / 2;
    const ib_w: u16 = rest_w - cl_w;
    var x: u16 = b.x;
    if (emblem_w > 0) {
        const inner = self.screen.pane(.{ .x = x, .y = b.y, .w = emblem_w, .h = top_h }, .{ .title = q.clip((try q.status(al, g)).outfit_name, 36) });
        if (!self.drawEmblem(inner)) {
            var art: std.ArrayListUnmanaged([]const u8) = .empty;
            try art.append(al, "");
            const e = self.emblemFor(g);
            for (e.art) |line| try art.append(al, try std.fmt.allocPrint(al, "        {{p}}{s}{{/}}", .{line}));
            try art.append(al, "");
            try art.append(al, try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{e.name}));
            try art.append(al, "");
            try art.append(al, "  {d}import a picture in the wizard's{/}");
            try art.append(al, "  {d}emblem step to show a crest here{/}");
            self.screen.lines(inner, art.items, 0, null);
        }
        x += emblem_w;
    }
    var cl: std.ArrayListUnmanaged([]const u8) = .empty;
    for (view.checklist) |w| {
        try cl.append(al, try std.fmt.allocPrint(al, "{s} {s}   {{d}}→ {s}{{/}}", .{ if (w.blocking) "{c}!{/}" else "{a}·{/}", w.text, tab_names[w.jump] }));
    }
    if (view.checklist.len == 0) try cl.append(al, "{g}all clear{/} — nothing blocks the turn");
    // The Dragoons rating (12C.6) rides in the title so the cursor still maps onto the warnings.
    const rating_plain = try q.stripMarks(al, view.rating_line);
    const cl_title = try std.fmt.allocPrint(al, "END-TURN CHECKLIST · {s}", .{q.clip(rating_plain, if (cl_w > 30) cl_w - 26 else 0)});
    self.listPane(.{ .x = x, .y = b.y, .w = cl_w, .h = top_h }, cl_title, cl.items, 0, self.focus == 0, true);
    x += cl_w;
    var ib: std.ArrayListUnmanaged([]const u8) = .empty;
    var ib_index: std.ArrayListUnmanaged(usize) = .empty;
    for (view.inbox, 0..) |it, i| {
        const mk: []const u8 = if (it.days_left <= 1) "{c}" else "{a}";
        try ib.append(al, try std.fmt.allocPrint(al, "> {{a}}{s}{{/}} · {s} · {s}{d} days left{{/}}", .{ it.kind, it.company, mk, it.days_left }));
        try ib_index.append(al, i);
        for (it.options, 0..) |o, oi| {
            try ib.append(al, try std.fmt.allocPrint(al, "    {d}  {s}{s}", .{ oi + 1, o, if (oi == it.default_choice) "   {d}default{/}" else "" }));
            try ib_index.append(al, i);
        }
        try ib.append(al, "");
        try ib_index.append(al, i);
    }
    if (view.inbox.len == 0) try ib.append(al, "{d}nothing pending{/}");
    self.listPane(.{ .x = x, .y = b.y, .w = ib_w, .h = top_h }, "INBOX", ib.items, 1, self.focus == 1, true);

    const co_h: u16 = @min(b.h - top_h, @as(u16, @intCast(view.companies.len + 3)));
    const co_inner = self.screen.pane(.{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = co_h }, .{ .title = "COMPANIES" });
    // Shares the LOG pane's scroll slot: ←/→ while the log is focused scroll these columns.
    try self.tableOrNote(co_inner, .{ .cols = q.company_cols, .rows = view.companies }, 2, false, "{d}no companies{/}");
    if (self.focus == 2) self.focus_scroll = 2;

    const rest_h: u16 = b.h - top_h - co_h;
    if (rest_h >= 3) {
        const log_w: u16 = if (self.narrow()) b.w else layout.major.of(b.w);
        self.listPane(.{ .x = b.x, .y = b.y + top_h + co_h, .w = log_w, .h = rest_h }, "LOG", view.log, 2, self.focus == 2, true);
        if (log_w < b.w) self.listPane(.{ .x = b.x + log_w, .y = b.y + top_h + co_h, .w = b.w - log_w, .h = rest_h }, "HQs", view.hqs, 3, false, false);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.desk(al, g, q.desk_log_rows);
        switch (self.focus) {
            0 => self.moveCursor(0, delta, view.checklist.len),
            1 => self.moveCursor(1, delta, self.inboxRowCount(view)),
            else => self.moveCursor(2, delta, view.log.len),
        }

}

pub fn enter(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.desk(al, g, q.desk_log_rows);
        if (self.focus == 0 and view.checklist.len > 0) {
            const w = view.checklist[@min(self.cur(0).*, view.checklist.len - 1)];
            self.switchTab(@enumFromInt(w.jump));
        } else if (self.focus == 1) {
            if (self.inboxEventAtCursor(view)) |idx| self.modal = .{ .decision = idx };
        } else if (view.log.len > 0) {
            // The LOG pane clips; the modal wraps the whole entry.
            self.openModal(.{ .log_entry = @min(self.cur(2).*, view.log.len - 1) });
        }

}

pub fn key(self: *App, ch: u21) anyerror!void {
    switch (ch) {
        'e' => {
            self.logos = &.{};
            try self.loadLogoList();
            self.openModal(.emblem);
        },
        else => {},
    }
}
