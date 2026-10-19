//! World personages at campaign creation (docs/p5d-conflict-world-design.md
//! §B, P5d.1a, P5d.1d): one planetary ruler per hiring world and one leader
//! per leader-bearing faction, each the `personages.zon` row whose era
//! window holds the start year or else a procedural draw, plus every other
//! in-window data row; and the load-time check that a campaign holds
//! exactly such a set.
//! No MekHQ counterpart: MekHQ has no persistent political figures
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const planet = @import("../domain/planet.zig");
const faction = @import("../domain/faction.zig");
const personage = @import("../domain/personage.zig");
const personage_data = @import("../domain/personage_data.zig");
const personage_gen = @import("../gen/personage_gen.zig");
const names = @import("../gen/person_gen.zig").names;
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

/// Ruler and leader seats: every campaign with a commander fills each once.
pub const seed_count = ruler_count + leader_count;

/// Data rows whose role holds no ruler or leader seat; a campaign seats
/// those in its start year's window in addition to the seats.
pub const extra_row_count: usize = blk: {
    var n: usize = 0;
    for (personage_data.table.rows) |row| {
        if (!holdsSeat(row.role)) n += 1;
    }
    break :blk n;
};

/// The most personages a campaign holds: every seat and every extra row.
pub const max_count = seed_count + extra_row_count;

/// Whether a role fills a ruler or leader seat that a procedural draw
/// fills when no data row does.
fn holdsSeat(role: personage.Role) bool {
    return switch (role) {
        .planetary_ruler, .faction_leader => true,
        .heir, .family, .intelligence_chief => false,
    };
}

// Every build checks what the data table shares with the procedural
// generator and the display (rules 33, 58, 80): names and titles are
// markup-safe, no data full name is one the names.zon pools can draw, no
// two data rows share a full name, and the pools cover every seat a
// procedural draw may fill.
comptime {
    @setEvalBranchQuota(2_000_000);
    if (seed_count > personage_gen.name_space)
        @compileError("data/tables/names.zon: first × last names are fewer than the personages seeded; every personage needs a distinct name");
    const file = "data/tables/personages.zon: ";
    for (personage_data.table.rows, 0..) |row, i| {
        for ([_][]const u8{ row.first_name, row.last_name, row.title }) |text| {
            if (!table.markupSafe(text)) @compileError(file ++ "a name or title is not markup-safe: " ++ row.key);
        }
        if (inPool(names.first, row.first_name) and inPool(names.last, row.last_name))
            @compileError(file ++ "the names.zon pools can draw this full name: " ++ row.key);
        for (personage_data.table.rows[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.first_name, row.first_name) and std.mem.eql(u8, earlier.last_name, row.last_name))
                @compileError(file ++ "two rows share a full name: " ++ earlier.key ++ ", " ++ row.key);
        }
    }
}

