//! The Forces screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the TO&E tab (docs/mekhq-map.md).

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
    self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, try std.fmt.allocPrint(al, "TO&E · {{a}}{s}{{/}} ({d}/{d}) · {s}", .{ views[self.forces_view].label, self.forces_view + 1, views.len, try app.keys.paneTitle(al, &legend, 0) }), texts.items, 0, self.focus == 0, true);
    if (lw < b.w) {
        const c = self.cur(0).*;
        const detail_h: u16 = layout.major.of(b.h);
        if (rows.len > 0 and c < rows.len and rows[c].unit != .none) {
            const detail = try q.hull(al, g, rows[c].unit);
            self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, "HULL", detail, 1, false, false);
        } else if (rows.len > 0 and c < rows.len and rows[c].force != .none and rows[c].company != .none) {
            const co = rows[c].company;
            const side_hint = try app.keys.paneTitle(al, &legend, 1);
            switch (self.forces_pane) {
                .readiness => {
                    const lines = try q.readinessLines(al, g, co);
                    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "READINESS · {s} · {s}", .{ try q.forceName(self.a(), g, co), side_hint }), lines, 1, false, false);
                },
                .manning => {
                    var mrows: std.ArrayListUnmanaged([]const u8) = .empty;
                    const mq = try q.manning(al, g, co);
                    for (try (try q.tableOf(al, q.manning_cols, mq)).render(al), 0..) |ln, i| try mrows.append(al, if (i == 0) try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{ln}) else ln);
                    var open_total: u32 = 0;
                    for (mq) |m| open_total += m.need -| m.have;
                    try mrows.append(al, "");
                    try mrows.append(al, if (open_total == 0) "{g}every seat filled{/}" else try std.fmt.allocPrint(al, "{{c}}{d} open{{/}} — the hiring halls fill them", .{open_total}));
                    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "MANNING · {s} · {s}", .{ try q.forceName(self.a(), g, co), side_hint }), mrows.items, 1, false, false);
                },
                .damage => {
                    const dmg = try q.companyDamage(al, g, co);
                    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = detail_h }, try std.fmt.allocPrint(al, "DAMAGE · {s} · {s}", .{ try q.forceName(self.a(), g, co), side_hint }), dmg.lines, 1, false, false);
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

