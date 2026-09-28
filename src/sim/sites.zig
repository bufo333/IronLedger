//! Where stock sits, how much a site can hold, and how it moves between
//! sites: the HQ warehouse, a deployed company's field trucks, and the
//! outfit's fallback depot before any HQ exists (ARCH §9.8, "Warehouses
//! hold real tonnage"). A force draws supplies from its own field stores
//! while away from home and its home warehouse otherwise; goods a company
//! cannot use in the field ride a courier home (ARCH §9.5 supply-line
//! graph) rather than travel by freight.
//!
//! MekHQ counterpart: none — MekHQ has no per-site storage tonnage; see
//! `docs/mekhq-map.md`.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const part_mod = @import("../domain/part.zig");
const treasury = @import("treasury.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const posture = @import("posture.zig");
const network = @import("network.zig");
const hq_ops = @import("hq_ops.zig");
const commander_mod = @import("../domain/commander.zig");
const planet_mod = @import("../domain/planet.zig");
const logistics = @import("../econ/logistics.zig");
const market_mod = @import("../econ/market.zig");
const field_supply = @import("field_supply.zig");
const hq_mod = @import("../domain/hq.zig");
const faction_mod = @import("../domain/faction.zig");
const commands = @import("commands.zig");

/// Where a force draws supplies from: its own field stores while away
/// from home, its home warehouse otherwise.
pub fn siteForForce(gs: *GameState, force_id: types.ForceId) types.Site {
    const co = gs.companyOf(force_id);
    if (co != .none and !posture.isCompanyHome(gs, co)) return .{ .company = co };
    return gs.homeSiteFor(force_id);
}

/// Tonnage currently stored at a site.
pub fn siteTons(gs: *GameState, site: types.Site) u32 {
    const map = gs.stockMap(site) orelse return 0;
    var total: u32 = 0;
    var it = map.iterator();
    while (it.next()) |entry| total += entry.value_ptr.* * part_mod.tons(entry.key_ptr.*);
    return total;
}

/// Storage capacity (null = unlimited outfit depot). A company's cap is
/// its logistics trucks: 20t per cargo truck, 5t per salvage truck.
pub fn siteCapacityTons(gs: *GameState, site: types.Site) ?u32 {
    switch (site) {
        .outfit => return null,
        .hq => |id| return if (gs.hqs.getPtr(id)) |h| h.warehouseCapacityTons() else 0,
        .company => |id| {
            var cap: u32 = 0;
            var it = gs.units.iterator();
            while (it.next()) |entry| {
                const u = entry.value_ptr;
                if (u.status == .destroyed or gs.companyOf(u.force) != id) continue;
                if (std.mem.eql(u8, u.chassis_key, "CGT-3")) cap += tuning.unit.truck_tons.cargo;
                if (std.mem.eql(u8, u.chassis_key, "SVT-1")) cap += tuning.unit.truck_tons.salvage;
            }
            return cap;
        },
    }
}

pub fn siteFreeTons(gs: *GameState, site: types.Site) u32 {
    const cap = siteCapacityTons(gs, site) orelse return std.math.maxInt(u32);
    return cap -| siteTons(gs, site);
}

/// Move stock between sites on the spot (co-located handover). Returns
/// the quantity actually moved (bounded by source stock and destination
/// space).
pub fn moveStock(gs: *GameState, from: types.Site, to: types.Site, key: []const u8, qty: u32) !u32 {
    const have = gs.stockCount(from, key);
    const per = part_mod.tons(key);
    const fits = if (per == 0) qty else siteFreeTons(gs, to) / per;
    const n = @min(qty, @min(have, fits));
    if (n == 0) return 0;
    _ = gs.takeStock(from, key, n);
    try gs.addStock(to, key, n);
    return n;
}

/// Consume a batch of stock from a site: each key's quantity is removed.
/// A missing or short entry is silently skipped (C5 will validate).
/// Rule 14: the named consume operation for stock batches.
pub fn consumeStockBatch(gs: *GameState, site: types.Site, batch: *const std.StringArrayHashMapUnmanaged(u32)) void {
    var it = batch.iterator();
    while (it.next()) |entry| {
        _ = gs.takeStock(site, entry.key_ptr.*, entry.value_ptr.*);
    }
}

/// Crate goods a company picked up in the field (salvaged structure,
/// windfalls it cannot use out there) for the next convoy home: they
/// arrive at the home warehouse after the map transit, no freight — the
/// salvage crews haul them. Structural work is depot work.
pub fn sendHome(gs: *GameState, company: types.ForceId, key: []const u8, qty: u32) !void {
    if (qty == 0) return;
    const home = gs.homeHqFor(company);
    if (home == .none) {
        // No HQ yet (tests, pre-commander): straight into the outfit depot.
        try gs.addStock(gs.defaultSite(), key, qty);
        return;
    }
    const days = @max(3, treasury.courierEtaDays(gs, .{ .company = company }));
    try gs.part_orders.append(gs.allocator(), .{
        .part_key = key,
        .quantity = qty,
        .dest = .{ .hq = home },
        .ordered_day = gs.clock.day_index,
        .eta_day = gs.clock.day_index + days,
        .cost = 0,
        .status = .in_transit,
    });
}

/// The planet a site physically sits on.
pub fn sitePlanetKey(gs: *GameState, site: types.Site) ?[]const u8 {
    return switch (site) {
        .outfit => if (gs.hqs.count() > 0) gs.hqs.values()[0].planet_key else null,
        .hq => |id| if (gs.hqs.getPtr(id)) |h| h.planet_key else null,
        .company => |id| blk: {
            if (gs.deploymentContract(id)) |c| break :blk c.planet_key;
            if (gs.force(id)) |f| if (f.location_planet) |p| break :blk p;
            break :blk if (gs.hqs.getPtr(gs.homeHqFor(id))) |h| h.planet_key else null;
        },
    };
}

// ---- C4b supply/logistics command handlers moved from commands.zig ----

/// Result for order_part and replace_mount.
pub const OrderResult = struct { sourced: bool = true, hq: types.HqId = .none };
/// Result for ship_components_home.
pub const ShipComponentsResult = struct { count: u32 = 0, hq: types.HqId = .none };
/// Result for replace_gear.
pub const ReplaceGearResult = struct { ordered: u32 = 0, unsourced: u32 = 0 };

fn validateSite(gs: *GameState, site: types.Site) !void {
    switch (site) {
        .outfit => {},
        .hq => |id| if (gs.hqs.getPtr(id) == null) return error.UnknownSite,
        .company => |id| {
            const f = gs.force(id) orelse return error.UnknownSite;
            if (f.echelon != .company) return error.NotACompany;
        },
    }
}

/// Refuse anything the destination can't hold once inbound goods land.
pub fn checkRoom(gs: *GameState, site: types.Site, part_key: []const u8, quantity: u32) !void {
    const cap = siteCapacityTons(gs, site) orelse return;
    const used = siteTons(gs, site) + field_supply.inboundTonsTo(gs, site);
    if (used + quantity * part_mod.tons(part_key) > cap) return error.StorageFull;
}

/// A freight quote: what a shipment costs, how long it takes, and the
/// linked route whose weekly capacity it needs.
pub const Freight = struct {
    cost: types.CBills,
    days: u32,
    route: []const network.RouteHop = &.{},
    tons: u32 = 0,
};

/// Quote freight between two sites: HQ→HQ legs ride the
/// supply-link route (multi-hop, throughput-capped; charter if unlinked);
/// the last leg to a deployed company is a direct charter from its home
/// HQ. Transport admins negotiate better rates. Pure: refuses with
/// `ThroughputExceeded` when the route is full, but books nothing; the
/// caller runs `commitFreight` once the payment has cleared. The route
/// lives in `alloc`.
pub fn freightQuote(gs: *GameState, alloc: std.mem.Allocator, from: types.Site, to: types.Site, tons_moved: u32) !Freight {
    const a = planet_mod.find(sitePlanetKey(gs, from) orelse "") orelse return .{ .cost = 0, .days = logistics.same_world_days };
    const b = planet_mod.find(sitePlanetKey(gs, to) orelse "") orelse return .{ .cost = 0, .days = logistics.same_world_days };
    var route: []const network.RouteHop = &.{};
    var days: u32 = logistics.same_world_days;
    var cost: types.CBills = 0;

    const from_hq: types.HqId = switch (from) {
        .hq => |id| id,
        .company => |id| gs.homeHqFor(id),
        .outfit => if (gs.hqs.count() > 0) gs.hqs.keys()[0] else .none,
    };
    const to_hq: types.HqId = switch (to) {
        .hq => |id| id,
        .company => |id| gs.homeHqFor(id),
        .outfit => if (gs.hqs.count() > 0) gs.hqs.keys()[0] else .none,
    };
    if (from_hq != .none and to_hq != .none and from_hq != to_hq) {
        route = try network.routeBetween(gs, from_hq, to_hq, alloc);
        if (!network.fitsThroughput(gs, route, tons_moved)) return error.ThroughputExceeded;
        days = network.routeDays(route);
        var jumps_total: u32 = 0;
        for (route) |h| jumps_total += h.hop.jumps;
        cost = types.applyBp(@as(types.CBills, tons_moved) * tuning.logistics.freight_per_ton_jump * @as(types.CBills, @max(1, jumps_total)), network.routeCostMultBp(route));
    }
    // Final leg: home HQ → the company's contract planet (or same world).
    const last_from = if (to_hq != .none) planet_mod.find(gs.hqs.getPtr(to_hq).?.planet_key) orelse a else a;
    if (last_from != b) {
        const jumps = planet_mod.jumpsBetween(last_from, b);
        days += logistics.transitDays(jumps);
        cost += @as(types.CBills, tons_moved) * tuning.logistics.freight_per_ton_jump * @as(types.CBills, @max(1, jumps));
    } else if (from_hq == to_hq) {
        days = tuning.logistics.freight_min_days;
    }
    cost = types.applyBp(cost, commander_mod.costMultBp(gs.commander, .freight));
    if (gs.hqs.count() > 0) {
        const transport = hq_ops.hqStaff(gs, gs.hqs.keys()[0], .admin_transport);
        cost = types.applyBp(cost, 10_000 - tuning.logistics.transport_admin_discount_bp * @as(types.Bp, @min(tuning.logistics.transport_admin_max, transport.count)));
    }
    return .{ .cost = cost, .days = @max(tuning.logistics.freight_min_days, days), .route = route, .tons = tons_moved };
}

/// Book a quoted shipment's tonnage on its route. Cannot fail: the quote
/// checked the capacity against the same state.
pub fn commitFreight(gs: *GameState, f: Freight) void {
    network.commitThroughput(gs, f.route, f.tons);
}

pub fn shipStock(gs: *GameState, part_key: []const u8, quantity: u32, from: types.Site, to: types.Site) !void {
    if (part_mod.find(part_key) == null) return error.UnknownPart;
    try validateSite(gs, from);
    try validateSite(gs, to);
    if (gs.stockCount(from, part_key) < quantity) return error.InsufficientStock;
    try checkRoom(gs, to, part_key, quantity);

    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const freight = try freightQuote(gs, arena.allocator(), from, to, quantity * part_mod.tons(part_key));
    const payer = state_mod.Treasury.ofSite(from);
    const tags = payer.tags();
    if (freight.cost > 0) {
        try treasury.debit(gs, payer, .{
            .day = gs.clock.day_index,
            .amount = -freight.cost,
            .category = .freight,
            .company = tags.company,
            .hq = tags.hq,
            .note = part_key,
        });
    }
    if (!gs.takeStock(from, part_key, quantity)) return error.InsufficientStock;
    commitFreight(gs, freight);
    try gs.part_orders.append(gs.allocator(), .{
        .part_key = part_mod.find(part_key).?.key,
        .quantity = quantity,
        .dest = to,
        .ordered_day = gs.clock.day_index,
        .eta_day = gs.clock.day_index + freight.days,
        .cost = freight.cost,
        .status = .in_transit,
    });
    try gs.log(.delivery, .{ .company = tags.company, .hq = tags.hq }, "[shipment] {s} x{d} dispatched, eta {d} days, freight {d}", .{ part_key, quantity, freight.days, freight.cost });
}

pub fn setStockPolicy(gs: *GameState, hq_id: types.HqId, part_key: []const u8, min: u32, target: u32) !void {
    if (gs.hqs.getPtr(hq_id) == null) return error.UnknownHq;
    const def = part_mod.find(part_key) orelse return error.UnknownPart;
    const actual_target = @max(target, min);
    var i: usize = 0;
    while (i < gs.stock_policies.items.len) : (i += 1) {
        const line = &gs.stock_policies.items[i];
        if (line.hq == hq_id and std.mem.eql(u8, line.part_key, def.key)) {
            if (target == 0) {
                _ = gs.stock_policies.orderedRemove(i);
            } else {
                line.min = min;
                line.target = actual_target;
            }
            return;
        }
    }
    if (target == 0) return;
    try gs.stock_policies.append(gs.allocator(), .{ .hq = hq_id, .part_key = def.key, .min = min, .target = actual_target });
}

pub fn sellStock(gs: *GameState, hq_id: types.HqId, part_key: []const u8, quantity: u32) !void {
    const h = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    const def = part_mod.find(part_key) orelse return error.UnknownPart;
    if (quantity == 0) return;
    const have = gs.stockCount(.{ .hq = hq_id }, def.key);
    if (have < quantity) return error.InsufficientStock;
    for (gs.stock_policies.items) |sp| {
        if (sp.hq == hq_id and std.mem.eql(u8, sp.part_key, def.key) and have - quantity < sp.min) return error.KeepStocked;
    }
    const value = market_mod.stockSaleValue(def.key, quantity);
    _ = gs.takeStock(.{ .hq = hq_id }, def.key, quantity);
    try gs.postTreasury(.{ .hq = hq_id }, .{ .day = gs.clock.day_index, .amount = value, .category = .unit_sale, .hq = hq_id, .note = def.key });
    try gs.log(.market, .{ .hq = hq_id }, "[sale] {d} {s} sold from {s} for {d}", .{ quantity, def.key, h.name, value });
}

pub fn shipComponentsHome(gs: *GameState, company: types.ForceId) !ShipComponentsResult {
    const f = gs.forces.getPtr(company) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;
    const home = gs.homeHqFor(company);
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(gs.allocator());
    var qtys: std.ArrayListUnmanaged(u32) = .empty;
    defer qtys.deinit(gs.allocator());
    var it = f.stock.iterator();
    while (it.next()) |e| if (part_mod.isComponent(e.key_ptr.*) and e.value_ptr.* > 0) {
        try keys.append(gs.allocator(), e.key_ptr.*);
        try qtys.append(gs.allocator(), e.value_ptr.*);
    };
    if (keys.items.len == 0) return error.NothingToShip;
    var sent: u32 = 0;
    for (keys.items, qtys.items) |key, qty| {
        // A line the route, the room or the funds refuse stays with the
        // company; `shipStock` refuses before anything moves, so only an
        // allocation failure can follow a paid freight bill.
        shipStock(gs, key, qty, .{ .company = company }, .{ .hq = home }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        sent += qty;
    }
    return .{ .count = sent, .hq = home };
}

pub fn replaceMount(gs: *GameState, unit_id: types.UnitId, slot_key: []const u8) !OrderResult {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    for (u.slots.items) |s| {
        if (!std.mem.eql(u8, s.slot_key, slot_key)) continue;
        if (s.condition == .ok) return error.MountIsFine;
        const home = gs.homeHqFor(u.force);
        var res = try orderPart(gs, s.part_key, 1, .{ .hq = home });
        res.hq = home;
        return res;
    }
    return error.NoSuchSlot;
}

pub fn orderPart(gs: *GameState, part_key: []const u8, quantity: u32, dest_opt: ?types.Site) !OrderResult {
    const def = part_mod.find(part_key) orelse return error.UnknownPart;
    if (gs.hqs.count() == 0) return error.NoHq;
    const dest: types.Site = dest_opt orelse gs.defaultSite();
    try validateSite(gs, dest);
    try checkRoom(gs, dest, part_key, quantity);

    // The destination's home HQ sources and pays.
    const hq_id: types.HqId = switch (dest) {
        .hq => |id| id,
        .company => |id| gs.homeHqFor(id),
        .outfit => gs.hqs.keys()[0],
    };
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    const world = planet_mod.find(hq.planet_key) orelse return error.UnknownPlanet;

    const cost_mult: types.Bp = types.applyBp(tuning.market.procurement_markup_bp, gs.diff().purchase_bp); // 10% procurement markup, scaled by difficulty
    var lead_days: u32 = logistics.transitDays(1);
    // Onward shipment to a deployed company: more days, freight on top.
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const onward = try freightQuote(gs, arena.allocator(), .{ .hq = hq_id }, dest, quantity * def.pallet_tons);
    if (dest == .company) lead_days += onward.days;

    // Logistics-admin acquisition roll vs. rarity (MekHQ-style). The back
    // office: the best posted logistics admin works the roll, and
    // a bigger office shaves the lead time. Components can be bought this
    // way when rarity allows — or fabricated (guaranteed) in the bay.
    const logi = hq_ops.hqStaff(gs, hq_id, .admin_logistics);
    const admin_bonus: i32 = if (logi.count == 0) -2 else 5 - @as(i32, logi.best_skill);
    lead_days = @max(3, lead_days -| @min(4, logi.count / 2));
    // Sourcing: the part's availability code, the world's shelves,
    // the HQ's comms reach.
    const src = part_mod.sourcing(def, faction_mod.isPeriphery(world.faction), hq.effectiveFacilityLevel(.comms));
    const roll = @as(i32, gs.rng.roll2d6(.acquisition)) + admin_bonus + world.industry / 2 + src.total();
    const sourced = roll >= def.rarity.availabilityTarget();

    if (!sourced) {
        try gs.part_orders.append(gs.allocator(), .{
            .part_key = def.key,
            .quantity = quantity,
            .dest = dest,
            .ordered_day = gs.clock.day_index,
            .cost = 0,
            .status = .failed,
        });
        const why = try src.text(gs.allocator(), def);
        try gs.log(.delivery, .{ .hq = hq_id }, "[order] logistics could not source {d} × {s} this time ({s}, roll {d} vs {d}{s}{s}) — retry after the monthly refresh{s}", .{
            quantity, def.key, @tagName(def.rarity), roll, def.rarity.availabilityTarget(), if (why.len > 0) "; " else "", why, if (part_mod.isComponent(def.key)) ", or fabricate it in the bay" else "",
        });
        return .{ .sourced = false };
    }

    // Orders placed at the HQ are paid from the HQ's treasury,
    // onward freight to the field included.
    var total = types.applyBp(def.cost * quantity, cost_mult);
    total = types.applyBp(total, commander_mod.costMultBp(gs.commander, .freight));
    if (dest == .company) total += onward.cost;
    try treasury.debit(gs, .{ .hq = hq_id }, .{
        .day = gs.clock.day_index,
        .amount = -total,
        .category = .parts,
        .hq = hq_id,
        .note = def.name,
    });
    if (dest == .company) commitFreight(gs, onward);
    try gs.part_orders.append(gs.allocator(), .{
        .part_key = def.key,
        .quantity = quantity,
        .dest = dest,
        .ordered_day = gs.clock.day_index,
        .eta_day = gs.clock.day_index + lead_days,
        .cost = total,
        .status = .in_transit,
    });
    return .{};
}

/// `replace_gear`: one spare per destroyed or missing weapon/equipment/ammo
/// slot, ordered to the hull's site so its own tech can fit it on the
/// weekly repair pass (ARCH §9.7). Spares already on that shelf or already
/// on order for it are counted first, so calling twice orders nothing new.
/// Damaged gear needs hours, not parts; structure is `depot` work.
pub fn replaceGear(gs: *GameState, unit_id: types.UnitId) !ReplaceGearResult {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    if (gs.hqs.count() == 0) return error.NoHq;
    const site = hq_ops.spareSiteFor(gs, u);
    var wanted: u32 = 0;
    var ordered: u32 = 0;
    var unsourced: u32 = 0;
    // The site's ledger (hq_ops.spareDemand) says what is short across every
    // hull there; this hull's broken mounts of a part get up to that many.
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const ledger = hq_ops.spareDemand(arena.allocator(), gs, site) catch return error.OutOfMemory;
    for (u.slots.items, 0..) |s, i| {
        if (!hq_ops.slotNeedsSpare(s)) continue;
        wanted += 1;
        var nth: u32 = 0;
        for (u.slots.items[0..i]) |t| if (hq_ops.slotNeedsSpare(t) and std.mem.eql(u8, t.part_key, s.part_key)) {
            nth += 1;
        };
        var short: u32 = 0;
        for (ledger) |l| if (std.mem.eql(u8, l.key, s.part_key)) {
            short = l.short;
        };
        if (nth >= short) continue;
        const r = try orderPart(gs, s.part_key, 1, site);
        if (r.sourced) ordered += 1 else unsourced += 1;
    }
    if (wanted == 0) return error.NothingToReplace;
    return .{ .ordered = ordered, .unsourced = unsourced };
}

// ---- C4b personnel/crew command handlers moved from commands.zig ----

/// Transit days between two companies' worlds (0 if co-located).
pub fn travelDays(gs: *GameState, from_company: types.ForceId, to_company: types.ForceId) u32 {
    const a = planet_mod.find(sitePlanetKey(gs, .{ .company = from_company }) orelse "") orelse return 0;
    const b = planet_mod.find(sitePlanetKey(gs, .{ .company = to_company }) orelse "") orelse return 0;
    if (a == b) return 0;
    return logistics.daysBetween(a, b);
}

// ---- C4b exec wrappers ----
const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execOrderPart(gs: *GameState, o: @FieldType(Command, "order_part")) Error!Result {
    const res = orderPart(gs, o.part_key, o.quantity, o.dest) catch |err| return @errorCast(err);
    return .{ .sourced = res.sourced };
}

pub fn execShipStock(gs: *GameState, s: @FieldType(Command, "ship_stock")) Error!Result {
    shipStock(gs, s.part_key, s.quantity, s.from, s.to) catch |err| return @errorCast(err);
    return .{};
}

pub fn execSetStockPolicy(gs: *GameState, sp: @FieldType(Command, "set_stock_policy")) Error!Result {
    setStockPolicy(gs, sp.hq, sp.part_key, sp.min, sp.target) catch |err| return @errorCast(err);
    return .{};
}

pub fn execSellStock(gs: *GameState, sale: @FieldType(Command, "sell_stock")) Error!Result {
    sellStock(gs, sale.hq, sale.part_key, sale.quantity) catch |err| return @errorCast(err);
    return .{};
}

pub fn execReplaceGear(gs: *GameState, unit_id: @FieldType(Command, "replace_gear")) Error!Result {
    const res = replaceGear(gs, unit_id) catch |err| return @errorCast(err);
    return .{ .ordered = res.ordered, .unsourced = res.unsourced };
}

pub fn execReplaceMount(gs: *GameState, r: @FieldType(Command, "replace_mount")) Error!Result {
    const res = replaceMount(gs, r.unit, r.slot_key) catch |err| return @errorCast(err);
    return .{ .sourced = res.sourced, .hq = res.hq };
}

pub fn execShipComponentsHome(gs: *GameState, co: @FieldType(Command, "ship_components_home")) Error!Result {
    const res = shipComponentsHome(gs, co) catch |err| return @errorCast(err);
    return .{ .count = res.count, .hq = res.hq };
}

test "order_part is refused over the site's free tons and accepted at the limit" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];
    gs.hqs.values()[0].funds = 100_000_000;
    const site: types.Site = .{ .hq = hq_id };

    // An HQ site has a finite capacity, and nothing is already inbound to
    // it: the refusal below is exactly siteFreeTons, with no overflow or
    // inbound tonnage muddying the boundary.
    try std.testing.expect(siteCapacityTons(&gs, site) != null);
    try std.testing.expectEqual(@as(u32, 0), field_supply.inboundTonsTo(&gs, site));

    const free = siteFreeTons(&gs, site);
    try std.testing.expectError(commands.Error.StorageFull, commands.execute(&gs, .{
        .order_part = .{ .part_key = "provisions", .quantity = free + 1, .dest = site },
    }));

    // Exactly the free tonnage fits: the room check does not refuse it, and
    // the order is recorded against this site.
    _ = try commands.execute(&gs, .{ .order_part = .{ .part_key = "provisions", .quantity = free, .dest = site } });
    var found = false;
    for (gs.part_orders.items) |o| {
        if (std.mem.eql(u8, o.part_key, "provisions") and o.quantity == free and std.meta.eql(o.dest, site)) found = true;
    }
    try std.testing.expect(found);
}

