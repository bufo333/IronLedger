//! The People screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

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
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, .{ .title = title, .focused = true, .right_title = "[/] next filter  [?] previous" });
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
        try st.append(al, "");
        try st.append(al, "{d}[a] assign to a seat  [t] train  [P] post to HQ  [x] transfer  [L] leave  [D] fire{/}");
        self.listPane(.{ .x = b.x + lw, .y = b.y + rec_h, .w = b.w - lw, .h = b.h - rec_h }, "OPEN SEATS", st.items, 2, false, false);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.people(al, g, self.people_filter);
        self.moveCursor(0, delta, view.rows.len);

}

pub fn enter(self: *App) anyerror!void {
        const id = (try self.selectedPerson()) orelse return;
        self.openModal(.{ .seat = id });

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        if (ch == '/' or ch == ',') {
            self.people_filter = if (ch == '/') self.people_filter.next() else self.people_filter.prev();
            self.cur(0).* = 0;
            return;
        }
        const id = (try self.selectedPerson()) orelse return;
        var buf: [96]u8 = undefined;
        switch (ch) {
            't' => {
                const row = (try self.selectedPersonRow()) orelse return;
                self.openCommand(std.fmt.bufPrint(&buf, "train {d} {s}", .{ @intFromEnum(id), @tagName(row.primary_skill) }) catch "train ");
            },
            'a' => {
                self.openModal(.{ .seat = id });
            },
            'P' => {
                self.openModal(.{ .pick_hq = id });
            },
            'x' => {
                self.openModal(.{ .pick_company = .{ .what = .person, .id = @intFromEnum(id) } });
            },
            'L' => self.openAmount(try std.fmt.allocPrint(al, "LEAVE · {s}", .{try q.personName(al, g, id)}), .{ .leave = id }, &.{
                .{ .label = "days", .value = 7, .min = 1, .max = 90, .step = 1 },
            }),
            'T' => self.openAmount(try std.fmt.allocPrint(al, "TRIAGE · {s} (higher heals first)", .{try q.personName(al, g, id)}), .{ .triage = id }, &.{
                .{ .label = "priority", .value = 1, .min = 0, .max = 9, .step = 1 },
            }),
            'D' => self.modal = .{ .confirm = .{ .kind = .fire, .id = @intFromEnum(id) } },
            'r' => self.modal = .{ .record = id },
            'm' => {
                _ = try self.execSay(.{ .admit = id }, .good, "{s} admitted to the medbay — healing starts tomorrow", .{try q.personName(al, g, id)});
            },
            else => {},
        }

}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "x on a person opens the company picker for that person" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .people);
    try app.pressForTest(c, .{ .char = 'x' });
    try std.testing.expect(c.app.modal == .pick_company);
}
