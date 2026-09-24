//! Key bindings: one table per screen (and one for the whole client) maps
//! keys to semantic actions and carries every word shown about them. The
//! footer, pane titles, help rows and the key block in docs/tui.md are
//! generated from the tables, and a screen's handler switches on actions,
//! so a key cannot work without being listed or be listed without working
//! (docs/coding-contract.md rule 22). MekHQ has no counterpart: its Swing
//! menus carry their own accelerators.

const std = @import("std");
const term = @import("term.zig");

pub const Key = term.Key;

/// Footer order, everywhere: navigate | act | money · misc.
pub const Group = enum { navigate, act, money, misc };

/// What a binding answers to: one key, a run of characters, a run of
/// function keys, or typed text (any printable character no other binding
/// claims). A run hands its handler the offset of the key pressed; a text
/// handler reads the character from the key itself.
pub const Match = union(enum) {
    key: Key,
    chars: struct { u21, u21 },
    fkeys: struct { u8, u8 },
    text,

    pub fn char(c: u21) Match {
        return .{ .key = .{ .char = c } };
    }

    /// The offset of `k` in this match, or null when it does not match.
    pub fn offset(self: Match, k: Key) ?u8 {
        switch (self) {
            .key => |want| return if (keyEql(want, k)) 0 else null,
            .chars => |r| return switch (k) {
                .char => |c| if (c >= r[0] and c <= r[1]) @intCast(c - r[0]) else null,
                else => null,
            },
            .fkeys => |r| return switch (k) {
                .f => |n| if (n >= r[0] and n <= r[1]) n - r[0] else null,
                else => null,
            },
            .text => return switch (k) {
                .char => |c| if (c >= 0x20 and c != 0x7f) 0 else null,
                else => null,
            },
        }
    }

    /// True when two matches share any key.
    pub fn overlaps(a: Match, b: Match) bool {
        // Text is the fallback: it gives way to every other binding.
        if (a == .text or b == .text) return a == .text and b == .text;
        return switch (a) {
            .key => |k| b.offset(k) != null,
            .chars => |r| blk: {
                var c = r[0];
                while (c <= r[1]) : (c += 1) if (b.offset(.{ .char = c }) != null) break :blk true;
                break :blk false;
            },
            .fkeys => |r| blk: {
                var n = r[0];
                while (n <= r[1]) : (n += 1) if (b.offset(.{ .f = n }) != null) break :blk true;
                break :blk false;
            },
            .text => unreachable,
        };
    }
};

pub fn keyEql(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .char => |c| c == b.char,
        .f => |n| n == b.f,
        .ctrl => |c| c == b.ctrl,
        else => true,
    };
}

pub fn Binding(comptime Action: type) type {
    return struct {
        match: Match,
        action: Action,
        /// A few words for the footer and pane titles: "upgrade".
        label: []const u8,
        group: Group,
        /// The pane (focus index) the binding works in; null = every pane.
        pane: ?u8 = null,
        /// The pane whose title lists the binding, when that differs from
        /// `pane` (a key that works anywhere but acts on one pane).
        title: ?u8 = null,
        /// How the key is written when its name will not do ("F1-F10").
        shown: ?[]const u8 = null,
        /// A sentence for the help modal when the label is not enough.
        help: ?[]const u8 = null,
        show_footer: bool = true,
        show_help: bool = true,
    };
}

/// What `lookup` found: the action, and the key's offset in a run.
pub fn Hit(comptime Action: type) type {
    return struct { action: Action, offset: u8 };
}

/// The action `k` means with pane `focus` focused, in this order: the
/// pane's own key, typed text in that pane, an every-pane key, typed text
/// anywhere. So a text field takes every character while it has focus.
pub fn lookup(comptime Action: type, bindings: []const Binding(Action), focus: u8, k: Key) ?Hit(Action) {
    var found: [4]?Hit(Action) = .{ null, null, null, null };
    for (bindings) |b| {
        const off = b.match.offset(k) orelse continue;
        const in_pane = if (b.pane) |p| p == focus else false;
        if (b.pane != null and !in_pane) continue;
        const rank: usize = (if (b.pane == null) @as(usize, 2) else 0) + @intFromBool(b.match == .text);
        if (found[rank] == null) found[rank] = .{ .action = b.action, .offset = off };
    }
    for (found) |f| if (f) |hit| return hit;
    return null;
}

/// A binding stripped of its action type, for the text generators and the
/// cross-table checks.
pub const Entry = struct {
    match: Match,
    label: []const u8,
    group: Group,
    pane: ?u8,
    title: ?u8,
    shown: ?[]const u8,
    help: ?[]const u8,
    show_footer: bool,
    show_help: bool,
};