const Action = enum { prev_view, next_view, assign, seat, unassign, lance, transfer, crew, auto_assign, train_one, train_all, cycle_pane, order, depot, spares_recall, mothball, air_wing, raise, sell, disband, fabricate };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('['), .action = .prev_view, .label = "switch view", .group = .navigate, .shown = "[ ]", .title = 0, .help = "previous / next TO&E view: all forces, each company, unassigned hulls, the hangar" },
    .{ .match = app.keys.Match.char(']'), .action = .next_view, .label = "next view", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('r'), .action = .cycle_pane, .label = "cycle pane", .group = .navigate, .title = 1, .help = "cycle the side pane: readiness, manning, damage" },
    .{ .match = .{ .key = .enter }, .action = .assign, .label = "assign", .group = .act, .pane = 0, .help = "assign people to the hull under the cursor (narrow: its detail)" },
    .{ .match = app.keys.Match.char('a'), .action = .seat, .label = "seat", .group = .act, .help = "seat a pilot, crew or tech on the hull under the cursor" },
    .{ .match = app.keys.Match.char('u'), .action = .unassign, .label = "unassign", .group = .act, .help = "clear a seat or the tech on the hull under the cursor" },
    .{ .match = app.keys.Match.char('l'), .action = .lance, .label = "lance", .group = .act, .help = "move the hull under the cursor into a lance" },
    .{ .match = app.keys.Match.char('x'), .action = .transfer, .label = "transfer", .group = .act, .help = "send the hull under the cursor to another company" },
    .{ .match = app.keys.Match.char('c'), .action = .crew, .label = "crew", .group = .act, .help = "hire from the halls to fill the company's manning table" },
    .{ .match = app.keys.Match.char('A'), .action = .auto_assign, .label = "auto", .group = .act, .help = "auto-assign the company's people to its hulls" },
    .{ .match = app.keys.Match.char('t'), .action = .train_one, .label = "train one / all", .group = .act, .shown = "t / T", .help = "train one person (the command line); T enrolls the whole company" },
    .{ .match = app.keys.Match.char('T'), .action = .train_all, .label = "train all", .group = .act, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('o'), .action = .order, .label = "role (lance) / ROE (company)", .group = .act, .help = "cycle a lance's role, or a company's rules of engagement" },
    .{ .match = app.keys.Match.char('d'), .action = .depot, .label = "depot", .group = .act, .help = "queue the hull under the cursor for depot repair" },
    .{ .match = app.keys.Match.char('R'), .action = .spares_recall, .label = "spares (hull) / recall (company)", .group = .act, .help = "on a hull: order spares for its broken gear; on a company: recall it home" },
    .{ .match = app.keys.Match.char('m'), .action = .mothball, .label = "mothball", .group = .act, .help = "mothball or reactivate the hull under the cursor" },
    .{ .match = app.keys.Match.char('w'), .action = .air_wing, .label = "air wing", .group = .act, .help = "raise an air wing for the company under the cursor" },
    .{ .match = app.keys.Match.char('+'), .action = .raise, .label = "raise", .group = .act, .help = "raise a new combat company" },
    .{ .match = app.keys.Match.char('='), .action = .raise, .label = "raise", .group = .act, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('$'), .action = .sell, .label = "sell", .group = .money, .help = "sell the hull under the cursor" },
    .{ .match = app.keys.Match.char('X'), .action = .disband, .label = "disband", .group = .money, .help = "disband the company under the cursor" },
    .{ .match = app.keys.Match.char('b'), .action = .fabricate, .label = "fabricate", .group = .money, .help = "fabricate the structural parts the company's home HQ lacks" },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = &self.gs.?;
    const rows = try self.toeRows();
    const c = self.cur(0).*;
    const row: ?q.ToeRow = if (c < rows.len) rows[c] else null;
    switch (hit.action) {
        .assign => if (self.focus == 0 and c < rows.len and rows[c].unit != .none) {
            if (self.narrow()) {
                self.modal = .{ .hull = rows[c].unit };
                return true;
            }
            var buf: [64]u8 = undefined;
            self.input.set(std.fmt.bufPrint(&buf, "assign {d} ", .{@intFromEnum(rows[c].unit)}) catch "assign ");
            self.modal = .{ .input = .command };
        },
        .seat => if (row) |r| {
            if (r.unit == .none) {
                self.say(.dim, "put the cursor on a hull to crew it", .{});
                return true;
            }
            self.openModal(.{ .pick_crew = r.unit });
        },
        .unassign => if (row) |r| {
            if (r.unit == .none) {
                self.say(.dim, "put the cursor on a hull to clear its seat or tech", .{});
                return true;
            }
            self.openModal(.{ .pick_unassign = r.unit });
        },
        .auto_assign => if (row) |r| {
            const co = r.company;
            if (co != .none) {
                _ = try self.execSay(.{ .auto_assign = co }, .good, "auto-assigned {s}", .{try q.forceName(self.a(), g, co)});
            }
        },
        .crew => if (row) |r| {
            const co = r.company;
            if (co != .none) {
                const res = self.execResult(.{ .crew_company = co }) orelse return true;
                self.say(if (res.still_open == 0) .good else .amber, "{s}: {d} hired to fill the manning table · {d} lines still open (no candidates on the boards yet)", .{ try q.forceName(self.a(), g, co), res.hired_count, res.still_open });
            }
        },
        .train_one => self.openCommand("train "),
        .train_all => if (row) |r| {
            const co = r.company;
            if (co == .none) {
                self.say(.dim, "put the cursor on a company (or one of its hulls) to train it", .{});
                return true;
            }
            const res = self.execResult(.{ .train_company = .{ .company = co } }) orelse return true;
            self.say(if (res.enrolled > 0) .good else .amber, "{s}: {d} enrolled at their trades · {d} short of XP · {d} busy · {d} nothing to learn  (:train co:{d} <skill> targets one skill)", .{
                try q.forceName(self.a(), g, co), res.enrolled, res.short_xp, res.busy, res.nothing_to_learn, @intFromEnum(co),
            });
        },
        .cycle_pane => {
            self.forces_pane = switch (self.forces_pane) {
                .damage => .readiness,
                .readiness => .manning,
                .manning => .damage,
            };
            if (self.narrow() and self.forces_pane == .readiness) self.modal = .readiness;
        },
        .air_wing => if (row) |r| {
            const co = r.company;
            if (co == .none) {
                self.say(.dim, "put the cursor on a company to raise its air wing", .{});
                return true;
            }
            _ = try self.execSay(.{ .raise_air_company = co }, .good, "{s} has an air wing — fighters go in its air lances (Market: aero filter; :newlance co:N air <name> adds a lance)", .{try q.forceName(self.a(), g, co)});
        },
        .transfer => if (row) |r| {
            if (r.unit == .none) {
                self.say(.dim, "put the cursor on a hull to send it to another company", .{});
                return true;
            }
            self.openModal(.{ .pick_company = .{ .what = .unit, .id = @intFromEnum(r.unit) } });
        },
        .lance => if (row) |r| {
            if (r.unit == .none) {
                self.say(.dim, "put the cursor on a hull to move it into a lance", .{});
                return true;
            }
            self.openModal(.{ .lance_pick = r.unit });
        },
        .raise => {
            // Aim at an HQ with a free combat-company slot (the selected
            // one if it has room); with none free, at the selected HQ,
            // and `raise_company` says why it refuses.
            const selected: app.types.HqId = @enumFromInt(self.hqSelId(g));
            const pick = q.hqWithCompanySlot(g, selected);
            self.raise.hq = if (pick == .none) selected else pick;
            self.input.len = 0;
            self.modal = .{ .input = .raise_name };
        },
        .next_view => {
            const views = try q.toeViews(al, g);
            self.forces_view = (self.forces_view + 1) % views.len;
            self.cur(0).* = 0;
        },
        .prev_view => {
            const views = try q.toeViews(al, g);
            self.forces_view = (self.forces_view + views.len - 1) % views.len;
            self.cur(0).* = 0;
        },
        .fabricate => if (row) |r| {
            const co = r.company;
            if (co == .none) {
                self.say(.dim, "put the cursor on a company or one of its hulls", .{});
                return true;
            }
            const dmg = try q.companyDamage(al, g, co);
            if (dmg.short_key) |part| {
                self.openAmount(try std.fmt.allocPrint(al, "FABRICATE {s} for {s}", .{ part, try q.forceName(self.a(), g, co) }), .{ .fabricate = .{ .hq = self.homeHqOf(co), .key = part } }, &.{
                    .{ .label = "quantity", .value = 1, .min = 1, .max = 20, .step = 1 },
                });
            } else self.say(.good, "{s} needs no structural components the home HQ lacks", .{try q.forceName(self.a(), g, co)});
        },
        .mothball => if (row) |r| {
            if (r.unit == .none) return true;
            const res = self.execResult(.{ .toggle_mothball = r.unit }) orelse return true;
            if (res.mothballed orelse false) self.say(.good, "#{d} mothballed — 20% upkeep, no maintenance wear, no crew needed", .{@intFromEnum(r.unit)}) else self.say(.good, "#{d} reactivating — tech-days before it can fight or move", .{@intFromEnum(r.unit)});
        },
        .sell => if (row) |r| {
            if (r.unit != .none) self.modal = .{ .confirm = .{ .kind = .sell_unit, .id = @intFromEnum(r.unit) } };
        },
        .depot => if (row) |r| {
            if (r.unit != .none) {
                const res = self.execResult(.{ .depot = r.unit }) orelse return true;
                self.say(.good, "#{d} queued for depot repair at {s} — that HQ's bays list the job", .{ @intFromEnum(r.unit), try q.hqName(self.a(), g, res.hq) });
            }
        },
        .order => if (row) |r| {
            if (r.force == .none) return true;
            // On a company row: cycle its rules of engagement.
            if (r.is_company) {
                const res = self.execResult(.{ .cycle_roe = r.force }) orelse return true;
                self.say(.good, "{s} ROE → {s}", .{ try r.name.markup(self.a()), res.roe.?.describe() });
                return true;
            }
            if (!r.is_lance) {
                self.say(.dim, "roles are set on lances, rules of engagement on companies — move the cursor onto a lance or company row", .{});
                return true;
            }
            const res = self.execResult(.{ .cycle_role = r.force }) orelse return true;
            self.say(.good, "{s} → {s}: {s}", .{ try r.name.markup(self.a()), @tagName(res.role.?), res.role.?.describe() });
        },
        .disband => if (row) |r| {
            const co = r.company;
            if (co != .none) self.modal = .{ .confirm = .{ .kind = .disband, .id = @intFromEnum(co) } };
        },
        .spares_recall => if (row) |r| {
            if (r.unit != .none) {
                // Gear is field work on every hull kind: order spares for what's destroyed to the hull's site.
                const res = self.execResult(.{ .replace_gear = r.unit }) orelse return true;
                if (res.ordered + res.unsourced == 0) {
                    self.say(.good, "#{d}: spares for its broken gear are already on hand or on order — its tech fits them on the weekly repair pass", .{@intFromEnum(r.unit)});
                } else {
                    self.say(if (res.unsourced == 0) .good else .amber, "#{d}: {d} spare{s} ordered to its site{s} — its tech fits them on the weekly repair pass", .{
                        @intFromEnum(r.unit), res.ordered, if (res.ordered == 1) "" else "s",
                        if (res.unsourced > 0) " (some could not be sourced this month — retry after the refresh)" else "",
                    });
                }
                return true;
            }
            const co = r.company;
            if (co == .none) return true;
            _ = try self.execSay(.{ .recall_idle = co }, .good, "{s} is coming home", .{try q.forceName(self.a(), g, co)});
        },
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the forces bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "+ opens the raise-a-company name prompt and Esc leaves it" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .forces);
    try app.pressForTest(c, .{ .char = '+' });
    try std.testing.expect(c.app.modal == .input and c.app.modal.input == .raise_name);
    try app.pressForTest(c, .escape);
    try std.testing.expect(c.app.modal == .none);
}
