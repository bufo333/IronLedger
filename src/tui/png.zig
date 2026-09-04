//! Minimal PNG decoder for emblem import (docs/tui.md "Emblems"): 8-bit
//! greyscale / RGB / RGBA / palette, non-interlaced, all five scanline
//! filters. Enough for a crest dropped into the logos directory; anything
//! fancier (16-bit, interlaced) is refused with a clear error. Output is
//! packed RGB. No MekHQ counterpart.

const std = @import("std");
const flate = std.compress.flate;

pub const Image = struct {
    width: u32,
    height: u32,
    /// width × height × 3 bytes, row-major.
    rgb: []u8,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.rgb);
    }

    pub fn pixel(self: *const Image, x: u32, y: u32) [3]u8 {
        const i = (@as(usize, y) * self.width + x) * 3;
        return .{ self.rgb[i], self.rgb[i + 1], self.rgb[i + 2] };
    }
};

pub const Error = error{
    NotPng,
    Unsupported,
    Corrupt,
} || std.mem.Allocator.Error;

const signature = "\x89PNG\r\n\x1a\n";

pub fn isPng(bytes: []const u8) bool {
    return bytes.len > 8 and std.mem.eql(u8, bytes[0..8], signature);
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (!isPng(bytes)) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var palette: []const u8 = &.{};
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(alloc);

    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 .. pos + 8];
        pos += 8;
        if (pos + len + 4 > bytes.len) return error.Corrupt;
        const data = bytes[pos .. pos + len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = data[9];
            if (data[12] != 0) return error.Unsupported; // interlaced
            if (depth != 8) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        pos += len + 4; // skip CRC
    }
    if (width == 0 or height == 0 or idat.items.len == 0) return error.Corrupt;
    const channels: u32 = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    if (color == 3 and palette.len == 0) return error.Corrupt;
    if (@as(u64, width) * height > 64 * 1024 * 1024) return error.Unsupported;

    // Inflate the concatenated IDAT stream.
    var in = std.Io.Reader.fixed(idat.items);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var dec = flate.Decompress.init(&in, .zlib, window);
    const stride: usize = @as(usize, width) * channels;
    const expected: usize = (stride + 1) * height;
    const raw = dec.reader.allocRemaining(alloc, .limited(expected + 1)) catch return error.Corrupt;
    defer alloc.free(raw);
    if (raw.len < expected) return error.Corrupt;

    // Unfilter in place (scanline by scanline), then convert to RGB.
    const bpp: usize = channels;
    const rgb = try alloc.alloc(u8, @as(usize, width) * height * 3);
    errdefer alloc.free(rgb);
    var prev: []u8 = try alloc.alloc(u8, stride);
    defer alloc.free(prev);
    @memset(prev, 0);
    var cur: []u8 = try alloc.alloc(u8, stride);
    defer alloc.free(cur);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        const ft = line[0];
        @memcpy(cur, line[1..]);
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: u16 = if (i >= bpp) cur[i - bpp] else 0;
            const b: u16 = prev[i];
            const c: u16 = if (i >= bpp) prev[i - bpp] else 0;
            const add: u16 = switch (ft) {
                0 => 0,
                1 => a,
                2 => b,
                3 => (a + b) / 2,
                4 => paeth(a, b, c),
                else => return error.Corrupt,
            };
            cur[i] = @intCast((@as(u16, cur[i]) + add) & 0xff);
        }
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const src = cur[x * channels ..];
            const dst = rgb[(y * width + x) * 3 ..][0..3];
            switch (color) {
                0, 4 => {
                    dst[0] = src[0];
                    dst[1] = src[0];
                    dst[2] = src[0];
                },
                2, 6 => {
                    dst[0] = src[0];
                    dst[1] = src[1];
                    dst[2] = src[2];
                },
                3 => {
                    const idx: usize = src[0];
                    if (idx * 3 + 2 >= palette.len) return error.Corrupt;
                    dst[0] = palette[idx * 3];
                    dst[1] = palette[idx * 3 + 1];
                    dst[2] = palette[idx * 3 + 2];
                },
                else => unreachable,
            }
        }
        std.mem.swap([]u8, &prev, &cur);
    }
    return .{ .width = width, .height = height, .rgb = rgb };
}

fn paeth(a: u16, b: u16, c: u16) u16 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "decodes an RGB PNG using the none, sub and up filters" {
    const bytes = @embedFile("testdata/rgb4x3.png");
    var img = try decode(std.testing.allocator, bytes);
    defer img.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 3), img.height);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, img.pixel(0, 0));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, img.pixel(3, 0));
    try std.testing.expectEqual([3]u8{ 40, 50, 60 }, img.pixel(1, 1));
    try std.testing.expectEqual([3]u8{ 128, 128, 128 }, img.pixel(1, 2));
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, img.pixel(3, 2));
    try std.testing.expectError(error.NotPng, decode(std.testing.allocator, "not a png"));
}
