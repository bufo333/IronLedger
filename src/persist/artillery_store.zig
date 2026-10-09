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
}

/// Decode required current payloads without defaults; schema checks also enforce
/// disjoint placement, while decoding independently checks absent-column consistency.
pub fn load(db: sqlite.Db, gs: *GameState, cid: i64, version: u32) !void {
    if (version >= 60) {
        gs.next_artillery_formation_id = try requiredCounter(db, cid, "next_artillery_formation_id");
        gs.next_artillery_offer_id = try requiredCounter(db, cid, "next_artillery_offer_id");
    }
    const fs = try db.prepare("SELECT id,hull,acquisition_day,paid_price,placement,pool_hq,company,from_hq,to_hq,dispatch_day,eta_day,paid_cost FROM artillery_formation WHERE cid=?1 ORDER BY ord");
    defer fs.finalize();
    try fs.bindAll(.{cid});
    while (try fs.next()) {
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
    const os = try db.prepare("SELECT id,hq,year,month,available FROM artillery_offer WHERE cid=?1 ORDER BY ord");
    defer os.finalize();
    try os.bindAll(.{cid});
    while (try os.next()) {
        const flag = try os.intAs(u8, 4);
        if (flag > 1) return error.CorruptSave;
        try gs.artillery_offers.append(gs.allocator(), .{ .id = try positiveId(types.ArtilleryOfferId, os.int(0)), .hq = try positiveId(types.HqId, os.int(1)), .year = try os.intAs(u16, 2), .month = try os.intAs(u8, 3), .available = flag == 1 });
    }
    if (version < 60 and (gs.artillery_formations.count() != 0 or gs.artillery_offers.items.len != 0)) return error.CorruptSave;
}

fn requiredCounter(db: sqlite.Db, cid: i64, key: []const u8) !u32 {
    const st = try db.prepare("SELECT value FROM meta WHERE cid=?1 AND key=?2");
    defer st.finalize();
    try st.bindAll(.{ cid, key });
    if (!try st.next()) return error.CorruptSave;
    const value = try st.intAs(u32, 0);
    if (value == 0 or try st.next()) return error.CorruptSave;
    return value;
}

test "positive artillery identities reject missing negative and overflowing values" {
    try std.testing.expectError(error.CorruptSave, positiveId(types.ArtilleryFormationId, 0));
    try std.testing.expectError(error.CorruptSave, positiveId(types.ArtilleryOfferId, -1));
    try std.testing.expectError(error.CorruptSave, positiveId(types.HqId, @as(i64, std.math.maxInt(u32)) + 1));
    try std.testing.expectEqual(@as(types.HullInstanceId, @enumFromInt(3)), try positiveId(types.HullInstanceId, 3));
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
