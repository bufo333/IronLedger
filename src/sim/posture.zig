//! Company posture: the one cascade every screen, warning and refusal reads (ARCH §9.7).
//! MekHQ counterpart: none (§9.7 is this game's extension) (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const contract_mod = @import("../domain/contract.zig");
const force_mod = @import("../domain/force.zig");
const GameState = @import("state.zig").GameState;
const founding = @import("founding.zig");

/// Where a company stands (ARCH §9.7): the one cascade every screen,
/// warning and refusal reads. Contract first (en route, then on
/// station), then the road home, then a world it idles on, else home.
pub const CompanyPosture = union(enum) {
    home,
    en_route: *contract_mod.Contract,
    deployed: *contract_mod.Contract,
    returning: u32, // arrival day
    idle_afield: []const u8, // planet key
};

pub fn companyPosture(gs: *GameState, company: types.ForceId) CompanyPosture {
    if (gs.deploymentContract(company)) |c| return if (c.status == .transit) .{ .en_route = c } else .{ .deployed = c };
    const f = gs.forces.getPtr(company) orelse return .home;
    if (f.return_eta_day) |eta| return .{ .returning = eta };
    if (f.location_planet) |p| return .{ .idle_afield = p };
    return .home;
}

/// The world a company stands on (ARCH §9.7; docs/p5d-conflict-world-design.md
/// §K "Reach"): its deployment contract's world, en route (the destination)
/// or on station; else the world it idles on; else its home HQ's world. A
/// company returning home stands on its home HQ's world, because
/// `contract_control` clears `location_planet` when it starts home. Null
/// only when it has no home HQ. The one company-position rule: transfer
/// days and news reach (`news.newsReach`) read it.
pub fn companyWorld(gs: *GameState, company: types.ForceId) ?[]const u8 {
    if (gs.deploymentContract(company)) |c| return c.planet_key;
    if (gs.force(company)) |f| if (f.location_planet) |p| return p;
    return if (gs.hqs.getPtr(gs.homeHqFor(company))) |h| h.planet_key else null;
}

/// Is the company physically at its home HQ (not deployed, not idling
/// on a contract world, not travelling)?
pub fn isCompanyHome(gs: *GameState, company: types.ForceId) bool {
    return companyPosture(gs, company) == .home;
}

/// Out on a contract (en route or on station). Not the opposite of
/// home: a company returning or idling afield is neither.
pub fn isCompanyDeployed(gs: *GameState, company: types.ForceId) bool {
    return gs.deploymentContract(company) != null;
}

test "company posture is one cascade: contract, then the road home, then a world, else home" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    const home = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var co: types.ForceId = .none;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        co = e.value_ptr.id;
    };
    const home_world = gs.hqs.get(home).?.planet_key;
    try std.testing.expect(!std.mem.eql(u8, home_world, "galatea") and !std.mem.eql(u8, home_world, "skye"));
    try std.testing.expect(companyPosture(&gs, co) == .home);
    try std.testing.expect(isCompanyHome(&gs, co) and !isCompanyDeployed(&gs, co));
    try std.testing.expectEqualStrings(home_world, companyWorld(&gs, co).?);
    const f = gs.forces.getPtr(co).?;
    f.location_planet = "galatea";
    try std.testing.expect(companyPosture(&gs, co) == .idle_afield);
    try std.testing.expect(!isCompanyHome(&gs, co) and !isCompanyDeployed(&gs, co));
    try std.testing.expectEqualStrings("galatea", companyWorld(&gs, co).?);
    // On the road home the company has left its world (`contract_control`
    // clears it) and stands on its home HQ's.
    f.location_planet = null;
    f.return_eta_day = 40;
    try std.testing.expect(companyPosture(&gs, co) == .returning);
    try std.testing.expectEqual(@as(u32, 40), companyPosture(&gs, co).returning);
    try std.testing.expectEqualStrings(home_world, companyWorld(&gs, co).?);
    f.return_eta_day = null;
    // A contract it runs puts it on the contract's world, en route (the
    // destination) and on station, ahead of the world it idles on.
    f.location_planet = "galatea";
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "skye", .terms = .{ .length_months = 6, .base_pay_month = 100_000 }, .status = .transit, .assigned_company = co });
    try std.testing.expect(companyPosture(&gs, co) == .en_route);
    try std.testing.expectEqualStrings("skye", companyWorld(&gs, co).?);
    gs.contracts.getPtr(cid).?.status = .active;
    try std.testing.expect(companyPosture(&gs, co) == .deployed);
    try std.testing.expectEqualStrings("skye", companyWorld(&gs, co).?);
}

test "posture x sites.siteForForce: siteForForce returns company site iff !isCompanyHome" {
    const sites = @import("sites.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Bravo");
    var co: types.ForceId = .none;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        co = e.value_ptr.id;
    };
    // home: siteForForce returns the home site (not .{ .company = co })
    try std.testing.expect(isCompanyHome(&gs, co));
    const home_site = sites.siteForForce(&gs, co);
    try std.testing.expect(home_site != .company);

    // idle_afield: siteForForce returns .{ .company = co }
    const f = gs.forces.getPtr(co).?;
    f.location_planet = "galatea";
    try std.testing.expect(!isCompanyHome(&gs, co));
    const afield_site = sites.siteForForce(&gs, co);
    try std.testing.expectEqual(types.Site{ .company = co }, afield_site);

    // returning: siteForForce returns .{ .company = co }
    f.return_eta_day = 40;
    try std.testing.expect(!isCompanyHome(&gs, co));
    const ret_site = sites.siteForForce(&gs, co);
    try std.testing.expectEqual(types.Site{ .company = co }, ret_site);
}
