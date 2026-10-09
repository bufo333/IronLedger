//! Artillery seat qualification, physical presence and assignment preparation.
//! No MekHQ counterpart: individual project crew policy (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const rules = @import("../domain/artillery_operations.zig");
const dom = @import("../domain/artillery_formation.zig");
const person = @import("../domain/person.zig");
const GameState = @import("state.zig").GameState;
const commands = @import("commands.zig");
const posture = @import("posture.zig");
const operations = @import("artillery_operations.zig");
const personnel = @import("personnel.zig");

pub const Occupancy = struct { formation: types.ArtilleryFormationId, seat: rules.Seat };

/// One operating seat across artillery and ordinary hulls. Source: operations
/// design, Crew and personnel policy. Empty IDs never count as occupants.
pub fn operatingSeat(gs: *const GameState, id: types.PersonId) ?Occupancy {
    if (id == .none) return null;
    for (gs.artillery_formations.values()) |f| for (rules.seats, f.crew) |seat, occupant| {
        if (occupant == id) return .{ .formation = f.id, .seat = seat };
    };
    return null;
}

/// True for any conventional pilot or artillery operating seat, without mutation.
pub fn isSeated(gs: *GameState, id: types.PersonId) bool {
    return id != .none and (gs.pilotSeat(id) != .none or operatingSeat(gs, id) != null);
}

/// Unassigned people stand at the outfit seat; company people follow their actual
/// posture. Posted staff stand only at their own HQ. No home-HQ remote service.
pub fn personPresent(gs: *GameState, p: *const person.Person, site: types.Site) bool {
    const company = gs.companyOf(p.assigned_force);
    if (company != .none) {
        const physical = switch (posture.companyPosture(gs, company)) {
            .home => gs.homeSiteFor(company),
            .deployed, .idle_afield => types.Site{ .company = company },
            .en_route, .returning => return false,
        };
        return std.meta.eql(physical, site);
    }
    const physical = if (p.posted_hq != .none) types.Site{ .hq = p.posted_hq } else gs.defaultSite();
    return std.meta.eql(physical, site);
}

/// Complete operating-seat eligibility with typed refusals. A candidate either
/// belongs to this company or joins it wholly unassigned at its actual home.
pub fn crewEligibility(gs: *GameState, f: *const dom.Formation, seat: rules.Seat, p: *const person.Person) commands.Error!void {
    if (f.placement != .company) return error.ArtilleryWrongLocation;
    const site = operations.operationSite(gs, f) orelse return error.ArtilleryNoServiceSite;
    if (!personnel.availableForDuty(p, gs.clock.day_index)) return error.Unavailable;
    if (!rules.qualified(p, seat)) return error.ArtilleryUnqualified;
    const company = f.placement.company;
    const member = gs.companyOf(p.assigned_force);
    if (member != company and (p.assigned_force != .none or p.posted_hq != .none or site != .hq)) return error.ArtilleryPersonAbsent;
    if (!personPresent(gs, p, site)) return error.ArtilleryPersonAbsent;
    if (isSeated(gs, p.id)) return error.ArtilleryPersonSeated;
    for (gs.units.values()) |u| if (u.tech == p.id) return error.ArtilleryPersonSeated;
    for (gs.artillery_formations.values()) |carrier| if (carrier.tech == p.id) return error.ArtilleryPersonSeated;
}

/// Complete local mechanic eligibility; a mechanic can share local workload.
pub fn techEligibility(gs: *GameState, f: *const dom.Formation, p: *const person.Person) commands.Error!void {
    const site = operations.operationSite(gs, f) orelse return error.ArtilleryNoServiceSite;
    if (!personnel.availableForDuty(p, gs.clock.day_index)) return error.Unavailable;
    if (p.role != .tech_mechanic or p.skill(.tech_mechanic) == null) return error.ArtilleryUnqualified;
    if (isSeated(gs, p.id)) return error.ArtilleryPersonSeated;
    if (!personPresent(gs, p, site)) return error.ArtilleryPersonAbsent;
    if (f.placement == .company) {
        const member = gs.companyOf(p.assigned_force);
        if (member != f.placement.company and (p.assigned_force != .none or p.posted_hq != .none or site != .hq)) return error.ArtilleryPersonAbsent;
    }
}

