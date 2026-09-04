//! Emblem display (docs/tui.md "Emblems"): the outfit's crest as a real
//! picture where the terminal speaks the kitty graphics protocol (kitty,
//! Ghostty, WezTerm, Konsole), and as half-block colour cells everywhere
//! else. Also the logos-directory listing for the wizard's import step.
//! I/O lives here and in term.zig only. No MekHQ counterpart.

const std = @import("std");
const png = @import("png.zig");

pub const Graphics = enum { none, kitty };

pub const Emblem = struct {
    /// The original file bytes (what the campaign stores and kitty receives).
    bytes: []u8,
    img: png.Image,
    kitty_id: u32,

    pub fn load(gpa: std.mem.Allocator, bytes: []const u8, kitty_id: u32) !Emblem {
        const img = try png.decode(gpa, bytes);
        errdefer {
            var i = img;
            i.deinit(gpa);
        }
        const copy = try gpa.dupe(u8, bytes);
        return .{ .bytes = copy, .img = img, .kitty_id = kitty_id };
    }

    pub fn deinit(self: *Emblem, gpa: std.mem.Allocator) void {
        self.img.deinit(gpa);
        gpa.free(self.bytes);
    }
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// 24-bit colour SGR is safe to emit here.
pub fn detectTruecolor() bool {
    if (env("COLORTERM")) |c| {
        if (std.mem.indexOf(u8, c, "truecolor") != null or std.mem.indexOf(u8, c, "24bit") != null) return true;
    }
    if (env("TERM_PROGRAM")) |p| {
        for ([_][]const u8{ "ghostty", "iTerm", "WezTerm", "kitty", "Alacritty", "vscode" }) |k| {
            if (std.ascii.indexOfIgnoreCase(p, k) != null) return true;
        }
    }
    if (env("TERM")) |t| {
        if (std.mem.indexOf(u8, t, "kitty") != null or std.mem.indexOf(u8, t, "ghostty") != null or std.mem.indexOf(u8, t, "direct") != null) return true;
    }
    return false;
}

// ---------------------------------------------------------- kitty protocol

const chunk_len = 4096;

/// Transmit a PNG once under `id` (a=t: store only, no placement).
pub fn kittyTransmit(out: *std.Io.Writer, gpa: std.mem.Allocator, id: u32, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(bytes.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, bytes);
    var pos: usize = 0;
    var first = true;
    while (pos < b64.len) {
        const end = @min(pos + chunk_len, b64.len);
        const more: u8 = if (end < b64.len) 1 else 0;
        if (first) {
            try out.print("\x1b_Ga=t,f=100,i={d},q=2,m={d};", .{ id, more });
            first = false;
        } else {
            try out.print("\x1b_Gm={d};", .{more});
        }
        try out.writeAll(b64[pos..end]);
        try out.writeAll("\x1b\\");
        pos = end;
    }
    try out.flush();
}

/// Place the stored image over a cell rectangle (0-based x/y).
pub fn kittyPlace(out: *std.Io.Writer, id: u32, x: u16, y: u16, cols: u16, rows: u16) !void {
    try out.print("\x1b[{d};{d}H\x1b_Ga=p,i={d},c={d},r={d},q=2\x1b\\", .{ y + 1, x + 1, id, cols, rows });
}

/// Remove every visible placement (images stay stored).
pub fn kittyDeleteAll(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b_Ga=d,d=a,q=2\x1b\\");
}

pub fn kittyForget(out: *std.Io.Writer, id: u32) !void {
    try out.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id});
}

/// The kitty graphics query: a 1×1 direct-colour image with id 31; a
/// supporting terminal answers `\x1b_Gi=31;OK\x1b\\`.
pub const kitty_query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

pub fn kittyReplyOk(reply: []const u8) bool {
    return std.mem.indexOf(u8, reply, "_Gi=31;OK") != null;
}

// ------------------------------------------------------------ logo files

/// PNG files in `dir_path` (names only, sorted), owned by `alloc`.
pub fn listPngs(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(e.name, ".png")) continue;
        try out.append(alloc, try alloc.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

pub fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(32 * 1024 * 1024));
}

test "kitty reply detection and transmit chunking" {
    try std.testing.expect(kittyReplyOk("\x1b_Gi=31;OK\x1b\\"));
    try std.testing.expect(!kittyReplyOk("\x1b[?1;2c"));
    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const bytes = @embedFile("testdata/rgb4x3.png");
    try kittyTransmit(&w, std.testing.allocator, 7, bytes);
    const written = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b_Ga=t,f=100,i=7,q=2,m=0;"));
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b\\"));
}
