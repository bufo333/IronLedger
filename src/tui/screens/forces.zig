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
    .{ .match = .{ .key = .enter }, .action = .assign, .label = "assign", .group = .act, .pane = 0, .help = "assign people to the hull under the cursor (narrow: its detail); artillery: seat crew (narrow: its detail)" },
    .{ .match = app.keys.Match.char('a'), .action = .seat, .label = "seat", .group = .act, .help = "seat a pilot, crew or tech on the hull under the cursor; artillery: seat crew" },
    .{ .match = app.keys.Match.char('u'), .action = .unassign, .label = "unassign", .group = .act, .help = "clear a seat or the tech on the hull under the cursor; artillery: clear a seat or the mechanic" },
    .{ .match = app.keys.Match.char('l'), .action = .lance, .label = "lance", .group = .act, .help = "move the hull under the cursor into a lance" },
    .{ .match = app.keys.Match.char('x'), .action = .transfer, .label = "transfer", .group = .act, .help = "send the hull under the cursor to another company; artillery: send the carrier to a company" },
    .{ .match = app.keys.Match.char('c'), .action = .crew, .label = "crew", .group = .act, .help = "hire from the halls to fill the company's manning table; artillery: its company's" },
    .{ .match = app.keys.Match.char('A'), .action = .auto_assign, .label = "auto", .group = .act, .help = "auto-assign the company's people to its hulls; artillery: its company's" },
    .{ .match = app.keys.Match.char('t'), .action = .train_one, .label = "train one / all", .group = .act, .shown = "t / T", .help = "train one person (the command line); T enrolls the whole company" },
    .{ .match = app.keys.Match.char('T'), .action = .train_all, .label = "train all", .group = .act, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('o'), .action = .order, .label = "role (lance) / ROE (company)", .group = .act, .help = "cycle a lance's role, or a company's rules of engagement" },
    .{ .match = app.keys.Match.char('d'), .action = .depot, .label = "depot", .group = .act, .help = "queue the hull under the cursor for depot repair; artillery: as v" },
    .{ .match = app.keys.Match.char('R'), .action = .spares_recall, .label = "spares (hull) / recall (company)", .group = .act, .help = "on a hull: order spares for its broken gear; on a company: recall it home" },
    .{ .match = app.keys.Match.char('m'), .action = .mothball, .label = "mothball", .group = .act, .help = "mothball or reactivate the hull under the cursor" },
    .{ .match = app.keys.Match.char('w'), .action = .air_wing, .label = "air wing", .group = .act, .help = "raise an air wing for the company under the cursor" },
    .{ .match = app.keys.Match.char('+'), .action = .raise, .label = "raise", .group = .act, .help = "raise a new combat company" },
    .{ .match = app.keys.Match.char('='), .action = .raise, .label = "raise", .group = .act, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('$'), .action = .sell, .label = "sell", .group = .money, .help = "sell the hull under the cursor; artillery: as p" },
    .{ .match = app.keys.Match.char('X'), .action = .disband, .label = "disband", .group = .money, .help = "disband the company under the cursor" },
    .{ .match = app.keys.Match.char('b'), .action = .fabricate, .label = "fabricate", .group = .money, .help = "fabricate the structural parts the company's home HQ lacks" },
    .{ .match = app.keys.Match.char('h'), .action = .mech, .label = "mech record", .group = .act, .help = "open the hull's lifecycle: combat history, maintenance log and ownership chain (artillery too)" },
    // Artillery panel keys (active on the artillery view)
    .{ .match = app.keys.Match.char('e'), .action = .arty_attach, .label = "attach / detach", .group = .act, .help = "pooled: pick a company to attach to at home or send to in the field; attached: detach at home (artillery panel)" },
    .{ .match = app.keys.Match.char('f'), .action = .arty_seat, .label = "seat crew", .group = .act, .help = "pick crew for an empty artillery seat (artillery panel)" },
    .{ .match = app.keys.Match.char('g'), .action = .arty_tech, .label = "assign tech", .group = .act, .help = "pick the artillery mechanic (artillery panel)" },
    .{ .match = app.keys.Match.char('i'), .action = .arty_reload, .label = "reload", .group = .act, .help = "reload artillery magazines (artillery panel)" },
    .{ .match = app.keys.Match.char('v'), .action = .arty_repair, .label = "repair", .group = .act, .help = "queue an artillery depot repair (artillery panel)" },
    .{ .match = app.keys.Match.char('s'), .action = .arty_ship, .label = "ship to HQ", .group = .act, .help = "freight a pooled carrier to another HQ (artillery panel)" },
    .{ .match = app.keys.Match.char('p'), .action = .arty_sell, .label = "sell arty", .group = .money, .help = "sell the artillery carrier (artillery panel)" },
};

