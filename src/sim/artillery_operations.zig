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
            if (p.status != .active or !rules.qualified(p, seat) or gs.companyOf(p.assigned_force) != f.placement.company or p.posted_hq != .none or gs.pilotSeat(id) != .none) return error.CorruptSave;
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
            if (p.status != .active or p.role != .tech_mechanic or p.skill(.tech_mechanic) == null or crew.isSeated(gs, p.id)) return error.CorruptSave;
            if (f.placement == .company and (gs.companyOf(p.assigned_force) != f.placement.company or p.posted_hq != .none)) return error.CorruptSave;
        }
    }
    for (gs.bay_jobs.items, 0..) |job, index| {
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
