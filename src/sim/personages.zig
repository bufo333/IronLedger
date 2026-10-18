//! World personages at campaign creation (docs/p5d-conflict-world-design.md
//! §B, P5d.1a): one procedural planetary ruler per hiring world and one
//! procedural leader per leader-bearing faction, and the load-time check
//! that a campaign holds exactly that set.
//! No MekHQ counterpart: MekHQ has no persistent political figures
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const planet = @import("../domain/planet.zig");
const faction = @import("../domain/faction.zig");
const personage = @import("../domain/personage.zig");
const personage_gen = @import("../gen/personage_gen.zig");
const personage_relations = @import("personage_relations.zig");
const table = @import("table.zig");
const rng_mod = @import("rng.zig");
const GameState = @import("state.zig").GameState;

/// Rulers seeded: one per world `personage.worldHasRuler` accepts.
pub const ruler_count: usize = blk: {
    @setEvalBranchQuota(200_000);
    var n: usize = 0;
    for (planet.catalog) |*world| {
        if (personage.worldHasRuler(world)) n += 1;
    }
    break :blk n;
};

/// Leaders seeded: one per faction `personage.factionHasLeader` accepts.
pub const leader_count: usize = blk: {
    @setEvalBranchQuota(20_000);
    var n: usize = 0;
    for (faction.table) |*f| {
        if (personage.factionHasLeader(f)) n += 1;
    }
    break :blk n;
};

pub const seed_count = ruler_count + leader_count;

comptime {
    if (seed_count > personage_gen.name_space)
        @compileError("data/tables/names.zon: first × last names are fewer than the personages seeded; every personage needs a distinct name");
}

/// Every procedural personage of a new campaign and their relations, drawn
/// and with `personages` and `personage_relations` capacity reserved, but
/// not yet on the books. `deinit` releases it, committed or not.
pub const Seeding = struct {
    rows: [seed_count]personage.Personage,
    /// `personage_relations.generate`'s rows, in operation scratch memory
    /// (rule 78).
    relations: []personage.Relation,
    /// `next_personage_id` before and after the seeded IDs.
    first_id: u32,
    next_id: u32,
    /// The `.politics` stream after every draw.
    politics: std.Random.DefaultPrng,

    pub fn deinit(self: *const Seeding, gs: *GameState) void {
        gs.scratch().free(self.relations);
    }
};

/// Draw every procedural personage of a new campaign and their relations,
/// and reserve room for them; `commitSeeding` puts them on the books.
/// Nothing in `gs` changes except `personages` and `personage_relations`
/// capacity, so campaign creation prepares this before its first mutation
/// and commits it after its last fallible step.
///
/// Draw order, all on `.politics`: one ruler per hiring world in
/// `planets.zon` catalogue order, then one leader per leader-bearing faction
/// in `factions.zon` order, each drawing `personage_gen.generate`'s sequence;
/// then, after the last personage, `personage_relations.generate`'s
/// sequence. IDs follow the personage order from `next_personage_id`. A
/// change to this order changes every campaign and needs a deliberate
/// re-pin.
///
/// `CorruptSave` when the ID counter cannot hold the seeded IDs;
/// `OutOfMemory` when a relation allocation or a reservation fails.
pub fn prepareSeeding(gs: *GameState) error{ CorruptSave, OutOfMemory }!Seeding {
    if (gs.next_personage_id > std.math.maxInt(u32) - seed_count) return error.CorruptSave;

    var rng_copy = gs.rng;
    var name_buf: [seed_count]u32 = undefined;
    var drawn = personage_gen.NameDraw.init(&name_buf);
    var s: Seeding = .{ .rows = undefined, .relations = &.{}, .first_id = gs.next_personage_id, .next_id = gs.next_personage_id, .politics = undefined };
    var len: usize = 0;
    for (planet.catalog) |*world| {
        if (!personage.worldHasRuler(world)) continue;
        s.rows[len] = procedural(&rng_copy, &drawn, @enumFromInt(s.next_id), .planetary_ruler, world.faction, world.key);
        s.next_id += 1;
        len += 1;
    }
    for (faction.table) |*f| {
        if (!personage.factionHasLeader(f)) continue;
        s.rows[len] = procedural(&rng_copy, &drawn, @enumFromInt(s.next_id), .faction_leader, f.key, f.capital);
        s.next_id += 1;
        len += 1;
    }
    std.debug.assert(len == seed_count);
    s.relations = try personage_relations.generate(gs.scratch(), &rng_copy, &s.rows);
    errdefer s.deinit(gs);
    s.politics = rng_copy.prngs[@intFromEnum(rng_mod.Stream.politics)];

    try gs.personages.ensureUnusedCapacity(gs.allocator(), seed_count);
    try gs.personage_relations.ensureUnusedCapacity(gs.allocator(), s.relations.len);
    return s;
}

