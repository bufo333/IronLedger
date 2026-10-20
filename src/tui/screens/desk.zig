//! The Desk screen (docs/engineering-contract.md rule 35): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the Command Center tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const layout = app.layout;
const q = app.q;
const tabName = app.tabName;

/// The campaign-global reports the Desk hub lists; each opens its existing
/// read-only modal (app.zig Modal). The list is frontend chrome, not a sim
/// rule: it decides nothing, and each report's body comes from its own query.
const Report = struct {
    name: []const u8,
    desc: []const u8,
    target: enum { summary, readiness, battles, leaderboard },
};

const reports = [_]Report{
    .{ .name = "Campaign summary", .desc = "the campaign in aggregate", .target = .summary },
    .{ .name = "Readiness", .desc = "every company: fatigue, morale, wounded, banked XP, depot", .target = .readiness },
    .{ .name = "Battles", .desc = "the engagements still on record", .target = .battles },
    .{ .name = "Merc companies", .desc = "all merc outfits: founding, funds, hulls", .target = .leaderboard },
};

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = self.state();
    const b = self.body();
    const view = try q.desk(al, g, q.desk_log_rows);
    const band = bands(b.h, view.companies.len);

    const top_h: u16 = band.top_h;
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
        try cl.append(al, try std.fmt.allocPrint(al, "{s} {s}   {{d}}→ {s}{{/}}", .{ if (w.urgent) "{c}!{/}" else "{a}·{/}", w.text, tabName(@enumFromInt(w.jump)) }));
    }
    if (view.checklist.len == 0) try cl.append(al, "{g}all clear{/} — nothing blocks the turn");
    // The Dragoons rating rides in the title so the cursor still maps onto the warnings.
    const rating_plain = try q.stripMarks(al, view.rating_line);
    const cl_title = try std.fmt.allocPrint(al, "END-TURN CHECKLIST · {s}", .{q.clip(rating_plain, if (cl_w > 30) cl_w - 26 else 0)});
    self.listPane(.{ .x = x, .y = b.y, .w = cl_w, .h = top_h }, cl_title, cl.items, 0, self.paneFocused(0), true);
    x += cl_w;
    const ib = try inboxPane(al, view);
    const ib_lines: []const []const u8 = if (ib.lines.len == 0) &.{"{d}nothing pending{/}"} else ib.lines;
    self.listPane(.{ .x = x, .y = b.y, .w = ib_w, .h = top_h }, "INBOX", ib_lines, 1, self.paneFocused(1), true);

    const co_h: u16 = band.co_h;
    const co_inner = self.screen.pane(.{ .x = b.x, .y = b.y + top_h, .w = b.w, .h = co_h }, .{ .title = "COMPANIES" });
    // Shares the LOG pane's scroll slot: ←/→ while the log is focused scroll these columns.
    try self.tableOrNote(co_inner, .{ .cols = q.company_cols, .rows = view.companies }, 2, false, "{d}no companies{/}");
    if (self.focus == 2) self.focus_scroll = 2;

    const rest_h: u16 = band.rest_h;
    if (band.panes() > log_pane) {
        const by: u16 = b.y + top_h + co_h;
        // The right column holds the reports hub and, when wide, the HQ summaries;
        // the log and the newswire take the rest. Reports is drawn whenever the
        // log is, at every width.
        const right_w: u16 = if (self.narrow()) layout.minor.of(b.w) else (b.w - layout.major.of(b.w));
        const log_w: u16 = b.w - right_w;
        // The log over the newswire, each with at least one row, when both fit.
        const min_h = layout.list_pane_min_rows;
        const log_h: u16 = if (band.panes() > newswire_pane) @max(min_h, @min(layout.major.of(rest_h), rest_h - min_h)) else rest_h;
        self.listPane(.{ .x = b.x, .y = by, .w = log_w, .h = log_h }, "LOG", view.log, log_pane, self.paneFocused(log_pane), true);
        if (band.panes() > newswire_pane) {
            self.listPane(.{ .x = b.x, .y = by + log_h, .w = log_w, .h = rest_h - log_h }, "NEWSWIRE", try newswireLines(al, view), newswire_pane, self.paneFocused(newswire_pane), true);
        }

        const rx: u16 = b.x + log_w;
        const rp_h: u16 = @min(rest_h, @as(u16, @intCast(reports.len + 3)));
        // HQs below the reports hub when there is room (wide only). Drawn without a
        // cursor slot (like the emblem fallback) so it does not clamp slot 3, which
        // the focusable reports pane now owns.
        if (!self.narrow() and rest_h > rp_h) {
            const hq_inner = self.screen.pane(.{ .x = rx, .y = by + rp_h, .w = right_w, .h = rest_h - rp_h }, .{ .title = "HQs" });
            self.screen.lines(hq_inner, view.hqs, 0, null);
        }

        var rl: std.ArrayListUnmanaged([]const u8) = .empty;
        for (reports) |r| try rl.append(al, try std.fmt.allocPrint(al, "{s}   {{d}}{s}{{/}}", .{ r.name, r.desc }));
        self.listPane(.{ .x = rx, .y = by, .w = right_w, .h = rp_h }, "REPORTS", rl.items, 3, self.paneFocused(3), true);
    }
}

