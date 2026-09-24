//! The Forces screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Tab = app.Tab;
const game = app.game;
const layout = app.layout;
const q = app.q;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const views = try q.toeViews(al, g);
    App.clampIdx(&self.forces_view, views.len);
    const rows = try q.toeFiltered(al, g, views[self.forces_view].filter);
    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rows) |r| try texts.append(al, r.text);
    const lw: u16 = if (layout.wide(b.w)) layout.list.of(b.w) else b.w;
    self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, try std.fmt.allocPrint(al, "TO&E · {{a}}{s}{{/}} ({d}/{d}) · [ ] switch", .{ views[self.forces_view].label, self.forces_view + 1, views.len }), texts.items, 0, self.focus == 0, true);
    if (lw < b.w) {
        const c = self.cur(0).*;
        const detail_h: u16 = layout.major.of(b.h);
        if (rows.len > 0 and c < rows.len and rows[c].unit != .none) {
            const detail = try q.hull(al, g, rows[c].unit);
            self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, "HULL", detail, 1, false, false);
        } else if (rows.len > 0 and c < rows.len and rows[c].force != .none and rows[c].company != .none) {
            const co = rows[c].company;
            switch (self.forces_pane) {
                .readiness => {
                    const lines = try q.readinessLines(al, g, co);
                    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "READINESS · {s} · r = manning", .{try q.forceName(self.a(), g, co)}), lines, 1, false, false);
                },
                .manning => {
                    var mrows: std.ArrayListUnmanaged([]const u8) = .empty;
                    const mq = try q.manning(al, g, co);
                    for (try (try q.tableOf(al, q.manning_cols, mq)).render(al), 0..) |ln, i| try mrows.append(al, if (i == 0) try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{ln}) else ln);
                    var open_total: u32 = 0;
                    for (mq) |m| open_total += m.need -| m.have;
                    try mrows.append(al, "");
                    try mrows.append(al, if (open_total == 0) "{g}every seat filled{/}" else try std.fmt.allocPrint(al, "{{c}}{d} open{{/}} — HQ screen Tab into the hall (f filters by role) · :crew co:N hires the open seats from the halls", .{open_total}));
                    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "MANNING · {s} · r = damage", .{try q.forceName(self.a(), g, co)}), mrows.items, 1, false, false);
                },
                .damage => {
                    const dmg = try q.companyDamage(al, g, co);
                    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "DAMAGE · {s} · r = readiness", .{try q.forceName(self.a(), g, co)}), dmg.lines, 1, false, false);
                },
            }
        } else {
            const empty = [_][]const u8{"{d}select a hull in the TO&E{/}"};
            self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, "HULL", &empty, 1, false, false);
        }
        const pool = try q.unassigned(al, g);
        self.listPane(.{ .x = b.x + lw, .y = b.y + detail_h, .w = b.w - lw, .h = b.h - detail_h }, "UNASSIGNED POOL", pool, 2, self.focus == 1, true);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        if (self.focus == 0) {
            const rows = try self.toeRows();
            self.moveCursor(0, delta, rows.len);
        } else {
            const pool = try q.unassigned(al, g);
            self.moveCursor(2, delta, pool.len);
        }

}

