//! The political world's progression (docs/p5d-conflict-world-design.md §C,
//! §K "Progression is independent of the player", P5d.1e). `advanceWorld`,
//! the markets-phase owner, moves due conflicts through discovery, the
//! strike and NPC-only resolution, and on the 1st `runSchemes` opens new
//! ones from the `political_events.zon` opening templates. Also the one
//! cause formatter and the load-time check every campaign's conflicts keep.
//! Player state, presence and visibility are never inputs, and the
//! contract board never reads a conflict.
//! No MekHQ counterpart: MekHQ has no persistent political conflicts
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const planet = @import("../domain/planet.zig");
const faction = @import("../domain/faction.zig");
const personage = @import("../domain/personage.zig");
const political_event = @import("../domain/political_event.zig");
const conflict = @import("../domain/conflict.zig");
const opfor = @import("../domain/opfor.zig");
const world_state_dom = @import("../domain/world_state.zig");
const logistics = @import("../econ/logistics.zig");
const personages = @import("personages.zig");
const world_state = @import("world_state.zig");
const table = @import("table.zig");
const rng_mod = @import("rng.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;

const Conflict = conflict.Conflict;
const Row = political_event.Row;

const world_count = planet.catalog.len;
const faction_count = faction.table.len;
const max_people = personages.max_count;

comptime {
    std.debug.assert(world_count <= std.math.maxInt(u16));
    std.debug.assert(faction_count <= std.math.maxInt(u8));
    std.debug.assert(political_event.table.events.len <= std.math.maxInt(u16));
}

// Every build checks what the template table shows the player (rules 33,
// 58): each name and the literal text of each cause is markup-safe.
comptime {
    @setEvalBranchQuota(1_000_000);
    const file = "data/tables/political_events.zon: ";
    for (political_event.table.events) |row| {
        if (!table.markupSafe(row.name)) @compileError(file ++ "a name is not markup-safe: " ++ row.key);
        var parts = political_event.CauseParts.init(row.cause);
        while (parts.next() catch unreachable) |part| switch (part) {
            .text => |text| if (!table.markupSafe(text)) @compileError(file ++ "a cause is not markup-safe: " ++ row.key),
            .placeholder => {},
        };
    }
}

// ---------------------------------------------------------------- reading

/// What `runSchemes` reads of a campaign, resolved once per call so the
/// candidate scan is indexed: personages by their position in
/// `gs.personages`, worlds by `planet.catalog` position, factions by
/// `faction.table` position.
const Context = struct {
    gs: *const GameState,
    today: u32,
    people: []const personage.Personage,
    /// Per personage: its seat world and its faction.
    seat: [max_people]?u16,
    faction_of: [max_people]?u8,
    /// Per world: its ruler and its faction.
    ruler: [world_count]?u32,
    world_faction: [world_count]?u8,
    /// Worlds with an unresolved conflict, and personages who instigated one.
    contested: [world_count]bool,
    busy: [max_people]bool,
    unresolved: usize,
    /// `personage.factionsHostile` between every pair.
    hostile: [faction_count][faction_count]bool,
    /// `beat[loser][winner]`: `winner` won a conflict against `loser`
    /// resolved within `recent_defeat_lookback_days`.
    beat: [faction_count][faction_count]bool,
    /// Factions with an `intelligence_chief` personage (decision E6).
    has_chief: [faction_count]bool,

    fn build(gs: *const GameState) error{CorruptSave}!Context {
        const people = gs.personages.values();
        if (people.len > max_people) return error.CorruptSave;
        var ctx: Context = .{
            .gs = gs,
            .today = gs.clock.day_index,
            .people = people,
            .seat = [_]?u16{null} ** max_people,
            .faction_of = [_]?u8{null} ** max_people,
            .ruler = [_]?u32{null} ** world_count,
            .world_faction = [_]?u8{null} ** world_count,
            .contested = [_]bool{false} ** world_count,
            .busy = [_]bool{false} ** max_people,
            .unresolved = 0,
            .hostile = undefined,
            .beat = [_][faction_count]bool{[_]bool{false} ** faction_count} ** faction_count,
            .has_chief = [_]bool{false} ** faction_count,
        };
        for (faction.table, 0..) |a, i| for (faction.table, 0..) |b, j| {
            ctx.hostile[i][j] = personage.factionsHostile(a.key, b.key);
        };
        for (planet.catalog, 0..) |*w, wi| ctx.world_faction[wi] = factionIndex(w.faction);
        for (people, 0..) |*p, pi| {
            ctx.seat[pi] = worldIndex(p.seat_planet_key);
            ctx.faction_of[pi] = factionIndex(p.faction_key);
            if (p.role == .planetary_ruler) if (ctx.seat[pi]) |wi| {
                ctx.ruler[wi] = @intCast(pi);
            };
            if (p.role == .intelligence_chief) if (ctx.faction_of[pi]) |fi| {
                ctx.has_chief[fi] = true;
            };
        }
        for (gs.conflicts.values()) |*c| {
            if (c.outcome) |outcome| {
                if (ctx.today -| c.expires_day > tuning.politics.recent_defeat_lookback_days) continue;
                const a = factionIndex(c.aggressor.faction_key) orelse return error.CorruptSave;
                const d = factionIndex(c.defender.faction_key) orelse return error.CorruptSave;
                switch (outcome) {
                    .aggressor_won => ctx.beat[d][a] = true,
                    .defender_held => ctx.beat[a][d] = true,
                }
                continue;
            }
            ctx.unresolved += 1;
            ctx.contested[worldIndex(c.planet_key) orelse return error.CorruptSave] = true;
            ctx.busy[gs.personages.getIndex(c.instigator) orelse return error.CorruptSave] = true;
        }
        return ctx;
    }
};

/// Whether world `wi` is within `scheme_reach_ly` of the seat `from`.
fn inReach(from: ?u16, wi: usize) bool {
    const at = from orelse return false;
    return planet.distanceLy(&planet.catalog[at], &planet.catalog[wi]) <= tuning.politics.scheme_reach_ly;
}

fn worldIndex(key: []const u8) ?u16 {
    for (planet.catalog, 0..) |w, i| if (std.mem.eql(u8, w.key, key)) return @intCast(i);
    return null;
}

fn factionIndex(key: []const u8) ?u8 {
    for (faction.table, 0..) |f, i| if (std.mem.eql(u8, f.key, key)) return @intCast(i);
    return null;
}

// ---------------------------------------------------------------- the rules

/// Whether a personage may instigate a template (§C producer): it holds one
/// of the template's roles and at least one of its motives, and its faction
/// is the catch-all pirate bucket exactly when the template is a pirate's.
pub fn instigatorEligible(p: *const personage.Personage, row: *const Row) bool {
    const role_ok = for (row.instigator_roles) |role| {
        if (role == p.role) break true;
    } else false;
    const motive_ok = for (row.motives) |m| {
        if (p.motives.contains(m)) break true;
    } else false;
    const pirate = std.mem.eql(u8, p.faction_key, personage.catch_all_faction_key);
    return role_ok and motive_ok and pirate == row.pirate;
}

/// A candidate's draw weight (§C producer): the template's weight times one
/// plus the instigator's ambition. The one weight owner.
pub fn schemeWeight(row: *const Row, instigator: *const personage.Personage) u64 {
    return @as(u64, row.weight) * (1 + @as(u64, instigator.ambition));
}

/// `hostile_world`: a hiring world of another faction hostile to the
/// instigator's (`personage.factionsHostile`), within `scheme_reach_ly` of
/// the instigator's seat, with at least `min_industry`. The target is its
/// ruler.
fn hostileWorld(ctx: *const Context, pi: usize, wi: usize, min_industry: u8) ?u32 {
    const ruler = ctx.ruler[wi] orelse return null;
    const wf = ctx.world_faction[wi] orelse return null;
    const pf = ctx.faction_of[pi] orelse return null;
    if (wf == pf or !ctx.hostile[pf][wf]) return null;
    if (planet.catalog[wi].industry < min_industry) return null;
    if (!inReach(ctx.seat[pi], wi)) return null;
    return ruler;
}

/// `recent_victor_world`: a hiring world of another faction that won a
/// conflict against the instigator's faction resolved within
/// `recent_defeat_lookback_days`, within `scheme_reach_ly` of the
/// instigator's seat. The target is its ruler.
fn recentVictorWorld(ctx: *const Context, pi: usize, wi: usize) ?u32 {
    const ruler = ctx.ruler[wi] orelse return null;
    const wf = ctx.world_faction[wi] orelse return null;
    const pf = ctx.faction_of[pi] orelse return null;
    if (wf == pf or !ctx.beat[pf][wf]) return null;
    if (!inReach(ctx.seat[pi], wi)) return null;
    return ruler;
}

/// `grudge_seat` and `rival_seat`: the seat of a personage among `related`
/// (those the instigator bears a grudge, or its rivals, in relation order).
/// The target is the first one seated there.
fn relatedSeat(ctx: *const Context, related: []const u32, wi: usize) ?u32 {
    for (related) |q| if (seatIs(ctx.seat[q], wi)) return q;
    return null;
}

fn seatIs(seat: ?u16, wi: usize) bool {
    const at = seat orelse return false;
    return at == wi;
}

/// `ally_foe_world`: a hiring world hostile to the faction of one of
/// `allies`, within `scheme_reach_ly` of that ally's seat. The target is its
/// ruler.
fn allyFoeWorld(ctx: *const Context, allies: []const u32, wi: usize) ?u32 {
    const ruler = ctx.ruler[wi] orelse return null;
    const wf = ctx.world_faction[wi] orelse return null;
    for (allies) |a| {
        const af = ctx.faction_of[a] orelse continue;
        if (ctx.hostile[af][wf] and inReach(ctx.seat[a], wi)) return ruler;
    }
    return null;
}

/// `own_seat`: the instigator's own seat, when its loyalty to its liege
/// (the liege relation's weight) is at most `secession_loyalty_max`. The
/// target is the instigator.
fn ownSeat(ctx: *const Context, pi: usize, liege: ?Liege, wi: usize) ?u32 {
    const l = liege orelse return null;
    if (!seatIs(ctx.seat[pi], wi) or l.loyalty > tuning.politics.secession_loyalty_max) return null;
    return @intCast(pi);
}

const Liege = struct { index: u32, loyalty: u8 };

fn liegeOf(ctx: *const Context, id: types.PersonageId) ?Liege {
    for (ctx.gs.personage_relations.items) |rel| if (rel.kind == .liege and rel.from == id) {
        return .{ .index = @intCast(ctx.gs.personages.getIndex(rel.to) orelse return null), .loyalty = rel.weight };
    };
    return null;
}

/// The personages `id` holds `kind` toward, in relation order: a grudge
/// from `id`, or a symmetric relation from either end.
fn relatedTo(alloc: std.mem.Allocator, ctx: *const Context, id: types.PersonageId, kind: personage.RelationKind) error{OutOfMemory}![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    errdefer out.deinit(alloc);
    for (ctx.gs.personage_relations.items) |rel| {
        if (rel.kind != kind) continue;
        const other = if (rel.from == id) rel.to else if (kind.symmetric() and rel.to == id) rel.from else continue;
        try out.append(alloc, @intCast(ctx.gs.personages.getIndex(other) orelse continue));
    }
    return out.toOwnedSlice(alloc);
}

/// The world a faction's strike force stages from against `target` (§A,
/// D19): the faction's world nearest it by `planet.distanceLy`, never
/// `target` itself, ties in catalogue order; null when the faction holds
/// no other world. The one staging owner.
pub fn stagingWorld(faction_key: []const u8, target: *const planet.Planet) ?*const planet.Planet {
    return stagingWorldIn(planet.catalog, faction_key, target);
}

fn stagingWorldIn(worlds: []const planet.Planet, faction_key: []const u8, target: *const planet.Planet) ?*const planet.Planet {
    var best: ?*const planet.Planet = null;
    var best_ly: u32 = std.math.maxInt(u32);
    for (worlds) |*w| {
        if (!std.mem.eql(u8, w.faction, faction_key) or std.mem.eql(u8, w.key, target.key)) continue;
        const ly = planet.distanceLy(w, target);
        if (ly < best_ly) {
            best = w;
            best_ly = ly;
        }
    }
    return best;
}

/// Days the strike force travels from its staging world to the target:
/// the shared travel rule (`logistics.daysForJumps`).
fn travelDays(staging: *const planet.Planet, target: *const planet.Planet) u32 {
    return logistics.daysForJumps(planet.jumpsBetween(staging, target));
}

// ---------------------------------------------------------------- opening

/// One scheme a month may open: who instigates which template against
/// which world, the target personage, and its draw weight.
const Candidate = struct {
    instigator: u32,
    template: u16,
    world: u16,
    target: u32,
    weight: u64,
};

/// Every candidate scheme, in personage order, then template-file order,
/// then catalogue order (§K step 3). A candidate's instigator meets
/// `instigatorEligible` and instigated no unresolved conflict; its target
/// world has no unresolved conflict, passes the template's rule, and the
/// aggressor's faction has a world to stage from. `alloc` owns the result.
fn candidates(alloc: std.mem.Allocator, ctx: *const Context) error{OutOfMemory}![]Candidate {
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer out.deinit(alloc);
    for (ctx.people, 0..) |*p, pi| {
        if (ctx.busy[pi]) continue;
        for (political_event.table.events, 0..) |*row, ti| {
            if (!instigatorEligible(p, row)) continue;
            const related: []u32 = switch (row.target) {
                .grudge_seat => try relatedTo(alloc, ctx, p.id, .grudge),
                .rival_seat => try relatedTo(alloc, ctx, p.id, .rival),
                .ally_foe_world => try relatedTo(alloc, ctx, p.id, .ally),
                .hostile_world, .recent_victor_world, .own_seat => &.{},
            };
            defer alloc.free(related);
            const liege = if (row.target == .own_seat) liegeOf(ctx, p.id) else null;
            for (0..world_count) |wi| {
                if (ctx.contested[wi]) continue;
                const target = switch (row.target) {
                    .hostile_world => hostileWorld(ctx, pi, wi, row.min_industry),
                    .recent_victor_world => recentVictorWorld(ctx, pi, wi),
                    .grudge_seat, .rival_seat => relatedSeat(ctx, related, wi),
                    .ally_foe_world => allyFoeWorld(ctx, related, wi),
                    .own_seat => ownSeat(ctx, pi, liege, wi),
                } orelse continue;
                const sides = sidesOf(ctx, @intCast(pi), row, @intCast(wi), target) orelse continue;
                if (stagingWorld(sides.aggressor.faction_key, &planet.catalog[wi]) == null) continue;
                try out.append(alloc, .{ .instigator = @intCast(pi), .template = @intCast(ti), .world = @intCast(wi), .target = target, .weight = schemeWeight(row, p) });
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

const Sides = struct { aggressor: conflict.Power, defender: conflict.Power };

/// A scheme's sides (§C): on the aggressor side the instigator and its
/// faction attack the target personage and the world's faction; on the
/// defender side (`own_seat`) the instigator's liege and its faction come
/// to retake the world from the instigator. Null for a defender-side
/// scheme without a liege.
fn sidesOf(ctx: *const Context, pi: u32, row: *const Row, wi: u16, target: u32) ?Sides {
    const p = &ctx.people[pi];
    const world_faction = planet.catalog[wi].faction;
    return switch (row.instigator_side) {
        .aggressor => .{
            .aggressor = .{ .faction_key = p.faction_key, .personage = p.id },
            .defender = .{ .faction_key = world_faction, .personage = ctx.people[target].id },
        },
        .defender => blk: {
            const liege = liegeOf(ctx, p.id) orelse return null;
            const l = &ctx.people[liege.index];
            break :blk .{
                .aggressor = .{ .faction_key = l.faction_key, .personage = l.id },
                .defender = .{ .faction_key = world_faction, .personage = p.id },
            };
        },
    };
}

/// The ids `runSchemes` opened, in draw order (rule 16).
pub const Opened = struct {
    ids: [tuning.politics.schemes_per_month]types.ConflictId = undefined,
    len: usize = 0,

    pub fn slice(self: *const Opened) []const types.ConflictId {
        return self.ids[0..self.len];
    }
};

/// Open this month's conflicts (§C producer, §A timeline; decisions E1, E6).
/// The caller runs it on the 1st of the month, after the day's due
/// transitions. In order, on `.politics`:
/// 1. every `candidates` entry is a scheme the month may open;
/// 2. up to `min(schemes_per_month, max_open_conflicts − unresolved)`
///    weighted draws (`schemeWeight`), each removing the candidates that
///    share its instigator or its target world;
/// 3. for each drawn scheme in draw order: the preparation days; the
///    staging world (`stagingWorld`); `strike_day = today + preparation +`
///    the travel from staging to target; the intelligence lag, less
///    `intel_chief_cut_days` when the defender's faction has an
///    `intelligence_chief`; `discovery_day` (`conflict.discoveryDay`); the
///    fighting days and `expires_day`; the defender's garrison
///    (`opfor.roll` for `garrison_duty`, scaled by `conflict.localForceLances`
///    with the world's security); and the strike force (`opfor.roll` for the
///    template's `strike_kind`).
/// A change to this order changes every campaign and needs a deliberate
/// re-pin. Nothing is logged: an opening is secret (§A). Validates and
/// prepares everything before the first mutation (rules 12, 16), so on
/// `OutOfMemory` or `CorruptSave` (a broken reference, or an id counter
/// that cannot hold the new ids) the campaign is unchanged.
pub fn runSchemes(gs: *GameState) error{ OutOfMemory, CorruptSave }!Opened {
    const ctx = try Context.build(gs);
    const scratch = gs.scratch();
    const pool = try candidates(scratch, &ctx);
    defer scratch.free(pool);
    const live = try scratch.alloc(bool, pool.len);
    defer scratch.free(live);
    @memset(live, true);

    var rng = gs.rng;
    const r = rng.random(.politics);
    const draws = @min(@as(usize, tuning.politics.schemes_per_month), @as(usize, tuning.politics.max_open_conflicts) -| ctx.unresolved);
    var chosen: [tuning.politics.schemes_per_month]usize = undefined;
    var n: usize = 0;
    var total: u64 = 0;
    for (pool) |c| total += c.weight;
    while (n < draws and total > 0) : (n += 1) {
        var pick = r.uintLessThan(u64, total);
        const at = for (pool, live, 0..) |c, alive, i| {
            if (!alive) continue;
            if (pick < c.weight) break i;
            pick -= c.weight;
        } else unreachable;
        chosen[n] = at;
        const drawn = pool[at];
        for (pool, live) |c, *alive| if (alive.* and (c.instigator == drawn.instigator or c.world == drawn.world)) {
            alive.* = false;
            total -= c.weight;
        };
    }

    if (gs.next_conflict_id == 0 or gs.next_conflict_id > std.math.maxInt(u32) - n) return error.CorruptSave;
    var planned: [tuning.politics.schemes_per_month]Conflict = undefined;
    for (chosen[0..n], planned[0..n], 0..) |at, *c, i| {
        c.* = try plan(&ctx, &rng, pool[at], @enumFromInt(gs.next_conflict_id + @as(u32, @intCast(i))));
    }

    const alloc = gs.allocator();
    try gs.conflicts.ensureUnusedCapacity(alloc, n);
    for (planned[0..n]) |*c| {
        c.template_key = try alloc.dupe(u8, c.template_key);
        c.planet_key = try alloc.dupe(u8, c.planet_key);
        c.aggressor.faction_key = try alloc.dupe(u8, c.aggressor.faction_key);
        c.defender.faction_key = try alloc.dupe(u8, c.defender.faction_key);
        c.staging_planet_key = try alloc.dupe(u8, c.staging_planet_key);
    }

    var opened: Opened = .{};
    for (planned[0..n]) |c| {
        gs.conflicts.putAssumeCapacity(c.id, c);
        opened.ids[opened.len] = c.id;
        opened.len += 1;
    }
    gs.next_conflict_id += @intCast(n);
    gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)] = rng.prngs[@intFromEnum(rng_mod.Stream.politics)];
    return opened;
}

/// One drawn scheme's conflict, its days and forces drawn on `rng`'s
/// `.politics` in `runSchemes`'s step-3 order. Its strings are static table
/// memory.
fn plan(ctx: *const Context, rng: *rng_mod.Rng, cand: Candidate, id: types.ConflictId) error{CorruptSave}!Conflict {
    const pol = tuning.politics;
    const row = &political_event.table.events[cand.template];
    const target = &planet.catalog[cand.world];
    const sides = sidesOf(ctx, cand.instigator, row, cand.world, cand.target) orelse return error.CorruptSave;
    const r = rng.random(.politics);
    const opened = ctx.today;
    const prep = r.intRangeAtMost(u32, pol.scheme_prep_days_min, pol.scheme_prep_days_max);
    const staging = stagingWorld(sides.aggressor.faction_key, target) orelse return error.CorruptSave;
    const strike = opened + prep + travelDays(staging, target);
    const intel_lag = r.intRangeAtMost(u32, pol.intel_lag_days_min, pol.intel_lag_days_max);
    const defender_faction = factionIndex(sides.defender.faction_key) orelse return error.CorruptSave;
    const chief_cut: u32 = if (ctx.has_chief[defender_faction]) pol.intel_chief_cut_days else 0;
    const discovery = conflict.discoveryDay(opened, intel_lag, chief_cut, strike);
    const fight = r.intRangeAtMost(u32, pol.fight_days_min, pol.fight_days_max);
    const year = ctx.gs.clock.date.year;
    var local = opfor.roll(rng, .politics, .garrison_duty, sides.defender.faction_key, year);
    const security: i16 = if (ctx.gs.world_states.get(target.key)) |ws| ws.security else 0;
    local.lances = conflict.localForceLances(local.lances, security);
    const strike_force = opfor.roll(rng, .politics, row.strike_kind, sides.aggressor.faction_key, year);
    return .{
        .id = id,
        .template_key = row.key,
        .planet_key = target.key,
        .aggressor = sides.aggressor,
        .defender = sides.defender,
        .instigator = ctx.people[cand.instigator].id,
        .staging_planet_key = staging.key,
        .opened_day = opened,
        .discovery_day = discovery,
        .strike_day = strike,
        .expires_day = strike + fight,
        .local_force = local,
        .strike_force = strike_force,
    };
}

// ---------------------------------------------------------------- progression

const DueKind = enum { discovery, strike, resolution };

/// One due transition, prepared: its log line, and for a resolution the
/// drawn outcome and the prepared world-state move.
const DueStep = struct {
    index: usize,
    kind: DueKind,
    log: state_mod.LogEntry,
    outcome: conflict.Outcome = .defender_held,
    world: world_state.PreparedWorldAdjust = undefined,
    /// The world's state before `commitDue` moved it; null when it had no row.
    prior_world: ?world_state_dom.WorldState = null,
};

/// Today's due transitions, every fallible step done (log text and room,
/// world-state room, the resolution draws on a copy of `.politics`).
const PreparedDue = struct {
    steps: []DueStep,
    politics: std.Random.DefaultPrng,
    prior_politics: std.Random.DefaultPrng,
    log_len: usize,

    fn deinit(self: *const PreparedDue, gs: *GameState) void {
        gs.scratch().free(self.steps);
    }
};

/// Prepare today's due transitions (§K step 2), by (day, `ConflictId`):
/// every unresolved conflict whose `discovery_day`, `strike_day` or
/// `expires_day` is today, in id order. Discovery and the strike each get
/// one `[politics]` line. At `expires_day` the conflict resolves NPC-only
/// (§C resolution; decision E4): one `.politics` draw below
/// `conflict.aggressorWinChanceBp` is the aggressor's win, the world moves
/// by `world_state.conflictWorldDelta` (one `[world]` line), and one
/// `[politics]` line names the result. Changes nothing but log, world-state
/// and arena room.
fn prepareDue(gs: *GameState) error{ OutOfMemory, CorruptSave }!PreparedDue {
    const today = gs.clock.day_index;
    var count: usize = 0;
    var resolutions: usize = 0;
    for (gs.conflicts.values()) |*c| {
        if (c.outcome != null) continue;
        if (c.discovery_day == today or c.strike_day == today or c.expires_day == today) count += 1;
        if (c.expires_day == today) resolutions += 1;
    }
    const steps = try gs.scratch().alloc(DueStep, count);
    errdefer gs.scratch().free(steps);
    try gs.reserveLog(count + resolutions);
    try gs.world_states.ensureUnusedCapacity(gs.allocator(), resolutions);
    var text = std.heap.ArenaAllocator.init(gs.scratch());
    defer text.deinit();
    const ta = text.allocator();

    var rng = gs.rng;
    const r = rng.random(.politics);
    var at: usize = 0;
    for (gs.conflicts.values(), 0..) |*c, index| {
        if (c.outcome != null) continue;
        const world = (planet.find(c.planet_key) orelse return error.CorruptSave).name;
        const aggressor = (faction.find(c.aggressor.faction_key) orelse return error.CorruptSave).name;
        const defender = (faction.find(c.defender.faction_key) orelse return error.CorruptSave).name;
        if (c.discovery_day == today) {
            steps[at] = .{ .index = index, .kind = .discovery, .log = try gs.prepareLog(.politics, .{}, "[politics] {s} learns of a threat to {s}: {s}", .{ defender, world, try causeText(ta, gs, c) }) };
            at += 1;
        } else if (c.strike_day == today) {
            steps[at] = .{ .index = index, .kind = .strike, .log = try gs.prepareLog(.politics, .{}, "[politics] fighting begins on {s}: {s} against {s}", .{ world, aggressor, defender }) };
            at += 1;
        } else if (c.expires_day == today) {
            const row = political_event.find(c.template_key) orelse return error.CorruptSave;
            const won = r.uintLessThan(u32, @intCast(types.full_bp)) < conflict.aggressorWinChanceBp(c.strike_force, c.local_force);
            const outcome: conflict.Outcome = if (won) .aggressor_won else .defender_held;
            steps[at] = .{
                .index = index,
                .kind = .resolution,
                .outcome = outcome,
                .world = try world_state.prepareWorldAdjust(gs, c.planet_key, world_state.conflictWorldDelta(outcome), row.name),
                .log = switch (outcome) {
                    .aggressor_won => try gs.prepareLog(.politics, .{}, "[politics] {s} takes {s} from {s}", .{ aggressor, world, defender }),
                    .defender_held => try gs.prepareLog(.politics, .{}, "[politics] {s} holds {s} against {s}", .{ defender, world, aggressor }),
                },
            };
            at += 1;
        }
    }
    std.debug.assert(at == count);
    return .{
        .steps = steps,
        .politics = rng.prngs[@intFromEnum(rng_mod.Stream.politics)],
        .prior_politics = gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)],
        .log_len = gs.event_log.items.len,
    };
}

/// Put prepared due transitions on the books, in order. Infallible; each
/// step records what `rollbackDue` restores.
fn commitDue(gs: *GameState, due: *PreparedDue) void {
    std.debug.assert(gs.event_log.items.len == due.log_len);
    for (due.steps) |*s| switch (s.kind) {
        .discovery, .strike => gs.commitLog(s.log),
        .resolution => {
            const c = &gs.conflicts.values()[s.index];
            c.outcome = s.outcome;
            s.prior_world = gs.world_states.get(c.planet_key);
            world_state.commitWorldAdjust(gs, s.world);
            gs.commitLog(s.log);
        },
    };
    gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)] = due.politics;
}

