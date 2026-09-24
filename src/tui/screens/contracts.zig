//! The Contracts screen (docs/coding-contract.md rule 18): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const Tab = app.Tab;
const layout = app.layout;
const q = app.q;
const screen_mod = app.screen_mod;
const types = app.types;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
    const b = self.body();
    const view = try q.contracts(al, g, @enumFromInt(self.hqSelId(g)));
    // Room for the offers and the candidates under the cursor's offer,
    // up to three fifths of the screen.
    const c = self.cur(0);
    if (view.board.len > 0 and c.* >= view.board.len) c.* = view.board.len - 1;
    const cands = if (view.board.len > 0) try q.offerCandidates(al, g, view.board[c.*].index) else &[_]q.Candidate{};
    const board_need: u16 = @intCast(@min(1 + view.board.len + 3 + 1 + cands.len + 2, 200));
    const board_h: u16 = @max(6, @min(board_need, layout.major.of(b.h)));
    const board_hq: types.HqId = @enumFromInt(self.hqSelId(g));
    const inner = self.screen.pane(.{ .x = b.x, .y = b.y, .w = b.w, .h = board_h }, .{ .title = try std.fmt.allocPrint(al, "CONTRACT BOARD · {{a}}{s}{{/}} · for the companies based there", .{try q.hqName(self.a(), g, board_hq)}), .focused = self.focus == 0, .right_title = "[ ] other HQ  [←/→] columns  [Enter] accept" });
    if (view.board.len == 0) {
        self.screen.lines(inner, &.{"{d}no offers — the board refreshes on the 1st{/}"}, 0, null);
    } else {
        // The offers on top; under them, who could take the one under the
        // cursor, readiest first.
        const board_rows: u16 = @intCast(@min(view.board.len + 1, inner.h));
        try self.tablePane(.{ .x = inner.x, .y = inner.y, .w = inner.w, .h = board_rows }, try view.boardTable(al), 0, self.focus == 0);
        if (inner.h > board_rows + 2) {
            const y = inner.y + board_rows;
            self.screen.textPad(inner.x, y + 1, inner.w, "{a}companies for the selected offer{/}", .normal);
            _ = try self.screen.table(al, .{ .x = inner.x, .y = y + 2, .w = inner.w, .h = inner.h - board_rows - 2 }, try q.tableOf(al, q.candidates_cols, cands), 0, null, self.colScroll(3));
        }
    }

    // The board's notes (rating, band and rights terms), wrapped in a
    // box of their own under the board; up to three lines, fewer when
    // the screen is short.
    const notes = try screen_mod.wrap(al, view.notes, b.w -| 4);
    const notes_room: usize = if (b.h > board_h + 10) @min(3, b.h - board_h - 10) else 0;
    const notes_n: u16 = @intCast(@min(notes.len, notes_room));
    const notes_h: u16 = if (notes_n > 0) notes_n + 2 else 0;
    if (notes_h > 0) {
        const notes_inner = self.screen.pane(.{ .x = b.x, .y = b.y + board_h, .w = b.w, .h = notes_h }, .{ .title = "NOTES" });
        self.screen.lines(notes_inner, notes, 0, null);
    }
    const top_h: u16 = board_h + notes_h;

    var act: std.ArrayListUnmanaged([]const u8) = .empty;
    var act_index: std.ArrayListUnmanaged(usize) = .empty;
    for (view.active, 0..) |ar, i| {
        for (ar.lines) |l| {
            try act.append(al, l);
            try act_index.append(al, i);
        }
    }
    if (view.active.len == 0) try act.append(al, "{d}no active contracts{/}");
    const wide = layout.extraWide(b.w);
    const act_w: u16 = if (wide) layout.major.of(b.w) else b.w;
    const history = try q.contractHistory(al, g);
    const c2 = self.cur(2);
    if (history.len > 0 and c2.* >= history.len) c2.* = history.len - 1;
    // Narrow: the active list gives up its lower part to the history.
    const act_h: u16 = if (wide) b.h - top_h else layout.major.of(b.h - top_h);
    const c1 = self.cur(1);
    if (view.active.len > 0 and c1.* >= view.active.len) c1.* = view.active.len - 1;
    const inner2 = self.screen.pane(.{ .x = b.x, .y = b.y + top_h, .w = act_w, .h = act_h }, .{ .title = "ACTIVE", .focused = self.focus == 1, .right_title = "[Enter] full log  [c] complete  [R] recall" });
    var first: usize = 0;
    for (act_index.items, 0..) |ai, li| if (ai == c1.* and first == 0 and li > 0) {
        first = li;
    };
    self.screen.lines(inner2, act.items, if (first + inner2.h > act.items.len and act.items.len > inner2.h) act.items.len - inner2.h else first, if (self.focus == 1 and view.active.len > 0) first else null);

    var hist: std.ArrayListUnmanaged([]const u8) = .empty;
    if (history.len == 0) try hist.append(al, "{d}no closed contracts yet — completed, breached and failed contracts land here, and an HQ can be founded on any world worked{/}");
    try hist.append(al, "");
    try hist.append(al, "{a}STANDING{/}  tours served earn it, tours served against a house cost it, a breach costs a lot; it drifts home monthly");
    for (view.standings) |line| try hist.append(al, line);
    const hist_rect: screen_mod.Rect = if (wide)
        .{ .x = b.x + act_w, .y = b.y + top_h, .w = b.w - act_w, .h = (b.h - top_h) / 2 }
    else
        .{ .x = b.x, .y = b.y + top_h + act_h, .w = b.w, .h = b.h - top_h - act_h };
    const hist_inner = self.screen.pane(hist_rect, .{ .title = "HISTORY", .focused = self.focus == 2, .right_title = "Tab here · log follows the cursor · [Enter] full log" });
    // The closed contracts as a table, the standings as lines under it.
    const hist_rows: u16 = @intCast(@min(history.len + 1, hist_inner.h));
    try self.tablePane(.{ .x = hist_inner.x, .y = hist_inner.y, .w = hist_inner.w, .h = hist_rows }, try q.tableOf(al, q.history_cols, history), 2, self.focus == 2);
    if (hist_inner.h > hist_rows) self.screen.lines(.{ .x = hist_inner.x, .y = hist_inner.y + hist_rows, .w = hist_inner.w, .h = hist_inner.h - hist_rows }, hist.items, 0, null);

    if (wide) {
        // The log follows whichever contract the cursor is on: an active one, or a closed one in the history.
        const log_id: types.ContractId = if (self.focus == 2 and history.len > 0) history[c2.*].id else if (view.active.len > 0) view.active[c1.*].id else .none;
        const log = if (log_id != .none) try q.battleLog(al, g, log_id, 40) else &[_][]const u8{"{d}no contract under the cursor{/}"};
        self.listPane(.{ .x = b.x + act_w, .y = b.y + top_h + hist_rect.h, .w = b.w - act_w, .h = b.h - top_h - hist_rect.h }, "CONTRACT LOG", log, 3, false, false);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.contracts(al, g, @enumFromInt(self.hqSelId(g)));
        if (self.focus == 0) self.moveCursor(0, delta, view.board.len) else if (self.focus == 1) self.moveCursor(1, delta, view.active.len) else self.moveCursor(2, delta, (try q.contractHistory(al, g)).len);

}

