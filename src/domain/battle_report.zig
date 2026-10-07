//! Battle-report record types (ARCH §7). The after-action record kept as
//! fields rather than prose, so screens can count and colour without reading
//! text. `BattleReport` holds everything one engagement produced; `Journal`
//! holds the campaign's complete battle history.
//!
//! Lifetime rule: everything a report holds must live in the campaign arena,
//! which outlives every entity in it. Borrowing from a catalogue row or from
//! arena-held entity memory is fine; borrowing from anything with an explicit
//! `deinit` is not, because the arena will not keep a freed backing array
//! alive. `battle.zig` duplicates the hit list for exactly that reason.
//!
//! Rule 33: nothing here emits markup. `gs.log` text is domain data; the
//! screens colour it in `queries`.
//!
//! MekHQ counterpart: `AtBScenario` + the campaign-report entries it writes
//! (MekHQ keeps the narrative only; the fields here are ours).
//! MekHQ counterpart: the scenario resolution step after a battle
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const unit_mod = @import("unit.zig");
const person_mod = @import("person.zig");
const force_mod = @import("force.zig");
const autoresolve = @import("autoresolve.zig");
const operation = @import("operation.zig");

/// What a hit did to a mounted part.
pub const SlotResult = enum {
    none,
    damaged,
    destroyed,

    pub fn label(self: SlotResult) []const u8 {
        return switch (self) {
            .none => "",
            .damaged => "damaged",
            .destroyed => "destroyed",
        };
    }
};

/// What became of the hull's crew, as fields rather than a sentence, so
/// the screens can count and colour without reading prose.
///
/// A wound and a fate are **independent**: a pilot hit in the fight can
/// still be left on the field and taken, and the AAR says both
/// ("… wounded (light torso); … MIA (held by DC)"). A tagged union here
/// would quietly drop one of them.
pub const CrewOutcome = struct {
    wound: ?Wound = null,
    fate: Fate = .unhurt,

    pub const Wound = struct { severity: u8, location: person_mod.InjuryLocation, permanent: bool };
    pub const Fate = enum {
        unhurt,
        kia,
        /// Left on a lost field and taken: ransom, trade or write-off.
        missing,
    };

    /// Nothing to report for this seat.
    pub fn untouched(self: CrewOutcome) bool {
        return self.wound == null and self.fate == .unhurt;
    }
};

/// One recorded hit: which hull, what it lost, what happened to the crew.
/// `chassis_key`/`chassis_name`/`crew_name` are copies — see the module
/// note on why the record does not look them up again.
pub const HullHit = struct {
    unit: types.UnitId,
    chassis_key: []const u8,
    chassis_name: []const u8,
    armor_before: u8,
    armor_after: u8,
    slot: ?[]const u8 = null,
    slot_part: []const u8 = "",
    slot_result: SlotResult = .none,
    destroyed: bool = false,
    cause: unit_mod.WreckCause = .none,
    pilot: types.PersonId = .none,
    crew_name: []const u8 = "",
    crew: CrewOutcome = .{},
    /// A lost field: the recovery roll and the target it needed.
    recovery: ?struct { roll: i32, target: i32 } = null,
    /// The recovery roll missed: the hull is the enemy's.
    lost: bool = false,

    /// Nothing but paint (the AAR says so rather than listing a bare hull).
    pub fn armorOnly(self: *const HullHit) bool {
        return !self.destroyed and self.slot == null and self.crew.untouched();
    }
};

/// Tons of one munition family burned here, and what the trucks hold now.
pub const AmmoLine = struct {
    key: []const u8,
    burned: u32 = 0,
    left: u32 = 0,
};

/// A wreck the crews could get a chain around. On the abstraction path,
/// rolled once off the enemy's RAT when the fight ends and then left
/// alone. On the pool path, this IS the drawn enemy hull that was
/// destroyed — `hull_instance_id` names the existing instance. The
/// condition fields and chassis metadata live in the record rather than
/// being re-derived at claim time, because the manifest the player is
/// offered and the manifest the command materialises have to be the
/// same wrecks (save/reload included).
pub const SalvageCandidate = struct {
    key: []const u8,
    name: []const u8,
    bv: i64,
    armor_pct: u8,
    quality: types.Quality,
    damaged_slots: u8,
    destroyed_slots: u8,
    missing_components: u8,
    /// `.none` on the abstraction path (a RAT-rolled wreck that owns no
    /// instance); the drawn enemy hull's id on the pool path, so the
    /// claim transfers that very hull rather than minting a new one.
    hull_instance_id: types.HullInstanceId = .none,
};

