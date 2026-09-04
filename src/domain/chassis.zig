//! Static chassis catalog: the designs meks are instances of.
//! Data lives in data/chassis.zon (curated 3025 set), imported at comptime —
//! MekHQ reads MegaMek's .mtf files here; we re-encode a curated set instead
//! (licensing note in ARCHITECTURE §12).

const std = @import("std");
const types = @import("types.zig");
const unit = @import("unit.zig");

pub const WeightClass = enum { light, medium, heavy, assault };

pub const LoadoutSlot = struct {
    slot: []const u8, // e.g. "ra.ppc.1"
    part: []const u8, // part catalog key
    class: unit.SlotClass,
};

pub const Chassis = struct {
    key: []const u8, // variant designation, e.g. "SHD-2H"
    name: []const u8, // "Shadow Hawk"
    tonnage: u8,
    bv: u16, // BV2 — autoresolve base strength (ARCH §7)
    cost: types.CBills,
    rarity: types.Rarity, // market appearance tier (ARCH §9.8)
    kind: unit.UnitKind = .mek,
    // Construction facts (Stage 10 MekLab; meks only, defaults for others).
    walk_mp: u8 = 0,
    jump_mp: u8 = 0,
    heat_sinks: u8 = 10,
    armor_half_tons: u16 = 0,
    loadout: []const LoadoutSlot,

    pub fn engineRating(self: *const Chassis) u32 {
        return @as(u32, self.tonnage) * self.walk_mp;
    }

    pub fn weightClass(self: *const Chassis) WeightClass {
        return switch (self.tonnage) {
            0...35 => .light,
            36...55 => .medium,
            56...75 => .heavy,
            else => .assault,
        };
    }
};

pub const catalog: []const Chassis = @import("chassis_zon");

pub fn find(key: []const u8) ?*const Chassis {
    for (catalog) |*c| {
        if (std.mem.eql(u8, c.key, key)) return c;
    }
    return null;
}

/// All *mek* entries of one weight class — the company generator's RAT
/// (random assignment table) pool.
pub fn ofWeightClass(class: WeightClass, buf: []*const Chassis) []*const Chassis {
    var n: usize = 0;
    for (catalog) |*c| {
        if (c.kind == .mek and c.weightClass() == class and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Meks suitable for a scout lance: at or under `max_tonnage`.
pub fn scoutPool(max_tonnage: u8, buf: []*const Chassis) []*const Chassis {
    var n: usize = 0;
    for (catalog) |*c| {
        if (c.kind == .mek and c.tonnage <= max_tonnage and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

test "catalog loads from zon with sane values and unique keys" {
    try std.testing.expect(catalog.len >= 12);
    for (catalog, 0..) |c, i| {
        try std.testing.expect(c.bv > 0);
        try std.testing.expect(c.cost > 0);
        if (c.kind == .mek) try std.testing.expect(c.tonnage >= 20 and c.tonnage <= 100);
        try std.testing.expect(c.loadout.len > 0);
        for (catalog[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, c.key, other.key));
        }
    }
}

test "scout pool excludes heavies and support vehicles" {
    var buf: [32]*const Chassis = undefined;
    const scouts = scoutPool(40, &buf);
    try std.testing.expect(scouts.len >= 3);
    for (scouts) |c| {
        try std.testing.expect(c.tonnage <= 40);
        try std.testing.expectEqual(unit.UnitKind.mek, c.kind);
    }
}

test "find and weight classes" {
    const shd = find("SHD-2H").?;
    try std.testing.expectEqualStrings("Shadow Hawk", shd.name);
    try std.testing.expectEqual(WeightClass.medium, shd.weightClass());
    try std.testing.expectEqual(WeightClass.assault, find("AS7-D").?.weightClass());
    try std.testing.expect(find("MAD-CAT") == null); // wrong era, chummer

    var buf: [32]*const Chassis = undefined;
    const lights = ofWeightClass(.light, &buf);
    try std.testing.expect(lights.len >= 3);
}
