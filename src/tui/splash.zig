//! Title screen (Stage 12): the game's name and a BattleMech in ASCII,
//! held for five seconds at start or until a key is pressed. Pure drawing
//! into the cell grid; the wait loop lives in app.zig.

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

/// A heavy 'Mech, three-quarter view, ~26 rows × 58 columns.
pub const mech = [_][]const u8{
    "                         ______                           ",
    "                    ____/      \\____                      ",
    "                   |    |  __  |    |                     ",
    "                   |____| |__| |____|         /\\          ",
    "               ___/  [=====||=====]  \\___    //\\\\         ",
    "              /   |   \\ ________ /   |   \\  //  \\\\        ",
    "             / /| |    |  o  o  |    | |\\ \\//    \\\\       ",
    "            / / | |    |________|    | | \\ /      \\\\      ",
    "           / /  | |   /|   ||   |\\   | |  \\        \\\\     ",
    "     _____/ /   | |  / |___||___| \\  | |   \\____    \\\\    ",
    "    |  ___  |   | | /  |[]||||[]|  \\ | |   |  __|  __\\\\___",
    "    | |LRM| |   | |/   |[]||||[]|   \\| |   | |__|  \\__  __/",
    "    | |20 | |   |  |   |[]||||[]|   |  |   |  __|     ||  ",
    "    | |___| |   |  |   |__||||__|   |  |   | |__|     ||  ",
    "    |_______|   |__|   |  ||||  |   |__|   |____|   __||__",
    "       | |       | |   |  ||||  |   | |       | |   |______|",
    "       | |       | |   |__||||__|   | |       | |          ",
    "       |_|      _| |___|  |  |  |___| |_      |_|          ",
    "               |___________|  |___________|                ",
    "                |    |    |    |    |    |                 ",
    "                |    |    |    |    |    |                 ",
    "                |    |    |    |    |    |                 ",
    "                |____|    |    |    |____|                 ",
    "               /     |    |    |    |     \\                ",
    "              /______|____|    |____|______\\               ",
    "             |_______________|_______________|              ",
};

/// Draw the splash centred on the screen.
pub fn draw(s: *Screen, ascii: bool) void {
    s.clear();
    const t: []const []const u8 = if (ascii) &title_ascii else &title;
    const total_h: i32 = @intCast(t.len + 2 + mech.len + 3);
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
    for (mech) |line| mech_w = @max(mech_w, @as(i32, @intCast(line.len)));
    const mech_x: i32 = @max(0, @divTrunc(@as(i32, s.cols) - mech_w, 2));
    for (mech) |line| {
        _ = s.text(mech_x, y, s.cols, line, .normal);
        y += 1;
    }
    y += 1;
    const hint = "press any key";
    _ = s.text(@max(0, @divTrunc(@as(i32, s.cols) - @as(i32, hint.len), 2)), @min(y, @as(i32, s.rows) - 1), s.cols, hint, .dim);
}

test "splash art fits a 200x50 frame and the mech rows share a width" {
    var s = try Screen.init(std.testing.allocator, 200, 50);
    defer s.deinit();
    draw(&s, false);
    draw(&s, true);
    for (mech) |row| try std.testing.expect(row.len <= 60);
    for (title) |row| try std.testing.expect(screen_mod.visibleLen(row) <= 90);
}