/// Undo a `commitDue` (rule 12's rollback guard): the outcomes, each
/// world's prior state (a row the commit added is removed again, last
/// first), the log and the `.politics` stream.
fn rollbackDue(gs: *GameState, due: *const PreparedDue) void {
    var i = due.steps.len;
    while (i > 0) {
        i -= 1;
        const s = &due.steps[i];
        if (s.kind != .resolution) continue;
        const c = &gs.conflicts.values()[s.index];
        if (s.prior_world) |prior| {
            gs.world_states.getPtr(c.planet_key).?.* = prior;
        } else {
            const added = gs.world_states.pop().?;
            std.debug.assert(std.mem.eql(u8, added.key, c.planet_key));
        }
        c.outcome = null;
    }
    gs.event_log.items.len = due.log_len;
    gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)] = due.prior_politics;
}

/// The markets-phase political step (§K "Progression is independent of the
/// player"): today's due transitions (`prepareDue`), then on the 1st of
/// the month `runSchemes`. NPC movements and beats are later increments'.
/// Reads no player state, presence or visibility. Failure-atomic: an error
/// leaves the campaign as it was (rules 12, 17).
pub fn advanceWorld(gs: *GameState) error{ OutOfMemory, CorruptSave }!void {
    var due = try prepareDue(gs);
    defer due.deinit(gs);
    commitDue(gs, &due);
    if (gs.clock.date.day != 1) return;
    _ = runSchemes(gs) catch |err| {
        rollbackDue(gs, &due);
        return err;
    };
}

