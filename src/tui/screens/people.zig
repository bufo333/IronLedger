//! The People screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the Personnel tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const layout = app.layout;
const q = app.q;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const view = try q.people(al, g, self.people_filter);
    const lw: u16 = if (layout.extraWide(b.w)) @max(layout.people_list.of(b.w), @min(b.w - 60, 128)) else b.w;
    const title = try std.fmt.allocPrint(al, "PERSONNEL · filter {{a}}{s}{{/}} · {d} of {d}", .{ @tagName(self.people_filter), view.rows.len, view.total });
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, .{ .title = title, .focused = true, .right_title = try app.keys.paneTitle(al, &legend, 0) });
    const c = self.cur(0);
    try self.tableOrNote(inner, try q.tableOf(al, q.people_cols, view.rows), 0, view.rows.len > 0, "{d}nobody matches this filter{/}");
    if (lw < b.w and view.rows.len > 0) {
        const id = view.rows[c.*].id;
        const rec = try q.personRecord(al, g, id);
        const rec_h: u16 = layout.major.of(b.h);
        self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = rec_h }, "RECORD", rec, 1, false, false);
        const seats = try q.openSeats(al, g, id);
        var st: std.ArrayListUnmanaged([]const u8) = .empty;
        for (seats) |s| try st.append(al, s.text);
        if (seats.len == 0) try st.append(al, "{d}no open seat for this role right now{/}");
        self.listPane(.{ .x = b.x + lw, .y = b.y + rec_h, .w = b.w - lw, .h = b.h - rec_h }, "OPEN SEATS", st.items, 2, false, false);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const view = try q.people(al, g, self.people_filter);
    self.moveCursor(0, delta, view.rows.len);
}

const Action = enum { filter_next, filter_prev, seat, transfer, post, train, leave, triage, admit, record, fire };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('/'), .action = .filter_next, .label = "filter", .group = .navigate, .shown = "/ ,", .title = 0, .help = "next / previous roster filter" },
    .{ .match = app.keys.Match.char(','), .action = .filter_prev, .label = "previous filter", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('a'), .action = .seat, .label = "seat", .group = .act, .help = "assign the person under the cursor to an open seat" },
    .{ .match = .{ .key = .enter }, .action = .seat, .label = "seat", .group = .act, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('x'), .action = .transfer, .label = "transfer", .group = .act, .help = "transfer to another company" },
    .{ .match = app.keys.Match.char('P'), .action = .post, .label = "post", .group = .act, .help = "post to an HQ" },
    .{ .match = app.keys.Match.char('t'), .action = .train, .label = "train", .group = .act, .help = "train the person's primary skill" },
    .{ .match = app.keys.Match.char('L'), .action = .leave, .label = "leave", .group = .act, .help = "send on leave for some days" },
    .{ .match = app.keys.Match.char('T'), .action = .triage, .label = "triage", .group = .act, .help = "set medical triage priority (higher heals first)" },
    .{ .match = app.keys.Match.char('m'), .action = .admit, .label = "admit", .group = .act, .help = "admit to the medbay" },
    .{ .match = app.keys.Match.char('r'), .action = .record, .label = "record", .group = .act, .help = "open the full service record" },
    .{ .match = app.keys.Match.char('D'), .action = .fire, .label = "fire", .group = .money, .help = "dismiss the person (asks first)" },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = &self.gs.?;
    switch (hit.action) {
        .filter_next, .filter_prev => {
            self.people_filter = if (hit.action == .filter_next) self.people_filter.next() else self.people_filter.prev();
            self.cur(0).* = 0;
            return true;
        },
        else => {},
    }
    const id = (try self.selectedPerson()) orelse return true;
    var buf: [96]u8 = undefined;
    switch (hit.action) {
        .filter_next, .filter_prev => unreachable,
        .train => {
            const row = (try self.selectedPersonRow()) orelse return true;
            self.openCommand(std.fmt.bufPrint(&buf, "train {d} {s}", .{ @intFromEnum(id), @tagName(row.primary_skill) }) catch "train ");
        },
        .seat => {
            self.openModal(.{ .seat = id });
        },
        .post => {
            self.openModal(.{ .pick_hq = id });
        },
        .transfer => {
            self.openModal(.{ .pick_company = .{ .what = .person, .id = @intFromEnum(id) } });
        },
        .leave => self.openAmount(try std.fmt.allocPrint(al, "LEAVE · {s}", .{try q.personName(al, g, id)}), .{ .leave = id }, &.{
            .{ .label = "days", .value = 7, .min = 1, .max = 90, .step = 1 },
        }),
        .triage => self.openAmount(try std.fmt.allocPrint(al, "TRIAGE · {s} (higher heals first)", .{try q.personName(al, g, id)}), .{ .triage = id }, &.{
            .{ .label = "priority", .value = 1, .min = 0, .max = 9, .step = 1 },
        }),
        .fire => self.modal = .{ .confirm = .{ .kind = .fire, .id = @intFromEnum(id) } },
        .record => self.modal = .{ .record = id },
        .admit => {
            _ = try self.execSay(.{ .admit = id }, .good, "{s} admitted to the medbay — healing starts tomorrow", .{try q.personName(al, g, id)});
        },
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the people bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "x on a person opens the company picker for that person" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .people);
    try app.pressForTest(c, .{ .char = 'x' });
    try std.testing.expect(c.app.modal == .pick_company);
}
