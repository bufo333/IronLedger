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

    const count = @typeInfo(Stream).@"enum".fields.len;
};

pub const Rng = struct {
    prngs: [Stream.count]std.Random.DefaultPrng,

    pub fn init(seed: u64) Rng {
        var self: Rng = undefined;
        for (&self.prngs, 0..) |*prng, i| {
            // Distinct, stable derivation per stream.
            prng.* = std.Random.DefaultPrng.init(seed ^ (0x9E3779B97F4A7C15 *% (i + 1)));
        }
        return self;
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

test "2d6 stays in range" {
    var r = Rng.init(7);
    for (0..1000) |_| {
        const v = r.roll2d6(.events);
        try std.testing.expect(v >= 2 and v <= 12);
    }
}
