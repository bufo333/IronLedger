//! Founding: commander creation and HQ setup (ARCH §4).
//! MekHQ counterpart: `Campaign.java` initial setup; our version separates
//! founding from the state it operates on.

const std = @import("std");
const tuning = @import("../domain/tuning.zig").t;
const types = @import("../domain/types.zig");
const person_mod = @import("../domain/person.zig");
const commander_mod = @import("../domain/commander.zig");
const planet_mod = @import("../domain/planet.zig");
const hq_mod = @import("../domain/hq.zig");
const part_mod = @import("../domain/part.zig");
const GameState = @import("state.zig").GameState;
const personnel = @import("personnel.zig");
const hq_ops = @import("hq_ops.zig");
const treasury = @import("treasury.zig");

pub const CreateCommanderError = error{ CommanderExists, NoHomeWorld } || std.mem.Allocator.Error;

/// Character creation: the commander's origin picks the starter world
/// (weighted-random in their faction's space) and stands up the starter
/// regional HQ there with modest level-1 facilities.
pub fn createCommander(
    gs: *GameState,
    name: []const u8,
    origin: commander_mod.Faction,
    profession: commander_mod.Profession,
) CreateCommanderError!types.HqId {
    if (gs.commander != null) return error.CommanderExists;
    const world = planet_mod.weightedPickByFaction(&gs.rng, .generation, origin.key()) orelse return error.NoHomeWorld;

    gs.commander = .{
        .name = try gs.allocator().dupe(u8, name),
        .origin = origin,
        .profession = profession,
    };

    const id: types.HqId = @enumFromInt(gs.next_hq_id);
    gs.next_hq_id += 1;
    var hq: hq_mod.Hq = .{
        .id = id,
        .name = try std.fmt.allocPrint(gs.allocator(), "{s} Regional HQ", .{world.name}),
        .tier = .regional,
        .planet_key = world.key,
        .monthly_upkeep = hq_mod.HqTier.regional.monthlyUpkeep(),
    };
    const starter_facilities = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .hospital, .mess, .comms, .spaceport, .hiring_hall, .training_ground };
    for (starter_facilities) |kind| {
        try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
    }
    const req = hq.staffRequired();
    try gs.hqs.put(gs.allocator(), id, hq);

    // The back office is people: recruit the starter HQ's
    // staff to requirement and post them. Their payroll is the tail.
    const staff_plan = [_]struct { person_mod.Role, u32 }{
        .{ .admin_command, req.admin },                           .{ .admin_logistics, req.logistics / 2 },
        .{ .admin_transport, req.logistics - req.logistics / 2 }, .{ .admin_hr, req.hr },
        .{ .admin_finance, req.finance },
    };
    for (staff_plan) |entry| {
        for (0..entry[1]) |_| {
            const pid = try personnel.recruitGenerated(gs, entry[0], id, .generation);
            gs.person(pid).?.posted_hq = id;
        }
    }
    hq_ops.refreshHqStaffing(gs);

    // Founding capital: the HQ opens with its own operating treasury,
    // handed over on-site (no courier).
    treasury.transferFunds(gs, .outfit, .{ .hq = id }, tuning.hq.founding_funds, 0) catch |err| switch (err) {
        // An outfit that cannot cover the founding capital opens the HQ
        // with an empty treasury.
        error.InsufficientTreasury => {},
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Standing defaults the player can clear, so a hands-off outfit keeps
    // its HQ solvent and fed: the outfit tops the HQ up on payday, and
    // the warehouse keeps provisions stocked.
    try gs.policies.append(gs.allocator(), .{ .entity = .{ .hq = id }, .floor = tuning.finance.hq_policy_floor, .monthly_cap = tuning.finance.hq_policy_cap });
    try gs.stock_policies.append(gs.allocator(), .{ .hq = id, .part_key = "provisions", .min = tuning.generation.provisions_keep_min, .target = tuning.generation.provisions_keep_target });

    // A modestly stocked warehouse to start.
    const site: types.Site = .{ .hq = id };
    const g = tuning.generation;
    try gs.addStock(site, "provisions", g.starter_provisions);
    try gs.addStock(site, "medical_supplies", g.starter_medical);
    try gs.addStock(site, "armor", g.starter_armor);
    for (part_mod.component_keys) |key| try gs.addStock(site, key, g.starter_components_each);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, g.starter_munitions_each);
    return id;
}

// ------------------------------------- the HQ network

pub const FoundError = error{ UnknownPlanet, NotReachable } || std.mem.Allocator.Error;

