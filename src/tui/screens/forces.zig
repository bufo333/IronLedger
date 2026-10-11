//! The Forces screen (docs/engineering-contract.md rule 35): its draw, cursor
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
    const g = self.state();
    const b = self.body();
    const views = try q.toeViews(al, g);
    // forces_view may be views.len when the artillery panel is selected.
    if (self.forces_view > views.len) self.forces_view = views.len;
    if (self.forces_view == views.len) {
        // Artillery panel: use cur(0) as the single shared selection cursor.
        const arty_rows = try q.artilleryFormationRows(al, g);
        App.clampIdx(self.cur(0), arty_rows.len);
        const lw: u16 = if (layout.wide(b.w)) layout.list.of(b.w) else b.w;
        const total_views = views.len + 1;
        var list_texts = try al.alloc([]const u8, arty_rows.len);
        for (arty_rows, 0..) |r, i| list_texts[i] = r.text;
        self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, try std.fmt.allocPrint(al, "ARTILLERY ({d}/{d}) · {s}", .{ total_views, total_views, try app.keys.paneTitle(al, &legend, 0) }), list_texts, 0, self.paneFocused(0), true);
        if (lw < b.w) {
            const cur_val = self.cur(0).*;
            if (cur_val < arty_rows.len) {
                const detail = try q.artilleryDetailLines(al, g, arty_rows[cur_val].id);
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = b.h }, "ARTILLERY DETAIL", detail, 1, self.paneFocused(1), true);
            } else {
                const empty = [_][]const u8{"{d}no artillery formations{/}"};
                self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = b.h }, "ARTILLERY DETAIL", &empty, 1, self.paneFocused(1), false);
            }
        }
        return;
    }
    App.clampIdx(&self.forces_view, views.len);
    const rows = try q.toeFiltered(al, g, views[self.forces_view].filter);
    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rows) |r| try texts.append(al, r.text);
    const lw: u16 = if (layout.wide(b.w)) layout.list.of(b.w) else b.w;
    self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, try std.fmt.allocPrint(al, "TO&E · {{a}}{s}{{/}} ({d}/{d}) · {s}", .{ views[self.forces_view].label, self.forces_view + 1, views.len + 1, try app.keys.paneTitle(al, &legend, 0) }), texts.items, 0, self.paneFocused(0), true);
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
                    for (mq) |m| open_total += m.open;
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
        self.listPane(.{ .x = b.x + lw, .y = b.y + detail_h, .w = b.w - lw, .h = b.h - detail_h }, "UNASSIGNED POOL", pool, 2, self.paneFocused(1), true);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = self.state();
    const views = try q.toeViews(al, g);
    if (self.forces_view == views.len) {
        if (self.focus == 1) {
            // Detail pane: scroll through the formation's detail lines.
            const arty_rows = try q.artilleryFormationRows(al, g);
            const cur_val = self.cur(0).*;
            if (cur_val < arty_rows.len) {
                const detail = try q.artilleryDetailLines(al, g, arty_rows[cur_val].id);
                self.moveCursor(1, delta, detail.len);
            }
            return;
        }
        if (self.focus != 0) return;
        const arty_rows = try q.artilleryFormationRows(al, g);
        self.moveCursor(0, delta, arty_rows.len);
        return;
    }
    if (self.focus == 0) {
        const rows = try self.toeRows();
        self.moveCursor(0, delta, rows.len);
    } else {
        const pool = try q.unassigned(al, g);
        self.moveCursor(2, delta, pool.len);
    }
}

