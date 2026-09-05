//! HQ network: brigade / regional / field headquarters with facilities,
//! influence rings, capacity slots, staffing overhead, and upgrade projects.
//! No MekHQ equivalent — this is the game's centerpiece (ARCH §9, GAMEPLAY.md).
//!
//! Tuning values live in data/tables/tuning.zon (`tuning.hq`).

const std = @import("std");
const tuning = @import("tuning.zig").t;
const types = @import("types.zig");
const SupportLanceKind = @import("force.zig").SupportLanceKind;

pub const HqTier = enum {
    brigade, // home base: best facilities, deepest stock, one only
    regional, // per region of space: projects the influence ring
    field, // beachhead toehold: minimal, upgradeable to regional

    /// Base influence radius in light-years (ARCH §9.2).
    pub fn baseInfluenceLy(self: HqTier) u32 {
        return switch (self) {
            .field => tuning.hq.influence_ly.field,
            .regional => tuning.hq.influence_ly.regional,
            .brigade => tuning.hq.influence_ly.brigade,
        };
    }

    /// Monthly upkeep of an HQ of this tier.
    pub fn monthlyUpkeep(self: HqTier) types.CBills {
        return switch (self) {
            .field => tuning.hq.upkeep.field,
            .regional => tuning.hq.upkeep.regional,
            .brigade => tuning.hq.upkeep.brigade,
        };
    }
};

pub const FacilityKind = enum {
    mek_bay, // repair/refit capacity; gates refit class & combat-lance cap
    warehouse, // logistics/parts depot: stocking depth, hub pass-through quality
    hospital, // medical throughput & survival odds
    mess, // provisions buffer, morale & fatigue recovery
    training_ground, // XP rate for garrisoned/training lances
    hiring_hall, // recruit quality & pipeline size
    comms, // influence reach, contract market, event forewarning
    spaceport, // berths, shipment throughput, freight cost, air company
};

pub const max_facility_level = 5;

pub const Facility = struct {
    kind: FacilityKind,
    level: u8 = 1, // 0 = absent, max 5
};

/// What an HQ can host (ARCH §9.3). Derived from tier + facilities; growth
/// is infrastructure-first: want a second company, build a second HQ.
pub const Capacity = struct {
    combat_companies: u8,
    lances_per_company: u8, // 3 base, up to 5 with mek bay investment
    support_companies: u8,
    /// Support lances the support company may hold (GAMEPLAY: hospital,
    /// mess and warehouse levels unlock lance slots).
    support_lances: u8,
    air_companies: u8,
    dropship_berths: u8,
    jumpship_berths: u8,
};

/// Staffing an HQ requires — grows permanently with every facility level
/// (ARCH §9.4): C-bills are the cheap part, the payroll tail is the price.
pub const StaffRequirement = struct {
    admin: u32,
    logistics: u32,
    hr: u32,
    finance: u32,

    pub fn total(self: StaffRequirement) u32 {
        return self.admin + self.logistics + self.hr + self.finance;
    }
};

pub const ProjectKind = enum { found, tier_upgrade, facility_upgrade };

pub const ProjectPhase = enum { paperwork, construction, complete };

/// Founding or upgrading is a project: a paperwork phase (permits,
/// procurement — shortened by admin capacity), then construction.
pub const Project = struct {
    kind: ProjectKind,
    facility: ?FacilityKind = null, // set iff facility_upgrade
    target_level: u8 = 0,
    started_day: u32,
    paperwork_done_day: u32,
    construction_done_day: u32,
    cost: types.CBills,

    pub fn phase(self: Project, day: u32) ProjectPhase {
        if (day >= self.construction_done_day) return .complete;
        if (day >= self.paperwork_done_day) return .construction;
        return .paperwork;
    }
};

