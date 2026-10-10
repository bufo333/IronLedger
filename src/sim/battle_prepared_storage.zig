//! Explicit storage ownership for one prepared engagement.
//! No MekHQ counterpart: atomic engagement policy (docs/p2-artillery-battle-design.md).

const std = @import("std");
const state = @import("state.zig");
const GameState = state.GameState;
const person = @import("../domain/person.zig");
const unit = @import("../domain/unit.zig");
const report = @import("../domain/battle_report.zig");
const events = @import("../domain/events.zig");

fn copiedList(alloc: std.mem.Allocator, original: anytype) !@TypeOf(original) {
    var result: @TypeOf(original) = .empty;
    try result.appendSlice(alloc, original.items);
    return result;
}

fn copyPerson(alloc: std.mem.Allocator, p: person.Person) !person.Person {
    var result = p;
    result.skills = try p.skills.clone(alloc);
    result.injuries = try copiedList(alloc, p.injuries);
    result.awards = try copiedList(alloc, p.awards);
    result.abilities = try copiedList(alloc, p.abilities);
    return result;
}

fn copyUnit(alloc: std.mem.Allocator, u: unit.Unit) !unit.Unit {
    var result = u;
    result.slots = try copiedList(alloc, u.slots);
    return result;
}

/// Isolate every mutable container reached by engagement resolution. Immutable
/// catalogue keys, identity text and existing report payloads remain borrowed:
/// resolution neither replaces nor frees them. Lifecycle owners are never borrowed.
pub fn isolate(view: *GameState, source: *const GameState) !void {
    const alloc = view.allocator();
    view.lifecycle_arena = null;
    view.faction_roster_lifecycle_arena = null;
    view.merc_company_roster_lifecycle_arena = null;
    view.people = try source.people.clone(alloc);
    for (view.people.values()) |*p| p.* = try copyPerson(alloc, p.*);
    view.units = try source.units.clone(alloc);
    for (view.units.values()) |*u| u.* = try copyUnit(alloc, u.*);
    view.held_hulls = try copiedList(alloc, source.held_hulls);
    for (view.held_hulls.items) |*h| h.unit = try copyUnit(alloc, h.unit);
    view.forces = try source.forces.clone(alloc);
    for (view.forces.values()) |*f| {
        f.stock = try f.stock.clone(alloc);
        f.units = try copiedList(alloc, f.units);
        f.children = try copiedList(alloc, f.children);
    }
    view.hqs = try source.hqs.clone(alloc);
    for (view.hqs.values()) |*h| {
        h.stock = try h.stock.clone(alloc);
        h.facilities = try copiedList(alloc, h.facilities);
        h.projects = try copiedList(alloc, h.projects);
    }
    view.contracts = try source.contracts.clone(alloc);
    for (view.contracts.values()) |*c| {
        c.operations = try copiedList(alloc, c.operations);
        for (c.operations.items) |*op| {
            op.tasks = try copiedList(alloc, op.tasks);
            op.interventions = try copiedList(alloc, op.interventions);
        }
        c.actor_ids = try copiedList(alloc, c.actor_ids);
        c.rival_ids = try copiedList(alloc, c.rival_ids);
        c.officer_arc_ids = try copiedList(alloc, c.officer_arc_ids);
    }
    view.hull_instances = try source.hull_instances.clone(alloc);
    for (view.hull_instances.values()) |*h| h.loadout = try copiedList(alloc, h.loadout);
    view.faction_rosters = try source.faction_rosters.clone(alloc);
    for (view.faction_rosters.values()) |*pool| pool.* = try copiedList(alloc, pool.*);
    view.merc_company_rosters = try source.merc_company_rosters.clone(alloc);
    for (view.merc_company_rosters.values()) |*pool| pool.* = try copiedList(alloc, pool.*);
    view.artillery_formations = try source.artillery_formations.clone(alloc);
    view.spare_parts = try source.spare_parts.clone(alloc);
    view.faction_standing = try source.faction_standing.clone(alloc);
    view.event_memory = try source.event_memory.clone(alloc);
    view.event_queue.pending = try copiedList(alloc, source.event_queue.pending);
    view.battle_reports.kept = try copiedList(alloc, source.battle_reports.kept);
    view.event_log = try copiedList(alloc, source.event_log);
    view.ledger.transactions = try copiedList(alloc, source.ledger.transactions);
    view.part_orders = try copiedList(alloc, source.part_orders);
    view.unit_transfers = try copiedList(alloc, source.unit_transfers);
    view.hull_combat_records = try copiedList(alloc, source.hull_combat_records);
    view.hull_ownership_history = try copiedList(alloc, source.hull_ownership_history);
    view.maintenance_entries = try copiedList(alloc, source.maintenance_entries);
    view.market_listings = try copiedList(alloc, source.market_listings);
    view.bay_jobs = try copiedList(alloc, source.bay_jobs);
    view.refit_plans = try copiedList(alloc, source.refit_plans);
    for (view.refit_plans.items) |*plan| plan.ops = try copiedList(alloc, plan.ops);
}

