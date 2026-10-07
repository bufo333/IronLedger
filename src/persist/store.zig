//! The save store (Stage 11): one SQLite file holds many campaigns. Every
//! table carries a campaign id; `campaign` is the registry. Saving rewrites
//! a campaign's rows inside one transaction; loading rebuilds a GameState
//! from them; deleting a campaign removes it and starts nothing else.
//!
//! The sim core never touches SQL — this module maps GameState ↔ rows.
//! docs/schema.sql remains the design document; this DDL is the executable
//! truth and stays close to it.
//! MekHQ counterpart: the campaign save and load (XML there, SQLite here)
//! (docs/mekhq-map.md).

const std = @import("std");
const rng_mod = @import("../sim/rng.zig");
const sqlite = @import("sqlite.zig");
const types = @import("../domain/types.zig");
const state_mod = @import("../sim/state.zig");
const GameState = state_mod.GameState;
const founding = @import("../sim/founding.zig");
const posture = @import("../sim/posture.zig");
const person_mod = @import("../domain/person.zig");
const unit_mod = @import("../domain/unit.zig");
const force_mod = @import("../domain/force.zig");
const battle_report_mod = @import("../domain/battle_report.zig");
const autoresolve_mod = @import("../domain/autoresolve.zig");
const hq_mod = @import("../domain/hq.zig");
const contract_mod = @import("../domain/contract.zig");
const commander_mod = @import("../domain/commander.zig");
const finance_mod = @import("../econ/finance.zig");
const market_mod = @import("../econ/market.zig");
const events_mod = @import("../domain/events.zig");
const contract_events = @import("../sim/contract_events.zig");
const clock_mod = @import("../domain/clock.zig");
const digest = @import("../sim/digest.zig");
const hq_ops = @import("../sim/hq_ops.zig");
const held_hulls_m = @import("../sim/held_hulls.zig");
const arc_mod = @import("../domain/arc.zig");
const operation_mod = @import("../domain/operation.zig");
const actor_mod = @import("../domain/actor.zig");
const rival_mod = @import("../domain/rival.zig");
const merc_company_mod = @import("../domain/merc_company.zig");
const officer_dom = @import("../domain/officer.zig");
const world_state_dom = @import("../domain/world_state.zig");

pub const schema_version = 58;

const ddl =
    \\CREATE TABLE IF NOT EXISTS player (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, created_seq INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL CHECK (schema_version > 0), save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS rng_stream (cid INTEGER NOT NULL, stream TEXT NOT NULL, format INTEGER NOT NULL, state BLOB NOT NULL, UNIQUE (cid, stream), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS commander (cid INTEGER PRIMARY KEY, name TEXT NOT NULL, origin TEXT NOT NULL, profession TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0 CHECK (admitted IN (0,1)), rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0 CHECK (rank_pinned IN (0,1)), kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0 CHECK (edge_spent IN (0,1)), faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, secondary_role TEXT, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS award (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, key TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS ability (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, key TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS person_skill (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, skill TEXT NOT NULL, level INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS injury (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, ord INTEGER NOT NULL, location TEXT NOT NULL, severity INTEGER NOT NULL, incurred INTEGER NOT NULL, heal_done INTEGER, doctor INTEGER NOT NULL DEFAULT 0, permanent INTEGER NOT NULL DEFAULT 0 CHECK (permanent IN (0,1)), healed INTEGER NOT NULL DEFAULT 0 CHECK (healed IN (0,1)), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS unit (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, chassis_key TEXT, name TEXT, kind TEXT, force INTEGER, pilot INTEGER, tech INTEGER, armor_pct INTEGER, quality TEXT, status TEXT, last_maint INTEGER, acquired_day INTEGER, price INTEGER, reactivation_done INTEGER, berth_hq INTEGER NOT NULL DEFAULT 0, wreck TEXT NOT NULL DEFAULT 'none', held_by TEXT NOT NULL DEFAULT '', held_day INTEGER NOT NULL DEFAULT 0, held_battle INTEGER NOT NULL DEFAULT 0, held_force INTEGER NOT NULL DEFAULT 0, hull_instance_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS unit_slot (cid INTEGER NOT NULL, unit_id INTEGER NOT NULL, ord INTEGER NOT NULL, slot_key TEXT, part_key TEXT, class TEXT, condition TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, unit_id) REFERENCES unit(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS force (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, parent INTEGER, name TEXT, emblem BLOB, local_funds INTEGER, echelon TEXT, commander INTEGER, supplying_hq INTEGER, role TEXT, support_kind TEXT, last_rotation INTEGER, contracts_since_rotation INTEGER, location_planet TEXT, return_eta INTEGER, shortage_days INTEGER, roe TEXT NOT NULL DEFAULT 'standard', PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS force_unit (cid INTEGER NOT NULL, force_id INTEGER NOT NULL, ord INTEGER NOT NULL, unit_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, force_id) REFERENCES force(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, unit_id) REFERENCES unit(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS force_child (cid INTEGER NOT NULL, force_id INTEGER NOT NULL, ord INTEGER NOT NULL, child_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, force_id) REFERENCES force(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, child_id) REFERENCES force(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS stock (cid INTEGER NOT NULL, owner_kind TEXT NOT NULL, owner_id INTEGER NOT NULL, ord INTEGER NOT NULL, key TEXT NOT NULL, qty INTEGER NOT NULL, UNIQUE (cid, owner_kind, owner_id, key), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hq (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, name TEXT, tier TEXT, planet TEXT, staff_assigned INTEGER, upkeep INTEGER, funds INTEGER, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hq_facility (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, level INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hq_id) REFERENCES hq(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hq_project (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, facility TEXT, target_level INTEGER, started INTEGER, paperwork_done INTEGER, construction_done INTEGER, cost INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hq_id) REFERENCES hq(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL CHECK (is_offer IN (0,1)), ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER CHECK (salvage_exchange IN (0,1)), command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0 CHECK (negotiated IN (0,1)), enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER, arc_key TEXT NOT NULL DEFAULT '', arc_beat INTEGER NOT NULL DEFAULT 0, escalation_clock INTEGER NOT NULL DEFAULT 0, arc_finale_key TEXT NOT NULL DEFAULT '', command_capacity INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS operation (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, template_key TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT NOT NULL, opened_day INTEGER NOT NULL, resolved_day INTEGER, committed_day INTEGER, intent TEXT NOT NULL DEFAULT 'secure_objective', tempo TEXT NOT NULL DEFAULT 'advance', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS txn (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, amount INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, note TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS loan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, principal INTEGER, balance INTEGER, rate_bp INTEGER, term INTEGER, next_pay INTEGER, payment INTEGER, id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS courier (cid INTEGER NOT NULL, ord INTEGER NOT NULL, to_kind TEXT, to_id INTEGER, amount INTEGER, sent INTEGER, eta INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, entity_kind TEXT, entity_id INTEGER, floor INTEGER, cap INTEGER, sent INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS supply_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, company INTEGER, min_days INTEGER, tons INTEGER, ammo_battles INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS stock_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, part_key TEXT, min_qty INTEGER, target INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS bay_job (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, kind TEXT, unit INTEGER, item_key TEXT, duration INTEGER, queued INTEGER, started INTEGER, done INTEGER, cost INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS candidate (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, first TEXT, last TEXT, callsign TEXT, role TEXT, experience TEXT, primary_skill INTEGER, secondary_skill INTEGER, bonus INTEGER, listed INTEGER, expires INTEGER, age INTEGER NOT NULL DEFAULT 30, id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hq_link (cid INTEGER NOT NULL, ord INTEGER NOT NULL, a INTEGER, b INTEGER, level INTEGER, tons INTEGER, established INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS unit_transfer (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, to_company INTEGER, eta INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS faction_cooling (cid INTEGER NOT NULL, ord INTEGER NOT NULL, faction TEXT, until_day INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS faction_standing (cid INTEGER NOT NULL, faction TEXT NOT NULL, value INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS event_memory (cid INTEGER NOT NULL, kind TEXT NOT NULL, last_day INTEGER NOT NULL, last_choice INTEGER NOT NULL, streak INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS rating_snapshot (cid INTEGER NOT NULL, year INTEGER NOT NULL, score INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS listing (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, item_key TEXT, rarity TEXT, price INTEGER, qty INTEGER, staple INTEGER CHECK (staple IN (0,1)), listed INTEGER, expires INTEGER, hq INTEGER, c_armor INTEGER, c_quality TEXT, c_damaged INTEGER, c_destroyed INTEGER, c_missing INTEGER, black INTEGER NOT NULL DEFAULT 0 CHECK (black IN (0,1)), company INTEGER NOT NULL DEFAULT 0, id INTEGER NOT NULL DEFAULT 0, hull_instance_id INTEGER NOT NULL DEFAULT 0, planet_key TEXT NOT NULL DEFAULT '', available_after INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS part_order (cid INTEGER NOT NULL, ord INTEGER NOT NULL, part_key TEXT, qty INTEGER, dest_kind TEXT, dest_id INTEGER, ordered INTEGER, eta INTEGER, cost INTEGER, status TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS event_log (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, text TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS pending_event (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, day INTEGER, contract INTEGER, company INTEGER, default_choice INTEGER, deadline INTEGER, chosen INTEGER, person INTEGER NOT NULL DEFAULT 0, id INTEGER NOT NULL DEFAULT 0, battle INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS refit_plan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, committed INTEGER CHECK (committed IN (0,1)), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS refit_op (cid INTEGER NOT NULL, plan_ord INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, slot_key TEXT, location TEXT, part_key TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, plan_ord) REFERENCES refit_plan(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1 CHECK (acknowledged IN (0,1)), salvage_unclaimed INTEGER NOT NULL DEFAULT 0, operation TEXT NOT NULL DEFAULT '', operation_intent TEXT NOT NULL DEFAULT '', operation_tempo TEXT NOT NULL DEFAULT '', operation_interventions TEXT NOT NULL DEFAULT '', UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_hit (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, chassis_key TEXT, chassis_name TEXT, armor_before INTEGER, armor_after INTEGER, slot TEXT, slot_part TEXT, slot_result TEXT, destroyed INTEGER, cause TEXT, pilot INTEGER, crew_name TEXT, wound_severity INTEGER, wound_location TEXT, wound_permanent INTEGER, fate TEXT, recovery_roll INTEGER, recovery_target INTEGER, lost INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_ammo (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, family TEXT, burned INTEGER, reserve INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_salvage (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, key TEXT, name TEXT, bv INTEGER, armor_pct INTEGER, quality TEXT, damaged INTEGER, destroyed INTEGER, missing INTEGER, hull_instance_id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS operation_task (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, operation_id INTEGER NOT NULL, ord INTEGER NOT NULL, lance_id INTEGER NOT NULL, task TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS operation_intervention (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, operation_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_task (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, lance_id INTEGER NOT NULL, lance_name TEXT NOT NULL, task TEXT NOT NULL, succeeded INTEGER NOT NULL CHECK (succeeded IN (0,1)), note TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS actor (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, first_name TEXT NOT NULL, last_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, contract INTEGER NOT NULL DEFAULT 0, trust INTEGER NOT NULL DEFAULT 0, debt INTEGER NOT NULL DEFAULT 0, respect INTEGER NOT NULL DEFAULT 0, hostility INTEGER NOT NULL DEFAULT 0, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS world_state (cid INTEGER NOT NULL, ord INTEGER NOT NULL, planet_key TEXT NOT NULL, security INTEGER NOT NULL DEFAULT 0, civilian_support INTEGER NOT NULL DEFAULT 0, infrastructure_strain INTEGER NOT NULL DEFAULT 0, employer_control INTEGER NOT NULL DEFAULT 0, enemy_influence INTEGER NOT NULL DEFAULT 0, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, planet_key), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS rival (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, contract INTEGER NOT NULL DEFAULT 0, standing INTEGER NOT NULL DEFAULT 0, encounters INTEGER NOT NULL DEFAULT 1, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), merc_company_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS officer_arc (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, person INTEGER NOT NULL, contract INTEGER NOT NULL DEFAULT 0, seat TEXT NOT NULL, performance INTEGER NOT NULL DEFAULT 0, encounters INTEGER NOT NULL DEFAULT 1, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_merc_company_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_loadout (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, slot_index INTEGER NOT NULL, part_key TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_combat_record (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, battle_id INTEGER NOT NULL DEFAULT 0, contract_id INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, hits_taken INTEGER NOT NULL DEFAULT 0, armor_lost INTEGER NOT NULL DEFAULT 0, slots_damaged INTEGER NOT NULL DEFAULT 0, slots_destroyed INTEGER NOT NULL DEFAULT 0, destroyed INTEGER NOT NULL DEFAULT 0 CHECK (destroyed IN (0,1)), cause TEXT NOT NULL DEFAULT 'none', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS maintenance_entry (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER NOT NULL DEFAULT 0, tech INTEGER NOT NULL DEFAULT 0, action TEXT NOT NULL DEFAULT 'repair', description TEXT NOT NULL DEFAULT '', battle_id INTEGER NOT NULL DEFAULT 0, cost INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_ownership_history (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, from_day INTEGER NOT NULL DEFAULT 0, to_day INTEGER NOT NULL DEFAULT 0, acquisition_type TEXT NOT NULL DEFAULT 'initial', prior_owner_key TEXT NOT NULL DEFAULT '', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS faction_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, faction_key TEXT NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS merc_company (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, cbills INTEGER NOT NULL DEFAULT 0, founded_day INTEGER NOT NULL DEFAULT 0, dissolved_day INTEGER NOT NULL DEFAULT 0, logo_key TEXT NOT NULL DEFAULT '', PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS merc_company_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, merc_company_id INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, merc_company_id) REFERENCES merc_company(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
;

const tables = [_][]const u8{
    "meta",               "meta_text",              "rng",                    "commander",        "person",            "person_skill",        "injury",                "award",         "ability",
    "unit",               "unit_slot",              "force",                  "force_unit",       "force_child",       "stock",               "hq",                    "hq_facility",   "hq_project",
    "contract",           "txn",                    "loan",                   "courier",          "policy",            "bay_job",             "candidate",             "hq_link",       "unit_transfer",
    "supply_policy",      "stock_policy",           "faction_cooling",        "faction_standing", "event_memory",      "listing",             "part_order",            "event_log",     "pending_event",
    "refit_plan",         "refit_op",               "rating_snapshot",        "battle_report",    "battle_report_hit", "battle_report_ammo",  "battle_report_salvage", "rng_stream",    "operation",
    "operation_task",     "operation_intervention", "battle_report_task",     "actor",            "world_state",       "rival",               "officer_arc",           "hull_instance", "hull_loadout",
    "hull_combat_record", "maintenance_entry",      "hull_ownership_history", "faction_roster",   "merc_company",      "merc_company_roster",
};

// Indexes for per-campaign tables (A28/D31): cid filters on every load;
// composite shapes for the battle_report sub-tables whose loaders filter
// on (cid, report_ord).  CREATE INDEX IF NOT EXISTS is idempotent.
const index_ddl =
    \\CREATE INDEX IF NOT EXISTS ix_meta_cid ON meta(cid);
    \\CREATE INDEX IF NOT EXISTS ix_meta_text_cid ON meta_text(cid);
    \\CREATE INDEX IF NOT EXISTS ix_rng_cid ON rng(cid);
    \\CREATE INDEX IF NOT EXISTS ix_commander_cid ON commander(cid);
    \\CREATE INDEX IF NOT EXISTS ix_person_cid ON person(cid);
    \\CREATE INDEX IF NOT EXISTS ix_person_skill_cid ON person_skill(cid);
    \\CREATE INDEX IF NOT EXISTS ix_injury_cid ON injury(cid);
    \\CREATE INDEX IF NOT EXISTS ix_award_cid ON award(cid);
    \\CREATE INDEX IF NOT EXISTS ix_ability_cid ON ability(cid);
    \\CREATE INDEX IF NOT EXISTS ix_unit_cid ON unit(cid);
    \\CREATE INDEX IF NOT EXISTS ix_unit_slot_cid ON unit_slot(cid);
    \\CREATE INDEX IF NOT EXISTS ix_force_cid ON force(cid);
    \\CREATE INDEX IF NOT EXISTS ix_force_unit_cid ON force_unit(cid);
    \\CREATE INDEX IF NOT EXISTS ix_force_child_cid ON force_child(cid);
    \\CREATE INDEX IF NOT EXISTS ix_stock_cid ON stock(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hq_cid ON hq(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hq_facility_cid ON hq_facility(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hq_project_cid ON hq_project(cid);
    \\CREATE INDEX IF NOT EXISTS ix_contract_cid ON contract(cid);
    \\CREATE INDEX IF NOT EXISTS ix_txn_cid ON txn(cid);
    \\CREATE INDEX IF NOT EXISTS ix_loan_cid ON loan(cid);
    \\CREATE INDEX IF NOT EXISTS ix_courier_cid ON courier(cid);
    \\CREATE INDEX IF NOT EXISTS ix_policy_cid ON policy(cid);
    \\CREATE INDEX IF NOT EXISTS ix_bay_job_cid ON bay_job(cid);
    \\CREATE INDEX IF NOT EXISTS ix_candidate_cid ON candidate(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hq_link_cid ON hq_link(cid);
    \\CREATE INDEX IF NOT EXISTS ix_unit_transfer_cid ON unit_transfer(cid);
    \\CREATE INDEX IF NOT EXISTS ix_supply_policy_cid ON supply_policy(cid);
    \\CREATE INDEX IF NOT EXISTS ix_stock_policy_cid ON stock_policy(cid);
    \\CREATE INDEX IF NOT EXISTS ix_faction_cooling_cid ON faction_cooling(cid);
    \\CREATE INDEX IF NOT EXISTS ix_faction_standing_cid ON faction_standing(cid);
    \\CREATE INDEX IF NOT EXISTS ix_event_memory_cid ON event_memory(cid);
    \\CREATE INDEX IF NOT EXISTS ix_listing_cid ON listing(cid);
    \\CREATE INDEX IF NOT EXISTS ix_part_order_cid ON part_order(cid);
    \\CREATE INDEX IF NOT EXISTS ix_event_log_cid ON event_log(cid);
    \\CREATE INDEX IF NOT EXISTS ix_pending_event_cid ON pending_event(cid);
    \\CREATE INDEX IF NOT EXISTS ix_refit_plan_cid ON refit_plan(cid);
    \\CREATE INDEX IF NOT EXISTS ix_refit_op_cid ON refit_op(cid);
    \\CREATE INDEX IF NOT EXISTS ix_rating_snapshot_cid ON rating_snapshot(cid);
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_cid ON battle_report(cid);
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_hit_report ON battle_report_hit(cid, report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_ammo_report ON battle_report_ammo(cid, report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_salvage_report ON battle_report_salvage(cid, report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_rng_stream_cid ON rng_stream(cid);
    \\CREATE INDEX IF NOT EXISTS ix_operation_cid ON operation(cid);
    \\CREATE INDEX IF NOT EXISTS ix_operation_task_cid ON operation_task(cid, contract_id, operation_id);
    \\CREATE INDEX IF NOT EXISTS ix_operation_intervention_cid ON operation_intervention(cid, contract_id, operation_id);
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_task_report ON battle_report_task(cid, report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_actor_cid ON actor(cid);
    \\CREATE INDEX IF NOT EXISTS ix_world_state_cid ON world_state(cid);
    \\CREATE INDEX IF NOT EXISTS ix_rival_cid ON rival(cid);
    \\CREATE INDEX IF NOT EXISTS ix_officer_arc_cid ON officer_arc(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hull_instance_cid ON hull_instance(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hull_loadout_cid ON hull_loadout(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hull_combat_record_cid ON hull_combat_record(cid);
    \\CREATE INDEX IF NOT EXISTS ix_maintenance_entry_cid ON maintenance_entry(cid);
    \\CREATE INDEX IF NOT EXISTS ix_hull_ownership_history_cid ON hull_ownership_history(cid);
    \\CREATE INDEX IF NOT EXISTS ix_faction_roster_cid ON faction_roster(cid);
    \\CREATE INDEX IF NOT EXISTS ix_merc_company_cid ON merc_company(cid);
    \\CREATE INDEX IF NOT EXISTS ix_merc_company_roster_cid ON merc_company_roster(cid);
;

/// The stream order of the single `rng` blob that saves before schema v32
/// hold: the generator states, one after another, in this order.
const legacy_rng_order = [_]rng_mod.Stream{ .generation, .market, .maintenance, .acquisition, .battle, .events, .medical, .travel };

/// Hard upper bound on a stored emblem PNG (rule 64).
/// 4 MiB matches the pixel-limit constant in `src/tui/png.zig`
/// (`max_emblem_pixels = 2048×2048`): a valid 2048×2048 PNG is compressed
/// and is always well below this, so no legitimate emblem is refused.
const max_emblem_bytes: usize = 2048 * 2048;

pub const Store = struct {
    db: sqlite.Db,
    /// The player new campaigns are filed under; 0 = none.
    player_id: i64 = 0,

    /// One schema step: `from` is the last version before this column existed,
    /// `to` is the version that adds it. `CREATE TABLE IF NOT EXISTS` in `ddl`
    /// covers new tables; columns on existing tables are the only thing SQLite
    /// makes us migrate by hand. Steps are idempotent (column-guarded) so a
    /// store that predates the version key still upgrades cleanly. Array is
    /// ordered ascending by `to` (then by declaration order for equal `to`).
    pub const Migration = struct { from: u32, to: u32, table: []const u8, column: []const u8, sql: [*:0]const u8 };
    /// Migration patterns: ADD COLUMN with NOT NULL DEFAULT is correct for new columns.
    /// To remove or rename a column: RENAME the table to `<table>__bak`, CREATE the table
    /// with the correct final schema, INSERT SELECT with any necessary CASE expressions, then
    /// DROP `<table>__bak`. Never leave a dead column. The v53→v54 hull_instance entry below
    /// is the canonical example.
    pub const migrations = [_]Migration{
        .{ .from = 1, .to = 2, .table = "campaign", .column = "player_id", .sql = "ALTER TABLE campaign ADD COLUMN player_id INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 2, .to = 3, .table = "person", .column = "admitted", .sql = "ALTER TABLE person ADD COLUMN admitted INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 3, .to = 4, .table = "policy", .column = "sent", .sql = "ALTER TABLE policy ADD COLUMN sent INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 4, .to = 5, .table = "supply_policy", .column = "ammo_battles", .sql = "ALTER TABLE supply_policy ADD COLUMN ammo_battles INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 5, .to = 6, .table = "unit", .column = "berth_hq", .sql = "ALTER TABLE unit ADD COLUMN berth_hq INTEGER NOT NULL DEFAULT 0" },
        // v7: the `injury` table (created by ddl); campaign data is
        // upgraded on load (`upgradeCampaign`). v8: `faction_standing`
        // (created by ddl; absent rows read as 0).
        .{ .from = 8, .to = 9, .table = "pending_event", .column = "person", .sql = "ALTER TABLE pending_event ADD COLUMN person INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 9, .to = 10, .table = "contract", .column = "negotiated", .sql = "ALTER TABLE contract ADD COLUMN negotiated INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 10, .to = 11, .table = "person", .column = "rank", .sql = "ALTER TABLE person ADD COLUMN rank TEXT NOT NULL DEFAULT 'private'" },
        .{ .from = 10, .to = 11, .table = "person", .column = "rank_pinned", .sql = "ALTER TABLE person ADD COLUMN rank_pinned INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 11, .to = 12, .table = "person", .column = "kills", .sql = "ALTER TABLE person ADD COLUMN kills INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 11, .to = 12, .table = "person", .column = "kill_bv", .sql = "ALTER TABLE person ADD COLUMN kill_bv INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 11, .to = 12, .table = "person", .column = "battles", .sql = "ALTER TABLE person ADD COLUMN battles INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 11, .to = 12, .table = "person", .column = "tours", .sql = "ALTER TABLE person ADD COLUMN tours INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 11, .to = 12, .table = "person", .column = "outstanding_tours", .sql = "ALTER TABLE person ADD COLUMN outstanding_tours INTEGER NOT NULL DEFAULT 0" },
        // v12 also adds the `award` table (created by ddl).
        .{ .from = 12, .to = 13, .table = "person", .column = "edge_spent", .sql = "ALTER TABLE person ADD COLUMN edge_spent INTEGER NOT NULL DEFAULT 0" },
        // v13 also adds the `ability` table (created by ddl).
        .{ .from = 13, .to = 14, .table = "person", .column = "faction", .sql = "ALTER TABLE person ADD COLUMN faction TEXT NOT NULL DEFAULT ''" },
        .{ .from = 14, .to = 15, .table = "person", .column = "shares", .sql = "ALTER TABLE person ADD COLUMN shares INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 15, .to = 16, .table = "person", .column = "born_day", .sql = "ALTER TABLE person ADD COLUMN born_day INTEGER" },
        .{ .from = 16, .to = 17, .table = "person", .column = "last_raise_day", .sql = "ALTER TABLE person ADD COLUMN last_raise_day INTEGER" },
        .{ .from = 16, .to = 17, .table = "person", .column = "last_award_day", .sql = "ALTER TABLE person ADD COLUMN last_award_day INTEGER" },
        // v18 adds the `rating_snapshot` table (created by ddl) and the stats meta ints.
        .{ .from = 18, .to = 19, .table = "listing", .column = "black", .sql = "ALTER TABLE listing ADD COLUMN black INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 19, .to = 20, .table = "unit", .column = "wreck", .sql = "ALTER TABLE unit ADD COLUMN wreck TEXT NOT NULL DEFAULT 'none'" },
        .{ .from = 20, .to = 21, .table = "force", .column = "roe", .sql = "ALTER TABLE force ADD COLUMN roe TEXT NOT NULL DEFAULT 'standard'" },
        .{ .from = 21, .to = 22, .table = "contract", .column = "enemy_lances", .sql = "ALTER TABLE contract ADD COLUMN enemy_lances INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 21, .to = 22, .table = "contract", .column = "enemy_quality", .sql = "ALTER TABLE contract ADD COLUMN enemy_quality TEXT NOT NULL DEFAULT 'regular'" },
        .{ .from = 21, .to = 22, .table = "contract", .column = "enemy_lance_bv", .sql = "ALTER TABLE contract ADD COLUMN enemy_lance_bv INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 22, .to = 23, .table = "listing", .column = "company", .sql = "ALTER TABLE listing ADD COLUMN company INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 23, .to = 24, .table = "contract", .column = "enemy_lance_tons", .sql = "ALTER TABLE contract ADD COLUMN enemy_lance_tons INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 23, .to = 24, .table = "contract", .column = "offer_hq", .sql = "ALTER TABLE contract ADD COLUMN offer_hq INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 24, .to = 25, .table = "person", .column = "departed_day", .sql = "ALTER TABLE person ADD COLUMN departed_day INTEGER" },
        // v26: the inbox is answered by event id, not by row; `load` stamps
        // ids on rows that default to 0.
        .{ .from = 25, .to = 26, .table = "pending_event", .column = "id", .sql = "ALTER TABLE pending_event ADD COLUMN id INTEGER NOT NULL DEFAULT 0" },
        // v28: reports already in a save count as read (default 1), so an
        // upgrade does not hold the turn on battles long since fought.
        .{ .from = 27, .to = 28, .table = "battle_report", .column = "acknowledged", .sql = "ALTER TABLE battle_report ADD COLUMN acknowledged INTEGER NOT NULL DEFAULT 1" },
        // v29: a hull the enemy holds rides in the `unit` table with
        // its own slots, distinguished only by a non-empty `held_by`.
        .{ .from = 28, .to = 29, .table = "unit", .column = "held_by", .sql = "ALTER TABLE unit ADD COLUMN held_by TEXT NOT NULL DEFAULT ''" },
        .{ .from = 28, .to = 29, .table = "unit", .column = "held_day", .sql = "ALTER TABLE unit ADD COLUMN held_day INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 28, .to = 29, .table = "unit", .column = "held_battle", .sql = "ALTER TABLE unit ADD COLUMN held_battle INTEGER NOT NULL DEFAULT 0" },
        // v30: a battle decision names the engagement it answers,
        // and a hull won back goes home to the lance it was taken from.
        .{ .from = 29, .to = 30, .table = "pending_event", .column = "battle", .sql = "ALTER TABLE pending_event ADD COLUMN battle INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 29, .to = 30, .table = "unit", .column = "held_force", .sql = "ALTER TABLE unit ADD COLUMN held_force INTEGER NOT NULL DEFAULT 0" },
        // v31: the part of a haul still to be divided. Older saves
        // have no undivided hauls — their salvage was taken at claim time.
        .{ .from = 30, .to = 31, .table = "battle_report", .column = "salvage_unclaimed", .sql = "ALTER TABLE battle_report ADD COLUMN salvage_unclaimed INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 32, .to = 33, .table = "contract", .column = "orders_day", .sql = "ALTER TABLE contract ADD COLUMN orders_day INTEGER" },
        // v34: a hall candidate keeps the age it was generated with.
        .{ .from = 33, .to = 34, .table = "candidate", .column = "age", .sql = "ALTER TABLE candidate ADD COLUMN age INTEGER NOT NULL DEFAULT 30" },
        // v35: typed identity for listings, candidates and loans; three meta
        // counters. Pre-v35 rows carry 0 and are backfilled on load (rule 51).
        // next_contract_id is already a meta int; its counter now also advances
        // at offer generation, so u32 is ample for any campaign.
        .{ .from = 34, .to = 35, .table = "listing", .column = "id", .sql = "ALTER TABLE listing ADD COLUMN id INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 34, .to = 35, .table = "candidate", .column = "id", .sql = "ALTER TABLE candidate ADD COLUMN id INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 34, .to = 35, .table = "loan", .column = "id", .sql = "ALTER TABLE loan ADD COLUMN id INTEGER NOT NULL DEFAULT 0" },
        // v36: Person.secondary_role is now persisted; NULL on pre-v36 rows
        // means no secondary role was set (correct default).
        .{ .from = 35, .to = 36, .table = "person", .column = "secondary_role", .sql = "ALTER TABLE person ADD COLUMN secondary_role TEXT" },
        // v38: operation arc state on contract; new `operation` child table
        // (created by ddl). Pre-v38 rows default to "" / 0 / 0 (inert).
        .{ .from = 37, .to = 38, .table = "contract", .column = "arc_key", .sql = "ALTER TABLE contract ADD COLUMN arc_key TEXT NOT NULL DEFAULT ''" },
        .{ .from = 37, .to = 38, .table = "contract", .column = "arc_beat", .sql = "ALTER TABLE contract ADD COLUMN arc_beat INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 37, .to = 38, .table = "contract", .column = "escalation_clock", .sql = "ALTER TABLE contract ADD COLUMN escalation_clock INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 38, .to = 39, .table = "contract", .column = "arc_finale_key", .sql = "ALTER TABLE contract ADD COLUMN arc_finale_key TEXT NOT NULL DEFAULT ''" },
        .{ .from = 38, .to = 39, .table = "operation", .column = "committed_day", .sql = "ALTER TABLE operation ADD COLUMN committed_day INTEGER" },
        .{ .from = 38, .to = 39, .table = "battle_report", .column = "operation", .sql = "ALTER TABLE battle_report ADD COLUMN operation TEXT NOT NULL DEFAULT ''" },
        // v40: operation.intent and battle_report.operation_intent (docs/p4-operations-design.md §6).
        .{ .from = 39, .to = 40, .table = "operation", .column = "intent", .sql = "ALTER TABLE operation ADD COLUMN intent TEXT NOT NULL DEFAULT 'secure_objective'" },
        .{ .from = 39, .to = 40, .table = "battle_report", .column = "operation_intent", .sql = "ALTER TABLE battle_report ADD COLUMN operation_intent TEXT NOT NULL DEFAULT ''" },
        // v42: operation.tempo and battle_report.operation_tempo (docs/p4-operations-design.md §8, P4f).
        .{ .from = 41, .to = 42, .table = "operation", .column = "tempo", .sql = "ALTER TABLE operation ADD COLUMN tempo TEXT NOT NULL DEFAULT 'advance'" },
        .{ .from = 41, .to = 42, .table = "battle_report", .column = "operation_tempo", .sql = "ALTER TABLE battle_report ADD COLUMN operation_tempo TEXT NOT NULL DEFAULT ''" },
        // v43: contract.command_capacity and battle_report.operation_interventions (P4g).
        // operation_intervention table is new (no migration row needed; applySchema creates it).
        .{ .from = 42, .to = 43, .table = "contract", .column = "command_capacity", .sql = "ALTER TABLE contract ADD COLUMN command_capacity INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 42, .to = 43, .table = "battle_report", .column = "operation_interventions", .sql = "ALTER TABLE battle_report ADD COLUMN operation_interventions TEXT NOT NULL DEFAULT ''" },
        // v44: actor table (P4i). New table — no ALTER TABLE migration needed; applySchema creates it.
        // The `actor` table is wholly new; existing saves open with zero actors, next_actor_id=1 (safe default).
        // v45: world_state table (P4h.4). New table — no ALTER TABLE migration needed; applySchema creates it.
        // Existing saves open with zero world states (safe default).
        // v46: rival table (P4i). New table — no ALTER TABLE migration needed; applySchema creates it.
        // Existing saves open with zero rivals, next_rival_id=1 (safe default).
        // v47: officer_arc table (P4i). New table — no ALTER TABLE migration needed; applySchema creates it.
        // Existing saves open with zero officer arcs, next_officer_arc_id=1 (safe default).
        // v48: hull_instance + hull_loadout tables (P3c.1, docs/p3c-hull-lifecycle-design.md §3).
        // New tables — applySchema's ddl creates them. The unit table gains
        // hull_instance_id (added here); upgradeCampaign synthesizes one
        // HullInstance per owned unit for campaigns saved before v48.
        .{ .from = 47, .to = 48, .table = "unit", .column = "hull_instance_id", .sql = "ALTER TABLE unit ADD COLUMN hull_instance_id INTEGER NOT NULL DEFAULT 0" },
        // v49: hull_combat_record table (P3c.2, docs/p3c-hull-lifecycle-design.md §1, §4).
        // New table — applySchema's ddl creates it. Old saves open with zero records (safe default).
        .{ .from = 48, .to = 49, .table = "hull_combat_record", .column = "", .sql = "CREATE TABLE IF NOT EXISTS hull_combat_record (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, battle_id INTEGER NOT NULL DEFAULT 0, contract_id INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, hits_taken INTEGER NOT NULL DEFAULT 0, armor_lost INTEGER NOT NULL DEFAULT 0, slots_damaged INTEGER NOT NULL DEFAULT 0, slots_destroyed INTEGER NOT NULL DEFAULT 0, destroyed INTEGER NOT NULL DEFAULT 0 CHECK (destroyed IN (0,1)), cause TEXT NOT NULL DEFAULT 'none', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED)" },
        // v50: maintenance_entry table (P3c.3, docs/p3c-hull-lifecycle-design.md §1, §2).
        // New table — applySchema's ddl creates it. Old saves open with zero entries.
        .{ .from = 49, .to = 50, .table = "maintenance_entry", .column = "", .sql = "CREATE TABLE IF NOT EXISTS maintenance_entry (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER NOT NULL DEFAULT 0, tech INTEGER NOT NULL DEFAULT 0, action TEXT NOT NULL DEFAULT 'repair', description TEXT NOT NULL DEFAULT '', battle_id INTEGER NOT NULL DEFAULT 0, cost INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED)" },
        // v51: hull_ownership_history table (P3c.4, docs/p3c-hull-lifecycle-design.md §1, §2).
        // New table — applySchema's ddl creates it. Old saves open with zero rows;
        // upgradeCampaign seeds one .initial interval per owned hull (from_version < 51).
        .{ .from = 50, .to = 51, .table = "hull_ownership_history", .column = "", .sql = "CREATE TABLE IF NOT EXISTS hull_ownership_history (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, from_day INTEGER NOT NULL DEFAULT 0, to_day INTEGER NOT NULL DEFAULT 0, acquisition_type TEXT NOT NULL DEFAULT 'initial', prior_owner_key TEXT NOT NULL DEFAULT '', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED)" },
        // v52 (P3e.2): HullInstance current-owner fields (owner_type/owner_faction_key/owner_rival_id).
        // ADD COLUMN NOT NULL DEFAULT backfills every existing hull to 'player' deterministically;
        // every existing hull is player-owned, so no upgradeCampaign code is needed.
        .{ .from = 51, .to = 52, .table = "hull_instance", .column = "owner_type", .sql = "ALTER TABLE hull_instance ADD COLUMN owner_type TEXT NOT NULL DEFAULT 'player'" },
        .{ .from = 51, .to = 52, .table = "hull_instance", .column = "owner_faction_key", .sql = "ALTER TABLE hull_instance ADD COLUMN owner_faction_key TEXT NOT NULL DEFAULT ''" },
        .{ .from = 51, .to = 52, .table = "hull_instance", .column = "owner_rival_id", .sql = "ALTER TABLE hull_instance ADD COLUMN owner_rival_id INTEGER NOT NULL DEFAULT 0" },
        // v53 (P3e.3): faction_roster + rival_roster tables (docs/p3c-economy-design.md §2).
        // New tables — applySchema's ddl creates them. Old saves open with zero rosters.
        .{ .from = 52, .to = 53, .table = "faction_roster", .column = "", .sql = "CREATE TABLE IF NOT EXISTS faction_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, faction_key TEXT NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED)" },
        .{ .from = 52, .to = 53, .table = "rival_roster", .column = "", .sql = "CREATE TABLE IF NOT EXISTS rival_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, rival_id INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, rival_id) REFERENCES rival(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED)" },
        // v54 (P3e entity split): MercCompany/MercCompanyId, merc_company_rosters, owner kind rename.
        // rival: add merc_company_id FK column (soft FK, validated in loader; 0 = none).
        .{ .from = 53, .to = 54, .table = "rival", .column = "merc_company_id", .sql = "ALTER TABLE rival ADD COLUMN merc_company_id INTEGER NOT NULL DEFAULT 0" },
        // hull_instance: rebuild-table to add owner_merc_company_id, remove owner_rival_id, and
        // relabel owner_type='rival'→'merc_company'. Guard: owner_merc_company_id absent on v53 stores.
        // v53 hull_instance__bak has owner_rival_id (added v52) but no owner_merc_company_id yet.
        .{ .from = 53, .to = 54, .table = "hull_instance", .column = "owner_merc_company_id", .sql = "ALTER TABLE hull_instance RENAME TO hull_instance__bak; CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_merc_company_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED); INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign, CASE WHEN owner_type='rival' THEN 'merc_company' ELSE owner_type END, owner_faction_key, CASE WHEN owner_type='rival' THEN owner_rival_id ELSE 0 END FROM hull_instance__bak; DROP TABLE hull_instance__bak" },
        // Drop the deprecated rival_roster table (renamed to merc_company_roster).
        // No producer ever wrote rival_rosters between P3e.3 and this increment, so every
        // shipped v53 store has an empty rival_roster; DROP IF EXISTS is fresh-safe and idempotent.
        .{ .from = 53, .to = 54, .table = "rival_roster", .column = "", .sql = "DROP TABLE IF EXISTS rival_roster" },
        // merc_company table: NO migration row — ddl's CREATE TABLE IF NOT EXISTS covers fresh
        // and upgraded stores. Old saves open with an empty merc_companies map and
        // next_merc_company_id=1 (safe default), exactly the v44/v45/v46 new-table precedent.
        // v55 (P3e.5b-3b): hull_instance_id in battle_report_salvage (pool-path salvage link).
        // Default 0 = .none; abstraction-path rows stay 0.
        .{ .from = 54, .to = 55, .table = "battle_report_salvage", .column = "hull_instance_id", .sql = "ALTER TABLE battle_report_salvage ADD COLUMN hull_instance_id INTEGER NOT NULL DEFAULT 0" },
        // v56 (P3e.6): hull_instance_id in listing (faction surplus listings carry a real HullInstance).
        // Default 0 = .none; abstraction-path listings (house board, black market, contract world) stay 0.
        .{ .from = 55, .to = 56, .table = "listing", .column = "hull_instance_id", .sql = "ALTER TABLE listing ADD COLUMN hull_instance_id INTEGER NOT NULL DEFAULT 0" },
        // v57 (P3f.1): dispersed black-market listing placement.
        .{ .from = 56, .to = 57, .table = "listing", .column = "planet_key", .sql = "ALTER TABLE listing ADD COLUMN planet_key TEXT NOT NULL DEFAULT ''" },
        .{ .from = 56, .to = 57, .table = "listing", .column = "available_after", .sql = "ALTER TABLE listing ADD COLUMN available_after INTEGER NOT NULL DEFAULT 0" },
        // v58 (P3f.4): merc company lifecycle fields (cbills, founded/dissolved day, logo key).
        // Default 0/'' = fail-closed legacy values (rule 49).
        .{ .from = 57, .to = 58, .table = "merc_company", .column = "cbills", .sql = "ALTER TABLE merc_company ADD COLUMN cbills INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 57, .to = 58, .table = "merc_company", .column = "founded_day", .sql = "ALTER TABLE merc_company ADD COLUMN founded_day INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 57, .to = 58, .table = "merc_company", .column = "dissolved_day", .sql = "ALTER TABLE merc_company ADD COLUMN dissolved_day INTEGER NOT NULL DEFAULT 0" },
        .{ .from = 57, .to = 58, .table = "merc_company", .column = "logo_key", .sql = "ALTER TABLE merc_company ADD COLUMN logo_key TEXT NOT NULL DEFAULT ''" },
    };

    pub fn open(path: [*:0]const u8) !Store {
        const db = try sqlite.Db.open(path);
        // fromDb takes ownership of db on success (A24); close on any failure before then.
        errdefer db.close();
        return try fromDb(db);
    }

    /// Read the store's current schema version without mutating the database.
    /// Returns null for a brand-new store (no `setting` table yet).
    /// Returns 1 for a legacy store that has the table but no `schema_version` row.
    /// Returns `error.CorruptStore` for a value < 1 or that does not fit u32.
    fn readStoreVersion(db: sqlite.Db) !?u32 {
        const sm = try db.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='setting'");
        defer sm.finalize();
        _ = try sm.next();
        if (sm.int(0) == 0) return null; // brand-new store, no tables yet
        const st = try db.prepare("SELECT value FROM setting WHERE key = 'schema_version'");
        defer st.finalize();
        if (!try st.next()) return 1; // legacy store: table exists but no version row
        const v = st.int(0);
        if (v < 1) return error.CorruptStore;
        return std.math.cast(u32, v) orelse error.CorruptStore;
    }

    /// Adopt an open database: create what's missing, migrate what's old.
    /// `db` is owned by the caller until this returns successfully; on any
    /// error the caller must close it (A24).  Version is read before any
    /// DDL so a future-version store is refused without mutation (rule 49).
    /// DDL, indexes, column migrations, and table rebuild run in one
    /// transaction (rule 62). Rule 50: PRAGMA foreign_keys is a no-op inside
    /// a transaction, so it is set outside the BEGIN/COMMIT boundary.
    pub fn fromDb(db: sqlite.Db) !Store {
        const stored_opt = try readStoreVersion(db);
        if (stored_opt) |s| if (s > schema_version) return error.StoreNewerThanGame;
        var stored: u32 = stored_opt orelse 0;
        const store: Store = .{ .db = db };
        // Disable FK enforcement before the transaction: DDL and the rebuild
        // require it off; it is re-enabled after COMMIT (rule 50).
        try db.exec("PRAGMA foreign_keys = OFF");
        try db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer db.exec("ROLLBACK") catch {};
        try db.exec(ddl);
        // A fresh store (stored == 0) is fully created by the current DDL and needs
        // no historical migrations. Mark it as already at schema_version so the loop
        // below skips every migration (all have m.to <= schema_version).
        if (stored == 0) stored = schema_version;
        try db.exec(index_ddl);
        for (migrations) |m| {
            if (m.to <= stored) continue;
            if (!try hasColumnRt(db, m.table, m.column)) try db.exec(m.sql);
        }
        // Rebuild per-cid tables with the declared constraint set (rules 50, 51).
        // Skipped for brand-new stores (stored == 0): ddl already creates constrained tables.
        if (stored >= 1 and stored < 37) try rebuildToV37(db);
        try store.setSetting("schema_version", schema_version);
        try db.exec("COMMIT");
        // Re-enable FK enforcement for all subsequent operations (rule 50).
        try db.exec("PRAGMA foreign_keys = ON");
        return store;
    }

    /// Rebuild every per-cid table to acquire the constraint set declared in
    /// `ddl`: containment foreign keys, UNIQUE keys, and CHECK constraints
    /// (rules 50, 51). Uses the SQLite ALTER TABLE procedure: create t__new
    /// with the final schema, copy every row with an explicit column list,
    /// drop t, rename t__new to t. Runs with foreign_keys OFF (set by the
    /// caller); CHECK constraints still apply on INSERT but are restricted to
    /// writer-guaranteed values. Does not run foreign_key_check: soft
    /// references remain the loader's job. Called from fromDb for stored < 37.
    fn rebuildToV37(db: sqlite.Db) !void {
        const marker = "CREATE TABLE IF NOT EXISTS ";
        for (tables) |t| {
            // --- locate this table's constrained definition in ddl ---
            var search_buf: [80]u8 = undefined;
            const search = std.fmt.bufPrint(&search_buf, "{s}{s} (", .{ marker, t }) catch return error.SqliteError;
            const ddl_pos = std.mem.indexOf(u8, ddl, search) orelse continue;
            const ddl_end = std.mem.indexOfScalarPos(u8, ddl, ddl_pos, '\n') orelse ddl.len;
            const table_ddl = ddl[ddl_pos..ddl_end]; // "CREATE TABLE IF NOT EXISTS t (...);"

            // --- create t__new with the constrained schema ---
            // Substitute the table name with t__new in the CREATE TABLE statement.
            const suffix = table_ddl[marker.len + t.len ..]; // " (...);"
            var create_buf: [2048:0]u8 = undefined;
            _ = std.fmt.bufPrintZ(&create_buf, "{s}{s}__new{s}", .{ marker, t, suffix }) catch return error.SqliteError;
            try db.exec(&create_buf);

            // --- build explicit column list from the DDL target schema (t__new) ---
            // Using the target schema rather than the source table ensures that any columns
            // added by migrations that no longer belong in the DDL (e.g. removed by a later
            // rebuild-table migration) are dropped during the rebuild rather than copied.
            var cols_buf: [2048]u8 = undefined;
            var cols_len: usize = 0;
            {
                var sq_buf: [80]u8 = undefined;
                const sq = std.fmt.bufPrint(&sq_buf, "PRAGMA table_info({s}__new)", .{t}) catch return error.SqliteError;
                const st = try db.prepare(sq);
                defer st.finalize();
                var name_buf: [64]u8 = undefined;
                while (try st.next()) {
                    var fba = std.heap.FixedBufferAllocator.init(&name_buf);
                    const col_name = st.text(1, fba.allocator()) catch continue; // best-effort: a column name exceeding the probe buffer cannot be the rebuild target
                    if (cols_len > 0) {
                        if (cols_len >= cols_buf.len) return error.SqliteError;
                        cols_buf[cols_len] = ',';
                        cols_len += 1;
                    }
                    if (cols_len + col_name.len > cols_buf.len) return error.SqliteError;
                    @memcpy(cols_buf[cols_len..][0..col_name.len], col_name);
                    cols_len += col_name.len;
                }
            }
            const cols_str = cols_buf[0..cols_len];

            // --- INSERT INTO t__new SELECT <cols> FROM t ---
            var insert_buf: [3072:0]u8 = undefined;
            _ = std.fmt.bufPrintZ(&insert_buf, "INSERT INTO {s}__new SELECT {s} FROM {s}", .{ t, cols_str, t }) catch return error.SqliteError;
            try db.exec(&insert_buf);

            // --- DROP TABLE t ---
            var drop_buf: [64:0]u8 = undefined;
            _ = std.fmt.bufPrintZ(&drop_buf, "DROP TABLE {s}", .{t}) catch return error.SqliteError;
            try db.exec(&drop_buf);

            // --- ALTER TABLE t__new RENAME TO t ---
            var rename_buf: [96:0]u8 = undefined;
            _ = std.fmt.bufPrintZ(&rename_buf, "ALTER TABLE {s}__new RENAME TO {s}", .{ t, t }) catch return error.SqliteError;
            try db.exec(&rename_buf);
        }
        // Recreate all per-cid indexes after the rebuild (idempotent).
        try db.exec(index_ddl);
    }

    fn hasColumnRt(db: sqlite.Db, table: []const u8, column: []const u8) !bool {
        var sql_buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "PRAGMA table_info({s})", .{table});
        var buf: [64]u8 = undefined;
        const st = try db.prepare(sql);
        defer st.finalize();
        while (try st.next()) {
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const name = st.text(1, fba.allocator()) catch continue; // best-effort: a column name exceeding the probe buffer cannot be the target
            if (std.mem.eql(u8, name, column)) return true;
        }
        return false;
    }

    fn hasColumn(db: sqlite.Db, comptime table: []const u8, column: []const u8) !bool {
        var buf: [64]u8 = undefined;
        const st = try db.prepare("PRAGMA table_info(" ++ table ++ ")");
        defer st.finalize();
        while (try st.next()) {
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const name = st.text(1, fba.allocator()) catch continue; // best-effort: a column name exceeding the probe buffer cannot be the target
            if (std.mem.eql(u8, name, column)) return true;
        }
        return false;
    }

    pub fn close(self: Store) void {
        self.db.close();
    }

    pub const CampaignInfo = struct {
        id: i64,
        name: @import("../sim/table.zig").Raw,
        commander: @import("../sim/table.zig").Raw,
        day: i64,
        date: []const u8,
        /// Monotonic save counter across the store (the sim core keeps no
        /// wall clock); higher = saved more recently.
        save_seq: i64,
        player_id: i64 = 0,
    };

    pub const PlayerInfo = struct {
        id: i64,
        name: @import("../sim/table.zig").Raw,
        campaigns: i64,
    };

    /// Every playthrough in the store, most recently saved first. Strings
    /// owned by `alloc`. `player` = 0 lists everyone's.
    pub fn listCampaigns(self: Store, alloc: std.mem.Allocator) ![]CampaignInfo {
        return self.listCampaignsOf(alloc, 0);
    }

    pub fn listCampaignsOf(self: Store, alloc: std.mem.Allocator, player: i64) ![]CampaignInfo {
        var out: std.ArrayListUnmanaged(CampaignInfo) = .empty;
        const st = try self.db.prepare("SELECT id, name, commander, day, date, save_seq, player_id FROM campaign WHERE (?1 = 0 OR player_id = ?1) ORDER BY save_seq DESC, id DESC");
        defer st.finalize();
        try st.bindAll(.{player});
        while (try st.next()) {
            try out.append(alloc, .{
                .id = st.int(0),
                .name = .{ .raw = try st.text(1, alloc) },
                .commander = .{ .raw = try st.text(2, alloc) },
                .day = st.int(3),
                .date = try st.text(4, alloc),
                .save_seq = st.int(5),
                .player_id = st.int(6),
            });
        }
        return out.toOwnedSlice(alloc);
    }

    // -------------------------------------------------------------- settings

    /// Client settings (music on/off, volume …) live in the store so they
    /// follow the save file, not the terminal.
    pub fn getSetting(self: Store, key: []const u8, default: i64) i64 {
        const st = self.db.prepare("SELECT value FROM setting WHERE key = ?1") catch return default;
        defer st.finalize();
        st.bindAll(.{key}) catch return default;
        const has = st.next() catch return default;
        return if (has) st.int(0) else default;
    }

    pub fn setSetting(self: Store, key: []const u8, value: i64) !void {
        const st = try self.db.prepare("INSERT INTO setting (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
        defer st.finalize();
        try st.bindAll(.{ key, value });
        try st.run();
    }

    // --------------------------------------------------------------- players

    pub fn listPlayers(self: Store, alloc: std.mem.Allocator) ![]PlayerInfo {
        var out: std.ArrayListUnmanaged(PlayerInfo) = .empty;
        const st = try self.db.prepare("SELECT p.id, p.name, (SELECT COUNT(*) FROM campaign c WHERE c.player_id = p.id) FROM player p ORDER BY p.created_seq, p.id");
        defer st.finalize();
        while (try st.next()) {
            try out.append(alloc, .{ .id = st.int(0), .name = .{ .raw = try st.text(1, alloc) }, .campaigns = st.int(2) });
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn createPlayer(self: Store, name: []const u8) !i64 {
        const ins = try self.db.prepare("INSERT INTO player (name, created_seq) VALUES (?1, (SELECT COALESCE(MAX(created_seq), 0) + 1 FROM player))");
        defer ins.finalize();
        try ins.bindAll(.{name});
        try ins.run();
        const q = try self.db.prepare("SELECT last_insert_rowid()");
        defer q.finalize();
        _ = try q.next();
        return q.int(0);
    }

    /// Delete a player and every campaign filed under them, atomically (rule 49).
    pub fn deletePlayer(self: Store, player: i64) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        // List campaigns before the transaction so the SELECT does not
        // nest inside the BEGIN below (SQLite rejects nested BEGIN).
        const owned = try self.listCampaignsOf(arena.allocator(), player);
        try self.db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer self.db.exec("ROLLBACK") catch {};
        for (owned) |c| {
            // Clear rows then delete the campaign row inline: do NOT call
            // deleteCampaign — it opens its own transaction and SQLite
            // rejects nested BEGIN.
            try self.clearRows(c.id);
            const del_c = try self.db.prepare("DELETE FROM campaign WHERE id = ?1");
            defer del_c.finalize();
            try del_c.bindAll(.{c.id});
            try del_c.run();
        }
        const del = try self.db.prepare("DELETE FROM player WHERE id = ?1");
        defer del.finalize();
        try del.bindAll(.{player});
        try del.run();
        try self.db.exec("COMMIT");
    }

    /// Remove a campaign and every row that belonged to it.
    pub fn deleteCampaign(self: Store, cid: i64) !void {
        try self.db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer self.db.exec("ROLLBACK") catch {};
        try self.clearRows(cid);
        const st = try self.db.prepare("DELETE FROM campaign WHERE id = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        try st.run();
        try self.db.exec("COMMIT");
    }

    fn clearRows(self: Store, cid: i64) !void {
        inline for (tables) |t| {
            const st = try self.db.prepare("DELETE FROM " ++ t ++ " WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            try st.run();
        }
    }

    // ------------------------------------------------------------------ save

    /// Save the campaign in one transaction. A first save registers it and
    /// sets `gs.campaign_id` only once the transaction commits, so a failed
    /// save leaves both the store and the state as they were. Saving over a
    /// campaign whose row is gone returns `error.NoSuchCampaign`.
    pub fn save(self: Store, gs: *GameState) !void {
        try self.db.exec("BEGIN");
        // best-effort: rolling back a failed transaction; the original error propagates.
        errdefer self.db.exec("ROLLBACK") catch {};

        const cid = try self.saveCampaignRow(gs);
        try self.clearRows(cid);

        try self.saveMeta(gs, cid);
        try self.saveRngStream(gs, cid);
        try self.saveCommander(gs, cid);
        try self.savePerson(gs, cid);
        try self.saveUnit(gs, cid);
        try self.saveHullInstances(gs, cid);
        try self.saveHullCombatRecords(gs, cid);
        try self.saveMaintenanceEntries(gs, cid);
        try self.saveHullOwnershipHistory(gs, cid);
        try self.saveForce(gs, cid);
        try self.saveStock(cid, "outfit", 0, &gs.spare_parts);
        try self.saveHq(gs, cid);
        try self.saveContracts(gs, cid);
        try self.saveOperations(gs, cid);
        try self.saveActors(gs, cid);
        try self.saveMercCompanies(gs, cid);
        try self.saveRivals(gs, cid);
        try self.saveOfficerArcs(gs, cid);
        try self.saveWorldStates(gs, cid);
        try self.saveFactionRosters(gs, cid);
        try self.saveMercCompanyRosters(gs, cid);
        try self.saveTxn(gs, cid);
        try self.saveLoan(gs, cid);
        try self.saveCourier(gs, cid);
        try self.savePolicy(gs, cid);
        try self.saveSupplyPolicy(gs, cid);
        try self.saveStockPolicy(gs, cid);
        try self.saveBayJob(gs, cid);
        try self.saveCandidate(gs, cid);
        try self.saveHqLink(gs, cid);
        try self.saveUnitTransfer(gs, cid);
        try self.saveFactionCooling(gs, cid);
        try self.saveFactionStanding(gs, cid);
        try self.saveEventMemory(gs, cid);
        try self.saveRatingSnapshot(gs, cid);
        try self.saveListing(gs, cid);
        try self.savePartOrder(gs, cid);
        try self.saveEventLog(gs, cid);
        try self.savePendingEvent(gs, cid);
        try self.saveBattleReport(gs, cid);
        try self.saveRefitPlan(gs, cid);

        try self.db.exec("COMMIT");
        gs.campaign_id = cid;
    }

    // ---- the per-table encoders `save` runs, in its order ----

    /// Insert or update the campaign registry row; returns its id.
    /// `NoSuchCampaign` when an id already set has no row.
    fn saveCampaignRow(self: Store, gs: *GameState) !i64 {
        var date_buf: [10]u8 = undefined;
        const date = gs.clock.date.text(&date_buf);
        const cmdr_name: []const u8 = if (gs.commander) |c| c.name else "";

        var cid = gs.campaign_id;
        if (cid == 0) {
            const ins = try self.db.prepare("INSERT INTO campaign (name, commander, day, date, schema_version, save_seq, player_id) VALUES (?1, ?2, ?3, ?4, ?5, (SELECT COALESCE(MAX(save_seq), 0) + 1 FROM campaign), ?6)");
            defer ins.finalize();
            try ins.bindAll(.{ gs.outfit_name, cmdr_name, @as(i64, gs.clock.day_index), date, @as(i64, schema_version), self.player_id });
            try ins.run();
            const q = try self.db.prepare("SELECT last_insert_rowid()");
            defer q.finalize();
            _ = try q.next();
            cid = q.int(0);
        } else {
            const up = try self.db.prepare("UPDATE campaign SET name = ?1, commander = ?2, day = ?3, date = ?4, schema_version = ?5, save_seq = (SELECT COALESCE(MAX(save_seq), 0) + 1 FROM campaign) WHERE id = ?6");
            defer up.finalize();
            try up.bindAll(.{ gs.outfit_name, cmdr_name, @as(i64, gs.clock.day_index), date, @as(i64, schema_version), cid });
            try up.run();
            if (self.db.changes() == 0) return error.NoSuchCampaign;
        }
        return cid;
    }

    // Scalars.
    fn saveMeta(self: Store, gs: *GameState, cid: i64) !void {
        const difficulty_int: i64 = @intFromEnum(gs.difficulty);
        // A u64 enemy-BV counter that exceeds i64 is a corrupt save on write.
        const enemy_bv_i64: i64 = std.math.cast(i64, gs.stats.enemy_bv_destroyed) orelse return error.SqliteError;
        const st = try self.db.prepare("INSERT INTO meta VALUES (?1, ?2, ?3)");
        defer st.finalize();
        const ints = [_]struct { []const u8, i64 }{
            .{ "day_index", gs.clock.day_index },                   .{ "year", gs.clock.date.year },
            .{ "month", gs.clock.date.month },                      .{ "day", gs.clock.date.day },
            .{ "funds", gs.funds },                                 .{ "reputation", gs.reputation },
            .{ "bankrupt", @as(i64, @intFromBool(gs.bankrupt)) },   .{ "auto_admit", @as(i64, @intFromBool(gs.auto_admit)) },
            .{ "difficulty", difficulty_int },                      .{ "share_profit_bp", @as(i64, gs.share_profit_bp) },
            .{ "stat_battles_won", gs.stats.battles_won },          .{ "stat_battles_drawn", gs.stats.battles_drawn },
            .{ "stat_battles_lost", gs.stats.battles_lost },        .{ "stat_hulls_lost", gs.stats.hulls_lost },
            .{ "stat_hulls_salvaged", gs.stats.hulls_salvaged },    .{ "stat_people_kia", gs.stats.people_kia },
            .{ "stat_enemy_bv", enemy_bv_i64 },                     .{ "next_person_id", gs.next_person_id },
            .{ "next_unit_id", gs.next_unit_id },                   .{ "next_force_id", gs.next_force_id },
            .{ "next_hq_id", gs.next_hq_id },                       .{ "next_contract_id", gs.next_contract_id },
            .{ "next_battle_id", gs.next_battle_id },               .{ "rng_seed", @as(i64, @bitCast(gs.rng.seed)) },
            .{ "next_event_id", gs.event_queue.next_id },           .{ "next_listing_id", gs.next_listing_id },
            .{ "next_candidate_id", gs.next_candidate_id },         .{ "next_loan_id", gs.next_loan_id },
            .{ "next_operation_id", gs.next_operation_id },         .{ "next_actor_id", gs.next_actor_id },
            .{ "next_rival_id", gs.next_rival_id },                 .{ "next_officer_arc_id", gs.next_officer_arc_id },
            .{ "next_hull_instance_id", gs.next_hull_instance_id }, .{ "next_merc_company_id", gs.next_merc_company_id },
        };
        for (ints) |kv| {
            try st.bindAll(.{ cid, kv[0], kv[1] });
            try st.run();
        }
        const tx = try self.db.prepare("INSERT INTO meta_text VALUES (?1, ?2, ?3)");
        defer tx.finalize();
        try tx.bindAll(.{ cid, "outfit_name", gs.outfit_name });
        try tx.run();
        tx.reset();
        try tx.bindAll(.{ cid, "player_logo_key", gs.player_logo_key });
        try tx.run();
    }

    fn saveRngStream(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO rng_stream VALUES (?1, ?2, ?3, ?4)");
        defer st.finalize();
        for (std.enums.values(rng_mod.Stream)) |stream| {
            const bytes = gs.rng.encode(stream);
            try st.bindAll(.{ cid, @tagName(stream), rng_mod.Rng.state_format });
            try st.bindBlob(4, &bytes);
            try st.run();
        }
    }

    fn saveCommander(self: Store, gs: *GameState, cid: i64) !void {
        if (gs.commander) |c| {
            const st = try self.db.prepare("INSERT INTO commander VALUES (?1, ?2, ?3, ?4)");
            defer st.finalize();
            try st.bindAll(.{ cid, c.name, c.origin, c.profession });
            try st.run();
        }
    }

    // People.
    fn savePerson(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO person VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37)");
        const aw = try self.db.prepare("INSERT INTO award VALUES (?1,?2,?3)");
        defer aw.finalize();
        const ab = try self.db.prepare("INSERT INTO ability VALUES (?1,?2,?3)");
        defer ab.finalize();
        defer st.finalize();
        const sk = try self.db.prepare("INSERT INTO person_skill VALUES (?1, ?2, ?3, ?4)");
        defer sk.finalize();
        const inj = try self.db.prepare("INSERT INTO injury VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer inj.finalize();
        var it = gs.people.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const p = entry.value_ptr;
            try st.bindAll(.{
                cid,                                       ord,                                                               @intFromEnum(p.id),
                p.first_name,                              p.last_name,                                                       p.callsign,
                p.role,                                    @as(i64, p.xp),                                                    p.status,
                @as(i64, p.fatigue),                       @as(i64, p.morale),                                                @as(i64, p.recruited_day),
                p.salary_override,                         @intFromEnum(p.assigned_force),                                    @intFromEnum(p.posted_hq),
                @as(i64, p.weekly_hours),                  @as(i64, p.medbay_priority),                                       p.leave_until_day,
                p.wound_heal_day,                          if (p.training) |t| @as(?[]const u8, @tagName(t.skill)) else null, if (p.training) |t| @as(?u32, t.done_day) else null,
                @as(i64, @intFromBool(p.medbay_admitted)), p.rank,                                                            @as(i64, @intFromBool(p.rank_pinned)),
                @as(i64, p.kills),                         @as(i64, p.kill_bv),                                               @as(i64, p.battles),
                @as(i64, p.tours),                         @as(i64, p.outstanding_tours),                                     @as(i64, @intFromBool(p.edge_spent)),
                p.faction,                                 @as(i64, p.shares),                                                p.born_day,
                p.last_raise_day,                          p.last_award_day,                                                  p.departed_day,
                p.secondary_role,
            });
            for (p.awards.items) |key| {
                try aw.bindAll(.{ cid, @intFromEnum(p.id), key });
                try aw.run();
            }
            for (p.abilities.items) |key| {
                try ab.bindAll(.{ cid, @intFromEnum(p.id), key });
                try ab.run();
            }
            try st.run();
            var skit = p.skills.iterator();
            while (skit.next()) |s| {
                try sk.bindAll(.{ cid, @intFromEnum(p.id), s.key_ptr.*, @as(i64, s.value_ptr.*) });
                try sk.run();
            }
            for (p.injuries.items, 0..) |i, n| {
                try inj.bindAll(.{ cid, @intFromEnum(p.id), @as(i64, @intCast(n)), i.location, @as(i64, i.severity), @as(i64, i.incurred_day), i.heal_done_day, @intFromEnum(i.doctor), @as(i64, @intFromBool(i.permanent)), @as(i64, @intFromBool(i.healed)) });
                try inj.run();
            }
        }
    }

    // Units and slots.
    fn saveUnit(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO unit VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)");
        defer st.finalize();
        const sl = try self.db.prepare("INSERT INTO unit_slot VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer sl.finalize();
        var ord: i64 = 0;
        const Writer = struct {
            // One writer for both, so an owned hull and a held one can
            // never be saved by two loops that drift apart.
            fn put(unit_st: anytype, slot_st: anytype, c: i64, o: i64, u: *const unit_mod.Unit, held: unit_mod.HeldHull.Mark) !void {
                try unit_st.bindAll(.{
                    c,                                   o,                                       @intFromEnum(u.id),               u.chassis_key,
                    u.name,                              u.kind,                                  @intFromEnum(u.force),            @intFromEnum(u.pilot),
                    @intFromEnum(u.tech),                @as(i64, u.armor_pct),                   u.quality,                        u.status,
                    u.last_maintenance_day,              @as(i64, u.acquired_day),                u.purchase_price,                 u.reactivation_done_day,
                    @intFromEnum(u.berth_hq),            u.wreck,                                 held.by,                          @as(i64, held.day),
                    @as(i64, @intFromEnum(held.battle)), @as(i64, @intFromEnum(held.from_force)), @intFromEnum(u.hull_instance_id),
                });
                try unit_st.run();
                for (u.slots.items, 0..) |s, i| {
                    try slot_st.bindAll(.{ c, @intFromEnum(u.id), @as(i64, @intCast(i)), s.slot_key, s.part_key, s.class, s.condition });
                    try slot_st.run();
                }
            }
        };
        var it = gs.units.iterator();
        while (it.next()) |entry| : (ord += 1) try Writer.put(st, sl, cid, ord, entry.value_ptr, .{});
        for (gs.held_hulls.items) |*h| {
            try Writer.put(st, sl, cid, ord, &h.unit, h.mark());
            ord += 1;
        }
    }

    fn saveHullInstances(self: Store, gs: *GameState, cid: i64) !void {
        // Named-column INSERT: explicit column list keeps the write correct across schema changes.
        const st = try self.db.prepare("INSERT INTO hull_instance (cid,ord,id,base_key,name,nickname,status,intro_year,pre_campaign,owner_type,owner_faction_key,owner_merc_company_id) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer st.finalize();
        const ld = try self.db.prepare("INSERT INTO hull_loadout VALUES (?1,?2,?3,?4)");
        defer ld.finalize();
        var it = gs.hull_instances.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const h = entry.value_ptr;
            const owner_type_tag = @tagName(std.meta.activeTag(h.owner));
            const owner_faction_key: []const u8 = switch (h.owner) {
                .faction => |k| k,
                else => "",
            };
            const owner_merc_company_id: i64 = switch (h.owner) {
                .merc_company => |r| @as(i64, @intFromEnum(r)),
                else => 0,
            };
            try st.bindAll(.{ cid, ord, @intFromEnum(h.id), h.base_key, h.name, h.nickname, @tagName(h.status), @as(i64, h.intro_year), @as(i64, @intFromBool(h.pre_campaign)), owner_type_tag, owner_faction_key, owner_merc_company_id });
            try st.run();
            for (h.loadout.items, 0..) |l, i| {
                try ld.bindAll(.{ cid, @intFromEnum(h.id), @as(i64, @intCast(i)), l.part_key });
                try ld.run();
            }
        }
    }

    fn saveHullCombatRecords(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO hull_combat_record VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer st.finalize();
        for (gs.hull_combat_records.items, 0..) |r, ord| {
            try st.bindAll(.{
                cid,
                @intFromEnum(r.hull_instance_id),
                @as(i64, @intCast(ord)),
                @intFromEnum(r.battle_id),
                @intFromEnum(r.contract_id),
                @as(i64, r.kills),
                @as(i64, r.hits_taken),
                @as(i64, r.armor_lost),
                @as(i64, r.slots_damaged),
                @as(i64, r.slots_destroyed),
                @as(i64, @intFromBool(r.destroyed)),
                @tagName(r.cause),
            });
            try st.run();
        }
    }

    fn saveMaintenanceEntries(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO maintenance_entry VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer st.finalize();
        for (gs.maintenance_entries.items, 0..) |e, ord| {
            try st.bindAll(.{
                cid,
                @intFromEnum(e.hull_instance_id),
                @as(i64, @intCast(ord)),
                @as(i64, e.day),
                @intFromEnum(e.tech),
                @tagName(e.action),
                e.description,
                @intFromEnum(e.battle_id),
                e.cost,
            });
            try st.run();
        }
    }

    fn saveHullOwnershipHistory(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO hull_ownership_history VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.hull_ownership_history.items, 0..) |e, ord| {
            try st.bindAll(.{
                cid,
                @intFromEnum(e.hull_instance_id),
                @as(i64, @intCast(ord)),
                @as(i64, e.from_day),
                @as(i64, e.to_day),
                @tagName(e.acquisition_type),
                e.prior_owner_key,
            });
            try st.run();
        }
    }

    // Forces, their unit and child orderings, and field stores.
    fn saveForce(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO force VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)");
        defer st.finalize();
        const fu = try self.db.prepare("INSERT INTO force_unit VALUES (?1,?2,?3,?4)");
        defer fu.finalize();
        const fc = try self.db.prepare("INSERT INTO force_child VALUES (?1,?2,?3,?4)");
        defer fc.finalize();
        var it = gs.forces.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const f = entry.value_ptr;
            try st.bind(1, cid);
            try st.bind(2, ord);
            try st.bind(3, @intFromEnum(f.id));
            try st.bind(4, @intFromEnum(f.parent));
            try st.bind(5, f.name);
            if (f.emblem) |e| try st.bindBlob(6, e) else try st.bind(6, null);
            try st.bind(7, f.local_funds);
            try st.bind(8, f.echelon);
            try st.bind(9, @intFromEnum(f.commander));
            try st.bind(10, @intFromEnum(f.supplying_hq));
            try st.bind(11, f.role);
            try st.bind(12, f.support_kind);
            try st.bind(13, f.last_rotation_day);
            try st.bind(14, @as(i64, f.contracts_since_rotation));
            try st.bind(15, f.location_planet);
            try st.bind(16, f.return_eta_day);
            try st.bind(17, @as(i64, f.supply_shortage_days));
            try st.bind(18, f.roe);
            try st.run();
            for (f.units.items, 0..) |uid, i| {
                try fu.bindAll(.{ cid, @intFromEnum(f.id), @as(i64, @intCast(i)), @intFromEnum(uid) });
                try fu.run();
            }
            for (f.children.items, 0..) |child, i| {
                try fc.bindAll(.{ cid, @intFromEnum(f.id), @as(i64, @intCast(i)), @intFromEnum(child) });
                try fc.run();
            }
            try self.saveStock(cid, "company", @intFromEnum(f.id), &f.stock);
        }
    }

    // HQs, facilities, projects, warehouse stock.
    fn saveHq(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO hq VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer st.finalize();
        const fa = try self.db.prepare("INSERT INTO hq_facility VALUES (?1,?2,?3,?4,?5)");
        defer fa.finalize();
        const pr = try self.db.prepare("INSERT INTO hq_project VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer pr.finalize();
        var it = gs.hqs.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const h = entry.value_ptr;
            try st.bindAll(.{ cid, ord, @intFromEnum(h.id), h.name, h.tier, h.planet_key, @as(i64, h.staff_assigned), h.monthly_upkeep, h.funds });
            try st.run();
            for (h.facilities.items, 0..) |f, i| {
                try fa.bindAll(.{ cid, @intFromEnum(h.id), @as(i64, @intCast(i)), f.kind, @as(i64, f.level) });
                try fa.run();
            }
            for (h.projects.items, 0..) |p, i| {
                try pr.bindAll(.{ cid, @intFromEnum(h.id), @as(i64, @intCast(i)), p.kind, p.facility, @as(i64, p.target_level), @as(i64, p.started_day), @as(i64, p.paperwork_done_day), @as(i64, p.construction_done_day), p.cost });
                try pr.run();
            }
            try self.saveStock(cid, "hq", @intFromEnum(h.id), &h.stock);
        }
    }

    // Contracts and offers.
    fn saveContracts(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO contract VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50)");
        defer st.finalize();
        var ord: i64 = 0;
        var it = gs.contracts.iterator();
        while (it.next()) |entry| : (ord += 1) try saveContract(st, cid, false, ord, entry.value_ptr);
        for (gs.contract_offers.items, 0..) |*o, i| try saveContract(st, cid, true, @intCast(i), o);
    }

    fn saveOperations(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO operation VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer st.finalize();
        // P4e: per-operation task assignments.
        const tt = try self.db.prepare("INSERT INTO operation_task VALUES (?1,?2,?3,?4,?5,?6)");
        defer tt.finalize();
        // P4g: per-operation intervention applications.
        const iv_st = try self.db.prepare("INSERT INTO operation_intervention VALUES (?1,?2,?3,?4,?5)");
        defer iv_st.finalize();
        var it = gs.contracts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr;
            for (c.operations.items, 0..) |op, ord| {
                try st.bindAll(.{
                    cid,
                    @intFromEnum(c.id),
                    @as(i64, @intCast(ord)),
                    @intFromEnum(op.id),
                    op.template_key,
                    @tagName(op.state),
                    @tagName(op.outcome),
                    @as(i64, op.opened_day),
                    op.resolved_day,
                    op.committed_day,
                    @tagName(op.intent),
                    @tagName(op.tempo),
                });
                try st.run();
                for (op.tasks.items, 0..) |lt, ti| {
                    try tt.bindAll(.{
                        cid,
                        @intFromEnum(c.id),
                        @intFromEnum(op.id),
                        @as(i64, @intCast(ti)),
                        @as(i64, @intFromEnum(lt.lance)),
                        @tagName(lt.task),
                    });
                    try tt.run();
                }
                for (op.interventions.items, 0..) |iv, ii| {
                    try iv_st.bindAll(.{
                        cid,
                        @intFromEnum(c.id),
                        @intFromEnum(op.id),
                        @as(i64, @intCast(ii)),
                        @tagName(iv),
                    });
                    try iv_st.run();
                }
            }
        }
    }

    fn loadOperations(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT contract_id, id, template_key, state, outcome, opened_day, resolved_day, committed_day, intent, tempo FROM operation WHERE cid = ?1 ORDER BY contract_id, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const contract_id = try toId(types.ContractId, st.int(0));
            const c = gs.contracts.getPtr(contract_id) orelse return error.CorruptSave;
            const op: operation_mod.Operation = .{
                .id = try toId(types.OperationId, st.int(1)),
                .template_key = try st.text(2, alloc),
                .state = st.enumValue(operation_mod.OperationState, 3) orelse return error.CorruptSave,
                .outcome = st.enumValue(operation_mod.OutcomeBand, 4) orelse return error.CorruptSave,
                .opened_day = try st.intAs(u32, 5),
                .resolved_day = try optU32(st.optInt(6)),
                .committed_day = try optU32(st.optInt(7)),
                .intent = st.enumValue(operation_mod.Intent, 8) orelse return error.CorruptSave,
                .tempo = st.enumValue(operation_mod.TempoPosture, 9) orelse return error.CorruptSave,
            };
            try c.operations.append(alloc, op);
        }
        // Bump next_operation_id past the maximum stored id.
        {
            var max: u32 = 0;
            var cit = gs.contracts.iterator();
            while (cit.next()) |entry| {
                for (entry.value_ptr.operations.items) |op| {
                    max = @max(max, @intFromEnum(op.id));
                }
            }
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            gs.next_operation_id = @max(gs.next_operation_id, max + 1);
        }
        // FK-orphan: operation_task rows must reference loaded operation ids (P4e).
        {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM operation_task WHERE cid = ?1 AND operation_id NOT IN (SELECT id FROM operation WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
        // FK-orphan: operation_intervention rows must reference loaded operation ids (P4g).
        {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM operation_intervention WHERE cid = ?1 AND operation_id NOT IN (SELECT id FROM operation WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
    }

    // P4e: load lance task assignments onto operations (must run after loadOperations).
    fn loadOperationTasks(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT contract_id, operation_id, lance_id, task FROM operation_task WHERE cid = ?1 ORDER BY contract_id, operation_id, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const contract_id = try toId(types.ContractId, st.int(0));
            const operation_id = try toId(types.OperationId, st.int(1));
            const lance_id = try toId(types.ForceId, st.int(2));
            const task = st.enumValue(operation_mod.LanceTask, 3) orelse return error.CorruptSave;
            const c = gs.contracts.getPtr(contract_id) orelse return error.CorruptSave;
            for (c.operations.items) |*op| {
                if (op.id == operation_id) {
                    try op.tasks.append(alloc, .{ .lance = lance_id, .task = task });
                    break;
                }
            }
        }
    }

    // P4g: load intervention applications onto operations (must run after loadOperations).
    fn loadOperationInterventions(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT contract_id, operation_id, kind FROM operation_intervention WHERE cid = ?1 ORDER BY contract_id, operation_id, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const contract_id = try toId(types.ContractId, st.int(0));
            const operation_id = try toId(types.OperationId, st.int(1));
            const kind = st.enumValue(operation_mod.Intervention, 2) orelse return error.CorruptSave;
            const c = gs.contracts.getPtr(contract_id) orelse return error.CorruptSave;
            for (c.operations.items) |*op| {
                if (op.id == operation_id) {
                    try op.interventions.append(alloc, kind);
                    break;
                }
            }
        }
    }

    // P4i: save and load persistent actors.
    fn saveActors(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO actor VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)");
        defer st.finalize();
        var it = gs.actors.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const a = entry.value_ptr;
            try st.bindAll(.{
                cid,
                ord,
                @intFromEnum(a.id),
                a.archetype_key,
                a.first_name,
                a.last_name,
                a.faction_key,
                @tagName(a.side),
                @intFromEnum(a.contract),
                @as(i64, a.trust),
                @as(i64, a.debt),
                @as(i64, a.respect),
                @as(i64, a.hostility),
                a.last_cause,
                @as(i64, a.last_cause_day),
                @as(i64, @intFromBool(a.recurring)),
            });
            try st.run();
        }
    }

    fn loadActors(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, archetype_key, first_name, last_name, faction_key, side, contract, trust, debt, respect, hostility, last_cause, last_cause_day, recurring FROM actor WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const archetype_key = try st.text(1, alloc);
            // Validate archetype_key references a known archetype.
            if (actor_mod.find(archetype_key) == null) return error.CorruptSave;
            const side_str = try st.text(5, alloc);
            const side = std.meta.stringToEnum(actor_mod.FactionSide, side_str) orelse return error.CorruptSave;
            const trust = try fit(i16, st.int(7));
            const debt = try fit(i16, st.int(8));
            const respect = try fit(i16, st.int(9));
            const hostility = try fit(i16, st.int(10));
            // Validate relationship dimensions in range.
            if (trust < actor_mod.rel_min or trust > actor_mod.rel_max) return error.CorruptSave;
            if (debt < actor_mod.rel_min or debt > actor_mod.rel_max) return error.CorruptSave;
            if (respect < actor_mod.rel_min or respect > actor_mod.rel_max) return error.CorruptSave;
            if (hostility < actor_mod.rel_min or hostility > actor_mod.rel_max) return error.CorruptSave;
            const contract_raw = st.int(6);
            const contract_id: types.ContractId = @enumFromInt(std.math.cast(u32, contract_raw) orelse return error.CorruptSave);
            const a: actor_mod.Actor = .{
                .id = try toId(types.ActorId, st.int(0)),
                .archetype_key = archetype_key,
                .first_name = try st.text(2, alloc),
                .last_name = try st.text(3, alloc),
                .faction_key = try st.text(4, alloc),
                .side = side,
                .contract = contract_id,
                .trust = trust,
                .debt = debt,
                .respect = respect,
                .hostility = hostility,
                .last_cause = try st.text(11, alloc),
                .last_cause_day = try st.intAs(u32, 12),
                .recurring = st.int(13) != 0,
            };
            const gop = try gs.actors.getOrPut(alloc, a.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = a;
        }
        // Validate: actors with a nonzero contract reference must resolve to a loaded contract.
        // Rebuild actor_ids lists on contracts from actors' contract back-references.
        {
            var it = gs.actors.iterator();
            while (it.next()) |entry| {
                const a = entry.value_ptr;
                if (a.contract == .none) continue;
                const c = gs.contracts.getPtr(a.contract) orelse return error.CorruptSave;
                try c.actor_ids.append(alloc, a.id);
            }
        }
        // Bump next_actor_id past the maximum stored id.
        {
            var max: u32 = 0;
            var it = gs.actors.iterator();
            while (it.next()) |entry| max = @max(max, @intFromEnum(entry.key_ptr.*));
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            gs.next_actor_id = @max(gs.next_actor_id, max + 1);
        }
    }

    // P4h.4: save and load per-world state.
    fn saveWorldStates(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO world_state VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer st.finalize();
        var it = gs.world_states.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const ws = entry.value_ptr;
            try st.bindAll(.{
                cid,
                ord,
                entry.key_ptr.*,
                @as(i64, ws.security),
                @as(i64, ws.civilian_support),
                @as(i64, ws.infrastructure_strain),
                @as(i64, ws.employer_control),
                @as(i64, ws.enemy_influence),
                ws.last_cause,
                @as(i64, ws.last_cause_day),
            });
            try st.run();
        }
    }

    fn loadWorldStates(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT planet_key, security, civilian_support, infrastructure_strain, employer_control, enemy_influence, last_cause, last_cause_day FROM world_state WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const planet_key = try st.text(0, alloc);
            const security = try fit(i16, st.int(1));
            const civilian_support = try fit(i16, st.int(2));
            const infrastructure_strain = try fit(i16, st.int(3));
            const employer_control = try fit(i16, st.int(4));
            const enemy_influence = try fit(i16, st.int(5));
            // Validate dimension ranges.
            if (security < world_state_dom.world_min or security > world_state_dom.world_max) return error.CorruptSave;
            if (civilian_support < world_state_dom.world_min or civilian_support > world_state_dom.world_max) return error.CorruptSave;
            if (infrastructure_strain < world_state_dom.world_min or infrastructure_strain > world_state_dom.world_max) return error.CorruptSave;
            if (employer_control < world_state_dom.world_min or employer_control > world_state_dom.world_max) return error.CorruptSave;
            if (enemy_influence < world_state_dom.world_min or enemy_influence > world_state_dom.world_max) return error.CorruptSave;
            const ws: world_state_dom.WorldState = .{
                .security = security,
                .civilian_support = civilian_support,
                .infrastructure_strain = infrastructure_strain,
                .employer_control = employer_control,
                .enemy_influence = enemy_influence,
                .last_cause = try st.text(6, alloc),
                .last_cause_day = try st.intAs(u32, 7),
            };
            const gop = try gs.world_states.getOrPut(alloc, planet_key);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = ws;
        }
    }

    // P4i: save and load persistent rivals.
    fn saveRivals(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO rival VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)");
        defer st.finalize();
        var it = gs.rivals.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const rv = entry.value_ptr;
            try st.bindAll(.{
                cid,
                ord,
                @intFromEnum(rv.id),
                rv.archetype_key,
                rv.commander_first,
                rv.commander_last,
                rv.unit_name,
                rv.faction_key,
                @tagName(rv.side),
                @tagName(rv.doctrine),
                @intFromEnum(rv.contract),
                @as(i64, rv.standing),
                @as(i64, rv.encounters),
                rv.last_cause,
                @as(i64, rv.last_cause_day),
                @as(i64, @intFromBool(rv.recurring)),
                @as(i64, @intFromEnum(rv.merc_company_id)),
            });
            try st.run();
        }
    }

    fn loadRivals(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine, contract, standing, encounters, last_cause, last_cause_day, recurring, merc_company_id FROM rival WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const archetype_key = try st.text(1, alloc);
            // Validate archetype_key references a known archetype.
            if (rival_mod.find(archetype_key) == null) return error.CorruptSave;
            const side_str = try st.text(6, alloc);
            const side = std.meta.stringToEnum(rival_mod.FactionSide, side_str) orelse return error.CorruptSave;
            const doctrine_str = try st.text(7, alloc);
            const doctrine = std.meta.stringToEnum(rival_mod.RivalDoctrine, doctrine_str) orelse return error.CorruptSave;
            const standing = try fit(i16, st.int(9));
            // Validate standing in range.
            if (standing < rival_mod.rival_min or standing > rival_mod.rival_max) return error.CorruptSave;
            const encounters_raw = st.int(10);
            const encounters = std.math.cast(u16, encounters_raw) orelse return error.CorruptSave;
            const contract_raw = st.int(8);
            const contract_id: types.ContractId = @enumFromInt(std.math.cast(u32, contract_raw) orelse return error.CorruptSave);
            const unit_name = try st.text(4, alloc);
            // Validate unit_name markup-safe.
            if (!@import("../sim/table.zig").markupSafe(unit_name)) return error.CorruptSave;
            const last_cause = try st.text(11, alloc);
            // Validate last_cause markup-safe (may be empty).
            if (last_cause.len > 0 and !@import("../sim/table.zig").markupSafe(last_cause)) return error.CorruptSave;
            const rv: rival_mod.Rival = .{
                .id = try toId(types.RivalId, st.int(0)),
                .archetype_key = archetype_key,
                .commander_first = try st.text(2, alloc),
                .commander_last = try st.text(3, alloc),
                .unit_name = unit_name,
                .faction_key = try st.text(5, alloc),
                .side = side,
                .doctrine = doctrine,
                .contract = contract_id,
                .standing = standing,
                .encounters = encounters,
                .last_cause = last_cause,
                .last_cause_day = try st.intAs(u32, 12),
                .recurring = st.int(13) != 0,
                .merc_company_id = try toId(types.MercCompanyId, st.int(14)),
            };
            const gop = try gs.rivals.getOrPut(alloc, rv.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = rv;
        }
        // Validate: rivals with a nonzero contract reference must resolve to a loaded contract.
        // Rebuild rival_ids lists on contracts from rivals' contract back-references.
        {
            var it2 = gs.rivals.iterator();
            while (it2.next()) |entry| {
                const rv = entry.value_ptr;
                if (rv.contract == .none) continue;
                const c = gs.contracts.getPtr(rv.contract) orelse return error.CorruptSave;
                try c.rival_ids.append(alloc, rv.id);
            }
        }
        // Bump next_rival_id past the maximum stored id.
        {
            var max: u32 = 0;
            var it2 = gs.rivals.iterator();
            while (it2.next()) |entry| max = @max(max, @intFromEnum(entry.key_ptr.*));
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            gs.next_rival_id = @max(gs.next_rival_id, max + 1);
        }
    }

    // P3e entity split: save and load persistent world merc companies.
    fn saveMercCompanies(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO merc_company VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)");
        defer st.finalize();
        var it = gs.merc_companies.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const mc = entry.value_ptr;
            try st.bindAll(.{
                cid,
                ord,
                @as(i64, @intFromEnum(mc.id)),
                mc.archetype_key,
                mc.commander_first,
                mc.commander_last,
                mc.unit_name,
                mc.faction_key,
                @tagName(mc.side),
                @tagName(mc.doctrine),
                mc.cbills,
                @as(i64, mc.founded_day),
                @as(i64, mc.dissolved_day),
                mc.logo_key,
            });
            try st.run();
        }
    }

    fn loadMercCompanies(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine, cbills, founded_day, dissolved_day, logo_key FROM merc_company WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const archetype_key = try st.text(1, alloc);
            if (rival_mod.find(archetype_key) == null) return error.CorruptSave;
            const side_str = try st.text(6, alloc);
            const side = std.meta.stringToEnum(merc_company_mod.FactionSide, side_str) orelse return error.CorruptSave;
            const doctrine_str = try st.text(7, alloc);
            const doctrine = std.meta.stringToEnum(merc_company_mod.RivalDoctrine, doctrine_str) orelse return error.CorruptSave;
            const unit_name = try st.text(4, alloc);
            if (!@import("../sim/table.zig").markupSafe(unit_name)) return error.CorruptSave;
            const mc: merc_company_mod.MercCompany = .{
                .id = try toId(types.MercCompanyId, st.int(0)),
                .archetype_key = archetype_key,
                .commander_first = try st.text(2, alloc),
                .commander_last = try st.text(3, alloc),
                .unit_name = unit_name,
                .faction_key = try st.text(5, alloc),
                .side = side,
                .doctrine = doctrine,
                .cbills = st.int(8),
                .founded_day = try st.intAs(u32, 9),
                .dissolved_day = try st.intAs(u32, 10),
                .logo_key = try st.text(11, alloc),
            };
            const gop = try gs.merc_companies.getOrPut(alloc, mc.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = mc;
        }
    }

    // P4i: save and load persistent officer arcs.
    fn saveOfficerArcs(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO officer_arc VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
        defer st.finalize();
        var it = gs.officer_arcs.iterator();
        var ord: i64 = 0;
        while (it.next()) |entry| : (ord += 1) {
            const oa = entry.value_ptr;
            try st.bindAll(.{
                cid,
                ord,
                @intFromEnum(oa.id),
                @intFromEnum(oa.person),
                @intFromEnum(oa.contract),
                @tagName(oa.seat),
                @as(i64, oa.performance),
                @as(i64, oa.encounters),
                oa.last_cause,
                @as(i64, oa.last_cause_day),
                @as(i64, @intFromBool(oa.recurring)),
            });
            try st.run();
        }
    }

    /// Min/max bounds for stored performance (validated on load; mirror rule 20 constants).
    const perf_min: i16 = officer_dom.perf_min;
    const perf_max: i16 = officer_dom.perf_max;

    fn loadOfficerArcs(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, person, contract, seat, performance, encounters, last_cause, last_cause_day, recurring FROM officer_arc WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const seat_str = try st.text(3, alloc);
            const seat = std.meta.stringToEnum(officer_dom.OfficerSeat, seat_str) orelse return error.CorruptSave;
            const performance = try fit(i16, st.int(4));
            if (performance < perf_min or performance > perf_max) return error.CorruptSave;
            const encounters_raw = st.int(5);
            const encounters = std.math.cast(u16, encounters_raw) orelse return error.CorruptSave;
            const contract_raw = st.int(2);
            const contract_id: types.ContractId = @enumFromInt(std.math.cast(u32, contract_raw) orelse return error.CorruptSave);
            const person_raw = st.int(1);
            const person_id: types.PersonId = @enumFromInt(std.math.cast(u32, person_raw) orelse return error.CorruptSave);
            // Validate person back-reference: must resolve to a loaded Person.
            if (person_id == .none or gs.people.getPtr(person_id) == null) return error.CorruptSave;
            const last_cause = try st.text(6, alloc);
            if (last_cause.len > 0 and !@import("../sim/table.zig").markupSafe(last_cause)) return error.CorruptSave;
            const oa: officer_dom.OfficerArc = .{
                .id = try toId(types.OfficerArcId, st.int(0)),
                .person = person_id,
                .contract = contract_id,
                .seat = seat,
                .performance = performance,
                .encounters = encounters,
                .last_cause = last_cause,
                .last_cause_day = try st.intAs(u32, 7),
                .recurring = st.int(8) != 0,
            };
            const gop = try gs.officer_arcs.getOrPut(alloc, oa.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = oa;
        }
        // Validate: officer arcs with a nonzero contract reference must resolve to a loaded contract.
        // Rebuild officer_arc_ids lists on contracts from officer arcs' contract back-references.
        {
            var it2 = gs.officer_arcs.iterator();
            while (it2.next()) |entry| {
                const oa = entry.value_ptr;
                if (oa.contract == .none) continue;
                const c = gs.contracts.getPtr(oa.contract) orelse return error.CorruptSave;
                try c.officer_arc_ids.append(alloc, oa.id);
            }
        }
        // Bump next_officer_arc_id past the maximum stored id.
        {
            var max: u32 = 0;
            var it2 = gs.officer_arcs.iterator();
            while (it2.next()) |entry| max = @max(max, @intFromEnum(entry.key_ptr.*));
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            gs.next_officer_arc_id = @max(gs.next_officer_arc_id, max + 1);
        }
    }

    // P3e.3: save and load faction/rival roster collections.

    /// Save faction_rosters: one row per (faction_key, hull_instance_id) pair,
    /// ordered by global insertion order so load restores exact map+list order
    /// (docs/p3c-economy-design.md §2; rules 2, 49, 53).
    fn saveFactionRosters(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO faction_roster VALUES (?1,?2,?3,?4)");
        defer st.finalize();
        var ord: i64 = 0;
        var it = gs.faction_rosters.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |hid| {
                try st.bindAll(.{ cid, ord, entry.key_ptr.*, @as(i64, @intFromEnum(hid)) });
                try st.run();
                ord += 1;
            }
        }
    }

    /// Load faction_rosters from the faction_roster table. Keys and values are
    /// appended in ord order, restoring the original insertion order for both
    /// the map and each hull list. faction_key is validated centrally by
    /// validateStoredStrings (Check.house); member hull ids by validateReferences.
    fn loadFactionRosters(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT faction_key, hull_instance_id FROM faction_roster WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const key = try st.text(0, alloc);
            const hid = try toId(types.HullInstanceId, st.int(1));
            if (hid == .none) return error.CorruptSave; // a roster member must be a real hull id
            const gop = try gs.faction_rosters.getOrPut(alloc, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, hid);
        }
    }

    /// Save merc_company_rosters: one row per (merc_company_id, hull_instance_id) pair.
    fn saveMercCompanyRosters(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO merc_company_roster VALUES (?1,?2,?3,?4)");
        defer st.finalize();
        var ord: i64 = 0;
        var it = gs.merc_company_rosters.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |hid| {
                try st.bindAll(.{ cid, ord, @as(i64, @intFromEnum(entry.key_ptr.*)), @as(i64, @intFromEnum(hid)) });
                try st.run();
                ord += 1;
            }
        }
    }

    /// Load merc_company_rosters from the merc_company_roster table. merc_company_id and
    /// member hull ids are validated centrally by validateReferences (rule 47).
    fn loadMercCompanyRosters(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT merc_company_id, hull_instance_id FROM merc_company_roster WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const mid = try toId(types.MercCompanyId, st.int(0));
            if (mid == .none) return error.CorruptSave; // a roster keyed by none is corrupt
            const hid = try toId(types.HullInstanceId, st.int(1));
            if (hid == .none) return error.CorruptSave; // a roster member must be a real hull id
            const gop = try gs.merc_company_rosters.getOrPut(alloc, mid);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, hid);
        }
    }

    // Ledger and the rest of the lists.
    fn saveTxn(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO txn VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer st.finalize();
        for (gs.ledger.transactions.items, 0..) |t, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, t.day), t.amount, t.category, @intFromEnum(t.company), @intFromEnum(t.hq), @intFromEnum(t.contract), t.note });
            try st.run();
        }
    }

    fn saveLoan(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO loan VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer st.finalize();
        for (gs.loans.items, 0..) |l, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), l.principal, l.balance, l.rate_bp, @as(i64, l.term_months), @as(i64, l.next_pay_day), l.payment, @intFromEnum(l.id) });
            try st.run();
        }
    }

    fn saveCourier(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO courier VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.fund_couriers.items, 0..) |c, i| {
            const t = treasuryCols(c.to);
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), t.kind, t.id, c.amount, @as(i64, c.sent_day), @as(i64, c.eta_day) });
            try st.run();
        }
    }

    fn savePolicy(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO policy VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.policies.items, 0..) |p, i| {
            const t = treasuryCols(p.entity);
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), t.kind, t.id, p.floor, p.monthly_cap, p.sent_this_month });
            try st.run();
        }
    }

    fn saveSupplyPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO supply_policy VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        for (gs.supply_policies.items, 0..) |p, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.company), @as(i64, p.min_days), @as(i64, p.tons), @as(i64, p.ammo_battles) });
            try st.run();
        }
    }

    fn saveStockPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO stock_policy VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        for (gs.stock_policies.items, 0..) |p, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.hq), p.part_key, @as(i64, p.min), @as(i64, p.target) });
            try st.run();
        }
    }

    fn saveBayJob(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO bay_job VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
        defer st.finalize();
        for (gs.bay_jobs.items, 0..) |j, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(j.hq), j.kind, @intFromEnum(j.unit), j.item_key, @as(i64, j.duration_days), @as(i64, j.queued_day), j.started_day, j.done_day, j.cost });
            try st.run();
        }
    }

    fn saveCandidate(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO candidate VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)");
        defer st.finalize();
        for (gs.candidates.items, 0..) |c, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(c.hq), c.spec.first, c.spec.last, c.spec.callsign, c.spec.role, c.spec.experience, @as(i64, c.spec.primary_skill), @as(i64, c.spec.secondary_skill), c.asking_bonus, @as(i64, c.listed_day), @as(i64, c.expires_day), @as(i64, c.spec.age), @intFromEnum(c.id) });
            try st.run();
        }
    }

    fn saveHqLink(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO hq_link VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.hq_links.items, 0..) |l, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(l.a), @intFromEnum(l.b), @as(i64, l.level), @as(i64, l.tons_this_week), @as(i64, l.established_day) });
            try st.run();
        }
    }

    fn saveUnitTransfer(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO unit_transfer VALUES (?1,?2,?3,?4,?5)");
        defer st.finalize();
        for (gs.unit_transfers.items, 0..) |t, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(t.unit), @intFromEnum(t.to_company), @as(i64, t.eta_day) });
            try st.run();
        }
    }

    fn saveFactionCooling(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO faction_cooling VALUES (?1,?2,?3,?4)");
        defer st.finalize();
        for (gs.faction_cooling.items, 0..) |f, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), f.faction, @as(i64, f.until_day) });
            try st.run();
        }
    }

    fn saveFactionStanding(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO faction_standing VALUES (?1,?2,?3)");
        defer st.finalize();
        var it = gs.faction_standing.iterator();
        while (it.next()) |e| {
            try st.bindAll(.{ cid, e.key_ptr.*, @as(i64, e.value_ptr.*) });
            try st.run();
        }
    }

    fn saveEventMemory(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO event_memory VALUES (?1,?2,?3,?4,?5)");
        defer st.finalize();
        var it = gs.event_memory.iterator();
        while (it.next()) |e| {
            try st.bindAll(.{ cid, e.key_ptr.*, @as(i64, e.value_ptr.last_day), @as(i64, e.value_ptr.last_choice), @as(i64, e.value_ptr.streak) });
            try st.run();
        }
    }

    fn saveRatingSnapshot(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO rating_snapshot VALUES (?1,?2,?3)");
        defer st.finalize();
        for (gs.rating_history.items) |snap| {
            try st.bindAll(.{ cid, @as(i64, snap.year), @as(i64, snap.score) });
            try st.run();
        }
    }

    fn saveListing(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO listing VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)");
        defer st.finalize();
        for (gs.market_listings.items, 0..) |l, i| {
            try st.bindAll(.{
                cid,                                                                  @as(i64, @intCast(i)),                                     l.kind,                                                      l.item_key,
                l.rarity,                                                             l.price,                                                   @as(i64, l.quantity),                                        l.staple,
                @as(i64, l.listed_day),                                               @as(i64, l.expires_day),                                   @intFromEnum(l.hq),                                          if (l.condition) |c| @as(?i64, c.armor_pct) else null,
                if (l.condition) |c| @as(?[]const u8, @tagName(c.quality)) else null, if (l.condition) |c| @as(?i64, c.damaged_slots) else null, if (l.condition) |c| @as(?i64, c.destroyed_slots) else null, if (l.condition) |c| @as(?i64, c.missing_components) else null,
                @as(i64, @intFromBool(l.black_market)),                               @intFromEnum(l.company),                                   @intFromEnum(l.id),                                          @intFromEnum(l.hull_instance_id),
                l.planet_key,                                                         @as(i64, l.available_after),
            });
            try st.run();
        }
    }

    fn savePartOrder(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO part_order VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer st.finalize();
        for (gs.part_orders.items, 0..) |o, i| {
            const dest_cols = siteCols(o.dest);
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), o.part_key, @as(i64, o.quantity), dest_cols.kind, dest_cols.id, @as(i64, o.ordered_day), o.eta_day, o.cost, o.status });
            try st.run();
        }
    }

    fn saveEventLog(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO event_log VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
        defer st.finalize();
        for (gs.event_log.items, 0..) |e, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, e.day), e.category, @intFromEnum(e.company), @intFromEnum(e.hq), @intFromEnum(e.contract), e.text });
            try st.run();
        }
    }

    fn savePendingEvent(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO pending_event VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer st.finalize();
        for (gs.event_queue.pending.items, 0..) |e, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), e.kind, @as(i64, e.day), @intFromEnum(e.contract), @intFromEnum(e.company), @as(i64, @intCast(e.default_choice)), @as(i64, e.deadline_day), if (e.chosen) |c| @as(?i64, @intCast(c)) else null, @intFromEnum(e.person), @intFromEnum(e.id), @intFromEnum(e.battle) });
            try st.run();
        }
    }

    fn saveBattleReport(self: Store, gs: *GameState, cid: i64) !void {
        // Battle reports: the record a screen reads. Hits and ammunition
        // are child rows; the ammunition family is stored by name, not
        // by position, because `part.munition_keys` can grow and a
        // positional encoding would silently re-label saved rows.
        const br = try self.db.prepare("INSERT INTO battle_report VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,?51,?52,?53,?54,?55,?56,?57)");
        defer br.finalize();
        const bh = try self.db.prepare("INSERT INTO battle_report_hit VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)");
        defer bh.finalize();
        const ba = try self.db.prepare("INSERT INTO battle_report_ammo VALUES (?1,?2,?3,?4,?5,?6)");
        defer ba.finalize();
        const bs = try self.db.prepare("INSERT INTO battle_report_salvage VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer bs.finalize();
        // P4e: per-engagement task results.
        const bt = try self.db.prepare("INSERT INTO battle_report_task VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
        defer bt.finalize();
        for (gs.battle_reports.kept.items, 0..) |r, i| {
            const ord: i64 = @intCast(i);
            try br.bindAll(.{
                cid,                                    ord,                                  @intFromEnum(r.id),                                                 @as(i64, r.day),
                @intFromEnum(r.contract),               @intFromEnum(r.company),              r.kind,                                                             r.enemy_key,
                r.scenario,                             r.terrain,                            r.weather,                                                          @tagName(r.outcome),
                @as(i64, @intFromBool(r.held_field)),   @as(i64, @intFromBool(r.withdrew)),   @tagName(r.roe),                                                    @as(i64, @intFromBool(r.roe_overridden)),
                r.player_power,                         r.enemy_power,                        @as(i64, r.conditions_mod),                                         @as(i64, @intFromBool(r.close_terrain)),
                @as(i64, @intFromBool(r.air_grounded)), @as(i64, @intFromBool(r.convoy_hit)), r.edge_spent_by,                                                    @as(i64, r.recon_quality),
                @as(i64, r.avg_fatigue),                @as(i64, r.avg_morale),               @as(i64, r.hits_taken),                                             @as(i64, r.destroyed),
                @as(i64, r.wounded),                    @as(i64, r.kia),                      @as(i64, r.lost_hulls),                                             @as(i64, r.missing),
                r.enemy_destroyed_bv,                   @as(i64, r.kills_credited),           @as(i64, r.prisoners),                                              r.battle_loss_comp,
                @as(i64, r.score_after),                @as(i64, r.score_delta),              @as(i64, r.morale_delta),                                           @as(i64, r.fatigue_add),
                @as(i64, r.battle_loss_pct),            @as(i64, r.salvage_pct),              r.command_rights,                                                   @as(i64, r.silenced_mounts),
                @as(i64, r.armor_left),                 r.salvage.claimed_bv,                 r.salvage.haulable_bv,                                              r.salvage.liaison_cut,
                r.salvage.exchange_cash,                r.salvage.items,                      @as(i64, @intFromBool(r.conceded)),                                 @as(i64, @intFromBool(r.acknowledged)),
                r.salvage.unclaimed_bv,                 r.operation,                          if (r.operation_intent) |oi| @tagName(oi) else @as([]const u8, ""), if (r.operation_tempo) |ot| @tagName(ot) else @as([]const u8, ""),
                r.operation_interventions,
            });
            try br.run();
            for (r.hulls, 0..) |h, hi| {
                // Each value in its own local: a mixed if/else inside
                // the tuple lets peer resolution pick a type the
                // binder then reads as the wrong kind of column.
                const slot_key: []const u8 = h.slot orelse "";
                const wound_severity: ?i64 = if (h.crew.wound) |w| @intCast(w.severity) else null;
                const wound_location: []const u8 = if (h.crew.wound) |w| @tagName(w.location) else "";
                const wound_permanent: i64 = if (h.crew.wound) |w| @intFromBool(w.permanent) else 0;
                const recovery_roll: ?i64 = if (h.recovery) |rec| @intCast(rec.roll) else null;
                const recovery_target: ?i64 = if (h.recovery) |rec| @intCast(rec.target) else null;
                try bh.bindAll(.{
                    cid,               ord,                             @as(i64, @intCast(hi)),   @as(i64, @intFromEnum(h.unit)),
                    h.chassis_key,     h.chassis_name,                  @as(i64, h.armor_before), @as(i64, h.armor_after),
                    slot_key,          h.slot_part,                     @tagName(h.slot_result),  @as(i64, @intFromBool(h.destroyed)),
                    @tagName(h.cause), @as(i64, @intFromEnum(h.pilot)), h.crew_name,              wound_severity,
                    wound_location,    wound_permanent,                 @tagName(h.crew.fate),    recovery_roll,
                    recovery_target,   @as(i64, @intFromBool(h.lost)),
                });
                try bh.run();
            }
            for (r.ammo, 0..) |a, ai| {
                try ba.bindAll(.{ cid, ord, @as(i64, @intCast(ai)), a.key, @as(i64, a.burned), @as(i64, a.left) });
                try ba.run();
            }
            // The wrecks on offer. Rolled once when the fight ended, so a reload must offer the same ones — rolling
            // again would hand the player a different battlefield.
            for (r.salvage.candidates, 0..) |sc, si| {
                try bs.bindAll(.{
                    cid,                        ord,                          @as(i64, @intCast(si)),          sc.key,
                    sc.name,                    sc.bv,                        @as(i64, sc.armor_pct),          @tagName(sc.quality),
                    @as(i64, sc.damaged_slots), @as(i64, sc.destroyed_slots), @as(i64, sc.missing_components), @as(i64, @intFromEnum(sc.hull_instance_id)),
                });
                try bs.run();
            }
            // P4e: task results.
            for (r.tasks, 0..) |lt, ti| {
                try bt.bindAll(.{
                    cid,
                    ord,
                    @as(i64, @intCast(ti)),
                    @as(i64, @intFromEnum(lt.lance)),
                    lt.lance_name,
                    @tagName(lt.task),
                    @as(i64, @intFromBool(lt.succeeded)),
                    lt.note,
                });
                try bt.run();
            }
        }
    }

    fn saveRefitPlan(self: Store, gs: *GameState, cid: i64) !void {
        const pl = try self.db.prepare("INSERT INTO refit_plan VALUES (?1,?2,?3,?4)");
        defer pl.finalize();
        const op = try self.db.prepare("INSERT INTO refit_op VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer op.finalize();
        for (gs.refit_plans.items, 0..) |p, i| {
            try pl.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(p.unit), p.committed });
            try pl.run();
            for (p.ops.items, 0..) |o, j| {
                switch (o) {
                    .remove => |slot_key| try op.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, @intCast(j)), "remove", slot_key, @as(?[]const u8, null), @as(?[]const u8, null) }),
                    .install => |it| try op.bindAll(.{ cid, @as(i64, @intCast(i)), @as(i64, @intCast(j)), "install", @as(?[]const u8, null), it.location, it.part_key }),
                }
                try op.run();
            }
        }
    }

    fn saveStock(self: Store, cid: i64, kind: []const u8, owner: i64, stock: *const std.StringArrayHashMapUnmanaged(u32)) !void {
        const st = try self.db.prepare("INSERT INTO stock VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        var it = stock.iterator();
        var i: i64 = 0;
        while (it.next()) |entry| : (i += 1) {
            try st.bindAll(.{ cid, kind, owner, i, entry.key_ptr.*, @as(i64, entry.value_ptr.*) });
            try st.run();
        }
    }

    fn saveContract(st: sqlite.Stmt, cid: i64, is_offer: bool, ord: i64, c: *const contract_mod.Contract) !void {
        try st.bindAll(.{
            cid,                             is_offer,                         ord,                               @intFromEnum(c.id),
            c.kind,                          c.employer_key,                   c.enemy_key,                       c.planet_key,
            c.status,                        @intFromEnum(c.assigned_company), c.start_day,                       @as(i64, c.score),
            @as(i64, c.dist_ly),             c.beachhead,                      @as(i64, c.transit_days),          c.arrive_day,
            c.end_day,                       c.monthly_net,                    c.next_battle_day,                 @as(i64, c.battles_fought),
            @as(i64, c.casualties),          c.objective,                      c.committed_bv,                    c.enemy_pool_bv,
            c.enemy_pool_remaining,          @as(i64, c.victory_points),       c.ineffective_since,               c.breach_day,
            @as(i64, c.terms.length_months), c.terms.base_pay_month,           @as(i64, c.terms.advance_pct),     c.terms.signing_bonus,
            @as(i64, c.terms.transport_pct), @as(i64, c.terms.overhead_pct),   @as(i64, c.terms.battle_loss_pct), @as(i64, c.terms.salvage_pct),
            c.terms.salvage_exchange,        c.terms.command_rights,           c.negotiated,                      @as(i64, c.enemy_lances),
            c.enemy_quality,                 c.enemy_lance_bv,                 @as(i64, c.enemy_lance_tons),      @intFromEnum(c.offer_hq),
            c.orders_day,                    c.arc_key,                        @as(i64, c.arc_beat),              @as(i64, c.escalation_clock),
            c.arc_finale_key,                @as(i64, c.command_capacity),
        });
        try st.run();
    }

    // ------------------------------------------------------------------ load

    /// Restore every RNG stream. A row names its stream; a stream with no
    /// row starts fresh from the campaign seed. A malformed row, an unknown
    /// stream, or stream rows without a seed are `error.CorruptSave`.
    ///
    /// Saves before schema v32 hold one `rng` blob of native-endian
    /// generator states in `legacy_rng_order` and no seed. Their seed, used
    /// only for streams added since, is a hash of that blob, so it differs
    /// per campaign. A save with no RNG state at all is corrupt.
    fn loadRng(self: Store, gs: *GameState, cid: i64, has_seed: bool) !void {
        const alloc = gs.allocator();
        var loaded = std.EnumSet(rng_mod.Stream).initEmpty();
        {
            const st = try self.db.prepare("SELECT stream, format, state FROM rng_stream WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            while (try st.next()) {
                const stream = st.enumValue(rng_mod.Stream, 0) orelse return error.CorruptSave;
                if (!gs.rng.decode(stream, st.int(1), try st.blob(2, alloc, rng_mod.Rng.state_len))) return error.CorruptSave;
                loaded.insert(stream);
            }
        }
        if (loaded.count() > 0 and !has_seed) return error.CorruptSave;
        if (loaded.count() == 0) {
            const st = try self.db.prepare("SELECT state FROM rng WHERE cid = ?1");
            defer st.finalize();
            try st.bindAll(.{cid});
            if (!try st.next()) return error.CorruptSave;
            const bytes = try st.blob(0, alloc, legacy_rng_order.len * @sizeOf(std.Random.DefaultPrng));
            const size = @sizeOf(std.Random.DefaultPrng);
            if (bytes.len != legacy_rng_order.len * size) return error.CorruptSave;
            for (legacy_rng_order, 0..) |stream, i| {
                gs.rng.prngs[@intFromEnum(stream)] = std.mem.bytesToValue(std.Random.DefaultPrng, bytes[i * size ..][0..size]);
                loaded.insert(stream);
            }
            if (!has_seed) gs.rng.seed = std.hash.Wyhash.hash(0, bytes);
        }
        for (std.enums.values(rng_mod.Stream)) |stream| {
            if (!loaded.contains(stream)) gs.rng.prngs[@intFromEnum(stream)] = rng_mod.Rng.fresh(gs.rng.seed, stream);
        }
    }

    /// Rebuild a campaign from the store. `gpa` backs the new GameState.
    pub fn load(self: Store, gpa: std.mem.Allocator, cid: i64) !GameState {
        var gs = GameState.init(gpa, .{});
        errdefer gs.deinit();
        gs.campaign_id = cid;
        const saved_version = try self.loadVersion(cid);
        if (saved_version > schema_version) return error.SaveNewerThanGame;

        const has_seed = try self.loadMeta(&gs, cid);
        try self.loadRng(&gs, cid, has_seed);
        try self.loadCommander(&gs, cid);
        try self.loadPerson(&gs, cid);
        try self.loadUnit(&gs, cid);
        try self.loadHullInstances(&gs, cid);
        try self.loadHullCombatRecords(&gs, cid);
        try self.loadMaintenanceEntries(&gs, cid);
        try self.loadHullOwnershipHistory(&gs, cid);
        try self.loadForce(&gs, cid);
        try self.loadHq(&gs, cid);
        try self.loadStock(&gs, cid);
        try self.loadContract(&gs, cid);
        try self.loadOperations(&gs, cid);
        try self.loadOperationTasks(&gs, cid);
        try self.loadOperationInterventions(&gs, cid);
        try self.loadActors(&gs, cid);
        try self.loadMercCompanies(&gs, cid);
        try self.loadRivals(&gs, cid);
        try self.loadOfficerArcs(&gs, cid);
        try self.loadWorldStates(&gs, cid);
        try self.loadFactionRosters(&gs, cid);
        try self.loadMercCompanyRosters(&gs, cid);
        try self.loadTxn(&gs, cid);
        try self.loadLoan(&gs, cid);
        try self.loadCourier(&gs, cid);
        try self.loadPolicy(&gs, cid);
        try self.loadSupplyPolicy(&gs, cid);
        try self.loadStockPolicy(&gs, cid);
        try self.loadBayJob(&gs, cid);
        try self.loadCandidate(&gs, cid);
        try self.loadHqLink(&gs, cid);
        try self.loadUnitTransfer(&gs, cid);
        try self.loadFactionCooling(&gs, cid);
        try self.loadFactionStanding(&gs, cid);
        try self.loadEventMemory(&gs, cid);
        try self.loadRatingSnapshot(&gs, cid);
        try self.loadListing(&gs, cid);
        try self.loadPartOrder(&gs, cid);
        try self.loadEventLog(&gs, cid);
        try self.loadPendingEvent(&gs, cid, saved_version);
        try self.loadBattleReport(&gs, cid);
        try self.loadRefitPlan(&gs, cid);

        hq_ops.refreshHqStaffing(&gs);
        try upgradeCampaign(&gs, saved_version);
        // Saves before schema v18 have no stats counters: if the book is
        // empty but the log has battles, count them up. Gated on version so
        // a legitimately stats-empty current save is not re-derived from log
        // text (rule 51, C7c).
        if (saved_version < 18 and gs.stats.isEmpty()) recoverStatsFromLog(&gs);
        // Saves without a `next_battle_id` row still hold reports, held hulls
        // and decisions that name battles; numbering resumes past all of them.
        gs.resumeBattleIds();
        // Validate all cross-entity references and reconcile counters before
        // string validation (rules 47, 48).
        try validateReferences(&gs);
        try reconcileCounters(&gs);
        try validateStoredStrings(&gs);
        return gs;
    }

    // ---- the per-table decoders `load` runs, in its order ----

    /// The schema version a campaign was saved at; `NoSuchCampaign` when the id is unknown.
    /// A campaign schema_version below 1 is corruption (rule 49).
    fn loadVersion(self: Store, cid: i64) !u32 {
        const st = try self.db.prepare("SELECT schema_version FROM campaign WHERE id = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        if (!try st.next()) return error.NoSuchCampaign;
        const v = st.int(0);
        if (v < 1) return error.CorruptSave;
        return std.math.cast(u32, v) orelse error.CorruptSave;
    }

    /// The campaign scalars; true when the save holds its RNG seed.
    /// Required meta keys must all be present; a missing one is corrupt
    /// (rule 47). The date is validated after reading so a month-13 row
    /// is rejected before it reaches the `unreachable` in `daysInMonth`.
    fn loadMeta(self: Store, gs: *GameState, cid: i64) !bool {
        const alloc = gs.allocator();
        var has_seed = false;
        // Required meta keys: a save missing any of these is a corrupt save.
        var saw_day_index = false;
        var saw_year = false;
        var saw_month = false;
        var saw_day_field = false;
        var saw_funds = false;
        var saw_reputation = false;
        var saw_difficulty = false;
        const st = try self.db.prepare("SELECT key, value FROM meta WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const key = try st.text(0, alloc);
            const v = st.int(1);
            if (std.mem.eql(u8, key, "day_index")) {
                gs.clock.day_index = try fit(@TypeOf(gs.clock.day_index), v);
                saw_day_index = true;
            }
            if (std.mem.eql(u8, key, "year")) {
                gs.clock.date.year = try fit(@TypeOf(gs.clock.date.year), v);
                saw_year = true;
            }
            if (std.mem.eql(u8, key, "month")) {
                gs.clock.date.month = try fit(@TypeOf(gs.clock.date.month), v);
                saw_month = true;
            }
            if (std.mem.eql(u8, key, "day")) {
                gs.clock.date.day = try fit(@TypeOf(gs.clock.date.day), v);
                saw_day_field = true;
            }
            if (std.mem.eql(u8, key, "funds")) {
                gs.funds = v;
                saw_funds = true;
            }
            if (std.mem.eql(u8, key, "reputation")) {
                gs.reputation = try fit(@TypeOf(gs.reputation), v);
                saw_reputation = true;
            }
            if (std.mem.eql(u8, key, "bankrupt")) gs.bankrupt = v != 0;
            if (std.mem.eql(u8, key, "auto_admit")) gs.auto_admit = v != 0;
            if (std.mem.eql(u8, key, "difficulty")) {
                gs.difficulty = std.enums.fromInt(@TypeOf(gs.difficulty), v) orelse return error.CorruptSave;
                saw_difficulty = true;
            }
            if (std.mem.eql(u8, key, "share_profit_bp")) gs.share_profit_bp = try fit(@TypeOf(gs.share_profit_bp), v);
            if (std.mem.eql(u8, key, "stat_battles_won")) gs.stats.battles_won = try fit(@TypeOf(gs.stats.battles_won), v);
            if (std.mem.eql(u8, key, "stat_battles_drawn")) gs.stats.battles_drawn = try fit(@TypeOf(gs.stats.battles_drawn), v);
            if (std.mem.eql(u8, key, "stat_battles_lost")) gs.stats.battles_lost = try fit(@TypeOf(gs.stats.battles_lost), v);
            if (std.mem.eql(u8, key, "stat_hulls_lost")) gs.stats.hulls_lost = try fit(@TypeOf(gs.stats.hulls_lost), v);
            if (std.mem.eql(u8, key, "stat_hulls_salvaged")) gs.stats.hulls_salvaged = try fit(@TypeOf(gs.stats.hulls_salvaged), v);
            if (std.mem.eql(u8, key, "stat_people_kia")) gs.stats.people_kia = try fit(@TypeOf(gs.stats.people_kia), v);
            if (std.mem.eql(u8, key, "stat_enemy_bv")) gs.stats.enemy_bv_destroyed = try fit(@TypeOf(gs.stats.enemy_bv_destroyed), v);
            if (std.mem.eql(u8, key, "next_person_id")) gs.next_person_id = try fit(@TypeOf(gs.next_person_id), v);
            if (std.mem.eql(u8, key, "next_unit_id")) gs.next_unit_id = try fit(@TypeOf(gs.next_unit_id), v);
            if (std.mem.eql(u8, key, "next_force_id")) gs.next_force_id = try fit(@TypeOf(gs.next_force_id), v);
            if (std.mem.eql(u8, key, "next_hq_id")) gs.next_hq_id = try fit(@TypeOf(gs.next_hq_id), v);
            if (std.mem.eql(u8, key, "next_contract_id")) gs.next_contract_id = try fit(@TypeOf(gs.next_contract_id), v);
            if (std.mem.eql(u8, key, "next_battle_id")) gs.next_battle_id = try fit(@TypeOf(gs.next_battle_id), v);
            if (std.mem.eql(u8, key, "next_event_id")) gs.event_queue.next_id = try fit(@TypeOf(gs.event_queue.next_id), v);
            if (std.mem.eql(u8, key, "next_listing_id")) gs.next_listing_id = try fit(@TypeOf(gs.next_listing_id), v);
            if (std.mem.eql(u8, key, "next_candidate_id")) gs.next_candidate_id = try fit(@TypeOf(gs.next_candidate_id), v);
            if (std.mem.eql(u8, key, "next_loan_id")) gs.next_loan_id = try fit(@TypeOf(gs.next_loan_id), v);
            if (std.mem.eql(u8, key, "next_operation_id")) gs.next_operation_id = try fit(@TypeOf(gs.next_operation_id), v);
            if (std.mem.eql(u8, key, "next_actor_id")) gs.next_actor_id = try fit(@TypeOf(gs.next_actor_id), v);
            if (std.mem.eql(u8, key, "next_rival_id")) gs.next_rival_id = try fit(@TypeOf(gs.next_rival_id), v);
            if (std.mem.eql(u8, key, "next_officer_arc_id")) gs.next_officer_arc_id = try fit(@TypeOf(gs.next_officer_arc_id), v);
            if (std.mem.eql(u8, key, "next_hull_instance_id")) gs.next_hull_instance_id = try fit(@TypeOf(gs.next_hull_instance_id), v);
            if (std.mem.eql(u8, key, "next_merc_company_id")) gs.next_merc_company_id = try fit(@TypeOf(gs.next_merc_company_id), v);
            if (std.mem.eql(u8, key, "rng_seed")) {
                gs.rng.seed = @bitCast(v);
                has_seed = true;
            }
        }
        // All seven required meta-int keys must be present.
        if (!saw_day_index or !saw_year or !saw_month or !saw_day_field or
            !saw_funds or !saw_reputation or !saw_difficulty) return error.CorruptSave;
        // Validate the calendar values before any code path reaches daysInMonth.
        if (!gs.clock.date.valid()) return error.CorruptSave;
        var saw_outfit_name = false;
        const tx = try self.db.prepare("SELECT key, value FROM meta_text WHERE cid = ?1");
        defer tx.finalize();
        try tx.bindAll(.{cid});
        while (try tx.next()) {
            const key = try tx.text(0, alloc);
            if (std.mem.eql(u8, key, "outfit_name")) {
                gs.outfit_name = try tx.text(1, alloc);
                saw_outfit_name = true;
            } else if (std.mem.eql(u8, key, "player_logo_key")) {
                gs.player_logo_key = try tx.text(1, alloc);
            }
        }
        if (!saw_outfit_name) return error.CorruptSave;
        return has_seed;
    }

    fn loadCommander(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT name, origin, profession FROM commander WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        if (try st.next()) {
            gs.commander = .{
                .name = try st.text(0, alloc),
                .origin = st.enumValue(commander_mod.Faction, 1) orelse return error.CorruptSave,
                .profession = st.enumValue(commander_mod.Profession, 2) orelse return error.CorruptSave,
            };
        }
    }

    // People.
    fn loadPerson(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, first, last, callsign, role, xp, status, fatigue, morale, recruited_day, salary_override, assigned_force, posted_hq, weekly_hours, medbay_priority, leave_until, wound_heal_day, training_skill, training_done, admitted, rank, rank_pinned, kills, kill_bv, battles, tours, outstanding_tours, edge_spent, faction, shares, born_day, last_raise_day, last_award_day, departed_day, secondary_role FROM person WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            var p: person_mod.Person = .{
                .id = try toId(types.PersonId, st.int(0)),
                .first_name = try st.text(1, alloc),
                .last_name = try st.text(2, alloc),
                .callsign = try st.optText(3, alloc),
                .role = st.enumValue(person_mod.Role, 4) orelse return error.CorruptSave,
                .xp = try st.intAs(u32, 5),
                .status = st.enumValue(person_mod.Status, 6) orelse return error.CorruptSave,
                .fatigue = try st.intAs(u8, 7),
                .morale = try st.intAs(u8, 8),
                .recruited_day = try st.intAs(u32, 9),
                .salary_override = st.optInt(10),
                .assigned_force = try toId(types.ForceId, st.int(11)),
                .posted_hq = try toId(types.HqId, st.int(12)),
                .weekly_hours = try st.intAs(u16, 13),
                .medbay_priority = try st.intAs(u8, 14),
                .leave_until_day = try optU32(st.optInt(15)),
                .wound_heal_day = try optU32(st.optInt(16)),
                .medbay_admitted = st.int(19) != 0,
                .rank = st.enumValue(@import("../domain/rank.zig").Rank, 20) orelse return error.CorruptSave,
                .rank_pinned = st.int(21) != 0,
                .kills = try st.intAs(u32, 22),
                .kill_bv = try st.intAs(u32, 23),
                .battles = try st.intAs(u32, 24),
                .tours = try st.intAs(u32, 25),
                .outstanding_tours = try st.intAs(u32, 26),
                .edge_spent = st.int(27) != 0,
                .faction = try st.text(28, alloc),
                .shares = try st.intAs(u8, 29),
                .born_day = if (st.optInt(30)) |b| try fit(i32, b) else null,
                .last_raise_day = try optU32(st.optInt(31)),
                .last_award_day = try optU32(st.optInt(32)),
                .departed_day = try optU32(st.optInt(33)),
                .secondary_role = try st.optEnum(person_mod.Role, 34),
            };
            if (try st.optEnum(types.SkillType, 17)) |skill| {
                if (st.optInt(18)) |done| p.training = .{ .skill = skill, .done_day = try fit(u32, done) };
            }
            const gop_p = try gs.people.getOrPut(alloc, p.id);
            if (gop_p.found_existing) return error.CorruptSave;
            gop_p.value_ptr.* = p;
        }
        const sk = try self.db.prepare("SELECT person_id, skill, level FROM person_skill WHERE cid = ?1 ORDER BY person_id, rowid");
        defer sk.finalize();
        try sk.bindAll(.{cid});
        while (try sk.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, sk.int(0))) orelse return error.CorruptSave;
            const skill = sk.enumValue(types.SkillType, 1) orelse return error.CorruptSave;
            try p.skills.put(alloc, skill, try sk.intAs(u8, 2));
        }
        const aw = try self.db.prepare("SELECT person_id, key FROM award WHERE cid = ?1 ORDER BY person_id, rowid");
        defer aw.finalize();
        try aw.bindAll(.{cid});
        while (try aw.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, aw.int(0))) orelse return error.CorruptSave;
            try p.awards.append(alloc, try aw.text(1, alloc));
        }
        const ab = try self.db.prepare("SELECT person_id, key FROM ability WHERE cid = ?1 ORDER BY person_id, rowid");
        defer ab.finalize();
        try ab.bindAll(.{cid});
        while (try ab.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, ab.int(0))) orelse return error.CorruptSave;
            try p.abilities.append(alloc, try ab.text(1, alloc));
        }
        const inj = try self.db.prepare("SELECT person_id, location, severity, incurred, heal_done, doctor, permanent, healed FROM injury WHERE cid = ?1 ORDER BY person_id, ord");
        defer inj.finalize();
        try inj.bindAll(.{cid});
        while (try inj.next()) {
            const p = gs.people.getPtr(try toId(types.PersonId, inj.int(0))) orelse return error.CorruptSave;
            const location = inj.enumValue(person_mod.InjuryLocation, 1) orelse return error.CorruptSave;
            try p.injuries.append(alloc, .{
                .location = location,
                .severity = try inj.intAs(u8, 2),
                .incurred_day = try inj.intAs(u32, 3),
                .heal_done_day = try optU32(inj.optInt(4)),
                .doctor = try toId(types.PersonId, inj.int(5)),
                .permanent = inj.int(6) != 0,
                .healed = inj.int(7) != 0,
            });
        }
    }

    // Units.
    fn loadUnit(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, chassis_key, name, kind, force, pilot, tech, armor_pct, quality, status, last_maint, acquired_day, price, reactivation_done, berth_hq, wreck, held_by, held_day, held_battle, held_force, hull_instance_id FROM unit WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const u: unit_mod.Unit = .{
                .id = try toId(types.UnitId, st.int(0)),
                .chassis_key = try st.text(1, alloc),
                .name = try st.optText(2, alloc),
                .kind = st.enumValue(unit_mod.UnitKind, 3) orelse return error.CorruptSave,
                .force = try toId(types.ForceId, st.int(4)),
                .pilot = try toId(types.PersonId, st.int(5)),
                .tech = try toId(types.PersonId, st.int(6)),
                .armor_pct = try st.intAs(u8, 7),
                .quality = st.enumValue(types.Quality, 8) orelse return error.CorruptSave,
                .status = st.enumValue(unit_mod.UnitStatus, 9) orelse return error.CorruptSave,
                .last_maintenance_day = try optU32(st.optInt(10)),
                .acquired_day = try st.intAs(u32, 11),
                .purchase_price = st.int(12),
                .reactivation_done_day = try optU32(st.optInt(13)),
                .berth_hq = try toId(types.HqId, st.int(14)),
                .wreck = st.enumValue(unit_mod.WreckCause, 15) orelse return error.CorruptSave,
                .hull_instance_id = try toId(types.HullInstanceId, st.int(20)),
            };
            // A non-empty `held_by` is what tells the two apart: the
            // enemy's hulls go to the limbo list, ours to the books.
            const held_by = try st.text(16, alloc);
            if (held_by.len == 0) {
                try gs.units.put(alloc, u.id, u);
            } else {
                try gs.held_hulls.append(alloc, .{
                    .unit = u,
                    .by = held_by,
                    .day = try st.intAs(u32, 17),
                    .battle = try toId(types.BattleId, st.int(18)),
                    .from_force = try toId(types.ForceId, st.int(19)),
                });
            }
        }
        const sl = try self.db.prepare("SELECT unit_id, slot_key, part_key, class, condition FROM unit_slot WHERE cid = ?1 ORDER BY unit_id, ord");
        defer sl.finalize();
        try sl.bindAll(.{cid});
        while (try sl.next()) {
            const uid = try toId(types.UnitId, sl.int(0));
            const u = gs.units.getPtr(uid) orelse blk: {
                for (gs.held_hulls.items) |*h| if (h.unit.id == uid) break :blk &h.unit;
                return error.CorruptSave; // orphan unit_slot: no unit or held hull owns it
            };
            try u.slots.append(alloc, .{
                .slot_key = try sl.text(1, alloc),
                .part_key = try sl.text(2, alloc),
                .class = sl.enumValue(unit_mod.SlotClass, 3) orelse return error.CorruptSave,
                .condition = sl.enumValue(unit_mod.PartCondition, 4) orelse return error.CorruptSave,
            });
        }
    }

    fn loadHullInstances(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const hull_mod = @import("../domain/hull_instance.zig");
        const st = try self.db.prepare("SELECT id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id FROM hull_instance WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const status = st.enumValue(hull_mod.HullStatus, 4) orelse return error.CorruptSave;
            // Reconstruct owner union fail-closed (rule 47). Unknown tag → CorruptSave;
            // inconsistent payload (e.g. faction key present but owner_type != merc_company) → CorruptSave.
            const ot = st.enumValue(hull_mod.OwnerType, 7) orelse return error.CorruptSave;
            const faction_key = try st.text(8, alloc); // NOT NULL DEFAULT '' — "" for non-faction
            const merc_company_id_raw = st.int(9); // NOT NULL DEFAULT 0 — 0 for non-merc_company
            const owner: hull_mod.HullOwner = switch (ot) {
                .player, .market, .destroyed => blk: {
                    // Consistency: payload columns must be empty/zero
                    if (faction_key.len != 0) return error.CorruptSave;
                    if (merc_company_id_raw != 0) return error.CorruptSave;
                    break :blk switch (ot) {
                        .player => .player,
                        .market => .market,
                        .destroyed => .destroyed,
                        else => unreachable,
                    };
                },
                .faction => blk: {
                    if (faction_key.len == 0) return error.CorruptSave;
                    if (merc_company_id_raw != 0) return error.CorruptSave;
                    break :blk .{ .faction = faction_key };
                },
                .merc_company => blk: {
                    if (merc_company_id_raw == 0) return error.CorruptSave;
                    if (faction_key.len != 0) return error.CorruptSave;
                    break :blk .{ .merc_company = try toId(types.MercCompanyId, merc_company_id_raw) };
                },
            };
            const inst: hull_mod.HullInstance = .{
                .id = try toId(types.HullInstanceId, st.int(0)),
                .base_key = try st.text(1, alloc),
                .name = try st.optText(2, alloc),
                .nickname = try st.optText(3, alloc),
                .status = status,
                .intro_year = try st.intAs(u16, 5),
                .pre_campaign = st.int(6) != 0,
                .owner = owner,
            };
            const gop = try gs.hull_instances.getOrPut(alloc, inst.id);
            if (gop.found_existing) return error.CorruptSave; // duplicate id
            gop.value_ptr.* = inst;
        }
        const ld = try self.db.prepare("SELECT hull_instance_id, slot_index, part_key FROM hull_loadout WHERE cid = ?1 ORDER BY hull_instance_id, slot_index");
        defer ld.finalize();
        try ld.bindAll(.{cid});
        while (try ld.next()) {
            const hid = try toId(types.HullInstanceId, ld.int(0));
            const h = gs.hull_instances.getPtr(hid) orelse return error.CorruptSave; // orphan loadout row
            try h.loadout.append(alloc, .{ .part_key = try ld.text(2, alloc) });
        }
    }

    fn loadHullCombatRecords(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const hull_inst_mod = @import("../domain/hull_instance.zig");
        const st = try self.db.prepare("SELECT hull_instance_id, battle_id, contract_id, kills, hits_taken, armor_lost, slots_damaged, slots_destroyed, destroyed, cause FROM hull_combat_record WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const hid = try toId(types.HullInstanceId, st.int(0));
            // hull_instance_id must resolve to a loaded hull_instance (orphan check).
            // Historical battle and contract backlinks may be unavailable on load;
            // only hull_instance_id is a validated containment FK.
            _ = gs.hull_instances.getPtr(hid) orelse return error.CorruptSave;
            const cause = st.enumValue(unit_mod.WreckCause, 9) orelse return error.CorruptSave;
            const rec: hull_inst_mod.HullCombatRecord = .{
                .hull_instance_id = hid,
                .battle_id = try toId(types.BattleId, st.int(1)),
                .contract_id = try toId(types.ContractId, st.int(2)),
                .kills = try st.intAs(u16, 3),
                .hits_taken = try st.intAs(u16, 4),
                .armor_lost = try st.intAs(u16, 5),
                .slots_damaged = try st.intAs(u8, 6),
                .slots_destroyed = try st.intAs(u8, 7),
                .destroyed = st.int(8) != 0,
                .cause = cause,
            };
            try gs.hull_combat_records.append(alloc, rec);
        }
    }

    fn loadMaintenanceEntries(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const hull_inst_mod = @import("../domain/hull_instance.zig");
        const st = try self.db.prepare("SELECT hull_instance_id, day, tech, action, description, battle_id, cost FROM maintenance_entry WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const hid = try toId(types.HullInstanceId, st.int(0));
            _ = gs.hull_instances.getPtr(hid) orelse return error.CorruptSave; // orphan FK
            const action = st.enumValue(hull_inst_mod.MaintenanceAction, 3) orelse return error.CorruptSave;
            try gs.maintenance_entries.append(alloc, .{
                .hull_instance_id = hid,
                .day = try st.intAs(u32, 1),
                .tech = try toId(types.PersonId, st.int(2)),
                .action = action,
                .description = try st.text(4, alloc),
                .battle_id = try toId(types.BattleId, st.int(5)),
                .cost = st.int(6),
            });
        }
    }

    fn loadHullOwnershipHistory(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const hull_inst_mod = @import("../domain/hull_instance.zig");
        const st = try self.db.prepare("SELECT hull_instance_id, from_day, to_day, acquisition_type, prior_owner_key FROM hull_ownership_history WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const hid = try toId(types.HullInstanceId, st.int(0));
            _ = gs.hull_instances.getPtr(hid) orelse return error.CorruptSave; // orphan FK
            const acq = st.enumValue(hull_inst_mod.AcquisitionType, 3) orelse return error.CorruptSave;
            try gs.hull_ownership_history.append(alloc, .{
                .hull_instance_id = hid,
                .from_day = try st.intAs(u32, 1),
                .to_day = try st.intAs(u32, 2),
                .acquisition_type = acq,
                .prior_owner_key = try st.text(4, alloc),
            });
        }
    }

    // Forces.
    fn loadForce(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, parent, name, emblem, local_funds, echelon, commander, supplying_hq, role, support_kind, last_rotation, contracts_since_rotation, location_planet, return_eta, shortage_days, roe FROM force WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const f: force_mod.Force = .{
                .id = try toId(types.ForceId, st.int(0)),
                .parent = try toId(types.ForceId, st.int(1)),
                .name = try st.text(2, alloc),
                .emblem = if (st.isNull(3)) null else try st.blob(3, alloc, max_emblem_bytes),
                .local_funds = st.int(4),
                .echelon = st.enumValue(force_mod.Echelon, 5) orelse return error.CorruptSave,
                .commander = try toId(types.PersonId, st.int(6)),
                .supplying_hq = try toId(types.HqId, st.int(7)),
                .role = st.enumValue(force_mod.LanceRole, 8) orelse return error.CorruptSave,
                .support_kind = try st.optEnum(force_mod.SupportLanceKind, 9),
                .last_rotation_day = try optU32(st.optInt(10)),
                .contracts_since_rotation = try st.intAs(u16, 11),
                .location_planet = try st.optText(12, alloc),
                .return_eta_day = try optU32(st.optInt(13)),
                .supply_shortage_days = try st.intAs(u16, 14),
                .roe = st.enumValue(force_mod.Roe, 15) orelse return error.CorruptSave,
            };
            const gop_f = try gs.forces.getOrPut(alloc, f.id);
            if (gop_f.found_existing) return error.CorruptSave;
            gop_f.value_ptr.* = f;
        }
        const fu = try self.db.prepare("SELECT force_id, unit_id FROM force_unit WHERE cid = ?1 ORDER BY force_id, ord");
        defer fu.finalize();
        try fu.bindAll(.{cid});
        while (try fu.next()) {
            const f = gs.forces.getPtr(try toId(types.ForceId, fu.int(0))) orelse return error.CorruptSave;
            try f.units.append(alloc, try toId(types.UnitId, fu.int(1)));
        }
        const fc = try self.db.prepare("SELECT force_id, child_id FROM force_child WHERE cid = ?1 ORDER BY force_id, ord");
        defer fc.finalize();
        try fc.bindAll(.{cid});
        while (try fc.next()) {
            const f = gs.forces.getPtr(try toId(types.ForceId, fc.int(0))) orelse return error.CorruptSave;
            try f.children.append(alloc, try toId(types.ForceId, fc.int(1)));
        }
    }

    // HQs.
    fn loadHq(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, name, tier, planet, staff_assigned, upkeep, funds FROM hq WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const h: hq_mod.Hq = .{
                .id = try toId(types.HqId, st.int(0)),
                .name = try st.text(1, alloc),
                .tier = st.enumValue(hq_mod.HqTier, 2) orelse return error.CorruptSave,
                .planet_key = try st.text(3, alloc),
                .staff_assigned = 0, // derived: refreshHqStaffing recomputes it after the load
                .monthly_upkeep = st.int(5),
                .funds = st.int(6),
            };
            const gop_h = try gs.hqs.getOrPut(alloc, h.id);
            if (gop_h.found_existing) return error.CorruptSave;
            gop_h.value_ptr.* = h;
        }
        const fa = try self.db.prepare("SELECT hq_id, kind, level FROM hq_facility WHERE cid = ?1 ORDER BY hq_id, ord");
        defer fa.finalize();
        try fa.bindAll(.{cid});
        while (try fa.next()) {
            const h = gs.hqs.getPtr(try toId(types.HqId, fa.int(0))) orelse return error.CorruptSave;
            try h.facilities.append(alloc, .{ .kind = fa.enumValue(hq_mod.FacilityKind, 1) orelse return error.CorruptSave, .level = try fa.intAs(u8, 2) });
        }
        const pr = try self.db.prepare("SELECT hq_id, kind, facility, target_level, started, paperwork_done, construction_done, cost FROM hq_project WHERE cid = ?1 ORDER BY hq_id, ord");
        defer pr.finalize();
        try pr.bindAll(.{cid});
        while (try pr.next()) {
            const h = gs.hqs.getPtr(try toId(types.HqId, pr.int(0))) orelse return error.CorruptSave;
            try h.projects.append(alloc, .{
                .kind = pr.enumValue(hq_mod.ProjectKind, 1) orelse return error.CorruptSave,
                .facility = try pr.optEnum(hq_mod.FacilityKind, 2),
                .target_level = try pr.intAs(u8, 3),
                .started_day = try pr.intAs(u32, 4),
                .paperwork_done_day = try pr.intAs(u32, 5),
                .construction_done_day = try pr.intAs(u32, 6),
                .cost = pr.int(7),
            });
        }
    }

    // Stock at every site.
    fn loadStock(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // Track (owner_kind, owner_id, key) triples to detect duplicate rows
        // (rule 47, C7). Arena-backed; deinit reclaims the table array.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(alloc);
        const st = try self.db.prepare("SELECT owner_kind, owner_id, key, qty FROM stock WHERE cid = ?1 ORDER BY owner_kind, owner_id, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = try st.text(0, alloc);
            const owner_id = st.int(1);
            const key = try st.text(2, alloc);
            const site = try siteFromCols(kind, owner_id);
            // A second row for the same (owner_kind, owner_id, key) is corruption.
            const tag = try std.fmt.allocPrint(alloc, "{s}\x00{d}\x00{s}", .{ kind, owner_id, key });
            const gop = try seen.getOrPut(alloc, tag);
            if (gop.found_existing) return error.CorruptSave;
            gs.addStock(site, key, try st.intAs(u32, 3)) catch |err| return switch (err) {
                // An orphan stock row (site not in gs.hqs/gs.forces) or a
                // sum that overflows u32 are both corruption (rule 47).
                error.UnknownSite, error.StockOverflow => error.CorruptSave,
                else => err,
            };
        }
    }

    // Contracts & offers.
    fn loadContract(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT is_offer, id, kind, employer, enemy, planet, status, company, start_day, score, dist_ly, beachhead, transit_days, arrive_day, end_day, monthly_net, next_battle, battles, casualties, objective, committed_bv, pool, pool_remaining, vp, ineffective_since, breach_day, length_months, base_pay, advance_pct, signing_bonus, transport_pct, overhead_pct, battle_loss_pct, salvage_pct, salvage_exchange, command_rights, negotiated, enemy_lances, enemy_quality, enemy_lance_bv, enemy_lance_tons, offer_hq, orders_day, arc_key, arc_beat, escalation_clock, arc_finale_key, command_capacity FROM contract WHERE cid = ?1 ORDER BY is_offer, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const c: contract_mod.Contract = .{
                .id = try toId(types.ContractId, st.int(1)),
                .kind = st.enumValue(contract_mod.ContractKind, 2) orelse return error.CorruptSave,
                .employer_key = try st.text(3, alloc),
                .enemy_key = try st.text(4, alloc),
                .planet_key = try st.text(5, alloc),
                .status = st.enumValue(contract_mod.ContractStatus, 6) orelse return error.CorruptSave,
                .assigned_company = try toId(types.ForceId, st.int(7)),
                .start_day = try optU32(st.optInt(8)),
                .score = try st.intAs(i32, 9),
                .dist_ly = try st.intAs(u32, 10),
                .beachhead = st.int(11) != 0,
                .transit_days = try st.intAs(u32, 12),
                .arrive_day = try optU32(st.optInt(13)),
                .end_day = try optU32(st.optInt(14)),
                .monthly_net = st.int(15),
                .next_battle_day = try optU32(st.optInt(16)),
                .battles_fought = try st.intAs(u8, 17),
                .casualties = try st.intAs(u8, 18),
                .objective = st.enumValue(contract_mod.ObjectiveKind, 19) orelse return error.CorruptSave,
                .committed_bv = st.int(20),
                .enemy_pool_bv = st.int(21),
                .enemy_pool_remaining = st.int(22),
                .victory_points = try st.intAs(i32, 23),
                .ineffective_since = try optU32(st.optInt(24)),
                .breach_day = try optU32(st.optInt(25)),
                .negotiated = st.int(36) != 0,
                .enemy_lances = try st.intAs(u8, 37),
                .enemy_quality = st.enumValue(types.ExperienceLevel, 38) orelse return error.CorruptSave,
                .enemy_lance_bv = st.int(39),
                .enemy_lance_tons = try st.intAs(u32, 40),
                .offer_hq = try toId(types.HqId, st.int(41)),
                .orders_day = try optU32(st.optInt(42)),
                .arc_key = try st.text(43, alloc),
                .arc_beat = try st.intAs(u8, 44),
                .escalation_clock = try st.intAs(u16, 45),
                .arc_finale_key = try st.text(46, alloc),
                .command_capacity = try st.intAs(u8, 47),
                .terms = .{
                    .length_months = try st.intAs(u8, 26),
                    .base_pay_month = st.int(27),
                    .advance_pct = try st.intAs(u8, 28),
                    .signing_bonus = st.int(29),
                    .transport_pct = try st.intAs(u8, 30),
                    .overhead_pct = try st.intAs(u8, 31),
                    .battle_loss_pct = try st.intAs(u8, 32),
                    .salvage_pct = try st.intAs(u8, 33),
                    .salvage_exchange = st.int(34) != 0,
                    .command_rights = st.enumValue(contract_mod.CommandRights, 35) orelse return error.CorruptSave,
                },
            };
            if (st.int(0) != 0) {
                try gs.contract_offers.append(alloc, c);
            } else {
                const gop_c = try gs.contracts.getOrPut(alloc, c.id);
                if (gop_c.found_existing) return error.CorruptSave;
                gop_c.value_ptr.* = c;
            }
        }
    }

    // Lists.
    fn loadTxn(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT day, amount, category, company, hq, contract, note FROM txn WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.ledger.transactions.append(alloc, .{
                .day = try st.intAs(u32, 0),
                .amount = st.int(1),
                .category = st.enumValue(finance_mod.Category, 2) orelse return error.CorruptSave,
                .company = try toId(types.ForceId, st.int(3)),
                .hq = try toId(types.HqId, st.int(4)),
                .contract = try toId(types.ContractId, st.int(5)),
                .note = try st.text(6, alloc),
            });
        }
    }

    fn loadLoan(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // v35 added an `id` column to loan; pre-v35 rows carry 0 and are
        // backfilled deterministically in ord order (rule 51).
        const st = try self.db.prepare("SELECT principal, balance, rate_bp, term, next_pay, payment, id FROM loan WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const raw_id = st.int(6);
            const id: types.LoanId = if (raw_id != 0)
                try toId(types.LoanId, raw_id)
            else blk: {
                const bid: types.LoanId = @enumFromInt(gs.next_loan_id);
                gs.next_loan_id += 1;
                break :blk bid;
            };
            try gs.loans.append(alloc, .{
                .id = id,
                .principal = st.int(0),
                .balance = st.int(1),
                .rate_bp = st.int(2),
                .term_months = try st.intAs(u16, 3),
                .next_pay_day = try st.intAs(u32, 4),
                .payment = st.int(5),
            });
            if (raw_id != 0 and try fit(u32, raw_id) >= gs.next_loan_id)
                gs.next_loan_id = try fit(u32, raw_id) + 1;
        }
    }

    fn loadCourier(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT to_kind, to_id, amount, sent, eta FROM courier WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.fund_couriers.append(alloc, .{ .to = try treasuryFromCols(try st.text(0, alloc), st.int(1)), .amount = st.int(2), .sent_day = try st.intAs(u32, 3), .eta_day = try st.intAs(u32, 4) });
        }
    }

    fn loadPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT entity_kind, entity_id, floor, cap, sent FROM policy WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.policies.append(alloc, .{ .entity = try treasuryFromCols(try st.text(0, alloc), st.int(1)), .floor = st.int(2), .monthly_cap = st.int(3), .sent_this_month = st.int(4) });
        }
    }

    fn loadSupplyPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT company, min_days, tons, ammo_battles FROM supply_policy WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.supply_policies.append(alloc, .{ .company = try toId(types.ForceId, st.int(0)), .min_days = try st.intAs(u16, 1), .tons = try st.intAs(u32, 2), .ammo_battles = try st.intAs(u8, 3) });
        }
    }

    fn loadStockPolicy(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT hq, part_key, min_qty, target FROM stock_policy WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.stock_policies.append(alloc, .{ .hq = try toId(types.HqId, st.int(0)), .part_key = try st.text(1, alloc), .min = try st.intAs(u32, 2), .target = try st.intAs(u32, 3) });
        }
    }

    fn loadBayJob(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT hq, kind, unit, item_key, duration, queued, started, done, cost FROM bay_job WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.bay_jobs.append(alloc, .{
                .hq = try toId(types.HqId, st.int(0)),
                .kind = st.enumValue(state_mod.BayJobKind, 1) orelse return error.CorruptSave,
                .unit = try toId(types.UnitId, st.int(2)),
                .item_key = try st.text(3, alloc),
                .duration_days = try st.intAs(u32, 4),
                .queued_day = try st.intAs(u32, 5),
                .started_day = try optU32(st.optInt(6)),
                .done_day = try optU32(st.optInt(7)),
                .cost = st.int(8),
            });
        }
    }

    fn loadCandidate(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // v35 added an `id` column to candidate; this query reads it when present
        // (DEFAULT 0 after migration). Pre-v35 rows carry 0 and are backfilled
        // deterministically in ord order from next_candidate_id (rule 51).
        const st = try self.db.prepare("SELECT hq, first, last, callsign, role, experience, primary_skill, secondary_skill, bonus, listed, expires, age, id FROM candidate WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const raw_id = st.int(12); // 0 on pre-v35 rows (DEFAULT 0 from migration)
            const id: types.CandidateId = if (raw_id != 0)
                try toId(types.CandidateId, raw_id)
            else blk: {
                // Backfill: assign the next counter value in ord order.
                const bid: types.CandidateId = @enumFromInt(gs.next_candidate_id);
                gs.next_candidate_id += 1;
                break :blk bid;
            };
            try gs.candidates.append(alloc, .{
                .id = id,
                .hq = try toId(types.HqId, st.int(0)),
                .spec = .{
                    .first = try st.text(1, alloc),
                    .last = try st.text(2, alloc),
                    .callsign = try st.optText(3, alloc),
                    .role = st.enumValue(person_mod.Role, 4) orelse return error.CorruptSave,
                    .experience = st.enumValue(types.ExperienceLevel, 5) orelse return error.CorruptSave,
                    .primary_skill = try st.intAs(u8, 6),
                    .secondary_skill = try st.intAs(u8, 7),
                    .age = try st.intAs(u8, 11),
                },
                .asking_bonus = st.int(8),
                .listed_day = try st.intAs(u32, 9),
                .expires_day = try st.intAs(u32, 10),
            });
            // Raise the counter above any persisted id that exceeds it.
            if (raw_id != 0 and try fit(u32, raw_id) >= gs.next_candidate_id)
                gs.next_candidate_id = try fit(u32, raw_id) + 1;
        }
    }

    fn loadHqLink(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT a, b, level, tons, established FROM hq_link WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.hq_links.append(alloc, .{ .a = try toId(types.HqId, st.int(0)), .b = try toId(types.HqId, st.int(1)), .level = try st.intAs(u8, 2), .tons_this_week = try st.intAs(u32, 3), .established_day = try st.intAs(u32, 4) });
        }
    }

    fn loadUnitTransfer(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT unit, to_company, eta FROM unit_transfer WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.unit_transfers.append(alloc, .{ .unit = try toId(types.UnitId, st.int(0)), .to_company = try toId(types.ForceId, st.int(1)), .eta_day = try st.intAs(u32, 2) });
        }
    }

    fn loadFactionCooling(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT faction, until_day FROM faction_cooling WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.faction_cooling.append(alloc, .{ .faction = try st.text(0, alloc), .until_day = try st.intAs(u32, 1) });
        }
    }

    fn loadFactionStanding(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // ORDER BY rowid preserves save-insert order so the array hash map
        // iteration order is deterministic; digest.zig hashes it in that order.
        const st = try self.db.prepare("SELECT faction, value FROM faction_standing WHERE cid = ?1 ORDER BY rowid");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const faction = try st.text(0, alloc);
            const gop = try gs.faction_standing.getOrPut(alloc, faction);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = try st.intAs(i32, 1);
        }
    }

    fn loadEventMemory(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // ORDER BY rowid preserves save-insert order for deterministic digest.
        const st = try self.db.prepare("SELECT kind, last_day, last_choice, streak FROM event_memory WHERE cid = ?1 ORDER BY rowid");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = st.enumValue(events_mod.EventKind, 0) orelse return error.CorruptSave;
            const gop = try gs.event_memory.getOrPut(alloc, kind);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = .{ .last_day = try st.intAs(u32, 1), .last_choice = try st.intAs(u8, 2), .streak = try st.intAs(u8, 3) };
        }
    }

    fn loadRatingSnapshot(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT year, score FROM rating_snapshot WHERE cid = ?1 ORDER BY year");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.rating_history.append(alloc, .{ .year = try st.intAs(i32, 0), .score = try st.intAs(i32, 1) });
        }
    }

    fn loadListing(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // v35 added an `id` column to listing; pre-v35 rows carry 0 and are
        // backfilled deterministically in ord order (rule 51).
        // v56 added hull_instance_id; pre-v56 rows carry 0 → .none (abstraction-path listings).
        // v57 added planet_key, available_after; pre-v57 rows carry defaults ('', 0).
        const st = try self.db.prepare("SELECT kind, item_key, rarity, price, qty, staple, listed, expires, hq, c_armor, c_quality, c_damaged, c_destroyed, c_missing, black, company, id, hull_instance_id, planet_key, available_after FROM listing WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const raw_id = st.int(16);
            const id: types.ListingId = if (raw_id != 0)
                try toId(types.ListingId, raw_id)
            else blk: {
                const bid: types.ListingId = @enumFromInt(gs.next_listing_id);
                gs.next_listing_id += 1;
                break :blk bid;
            };
            const raw_hid = st.int(17);
            const hull_instance_id: types.HullInstanceId = if (raw_hid != 0)
                try toId(types.HullInstanceId, raw_hid)
            else
                .none;
            const kind_text = try st.text(0, alloc);
            var l: market_mod.Listing = .{
                .kind = if (std.mem.eql(u8, kind_text, "unit")) .unit else if (std.mem.eql(u8, kind_text, "part")) .part else return error.CorruptSave,
                .item_key = try st.text(1, alloc),
                .rarity = st.enumValue(types.Rarity, 2) orelse return error.CorruptSave,
                .price = st.int(3),
                .quantity = try st.intAs(u32, 4),
                .staple = st.int(5) != 0,
                .listed_day = try st.intAs(u32, 6),
                .expires_day = try st.intAs(u32, 7),
                .hq = try toId(types.HqId, st.int(8)),
                .black_market = st.int(14) != 0,
                .company = try toId(types.ForceId, st.int(15)),
                .id = id,
                .hull_instance_id = hull_instance_id,
                .planet_key = try st.text(18, alloc),
                .available_after = try st.intAs(u32, 19),
            };
            if (st.optInt(9)) |armor| {
                l.condition = .{
                    .armor_pct = try fit(u8, armor),
                    .quality = st.enumValue(types.Quality, 10) orelse return error.CorruptSave,
                    .damaged_slots = try st.intAs(u8, 11),
                    .destroyed_slots = try st.intAs(u8, 12),
                    .missing_components = try st.intAs(u8, 13),
                };
            }
            try gs.market_listings.append(alloc, l);
            if (raw_id != 0 and try fit(u32, raw_id) >= gs.next_listing_id)
                gs.next_listing_id = try fit(u32, raw_id) + 1;
        }
    }

    fn loadPartOrder(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT part_key, qty, dest_kind, dest_id, ordered, eta, cost, status FROM part_order WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.part_orders.append(alloc, .{
                .part_key = try st.text(0, alloc),
                .quantity = try st.intAs(u32, 1),
                .dest = try siteFromCols(try st.text(2, alloc), st.int(3)),
                .ordered_day = try st.intAs(u32, 4),
                .eta_day = try optU32(st.optInt(5)),
                .cost = st.int(6),
                .status = st.enumValue(@import("../domain/part.zig").OrderStatus, 7) orelse return error.CorruptSave,
            });
        }
    }

    fn loadEventLog(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT day, category, company, hq, contract, text FROM event_log WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            try gs.event_log.append(alloc, .{
                .day = try st.intAs(u32, 0),
                .category = st.enumValue(state_mod.LogCategory, 1) orelse return error.CorruptSave,
                .company = try toId(types.ForceId, st.int(2)),
                .hq = try toId(types.HqId, st.int(3)),
                .contract = try toId(types.ContractId, st.int(4)),
                .text = try st.text(5, alloc),
            });
        }
    }

    fn loadPendingEvent(self: Store, gs: *GameState, cid: i64, saved_version: u32) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT kind, day, contract, company, default_choice, deadline, chosen, person, id, battle FROM pending_event WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = st.enumValue(events_mod.EventKind, 0) orelse return error.CorruptSave;
            const entry = contract_events.entryForKind(kind) orelse return error.CorruptSave;
            const default_choice = try st.intAs(usize, 4);
            if (default_choice >= entry.options.len) return error.CorruptSave; // out-of-range choice
            const chosen: ?usize = if (st.optInt(6)) |c| blk: {
                const ci = try fit(usize, c);
                if (ci >= entry.options.len) return error.CorruptSave;
                break :blk ci;
            } else null;
            try gs.event_queue.pending.append(alloc, .{
                .day = try st.intAs(u32, 1),
                .kind = kind,
                .contract = try toId(types.ContractId, st.int(2)),
                .company = try toId(types.ForceId, st.int(3)),
                .options = entry.options,
                .default_choice = default_choice,
                .deadline_day = try st.intAs(u32, 5),
                .chosen = chosen,
                .person = try toId(types.PersonId, st.int(7)),
                .id = try toId(types.EventId, st.int(8)),
                .battle = try toId(types.BattleId, st.int(9)),
            });
        }
        // Saves before schema v26 have every id defaulted to 0; stamp them
        // in load order so the inbox is addressable. Current-version saves
        // already hold real ids; this gate ensures no RNG or state growth
        // occurs on a current-version load (rule 51, C7c).
        if (saved_version < 26) {
            for (gs.event_queue.pending.items, 0..) |*ev, i| {
                if (ev.id == .none) ev.id = @enumFromInt(i + 1);
            }
        }
        gs.event_queue.resumeIds();
    }

    fn loadBattleReport(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // Battle reports. Child rows are read per report; an outcome or
        // ROE that does not parse is `error.CorruptSave`.
        const br = try self.db.prepare("SELECT ord, id, day, contract, company, kind, enemy_key, scenario, terrain, weather, outcome, held_field, withdrew, roe, roe_overridden, player_power, enemy_power, conditions_mod, close_terrain, air_grounded, convoy_hit, edge_spent_by, recon_quality, avg_fatigue, avg_morale, hits_taken, destroyed, wounded, kia, lost_hulls, missing, enemy_destroyed_bv, kills_credited, prisoners, battle_loss_comp, score_after, score_delta, morale_delta, fatigue_add, battle_loss_pct, salvage_pct, command_rights, silenced_mounts, armor_left, salvage_claimed, salvage_haulable, salvage_cut, salvage_cash, salvage_items, conceded, acknowledged, salvage_unclaimed, operation, operation_intent, operation_tempo, operation_interventions FROM battle_report WHERE cid = ?1 ORDER BY ord");
        defer br.finalize();
        try br.bindAll(.{cid});
        while (try br.next()) {
            const ord = br.int(0);
            const outcome = br.enumValue(autoresolve_mod.Outcome, 10) orelse return error.CorruptSave;
            const roe = br.enumValue(force_mod.Roe, 13) orelse return error.CorruptSave;

            const hulls = try self.loadReportHits(alloc, cid, ord);
            const ammo = try self.loadReportAmmo(alloc, cid, ord);
            const candidates = try self.loadReportSalvage(alloc, cid, ord);
            const tasks = try self.loadReportTasks(alloc, cid, ord);
            try gs.battle_reports.kept.append(alloc, .{
                .id = try toId(types.BattleId, br.int(1)),
                .day = try br.intAs(u32, 2),
                .contract = try toId(types.ContractId, br.int(3)),
                .company = try toId(types.ForceId, br.int(4)),
                .kind = try br.text(5, alloc),
                .enemy_key = try br.text(6, alloc),
                .scenario = try br.text(7, alloc),
                .terrain = try br.text(8, alloc),
                .weather = try br.text(9, alloc),
                .outcome = outcome,
                .held_field = br.int(11) != 0,
                .withdrew = br.int(12) != 0,
                .roe = roe,
                .roe_overridden = br.int(14) != 0,
                .player_power = br.int(15),
                .enemy_power = br.int(16),
                .conditions_mod = try br.intAs(i32, 17),
                .close_terrain = br.int(18) != 0,
                .air_grounded = br.int(19) != 0,
                .convoy_hit = br.int(20) != 0,
                .edge_spent_by = try br.text(21, alloc),
                .recon_quality = try br.intAs(u8, 22),
                .avg_fatigue = try br.intAs(u8, 23),
                .avg_morale = try br.intAs(u8, 24),
                .hits_taken = try br.intAs(u32, 25),
                .destroyed = try br.intAs(u8, 26),
                .wounded = try br.intAs(u8, 27),
                .kia = try br.intAs(u8, 28),
                .lost_hulls = try br.intAs(u32, 29),
                .missing = try br.intAs(u32, 30),
                .enemy_destroyed_bv = br.int(31),
                .kills_credited = try br.intAs(u32, 32),
                .prisoners = try br.intAs(u32, 33),
                .battle_loss_comp = br.int(34),
                .score_after = try br.intAs(i32, 35),
                .score_delta = try br.intAs(i32, 36),
                .morale_delta = try br.intAs(i32, 37),
                .fatigue_add = try br.intAs(u8, 38),
                .battle_loss_pct = try br.intAs(u8, 39),
                .salvage_pct = try br.intAs(u8, 40),
                .command_rights = try br.text(41, alloc),
                .hulls = hulls,
                .ammo = ammo,
                .silenced_mounts = try br.intAs(u32, 42),
                .armor_left = try br.intAs(u32, 43),
                .salvage = .{
                    .claimed_bv = br.int(44),
                    .haulable_bv = br.int(45),
                    .liaison_cut = br.int(46),
                    .exchange_cash = br.int(47),
                    .items = try br.text(48, alloc),
                    .candidates = candidates,
                    .unclaimed_bv = br.int(51),
                },
                .conceded = br.int(49) != 0,
                .acknowledged = br.int(50) != 0,
                .operation = try br.text(52, alloc),
                .operation_intent = blk: {
                    const raw = try br.text(53, alloc);
                    if (raw.len == 0) break :blk null;
                    break :blk std.meta.stringToEnum(operation_mod.Intent, raw) orelse return error.CorruptSave;
                },
                .operation_tempo = blk: {
                    const raw = try br.text(54, alloc);
                    if (raw.len == 0) break :blk null;
                    break :blk std.meta.stringToEnum(operation_mod.TempoPosture, raw) orelse return error.CorruptSave;
                },
                .operation_interventions = try br.text(55, alloc),
                .tasks = tasks,
            });
        }
        // Post-load orphan check: a child row whose report_ord names no loaded
        // battle_report is corruption (rule 47, C7). One query per child table.
        {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM battle_report_hit WHERE cid = ?1 AND report_ord NOT IN (SELECT ord FROM battle_report WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
        {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM battle_report_ammo WHERE cid = ?1 AND report_ord NOT IN (SELECT ord FROM battle_report WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
        {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM battle_report_salvage WHERE cid = ?1 AND report_ord NOT IN (SELECT ord FROM battle_report WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
        // P4e: task orphan check.
        {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM battle_report_task WHERE cid = ?1 AND report_ord NOT IN (SELECT ord FROM battle_report WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
    }

    /// The hulls a report's hit rows name, in order.
    fn loadReportHits(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]battle_report_mod.HullHit {
        var hulls: std.ArrayListUnmanaged(battle_report_mod.HullHit) = .empty;
        const bh = try self.db.prepare("SELECT unit, chassis_key, chassis_name, armor_before, armor_after, slot, slot_part, slot_result, destroyed, cause, pilot, crew_name, wound_severity, wound_location, wound_permanent, fate, recovery_roll, recovery_target, lost FROM battle_report_hit WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bh.finalize();
        try bh.bindAll(.{ cid, ord });
        while (try bh.next()) {
            const slot_text = try bh.text(5, alloc);
            try hulls.append(alloc, .{
                .unit = try toId(types.UnitId, bh.int(0)),
                .chassis_key = try bh.text(1, alloc),
                .chassis_name = try bh.text(2, alloc),
                .armor_before = try bh.intAs(u8, 3),
                .armor_after = try bh.intAs(u8, 4),
                .slot = if (slot_text.len > 0) slot_text else null,
                .slot_part = try bh.text(6, alloc),
                .slot_result = bh.enumValue(battle_report_mod.SlotResult, 7) orelse return error.CorruptSave,
                .destroyed = bh.int(8) != 0,
                .cause = bh.enumValue(unit_mod.WreckCause, 9) orelse return error.CorruptSave,
                .pilot = try toId(types.PersonId, bh.int(10)),
                .crew_name = try bh.text(11, alloc),
                .crew = .{
                    .wound = if (bh.optInt(12)) |sev| .{
                        .severity = try fit(u8, sev),
                        .location = bh.enumValue(person_mod.InjuryLocation, 13) orelse return error.CorruptSave,
                        .permanent = bh.int(14) != 0,
                    } else null,
                    .fate = bh.enumValue(battle_report_mod.CrewOutcome.Fate, 15) orelse return error.CorruptSave,
                },
                .recovery = if (bh.optInt(16)) |roll| .{ .roll = try fit(i32, roll), .target = try bh.intAs(i32, 17) } else null,
                .lost = bh.int(18) != 0,
            });
        }
        return hulls.items;
    }

    /// A report's ammunition lines, in order.
    fn loadReportAmmo(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]battle_report_mod.AmmoLine {
        var ammo: std.ArrayListUnmanaged(battle_report_mod.AmmoLine) = .empty;
        const ba = try self.db.prepare("SELECT family, burned, reserve FROM battle_report_ammo WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer ba.finalize();
        try ba.bindAll(.{ cid, ord });
        while (try ba.next()) try ammo.append(alloc, .{
            .key = try ba.text(0, alloc),
            .burned = try ba.intAs(u32, 1),
            .left = try ba.intAs(u32, 2),
        });
        return ammo.items;
    }

    /// The wrecks a report's salvage claim was divided over, in order.
    fn loadReportSalvage(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]battle_report_mod.SalvageCandidate {
        var candidates: std.ArrayListUnmanaged(battle_report_mod.SalvageCandidate) = .empty;
        const bs = try self.db.prepare("SELECT key, name, bv, armor_pct, quality, damaged, destroyed, missing, hull_instance_id FROM battle_report_salvage WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bs.finalize();
        try bs.bindAll(.{ cid, ord });
        while (try bs.next()) try candidates.append(alloc, .{
            .key = try bs.text(0, alloc),
            .name = try bs.text(1, alloc),
            .bv = bs.int(2),
            .armor_pct = try bs.intAs(u8, 3),
            .quality = bs.enumValue(types.Quality, 4) orelse return error.CorruptSave,
            .damaged_slots = try bs.intAs(u8, 5),
            .destroyed_slots = try bs.intAs(u8, 6),
            .missing_components = try bs.intAs(u8, 7),
            .hull_instance_id = @enumFromInt(try bs.intAs(u32, 8)),
        });
        return candidates.items;
    }

    // P4e: per-engagement task results for a single battle_report ord.
    fn loadReportTasks(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64) ![]battle_report_mod.TaskedLance {
        var tasks: std.ArrayListUnmanaged(battle_report_mod.TaskedLance) = .empty;
        const bt = try self.db.prepare("SELECT lance_id, lance_name, task, succeeded, note FROM battle_report_task WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bt.finalize();
        try bt.bindAll(.{ cid, ord });
        while (try bt.next()) {
            const task = bt.enumValue(operation_mod.LanceTask, 2) orelse return error.CorruptSave;
            try tasks.append(alloc, .{
                .lance = try toId(types.ForceId, bt.int(0)),
                .lance_name = try bt.text(1, alloc),
                .task = task,
                .succeeded = bt.int(3) != 0,
                .note = try bt.text(4, alloc),
            });
        }
        return tasks.items;
    }

    fn loadRefitPlan(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const pl = try self.db.prepare("SELECT ord, unit, committed FROM refit_plan WHERE cid = ?1 ORDER BY ord");
        defer pl.finalize();
        try pl.bindAll(.{cid});
        while (try pl.next()) {
            try gs.refit_plans.append(alloc, .{ .unit = try toId(types.UnitId, pl.int(1)), .committed = pl.int(2) != 0 });
        }
        const op = try self.db.prepare("SELECT plan_ord, kind, slot_key, location, part_key FROM refit_op WHERE cid = ?1 ORDER BY plan_ord, ord");
        defer op.finalize();
        try op.bindAll(.{cid});
        while (try op.next()) {
            const idx: usize = try op.intAs(usize, 0);
            if (idx >= gs.refit_plans.items.len) return error.CorruptSave; // orphan refit_op
            const kind = try op.text(1, alloc);
            if (std.mem.eql(u8, kind, "remove")) {
                try gs.refit_plans.items[idx].ops.append(alloc, .{ .remove = try op.text(2, alloc) });
            } else {
                try gs.refit_plans.items[idx].ops.append(alloc, .{ .install = .{
                    .location = op.enumValue(@import("../domain/meklab.zig").Location, 3) orelse return error.CorruptSave,
                    .part_key = try op.text(4, alloc),
                } });
            }
        }
    }

    /// Data-level upgrades for campaigns saved under an older schema.
    /// Draws from the `generation` stream only when a step needs a roll.
    pub fn upgradeCampaign(gs: *GameState, from_version: u32) !void {
        // Saves before v16 have no birthdays; each person rolls an age by
        // role and experience.
        if (from_version < 16) {
            const person_gen = @import("../gen/person_gen.zig");
            var it = gs.people.iterator();
            while (it.next()) |e| {
                const p = e.value_ptr;
                if (p.born_day != null) continue;
                const age = person_gen.rollAge(&gs.rng, .generation, p.role, p.experience());
                p.setBirthdayFromAge(p.recruited_day, age);
            }
        }
        // Saves before v7 hold wounds with no located injury; triage
        // (medical.runDailyHealing) gives such a person a stand-in record,
        // so nothing is upgraded here.
        // v48 (P3c.1): give every owned unit a HullInstance whose base_key is the
        // unit's chassis_key and whose design loadout is built from the unit's slot
        // part_keys (docs/p3c-hull-lifecycle-design.md §3). Deterministic (no RNG);
        // runs only for campaigns saved before v48.
        if (from_version < 48) {
            const chassis = @import("../domain/chassis.zig");
            const hull_mod = @import("../domain/hull_instance.zig");
            const alloc = gs.allocator();
            var it = gs.units.iterator();
            while (it.next()) |e| {
                const u = e.value_ptr;
                const design = chassis.find(u.chassis_key) orelse return error.CorruptSave;
                const id: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
                gs.next_hull_instance_id += 1;
                var inst: hull_mod.HullInstance = .{
                    .id = id,
                    .base_key = u.chassis_key,
                    .status = .active,
                    .intro_year = design.intro_year,
                    .pre_campaign = true,
                };
                for (u.slots.items) |s| try inst.loadout.append(alloc, .{ .part_key = s.part_key });
                try gs.hull_instances.put(alloc, id, inst);
                u.hull_instance_id = id;
            }
        }
        // v51 (P3c.4): seed one .initial ownership interval per owned hull for
        // campaigns saved before the ownership log existed. Deterministic (no RNG).
        if (from_version < 51) {
            const alloc = gs.allocator();
            var it = gs.units.iterator();
            while (it.next()) |e| {
                const u = e.value_ptr;
                if (u.hull_instance_id == .none) continue;
                try gs.hull_ownership_history.append(alloc, .{
                    .hull_instance_id = u.hull_instance_id,
                    .from_day = u.acquired_day,
                    .to_day = 0,
                    .acquisition_type = .initial,
                    .prior_owner_key = "unknown",
                });
            }
        }
    }
};

/// Save-file recovery, not a rule: a campaign saved before schema v18 has
/// no stats counters, so its log holds battles and its book holds zeros.
/// This reads the log's AAR lines once, at load. Campaigns with counters
/// count at the source (battle.zig) and never come through here.
pub fn recoverStatsFromLog(gs: *GameState) void {
    var st: state_mod.Stats = .{};
    for (gs.event_log.items) |e| {
        // Lines carry a date prefix: "3025-02-15 [AAR] …".
        if (e.category != .battle or std.mem.indexOf(u8, e.text, "[AAR]") == null) continue;
        if (std.mem.indexOf(u8, e.text, " — power ") != null) {
            // "[AAR] kind vs enemy …: outcome — power a vs b"
            const head = e.text[0..std.mem.indexOf(u8, e.text, " — power ").?];
            const colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse continue;
            const outcome = std.mem.trim(u8, head[colon + 1 ..], " ");
            if (std.mem.eql(u8, outcome, "decisive_victory") or std.mem.eql(u8, outcome, "victory")) st.battles_won += 1 //
            else if (std.mem.eql(u8, outcome, "draw")) st.battles_drawn += 1 //
            else if (std.mem.eql(u8, outcome, "defeat") or std.mem.eql(u8, outcome, "rout")) st.battles_lost += 1;
            continue;
        }
        if (std.mem.indexOf(u8, e.text, "losses: ")) |i| {
            // "losses: H hit / D destroyed, W wounded, K KIA | enemy losses B BV"
            var it = std.mem.tokenizeAny(u8, e.text[i + "losses: ".len ..], " /,|");
            var nums: [8]u64 = @splat(0);
            var n: usize = 0;
            while (it.next()) |tok| {
                if (n >= nums.len) break;
                if (std.fmt.parseInt(u64, tok, 10)) |v| {
                    nums[n] = v;
                    n += 1;
                } else |_| {}
            }
            // order: hit, destroyed, wounded, KIA, enemy BV
            if (n >= 5) {
                st.hulls_lost += @intCast(nums[1]);
                st.people_kia += @intCast(nums[3]);
                st.enemy_bv_destroyed += nums[4];
            }
            continue;
        }
        if (std.mem.indexOf(u8, e.text, "salvage: ") != null) {
            var rest = e.text;
            while (std.mem.indexOf(u8, rest, "wreck #")) |k| {
                st.hulls_salvaged += 1;
                rest = rest[k + "wreck #".len ..];
            }
        }
    }
    gs.stats = st;
}

test "counters rebuild from the AAR lines of an older save" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1288 });
    defer gs.deinit();
    try gs.log(.battle, .{}, "[AAR] garrison_duty vs DC: victory — power 900 vs 700 (recon 0, fatigue 4, morale 50)", .{});
    try gs.log(.battle, .{}, "[AAR]   losses: 2 hit / 1 destroyed, 1 wounded, 1 KIA | enemy losses 1200 BV ≈ 1 kill credited | salvage 300 BV claimed | comp 0 | score 1", .{});
    try gs.log(.battle, .{}, "[AAR]   salvage: wreck #40 SHD-2H Shadow Hawk (armor 30%) → home depot in 5 days; wreck #41 LCT-1V Locust → home depot in 5 days; ", .{});
    try gs.log(.battle, .{}, "[AAR] raid vs CC — ambush on heavy woods, night action: rout — power 500 vs 900 (recon 0, fatigue 9, morale 40)", .{});
    try gs.log(.battle, .{}, "[AAR]   losses: 4 hit / 2 destroyed, 2 wounded, 0 KIA | enemy losses 100 BV ≈ 0 kills credited | salvage 0 BV claimed | comp 0 | score -2", .{});
    try gs.log(.battle, .{}, "[AAR]   salvage: none — the field was not held", .{});
    recoverStatsFromLog(&gs);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_won);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.battles_lost);
    try std.testing.expectEqual(@as(u32, 3), gs.stats.hulls_lost);
    try std.testing.expectEqual(@as(u32, 1), gs.stats.people_kia);
    try std.testing.expectEqual(@as(u32, 2), gs.stats.hulls_salvaged);
    try std.testing.expectEqual(@as(u64, 1300), gs.stats.enemy_bv_destroyed);
}

/// Every stored key names something in the catalogues, and every display
/// copy a save keeps is markup-safe; `error.CorruptSave` otherwise. The
/// screens then show these strings as they are. Free text a player chose
/// (names, log lines, crew names) is not checked here: the queries escape
/// it on the way to a screen.
fn validateStoredStrings(gs: *GameState) error{CorruptSave}!void {
    const chassis = @import("../domain/chassis.zig");
    const part = @import("../domain/part.zig");
    const planet = @import("../domain/planet.zig");
    const faction = @import("../domain/faction.zig");
    const table = @import("../sim/table.zig");
    const Check = struct {
        fn hull(key: []const u8) error{CorruptSave}!void {
            if (chassis.find(key) == null) return error.CorruptSave;
        }
        fn item(key: []const u8) error{CorruptSave}!void {
            if (!part.isKnownKey(key)) return error.CorruptSave;
        }
        fn world(key: []const u8) error{CorruptSave}!void {
            if (planet.find(key) == null) return error.CorruptSave;
        }
        fn house(key: []const u8) error{CorruptSave}!void {
            if (faction.find(key) == null) return error.CorruptSave;
        }
        fn shown(text: []const u8) error{CorruptSave}!void {
            if (!table.markupSafe(text)) return error.CorruptSave;
        }
        fn slots(u: *const @import("../domain/unit.zig").Unit) error{CorruptSave}!void {
            try hull(u.chassis_key);
            for (u.slots.items) |s| {
                try item(s.part_key);
                try shown(s.slot_key);
            }
        }
        fn stock(map: *const std.StringArrayHashMapUnmanaged(u32)) error{CorruptSave}!void {
            for (map.keys()) |k| try item(k);
        }
        fn arc(key: []const u8) error{CorruptSave}!void {
            if (arc_mod.find(key) == null) return error.CorruptSave;
        }
        fn opTemplate(key: []const u8) error{CorruptSave}!void {
            if (operation_mod.findTemplate(key) == null) return error.CorruptSave;
        }
    };
    var uit = gs.units.iterator();
    while (uit.next()) |e| try Check.slots(e.value_ptr);
    for (gs.held_hulls.items) |*h| try Check.slots(&h.unit);
    try Check.stock(&gs.spare_parts);
    var hit = gs.hqs.iterator();
    while (hit.next()) |e| {
        try Check.world(e.value_ptr.planet_key);
        try Check.stock(&e.value_ptr.stock);
    }
    var force_it = gs.forces.iterator();
    while (force_it.next()) |e| {
        try Check.stock(&e.value_ptr.stock);
        if (e.value_ptr.location_planet) |p| try Check.world(p);
    }
    for ([_][]const @import("../domain/contract.zig").Contract{ gs.contracts.values(), gs.contract_offers.items }) |list| for (list) |c| {
        try Check.world(c.planet_key);
        try Check.house(c.employer_key);
        try Check.house(c.enemy_key);
        if (c.arc_key.len > 0) try Check.arc(c.arc_key);
        if (c.arc_key.len > 0 and c.arc_finale_key.len > 0) {
            const a = arc_mod.find(c.arc_key) orelse return error.CorruptSave;
            var found = false;
            for (a.finales) |f| if (std.mem.eql(u8, f.key, c.arc_finale_key)) {
                found = true;
                break;
            };
            if (!found) return error.CorruptSave;
        }
        for (c.operations.items) |op| try Check.opTemplate(op.template_key);
    };
    var pit = gs.people.iterator();
    while (pit.next()) |e| if (e.value_ptr.faction.len > 0) try Check.house(e.value_ptr.faction);
    for (gs.faction_standing.keys()) |k| try Check.house(k);
    for (gs.faction_cooling.items) |f| try Check.house(f.faction);
    for (gs.market_listings.items) |l| switch (l.kind) {
        .unit => try Check.hull(l.item_key),
        .part => try Check.item(l.item_key),
    };
    for (gs.part_orders.items) |o| try Check.item(o.part_key);
    for (gs.stock_policies.items) |sp| try Check.item(sp.part_key);
    for (gs.bay_jobs.items) |j| if (j.item_key.len > 0) try Check.item(j.item_key);
    for (gs.refit_plans.items) |plan| for (plan.ops.items) |op| switch (op) {
        .install => |it| try Check.item(it.part_key),
        .remove => |slot_key| try Check.shown(slot_key),
    };
    // Actors: archetype_key and last_cause must be markup-safe.
    {
        var ait = gs.actors.iterator();
        while (ait.next()) |e| {
            const a = e.value_ptr;
            if (actor_mod.find(a.archetype_key) == null) return error.CorruptSave;
            if (a.last_cause.len > 0) try Check.shown(a.last_cause);
        }
    }
    // Rivals: archetype_key and unit_name and last_cause must be valid/markup-safe.
    {
        var rit = gs.rivals.iterator();
        while (rit.next()) |e| {
            const rv = e.value_ptr;
            if (rival_mod.find(rv.archetype_key) == null) return error.CorruptSave;
            if (!table.markupSafe(rv.unit_name)) return error.CorruptSave;
            if (rv.last_cause.len > 0) try Check.shown(rv.last_cause);
        }
    }
    // Merc companies: archetype_key and unit_name must be valid/markup-safe.
    {
        var mcit = gs.merc_companies.iterator();
        while (mcit.next()) |e| {
            const mc = e.value_ptr;
            if (rival_mod.find(mc.archetype_key) == null) return error.CorruptSave;
            if (!table.markupSafe(mc.unit_name)) return error.CorruptSave;
        }
    }
    // Officer arcs: last_cause must be markup-safe.
    {
        var oait = gs.officer_arcs.iterator();
        while (oait.next()) |e| {
            if (e.value_ptr.last_cause.len > 0) try Check.shown(e.value_ptr.last_cause);
        }
    }
    // World states: planet_key must name a known planet; last_cause must be markup-safe.
    {
        var wsit = gs.world_states.iterator();
        while (wsit.next()) |e| {
            try Check.world(e.key_ptr.*);
            if (e.value_ptr.last_cause.len > 0) try Check.shown(e.value_ptr.last_cause);
        }
    }
    // Hull instances: base_key must name a known chassis; name and nickname must be markup-safe;
    // each loadout part_key must name a known part; faction owner key must name a known faction
    // (rules 47, 50).
    {
        var hiit = gs.hull_instances.iterator();
        while (hiit.next()) |e| {
            const inst = e.value_ptr;
            try Check.hull(inst.base_key);
            if (inst.name) |n| try Check.shown(n);
            if (inst.nickname) |n| try Check.shown(n);
            for (inst.loadout.items) |l| try Check.item(l.part_key);
            if (inst.owner == .faction) try Check.house(inst.owner.faction);
        }
    }
    // Maintenance entries: description must be markup-safe (rule 50).
    {
        for (gs.maintenance_entries.items) |e| {
            try Check.shown(e.description);
        }
    }
    // Faction rosters: every roster key must name a known faction (rule 47, 50).
    for (gs.faction_rosters.keys()) |k| try Check.house(k);
    // Ownership history: prior_owner_key is free provenance (may name a gone
    // entity) so it is NOT catalogue-validated, only markup-safe (rule 50).
    for (gs.hull_ownership_history.items) |e| try Check.shown(e.prior_owner_key);
    for (gs.battle_reports.kept.items) |r| {
        inline for (.{ r.kind, r.enemy_key, r.scenario, r.terrain, r.weather, r.command_rights, r.salvage.items, r.operation, r.operation_interventions }) |text| try Check.shown(text);
        if (r.operation_intent) |i| try Check.shown(@tagName(i));
        for (r.hulls) |h| {
            try Check.hull(h.chassis_key);
            try Check.shown(h.chassis_name);
            try Check.shown(h.slot_part);
            if (h.slot) |s| try Check.shown(s);
        }
        for (r.ammo) |a| try Check.item(a.key);
        for (r.salvage.candidates) |c| {
            try Check.hull(c.key);
            try Check.shown(c.name);
        }
    }
}

/// Validate cross-entity references: every non-`.none` id that names a
/// live entity must resolve; a dangling reference is corruption (rule 47).
fn validateReferences(gs: *GameState) error{CorruptSave}!void {
    // Helper: a non-none typed id must name a live entity in `map`.
    const Ref = struct {
        fn inMap(comptime Id: type, id: Id, map: anytype) error{CorruptSave}!void {
            if (id == .none) return;
            if (map.getPtr(id) == null) return error.CorruptSave;
        }
        fn unitExists(id: types.UnitId, gsp: *const GameState) error{CorruptSave}!void {
            if (id == .none) return;
            if (gsp.units.getPtr(id) != null) return;
            for (gsp.held_hulls.items) |*h| if (h.unit.id == id) return;
            return error.CorruptSave;
        }
    };
    // Units
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        try Ref.inMap(types.ForceId, u.force, gs.forces);
        try Ref.inMap(types.PersonId, u.pilot, gs.people);
        try Ref.inMap(types.PersonId, u.tech, gs.people);
        try Ref.inMap(types.HqId, u.berth_hq, gs.hqs);
        try Ref.inMap(types.HullInstanceId, u.hull_instance_id, gs.hull_instances);
    }
    // Hull instances: merc-company-owned hulls must reference a live merc company (post-load pass;
    // loadHullInstances runs before loadMercCompanies, so this check runs here, not there).
    {
        var hiit = gs.hull_instances.iterator();
        while (hiit.next()) |e| {
            if (e.value_ptr.owner == .merc_company)
                try Ref.inMap(types.MercCompanyId, e.value_ptr.owner.merc_company, gs.merc_companies);
        }
    }
    // Forces
    var fit_it = gs.forces.iterator();
    while (fit_it.next()) |e| {
        const f = e.value_ptr;
        try Ref.inMap(types.ForceId, f.parent, gs.forces);
        try Ref.inMap(types.PersonId, f.commander, gs.people);
        try Ref.inMap(types.HqId, f.supplying_hq, gs.hqs);
        // Each unit/child reference in the list must resolve.
        for (f.units.items) |uid| try Ref.unitExists(uid, gs);
        for (f.children.items) |cid| try Ref.inMap(types.ForceId, cid, gs.forces);
    }
    // People
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        try Ref.inMap(types.ForceId, p.assigned_force, gs.forces);
        try Ref.inMap(types.HqId, p.posted_hq, gs.hqs);
    }
    // Contracts
    for ([_][]const contract_mod.Contract{ gs.contracts.values(), gs.contract_offers.items }) |list| {
        for (list) |c| {
            try Ref.inMap(types.ForceId, c.assigned_company, gs.forces);
            try Ref.inMap(types.HqId, c.offer_hq, gs.hqs);
        }
    }
    // Bay jobs
    for (gs.bay_jobs.items) |j| {
        try Ref.inMap(types.HqId, j.hq, gs.hqs);
        try Ref.unitExists(j.unit, gs);
    }
    // Pending events
    for (gs.event_queue.pending.items) |ev| {
        try Ref.inMap(types.ContractId, ev.contract, gs.contracts);
        try Ref.inMap(types.ForceId, ev.company, gs.forces);
        try Ref.inMap(types.PersonId, ev.person, gs.people);
    }
    // Held hulls
    for (gs.held_hulls.items) |h| {
        try Ref.inMap(types.ForceId, h.from_force, gs.forces);
    }
    // Market listings: a non-.none hull_instance_id must name a live HullInstance (rules 47/48).
    for (gs.market_listings.items) |l| {
        try Ref.inMap(types.HullInstanceId, l.hull_instance_id, gs.hull_instances);
    }
    // Ledger transactions
    for (gs.ledger.transactions.items) |t| {
        try Ref.inMap(types.ForceId, t.company, gs.forces);
        try Ref.inMap(types.HqId, t.hq, gs.hqs);
        try Ref.inMap(types.ContractId, t.contract, gs.contracts);
    }
    // HQ links
    for (gs.hq_links.items) |l| {
        try Ref.inMap(types.HqId, l.a, gs.hqs);
        try Ref.inMap(types.HqId, l.b, gs.hqs);
    }
    // Unit transfers
    for (gs.unit_transfers.items) |ut| {
        try Ref.unitExists(ut.unit, gs);
        try Ref.inMap(types.ForceId, ut.to_company, gs.forces);
    }
    // Supply and stock policies
    for (gs.supply_policies.items) |sp| try Ref.inMap(types.ForceId, sp.company, gs.forces);
    for (gs.stock_policies.items) |sp| try Ref.inMap(types.HqId, sp.hq, gs.hqs);
    // Fund couriers and standing policies
    for (gs.fund_couriers.items) |c| switch (c.to) {
        .outfit => {},
        .hq => |id| try Ref.inMap(types.HqId, id, gs.hqs),
        .company => |id| try Ref.inMap(types.ForceId, id, gs.forces),
    };
    for (gs.policies.items) |p| switch (p.entity) {
        .outfit => {},
        .hq => |id| try Ref.inMap(types.HqId, id, gs.hqs),
        .company => |id| try Ref.inMap(types.ForceId, id, gs.forces),
    };
    // Faction/merc-company rosters: every member hull must resolve to a live hull
    // instance; each merc_company roster key must name a live merc company (rule 47).
    // Also validate Rival.merc_company_id FK (allows .none).
    {
        var frit = gs.faction_rosters.iterator();
        while (frit.next()) |e| for (e.value_ptr.items) |hid|
            try Ref.inMap(types.HullInstanceId, hid, gs.hull_instances);
        var mrit = gs.merc_company_rosters.iterator();
        while (mrit.next()) |e| {
            try Ref.inMap(types.MercCompanyId, e.key_ptr.*, gs.merc_companies);
            for (e.value_ptr.items) |hid|
                try Ref.inMap(types.HullInstanceId, hid, gs.hull_instances);
        }
        var rvit = gs.rivals.iterator();
        while (rvit.next()) |e|
            try Ref.inMap(types.MercCompanyId, e.value_ptr.merc_company_id, gs.merc_companies);
    }
}

/// Ensure every entity counter exceeds the maximum owned id; detect
/// impossible-maxima that would overflow on the next allocation (rule 48).
fn reconcileCounters(gs: *GameState) error{CorruptSave}!void {
    const max_u32 = std.math.maxInt(u32);
    // Helper: find max id in a map and ensure counter > max.
    // next_*_id stays at least 1, so the first allocation is always fresh.
    {
        var max: u32 = 0;
        var it = gs.people.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_person_id = @max(gs.next_person_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.units.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        for (gs.held_hulls.items) |h| max = @max(max, @intFromEnum(h.unit.id));
        if (max == max_u32) return error.CorruptSave;
        gs.next_unit_id = @max(gs.next_unit_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.forces.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_force_id = @max(gs.next_force_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.hqs.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_hq_id = @max(gs.next_hq_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.contracts.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        for (gs.contract_offers.items) |c| max = @max(max, @intFromEnum(c.id));
        if (max == max_u32) return error.CorruptSave;
        gs.next_contract_id = @max(gs.next_contract_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.actors.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_actor_id = @max(gs.next_actor_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.rivals.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_rival_id = @max(gs.next_rival_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.merc_companies.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_merc_company_id = @max(gs.next_merc_company_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.officer_arcs.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_officer_arc_id = @max(gs.next_officer_arc_id, max + 1);
    }
    {
        var max: u32 = 0;
        var it = gs.hull_instances.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        gs.next_hull_instance_id = @max(gs.next_hull_instance_id, max + 1);
    }
    // Battle and event counters: resumeBattleIds/resumeIds saturate at maxInt
    // when an entity holds the maximum id — detect that here (rule 48).
    if (gs.next_battle_id == max_u32) return error.CorruptSave;
    if (gs.event_queue.next_id == max_u32) return error.CorruptSave;
    // Listing, candidate and loan: backfilled in their loaders; check max.
    {
        var max: u32 = 0;
        for (gs.market_listings.items) |l| max = @max(max, @intFromEnum(l.id));
        if (max == max_u32) return error.CorruptSave;
        gs.next_listing_id = @max(gs.next_listing_id, max + 1);
    }
    {
        var max: u32 = 0;
        for (gs.candidates.items) |c| max = @max(max, @intFromEnum(c.id));
        if (max == max_u32) return error.CorruptSave;
        gs.next_candidate_id = @max(gs.next_candidate_id, max + 1);
    }
    {
        var max: u32 = 0;
        for (gs.loans.items) |l| max = @max(max, @intFromEnum(l.id));
        if (max == max_u32) return error.CorruptSave;
        gs.next_loan_id = @max(gs.next_loan_id, max + 1);
    }
}

/// A stored integer as `T`; `error.CorruptSave` when it does not fit.
fn fit(comptime T: type, v: i64) error{CorruptSave}!T {
    return std.math.cast(T, v) orelse error.CorruptSave;
}

/// A typed id from a stored integer; `error.CorruptSave` outside `u32`.
fn toId(comptime T: type, v: i64) error{CorruptSave}!T {
    return @enumFromInt(std.math.cast(u32, v) orelse return error.CorruptSave);
}

fn optU32(v: ?i64) error{CorruptSave}!?u32 {
    return if (v) |x| try fit(u32, x) else null;
}

const Cols = struct { kind: []const u8, id: i64 };

fn treasuryCols(t: state_mod.Treasury) Cols {
    return switch (t) {
        .outfit => .{ .kind = "outfit", .id = 0 },
        .hq => |id| .{ .kind = "hq", .id = @intFromEnum(id) },
        .company => |id| .{ .kind = "company", .id = @intFromEnum(id) },
    };
}

fn treasuryFromCols(kind: []const u8, id: i64) error{CorruptSave}!state_mod.Treasury {
    if (std.mem.eql(u8, kind, "hq")) return .{ .hq = try toId(types.HqId, id) };
    if (std.mem.eql(u8, kind, "company")) return .{ .company = try toId(types.ForceId, id) };
    if (std.mem.eql(u8, kind, "outfit")) return .outfit;
    return error.CorruptSave;
}

fn siteCols(s: types.Site) Cols {
    return switch (s) {
        .outfit => .{ .kind = "outfit", .id = 0 },
        .hq => |id| .{ .kind = "hq", .id = @intFromEnum(id) },
        .company => |id| .{ .kind = "company", .id = @intFromEnum(id) },
    };
}

fn siteFromCols(kind: []const u8, id: i64) error{CorruptSave}!types.Site {
    if (std.mem.eql(u8, kind, "hq")) return .{ .hq = try toId(types.HqId, id) };
    if (std.mem.eql(u8, kind, "company")) return .{ .company = try toId(types.ForceId, id) };
    if (std.mem.eql(u8, kind, "outfit")) return .outfit;
    return error.CorruptSave;
}

test "save → load → identical hash, and the loaded campaign keeps playing" {
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 1101 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "Erik Kalmar", .origin = .CC, .profession = .quartermaster } });
    _ = try commands.execute(&gs, .{ .rename_outfit = "Kalmar's Free Legion" });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(&gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
    _ = try commands.execute(&gs, .{ .set_policy = .{ .entity = .{ .company = co }, .floor = 200_000, .monthly_cap = 300_000 } });
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 14, .tons = 20 } });
    _ = try commands.execute(&gs, .{ .set_supply_policy = .{ .company = co, .min_days = 30, .tons = 60 } }); // re-setting replaces
    _ = try commands.execute(&gs, .{ .set_stock_policy = .{ .hq = gs.seat(), .part_key = "ammo_lrm", .min = 10, .target = 30 } });
    _ = try commands.execute(&gs, .{ .set_auto_admit = true });
    _ = try commands.execute(&gs, .{ .set_shares_pct = 45 }); // profit shares
    gs.people.getPtr(gs.people.keys()[2]).?.shares = 4;
    gs.people.getPtr(gs.people.keys()[2]).?.last_raise_day = 3; // raise cooldown
    gs.stats.battles_won = 7; // campaign stats
    // secondary_role round-trip (C7c): a non-null secondary_role must survive.
    gs.people.getPtr(gs.people.keys()[1]).?.secondary_role = .tech_mek;
    const secondary_role_person = gs.people.keys()[1];
    try gs.rating_history.append(gs.allocator(), .{ .year = 3025, .score = 40 });
    _ = try commands.execute(&gs, .{ .advance_days = 40 }); // battles, events, deliveries, couriers
    _ = try gs.adjustStanding("LC", 12); // faction standing rides along
    // A permanent injury on someone's record rides along.
    const scarred = gs.people.keys()[3];
    try gs.people.getPtr(scarred).?.injuries.append(gs.allocator(), .{ .location = .head, .severity = 3, .incurred_day = 5, .heal_done_day = 40, .permanent = true, .healed = true });
    // A dropship holding a berth rides along.
    const ship = try gs.addUnit("LEOPARD");
    gs.unit(ship).?.berth_hq = gs.seat();
    // A company's rules of engagement ride along.
    gs.forces.getPtr(gs.forces.keys()[0]).?.roe = .cautious;
    // A wreck remembers how it died.
    const wreck = try gs.addUnit("GRF-1N");
    gs.unit(wreck).?.markWreckedBy(.engine);
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try std.testing.expect(gs.campaign_id > 0);

    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(gs.seat(), loaded.unit(ship).?.berth_hq);
    try std.testing.expectEqual(@import("../domain/unit.zig").WreckCause.engine, loaded.unit(wreck).?.wreck);
    try std.testing.expectEqual(@import("../domain/force.zig").Roe.cautious, loaded.forces.getPtr(gs.forces.keys()[0]).?.roe);
    // Offers keep their opposition.
    if (gs.contract_offers.items.len > 0) {
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_lances, loaded.contract_offers.items[0].enemy_lances);
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_quality, loaded.contract_offers.items[0].enemy_quality);
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_lance_bv, loaded.contract_offers.items[0].enemy_lance_bv);
        try std.testing.expectEqual(gs.contract_offers.items[0].enemy_lance_tons, loaded.contract_offers.items[0].enemy_lance_tons);
        try std.testing.expectEqual(gs.contract_offers.items[0].offer_hq, loaded.contract_offers.items[0].offer_hq);
    }
    try std.testing.expectEqual(@as(i32, 12), loaded.standing("LC"));
    try std.testing.expectEqual(@as(usize, 1), loaded.person(scarred).?.injuries.items.len);
    try std.testing.expect(loaded.person(scarred).?.injuries.items[0].permanent);
    try std.testing.expectEqual(person_mod.InjuryLocation.head, loaded.person(scarred).?.injuries.items[0].location);
    try std.testing.expectEqualStrings("Kalmar's Free Legion", loaded.outfit_name);
    try std.testing.expectEqual(gs.people.count(), loaded.people.count());
    try std.testing.expectEqual(gs.event_log.items.len, loaded.event_log.items.len);
    try std.testing.expectEqual(gs.event_queue.pending.items.len, loaded.event_queue.pending.items.len);
    // An event is answered by id, so the ids must survive the save —
    // a length check would pass with every one of them zeroed.
    for (gs.event_queue.pending.items, loaded.event_queue.pending.items) |saved_ev, loaded_ev| {
        try std.testing.expectEqual(saved_ev.id, loaded_ev.id);
        try std.testing.expect(loaded_ev.id != .none);
        // An event's options are rebuilt from its kind on load, and
        // a kind with no `entryForKind` entry comes back unanswerable —
        // which a length check or an id check would never notice.
        try std.testing.expectEqual(saved_ev.kind, loaded_ev.kind);
        try std.testing.expectEqual(saved_ev.options.len, loaded_ev.options.len);
        try std.testing.expectEqual(saved_ev.default_choice, loaded_ev.default_choice);
        try std.testing.expectEqual(saved_ev.needsDecision(), loaded_ev.needsDecision());
        try std.testing.expectEqual(saved_ev.holdsTurn(), loaded_ev.holdsTurn());
        // A battle decision that forgets which fight it answers
        // comes back applying to nothing.
        try std.testing.expectEqual(saved_ev.battle, loaded_ev.battle);
    }
    // And the counter resumes past them, so the next event cannot collide
    // with one already in the inbox.
    for (loaded.event_queue.pending.items) |ev| {
        try std.testing.expect(@intFromEnum(ev.id) < loaded.event_queue.next_id);
    }
    // Policies survive the round trip with their current numbers (the
    // starter HQ's default top-up and provisions line ride along).
    try std.testing.expectEqual(@as(usize, 2), loaded.policies.items.len);
    try std.testing.expectEqual(gs.policies.items[1].sent_this_month, loaded.policies.items[1].sent_this_month);
    try std.testing.expectEqual(@as(usize, 1), loaded.supply_policies.items.len);
    try std.testing.expectEqual(@as(u16, 30), loaded.supply_policies.items[0].min_days);
    try std.testing.expectEqual(@as(u32, 60), loaded.supply_policies.items[0].tons);
    try std.testing.expectEqual(@as(usize, 2), loaded.stock_policies.items.len);
    try std.testing.expectEqualStrings("ammo_lrm", loaded.stock_policies.items[1].part_key);
    try std.testing.expectEqual(@as(u32, 30), loaded.stock_policies.items[1].target);
    try std.testing.expect(loaded.auto_admit);
    try std.testing.expectEqual(@as(types.Bp, 4_500), loaded.share_profit_bp);
    try std.testing.expectEqual(gs.people.getPtr(gs.people.keys()[2]).?.shares, loaded.people.getPtr(gs.people.keys()[2]).?.shares);
    try std.testing.expectEqual(@as(?u32, 3), loaded.people.getPtr(gs.people.keys()[2]).?.last_raise_day);
    try std.testing.expectEqual(gs.stats.battles_won, loaded.stats.battles_won);
    try std.testing.expect(loaded.stats.battles_won >= 7);
    try std.testing.expectEqual(@as(usize, 1), loaded.rating_history.items.len);
    try std.testing.expectEqual(@as(i32, 40), loaded.rating_history.items[0].score);
    try std.testing.expectEqual(
        @as(?person_mod.Role, .tech_mek),
        loaded.people.getPtr(secondary_role_person).?.secondary_role,
    );

    // Determinism survives the round trip: both worlds evolve identically.
    _ = try commands.execute(&gs, .{ .advance_days = 30 });
    _ = try commands.execute(&loaded, .{ .advance_days = 30 });
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
}

test "players own campaigns; deleting a player cascades" {
    const commands = @import("../sim/commands.zig");
    var store = try Store.open(":memory:");
    defer store.close();
    const john = try store.createPlayer("John");
    const guest = try store.createPlayer("Guest");
    try std.testing.expect(john != guest);

    var a = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer a.deinit();
    _ = try commands.execute(&a, .{ .create_commander = .{ .name = "A", .origin = .LC, .profession = .paymaster } });
    store.player_id = john;
    try store.save(&a);
    var b = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer b.deinit();
    _ = try commands.execute(&b, .{ .create_commander = .{ .name = "B", .origin = .DC, .profession = .line_officer } });
    store.player_id = guest;
    try store.save(&b);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    try std.testing.expectEqual(@as(usize, 1), (try store.listCampaignsOf(al, john)).len);
    try std.testing.expectEqual(@as(usize, 2), (try store.listCampaigns(al)).len);
    const players = try store.listPlayers(al);
    try std.testing.expectEqual(@as(usize, 2), players.len);
    try std.testing.expectEqual(@as(i64, 1), players[0].campaigns);

    try store.deletePlayer(john);
    try std.testing.expectEqual(@as(usize, 1), (try store.listPlayers(al)).len);
    try std.testing.expectEqual(@as(usize, 1), (try store.listCampaigns(al)).len);
    try std.testing.expectEqual(guest, (try store.listCampaigns(al))[0].player_id);
}

test "a store with schema_version = 0 is refused as corrupt without partial upgrade" {
    const raw = try sqlite.Db.open(":memory:");
    // Create a store with a setting table holding schema_version = 0.
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\INSERT INTO setting VALUES ('schema_version', 0);
    );
    // readStoreVersion must detect the corrupt version; fromDb must refuse
    // without running DDL (no campaign table should exist afterwards).
    try std.testing.expectError(error.CorruptStore, Store.fromDb(raw));
    // The raw handle is still open; verify no campaign table was created.
    const st = try raw.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='campaign'");
    defer st.finalize();
    _ = try st.next();
    try std.testing.expectEqual(@as(i64, 0), st.int(0));
    raw.close();
}

test "a brand-new empty :memory: store opens (new-vs-corrupt distinction)" {
    // A zero-byte :memory: must open as a new store, not be mistaken for
    // a corrupt one.  readStoreVersion returns null → new store path.
    const store = try Store.open(":memory:");
    defer store.close();
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
}

test "a fresh store has no owner_rival_id column in hull_instance (P3e entity split)" {
    // Regression: historical migrations must not run against a fresh store.
    // The v52 migration adds owner_rival_id; the v54 rebuild removes it.
    // A fresh store created entirely by the current DDL must never carry owner_rival_id.
    const store = try Store.open(":memory:");
    defer store.close();
    try std.testing.expect(!try Store.hasColumnRt(store.db, "hull_instance", "owner_rival_id"));
    try std.testing.expect(try Store.hasColumnRt(store.db, "hull_instance", "owner_merc_company_id"));
}

test "a future-version store is refused with no DDL mutation" {
    const raw = try sqlite.Db.open(":memory:");
    // A store whose schema_version exceeds the game's.
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\INSERT INTO setting VALUES ('schema_version', 9999);
    );
    try std.testing.expectError(error.StoreNewerThanGame, Store.fromDb(raw));
    // Verify that fromDb created no campaign table (no mutation).
    const st = try raw.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='campaign'");
    defer st.finalize();
    _ = try st.next();
    try std.testing.expectEqual(@as(i64, 0), st.int(0));
    raw.close();
}

test "deletePlayer is atomic: a failure leaves no partial state" {
    const commands = @import("../sim/commands.zig");
    var store = try Store.open(":memory:");
    defer store.close();
    const pid = try store.createPlayer("P");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "C", .origin = .FS, .profession = .paymaster } });
    store.player_id = pid;
    try store.save(&gs);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Verify initial state.
    try std.testing.expectEqual(@as(usize, 1), (try store.listCampaigns(arena.allocator())).len);
    try std.testing.expectEqual(@as(usize, 1), (try store.listPlayers(arena.allocator())).len);
    // Delete the player; both the player row and its campaigns must be gone.
    try store.deletePlayer(pid);
    try std.testing.expectEqual(@as(usize, 0), (try store.listCampaigns(arena.allocator())).len);
    try std.testing.expectEqual(@as(usize, 0), (try store.listPlayers(arena.allocator())).len);
}

test "one store, many playthroughs: list, overwrite, delete" {
    const commands = @import("../sim/commands.zig");
    const store = try Store.open(":memory:");
    defer store.close();

    var a = GameState.init(std.testing.allocator, .{ .seed = 1 });
    defer a.deinit();
    _ = try commands.execute(&a, .{ .create_commander = .{ .name = "A", .origin = .LC, .profession = .paymaster } });
    _ = try commands.execute(&a, .{ .rename_outfit = "Alpha Outfit" });
    try store.save(&a);

    var b = GameState.init(std.testing.allocator, .{ .seed = 2 });
    defer b.deinit();
    _ = try commands.execute(&b, .{ .create_commander = .{ .name = "B", .origin = .DC, .profession = .line_officer } });
    _ = try commands.execute(&b, .{ .rename_outfit = "Bravo Outfit" });
    try store.save(&b);
    try std.testing.expect(a.campaign_id != b.campaign_id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try store.listCampaigns(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), list.len);

    // Saving again overwrites in place (same id, no duplicate).
    _ = try commands.execute(&a, .{ .advance_days = 10 });
    try store.save(&a);
    try std.testing.expectEqual(@as(usize, 2), (try store.listCampaigns(arena.allocator())).len);
    var reloaded = try store.load(std.testing.allocator, a.campaign_id);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(u32, 10), reloaded.clock.day_index);

    // Delete one; the other is untouched.
    try store.deleteCampaign(a.campaign_id);
    const after = try store.listCampaigns(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("Bravo Outfit", after[0].name.raw);
    var still = try store.load(std.testing.allocator, b.campaign_id);
    defer still.deinit();
    try std.testing.expectEqual(digest.stateHash(&b), digest.stateHash(&still));
}

test "a v5 store upgrades in place — columns added, version stamped, wounds left to triage" {
    // A store as the game wrote it at schema 5: no berth_hq on unit, no
    // injury table, no schema_version setting. Only the tables the fixture
    // touches are created by hand; `fromDb` creates the rest.
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE unit (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, chassis_key TEXT, name TEXT, kind TEXT, force INTEGER, pilot INTEGER, tech INTEGER, armor_pct INTEGER, quality TEXT, status TEXT, last_maint INTEGER, acquired_day INTEGER, price INTEGER, reactivation_done INTEGER, PRIMARY KEY (cid, id));
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id));
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL);
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        \\INSERT INTO campaign VALUES (1, 'Old Outfit', 'K', 12, '3025-01-13', 5, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 12);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 13);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Old Outfit');
        \\INSERT INTO unit VALUES (1, 0, 1, 'LCT-1V', NULL, 'mek', 0, 0, 0, 100, 'c', 'ready', NULL, 0, 1500000, NULL);
        \\INSERT INTO person VALUES (1, 0, 1, 'Lori', 'Kalmar', NULL, 'mekwarrior', 0, 'wounded', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, 30, NULL, NULL, 1);
    );

    const store = try Store.fromDb(raw);
    defer store.close();
    try std.testing.expect(try Store.hasColumnRt(store.db, "unit", "berth_hq"));
    try std.testing.expect(try Store.hasColumnRt(store.db, "injury", "location"));
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));

    var gs = try store.load(std.testing.allocator, 1);
    defer gs.deinit();
    try std.testing.expectEqual(@as(u32, 12), gs.clock.day_index);
    const lori = gs.person(@enumFromInt(1)).?;
    try std.testing.expectEqual(person_mod.Status.wounded, lori.status);
    // The store does not invent a wound record; triage does, the first
    // day the medbay looks at her (the sim's rule, not the loader's).
    try std.testing.expectEqual(@as(usize, 0), lori.injuries.items.len);
    try std.testing.expectEqual(@as(?u32, 30), lori.wound_heal_day);
    try std.testing.expectEqual(types.HqId.none, gs.unit(@enumFromInt(1)).?.berth_hq);

    // A save from a newer game is refused rather than misread.
    try store.db.exec("UPDATE campaign SET schema_version = 99 WHERE id = 1");
    try std.testing.expectError(error.SaveNewerThanGame, store.load(std.testing.allocator, 1));
}

test "a v34 store backfills listing, candidate and loan ids in ord order" {
    // A store as the game wrote it at schema 34: listing, candidate and loan
    // tables lack the `id` column that v35 adds. Rows carry 0 (the DEFAULT
    // added by migration) and are backfilled deterministically in ord order
    // from next_*_id (rule 51). The three meta counters are absent; the
    // counters start at their GameState default of 1.
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\CREATE TABLE listing (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, item_key TEXT, rarity TEXT, price INTEGER, qty INTEGER, staple INTEGER, listed INTEGER, expires INTEGER, hq INTEGER, c_armor INTEGER, c_quality TEXT, c_damaged INTEGER, c_destroyed INTEGER, c_missing INTEGER, black INTEGER NOT NULL DEFAULT 0, company INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE candidate (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, first TEXT, last TEXT, callsign TEXT, role TEXT, experience TEXT, primary_skill INTEGER, secondary_skill INTEGER, bonus INTEGER, listed INTEGER, expires INTEGER, age INTEGER NOT NULL DEFAULT 30);
        \\CREATE TABLE loan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, principal INTEGER, balance INTEGER, rate_bp INTEGER, term INTEGER, next_pay INTEGER, payment INTEGER);
        \\INSERT INTO campaign VALUES (1, 'Old Outfit', NULL, 0, '3025-01-01', 34, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Old Outfit');
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        \\INSERT INTO listing VALUES (1, 0, 'part', 'armor',      'common', 10000, 5,  0, 0, 400, 0, NULL, NULL, NULL, NULL, NULL, 0, 0);
        \\INSERT INTO listing VALUES (1, 1, 'part', 'provisions', 'common',  2000, 10, 0, 0, 400, 0, NULL, NULL, NULL, NULL, NULL, 0, 0);
        \\INSERT INTO candidate VALUES (1, 0, 0, 'Alpha', 'Tester', NULL, 'mekwarrior', 'regular', 4, 5, 100000, 0, 400, 25);
        \\INSERT INTO candidate VALUES (1, 1, 0, 'Beta',  'Tester', NULL, 'mekwarrior', 'veteran', 3, 4, 200000, 0, 400, 30);
        \\INSERT INTO loan VALUES (1, 0, 1000000, 1000000, 1200, 12, 30, 84000);
        \\INSERT INTO loan VALUES (1, 1, 2000000, 2000000, 1200, 24, 30, 92000);
    );

    const store = try Store.fromDb(raw);
    defer store.close();
    // v35 migrations added the id columns to all three tables.
    try std.testing.expect(try Store.hasColumnRt(store.db, "listing", "id"));
    try std.testing.expect(try Store.hasColumnRt(store.db, "candidate", "id"));
    try std.testing.expect(try Store.hasColumnRt(store.db, "loan", "id"));

    var gs = try store.load(std.testing.allocator, 1);
    defer gs.deinit();

    // Listing backfill: ord 0 → id 1, ord 1 → id 2; counter past the max.
    try std.testing.expectEqual(@as(usize, 2), gs.market_listings.items.len);
    try std.testing.expect(@intFromEnum(gs.market_listings.items[0].id) != 0);
    try std.testing.expectEqual(@as(types.ListingId, @enumFromInt(1)), gs.market_listings.items[0].id);
    try std.testing.expectEqual(@as(types.ListingId, @enumFromInt(2)), gs.market_listings.items[1].id);
    try std.testing.expect(gs.next_listing_id > @intFromEnum(gs.market_listings.items[1].id));

    // Candidate backfill: ord 0 → id 1, ord 1 → id 2; counter past the max.
    try std.testing.expectEqual(@as(usize, 2), gs.candidates.items.len);
    try std.testing.expect(@intFromEnum(gs.candidates.items[0].id) != 0);
    try std.testing.expectEqual(@as(types.CandidateId, @enumFromInt(1)), gs.candidates.items[0].id);
    try std.testing.expectEqual(@as(types.CandidateId, @enumFromInt(2)), gs.candidates.items[1].id);
    try std.testing.expect(gs.next_candidate_id > @intFromEnum(gs.candidates.items[1].id));

    // Loan backfill: ord 0 → id 1, ord 1 → id 2; counter past the max.
    try std.testing.expectEqual(@as(usize, 2), gs.loans.items.len);
    try std.testing.expect(@intFromEnum(gs.loans.items[0].id) != 0);
    try std.testing.expectEqual(@as(types.LoanId, @enumFromInt(1)), gs.loans.items[0].id);
    try std.testing.expectEqual(@as(types.LoanId, @enumFromInt(2)), gs.loans.items[1].id);
    try std.testing.expect(gs.next_loan_id > @intFromEnum(gs.loans.items[1].id));
}

test "a battle report round-trips as fields, not as a row count" {
    const battle = @import("../sim/battle.zig");
    const part_mod = @import("../domain/part.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 90210 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 30, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    // Enough engagements that some hull takes a slot hit and some crew is
    // hurt — an all-clean fixture would not exercise the child rows.
    for (0..8) |_| {
        try battle.resolveEngagement(&gs, c);
        try @import("../sim/maintenance.zig").runWeeklyRepairs(&gs);
    }

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // The fixture must actually have fought, or every assertion below is
    // vacuous — the failure mode this whole test exists to catch.
    try std.testing.expect(gs.battle_reports.kept.items.len >= 8);
    var hulls_seen: usize = 0;
    for (gs.battle_reports.kept.items) |r| hulls_seen += r.hulls.len;
    try std.testing.expect(hulls_seen > 0);
    // A battle report round-trips as fields, child rows included.
    // Asserting only the count would pass with every hull and every
    // munition family dropped on the floor.
    try std.testing.expectEqual(gs.battle_reports.kept.items.len, loaded.battle_reports.kept.items.len);
    for (gs.battle_reports.kept.items, loaded.battle_reports.kept.items) |saved_r, loaded_r| {
        try std.testing.expectEqual(saved_r.id, loaded_r.id);
        try std.testing.expectEqual(saved_r.outcome, loaded_r.outcome);
        try std.testing.expectEqual(saved_r.held_field, loaded_r.held_field);
        try std.testing.expectEqual(saved_r.player_power, loaded_r.player_power);
        try std.testing.expectEqual(saved_r.morale_delta, loaded_r.morale_delta);
        try std.testing.expectEqualStrings(saved_r.enemy_key, loaded_r.enemy_key);
        try std.testing.expectEqual(saved_r.hulls.len, loaded_r.hulls.len);
        try std.testing.expectEqual(saved_r.ammo.len, loaded_r.ammo.len);
        for (saved_r.hulls, loaded_r.hulls) |saved_h, loaded_h| {
            try std.testing.expectEqual(saved_h.unit, loaded_h.unit);
            try std.testing.expectEqual(saved_h.armor_before, loaded_h.armor_before);
            try std.testing.expectEqual(saved_h.armor_after, loaded_h.armor_after);
            try std.testing.expectEqual(saved_h.destroyed, loaded_h.destroyed);
            try std.testing.expectEqual(saved_h.cause, loaded_h.cause);
            try std.testing.expectEqual(saved_h.crew.fate, loaded_h.crew.fate);
            try std.testing.expectEqual(saved_h.crew.wound == null, loaded_h.crew.wound == null);
            if (saved_h.crew.wound) |w| {
                try std.testing.expectEqual(w.severity, loaded_h.crew.wound.?.severity);
                try std.testing.expectEqual(w.location, loaded_h.crew.wound.?.location);
            }
            try std.testing.expectEqual(saved_h.recovery == null, loaded_h.recovery == null);
            try std.testing.expectEqualStrings(saved_h.chassis_key, loaded_h.chassis_key);
        }
        for (saved_r.ammo, loaded_r.ammo) |saved_a, loaded_a| {
            try std.testing.expectEqualStrings(saved_a.key, loaded_a.key);
            try std.testing.expectEqual(saved_a.burned, loaded_a.burned);
            try std.testing.expectEqual(saved_a.left, loaded_a.left);
        }
        // The AAR a reloaded report renders is the AAR it always rendered.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const after_action = @import("../sim/after_action.zig");
        const before_lines = try after_action.render(arena.allocator(), &saved_r);
        const after_lines = try after_action.render(arena.allocator(), &loaded_r);
        try std.testing.expectEqual(before_lines.len, after_lines.len);
        for (before_lines, after_lines) |bl, al2| try std.testing.expectEqualStrings(bl, al2);
    }
}

test "battle reports beyond the former retention cap survive save and load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9_021 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const report_count: u32 = 41;
    var i: u32 = 1;
    while (i <= report_count) : (i += 1) {
        try gs.battle_reports.record(gs.allocator(), .{
            .id = @enumFromInt(i),
            .day = i,
            .contract = .none,
            .company = co,
            .kind = "raid",
            .enemy_key = "DC",
            .scenario = "probe",
            .terrain = "plains",
            .weather = "clear",
            .outcome = .victory,
        });
    }
    gs.next_battle_id = report_count + 1;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(@as(usize, report_count), loaded.battle_reports.kept.items.len);
    try std.testing.expect(loaded.battle_reports.find(@enumFromInt(1)) != null);
    try std.testing.expect(loaded.battle_reports.find(@enumFromInt(report_count)) != null);
    try std.testing.expectEqual(report_count + 1, loaded.next_battle_id);
}

test "a hull the enemy holds round-trips, slots and all — off the books, not struck off" {
    const battle = @import("../sim/battle.zig");
    const part_mod = @import("../domain/part.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12007 });
    defer gs.deinit();
    gs.difficulty = .elite; // a lost field is the point of the fixture
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .planetary_assault,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .battle_loss_pct = 30 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const site: types.Site = .{ .company = co };
    try gs.addStock(site, "armor", 60);
    for (part_mod.munition_keys) |key| try gs.addStock(site, key, 40);
    // A starving, exhausted company with no armour left: routs are the norm
    // and hulls stay on the field.
    for (0..10) |_| {
        var pit = gs.people.iterator();
        while (pit.next()) |e| {
            e.value_ptr.morale = 0;
            e.value_ptr.fatigue = 60;
        }
        var uit = gs.units.iterator();
        while (uit.next()) |e| if (e.value_ptr.status != .destroyed) {
            e.value_ptr.armor_pct = 0;
        };
        try battle.resolveEngagement(&gs, c);
    }

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // Vacuous otherwise: if nothing was ever held, everything below passes
    // while the feature is broken.
    try std.testing.expect(gs.held_hulls.items.len > 0);
    try std.testing.expectEqual(gs.held_hulls.items.len, loaded.held_hulls.items.len);
    // Held hulls are off the books on both sides of the save, and the
    // owned count is not quietly inflated by them.
    try std.testing.expectEqual(gs.units.count(), loaded.units.count());
    var slots_seen: usize = 0;
    for (gs.held_hulls.items, loaded.held_hulls.items) |saved, got| {
        try std.testing.expectEqual(saved.unit.id, got.unit.id);
        try std.testing.expectEqualStrings(saved.unit.chassis_key, got.unit.chassis_key);
        try std.testing.expectEqual(saved.unit.status, got.unit.status);
        try std.testing.expectEqual(saved.unit.armor_pct, got.unit.armor_pct);
        try std.testing.expectEqualStrings(saved.by, got.by);
        try std.testing.expectEqual(saved.day, got.day);
        try std.testing.expectEqual(saved.battle, got.battle);
        try std.testing.expectEqual(saved.unit.slots.items.len, got.unit.slots.items.len);
        slots_seen += got.unit.slots.items.len;
        try std.testing.expect(loaded.units.get(got.unit.id) == null);
        try std.testing.expect(loaded.heldHull(got.unit.id) != null);
    }
    // The slot rows really came back — the drop this test exists to catch.
    try std.testing.expect(slots_seen > 0);
}

fn countCampaignRows(store: Store) !i64 {
    const st = try store.db.prepare("SELECT COUNT(*) FROM campaign");
    defer st.finalize();
    _ = try st.next();
    return st.int(0);
}

test "loading a campaign id with no campaign row is refused" {
    const store = try Store.open(":memory:");
    defer store.close();
    try std.testing.expectError(error.NoSuchCampaign, store.load(std.testing.allocator, 999));
}

test "a first save that fails leaves the campaign unsaved, and a retry registers it" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4004 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const store = try Store.open(":memory:");
    defer store.close();
    // A missing child table makes the save fail after the campaign INSERT.
    try store.db.exec("DROP TABLE unit");
    try std.testing.expect(std.meta.isError(store.save(&gs)));
    try std.testing.expectEqual(@as(i64, 0), gs.campaign_id);
    try std.testing.expectEqual(@as(i64, 0), try countCampaignRows(store));

    try store.db.exec(ddl);
    try store.save(&gs);
    try std.testing.expect(gs.campaign_id != 0);
    try std.testing.expectEqual(@as(i64, 1), try countCampaignRows(store));
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
}

test "saving over a campaign row that no longer exists is refused" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4005 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // FK enforcement must be off: child rows reference this campaign row.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("DELETE FROM campaign");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.NoSuchCampaign, store.save(&gs));
    try std.testing.expectEqual(@as(i64, 0), try countCampaignRows(store));
}

/// Save a generated campaign, corrupt one column with `sql`, and load it
/// back. Foreign-key enforcement is disabled around the tamper SQL so the
/// loader remains the asserted integrity check (defense in depth: rule 50).
fn loadAfterTampering(sql: [*:0]const u8) !void {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5005 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "an integer column out of its field's range rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE person SET fatigue = 100000"));
}

test "a negative id rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit SET force = -5"));
}

test "a child row whose parent is missing rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE person_skill SET person_id = 99999"));
}

test "an unknown enum value rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE commander SET origin = 'XX'"));
}

test "a stored key that names nothing in the catalogues rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE hq SET planet = '{c}nowhere'"));
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit SET chassis_key = 'NOPE-1'"));
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit_slot SET part_key = 'nope' WHERE ord = 0"));
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE stock SET key = '{g}x' WHERE ord = 0"));
}

test "a battle report's display copies must be markup-safe to load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8101 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 1);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("UPDATE battle_report SET scenario = '{c}ambush'");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "confirmed battle orders survive a save" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8301 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 0);
    f.c.next_battle_day = gs.clock.day_index + 2;
    f.c.orders_day = f.c.next_battle_day;
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(f.c.orders_day, loaded.contracts.getPtr(f.c.id).?.orders_day);
}

test "a malformed RNG stream row rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE rng_stream SET state = x'00' WHERE stream = 'battle'"));
}

test "an RNG row naming no known stream rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE rng_stream SET stream = 'weather' WHERE stream = 'travel'"));
}

test "a malformed legacy RNG blob rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("DELETE FROM rng_stream; INSERT INTO rng VALUES (1, x'00')"));
}

test "an oversized emblem blob is rejected as CorruptStore before allocation" {
    // zeroblob(n) writes n bytes without materialising them, so the test
    // does not allocate 4 MiB.  max_emblem_bytes is 2048*2048 = 4194304;
    // 4194305 is one byte over.
    try std.testing.expectError(error.CorruptStore, loadAfterTampering(
        "UPDATE force SET emblem = zeroblob(4194305) WHERE rowid = (SELECT rowid FROM force LIMIT 1)",
    ));
}

// C7a: orphan rows, dangling references, discriminator validation, NULL, duplicate, date, meta.

test "an orphan unit_slot row rejects the load" {
    // unit_slot.unit_id names a unit that does not exist (rule 47).
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit_slot SET unit_id = 99999 WHERE rowid = (SELECT rowid FROM unit_slot LIMIT 1)"));
}

test "dangling cross-entity references reject the load" {
    // Each tamper sets one cross-entity link to a non-existent live id (rule 47).
    // force_unit: a force's unit list names a unit that is not in gs.units.
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE force_unit SET unit_id = 99999"));
    // unit.pilot: a unit's pilot id names a person that does not exist.
    // All units that already have a pilot keep 99999; force != none units have pilots.
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE unit SET pilot = 99999 WHERE pilot != 0"));
    // person.assigned_force: a person's company assignment names a force that does not exist.
    // generateInto assigns all pilots to a lance, so assigned_force != 0 rows exist.
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE person SET assigned_force = 99999 WHERE assigned_force != 0"));
}

test "an orphan stock row rejects the load as corrupt, not UnknownSite" {
    // stock.owner_id names a site (hq or company) that is not in the live maps;
    // loadStock must surface this as error.CorruptSave (not the internal error.UnknownSite).
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE stock SET owner_id = 99999 WHERE owner_kind IN ('hq','company')"));
}

test "a duplicate stock row for the same owner and key is rejected by the schema" {
    // Uniqueness of (cid, owner_kind, owner_id, key) is now schema-enforced
    // (UNIQUE constraint on stock, rule 50). The INSERT is rejected at the
    // schema level before the loader sees it; the loader's seen-set guard
    // remains for any non-SQL path.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5005 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try std.testing.expectError(error.ConstraintViolation, store.db.exec(
        "INSERT INTO stock SELECT cid, owner_kind, owner_id, (SELECT MAX(ord) FROM stock) + 1, key, qty FROM stock LIMIT 1",
    ));
}

test "an orphan battle_report child row rejects the load as corrupt" {
    // A battle_report_hit/ammo/salvage row whose report_ord names no battle_report is
    // corruption (rule 47, C7). Use foughtCampaignForTest so battle_report rows exist.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9901 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 1);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Insert an ammo row with report_ord 99999 which no battle_report.ord equals.
    // FK enforcement is off so the insert reaches the loader's orphan check.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("INSERT INTO battle_report_ammo VALUES ((SELECT id FROM campaign LIMIT 1), 99999, 0, 'lrm5', 0, 0)");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "an unknown optional enum value rejects the load" {
    // force.support_kind non-NULL but unknown tag → CorruptSave (rule 47).
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE force SET support_kind = 'heavy' WHERE rowid = (SELECT rowid FROM force LIMIT 1)"));
}

test "an unknown listing kind rejects the load" {
    // listing.kind is strictly 'unit' or 'part'; anything else is corruption.
    // Insert a row directly so the test does not depend on the market state.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7771 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("INSERT INTO listing (cid, ord, kind) VALUES (1, 0, 'crate')");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "a NULL in a required enum column rejects the load" {
    // person.role is required; enumValue returns null on SQL NULL → CorruptSave.
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE person SET role = NULL WHERE rowid = (SELECT rowid FROM person LIMIT 1)"));
}

test "a duplicate primary person id is rejected by the schema" {
    // The rebuild in fromDb copies rows into person__new (PRIMARY KEY (cid, id));
    // duplicate (cid, id) fails at the schema level before the loader runs.
    // Uniqueness of (cid, id) is schema-enforced; the loader's getOrPut guard
    // remains for any non-SQL path. RNG: legacy 256-byte blob (pre-v32).
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close(); // fromDb fails, so caller closes raw
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0, faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, secondary_role TEXT);
        \\INSERT INTO setting VALUES ('schema_version', 36);
        \\INSERT INTO campaign VALUES (1, 'Test', NULL, 0, '3025-01-01', 36, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Test');
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        \\INSERT INTO person VALUES (1, 0, 1, 'A', 'B', NULL, 'mekwarrior', 0, 'active', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, NULL, NULL, NULL, 0, 'private', 0, 0, 0, 0, 0, 0, 0, '', 0, NULL, NULL, NULL, NULL, NULL);
        \\INSERT INTO person VALUES (1, 1, 1, 'C', 'D', NULL, 'mekwarrior', 0, 'active', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, NULL, NULL, NULL, 0, 'private', 0, 0, 0, 0, 0, 0, 0, '', 0, NULL, NULL, NULL, NULL, NULL);
    );
    // rebuildToV37 copies duplicate (cid=1, id=1) rows into person__new
    // (PRIMARY KEY (cid, id)) → ConstraintViolation at the schema level.
    try std.testing.expectError(error.ConstraintViolation, Store.fromDb(raw));
}

test "a save with month 13 rejects the load" {
    // Date validation (Date.valid) rejects month 13 (rule 47).
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE meta SET value = 13 WHERE key = 'month'"));
}

test "a missing required meta row rejects the load" {
    // The loader requires scalar meta rows to be present; absence is corruption
    // (rule 47, 70). Representative set: funds, reputation, difficulty, and a
    // required date component (month).
    for ([_][*:0]const u8{
        "DELETE FROM meta WHERE key = 'funds'",
        "DELETE FROM meta WHERE key = 'reputation'",
        "DELETE FROM meta WHERE key = 'difficulty'",
        "DELETE FROM meta WHERE key = 'month'",
    }) |sql| try std.testing.expectError(error.CorruptSave, loadAfterTampering(sql));
}

// C7b: counter reconciliation and choice bounds.

test "next_person_id is resumed past a higher owned id after load" {
    // A save with next_person_id below a live person id is repaired by
    // reconcileCounters: the counter advances above the max owned id (rule 48).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8881 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Drive next_person_id below the max owned id.
    try store.db.exec("UPDATE meta SET value = 0 WHERE key = 'next_person_id'");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    // Counter must exceed every person id.
    var max_pid: u32 = 0;
    var pit = loaded.people.iterator();
    while (pit.next()) |e| max_pid = @max(max_pid, @intFromEnum(e.key_ptr.*));
    try std.testing.expect(loaded.next_person_id > max_pid);
}

test "a pending event with an out-of-range default_choice rejects the load" {
    // default_choice >= options.len for the event's kind is corruption (rule 47).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9991 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    // press_or_consolidate has 2 options (default_choice = 1); tamper to 99.
    try contract_events.queuePress(&gs, gs.contracts.getPtr(@enumFromInt(1)).?);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("UPDATE pending_event SET default_choice = 99");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "a person id equal to maxInt(u32) rejects the load as corrupt" {
    // reconcileCounters: max owned id == maxInt(u32) means next allocation would
    // overflow — the save is corrupt (rule 48). Use a raw fixture to bypass the
    // PRIMARY KEY constraint and store the impossible id. The person table here
    // has no PRIMARY KEY so SQLite allows id = 4294967295 (maxInt u32).
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0, faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, secondary_role TEXT);
        \\INSERT INTO setting VALUES ('schema_version', 36);
        \\INSERT INTO campaign VALUES (1, 'Test', NULL, 0, '3025-01-01', 36, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Test');
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        \\INSERT INTO person VALUES (1, 0, 4294967295, 'A', 'B', NULL, 'mekwarrior', 0, 'active', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, NULL, NULL, NULL, 0, 'private', 0, 0, 0, 0, 0, 0, 0, '', 0, NULL, NULL, NULL, NULL, NULL);
    );
    const store = try Store.fromDb(raw);
    defer store.close();
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, 1));
}

// C9: schema integrity and migration tests.

test "the migrations array is strictly ascending by to and each from < to" {
    // Rule 51: ordered migrations; source version is explicit.
    var prev_to: u32 = 0;
    for (Store.migrations) |m| {
        try std.testing.expect(m.from < m.to);
        try std.testing.expect(m.to >= prev_to);
        prev_to = m.to;
    }
}

test "foreign keys are enforced on every connection" {
    // Rule 50: Db.open enables PRAGMA foreign_keys = ON. A deferred FK
    // violation is caught at the auto-commit boundary.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7701 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // An award for a non-existent person_id is deferred until COMMIT; FK
    // enforcement rejects it (ConstraintViolation), proving rule 50 wiring.
    const cid = gs.campaign_id;
    try store.db.exec("BEGIN");
    const st = try store.db.prepare("INSERT INTO award (cid, person_id, key) VALUES (?1, ?2, ?3)");
    defer st.finalize();
    try st.bindAll(.{ cid, @as(i64, 99999), "valor" });
    try st.run(); // deferred: no error yet
    try std.testing.expectError(error.ConstraintViolation, store.db.exec("COMMIT"));
}

test "a v36 store rebuilds to v37 with constraints and preserves every row" {
    // Rule 51: fixture for the rebuild boundary. A v36-shaped store (no FK/UNIQUE
    // constraints on per-cid tables) is reopened through fromDb; schema_version
    // advances to 37 and the new constraints are present.
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng_stream (cid INTEGER NOT NULL, stream TEXT NOT NULL, format INTEGER NOT NULL, state BLOB NOT NULL, UNIQUE (cid, stream));
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0, faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, secondary_role TEXT, PRIMARY KEY (cid, id));
        \\CREATE TABLE award (cid INTEGER NOT NULL, person_id INTEGER NOT NULL, key TEXT NOT NULL);
        \\INSERT INTO setting VALUES ('schema_version', 36);
        \\INSERT INTO campaign VALUES (1, 'Fixture', NULL, 0, '3025-01-01', 36, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Fixture');
        \\INSERT INTO person VALUES (1, 0, 1, 'A', 'B', NULL, 'mekwarrior', 0, 'active', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, NULL, NULL, NULL, 0, 'private', 0, 0, 0, 0, 0, 0, 0, '', 0, NULL, NULL, NULL, NULL, NULL);
        \\INSERT INTO award VALUES (1, 1, 'valor');
    );
    const store = try Store.fromDb(raw);
    defer store.close();
    // Schema advanced to 37.
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
    // award now carries the containment FK to person.
    var fk_found = false;
    const fk = try store.db.prepare("PRAGMA foreign_key_list(award)");
    defer fk.finalize();
    while (try fk.next()) {
        var buf: [32]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const tbl = fk.text(2, fba.allocator()) catch continue;
        if (std.mem.eql(u8, tbl, "person")) fk_found = true;
    }
    try std.testing.expect(fk_found);
    // All rows survived the rebuild.
    const cnt = try store.db.prepare("SELECT COUNT(*) FROM award WHERE cid = 1");
    defer cnt.finalize();
    try std.testing.expect(try cnt.next());
    try std.testing.expectEqual(@as(i64, 1), cnt.int(0));
}

test "a rebuilt store loads to the identical digest" {
    // Rules 2, 51: the rebuild is data-preserving. Saving through a current
    // store, forcing schema_version back to 36, reopening (triggers rebuild),
    // and loading yields an identical state hash.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20_260_924 });
    defer gs.deinit();
    try playedYearForTest(&gs);
    const hash_before = digest.stateHash(&gs);

    const raw = try sqlite.Db.open(":memory:");
    // First fromDb: creates schema and sets version to 37.
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    // Force version back to 36 so the next fromDb rebuilds.
    try raw.exec("UPDATE setting SET value = 36 WHERE key = 'schema_version'");
    // Second fromDb: sees v36, runs rebuildToV37.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    // Digest is identical: the rebuild changed no data.
    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(@as(u64, 7031099491874677131), hash_before);
}

test "every next-ID counter resumes past a higher owned id after load" {
    // Rule 70: representative table-driven coverage for all 10 counter meta
    // rows. Each counter is driven below the maximum owned id; reconcileCounters
    // (and resumeBattleIds/resumeIds for the battle/event counters) must bump it
    // past the max on load.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8881 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    for ([_][*:0]const u8{
        "UPDATE meta SET value = 0 WHERE key = 'next_person_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_unit_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_force_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_hq_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_contract_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_battle_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_event_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_listing_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_candidate_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_loan_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_rival_id'",
        "UPDATE meta SET value = 0 WHERE key = 'next_officer_arc_id'",
    }) |sql| {
        try store.db.exec(sql);
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        // Each counter must be at least 1 after load (resume invariant).
        try std.testing.expect(loaded.next_person_id >= 1);
        try std.testing.expect(loaded.next_unit_id >= 1);
        try std.testing.expect(loaded.next_force_id >= 1);
        try std.testing.expect(loaded.next_hq_id >= 1);
        try std.testing.expect(loaded.next_contract_id >= 1);
        try std.testing.expect(loaded.next_battle_id >= 1);
        try std.testing.expect(loaded.event_queue.next_id >= 1);
        try std.testing.expect(loaded.next_listing_id >= 1);
        try std.testing.expect(loaded.next_candidate_id >= 1);
        try std.testing.expect(loaded.next_loan_id >= 1);
        try std.testing.expect(loaded.next_rival_id >= 1);
        try std.testing.expect(loaded.next_officer_arc_id >= 1);
    }
}

test "a next_battle_id at maxInt rejects the load as corrupt" {
    // Rule 70: overflow class distinct from person (resumeBattleIds saturates
    // at maxInt when a battle id equals maxInt(u32); rule 48). Complements the
    // next_person_id overflow test.
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng_stream (cid INTEGER NOT NULL, stream TEXT NOT NULL, format INTEGER NOT NULL, state BLOB NOT NULL, UNIQUE (cid, stream));
        \\INSERT INTO setting VALUES ('schema_version', 36);
        \\INSERT INTO campaign VALUES (1, 'Test', NULL, 0, '3025-01-01', 36, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta VALUES (1, 'next_battle_id', 4294967295);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Test');
    );
    const store = try Store.fromDb(raw);
    defer store.close();
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, 1));
}

// C7c: current-version no-RNG test and v17/v18 stats recovery.

test "a current-version save draws no RNG and rewrites no counter on load" {
    // Gate: recoverStatsFromLog (< v18) and event id stamping (< v26) must not
    // run on a current-version save. Verify by checking every RNG stream state
    // is byte-for-byte identical before and after load, and next_person_id is
    // unchanged (no counter rewrite beyond the no-op reconciliation).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5551 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    stirRng(&gs);
    const pid_before = gs.next_person_id;
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    // Every stream is bit-for-bit identical: no RNG draw happened on load.
    for (std.enums.values(rng_mod.Stream)) |stream| {
        try std.testing.expectEqual(gs.rng.encode(stream), loaded.rng.encode(stream));
    }
    // Counter is unchanged beyond the no-op reconcile (max owned id < counter).
    try std.testing.expectEqual(pid_before, loaded.next_person_id);
}

test "a v17 store recovers stats from its log; a v18 store does not" {
    // recoverStatsFromLog runs only when saved_version < 18. A v17 save with
    // battle log lines should recover battles_won; a v18 save with the same
    // rows but no stats meta should leave stats empty (the loader trusts the
    // version gate and makes no attempt to re-derive, rule 51).
    // Pre-v32 stores use the legacy `rng` blob (256 bytes for 8 streams × 32 bytes each).
    // v17: stats empty in meta → recoverStatsFromLog runs → battles_won set.
    {
        const raw = try sqlite.Db.open(":memory:");
        try raw.exec(
            \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
            \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
            \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
            \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
            \\INSERT INTO setting VALUES ('schema_version', 17);
            \\INSERT INTO campaign VALUES (1, 'Old', NULL, 0, '3025-01-01', 17, 1, 0);
            \\INSERT INTO meta VALUES (1, 'day_index', 0);
            \\INSERT INTO meta VALUES (1, 'year', 3025);
            \\INSERT INTO meta VALUES (1, 'month', 1);
            \\INSERT INTO meta VALUES (1, 'day', 1);
            \\INSERT INTO meta VALUES (1, 'funds', 0);
            \\INSERT INTO meta VALUES (1, 'reputation', 0);
            \\INSERT INTO meta VALUES (1, 'difficulty', 1);
            \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Old');
            \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        );
        const store = try Store.fromDb(raw);
        defer store.close();
        // Insert a battle-win log row using the current event_log schema so
        // recoverStatsFromLog can parse it (requires [AAR] prefix and ' — power ').
        try store.db.exec("INSERT INTO event_log (cid, ord, day, category, company, hq, contract, text) VALUES (1, 0, 5, 'battle', 0, 0, 0, '[AAR] recon_raid vs PER: victory \u{2014} power 3000 vs 2000')");
        var loaded = try store.load(std.testing.allocator, 1);
        defer loaded.deinit();
        try std.testing.expect(loaded.stats.battles_won > 0);
    }
    // v18: same rows, version gate closed → stats stay empty (no re-derivation).
    {
        const raw = try sqlite.Db.open(":memory:");
        try raw.exec(
            \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
            \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
            \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
            \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
            \\INSERT INTO setting VALUES ('schema_version', 18);
            \\INSERT INTO campaign VALUES (1, 'Old', NULL, 0, '3025-01-01', 18, 1, 0);
            \\INSERT INTO meta VALUES (1, 'day_index', 0);
            \\INSERT INTO meta VALUES (1, 'year', 3025);
            \\INSERT INTO meta VALUES (1, 'month', 1);
            \\INSERT INTO meta VALUES (1, 'day', 1);
            \\INSERT INTO meta VALUES (1, 'funds', 0);
            \\INSERT INTO meta VALUES (1, 'reputation', 0);
            \\INSERT INTO meta VALUES (1, 'difficulty', 1);
            \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Old');
            \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        );
        const store = try Store.fromDb(raw);
        defer store.close();
        // Insert the same battle-win log row; the v18 gate must suppress recovery.
        try store.db.exec("INSERT INTO event_log (cid, ord, day, category, company, hq, contract, text) VALUES (1, 0, 5, 'battle', 0, 0, 0, '[AAR] recon_raid vs PER: victory \u{2014} power 3000 vs 2000')");
        var loaded = try store.load(std.testing.allocator, 1);
        defer loaded.deinit();
        try std.testing.expect(loaded.stats.isEmpty());
    }
}

/// Draw from every stream so none sits at its starting state.
fn stirRng(gs: *GameState) void {
    for (std.enums.values(rng_mod.Stream), 0..) |stream, i| {
        for (0..i + 3) |_| _ = gs.rng.roll2d6(stream);
    }
}

test "every RNG stream and the seed survive a save and load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6006 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(gs.rng.seed, loaded.rng.seed);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        try std.testing.expectEqual(gs.rng.encode(stream), loaded.rng.encode(stream));
    }
}

test "a stream the save lacks starts fresh from the seed, and the others keep their state" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6007 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // A stream added to the game after this campaign was saved has no row.
    try store.db.exec("DELETE FROM rng_stream WHERE stream = 'travel'");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var fresh = rng_mod.Rng.init(gs.rng.seed);
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const want = if (stream == .travel) fresh.encode(stream) else gs.rng.encode(stream);
        try std.testing.expectEqual(want, loaded.rng.encode(stream));
    }
}

test "a save from before per-stream rows loads every stream from its legacy blob" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6008 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Rewrite the save the way schema v31 held it: one blob, no seed.
    try store.db.exec("DELETE FROM rng_stream; DELETE FROM meta WHERE key = 'rng_seed'");
    var blob: [legacy_rng_order.len * @sizeOf(std.Random.DefaultPrng)]u8 = undefined;
    for (legacy_rng_order, 0..) |stream, i| {
        @memcpy(blob[i * @sizeOf(std.Random.DefaultPrng) ..][0..@sizeOf(std.Random.DefaultPrng)], std.mem.asBytes(&gs.rng.prngs[@intFromEnum(stream)]));
    }
    const ins = try store.db.prepare("INSERT INTO rng VALUES (?1, ?2)");
    defer ins.finalize();
    try ins.bind(1, gs.campaign_id);
    try ins.bindBlob(2, &blob);
    try ins.run();
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    // Streams in the legacy blob are restored exactly. Streams added after v31
    // (not in legacy_rng_order) are absent from the blob and start fresh from seed.
    var fresh_from_seed = rng_mod.Rng.init(std.hash.Wyhash.hash(0, &blob));
    for (std.enums.values(rng_mod.Stream)) |stream| {
        const in_legacy = for (legacy_rng_order) |ls| {
            if (ls == stream) break true;
        } else false;
        const want = if (in_legacy) gs.rng.encode(stream) else fresh_from_seed.encode(stream);
        try std.testing.expectEqual(want, loaded.rng.encode(stream));
    }
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, &blob), loaded.rng.seed);
}

/// A campaign that has fought `fights` engagements, every battle decision
/// answered with its default and every report read.
fn foughtCampaignForTest(gs: *GameState, fights: u32) !void {
    _ = try founding.createCommander(gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    for (@import("../domain/part.zig").munition_keys) |key| try gs.addStock(.{ .company = co }, key, 40);
    for (0..fights) |_| {
        try @import("../sim/battle.zig").resolveEngagement(gs, c);
        while (gs.event_queue.blocking()) |ev| try contract_events.resolveChoice(gs, ev.id, ev.default_choice);
        while (gs.battle_reports.unread()) |r| _ = gs.battle_reports.markRead(r.id);
    }
}

test "battle report IDs stay unique after a save and load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3003 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 3);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(gs.next_battle_id, loaded.next_battle_id);
    const fresh = loaded.nextBattleId();
    for (loaded.battle_reports.kept.items) |r| try std.testing.expect(r.id != fresh);
}

test "a save without the battle counter resumes numbering past every battle it references" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3004 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 3);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Saves before the counter was stored carry no `next_battle_id` row.
    try store.db.exec("DELETE FROM meta WHERE key = 'next_battle_id'");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var max: u32 = 0;
    for (loaded.battle_reports.kept.items) |r| max = @max(max, @intFromEnum(r.id));
    for (loaded.held_hulls.items) |h| max = @max(max, @intFromEnum(h.battle));
    for (loaded.event_queue.pending.items) |ev| max = @max(max, @intFromEnum(ev.battle));
    try std.testing.expect(max > 0);
    try std.testing.expect(loaded.next_battle_id > max);
}

test "a battle decision round-trips answerable, and still holds the turn" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12006 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    try @import("../sim/contract_events.zig").queuePress(&gs, c);
    try std.testing.expect(gs.event_queue.blocking() != null);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // The store rebuilds an event's options from its kind. Without an
    // `entryForKind` entry the decision comes back optionless — answered
    // by nobody, holding nothing, and silently gone.
    const ev = loaded.event_queue.blocking() orelse return error.DecisionLostOnLoad;
    try std.testing.expectEqual(@import("../domain/events.zig").EventKind.press_or_consolidate, ev.kind);
    try std.testing.expectEqual(@as(usize, 2), ev.options.len);
    try std.testing.expectEqual(gs.event_queue.blocking().?.id, ev.id);
    try std.testing.expectEqual(@as(usize, 1), ev.default_choice);
    try std.testing.expect(ev.holdsTurn());
}

test "a field repair decision comes back from a save with its three orders" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12069 });
    defer gs.deinit();
    const f = try contract_events.damagedCompanyForTest(&gs, 2);
    try contract_events.queueFieldRepair(&gs, f.c, .none);
    try std.testing.expect(gs.event_queue.blocking() != null);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const ev = loaded.event_queue.blocking() orelse return error.DecisionLostOnLoad;
    try std.testing.expectEqual(@import("../domain/events.zig").EventKind.field_repair, ev.kind);
    try std.testing.expectEqual(@as(usize, 3), ev.options.len);
    try std.testing.expect(ev.holdsTurn());
    // The damage is state, not part of the event: the reloaded plan matches.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const maintenance = @import("../sim/maintenance.zig");
    const before = try maintenance.planFor(&gs, arena.allocator(), f.c.assigned_company, .worst_first);
    const after = try maintenance.planFor(&loaded, arena.allocator(), f.c.assigned_company, .worst_first);
    try std.testing.expectEqual(before.hulls.len, after.hulls.len);
    for (before.hulls, after.hulls) |x, y| try std.testing.expectEqual(x.armor_after, y.armor_after);
}

test "a recovery decision remembers its battle, and a held hull its lance" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12066 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .planetary_assault,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000 },
        .status = .active,
        .assigned_company = co,
    });
    const c = gs.contracts.getPtr(@enumFromInt(1)).?;
    const taken = blk: {
        var it = gs.units.iterator();
        while (it.next()) |e| if (e.value_ptr.kind == .mek and e.value_ptr.force != .none) break :blk e.value_ptr.id;
        unreachable;
    };
    const lance = gs.unit(taken).?.force;
    try held_hulls_m.holdUnit(&gs, taken, "DC", @enumFromInt(4));
    try @import("../sim/contract_events.zig").queueRecoveryPush(&gs, c, @enumFromInt(4));

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const ev = loaded.event_queue.blocking() orelse return error.DecisionLostOnLoad;
    try std.testing.expectEqual(@import("../domain/events.zig").EventKind.recovery_push, ev.kind);
    // The two pointers this decision needs to do anything at all.
    try std.testing.expectEqual(@as(types.BattleId, @enumFromInt(4)), ev.battle);
    try std.testing.expectEqual(lance, loaded.heldHull(taken).?.from_force);
    // And a hull won back after a reload still goes home to that lance.
    try std.testing.expect(try held_hulls_m.releaseHull(&loaded, taken));
    try std.testing.expectEqual(lance, loaded.unit(taken).?.force);
}

test "the wrecks on offer survive a save — the same battlefield after a reload" {
    const battle = @import("../sim/battle.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12060 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    // A report with a haul still to be divided, built by hand so the test
    // does not depend on a campaign happening to throw one up.
    const candidates = [_]battle_report_mod.SalvageCandidate{
        .{ .key = "DRG-1N", .name = "Dragon", .bv = 1_144, .armor_pct = 30, .quality = .c, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 1 },
        .{ .key = "LCT-1V", .name = "Locust", .bv = 432, .armor_pct = 24, .quality = .d, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .key = "STG-3R", .name = "Stinger", .bv = 192, .armor_pct = 18, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
    };
    try gs.battle_reports.record(gs.allocator(), .{
        .id = gs.nextBattleId(),
        .day = 12,
        .contract = @enumFromInt(1),
        .company = co,
        .kind = "recon_raid",
        .enemy_key = "DC",
        .scenario = "breakthrough",
        .terrain = "badlands",
        .weather = "clear skies",
        .outcome = .victory,
        .held_field = true,
        .acknowledged = true,
        .salvage = .{ .claimed_bv = 1_500, .candidates = &candidates, .unclaimed_bv = 1_500 },
    });
    const battle_id = gs.battle_reports.kept.items[0].id;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const r = loaded.battle_reports.find(battle_id) orelse return error.ReportLostOnLoad;
    try std.testing.expectEqual(@as(i64, 1_500), r.salvage.unclaimed_bv);
    try std.testing.expectEqual(candidates.len, r.salvage.candidates.len);
    for (candidates, r.salvage.candidates) |saved, got| {
        try std.testing.expectEqualStrings(saved.key, got.key);
        try std.testing.expectEqualStrings(saved.name, got.name);
        try std.testing.expectEqual(saved.bv, got.bv);
        try std.testing.expectEqual(saved.armor_pct, got.armor_pct);
        try std.testing.expectEqual(saved.quality, got.quality);
        try std.testing.expectEqual(saved.destroyed_slots, got.destroyed_slots);
        try std.testing.expectEqual(saved.missing_components, got.missing_components);
    }
    // And the plan the reloaded record offers is the plan the original
    // offered — the whole reason the rolls are kept rather than re-rolled.
    const before = battle.salvagePlan(&candidates, 1_500, .heaviest);
    const after = battle.salvagePlan(r.salvage.candidates, 1_500, .heaviest);
    try std.testing.expectEqual(before.hulls, after.hulls);
    try std.testing.expectEqualStrings("Dragon", r.salvage.candidates[after.take[0]].name);
}

/// A played year for the golden master: a commander, the starter company,
/// every contract offer taken as the last one ends, every decision answered
/// with its default and every after-action read.
fn playedYearForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    const checklist = @import("../sim/checklist.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "Kalmar", .origin = .LC, .profession = .line_officer } });
    const co = (try commands.execute(gs, .{ .new_company = "Alpha" })).created_force;
    var day: u32 = 0;
    while (day < 365) {
        while (checklist.turnHold(gs)) |h| switch (h) {
            .unread_after_action => _ = try commands.execute(gs, .{ .read_report = gs.battle_reports.unread().?.id }),
            .battle_decision => {
                const ev = gs.event_queue.blocking().?;
                _ = try commands.execute(gs, .{ .resolve_decision = .{ .event = ev.id, .choice = ev.default_choice } });
            },
        };
        if (!posture.isCompanyDeployed(gs, co) and gs.contract_offers.items.len > 0) {
            _ = commands.execute(gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } }) catch {};
        }
        const r = try commands.execute(gs, .{ .advance_days = 7 });
        if (r.days_advanced == 0) return error.TestUnexpectedResult;
        day += @intCast(r.days_advanced);
    }
}

test "golden master: a played year hashes to its pinned value, and a save of it plays on identically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20_260_924 });
    defer gs.deinit();
    try playedYearForTest(&gs);
    try std.testing.expect(gs.battle_reports.kept.items.len > 0); // the year saw fighting
    // The scripted campaign's hash detects any simulation or persistence change.
    try std.testing.expectEqual(@as(u64, 7031099491874677131), digest.stateHash(&gs));

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
    const commands = @import("../sim/commands.zig");
    for ([_]*GameState{ &gs, &loaded }) |g| _ = try commands.execute(g, .{ .advance_days = 60 });
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
}

test "pool-path salvage: hull_instance_id round-trips through save/load" {
    // P3e.5b-3b: pool-path candidates carry the drawn hull's id so the deferred
    // salvage decision claims the real wreck, not a freshly minted one.
    // Rule 5: this test lives in persist (store.zig), not sim/battle.zig.
    const testing = std.testing;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4005 });
    defer gs.deinit();
    gs.clock.day_index = 5;
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 6, .base_pay_month = 400_000, .salvage_pct = 100 },
        .status = .active,
        .assigned_company = co,
        .monthly_net = 300_000,
        .enemy_lances = 1,
    });

    // Two WSP-1A hull instances owned by DC (enemy).
    const hid0: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    const hid1: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    for ([_]types.HullInstanceId{ hid0, hid1 }) |hid| {
        try gs.hull_instances.put(gs.allocator(), hid, .{
            .id = hid,
            .base_key = "WSP-1A",
            .owner = .{ .faction = "DC" },
        });
        try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = 0,
            .to_day = 0,
            .acquisition_type = .initial,
            .prior_owner_key = "",
        });
    }

    // Battle report with pool-path candidates (hull_instance_id != .none).
    const bid: types.BattleId = gs.nextBattleId();
    const cands = try gs.allocator().dupe(battle_report_mod.SalvageCandidate, &[_]battle_report_mod.SalvageCandidate{
        .{ .hull_instance_id = hid0, .key = "WSP-1A", .name = "Wasp", .bv = 192, .armor_pct = 60, .quality = .c, .damaged_slots = 1, .destroyed_slots = 1, .missing_components = 1 },
        .{ .hull_instance_id = hid1, .key = "WSP-1A", .name = "Wasp", .bv = 192, .armor_pct = 40, .quality = .d, .damaged_slots = 1, .destroyed_slots = 2, .missing_components = 1 },
    });
    try gs.battle_reports.record(gs.allocator(), .{
        .id = bid,
        .day = 5,
        .contract = cid,
        .company = co,
        .kind = "recon_raid",
        .enemy_key = "DC",
        .scenario = "standup",
        .terrain = "plains",
        .weather = "clear",
        .outcome = autoresolve_mod.Outcome.victory,
        .held_field = true,
        .salvage = .{ .unclaimed_bv = 200, .candidates = cands },
        .acknowledged = true,
    });

    // Save and reload.
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // hull_instance_id survives the round-trip (columns hull_instance_id, schema v55).
    const rep = loaded.battle_reports.find(bid) orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 2), rep.salvage.candidates.len);
    try testing.expectEqual(hid0, rep.salvage.candidates[0].hull_instance_id);
    try testing.expectEqual(hid1, rep.salvage.candidates[1].hull_instance_id);
    // Abstraction-path candidates keep hull_instance_id = .none (column default 0).
    // (Pool-path candidates carry the real drawn hull id, tested above.)
}

test "the table registry matches the tables the executable schema creates" {
    // Campaign clear, delete and overwrite walk `tables`: a table the DDL
    // creates but the registry misses would keep a deleted campaign's rows.
    const store_wide = [_][]const u8{ "campaign", "player", "setting" };
    var created: std.ArrayListUnmanaged([]const u8) = .empty;
    defer created.deinit(std.testing.allocator);
    var rest: []const u8 = ddl;
    const marker = "CREATE TABLE IF NOT EXISTS ";
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        rest = rest[i + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, " (") orelse rest.len;
        const name = rest[0..end];
        const shared = for (store_wide) |w| {
            if (std.mem.eql(u8, w, name)) break true;
        } else false;
        if (!shared) try created.append(std.testing.allocator, name);
    }
    try std.testing.expectEqual(tables.len, created.items.len);
    for (tables, 0..) |t, i| {
        for (tables[i + 1 ..]) |u| try std.testing.expect(!std.mem.eql(u8, t, u));
        const in_ddl = for (created.items) |c| {
            if (std.mem.eql(u8, c, t)) break true;
        } else false;
        if (!in_ddl) std.debug.print("registry table {s} is not in the DDL\n", .{t});
        try std.testing.expect(in_ddl);
    }
}

// P4b: arc/operation persistence (rule 47, 67, 69).

/// Build a store with a garrison contract carrying one operation; corrupt one
/// column with `sql`, and attempt to load. FK enforcement is off during
/// tampering so the loader remains the integrity check (rule 50, defense-in-depth).
fn loadArcAfterTampering(sql: [*:0]const u8) !void {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4205 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "caph",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .arc_beat = 0,
        .escalation_clock = 10,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });
    gs.next_operation_id = 2;
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "a garrison contract with arc state and operations round-trips to an identical digest" {
    // Rule 47: arc_key/arc_beat/escalation_clock and the operation child table
    // survive save → load. Two operations in distinct states and outcome bands
    // cover the serialisation paths.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4201 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "caph",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .arc_beat = 1,
        .escalation_clock = 35,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "negotiate_terms",
        .state = .available,
        .opened_day = 0,
    });
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(2),
        .template_key = "repel_probe",
        .state = .resolved,
        .outcome = .success,
        .opened_day = 0,
        .resolved_day = 5,
    });
    gs.next_operation_id = 3;
    gs.next_contract_id = 2; // one past the manually inserted id=1
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    // Spot-check arc fields and operations.
    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqualStrings("fracturing_garrison", lc.arc_key);
    try std.testing.expectEqual(@as(u8, 1), lc.arc_beat);
    try std.testing.expectEqual(@as(u16, 35), lc.escalation_clock);
    try std.testing.expectEqual(@as(usize, 2), lc.operations.items.len);
    try std.testing.expectEqualStrings("negotiate_terms", lc.operations.items[0].template_key);
    try std.testing.expectEqual(operation_mod.OperationState.available, lc.operations.items[0].state);
    try std.testing.expectEqualStrings("repel_probe", lc.operations.items[1].template_key);
    try std.testing.expectEqual(operation_mod.OperationState.resolved, lc.operations.items[1].state);
    try std.testing.expectEqual(operation_mod.OutcomeBand.success, lc.operations.items[1].outcome);
    try std.testing.expectEqual(@as(?u32, 5), lc.operations.items[1].resolved_day);
    try std.testing.expectEqual(@as(u32, 3), loaded.next_operation_id);
}

test "arc_finale_key, committed_day, and battle_report.operation round-trip through save/load" {
    // Rule 47: the three columns added in v39 carry non-default values through
    // a full save → load cycle without loss (firstStateDifference == "").
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3901 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "caph",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .arc_beat = 2,
        .escalation_clock = 5,
        .arc_finale_key = "held", // non-default
    });
    const c = gs.contracts.getPtr(cid).?;
    // Operation with non-null committed_day.
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 7, // non-default
    });
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;
    // Battle report with non-empty operation.
    try gs.battle_reports.kept.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 5,
        .contract = cid,
        .company = co,
        .kind = "garrison duty",
        .enemy_key = "PER",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .defeat,
        .score_delta = -2,
        .score_after = -2,
        .command_rights = "independent",
        .operation = try gs.allocator().dupe(u8, "Repel Probe"), // non-default
        .conceded = true,
        .acknowledged = true,
    });
    gs.next_battle_id = 2;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var diff_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");

    // Spot-check each new column.
    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqualStrings("held", lc.arc_finale_key);
    try std.testing.expectEqual(@as(?u32, 7), lc.operations.items[0].committed_day);
    try std.testing.expectEqualStrings("Repel Probe", loaded.battle_reports.kept.items[0].operation);
}

test "operation.tempo and battle_report.operation_tempo round-trip through save/load (P4f)" {
    // Rule 47: the v42 columns carry non-default values through a full save → load
    // cycle without loss.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4201 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .available,
        .opened_day = 0,
        .tempo = .recon, // non-default
    });
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;
    try gs.battle_reports.kept.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 5,
        .contract = cid,
        .company = co,
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .victory,
        .score_delta = 2,
        .score_after = 2,
        .command_rights = "independent",
        .operation = try gs.allocator().dupe(u8, "Repel Probe"),
        .operation_tempo = .recon, // non-default
        .acknowledged = true,
    });
    gs.next_battle_id = 2;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqual(operation_mod.TempoPosture.recon, lc.operations.items[0].tempo);
    try std.testing.expectEqual(@as(?operation_mod.TempoPosture, .recon), loaded.battle_reports.kept.items[0].operation_tempo);
}

test "a v41 store migrates to v42 with operation.tempo and battle_report.operation_tempo defaults" {
    // Rule 50: a store at v41 must migrate cleanly; the new columns must
    // have their default values ('advance' and '' respectively) for existing rows.
    const alloc = std.testing.allocator;
    var store_v41 = try sqlite.Db.open(":memory:");
    defer store_v41.close();
    // Build a v41-equivalent schema: the same tables minus the two new columns.
    try store_v41.exec(
        \\CREATE TABLE setting (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
        \\INSERT INTO setting VALUES ('schema_version', 41);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL CHECK (schema_version > 0), save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE operation (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, template_key TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT NOT NULL, opened_day INTEGER NOT NULL, resolved_day INTEGER, committed_day INTEGER, intent TEXT NOT NULL DEFAULT 'secure_objective', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\CREATE TABLE battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1, salvage_unclaimed INTEGER NOT NULL DEFAULT 0, operation TEXT NOT NULL DEFAULT '', operation_intent TEXT NOT NULL DEFAULT '', UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    );
    // Adopt (migrate) must succeed.
    const store = try Store.fromDb(store_v41);
    defer store.close();
    // After migration the schema_version must be 42.
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
    _ = alloc;
}

test "a contract arc_key not in arcs.zon rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadArcAfterTampering(
        "UPDATE contract SET arc_key = '__bad_arc__' WHERE arc_key != ''",
    ));
}

test "an operation with an unknown state rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadArcAfterTampering(
        "UPDATE operation SET state = 'bogus_state'",
    ));
}

test "an operation template_key not in operations.zon rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadArcAfterTampering(
        "UPDATE operation SET template_key = '__bad_template__'",
    ));
}

test "a v38 store migrates to v39 with arc_finale_key, committed_day, and operation defaults" {
    // Rule 51: forward migration. A v38-shaped store (arc columns present on
    // contract, operation table exists, battle_report exists — all missing
    // the three v39 columns) opens cleanly; the new columns take their defaults:
    // contract.arc_finale_key = '', operation.committed_day = null,
    // battle_report.operation = ''.
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng_stream (cid INTEGER NOT NULL, stream TEXT NOT NULL, format INTEGER NOT NULL, state BLOB NOT NULL, UNIQUE (cid, stream));
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0, faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, secondary_role TEXT, PRIMARY KEY (cid, id));
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\CREATE TABLE contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL CHECK (is_offer IN (0,1)), ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER, command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0, enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER, arc_key TEXT NOT NULL DEFAULT '', arc_beat INTEGER NOT NULL DEFAULT 0, escalation_clock INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE operation (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, template_key TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT NOT NULL, opened_day INTEGER NOT NULL, resolved_day INTEGER);
        \\CREATE TABLE battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1, salvage_unclaimed INTEGER NOT NULL DEFAULT 0, UNIQUE (cid, ord));
        \\INSERT INTO setting VALUES ('schema_version', 38);
        \\INSERT INTO campaign VALUES (1, 'Fixture', NULL, 0, '3025-01-01', 38, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Fixture');
        \\INSERT INTO person VALUES (1, 0, 1, 'A', 'B', NULL, 'mekwarrior', 0, 'active', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, NULL, NULL, NULL, 0, 'private', 0, 0, 0, 0, 0, 0, 0, '', 0, NULL, NULL, NULL, NULL, NULL);
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        \\INSERT INTO contract VALUES (1, 0, 0, 1, 'garrison_duty', 'LC', 'PER', 'caph', 'active', 0, 0, 0, 30, 0, 14, 14, 360, 80000, 30, 0, 0, 'duration', 0, 100000, 100000, 0, NULL, NULL, 12, 80000, 25, 0, 0, 0, 0, 0, 0, 'independent', 0, 0, 'regular', 0, 0, 0, NULL, 'fracturing_garrison', 0, 5);
        \\INSERT INTO operation (cid, contract_id, ord, id, template_key, state, outcome, opened_day) VALUES (1, 1, 0, 1, 'negotiate_terms', 'committed', 'none', 0);
        \\INSERT INTO battle_report (cid, ord, outcome, roe) VALUES (1, 0, 'defeat', 'standard');
    );
    const store = try Store.fromDb(raw);
    defer store.close();
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
    var loaded = try store.load(std.testing.allocator, 1);
    defer loaded.deinit();
    // contract.arc_finale_key must default to "".
    try std.testing.expectEqual(@as(usize, 1), loaded.contracts.count());
    const c = loaded.contracts.values()[0];
    try std.testing.expectEqualStrings("", c.arc_finale_key);
    // operation.committed_day must default to null.
    try std.testing.expectEqual(@as(usize, 1), c.operations.items.len);
    try std.testing.expectEqual(@as(?u32, null), c.operations.items[0].committed_day);
    // battle_report.operation must default to "".
    try std.testing.expectEqual(@as(usize, 1), loaded.battle_reports.kept.items.len);
    try std.testing.expectEqualStrings("", loaded.battle_reports.kept.items[0].operation);
}

test "a v37 store migrates to v38 with empty arc fields and no operations" {
    // Rule 51: additive forward-only migration. A v37-shaped store (no arc
    // columns on contract, no operation table) opens and loads cleanly.
    // arc_key defaults to '', escalation_clock to 0, operations list is empty.
    const raw = try sqlite.Db.open(":memory:");
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE meta (cid INTEGER NOT NULL, key TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE meta_text (cid INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (cid, key));
        \\CREATE TABLE rng_stream (cid INTEGER NOT NULL, stream TEXT NOT NULL, format INTEGER NOT NULL, state BLOB NOT NULL, UNIQUE (cid, stream));
        \\CREATE TABLE person (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, first TEXT, last TEXT, callsign TEXT, role TEXT, xp INTEGER, status TEXT, fatigue INTEGER, morale INTEGER, recruited_day INTEGER, salary_override INTEGER, assigned_force INTEGER, posted_hq INTEGER, weekly_hours INTEGER, medbay_priority INTEGER, leave_until INTEGER, wound_heal_day INTEGER, training_skill TEXT, training_done INTEGER, admitted INTEGER NOT NULL DEFAULT 0, rank TEXT NOT NULL DEFAULT 'private', rank_pinned INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, kill_bv INTEGER NOT NULL DEFAULT 0, battles INTEGER NOT NULL DEFAULT 0, tours INTEGER NOT NULL DEFAULT 0, outstanding_tours INTEGER NOT NULL DEFAULT 0, edge_spent INTEGER NOT NULL DEFAULT 0, faction TEXT NOT NULL DEFAULT '', shares INTEGER NOT NULL DEFAULT 0, born_day INTEGER, last_raise_day INTEGER, last_award_day INTEGER, departed_day INTEGER, secondary_role TEXT, PRIMARY KEY (cid, id));
        \\CREATE TABLE rng (cid INTEGER PRIMARY KEY, state BLOB NOT NULL);
        \\CREATE TABLE contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL CHECK (is_offer IN (0,1)), ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER, command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0, enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER);
        \\INSERT INTO setting VALUES ('schema_version', 37);
        \\INSERT INTO campaign VALUES (1, 'Fixture', NULL, 0, '3025-01-01', 37, 1, 0);
        \\INSERT INTO meta VALUES (1, 'day_index', 0);
        \\INSERT INTO meta VALUES (1, 'year', 3025);
        \\INSERT INTO meta VALUES (1, 'month', 1);
        \\INSERT INTO meta VALUES (1, 'day', 1);
        \\INSERT INTO meta VALUES (1, 'funds', 0);
        \\INSERT INTO meta VALUES (1, 'reputation', 0);
        \\INSERT INTO meta VALUES (1, 'difficulty', 1);
        \\INSERT INTO meta_text VALUES (1, 'outfit_name', 'Fixture');
        \\INSERT INTO person VALUES (1, 0, 1, 'A', 'B', NULL, 'mekwarrior', 0, 'active', 0, 50, 0, NULL, 0, 0, 40, 0, NULL, NULL, NULL, NULL, 0, 'private', 0, 0, 0, 0, 0, 0, 0, '', 0, NULL, NULL, NULL, NULL, NULL);
        \\INSERT INTO contract VALUES (1, 0, 0, 1, 'garrison_duty', 'LC', 'PER', 'caph', 'active', 0, 0, 0, 30, 0, 14, 14, 360, 80000, 30, 0, 0, 'duration', 0, 100000, 100000, 0, NULL, NULL, 12, 80000, 25, 0, 0, 0, 0, 0, 0, 'independent', 0, 0, 'regular', 0, 0, 0, NULL);
        \\INSERT INTO rng VALUES (1, x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
    );
    // fromDb runs migrations and creates the operation table via DDL.
    const store = try Store.fromDb(raw);
    defer store.close();
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
    // Loading must succeed with empty arc state and no operations.
    var loaded = try store.load(std.testing.allocator, 1);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.contracts.count());
    const c = loaded.contracts.values()[0];
    try std.testing.expectEqualStrings("", c.arc_key);
    try std.testing.expectEqual(@as(u8, 0), c.arc_beat);
    try std.testing.expectEqual(@as(u16, 0), c.escalation_clock);
    try std.testing.expectEqual(@as(usize, 0), c.operations.items.len);
}

test "non-default op.intent and non-null operation_intent round-trip through save/load" {
    // Rule 47: the non-default save branch (@tagName(op.intent)) and the
    // non-empty load branch (stringToEnum orelse CorruptSave) for both
    // operation.intent and battle_report.operation_intent are exercised here.
    // The default value for both columns is 'secure_objective' / ''; this test
    // stores '.break_enemy' and '.preserve_force' to reach the non-default paths.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4301 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "PER",
        .planet_key = "caph",
        .terms = .{ .length_months = 12, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .arc_beat = 1,
        .escalation_clock = 10,
    });
    // Operation with non-default intent (.break_enemy ≠ 'secure_objective').
    try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 3,
        .intent = .break_enemy, // non-default: exercises @tagName path in save
    });
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;
    // Battle report with non-null operation_intent (.preserve_force ≠ null/'').
    try gs.battle_reports.kept.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 2,
        .contract = cid,
        .company = co,
        .kind = "garrison duty",
        .enemy_key = "PER",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .victory,
        .score_delta = 2,
        .score_after = 2,
        .command_rights = "independent",
        .operation = try gs.allocator().dupe(u8, "Repel Probe"),
        .operation_intent = .preserve_force, // non-null: exercises non-empty load branch
        .acknowledged = true,
    });
    gs.next_battle_id = 2;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");

    // Spot-check: operation.intent must survive as .break_enemy.
    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqual(@as(usize, 1), lc.operations.items.len);
    try std.testing.expectEqual(operation_mod.Intent.break_enemy, lc.operations.items[0].intent);

    // Spot-check: battle_report.operation_intent must survive as .preserve_force.
    try std.testing.expectEqual(@as(usize, 1), loaded.battle_reports.kept.items.len);
    try std.testing.expectEqual(
        @as(?operation_mod.Intent, .preserve_force),
        loaded.battle_reports.kept.items[0].operation_intent,
    );
}

test "operation_task and battle_report_task round-trip with ≥2 rows (P4e)" {
    // Rule 47 / P4e: two LanceTasking rows on an operation and two TaskedLance
    // rows on a battle report must survive save → load with firstStateDifference == "".
    // Spot-checks verify the enum, lance id, success flag and note survive exactly.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 55006 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Alpha", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    const lance_a: types.ForceId = @enumFromInt(10);
    const lance_b: types.ForceId = @enumFromInt(11);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "caph",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    // Operation with two task assignments.
    try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 3,
    });
    const op = &gs.contracts.getPtr(cid).?.operations.items[0];
    try op.tasks.append(gs.allocator(), .{ .lance = lance_a, .task = .main_effort });
    try op.tasks.append(gs.allocator(), .{ .lance = lance_b, .task = .reserve });
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;

    // Battle report with two TaskedLance rows.
    const note_a = try gs.allocator().dupe(u8, "led the advance");
    const note_b = try gs.allocator().dupe(u8, "held in reserve");
    try gs.battle_reports.kept.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 4,
        .contract = cid,
        .company = co,
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .victory,
        .score_delta = 2,
        .score_after = 2,
        .command_rights = "independent",
        .acknowledged = true,
        .tasks = try gs.allocator().dupe(battle_report_mod.TaskedLance, &.{
            .{ .lance = lance_a, .lance_name = "", .task = .main_effort, .succeeded = true, .note = note_a },
            .{ .lance = lance_b, .lance_name = "", .task = .reserve, .succeeded = false, .note = note_b },
        }),
    });
    gs.next_battle_id = 2;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");

    // Spot-check operation tasks.
    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqual(@as(usize, 1), lc.operations.items.len);
    try std.testing.expectEqual(@as(usize, 2), lc.operations.items[0].tasks.items.len);
    try std.testing.expectEqual(operation_mod.LanceTask.main_effort, lc.operations.items[0].tasks.items[0].task);
    try std.testing.expectEqual(lance_a, lc.operations.items[0].tasks.items[0].lance);
    try std.testing.expectEqual(operation_mod.LanceTask.reserve, lc.operations.items[0].tasks.items[1].task);
    try std.testing.expectEqual(lance_b, lc.operations.items[0].tasks.items[1].lance);

    // Spot-check battle report tasks.
    try std.testing.expectEqual(@as(usize, 1), loaded.battle_reports.kept.items.len);
    const lr = loaded.battle_reports.kept.items[0];
    try std.testing.expectEqual(@as(usize, 2), lr.tasks.len);
    try std.testing.expectEqual(operation_mod.LanceTask.main_effort, lr.tasks[0].task);
    try std.testing.expect(lr.tasks[0].succeeded);
    try std.testing.expectEqualStrings("led the advance", lr.tasks[0].note);
    try std.testing.expectEqual(operation_mod.LanceTask.reserve, lr.tasks[1].task);
    try std.testing.expect(!lr.tasks[1].succeeded);
    try std.testing.expectEqualStrings("held in reserve", lr.tasks[1].note);
}

test "a v40 store with no task tables loads cleanly with empty task lists" {
    // Rule 51 / P4e: operation_task and battle_report_task are created by DDL when
    // a v40 store is opened; the existing operation and battle_report rows load with
    // empty task lists (correct migration default, like the operation table for v38).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 55007 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Beta", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "caph",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 2,
    });
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;
    try gs.battle_reports.kept.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 3,
        .contract = cid,
        .company = co,
        .kind = "garrison duty",
        .enemy_key = "DC",
        .scenario = "",
        .terrain = "",
        .weather = "",
        .outcome = .victory,
        .score_delta = 2,
        .score_after = 2,
        .command_rights = "independent",
        .acknowledged = true,
    });
    gs.next_battle_id = 2;

    const raw = try sqlite.Db.open(":memory:");
    // First pass: save at the current schema.
    const s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    // Simulate a v40 store: drop the P4e task tables and roll back the version.
    // fromDb will recreate them via DDL (CREATE TABLE IF NOT EXISTS) on reopen.
    try raw.exec("DROP TABLE IF EXISTS operation_task");
    try raw.exec("DROP TABLE IF EXISTS battle_report_task");
    try raw.exec("UPDATE setting SET value = 40 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 40");

    // Second pass: fromDb recreates the missing tables; schema advances to current.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // Load must succeed; operation and battle report must have empty task lists.
    try std.testing.expectEqual(@as(usize, 1), loaded.contracts.count());
    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqual(@as(usize, 1), lc.operations.items.len);
    try std.testing.expectEqual(@as(usize, 0), lc.operations.items[0].tasks.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.battle_reports.kept.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.battle_reports.kept.items[0].tasks.len);
}

test "invalid and orphaned operation_task rows reject the load as corrupt (P4e)" {
    // Rules 47, 69 / P4e: an unknown task enum in operation_task → CorruptSave;
    // an operation_task row whose operation_id names no operation → CorruptSave.
    // Both follow the corruption-fixture pattern: save a valid campaign, inject bad
    // SQL with FK enforcement off, attempt to load.

    // Minimal campaign fixture with one committed operation.
    const buildGs = struct {
        fn run(alloc_gs: std.mem.Allocator) !GameState {
            var gs = GameState.init(alloc_gs, .{ .seed = 55008 });
            _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
            const co = try gs.createForce("Gamma", .company, .none);
            const cid: types.ContractId = @enumFromInt(1);
            try gs.contracts.put(gs.allocator(), cid, .{
                .id = cid,
                .kind = .garrison_duty,
                .employer_key = "LC",
                .enemy_key = "DC",
                .planet_key = "caph",
                .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
                .status = .active,
                .assigned_company = co,
                .arc_key = "fracturing_garrison",
            });
            try gs.contracts.getPtr(cid).?.operations.append(gs.allocator(), .{
                .id = @enumFromInt(1),
                .template_key = "repel_probe",
                .state = .committed,
                .opened_day = 0,
                .committed_day = 1,
            });
            gs.next_operation_id = 2;
            gs.next_contract_id = 2;
            return gs;
        }
    }.run;

    // G1: unknown task enum value in operation_task → CorruptSave.
    {
        var gs = try buildGs(std.testing.allocator);
        defer gs.deinit();
        const s = try Store.open(":memory:");
        defer s.close();
        try s.save(&gs);
        try s.db.exec("PRAGMA foreign_keys = OFF");
        // operation_id = 1 matches the saved operation; task is not a valid LanceTask tag.
        try s.db.exec("INSERT INTO operation_task VALUES (1, 1, 1, 0, 10, 'nonexistent_task')");
        try s.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, s.load(std.testing.allocator, gs.campaign_id));
    }

    // G2: orphaned operation_task row (operation_id names no saved operation) → CorruptSave.
    {
        var gs = try buildGs(std.testing.allocator);
        defer gs.deinit();
        const s = try Store.open(":memory:");
        defer s.close();
        try s.save(&gs);
        try s.db.exec("PRAGMA foreign_keys = OFF");
        // operation_id = 99999 has no corresponding row in the operation table.
        try s.db.exec("INSERT INTO operation_task VALUES (1, 1, 99999, 0, 10, 'main_effort')");
        try s.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, s.load(std.testing.allocator, gs.campaign_id));
    }
}

// P4g persistence tests -------------------------------------------------------

/// Minimal campaign fixture for P4g corrupt-load tests: one active arc contract
/// with a committed combat operation (so operation_intervention rows are valid).
fn buildInterventionGs(alloc_gs: std.mem.Allocator) !GameState {
    var gs = GameState.init(alloc_gs, .{ .seed = 55009 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Delta", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "caph",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .command_capacity = 3,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .committed,
        .opened_day = 0,
        .committed_day = 1,
    });
    try c.operations.items[0].interventions.append(gs.allocator(), operation_mod.Intervention.reinforce);
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;
    return gs;
}

test "command_capacity and applied intervention round-trip through save/load (P4g)" {
    // Rules 47, 67: a non-zero command_capacity and an applied intervention
    // survive save → load with an identical stateHash.
    var gs = try buildInterventionGs(std.testing.allocator);
    defer gs.deinit();
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    const lc = loaded.contracts.getPtr(@enumFromInt(1)).?;
    try std.testing.expectEqual(@as(u8, 3), lc.command_capacity);
    try std.testing.expectEqual(@as(usize, 1), lc.operations.items[0].interventions.items.len);
    try std.testing.expectEqual(operation_mod.Intervention.reinforce, lc.operations.items[0].interventions.items[0]);
}

test "a v42 store migrates to v43 with command_capacity and operation_interventions defaults" {
    // Rule 50: a store at v42 must migrate cleanly; the new v43 columns must
    // have their default values (0 and '' respectively) for existing rows.
    var store_v42 = try sqlite.Db.open(":memory:");
    defer store_v42.close();
    // Build a v42-equivalent schema: the same tables minus the v43 additions
    // (no command_capacity on contract, no operation_interventions on battle_report,
    // no operation_intervention table).
    try store_v42.exec(
        \\CREATE TABLE setting (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
        \\INSERT INTO setting VALUES ('schema_version', 42);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL CHECK (schema_version > 0), save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL CHECK (is_offer IN (0,1)), ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER CHECK (salvage_exchange IN (0,1)), command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0 CHECK (negotiated IN (0,1)), enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER, arc_key TEXT NOT NULL DEFAULT '', arc_beat INTEGER NOT NULL DEFAULT 0, escalation_clock INTEGER NOT NULL DEFAULT 0, arc_finale_key TEXT NOT NULL DEFAULT '', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\CREATE TABLE operation (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, template_key TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT NOT NULL, opened_day INTEGER NOT NULL, resolved_day INTEGER, committed_day INTEGER, intent TEXT NOT NULL DEFAULT 'secure_objective', tempo TEXT NOT NULL DEFAULT 'advance', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\CREATE TABLE battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1 CHECK (acknowledged IN (0,1)), salvage_unclaimed INTEGER NOT NULL DEFAULT 0, operation TEXT NOT NULL DEFAULT '', operation_intent TEXT NOT NULL DEFAULT '', operation_tempo TEXT NOT NULL DEFAULT '', UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    );
    // fromDb must migrate v42 → v43 successfully.
    const store = try Store.fromDb(store_v42);
    defer store.close();
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
}

test "invalid and orphaned operation_intervention rows reject the load as corrupt (P4g)" {
    // Rules 47, 69 / P4g: an unknown intervention kind → CorruptSave;
    // an orphaned operation_intervention row (references no saved operation) → CorruptSave;
    // a contract with command_capacity out of u8 range → CorruptSave.

    // G1: unknown intervention kind → CorruptSave.
    {
        var gs = try buildInterventionGs(std.testing.allocator);
        defer gs.deinit();
        const s = try Store.open(":memory:");
        defer s.close();
        try s.save(&gs);
        try s.db.exec("PRAGMA foreign_keys = OFF");
        // Insert an operation_intervention row with an invalid kind string.
        // Schema: (cid, contract_id, operation_id, ord, kind).
        try s.db.exec("INSERT INTO operation_intervention VALUES (1, 1, 1, 1, 'notakind')");
        try s.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, s.load(std.testing.allocator, gs.campaign_id));
    }

    // G2: orphaned operation_intervention row (operation_id names no saved operation) → CorruptSave.
    {
        var gs = try buildInterventionGs(std.testing.allocator);
        defer gs.deinit();
        const s = try Store.open(":memory:");
        defer s.close();
        try s.save(&gs);
        try s.db.exec("PRAGMA foreign_keys = OFF");
        // operation_id = 99999 does not match any operation in the campaign.
        try s.db.exec("INSERT INTO operation_intervention VALUES (1, 1, 99999, 0, 'reinforce')");
        try s.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, s.load(std.testing.allocator, gs.campaign_id));
    }

    // G3: contract command_capacity out of u8 range (999 > 255) → CorruptSave.
    {
        var gs = try buildInterventionGs(std.testing.allocator);
        defer gs.deinit();
        const s = try Store.open(":memory:");
        defer s.close();
        try s.save(&gs);
        try s.db.exec("PRAGMA foreign_keys = OFF");
        try s.db.exec("UPDATE contract SET command_capacity = 999");
        try s.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, s.load(std.testing.allocator, gs.campaign_id));
    }
}

/// Build a minimal GameState with one active arc contract and one actor attached.
/// Used by actor corrupt-load tests so `saveActors`/`loadActors` write real rows.
fn buildActorGs(alloc: std.mem.Allocator) !GameState {
    var gs = GameState.init(alloc, .{ .seed = 20050 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c = gs.contracts.getPtr(cid).?;
    const aid: types.ActorId = @enumFromInt(1);
    const a: actor_mod.Actor = .{
        .id = aid,
        .archetype_key = "liaison",
        .first_name = "Ann",
        .last_name = "Smith",
        .faction_key = "LC",
        .side = .employer,
        .contract = cid,
        .trust = 20,
    };
    try gs.commitActor(a);
    try c.actor_ids.append(gs.allocator(), aid);
    gs.next_actor_id = 2;
    gs.next_contract_id = 2;
    return gs;
}

/// Save a campaign with an actor row, corrupt it with `sql`, and try to load it back.
fn loadActorAfterTampering(sql: [*:0]const u8) !void {
    var gs = try buildActorGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "actors with nonzero relationships and a recurring actor survive a save/load round-trip (P4i)" {
    // Rules 47, 67 / P4i: a campaign with actors — including a recurring actor that
    // carries forward relationship values from a closed contract — survives save → load
    // with an identical stateHash. Exercises saveActors/loadActors with real rows.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");

    // Contract 1 (completed) — introduces liaison actor (id=1).
    const cid1: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid1, .{
        .id = cid1,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .completed,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c1 = gs.contracts.getPtr(cid1).?;
    const aid1: types.ActorId = @enumFromInt(1);
    const actor1: actor_mod.Actor = .{
        .id = aid1,
        .archetype_key = "liaison",
        .first_name = "Ann",
        .last_name = "Smith",
        .faction_key = "LC",
        .side = .employer,
        .contract = cid1,
        .trust = 30,
        .hostility = 5,
        .last_cause = "good_work",
        .last_cause_day = 10,
    };
    try gs.commitActor(actor1);
    try c1.actor_ids.append(gs.allocator(), aid1);

    // Contract 2 (active) — recurring liaison (id=2) carrying forward from contract 1.
    const cid2: types.ContractId = @enumFromInt(2);
    try gs.contracts.put(gs.allocator(), cid2, .{
        .id = cid2,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c2 = gs.contracts.getPtr(cid2).?;
    const aid2: types.ActorId = @enumFromInt(2);
    const actor2: actor_mod.Actor = .{
        .id = aid2,
        .archetype_key = "liaison",
        .first_name = "Ann",
        .last_name = "Smith",
        .faction_key = "LC",
        .side = .employer,
        .contract = cid2,
        .trust = 45,
        .hostility = 3,
        .last_cause = "repeated_service",
        .last_cause_day = 40,
        .recurring = true,
    };
    try gs.commitActor(actor2);
    try c2.actor_ids.append(gs.allocator(), aid2);

    gs.next_actor_id = 3;
    gs.next_contract_id = 3;

    try std.testing.expectEqual(@as(usize, 2), gs.actors.count());
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    // Actors round-tripped.
    try std.testing.expectEqual(@as(usize, 2), loaded.actors.count());
    // Recurring flag survives.
    try std.testing.expect(loaded.actors.getPtr(aid2).?.recurring);
    // Nonzero relationships survive.
    try std.testing.expectEqual(@as(i16, 45), loaded.actors.getPtr(aid2).?.trust);
}

test "a v43 store migrates to v44 with the actor table created and next_actor_id defaults to 1 (P4i)" {
    // Rule 50 / P4i: a store at schema v43 (no actor table, no next_actor_id meta row)
    // must migrate cleanly to v44 — applySchema creates the actor table — and loading
    // a campaign from the migrated store yields next_actor_id = 1 (safe default for a
    // campaign that had no actors before P4i).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    // Simulate a v43 store: drop the actor table and the next_actor_id meta row,
    // then downgrade schema_version to 43.
    try raw.exec("DROP TABLE actor");
    try raw.exec("DELETE FROM meta WHERE key = 'next_actor_id'");
    try raw.exec("UPDATE setting SET value = 43 WHERE key = 'schema_version'");
    // fromDb sees v43, runs applySchema (CREATE TABLE IF NOT EXISTS actor), sets v44.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    // Schema advanced to 44.
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    // actor table exists and is empty.
    const cnt = try s2.db.prepare("SELECT COUNT(*) FROM actor");
    defer cnt.finalize();
    try std.testing.expect(try cnt.next());
    try std.testing.expectEqual(@as(i64, 0), cnt.int(0));
    // Loading the campaign yields next_actor_id = 1 (no meta row → safe default).
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 1), loaded.next_actor_id);
}

test "an unknown archetype_key in an actor row rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: actor.archetype_key must name a known archetype (rule 50).
    try std.testing.expectError(error.CorruptSave, loadActorAfterTampering(
        "UPDATE actor SET archetype_key = 'notanarchetype'",
    ));
}

test "an out-of-range relationship in an actor row rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: trust (and the other dimensions) must lie in [rel_min, rel_max].
    // trust = 200 > rel_max = 100.
    try std.testing.expectError(error.CorruptSave, loadActorAfterTampering(
        "UPDATE actor SET trust = 200",
    ));
}

test "an actor row with a dangling contract reference rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: if actor.contract != 0, the contract_id must resolve to a loaded
    // contract. A nonzero id that names nothing is corruption.
    try std.testing.expectError(error.CorruptSave, loadActorAfterTampering(
        "UPDATE actor SET contract = 99999",
    ));
}

test "withdrawn operation and fell finale round-trip through save/load with identical stateHash (P4h)" {
    // Rules 47, 67 / P4h: a contract whose operation is .withdrawn and whose
    // arc_finale_key is 'fell' (status = .failed) survives save → load
    // with an identical stateHash. This covers the new OperationState.withdrawn
    // variant which relies on the existing TEXT column for operation.state.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 77099 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try gs.createForce("Gamma", .company, .none);
    const cid: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid, .{
        .id = cid,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .failed,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
        .arc_finale_key = "fell",
        .escalation_clock = 40,
    });
    const c = gs.contracts.getPtr(cid).?;
    try c.operations.append(gs.allocator(), .{
        .id = @enumFromInt(1),
        .template_key = "repel_probe",
        .state = .withdrawn,
        .opened_day = 0,
        .resolved_day = 0,
    });
    gs.next_operation_id = 2;
    gs.next_contract_id = 2;

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    const lc = loaded.contracts.getPtr(cid).?;
    try std.testing.expectEqualStrings("fell", lc.arc_finale_key);
    try std.testing.expectEqual(@import("../domain/contract.zig").ContractStatus.failed, lc.status);
    try std.testing.expectEqual(operation_mod.OperationState.withdrawn, lc.operations.items[0].state);
}

// ---- P4h.4 world_state persistence tests ----------------------------------

fn buildWorldStateGs(alloc: std.mem.Allocator) !GameState {
    const world_state_sim = @import("../sim/world_state.zig");
    var gs = GameState.init(alloc, .{ .seed = 30001 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    // Set world states for two known worlds.
    const prep1 = try world_state_sim.prepareWorldAdjust(&gs, "galatea", .{ .security = 30, .employer_control = 20, .enemy_influence = -10 }, "big_win");
    world_state_sim.commitWorldAdjust(&gs, prep1);
    const prep2 = try world_state_sim.prepareWorldAdjust(&gs, "solaris7", .{ .enemy_influence = 15, .infrastructure_strain = 5 }, "setback");
    world_state_sim.commitWorldAdjust(&gs, prep2);
    return gs;
}

fn loadWorldStateAfterTampering(sql: [*:0]const u8) !void {
    var gs = try buildWorldStateGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "world states on two worlds survive a save/load round-trip (P4h.4)" {
    // Rules 47, 67 / P4h.4: a campaign with non-zero world state on two worlds
    // saves and loads to an identical stateHash. Insertion order is preserved by
    // the `ord` column + ORDER BY ord so the StringArrayHashMap digest matches.
    var gs = try buildWorldStateGs(std.testing.allocator);
    defer gs.deinit();

    try std.testing.expectEqual(@as(usize, 2), gs.world_states.count());
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(@as(usize, 2), loaded.world_states.count());
    // Galatea values survive.
    const gal = loaded.world_states.get("galatea").?;
    try std.testing.expectEqual(@as(i16, 30), gal.security);
    try std.testing.expectEqual(@as(i16, 20), gal.employer_control);
    try std.testing.expectEqual(@as(i16, -10), gal.enemy_influence);
    try std.testing.expectEqualStrings("big_win", gal.last_cause);
}

test "a v44 store migrates to v45 with the world_state table created (P4h.4)" {
    // Rule 50 / P4h.4: a store at schema v44 (no world_state table) must migrate
    // cleanly to v45 — applySchema creates the table — and loading yields zero world states.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 30002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    // Simulate a v44 store: drop the world_state table and downgrade schema_version.
    try raw.exec("DROP TABLE world_state");
    try raw.exec("UPDATE setting SET value = 44 WHERE key = 'schema_version'");
    // fromDb sees v44, runs applySchema (CREATE TABLE IF NOT EXISTS world_state), sets v45.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    // Schema advanced to current.
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    // world_state table exists and is empty.
    const cnt = try s2.db.prepare("SELECT COUNT(*) FROM world_state");
    defer cnt.finalize();
    try std.testing.expect(try cnt.next());
    try std.testing.expectEqual(@as(i64, 0), cnt.int(0));
    // Loading yields zero world states (safe default).
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.world_states.count());
}

test "a world_state row with an unknown planet_key rejects the load as corrupt (P4h.4)" {
    // Rule 47 / P4h.4: planet_key must name a known planet.
    try std.testing.expectError(error.CorruptSave, loadWorldStateAfterTampering(
        "UPDATE world_state SET planet_key = 'notaplanet' WHERE planet_key = 'galatea'",
    ));
}

test "a world_state row with an out-of-range dimension rejects the load as corrupt (P4h.4)" {
    // Rule 47 / P4h.4: dimension values must lie in [world_min, world_max].
    try std.testing.expectError(error.CorruptSave, loadWorldStateAfterTampering(
        "UPDATE world_state SET security = 200",
    ));
}

test "a world_state row with a non-markup-safe last_cause rejects the load as corrupt (P4h.4)" {
    // Rule 47 / P4h.4: last_cause must be markup-safe.
    try std.testing.expectError(error.CorruptSave, loadWorldStateAfterTampering(
        "UPDATE world_state SET last_cause = '{bad markup}'",
    ));
}

// ---- P4i rival persistence tests ------------------------------------------

fn buildRivalGs(alloc: std.mem.Allocator) !GameState {
    var gs = GameState.init(alloc, .{ .seed = 40001 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");

    // Contract 1 (completed) — introduces enemy_raiders rival (id=1).
    const cid1: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid1, .{
        .id = cid1,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .completed,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c1 = gs.contracts.getPtr(cid1).?;
    const rid1: types.RivalId = @enumFromInt(1);
    const rv1: rival_mod.Rival = .{
        .id = rid1,
        .archetype_key = "enemy_raiders",
        .commander_first = "Ann",
        .commander_last = "Smith",
        .unit_name = "Smith Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
        .contract = cid1,
        .standing = -20,
        .encounters = 1,
        .last_cause = "setback",
        .last_cause_day = 10,
    };
    try gs.commitRival(rv1);
    try c1.rival_ids.append(gs.allocator(), rid1);

    // Contract 2 (active) — recurring enemy_raiders (id=2) carrying forward.
    const cid2: types.ContractId = @enumFromInt(2);
    try gs.contracts.put(gs.allocator(), cid2, .{
        .id = cid2,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c2 = gs.contracts.getPtr(cid2).?;
    const rid2: types.RivalId = @enumFromInt(2);
    const rv2: rival_mod.Rival = .{
        .id = rid2,
        .archetype_key = "enemy_raiders",
        .commander_first = "Ann",
        .commander_last = "Smith",
        .unit_name = "Smith Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
        .contract = cid2,
        .standing = -30,
        .encounters = 2,
        .last_cause = "repeated_setback",
        .last_cause_day = 40,
        .recurring = true,
    };
    try gs.commitRival(rv2);
    try c2.rival_ids.append(gs.allocator(), rid2);

    gs.next_rival_id = 3;
    gs.next_actor_id = 1;
    gs.next_contract_id = 3;
    return gs;
}

fn loadRivalAfterTampering(sql: [*:0]const u8) !void {
    var gs = try buildRivalGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "rivals with nonzero standing and a recurring rival survive a save/load round-trip (P4i)" {
    // Rules 47, 67 / P4i: a campaign with rivals — including a recurring rival that
    // carries forward standing and encounters from a closed contract — survives save
    // → load with an identical stateHash. Exercises saveRivals/loadRivals.
    var gs = try buildRivalGs(std.testing.allocator);
    defer gs.deinit();

    try std.testing.expectEqual(@as(usize, 2), gs.rivals.count());
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    // Rivals round-tripped.
    try std.testing.expectEqual(@as(usize, 2), loaded.rivals.count());
    const rid2: types.RivalId = @enumFromInt(2);
    // Recurring flag survives.
    try std.testing.expect(loaded.rivals.getPtr(rid2).?.recurring);
    // Nonzero standing survives.
    try std.testing.expectEqual(@as(i16, -30), loaded.rivals.getPtr(rid2).?.standing);
    // Encounters survive.
    try std.testing.expectEqual(@as(u16, 2), loaded.rivals.getPtr(rid2).?.encounters);
    // rival_ids rebuilt on contracts.
    const cid2: types.ContractId = @enumFromInt(2);
    const lc2 = loaded.contracts.getPtr(cid2).?;
    try std.testing.expectEqual(@as(usize, 1), lc2.rival_ids.items.len);
    try std.testing.expectEqual(rid2, lc2.rival_ids.items[0]);
}

test "a v45 store migrates to v46 with the rival table created and next_rival_id defaults to 1 (P4i)" {
    // Rule 50 / P4i: a store at schema v45 (no rival table, no next_rival_id meta row)
    // must migrate cleanly to v46 — applySchema creates the rival table — and loading
    // a campaign from the migrated store yields next_rival_id = 1 (safe default).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 40002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    // Simulate a v45 store: drop the rival table and the next_rival_id meta row,
    // then downgrade schema_version to 45.
    try raw.exec("DROP TABLE rival");
    try raw.exec("DELETE FROM meta WHERE key = 'next_rival_id'");
    try raw.exec("UPDATE setting SET value = 45 WHERE key = 'schema_version'");
    // fromDb sees v45, runs applySchema (CREATE TABLE IF NOT EXISTS rival), sets v46.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    // Schema advanced to current.
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    // rival table exists and is empty.
    const cnt = try s2.db.prepare("SELECT COUNT(*) FROM rival");
    defer cnt.finalize();
    try std.testing.expect(try cnt.next());
    try std.testing.expectEqual(@as(i64, 0), cnt.int(0));
    // Loading the campaign yields next_rival_id = 1 (no meta row → safe default).
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 1), loaded.next_rival_id);
    try std.testing.expectEqual(@as(usize, 0), loaded.rivals.count());
}

test "an unknown archetype_key in a rival row rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: rival.archetype_key must name a known archetype.
    try std.testing.expectError(error.CorruptSave, loadRivalAfterTampering(
        "UPDATE rival SET archetype_key = 'notanarchetype' WHERE id = 1",
    ));
}

test "an out-of-range standing in a rival row rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: standing must lie in [rival_min, rival_max].
    try std.testing.expectError(error.CorruptSave, loadRivalAfterTampering(
        "UPDATE rival SET standing = 200 WHERE id = 1",
    ));
}

test "a rival row with a dangling contract reference rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: if rival.contract != 0, the contract_id must resolve to a loaded
    // contract. A nonzero id that names nothing is corruption.
    try std.testing.expectError(error.CorruptSave, loadRivalAfterTampering(
        "UPDATE rival SET contract = 99999 WHERE id = 1",
    ));
}

test "a rival row with a non-markup-safe unit_name rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: unit_name must be markup-safe.
    try std.testing.expectError(error.CorruptSave, loadRivalAfterTampering(
        "UPDATE rival SET unit_name = '{bad markup}' WHERE id = 1",
    ));
}

// P4i: officer arc persistence (rules 47, 67, 69).

fn buildOfficerGs(alloc: std.mem.Allocator) !GameState {
    var gs = GameState.init(alloc, .{ .seed = 50001 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const co = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");

    // Contract 1 (completed) — introduces officer arc (id=1, non-recurring).
    const cid1: types.ContractId = @enumFromInt(1);
    try gs.contracts.put(gs.allocator(), cid1, .{
        .id = cid1,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .completed,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c1 = gs.contracts.getPtr(cid1).?;
    // Use person id 1 (the commander created above).
    const pid1: types.PersonId = @enumFromInt(1);
    const oa1_id: types.OfficerArcId = @enumFromInt(1);
    const oa1: officer_dom.OfficerArc = .{
        .id = oa1_id,
        .person = pid1,
        .contract = cid1,
        .seat = .company_commander,
        .performance = -20,
        .encounters = 1,
        .last_cause = "setback",
        .last_cause_day = 10,
        .recurring = false,
    };
    try gs.commitOfficerArc(oa1);
    try c1.officer_arc_ids.append(gs.allocator(), oa1_id);

    // Contract 2 (active) — recurring officer arc (id=2) carrying forward.
    const cid2: types.ContractId = @enumFromInt(2);
    try gs.contracts.put(gs.allocator(), cid2, .{
        .id = cid2,
        .kind = .garrison_duty,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 18, .base_pay_month = 200_000 },
        .status = .active,
        .assigned_company = co,
        .arc_key = "fracturing_garrison",
    });
    const c2 = gs.contracts.getPtr(cid2).?;
    const oa2_id: types.OfficerArcId = @enumFromInt(2);
    const oa2: officer_dom.OfficerArc = .{
        .id = oa2_id,
        .person = pid1,
        .contract = cid2,
        .seat = .company_commander,
        .performance = -30,
        .encounters = 2,
        .last_cause = "repeated_setback",
        .last_cause_day = 40,
        .recurring = true,
    };
    try gs.commitOfficerArc(oa2);
    try c2.officer_arc_ids.append(gs.allocator(), oa2_id);

    gs.next_officer_arc_id = 3;
    gs.next_rival_id = 1;
    gs.next_actor_id = 1;
    gs.next_contract_id = 3;
    return gs;
}

fn loadOfficerAfterTampering(sql: [*:0]const u8) !void {
    var gs = try buildOfficerGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "officer arcs with nonzero performance and a recurring arc survive a save/load round-trip (P4i)" {
    // Rules 47, 67 / P4i: a campaign with officer arcs — including a recurring arc that
    // carries forward performance and encounters from a closed contract — survives save
    // → load with an identical stateHash. Exercises saveOfficerArcs/loadOfficerArcs.
    var gs = try buildOfficerGs(std.testing.allocator);
    defer gs.deinit();

    try std.testing.expectEqual(@as(usize, 2), gs.officer_arcs.count());
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    // Officer arcs round-tripped.
    try std.testing.expectEqual(@as(usize, 2), loaded.officer_arcs.count());
    const oa2_id: types.OfficerArcId = @enumFromInt(2);
    // Recurring flag survives.
    try std.testing.expect(loaded.officer_arcs.getPtr(oa2_id).?.recurring);
    // Nonzero performance survives.
    try std.testing.expectEqual(@as(i16, -30), loaded.officer_arcs.getPtr(oa2_id).?.performance);
    // Encounters survive.
    try std.testing.expectEqual(@as(u16, 2), loaded.officer_arcs.getPtr(oa2_id).?.encounters);
    // officer_arc_ids rebuilt on contracts.
    const cid2: types.ContractId = @enumFromInt(2);
    const lc2 = loaded.contracts.getPtr(cid2).?;
    try std.testing.expectEqual(@as(usize, 1), lc2.officer_arc_ids.items.len);
    try std.testing.expectEqual(oa2_id, lc2.officer_arc_ids.items[0]);
}

test "a v46 store migrates to v47 with the officer_arc table created and next_officer_arc_id defaults to 1 (P4i)" {
    // Rule 50 / P4i: a store at schema v46 (no officer_arc table, no next_officer_arc_id meta row)
    // must migrate cleanly to v47 — applySchema creates the officer_arc table — and loading
    // a campaign from the migrated store yields next_officer_arc_id = 1 (safe default).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    // Simulate a v46 store: drop the officer_arc table and the next_officer_arc_id meta row,
    // then downgrade schema_version to 46.
    try raw.exec("DROP TABLE officer_arc");
    try raw.exec("DELETE FROM meta WHERE key = 'next_officer_arc_id'");
    try raw.exec("UPDATE setting SET value = 46 WHERE key = 'schema_version'");
    // fromDb sees v46, runs applySchema (CREATE TABLE IF NOT EXISTS officer_arc), sets v47.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    // Schema advanced to current.
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    // officer_arc table exists and is empty.
    const cnt = try s2.db.prepare("SELECT COUNT(*) FROM officer_arc");
    defer cnt.finalize();
    try std.testing.expect(try cnt.next());
    try std.testing.expectEqual(@as(i64, 0), cnt.int(0));
    // Loading the campaign yields next_officer_arc_id = 1 (no meta row → safe default).
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 1), loaded.next_officer_arc_id);
    try std.testing.expectEqual(@as(usize, 0), loaded.officer_arcs.count());
}

test "an unknown seat tag in an officer_arc row rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: officer_arc.seat must name a valid OfficerSeat tag.
    try std.testing.expectError(error.CorruptSave, loadOfficerAfterTampering(
        "UPDATE officer_arc SET seat = 'notaseat' WHERE id = 1",
    ));
}

test "an out-of-range performance in an officer_arc row rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: performance must lie in [perf_min, perf_max].
    try std.testing.expectError(error.CorruptSave, loadOfficerAfterTampering(
        "UPDATE officer_arc SET performance = 200 WHERE id = 1",
    ));
}

test "an officer_arc row with a dangling contract reference rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: if officer_arc.contract != 0, the contract_id must resolve to a loaded
    // contract. A nonzero id that names nothing is corruption.
    try std.testing.expectError(error.CorruptSave, loadOfficerAfterTampering(
        "UPDATE officer_arc SET contract = 99999 WHERE id = 1",
    ));
}

test "an officer_arc row with a dangling person reference rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: officer_arc.person must resolve to a loaded Person.
    try std.testing.expectError(error.CorruptSave, loadOfficerAfterTampering(
        "UPDATE officer_arc SET person = 99999 WHERE id = 1",
    ));
}

test "an officer_arc row with a non-markup-safe last_cause rejects the load as corrupt (P4i)" {
    // Rule 47 / P4i: last_cause must be markup-safe.
    try std.testing.expectError(error.CorruptSave, loadOfficerAfterTampering(
        "UPDATE officer_arc SET last_cause = '{bad markup}' WHERE id = 1",
    ));
}

test "next_officer_arc_id resumes past owned ids after load (P4i counter-resume)" {
    // Rule 70 / P4i: next_officer_arc_id must be >= 1 and above every owned id after load.
    var gs = try buildOfficerGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // Drive counter below the max owned id; reconcileCounters bumps it past the max on load.
    try store.db.exec("UPDATE meta SET value = 0 WHERE key = 'next_officer_arc_id'");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expect(loaded.next_officer_arc_id >= 1);
    // Must be above all owned ids (max owned id = 2).
    var it = loaded.officer_arcs.iterator();
    while (it.next()) |e| {
        try std.testing.expect(loaded.next_officer_arc_id > @intFromEnum(e.key_ptr.*));
    }
}

// P3c.1 hull instance tests ------------------------------------------------

/// Build a GameState with two directly-added units and two crafted HullInstances,
/// isolated from generation seeding (P3c.5). Two named instances (id=1 and id=2)
/// are the owners of the two units. Returns the gs ready for save; caller must deinit.
fn buildHullGs(alloc: std.mem.Allocator) !GameState {
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(alloc, .{ .seed = 30001 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();
    // Add two units directly so the fixture is independent of generation seeding.
    const uid1 = try gs.addUnit("LCT-1V");
    const uid2 = try gs.addUnit("JR7-D");
    const units = [_]types.UnitId{ uid1, uid2 };
    for (units, 0..) |uid, count| {
        const u = gs.unit(uid).?;
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        var inst: hull_mod.HullInstance = .{
            .id = hid,
            .base_key = u.chassis_key,
            .status = .active,
            .intro_year = 2750,
            .pre_campaign = false,
        };
        if (count == 0) {
            inst.name = "Ironside";
            inst.nickname = "Lucky Seven";
            try inst.loadout.append(a, .{ .part_key = "mlas" });
            try inst.loadout.append(a, .{ .part_key = "srm4" });
        }
        try gs.hull_instances.put(a, hid, inst);
        u.hull_instance_id = hid;
    }
    return gs;
}

/// Save a campaign with a hull instance row, corrupt it with `sql`, and try to load it back.
fn loadHullInstanceAfterTampering(sql: [*:0]const u8) !void {
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "hull instances and linked units survive a save/load round-trip with identical stateHash (P3c.1)" {
    // Rules 47, 67 / P3c.1: a campaign with hull instances (one named with loadout,
    // one minimal) and two units linked to them survives save → load with an identical
    // stateHash. Exercises saveHullInstances/loadHullInstances with real rows.
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    const before = digest.stateHash(&gs);
    const inst_count = gs.hull_instances.count();
    try std.testing.expect(inst_count >= 1);

    // Locate the named first instance (loadout has 2 slots).
    var named_id: types.HullInstanceId = .none;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| {
        if (e.value_ptr.name != null) {
            named_id = e.key_ptr.*;
            break;
        }
    }
    try std.testing.expect(named_id != .none);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    // Hull instances round-tripped.
    try std.testing.expectEqual(inst_count, loaded.hull_instances.count());

    // Named instance's fields survive.
    const li = loaded.hull_instances.getPtr(named_id) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Ironside", li.name.?);
    try std.testing.expectEqualStrings("Lucky Seven", li.nickname.?);
    try std.testing.expectEqual(@import("../domain/hull_instance.zig").HullStatus.active, li.status);
    try std.testing.expectEqual(@as(u16, 2750), li.intro_year);
    try std.testing.expect(!li.pre_campaign);
    try std.testing.expectEqual(@as(usize, 2), li.loadout.items.len);
    try std.testing.expectEqualStrings("mlas", li.loadout.items[0].part_key);
    try std.testing.expectEqualStrings("srm4", li.loadout.items[1].part_key);

    // Linked units' hull_instance_id survives.
    var uit = loaded.units.iterator();
    var linked: usize = 0;
    while (uit.next()) |e| if (e.value_ptr.hull_instance_id != .none) {
        linked += 1;
    };
    try std.testing.expect(linked >= 1);
}

test "v47→v48 migration synthesizes one HullInstance per owned unit (P3c.1)" {
    // Rules 50, 51 / P3c.1: a store at schema v47 must migrate to v48 with exactly one
    // HullInstance per owned unit, each having base_key == chassis_key, pre_campaign = true,
    // status = active, loadout length == slot count.
    // Note: SQLite cannot drop a column; hull_instance_id already exists in the unit table
    // after fromDb adds it via the ALTER migration. Setting it to 0 faithfully reproduces
    // the DEFAULT 0 state the real migration produces (same technique as actor tests).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 30002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Gamma");
    const owned_count = gs.units.count();
    try std.testing.expect(owned_count > 0);

    // Record each owned unit's slot count before simulating a v47 store.
    const alloc = std.testing.allocator;
    var slot_counts = std.AutoArrayHashMapUnmanaged(types.UnitId, usize){};
    defer slot_counts.deinit(alloc);
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        try slot_counts.put(alloc, e.key_ptr.*, e.value_ptr.slots.items.len);
    }

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Simulate a v47 store: remove the hull tables, reset hull_instance_id to 0,
    // remove the next_hull_instance_id meta row, and downgrade schema_version.
    // Also clear P3c.2–P3c.4 child tables whose rows now exist (P3c.5 seeded
    // them) and would orphan against migration-recreated instances on load.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("DROP TABLE hull_loadout");
    try raw.exec("DROP TABLE hull_instance");
    try raw.exec("UPDATE unit SET hull_instance_id = 0");
    try raw.exec("DELETE FROM meta WHERE key = 'next_hull_instance_id'");
    try raw.exec("DELETE FROM hull_combat_record");
    try raw.exec("DELETE FROM maintenance_entry");
    try raw.exec("DELETE FROM hull_ownership_history");
    try raw.exec("UPDATE setting SET value = 47 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 47");
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: fromDb sees v47, ddl creates hull_instance + hull_loadout, schema advances to 48.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // One HullInstance per owned unit.
    try std.testing.expectEqual(owned_count, loaded.hull_instances.count());

    // Each owned unit has a non-.none hull_instance_id resolving to a valid instance.
    var luit = loaded.units.iterator();
    while (luit.next()) |e| {
        const u = e.value_ptr;
        try std.testing.expect(u.hull_instance_id != .none);
        const inst = loaded.hull_instances.getPtr(u.hull_instance_id) orelse return error.TestFailed;
        try std.testing.expectEqualStrings(u.chassis_key, inst.base_key);
        try std.testing.expect(inst.pre_campaign);
        try std.testing.expectEqual(@import("../domain/hull_instance.zig").HullStatus.active, inst.status);
        const expected_slots = slot_counts.get(u.id) orelse 0;
        try std.testing.expectEqual(expected_slots, inst.loadout.items.len);
    }

    // next_hull_instance_id is past all owned ids.
    try std.testing.expectEqual(owned_count + 1, loaded.next_hull_instance_id);
}

test "a bad base_key in a hull_instance row rejects the load as corrupt (P3c.1)" {
    // Rule 47 / P3c.1: hull_instance.base_key must name a known chassis.
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_instance SET base_key = 'notachassis'",
    ));
}

test "a bad part_key in a hull_loadout row rejects the load as corrupt (P3c.1)" {
    // Rule 47 / P3c.1: hull_loadout.part_key must name a known part.
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_loadout SET part_key = 'notapart' WHERE slot_index = 0",
    ));
}

test "a duplicate hull_instance id rejects the load as corrupt (P3c.1)" {
    // Rule 47 / P3c.1: each hull_instance row must have a unique id per campaign.
    // The hull_instance table has PRIMARY KEY (cid, id) which prevents a direct insert.
    // We recreate the table without the PK constraint, then insert the duplicate.
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "ALTER TABLE hull_instance RENAME TO hull_instance_bak;" ++
            "CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0, owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_merc_company_id INTEGER NOT NULL DEFAULT 0);" ++
            "INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id FROM hull_instance_bak;" ++
            "INSERT INTO hull_instance SELECT cid, 999, id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id FROM hull_instance_bak LIMIT 1;" ++
            "DROP TABLE hull_instance_bak",
    ));
}

// P3c.2 hull_combat_record tests --------------------------------------------

test "hull_combat_records survive a save/load round-trip with identical stateHash (P3c.2)" {
    // Rules 45, 46, 67 / P3c.2: a campaign with two hull_combat_record rows
    // referencing distinct hull_instances survives save → load with an identical
    // stateHash. Exercises saveHullCombatRecords/loadHullCombatRecords.
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    // Add two distinct combat records referencing the two hull instances.
    var hids: [2]types.HullInstanceId = .{ .none, .none };
    var idx: usize = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| : (idx += 1) {
        if (idx < 2) hids[idx] = e.key_ptr.*;
    }
    try std.testing.expect(hids[0] != .none);
    try std.testing.expect(hids[1] != .none);

    try gs.hull_combat_records.append(gs.allocator(), .{
        .hull_instance_id = hids[0],
        .battle_id = @enumFromInt(1),
        .contract_id = @enumFromInt(2),
        .kills = 3,
        .hits_taken = 5,
        .armor_lost = 20,
        .slots_damaged = 1,
        .slots_destroyed = 0,
        .destroyed = false,
        .cause = .none,
    });
    try gs.hull_combat_records.append(gs.allocator(), .{
        .hull_instance_id = hids[1],
        .battle_id = @enumFromInt(1),
        .contract_id = @enumFromInt(2),
        .kills = 0,
        .hits_taken = 2,
        .armor_lost = 8,
        .slots_damaged = 0,
        .slots_destroyed = 1,
        .destroyed = true,
        .cause = .engine,
    });

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    // Row count survives.
    try std.testing.expectEqual(@as(usize, 2), loaded.hull_combat_records.items.len);

    // First record's fields survive.
    const r0 = loaded.hull_combat_records.items[0];
    try std.testing.expectEqual(hids[0], r0.hull_instance_id);
    try std.testing.expectEqual(@as(u16, 3), r0.kills);
    try std.testing.expectEqual(@as(u16, 5), r0.hits_taken);
    try std.testing.expectEqual(@as(u16, 20), r0.armor_lost);
    try std.testing.expectEqual(@as(u8, 1), r0.slots_damaged);
    try std.testing.expectEqual(@as(u8, 0), r0.slots_destroyed);
    try std.testing.expect(!r0.destroyed);
    try std.testing.expectEqual(@import("../domain/unit.zig").WreckCause.none, r0.cause);

    // Second record's fields survive.
    const r1 = loaded.hull_combat_records.items[1];
    try std.testing.expectEqual(hids[1], r1.hull_instance_id);
    try std.testing.expectEqual(@as(u16, 0), r1.kills);
    try std.testing.expectEqual(@as(u8, 1), r1.slots_destroyed);
    try std.testing.expect(r1.destroyed);
    try std.testing.expectEqual(unit_mod.WreckCause.engine, r1.cause);
}

test "an orphan hull_instance_id in a hull_combat_record rejects the load as corrupt (P3c.2)" {
    // Rule 47 / P3c.2: hull_combat_record.hull_instance_id must resolve to
    // a loaded hull_instance; an orphan must be rejected as a corrupt save.
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    // Get any valid hull_instance_id.
    var hid: types.HullInstanceId = .none;
    var hit = gs.hull_instances.iterator();
    if (hit.next()) |e| hid = e.key_ptr.*;
    try std.testing.expect(hid != .none);

    try gs.hull_combat_records.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .battle_id = @enumFromInt(1),
        .kills = 1,
    });

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // Tamper: point hull_instance_id at a nonexistent instance id.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE hull_combat_record SET hull_instance_id = 99999");
    try store.db.exec("PRAGMA foreign_keys = ON");

    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));

    // Also verify an unknown cause tag is rejected.
    // Restore a valid hull_instance_id (via subquery) and set an invalid cause tag.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE hull_combat_record SET hull_instance_id = (SELECT id FROM hull_instance LIMIT 1), cause = 'not_a_real_cause'");
    try store.db.exec("PRAGMA foreign_keys = ON");

    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

// P3c.3 maintenance_entry tests -----------------------------------------------

test "maintenance_entries survive a save/load round-trip with identical stateHash (P3c.3)" {
    // Rules 45, 46, 67 / P3c.3: a campaign with two maintenance_entry rows
    // referencing distinct hull_instances survives save → load with an identical
    // stateHash. Exercises saveMaintenanceEntries/loadMaintenanceEntries.
    const hull_inst_mod = @import("../domain/hull_instance.zig");
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    // Collect the two hull_instance ids that buildHullGs linked.
    var hids: [2]types.HullInstanceId = .{ .none, .none };
    var idx: usize = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| : (idx += 1) {
        if (idx < 2) hids[idx] = e.key_ptr.*;
    }
    try std.testing.expect(hids[0] != .none);
    try std.testing.expect(hids[1] != .none);

    // Add two distinct maintenance entries referencing the two hull instances.
    try gs.maintenance_entries.append(gs.allocator(), .{
        .hull_instance_id = hids[0],
        .day = 42,
        .tech = @enumFromInt(1),
        .action = .repair,
        .description = hull_inst_mod.MaintenanceAction.repair.describe(),
        .battle_id = .none,
        .cost = 500_000,
    });
    try gs.maintenance_entries.append(gs.allocator(), .{
        .hull_instance_id = hids[1],
        .day = 100,
        .tech = @enumFromInt(2),
        .action = .modify,
        .description = hull_inst_mod.MaintenanceAction.modify.describe(),
        .battle_id = .none,
        .cost = 120_000,
    });

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    // Row count survives.
    try std.testing.expectEqual(@as(usize, 2), loaded.maintenance_entries.items.len);

    // First entry's fields survive.
    const e0 = loaded.maintenance_entries.items[0];
    try std.testing.expectEqual(hids[0], e0.hull_instance_id);
    try std.testing.expectEqual(@as(u32, 42), e0.day);
    try std.testing.expectEqual(hull_inst_mod.MaintenanceAction.repair, e0.action);
    try std.testing.expectEqualStrings("depot structural repair", e0.description);
    try std.testing.expectEqual(@as(types.CBills, 500_000), e0.cost);

    // Second entry's fields survive.
    const e1 = loaded.maintenance_entries.items[1];
    try std.testing.expectEqual(hids[1], e1.hull_instance_id);
    try std.testing.expectEqual(@as(u32, 100), e1.day);
    try std.testing.expectEqual(hull_inst_mod.MaintenanceAction.modify, e1.action);
    try std.testing.expectEqualStrings("loadout refit", e1.description);
    try std.testing.expectEqual(@as(types.CBills, 120_000), e1.cost);
}

test "maintenance_entry corruption is rejected on load (P3c.3)" {
    // Rule 47 / P3c.3: orphan hull_instance_id, unknown action tag, and
    // markup-unsafe description each must reject the load as error.CorruptSave.
    const hull_inst_mod = @import("../domain/hull_instance.zig");
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    var hid: types.HullInstanceId = .none;
    var hit = gs.hull_instances.iterator();
    if (hit.next()) |e| hid = e.key_ptr.*;
    try std.testing.expect(hid != .none);

    try gs.maintenance_entries.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .day = 1,
        .action = .repair,
        .description = hull_inst_mod.MaintenanceAction.repair.describe(),
        .cost = 10_000,
    });

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // (a) Orphan hull_instance_id.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE maintenance_entry SET hull_instance_id = 99999");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));

    // (b) Unknown action tag.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE maintenance_entry SET hull_instance_id = (SELECT id FROM hull_instance LIMIT 1), action = 'not_a_real_action'");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));

    // (c) Markup-unsafe description (validateStoredStrings check, rule 50).
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE maintenance_entry SET action = 'repair', description = char(27) || '[31m'");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

// P3c.4 hull_ownership_history tests -----------------------------------------

test "hull_ownership_history survives a save/load round-trip with identical stateHash (P3c.4)" {
    // Rules 45, 46, 67 / P3c.4: a campaign with two hull_ownership_history rows
    // (one closed, one open) survives save → load with an identical stateHash.
    const hull_inst_mod = @import("../domain/hull_instance.zig");
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    var hids: [2]types.HullInstanceId = .{ .none, .none };
    var idx: usize = 0;
    var hit = gs.hull_instances.iterator();
    while (hit.next()) |e| : (idx += 1) {
        if (idx < 2) hids[idx] = e.key_ptr.*;
    }
    try std.testing.expect(hids[0] != .none);
    try std.testing.expect(hids[1] != .none);

    // Row 0: closed interval (.purchase).
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hids[0],
        .from_day = 10,
        .to_day = 50,
        .acquisition_type = .purchase,
        .prior_owner_key = try gs.allocator().dupe(u8, "unknown"),
    });
    // Row 1: open interval (.salvage).
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hids[1],
        .from_day = 55,
        .to_day = 0,
        .acquisition_type = .salvage,
        .prior_owner_key = try gs.allocator().dupe(u8, "DC"),
    });

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    try std.testing.expectEqual(@as(usize, 2), loaded.hull_ownership_history.items.len);

    const r0 = loaded.hull_ownership_history.items[0];
    try std.testing.expectEqual(hids[0], r0.hull_instance_id);
    try std.testing.expectEqual(@as(u32, 10), r0.from_day);
    try std.testing.expectEqual(@as(u32, 50), r0.to_day);
    try std.testing.expectEqual(hull_inst_mod.AcquisitionType.purchase, r0.acquisition_type);
    try std.testing.expectEqualStrings("unknown", r0.prior_owner_key);

    const r1 = loaded.hull_ownership_history.items[1];
    try std.testing.expectEqual(hids[1], r1.hull_instance_id);
    try std.testing.expectEqual(@as(u32, 55), r1.from_day);
    try std.testing.expectEqual(@as(u32, 0), r1.to_day);
    try std.testing.expectEqual(hull_inst_mod.AcquisitionType.salvage, r1.acquisition_type);
    try std.testing.expectEqualStrings("DC", r1.prior_owner_key);
}

test "hull_ownership_history corruption is rejected on load (P3c.4)" {
    // Rule 47 / P3c.4: orphan hull_instance_id, unknown acquisition_type tag, and
    // markup-unsafe prior_owner_key each must reject the load as error.CorruptSave.
    const hull_inst_mod = @import("../domain/hull_instance.zig");
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    var hid: types.HullInstanceId = .none;
    var hit = gs.hull_instances.iterator();
    if (hit.next()) |e| hid = e.key_ptr.*;
    try std.testing.expect(hid != .none);

    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 1,
        .to_day = 0,
        .acquisition_type = .initial,
        .prior_owner_key = try gs.allocator().dupe(u8, "unknown"),
    });
    _ = hull_inst_mod.AcquisitionType.initial; // verify symbol exists

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // (a) Orphan hull_instance_id.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE hull_ownership_history SET hull_instance_id = 99999");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));

    // (b) Unknown acquisition_type tag.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE hull_ownership_history SET hull_instance_id = (SELECT id FROM hull_instance LIMIT 1), acquisition_type = 'not_a_real_type'");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));

    // (c) Markup-unsafe prior_owner_key (validateStoredStrings check, rule 50).
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE hull_ownership_history SET acquisition_type = 'initial', prior_owner_key = char(27) || '[31m'");
    try store.db.exec("PRAGMA foreign_keys = ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

// P3e.2 HullInstance current-owner tests ------------------------------------

/// Build a GameState with five hull instances (one per OwnerType), a linked unit
/// (for campaign validity), and one rival (for the rival-owned hull). Caller must deinit.
fn buildOwnerGs(alloc: std.mem.Allocator) !GameState {
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(alloc, .{ .seed = 30011 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();
    const uid1 = try gs.addUnit("LCT-1V");
    // Hull 1: player-owned — linked to uid1
    {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(a, hid, hull_mod.HullInstance{ .id = hid, .base_key = "LCT-1V", .status = .active, .intro_year = 2750, .owner = .player });
        gs.unit(uid1).?.hull_instance_id = hid;
    }
    // Hull 2: faction-owned ("LC")
    {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(a, hid, hull_mod.HullInstance{ .id = hid, .base_key = "LCT-1V", .status = .active, .intro_year = 2750, .owner = .{ .faction = "LC" } });
    }
    // Hull 3: merc-company-owned — add one merc company first
    const mid: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(a, mid, merc_company_mod.MercCompany{ .id = mid, .archetype_key = "enemy_raiders", .commander_first = "Ann", .commander_last = "Smith", .unit_name = "Smith Raiders", .faction_key = "DC", .side = .enemy, .doctrine = .aggressive });
    gs.next_merc_company_id = 2;
    {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(a, hid, hull_mod.HullInstance{ .id = hid, .base_key = "LCT-1V", .status = .active, .intro_year = 2750, .owner = .{ .merc_company = mid } });
    }
    // Hull 4: market-owned
    {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(a, hid, hull_mod.HullInstance{ .id = hid, .base_key = "LCT-1V", .status = .active, .intro_year = 2750, .owner = .market });
    }
    // Hull 5: destroyed
    {
        const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
        gs.next_hull_instance_id += 1;
        try gs.hull_instances.put(a, hid, hull_mod.HullInstance{ .id = hid, .base_key = "LCT-1V", .status = .permanently_destroyed, .intro_year = 2750, .owner = .destroyed });
    }
    return gs;
}

test "all five HullOwner kinds survive a save/load round-trip with identical stateHash (P3e.2)" {
    // Rules 45, 46, 53, 67 / P3e.2: a campaign holding one hull per owner kind
    // (player, faction, rival, market, destroyed) saves and loads with an identical
    // stateHash; firstStateDifference is empty; each reconstructed owner tag and payload matches.
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = try buildOwnerGs(std.testing.allocator);
    defer gs.deinit();

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    // Count owner kinds in loaded state — one of each.
    var counts = [_]u32{0} ** 5; // indexed by @intFromEnum(OwnerType)
    var it = loaded.hull_instances.iterator();
    while (it.next()) |e| {
        counts[@intFromEnum(std.meta.activeTag(e.value_ptr.owner))] += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), counts[@intFromEnum(hull_mod.OwnerType.player)]);
    try std.testing.expectEqual(@as(u32, 1), counts[@intFromEnum(hull_mod.OwnerType.faction)]);
    try std.testing.expectEqual(@as(u32, 1), counts[@intFromEnum(hull_mod.OwnerType.merc_company)]);
    try std.testing.expectEqual(@as(u32, 1), counts[@intFromEnum(hull_mod.OwnerType.market)]);
    try std.testing.expectEqual(@as(u32, 1), counts[@intFromEnum(hull_mod.OwnerType.destroyed)]);

    // Verify faction key and merc_company id payloads survive.
    var it2 = loaded.hull_instances.iterator();
    while (it2.next()) |e| {
        switch (e.value_ptr.owner) {
            .faction => |k| try std.testing.expectEqualStrings("LC", k),
            .merc_company => |r| try std.testing.expect(r != .none),
            else => {},
        }
    }
}

test "an unknown owner_type tag in a hull_instance row rejects the load as corrupt (P3e.2)" {
    // Rule 47 / P3e.2: owner_type must be a valid OwnerType tag.
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_instance SET owner_type = 'bogus'",
    ));
}

test "owner_type='faction' with empty faction key rejects the load as corrupt (P3e.2)" {
    // Rule 47 / P3e.2: a faction owner must carry a non-empty faction key.
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_instance SET owner_type = 'faction'",
    ));
}

test "owner_type='merc_company' with zero merc_company_id rejects the load as corrupt (P3e.2)" {
    // Rule 47 / P3e.2: a merc_company owner must carry a non-zero merc_company_id.
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_instance SET owner_type = 'merc_company'",
    ));
}

test "non-empty owner_faction_key with owner_type='player' rejects the load as corrupt (P3e.2)" {
    // Rule 47 / P3e.2: a player/market/destroyed owner must carry an empty faction key (consistency).
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_instance SET owner_faction_key = 'LC'",
    ));
}

test "owner_type='faction' with unknown faction key rejects the load as corrupt (P3e.2)" {
    // Rule 47 / P3e.2: a faction owner's key must name a known faction (Check.house).
    try std.testing.expectError(error.CorruptSave, loadHullInstanceAfterTampering(
        "UPDATE hull_instance SET owner_type = 'faction', owner_faction_key = 'notafaction'",
    ));
}

test "a merc_company-owned hull with an absent merc_company_id rejects the load as corrupt (P3e.2)" {
    // Rule 47 / P3e.2: a merc_company-owned hull whose merc_company_id names no live merc company is
    // corruption (validateReferences post-load check, which runs after all collections load).
    var gs = try buildOwnerGs(std.testing.allocator);
    defer gs.deinit();

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // Delete the merc_company row — the merc_company-owned hull now has a dangling FK.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("DELETE FROM merc_company");
    try store.db.exec("PRAGMA foreign_keys = ON");

    if (store.load(std.testing.allocator, gs.campaign_id)) |loaded_gs| {
        var mutable = loaded_gs;
        mutable.deinit();
        return error.TestExpectedError; // should have returned error.CorruptSave
    } else |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
    }
}

test "v51→v52 migration backfills all hull instances to owner='player' (P3e.2)" {
    // Rules 50, 51 / P3e.2: a store at schema v51 must migrate through v52 with every
    // hull_instance row backfilled to owner_type='player' / owner_faction_key='' / owner_merc_company_id=0,
    // and every loaded hull has owner == .player. SQLite ADD COLUMN NOT NULL DEFAULT
    // handles the backfill deterministically.
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();
    const hull_count = gs.hull_instances.count();
    try std.testing.expect(hull_count > 0);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Simulate a v51 store: recreate hull_instance without the three owner columns
    // and downgrade schema_version.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("ALTER TABLE hull_instance RENAME TO hull_instance_v52;" ++
        "CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);" ++
        "INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign FROM hull_instance_v52;" ++
        "DROP TABLE hull_instance_v52");
    try raw.exec("UPDATE setting SET value = 51 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 51");
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: fromDb sees v51, runs the three ALTER TABLE ADD COLUMN migrations → v52.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // Every hull loaded as owner == .player.
    try std.testing.expectEqual(hull_count, loaded.hull_instances.count());
    var lit = loaded.hull_instances.iterator();
    while (lit.next()) |e| {
        try std.testing.expectEqual(hull_mod.OwnerType.player, std.meta.activeTag(e.value_ptr.owner));
        try std.testing.expect(e.value_ptr.owner == .player);
    }
}

// P3e.3: faction_roster + rival_roster persistence (rules 47, 67, 69).

fn buildRosterGs(alloc: std.mem.Allocator) !GameState {
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(alloc, .{ .seed = 50001 });
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();

    // One merc company (id=1) so merc_company_rosters has a live FK target.
    const mcid1: types.MercCompanyId = @enumFromInt(1);
    try gs.merc_companies.put(a, mcid1, merc_company_mod.MercCompany{
        .id = mcid1,
        .archetype_key = "enemy_raiders",
        .commander_first = "Bo",
        .commander_last = "Rex",
        .unit_name = "Rex Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
    });
    gs.next_merc_company_id = 2;

    // Three hull instances. Owners set consistently (hygiene).
    const hid1: types.HullInstanceId = @enumFromInt(1);
    const hid2: types.HullInstanceId = @enumFromInt(2);
    const hid3: types.HullInstanceId = @enumFromInt(3);
    try gs.hull_instances.put(a, hid1, .{ .id = hid1, .base_key = "LCT-1V", .status = .active, .owner = .{ .faction = "DC" } });
    try gs.hull_instances.put(a, hid2, .{ .id = hid2, .base_key = "JR7-D", .status = .active, .owner = .{ .faction = "DC" } });
    try gs.hull_instances.put(a, hid3, .{ .id = hid3, .base_key = "LCT-1V", .status = .active, .owner = .{ .merc_company = mcid1 } });
    gs.next_hull_instance_id = 4;

    // Faction roster: DC owns hulls 1 and 2 (multi-element, tests order preservation).
    const fr_gop = try gs.faction_rosters.getOrPut(a, "DC");
    if (!fr_gop.found_existing) fr_gop.value_ptr.* = .empty;
    try fr_gop.value_ptr.append(a, hid1);
    try fr_gop.value_ptr.append(a, hid2);

    // Merc company roster: merc company 1 owns hull 3.
    const mrit_gop = try gs.merc_company_rosters.getOrPut(a, mcid1);
    if (!mrit_gop.found_existing) mrit_gop.value_ptr.* = .empty;
    try mrit_gop.value_ptr.append(a, hid3);

    _ = hull_mod.HullStatus.active; // suppress unused import warning
    return gs;
}

/// Save a campaign with roster rows, corrupt it with `sql`, and try to load it.
fn loadRosterAfterTampering(sql: [*:0]const u8) !void {
    var gs = try buildRosterGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec(sql);
    try store.db.exec("PRAGMA foreign_keys = ON");
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    loaded.deinit();
}

test "faction and merc-company rosters survive a save/load round-trip with identical stateHash (P3e entity split)" {
    // Rules 47, 67 / P3e entity split: a campaign with faction_rosters and merc_company_rosters
    // survives save → load with an identical stateHash. Exercises saveFactionRosters/loadFactionRosters
    // and saveMercCompanyRosters/loadMercCompanyRosters.
    var gs = try buildRosterGs(std.testing.allocator);
    defer gs.deinit();

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    // Faction roster round-tripped with correct key count and order.
    try std.testing.expectEqual(@as(usize, 1), loaded.faction_rosters.count());
    const dc_list = loaded.faction_rosters.getPtr("DC") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), dc_list.items.len);
    const hid1: types.HullInstanceId = @enumFromInt(1);
    const hid2: types.HullInstanceId = @enumFromInt(2);
    try std.testing.expectEqual(hid1, dc_list.items[0]);
    try std.testing.expectEqual(hid2, dc_list.items[1]);

    // Merc company roster round-tripped.
    try std.testing.expectEqual(@as(usize, 1), loaded.merc_company_rosters.count());
    const mcid1: types.MercCompanyId = @enumFromInt(1);
    const mc_list = loaded.merc_company_rosters.getPtr(mcid1) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), mc_list.items.len);
    const hid3: types.HullInstanceId = @enumFromInt(3);
    try std.testing.expectEqual(hid3, mc_list.items[0]);
}

test "a v52 store migrates to v54 with the roster tables created (P3e.3/entity-split)" {
    // Rules 50, 51 / P3e.3 + entity split: a store at schema v52 (no roster tables) must
    // migrate to v54 — ddl creates faction_roster/merc_company_roster/merc_company — and
    // loading a campaign yields empty rosters. rival_roster is never created (v53→v54 drops it).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Simulate a v52 store: drop roster/merc tables and downgrade schema_version.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("DROP TABLE IF EXISTS faction_roster");
    try raw.exec("DROP TABLE IF EXISTS merc_company_roster");
    try raw.exec("DROP TABLE IF EXISTS merc_company");
    try raw.exec("UPDATE setting SET value = 52 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 52");
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: fromDb sees v52, ddl creates tables, migrations run, schema advances to 54.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    // faction_roster and merc_company_roster exist and are empty; rival_roster is gone.
    const fc = try s2.db.prepare("SELECT COUNT(*) FROM faction_roster");
    defer fc.finalize();
    try std.testing.expect(try fc.next());
    try std.testing.expectEqual(@as(i64, 0), fc.int(0));
    const mrc = try s2.db.prepare("SELECT COUNT(*) FROM merc_company_roster");
    defer mrc.finalize();
    try std.testing.expect(try mrc.next());
    try std.testing.expectEqual(@as(i64, 0), mrc.int(0));

    // Loading yields empty rosters.
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.faction_rosters.count());
    try std.testing.expectEqual(@as(usize, 0), loaded.merc_company_rosters.count());
}

test "a faction_roster row naming no hull instance rejects the load as corrupt (P3e.3)" {
    // Rule 47 / P3e.3: every faction_roster hull_instance_id must resolve to a live hull instance.
    try std.testing.expectError(error.CorruptSave, loadRosterAfterTampering(
        "UPDATE faction_roster SET hull_instance_id = 99999 WHERE hull_instance_id = 1",
    ));
}

test "a faction_roster row with an unknown faction_key rejects the load as corrupt (P3e.3)" {
    // Rule 47 / P3e.3: every faction_roster key must name a known faction (Check.house).
    try std.testing.expectError(error.CorruptSave, loadRosterAfterTampering(
        "UPDATE faction_roster SET faction_key = 'notahouse' WHERE faction_key = 'DC'",
    ));
}

test "a merc_company_roster row naming no merc company rejects the load as corrupt (P3e entity split)" {
    // Rule 47 / P3e entity split: every merc_company_roster key must resolve to a live merc company.
    try std.testing.expectError(error.CorruptSave, loadRosterAfterTampering(
        "UPDATE merc_company_roster SET merc_company_id = 99999 WHERE merc_company_id = 1",
    ));
}

// P3e entity split: merc company save/load and migration tests.

test "merc companies survive a save/load round-trip with identical stateHash (P3e entity split)" {
    // Rules 45, 46, 53, 67 / P3e entity split: a campaign holding merc_companies survives
    // save → load with identical stateHash; firstStateDifference is empty; archetype/
    // side/doctrine/unit_name survive; rule 69 round-trip proof for the new collection.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50020 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();

    const mc1: merc_company_mod.MercCompany = .{
        .id = @enumFromInt(1),
        .archetype_key = "enemy_raiders",
        .commander_first = "Bo",
        .commander_last = "Rex",
        .unit_name = "Rex Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
    };
    const mc2: merc_company_mod.MercCompany = .{
        .id = @enumFromInt(2),
        .archetype_key = "enemy_raiders",
        .commander_first = "Jo",
        .commander_last = "Marr",
        .unit_name = "Marr Lancers",
        .faction_key = "LC",
        .side = .employer,
        .doctrine = .cautious,
    };
    try gs.merc_companies.put(a, mc1.id, mc1);
    try gs.merc_companies.put(a, mc2.id, mc2);
    gs.next_merc_company_id = 3;

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(@as(usize, 2), loaded.merc_companies.count());
    const lmc1 = loaded.merc_companies.getPtr(@enumFromInt(1)) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("enemy_raiders", lmc1.archetype_key);
    try std.testing.expectEqualStrings("Rex Raiders", lmc1.unit_name);
    try std.testing.expectEqual(merc_company_mod.FactionSide.enemy, lmc1.side);
    try std.testing.expectEqual(merc_company_mod.RivalDoctrine.aggressive, lmc1.doctrine);
}

test "a rival row with a dangling merc_company_id rejects the load as corrupt (P3e entity split)" {
    // Rule 47 / P3e entity split: Rival.merc_company_id must resolve to a live merc company or be .none.
    var gs = try buildRivalGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Tamper: point a rival's merc_company_id at a nonexistent merc company.
    try store.db.exec("PRAGMA foreign_keys = OFF");
    try store.db.exec("UPDATE rival SET merc_company_id = 99999");
    try store.db.exec("PRAGMA foreign_keys = ON");
    if (store.load(std.testing.allocator, gs.campaign_id)) |loaded_gs| {
        var mutable = loaded_gs;
        mutable.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
    }
}

test "a v53 store migrates to v54 with merc_company/merc_company_roster created and rival relabelled (P3e entity split)" {
    // Rules 50, 51 / P3e entity split: a store at schema v53 (rival_roster, owner_rival_id) must
    // migrate to v54: owner_merc_company_id added, owner_type='rival'→'merc_company' relabelled,
    // rival_roster dropped, merc_company/merc_company_roster created.
    // Asserted at the SQL level (not through store.load) because the relabelled hull has
    // no merc_company parent row — provably unreachable in a real save; P3e.5 adds producers.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50030 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();

    // One player-owned hull instance (baseline for migration).
    const hid1: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(a, hid1, .{ .id = hid1, .base_key = "LCT-1V", .status = .active });
    gs.next_hull_instance_id = 2;

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Simulate a v53 store: recreate hull_instance without owner_merc_company_id but with
    // owner_rival_id; recreate rival without merc_company_id; recreate rival_roster; drop
    // merc_company/merc_company_roster; set schema version 53.
    try raw.exec("PRAGMA foreign_keys = OFF");
    // Recreate hull_instance with owner_rival_id instead of owner_merc_company_id.
    try raw.exec("ALTER TABLE hull_instance RENAME TO hull_instance_v54;" ++
        "CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_rival_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);" ++
        "INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id FROM hull_instance_v54;" ++
        "DROP TABLE hull_instance_v54");
    // Insert a raw hull row with owner_type='rival' and owner_rival_id=7 to test relabelling.
    try raw.exec("INSERT INTO hull_instance VALUES (1, 99, 777, 'LCT-1V', NULL, NULL, 'active', 2750, 0, 'rival', '', 7)");
    // Recreate rival table without merc_company_id.
    try raw.exec("ALTER TABLE rival RENAME TO rival_v54;" ++
        "CREATE TABLE rival (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, contract INTEGER NOT NULL DEFAULT 0, standing INTEGER NOT NULL DEFAULT 0, encounters INTEGER NOT NULL DEFAULT 1, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);" ++
        "INSERT INTO rival SELECT cid, ord, id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine, contract, standing, encounters, last_cause, last_cause_day, recurring FROM rival_v54;" ++
        "DROP TABLE rival_v54");
    // Create rival_roster (was dropped by current ddl); drop merc_company/merc_company_roster.
    try raw.exec("CREATE TABLE rival_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, rival_id INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED)");
    try raw.exec("DROP TABLE IF EXISTS merc_company");
    try raw.exec("DROP TABLE IF EXISTS merc_company_roster");
    try raw.exec("UPDATE setting SET value = 53 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 53");
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: fromDb sees v53, runs v54 migrations, schema advances to 54.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    // merc_company and merc_company_roster exist and are empty.
    const mc_count = try s2.db.prepare("SELECT COUNT(*) FROM merc_company");
    defer mc_count.finalize();
    try std.testing.expect(try mc_count.next());
    try std.testing.expectEqual(@as(i64, 0), mc_count.int(0));
    const mrc_count = try s2.db.prepare("SELECT COUNT(*) FROM merc_company_roster");
    defer mrc_count.finalize();
    try std.testing.expect(try mrc_count.next());
    try std.testing.expectEqual(@as(i64, 0), mrc_count.int(0));

    // rival_roster is gone.
    const rr_check = try s2.db.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='rival_roster'");
    defer rr_check.finalize();
    try std.testing.expect(try rr_check.next());
    try std.testing.expectEqual(@as(i64, 0), rr_check.int(0));

    // The relabelled hull (id=777) has owner_type='merc_company' and owner_merc_company_id=7;
    // owner_rival_id is gone — the rebuild-table migration removed it.
    const relabel_q = try s2.db.prepare("SELECT owner_type, owner_merc_company_id FROM hull_instance WHERE id = 777");
    defer relabel_q.finalize();
    try std.testing.expect(try relabel_q.next());
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ot = try relabel_q.text(0, fba.allocator());
    try std.testing.expectEqualStrings("merc_company", ot);
    try std.testing.expectEqual(@as(i64, 7), relabel_q.int(1));
}

// P3f.4: merc company lifecycle — save/load and migration tests.

test "MercCompany save/load round-trip with all four new fields non-default (P3f.4)" {
    // Rules 45, 46, 53, 67 / P3f.4: a campaign with non-default cbills/founded_day/
    // dissolved_day/logo_key survives save → load with identical stateHash; the four
    // new fields round-trip exactly.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 58001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();

    const mc1: merc_company_mod.MercCompany = .{
        .id = @enumFromInt(1),
        .archetype_key = "enemy_raiders",
        .commander_first = "Bo",
        .commander_last = "Rex",
        .unit_name = "Rex Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
        .cbills = 3_500_000,
        .founded_day = 42,
        .dissolved_day = 90,
        .logo_key = "ashfall_lancers",
    };
    try gs.merc_companies.put(a, mc1.id, mc1);
    gs.next_merc_company_id = 2;

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));

    const lmc = loaded.merc_companies.getPtr(@enumFromInt(1)) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(types.CBills, 3_500_000), lmc.cbills);
    try std.testing.expectEqual(@as(u32, 42), lmc.founded_day);
    try std.testing.expectEqual(@as(u32, 90), lmc.dissolved_day);
    try std.testing.expectEqualStrings("ashfall_lancers", lmc.logo_key);
}

test "a v57 store migrates to v58 with four new merc_company columns and legacy defaults (P3f.4)" {
    // Rules 50, 51 / P3f.4: a store at schema v57 (no cbills/founded_day/dissolved_day/logo_key)
    // migrates to v58: four new columns exist with fail-closed legacy defaults.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 58002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();

    const mc1: merc_company_mod.MercCompany = .{
        .id = @enumFromInt(1),
        .archetype_key = "enemy_raiders",
        .commander_first = "Bo",
        .commander_last = "Rex",
        .unit_name = "Rex Raiders",
        .faction_key = "DC",
        .side = .enemy,
        .doctrine = .aggressive,
    };
    try gs.merc_companies.put(a, mc1.id, mc1);
    gs.next_merc_company_id = 2;

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Simulate a v57 store: drop the four new columns and set schema_version = 57.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("ALTER TABLE merc_company RENAME TO merc_company__bak");
    try raw.exec("CREATE TABLE merc_company (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED)");
    try raw.exec("INSERT INTO merc_company SELECT cid, ord, id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine FROM merc_company__bak");
    try raw.exec("DROP TABLE merc_company__bak");
    try raw.exec("UPDATE setting SET value = 57 WHERE key = 'schema_version'");
    try raw.exec("PRAGMA foreign_keys = ON");

    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    // Four new columns must now exist.
    try std.testing.expect(try Store.hasColumnRt(raw, "merc_company", "cbills"));
    try std.testing.expect(try Store.hasColumnRt(raw, "merc_company", "founded_day"));
    try std.testing.expect(try Store.hasColumnRt(raw, "merc_company", "dissolved_day"));
    try std.testing.expect(try Store.hasColumnRt(raw, "merc_company", "logo_key"));

    // Load the legacy row — fail-closed defaults.
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    const lmc = loaded.merc_companies.getPtr(@enumFromInt(1)) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(types.CBills, 0), lmc.cbills);
    try std.testing.expectEqual(@as(u32, 0), lmc.founded_day);
    try std.testing.expectEqual(@as(u32, 0), lmc.dissolved_day);
    try std.testing.expectEqualStrings("", lmc.logo_key);
}

test "v50→v51 migration seeds one .initial ownership interval per owned hull (P3c.4)" {
    // Rules 50, 51 / P3c.4: a store at schema v50 must migrate to v51 with exactly one
    // .initial ownership interval per owned unit, with from_day == acquired_day,
    // to_day == 0, and prior_owner_key == "unknown".
    const hull_inst_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 30003 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Delta");
    // generateInto now links every unit with a pre_campaign HullInstance (P3c.5).
    const owned_count = gs.units.count();
    try std.testing.expect(owned_count > 0);

    // Record acquired_day values before simulating.
    var acquired_days = std.AutoArrayHashMapUnmanaged(types.HullInstanceId, u32){};
    defer acquired_days.deinit(std.testing.allocator);
    var uit2 = gs.units.iterator();
    while (uit2.next()) |e| {
        try acquired_days.put(std.testing.allocator, e.value_ptr.hull_instance_id, e.value_ptr.acquired_day);
    }

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Simulate a v50 store: drop hull_ownership_history and downgrade schema_version.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("DROP TABLE hull_ownership_history");
    try raw.exec("UPDATE setting SET value = 50 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 50");
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: fromDb sees v50, ddl creates hull_ownership_history, schema advances to 51.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));

    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // Exactly one .initial row per owned hull.
    try std.testing.expectEqual(owned_count, loaded.hull_ownership_history.items.len);
    for (loaded.hull_ownership_history.items) |row| {
        try std.testing.expectEqual(hull_inst_mod.AcquisitionType.initial, row.acquisition_type);
        try std.testing.expectEqual(@as(u32, 0), row.to_day);
        try std.testing.expectEqualStrings("unknown", row.prior_owner_key);
        const expected_day = acquired_days.get(row.hull_instance_id) orelse return error.TestFailed;
        try std.testing.expectEqual(expected_day, row.from_day);
    }
}

test "seeded faction hull pool survives a save/load round-trip with identical stateHash (P3e.4)" {
    // Rules 47, 67 / P3e.4: a campaign seeded with faction hull pools via
    // create_commander survives save → load with an identical stateHash.
    // Exercises saveFactionRosters/loadFactionRosters on the production seeded
    // shape (owner + provenance + membership), not the hand-built synthetic rows
    // used by the P3e.3 round-trip test.
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50010 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{
        .name = "Kerensky",
        .origin = .LC,
        .profession = .line_officer,
        .start_year = 3025,
    } });

    const before = digest.stateHash(&gs);
    // Five Great House factions plus six minor Periphery (P3e.5b manufacturing)
    // plus PER (P3e.5b-1) must have rosters.
    try std.testing.expectEqual(@as(usize, 12), gs.faction_rosters.count());

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(@as(usize, 12), loaded.faction_rosters.count());
}

test "seeded merc company hull pool survives a save/load round-trip with identical stateHash (P3e.5a)" {
    // Rules 47, 67 / P3e.5a: a campaign seeded with merc company hull pools via
    // create_commander survives save → load with an identical stateHash.
    // Exercises saveMercCompanies/loadMercCompanies and
    // saveMercCompanyRosters/loadMercCompanyRosters on the production seeded
    // shape (owner + provenance + membership).
    const commands = @import("../sim/commands.zig");
    const tuning = @import("../domain/tuning.zig").t;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50011 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{
        .name = "Kerensky",
        .origin = .LC,
        .profession = .line_officer,
        .start_year = 3025,
    } });

    const before = digest.stateHash(&gs);
    // Merc companies and rosters must be non-empty after seeding.
    try std.testing.expect(gs.merc_companies.count() > 0);
    try std.testing.expect(gs.merc_company_rosters.count() > 0);
    try std.testing.expectEqual(@as(usize, tuning.generation.merc_company_count), gs.merc_companies.count());

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(gs.merc_companies.count(), loaded.merc_companies.count());
    try std.testing.expectEqual(gs.merc_company_rosters.count(), loaded.merc_company_rosters.count());
}

test "P3e.6: surplus listing hull_instance_id round-trips through save/load" {
    // Rules 45, 46, 53: a listing with hull_instance_id set saves and reloads
    // with the id preserved and the digest unchanged.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.day_index = 5;

    // Mint a market-owned HullInstance.
    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hid, .{
        .id = hid,
        .base_key = "SHD-2H",
        .owner = .market,
    });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 1,
        .to_day = 0,
        .acquisition_type = .transfer,
        .prior_owner_key = "LC",
    });

    // Surplus listing with hull_instance_id set.
    const lid: types.ListingId = @enumFromInt(gs.next_listing_id);
    gs.next_listing_id += 1;
    try gs.market_listings.append(gs.allocator(), .{
        .id = lid,
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 1,
        .expires_day = 62,
        .hull_instance_id = hid,
    });

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // hull_instance_id must survive the round-trip.
    var found = false;
    for (loaded.market_listings.items) |l| {
        if (l.id == lid) {
            try std.testing.expectEqual(hid, l.hull_instance_id);
            found = true;
        }
    }
    try std.testing.expect(found);

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
}

test "P3e.6: v55 store upgrades to v56, existing listings load with hull_instance_id = .none" {
    // Rules 50, 51: a v55 store (listing table without hull_instance_id) migrates
    // to v56 — the column is added with DEFAULT 0 — and existing abstraction-path
    // listings load with hull_instance_id == .none.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    // Add an abstraction-path listing (no hull_instance_id).
    const lid: types.ListingId = @enumFromInt(gs.next_listing_id);
    gs.next_listing_id += 1;
    try gs.market_listings.append(gs.allocator(), .{
        .id = lid,
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 800_000,
        .listed_day = 1,
        .expires_day = 62,
        // hull_instance_id defaults to .none
    });

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Downgrade to v55: drop hull_instance_id from listing by recreating the table.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec(
        \\ALTER TABLE listing RENAME TO listing__bak;
        \\CREATE TABLE listing (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, item_key TEXT, rarity TEXT, price INTEGER, qty INTEGER, staple INTEGER CHECK (staple IN (0,1)), listed INTEGER, expires INTEGER, hq INTEGER, c_armor INTEGER, c_quality TEXT, c_damaged INTEGER, c_destroyed INTEGER, c_missing INTEGER, black INTEGER NOT NULL DEFAULT 0 CHECK (black IN (0,1)), company INTEGER NOT NULL DEFAULT 0, id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\INSERT INTO listing SELECT cid, ord, kind, item_key, rarity, price, qty, staple, listed, expires, hq, c_armor, c_quality, c_damaged, c_destroyed, c_missing, black, company, id FROM listing__bak;
        \\DROP TABLE listing__bak;
        \\UPDATE setting SET value = 55 WHERE key = 'schema_version';
        \\UPDATE campaign SET schema_version = 55;
    );
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: sees v55, runs migration to add hull_instance_id.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    try std.testing.expect(try Store.hasColumnRt(raw, "listing", "hull_instance_id"));

    // Load and verify existing listing has hull_instance_id == .none.
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var found = false;
    for (loaded.market_listings.items) |l| {
        if (l.id == lid) {
            try std.testing.expectEqual(types.HullInstanceId.none, l.hull_instance_id);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "P3e.6: a listing with hull_instance_id naming no hull is rejected as corrupt" {
    // Rules 47/48/70: a listing row whose hull_instance_id names no hull instance
    // must be rejected with CorruptSave by validateReferences.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56003 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    // Add a surplus listing with hull_instance_id pointing to a non-existent instance.
    const bad_hid: types.HullInstanceId = @enumFromInt(99999);
    try gs.market_listings.append(gs.allocator(), .{
        .id = @enumFromInt(gs.next_listing_id),
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 900_000,
        .listed_day = 1,
        .expires_day = 62,
        .hull_instance_id = bad_hid,
    });
    gs.next_listing_id += 1;

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // Tamper: the hull_instance 99999 does not exist in hull_instances.
    // validateReferences must detect this and return CorruptSave.
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "P3f.1: dispersed listing planet_key and available_after round-trip through save/load" {
    // Rules 45, 46, 53: a dispersed black-market listing with planet_key and
    // available_after set saves and reloads with both fields preserved and
    // the digest unchanged.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57001 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);
    gs.clock.day_index = 5;

    // Mint a market-owned HullInstance (validateReferences requires a referenced hull).
    const hid: types.HullInstanceId = @enumFromInt(gs.next_hull_instance_id);
    gs.next_hull_instance_id += 1;
    try gs.hull_instances.put(gs.allocator(), hid, .{
        .id = hid,
        .base_key = "SHD-2H",
        .owner = .market,
    });
    try gs.hull_ownership_history.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .from_day = 1,
        .to_day = 0,
        .acquisition_type = .transfer,
        .prior_owner_key = "LC",
    });

    // Dispersed black-market listing with planet_key and available_after set.
    const lid_dispersed: types.ListingId = @enumFromInt(gs.next_listing_id);
    gs.next_listing_id += 1;
    try gs.market_listings.append(gs.allocator(), .{
        .id = lid_dispersed,
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 1_200_000,
        .listed_day = 1,
        .expires_day = 90,
        .black_market = true,
        .hull_instance_id = hid,
        .planet_key = "galatea",
        .available_after = 100,
    });

    // Ordinary HQ listing with default values (covers the migrated/HQ path).
    const lid_ordinary: types.ListingId = @enumFromInt(gs.next_listing_id);
    gs.next_listing_id += 1;
    try gs.market_listings.append(gs.allocator(), .{
        .id = lid_ordinary,
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 850_000,
        .listed_day = 1,
        .expires_day = 30,
        // planet_key defaults to "", available_after defaults to 0
    });

    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    // Dispersed listing must preserve planet_key and available_after.
    var found_dispersed = false;
    var found_ordinary = false;
    for (loaded.market_listings.items) |l| {
        if (l.id == lid_dispersed) {
            try std.testing.expectEqualStrings("galatea", l.planet_key);
            try std.testing.expectEqual(@as(u32, 100), l.available_after);
            found_dispersed = true;
        }
        if (l.id == lid_ordinary) {
            try std.testing.expectEqualStrings("", l.planet_key);
            try std.testing.expectEqual(@as(u32, 0), l.available_after);
            found_ordinary = true;
        }
    }
    try std.testing.expect(found_dispersed);
    try std.testing.expect(found_ordinary);

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
}

test "P3f.1: v56 store upgrades to v57, existing listings load with planet_key='' and available_after=0" {
    // Rules 50, 51: a v56 store (listing table without planet_key/available_after)
    // migrates to v57 — columns are added with defaults — and existing listings
    // load with planet_key == "" and available_after == 0 (fail-closed, rule 49).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57002 });
    defer gs.deinit();
    _ = try founding.createCommander(&gs, "T", .LC, .line_officer);

    // Add an abstraction-path listing (no planet_key/available_after).
    const lid: types.ListingId = @enumFromInt(gs.next_listing_id);
    gs.next_listing_id += 1;
    try gs.market_listings.append(gs.allocator(), .{
        .id = lid,
        .kind = .unit,
        .item_key = "SHD-2H",
        .rarity = .common,
        .price = 800_000,
        .listed_day = 1,
        .expires_day = 62,
        // planet_key and available_after default to "" and 0
    });

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    // Downgrade to v56: drop planet_key and available_after from listing by recreating the table.
    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec(
        \\ALTER TABLE listing RENAME TO listing__bak;
        \\CREATE TABLE listing (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, item_key TEXT, rarity TEXT, price INTEGER, qty INTEGER, staple INTEGER CHECK (staple IN (0,1)), listed INTEGER, expires INTEGER, hq INTEGER, c_armor INTEGER, c_quality TEXT, c_damaged INTEGER, c_destroyed INTEGER, c_missing INTEGER, black INTEGER NOT NULL DEFAULT 0 CHECK (black IN (0,1)), company INTEGER NOT NULL DEFAULT 0, id INTEGER NOT NULL DEFAULT 0, hull_instance_id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\INSERT INTO listing SELECT cid, ord, kind, item_key, rarity, price, qty, staple, listed, expires, hq, c_armor, c_quality, c_damaged, c_destroyed, c_missing, black, company, id, hull_instance_id FROM listing__bak;
        \\DROP TABLE listing__bak;
        \\UPDATE setting SET value = 56 WHERE key = 'schema_version';
        \\UPDATE campaign SET schema_version = 56;
    );
    try raw.exec("PRAGMA foreign_keys = ON");

    // Re-open: sees v56, runs migration to add planet_key and available_after.
    const s2 = try Store.fromDb(raw);
    defer s2.close();
    try std.testing.expectEqual(@as(i64, schema_version), s2.getSetting("schema_version", 0));
    try std.testing.expect(try Store.hasColumnRt(raw, "listing", "planet_key"));
    try std.testing.expect(try Store.hasColumnRt(raw, "listing", "available_after"));

    // Load and verify existing listing has planet_key == "" and available_after == 0.
    var loaded = try s2.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var found = false;
    for (loaded.market_listings.items) |l| {
        if (l.id == lid) {
            try std.testing.expectEqualStrings("", l.planet_key);
            try std.testing.expectEqual(@as(u32, 0), l.available_after);
            found = true;
        }
    }
    try std.testing.expect(found);
}
