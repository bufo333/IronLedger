//! The client's selectable looks (docs/tui.md "Rendering"): a closed set
//! of themes, each a chrome palette with or without the scrim and the
//! modal shadow. A theme changes chrome only; semantic colours are the same
//! under every theme (rule 43). The player picks one in Settings and the
//! store keeps it (`lobby.Theme`).
//! No MekHQ counterpart: MekHQ draws with Swing (docs/mekhq-map.md).

const std = @import("std");
const Theme = @import("game").lobby.Theme;
const screen = @import("screen.zig");
const term = @import("term.zig");

pub const Entry = struct {
    id: Theme,
    /// The name Settings and the status line show.
    name: []const u8,
    /// One line on what the theme is for.
    blurb: []const u8,
    look: screen.Look,
};

/// Every theme, in the order Settings cycles through them.
pub const entries = [_]Entry{
    .{ .id = .standard, .name = "standard", .blurb = "dim chrome, bold titles; a modal stands out over a dimmed screen", .look = .{ .palette = &term.palette.standard, .scrim = true, .shadow = true } },
    .{ .id = .classic, .name = "classic", .blurb = "every border one colour; a modal has only its double rule", .look = .{ .palette = &term.palette.classic } },
    .{ .id = .high_contrast, .name = "high contrast", .blurb = "no greys: bold, reverse and faint, for light backgrounds and low vision", .look = .{ .palette = &term.palette.high_contrast, .scrim = true, .shadow = true } },
};

comptime {
    for (std.enums.values(Theme)) |id| {
        var found = 0;
        for (entries) |e| found += @intFromBool(e.id == id);
        if (found != 1) @compileError("every theme has exactly one entry");
    }
}

/// The entry for `id`.
pub fn of(id: Theme) *const Entry {
    for (&entries) |*e| if (e.id == id) return e;
    unreachable; // every theme has an entry (checked at compile time)
}

/// The theme `dir` steps away from `id` in `entries` order, wrapping at
/// either end.
pub fn next(id: Theme, dir: i8) Theme {
    const n: i32 = entries.len;
    const at: i32 = for (entries, 0..) |e, i| {
        if (e.id == id) break @intCast(i);
    } else unreachable; // every theme has an entry (checked at compile time)
    return entries[@intCast(@mod(at + dir, n))].id;
}

test "themes cycle in both directions and wrap at either end" {
    try std.testing.expectEqual(Theme.classic, next(.standard, 1));
    try std.testing.expectEqual(Theme.high_contrast, next(.classic, 1));
    try std.testing.expectEqual(Theme.standard, next(.high_contrast, 1));
    try std.testing.expectEqual(Theme.high_contrast, next(.standard, -1));
    try std.testing.expectEqual(Theme.standard, next(.classic, -1));
}

test "every theme draws every semantic style exactly as classic does (rule 43)" {
    const classic = of(.classic).look.palette;
    const chrome = [_]screen.Style{ .box, .focus, .pane_title, .modal_box, .modal_title, .shadow, .scrim };
    for (entries) |e| for (std.enums.values(screen.Style)) |style| {
        if (std.mem.indexOfScalar(screen.Style, &chrome, style) != null) continue;
        try std.testing.expectEqualStrings(style.sgr(classic), style.sgr(e.look.palette));
    };
}

test "classic keeps the single-style chrome: no scrim and no shadow" {
    const classic = of(.classic).look;
    try std.testing.expect(!classic.scrim and !classic.shadow);
    try std.testing.expect(classic.palette == &term.palette.classic);
}

test "high contrast draws chrome with no fixed grey" {
    const p = of(.high_contrast).look.palette;
    for ([_][]const u8{ p.box, p.focus, p.pane_title, p.modal_box, p.modal_title, p.shadow, p.scrim }) |s| {
        for ([_][]const u8{ ";37m", ";90m", ";97m" }) |grey| try std.testing.expect(!std.mem.endsWith(u8, s, grey));
    }
}
