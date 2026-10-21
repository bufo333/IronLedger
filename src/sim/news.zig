//! News reach: who hears of a political happening
//! (docs/p5d-conflict-world-design.md §K "Reach: who hears about it";
//! P5d.1g; decision D10), and the load-time check every campaign's news
//! items keep. `newsReach` is the one reach owner; `politics.prepareDue`
//! asks it whether a due step also makes news. Reach never feeds
//! progression: it draws nothing and changes nothing.
//! No MekHQ counterpart: MekHQ has no political news (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const planet = @import("../domain/planet.zig");
const news_dom = @import("../domain/news.zig");
const posture = @import("posture.zig");
const GameState = @import("state.zig").GameState;

/// Whether a happening `distance_ly` light-years from a presence is heard
/// there (§K "Threshold"; decision D10): at most `news_reach_ly`,
/// inclusive. Distances are `planet.distanceLy`'s whole light-years.
pub fn withinReach(distance_ly: u32) bool {
    return distance_ly <= tuning.politics.news_reach_ly;
}

/// The presence a happening is heard from, and how far away it is.
pub const Reach = struct {
    distance_ly: u32,
    from: news_dom.PresenceKind,
    /// The presence's world, a `planets.zon` key.
    from_planet_key: []const u8,
};

/// A presence and its tie-break key: an HQ before a company, then the
/// lower id.
const Candidate = struct {
    reach: Reach,
    id: u32,

    fn before(self: Candidate, other: Candidate) bool {
        if (self.reach.distance_ly != other.reach.distance_ly) return self.reach.distance_ly < other.reach.distance_ly;
        if (self.reach.from != other.reach.from) return self.reach.from == .hq;
        return self.id < other.id;
    }
};

/// Who hears of a happening on `planet_key` today (§K "Reach"): the nearest
/// presence `withinReach`, or null when none is. Presences are every HQ's
/// world and every company's world (`posture.companyWorld`: its contract's
/// world en route or on station, the world it idles on, else its home HQ's,
/// also while returning). Equal distances go to an HQ before a company,
/// then to the lower id. `CorruptSave` when the world or a presence's world
/// is not in the catalogue. Reads presences only: draws nothing, mutates
/// nothing.
pub fn newsReach(gs: *GameState, planet_key: []const u8) error{CorruptSave}!?Reach {
    const world = planet.find(planet_key) orelse return error.CorruptSave;
    var best: ?Candidate = null;
    for (gs.hqs.values()) |*h| {
        const at = planet.find(h.planet_key) orelse return error.CorruptSave;
        consider(&best, .{ .reach = .{ .distance_ly = planet.distanceLy(world, at), .from = .hq, .from_planet_key = at.key }, .id = @intFromEnum(h.id) });
    }
    for (gs.forces.values()) |*f| {
        if (f.echelon != .company) continue;
        const key = posture.companyWorld(gs, f.id) orelse continue;
        const at = planet.find(key) orelse return error.CorruptSave;
        consider(&best, .{ .reach = .{ .distance_ly = planet.distanceLy(world, at), .from = .company, .from_planet_key = at.key }, .id = @intFromEnum(f.id) });
    }
    return if (best) |b| b.reach else null;
}

fn consider(best: *?Candidate, c: Candidate) void {
    if (!withinReach(c.reach.distance_ly)) return;
    if (best.*) |b| if (!c.before(b)) return;
    best.* = c;
}