// ---------------------------------------------------------------- text

pub const CauseError = error{ CorruptSave, OutOfMemory };

/// A conflict's cause sentence (rule 28: the one cause formatter): its
/// template's `cause` with `{instigator}` and `{target}` as each
/// personage's name and title ("Katrina Steiner (Archon of the Lyran
/// Commonwealth)"), `{world}` as the world's name and `{aggressor}` and
/// `{defender}` as the sides' faction names. The target is the defender's
/// personage. Plain text, not escaped and not stored; `alloc` owns it.
/// `CorruptSave` when the template, a personage, its title, the world or a
/// faction does not resolve.
pub fn causeText(alloc: std.mem.Allocator, gs: *const GameState, c: *const Conflict) CauseError![]const u8 {
    const row = political_event.find(c.template_key) orelse return error.CorruptSave;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var parts = political_event.CauseParts.init(row.cause);
    while (parts.next() catch return error.CorruptSave) |part| switch (part) {
        .text => |t| try out.appendSlice(alloc, t),
        .placeholder => |ph| switch (ph) {
            .instigator => try appendPersonage(alloc, &out, gs, c.instigator),
            .target => try appendPersonage(alloc, &out, gs, c.defender.personage),
            .world => try out.appendSlice(alloc, (planet.find(c.planet_key) orelse return error.CorruptSave).name),
            .aggressor => try out.appendSlice(alloc, (faction.find(c.aggressor.faction_key) orelse return error.CorruptSave).name),
            .defender => try out.appendSlice(alloc, (faction.find(c.defender.faction_key) orelse return error.CorruptSave).name),
        },
    };
    return out.toOwnedSlice(alloc);
}

