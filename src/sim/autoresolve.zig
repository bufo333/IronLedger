//! Battle autoresolution (ARCH §7) — the heart of the "hands-off" design.
//! Descended from MekHQ's ACAR (abstract combat auto resolution), extended so
//! campaign-level decisions (supply, maintenance, morale, support echelon)
//! visibly move the odds. Stage 7 implements rounds/damage/salvage; the
//! element power model starts here.
//!
//! Design goal: legible outcomes. The AAR must let the player trace a loss
//! to "C-grade maintenance and two green lances," not to a die roll.

const std = @import("std");
const types = @import("../domain/types.zig");

/// Campaign-state modifiers for one side, gathered before the engagement.
/// Every field is a lever the player controls without touching a battle.
pub const CampaignMods = struct {
    supply_parts: bool = true, // false = shortage
    supply_ammo: bool = true,
    supply_medical: bool = true,
    supply_provisions: bool = true,
    avg_fatigue: u8 = 0, // 0–100
    avg_morale: u8 = 50, // 0–100
    commander_tactics: u8 = 7, // skill target number, lower = better
    has_air_cover: bool = false,
    has_artillery: bool = false,
    has_field_repair: bool = false, // mobile field base / repair depot in range
    recon_quality: u8 = 0, // 0–3, from scouting lances & comms facility
    // Support-company lances (force.SupportLanceKind, ARCH §9.3). Effects
    // here are small and direct; their bigger payoffs are campaign-side
    // (healing, morale recovery, salvage yield, ransom events); the sizes are tuning.autoresolve.
    has_mash_lance: bool = false, // troops fight harder knowing medevac exists
    has_mess_lance: bool = false, // hot food at the front
    has_security_lance: bool = false, // rear/prisoner security frees combat units
    has_salvage_lance: bool = false, // no power effect; raises post-battle yield
};

/// One resolvable element: a lance/flight/platoon aggregated for battle.
pub const Element = struct {
    force: types.ForceId = .none,
    /// Sum of BV2-derived base strengths of the element's units (Stage 7:
    /// from chassis catalog). Placeholder scale: ~1000/mek.
    base_strength: i64,
    avg_gunnery: u8 = 4,
    avg_piloting: u8 = 5,
    avg_condition_pct: u8 = 100, // from Unit.conditionPct()
    avg_quality: types.Quality = .c,

    /// Effective combat power after crew skill and condition. The crew
    /// multiplier follows the 2d6 to-hit curve: each point of gunnery below
    /// 4 is worth ~20%, above 4 costs ~15%. Tuned in Stage 7.
    pub fn effectivePower(self: Element, mods: CampaignMods) i64 {
        const t = @import("../domain/tuning.zig").t.autoresolve;
        var bp: types.Bp = types.full_bp;

        // Crew skill (gunnery dominates, piloting supports).
        const g: i64 = self.avg_gunnery;
        const p: i64 = self.avg_piloting;
        bp += (4 - g) * if (g < 4) t.gunnery_below_bp else t.gunnery_above_bp;
        bp += (5 - p) * t.piloting_bp;

        // Materiel condition & maintenance quality.
        bp = @divTrunc(bp * self.avg_condition_pct, 100);
        bp += @as(i64, self.avg_quality.maintenanceModifier()) * t.quality_step_bp; // A(+3)→−15%, F(−2)→+10%

        // Campaign modifiers — the player's real levers.
        if (!mods.supply_ammo) bp -= t.no_ammo_bp;
        if (!mods.supply_parts) bp -= t.no_parts_bp;
        if (!mods.supply_provisions) bp -= t.no_provisions_bp;
        bp -= @divTrunc(@as(i64, mods.avg_fatigue) * t.fatigue_scale_bp, 100);
        bp += @divTrunc((@as(i64, mods.avg_morale) - 50) * t.morale_scale_bp, 50);
        if (mods.has_air_cover) bp += t.air_cover_bp;
        if (mods.has_artillery) bp += t.artillery_bp;
        bp += @as(i64, mods.recon_quality) * t.recon_per_level_bp;
        if (mods.has_mash_lance) bp += t.support_lance_bp;
        if (mods.has_mess_lance) bp += t.support_lance_bp;
        if (mods.has_security_lance) bp += t.support_lance_bp;

        return @max(0, types.applyBp(self.base_strength, bp));
    }
};

pub const Outcome = enum {
    decisive_victory,
    victory,
    draw,
    defeat,
    rout,

    /// The company lost the fight (defeat or rout).
    pub fn isLoss(self: Outcome) bool {
        return self == .defeat or self == .rout;
    }

    /// The company still holds the ground afterwards (a draw included;
    /// a cautious withdrawal is the caller's exception).
    pub fn heldField(self: Outcome) bool {
        return self == .decisive_victory or self == .victory or self == .draw;
    }
};

test "supply and morale move combat power" {
    const elem: Element = .{ .base_strength = 4_000, .avg_gunnery = 4, .avg_piloting = 5 };

    const well_supplied = elem.effectivePower(.{});
    const starved = elem.effectivePower(.{
        .supply_ammo = false,
        .supply_parts = false,
        .supply_provisions = false,
        .avg_fatigue = 60,
        .avg_morale = 20,
    });
    try std.testing.expect(starved < well_supplied);
    // The gap should be material, not cosmetic: starved fights at <70%.
    try std.testing.expect(starved * 10 < well_supplied * 7);
}

test "elite crews outfight green crews in the same machines" {
    const machines: Element = .{ .base_strength = 4_000 };
    var elite = machines;
    elite.avg_gunnery = 2;
    elite.avg_piloting = 3;
    var green = machines;
    green.avg_gunnery = 5;
    green.avg_piloting = 6;
    try std.testing.expect(elite.effectivePower(.{}) > green.effectivePower(.{}));
}
