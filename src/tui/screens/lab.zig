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

/// Return the screen rect for a location box within the spatial mech diagram.
/// base_x / base_y: top-left corner of the diagram area (after the budget pane).
/// Diagram layout (record-sheet style):
///
///            [HD]
///   [LA][LT][CT][RT][RA]
///       [LL]     [RL]
///
/// Total width  = arm_w + 3*torso_w + arm_w
/// Total height = head_h + torso_h + leg_h
fn boxRect(
    loc: meklab.Location,
    base_x: u16,
    base_y: u16,
    torso_w: u16,
    arm_w: u16,
    head_h: u16,
    torso_h: u16,
    leg_h: u16,
) struct { x: u16, y: u16, w: u16, h: u16 } {
    const t2: u16 = torso_w *% 2;
    const t3: u16 = torso_w *% 3;
    const ra_x: u16 = arm_w +% t3;
    const leg_y: u16 = base_y +% head_h +% torso_h;
    return switch (loc) {
        .hd => .{ .x = base_x +% arm_w +% torso_w, .y = base_y, .w = torso_w, .h = head_h },
        .lt => .{ .x = base_x +% arm_w, .y = base_y +% head_h, .w = torso_w, .h = torso_h },
        .ct => .{ .x = base_x +% arm_w +% torso_w, .y = base_y +% head_h, .w = torso_w, .h = torso_h },
        .rt => .{ .x = base_x +% arm_w +% t2, .y = base_y +% head_h, .w = torso_w, .h = torso_h },
        .la => .{ .x = base_x, .y = base_y +% head_h, .w = arm_w, .h = torso_h },
        .ra => .{ .x = base_x +% ra_x, .y = base_y +% head_h, .w = arm_w, .h = torso_h },
        .ll => .{ .x = base_x +% arm_w, .y = leg_y, .w = torso_w, .h = leg_h },
        .rl => .{ .x = base_x +% arm_w +% t2, .y = leg_y, .w = torso_w, .h = leg_h },
    };
}

/// Format one crit slot row for rendering inside a location box.
/// Staged installs (slot_key == "" and kind != fixed/free) render in amber
/// to show they are pending.
fn slotLine(al: std.mem.Allocator, row: q.LayoutRow) ![]const u8 {
    const staged = row.slot_key.len == 0 and
        row.kind != .fixed and row.kind != .free;
    const mark: []const u8 = switch (row.kind) {
        .fixed => "{d}■{/}",
        .missile => if (staged) "{a}M{/}" else "{p}M{/}",
        .energy => "{a}E{/}",
        .ballistic => if (staged) "{a}B{/}" else "{c}B{/}",
        .equipment => if (staged) "{a}Q{/}" else "{g}Q{/}",
        .ammo => if (staged) "{a}A{/}" else "{g}A{/}",
        .free => "{d}·{/}",
    };
    const text: []const u8 = switch (row.kind) {
        .fixed => try std.fmt.allocPrint(al, "{{d}}{s}{{/}}", .{row.text}),
        .free => "{d}────────{/}",
        else => if (staged)
            try std.fmt.allocPrint(al, "{{a}}{s}{{/}}", .{row.text})
        else
            row.text,
    };
    return std.fmt.allocPrint(al, "{s} {s}", .{ mark, text });
}

/// Map the flat linear cursor (which counts header + rows + blank per box)
/// to (box_index, row_index_within_box).  row index is null when the cursor
/// is on a header or blank separator row.
fn cursorBoxRow(boxes: []const q.LocationBox, cursor: usize) struct { bi: usize, ri: ?usize } {
    var idx: usize = 0;
    for (boxes, 0..) |box, bi| {
        if (idx == cursor) return .{ .bi = bi, .ri = null }; // header
        idx += 1;
        for (box.rows, 0..) |_, ri| {
            if (idx == cursor) return .{ .bi = bi, .ri = ri };
            idx += 1;
        }
        if (idx == cursor) return .{ .bi = bi, .ri = null }; // blank
        idx += 1;
    }
    return .{ .bi = 0, .ri = null };
}