fn appendPersonage(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), gs: *const GameState, id: types.PersonageId) CauseError!void {
    const p = gs.personages.get(id) orelse return error.CorruptSave;
    const title = personage.titleText(alloc, &p) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownSeat, error.UnknownKey => return error.CorruptSave,
    };
    defer alloc.free(title);
    try out.print(alloc, "{s} {s} ({s})", .{ p.first_name, p.last_name, title });
}

// ---------------------------------------------------------------- loading

/// A loaded campaign's conflicts keep every invariant opening and
/// progression keep (rule 47; docs/p5d-conflict-world-design.md §J). Runs
/// after the personage and relation checks. `CorruptSave` for: an id that
/// is none, differs from its key or is at or past `next_conflict_id`; an
/// unknown template, world or faction; a personage that is not in the
/// campaign; an instigator that is not the side personage its template
/// names; a staging world other than `stagingWorld`'s; days out of order;
/// `strike_day` less the travel not `opened_day` plus a preparation in
/// range, or fighting days out of range; `opened_day` after today; an
/// unresolved conflict at or past its `expires_day`, or a resolved one
/// before it; two unresolved conflicts on one world, or more than
/// `max_open_conflicts`; a force without a lance or with a negative BV or
/// tonnage.
pub fn validate(gs: *const GameState) error{CorruptSave}!void {
    const pol = tuning.politics;
    const today = gs.clock.day_index;
    var unresolved: usize = 0;
    for (gs.conflicts.values()) |*c| unresolved += @intFromBool(c.outcome == null);
    if (unresolved > pol.max_open_conflicts) return error.CorruptSave;
    var contested = [_]bool{false} ** world_count;
    for (gs.conflicts.keys(), gs.conflicts.values()) |id, *c| {
        if (c.id != id or id == .none or @intFromEnum(id) >= gs.next_conflict_id) return error.CorruptSave;
        const row = political_event.find(c.template_key) orelse return error.CorruptSave;
        const wi = worldIndex(c.planet_key) orelse return error.CorruptSave;
        const target = &planet.catalog[wi];
        if (factionIndex(c.aggressor.faction_key) == null or factionIndex(c.defender.faction_key) == null) return error.CorruptSave;
        for ([_]types.PersonageId{ c.aggressor.personage, c.defender.personage, c.instigator }) |pid| {
            if (!gs.personages.contains(pid)) return error.CorruptSave;
        }
        const side_personage = switch (row.instigator_side) {
            .aggressor => c.aggressor.personage,
            .defender => c.defender.personage,
        };
        if (c.instigator != side_personage) return error.CorruptSave;
        const staging = stagingWorld(c.aggressor.faction_key, target) orelse return error.CorruptSave;
        if (!std.mem.eql(u8, staging.key, c.staging_planet_key)) return error.CorruptSave;
        if (!(c.opened_day < c.discovery_day and c.discovery_day < c.strike_day and c.strike_day < c.expires_day)) return error.CorruptSave;
        const departs = @as(u64, c.strike_day) -| travelDays(staging, target);
        if (departs < @as(u64, c.opened_day) + pol.scheme_prep_days_min or departs > @as(u64, c.opened_day) + pol.scheme_prep_days_max) return error.CorruptSave;
        const fight = c.expires_day - c.strike_day;
        if (fight < pol.fight_days_min or fight > pol.fight_days_max) return error.CorruptSave;
        if (c.opened_day > today) return error.CorruptSave;
        if (c.outcome == null) {
            if (c.expires_day <= today or contested[wi]) return error.CorruptSave;
            contested[wi] = true;
        } else if (c.expires_day > today) return error.CorruptSave;
        for ([_]conflict.Force{ c.local_force, c.strike_force }) |f| {
            if (f.lances == 0 or f.lance_bv < 0) return error.CorruptSave;
        }
    }
}

