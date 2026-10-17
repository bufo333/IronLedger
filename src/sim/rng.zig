//! Deterministic RNG with named per-subsystem streams (ARCH §4).
//! Adding a roll in one system must never perturb another, so every
//! subsystem draws from its own stream. All combat/campaign dice are 2d6.
//! MekHQ counterpart: MegaMek's `Compute` dice; here every roll draws from a
//! named, seeded stream (docs/mekhq-map.md).

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
    actors, // P4i: persistent actor identity and relationship seeds
    rivals, // P4i: persistent rival company identity seeds
    rosters, // P3e.4: faction hull-pool seeding at campaign creation
    politics, // personage generation at campaign creation

    pub const count = @typeInfo(Stream).@"enum".fields.len;

    /// Each stream's permanent seed salt. A stream's identity is its salt,
    /// not its place in this enum: reordering or adding streams changes no
    /// existing stream.
    pub fn salt(self: Stream) u64 {
        return switch (self) {
            .generation => 0x9E3779B97F4A7C15,
            .market => 0x3C6EF372FE94F82A,
            .maintenance => 0xDAA66D2C7DDF743F,
            .acquisition => 0x78DDE6E5FD29F054,
            .battle => 0x1715609F7C746C69,
            .events => 0xB54CDA58FBBEE87E,
            .medical => 0x538454127B096493,
            .travel => 0xF1BBCDCBFA53E0A8,
            .actors => 0xC2B2AE3D27D4EB4F, // P4i actor identity generation
            .rivals => 0xA3F84D2E6B1C9057, // P4i rival company identity generation
            .rosters => 0xBF58476D1CE4E5B9, // P3e.4 faction hull-pool seeding (save-meaning)
            .politics => 0x94D049BB133111EB, // personage generation (save-meaning)
        };
    }
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
        return std.Random.DefaultPrng.init(seed ^ stream.salt());
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

    /// The BattleTech die roll, `roll2d6_min` to `roll2d6_max`.
    pub fn roll2d6(self: *Rng, stream: Stream) u8 {
        const r = self.random(stream);
        return r.intRangeAtMost(u8, 1, 6) + r.intRangeAtMost(u8, 1, 6);
    }
};

/// The range of `Rng.roll2d6`.
pub const roll2d6_min: u8 = 2;
pub const roll2d6_max: u8 = 12;

/// Returns a deterministic seed whose first roll on `stream` is `want`, or null
/// when `want` is outside the 2d6 range.
pub fn seedForFirstRoll(stream: Stream, want: u8) ?u64 {
    if (want < roll2d6_min or want > roll2d6_max) return null;
    var seed: u64 = 0;
    while (true) : (seed += 1) {
        var rng = Rng.init(seed);
        if (rng.roll2d6(stream) == want) return seed;
    }
}

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
        try std.testing.expect(v >= roll2d6_min and v <= roll2d6_max);
    }
}

test "seedForFirstRoll produces the requested stream roll" {
    const seed = seedForFirstRoll(.maintenance, 10).?;
    var rng = Rng.init(seed);
    try std.testing.expectEqual(@as(u8, 10), rng.roll2d6(.maintenance));
    try std.testing.expectEqual(@as(?u64, null), seedForFirstRoll(.maintenance, 1));
    try std.testing.expectEqual(@as(?u64, null), seedForFirstRoll(.maintenance, 13));
}

test "stream salts are distinct and independent of enum order" {
    for (std.enums.values(Stream), 0..) |a, i| {
        for (std.enums.values(Stream)[i + 1 ..]) |b| try std.testing.expect(a.salt() != b.salt());
    }
    // Pinned: a salt is part of every saved seed's meaning, so changing
    // one would change what existing saves draw.
    try std.testing.expectEqual(@as(u64, 0x1715609F7C746C69), Stream.battle.salt());
    // P4i: actor stream salt pinned.
    try std.testing.expectEqual(@as(u64, 0xC2B2AE3D27D4EB4F), Stream.actors.salt());
    // P4i: rivals stream salt pinned.
    try std.testing.expectEqual(@as(u64, 0xA3F84D2E6B1C9057), Stream.rivals.salt());
    // P3e.4: rosters stream salt pinned.
    try std.testing.expectEqual(@as(u64, 0xBF58476D1CE4E5B9), Stream.rosters.salt());
    // The politics stream salt pinned.
    try std.testing.expectEqual(@as(u64, 0x94D049BB133111EB), Stream.politics.salt());
}

test "every stream's first draw for a fixed seed is pinned" {
    // Rule 57: adding a stream leaves every existing stream's draws as they
    // were. Each value is the stream's first u64 for seed 3025.
    const pinned = [_]struct { Stream, u64 }{
        .{ .generation, 1013896583676193370 },
        .{ .market, 2261206037223925633 },
        .{ .maintenance, 6077392954855604654 },
        .{ .acquisition, 15381688641334404543 },
        .{ .battle, 16073282218357221649 },
        .{ .events, 3679913571991931764 },
        .{ .medical, 6179152037605412326 },
        .{ .travel, 12936974518335990171 },
        .{ .actors, 1676454171681377804 },
        .{ .rivals, 16628555082215552019 },
        .{ .rosters, 16870582734659653342 },
        .{ .politics, 2700404483974280841 },
    };
    try std.testing.expectEqual(Stream.count, pinned.len);
    var rng = Rng.init(3025);
    for (pinned) |entry| try std.testing.expectEqual(entry[1], rng.random(entry[0]).int(u64));
}
