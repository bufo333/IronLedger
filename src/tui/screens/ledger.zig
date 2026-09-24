//! The Ledger screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the Finances tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Treasury = app.Treasury;
const layout = app.layout;
const q = app.q;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const all = try q.allTreasuries(al, g);
    App.clampIdx(&self.ledger_sel, all.len);
    const view = try q.ledger(al, g, all[self.ledger_sel], 31, 200);
    const tw: u16 = if (self.narrow()) layout.minor.of(b.w) else @max(34, layout.quarter.of(b.w));
    const pw: u16 = if (self.narrow()) 0 else @max(30, layout.ledger_pnl.of(b.w));
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = tw, .h = b.h }, .{ .title = "TREASURIES", .focused = self.focus == 0, .right_title = try app.keys.paneTitle(al, &legend, 0) });
    // The treasuries as a table (the cursor is ledger_sel, not a pane cursor), the extras as lines under it.
    const t_h: u16 = @intCast(@min(view.treasuries.len + 1, inner.h));
    const tsc = self.colScroll(0);
    if (self.focus == 0) self.focus_scroll = 0;
    _ = try self.screen.table(al, .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = t_h }, try q.tableOf(al, q.treasury_cols, view.treasuries), 0, if (self.focus == 0) self.ledger_sel else null, tsc);
    if (inner.h > t_h + 1) self.screen.lines(.{ .x = inner.x, .y = inner.y + t_h + 1, .w = inner.w, .h = inner.h - t_h - 1 }, view.extras, 0, null);
    if (pw > 0) {
        const pinner = self.screen.pane(.{ .x = b.x + tw, .y = b.y, .w = pw, .h = b.h }, .{ .title = view.pnl_title });
        _ = try self.screen.table(al, pinner, .{ .cols = view.pnl_cols, .rows = view.pnl }, 0, null, self.colScroll(1));
    }
    const led_inner = self.screen.pane(.{ .x = b.x + tw + pw, .y = b.y, .w = b.w - tw - pw, .h = b.h }, .{ .title = "LEDGER", .focused = self.focus == 1 });
    try self.tableOrNote(led_inner, .{ .cols = q.ledger_cols, .rows = view.ledger }, 2, self.focus == 1, "{d}no transactions yet{/}");
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    if (self.focus == 0) {
        const all = try q.allTreasuries(al, g);
        const v: i32 = @as(i32, @intCast(self.ledger_sel)) + delta;
        self.ledger_sel = @intCast(@max(0, @min(@as(i32, @intCast(all.len)) - 1, v)));
    } else {
        const view = try q.ledger(al, g, .outfit, 31, 200);
        self.moveCursor(2, delta, view.ledger.len + 1);
    }
}

