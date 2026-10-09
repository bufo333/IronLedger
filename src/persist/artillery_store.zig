//! Artillery row encoding within the store's single transaction.
//! No MekHQ counterpart: SQLite campaign representation (docs/mekhq-map.md).

const std = @import("std");
const sqlite = @import("sqlite.zig");
const types = @import("../domain/types.zig");
const dom = @import("../domain/artillery_formation.zig");
const GameState = @import("../sim/state.zig").GameState;

fn positiveId(comptime T: type, raw: i64) !T {
    const value = std.math.cast(u32, raw) orelse return error.CorruptSave;
    if (value == 0) return error.CorruptSave;
    return @enumFromInt(value);
}

fn optionalId(comptime T: type, st: sqlite.Stmt, column: c_int) !?T {
    return if (st.optInt(column)) |raw| try positiveId(T, raw) else null;
}

fn optionalDay(st: sqlite.Stmt, column: c_int) !?u32 {
    return if (st.optInt(column)) |raw| std.math.cast(u32, raw) orelse return error.CorruptSave else null;
}

/// Encode ordered formations/offers; the caller owns BEGIN/COMMIT and table clearing.
pub fn save(db: sqlite.Db, gs: *const GameState, cid: i64) !void {
    const fs = try db.prepare("INSERT INTO artillery_formation VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)");
    defer fs.finalize();
    for (gs.artillery_formations.values(), 0..) |f, ord| {
        const pool: ?types.HqId = if (f.placement == .hq_pool) f.placement.hq_pool else null;
        const co: ?types.ForceId = if (f.placement == .company) f.placement.company else null;
        const t: ?dom.Freight = if (f.placement == .freight) f.placement.freight else null;
        try fs.bindAll(.{ cid, ord, f.id, f.hull, f.acquisition_day, f.paid_price, @tagName(f.placement), pool, co, if (t) |v| @as(?types.HqId, v.from_hq) else null, if (t) |v| @as(?types.HqId, v.to_hq) else null, if (t) |v| @as(?u32, v.dispatch_day) else null, if (t) |v| @as(?u32, v.eta_day) else null, if (t) |v| @as(?types.CBills, v.paid_cost) else null });
        try fs.run();
    }
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
    if (version >= 60) {
        gs.next_artillery_formation_id = try requiredCounter(db, cid, "next_artillery_formation_id");
        gs.next_artillery_offer_id = try requiredCounter(db, cid, "next_artillery_offer_id");
    }
    const fs = try db.prepare(
        \\SELECT id,hull,acquisition_day,paid_price,placement,pool_hq,company,
        \\       from_hq,to_hq,dispatch_day,eta_day,paid_cost,ord,
        \\       typeof(cid)='integer' AND typeof(ord)='integer'
        \\       AND typeof(id)='integer' AND typeof(hull)='integer'
        \\       AND typeof(acquisition_day)='integer' AND typeof(paid_price)='integer'
        \\       AND typeof(placement)='text'
        \\       AND typeof(pool_hq) IN ('integer','null') AND typeof(company) IN ('integer','null')
        \\       AND typeof(from_hq) IN ('integer','null') AND typeof(to_hq) IN ('integer','null')
        \\       AND typeof(dispatch_day) IN ('integer','null') AND typeof(eta_day) IN ('integer','null')
        \\       AND typeof(paid_cost) IN ('integer','null')
        \\FROM artillery_formation WHERE cid=?1 ORDER BY ord
    );
    defer fs.finalize();
    try fs.bindAll(.{cid});
    while (try fs.next()) {
        // SQLite integer reads coerce REAL/TEXT/BLOB and NULL. Check original
        // storage classes before any payload conversion (contract rule 47).
        if (fs.int(13) != 1) return error.CorruptSave;
        _ = try fs.intAs(usize, 12);
        const tag = fs.enumValue(std.meta.Tag(dom.Placement), 4) orelse return error.CorruptSave;
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
            .freight => .{ .freight = .{ .from_hq = from.?, .to_hq = to.?, .dispatch_day = sent.?, .eta_day = eta.?, .paid_cost = cost.? } },
        };
        const f: dom.Formation = .{ .id = try positiveId(types.ArtilleryFormationId, fs.int(0)), .hull = try positiveId(types.HullInstanceId, fs.int(1)), .acquisition_day = try fs.intAs(u32, 2), .paid_price = fs.int(3), .placement = placement };
        const gop = try gs.artillery_formations.getOrPut(gs.allocator(), f.id);
        if (gop.found_existing) return error.CorruptSave;
        gop.value_ptr.* = f;
    }
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
    if (version >= 60 and gs.artillery_offers.items.len != try requiredMetaUint(db, cid, "artillery_offer_count")) return error.CorruptSave;
    if (version < 60 and (gs.artillery_formations.count() != 0 or gs.artillery_offers.items.len != 0)) return error.CorruptSave;
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
        \\DELETE FROM artillery_formation;
        \\DELETE FROM artillery_offer;
        \\DELETE FROM meta;
        \\INSERT INTO artillery_formation VALUES(1,0,1,3,0,1779313,'hq_pool',1,NULL,NULL,NULL,NULL,NULL,NULL);
        \\INSERT INTO artillery_offer VALUES(1,0,1,1,3025,1,0);
        \\INSERT INTO meta VALUES(1,'next_artillery_formation_id',2);
        \\INSERT INTO meta VALUES(1,'next_artillery_offer_id',2);
        \\INSERT INTO meta VALUES(1,'artillery_offer_count',1);
    );
    switch (placement) {
        .hq_pool => {},
        .company => try db.exec("UPDATE artillery_formation SET placement='company',pool_hq=NULL,company=1"),
        .freight => try db.exec("UPDATE artillery_formation SET placement='freight',pool_hq=NULL,from_hq=1,to_hq=2,dispatch_day=0,eta_day=10,paid_cost=0"),
        .sold => try db.exec("UPDATE artillery_formation SET placement='sold',pool_hq=NULL"),
    }
}

fn openCodecFixture() !sqlite.Db {
    const db = try sqlite.Db.open(":memory:");
    errdefer db.close();
    // No affinities or constraints: malformed storage classes reach the decoder,
    // including required NULLs normally blocked by executable DDL's NOT NULL.
    try db.exec(
        \\CREATE TABLE artillery_formation(cid,ord,id,hull,acquisition_day,paid_price,placement,pool_hq,company,from_hq,to_hq,dispatch_day,eta_day,paid_cost);
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
    try std.testing.expectError(error.CorruptSave, load(db, &rows, 1, 60));
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
        try load(db, &rows, 1, 60);
        const formation = rows.artillery_formations.values()[0];
        try std.testing.expectEqual(placement, std.meta.activeTag(formation.placement));
        switch (formation.placement) {
            .hq_pool => |hq| try std.testing.expectEqual(@as(types.HqId, @enumFromInt(1)), hq),
            .company => |company| try std.testing.expectEqual(@as(types.ForceId, @enumFromInt(1)), company),
            .freight => |freight| try std.testing.expectEqualDeep(dom.Freight{ .from_hq = @enumFromInt(1), .to_hq = @enumFromInt(2), .dispatch_day = 0, .eta_day = 10, .paid_cost = 0 }, freight),
            .sold => {},
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
            try std.testing.expectError(error.CorruptSave, load(db, &rows, 1, 60));
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