/// A loaded campaign's news items keep every invariant emission keeps
/// (rule 47; docs/p5d-conflict-world-design.md §K "Persistence"). Runs
/// after `politics.validate`. `CorruptSave` for: a counter of 0; an id that
/// is none, differs from its key, is not above the one before it (items go
/// in emission order) or is at or past `next_news_id`; a conflict that is
/// not loaded or is a standing need; an item whose day (the domain's
/// `day`) has no calendar date (`Clock.dateOf`: it is after today, or the
/// clock counts it back before the earliest date); a resolution of an unresolved
/// conflict; a presence world not in the catalogue, or one beyond reach of
/// the conflict's world (`withinReach`); empty text or text that is not
/// UTF-8; or two items of one kind for one conflict.
pub fn validate(gs: *const GameState) error{CorruptSave}!void {
    if (gs.next_news_id == 0) return error.CorruptSave;
    var previous: u32 = @intFromEnum(types.NewsId.none);
    const items = gs.news_items.values();
    for (gs.news_items.keys(), items, 0..) |id, *item, i| {
        if (item.id != id or @intFromEnum(id) <= previous or @intFromEnum(id) >= gs.next_news_id) return error.CorruptSave;
        previous = @intFromEnum(id);
        const c = gs.conflicts.getPtr(item.conflict) orelse return error.CorruptSave;
        if (c.family == .standing) return error.CorruptSave;
        const day = news_dom.day(item, c) orelse return error.CorruptSave;
        _ = gs.clock.dateOf(day) catch return error.CorruptSave;
        if (item.kind == .resolution and c.outcome == null) return error.CorruptSave;
        const distance = news_dom.reachLy(item, c) orelse return error.CorruptSave;
        if (!withinReach(distance)) return error.CorruptSave;
        if (item.text.len == 0 or !std.unicode.utf8ValidateSlice(item.text)) return error.CorruptSave;
        for (items[0..i]) |*earlier| {
            if (earlier.conflict == item.conflict and earlier.kind == item.kind) return error.CorruptSave;
        }
    }
}

/// One item heard today: a conflict opened on `world_key`
/// (`politics.openConflictForTest`), the seat HQ moved onto that world, and
/// its discovery day reached mid-month through `politics.advanceWorld`.
/// Returns the item's id. Tests only.
pub fn heardForTest(gs: *GameState, world_key: []const u8) !types.NewsId {
    std.debug.assert(@import("builtin").is_test);
    const politics = @import("politics.zig");
    const id = try politics.openConflictForTest(gs, world_key, "border_grab");
    gs.hqs.getPtr(gs.seat()).?.planet_key = gs.conflicts.get(id).?.planet_key;
    gs.clock.day_index = gs.conflicts.get(id).?.discovery_day;
    gs.clock.date = .{ .year = 3025, .month = 3, .day = 15 };
    try politics.advanceWorld(gs);
    const last = gs.news_items.values()[gs.news_items.count() - 1];
    std.debug.assert(last.conflict == id and last.kind == .discovery);
    return last.id;
}

// ---- Tests ----

const founding = @import("founding.zig");

/// A campaign with its seat HQ on `hq_world` and one company at home.
fn campaignForTest(gs: *GameState, hq_world: []const u8) !types.ForceId {
    const home = try founding.createCommander(gs, "T", .LC, .line_officer);
    gs.hqs.getPtr(home).?.planet_key = hq_world;
    _ = try @import("starter_company.zig").generateInto(gs, "Alpha");
    for (gs.forces.values()) |f| if (f.echelon == .company) return f.id;
    return error.TestNoCompany;
}

test "a happening is heard at 99 and 100 light-years and not at 101" {
    // Decision D10 at the tuned threshold: inclusive, whole light-years.
    const reach = tuning.politics.news_reach_ly;
    try std.testing.expectEqual(@as(u32, 100), reach);
    try std.testing.expect(withinReach(reach - 1));
    try std.testing.expect(withinReach(reach));
    try std.testing.expect(!withinReach(reach + 1));
    try std.testing.expect(withinReach(0));
}