pub fn enter(self: *App) anyerror!void {
        const rows = try self.toeRows();
        const c = self.cur(0).*;
        if (self.focus == 0 and c < rows.len and rows[c].unit != .none) {
            if (self.narrow()) {
                self.modal = .{ .hull = rows[c].unit };
                return;
            }
            var buf: [64]u8 = undefined;
            self.input.set(std.fmt.bufPrint(&buf, "assign {d} ", .{@intFromEnum(rows[c].unit)}) catch "assign ");
            self.modal = .{ .input = .command };
        }

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const rows = try self.toeRows();
        const c = self.cur(0).*;
        const row: ?q.ToeRow = if (c < rows.len) rows[c] else null;
        switch (ch) {
            'a' => if (row) |r| {
                if (r.unit == .none) {
                    self.say(.dim, "put the cursor on a hull to crew it", .{});
                    return;
                }
                self.openModal(.{ .pick_crew = r.unit });
            },
            'u' => if (row) |r| {
                if (r.unit == .none) {
                    self.say(.dim, "put the cursor on a hull to clear its seat or tech", .{});
                    return;
                }
                self.openModal(.{ .pick_unassign = r.unit });
            },
            'A' => if (row) |r| {
                const co = r.company;
                if (co != .none) {
                    _ = try self.execSay(.{ .auto_assign = co }, .good, "auto-assigned {s}", .{try q.forceName(self.a(), g, co)});
                }
            },
            'c' => if (row) |r| {
                const co = r.company;
                if (co != .none) {
                    const res = self.execResult(.{ .crew_company = co }) orelse return;
                    self.say(if (res.still_open == 0) .good else .amber, "{s}: {d} hired to fill the manning table · {d} lines still open (no candidates on the boards yet)", .{ try q.forceName(self.a(), g, co), res.hired_count, res.still_open });
                }
            },
            't' => self.openCommand("train "),
            'T' => if (row) |r| {
                const co = r.company;
                if (co == .none) {
                    self.say(.dim, "put the cursor on a company (or one of its hulls) to train it", .{});
                    return;
                }
                const res = self.execResult(.{ .train_company = .{ .company = co } }) orelse return;
                self.say(if (res.enrolled > 0) .good else .amber, "{s}: {d} enrolled at their trades · {d} short of XP · {d} busy · {d} nothing to learn  (:train co:{d} <skill> targets one skill)", .{
                    try q.forceName(self.a(), g, co), res.enrolled, res.short_xp, res.busy, res.nothing_to_learn, @intFromEnum(co),
                });
            },
            'r' => {
                self.forces_pane = switch (self.forces_pane) {
                    .damage => .readiness,
                    .readiness => .manning,
                    .manning => .damage,
                };
                if (self.narrow() and self.forces_pane == .readiness) self.modal = .readiness;
            },
            'M' => {
                // Straight to the manning table (play feedback: it hid behind r).
                self.forces_pane = .manning;
                self.say(.dim, "MANNING: have / need per role for the company under the cursor — :crew co:N hires the gaps at home, xfer sends people out to a deployed one", .{});
            },
            'w' => if (row) |r| {
                const co = r.company;
                if (co == .none) {
                    self.say(.dim, "put the cursor on a company to raise its air wing", .{});
                    return;
                }
                _ = try self.execSay(.{ .raise_air_company = co }, .good, "{s} has an air wing — fighters go in its air lances (Market: aero filter; :newlance co:N air <name> adds a lance)", .{try q.forceName(self.a(), g, co)});
            },
            'x' => if (row) |r| {
                if (r.unit == .none) {
                    self.say(.dim, "put the cursor on a hull to send it to another company", .{});
                    return;
                }
                self.openModal(.{ .pick_company = .{ .what = .unit, .id = @intFromEnum(r.unit) } });
            },
            'l' => if (row) |r| {
                if (r.unit == .none) {
                    self.say(.dim, "put the cursor on a hull to move it into a lance", .{});
                    return;
                }
                self.openModal(.{ .lance_pick = r.unit });
            },
            '+', '=' => {
                // Aim at an HQ with a free combat-company slot (the selected
                // one if it has room); with none free, at the selected HQ,
                // and `raise_company` says why it refuses.
                const selected: app.types.HqId = @enumFromInt(self.hqSelId(g));
                const pick = q.hqWithCompanySlot(g, selected);
                self.raise.hq = if (pick == .none) selected else pick;
                self.input.len = 0;
                self.modal = .{ .input = .raise_name };
            },
            ']', '[' => {
                const views = try q.toeViews(al, g);
                self.forces_view = if (ch == ']') (self.forces_view + 1) % views.len else (self.forces_view + views.len - 1) % views.len;
                self.cur(0).* = 0;
            },
            'b' => if (row) |r| {
                const co = r.company;
                if (co == .none) {
                    self.say(.dim, "put the cursor on a company or one of its hulls", .{});
                    return;
                }
                const dmg = try q.companyDamage(al, g, co);
                if (dmg.short_key) |part| {
                    self.openAmount(try std.fmt.allocPrint(al, "FABRICATE {s} for {s}", .{ part, try q.forceName(self.a(), g, co) }), .{ .fabricate = .{ .hq = self.homeHqOf(co), .key = part } }, &.{
                        .{ .label = "quantity", .value = 1, .min = 1, .max = 20, .step = 1 },
                    });
                } else self.say(.good, "{s} needs no structural components the home HQ lacks", .{try q.forceName(self.a(), g, co)});
            },
            'm' => if (row) |r| {
                if (r.unit == .none) return;
                const res = self.execResult(.{ .toggle_mothball = r.unit }) orelse return;
                if (res.mothballed orelse false) self.say(.good, "#{d} mothballed — 20% upkeep, no maintenance wear, no crew needed", .{@intFromEnum(r.unit)}) else self.say(.good, "#{d} reactivating — tech-days before it can fight or move", .{@intFromEnum(r.unit)});
            },
            '$' => if (row) |r| {
                if (r.unit != .none) self.modal = .{ .confirm = .{ .kind = .sell_unit, .id = @intFromEnum(r.unit) } };
            },
            'd' => if (row) |r| {
                if (r.unit != .none) {
                    const res = self.execResult(.{ .depot = r.unit }) orelse return;
                    self.say(.good, "#{d} queued for depot repair at {s} — HQ screen, [ ] to that HQ, its bays list the job", .{ @intFromEnum(r.unit), try q.hqName(self.a(), g, res.hq) });
                }
            },
            'o' => if (row) |r| {
                if (r.force == .none) return;
                // On a company row: cycle its rules of engagement (12D.4).
                if (r.is_company) {
                    const res = self.execResult(.{ .cycle_roe = r.force }) orelse return;
                    self.say(.good, "{s} ROE → {s}", .{ try q.plain(self.a(), r.name), res.roe.?.describe() });
                    return;
                }
                if (!r.is_lance) {
                    self.say(.dim, "roles are set on lances, rules of engagement on companies — move the cursor onto a lance or company row", .{});
                    return;
                }
                const res = self.execResult(.{ .cycle_role = r.force }) orelse return;
                self.say(.good, "{s} → {s}: {s}", .{ try q.plain(self.a(), r.name), @tagName(res.role.?), res.role.?.describe() });
            },
            'X' => if (row) |r| {
                const co = r.company;
                if (co != .none) self.modal = .{ .confirm = .{ .kind = .disband, .id = @intFromEnum(co) } };
            },
            'R' => if (row) |r| {
                if (r.unit != .none) {
                    // Gear is field work on every hull kind: order spares for what's destroyed to the hull's site.
                    const res = self.execResult(.{ .replace_gear = r.unit }) orelse return;
                    if (res.ordered + res.unsourced == 0) {
                        self.say(.good, "#{d}: spares for its broken gear are already on hand or on order — its tech fits them on the weekly repair pass", .{@intFromEnum(r.unit)});
                    } else {
                        self.say(if (res.unsourced == 0) .good else .amber, "#{d}: {d} spare{s} ordered to its site{s} — its tech fits them on the weekly repair pass", .{
                            @intFromEnum(r.unit), res.ordered, if (res.ordered == 1) "" else "s",
                            if (res.unsourced > 0) " (some could not be sourced this month — retry after the refresh)" else "",
                        });
                    }
                    return;
                }
                const co = r.company;
                if (co == .none) return;
                _ = try self.execSay(.{ .recall_idle = co }, .good, "{s} is coming home", .{try q.forceName(self.a(), g, co)});
            },
            else => {},
        }

}
