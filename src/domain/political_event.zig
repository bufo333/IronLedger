//! Political event templates: the data rows every political happening is an
//! instance of (docs/p5d-conflict-world-design.md §K "One event
//! architecture"). The `opening` family is the §C scheme templates: each
//! names who may instigate it, what it targets, which side the instigator
//! takes, the strike force's kind and one cause sentence. Data in
//! data/tables/political_events.zon; `sim/politics.zig` opens conflicts
//! from it.
//! No MekHQ counterpart: MekHQ has no political events (docs/mekhq-map.md).

const std = @import("std");
const personage = @import("personage.zig");
const contract = @import("contract.zig");
const opfor = @import("opfor.zig");

/// §K's template families. The table holds only `opening` rows: the other
/// families have no producer, and the build refuses them.
pub const Family = enum { opening, beat, resolution, intrigue };

/// What a scheme targets (§C producer). `sim/politics.zig` owns each rule's
/// test.
pub const TargetRule = enum {
    /// A hiring world of a faction hostile to the instigator's, in reach.
    hostile_world,
    /// A world of a faction that recently beat the instigator's, in reach.
    recent_victor_world,
    /// The seat of a personage the instigator bears a grudge.
    grudge_seat,
    /// The seat of the instigator's rival.
    rival_seat,
    /// A world hostile to an ally's faction, in reach of the ally's seat.
    ally_foe_world,
    /// The instigator's own seat, in revolt against a liege it is not loyal
    /// to.
    own_seat,

    /// Whether `min_industry` applies: only `hostile_world` reads it.
    pub fn industryGated(self: TargetRule) bool {
        return self == .hostile_world;
    }
};

/// Which side of the conflict the instigator takes.
pub const Side = enum { aggressor, defender };

/// The placeholders a cause sentence may hold: the instigator's and the
/// target personage's title and name, the world's name, and the two sides'
/// faction names.
pub const Placeholder = enum { instigator, target, world, aggressor, defender };

pub const Row = struct {
    /// Stable key a save stores in `conflict.template_key`; never renamed.
    key: []const u8,
    /// Short display label, such as "Border grab".
    name: []const u8,
    family: Family,
    /// The instigator holds one of these roles…
    instigator_roles: []const personage.Role,
    /// …and at least one of these motives.
    motives: []const personage.Motive,
    /// The instigator's faction is the catch-all pirate bucket when true,
    /// and any other faction when false.
    pirate: bool,
    target: TargetRule,
    /// The target world's least industry; 0 for every rule but
    /// `hostile_world`.
    min_industry: u8,
    instigator_side: Side,
    /// The kind whose `opfor.zon` row sizes the strike force.
    strike_kind: contract.ContractKind,
    /// Relative draw weight, before the instigator's ambition.
    weight: u32,
    /// One sentence; `{…}` holds a `Placeholder` name.
    cause: []const u8,
};

pub const Table = struct {
    events: []const Row,
};

pub const table: Table = @import("political_events_zon");

/// The row with this key, or null. The row lives in static table memory.
pub fn find(key: []const u8) ?*const Row {
    for (table.events) |*row| {
        if (std.mem.eql(u8, row.key, key)) return row;
    }
    return null;
}

/// One piece of a cause sentence: literal text or a placeholder.
pub const CausePart = union(enum) {
    text: []const u8,
    placeholder: Placeholder,
};

/// Splits a cause sentence into its literal and placeholder parts in order.
pub const CauseParts = struct {
    rest: []const u8,

    pub fn init(cause: []const u8) CauseParts {
        return .{ .rest = cause };
    }

    /// The next part; `error.UnknownPlaceholder` for a `{…}` that names no
    /// `Placeholder` or never closes.
    pub fn next(self: *CauseParts) error{UnknownPlaceholder}!?CausePart {
        if (self.rest.len == 0) return null;
        const open = std.mem.indexOfScalar(u8, self.rest, '{') orelse {
            defer self.rest = "";
            return .{ .text = self.rest };
        };
        if (open > 0) {
            defer self.rest = self.rest[open..];
            return .{ .text = self.rest[0..open] };
        }
        const close = std.mem.indexOfScalar(u8, self.rest, '}') orelse return error.UnknownPlaceholder;
        const name = self.rest[1..close];
        self.rest = self.rest[close + 1 ..];
        return .{ .placeholder = std.meta.stringToEnum(Placeholder, name) orelse return error.UnknownPlaceholder };
    }
};