fn destinationList(alloc: std.mem.Allocator, existing: anytype, count: usize) !@TypeOf(existing.*) {
    try existing.ensureTotalCapacity(alloc, count);
    return existing.*;
}

fn publishList(destination: anytype, source: anytype) void {
    destination.clearRetainingCapacity();
    destination.appendSliceAssumeCapacity(source.items);
}

fn publishMap(destination: anytype, source: anytype) void {
    destination.clearRetainingCapacity();
    for (source.keys(), source.values()) |key, value| destination.putAssumeCapacity(key, value);
}

fn ownedText(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    return alloc.dupe(u8, value);
}

fn promotedPerson(alloc: std.mem.Allocator, value: person.Person) !person.Person {
    var result = try copyPerson(alloc, value);
    result.first_name = try ownedText(alloc, value.first_name);
    result.last_name = try ownedText(alloc, value.last_name);
    if (value.callsign) |name| result.callsign = try ownedText(alloc, name);
    result.faction = try ownedText(alloc, value.faction);
    for (result.awards.items) |*name| name.* = try ownedText(alloc, name.*);
    for (result.abilities.items) |*name| name.* = try ownedText(alloc, name.*);
    return result;
}

fn promotedUnit(alloc: std.mem.Allocator, value: unit.Unit) !unit.Unit {
    var result = try copyUnit(alloc, value);
    result.chassis_key = try ownedText(alloc, value.chassis_key);
    if (value.name) |name| result.name = try ownedText(alloc, name);
    for (result.slots.items) |*slot| {
        slot.slot_key = try ownedText(alloc, slot.slot_key);
        slot.part_key = try ownedText(alloc, slot.part_key);
    }
    return result;
}

fn promotedReport(alloc: std.mem.Allocator, value: report.BattleReport) !report.BattleReport {
    var result = value;
    result.kind = try ownedText(alloc, value.kind);
    result.enemy_key = try ownedText(alloc, value.enemy_key);
    result.scenario = try ownedText(alloc, value.scenario);
    result.terrain = try ownedText(alloc, value.terrain);
    result.weather = try ownedText(alloc, value.weather);
    result.edge_spent_by = try ownedText(alloc, value.edge_spent_by);
    result.command_rights = try ownedText(alloc, value.command_rights);
    result.operation = try ownedText(alloc, value.operation);
    result.operation_interventions = try ownedText(alloc, value.operation_interventions);
    const hits = try alloc.dupe(report.HullHit, value.hulls);
    for (hits) |*hit| {
        hit.chassis_key = try ownedText(alloc, hit.chassis_key);
        hit.chassis_name = try ownedText(alloc, hit.chassis_name);
        if (hit.slot) |slot| hit.slot = try ownedText(alloc, slot);
        hit.slot_part = try ownedText(alloc, hit.slot_part);
        hit.crew_name = try ownedText(alloc, hit.crew_name);
    }
    result.hulls = hits;
    const ammo = try alloc.dupe(report.AmmoLine, value.ammo);
    for (ammo) |*line| line.key = try ownedText(alloc, line.key);
    result.ammo = ammo;
    result.salvage.items = try ownedText(alloc, value.salvage.items);
    const candidates = try alloc.dupe(report.SalvageCandidate, value.salvage.candidates);
    for (candidates) |*candidate| {
        candidate.key = try ownedText(alloc, candidate.key);
        candidate.name = try ownedText(alloc, candidate.name);
    }
    result.salvage.candidates = candidates;
    const tasks = try alloc.dupe(report.TaskedLance, value.tasks);
    for (tasks) |*task| {
        task.lance_name = try ownedText(alloc, task.lance_name);
        task.note = try ownedText(alloc, task.note);
    }
    result.tasks = tasks;
    if (result.artillery) |*a| {
        a.catalogue_key = try ownedText(alloc, a.catalogue_key);
        a.catalogue_name = try ownedText(alloc, a.catalogue_name);
        for (&a.seats) |*seat| seat.name = try ownedText(alloc, seat.name);
    }
    return result;
}

