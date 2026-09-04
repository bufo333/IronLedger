//! Weekly maintenance checks and repair work (Stage 5, ARCH §9.7), on the
//! Stage 9C.2 tech-time budget: every hull needs an assigned tech, every
//! tech has weekly hours, and hulls nobody has hours for roll uncovered.
//! Mirrors MekHQ's maintenance system: tech skill vs. a target number from
//! quality and conditions; failures drift quality A-ward and break parts.
//! Techs get hurt doing it, and free techs are swapped in when they do.

const std = @import("std");
const types = @import("../domain/types.zig");
const unit_mod = @import("../domain/unit.zig");
const part_mod = @import("../domain/part.zig");
const person_mod = @import("../domain/person.zig");
const chassis_mod = @import("../domain/chassis.zig");
const hq_ops = @import("hq_ops.zig");
const GameState = @import("state.zig").GameState;

/// Hours a field repair costs the hull's tech. // TUNE
const hours_damaged_slot = 3;
const hours_destroyed_slot = 5;
const hours_armor_patch = 2;

/// Remaining weekly hours per tech, built lazily as hulls come up.
const HourBook = struct {
    map: std.AutoHashMapUnmanaged(types.PersonId, u32) = .empty,
    alloc: std.mem.Allocator,

    fn spend(self: *HourBook, gs: *GameState, tech: *const person_mod.Person, hours: u32, base_load: u32) !bool {
        const entry = try self.map.getOrPut(self.alloc, tech.id);
        if (!entry.found_existing) entry.value_ptr.* = gs.techHoursAvailable(tech) -| base_load;
        if (entry.value_ptr.* < hours) return false;
        entry.value_ptr.* -= hours;
        return true;
    }
};

fn unitTonnage(u: *const unit_mod.Unit) u8 {
    return if (chassis_mod.find(u.chassis_key)) |d| d.tonnage else 50;
}

/// The hull's tech if assigned and fit for duty today.
fn activeTech(gs: *GameState, u: *const unit_mod.Unit) ?*person_mod.Person {
    const t = gs.person(u.tech) orelse return null;
    return if (t.isAvailable(gs.clock.day_index)) t else null;
}

/// Weekly maintenance: one check per active hull, worked by its tech from
/// their hour budget; no tech (or no hours) → rolls uncovered. // TUNE
pub fn runWeeklyMaintenance(gs: *GameState) !void {
    var book: HourBook = .{ .alloc = std.heap.page_allocator };
    defer book.map.deinit(book.alloc);
    var upkeep_cost: types.CBills = 0;

    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status == .mothballed or u.status == .destroyed or u.status == .repairing or u.status == .refitting) continue;
        if (u.kind == .infantry) continue; // platoons maintain their own kit

        const need_hours = unit_mod.maintenanceHours(u.kind, unitTonnage(u));
        var covered = false;
        var skill: u8 = 7;
        var tech_id: types.PersonId = .none;
        if (activeTech(gs, u)) |t| {
            if (try book.spend(gs, t, need_hours, 0)) {
                covered = true;
                skill = t.skill(unit_mod.techRoleFor(u.kind).?.primarySkill()) orelse 7;
                tech_id = t.id;
            }
        }

        const deployed = gs.deploymentContract(gs.companyOf(u.force)) != null;
        var tn: i32 = 4 + u.quality.maintenanceModifier();
        if (deployed) tn += 1; // field conditions
        if (!covered) tn += 3; // nobody turning wrenches

        const raw = gs.rng.roll2d6(.maintenance);
        const total: i32 = @as(i32, raw) + (5 - @as(i32, skill));

        if (total <= tn - 2) {
            // Clear miss: quality drifts toward A; a snake-eyes week also
            // breaks something (field-fixable or worse).
            const q = @intFromEnum(u.quality);
            if (q > 0) u.quality = @enumFromInt(q - 1);
            if (raw == 2 and u.slots.items.len > 0) {
                const idx = gs.rng.random(.maintenance).uintLessThan(usize, u.slots.items.len);
                const slot = &u.slots.items[idx];
                slot.condition = switch (slot.condition) {
                    .ok => .damaged,
                    .damaged => .destroyed,
                    else => slot.condition,
                };
            }
        } else if (total >= tn + 8) {
            // Exceptional work slowly restores a machine (rare by design).
            const q = @intFromEnum(u.quality);
            if (q < 5) u.quality = @enumFromInt(q + 1);
        }

        // Accidents happen in the hangar (Stage 9C.2): snake-eyes while
        // working a hull, and then only one bad week in six hurts the tech
        // (≈0.5% per hull-week; a 32-hull company sees one every couple of
        // months rather than one a week). // TUNE
        if (covered and raw == 2 and gs.rng.roll2d6(.maintenance) <= 4) try injureTech(gs, tech_id, 5 + gs.rng.roll2d6(.medical), "maintenance accident");

        if (covered) {
            u.last_maintenance_day = gs.clock.day_index;
            upkeep_cost += @divTrunc(u.purchase_price, 2_500); // ~0.17%/month in consumables
        }
    }

    if (upkeep_cost > 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -types.applyBp(upkeep_cost, gs.commanderMultBp(.repair)),
            .category = .maintenance,
            .note = "weekly maintenance consumables",
        });
    }
}