fn inPool(pool: []const []const u8, name: []const u8) bool {
    for (pool) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

/// How many personages a campaign starting in `start_year` seats: every
/// seat, and every extra data row whose window holds the year.
pub fn seatedCount(start_year: u16) usize {
    var n: usize = seed_count;
    for (personage_data.table.rows) |*row| {
        if (!holdsSeat(row.role) and personage_data.inWindow(row, start_year)) n += 1;
    }
    return n;
}

/// Every personage of a new campaign and their relations, drawn and with
/// `personages` and `personage_relations` capacity reserved, but not yet on
/// the books. `deinit` releases it, committed or not.
pub const Seeding = struct {
    /// The first `len` entries are the personages, in ID order.
    rows: [max_count]personage.Personage,
    len: usize,
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

    /// The seated personages, in ID order.
    pub fn seated(self: *const Seeding) []const personage.Personage {
        return self.rows[0..self.len];
    }

    /// Seat `p`, whose id is `next_id`, and advance `next_id`.
    fn append(self: *Seeding, p: personage.Personage) void {
        std.debug.assert(@intFromEnum(p.id) == self.next_id);
        self.rows[self.len] = p;
        self.len += 1;
        self.next_id += 1;
    }
};

/// Seat every personage of a campaign starting in `start_year`, draw their
/// relations, and reserve room for them; `commitSeeding` puts them on the
/// books. Nothing in `gs` changes except `personages` and
/// `personage_relations` capacity, so campaign creation prepares this
/// before its first mutation and commits it after its last fallible step.
///
/// Seating order: one ruler per hiring world in `planets.zon` catalogue
/// order, then one leader per leader-bearing faction in `factions.zon`
/// order, each the data row for that seat whose window holds `start_year`
/// (`personage_data.inWindow`) or else a procedural row drawing
/// `personage_gen.generate`'s sequence on `.politics`; then every other
/// in-window data row in `personages.zon` order; then, after the last
/// personage, `personage_relations.generate`'s sequence. IDs follow that
/// order from `next_personage_id`. A start year no data row's window holds
/// draws, seats and numbers exactly the procedural set. A change to this
/// order changes every campaign and needs a deliberate re-pin.
///
/// `CorruptSave` when the ID counter cannot hold the seeded IDs;
/// `OutOfMemory` when a relation allocation or a reservation fails.
pub fn prepareSeeding(gs: *GameState, start_year: u16) error{ CorruptSave, OutOfMemory }!Seeding {
    if (gs.next_personage_id > std.math.maxInt(u32) - seatedCount(start_year)) return error.CorruptSave;

    var rng_copy = gs.rng;
    var name_buf: [seed_count]u32 = undefined;
    var drawn = personage_gen.NameDraw.init(&name_buf);
    var s: Seeding = .{ .rows = undefined, .len = 0, .relations = &.{}, .first_id = gs.next_personage_id, .next_id = gs.next_personage_id, .politics = undefined };
    for (planet.catalog) |*world| {
        if (!personage.worldHasRuler(world)) continue;
        s.append(if (dataRowFor(.planetary_ruler, world.key, start_year)) |row|
            fromData(row, @enumFromInt(s.next_id))
        else
            procedural(&rng_copy, &drawn, @enumFromInt(s.next_id), .planetary_ruler, world.faction, world.key));
    }
    for (faction.table) |*f| {
        if (!personage.factionHasLeader(f)) continue;
        s.append(if (dataRowFor(.faction_leader, f.key, start_year)) |row|
            fromData(row, @enumFromInt(s.next_id))
        else
            procedural(&rng_copy, &drawn, @enumFromInt(s.next_id), .faction_leader, f.key, f.capital));
    }
    for (personage_data.table.rows) |*row| {
        if (holdsSeat(row.role) or !personage_data.inWindow(row, start_year)) continue;
        s.append(fromData(row, @enumFromInt(s.next_id)));
    }
    std.debug.assert(s.len == seatedCount(start_year));
    s.relations = try personage_relations.generate(gs.scratch(), &rng_copy, s.seated());
    errdefer s.deinit(gs);
    s.politics = rng_copy.prngs[@intFromEnum(rng_mod.Stream.politics)];

    try gs.personages.ensureUnusedCapacity(gs.allocator(), s.len);
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
    for (s.seated()) |p| gs.personages.putAssumeCapacity(p.id, p);
    gs.personage_relations.appendSliceAssumeCapacity(s.relations);
    gs.next_personage_id = s.next_id;
    gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)] = s.politics;
}

/// Seat the personages of a campaign whose commander already exists, as
/// `create_commander` does, for the clock's year as its start year. Tests
/// only.
pub fn seedForTest(gs: *GameState) error{ CorruptSave, OutOfMemory }!void {
    std.debug.assert(@import("builtin").is_test);
    const s = try prepareSeeding(gs, gs.clock.date.year);
    defer s.deinit(gs);
    commitSeeding(gs, &s);
}

/// The data row of `role` for one seat — a ruler's world or a leader's
/// faction — whose window holds `start_year`, or null. The build allows at
/// most one per seat among overlapping windows.
fn dataRowFor(role: personage.Role, seat_key: []const u8, start_year: u16) ?*const personage_data.Row {
    for (personage_data.table.rows) |*row| {
        if (row.role != role or !personage_data.inWindow(row, start_year)) continue;
        const key = if (role == .planetary_ruler) row.seat_planet_key else row.faction_key;
        if (std.mem.eql(u8, key, seat_key)) return row;
    }
    return null;
}

/// One data row as a personage; every string is static table memory.
fn fromData(row: *const personage_data.Row, id: types.PersonageId) personage.Personage {
    return .{
        .id = id,
        .role = row.role,
        .first_name = row.first_name,
        .last_name = row.last_name,
        .faction_key = row.faction_key,
        .seat_planet_key = row.seat_planet_key,
        .motives = personage_data.motiveSet(row),
        .ambition = row.ambition,
        .provenance = row.provenance,
        .generator_version = 0,
        .key = row.key,
        .family_key = row.family_key,
    };
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
        .key = "",
        .family_key = "",
    };
}

