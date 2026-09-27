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

test "order_part is refused over the site's free tons and accepted at the limit" {
    const commands = @import("commands.zig");
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
