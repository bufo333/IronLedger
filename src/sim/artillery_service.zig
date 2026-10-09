//! Artillery adapters to shared maintenance, repair rules and HQ bays.
//! No MekHQ counterpart: project carrier operations (docs/mekhq-map.md).

const std = @import("std");
const types = @import("../domain/types.zig");
const tuning = @import("../domain/tuning.zig").t;
const dom = @import("../domain/artillery_formation.zig");
const rules = @import("../domain/artillery_operations.zig");
const unit = @import("../domain/unit.zig");
const part = @import("../domain/part.zig");
const person = @import("../domain/person.zig");
const commander = @import("../domain/commander.zig");
const hull = @import("../domain/hull_instance.zig");
const state = @import("state.zig");
const GameState = state.GameState;
const commands = @import("commands.zig");
const artillery = @import("artillery.zig");
const crew = @import("artillery_crew.zig");
const operations = @import("artillery_operations.zig");
const maintenance = @import("maintenance.zig");
const hq_ops = @import("hq_ops.zig");
const sites = @import("sites.zig");

/// The shared maintenance table for the carrier's verified tonnage and quality.
pub fn baseHours(f: *const dom.Formation) u32 {
    return maintenance.maintenanceHoursFor(.vehicle, @intCast(artillery.carrier().vehicle.tons), f.quality, false);
}

/// Shared skill pacing; absent/unqualified mechanics do not grant a default.
pub fn techHours(gs: *GameState, f: *const dom.Formation) u32 {
    const p = gs.person(f.tech) orelse return baseHours(f);
    const skill = p.skill(.tech_mechanic) orelse return baseHours(f);
    return maintenance.hoursForSkill(baseHours(f), skill);
}

/// One active owned carrier's weekly consumables estimate, including freight;
/// actual weekly charges require covered local service.
pub fn weeklyConsumablesTotal(gs: *const GameState) types.CBills {
    var total: types.CBills = 0;
    for (gs.artillery_formations.values()) |f| if (f.placement != .sold) {
        total += @divTrunc(artillery.purchasePrice(), tuning.maintenance.consumables_divisor);
    };
    return total;
}

pub const RepairQuote = struct { formation: types.ArtilleryFormationId, hq: types.HqId, component: []const u8, duration_days: u32, labor: types.CBills };

/// Pure structural-work eligibility at the actual regional/brigade HQ; shared
/// bay capability and local mechanic are required independently of readiness.
pub fn repairQuote(gs: *GameState, f: *const dom.Formation) commands.Error!RepairQuote {
    if (operations.hasJob(gs, f.id)) return error.ArtilleryBayJob;
    const site = operations.serviceCapability(gs, f) orelse return error.ArtilleryNoMechanic;
    if (site != .hq) return error.ArtilleryWrongLocation;
    const hq = gs.hqs.getPtr(site.hq) orelse return error.UnknownHq;
    if (!hq.supportsStructuralRepair()) return error.NoBay;
    const component = part.componentForSlotClass("chassis.structure", .heavy);
    if (hq.effectiveFacilityLevel(.mek_bay) < part.find(component).?.fab_min_bay) return error.BayTooSmall;
    if (f.slots[@intFromEnum(rules.Slot.chassis)].condition == .ok) return error.NothingToRepair;
    if (gs.stockCount(site, component) == 0) return error.MissingComponents;
    return .{ .formation = f.id, .hq = site.hq, .component = component, .duration_days = tuning.hq_ops.depot_base_days + tuning.hq_ops.depot_days_per_component, .labor = @divTrunc(artillery.purchasePrice(), tuning.hq_ops.depot_labour_divisor) };
}

/// Prepared stock consumption, queue insertion, history and log commit together.
pub fn queueRepair(gs: *GameState, id: types.ArtilleryFormationId) commands.Error!commands.Result {
    const f = gs.artillery_formations.getPtr(id) orelse return error.NoSuchArtilleryFormation;
    const q = try repairQuote(gs, f);
    try gs.bay_jobs.ensureUnusedCapacity(gs.allocator(), 1);
    try gs.maintenance_entries.ensureUnusedCapacity(gs.allocator(), 1);
    const log = try gs.prepareLog(.construction, .{ .hq = q.hq }, "[artillery] formation {d} chassis repair queued at HQ {d}", .{ @intFromEnum(id), @intFromEnum(q.hq) });
    if (!gs.takeStock(.{ .hq = q.hq }, q.component, 1)) unreachable;
    gs.bay_jobs.appendAssumeCapacity(.{ .hq = q.hq, .kind = .artillery_depot_repair, .artillery = id, .duration_days = q.duration_days, .queued_day = gs.clock.day_index, .cost = q.labor });
    gs.maintenance_entries.appendAssumeCapacity(.{ .hull_instance_id = f.hull, .day = gs.clock.day_index, .tech = f.tech, .action = .repair, .description = "artillery chassis depot work", .cost = q.labor });
    gs.commitLog(log);
    return .{ .artillery_formation = id, .hq = q.hq, .artillery_site = .{ .hq = q.hq } };
}