// ---- Tests ----

const commands = @import("commands.zig");
const digest = @import("digest.zig");
const campaign_backup = @import("campaign_backup.zig");

fn createdForTest(gs: *GameState) !void {
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
}

/// Step the calendar to the next 1st of the month, running no phase.
fn toMonthStartForTest(gs: *GameState) void {
    gs.clock.advance();
    while (gs.clock.date.day != 1) gs.clock.advance();
}

fn personageIndexForTest(gs: *const GameState, key: []const u8) usize {
    for (gs.personages.values(), 0..) |p, i| if (std.mem.eql(u8, p.key, key)) return i;
    unreachable;
}

fn rowForTest(key: []const u8) *const Row {
    return political_event.find(key).?;
}

/// A conflict on `planet_key` between two personages, with its days set
/// from `opened` and forces of the given lance BV; it passes `validate`'s
/// timeline checks.
fn conflictForTest(gs: *GameState, aggressor: types.PersonageId, defender: types.PersonageId, planet_key: []const u8, opened: u32, strike_bv: i64, local_bv: i64) Conflict {
    const a = gs.personages.get(aggressor).?;
    const target = planet.find(planet_key).?;
    const staging = stagingWorld(a.faction_key, target).?;
    const strike = opened + tuning.politics.scheme_prep_days_min + travelDays(staging, target);
    const id: types.ConflictId = @enumFromInt(gs.next_conflict_id);
    gs.next_conflict_id += 1;
    return .{
        .id = id,
        .template_key = "border_grab",
        .planet_key = target.key,
        .aggressor = .{ .faction_key = a.faction_key, .personage = aggressor },
        .defender = .{ .faction_key = target.faction, .personage = defender },
        .instigator = aggressor,
        .staging_planet_key = staging.key,
        .opened_day = opened,
        .discovery_day = conflict.discoveryDay(opened, tuning.politics.intel_lag_days_min, 0, strike),
        .strike_day = strike,
        .expires_day = strike + tuning.politics.fight_days_min,
        .local_force = .{ .lances = 2, .quality = .regular, .lance_bv = local_bv, .lance_tons = 200 },
        .strike_force = .{ .lances = 2, .quality = .regular, .lance_bv = strike_bv, .lance_tons = 200 },
    };
}

/// The first world, in catalogue order, that `hostileWorld` admits for
/// personage `pi`, with the industry floor `min_industry`.
fn firstHostileForTest(ctx: *const Context, pi: usize, min_industry: u8) ?usize {
    for (0..world_count) |wi| if (hostileWorld(ctx, pi, wi, min_industry) != null) return wi;
    return null;
}

/// A ruler with a hostile world in reach, and that world.
fn borderRulerForTest(ctx: *const Context) struct { pi: usize, wi: usize } {
    for (ctx.people, 0..) |p, pi| {
        if (p.role != .planetary_ruler) continue;
        if (firstHostileForTest(ctx, pi, 0)) |wi| return .{ .pi = pi, .wi = wi };
    }
    unreachable;
}

test "hostile_world admits a hostile hiring world in reach and refuses one of the same faction, a friendly one, one out of reach and one below the industry floor" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73001 });
    defer gs.deinit();
    try createdForTest(&gs);
    const ctx = try Context.build(&gs);
    const found = borderRulerForTest(&ctx);
    const p = &ctx.people[found.pi];
    const seat = planet.find(p.seat_planet_key).?;
    try std.testing.expectEqual(ctx.ruler[found.wi].?, hostileWorld(&ctx, found.pi, found.wi, 0).?);
    // Expected sets from the tables: every admitted world is hostile, of
    // another faction, ruled and in reach; every other world is refused.
    var refused_same = false;
    var refused_far = false;
    for (planet.catalog, 0..) |*w, wi| {
        const admitted = hostileWorld(&ctx, found.pi, wi, 0) != null;
        const same = std.mem.eql(u8, w.faction, p.faction_key);
        const hostile = personage.factionsHostile(w.faction, p.faction_key);
        const near = planet.distanceLy(seat, w) <= tuning.politics.scheme_reach_ly;
        try std.testing.expectEqual(!same and hostile and near and personage.worldHasRuler(w), admitted);
        refused_same = refused_same or (same and near);
        refused_far = refused_far or (!same and hostile and !near and personage.worldHasRuler(w));
    }
    try std.testing.expect(refused_same and refused_far);
    // The industry floor: the same world at one more than its industry.
    const industry = planet.catalog[found.wi].industry;
    try std.testing.expectEqual(@as(?u32, null), hostileWorld(&ctx, found.pi, found.wi, industry + 1));
    try std.testing.expect(hostileWorld(&ctx, found.pi, found.wi, industry) != null);
}

