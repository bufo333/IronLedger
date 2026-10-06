//! The MekLab rules (Stage 10, ARCH §10): TechManual construction for
//! standard Inner Sphere 3025 BattleMechs. Pure functions over a chassis
//! and a loadout: what the hull weighs, what each location can hold, what
//! rule a fit breaks, and how big a job a refit is (CamOps class A–D).
//!
//! Integer arithmetic throughout: masses in half-tons, no floats.
//! MekHQ counterpart: the MekLab tab and its customization rules
//! (docs/mekhq-map.md).

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

/// Free critical slots per location after fixed occupants, sourced from
/// `Chassis.crit_slots` (design §2/§4, TechManual). Index order matches
/// `Location` (hd=0 … rl=7).
pub fn freeCrits(design: *const chassis_mod.Chassis, loc: Location) u8 {
    return design.crit_slots[@intFromEnum(loc)];
}

pub fn isTorso(loc: Location) bool {
    return loc == .ct or loc == .lt or loc == .rt;
}

pub fn isLeg(loc: Location) bool {
    return loc == .ll or loc == .rl;
}

/// Physical crit slots per location on a standard Inner Sphere BattleMech
/// (TechManual construction tables, same authority as chassis.zig:36-38).
/// This is the total physical count; free crits = physicalTotal - fixedOccupants.len.
/// Reconciliation identity: fixedOccupants(design, loc, buf).len + crit_slots[loc] == physicalTotal(loc)
pub fn physicalTotal(loc: Location) u8 {
    return switch (loc) {
        .hd => 6,
        .ct => 12,
        .lt, .rt => 12,
        .la, .ra => 12,
        .ll, .rl => 6,
    };
}

/// A named occupant of a fixed crit slot (cockpit, actuator, etc.).
/// All render as the dim '■' marker in the layout display.
pub const FixedOccupant = struct {
    /// Category for display colour / filtering.
    kind: Kind,
    /// Short display text, e.g. "cockpit", "engine", "shoulder", "lower arm".
    label: []const u8,

    pub const Kind = enum { cockpit, sensors, life_support, engine, gyro, actuator };
};

/// The named fixed occupants for `loc` on `design`, written into `buf`.
/// Returns a slice of `buf`; caller supplies a buffer of at least 6 elements
/// (the maximum for any location is the head with 5 fixed slots).
///
/// Standard inner-sphere assumptions (no XL/light engine splits, no triple-
/// strength myomer): engine 6 CT slots fixed; gyro 4 CT slots fixed.
/// These are the values consistent with every shipped crit_slots entry and
/// with the reconciliation identity above (see plan §OC-3 for derivation).
///
/// One owner (rule 20): every consumer of "which slots are fixed and what are
/// they called" calls this function.
pub fn fixedOccupants(design: *const chassis_mod.Chassis, loc: Location, buf: []FixedOccupant) []FixedOccupant {
    var n: usize = 0;
    switch (loc) {
        .hd => {
            buf[n] = .{ .kind = .cockpit, .label = "cockpit" };
            n += 1;
            buf[n] = .{ .kind = .sensors, .label = "sensors" };
            n += 1;
            buf[n] = .{ .kind = .sensors, .label = "sensors" };
            n += 1;
            buf[n] = .{ .kind = .life_support, .label = "life support" };
            n += 1;
            buf[n] = .{ .kind = .life_support, .label = "life support" };
            n += 1;
        },
        .ct => {
            buf[n] = .{ .kind = .engine, .label = "engine" };
            n += 1;
            buf[n] = .{ .kind = .engine, .label = "engine" };
            n += 1;
            buf[n] = .{ .kind = .engine, .label = "engine" };
            n += 1;
            buf[n] = .{ .kind = .engine, .label = "engine" };
            n += 1;
            buf[n] = .{ .kind = .engine, .label = "engine" };
            n += 1;
            buf[n] = .{ .kind = .engine, .label = "engine" };
            n += 1;
            buf[n] = .{ .kind = .gyro, .label = "gyro" };
            n += 1;
            buf[n] = .{ .kind = .gyro, .label = "gyro" };
            n += 1;
            buf[n] = .{ .kind = .gyro, .label = "gyro" };
            n += 1;
            buf[n] = .{ .kind = .gyro, .label = "gyro" };
            n += 1;
        },
        .lt, .rt => {
            // No fixed occupants in standard side torsos.
        },
        .la, .ra => {
            buf[n] = .{ .kind = .actuator, .label = "shoulder" };
            n += 1;
            buf[n] = .{ .kind = .actuator, .label = "upper arm" };
            n += 1;
            const acts = if (loc == .la) design.left_arm_actuators else design.right_arm_actuators;
            switch (acts) {
                .full => {
                    buf[n] = .{ .kind = .actuator, .label = "lower arm" };
                    n += 1;
                    buf[n] = .{ .kind = .actuator, .label = "hand" };
                    n += 1;
                },
                .no_hand => {
                    buf[n] = .{ .kind = .actuator, .label = "lower arm" };
                    n += 1;
                },
                .no_lower_arm => {
                    // Only shoulder + upper arm; no lower arm, no hand.
                },
            }
        },
        .ll, .rl => {
            buf[n] = .{ .kind = .actuator, .label = "hip" };
            n += 1;
            buf[n] = .{ .kind = .actuator, .label = "upper leg" };
            n += 1;
            buf[n] = .{ .kind = .actuator, .label = "lower leg" };
            n += 1;
            buf[n] = .{ .kind = .actuator, .label = "foot" };
            n += 1;
        },
    }
    return buf[0..n];
}