/// Focus indices of the log and the newswire, the first and last panes
/// below the companies table.
const log_pane: u8 = 2;
const newswire_pane: u8 = 4;

/// The Desk's three bands, top to bottom (rule 38): the checklist and inbox,
/// the companies table, and the region the log, newswire and reports share.
const Bands = struct {
    top_h: u16,
    co_h: u16,
    rest_h: u16,

    /// How many panes are drawn, from focus index 0: the checklist and inbox
    /// always; the log and reports when the region holds one list pane; the
    /// newswire too when it holds two.
    fn panes(self: Bands) u8 {
        if (self.rest_h >= 2 * layout.list_pane_min_rows) return newswire_pane + 1;
        if (self.rest_h >= layout.list_pane_min_rows) return newswire_pane;
        return log_pane;
    }
};

/// The top band takes its share of the body but yields rows, down to
/// `layout.desk_top_min_rows`, so the log and the newswire below the
/// companies each keep `layout.list_pane_min_rows`.
fn bands(body_h: u16, companies: usize) Bands {
    const co_want: u16 = @intCast(@min(companies + 3, body_h));
    const room = body_h -| co_want -| 2 * layout.list_pane_min_rows;
    const top_h: u16 = @min(body_h, @max(layout.desk_top_min_rows, @min(layout.minor.of(body_h), room)));
    const co_h: u16 = @min(body_h - top_h, co_want);
    return .{ .top_h = top_h, .co_h = co_h, .rest_h = body_h - top_h - co_h };
}