fn promotedEvent(alloc: std.mem.Allocator, value: events.Event) !events.Event {
    var result = value;
    const options = try alloc.dupe(events.Option, value.options);
    for (options) |*option| {
        option.label = try ownedText(alloc, option.label);
        const effects = try alloc.dupe(events.Effect, option.effects);
        for (effects) |*effect| if (effect.* == .field_stock) {
            effect.field_stock.key = try ownedText(alloc, effect.field_stock.key);
        };
        option.effects = effects;
    }
    result.options = options;
    return result;
}

/// Prepared scalar/entity values live in operation storage. Existing nested
/// destinations retain their campaign buffers; only new retained payloads allocate
/// campaign storage. Publication copies into those destinations without allocation.
pub const Publication = struct {
    values: GameState,

    pub fn prepare(live: *GameState, staged: *GameState, scratch: std.mem.Allocator) !Publication {
        const alloc = live.allocator();
        var values = staged.*;
        values.people = try staged.people.clone(scratch);
        try live.people.ensureTotalCapacity(alloc, staged.people.count());
        for (values.people.values()) |*p| {
            if (live.person(p.id)) |old| {
                p.skills = old.skills;
                p.injuries = try destinationList(alloc, &old.injuries, p.injuries.items.len);
                p.awards = try destinationList(alloc, &old.awards, p.awards.items.len);
                p.abilities = old.abilities;
            } else p.* = try promotedPerson(alloc, p.*);
        }
        values.units = try staged.units.clone(scratch);
        try live.units.ensureTotalCapacity(alloc, staged.units.count());
        for (values.units.values()) |*u| {
            if (live.unit(u.id)) |old| {
                u.slots = try destinationList(alloc, &old.slots, u.slots.items.len);
            } else u.* = try promotedUnit(alloc, u.*);
        }
        values.held_hulls = try copiedList(scratch, staged.held_hulls);
        for (values.held_hulls.items) |*held| {
            const existing = for (live.held_hulls.items) |*old| {
                if (old.unit.id == held.unit.id) break old;
            } else null;
            if (existing) |old| {
                held.unit.slots = try destinationList(alloc, &old.unit.slots, held.unit.slots.items.len);
            } else held.unit = try promotedUnit(alloc, held.unit);
        }
        try live.held_hulls.ensureTotalCapacity(alloc, values.held_hulls.items.len);
        values.forces = try staged.forces.clone(scratch);
        for (values.forces.values()) |*f| {
            const old = live.forces.getPtr(f.id) orelse return error.UnknownForce;
            f.stock = old.stock;
            try old.stock.ensureTotalCapacity(alloc, staged.forces.getPtr(f.id).?.stock.count());
            f.stock = old.stock;
            f.units = try destinationList(alloc, &old.units, f.units.items.len);
            f.children = old.children;
        }
        values.hqs = try staged.hqs.clone(scratch);
        for (values.hqs.values()) |*h| {
            const old = live.hqs.getPtr(h.id) orelse return error.UnknownHq;
            try old.stock.ensureTotalCapacity(alloc, h.stock.count());
            h.stock = old.stock;
            h.facilities = old.facilities;
            h.projects = old.projects;
        }
        values.contracts = try staged.contracts.clone(scratch);
        for (values.contracts.values()) |*c| {
            const old = live.contracts.getPtr(c.id) orelse return error.UnknownContract;
            if (c.operations.items.len != old.operations.items.len) return error.CorruptSave;
            c.operations = try copiedList(scratch, c.operations);
            for (c.operations.items, old.operations.items) |*op, old_op| {
                op.tasks = old_op.tasks;
                op.interventions = old_op.interventions;
            }
            c.actor_ids = old.actor_ids;
            c.rival_ids = old.rival_ids;
            c.officer_arc_ids = old.officer_arc_ids;
        }
        values.hull_instances = try staged.hull_instances.clone(scratch);
        try live.hull_instances.ensureTotalCapacity(alloc, staged.hull_instances.count());
        for (values.hull_instances.values()) |*h| {
            if (live.hull_instances.getPtr(h.id)) |old| {
                h.loadout = old.loadout;
            } else {
                h.loadout = try copiedList(alloc, h.loadout);
                h.base_key = try ownedText(alloc, h.base_key);
                if (h.name) |name| h.name = try ownedText(alloc, name);
                if (h.nickname) |name| h.nickname = try ownedText(alloc, name);
            }
        }
        values.faction_rosters = try staged.faction_rosters.clone(scratch);
        try live.faction_rosters.ensureTotalCapacity(alloc, staged.faction_rosters.count());
        for (values.faction_rosters.keys(), values.faction_rosters.values()) |key, *pool| {
            if (live.faction_rosters.getPtr(key)) |old| {
                pool.* = try destinationList(alloc, old, pool.items.len);
            } else pool.* = try copiedList(alloc, pool.*);
        }
        values.merc_company_rosters = try staged.merc_company_rosters.clone(scratch);
        try live.merc_company_rosters.ensureTotalCapacity(alloc, staged.merc_company_rosters.count());
        for (values.merc_company_rosters.keys(), values.merc_company_rosters.values()) |key, *pool| {
            if (live.merc_company_rosters.getPtr(key)) |old| {
                pool.* = try destinationList(alloc, old, pool.items.len);
            } else pool.* = try copiedList(alloc, pool.*);
        }
        values.event_queue.pending = try copiedList(scratch, staged.event_queue.pending);
        for (values.event_queue.pending.items) |*event| {
            if (live.event_queue.find(event.id) == null) event.* = try promotedEvent(alloc, event.*);
        }
        values.battle_reports.kept = try copiedList(scratch, staged.battle_reports.kept);
        for (values.battle_reports.kept.items) |*battle| {
            if (live.battle_reports.find(battle.id) == null) battle.* = try promotedReport(alloc, battle.*);
        }
        values.event_log = try copiedList(scratch, staged.event_log);
        for (values.event_log.items[live.event_log.items.len..]) |*entry| entry.text = try ownedText(alloc, entry.text);
        values.ledger.transactions = try copiedList(scratch, staged.ledger.transactions);
        for (values.ledger.transactions.items[live.ledger.transactions.items.len..]) |*txn| txn.note = try ownedText(alloc, txn.note);
        values.hull_ownership_history = try copiedList(scratch, staged.hull_ownership_history);
        for (values.hull_ownership_history.items[live.hull_ownership_history.items.len..]) |*interval| interval.prior_owner_key = try ownedText(alloc, interval.prior_owner_key);
        values.maintenance_entries = try copiedList(scratch, staged.maintenance_entries);
        for (values.maintenance_entries.items[live.maintenance_entries.items.len..]) |*entry| entry.description = try ownedText(alloc, entry.description);
        values.faction_standing = try staged.faction_standing.clone(scratch);
        for (values.faction_standing.keys()) |*key| {
            if (!live.faction_standing.contains(key.*)) key.* = try ownedText(alloc, key.*);
        }
        values.refit_plans = try copiedList(scratch, staged.refit_plans);
        for (values.refit_plans.items) |*plan| {
            const original = live.refitPlanFor(plan.unit) orelse return error.CorruptSave;
            plan.ops = original.ops;
        }
        try live.artillery_formations.ensureTotalCapacity(alloc, staged.artillery_formations.count());
        try live.spare_parts.ensureTotalCapacity(alloc, staged.spare_parts.count());
        try live.faction_standing.ensureTotalCapacity(alloc, staged.faction_standing.count());
        try live.event_memory.ensureTotalCapacity(alloc, staged.event_memory.count());
        try live.event_queue.pending.ensureTotalCapacity(alloc, staged.event_queue.pending.items.len);
        try live.battle_reports.kept.ensureTotalCapacity(alloc, staged.battle_reports.kept.items.len);
        try live.event_log.ensureTotalCapacity(alloc, staged.event_log.items.len);
        try live.ledger.transactions.ensureTotalCapacity(alloc, staged.ledger.transactions.items.len);
        try live.part_orders.ensureTotalCapacity(alloc, staged.part_orders.items.len);
        try live.unit_transfers.ensureTotalCapacity(alloc, staged.unit_transfers.items.len);
        try live.hull_combat_records.ensureTotalCapacity(alloc, staged.hull_combat_records.items.len);
        try live.hull_ownership_history.ensureTotalCapacity(alloc, staged.hull_ownership_history.items.len);
        try live.maintenance_entries.ensureTotalCapacity(alloc, staged.maintenance_entries.items.len);
        try live.market_listings.ensureTotalCapacity(alloc, staged.market_listings.items.len);
        try live.bay_jobs.ensureTotalCapacity(alloc, staged.bay_jobs.items.len);
        try live.refit_plans.ensureTotalCapacity(alloc, staged.refit_plans.items.len);
        return .{ .values = values };
    }

    /// Publish the validated engagement. Every destination and identity is
    /// prepared, all retained payloads are campaign-owned, and streams are copied.
    pub fn commit(self: *Publication, live: *GameState, staged: *const GameState) void {
        for (self.values.people.values(), staged.people.values()) |*p, source| {
            if (!live.people.contains(p.id)) continue;
            publishList(&p.injuries, source.injuries);
            publishList(&p.awards, source.awards);
        }
        publishMap(&live.people, self.values.people);
        for (self.values.units.values(), staged.units.values()) |*u, source| {
            if (live.units.contains(u.id)) publishList(&u.slots, source.slots);
        }
        publishMap(&live.units, self.values.units);
        for (self.values.held_hulls.items, staged.held_hulls.items) |*held, source| {
            if (live.heldHull(held.unit.id) != null) publishList(&held.unit.slots, source.unit.slots);
        }
        publishList(&live.held_hulls, self.values.held_hulls);
        for (self.values.forces.values(), staged.forces.values()) |*f, source| {
            publishMap(&f.stock, source.stock);
            publishList(&f.units, source.units);
            live.forces.getPtr(f.id).?.* = f.*;
        }
        for (self.values.hqs.values(), staged.hqs.values()) |*h, source| {
            publishMap(&h.stock, source.stock);
            live.hqs.getPtr(h.id).?.* = h.*;
        }
        for (self.values.contracts.values()) |c| {
            const destination = live.contracts.getPtr(c.id).?;
            var value = c;
            publishList(&destination.operations, c.operations);
            value.operations = destination.operations;
            destination.* = value;
        }
        publishMap(&live.hull_instances, self.values.hull_instances);
        for (self.values.faction_rosters.values(), staged.faction_rosters.values()) |*pool, source| publishList(pool, source);
        publishMap(&live.faction_rosters, self.values.faction_rosters);
        for (self.values.merc_company_rosters.values(), staged.merc_company_rosters.values()) |*pool, source| publishList(pool, source);
        publishMap(&live.merc_company_rosters, self.values.merc_company_rosters);
        publishMap(&live.artillery_formations, self.values.artillery_formations);
        publishMap(&live.spare_parts, self.values.spare_parts);
        publishMap(&live.faction_standing, self.values.faction_standing);
        publishMap(&live.event_memory, self.values.event_memory);
        publishList(&live.event_queue.pending, self.values.event_queue.pending);
        publishList(&live.battle_reports.kept, self.values.battle_reports.kept);
        publishList(&live.event_log, self.values.event_log);
        publishList(&live.ledger.transactions, self.values.ledger.transactions);
        publishList(&live.part_orders, self.values.part_orders);
        publishList(&live.unit_transfers, self.values.unit_transfers);
        publishList(&live.hull_combat_records, self.values.hull_combat_records);
        publishList(&live.hull_ownership_history, self.values.hull_ownership_history);
        publishList(&live.maintenance_entries, self.values.maintenance_entries);
        publishList(&live.market_listings, self.values.market_listings);
        publishList(&live.bay_jobs, self.values.bay_jobs);
        publishList(&live.refit_plans, self.values.refit_plans);
        live.rng = self.values.rng;
        live.funds = self.values.funds;
        live.reputation = self.values.reputation;
        live.stats = self.values.stats;
        live.event_queue.next_id = self.values.event_queue.next_id;
        live.next_battle_id = self.values.next_battle_id;
        live.next_person_id = self.values.next_person_id;
        live.next_unit_id = self.values.next_unit_id;
        live.next_hull_instance_id = self.values.next_hull_instance_id;
        live.next_listing_id = self.values.next_listing_id;
    }
};

