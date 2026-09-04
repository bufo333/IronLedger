//! Markets: contract offers, hiring pool, unit purchases.
//! Mirrors MekHQ `market/ContractMarket`, `PersonnelMarket`, `UnitMarket`.
//! Stage 4 implements generation; refresh cadence and offer shapes live here.

const std = @import("std");
const types = @import("../domain/types.zig");
const contract = @import("../domain/contract.zig");
const person = @import("../domain/person.zig");
const rng_mod = @import("../sim/rng.zig");

pub const RefreshCadence = struct {
    /// MekHQ cadence: contract market refreshes monthly, personnel weekly,
    /// units monthly.
    pub const contract_days = 30;
    pub const personnel_days = 7;
    pub const unit_days = 30;
};

/// Number of contract offers scales with reputation and comms facilities.
pub fn contractOfferCount(reputation: i32, comms_level: u8) u8 {
    const base: i32 = 2 + @divTrunc(reputation, 20) + comms_level;
    return @intCast(std.math.clamp(base, 1, 8));
}

/// Contracts only exist where your reputation reaches (ARCH §9.2): inside an
/// influence ring the market is open; in the beachhead band offers appear
/// flagged with a penalty preview; beyond that the map is dark.
pub const OfferVisibility = enum { in_ring, beachhead, hidden };

/// Width of the beachhead band past the influence ring. // TUNE
pub const beachhead_band_ly = 30;

pub fn visibilityFor(dist_ly: u32, influence_ly: u32) OfferVisibility {
    if (dist_ly <= influence_ly) return .in_ring;
    if (dist_ly <= influence_ly + beachhead_band_ly) return .beachhead;
    return .hidden;
}

// -------------------------------------------------- site markets (ARCH §9.8)
// A market is a place: at a regional HQ (deep), a field HQ (shallow), or on
// the planet of an active contract (local industry). Meks and parts appear
// in listings by rarity roll at each refresh.

pub const SiteKind = enum {
    regional_hq,
    field_hq,
    contract_planet,

    /// Listing slots rolled per refresh. Regional depth scales with the
    /// warehouse; the rest are what they are. // TUNE
    pub fn listingSlots(self: SiteKind, warehouse_level: u8) u8 {
        return switch (self) {
            .regional_hq => 4 + warehouse_level,
            .field_hq => 2,
            .contract_planet => 3,
        };
    }

    /// Structural replacement parts for owned chassis are ALWAYS available
    /// at a regional HQ — fabricate or purchase, never rarity-rolled
    /// (ARCH §9.8). Rarity gates what's new, not repairing what you field.
    pub fn guaranteesStructural(self: SiteKind) bool {
        return self == .regional_hq;
    }
};

/// Cost multiplier and lead time for guaranteed structural fabrication. // TUNE
pub const structural_fab_cost_mult_bp: types.Bp = 15_000; // ×1.5 vs. catalog
pub const structural_fab_days = 7;

pub const Rarity = types.Rarity; // canonical home: domain/types.zig

/// One availability roll: does an item of this rarity show up in this
/// market's refresh? Industry-rich planets and better facilities see more.
pub fn listingAppears(
    rng: *rng_mod.Rng,
    rarity: Rarity,
    planet_industry: u8, // 0–5
    site_bonus: u8, // from facilities, 0–3
) bool {
    const roll = rng.roll2d6(.market) + planet_industry / 2 + site_bonus;
    return roll >= rarity.availabilityTarget();
}

/// What you'd be buying (Stage 9C.3): a listed hull's rolled condition.
pub const HullCondition = struct {
    armor_pct: u8,
    quality: types.Quality,
    damaged_slots: u8,
    destroyed_slots: u8,
    missing_components: u8,

    pub fn label(self: HullCondition) []const u8 {
        if (self.missing_components > 0) return "WRECK";
        if (self.destroyed_slots > 0) return "worn";
        if (self.armor_pct < 100 or self.damaged_slots > 0) return "used";
        return "new";
    }
};

/// One entry on a site market's board (ARCH §9.8). Listings persist until
/// bought or aged out (Stage 9C.3): hulls linger for months, staples are
/// always restocked, rare slots roll monthly.
pub const Listing = struct {
    kind: enum { unit, part },
    item_key: []const u8, // chassis_key or part_key (catalog memory)
    rarity: types.Rarity,
    price: types.CBills,
    /// The HQ whose board this is (Stage 9D: every HQ has one).
    hq: types.HqId = .none,
    quantity: u32 = 1,
    staple: bool = false,
    listed_day: u32 = 0,
    expires_day: u32 = 0,
    condition: ?HullCondition = null,
};

/// Parts always on every board (weapons and ammo are readily available;
/// the rare slots are for everything else). // TUNE
pub const staple_keys = [_][]const u8{
    "ammo_ac5", "ammo_ac20", "ammo_lrm", "ammo_srm", "ammo_mg",
    "armor",    "provisions", "medical_supplies",
    "mlas",     "slas",      "mg",       "srm2",     "srm4",   "srm6",
    "lrm5",     "lrm10",     "ac5",
};

