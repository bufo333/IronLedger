//! Terminal layer for the TUI (Stage 12, docs/tui.md "Rendering"): raw
//! mode, the alternate screen, window size, key decoding and the resize
//! signal. Hand-rolled ANSI so the client has no dependency; a library
//! can replace it behind this interface.
//! No MekHQ counterpart (MekHQ is Swing) (docs/mekhq-map.md).
//! Platform-gated (rule 65): POSIX termios/SIGWINCH on macOS/Linux;
//! Windows console VT mode on Windows (resize by polling the console size).

const std = @import("std");
const posix = std.posix;
const native_os = @import("builtin").os.tag;

pub const Size = struct { cols: u16, rows: u16 };

/// A 24-bit colour for pixel cells.
pub const Rgb = [3]u8;

/// The SGR sequences the client paints with (rule 42: escapes live here).
pub const sgr = struct {
    pub const reset = "\x1b[0m";
    pub const dim = "\x1b[0;90m";
    pub const amber = "\x1b[0;33m";
    pub const good = "\x1b[0;32m";
    pub const crit = "\x1b[0;31m";
    pub const sel = "\x1b[0;30;46m";
    pub const tab = "\x1b[0;1;30;43m";
    pub const purple = "\x1b[0;35m";
    pub const box = "\x1b[0;37m";
    pub const focus = "\x1b[0;36m";
    pub const blue = "\x1b[0;94m";
    pub const red = "\x1b[0;91m";
    pub const yellow = "\x1b[0;93m";
    pub const green = "\x1b[0;92m";
    pub const magenta = "\x1b[0;95m";
    pub const cyan = "\x1b[0;96m";
    pub const white = "\x1b[0;97m";
    pub const grey = "\x1b[0;90m";
};