/// Put a prepared seeding on the books: the rows and their relations, then
/// `next_personage_id` and the `.politics` stream. Infallible. Steps
/// between preparing and committing may draw other streams but must leave
/// `.politics`, `next_personage_id`, `personages` and `personage_relations`
/// alone.
pub fn commitSeeding(gs: *GameState, s: *const Seeding) void {
    std.debug.assert(gs.next_personage_id == s.first_id and gs.personages.count() == 0 and gs.personage_relations.items.len == 0);
    for (s.rows) |p| gs.personages.putAssumeCapacity(p.id, p);
    gs.personage_relations.appendSliceAssumeCapacity(s.relations);
    gs.next_personage_id = s.next_id;
    gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)] = s.politics;
}

/// Seat the personages of a campaign whose commander already exists, as
/// `create_commander` does. Tests only.
pub fn seedForTest(gs: *GameState) error{ CorruptSave, OutOfMemory }!void {
    std.debug.assert(@import("builtin").is_test);
    const s = try prepareSeeding(gs);
    defer s.deinit(gs);
    commitSeeding(gs, &s);
}

/// One procedural row; every string is static catalogue or names-table memory.
fn procedural(rng: *rng_mod.Rng, drawn: *personage_gen.NameDraw, id: types.PersonageId, role: personage.Role, faction_key: []const u8, seat: []const u8) personage.Personage {
    const g = personage_gen.generate(rng, .politics, drawn);
    return .{
        .id = id,
        .role = role,
        .first_name = g.first,
        .last_name = g.last,
        .faction_key = faction_key,
        .seat_planet_key = seat,
        .motives = g.motives,
        .ambition = g.ambition,
        .provenance = .procedural,
        .generator_version = personage_gen.version,
    };
}

/// A loaded campaign's personages are the seeded set and nothing else
/// (rule 47; docs/p5d-conflict-world-design.md §J "dangling refs"):
/// every key and seat resolves, a ruler sits on a hiring world of its own
/// faction, a leader on its leader-bearing faction's capital, no world or
/// faction has two, every character value is in range, and a campaign with
/// a commander covers every world and faction while one without holds
/// none. `CorruptSave` otherwise.
pub fn validate(gs: *const GameState) error{CorruptSave}!void {
    if (gs.commander == null and gs.personages.count() > 0) return error.CorruptSave;
    var ruled = [_]bool{false} ** planet.catalog.len;
    var led = [_]bool{false} ** faction.table.len;
    var it = gs.personages.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.id != entry.key_ptr.* or p.id == .none) return error.CorruptSave;
        if (p.first_name.len == 0 or p.last_name.len == 0) return error.CorruptSave;
        if (!table.markupSafe(p.first_name) or !table.markupSafe(p.last_name)) return error.CorruptSave;
        if (!personage.motivesValid(p.motives) or p.ambition > tuning.politics.ambition_max) return error.CorruptSave;
        switch (p.provenance) {
            .procedural => if (p.generator_version != personage_gen.version) return error.CorruptSave,
        }
        switch (p.role) {
            .planetary_ruler => {
                const at = worldIndex(p.seat_planet_key) orelse return error.CorruptSave;
                const world = &planet.catalog[at];
                if (!personage.worldHasRuler(world) or !std.mem.eql(u8, p.faction_key, world.faction)) return error.CorruptSave;
                if (ruled[at]) return error.CorruptSave;
                ruled[at] = true;
            },
            .faction_leader => {
                const at = factionIndex(p.faction_key) orelse return error.CorruptSave;
                const f = &faction.table[at];
                if (!personage.factionHasLeader(f) or !std.mem.eql(u8, p.seat_planet_key, f.capital)) return error.CorruptSave;
                if (led[at]) return error.CorruptSave;
                led[at] = true;
            },
        }
    }
    if (gs.commander == null) return;
    for (planet.catalog, ruled) |*world, has| if (personage.worldHasRuler(world) and !has) return error.CorruptSave;
    for (faction.table, led) |*f, has| if (personage.factionHasLeader(f) and !has) return error.CorruptSave;
}

