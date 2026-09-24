//! The Supply screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the Warehouse tab and parts acquisition (docs/mekhq-
//! map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Treasury = app.Treasury;
const game = app.game;
const layout = app.layout;
const q = app.q;
const types = app.types;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const view = try q.supply(al, g);
    const lw: u16 = if (self.narrow()) b.w else layout.list.of(b.w);
    self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, "SITES", view.rows, 0, true, true);
    if (lw < b.w) {
        const c = self.cur(0).*;
        const site: ?types.Site = if (c < view.site.len) view.site[c] else null;
        const top_h: u16 = b.h / 2;
        if (site) |s| {
            const table = try q.stockTable(al, g, s);
            self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = top_h }, try std.fmt.allocPrint(al, "STOCK · {s}", .{try q.siteLabel(al, g, s)}), table, 1, false, false);
        } else {
            const hint = [_][]const u8{"{d}move the cursor onto a site to see its stock{/}"};
            self.listPane(.{ .x = b.x + lw, .y = b.y, .w = b.w - lw, .h = top_h }, "STOCK", &hint, 1, false, false);
        }
        const inb = try q.inbound(al, g);
        const iinner = self.screen.pane(.{ .x = b.x + lw, .y = b.y + top_h, .w = b.w - lw, .h = b.h - top_h }, .{ .title = "INBOUND · soonest first" });
        try self.tableOrNote(iinner, try q.tableOf(al, q.inbound_cols, inb), 2, false, "{d}nothing on the way{/}");
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const view = try q.supply(al, g);
    self.moveCursor(0, delta, view.rows.len);
}