test "engagement isolation owns nested skills injuries slots stocks and roster lists" {
    const types = @import("../domain/types.zig");
    const digest = @import("digest.zig");
    var live = GameState.init(std.testing.allocator, .{});
    defer live.deinit();
    const pid = try live.hirePerson("Local", "Crew", .vehicle_crew);
    const uid = try live.addUnit("SCP-1N");
    const force = try live.createForce("Alpha", .company, .none);
    try live.addStock(.{ .company = force }, "armor", 10);
    const pool = try live.faction_rosters.getOrPut(live.allocator(), "DC");
    pool.value_ptr.* = .empty;
    try pool.value_ptr.append(live.allocator(), @enumFromInt(1));
    const before = digest.stateHash(&live);
    var view = live;
    view.arena = std.heap.ArenaAllocator.init(live.scratch());
    defer view.deinit();
    try isolate(&view, &live);
    try view.person(pid).?.skills.put(view.allocator(), .driving_vee, 1);
    try view.person(pid).?.injuries.append(view.allocator(), .{ .location = .head, .severity = 2, .incurred_day = 0 });
    view.unit(uid).?.slots.items[0].condition = .destroyed;
    view.forces.getPtr(force).?.stock.getPtr("armor").?.* = 0;
    try view.faction_rosters.getPtr("DC").?.append(view.allocator(), @as(types.HullInstanceId, @enumFromInt(2)));
    try std.testing.expectEqual(before, digest.stateHash(&live));
}

