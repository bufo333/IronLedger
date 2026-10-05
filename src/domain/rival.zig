//! Persistent rival companies and the narrow standing/status model.
//! A rival is introduced by a contract arc and persists across contracts;
//! encountering the same faction/archetype on a later contract surfaces the
//! prior standing. No MekHQ counterpart (P4 operations design §§3,5).

const std = @import("std");
const types = @import("types.zig");
const arc_mod = @import("arc.zig");
const actor_mod = @import("actor.zig");

/// Re-export FactionSide from actor.zig (employer/enemy).
pub const FactionSide = actor_mod.FactionSide;

/// Operational doctrine carried by the rival company.
pub const RivalDoctrine = enum {
    aggressive,
    cautious,
    attritional,
    opportunist,
    honorable,

    /// Short display label.
    pub fn label(self: RivalDoctrine) []const u8 {
        return switch (self) {
            .aggressive => "aggressive",
            .cautious => "cautious",
            .attritional => "attritional",
            .opportunist => "opportunist",
            .honorable => "honorable",
        };
    }
};

/// Derived relationship status from standing.
pub const RivalStatus = enum {
    hostile,
    active,
    allied,

    /// Short display label.
    pub fn label(self: RivalStatus) []const u8 {
        return switch (self) {
            .hostile => "hostile",
            .active => "active",
            .allied => "allied",
        };
    }
};

/// Min/max bounds for rival standing (rule 24 single named constant).
pub const rival_min: i16 = -100; // TUNE
pub const rival_max: i16 = 100; // TUNE

/// One archetype row from rival_archetypes.zon.
pub const RivalArchetype = struct {
    key: []const u8,
    name: []const u8,
    doctrine: []const u8,
    faction_side: []const u8,
    unit_noun: []const u8,
    arcs: []const []const u8,
};

pub const ArchetypeTable = struct { archetypes: []const RivalArchetype };

pub const table: ArchetypeTable = @import("rival_archetypes_zon");

/// Find the archetype with this key, or null.
pub fn find(key: []const u8) ?*const RivalArchetype {
    for (0..table.archetypes.len) |i| {
        if (std.mem.eql(u8, table.archetypes[i].key, key)) return &table.archetypes[i];
    }
    return null;
}

/// A persistent rival entity, introduced by an arc contract.
/// Stored in GameState.rivals keyed by RivalId.
pub const Rival = struct {
    id: types.RivalId = .none,
    /// Key into rival_archetypes.zon.
    archetype_key: []const u8 = "",
    /// Commander name (generated).
    commander_first: []const u8 = "",
    commander_last: []const u8 = "",
    /// Unit name: "<commander_last> <archetype.unit_noun>".
    unit_name: []const u8 = "",
    /// Faction key (employer or enemy side) from the contract that introduced this rival.
    faction_key: []const u8 = "",
    /// Which side of the conflict (derived from the archetype's faction_side).
    side: FactionSide = .employer,
    /// Operational doctrine (derived from the archetype).
    doctrine: RivalDoctrine = .cautious,
    /// The contract this rival was introduced on (soft reference; .none when none).
    contract: types.ContractId = .none,

    /// Signed standing score (clamped to rival_min..rival_max).
    standing: i16 = 0,
    /// How many contracts this rival has been encountered on.
    encounters: u16 = 0,

    /// Short cause label for the most recent standing change (markup-safe).
    last_cause: []const u8 = "",
    /// Day the most recent standing change was recorded.
    last_cause_day: u32 = 0,

    /// True when this rival recurs from a prior contract (carried forward).
    recurring: bool = false,
    /// FK to the world merc company this status overlay belongs to
    /// (docs/p3c-economy-design.md §8.B); .none until P3e.5 attaches rivals to companies.
    merc_company_id: types.MercCompanyId = .none,
};

// ---- Comptime validation ---------------------------------------------------

