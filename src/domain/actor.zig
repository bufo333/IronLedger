//! Persistent contract-introduced actors and the narrow relationship model.
//! An actor is introduced by a contract arc and persists across contracts;
//! encountering the same faction/archetype on a later contract surfaces the
//! prior relationship. No MekHQ counterpart (P4 operations design §§3,5).

const std = @import("std");
const types = @import("types.zig");
const arc_mod = @import("arc.zig");

/// The role an actor plays in the contract arc.
pub const ActorKind = enum {
    liaison,
    official,
    militia_leader,
    quartermaster,
    civilian_organizer,
    smuggler,
    enemy_officer,
};

/// Which side of the conflict the archetype typically stands on.
pub const FactionSide = enum {
    employer,
    enemy,
};

/// One archetype row from actor_archetypes.zon.
pub const ActorArchetype = struct {
    key: []const u8,
    name: []const u8,
    kind: []const u8,
    agenda: []const u8,
    faction_side: []const u8,
    arcs: []const []const u8,
};

pub const Table = struct { archetypes: []const ActorArchetype };

pub const table: Table = @import("actor_archetypes_zon");

/// Find the archetype with this key, or null.
pub fn find(key: []const u8) ?*const ActorArchetype {
    for (0..table.archetypes.len) |i| {
        if (std.mem.eql(u8, table.archetypes[i].key, key)) return &table.archetypes[i];
    }
    return null;
}

/// The four relationship dimensions carried by every actor (P4h.3).
/// Each is clamped to −100…100 (rule 24).
pub const RelationshipDim = enum {
    trust,
    debt,
    respect,
    hostility,

    /// Short display label.
    pub fn label(self: RelationshipDim) []const u8 {
        return switch (self) {
            .trust => "trust",
            .debt => "debt",
            .respect => "respect",
            .hostility => "hostility",
        };
    }
};

/// Min/max bounds for relationship dimensions (rule 24 single named constant).
pub const rel_min: i16 = -100; // TUNE
pub const rel_max: i16 = 100; // TUNE

/// A persistent actor entity, introduced by an arc contract.
/// Stored in GameState.actors keyed by ActorId.
pub const Actor = struct {
    id: types.ActorId = .none,
    /// Key into actor_archetypes.zon.
    archetype_key: []const u8 = "",
    /// Display name split (person_gen-style).
    first_name: []const u8 = "",
    last_name: []const u8 = "",
    /// Faction key (employer or enemy side) from the contract that introduced this actor.
    faction_key: []const u8 = "",
    /// Which side of the conflict (derived from the archetype's faction_side).
    side: FactionSide = .employer,
    /// The contract this actor was introduced on (soft reference; .none when none).
    contract: types.ContractId = .none,

    // Relationship dimensions (clamped to rel_min…rel_max).
    trust: i16 = 0,
    debt: i16 = 0,
    respect: i16 = 0,
    hostility: i16 = 0,

    /// Short cause label for the most recent relationship change (markup-safe).
    last_cause: []const u8 = "",
    /// Day the most recent relationship change was recorded.
    last_cause_day: u32 = 0,

    /// True when this actor recurs from a prior contract (carried forward).
    recurring: bool = false,
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

    if (table.archetypes.len == 0) @compileError("actor_archetypes.zon: empty table");

    for (table.archetypes, 0..) |a, i| {
        if (!markupSafe(a.key)) @compileError("actor_archetypes.zon: key not markup-safe: " ++ a.key);
        if (!markupSafe(a.name)) @compileError("actor_archetypes.zon: name not markup-safe: " ++ a.name);
        if (!markupSafe(a.agenda)) @compileError("actor_archetypes.zon: agenda not markup-safe: " ++ a.key);
        if (a.agenda.len == 0) @compileError("actor_archetypes.zon: agenda is empty: " ++ a.key);
        if (a.arcs.len == 0) @compileError("actor_archetypes.zon: arcs is empty: " ++ a.key);
        // Key uniqueness.
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (std.mem.eql(u8, a.key, table.archetypes[j].key)) @compileError("actor_archetypes.zon: duplicate key: " ++ a.key);
        }
        // kind must be a valid ActorKind tag.
        _ = std.meta.stringToEnum(ActorKind, a.kind) orelse @compileError("actor_archetypes.zon: unknown kind: " ++ a.kind);
        // faction_side must be a valid FactionSide tag.
        _ = std.meta.stringToEnum(FactionSide, a.faction_side) orelse @compileError("actor_archetypes.zon: unknown faction_side: " ++ a.faction_side);
        // Every arc key in arcs must exist in arc_mod.table.
        for (a.arcs) |arc_key| {
            var found = false;
            for (arc_mod.table.arcs) |arc| {
                if (std.mem.eql(u8, arc.key, arc_key)) {
                    found = true;
                    break;
                }
            }
            if (!found) @compileError("actor_archetypes.zon: unknown arc key in arcs: " ++ arc_key);
        }
    }

    // Every arc in arc_mod.table must have at least one actor archetype attached.
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
        if (!found_arc) @compileError("actor_archetypes.zon: no archetype for arc: " ++ arc.key);
    }
}

// ---- Tests -----------------------------------------------------------------

test "data: actor_archetypes.zon loads and validates" {
    const testing = std.testing;

    // The comptime block above performs all structural validation.
    // This test confirms runtime reachability: table has archetypes,
    // find works, and relationship dimension labels are complete.

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

    // Every arc in arc_mod.table has at least one actor archetype attached.
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

    // Every kind tag is parseable.
    for (table.archetypes) |a| {
        _ = std.meta.stringToEnum(ActorKind, a.kind) orelse return error.UnknownKind;
        _ = std.meta.stringToEnum(FactionSide, a.faction_side) orelse return error.UnknownFactionSide;
    }
}

test "Actor defaults and RelationshipDim labels" {
    const a: Actor = .{};
    try std.testing.expectEqual(types.ActorId.none, a.id);
    try std.testing.expectEqual(@as(i16, 0), a.trust);
    try std.testing.expectEqual(@as(i16, 0), a.hostility);
    try std.testing.expectEqualStrings("trust", RelationshipDim.trust.label());
    try std.testing.expectEqualStrings("hostility", RelationshipDim.hostility.label());
    try std.testing.expectEqual(@as(i16, 100), rel_max);
    try std.testing.expectEqual(@as(i16, -100), rel_min);
}