/// Whether a keyed personage holds exactly its data row's identity and
/// character: role, names, faction, seat, family, motives, ambition and
/// provenance.
fn matchesData(p: *const personage.Personage, row: *const personage_data.Row) bool {
    return p.role == row.role and p.provenance == row.provenance and p.ambition == row.ambition and
        p.motives.eql(personage_data.motiveSet(row)) and
        std.mem.eql(u8, p.first_name, row.first_name) and std.mem.eql(u8, p.last_name, row.last_name) and
        std.mem.eql(u8, p.faction_key, row.faction_key) and std.mem.eql(u8, p.seat_planet_key, row.seat_planet_key) and
        std.mem.eql(u8, p.family_key, row.family_key);
}

/// A loaded campaign's personages are a seated set and nothing else
/// (rule 47; docs/p5d-conflict-world-design.md §J "dangling refs"):
/// every key and seat resolves, a ruler sits on a hiring world of its own
/// faction, a leader on its leader-bearing faction's capital, no world or
/// faction has two, every character value is in range, and a campaign with
/// a commander covers every world and faction while one without holds
/// none. A procedural row has no key or family, `generator_version`
/// `personage_gen.version`, and a ruler or leader role; a keyed row names a
/// `personages.zon` row no other personage names, matches it
/// (`matchesData`), and has `generator_version` 0. Which data rows a
/// campaign holds is not checked: the start year is not saved.
/// `CorruptSave` otherwise.
pub fn validate(gs: *const GameState) error{CorruptSave}!void {
    if (gs.commander == null and gs.personages.count() > 0) return error.CorruptSave;
    var ruled = [_]bool{false} ** planet.catalog.len;
    var led = [_]bool{false} ** faction.table.len;
    var keyed = [_]bool{false} ** personage_data.table.rows.len;
    var it = gs.personages.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.id != entry.key_ptr.* or p.id == .none) return error.CorruptSave;
        if (p.first_name.len == 0 or p.last_name.len == 0) return error.CorruptSave;
        if (!table.markupSafe(p.first_name) or !table.markupSafe(p.last_name)) return error.CorruptSave;
        if (!personage.motivesValid(p.motives) or p.ambition > tuning.politics.ambition_max) return error.CorruptSave;
        if (p.key.len == 0) {
            if (p.provenance != .procedural or p.generator_version != personage_gen.version) return error.CorruptSave;
            if (p.family_key.len != 0 or !holdsSeat(p.role)) return error.CorruptSave;
        } else {
            const at = dataIndex(p.key) orelse return error.CorruptSave;
            if (keyed[at]) return error.CorruptSave;
            keyed[at] = true;
            if (p.provenance == .procedural or p.generator_version != 0) return error.CorruptSave;
            if (!matchesData(p, &personage_data.table.rows[at])) return error.CorruptSave;
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
            // A keyed row's seat and faction are its data row's, which the
            // build resolves.
            .heir, .family, .intelligence_chief => {},
        }
    }
    if (gs.commander == null) return;
    for (planet.catalog, ruled) |*world, has| if (personage.worldHasRuler(world) and !has) return error.CorruptSave;
    for (faction.table, led) |*f, has| if (personage.factionHasLeader(f) and !has) return error.CorruptSave;
}

