//! The Market screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Tab = app.Tab;
const game = app.game;
const layout = app.layout;
const q = app.q;
const types = app.types;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const view = try q.market(al, g, self.market_filter, @enumFromInt(self.hqSelId(g)));
    const top_h: u16 = @max(6, layout.minor.of(b.h));
    const hq_id: types.HqId = @enumFromInt(self.hqSelId(g));
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = b.w, .h = top_h }, .{ .title = try std.fmt.allocPrint(al, "MARKET BOARD · {{a}}{s}{{/}} pays from its treasury ({s}) · filter {{a}}{s}{{/}} · {d} listings", .{ try q.hqName(self.a(), g, hq_id), try q.money(al, q.balance(g, .{ .hq = hq_id })), @tagName(self.market_filter), view.board.len }), .focused = self.focus == 0, .right_title = "[ ] other HQ  [/] filter  [Enter] buy" });
    try self.tableOrNote(inner, try q.tableOf(al, q.market_cols, view.board), 0, self.focus == 0, "{d}nothing on the boards — they refresh on the 1st, staples restock as they sell{/}");

    const cw: u16 = if (self.narrow()) b.w else layout.list.of(b.w);
    const inner2 = self.screen.pane(.{ .x = b.x, .y = b.y + top_h, .w = cw, .h = b.h - top_h }, .{ .title = try std.fmt.allocPrint(al, "ORDER CATALOG · delivered to {s}", .{try q.hqName(self.a(), g, hq_id)}), .focused = self.focus == 1, .right_title = "[Enter] order  [b] fabricate" });
    try self.tableOrNote(inner2, try q.tableOf(al, q.catalog_cols, view.catalog), 1, self.focus == 1, "{d}nothing in the catalog under this filter{/}");
    if (cw < b.w) {
        const dem_h: u16 = layout.list.of(b.h - top_h);
        const inner3 = self.screen.pane(.{ .x = b.x + cw, .y = b.y + top_h, .w = b.w - cw, .h = dem_h }, .{ .title = "DEMAND · damaged slots", .focused = self.focus == 2, .right_title = "[Enter] order shortfall" });
        try self.tableOrNote(inner3, try q.tableOf(al, q.demand_cols, view.demand), 2, self.focus == 2, "{g}nothing damaged{/}");
        const pol = try q.stockPolicies(al, g, hq_id);
        const inner4 = self.screen.pane(.{ .x = b.x + cw, .y = b.y + top_h + dem_h, .w = b.w - cw, .h = b.h - top_h - dem_h }, .{ .title = try std.fmt.allocPrint(al, "KEEP STOCKED · {s} · checked daily", .{try q.hqName(self.a(), g, hq_id)}), .focused = self.focus == 3, .right_title = "[Enter] edit  [x] remove" });
        try self.tableOrNote(inner4, try q.tableOf(al, q.stock_policy_cols, pol), 3, self.focus == 3, "{d}none — K on a catalogue row keeps that part stocked here{/}");
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.market(al, g, self.market_filter, @enumFromInt(self.hqSelId(g)));
        switch (self.focus) {
            0 => self.moveCursor(0, delta, view.board.len),
            1 => self.moveCursor(1, delta, view.catalog.len),
            2 => self.moveCursor(2, delta, view.demand.len),
            else => self.moveCursor(3, delta, (try q.stockPolicies(al, g, @enumFromInt(self.hqSelId(g)))).len),
        }

}