/// A tech goes down: wounded for `days`, and every hull they covered gets a
/// free tech swapped in if one exists — logged either way, surfaced in the
/// end-turn checklist as an open slot otherwise.
pub fn injureTech(gs: *GameState, tech_id: types.PersonId, days: u32, cause: []const u8) !void {
    const t = gs.person(tech_id) orelse return;
    if (t.status != .active) return;
    t.status = .wounded;
    t.medbay_admitted = false; // healing starts when the player admits them
    const company = gs.companyOf(t.assigned_force);
    try gs.log(.medical, .{ .company = company }, "[medbay] {s} {s} injured ({s}) — {d} days", .{ t.first_name, t.last_name, cause, days });

    var swapped: u32 = 0;
    var open: u32 = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.tech != tech_id) continue;
        const role = unit_mod.techRoleFor(u.kind) orelse continue;
        const hours = unit_mod.maintenanceHours(u.kind, unitTonnage(u));
        if (gs.findFreeTech(role, gs.companyOf(u.force), hours)) |replacement| {
            u.tech = replacement;
            swapped += 1;
        } else {
            u.tech = .none;
            open += 1;
        }
    }
    if (swapped + open > 0) {
        try gs.log(.medical, .{ .company = company }, "[roster] {d} hull(s) reassigned to free techs, {d} left without a tech", .{ swapped, open });
    }
}

/// Weekly repair pass: field work by the hull's own tech from their spare
/// hours; depot work becomes a bay job (Stage 9C). Destroyed parts consume
/// spares from the hull's site.
pub fn runWeeklyRepairs(gs: *GameState) !void {
    var depot_ok = false;
    var hqit = gs.hqs.iterator();
    while (hqit.next()) |entry| {
        if (entry.value_ptr.supportsStructuralRepair()) depot_ok = true;
    }
    var book: HourBook = .{ .alloc = std.heap.page_allocator };
    defer book.map.deinit(book.alloc);

    var labor_cost: types.CBills = 0;
    var it = gs.units.iterator();
    while (it.next()) |entry| {
        const u = entry.value_ptr;
        if (u.status == .mothballed or u.status == .destroyed or u.status == .repairing or u.status == .refitting) continue;
        const tech = activeTech(gs, u) orelse continue; // no tech, no repairs
        const base_load = gs.techLoadHours(tech.id);
        const at_home = gs.deploymentContract(gs.companyOf(u.force)) == null;
        const site = gs.siteForForce(u.force);

        for (u.slots.items) |*slot| {
            const tier = unit_mod.repairTier(slot.class, slot.condition) orelse continue;
            switch (tier) {
                .field => switch (slot.condition) {
                    .damaged => if (try book.spend(gs, tech, hours_damaged_slot, base_load)) {
                        slot.condition = .ok;
                        labor_cost += @divTrunc(part_mod.cost(slot.part_key), 20);
                    },
                    .destroyed, .missing => if (gs.stockCount(site, slot.part_key) > 0) {
                        if (try book.spend(gs, tech, hours_destroyed_slot, base_load)) {
                            _ = gs.takeStock(site, slot.part_key, 1);
                            slot.condition = .ok;
                            labor_cost += @divTrunc(part_mod.cost(slot.part_key), 10);
                        }
                    },
                    .ok => {},
                },
                // Structural work is a bay job (Stage 9C): queued once per
                // hull, components taken from the warehouse up front.
                .depot => if (at_home and depot_ok and !hq_ops.hasJobForUnit(gs, u.id)) {
                    _ = hq_ops.queueDepotRepair(gs, u.id) catch false;
                },
            }
        }

        // Armor patching: 15%/week, spares and hours permitting.
        if (u.armor_pct < 100 and gs.stockCount(site, "armor") > 0) {
            if (try book.spend(gs, tech, hours_armor_patch, base_load)) {
                _ = gs.takeStock(site, "armor", 1);
                u.armor_pct = @min(100, u.armor_pct + 15);
                labor_cost += 5_000;
            }
        }
    }

    if (labor_cost > 0) {
        try gs.postTransaction(.{
            .day = gs.clock.day_index,
            .amount = -types.applyBp(labor_cost, gs.commanderMultBp(.repair)),
            .category = .maintenance,
            .note = "repair labor & materials",
        });
    }
}