/// Paperwork lead time in days for a new project.
pub fn paperworkDays(admin_effective_level: u32) u32 {
    return @max(tuning.hq.paperwork_min_days, tuning.hq.paperwork_base_days -| admin_effective_level * tuning.hq.paperwork_days_per_admin_level);
}

/// C-bill cost to raise `kind` to `to_level` (quadratic in level).
pub fn upgradeCost(kind: FacilityKind, to_level: u8) types.CBills {
    const per_level: types.CBills = switch (kind) {
        .mek_bay => tuning.hq.upgrade_cost_per_level.mek_bay,
        .warehouse => tuning.hq.upgrade_cost_per_level.warehouse,
        .hospital => tuning.hq.upgrade_cost_per_level.hospital,
        .mess => tuning.hq.upgrade_cost_per_level.mess,
        .training_ground => tuning.hq.upgrade_cost_per_level.training_ground,
        .hiring_hall => tuning.hq.upgrade_cost_per_level.hiring_hall,
        .comms => tuning.hq.upgrade_cost_per_level.comms,
        .spaceport => tuning.hq.upgrade_cost_per_level.spaceport,
    };
    const lvl: types.CBills = to_level;
    return per_level * lvl * lvl;
}

pub const Hq = struct {
    id: types.HqId,
    name: []const u8,
    tier: HqTier,
    planet_key: []const u8,
    facilities: std.ArrayListUnmanaged(Facility) = .empty,
    projects: std.ArrayListUnmanaged(Project) = .empty,
    staff_assigned: u32 = 0,
    monthly_upkeep: types.CBills = 0,
    /// The HQ's own treasury (Stage 9A): construction, market buys, and
    /// upkeep draw from here; refilled by courier from the outfit.
    funds: types.CBills = 0,
    /// Warehouse stock by catalog key (Stage 9B), bounded by
    /// `warehouseCapacityTons` of the effective warehouse level.
    stock: std.StringArrayHashMapUnmanaged(u32) = .empty,

    /// Storage tonnage the warehouse holds — the reason to expand it.
    pub fn warehouseCapacityTons(self: *const Hq) u32 {
        const lvl: u32 = self.effectiveFacilityLevel(.warehouse);
        return tuning.hq.warehouse_tons_per_level_sq * lvl * lvl;
    }

    pub fn deinit(self: *Hq, alloc: std.mem.Allocator) void {
        self.facilities.deinit(alloc);
        self.projects.deinit(alloc);
    }

    /// Built level of a facility (0 = absent).
    pub fn facilityLevel(self: *const Hq, kind: FacilityKind) u8 {
        for (self.facilities.items) |f| {
            if (f.kind == kind) return f.level;
        }
        return 0;
    }

    /// Staff the facilities demand (ARCH §9.4). // TUNE
    pub fn staffRequired(self: *const Hq) StaffRequirement {
        var req: StaffRequirement = switch (self.tier) {
            .field => .{ .admin = 1, .logistics = 1, .hr = 0, .finance = 1 },
            .regional => .{ .admin = 4, .logistics = 2, .hr = 2, .finance = 2 },
            .brigade => .{ .admin = 10, .logistics = 4, .hr = 4, .finance = 4 },
        };
        for (self.facilities.items) |f| {
            const lvl: u32 = f.level;
            switch (f.kind) {
                .mek_bay, .warehouse, .spaceport => req.logistics += 2 * lvl,
                .hiring_hall, .training_ground => req.hr += 2 * lvl,
                .hospital, .mess => req.hr += lvl,
                .comms => req.admin += lvl,
            }
        }
        // Paperwork grows with the whole organization.
        req.finance += (req.admin + req.logistics + req.hr) / 4;
        return req;
    }

    /// Understaffed HQs run below their built level: −1 effective level per
    /// full 25% staffing shortfall (ARCH §9.4). Plateaus at 0 — degraded,
    /// never a death spiral.
    pub fn effectiveFacilityLevel(self: *const Hq, kind: FacilityKind) u8 {
        const built = self.facilityLevel(kind);
        if (built == 0) return 0;
        const required = self.staffRequired().total();
        if (required == 0 or self.staff_assigned >= required) return built;
        const shortfall_steps: u8 = @intCast(((required - self.staff_assigned) * 4) / required);
        return built -| shortfall_steps;
    }

    /// Influence ring radius in LY (ARCH §9.2): reputation travels by HPG
    /// and word of mouth, and yours only reaches so far.
    pub fn influenceLy(self: *const Hq) u32 {
        return self.tier.baseInfluenceLy() +
            tuning.hq.influence_per_comms_ly * @as(u32, self.effectiveFacilityLevel(.comms)) +
            tuning.hq.influence_per_spaceport_ly * @as(u32, self.effectiveFacilityLevel(.spaceport));
    }

    /// Capacity slots (ARCH §9.3). // TUNE
    pub fn capacity(self: *const Hq) Capacity {
        const bay = self.effectiveFacilityLevel(.mek_bay);
        const port = self.effectiveFacilityLevel(.spaceport);
        const comms = self.effectiveFacilityLevel(.comms);

        // A company's 3 line lances + recon at bay level 1; the fifth lance
        // needs a level-3 bay. // TUNE
        const lance_cap: u8 = if (bay == 0) 3 else if (bay >= 3) 5 else 4;
        // The four staple support lances (salvage, MASH, logistics,
        // security) come with the slot; a mess needs a real mess hall, and
        // a deep hospital or warehouse opens one more. // TUNE
        const mess = self.effectiveFacilityLevel(.mess);
        const hospital = self.effectiveFacilityLevel(.hospital);
        const warehouse = self.effectiveFacilityLevel(.warehouse);
        const support_cap: u8 = 4 + @as(u8, @intFromBool(mess >= 2)) + @as(u8, @intFromBool(hospital >= 3 or warehouse >= 3));

        return switch (self.tier) {
            .field => .{
                // A forward base: one company can rest, resupply and stage
                // here (play feedback). What it lacks is whatever needs a
                // facility it has not built — no training without a
                // training ground, no structural repair without a mek bay,
                // no hiring without a hall.
                // It hosts a company as it stands (three line lances and a
                // recon lance); it builds nothing — the fifth lance needs a
                // regional bay.
                .combat_companies = 1,
                .lances_per_company = 4,
                .support_companies = 1,
                .support_lances = 4,
                .air_companies = 0,
                .dropship_berths = 0,
                .jumpship_berths = 0,
            },
            .regional => .{
                .combat_companies = 1,
                .lances_per_company = lance_cap,
                .support_companies = 1,
                .support_lances = support_cap,
                .air_companies = if (port >= 3) 1 else 0,
                .dropship_berths = 1 + port / 2,
                .jumpship_berths = if (port >= 4 and comms >= 3) 1 else 0,
            },
            .brigade => .{
                .combat_companies = 2,
                .lances_per_company = lance_cap,
                .support_companies = 2,
                .support_lances = support_cap + 2,
                .air_companies = 1 + @as(u8, @intFromBool(port >= 4)),
                .dropship_berths = 2 + port,
                .jumpship_berths = 1 + @as(u8, @intFromBool(port >= 4 and comms >= 4)),
            },
        };
    }

    /// Whether this HQ's facilities can stand up a support lance of `kind`
    /// (Stage 12.15): a mess lance needs a mess hall (≥ 2), MASH a hospital,
    /// a logistics lance a warehouse; salvage and security always. // TUNE
    pub fn supportLanceAllowed(self: *const Hq, kind: SupportLanceKind) bool {
        if (self.tier == .field) return false;
        return switch (kind) {
            .mess => self.effectiveFacilityLevel(.mess) >= 2,
            .mash => self.effectiveFacilityLevel(.hospital) >= 1,
            .transport => self.effectiveFacilityLevel(.warehouse) >= 1,
            .salvage, .security => true,
        };
    }

    /// Structural repairs and destroyed-unit rebuilds (unit.RepairTier.depot)
    /// happen only here: a regional/brigade HQ with a working mek bay
    /// (ARCH §9.7). Field HQs and field techs handle armor/weapons/ammo only.
    pub fn supportsStructuralRepair(self: *const Hq) bool {
        return self.tier != .field and self.effectiveFacilityLevel(.mek_bay) > 0;
    }

    /// Skill training (converting earned XP into levels) happens only at a
    /// regional/brigade HQ with a training ground (ARCH §9.7). XP itself is
    /// earned anywhere.
    pub fn supportsTraining(self: *const Hq) bool {
        return self.tier != .field and self.effectiveFacilityLevel(.training_ground) > 0;
    }

    /// Highest refit class this HQ's mek bay can perform (CamOps classes
    /// A=trivial .. F=factory), gated by tier and *effective* bay level.
    pub fn refitClassCeiling(self: *const Hq) ?types.Quality {
        const bay = self.effectiveFacilityLevel(.mek_bay);
        if (bay == 0) return null;
        const tier_cap: u8 = switch (self.tier) {
            .field => 1, // class B
            .regional => 3, // class D
            .brigade => 5, // class F
        };
        // Bay level 1 handles class B (like-for-like swaps); each level
        // above unlocks the next class, up to the tier's cap. // TUNE
        return @enumFromInt(@min(bay, tier_cap));
    }
};