/// The panes `draw` lays out at the current size (`App.paneCount`).
pub fn shownPanes(self: *App) anyerror!u8 {
    const view = try q.desk(self.a(), self.state(), q.desk_log_rows);
    return bands(self.body().h, view.companies.len).panes();
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

/// The NEWSWIRE pane's lines: one per row of `view.news`, in its order, so
/// the cursor's index is the row's; the empty state when there is none.
fn newswireLines(al: std.mem.Allocator, view: q.Desk) ![]const []const u8 {
    if (view.news.len == 0) return &.{"{d}no news within reach{/}"};
    const lines = try al.alloc([]const u8, view.news.len);
    for (view.news, lines) |row, *line| line.* = row.text;
    return lines;
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = self.state();
    const view = try q.desk(al, g, q.desk_log_rows);
    switch (self.focus) {
        0 => self.moveCursor(0, delta, view.checklist.len),
        1 => self.moveCursor(1, delta, (try inboxPane(al, view)).lines.len),
        3 => self.moveCursor(3, delta, reports.len),
        4 => self.moveCursor(4, delta, view.news.len),
        else => self.moveCursor(2, delta, view.log.len),
    }
}

const Action = enum { go_to, decide, read_entry, open_report, read_item, battles, emblem };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = .{ .key = .enter }, .action = .go_to, .label = "go to", .group = .act, .pane = 0, .help = "go where the warning points (a contact warning opens its battle orders, a due engagement its battle screen)" },
    .{ .match = .{ .key = .enter }, .action = .decide, .label = "decide", .group = .act, .pane = 1, .help = "open the decision under the cursor" },
    .{ .match = .{ .key = .enter }, .action = .read_entry, .label = "read entry", .group = .act, .pane = 2, .help = "read the whole log entry under the cursor" },
    .{ .match = .{ .key = .enter }, .action = .open_report, .label = "open report", .group = .act, .pane = 3, .help = "open the selected report (read-only; Esc closes)" },
    .{ .match = .{ .key = .enter }, .action = .read_item, .label = "read item", .group = .act, .pane = 4, .help = "read the whole news item under the cursor" },
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
            // A contact warning opens that engagement's battle orders, a due
            // engagement its battle screen.
            if (w.kind == .contact_imminent and w.contract != .none) {
                self.openOrders(w.contract);
            } else if (w.kind == .engagement_due and w.contract != .none) {
                self.openModal(.{ .battle = w.contract });
            } else self.switchTab(@enumFromInt(w.jump));
        },
        .decide => {
            const view = try q.desk(al, g, q.desk_log_rows);
            const ib = try inboxPane(al, view);
            const c = self.cur(1).*;
            if (c < ib.event.len) self.openModal(.{ .decision = ib.event[c] });
        },
        .read_entry => {
            const view = try q.desk(al, g, q.desk_log_rows);
            // The LOG pane clips; the modal wraps the whole entry.
            if (view.log.len > 0) self.openModal(.{ .log_entry = @min(self.cur(2).*, view.log.len - 1) });
        },
        .open_report => {
            const r = reports[@min(self.cur(3).*, reports.len - 1)];
            switch (r.target) {
                .summary => self.modal = .summary,
                .readiness => self.modal = .readiness,
                .battles => {
                    self.battles_from_list = true;
                    self.openModal(.battle_list);
                },
                .leaderboard => self.openModal(.leaderboard),
            }
        },
        .read_item => {
            const view = try q.desk(al, g, q.desk_log_rows);
            // The NEWSWIRE pane clips; the modal wraps the whole item.
            if (view.news.len > 0) self.openModal(.{ .news_item = view.news[@min(self.cur(4).*, view.news.len - 1)].id });
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
    const view: q.Desk = .{ .rating_line = "", .checklist = &.{}, .inbox = &rows, .companies = &.{}, .hqs = &.{}, .log = &.{}, .news = &.{} };
    const pane = try inboxPane(al, view);
    try std.testing.expectEqual(pane.lines.len, pane.event.len);
    // Header, two options and a gap for the first; header, one option and a gap for the second.
    try std.testing.expectEqual(@as(usize, 7), pane.lines.len);
    for (pane.event[0..4]) |e| try std.testing.expectEqual(@as(app.types.EventId, @enumFromInt(7)), e);
    for (pane.event[4..]) |e| try std.testing.expectEqual(@as(app.types.EventId, @enumFromInt(4)), e);
    const empty: q.Desk = .{ .rating_line = "", .checklist = &.{}, .inbox = &.{}, .companies = &.{}, .hqs = &.{}, .log = &.{}, .news = &.{} };
    try std.testing.expectEqual(@as(usize, 0), (try inboxPane(al, empty)).event.len);
}

test "the newswire shows one line per news row in order, and its empty state when there is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const empty: q.Desk = .{ .rating_line = "", .checklist = &.{}, .inbox = &.{}, .companies = &.{}, .hqs = &.{}, .log = &.{}, .news = &.{} };
    const none = try newswireLines(al, empty);
    try std.testing.expectEqual(@as(usize, 1), none.len);
    try std.testing.expectEqualStrings("{d}no news within reach{/}", none[0]);
    var rows = [_]q.NewsRow{
        .{ .id = @enumFromInt(9), .conflict = @enumFromInt(2), .text = "newer" },
        .{ .id = @enumFromInt(4), .conflict = @enumFromInt(1), .text = "older" },
    };
    var view = empty;
    view.news = &rows;
    const lines = try newswireLines(al, view);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("newer", lines[0]);
    try std.testing.expectEqualStrings("older", lines[1]);
}