test "recent_victor_world admits a world of a faction that recently beat the instigator's, and refuses it without or after that defeat" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73002 });
    defer gs.deinit();
    try createdForTest(&gs);
    const before = try Context.build(&gs);
    const found = borderRulerForTest(&before);
    try std.testing.expectEqual(@as(?u32, null), recentVictorWorld(&before, found.pi, found.wi));
    // The world's faction held a world against the instigator's faction.
    const p = before.people[found.pi];
    const victor_world = &planet.catalog[found.wi];
    var c = conflictForTest(&gs, p.id, before.people[before.ruler[found.wi].?].id, victor_world.key, 0, 1_000, 1_000);
    gs.clock.day_index = c.expires_day;
    c.outcome = .defender_held;
    try gs.conflicts.put(gs.allocator(), c.id, c);
    const after = try Context.build(&gs);
    try std.testing.expectEqual(after.ruler[found.wi].?, recentVictorWorld(&after, found.pi, found.wi).?);
    // The defeat was the instigator's own attack: a win by the world's
    // faction, not a loss, never admits it the other way round.
    const victor_pi = after.ruler[found.wi].?;
    try std.testing.expectEqual(@as(?u32, null), recentVictorWorld(&after, victor_pi, before.seat[found.pi].?));
    // Past the lookback the defeat is forgotten.
    gs.clock.day_index = c.expires_day + tuning.politics.recent_defeat_lookback_days + 1;
    const later = try Context.build(&gs);
    try std.testing.expectEqual(@as(?u32, null), recentVictorWorld(&later, found.pi, found.wi));
}

test "grudge_seat and rival_seat admit the related personage's seat and refuse every other world" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73003 });
    defer gs.deinit();
    try createdForTest(&gs);
    const scratch = std.testing.allocator;
    for ([_]personage.RelationKind{ .grudge, .rival }) |kind| {
        const ctx = try Context.build(&gs);
        // The first relation of the kind in the campaign.
        const rel = for (gs.personage_relations.items) |rel| {
            if (rel.kind == kind) break rel;
        } else unreachable;
        const holder = gs.personages.getIndex(rel.from).?;
        const other = gs.personages.getIndex(rel.to).?;
        const related = try relatedTo(scratch, &ctx, rel.from, kind);
        defer scratch.free(related);
        try std.testing.expect(std.mem.indexOfScalar(u32, related, @intCast(other)) != null);
        const seat = ctx.seat[other].?;
        try std.testing.expectEqual(@as(u32, @intCast(other)), relatedSeat(&ctx, related, seat).?);
        for (0..world_count) |wi| {
            const expected = for (related) |q| {
                if (seatIs(ctx.seat[q], wi)) break true;
            } else false;
            try std.testing.expectEqual(expected, relatedSeat(&ctx, related, wi) != null);
        }
        // A grudge runs one way: its target holds the holder only through
        // a grudge of its own; a rival reads from either end.
        const back = try relatedTo(scratch, &ctx, rel.to, kind);
        defer scratch.free(back);
        const own_grudge = for (gs.personage_relations.items) |r| {
            if (r.kind == .grudge and r.from == rel.to and r.to == rel.from) break true;
        } else false;
        try std.testing.expectEqual(kind == .rival or own_grudge, std.mem.indexOfScalar(u32, back, @intCast(holder)) != null);
    }
}

test "ally_foe_world admits a world hostile to an ally's faction in the ally's reach, and refuses one that is not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73004 });
    defer gs.deinit();
    try createdForTest(&gs);
    const ctx = try Context.build(&gs);
    const rel = for (gs.personage_relations.items) |rel| {
        if (rel.kind == .ally) break rel;
    } else unreachable;
    const ally = gs.personages.getIndex(rel.to).?;
    const allies = [_]u32{@intCast(ally)};
    const ally_seat = &planet.catalog[ctx.seat[ally].?];
    const ally_faction = ctx.people[ally].faction_key;
    var refused: usize = 0;
    for (planet.catalog, 0..) |*w, wi| {
        const expected = personage.worldHasRuler(w) and personage.factionsHostile(ally_faction, w.faction) and
            planet.distanceLy(ally_seat, w) <= tuning.politics.scheme_reach_ly;
        try std.testing.expectEqual(expected, allyFoeWorld(&ctx, &allies, wi) != null);
        refused += @intFromBool(!expected);
    }
    try std.testing.expect(refused > 0);
    try std.testing.expectEqual(@as(?u32, null), allyFoeWorld(&ctx, &.{}, ctx.seat[ally].?));
}

test "own_seat admits a ruler's own seat at or below the loyalty bound and refuses it above, or with no liege" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73005 });
    defer gs.deinit();
    try createdForTest(&gs);
    const rel = for (gs.personage_relations.items) |*rel| {
        if (rel.kind == .liege) break rel;
    } else unreachable;
    const pi = gs.personages.getIndex(rel.from).?;
    const seat = (try Context.build(&gs)).seat[pi].?;
    rel.weight = tuning.politics.secession_loyalty_max;
    var ctx = try Context.build(&gs);
    try std.testing.expectEqual(@as(u32, @intCast(pi)), ownSeat(&ctx, pi, liegeOf(&ctx, rel.from), seat).?);
    try std.testing.expectEqual(@as(?u32, null), ownSeat(&ctx, pi, liegeOf(&ctx, rel.from), (@as(usize, seat) + 1) % world_count));
    rel.weight = tuning.politics.secession_loyalty_max + 1;
    ctx = try Context.build(&gs);
    try std.testing.expectEqual(@as(?u32, null), ownSeat(&ctx, pi, liegeOf(&ctx, rel.from), seat));
    try std.testing.expectEqual(@as(?u32, null), ownSeat(&ctx, pi, null, seat));
    // The sides: the liege attacks and the instigator defends its seat.
    rel.weight = tuning.politics.secession_loyalty_max;
    ctx = try Context.build(&gs);
    const sides = sidesOf(&ctx, @intCast(pi), rowForTest("secession_revolt"), seat, @intCast(pi)).?;
    try std.testing.expectEqual(rel.to, sides.aggressor.personage);
    try std.testing.expectEqual(rel.from, sides.defender.personage);
}

test "a pirate template takes only a pirate's ruler and every other template only a non-pirate" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73006 });
    defer gs.deinit();
    try createdForTest(&gs);
    var pirate: ?*const personage.Personage = null;
    var lyran: ?*const personage.Personage = null;
    for (gs.personages.values()) |*p| {
        if (p.role != .planetary_ruler or !p.motives.contains(.profit)) continue;
        if (std.mem.eql(u8, p.faction_key, personage.catch_all_faction_key)) pirate = pirate orelse p;
        if (std.mem.eql(u8, p.faction_key, "LC")) lyran = lyran orelse p;
    }
    try std.testing.expect(instigatorEligible(pirate.?, rowForTest("pirate_predation")));
    try std.testing.expect(!instigatorEligible(lyran.?, rowForTest("pirate_predation")));
    try std.testing.expect(instigatorEligible(lyran.?, rowForTest("industrial_seizure")));
    try std.testing.expect(!instigatorEligible(pirate.?, rowForTest("industrial_seizure")));
    // A role or motive the template does not name refuses it.
    var heir = lyran.?.*;
    heir.role = .heir;
    try std.testing.expect(!instigatorEligible(&heir, rowForTest("industrial_seizure")));
    var no_motive = lyran.?.*;
    no_motive.motives = .initOne(.honor);
    try std.testing.expect(!instigatorEligible(&no_motive, rowForTest("industrial_seizure")));
    // The weight grows with ambition.
    var calm = lyran.?.*;
    calm.ambition = 0;
    try std.testing.expectEqual(@as(u64, rowForTest("border_grab").weight), schemeWeight(rowForTest("border_grab"), &calm));
    calm.ambition = 9;
    try std.testing.expectEqual(@as(u64, rowForTest("border_grab").weight) * 10, schemeWeight(rowForTest("border_grab"), &calm));
}

