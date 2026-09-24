//! The Desk screen (docs/coding-contract.md rule 35): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the Command Center tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const layout = app.layout;
const q = app.q;
const tab_names = app.tab_names;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = self.state();
    const b = self.body();
    const view = try q.desk(al, g, q.desk_log_rows);

    const top_h: u16 = @max(8, layout.minor.of(b.h));
    const emblem_w: u16 = if (b.w >= layout.emblem_cols) 44 else 0;
    const rest_w: u16 = b.w - emblem_w;
    const cl_w: u16 = rest_w / 2;
    const ib_w: u16 = rest_w - cl_w;
    var x: u16 = b.x;
    if (emblem_w > 0) {
        const inner = self.screen.pane(.{ .x = x, .y = b.y, .w = emblem_w, .h = top_h }, .{ .title = q.clip(try (try q.status(al, g)).outfit_name.markup(al), 36) });
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
        try cl.append(al, try std.fmt.allocPrint(al, "{s} {s}   {{d}}→ {s}{{/}}", .{ if (w.urgent) "{c}!{/}" else "{a}·{/}", w.text, tab_names[w.jump] }));
    }
    if (view.checklist.len == 0) try cl.append(al, "{g}all clear{/} — nothing blocks the turn");
    // The Dragoons rating rides in the title so the cursor still maps onto the warnings.
    const rating_plain = try q.stripMarks(al, view.rating_line);
    const cl_title = try std.fmt.allocPrint(al, "END-TURN CHECKLIST · {s}", .{q.clip(rating_plain, if (cl_w > 30) cl_w - 26 else 0)});
    self.listPane(.{ .x = x, .y = b.y, .w = cl_w, .h = top_h }, cl_title, cl.items, 0, self.focus == 0, true);
    x += cl_w;
    const ib = try inboxPane(al, view);
    const ib_lines: []const []const u8 = if (ib.lines.len == 0) &.{"{d}nothing pending{/}"} else ib.lines;
    self.listPane(.{ .x = x, .y = b.y, .w = ib_w, .h = top_h }, "INBOX", ib_lines, 1, self.focus == 1, true);

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

/// The INBOX pane's lines, and beside each the decision it belongs to: one
/// layout for drawing, the cursor's range and Enter.
const InboxPane = struct { lines: []const []const u8, event: []const app.types.EventId };

fn inboxPane(al: std.mem.Allocator, view: q.Desk) !InboxPane {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var event: std.ArrayListUnmanaged(app.types.EventId) = .empty;
    for (view.inbox) |it| {
        const mk: []const u8 = if (it.days_left <= 1) "{c}" else "{a}";
        try lines.append(al, try std.fmt.allocPrint(al, "> {{a}}{s}{{/}} · {s} · {s}{d} days left{{/}}", .{ it.kind, it.company, mk, it.days_left }));
        for (it.options, 0..) |o, oi| {
            try lines.append(al, try std.fmt.allocPrint(al, "    {d}  {s}{s}", .{ oi + 1, o, if (oi == it.default_choice) "   {d}default{/}" else "" }));
        }
        try lines.append(al, "");
        while (event.items.len < lines.items.len) try event.append(al, it.event_id);
    }
    return .{ .lines = lines.items, .event = event.items };
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = self.state();
    const view = try q.desk(al, g, q.desk_log_rows);
    switch (self.focus) {
        0 => self.moveCursor(0, delta, view.checklist.len),
        1 => self.moveCursor(1, delta, (try inboxPane(al, view)).lines.len),
        else => self.moveCursor(2, delta, view.log.len),
    }
}

