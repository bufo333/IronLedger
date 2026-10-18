//! Relations between world personages at campaign creation
//! (docs/p5d-conflict-world-design.md §B relations, P5d.1c): every ruler's
//! fealty to its faction's leader, kin by shared surname within a faction,
//! and rivals, allies and grudges between rulers in reach; and the load-time
//! check every campaign's relations keep.
//! No MekHQ counterpart: MekHQ has no persistent political figures
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const planet = @import("../domain/planet.zig");
const faction = @import("../domain/faction.zig");
const personage = @import("../domain/personage.zig");
const rng_mod = @import("rng.zig");
const personages = @import("personages.zig");
const GameState = @import("state.zig").GameState;

const Relation = personage.Relation;
const RelationKind = personage.RelationKind;

/// The relations of a new campaign's personages, drawn from `.politics` on
/// `rng`; the caller owns the returned slice, allocated from `alloc`. `rows`
/// are every personage, in ascending ID order. Draws nothing from any other
/// stream and changes nothing else.
///
/// Draw order, all on `.politics`:
/// 1. liege: for each ruler in ID order whose faction has a leader, one
///    weight (the vassal's loyalty); the leader is found, not drawn;
/// 2. kin: for each pair `personage.kinAtCreation` accepts, in (lower ID,
///    higher ID) order, one weight;
/// 3. for each ruler in ID order, in turn rival, ally, then grudge: the
///    candidates are the other rulers `personage.inRelationReach` and
///    `personage.drawnRelationFactionsAllowed` accept, in ID order, less
///    any pair that already holds that kind and, for a rival, any ally, and
///    for an ally, any rival. With no candidate nothing is drawn; otherwise
///    the kind's chance, then on success a uniform candidate and a weight.
///
/// A change to this order changes every campaign and needs a deliberate
/// re-pin. `OutOfMemory` when `alloc` fails; nothing is then returned.
pub fn generate(alloc: std.mem.Allocator, rng: *rng_mod.Rng, rows: []const personage.Personage) error{OutOfMemory}![]Relation {
    for (rows[1..], rows[0..rows.len -| 1]) |later, earlier| std.debug.assert(@intFromEnum(later.id) > @intFromEnum(earlier.id));
    const r = rng.random(.politics);
    var out: std.ArrayListUnmanaged(Relation) = .empty;
    errdefer out.deinit(alloc);

    for (rows) |*vassal| {
        if (vassal.role != .planetary_ruler) continue;
        const liege = leaderOf(rows, vassal.faction_key) orelse continue;
        try out.append(alloc, .{ .from = vassal.id, .to = liege.id, .kind = .liege, .weight = drawWeight(r) });
    }

    for (rows, 0..) |*a, i| for (rows[i + 1 ..]) |*b| if (personage.kinAtCreation(a, b)) {
        try out.append(alloc, .{ .from = a.id, .to = b.id, .kind = .kin, .weight = drawWeight(r) });
    };

    // Seats resolved once: a ruler's world, null for a leader.
    const seats = try alloc.alloc(?*const planet.Planet, rows.len);
    defer alloc.free(seats);
    for (rows, seats) |*p, *seat| seat.* = if (p.role == .planetary_ruler) planet.find(p.seat_planet_key) else null;
    var candidates: std.ArrayListUnmanaged(usize) = .empty;
    defer candidates.deinit(alloc);
    try candidates.ensureTotalCapacity(alloc, rows.len);
    const drawn_start = out.items.len;
    for (rows, seats, 0..) |*a, seat_a, i| {
        const at = seat_a orelse continue;
        for ([_]RelationKind{ .rival, .ally, .grudge }) |kind| {
            candidates.clearRetainingCapacity();
            for (rows, seats, 0..) |*b, seat_b, j| {
                const bt = seat_b orelse continue;
                if (i == j or !personage.inRelationReach(at, bt)) continue;
                if (!personage.drawnRelationFactionsAllowed(kind, a.faction_key, b.faction_key)) continue;
                const drawn = out.items[drawn_start..];
                if (pairHolds(drawn, a.id, b.id, kind)) continue;
                if (kind == .rival and pairHolds(drawn, a.id, b.id, .ally)) continue;
                if (kind == .ally and pairHolds(drawn, a.id, b.id, .rival)) continue;
                candidates.appendAssumeCapacity(j);
            }
            if (candidates.items.len == 0) continue;
            if (@as(types.Bp, r.uintLessThan(u32, @intCast(types.full_bp))) >= chanceBp(kind)) continue;
            const b = &rows[candidates.items[r.uintLessThan(usize, candidates.items.len)]];
            const weight = drawWeight(r);
            try out.append(alloc, if (kind.symmetric() and @intFromEnum(b.id) < @intFromEnum(a.id))
                .{ .from = b.id, .to = a.id, .kind = kind, .weight = weight }
            else
                .{ .from = a.id, .to = b.id, .kind = kind, .weight = weight });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn drawWeight(r: std.Random) u8 {
    return r.intRangeAtMost(u8, tuning.politics.relation_weight_min, tuning.politics.relation_weight_max);
}

fn chanceBp(kind: RelationKind) types.Bp {
    return switch (kind) {
        .rival => tuning.politics.rival_chance_bp,
        .ally => tuning.politics.ally_chance_bp,
        .grudge => tuning.politics.grudge_chance_bp,
        .liege, .kin => unreachable,
    };
}

/// The leader of a faction among `rows`, or null when it has none.
fn leaderOf(rows: []const personage.Personage, faction_key: []const u8) ?*const personage.Personage {
    for (rows) |*p| if (p.role == .faction_leader and std.mem.eql(u8, p.faction_key, faction_key)) return p;
    return null;
}

/// Whether `a` and `b`, in either order, already hold `kind`.
fn pairHolds(relations: []const Relation, a: types.PersonageId, b: types.PersonageId, kind: RelationKind) bool {
    for (relations) |rel| {
        if (rel.kind == kind and ((rel.from == a and rel.to == b) or (rel.from == b and rel.to == a))) return true;
    }
    return false;
}

/// A loaded campaign's relations keep the invariants every campaign keeps
/// (rule 47; docs/p5d-conflict-world-design.md §J "dangling refs"). Runs
/// after `personages.validate`. `CorruptSave` for: an endpoint that is no
/// personage, or a self-relation; a symmetric relation without `from < to`;
/// a duplicate `(from, to, kind)`; a weight off the tuned scale; a liege
/// from anyone but a ruler, to anyone but the leader of the ruler's own
/// faction, or a second one; a ruler of a leader-bearing faction without a
/// liege; one pair holding both rival and ally; relations in a campaign
/// without personages. Which pairs creation draws (kin's surname, reach,
/// faction rules) is not checked here: later play may relate others.
pub fn validate(gs: *const GameState) error{CorruptSave}!void {
    const relations = gs.personage_relations.items;
    const people = gs.personages.values();
    if (people.len == 0) {
        if (relations.len > 0) return error.CorruptSave;
        return;
    }
    // `personages.validate` holds a campaign to the seeded set.
    if (people.len > personages.seed_count) return error.CorruptSave;
    var has_liege = [_]bool{false} ** personages.seed_count;
    for (relations, 0..) |rel, i| {
        if (rel.from == rel.to) return error.CorruptSave;
        const from = gs.personages.getIndex(rel.from) orelse return error.CorruptSave;
        const to = gs.personages.getIndex(rel.to) orelse return error.CorruptSave;
        if (rel.kind.symmetric() and @intFromEnum(rel.from) >= @intFromEnum(rel.to)) return error.CorruptSave;
        if (!personage.relationWeightValid(rel.weight)) return error.CorruptSave;
        for (relations[0..i]) |earlier| {
            const same_pair = (earlier.from == rel.from and earlier.to == rel.to) or (earlier.from == rel.to and earlier.to == rel.from);
            if (!same_pair) continue;
            if (earlier.from == rel.from and earlier.kind == rel.kind) return error.CorruptSave;
            if ((earlier.kind == .rival and rel.kind == .ally) or (earlier.kind == .ally and rel.kind == .rival)) return error.CorruptSave;
        }
        if (rel.kind == .liege) {
            const vassal = &people[from];
            const liege = &people[to];
            if (vassal.role != .planetary_ruler or liege.role != .faction_leader) return error.CorruptSave;
            if (!std.mem.eql(u8, vassal.faction_key, liege.faction_key)) return error.CorruptSave;
            if (has_liege[from]) return error.CorruptSave;
            has_liege[from] = true;
        }
    }
    for (people, has_liege[0..people.len]) |*p, held| {
        if (p.role != .planetary_ruler) continue;
        const f = faction.find(p.faction_key) orelse return error.CorruptSave;
        if (personage.factionHasLeader(f) and !held) return error.CorruptSave;
    }
}

// ---- Tests ----

const commands = @import("commands.zig");

fn createdForTest(gs: *GameState) !void {
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
}

fn kindCount(relations: []const Relation, kind: RelationKind) usize {
    var n: usize = 0;
    for (relations) |rel| n += @intFromBool(rel.kind == kind);
    return n;
}

test "one seed draws the same relations and another seed different ones, every kind among them" {
    var a = GameState.init(std.testing.allocator, .{ .seed = 71101 });
    defer a.deinit();
    var b = GameState.init(std.testing.allocator, .{ .seed = 71101 });
    defer b.deinit();
    var c = GameState.init(std.testing.allocator, .{ .seed = 71102 });
    defer c.deinit();
    try createdForTest(&a);
    try createdForTest(&b);
    try createdForTest(&c);

    try std.testing.expectEqualSlices(Relation, a.personage_relations.items, b.personage_relations.items);
    const same_as_c = std.mem.eql(u8, std.mem.sliceAsBytes(a.personage_relations.items), std.mem.sliceAsBytes(c.personage_relations.items));
    try std.testing.expect(!same_as_c);
    // Each kind occurs, so the rule assertions below are not vacuous.
    for (std.enums.values(RelationKind)) |kind| {
        errdefer std.debug.print("no {s} relation drawn\n", .{@tagName(kind)});
        try std.testing.expect(kindCount(a.personage_relations.items, kind) > 0);
    }
    try validate(&a);
}

test "creation relates exactly the pairs the relation rules name" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71101 });
    defer gs.deinit();
    try createdForTest(&gs);
    const relations = gs.personage_relations.items;
    const people = gs.personages.values();

    // Expected sets come from the static tables and the personage map.
    const Expect = struct {
        fn leaderBearing(key: []const u8) bool {
            const f = faction.find(key).?;
            return f.hires and !std.mem.eql(u8, f.key, "PER");
        }
        fn lists(a: []const u8, b: []const u8) bool {
            for (faction.find(a).?.foes) |foe| if (std.mem.eql(u8, foe, b)) return true;
            return false;
        }
        fn hostile(a: []const u8, b: []const u8) bool {
            return lists(a, b) or lists(b, a);
        }
    };

    // Liege: every ruler of a leader-bearing faction exactly once, to its
    // faction's leader; nobody else.
    for (people) |*p| {
        var held: usize = 0;
        for (relations) |rel| if (rel.kind == .liege and rel.from == p.id) {
            held += 1;
            const liege = gs.personages.get(rel.to).?;
            try std.testing.expectEqual(personage.Role.faction_leader, liege.role);
            try std.testing.expectEqualStrings(p.faction_key, liege.faction_key);
        };
        const expected: usize = if (p.role == .planetary_ruler and Expect.leaderBearing(p.faction_key)) 1 else 0;
        try std.testing.expectEqual(expected, held);
    }

    // Kin: exactly the same-faction, same-last-name pairs, lower ID first.
    var kin_pairs: usize = 0;
    for (people, 0..) |*a, i| for (people[i + 1 ..]) |*b| {
        if (!(std.mem.eql(u8, a.faction_key, b.faction_key) and std.mem.eql(u8, a.last_name, b.last_name))) continue;
        kin_pairs += 1;
        var found: usize = 0;
        for (relations) |rel| found += @intFromBool(rel.kind == .kin and rel.from == a.id and rel.to == b.id);
        try std.testing.expectEqual(@as(usize, 1), found);
    };
    try std.testing.expect(kin_pairs > 0);
    try std.testing.expectEqual(kin_pairs, kindCount(relations, .kin));

    // Rival, ally and grudge join two rulers in reach under their faction rule.
    for (relations, 0..) |rel, i| {
        if (rel.kind == .liege or rel.kind == .kin) continue;
        const a = gs.personages.get(rel.from).?;
        const b = gs.personages.get(rel.to).?;
        try std.testing.expect(a.role == .planetary_ruler and b.role == .planetary_ruler);
        try std.testing.expect(planet.distanceLy(planet.find(a.seat_planet_key).?, planet.find(b.seat_planet_key).?) <= tuning.politics.relation_reach_ly);
        switch (rel.kind) {
            .rival => try std.testing.expectEqualStrings(a.faction_key, b.faction_key),
            .ally => try std.testing.expect(!Expect.hostile(a.faction_key, b.faction_key)),
            .grudge => try std.testing.expect(Expect.hostile(a.faction_key, b.faction_key)),
            .liege, .kin => unreachable,
        }
        // No pair holds both rival and ally.
        for (relations[0..i]) |earlier| {
            const same_pair = (earlier.from == rel.from and earlier.to == rel.to) or (earlier.from == rel.to and earlier.to == rel.from);
            if (same_pair) try std.testing.expect(!((earlier.kind == .rival and rel.kind == .ally) or (earlier.kind == .ally and rel.kind == .rival)));
        }
    }

    for (relations) |rel| {
        try std.testing.expect(rel.weight >= tuning.politics.relation_weight_min and rel.weight <= tuning.politics.relation_weight_max);
        if (rel.kind.symmetric()) try std.testing.expect(@intFromEnum(rel.from) < @intFromEnum(rel.to));
    }
    try validate(&gs);
}

test "relation generation draws only from the politics stream and refuses a failing allocator" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71103 });
    defer gs.deinit();
    try createdForTest(&gs);
    const people = gs.personages.values();
    var rng = rng_mod.Rng.init(71103);
    const relations = try generate(std.testing.allocator, &rng, people);
    defer std.testing.allocator.free(relations);
    const fresh = rng_mod.Rng.init(71103);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const moved = !std.mem.eql(u8, &rng.encode(stream), &fresh.encode(stream));
        try std.testing.expectEqual(stream == .politics, moved);
    }
    var again = rng_mod.Rng.init(71103);
    try std.testing.expectError(error.OutOfMemory, generate(std.testing.failing_allocator, &again, people));
}