const Action = enum { prev_view, next_view, assign, seat, unassign, lance, transfer, crew, auto_assign, train_one, train_all, cycle_pane, order, depot, spares_recall, mothball, air_wing, raise, sell, disband, fabricate, mech, arty_attach, arty_seat, arty_tech, arty_reload, arty_repair, arty_ship, arty_sell };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('['), .action = .prev_view, .label = "switch view", .group = .navigate, .shown = "[ ]", .title = 0, .help = "previous / next TO&E view: all forces, each company, unassigned hulls, the hangar, artillery" },
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
    .{ .match = app.keys.Match.char('h'), .action = .mech, .label = "mech record", .group = .act, .help = "open the hull's lifecycle: combat history, maintenance log and ownership chain" },
    // Artillery panel keys (active on the artillery view)
    .{ .match = app.keys.Match.char('e'), .action = .arty_attach, .label = "attach / detach", .group = .act, .help = "attach or detach the artillery carrier (artillery panel)" },
    .{ .match = app.keys.Match.char('f'), .action = .arty_seat, .label = "seat crew", .group = .act, .help = "assign an artillery crew seat (artillery panel)" },
    .{ .match = app.keys.Match.char('g'), .action = .arty_tech, .label = "assign tech", .group = .act, .help = "assign or clear the artillery mechanic (artillery panel)" },
    .{ .match = app.keys.Match.char('i'), .action = .arty_reload, .label = "reload", .group = .act, .help = "reload artillery magazines (artillery panel)" },
    .{ .match = app.keys.Match.char('v'), .action = .arty_repair, .label = "repair", .group = .act, .help = "queue an artillery depot repair (artillery panel)" },
    .{ .match = app.keys.Match.char('s'), .action = .arty_ship, .label = "ship to HQ", .group = .act, .help = "transfer artillery to another HQ (artillery panel)" },
    .{ .match = app.keys.Match.char('p'), .action = .arty_sell, .label = "sell arty", .group = .money, .help = "sell the artillery carrier (artillery panel)" },
};
pub const legend = app.keys.entries(Action, &bindings);