/// What the artillery panel says for a key that acts only on TO&E rows.
const toe_only_note = "that key acts on TO&E rows — here: Enter/a/f seat crew, u clear, g mechanic, e attach/detach, x send, s ship to an HQ, i reload, v repair, p sell, h record, A/c its company · [ ] back to the TO&E";

/// Step to the previous or next Forces view (the artillery panel is the last
/// of `views_len + 1`). The new view opens on its first row with its list
/// focused, so a pane focused in the old view never hides the new cursor.
fn stepView(self: *App, views_len: usize, forward: bool) void {
    self.forces_view = if (forward) (self.forces_view + 1) % (views_len + 1) else (self.forces_view + views_len) % (views_len + 1);
    self.cur(0).* = 0;
    self.focus = 0;
}

/// The formation under the panel's cursor, or null after saying none is.
fn selectedArtillery(self: *App, rows: []const q.ArtilleryFormationRow) ?q.ArtilleryFormationRow {
    const cur = self.cur(0).*;
    if (cur < rows.len) return rows[cur];
    self.say(.dim, "no artillery formation selected", .{});
    return null;
}

/// Raise a combat company at an HQ with a free slot (the selected one if it
/// has room); with none free, at the selected HQ, and `raise_company` says why.
fn openRaise(self: *App, g: *app.GameState) !void {
    const selected: app.types.HqId = @enumFromInt(try self.hqSelId(g));
    const pick = q.hqWithCompanySlot(g, selected);
    self.raise.hq = if (pick == .none) selected else pick;
    self.input.len = 0;
    self.modal = .{ .input = .raise_name };
}

fn autoAssignCompany(self: *App, g: *app.GameState, co: app.types.ForceId) !void {
    _ = try self.execSay(.{ .auto_assign = co }, .good, "auto-assigned {s}", .{try q.forceName(self.a(), g, co)});
}

fn crewCompany(self: *App, g: *app.GameState, co: app.types.ForceId) !void {
    const res = self.execResult(.{ .crew_company = co }) orelse return;
    self.say(if (res.still_open == 0) .good else .amber, "{s}: {d} hired to fill the manning table · {d} lines still open (no candidates on the boards yet)", .{ try q.forceName(self.a(), g, co), res.hired_count, res.still_open });
}
pub const legend = app.keys.entries(Action, &bindings);

