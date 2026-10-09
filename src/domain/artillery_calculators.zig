//! P2e conventional-artillery vehicle BV and cost calculations.
//! MekHQ counterpart: MegaMek `CombatVehicleBVCalculator.java` and
//! `CombatVehicleCostCalculator.java` (docs/mekhq-map.md).

const std = @import("std");
const types = @import("types.zig");

pub const Location = enum { body, front, right, left, rear };
pub const EquipmentKind = enum { weapon, ammunition, misc };

pub const EquipmentSpec = struct {
    key: []const u8,
    kind: EquipmentKind,
    bv: i64,
    cost: types.CBills,
    ammo_for: ?[]const u8 = null,
};

pub const MountedEquipment = struct {
    key: []const u8,
    count: u8,
    location: Location,
};

pub const CombatVehicleSpec = struct {
    tons: u16,
    cruise_mp: u8,
    engine_rating: u16,
    armor: [4]u16,
    internal_structure: u16,
    is_tracked: bool,
    is_ice: bool,
    is_support: bool = false,
    is_superheavy: bool = false,
    is_omni: bool = false,
    has_turret: bool = false,
    has_patchwork_armor: bool = false,
    has_special_modifier: bool = false,
};

pub const VehicleCalculation = struct {
    armor_bv_hundredths: i64,
    defensive_bv_hundredths: i64,
    weapon_bv: i64,
    ammunition_bv: i64,
    weight_bv_hundredths: i64,
    offensive_bv_hundredths: i64,
    speed_factor_hundredths: i64,
    engine_cost: types.CBills,
    armor_cost: types.CBills,
    structure_cost: types.CBills,
    control_cost: types.CBills,
    equipment_cost: types.CBills,
    mega_mek_cost_cents: i64,
    bv: u16,
    cost: types.CBills,
};

/// Converts a non-negative, MegaMek-cent-rounded cost to project integer
/// C-bills by ceiling division. Project money has no cent representation
/// (docs/p2-artillery-domain-research.md; engineering-contract rule 54).
pub fn ceilMegaMekCostCentsToCBills(cents: i64) error{ NegativeCost, Overflow }!types.CBills {
    if (cents < 0) return error.NegativeCost;
    const adjusted = std.math.add(i64, cents, 99) catch return error.Overflow;
    return @divFloor(adjusted, 100);
}

