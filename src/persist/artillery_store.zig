//! Artillery row encoding within the store's single transaction.
//! No MekHQ counterpart: SQLite campaign representation (docs/mekhq-map.md).

const std = @import("std");
const sqlite = @import("sqlite.zig");
const types = @import("../domain/types.zig");
const operations = @import("../domain/artillery_operations.zig");
const dom = @import("../domain/artillery_formation.zig");
const GameState = @import("../sim/state.zig").GameState;

fn positiveId(comptime T: type, raw: i64) !T {
    const value = std.math.cast(u32, raw) orelse return error.CorruptSave;
    if (value == 0) return error.CorruptSave;
    return @enumFromInt(value);
}

test "artillery full campaign load rejects placement TEXT containing embedded NUL" {
    const store_mod = @import("store.zig");
    const artillery = @import("../sim/artillery.zig");
    const digest = @import("../sim/digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try @import("../sim/founding.zig").createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    _ = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    const store = try store_mod.Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var valid = try store.load(std.testing.allocator, gs.campaign_id);
    defer valid.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&valid));
    const malformed = "hq_pool\x00invalid";
    try store.db.exec("PRAGMA ignore_check_constraints=ON");
    const update = try store.db.prepare("UPDATE artillery_formation SET placement=?1 WHERE cid=?2");
    defer update.finalize();
    try update.bindAll(.{ malformed, gs.campaign_id });
    try update.run();
    try store.db.exec("PRAGMA ignore_check_constraints=OFF");
    const check = try store.db.prepare("SELECT placement,typeof(placement)='text' FROM artillery_formation WHERE cid=?1");
    defer check.finalize();
    try check.bindAll(.{gs.campaign_id});
    try std.testing.expect(try check.next());
    try std.testing.expectEqual(@as(i64, 1), check.int(1));
    const bytes = try check.text(0, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, malformed, bytes);
    var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        return;
    };
    loaded.deinit();
    return error.TestExpectedError;
}

fn optionalId(comptime T: type, st: sqlite.Stmt, column: c_int) !?T {
    return if (st.optInt(column)) |raw| try positiveId(T, raw) else null;
}

fn optionalDay(st: sqlite.Stmt, column: c_int) !?u32 {
    return if (st.optInt(column)) |raw| std.math.cast(u32, raw) orelse return error.CorruptSave else null;
}

/// Encode ordered formations/offers; the caller owns BEGIN/COMMIT and table clearing.
pub fn save(db: sqlite.Db, gs: *const GameState, cid: i64) !void {
    const fs = try db.prepare("INSERT INTO artillery_formation VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)");
    defer fs.finalize();
    for (gs.artillery_formations.values(), 0..) |f, ord| {
        const pool: ?types.HqId = if (f.placement == .hq_pool) f.placement.hq_pool else null;
        const co: ?types.ForceId = if (f.placement == .company) f.placement.company else null;
        const t: ?dom.Freight = if (f.placement == .freight) f.placement.freight else null;
        try fs.bindAll(.{ cid, ord, f.id, f.hull, f.acquisition_day, f.paid_price, @tagName(f.placement), pool, co, if (t) |v| @as(?types.HqId, v.from_hq) else null, if (t) |v| @as(?types.HqId, v.to_hq) else null, if (t) |v| @as(?u32, v.dispatch_day) else null, if (t) |v| @as(?u32, v.eta_day) else null, if (t) |v| @as(?types.CBills, v.paid_cost) else null, f.quality, f.armor_pct, f.last_maintenance_day, if (f.tech != .none) @as(?types.PersonId, f.tech) else null });
        try fs.run();
    }
    const cs = try db.prepare("INSERT INTO artillery_crew VALUES (?1,?2,?3,?4)");
    defer cs.finalize();
    const ss = try db.prepare("INSERT INTO artillery_slot VALUES (?1,?2,?3,?4,?5)");
    defer ss.finalize();
    for (gs.artillery_formations.values()) |f| {
        for (operations.seats, f.crew) |seat, occupant| {
            try cs.bindAll(.{ cid, f.id, seat, if (occupant != .none) @as(?types.PersonId, occupant) else null });
            try cs.run();
        }
        for (operations.descriptors, f.slots) |d, state| {
            try ss.bindAll(.{ cid, f.id, d.slot, state.condition, if (d.family != null) @as(?u16, state.rounds) else null });
            try ss.run();
        }
    }
    const checkpoint = try db.prepare("INSERT INTO meta VALUES (?1,'last_artillery_service_day',?2)");
    defer checkpoint.finalize();
    // SQL meta integers encode the nullable day with -1; zero is a real day.
    try checkpoint.bindAll(.{ cid, if (gs.last_artillery_service_day) |day| @as(i64, day) else -1 });
    try checkpoint.run();
    const os = try db.prepare("INSERT INTO artillery_offer VALUES (?1,?2,?3,?4,?5,?6,?7)");
    defer os.finalize();
    for (gs.artillery_offers.items, 0..) |o, ord| {
        try os.bindAll(.{ cid, ord, o.id, o.hq, o.year, o.month, o.available });
        try os.run();
    }
    // The serialized count distinguishes a deleted board from an HQ that is
    // legitimately awaiting its first market phase. It is not gameplay state.
    const count = try db.prepare("INSERT INTO meta VALUES (?1,'artillery_offer_count',?2)");
    defer count.finalize();
    try count.bindAll(.{ cid, gs.artillery_offers.items.len });
    try count.run();
}