test "influence ring grows with comms and spaceport" {
    var hq: Hq = .{ .id = @enumFromInt(1), .name = "HQ Zenith", .tier = .regional, .planet_key = "zurich" };
    defer hq.deinit(std.testing.allocator);
    hq.staff_assigned = 999; // fully staffed

    try std.testing.expectEqual(@as(u32, 60), hq.influenceLy());
    try hq.facilities.append(std.testing.allocator, .{ .kind = .comms, .level = 3 });
    try hq.facilities.append(std.testing.allocator, .{ .kind = .spaceport, .level = 2 });
    try std.testing.expectEqual(@as(u32, 100), hq.influenceLy()); // 60 + 30 + 10
}

test "capacity: field < regional < brigade; facilities open slots" {
    var hq: Hq = .{ .id = @enumFromInt(1), .name = "HQ Anchorage", .tier = .regional, .planet_key = "acamar" };
    defer hq.deinit(std.testing.allocator);
    hq.staff_assigned = 999;

    var cap = hq.capacity();
    try std.testing.expectEqual(@as(u8, 1), cap.combat_companies);
    try std.testing.expectEqual(@as(u8, 3), cap.lances_per_company); // no bay yet
    try std.testing.expectEqual(@as(u8, 0), cap.air_companies);
    try std.testing.expectEqual(@as(u8, 0), cap.jumpship_berths);

    try hq.facilities.append(std.testing.allocator, .{ .kind = .mek_bay, .level = 5 });
    try hq.facilities.append(std.testing.allocator, .{ .kind = .spaceport, .level = 4 });
    try hq.facilities.append(std.testing.allocator, .{ .kind = .comms, .level = 3 });
    cap = hq.capacity();
    try std.testing.expectEqual(@as(u8, 5), cap.lances_per_company); // the 5-lance company
    try std.testing.expectEqual(@as(u8, 1), cap.air_companies);
    try std.testing.expectEqual(@as(u8, 4), cap.support_lances); // no mess, hospital or warehouse yet
    try std.testing.expect(!hq.supportLanceAllowed(.mess));
    try std.testing.expect(hq.supportLanceAllowed(.salvage));
    try hq.facilities.append(std.testing.allocator, .{ .kind = .mess, .level = 2 });
    try hq.facilities.append(std.testing.allocator, .{ .kind = .warehouse, .level = 3 });
    try std.testing.expectEqual(@as(u8, 6), hq.capacity().support_lances);
    try std.testing.expect(hq.supportLanceAllowed(.mess));
    try std.testing.expect(hq.supportLanceAllowed(.transport));
    try std.testing.expectEqual(@as(u8, 3), cap.dropship_berths);
    try std.testing.expectEqual(@as(u8, 1), cap.jumpship_berths);

    hq.tier = .field;
    try std.testing.expectEqual(@as(u8, 1), hq.capacity().combat_companies); // a forward base hosts one
    try std.testing.expectEqual(@as(u8, 4), hq.capacity().lances_per_company); // as it stands, never a fifth
    try std.testing.expectEqual(@as(u8, 0), hq.capacity().air_companies);
    hq.tier = .brigade;
    try std.testing.expect(hq.capacity().combat_companies > 1);
}

