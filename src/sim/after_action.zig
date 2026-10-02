//! The after-action record renderer (Stage 12G): turns a `BattleReport`
//! into the `[AAR]` lines the campaign log carries. Record types now live
//! in `domain/battle_report.zig`; rendering stays here because it uses
//! sim-level imports (`medical`, `part`).
//!
//! A report **outlives the hulls and the people it names**: a wreck left
//! on the field is struck off the books the same day and a KIA
//! pilot leaves the roster. So the names it shows are captured at
//! resolution time rather than looked up later — a rank earned next year
//! must not rewrite last year's AAR.
//!
//! Rule 33: nothing here emits markup. `gs.log` text is domain data; the
//! screens colour it in `queries`.
//!
//! MekHQ counterpart: the scenario resolution step after a battle writes
//! campaign-report entries (MekHQ keeps the narrative only; this module
//! renders the structured record into `[AAR]` prose). See docs/mekhq-map.md.

const std = @import("std");
const battle_report = @import("../domain/battle_report.zig");
const BattleReport = battle_report.BattleReport;
const HullHit = battle_report.HullHit;
const SlotResult = battle_report.SlotResult;
const part_mod = @import("../domain/part.zig");
const medical = @import("medical.zig");
const operations_m = @import("operations.zig");

/// The `[AAR]` lines for a report, in log order. The one place a battle
/// becomes prose: `battle.zig` logs what this returns and nothing else, so
/// a field added above shows up in the narrative by changing one function.
pub fn render(alloc: std.mem.Allocator, r: *const BattleReport) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (r.conceded) {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR] {s}: no combat-effective units — objective conceded", .{r.kind}));
        return out.toOwnedSlice(alloc);
    }

    try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR] {s} vs {s} — {s} on {s}, {s}: {s} — power {d} vs {d} (recon {d}, fatigue {d}, morale {d}{s}{s}{s}){s}{s}{s}{s}", .{
        r.kind,                                                       r.enemy_key,                                       r.scenario,
        r.terrain,                                                    r.weather,                                         @tagName(r.outcome),
        r.player_power,                                               r.enemy_power,                                     r.recon_quality,
        r.avg_fatigue,                                                r.avg_morale,                                      if (r.conditions_mod != 0) try std.fmt.allocPrint(alloc, ", conditions {s}{d} to the roll", .{ if (r.conditions_mod > 0) "+" else "", r.conditions_mod }) else "",
        if (r.close_terrain) ", close terrain caps the odds" else "", if (r.air_grounded) ", fighters grounded" else "",
        if (r.convoy_hit) " · the convoy was hit — support train damaged" else "",
        if (r.roe == .standard) "" else try std.fmt.allocPrint(alloc, " · ROE {s}{s}{s}", .{ @tagName(r.roe), if (r.roe_overridden) " (integrated command)" else "", if (r.withdrew) " — withdrew from a draw, field given up" else "" }),
        if (r.edge_spent_by.len > 0) try std.fmt.allocPrint(alloc, " · {s} spent Edge to re-roll a lost engagement", .{r.edge_spent_by}) else "",
        if (r.operation.len > 0) try std.fmt.allocPrint(alloc, " · operation: {s}{s}{s}{s}", .{
            r.operation,
            if (r.operation_intent) |intent| try std.fmt.allocPrint(alloc, " (intent: {s} — {s})", .{
                intent.label(),
                if (operations_m.operationSucceeded(intent, operations_m.combatBand(r.outcome))) "mission success" else "mission failed",
            }) else "",
            if (r.operation_tempo) |tempo| try std.fmt.allocPrint(alloc, " [tempo: {s}]", .{tempo.label()}) else "",
            if (r.operation_interventions.len > 0) try std.fmt.allocPrint(alloc, " [interventions: {s}]", .{r.operation_interventions}) else "",
        }) else "",
    }));

    try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   losses: {d} hit / {d} destroyed, {d} wounded, {d} KIA | enemy losses {d} BV ≈ {d} kill{s} credited{s} | salvage {d} BV claimed | comp {d} | score {d}", .{
        r.hits_taken,         r.destroyed,        r.wounded,                              r.kia,
        r.enemy_destroyed_bv, r.kills_credited,   if (r.kills_credited == 1) "" else "s", if (r.prisoners > 0) try std.fmt.allocPrint(alloc, ", {d} prisoner{s} taken (inbox)", .{ r.prisoners, if (r.prisoners == 1) "" else "s" }) else "",
        r.salvage.claimed_bv, r.battle_loss_comp, r.score_after,
    }));

    for (r.hulls) |*h| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   #{d} {s} {s}: {s}armor {d}%→{d}%{s}{s}{s}{s}", .{
            @intFromEnum(h.unit),                                                h.chassis_key, h.chassis_name,
            if (h.destroyed) try std.fmt.allocPrint(alloc, "DESTROYED ({s}) · ", .{h.cause.label()}) else "",
            h.armor_before,                                                      h.armor_after,
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
            r.lost_hulls,                                                                                                                                if (r.lost_hulls == 1) "" else "s", r.enemy_key,
            if (r.missing > 0) try std.fmt.allocPrint(alloc, ", {d} pilot{s} missing (inbox)", .{ r.missing, if (r.missing == 1) "" else "s" }) else "", r.battle_loss_pct,
        }));
    }

    // Per-lance task results (P4e). One line per assigned lance.
    for (r.tasks) |lt| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "[AAR]   task {s}: {s} — {s}", .{
            lt.task.label(),
            lt.lance_name,
            lt.note,
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

/// " · field lost · recovery 6 vs 7 — LEFT TO THE ENEMY".
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
    const ammo = [_]battle_report.AmmoLine{.{ .key = "ammo_lrm", .burned = 9, .left = 2 }};
    const r: BattleReport = .{
        .id = @enumFromInt(1),
        .day = 412,
        .contract = @enumFromInt(3),
        .company = @enumFromInt(1),
        .kind = "objective raid",
        .enemy_key = "DC",
        .scenario = "breakthrough",
        .terrain = "urban",
        .weather = "clear",
        .outcome = .victory,
        .held_field = true,
        .player_power = 1840,
        .enemy_power = 1610,
        .hits_taken = 2,
        .destroyed = 1,
        .kia = 1,
        .enemy_destroyed_bv = 900,
        .kills_credited = 1,
        .hulls = &hulls,
        .ammo = &ammo,
        .silenced_mounts = 2,
        .armor_left = 7,
        .salvage = .{ .claimed_bv = 450, .items = "wreck #31 CN9-A Centurion" },
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

    // Rule 33: the sim never emits markup — the screens colour the line.
    for (lines) |l| try std.testing.expect(std.mem.indexOfScalar(u8, l, '{') == null);
}

test "a conceded objective renders one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: BattleReport = .{
        .id = @enumFromInt(1),
        .day = 1,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .defeat,
        .conceded = true,
    };
    const lines = try render(arena.allocator(), &r);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.endsWith(u8, lines[0], "no combat-effective units — objective conceded"));
}