/// The artillery panel: every Forces action either acts on the formation under
/// the cursor or says why it does not (docs/tui.md, F3 Forces).
fn handleArty(self: *App, action: Action, al: std.mem.Allocator, g: *app.GameState) anyerror!bool {
    const views = try q.toeViews(al, g);
    const arty_rows = try q.artilleryFormationRows(al, g);
    var buf: [64]u8 = undefined;
    switch (action) {
        .next_view => stepView(self, views.len, true),
        .prev_view => stepView(self, views.len, false),
        .raise => try openRaise(self, g),
        .cycle_pane, .lance, .train_one, .train_all, .order, .spares_recall, .mothball, .air_wing, .disband, .fabricate => self.say(.dim, toe_only_note, .{}),
        .assign => if (selectedArtillery(self, arty_rows)) |r| {
            // Narrow terminals have no side pane: Enter opens the detail.
            if (self.narrow()) self.modal = .{ .arty_detail = r.id } else self.openModal(.{ .pick_arty_crew = r.id });
        },
        .seat, .arty_seat => if (selectedArtillery(self, arty_rows)) |r| self.openModal(.{ .pick_arty_crew = r.id }),
        .unassign => if (selectedArtillery(self, arty_rows)) |r| self.openModal(.{ .pick_arty_unassign = r.id }),
        .arty_tech => if (selectedArtillery(self, arty_rows)) |r| self.openModal(.{ .pick_arty_tech = r.id }),
        .transfer => if (selectedArtillery(self, arty_rows)) |r| self.openModal(.{ .pick_arty_send = r.id }),
        .arty_attach => if (selectedArtillery(self, arty_rows)) |r| {
            if (r.placement == .hq_pool) self.openModal(.{ .pick_arty_send = r.id }) else try self.execReport(.{ .detach_artillery = r.id });
        },
        .arty_repair, .depot => if (selectedArtillery(self, arty_rows)) |r| try self.execReport(.{ .repair_artillery = r.id }),
        .arty_ship => if (selectedArtillery(self, arty_rows)) |r| {
            self.input.set(std.fmt.bufPrint(&buf, "shiparty {d} hq:", .{@intFromEnum(r.id)}) catch "shiparty ");
            self.modal = .{ .input = .command };
        },
        .arty_reload => if (selectedArtillery(self, arty_rows)) |r| {
            self.input.set(std.fmt.bufPrint(&buf, "reloadarty {d} ", .{@intFromEnum(r.id)}) catch "reloadarty ");
            self.modal = .{ .input = .command };
        },
        .arty_sell, .sell => if (selectedArtillery(self, arty_rows)) |r| {
            self.input.set(std.fmt.bufPrint(&buf, "sellarty {d}", .{@intFromEnum(r.id)}) catch "sellarty ");
            self.modal = .{ .input = .command };
        },
        .mech => if (selectedArtillery(self, arty_rows)) |r| self.openModal(.{ .mech = .{ .id = r.hull } }),
        .auto_assign => if (selectedArtillery(self, arty_rows)) |r| {
            if (r.company == .none) self.say(.dim, "the carrier is not attached — A acts on its company once it is", .{}) else try autoAssignCompany(self, g, r.company);
        },
        .crew => if (selectedArtillery(self, arty_rows)) |r| {
            if (r.company == .none) self.say(.dim, "the carrier is not attached — c hires for its company once it is", .{}) else try crewCompany(self, g, r.company);
        },
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
            if (r.company != .none) try autoAssignCompany(self, g, r.company);
        },
        .crew => if (row) |r| {
            if (r.company != .none) try crewCompany(self, g, r.company);
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
        .raise => try openRaise(self, g),
        .next_view => stepView(self, (try q.toeViews(al, g)).len, true),
        .prev_view => stepView(self, (try q.toeViews(al, g)).len, false),
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
        .arty_attach, .arty_seat, .arty_tech, .arty_reload, .arty_repair, .arty_ship, .arty_sell => self.say(.dim, "that key acts on the artillery panel — [ from all forces reaches it", .{}),
    }
    return true;
}

