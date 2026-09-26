//! Company posture: the one cascade every screen, warning and refusal reads (ARCH §9.7).
//! MekHQ counterpart: none (§9.7 is this game's extension).

const std = @import("std");
const types = @import("../domain/types.zig");
const contract_mod = @import("../domain/contract.zig");
const force_mod = @import("../domain/force.zig");
const GameState = @import("state.zig").GameState;

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
    _ = try gs.createCommander("T", .LC, .line_officer);
    _ = try @import("starter_company.zig").generateInto(&gs, "Alpha");
    var co: types.ForceId = .none;
    var it = gs.forces.iterator();
    while (it.next()) |e| if (e.value_ptr.echelon == .company) {
        co = e.value_ptr.id;
    };
    try std.testing.expect(companyPosture(&gs, co) == .home);
    try std.testing.expect(isCompanyHome(&gs, co) and !isCompanyDeployed(&gs, co));
    const f = gs.forces.getPtr(co).?;
    f.location_planet = "galatea";
    try std.testing.expect(companyPosture(&gs, co) == .idle_afield);
    try std.testing.expect(!isCompanyHome(&gs, co) and !isCompanyDeployed(&gs, co));
    f.return_eta_day = 40;
    try std.testing.expect(companyPosture(&gs, co) == .returning);
    try std.testing.expectEqual(@as(u32, 40), companyPosture(&gs, co).returning);
}

test "posture x sites.siteForForce: siteForForce returns company site iff !isCompanyHome" {
    const sites = @import("sites.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    _ = try gs.createCommander("T", .LC, .line_officer);
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