fn dataIndex(key: []const u8) ?usize {
    for (personage_data.table.rows, 0..) |row, i| if (std.mem.eql(u8, row.key, key)) return i;
    return null;
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

/// The stock data row expected in one seat in `year`, found by a plain
/// scan of the table: a ruler's world or a leader's faction.
fn expectedDataRowForTest(role: personage.Role, seat_key: []const u8, year: u16) ?*const personage_data.Row {
    var found: ?*const personage_data.Row = null;
    for (personage_data.table.rows) |*row| {
        if (row.role != role or year < row.era_from_year or year > row.era_to_year) continue;
        if (std.mem.eql(u8, if (role == .planetary_ruler) row.seat_planet_key else row.faction_key, seat_key)) found = row;
    }
    return found;
}

fn expectDataPersonageForTest(p: personage.Personage, row: *const personage_data.Row) !void {
    try std.testing.expectEqualStrings(row.key, p.key);
    try std.testing.expectEqualStrings(row.family_key, p.family_key);
    try std.testing.expectEqualStrings(row.first_name, p.first_name);
    try std.testing.expectEqualStrings(row.last_name, p.last_name);
    try std.testing.expectEqual(row.role, p.role);
    try std.testing.expectEqual(row.provenance, p.provenance);
    try std.testing.expectEqual(row.ambition, p.ambition);
    try std.testing.expectEqual(@as(u16, 0), p.generator_version);
    try std.testing.expectEqual(row.motives.len, p.motives.count());
    for (row.motives) |m| try std.testing.expect(p.motives.contains(m));
}

test "creation seats every seat once, in-window data rows in their seats and the rest procedural" {
    // Expected sets come from the static tables, not from literals. 3020
    // holds no stock data row's window; 3025 holds every one.
    for ([_]u16{ 3020, 3025 }) |year| {
        errdefer std.debug.print("start year {d}\n", .{year});
        var gs = GameState.init(std.testing.allocator, .{ .seed = 70101 });
        defer gs.deinit();
        _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer, .start_year = year } });

        var hiring_worlds: usize = 0;
        var data_rows: usize = 0;
        for (planet.catalog) |*world| {
            var rulers: usize = 0;
            for (gs.personages.values()) |p| {
                if (p.role != .planetary_ruler or !std.mem.eql(u8, p.seat_planet_key, world.key)) continue;
                rulers += 1;
                try std.testing.expectEqualStrings(world.faction, p.faction_key);
                if (expectedDataRowForTest(.planetary_ruler, world.key, year)) |row| {
                    try expectDataPersonageForTest(p, row);
                    data_rows += 1;
                } else {
                    try std.testing.expectEqual(personage.Provenance.procedural, p.provenance);
                    try std.testing.expectEqualStrings("", p.key);
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
                if (p.role != .faction_leader or !std.mem.eql(u8, p.faction_key, f.key)) continue;
                leaders += 1;
                try std.testing.expectEqualStrings(f.capital, p.seat_planet_key);
                if (expectedDataRowForTest(.faction_leader, f.key, year)) |row| {
                    try expectDataPersonageForTest(p, row);
                    data_rows += 1;
                } else {
                    try std.testing.expectEqual(personage.Provenance.procedural, p.provenance);
                }
            }
            const expected: usize = if (f.hires and !std.mem.eql(u8, f.key, "PER")) 1 else 0;
            try std.testing.expectEqual(expected, leaders);
            leader_factions += expected;
        }
        // Every other in-window data row is seated exactly once, after the
        // seats, in table order.
        var extra: usize = 0;
        for (personage_data.table.rows) |*row| {
            if (row.role == .planetary_ruler or row.role == .faction_leader) continue;
            if (year < row.era_from_year or year > row.era_to_year) continue;
            var held: usize = 0;
            for (gs.personages.values(), 0..) |p, at| if (std.mem.eql(u8, p.key, row.key)) {
                held += 1;
                try std.testing.expectEqual(hiring_worlds + leader_factions + extra, at);
                try expectDataPersonageForTest(p, row);
            };
            try std.testing.expectEqual(@as(usize, 1), held);
            extra += 1;
        }
        // The ComStar world gets no ruler and the catch-all bucket no leader;
        // every procedural row has no key and the generator's version.
        for (gs.personages.values()) |p| {
            try std.testing.expect(!std.mem.eql(u8, p.faction_key, "CS"));
            if (p.role == .faction_leader) try std.testing.expect(!std.mem.eql(u8, p.faction_key, "PER"));
            if (p.provenance == .procedural) {
                try std.testing.expectEqual(personage_gen.version, p.generator_version);
                try std.testing.expectEqualStrings("", p.key);
                try std.testing.expectEqualStrings("", p.family_key);
            }
        }
        try std.testing.expectEqual(hiring_worlds + leader_factions + extra, gs.personages.count());
        try std.testing.expectEqual(seatedCount(year), gs.personages.count());
        if (year == personage_data.reference_year) {
            try std.testing.expectEqual(personage_data.table.rows.len, data_rows + extra);
        } else try std.testing.expectEqual(@as(usize, 0), data_rows + extra);
        // IDs run 1..N in seating order: rulers, leaders, then the rest.
        for (gs.personages.keys(), gs.personages.values(), 1..) |id, p, want| {
            try std.testing.expectEqual(@as(u32, @intCast(want)), @intFromEnum(id));
            try std.testing.expectEqual(want > hiring_worlds and want <= hiring_worlds + leader_factions, p.role == .faction_leader);
        }
        try std.testing.expectEqual(@as(u32, @intCast(gs.personages.count() + 1)), gs.next_personage_id);
        try validate(&gs);
        try personage_relations.validate(&gs);
    }
}

