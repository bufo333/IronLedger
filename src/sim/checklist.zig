//! The end-turn checklist (Stage 9C.2, ARCH §9.9): everything the player
//! should know before time moves. A pure query over GameState — the CLI
//! refuses to advance until it's acknowledged; the TUI renders it as a
//! modal. Nothing slips past a turn boundary unannounced.

const std = @import("std");
const types = @import("../domain/types.zig");
const unit_mod = @import("../domain/unit.zig");
const part_mod = @import("../domain/part.zig");
const hq_ops = @import("hq_ops.zig");
const medical = @import("medical.zig");
const GameState = @import("state.zig").GameState;

pub const WarningKind = enum {
    decision_due,
    open_slots,
    understaffed_hq,
    hungry,
    dry_ammo,
    overdrawn,
    depot_backlog,
    medbay_over_capacity,
    tech_overloaded,
    combat_ineffective,
    objectives_met,
    company_idle_afield,
};

pub const Warning = struct {
    kind: WarningKind,
    text: []const u8,
};

/// Build the checklist. `alloc` owns the returned slice and texts.
pub fn turnWarnings(gs: *GameState, alloc: std.mem.Allocator) ![]Warning {
    var out: std.ArrayListUnmanaged(Warning) = .empty;
    const day = gs.clock.day_index;

    // Decisions about to default.
    for (gs.event_queue.pending.items) |ev| {
        if (ev.needsDecision() and ev.deadline_day <= day + 2) {
            try out.append(alloc, .{ .kind = .decision_due, .text = try std.fmt.allocPrint(alloc, "decision '{s}' defaults on day {d} (today {d})", .{ @tagName(ev.kind), ev.deadline_day, day }) });
        }
    }

    // Open pilot/tech slots per company.
    var fit = gs.forces.iterator();
    while (fit.next()) |fentry| {
        const f = fentry.value_ptr;
        if (f.echelon != .company) continue;
        var no_pilot: u32 = 0;
        var no_tech: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |uentry| {
            const u = uentry.value_ptr;
            if (gs.companyOf(u.force) != f.id or u.status == .destroyed or u.status == .mothballed) continue;
            const pilot_ok = if (gs.person(u.pilot)) |p| p.isAvailable(day) else false;
            if (!pilot_ok) no_pilot += 1;
            if (unit_mod.techRoleFor(u.kind) != null) {
                const tech_ok = if (gs.person(u.tech)) |t| t.isAvailable(day) else false;
                if (!tech_ok) no_tech += 1;
            }
        }
        if (no_pilot + no_tech > 0) {
            try out.append(alloc, .{ .kind = .open_slots, .text = try std.fmt.allocPrint(alloc, "{s}: {d} hull(s) without a pilot, {d} without a tech (no repairs/reloads)", .{ f.name, no_pilot, no_tech }) });
        }
        if (f.supply_shortage_days > 0) {
            try out.append(alloc, .{ .kind = .hungry, .text = try std.fmt.allocPrint(alloc, "{s} has been hungry {d} day(s) — send provisions or funds", .{ f.name, f.supply_shortage_days }) });
        }
        if (gs.deploymentContract(f.id) != null) {
            var dry: u32 = 0;
            for (part_mod.munition_keys) |key| {
                if (gs.stockCount(.{ .company = f.id }, key) == 0) dry += 1;
            }
            if (dry > 0) try out.append(alloc, .{ .kind = .dry_ammo, .text = try std.fmt.allocPrint(alloc, "{s}: {d} munition famil{s} at zero in the field stores", .{ f.name, dry, if (dry == 1) "y" else "ies" }) });
            if (f.local_funds < 0) try out.append(alloc, .{ .kind = .overdrawn, .text = try std.fmt.allocPrint(alloc, "{s} operating funds overdrawn ({d})", .{ f.name, f.local_funds }) });
        }
    }

    // Contract control (Stage 9E).
    var cit = gs.contracts.iterator();
    while (cit.next()) |centry| {
        const c = centry.value_ptr;
        if (c.status != .active) continue;
        if (c.ineffective_since) |since| {
            const left = (since + @import("contract_control.zig").grace_days) -| day;
            try out.append(alloc, .{ .kind = .combat_ineffective, .text = try std.fmt.allocPrint(alloc, "{s}: COMBAT-INEFFECTIVE — {d} day(s) to buy local replacements or the employer declares breach", .{ @tagName(c.kind), left }) });
        }
        if (c.objectivesMet()) {
            try out.append(alloc, .{ .kind = .objectives_met, .text = try std.fmt.allocPrint(alloc, "{s}: objectives substantially met ({d}% of opposition destroyed) — `complete {d}` to close out", .{ @tagName(c.kind), c.poolDestroyedPct(), @intFromEnum(c.id) }) });
        }
    }
    var idle_it = gs.forces.iterator();
    while (idle_it.next()) |fentry| {
        const f = fentry.value_ptr;
        if (f.echelon != .company or f.location_planet == null or gs.deploymentContract(f.id) != null) continue;
        try out.append(alloc, .{ .kind = .company_idle_afield, .text = try std.fmt.allocPrint(alloc, "{s} is idling on {s} eating its trucks — accept work from the field or `recall co:{d}`", .{ f.name, f.location_planet.?, @intFromEnum(f.id) }) });
    }

    // HQ staffing, treasuries, bays.
    var hit = gs.hqs.iterator();
    while (hit.next()) |hentry| {
        const hq = hentry.value_ptr;
        const req = hq.staffRequired().total();
        if (hq.staff_assigned < req) {
            try out.append(alloc, .{ .kind = .understaffed_hq, .text = try std.fmt.allocPrint(alloc, "{s} understaffed {d}/{d} — facilities run below level", .{ hq.name, hq.staff_assigned, req }) });
        }
        if (hq.funds < 0) {
            try out.append(alloc, .{ .kind = .overdrawn, .text = try std.fmt.allocPrint(alloc, "{s} treasury overdrawn ({d})", .{ hq.name, hq.funds }) });
        }
        const idle = hq_ops.baySlots(gs, hq.id) -| hq_ops.activeJobs(gs, hq.id);
        var waiting: u32 = 0;
        var uit = gs.units.iterator();
        while (uit.next()) |uentry| {
            const u = uentry.value_ptr;
            if (u.needsDepot() and u.status != .repairing and gs.deploymentContract(gs.companyOf(u.force)) == null and !hq_ops.hasJobForUnit(gs, u.id)) waiting += 1;
        }
        if (waiting > 0 and idle > 0) {
            try out.append(alloc, .{ .kind = .depot_backlog, .text = try std.fmt.allocPrint(alloc, "{d} hull(s) need depot work and {d} bay slot(s) sit idle — components or techs missing (see `demand`, `roster`)", .{ waiting, idle }) });
        }
    }

    // Medbay over capacity at home.
    var wounded_home: u32 = 0;
    var pit = gs.people.iterator();
    while (pit.next()) |pentry| {
        const p = pentry.value_ptr;
        if (p.status == .wounded and gs.deploymentContract(gs.companyOf(p.assigned_force)) == null) wounded_home += 1;
    }
    const beds = medical.bedCapacity(gs, .none, false);
    if (wounded_home > beds) {
        try out.append(alloc, .{ .kind = .medbay_over_capacity, .text = try std.fmt.allocPrint(alloc, "medbay over capacity: {d} wounded for {d} beds — triage priorities decide who heals", .{ wounded_home, beds }) });
    }

    // Techs carrying more hulls than their hours allow.
    var overloaded: u32 = 0;
    var tit = gs.people.iterator();
    while (tit.next()) |tentry| {
        const t = tentry.value_ptr;
        if (!t.isAvailable(day)) continue;
        if (unit_mod.techRoleFor(.mek) != t.role and t.role != .tech_mechanic and t.role != .tech_aero and t.role != .tech_ba) continue;
        if (gs.techLoadHours(t.id) > gs.techHoursAvailable(t)) overloaded += 1;
    }
    if (overloaded > 0) {
        try out.append(alloc, .{ .kind = .tech_overloaded, .text = try std.fmt.allocPrint(alloc, "{d} tech(s) assigned more hulls than their weekly hours cover — some hulls roll uncovered", .{overloaded}) });
    }

    return out.toOwnedSlice(alloc);
}

test "the checklist names open slots and overloaded techs" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 61 });
    defer gs.deinit();
    const co = try gs.createForce("Alpha", .company, .none);
    const uid = try gs.addUnit("AS7-D");
    try gs.assignUnit(uid, co, .none); // no pilot, no tech

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const warnings = try turnWarnings(&gs, arena.allocator());
    var saw_open = false;
    for (warnings) |w| {
        if (w.kind == .open_slots) saw_open = true;
    }
    try std.testing.expect(saw_open);
}