const Action = enum { transfer_command, loan, repay, send_cash, pull_back, policy, clear_policy };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = .{ .key = .enter }, .action = .transfer_command, .label = "transfer", .group = .money, .help = "open the command line with a transfer from the outfit treasury started" },
    .{ .match = app.keys.Match.char('L'), .action = .loan, .label = "loan", .group = .money, .help = "take a loan (simple interest)" },
    .{ .match = app.keys.Match.char('R'), .action = .repay, .label = "repay", .group = .money, .help = "repay the oldest loan" },
    .{ .match = app.keys.Match.char('t'), .action = .send_cash, .label = "send cash", .group = .money, .title = 0, .help = "send cash from the outfit to the HQ or company row selected" },
    .{ .match = app.keys.Match.char('T'), .action = .pull_back, .label = "pull cash back", .group = .money, .help = "pull cash back from the selected HQ or company to the outfit" },
    .{ .match = app.keys.Match.char('p'), .action = .policy, .label = "top-up policy", .group = .money, .title = 0, .help = "set the selected row's cash top-up policy (floor and monthly cap)" },
    .{ .match = app.keys.Match.char('x'), .action = .clear_policy, .label = "clear policy", .group = .money, .help = "clear the selected row's standing cash or resupply policy" },
};
pub const legend = app.keys.entries(Action, &bindings);

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = &self.gs.?;
    switch (hit.action) {
        .transfer_command => {
            self.cmd_prefill.set("transfer outfit ");
            self.input.set(self.cmd_prefill.slice());
            self.cmd_prefill.len = 0;
            self.modal = .{ .input = .command };
        },
        .send_cash, .pull_back, .policy => {
            const all = try q.allTreasuries(al, g);
            const sel: Treasury = if (self.ledger_sel < all.len) all[self.ledger_sel] else .outfit;
            const label = try q.treasuryLabel(al, g, sel);
            if (sel == .outfit) {
                self.say(.dim, "select the HQ or company row first — cash moves between it and the outfit treasury", .{});
                return true;
            }
            if (hit.action == .send_cash) {
                self.openAmount(try std.fmt.allocPrint(al, "SEND CASH TO {s}", .{label}), .{ .transfer_to = sel }, &.{
                    .{ .label = "c-bills", .value = 250_000, .min = 1, .max = @max(1, (try q.status(al, g)).funds_cbills), .step = 50_000 },
                });
            } else if (hit.action == .pull_back) {
                const bal = q.balance(g, sel);
                self.openAmount(try std.fmt.allocPrint(al, "PULL CASH BACK FROM {s}", .{label}), .{ .transfer_back = sel }, &.{
                    .{ .label = "c-bills", .value = @max(0, @divTrunc(bal, 2)), .min = 1, .max = @max(1, bal), .step = 50_000 },
                });
            } else {
                const existing = q.policyFor(g, sel);
                self.openAmount(try std.fmt.allocPrint(al, "CASH POLICY · {s}", .{label}), .{ .policy = sel }, &.{
                    .{ .label = "keep above", .value = if (existing) |p| p.floor else 250_000, .min = 0, .max = 100_000_000, .step = 50_000 },
                    .{ .label = "cap per month", .value = if (existing) |p| p.monthly_cap else 500_000, .min = 0, .max = 100_000_000, .step = 50_000 },
                });
            }
        },
        .clear_policy => {
            const all = try q.allTreasuries(al, g);
            const sel: Treasury = if (self.ledger_sel < all.len) all[self.ledger_sel] else .outfit;
            if (sel == .outfit) {
                self.say(.dim, "select the HQ or company row whose policy you want cleared", .{});
                return true;
            }
            const label = try q.treasuryLabel(al, g, sel);
            if (q.policyFor(g, sel) != null) {
                _ = try self.execSay(.{ .set_policy = .{ .entity = sel, .floor = 0, .monthly_cap = 0 } }, .good, "cash top-up policy for {s} cleared", .{label});
                return true;
            }
            if (sel == .company and q.supplyPolicyFor(g, sel.company) != null) {
                _ = try self.execSay(.{ .set_supply_policy = .{ .company = sel.company, .min_days = 0, .tons = 0 } }, .good, "resupply policy for {s} cleared", .{label});
                return true;
            }
            self.say(.dim, "{s} has no standing policy", .{label});
        },
        .loan => self.openAmount("TAKE A LOAN (simple interest)", .loan, &.{
            .{ .label = "principal", .value = @min(q.creditRemaining(g), 1_000_000), .min = 1, .max = @max(1, q.creditRemaining(g)), .step = 100_000 },
            .{ .label = "months", .value = 12, .min = 1, .max = 60, .step = 6 },
        }),
        .repay => {
            const bal = q.oldestLoanBalance(g) orelse {
                self.say(.dim, "no loans to repay", .{});
                return true;
            };
            self.openAmount("REPAY THE OLDEST LOAN", .{ .repay = 0 }, &.{
                .{ .label = "c-bills", .value = @min(bal, @max(0, (try q.status(al, g)).funds_cbills)), .min = 1, .max = @max(1, bal), .step = 50_000 },
            });
        },
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the ledger bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "L opens the loan form" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .ledger);
    try app.pressForTest(c, .{ .char = 'L' });
    try std.testing.expect(c.app.modal == .amount);
}