/// A hash of what a start year without data rows seats, over the fields
/// and encodings a campaign without data rows has always held: every
/// personage's id, role, names, faction, seat, motive mask, ambition,
/// provenance and generator version, the counter, every relation, and the
/// `.politics` stream. Keys and families are left out; the test asserts
/// them empty.
fn seatedWorldHashForTest(gs: *const GameState) u64 {
    var h = std.hash.Wyhash.init(0);
    const Put = struct {
        fn int(hh: *std.hash.Wyhash, comptime T: type, v: T) void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            hh.update(&b);
        }
        fn text(hh: *std.hash.Wyhash, s: []const u8) void {
            int(hh, u32, @intCast(s.len));
            hh.update(s);
        }
    };
    Put.int(&h, u32, @intCast(gs.personages.count()));
    for (gs.personages.values()) |p| {
        Put.int(&h, u32, @intFromEnum(p.id));
        Put.text(&h, @tagName(p.role));
        Put.text(&h, p.first_name);
        Put.text(&h, p.last_name);
        Put.text(&h, p.faction_key);
        Put.text(&h, p.seat_planet_key);
        Put.int(&h, u16, personage.motivesMask(p.motives));
        Put.int(&h, u8, p.ambition);
        Put.text(&h, @tagName(p.provenance));
        Put.int(&h, u16, p.generator_version);
    }
    Put.int(&h, u32, gs.next_personage_id);
    Put.int(&h, u32, @intCast(gs.personage_relations.items.len));
    for (gs.personage_relations.items) |rel| {
        Put.int(&h, u32, @intFromEnum(rel.from));
        Put.int(&h, u32, @intFromEnum(rel.to));
        Put.text(&h, @tagName(rel.kind));
        Put.int(&h, u8, rel.weight);
    }
    const politics = gs.rng.encode(.politics);
    h.update(&politics);
    return h.final();
}

test "a start year no data row's window holds seats exactly the procedural world" {
    // The pinned value is `seatedWorldHashForTest` of this campaign as the
    // procedural-only seeding made it (244 personages, 493 relations), so
    // data rows outside their window change no draw, row, id, relation or
    // stream state. The seating is `create_commander`'s, before the
    // standing needs it draws next.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 72001 });
    defer gs.deinit();
    _ = try @import("founding.zig").createCommanderAt(&gs, "T", .LC, .line_officer, 3020);
    try seedForTest(&gs);
    for (gs.personages.values()) |p| {
        try std.testing.expectEqualStrings("", p.key);
        try std.testing.expectEqualStrings("", p.family_key);
    }
    try std.testing.expectEqual(@as(usize, 244), gs.personages.count());
    try std.testing.expectEqual(@as(usize, 493), gs.personage_relations.items.len);
    try std.testing.expectEqual(@as(u64, 14122909925932871157), seatedWorldHashForTest(&gs));
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
    const s = try prepareSeeding(&gs, personage_data.reference_year);
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
    try std.testing.expectEqual(@as(u64, 15180135651749192151), h.final());
}

test "a create_commander whose personage reservation fails leaves the campaign unchanged and can be retried" {
    // Rules 11, 12 and 69. Each attempt is a fresh campaign whose arena and
    // operation scratch take every allocation from an allocator failing at
    // index `i`, until an attempt gets every allocation it asks for. Which
    // index lands in which step depends on how the arena serves and grows
    // its blocks, so the sweep covers them all: every refused attempt, in
    // the relation scratch, a reservation or a step after them, leaves the
    // campaign as it was. The first attempt fails in the relation scratch,
    // the command's first allocation.
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fresh = GameState.init(outer.allocator(), .{ .seed = 70105 });
    const before = digest.stateHash(&fresh);

    var first_refused: ?*GameState = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        const gs = try outer.allocator().create(GameState);
        gs.* = GameState.init(outer.allocator(), .{ .seed = 70105 });
        const failing = try outer.allocator().create(std.testing.FailingAllocator);
        failing.* = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = i });
        gs.arena.child_allocator = failing.allocator();
        if (commands.execute(gs, create_for_test)) |_| break else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(before, digest.stateHash(gs));
        if (first_refused == null) first_refused = gs;
    }
    const gs = first_refused orelse return error.TestExpectedRefusal;

    // The refused campaign creates cleanly once memory is available.
    gs.arena.child_allocator = outer.allocator();
    try createdForTest(gs);
    try std.testing.expectEqual(seatedCount(personage_data.reference_year), gs.personages.count());
    try std.testing.expect(gs.personage_relations.items.len > 0);
    try validate(gs);
    try personage_relations.validate(gs);
}

test "a create_commander whose personage counter cannot hold the seeded ids refuses without change" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70106 });
    defer gs.deinit();
    gs.next_personage_id = std.math.maxInt(u32) - @as(u32, @intCast(seatedCount(personage_data.reference_year))) + 1;
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.CorruptSave, createdForTest(&gs));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    gs.next_personage_id -= 1;
    try createdForTest(&gs);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), gs.next_personage_id);
}
