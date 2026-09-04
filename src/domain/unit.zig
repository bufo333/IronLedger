//! Units: meks, vehicles, aerospace, support assets, transports.
//! Mirrors MekHQ `unit/Unit.java`. Per-unit state only — the static design
//! (tonnage, loadout, BV) comes from the chassis catalog in data/ (Stage 3).

const std = @import("std");
const types = @import("types.zig");

pub const UnitKind = enum {
    mek,
    vehicle,
    aerospace,
    battle_armor,
    infantry,
    // Support echelon — these fight nobody but win battles (ARCH §3.4):
    mash,
    mobile_field_base,
    cargo,
    dropship,
    jumpship,

    pub fn isCombat(self: UnitKind) bool {
        return switch (self) {
            .mek, .vehicle, .aerospace, .battle_armor, .infantry => true,
            else => false,
        };
    }
};

pub const UnitStatus = enum { ready, damaged, repairing, refitting, mothballed, destroyed, in_transit };

const Role = @import("person.zig").Role;

/// Who sits in the crew slot for this kind of hull.
pub fn crewRoleFor(kind: UnitKind) Role {
    return switch (kind) {
        .mek => .mekwarrior,
        .vehicle, .mash, .mobile_field_base, .cargo => .vehicle_crew,
        .aerospace => .aero_pilot,
        .battle_armor => .ba_trooper,
        .infantry => .infantry,
        .dropship => .dropship_crew,
        .jumpship => .jumpship_crew,
    };
}

/// Who keeps this kind of hull running (null = self-maintaining).
pub fn techRoleFor(kind: UnitKind) ?Role {
    return switch (kind) {
        .mek => .tech_mek,
        .vehicle, .mash, .mobile_field_base, .cargo => .tech_mechanic,
        .aerospace, .dropship, .jumpship => .tech_aero,
        .battle_armor => .tech_ba,
        .infantry => null,
    };
}

/// Weekly maintenance hours a hull costs its tech, by kind and tonnage
/// (Stage 9C.2 tech-time budget). // TUNE
pub fn maintenanceHours(kind: UnitKind, tonnage: u8) u32 {
    return switch (kind) {
        .mek => if (tonnage <= 35) @as(u32, 4) else if (tonnage <= 55) 6 else if (tonnage <= 75) 8 else 10,
        .vehicle, .mash, .mobile_field_base, .cargo => 4,
        .aerospace => 8,
        .battle_armor => 2,
        .infantry => 0,
        .dropship => 20,
        .jumpship => 30,
    };
}

// ---------------------------------------- the hangar ledger (ARCH §9.8)
// Every hull owned bills monthly, running or not: hangar space, transport
// allocation, insurance, tech attention. Cold storage (mothballing at a
// regional HQ) cuts the bill to a fraction but costs reactivation time.

/// Monthly per-hull carry cost by unit kind, C-bills. // TUNE
pub fn monthlyCarryCost(kind: UnitKind) types.CBills {
    return switch (kind) {
        .mek => 2_000,
        .vehicle => 1_200,
        .aerospace => 3_000,
        .battle_armor => 500,
        .infantry => 200,
        .mash, .mobile_field_base => 800,
        .cargo => 500,
        .dropship => 15_000,
        .jumpship => 50_000,
    };
}

/// Cold-storage carry cost: 20% of active. // TUNE
pub const cold_storage_cost_bp: types.Bp = 2_000;

pub fn carryCost(kind: UnitKind, in_cold_storage: bool) types.CBills {
    const base = monthlyCarryCost(kind);
    return if (in_cold_storage) types.applyBp(base, cold_storage_cost_bp) else base;
}

/// Tech-days to wake a mothballed hull before it can transfer or fight;
/// a neglected machine (low quality) takes longer. // TUNE
pub fn reactivationDays(quality: types.Quality) u32 {
    return 7 + (5 - @as(u32, @intFromEnum(quality))) * 3; // F: 7 days .. A: 22
}

pub const PartCondition = enum { ok, damaged, destroyed, missing };

/// What kind of thing occupies a slot — decides the repair echelon (ARCH §9.7).
pub const SlotClass = enum { armor, structure, weapon, equipment, ammo };

/// Where a repair can happen. Field: the company's own techs, given spare
/// parts. Depot: a regional/brigade HQ mek bay, over real bay time.
pub const RepairTier = enum { field, depot };

/// Repair echelon for a damaged slot (null = nothing to repair):
/// armor patching, weapon/equipment swaps and ammo reloads are field work;
/// internal structure (torso/limbs) is depot work, always.
pub fn repairTier(class: SlotClass, condition: PartCondition) ?RepairTier {
    if (condition == .ok) return null;
    return switch (class) {
        .armor, .weapon, .equipment, .ammo => .field,
        .structure => .depot,
    };
}

/// One equipment/structure slot on a unit; battle damage lands here and
/// repair work + parts demand derive from it (Stage 5/7).
pub const PartSlot = struct {
    slot_key: []const u8, // e.g. "right_torso.medium_laser.1"
    part_key: []const u8, // catalog key in data/parts/
    class: SlotClass = .equipment,
    condition: PartCondition = .ok,
};