/// A queued or started job waits without rolling when its assigned mechanic
/// cannot work at the actual HQ. A started job continues occupying its bay.
pub fn jobCanWork(gs: *GameState, job: *const state.BayJob) bool {
    const f = gs.artillery_formations.getPtr(job.artillery) orelse return false;
    const site = operations.serviceCapability(gs, f) orelse return false;
    return site == .hq and site.hq == job.hq;
}

const PreparedPerson = struct { id: types.PersonId, value: person.Person };

/// An artillery batch stages only its condition, stock, people, shared tech
/// references, streams, jobs, postings and logs. Nested mutable accident data
/// is copied before invoking the existing medical/award owners.
const ServiceBatch = struct {
    view: GameState,
    prepared_people: std.ArrayListUnmanaged(PreparedPerson) = .empty,
    logs: std.ArrayListUnmanaged(state.LogEntry) = .empty,

    fn init(gs: *GameState) !ServiceBatch {
        var view = gs.*;
        view.arena = std.heap.ArenaAllocator.init(gs.scratch());
        errdefer view.arena.deinit();
        const alloc = view.allocator();
        view.people = try gs.people.clone(alloc);
        for (view.people.values()) |*p| {
            p.injuries = .empty;
            try p.injuries.appendSlice(alloc, gs.person(p.id).?.injuries.items);
            p.awards = .empty;
            try p.awards.appendSlice(alloc, gs.person(p.id).?.awards.items);
        }
        view.units = try gs.units.clone(alloc);
        view.artillery_formations = try gs.artillery_formations.clone(alloc);
        view.hqs = try gs.hqs.clone(alloc);
        for (view.hqs.values()) |*h| h.stock = try h.stock.clone(alloc);
        view.forces = try gs.forces.clone(alloc);
        for (view.forces.values()) |*f| f.stock = try f.stock.clone(alloc);
        view.bay_jobs = .empty;
        try view.bay_jobs.appendSlice(alloc, gs.bay_jobs.items);
        view.maintenance_entries = .empty;
        view.event_log = .empty;
        view.ledger.transactions = .empty;
        return .{ .view = view };
    }

    fn deinit(self: *ServiceBatch) void {
        self.view.arena.deinit();
    }

    fn prepareCommit(self: *ServiceBatch, gs: *GameState) !void {
        const alloc = gs.allocator();
        const scratch = self.view.allocator();
        for (self.view.people.values()) |p| {
            const original = gs.person(p.id).?;
            if (p.status == original.status and p.injuries.items.len == original.injuries.items.len and p.awards.items.len == original.awards.items.len and p.morale == original.morale) continue;
            var copy = p;
            copy.injuries = .empty;
            try copy.injuries.appendSlice(alloc, p.injuries.items);
            copy.awards = .empty;
            try copy.awards.appendSlice(alloc, p.awards.items);
            try self.prepared_people.append(scratch, .{ .id = p.id, .value = copy });
        }
        for (self.view.event_log.items) |entry| {
            var copy = entry;
            copy.text = try alloc.dupe(u8, entry.text);
            try self.logs.append(scratch, copy);
        }
        try gs.reserveLog(self.logs.items.len);
        try gs.reserveLedger(self.view.ledger.transactions.items.len);
        try gs.bay_jobs.ensureUnusedCapacity(alloc, self.view.bay_jobs.items.len - gs.bay_jobs.items.len);
        try gs.maintenance_entries.ensureUnusedCapacity(alloc, self.view.maintenance_entries.items.len);
    }

    fn commit(self: *const ServiceBatch, gs: *GameState) void {
        for (self.view.artillery_formations.values()) |f| gs.artillery_formations.getPtr(f.id).?.* = f;
        for (self.view.units.values()) |u| gs.unit(u.id).?.tech = u.tech;
        for (self.prepared_people.items) |p| gs.person(p.id).?.* = p.value;
        for (self.view.hqs.values()) |h| {
            const target = gs.hqs.getPtr(h.id).?;
            for (h.stock.keys(), h.stock.values()) |key, value| target.stock.getPtr(key).?.* = value;
            target.funds = h.funds;
        }
        for (self.view.forces.values()) |f| {
            const target = gs.force(f.id).?;
            for (f.stock.keys(), f.stock.values()) |key, value| target.stock.getPtr(key).?.* = value;
            target.local_funds = f.local_funds;
        }
        gs.bay_jobs.clearRetainingCapacity();
        gs.bay_jobs.appendSliceAssumeCapacity(self.view.bay_jobs.items);
        gs.maintenance_entries.appendSliceAssumeCapacity(self.view.maintenance_entries.items);
        gs.ledger.transactions.appendSliceAssumeCapacity(self.view.ledger.transactions.items);
        gs.event_log.appendSliceAssumeCapacity(self.logs.items);
        gs.funds = self.view.funds;
        gs.rng = self.view.rng;
    }
};

