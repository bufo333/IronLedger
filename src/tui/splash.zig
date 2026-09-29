//! Title screen (Stage 12): the game's name and one of four BattleMechs in
//! ASCII, chosen at random each launch (Timber Wolf, Dire Wolf, Mad Dog, Nova),
//! held for five seconds at start or until a key is pressed. Pure drawing
//! into the cell grid; the wait loop lives in app.zig.
//! No MekHQ counterpart: the title screen (docs/mekhq-map.md).

const std = @import("std");
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;

pub const game_name = "IRON LEDGER";
pub const tagline = "a mercenary command in the Succession Wars";

/// Block-letter title, 6 rows.
pub const title = [_][]const u8{
    "██╗██████╗  ██████╗ ███╗   ██╗    ██╗     ███████╗██████╗  ██████╗ ███████╗██████╗ ",
    "██║██╔══██╗██╔═══██╗████╗  ██║    ██║     ██╔════╝██╔══██╗██╔════╝ ██╔════╝██╔══██╗",
    "██║██████╔╝██║   ██║██╔██╗ ██║    ██║     █████╗  ██║  ██║██║  ███╗█████╗  ██████╔╝",
    "██║██╔══██╗██║   ██║██║╚██╗██║    ██║     ██╔══╝  ██║  ██║██║   ██║██╔══╝  ██╔══██╗",
    "██║██║  ██║╚██████╔╝██║ ╚████║    ███████╗███████╗██████╔╝╚██████╔╝███████╗██║  ██║",
    "╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝    ╚══════╝╚══════╝╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝",
};

/// ASCII-only title for `--ascii` terminals.
pub const title_ascii = [_][]const u8{
    " ___ ____   ___  _   _    _     _____ ____   ____ _____ ____  ",
    "|_ _|  _ \\ / _ \\| \\ | |  | |   | ____|  _ \\ / ___| ____|  _ \\ ",
    " | || |_) | | | |  \\| |  | |   |  _| | | | | |  _|  _| | |_) |",
    " | ||  _ <| |_| | |\\  |  | |___| |___| |_| | |_| | |___|  _ < ",
    "|___|_| \\_\\\\___/|_| \\_|  |_____|_____|____/ \\____|_____|_| \\_\\",
};

/// The ASCII artist's credit, drawn in the splash's bottom-right corner.
pub const credit_art = "ASCII art: Rick Heney";
/// The game's author credit, drawn in the splash's bottom-left corner.
pub const credit_game = "A game by John Burns";

/// One mech drawing: caption name and art rows (pure ASCII, no markup braces).
pub const MechArt = struct {
    /// The exact caption delivered with the drawing, e.g. "ASCII Timber Wolf".
    name: []const u8,
    /// Drawing rows only (no caption); every row is pure ASCII.
    art: []const []const u8,
};

