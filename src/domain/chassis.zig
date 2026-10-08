//! Static chassis catalog: the designs meks are instances of.
//! Data lives in data/chassis.zon (curated 3025 set), imported at comptime —
//! Adaptation of MekHQ's MegaMek .mtf loading: a curated set is re-encoded
//! instead (licensing note in ARCHITECTURE §12).

const std = @import("std");
const types = @import("types.zig");
const unit = @import("unit.zig");

pub const WeightClass = enum { light, medium, heavy, assault };

/// Pinned MegaMek mm-data revision for P2v-a conventional chassis facts.
/// Source paths are repository-relative to this revision (P2 design §2).
pub const conventional_source_revision = "2a62993f8da306f489116233d489d1f6222945e3";

/// Arm actuator complement (TechManual standard-IS construction rules;
/// the reconciliation identity in meklab.fixedOccupants governs).
/// .full         = shoulder + upper arm + lower arm + hand  (4 fixed crit slots)
/// .no_hand      = shoulder + upper arm + lower arm         (3 fixed crit slots)
/// .no_lower_arm = shoulder + upper arm only                (2 fixed crit slots;
///                 hand is necessarily absent when lower arm is missing)
pub const ArmActuators = enum { full, no_hand, no_lower_arm };

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
    /// First year the design is in service (MekHQ `introYear`);
    /// the market, RATs and salvage only field what exists in the campaign year.
    intro_year: u16 = 2400,
    kind: unit.UnitKind = .mek,
    /// Pinned MegaMek mm-data provenance for conventional chassis. Empty for
    /// non-conventional entries, which are not admitted by the P2 market rule.
    source_revision: []const u8 = "",
    source_path: []const u8 = "",
    /// Explicit P2 market admission, independent of rarity and source era.
    market_eligible: bool = false,
    // Construction facts (MekLab; meks only, defaults for others).
    walk_mp: u8 = 0,
    jump_mp: u8 = 0,
    heat_sinks: u8 = 10,
    armor_half_tons: u16 = 0,
    /// Free critical slots per location after fixed occupants, indexed in
    /// `meklab.Location` order: hd, ct, lt, rt, la, ra, ll, rl. Default is
    /// the standard IS 'Mech (TechManual): head 1, CT 2, side torso 12,
    /// arm 8, leg 2. Do NOT import meklab; the index order is a documented
    /// contract.
    crit_slots: [8]u8 = .{ 1, 2, 12, 12, 8, 8, 2, 2 },
    /// Arm actuator complement for left arm. Default .full (4 fixed slots:
    /// shoulder + upper arm + lower arm + hand). Set to .no_hand (3) or
    /// .no_lower_arm (2) for restricted designs; crit_slots[la] must be
    /// adjusted accordingly (meklab.fixedOccupants identity enforces this).
    left_arm_actuators: ArmActuators = .full,
    /// Arm actuator complement for right arm. See left_arm_actuators.
    right_arm_actuators: ArmActuators = .full,
    // Transport facts (dropships/jumpships only, TRO:3025).
    // A dropship lifts hulls by bay kind; a jumpship carries dropships on
    // its docking collars. Tonnage is nominal for ships (u8).
    mek_bays: u8 = 0,
    asf_bays: u8 = 0,
    vehicle_bays: u8 = 0,
    cargo_tons: u32 = 0,
    collars: u8 = 0,
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
/// (random assignment table) pool, in service by `year`.
pub fn availableIn(c: *const Chassis, year: u16) bool {
    return c.intro_year <= year;
}

