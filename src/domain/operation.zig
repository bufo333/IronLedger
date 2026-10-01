//! Operation templates and runtime instances. An operation is a mission
//! presented to the commander during a contract arc; it may be combat or
//! non-combat and feeds the escalation/resolution model.
//! Data in data/tables/operations.zon.
//! No MekHQ counterpart (P4 operations design §5).

const std = @import("std");
const types = @import("types.zig");
const arc_mod = @import("arc.zig");

/// Lifecycle state of an instantiated operation.
pub const OperationState = enum {
    briefing,
    available,
    committed,
    resolved,
    escalation,
    finale,
    aftermath,
    declined,
};

/// Resolution outcome bands, from worst to best. `none` = not yet resolved.
pub const OutcomeBand = enum {
    none,
    failure,
    setback,
    partial,
    success,
    decisive,
};

/// Static definition of one type of operation mission.
pub const OperationTemplate = struct {
    key: []const u8,
    name: []const u8,
    /// The arc this template belongs to.
    arc_key: []const u8,
    /// true = yields a battle engagement; false = non-combat.
    combat: bool,
    /// Display objective line (markup-safe).
    objective: []const u8,
    /// Typical days to resolution. // TUNE
    expected_days: u16,
    /// Follow-up operation template keys unlocked on success.
    follow_up: []const []const u8,
    /// Decline consequence descriptor (clock/standing/readiness label;
    /// promoted to a typed effect in P4c).
    decline_note: []const u8,
};

pub const Table = struct { templates: []const OperationTemplate };

pub const table: Table = @import("operations_zon");

/// One runtime operation instance held on a Contract.
pub const Operation = struct {
    id: types.OperationId,
    template_key: []const u8,
    state: OperationState,
    outcome: OutcomeBand = .none,
    opened_day: u32,
    resolved_day: ?u32 = null,
    /// Day the operation was committed (state → .committed); null until then.
    committed_day: ?u32 = null,
};

/// The template with this key, or null.
pub fn findTemplate(key: []const u8) ?*const OperationTemplate {
    for (0..table.templates.len) |i| {
        if (std.mem.eql(u8, table.templates[i].key, key)) return &table.templates[i];
    }
    return null;
}

test "data: operations.zon loads and validates" {
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

    // Table must have at least one template.
    try testing.expect(table.templates.len > 0);

    for (0..table.templates.len) |i| {
        const t = &table.templates[i];

        // Key uniqueness.
        for (0..i) |j| try testing.expect(!std.mem.eql(u8, t.key, table.templates[j].key));

        // Strings markup-safe.
        try testing.expect(markupSafe(t.key));
        try testing.expect(markupSafe(t.name));
        try testing.expect(markupSafe(t.objective));
        try testing.expect(markupSafe(t.decline_note));

        // arc_key resolves in arc.table.
        try testing.expect(arc_mod.find(t.arc_key) != null);

        // follow_up keys all resolve in this table.
        for (t.follow_up) |fk| {
            try testing.expect(findTemplate(fk) != null);
            try testing.expect(markupSafe(fk));
        }
    }

    // findTemplate returns a template for known keys and null for unknowns.
    try testing.expect(findTemplate("negotiate_terms") != null);
    try testing.expect(findTemplate("repel_probe") != null);
    try testing.expectEqual(@as(?*const OperationTemplate, null), findTemplate("__no_such_template__"));

    // Every arc's opening keys must resolve to a template in this table.
    // A bad opening key would pass data load but fail silently at runtime.
    for (0..arc_mod.table.arcs.len) |ai| {
        const a = &arc_mod.table.arcs[ai];
        for (a.opening) |okey| {
            try testing.expect(findTemplate(okey) != null);
        }
    }

    // Both templates belong to fracturing_garrison.
    const negotiate = findTemplate("negotiate_terms").?;
    try testing.expectEqualStrings("fracturing_garrison", negotiate.arc_key);
    try testing.expect(!negotiate.combat);

    const repel = findTemplate("repel_probe").?;
    try testing.expectEqualStrings("fracturing_garrison", repel.arc_key);
    try testing.expect(repel.combat);
}
