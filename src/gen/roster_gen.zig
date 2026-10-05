//! Faction hull-pool roller (P3e.4, docs/p3c-economy-design.md §3/§4).
//! Pure: takes an injected RNG and stream; produces chassis from the RAT.
//! The caller (roster_seed.zig) owns stream selection and GameState mutation.
//! No MekHQ counterpart: campaign-start roster seeding is specific to this
//! implementation (docs/mekhq-map.md).

const std = @import("std");
const chassis = @import("../domain/chassis.zig");
const rat = @import("../domain/rat.zig");
const company_gen = @import("company_gen.zig");
const rng_mod = @import("../sim/rng.zig");

/// Roll one chassis for a faction's hull pool.
/// Draws weight class via the RAT 2d6 distribution (`company_gen.rollWeightClass`),
/// then a chassis via `rat.roll`. Returns static catalogue memory.
pub fn rollFactionPoolOne(
    rng: *rng_mod.Rng,
    stream: rng_mod.Stream,
    faction_key: []const u8,
    year: u16,
) *const chassis.Chassis {
    const class = company_gen.rollWeightClass(rng, stream);
    return rat.roll(rng, stream, faction_key, class, year);
}

/// Roll `out.len` chassis keys for a faction's hull pool.
/// For each hull: draw weight class then chassis, hull by hull in fixed order
/// so the stream is deterministic. Stores static catalogue key pointers — no
/// allocation.
pub fn rollFactionPool(
    rng: *rng_mod.Rng,
    stream: rng_mod.Stream,
    faction_key: []const u8,
    year: u16,
    out: [][]const u8,
) void {
    for (out) |*slot| {
        slot.* = rollFactionPoolOne(rng, stream, faction_key, year).key;
    }
}

test "rollFactionPool: same seed+stream+faction+year produces identical pool" {
    const alloc = std.testing.allocator;
    const keys_a = try alloc.alloc([]const u8, 24);
    defer alloc.free(keys_a);
    const keys_b = try alloc.alloc([]const u8, 24);
    defer alloc.free(keys_b);

    var rng_a = rng_mod.Rng.init(12345);
    var rng_b = rng_mod.Rng.init(12345);
    rollFactionPool(&rng_a, .rosters, "LC", 3025, keys_a);
    rollFactionPool(&rng_b, .rosters, "LC", 3025, keys_b);

    for (keys_a, keys_b) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "rollFactionPool: every key resolves to a mek available in the year" {
    var keys: [24][]const u8 = undefined;
    var rng = rng_mod.Rng.init(99999);
    rollFactionPool(&rng, .rosters, "DC", 3025, &keys);

    for (keys) |key| {
        const c = chassis.find(key) orelse {
            std.debug.print("rollFactionPool: unknown chassis key {s}\n", .{key});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(c.kind == .mek);
        try std.testing.expect(chassis.availableIn(c, 3025));
    }
}
