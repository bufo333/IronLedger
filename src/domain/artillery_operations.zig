//! Canonical artillery seats, equipment and sealed reload units.
//! No MekHQ counterpart: project operations policy (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");
const unit = @import("unit.zig");
const person = @import("person.zig");
const part = @import("part.zig");
const catalogue = @import("artillery_catalogue.zig");

/// Project units and compatibility order: docs/p2-artillery-operations-design.md.
pub const maintenance_age_days: u32 = 14;
pub const damaged_chassis_sale_cap_pct: u8 = 50;
pub const reserve_floor_loads: u32 = 1;
pub const reserve_target_loads: u32 = 2;
pub const long_tom_rounds_per_bin: u16 = 5;
pub const mg_rounds_per_bin: u16 = 100;

pub const Seat = enum { commander, gunner, driver, loader };
pub const seats = std.enums.values(Seat);
pub const crew_count: u32 = seats.len;
pub const Family = enum { long_tom, machine_gun };
pub const families = std.enums.values(Family);

/// Stable normalized-row identities; never reorder existing entries.
pub const Slot = enum {
    chassis,
    main_gun,
    machine_gun_right_1,
    machine_gun_right_2,
    machine_gun_left_1,
    machine_gun_left_2,
    long_tom_bin_1,
    long_tom_bin_2,
    long_tom_bin_3,
    long_tom_bin_4,
    machine_gun_bin,
    communications,
    hitch,
};

pub const Descriptor = struct {
    slot: Slot,
    catalogue_key: ?[]const u8,
    class: unit.SlotClass,
    spare_key: []const u8,
    family: ?Family = null,
    capacity_rounds: u16 = 0,
};

pub const descriptors = [_]Descriptor{
    .{ .slot = .chassis, .catalogue_key = null, .class = .structure, .spare_key = "comp_chassis_h" },
    .{ .slot = .main_gun, .catalogue_key = "long_tom", .class = .weapon, .spare_key = "artillery_spares" },
    .{ .slot = .machine_gun_right_1, .catalogue_key = "machine_gun", .class = .weapon, .spare_key = "mg" },
    .{ .slot = .machine_gun_right_2, .catalogue_key = "machine_gun", .class = .weapon, .spare_key = "mg" },
    .{ .slot = .machine_gun_left_1, .catalogue_key = "machine_gun", .class = .weapon, .spare_key = "mg" },
    .{ .slot = .machine_gun_left_2, .catalogue_key = "machine_gun", .class = .weapon, .spare_key = "mg" },
    .{ .slot = .long_tom_bin_1, .catalogue_key = "long_tom_ammo", .class = .ammo, .spare_key = "artillery_spares", .family = .long_tom, .capacity_rounds = long_tom_rounds_per_bin },
    .{ .slot = .long_tom_bin_2, .catalogue_key = "long_tom_ammo", .class = .ammo, .spare_key = "artillery_spares", .family = .long_tom, .capacity_rounds = long_tom_rounds_per_bin },
    .{ .slot = .long_tom_bin_3, .catalogue_key = "long_tom_ammo", .class = .ammo, .spare_key = "artillery_spares", .family = .long_tom, .capacity_rounds = long_tom_rounds_per_bin },
    .{ .slot = .long_tom_bin_4, .catalogue_key = "long_tom_ammo", .class = .ammo, .spare_key = "artillery_spares", .family = .long_tom, .capacity_rounds = long_tom_rounds_per_bin },
    .{ .slot = .machine_gun_bin, .catalogue_key = "machine_gun_ammo_half", .class = .ammo, .spare_key = "artillery_spares", .family = .machine_gun, .capacity_rounds = mg_rounds_per_bin },
    .{ .slot = .communications, .catalogue_key = "communications_size_3", .class = .equipment, .spare_key = "artillery_spares" },
    .{ .slot = .hitch, .catalogue_key = "hitch", .class = .equipment, .spare_key = "artillery_spares" },
};

/// Persisted condition and exact loaded rounds; non-ammunition slots carry zero.
pub const SlotState = struct { condition: unit.PartCondition = .ok, rounds: u16 = 0 };
pub const Slots = [descriptors.len]SlotState;
pub const Crew = [seats.len]types.PersonId;

/// Seat qualification requires an explicit skill; absent values never qualify.
/// Source: operations design, Crew and personnel policy.
pub fn seatSkill(seat: Seat) types.SkillType {
    return if (seat == .driver) .driving_vee else .gunnery_vee;
}

/// Role and learned-skill qualification only; availability/location belong to sim.
pub fn qualified(p: *const person.Person, seat: Seat) bool {
    return p.role == .vehicle_crew and p.skill(seatSkill(seat)) != null;
}