fn changeQuality(f: *dom.Formation, drift: maintenance.QualityDrift) void {
    const q = @intFromEnum(f.quality);
    switch (drift) {
        .drop => if (q > @intFromEnum(types.Quality.a)) {
            f.quality = @enumFromInt(q - 1);
        },
        .rise => if (q < @intFromEnum(types.Quality.f)) {
            f.quality = @enumFromInt(q + 1);
        },
        .hold => {},
    }
}

fn damageGear(gs: *GameState, f: *dom.Formation, intact_only: bool) !void {
    var eligible: [rules.descriptors.len]usize = undefined;
    var count: u32 = 0;
    for (rules.descriptors, f.slots, 0..) |d, s, i| {
        if (d.class == .structure or (intact_only and s.condition != .ok)) continue;
        eligible[count] = i;
        count += 1;
    }
    if (count == 0) return;
    const index = eligible[gs.rng.random(.maintenance).uintLessThan(u32, count)];
    const slot = &f.slots[index];
    slot.condition = switch (slot.condition) {
        .ok => .damaged,
        .damaged => .destroyed,
        else => slot.condition,
    };
    if (slot.condition == .destroyed and slot.rounds > 0) {
        const lost = slot.rounds;
        slot.rounds = 0;
        try gs.log(.construction, .{}, "[artillery] formation {d} lost {d} rounds from destroyed {s}", .{ @intFromEnum(f.id), lost, @tagName(rules.descriptors[index].slot) });
    }
}

fn prepareMaintenance(gs: *GameState, f: *dom.Formation, book: *maintenance.HourBook) !void {
    const site = operations.operationSite(gs, f) orelse return;
    if (operations.hasJob(gs, f.id)) return;
    const mechanic_site = operations.serviceCapability(gs, f);
    const tech = if (mechanic_site != null) gs.person(f.tech) else null;
    const covered = if (tech) |p| try book.spend(gs, p, techHours(gs, f), 0) else false;
    const skill = if (covered) tech.?.skill(.tech_mechanic).? else 7;
    const target = tuning.maintenance.target_base + f.quality.maintenanceModifier() + (if (site == .company) tuning.maintenance.target_deployed else @as(i32, 0)) + (if (!covered) tuning.maintenance.target_uncovered else @as(i32, 0));
    const raw = gs.rng.roll2d6(.maintenance);
    const drift = maintenance.qualityDrift(@as(i32, raw) + person.skillRollBonus(skill), target);
    const before = f.quality;
    changeQuality(f, drift);
    if (drift == .drop and raw == 2) try damageGear(gs, f, false);
    if (f.quality != before) try gs.log(.construction, .{}, "[artillery] formation {d} quality {s} -> {s}", .{ @intFromEnum(f.id), @tagName(before), @tagName(f.quality) });
    if (covered) {
        f.last_maintenance_day = gs.clock.day_index;
        try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -types.applyBp(@divTrunc(artillery.purchasePrice(), tuning.maintenance.consumables_divisor), commander.costMultBp(gs.commander, .repair)), .category = .maintenance, .note = "artillery maintenance consumables" });
        if (raw == 2 and gs.rng.roll2d6(.maintenance) <= tuning.maintenance.accident_target) try maintenance.injureTech(gs, tech.?.id, tuning.maintenance.accident_days_base + gs.rng.roll2d6(.medical), "artillery maintenance accident");
    }
}

fn prepareFieldRepairs(gs: *GameState, f: *dom.Formation, book: *maintenance.HourBook) !void {
    if (operations.hasJob(gs, f.id)) return;
    const site = operations.serviceCapability(gs, f) orelse return;
    const tech = gs.person(f.tech).?;
    const reserved = maintenance.techWeeklyLoadHours(gs, tech.id);
    var labor: types.CBills = 0;
    for (rules.descriptors, &f.slots) |d, *s| {
        const tier = unit.repairTier(d.class, s.condition) orelse continue;
        if (tier == .depot) continue;
        const replacement = s.condition == .destroyed or s.condition == .missing;
        if (replacement and gs.stockCount(site, d.spare_key) == 0) continue;
        if (!try book.spend(gs, tech, maintenance.slotHours(replacement), reserved)) continue;
        if (replacement and !gs.takeStock(site, d.spare_key, 1)) unreachable;
        s.condition = .ok;
        labor += maintenance.slotLabour(d.spare_key, replacement);
    }
    if (f.armor_pct < 100 and gs.stockCount(site, "armor") > 0 and try book.spend(gs, tech, tuning.maintenance.hours_armor_patch, reserved)) {
        if (!gs.takeStock(site, "armor", 1)) unreachable;
        f.armor_pct = @min(100, f.armor_pct + tuning.maintenance.armor_patch_pct);
        labor += tuning.maintenance.armor_patch_labour;
    }
    if (labor > 0) try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -types.applyBp(labor, commander.costMultBp(gs.commander, .repair)), .category = .maintenance, .note = "artillery field repair labor" });
    if (f.slots[@intFromEnum(rules.Slot.chassis)].condition != .ok and site == .hq) {
        _ = queueRepair(gs, f.id) catch |err| switch (err) {
            error.ArtilleryNoMechanic, error.ArtilleryBayJob, error.ArtilleryWrongLocation, error.NoBay, error.BayTooSmall, error.MissingComponents, error.NothingToRepair => {
                try gs.log(.construction, .{ .hq = site.hq }, "[artillery] formation {d} depot work waiting: {s}", .{ @intFromEnum(f.id), @errorName(err) });
                return;
            },
            else => return err,
        };
    }
}

