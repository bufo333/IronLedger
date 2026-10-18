//! Personages: the persisted figures of the political world, a world's
//! ruler and a power's leader (docs/p5d-conflict-world-design.md §B, P5d.1a).
//! Distinct from the contract-scoped `Actor`. This record holds §B's
//! identity, motive, ambition and provenance, and §B's relations between
//! personages (P5d.1c), whose liege weight is loyalty; family, backstory,
//! status, standing and flags belong to later increments.
//! No MekHQ counterpart: MekHQ has no persistent political figures
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const tuning = @import("tuning.zig").t;
const planet = @import("planet.zig");
const faction = @import("faction.zig");

/// The role a personage holds (§B). Persisted by tag name.
pub const Role = enum {
    planetary_ruler,
    faction_leader,
};

/// §B's closed motive set. Each value is the motive's bit in the persisted
/// motive mask (`motivesMask`), so a value never changes once saved.
pub const Motive = enum(u4) {
    expansion = 0,
    dynastic_security = 1,
    secession = 2,
    revenge = 3,
    profit = 4,
    honor = 5,
    reform = 6,
    survival = 7,
    ambition = 8,
};

pub const Motives = std.EnumSet(Motive);

/// Where a personage's row comes from (§B). Persisted by tag name.
pub const Provenance = enum {
    /// Generated at campaign creation; `generator_version` names the generator.
    procedural,

    /// The label every display row shows beside the name.
    pub fn label(self: Provenance) []const u8 {
        return switch (self) {
            .procedural => "procedural",
        };
    }
};

pub const Personage = struct {
    id: types.PersonageId,
    role: Role,
    first_name: []const u8,
    last_name: []const u8,
    /// `factions.zon` key: the ruler's world's faction, or the leader's faction.
    faction_key: []const u8,
    /// `planets.zon` key: the world ruled, or the leader's capital.
    seat_planet_key: []const u8,
    motives: Motives,
    /// 0..`tuning.politics.ambition_max`.
    ambition: u8,
    provenance: Provenance,
    generator_version: u16,
};

/// The faction key that is a catch-all bucket rather than a polity: it has
/// worlds and hires, but no leader (design decision P1, §B "Power").
pub const catch_all_faction_key = "PER";

/// Whether a world gets a planetary ruler: its faction hires (§B coverage
/// target). A world whose faction is unknown gets none.
pub fn worldHasRuler(world: *const planet.Planet) bool {
    const f = faction.find(world.faction) orelse return false;
    return f.hires;
}

/// Whether a faction gets a leader: it hires and is not the catch-all
/// bucket (§B coverage target; decision P1). The leader sits on its capital.
pub fn factionHasLeader(f: *const faction.FactionRow) bool {
    return f.hires and !std.mem.eql(u8, f.key, catch_all_faction_key);
}

/// Whether a motive set holds the number of motives §B allows.
pub fn motivesValid(m: Motives) bool {
    const n = m.count();
    return n >= tuning.politics.motive_count_min and n <= tuning.politics.motive_count_max;
}

/// The persisted motive mask: bit `@intFromEnum(m)` set for each motive held.
pub fn motivesMask(m: Motives) u16 {
    var mask: u16 = 0;
    var it = m.iterator();
    while (it.next()) |motive| mask |= @as(u16, 1) << @intFromEnum(motive);
    return mask;
}

/// The motive set a persisted mask names; null when it sets a bit that is
/// no motive.
pub fn motivesFromMask(mask: u16) ?Motives {
    var m = Motives.initEmpty();
    var rest = mask;
    for (std.enums.values(Motive)) |motive| {
        const bit = @as(u16, 1) << @intFromEnum(motive);
        if (rest & bit != 0) m.insert(motive);
        rest &= ~bit;
    }
    return if (rest == 0) m else null;
}

/// §B's relation kinds. Persisted by tag name.
pub const RelationKind = enum {
    /// Vassal → liege: a ruler's fealty to its faction's leader.
    liege,
    kin,
    rival,
    ally,
    /// Holder → target.
    grudge,

    /// Whether the relation reads the same from either end. A symmetric
    /// relation is stored once, with `from < to`; a directed one runs
    /// `from` → `to`.
    pub fn symmetric(self: RelationKind) bool {
        return switch (self) {
            .kin, .rival, .ally => true,
            .liege, .grudge => false,
        };
    }
};

