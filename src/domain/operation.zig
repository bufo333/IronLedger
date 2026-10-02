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
    /// Operationally withdrawn before resolution: force preserved,
    /// escalation pressure applied. (P4h)
    withdrawn,
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

/// Pre-commitment posture chosen per operation: trading operation speed
/// (tempo) against better intelligence, readiness, and escalation pressure
/// (docs/p4-operations-design.md §7 decision 7, P4f). Legal set is derived
/// from the template's `combat` flag; owned by `sim/operations.zig` (rule 20).
pub const TempoPosture = enum {
    /// Act immediately at full speed — the baseline. // TUNE
    advance,
    /// Gather additional intelligence before committing; combat-only. // TUNE
    recon,
    /// Establish a prepared position before action; combat-only. // TUNE
    prepare,
    /// Delay the operation to reduce escalation pressure or wait for
    /// reinforcement; legal on any operation type. // TUNE
    delay,

    /// Short display label for the UI and AAR (markup-safe; rule 33). // TUNE
    pub fn label(self: TempoPosture) []const u8 {
        return switch (self) {
            .advance => "advance",
            .recon => "recon",
            .prepare => "prepare",
            .delay => "delay",
        };
    }
};

/// Tactical task assigned to one lance for a committed combat operation
/// (docs/p4-operations-design.md §7, rule 20). Legal set is derived from
/// the template's `combat` flag and the contract's `CommandRights`;
/// owned by `sim/operations.zig` (rule 20).
pub const LanceTask = enum {
    screen,
    main_effort,
    reserve,
    escort,
    objective_security,
    recovery,
    recon,

    /// Short display label for the UI and AAR (markup-safe; rule 33). // TUNE
    pub fn label(self: LanceTask) []const u8 {
        return switch (self) {
            .screen => "screen",
            .main_effort => "main effort",
            .reserve => "reserve",
            .escort => "escort",
            .objective_security => "objective security",
            .recovery => "recovery",
            .recon => "recon",
        };
    }
};

/// One lance→task assignment on a committed combat operation (P4e).
pub const LanceTasking = struct {
    lance: types.ForceId,
    task: LanceTask,
};

/// A command intervention applied to a committed combat operation (P4g).
/// Spends command capacity to shape the deterministic opening roll.
/// Labels are markup-safe (rule 33).
pub const Intervention = enum {
    emergency_recon,
    reinforce,
    air_cover,
    field_repair,

    /// Short display label for the UI and AAR (markup-safe; rule 33). // TUNE
    pub fn label(self: Intervention) []const u8 {
        return switch (self) {
            .emergency_recon => "emergency recon",
            .reinforce => "reinforce",
            .air_cover => "air cover",
            .field_repair => "field repair",
        };
    }
};

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
    /// Commander's stated mission intent, chosen at commit time (docs/p4-operations-design.md §6).
    /// Default `.secure_objective` keeps the baseline behaviour for ops committed before P4d.
    intent: Intent = .secure_objective,
    /// Pre-commitment tempo posture for this operation (P4f).
    /// Default `.advance` keeps the baseline behaviour for ops committed before P4f.
    tempo: TempoPosture = .advance,
    /// Lance task assignments for this committed combat operation (P4e).
    /// Lives in the campaign arena; freed with the arena. Default empty.
    tasks: std.ArrayListUnmanaged(LanceTasking) = .empty,
    /// Command interventions applied to this committed combat operation (P4g).
    /// Lives in the campaign arena; freed with the arena. Default empty.
    interventions: std.ArrayListUnmanaged(Intervention) = .empty,
};

