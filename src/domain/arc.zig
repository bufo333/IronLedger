//! Operation arc archetypes: the narrative structures drawn at contract
//! acceptance that shape what missions the company encounters and how the
//! contract resolves. Data in data/tables/arcs.zon.
//! No MekHQ counterpart (P4 operations design §5).

const std = @import("std");
const contract_mod = @import("contract.zig");

/// One narrative beat in an arc's escalation sequence.
pub const Beat = struct {
    key: []const u8,
    name: []const u8,
    /// Accumulated escalation ticks that advance this beat to the next.
    /// 0 = terminal: the arc waits here until a finale is selected (P4h). // TUNE
    escalation_threshold: u16,
};

/// One possible ending for the arc, selected by the escalation clock level.
/// Bands are checked highest min_clock first; one must have min_clock == 0
/// as the unconditional fallback. // TUNE
pub const Finale = struct {
    key: []const u8,
    name: []const u8,
    /// Minimum escalation clock at which this ending may be selected.
    min_clock: u16,
};

/// One arc archetype: a set of contract kinds it applies to, an ordered
/// beat sequence, finale options, and the operations available at beat 0.
pub const Arc = struct {
    key: []const u8,
    name: []const u8,
    /// Contract kinds this arc may be drawn for (ContractKind tag names).
    kinds: []const []const u8,
    beats: []const Beat,
    finales: []const Finale,
    /// Operation template keys available at beat 0 (opening beat).
    opening: []const []const u8,
};

pub const Table = struct { arcs: []const Arc };

pub const table: Table = @import("arcs_zon");

/// The arc with this key, or null.
pub fn find(key: []const u8) ?*const Arc {
    for (0..table.arcs.len) |i| {
        if (std.mem.eql(u8, table.arcs[i].key, key)) return &table.arcs[i];
    }
    return null;
}

test "data: arcs.zon loads and validates" {
    const testing = std.testing;
    // Markup-safe check inlined: matches sim/table.zig markupSafe (no upward import).
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

    // Table must have at least one arc.
    try testing.expect(table.arcs.len > 0);

    for (0..table.arcs.len) |i| {
        const a = &table.arcs[i];

        // Key uniqueness: no two arcs share a key.
        for (0..i) |j| try testing.expect(!std.mem.eql(u8, a.key, table.arcs[j].key));

        // Key and name are markup-safe.
        try testing.expect(markupSafe(a.key));
        try testing.expect(markupSafe(a.name));

        // Every kinds entry resolves to a ContractKind.
        try testing.expect(a.kinds.len > 0);
        for (a.kinds) |k| {
            _ = std.meta.stringToEnum(contract_mod.ContractKind, k) orelse return error.UnknownContractKind;
        }

        // beats non-empty; keys and names markup-safe.
        try testing.expect(a.beats.len > 0);
        for (a.beats) |b| {
            try testing.expect(markupSafe(b.key));
            try testing.expect(markupSafe(b.name));
            try testing.expect(b.key.len > 0);
        }

        // finales non-empty; exactly one with min_clock == 0 (fallback).
        try testing.expect(a.finales.len > 0);
        var fallback_count: u32 = 0;
        for (a.finales) |f| {
            try testing.expect(markupSafe(f.key));
            try testing.expect(markupSafe(f.name));
            try testing.expect(f.key.len > 0);
            if (f.min_clock == 0) fallback_count += 1;
        }
        try testing.expectEqual(@as(u32, 1), fallback_count);

        // opening keys non-empty and markup-safe.
        try testing.expect(a.opening.len > 0);
        for (a.opening) |ok| {
            try testing.expect(ok.len > 0);
            try testing.expect(markupSafe(ok));
        }
    }

    // find() returns the arc for known keys and null for unknowns.
    try testing.expect(find("fracturing_garrison") != null);
    try testing.expectEqual(@as(?*const Arc, null), find("__no_such_arc__"));
}
