//! The after-action record (Stage 12G): what one engagement did, kept as
//! fields instead of prose. `battle.resolveEngagement` fills a
//! `BattleReport`; `render` turns it into the `[AAR]` lines the campaign
//! log has always carried, so the record and the narrative cannot drift
//! (docs/coding-contract.md rule 5 — one rule, one place).
//!
//! A report **outlives the hulls and the people it names**: a wreck left
//! on the field is struck off the books the same day (12D.3) and a KIA
//! pilot leaves the roster. So the names it shows are captured at
//! resolution time rather than looked up later — a rank earned next year
//! must not rewrite last year's AAR.
//!
//! Lifetime rule: everything a report holds must live in the campaign
//! arena, which outlives every entity in it. Borrowing from a catalogue
//! row or from arena-held entity memory is fine; borrowing from anything
//! with an explicit `deinit` is not, because the arena will not keep a
//! freed backing array alive. `battle.zig` duplicates the hit list for
//! exactly that reason.
//!
//! Rule 16: nothing here emits markup. `gs.log` text is domain data; the
//! screens colour it in `queries`.
//!
//! MekHQ counterpart: `AtBScenario` + the campaign-report entries it
//! writes (MekHQ keeps the narrative only; the fields here are ours).

const std = @import("std");
const types = @import("../domain/types.zig");
const unit_mod = @import("../domain/unit.zig");
const person_mod = @import("../domain/person.zig");
const part_mod = @import("../domain/part.zig");
const force_mod = @import("../domain/force.zig");
const autoresolve = @import("autoresolve.zig");
const medical = @import("medical.zig");
const tuning = @import("../domain/tuning.zig").t;

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
/// still be left on the field and taken, and the AAR has always said both
/// ("… wounded (light torso); … MIA (held by DC)"). A tagged union here
/// would quietly drop one of them.
pub const CrewOutcome = struct {
    wound: ?Wound = null,
    fate: Fate = .unhurt,

    pub const Wound = struct { severity: u8, location: person_mod.InjuryLocation, permanent: bool };
    pub const Fate = enum {
        unhurt,
        kia,
        /// Left on a lost field and taken (12D.3): ransom, trade or write-off.
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
    /// A lost field (12D.3): the recovery roll and the target it needed.
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

/// What the claim became: things crated home, or cash under a salvage
/// exchange (12B.2). `items` is the itemised manifest text.
pub const SalvageManifest = struct {
    claimed_bv: i64 = 0,
    haulable_bv: i64 = 0,
    liaison_cut: i64 = 0,
    exchange_cash: types.CBills = 0,
    items: []const u8 = "",
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
    /// Applied to every active hand (12C.1) and, before 12G, never reported.
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

    /// No combat-effective units: the objective was conceded without a shot.
    conceded: bool = false,
    /// The commander has read it (12G.5). An unread report holds the turn:
    /// a battle disposes of hulls and people permanently, so it is not
    /// something a week-long advance may resolve past unseen (ARCH §6).
    acknowledged: bool = false,

    /// Hulls that never came home (12D.3) — the count the inbox and the
    /// checklist both read, so neither counts rows itself (rule 5).
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

/// The engagements still on record, oldest first (12G.4). Owns its own
/// retention, the way `events.EventQueue` owns the inbox: `GameState`
/// holds one and nothing else decides how long a report lives.
///
/// The permanent account of a battle is its `[AAR]` lines in the campaign
/// log, which are never pruned. These are what a screen reads to show a
/// fight as something other than prose, so a few tours' worth is enough.
pub const Journal = struct {
    kept: std.ArrayListUnmanaged(BattleReport) = .empty,

    /// Keep a resolved engagement, dropping the oldest past
    /// `tuning.battle.reports_kept`. The one place retention is decided.
    pub fn record(self: *Journal, alloc: std.mem.Allocator, report: BattleReport) !void {
        try self.kept.append(alloc, report);
        if (self.kept.items.len > tuning.battle.reports_kept) _ = self.kept.orderedRemove(0);
    }

    /// One kept engagement, or null once it has aged out of the window.
    pub fn find(self: *const Journal, id: types.BattleId) ?*const BattleReport {
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

    /// Mark one read. Returns false when it has aged out of the window,
    /// so the command can refuse rather than silently do nothing.
    pub fn markRead(self: *Journal, id: types.BattleId) bool {
        for (self.kept.items) |*r| if (r.id == id) {
            r.acknowledged = true;
            return true;
        };
        return false;
    }
};

/// The `[AAR]` lines for a report, in log order. The one place a battle
/// becomes prose: `battle.zig` logs what this returns and nothing else, so
/// a field added above shows up in the narrative by changing one function.
pub fn render(alloc: std.mem.Allocator, r: *const BattleReport) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (r.conceded) {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR] {s}: no combat-effective units — objective conceded", .{r.kind}));
        return out.toOwnedSlice(alloc);
    }

    try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR] {s} vs {s} — {s} on {s}, {s}: {s} — power {d} vs {d} (recon {d}, fatigue {d}, morale {d}{s}{s}{s}){s}{s}{s}", .{
        r.kind,                 r.enemy_key,   r.scenario,
        r.terrain,              r.weather,     @tagName(r.outcome),
        r.player_power,         r.enemy_power, r.recon_quality,
        r.avg_fatigue,          r.avg_morale,
        if (r.conditions_mod != 0) try std.fmt.allocPrint(alloc, ", conditions {s}{d} to the roll", .{ if (r.conditions_mod > 0) "+" else "", r.conditions_mod }) else "",
        if (r.close_terrain) ", close terrain caps the odds" else "",
        if (r.air_grounded) ", fighters grounded" else "",
        if (r.convoy_hit) " · the convoy was hit — support train damaged" else "",
        if (r.roe == .standard) "" else try std.fmt.allocPrint(alloc, " · ROE {s}{s}{s}", .{ @tagName(r.roe), if (r.roe_overridden) " (integrated command)" else "", if (r.withdrew) " — withdrew from a draw, field given up" else "" }),
        if (r.edge_spent_by.len > 0) try std.fmt.allocPrint(alloc, " · {s} spent Edge to re-roll a lost engagement", .{r.edge_spent_by}) else "",
    }));

    try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   losses: {d} hit / {d} destroyed, {d} wounded, {d} KIA | enemy losses {d} BV ≈ {d} kill{s} credited{s} | salvage {d} BV claimed | comp {d} | score {d}", .{
        r.hits_taken,   r.destroyed, r.wounded,           r.kia,
        r.enemy_destroyed_bv,        r.kills_credited,
        if (r.kills_credited == 1) "" else "s",
        if (r.prisoners > 0) try std.fmt.allocPrint(alloc, ", {d} prisoner{s} taken (inbox)", .{ r.prisoners, if (r.prisoners == 1) "" else "s" }) else "",
        r.salvage.claimed_bv,        r.battle_loss_comp, r.score_after,
    }));

    for (r.hulls) |*h| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   #{d} {s} {s}: {s}armor {d}%→{d}%{s}{s}{s}{s}", .{
            @intFromEnum(h.unit), h.chassis_key, h.chassis_name,
            if (h.destroyed) try std.fmt.allocPrint(alloc, "DESTROYED ({s}) · ", .{h.cause.label()}) else "",
            h.armor_before,       h.armor_after,
            if (h.slot) |sk| try std.fmt.allocPrint(alloc, " · {s} ({s}) {s}{s}", .{ sk, h.slot_part, h.slot_result.label(), try recoveryText(alloc, h) }) else try recoveryText(alloc, h),
            if (h.crew.untouched()) "" else " · ",
            if (h.crew.untouched()) "" else try crewText(alloc, h, r.enemy_key),
            if (h.armorOnly()) " · armor only" else "",
        }));
    }

    if (r.salvage.items.len > 0) {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   salvage: {s}{s}", .{
            r.salvage.items,
            if (r.salvage.liaison_cut > 0) try std.fmt.allocPrint(alloc, " (the employer's liaison claimed {d} BV under {s} command rights)", .{ r.salvage.liaison_cut, r.command_rights }) else "",
        }));
    } else if (r.held_field) {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   salvage: field held, nothing worth hauling ({d} BV destroyed, {d} haulable, {d}% rights)", .{ r.enemy_destroyed_bv, r.salvage.haulable_bv, r.salvage_pct }));
    } else {
        try out.append(alloc, "[AAR]   salvage: none — the field was not held");
    }

    if (r.lost_hulls > 0) {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   field lost: {d} hull{s} left to {s}{s} — battle-loss comp covers {d}% under the terms", .{
            r.lost_hulls, if (r.lost_hulls == 1) "" else "s", r.enemy_key,
            if (r.missing > 0) try std.fmt.allocPrint(alloc, ", {d} pilot{s} missing (inbox)", .{ r.missing, if (r.missing == 1) "" else "s" }) else "",
            r.battle_loss_pct,
        }));
    }

    var spent: std.ArrayListUnmanaged(u8) = .empty;
    var left: std.ArrayListUnmanaged(u8) = .empty;
    for (r.ammo, 0..) |a, i| {
        if (i > 0) {
            try spent.appendSlice(alloc, ", ");
            try left.appendSlice(alloc, ", ");
        }
        try spent.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}t {s}", .{ a.burned, part_mod.munitionLabel(a.key) }));
        try left.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}t {s}", .{ a.left, part_mod.munitionLabel(a.key) }));
    }
    try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   expended: {s} | {d} mounts silenced (dry) | left in the trucks: {s}, {d}t armor", .{
        spent.items, r.silenced_mounts, left.items, r.armor_left,
    }));

    return out.toOwnedSlice(alloc);
}