pub fn ofWeightClass(class: WeightClass, year: u16, buf: []*const Chassis) []*const Chassis {
    var n: usize = 0;
    for (catalog) |*c| {
        if (c.kind == .mek and c.weightClass() == class and availableIn(c, year) and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Every catalog entry of one unit kind (transports, fighters, ...).
pub fn ofKind(kind: unit.UnitKind, year: u16, buf: []*const Chassis) []*const Chassis {
    var n: usize = 0;
    for (catalog) |*c| {
        if (c.kind == kind and availableIn(c, year) and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// P2 conventional market admission: a sourced, explicitly approved vehicle
/// or aerospace chassis that exists in the requested campaign year.
pub fn conventionalMarketEligible(c: *const Chassis, year: u16) bool {
    return (c.kind == .vehicle or c.kind == .aerospace) and c.market_eligible and availableIn(c, year);
}

/// The only catalogue selector for P2 conventional market offers.
pub fn conventionalMarketPool(kind: unit.UnitKind, year: u16, buf: []*const Chassis) []*const Chassis {
    var n: usize = 0;
    for (catalog) |*c| {
        if (c.kind == kind and conventionalMarketEligible(c, year) and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

fn approvedConventionalMarketKey(key: []const u8) bool {
    const keys = [_][]const u8{ "SCP-1N", "MTR", "SRM-CAR", "TR-7", "SPR-H5", "SL-15" };
    for (keys) |approved| if (std.mem.eql(u8, key, approved)) return true;
    return false;
}

fn expectLoadout(c: *const Chassis, parts: []const []const u8, prefixes: []const []const u8) !void {
    try std.testing.expectEqual(parts.len, c.loadout.len);
    try std.testing.expectEqual(parts.len, prefixes.len);
    for (c.loadout, parts, prefixes) |slot, part_key, prefix| {
        try std.testing.expectEqualStrings(part_key, slot.part);
        try std.testing.expect(std.mem.startsWith(u8, slot.slot, prefix));
    }
}

/// Meks suitable for a scout lance: at or under `max_tonnage`.
pub fn scoutPool(max_tonnage: u8, year: u16, buf: []*const Chassis) []*const Chassis {
    var n: usize = 0;
    for (catalog) |*c| {
        if (c.kind == .mek and c.tonnage <= max_tonnage and availableIn(c, year) and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

test "data: catalog loads from zon with sane values and unique keys" {
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

test "data: conventional chassis have pinned provenance and explicit market admission" {
    const audited = [_]struct { []const u8, []const u8 }{
        .{ "SCP-1N", "data/mekfiles/vehicles/3039u/Scorpion Light Tank.blk" },
        .{ "VDT", "data/mekfiles/vehicles/3039u/Vedette Medium Tank.blk" },
        .{ "HTZ", "data/mekfiles/vehicles/3039u/Hetzer Wheeled Assault Gun.blk" },
        .{ "MTR", "data/mekfiles/vehicles/3039u/Manticore Heavy Tank.blk" },
        .{ "DMO", "data/mekfiles/vehicles/3039u/Demolisher Heavy Tank (Mk. I).blk" },
        .{ "SRK", "data/mekfiles/vehicles/3039u/Schrek PPC Carrier.blk" },
        .{ "LRM-CAR", "data/mekfiles/vehicles/3039u/LRM Carrier.blk" },
        .{ "SRM-CAR", "data/mekfiles/vehicles/3039u/SRM Carrier.blk" },
        .{ "ONT", "data/mekfiles/vehicles/3039u/Ontos Heavy Tank.blk" },
        .{ "PGS", "data/mekfiles/vehicles/3039u/Pegasus Scout Hover Tank.blk" },
        .{ "SCM", "data/mekfiles/vehicles/3039u/Saracen Medium Hover Tank.blk" },
        .{ "GAL", "data/mekfiles/vehicles/3039u/Galleon Light Tank.blk" },
        .{ "SPR-H5", "data/mekfiles/fighters/TRO3039u/Sparrowhawk SPR-H5.blk" },
        .{ "CSR-V12", "data/mekfiles/fighters/TRO3039u/Corsair CSR-V12.blk" },
        .{ "LCF-R15", "data/mekfiles/fighters/TRO3039u/Lucifer LCF-R15.blk" },
        .{ "SL-15", "data/mekfiles/fighters/TRO3039u/Slayer SL-15.blk" },
        .{ "STU-K5", "data/mekfiles/fighters/TRO3039u/Stuka STU-K5.blk" },
        .{ "TR-7", "data/mekfiles/fighters/TRO3039u/Thrush TR-7.blk" },
        .{ "SYD-Z1", "data/mekfiles/fighters/TRO3039u/Seydlitz SYD-Z1.blk" },
        .{ "LTN-G15", "data/mekfiles/fighters/TRO3039u/Lightning LTN-G15.blk" },
        .{ "EGL-R6", "data/mekfiles/fighters/TRO3039u/Eagle EGL-R6.blk" },
        .{ "RVR", "data/mekfiles/fighters/TRO3039u/Riever F-700.blk" },
        .{ "CHP-W5", "data/mekfiles/fighters/TRO3039u/Chippewa CHP-W5.blk" },
    };
    var seen: usize = 0;
    for (catalog) |c| {
        if (c.kind != .vehicle and c.kind != .aerospace) continue;
        seen += 1;
        try std.testing.expectEqualStrings(conventional_source_revision, c.source_revision);
        try std.testing.expect(c.source_path.len > 0);
        const prefix = if (c.kind == .vehicle) "data/mekfiles/vehicles/" else "data/mekfiles/fighters/";
        try std.testing.expect(std.mem.startsWith(u8, c.source_path, prefix));
        try std.testing.expectEqual(approvedConventionalMarketKey(c.key), c.market_eligible);
        if (c.market_eligible) try std.testing.expect(c.intro_year <= 3025);
    }
    try std.testing.expectEqual(audited.len, seen);
    for (audited) |entry| {
        const c = find(entry[0]).?;
        try std.testing.expectEqualStrings(entry[1], c.source_path);
    }
}

test "data: approved conventional replacements and market pools agree" {
    const scorpion = find("SCP-1N").?;
    try std.testing.expectEqual(@as(u16, 2807), scorpion.intro_year);
    try expectLoadout(scorpion, &.{ "ac5", "mg", "ammo_ac5", "ammo_mg" }, &.{ "turret.", "turret.", "body.", "body." });
    const manticore = find("MTR").?;
    try std.testing.expectEqual(@as(u16, 2575), manticore.intro_year);
    try expectLoadout(manticore, &.{ "ppc", "lrm10", "srm6", "mlas", "ammo_lrm", "ammo_srm" }, &.{ "turret.", "turret.", "turret.", "front.", "body.", "body." });
    const carrier = find("SRM-CAR").?;
    try std.testing.expectEqual(@as(u16, 2470), carrier.intro_year);
    try std.testing.expectEqual(@as(usize, 14), carrier.loadout.len);
    for (carrier.loadout[0..10]) |slot| {
        try std.testing.expectEqualStrings("srm6", slot.part);
        try std.testing.expect(std.mem.startsWith(u8, slot.slot, "front."));
    }
    const thrush = find("TR-7").?;
    try std.testing.expectEqual(@as(u16, 2798), thrush.intro_year);
    try expectLoadout(thrush, &.{ "mlas", "mlas", "mlas" }, &.{ "nose.", "lw.", "rw." });
    const sparrowhawk = find("SPR-H5").?;
    try std.testing.expectEqual(@as(u16, 2520), sparrowhawk.intro_year);
    try expectLoadout(sparrowhawk, &.{ "mlas", "mlas", "slas", "slas" }, &.{ "nose.", "nose.", "lw.", "rw." });
    const slayer = find("SL-15").?;
    try std.testing.expectEqual(@as(u16, 2770), slayer.intro_year);
    try expectLoadout(slayer, &.{ "ac10", "mlas", "mlas", "mlas", "mlas", "mlas", "mlas", "ammo_ac10", "ammo_ac10" }, &.{ "nose.", "nose.", "lw.", "lw.", "rw.", "rw.", "aft.", "fuselage.", "fuselage." });

    var buf: [16]*const Chassis = undefined;
    const vehicles = conventionalMarketPool(.vehicle, 3025, &buf);
    try std.testing.expectEqual(@as(usize, 3), vehicles.len);
    for (vehicles) |c| try std.testing.expect(conventionalMarketEligible(c, 3025));
    const fighters = conventionalMarketPool(.aerospace, 3025, &buf);
    try std.testing.expectEqual(@as(usize, 3), fighters.len);
    for (fighters) |c| try std.testing.expect(conventionalMarketEligible(c, 3025));
    try std.testing.expect(!conventionalMarketEligible(find("VDT").?, 3025));
    try std.testing.expect(!conventionalMarketEligible(find("CSR-V12").?, 3025));
}

test "arm actuator fields: identity crit_slots[arm] + fixed_count == 12" {
    // Chassis with .no_lower_arm (2 fixed: shoulder + upper arm) → arm free crits = 10.
    // Source: MegaMek MTF slot layout (shoulder + upper arm, then weapons — no lower arm entry).
    const no_lower_arm_keys = [_][]const u8{
        "CPLT-C1", "RFL-3N", "UM-R60",
    };
    for (no_lower_arm_keys) |key| {
        const c = find(key).?;
        try std.testing.expectEqual(ArmActuators.no_lower_arm, c.left_arm_actuators);
        try std.testing.expectEqual(ArmActuators.no_lower_arm, c.right_arm_actuators);
        try std.testing.expectEqual(@as(u8, 10), c.crit_slots[4]); // la index 4
        try std.testing.expectEqual(@as(u8, 10), c.crit_slots[5]); // ra index 5
    }
    // Chassis with .no_hand (3 fixed: shoulder + upper arm + lower arm, no hand) → arm free crits = 9.
    // Source: MegaMek MTF slot layout (shoulder + upper arm + lower arm, then weapons — no hand entry).
    const no_hand_keys = [_][]const u8{ "MAD-3R", "MAD-3D", "WHM-6R", "WHM-6D" };
    for (no_hand_keys) |key| {
        const c = find(key).?;
        try std.testing.expectEqual(ArmActuators.no_hand, c.left_arm_actuators);
        try std.testing.expectEqual(ArmActuators.no_hand, c.right_arm_actuators);
        try std.testing.expectEqual(@as(u8, 9), c.crit_slots[4]); // la index 4
        try std.testing.expectEqual(@as(u8, 9), c.crit_slots[5]); // ra index 5
    }
    // All remaining mek chassis default to .full (4 fixed) → arm free crits = 8.
    for (catalog) |c| {
        if (c.kind != .mek) continue;
        var is_restricted = false;
        for (no_lower_arm_keys) |key| {
            if (std.mem.eql(u8, c.key, key)) {
                is_restricted = true;
                break;
            }
        }
        for (no_hand_keys) |key| {
            if (std.mem.eql(u8, c.key, key)) {
                is_restricted = true;
                break;
            }
        }
        if (!is_restricted) {
            try std.testing.expectEqual(ArmActuators.full, c.left_arm_actuators);
            try std.testing.expectEqual(ArmActuators.full, c.right_arm_actuators);
            try std.testing.expectEqual(@as(u8, 8), c.crit_slots[4]); // la index 4
            try std.testing.expectEqual(@as(u8, 8), c.crit_slots[5]); // ra index 5
        }
    }
}

test "the catalogue is broad — TRO:3025 meks, 3026 vehicles, fighters" {
    var meks: u32 = 0;
    var vehicles: u32 = 0;
    var fighters: u32 = 0;
    for (catalog) |c| switch (c.kind) {
        .mek => meks += 1,
        .vehicle => vehicles += 1,
        .aerospace => fighters += 1,
        else => {},
    };
    try std.testing.expect(meks >= 60);
    try std.testing.expect(vehicles >= 12);
    try std.testing.expect(fighters >= 10);
    // Every loadout part resolves in the parts catalogue.
    const part = @import("part.zig");
    for (catalog) |c| for (c.loadout) |l| {
        if (part.find(l.part) == null) {
            std.debug.print("{s}: unknown part {s}\n", .{ c.key, l.part });
            return error.TestUnexpectedResult;
        }
    };
}

test "transports and fighters are in the catalog with lift facts" {
    var buf: [16]*const Chassis = undefined;
    const ships = ofKind(.dropship, 3025, &buf);
    try std.testing.expect(ships.len >= 3);
    for (ships) |s| try std.testing.expect(s.mek_bays > 0);
    const jumpers = ofKind(.jumpship, 3025, &buf);
    try std.testing.expect(jumpers.len >= 3);
    for (jumpers) |j| try std.testing.expect(j.collars > 0);
    try std.testing.expect(ofKind(.aerospace, 3025, &buf).len >= 5);
    try std.testing.expectEqual(@as(u8, 4), find("LEOPARD").?.mek_bays);
}

test "scout pool excludes heavies and support vehicles" {
    var buf: [32]*const Chassis = undefined;
    const scouts = scoutPool(40, 3025, &buf);
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
    const lights = ofWeightClass(.light, 3025, &buf);
    try std.testing.expect(lights.len >= 3);
}

test "designs appear with their year" {
    var buf: [64]*const Chassis = undefined;
    const now = ofWeightClass(.medium, 3025, &buf).len;
    const early = ofWeightClass(.medium, 3000, &buf).len;
    try std.testing.expect(early < now); // the house refits of the 3020s are not there yet
    try std.testing.expect(find("SHD-2D").?.intro_year > 3000);
    try std.testing.expect(availableIn(find("SHD-2H").?, 2900));
}
