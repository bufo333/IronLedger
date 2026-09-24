//! Tuning tables: every balance constant the sim reads, loaded at comptime
//! from data/tables/tuning.zon (Stage 12.17).
//! MekHQ counterpart: `campaign/CampaignOptions` — knobs, not rules; the
//! formulas stay legible in the modules that use them. The ZON file is
//! type-checked against `Tuning` at compile time: a missing or misspelled
//! field is a build error, not a silent default.

const std = @import("std");
const types = @import("types.zig");

/// A row of the staff-base table (zeros are legitimate).
pub const StaffRow = struct { admin: u32, logistics: u32, hr: u32, finance: u32 };
/// A tier's fixed slots (zeros are legitimate).
pub const CapacityRow = struct { combat_companies: u8, lances_per_company: u8, support_companies: u8, support_lances: u8, air_companies: u8, dropship_berths: u8, jumpship_berths: u8 };

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
        /// Staff each tier needs before any facility (ARCH §9.4); a table of
        /// desks, so a zero is a real value.
        staff_base: struct {
            field: StaffRow,
            regional: StaffRow,
            brigade: StaffRow,
        },
        /// Staff per facility level: bays, warehouses and ports want
        /// logistics; halls and grounds want HR; care facilities want HR;
        /// comms want admins.
        staff_per_level: struct { logistics: u32, hr_halls: u32, hr_care: u32, admin_comms: u32 },
        /// Finance desks: one per this many other staff.
        finance_share_divisor: u32,
        /// Understaffing steps: −1 effective level per this fraction (1/n) of shortfall.
        understaffing_steps: u32,
        /// Line lances per company: without a bay, with one, and with a bay of `lances_full_bay_level`.
        lances_no_bay: u8,
        lances_with_bay: u8,
        lances_full_bay: u8,
        lances_full_bay_level: u8,
        /// Support lances: the staple four, +1 for a mess hall of `support_mess_level`,
        /// +1 for a hospital or warehouse of `support_deep_level`.
        support_base: u8,
        support_mess_level: u8,
        support_deep_level: u8,
        /// Slots per tier (ARCH §9.3); facility-driven slots are computed.
        capacity_field: CapacityRow,
        capacity_regional: struct { combat_companies: u8, support_companies: u8, air_port_level: u8, dropship_base: u8, dropship_port_levels_each: u8, jumpship_port_level: u8, jumpship_comms_level: u8 },
        capacity_brigade: struct { combat_companies: u8, support_companies: u8, support_extra: u8, air_base: u8, air_port_level: u8, dropship_base: u8, jumpship_base: u8, jumpship_port_level: u8, jumpship_comms_level: u8 },
        /// Facility levels a support trade needs at the home HQ.
        support_lance_needs: struct { mess: u8, mash_hospital: u8, transport_warehouse: u8 },
        /// Highest refit class a tier's bay reaches (Quality index: 1 = B … 5 = F).
        refit_class_cap: struct { field: u8, regional: u8, brigade: u8 },
    },
    logistics: struct {
        /// Days a same-world move still takes (loading, a short burn, paperwork).
        same_world_days: u32,
        ly_per_jump: u32,
        recharge_days: u32,
        burn_days: u32,
        charter_delay_bp: types.Bp,
        delay_step_per_level_bp: types.Bp,
        raw_hop_cost_bp: types.Bp,
        hub_discount_per_level_bp: types.Bp,
        /// Supply units a week a link moves per level.
        throughput_per_level: u32,
        /// Tons in one supply unit.
        tons_per_supply_unit: u32, // TUNE
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
        upkeep_per_level: types.CBills,
        link_cost_per_level_sq: types.CBills,
    },
    market: struct {
        /// Parts always on every board (weapons and ammo are readily available; the rare slots are for everything else).
        staple_keys: []const []const u8,
        /// Listed hull condition by 2d6: at or above `new_roll` new, `used_roll` used, `worn_roll` worn, below it a wreck.
        cond_new_roll: u8,
        cond_used_roll: u8,
        cond_worn_roll: u8,
        /// A hall candidate's signing bonus: this many months' salary plus one per experience step.
        asking_bonus_base_months: u8,
        /// Days a hall walk-in or floor top-up stays listed; the weekly refresh's crowd.
        hall_walkin_days: u32,
        hall_refresh_days: u32,
        /// Days a staple hull listing stays on the board.
        staple_listing_days: u32,
        /// Hull pricing by condition (ARCH §9.8): what a missing component
        /// knocks off, and the condition multiplier's base, per quality
        /// step and per armour point (basis points).
        wreck_component_value: types.CBills,
        cond_base_bp: types.Bp,
        cond_quality_bp: types.Bp,
        cond_armor_bp_per_pct: types.Bp,
        /// The board's rough repair bill for a listed hull (per destroyed
        /// slot, per damaged slot, per missing component, per 15% armour).
        repair_guess_destroyed: types.CBills,
        repair_guess_damaged: types.CBills,
        repair_guess_component: types.CBills,
        repair_guess_armor_step: types.CBills,
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
        /// The hall never runs dry: at least this many candidates
        /// of every role walk the boards at a hiring hall (combat crews and
        /// techs get `hall_floor_combat`), topped up daily.
        hall_floor: u32,
        hall_floor_combat: u32,
        procurement_markup_bp: types.Bp,
        rarity_target: struct { common: u8, uncommon: u8, rare: u8, very_rare: u8 },
        /// The contract board: never fewer than `offers_min`
        /// offers, never more than `offers_max`; the rating letter and comms
        /// reach fill the gap between.
        offers_min: u8,
        offers_max: u8,
        /// Part availability (MekHQ acquisition target by tech base
        /// and TechManual availability code): the roll modifier per
        /// availability letter, the penalty a periphery world puts on
        /// Inner Sphere parts rated D or worse, and what comms reach adds
        /// per two facility levels.
        avail_mod: struct { a: i8, b: i8, c: i8, d: i8, e: i8, f: i8 },
        periphery_penalty: i32,
        comms_bonus_per_two_levels: i32,
        /// Black market (AtB black market): at an HQ with a hiring
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
        /// Iron Man: heals in this share of the days, never under the floor.
        iron_man_heal_bp: types.Bp,
        iron_man_min_days: u32,
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
        /// Medics: each covers this many patients toward the
        /// doctor ratio, and adds a field bed (two medics per bed without a
        /// MASH truck to staff).
        patients_per_medic: u32,
        permanent_target: u8,
    },
    person: struct {
        /// Readiness ranking for an offer: points against a company
        /// per hull in the depot, per spent crew, per wounded, and the
        /// divisors that turn fatigue, transit days and morale into points.
        readiness_depot_weight: i32,
        readiness_spent_weight: i32,
        readiness_wounded_weight: i32,
        readiness_fatigue_divisor: u32,
        readiness_transit_divisor: u32,
        readiness_morale_divisor: u32,
        /// Skill points a permanent head or internal injury costs.
        permanent_penalty_per_injury: u8,
        /// Morale at home: +1 per this many HR admins at the seat, capped.
        hr_morale_admins_per_point: u32,
        hr_morale_bonus_max: u32,
        /// HR admins at the seat that add +1 to the recruit-quality roll.
        recruit_hr_admins: u32,
        /// Tech hours: half rate with no astechs, full at this many per tech.
        astechs_per_tech_full_rate: u32,
        tech_no_team_bp: types.Bp,
        /// Morale bands the boards colour: under `restless_morale` is
        /// critical, under `morale_content` amber; `morale_content` is also
        /// where rested spirits settle at home.
        morale_content: u8,
        /// Garrison duty lifts spirits below this while fatigue stays under
        /// the grind line; fatigue over `fatigue_grind` grinds morale down.
        morale_garrison_lift_below: u8,
        fatigue_grind: u8,
        /// Average fatigue at or under this counts a company as rested.
        fatigue_rested: u8,
        weekly_hours: u16,
        improve_cost_base: u32,
        max_fatigue: u8,
        fatigue_per_battle: u32,
        fatigue_casualty_divisor: u32,
        fatigue_contract_cap: u32,
        fatigue_decay_base: u8,
        fatigue_decay_per_mess: u8,
        monthly_service_xp: u32,
        /// Garrison duty is nearly home: weekly fatigue recovery in
        /// the field on garrison-class work as a share of the home rate,
        /// and the tour's fatigue bill counts months divided by this.
        garrison_rest_bp: types.Bp,
        garrison_tour_months_divisor: u32,
        /// Turnover (AtB retirement/defection abstracted):
        /// after `turnover_min_tenure_months`, anyone whose morale is under
        /// `restless_morale` or fatigue over `exhausted_fatigue` rolls 2d6
        /// each payday; under `turnover_target` (+1 per restless flag) they
        /// hand in their notice (an inbox decision, not a walkout). Target 3:
        /// one flag fires on a 3 or less (8.3%), both on a 4 or less (16.7%). Long service (`retire_tenure_months`)
        /// retires instead of resigning.
        turnover_min_tenure_months: u32,
        restless_morale: u8,
        exhausted_fatigue: u8,
        /// Fatigue bands (CamOps fatigue / MekHQ Fatigue option):
        /// tired from `fatigue_tired` (+1 gunnery & piloting), exhausted
        /// from `exhausted_fatigue` (+2), spent from `fatigue_spent` (+3 and
        /// unfit: the auto-assigner seats someone fresher when it can).
        fatigue_tired: u8,
        fatigue_spent: u8,
        turnover_target: u8,
        retire_tenure_months: u32,
        /// Departure payout (MekHQ retirement bonus / AtB retirement
        /// payment): `severance_months_per_year` months' salary per full
        /// year served, capped at `severance_cap_months`; a plain firing
        /// pays `fire_severance_bp` of it.
        severance_months_per_year: u32,
        severance_cap_months: u32,
        fire_severance_bp: types.Bp,
        /// Shares (AtB shares system): a combat or tech hand holds
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
        /// Ages (MekHQ birthdays / AtB age-based retirement): from
        /// `age_old` a person adds a restless flag on the turnover roll, at
        /// `age_retire` they retire on the next payday at home; under
        /// `age_young` XP awards are scaled by `xp_young_bp`.
        age_old: u32,
        age_retire: u32,
        age_young: u32,
        xp_young_bp: types.Bp,
        /// Loyalty (AtB founder/loyalty modifiers): each modifier in
        /// play cancels one restless flag on the payday roll — a founder
        /// (who also never rolls at all while morale is at least
        /// `founder_morale_floor`), `veteran_tours` or more tours served, a
        /// raise or bonus accepted within `raise_loyalty_days`, an award
        /// within `award_loyalty_days`.
        founder_morale_floor: u8,
        veteran_tours: u32,
        /// Morale from the field: outfit-wide swings when a
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
        /// Weekly maintenance hours by kind; meks by tonnage band
        /// (infantry has no hull and takes none).
        maintenance_hours: struct { mek_light: u32, mek_medium: u32, mek_heavy: u32, mek_assault: u32, vehicle: u32, aerospace: u32, battle_armor: u32, dropship: u32, jumpship: u32 },
        mek_light_max_tons: u8,
        mek_medium_max_tons: u8,
        mek_heavy_max_tons: u8,
        /// Below this condition the hangar calls a hull "shot up".
        shot_up_condition_pct: u8,
        /// Where the armour meter turns amber, then red. Bands, not
        /// thresholds anything decides on: the rules read `armor_pct`.
        armor_amber_pct: u8, // TUNE
        armor_red_pct: u8, // TUNE
        carry: struct { mek: types.CBills, vehicle: types.CBills, aerospace: types.CBills, battle_armor: types.CBills, infantry: types.CBills, mash: types.CBills, cargo: types.CBills, dropship: types.CBills, jumpship: types.CBills },
        cold_storage_bp: types.Bp,
        reactivation_base_days: u32,
        reactivation_days_per_quality_step: u32,
        sale_bp: types.Bp,
        truck_tons: struct { cargo: u32, salvage: u32 },
    },
    battle: struct {
        /// The engagement roll (2d6 + modifiers) at or above which each
        /// outcome falls; under `defeat` is a rout.
        outcome_at: struct { decisive_victory: i32, victory: i32, draw: i32, defeat: i32 },
        /// Share of the engaged hulls hit, by outcome.
        hit_pct: struct { decisive_victory: i32, victory: i32, draw: i32, defeat: i32, rout: i32 },
        /// Share of the enemy's BV destroyed, by outcome.
        enemy_loss_pct: struct { decisive_victory: u32, victory: u32, draw: u32, defeat: u32, rout: u32 },
        /// A hit's 2d6 severity: armour lost per point, C-bills of damage
        /// per point, the severity that also breaks a slot, cooks an ammo
        /// bin off, kills the hull outright, or kills it with no armour left.
        armor_per_severity: u8,
        /// Engagements kept as records. The permanent account is
        /// the AAR in the campaign log; these are what the screens read,
        /// so a few tours' worth is plenty.
        reports_kept: u32, // TUNE
        damage_value_per_severity: types.CBills,
        slot_hit_severity: u8,
        cookoff_severity: u8,
        kill_severity: u8,
        kill_armorless_severity: u8,
        /// Wound severity by hit: crippling at or over, serious at or over, else light.
        wound_crippling_severity: u8,
        wound_serious_severity: u8,
        /// The follow-up 2d6 a hard hit must reach to wound (MASH forward: harder).
        wound_target: u8,
        wound_target_mash: u8,
        /// Contract score per outcome (defeat comes from the command rights;
        /// concede is an engagement with nobody to put in the line).
        score: struct { decisive_victory: i32, victory: i32, draw: i32, rout: i32, concede: i32 },
        /// Company morale per outcome, and the relief a mess lance gives after a loss.
        morale: struct { decisive_victory: i32, victory: i32, draw: i32, defeat: i32, rout: i32, mess_relief: i32 },
        /// Fatigue a fight adds before the environment's share.
        fatigue_base: u8,
        /// XP for an engagement that scored, and for one that did not.
        xp_scored: u8,
        xp_fought: u8,
        gap_base_days: u32,
        mounts_per_ammo_ton: u32,
        silence_penalty_pct: i64,
        defense_bonus_bp: types.Bp,
        salvage_bv_per_truck: i64,
        salvage_bv_by_hand: i64,
        /// Physical salvage: a crewed salvage lance strips
        /// this much more; what is not a whole hull becomes parts at these
        /// BV prices (armor per ton, a weapon, a structural component).
        salvage_lance_bonus_bp: types.Bp,
        salvage_bv_per_armor_ton: i64,
        salvage_bv_per_weapon: i64,
        salvage_bv_per_component: i64,
        /// Garrison probes (ARCH §8): garrison-class contracts see a
        /// probe every `garrison_probe_base_days` + 2d6 × `garrison_probe_die_days`
        /// days, the enemy committing `garrison_probe_lances` of its lances.
        garrison_probe_base_days: u32,
        garrison_probe_die_days: u32,
        garrison_probe_lances: u8,
        /// Wrecks rolled off the enemy's table after a field held,
        /// from which the salvage claim buys what it can reach.
        salvage_candidates: u32, // TUNE
        /// Press the advance or consolidate: after a field held,
        /// the commander chooses the tempo. Pressing puts the next
        /// engagement `press_gap_days` out instead of the usual gap, and
        /// the employer notices (`press_score`); the company pays for it
        /// in fatigue. Consolidating buys a breather the troops feel.
        press_gap_days: u32, // TUNE
        press_score: i16, // TUNE
        press_fatigue: u8, // TUNE
        consolidate_morale: i8, // TUNE
        /// Days before a scheduled engagement that the contact warning
        /// shows. At most `battle.min_gap_days`, so every scheduled
        /// engagement opens its window on an advance.
        contact_warning_days: u32, // TUNE
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
        /// Defaults set at acceptance: a share of the advance
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
        /// Depot labour per structure hit: the hull's price over this.
        depot_labour_divisor: types.CBills,
        slots_per_bay_level: u32,
        depot_base_days: u32,
        depot_days_per_component: u32,
        build_days_per_level: u32,
        tier_upgrade_cost: types.CBills,
        tier_upgrade_build_days: u32,
        refit_labor_per_hour: types.CBills,
        /// Repair outcomes (MekHQ repair roll): a depot repair or
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
    /// Quality drift (MekHQ maintenance quality). The weekly
    /// maintenance roll (2d6 + 5 − tech skill vs. 4 + quality modifier, +1
    /// afield, +3 uncovered) moves the hull's letter one step toward A
    /// (worst) on a miss by `quality_drop_margin` or more, one step toward
    /// F (best) on a success by `quality_rise_margin` or more; resale moves
    /// `quality_sale_bp_per_step` per step from C.
    maintenance: struct {
        /// Hours a field repair costs the hull's tech.
        hours_damaged_slot: u32,
        hours_destroyed_slot: u32,
        hours_armor_patch: u32,
        /// Weekly check target: base, plus for a deployed hull, plus with no tech.
        target_base: i32,
        target_deployed: i32,
        target_uncovered: i32,
        /// Labour per field repair: the part's cost over this.
        labour_damaged_divisor: types.CBills,
        labour_destroyed_divisor: types.CBills,
        /// Armour patched per week and its labour.
        armor_patch_pct: u8,
        armor_patch_labour: types.CBills,
        /// The night after a fight: the share of the company's
        /// pooled spare tech-hours the field repair push spends.
        push_hours_bp: types.Bp, // TUNE
        /// Tech-hours a ready Logistics lance's field workshop adds to the
        /// night's repair push.
        push_workshop_hours: u32, // TUNE
        /// A snake-eyes week hurts the tech on a follow-up 2d6 at or under
        /// this, for this many days plus 2d6.
        accident_target: u8,
        accident_days_base: u8,
        /// Days off a bay accident costs before the 2d6.
        bay_accident_days_base: u32,
        /// An injury's severity from its days off: light up to the first, serious up to the second, crippling past it.
        injury_days_serious: u32,
        injury_days_crippling: u32,
        /// Weekly consumables: the hull's price over this (~0.17%/month).
        consumables_divisor: types.CBills,
        quality_drop_margin: i32,
        quality_rise_margin: i32,
        quality_sale_bp_per_step: types.Bp,
        /// Tech target numbers: the flat hours-per-class table is
        /// scaled by the hull's quality (A worst … F best), by an exotic
        /// design (very rare on the market), and by the tech's own
        /// skill — a veteran turns a wrench faster than a green hand.
        hours_quality_bp: struct { a: types.Bp, b: types.Bp, c: types.Bp, d: types.Bp, e: types.Bp, f: types.Bp },
        hours_exotic_bp: types.Bp,
        hours_skill_bp: struct { elite: types.Bp, veteran: types.Bp, regular: types.Bp, green: types.Bp, untrained: types.Bp },
    },
    /// Dragoons rating (CamOps "Mercenary Rating", MekHQ
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
        /// What the letter buys on the board: pay multiplier per
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
        /// Reputation on completion: 1 + VP / `rep_vp_per_point`, the VP part clamped to [min, max]; a tour in the red earns only the (negative) VP part.
        rep_vp_per_point: i32,
        rep_vp_bonus_min: i32,
        rep_vp_bonus_max: i32,
        /// Standing gained with the employer: base + VP / this.
        standing_vp_divisor: i32,
        /// Offer terms rolled on the board (CamOps contract generation).
        advance_pct: u8,
        signing_bonus_target: u8,
        signing_bonus_divisor: types.CBills,
        transport_pct_per_pip: u8,
        /// Straight support: 2d6 at or over each line pays that share.
        overhead_quarter_at: u8,
        overhead_half_at: u8,
        overhead_full_at: u8,
        battle_loss_target: u8,
        battle_loss_pct: u8,
        salvage_pct_per_pip: u8,
        /// Enemy strength relative to the committed force by kind (bp), and
        /// how the attrition pool grows with length.
        enemy_strength_bp: struct { garrison_duty: types.Bp, cadre_duty: types.Bp, security_duty: types.Bp, riot_duty: types.Bp, planetary_assault: types.Bp, relief_duty: types.Bp, guerrilla_warfare: types.Bp, pirate_hunting: types.Bp, diversionary_raid: types.Bp, objective_raid: types.Bp, recon_raid: types.Bp, extraction_raid: types.Bp },
        pool_per_month_divisor: types.Bp,
        pool_months_cap: u8,
        /// Victory points per point of contract score.
        vp_per_score: i32,
        /// Grade thresholds on victory points: outstanding, strong.
        grade_outstanding_vp: i32,
        grade_strong_vp: i32,
        /// Attrition objective met at this share of the enemy pool destroyed.
        attrition_met_pct: u32,
        /// Combat effectiveness (ARCH §7): below `effective_min_pct` of the
        /// committed BV the company is ineffective; below `effective_warn_pct`
        /// the screens go amber.
        effective_min_pct: u32,
        effective_warn_pct: u32,
        grace_days: u32,
        cooling_days: u32,
        decision_window_days: u32,
        /// Personnel notices (raise, bonus, replace, let go) get a longer
        /// window than contract events, so a week's skip does not expire
        /// one before the inbox is read.
        notice_window_days: u32,
        /// Faction standing, −100…100 per house: what a
        /// completed tour earns the employer, what fighting a house costs
        /// with them, what a breach costs, the pay swing per point (bp),
        /// the line under which a house shuns you (half its offers, like
        /// cooling), and the monthly drift back toward neutral.
        standing_complete_gain: i32,
        standing_enemy_loss: i32,
        standing_breach_loss: i32,
        /// A performance failure at term (CamOps): what it costs with
        /// the employer and in reputation. No clawback, no cooling.
        standing_failure_loss: i32,
        failure_reputation: i32,
        /// Jump-point interdiction: weekly, a company in transit
        /// without its own crewed DropShip meets raiders on 2d6 ≥ this.
        interdiction_target: u8,
        /// Threat pay: an offer's pay scales with its opposition's
        /// power against the kind's norm (the midpoint lance count of
        /// `reference_lance_bv` at regular skill) — by `threat_pay_weight_bp`
        /// of the difference, capped at ±`threat_pay_cap_bp`.
        reference_lance_bv: i64,
        threat_pay_weight_bp: types.Bp,
        threat_pay_cap_bp: types.Bp,
        standing_pay_bp_per_point: types.Bp,
        /// Shunned when standing is at or under −this.
        standing_shun_depth: i32,
        standing_drift_per_month: i32,
        /// Chance a contract rolls on the weekly deck at all (bp).
        weekly_event_chance_bp: types.Bp,
        /// A weekly decision of one kind waits this many days before it can
        /// come up again.
        weekly_decision_cooldown_days: u32,
        /// After this many identical answers in a row the answer becomes a
        /// standing order, applied without asking (`sop clear <event>` resets).
        standing_order_after: u8,
        /// Command rights (AtB/CamOps): what the employer's grip on
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
        /// Salvage exchange (CamOps): the employer keeps the wrecks
        /// and pays the claim in cash at this share of BV value, at this
        /// many C-bills per BV. Rolled on one offer in `salvage_exchange_in`.
        salvage_exchange_bp: types.Bp,
        salvage_cbills_per_bv: types.CBills,
        salvage_exchange_in: u32,
        /// Negotiation (CamOps): 2d6 + the rating edge
        /// + the command office's skill edge vs `negotiation_target` −
        /// standing/`negotiation_standing_per`; a miss hardens the pay by
        /// `negotiation_fail_pay_bp`; a natural 2 withdraws the offer.
        negotiation_target: i32,
        negotiation_standing_per: i32,
        negotiation_fail_pay_bp: types.Bp,
        negotiation_pay_step_bp: types.Bp,
        /// Prisoners: captured per battle when a security lance holds
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
        /// RAT weight-class roll (2d6): up to `light_max` light, `medium_max` medium, `heavy_max` heavy, else assault.
        weight_light_max: u8,
        weight_medium_max: u8,
        weight_heavy_max: u8,
        /// Support staff ratios: one doctor per this many combat
        /// crew, astechs per tech, medics per doctor, one admin per this
        /// many combat crew, and never fewer admins than the office needs.
        crew_per_doctor: u32,
        astechs_per_tech: u32,
        medics_per_doctor: u32,
        crew_per_admin: u32,
        admins_min: u32,
        scout_max_tonnage: u8,
        starter_provisions: u32,
        starter_medical: u32,
        starter_armor: u32,
        starter_components_each: u32,
        starter_munitions_each: u32,
        /// Keep-stocked provisions line at the starter HQ (min / target tons).
        provisions_keep_min: u32,
        provisions_keep_target: u32,
        /// Starter line lances: 2d6 at or under this is a light
        /// mek, anything higher a medium — no heavies or assaults the
        /// founding level-1 mek bay could not rebuild.
        starter_light_max: u8,
    },
    /// Real loss: how hulls die, what a rebuild needs, and when
    /// one is not worth it.
    loss: struct {
        /// An engine kill or an ammunition explosion is scrap on 2d6 at or
        /// under this (+ the difficulty's `scrap_mod`).
        scrap_target: i32,
        /// Bay days a new engine adds to a rebuild.
        engine_rebuild_days: u32,
        /// A rebuild costing more than this share of a new hull is flagged
        /// "beyond economical repair" (it can still be done).
        writeoff_bp: types.Bp,
        /// Who holds the field keeps the wrecks (CamOps salvage). On
        /// a lost field each hull wrecked there is recovered on 2d6 + mods ≥
        /// this, else the enemy has it. Mods: a crewed salvage lance, enough
        /// SVT-1 trucks for the wrecks, an own DropShip on-world, a rout,
        /// the scenario's `recovery_mod` and the difficulty's.
        recovery_target: i32,
        recovery_salvage_lance: i32,
        recovery_trucks: i32,
        recovery_dropship: i32,
        recovery_rout: i32,
        /// The pilot of a hull left behind walks out on 2d6 + (5 − piloting)
        /// + the difficulty's recovery mod (+ the rout penalty) ≥ this;
        /// otherwise they are missing, held by the enemy (ransom, trade, or
        /// written off in the inbox).
        escape_target: i32,
        /// Company morale when a missing pilot is written off.
        mia_morale: i32,
        /// Rules of engagement: roll shift, the share of engaged
        /// hulls hit on a lost fight (percentage points), the recovery
        /// roll, and the extra morale a lost stand costs.
        roe: struct {
            hold_roll: i32,
            cautious_roll: i32,
            hold_hits_pct: i32,
            cautious_hits_pct: i32,
            hold_recovery: i32,
            cautious_recovery: i32,
            hold_morale: i32,
            /// Score a cautious withdrawal from a draw costs.
            withdrawal_score: i32,
        },
        /// Go back for the downed: a night sortie onto ground the
        /// enemy now holds. Each hull left and each pilot held gets one
        /// more roll, at `push_mod` to the target that failed the first
        /// time. The company pays for the night in fatigue; a sortie that
        /// rolls at or under `push_mishap_at` costs someone a wound.
        /// Bringing anyone home is worth `push_morale` to the company.
        push_mod: i32, // TUNE
        push_fatigue: u8, // TUNE
        push_mishap_at: i32, // TUNE
        push_morale: i8, // TUNE
    },
    /// Autoresolve power modifiers (ARCH §7, basis points on base strength).
    autoresolve: struct {
        /// Each point of gunnery under 4 is worth this; over 4 costs this.
        gunnery_below_bp: types.Bp,
        gunnery_above_bp: types.Bp,
        piloting_bp: types.Bp,
        /// Per step of maintenance quality modifier (A is +3, F −2).
        quality_step_bp: types.Bp,
        no_ammo_bp: types.Bp,
        no_parts_bp: types.Bp,
        no_provisions_bp: types.Bp,
        /// Scaled by average fatigue over 100, and by (morale − 50) over 50.
        fatigue_scale_bp: types.Bp,
        morale_scale_bp: types.Bp,
        air_cover_bp: types.Bp,
        artillery_bp: types.Bp,
        recon_per_level_bp: types.Bp,
        support_lance_bp: types.Bp,
    },
    /// Component fabrication and provisions (domain/part.zig).
    part: struct {
        /// Bay days per component location; other keys take `other`.
        fab_days: struct { ct: u32, torso: u32, leg: u32, arm: u32, head: u32, other: u32 },
        /// Days added by weight class (light is quicker).
        fab_class_delta: struct { light: i32, heavy: i32, assault: i32 },
        /// One ton of provisions feeds this many person-days.
        provisions_person_days_per_ton: u32,
    },
    /// Force shape constants not fixed by ARCH §9.3.
    force: struct {
        max_air_lances: u8,
    },
    commander: struct { bonus_bp: types.Bp },
};

