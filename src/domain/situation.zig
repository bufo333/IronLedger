//! Actor-owned situations on an arc contract (ARCHITECTURE.md §8
//! "Situations"): the rows of data/tables/situations.zon and the record a
//! contract keeps of each situation it raised. A situation is owned by one
//! of the contract's actors, offers options that each name a concrete
//! cost, and leaves typed flags on the actor and the world.
//! No MekHQ counterpart (ROADMAP P5c; P4 operations design §§3,5).

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const arc_mod = @import("arc.zig");
const actor_mod = @import("actor.zig");
const world_state = @import("world_state.zig");

/// One answer to a situation.
pub const Option = struct {
    label: []const u8,
    /// What the answer costs the company, from the closed subset
    /// `events.isCost`; at least one is a burden (`events.isBurden`).
    costs: []const events.Effect,
    /// Applied to the owning actor (clamped by `actors.adjustRelationship`).
    relationship: actor_mod.RelDelta = .{},
    /// Applied to the contract world (clamped by `world_state.prepareWorldAdjust`).
    world: world_state.WorldDelta = .{},
    set_actor_flags: []const actor_mod.ActorFlag = &.{},
    set_world_flags: []const world_state.WorldFlag = &.{},
    /// What the actor or the world holds afterwards, shown beside the option.
    remembers: []const u8,

    pub fn actorFlags(self: *const Option) actor_mod.ActorFlags {
        var set: actor_mod.ActorFlags = .{};
        for (self.set_actor_flags) |f| set.insert(f);
        return set;
    }

    pub fn worldFlags(self: *const Option) world_state.WorldFlags {
        var set: world_state.WorldFlags = .{};
        for (self.set_world_flags) |f| set.insert(f);
        return set;
    }
};

/// One situations.zon row.
pub const Situation = struct {
    key: []const u8,
    /// The arc whose contracts raise it.
    arc: []const u8,
    /// The actor archetype that owns it; attached to the arc.
    owner: []const u8,
    /// The beat (a key of the arc's beats) from which it may come up.
    min_beat: []const u8,
    /// A callback: it comes up only while the owner carries this flag.
    requires_actor_flag: ?actor_mod.ActorFlag = null,
    /// What the owner brings, following the owner's name.
    title: []const u8,
    /// Why a callback came up; present exactly when a flag is required.
    callback_note: []const u8 = "",
    /// The answer that applies at the deadline.
    default_choice: u8,
    options: []const Option,

    /// The index of `min_beat` in the arc's beats (validated at build time).
    pub fn minBeatIndex(self: *const Situation) u8 {
        const a = arc_mod.find(self.arc).?;
        for (a.beats, 0..) |b, i| if (std.mem.eql(u8, b.key, self.min_beat)) return @intCast(i);
        unreachable;
    }

    /// The decision inbox's view of the options: label and costs, from
    /// static storage built with the table.
    pub fn eventOptions(self: *const Situation) []const events.Option {
        return event_options[self.indexInTable()];
    }

    fn indexInTable(self: *const Situation) usize {
        return (@intFromPtr(self) - @intFromPtr(table.situations.ptr)) / @sizeOf(Situation);
    }
};

pub const Table = struct { situations: []const Situation };

pub const table: Table = @import("situations_zon");

/// Option counts a situation may offer, and costs an option may name.
pub const min_options = 2;
pub const max_options = 3;
pub const max_costs = 4;

/// What a contract remembers of one situation it raised.
pub const SituationRecord = struct {
    /// The situations.zon row's key.
    key: []const u8,
    /// The day it came up.
    day: u32,
    /// The contract's actor who owns it.
    actor: types.ActorId,
    /// The answer applied, by option index; null while it awaits one.
    choice: ?u8 = null,
};

/// The row with this key, or null.
pub fn find(key: []const u8) ?*const Situation {
    for (table.situations) |*s| if (std.mem.eql(u8, s.key, key)) return s;
    return null;
}

/// Does any row belong to this arc? Its contracts raise situations in
/// place of the monthly event deck (`contract_events.rollMonthly`).
pub fn arcHasSituations(arc_key: []const u8) bool {
    if (arc_key.len == 0) return false;
    for (table.situations) |s| if (std.mem.eql(u8, s.arc, arc_key)) return true;
    return false;
}

const event_options: [table.situations.len][]const events.Option = blk: {
    var all: [table.situations.len][]const events.Option = undefined;
    for (table.situations, 0..) |s, i| {
        var opts: [s.options.len]events.Option = undefined;
        for (s.options, 0..) |o, j| opts[j] = .{ .label = o.label, .effects = o.costs };
        const final = opts;
        all[i] = &final;
    }
    break :blk all;
};

// ---- Validation (rule 58) --------------------------------------------------

/// A table defect: what is wrong, and the row it is wrong in.
pub const Defect = struct { what: []const u8, key: []const u8 };

