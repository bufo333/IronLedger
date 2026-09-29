//! Refit: MekLab installation validation and plan application (ARCH §4).
//! MekHQ counterpart: MegaMekLab; see docs/mekhq-map.md.

const std = @import("std");
const types = @import("../domain/types.zig");
const meklab = @import("../domain/meklab.zig");
const chassis_mod = @import("../domain/chassis.zig");
const part_mod = @import("../domain/part.zig");
const state_mod = @import("state.zig");
const GameState = state_mod.GameState;
const RefitPlan = state_mod.RefitPlan;
const hq_ops = @import("hq_ops.zig");
const posture = @import("posture.zig");
const tuning = @import("../domain/tuning.zig").t;
const commands = @import("commands.zig");

/// The hull's mounted items with a plan's edits applied (what the lab
/// validates). `alloc` owns the result.
pub fn labItems(gs: *GameState, unit_id: types.UnitId, alloc: std.mem.Allocator) ![]meklab.Item {
    const u = gs.unit(unit_id) orelse return &.{};
    var out: std.ArrayListUnmanaged(meklab.Item) = .empty;
    const plan = gs.refitPlanFor(unit_id);
    for (u.slots.items) |s| {
        if (s.class == .structure) continue;
        if (plan) |p| {
            var removed = false;
            for (p.ops.items) |op| {
                if (op == .remove and std.mem.eql(u8, op.remove, s.slot_key)) removed = true;
            }
            if (removed) continue;
        }
        const loc = meklab.parseLocation(s.slot_key) orelse continue;
        try out.append(alloc, .{ .location = loc, .part_key = s.part_key });
    }
    if (plan) |p| {
        for (p.ops.items) |op| {
            if (op == .install) try out.append(alloc, op.install);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The rules' verdict on putting `part_key` at `loc` on top of the
/// hull's current plan (the Lab's location picker and the commit share it).
pub fn tryInstall(gs: *GameState, alloc: std.mem.Allocator, unit_id: types.UnitId, loc: meklab.Location, part_key: []const u8) !meklab.Report {
    const u = gs.unit(unit_id) orelse return error.UnknownUnit;
    const design = chassis_mod.find(u.chassis_key) orelse return error.UnknownChassis;
    const base = try labItems(gs, unit_id, alloc);
    var items = try alloc.alloc(meklab.Item, base.len + 1);
    @memcpy(items[0..base.len], base);
    items[base.len] = .{ .location = loc, .part_key = part_key };
    return meklab.validate(design, items, alloc);
}

/// Apply a committed plan to the hull: removed mounts come off (and
/// return to the site's stock), installs become new slots.
///
/// Prepare/commit split (rule 12, C5q): all fallible allocations complete
/// before any slot mutation so a partial failure leaves the hull unchanged.
pub fn applyRefit(gs: *GameState, plan: *const RefitPlan, site: types.Site) !void {
    const u = gs.unit(plan.unit) orelse return;
    const alloc = gs.allocator();

    // ---- Prepare ----
    // Count installs and reserve slot capacity upfront.
    var n_installs: usize = 0;
    for (plan.ops.items) |op| if (op == .install) {
        n_installs += 1;
    };
    try u.slots.ensureUnusedCapacity(alloc, n_installs);

    // Reserve stock-map capacity for every ok-condition removal.
    for (plan.ops.items) |op| {
        if (op != .remove) continue;
        for (u.slots.items) |s| {
            if (std.mem.eql(u8, s.slot_key, op.remove) and s.condition == .ok) {
                const dest_map = gs.stockMap(site) orelse break;
                try dest_map.ensureUnusedCapacity(alloc, 1);
                break;
            }
        }
    }

    // Pre-allocate install slot_keys accounting for which slots survive the
    // removes in this plan.  Simulate the remove ops on an index list (no
    // mutation) to determine post-remove numbering, then pre-alloc each key.
    var scratch = std.heap.ArenaAllocator.init(gs.scratch());
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Build a list of slot indices that survive all removes.
    var surviving = try std.ArrayListUnmanaged(usize).initCapacity(sa, u.slots.items.len);
    for (0..u.slots.items.len) |idx| surviving.appendAssumeCapacity(idx);
    for (plan.ops.items) |op| {
        if (op != .remove) continue;
        for (surviving.items, 0..) |slot_idx, ri| {
            if (std.mem.eql(u8, u.slots.items[slot_idx].slot_key, op.remove)) {
                _ = surviving.swapRemove(ri);
                break;
            }
        }
    }

    // For each install, compute the slot_key with the post-remove numbering
    // and pre-alloc it in the persistent arena.
    var install_keys = try std.ArrayListUnmanaged([]const u8).initCapacity(sa, n_installs);
    for (plan.ops.items) |op| {
        if (op != .install) continue;
        const it = op.install;
        const def = part_mod.find(it.part_key) orelse {
            install_keys.appendAssumeCapacity("");
            continue;
        };
        var n: u32 = 1;
        for (surviving.items) |slot_idx| {
            const s = u.slots.items[slot_idx];
            if (std.mem.startsWith(u8, s.slot_key, @tagName(it.location)) and std.mem.indexOf(u8, s.slot_key, def.key) != null) n += 1;
        }
        install_keys.appendAssumeCapacity(try std.fmt.allocPrint(alloc, "{s}.{s}.{d}", .{ @tagName(it.location), def.key, n }));
    }

    // ---- Commit: no allocation can fail past here ----
    var install_idx: usize = 0;
    for (plan.ops.items) |op| {
        switch (op) {
            .remove => |slot_key| {
                for (u.slots.items, 0..) |s, i| {
                    if (std.mem.eql(u8, s.slot_key, slot_key)) {
                        // Capacity pre-reserved above; addStock cannot fail.
                        if (s.condition == .ok) gs.addStock(site, s.part_key, 1) catch unreachable;
                        _ = u.slots.orderedRemove(i);
                        break;
                    }
                }
            },
            .install => |it| {
                const def = part_mod.find(it.part_key) orelse {
                    install_idx += 1;
                    continue;
                };
                const sk = install_keys.items[install_idx];
                install_idx += 1;
                // Slot capacity pre-reserved above; appendAssumeCapacity cannot fail.
                u.slots.appendAssumeCapacity(.{
                    .slot_key = sk,
                    .part_key = def.key,
                    .class = switch (def.mount) {
                        .ammo => .ammo,
                        .equipment => .equipment,
                        else => .weapon,
                    },
                });
            },
        }
    }
}

test "labItems merges hull slots with plan: remove suppresses a slot, install appends" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    // Confirm the Locust has a medium laser in ct.
    const u = gs.unit(uid).?;
    var has_mlas = false;
    for (u.slots.items) |s| {
        if (std.mem.eql(u8, s.slot_key, "ct.mlas.1")) has_mlas = true;
    }
    try std.testing.expect(has_mlas);
    // Build a plan: remove the ct medium laser, install one at rt.
    const plan = try gs.refitPlanOrCreate(uid);
    const slot_key = try gs.allocator().dupe(u8, "ct.mlas.1");
    try plan.ops.append(gs.allocator(), .{ .remove = slot_key });
    try plan.ops.append(gs.allocator(), .{ .install = .{ .location = .rt, .part_key = "mlas" } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try labItems(&gs, uid, arena.allocator());
    // ct.mlas.1 must be absent; rt install must be present.
    var found_ct_mlas = false;
    var found_rt_mlas = false;
    for (items) |it| {
        if (it.location == .ct and std.mem.eql(u8, it.part_key, "mlas")) found_ct_mlas = true;
        if (it.location == .rt and std.mem.eql(u8, it.part_key, "mlas")) found_rt_mlas = true;
    }
    try std.testing.expect(!found_ct_mlas);
    try std.testing.expect(found_rt_mlas);
}

test "applyRefit: removed ok-condition part returns to stock, install becomes a new slot" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer gs.deinit();
    const uid = try gs.addUnit("LCT-1V");
    // Count slots before.
    const slot_count_before = gs.unit(uid).?.slots.items.len;
    // Build a plan: remove the ct medium laser (condition ok), install mg at ra.
    const plan = try gs.refitPlanOrCreate(uid);
    const slot_key = try gs.allocator().dupe(u8, "ct.mlas.1");
    try plan.ops.append(gs.allocator(), .{ .remove = slot_key });
    try plan.ops.append(gs.allocator(), .{ .install = .{ .location = .ra, .part_key = "mg" } });
    try applyRefit(&gs, plan, .outfit);
    const u = gs.unit(uid).?;
    // One slot removed, one added: net same count.
    try std.testing.expectEqual(slot_count_before, u.slots.items.len);
    // ct.mlas.1 slot is gone.
    for (u.slots.items) |s| {
        try std.testing.expect(!std.mem.eql(u8, s.slot_key, "ct.mlas.1"));
    }
    // The medium laser returned to outfit stock.
    try std.testing.expectEqual(@as(u32, 1), gs.stockCount(.outfit, "mlas"));
    // A new mg slot exists at ra.
    var found_ra_mg = false;
    for (u.slots.items) |s| {
        if (std.mem.startsWith(u8, s.slot_key, "ra") and std.mem.eql(u8, s.part_key, "mg")) found_ra_mg = true;
    }
    try std.testing.expect(found_ra_mg);
}

// ---- C4b refit command handlers moved from commands.zig ----

const Error = commands.Error;
const Result = commands.Result;
const Command = commands.Command;

pub fn execRefitRemove(gs: *GameState, r: @FieldType(Command, "refit_remove")) Error!Result {
    const u = gs.unit(r.unit) orelse return Error.UnknownUnit;
    if (u.kind != .mek) return Error.NotAMek;
    if (u.status == .destroyed) return Error.Unavailable; // a wreck is rebuilt (depot) or stripped, not refitted
    var found = false;
    for (u.slots.items) |s| {
        if (std.mem.eql(u8, s.slot_key, r.slot_key) and s.class != .structure) found = true;
    }
    if (!found) return Error.NoSuchSlot;
    const plan = try gs.refitPlanOrCreate(r.unit);
    if (plan.committed) return Error.ProjectInProgress;
    try plan.ops.append(gs.allocator(), .{ .remove = try gs.allocator().dupe(u8, r.slot_key) });
    return .{};
}

pub fn execRefitInstall(gs: *GameState, r: @FieldType(Command, "refit_install")) Error!Result {
    const u = gs.unit(r.unit) orelse return Error.UnknownUnit;
    if (u.kind != .mek) return Error.NotAMek;
    if (u.status == .destroyed) return Error.Unavailable;
    const def = part_mod.find(r.part_key) orelse return Error.UnknownPart;
    if (!def.mountable()) return Error.NotAComponent;
    const plan = try gs.refitPlanOrCreate(r.unit);
    if (plan.committed) return Error.ProjectInProgress;
    try plan.ops.append(gs.allocator(), .{ .install = .{ .location = r.location, .part_key = def.key } });
    return .{};
}

pub fn execRefitClear(gs: *GameState, unit_id: @FieldType(Command, "refit_clear")) Error!Result {
    for (gs.refit_plans.items, 0..) |p, i| {
        if (p.unit != unit_id) continue;
        if (p.committed) {
            // A committed plan lives with its bay job; one without a
            // job is an orphan — clear it and give the parts back.
            if (hq_ops.hasJobForUnit(gs, unit_id)) return Error.ProjectInProgress;
            const home: types.Site = .{ .hq = gs.homeHqFor(if (gs.unit(unit_id)) |u| u.force else .none) };
            for (p.ops.items) |op| if (op == .install) try gs.addStock(home, op.install.part_key, 1);
            try gs.log(.construction, .{}, "[lab] orphaned refit plan on #{d} cleared — parts returned to the warehouse", .{@intFromEnum(unit_id)});
        }
        _ = gs.refit_plans.orderedRemove(i);
        break;
    }
    return .{};
}

/// Commit a refit plan: legal fit, class within the bay's ceiling, parts on
/// the shelf, hull at home — then a bay job for the hours it takes.
pub fn commitRefit(gs: *GameState, unit_id: types.UnitId) Error!Result {
    const u = gs.unit(unit_id) orelse return Error.UnknownUnit;
    if (u.kind != .mek) return Error.NotAMek;
    const plan = gs.refitPlanFor(unit_id) orelse return Error.NoPlan;
    if (plan.committed or plan.ops.items.len == 0) return Error.NoPlan;
    if (u.isBusy() or u.isParked()) return Error.Unavailable;
    if (!posture.isCompanyHome(gs, gs.companyOf(u.force))) return Error.UnitAway;
    const design = chassis_mod.find(u.chassis_key) orelse return Error.UnknownChassis;
    const hq_id = gs.homeHqFor(u.force);
    const hq = gs.hqs.getPtr(hq_id) orelse return Error.NoHq;

    // The rules.
    var arena = std.heap.ArenaAllocator.init(gs.scratch());
    defer arena.deinit();
    const items = try labItems(gs, unit_id, arena.allocator());
    const report = meklab.validate(design, items, arena.allocator()) catch return Error.OutOfMemory;
    if (!report.legal) return Error.IllegalFit;

    // The bay's ceiling.
    const class = meklab.classify(plan.ops.items, u.slots.items);
    const ceiling = hq.refitClassCeiling() orelse return Error.NoBay;
    if (@intFromEnum(class.asQuality()) > @intFromEnum(ceiling)) return Error.RefitClassTooHigh;

    // The parts, counted per part across every install, all present
    // before any are taken.
    const site: types.Site = .{ .hq = hq_id };
    var demand: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (plan.ops.items) |op| {
        if (op != .install) continue;
        const entry = try demand.getOrPut(arena.allocator(), op.install.part_key);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    }
    var dit = demand.iterator();
    while (dit.next()) |d| {
        if (gs.stockCount(site, d.key_ptr.*) < d.value_ptr.*) return Error.MissingParts;
    }
    try gs.bay_jobs.ensureUnusedCapacity(gs.allocator(), 1);
    dit = demand.iterator();
    while (dit.next()) |d| {
        if (!gs.takeStock(site, d.key_ptr.*, d.value_ptr.*)) return Error.MissingParts;
    }

    const hours = meklab.refitHours(plan.ops.items, u.slots.items, class);
    plan.committed = true;
    try gs.bay_jobs.append(gs.allocator(), .{
        .hq = hq_id,
        .kind = .refit,
        .unit = unit_id,
        .duration_days = @max(1, std.math.divCeil(u32, hours, 8) catch unreachable),
        .queued_day = gs.clock.day_index,
        .cost = @as(types.CBills, hours) * tuning.hq_ops.refit_labor_per_hour, // labor
    });
    try gs.log(.construction, .{ .hq = hq_id }, "[lab] {s} refit committed: class {s}, {d} tech-hours, {d} bay day(s) · {s}", .{
        u.chassis_key, @tagName(class), hours, @max(1, std.math.divCeil(u32, hours, 8) catch unreachable), try hq_ops.repairOddsText(gs.allocator(), gs, hq_id, unit_id),
    });
    return .{};
}

test "a refit cannot install two parts from one in stock" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1010 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });
    const hq_id = gs.seat();
    _ = try commands.execute(&gs, .{ .new_company = "Alpha" });
    const site: types.Site = .{ .hq = hq_id };
    // A mek with two mounts of one weapon: pull both and put the same
    // weapon back in each, a legal like-for-like refit needing two parts.
    var it = gs.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (u.kind != .mek) continue;
        for (u.slots.items, 0..) |a, i| {
            if (a.class != .weapon) continue;
            for (u.slots.items[i + 1 ..]) |b| {
                if (b.class != .weapon or !std.mem.eql(u8, a.part_key, b.part_key)) continue;
                const part = a.part_key;
                const loc_a = meklab.parseLocation(a.slot_key).?;
                const loc_b = meklab.parseLocation(b.slot_key).?;
                const key_a = a.slot_key;
                const key_b = b.slot_key;
                _ = try commands.execute(&gs, .{ .refit_remove = .{ .unit = u.id, .slot_key = key_a } });
                _ = try commands.execute(&gs, .{ .refit_remove = .{ .unit = u.id, .slot_key = key_b } });
                _ = try commands.execute(&gs, .{ .refit_install = .{ .unit = u.id, .location = loc_a, .part_key = part } });
                _ = try commands.execute(&gs, .{ .refit_install = .{ .unit = u.id, .location = loc_b, .part_key = part } });
                _ = gs.takeStock(site, part, gs.stockCount(site, part));
                try gs.addStock(site, part, 1);
                try std.testing.expectError(Error.MissingParts, commands.execute(&gs, .{ .refit_commit = u.id }));
                try std.testing.expectEqual(@as(u32, 1), gs.stockCount(site, part));
                try gs.addStock(site, part, 1);
                _ = try commands.execute(&gs, .{ .refit_commit = u.id });
                try std.testing.expectEqual(@as(u32, 0), gs.stockCount(site, part));
                return;
            }
        }
    }
    return error.NoMekWithTwinMounts;
}

