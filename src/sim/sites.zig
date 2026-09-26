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
const GameState = @import("state.zig").GameState;

/// Where a force draws supplies from: its own field stores while away
/// from home, its home warehouse otherwise.
pub fn siteForForce(gs: *GameState, force_id: types.ForceId) types.Site {
    const co = gs.companyOf(force_id);
    if (co != .none and !gs.isCompanyHome(co)) return .{ .company = co };
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

test "order_part is refused over the site's free tons and accepted at the limit" {
    const commands = @import("commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq_id = gs.hqs.keys()[0];
    gs.hqs.values()[0].funds = 100_000_000;
    const site: types.Site = .{ .hq = hq_id };

    const free = siteFreeTons(&gs, site);
    try std.testing.expectError(commands.Error.StorageFull, commands.execute(&gs, .{
        .order_part = .{ .part_key = "provisions", .quantity = free + 1 },
    }));

    // Exactly the free tonnage fits: the room check does not refuse it.
    _ = try commands.execute(&gs, .{ .order_part = .{ .part_key = "provisions", .quantity = free } });
    try std.testing.expect(siteTons(&gs, site) <= siteCapacityTons(&gs, site).?);
}