fn screenHasText(screen: *const app.Screen, needle: []const u8) bool {
    if (needle.len == 0) return false;
    for (0..screen.rows) |y| {
        if (screen.cols < needle.len) continue;
        for (0..screen.cols - needle.len) |x| {
            var matched = true;
            for (needle, 0..) |ch, i| {
                if (screen.get(@intCast(x + i), @intCast(y)).ch != ch) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
    }
    return false;
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
    // 'e' (arty_attach) on a pooled carrier opens the send picker for it
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expectEqual(bought_id, c.app.modal.pick_arty_send);
    try app.pressForTest(c, .escape);
    // 'f' (arty_seat) opens the crew picker
    try app.pressForTest(c, .{ .char = 'f' });
    try std.testing.expectEqual(bought_id, c.app.modal.pick_arty_crew);
    try app.pressForTest(c, .escape);
    // 'g' (arty_tech) opens the mechanic picker
    try app.pressForTest(c, .{ .char = 'g' });
    try std.testing.expectEqual(bought_id, c.app.modal.pick_arty_tech);
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
    // 'e' then Enter on the home company's row attaches the carrier to it
    try app.pressForTest(c, .{ .char = 'e' });
    const send_rows = try q.artilleryCompanyChoices(c.app.frame.allocator(), c.app.state(), bought_id);
    try std.testing.expect(send_rows.len > 0 and send_rows[0].eligible and send_rows[0].artillery_send.? == .attach);
    const home_company = send_rows[0].sel.company;
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "attached") != null);
    try std.testing.expectEqual(home_company, c.app.state().artillery_formations.get(bought_id).?.placement.company);
    // 'e' while attached detaches at home and says so
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "detached") != null);
    // 'v' (arty_repair) executes directly: no qualified local mechanic assigned, modal stays .none
    const hash_before_repair = game.digest.stateHash(c.app.state());
    try app.pressForTest(c, .{ .char = 'v' });
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "qualified local mechanic") != null);
    try std.testing.expectEqual(hash_before_repair, game.digest.stateHash(c.app.state()));
    // Wide viewport for scroll test: 120×24 → body.h=21, inner.h=19 (< 21 detail lines).
    try c.app.screen.resize(120, 24);
    // Tab focuses detail pane (pane 1) on wide terminal
    try app.pressForTest(c, .tab);
    try std.testing.expectEqual(@as(u8, 1), c.app.focus);
    // j/k on detail pane moves cur(1)
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(usize, 1), c.app.cur(1).*);
    // Fetch detail lines with a durable allocator (frame arena is reset by each pressForTest).
    var det_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer det_arena.deinit();
    const detail_lines = try q.artilleryDetailLines(det_arena.allocator(), c.app.state(), bought_id);
    try std.testing.expect(detail_lines.len > 0);
    // Initial viewport (cur=1, inner.h=19) does not show the last detail line.
    const last_detail = detail_lines[detail_lines.len - 1];
    const last_snippet = if (last_detail.len > 8) last_detail[0..8] else last_detail;
    try std.testing.expect(!screenHasText(&c.app.screen, last_snippet));
    // Scroll past the end; cursor clamps at detail_lines.len - 1.
    for (0..detail_lines.len + 5) |_| try app.pressForTest(c, .down);
    try std.testing.expectEqual(detail_lines.len - 1, c.app.cur(1).*);
    // After scrolling to the last line, it is rendered on screen.
    try std.testing.expect(screenHasText(&c.app.screen, last_snippet));
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
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expectEqual(id0, c.app.modal.pick_arty_send);
    try app.pressForTest(c, .escape);
    // Rendered selection agrees with activated identity: detail pane shows id0's formation.
    var id_buf: [32]u8 = undefined;
    try std.testing.expect(screenHasText(&c.app.screen, std.fmt.bufPrint(&id_buf, "Artillery #{d}", .{@intFromEnum(id0)}) catch ""));
    // Down moves to row 1
    try app.pressForTest(c, .down);
    try std.testing.expectEqual(@as(usize, 1), c.app.cur(0).*);
    try app.pressForTest(c, .{ .char = 'e' });
    try std.testing.expectEqual(id1, c.app.modal.pick_arty_send);
    try app.pressForTest(c, .escape);
    // Rendered selection agrees with activated identity: detail pane shows id1's formation.
    try std.testing.expect(screenHasText(&c.app.screen, std.fmt.bufPrint(&id_buf, "Artillery #{d}", .{@intFromEnum(id1)}) catch ""));
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
    try c.app.screen.resize(80, 24); // narrow (<120 cols) and at the minimum renderable size
    try toTab(c, .forces);
    try navToArty(c);
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .arty_detail);
    // Capture the formation ID from the modal (rows is freed by pressForTest frame reset).
    const modal_fid = c.app.modal.arty_detail;
    // Fetch detail lines from a durable allocator (al is a frame arena reset by pressForTest).
    var det_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer det_arena.deinit();
    const detail = try q.artilleryDetailLines(det_arena.allocator(), c.app.state(), modal_fid);
    try std.testing.expect(detail.len > 0);
    // Scroll down inside the detail modal: read_only retains the modal, scroll advances the cursor
    try app.pressForTest(c, .down);
    try std.testing.expect(c.app.modal == .arty_detail);
    try std.testing.expect(c.app.modal_cursor > 0);
    // End key also scrolls without closing
    try app.pressForTest(c, .end);
    try std.testing.expect(c.app.modal == .arty_detail);
    // After End the viewport scrolls to show the last detail lines; verify the bottom line is rendered.
    const last = detail[detail.len - 1];
    try std.testing.expect(screenHasText(&c.app.screen, if (last.len > 8) last[0..8] else last));
}