pub fn entries(comptime Action: type, comptime bindings: []const Binding(Action)) [bindings.len]Entry {
    var out: [bindings.len]Entry = undefined;
    for (bindings, &out) |b, *e| e.* = .{
        .match = b.match,
        .label = b.label,
        .group = b.group,
        .pane = b.pane,
        .title = b.title,
        .shown = b.shown,
        .help = b.help,
        .show_footer = b.show_footer,
        .show_help = b.show_help,
    };
    return out;
}

/// How a binding's key is written: "Enter", "↑", "F12", "u", "1-9".
pub fn keyText(buf: []u8, e: Entry) []const u8 {
    if (e.shown) |s| return s;
    return switch (e.match) {
        .key => |k| keyName(buf, k),
        .chars => |r| std.fmt.bufPrint(buf, "{u}-{u}", .{ r[0], r[1] }) catch "?",
        .fkeys => |r| std.fmt.bufPrint(buf, "F{d}-F{d}", .{ r[0], r[1] }) catch "?",
        .text => "type",
    };
}

pub fn keyName(buf: []u8, k: Key) []const u8 {
    return switch (k) {
        .char => |c| std.fmt.bufPrint(buf, "{u}", .{c}) catch "?",
        .f => |n| std.fmt.bufPrint(buf, "F{d}", .{n}) catch "?",
        .ctrl => |c| std.fmt.bufPrint(buf, "Ctrl-{u}", .{@as(u21, c)}) catch "?",
        .enter => "Enter",
        .escape => "Esc",
        .tab => "Tab",
        .backtab => "Shift-Tab",
        .backspace => "Backspace",
        .delete => "Del",
        .up => "↑",
        .down => "↓",
        .left => "←",
        .right => "→",
        .home => "Home",
        .end => "End",
        .pgup => "PgUp",
        .pgdn => "PgDn",
        .none => "",
    };
}

/// The footer line: `key label` per binding, `·` within a group, and the
/// groups in footer order (navigate | act | money · misc).
pub fn footer(alloc: std.mem.Allocator, lists: []const []const Entry) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    inline for (.{ Group.navigate, Group.act, Group.money, Group.misc }) |g| {
        var first = true;
        for (lists) |list| for (list) |e| {
            if (e.group != g or !e.show_footer) continue;
            if (first) {
                if (out.items.len > 0) try out.appendSlice(alloc, if (g == .misc) " · " else " | ");
                first = false;
            } else try out.appendSlice(alloc, " · ");
            var buf: [16]u8 = undefined;
            try out.print(alloc, "{s} {s}", .{ keyText(&buf, e), e.label });
        };
    }
    return out.toOwnedSlice(alloc);
}

/// A pane's right-hand title: `[key] label` for the pane's own bindings.
pub fn paneTitle(alloc: std.mem.Allocator, list: []const Entry, pane: u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (list) |e| {
        if ((e.title orelse e.pane) != pane or !e.show_footer) continue;
        if (out.items.len > 0) try out.appendSlice(alloc, "  ");
        var buf: [16]u8 = undefined;
        try out.print(alloc, "[{s}] {s}", .{ keyText(&buf, e), e.label });
    }
    return out.toOwnedSlice(alloc);
}

/// How the first binding for `action` is written, for a hint whose verb
/// the caller supplies ("[Enter] choose").
pub fn keyFor(comptime Action: type, buf: []u8, bindings: []const Binding(Action), action: Action) []const u8 {
    for (bindings) |b| if (b.action == action) return keyText(buf, .{
        .match = b.match,
        .label = b.label,
        .group = b.group,
        .pane = b.pane,
        .title = b.title,
        .shown = b.shown,
        .help = b.help,
        .show_footer = b.show_footer,
        .show_help = b.show_help,
    });
    return "?";
}

/// A modal title: its name, then `[key] label` for each binding shown
/// (an empty name gives just the keys, for a hint line).
pub fn title(alloc: std.mem.Allocator, name: []const u8, list: []const Entry) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, name);
    for (list) |e| {
        if (!e.show_footer) continue;
        var buf: [16]u8 = undefined;
        if (out.items.len > 0) try out.appendSlice(alloc, " · ");
        try out.print(alloc, "[{s}] {s}", .{ keyText(&buf, e), e.label });
    }
    return out.toOwnedSlice(alloc);
}

/// One help line per binding shown in help: the key, then its sentence or
/// its label.
pub fn helpLines(alloc: std.mem.Allocator, list: []const Entry) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (list) |e| {
        if (!e.show_help) continue;
        var buf: [16]u8 = undefined;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s: <10} {s}", .{ keyText(&buf, e), e.help orelse e.label }));
    }
    return out.toOwnedSlice(alloc);
}