/// The first defect in `t`, or null. The build refuses a table with one
/// (the comptime block below); flags that exclude each other are refused
/// by `sim/situations.flagDefect`, beside their owners, and string markup
/// safety is checked by the data walker in `sim/table.zig`.
pub fn defect(t: Table) ?Defect {
    for (t.situations, 0..) |s, i| {
        if (s.key.len == 0) return .{ .what = "empty key", .key = s.key };
        for (t.situations[0..i]) |prior| if (std.mem.eql(u8, prior.key, s.key)) return .{ .what = "duplicate key", .key = s.key };
        if (s.title.len == 0) return .{ .what = "empty title", .key = s.key };
        const a = arc_mod.find(s.arc) orelse return .{ .what = "unknown arc", .key = s.key };
        const beat_found = for (a.beats) |b| {
            if (std.mem.eql(u8, b.key, s.min_beat)) break true;
        } else false;
        if (!beat_found) return .{ .what = "min_beat is not a beat of its arc", .key = s.key };
        const owner = actor_mod.find(s.owner) orelse return .{ .what = "unknown owner archetype", .key = s.key };
        const attached = for (owner.arcs) |k| {
            if (std.mem.eql(u8, k, s.arc)) break true;
        } else false;
        if (!attached) return .{ .what = "owner archetype does not attach to the arc", .key = s.key };
        if ((s.requires_actor_flag != null) != (s.callback_note.len > 0)) return .{ .what = "callback_note is required exactly when a flag is", .key = s.key };
        if (s.options.len < min_options or s.options.len > max_options) return .{ .what = "option count out of range", .key = s.key };
        if (s.default_choice >= s.options.len) return .{ .what = "default_choice out of range", .key = s.key };
        for (s.options) |o| {
            if (o.label.len == 0 or o.remembers.len == 0) return .{ .what = "option without a label or a remembers phrase", .key = s.key };
            if (o.costs.len == 0 or o.costs.len > max_costs) return .{ .what = "option cost count out of range", .key = s.key };
            var burden = false;
            for (o.costs) |c| {
                if (!events.isCost(c)) return .{ .what = "a cost outside the situation cost subset", .key = s.key };
                if (events.isBurden(c)) burden = true;
            }
            if (!burden) return .{ .what = "a free option (no cost takes anything)", .key = s.key };
        }
    }
    return null;
}

comptime {
    @setEvalBranchQuota(200_000);
    if (defect(table)) |d| @compileError("situations.zon: " ++ d.what ++ ": " ++ d.key);
}

// ---- Tests -----------------------------------------------------------------

test "data: situations.zon loads, validates and serves inbox options" {
    try std.testing.expect(defect(table) == null);
    for (table.situations) |*s| {
        try std.testing.expectEqual(s, find(s.key).?);
        try std.testing.expect(arcHasSituations(s.arc));
        const opts = s.eventOptions();
        try std.testing.expectEqual(s.options.len, opts.len);
        for (s.options, opts) |o, e| {
            try std.testing.expectEqualStrings(o.label, e.label);
            try std.testing.expectEqual(o.costs.ptr, e.effects.ptr);
        }
        try std.testing.expectEqualStrings(s.min_beat, arc_mod.find(s.arc).?.beats[s.minBeatIndex()].key);
    }
    try std.testing.expect(find("__no_such_situation__") == null);
    try std.testing.expect(!arcHasSituations(""));
}

test "the table check refuses each defect it names" {
    const ok_option: Option = .{ .label = "pay", .costs = &.{.{ .cash = -1 }}, .remembers = "paid" };
    const base: Situation = .{ .key = "s", .arc = "fracturing_garrison", .owner = "black_market", .min_beat = "beginning", .title = "t", .default_choice = 0, .options = &.{ ok_option, ok_option } };
    try std.testing.expect(defect(.{ .situations = &.{base} }) == null);

    const Case = struct { what: []const u8, row: Situation };
    var free = base;
    free.options = &.{ ok_option, .{ .label = "x", .costs = &.{.{ .cash = 5 }}, .remembers = "r" } };
    var outside = base;
    outside.options = &.{ ok_option, .{ .label = "x", .costs = &.{ .{ .cash = -1 }, .{ .xp_all = 1 } }, .remembers = "r" } };
    var no_note = base;
    no_note.requires_actor_flag = .did_business;
    var stray_note = base;
    stray_note.callback_note = "why";
    var bad_beat = base;
    bad_beat.min_beat = "breakthrough";
    var bad_arc = base;
    bad_arc.arc = "__no_arc__";
    var bad_owner = base;
    bad_owner.owner = "__no_owner__";
    var foreign_owner = base;
    foreign_owner.owner = "relief_liaison";
    var bad_default = base;
    bad_default.default_choice = 2;
    var one_option = base;
    one_option.options = &.{ok_option};
    var no_costs = base;
    no_costs.options = &.{ ok_option, .{ .label = "x", .costs = &.{}, .remembers = "r" } };
    const cases = [_]Case{
        .{ .what = "a free option (no cost takes anything)", .row = free },
        .{ .what = "a cost outside the situation cost subset", .row = outside },
        .{ .what = "callback_note is required exactly when a flag is", .row = no_note },
        .{ .what = "callback_note is required exactly when a flag is", .row = stray_note },
        .{ .what = "min_beat is not a beat of its arc", .row = bad_beat },
        .{ .what = "unknown arc", .row = bad_arc },
        .{ .what = "unknown owner archetype", .row = bad_owner },
        .{ .what = "owner archetype does not attach to the arc", .row = foreign_owner },
        .{ .what = "default_choice out of range", .row = bad_default },
        .{ .what = "option count out of range", .row = one_option },
        .{ .what = "option cost count out of range", .row = no_costs },
    };
    for (cases) |case| {
        const d = defect(.{ .situations = &.{case.row} }) orelse return error.TestExpectedDefect;
        try std.testing.expectEqualStrings(case.what, d.what);
    }
    const dup = defect(.{ .situations = &.{ base, base } }).?;
    try std.testing.expectEqualStrings("duplicate key", dup.what);
}