test "the desk's five panes cycle and clamp wide and narrow, and Enter on the newswire opens the item under the cursor" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    _ = try app.game.news.heardForTest(c.app.state(), "skye");
    _ = try app.game.news.heardForTest(c.app.state(), "tharkad");
    try toTab(c, .desk);
    // The rows live in the frame arena, which every key press resets.
    const news = (try q.desk(c.app.a(), c.app.state(), q.desk_log_rows)).news;
    try std.testing.expect(news.len >= 2);
    const second = news[1].id;
    const count = news.len;
    for ([_]u16{ 200, 100 }) |w| {
        try c.app.screen.resize(w, 50);
        try app.pressForTest(c, .escape);
        c.app.focus = 0;
        // Tab reaches the newswire last and wraps to the checklist.
        for (0..4) |_| try app.pressForTest(c, .tab);
        try std.testing.expectEqual(@as(u8, 4), c.app.focus);
        try app.pressForTest(c, .tab);
        try std.testing.expectEqual(@as(u8, 0), c.app.focus);
        try app.pressForTest(c, .backtab);
        try std.testing.expectEqual(@as(u8, 4), c.app.focus);
        // The cursor clamps to the rows the newswire holds.
        for (0..count + 3) |_| try app.pressForTest(c, .{ .char = 'j' });
        try std.testing.expectEqual(count - 1, c.app.cur(4).*);
        c.app.cur(4).* = 1;
        try app.pressForTest(c, .enter);
        try std.testing.expect(c.app.modal == .news_item);
        try std.testing.expectEqual(second, c.app.modal.news_item);
        try app.pressForTest(c, .escape);
        try std.testing.expect(c.app.modal == .none);
    }
}

