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
        /// The hall never runs dry (12B.10): at least this many candidates
        /// of every role walk the boards at a hiring hall (combat crews and
        /// techs get `hall_floor_combat`), topped up daily.
        hall_floor: u32,
        hall_floor_combat: u32,
        procurement_markup_bp: types.Bp,
        rarity_target: struct { common: u8, uncommon: u8, rare: u8, very_rare: u8 },
        /// The contract board (play feedback): never fewer than `offers_min`
        /// offers, never more than `offers_max`; the rating letter and comms
        /// reach fill the gap between.
        offers_min: u8,
        offers_max: u8,
        /// Part availability (12C.14, MekHQ acquisition target by tech base
        /// and TechManual availability code): the roll modifier per
        /// availability letter, the penalty a periphery world puts on
        /// Inner Sphere parts rated D or worse, and what comms reach adds
        /// per two facility levels.
        avail_mod: struct { a: i8, b: i8, c: i8, d: i8, e: i8, f: i8 },
        periphery_penalty: i32,
        comms_bonus_per_two_levels: i32,
        /// Black market (12C.17, AtB black market): at an HQ with a hiring
        /// hall and comms of `black_market_comms` or more, a monthly 2d6 of
        /// `black_market_target`+ puts one rare hull or scarce part on the
        /// board at `black_market_price_bp` of list, gone in
        /// `black_market_days`. Buying rolls 2d6: `black_market_fraud_target`
        /// or under and the seller vanishes with the money (standing with
        /// the world's house −`black_market_standing_loss`); a real sale
        /// still costs a point with the house and earns one with the pirates.
        black_market_comms: u8,
        black_market_target: u8,
        black_market_price_bp: types.Bp,
        black_market_days: u32,
        black_market_fraud_target: u8,
        black_market_standing_loss: i32,
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
        /// Medics (12B.11): each covers this many patients toward the
        /// doctor ratio, and adds a field bed (two medics per bed without a
        /// MASH truck to staff).
        patients_per_medic: u32,
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
        /// Turnover (Stage 12.20, AtB retirement/defection abstracted):
        /// after `turnover_min_tenure_months`, anyone whose morale is under
        /// `restless_morale` or fatigue over `exhausted_fatigue` rolls 2d6
        /// each payday; under `turnover_target` (+1 per restless flag) they
        /// hand in their notice (an inbox decision, not a walkout). Target 3:
        /// one flag fires on a 3 or less (8.3%), both on a 4 or less (16.7%). Long service (`retire_tenure_months`)
        /// retires instead of resigning.
        /// Garrison duty is nearly home (12.30): weekly fatigue recovery in
        /// the field on garrison-class work as a share of the home rate,
        /// and the tour's fatigue bill counts months divided by this.
        garrison_rest_bp: types.Bp,
        garrison_tour_months_divisor: u32,
        turnover_min_tenure_months: u32,
        restless_morale: u8,
        exhausted_fatigue: u8,
        /// Fatigue bands (12C.1, CamOps fatigue / MekHQ Fatigue option):
        /// tired from `fatigue_tired` (+1 gunnery & piloting), exhausted
        /// from `exhausted_fatigue` (+2), spent from `fatigue_spent` (+3 and
        /// unfit: the auto-assigner seats someone fresher when it can).
        fatigue_tired: u8,
        fatigue_spent: u8,
        turnover_target: u8,
        retire_tenure_months: u32,
        /// Departure payout (12C.2, MekHQ retirement bonus / AtB retirement
        /// payment): `severance_months_per_year` months' salary per full
        /// year served, capped at `severance_cap_months`; a plain firing
        /// pays `fire_severance_bp` of it.
        severance_months_per_year: u32,
        severance_cap_months: u32,
        fire_severance_bp: types.Bp,
        /// Shares (12C.3, AtB shares system): a combat or tech hand holds
        /// `shares_base` after `shares_tenure_months`, a founder (on the
        /// books day 0) `shares_founder`, plus one per rank above sergeant;
        /// `share_profit_default_bp` of contract income is paid out pro rata
        /// at completion (the owner sets the live figure with `shares`).
        /// Every `shares_per_restless` shares cancel one restless flag, and
        /// shareholders take half severance.
        shares_base: u8,
        shares_founder: u8,
        shares_tenure_months: u32,
        shares_per_restless: u8,
        share_profit_default_bp: types.Bp,
        /// Ages (12C.4, MekHQ birthdays / AtB age-based retirement): from
        /// `age_old` a person adds a restless flag on the turnover roll, at
        /// `age_retire` they retire on the next payday at home; under
        /// `age_young` XP awards are scaled by `xp_young_bp`.
        age_old: u32,
        age_retire: u32,
        age_young: u32,
        xp_young_bp: types.Bp,
        /// Loyalty (12C.5, AtB founder/loyalty modifiers): each modifier in
        /// play cancels one restless flag on the payday roll — a founder
        /// (who also never rolls at all while morale is at least
        /// `founder_morale_floor`), `veteran_tours` or more tours served, a
        /// raise or bonus accepted within `raise_loyalty_days`, an award
        /// within `award_loyalty_days`.
        founder_morale_floor: u8,
        veteran_tours: u32,
        /// Morale from the field (12C.11): outfit-wide swings when a
        /// contract closes strong (outstanding/strong grade) or is breached
        /// (a performance failure at term is a breach); and the extra point
        /// a win on a weighted scenario earns the company.
        morale_contract_strong: i32,
        morale_contract_breached: i32,
        morale_objective_bonus: i32,
        raise_loyalty_days: u32,
        award_loyalty_days: u32,
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
        /// Physical salvage (Stage 12.23): a crewed salvage lance strips
        /// this much more; what is not a whole hull becomes parts at these
        /// BV prices (armor per ton, a weapon, a structural component).
        salvage_lance_bonus_bp: types.Bp,
        salvage_bv_per_armor_ton: i64,
        salvage_bv_per_weapon: i64,
        salvage_bv_per_component: i64,
    },
    field_supply: struct {
        ammo_share_pct: u32,
        armor_share_pct: u32,
        medical_share_pct: u32,
        days_per_battle: u32,
        provisions_cadence_days: u32,
        /// Safety days for the resupply policy a deployment gets by default.
        default_min_days: u16,
    },
    finance: struct {
        loan_rate_bp: types.Bp,
        credit_floor: types.CBills,
        credit_liquidation_bp: types.Bp,
        hardship_bp: types.Bp,
        field_markup_bp: types.Bp,
        /// Defaults set at acceptance (Stage 12.19): a share of the advance
        /// handed to the company as local operating funds, and a standing
        /// top-up policy for it — both clearable.
        field_float_bp: types.Bp,
        field_policy_floor: types.CBills,
        field_policy_cap: types.CBills,
        /// Default standing top-up for the starter HQ.
        hq_policy_floor: types.CBills,
        hq_policy_cap: types.CBills,
    },
    hq_ops: struct {
        slots_per_bay_level: u32,
        depot_base_days: u32,
        depot_days_per_component: u32,
        build_days_per_level: u32,
        tier_upgrade_cost: types.CBills,
        tier_upgrade_build_days: u32,
        refit_labor_per_hour: types.CBills,
        /// Repair outcomes (12C.12, MekHQ repair roll): a depot repair or
        /// refit rolls 2d6 + (5 − tech skill) against `repair_target_base`
        /// + the hull's quality modifier (A worst … F best). Margin of
        /// `repair_fault_margin` or more is clean; under it the job lands
        /// with a lingering fault (quality one step worse); a miss redoes
        /// `repair_redo_bp` of the bay time; a natural 2 botches (a piece
        /// of gear destroyed).
        repair_target_base: i32,
        repair_fault_margin: i32,
        repair_redo_bp: types.Bp,
    },
    /// Quality drift (12C.13, MekHQ maintenance quality). The weekly
    /// maintenance roll (2d6 + 5 − tech skill vs. 4 + quality modifier, +1
    /// afield, +3 uncovered) moves the hull's letter one step toward A
    /// (worst) on a miss by `quality_drop_margin` or more, one step toward
    /// F (best) on a success by `quality_rise_margin` or more; resale moves
    /// `quality_sale_bp_per_step` per step from C.
    maintenance: struct {
        quality_drop_margin: i32,
        quality_rise_margin: i32,
        quality_sale_bp_per_step: types.Bp,
        /// Tech target numbers (12C.15): the flat hours-per-class table is
        /// scaled by the hull's quality (A worst … F best), by an exotic
        /// design (very rare on the market), and by the tech's own
        /// skill — a veteran turns a wrench faster than a green hand.
        hours_quality_bp: struct { a: types.Bp, b: types.Bp, c: types.Bp, d: types.Bp, e: types.Bp, f: types.Bp },
        hours_exotic_bp: types.Bp,
        hours_skill_bp: struct { elite: types.Bp, veteran: types.Bp, regular: types.Bp, green: types.Bp, untrained: types.Bp },
    },
    /// Dragoons rating (12C.6, CamOps "Mercenary Rating", MekHQ
    /// `UnitRating`): the letter thresholds on the summed score and the
    /// points each contract outcome adds to the combat record.
    rating: struct {
        letter_d: i32,
        letter_c: i32,
        letter_b: i32,
        letter_a: i32,
        letter_a_star: i32,
        /// The combat record of an outfit that has never closed a contract.
        record_unproven: i32,
        record_outstanding: i32,
        record_strong: i32,
        record_satisfactory: i32,
        record_poor: i32,
        record_failed: i32,
        record_breached: i32,
        record_cap: i32,
        /// 12C.7 — what the letter buys on the board: pay multiplier per
        /// letter (F…A*), the letter index from which the Great Houses hire
        /// (0 = F, 1 = D, …), the index from which planetary assaults are
        /// offered, and the negotiation edge (index − `negotiation_offset`).
        pay_bp_f: types.Bp,
        pay_bp_d: types.Bp,
        pay_bp_c: types.Bp,
        pay_bp_b: types.Bp,
        pay_bp_a: types.Bp,
        pay_bp_a_star: types.Bp,
        house_min_index: u8,
        assault_min_index: u8,
        negotiation_offset: i32,
        recruit_bonus_index: u8,
    },
    contract: struct {
        grace_days: u32,
        cooling_days: u32,
        decision_window_days: u32,
        /// Faction standing (Stage 12.21), −100…100 per house: what a
        /// completed tour earns the employer, what fighting a house costs
        /// with them, what a breach costs, the pay swing per point (bp),
        /// the line under which a house shuns you (half its offers, like
        /// cooling), and the monthly drift back toward neutral.
        standing_complete_gain: i32,
        standing_enemy_loss: i32,
        standing_breach_loss: i32,
        standing_pay_bp_per_point: types.Bp,
        /// Shunned when standing is at or under −this.
        standing_shun_depth: i32,
        standing_drift_per_month: i32,
        /// Chance a contract rolls on the weekly deck at all (bp). Play
        /// feedback (12.24): too many small happenings.
        weekly_event_chance_bp: types.Bp,
        /// A weekly decision of one kind waits this many days before it can
        /// come up again (play feedback: the same smuggler every month).
        weekly_decision_cooldown_days: u32,
        /// After this many identical answers in a row the answer becomes a
        /// standing order, applied without asking (`sop clear <event>` resets).
        standing_order_after: u8,
        /// Command rights (12B.1, AtB/CamOps): what the employer's grip on
        /// your company costs and buys, from integrated to independent.
        rights: struct {
            /// Days off the battle gap: the employer picks more fights.
            gap_delta: struct { integrated: i32, house: i32, liaison: i32, independent: i32 },
            /// Your share of the salvage claim after the liaison's cut.
            salvage_share_bp: struct { integrated: types.Bp, house: types.Bp, liaison: types.Bp, independent: types.Bp },
            /// Pay multiplier priced into the offer.
            pay_bp: struct { integrated: types.Bp, house: types.Bp, liaison: types.Bp, independent: types.Bp },
            /// Score a defeat costs under integrated command (harder grading).
            integrated_defeat_score: i32,
        },
        /// Salvage exchange (12B.2, CamOps): the employer keeps the wrecks
        /// and pays the claim in cash at this share of BV value, at this
        /// many C-bills per BV. Rolled on one offer in `salvage_exchange_in`.
        salvage_exchange_bp: types.Bp,
        salvage_cbills_per_bv: types.CBills,
        salvage_exchange_in: u32,
        /// Negotiation (12B.3, CamOps): 2d6 + the rating edge (12C.7)
        /// + the command office's skill edge vs `negotiation_target` −
        /// standing/`negotiation_standing_per`; a miss hardens the pay by
        /// `negotiation_fail_pay_bp`; a natural 2 withdraws the offer.
        negotiation_target: i32,
        negotiation_standing_per: i32,
        negotiation_fail_pay_bp: types.Bp,
        negotiation_pay_step_bp: types.Bp,
        /// Prisoners (12B.7): captured per battle when a security lance holds
        /// the field — one per this many kills, capped; ransom by experience
        /// (green…elite); the 2d6 target a captive must meet to take your coin.
        prisoners_per_kills: u32,
        prisoners_max_per_battle: u32,
        ransom_green: types.CBills,
        ransom_regular: types.CBills,
        ransom_veteran: types.CBills,
        ransom_elite: types.CBills,
        recruit_prisoner_target: u8,
    },
    generation: struct {
        scout_max_tonnage: u8,
        starter_provisions: u32,
        starter_medical: u32,
        starter_armor: u32,
        starter_components_each: u32,
        starter_munitions_each: u32,
        /// Keep-stocked provisions line at the starter HQ (min / target tons).
        provisions_keep_min: u32,
        provisions_keep_target: u32,
    },
    commander: struct { bonus_bp: types.Bp },
};

/// The live table.
pub const t: Tuning = @import("tuning_zon");

fn checkPositive(comptime T: type, value: T, comptime name: []const u8) !void {
    switch (@typeInfo(T)) {
        .int => |info| {
            // Signed knobs (deltas, scores) may be zero or negative by design.
            if (info.signedness == .signed) return;
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