test "every upgrade raises the permanent staffing bill" {
    var hq: Hq = .{ .id = @enumFromInt(1), .name = "HQ Zenith", .tier = .regional, .planet_key = "zurich" };
    defer hq.deinit(std.testing.allocator);

    const before = hq.staffRequired().total();
    try hq.facilities.append(std.testing.allocator, .{ .kind = .warehouse, .level = 3 });
    const after = hq.staffRequired().total();
    try std.testing.expect(after > before);
}

test "understaffing degrades effective levels but plateaus at zero" {
    var hq: Hq = .{ .id = @enumFromInt(1), .name = "HQ Anchorage", .tier = .regional, .planet_key = "acamar" };
    defer hq.deinit(std.testing.allocator);
    try hq.facilities.append(std.testing.allocator, .{ .kind = .warehouse, .level = 4 });

    hq.staff_assigned = hq.staffRequired().total();
    try std.testing.expectEqual(@as(u8, 4), hq.effectiveFacilityLevel(.warehouse));

    hq.staff_assigned = hq.staffRequired().total() / 2; // 50% short → −2
    try std.testing.expectEqual(@as(u8, 2), hq.effectiveFacilityLevel(.warehouse));

    hq.staff_assigned = 0; // 100% short → floor at 0, never negative
    try std.testing.expectEqual(@as(u8, 0), hq.effectiveFacilityLevel(.warehouse));
}