/// Decode required current payloads without defaults; schema checks also enforce
/// disjoint placement, while decoding independently checks absent-column consistency.
pub fn load(db: sqlite.Db, gs: *GameState, cid: i64, version: u32) !void {
    if (version != 63) return error.CorruptSave;
    gs.next_artillery_formation_id = try requiredCounter(db, cid, "next_artillery_formation_id");
    gs.next_artillery_offer_id = try requiredCounter(db, cid, "next_artillery_offer_id");
    const fs = try db.prepare(
        \\SELECT id,hull,acquisition_day,paid_price,placement,pool_hq,company,
        \\       from_hq,to_hq,dispatch_day,eta_day,paid_cost,ord,
        \\       quality,armor,last_maintenance,tech,
        \\       typeof(cid)='integer' AND typeof(ord)='integer'
        \\       AND typeof(id)='integer' AND typeof(hull)='integer'
        \\       AND typeof(acquisition_day)='integer' AND typeof(paid_price)='integer'
        \\       AND typeof(placement)='text'
        \\       AND typeof(pool_hq) IN ('integer','null') AND typeof(company) IN ('integer','null')
        \\       AND typeof(from_hq) IN ('integer','null') AND typeof(to_hq) IN ('integer','null')
        \\       AND typeof(dispatch_day) IN ('integer','null') AND typeof(eta_day) IN ('integer','null')
        \\       AND typeof(paid_cost) IN ('integer','null')
        \\       AND typeof(quality)='text' AND typeof(armor)='integer'
        \\       AND typeof(last_maintenance) IN ('integer','null') AND typeof(tech) IN ('integer','null')
        \\FROM artillery_formation WHERE cid=?1 ORDER BY ord
    );
    defer fs.finalize();
    try fs.bindAll(.{cid});
    while (try fs.next()) {
        // SQLite integer reads coerce REAL/TEXT/BLOB and NULL. Check original
        // storage classes before any payload conversion (contract rule 47).
        if (fs.int(17) != 1) return error.CorruptSave;
        _ = try fs.intAs(usize, 12);
        const tag_bytes = try fs.text(4, gs.scratch());
        defer gs.scratch().free(tag_bytes);
        const tag = std.meta.stringToEnum(std.meta.Tag(dom.Placement), tag_bytes) orelse return error.CorruptSave;
        const pool = try optionalId(types.HqId, fs, 5);
        const co = try optionalId(types.ForceId, fs, 6);
        const from = try optionalId(types.HqId, fs, 7);
        const to = try optionalId(types.HqId, fs, 8);
        const sent = try optionalDay(fs, 9);
        const eta = try optionalDay(fs, 10);
        const cost = fs.optInt(11);
        const is_freight = tag == .freight;
        if ((pool != null) != (tag == .hq_pool) or (co != null) != (tag == .company) or (from != null) != is_freight or (to != null) != is_freight or (sent != null) != is_freight or (eta != null) != is_freight or (cost != null) != is_freight) return error.CorruptSave;
        const placement: dom.Placement = switch (tag) {
            .hq_pool => .{ .hq_pool = pool.? },
            .company => .{ .company = co.? },
            .sold => .sold,
            .destroyed => .destroyed,
            .freight => .{ .freight = .{ .from_hq = from.?, .to_hq = to.?, .dispatch_day = sent.?, .eta_day = eta.?, .paid_cost = cost.? } },
        };
        const quality_bytes = try fs.text(13, gs.scratch());
        defer gs.scratch().free(quality_bytes);
        const quality = std.meta.stringToEnum(types.Quality, quality_bytes) orelse return error.CorruptSave;
        const armor = try fs.intAs(u8, 14);
        if (armor > dom.intact_condition_pct) return error.CorruptSave;
        const last = try optionalDay(fs, 15);
        const tech = (try optionalId(types.PersonId, fs, 16)) orelse .none;
        const f: dom.Formation = .{ .id = try positiveId(types.ArtilleryFormationId, fs.int(0)), .hull = try positiveId(types.HullInstanceId, fs.int(1)), .acquisition_day = try fs.intAs(u32, 2), .paid_price = fs.int(3), .placement = placement, .quality = quality, .armor_pct = armor, .last_maintenance_day = last, .tech = tech };
        const gop = try gs.artillery_formations.getOrPut(gs.allocator(), f.id);
        if (gop.found_existing) return error.CorruptSave;
        gop.value_ptr.* = f;
    }
    try loadOperationalRows(db, gs, cid);
    try loadCheckpoint(db, gs, cid);
    const os = try db.prepare(
        \\SELECT id,hq,year,month,available,ord,
        \\       typeof(cid)='integer' AND typeof(ord)='integer'
        \\       AND typeof(id)='integer' AND typeof(hq)='integer'
        \\       AND typeof(year)='integer' AND typeof(month)='integer' AND typeof(available)='integer'
        \\FROM artillery_offer WHERE cid=?1 ORDER BY ord
    );
    defer os.finalize();
    try os.bindAll(.{cid});
    while (try os.next()) {
        if (os.int(6) != 1) return error.CorruptSave;
        _ = try os.intAs(usize, 5);
        const flag = try os.intAs(u8, 4);
        if (flag > 1) return error.CorruptSave;
        try gs.artillery_offers.append(gs.allocator(), .{ .id = try positiveId(types.ArtilleryOfferId, os.int(0)), .hq = try positiveId(types.HqId, os.int(1)), .year = try os.intAs(u16, 2), .month = try os.intAs(u8, 3), .available = flag == 1 });
    }
    if (gs.artillery_offers.items.len != try requiredMetaUint(db, cid, "artillery_offer_count")) return error.CorruptSave;
}

