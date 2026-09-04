//! Logistics: star-map transit, shipments, supply consumption.
//! Extends MekHQ's `Quartermaster`/`procurement` with a real supply network
//! (ARCH §9): HQs ship parts/ammo/medical/provisions to deployed companies
//! over jump routes with real delays.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");

/// Standard JumpShip hop: ~30 LY, then recharge at the jump point.
pub const ly_per_jump = tuning.logistics.ly_per_jump;
pub const recharge_days = tuning.logistics.recharge_days; // solar sail recharge (varies by star; Stage 9)
pub const burn_days_default = tuning.logistics.burn_days; // in-system transit, jump point ↔ planet

/// Transit time in days for a route of `jumps` hops. First-cut model:
/// burn out + (jumps × recharge, pipelining the first) + burn in.
/// Owned command-circuit or lithium-fusion batteries reduce this (Stage 9).
pub fn transitDays(jumps: u32) u32 {
    if (jumps == 0) return burn_days_default; // same system
    return burn_days_default + (jumps - 1) * recharge_days + burn_days_default;
}

pub const Shipment = struct {
    origin_hq: types.HqId,
    dest_company: types.ForceId,
    class: types.SupplyClass,
    quantity: u32,
    depart_day: u32,
    eta_day: u32,
    freight_cost: types.CBills,
};

// ---------------------------------------------------------------- routes
// The HQ network is a graph (ARCH §9.5): HQ nodes, player-established supply
// links as edges. A route is a sequence of hops; every hop multiplies delay
// and cost — unless its link and pass-through HQ are upgraded into a hub.

/// One leg of a route: the link travelled, and (for intermediate hops) the
/// pass-through HQ's warehouse/spaceport levels, which set handling quality.
pub const Hop = struct {
    jumps: u32 = 1, // jump legs on this hop
    link_level: u8 = 1, // 1 charter, 2 scheduled, 3+ dedicated jumpship
    via_warehouse: u8 = 0, // pass-through HQ facility levels (0 = raw stopover)
    via_spaceport: u8 = 0,
};

/// Per-hop delay multiplier, basis points: ×1.5 for charter down to ×1.0
/// for a dedicated line.
pub fn hopDelayMultBp(link_level: u8) types.Bp {
    return @max(10_000, tuning.logistics.charter_delay_bp - tuning.logistics.delay_step_per_level_bp * @as(types.Bp, link_level));
}

/// Per-hop freight cost multiplier: ×1.4 raw, reduced by the pass-through
/// HQ's warehouse+spaceport levels (a real hub charges less friction).
pub fn hopCostMultBp(via_warehouse: u8, via_spaceport: u8) types.Bp {
    const hub: types.Bp = @as(types.Bp, via_warehouse) + via_spaceport;
    return @max(10_000, tuning.logistics.raw_hop_cost_bp - tuning.logistics.hub_discount_per_level_bp * hub);
}

/// Transit charter multiplier when the outfit's own ships lift part of a
/// company (Stage 12.15): the carried share still pays the jumpship collar
/// (half the charter) unless an owned jumpship makes the run too.
pub fn transitFreightBp(covered_bp: types.Bp, own_jumpship: bool) types.Bp {
    const covered = @min(covered_bp, 10_000);
    const collar_bp: types.Bp = if (own_jumpship) 0 else tuning.logistics.collar_charter_bp;
    return 10_000 - covered + @divTrunc(covered * collar_bp, 10_000);
}

/// Per-hop delay multiplier on a dedicated line: your own jumpship, no
/// waiting for a charter. Freight on that hop is the ship's carry cost,
/// already billed monthly.
pub const dedicated_line_cost_bp: types.Bp = tuning.logistics.dedicated_line_cost_bp;

/// Total door-to-door days for a route.
pub fn routeDelayDays(hops: []const Hop) u32 {
    var total: u32 = 0;
    for (hops) |h| {
        const base: u64 = transitDays(h.jumps);
        total += @intCast(@divTrunc(base * @as(u64, @intCast(hopDelayMultBp(h.link_level))), 10_000));
    }
    return total;
}

/// Combined freight-cost multiplier for a route (hop multipliers compound).
pub fn routeCostMultBp(hops: []const Hop) types.Bp {
    var mult: types.Bp = 10_000;
    for (hops) |h| {
        mult = @divTrunc(mult * hopCostMultBp(h.via_warehouse, h.via_spaceport), 10_000);
        if (h.link_level >= 3) mult = @divTrunc(mult * dedicated_line_cost_bp, 10_000);
    }
    return mult;
}

/// Supply units/week a link level can move.
pub fn linkThroughputPerWeek(link_level: u8) u32 {
    return @as(u32, link_level) * tuning.logistics.throughput_per_level;
}