/// Four BattleMechs by Rick Heney; one is chosen at random each launch.
pub const mechs = [_]MechArt{
    // index 0
    .{
        .name = "ASCII Timber Wolf",
        .art = &[_][]const u8{
            "          ----             ----",
            "         |oooo|           |oooo|",
            "         |oooo|           |oooo|",
            "         |oooo| /-------\\ |oooo|",
            "        (|*ooo|/\\  | |  /\\|ooo*|)",
            "          ----| /-------\\ |----",
            "        /--\\| |/  \\ | /  \\| |/--\\",
            "    ___/\\  || ||  /---\\  || ||  /\\___",
            "   /\\\\__/\\-/|_|\\--|\\/_/|--/|_|\\-/\\__//\\",
            "   | /         0=\\o---o/=0         \\ |",
            "   |-|            \\o_o/            |-|",
            "   (=)           |=====|           (=)",
            "   |-|       _ __ |---| __ _       |-|",
            "  /---\\    /| |||=======||| |\\    /---\\",
            "  |<0>|    || |||=======||| ||    |<0>|",
            "  \\---/    \\|_|--       --|_|/    \\---/",
            "   |o|      ||             ||      |o|",
            "           /||             ||\\",
            "         /--|\\|           /||--\\",
            "         |====|           |====|",
            "         \\_||_/           \\_||_/",
            "          /||\\             /||\\",
            "          ||||             ||||",
            "         //--\\\\           //--\\\\",
            "         ||  ||           ||  ||",
            "         ||  ||           ||  ||",
            "         \\|  |/           \\|  |/",
            "         /\\__/\\           /\\__/\\",
            "      __ /====\\ __     __ /====\\ __",
            "     /_/==|__|==\\_\\   /_/==|__|==\\_\\",
        },
    },
    // index 1
    .{
        .name = "ASCII Dire Wolf",
        .art = &[_][]const u8{
            "                 _____",
            "                /ooooo\\",
            "                |\\oooo|",
            "          ___----___oo|",
            "        _/  ______  \\_/",
            "   __  |/  / ____ \\  \\|  __",
            "  || ||/= / /    \\ \\ =\\|| ||",
            " [|| |||_/_| \\==/ |_\\_||| ||]",
            "  || |||_| |\\____/| |_||| ||",
            "  ||/    | |\\o()o/| |    \\||",
            "  |||    |_| \\__/ |_|    |||",
            " /---|      ==||==      |---\\",
            " |O O|  ___  ====  ___  |O O|",
            " | O | |   |||--|||   | | O |",
            " |O O| |   |||__|||   | |O O|",
            " \\---| |   | |/\\| |   | |---/",
            "   V   |---|      |---|   V",
            "       |___|      |___|",
            "      /     \\    /     \\",
            "      |     |    |     |",
            "      \\     /    \\     /",
            "       \\___/      \\___/",
            "       /   \\      /   \\",
            "    ___|___|      |___|___",
            "   /  _|/-\\|      |/-\\|_  \\",
            "   ---  ---        ---  ---",
        },
    },
    // index 2
    .{
        .name = "ASCII Mad Dog",
        .art = &[_][]const u8{
            "             ___   ___   ___",
            "            |---| /   \\ |---|",
            "          _ |ooo|-|   |-|ooo| _",
            "         / ||ooo| || || |ooo|| \\",
            "        |  ||ooo| || || |ooo||  |",
            "       / \\-||ooo|/|| ||\\|ooo||-/ \\",
            "      / /   |ooo(||---||)ooo|   \\ \\",
            "    _/ /    |---|\\|   |/|---|    \\ \\_",
            "   /_\\/     |___|O|---|O|___|     \\/_\\",
            " (0)_(0)         |=====|         (0)_(0)",
            "    V        _ __ |---| __ _        V",
            "           /| |||=======||| |\\",
            "           || |||=======||| ||",
            "           \\|_|--       --|_|/",
            "            ||             ||",
            "           /||             ||\\",
            "         /--|\\|           /||--\\",
            "         |====|           |====|",
            "         \\_||_/           \\_||_/",
            "          /||\\             /||\\",
            "          ||||             ||||",
            "         //--\\\\           //--\\\\",
            "         ||  ||           ||  ||",
            "         ||  ||           ||  ||",
            "         \\|  |/           \\|  |/",
            "         /\\__/\\           /\\__/\\",
            "      __ /====\\ __     __ /====\\ __",
            "     /_/==|__|==\\_\\   /_/==|__|==\\_\\",
        },
    },
    // index 3
    .{
        .name = "ASCII Nova",
        .art = &[_][]const u8{
            "          __                  __",
            "     _   _||-\\   ________   /-||_   _",
            "    | |-| ||| |=| ______ |=| ||| |-| |",
            "    | ||| ||| | ||-/||\\-|| | ||| ||| |",
            "    | ||| ||| | |_/_/\\_\\_| | ||| ||| |",
            "    | |-| ||| |=-| ____ |-=| ||| |-| |",
            "    | | | ||-/   |/ __ \\|   \\-|| | | |",
            "   _|_| | |||   _| |  | |_   ||| | |_|_",
            "  _| |  |-|||] /=|_|__|_|=\\ [|||-|  | |_",
            " /0--0| \\||||  \\o_/    \\_o/  ||||/ |0--0\\",
            "|0|==||  /  \\                /  \\  ||==|0|",
            "|0|=='|  |--|                |--|  |`==|0|",
            " \\0__0|  |  |                |  |  |0__0/",
            "         |__|                |__|",
            "         /||\\                /||\\",
            "          ||                  ||",
            "         /--\\                /--\\",
            "        /____\\              /____\\",
            "     ____----_              _----____",
            "    /|___|  |_|            |_|  |___|\\",
            "   /__/ _|__|_              _|__|_ \\__\\",
        },
    },
};

