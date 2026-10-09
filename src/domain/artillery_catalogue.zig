//! Static P2e artillery construction catalogue.
//! MekHQ counterpart: MegaMek `.blk` vehicle records (docs/mekhq-map.md).
//! It has no acquisition, campaign-state, or market surface
//! (docs/p2-artillery-domain-research.md).

const std = @import("std");
const calc = @import("artillery_calculators.zig");

pub const source_revision = "2a62993f8da306f489116233d489d1f6222945e3";

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
    for (catalogue, 0..) |entry, i| {
        if (entry.key.len == 0 or entry.name.len == 0 or entry.model.len == 0 or entry.intro_year > 3025 or
            !std.mem.eql(u8, entry.source_revision, source_revision) or entry.source_path.len == 0)
            return error.InvalidCatalogueEntry;
        for (catalogue[i + 1 ..]) |other| if (std.mem.eql(u8, entry.key, other.key)) return error.DuplicateCatalogueKey;
        _ = try calculated(&entry);
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
