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
            if (p.status == original.status and p.injuries.items.len == original.injuries.items.len and p.awards.items.len == original.awards.items.len and p.morale == original.morale and p.assigned_force == original.assigned_force) continue;
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
        try gs.bay_jobs.ensureUnusedCapacity(alloc, self.view.bay_jobs.items.len -| gs.bay_jobs.items.len);
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
        if (raw == 2 and gs.rng.roll2d6(.maintenance) <= tuning.maintenance.accident_target) try maintenance.injureTechPrepared(gs, tech.?.id, tuning.maintenance.accident_days_base + gs.rng.roll2d6(.medical), "artillery maintenance accident");
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
        if (original.cost > 0) try view.postTreasury(.{ .hq = original.hq }, .{ .day = view.clock.day_index, .amount = -types.applyBp(original.cost, commander.costMultBp(view.commander, .repair)), .category = .maintenance, .hq = original.hq, .note = "artillery depot labor" });
        if (view.rng.roll2d6(.medical) == 2) try maintenance.injureTechPrepared(view, p.id, tuning.maintenance.bay_accident_days_base + view.rng.roll2d6(.medical), "artillery bay accident");
        try view.log(.construction, .{ .hq = original.hq }, "[artillery] formation {d} chassis repair completed: {s}", .{ @intFromEnum(f.id), @tagName(outcome) });
    }
    try batch.prepareCommit(gs);
    batch.commit(gs);
    return outcome != .redo;
}

/// Accident preparation covers injury, awards and replacements across both
/// asset populations before committing personnel, references, streams or logs.
pub fn injureTechAtomic(gs: *GameState, id: types.PersonId, days: u32, cause: []const u8) !void {
    var batch = try ServiceBatch.init(gs);
    defer batch.deinit();
    try maintenance.injureTechPrepared(&batch.view, id, days, cause);
    try batch.prepareCommit(gs);
    batch.commit(gs);
}

