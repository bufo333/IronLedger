//! The HQ network (ARCH §9): founding HQs on worlds and assigning companies
//! to them within each HQ's capacity slots (§9.3). Registering a prepared
//! HQ under the next id, `GameState.commitHq`, stays with the state it
//! writes. The supply-line graph between HQs is `network.zig`. No MekHQ
//! counterpart: the HQ network is this game's extension
//! (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const hq_mod = @import("../domain/hq.zig");
const planet_mod = @import("../domain/planet.zig");
const GameState = @import("state.zig").GameState;

pub const FoundError = error{ UnknownPlanet, NotReachable } || std.mem.Allocator.Error;

/// Stand up an HQ on a world. Field HQs open with a bay, a warehouse and a
/// mess; regional ones add comms, a spaceport, a hospital and a hiring
/// hall. Staffing is the player's problem from day one.
pub fn foundHq(gs: *GameState, name: []const u8, tier: hq_mod.HqTier, planet_key: []const u8) FoundError!types.HqId {
    const hq = try prepareHq(gs, name, tier, planet_key);
    try gs.hqs.ensureUnusedCapacity(gs.allocator(), 1);
    return gs.commitHq(hq);
}

/// A new HQ with every allocation done but no id and nothing on the books;
/// `GameState.commitHq` registers it.
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

/// Combat companies currently assigned to an HQ.
pub fn companiesAtHq(gs: *GameState, hq_id: types.HqId) u32 {
    var n: u32 = 0;
    var it = gs.forces.iterator();
    while (it.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon == .company and f.supplying_hq == hq_id) n += 1;
    }
    return n;
}

/// Air wings of the companies assigned to an HQ.
pub fn airCompaniesAtHq(gs: *GameState, hq_id: types.HqId) u32 {
    var n: u32 = 0;
    var it = gs.forces.iterator();
    while (it.next()) |entry| {
        const f = entry.value_ptr;
        if (f.echelon != .air_company) continue;
        const co = gs.forces.getPtr(f.parent) orelse continue;
        if (co.supplying_hq == hq_id) n += 1;
    }
    return n;
}

pub const AssignHqError = error{ UnknownForce, UnknownHq, NotACompany, CapacityFull, TooManyLances };

/// Assign a company to an HQ, enforcing the HQ's capacity slots (ARCH §9.3):
/// companies per HQ and lances per company.
pub fn assignCompanyToHq(gs: *GameState, company: types.ForceId, hq_id: types.HqId) AssignHqError!void {
    const f = gs.forces.getPtr(company) orelse return error.UnknownForce;
    if (f.echelon != .company) return error.NotACompany;
    const hq = gs.hqs.getPtr(hq_id) orelse return error.UnknownHq;
    const cap = hq.capacity();
    const already = companiesAtHq(gs, hq_id) - @intFromBool(f.supplying_hq == hq_id);
    if (already >= cap.combat_companies) return error.CapacityFull;
    if (gs.combatLancesOf(company) > cap.lances_per_company) return error.TooManyLances;
    f.supplying_hq = hq_id;
}

test "a field HQ opens smaller than a regional one; an unknown world is refused and nothing is founded" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7702 });
    defer gs.deinit();
    const field = try foundHq(&gs, "Forward", .field, "skye");
    const regional = try foundHq(&gs, "Seat", .regional, "alkaid");
    try std.testing.expect(gs.hqs.getPtr(regional).?.facilities.items.len > gs.hqs.getPtr(field).?.facilities.items.len);
    try std.testing.expectError(error.UnknownPlanet, foundHq(&gs, "Nowhere", .field, "no_such_world"));
    try std.testing.expectEqual(@as(usize, 2), gs.hqs.count());
}

test "an HQ takes companies up to its slots, and a company already there does not count twice" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7703 });
    defer gs.deinit();
    const hq = try foundHq(&gs, "Forward", .field, "skye");
    const slots = gs.hqs.getPtr(hq).?.capacity().combat_companies;
    var i: u32 = 0;
    while (i < slots) : (i += 1) {
        const co = try gs.createForce("Company", .company, .none);
        try assignCompanyToHq(&gs, co, hq);
        try assignCompanyToHq(&gs, co, hq); // re-assigning the same company is not a new slot
    }
    try std.testing.expectEqual(slots, companiesAtHq(&gs, hq));
    const extra = try gs.createForce("One too many", .company, .none);
    try std.testing.expectError(error.CapacityFull, assignCompanyToHq(&gs, extra, hq));
    try std.testing.expectEqual(slots, companiesAtHq(&gs, hq));
}