/// Row `y` of the client's screen as text, trailing blanks dropped.
fn screenRowForTest(al: std.mem.Allocator, c: *app.ClientForTest, y: u16) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (0..c.app.screen.cols) |x| {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(c.app.screen.get(@intCast(x), y).ch, &buf);
        try out.appendSlice(al, buf[0..n]);
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

test "at 80x24 five companies leave the newswire rows to read and select; more companies drop panes focus cannot reach" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    _ = try app.game.news.heardForTest(c.app.state(), "skye");
    _ = try app.game.news.heardForTest(c.app.state(), "tharkad");
    try app.game.campaign_scripts.companiesForTest(c.app.state(), 5);
    try c.app.screen.resize(80, 24);
    try toTab(c, .desk);
    try std.testing.expectEqual(@as(usize, 5), (try q.desk(c.app.a(), c.app.state(), q.desk_log_rows)).companies.len);
    // Every pane is drawn, and Tab reaches the newswire.
    try std.testing.expectEqual(@as(u16, 0b11111), c.app.panes_drawn);
    c.app.focus = 0;
    for (0..4) |_| try app.pressForTest(c, .tab);
    try std.testing.expectEqual(@as(u8, 4), c.app.focus);
    try app.pressForTest(c, .{ .char = 'j' });
    try std.testing.expectEqual(@as(usize, 1), c.app.cur(4).*);
    // On screen, the selected row under the NEWSWIRE title is the second
    // news row's text.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const news = try q.newsRows(al, c.app.state(), q.newswire_rows);
    const want = try q.stripMarks(al, news[1].text);
    const title_y: u16 = for (0..c.app.screen.rows) |y| {
        if (std.mem.indexOf(u8, try screenRowForTest(al, c, @intCast(y)), "NEWSWIRE") != null) break @intCast(y);
    } else return error.TestUnexpectedResult;
    var selected: ?[]const u8 = null;
    var y: u16 = title_y + 1;
    while (y < c.app.screen.rows) : (y += 1) {
        const row = try screenRowForTest(al, c, y);
        if (std.mem.startsWith(u8, row, "└")) break;
        // The text between the newswire's side borders; the cursor row is
        // painted selected.
        var cells = std.mem.splitSequence(u8, row, "│");
        _ = cells.next();
        const text = std.mem.trim(u8, cells.next() orelse "", " ");
        for (2..c.app.screen.cols) |x| {
            if (c.app.screen.get(@intCast(x), y).style == .sel) selected = text;
        }
        if (selected != null) break;
    }
    try std.testing.expect(selected != null and selected.?.len >= 10);
    try std.testing.expect(std.mem.startsWith(u8, want, selected.?));
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .news_item);
    try std.testing.expectEqual(news[1].id, c.app.modal.news_item);
    try app.pressForTest(c, .escape);
    // A sixth company leaves no room for the newswire: it is not drawn, a
    // focus on it moves to the reports, and Tab cycles the four drawn panes.
    try app.game.campaign_scripts.companiesForTest(c.app.state(), 6);
    try app.pressForTest(c, .none);
    try std.testing.expectEqual(@as(u16, 0b1111), c.app.panes_drawn);
    try std.testing.expectEqual(@as(u8, 3), c.app.focus);
    try app.pressForTest(c, .tab);
    try std.testing.expectEqual(@as(u8, 0), c.app.focus);
    // Enough companies to fill the body leave only the checklist and inbox.
    try app.game.campaign_scripts.companiesForTest(c.app.state(), 12);
    c.app.focus = 3;
    try app.pressForTest(c, .none);
    try std.testing.expectEqual(@as(u16, 0b11), c.app.panes_drawn);
    try std.testing.expectEqual(@as(u8, 1), c.app.focus);
    try app.pressForTest(c, .tab);
    try std.testing.expectEqual(@as(u8, 0), c.app.focus);
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "a situation's inbox lines open its decision, which draws narrow and is answered by its key" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    const id = try app.game.situations.raisedSituationForTest(c.app.state());
    try toTab(c, .desk);
    const pane = try inboxPane(c.app.a(), try q.desk(c.app.a(), c.app.state(), q.desk_log_rows));
    // The row's header and each of its three options belong to it.
    var lines: usize = 0;
    var first: usize = 0;
    for (pane.event, 0..) |e, i| if (e == id) {
        if (lines == 0) first = i;
        lines += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), lines);
    // The modal opens at its top, and draws, at 80x24, even after another
    // modal was scrolled and closed there.
    try c.app.screen.resize(80, 24);
    try app.pressForTest(c, .{ .char = '?' });
    for (0..3) |_| try app.pressForTest(c, .{ .char = 'j' });
    try app.pressForTest(c, .escape);
    try std.testing.expect(c.app.modal_cursor > 0);
    c.app.focus = 1;
    c.app.cur(1).* = first + 3; // an option line, not the header
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .decision);
    try std.testing.expectEqual(id, c.app.modal.decision);
    try std.testing.expectEqual(@as(usize, 0), c.app.modal_cursor);
    try app.pressForTest(c, .{ .char = '1' });
    try c.app.screen.resize(200, 50);
    for ((try q.desk(c.app.a(), c.app.state(), q.desk_log_rows)).inbox) |row| try std.testing.expect(row.event_id != id);
}

test "the desk bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "the reports pane opens the selected report under the cursor" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .desk);
    // focus 3 is the reports pane; each row opens its own read-only modal.
    c.app.focus = 3;
    c.app.cur(3).* = 0;
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .summary);

    c.app.modal = .none;
    c.app.focus = 3;
    c.app.cur(3).* = 1;
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .readiness);

    c.app.modal = .none;
    c.app.focus = 3;
    c.app.cur(3).* = 2;
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .battle_list);

    c.app.modal = .none;
    c.app.focus = 3;
    c.app.cur(3).* = 3;
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .leaderboard);
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
        } else if (w.kind == .engagement_due) {
            try std.testing.expect(c.app.modal == .battle);
        } else try std.testing.expectEqual(@as(app.Tab, @enumFromInt(w.jump)), c.app.tab);
        try app.pressForTest(c, .escape);
        try toTab(c, .desk);
    }
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(c.app.modal == .emblem);
}