/// Assignment allocates its log before changing either reference; no RNG or IDs.
pub fn assign(gs: *GameState, request: @FieldType(commands.Command, "assign_artillery_crew")) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(request.formation) orelse return error.NoSuchArtilleryFormation;
    const p = gs.person(request.person) orelse return error.UnknownPerson;
    if (f.crew[@intFromEnum(request.seat)] != .none) return error.ArtilleryPersonSeated;
    try crewEligibility(gs, f, request.seat, p);
    const log = try gs.prepareLog(.rotation, .{ .company = f.placement.company }, "[artillery] formation {d} {s} assigned person {d}", .{ @intFromEnum(f.id), @tagName(request.seat), @intFromEnum(p.id) });
    f.crew[@intFromEnum(request.seat)] = p.id;
    p.assigned_force = f.placement.company;
    gs.commitLog(log);
    return .{ .artillery_formation = f.id, .artillery_person = p.id };
}

/// Explicit unassignment preserves personnel books, availability and location.
pub fn unassign(gs: *GameState, request: @FieldType(commands.Command, "unassign_artillery_crew")) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(request.formation) orelse return error.NoSuchArtilleryFormation;
    if (f.placement == .sold) return error.ArtilleryUnavailable;
    const id = f.crew[@intFromEnum(request.seat)];
    const log = try gs.prepareLog(.rotation, .{}, "[artillery] formation {d} {s} unassigned", .{ @intFromEnum(f.id), @tagName(request.seat) });
    f.crew[@intFromEnum(request.seat)] = .none;
    gs.commitLog(log);
    return .{ .artillery_formation = f.id, .artillery_person = id };
}

/// Mechanic assignment prepares its owned log before references or books change.
pub fn assignTech(gs: *GameState, request: @FieldType(commands.Command, "assign_artillery_tech")) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(request.formation) orelse return error.NoSuchArtilleryFormation;
    const p = gs.person(request.person) orelse return error.UnknownPerson;
    try techEligibility(gs, f, p);
    const log = try gs.prepareLog(.rotation, .{}, "[artillery] formation {d} mechanic assigned person {d}", .{ @intFromEnum(f.id), @intFromEnum(p.id) });
    f.tech = p.id;
    if (f.placement == .company and p.assigned_force == .none) p.assigned_force = f.placement.company;
    gs.commitLog(log);
    return .{ .artillery_formation = f.id, .artillery_person = p.id };
}

/// Remove a technician reference without changing that person's company or post.
pub fn unassignTech(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(id) orelse return error.NoSuchArtilleryFormation;
    if (f.placement == .sold) return error.ArtilleryUnavailable;
    const person_id = f.tech;
    const log = try gs.prepareLog(.rotation, .{}, "[artillery] formation {d} mechanic unassigned", .{@intFromEnum(f.id)});
    f.tech = .none;
    gs.commitLog(log);
    return .{ .artillery_formation = id, .artillery_person = person_id };
}