/// What the claim became: things crated home, or cash under a salvage
/// exchange. `items` is the itemised manifest text.
pub const SalvageManifest = struct {
    claimed_bv: i64 = 0,
    haulable_bv: i64 = 0,
    liaison_cut: i64 = 0,
    exchange_cash: types.CBills = 0,
    items: []const u8 = "",
    /// What was on offer, and whether the commander has yet chosen from
    /// it. Empty when the haul was too small to be worth a choice — then
    /// `items` already describes what was taken.
    candidates: []const SalvageCandidate = &.{},
    /// The haul still to be divided, in BV. Zero once taken.
    unclaimed_bv: i64 = 0,
};

/// One tasked lance's result in a battle engagement (P4e).
/// Names are duped into the campaign arena at resolution time (lifetime
/// rule: no borrow from anything with a `deinit`; see module note).
pub const TaskedLance = struct {
    lance: types.ForceId,
    lance_name: []const u8,
    task: operation.LanceTask,
    succeeded: bool,
    note: []const u8,
};

/// One engagement, whole.
pub const BattleReport = struct {
    id: types.BattleId,
    day: u32,
    contract: types.ContractId,
    company: types.ForceId,

    // Where and what kind of fight.
    kind: []const u8,
    enemy_key: []const u8,
    scenario: []const u8,
    terrain: []const u8,
    weather: []const u8,

    // How it was decided.
    outcome: autoresolve.Outcome,
    held_field: bool = false,
    withdrew: bool = false,
    roe: force_mod.Roe = .standard,
    roe_overridden: bool = false,
    player_power: i64 = 0,
    enemy_power: i64 = 0,
    conditions_mod: i32 = 0,
    close_terrain: bool = false,
    air_grounded: bool = false,
    convoy_hit: bool = false,
    edge_spent_by: []const u8 = "",
    recon_quality: u8 = 0,
    avg_fatigue: u8 = 0,
    avg_morale: u8 = 0,

    // What it cost and what it earned.
    hits_taken: u32 = 0,
    destroyed: u8 = 0,
    wounded: u8 = 0,
    kia: u8 = 0,
    lost_hulls: u32 = 0,
    missing: u32 = 0,
    enemy_destroyed_bv: i64 = 0,
    kills_credited: u32 = 0,
    prisoners: u32 = 0,
    battle_loss_comp: types.CBills = 0,
    score_after: i32 = 0,
    score_delta: i32 = 0,
    /// Applied to every active hand in the company.
    morale_delta: i32 = 0,
    fatigue_add: u8 = 0,
    battle_loss_pct: u8 = 0,
    salvage_pct: u8 = 0,
    command_rights: []const u8 = "",

    hulls: []const HullHit = &.{},
    ammo: []const AmmoLine = &.{},
    silenced_mounts: u32 = 0,
    armor_left: u32 = 0,
    salvage: SalvageManifest = .{},

    /// The operation that produced this engagement (template name), or "".
    operation: []const u8 = "",
    /// The commander's stated intent for the committed combat operation, if any.
    /// Null when no combat operation was committed for this engagement.
    operation_intent: ?operation.Intent = null,
    /// The tempo posture of the committed combat operation, if any (P4f).
    /// Null when no combat operation was committed for this engagement.
    operation_tempo: ?operation.TempoPosture = null,
    /// Comma-separated list of intervention labels applied to the committed
    /// combat operation, if any (P4g). Empty string when none.
    operation_interventions: []const u8 = "",
    /// Per-lance task results for this engagement (P4e).
    /// Arena-owned slice (duped at resolution time); empty when no tasks assigned.
    tasks: []const TaskedLance = &.{},
    /// No combat-effective units: the objective was conceded without a shot.
    conceded: bool = false,
    /// The commander has read it. An unread report holds the turn:
    /// a battle disposes of hulls and people permanently, so it is not
    /// something a week-long advance may resolve past unseen (ARCH §6).
    acknowledged: bool = false,

    /// Hulls that never came home — the count the inbox and the
    /// checklist both read, so neither counts rows itself (rule 20).
    pub fn hullsLost(self: *const BattleReport) u32 {
        var n: u32 = 0;
        for (self.hulls) |h| n += @intFromBool(h.lost);
        return n;
    }

    /// Tons of a family burned here; 0 for one that never fired.
    pub fn burned(self: *const BattleReport, key: []const u8) u32 {
        for (self.ammo) |a| if (std.mem.eql(u8, a.key, key)) return a.burned;
        return 0;
    }
};