/// " · field lost · recovery 6 vs 7 — LEFT TO THE ENEMY" (12D.3).
fn recoveryText(alloc: std.mem.Allocator, h: *const HullHit) ![]const u8 {
    const rec = h.recovery orelse return "";
    return try std.fmt.allocPrint(alloc, " · field lost · recovery {d} vs {d} — {s}", .{ rec.roll, rec.target, if (h.lost) "LEFT TO THE ENEMY" else "dragged off" });
}

/// "Lori Kalmar wounded (serious torso)" / "… KIA" / "… MIA (held by DC)",
/// and the wounded-then-taken pair joined with "; ". The one place a
/// `CrewOutcome` becomes words.
fn crewText(alloc: std.mem.Allocator, h: *const HullHit, enemy_key: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (h.crew.wound) |w| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} wounded ({s} {s}{s})", .{ h.crew_name, medical.severityLabel(w.severity), @tagName(w.location), if (w.permanent) ", permanent" else "" }));
    }
    switch (h.crew.fate) {
        .unhurt => {},
        .kia => try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} KIA", .{h.crew_name})),
        .missing => {
            if (out.items.len > 0) try out.appendSlice(alloc, "; ");
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} MIA (held by {s})", .{ h.crew_name, enemy_key }));
        },
    }
    return out.items;
}

