//! Units: meks, vehicles, aerospace, support assets, transports.
//! MekHQ counterpart: `unit/Unit.java`. Per-unit state only — the static design
//! (tonnage, loadout, BV) comes from the chassis catalog in data/ (Stage 3).

const std = @import("std");
const tuning = @import("tuning.zig").t;
const types = @import("types.zig");

pub const UnitKind = enum {
    mek,
    vehicle,
    aerospace,
    battle_armor,
    infantry,
    // Support echelon — these fight nobody but win battles (ARCH §3.4):
    mash,
    cargo,
    dropship,
    jumpship,

    pub fn isTransport(self: UnitKind) bool {
        return self == .dropship or self == .jumpship;
    }

    /// Which dropship bay kind carries this hull (null: rides as cargo/crew).
    pub fn bayKind(self: UnitKind) ?BayKind {
        return switch (self) {
            .mek => .mek,
            .aerospace => .asf,
            .vehicle, .mash, .cargo => .vehicle,
            else => null,
        };
    }

    pub fn isCombat(self: UnitKind) bool {
        return switch (self) {
            .mek, .vehicle, .aerospace, .battle_armor, .infantry => true,
            else => false,
        };
    }
};

pub const BayKind = enum { mek, asf, vehicle };

/// How a hull died (TechManual "Destroying a 'Mech"): the cause
/// decides what the rebuild needs. A cored centre torso is a component
/// and bay time; a destroyed engine (three engine criticals) adds a new
/// engine at the TechManual price; an ammunition explosion guts both side
/// torsos as well; scrap is beyond rebuilding — strip it for parts.
/// MekHQ counterpart: the salvage/"unrepairable" states of `Unit`.
pub const WreckCause = enum {
    none,
    cored,
    engine,
    ammo,
    scrap,

    pub fn label(self: WreckCause) []const u8 {
        return switch (self) {
            .none => "",
            .cored => "centre torso cored",
            .engine => "engine destroyed",
            .ammo => "ammunition explosion",
            .scrap => "scrap — beyond rebuilding",
        };
    }

    /// A new engine goes in with the rebuild.
    pub fn needsEngine(self: WreckCause) bool {
        return self == .engine or self == .ammo;
    }
};

/// TechManual standard fusion engine cost: 5,000 × rating × tonnage ÷ 75,
/// with the rating from the design's walking MP × tonnage.
pub fn engineCost(tonnage: u32, walk_mp: u32) types.CBills {
    const rating: types.CBills = @as(types.CBills, walk_mp) * tonnage;
    return @divTrunc(5_000 * rating * @as(types.CBills, tonnage), 75);
}

pub const UnitStatus = enum { ready, damaged, repairing, refitting, mothballed, destroyed, in_transit };

const Role = @import("person.zig").Role;

/// Who sits in the crew slot for this kind of hull.
pub fn crewRoleFor(kind: UnitKind) Role {
    return switch (kind) {
        .mek => .mekwarrior,
        .vehicle, .mash, .cargo => .vehicle_crew,
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
        .vehicle, .mash, .cargo => .tech_mechanic,
        .aerospace, .dropship, .jumpship => .tech_aero,
        .battle_armor => .tech_ba,
        .infantry => null,
    };
}

/// Weekly maintenance hours a hull costs its tech, by kind and tonnage
/// (the tech-time budget; tuning.unit.maintenance_hours).
pub fn maintenanceHours(kind: UnitKind, tonnage: u8) u32 {
    const t = @import("tuning.zig").t.unit;
    const h = t.maintenance_hours;
    return switch (kind) {
        .mek => if (tonnage <= t.mek_light_max_tons) h.mek_light else if (tonnage <= t.mek_medium_max_tons) h.mek_medium else if (tonnage <= t.mek_heavy_max_tons) h.mek_heavy else h.mek_assault,
        .vehicle, .mash, .cargo => h.vehicle,
        .aerospace => h.aerospace,
        .battle_armor => h.battle_armor,
        .infantry => 0, // no hull to maintain
        .dropship => h.dropship,
        .jumpship => h.jumpship,
    };
}

// ---------------------------------------- the hangar ledger (ARCH §9.8)
// Every hull owned bills monthly, running or not: hangar space, transport
// allocation, insurance, tech attention. Cold storage (mothballing at a
// regional HQ) cuts the bill to a fraction but costs reactivation time.

/// Monthly per-hull carry cost by unit kind, C-bills.
pub fn monthlyCarryCost(kind: UnitKind) types.CBills {
    const c = tuning.unit.carry;
    return switch (kind) {
        .mek => c.mek,
        .vehicle => c.vehicle,
        .aerospace => c.aerospace,
        .battle_armor => c.battle_armor,
        .infantry => c.infantry,
        .mash => c.mash,
        .cargo => c.cargo,
        .dropship => c.dropship,
        .jumpship => c.jumpship,
    };
}

/// Cold-storage carry cost: 20% of active.
pub const cold_storage_cost_bp: types.Bp = tuning.unit.cold_storage_bp;

pub fn carryCost(kind: UnitKind, in_cold_storage: bool) types.CBills {
    const base = monthlyCarryCost(kind);
    return if (in_cold_storage) types.applyBp(base, cold_storage_cost_bp) else base;
}

