//! Replenishing conventional hull offers for site market boards (ARCH §9.8).
//! MekHQ counterpart: `UnitMarket`; vehicles and aerospace fighters use the
//! verified conventional catalogue rather than faction manufacturing pools.

const std = @import("std");
const types = @import("../domain/types.zig");
const chassis = @import("../domain/chassis.zig");
const part = @import("../domain/part.zig");
const unit = @import("../domain/unit.zig");
const market = @import("../econ/market.zig");
const tuning = @import("../domain/tuning.zig").t;
const GameState = @import("state.zig").GameState;

/// Select and append one verified conventional listing. All `.market` draws,
/// list capacity, and listing facts are prepared before the board or ID changes.
pub fn appendOffer(gs: *GameState, hq: types.HqId, industry: u8, availability_facility: u8, kind: unit.UnitKind) !bool {
    std.debug.assert(kind == .vehicle or kind == .aerospace);
    var staged_rng = gs.rng;
    var buffer: [32]*const chassis.Chassis = undefined;
    const pool = chassis.conventionalMarketPool(kind, gs.clock.date.year, &buffer);
    if (pool.len == 0) return false;
    const design = pool[staged_rng.random(.market).uintLessThan(usize, pool.len)];
    if (!market.listingAppears(&staged_rng, design.rarity, industry, availability_facility, 0, .market)) {
        gs.rng = staged_rng;
        return false;
    }
    const condition = market.rollHullCondition(&staged_rng, .market);
    const price_roll = market.priceRollBp(&staged_rng, .market);
    var weapon_value: types.CBills = 0;
    var weapon_count: types.CBills = 0;
    for (design.loadout) |slot| if (slot.class == .weapon) {
        weapon_value += part.cost(slot.part);
        weapon_count += 1;
    };
    const average_weapon = if (weapon_count > 0) @divTrunc(weapon_value, weapon_count) else 50_000;
    const expires_day = gs.clock.day_index + tuning.market.offer_days_base + @as(u32, staged_rng.roll2d6(.market)) * tuning.market.offer_days_per_pip;
    try gs.market_listings.ensureUnusedCapacity(gs.allocator(), 1);

    gs.market_listings.appendAssumeCapacity(.{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = design.key,
        .rarity = design.rarity,
        .price = market.hullPrice(design.cost, average_weapon, condition, price_roll),
        .listed_day = gs.clock.day_index,
        .expires_day = expires_day,
        .condition = condition,
        .hq = hq,
    });
    gs.next_listing_id += 1;
    gs.rng = staged_rng;
    return true;
}

test "conventional offers use only verified pool entries and no backing hull instance" {
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 812 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
    const hq = gs.seat();
    const before_hulls = gs.hull_instances.count();
    _ = try appendOffer(&gs, hq, 10, 10, .vehicle);
    _ = try appendOffer(&gs, hq, 10, 10, .aerospace);
    try std.testing.expectEqual(before_hulls, gs.hull_instances.count());
    for (gs.market_listings.items) |listing| {
        const design = chassis.find(listing.item_key).?;
        try std.testing.expect(design.kind == .vehicle or design.kind == .aerospace);
        try std.testing.expect(chassis.conventionalMarketEligible(design, gs.clock.date.year));
        try std.testing.expectEqual(types.HullInstanceId.none, listing.hull_instance_id);
    }
}

test "conventional offer preparation is failure-atomic" {
    const digest = @import("digest.zig");
    const founding = @import("founding.zig");
    var seed: u64 = 1;
    while (true) : (seed += 1) {
        var probe = GameState.init(std.testing.allocator, .{ .seed = seed });
        defer probe.deinit();
        _ = try founding.createCommander(&probe, "T", .LC, .quartermaster);
        if (try appendOffer(&probe, probe.seat(), 10, 10, .vehicle)) break;
    }

    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var gs = GameState.init(outer.allocator(), .{ .seed = seed });
        _ = try founding.createCommander(&gs, "T", .LC, .quartermaster);
        const before = digest.stateHash(&gs);
        gs.arena.state.used_list = null;
        gs.arena.state.free_list = null;
        var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = fail_index });
        gs.arena.child_allocator = failing.allocator();
        if (appendOffer(&gs, gs.seat(), 10, 10, .vehicle)) |listed| {
            try std.testing.expect(listed);
            try std.testing.expect(digest.stateHash(&gs) != before);
            gs.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            gs.deinit();
        }
    }
}
