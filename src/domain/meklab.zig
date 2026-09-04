//! The MekLab rules (Stage 10, ARCH §10): TechManual construction for
//! standard Inner Sphere 3025 BattleMechs. Pure functions over a chassis
//! and a loadout: what the hull weighs, what each location can hold, what
//! rule a fit breaks, and how big a job a refit is (CamOps class A–F).
//!
//! Integer arithmetic throughout: masses in half-tons, no floats.

const std = @import("std");
const types = @import("types.zig");
const chassis_mod = @import("chassis.zig");
const part_mod = @import("part.zig");
const unit_mod = @import("unit.zig");

pub const Location = enum(u3) { hd, ct, lt, rt, la, ra, ll, rl };
pub const location_count = 8;

pub fn parseLocation(slot_key: []const u8) ?Location {
    if (slot_key.len < 3 or slot_key[2] != '.') return null;
    return std.meta.stringToEnum(Location, slot_key[0..2]);
}

/// Free critical slots per location after the fixed occupants (TechManual):
/// head 6 − life support/sensors/cockpit; center torso 12 − engine/gyro;
/// side torsos 12; arms 12 − four actuators; legs 6 − four actuators.
pub fn freeCrits(loc: Location) u8 {
    return switch (loc) {
        .hd => 1,
        .ct => 2,
        .lt, .rt => 12,
        .la, .ra => 8,
        .ll, .rl => 2,
    };
}

pub fn isTorso(loc: Location) bool {
    return loc == .ct or loc == .lt or loc == .rt;
}

pub fn isLeg(loc: Location) bool {
    return loc == .ll or loc == .rl;
}

/// Standard fusion engine mass in half-tons by rating (TechManual table,
/// linearly interpolated between the 20-point rows). // TUNE: full table
const engine_rows = [_]struct { u32, u32 }{
    .{ 60, 3 },   .{ 80, 5 },   .{ 100, 6 },  .{ 120, 8 },  .{ 140, 10 }, .{ 160, 12 },
    .{ 180, 14 }, .{ 200, 17 }, .{ 220, 20 }, .{ 240, 23 }, .{ 260, 27 }, .{ 280, 32 },
    .{ 300, 38 }, .{ 320, 45 }, .{ 340, 54 }, .{ 360, 66 }, .{ 380, 82 }, .{ 400, 105 },
};

pub fn engineHalfTons(rating: u32) u32 {
    if (rating <= engine_rows[0][0]) return engine_rows[0][1];
    var i: usize = 1;
    while (i < engine_rows.len) : (i += 1) {
        if (rating <= engine_rows[i][0]) {
            const lo = engine_rows[i - 1];
            const hi = engine_rows[i];
            const span = hi[0] - lo[0];
            return lo[1] + (hi[1] - lo[1]) * (rating - lo[0]) / span;
        }
    }
    return engine_rows[engine_rows.len - 1][1];
}

/// Jump jet mass by weight class (half-tons each).
pub fn jumpJetHalfTons(tonnage: u8) u32 {
    return if (tonnage <= 55) 1 else if (tonnage <= 85) 2 else 4;
}

/// What the chassis itself weighs before a single weapon goes on:
/// structure, engine, gyro, cockpit, armor, jump jets, and heat sinks
/// beyond the ten a fusion engine carries free.
pub fn fixedHalfTons(design: *const chassis_mod.Chassis) u32 {
    const rating = design.engineRating();
    const structure: u32 = @as(u32, design.tonnage) * 2 / 10; // 10% of tonnage
    const engine = engineHalfTons(rating);
    const gyro: u32 = (std.math.divCeil(u32, rating, 100) catch 1) * 2;
    const cockpit: u32 = 6;
    const jets: u32 = @as(u32, design.jump_mp) * jumpJetHalfTons(design.tonnage);
    const extra_sinks: u32 = @as(u32, design.heat_sinks -| 10) * 2;
    return structure + engine + gyro + cockpit + design.armor_half_tons + jets + extra_sinks;
}

pub const Violation = struct {
    rule: enum { overweight, crits, heat_sinks, ammo, location, unknown_part },
    text: []const u8,
};