/// Whether a part's location rule permits placement in `loc` (design §2/§4,
/// rule 20). One owner: the validator and the picker both call this.
pub fn locationAllowed(rule: part_mod.LocationRule, loc: Location) bool {
    return switch (rule) {
        .any => true,
        .torso_or_leg => isTorso(loc) or isLeg(loc),
        .side_torso => loc == .lt or loc == .rt,
        .head_or_torso => loc == .hd or isTorso(loc),
    };
}

/// The refusal phrase for a location rule (rule 28: one owner for the
/// refusal sentence fragment).
fn locationRuleText(rule: part_mod.LocationRule) []const u8 {
    return switch (rule) {
        .any => "any location",
        .torso_or_leg => "torsos or legs",
        .side_torso => "side torsos",
        .head_or_torso => "the head or torsos",
    };
}

/// Construction tables from data/tables/meklab.zon (TechManual): the
/// Master Engine Table and the Internal Structure Table.
pub const Tables = struct {
    engine_half_tons: []const u32, // rating 10..400 step 5
    internal_structure: []const StructureRow,
    head_structure: u8,
    head_max_armor: u8,
};
pub const StructureRow = struct { tonnage: u8, ct: u8, side: u8, arm: u8, leg: u8 };
pub const tables: Tables = @import("meklab_zon");

/// Standard fusion engine mass in half-tons by rating (Master Engine
/// Table; ratings are rounded up to the next multiple of 5).
pub fn engineHalfTons(rating: u32) u32 {
    const t = tables.engine_half_tons;
    if (rating <= 10) return t[0];
    const idx = (rating - 10 + 4) / 5;
    return t[@min(idx, t.len - 1)];
}

/// Internal structure points per location for a tonnage (rounded up to
/// the next 5 tons).
pub fn structureRow(tonnage: u8) StructureRow {
    for (tables.internal_structure) |row| if (tonnage <= row.tonnage) return row;
    return tables.internal_structure[tables.internal_structure.len - 1];
}

/// Most armor a chassis can carry, in points: twice the structure per
/// location (head 9), TechManual armor rules.
pub fn maxArmorPoints(tonnage: u8) u32 {
    const r = structureRow(tonnage);
    return @as(u32, tables.head_max_armor) + 2 * (@as(u32, r.ct) + 2 * @as(u32, r.side) + 2 * @as(u32, r.arm) + 2 * @as(u32, r.leg));
}

/// ...and in half-tons of standard armor (16 points per ton).
pub fn maxArmorHalfTons(tonnage: u8) u32 {
    return maxArmorPoints(tonnage) / 8;
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
    const gyro: u32 = (std.math.divCeil(u32, rating, 100) catch unreachable) * 2;
    const cockpit: u32 = 6;
    const jets: u32 = @as(u32, design.jump_mp) * jumpJetHalfTons(design.tonnage);
    const extra_sinks: u32 = @as(u32, design.heat_sinks -| 10) * 2;
    return structure + engine + gyro + cockpit + design.armor_half_tons + jets + extra_sinks;
}