/// One relation between two personages (§B `personage_relation`). Its
/// identity is `(from, to, kind)`.
pub const Relation = struct {
    from: types.PersonageId,
    to: types.PersonageId,
    kind: RelationKind,
    /// `tuning.politics.relation_weight_min..relation_weight_max`. A liege
    /// relation's weight is the vassal's loyalty to its liege (§B: `loyalty`
    /// (to liege) on a 0–100 scale), so loyalty exists exactly where a liege
    /// does.
    weight: u8,
};

/// Whether two factions are hostile: either lists the other in
/// `factions.zon` `foes`. Symmetric although `foes` is not (TC lists FS,
/// FS does not list TC). The one hostility test for ally and grudge
/// relations (docs/p5d-conflict-world-design.md §B, decision R1 (relations)). An
/// unknown key is no faction and hostile to none.
pub fn factionsHostile(a: []const u8, b: []const u8) bool {
    const fa = faction.find(a) orelse return false;
    const fb = faction.find(b) orelse return false;
    for (fa.foes) |foe| if (std.mem.eql(u8, foe, fb.key)) return true;
    for (fb.foes) |foe| if (std.mem.eql(u8, foe, fa.key)) return true;
    return false;
}

/// Whether two rulers' seats are close enough for a rival, ally or grudge
/// relation drawn at campaign creation: within
/// `tuning.politics.relation_reach_ly` (§B, decision R1 (relations)).
pub fn inRelationReach(seat_a: *const planet.Planet, seat_b: *const planet.Planet) bool {
    return planet.distanceLy(seat_a, seat_b) <= tuning.politics.relation_reach_ly;
}

/// Whether a ruler of `faction_a` may draw `kind` toward a ruler of
/// `faction_b` at campaign creation (§B, decision R1 (relations)): a rival is of the
/// same faction, an ally of a faction neither side lists as a foe, a
/// grudge's target of a faction either side does. Only rulers within
/// reach (`inRelationReach`) draw these; `liege` and `kin` are never drawn
/// this way.
pub fn drawnRelationFactionsAllowed(kind: RelationKind, faction_a: []const u8, faction_b: []const u8) bool {
    return switch (kind) {
        .rival => std.mem.eql(u8, faction_a, faction_b),
        .ally => !factionsHostile(faction_a, faction_b),
        .grudge => factionsHostile(faction_a, faction_b),
        .liege, .kin => false,
    };
}

/// Whether two distinct personages are kin at campaign creation: the same
/// faction and the same last name (§B, decision K1). Kin never crosses
/// factions.
pub fn kinAtCreation(a: *const Personage, b: *const Personage) bool {
    return a.id != b.id and std.mem.eql(u8, a.faction_key, b.faction_key) and std.mem.eql(u8, a.last_name, b.last_name);
}

/// Whether a relation weight is on the tuned scale.
pub fn relationWeightValid(weight: u8) bool {
    return weight >= tuning.politics.relation_weight_min and weight <= tuning.politics.relation_weight_max;
}

pub const TitleError = error{UnknownSeat} || std.mem.Allocator.Error;

/// A personage's title (rule 28: the one formatter): "Governor of <world>"
/// for a ruler, "Leader, <faction>" for a leader. Project-authored generic
/// labels, not canon titles. `UnknownSeat` when the key names no row.
pub fn titleText(alloc: std.mem.Allocator, p: *const Personage) TitleError![]const u8 {
    return switch (p.role) {
        .planetary_ruler => std.fmt.allocPrint(alloc, "Governor of {s}", .{(planet.find(p.seat_planet_key) orelse return error.UnknownSeat).name}),
        .faction_leader => std.fmt.allocPrint(alloc, "Leader, {s}", .{(faction.find(p.faction_key) orelse return error.UnknownSeat).name}),
    };
}

// The design bounds are §B's: a motive set holds two or three of the nine
// motives, and ambition is on a 0–100 scale. The save schema's checks hold
// these bounds, so tuning may narrow them but never widen them.
comptime {
    const pol = tuning.politics;
    if (pol.motive_count_min < 2 or pol.motive_count_min > pol.motive_count_max or pol.motive_count_max > 3)
        @compileError("data/tables/tuning.zon: politics motive counts must satisfy 2 <= min <= max <= 3 (§B)");
    if (pol.ambition_max > 100)
        @compileError("data/tables/tuning.zon: politics.ambition_max must not exceed 100 (§B)");
    // A relation weight is on §B's 1–100 scale, which the save schema's
    // `weight BETWEEN 1 AND 100` check holds; a chance is a share of 10 000 bp.
    if (pol.relation_weight_min < 1 or pol.relation_weight_min > pol.relation_weight_max or pol.relation_weight_max > 100)
        @compileError("data/tables/tuning.zon: politics relation weights must satisfy 1 <= min <= max <= 100 (§B)");
    for (.{ pol.rival_chance_bp, pol.ally_chance_bp, pol.grudge_chance_bp }) |chance| {
        if (chance < 0 or chance > types.full_bp)
            @compileError("data/tables/tuning.zon: politics relation chances must lie in 0..10000 bp");
    }
}