pub fn enter(self: *App) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        const view = try q.contracts(al, g, @enumFromInt(self.hqSelId(g)));
        if (self.focus == 0 and view.board.len > 0) {
            // Always choose in the open: the picker ranks
            // the companies readiest first and says who cannot go.
            self.openModal(.{ .accept_pick = view.board[@min(self.cur(0).*, view.board.len - 1)].index });
        } else if (self.focus == 1 and view.active.len > 0) {
            // The whole log, full screen: the side pane clips it.
            self.modal_cursor = std.math.maxInt(usize) / 2; // open at the latest entry
            self.modal = .{ .contract_log = view.active[@min(self.cur(1).*, view.active.len - 1)].id };
        } else if (self.focus == 2) {
            const history = try q.contractHistory(al, g);
            if (history.len > 0) {
                self.modal_cursor = std.math.maxInt(usize) / 2;
                self.modal = .{ .contract_log = history[@min(self.cur(2).*, history.len - 1)].id };
            }
        }

}

pub fn key(self: *App, ch: u21) anyerror!void {
    const al = self.a();
    const g = &self.gs.?;
        // One board per HQ: [ ] steps through them.
        if (ch == ']' or ch == '[') {
            const n = (try q.hqList(al, g)).len;
            if (n > 0) self.hq_sel = if (ch == ']') (self.hq_sel + 1) % n else (self.hq_sel + n - 1) % n;
            self.cur(0).* = 0;
            return;
        }
        if (self.focus == 2) return; // history is read-only: the log pane follows the cursor
        const view = try q.contracts(al, g, @enumFromInt(self.hqSelId(g)));
        if (self.focus == 0) {
            if (ch == 'b' and view.board.len > 0) { // bargain: n is end-turn everywhere
                const offer = view.board[@min(self.cur(0).*, view.board.len - 1)];
                const idx = offer.index;
                if (offer.negotiated) {
                    self.say(.dim, "that offer has had its negotiation round — take it or leave it", .{});
                    return;
                }
                self.openModal(.{ .negotiate = idx });
            }
            return;
        }
        if (view.active.len == 0) return;
        const sel = view.active[@min(self.cur(1).*, view.active.len - 1)];
        switch (ch) {
            'c' => {
                if (sel.id == .none) {
                    self.say(.dim, "no contract to complete — [R] recalls the company", .{});
                    return;
                }
                _ = try self.execSay(.{ .complete_contract = sel.id }, .good, "contract [{d}] closed out", .{@intFromEnum(sel.id)});
            },
            'R' => {
                // Under contract the recall is a breach: confirm it first.
                if (sel.id != .none) {
                    self.modal = .{ .confirm = .{ .kind = .recall_breach, .id = @intFromEnum(sel.company) } };
                    return;
                }
                _ = try self.execSay(.{ .recall_company = sel.company }, .good, "{s} is coming home", .{try q.forceName(self.a(), g, sel.company)});
            },
            else => {},
        }

}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "b on an offer opens its negotiation for that offer" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .contracts);
    c.app.focus = 0;
    try app.pressForTest(c, .{ .char = 'b' });
    try std.testing.expect(c.app.modal == .negotiate);
    try std.testing.expectEqual(c.app.cur(0).*, c.app.modal.negotiate);
}
