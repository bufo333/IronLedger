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
const person_gen = @import("person_gen.zig");
const rival_mod = @import("../domain/rival.zig");

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

/// Roll identity fields for a world merc company (P3e.5a,
/// docs/p3c-economy-design.md §8.D). Pure: no allocation, no GameState.
/// Draws commander first/last from person_gen.names on the given stream.
/// Side and doctrine are derived from the archetype (same derivation as
/// rivals.generateRival). faction_key is accepted so the caller's signature
/// is stable when pool selection is added; pool selection (rollFactionPoolOne)
/// remains the caller's responsibility.
pub fn rollMercCompanyIdentity(
    rng: *rng_mod.Rng,
    stream: rng_mod.Stream,
    archetype: *const rival_mod.RivalArchetype,
    faction_key: []const u8,
) struct { first: []const u8, last: []const u8, side: rival_mod.FactionSide, doctrine: rival_mod.RivalDoctrine } {
    _ = faction_key;
    const r = rng.random(stream);
    const first = person_gen.names.first[r.uintLessThan(usize, person_gen.names.first.len)];
    const last = person_gen.names.last[r.uintLessThan(usize, person_gen.names.last.len)];
    const side = std.meta.stringToEnum(rival_mod.FactionSide, archetype.faction_side) orelse .employer;
    const doctrine = std.meta.stringToEnum(rival_mod.RivalDoctrine, archetype.doctrine) orelse .cautious;
    return .{ .first = first, .last = last, .side = side, .doctrine = doctrine };
}

test "rollMercCompanyIdentity: deterministic and side/doctrine match archetype" {
    // Table-driven: two archetypes, one representative invariant each.
    const archetypes = rival_mod.table.archetypes;
    try std.testing.expect(archetypes.len >= 2);

    // For each test archetype: same seed + stream + archetype → identical result;
    // side and doctrine exactly match the archetype's parsed values.
    for ([_]usize{ 0, 1 }) |ai| {
        const archetype = &archetypes[ai];
        var rng_a = rng_mod.Rng.init(54321);
        var rng_b = rng_mod.Rng.init(54321);
        const id_a = rollMercCompanyIdentity(&rng_a, .rivals, archetype, "LC");
        const id_b = rollMercCompanyIdentity(&rng_b, .rivals, archetype, "LC");
        try std.testing.expectEqualStrings(id_a.first, id_b.first);
        try std.testing.expectEqualStrings(id_a.last, id_b.last);
        try std.testing.expectEqual(id_a.side, id_b.side);
        try std.testing.expectEqual(id_a.doctrine, id_b.doctrine);
        // side and doctrine must match the archetype exactly.
        const expected_side = std.meta.stringToEnum(rival_mod.FactionSide, archetype.faction_side).?;
        const expected_doctrine = std.meta.stringToEnum(rival_mod.RivalDoctrine, archetype.doctrine).?;
        try std.testing.expectEqual(expected_side, id_a.side);
        try std.testing.expectEqual(expected_doctrine, id_a.doctrine);
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