test "no tech, no maintenance: an unassigned hull rots; an assigned one holds" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs.deinit();
    const uid = try gs.addUnit("SHD-2H");
    gs.unit(uid).?.quality = .f;
    for (0..52) |_| try runWeeklyMaintenance(&gs);
    const neglected = gs.unit(uid).?.quality;
    try std.testing.expect(@intFromEnum(neglected) < @intFromEnum(types.Quality.f));

    var gs2 = GameState.init(std.testing.allocator, .{ .seed = 99 });
    defer gs2.deinit();
    const uid2 = try gs2.addUnit("SHD-2H");
    gs2.unit(uid2).?.quality = .f;
    const tech = try gs2.hirePerson("Clay", "Cluny", .tech_mek);
    try gs2.person(tech).?.skills.put(gs2.allocator(), .tech_mek, 2);
    try gs2.assignSlot(uid2, .tech, tech);
    for (0..52) |_| try runWeeklyMaintenance(&gs2);
    try std.testing.expect(@intFromEnum(gs2.unit(uid2).?.quality) >= @intFromEnum(neglected));
    try std.testing.expect(gs2.ledger.balance() < 0); // consumables were paid for
}

test "tech hours are a budget: too many hulls leave some uncovered" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 100 });
    defer gs.deinit();
    const tech = try gs.hirePerson("Solo", "Tech", .tech_mek);
    // 40h budget, no astechs → 20h effective; an Atlas costs 10h/week.
    var uids: [4]types.UnitId = undefined;
    for (&uids) |*id| {
        id.* = try gs.addUnit("AS7-D");
        try gs.assignSlot(id.*, .tech, tech);
    }
    try std.testing.expectEqual(@as(u32, 40), gs.techLoadHours(tech));
    try std.testing.expectEqual(@as(u32, 20), gs.techHoursAvailable(gs.person(tech).?));
    try runWeeklyMaintenance(&gs);
    var maintained: u32 = 0;
    for (uids) |id| {
        if (gs.unit(id).?.last_maintenance_day != null) maintained += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), maintained);
}

test "an injured tech is swapped for a free one" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 101 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const uid = try gs.addUnit("SHD-2H");
    try gs.assignUnit(uid, co, .none);
    const t1 = try gs.hirePerson("A", "One", .tech_mek);
    const t2 = try gs.hirePerson("B", "Two", .tech_mek);
    gs.person(t1).?.assigned_force = co;
    gs.person(t2).?.assigned_force = co;
    try gs.assignSlot(uid, .tech, t1);

    try injureTech(&gs, t1, 10, "test");
    try std.testing.expectEqual(person_mod.Status.wounded, gs.person(t1).?.status);
    try std.testing.expectEqual(t2, gs.unit(uid).?.tech);
}

test "repairs consume spares; depot work needs the HQ" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7 });
    defer gs.deinit();
    const uid = try gs.addUnit("SHD-2H");
    const u = gs.unit(uid).?;
    const tech = try gs.hirePerson("Clay", "Cluny", .tech_mek);
    try gs.assignSlot(uid, .tech, tech);

    for (u.slots.items) |*slot| {
        if (slot.class == .weapon) {
            slot.condition = .destroyed;
            break;
        }
    }
    u.slots.items[1].condition = .destroyed; // ct.structure

    try runWeeklyRepairs(&gs);
    try std.testing.expect(u.needsDepot());

    _ = try gs.createCommander("T", .LC, .chief_engineer);
    try gs.addSpare("ac5", 1);
    try runWeeklyRepairs(&gs);
    try std.testing.expectEqual(@as(u32, 0), gs.spareCount("ac5"));
    try std.testing.expect(hq_ops.hasJobForUnit(&gs, uid));
    try hq_ops.runDaily(&gs);
    gs.clock.day_index += 30;
    try hq_ops.runDaily(&gs);
    try std.testing.expect(!u.needsDepot());
    for (u.slots.items) |slot| try std.testing.expectEqual(unit_mod.PartCondition.ok, slot.condition);
}