pub const Report = struct {
    legal: bool,
    tonnage: u8,
    fixed_half_tons: u32,
    loadout_half_tons: u32,
    free_half_tons: i32, // negative = overweight
    crits_used: [location_count]u8,
    crits_free: [location_count]u8,
    heat_per_alpha: u32,
    heat_sinks: u8,
    violations: []Violation,
};

/// Items the lab reasons about: a location and a catalog key.
pub const Item = struct {
    location: Location,
    part_key: []const u8,
};

/// Validate a loadout against the chassis. `alloc` owns the violations.
pub fn validate(design: *const chassis_mod.Chassis, items: []const Item, alloc: std.mem.Allocator) !Report {
    var report: Report = .{
        .legal = true,
        .tonnage = design.tonnage,
        .fixed_half_tons = fixedHalfTons(design),
        .loadout_half_tons = 0,
        .free_half_tons = 0,
        .crits_used = @splat(0),
        .crits_free = @splat(0),
        .heat_per_alpha = 0,
        .heat_sinks = design.heat_sinks,
        .violations = &.{},
    };
    var violations: std.ArrayListUnmanaged(Violation) = .empty;

    // Mounted items first; the chassis's own jump jets and loose heat sinks
    // then take whatever slots remain (see below).
    var ammo_needed = std.StringArrayHashMapUnmanaged(bool).empty;
    defer ammo_needed.deinit(alloc);
    var ammo_have = std.StringArrayHashMapUnmanaged(bool).empty;
    defer ammo_have.deinit(alloc);
    for (items) |it| {
        const def = part_mod.find(it.part_key) orelse {
            try violations.append(alloc, .{ .rule = .unknown_part, .text = try std.fmt.allocPrint(alloc, "unknown part '{s}'", .{it.part_key}) });
            continue;
        };
        if (!def.mountable()) {
            try violations.append(alloc, .{ .rule = .unknown_part, .text = try std.fmt.allocPrint(alloc, "'{s}' is not something a mek mounts", .{def.name}) });
            continue;
        }
        var mass: u32 = def.mass_half_tons;
        if (std.mem.eql(u8, def.key, "jump_jet")) {
            mass = jumpJetHalfTons(design.tonnage);
            if (!isTorso(it.location) and !isLeg(it.location)) {
                try violations.append(alloc, .{ .rule = .location, .text = try std.fmt.allocPrint(alloc, "jump jets mount only in torsos or legs, not {s}", .{@tagName(it.location)}) });
            }
        }
        report.loadout_half_tons += mass;
        report.crits_used[@intFromEnum(it.location)] +|= def.crits;
        report.heat_per_alpha += def.heat;
        if (def.mount == .ammo) {
            try ammo_have.put(alloc, def.key, true);
        } else if (part_mod.munitionFor(def.key)) |fam| {
            try ammo_needed.put(alloc, fam, true);
        }
    }

    // Implicit occupants: jump jets ride legs then torsos; heat sinks past
    // the engine's integral count take a crit each, anywhere with room.
    var jets: u32 = design.jump_mp;
    const jet_order = [_]Location{ .ll, .rl, .ct, .lt, .rt };
    for (jet_order) |loc| {
        while (jets > 0 and report.crits_used[@intFromEnum(loc)] < freeCrits(loc)) : (jets -= 1) report.crits_used[@intFromEnum(loc)] += 1;
    }
    if (jets > 0) {
        try violations.append(alloc, .{ .rule = .crits, .text = try std.fmt.allocPrint(alloc, "no room in torsos or legs for {d} jump jet(s)", .{jets}) });
    }
    const integral: u32 = @min(design.heat_sinks, design.engineRating() / 25);
    var loose_sinks: u32 = @as(u32, design.heat_sinks) - integral;
    const sink_order = [_]Location{ .ll, .rl, .lt, .rt, .la, .ra, .ct, .hd };
    for (sink_order) |loc| {
        while (loose_sinks > 0 and report.crits_used[@intFromEnum(loc)] < freeCrits(loc)) : (loose_sinks -= 1) report.crits_used[@intFromEnum(loc)] += 1;
    }
    if (loose_sinks > 0) {
        try violations.append(alloc, .{ .rule = .crits, .text = try std.fmt.allocPrint(alloc, "no critical slots left for {d} heat sink(s)", .{loose_sinks}) });
    }

    // Rules.
    const total = report.fixed_half_tons + report.loadout_half_tons;
    report.free_half_tons = @as(i32, @intCast(@as(u32, design.tonnage) * 2)) - @as(i32, @intCast(total));
    if (report.free_half_tons < 0) {
        try violations.append(alloc, .{ .rule = .overweight, .text = try std.fmt.allocPrint(alloc, "overweight by {d}.{d} tons ({d}.{d}/{d}t)", .{
            @divTrunc(-report.free_half_tons, 2), @mod(-report.free_half_tons, 2) * 5, total / 2, (total % 2) * 5, design.tonnage,
        }) });
    }
    for (0..location_count) |i| {
        const loc: Location = @enumFromInt(i);
        const cap = freeCrits(loc);
        if (report.crits_used[i] > cap) {
            try violations.append(alloc, .{ .rule = .crits, .text = try std.fmt.allocPrint(alloc, "{s} needs {d} critical slots but has {d}", .{ @tagName(loc), report.crits_used[i], cap }) });
        }
        report.crits_free[i] = cap -| report.crits_used[i];
    }
    if (design.heat_sinks < 10) {
        try violations.append(alloc, .{ .rule = .heat_sinks, .text = try std.fmt.allocPrint(alloc, "a mek needs at least 10 heat sinks (has {d})", .{design.heat_sinks}) });
    }
    var nit = ammo_needed.iterator();
    while (nit.next()) |entry| {
        if (!ammo_have.contains(entry.key_ptr.*)) {
            try violations.append(alloc, .{ .rule = .ammo, .text = try std.fmt.allocPrint(alloc, "no ammunition mounted for weapons that fire {s}", .{entry.key_ptr.*}) });
        }
    }

    report.violations = try violations.toOwnedSlice(alloc);
    report.legal = report.violations.len == 0;
    return report;
}