fn handleArty(self: *App, action: Action, al: std.mem.Allocator, g: *app.GameState) anyerror!bool {
    const views = try q.toeViews(al, g);
    const arty_rows = try q.artilleryFormationRows(al, g);
    const cur = self.cur(0).*;
    var buf: [64]u8 = undefined;
    switch (action) {
        .next_view => {
            self.forces_view = (self.forces_view + 1) % (views.len + 1);
            self.cur(0).* = 0;
        },
        .prev_view => {
            self.forces_view = (self.forces_view + views.len) % (views.len + 1);
            self.cur(0).* = 0;
        },
        .assign => {
            // Enter on narrow: open the detail modal for the selected formation.
            if (self.narrow() and cur < arty_rows.len) {
                self.modal = .{ .arty_detail = arty_rows[cur].id };
            }
        },
        .arty_attach => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const row = arty_rows[cur];
            const fid = @intFromEnum(row.id);
            if (row.attached) {
                self.input.set(std.fmt.bufPrint(&buf, "detacharty {d}", .{fid}) catch "detacharty ");
            } else {
                self.input.set(std.fmt.bufPrint(&buf, "attacharty {d} co:", .{fid}) catch "attacharty ");
            }
            self.modal = .{ .input = .command };
        },
        .arty_seat => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const fid = @intFromEnum(arty_rows[cur].id);
            self.input.set(std.fmt.bufPrint(&buf, "seat {d} ", .{fid}) catch "seat ");
            self.modal = .{ .input = .command };
        },
        .arty_tech => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const fid = @intFromEnum(arty_rows[cur].id);
            self.input.set(std.fmt.bufPrint(&buf, "artytech {d} ", .{fid}) catch "artytech ");
            self.modal = .{ .input = .command };
        },
        .arty_reload => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const fid = @intFromEnum(arty_rows[cur].id);
            self.input.set(std.fmt.bufPrint(&buf, "reloadarty {d} ", .{fid}) catch "reloadarty ");
            self.modal = .{ .input = .command };
        },
        .arty_repair => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const cmd = app.game.commands.Command{ .repair_artillery = arty_rows[cur].id };
            const res = self.execResult(cmd) orelse return true;
            self.say(.good, "{s}", .{try q.resultText(self.a(), g, cmd, res)});
        },
        .arty_ship => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const fid = @intFromEnum(arty_rows[cur].id);
            self.input.set(std.fmt.bufPrint(&buf, "shiparty {d} hq:", .{fid}) catch "shiparty ");
            self.modal = .{ .input = .command };
        },
        .arty_sell => {
            if (cur >= arty_rows.len) {
                self.say(.dim, "no artillery formation selected", .{});
                return true;
            }
            const fid = @intFromEnum(arty_rows[cur].id);
            self.input.set(std.fmt.bufPrint(&buf, "sellarty {d}", .{fid}) catch "sellarty ");
            self.modal = .{ .input = .command };
        },
        else => {}, // TO&E-specific actions do not apply in the artillery panel
    }
    return true;
}

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = self.state();
    // Dispatch to artillery handlers when the artillery panel is active.
    {
        const views = try q.toeViews(al, g);
        if (self.forces_view == views.len) return try handleArty(self, hit.action, al, g);
    }
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
            const selected: app.types.HqId = @enumFromInt(try self.hqSelId(g));
            const pick = q.hqWithCompanySlot(g, selected);
            self.raise.hq = if (pick == .none) selected else pick;
            self.input.len = 0;
            self.modal = .{ .input = .raise_name };
        },
        .next_view => {
            const views = try q.toeViews(al, g);
            self.forces_view = (self.forces_view + 1) % (views.len + 1);
            self.cur(0).* = 0;
        },
        .prev_view => {
            const views = try q.toeViews(al, g);
            self.forces_view = (self.forces_view + views.len) % (views.len + 1);
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
                self.openAmount(try std.fmt.allocPrint(al, "FABRICATE {s} for {s}", .{ part, try q.forceName(self.a(), g, co) }), .{ .fabricate = .{ .hq = try self.homeHqOf(co), .key = part } }, &.{
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
        .mech => if (row) |r| {
            if (r.unit == .none) {
                self.say(.dim, "put the cursor on a hull to open its lifecycle record", .{});
                return true;
            }
            const hid = q.hullInstanceForUnit(g, r.unit);
            if (hid != .none) {
                self.openModal(.{ .mech = .{ .id = hid } });
            } else {
                self.say(.dim, "no lifecycle record for this hull", .{});
            }
        },
        // Artillery panel actions — only reachable via handleArty; never reached here.
        .arty_attach, .arty_seat, .arty_tech, .arty_reload, .arty_repair, .arty_ship, .arty_sell => {},
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the forces bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

fn navToArty(c: *app.ClientForTest) !void {
    // [ from view 0 wraps to view views.len (artillery panel).
    // Compute expected index first, then navigate.
    const al = c.app.frame.allocator();
    const views = try q.toeViews(al, c.app.state());
    c.app.forces_view = 0;
    try app.pressForTest(c, .{ .char = '[' });
    try std.testing.expectEqual(views.len, c.app.forces_view);
}

test "artillery panel: empty state draws without crash" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .forces);
    try navToArty(c);
    // cur(0) must be 0 and modal must be none
    try std.testing.expectEqual(@as(usize, 0), c.app.cur(0).*);
    try std.testing.expect(c.app.modal == .none);
}

fn buyTestFormation(c: *app.ClientForTest) !bool {
    const al = c.app.frame.allocator();
    const gs = c.app.state();
    const hq_rows = try q.hqList(al, gs);
    if (hq_rows.len == 0) return false;
    const hq_id = hq_rows[0].id;
    const offer_rows = try q.artilleryOfferRows(al, gs);
    if (offer_rows.len == 0) return false;
    const offer_id = offer_rows[0].id;
    // HQ founding_funds = 1M; purchasePrice ≈ 1.78M; loan 800K tops it up via courier.
    if (!try c.app.exec(.{ .take_loan = .{ .principal = 800_000, .term_months = 12 } })) return false;
    if (!try c.app.exec(.{ .transfer = .{ .from = .outfit, .to = .{ .hq = hq_id }, .amount = 800_000 } })) return false;
    _ = try c.app.exec(.{ .advance_days = 4 }); // same_world_days = 3; courier arrives
    return try c.app.exec(.{ .buy_artillery = .{ .hq = hq_id, .offer = offer_id } });
}

test "artillery panel: with a formation, cursor, controls and detail" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    const ok = try buyTestFormation(c);
    try std.testing.expect(ok);
    const al = c.app.frame.allocator();
    // One formation exists and row identity is typed
    const rows = try q.artilleryFormationRows(al, c.app.state());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    const bought_id = rows[0].id;
    try toTab(c, .forces);
    try navToArty(c);
    // Cursor 0 targets the bought formation
    try std.testing.expectEqual(bought_id, (try q.artilleryFormationRows(al, c.app.state()))[c.app.cur(0).*].id);
    // Down clamps at 0 (only one row)
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(usize, 0), c.app.cur(0).*);
    // 'e' (arty_attach) prefills attacharty for an unattached formation
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "attacharty") != null);
    try app.pressForTest(c, .escape);
    // 'f' (arty_seat) prefills seat command
    try app.pressForTest(c, .{ .char = 'f' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "seat") != null);
    try app.pressForTest(c, .escape);
    // 'g' (arty_tech) prefills artytech command
    try app.pressForTest(c, .{ .char = 'g' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "artytech") != null);
    try app.pressForTest(c, .escape);
    // 'i' (arty_reload) prefills reloadarty command
    try app.pressForTest(c, .{ .char = 'i' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "reloadarty") != null);
    try app.pressForTest(c, .escape);
    // 's' (arty_ship) prefills shiparty command
    try app.pressForTest(c, .{ .char = 's' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "shiparty") != null);
    try app.pressForTest(c, .escape);
    // 'p' (arty_sell) prefills sellarty command
    try app.pressForTest(c, .{ .char = 'p' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "sellarty") != null);
    try app.pressForTest(c, .escape);
    // 'e' after attaching should prefill "detacharty N"
    const toe_rows = try q.toeFiltered(al, c.app.state(), .all);
    var co: ?game.types.ForceId = null;
    for (toe_rows) |r| if (r.is_company) {
        co = r.force;
        break;
    };
    try std.testing.expect(co != null);
    // 'e' opens input with attacharty prefill; complete and submit to actually attach
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "attacharty") != null);
    var attach_buf: [64]u8 = undefined;
    c.app.input.set(std.fmt.bufPrint(&attach_buf, "attacharty {d} co:{d}", .{ @intFromEnum(bought_id), @intFromEnum(co.?) }) catch "");
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "attached") != null);
    // 'e' while attached prefills "detacharty N"; submit to detach
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(c.app.modal == .input);
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), "detacharty") != null);
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "detached") != null);
    // 'v' (arty_repair) executes directly: no qualified local mechanic assigned, modal stays .none
    const hash_before_repair = game.digest.stateHash(c.app.state());
    try app.pressForTest(c, .{ .char = 'v' });
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "qualified local mechanic") != null);
    try std.testing.expectEqual(hash_before_repair, game.digest.stateHash(c.app.state()));
    // Tab focuses detail pane (pane 1) on wide terminal
    try app.pressForTest(c, .tab);
    try std.testing.expectEqual(@as(u8, 1), c.app.focus);
    // j/k on detail pane moves cur(1)
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(usize, 1), c.app.cur(1).*);
    // 'j' clamped to end of detail view
    const detail_lines = try q.artilleryDetailLines(al, c.app.state(), bought_id);
    try std.testing.expect(detail_lines.len > 0);
    for (0..detail_lines.len + 5) |_| try app.pressForTest(c, .down);
    try std.testing.expectEqual(detail_lines.len - 1, c.app.cur(1).*);
    // Narrow resize: focus clamps from 1 to 0 (narrow_panes = 1)
    try c.app.screen.resize(80, 24);
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(u8, 0), c.app.focus);
}

