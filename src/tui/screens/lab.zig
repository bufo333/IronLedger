//! The Lab screen (docs/coding-contract.md rule 35): its draw, cursor
//! move, Enter and letter keys, registered once in `app.screen_table`.
//! Reads through queries, mutates through commands, like every screen.
//! MekHQ counterpart: the MekLab tab (docs/mekhq-map.md).

const std = @import("std");
const app = @import("../app.zig");
const App = app.App;
const game = app.game;
const layout = app.layout;
const q = app.q;
const meklab = game.meklab;

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = self.state();
    const b = self.body();
    const meks = try q.labMeks(al, g);
    if (meks.len == 0) {
        const rows = [_][]const u8{"{d}no meks to work on{/}"};
        self.listPane(b, "LAB", &rows, 0, false, false);
        return;
    }
    App.clampIdx(&self.lab_sel, meks.len);
    const uid = meks[self.lab_sel];
    const view = try q.lab(al, g, uid);
    const boxes = try q.labLayout(al, g, uid);
    const lw: u16 = if (self.narrow()) 0 else @max(30, layout.lab_hulls.of(b.w));
    const mw: u16 = if (self.narrow()) layout.major.of(b.w) else @max(40, layout.lab_mounts.of(b.w));

    // Left pane: budget summary + per-location crit boxes.
    if (lw > 0) {
        var budget_rows: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.budget) |line| try budget_rows.append(al, line);
        if (boxes.len > 0) {
            try budget_rows.append(al, "");
            try budget_rows.append(al, "{d}── locations ─────────────────────{/}");
            for (boxes) |box| {
                // Summary: "LA  fixed 2  free 10 [actuator note]"
                var fixed_n: u8 = 0;
                var free_n: u8 = 0;
                for (box.rows) |row| {
                    if (row.kind == .fixed) fixed_n += 1;
                    if (row.kind == .free) free_n += 1;
                }
                try budget_rows.append(al, try std.fmt.allocPrint(al, "{s: <4} {d: >2} fixed · {d: >2} free{s}", .{
                    box.title,                                                                                                  fixed_n, free_n,
                    if (box.actuator_note.len > 0) try std.fmt.allocPrint(al, "  {{d}}{s}{{/}}", .{box.actuator_note}) else "",
                }));
            }
        }
        self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, view.title, budget_rows.items, 1, false, false);
    }

    // Middle pane: per-location crit layout (the construction editor).
    var layout_rows: std.ArrayListUnmanaged([]const u8) = .empty;
    for (boxes) |box| {
        // Location header.
        const hdr = if (box.actuator_note.len > 0)
            try std.fmt.allocPrint(al, "{{a}}── {s} ──{{/}} {{d}}{s}{{/}}", .{ box.title, box.actuator_note })
        else
            try std.fmt.allocPrint(al, "{{a}}── {s} ──{{/}}", .{box.title});
        try layout_rows.append(al, hdr);
        for (box.rows) |row| {
            const mark: []const u8 = switch (row.kind) {
                .fixed => "{d}■{/}",
                .missile => "{b}M{/}",
                .energy => "{g}E{/}",
                .ballistic => "{a}B{/}",
                .equipment => "{s}Q{/}",
                .ammo => "{a}A{/}",
                .free => "{d}·{/}",
            };
            const text_col: []const u8 = switch (row.kind) {
                .fixed => try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{row.text}),
                .free => "{d}──────────{/}",
                else => try std.fmt.allocPrint(al, "{s}", .{row.text}),
            };
            try layout_rows.append(al, try std.fmt.allocPrint(al, " {s} {s}", .{ mark, text_col }));
        }
        try layout_rows.append(al, "");
    }
    if (layout_rows.items.len == 0) try layout_rows.append(al, "{d}no layout{/}");
    const focused_pane: bool = self.paneFocused(0);
    self.listPane(.{ .x = b.x + lw, .y = b.y, .w = mw, .h = b.h }, try std.fmt.allocPrint(al, "LAYOUT · hull {d} of {d}", .{ self.lab_sel + 1, meks.len }), layout_rows.items, 0, focused_pane, true);

    // Right pane: plan & rules.
    self.listPane(.{ .x = b.x + lw + mw, .y = b.y, .w = b.w - lw - mw, .h = b.h }, if (view.legal) "PLAN" else "PLAN · {c}illegal{/}", view.plan, 2, false, false);
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = self.state();
    const uid = (try self.labUnit()) orelse return;
    const boxes = try q.labLayout(al, g, uid);
    // Count total layout rows across all boxes (plus header rows).
    var total: usize = 0;
    for (boxes) |box| total += 1 + box.rows.len + 1; // header + rows + blank
    if (total > 0) self.moveCursor(0, delta, total);
}