test "reach is the nearest presence within the threshold on the real map, an HQ before a company at equal distance" {
    const skye = planet.find("skye").?;
    // The catalogue's farthest world in reach of Skye and its nearest one
    // beyond it.
    var near: ?*const planet.Planet = null;
    var far: ?*const planet.Planet = null;
    for (planet.catalog) |*w| {
        const d = planet.distanceLy(w, skye);
        if (withinReach(d) and (near == null or d > planet.distanceLy(near.?, skye))) near = w;
        if (!withinReach(d) and (far == null or d < planet.distanceLy(far.?, skye))) far = w;
    }
    try std.testing.expect(planet.distanceLy(near.?, skye) > 0);

    var gs = GameState.init(std.testing.allocator, .{ .seed = 75001 });
    defer gs.deinit();
    const co = try campaignForTest(&gs, near.?.key);
    const hq = gs.hqs.values()[0].id;
    // In reach at the edge: the HQ (its company at home ties, and loses).
    const edge = (try newsReach(&gs, "skye")).?;
    try std.testing.expectEqual(planet.distanceLy(near.?, skye), edge.distance_ly);
    try std.testing.expectEqual(news_dom.PresenceKind.hq, edge.from);
    try std.testing.expectEqualStrings(near.?.key, edge.from_planet_key);
    // Just beyond it, with the company at home there too: no one hears.
    gs.hqs.getPtr(hq).?.planet_key = far.?.key;
    try std.testing.expectEqual(@as(?Reach, null), try newsReach(&gs, "skye"));

    // Rule 71, two presences at unequal distances: the nearer one hears,
    // whichever kind it is.
    const company = gs.forces.getPtr(co).?;
    gs.hqs.getPtr(hq).?.planet_key = "galatea";
    company.location_planet = "skye";
    const nearer_company = (try newsReach(&gs, "skye")).?;
    try std.testing.expectEqual(news_dom.PresenceKind.company, nearer_company.from);
    try std.testing.expectEqual(@as(u32, 0), nearer_company.distance_ly);
    gs.hqs.getPtr(hq).?.planet_key = "skye";
    company.location_planet = "galatea";
    const nearer_hq = (try newsReach(&gs, "skye")).?;
    try std.testing.expectEqual(news_dom.PresenceKind.hq, nearer_hq.from);
    try std.testing.expectEqualStrings("skye", nearer_hq.from_planet_key);
    // The company hears where the HQ cannot.
    gs.hqs.getPtr(hq).?.planet_key = far.?.key;
    const afield = (try newsReach(&gs, "skye")).?;
    try std.testing.expectEqual(news_dom.PresenceKind.company, afield.from);
    try std.testing.expectEqualStrings("galatea", afield.from_planet_key);
    try std.testing.expectEqual(planet.distanceLy(planet.find("galatea").?, skye), afield.distance_ly);
    // Equal distance: the company on the HQ's world loses the tie.
    gs.hqs.getPtr(hq).?.planet_key = "galatea";
    try std.testing.expectEqual(news_dom.PresenceKind.hq, (try newsReach(&gs, "skye")).?.from);

    // A world or a presence's world outside the catalogue is corruption.
    try std.testing.expectError(error.CorruptSave, newsReach(&gs, "nowhere"));
    company.location_planet = "nowhere";
    try std.testing.expectError(error.CorruptSave, newsReach(&gs, "skye"));
}

test "a campaign holding two items of one kind for one conflict is corrupt, as the schema also refuses" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 75002 });
    defer gs.deinit();
    // The command seats the personages a conflict needs.
    _ = try @import("commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    gs.hqs.getPtr(gs.seat()).?.planet_key = "skye";
    const id = try @import("politics.zig").openConflictForTest(&gs, "skye", "border_grab");
    gs.clock.day_index = gs.conflicts.get(id).?.discovery_day;
    const item: news_dom.NewsItem = .{ .id = @enumFromInt(1), .kind = .discovery, .conflict = id, .reach_from = .hq, .reach_from_planet_key = "skye", .text = "Lyran Commonwealth learns of a threat to Skye" };
    try gs.news_items.put(gs.allocator(), item.id, item);
    gs.next_news_id = 2;
    try validate(&gs);
    var again = item;
    again.id = @enumFromInt(2);
    try gs.news_items.put(gs.allocator(), again.id, again);
    gs.next_news_id = 3;
    try std.testing.expectError(error.CorruptSave, validate(&gs));
    gs.news_items.getPtr(again.id).?.kind = .strike;
    gs.clock.day_index = gs.conflicts.get(id).?.strike_day.?;
    try validate(&gs);
}

test "a campaign whose clock counts its news back before the calendar's first date is corrupt" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 75003 });
    defer gs.deinit();
    _ = try @import("commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    _ = try heardForTest(&gs, "skye");
    try validate(&gs);
    // An inconsistent clock: far more days have passed than 3025 holds.
    gs.clock.day_index = std.math.maxInt(u32);
    try std.testing.expectError(error.CorruptSave, validate(&gs));
}