/// A route moves only what its weakest hop can carry: stack two companies
/// behind one charter link and both starve.
pub fn routeThroughputPerWeek(hops: []const Hop) u32 {
    var min: u32 = std.math.maxInt(u32);
    for (hops) |h| min = @min(min, linkThroughputPerWeek(h.link_level));
    return if (hops.len == 0) 0 else min;
}

// ------------------------------------------- out-of-influence operations

/// Price multiplier for buying supplies locally beyond every influence ring
/// (ARCH §9.6): ×2.0 base +0.5 per 30 LY beyond, capped ×4.0, eased by the
/// planet's industry rating. Expensive but viable — the valve that prevents
/// a death spiral, itemized on the P&L as 'local_supplies'.
pub fn localPurchaseMultBp(ly_beyond_ring: u32, planet_industry: u8) types.Bp {
    const l = tuning.logistics;
    const base: types.Bp = l.local_base_bp + l.local_step_bp * @as(types.Bp, ly_beyond_ring / l.local_step_ly);
    const eased = base - l.local_industry_ease_bp * @as(types.Bp, planet_industry);
    return std.math.clamp(eased, l.local_base_bp, l.local_max_bp);
}

/// Daily consumption per deployed company (Stage 5 tunes per roster size and
/// contract intensity). Units: abstract supply points.
pub const daily_consumption = std.enums.EnumFieldStruct(types.SupplyClass, u32, null){
    .parts = 2,
    .ammo = 1, // combat multiplies this
    .medical = 1,
    .provisions = 4,
    .personnel = 0,
};

test "transit time scales with jumps" {
    try std.testing.expectEqual(@as(u32, 5), transitDays(0));
    try std.testing.expectEqual(@as(u32, 10), transitDays(1));
    try std.testing.expectEqual(@as(u32, 24), transitDays(3));
}

test "upgrading an intermediary HQ makes routes through it faster and cheaper" {
    // Anchorage → (via un-upgraded frontier HQ) → deployed company, 2 hops.
    const raw = [_]Hop{
        .{ .jumps = 2, .link_level = 1 },
        .{ .jumps = 1, .link_level = 1, .via_warehouse = 0, .via_spaceport = 0 },
    };
    // Same topology after investing in the intermediary + scheduled links.
    const hub = [_]Hop{
        .{ .jumps = 2, .link_level = 3 },
        .{ .jumps = 1, .link_level = 3, .via_warehouse = 4, .via_spaceport = 3 },
    };
    try std.testing.expect(routeDelayDays(&hub) < routeDelayDays(&raw));
    try std.testing.expect(routeCostMultBp(&hub) < routeCostMultBp(&raw));
    // A single direct hop beats both.
    const direct = [_]Hop{.{ .jumps = 3, .link_level = 3 }};
    try std.testing.expect(routeDelayDays(&direct) < routeDelayDays(&hub));
}

test "throughput is bottlenecked by the weakest hop" {
    const hops = [_]Hop{
        .{ .link_level = 3 },
        .{ .link_level = 1 }, // the charter link everyone forgot to upgrade
        .{ .link_level = 2 },
    };
    try std.testing.expectEqual(@as(u32, 10), routeThroughputPerWeek(&hops));
}

test "local purchases: expensive but viable, capped, eased by industry" {
    try std.testing.expectEqual(@as(types.Bp, 20_000), localPurchaseMultBp(10, 0)); // just past the ring: ×2
    try std.testing.expectEqual(@as(types.Bp, 25_000), localPurchaseMultBp(35, 0)); // one jump beyond: ×2.5
    try std.testing.expectEqual(@as(types.Bp, 40_000), localPurchaseMultBp(300, 0)); // deep space: capped ×4
    try std.testing.expect(localPurchaseMultBp(65, 3) < localPurchaseMultBp(65, 0)); // industry helps
}

test "own lift cuts the transit charter: dropship halves it, jumpship waives it" {
    try std.testing.expectEqual(@as(types.Bp, 10_000), transitFreightBp(0, false));
    try std.testing.expectEqual(@as(types.Bp, 5_000), transitFreightBp(10_000, false));
    try std.testing.expectEqual(@as(types.Bp, 0), transitFreightBp(10_000, true));
    try std.testing.expectEqual(@as(types.Bp, 7_500), transitFreightBp(5_000, false));
    const charter = [_]Hop{.{ .link_level = 1 }};
    const dedicated = [_]Hop{.{ .link_level = 3 }};
    try std.testing.expect(routeCostMultBp(&dedicated) < routeCostMultBp(&charter));
}
