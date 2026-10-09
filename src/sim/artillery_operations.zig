//! Artillery physical capabilities and whole-bin ammunition loading.
//! No MekHQ counterpart: project operational policy (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const rules = @import("../domain/artillery_operations.zig");
const dom = @import("../domain/artillery_formation.zig");
const GameState = @import("state.zig").GameState;
const commands = @import("commands.zig");
const posture = @import("posture.zig");
const crew = @import("artillery_crew.zig");
const sites = @import("sites.zig");
const personnel = @import("personnel.zig");
const hq_ops = @import("hq_ops.zig");

/// Actual stock/facility site, absent during company/freight travel and sale.
/// Source: operations design, Physical location and complete capabilities.
pub fn operationSite(gs: *GameState, f: *const dom.Formation) ?types.Site {
    const hull = gs.hull_instances.get(f.hull) orelse return null;
    if (hull.owner != .player or hull.status != .active) return null;
    return switch (f.placement) {
        .hq_pool => |hq| if (gs.hqs.contains(hq)) .{ .hq = hq } else null,
        .company => |company| switch (posture.companyPosture(gs, company)) {
            .home => if (gs.hqs.contains(gs.homeHqFor(company))) .{ .hq = gs.homeHqFor(company) } else null,
            .deployed, .idle_afield => .{ .company = company },
            .en_route, .returning => null,
        },
        .freight, .sold => null,
    };
}

/// Queued and active jobs equally exclude all field capabilities and placement.
pub fn hasJob(gs: *const GameState, formation: types.ArtilleryFormationId) bool {
    for (gs.bay_jobs.items) |j| if (j.artillery == formation) return true;
    return false;
}

/// Local qualified available mechanic and physical active carrier; does not
/// require combat crew, intact chassis, loaded ammo or fresh maintenance.
pub fn serviceCapability(gs: *GameState, f: *const dom.Formation) ?types.Site {
    const site = operationSite(gs, f) orelse return null;
    const p = gs.person(f.tech) orelse return null;
    crew.techEligibility(gs, f, p) catch |err| switch (err) {
        error.Unavailable, error.ArtilleryUnqualified, error.ArtilleryPersonSeated, error.ArtilleryPersonAbsent, error.ArtilleryNoServiceSite => return null,
        else => unreachable,
    };
    return site;
}

/// Complete primary-gun firing readiness for combat consumers. No battle effect
/// is applied here. Source: operations design, Physical location and complete capabilities.
pub fn operationalReadiness(gs: *GameState, f: *const dom.Formation) bool {
    if (f.placement != .company or hasJob(gs, f.id) or f.armor_pct == 0) return false;
    const site = serviceCapability(gs, f) orelse return false;
    for ([_]rules.Slot{ .chassis, .main_gun, .communications }) |s| if (f.slots[@intFromEnum(s)].condition != .ok) return false;
    const serviced = f.last_maintenance_day orelse return false;
    if (serviced > gs.clock.day_index or gs.clock.day_index - serviced > rules.maintenance_age_days) return false;
    for (rules.seats, f.crew) |seat, id| {
        const p = gs.person(id) orelse return false;
        if (!personnel.availableForDuty(p, gs.clock.day_index) or !rules.qualified(p, seat)) return false;
        if (gs.companyOf(p.assigned_force) != f.placement.company or !crew.personPresent(gs, p, site)) return false;
    }
    for (rules.descriptors, f.slots) |d, s| if (d.family == .long_tom and s.condition == .ok and s.rounds > 0) return true;
    return false;
}

pub const ReloadQuote = struct {
    formation: types.ArtilleryFormationId,
    site: types.Site,
    family: rules.Family,
    packages: u32,
    bins: [rules.descriptors.len]bool,
};