test "projects move through paperwork then construction" {
    const p: Project = .{
        .kind = .facility_upgrade,
        .facility = .warehouse,
        .target_level = 2,
        .started_day = 100,
        .paperwork_done_day = 121,
        .construction_done_day = 156,
        .cost = upgradeCost(.warehouse, 2),
    };
    try std.testing.expectEqual(ProjectPhase.paperwork, p.phase(110));
    try std.testing.expectEqual(ProjectPhase.construction, p.phase(140));
    try std.testing.expectEqual(ProjectPhase.complete, p.phase(156));
    try std.testing.expectEqual(@as(types.CBills, 1_600_000), p.cost);
}

test "structural repair and training are regional-HQ privileges" {
    var hq: Hq = .{ .id = @enumFromInt(1), .name = "Firebase", .tier = .field, .planet_key = "talitha" };
    defer hq.deinit(std.testing.allocator);
    hq.staff_assigned = 999;
    try hq.facilities.append(std.testing.allocator, .{ .kind = .mek_bay, .level = 2 });
    try hq.facilities.append(std.testing.allocator, .{ .kind = .training_ground, .level = 2 });

    // A field HQ has the buildings but not the echelon.
    try std.testing.expect(!hq.supportsStructuralRepair());
    try std.testing.expect(!hq.supportsTraining());

    hq.tier = .regional;
    try std.testing.expect(hq.supportsStructuralRepair());
    try std.testing.expect(hq.supportsTraining());
}

test "admin capacity shortens paperwork" {
    try std.testing.expect(paperworkDays(0) > paperworkDays(3));
    try std.testing.expect(paperworkDays(10) >= 5); // never free
}