/// The campaign's engagements, oldest first. `GameState` holds one complete
/// structured history; acknowledgement controls turn gating, never retention.
pub const Journal = struct {
    kept: std.ArrayListUnmanaged(BattleReport) = .empty,

    /// Reserves one report slot before battle resolution mutates campaign state.
    pub fn prepareRecord(self: *Journal, alloc: std.mem.Allocator) !void {
        try self.kept.ensureUnusedCapacity(alloc, 1);
    }

    /// Keep a resolved engagement for the campaign lifetime.
    pub fn record(self: *Journal, alloc: std.mem.Allocator, report: BattleReport) !void {
        try self.kept.append(alloc, report);
    }

    /// Commits a report after `prepareRecord` reserved its slot.
    pub fn recordAssumeCapacity(self: *Journal, report: BattleReport) void {
        self.kept.appendAssumeCapacity(report);
    }

    /// One retained engagement, or null when no report with that ID exists.
    pub fn find(self: *const Journal, id: types.BattleId) ?*const BattleReport {
        for (self.kept.items) |*r| if (r.id == id) return r;
        return null;
    }

    /// The same record, writable. Only the salvage decision uses this —
    /// the account of a fight is otherwise written once.
    pub fn findMut(self: *Journal, id: types.BattleId) ?*BattleReport {
        for (self.kept.items) |*r| if (r.id == id) return r;
        return null;
    }

    /// The oldest engagement the commander has not read, if any. The one
    /// place "is there something to see" is decided: the turn gate, the
    /// checklist and the client all ask this.
    pub fn unread(self: *const Journal) ?*const BattleReport {
        for (self.kept.items) |*r| if (!r.acknowledged) return r;
        return null;
    }

    /// Mark one read. Returns false when no report with that ID exists.
    pub fn markRead(self: *Journal, id: types.BattleId) bool {
        for (self.kept.items) |*r| if (r.id == id) {
            r.acknowledged = true;
            return true;
        };
        return false;
    }
};

test "BattleReport: default tasks slice is empty; operation_tempo defaults null" {
    const r: BattleReport = .{
        .id = @enumFromInt(1),
        .day = 1,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "k",
        .enemy_key = "DC",
        .scenario = "s",
        .terrain = "t",
        .weather = "w",
        .outcome = .defeat,
    };
    try std.testing.expectEqual(@as(usize, 0), r.tasks.len);
    try std.testing.expectEqual(@as(?operation.TempoPosture, null), r.operation_tempo);
}

test "armorOnly and hullsLost read the record, not the prose" {
    const paint: HullHit = .{ .unit = @enumFromInt(1), .chassis_key = "x", .chassis_name = "X", .armor_before = 90, .armor_after = 70 };
    try std.testing.expect(paint.armorOnly());
    const gone: HullHit = .{ .unit = @enumFromInt(2), .chassis_key = "y", .chassis_name = "Y", .armor_before = 10, .armor_after = 0, .destroyed = true, .lost = true };
    try std.testing.expect(!gone.armorOnly());
    const hulls = [_]HullHit{ paint, gone };
    const r: BattleReport = .{
        .id = @enumFromInt(1),
        .day = 1,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "k",
        .enemy_key = "DC",
        .scenario = "s",
        .terrain = "t",
        .weather = "w",
        .outcome = .defeat,
        .hulls = &hulls,
    };
    try std.testing.expectEqual(@as(u32, 1), r.hullsLost());
    try std.testing.expectEqual(@as(u32, 0), r.burned("ammo_lrm"));
}

test "the journal retains every recorded engagement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const reports: u32 = 80;

    var journal: Journal = .{};
    var i: u32 = 0;
    while (i < reports) : (i += 1) {
        try journal.record(al, .{
            .id = @enumFromInt(i + 1),
            .day = i,
            .contract = @enumFromInt(1),
            .company = @enumFromInt(1),
            .kind = "raid",
            .enemy_key = "DC",
            .scenario = "s",
            .terrain = "t",
            .weather = "w",
            .outcome = .victory,
        });
    }
    try std.testing.expectEqual(@as(usize, reports), journal.kept.items.len);
    try std.testing.expectEqual(@as(u32, 0), journal.kept.items[0].day);
    try std.testing.expectEqual(@as(u32, reports - 1), journal.kept.items[reports - 1].day);
    try std.testing.expect(journal.find(@enumFromInt(1)) != null);
    try std.testing.expect(journal.find(@enumFromInt(reports)) != null);
}
