//! Static P2e artillery construction catalogue.
//! MekHQ counterpart: MegaMek `.blk` vehicle records (docs/mekhq-map.md).
//! It has no acquisition, campaign-state, or market surface
//! (docs/p2-artillery-domain-research.md).

const std = @import("std");
const calc = @import("artillery_calculators.zig");

pub const source_revision = "2a62993f8da306f489116233d489d1f6222945e3";
pub const mobile_long_tom_source_path = "data/mekfiles/vehicles/3039u/Mobile Long Tom LT-MOB-25.blk";

pub const Entry = struct {
    key: []const u8,
    name: []const u8,
    model: []const u8,
    category: enum { mobile_artillery_carrier },
    intro_year: u16,
    source_revision: []const u8,
    source_path: []const u8,
    vehicle: calc.CombatVehicleSpec,
    mounts: []const calc.MountedEquipment,
};

pub const equipment = [_]calc.EquipmentSpec{
    .{ .key = "long_tom", .kind = .weapon, .bv = 368, .cost = 450_000 },
    .{ .key = "machine_gun", .kind = .weapon, .bv = 5, .cost = 5_000 },
    .{ .key = "long_tom_ammo", .kind = .ammunition, .bv = 92, .cost = 20_000, .ammo_for = "long_tom" },
    .{ .key = "machine_gun_ammo_half", .kind = .ammunition, .bv = 1, .cost = 500, .ammo_for = "machine_gun" },
    .{ .key = "communications_size_3", .kind = .misc, .bv = 0, .cost = 30_000 },
    .{ .key = "hitch", .kind = .misc, .bv = 0, .cost = 0 },
};

const mobile_long_tom_vehicle = calc.CombatVehicleSpec{
    .tons = 75,
    .cruise_mp = 3,
    .engine_rating = 225,
    .armor = .{ 16, 16, 16, 16 },
    .internal_structure = 8,
    .is_tracked = true,
    .is_ice = true,
};

const mobile_long_tom_mounts = [_]calc.MountedEquipment{
    .{ .key = "long_tom", .count = 1, .location = .front },
    .{ .key = "long_tom_ammo", .count = 4, .location = .body },
    .{ .key = "machine_gun", .count = 2, .location = .right },
    .{ .key = "machine_gun", .count = 2, .location = .left },
    .{ .key = "machine_gun_ammo_half", .count = 1, .location = .body },
    .{ .key = "communications_size_3", .count = 1, .location = .body },
    .{ .key = "hitch", .count = 1, .location = .rear },
};

pub const catalogue: []const Entry = @import("artillery_zon");

/// Calculates the entry's sole BV and integer C-bill values from construction
/// inputs. No static BV or cost literal is admitted in the catalogue.
pub fn calculated(entry: *const Entry) !calc.VehicleCalculation {
    return calc.calculate(entry.vehicle, &equipment, entry.mounts);
}

pub fn find(key: []const u8) ?*const Entry {
    for (catalogue) |*entry| if (std.mem.eql(u8, entry.key, key)) return entry;
    return null;
}

pub fn validate() !void {
    if (catalogue.len != 1) return error.InvalidCatalogueEntry;
    const entry = catalogue[0];
    try validateMobileLongTom(entry);
    _ = try calculated(&entry);
}

fn validateMobileLongTom(entry: Entry) !void {
    if (!std.mem.eql(u8, entry.key, "LT-MOB-25") or
        !std.mem.eql(u8, entry.name, "Mobile Long Tom Artillery") or
        !std.mem.eql(u8, entry.model, "LT-MOB-25") or
        entry.category != .mobile_artillery_carrier or
        entry.intro_year != 2602 or
        !std.mem.eql(u8, entry.source_revision, source_revision) or
        !std.mem.eql(u8, entry.source_path, mobile_long_tom_source_path) or
        !std.meta.eql(entry.vehicle, mobile_long_tom_vehicle) or
        entry.mounts.len != mobile_long_tom_mounts.len)
        return error.InvalidCatalogueEntry;

    for (entry.mounts, mobile_long_tom_mounts) |mount, approved| {
        if (!std.mem.eql(u8, mount.key, approved.key) or mount.count != approved.count or mount.location != approved.location)
            return error.InvalidCatalogueEntry;
    }
}

test "data: artillery catalogue accepts the fractional MegaMek result and exposes integer C-bills" {
    try validate();
    const entry = find("LT-MOB-25").?;
    const value = try calculated(entry);
    try std.testing.expectEqual(@as(i64, 177_931_250), value.mega_mek_cost_cents);
    try std.testing.expectEqual(@as(i64, 1_779_313), value.cost);
    try std.testing.expectEqual(@as(u16, 782), value.bv);
    try std.testing.expectEqual(@as(i64, 281_250), value.engine_cost);
    try std.testing.expectEqual(@as(i64, 40_000), value.armor_cost);
    try std.testing.expectEqual(@as(i64, 75_000), value.structure_cost);
    try std.testing.expectEqual(@as(i64, 40_000), value.control_cost);
    try std.testing.expectEqual(@as(i64, 580_500), value.equipment_cost);
}

test "data: artillery catalogue rejects changes to pinned Mobile Long Tom construction facts" {
    var entry = catalogue[0];
    try validateMobileLongTom(entry);

    entry.source_revision = "__wrong_revision__";
    try std.testing.expectError(error.InvalidCatalogueEntry, validateMobileLongTom(entry));

    entry = catalogue[0];
    entry.source_path = "data/mekfiles/vehicles/3039u/__wrong__.blk";
    try std.testing.expectError(error.InvalidCatalogueEntry, validateMobileLongTom(entry));

    var mounts = mobile_long_tom_mounts;
    mounts[1].count = 3;
    entry = catalogue[0];
    entry.mounts = &mounts;
    try std.testing.expectError(error.InvalidCatalogueEntry, validateMobileLongTom(entry));

    mounts = mobile_long_tom_mounts;
    mounts[2].location = .left;
    entry.mounts = &mounts;
    try std.testing.expectError(error.InvalidCatalogueEntry, validateMobileLongTom(entry));
}