test "the staging world is the aggressor faction's nearest, ties in catalogue order, never the target" {
    const worlds = [_]planet.Planet{
        .{ .key = "target", .name = "Target", .faction = "LC", .x = 0, .y = 0, .industry = 1 },
        .{ .key = "far", .name = "Far", .faction = "DC", .x = 50, .y = 0, .industry = 1 },
        .{ .key = "tie_a", .name = "Tie A", .faction = "DC", .x = 0, .y = 20, .industry = 1 },
        .{ .key = "tie_b", .name = "Tie B", .faction = "DC", .x = 20, .y = 0, .industry = 1 },
        .{ .key = "other", .name = "Other", .faction = "FS", .x = 1, .y = 0, .industry = 1 },
    };
    try std.testing.expectEqualStrings("tie_a", stagingWorldIn(&worlds, "DC", &worlds[0]).?.key);
    // A target of the aggressor's own faction is never its own staging world.
    try std.testing.expectEqualStrings("tie_b", stagingWorldIn(&worlds, "DC", &worlds[2]).?.key);
    // The target's own faction stages from elsewhere, never the target.
    try std.testing.expectEqual(@as(?*const planet.Planet, null), stagingWorldIn(&worlds, "LC", &worlds[0]));
    try std.testing.expectEqual(@as(?*const planet.Planet, null), stagingWorldIn(&worlds, "CC", &worlds[0]));
    // On the real map, the owner equals a plain scan.
    const target = planet.find("skye").?;
    var best: ?*const planet.Planet = null;
    for (planet.catalog) |*w| if (std.mem.eql(u8, w.faction, "FWL") and (best == null or planet.distanceLy(w, target) < planet.distanceLy(best.?, target))) {
        best = w;
    };
    try std.testing.expectEqual(best.?, stagingWorld("FWL", target).?);
}

test "the first month start opens conflicts whose days follow the travel rule, and none at opening is logged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73007 });
    defer gs.deinit();
    try createdForTest(&gs);
    toMonthStartForTest(&gs);
    const logs = gs.event_log.items.len;
    const opened = try runSchemes(&gs);
    try std.testing.expectEqual(@as(usize, tuning.politics.schemes_per_month), opened.len);
    try std.testing.expectEqual(logs, gs.event_log.items.len);
    for (opened.slice(), 1..) |id, want| {
        try std.testing.expectEqual(@as(u32, @intCast(want)), @intFromEnum(id));
        const c = gs.conflicts.get(id).?;
        const target = planet.find(c.planet_key).?;
        const staging = planet.find(c.staging_planet_key).?;
        const travel = logistics.daysForJumps(planet.jumpsBetween(staging, target));
        const prep = c.strike_day - travel - c.opened_day;
        try std.testing.expect(prep >= tuning.politics.scheme_prep_days_min and prep <= tuning.politics.scheme_prep_days_max);
        try std.testing.expectEqual(gs.clock.day_index, c.opened_day);
        try std.testing.expect(c.opened_day < c.discovery_day and c.discovery_day < c.strike_day and c.strike_day < c.expires_day);
        try std.testing.expectEqual(conflict.Status.preparing, conflict.status(&c, gs.clock.day_index));
        try std.testing.expect(!std.mem.eql(u8, c.staging_planet_key, c.planet_key));
        try std.testing.expectEqualStrings(c.aggressor.faction_key, staging.faction);
    }
    try std.testing.expectEqual(@as(u32, @intCast(opened.len + 1)), gs.next_conflict_id);
    // The drawn pair shares neither instigator nor world.
    const a = gs.conflicts.values()[0];
    const b = gs.conflicts.values()[1];
    try std.testing.expect(a.instigator != b.instigator and !std.mem.eql(u8, a.planet_key, b.planet_key));
    try validate(&gs);
}

test "no second unresolved conflict opens on a world or for an instigator, and none opens at the cap" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73008 });
    defer gs.deinit();
    try createdForTest(&gs);
    toMonthStartForTest(&gs);
    _ = try runSchemes(&gs);
    const ctx = try Context.build(&gs);
    const pool = try candidates(std.testing.allocator, &ctx);
    defer std.testing.allocator.free(pool);
    for (pool) |c| for (gs.conflicts.values()) |*open| {
        try std.testing.expect(!std.mem.eql(u8, planet.catalog[c.world].key, open.planet_key));
        try std.testing.expect(ctx.people[c.instigator].id != open.instigator);
    };
    // At the cap: the unresolved count is the cap and nothing opens.
    var count = gs.conflicts.count();
    while (count < tuning.politics.max_open_conflicts) : (count = gs.conflicts.count()) {
        const more = try runSchemes(&gs);
        if (more.len == 0) break;
    }
    try std.testing.expectEqual(@as(usize, tuning.politics.max_open_conflicts), gs.conflicts.count());
    const before = digest.stateHash(&gs);
    try std.testing.expectEqual(@as(usize, 0), (try runSchemes(&gs)).len);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try validate(&gs);
}

test "two campaigns on one seed open the same conflicts over 24 months, an unrelated command changes none, and every invariant holds" {
    var a = GameState.init(std.testing.allocator, .{ .seed = 73009 });
    defer a.deinit();
    var b = GameState.init(std.testing.allocator, .{ .seed = 73009 });
    defer b.deinit();
    try createdForTest(&a);
    try createdForTest(&b);
    // One campaign hires; the political world never reads the player.
    _ = try commands.execute(&b, .{ .hire = .{ .first = "Grayson", .last = "Carlyle", .role = .mekwarrior } });
    var resolved: usize = 0;
    for (0..24) |_| {
        for ([_]*GameState{ &a, &b }) |g| {
            g.clock.advance();
            try advanceWorld(g);
            while (g.clock.date.day != 1) {
                g.clock.advance();
                try advanceWorld(g);
            }
        }
        try validate(&a);
        var ha = std.hash.Wyhash.init(0);
        var hb = std.hash.Wyhash.init(0);
        digest.update(&ha, a.conflicts);
        digest.update(&hb, b.conflicts);
        try std.testing.expectEqual(ha.final(), hb.final());
        try std.testing.expectEqualSlices(u8, &a.rng.encode(.politics), &b.rng.encode(.politics));
    }
    for (a.conflicts.values()) |*c| {
        try std.testing.expect(c.opened_day < c.discovery_day and c.discovery_day < c.strike_day and c.strike_day < c.expires_day);
        resolved += @intFromBool(c.outcome != null);
    }
    try std.testing.expect(a.conflicts.count() > 2 * tuning.politics.schemes_per_month and resolved > 0);
}

test "advancing the political world moves only the politics stream and leaves the board and listings alone" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73010 });
    defer gs.deinit();
    try createdForTest(&gs);
    toMonthStartForTest(&gs);
    const before = gs.rng;
    var board = std.hash.Wyhash.init(0);
    digest.update(&board, gs.contract_offers);
    digest.update(&board, gs.market_listings);
    digest.update(&board, gs.candidates);
    try advanceWorld(&gs);
    try std.testing.expect(gs.conflicts.count() > 0);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const moved = !std.mem.eql(u8, &before.encode(stream), &gs.rng.encode(stream));
        try std.testing.expectEqual(stream == .politics, moved);
    }
    var after = std.hash.Wyhash.init(0);
    digest.update(&after, gs.contract_offers);
    digest.update(&after, gs.market_listings);
    digest.update(&after, gs.candidates);
    try std.testing.expectEqual(board.final(), after.final());
}

/// A campaign holding one conflict of known forces on Skye, attacked from
/// a world hostile to the Lyran Commonwealth.
fn skyeConflictForTest(gs: *GameState, strike_bv: i64, local_bv: i64) !types.ConflictId {
    try createdForTest(gs);
    var attacker: ?types.PersonageId = null;
    var defender: ?types.PersonageId = null;
    for (gs.personages.values()) |p| {
        if (p.role == .faction_leader and std.mem.eql(u8, p.faction_key, "FWL")) attacker = p.id;
        if (p.role == .planetary_ruler and std.mem.eql(u8, p.seat_planet_key, "skye")) defender = p.id;
    }
    const c = conflictForTest(gs, attacker.?, defender.?, "skye", gs.clock.day_index, strike_bv, local_bv);
    try gs.conflicts.put(gs.allocator(), c.id, c);
    return c.id;
}

/// Run `advanceWorld` on day `day`, with a calendar date that is not the
/// 1st, so only due transitions run.
fn advanceOnForTest(gs: *GameState, day: u32) !void {
    gs.clock.day_index = day;
    gs.clock.date = .{ .year = 3025, .month = 3, .day = 15 };
    try advanceWorld(gs);
}

fn politicsLinesForTest(gs: *const GameState) usize {
    var n: usize = 0;
    for (gs.event_log.items) |e| n += @intFromBool(e.category == .politics);
    return n;
}