const Action = enum { prev_hull, next_hull, install, remove, clear, commit, replace, depot, enter_slot };

pub const bindings = [_]app.keys.Binding(Action){
    .{ .match = app.keys.Match.char('['), .action = .prev_hull, .label = "hull", .group = .navigate, .shown = "[ ]", .help = "previous / next mek in the hangar" },
    .{ .match = app.keys.Match.char(']'), .action = .next_hull, .label = "next hull", .group = .navigate, .show_footer = false, .show_help = false },
    .{ .match = app.keys.Match.char('+'), .action = .install, .label = "install", .group = .act, .help = "stage installing a part (location picker)" },
    .{ .match = app.keys.Match.char('-'), .action = .remove, .label = "remove", .group = .act, .help = "stage removing the mount under the cursor" },
    .{ .match = app.keys.Match.char('c'), .action = .clear, .label = "clear", .group = .act, .help = "clear the staged refit plan" },
    .{ .match = app.keys.Match.char('m'), .action = .commit, .label = "commit", .group = .act, .help = "commit the plan as a bay job at the home HQ" },
    .{ .match = .{ .key = .enter }, .action = .enter_slot, .label = "select slot", .group = .act, .help = "on a free slot: open location-scoped part picker; on a loaded slot: stage remove" },
    .{ .match = app.keys.Match.char('R'), .action = .replace, .label = "order replacement", .group = .act, .help = "order a replacement for the damaged or destroyed mount under the cursor" },
    .{ .match = app.keys.Match.char('D'), .action = .depot, .label = "depot", .group = .act, .help = "queue the hull for depot repair" },
};
pub const legend = app.keys.entries(Action, &bindings);

/// Resolve which LocationBox row the layout cursor currently points to.
/// Returns the box and row within it, or null if the cursor is on a header/blank.
fn cursorRow(boxes: []const q.LocationBox, cursor: usize) ?struct { box: q.LocationBox, row: q.LayoutRow } {
    var idx: usize = 0;
    for (boxes) |box| {
        // Header row.
        if (idx == cursor) return null;
        idx += 1;
        // Slot rows.
        for (box.rows) |row| {
            if (idx == cursor) return .{ .box = box, .row = row };
            idx += 1;
        }
        // Blank separator row.
        if (idx == cursor) return null;
        idx += 1;
    }
    return null;
}