/// The descriptor for a persisted canonical identity; pure and total.
pub fn descriptor(slot: Slot) *const Descriptor {
    return &descriptors[@intFromEnum(slot)];
}

/// One sealed warehouse unit refills one empty intact bin in this family.
pub fn packageKey(family: Family) []const u8 {
    return switch (family) {
        .long_tom => "ammo_long_tom",
        .machine_gun => "ammo_artillery_mg",
    };
}

/// Packages per complete reload, derived from canonical bin descriptors.
pub fn packagesPerLoad(family: Family) u32 {
    var count: u32 = 0;
    for (descriptors) |d| if (d.family == family) {
        count += 1;
    };
    return count;
}

/// Validate storage invariants without repairing magazines or conditions.
pub fn validateSlots(slots: *const Slots) error{CorruptSave}!void {
    for (descriptors, slots) |d, s| {
        if (s.rounds > d.capacity_rounds) return error.CorruptSave;
        if ((s.condition == .destroyed or s.condition == .missing) and s.rounds != 0) return error.CorruptSave;
    }
}

test "seat qualification selects present vehicle skills without defaults" {
    var p: person.Person = .{ .id = @enumFromInt(1), .first_name = "A", .last_name = "B", .role = .vehicle_crew };
    defer p.skills.deinit(std.testing.allocator);
    for (seats) |s| try std.testing.expect(!qualified(&p, s));
    try p.skills.put(std.testing.allocator, .gunnery_vee, 4);
    for (seats) |s| try std.testing.expectEqual(s != .driver, qualified(&p, s));
    try p.skills.put(std.testing.allocator, .driving_vee, 5);
    for (seats) |s| try std.testing.expect(qualified(&p, s));
    try std.testing.expectEqual(types.SkillType.driving_vee, seatSkill(.driver));
}

test "data: artillery descriptors preserve every catalogue mount and supply metadata" {
    const entry = catalogue.catalogue[0];
    for (catalogue.equipment) |equipment| {
        var mounts: u32 = 0;
        for (entry.mounts) |m| if (std.mem.eql(u8, m.key, equipment.key)) {
            mounts += m.count;
        };
        var slots: u32 = 0;
        for (descriptors) |d| if (d.catalogue_key) |key| {
            if (std.mem.eql(u8, key, equipment.key)) slots += 1;
        };
        try std.testing.expectEqual(mounts, slots);
    }
    for (descriptors, 0..) |d, i| {
        try std.testing.expectEqual(i, @intFromEnum(d.slot));
        try std.testing.expectEqualDeep(d, descriptor(d.slot).*);
        try std.testing.expect(part.find(d.spare_key) != null);
    }
    try std.testing.expectEqualStrings(part.componentForSlotClass("chassis.structure", .heavy), descriptor(.chassis).spare_key);
    for (families) |family| {
        const p = part.find(packageKey(family)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(part.MountType.none, p.mount);
        try std.testing.expectEqual(@as(u16, 1), p.pallet_tons);
        try std.testing.expectEqual(entry.intro_year, p.intro_year);
        try std.testing.expectEqual(part.TechBase.inner_sphere, p.tech_base);
        try std.testing.expectEqual(if (family == .long_tom) types.Rarity.rare else types.Rarity.common, p.rarity);
        try std.testing.expectEqual(if (family == .long_tom) part.Availability.e else part.Availability.b, p.availability);
        var rounds: u32 = 0;
        for (descriptors) |d| if (d.family == family) {
            rounds += d.capacity_rounds;
        };
        try std.testing.expectEqual(packagesPerLoad(family) * @as(u32, if (family == .long_tom) long_tom_rounds_per_bin else mg_rounds_per_bin), rounds);
    }
    const spare = part.find("artillery_spares") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(part.MountType.none, spare.mount);
    try std.testing.expectEqual(@as(u16, 1), spare.pallet_tons);
    try std.testing.expectEqual(entry.intro_year, spare.intro_year);
    try std.testing.expectEqual(types.Rarity.uncommon, spare.rarity);
    try std.testing.expectEqual(part.Availability.d, spare.availability);
}

test "slot validation rejects overflow and rounds in missing bins" {
    var slots: Slots = @splat(.{});
    try validateSlots(&slots);
    slots[@intFromEnum(Slot.long_tom_bin_1)].rounds = long_tom_rounds_per_bin + 1;
    try std.testing.expectError(error.CorruptSave, validateSlots(&slots));
    slots[@intFromEnum(Slot.long_tom_bin_1)] = .{ .condition = .missing, .rounds = 1 };
    try std.testing.expectError(error.CorruptSave, validateSlots(&slots));
}