test "render turns a report into the AAR lines, with no markup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const hulls = [_]HullHit{
        .{ .unit = @enumFromInt(14), .chassis_key = "SHD-2H", .chassis_name = "Shadow Hawk", .armor_before = 78, .armor_after = 31, .slot = "RT", .slot_part = "actuator", .slot_result = .destroyed },
        .{ .unit = @enumFromInt(17), .chassis_key = "LCT-1V", .chassis_name = "Locust", .armor_before = 44, .armor_after = 0, .destroyed = true, .cause = .ammo, .crew_name = "Cpl Petrov", .crew = .{ .fate = .kia } },
    };
    const ammo = [_]AmmoLine{.{ .key = "ammo_lrm", .burned = 9, .left = 2 }};
    const r: BattleReport = .{
        .id = @enumFromInt(1),        .day = 412,             .contract = @enumFromInt(3),
        .company = @enumFromInt(1),   .kind = "objective raid", .enemy_key = "DC",
        .scenario = "breakthrough",   .terrain = "urban",      .weather = "clear",
        .outcome = .victory,          .held_field = true,      .player_power = 1840,
        .enemy_power = 1610,          .hits_taken = 2,         .destroyed = 1,
        .kia = 1,                     .enemy_destroyed_bv = 900, .kills_credited = 1,
        .hulls = &hulls,              .ammo = &ammo,           .silenced_mounts = 2,
        .armor_left = 7,              .salvage = .{ .claimed_bv = 450, .items = "wreck #31 CN9-A Centurion" },
    };
    const lines = try render(al, &r);

    // Header, losses, one line per hull, salvage, ammo. No "field lost"
    // line: nothing was left behind.
    try std.testing.expectEqual(@as(usize, 6), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "victory — power 1840 vs 1610") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "1 kill credited") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[2], "#14 SHD-2H Shadow Hawk: armor 78%→31% · RT (actuator) destroyed") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[3], "DESTROYED (ammunition explosion)") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[3], "Cpl Petrov KIA") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[4], "salvage: wreck #31") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[5], "9t LRM") != null);

    // Rule 16: the sim never emits markup — the screens colour the line.
    for (lines) |l| try std.testing.expect(std.mem.indexOfScalar(u8, l, '{') == null);
}

