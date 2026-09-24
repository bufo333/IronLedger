//! The Ledger screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

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
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = tw, .h = b.h }, .{ .title = "TREASURIES", .focused = self.focus == 0, .right_title = "[t] transfer [p] policy" });
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

pub fn enter(self: *App) anyerror!void {
        self.cmd_prefill.set("transfer outfit ");
        self.input.set(self.cmd_prefill.slice());
        self.cmd_prefill.len = 0;
        self.modal = .{ .input = .command };

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    switch (ch) {
        't', 'T', 'p' => {
            const all = try q.allTreasuries(al, g);
            const sel: Treasury = if (self.ledger_sel < all.len) all[self.ledger_sel] else .outfit;
            const label = try q.treasuryLabel(al, g, sel);
            if (sel == .outfit) {
                self.say(.dim, "select the HQ or company row first — cash moves between it and the outfit treasury", .{});
                return;
            }
            if (ch == 't') {
                self.openAmount(try std.fmt.allocPrint(al, "SEND CASH TO {s}", .{label}), .{ .transfer_to = sel }, &.{
                    .{ .label = "c-bills", .value = 250_000, .min = 1, .max = @max(1, (try q.status(al, g)).funds_cbills), .step = 50_000 },
                });
            } else if (ch == 'T') {
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
        'x' => {
            const all = try q.allTreasuries(al, g);
            const sel: Treasury = if (self.ledger_sel < all.len) all[self.ledger_sel] else .outfit;
            if (sel == .outfit) {
                self.say(.dim, "select the HQ or company row whose policy you want cleared", .{});
                return;
            }
            const label = try q.treasuryLabel(al, g, sel);
            if (q.policyFor(g, sel) != null) {
                _ = try self.execSay(.{ .set_policy = .{ .entity = sel, .floor = 0, .monthly_cap = 0 } }, .good, "cash top-up policy for {s} cleared", .{label});
                return;
            }
            if (sel == .company and q.supplyPolicyFor(g, sel.company) != null) {
                _ = try self.execSay(.{ .set_supply_policy = .{ .company = sel.company, .min_days = 0, .tons = 0 } }, .good, "resupply policy for {s} cleared", .{label});
                return;
            }
            self.say(.dim, "{s} has no standing policy", .{label});
        },
        'L' => self.openAmount("TAKE A LOAN (simple interest)", .loan, &.{
            .{ .label = "principal", .value = @min(q.creditRemaining(g), 1_000_000), .min = 1, .max = @max(1, q.creditRemaining(g)), .step = 100_000 },
            .{ .label = "months", .value = 12, .min = 1, .max = 60, .step = 6 },
        }),
        'R' => {
            const bal = q.oldestLoanBalance(g) orelse {
                self.say(.dim, "no loans to repay", .{});
                return;
            };
            self.openAmount("REPAY THE OLDEST LOAN", .{ .repay = 0 }, &.{
                .{ .label = "c-bills", .value = @min(bal, @max(0, (try q.status(al, g)).funds_cbills)), .min = 1, .max = @max(1, bal), .step = 50_000 },
            });
        },
        else => {},
    }
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "L opens the loan form" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .ledger);
    try app.pressForTest(c, .{ .char = 'L' });
    try std.testing.expect(c.app.modal == .amount);
}
