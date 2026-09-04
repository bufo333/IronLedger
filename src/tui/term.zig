//! Terminal layer for the TUI (Stage 12, docs/tui.md "Rendering"): raw
//! mode, the alternate screen, window size, key decoding and the resize
//! signal. Hand-rolled ANSI on purpose — no dependency, ~300 lines, and
//! swappable behind this interface if libvaxis tracks Zig 0.16 later.
//! No MekHQ counterpart (MekHQ is Swing).

const std = @import("std");
const posix = std.posix;

pub const Size = struct { cols: u16, rows: u16 };

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

var winch_flag = std.atomic.Value(bool).init(false);

fn onWinch(_: posix.SIG) callconv(.c) void {
    winch_flag.store(true, .seq_cst);
}

pub const Term = struct {
    in_fd: posix.fd_t,
    orig: posix.termios,
    out: *std.Io.Writer,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    /// Enter raw mode + alternate screen. `out` must outlive the Term.
    pub fn init(out: *std.Io.Writer) !Term {
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

        var act: posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.WINCH, &act, null);

        // Alternate screen, hide cursor, clear.
        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        try out.flush();
        return .{ .in_fd = fd, .orig = orig, .out = out };
    }

    pub fn deinit(self: *Term) void {
        self.out.writeAll("\x1b[0m\x1b[?25h\x1b[2J\x1b[H\x1b[?1049l") catch {};
        self.out.flush() catch {};
        posix.tcsetattr(self.in_fd, .FLUSH, self.orig) catch {};
    }

    pub fn size(self: *Term) Size {
        _ = self;
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
        return .{ .cols = ws.col, .rows = ws.row };
    }

    /// True once after every window resize.
    pub fn tookResize(self: *Term) bool {
        _ = self;
        return winch_flag.swap(false, .seq_cst);
    }

    fn fill(self: *Term, timeout_ms: i32) bool {
        if (self.pending_len > 0) return true;
        var fds = [_]posix.pollfd{.{ .fd = self.in_fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return false;
        if (n == 0) return false;
        const got = posix.read(self.in_fd, &self.pending) catch return false;
        self.pending_len = got;
        return got > 0;
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
        self.out.writeAll(query) catch return 0;
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
                    num = num * 10 + (c - '0');
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