pub fn cursorHome(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[H");
}

/// Move to a 1-based row and column.
pub fn cursorTo(out: *std.Io.Writer, row: u16, col: u16) !void {
    try out.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn resetStyle(out: *std.Io.Writer) !void {
    try out.writeAll(sgr.reset);
}

/// One glyph painted with a foreground and background colour: 24-bit, or
/// the nearest of the 256-colour cube.
pub fn paintPair(out: *std.Io.Writer, truecolor: bool, fg: Rgb, bg: Rgb, glyph: []const u8) !void {
    if (truecolor) {
        try out.print("\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}m{s}", .{ fg[0], fg[1], fg[2], bg[0], bg[1], bg[2], glyph });
    } else {
        try out.print("\x1b[0;38;5;{d};48;5;{d}m{s}", .{ c256(fg), c256(bg), glyph });
    }
}

fn c256(c: Rgb) u8 {
    const r: u8 = @intCast((@as(u16, c[0]) * 5 + 127) / 255);
    const g: u8 = @intCast((@as(u16, c[1]) * 5 + 127) / 255);
    const b: u8 = @intCast((@as(u16, c[2]) * 5 + 127) / 255);
    return 16 + 36 * r + 6 * g + b;
}

test "paintPair picks the cube index for 256 colours" {
    try std.testing.expectEqual(@as(u8, 16), c256(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 231), c256(.{ 255, 255, 255 }));
}

test "CSI digit overflow saturates and produces .escape, not undefined behaviour" {
    // An overlong CSI digit string must not overflow; saturating arithmetic
    // yields a value outside all named cases, which maps to .escape (rule 64).
    // The entire sequence fits in `pending`, so `fill` never reads `in_fd`.
    var t: Term = .{
        .in_fd = posix.STDIN_FILENO,
        .orig = undefined, // not read in readKey
        .out = undefined, // not read in readKey
    };
    const seq = "\x1b[99999999999999999999~";
    @memcpy(t.pending[0..seq.len], seq);
    t.pending_len = seq.len;
    const key = t.readKey(100);
    try std.testing.expect(key == .escape);
}

pub const Key = union(enum) {
    char: u21,
    enter,
    escape,
    tab,
    backtab,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    pgup,
    pgdn,
    f: u8, // F1..F12
    ctrl: u8, // 'a'..'z'
    /// Nothing arrived before the timeout.
    none,
};

// ---------------------------------------------------------------------------
// POSIX-only globals (macOS/Linux).
// ---------------------------------------------------------------------------

/// Atomic flag set by the SIGWINCH handler; consumed by tookResize().
var winch_flag: if (native_os != .windows) std.atomic.Value(bool) else void =
    if (native_os != .windows) std.atomic.Value(bool).init(false) else {};

fn onWinch(_: posix.SIG) callconv(.c) void {
    // Guarded: only stores on POSIX; comptime-false on Windows.
    if (native_os != .windows) winch_flag.store(true, .seq_cst);
}

// ---------------------------------------------------------------------------
// Windows console API declarations (Win32 API Reference, kernel32.dll).
// These declarations compile on all platforms but are only linked when called,
// which is gated on native_os == .windows throughout this file.
// ---------------------------------------------------------------------------

const win_con = struct {
    /// SMALL_RECT — console window rectangle (Win32 API Reference: SMALL_RECT)
    const SMALL_RECT = extern struct {
        Left: std.os.windows.SHORT,
        Top: std.os.windows.SHORT,
        Right: std.os.windows.SHORT,
        Bottom: std.os.windows.SHORT,
    };
    /// CONSOLE_SCREEN_BUFFER_INFO — console buffer info (Win32 API Reference: CONSOLE_SCREEN_BUFFER_INFO)
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: std.os.windows.COORD,
        dwCursorPosition: std.os.windows.COORD,
        wAttributes: std.os.windows.WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: std.os.windows.COORD,
    };
    /// GetStdHandle — retrieve a handle for stdin/stdout/stderr (Win32 API Reference: GetStdHandle)
    extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
    /// GetConsoleMode — query current console mode flags (Win32 API Reference: GetConsoleMode)
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    /// SetConsoleMode — set console mode flags (Win32 API Reference: SetConsoleMode)
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    /// GetConsoleScreenBufferInfo — query size and cursor (Win32 API Reference: GetConsoleScreenBufferInfo)
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        hConsoleOutput: std.os.windows.HANDLE,
        lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) std.os.windows.BOOL;

    // GetStdHandle nStdHandle values (Win32 API Reference: GetStdHandle)
    const STD_INPUT_HANDLE: std.os.windows.DWORD = 0xFFFFFFF6; // (DWORD)(-10)
    const STD_OUTPUT_HANDLE: std.os.windows.DWORD = 0xFFFFFFF5; // (DWORD)(-11)
    // Input mode flags (Win32 API Reference: SetConsoleMode)
    const ENABLE_ECHO_INPUT: std.os.windows.DWORD = 0x0004;
    const ENABLE_LINE_INPUT: std.os.windows.DWORD = 0x0002;
    const ENABLE_PROCESSED_INPUT: std.os.windows.DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: std.os.windows.DWORD = 0x0200;
};

// ---------------------------------------------------------------------------
// Term — platform-gated OS-touching members.
// ---------------------------------------------------------------------------