/// Aggregate physical-site repair stock in canonical carrier/slot order. Field
/// demand is replacement gear plus the one weekly armor patch; structure is
/// reported separately for the shared actual-HQ component ledger.
pub fn addRepairDemand(alloc: std.mem.Allocator, gs: *GameState, site: types.Site, company: ?types.ForceId, structural: bool, need: *std.StringArrayHashMapUnmanaged(u32)) !void {
    for (gs.artillery_formations.values()) |*f| {
        if (operations.hasJob(gs, f.id)) continue;
        const actual = operations.operationSite(gs, f) orelse continue;
        if (!std.meta.eql(actual, site)) continue;
        if (company) |co| if (f.placement != .company or f.placement.company != co) continue;
        for (rules.descriptors, f.slots) |d, slot| {
            const tier = unit.repairTier(d.class, slot.condition) orelse continue;
            if ((tier == .depot) != structural) continue;
            if (!structural and slot.condition != .destroyed and slot.condition != .missing) continue;
            const entry = try need.getOrPut(alloc, d.spare_key);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
        if (!structural and f.armor_pct < dom.intact_condition_pct) {
            const entry = try need.getOrPut(alloc, "armor");
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
}

test "one mechanic shares exact conventional artillery hours and actual HQ teams" {
    const founding = @import("founding.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, false);
    const f = gs.artillery_formations.getPtr(id).?;
    const tech_id = f.tech;
    var tech = gs.person(tech_id).?;
    const ordinary = try gs.addUnit("SCP-1N");
    gs.unit(ordinary).?.tech = tech.id;
    const demand = maintenance.techWeeklyHoursFor(&gs, tech, gs.unit(ordinary).?) + techHours(&gs, f);
    try std.testing.expectEqual(demand, maintenance.techWeeklyLoadHours(&gs, tech.id));
    const far = try founding.foundHq(&gs, "Remote", .regional, "skye");
    const without_team = maintenance.techWeeklyHoursAvailable(&gs, tech);
    for (0..tuning.person.astechs_per_tech_full_rate) |_| {
        const assistant = try gs.hirePerson("Remote", "Assistant", .astech);
        gs.person(assistant).?.posted_hq = far;
    }
    tech = gs.person(tech_id).?;
    try std.testing.expectEqual(without_team, maintenance.techWeeklyHoursAvailable(&gs, tech));
    for (gs.people.values()) |*p| if (p.role == .astech) {
        p.posted_hq = gs.seat();
    };
    try std.testing.expect(maintenance.techWeeklyHoursAvailable(&gs, tech) > without_team);
    var book: maintenance.HourBook = .{ .alloc = std.testing.allocator };
    defer book.map.deinit(std.testing.allocator);
    try book.map.put(std.testing.allocator, tech.id, maintenance.techWeeklyHoursFor(&gs, tech, gs.unit(ordinary).?));
    try std.testing.expect(try book.spend(&gs, tech, maintenance.techWeeklyHoursFor(&gs, tech, gs.unit(ordinary).?), 0));
    try std.testing.expect(!try book.spend(&gs, tech, techHours(&gs, f), 0));
    var repairs: maintenance.HourBook = .{ .alloc = std.testing.allocator };
    defer repairs.map.deinit(std.testing.allocator);
    try repairs.map.put(std.testing.allocator, tech.id, 0);
    f.slots[@intFromEnum(rules.Slot.communications)].condition = .damaged;
    try runWeekly(&gs, &book, &repairs);
    try std.testing.expect(f.last_maintenance_day == null);
    try std.testing.expectEqual(unit.PartCondition.damaged, f.slots[@intFromEnum(rules.Slot.communications)].condition);
    const digest = @import("digest.zig");
    const checkpoint = digest.stateHash(&gs);
    try runWeekly(&gs, &book, &repairs);
    try std.testing.expectEqual(checkpoint, digest.stateHash(&gs));
}

fn depotFixtureForTest(gs: *GameState) !types.ArtilleryFormationId {
    const id = try operations.fixtureForTest(gs, false);
    const hq = gs.hqs.getPtr(gs.seat()).?;
    for (hq.facilities.items) |*facility| if (facility.kind == .mek_bay) {
        facility.level = part.find(rules.descriptor(.chassis).spare_key).?.fab_min_bay;
    };
    hq.staff_assigned = hq.staffRequired().total();
    gs.artillery_formations.getPtr(id).?.slots[@intFromEnum(rules.Slot.chassis)].condition = .destroyed;
    try gs.addStock(.{ .hq = gs.seat() }, rules.descriptor(.chassis).spare_key, 1);
    return id;
}

test "local field and structural demand feeds existing ledgers without minting ammunition" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try depotFixtureForTest(&gs);
    const f = gs.artillery_formations.getPtr(id).?;
    f.slots[@intFromEnum(rules.Slot.long_tom_bin_1)].condition = .missing;
    f.armor_pct = 90;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const field = try hq_ops.spareDemand(arena.allocator(), &gs, .{ .hq = gs.seat() });
    try std.testing.expectEqual(@as(usize, 2), field.len);
    try std.testing.expectEqualStrings("artillery_spares", field[0].key);
    try std.testing.expectEqual(@as(u32, 1), field[0].short);
    const structural = try hq_ops.componentDemand(arena.allocator(), &gs, gs.seat(), null);
    try std.testing.expectEqual(@as(usize, 1), structural.len);
    try std.testing.expectEqual(@as(u32, 0), structural[0].short);
    const quote = try repairQuote(&gs, f);
    _ = try commands.execute(&gs, .{ .repair_artillery = id });
    try std.testing.expectEqual(quote.duration_days, gs.bay_jobs.items[0].duration_days);
    try std.testing.expectEqual(id, (try hq_ops.bayTarget(&gs, &gs.bay_jobs.items[0])).artillery);
    try std.testing.expectEqual(@as(usize, 0), (try hq_ops.componentDemand(arena.allocator(), &gs, gs.seat(), null)).len);
    try std.testing.expectError(error.ArtilleryBayJob, artillery.sell(&gs, id));
    gs.person(f.tech).?.leave_until_day = 100;
    const digest = @import("digest.zig");
    const waiting = digest.stateHash(&gs);
    try std.testing.expect(!jobCanWork(&gs, &gs.bay_jobs.items[0]));
    try std.testing.expect(!try completeJob(&gs, 0));
    try std.testing.expectEqual(waiting, digest.stateHash(&gs));
    gs.person(f.tech).?.leave_until_day = null;
    gs.clock.day_index = quote.duration_days;
    gs.bay_jobs.items[0].started_day = 0;
    gs.bay_jobs.items[0].done_day = quote.duration_days;
    var tries: usize = 0;
    while (!try completeJob(&gs, 0)) : (tries += 1) {
        try std.testing.expect(tries < 100);
        gs.clock.day_index = gs.bay_jobs.items[0].done_day.?;
    }
    try std.testing.expectEqual(unit.PartCondition.ok, f.slots[@intFromEnum(rules.Slot.chassis)].condition);
    for (rules.descriptors, f.slots) |d, s| if (d.family != null) {
        try std.testing.expectEqual(@as(u16, 0), s.rounds);
    };
}

test "weekly preparation accident queue and completion refuse every allocation failure unchanged then retry" {
    const digest = @import("digest.zig");
    for ([_]enum { weekly, accident, queue, completion }{ .weekly, .accident, .queue, .completion }) |action| {
        var failure_index: usize = 0;
        var failed = false;
        while (true) : (failure_index += 1) {
            var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer outer.deinit();
            var gs = GameState.init(outer.allocator(), .{ .seed = 625 });
            const id = try depotFixtureForTest(&gs);
            var replacement: types.PersonId = .none;
            if (action == .accident) {
                const company = try gs.createForce("Alpha", .company, .none);
                _ = try artillery.attach(&gs, .{ .formation = id, .company = company });
                const tech = try gs.hirePerson("Local", "Mechanic", .tech_mechanic);
                _ = try crew.assignTech(&gs, .{ .formation = id, .person = tech });
                replacement = try gs.hirePerson("Spare", "Mechanic", .tech_mechanic);
                gs.person(replacement).?.weekly_hours = 100;
            }
            if (action == .completion) {
                _ = try queueRepair(&gs, id);
                gs.bay_jobs.items[0].started_day = 0;
                gs.clock.day_index = gs.bay_jobs.items[0].duration_days;
                gs.bay_jobs.items[0].done_day = gs.clock.day_index;
            }
            const before = digest.stateHash(&gs);
            gs.arena.state = .{};
            var failing = std.testing.FailingAllocator.init(outer.allocator(), .{ .fail_index = failure_index });
            gs.arena.child_allocator = failing.allocator();
            var service: maintenance.HourBook = .{ .alloc = outer.allocator() };
            var repairs: maintenance.HourBook = .{ .alloc = outer.allocator() };
            const result: anyerror!void = switch (action) {
                .weekly => runWeekly(&gs, &service, &repairs),
                .accident => injureTechAtomic(&gs, gs.artillery_formations.get(id).?.tech, 3, "test accident"),
                .queue => blk: {
                    _ = queueRepair(&gs, id) catch |err| break :blk err;
                    break :blk {};
                },
                .completion => blk: {
                    _ = completeJob(&gs, 0) catch |err| break :blk err;
                    break :blk {};
                },
            };
            if (result) |_| break else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(before, digest.stateHash(&gs));
                failed = true;
                gs.arena.child_allocator = outer.allocator();
                gs.arena.state = .{};
                switch (action) {
                    .weekly => try runWeekly(&gs, &service, &repairs),
                    .accident => try injureTechAtomic(&gs, gs.artillery_formations.get(id).?.tech, 3, "test accident"),
                    .queue => _ = try queueRepair(&gs, id),
                    .completion => _ = try completeJob(&gs, 0),
                }
                try std.testing.expect(before != digest.stateHash(&gs));
                if (action == .accident) {
                    const f = gs.artillery_formations.get(id).?;
                    try std.testing.expectEqual(replacement, f.tech);
                    try std.testing.expectEqual(f.placement.company, gs.person(replacement).?.assigned_force);
                }
            }
        }
        try std.testing.expect(failed);
    }
}

test "accident replacement joins an attached formation company from wholly unassigned personnel" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const original = gs.artillery_formations.get(id).?;
    const replacement = try gs.hirePerson("Spare", "Mechanic", .tech_mechanic);
    gs.person(replacement).?.weekly_hours = 100;
    try std.testing.expectEqual(types.ForceId.none, gs.person(replacement).?.assigned_force);
    try std.testing.expectEqual(types.HqId.none, gs.person(replacement).?.posted_hq);
    try maintenance.injureTech(&gs, original.tech, 3, "shared accident");
    try std.testing.expectEqual(person.Status.wounded, gs.person(original.tech).?.status);
    try std.testing.expectEqual(replacement, gs.artillery_formations.get(id).?.tech);
    try std.testing.expectEqual(original.placement.company, gs.person(replacement).?.assigned_force);
    try artillery.validate(&gs);
    try std.testing.expect(operations.serviceCapability(&gs, gs.artillery_formations.getPtr(id).?) != null);
}

test "depot completion debits actual HQ labor with the shared commander repair multiplier" {
    for ([_]commander.Profession{ .paymaster, .chief_engineer }) |profession| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const id = try depotFixtureForTest(&gs);
        gs.commander.?.profession = profession;
        const quote = try repairQuote(&gs, gs.artillery_formations.getPtr(id).?);
        _ = try queueRepair(&gs, id);
        gs.clock.day_index = quote.duration_days;
        gs.bay_jobs.items[0].started_day = 0;
        gs.bay_jobs.items[0].done_day = gs.clock.day_index;
        const before = gs.hqs.get(gs.seat()).?.funds;
        var tries: usize = 0;
        while (!try completeJob(&gs, 0)) : (tries += 1) {
            try std.testing.expect(tries < 100);
            try std.testing.expectEqual(before, gs.hqs.get(gs.seat()).?.funds);
            gs.clock.day_index = gs.bay_jobs.items[0].done_day.?;
        }
        const labor = types.applyBp(quote.labor, commander.costMultBp(gs.commander, .repair));
        try std.testing.expectEqual(before - labor, gs.hqs.get(gs.seat()).?.funds);
        const posting = gs.ledger.transactions.items[gs.ledger.transactions.items.len - 1];
        try std.testing.expectEqual(-labor, posting.amount);
        try std.testing.expectEqual(gs.seat(), posting.hq);
        try std.testing.expectEqual(labor < quote.labor, profession == .chief_engineer);
    }
}