fn loadOperationalRows(db: sqlite.Db, gs: *GameState, cid: i64) !void {
    const seen = try gs.scratch().alloc(struct { crew: u8 = 0, slots: u16 = 0 }, gs.artillery_formations.count());
    defer gs.scratch().free(seen);
    @memset(seen, .{});
    const cs = try db.prepare("SELECT formation,seat,person,typeof(cid)='integer' AND typeof(formation)='integer' AND typeof(seat)='text' AND typeof(person) IN ('integer','null') FROM artillery_crew WHERE cid=?1");
    defer cs.finalize();
    try cs.bindAll(.{cid});
    while (try cs.next()) {
        if (cs.int(3) != 1) return error.CorruptSave;
        const id = try positiveId(types.ArtilleryFormationId, cs.int(0));
        const index = gs.artillery_formations.getIndex(id) orelse return error.CorruptSave;
        const bytes = try cs.text(1, gs.scratch());
        defer gs.scratch().free(bytes);
        const seat = std.meta.stringToEnum(operations.Seat, bytes) orelse return error.CorruptSave;
        const mask = @as(u8, 1) << @as(u3, @intCast(@intFromEnum(seat)));
        if (seen[index].crew & mask != 0) return error.CorruptSave;
        seen[index].crew |= mask;
        const occupant = (try optionalId(types.PersonId, cs, 2)) orelse .none;
        gs.artillery_formations.values()[index].crew[@intFromEnum(seat)] = occupant;
    }
    const ss = try db.prepare("SELECT formation,slot,condition,rounds,typeof(cid)='integer' AND typeof(formation)='integer' AND typeof(slot)='text' AND typeof(condition)='text' AND typeof(rounds) IN ('integer','null') FROM artillery_slot WHERE cid=?1");
    defer ss.finalize();
    try ss.bindAll(.{cid});
    while (try ss.next()) {
        if (ss.int(4) != 1) return error.CorruptSave;
        const id = try positiveId(types.ArtilleryFormationId, ss.int(0));
        const index = gs.artillery_formations.getIndex(id) orelse return error.CorruptSave;
        const bytes = try ss.text(1, gs.scratch());
        defer gs.scratch().free(bytes);
        const slot = std.meta.stringToEnum(operations.Slot, bytes) orelse return error.CorruptSave;
        const condition_bytes = try ss.text(2, gs.scratch());
        defer gs.scratch().free(condition_bytes);
        const condition = std.meta.stringToEnum(@import("../domain/unit.zig").PartCondition, condition_bytes) orelse return error.CorruptSave;
        const mask = @as(u16, 1) << @as(u4, @intCast(@intFromEnum(slot)));
        if (seen[index].slots & mask != 0) return error.CorruptSave;
        seen[index].slots |= mask;
        const d = operations.descriptor(slot);
        if ((ss.optInt(3) != null) != (d.family != null)) return error.CorruptSave;
        const rounds = if (ss.optInt(3)) |raw| std.math.cast(u16, raw) orelse return error.CorruptSave else 0;
        gs.artillery_formations.values()[index].slots[@intFromEnum(slot)] = .{ .condition = condition, .rounds = rounds };
    }
    for (seen, gs.artillery_formations.values()) |row, f| {
        if (row.crew != (@as(u8, 1) << operations.seats.len) - 1 or row.slots != (@as(u16, 1) << operations.descriptors.len) - 1) return error.CorruptSave;
        try operations.validateSlots(&f.slots);
    }
}

