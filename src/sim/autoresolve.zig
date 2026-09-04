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
    // (healing, morale recovery, salvage yield, ransom events). // TUNE
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
        var bp: types.Bp = 10_000;

        // Crew skill (gunnery dominates, piloting supports).
        const g: i64 = self.avg_gunnery;
        const p: i64 = self.avg_piloting;
        bp += (4 - g) * if (g < 4) @as(i64, 2_000) else 1_500;
        bp += (5 - p) * 500;

        // Materiel condition & maintenance quality.
        bp = @divTrunc(bp * self.avg_condition_pct, 100);
        bp += @as(i64, self.avg_quality.maintenanceModifier()) * -500; // A(+3)→−15%, F(−2)→+10%

        // Campaign modifiers — the player's real levers.
        if (!mods.supply_ammo) bp -= 2_500;
        if (!mods.supply_parts) bp -= 1_500;
        if (!mods.supply_provisions) bp -= 1_000;
        bp -= @divTrunc(@as(i64, mods.avg_fatigue) * 2_000, 100);
        bp += @divTrunc((@as(i64, mods.avg_morale) - 50) * 1_000, 50);
        if (mods.has_air_cover) bp += 1_500;
        if (mods.has_artillery) bp += 1_000;
        bp += @as(i64, mods.recon_quality) * 500;
        if (mods.has_mash_lance) bp += 250;
        if (mods.has_mess_lance) bp += 250;
        if (mods.has_security_lance) bp += 250;

        return @max(0, types.applyBp(self.base_strength, bp));
    }
};

pub const Outcome = enum {
    decisive_victory,
    victory,
    draw,
    defeat,
    rout,
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