test "artillery panel: two formations, cursor targets correct row" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    const al = c.app.frame.allocator();
    const hq_rows = try q.hqList(al, c.app.state());
    try std.testing.expect(hq_rows.len > 0);
    const home = hq_rows[0].id;
    try std.testing.expect(try c.app.exec(.{ .transfer = .{ .from = .outfit, .to = .{ .hq = home }, .amount = 800_000 } }));
    try std.testing.expect(try c.app.exec(.{ .advance_days = 4 })); // courier arrives (same_world_days = 3)
    const offer_rows_1 = try q.artilleryOfferRows(al, c.app.state());
    try std.testing.expect(offer_rows_1.len > 0);
    try std.testing.expect(try c.app.exec(.{ .buy_artillery = .{ .hq = home, .offer = offer_rows_1[0].id } }));
    try std.testing.expect(try c.app.exec(.{ .transfer = .{ .from = .outfit, .to = .{ .hq = home }, .amount = 2_000_000 } }));
    try std.testing.expect(try c.app.exec(.{ .advance_days = 28 })); // advance past Jan (31 days) into month 2
    const offer_rows_2 = try q.artilleryOfferRows(al, c.app.state());
    try std.testing.expect(offer_rows_2.len > 0);
    try std.testing.expect(try c.app.exec(.{ .buy_artillery = .{ .hq = home, .offer = offer_rows_2[0].id } }));
    const rows = try q.artilleryFormationRows(al, c.app.state());
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    const id0 = rows[0].id;
    const id1 = rows[1].id;
    try toTab(c, .forces);
    try navToArty(c);
    // Cursor starts at 0 — targets first formation
    try std.testing.expectEqual(@as(usize, 0), c.app.cur(0).*);
    var buf: [64]u8 = undefined;
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), std.fmt.bufPrint(&buf, "attacharty {d}", .{@intFromEnum(id0)}) catch "") != null);
    try app.pressForTest(c, .escape);
    // Down moves to row 1
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(usize, 1), c.app.cur(0).*);
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(std.mem.indexOf(u8, c.app.input.slice(), std.fmt.bufPrint(&buf, "attacharty {d}", .{@intFromEnum(id1)}) catch "") != null);
    try app.pressForTest(c, .escape);
    // Down clamps at row 1 (last row)
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(usize, 1), c.app.cur(0).*);
}