test "a conceded objective renders one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: BattleReport = .{
        .id = @enumFromInt(1), .day = 1, .contract = @enumFromInt(1), .company = @enumFromInt(1),
        .kind = "garrison duty", .enemy_key = "DC", .scenario = "", .terrain = "", .weather = "",
        .outcome = .defeat, .conceded = true,
    };
    const lines = try render(arena.allocator(), &r);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.endsWith(u8, lines[0], "no combat-effective units — objective conceded"));
}

test "armorOnly and hullsLost read the record, not the prose" {
    const paint: HullHit = .{ .unit = @enumFromInt(1), .chassis_key = "x", .chassis_name = "X", .armor_before = 90, .armor_after = 70 };
    try std.testing.expect(paint.armorOnly());
    const gone: HullHit = .{ .unit = @enumFromInt(2), .chassis_key = "y", .chassis_name = "Y", .armor_before = 10, .armor_after = 0, .destroyed = true, .lost = true };
    try std.testing.expect(!gone.armorOnly());
    const hulls = [_]HullHit{ paint, gone };
    const r: BattleReport = .{
        .id = @enumFromInt(1), .day = 1, .contract = @enumFromInt(1), .company = @enumFromInt(1),
        .kind = "k", .enemy_key = "DC", .scenario = "s", .terrain = "t", .weather = "w",
        .outcome = .defeat, .hulls = &hulls,
    };
    try std.testing.expectEqual(@as(u32, 1), r.hullsLost());
    try std.testing.expectEqual(@as(u32, 0), r.burned("ammo_lrm"));
}

test "12G.4: the journal is bounded, and the newest survive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const keep = tuning.battle.reports_kept;

    var journal: Journal = .{};
    // Record two windows' worth: the list stops growing, the oldest go.
    var i: u32 = 0;
    while (i < keep * 2) : (i += 1) {
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
    try std.testing.expectEqual(@as(usize, keep), journal.kept.items.len);

    // The window holds the most recent engagements, not the first ones.
    try std.testing.expectEqual(@as(u32, keep * 2 - 1), journal.kept.items[keep - 1].day);
    try std.testing.expectEqual(@as(u32, keep), journal.kept.items[0].day);

    // A report inside the window is findable; one that aged out is not.
    try std.testing.expect(journal.find(journal.kept.items[keep - 1].id) != null);
    try std.testing.expect(journal.find(@enumFromInt(1)) == null);
}