pub const Unit = struct {
    id: types.UnitId,
    chassis_key: []const u8, // catalog key, e.g. "SHD-2H"
    name: ?[]const u8 = null, // nickname
    kind: UnitKind,
    force: types.ForceId = .none,
    /// Crew slot (pilot/driver/leader) and the assigned technician (Stage
    /// 9C.2, MekHQ-style): no tech → no maintenance, repairs or reloads;
    /// no pilot → the hull doesn't fight. Multi-crew kinds grow a crew list
    /// later (schema models unit_crew).
    pilot: types.PersonId = .none,
    tech: types.PersonId = .none,
    armor_pct: u8 = 100,
    quality: types.Quality = .c,
    status: UnitStatus = .ready,
    slots: std.ArrayListUnmanaged(PartSlot) = .empty,
    last_maintenance_day: ?u32 = null,
    acquired_day: u32 = 0,
    purchase_price: types.CBills = 0,
    /// Non-null while techs wake this hull from cold storage (ARCH §9.8).
    reactivation_done_day: ?u32 = null,

    pub fn deinit(self: *Unit, alloc: std.mem.Allocator) void {
        self.slots.deinit(alloc);
    }

    /// Combat effectiveness of this hull before crew/campaign modifiers,
    /// as a percentage (0–100). Inputs to autoresolve (ARCH §7). Stage 7
    /// replaces this with BV-derived strength from the chassis catalog.
    pub fn conditionPct(self: *const Unit) u8 {
        if (self.status == .destroyed or self.status == .mothballed) return 0;
        var pct: u32 = self.armor_pct;
        for (self.slots.items) |s| {
            switch (s.condition) {
                .ok => {},
                .damaged => pct = pct * 95 / 100,
                .destroyed, .missing => pct = pct * 85 / 100,
            }
        }
        return @intCast(@min(pct, 100));
    }

    pub fn inColdStorage(self: *const Unit) bool {
        return self.status == .mothballed;
    }

    /// This hull's monthly bill (ARCH §9.8) — owned means billed.
    pub fn monthlyBill(self: *const Unit) types.CBills {
        if (self.status == .destroyed) return carryCost(self.kind, true); // a wreck stores like a mothball
        return carryCost(self.kind, self.inColdStorage());
    }

    /// True when the unit can only be restored at a regional/brigade HQ mek
    /// bay: it's destroyed, or carries structural damage (ARCH §9.7). Such a
    /// unit keeps fighting at reduced condition (or not at all) until it
    /// ships home.
    pub fn needsDepot(self: *const Unit) bool {
        if (self.status == .destroyed) return true;
        for (self.slots.items) |s| {
            if (repairTier(s.class, s.condition) == .depot) return true;
        }
        return false;
    }
};

test "condition degrades with damaged slots" {
    var u: Unit = .{ .id = @enumFromInt(1), .chassis_key = "SHD-2H", .kind = .mek };
    defer u.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 100), u.conditionPct());
    try u.slots.append(std.testing.allocator, .{
        .slot_key = "left_arm.autocannon5.1",
        .part_key = "ac5",
        .class = .weapon,
        .condition = .destroyed,
    });
    u.armor_pct = 60;
    try std.testing.expectEqual(@as(u8, 51), u.conditionPct());
}

test "the hangar ledger: every hull bills, cold storage bills less" {
    var u: Unit = .{ .id = @enumFromInt(3), .chassis_key = "SHD-2H", .kind = .mek };
    defer u.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(types.CBills, 2_000), u.monthlyBill());
    u.status = .damaged; // broken still bills full
    try std.testing.expectEqual(@as(types.CBills, 2_000), u.monthlyBill());
    u.status = .mothballed;
    try std.testing.expectEqual(@as(types.CBills, 400), u.monthlyBill());
}

test "reactivation takes longer for neglected machines" {
    try std.testing.expectEqual(@as(u32, 7), reactivationDays(.f));
    try std.testing.expectEqual(@as(u32, 22), reactivationDays(.a));
}

test "armor and weapons are field work; structure is depot work" {
    try std.testing.expectEqual(@as(?RepairTier, null), repairTier(.weapon, .ok));
    try std.testing.expectEqual(RepairTier.field, repairTier(.armor, .damaged).?);
    try std.testing.expectEqual(RepairTier.field, repairTier(.weapon, .destroyed).?);
    try std.testing.expectEqual(RepairTier.field, repairTier(.ammo, .missing).?);
    try std.testing.expectEqual(RepairTier.depot, repairTier(.structure, .damaged).?);
}

test "structural damage sends a unit home" {
    var u: Unit = .{ .id = @enumFromInt(2), .chassis_key = "SHD-2H", .kind = .mek };
    defer u.deinit(std.testing.allocator);
    try u.slots.append(std.testing.allocator, .{
        .slot_key = "right_torso.structure",
        .part_key = "internal.rt",
        .class = .structure,
        .condition = .ok,
    });
    try std.testing.expect(!u.needsDepot());
    u.slots.items[0].condition = .damaged;
    try std.testing.expect(u.needsDepot());
    u.slots.items[0].condition = .ok;
    u.status = .destroyed;
    try std.testing.expect(u.needsDepot());
}