pub const Violation = struct {
    rule: enum { overweight, crits, heat_sinks, ammo, location, unknown_part, armor },
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
        if (std.mem.eql(u8, def.key, "jump_jet")) mass = jumpJetHalfTons(design.tonnage);
        if (!locationAllowed(def.loc_rule, it.location)) {
            try violations.append(alloc, .{ .rule = .location, .text = try std.fmt.allocPrint(alloc, "{s} mount only in {s}, not {s}", .{ def.name, locationRuleText(def.loc_rule), @tagName(it.location) }) });
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
        while (jets > 0 and report.crits_used[@intFromEnum(loc)] < freeCrits(design, loc)) : (jets -= 1) report.crits_used[@intFromEnum(loc)] += 1;
    }
    if (jets > 0) {
        try violations.append(alloc, .{ .rule = .crits, .text = try std.fmt.allocPrint(alloc, "no room in torsos or legs for {d} jump jet(s)", .{jets}) });
    }
    const integral: u32 = @min(design.heat_sinks, design.engineRating() / 25);
    var loose_sinks: u32 = @as(u32, design.heat_sinks) - integral;
    const sink_order = [_]Location{ .ll, .rl, .lt, .rt, .la, .ra, .ct, .hd };
    for (sink_order) |loc| {
        while (loose_sinks > 0 and report.crits_used[@intFromEnum(loc)] < freeCrits(design, loc)) : (loose_sinks -= 1) report.crits_used[@intFromEnum(loc)] += 1;
    }
    if (loose_sinks > 0) {
        try violations.append(alloc, .{ .rule = .crits, .text = try std.fmt.allocPrint(alloc, "no critical slots left for {d} heat sink(s)", .{loose_sinks}) });
    }

    // Rules.
    const total = report.fixed_half_tons + report.loadout_half_tons;
    report.free_half_tons = @as(i32, @intCast(@as(u32, design.tonnage) * 2)) - @as(i32, @intCast(total));
    if (report.free_half_tons < 0) {
        const over_ht: i64 = @as(i64, report.free_half_tons);
        const used_ht: i64 = @as(i64, @intCast(total));
        try violations.append(alloc, .{ .rule = .overweight, .text = try std.fmt.allocPrint(alloc, "overweight by {s} ({s}/{d}t)", .{
            try part_mod.halfTonsText(alloc, -over_ht), try part_mod.halfTonsText(alloc, used_ht), design.tonnage,
        }) });
    }
    for (0..location_count) |i| {
        const loc: Location = @enumFromInt(i);
        const cap = freeCrits(design, loc);
        if (report.crits_used[i] > cap) {
            try violations.append(alloc, .{ .rule = .crits, .text = try std.fmt.allocPrint(alloc, "{s} needs {d} critical slots but has {d}", .{ @tagName(loc), report.crits_used[i], cap }) });
        }
        report.crits_free[i] = cap -| report.crits_used[i];
    }
    if (design.heat_sinks < 10) {
        try violations.append(alloc, .{ .rule = .heat_sinks, .text = try std.fmt.allocPrint(alloc, "a mek needs at least 10 heat sinks (has {d})", .{design.heat_sinks}) });
    }
    // Armor cannot exceed twice the internal structure (head 9).
    if (@as(u32, design.armor_half_tons) * 8 > maxArmorPoints(design.tonnage)) {
        try violations.append(alloc, .{ .rule = .armor, .text = try std.fmt.allocPrint(alloc, "{d} armor points exceed the {d} a {d}-ton frame can carry", .{ @as(u32, design.armor_half_tons) * 8, maxArmorPoints(design.tonnage), design.tonnage }) });
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
/// (E/F — engine, structure, chassis — are intentionally never modeled;
/// project-owner scope decision.)
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

/// Every catalogue mek's own loadout, run through the lab's rules.
fn canonicalReportForTest(alloc: std.mem.Allocator, design: *const chassis_mod.Chassis) !?Report {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    for (design.loadout) |l| {
        const loc = parseLocation(l.slot) orelse {
            std.debug.print("{s}: loadout slot '{s}' names no location\n", .{ design.key, l.slot });
            return null;
        };
        try items.append(alloc, .{ .location = loc, .part_key = l.part });
    }
    return try validate(design, items.items, alloc);
}

test "data: every catalogue mek's own loadout is legal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (chassis_mod.catalog) |*design| {
        if (design.kind != .mek) continue;
        const r = (try canonicalReportForTest(arena.allocator(), design)) orelse return error.TestUnexpectedResult;
        for (r.violations) |v| std.debug.print("{s}: {s}\n", .{ design.key, v.text });
        try std.testing.expect(r.legal);
    }
}