const Action = enum { go_to, decide, read_entry, battles, emblem };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = .{ .key = .enter }, .action = .go_to, .label = "go to", .group = .act, .pane = 0, .help = "go where the warning points (a contact warning opens its battle orders)" },
    .{ .match = .{ .key = .enter }, .action = .decide, .label = "decide", .group = .act, .pane = 1, .help = "open the decision under the cursor" },
    .{ .match = .{ .key = .enter }, .action = .read_entry, .label = "read entry", .group = .act, .pane = 2, .help = "read the whole log entry under the cursor" },
    .{ .match = app.keys.Match.char('b'), .action = .battles, .label = "battles", .group = .act, .help = "the engagements still on record: pick one to read" },
    .{ .match = app.keys.Match.char('e'), .action = .emblem, .label = "emblem", .group = .act, .help = "choose the outfit's emblem" },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = self.state();
    switch (hit.action) {
        .go_to => {
            const view = try q.desk(al, g, q.desk_log_rows);
            if (view.checklist.len == 0) return true;
            const w = view.checklist[@min(self.cur(0).*, view.checklist.len - 1)];
            // A contact warning opens that engagement's battle orders.
            if (w.kind == .contact_imminent and w.contract != .none) {
                self.openOrders(w.contract);
            } else self.switchTab(@enumFromInt(w.jump));
        },
        .decide => {
            const view = try q.desk(al, g, q.desk_log_rows);
            const ib = try inboxPane(al, view);
            const c = self.cur(1).*;
            if (c < ib.event.len) self.modal = .{ .decision = ib.event[c] };
        },
        .read_entry => {
            const view = try q.desk(al, g, q.desk_log_rows);
            // The LOG pane clips; the modal wraps the whole entry.
            if (view.log.len > 0) self.openModal(.{ .log_entry = @min(self.cur(2).*, view.log.len - 1) });
        },
        .battles => {
            self.battles_from_list = true;
            self.openModal(.battle_list);
        },
        .emblem => {
            self.logos = &.{};
            try self.loadLogoList();
            self.openModal(.emblem);
        },
    }
    return true;
}

test "every inbox line belongs to the decision it was drawn for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var rows = [_]q.InboxRow{
        .{ .event_id = @enumFromInt(7), .kind = "a", .company = "Alpha", .deadline_day = 9, .days_left = 3, .description = "", .options = &.{ "x", "y" }, .default_choice = 0 },
        .{ .event_id = @enumFromInt(4), .kind = "b", .company = "Bravo", .deadline_day = 9, .days_left = 1, .description = "", .options = &.{"z"}, .default_choice = 0 },
    };
    const view: q.Desk = .{ .rating_line = "", .checklist = &.{}, .inbox = &rows, .companies = &.{}, .hqs = &.{}, .log = &.{} };
    const pane = try inboxPane(al, view);
    try std.testing.expectEqual(pane.lines.len, pane.event.len);
    // Header, two options and a gap for the first; header, one option and a gap for the second.
    try std.testing.expectEqual(@as(usize, 7), pane.lines.len);
    for (pane.event[0..4]) |e| try std.testing.expectEqual(@as(app.types.EventId, @enumFromInt(7)), e);
    for (pane.event[4..]) |e| try std.testing.expectEqual(@as(app.types.EventId, @enumFromInt(4)), e);
    const empty: q.Desk = .{ .rating_line = "", .checklist = &.{}, .inbox = &.{}, .companies = &.{}, .hqs = &.{}, .log = &.{} };
    try std.testing.expectEqual(@as(usize, 0), (try inboxPane(al, empty)).event.len);
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the desk bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "Enter on a checklist warning goes where the warning says; e opens the emblem picker" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .desk);
    const view = try q.desk(c.app.a(), c.app.state(), q.desk_log_rows);
    if (view.checklist.len > 0) {
        const w = view.checklist[0];
        try app.pressForTest(c, .enter);
        if (w.kind == .contact_imminent) {
            try std.testing.expect(c.app.modal == .battle_orders);
        } else try std.testing.expectEqual(@as(app.Tab, @enumFromInt(w.jump)), c.app.tab);
        try app.pressForTest(c, .escape);
        try toTab(c, .desk);
    }
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(c.app.modal == .emblem);
}