/// The commander's stated objective for this operation (docs/p4-operations-design.md §6).
/// Legal set is derived from the template's `combat` flag and the contract's
/// `CommandRights`; owned by `sim/operations.zig` (rule 20).
pub const Intent = enum {
    /// Hold back and protect the company; accept reduced score to preserve hulls. // TUNE
    preserve_force,
    /// Accomplish the stated objective — the baseline. // TUNE
    secure_objective,
    /// Destroy or rout the enemy; push hard for maximum score. // TUNE
    break_enemy,
    /// Protect employer or allied assets on the field. // TUNE
    protect_assets,
    /// Gather or protect intelligence; accept reduced score for recon value. // TUNE
    secure_intelligence,
    /// Recover personnel or equipment from a contested area. // TUNE
    recover,

    /// Short display label for the UI and AAR (markup-safe; rule 33). // TUNE
    pub fn label(self: Intent) []const u8 {
        return switch (self) {
            .preserve_force => "preserve force",
            .secure_objective => "secure objective",
            .break_enemy => "break enemy",
            .protect_assets => "protect assets",
            .secure_intelligence => "secure intelligence",
            .recover => "recover",
        };
    }
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

test "OperationState: withdrawn exists and is distinct from all other states" {
    const testing = std.testing;
    const w = OperationState.withdrawn;
    // Distinct from the original eight states.
    try testing.expect(w != .briefing);
    try testing.expect(w != .available);
    try testing.expect(w != .committed);
    try testing.expect(w != .resolved);
    try testing.expect(w != .escalation);
    try testing.expect(w != .finale);
    try testing.expect(w != .aftermath);
    try testing.expect(w != .declined);
    // Default state is available (unchanged).
    const op: Operation = .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    };
    try testing.expectEqual(OperationState.available, op.state);
    try testing.expect(op.state != .withdrawn);
}

test "LanceTask: all seven values have a non-empty markup-safe label; Operation.tasks defaults to empty" {
    const testing = std.testing;
    const all_tasks = [_]LanceTask{ .screen, .main_effort, .reserve, .escort, .objective_security, .recovery, .recon };
    for (all_tasks) |t| {
        const lbl = t.label();
        try testing.expect(lbl.len > 0);
        // Markup-safe: no '{', no C0, no '<', '>', '&'.
        for (lbl) |ch| try testing.expect(ch != '{' and ch >= 0x20 and ch < 0x7f and ch != '<' and ch != '>' and ch != '&');
    }
    // Operation defaults to empty tasks list.
    const op: Operation = .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    };
    try testing.expectEqual(@as(usize, 0), op.tasks.items.len);
}

test "Intervention: all four values have a non-empty markup-safe label; Operation.interventions defaults empty" {
    const testing = std.testing;
    const all_interventions = [_]Intervention{ .emergency_recon, .reinforce, .air_cover, .field_repair };
    for (all_interventions) |iv| {
        const lbl = iv.label();
        try testing.expect(lbl.len > 0);
        for (lbl) |ch| try testing.expect(ch != '{' and ch >= 0x20 and ch < 0x7f);
    }
    // Operation defaults to empty interventions list.
    const op: Operation = .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    };
    try testing.expectEqual(@as(usize, 0), op.interventions.items.len);
}

test "TempoPosture: all four values have a non-empty markup-safe label; Operation.tempo defaults to advance" {
    const testing = std.testing;
    const all_postures = [_]TempoPosture{ .advance, .recon, .prepare, .delay };
    for (all_postures) |p| {
        const lbl = p.label();
        try testing.expect(lbl.len > 0);
        for (lbl) |ch| try testing.expect(ch != '{' and ch >= 0x20 and ch < 0x7f);
    }
    // Operation default tempo is advance.
    const op: Operation = .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    };
    try testing.expectEqual(TempoPosture.advance, op.tempo);
}

test "data: arc branch invariant — every arc has opening >= 2 and at least one template with follow_up >= 2" {
    const testing = std.testing;
    // For each arc in the table, assert:
    // 1. The arc has at least 2 opening templates.
    // 2. At least one operation template belonging to this arc has at least 2 follow_up keys.
    for (arc_mod.table.arcs) |arc| {
        // Opening depth.
        try testing.expect(arc.opening.len >= 2);

        // Branch depth: find at least one template with arc_key == arc.key and follow_up.len >= 2.
        var has_branch = false;
        for (table.templates) |t| {
            if (std.mem.eql(u8, t.arc_key, arc.key) and t.follow_up.len >= 2) {
                has_branch = true;
                break;
            }
        }
        try testing.expect(has_branch);
    }
}

test "Intent: all six values have a non-empty markup-safe label; Operation.intent defaults to secure_objective" {
    const testing = std.testing;
    // All six labels must be non-empty and markup-safe (no '{', no C0).
    const all_intents = [_]Intent{ .preserve_force, .secure_objective, .break_enemy, .protect_assets, .secure_intelligence, .recover };
    for (all_intents) |i| {
        const lbl = i.label();
        try testing.expect(lbl.len > 0);
        for (lbl) |ch| try testing.expect(ch != '{' and ch >= 0x20 and ch < 0x7f);
    }
    // Operation default intent is secure_objective.
    const op: Operation = .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    };
    try testing.expectEqual(Intent.secure_objective, op.intent);
}