test "artillery panel: narrow Enter with a formation opens arty_detail modal" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    const ok = try buyTestFormation(c);
    try std.testing.expect(ok);
    const al = c.app.frame.allocator();
    const rows = try q.artilleryFormationRows(al, c.app.state());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try c.app.screen.resize(79, 24);
    try toTab(c, .forces);
    try navToArty(c);
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .arty_detail);
    try std.testing.expectEqual(rows[0].id, c.app.modal.arty_detail);
    // The detail lines are populated (not empty)
    const detail = try q.artilleryDetailLines(al, c.app.state(), rows[0].id);
    try std.testing.expect(detail.len > 0);
    // Scroll down inside the detail modal: read_only retains the modal, scroll advances the cursor
    try app.pressForTest(c, .down);
    try std.testing.expect(c.app.modal == .arty_detail);
    try std.testing.expect(c.app.modal_cursor > 0);
    // End key also scrolls without closing
    try app.pressForTest(c, .end);
    try std.testing.expect(c.app.modal == .arty_detail);
}

test "artillery panel: narrow Enter with no formations is a no-op" {
    // When there are no formations Enter must not crash and must leave modal == .none.
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try c.app.screen.resize(79, 24);
    try toTab(c, .forces);
    try navToArty(c);
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .none);
}

test "arty_detail modal is wired into drawList and listKey dispatch" {
    // Compile-time coverage: arty_detail must appear in both dispatch lists so
    // that drawing and key-handling work once a formation is selected.
    // The compile error from adding arty_detail to Modal without updating the
    // dispatch lists in app.zig would surface here as a build failure.
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    c.app.modal = .{ .arty_detail = @enumFromInt(1) };
    try app.pressForTest(c, .escape);
    try std.testing.expect(c.app.modal == .none);
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