test "discovery, the strike and resolution happen on their days with one politics line each" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73011 });
    defer gs.deinit();
    const id = try skyeConflictForTest(&gs, 1_000, 1_000);
    const c = gs.conflicts.get(id).?;
    try advanceOnForTest(&gs, c.discovery_day - 1);
    try std.testing.expectEqual(@as(usize, 0), politicsLinesForTest(&gs));
    try advanceOnForTest(&gs, c.discovery_day);
    try std.testing.expectEqual(@as(usize, 1), politicsLinesForTest(&gs));
    try std.testing.expect(std.mem.indexOf(u8, gs.event_log.items[gs.event_log.items.len - 1].text, "learns of a threat to Skye") != null);
    try std.testing.expectEqual(conflict.Status.threatened, conflict.status(&gs.conflicts.get(id).?, gs.clock.day_index));
    try advanceOnForTest(&gs, c.strike_day);
    try std.testing.expectEqual(@as(usize, 2), politicsLinesForTest(&gs));
    try std.testing.expect(std.mem.indexOf(u8, gs.event_log.items[gs.event_log.items.len - 1].text, "fighting begins on Skye") != null);
    try advanceOnForTest(&gs, c.expires_day - 1);
    try std.testing.expectEqual(@as(?conflict.Outcome, null), gs.conflicts.get(id).?.outcome);
    try advanceOnForTest(&gs, c.expires_day);
    try std.testing.expectEqual(@as(usize, 3), politicsLinesForTest(&gs));
    try std.testing.expect(gs.conflicts.get(id).?.outcome != null);
    try advanceOnForTest(&gs, c.expires_day + 1);
    try std.testing.expectEqual(@as(usize, 3), politicsLinesForTest(&gs));
    try validate(&gs);
}

test "two due conflicts on one day go in id order" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73012 });
    defer gs.deinit();
    const first = try skyeConflictForTest(&gs, 1_000, 1_000);
    var second = gs.conflicts.get(first).?;
    second.id = @enumFromInt(gs.next_conflict_id);
    gs.next_conflict_id += 1;
    second.planet_key = "tharkad";
    try gs.conflicts.put(gs.allocator(), second.id, second);
    try advanceOnForTest(&gs, second.discovery_day);
    const log = gs.event_log.items;
    try std.testing.expect(std.mem.indexOf(u8, log[log.len - 2].text, "threat to Skye") != null);
    try std.testing.expect(std.mem.indexOf(u8, log[log.len - 1].text, "threat to Tharkad") != null);
}

/// A seed whose first `.politics` basis-point draw is below `chance` when
/// `below`, else at or above it.
fn politicsSeedForTest(chance: types.Bp, below: bool) u64 {
    var seed: u64 = 1;
    while (true) : (seed += 1) {
        var prng = rng_mod.Rng.fresh(seed, .politics);
        const roll: types.Bp = prng.random().uintLessThan(u32, @intCast(types.full_bp));
        if ((roll < chance) == below) return seed;
    }
}

test "resolution draws the outcome against the force chance and moves the world by the conflict delta, clamped" {
    for ([_]bool{ true, false }) |low| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 73013 });
        defer gs.deinit();
        const id = try skyeConflictForTest(&gs, 1_000, 3_000);
        const c = gs.conflicts.get(id).?;
        const chance = conflict.aggressorWinChanceBp(c.strike_force, c.local_force);
        try std.testing.expectEqual(@as(types.Bp, 2_500), chance);
        gs.rng.prngs[@intFromEnum(rng_mod.Stream.politics)] = rng_mod.Rng.fresh(politicsSeedForTest(chance, low), .politics);
        // A world near the top of its security range is clamped.
        try gs.world_states.put(gs.allocator(), "skye", .{ .security = 98, .employer_control = -97 });
        try advanceOnForTest(&gs, c.expires_day);
        const outcome: conflict.Outcome = if (low) .aggressor_won else .defender_held;
        try std.testing.expectEqual(@as(?conflict.Outcome, outcome), gs.conflicts.get(id).?.outcome);
        const delta = world_state.conflictWorldDelta(outcome);
        const ws = gs.world_states.get("skye").?;
        try std.testing.expectEqual(@as(i16, @min(100, 98 + delta.security)), ws.security);
        try std.testing.expectEqual(@as(i16, @max(-100, -97 + delta.employer_control)), ws.employer_control);
        try std.testing.expectEqual(delta.enemy_influence, ws.enemy_influence);
        try std.testing.expectEqual(delta.infrastructure_strain, ws.infrastructure_strain);
        try std.testing.expectEqual(gs.clock.day_index, ws.last_cause_day);
    }
}

test "a conflict on a world with no state row creates one through the world-state owner" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73014 });
    defer gs.deinit();
    const id = try skyeConflictForTest(&gs, 1_000, 1_000);
    try std.testing.expect(gs.world_states.get("skye") == null);
    try advanceOnForTest(&gs, gs.conflicts.get(id).?.expires_day);
    const delta = world_state.conflictWorldDelta(gs.conflicts.get(id).?.outcome.?);
    const ws = gs.world_states.get("skye").?;
    try std.testing.expectEqual(delta.security, ws.security);
    try std.testing.expectEqual(delta.civilian_support, ws.civilian_support);
    try std.testing.expectEqualStrings(rowForTest("border_grab").name, ws.last_cause);
}

/// Run `advanceWorld` on copies of `gs` whose arena and scratch fail at
/// allocation 0, 1, 2, … until one succeeds; every failed run leaves its
/// copy's digest equal to `gs`'s (rules 12, 69).
fn expectAdvanceWorldAtomicForTest(gs: *const GameState) !usize {
    const before = digest.stateHash(gs);
    var failures: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        var copy = try campaign_backup.take(gs);
        defer campaign_backup.discard(&copy);
        var failing = std.testing.FailingAllocator.init(copy.arena.child_allocator, .{ .fail_index = i });
        const backing = copy.arena.child_allocator;
        copy.arena.child_allocator = failing.allocator();
        defer copy.arena.child_allocator = backing;
        if (advanceWorld(&copy)) |_| {
            return failures;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&copy));
            failures += 1;
        }
    }
}

test "a month start that opens conflicts, and a day that resolves one, change nothing when any allocation fails" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73015 });
    defer gs.deinit();
    try createdForTest(&gs);
    toMonthStartForTest(&gs);
    try std.testing.expect(try expectAdvanceWorldAtomicForTest(&gs) > 0);
    try advanceWorld(&gs);
    try std.testing.expect(gs.conflicts.count() > 0);
    // The first resolution day, reached without its earlier transitions,
    // and a 1st of the month so the schemes run after it.
    const c = gs.conflicts.values()[0];
    gs.clock.day_index = c.expires_day;
    gs.clock.date = .{ .year = 3025, .month = 6, .day = 1 };
    try std.testing.expect(try expectAdvanceWorldAtomicForTest(&gs) > 0);
    try advanceWorld(&gs);
    try std.testing.expect(gs.conflicts.values()[0].outcome != null);
}

test "the cause names the instigator, the target, the world and the sides" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73016 });
    defer gs.deinit();
    const id = try skyeConflictForTest(&gs, 1_000, 1_000);
    var c = gs.conflicts.get(id).?;
    const text = try causeText(std.testing.allocator, &gs, &c);
    defer std.testing.allocator.free(text);
    const ruler = gs.personages.get(c.defender.personage).?;
    try std.testing.expect(std.mem.startsWith(u8, text, "Janos Marik (Captain-General of the Free Worlds League) covets Skye"));
    try std.testing.expect(std.mem.indexOf(u8, text, ruler.last_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(Steward of Skye)") != null);
    try std.testing.expect(table.markupSafe(text));
    try std.testing.expectError(error.OutOfMemory, causeText(std.testing.failing_allocator, &gs, &c));
    c.template_key = "nosuchtemplate";
    try std.testing.expectError(error.CorruptSave, causeText(std.testing.allocator, &gs, &c));
}
