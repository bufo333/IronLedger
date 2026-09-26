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
pub fn applyRefit(gs: *GameState, plan: *const RefitPlan, site: types.Site) !void {
    const u = gs.unit(plan.unit) orelse return;
    const alloc = gs.allocator();
    for (plan.ops.items) |op| {
        switch (op) {
            .remove => |slot_key| {
                for (u.slots.items, 0..) |s, i| {
                    if (std.mem.eql(u8, s.slot_key, slot_key)) {
                        if (s.condition == .ok) try gs.addStock(site, s.part_key, 1);
                        _ = u.slots.orderedRemove(i);
                        break;
                    }
                }
            },
            .install => |it| {
                const def = part_mod.find(it.part_key) orelse continue;
                var n: u32 = 1;
                for (u.slots.items) |s| {
                    if (std.mem.startsWith(u8, s.slot_key, @tagName(it.location)) and std.mem.indexOf(u8, s.slot_key, def.key) != null) n += 1;
                }
                try u.slots.append(alloc, .{
                    .slot_key = try std.fmt.allocPrint(alloc, "{s}.{s}.{d}", .{ @tagName(it.location), def.key, n }),
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
