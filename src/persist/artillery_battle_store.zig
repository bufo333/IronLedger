//! Normalized artillery combat reports inside the store facade's transaction.
//! No MekHQ counterpart: current-format SQLite representation (docs/mekhq-map.md).

const std = @import("std");
const sqlite = @import("sqlite.zig");
const types = @import("../domain/types.zig");
const report = @import("../domain/battle_report.zig");
const combat = @import("../domain/artillery_combat.zig");
const operations = @import("../domain/artillery_operations.zig");
const unit = @import("../domain/unit.zig");
const person = @import("../domain/person.zig");
const GameState = @import("../sim/state.zig").GameState;

fn enumText(comptime E: type, st: sqlite.Stmt, column: c_int, alloc: std.mem.Allocator) !E {
    const bytes = try st.text(column, alloc);
    defer alloc.free(bytes);
    return std.meta.stringToEnum(E, bytes) orelse return error.CorruptSave;
}

fn optionalEnum(comptime E: type, st: sqlite.Stmt, column: c_int, alloc: std.mem.Allocator) !?E {
    return if (st.isNull(column)) null else try enumText(E, st, column, alloc);
}

fn optionalInt(comptime T: type, st: sqlite.Stmt, column: c_int) !?T {
    return if (st.isNull(column)) null else try st.intAs(T, column);
}

fn boolean(st: sqlite.Stmt, column: c_int) !bool {
    const value = try st.intAs(u8, column);
    if (value > 1) return error.CorruptSave;
    return value == 1;
}

fn identity(comptime T: type, st: sqlite.Stmt, column: c_int) !T {
    const raw = try st.intAs(u32, column);
    if (raw == 0) return error.CorruptSave;
    return @enumFromInt(raw);
}

fn roll(st: sqlite.Stmt, a: c_int, b: c_int) !?report.RecordedRoll {
    const value = try optionalInt(i32, st, a);
    const target = try optionalInt(i32, st, b);
    if ((value != null) != (target != null)) return error.CorruptSave;
    return if (value) |v| .{ .roll = v, .target = target.? } else null;
}

/// Save canonical parent/seat/slot rows. Caller owns transaction and child clearing.
pub fn save(db: sqlite.Db, cid: i64, ord: i64, r: *const report.ArtilleryResult) !void {
    const st = try db.prepare("INSERT INTO artillery_battle VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37)");
    defer st.finalize();
    try st.bindAll(.{
        cid,                      ord,               r.formation,                                     r.hull,                                            r.catalogue_key,      r.catalogue_name,
        r.physical_participation, r.readiness,       r.no_fire,                                       r.fire,                                            r.damage,             r.target,
        r.accuracy_roll,          r.carrier_power,   r.enemy_power_before,                            r.suppressed_power,                                r.enemy_power_after,  r.exposure_percent,
        r.exposure_roll,          r.severity,        r.struck_slot,                                   r.struck_seat,                                     r.armor_before,       r.armor_after,
        r.newly_wrecked,          r.cause,           if (r.recovery) |v| @as(?i32, v.roll) else null, if (r.recovery) |v| @as(?i32, v.target) else null, r.compensation_basis, r.rounds_before[0],
        r.rounds_before[1],       r.rounds_after[0], r.rounds_after[1],                               r.fired_rounds[0],                                 r.fired_rounds[1],    r.lost_rounds[0],
        r.lost_rounds[1],
    });
    try st.run();
    const seat = try db.prepare("INSERT INTO artillery_battle_seat VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)");
    defer seat.finalize();
    for (r.seats) |s| {
        try seat.bindAll(.{ cid, ord, s.seat, if (s.person == .none) @as(?types.PersonId, null) else s.person, s.name, s.present, if (s.outcome.wound) |w| @as(?u8, w.severity) else null, if (s.outcome.wound) |w| @as(?person.InjuryLocation, w.location) else null, if (s.outcome.wound) |w| @as(?bool, w.permanent) else null, s.outcome.fate, if (s.escape) |v| @as(?i32, v.roll) else null, if (s.escape) |v| @as(?i32, v.target) else null, s.xp_participation });
        try seat.run();
    }
    const slot = try db.prepare("INSERT INTO artillery_battle_slot VALUES (?1,?2,?3,?4,?5,?6,?7)");
    defer slot.finalize();
    for (operations.descriptors, r.slots_before, r.slots_after) |d, before, after| {
        try slot.bindAll(.{ cid, ord, d.slot, before.condition, after.condition, if (d.family != null) @as(?u16, before.rounds) else null, if (d.family != null) @as(?u16, after.rounds) else null });
        try slot.run();
    }
}