test "publication retains new person and report payloads after scratch destruction" {
    const preparation = @import("battle_preparation.zig");
    var live = GameState.init(std.testing.allocator, .{});
    defer live.deinit();
    const pid = try live.hirePerson("Local", "Crew", .vehicle_crew);
    var work = try preparation.Engagement.init(&live, live.scratch());
    const staged = &work.view;
    const prisoner = try staged.hirePerson("Captured", "Crew", .vehicle_crew);
    const captured_unit = try staged.addUnit("SCP-1N");
    try staged.person(pid).?.injuries.append(staged.allocator(), .{ .location = .head, .severity = 2, .incurred_day = 0 });
    try staged.battle_reports.record(staged.allocator(), .{
        .id = staged.nextBattleId(),
        .day = 0,
        .contract = .none,
        .company = .none,
        .kind = try staged.allocator().dupe(u8, "retained kind"),
        .enemy_key = "DC",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .victory,
    });
    var publication = try work.prepare(&live);
    publication.commit(&live, staged);
    work.deinit();
    try std.testing.expectEqualStrings("Captured", live.person(prisoner).?.first_name);
    try std.testing.expectEqualStrings("SCP-1N", live.unit(captured_unit).?.chassis_key);
    try std.testing.expect(live.unit(captured_unit).?.slots.items[0].slot_key.len > 0);
    try std.testing.expectEqual(@as(usize, 1), live.person(pid).?.injuries.items.len);
    try std.testing.expectEqualStrings("retained kind", live.battle_reports.kept.items[0].kind);
}
