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
            .home => types.Site{ .hq = gs.homeHqFor(company) },
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
    const maintenance = @import("maintenance.zig");
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
        var best: ?types.PersonId = null;
        var best_spare: u32 = 0;
        var best_skill: u8 = std.math.maxInt(u8);
        for (gs.people.values()) |*p| {
            techEligibility(gs, f, p) catch |err| switch (err) {
                error.ArtilleryNoServiceSite, error.Unavailable, error.ArtilleryUnqualified, error.ArtilleryPersonAbsent, error.ArtilleryPersonSeated => continue,
                else => unreachable,
            };
            const spare = maintenance.techWeeklyHoursAvailable(gs, p) -| maintenance.techWeeklyLoadHours(gs, p.id);
            const skill = p.skill(.tech_mechanic).?;
            if (best == null or spare > best_spare or (spare == best_spare and (skill < best_skill or (skill == best_skill and @intFromEnum(p.id) < @intFromEnum(best.?))))) {
                best = p.id;
                best_spare = spare;
                best_skill = skill;
            }
        }
        if (best) |person_id| {
            f.tech = person_id;
            gs.person(person_id).?.assigned_force = company;
        } else open += 1;
    }
    return open;
}