const parent_columns = "formation,hull,catalogue_key,catalogue_name,physical,readiness,no_fire,fire,damage,target,accuracy,carrier_power,enemy_before,suppressed,enemy_after,exposure_pct,exposure_roll,severity,struck_slot,struck_seat,armor_before,armor_after,newly_wrecked,cause,recovery_roll,recovery_target,compensation,lt_before,mg_before,lt_after,mg_after,lt_fired,mg_fired,lt_lost,mg_lost";
const parent_classes =
    "typeof(cid)='integer' AND typeof(report_ord)='integer' AND typeof(formation)='integer' AND typeof(hull)='integer' AND typeof(catalogue_key)='text' AND typeof(catalogue_name)='text' AND typeof(physical)='integer' AND typeof(readiness) IN ('text','null') AND typeof(no_fire)='text' AND typeof(fire)='text' AND typeof(damage)='text' AND typeof(target) IN ('integer','null') AND typeof(accuracy) IN ('integer','null') AND typeof(carrier_power) IN ('integer','null') AND typeof(enemy_before) IN ('integer','null') AND typeof(suppressed)='integer' AND typeof(enemy_after) IN ('integer','null') AND typeof(exposure_pct) IN ('integer','null') AND typeof(exposure_roll) IN ('integer','null') AND typeof(severity) IN ('integer','null') AND typeof(struck_slot) IN ('text','null') AND typeof(struck_seat) IN ('text','null') AND typeof(armor_before)='integer' AND typeof(armor_after)='integer' AND typeof(newly_wrecked)='integer' AND typeof(cause)='text' AND typeof(recovery_roll) IN ('integer','null') AND typeof(recovery_target) IN ('integer','null') AND typeof(compensation)='integer' AND typeof(lt_before)='integer' AND typeof(mg_before)='integer' AND typeof(lt_after)='integer' AND typeof(mg_after)='integer' AND typeof(lt_fired)='integer' AND typeof(mg_fired)='integer' AND typeof(lt_lost)='integer' AND typeof(mg_lost)='integer'";

/// Decode a required present result, or verify complete absence including children.
/// All original SQLite storage classes and complete enum bytes are checked first.
pub fn load(db: sqlite.Db, gs: *GameState, cid: i64, ord: i64, present: bool) !?report.ArtilleryResult {
    const st = try db.prepare("SELECT " ++ parent_columns ++ "," ++ parent_classes ++ " FROM artillery_battle WHERE cid=?1 AND report_ord=?2");
    defer st.finalize();
    try st.bindAll(.{ cid, ord });
    const exists = try st.next();
    if (exists != present) return error.CorruptSave;
    if (!exists) {
        inline for (.{ "artillery_battle_seat", "artillery_battle_slot" }) |table| {
            const child = try db.prepare("SELECT COUNT(*) FROM " ++ table ++ " WHERE cid=?1 AND report_ord=?2");
            defer child.finalize();
            try child.bindAll(.{ cid, ord });
            if (!try child.next() or child.int(0) != 0) return error.CorruptSave;
        }
        return null;
    }
    if (st.int(35) != 1) return error.CorruptSave;
    var r: report.ArtilleryResult = .{
        .formation = try identity(types.ArtilleryFormationId, st, 0),
        .hull = try identity(types.HullInstanceId, st, 1),
        .catalogue_key = try st.text(2, gs.allocator()),
        .catalogue_name = try st.text(3, gs.allocator()),
        .physical_participation = try boolean(st, 4),
        .readiness = try optionalEnum(combat.ReadinessBlock, st, 5, gs.scratch()),
        .no_fire = try enumText(combat.NoFire, st, 6, gs.scratch()),
        .fire = try enumText(combat.FireOutcome, st, 7, gs.scratch()),
        .damage = try enumText(combat.DamageOutcome, st, 8, gs.scratch()),
        .target = try optionalInt(u8, st, 9),
        .accuracy_roll = try optionalInt(u8, st, 10),
        .carrier_power = try optionalInt(i64, st, 11),
        .enemy_power_before = try optionalInt(i64, st, 12),
        .suppressed_power = st.int(13),
        .enemy_power_after = try optionalInt(i64, st, 14),
        .exposure_percent = try optionalInt(u8, st, 15),
        .exposure_roll = try optionalInt(u8, st, 16),
        .severity = try optionalInt(u8, st, 17),
        .struck_slot = try optionalEnum(operations.Slot, st, 18, gs.scratch()),
        .struck_seat = try optionalEnum(operations.Seat, st, 19, gs.scratch()),
        .armor_before = try st.intAs(u8, 20),
        .armor_after = try st.intAs(u8, 21),
        .newly_wrecked = try boolean(st, 22),
        .cause = try enumText(unit.WreckCause, st, 23, gs.scratch()),
        .recovery = try roll(st, 24, 25),
        .compensation_basis = st.int(26),
        .rounds_before = .{ try st.intAs(u16, 27), try st.intAs(u16, 28) },
        .rounds_after = .{ try st.intAs(u16, 29), try st.intAs(u16, 30) },
        .fired_rounds = .{ try st.intAs(u16, 31), try st.intAs(u16, 32) },
        .lost_rounds = .{ try st.intAs(u16, 33), try st.intAs(u16, 34) },
        .slots_before = undefined,
        .slots_after = undefined,
    };
    if (try st.next()) return error.CorruptSave;
    try loadSeats(db, gs, cid, ord, &r);
    try loadSlots(db, gs, cid, ord, &r);
    return r;
}