pub const Term = struct {
    // POSIX state (macOS/Linux); void with default {} on Windows.
    in_fd: if (native_os != .windows) posix.fd_t else void =
        if (native_os != .windows) undefined else {},
    orig: if (native_os != .windows) posix.termios else void =
        if (native_os != .windows) undefined else {},
    // Windows state; void with default {} on POSIX.
    in_handle: if (native_os == .windows) std.os.windows.HANDLE else void =
        if (native_os == .windows) undefined else {},
    out_handle: if (native_os == .windows) std.os.windows.HANDLE else void =
        if (native_os == .windows) undefined else {},
    orig_in_mode: if (native_os == .windows) std.os.windows.DWORD else void =
        if (native_os == .windows) undefined else {},
    orig_out_mode: if (native_os == .windows) std.os.windows.DWORD else void =
        if (native_os == .windows) undefined else {},
    /// Last observed console size for poll-based resize detection (Windows only).
    last_size: if (native_os == .windows) Size else void =
        if (native_os == .windows) Size{ .cols = 80, .rows = 24 } else {},
    // Shared fields.
    out: *std.Io.Writer,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    /// Enter raw mode + alternate screen. `out` must outlive the Term.
    pub fn init(out: *std.Io.Writer) !Term {
        if (native_os == .windows) {
            // Windows: use console VT mode (ENABLE_VIRTUAL_TERMINAL_PROCESSING
            // on output; ENABLE_VIRTUAL_TERMINAL_INPUT on input).
            const ih = win_con.GetStdHandle(win_con.STD_INPUT_HANDLE) orelse
                return error.NoConsole;
            const oh = win_con.GetStdHandle(win_con.STD_OUTPUT_HANDLE) orelse
                return error.NoConsole;
            var orig_in: std.os.windows.DWORD = 0;
            if (!win_con.GetConsoleMode(ih, &orig_in).toBool())
                return error.GetConsoleMode;
            var orig_out: std.os.windows.DWORD = 0;
            if (!win_con.GetConsoleMode(oh, &orig_out).toBool())
                return error.GetConsoleMode;
            // Raw VT input: disable echo, line buffering, and processed input;
            // enable virtual-terminal input so VT sequences arrive as bytes.
            const raw_in =
                (orig_in & ~(win_con.ENABLE_ECHO_INPUT | win_con.ENABLE_LINE_INPUT | win_con.ENABLE_PROCESSED_INPUT)) |
                win_con.ENABLE_VIRTUAL_TERMINAL_INPUT;
            _ = win_con.SetConsoleMode(ih, raw_in);
            // best-effort: restoring the input mode while init fails.
            errdefer _ = win_con.SetConsoleMode(ih, orig_in);
            // VT output: add ENABLE_VIRTUAL_TERMINAL_PROCESSING (std.os.windows:4487).
            _ = win_con.SetConsoleMode(oh, orig_out | std.os.windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            // best-effort: restoring the output mode while init fails.
            errdefer _ = win_con.SetConsoleMode(oh, orig_out);
            // Alternate screen, hide cursor, clear.
            // best-effort: restoring the terminal while init fails.
            errdefer out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
            try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
            try out.flush();
            var t: Term = .{
                .in_handle = ih,
                .out_handle = oh,
                .orig_in_mode = orig_in,
                .orig_out_mode = orig_out,
                .out = out,
            };
            t.last_size = t.size();
            return t;
        } else {
            // POSIX (macOS/Linux): termios raw mode + SIGWINCH.
            const fd = posix.STDIN_FILENO;
            const orig = try posix.tcgetattr(fd);
            var raw = orig;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.iflag.IXON = false;
            raw.iflag.ICRNL = false;
            raw.iflag.BRKINT = false;
            raw.iflag.ISTRIP = false;
            raw.oflag.OPOST = false;
            raw.cc[@intFromEnum(posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(posix.V.TIME)] = 0;
            try posix.tcsetattr(fd, .FLUSH, raw);
            // Until init returns, nothing else restores the terminal: every
            // step past raw mode undoes itself on failure.
            // best-effort: restoring the terminal while init fails.
            errdefer posix.tcsetattr(fd, .FLUSH, orig) catch {};

            var act: posix.Sigaction = .{
                .handler = .{ .handler = onWinch },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(.WINCH, &act, null);
            errdefer {
                var default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
                posix.sigaction(.WINCH, &default, null);
            }

            // Alternate screen, hide cursor, clear.
            // best-effort: restoring the terminal while init fails.
            errdefer out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
            try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
            try out.flush();
            return .{ .in_fd = fd, .orig = orig, .out = out };
        }
    }

    pub fn deinit(self: *Term) void {
        // best-effort: restoring the terminal on exit.
        self.out.writeAll("\x1b[0m\x1b[?25h\x1b[2J\x1b[H\x1b[?1049l") catch {};
        // best-effort: restoring the terminal on exit.
        self.out.flush() catch {};
        if (native_os == .windows) {
            // best-effort: restoring console modes on exit.
            _ = win_con.SetConsoleMode(self.in_handle, self.orig_in_mode);
            _ = win_con.SetConsoleMode(self.out_handle, self.orig_out_mode);
        } else {
            // best-effort: restoring the terminal on exit.
            posix.tcsetattr(self.in_fd, .FLUSH, self.orig) catch {};
        }
    }

    pub fn size(self: *Term) Size {
        if (native_os == .windows) {
            var info: win_con.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (!win_con.GetConsoleScreenBufferInfo(self.out_handle, &info).toBool())
                return .{ .cols = 80, .rows = 24 };
            const w = info.srWindow;
            const cols: u16 = @intCast(@max(0, @as(i32, w.Right) - w.Left + 1));
            const rows: u16 = @intCast(@max(0, @as(i32, w.Bottom) - w.Top + 1));
            if (cols == 0 or rows == 0) return .{ .cols = 80, .rows = 24 };
            return .{ .cols = cols, .rows = rows };
        } else {
            var ws: posix.winsize = undefined;
            const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
            if (rc != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
            return .{ .cols = ws.col, .rows = ws.row };
        }
    }

    /// True once after every window resize.
    pub fn tookResize(self: *Term) bool {
        if (native_os == .windows) {
            // Windows has no SIGWINCH; detect resize by comparing consecutive sizes.
            const current = self.size();
            if (current.cols != self.last_size.cols or current.rows != self.last_size.rows) {
                self.last_size = current;
                return true;
            }
            return false;
        } else {
            return winch_flag.swap(false, .seq_cst);
        }
    }

    fn fill(self: *Term, timeout_ms: i32) bool {
        if (self.pending_len > 0) return true;
        if (native_os == .windows) {
            // Wait for console input using NtWaitForSingleObject with a
            // relative timeout (negative 100-ns units; null = wait forever).
            const timeout: std.os.windows.LARGE_INTEGER =
                -@as(std.os.windows.LARGE_INTEGER, timeout_ms) * 10000;
            const wait_status = std.os.windows.ntdll.NtWaitForSingleObject(
                self.in_handle,
                .FALSE,
                if (timeout_ms < 0) null else &timeout,
            );
            if (wait_status != .SUCCESS) return false;
            // Read available bytes from the console handle.
            var iosb: std.os.windows.IO_STATUS_BLOCK = .{
                .u = .{ .Status = .SUCCESS },
                .Information = 0,
            };
            const read_status = std.os.windows.ntdll.NtReadFile(
                self.in_handle,
                null,
                null,
                null,
                &iosb,
                @ptrCast(&self.pending),
                self.pending.len,
                null,
                null,
            );
            // best-effort: a read failure means no input arrived.
            if (read_status != .SUCCESS) return false;
            self.pending_len = iosb.Information;
            return iosb.Information > 0;
        } else {
            var fds = [_]posix.pollfd{.{ .fd = self.in_fd, .events = posix.POLL.IN, .revents = 0 }};
            // best-effort: a poll failure means no input is ready.
            const n = posix.poll(&fds, timeout_ms) catch return false;
            if (n == 0) return false;
            // best-effort: a read failure means no input arrived.
            const got = posix.read(self.in_fd, &self.pending) catch return false;
            self.pending_len = got;
            return got > 0;
        }
    }

    fn take(self: *Term) ?u8 {
        if (self.pending_len == 0) return null;
        const b = self.pending[0];
        std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - 1], self.pending[1..self.pending_len]);
        self.pending_len -= 1;
        return b;
    }

    /// Raw bytes as they arrive (for protocol probes at startup).
    pub fn readRaw(self: *Term, buf: []u8, timeout_ms: i32) usize {
        var n: usize = 0;
        while (n < buf.len and self.fill(timeout_ms)) {
            buf[n] = self.take() orelse break;
            n += 1;
            if (self.pending_len == 0) {
                // drain anything that follows quickly
                if (!self.fill(30)) break;
            }
        }
        return n;
    }

    /// Ask the terminal a question and collect its reply for a short while.
    pub fn probe(self: *Term, query: []const u8, buf: []u8, timeout_ms: i32) usize {
        // best-effort: a probe that cannot be sent returns no reply.
        self.out.writeAll(query) catch return 0;
        // best-effort: a probe that cannot be flushed returns no reply.
        self.out.flush() catch return 0;
        return self.readRaw(buf, timeout_ms);
    }

    /// Decode one key, waiting up to `timeout_ms`.
    pub fn readKey(self: *Term, timeout_ms: i32) Key {
        if (!self.fill(timeout_ms)) return .none;
        const b = self.take() orelse return .none;
        return switch (b) {
            0x1b => self.readEscape(),
            '\r', '\n' => .enter,
            '\t' => .tab,
            0x7f, 0x08 => .backspace,
            1...7, 11, 12, 14...26 => .{ .ctrl = 'a' + b - 1 },
            else => self.readUtf8(b),
        };
    }

    fn readUtf8(self: *Term, first: u8) Key {
        const len = std.unicode.utf8ByteSequenceLength(first) catch return .{ .char = first };
        if (len == 1) return .{ .char = first };
        var buf: [4]u8 = undefined;
        buf[0] = first;
        var i: usize = 1;
        while (i < len) : (i += 1) {
            if (!self.fill(20)) return .{ .char = '?' };
            buf[i] = self.take() orelse return .{ .char = '?' };
        }
        const cp = std.unicode.utf8Decode(buf[0..len]) catch return .{ .char = '?' };
        return .{ .char = cp };
    }

    fn readEscape(self: *Term) Key {
        // A lone ESC arrives with nothing behind it; sequences follow fast.
        if (!self.fill(25)) return .escape;
        const b = self.take() orelse return .escape;
        if (b == 'O') {
            if (!self.fill(25)) return .escape;
            const c = self.take() orelse return .escape;
            return switch (c) {
                'P' => .{ .f = 1 },
                'Q' => .{ .f = 2 },
                'R' => .{ .f = 3 },
                'S' => .{ .f = 4 },
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                else => .escape,
            };
        }
        if (b != '[') return .escape;
        var num: u32 = 0;
        var have_num = false;
        while (true) {
            if (!self.fill(25)) return .escape;
            const c = self.take() orelse return .escape;
            switch (c) {
                '0'...'9' => {
                    num = num *| 10 +| (c - '0');
                    have_num = true;
                },
                ';' => {
                    // modifier parameter follows; ignore it
                    num = 0;
                    have_num = false;
                },
                'A' => return .up,
                'B' => return .down,
                'C' => return .right,
                'D' => return .left,
                'H' => return .home,
                'F' => return .end,
                'Z' => return .backtab,
                'P' => return .{ .f = 1 },
                'Q' => return .{ .f = 2 },
                'R' => return .{ .f = 3 },
                'S' => return .{ .f = 4 },
                '~' => return switch (num) {
                    1, 7 => .home,
                    2 => .escape,
                    3 => .delete,
                    4, 8 => .end,
                    5 => .pgup,
                    6 => .pgdn,
                    11 => .{ .f = 1 },
                    12 => .{ .f = 2 },
                    13 => .{ .f = 3 },
                    14 => .{ .f = 4 },
                    15 => .{ .f = 5 },
                    17 => .{ .f = 6 },
                    18 => .{ .f = 7 },
                    19 => .{ .f = 8 },
                    20 => .{ .f = 9 },
                    21 => .{ .f = 10 },
                    23 => .{ .f = 11 },
                    24 => .{ .f = 12 },
                    else => .escape,
                },
                else => return .escape,
            }
        }
    }
};