/// Pure whole-batch quote: intact empty bins only; partial bins retain rounds.
/// Source: operations design, Ammunition and supply policy. No RNG or hours.
pub fn reloadQuote(gs: *GameState, f: *const dom.Formation, family: rules.Family) commands.Error!ReloadQuote {
    if (hasJob(gs, f.id)) return error.ArtilleryBayJob;
    const site = serviceCapability(gs, f) orelse return error.ArtilleryNoMechanic;
    var q: ReloadQuote = .{ .formation = f.id, .site = site, .family = family, .packages = 0, .bins = @splat(false) };
    for (rules.descriptors, f.slots, 0..) |d, s, i| if (d.family == family and s.condition == .ok and s.rounds == 0) {
        q.bins[i] = true;
        q.packages += 1;
    };
    if (q.packages == 0) return error.ArtilleryNothingToReload;
    if (gs.stockCount(site, rules.packageKey(family)) < q.packages) return error.InsufficientStock;
    return q;
}

/// Consume quoted local packages and fill selected bins atomically; one prepared
/// stock batch and owned log precede the non-failing commit.
pub fn reload(gs: *GameState, request: @FieldType(commands.Command, "reload_artillery")) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(request.formation) orelse return error.NoSuchArtilleryFormation;
    const q = try reloadQuote(gs, f, request.family);
    var batch: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer batch.deinit(gs.scratch());
    try batch.put(gs.scratch(), rules.packageKey(q.family), q.packages);
    const log = try gs.prepareLog(.delivery, .{}, "[artillery] formation {d} loaded {d} sealed {s} package(s)", .{ @intFromEnum(f.id), q.packages, @tagName(q.family) });
    if (!sites.consumeStockBatch(gs, q.site, &batch)) unreachable;
    for (q.bins, rules.descriptors, 0..) |selected, d, i| if (selected) {
        f.slots[i].rounds = d.capacity_rounds;
    };
    gs.commitLog(log);
    return .{ .artillery_formation = f.id, .artillery_site = q.site, .artillery_packages = q.packages };
}

/// Validate persisted operations without demanding present availability: recovery,
/// training and company travel preserve references while suppressing capability.
pub fn validate(gs: *GameState) error{CorruptSave}!void {
    if (gs.last_artillery_service_day) |day| if (day > gs.clock.day_index) return error.CorruptSave;
    for (gs.artillery_formations.values()) |f| {
        if (f.armor_pct > dom.intact_condition_pct) return error.CorruptSave;
        if (f.last_maintenance_day) |day| if (day > gs.clock.day_index or day < f.acquisition_day) return error.CorruptSave;
        try rules.validateSlots(&f.slots);
        for (rules.seats, f.crew) |seat, id| {
            if (id == .none) continue;
            if (f.placement != .company or @intFromEnum(id) >= gs.next_person_id) return error.CorruptSave;
            const p = gs.person(id) orelse return error.CorruptSave;
            if (p.isGone() or !rules.qualified(p, seat) or gs.companyOf(p.assigned_force) != f.placement.company or p.posted_hq != .none or gs.pilotSeat(id) != .none) return error.CorruptSave;
            var count: u32 = 0;
            for (gs.artillery_formations.values()) |other| {
                for (other.crew) |occupant| if (occupant == id) {
                    count += 1;
                };
                if (other.tech == id) return error.CorruptSave;
            }
            for (gs.units.values()) |u| if (u.tech == id) return error.CorruptSave;
            if (count != 1) return error.CorruptSave;
        }
        if (f.tech != .none) {
            if (f.placement == .sold or f.placement == .freight or @intFromEnum(f.tech) >= gs.next_person_id) return error.CorruptSave;
            const p = gs.person(f.tech) orelse return error.CorruptSave;
            if (p.isGone() or p.role != .tech_mechanic or p.skill(.tech_mechanic) == null or crew.isSeated(gs, p.id)) return error.CorruptSave;
            if (f.placement == .company and (gs.companyOf(p.assigned_force) != f.placement.company or p.posted_hq != .none)) return error.CorruptSave;
        }
    }
    for (gs.bay_jobs.items, 0..) |job, index| {
        _ = try hq_ops.bayTarget(gs, &job);
        const conventional = job.kind == .depot_repair or job.kind == .reactivation or job.kind == .refit;
        if ((job.unit != .none) != conventional or (job.artillery != .none) != (job.kind == .artillery_depot_repair)) return error.CorruptSave;
        if (job.duration_days == 0 or job.cost < 0 or job.queued_day > gs.clock.day_index or (job.started_day != null) != (job.done_day != null)) return error.CorruptSave;
        if (job.started_day) |day| if (day < job.queued_day or day > gs.clock.day_index or job.done_day.? < day) return error.CorruptSave;
        if (job.artillery == .none) continue;
        const f = gs.artillery_formations.getPtr(job.artillery) orelse return error.CorruptSave;
        const site = operationSite(gs, f) orelse return error.CorruptSave;
        if (site != .hq or site.hq != job.hq) return error.CorruptSave;
        for (gs.bay_jobs.items[0..index]) |other| if (other.artillery == job.artillery) return error.CorruptSave;
    }
}