/// Tech-days to wake a mothballed hull before it can transfer or fight;
/// a neglected machine (low quality) takes longer.
pub fn reactivationDays(quality: types.Quality) u32 {
    return tuning.unit.reactivation_base_days + (5 - @as(u32, @intFromEnum(quality))) * tuning.unit.reactivation_days_per_quality_step; // F: 7 days .. A: 22
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
/// repair work + parts demand derive from it.
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
    /// Crew slot (pilot/driver/leader) and the assigned technician
    /// (MekHQ-style): no tech → no maintenance, repairs or reloads;
    /// no pilot → the hull doesn't fight. Every kind, multi-crew ones
    /// included, holds one crew slot.
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
    /// Transports only: the HQ whose berth this ship holds.
    berth_hq: types.HqId = .none,
    /// Why a destroyed hull died; `.none` while it runs.
    wreck: WreckCause = .none,

    pub fn deinit(self: *Unit, alloc: std.mem.Allocator) void {
        self.slots.deinit(alloc);
    }

    /// Combat effectiveness of this hull before crew/campaign modifiers,
    /// as a percentage (0–100); autoresolve scales the chassis BV by it
    /// (ARCH §7).
    pub fn conditionPct(self: *const Unit) u8 {
        if (self.isParked()) return 0;
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

    /// Out of play until the player acts: a wreck or a mothballed hull.
    /// Nothing counts it, crews it, maintains it or fights with it.
    pub fn isParked(self: *const Unit) bool {
        return self.status == .destroyed or self.status == .mothballed;
    }

    /// On the bench: depot repair or refit in progress.
    pub fn inShop(self: *const Unit) bool {
        return self.status == .repairing or self.status == .refitting;
    }

    /// Cannot be moved or worked on right now: on the bench or on the road.
    pub fn isBusy(self: *const Unit) bool {
        return self.inShop() or self.status == .in_transit;
    }

    /// Stands in the line today (ARCH §7): not parked, not on the bench,
    /// not in transit. The one definition the battle, the effectiveness
    /// check and the hangar all use.
    pub fn canFight(self: *const Unit) bool {
        return !self.isParked() and !self.isBusy();
    }

    /// Gets weekly maintenance and field repairs: not parked, not on the
    /// bench (a hull in transit still rides with its tech).
    pub fn takesFieldWork(self: *const Unit) bool {
        return !self.isParked() and !self.inShop();
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
    /// A killed hull is a wreck: the centre torso (else the first structure
    /// slot) is destroyed, so the rebuild is real depot work — a component
    /// and bay time — never a wreck with only field damage, which would sit
    /// between the field and the depot.
    pub fn markWrecked(self: *Unit) void {
        self.markWreckedBy(.cored);
    }

    /// Wreck the hull by a cause: the centre torso always goes; an
    /// ammunition explosion takes both side torsos with it; scrap leaves no
    /// structure standing.
    pub fn markWreckedBy(self: *Unit, cause: WreckCause) void {
        self.wreck = if (cause == .none) .cored else cause;
        switch (self.wreck) {
            .ammo => for (self.slots.items) |*s| {
                if (s.class == .structure and (std.mem.startsWith(u8, s.slot_key, "lt.") or std.mem.startsWith(u8, s.slot_key, "rt."))) s.condition = .destroyed;
            },
            .scrap => for (self.slots.items) |*s| {
                if (s.class == .structure) s.condition = .destroyed;
            },
            else => {},
        }
        self.coreCentreTorso();
    }

    fn coreCentreTorso(self: *Unit) void {
        self.status = .destroyed;
        var first: ?*PartSlot = null;
        for (self.slots.items) |*s| {
            if (s.class != .structure) continue;
            if (first == null) first = s;
            if (std.mem.startsWith(u8, s.slot_key, "ct.")) {
                s.condition = .destroyed;
                return;
            }
        }
        if (first) |s| s.condition = .destroyed;
    }

    pub fn needsDepot(self: *const Unit) bool {
        if (self.status == .destroyed) return true; // a wreck is rebuilt in the depot
        if (self.status == .destroyed) return true;
        for (self.slots.items) |s| {
            if (repairTier(s.class, s.condition) == .depot) return true;
        }
        return false;
    }
};

/// A hull the enemy dragged off a field we lost: off the books
/// entirely — it bills nothing, fills no seat and appears in no lance,
/// because it is not in `GameState.units` at all — but it is not struck
/// off either. A recovery raid can win it back.
pub const HeldHull = struct {
    /// The hull as it stood when they took it, wounds and all.
    unit: Unit,
    /// Faction key of the house holding it.
    by: []const u8,
    /// The day the field was lost.
    day: u32,
    /// The engagement that lost it, so the after-action can be re-read.
    battle: types.BattleId,
    /// The lance it was in when they took it, so a hull won back goes
    /// home rather than into the hangar.
    from_force: types.ForceId = .none,

    /// The three facts that mark a hull as held, with "not held" as the
    /// default. The store writes one hull row for owned and held alike
    /// and tells them apart by a non-empty `by`.
    pub const Mark = struct {
        by: []const u8 = "",
        day: u32 = 0,
        battle: types.BattleId = .none,
        from_force: types.ForceId = .none,
    };

    pub fn mark(self: HeldHull) Mark {
        return .{ .by = self.by, .day = self.day, .battle = self.battle, .from_force = self.from_force };
    }
};


test "one line of hull status predicates: parked, in the shop, busy, fighting" {
    var u: Unit = .{ .id = @enumFromInt(1), .chassis_key = "SHD-2H", .kind = .mek };
    defer u.deinit(std.testing.allocator);
    try std.testing.expect(u.canFight() and u.takesFieldWork() and !u.isParked() and !u.isBusy());
    u.status = .refitting;
    try std.testing.expect(u.inShop() and u.isBusy() and !u.canFight() and !u.takesFieldWork());
    u.status = .in_transit;
    try std.testing.expect(u.isBusy() and !u.canFight() and u.takesFieldWork()); // rides with its tech
    u.status = .mothballed;
    try std.testing.expect(u.isParked() and !u.canFight() and !u.takesFieldWork());
    try std.testing.expectEqual(@as(u8, 0), u.conditionPct());
}

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