/// Draw the splash centred on the screen.
pub fn draw(s: *Screen, ascii: bool, index: usize) void {
    s.clear();
    const m = mechs[index];
    const t: []const []const u8 = if (ascii) &title_ascii else &title;
    const total_h: i32 = @intCast(t.len + 2 + m.art.len + 3);
    var y: i32 = @max(1, @divTrunc(@as(i32, s.rows) - total_h, 2));
    for (t) |line| {
        const w: i32 = @intCast(screen_mod.visibleLen(line));
        _ = s.text(@max(0, @divTrunc(@as(i32, s.cols) - w, 2)), y, s.cols, line, .amber);
        y += 1;
    }
    y += 1;
    const tw: i32 = @intCast(tagline.len);
    _ = s.text(@max(0, @divTrunc(@as(i32, s.cols) - tw, 2)), y, s.cols, tagline, .dim);
    y += 2;
    // Centre the figure as a block: every row starts at the same column.
    var mech_w: i32 = 0;
    for (m.art) |line| mech_w = @max(mech_w, @as(i32, @intCast(line.len)));
    const mech_x: i32 = @max(0, @divTrunc(@as(i32, s.cols) - mech_w, 2));
    for (m.art) |line| {
        _ = s.text(mech_x, y, s.cols, line, .normal);
        y += 1;
    }
    y += 1;
    const hint = "press any key";
    _ = s.text(@max(0, @divTrunc(@as(i32, s.cols) - @as(i32, hint.len), 2)), @min(y, @as(i32, s.rows) - 1), s.cols, hint, .dim);
    // The game credit sits in the bottom-left corner, the art credit in the bottom-right.
    _ = s.text(1, @as(i32, s.rows) - 1, s.cols, credit_game, .dim);
    _ = s.text(@max(0, @as(i32, s.cols) - @as(i32, credit_art.len) - 1), @as(i32, s.rows) - 1, s.cols, credit_art, .dim);
}

test "every splash mech and both titles fit a 200x50 frame" {
    var s = try Screen.init(std.testing.allocator, 200, 50);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 4), mechs.len);
    for (mechs, 0..) |mech, i| {
        draw(&s, false, i);
        draw(&s, true, i);
        for (mech.art) |row| try std.testing.expect(row.len <= 60);
        // The game credit is anchored to the bottom-left corner, in .dim.
        for (credit_game, 0..) |byte, k| {
            const c = s.get(1 + @as(u16, @intCast(k)), s.rows - 1);
            try std.testing.expectEqual(@as(u21, byte), c.ch);
            try std.testing.expectEqual(screen_mod.Style.dim, c.style);
        }
        // The art credit is anchored to the bottom-right corner, in .dim.
        const art_x: u16 = @intCast(@as(usize, s.cols) - credit_art.len - 1);
        for (credit_art, 0..) |byte, k| {
            const c = s.get(art_x + @as(u16, @intCast(k)), s.rows - 1);
            try std.testing.expectEqual(@as(u21, byte), c.ch);
            try std.testing.expectEqual(screen_mod.Style.dim, c.style);
        }
        // The mech name is no longer captioned anywhere on the frame.
        var named = false;
        var yy: u16 = 0;
        while (yy < s.rows) : (yy += 1) {
            var xx: u16 = 0;
            while (@as(usize, xx) + mech.name.len <= s.cols) : (xx += 1) {
                var match = true;
                for (mech.name, 0..) |byte, k| {
                    if (s.get(xx + @as(u16, @intCast(k)), yy).ch != @as(u21, byte)) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    named = true;
                    break;
                }
            }
            if (named) break;
        }
        try std.testing.expect(!named);
    }
    for (title) |row| try std.testing.expect(screen_mod.visibleLen(row) <= 90);
}