test "the stock designs are abridged by at most seven tons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (chassis_mod.catalog) |*design| {
        if (design.kind != .mek) continue;
        const r = (try canonicalReportForTest(arena.allocator(), design)).?;
        if (r.free_half_tons < 0 or r.free_half_tons > 14) std.debug.print("{s}: free {d} half-tons (fixed {d}, loadout {d})\n", .{ design.key, r.free_half_tons, r.fixed_half_tons, r.loadout_half_tons });
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

test "TechManual tables — engine masses and structure points are exact, armor is capped" {
    try std.testing.expectEqual(@as(u32, 38), engineHalfTons(300)); // 19 t
    try std.testing.expectEqual(@as(u32, 29), engineHalfTons(270)); // 14.5 t
    try std.testing.expectEqual(@as(u32, 17), engineHalfTons(200)); // 8.5 t
    try std.testing.expectEqual(@as(u32, 105), engineHalfTons(400)); // 52.5 t
    try std.testing.expectEqual(@as(u32, 31), engineHalfTons(275)); // 15.5 t
    try std.testing.expectEqual(@as(u8, 31), structureRow(100).ct); // Atlas
    try std.testing.expectEqual(@as(u8, 4), structureRow(20).leg); // Locust
    try std.testing.expectEqual(@as(u32, 307), maxArmorPoints(100));
    try std.testing.expectEqual(@as(u32, 69), maxArmorPoints(20));
    // A Locust with 10 tons of armor is not a Locust.
    var over = chassis_mod.find("LCT-1V").?.*;
    over.armor_half_tons = 20;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try validate(&over, &.{}, arena.allocator());
    var armor_rule = false;
    for (r.violations) |v| if (v.rule == .armor) {
        armor_rule = true;
    };
    try std.testing.expect(armor_rule);
}

test "locationAllowed: each rule permits exactly the right locations" {
    // .any allows all eight locations
    for ([_]Location{ .hd, .ct, .lt, .rt, .la, .ra, .ll, .rl }) |loc| {
        try std.testing.expect(locationAllowed(.any, loc));
    }
    // .torso_or_leg allows ct/lt/rt/ll/rl and refuses hd/la/ra
    for ([_]Location{ .ct, .lt, .rt, .ll, .rl }) |loc| {
        try std.testing.expect(locationAllowed(.torso_or_leg, loc));
    }
    for ([_]Location{ .hd, .la, .ra }) |loc| {
        try std.testing.expect(!locationAllowed(.torso_or_leg, loc));
    }
    // .side_torso allows only lt/rt
    try std.testing.expect(locationAllowed(.side_torso, .lt));
    try std.testing.expect(locationAllowed(.side_torso, .rt));
    for ([_]Location{ .hd, .ct, .la, .ra, .ll, .rl }) |loc| {
        try std.testing.expect(!locationAllowed(.side_torso, loc));
    }
    // .head_or_torso allows only hd/ct/lt/rt
    for ([_]Location{ .hd, .ct, .lt, .rt }) |loc| {
        try std.testing.expect(locationAllowed(.head_or_torso, loc));
    }
    for ([_]Location{ .la, .ra, .ll, .rl }) |loc| {
        try std.testing.expect(!locationAllowed(.head_or_torso, loc));
    }
}