test "a stock policy reorders a warehouse line to its target, once, and can be removed" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 20_000_000;
    gs.stock_policies.clearRetainingCapacity(); // drop the default provisions line — this test counts lines
    try std.testing.expectError(commands.Error.UnknownPart, commands.execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "unobtainium", .min = 1, .target = 2 } }));
    _ = try commands.execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = 5, .target = 30 } });
    try std.testing.expectEqual(@as(usize, 1), gs.stock_policies.items.len);
    // The founding warehouse holds some reloads already: above the minimum, nothing happens.
    _ = try commands.execute(&gs, .advance_day);
    try std.testing.expectEqual(@as(usize, 0), gs.part_orders.items.len);
    _ = gs.takeStock(.{ .hq = hq }, "ammo_lrm", gs.stockCount(.{ .hq = hq }, "ammo_lrm") - 4);
    // A few days for the sourcing roll to land (a miss waits a week).
    var ordered: u32 = 0;
    var days: u32 = 0;
    while (ordered == 0 and days < 30) : (days += 1) {
        _ = try commands.execute(&gs, .advance_day);
        for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "ammo_lrm") and o.dest == .hq and o.status != .failed) {
            ordered += o.quantity;
        };
    }
    try std.testing.expectEqual(@as(u32, 30 - 4), ordered);
    // Nothing more is ordered while that one is in flight.
    _ = try commands.execute(&gs, .advance_day);
    var live: usize = 0;
    for (gs.part_orders.items) |o| if (std.mem.eql(u8, o.part_key, "ammo_lrm") and o.status != .failed) {
        live += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), live);
    // Re-setting replaces; target 0 removes.
    _ = try commands.execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = 5, .target = 3 } });
    try std.testing.expectEqual(@as(usize, 1), gs.stock_policies.items.len);
    try std.testing.expectEqual(@as(u32, 5), gs.stock_policies.items[0].target); // clamped up to min
    _ = try commands.execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = 0, .target = 0 } });
    try std.testing.expectEqual(@as(usize, 0), gs.stock_policies.items.len);
}