/// The live table.
pub const t: Tuning = @import("tuning_zon");

fn expectTuningSane(comptime T: type, value: T, comptime name: []const u8) !void {
    switch (@typeInfo(T)) {
        .int => |info| {
            // Signed knobs (deltas, scores) may be zero or negative by design.
            if (info.signedness == .signed) return;
            // Slot and desk tables hold real zeros (a field HQ has no air wing).
            if (std.mem.indexOf(u8, name, ".staff_base.") != null or std.mem.indexOf(u8, name, ".capacity_") != null) return;
            if (value <= 0) {
                std.debug.print("tuning field {s} must be positive\n", .{name});
                return error.BadTuning;
            }
            if (std.mem.endsWith(u8, name, "_bp") and value > 100_000) {
                std.debug.print("tuning field {s} is over 100000 basis points\n", .{name});
                return error.BadTuning;
            }
        },
        .@"struct" => |info| inline for (info.fields) |f| try expectTuningSane(f.type, @field(value, f.name), name ++ "." ++ f.name),
        else => {},
    }
}

test "every tuning value is positive and every basis-point knob is sane" {
    try expectTuningSane(Tuning, t, "t");
}

test "spot checks against the values the formulas were built on" {
    try std.testing.expectEqual(@as(u32, 60), t.hq.influence_ly.regional);
    try std.testing.expectEqual(@as(u32, 6), t.battle.mounts_per_ammo_ton);
    try std.testing.expectEqual(@as(types.Bp, 1_200), t.finance.loan_rate_bp);
    try std.testing.expectEqual(@as(types.CBills, 2_000), t.logistics.freight_per_ly);
}