fn loadSeats(db: sqlite.Db, gs: *GameState, cid: i64, ord: i64, r: *report.ArtilleryResult) !void {
    const st = try db.prepare("SELECT seat,person,name,present,wound_severity,wound_location,wound_permanent,fate,escape_roll,escape_target,xp,typeof(cid)='integer' AND typeof(report_ord)='integer' AND typeof(seat)='text' AND typeof(person) IN ('integer','null') AND typeof(name)='text' AND typeof(present)='integer' AND typeof(wound_severity) IN ('integer','null') AND typeof(wound_location) IN ('text','null') AND typeof(wound_permanent) IN ('integer','null') AND typeof(fate)='text' AND typeof(escape_roll) IN ('integer','null') AND typeof(escape_target) IN ('integer','null') AND typeof(xp)='integer' FROM artillery_battle_seat WHERE cid=?1 AND report_ord=?2");
    defer st.finalize();
    try st.bindAll(.{ cid, ord });
    var seen: u8 = 0;
    while (try st.next()) {
        if (st.int(11) != 1) return error.CorruptSave;
        const seat = try enumText(operations.Seat, st, 0, gs.scratch());
        const index = @intFromEnum(seat);
        const mask = @as(u8, 1) << @as(u3, @intCast(index));
        if (seen & mask != 0) return error.CorruptSave;
        seen |= mask;
        const severity = try optionalInt(u8, st, 4);
        const location = try optionalEnum(person.InjuryLocation, st, 5, gs.scratch());
        const permanent = if (st.isNull(6)) null else @as(?bool, try boolean(st, 6));
        if ((severity != null) != (location != null) or (severity != null) != (permanent != null)) return error.CorruptSave;
        r.seats[index] = .{
            .seat = seat,
            .person = if (st.isNull(1)) .none else try identity(types.PersonId, st, 1),
            .name = try st.text(2, gs.allocator()),
            .present = try boolean(st, 3),
            .outcome = .{ .fate = try enumText(report.CrewOutcome.Fate, st, 7, gs.scratch()), .wound = if (severity) |s| .{ .severity = s, .location = location.?, .permanent = permanent.? } else null },
            .escape = try roll(st, 8, 9),
            .xp_participation = try boolean(st, 10),
        };
    }
    if (seen != (@as(u8, 1) << operations.seats.len) - 1) return error.CorruptSave;
}