pub fn draw(self: *App) anyerror!void {
    const al = self.a();
    const g = self.state();
    const b = self.body();
    const meks = try q.labMeks(al, g);
    if (meks.len == 0) {
        const focused = self.paneFocused(0);
        self.listPane(b, "LAB", &.{"{d}no meks to work on{/}"}, 0, focused, false);
        return;
    }
    App.clampIdx(&self.lab_sel, meks.len);
    const uid = meks[self.lab_sel];
    const view = try q.lab(al, g, uid);
    const boxes = try q.labLayout(al, g, uid);

    // Left pane: budget summary + staged plan (wide only).
    const lw: u16 = if (self.narrow()) 0 else @max(30, layout.lab_hulls.of(b.w));
    if (lw > 0) {
        var budget_rows: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.budget) |line| try budget_rows.append(al, line);
        if (view.plan.len > 0) {
            try budget_rows.append(al, "");
            try budget_rows.append(al, "{d}── staged plan ────────────────────{/}");
            for (view.plan) |line| try budget_rows.append(al, line);
        }
        self.listPane(.{ .x = b.x, .y = b.y, .w = lw, .h = b.h }, view.title, budget_rows.items, 1, false, false);
    }

    // Spatial mech diagram — all remaining width.
    const dx: u16 = b.x + lw;
    const focused_overall = self.paneFocused(0);

    // Box dimensions.  physicalTotal(loc) + 2 for the border; derived from
    // the actual row counts so the identity holds for any chassis.
    const torso_w: u16 = 16; // inner_w = 12: mark + space + 10-char label
    const arm_w: u16 = 13; // inner_w =  9: mark + space +  7-char label
    var head_h: u16 = 8;
    var torso_h: u16 = 14;
    var leg_h: u16 = 8;
    for (boxes) |box| switch (box.loc) {
        .hd => head_h = @intCast(box.rows.len + 2),
        .ct => torso_h = @intCast(box.rows.len + 2),
        .ll => leg_h = @intCast(box.rows.len + 2),
        else => {},
    };

    // Map the cursor to the selected box and row.
    const sel = cursorBoxRow(boxes, self.cur(0).*);

    // Render each location box at its spatial position within the diagram.
    for (boxes, 0..) |box, bi| {
        const r = boxRect(box.loc, dx, b.y, torso_w, arm_w, head_h, torso_h, leg_h);
        const is_sel = (bi == sel.bi);
        const inner = self.screen.pane(
            .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h },
            .{ .title = box.title, .focused = is_sel and focused_overall },
        );
        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        for (box.rows) |row| {
            try items.append(al, try slotLine(al, row));
        }
        self.screen.lines(inner, items.items, 0, if (is_sel) sel.ri else null);
    }

    // Actuator note: rendered below the LA box in the arm_w-wide space to
    // the left of LL (at y = head_h + torso_h) when the arm has reduced
    // actuators (box.actuator_note != "").
    for (boxes) |box| {
        if (box.actuator_note.len == 0 or box.loc != .la) continue;
        const note_x: i32 = @as(i32, dx);
        const note_y: i32 = @as(i32, b.y) + @as(i32, head_h) + @as(i32, torso_h);
        const note_w: u16 = arm_w;
        // Split at "/ " for the two-line form; single line for "no hand act."
        if (std.mem.indexOf(u8, box.actuator_note, "/ ")) |sep| {
            self.screen.textPad(note_x, note_y, note_w, box.actuator_note[0..sep], .dim);
            self.screen.textPad(note_x, note_y + 1, note_w, box.actuator_note[sep + 2 ..], .dim);
        } else {
            self.screen.textPad(note_x, note_y, note_w, box.actuator_note, .dim);
        }
    }

    // Stats panel: render view.budget lines in any remaining width to the
    // right of the diagram (width = 2*arm_w + 3*torso_w = 74 chars).
    const diag_w: u16 = arm_w *% 2 +% torso_w *% 3;
    const stats_x: u16 = dx +% diag_w;
    const stats_w: u16 = (b.x +% b.w) -| stats_x;
    if (stats_w >= 18) {
        var stats_rows: std.ArrayListUnmanaged([]const u8) = .empty;
        for (view.budget) |line| try stats_rows.append(al, line);
        const stats_inner = self.screen.pane(
            .{ .x = stats_x, .y = b.y, .w = stats_w, .h = b.h },
            .{ .title = "STATS", .focused = false },
        );
        self.screen.lines(stats_inner, stats_rows.items, 0, null);
    }
}

pub fn move(self: *App, delta: i32) anyerror!void {
    const al = self.a();
    const g = self.state();
    const uid = (try self.labUnit()) orelse return;
    const boxes = try q.labLayout(al, g, uid);
    // Count total items in the linear cursor model: header + rows + blank per box.
    var total: usize = 0;
    for (boxes) |box| total += 1 + box.rows.len + 1;
    if (total > 0) self.moveCursor(0, delta, total);
}

const Action = enum { prev_hull, next_hull, install, remove, clear, commit, replace, depot, enter_slot, next_box, prev_box };

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
    .{ .match = app.keys.Match.char('>'), .action = .next_box, .label = "next loc", .group = .navigate, .shown = "> <", .help = "jump to next / previous location box" },
    .{ .match = app.keys.Match.char('<'), .action = .prev_box, .label = "prev loc", .group = .navigate, .show_footer = false, .show_help = false },
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

/// Return the linear cursor index of box bi's header row.
fn boxHeaderIndex(boxes: []const q.LocationBox, bi: usize) usize {
    var idx: usize = 0;
    for (boxes, 0..) |box, i| {
        if (i == bi) return idx;
        idx += 1 + box.rows.len + 1;
    }
    return 0;
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
        .next_box => {
            const sel2 = cursorBoxRow(boxes, self.cur(0).*);
            const next_bi = (sel2.bi + 1) % boxes.len;
            self.cur(0).* = boxHeaderIndex(boxes, next_bi);
        },
        .prev_box => {
            const sel2 = cursorBoxRow(boxes, self.cur(0).*);
            const prev_bi = (sel2.bi + boxes.len - 1) % boxes.len;
            self.cur(0).* = boxHeaderIndex(boxes, prev_bi);
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