pub fn enter(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.market(al, g, self.market_filter, @enumFromInt(self.hqSelId(g)));
        const hq_id: types.HqId = @enumFromInt(self.hqSelId(g));
        switch (self.focus) {
            0 => if (view.board.len > 0) {
                const l = view.board[@min(self.cur(0).*, view.board.len - 1)];
                if (l.transport) {
                    _ = try self.execSay(.{ .buy_listing = l.index }, .good, "bought listing [{d}] — berthed at {s}; hire a ship crew from the hall and it lifts the next deployment", .{ l.index, try q.hqName(self.a(), g, hq_id) });
                } else {
                    _ = try self.execSay(.{ .buy_listing = l.index }, .good, "bought listing [{d}]", .{l.index});
                }
            },
            1 => if (view.catalog.len > 0) {
                const r = view.catalog[@min(self.cur(1).*, view.catalog.len - 1)];
                var buf: [96]u8 = undefined;
                self.openCommand(std.fmt.bufPrint(&buf, "order {s} 1 hq:{d}", .{ r.key, @intFromEnum(hq_id) }) catch "order ");
            },
            3 => {
                const pol = try q.stockPolicies(al, g, hq_id);
                if (pol.len == 0) return;
                const r = pol[@min(self.cur(3).*, pol.len - 1)];
                var buf: [96]u8 = undefined;
                self.openCommand(std.fmt.bufPrint(&buf, "stockpolicy hq:{d} {s} {d} {d}", .{ @intFromEnum(hq_id), r.key, r.min, r.target }) catch "stockpolicy ");
            },
            else => if (view.demand.len > 0) {
                const d = view.demand[@min(self.cur(2).*, view.demand.len - 1)];
                if (d.short == 0) {
                    self.say(.dim, "{s}: nothing short — on hand or already on order", .{d.key});
                    return;
                }
                // Structural components are fabricated at a regional bay
                // (ARCH §9.8); everything else is an acquisition roll — the
                // command picks (`cover_shortfall`).
                const r = self.execResult(.{ .cover_shortfall = .{ .hq = hq_id, .part_key = d.key, .quantity = d.short } }) orelse return;
                if (r.fabricated) {
                    self.say(.good, "fabricating {d} × {s} at {s} — a bay job, see the HQ screen", .{ d.short, d.key, try q.hqName(self.a(), g, hq_id) });
                    return;
                }
                if (r.sourced) self.say(.good, "ordered {d} × {s} to {s}", .{ d.short, d.key, try q.hqName(self.a(), g, hq_id) }) else self.say(.amber, "logistics could not source {s} this time — retry after the monthly market refresh, or buy it off a board", .{d.key});
            },
        }

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    switch (ch) {
        '/' => {
            self.market_filter = self.market_filter.next();
            self.cur(0).* = 0;
            self.cur(1).* = 0;
        },
        ',' => {
            self.market_filter = self.market_filter.prev();
            self.cur(0).* = 0;
            self.cur(1).* = 0;
        },
        'b' => {
            const view = try q.market(al, g, self.market_filter, @enumFromInt(self.hqSelId(g)));
            if (self.focus == 1 and view.catalog.len > 0) {
                const r = view.catalog[@min(self.cur(1).*, view.catalog.len - 1)];
                if (!r.component) {
                    self.say(.amber, "only structural components (comp_*) are fabricated; order the rest", .{});
                    return;
                }
                self.openAmount(try std.fmt.allocPrint(al, "FABRICATE {s}", .{r.key}), .{ .fabricate = .{ .hq = self.hqSelId(g), .key = r.key } }, &.{
                    .{ .label = "quantity", .value = 1, .min = 1, .max = 20, .step = 1 },
                });
            } else self.say(.dim, "select a comp_* row in the catalog, then b", .{});
        },
        'x' => {
            if (self.focus != 3) {
                self.say(.dim, "Tab to KEEP STOCKED, then x removes the highlighted line", .{});
                return;
            }
            const hq_id: types.HqId = @enumFromInt(self.hqSelId(g));
            const pol = try q.stockPolicies(al, g, hq_id);
            if (pol.len == 0) return;
            const r = pol[@min(self.cur(3).*, pol.len - 1)];
            _ = try self.execSay(.{ .set_stock_policy = .{ .hq = hq_id, .part_key = r.key, .min = 0, .target = 0 } }, .good, "keep-stocked line for {s} removed", .{r.key});
        },
        'K' => {
            const view = try q.market(al, g, self.market_filter, @enumFromInt(self.hqSelId(g)));
            if (self.focus == 1 and view.catalog.len > 0) {
                const r = view.catalog[@min(self.cur(1).*, view.catalog.len - 1)];
                self.openAmount(try std.fmt.allocPrint(al, "KEEP {s} STOCKED", .{r.key}), .{ .stock_policy = .{ .hq = self.hqSelId(g), .key = r.key } }, &.{
                    .{ .label = "minimum", .value = 5, .min = 0, .max = 999, .step = 1 },
                    .{ .label = "target", .value = 10, .min = 0, .max = 999, .step = 1 },
                });
            } else self.say(.dim, "select a catalogue row (Tab), then K to keep it stocked at the HQ", .{});
        },
        ']', '[' => {
            const n = (try q.hqList(al, g)).len;
            if (n > 0) self.hq_sel = if (ch == ']') (self.hq_sel + 1) % n else (self.hq_sel + n - 1) % n;
        },
        else => {},
    }
}
