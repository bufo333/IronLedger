//! Procedural personage generation (docs/p5d-conflict-world-design.md §B,
//! P5d.1a): a full name from data/tables/names.zon, two or three distinct
//! motives, and an ambition. Pure: the caller passes the random source and
//! the stream (rule 57).
//! No MekHQ counterpart: MekHQ generates no political figures; names come
//! from the `RandomNameGenerator` stand-in tables (docs/mekhq-map.md).

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const personage = @import("../domain/personage.zig");
const rng_mod = @import("../sim/rng.zig");
const names = @import("person_gen.zig").names;

/// The generator a `procedural` row names. A change to what `generate`
/// draws, or in what order, is a new version.
pub const version: u16 = 1;

/// Distinct full names the tables can make: every first name with every
/// last name. Distinct indices are distinct names because the build
/// refuses a pool with an empty or repeated entry (below).
pub const name_space: usize = names.first.len * names.last.len;

/// Why `pool` cannot name personages, or null: every entry must be nonempty
/// (a saved name is never empty) and no entry may repeat (rule 58).
pub fn poolProblem(pool: []const []const u8) ?[]const u8 {
    for (pool, 0..) |entry, i| {
        if (entry.len == 0) return "has an empty entry";
        for (pool[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, entry)) return "repeats an entry";
        }
    }
    return null;
}

// Every build checks the pools the generator names personages from, a
// mod's names.zon too.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (.{ .{ "first", names.first }, .{ "last", names.last } }) |pool| {
        if (poolProblem(pool[1])) |problem| @compileError("data/tables/names.zon: `" ++ pool[0] ++ "` " ++ problem ++ "; every personage needs a distinct, nonempty name");
    }
}

/// Full names already drawn, as ascending indices into the first × last
/// space, in a buffer the caller owns. Drawing without replacement keeps
/// every name distinct with no retry loop.
pub const NameDraw = struct {
    taken: []u32,
    len: usize = 0,

    /// `buf` bounds how many names this draw can hand out.
    pub fn init(buf: []u32) NameDraw {
        return .{ .taken = buf };
    }

    /// Draw one unused index: a rank among the unused indices, then the
    /// index at that rank. Requires room in the buffer and an unused name.
    fn next(self: *NameDraw, r: std.Random) u32 {
        std.debug.assert(self.len < self.taken.len and self.len < name_space);
        var index = r.uintLessThan(u32, @intCast(name_space - self.len));
        // Skip every taken index at or below the candidate, in ascending order.
        var at: usize = 0;
        while (at < self.len and self.taken[at] <= index) : (at += 1) index += 1;
        std.mem.copyBackwards(u32, self.taken[at + 1 .. self.len + 1], self.taken[at..self.len]);
        self.taken[at] = index;
        self.len += 1;
        return index;
    }
};

pub const Generated = struct {
    /// Static names-table memory.
    first: []const u8,
    last: []const u8,
    motives: personage.Motives,
    ambition: u8,
};

/// One personage's character. Draws, all from `stream`: a name rank, the
/// motive count, each motive's rank among the motives not yet held, then
/// the ambition.
pub fn generate(rng: *rng_mod.Rng, stream: rng_mod.Stream, drawn: *NameDraw) Generated {
    const r = rng.random(stream);
    const index = drawn.next(r);
    const pol = tuning.politics;
    const motive_count = r.intRangeAtMost(u8, pol.motive_count_min, pol.motive_count_max);
    var motives = personage.Motives.initEmpty();
    const all = std.enums.values(personage.Motive);
    for (0..motive_count) |held| {
        var rank = r.uintLessThan(usize, all.len - held);
        for (all) |m| {
            if (motives.contains(m)) continue;
            if (rank == 0) {
                motives.insert(m);
                break;
            }
            rank -= 1;
        }
    }
    return .{
        .first = names.first[index / names.last.len],
        .last = names.last[index % names.last.len],
        .motives = motives,
        .ambition = r.intRangeAtMost(u8, 0, pol.ambition_max),
    };
}

test "a full draw of the name space hands out every name exactly once" {
    var rng = rng_mod.Rng.init(5);
    var buf: [name_space]u32 = undefined;
    var drawn = NameDraw.init(&buf);
    var seen = [_]bool{false} ** name_space;
    for (0..name_space) |_| {
        const g = generate(&rng, .politics, &drawn);
        var first: usize = 0;
        while (!std.mem.eql(u8, names.first[first], g.first)) first += 1;
        var last: usize = 0;
        while (!std.mem.eql(u8, names.last[last], g.last)) last += 1;
        const index = first * names.last.len + last;
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |s| try std.testing.expect(s);
    for (buf[1..], buf[0 .. buf.len - 1]) |later, earlier| try std.testing.expect(later > earlier);
}

test "a name pool with an empty or repeated entry cannot name personages" {
    try std.testing.expectEqual(@as(?[]const u8, null), poolProblem(names.first));
    try std.testing.expectEqual(@as(?[]const u8, null), poolProblem(names.last));
    try std.testing.expectEqual(@as(?[]const u8, null), poolProblem(&.{ "Ann", "Bo" }));
    try std.testing.expectEqualStrings("has an empty entry", poolProblem(&.{ "Ann", "" }).?);
    try std.testing.expectEqualStrings("repeats an entry", poolProblem(&.{ "Ann", "Bo", "Ann" }).?);
}

test "motives and ambition stay inside the tuned bounds" {
    var rng = rng_mod.Rng.init(11);
    var buf: [400]u32 = undefined;
    var drawn = NameDraw.init(&buf);
    var counts = [_]u32{0} ** 4;
    var ambition_min: u8 = 255;
    var ambition_max: u8 = 0;
    for (0..buf.len) |_| {
        const g = generate(&rng, .politics, &drawn);
        try std.testing.expect(personage.motivesValid(g.motives));
        counts[g.motives.count()] += 1;
        try std.testing.expect(g.ambition <= tuning.politics.ambition_max);
        ambition_min = @min(ambition_min, g.ambition);
        ambition_max = @max(ambition_max, g.ambition);
    }
    // Both allowed counts occur, and the draws span the scale.
    try std.testing.expect(counts[2] > 0 and counts[3] > 0);
    try std.testing.expect(ambition_min < 10 and ambition_max > 90);
}

test "the generator draws only from the stream it is passed" {
    var a = rng_mod.Rng.init(77);
    var b = rng_mod.Rng.init(77);
    var buf_a: [8]u32 = undefined;
    var buf_b: [8]u32 = undefined;
    var drawn_a = NameDraw.init(&buf_a);
    var drawn_b = NameDraw.init(&buf_b);
    for (0..8) |_| {
        const ga = generate(&a, .politics, &drawn_a);
        const gb = generate(&b, .events, &drawn_b);
        _ = .{ ga, gb };
    }
    // Each state advanced only the stream it drew on.
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const fresh = rng_mod.Rng.init(77);
        const a_moved = !std.mem.eql(u8, &a.encode(stream), &fresh.encode(stream));
        const b_moved = !std.mem.eql(u8, &b.encode(stream), &fresh.encode(stream));
        try std.testing.expectEqual(stream == .politics, a_moved);
        try std.testing.expectEqual(stream == .events, b_moved);
    }
}