/// Prepare the entire stable-ID population and automatic field repairs against
/// the post-conventional state, carrying both shared hour books. A completed
/// day checkpoint prevents artillery RNG, stock and costs repeating on re-entry.
pub fn runWeekly(gs: *GameState, service_book: *maintenance.HourBook, repair_book: *maintenance.HourBook) !void {
    if (gs.last_artillery_service_day == gs.clock.day_index) return;
    var batch = try ServiceBatch.init(gs);
    defer batch.deinit();
    const alloc = batch.view.allocator();
    var ids: std.ArrayListUnmanaged(types.ArtilleryFormationId) = .empty;
    for (batch.view.artillery_formations.keys()) |id| try ids.append(alloc, id);
    std.mem.sort(types.ArtilleryFormationId, ids.items, {}, struct {
        fn less(_: void, a: types.ArtilleryFormationId, b: types.ArtilleryFormationId) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.less);
    var staged_service: maintenance.HourBook = .{ .alloc = alloc, .map = try service_book.map.clone(alloc) };
    var staged_repairs: maintenance.HourBook = .{ .alloc = alloc, .map = try repair_book.map.clone(alloc) };
    for (ids.items) |id| try prepareMaintenance(&batch.view, batch.view.artillery_formations.getPtr(id).?, &staged_service);
    for (ids.items) |id| try prepareFieldRepairs(&batch.view, batch.view.artillery_formations.getPtr(id).?, &staged_repairs);
    try batch.prepareCommit(gs);
    batch.commit(gs);
    gs.last_artillery_service_day = gs.clock.day_index;
}

/// A due depot job is atomic independently of earlier completed jobs. Redo
/// retains its bay and extends time; unavailable staff consumes no stream.
pub fn completeJob(gs: *GameState, index: usize) !bool {
    const original = gs.bay_jobs.items[index];
    if (!jobCanWork(gs, &original)) return false;
    var batch = try ServiceBatch.init(gs);
    defer batch.deinit();
    const view = &batch.view;
    const f = view.artillery_formations.getPtr(original.artillery) orelse return error.CorruptSave;
    const p = view.person(f.tech) orelse return error.CorruptSave;
    const outcome = hq_ops.rollRepairFor(&view.rng, p.skill(.tech_mechanic).?, f.quality);
    if (outcome == .redo) {
        const days: u32 = @intCast(@max(1, types.applyBp(original.duration_days, tuning.hq_ops.repair_redo_bp)));
        view.bay_jobs.items[index].done_day = std.math.add(u32, view.clock.day_index, days) catch return error.ArtilleryDateExhausted;
        try view.log(.construction, .{ .hq = original.hq }, "[artillery] formation {d} chassis repair redone for {d} days", .{ @intFromEnum(f.id), days });
    } else {
        f.slots[@intFromEnum(rules.Slot.chassis)].condition = .ok;
        if (outcome == .fault or outcome == .botch) try damageGear(view, f, true);
        if (outcome == .botch) changeQuality(f, .drop);
        if (original.cost > 0) try view.postTreasury(.{ .hq = original.hq }, .{ .day = view.clock.day_index, .amount = -original.cost, .category = .maintenance, .hq = original.hq, .note = "artillery depot labor" });
        if (view.rng.roll2d6(.medical) == 2) try maintenance.injureTech(view, p.id, tuning.maintenance.bay_accident_days_base + view.rng.roll2d6(.medical), "artillery bay accident");
        try view.log(.construction, .{ .hq = original.hq }, "[artillery] formation {d} chassis repair completed: {s}", .{ @intFromEnum(f.id), @tagName(outcome) });
    }
    try batch.prepareCommit(gs);
    batch.commit(gs);
    return outcome != .redo;
}