fn loadSlots(db: sqlite.Db, gs: *GameState, cid: i64, ord: i64, r: *report.ArtilleryResult) !void {
    const st = try db.prepare("SELECT slot,before_condition,after_condition,before_rounds,after_rounds,typeof(cid)='integer' AND typeof(report_ord)='integer' AND typeof(slot)='text' AND typeof(before_condition)='text' AND typeof(after_condition)='text' AND typeof(before_rounds) IN ('integer','null') AND typeof(after_rounds) IN ('integer','null') FROM artillery_battle_slot WHERE cid=?1 AND report_ord=?2");
    defer st.finalize();
    try st.bindAll(.{ cid, ord });
    var seen: u16 = 0;
    while (try st.next()) {
        if (st.int(5) != 1) return error.CorruptSave;
        const slot = try enumText(operations.Slot, st, 0, gs.scratch());
        const index = @intFromEnum(slot);
        const mask = @as(u16, 1) << @as(u4, @intCast(index));
        if (seen & mask != 0) return error.CorruptSave;
        seen |= mask;
        const before = try optionalInt(u16, st, 3);
        const after = try optionalInt(u16, st, 4);
        if ((before != null) != (operations.descriptor(slot).family != null) or (before != null) != (after != null)) return error.CorruptSave;
        r.slots_before[index] = .{ .condition = try enumText(unit.PartCondition, st, 1, gs.scratch()), .rounds = before orelse 0 };
        r.slots_after[index] = .{ .condition = try enumText(unit.PartCondition, st, 2, gs.scratch()), .rounds = after orelse 0 };
    }
    if (seen != (@as(u16, 1) << operations.descriptors.len) - 1) return error.CorruptSave;
    try operations.validateSlots(&r.slots_before);
    try operations.validateSlots(&r.slots_after);
}

/// Reject child/parent rows with no matching report, including absent-result rows.
pub fn validateParents(db: sqlite.Db, cid: i64) !void {
    inline for (.{ "artillery_battle", "artillery_battle_seat", "artillery_battle_slot" }) |table| {
        const st = try db.prepare("SELECT COUNT(*) FROM " ++ table ++ " WHERE cid=?1 AND report_ord NOT IN (SELECT ord FROM battle_report WHERE cid=?1)");
        defer st.finalize();
        try st.bindAll(.{cid});
        if (!try st.next() or st.int(0) != 0) return error.CorruptSave;
    }
}

fn campaignForTest(gs: *GameState) !types.ContractId {
    const capabilities = @import("../sim/artillery_operations.zig");
    const battle = @import("../sim/battle.zig");
    const part = @import("../domain/part.zig");
    const id = try capabilities.fixtureForTest(gs, true);
    const co = try @import("../sim/starter_company.zig").generateInto(gs, "Line company");
    const f = gs.artillery_formations.getPtr(id).?;
    f.placement = .{ .company = co };
    for (f.crew) |person_id| gs.person(person_id).?.assigned_force = co;
    gs.person(f.tech).?.assigned_force = co;
    f.last_maintenance_day = 0;
    for (operations.descriptors, &f.slots) |d, *slot| if (d.family != null) {
        slot.rounds = d.capacity_rounds;
    };
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .recon_raid, .employer_key = "LC", .enemy_key = "PER", .planet_key = gs.seatPlanetKey().?, .assigned_company = co, .status = .active, .terms = .{ .length_months = 6, .base_pay_month = 400_000, .battle_loss_pct = 30, .salvage_pct = 30 }, .monthly_net = 300_000 });
    try gs.addStock(.{ .company = co }, "armor", 60);
    for (part.munition_keys) |key| try gs.addStock(.{ .company = co }, key, 40);
    try battle.resolveEngagement(gs, gs.contracts.getPtr(cid).?);
    return cid;
}