/// Every action has a binding, and no two bindings answer the same key in
/// the same pane (a pane binding and an every-pane binding may share a key:
/// the pane's wins where it applies).
pub fn expectWellFormed(comptime Action: type, bindings: []const Binding(Action)) !void {
    inline for (std.meta.fields(Action)) |f| {
        const a: Action = @enumFromInt(f.value);
        for (bindings) |b| {
            if (b.action == a) break;
        } else {
            std.debug.print("action {s} has no binding\n", .{f.name});
            return error.UnboundAction;
        }
    }
    for (bindings, 0..) |a, i| for (bindings[i + 1 ..]) |b| {
        const same_scope = (a.pane == null and b.pane == null) or (a.pane != null and b.pane != null and a.pane.? == b.pane.?);
        if (same_scope and a.match.overlaps(b.match)) {
            std.debug.print("{s} and {s} share a key in one pane\n", .{ a.label, b.label });
            return error.DuplicateBinding;
        }
    };
}

const TestAction = enum { up, upgrade, hire, sell };
const test_bindings = [_]Binding(TestAction){
    .{ .match = .{ .key = .up }, .action = .up, .label = "up", .group = .navigate },
    .{ .match = Match.char('u'), .action = .upgrade, .label = "upgrade", .group = .act, .pane = 0 },
    .{ .match = .{ .key = .enter }, .action = .hire, .label = "hire", .group = .act, .pane = 1 },
    .{ .match = Match.char('$'), .action = .sell, .label = "sell", .group = .money },
};

test "a pane binding resolves only in its pane; an every-pane binding everywhere" {
    try expectWellFormed(TestAction, &test_bindings);
    try std.testing.expectEqual(TestAction.upgrade, lookup(TestAction, &test_bindings, 0, .{ .char = 'u' }).?.action);
    try std.testing.expect(lookup(TestAction, &test_bindings, 1, .{ .char = 'u' }) == null);
    try std.testing.expectEqual(TestAction.hire, lookup(TestAction, &test_bindings, 1, .enter).?.action);
    try std.testing.expectEqual(TestAction.sell, lookup(TestAction, &test_bindings, 1, .{ .char = '$' }).?.action);
}

test "a run hands back the offset of the key pressed" {
    const R = enum { screen };
    const b = [_]Binding(R){.{ .match = .{ .fkeys = .{ 1, 10 } }, .action = .screen, .label = "screens", .group = .navigate }};
    try std.testing.expectEqual(@as(u8, 6), lookup(R, &b, 0, .{ .f = 7 }).?.offset);
    try std.testing.expect(lookup(R, &b, 0, .{ .f = 12 }) == null);
}

test "an unbound action or a doubled key is refused" {
    const bad_unbound = [_]Binding(TestAction){.{ .match = Match.char('u'), .action = .upgrade, .label = "upgrade", .group = .act }};
    try std.testing.expectError(error.UnboundAction, expectWellFormed(TestAction, &bad_unbound));
    const R = enum { a, b };
    const doubled = [_]Binding(R){
        .{ .match = Match.char('x'), .action = .a, .label = "a", .group = .act },
        .{ .match = .{ .chars = .{ 'v', 'z' } }, .action = .b, .label = "b", .group = .act },
    };
    try std.testing.expectError(error.DuplicateBinding, expectWellFormed(R, &doubled));
}

test "a focused text field takes every character, even one bound elsewhere" {
    const R = enum { down, typed };
    const b = [_]Binding(R){
        .{ .match = Match.char('j'), .action = .down, .label = "down", .group = .navigate },
        .{ .match = .text, .action = .typed, .label = "type", .group = .act, .pane = 0 },
    };
    try std.testing.expectEqual(R.typed, lookup(R, &b, 0, .{ .char = 'j' }).?.action);
    try std.testing.expectEqual(R.down, lookup(R, &b, 1, .{ .char = 'j' }).?.action);
}

test "typed text is the fallback: a named key wins, any other character types" {
    const R = enum { save, typed };
    const b = [_]Binding(R){
        .{ .match = .text, .action = .typed, .label = "type", .group = .act },
        .{ .match = Match.char('u'), .action = .save, .label = "undo", .group = .act },
    };
    try expectWellFormed(R, &b);
    try std.testing.expectEqual(R.save, lookup(R, &b, 0, .{ .char = 'u' }).?.action);
    try std.testing.expectEqual(R.typed, lookup(R, &b, 0, .{ .char = 'x' }).?.action);
    try std.testing.expect(lookup(R, &b, 0, .enter) == null);
}

test "the footer groups in order and a pane title lists that pane's keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const es = entries(TestAction, &test_bindings);
    try std.testing.expectEqualStrings("↑ up | u upgrade · Enter hire | $ sell", try footer(al, &.{&es}));
    try std.testing.expectEqualStrings("[Enter] hire", try paneTitle(al, &es, 1));
}