fn worldIndex(key: []const u8) ?usize {
    for (planet.catalog, 0..) |w, i| if (std.mem.eql(u8, w.key, key)) return i;
    return null;
}

fn factionIndex(key: []const u8) ?usize {
    for (faction.table, 0..) |f, i| if (std.mem.eql(u8, f.key, key)) return i;
    return null;
}

// ---- Tests ----

const digest = @import("digest.zig");
const commands = @import("commands.zig");

const create_for_test: commands.Command = .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } };

fn createdForTest(gs: *GameState) !void {
    _ = try commands.execute(gs, create_for_test);
}

test "creation seats one ruler on every hiring world and one leader on every leader-bearing capital" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70101 });
    defer gs.deinit();
    try createdForTest(&gs);

    // Expected sets come from the static tables, not from literals.
    var hiring_worlds: usize = 0;
    for (planet.catalog) |*world| {
        var rulers: usize = 0;
        for (gs.personages.values()) |p| {
            if (p.role == .planetary_ruler and std.mem.eql(u8, p.seat_planet_key, world.key)) {
                rulers += 1;
                try std.testing.expectEqualStrings(world.faction, p.faction_key);
            }
        }
        const hires = faction.find(world.faction).?.hires;
        try std.testing.expectEqual(@as(usize, if (hires) 1 else 0), rulers);
        if (hires) hiring_worlds += 1;
    }
    var leader_factions: usize = 0;
    for (faction.table) |*f| {
        var leaders: usize = 0;
        for (gs.personages.values()) |p| {
            if (p.role == .faction_leader and std.mem.eql(u8, p.faction_key, f.key)) {
                leaders += 1;
                try std.testing.expectEqualStrings(f.capital, p.seat_planet_key);
            }
        }
        const expected: usize = if (f.hires and !std.mem.eql(u8, f.key, "PER")) 1 else 0;
        try std.testing.expectEqual(expected, leaders);
        leader_factions += expected;
    }
    // The ComStar world gets no ruler and the catch-all bucket no leader.
    for (gs.personages.values()) |p| {
        try std.testing.expect(!std.mem.eql(u8, p.faction_key, "CS"));
        if (p.role == .faction_leader) try std.testing.expect(!std.mem.eql(u8, p.faction_key, "PER"));
        try std.testing.expectEqual(personage.Provenance.procedural, p.provenance);
        try std.testing.expectEqual(personage_gen.version, p.generator_version);
    }
    try std.testing.expectEqual(hiring_worlds + leader_factions, gs.personages.count());
    // IDs run 1..N in seeding order: rulers, then leaders.
    for (gs.personages.keys(), gs.personages.values(), 1..) |id, p, want| {
        try std.testing.expectEqual(@as(u32, @intCast(want)), @intFromEnum(id));
        try std.testing.expectEqual(want > hiring_worlds, p.role == .faction_leader);
    }
    try std.testing.expectEqual(@as(u32, @intCast(gs.personages.count() + 1)), gs.next_personage_id);
    try validate(&gs);
}