test "normalized combat save overwrite load and continued battle preserve complete state" {
    const Store = @import("store.zig").Store;
    const digest = @import("../sim/digest.zig");
    const battle = @import("../sim/battle.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const cid = try campaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expect(gs.battle_reports.kept.items[0].artillery.?.fire != .not_fired);
    try battle.resolveEngagement(&gs, gs.contracts.getPtr(cid).?);
    try battle.resolveEngagement(&loaded, loaded.contracts.getPtr(cid).?);
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try store.save(&gs);
    try store.deleteCampaign(gs.campaign_id);
    inline for (.{ "artillery_battle", "artillery_battle_seat", "artillery_battle_slot" }) |table| {
        const st = try store.db.prepare("SELECT COUNT(*) FROM " ++ table);
        defer st.finalize();
        try std.testing.expect(try st.next());
        try std.testing.expectEqual(@as(i64, 0), st.int(0));
    }
}

test "combat file close reopen preserves captured reports and continued engagement" {
    const Store = @import("store.zig").Store;
    const digest = @import("../sim/digest.zig");
    const battle = @import("../sim/battle.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/combat.db", .{temporary.sub_path}, 0);
    defer std.testing.allocator.free(path);
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const cid = try campaignForTest(&gs);
    {
        const store = try Store.open(path);
        defer store.close();
        try store.save(&gs);
    }
    const reopened = try Store.open(path);
    defer reopened.close();
    var loaded = try reopened.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try battle.resolveEngagement(&gs, gs.contracts.getPtr(cid).?);
    try battle.resolveEngagement(&loaded, loaded.contracts.getPtr(cid).?);
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
}

test "current combat rows reject missing children orphan identity classes and invented outcomes" {
    const Store = @import("store.zig").Store;
    const digest = @import("../sim/digest.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try campaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    for ([_][*:0]const u8{
        "DELETE FROM artillery_battle",
        "UPDATE battle_report SET artillery_present=0",
        "UPDATE battle_report SET artillery_present=2",
        "DELETE FROM artillery_battle_seat WHERE seat='driver'",
        "DELETE FROM artillery_battle_slot WHERE slot='hitch'",
        "UPDATE artillery_battle SET report_ord=999",
        "UPDATE artillery_battle_seat SET report_ord=999",
        "UPDATE artillery_battle_slot SET report_ord=999",
        "UPDATE artillery_battle SET formation=0",
        "UPDATE artillery_battle SET formation=4294967296",
        "UPDATE artillery_battle SET formation=-1",
        "UPDATE artillery_battle SET hull=999999",
        "UPDATE artillery_battle SET fire='hit'||char(0)",
        "UPDATE artillery_battle SET readiness='crew'||char(0)",
        "UPDATE artillery_battle SET fire=X'686974'",
        "UPDATE artillery_battle SET accuracy=NULL",
        "UPDATE artillery_battle SET accuracy=2.5",
        "UPDATE artillery_battle SET severity=13",
        "UPDATE artillery_battle SET lt_after=lt_after+1",
        "UPDATE artillery_battle SET lt_fired=2",
        "UPDATE artillery_battle SET suppressed=suppressed+1",
        "UPDATE battle_report SET conceded=1",
        "UPDATE artillery_battle SET fire='not_fired',no_fire='enemy_forfeit',target=NULL,accuracy=NULL,carrier_power=NULL,lt_fired=0",
        "UPDATE artillery_battle SET armor_after=armor_after-1",
        "UPDATE artillery_battle SET recovery_roll=2,recovery_target=NULL",
        "UPDATE artillery_battle SET compensation=compensation+1",
        "UPDATE artillery_battle_seat SET person=999999 WHERE seat='driver'",
        "UPDATE artillery_battle_seat SET seat='driver'||char(0) WHERE seat='driver'",
        "UPDATE artillery_battle_seat SET present=2",
        "UPDATE artillery_battle_seat SET wound_severity=1,wound_location=NULL",
        "UPDATE artillery_battle_seat SET xp=-1",
        "UPDATE artillery_battle_slot SET slot='hitch'||char(0) WHERE slot='hitch'",
        "UPDATE artillery_battle_slot SET before_rounds=6 WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_battle_slot SET before_rounds=NULL WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_battle_slot SET after_condition='missing',after_rounds=1 WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_battle_slot SET before_rounds=0 WHERE slot='main_gun'",
        "UPDATE meta SET value=1 WHERE key='next_artillery_formation_id'",
        "UPDATE meta SET value=1 WHERE key='next_hull_instance_id'",
        "UPDATE meta SET value=1 WHERE key='next_person_id'",
        "UPDATE meta SET value=1 WHERE key='next_battle_id'",
        "UPDATE hull_combat_record SET kills=1 WHERE hull_instance_id=(SELECT hull FROM artillery_battle)",
        "UPDATE hull_combat_record SET slots_damaged=slots_damaged+1 WHERE hull_instance_id=(SELECT hull FROM artillery_battle)",
        "UPDATE hull_combat_record SET battle_id=999999 WHERE hull_instance_id=(SELECT hull FROM artillery_battle)",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        const before = digest.stateHash(&gs);
        var accepted = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            continue;
        };
        accepted.deinit();
        std.debug.print("accepted corrupt artillery combat: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
}

test "combat decoder rejects duplicate canonical rows and coercible original types without schema constraints" {
    const Store = @import("store.zig").Store;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try campaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys=OFF; ALTER TABLE artillery_battle_seat RENAME TO original_seat; CREATE TABLE artillery_battle_seat(cid,report_ord,seat,person,name,present,wound_severity,wound_location,wound_permanent,fate,escape_roll,escape_target,xp)");
    for ([_][*:0]const u8{
        "INSERT INTO artillery_battle_seat SELECT * FROM original_seat",
        "UPDATE artillery_battle_seat SET person=(SELECT person FROM original_seat WHERE seat='gunner') WHERE seat='driver'",
        "UPDATE artillery_battle_seat SET person='1'",
        "UPDATE artillery_battle_seat SET cid='1'",
        "UPDATE artillery_battle_seat SET report_ord='0'",
        "UPDATE artillery_battle_seat SET present='1'",
        "UPDATE artillery_battle_seat SET xp='1'",
        "UPDATE artillery_battle_seat SET fate=NULL",
        "UPDATE artillery_battle_seat SET name=X'41'",
    }) |tamper| {
        try store.db.exec("DELETE FROM artillery_battle_seat; INSERT INTO artillery_battle_seat SELECT * FROM original_seat");
        try store.db.exec(tamper);
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    try store.db.exec("DELETE FROM artillery_battle_seat; INSERT INTO artillery_battle_seat SELECT * FROM original_seat; ALTER TABLE artillery_battle_slot RENAME TO original_slot; CREATE TABLE artillery_battle_slot(cid,report_ord,slot,before_condition,after_condition,before_rounds,after_rounds)");
    for ([_][*:0]const u8{
        "INSERT INTO artillery_battle_slot SELECT * FROM original_slot",
        "UPDATE artillery_battle_slot SET before_rounds='5' WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_battle_slot SET before_condition=X'6f6b'",
        "UPDATE artillery_battle_slot SET report_ord='0'",
    }) |tamper| {
        try store.db.exec("DELETE FROM artillery_battle_slot; INSERT INTO artillery_battle_slot SELECT * FROM original_slot");
        try store.db.exec(tamper);
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
}

test "failed combat child first save and overwrite preserve memory disk and retry" {
    const Store = @import("store.zig").Store;
    const digest = @import("../sim/digest.zig");
    const old_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_level;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try campaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    const reject = "CREATE TRIGGER reject_combat BEFORE INSERT ON artillery_battle_seat WHEN NEW.seat='gunner' BEGIN SELECT RAISE(ABORT,'injected'); END";
    try store.db.exec(reject);
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
    try std.testing.expectEqual(@as(i64, 0), gs.campaign_id);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    const st = try store.db.prepare("SELECT COUNT(*) FROM campaign");
    defer st.finalize();
    try std.testing.expect(try st.next());
    try std.testing.expectEqual(@as(i64, 0), st.int(0));
    try store.db.exec("DROP TRIGGER reject_combat");
    try store.save(&gs);
    const original = digest.stateHash(&gs);
    gs.battle_reports.kept.items[0].artillery.?.seats[0].name = "Changed captured name";
    const changed = digest.stateHash(&gs);
    try store.db.exec(reject);
    try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
    try std.testing.expectEqual(changed, digest.stateHash(&gs));
    var disk = try store.load(std.testing.allocator, gs.campaign_id);
    defer disk.deinit();
    try std.testing.expectEqual(original, digest.stateHash(&disk));
    try store.db.exec("DROP TRIGGER reject_combat");
    try store.save(&gs);
    var retried = try store.load(std.testing.allocator, gs.campaign_id);
    defer retried.deinit();
    try std.testing.expectEqual(changed, digest.stateHash(&retried));
}
