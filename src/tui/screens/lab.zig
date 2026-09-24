//! The Lab screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the MekLab tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const game = app.game;
const layout = app.layout;
const q = app.q;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = self.state();
    const b = self.body();
    const meks = try q.labMeks(al, g);
    if (meks.len == 0) {
        const rows = [_][]const u8{"{d}no meks to work on{/}"};
        self.listPane(b, "LAB", &rows, 0, false, false);
        return;
    }
    App.clampIdx(&self.lab_sel, meks.len);
    const view = try q.lab(al, g, meks[self.lab_sel]);
    const lw: u16 = if (self.narrow()) 0 else @max(30, layout.lab_hulls.of(b.w));
    const mw: u16 = if (self.narrow()) layout.major.of(b.w) else @max(40, layout.lab_mounts.of(b.w));
    if (lw > 0) self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, view.title, view.budget, 1, false, false);
    var mounts: std.ArrayListUnmanaged([]const u8) = .empty;
    for (view.mounts) |m| try mounts.append(al, m.text);
    if (view.mounts.len == 0) try mounts.append(al, "{d}no mounts{/}");
    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = mw, .h = b.h }, try std.fmt.allocPrint(al, "MOUNTS · hull {d} of {d}", .{ self.lab_sel + 1, meks.len }), mounts.items, 0, true, true);
    self.listPane(.{ .x = b.x + lw + mw, .y = b.y, .w = b.w - lw - mw, .h = b.h }, if (view.legal) "PLAN" else "PLAN · {c}illegal{/}", view.plan, 2, false, false);
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = self.state();
    const uid = (try self.labUnit()) orelse return;
    const view = try q.lab(al, g, uid);
    self.moveCursor(0, delta, view.mounts.len);
}

const Action = enum { prev_hull, next_hull, install, remove, clear, commit, replace, depot };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('['), .action = .prev_hull, .label = "hull", .group = .navigate, .shown = "[ ]", .help = "previous / next mek in the hangar" },
    .{ .match = app.keys.Match.char(']'), .action = .next_hull, .label = "next hull", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('+'), .action = .install, .label = "install", .group = .act, .help = "stage installing a part from the home HQ's stock" },
    .{ .match = app.keys.Match.char('-'), .action = .remove, .label = "remove", .group = .act, .help = "stage removing the mount under the cursor" },
    .{ .match = app.keys.Match.char('c'), .action = .clear, .label = "clear", .group = .act, .help = "clear the staged refit plan" },
    .{ .match = .{ .key = .enter }, .action = .commit, .label = "commit", .group = .act, .help = "commit the plan as a bay job at the home HQ" },
    .{ .match = app.keys.Match.char('R'), .action = .replace, .label = "order replacement", .group = .act, .help = "order a replacement for the damaged or destroyed mount under the cursor" },
    .{ .match = app.keys.Match.char('D'), .action = .depot, .label = "depot", .group = .act, .help = "queue the hull for depot repair" },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = self.state();
    const uid = (try self.labUnit()) orelse return true;
    const view = try q.lab(al, g, uid);
    const meks = view.meks;
    switch (hit.action) {
        .next_hull => self.lab_sel = (self.lab_sel + 1) % meks.len,
        .prev_hull => self.lab_sel = (self.lab_sel + meks.len - 1) % meks.len,
        .remove => if (view.mounts.len > 0) {
            const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
            _ = try self.execSay(.{ .refit_remove = .{ .unit = uid, .slot_key = m.slot_key } }, .good, "staged: remove {s}", .{m.slot_key});
        },
        .install => {
            self.openModal(.{ .install_part = uid });
        },
        .replace => if (view.mounts.len > 0) {
            const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
            const res = self.execResultWith(.{ .replace_mount = .{ .unit = uid, .slot_key = m.slot_key } }, &.{
                .{ .err = error.MountIsFine, .style = .dim, .text = try std.fmt.allocPrint(self.a(), "{s} is fine — replacements are for damaged or destroyed gear", .{m.slot_key}) },
            }) orelse return true;
            self.say(.good, "ordered 1 × {s} to {s}; techs fit it on the next repair pass once it lands", .{ m.part_key, try q.hqName(self.a(), g, res.hq) });
        },
        .clear => {
            _ = try self.execSay(.{ .refit_clear = uid }, .good, "#{d}: refit plan cleared", .{@intFromEnum(uid)});
        },
        .commit => {
            _ = try self.execSay(.{ .refit_commit = uid }, .good, "refit committed — it is a bay job at the home HQ: the HQ screen lists the bays, queued and running, with days left", .{});
        },
        .depot => {
            _ = try self.execSay(.{ .depot = uid }, .good, "#{d} queued for depot repair — see the HQ screen's bays", .{@intFromEnum(uid)});
        },
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the lab bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "] and [ step through the hangar's meks" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .lab);
    const start = c.app.lab_sel;
    try app.pressForTest(c, .{ .char = ']' });
    try std.testing.expect(c.app.lab_sel != start);
    try app.pressForTest(c, .{ .char = '[' });
    try std.testing.expectEqual(start, c.app.lab_sel);
}

test "R on a sound mount words its own refusal" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .lab);
    try app.pressForTest(c, .{ .char = 'R' });
    // A fresh company's gear is sound: the lab's sentence, not "refused: …".
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "is fine") != null);
    try std.testing.expect(!std.mem.startsWith(u8, c.app.msg.slice(), "refused"));
}