/// Build the lab's item list from a unit's live slots (ok/damaged slots
/// count; destroyed/missing still occupy the mount but weigh nothing until
/// replaced — the lab shows them, the repair pipeline fixes them).
pub fn itemsFromSlots(slots: []const unit_mod.PartSlot, alloc: std.mem.Allocator) ![]Item {
    var out: std.ArrayListUnmanaged(Item) = .empty;
    for (slots) |s| {
        if (s.class == .structure) continue;
        const loc = parseLocation(s.slot_key) orelse continue;
        try out.append(alloc, .{ .location = loc, .part_key = s.part_key });
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ refits

pub const RefitOp = union(enum) {
    remove: []const u8, // slot key
    install: Item,
};

/// CamOps refit class from what a plan touches (abridged): A = ammo or
/// armor only; B = like-for-like weapon swaps in place; C = weapons or
/// equipment added/removed/changed; D = jump jets or heat sinks touched.
/// (E/F — engine, structure, chassis — are not offered.)
pub const RefitClass = enum(u8) {
    a = 0,
    b = 1,
    c = 2,
    d = 3,

    pub fn asQuality(self: RefitClass) types.Quality {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn hoursMultBp(self: RefitClass) types.Bp {
        return switch (self) {
            .a => 10_000,
            .b => 15_000,
            .c => 20_000,
            .d => 30_000,
        };
    }
};

pub fn classify(ops: []const RefitOp, slots: []const unit_mod.PartSlot) RefitClass {
    var worst: RefitClass = .a;
    var removed_weapons: u32 = 0;
    var installed_weapons: u32 = 0;
    for (ops) |op| {
        const key: []const u8 = switch (op) {
            .remove => |slot_key| blk: {
                for (slots) |s| {
                    if (std.mem.eql(u8, s.slot_key, slot_key)) break :blk s.part_key;
                }
                break :blk "";
            },
            .install => |it| it.part_key,
        };
        const def = part_mod.find(key) orelse continue;
        if (std.mem.eql(u8, def.key, "jump_jet") or std.mem.eql(u8, def.key, "heat_sink")) {
            worst = .d;
            continue;
        }
        if (def.mount == .ammo) continue; // class A work
        if (op == .remove) removed_weapons += 1 else installed_weapons += 1;
    }
    if (worst == .d) return .d;
    if (removed_weapons + installed_weapons == 0) return .a;
    // Like-for-like swap (one out, one in, same count) reads as class B;
    // anything that changes the weapon count is C.
    if (removed_weapons == installed_weapons and removed_weapons > 0) return @enumFromInt(@max(@intFromEnum(worst), @intFromEnum(RefitClass.b)));
    return .c;
}

/// Tech hours for a plan: each op costs 4h + 2h per crit, scaled by class.
pub fn refitHours(ops: []const RefitOp, slots: []const unit_mod.PartSlot, class: RefitClass) u32 {
    var hours: u32 = 0;
    for (ops) |op| {
        const key: []const u8 = switch (op) {
            .remove => |slot_key| blk: {
                for (slots) |s| {
                    if (std.mem.eql(u8, s.slot_key, slot_key)) break :blk s.part_key;
                }
                break :blk "";
            },
            .install => |it| it.part_key,
        };
        const crits: u32 = if (part_mod.find(key)) |d| d.crits else 1;
        hours += 4 + 2 * crits;
    }
    return @intCast(types.applyBp(@as(types.CBills, hours), class.hoursMultBp()));
}

test "the canonical designs are legal and close to their tonnage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for (chassis_mod.catalog) |*design| {
        if (design.kind != .mek) continue;
        var items: std.ArrayListUnmanaged(Item) = .empty;
        for (design.loadout) |l| {
            try items.append(alloc, .{ .location = parseLocation(l.slot).?, .part_key = l.part });
        }
        const r = try validate(design, items.items, alloc);
        for (r.violations) |v| std.debug.print("{s}: {s}\n", .{ design.key, v.text });
        try std.testing.expect(r.legal);
        // Abridged loadouts: never more than a few tons under.
        try std.testing.expect(r.free_half_tons >= 0 and r.free_half_tons <= 14);
    }
}

test "the lab refuses illegal fits and names the rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const locust = chassis_mod.find("LCT-1V").?;

    // A Locust with an AC/20 in the arm: overweight AND out of arm crits.
    const items = [_]Item{
        .{ .location = .ra, .part_key = "ac20" },
        .{ .location = .ct, .part_key = "ammo_ac20" },
    };
    const r = try validate(locust, &items, alloc);
    try std.testing.expect(!r.legal);
    var saw_weight = false;
    var saw_crits = false;
    for (r.violations) |v| {
        if (v.rule == .overweight) saw_weight = true;
        if (v.rule == .crits) saw_crits = true;
    }
    try std.testing.expect(saw_weight and saw_crits);

    // A missile boat with no reloads: the ammo rule.
    const dry = [_]Item{.{ .location = .rt, .part_key = "lrm10" }};
    const r2 = try validate(locust, &dry, alloc);
    var saw_ammo = false;
    for (r2.violations) |v| {
        if (v.rule == .ammo) saw_ammo = true;
    }
    try std.testing.expect(saw_ammo);

    // Jump jets in an arm: the location rule.
    const arm_jets = [_]Item{.{ .location = .la, .part_key = "jump_jet" }};
    const r3 = try validate(locust, &arm_jets, alloc);
    try std.testing.expect(!r3.legal and r3.violations[0].rule == .location);
}

test "refit classes: ammo is A, a like-for-like swap is B, new guns are C, jets are D" {
    const slots = [_]unit_mod.PartSlot{
        .{ .slot_key = "ra.mlas.1", .part_key = "mlas", .class = .weapon },
        .{ .slot_key = "ct.ammo_srm.1", .part_key = "ammo_srm", .class = .ammo },
    };
    try std.testing.expectEqual(RefitClass.a, classify(&.{.{ .remove = "ct.ammo_srm.1" }}, &slots));
    try std.testing.expectEqual(RefitClass.b, classify(&.{ .{ .remove = "ra.mlas.1" }, .{ .install = .{ .location = .ra, .part_key = "llas" } } }, &slots));
    try std.testing.expectEqual(RefitClass.c, classify(&.{.{ .install = .{ .location = .lt, .part_key = "srm6" } }}, &slots));
    try std.testing.expectEqual(RefitClass.d, classify(&.{.{ .install = .{ .location = .ll, .part_key = "jump_jet" } }}, &slots));
    try std.testing.expect(refitHours(&.{.{ .install = .{ .location = .lt, .part_key = "ppc" } }}, &slots, .c) > refitHours(&.{.{ .remove = "ct.ammo_srm.1" }}, &slots, .a));
}