/// Fill only empty artillery seats on a prepared roster, by formation ID, seat
/// order, required skill then PersonId. Mechanic choice uses spare shared hours,
/// then skill and ID. Caller owns the full command preparation and commit.
pub fn autoAssignPrepared(gs: *GameState, company: types.ForceId) !u32 {
    var ids: std.ArrayListUnmanaged(types.ArtilleryFormationId) = .empty;
    defer ids.deinit(gs.scratch());
    for (gs.artillery_formations.values()) |f| if (f.placement == .company and f.placement.company == company) {
        try ids.append(gs.scratch(), f.id);
    };
    std.mem.sort(types.ArtilleryFormationId, ids.items, {}, struct {
        fn less(_: void, a: types.ArtilleryFormationId, b: types.ArtilleryFormationId) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.less);
    var open: u32 = 0;
    for (ids.items) |id| {
        const f = gs.artillery_formations.getPtr(id).?;
        for (rules.seats, 0..) |seat, index| {
            if (f.crew[index] != .none) continue;
            var best: ?types.PersonId = null;
            var best_skill: u8 = std.math.maxInt(u8);
            for (gs.people.values()) |*p| {
                crewEligibility(gs, f, seat, p) catch |err| switch (err) {
                    error.ArtilleryWrongLocation, error.ArtilleryNoServiceSite, error.Unavailable, error.ArtilleryUnqualified, error.ArtilleryPersonAbsent, error.ArtilleryPersonSeated => continue,
                    else => unreachable,
                };
                const skill = p.skill(rules.seatSkill(seat)).?;
                if (best == null or skill < best_skill or (skill == best_skill and @intFromEnum(p.id) < @intFromEnum(best.?))) {
                    best = p.id;
                    best_skill = skill;
                }
            }
            if (best) |person_id| {
                f.crew[index] = person_id;
                gs.person(person_id).?.assigned_force = company;
            } else open += 1;
        }
        if (f.tech != .none) continue;
        const best = bestMechanic(gs, f, false);
        if (best) |person_id| {
            f.tech = person_id;
            gs.person(person_id).?.assigned_force = company;
        } else open += 1;
    }
    return open;
}

/// Best local qualified mechanic by spare shared hours, skill and PersonId.
/// Replacements require capacity for this carrier; empty-seat assignment may
/// expose an overloaded mechanic whose weekly service must wait.
pub fn bestMechanic(gs: *GameState, f: *const dom.Formation, require_hours: bool) ?types.PersonId {
    var best: ?types.PersonId = null;
    var best_spare: u32 = 0;
    var best_skill: u8 = std.math.maxInt(u8);
    const maintenance = @import("maintenance.zig");
    for (gs.people.values()) |*p| {
        techEligibility(gs, f, p) catch |err| switch (err) {
            error.ArtilleryNoServiceSite, error.Unavailable, error.ArtilleryUnqualified, error.ArtilleryPersonAbsent, error.ArtilleryPersonSeated => continue,
            else => unreachable,
        };
        const spare = maintenance.techWeeklyHoursAvailable(gs, p) -| maintenance.techWeeklyLoadHours(gs, p.id);
        if (require_hours and spare < maintenance.hoursForSkill(@import("artillery_service.zig").baseHours(f), p.skill(.tech_mechanic).?)) continue;
        const skill = p.skill(.tech_mechanic).?;
        if (best == null or spare > best_spare or (spare == best_spare and (skill < best_skill or (skill == best_skill and @intFromEnum(p.id) < @intFromEnum(best.?))))) {
            best = p.id;
            best_spare = spare;
            best_skill = skill;
        }
    }
    return best;
}

test "qualification presence and deterministic seat selection use distinct ordinary people" {
    const founding = @import("founding.zig");
    const artillery = @import("artillery.zig");
    const ordinary_crew = @import("crew.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, false);
    const co = try gs.createForce("Alpha", .company, .none);
    _ = try artillery.attach(&gs, .{ .formation = id, .company = co });
    const f = gs.artillery_formations.getPtr(id).?;
    const absent = try gs.hirePerson("Unqualified", "Crew", .vehicle_crew);
    gs.person(absent).?.skills.clearRetainingCapacity();
    try std.testing.expectError(error.ArtilleryUnqualified, crewEligibility(&gs, f, .gunner, gs.person(absent).?));
    const far = try founding.foundHq(&gs, "Remote", .regional, "skye");
    var ids: [rules.seats.len]types.PersonId = undefined;
    for (&ids) |*pid| {
        pid.* = try gs.hirePerson("Qualified", "Crew", .vehicle_crew);
        try gs.person(pid.*).?.skills.put(gs.allocator(), .gunnery_vee, 4);
        try gs.person(pid.*).?.skills.put(gs.allocator(), .driving_vee, 4);
    }
    const p = gs.person(ids[0]).?;
    p.posted_hq = far;
    try std.testing.expectError(error.ArtilleryPersonAbsent, crewEligibility(&gs, f, .gunner, p));
    p.posted_hq = .none;
    p.status = .pow;
    try std.testing.expectError(error.Unavailable, crewEligibility(&gs, f, .gunner, p));
    p.status = .active;
    p.training = .{ .skill = .gunnery_vee, .done_day = 1 };
    try std.testing.expectError(error.Unavailable, crewEligibility(&gs, f, .gunner, p));
    p.training = null;
    _ = try ordinary_crew.autoAssign(&gs, co);
    for (f.crew, ids, rules.seats) |occupant, expected, seat| {
        try std.testing.expectEqual(expected, occupant);
        try std.testing.expectEqual(Occupancy{ .formation = id, .seat = seat }, operatingSeat(&gs, occupant).?);
        try std.testing.expect(isSeated(&gs, occupant));
        try std.testing.expectError(error.ArtilleryPersonSeated, crewEligibility(&gs, f, seat, gs.person(occupant).?));
    }
    try std.testing.expectEqual(f.tech, bestMechanic(&gs, f, false).?);
    gs.force(co).?.location_planet = "galatea";
    try std.testing.expect(!personPresent(&gs, gs.person(ids[0]).?, .{ .hq = gs.seat() }));
    try std.testing.expect(personPresent(&gs, gs.person(ids[0]).?, .{ .company = co }));
}

test "crew commands reload and lifecycle are unchanged at each allocation failure and retry" {
    const digest = @import("digest.zig");
    const ordinary_crew = @import("crew.zig");
    for ([_]enum { seat, mechanic, reload, auto, hiring, departure }{ .seat, .mechanic, .reload, .auto, .hiring, .departure }) |action| {
        var failed = false;
        var failure_index: usize = 0;
        while (true) : (failure_index += 1) {
            var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer outer.deinit();
            var gs = GameState.init(outer.allocator(), .{});
            const id = try operations.fixtureForTest(&gs, true);
            const f = gs.artillery_formations.get(id).?;
            const occupant = f.crew[0];
            if (action == .seat or action == .auto) _ = try unassign(&gs, .{ .formation = id, .seat = .commander });
            if (action == .mechanic) _ = try unassignTech(&gs, id);
            try gs.addStock(operations.operationSite(&gs, gs.artillery_formations.getPtr(id).?).?, rules.packageKey(.long_tom), 4);
            if (action == .departure) {
                gs.clock.day_index = 365;
                gs.ledger.transactions = .empty;
            }
            const before = digest.stateHash(&gs);
            gs.arena.state = .{};
            var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = failure_index });
            gs.arena.child_allocator = failing.allocator();
            const result: anyerror!void = switch (action) {
                .seat => blk: {
                    _ = assign(&gs, .{ .formation = id, .seat = .commander, .person = occupant }) catch |err| break :blk err;
                    break :blk {};
                },
                .mechanic => blk: {
                    _ = assignTech(&gs, .{ .formation = id, .person = f.tech }) catch |err| break :blk err;
                    break :blk {};
                },
                .reload => blk: {
                    _ = operations.reload(&gs, .{ .formation = id, .family = .long_tom }) catch |err| break :blk err;
                    break :blk {};
                },
                .auto => blk: {
                    _ = ordinary_crew.autoAssign(&gs, f.placement.company) catch |err| break :blk err;
                    break :blk {};
                },
                .hiring => blk: {
                    _ = ordinary_crew.crewCompany(&gs, f.placement.company) catch |err| break :blk err;
                    break :blk {};
                },
                .departure => blk: {
                    _ = personnel.depart(&gs, occupant, .retired, types.full_bp, "test retirement") catch |err| break :blk err;
                    break :blk {};
                },
            };
            if (result) |_| break else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(before, digest.stateHash(&gs));
                failed = true;
                gs.arena.state = .{};
                gs.arena.child_allocator = outer.allocator();
                switch (action) {
                    .seat => _ = try assign(&gs, .{ .formation = id, .seat = .commander, .person = occupant }),
                    .mechanic => _ = try assignTech(&gs, .{ .formation = id, .person = f.tech }),
                    .reload => _ = try operations.reload(&gs, .{ .formation = id, .family = .long_tom }),
                    .auto => _ = try ordinary_crew.autoAssign(&gs, f.placement.company),
                    .hiring => _ = try ordinary_crew.crewCompany(&gs, f.placement.company),
                    .departure => _ = try personnel.depart(&gs, occupant, .retired, types.full_bp, "test retirement"),
                }
                try std.testing.expect(before != digest.stateHash(&gs));
            }
        }
        try std.testing.expect(failed);
    }
}