/// Complete attached fixture with explicit ordinary skills; tests may alter
/// availability, placement or magazines without manufacturing a Unit carrier.
pub fn fixtureForTest(gs: *GameState, attached: bool) !types.ArtilleryFormationId {
    const artillery = @import("artillery.zig");
    const home = try @import("founding.zig").createCommander(gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice() * 4;
    const bought = try artillery.buy(gs, .{ .hq = home, .offer = gs.artillery_offers.items[0].id });
    if (attached) {
        const co = try gs.createForce("Alpha", .company, .none);
        _ = try artillery.attach(gs, .{ .formation = bought.artillery_formation, .company = co });
        for (rules.seats) |seat| {
            const id = try gs.hirePerson(@tagName(seat), "Crew", .vehicle_crew);
            try gs.person(id).?.skills.put(gs.allocator(), rules.seatSkill(seat), 4);
            _ = try crew.assign(gs, .{ .formation = bought.artillery_formation, .seat = seat, .person = id });
        }
    }
    const tech = try gs.hirePerson("Local", "Mechanic", .tech_mechanic);
    try gs.person(tech).?.skills.put(gs.allocator(), .tech_mechanic, 4);
    _ = try crew.assignTech(gs, .{ .formation = bought.artillery_formation, .person = tech });
    return bought.artillery_formation;
}

test "readiness includes physical crew service condition magazines and maintenance age" {
    const artillery = @import("artillery.zig");
    const founding = @import("founding.zig");
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try fixtureForTest(&gs, true);
    const f = gs.artillery_formations.getPtr(id).?;
    const co = f.placement.company;
    const home = gs.seat();
    const far = try founding.foundHq(&gs, "Remote", .regional, "skye");
    try gs.addStock(.{ .hq = far }, rules.packageKey(.long_tom), 4);
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.InsufficientStock, reloadQuote(&gs, f, .long_tom));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try gs.addStock(.{ .hq = home }, rules.packageKey(.long_tom), 4);
    _ = try commands.execute(&gs, .{ .reload_artillery = .{ .formation = id, .family = .long_tom } });
    try std.testing.expect(!operationalReadiness(&gs, f));
    f.last_maintenance_day = 0;
    try std.testing.expect(operationalReadiness(&gs, f));
    for (rules.seats, f.crew) |seat, occupant| {
        const p = gs.person(occupant).?;
        try std.testing.expectEqual(seat, crew.operatingSeat(&gs, occupant).?.seat);
        p.status = .wounded;
        try validate(&gs);
        try std.testing.expect(!operationalReadiness(&gs, f));
        p.status = .active;
        p.leave_until_day = 1;
        try std.testing.expect(!operationalReadiness(&gs, f));
        p.leave_until_day = null;
        p.training = .{ .skill = rules.seatSkill(seat), .done_day = 1 };
        try std.testing.expect(!operationalReadiness(&gs, f));
        p.training = null;
        p.fatigue = 100;
        try std.testing.expect(!operationalReadiness(&gs, f));
        p.fatigue = 0;
    }
    gs.clock.day_index = rules.maintenance_age_days;
    try std.testing.expect(operationalReadiness(&gs, f));
    gs.clock.day_index += 1;
    try std.testing.expect(!operationalReadiness(&gs, f));
    f.last_maintenance_day = gs.clock.day_index;
    for ([_]rules.Slot{ .chassis, .main_gun, .communications }) |slot| {
        f.slots[@intFromEnum(slot)].condition = .damaged;
        try std.testing.expect(!operationalReadiness(&gs, f));
        f.slots[@intFromEnum(slot)].condition = .ok;
    }
    f.slots[@intFromEnum(rules.Slot.hitch)].condition = .destroyed;
    f.slots[@intFromEnum(rules.Slot.machine_gun_right_1)].condition = .missing;
    try std.testing.expect(operationalReadiness(&gs, f));
    gs.force(co).?.location_planet = "galatea";
    try std.testing.expectEqual(types.Site{ .company = co }, operationSite(&gs, f).?);
    try std.testing.expect(operationalReadiness(&gs, f));
    gs.force(co).?.return_eta_day = gs.clock.day_index + 10;
    try std.testing.expect(operationSite(&gs, f) == null);
    try std.testing.expect(!operationalReadiness(&gs, f));
    try validate(&gs);
    gs.force(co).?.return_eta_day = null;
    gs.force(co).?.location_planet = null;
    _ = try artillery.detach(&gs, id);
    try std.testing.expect(!operationalReadiness(&gs, f));
    try std.testing.expect(serviceCapability(&gs, f) == null);
    try std.testing.expectEqual(@as(u16, rules.long_tom_rounds_per_bin), f.slots[@intFromEnum(rules.Slot.long_tom_bin_1)].rounds);
}