fn loadCheckpoint(db: sqlite.Db, gs: *GameState, cid: i64) !void {
    const st = try db.prepare("SELECT value,typeof(cid)='integer' AND typeof(value)='integer' FROM meta WHERE cid=?1 AND key='last_artillery_service_day'");
    defer st.finalize();
    try st.bindAll(.{cid});
    if (!try st.next()) return error.CorruptSave;
    if (st.int(1) != 1) return error.CorruptSave;
    const raw = st.int(0);
    const day: ?u32 = if (raw == -1) null else std.math.cast(u32, raw) orelse return error.CorruptSave;
    if (try st.next()) return error.CorruptSave;
    gs.last_artillery_service_day = day;
}

fn requiredCounter(db: sqlite.Db, cid: i64, key: []const u8) !u32 {
    const value = try requiredMetaUint(db, cid, key);
    if (value == 0) return error.CorruptSave;
    return value;
}

fn requiredMetaUint(db: sqlite.Db, cid: i64, key: []const u8) !u32 {
    const st = try db.prepare("SELECT value,typeof(cid)='integer' AND typeof(value)='integer' FROM meta WHERE cid=?1 AND key=?2");
    defer st.finalize();
    try st.bindAll(.{ cid, key });
    if (!try st.next() or st.int(1) != 1) return error.CorruptSave;
    const value = try st.intAs(u32, 0);
    if (try st.next()) return error.CorruptSave;
    return value;
}

test "positive artillery identities reject missing negative and overflowing values" {
    try std.testing.expectError(error.CorruptSave, positiveId(types.ArtilleryFormationId, 0));
    try std.testing.expectError(error.CorruptSave, positiveId(types.ArtilleryOfferId, -1));
    try std.testing.expectError(error.CorruptSave, positiveId(types.HqId, @as(i64, std.math.maxInt(u32)) + 1));
    try std.testing.expectEqual(@as(types.HullInstanceId, @enumFromInt(3)), try positiveId(types.HullInstanceId, 3));
}