test "selling warehouse stock pays the HQ and respects a keep-stocked minimum" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    try gs.addStock(.{ .hq = hq }, "ammo_lrm", 20);
    const have = gs.stockCount(.{ .hq = hq }, "ammo_lrm");
    const funds_before = gs.hqs.getPtr(hq).?.funds;
    try std.testing.expectError(commands.Error.InsufficientStock, commands.execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = have + 1 } }));
    _ = try commands.execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = 10 } });
    try std.testing.expectEqual(have - 10, gs.stockCount(.{ .hq = hq }, "ammo_lrm"));
    try std.testing.expectEqual(funds_before + market_mod.stockSaleValue("ammo_lrm", 10), gs.hqs.getPtr(hq).?.funds);
    try std.testing.expect(market_mod.stockSaleValue("ammo_lrm", 10) > 0);
    _ = try commands.execute(&gs, .{ .set_stock_policy = .{ .hq = hq, .part_key = "ammo_lrm", .min = have - 12, .target = have } });
    try std.testing.expectError(commands.Error.KeepStocked, commands.execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = 5 } }));
    _ = try commands.execute(&gs, .{ .sell_stock = .{ .hq = hq, .part_key = "ammo_lrm", .quantity = 2 } });
}

test "warehouses are finite — orders that won't fit are refused" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 94 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];
    gs.hqs.values()[0].funds = 100_000_000;

    // The room check runs before the sourcing roll, so an oversized order
    // is refused deterministically.
    const cap = gs.hqs.values()[0].warehouseCapacityTons(); // 200t at level 1
    const used = siteTons(&gs, .{ .hq = hq_id });
    try std.testing.expectError(commands.Error.StorageFull, commands.execute(&gs, .{
        .order_part = .{ .part_key = "provisions", .quantity = cap - used + 1 },
    }));
    // Shipping something you don't have is refused too.
    try std.testing.expectError(commands.Error.InsufficientStock, commands.execute(&gs, .{
        .ship_stock = .{ .part_key = "ppc", .quantity = 1, .from = .{ .hq = hq_id }, .to = .{ .hq = hq_id } },
    }));
}

