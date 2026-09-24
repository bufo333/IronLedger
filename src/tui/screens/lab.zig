//! The Lab screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const game = app.game;
const layout = app.layout;
const q = app.q;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
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
    const g = &self.gs.?;
        const uid = (try self.labUnit()) orelse return;
        const view = try q.lab(al, g, uid);
        self.moveCursor(0, delta, view.mounts.len);

}

pub fn enter(self: *App) anyerror!void {
        const uid = (try self.labUnit()) orelse return;
        _ = try self.execSay(.{ .refit_commit = uid }, .good, "refit committed — it is a bay job at the home HQ: HQ screen (F7) lists the bays, queued and running, with days left", .{});

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const uid = (try self.labUnit()) orelse return;
        const view = try q.lab(al, g, uid);
        const meks = view.meks;
        switch (ch) {
            ']' => self.lab_sel = (self.lab_sel + 1) % meks.len,
            '[' => self.lab_sel = (self.lab_sel + meks.len - 1) % meks.len,
            '-' => if (view.mounts.len > 0) {
                const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
                _ = try self.execSay(.{ .refit_remove = .{ .unit = uid, .slot_key = m.slot_key } }, .good, "staged: remove {s} — Enter commits the plan to a bay, c clears it", .{m.slot_key});
            },
            '+' => {
                self.openModal(.{ .install_part = uid });
            },
            'R' => if (view.mounts.len > 0) {
                const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
                const res = game.commands.execute(g, .{ .replace_mount = .{ .unit = uid, .slot_key = m.slot_key } }) catch |err| switch (err) { // direct: a sound mount says how to order one
                    error.MountIsFine => return self.say(.dim, "{s} is fine — [R] orders a replacement for damaged or destroyed gear", .{m.slot_key}),
                    else => return self.say(.crit, "{s}", .{game.cli.errorText(err)}),
                };
                self.say(.good, "ordered 1 × {s} to {s}; techs fit it on the next repair pass once it lands", .{ m.part_key, try q.hqName(self.a(), g, res.hq) });
            },
            'c' => {
                _ = try self.execSay(.{ .refit_clear = uid }, .good, "#{d}: refit plan cleared", .{@intFromEnum(uid)});
            },
            'D' => {
                _ = try self.execSay(.{ .depot = uid }, .good, "#{d} queued for depot repair — see the HQ screen's bays", .{@intFromEnum(uid)});
            },
            else => {},
        }

}
