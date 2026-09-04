//! Tuning tables: every balance constant the sim reads, loaded at comptime
//! from data/tables/tuning.zon (Stage 12.17, closing the "// TUNE" debt).
//! Mirrors MekHQ `campaign/CampaignOptions` — knobs, not rules; the
//! formulas stay legible in the modules that use them. The ZON file is
//! type-checked against `Tuning` at compile time: a missing or misspelled
//! field is a build error, not a silent default.

const std = @import("std");
const types = @import("types.zig");

pub const Tuning = struct {
    hq: struct {
        influence_ly: struct { field: u32, regional: u32, brigade: u32 },
        influence_per_comms_ly: u32,
        influence_per_spaceport_ly: u32,
        paperwork_base_days: u32,
        paperwork_min_days: u32,
        paperwork_days_per_admin_level: u32,
        upgrade_cost_per_level: struct { mek_bay: types.CBills, warehouse: types.CBills, hospital: types.CBills, mess: types.CBills, training_ground: types.CBills, hiring_hall: types.CBills, comms: types.CBills, spaceport: types.CBills },
        warehouse_tons_per_level_sq: u32,
        upkeep: struct { field: types.CBills, regional: types.CBills, brigade: types.CBills },
        founding_funds: types.CBills,
        found_field_hq_cost: types.CBills,
        sale_pct: u32,
    },
    logistics: struct {
        ly_per_jump: u32,
        recharge_days: u32,
        burn_days: u32,
        charter_delay_bp: types.Bp,
        delay_step_per_level_bp: types.Bp,
        raw_hop_cost_bp: types.Bp,
        hub_discount_per_level_bp: types.Bp,
        throughput_per_level: u32,
        local_base_bp: types.Bp,
        local_step_bp: types.Bp,
        local_step_ly: u32,
        local_industry_ease_bp: types.Bp,
        local_max_bp: types.Bp,
        collar_charter_bp: types.Bp,
        dedicated_line_cost_bp: types.Bp,
        freight_per_ly: types.CBills,
    },
    network: struct {
        weeks_of_capacity: u32,
        upkeep_per_level: types.CBills,
        link_cost_per_level_sq: types.CBills,
    },
    market: struct {
        beachhead_band_ly: u32,
        regional_slots_base: u8,
        field_slots: u8,
        contract_planet_slots: u8,
        fab_cost_bp: types.Bp,
        fab_days: u32,
        stock_resale_bp: types.Bp,
        component_resale_bp: types.Bp,
        transport_price_bp: types.Bp,
        staple_price_base_bp: types.Bp,
        staple_price_per_industry_bp: types.Bp,
        beachhead_pay_bp: types.Bp,
        cooling_pay_bp: types.Bp,
        market_margin_bp: types.Bp,
        min_ops_cost: types.CBills,
        hall_arrival_target: u32,
        procurement_markup_bp: types.Bp,
        rarity_target: struct { common: u8, uncommon: u8, rare: u8, very_rare: u8 },
    },
    medical: struct {
        training_days: u32,
        training_min_days: u32,
        training_days_per_hr_staff: u32,
        heal_base_days: u32,
        heal_min_days: u32,
        patients_per_doctor: u32,
        understaffed_bp: types.Bp,
        mash_bp: types.Bp,
        hospital_bp: types.Bp,
        no_supplies_bp: types.Bp,
        beds_per_hospital_level: u32,
        beds_per_mash: u32,
        permanent_target: u8,
    },
    person: struct {
        weekly_hours: u16,
        improve_cost_base: u32,
        max_fatigue: u8,
        fatigue_per_battle: u32,
        fatigue_casualty_divisor: u32,
        fatigue_contract_cap: u32,
        fatigue_decay_base: u8,
        fatigue_decay_per_mess: u8,
        monthly_service_xp: u32,
    },
    unit: struct {
        carry: struct { mek: types.CBills, vehicle: types.CBills, aerospace: types.CBills, battle_armor: types.CBills, infantry: types.CBills, mash: types.CBills, cargo: types.CBills, dropship: types.CBills, jumpship: types.CBills },
        cold_storage_bp: types.Bp,
        reactivation_base_days: u32,
        reactivation_days_per_quality_step: u32,
        sale_bp: types.Bp,
        truck_tons: struct { cargo: u32, salvage: u32 },
    },
    battle: struct {
        gap_base_days: u32,
        mounts_per_ammo_ton: u32,
        silence_penalty_pct: i64,
        defense_bonus_bp: types.Bp,
        salvage_bv_per_truck: i64,
        salvage_bv_by_hand: i64,
    },
    field_supply: struct {
        ammo_share_pct: u32,
        armor_share_pct: u32,
        medical_share_pct: u32,
        days_per_battle: u32,
        provisions_cadence_days: u32,
    },
    finance: struct {
        loan_rate_bp: types.Bp,
        credit_floor: types.CBills,
        credit_liquidation_bp: types.Bp,
        hardship_bp: types.Bp,
        field_markup_bp: types.Bp,
    },
    hq_ops: struct {
        slots_per_bay_level: u32,
        depot_base_days: u32,
        depot_days_per_component: u32,
        build_days_per_level: u32,
        tier_upgrade_cost: types.CBills,
        tier_upgrade_build_days: u32,
        refit_labor_per_hour: types.CBills,
    },
    contract: struct {
        grace_days: u32,
        cooling_days: u32,
        decision_window_days: u32,
    },
    generation: struct {
        scout_max_tonnage: u8,
        starter_provisions: u32,
        starter_medical: u32,
        starter_armor: u32,
        starter_components_each: u32,
        starter_munitions_each: u32,
    },
    commander: struct { bonus_bp: types.Bp },
};

/// The live table.
pub const t: Tuning = @import("tuning_zon");

fn checkPositive(comptime T: type, value: T, comptime name: []const u8) !void {
    switch (@typeInfo(T)) {
        .int => {
            if (value <= 0) {
                std.debug.print("tuning field {s} must be positive\n", .{name});
                return error.BadTuning;
            }
            if (std.mem.endsWith(u8, name, "_bp") and value > 100_000) {
                std.debug.print("tuning field {s} is over 100000 basis points\n", .{name});
                return error.BadTuning;
            }
        },
        .@"struct" => |info| inline for (info.fields) |f| try checkPositive(f.type, @field(value, f.name), name ++ "." ++ f.name),
        else => {},
    }
}

test "every tuning value is positive and every basis-point knob is sane" {
    try checkPositive(Tuning, t, "t");
}

test "spot checks against the values the formulas were built on" {
    try std.testing.expectEqual(@as(u32, 60), t.hq.influence_ly.regional);
    try std.testing.expectEqual(@as(u32, 6), t.battle.mounts_per_ammo_ton);
    try std.testing.expectEqual(@as(types.Bp, 1_200), t.finance.loan_rate_bp);
    try std.testing.expectEqual(@as(types.CBills, 2_000), t.logistics.freight_per_ly);
}