test "the lab refuses illegal fits, gates by bay class, and refits through the bay" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1010 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .chief_engineer } });
    const hq_id = gs.seat();
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const lance = gs.force(gs.force(co).?.children.items[0]).?;
    const uid = lance.units.items[0];
    const u = gs.unit(uid).?;

    // Find a weapon slot to swap.
    var weapon_slot: []const u8 = "";
    var weapon_loc: meklab.Location = .ra;
    for (u.slots.items) |s| {
        if (s.class == .weapon) {
            weapon_slot = s.slot_key;
            weapon_loc = meklab.parseLocation(s.slot_key).?;
            break;
        }
    }

    // An AC/20 crammed in place of one laser: the rules say no.
    _ = try commands.execute(&gs, .{ .refit_remove = .{ .unit = uid, .slot_key = weapon_slot } });
    _ = try commands.execute(&gs, .{ .refit_install = .{ .unit = uid, .location = weapon_loc, .part_key = "ac20" } });
    _ = try commands.execute(&gs, .{ .refit_install = .{ .unit = uid, .location = weapon_loc, .part_key = "ac20" } });
    try std.testing.expectError(Error.IllegalFit, commands.execute(&gs, .{ .refit_commit = uid }));
    _ = try commands.execute(&gs, .{ .refit_clear = uid });

    // Jump jets are class D; a level-1 bay does class B only.
    _ = try commands.execute(&gs, .{ .refit_install = .{ .unit = uid, .location = .ll, .part_key = "jump_jet" } });
    try gs.addStock(.{ .hq = hq_id }, "jump_jet", 1);
    const r = commands.execute(&gs, .{ .refit_commit = uid });
    try std.testing.expect(r == Error.RefitClassTooHigh or r == Error.IllegalFit);
    _ = try commands.execute(&gs, .{ .refit_clear = uid });

    // A like-for-like swap (class B): laser out, small laser in — legal,
    // within the ceiling, parts required.
    _ = try commands.execute(&gs, .{ .refit_remove = .{ .unit = uid, .slot_key = weapon_slot } });
    _ = try commands.execute(&gs, .{ .refit_install = .{ .unit = uid, .location = weapon_loc, .part_key = "slas" } });
    try std.testing.expectError(Error.MissingParts, commands.execute(&gs, .{ .refit_commit = uid }));
    try gs.addStock(.{ .hq = hq_id }, "slas", 1);
    const slots_before = u.slots.items.len;
    _ = try commands.execute(&gs, .{ .refit_commit = uid });
    try std.testing.expectEqual(@as(u32, 0), gs.stockCount(.{ .hq = hq_id }, "slas"));

    // The bay does the work; the hull comes out with the new mount and the
    // old laser goes back on the shelf.
    _ = try commands.execute(&gs, .{ .advance_days = 12 });
    try std.testing.expectEqual(slots_before, u.slots.items.len);
    var has_slas = false;
    for (u.slots.items) |s| {
        if (std.mem.eql(u8, s.part_key, "slas")) has_slas = true;
    }
    try std.testing.expect(has_slas);
    try std.testing.expect(gs.refitPlanFor(uid) == null);
}