/// Stand up an HQ on a world. Field HQs open with a bay, a warehouse
/// and a mess; regional ones add comms, a spaceport, a hospital and a
/// hiring hall. Staffing is the player's problem from day one.
pub fn foundHq(gs: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!types.HqId {
    const hq = try prepareHq(gs, name, tier, planet_key);
    try gs.hqs.ensureUnusedCapacity(gs.allocator(), 1);
    return gs.commitHq(hq);
}

/// A new HQ with every allocation done but no id and nothing on the
/// books; `commitHq` registers it.
pub fn prepareHq(gs: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!hq_mod.Hq {
    const world = planet_mod.find(planet_key) orelse return error.UnknownPlanet;
    var hq: hq_mod.Hq = .{
        .id = .none,
        .name = try gs.allocator().dupe(u8, name),
        .tier = tier,
        .planet_key = world.key,
        .monthly_upkeep = tier.monthlyUpkeep(),
    };
    const base = [_]hq_mod.FacilityKind{ .mek_bay, .warehouse, .mess };
    for (base) |kind| try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
    if (tier != .field) {
        const more = [_]hq_mod.FacilityKind{ .comms, .spaceport, .hospital, .hiring_hall, .training_ground };
        for (more) |kind| try hq.facilities.append(gs.allocator(), .{ .kind = kind, .level = 1 });
    }
    return hq;
}

test "foundHq produces an HQ with exactly the facilities from prepareHq" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8101 });
    defer gs.deinit();
    _ = try createCommander(&gs, "T", .LC, .line_officer);

    const prepared_field = try prepareHq(&gs, "Frontier", .field, "alkaid");
    const field_id = try foundHq(&gs, "Frontier", .field, "alkaid");
    const actual_field = gs.hqs.getPtr(field_id).?;
    try std.testing.expectEqual(prepared_field.facilities.items.len, actual_field.facilities.items.len);
    for (prepared_field.facilities.items, actual_field.facilities.items) |exp, got| {
        try std.testing.expectEqual(exp.kind, got.kind);
        try std.testing.expectEqual(exp.level, got.level);
    }

    const prepared_regional = try prepareHq(&gs, "Second", .regional, "skye");
    const regional_id = try foundHq(&gs, "Second", .regional, "skye");
    const actual_regional = gs.hqs.getPtr(regional_id).?;
    try std.testing.expectEqual(prepared_regional.facilities.items.len, actual_regional.facilities.items.len);
    for (prepared_regional.facilities.items, actual_regional.facilities.items) |exp, got| {
        try std.testing.expectEqual(exp.kind, got.kind);
        try std.testing.expectEqual(exp.level, got.level);
    }
}

test "createCommander yields the same commander, HQ, staff and stock regardless of clock year" {
    // execCreateCommander sets the start year before calling createCommander;
    // this test verifies that the founding output is independent of the
    // clock's year value so the two paths always agree.
    var gs1 = GameState.init(std.testing.allocator, .{ .seed = 8102 });
    defer gs1.deinit();
    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 8102 });
    defer gs2.deinit();

    _ = try createCommander(&gs1, "T", .LC, .quartermaster);

    // Reproduce what execCreateCommander does: set the year, then found.
    gs2.clock.date.year = 3025;
    _ = try createCommander(&gs2, "T", .LC, .quartermaster);

    // Commander fields must match.
    try std.testing.expect(gs1.commander != null);
    try std.testing.expect(gs2.commander != null);
    try std.testing.expectEqualStrings(gs1.commander.?.name, gs2.commander.?.name);
    try std.testing.expectEqual(gs1.commander.?.origin, gs2.commander.?.origin);
    try std.testing.expectEqual(gs1.commander.?.profession, gs2.commander.?.profession);

    // Each state has exactly one HQ; it must land on the same planet.
    try std.testing.expectEqual(@as(usize, 1), gs1.hqs.count());
    try std.testing.expectEqual(@as(usize, 1), gs2.hqs.count());
    const hq1 = gs1.hqs.values()[0];
    const hq2 = gs2.hqs.values()[0];
    try std.testing.expectEqualStrings(hq1.planet_key, hq2.planet_key);
    try std.testing.expectEqual(hq1.tier, hq2.tier);
    try std.testing.expectEqual(hq1.facilities.items.len, hq2.facilities.items.len);

    // Recruited staff count must match.
    try std.testing.expectEqual(gs1.people.count(), gs2.people.count());

    // Starter stock must match for every part family.
    const site1: types.Site = .{ .hq = gs1.hqs.keys()[0] };
    const site2: types.Site = .{ .hq = gs2.hqs.keys()[0] };
    for (part_mod.component_keys) |key| {
        try std.testing.expectEqual(gs1.stockCount(site1, key), gs2.stockCount(site2, key));
    }
    for (part_mod.munition_keys) |key| {
        try std.testing.expectEqual(gs1.stockCount(site1, key), gs2.stockCount(site2, key));
    }
}