/// Calculates the cited tracked, non-support conventional-vehicle subset.
/// Inputs are construction facts and resolved equipment only; this is pure and
/// deterministic. Unsupported construction and arithmetic overflow refuse.
pub fn calculate(spec: CombatVehicleSpec, equipment: []const EquipmentSpec, mounts: []const MountedEquipment) !VehicleCalculation {
    if (spec.tons == 0 or spec.internal_structure == 0) return error.InvalidConstruction;
    if (spec.cruise_mp != 3 or spec.engine_rating == 0 or !spec.is_tracked or !spec.is_ice or
        spec.is_support or spec.is_superheavy or spec.is_omni or spec.has_turret or spec.has_patchwork_armor or spec.has_special_modifier)
        return error.UnsupportedVehicle;
    if (@as(i64, spec.engine_rating) != try mul(spec.tons, spec.cruise_mp)) return error.InvalidEngineRating;
    if (mounts.len == 0) return error.MissingEquipment;

    for (equipment, 0..) |item, i| {
        if (item.key.len == 0 or item.bv < 0 or item.cost < 0) return error.InvalidEquipment;
        for (equipment[i + 1 ..]) |other| if (std.mem.eql(u8, item.key, other.key)) return error.DuplicateEquipmentKey;
    }
    var weapons_bv: i64 = 0;
    var equipment_cost: types.CBills = 0;
    for (mounts, 0..) |mount, i| {
        if (mount.count == 0) return error.InvalidEquipmentCount;
        for (mounts[i + 1 ..]) |other| {
            if (std.mem.eql(u8, mount.key, other.key) and mount.location == other.location) return error.DuplicateEquipmentIdentity;
        }
        const item = findEquipment(equipment, mount.key) orelse return error.UnknownEquipment;
        const count: i64 = mount.count;
        equipment_cost = try add(equipment_cost, try mul(item.cost, count));
        switch (item.kind) {
            .weapon => weapons_bv = try add(weapons_bv, try mul(item.bv, count)),
            .ammunition => {
                if (item.ammo_for == null) return error.MissingAmmoData;
            },
            .misc => {},
        }
    }
    for (equipment) |item| if (item.kind == .ammunition) {
        const weapon_key = item.ammo_for orelse return error.MissingAmmoData;
        if (findEquipment(equipment, weapon_key) == null) return error.MissingAmmoData;
    };

    const armor_points = try sumArmor(spec.armor);
    const armor_bv = try mul(armor_points, 250);
    const structure_bv = try mul(@as(i64, spec.internal_structure), 150);
    var defensive = try add(armor_bv, structure_bv);
    defensive = @divFloor(try mul(defensive, 90), 100);
    defensive = @divFloor(try mul(defensive, 110), 100);

    const capped_ammo = try cappedAmmunitionBv(equipment, mounts);
    var offensive = try add(try add(try mul(weapons_bv, 100), try mul(capped_ammo, 100)), try mul(@as(i64, spec.tons), 50));
    const speed_factor = try mobileLongTomSpeedFactorHundredths(spec.cruise_mp);
    offensive = @divFloor(try mul(offensive, speed_factor), 100);
    const final_bv = try roundHalfUp(try add(defensive, offensive), 100);
    if (final_bv > std.math.maxInt(u16)) return error.Overflow;

    const engine_cost = @divExact(try mul(try mul(1_250, spec.engine_rating), spec.tons), 75);
    const armor_cost = try halfTonCost(armor_points, 16);
    const structure_cost = try halfTonCost(spec.tons, 10);
    const control_cost = try halfTonCost(try mul(spec.tons, 5), 100);
    const subtotal = try add(try add(try add(engine_cost, armor_cost), try add(structure_cost, control_cost)), equipment_cost);
    const cents = try roundMegaMekCostToCentsUp(try mul(subtotal, 100 + @as(i64, spec.tons)), 1);
    return .{
        .armor_bv_hundredths = armor_bv,
        .defensive_bv_hundredths = defensive,
        .weapon_bv = weapons_bv,
        .ammunition_bv = capped_ammo,
        .weight_bv_hundredths = try mul(spec.tons, 50),
        .offensive_bv_hundredths = offensive,
        .speed_factor_hundredths = speed_factor,
        .engine_cost = engine_cost,
        .armor_cost = armor_cost,
        .structure_cost = structure_cost,
        .control_cost = control_cost,
        .equipment_cost = equipment_cost,
        .mega_mek_cost_cents = cents,
        .bv = @intCast(final_bv),
        .cost = try ceilMegaMekCostCentsToCBills(cents),
    };
}

fn findEquipment(equipment: []const EquipmentSpec, key: []const u8) ?EquipmentSpec {
    for (equipment) |item| if (std.mem.eql(u8, item.key, key)) return item;
    return null;
}

fn cappedAmmunitionBv(equipment: []const EquipmentSpec, mounts: []const MountedEquipment) !i64 {
    var total: i64 = 0;
    for (equipment) |ammo| {
        if (ammo.kind != .ammunition) continue;
        const weapon_key = ammo.ammo_for orelse return error.MissingAmmoData;
        var ammo_bv: i64 = 0;
        var weapon_bv: i64 = 0;
        for (mounts) |mount| {
            if (std.mem.eql(u8, mount.key, ammo.key)) ammo_bv = try add(ammo_bv, try mul(ammo.bv, mount.count));
            if (std.mem.eql(u8, mount.key, weapon_key)) {
                const weapon = findEquipment(equipment, weapon_key) orelse return error.MissingAmmoData;
                weapon_bv = try add(weapon_bv, try mul(weapon.bv, mount.count));
            }
        }
        total = try add(total, @min(ammo_bv, weapon_bv));
    }
    return total;
}

fn sumArmor(armor: [4]u16) !i64 {
    var result: i64 = 0;
    for (armor) |points| result = try add(result, points);
    return result;
}

fn halfTonCost(numerator: i64, denominator: i64) !i64 {
    const half_tons = @divFloor(try add(try mul(numerator, 2), denominator - 1), denominator);
    return mul(half_tons, 5_000);
}

fn mobileLongTomSpeedFactorHundredths(mp: u8) error{UnsupportedMovement}!i64 {
    if (mp != 3) return error.UnsupportedMovement;
    return 77;
}

fn roundHalfUp(value: i64, divisor: i64) !i64 {
    return @divFloor(try add(value, @divFloor(divisor, 2)), divisor);
}

/// Reproduces MegaMek's non-negative `RoundingMode.UP` final cost scale of
/// two decimal places. The numerator and denominator are C-bill cents.
fn roundMegaMekCostToCentsUp(numerator: i64, denominator: i64) !i64 {
    if (numerator < 0 or denominator <= 0) return error.InvalidCost;
    return @divFloor(try add(numerator, denominator - 1), denominator);
}