test "artillery panel: arty_repair key with repairable formation shows success feedback" {
    // Exercises the success path of handleArty(.arty_repair) — the 'v' key path
    // at forces.zig:213–221 that calls execResult(.repair_artillery) and shows resultText.
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    const ok = try buyTestFormation(c);
    try std.testing.expect(ok);
    const al = c.app.frame.allocator();
    const rows = try q.artilleryFormationRows(al, c.app.state());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    const fid = rows[0].id;
    const hq_rows = try q.hqList(al, c.app.state());
    const hq_id = hq_rows[0].id;
    // Hire a tech mechanic and assign them to the formation.
    const hire_res = c.app.execResult(.{ .hire = .{ .first = "Local", .last = "Mechanic", .role = .tech_mechanic } });
    try std.testing.expect(hire_res != null);
    const tech_id = hire_res.?.hired;
    try std.testing.expect(tech_id != .none);
    try std.testing.expect(try c.app.exec(.{ .assign_artillery_tech = .{ .formation = fid, .person = tech_id } }));
    try game.artillery_service.prepareRepairableForTest(c.app.state(), fid, hq_id);
    // Navigate to the artillery panel.
    try toTab(c, .forces);
    try navToArty(c);
    // Press 'v': repair command succeeds; modal stays .none and msg shows depot repair queued.
    try app.pressForTest(c, .{ .char = 'v' });
    try std.testing.expect(c.app.modal == .none);
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const expected_msg = try q.resultText(result_arena.allocator(), c.app.state(), .{ .repair_artillery = fid }, game.commands.Result{ .artillery_formation = fid, .artillery_site = .{ .hq = hq_id } });
    try std.testing.expectEqualStrings(expected_msg, c.app.msg.slice());
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

/// Whether the last key visibly did something: a modal, the campaign, the
/// view or the status line changed.
fn keyActed(c: *app.ClientForTest, view: usize, digest_before: u64) bool {
    return c.app.modal != .none or c.app.msg.len > 0 or c.app.forces_view != view or digest_before != game.digest.stateHash(c.app.state());
}

test "every Forces key acts or explains itself on the artillery panel, and artillery keys explain themselves on the TO&E" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try std.testing.expect(try buyTestFormation(c));
    try toTab(c, .forces);
    var ignored: usize = 0;
    // Wide (two panes) and the narrow minimum, with one pooled carrier.
    for ([_][2]u16{ .{ 200, 50 }, .{ 80, 24 } }) |size| {
        try c.app.screen.resize(size[0], size[1]);
        for (bindings) |b| {
            try navToArty(c);
            c.app.focus = 0;
            c.app.modal = .none;
            c.app.msg.len = 0;
            const view = c.app.forces_view;
            const before = game.digest.stateHash(c.app.state());
            try app.pressForTest(c, b.match.key);
            if (!keyActed(c, view, before)) {
                std.debug.print("artillery panel ignores '{s}' ({s}) at {d}x{d}\n", .{ b.shown orelse b.label, @tagName(b.action), size[0], size[1] });
                ignored += 1;
            }
            c.app.modal = .none;
        }
        // On a TO&E view the artillery-panel keys say where they work.
        for (bindings) |b| {
            if (!std.mem.startsWith(u8, @tagName(b.action), "arty_")) continue;
            c.app.forces_view = 0;
            c.app.cur(0).* = 0;
            c.app.focus = 0;
            c.app.modal = .none;
            c.app.msg.len = 0;
            const before = game.digest.stateHash(c.app.state());
            try app.pressForTest(c, b.match.key);
            if (!keyActed(c, 0, before)) {
                std.debug.print("TO&E view ignores artillery key '{s}' ({s}) at {d}x{d}\n", .{ b.label, @tagName(b.action), size[0], size[1] });
                ignored += 1;
            }
            c.app.modal = .none;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), ignored);
}

/// The style of the first cell of `needle` on screen, or null when not shown.
fn screenTextStyle(screen: *const app.Screen, needle: []const u8) ?@TypeOf(screen.get(0, 0).style) {
    for (0..screen.rows) |y| {
        if (screen.cols < needle.len) continue;
        for (0..screen.cols - needle.len) |x| {
            var matched = true;
            for (needle, 0..) |ch, i| if (screen.get(@intCast(x + i), @intCast(y)).ch != ch) {
                matched = false;
                break;
            };
            if (matched) return screen.get(@intCast(x), @intCast(y)).style;
        }
    }
    return null;
}