test "a failed sourcing roll is reported, keeps its destination, and clears after two weeks" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1228 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .paymaster } });
    const hq = gs.hqs.keys()[0];
    gs.hqs.getPtr(hq).?.funds = 50_000_000;
    // Order a rare component many times: at least one roll fails.
    var failed: ?usize = null;
    var tries: u32 = 0;
    while (failed == null and tries < 40) : (tries += 1) {
        const r = try commands.execute(&gs, .{ .order_part = .{ .part_key = "comp_ct", .quantity = 1, .dest = .{ .hq = hq } } });
        if (!r.sourced) failed = gs.part_orders.items.len - 1;
    }
    try std.testing.expect(failed != null);
    const o = gs.part_orders.items[failed.?];
    try std.testing.expect(o.status == .failed and o.dest == .hq and o.dest.hq == hq);
    // Two weeks on, the failed record is gone.
    const tick = @import("tick.zig");
    gs.clock.day_index += 14;
    try tick.runTravel(&gs);
    for (gs.part_orders.items) |po| try std.testing.expect(po.status != .failed);
}

test "gear on any hull is field work — replace orders the spare to its site, the tech fits it" {
    const crew = @import("crew.zig");
    const unit_mod = @import("../domain/unit.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 61 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const uid = try gs.addUnit("SVT-1"); // a salvage truck: cargo, not a mek
    const tech = try gs.hirePerson("Wren", "Okafor", .tech_mechanic);
    try crew.assignSlot(&gs, uid, .tech, tech);
    for (gs.unit(uid).?.slots.items) |*s| if (std.mem.eql(u8, s.slot_key, "bed.winch.1")) {
        s.condition = .destroyed;
    };

    // The Lab's door is shut to it, and the depot only does structure.
    try std.testing.expectError(commands.Error.NotAMek, commands.execute(&gs, .{ .refit_remove = .{ .unit = uid, .slot_key = "bed.winch.1" } }));
    try std.testing.expectError(commands.Error.NothingToRepair, commands.execute(&gs, .{ .depot = uid }));

    // replace orders exactly one winch to the hull's site; once it is on
    // order a second call orders nothing more.
    const site = siteForForce(&gs, gs.unit(uid).?.force);
    const r = try commands.execute(&gs, .{ .replace_gear = uid });
    try std.testing.expectEqual(@as(u32, 1), r.ordered + r.unsourced);
    if (r.ordered == 1) {
        const again = try commands.execute(&gs, .{ .replace_gear = uid });
        try std.testing.expectEqual(@as(u32, 0), again.ordered + again.unsourced);
    }

    // Sourcing is a roll: put the spare on the shelf and let the weekly
    // pass fit it — the mechanic's own hours, no bay involved.
    try gs.addStock(site, "winch", 1);
    _ = try commands.execute(&gs, .{ .advance_days = 7 });
    for (gs.unit(uid).?.slots.items) |s| if (std.mem.eql(u8, s.slot_key, "bed.winch.1")) {
        try std.testing.expectEqual(unit_mod.PartCondition.ok, s.condition);
    };
    try std.testing.expectError(commands.Error.NothingToReplace, commands.execute(&gs, .{ .replace_gear = uid }));
}

test "ship_stock propagates OutOfMemory and moves nothing" {
    // `outer` owns every byte the campaign arena ever hands out, so
    // detaching the arena's own headroom tracking below cannot leak.
    const founding = @import("founding.zig");
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var gs = GameState.init(outer.allocator(), .{ .seed = 7501 });
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const home = gs.hqs.keys()[0];
    const far = try founding.foundHq(&gs, "Frontier", .field, "alkaid");
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 1, .established_day = 0 });
    try gs.addStock(.{ .hq = far }, "armor", 10);
    gs.hqs.getPtr(far).?.funds = 10_000_000;
    const funds_before = gs.hqs.getPtr(far).?.funds;
    const stock_before = gs.stockCount(.{ .hq = far }, "armor");
    const orders_before = gs.part_orders.items.len;

    // Discard the arena's spare headroom and fail every further allocation
    // (calibrated: 950 bytes fails inside `freightQuote`'s own
    // `routeBetween` call, verified against a stack trace — before the
    // freight debit, the stock move or the part-order log): the refusal
    // must surface as OutOfMemory and move nothing.
    gs.arena.state.used_list = null;
    gs.arena.state.free_list = null;
    const buf = try std.testing.allocator.alloc(u8, 950);
    defer std.testing.allocator.free(buf);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    gs.arena.child_allocator = fba.allocator();

    try std.testing.expectError(error.OutOfMemory, commands.execute(&gs, .{ .ship_stock = .{ .part_key = "armor", .quantity = 10, .from = .{ .hq = far }, .to = .{ .hq = home } } }));
    try std.testing.expectEqual(funds_before, gs.hqs.getPtr(far).?.funds);
    try std.testing.expectEqual(stock_before, gs.stockCount(.{ .hq = far }, "armor"));
    try std.testing.expectEqual(orders_before, gs.part_orders.items.len);
}

test "a shipment the payer cannot afford uses no link capacity" {
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7501 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const home = gs.hqs.keys()[0];
    const far = try founding.foundHq(&gs, "Frontier", .field, "alkaid");
    try gs.hq_links.append(gs.allocator(), .{ .a = home, .b = far, .level = 1, .established_day = 0 });
    // The shipment is paid from the sending HQ's treasury, which is empty.
    try gs.addStock(.{ .hq = far }, "armor", 10);
    gs.hqs.getPtr(far).?.funds = 0;
    try std.testing.expectError(commands.Error.InsufficientTreasury, commands.execute(&gs, .{
        .ship_stock = .{ .part_key = "armor", .quantity = 10, .from = .{ .hq = far }, .to = .{ .hq = home } },
    }));
    try std.testing.expectEqual(@as(u32, 0), gs.hq_links.items[0].tons_this_week);
    try std.testing.expectEqual(@as(u32, 10), gs.stockCount(.{ .hq = far }, "armor"));
}