test "artillery campaign load rejects fractional identity price and market year" {
    const store_mod = @import("store.zig");
    const commands = @import("../sim/commands.zig");
    const artillery = @import("../sim/artillery.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try @import("../sim/founding.zig").createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    _ = try commands.execute(&gs, .{ .buy_artillery = .{ .hq = home, .offer = gs.artillery_offers.items[0].id } });
    const store = try store_mod.Store.open(":memory:");
    defer store.close();
    try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
    for ([_][*:0]const u8{
        "UPDATE artillery_formation SET id=id+0.5",
        "UPDATE artillery_formation SET paid_price=paid_price+0.5",
        "UPDATE artillery_offer SET year=year+0.5",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec(tamper);
        var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        loaded.deinit();
        std.debug.print("accepted malformed artillery row: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
}

fn resetCodecFixture(db: sqlite.Db, placement: std.meta.Tag(dom.Placement)) !void {
    try db.exec(
        \\DELETE FROM artillery_crew;
        \\DELETE FROM artillery_slot;
        \\DELETE FROM artillery_formation;
        \\DELETE FROM artillery_offer;
        \\DELETE FROM meta;
        \\INSERT INTO artillery_formation VALUES(1,0,1,3,0,1779313,'hq_pool',1,NULL,NULL,NULL,NULL,NULL,NULL,'c',100,NULL,NULL);
        \\INSERT INTO artillery_offer VALUES(1,0,1,1,3025,1,0);
        \\INSERT INTO meta VALUES(1,'next_artillery_formation_id',2);
        \\INSERT INTO meta VALUES(1,'next_artillery_offer_id',2);
        \\INSERT INTO meta VALUES(1,'artillery_offer_count',1);
        \\INSERT INTO meta VALUES(1,'last_artillery_service_day',-1);
    );
    inline for (operations.seats) |seat| try db.exec("INSERT INTO artillery_crew VALUES(1,1,'" ++ @tagName(seat) ++ "',NULL)");
    inline for (operations.descriptors) |d| try db.exec("INSERT INTO artillery_slot VALUES(1,1,'" ++ @tagName(d.slot) ++ "','ok'," ++ (if (d.family != null) "0" else "NULL") ++ ")");
    switch (placement) {
        .hq_pool => {},
        .company => try db.exec("UPDATE artillery_formation SET placement='company',pool_hq=NULL,company=1"),
        .freight => try db.exec("UPDATE artillery_formation SET placement='freight',pool_hq=NULL,from_hq=1,to_hq=2,dispatch_day=0,eta_day=10,paid_cost=0"),
        .sold => try db.exec("UPDATE artillery_formation SET placement='sold',pool_hq=NULL"),
        .destroyed => try db.exec("UPDATE artillery_formation SET placement='destroyed',pool_hq=NULL"),
    }
}

fn openCodecFixture() !sqlite.Db {
    const db = try sqlite.Db.open(":memory:");
    errdefer db.close();
    // No affinities or constraints: malformed storage classes reach the decoder,
    // including required NULLs normally blocked by executable DDL's NOT NULL.
    try db.exec(
        \\CREATE TABLE artillery_formation(cid,ord,id,hull,acquisition_day,paid_price,placement,pool_hq,company,from_hq,to_hq,dispatch_day,eta_day,paid_cost,quality,armor,last_maintenance,tech);
        \\CREATE TABLE artillery_crew(cid,formation,seat,person);
        \\CREATE TABLE artillery_slot(cid,formation,slot,condition,rounds);
        \\CREATE TABLE artillery_offer(cid,ord,id,hq,year,month,available);
        \\CREATE TABLE meta(cid,key,value);
    );
    return db;
}

fn expectMalformedCodecValue(db: sqlite.Db, table: []const u8, field: []const u8, value: []const u8) !void {
    var sql: [256]u8 = undefined;
    try db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE {s} SET {s}={s}", .{ table, field, value }));
    var rows = GameState.init(std.testing.allocator, .{});
    defer rows.deinit();
    try std.testing.expectError(error.CorruptSave, load(db, &rows, 1, 63));
}

test "artillery codec rejects noninteger required fields and nontext placement tags" {
    const db = try openCodecFixture();
    defer db.close();
    const fields = [_]struct { table: []const u8, field: []const u8 }{
        .{ .table = "artillery_formation", .field = "ord" },
        .{ .table = "artillery_formation", .field = "id" },
        .{ .table = "artillery_formation", .field = "hull" },
        .{ .table = "artillery_formation", .field = "acquisition_day" },
        .{ .table = "artillery_formation", .field = "paid_price" },
        .{ .table = "artillery_offer", .field = "ord" },
        .{ .table = "artillery_offer", .field = "id" },
        .{ .table = "artillery_offer", .field = "hq" },
        .{ .table = "artillery_offer", .field = "year" },
        .{ .table = "artillery_offer", .field = "month" },
        .{ .table = "artillery_offer", .field = "available" },
    };
    for (fields) |field| {
        for ([_][]const u8{ "0.5", "'1'", "'invalid'", "X'31'", "NULL" }) |value| {
            try resetCodecFixture(db, .hq_pool);
            try expectMalformedCodecValue(db, field.table, field.field, value);
        }
    }
    for ([_][]const u8{ "artillery_formation", "artillery_offer", "meta" }) |table| {
        try resetCodecFixture(db, .hq_pool);
        try expectMalformedCodecValue(db, table, "cid", "1.0");
    }
    for ([_][]const u8{ "1", "0.5", "'unknown'", "X'68715f706f6f6c'", "NULL" }) |value| {
        try resetCodecFixture(db, .hq_pool);
        try expectMalformedCodecValue(db, "artillery_formation", "placement", value);
    }
}

test "artillery codec preserves integer and null placements and rejects coerced nullable payloads" {
    const db = try openCodecFixture();
    defer db.close();
    for (std.enums.values(std.meta.Tag(dom.Placement))) |placement| {
        try resetCodecFixture(db, placement);
        var rows = GameState.init(std.testing.allocator, .{});
        defer rows.deinit();
        try load(db, &rows, 1, 63);
        const formation = rows.artillery_formations.values()[0];
        try std.testing.expectEqual(placement, std.meta.activeTag(formation.placement));
        switch (formation.placement) {
            .hq_pool => |hq| try std.testing.expectEqual(@as(types.HqId, @enumFromInt(1)), hq),
            .company => |company| try std.testing.expectEqual(@as(types.ForceId, @enumFromInt(1)), company),
            .freight => |freight| try std.testing.expectEqualDeep(dom.Freight{ .from_hq = @enumFromInt(1), .to_hq = @enumFromInt(2), .dispatch_day = 0, .eta_day = 10, .paid_cost = 0 }, freight),
            .sold, .destroyed => {},
        }
        try std.testing.expectEqual(@as(u32, 0), formation.acquisition_day);
        try std.testing.expect(!rows.artillery_offers.items[0].available);
    }
    const fields = [_]struct { placement: std.meta.Tag(dom.Placement), field: []const u8 }{
        .{ .placement = .hq_pool, .field = "pool_hq" },
        .{ .placement = .company, .field = "company" },
        .{ .placement = .freight, .field = "from_hq" },
        .{ .placement = .freight, .field = "to_hq" },
        .{ .placement = .freight, .field = "dispatch_day" },
        .{ .placement = .freight, .field = "eta_day" },
        .{ .placement = .freight, .field = "paid_cost" },
    };
    for (fields) |field| {
        for ([_][]const u8{ "0.5", "'1'", "'invalid'", "X'31'", "NULL" }) |value| {
            try resetCodecFixture(db, field.placement);
            try expectMalformedCodecValue(db, "artillery_formation", field.field, value);
        }
    }
}

test "artillery codec requires integer counter and row count metadata" {
    const db = try openCodecFixture();
    defer db.close();
    for ([_][]const u8{ "next_artillery_formation_id", "next_artillery_offer_id", "artillery_offer_count" }) |key| {
        for ([_][]const u8{ "1.5", "'2'", "'invalid'", "X'32'", "NULL", "0", "-1", "4294967296" }) |value| {
            try resetCodecFixture(db, .hq_pool);
            var sql: [256]u8 = undefined;
            try db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE meta SET value={s} WHERE key='{s}'", .{ value, key }));
            var rows = GameState.init(std.testing.allocator, .{});
            defer rows.deinit();
            try std.testing.expectError(error.CorruptSave, load(db, &rows, 1, 63));
        }
    }
}

test "artillery row codecs and transactional facade preserve consumed offers and carrier identity" {
    const store_mod = @import("store.zig");
    const artillery = @import("../sim/artillery.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try @import("../sim/founding.zig").createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    const bought = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    const company = try gs.createForce("Company", .company, .none);
    try @import("../sim/toe.zig").assignCompanyToHq(&gs, company, home);
    _ = try artillery.attach(&gs, .{ .formation = bought.artillery_formation, .company = company });
    const store = try store_mod.Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var rows = GameState.init(std.testing.allocator, .{});
    defer rows.deinit();
    try load(store.db, &rows, gs.campaign_id, store_mod.schema_version);
    try std.testing.expectEqualDeep(gs.artillery_formations.get(bought.artillery_formation).?, rows.artillery_formations.get(bought.artillery_formation).?);
    try std.testing.expectEqualDeep(gs.artillery_offers.items, rows.artillery_offers.items);
    try std.testing.expectEqual(gs.next_artillery_formation_id, rows.next_artillery_formation_id);
    try std.testing.expectEqual(gs.next_artillery_offer_id, rows.next_artillery_offer_id);
    var campaign = try store.load(std.testing.allocator, gs.campaign_id);
    defer campaign.deinit();
    try std.testing.expectEqualDeep(rows.artillery_formations.values(), campaign.artillery_formations.values());
    try std.testing.expectEqual(company, campaign.artillery_formations.get(bought.artillery_formation).?.placement.company);
}

test "artillery consumed offer deletion fails closed before market synchronization" {
    const store_mod = @import("store.zig");
    const artillery = @import("../sim/artillery.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try @import("../sim/founding.zig").createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    _ = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    const store = try store_mod.Store.open(":memory:");
    defer store.close();
    _ = try @import("../sim/founding.zig").foundHq(&gs, "Far", .regional, "skye");
    try artillery.syncMarkets(&gs);
    for ([_][*:0]const u8{
        "DELETE FROM artillery_offer WHERE available=0",
        "DELETE FROM artillery_offer WHERE available=1",
        "DELETE FROM artillery_offer",
        "DELETE FROM meta WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=-1 WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=4294967296 WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=0 WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=3 WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=2.5 WHERE key='artillery_offer_count'",
        "UPDATE meta SET value='invalid' WHERE key='artillery_offer_count'",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec(tamper);
        var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        loaded.deinit();
        return error.TestExpectedError;
    }
}

test "offer completeness preserves zero boards and delayed initialization of new eligible HQs" {
    const store_mod = @import("store.zig");
    const artillery = @import("../sim/artillery.zig");
    const founding = @import("../sim/founding.zig");
    const hq_ops = @import("../sim/hq_ops.zig");
    const digest = @import("../sim/digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const store = try store_mod.Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var empty = try store.load(std.testing.allocator, gs.campaign_id);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.artillery_offers.items.len);
    for ([_][*:0]const u8{
        "UPDATE meta SET value='invalid' WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=0.5 WHERE key='artillery_offer_count'",
        "UPDATE meta SET value=X'00' WHERE key='artillery_offer_count'",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec(tamper);
        var malformed = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        malformed.deinit();
        return error.TestExpectedError;
    }

    const home = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice();
    _ = try artillery.buy(&gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    _ = try founding.foundHq(&gs, "New", .regional, "skye");
    const promoted = try founding.foundHq(&gs, "Promoted", .field, "alkaid");
    gs.hqs.getPtr(promoted).?.funds = hq_ops.tier_upgrade_cost;
    try hq_ops.startTierUpgrade(&gs, promoted);
    gs.clock.day_index = gs.hqs.getPtr(promoted).?.projects.items[0].construction_done_day;
    try hq_ops.runDaily(&gs);
    try std.testing.expectEqual(@import("../domain/hq.zig").HqTier.regional, gs.hqs.getPtr(promoted).?.tier);
    try std.testing.expectEqual(@as(usize, 1), gs.artillery_offers.items.len);
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    for ([_]*GameState{ &gs, &loaded }) |g| {
        try artillery.syncMarkets(g);
        try artillery.validate(g);
        try std.testing.expectEqual(@as(usize, 3), g.artillery_offers.items.len);
        try std.testing.expect(!g.artillery_offers.items[0].available);
    }
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
}

fn placementCampaignForTest(gs: *GameState, placement: std.meta.Tag(dom.Placement)) !void {
    const artillery = @import("../sim/artillery.zig");
    const founding = @import("../sim/founding.zig");
    const home = try founding.createCommander(gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice() * 10;
    const bought = try artillery.buy(gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    switch (placement) {
        .hq_pool => {},
        .company => {
            const company = try gs.createForce("Company", .company, .none);
            try @import("../sim/toe.zig").assignCompanyToHq(gs, company, home);
            _ = try artillery.attach(gs, .{ .formation = bought.artillery_formation, .company = company });
        },
        .freight => {
            const far = try founding.foundHq(gs, "Far", .regional, "skye");
            try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 2, .established_day = 0 });
            _ = try artillery.transfer(gs, .{ .formation = bought.artillery_formation, .to_hq = far });
        },
        .sold => _ = try artillery.sell(gs, bought.artillery_formation),
        .destroyed => try artillery.destroy(gs, bought.artillery_formation),
    }
    try artillery.validate(gs);
}

test "every artillery placement round trips exact tags and rejects incomplete TEXT" {
    const store_mod = @import("store.zig");
    const digest = @import("../sim/digest.zig");
    for (std.enums.values(std.meta.Tag(dom.Placement))) |placement| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        try placementCampaignForTest(&gs, placement);
        const store = try store_mod.Store.open(":memory:");
        defer store.close();
        try store.save(&gs);
        var valid = try store.load(std.testing.allocator, gs.campaign_id);
        defer valid.deinit();
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&valid));
        const embedded = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00invalid", .{@tagName(placement)});
        defer std.testing.allocator.free(embedded);
        const trailing = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00", .{@tagName(placement)});
        defer std.testing.allocator.free(trailing);
        for ([_][]const u8{ embedded, trailing, "", "unknown" }) |value| {
            try store.save(&gs);
            try store.db.exec("PRAGMA ignore_check_constraints=ON");
            const update = try store.db.prepare("UPDATE artillery_formation SET placement=?1 WHERE cid=?2");
            defer update.finalize();
            try update.bindAll(.{ value, gs.campaign_id });
            try update.run();
            try std.testing.expectEqual(@as(i64, 1), store.db.changes());
            try store.db.exec("PRAGMA ignore_check_constraints=OFF");
            const check = try store.db.prepare("SELECT placement,typeof(placement)='text' FROM artillery_formation WHERE cid=?1");
            defer check.finalize();
            try check.bindAll(.{gs.campaign_id});
            try std.testing.expect(try check.next());
            try std.testing.expectEqual(@as(i64, 1), check.int(1));
            const bytes = try check.text(0, std.testing.allocator);
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualSlices(u8, value, bytes);
            var malformed = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
                try std.testing.expectEqual(error.CorruptSave, err);
                continue;
            };
            malformed.deinit();
            return error.TestExpectedError;
        }
    }
}

test "placement tag scratch propagates allocation failure and releases bytes on every outcome" {
    const db = try openCodecFixture();
    defer db.close();
    for ([_][]const u8{ "hq_pool", "hq_pool\x00invalid" }) |value| {
        try resetCodecFixture(db, .hq_pool);
        const update = try db.prepare("UPDATE artillery_formation SET placement=?1");
        defer update.finalize();
        try update.bindAll(.{value});
        try update.run();
        for ([_]usize{ 0, 1, std.math.maxInt(usize) }) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            {
                var rows = GameState.init(failing.allocator(), .{});
                defer rows.deinit();
                if (fail_index == 0 or (fail_index == 1 and std.mem.eql(u8, value, "hq_pool"))) {
                    try std.testing.expectError(error.OutOfMemory, load(db, &rows, 1, 63));
                    try std.testing.expect(failing.has_induced_failure);
                } else if (std.mem.eql(u8, value, "hq_pool")) {
                    try load(db, &rows, 1, 63);
                    // Operational enums and row masks are scratch allocations;
                    // their bytes must be reclaimed alongside the campaign below.
                    try std.testing.expect(failing.deallocations > 0);
                } else {
                    try std.testing.expectError(error.CorruptSave, load(db, &rows, 1, 63));
                    try std.testing.expectEqual(@as(usize, value.len), failing.freed_bytes);
                }
            }
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