/// Roll a listed hull's condition: most are used, some are new, a few are
/// burned-out wrecks missing structure — priced accordingly. // TUNE
pub fn rollHullCondition(rng: *rng_mod.Rng) HullCondition {
    const roll = rng.roll2d6(.market);
    const r = rng.random(.market);
    if (roll >= 10) return .{
        .armor_pct = 100,
        .quality = if (r.boolean()) .f else .e,
        .damaged_slots = 0,
        .destroyed_slots = 0,
        .missing_components = 0,
    };
    if (roll >= 7) return .{
        .armor_pct = @intCast(@min(100, 80 + rng.roll2d6(.market))),
        .quality = if (r.boolean()) .d else .c,
        .damaged_slots = r.intRangeAtMost(u8, 0, 1),
        .destroyed_slots = 0,
        .missing_components = 0,
    };
    if (roll >= 4) return .{
        .armor_pct = @intCast(30 + @as(u32, rng.roll2d6(.market)) * 4),
        .quality = if (r.boolean()) .c else .b,
        .damaged_slots = r.intRangeAtMost(u8, 1, 2),
        .destroyed_slots = 1,
        .missing_components = if (r.uintLessThan(u8, 4) == 0) 1 else 0,
    };
    return .{
        .armor_pct = @intCast(@as(u32, rng.roll2d6(.market)) * 2),
        .quality = if (r.boolean()) .b else .a,
        .damaged_slots = 1,
        .destroyed_slots = r.intRangeAtMost(u8, 2, 3),
        .missing_components = r.intRangeAtMost(u8, 1, 2),
    };
}

/// Price a hull by loadout value and condition: a new, fully loaded hull
/// at a premium; a wreck missing a leg and its guns for a fraction. // TUNE
pub fn hullPrice(base_cost: types.CBills, avg_weapon_cost: types.CBills, cond: HullCondition, price_roll_bp: types.Bp) types.CBills {
    const lost = @as(types.CBills, cond.destroyed_slots) * avg_weapon_cost +
        @as(types.CBills, cond.missing_components) * 80_000;
    const intact = @max(@divTrunc(base_cost, 5), base_cost - lost);
    const cond_bp: types.Bp = 3_000 + @as(types.Bp, @intFromEnum(cond.quality)) * 1_000 + @as(types.Bp, cond.armor_pct) * 40;
    return types.applyBp(types.applyBp(intact, cond_bp), price_roll_bp);
}

pub const HireOffer = struct {
    role: person.Role,
    experience: types.ExperienceLevel,
    signing_bonus: types.CBills = 0,
};

pub const ContractOffer = struct {
    kind: contract.ContractKind,
    employer_key: []const u8,
    planet_key: []const u8,
    terms: contract.Terms,
    expires_day: u32,
};

test "offer count clamps and grows with reputation" {
    try std.testing.expectEqual(@as(u8, 2), contractOfferCount(0, 0));
    try std.testing.expectEqual(@as(u8, 5), contractOfferCount(40, 1));
    try std.testing.expectEqual(@as(u8, 8), contractOfferCount(200, 5));
}

test "rarity works: common floods the boards, very rare is an event" {
    var rng = rng_mod.Rng.init(777);
    var common_hits: u32 = 0;
    var very_rare_hits: u32 = 0;
    for (0..10_000) |_| {
        if (listingAppears(&rng, .common, 2, 0)) common_hits += 1;
        if (listingAppears(&rng, .very_rare, 2, 0)) very_rare_hits += 1;
    }
    try std.testing.expect(common_hits > 8_000);
    try std.testing.expect(very_rare_hits < 2_500);
    try std.testing.expect(very_rare_hits > 0); // rare, not impossible
    try std.testing.expect(common_hits > very_rare_hits * 4);
}

test "only regional HQs guarantee structural parts" {
    try std.testing.expect(SiteKind.regional_hq.guaranteesStructural());
    try std.testing.expect(!SiteKind.field_hq.guaranteesStructural());
    try std.testing.expect(!SiteKind.contract_planet.guaranteesStructural());
    try std.testing.expect(SiteKind.regional_hq.listingSlots(3) > SiteKind.field_hq.listingSlots(3));
}

test "9C.3: a wreck is priced like a wreck" {
    const new: HullCondition = .{ .armor_pct = 100, .quality = .f, .damaged_slots = 0, .destroyed_slots = 0, .missing_components = 0 };
    const wreck: HullCondition = .{ .armor_pct = 10, .quality = .a, .damaged_slots = 1, .destroyed_slots = 3, .missing_components = 2 };
    const p_new = hullPrice(4_672_315, 90_000, new, 10_000);
    const p_wreck = hullPrice(4_672_315, 90_000, wreck, 10_000);
    try std.testing.expect(p_new > 4_672_315); // premium over catalog
    try std.testing.expect(p_wreck * 3 < p_new); // a fraction
    try std.testing.expectEqualStrings("WRECK", wreck.label());
    try std.testing.expectEqualStrings("new", new.label());
}

test "offer visibility bands: ring, beachhead, dark" {
    const ring: u32 = 60;
    try std.testing.expectEqual(OfferVisibility.in_ring, visibilityFor(0, ring));
    try std.testing.expectEqual(OfferVisibility.in_ring, visibilityFor(60, ring));
    try std.testing.expectEqual(OfferVisibility.beachhead, visibilityFor(61, ring));
    try std.testing.expectEqual(OfferVisibility.beachhead, visibilityFor(90, ring));
    try std.testing.expectEqual(OfferVisibility.hidden, visibilityFor(91, ring));
}