test "data-driven crit capacity: validate reads crit_slots, not a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A copy of LCT-1V with left-arm capacity zeroed out.
    var m = chassis_mod.find("LCT-1V").?.*;
    m.crit_slots[@intFromEnum(Location.la)] = 0;

    // A single medium laser in the left arm violates the zeroed capacity.
    const one_item = [_]Item{.{ .location = .la, .part_key = "mlas" }};
    const bad = try validate(&m, &one_item, alloc);
    var saw_crits_la = false;
    for (bad.violations) |v| {
        if (v.rule == .crits and std.mem.indexOf(u8, v.text, "la") != null) saw_crits_la = true;
    }
    try std.testing.expect(saw_crits_la);

    // The same loadout on the unmodified LCT-1V produces no crits violation for la.
    const stock = chassis_mod.find("LCT-1V").?;
    const good = try validate(stock, &one_item, alloc);
    for (good.violations) |v| {
        if (v.rule == .crits and std.mem.indexOf(u8, v.text, "la") != null) {
            return error.TestUnexpectedResult;
        }
    }
}

test "physicalTotal matches TechManual standard-IS totals" {
    try std.testing.expectEqual(@as(u8, 6), physicalTotal(.hd));
    try std.testing.expectEqual(@as(u8, 12), physicalTotal(.ct));
    try std.testing.expectEqual(@as(u8, 12), physicalTotal(.lt));
    try std.testing.expectEqual(@as(u8, 12), physicalTotal(.rt));
    try std.testing.expectEqual(@as(u8, 12), physicalTotal(.la));
    try std.testing.expectEqual(@as(u8, 12), physicalTotal(.ra));
    try std.testing.expectEqual(@as(u8, 6), physicalTotal(.ll));
    try std.testing.expectEqual(@as(u8, 6), physicalTotal(.rl));
}

test "fixedOccupants: arm count varies by actuator flag" {
    var buf: [6]FixedOccupant = undefined;
    // A full-actuator chassis.
    const shd = chassis_mod.find("SHD-2H").?;
    try std.testing.expectEqual(@as(usize, 4), fixedOccupants(shd, .la, &buf).len);
    try std.testing.expectEqual(@as(usize, 4), fixedOccupants(shd, .ra, &buf).len);
    // .no_hand → 3 fixed.
    var no_hand = shd.*;
    no_hand.left_arm_actuators = .no_hand;
    try std.testing.expectEqual(@as(usize, 3), fixedOccupants(&no_hand, .la, &buf).len);
    // .no_lower_arm → 2 fixed (the Catapult's case).
    const cplt = chassis_mod.find("CPLT-C1").?;
    try std.testing.expectEqual(@as(usize, 2), fixedOccupants(cplt, .la, &buf).len);
    try std.testing.expectEqual(@as(usize, 2), fixedOccupants(cplt, .ra, &buf).len);
    // Labels for head occupants.
    const shd_hd = fixedOccupants(shd, .hd, &buf);
    try std.testing.expectEqual(@as(usize, 5), shd_hd.len);
    try std.testing.expectEqual(FixedOccupant.Kind.cockpit, shd_hd[0].kind);
    // CT: 10 fixed (6 engine + 4 gyro) — needs a larger buffer.
    var ct_buf: [12]FixedOccupant = undefined;
    try std.testing.expectEqual(@as(usize, 10), fixedOccupants(shd, .ct, &ct_buf).len);
    // Leg: 4 fixed.
    try std.testing.expectEqual(@as(usize, 4), fixedOccupants(shd, .ll, &buf).len);
}

test "reconciliation identity: fixedOccupants.len + crit_slots[loc] == physicalTotal(loc) for every mek" {
    var buf: [12]FixedOccupant = undefined;
    for (chassis_mod.catalog) |*design| {
        if (design.kind != .mek) continue;
        inline for (@typeInfo(Location).@"enum".fields) |f| {
            const loc: Location = @enumFromInt(f.value);
            const fixed = fixedOccupants(design, loc, &buf).len;
            const free = design.crit_slots[f.value];
            const total = physicalTotal(loc);
            if (fixed + free != total) {
                std.debug.print("{s} {s}: fixed {d} + free {d} = {d}, expected {d}\n", .{ design.key, f.name, fixed, free, fixed + free, total });
                return error.TestUnexpectedResult;
            }
        }
    }
}