fn keyShaped(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    return true;
}

fn hasOpforRow(kind: contract.ContractKind) bool {
    for (opfor.table.by_kind) |r| if (std.mem.eql(u8, r.kind, @tagName(kind))) return true;
    return false;
}

// A broken row fails the build with the table's name (rule 58). Markup
// safety of names and cause text is checked where the sim reads the table
// (`sim/politics.zig`).
comptime {
    @setEvalBranchQuota(1_000_000);
    const file = "data/tables/political_events.zon: ";
    if (table.events.len == 0) @compileError(file ++ "the table holds no template");
    var total: u64 = 0;
    for (table.events, 0..) |row, i| {
        const k = row.key;
        if (!keyShaped(k)) @compileError(file ++ "a key is empty or not lowercase [a-z0-9_]: '" ++ k ++ "'");
        for (table.events[0..i]) |earlier| {
            if (std.mem.eql(u8, k, earlier.key)) @compileError(file ++ "duplicate key: " ++ k);
        }
        if (row.family != .opening) @compileError(file ++ "only the opening family is accepted: " ++ k);
        if (row.instigator_roles.len == 0) @compileError(file ++ "no instigator role: " ++ k);
        if (row.motives.len == 0) @compileError(file ++ "no motive: " ++ k);
        if (row.min_industry != 0 and !row.target.industryGated()) @compileError(file ++ "min_industry is set on a rule other than hostile_world: " ++ k);
        if (!hasOpforRow(row.strike_kind)) @compileError(file ++ "strike_kind has no opfor.zon row: " ++ k);
        if (row.weight == 0) @compileError(file ++ "weight must be positive: " ++ k);
        total += row.weight;
        if (row.name.len == 0) @compileError(file ++ "empty name: " ++ k);
        if (row.cause.len == 0) @compileError(file ++ "empty cause: " ++ k);
        var parts = CauseParts.init(row.cause);
        while (parts.next() catch @compileError(file ++ "a cause holds an unknown placeholder: " ++ k)) |_| {}
        const side_wanted: Side = if (row.target == .own_seat) .defender else .aggressor;
        if (row.instigator_side != side_wanted)
            @compileError(file ++ "own_seat rows take the defender side and every other row the aggressor side: " ++ k);
    }
    if (total == 0) @compileError(file ++ "the total weight is zero");
}

test "every stock row is found by its key, and its cause splits into known parts" {
    for (table.events) |*row| {
        try std.testing.expectEqual(row, find(row.key).?);
        var parts = CauseParts.init(row.cause);
        var n: usize = 0;
        while (try parts.next()) |_| n += 1;
        try std.testing.expect(n > 0);
    }
    try std.testing.expect(find("nosuchkey") == null);
}

test "a cause splits into text and placeholders, and refuses an unknown or unclosed one" {
    var parts = CauseParts.init("{instigator} covets {world}.");
    try std.testing.expectEqual(Placeholder.instigator, (try parts.next()).?.placeholder);
    try std.testing.expectEqualStrings(" covets ", (try parts.next()).?.text);
    try std.testing.expectEqual(Placeholder.world, (try parts.next()).?.placeholder);
    try std.testing.expectEqualStrings(".", (try parts.next()).?.text);
    try std.testing.expectEqual(@as(?CausePart, null), try parts.next());
    var unknown = CauseParts.init("a {nobody} b");
    _ = try unknown.next();
    try std.testing.expectError(error.UnknownPlaceholder, unknown.next());
    var unclosed = CauseParts.init("{world");
    try std.testing.expectError(error.UnknownPlaceholder, unclosed.next());
}