test "maintenance bin loss and repair retain exact magazines and replacement stock" {
    const rng_mod = @import("rng.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, false);
    const f = gs.artillery_formations.getPtr(id).?;
    f.quality = .a;
    const bin = @intFromEnum(rules.Slot.long_tom_bin_1);
    f.slots[bin] = .{ .condition = .damaged, .rounds = 3 };
    var seed: u64 = 0;
    while (true) : (seed += 1) {
        var candidate = rng_mod.Rng.init(seed);
        if (candidate.roll2d6(.maintenance) == 2 and candidate.random(.maintenance).uintLessThan(u32, rules.descriptors.len - 1) == bin - 1) break;
    }
    gs.rng = rng_mod.Rng.init(seed);
    var service: maintenance.HourBook = .{ .alloc = std.testing.allocator };
    defer service.map.deinit(std.testing.allocator);
    var repairs: maintenance.HourBook = .{ .alloc = std.testing.allocator };
    defer repairs.map.deinit(std.testing.allocator);
    try repairs.map.put(std.testing.allocator, f.tech, 0);
    try runWeekly(&gs, &service, &repairs);
    try std.testing.expectEqual(unit.PartCondition.destroyed, f.slots[bin].condition);
    try std.testing.expectEqual(@as(u16, 0), f.slots[bin].rounds);
    try std.testing.expectEqual(@as(?u32, 0), f.last_maintenance_day);
    var loss_log = false;
    for (gs.event_log.items) |entry| if (std.mem.indexOf(u8, entry.text, "lost 3 rounds") != null) {
        loss_log = true;
    };
    try std.testing.expect(loss_log);
    // Directly exercise the weekly field adapter on a prepared view: a local
    // replacement repairs condition only. Remote stock provides no substitute.
    const far = try @import("founding.zig").foundHq(&gs, "Remote", .regional, "skye");
    try gs.addStock(.{ .hq = far }, "artillery_spares", 1);
    const tech = try gs.hirePerson("Replacement", "Mechanic", .tech_mechanic);
    _ = try crew.assignTech(&gs, .{ .formation = id, .person = tech });
    gs.person(tech).?.weekly_hours = 100;
    var field_book: maintenance.HourBook = .{ .alloc = std.testing.allocator };
    defer field_book.map.deinit(std.testing.allocator);
    try prepareFieldRepairs(&gs, f, &field_book);
    try std.testing.expectEqual(unit.PartCondition.destroyed, f.slots[bin].condition);
    try gs.addStock(.{ .hq = gs.seat() }, "artillery_spares", 1);
    try prepareFieldRepairs(&gs, f, &field_book);
    try std.testing.expectEqual(unit.PartCondition.ok, f.slots[bin].condition);
    try std.testing.expectEqual(@as(u16, 0), f.slots[bin].rounds);
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = gs.seat() }, "artillery_spares"));
    try std.testing.expectEqual(@as(u32, 1), gs.stockCount(.{ .hq = far }, "artillery_spares"));
}

test "accidents replace shared conventional and artillery references with one local capacity owner" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    const f = gs.artillery_formations.get(id).?;
    const replacement = try gs.hirePerson("Spare", "Mechanic", .tech_mechanic);
    gs.person(replacement).?.assigned_force = f.placement.company;
    gs.person(replacement).?.weekly_hours = 100;
    const vehicle = try gs.addUnit("SCP-1N");
    try @import("toe.zig").placeUnitInCompanyPool(&gs, vehicle, f.placement.company);
    gs.unit(vehicle).?.tech = f.tech;
    try maintenance.injureTech(&gs, f.tech, 3, "shared accident");
    try std.testing.expectEqual(person.Status.wounded, gs.person(f.tech).?.status);
    try std.testing.expectEqual(replacement, gs.unit(vehicle).?.tech);
    try std.testing.expectEqual(replacement, gs.artillery_formations.get(id).?.tech);
    try std.testing.expectEqual(maintenance.techWeeklyHoursFor(&gs, gs.person(replacement).?, gs.unit(vehicle).?) + techHours(&gs, gs.artillery_formations.getPtr(id).?), maintenance.techWeeklyLoadHours(&gs, replacement));
}