test "whole-bin reload preserves partial rounds and refuses aggregate shortage unchanged" {
    const digest = @import("digest.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try fixtureForTest(&gs, false);
    const f = gs.artillery_formations.getPtr(id).?;
    const site = operationSite(&gs, f).?;
    f.slots[@intFromEnum(rules.Slot.long_tom_bin_1)].rounds = 3;
    f.slots[@intFromEnum(rules.Slot.long_tom_bin_3)].rounds = rules.long_tom_rounds_per_bin;
    try gs.addStock(site, rules.packageKey(.long_tom), 1);
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.InsufficientStock, commands.execute(&gs, .{ .reload_artillery = .{ .formation = id, .family = .long_tom } }));
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try gs.addStock(site, rules.packageKey(.long_tom), 1);
    const quote = try reloadQuote(&gs, f, .long_tom);
    const result = try commands.execute(&gs, .{ .reload_artillery = .{ .formation = id, .family = .long_tom } });
    try std.testing.expectEqual(quote.packages, result.artillery_packages);
    try std.testing.expectEqual(@as(u32, 2), result.artillery_packages);
    for ([_]rules.Slot{ .long_tom_bin_1, .long_tom_bin_2, .long_tom_bin_3, .long_tom_bin_4 }, [_]u16{ 3, 5, 5, 5 }) |slot, rounds| try std.testing.expectEqual(rounds, f.slots[@intFromEnum(slot)].rounds);
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(site, rules.packageKey(.long_tom)));
    try gs.addStock(site, rules.packageKey(.machine_gun), 2);
    f.slots[@intFromEnum(rules.Slot.machine_gun_bin)].rounds = 1;
    try std.testing.expectError(error.ArtilleryNothingToReload, reloadQuote(&gs, f, .machine_gun));
    f.slots[@intFromEnum(rules.Slot.machine_gun_bin)] = .{ .condition = .damaged };
    try std.testing.expectError(error.ArtilleryNothingToReload, reloadQuote(&gs, f, .machine_gun));
    f.slots[@intFromEnum(rules.Slot.machine_gun_bin)].condition = .ok;
    _ = try reload(&gs, .{ .formation = id, .family = .machine_gun });
    try std.testing.expectEqual(rules.mg_rounds_per_bin, f.slots[@intFromEnum(rules.Slot.machine_gun_bin)].rounds);
    try std.testing.expectEqual(@as(u32, 1), gs.stockCount(site, rules.packageKey(.machine_gun)));
}