comptime {
    @setEvalBranchQuota(100_000);
    // Markup-safe check (matches sim/table.zig markupSafe; no upward import).
    const markupSafe = struct {
        fn f(s: []const u8) bool {
            if (!std.unicode.utf8ValidateSlice(s)) return false;
            var it = std.unicode.Utf8View.initUnchecked(s).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp == '{' or cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) return false;
            }
            return true;
        }
    }.f;

    if (table.archetypes.len == 0) @compileError("rival_archetypes.zon: empty table");

    for (table.archetypes, 0..) |a, i| {
        if (!markupSafe(a.key)) @compileError("rival_archetypes.zon: key not markup-safe: " ++ a.key);
        if (!markupSafe(a.name)) @compileError("rival_archetypes.zon: name not markup-safe: " ++ a.name);
        if (!markupSafe(a.unit_noun)) @compileError("rival_archetypes.zon: unit_noun not markup-safe: " ++ a.key);
        if (a.unit_noun.len == 0) @compileError("rival_archetypes.zon: unit_noun is empty: " ++ a.key);
        if (a.arcs.len == 0) @compileError("rival_archetypes.zon: arcs is empty: " ++ a.key);
        // Key uniqueness.
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (std.mem.eql(u8, a.key, table.archetypes[j].key)) @compileError("rival_archetypes.zon: duplicate key: " ++ a.key);
        }
        // doctrine must be a valid RivalDoctrine tag.
        _ = std.meta.stringToEnum(RivalDoctrine, a.doctrine) orelse @compileError("rival_archetypes.zon: unknown doctrine: " ++ a.doctrine);
        // faction_side must be a valid FactionSide tag.
        _ = std.meta.stringToEnum(FactionSide, a.faction_side) orelse @compileError("rival_archetypes.zon: unknown faction_side: " ++ a.faction_side);
        // Every arc key in arcs must exist in arc_mod.table.
        for (a.arcs) |arc_key| {
            var found = false;
            for (arc_mod.table.arcs) |arc| {
                if (std.mem.eql(u8, arc.key, arc_key)) {
                    found = true;
                    break;
                }
            }
            if (!found) @compileError("rival_archetypes.zon: unknown arc key in arcs: " ++ arc_key);
        }
    }

    // Every arc in arc_mod.table must have at least one rival archetype attached.
    for (arc_mod.table.arcs) |arc| {
        var found_arc = false;
        for (table.archetypes) |a| {
            for (a.arcs) |arc_key| {
                if (std.mem.eql(u8, arc_key, arc.key)) {
                    found_arc = true;
                    break;
                }
            }
            if (found_arc) break;
        }
        if (!found_arc) @compileError("rival_archetypes.zon: no archetype for arc: " ++ arc.key);
    }
}

// ---- Tests -----------------------------------------------------------------

test "data: rival_archetypes.zon loads and validates" {
    const testing = std.testing;

    // The comptime block above performs all structural validation.
    // This test confirms runtime reachability: table has archetypes,
    // find works, doctrine and faction_side tags parse.

    try testing.expect(table.archetypes.len > 0);

    // Key uniqueness.
    for (table.archetypes, 0..) |a, i| {
        for (table.archetypes[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.key, b.key));
        }
    }

    // Every archetype resolves via find.
    for (table.archetypes) |a| {
        const found = find(a.key);
        try testing.expect(found != null);
        try testing.expectEqualStrings(a.key, found.?.key);
    }

    // Every arc in arc_mod.table has at least one rival archetype attached.
    for (arc_mod.table.arcs) |arc| {
        var found = false;
        for (table.archetypes) |a| {
            for (a.arcs) |arc_key| {
                if (std.mem.eql(u8, arc_key, arc.key)) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        try testing.expect(found);
    }

    // Every doctrine and faction_side tag is parseable.
    for (table.archetypes) |a| {
        _ = std.meta.stringToEnum(RivalDoctrine, a.doctrine) orelse return error.UnknownDoctrine;
        _ = std.meta.stringToEnum(FactionSide, a.faction_side) orelse return error.UnknownFactionSide;
    }
}

test "Rival defaults and standing constants" {
    const r: Rival = .{};
    try std.testing.expectEqual(types.RivalId.none, r.id);
    try std.testing.expectEqual(@as(i16, 0), r.standing);
    try std.testing.expectEqual(@as(i16, 100), rival_max);
    try std.testing.expectEqual(@as(i16, -100), rival_min);
    try std.testing.expectEqualStrings("hostile", RivalStatus.hostile.label());
    try std.testing.expectEqualStrings("active", RivalStatus.active.label());
    try std.testing.expectEqualStrings("allied", RivalStatus.allied.label());
    try std.testing.expectEqualStrings("cautious", RivalDoctrine.cautious.label());
    try std.testing.expectEqual(types.MercCompanyId.none, r.merc_company_id);
}