test "render: operation name appears in the AAR header when set" {
    // F3: consumer test — render must include the operation name in the
    // header line when BattleReport.operation is non-empty (rule 20).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ammo = [_]battle_report.AmmoLine{.{ .key = "ammo_lrm", .burned = 0, .left = 0 }};
    const r: BattleReport = .{
        .id = @enumFromInt(2),
        .day = 10,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "open",
        .weather = "clear",
        .outcome = .defeat,
        .operation = "Repel Probe",
        .ammo = &ammo,
    };
    const lines = try render(arena.allocator(), &r);
    // Header line (lines[0]) must contain the operation name.
    try std.testing.expect(lines.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "Repel Probe") != null);

    // When operation_tempo is set, the label appears in the header.
    const r_tempo: BattleReport = .{
        .id = @enumFromInt(6),
        .day = 15,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "open",
        .weather = "clear",
        .outcome = .victory,
        .operation = "Repel Probe",
        .operation_tempo = .recon,
        .ammo = &ammo,
    };
    const lines_tempo = try render(arena.allocator(), &r_tempo);
    try std.testing.expect(lines_tempo.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, lines_tempo[0], "[tempo: recon]") != null);
}

test "render: intent and success verdict appear in the AAR header when operation_intent is set" {
    // Rule 20 consumer test: render calls operationSucceeded and shows the verdict.
    // docs/p4-operations-design.md §6.
    const operation = @import("../domain/operation.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ammo = [_]battle_report.AmmoLine{.{ .key = "ammo_lrm", .burned = 0, .left = 0 }};
    // secure_objective + victory => "mission success"
    const r_ok: BattleReport = .{
        .id = @enumFromInt(3),
        .day = 11,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "open",
        .weather = "clear",
        .outcome = .victory,
        .operation = "Repel Probe",
        .operation_intent = .secure_objective,
        .ammo = &ammo,
    };
    const lines_ok = try render(arena.allocator(), &r_ok);
    try std.testing.expect(lines_ok.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, lines_ok[0], "intent: secure objective") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines_ok[0], "mission success") != null);

    // preserve_force + rout => "mission failed"
    const r_fail: BattleReport = .{
        .id = @enumFromInt(4),
        .day = 12,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "open",
        .weather = "clear",
        .outcome = .rout,
        .operation = "Repel Probe",
        .operation_intent = .preserve_force,
        .ammo = &ammo,
    };
    _ = operation;
    const lines_fail = try render(arena.allocator(), &r_fail);
    try std.testing.expect(lines_fail.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, lines_fail[0], "intent: preserve force") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines_fail[0], "mission failed") != null);
}

test "render: per-lance task lines appear in AAR for each assigned task (P4e)" {
    // Consumer test: render must produce one [AAR] task line per entry in report.tasks.
    const operation = @import("../domain/operation.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ammo = [_]battle_report.AmmoLine{.{ .key = "ammo_lrm", .burned = 0, .left = 0 }};
    const tasks = [_]battle_report.TaskedLance{
        .{ .lance = @enumFromInt(1), .lance_name = "Alpha Lance", .task = .main_effort, .succeeded = true, .note = "led the advance" },
        .{ .lance = @enumFromInt(2), .lance_name = "Beta Lance", .task = .reserve, .succeeded = false, .note = "line broke before reserve could act" },
    };
    const r: BattleReport = .{
        .id = @enumFromInt(5),
        .day = 20,
        .contract = @enumFromInt(1),
        .company = @enumFromInt(1),
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "open",
        .weather = "clear",
        .outcome = .victory,
        .tasks = &tasks,
        .ammo = &ammo,
    };
    _ = operation;
    const lines = try render(arena.allocator(), &r);
    // There must be two task lines.
    var task_lines: u32 = 0;
    for (lines) |line| if (std.mem.indexOf(u8, line, "[AAR]   task ") != null) {
        task_lines += 1;
    };
    try std.testing.expectEqual(@as(u32, 2), task_lines);
    // The first task line must mention the task label and lance name.
    var found_main = false;
    var found_note = false;
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, "main effort") != null and std.mem.indexOf(u8, line, "Alpha Lance") != null) found_main = true;
        if (std.mem.indexOf(u8, line, "led the advance") != null) found_note = true;
    }
    try std.testing.expect(found_main);
    try std.testing.expect(found_note);
}