test "switching Forces views focuses the list, so the artillery panel opens with its cursor on the carrier" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try std.testing.expect(try buyTestFormation(c));
    try toTab(c, .forces);
    c.app.forces_view = 0;
    try app.pressForTest(c, .tab);
    try std.testing.expectEqual(@as(u8, 1), c.app.focus);
    try app.pressForTest(c, .{ .char = '[' });
    try std.testing.expectEqual(@as(u8, 0), c.app.focus);
    try std.testing.expect(screenTextStyle(&c.app.screen, "#1  hull #").? == .sel);
    // And back to a TO&E view: the TO&E list has the focus.
    try app.pressForTest(c, .tab);
    try app.pressForTest(c, .{ .char = ']' });
    try std.testing.expectEqual(@as(u8, 0), c.app.focus);
}

test "artillery pickers act on the typed row under the cursor, and a dimmed row shows the owner's refusal" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try std.testing.expect(try buyTestFormation(c));
    const fid = (try q.artilleryFormationRows(c.app.frame.allocator(), c.app.state()))[0].id;
    const hired = c.app.execResult(.{ .hire = .{ .first = "Pool", .last = "Gunner", .role = .vehicle_crew } }).?.hired;
    try toTab(c, .forces);
    try navToArty(c);
    // Wide Enter: the crew picker; Enter seats the highlighted row's person in its seat.
    try app.pressForTest(c, .enter);
    try std.testing.expectEqual(fid, c.app.modal.pick_arty_crew);
    const top = (try q.artilleryCrewChoices(c.app.frame.allocator(), c.app.state(), fid))[0];
    try std.testing.expect(top.eligible);
    var hired_eligible = false;
    for (try q.artilleryCrewChoices(c.app.frame.allocator(), c.app.state(), fid)) |row| hired_eligible = hired_eligible or (row.sel.person == hired and row.eligible);
    try std.testing.expect(hired_eligible);
    try app.pressForTest(c, .enter);
    try std.testing.expect(c.app.modal == .none);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "seated") != null);
    try std.testing.expectEqual(top.sel.person, c.app.state().artillery_formations.get(fid).?.crew[@intFromEnum(top.artillery_seat.?)]);
    // u: the clear picker's row clears that seat.
    try app.pressForTest(c, .{ .char = 'u' });
    try std.testing.expectEqual(fid, c.app.modal.pick_arty_unassign);
    try app.pressForTest(c, .enter);
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "seat cleared") != null);
    try std.testing.expectEqual(game.types.PersonId.none, c.app.state().artillery_formations.get(fid).?.crew[@intFromEnum(top.artillery_seat.?)]);
    // A travelling company's row is dimmed; Enter still sends the command and
    // shows the canonical refusal, changing nothing.
    var co: game.types.ForceId = .none;
    for (try q.toeFiltered(c.app.frame.allocator(), c.app.state(), .all)) |r| if (r.is_company) {
        co = r.force;
    };
    try std.testing.expect(co != .none);
    c.app.state().forces.getPtr(co).?.return_eta_day = c.app.state().clock.day_index + 30;
    try app.pressForTest(c, .{ .char = 'x' });
    try std.testing.expectEqual(fid, c.app.modal.pick_arty_send);
    const rows = try q.artilleryCompanyChoices(c.app.frame.allocator(), c.app.state(), fid);
    const at = for (rows, 0..) |row, i| {
        if (row.sel.company == co) break i;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(!rows[at].eligible);
    c.app.modal_cursor = at;
    const before = game.digest.stateHash(c.app.state());
    try app.pressForTest(c, .enter);
    var want: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "refused: {s}", .{game.cli.errorText(error.ArtilleryCompanyTravelling)}), c.app.msg.slice());
    try std.testing.expectEqual(before, game.digest.stateHash(c.app.state()));
    // Narrow: the pickers draw at the minimum size.
    try c.app.screen.resize(80, 24);
    try app.pressForTest(c, .{ .char = 'f' });
    try std.testing.expectEqual(fid, c.app.modal.pick_arty_crew);
    try app.pressForTest(c, .escape);
    try app.pressForTest(c, .{ .char = 'g' });
    try std.testing.expectEqual(fid, c.app.modal.pick_arty_tech);
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
