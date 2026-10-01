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

/// Upper pixel-count limit for imported emblems (rule 64).
/// 2048×2048 = 4,194,304 pixels; larger images are refused before any
/// decompression is attempted.
const max_emblem_pixels: u64 = 2048 * 2048;

/// Alpha-composite background colour (rule 41): opaque black.
/// PNG colour types 4 (grey+alpha) and 6 (RGBA) are blended against this
/// before the image is handed to the rest of the TUI.
const alpha_blend_bg = [3]u8{ 0, 0, 0 };

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
    var got_ihdr = false;

    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 .. pos + 8];
        pos += 8;
        if (pos + len + 4 > bytes.len) return error.Corrupt;
        const data = bytes[pos .. pos + len];

        // IHDR must be the first chunk (PNG spec chunk order rule); the
        // order check fires before CRC so test fixtures need no checksums.
        if (!got_ihdr and !std.mem.eql(u8, kind, "IHDR")) return error.Corrupt;

        // CRC covers the chunk type and data fields (PNG spec, chunk CRC rule).
        {
            var crc = std.hash.crc.Crc32.init();
            crc.update(kind);
            crc.update(data);
            const computed = crc.final();
            const stored = std.mem.readInt(u32, bytes[pos + len ..][0..4], .big);
            if (computed != stored) return error.Corrupt;
        }

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            got_ihdr = true;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = data[9];
            if (data[12] != 0) return error.Unsupported; // interlaced
            if (depth != 8) return error.Unsupported;
            // Refuse images that exceed the pixel limit before decompression
            // (rule 64; see `max_emblem_pixels`).
            if (@as(u64, width) * height > max_emblem_pixels) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        pos += len + 4; // advance past data and CRC
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

    // Inflate the concatenated IDAT stream.
    var in = std.Io.Reader.fixed(idat.items);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var dec = flate.Decompress.init(&in, .zlib, window);
    const stride: usize = @as(usize, width) * channels;
    const expected: usize = (stride + 1) * height;
    const raw = dec.reader.allocRemaining(alloc, .limited(expected + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    defer alloc.free(raw);
    if (raw.len != expected) return error.Corrupt;

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
                0 => {
                    dst[0] = src[0];
                    dst[1] = src[0];
                    dst[2] = src[0];
                },
                4 => {
                    // Greyscale + alpha: blend against `alpha_blend_bg` (black).
                    const a = src[1];
                    const g: u8 = @intCast((@as(u16, src[0]) * a + @as(u16, alpha_blend_bg[0]) * (255 - a)) / 255);
                    dst[0] = g;
                    dst[1] = g;
                    dst[2] = g;
                },
                2 => {
                    dst[0] = src[0];
                    dst[1] = src[1];
                    dst[2] = src[2];
                },
                6 => {
                    // RGBA: blend each channel against `alpha_blend_bg` (black).
                    const a = src[3];
                    dst[0] = @intCast((@as(u16, src[0]) * a + @as(u16, alpha_blend_bg[0]) * (255 - a)) / 255);
                    dst[1] = @intCast((@as(u16, src[1]) * a + @as(u16, alpha_blend_bg[1]) * (255 - a)) / 255);
                    dst[2] = @intCast((@as(u16, src[2]) * a + @as(u16, alpha_blend_bg[2]) * (255 - a)) / 255);
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

test "CRC mismatch rejects the chunk" {
    // Minimal valid-structure PNG with a zeroed IHDR CRC.
    var buf: [8 + 8 + 13 + 4]u8 = undefined;
    @memcpy(buf[0..8], signature);
    std.mem.writeInt(u32, buf[8..12], 13, .big); // IHDR length
    @memcpy(buf[12..16], "IHDR");
    std.mem.writeInt(u32, buf[16..20], 1, .big); // width = 1
    std.mem.writeInt(u32, buf[20..24], 1, .big); // height = 1
    buf[24] = 8;
    buf[25] = 2;
    buf[26] = 0;
    buf[27] = 0;
    buf[28] = 0;
    @memset(buf[29..33], 0); // bad CRC
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, &buf));
}

test "chunk before IHDR rejects as corrupt" {
    // IDAT before IHDR (order check fires before CRC check).
    var buf: [8 + 8 + 0 + 4]u8 = undefined;
    @memcpy(buf[0..8], signature);
    std.mem.writeInt(u32, buf[8..12], 0, .big); // length = 0
    @memcpy(buf[12..16], "IDAT");
    @memset(buf[16..20], 0); // CRC placeholder
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, &buf));
}

test "inflate stream longer than expected is rejected" {
    const bytes = @embedFile("testdata/inflate_long.png");
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, bytes));
}

test "RGBA PNG blends alpha against a black background" {
    const bytes = @embedFile("testdata/rgba2x1.png");
    var img = try decode(std.testing.allocator, bytes);
    defer img.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    // Pixel 0: fully opaque red — unchanged.
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, img.pixel(0, 0));
    // Pixel 1: RGBA (200, 100, 50, 128) blended against black.
    // R = 200*128/255 = 100, G = 100*128/255 = 50, B = 50*128/255 = 25.
    try std.testing.expectEqual([3]u8{ 100, 50, 25 }, img.pixel(1, 0));
}

test "decode preserves OutOfMemory instead of mapping it to Corrupt" {
    const bytes = @embedFile("testdata/rgb4x3.png");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, png_bytes: []const u8) !void {
            var img = try decode(alloc, png_bytes);
            img.deinit(alloc);
        }
    }.run, .{bytes});
}