test "every hiring world gets a ruler and every hiring faction except the catch-all a leader" {
    for (planet.catalog) |*world| {
        try std.testing.expectEqual(faction.find(world.faction).?.hires, worldHasRuler(world));
    }
    try std.testing.expect(!worldHasRuler(&.{ .key = "x", .name = "X", .faction = "nobody", .x = 0, .y = 0, .industry = 0 }));
    try std.testing.expect(factionHasLeader(faction.find("LC").?));
    try std.testing.expect(!factionHasLeader(faction.find("CS").?));
    try std.testing.expect(!factionHasLeader(faction.find(catch_all_faction_key).?));
    try std.testing.expect(faction.find(catch_all_faction_key).?.hires);
}

test "a motive mask round-trips and refuses bits that are no motive" {
    var m = Motives.initEmpty();
    m.insert(.expansion);
    m.insert(.ambition);
    try std.testing.expectEqual(@as(u16, 0b1_0000_0001), motivesMask(m));
    try std.testing.expect(motivesFromMask(motivesMask(m)).?.eql(m));
    try std.testing.expectEqual(@as(?Motives, null), motivesFromMask(0b10_0000_0000));
    try std.testing.expect(motivesFromMask(0).?.count() == 0);
    try std.testing.expect(motivesValid(m));
    m.insert(.honor);
    try std.testing.expect(motivesValid(m));
    m.insert(.reform);
    try std.testing.expect(!motivesValid(m));
    try std.testing.expect(!motivesValid(Motives.initOne(.profit)));
}

test "hostility holds when either faction lists the other, so it is symmetric over one-sided foes" {
    // factions.zon: TC lists FS as a foe and FS does not list TC.
    const fs = faction.find("FS").?;
    for (fs.foes) |foe| try std.testing.expect(!std.mem.eql(u8, foe, "TC"));
    try std.testing.expect(factionsHostile("TC", "FS"));
    try std.testing.expect(factionsHostile("FS", "TC"));
    // PER lists itself; neither LC nor FS lists the other.
    try std.testing.expect(factionsHostile(catch_all_faction_key, catch_all_faction_key));
    try std.testing.expect(!factionsHostile("LC", "FS"));
    try std.testing.expect(!factionsHostile("LC", "LC"));
    try std.testing.expect(!factionsHostile("LC", "nobody"));
    for (faction.table) |a| for (faction.table) |b| {
        try std.testing.expectEqual(factionsHostile(a.key, b.key), factionsHostile(b.key, a.key));
    };
    // Ally and grudge partition every faction pair; rival needs one faction.
    try std.testing.expect(drawnRelationFactionsAllowed(.grudge, "FS", "TC") and !drawnRelationFactionsAllowed(.ally, "FS", "TC"));
    try std.testing.expect(drawnRelationFactionsAllowed(.ally, "LC", "FS") and !drawnRelationFactionsAllowed(.grudge, "LC", "FS"));
    try std.testing.expect(drawnRelationFactionsAllowed(.rival, "LC", "LC") and !drawnRelationFactionsAllowed(.rival, "LC", "FS"));
    try std.testing.expect(!drawnRelationFactionsAllowed(.liege, "LC", "LC") and !drawnRelationFactionsAllowed(.kin, "LC", "LC"));
    try std.testing.expect(RelationKind.kin.symmetric() and RelationKind.rival.symmetric() and RelationKind.ally.symmetric());
    try std.testing.expect(!RelationKind.liege.symmetric() and !RelationKind.grudge.symmetric());
}

test "a title names the world ruled or the faction led" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Personage = .{ .id = @enumFromInt(1), .role = .planetary_ruler, .first_name = "A", .last_name = "B", .faction_key = "LC", .seat_planet_key = "skye", .motives = .initEmpty(), .ambition = 0, .provenance = .procedural, .generator_version = 1 };
    try std.testing.expectEqualStrings("Governor of Skye", try titleText(a, &p));
    p.role = .faction_leader;
    try std.testing.expectEqualStrings("Leader, Lyran Commonwealth", try titleText(a, &p));
    p.faction_key = "nobody";
    try std.testing.expectError(error.UnknownSeat, titleText(a, &p));
}