fn add(a: i64, b: i64) error{Overflow}!i64 {
    return std.math.add(i64, a, b) catch error.Overflow;
}

fn mul(a: anytype, b: anytype) error{Overflow}!i64 {
    return std.math.mul(i64, @intCast(a), @intCast(b)) catch error.Overflow;
}

test "MegaMek cents round upward then project conversion ceilings to C-bills" {
    try std.testing.expectEqual(@as(types.CBills, 1_779_313), try ceilMegaMekCostCentsToCBills(177_931_250));
    try std.testing.expectEqual(@as(types.CBills, 1), try ceilMegaMekCostCentsToCBills(100));
    try std.testing.expectEqual(@as(types.CBills, 2), try ceilMegaMekCostCentsToCBills(101));
    try std.testing.expectEqual(@as(types.CBills, 2), try ceilMegaMekCostCentsToCBills(150));
    try std.testing.expectEqual(@as(types.CBills, @divFloor(std.math.maxInt(i64), 100)), try ceilMegaMekCostCentsToCBills(std.math.maxInt(i64) - 99));
    try std.testing.expectError(error.NegativeCost, ceilMegaMekCostCentsToCBills(-1));
    try std.testing.expectError(error.Overflow, ceilMegaMekCostCentsToCBills(std.math.maxInt(i64)));
}

test "calculator rejects construction outside its cited Mobile Long Tom subset" {
    const spec = CombatVehicleSpec{
        .tons = 75,
        .cruise_mp = 3,
        .engine_rating = 225,
        .armor = .{ 16, 16, 16, 16 },
        .internal_structure = 8,
        .is_tracked = true,
        .is_ice = true,
        .is_support = true,
    };
    try std.testing.expectError(error.UnsupportedVehicle, calculate(spec, &.{}, &.{}));
}

test "calculator preserves MegaMek cents until the sole C-bill conversion" {
    const equipment = [_]EquipmentSpec{
        .{ .key = "long_tom", .kind = .weapon, .bv = 368, .cost = 450_000 },
        .{ .key = "machine_gun", .kind = .weapon, .bv = 5, .cost = 5_000 },
        .{ .key = "long_tom_ammo", .kind = .ammunition, .bv = 92, .cost = 20_000, .ammo_for = "long_tom" },
        .{ .key = "machine_gun_ammo_half", .kind = .ammunition, .bv = 1, .cost = 500, .ammo_for = "machine_gun" },
        .{ .key = "communications_size_3", .kind = .misc, .bv = 0, .cost = 30_000 },
        .{ .key = "hitch", .kind = .misc, .bv = 0, .cost = 0 },
    };
    const mounts = [_]MountedEquipment{
        .{ .key = "long_tom", .count = 1, .location = .front },
        .{ .key = "long_tom_ammo", .count = 4, .location = .body },
        .{ .key = "machine_gun", .count = 2, .location = .right },
        .{ .key = "machine_gun", .count = 2, .location = .left },
        .{ .key = "machine_gun_ammo_half", .count = 1, .location = .body },
        .{ .key = "communications_size_3", .count = 1, .location = .body },
        .{ .key = "hitch", .count = 1, .location = .rear },
    };
    const value = try calculate(.{
        .tons = 75,
        .cruise_mp = 3,
        .engine_rating = 225,
        .armor = .{ 16, 16, 16, 16 },
        .internal_structure = 8,
        .is_tracked = true,
        .is_ice = true,
    }, &equipment, &mounts);
    try std.testing.expectEqual(@as(i64, 177_931_250), value.mega_mek_cost_cents);
    try std.testing.expectEqual(@as(types.CBills, 1_779_313), value.cost);
}

test "calculator refuses overflowing construction arithmetic" {
    const equipment = [_]EquipmentSpec{.{ .key = "weapon", .kind = .weapon, .bv = 1, .cost = std.math.maxInt(i64) }};
    const mounts = [_]MountedEquipment{.{ .key = "weapon", .count = 2, .location = .front }};
    try std.testing.expectError(error.Overflow, calculate(.{
        .tons = 75,
        .cruise_mp = 3,
        .engine_rating = 225,
        .armor = .{ 16, 16, 16, 16 },
        .internal_structure = 8,
        .is_tracked = true,
        .is_ice = true,
    }, &equipment, &mounts));
}
