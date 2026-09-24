//! Deterministic RNG with named per-subsystem streams (ARCH §4).
//! Adding a roll in one system must never perturb another, so every
//! subsystem draws from its own stream. All combat/campaign dice are 2d6.

const std = @import("std");

pub const Stream = enum(u8) {
    generation, // company/person/name generation
    market, // contract/personnel/unit market rolls
    maintenance,
    acquisition,
    battle,
    events,
    medical,
    travel,

    pub const count = @typeInfo(Stream).@"enum".fields.len;
};

pub const Rng = struct {
    /// The campaign seed every stream starts from.
    seed: u64,
    prngs: [Stream.count]std.Random.DefaultPrng,

    /// Serialized stream state, format 1: the generator's four words,
    /// little-endian.
    pub const state_format: i64 = 1;
    pub const state_len = 32;

    pub fn init(seed: u64) Rng {
        var self: Rng = .{ .seed = seed, .prngs = undefined };
        for (&self.prngs, 0..) |*prng, i| prng.* = fresh(seed, @enumFromInt(i));
        return self;
    }

    /// A stream's starting state for a seed: distinct per stream, stable
    /// for a given seed.
    pub fn fresh(seed: u64, stream: Stream) std.Random.DefaultPrng {
        return std.Random.DefaultPrng.init(seed ^ (0x9E3779B97F4A7C15 *% (@as(u64, @intFromEnum(stream)) + 1)));
    }

    /// One stream's state in format 1.
    pub fn encode(self: *const Rng, stream: Stream) [state_len]u8 {
        var out: [state_len]u8 = undefined;
        for (self.prngs[@intFromEnum(stream)].s, 0..) |word, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], word, .little);
        return out;
    }

    /// Restore one stream from format-1 bytes; false when they are not.
    pub fn decode(self: *Rng, stream: Stream, format: i64, bytes: []const u8) bool {
        if (format != state_format or bytes.len != state_len) return false;
        for (&self.prngs[@intFromEnum(stream)].s, 0..) |*word, i| word.* = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
        return true;
    }

    pub fn random(self: *Rng, stream: Stream) std.Random {
        return self.prngs[@intFromEnum(stream)].random();
    }

    /// The BattleTech die roll.
    pub fn roll2d6(self: *Rng, stream: Stream) u8 {
        const r = self.random(stream);
        return r.intRangeAtMost(u8, 1, 6) + r.intRangeAtMost(u8, 1, 6);
    }
};

test "streams are independent and deterministic" {
    var a = Rng.init(42);
    var b = Rng.init(42);

    // Draw heavily from one stream in `a` only; another stream must still
    // match the untouched twin exactly.
    for (0..1000) |_| _ = a.roll2d6(.maintenance);
    for (0..10) |_| {
        try std.testing.expectEqual(b.roll2d6(.battle), a.roll2d6(.battle));
    }
}

test "a stream round-trips through its encoding" {
    var a = Rng.init(99);
    for (0..17) |_| _ = a.roll2d6(.market);
    var b = Rng.init(1);
    try std.testing.expect(b.decode(.market, Rng.state_format, &a.encode(.market)));
    for (0..10) |_| try std.testing.expectEqual(a.roll2d6(.market), b.roll2d6(.market));
    try std.testing.expect(!b.decode(.market, 2, &a.encode(.market)));
    try std.testing.expect(!b.decode(.market, Rng.state_format, "short"));
}

test "2d6 stays in range" {
    var r = Rng.init(7);
    for (0..1000) |_| {
        const v = r.roll2d6(.events);
        try std.testing.expect(v >= 2 and v <= 12);
    }
}