const Action = enum { order, ship, trim, parts_home, keep, send_cash, cash_back, cash_policy, resupply_policy, sell };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('o'), .action = .order, .label = "order", .group = .act, .help = "order a part delivered to the site under the cursor" },
    .{ .match = app.keys.Match.char('s'), .action = .ship, .label = "ship", .group = .act, .help = "ship parts from the home shelf (to the company under the cursor)" },
    .{ .match = app.keys.Match.char('R'), .action = .trim, .label = "trim to plan", .group = .act, .help = "return a company's stock over its field plan to the home HQ" },
    .{ .match = app.keys.Match.char('H'), .action = .parts_home, .label = "parts home", .group = .act, .help = "send every structural component in a company's field stores home" },
    .{ .match = app.keys.Match.char('K'), .action = .keep, .label = "keep stocked", .group = .act, .help = "keep a part stocked at the HQ under the cursor" },
    .{ .match = app.keys.Match.char('t'), .action = .send_cash, .label = "cash out", .group = .money, .help = "send outfit cash to the company or HQ under the cursor" },
    .{ .match = app.keys.Match.char('T'), .action = .cash_back, .label = "cash back", .group = .money, .help = "transfer the site's cash back to the outfit" },
    .{ .match = app.keys.Match.char('p'), .action = .cash_policy, .label = "cash policy", .group = .money, .help = "keep a company or HQ topped up from the outfit treasury" },
    .{ .match = app.keys.Match.char('P'), .action = .resupply_policy, .label = "resupply policy", .group = .money, .help = "set a company's automatic resupply policy" },
    .{ .match = app.keys.Match.char('$'), .action = .sell, .label = "sell stock", .group = .money },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = &self.gs.?;
    const site = try self.supplySite();
    var buf: [128]u8 = undefined;
    switch (hit.action) {
        .order => {
            self.openModal(.{ .pick_part = .{ .purpose = .order, .site = site orelse q.defaultSite(g) } });
        },
        .ship => {
            // Ship from the home shelf: a company row means its home HQ's stores.
            const from: types.Site = if (site) |s| switch (s) {
                .company => |id| .{ .hq = @enumFromInt(self.homeHqOf(id)) },
                else => s,
            } else q.defaultSite(g);
            self.openModal(.{ .pick_part = .{ .purpose = .ship, .site = from, .ship_to = if (site) |s2| (if (s2 == .company) s2.company else null) else null } });
        },
        .send_cash => {
            const s2 = site orelse {
                self.say(.dim, "put the cursor on a company or HQ row to send it cash", .{});
                return true;
            };
            const to: Treasury = switch (s2) {
                .company => |id| .{ .company = id },
                .hq => |id| .{ .hq = id },
                .outfit => {
                    self.say(.dim, "put the cursor on a company or HQ row to send it cash", .{});
                    return true;
                },
            };
            self.openAmount(try std.fmt.allocPrint(al, "SEND CASH TO {s}", .{try q.treasuryLabel(al, g, to)}), .{ .transfer_to = to }, &.{
                .{ .label = "c-bills", .value = if (s2 == .company) 250_000 else 500_000, .min = 1, .max = @max(1, (try q.status(al, g)).funds_cbills), .step = 50_000 },
            });
        },
        .cash_policy => {
            const s2 = site orelse {
                self.say(.dim, "put the cursor on a company or HQ row to set its cash policy", .{});
                return true;
            };
            const t: Treasury = switch (s2) {
                .company => |id| .{ .company = id },
                .hq => |id| .{ .hq = id },
                .outfit => {
                    self.say(.dim, "policies top up companies and HQs from the outfit treasury", .{});
                    return true;
                },
            };
            const existing = q.policyFor(g, t);
            self.openAmount(try std.fmt.allocPrint(al, "CASH POLICY · {s}", .{try q.treasuryLabel(al, g, t)}), .{ .policy = t }, &.{
                .{ .label = "keep above", .value = if (existing) |p| p.floor else if (s2 == .company) 250_000 else 500_000, .min = 0, .max = 100_000_000, .step = 50_000 },
                .{ .label = "cap per month", .value = if (existing) |p| p.monthly_cap else if (s2 == .company) 500_000 else 1_000_000, .min = 0, .max = 100_000_000, .step = 50_000 },
            });
        },
        .resupply_policy => {
            const co: types.ForceId = if (site) |s2| (if (s2 == .company) s2.company else .none) else .none;
            if (co == .none) {
                self.say(.dim, "resupply policies belong to a company — put the cursor on its field stores", .{});
                return true;
            }
            var days: i64 = 14;
            var tons: i64 = 0;
            var battles: i64 = 0;
            if (q.supplyPolicyFor(g, co)) |sp| {
                days = sp.min_days;
                tons = sp.tons;
                battles = sp.ammo_battles;
            }
            self.openAmount(try std.fmt.allocPrint(al, "RESUPPLY POLICY · {s}", .{try q.forceName(self.a(), g, co)}), .{ .supply_policy = co }, &.{
                .{ .label = "safety days (0 clears)", .value = days, .min = 0, .max = 365, .step = 7 },
                .{ .label = "max tons (0 = auto)", .value = tons, .min = 0, .max = 9_999, .step = 10 },
                .{ .label = "ammo battles", .value = battles, .min = 0, .max = 20, .step = 1 },
            });
        },
        .keep => {
            self.openModal(.{ .pick_part = .{ .purpose = .keep, .site = if (site) |s| (if (s == .hq) s else q.defaultSite(g)) else q.defaultSite(g) } });
        },
        .sell => {
            self.openModal(.{ .pick_part = .{ .purpose = .sell, .site = if (site) |s| (if (s == .hq) s else q.defaultSite(g)) else q.defaultSite(g) } });
        },
        .trim => {
            const co: types.ForceId = if (site) |s| (if (s == .company) s.company else .none) else .none;
            if (co == .none) {
                self.say(.dim, "move the cursor onto a company's field stores", .{});
                return true;
            }
            const r = self.execResult(.{ .trim_stock = co }) orelse return true;
            if (r.tons_moved == 0) {
                self.say(.dim, "{s}'s stores already match the field plan", .{try q.forceName(self.a(), g, co)});
            } else {
                self.say(.good, "{s} returns {d}t over the plan to the home HQ — riding the empty convoys, no freight", .{ try q.forceName(self.a(), g, co), r.tons_moved });
            }
        },
        .parts_home => {
            // Send every structural component in the field stores home.
            const co: types.ForceId = if (site) |s| (if (s == .company) s.company else .none) else .none;
            if (co == .none) {
                self.say(.dim, "move the cursor onto a company's field stores", .{});
                return true;
            }
            const res = self.execResultWith(.{ .ship_components_home = co }, &.{
                .{ .err = error.NothingToShip, .style = .dim, .text = try std.fmt.allocPrint(self.a(), "no structural components in {s}'s field stores", .{try q.forceName(self.a(), g, co)}) },
            }) orelse return true;
            self.say(.good, "{d} component{s} shipped from {s} to {s} (freight from local funds)", .{ res.count, if (res.count == 1) "" else "s", try q.forceName(self.a(), g, co), try q.hqName(self.a(), g, res.hq) });
        },
        .cash_back => self.openCommand(if (site) |s| switch (s) {
            .company => |id| std.fmt.bufPrint(&buf, "transfer co:{d} outfit {d}", .{ @intFromEnum(id), @max(0, @divTrunc(q.balance(g, .{ .company = id }), 2)) }) catch "transfer ",
            .hq => |id| std.fmt.bufPrint(&buf, "transfer hq:{d} outfit {d}", .{ @intFromEnum(id), @max(0, @divTrunc(q.balance(g, .{ .hq = id }), 2)) }) catch "transfer ",
            .outfit => "transfer ",
        } else "transfer "),
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the supply bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "o opens the part picker for an order" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .supply);
    try app.pressForTest(c, .{ .char = 'o' });
    try std.testing.expect(c.app.modal == .pick_part);
}