test "one seed seats the same personages and another seed different ones" {
    var a = GameState.init(std.testing.allocator, .{ .seed = 70102 });
    defer a.deinit();
    var b = GameState.init(std.testing.allocator, .{ .seed = 70102 });
    defer b.deinit();
    var c = GameState.init(std.testing.allocator, .{ .seed = 70103 });
    defer c.deinit();
    try createdForTest(&a);
    try createdForTest(&b);
    try createdForTest(&c);

    var h_a = std.hash.Wyhash.init(0);
    var h_b = std.hash.Wyhash.init(0);
    var h_c = std.hash.Wyhash.init(0);
    digest.update(&h_a, a.personages);
    digest.update(&h_b, b.personages);
    digest.update(&h_c, c.personages);
    try std.testing.expectEqual(h_a.final(), h_b.final());
    try std.testing.expect(h_a.final() != h_c.final());

    const ps = a.personages.values();
    for (ps, 0..) |p, i| {
        const q = b.personages.values()[i];
        try std.testing.expectEqual(p.id, q.id);
        try std.testing.expectEqualStrings(p.first_name, q.first_name);
        try std.testing.expectEqualStrings(p.last_name, q.last_name);
        try std.testing.expect(p.motives.eql(q.motives));
        try std.testing.expectEqual(p.ambition, q.ambition);
        // Full names are pairwise distinct; character values stay in range.
        for (ps[0..i]) |earlier| try std.testing.expect(!(std.mem.eql(u8, p.first_name, earlier.first_name) and std.mem.eql(u8, p.last_name, earlier.last_name)));
        try std.testing.expect(p.motives.count() >= 2 and p.motives.count() <= 3);
        try std.testing.expect(p.ambition <= 100);
    }
}

test "seeding personages advances only the politics stream" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70104 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommander(&gs, "T", .LC, .line_officer);
    const before = gs.rng;
    const hash = digest.stateHash(&gs);
    const s = try prepareSeeding(&gs);
    defer s.deinit(&gs);
    try std.testing.expectEqual(hash, digest.stateHash(&gs));
    commitSeeding(&gs, &s);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const moved = !std.mem.eql(u8, &before.encode(stream), &gs.rng.encode(stream));
        try std.testing.expectEqual(stream == .politics, moved);
    }
}

test "drawing relations after the personages leaves every personage row as drawn without them" {
    // The personage map and counter of one seed equal what the personage
    // draws alone produce: relations draw only after the last personage.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70107 });
    defer gs.deinit();
    try createdForTest(&gs);
    var h = std.hash.Wyhash.init(0);
    digest.update(&h, gs.personages);
    digest.update(&h, gs.next_personage_id);
    try std.testing.expectEqual(@as(u64, 4688277191565672504), h.final());
}

test "a create_commander whose personage reservation fails leaves the campaign unchanged and can be retried" {
    // Rules 11, 12 and 69. Each attempt is a fresh campaign whose arena and
    // operation scratch take every allocation from an allocator failing at
    // index `i`. Attempts run until one fails with the last reservation,
    // the relations', already made; every attempt before it failed in the
    // relation scratch or a reservation (the arena may serve a small
    // reservation from memory it already holds), and must leave the campaign
    // as it was.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fresh = GameState.init(outer.allocator(), .{ .seed = 70105 });
    const before = digest.stateHash(&fresh);

    var refused: ?*GameState = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        const gs = try outer.allocator().create(GameState);
        gs.* = GameState.init(outer.allocator(), .{ .seed = 70105 });
        const failing = try outer.allocator().create(std.testing.FailingAllocator);
        failing.* = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, commands.execute(gs, create_for_test));
        if (gs.personage_relations.capacity > 0) break;
        try std.testing.expectEqual(before, digest.stateHash(gs));
        refused = gs;
    }
    // At least one attempt failed inside the preparation itself.
    const gs = refused orelse return error.TestExpectedRefusal;

    // The refused campaign creates cleanly once memory is available.
    gs.arena.child_allocator = outer.allocator();
    try createdForTest(gs);
    try std.testing.expectEqual(seed_count, gs.personages.count());
    try std.testing.expect(gs.personage_relations.items.len > 0);
    try validate(gs);
    try personage_relations.validate(gs);
}

test "a create_commander whose personage counter cannot hold the seeded ids refuses without change" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70106 });
    defer gs.deinit();
    gs.next_personage_id = std.math.maxInt(u32) - @as(u32, seed_count) + 1;
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.CorruptSave, createdForTest(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    gs.next_personage_id -= 1;
    try createdForTest(&gs);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), gs.next_personage_id);
}