pub fn handle(self: *App, k: app.Key) anyerror!bool {
    const hit = app.keys.lookup(Action, &bindings, self.focus, k) orelse return false;
    const al = self.a();
    const g = self.state();
    const uid = (try self.labUnit()) orelse return true;
    const view = try q.lab(al, g, uid);
    const meks = view.meks;
    const boxes = try q.labLayout(al, g, uid);
    switch (hit.action) {
        .next_hull => self.lab_sel = (self.lab_sel + 1) % meks.len,
        .prev_hull => self.lab_sel = (self.lab_sel + meks.len - 1) % meks.len,
        .remove => {
            // Remove: use the mounts list for backward compatibility.
            if (view.mounts.len > 0) {
                const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
                _ = try self.execSay(.{ .refit_remove = .{ .unit = uid, .slot_key = m.slot_key } }, .good, "staged: remove {s}", .{m.slot_key});
            }
        },
        .install => {
            self.openModal(.{ .install_part = uid });
        },
        .enter_slot => {
            // Enter: resolve the layout cursor row.
            if (cursorRow(boxes, self.cur(0).*)) |hit_row| {
                if (hit_row.row.kind == .free) {
                    // Free slot: open location-scoped part picker.
                    self.openModal(.{ .install_at = .{ .unit = uid, .location = hit_row.box.loc } });
                } else if (hit_row.row.kind != .fixed) {
                    // Loaded slot: stage remove.
                    if (hit_row.row.slot_key.len > 0) {
                        _ = try self.execSay(.{ .refit_remove = .{ .unit = uid, .slot_key = hit_row.row.slot_key } }, .good, "staged: remove {s}", .{hit_row.row.slot_key});
                    }
                }
            }
        },
        .replace => if (view.mounts.len > 0) {
            const m = view.mounts[@min(self.cur(0).*, view.mounts.len - 1)];
            const res = self.execResult(.{ .replace_mount = .{ .unit = uid, .slot_key = m.slot_key } }) orelse return true;
            self.say(.good, "ordered 1 × {s} to {s}; techs fit it on the next repair pass once it lands", .{ m.part_key, try q.hqName(self.a(), g, res.hq) });
        },
        .clear => {
            _ = try self.execSay(.{ .refit_clear = uid }, .good, "#{d}: refit plan cleared", .{@intFromEnum(uid)});
        },
        .commit => {
            _ = try self.execSay(.{ .refit_commit = uid }, .good, "refit committed — it is a bay job at the home HQ: the HQ screen lists the bays, queued and running, with days left", .{});
        },
        .depot => {
            _ = try self.execSay(.{ .depot = uid }, .good, "#{d} queued for depot repair — see the HQ screen's bays", .{@intFromEnum(uid)});
        },
    }
    return true;
}

fn toTab(c: *app.ClientForTest, tab: app.Tab) !void {
    try app.pressForTest(c, .{ .f = @intFromEnum(tab) + 1 });
}

test "the lab bindings are well formed" {
    try app.keys.expectWellFormed(Action, &bindings);
}

test "] and [ step through the hangar's meks" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .lab);
    const start = c.app.lab_sel;
    try app.pressForTest(c, .{ .char = ']' });
    try std.testing.expect(c.app.lab_sel != start);
    try app.pressForTest(c, .{ .char = '[' });
    try std.testing.expectEqual(start, c.app.lab_sel);
}

test "R on a sound mount shows canonical MountIsFine refusal" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .lab);
    try app.pressForTest(c, .{ .char = 'R' });
    // A fresh company's gear is sound: the canonical sentence via cli.errorText.
    try std.testing.expect(std.mem.indexOf(u8, c.app.msg.slice(), "is fine") != null);
    try std.testing.expect(std.mem.startsWith(u8, c.app.msg.slice(), "refused"));
}

test "m commits the refit plan (previously Enter)" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .lab);
    // 'm' now commits (was Enter); with an empty plan the command is refused.
    try app.pressForTest(c, .{ .char = 'm' });
    // An empty plan commit is refused ("nothing staged").
    try std.testing.expect(std.mem.startsWith(u8, c.app.msg.slice(), "refused"));
}

test "Enter on a free slot opens the install_at modal" {
    const c = try app.clientForTest(std.testing.allocator);
    defer app.deinitForTest(c, std.testing.allocator);
    try toTab(c, .lab);
    // Navigate to a free slot: move down past the first fixed/loaded rows.
    // Move down enough times to reach a free row (layout has fixed + loaded + free rows).
    const al = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(al);
    defer arena.deinit();
    const g = c.app.state();
    const meks = try q.labMeks(arena.allocator(), g);
    if (meks.len == 0) return;
    const uid = meks[c.app.lab_sel];
    const boxes = try q.labLayout(arena.allocator(), g, uid);
    // Find the index of the first free row in the layout list.
    var target_idx: ?usize = null;
    var idx: usize = 0;
    outer: for (boxes) |box| {
        idx += 1; // header
        for (box.rows) |row| {
            if (row.kind == .free) {
                target_idx = idx;
                break :outer;
            }
            idx += 1;
        }
        idx += 1; // blank
    }
    if (target_idx == null) return; // no free slots in the test hull
    // Set the cursor directly.
    c.app.cur(0).* = target_idx.?;
    // Press Enter.
    try app.pressForTest(c, .enter);
    // The modal should now be install_at.
    const is_install_at = switch (c.app.modal) {
        .install_at => true,
        else => false,
    };
    try std.testing.expect(is_install_at);
}
