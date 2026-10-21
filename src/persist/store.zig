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
const battle_phase_mod = @import("../domain/battle_phase.zig");
const battle_phases_rules = @import("../sim/battle_phases.zig");
const battle_rules = @import("../sim/battle.zig");
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
const merc_band = @import("../domain/merc_band.zig");
const officer_dom = @import("../domain/officer.zig");
const world_state_dom = @import("../domain/world_state.zig");
const world_state_rules = @import("../sim/world_state.zig");
const actor_rules = @import("../sim/actors.zig");
const situation_mod = @import("../domain/situation.zig");
const personage_mod = @import("../domain/personage.zig");
const personage_rules = @import("../sim/personages.zig");
const personage_relation_rules = @import("../sim/personage_relations.zig");
const conflict_mod = @import("../domain/conflict.zig");
const politics = @import("../sim/politics.zig");
const news_mod = @import("../domain/news.zig");
const news = @import("../sim/news.zig");
const npc_base = @import("../sim/npc_base.zig");
const faction_mod = @import("../domain/faction.zig");
const planet_mod = @import("../domain/planet.zig");

const artillery_store = @import("artillery_store.zig");
const artillery_battle_store = @import("artillery_battle_store.zig");
const artillery = @import("../sim/artillery.zig");
const artillery_catalogue = @import("../domain/artillery_catalogue.zig");

pub const schema_version = 76;

/// The oldest format this executable reads (rule 51). Every format from it
/// up to `schema_version` opens through successive migrations in place:
/// v71 → v72 (`migrateV71ToV72`), v72 → v73 (`migrateV72ToV73`), v73 → v74
/// (`migrateV73ToV74`), v74 → v75 (`migrateV74ToV75`), then v75 → v76
/// (`migrateV75ToV76`).
pub const oldest_supported_schema_version = 71;

/// Every table of schema v76: schema v75's with `merc_company` in its v76
/// definition (`merc_company_v76_ddl`), and `merc_hull_arrival`
/// (`merc_hull_arrival_v76_ddl`).
const ddl: [:0]const u8 = std.fmt.comptimePrint("{s}", .{replaceTableLine(ddl_v75, "merc_company", merc_company_v76_ddl) ++ "\n" ++ merc_hull_arrival_v76_ddl});

/// Every table of schema v75, frozen: byte for byte the executable DDL of
/// that format, schema v74's and its `news_item` table. `migrateV75ToV76`
/// validates a v75 store against it. Never edited.
const ddl_v75: [:0]const u8 = ddl_v74 ++ "\n" ++ news_item_v75_ddl;

/// The columns schema v75's `merc_company` has, in order (as v72's); the
/// v76 rebuild copies exactly these.
const merc_company_v75_columns = "cid, ord, id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine, cbills, founded_day, dissolved_day, logo_key, band_key, understrength_since";

/// Schema v76's `merc_company` table (docs/p5d-conflict-world-design.md §A,
/// §L1): v75's columns, then the company's base world `home_planet_key`
/// (non-empty text) and its `ready_day` (a campaign day), before its keys.
/// A loaded row is also checked by `npc_base.validate`.
const merc_company_v76_ddl: []const u8 = blk: {
    const line = tableLine(ddl_v72, "merc_company");
    const keys = ", PRIMARY KEY (cid, id)";
    const at = std.mem.indexOf(u8, line, keys).?;
    break :blk line[0..at] ++
        ", home_planet_key TEXT NOT NULL CHECK (typeof(home_planet_key)='text' AND length(home_planet_key) > 0)" ++
        ", ready_day INTEGER NOT NULL CHECK (typeof(ready_day)='integer' AND ready_day BETWEEN 0 AND 4294967295)" ++
        line[at..];
};

/// Schema v76's `merc_hull_arrival` table (docs/p5d-conflict-world-design.md
/// §L1): one row per merc hull still travelling to its company's base, in
/// insertion order (`GameState.merc_hull_arrivals`), with its arrival day.
/// A loaded row is also checked by `npc_base.validate`.
const merc_hull_arrival_v76_ddl =
    \\CREATE TABLE IF NOT EXISTS merc_hull_arrival (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), hull_instance_id INTEGER NOT NULL CHECK (typeof(hull_instance_id)='integer' AND hull_instance_id BETWEEN 1 AND 4294967295), arrive_day INTEGER NOT NULL CHECK (typeof(arrive_day)='integer' AND arrive_day BETWEEN 0 AND 4294967295), PRIMARY KEY (cid, hull_instance_id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
;

/// Each v75 company's v76 `home_planet_key`: its faction's
/// `npc_base.compatibilityBase`, the documented compatibility value of rule
/// 51, as a `CASE faction_key` with one arm per faction that has one.
const merc_company_v76_base_case: []const u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var s: []const u8 = "CASE faction_key";
    for (faction_mod.table) |row| {
        const base = npc_base.compatibilityBase(row.key) orelse continue;
        s = s ++ " WHEN '" ++ row.key ++ "' THEN '" ++ base.key ++ "'";
    }
    break :blk s ++ " END";
};

/// The factions `merc_company_v76_base_case` has an arm for, as an SQL
/// list; a v75 company of any other `faction_key` is refused.
const merc_company_v76_factions: []const u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var s: []const u8 = "";
    for (faction_mod.table) |row| {
        if (npc_base.compatibilityBase(row.key) == null) continue;
        s = s ++ (if (s.len == 0) "" else ", ") ++ "'" ++ row.key ++ "'";
    }
    break :blk "(" ++ s ++ ")";
};

/// Every table of schema v74, frozen: byte for byte the executable DDL of
/// that format, schema v73's with `contract` and `conflict` in their v74
/// definitions (`contract_v74_ddl`, `conflict_v74_ddl`). `migrateV74ToV75`
/// validates a v74 store against it. Never edited.
const ddl_v74: [:0]const u8 = blk: {
    const with_contract = replaceTableLine(ddl_v73, "contract", contract_v74_ddl);
    break :blk std.fmt.comptimePrint("{s}", .{replaceTableLine(with_contract, "conflict", conflict_v74_ddl)});
};

/// Schema v75's `news_item` table (docs/p5d-conflict-world-design.md §K
/// "News", "Persistence and digest"): one row per item in id order, its
/// kind and presence kind by tag name, its conflict, the world it was heard
/// on and its text, both non-empty; at most one item of a kind per
/// conflict. A loaded row is also checked by `news.validate`.
const news_item_v75_ddl =
    \\CREATE TABLE IF NOT EXISTS news_item (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), id INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), kind TEXT NOT NULL CHECK (typeof(kind)='text' AND kind IN ('discovery','strike','resolution')), conflict_id INTEGER NOT NULL CHECK (typeof(conflict_id)='integer' AND conflict_id BETWEEN 1 AND 4294967295), reach_from TEXT NOT NULL CHECK (typeof(reach_from)='text' AND reach_from IN ('hq','company')), reach_from_planet_key TEXT NOT NULL CHECK (typeof(reach_from_planet_key)='text' AND length(reach_from_planet_key) > 0), text TEXT NOT NULL CHECK (typeof(text)='text' AND length(text) > 0), PRIMARY KEY (cid, id), UNIQUE (cid, ord), UNIQUE (cid, conflict_id, kind), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, conflict_id) REFERENCES conflict(cid, id) DEFERRABLE INITIALLY DEFERRED);
;

/// `text` (one CREATE TABLE per line) with `table`'s line replaced by
/// `line`.
fn replaceTableLine(comptime text: []const u8, comptime table: []const u8, comptime line: []const u8) []const u8 {
    const old = tableLine(text, table);
    const at = std.mem.indexOf(u8, text, old).?;
    return text[0..at] ++ line ++ text[at + old.len ..];
}

/// Every table of schema v73, frozen: byte for byte the executable DDL of
/// that format, schema v72's and its `conflict` table. `migrateV73ToV74`
/// validates a v73 store against it. Never edited.
const ddl_v73: [:0]const u8 = ddl_v72 ++ "\n" ++ conflict_v73_ddl;

/// The columns schema v73's `contract` has, in order (as v72's); the v74
/// rebuild copies exactly these.
const contract_v73_columns = "cid, is_offer, ord, id, kind, employer, enemy, planet, status, company, start_day, score, dist_ly, beachhead, transit_days, arrive_day, end_day, monthly_net, next_battle, battles, casualties, objective, committed_bv, pool, pool_remaining, vp, ineffective_since, breach_day, length_months, base_pay, advance_pct, signing_bonus, transport_pct, overhead_pct, battle_loss_pct, salvage_pct, salvage_exchange, command_rights, negotiated, enemy_lances, enemy_quality, enemy_lance_bv, enemy_lance_tons, offer_hq, orders_day, arc_key, arc_beat, escalation_clock, arc_finale_key, command_capacity";

/// Schema v74's `contract` table: v73's columns, then each position's
/// backer (docs/p5d-conflict-world-design.md §C "No contract without a
/// backer"): `conflict_id` (NULL only on a row a v73 store held, which then
/// has the default side and no days), `side`, `on_station_by` and
/// `close_day` (both set or both NULL, the close no later than the
/// station day), and a foreign key to the backing conflict. A loaded row is
/// also checked by `politics.validate`.
const contract_v74_ddl: []const u8 = blk: {
    const line = tableLine(ddl_v72, "contract");
    const campaign_fk = ", FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);";
    std.debug.assert(std.mem.endsWith(u8, line, campaign_fk));
    break :blk line[0 .. line.len - campaign_fk.len] ++
        ", conflict_id INTEGER CHECK (conflict_id IS NULL OR (typeof(conflict_id)='integer' AND conflict_id BETWEEN 1 AND 4294967295))" ++
        ", side TEXT NOT NULL DEFAULT 'defender' CHECK (typeof(side)='text' AND side IN ('aggressor','defender'))" ++
        ", on_station_by INTEGER CHECK (on_station_by IS NULL OR (typeof(on_station_by)='integer' AND on_station_by BETWEEN 0 AND 4294967295))" ++
        ", close_day INTEGER CHECK (close_day IS NULL OR (typeof(close_day)='integer' AND close_day BETWEEN 0 AND 4294967295))" ++
        ", CHECK (conflict_id IS NOT NULL OR (side = 'defender' AND on_station_by IS NULL AND close_day IS NULL))" ++
        ", CHECK ((close_day IS NULL) = (on_station_by IS NULL) AND (close_day IS NULL OR close_day <= on_station_by))" ++
        campaign_fk[0 .. campaign_fk.len - 2] ++
        ", FOREIGN KEY (cid, conflict_id) REFERENCES conflict(cid, id) DEFERRABLE INITIALLY DEFERRED);";
};

/// The columns schema v73's `conflict` has, in order; the v74 rebuild
/// copies exactly these.
const conflict_v73_columns = "cid, ord, id, template_key, planet_key, aggressor_faction, aggressor_personage, defender_faction, defender_personage, instigator, staging_planet_key, opened_day, discovery_day, strike_day, expires_day, local_lances, local_quality, local_lance_bv, local_lance_tons, strike_lances, strike_quality, strike_lance_bv, strike_lance_tons, outcome";

/// Schema v74's `conflict` table (docs/p5d-conflict-world-design.md §C, §E,
/// §J): v73's columns with the aggressor side (aggressor, staging world,
/// strike and end days, strike force) NULL exactly on a `standing`
/// conflict, and `family`. An `offensive` row keeps v73's day order and
/// never stands down; a `standing` row is known from its opening, is
/// instigated by its defender and only stands down. A loaded row is checked
/// by `politics.validate`.
const conflict_v74_ddl =
    \\CREATE TABLE IF NOT EXISTS conflict (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), id INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), template_key TEXT NOT NULL CHECK (typeof(template_key)='text' AND length(template_key) > 0), planet_key TEXT NOT NULL CHECK (typeof(planet_key)='text' AND length(planet_key) > 0), aggressor_faction TEXT CHECK (aggressor_faction IS NULL OR (typeof(aggressor_faction)='text' AND length(aggressor_faction) > 0)), aggressor_personage INTEGER CHECK (aggressor_personage IS NULL OR (typeof(aggressor_personage)='integer' AND aggressor_personage BETWEEN 1 AND 4294967295)), defender_faction TEXT NOT NULL CHECK (typeof(defender_faction)='text' AND length(defender_faction) > 0), defender_personage INTEGER NOT NULL CHECK (typeof(defender_personage)='integer' AND defender_personage BETWEEN 1 AND 4294967295), instigator INTEGER NOT NULL CHECK (typeof(instigator)='integer' AND instigator BETWEEN 1 AND 4294967295), staging_planet_key TEXT CHECK (staging_planet_key IS NULL OR (typeof(staging_planet_key)='text' AND length(staging_planet_key) > 0)), opened_day INTEGER NOT NULL CHECK (typeof(opened_day)='integer' AND opened_day BETWEEN 0 AND 4294967295), discovery_day INTEGER NOT NULL CHECK (typeof(discovery_day)='integer' AND discovery_day BETWEEN 0 AND 4294967295), strike_day INTEGER CHECK (strike_day IS NULL OR (typeof(strike_day)='integer' AND strike_day BETWEEN 0 AND 4294967295)), expires_day INTEGER CHECK (expires_day IS NULL OR (typeof(expires_day)='integer' AND expires_day BETWEEN 0 AND 4294967295)), local_lances INTEGER NOT NULL CHECK (typeof(local_lances)='integer' AND local_lances BETWEEN 1 AND 255), local_quality TEXT NOT NULL CHECK (typeof(local_quality)='text' AND local_quality IN ('green','regular','veteran','elite')), local_lance_bv INTEGER NOT NULL CHECK (typeof(local_lance_bv)='integer' AND local_lance_bv >= 0), local_lance_tons INTEGER NOT NULL CHECK (typeof(local_lance_tons)='integer' AND local_lance_tons BETWEEN 0 AND 4294967295), strike_lances INTEGER CHECK (strike_lances IS NULL OR (typeof(strike_lances)='integer' AND strike_lances BETWEEN 1 AND 255)), strike_quality TEXT CHECK (strike_quality IS NULL OR (typeof(strike_quality)='text' AND strike_quality IN ('green','regular','veteran','elite'))), strike_lance_bv INTEGER CHECK (strike_lance_bv IS NULL OR (typeof(strike_lance_bv)='integer' AND strike_lance_bv >= 0)), strike_lance_tons INTEGER CHECK (strike_lance_tons IS NULL OR (typeof(strike_lance_tons)='integer' AND strike_lance_tons BETWEEN 0 AND 4294967295)), outcome TEXT CHECK (outcome IS NULL OR (typeof(outcome)='text' AND outcome IN ('aggressor_won','defender_held','stood_down'))), family TEXT NOT NULL CHECK (typeof(family)='text' AND family IN ('offensive','standing')), CHECK (family <> 'offensive' OR (aggressor_faction IS NOT NULL AND aggressor_personage IS NOT NULL AND staging_planet_key IS NOT NULL AND strike_day IS NOT NULL AND expires_day IS NOT NULL AND strike_lances IS NOT NULL AND strike_quality IS NOT NULL AND strike_lance_bv IS NOT NULL AND strike_lance_tons IS NOT NULL AND opened_day < discovery_day AND discovery_day < strike_day AND strike_day < expires_day AND (outcome IS NULL OR outcome <> 'stood_down'))), CHECK (family <> 'standing' OR (aggressor_faction IS NULL AND aggressor_personage IS NULL AND staging_planet_key IS NULL AND strike_day IS NULL AND expires_day IS NULL AND strike_lances IS NULL AND strike_quality IS NULL AND strike_lance_bv IS NULL AND strike_lance_tons IS NULL AND discovery_day = opened_day AND instigator = defender_personage AND (outcome IS NULL OR outcome = 'stood_down'))), PRIMARY KEY (cid, id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, aggressor_personage) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, defender_personage) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, instigator) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED);
;

/// Schema v73's `conflict` table, frozen (docs/p5d-conflict-world-design.md
/// §C, §J): every conflict offensive, every column but `outcome` required.
const conflict_v73_ddl =
    \\CREATE TABLE IF NOT EXISTS conflict (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), id INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), template_key TEXT NOT NULL CHECK (typeof(template_key)='text' AND length(template_key) > 0), planet_key TEXT NOT NULL CHECK (typeof(planet_key)='text' AND length(planet_key) > 0), aggressor_faction TEXT NOT NULL CHECK (typeof(aggressor_faction)='text' AND length(aggressor_faction) > 0), aggressor_personage INTEGER NOT NULL CHECK (typeof(aggressor_personage)='integer' AND aggressor_personage BETWEEN 1 AND 4294967295), defender_faction TEXT NOT NULL CHECK (typeof(defender_faction)='text' AND length(defender_faction) > 0), defender_personage INTEGER NOT NULL CHECK (typeof(defender_personage)='integer' AND defender_personage BETWEEN 1 AND 4294967295), instigator INTEGER NOT NULL CHECK (typeof(instigator)='integer' AND instigator BETWEEN 1 AND 4294967295), staging_planet_key TEXT NOT NULL CHECK (typeof(staging_planet_key)='text' AND length(staging_planet_key) > 0), opened_day INTEGER NOT NULL CHECK (typeof(opened_day)='integer' AND opened_day BETWEEN 0 AND 4294967295), discovery_day INTEGER NOT NULL CHECK (typeof(discovery_day)='integer' AND discovery_day BETWEEN 0 AND 4294967295), strike_day INTEGER NOT NULL CHECK (typeof(strike_day)='integer' AND strike_day BETWEEN 0 AND 4294967295), expires_day INTEGER NOT NULL CHECK (typeof(expires_day)='integer' AND expires_day BETWEEN 0 AND 4294967295), local_lances INTEGER NOT NULL CHECK (typeof(local_lances)='integer' AND local_lances BETWEEN 1 AND 255), local_quality TEXT NOT NULL CHECK (typeof(local_quality)='text' AND local_quality IN ('green','regular','veteran','elite')), local_lance_bv INTEGER NOT NULL CHECK (typeof(local_lance_bv)='integer' AND local_lance_bv >= 0), local_lance_tons INTEGER NOT NULL CHECK (typeof(local_lance_tons)='integer' AND local_lance_tons BETWEEN 0 AND 4294967295), strike_lances INTEGER NOT NULL CHECK (typeof(strike_lances)='integer' AND strike_lances BETWEEN 1 AND 255), strike_quality TEXT NOT NULL CHECK (typeof(strike_quality)='text' AND strike_quality IN ('green','regular','veteran','elite')), strike_lance_bv INTEGER NOT NULL CHECK (typeof(strike_lance_bv)='integer' AND strike_lance_bv >= 0), strike_lance_tons INTEGER NOT NULL CHECK (typeof(strike_lance_tons)='integer' AND strike_lance_tons BETWEEN 0 AND 4294967295), outcome TEXT CHECK (outcome IS NULL OR (typeof(outcome)='text' AND outcome IN ('aggressor_won','defender_held'))), CHECK (opened_day < discovery_day AND discovery_day < strike_day AND strike_day < expires_day), PRIMARY KEY (cid, id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, aggressor_personage) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, defender_personage) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, instigator) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED);
;

/// Every index of schema v76: schema v75's and `ix_merc_hull_arrival_cid`.
const index_ddl = index_ddl_v75 ++ "\n" ++ merc_hull_arrival_v76_index_ddl;

/// Every index of schema v75: schema v74's and `ix_news_item_cid`. Never
/// edited.
const index_ddl_v75 = index_ddl_v74 ++ "\n" ++ news_item_v75_index_ddl;

const merc_hull_arrival_v76_index_ddl = "CREATE INDEX IF NOT EXISTS ix_merc_hull_arrival_cid ON merc_hull_arrival(cid);";

/// Every index of schema v74, as of v73: schema v72's and
/// `ix_conflict_cid`. Never edited.
const index_ddl_v74 = index_ddl_v72 ++ "\n" ++ conflict_v73_index_ddl;

const conflict_v73_index_ddl = "CREATE INDEX IF NOT EXISTS ix_conflict_cid ON conflict(cid);";

const news_item_v75_index_ddl = "CREATE INDEX IF NOT EXISTS ix_news_item_cid ON news_item(cid);";

/// Every table of schema v72, frozen: byte for byte the executable DDL of
/// that format. `migrateV72ToV73` validates a v72 store against it, and
/// schema v71 is derived from it (`ddl_v71`). Never edited: a later schema
/// changes `ddl`, not this.
const ddl_v72 =
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
    \\CREATE TABLE IF NOT EXISTS retired_hq (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (ord >= 0 AND ord <= 4294967295), id INTEGER NOT NULL CHECK (id > 0 AND id <= 4294967295), name TEXT NOT NULL, planet TEXT NOT NULL, tier TEXT NOT NULL CHECK (tier IN ('field','regional','brigade')), sold_day INTEGER NOT NULL CHECK (sold_day >= 0 AND sold_day <= 4294967295), PRIMARY KEY (cid, id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hq_facility (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, level INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hq_id) REFERENCES hq(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hq_project (cid INTEGER NOT NULL, hq_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, facility TEXT, target_level INTEGER, started INTEGER, paperwork_done INTEGER, construction_done INTEGER, cost INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hq_id) REFERENCES hq(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL CHECK (is_offer IN (0,1)), ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER CHECK (salvage_exchange IN (0,1)), command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0 CHECK (negotiated IN (0,1)), enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER, arc_key TEXT NOT NULL DEFAULT '', arc_beat INTEGER NOT NULL DEFAULT 0, escalation_clock INTEGER NOT NULL DEFAULT 0, arc_finale_key TEXT NOT NULL DEFAULT '', command_capacity INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS operation (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, template_key TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT NOT NULL, opened_day INTEGER NOT NULL, resolved_day INTEGER, committed_day INTEGER, intent TEXT NOT NULL DEFAULT 'secure_objective', tempo TEXT NOT NULL DEFAULT 'advance', reserve_committed INTEGER NOT NULL DEFAULT 0 CHECK (reserve_committed IN (0,1)), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS txn (cid INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER, amount INTEGER, category TEXT, company INTEGER, hq INTEGER, contract INTEGER, note TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS loan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, principal INTEGER, balance INTEGER, rate_bp INTEGER, term INTEGER, next_pay INTEGER, payment INTEGER, id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS courier (cid INTEGER NOT NULL, ord INTEGER NOT NULL, to_kind TEXT, to_id INTEGER, amount INTEGER, sent INTEGER, eta INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, entity_kind TEXT, entity_id INTEGER, floor INTEGER, cap INTEGER, sent INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS supply_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, company INTEGER, min_days INTEGER, tons INTEGER, ammo_battles INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS stock_policy (cid INTEGER NOT NULL, ord INTEGER NOT NULL, hq INTEGER, part_key TEXT, min_qty INTEGER, target INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS bay_job (cid INTEGER NOT NULL CHECK (typeof(cid)='integer'), ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), hq INTEGER NOT NULL CHECK (typeof(hq)='integer' AND hq BETWEEN 1 AND 4294967295), kind TEXT NOT NULL CHECK (typeof(kind)='text' AND kind IN ('depot_repair','reactivation','fabrication','refit','artillery_depot_repair')), unit INTEGER, item_key TEXT NOT NULL CHECK (typeof(item_key)='text'), duration INTEGER NOT NULL CHECK (typeof(duration)='integer' AND duration > 0 AND duration <= 4294967295), queued INTEGER NOT NULL CHECK (typeof(queued)='integer' AND queued BETWEEN 0 AND 4294967295), started INTEGER, done INTEGER, cost INTEGER NOT NULL CHECK (typeof(cost)='integer' AND cost >= 0), artillery INTEGER, PRIMARY KEY(cid,ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,unit) REFERENCES unit(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,artillery) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK ((unit IS NOT NULL) = (kind IN ('depot_repair','reactivation','refit'))), CHECK ((artillery IS NOT NULL) = (kind='artillery_depot_repair')), CHECK (unit IS NULL OR (typeof(unit)='integer' AND unit BETWEEN 1 AND 4294967295)), CHECK (artillery IS NULL OR (typeof(artillery)='integer' AND artillery BETWEEN 1 AND 4294967295)), CHECK ((started IS NULL) = (done IS NULL)), CHECK (started IS NULL OR (typeof(started)='integer' AND started BETWEEN queued AND 4294967295 AND typeof(done)='integer' AND done BETWEEN started AND 4294967295)), CHECK ((item_key != '') = (kind='fabrication')));
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
    \\CREATE TABLE IF NOT EXISTS pending_event (cid INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, day INTEGER, contract INTEGER, company INTEGER, default_choice INTEGER, deadline INTEGER, chosen INTEGER, person INTEGER NOT NULL DEFAULT 0, id INTEGER NOT NULL DEFAULT 0, battle INTEGER NOT NULL DEFAULT 0, situation TEXT CHECK (situation IS NULL OR typeof(situation)='text'), actor INTEGER NOT NULL CHECK (typeof(actor)='integer' AND actor BETWEEN 0 AND 4294967295), CHECK ((situation IS NOT NULL) = (kind = 'situation')), CHECK ((actor != 0) = (kind = 'situation')), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS refit_plan (cid INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, committed INTEGER CHECK (committed IN (0,1)), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS refit_op (cid INTEGER NOT NULL, plan_ord INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT, slot_key TEXT, location TEXT, part_key TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, plan_ord) REFERENCES refit_plan(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL CHECK (id > 0), day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1 CHECK (acknowledged IN (0,1)), salvage_unclaimed INTEGER NOT NULL DEFAULT 0, operation TEXT NOT NULL DEFAULT '', operation_intent TEXT NOT NULL DEFAULT '', operation_tempo TEXT NOT NULL DEFAULT '', operation_interventions TEXT NOT NULL DEFAULT '', artillery_present INTEGER NOT NULL CHECK(typeof(artillery_present)='integer' AND artillery_present IN (0,1)), phase_count INTEGER NOT NULL CHECK (typeof(phase_count)='integer' AND phase_count BETWEEN 0 AND 3), lever_count INTEGER NOT NULL CHECK (typeof(lever_count)='integer' AND lever_count BETWEEN 0 AND 5), UNIQUE (cid, ord), UNIQUE (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_hit (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, unit INTEGER, chassis_key TEXT, chassis_name TEXT, armor_before INTEGER, armor_after INTEGER, slot TEXT, slot_part TEXT, slot_result TEXT, destroyed INTEGER, cause TEXT, pilot INTEGER, crew_name TEXT, wound_severity INTEGER, wound_location TEXT, wound_permanent INTEGER, fate TEXT, recovery_roll INTEGER, recovery_target INTEGER, lost INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_ammo (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, family TEXT, burned INTEGER, reserve INTEGER, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_salvage (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, key TEXT, name TEXT, bv INTEGER, armor_pct INTEGER, quality TEXT, damaged INTEGER, destroyed INTEGER, missing INTEGER, hull_instance_id INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS operation_task (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, operation_id INTEGER NOT NULL, ord INTEGER NOT NULL, lance_id INTEGER NOT NULL, task TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS operation_intervention (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, operation_id INTEGER NOT NULL, ord INTEGER NOT NULL, kind TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_task (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL, lance_id INTEGER NOT NULL, lance_name TEXT NOT NULL, task TEXT NOT NULL, succeeded INTEGER NOT NULL CHECK (succeeded IN (0,1)), note TEXT NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_phase (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord BETWEEN 0 AND 2), phase TEXT NOT NULL CHECK (phase IN ('contact','decisive','pursuit','withdrawal')), order_kind TEXT NOT NULL CHECK (order_kind IN ('engage','press_on','withdraw','pursue','consolidate','cover_recovery','roe')), order_roe TEXT CHECK (order_roe IS NULL OR order_roe IN ('hold','standard','cautious')), roe TEXT NOT NULL CHECK (roe IN ('hold','standard','cautious')), ratio_bonus INTEGER NOT NULL CHECK (typeof(ratio_bonus)='integer' AND ratio_bonus BETWEEN -2147483648 AND 2147483647), scenario_mod INTEGER NOT NULL CHECK (typeof(scenario_mod)='integer' AND scenario_mod BETWEEN -2147483648 AND 2147483647), roe_roll INTEGER NOT NULL CHECK (typeof(roe_roll)='integer' AND roe_roll BETWEEN -2147483648 AND 2147483647), momentum INTEGER NOT NULL CHECK (typeof(momentum)='integer' AND momentum BETWEEN -2147483648 AND 2147483647), lever_mod INTEGER NOT NULL CHECK (typeof(lever_mod)='integer' AND lever_mod BETWEEN -2147483648 AND 2147483647), margin INTEGER NOT NULL CHECK (typeof(margin)='integer' AND margin BETWEEN -2147483648 AND 2147483647), hits INTEGER NOT NULL CHECK (typeof(hits)='integer' AND hits BETWEEN 0 AND 4294967295), PRIMARY KEY (cid, report_ord, ord), CHECK ((order_roe IS NULL) = (order_kind != 'roe')), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_report_lever (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord BETWEEN 0 AND 4), kind TEXT NOT NULL CHECK (kind IN ('commit_reserve','emergency_recon','reinforce','air_cover','field_repair')), cost INTEGER NOT NULL CHECK (typeof(cost)='integer' AND cost BETWEEN 0 AND 255), roll_mod INTEGER NOT NULL CHECK (typeof(roll_mod)='integer' AND roll_mod BETWEEN -2147483648 AND 2147483647), PRIMARY KEY (cid, report_ord, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_in_progress (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), contract_id INTEGER NOT NULL CHECK (typeof(contract_id)='integer' AND contract_id BETWEEN 1 AND 4294967295), phase TEXT NOT NULL CHECK (phase IN ('contact','decisive')), orders INTEGER NOT NULL CHECK (typeof(orders)='integer' AND orders >= 1), PRIMARY KEY (cid, contract_id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS battle_in_progress_order (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), order_kind TEXT NOT NULL CHECK (order_kind IN ('engage','press_on','withdraw','pursue','consolidate','cover_recovery','roe','commit_reserve','intervene')), order_roe TEXT CHECK (order_roe IS NULL OR order_roe IN ('hold','standard','cautious')), order_intervention TEXT CHECK (order_intervention IS NULL OR order_intervention IN ('emergency_recon','reinforce','air_cover','field_repair')), pause TEXT NOT NULL CHECK (pause IN ('contact','decisive')), margin INTEGER NOT NULL CHECK (typeof(margin)='integer' AND margin BETWEEN -2147483648 AND 2147483647), hits INTEGER NOT NULL CHECK (typeof(hits)='integer' AND hits BETWEEN 0 AND 4294967295), momentum INTEGER NOT NULL CHECK (typeof(momentum)='integer' AND momentum BETWEEN -2147483648 AND 2147483647), roe TEXT NOT NULL CHECK (roe IN ('hold','standard','cautious')), outcome TEXT CHECK (outcome IS NULL OR outcome IN ('decisive_victory','victory','draw','defeat','rout')), held_field INTEGER NOT NULL CHECK (held_field IN (0,1)), odds_next TEXT NOT NULL CHECK (odds_next IN ('decisive','pursuit','cover')), odds_0 INTEGER NOT NULL CHECK (typeof(odds_0)='integer' AND odds_0 BETWEEN 0 AND 65535), odds_1 INTEGER NOT NULL CHECK (typeof(odds_1)='integer' AND odds_1 BETWEEN 0 AND 65535), odds_2 INTEGER NOT NULL CHECK (typeof(odds_2)='integer' AND odds_2 BETWEEN 0 AND 65535), odds_3 INTEGER NOT NULL CHECK (typeof(odds_3)='integer' AND odds_3 BETWEEN 0 AND 65535), odds_4 INTEGER NOT NULL CHECK (typeof(odds_4)='integer' AND odds_4 BETWEEN 0 AND 65535), odds_total INTEGER NOT NULL CHECK (typeof(odds_total)='integer' AND odds_total BETWEEN 1 AND 65535), lever_mod INTEGER NOT NULL CHECK (typeof(lever_mod)='integer' AND lever_mod BETWEEN -2147483648 AND 2147483647), reserve_committed INTEGER NOT NULL CHECK (reserve_committed IN (0,1)), capacity_spent INTEGER NOT NULL CHECK (typeof(capacity_spent)='integer' AND capacity_spent BETWEEN 0 AND 255), PRIMARY KEY (cid, contract_id, ord), CHECK ((order_roe IS NULL) = (order_kind != 'roe')), CHECK ((order_intervention IS NULL) = (order_kind != 'intervene')), CHECK ((outcome IS NULL) = (pause = 'contact')), CHECK (pause = 'decisive' OR held_field = 0), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, contract_id) REFERENCES battle_in_progress(cid, contract_id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS actor (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, first_name TEXT NOT NULL, last_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, contract INTEGER NOT NULL DEFAULT 0, trust INTEGER NOT NULL DEFAULT 0, debt INTEGER NOT NULL DEFAULT 0, respect INTEGER NOT NULL DEFAULT 0, hostility INTEGER NOT NULL DEFAULT 0, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), flags INTEGER NOT NULL CHECK (typeof(flags)='integer' AND flags BETWEEN 0 AND 15 AND (flags & 3) != 3), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS world_state (cid INTEGER NOT NULL, ord INTEGER NOT NULL, planet_key TEXT NOT NULL, security INTEGER NOT NULL DEFAULT 0, civilian_support INTEGER NOT NULL DEFAULT 0, infrastructure_strain INTEGER NOT NULL DEFAULT 0, employer_control INTEGER NOT NULL DEFAULT 0, enemy_influence INTEGER NOT NULL DEFAULT 0, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL CHECK (typeof(flags)='integer' AND flags BETWEEN 0 AND 7 AND (flags & 3) != 3), PRIMARY KEY (cid, planet_key), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS contract_situation (cid INTEGER NOT NULL, contract INTEGER NOT NULL CHECK (typeof(contract)='integer' AND contract BETWEEN 1 AND 4294967295), ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), situation TEXT NOT NULL CHECK (typeof(situation)='text'), day INTEGER NOT NULL CHECK (typeof(day)='integer' AND day BETWEEN 0 AND 4294967295), actor INTEGER NOT NULL CHECK (typeof(actor)='integer' AND actor BETWEEN 1 AND 4294967295), choice INTEGER CHECK (choice IS NULL OR (typeof(choice)='integer' AND choice BETWEEN 0 AND 2)), PRIMARY KEY (cid, contract, ord), UNIQUE (cid, contract, situation), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, actor) REFERENCES actor(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS rival (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, contract INTEGER NOT NULL DEFAULT 0, standing INTEGER NOT NULL DEFAULT 0, encounters INTEGER NOT NULL DEFAULT 1, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), merc_company_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS officer_arc (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, person INTEGER NOT NULL, contract INTEGER NOT NULL DEFAULT 0, seat TEXT NOT NULL, performance INTEGER NOT NULL DEFAULT 0, encounters INTEGER NOT NULL DEFAULT 1, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_merc_company_id INTEGER NOT NULL DEFAULT 0, catalogue TEXT NOT NULL DEFAULT 'chassis' CHECK (catalogue IN ('chassis','artillery')), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_loadout (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, slot_index INTEGER NOT NULL, part_key TEXT, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_combat_record (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, battle_id INTEGER NOT NULL DEFAULT 0, contract_id INTEGER NOT NULL DEFAULT 0, kills INTEGER NOT NULL DEFAULT 0, hits_taken INTEGER NOT NULL DEFAULT 0, armor_lost INTEGER NOT NULL DEFAULT 0, slots_damaged INTEGER NOT NULL DEFAULT 0, slots_destroyed INTEGER NOT NULL DEFAULT 0, destroyed INTEGER NOT NULL DEFAULT 0 CHECK (destroyed IN (0,1)), cause TEXT NOT NULL DEFAULT 'none', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS maintenance_entry (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL, day INTEGER NOT NULL DEFAULT 0, tech INTEGER NOT NULL DEFAULT 0, action TEXT NOT NULL DEFAULT 'repair', description TEXT NOT NULL DEFAULT '', battle_id INTEGER NOT NULL DEFAULT 0, cost INTEGER NOT NULL DEFAULT 0, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS hull_ownership_history (cid INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (ord >= 0), from_day INTEGER NOT NULL DEFAULT 0 CHECK (from_day BETWEEN 0 AND 4294967295), to_day INTEGER CHECK (to_day IS NULL OR (to_day BETWEEN from_day AND 4294967295)), acquisition_type TEXT NOT NULL DEFAULT 'initial', prior_owner_key TEXT NOT NULL DEFAULT '', UNIQUE (cid,ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS faction_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, faction_key TEXT NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS merc_company (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, cbills INTEGER NOT NULL DEFAULT 0, founded_day INTEGER NOT NULL DEFAULT 0, dissolved_day INTEGER NOT NULL DEFAULT 0, logo_key TEXT NOT NULL DEFAULT '', band_key TEXT NOT NULL, understrength_since INTEGER CHECK (understrength_since IS NULL OR (typeof(understrength_since)='integer' AND understrength_since BETWEEN 0 AND 4294967295)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS merc_company_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, merc_company_id INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, merc_company_id) REFERENCES merc_company(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS personage (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), id INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), role TEXT NOT NULL CHECK (role IN ('planetary_ruler','faction_leader','heir','family','intelligence_chief')), first_name TEXT NOT NULL CHECK (typeof(first_name)='text' AND length(first_name) > 0), last_name TEXT NOT NULL CHECK (typeof(last_name)='text' AND length(last_name) > 0), faction_key TEXT NOT NULL CHECK (typeof(faction_key)='text'), seat_planet_key TEXT NOT NULL CHECK (typeof(seat_planet_key)='text'), motives INTEGER NOT NULL CHECK (typeof(motives)='integer' AND motives BETWEEN 1 AND 511 AND (motives & 1) + ((motives >> 1) & 1) + ((motives >> 2) & 1) + ((motives >> 3) & 1) + ((motives >> 4) & 1) + ((motives >> 5) & 1) + ((motives >> 6) & 1) + ((motives >> 7) & 1) + ((motives >> 8) & 1) BETWEEN 2 AND 3), ambition INTEGER NOT NULL CHECK (typeof(ambition)='integer' AND ambition BETWEEN 0 AND 100), provenance TEXT NOT NULL CHECK (provenance IN ('procedural','canon','authored')), generator_version INTEGER NOT NULL CHECK (typeof(generator_version)='integer' AND generator_version IN (0,1)), key TEXT NOT NULL CHECK (typeof(key)='text'), family_key TEXT NOT NULL CHECK (typeof(family_key)='text'), CHECK ((provenance = 'procedural' AND key = '' AND family_key = '' AND generator_version = 1 AND role IN ('planetary_ruler','faction_leader')) OR (provenance IN ('canon','authored') AND key <> '' AND generator_version = 0)), PRIMARY KEY (cid, id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS personage_relation (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), from_id INTEGER NOT NULL CHECK (typeof(from_id)='integer' AND from_id BETWEEN 1 AND 4294967295), to_id INTEGER NOT NULL CHECK (typeof(to_id)='integer' AND to_id BETWEEN 1 AND 4294967295), kind TEXT NOT NULL CHECK (typeof(kind)='text' AND kind IN ('liege','kin','rival','ally','grudge')), weight INTEGER NOT NULL CHECK (typeof(weight)='integer' AND weight BETWEEN 1 AND 100), CHECK (from_id <> to_id), CHECK (kind NOT IN ('kin','rival','ally') OR from_id < to_id), PRIMARY KEY (cid, ord), UNIQUE (cid, from_id, to_id, kind), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, from_id) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid, to_id) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS artillery_formation (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (ord >= 0), id INTEGER NOT NULL CHECK (id BETWEEN 1 AND 4294967295), hull INTEGER NOT NULL CHECK (hull BETWEEN 1 AND 4294967295), acquisition_day INTEGER NOT NULL CHECK (acquisition_day BETWEEN 0 AND 4294967295), paid_price INTEGER NOT NULL CHECK (paid_price > 0), placement TEXT NOT NULL CHECK (placement IN ('hq_pool','company','freight','sold','destroyed','field_freight','field_return')), pool_hq INTEGER, company INTEGER, from_hq INTEGER, to_hq INTEGER, dispatch_day INTEGER, eta_day INTEGER, paid_cost INTEGER, quality TEXT NOT NULL DEFAULT 'c' CHECK(typeof(quality)='text' AND quality IN ('a','b','c','d','e','f')), armor INTEGER NOT NULL DEFAULT 100 CHECK(typeof(armor)='integer' AND armor BETWEEN 0 AND 100), last_maintenance INTEGER CHECK(last_maintenance IS NULL OR (typeof(last_maintenance)='integer' AND last_maintenance BETWEEN 0 AND 4294967295)), tech INTEGER CHECK(tech IS NULL OR (typeof(tech)='integer' AND tech BETWEEN 1 AND 4294967295)), FOREIGN KEY(cid,tech) REFERENCES person(cid,id) DEFERRABLE INITIALLY DEFERRED, PRIMARY KEY (cid,id), UNIQUE (cid,ord), UNIQUE (cid,hull), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,hull) REFERENCES hull_instance(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,pool_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,company) REFERENCES force(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,from_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,to_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK ((pool_hq IS NOT NULL) = (placement='hq_pool')), CHECK ((company IS NOT NULL) = (placement IN ('company','field_freight'))), CHECK ((from_hq IS NOT NULL) = (placement IN ('freight','field_freight'))), CHECK ((to_hq IS NOT NULL) = (placement IN ('freight','field_return'))), CHECK ((dispatch_day IS NOT NULL) = (placement IN ('freight','field_freight','field_return'))), CHECK ((eta_day IS NOT NULL) = (placement IN ('freight','field_freight','field_return'))), CHECK ((paid_cost IS NOT NULL) = (placement IN ('freight','field_freight','field_return'))), CHECK (pool_hq IS NULL OR pool_hq BETWEEN 1 AND 4294967295), CHECK (company IS NULL OR company BETWEEN 1 AND 4294967295), CHECK (from_hq IS NULL OR from_hq BETWEEN 1 AND 4294967295), CHECK (to_hq IS NULL OR to_hq BETWEEN 1 AND 4294967295), CHECK (placement!='freight' OR from_hq!=to_hq), CHECK (placement NOT IN ('freight','field_freight','field_return') OR (dispatch_day BETWEEN 0 AND 4294967295 AND eta_day > dispatch_day AND eta_day <= 4294967295 AND paid_cost >= 0)));
    \\CREATE TABLE IF NOT EXISTS artillery_crew (cid INTEGER NOT NULL CHECK(typeof(cid)='integer'), formation INTEGER NOT NULL CHECK(typeof(formation)='integer' AND formation BETWEEN 1 AND 4294967295), seat TEXT NOT NULL CHECK(typeof(seat)='text' AND seat IN ('commander','gunner','driver','loader')), person INTEGER CHECK(person IS NULL OR (typeof(person)='integer' AND person BETWEEN 1 AND 4294967295)), PRIMARY KEY(cid,formation,seat), UNIQUE(cid,person), FOREIGN KEY(cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,formation) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,person) REFERENCES person(cid,id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS artillery_slot (cid INTEGER NOT NULL CHECK(typeof(cid)='integer'), formation INTEGER NOT NULL CHECK(typeof(formation)='integer' AND formation BETWEEN 1 AND 4294967295), slot TEXT NOT NULL CHECK(typeof(slot)='text' AND slot IN ('chassis','main_gun','machine_gun_right_1','machine_gun_right_2','machine_gun_left_1','machine_gun_left_2','long_tom_bin_1','long_tom_bin_2','long_tom_bin_3','long_tom_bin_4','machine_gun_bin','communications','hitch')), condition TEXT NOT NULL CHECK(typeof(condition)='text' AND condition IN ('ok','damaged','destroyed','missing')), rounds INTEGER, PRIMARY KEY(cid,formation,slot), FOREIGN KEY(cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,formation) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK((rounds IS NOT NULL)=(slot IN ('long_tom_bin_1','long_tom_bin_2','long_tom_bin_3','long_tom_bin_4','machine_gun_bin'))), CHECK(rounds IS NULL OR (typeof(rounds)='integer' AND rounds >= 0 AND rounds <= CASE WHEN slot='machine_gun_bin' THEN 100 ELSE 5 END)), CHECK(condition NOT IN ('destroyed','missing') OR rounds IS NULL OR rounds=0));
    \\CREATE TABLE IF NOT EXISTS artillery_offer (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (ord >= 0), id INTEGER NOT NULL CHECK (id BETWEEN 1 AND 4294967295), hq INTEGER NOT NULL CHECK (hq BETWEEN 1 AND 4294967295), year INTEGER NOT NULL CHECK (year BETWEEN 1 AND 65535), month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12), available INTEGER NOT NULL CHECK (available IN (0,1)), PRIMARY KEY (cid,id), UNIQUE (cid,ord), UNIQUE (cid,hq), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED);
    \\CREATE TABLE IF NOT EXISTS artillery_battle (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, formation INTEGER NOT NULL CHECK(formation BETWEEN 1 AND 4294967295), hull INTEGER NOT NULL CHECK(hull BETWEEN 1 AND 4294967295), catalogue_key TEXT NOT NULL, catalogue_name TEXT NOT NULL, physical INTEGER NOT NULL CHECK(physical IN (0,1)), readiness TEXT CHECK(readiness IN ('not_attached','not_present','depot_job','armor','mechanic','chassis','main_gun','communications','maintenance','crew','ammunition')), no_fire TEXT NOT NULL CHECK(no_fire IN ('none','not_present','not_ready','no_line_units','enemy_forfeit','zero_enemy_power')), fire TEXT NOT NULL CHECK(fire IN ('not_fired','hit','miss')), damage TEXT NOT NULL CHECK(damage IN ('not_exposed','unhit','damaged','recoverable','permanently_destroyed','scuttled','recovered')), target INTEGER CHECK(target BETWEEN 2 AND 12), accuracy INTEGER CHECK(accuracy BETWEEN 2 AND 12), carrier_power INTEGER CHECK(carrier_power>=0), enemy_before INTEGER CHECK(enemy_before>=0), suppressed INTEGER NOT NULL CHECK(suppressed>=0), enemy_after INTEGER CHECK(enemy_after>=0), exposure_pct INTEGER CHECK(exposure_pct BETWEEN 0 AND 100), exposure_roll INTEGER CHECK(exposure_roll BETWEEN 0 AND 99), severity INTEGER CHECK(severity BETWEEN 2 AND 12), struck_slot TEXT, struck_seat TEXT, armor_before INTEGER NOT NULL CHECK(armor_before BETWEEN 0 AND 100), armor_after INTEGER NOT NULL CHECK(armor_after BETWEEN 0 AND armor_before), newly_wrecked INTEGER NOT NULL CHECK(newly_wrecked IN (0,1)), cause TEXT NOT NULL CHECK(cause IN ('none','cored','ammo','scrap')), recovery_roll INTEGER, recovery_target INTEGER, compensation INTEGER NOT NULL CHECK(compensation>=0), lt_before INTEGER NOT NULL CHECK(lt_before>=0), mg_before INTEGER NOT NULL CHECK(mg_before>=0), lt_after INTEGER NOT NULL CHECK(lt_after>=0), mg_after INTEGER NOT NULL CHECK(mg_after>=0), lt_fired INTEGER NOT NULL CHECK(lt_fired>=0), mg_fired INTEGER NOT NULL CHECK(mg_fired>=0), lt_lost INTEGER NOT NULL CHECK(lt_lost>=0), mg_lost INTEGER NOT NULL CHECK(mg_lost>=0), PRIMARY KEY(cid,report_ord), FOREIGN KEY(cid,report_ord) REFERENCES battle_report(cid,ord) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,formation) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,hull) REFERENCES hull_instance(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK((target IS NOT NULL)=(fire!='not_fired')), CHECK((accuracy IS NOT NULL)=(fire!='not_fired')), CHECK((carrier_power IS NOT NULL)=(fire!='not_fired')), CHECK((enemy_before IS NULL)=(enemy_after IS NULL)), CHECK((recovery_roll IS NULL)=(recovery_target IS NULL)));
    \\CREATE TABLE IF NOT EXISTS artillery_battle_seat (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, seat TEXT NOT NULL CHECK(seat IN ('commander','gunner','driver','loader')), person INTEGER CHECK(person BETWEEN 1 AND 4294967295), name TEXT NOT NULL, present INTEGER NOT NULL CHECK(present IN (0,1)), wound_severity INTEGER CHECK(wound_severity BETWEEN 1 AND 3), wound_location TEXT, wound_permanent INTEGER CHECK(wound_permanent IN (0,1)), fate TEXT NOT NULL CHECK(fate IN ('unhurt','kia','missing')), escape_roll INTEGER, escape_target INTEGER, xp INTEGER NOT NULL CHECK(xp IN (0,1)), PRIMARY KEY(cid,report_ord,seat), UNIQUE(cid,report_ord,person), FOREIGN KEY(cid,report_ord) REFERENCES artillery_battle(cid,report_ord) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,person) REFERENCES person(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK((wound_severity IS NULL)=(wound_location IS NULL)), CHECK((wound_severity IS NULL)=(wound_permanent IS NULL)), CHECK((escape_roll IS NULL)=(escape_target IS NULL)));
    \\CREATE TABLE IF NOT EXISTS artillery_battle_slot (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, slot TEXT NOT NULL, before_condition TEXT NOT NULL CHECK(before_condition IN ('ok','damaged','destroyed','missing')), after_condition TEXT NOT NULL CHECK(after_condition IN ('ok','damaged','destroyed','missing')), before_rounds INTEGER CHECK(before_rounds>=0), after_rounds INTEGER CHECK(after_rounds>=0), PRIMARY KEY(cid,report_ord,slot), FOREIGN KEY(cid,report_ord) REFERENCES artillery_battle(cid,report_ord) DEFERRABLE INITIALLY DEFERRED);
;

const tables = [_][]const u8{
    "meta",                "meta_text",              "rng",                "commander",             "person",                "person_skill",        "injury",                 "award",                    "ability",
    "unit",                "unit_slot",              "force",              "force_unit",            "force_child",           "stock",               "hq",                     "hq_facility",              "hq_project",
    "contract",            "txn",                    "loan",               "courier",               "policy",                "bay_job",             "candidate",              "hq_link",                  "unit_transfer",
    "supply_policy",       "stock_policy",           "faction_cooling",    "faction_standing",      "event_memory",          "listing",             "part_order",             "event_log",                "pending_event",
    "refit_plan",          "refit_op",               "rating_snapshot",    "battle_report",         "battle_report_hit",     "battle_report_ammo",  "battle_report_salvage",  "rng_stream",               "operation",
    "operation_task",      "operation_intervention", "battle_report_task", "actor",                 "world_state",           "rival",               "officer_arc",            "hull_instance",            "hull_loadout",
    "artillery_formation", "artillery_crew",         "artillery_slot",     "artillery_offer",       "hull_combat_record",    "maintenance_entry",   "hull_ownership_history", "faction_roster",           "merc_company",
    "merc_company_roster", "retired_hq",             "artillery_battle",   "artillery_battle_seat", "artillery_battle_slot", "battle_report_phase", "battle_in_progress",     "battle_in_progress_order", "battle_report_lever",
    "contract_situation",  "personage",              "personage_relation", "conflict",              "news_item",             "merc_hull_arrival",
};

// Indexes for per-campaign tables (A28/D31): cid filters on every load;
// composite shapes for the battle_report sub-tables whose loaders filter
// on (cid, report_ord).  CREATE INDEX IF NOT EXISTS is idempotent.
// Schema v72's indexes, frozen like `ddl_v72`.
const index_ddl_v72 =
    \\CREATE INDEX IF NOT EXISTS ix_artillery_battle_report ON artillery_battle(cid,report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_artillery_battle_seat_report ON artillery_battle_seat(cid,report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_artillery_battle_slot_report ON artillery_battle_slot(cid,report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_artillery_formation_cid ON artillery_formation(cid);
    \\CREATE INDEX IF NOT EXISTS ix_artillery_offer_cid ON artillery_offer(cid);
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
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_phase_report ON battle_report_phase(cid, report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_battle_report_lever_report ON battle_report_lever(cid, report_ord);
    \\CREATE INDEX IF NOT EXISTS ix_battle_in_progress_cid ON battle_in_progress(cid);
    \\CREATE INDEX IF NOT EXISTS ix_battle_in_progress_order_cid ON battle_in_progress_order(cid, contract_id);
    \\CREATE INDEX IF NOT EXISTS ix_actor_cid ON actor(cid);
    \\CREATE INDEX IF NOT EXISTS ix_world_state_cid ON world_state(cid);
    \\CREATE INDEX IF NOT EXISTS ix_contract_situation_cid ON contract_situation(cid);
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
    \\CREATE INDEX IF NOT EXISTS ix_personage_cid ON personage(cid);
    \\CREATE UNIQUE INDEX IF NOT EXISTS ux_personage_key ON personage(cid, key) WHERE key <> '';
    \\CREATE INDEX IF NOT EXISTS ix_personage_relation_cid ON personage_relation(cid);
;

/// The `personage` table of schema v71, frozen: the one table v71 and v72
/// define differently. Schema v71 has no `key` or `family_key` column, its
/// role CHECK admits only rulers and leaders, and its provenance CHECK only
/// `procedural` with `generator_version = 1`. `migrateV71ToV72` validates a
/// v71 store against it and rebuilds the table into the v72 DDL.
const personage_v71_ddl =
    \\CREATE TABLE IF NOT EXISTS personage (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), id INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), role TEXT NOT NULL CHECK (role IN ('planetary_ruler','faction_leader')), first_name TEXT NOT NULL CHECK (typeof(first_name)='text' AND length(first_name) > 0), last_name TEXT NOT NULL CHECK (typeof(last_name)='text' AND length(last_name) > 0), faction_key TEXT NOT NULL CHECK (typeof(faction_key)='text'), seat_planet_key TEXT NOT NULL CHECK (typeof(seat_planet_key)='text'), motives INTEGER NOT NULL CHECK (typeof(motives)='integer' AND motives BETWEEN 1 AND 511 AND (motives & 1) + ((motives >> 1) & 1) + ((motives >> 2) & 1) + ((motives >> 3) & 1) + ((motives >> 4) & 1) + ((motives >> 5) & 1) + ((motives >> 6) & 1) + ((motives >> 7) & 1) + ((motives >> 8) & 1) BETWEEN 2 AND 3), ambition INTEGER NOT NULL CHECK (typeof(ambition)='integer' AND ambition BETWEEN 0 AND 100), provenance TEXT NOT NULL CHECK (provenance IN ('procedural')), generator_version INTEGER NOT NULL CHECK (typeof(generator_version)='integer' AND generator_version = 1), PRIMARY KEY (cid, id), UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
;

/// The line of `text` (one statement per line) that defines `table`.
fn tableLine(comptime text: []const u8, comptime table: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const marker = "CREATE TABLE IF NOT EXISTS " ++ table ++ " (";
    const begin = std.mem.indexOf(u8, text, marker) orelse @compileError("no table " ++ table);
    const end = std.mem.indexOfScalarPos(u8, text, begin, '\n') orelse text.len;
    return text[begin..end];
}

/// Every table of schema v71: the frozen v72 DDL with the frozen v71
/// `personage` definition in place of v72's.
const ddl_v71: []const u8 = blk: {
    const v72 = tableLine(ddl_v72, "personage");
    const at = std.mem.indexOf(u8, ddl_v72, v72).?;
    break :blk ddl_v72[0..at] ++ personage_v71_ddl ++ ddl_v72[at + v72.len ..];
};

/// The columns schema v71's `personage` has, in order; the migration copies
/// exactly these.
const personage_v71_columns = "cid, ord, id, role, first_name, last_name, faction_key, seat_planet_key, motives, ambition, provenance, generator_version";

/// The schema v71 → v72 rebuild of `personage`, one statement per entry, in
/// order (`migrateV71ToV72`). Create–copy–drop–rename, not rename-first: a
/// rename of `personage` would rewrite `personage_relation`'s foreign keys
/// to the renamed table, which is then dropped. Every v71 row is procedural,
/// so each gains `key = ''` and `family_key = ''` and every other column is
/// copied as stored. Ends with the store and every campaign at v72.
const personage_v72_steps = [_][:0]const u8{
    std.fmt.comptimePrint("CREATE TABLE personage__v72{s}", .{tableLine(ddl_v72, "personage")["CREATE TABLE IF NOT EXISTS personage".len..]}),
    "INSERT INTO personage__v72 (" ++ personage_v71_columns ++ ", key, family_key) SELECT " ++ personage_v71_columns ++ ", '', '' FROM personage ORDER BY cid, ord",
    "DROP TABLE personage",
    "ALTER TABLE personage__v72 RENAME TO personage",
    "CREATE INDEX IF NOT EXISTS ix_personage_cid ON personage(cid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_personage_key ON personage(cid, key) WHERE key <> ''",
    "UPDATE campaign SET schema_version = 72",
    "UPDATE setting SET value = 72 WHERE key = 'schema_version'",
};

/// The schema v72 → v73 steps, in order (`migrateV72ToV73`): the new
/// `conflict` table and its index, a `next_conflict_id` of 1 for every
/// campaign (a v72 campaign has no conflict), and the store and every
/// campaign at v73. No existing table changes.
const conflict_v73_steps = [_][:0]const u8{
    std.fmt.comptimePrint("CREATE TABLE conflict{s}", .{conflict_v73_ddl["CREATE TABLE IF NOT EXISTS conflict".len..]}),
    conflict_v73_index_ddl,
    "INSERT INTO meta (cid, key, value) SELECT id, 'next_conflict_id', 1 FROM campaign",
    "UPDATE campaign SET schema_version = 73",
    "UPDATE setting SET value = 73 WHERE key = 'schema_version'",
};

/// The schema v73 → v74 rebuild of `conflict` and `contract`, one statement
/// per entry, in order (`migrateV73ToV74`). Each table is rebuilt
/// create–copy–drop–rename, rows in stored order: `conflict` first, so the
/// new `contract` foreign key names the rebuilt table. Every v73 conflict
/// is offensive, so each gains `family = 'offensive'`; every v73 contract
/// and offer has no backer, so each gains `conflict_id` NULL, the default
/// `side` and no `on_station_by` or `close_day`. Every other column is
/// copied as stored. Ends with the store and every campaign at v74.
const contract_conflict_v74_steps = [_][:0]const u8{
    std.fmt.comptimePrint("CREATE TABLE conflict__v74{s}", .{conflict_v74_ddl["CREATE TABLE IF NOT EXISTS conflict".len..]}),
    "INSERT INTO conflict__v74 (" ++ conflict_v73_columns ++ ", family) SELECT " ++ conflict_v73_columns ++ ", 'offensive' FROM conflict ORDER BY rowid",
    "DROP TABLE conflict",
    "ALTER TABLE conflict__v74 RENAME TO conflict",
    conflict_v73_index_ddl,
    std.fmt.comptimePrint("CREATE TABLE contract__v74{s}", .{contract_v74_ddl["CREATE TABLE IF NOT EXISTS contract".len..]}),
    "INSERT INTO contract__v74 (" ++ contract_v73_columns ++ ") SELECT " ++ contract_v73_columns ++ " FROM contract ORDER BY rowid",
    "DROP TABLE contract",
    "ALTER TABLE contract__v74 RENAME TO contract",
    "CREATE INDEX IF NOT EXISTS ix_contract_cid ON contract(cid)",
    "UPDATE campaign SET schema_version = 74",
    "UPDATE setting SET value = 74 WHERE key = 'schema_version'",
};

/// The schema v74 → v75 steps, in order (`migrateV74ToV75`): the new
/// `news_item` table and its index, a `next_news_id` of 1 for every
/// campaign (a v74 campaign has no news item), and the store and every
/// campaign at v75. No existing table changes.
const news_item_v75_steps = [_][:0]const u8{
    std.fmt.comptimePrint("CREATE TABLE news_item{s}", .{news_item_v75_ddl["CREATE TABLE IF NOT EXISTS news_item".len..]}),
    news_item_v75_index_ddl,
    "INSERT INTO meta (cid, key, value) SELECT id, 'next_news_id', 1 FROM campaign",
    "UPDATE campaign SET schema_version = 75",
    "UPDATE setting SET value = 75 WHERE key = 'schema_version'",
};

/// The schema v75 → v76 steps, in order (`migrateV75ToV76`). `merc_company`
/// is rebuilt create–copy–drop–rename, rows in stored order, so
/// `merc_company_roster`'s foreign key names the rebuilt table: each v75
/// company gains its faction's compatibility base
/// (`merc_company_v76_base_case`) and `ready_day = founded_day`, and every
/// other column is copied as stored. Then the new `merc_hull_arrival` table,
/// empty (a v75 purchase was fieldable at once), its index, and the store
/// and every campaign at v76.
const merc_company_v76_steps = [_][:0]const u8{
    std.fmt.comptimePrint("CREATE TABLE merc_company__v76{s}", .{merc_company_v76_ddl["CREATE TABLE IF NOT EXISTS merc_company".len..]}),
    std.fmt.comptimePrint("INSERT INTO merc_company__v76 ({s}, home_planet_key, ready_day) SELECT {s}, {s}, founded_day FROM merc_company ORDER BY rowid", .{ merc_company_v75_columns, merc_company_v75_columns, merc_company_v76_base_case }),
    "DROP TABLE merc_company",
    "ALTER TABLE merc_company__v76 RENAME TO merc_company",
    "CREATE INDEX IF NOT EXISTS ix_merc_company_cid ON merc_company(cid)",
    std.fmt.comptimePrint("CREATE TABLE merc_hull_arrival{s}", .{merc_hull_arrival_v76_ddl["CREATE TABLE IF NOT EXISTS merc_hull_arrival".len..]}),
    merc_hull_arrival_v76_index_ddl,
    "UPDATE campaign SET schema_version = 76",
    "UPDATE setting SET value = 76 WHERE key = 'schema_version'",
};

/// Migration steps as one script, for the `migrations` registry.
fn migrationScript(comptime steps: []const [:0]const u8) [:0]const u8 {
    var s: []const u8 = "";
    for (steps, 0..) |step, i| s = s ++ (if (i == 0) "" else "; ") ++ step;
    return std.fmt.comptimePrint("{s}", .{s});
}

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
        // v71 → v72: `personage` gains `key` and `family_key`, and its role
        // and provenance CHECKs widen. A v71 store holds only procedural
        // personages; each keeps every stored value and gains key = '' and
        // family_key = '' through a table rebuild (`migrateV71ToV72`).
        .{ .from = 71, .to = 72, .table = "personage", .column = "key", .sql = migrationScript(&personage_v72_steps) },
        // v72 → v73: the new `conflict` table, empty, and `next_conflict_id`
        // = 1 for every campaign; no existing table changes
        // (`migrateV72ToV73`).
        .{ .from = 72, .to = 73, .table = "conflict", .column = "", .sql = migrationScript(&conflict_v73_steps) },
        // v73 → v74: `conflict` gains `family` and its aggressor side
        // becomes optional for standing conflicts; `contract` gains each
        // position's backer. Both tables are rebuilt; every v73 conflict is
        // offensive and every v73 contract and offer has no backer
        // (`migrateV73ToV74`).
        .{ .from = 73, .to = 74, .table = "contract", .column = "conflict_id", .sql = migrationScript(&contract_conflict_v74_steps) },
        // v74 → v75: the new `news_item` table, empty, and `next_news_id`
        // = 1 for every campaign; no existing table changes
        // (`migrateV74ToV75`).
        .{ .from = 74, .to = 75, .table = "news_item", .column = "", .sql = migrationScript(&news_item_v75_steps) },
        // v75 → v76: `merc_company` gains each company's base and ready
        // day, rebuilt with its faction's compatibility base and its
        // founding day; the new `merc_hull_arrival` table, empty
        // (`migrateV75ToV76`).
        .{ .from = 75, .to = 76, .table = "merc_company", .column = "home_planet_key", .sql = migrationScript(&merc_company_v76_steps) },
    };

    pub fn open(path: [*:0]const u8) !Store {
        const db = try sqlite.Db.open(path);
        // fromDb takes ownership of db on success (A24); close on any failure before then.
        errdefer db.close();
        return try fromDb(db);
    }

    /// Classify before DDL: only a database with no application objects is new.
    /// Missing, duplicate or noninteger version metadata is CorruptStore.
    /// Source: engineering-contract.md rule 51 and ARCHITECTURE.md Persistence.
    fn readStoreVersion(db: sqlite.Db) !?u32 {
        const objects = try db.prepare("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
        defer objects.finalize();
        if (!try objects.next()) return error.CorruptStore;
        if (objects.int(0) == 0) return null;
        if (!try hasColumnRt(db, "setting", "key") or !try hasColumnRt(db, "setting", "value")) return error.CorruptStore;
        const st = try db.prepare("SELECT value, typeof(value)='integer' FROM setting WHERE key = 'schema_version'");
        defer st.finalize();
        if (!try st.next() or st.int(1) != 1) return error.CorruptStore;
        const version = std.math.cast(u32, st.int(0)) orelse return error.CorruptStore;
        if (version == 0 or try st.next()) return error.CorruptStore;
        return version;
    }

    /// Adopt the current schema, migrate a supported older one in place
    /// (`migrate`), or initialize a genuinely empty database. Unsupported
    /// formats and incomplete current schemas remain untouched. Caller owns
    /// db until success; initialization is one guarded transaction.
    /// Source: engineering-contract.md rules 50–51.
    pub fn fromDb(db: sqlite.Db) !Store {
        return fromDbFaulting(db, null);
    }

    /// `fromDb`, with the migration chain failing just before its step
    /// `fault_at` (below `migrationStepCount`) when non-null. Only tests
    /// pass a fault.
    fn fromDbFaulting(db: sqlite.Db, fault_at: ?usize) !Store {
        const version = try readStoreVersion(db);
        if (version) |stored| {
            if (stored < oldest_supported_schema_version) return error.StoreOlderThanGame;
            if (stored > schema_version) return error.StoreNewerThanGame;
            if (stored < schema_version) try migrate(db, stored, fault_at);
            try validateCurrentSchema(db);
        }
        try db.exec("PRAGMA foreign_keys = ON");
        const store: Store = .{ .db = db };
        if (version == null) {
            try db.exec("BEGIN");
            // best-effort: preserve the initialization error while undoing DDL.
            errdefer db.exec("ROLLBACK") catch {};
            try db.exec(ddl);
            try db.exec(index_ddl);
            try store.setSetting("schema_version", schema_version);
            try db.exec("COMMIT");
        }
        return store;
    }

    /// Required table/column names come directly from the executable DDL.
    /// This probes the read boundary without creating or healing any object.
    fn validateCurrentSchema(db: sqlite.Db) !void {
        return validateSchema(db, ddl);
    }

    /// A test's fault in the migration chain: counts the chain's steps and
    /// fails just before step `at`.
    const Fault = struct {
        at: ?usize,
        next: usize = 0,

        fn before(self: *Fault) error{SqliteError}!void {
            defer self.next += 1;
            if (self.at == self.next) return error.SqliteError;
        }
    };

    /// Steps of the chain from schema `from` a test fault may name: for a
    /// v71 store the v71 source check and each of `personage_v72_steps`;
    /// from v72 or older the v72 source check and each of
    /// `conflict_v73_steps`; from v73 or older the v73 source check and
    /// each of `contract_conflict_v74_steps`; from v74 or older the v74
    /// source check and each of `news_item_v75_steps`; then the v75 source
    /// check and each of `merc_company_v76_steps`; then the foreign-key
    /// check, the current schema check and COMMIT.
    fn migrationStepCount(from: u32) usize {
        const v71_part: usize = if (from == 71) 1 + personage_v72_steps.len else 0;
        const v72_part: usize = if (from <= 72) 1 + conflict_v73_steps.len else 0;
        const v73_part: usize = if (from <= 73) 1 + contract_conflict_v74_steps.len else 0;
        const v74_part: usize = if (from <= 74) 1 + news_item_v75_steps.len else 0;
        return v71_part + v72_part + v73_part + v74_part + 1 + merc_company_v76_steps.len + 3;
    }

    /// The migration chain (rule 51; docs/p5d-conflict-world-design.md §J):
    /// a store at a supported older format `from` reaches the current one
    /// through each migration in turn, all in one transaction with foreign
    /// keys off. A v71 store runs `migrateV71ToV72`, `migrateV72ToV73`,
    /// `migrateV73ToV74`, `migrateV74ToV75` and `migrateV75ToV76`; a v72
    /// store the last four; a v73 store the last three; a v74 store the
    /// last two; a v75 store only `migrateV75ToV76`. Each
    /// validates its frozen source format before its own statements, so a
    /// malformed or mixed-version store is `CorruptStore` before any change.
    /// The chain ends with an empty `PRAGMA foreign_key_check` (else
    /// `CorruptStore`) and the current schema check before COMMIT. Any
    /// failure rolls back and returns its error with the file still at
    /// `from`. `fault_at` (tests only) fails the chain just before that step
    /// (`migrationStepCount`).
    fn migrate(db: sqlite.Db, from: u32, fault_at: ?usize) !void {
        std.debug.assert(from >= oldest_supported_schema_version and from < schema_version);
        var fault: Fault = .{ .at = fault_at };
        try db.exec("PRAGMA foreign_keys = OFF");
        // best-effort: the connection's foreign keys come back on whatever failed.
        errdefer db.exec("PRAGMA foreign_keys = ON") catch {};
        try db.exec("BEGIN");
        // best-effort: preserve the migration error while undoing every step.
        errdefer db.exec("ROLLBACK") catch {};
        if (from == 71) try migrateV71ToV72(db, &fault);
        if (from <= 72) try migrateV72ToV73(db, &fault);
        if (from <= 73) try migrateV73ToV74(db, &fault);
        if (from <= 74) try migrateV74ToV75(db, &fault);
        try migrateV75ToV76(db, &fault);
        try fault.before();
        {
            const dangling = try db.prepare("PRAGMA foreign_key_check");
            defer dangling.finalize();
            if (try dangling.next()) return error.CorruptStore;
        }
        try fault.before();
        try validateCurrentSchema(db);
        try fault.before();
        try db.exec("COMMIT");
    }

    /// Every campaign of the store is at `version`; `CorruptStore` otherwise.
    fn requireCampaignsAt(db: sqlite.Db, comptime version: u32) !void {
        const off = try db.prepare("SELECT count(*) FROM campaign WHERE typeof(schema_version) <> 'integer' OR schema_version <> " ++ std.fmt.comptimePrint("{d}", .{version}));
        defer off.finalize();
        if (!try off.next() or off.int(0) != 0) return error.CorruptStore;
    }

    /// Schema v71 → v72, inside `migrate`'s transaction. Schema v71 differs
    /// from v72 only in `personage` (`personage_v71_ddl`). The source check:
    /// the store holds every v71 table and column (`ddl_v71`), its
    /// `personage` holds exactly the v71 columns, and every campaign is at
    /// v71; otherwise `CorruptStore`. Then `personage_v72_steps`. No gameplay
    /// value, ID, counter, relation or RNG stream changes, and no personage
    /// is added, so a migrated campaign loads and plays on as it would have
    /// under v71.
    fn migrateV71ToV72(db: sqlite.Db, fault: *Fault) !void {
        try fault.before();
        try validateSchema(db, ddl_v71);
        {
            const columns = try db.prepare("SELECT count(*) FROM pragma_table_info('personage')");
            defer columns.finalize();
            if (!try columns.next()) return error.CorruptStore;
            const v71_count = comptime std.mem.count(u8, personage_v71_columns, ",") + 1;
            if (columns.int(0) != v71_count) return error.CorruptStore;
        }
        try requireCampaignsAt(db, 71);
        for (personage_v72_steps) |step| {
            try fault.before();
            try db.exec(step);
        }
    }

    /// Schema v72 → v73, inside `migrate`'s transaction. Schema v73 adds the
    /// `conflict` table and the `next_conflict_id` counter and changes no
    /// existing table. The source check: the store holds every v72 table and
    /// column (`ddl_v72`), no `conflict` table and no `next_conflict_id`
    /// counter, and every campaign is at v72; otherwise `CorruptStore`. Then
    /// `conflict_v73_steps`. The reconstruction: a v72 campaign has no
    /// conflict, so each gets an empty conflict table and `next_conflict_id
    /// = 1`; every other value, ID, counter and RNG stream is unchanged, so
    /// a migrated campaign loads and plays on as it would have under v72.
    fn migrateV72ToV73(db: sqlite.Db, fault: *Fault) !void {
        try fault.before();
        try validateSchema(db, ddl_v72);
        {
            const present = try db.prepare("SELECT (SELECT count(*) FROM sqlite_master WHERE name = 'conflict') + (SELECT count(*) FROM meta WHERE key = 'next_conflict_id')");
            defer present.finalize();
            if (!try present.next() or present.int(0) != 0) return error.CorruptStore;
        }
        try requireCampaignsAt(db, 72);
        for (conflict_v73_steps) |step| {
            try fault.before();
            try db.exec(step);
        }
    }

    /// Schema v73 → v74, inside `migrate`'s transaction. Schema v74 differs
    /// from v73 only in `conflict` (`family`, and an optional aggressor
    /// side) and `contract` (each position's backer). The source check: the
    /// store holds every v73 table and column (`ddl_v73`), `conflict` holds
    /// exactly the v73 columns and no `family`, `contract` no
    /// `conflict_id`, and every campaign is at v73; otherwise
    /// `CorruptStore`. Then `contract_conflict_v74_steps`. The
    /// reconstruction: every v73 conflict is offensive, and every v73
    /// contract and offer has no backer (conflict_id `.none`, side
    /// `.defender`, no `on_station_by` or `close_day`); an offer without a
    /// backer leaves the board at the next month start
    /// (`contract_market.offerRetires`). No other value, ID, counter or RNG
    /// stream changes, so a migrated campaign loads and plays on as an
    /// ordinary v74 campaign holding those rows.
    fn migrateV73ToV74(db: sqlite.Db, fault: *Fault) !void {
        try fault.before();
        try validateSchema(db, ddl_v73);
        {
            const shape = try db.prepare("SELECT (SELECT count(*) FROM pragma_table_info('conflict')), (SELECT count(*) FROM pragma_table_info('conflict') WHERE name = 'family') + (SELECT count(*) FROM pragma_table_info('contract') WHERE name IN ('conflict_id', 'side', 'on_station_by', 'close_day'))");
            defer shape.finalize();
            if (!try shape.next()) return error.CorruptStore;
            const v73_count = comptime std.mem.count(u8, conflict_v73_columns, ",") + 1;
            if (shape.int(0) != v73_count or shape.int(1) != 0) return error.CorruptStore;
        }
        try requireCampaignsAt(db, 73);
        for (contract_conflict_v74_steps) |step| {
            try fault.before();
            try db.exec(step);
        }
    }

    /// Schema v74 → v75, inside `migrate`'s transaction. Schema v75 adds the
    /// `news_item` table and the `next_news_id` counter and changes no
    /// existing table. The source check: the store holds every v74 table and
    /// column (`ddl_v74`), no `news_item` table and no `next_news_id`
    /// counter, and every campaign is at v74; otherwise `CorruptStore`. Then
    /// `news_item_v75_steps`. The reconstruction: a v74 campaign has no news
    /// item, and reach is never back-filled (docs/p5d-conflict-world-design.md
    /// §K "Evaluation"), so each gets an empty news table and `next_news_id
    /// = 1`; every other value, ID, counter and RNG stream is unchanged, so
    /// a migrated campaign loads and plays on as an ordinary v75 campaign.
    fn migrateV74ToV75(db: sqlite.Db, fault: *Fault) !void {
        try fault.before();
        try validateSchema(db, ddl_v74);
        {
            const present = try db.prepare("SELECT (SELECT count(*) FROM sqlite_master WHERE name = 'news_item') + (SELECT count(*) FROM meta WHERE key = 'next_news_id')");
            defer present.finalize();
            if (!try present.next() or present.int(0) != 0) return error.CorruptStore;
        }
        try requireCampaignsAt(db, 74);
        for (news_item_v75_steps) |step| {
            try fault.before();
            try db.exec(step);
        }
    }

    /// Schema v75 → v76, inside `migrate`'s transaction. Schema v76 differs
    /// from v75 only in `merc_company` (`home_planet_key`, `ready_day`) and
    /// adds the `merc_hull_arrival` table. The source check: the store holds
    /// every v75 table and column (`ddl_v75`), `merc_company` holds exactly
    /// the v75 columns, there is no `merc_hull_arrival` table, every
    /// company's `faction_key` has a compatibility base
    /// (`merc_company_v76_factions`) and its `founded_day` is a campaign
    /// day, and every campaign is at v75; otherwise `CorruptStore`. Then
    /// `merc_company_v76_steps`. The reconstruction (rule 51,
    /// docs/p5d-conflict-world-design.md §L1): each company's base is
    /// `npc_base.compatibilityBase` of its faction, its `ready_day` its
    /// `founded_day`, and no hull is en route, because a v75 purchase was
    /// fieldable at once. It reads no seed and draws no RNG; every other
    /// value, ID, counter and RNG stream is unchanged, so a migrated campaign
    /// loads and plays on as an ordinary v76 campaign.
    fn migrateV75ToV76(db: sqlite.Db, fault: *Fault) !void {
        try fault.before();
        try validateSchema(db, ddl_v75);
        {
            const shape = try db.prepare(std.fmt.comptimePrint("SELECT (SELECT count(*) FROM pragma_table_info('merc_company')), (SELECT count(*) FROM sqlite_master WHERE name = 'merc_hull_arrival'), (SELECT count(*) FROM merc_company WHERE typeof(faction_key) <> 'text' OR faction_key NOT IN {s} OR typeof(founded_day) <> 'integer' OR founded_day NOT BETWEEN 0 AND 4294967295)", .{merc_company_v76_factions}));
            defer shape.finalize();
            if (!try shape.next()) return error.CorruptStore;
            const v75_count = comptime std.mem.count(u8, merc_company_v75_columns, ",") + 1;
            if (shape.int(0) != v75_count or shape.int(1) != 0 or shape.int(2) != 0) return error.CorruptStore;
        }
        try requireCampaignsAt(db, 75);
        for (merc_company_v76_steps) |step| {
            try fault.before();
            try db.exec(step);
        }
    }

    /// Every table and column that `definitions` (one CREATE TABLE per
    /// line) names exists; `CorruptStore` otherwise.
    fn validateSchema(db: sqlite.Db, definitions_text: []const u8) !void {
        var definitions = std.mem.splitScalar(u8, definitions_text, '\n');
        const marker = "CREATE TABLE IF NOT EXISTS ";
        while (definitions.next()) |line| {
            if (!std.mem.startsWith(u8, line, marker)) return error.CorruptStore;
            const rest = line[marker.len..];
            const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.CorruptStore;
            const table = rest[0..name_end];
            const present = try db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1");
            defer present.finalize();
            try present.bind(1, table);
            if (!try present.next()) return error.CorruptStore;
            const members = rest[name_end + 2 .. rest.len - 2];
            var start: usize = 0;
            var depth: usize = 0;
            var quoted = false;
            for (members, 0..) |byte, index| {
                if (byte == '\'') quoted = !quoted;
                if (quoted) continue;
                if (byte == '(') depth += 1;
                if (byte == ')') depth -= 1;
                if (byte == ',' and depth == 0) {
                    try validateSchemaMember(db, table, members[start..index]);
                    start = index + 1;
                }
            }
            try validateSchemaMember(db, table, members[start..]);
        }
    }

    fn validateSchemaMember(db: sqlite.Db, table: []const u8, member: []const u8) !void {
        const trimmed = std.mem.trim(u8, member, " ");
        const end = std.mem.indexOfAny(u8, trimmed, " (") orelse return error.CorruptStore;
        const name = trimmed[0..end];
        for ([_][]const u8{ "PRIMARY", "FOREIGN", "UNIQUE", "CHECK" }) |constraint| {
            if (std.mem.eql(u8, name, constraint)) return;
        }
        if (!try hasColumnRt(db, table, name)) return error.CorruptStore;
    }

    /// Rebuild every per-cid table to acquire the constraint set declared in
    /// `ddl`: containment foreign keys, UNIQUE keys, and CHECK constraints
    /// (rules 50, 51). Uses the SQLite ALTER TABLE procedure: create t__new
    /// with the final schema, copy every row with an explicit column list,
    /// drop t, rename t__new to t. Runs with foreign_keys OFF (set by the
    /// caller); CHECK constraints still apply on INSERT but are restricted to
    /// writer-guaranteed values. Does not run foreign_key_check: soft
    /// references remain the loader's job. Current-format adoption never invokes
    /// schema rebuilds.
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
            var create_buf: [8192:0]u8 = undefined;
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

    // Schema v59 zero closing days are disambiguated by the next interval in
    // each hull's persisted order. Final zero is open; successor start closes zero.
    fn rebuildOwnershipToV60(db: sqlite.Db) !void {
        const marker = "CREATE TABLE IF NOT EXISTS hull_ownership_history";
        const begin = std.mem.indexOf(u8, ddl, marker) orelse return error.SqliteError;
        const end = std.mem.indexOfScalarPos(u8, ddl, begin, '\n') orelse return error.SqliteError;
        var create_buf: [8192:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&create_buf, "CREATE TABLE hull_ownership_history__new{s}", .{ddl[begin + marker.len .. end]}) catch return error.SqliteError;
        try db.exec(&create_buf);
        const rows = try db.prepare(
            \\SELECT cid,hull_instance_id,ord,from_day,to_day,
            \\       typeof(cid)='integer' AND typeof(hull_instance_id)='integer'
            \\       AND typeof(ord)='integer' AND typeof(from_day)='integer'
            \\       AND typeof(to_day) IN ('integer','null')
            \\FROM hull_ownership_history ORDER BY cid,hull_instance_id,ord
        );
        defer rows.finalize();
        const successor = try db.prepare("SELECT from_day,typeof(from_day)='integer' FROM hull_ownership_history WHERE cid=?1 AND hull_instance_id=?2 AND ord>?3 ORDER BY ord LIMIT 1");
        defer successor.finalize();
        const insert = try db.prepare("INSERT INTO hull_ownership_history__new SELECT cid,hull_instance_id,ord,from_day,?4,acquisition_type,prior_owner_key FROM hull_ownership_history WHERE cid=?1 AND hull_instance_id=?2 AND ord=?3");
        defer insert.finalize();
        var previous_cid: i64 = 0;
        var previous_hull: i64 = 0;
        var previous_to: ?u32 = null;
        while (try rows.next()) {
            if (rows.int(5) != 1) return error.CorruptSave;
            const cid = rows.int(0);
            const hull = rows.int(1);
            const ord = try rows.intAs(u32, 2);
            _ = try toId(types.HullInstanceId, hull);
            const from = try rows.intAs(u32, 3);
            const legacy_to: ?u32 = if (rows.optInt(4)) |v| std.math.cast(u32, v) orelse return error.CorruptSave else null;
            try successor.bindAll(.{ cid, hull, ord });
            const next: ?u32 = if (try successor.next()) blk: {
                if (successor.int(1) != 1) return error.CorruptSave;
                break :blk try successor.intAs(u32, 0);
            } else null;
            successor.reset();
            const closing = if (legacy_to == null or legacy_to.? == 0) next else legacy_to;
            if (closing) |day| if (day < from) return error.CorruptSave;
            if (next) |day| if (day < from or closing == null or closing.? != day) return error.CorruptSave;
            if (cid == previous_cid and hull == previous_hull and (previous_to == null or previous_to.? != from)) return error.CorruptSave;
            try insert.bindAll(.{ cid, hull, ord, closing });
            try insert.run();
            previous_cid = cid;
            previous_hull = hull;
            previous_to = closing;
        }
        try db.exec("DROP TABLE hull_ownership_history");
        try db.exec("ALTER TABLE hull_ownership_history__new RENAME TO hull_ownership_history");
        try db.exec(index_ddl);
    }

    fn rebuildBattleReportToV59(db: sqlite.Db) !void {
        const marker = "CREATE TABLE IF NOT EXISTS battle_report (";
        const ddl_pos = std.mem.indexOf(u8, ddl, marker) orelse return error.SqliteError;
        const ddl_end = std.mem.indexOfScalarPos(u8, ddl, ddl_pos, '\n') orelse return error.SqliteError;
        const table_ddl = ddl[ddl_pos..ddl_end];
        const suffix = table_ddl["CREATE TABLE IF NOT EXISTS battle_report".len..];
        var create_buf: [8192:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&create_buf, "CREATE TABLE battle_report__new{s}", .{suffix}) catch return error.SqliteError;
        try db.exec(&create_buf);

        var cols_buf: [2048]u8 = undefined;
        var cols_len: usize = 0;
        const info = try db.prepare("PRAGMA table_info(battle_report)");
        defer info.finalize();
        var name_buf: [64]u8 = undefined;
        while (try info.next()) {
            var fba = std.heap.FixedBufferAllocator.init(&name_buf);
            const name = info.text(1, fba.allocator()) catch return error.SqliteError;
            if (cols_len > 0) {
                cols_buf[cols_len] = ',';
                cols_len += 1;
            }
            if (cols_len + name.len > cols_buf.len) return error.SqliteError;
            @memcpy(cols_buf[cols_len..][0..name.len], name);
            cols_len += name.len;
        }
        var insert_buf: [4096:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&insert_buf, "INSERT INTO battle_report__new ({s}) SELECT {s} FROM battle_report", .{ cols_buf[0..cols_len], cols_buf[0..cols_len] }) catch return error.SqliteError;
        try db.exec(&insert_buf);
        try db.exec("DROP TABLE battle_report");
        try db.exec("ALTER TABLE battle_report__new RENAME TO battle_report");
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
        if (gs.campaign_id != 0) try requireCampaignVersion(try self.loadVersion(gs.campaign_id));

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
        try artillery_store.save(self.db, gs, cid);
        try self.saveForce(gs, cid);
        try self.saveStock(cid, "outfit", 0, &gs.spare_parts);
        try self.saveHq(gs, cid);
        try self.saveRetiredHq(gs, cid);
        try self.saveContracts(gs, cid);
        try self.saveOperations(gs, cid);
        try self.saveContractSituations(gs, cid);
        try self.saveActors(gs, cid);
        try self.saveMercCompanies(gs, cid);
        try self.saveRivals(gs, cid);
        try self.saveOfficerArcs(gs, cid);
        try self.saveWorldStates(gs, cid);
        try self.saveFactionRosters(gs, cid);
        try self.saveMercCompanyRosters(gs, cid);
        try self.saveMercHullArrivals(gs, cid);
        try self.savePersonages(gs, cid);
        try self.savePersonageRelations(gs, cid);
        try self.saveConflicts(gs, cid);
        try self.saveNews(gs, cid);
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
        try self.saveBattleInProgress(gs, cid);
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
            .{ "day_index", gs.clock.day_index },                       .{ "year", gs.clock.date.year },
            .{ "month", gs.clock.date.month },                          .{ "day", gs.clock.date.day },
            .{ "funds", gs.funds },                                     .{ "reputation", gs.reputation },
            .{ "bankrupt", @as(i64, @intFromBool(gs.bankrupt)) },       .{ "auto_admit", @as(i64, @intFromBool(gs.auto_admit)) },
            .{ "difficulty", difficulty_int },                          .{ "share_profit_bp", @as(i64, gs.share_profit_bp) },
            .{ "stat_battles_won", gs.stats.battles_won },              .{ "stat_battles_drawn", gs.stats.battles_drawn },
            .{ "stat_battles_lost", gs.stats.battles_lost },            .{ "stat_hulls_lost", gs.stats.hulls_lost },
            .{ "stat_hulls_salvaged", gs.stats.hulls_salvaged },        .{ "stat_people_kia", gs.stats.people_kia },
            .{ "stat_enemy_bv", enemy_bv_i64 },                         .{ "next_person_id", gs.next_person_id },
            .{ "next_unit_id", gs.next_unit_id },                       .{ "next_force_id", gs.next_force_id },
            .{ "next_hq_id", gs.next_hq_id },                           .{ "next_contract_id", gs.next_contract_id },
            .{ "retired_hq_count", @intCast(gs.retired_hqs.count()) },  .{ "next_battle_id", gs.next_battle_id },
            .{ "rng_seed", @as(i64, @bitCast(gs.rng.seed)) },           .{ "next_event_id", gs.event_queue.next_id },
            .{ "next_listing_id", gs.next_listing_id },                 .{ "next_candidate_id", gs.next_candidate_id },
            .{ "next_loan_id", gs.next_loan_id },                       .{ "next_operation_id", gs.next_operation_id },
            .{ "next_actor_id", gs.next_actor_id },                     .{ "next_rival_id", gs.next_rival_id },
            .{ "next_officer_arc_id", gs.next_officer_arc_id },         .{ "next_artillery_formation_id", gs.next_artillery_formation_id },
            .{ "next_artillery_offer_id", gs.next_artillery_offer_id }, .{ "next_hull_instance_id", gs.next_hull_instance_id },
            .{ "next_merc_company_id", gs.next_merc_company_id },       .{ "next_personage_id", gs.next_personage_id },
            .{ "next_conflict_id", gs.next_conflict_id },               .{ "next_news_id", gs.next_news_id },
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
        const st = try self.db.prepare("INSERT INTO hull_instance (cid,ord,id,base_key,name,nickname,status,intro_year,pre_campaign,owner_type,owner_faction_key,owner_merc_company_id,catalogue) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)");
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
            try st.bindAll(.{ cid, ord, @intFromEnum(h.id), h.base_key, h.name, h.nickname, @tagName(h.status), @as(i64, h.intro_year), @as(i64, @intFromBool(h.pre_campaign)), owner_type_tag, owner_faction_key, owner_merc_company_id, h.catalogue });
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
                e.to_day,
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

    fn saveRetiredHq(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO retired_hq VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        for (gs.retired_hqs.values(), 0..) |h, ord| {
            try st.bindAll(.{ cid, @as(i64, @intCast(ord)), @intFromEnum(h.id), h.name, h.planet_key, @tagName(h.tier), h.sold_day });
            try st.run();
        }
    }

    // Contracts and offers.
    fn saveContracts(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO contract VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,?51,?52,?53,?54)");
        defer st.finalize();
        var ord: i64 = 0;
        var it = gs.contracts.iterator();
        while (it.next()) |entry| : (ord += 1) try saveContract(st, cid, false, ord, entry.value_ptr);
        for (gs.contract_offers.items, 0..) |*o, i| try saveContract(st, cid, true, @intCast(i), o);
    }

    fn saveOperations(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO operation VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)");
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
                    @as(i64, @intFromBool(op.reserve_committed)),
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
        const st = try self.db.prepare("SELECT contract_id, id, template_key, state, outcome, opened_day, resolved_day, committed_day, intent, tempo, reserve_committed, typeof(reserve_committed)='integer' FROM operation WHERE cid = ?1 ORDER BY contract_id, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const contract_id = try toId(types.ContractId, st.int(0));
            const c = gs.contracts.getPtr(contract_id) orelse return error.CorruptSave;
            // Only a combat operation fights a battle, so only one can have
            // committed its reserve.
            const reserve = st.int(10);
            if (st.int(11) != 1 or (reserve != 0 and reserve != 1)) return error.CorruptSave;
            const template_key = try st.text(2, alloc);
            if (reserve == 1) {
                const t = operation_mod.findTemplate(template_key) orelse return error.CorruptSave;
                if (!t.combat) return error.CorruptSave;
            }
            const op: operation_mod.Operation = .{
                .id = try toId(types.OperationId, st.int(1)),
                .template_key = template_key,
                .state = st.enumValue(operation_mod.OperationState, 3) orelse return error.CorruptSave,
                .outcome = st.enumValue(operation_mod.OutcomeBand, 4) orelse return error.CorruptSave,
                .opened_day = try st.intAs(u32, 5),
                .resolved_day = try optU32(st.optInt(6)),
                .committed_day = try optU32(st.optInt(7)),
                .intent = st.enumValue(operation_mod.Intent, 8) orelse return error.CorruptSave,
                .tempo = st.enumValue(operation_mod.TempoPosture, 9) orelse return error.CorruptSave,
                .reserve_committed = reserve == 1,
            };
            try c.operations.append(alloc, op);
        }
        // The stored counter must be beyond every owned operation identity.
        {
            var max: u32 = 0;
            var cit = gs.contracts.iterator();
            while (cit.next()) |entry| {
                for (entry.value_ptr.operations.items) |op| {
                    max = @max(max, @intFromEnum(op.id));
                }
            }
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            if (gs.next_operation_id <= max) return error.CorruptSave;
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

    /// Each contract's situation records, in the order raised.
    fn saveContractSituations(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO contract_situation VALUES (?1,?2,?3,?4,?5,?6,?7)");
        defer st.finalize();
        var it = gs.contracts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr;
            for (c.situations.items, 0..) |r, ord| {
                try st.bindAll(.{ cid, @intFromEnum(c.id), @as(i64, @intCast(ord)), r.key, @as(i64, r.day), @intFromEnum(r.actor), if (r.choice) |ch| @as(?i64, ch) else null });
                try st.run();
            }
        }
    }

    /// Situation records back onto their contracts (after `loadActors`).
    /// Fails closed on a record whose contract, situation or owner is
    /// unknown, whose situation belongs to another arc, whose owner is not
    /// the contract's actor of that archetype, that repeats a situation,
    /// that is out of order, dated after today, or whose choice is not an
    /// option.
    fn loadContractSituations(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT contract, ord, situation, day, actor, choice, typeof(situation)='text' AND typeof(contract)='integer' AND typeof(ord)='integer' AND typeof(day)='integer' AND typeof(actor)='integer' AND (choice IS NULL OR typeof(choice)='integer') FROM contract_situation WHERE cid = ?1 ORDER BY contract, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(6) != 1) return error.CorruptSave;
            const c = gs.contracts.getPtr(try toId(types.ContractId, st.int(0))) orelse return error.CorruptSave;
            if (st.int(1) != @as(i64, @intCast(c.situations.items.len))) return error.CorruptSave;
            const s = situation_mod.find(try st.text(2, alloc)) orelse return error.CorruptSave;
            if (!std.mem.eql(u8, s.arc, c.arc_key)) return error.CorruptSave;
            for (c.situations.items) |r| if (std.mem.eql(u8, r.key, s.key)) return error.CorruptSave;
            const day = try st.intAs(u32, 3);
            if (day > gs.clock.day_index) return error.CorruptSave;
            const actor_id = try toId(types.ActorId, st.int(4));
            const owner = gs.actor(actor_id) orelse return error.CorruptSave;
            if (owner.contract != c.id or !std.mem.eql(u8, owner.archetype_key, s.owner)) return error.CorruptSave;
            const choice: ?u8 = if (st.optInt(5)) |raw| blk: {
                const ch = try fit(u8, raw);
                if (ch >= s.options.len) return error.CorruptSave;
                break :blk ch;
            } else null;
            try c.situations.append(alloc, .{ .key = s.key, .day = day, .actor = actor_id, .choice = choice });
        }
    }

    // P4i: save and load persistent actors.
    fn saveActors(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO actor VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)");
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
                flagBits(actor_mod.ActorFlag, a.flags),
            });
            try st.run();
        }
    }

    fn loadActors(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, archetype_key, first_name, last_name, faction_key, side, contract, trust, debt, respect, hostility, last_cause, last_cause_day, recurring, flags, typeof(flags)='integer' FROM actor WHERE cid = ?1 ORDER BY ord");
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
            const flags = if (st.int(15) == 1) try flagSet(actor_mod.ActorFlag, st.int(14)) else return error.CorruptSave;
            if (actor_rules.flagsConflict(flags)) return error.CorruptSave;
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
                .flags = flags,
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
        // The stored counter must be beyond every owned actor identity.
        {
            var max: u32 = 0;
            var it = gs.actors.iterator();
            while (it.next()) |entry| max = @max(max, @intFromEnum(entry.key_ptr.*));
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            if (gs.next_actor_id <= max) return error.CorruptSave;
        }
    }

    // P4h.4: save and load per-world state.
    fn saveWorldStates(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO world_state VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
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
                flagBits(world_state_dom.WorldFlag, ws.flags),
            });
            try st.run();
        }
    }

    fn loadWorldStates(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT planet_key, security, civilian_support, infrastructure_strain, employer_control, enemy_influence, last_cause, last_cause_day, flags, typeof(flags)='integer' FROM world_state WHERE cid = ?1 ORDER BY ord");
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
            const flags = if (st.int(9) == 1) try flagSet(world_state_dom.WorldFlag, st.int(8)) else return error.CorruptSave;
            if (world_state_rules.flagsConflict(flags)) return error.CorruptSave;
            const ws: world_state_dom.WorldState = .{
                .security = security,
                .civilian_support = civilian_support,
                .infrastructure_strain = infrastructure_strain,
                .employer_control = employer_control,
                .enemy_influence = enemy_influence,
                .last_cause = try st.text(6, alloc),
                .last_cause_day = try st.intAs(u32, 7),
                .flags = flags,
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
        // The stored counter must be beyond every owned rival identity.
        {
            var max: u32 = 0;
            var it2 = gs.rivals.iterator();
            while (it2.next()) |entry| max = @max(max, @intFromEnum(entry.key_ptr.*));
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            if (gs.next_rival_id <= max) return error.CorruptSave;
        }
    }

    // P3e entity split: save and load persistent world merc companies.
    fn saveMercCompanies(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO merc_company VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)");
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
                mc.band_key,
                mc.understrength_since,
                mc.home_planet_key,
                @as(i64, mc.ready_day),
            });
            try st.run();
        }
    }

    /// Save `merc_hull_arrivals`: one row per en-route hull, in map order.
    fn saveMercHullArrivals(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO merc_hull_arrival VALUES (?1,?2,?3,?4)");
        defer st.finalize();
        for (gs.merc_hull_arrivals.keys(), gs.merc_hull_arrivals.values(), 0..) |hull_id, arrive_day, ord| {
            try st.bindAll(.{ cid, @as(i64, @intCast(ord)), @as(i64, @intFromEnum(hull_id)), @as(i64, arrive_day) });
            try st.run();
        }
    }

    /// Decode each arrival row exactly, in stored order: a value not stored
    /// as an integer or out of range, a hull id of none, a duplicate hull or
    /// an ordinal other than the row's position (`saveMercHullArrivals`
    /// writes 0, 1, 2, …) is `CorruptSave` (rule 47). `npc_base.validate`
    /// then checks each hull against its owner.
    fn loadMercHullArrivals(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT ord, hull_instance_id, arrive_day, typeof(ord)='integer' AND typeof(hull_instance_id)='integer' AND typeof(arrive_day)='integer' FROM merc_hull_arrival WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        var expected_ord: i64 = 0;
        while (try st.next()) : (expected_ord += 1) {
            // SQLite's integer reader would coerce text or a fraction.
            if (st.int(3) != 1) return error.CorruptSave;
            if (st.int(0) != expected_ord) return error.CorruptSave;
            const hull_id = try toId(types.HullInstanceId, st.int(1));
            if (hull_id == .none) return error.CorruptSave;
            const arrive_day = try st.intAs(u32, 2);
            const gop = try gs.merc_hull_arrivals.getOrPut(alloc, hull_id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = arrive_day;
        }
    }

    fn loadMercCompanies(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine, cbills, founded_day, dissolved_day, logo_key, band_key, understrength_since, typeof(understrength_since) IN ('null','integer'), home_planet_key, ready_day, typeof(home_planet_key)='text' AND typeof(ready_day)='integer' FROM merc_company WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const archetype_key = try st.text(1, alloc);
            if (rival_mod.find(archetype_key) == null) return error.CorruptSave;
            // An unknown band is corruption, never a default band (rule 47).
            const band = merc_band.find(try st.text(12, alloc)) orelse return error.CorruptSave;
            const side_str = try st.text(6, alloc);
            const side = std.meta.stringToEnum(merc_company_mod.FactionSide, side_str) orelse return error.CorruptSave;
            const doctrine_str = try st.text(7, alloc);
            const doctrine = std.meta.stringToEnum(merc_company_mod.RivalDoctrine, doctrine_str) orelse return error.CorruptSave;
            const unit_name = try st.text(4, alloc);
            if (!@import("../sim/table.zig").markupSafe(unit_name)) return error.CorruptSave;
            // A negative, non-integer or future understrength day is
            // corruption (rule 47; docs/p5d-conflict-world-design.md §J).
            if (st.int(14) != 1) return error.CorruptSave;
            const understrength_since: ?u32 = if (st.optInt(13)) |day| std.math.cast(u32, day) orelse return error.CorruptSave else null;
            if (understrength_since) |day| if (day > gs.clock.day_index) return error.CorruptSave;
            // The base is held in static catalog memory; an unknown world is
            // corruption, never a default (rule 47). The base must be stored
            // as text and the ready day as an integer, because SQLite's
            // readers would convert a blob base or a text or fractional day.
            if (st.int(17) != 1) return error.CorruptSave;
            const home = planet_mod.find(try st.text(15, alloc)) orelse return error.CorruptSave;
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
                .band_key = band.key,
                .understrength_since = understrength_since,
                .home_planet_key = home.key,
                .ready_day = try st.intAs(u32, 16),
            };
            const gop = try gs.merc_companies.getOrPut(alloc, mc.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = mc;
        }
    }

    // World personages (docs/p5d-conflict-world-design.md §B, §J).
    fn savePersonages(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO personage VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)");
        defer st.finalize();
        for (gs.personages.values(), 0..) |p, ord| {
            try st.bindAll(.{
                cid,
                @as(i64, @intCast(ord)),
                @as(i64, @intFromEnum(p.id)),
                @tagName(p.role),
                p.first_name,
                p.last_name,
                p.faction_key,
                p.seat_planet_key,
                @as(i64, personage_mod.motivesMask(p.motives)),
                @as(i64, p.ambition),
                @tagName(p.provenance),
                @as(i64, p.generator_version),
                p.key,
                p.family_key,
            });
            try st.run();
        }
    }

    /// Decode each row exactly; an unknown enum (matched on the column's full
    /// bytes, so a valid tag before an embedded NUL is unknown), a non-integer or
    /// out-of-range value, a duplicate id, or an ordinal other than the
    /// row's position (`savePersonages` writes 0, 1, 2, …) is `CorruptSave`
    /// (rule 47). `personages.validate` then checks keys, data rows, seats
    /// and coverage. A title is not stored: it is read from the data row by
    /// key.
    fn loadPersonages(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT id, role, first_name, last_name, faction_key, seat_planet_key, motives, ambition, provenance, generator_version, typeof(ord)='integer' AND typeof(id)='integer' AND typeof(motives)='integer' AND typeof(ambition)='integer' AND typeof(generator_version)='integer' AND typeof(role)='text' AND typeof(first_name)='text' AND typeof(last_name)='text' AND typeof(faction_key)='text' AND typeof(seat_planet_key)='text' AND typeof(provenance)='text' AND typeof(key)='text' AND typeof(family_key)='text', ord, key, family_key FROM personage WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(10) != 1) return error.CorruptSave;
            if (st.int(11) != @as(i64, @intCast(gs.personages.count()))) return error.CorruptSave;
            const p: personage_mod.Personage = .{
                .id = try toId(types.PersonageId, st.int(0)),
                .role = std.meta.stringToEnum(personage_mod.Role, try st.text(1, alloc)) orelse return error.CorruptSave,
                .first_name = try st.text(2, alloc),
                .last_name = try st.text(3, alloc),
                .faction_key = try st.text(4, alloc),
                .seat_planet_key = try st.text(5, alloc),
                .motives = personage_mod.motivesFromMask(try st.intAs(u16, 6)) orelse return error.CorruptSave,
                .ambition = try st.intAs(u8, 7),
                .provenance = std.meta.stringToEnum(personage_mod.Provenance, try st.text(8, alloc)) orelse return error.CorruptSave,
                .generator_version = try st.intAs(u16, 9),
                .key = try st.text(12, alloc),
                .family_key = try st.text(13, alloc),
            };
            const gop = try gs.personages.getOrPut(alloc, p.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = p;
        }
    }

    // Relations between personages (docs/p5d-conflict-world-design.md §B, §J).
    fn savePersonageRelations(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO personage_relation VALUES (?1,?2,?3,?4,?5,?6)");
        defer st.finalize();
        for (gs.personage_relations.items, 0..) |rel, ord| {
            try st.bindAll(.{
                cid,
                @as(i64, @intCast(ord)),
                @as(i64, @intFromEnum(rel.from)),
                @as(i64, @intFromEnum(rel.to)),
                @tagName(rel.kind),
                @as(i64, rel.weight),
            });
            try st.run();
        }
    }

    /// Decode each row exactly, as `loadPersonages` does: an unknown kind
    /// (matched on the column's full bytes), a non-integer or out-of-range
    /// value, or an ordinal other than the row's position
    /// (`savePersonageRelations` writes 0, 1, 2, …) is `CorruptSave` (rule
    /// 47). `personage_relations.validate` then checks endpoints, shape and
    /// lieges.
    fn loadPersonageRelations(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT from_id, to_id, kind, weight, typeof(ord)='integer' AND typeof(from_id)='integer' AND typeof(to_id)='integer' AND typeof(weight)='integer' AND typeof(kind)='text', ord FROM personage_relation WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(4) != 1) return error.CorruptSave;
            if (st.int(5) != @as(i64, @intCast(gs.personage_relations.items.len))) return error.CorruptSave;
            const rel: personage_mod.Relation = .{
                .from = try toId(types.PersonageId, st.int(0)),
                .to = try toId(types.PersonageId, st.int(1)),
                .kind = std.meta.stringToEnum(personage_mod.RelationKind, try st.text(2, alloc)) orelse return error.CorruptSave,
                .weight = try st.intAs(u8, 3),
            };
            try gs.personage_relations.append(alloc, rel);
        }
    }

    // World conflicts (docs/p5d-conflict-world-design.md §C, §J).
    fn saveConflicts(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO conflict VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)");
        defer st.finalize();
        for (gs.conflicts.values(), 0..) |c, ord| {
            const strike = c.strike_force;
            try st.bindAll(.{
                cid,
                @as(i64, @intCast(ord)),
                @as(i64, @intFromEnum(c.id)),
                c.template_key,
                c.planet_key,
                if (c.aggressor) |a| @as(?[]const u8, a.faction_key) else null,
                if (c.aggressor) |a| @as(?i64, @intFromEnum(a.personage)) else null,
                c.defender.faction_key,
                @as(i64, @intFromEnum(c.defender.personage)),
                @as(i64, @intFromEnum(c.instigator)),
                c.staging_planet_key,
                @as(i64, c.opened_day),
                @as(i64, c.discovery_day),
                if (c.strike_day) |d| @as(?i64, d) else null,
                if (c.expires_day) |d| @as(?i64, d) else null,
                @as(i64, c.local_force.lances),
                @tagName(c.local_force.quality),
                c.local_force.lance_bv,
                @as(i64, c.local_force.lance_tons),
                if (strike) |f| @as(?i64, f.lances) else null,
                if (strike) |f| @as(?[]const u8, @tagName(f.quality)) else null,
                if (strike) |f| @as(?i64, f.lance_bv) else null,
                if (strike) |f| @as(?i64, f.lance_tons) else null,
                if (c.outcome) |o| @as(?[]const u8, @tagName(o)) else null,
                @tagName(c.family),
            });
            try st.run();
        }
    }

    /// Decode each row exactly, as `loadPersonages` does: an unknown enum
    /// (matched on the column's full bytes), a value of the wrong type or
    /// out of range, a duplicate id, or an ordinal other than the row's
    /// position (`saveConflicts` writes 0, 1, 2, …) is `CorruptSave` (rule
    /// 47). The aggressor side's columns are each NULL or of their type,
    /// and its parts are present or absent together: the aggressor's
    /// faction and personage, and the strike force's four columns.
    /// `politics.validate` then checks the family's shape, id order,
    /// references, the timeline, staging, status and caps.
    fn loadConflicts(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare(
            \\SELECT id, template_key, planet_key, aggressor_faction, aggressor_personage, defender_faction, defender_personage, instigator, staging_planet_key,
            \\  opened_day, discovery_day, strike_day, expires_day,
            \\  local_lances, local_quality, local_lance_bv, local_lance_tons, strike_lances, strike_quality, strike_lance_bv, strike_lance_tons, outcome, family,
            \\  typeof(ord)='integer' AND typeof(id)='integer' AND typeof(template_key)='text' AND typeof(planet_key)='text'
            \\  AND typeof(aggressor_faction) IN ('text','null') AND typeof(aggressor_personage) IN ('integer','null') AND typeof(defender_faction)='text'
            \\  AND typeof(defender_personage)='integer' AND typeof(instigator)='integer' AND typeof(staging_planet_key) IN ('text','null')
            \\  AND typeof(opened_day)='integer' AND typeof(discovery_day)='integer' AND typeof(strike_day) IN ('integer','null') AND typeof(expires_day) IN ('integer','null')
            \\  AND typeof(local_lances)='integer' AND typeof(local_quality)='text' AND typeof(local_lance_bv)='integer' AND typeof(local_lance_tons)='integer'
            \\  AND typeof(strike_lances) IN ('integer','null') AND typeof(strike_quality) IN ('text','null') AND typeof(strike_lance_bv) IN ('integer','null') AND typeof(strike_lance_tons) IN ('integer','null')
            \\  AND typeof(outcome) IN ('text','null') AND typeof(family)='text'
            \\  AND (aggressor_faction IS NULL) = (aggressor_personage IS NULL)
            \\  AND (strike_lances IS NULL) = (strike_quality IS NULL) AND (strike_lances IS NULL) = (strike_lance_bv IS NULL) AND (strike_lances IS NULL) = (strike_lance_tons IS NULL),
            \\  ord
            \\FROM conflict WHERE cid = ?1 ORDER BY ord
        );
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(23) != 1) return error.CorruptSave;
            if (st.int(24) != @as(i64, @intCast(gs.conflicts.count()))) return error.CorruptSave;
            const c: conflict_mod.Conflict = .{
                .id = try toId(types.ConflictId, st.int(0)),
                .family = std.meta.stringToEnum(conflict_mod.Family, try st.text(22, alloc)) orelse return error.CorruptSave,
                .template_key = try st.text(1, alloc),
                .planet_key = try st.text(2, alloc),
                .aggressor = if (st.isNull(3)) null else .{ .faction_key = try st.text(3, alloc), .personage = try toId(types.PersonageId, st.int(4)) },
                .defender = .{ .faction_key = try st.text(5, alloc), .personage = try toId(types.PersonageId, st.int(6)) },
                .instigator = try toId(types.PersonageId, st.int(7)),
                .staging_planet_key = if (st.isNull(8)) null else try st.text(8, alloc),
                .opened_day = try st.intAs(u32, 9),
                .discovery_day = try st.intAs(u32, 10),
                .strike_day = try optU32(st.optInt(11)),
                .expires_day = try optU32(st.optInt(12)),
                .local_force = try conflictForce(st, 13, alloc),
                .strike_force = if (st.isNull(17)) null else try conflictForce(st, 17, alloc),
                .outcome = if (st.isNull(21)) null else std.meta.stringToEnum(conflict_mod.Outcome, try st.text(21, alloc)) orelse return error.CorruptSave,
            };
            const gop = try gs.conflicts.getOrPut(alloc, c.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = c;
        }
    }

    // News items (docs/p5d-conflict-world-design.md §K "News").
    fn saveNews(self: Store, gs: *GameState, cid: i64) !void {
        const st = try self.db.prepare("INSERT INTO news_item VALUES (?1,?2,?3,?4,?5,?6,?7,?8)");
        defer st.finalize();
        for (gs.news_items.values(), 0..) |n, ord| {
            try st.bindAll(.{
                cid,
                @as(i64, @intCast(ord)),
                @as(i64, @intFromEnum(n.id)),
                @tagName(n.kind),
                @as(i64, @intFromEnum(n.conflict)),
                @tagName(n.reach_from),
                n.reach_from_planet_key,
                n.text,
            });
            try st.run();
        }
    }

    /// Decode each row exactly, as `loadConflicts` does: an unknown kind or
    /// presence kind (matched on the column's full bytes), a value of the
    /// wrong type or out of range, a duplicate id, or an ordinal other than
    /// the row's position (`saveNews` writes 0, 1, 2, …) is `CorruptSave`
    /// (rule 47). `news.validate` then checks ids, references, days, reach
    /// and text.
    fn loadNews(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare(
            \\SELECT id, kind, conflict_id, reach_from, reach_from_planet_key, text,
            \\  typeof(ord)='integer' AND typeof(id)='integer' AND typeof(kind)='text' AND typeof(conflict_id)='integer'
            \\  AND typeof(reach_from)='text' AND typeof(reach_from_planet_key)='text' AND typeof(text)='text',
            \\  ord
            \\FROM news_item WHERE cid = ?1 ORDER BY ord
        );
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(6) != 1) return error.CorruptSave;
            if (st.int(7) != @as(i64, @intCast(gs.news_items.count()))) return error.CorruptSave;
            const n: news_mod.NewsItem = .{
                .id = try toId(types.NewsId, st.int(0)),
                .kind = std.meta.stringToEnum(news_mod.NewsKind, try st.text(1, alloc)) orelse return error.CorruptSave,
                .conflict = try toId(types.ConflictId, st.int(2)),
                .reach_from = std.meta.stringToEnum(news_mod.PresenceKind, try st.text(3, alloc)) orelse return error.CorruptSave,
                .reach_from_planet_key = try st.text(4, alloc),
                .text = try st.text(5, alloc),
            };
            const gop = try gs.news_items.getOrPut(alloc, n.id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = n;
        }
    }

    /// One conflict force from its four columns at `first`: lances, quality
    /// (by its full bytes), lance BV and lance tons.
    fn conflictForce(st: sqlite.Stmt, first: c_int, alloc: std.mem.Allocator) !conflict_mod.Force {
        return .{
            .lances = try st.intAs(u8, first),
            .quality = std.meta.stringToEnum(types.ExperienceLevel, try st.text(first + 1, alloc)) orelse return error.CorruptSave,
            .lance_bv = st.int(first + 2),
            .lance_tons = try st.intAs(u32, first + 3),
        };
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
        // The stored counter must be beyond every owned officer identity.
        {
            var max: u32 = 0;
            var it2 = gs.officer_arcs.iterator();
            while (it2.next()) |entry| max = @max(max, @intFromEnum(entry.key_ptr.*));
            if (max == std.math.maxInt(u32)) return error.CorruptSave;
            if (gs.next_officer_arc_id <= max) return error.CorruptSave;
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
    /// An empty roster is stored as no rows, so a loaded company without rows
    /// gets its empty entry (`GameState.merc_company_rosters`); loadMercCompanies
    /// runs first.
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
        for (gs.merc_companies.keys()) |mid| {
            const gop = try gs.merc_company_rosters.getOrPut(alloc, mid);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
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
        const st = try self.db.prepare("INSERT INTO bay_job VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        defer st.finalize();
        for (gs.bay_jobs.items, 0..) |j, i| {
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), @intFromEnum(j.hq), j.kind, if (j.unit != .none) @as(?types.UnitId, j.unit) else null, j.item_key, @as(i64, j.duration_days), @as(i64, j.queued_day), j.started_day, j.done_day, j.cost, if (j.artillery != .none) @as(?types.ArtilleryFormationId, j.artillery) else null });
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
        const st = try self.db.prepare("INSERT INTO pending_event VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)");
        defer st.finalize();
        for (gs.event_queue.pending.items, 0..) |e, i| {
            const situation: ?[]const u8 = if (e.kind == .situation) e.situation else null;
            try st.bindAll(.{ cid, @as(i64, @intCast(i)), e.kind, @as(i64, e.day), @intFromEnum(e.contract), @intFromEnum(e.company), @as(i64, @intCast(e.default_choice)), @as(i64, e.deadline_day), if (e.chosen) |c| @as(?i64, @intCast(c)) else null, @intFromEnum(e.person), @intFromEnum(e.id), @intFromEnum(e.battle), situation, @intFromEnum(e.actor) });
            try st.run();
        }
    }

    fn saveBattleReport(self: Store, gs: *GameState, cid: i64) !void {
        // Battle reports: the record a screen reads. Hits and ammunition
        // are child rows; the ammunition family is stored by name, not
        // by position, because `part.munition_keys` can grow and a
        // positional encoding would silently re-label saved rows.
        const br = try self.db.prepare("INSERT INTO battle_report VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,?51,?52,?53,?54,?55,?56,?57,?58,?59,?60)");
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
        const bp = try self.db.prepare("INSERT INTO battle_report_phase VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)");
        defer bp.finalize();
        const bl = try self.db.prepare("INSERT INTO battle_report_lever VALUES (?1,?2,?3,?4,?5,?6)");
        defer bl.finalize();
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
                r.operation_interventions,              r.artillery != null,                  @as(i64, @intCast(r.phases.len)),                                   @as(i64, @intCast(r.levers.len)),
            });
            try br.run();
            if (r.artillery) |a| try artillery_battle_store.save(self.db, cid, ord, &a);
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
            for (r.phases, 0..) |p, pi| {
                const order_roe: ?[]const u8 = switch (p.order) {
                    .roe => |roe| @tagName(roe),
                    else => null,
                };
                try bp.bindAll(.{
                    cid,                      ord,                  @as(i64, @intCast(pi)), @tagName(p.phase),
                    @tagName(p.order),        order_roe,            @tagName(p.roe),        @as(i64, p.ratio_bonus),
                    @as(i64, p.scenario_mod), @as(i64, p.roe_roll), @as(i64, p.momentum),   @as(i64, p.lever_mod),
                    @as(i64, p.margin),       @as(i64, p.hits),
                });
                try bp.run();
            }
            for (r.levers, 0..) |l, li| {
                try bl.bindAll(.{ cid, ord, @as(i64, @intCast(li)), @tagName(l.lever), @as(i64, l.cost), @as(i64, l.roll_mod) });
                try bl.run();
            }
        }
    }

    /// The battle in progress: its contract, pause and order count, then
    /// each order with the pause report it reached, in order. The record
    /// count (meta `battle_in_progress_count`) and each record's order count
    /// are serialization completeness checks, not state: a removed record
    /// or a truncated course of orders is corruption, never a battle not
    /// yet engaged or one paused earlier.
    fn saveBattleInProgress(self: Store, gs: *GameState, cid: i64) !void {
        const bb = try self.db.prepare("INSERT INTO battle_in_progress VALUES (?1,?2,?3,?4,?5)");
        defer bb.finalize();
        const bo = try self.db.prepare("INSERT INTO battle_in_progress_order VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)");
        defer bo.finalize();
        const count = try self.db.prepare("INSERT INTO meta VALUES (?1,'battle_in_progress_count',?2)");
        defer count.finalize();
        try count.bindAll(.{ cid, @as(i64, @intCast(gs.battles_in_progress.items.len)) });
        try count.run();
        for (gs.battles_in_progress.items, 0..) |record, i| {
            const contract: i64 = @intFromEnum(record.contract);
            try bb.bindAll(.{ cid, @as(i64, @intCast(i)), contract, @tagName(record.phase), @as(i64, @intCast(record.steps.items.len)) });
            try bb.run();
            for (record.steps.items, 0..) |step, si| {
                const r = step.report;
                const order_roe: ?[]const u8 = switch (step.order) {
                    .roe => |roe| @tagName(roe),
                    else => null,
                };
                const order_intervention: ?[]const u8 = switch (step.order) {
                    .intervene => |kind| @tagName(kind),
                    else => null,
                };
                const outcome: ?[]const u8 = if (r.outcome) |o| @tagName(o) else null;
                try bo.bindAll(.{
                    cid,                                  contract,                                    @as(i64, @intCast(si)),     @tagName(step.order),
                    order_roe,                            order_intervention,                          @tagName(r.pause),          @as(i64, r.margin),
                    @as(i64, r.hits),                     @as(i64, r.momentum),                        @tagName(r.roe),            outcome,
                    @as(i64, @intFromBool(r.held_field)), @tagName(r.odds.next),                       @as(i64, r.odds.counts[0]), @as(i64, r.odds.counts[1]),
                    @as(i64, r.odds.counts[2]),           @as(i64, r.odds.counts[3]),                  @as(i64, r.odds.counts[4]), @as(i64, r.odds.total),
                    @as(i64, r.lever_mod),                @as(i64, @intFromBool(r.reserve_committed)), @as(i64, r.capacity_spent),
                });
                try bo.run();
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
        const conflict_id: ?i64 = if (c.conflict_id == .none) null else @intFromEnum(c.conflict_id);
        const on_station: ?i64 = if (c.on_station_by) |d| d else null;
        const close_day: ?i64 = if (c.close_day) |d| d else null;
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
            c.arc_finale_key,                @as(i64, c.command_capacity),     conflict_id,                       @tagName(c.side),
            on_station,                      close_day,
        });
        try st.run();
    }

    // ------------------------------------------------------------------ load

    /// Restore exactly one valid named row for every stream and the saved seed.
    /// Missing, duplicate or malformed current state is corruption; no reseeding.
    /// Source: engineering-contract.md rule 52.
    fn loadRng(self: Store, gs: *GameState, cid: i64, has_seed: bool) !void {
        if (!has_seed) return error.CorruptSave;
        var loaded = std.EnumSet(rng_mod.Stream).initEmpty();
        const st = try self.db.prepare("SELECT stream, format, state, typeof(stream)='text' AND typeof(format)='integer' AND typeof(state)='blob' FROM rng_stream WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(3) != 1) return error.CorruptSave;
            const name = try st.text(0, gs.scratch());
            defer gs.scratch().free(name);
            const stream = std.meta.stringToEnum(rng_mod.Stream, name) orelse return error.CorruptSave;
            if (loaded.contains(stream)) return error.CorruptSave;
            const bytes = try st.blob(2, gs.scratch(), rng_mod.Rng.state_len);
            defer gs.scratch().free(bytes);
            if (!gs.rng.decode(stream, st.int(1), bytes)) return error.CorruptSave;
            loaded.insert(stream);
        }
        if (loaded.count() != std.enums.values(rng_mod.Stream).len) return error.CorruptSave;
    }

    /// Rebuild a campaign from the store. `gpa` backs the new GameState.
    pub fn load(self: Store, gpa: std.mem.Allocator, cid: i64) !GameState {
        var gs = GameState.init(gpa, .{});
        errdefer gs.deinit();
        gs.campaign_id = cid;
        const saved_version = try self.loadVersion(cid);
        try requireCampaignVersion(saved_version);

        const has_seed = try self.loadMeta(&gs, cid);
        inline for (.{ "next_person_id", "next_unit_id", "next_force_id", "next_hq_id", "next_contract_id", "next_battle_id", "next_listing_id", "next_candidate_id", "next_loan_id", "next_operation_id", "next_actor_id", "next_rival_id", "next_officer_arc_id", "next_hull_instance_id", "next_merc_company_id", "next_personage_id", "next_conflict_id", "next_news_id" }) |key| {
            const counter = (try self.hqMetaUint(cid, key, true)).?;
            if (counter == 0) return error.CorruptSave;
            @field(gs, key) = counter;
        }
        gs.event_queue.next_id = (try self.hqMetaUint(cid, "next_event_id", true)).?;
        if (gs.event_queue.next_id == 0) return error.CorruptSave;
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
        try self.loadRetiredHq(&gs, cid, saved_version);
        try self.loadStock(&gs, cid);
        try self.loadContract(&gs, cid);
        try self.loadOperations(&gs, cid);
        try self.loadOperationTasks(&gs, cid);
        try self.loadOperationInterventions(&gs, cid);
        try self.loadActors(&gs, cid);
        try self.loadContractSituations(&gs, cid);
        try self.loadMercCompanies(&gs, cid);
        try self.loadRivals(&gs, cid);
        try self.loadOfficerArcs(&gs, cid);
        try self.loadWorldStates(&gs, cid);
        try self.loadFactionRosters(&gs, cid);
        try self.loadMercCompanyRosters(&gs, cid);
        try self.loadMercHullArrivals(&gs, cid);
        try self.loadPersonages(&gs, cid);
        try self.loadPersonageRelations(&gs, cid);
        try self.loadConflicts(&gs, cid);
        try self.loadNews(&gs, cid);
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
        try validateSituationEvents(&gs);
        try self.loadBattleReport(&gs, cid);
        try self.loadBattleInProgress(&gs, cid);
        try self.loadRefitPlan(&gs, cid);
        try artillery_store.load(self.db, &gs, cid, saved_version);

        hq_ops.refreshHqStaffing(&gs);
        // Validate all cross-entity references and durable counters before
        // string validation (rules 47, 48).
        try validateReferences(&gs);
        try hq_ops.validateHqHistory(&gs);
        try artillery.validate(&gs);
        try personage_rules.validate(&gs);
        try personage_relation_rules.validate(&gs);
        try politics.validate(&gs);
        try news.validate(&gs);
        try npc_base.validate(&gs);
        try validateCounters(&gs);
        try validateStoredStrings(&gs);
        // Last: the battle in progress replays from the complete, validated campaign.
        try battle_rules.validateInProgress(&gs);
        return gs;
    }

    // ---- the per-table decoders `load` runs, in its order ----

    /// The schema version a campaign was saved at; `NoSuchCampaign` when the id is unknown.
    /// A campaign schema_version below 1 is corruption (rule 49).
    fn loadVersion(self: Store, cid: i64) !u32 {
        const st = try self.db.prepare("SELECT schema_version, typeof(schema_version)='integer' FROM campaign WHERE id = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        if (!try st.next()) return error.NoSuchCampaign;
        const v = st.int(0);
        if (st.int(1) != 1 or v < 1 or try st.next()) return error.CorruptSave;
        return std.math.cast(u32, v) orelse error.CorruptSave;
    }

    fn requireCampaignVersion(version: u32) !void {
        if (version < schema_version) return error.SaveOlderThanGame;
        if (version > schema_version) return error.SaveNewerThanGame;
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
        const st = try self.db.prepare("SELECT key, value, typeof(value)='integer' FROM meta WHERE cid = ?1");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const key = try st.text(0, alloc);
            const v = st.int(1);
            if (st.int(2) != 1) return error.CorruptSave;
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
            if (std.mem.eql(u8, key, "next_personage_id")) gs.next_personage_id = try fit(@TypeOf(gs.next_personage_id), v);
            if (std.mem.eql(u8, key, "next_conflict_id")) gs.next_conflict_id = try fit(@TypeOf(gs.next_conflict_id), v);
            if (std.mem.eql(u8, key, "next_news_id")) gs.next_news_id = try fit(@TypeOf(gs.next_news_id), v);
            if (std.mem.eql(u8, key, "rng_seed")) {
                if (has_seed) return error.CorruptSave;
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
        const st = try self.db.prepare(
            \\SELECT id,base_key,name,nickname,status,intro_year,pre_campaign,
            \\       owner_type,owner_faction_key,owner_merc_company_id,catalogue,ord,
            \\       typeof(cid)='integer' AND typeof(ord)='integer' AND typeof(id)='integer'
            \\       AND typeof(base_key)='text' AND typeof(name) IN ('text','null')
            \\       AND typeof(nickname) IN ('text','null') AND typeof(status)='text'
            \\       AND typeof(intro_year)='integer' AND typeof(pre_campaign)='integer'
            \\       AND typeof(owner_type)='text' AND typeof(owner_faction_key)='text'
            \\       AND typeof(owner_merc_company_id)='integer' AND typeof(catalogue)='text'
            \\FROM hull_instance WHERE cid=?1 ORDER BY ord
        );
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            // Check original storage classes before SQLite's column helpers can
            // coerce malformed carrier identity or provenance (contract rule 47).
            if (st.int(12) != 1) return error.CorruptSave;
            _ = try st.intAs(usize, 11);
            const pre_campaign = try st.intAs(u8, 6);
            if (pre_campaign > 1) return error.CorruptSave;
            const status = std.meta.stringToEnum(hull_mod.HullStatus, try st.text(4, alloc)) orelse return error.CorruptSave;
            // Reconstruct owner union fail-closed (rule 47). Unknown tag → CorruptSave;
            // inconsistent payload (e.g. faction key present but owner_type != merc_company) → CorruptSave.
            const ot = std.meta.stringToEnum(hull_mod.OwnerType, try st.text(7, alloc)) orelse return error.CorruptSave;
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
                .pre_campaign = pre_campaign != 0,
                .owner = owner,
                .catalogue = std.meta.stringToEnum(hull_mod.HullCatalogue, try st.text(10, alloc)) orelse return error.CorruptSave,
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
            // The post-load reference pass validates a populated battle backlink;
            // contract_id remains historical and may be unavailable.
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
        const st = try self.db.prepare(
            \\SELECT hull_instance_id,from_day,to_day,acquisition_type,prior_owner_key,ord,
            \\       typeof(cid)='integer' AND typeof(ord)='integer'
            \\       AND typeof(hull_instance_id)='integer' AND typeof(from_day)='integer'
            \\       AND typeof(to_day) IN ('integer','null')
            \\       AND typeof(acquisition_type)='text' AND typeof(prior_owner_key)='text'
            \\FROM hull_ownership_history WHERE cid=?1 ORDER BY ord
        );
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(6) != 1) return error.CorruptSave;
            _ = try st.intAs(usize, 5);
            const hid = try toId(types.HullInstanceId, st.int(0));
            _ = gs.hull_instances.getPtr(hid) orelse return error.CorruptSave; // orphan FK
            const acq = std.meta.stringToEnum(hull_inst_mod.AcquisitionType, try st.text(3, alloc)) orelse return error.CorruptSave;
            try gs.hull_ownership_history.append(alloc, .{
                .hull_instance_id = hid,
                .from_day = try st.intAs(u32, 1),
                .to_day = if (st.optInt(2)) |day| std.math.cast(u32, day) orelse return error.CorruptSave else null,
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

    /// Versioned archive completeness and permanent HQ counter. typeof checks
    /// precede conversion because SQLite's integer/text accessors coerce values.
    fn loadRetiredHq(self: Store, gs: *GameState, cid: i64, version: u32) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare(
            \\SELECT id,name,planet,tier,sold_day,ord,
            \\ typeof(cid)='integer' AND typeof(ord)='integer' AND typeof(id)='integer' AND typeof(name)='text'
            \\ AND typeof(planet)='text' AND typeof(tier)='text' AND typeof(sold_day)='integer'
            \\ FROM retired_hq WHERE cid=?1 ORDER BY ord
        );
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (version < 61 or st.int(6) != 1) return error.CorruptSave;
            if (try st.intAs(u32, 5) != gs.retired_hqs.count()) return error.CorruptSave;
            const id = try toId(types.HqId, st.int(0));
            if (id == .none) return error.CorruptSave;
            const tier_bytes = try st.text(3, gs.scratch());
            defer gs.scratch().free(tier_bytes);
            const tier = std.meta.stringToEnum(hq_mod.HqTier, tier_bytes) orelse return error.CorruptSave;
            const h: hq_mod.RetiredHq = .{
                .id = id,
                .name = try st.text(1, alloc),
                .planet_key = try st.text(2, alloc),
                .tier = tier,
                .sold_day = try st.intAs(u32, 4),
            };
            const gop = try gs.retired_hqs.getOrPut(alloc, id);
            if (gop.found_existing) return error.CorruptSave;
            gop.value_ptr.* = h;
        }
        const count = try self.hqMetaUint(cid, "retired_hq_count", version >= 61);
        if (count) |n| if (n != gs.retired_hqs.count()) return error.CorruptSave;
        if (version >= 61) {
            gs.next_hq_id = (try self.hqMetaUint(cid, "next_hq_id", true)).?;
            if (gs.next_hq_id == 0 or gs.next_hq_id <= hq_ops.maxHqIdentity(gs)) return error.CorruptSave;
        }
    }

    fn hqMetaUint(self: Store, cid: i64, key: []const u8, required: bool) !?u32 {
        const st = try self.db.prepare("SELECT value, typeof(cid)='integer' AND typeof(key)='text' AND typeof(value)='integer' FROM meta WHERE cid=?1 AND key=?2");
        defer st.finalize();
        try st.bindAll(.{ cid, key });
        if (!try st.next()) {
            if (required) return error.CorruptSave;
            return null;
        }
        if (st.int(1) != 1) return error.CorruptSave;
        const value = try st.intAs(u32, 0);
        if (try st.next()) return error.CorruptSave;
        return value;
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
    /// The backer columns (`conflict_id`, `side`, `on_station_by`,
    /// `close_day`) are each NULL where allowed or of their type, and `side`
    /// is matched on the column's full bytes, so a fraction or a valid tag
    /// with a tail is `CorruptSave` rather than the value it truncates to
    /// (rule 47). `politics.validateBacker` then checks the backer itself.
    fn loadContract(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const st = try self.db.prepare("SELECT is_offer, id, kind, employer, enemy, planet, status, company, start_day, score, dist_ly, beachhead, transit_days, arrive_day, end_day, monthly_net, next_battle, battles, casualties, objective, committed_bv, pool, pool_remaining, vp, ineffective_since, breach_day, length_months, base_pay, advance_pct, signing_bonus, transport_pct, overhead_pct, battle_loss_pct, salvage_pct, salvage_exchange, command_rights, negotiated, enemy_lances, enemy_quality, enemy_lance_bv, enemy_lance_tons, offer_hq, orders_day, arc_key, arc_beat, escalation_clock, arc_finale_key, command_capacity, conflict_id, side, on_station_by, close_day, typeof(conflict_id) IN ('integer','null') AND typeof(side)='text' AND typeof(on_station_by) IN ('integer','null') AND typeof(close_day) IN ('integer','null') FROM contract WHERE cid = ?1 ORDER BY is_offer, ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(52) != 1) return error.CorruptSave;
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
                .conflict_id = if (st.isNull(48)) .none else if (st.int(48) == 0) return error.CorruptSave else try toId(types.ConflictId, st.int(48)),
                .side = std.meta.stringToEnum(contract_mod.ConflictSide, try st.text(49, alloc)) orelse return error.CorruptSave,
                .on_station_by = try optU32(st.optInt(50)),
                .close_day = try optU32(st.optInt(51)),
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
        const st = try self.db.prepare("SELECT principal, balance, rate_bp, term, next_pay, payment, id FROM loan WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const raw_id = st.int(6);
            const id = try toId(types.LoanId, raw_id);
            if (id == .none) return error.CorruptSave;
            try gs.loans.append(alloc, .{
                .id = id,
                .principal = st.int(0),
                .balance = st.int(1),
                .rate_bp = st.int(2),
                .term_months = try st.intAs(u16, 3),
                .next_pay_day = try st.intAs(u32, 4),
                .payment = st.int(5),
            });
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
        const st = try self.db.prepare("SELECT hq,kind,unit,item_key,duration,queued,started,done,cost,artillery,typeof(cid)='integer' AND typeof(ord)='integer' AND typeof(hq)='integer' AND typeof(kind)='text' AND typeof(unit) IN ('integer','null') AND typeof(item_key)='text' AND typeof(duration)='integer' AND typeof(queued)='integer' AND typeof(started) IN ('integer','null') AND typeof(done) IN ('integer','null') AND typeof(cost)='integer' AND typeof(artillery) IN ('integer','null'),ord FROM bay_job WHERE cid=?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            if (st.int(10) != 1 or st.int(11) < 0) return error.CorruptSave;
            const raw_unit = st.optInt(2);
            const raw_artillery = st.optInt(9);
            if (raw_unit) |raw| if (raw <= 0) return error.CorruptSave;
            if (raw_artillery) |raw| if (raw <= 0) return error.CorruptSave;
            const kind_bytes = try st.text(1, gs.scratch());
            defer gs.scratch().free(kind_bytes);
            try gs.bay_jobs.append(alloc, .{
                .hq = try toId(types.HqId, st.int(0)),
                .kind = std.meta.stringToEnum(state_mod.BayJobKind, kind_bytes) orelse return error.CorruptSave,
                .unit = if (raw_unit) |raw| try toId(types.UnitId, raw) else .none,
                .artillery = if (raw_artillery) |raw| try toId(types.ArtilleryFormationId, raw) else .none,
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
        const st = try self.db.prepare("SELECT hq, first, last, callsign, role, experience, primary_skill, secondary_skill, bonus, listed, expires, age, id FROM candidate WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const raw_id = st.int(12);
            const id = try toId(types.CandidateId, raw_id);
            if (id == .none) return error.CorruptSave;
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
        const st = try self.db.prepare("SELECT kind, item_key, rarity, price, qty, staple, listed, expires, hq, c_armor, c_quality, c_damaged, c_destroyed, c_missing, black, company, id, hull_instance_id, planet_key, available_after FROM listing WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const raw_id = st.int(16);
            const id = try toId(types.ListingId, raw_id);
            if (id == .none) return error.CorruptSave;
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
        const st = try self.db.prepare("SELECT kind, day, contract, company, default_choice, deadline, chosen, person, id, battle, situation, actor, (situation IS NULL OR typeof(situation)='text') AND typeof(actor)='integer' FROM pending_event WHERE cid = ?1 ORDER BY ord");
        defer st.finalize();
        try st.bindAll(.{cid});
        while (try st.next()) {
            const kind = st.enumValue(events_mod.EventKind, 0) orelse return error.CorruptSave;
            if (st.int(12) != 1) return error.CorruptSave;
            // A situation rebuilds its options from its row; every other
            // kind from its deck entry, and names no situation or actor.
            var situation: []const u8 = "";
            var default_owned: ?usize = null;
            const options: []const events_mod.Option = if (kind == .situation) blk: {
                const s = situation_mod.find(try st.text(10, alloc)) orelse return error.CorruptSave;
                situation = s.key;
                default_owned = s.default_choice;
                break :blk s.eventOptions();
            } else blk: {
                if (!st.isNull(10) or st.int(11) != 0) return error.CorruptSave;
                break :blk (contract_events.entryForKind(kind) orelse return error.CorruptSave).options;
            };
            const default_choice = try st.intAs(usize, 4);
            if (default_choice >= options.len) return error.CorruptSave; // out-of-range choice
            if (default_owned) |d| if (default_choice != d) return error.CorruptSave;
            const chosen: ?usize = if (st.optInt(6)) |c| blk: {
                const ci = try fit(usize, c);
                if (ci >= options.len) return error.CorruptSave;
                break :blk ci;
            } else null;
            const actor = try toId(types.ActorId, st.int(11));
            if (kind == .situation and actor == .none) return error.CorruptSave;
            try gs.event_queue.pending.append(alloc, .{
                .day = try st.intAs(u32, 1),
                .kind = kind,
                .contract = try toId(types.ContractId, st.int(2)),
                .company = try toId(types.ForceId, st.int(3)),
                .options = options,
                .default_choice = default_choice,
                .deadline_day = try st.intAs(u32, 5),
                .chosen = chosen,
                .person = try toId(types.PersonId, st.int(7)),
                .id = try toId(types.EventId, st.int(8)),
                .battle = try toId(types.BattleId, st.int(9)),
                .situation = situation,
                .actor = actor,
            });
        }
        _ = saved_version;
        for (gs.event_queue.pending.items) |event| {
            if (event.id == .none or @intFromEnum(event.id) >= gs.event_queue.next_id) return error.CorruptSave;
        }
    }

    fn loadBattleReport(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        // Battle reports. Child rows are read per report; an outcome or
        // ROE that does not parse is `error.CorruptSave`.
        const br = try self.db.prepare("SELECT ord, id, day, contract, company, kind, enemy_key, scenario, terrain, weather, outcome, held_field, withdrew, roe, roe_overridden, player_power, enemy_power, conditions_mod, close_terrain, air_grounded, convoy_hit, edge_spent_by, recon_quality, avg_fatigue, avg_morale, hits_taken, destroyed, wounded, kia, lost_hulls, missing, enemy_destroyed_bv, kills_credited, prisoners, battle_loss_comp, score_after, score_delta, morale_delta, fatigue_add, battle_loss_pct, salvage_pct, command_rights, silenced_mounts, armor_left, salvage_claimed, salvage_haulable, salvage_cut, salvage_cash, salvage_items, conceded, acknowledged, salvage_unclaimed, operation, operation_intent, operation_tempo, operation_interventions, artillery_present, typeof(artillery_present)='integer' AND typeof(phase_count)='integer' AND typeof(lever_count)='integer', phase_count, lever_count FROM battle_report WHERE cid = ?1 ORDER BY ord");
        defer br.finalize();
        try br.bindAll(.{cid});
        while (try br.next()) {
            const ord = br.int(0);
            if (br.int(57) != 1 or br.int(56) < 0 or br.int(56) > 1) return error.CorruptSave;
            const artillery_result = try artillery_battle_store.load(self.db, gs, cid, ord, br.int(56) == 1);
            const outcome = br.enumValue(autoresolve_mod.Outcome, 10) orelse return error.CorruptSave;
            const roe = br.enumValue(force_mod.Roe, 13) orelse return error.CorruptSave;

            const hulls = try self.loadReportHits(alloc, cid, ord);
            const ammo = try self.loadReportAmmo(alloc, cid, ord);
            const candidates = try self.loadReportSalvage(alloc, cid, ord);
            const tasks = try self.loadReportTasks(alloc, cid, ord);
            const phases = try self.loadReportPhases(alloc, cid, ord, try br.intAs(usize, 58));
            const levers = try self.loadReportLevers(alloc, cid, ord, try br.intAs(usize, 59));
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
                .phases = phases,
                .levers = levers,
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
                .artillery = artillery_result,
            });
            if (!battle_phases_rules.reportPhasesConsistent(&gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1])) return error.CorruptSave;
        }
        try artillery_battle_store.validateParents(self.db, cid);
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
        inline for (.{ "battle_report_phase", "battle_report_lever" }) |table| {
            const chk = try self.db.prepare("SELECT COUNT(*) FROM " ++ table ++ " WHERE cid = ?1 AND report_ord NOT IN (SELECT ord FROM battle_report WHERE cid = ?1)");
            defer chk.finalize();
            try chk.bindAll(.{cid});
            if (!try chk.next()) return error.CorruptSave;
            if (chk.int(0) > 0) return error.CorruptSave;
        }
    }

    /// A stored battle order: the kind, the ROE column a `roe` order and only
    /// a `roe` order carries, and the intervention column an `intervene`
    /// order and only an `intervene` order carries. A table with no
    /// intervention column (`intervention_col` null) holds no `intervene`
    /// order.
    fn storedOrder(st: sqlite.Stmt, kind_col: c_int, roe_col: c_int, intervention_col: ?c_int) error{CorruptSave}!battle_phase_mod.Order {
        const kind = st.enumValue(battle_phase_mod.Order.Kind, kind_col) orelse return error.CorruptSave;
        const roe = try st.optEnum(force_mod.Roe, roe_col);
        const intervention = if (intervention_col) |col| try st.optEnum(operation_mod.Intervention, col) else null;
        if ((kind == .roe) != (roe != null)) return error.CorruptSave;
        if ((kind == .intervene) != (intervention != null)) return error.CorruptSave;
        return switch (kind) {
            .roe => .{ .roe = roe.? },
            .intervene => .{ .intervene = intervention.? },
            inline else => |k| @unionInit(battle_phase_mod.Order, @tagName(k), {}),
        };
    }

    /// A report's levers, in the order given: contiguous from 0, exactly the
    /// `count` the report row records, each kind known and each integer
    /// stored as an integer. `battle_phases.reportPhasesConsistent` then
    /// checks their costs, modifiers and sum.
    fn loadReportLevers(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64, count: usize) ![]battle_report_mod.BattleLever {
        var levers: std.ArrayListUnmanaged(battle_report_mod.BattleLever) = .empty;
        const bl = try self.db.prepare("SELECT ord, kind, cost, roll_mod, typeof(ord)='integer' AND typeof(cost)='integer' AND typeof(roll_mod)='integer' FROM battle_report_lever WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bl.finalize();
        try bl.bindAll(.{ cid, ord });
        while (try bl.next()) {
            if (bl.int(4) != 1) return error.CorruptSave;
            if (bl.int(0) != @as(i64, @intCast(levers.items.len)) or levers.items.len >= battle_phases_rules.max_levers) return error.CorruptSave;
            try levers.append(alloc, .{
                .lever = bl.enumValue(battle_phase_mod.Lever, 1) orelse return error.CorruptSave,
                .cost = try bl.intAs(u8, 2),
                .roll_mod = try bl.intAs(i32, 3),
            });
        }
        if (levers.items.len != count) return error.CorruptSave;
        return levers.items;
    }

    /// A report's fought phases, in order: contiguous from 0, exactly the
    /// `count` the report row records, at most `battle_phases.max_phases`,
    /// each integer stored as an integer.
    fn loadReportPhases(self: Store, alloc: std.mem.Allocator, cid: i64, ord: i64, count: usize) ![]battle_phase_mod.PhaseRecord {
        var phases: std.ArrayListUnmanaged(battle_phase_mod.PhaseRecord) = .empty;
        const bp = try self.db.prepare("SELECT ord, phase, order_kind, order_roe, roe, ratio_bonus, scenario_mod, roe_roll, momentum, lever_mod, margin, hits, typeof(ord)='integer' AND typeof(ratio_bonus)='integer' AND typeof(scenario_mod)='integer' AND typeof(roe_roll)='integer' AND typeof(momentum)='integer' AND typeof(lever_mod)='integer' AND typeof(margin)='integer' AND typeof(hits)='integer' FROM battle_report_phase WHERE cid = ?1 AND report_ord = ?2 ORDER BY ord");
        defer bp.finalize();
        try bp.bindAll(.{ cid, ord });
        while (try bp.next()) {
            if (bp.int(12) != 1) return error.CorruptSave;
            if (bp.int(0) != @as(i64, @intCast(phases.items.len)) or phases.items.len >= battle_phases_rules.max_phases) return error.CorruptSave;
            try phases.append(alloc, .{
                .phase = bp.enumValue(battle_phase_mod.Phase, 1) orelse return error.CorruptSave,
                .order = try storedOrder(bp, 2, 3, null),
                .roe = bp.enumValue(force_mod.Roe, 4) orelse return error.CorruptSave,
                .ratio_bonus = try bp.intAs(i32, 5),
                .scenario_mod = try bp.intAs(i32, 6),
                .roe_roll = try bp.intAs(i32, 7),
                .momentum = try bp.intAs(i32, 8),
                .lever_mod = try bp.intAs(i32, 9),
                .margin = try bp.intAs(i32, 10),
                .hits = try bp.intAs(u32, 11),
            });
        }
        if (phases.items.len != count) return error.CorruptSave;
        return phases.items;
    }

    /// The battle in progress (rules 47, 70). Fails closed on an unknown
    /// phase or order, a record for a missing or inactive contract, more than
    /// one record (the battle lock allows one), orders out of sequence or
    /// orphaned, a malformed integer, a record count (meta
    /// `battle_in_progress_count`) or an order count the rows do not match,
    /// and a course of orders or a pause that `battle_phases.recordConsistent`
    /// rejects. `battle.validateInProgress` replays the record once the
    /// whole campaign is loaded.
    fn loadBattleInProgress(self: Store, gs: *GameState, cid: i64) !void {
        const alloc = gs.allocator();
        const bb = try self.db.prepare("SELECT ord, contract_id, phase, typeof(ord)='integer' AND typeof(contract_id)='integer' AND typeof(orders)='integer', orders FROM battle_in_progress WHERE cid = ?1 ORDER BY ord");
        defer bb.finalize();
        try bb.bindAll(.{cid});
        while (try bb.next()) {
            if (bb.int(3) != 1) return error.CorruptSave;
            const orders = try bb.intAs(usize, 4);
            if (bb.int(0) != @as(i64, @intCast(gs.battles_in_progress.items.len)) or gs.battles_in_progress.items.len > 0) return error.CorruptSave;
            const contract = try toId(types.ContractId, bb.int(1));
            const c = gs.contracts.getPtr(contract) orelse return error.CorruptSave;
            if (c.status != .active) return error.CorruptSave;
            var record: battle_phase_mod.BattleInProgress = .{
                .contract = contract,
                .phase = bb.enumValue(battle_phase_mod.Pause, 2) orelse return error.CorruptSave,
            };
            const bo = try self.db.prepare("SELECT ord, order_kind, order_roe, pause, margin, hits, momentum, roe, outcome, held_field, odds_next, odds_0, odds_1, odds_2, odds_3, odds_4, odds_total, typeof(ord)='integer' AND typeof(margin)='integer' AND typeof(hits)='integer' AND typeof(momentum)='integer' AND typeof(held_field)='integer' AND typeof(odds_0)='integer' AND typeof(odds_1)='integer' AND typeof(odds_2)='integer' AND typeof(odds_3)='integer' AND typeof(odds_4)='integer' AND typeof(odds_total)='integer' AND typeof(lever_mod)='integer' AND typeof(reserve_committed)='integer' AND typeof(capacity_spent)='integer', order_intervention, lever_mod, reserve_committed, capacity_spent FROM battle_in_progress_order WHERE cid = ?1 AND contract_id = ?2 ORDER BY ord");
            defer bo.finalize();
            try bo.bindAll(.{ cid, @as(i64, @intFromEnum(contract)) });
            while (try bo.next()) {
                if (bo.int(17) != 1) return error.CorruptSave;
                if (bo.int(0) != @as(i64, @intCast(record.steps.items.len))) return error.CorruptSave;
                const held = bo.int(9);
                if (held != 0 and held != 1) return error.CorruptSave;
                const committed = bo.int(20);
                if (committed != 0 and committed != 1) return error.CorruptSave;
                var counts: [battle_phase_mod.max_bands]u16 = undefined;
                for (&counts, 11..) |*n, col| n.* = try bo.intAs(u16, @intCast(col));
                try record.steps.append(alloc, .{
                    .order = try storedOrder(bo, 1, 2, 18),
                    .report = .{
                        .pause = bo.enumValue(battle_phase_mod.Pause, 3) orelse return error.CorruptSave,
                        .margin = try bo.intAs(i32, 4),
                        .hits = try bo.intAs(u32, 5),
                        .momentum = try bo.intAs(i32, 6),
                        .roe = bo.enumValue(force_mod.Roe, 7) orelse return error.CorruptSave,
                        .outcome = try bo.optEnum(autoresolve_mod.Outcome, 8),
                        .held_field = held == 1,
                        .odds = .{
                            .next = bo.enumValue(battle_phase_mod.NextPhase, 10) orelse return error.CorruptSave,
                            .counts = counts,
                            .total = try bo.intAs(u16, 16),
                        },
                        .lever_mod = try bo.intAs(i32, 19),
                        .reserve_committed = committed == 1,
                        .capacity_spent = try bo.intAs(u8, 21),
                    },
                });
            }
            if (record.steps.items.len != orders) return error.CorruptSave;
            if (!battle_phases_rules.recordConsistent(&record)) return error.CorruptSave;
            try gs.battles_in_progress.append(alloc, record);
        }
        const orphan = try self.db.prepare("SELECT COUNT(*) FROM battle_in_progress_order WHERE cid = ?1 AND contract_id NOT IN (SELECT contract_id FROM battle_in_progress WHERE cid = ?1)");
        defer orphan.finalize();
        try orphan.bindAll(.{cid});
        if (!try orphan.next()) return error.CorruptSave;
        if (orphan.int(0) > 0) return error.CorruptSave;
        if ((try self.hqMetaUint(cid, "battle_in_progress_count", true)).? != gs.battles_in_progress.items.len) return error.CorruptSave;
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
        if (from_version < 60) try artillery.syncMarkets(gs);
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
                    .to_day = null,
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
            switch (inst.catalogue) {
                .chassis => try Check.hull(inst.base_key),
                .artillery => if (artillery_catalogue.find(inst.base_key) == null) return error.CorruptSave,
            }
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
        if (r.artillery) |a| {
            try Check.shown(a.catalogue_name);
        }
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
        fn reportExists(id: types.BattleId, gsp: *const GameState) error{CorruptSave}!void {
            if (id == .none) return;
            if (gsp.battle_reports.find(id) == null) return error.CorruptSave;
        }
    };
    // A permanent report ID is unique campaign history. A duplicate makes every
    // backlink ambiguous, so reject the whole save rather than choosing one.
    for (gs.battle_reports.kept.items, 0..) |r, i| {
        if (r.id == .none) return error.CorruptSave;
        for (gs.battle_reports.kept.items[0..i]) |earlier| {
            if (earlier.id == r.id) return error.CorruptSave;
        }
    }
    // Units
    var uit = gs.units.iterator();
    while (uit.next()) |e| {
        const u = e.value_ptr;
        try Ref.inMap(types.ForceId, u.force, gs.forces);
        try Ref.inMap(types.PersonId, u.pilot, gs.people);
        try Ref.inMap(types.PersonId, u.tech, gs.people);
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
        // Each unit/child reference in the list must resolve.
        for (f.units.items) |uid| try Ref.unitExists(uid, gs);
        for (f.children.items) |cid| try Ref.inMap(types.ForceId, cid, gs.forces);
    }
    // People
    var pit = gs.people.iterator();
    while (pit.next()) |e| {
        const p = e.value_ptr;
        try Ref.inMap(types.ForceId, p.assigned_force, gs.forces);
    }
    // Contracts
    for ([_][]const contract_mod.Contract{ gs.contracts.values(), gs.contract_offers.items }) |list| {
        for (list) |c| {
            try Ref.inMap(types.ForceId, c.assigned_company, gs.forces);
        }
    }
    // Bay jobs
    for (gs.bay_jobs.items) |j| {
        try Ref.unitExists(j.unit, gs);
    }
    // Pending events
    for (gs.event_queue.pending.items) |ev| {
        try Ref.inMap(types.ContractId, ev.contract, gs.contracts);
        try Ref.inMap(types.ForceId, ev.company, gs.forces);
        try Ref.inMap(types.PersonId, ev.person, gs.people);
        try Ref.reportExists(ev.battle, gs);
    }
    // Held hulls
    for (gs.held_hulls.items) |h| {
        try Ref.inMap(types.ForceId, h.from_force, gs.forces);
        try Ref.reportExists(h.battle, gs);
    }
    // Permanent history: every populated backlink names exactly one retained report.
    for (gs.hull_combat_records.items) |r| try Ref.reportExists(r.battle_id, gs);
    for (gs.maintenance_entries.items) |e| try Ref.reportExists(e.battle_id, gs);
    // Market listings: a non-.none hull_instance_id must name a live HullInstance (rules 47/48).
    for (gs.market_listings.items) |l| {
        try Ref.inMap(types.HullInstanceId, l.hull_instance_id, gs.hull_instances);
    }
    // Ledger transactions
    for (gs.ledger.transactions.items) |t| {
        try Ref.inMap(types.ForceId, t.company, gs.forces);
        try Ref.inMap(types.ContractId, t.contract, gs.contracts);
    }
    // Unit transfers
    for (gs.unit_transfers.items) |ut| {
        try Ref.unitExists(ut.unit, gs);
        try Ref.inMap(types.ForceId, ut.to_company, gs.forces);
    }
    // Supply and stock policies
    for (gs.supply_policies.items) |sp| try Ref.inMap(types.ForceId, sp.company, gs.forces);
    // Fund couriers and standing policies
    for (gs.fund_couriers.items) |c| switch (c.to) {
        .outfit => {},
        .hq => {},
        .company => |id| try Ref.inMap(types.ForceId, id, gs.forces),
    };
    for (gs.policies.items) |p| switch (p.entity) {
        .outfit => {},
        .hq => {},
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
fn validateCounters(gs: *GameState) error{CorruptSave}!void {
    const max_u32 = std.math.maxInt(u32);
    // Current counters are immutable on load and strictly exceed owned IDs.
    {
        var max: u32 = 0;
        var it = gs.people.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_person_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.units.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        for (gs.held_hulls.items) |h| max = @max(max, @intFromEnum(h.unit.id));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_unit_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.forces.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_force_id <= max) return error.CorruptSave;
    }
    {
        const max = hq_ops.maxHqIdentity(gs);
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_hq_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.contracts.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        for (gs.contract_offers.items) |c| max = @max(max, @intFromEnum(c.id));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_contract_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.actors.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_actor_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.rivals.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_rival_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.merc_companies.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_merc_company_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        for (gs.personages.keys()) |id| max = @max(max, @intFromEnum(id));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_personage_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.officer_arcs.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_officer_arc_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        var it = gs.hull_instances.iterator();
        while (it.next()) |e| max = @max(max, @intFromEnum(e.key_ptr.*));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_hull_instance_id <= max) return error.CorruptSave;
    }
    // Battle/event references also reserve their identity below the counter.
    if (gs.next_battle_id == max_u32) return error.CorruptSave;
    if (gs.event_queue.next_id == max_u32) return error.CorruptSave;
    for (gs.battle_reports.kept.items) |report| if (@intFromEnum(report.id) >= gs.next_battle_id) return error.CorruptSave;
    for (gs.held_hulls.items) |held| if (@intFromEnum(held.battle) >= gs.next_battle_id) return error.CorruptSave;
    for (gs.event_queue.pending.items) |event| if (@intFromEnum(event.battle) >= gs.next_battle_id) return error.CorruptSave;
    {
        var max: u32 = 0;
        for (gs.market_listings.items) |l| max = @max(max, @intFromEnum(l.id));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_listing_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        for (gs.candidates.items) |c| max = @max(max, @intFromEnum(c.id));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_candidate_id <= max) return error.CorruptSave;
    }
    {
        var max: u32 = 0;
        for (gs.loans.items) |l| max = @max(max, @intFromEnum(l.id));
        if (max == max_u32) return error.CorruptSave;
        if (gs.next_loan_id <= max) return error.CorruptSave;
    }
}

/// Every pending situation answers an open record of its contract, owned
/// by the same actor, and every open record has exactly one pending
/// situation; an answered record has none (rule 47).
fn validateSituationEvents(gs: *GameState) error{CorruptSave}!void {
    for (gs.event_queue.pending.items, 0..) |ev, i| {
        if (ev.kind != .situation) continue;
        const c = gs.contracts.getPtr(ev.contract) orelse return error.CorruptSave;
        const record = for (c.situations.items) |*r| {
            if (std.mem.eql(u8, r.key, ev.situation)) break r;
        } else return error.CorruptSave;
        if (record.choice != null or record.actor != ev.actor or ev.chosen != null) return error.CorruptSave;
        for (gs.event_queue.pending.items[0..i]) |prior| {
            if (prior.kind == .situation and prior.contract == ev.contract and std.mem.eql(u8, prior.situation, ev.situation)) return error.CorruptSave;
        }
    }
    for (gs.contracts.values()) |*c| for (c.situations.items) |r| {
        if (r.choice != null) continue;
        const pending = for (gs.event_queue.pending.items) |ev| {
            if (ev.kind == .situation and ev.contract == c.id and std.mem.eql(u8, ev.situation, r.key)) break true;
        } else false;
        if (!pending) return error.CorruptSave;
    };
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

/// A flag set as stored (schema 66): bit `@intFromEnum(flag)` per flag held.
fn flagBits(comptime E: type, set: std.EnumSet(E)) i64 {
    var bits: i64 = 0;
    var it = set.iterator();
    while (it.next()) |f| bits |= @as(i64, 1) << @intFromEnum(f);
    return bits;
}

/// A stored flag set; `error.CorruptSave` for a negative value or a bit
/// that names no flag.
fn flagSet(comptime E: type, bits: i64) error{CorruptSave}!std.EnumSet(E) {
    if (bits < 0) return error.CorruptSave;
    var set: std.EnumSet(E) = .{};
    var rest = bits;
    inline for (comptime std.enums.values(E)) |f| {
        const bit = @as(i64, 1) << @intFromEnum(f);
        if (rest & bit != 0) {
            set.insert(f);
            rest &= ~bit;
        }
    }
    if (rest != 0) return error.CorruptSave;
    return set;
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

test "purchased conventional vehicle preserves identity and provenance across save load" {
    const commands = @import("../sim/commands.zig");
    const hull_instance = @import("../domain/hull_instance.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 918 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const hq = gs.seat();
    gs.hqs.getPtr(hq).?.funds = 10_000_000;
    const listing: types.ListingId = @enumFromInt(gs.next_listing_id);
    try gs.market_listings.append(gs.allocator(), .{
        .id = listing,
        .kind = .unit,
        .item_key = "SCP-1N",
        .rarity = .common,
        .price = 400_000,
        .hq = hq,
    });
    gs.next_listing_id += 1;
    const bought = (try commands.execute(&gs, .{ .buy_listing = .{ .listing = listing, .buyer = .{ .hq = hq } } })).unit;
    const hull = gs.unit(bought).?.hull_instance_id;
    try std.testing.expect(hull != .none);
    try std.testing.expectEqual(hull_instance.OwnerType.player, std.meta.activeTag(gs.hull_instances.getPtr(hull).?.owner));
    try std.testing.expectEqual(@import("../domain/chassis.zig").find("SCP-1N").?.loadout.len + 1, gs.hull_instances.getPtr(hull).?.loadout.items.len);
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(hull, loaded.unit(bought).?.hull_instance_id);
    var purchase_found = false;
    for (loaded.hull_ownership_history.items) |row| {
        if (row.hull_instance_id != hull) continue;
        purchase_found = true;
        try std.testing.expectEqual(hull_instance.AcquisitionType.purchase, row.acquisition_type);
        try std.testing.expectEqual(@as(?u32, null), row.to_day);
    }
    try std.testing.expect(purchase_found);

    const next_hull = loaded.next_hull_instance_id;
    const next_listing: types.ListingId = @enumFromInt(loaded.next_listing_id);
    try loaded.market_listings.append(loaded.allocator(), .{ .id = next_listing, .kind = .unit, .item_key = "SCP-1N", .rarity = .common, .price = 400_000, .hq = hq });
    loaded.next_listing_id += 1;
    const second = (try commands.execute(&loaded, .{ .buy_listing = .{ .listing = next_listing, .buyer = .{ .hq = hq } } })).unit;
    const expected_next_hull: types.HullInstanceId = @enumFromInt(next_hull);
    try std.testing.expectEqual(expected_next_hull, loaded.unit(second).?.hull_instance_id);
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

test "nonempty unversioned databases are refused without creating a schema" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE unrelated(value); INSERT INTO unrelated VALUES ('retained')");
    try std.testing.expectError(error.CorruptStore, Store.fromDb(db));
    const st = try db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table'");
    defer st.finalize();
    try std.testing.expect(try st.next());
    try std.testing.expectEqual(@as(i64, 1), st.int(0));
}

/// A test campaign founded as `create_commander` leaves the world a load
/// requires: the commander and starter HQ, and every personage
/// (`personages.validate`). Returns the starter HQ.
pub fn foundCampaignForTest(gs: *GameState, name: []const u8, origin: commander_mod.Faction, profession: commander_mod.Profession) !types.HqId {
    std.debug.assert(@import("builtin").is_test);
    const home = try founding.createCommander(gs, name, origin, profession);
    try personage_rules.seedForTest(gs);
    return home;
}

fn databaseFingerprintForTest(db: sqlite.Db) !u64 {
    var hash = std.hash.Wyhash.init(0);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const schema = try db.prepare("SELECT type,name,sql FROM sqlite_master ORDER BY type,name");
    defer schema.finalize();
    while (try schema.next()) {
        for (0..3) |column| {
            _ = scratch.reset(.retain_capacity);
            const bytes = try schema.text(@intCast(column), scratch.allocator());
            hash.update(std.mem.asBytes(&bytes.len));
            hash.update(bytes);
        }
    }
    const tables_query = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    defer tables_query.finalize();
    while (try tables_query.next()) {
        const table = try tables_query.text(0, std.testing.allocator);
        defer std.testing.allocator.free(table);
        var sql: [16384]u8 = undefined;
        var writer = std.Io.Writer.fixed(&sql);
        try writer.writeAll("SELECT ");
        var pragma: [256]u8 = undefined;
        const columns = try db.prepare(try std.fmt.bufPrint(&pragma, "PRAGMA table_info(\"{s}\")", .{table}));
        defer columns.finalize();
        var count: c_int = 0;
        while (try columns.next()) {
            _ = scratch.reset(.retain_capacity);
            const name = try columns.text(1, scratch.allocator());
            if (count > 0) try writer.writeAll(",");
            try writer.print("typeof(\"{s}\")||':'||hex(\"{s}\")", .{ name, name });
            count += 1;
        }
        try writer.print(" FROM \"{s}\" ORDER BY rowid", .{table});
        const rows = try db.prepare(writer.buffered());
        defer rows.finalize();
        while (try rows.next()) {
            var column: c_int = 0;
            while (column < count) : (column += 1) {
                _ = scratch.reset(.retain_capacity);
                const value = try rows.text(column, scratch.allocator());
                hash.update(std.mem.asBytes(&value.len));
                hash.update(value);
            }
        }
    }
    return hash.final();
}

fn expectStoreRefusedUnchanged(db: sqlite.Db, expected: anyerror) !void {
    const before = try databaseFingerprintForTest(db);
    for (0..2) |_| {
        try std.testing.expectError(expected, Store.fromDb(db));
        try std.testing.expectEqual(before, try databaseFingerprintForTest(db));
    }
}

fn expectCurrentRoundTripForTest(store: Store, gs: *GameState) !void {
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(gs), digest.stateHash(&loaded));
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

test "a v5 fixture is refused without changing schema or rows" {
    // Preserve the historical table shapes and rows; adoption must not repair them.
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

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.CorruptStore);
}

test "a v34 fixture is refused without changing schema or rows" {
    // Preserve the historical table shapes and rows; adoption must not repair them.
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

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.CorruptStore);
}

test "a battle report round-trips as fields, not as a row count" {
    const battle = @import("../sim/battle.zig");
    const part_mod = @import("../domain/part.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 90210 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    gs.next_contract_id = 2;
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

test "a fighter engagement preserves shared battle rows and rendered AAR through save load" {
    const battle = @import("../sim/battle.zig");
    const after_action = @import("../sim/after_action.zig");
    const crew = @import("../sim/crew.zig");
    const toe = @import("../sim/toe.zig");
    const seed = rng_mod.seedForFirstRoll(.battle, 6) orelse unreachable;
    var gs = GameState.init(std.testing.allocator, .{ .seed = seed });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    const company = try gs.createForce("Alpha", .company, .none);
    const wing = try gs.createForce("Air Wing", .air_company, company);
    const air_lance = try gs.createForce("Air", .air_lance, wing);
    const fighter = try gs.addUnit("SL-15");
    const pilot = try gs.hirePerson("Air", "Pilot", .aero_pilot);
    const tech = try gs.hirePerson("Air", "Tech", .tech_aero);
    gs.person(pilot).?.assigned_force = air_lance;
    gs.person(tech).?.assigned_force = air_lance;
    try toe.assignUnit(&gs, fighter, air_lance, pilot);
    try crew.assignSlot(&gs, fighter, .tech, tech);
    try gs.recordHullAcquisition(gs.unit(fighter).?, .purchase, "unknown");
    const hull = gs.unit(fighter).?.hull_instance_id;
    const site: types.Site = .{ .company = company };
    try gs.addStock(site, "ammo_ac10", 1);
    try gs.contracts.put(gs.allocator(), @enumFromInt(1), .{
        .id = @enumFromInt(1),
        .kind = .recon_raid,
        .employer_key = "LC",
        .enemy_key = "DC",
        .planet_key = "galatea",
        .terms = .{ .length_months = 3, .base_pay_month = 100_000 },
        .status = .active,
        .assigned_company = company,
    });
    gs.next_contract_id = 2;
    try battle.resolveEngagement(&gs, gs.contracts.getPtr(@enumFromInt(1)).?);
    const report = gs.battle_reports.kept.items[0];
    try std.testing.expect(report.player_power > 0);
    var burned_ac10 = false;
    for (report.ammo) |line| if (std.mem.eql(u8, line.key, "ammo_ac10")) {
        try std.testing.expectEqual(@as(u32, 1), line.burned);
        burned_ac10 = true;
    };
    try std.testing.expect(burned_ac10);
    var fighter_hit = false;
    for (report.hulls) |hit| if (hit.unit == fighter) {
        try std.testing.expectEqualStrings("SL-15", hit.chassis_key);
        fighter_hit = true;
    };
    try std.testing.expect(fighter_hit);
    try std.testing.expectEqual(hull, gs.hull_combat_records.items[0].hull_instance_id);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    const saved = digest.stateHash(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(saved, digest.stateHash(&loaded));
    try std.testing.expectEqual(gs.unit(fighter).?.armor_pct, loaded.unit(fighter).?.armor_pct);
    try std.testing.expectEqual(gs.unit(fighter).?.slots.items.len, loaded.unit(fighter).?.slots.items.len);
    try std.testing.expectEqual(hull, loaded.hull_combat_records.items[0].hull_instance_id);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before_lines = try after_action.render(arena.allocator(), &report);
    const after_lines = try after_action.render(arena.allocator(), &loaded.battle_reports.kept.items[0]);
    try std.testing.expectEqual(before_lines.len, after_lines.len);
    for (before_lines, after_lines) |before_line, after_line| try std.testing.expectEqualStrings(before_line, after_line);
}

test "battle reports beyond forty survive save and load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9_021 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
            .held_field = true,
            .phases = battle_phases_rules.courseForTest(.victory),
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

test "permanent report identities and battle backlinks reject corruption" {
    // The provoked constraint failure is expected; keep its warning out of stderr.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const hull_inst_mod = @import("../domain/hull_instance.zig");
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();

    var hid: types.HullInstanceId = .none;
    var hulls = gs.hull_instances.iterator();
    if (hulls.next()) |entry| hid = entry.key_ptr.*;
    try std.testing.expect(hid != .none);

    for (1..3) |i| try gs.battle_reports.record(gs.allocator(), .{
        .id = @enumFromInt(i),
        .day = @intCast(i),
        .contract = .none,
        .company = .none,
        .kind = "raid",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "plains",
        .weather = "clear",
        .outcome = .victory,
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
    });
    gs.next_battle_id = 3;
    try gs.hull_combat_records.append(gs.allocator(), .{ .hull_instance_id = hid, .battle_id = @enumFromInt(1) });
    try gs.maintenance_entries.append(gs.allocator(), .{
        .hull_instance_id = hid,
        .action = .repair,
        .description = hull_inst_mod.MaintenanceAction.repair.describe(),
        .battle_id = @enumFromInt(1),
    });

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var valid = try store.load(std.testing.allocator, gs.campaign_id);
    defer valid.deinit();

    try std.testing.expectError(error.ConstraintViolation, store.db.exec("INSERT INTO battle_report (cid, ord, id) VALUES (1, 2, 1)"));

    try store.db.exec("DELETE FROM battle_report_phase WHERE report_ord = (SELECT ord FROM battle_report WHERE id = 1); DELETE FROM battle_report WHERE id = 1");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "a hull the enemy holds round-trips, slots and all — off the books, not struck off" {
    const battle = @import("../sim/battle.zig");
    const part_mod = @import("../domain/part.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12007 });
    defer gs.deinit();
    gs.difficulty = .elite; // a lost field is the point of the fixture
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    gs.next_contract_id = 2;
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    try personage_rules.seedForTest(&gs);
    f.c.next_battle_day = gs.clock.day_index + 2;
    f.c.orders_day = f.c.next_battle_day;
    gs.next_contract_id = @intFromEnum(f.c.id) + 1;
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

test "a disbanded company's ledger rows load as outfit overhead, keeping their contract tags" {
    const commands = @import("../sim/commands.zig");
    const treasury = @import("../sim/treasury.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4510 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .quartermaster } });
    const co = (try commands.execute(&gs, .{ .new_company = "Alpha" })).created_force;
    const truck = try gs.addUnit("CGT-3");
    _ = try commands.execute(&gs, .{ .transfer_unit = .{ .unit = truck, .to_company = co } });
    const hand = try gs.hirePerson("Alpha", "Hand", .mekwarrior);
    gs.person(hand).?.assigned_force = co;
    // A company-tagged row, and a closed contract the company held with its
    // contract-tagged rows (the contract record outlives the company).
    try treasury.transferFunds(&gs, .outfit, .{ .company = co }, 1_000, 0);
    const cid: types.ContractId = @enumFromInt(gs.next_contract_id);
    gs.next_contract_id += 1;
    try gs.contracts.put(gs.allocator(), cid, .{ .id = cid, .kind = .garrison_duty, .employer_key = "LC", .enemy_key = "PER", .planet_key = "galatea", .terms = .{ .length_months = 6, .base_pay_month = 400_000 }, .status = .completed, .assigned_company = co });
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = 600_000, .category = .advance, .company = co, .contract = cid, .note = "advance" });
    try gs.postTransaction(.{ .day = gs.clock.day_index, .amount = -500, .category = .supplies, .company = co, .contract = cid, .note = "tagged" });

    _ = try commands.execute(&gs, .{ .disband_company = co });
    try std.testing.expectEqual(types.ForceId.none, gs.contracts.get(cid).?.assigned_company);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expectEqual(contract_mod.ContractStatus.completed, loaded.contracts.get(cid).?.status);
    try std.testing.expectEqual(types.ForceId.none, loaded.contracts.get(cid).?.assigned_company);
    var retagged: usize = 0;
    for (loaded.ledger.transactions.items) |t| {
        try std.testing.expect(t.company != co);
        if (std.mem.eql(u8, t.note, "tagged") or std.mem.eql(u8, t.note, "advance")) {
            try std.testing.expectEqual(types.ForceId.none, t.company);
            try std.testing.expectEqual(cid, t.contract);
            retagged += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), retagged);
}

test "an orphan stock row rejects the load as corrupt, not UnknownSite" {
    // stock.owner_id names a site (hq or company) that is not in the live maps;
    // loadStock must surface this as error.CorruptSave (not the internal error.UnknownSite).
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE stock SET owner_id = 99999 WHERE owner_kind IN ('hq','company')"));
}

test "a duplicate stock row for the same owner and key is rejected by the schema" {
    // The provoked constraint failure is expected; keep its warning out of stderr.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    // Uniqueness of (cid, owner_kind, owner_id, key) is now schema-enforced
    // (UNIQUE constraint on stock, rule 50). The INSERT is rejected at the
    // schema level before the loader sees it; the loader's seen-set guard
    // remains for any non-SQL path.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5005 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const store = try Store.open(":memory:");
    defer store.close();
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8881 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    try store.save(&gs);
    try std.testing.expectError(error.ConstraintViolation, store.db.exec("INSERT INTO person SELECT * FROM person"));
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

test "next_person_id below its owned IDs is corrupt" {
    // Current counters are durable state; an invalid value is refused (rule 48).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8881 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Alpha");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // Drive next_person_id below the max owned id.
    try store.db.exec("UPDATE meta SET value = 0 WHERE key = 'next_person_id'");
    const before = try databaseFingerprintForTest(store.db);
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
}

test "a pending event with an out-of-range default_choice rejects the load" {
    // default_choice >= options.len for the event's kind is corruption (rule 47).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 9991 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("PRAGMA foreign_keys=OFF; UPDATE person SET id=4294967295 WHERE ord=0"));
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

test "a v58 report with a nullable ID is refused without mutation" {
    // The provoked constraint failure is expected; keep its warning out of stderr.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    try raw.exec(
        \\CREATE TABLE setting (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL, save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, UNIQUE (cid, ord));
        \\INSERT INTO setting VALUES ('schema_version', 58);
        \\INSERT INTO campaign VALUES (1, 'Fixture', NULL, 0, '3025-01-01', 58, 1, 0);
        \\INSERT INTO battle_report VALUES (1, 0, NULL);
    );
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "foreign keys are enforced on every connection" {
    // Rule 50: Db.open enables PRAGMA foreign_keys = ON. A deferred FK
    // violation is caught at the auto-commit boundary.
    // The provoked constraint failure is expected; keep its warning out of stderr.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7701 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v36 historical fixture is refused without mutation" {
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
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "a played current campaign round trips and its downgraded store is refused intact" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20_260_924 });
    defer gs.deinit();
    try playedYearForTest(&gs);
    const hash_before = digest.stateHash(&gs);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try raw.exec("UPDATE setting SET value = 36 WHERE key = 'schema_version'");
    defer raw.close();
    try std.testing.expectEqual(@as(u64, 2724787529299733336), digest.nonArtilleryReferenceHash(&gs));
    try std.testing.expectEqual(@as(u64, 13963650456936231268), hash_before);
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "every current next-ID counter is required and never repaired" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 8881 });
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    inline for (.{ "next_person_id", "next_unit_id", "next_force_id", "next_hq_id", "next_contract_id", "next_battle_id", "next_event_id", "next_listing_id", "next_candidate_id", "next_loan_id", "next_operation_id", "next_actor_id", "next_rival_id", "next_officer_arc_id", "next_hull_instance_id", "next_merc_company_id", "next_artillery_formation_id", "next_artillery_offer_id" }) |key| {
        inline for (.{ "UPDATE meta SET value=0 WHERE key='" ++ key ++ "'", "DELETE FROM meta WHERE key='" ++ key ++ "'" }) |sql| {
            try store.save(&gs);
            try store.db.exec(sql);
            const before = try databaseFingerprintForTest(store.db);
            try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
            try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
        }
    }
}

test "a next_battle_id at maxInt rejects the load as corrupt" {
    try std.testing.expectError(error.CorruptSave, loadAfterTampering("UPDATE meta SET value=4294967295 WHERE key='next_battle_id'"));
}

// C7c: current-version no-RNG test and v17/v18 stats recovery.

test "a current-version save draws no RNG and rewrites no counter on load" {
    // Gate: recoverStatsFromLog (< v18) and event id stamping (< v26) must not
    // run on a current-version save. Verify by checking every RNG stream state
    // is byte-for-byte identical before and after load, and next_person_id is
    // unchanged (no counter rewrite beyond the no-op reconciliation).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 5551 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v17 and v18 stores are refused without recovering statistics" {
    // Historical formats remain intact, including their stored statistics.
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
        defer raw.close();
        try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    }
    // The later historical format is independently refused.
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
        defer raw.close();
        try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "a missing current RNG stream is corrupt without a fresh-stream fallback" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6007 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    // A stream added to the game after this campaign was saved has no row.
    try store.db.exec("DELETE FROM rng_stream WHERE stream = 'travel'");
    const before = try databaseFingerprintForTest(store.db);
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
}

test "current missing RNG rows and seed are corrupt even with a valid legacy blob" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6008 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
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
    const before = try databaseFingerprintForTest(store.db);
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
}

/// A campaign that has fought `fights` engagements, every battle decision
/// answered with its default and every report read.
fn foughtCampaignForTest(gs: *GameState, fights: u32) !void {
    _ = try foundCampaignForTest(gs, "T", .LC, .line_officer);
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
    gs.next_contract_id = 2;
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

test "a missing current battle counter is corrupt without renumbering battles" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3004 });
    defer gs.deinit();
    try foughtCampaignForTest(&gs, 3);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    // Saves before the counter was stored carry no `next_battle_id` row.
    try store.db.exec("DELETE FROM meta WHERE key = 'next_battle_id'");
    const before = try databaseFingerprintForTest(store.db);
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
}

test "a battle decision round-trips answerable, and still holds the turn" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 12006 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    gs.next_contract_id = 2;
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
    try personage_rules.seedForTest(&gs);
    gs.next_contract_id = @intFromEnum(f.c.id) + 1;
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    try gs.battle_reports.record(gs.allocator(), .{
        .id = @enumFromInt(4),
        .day = gs.clock.day_index,
        .contract = c.id,
        .company = co,
        .kind = "planetary assault",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "plains",
        .weather = "clear",
        .outcome = .defeat,
        .phases = battle_phases_rules.courseForTest(.defeat),
    });
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
    gs.next_contract_id = 2;
    gs.next_battle_id = 5;
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "Kalmar", .origin = .LC, .profession = .line_officer } });
    const co = (try commands.execute(gs, .{ .new_company = "Alpha" })).created_force;
    var day: u32 = 0;
    while (day < 365) {
        try @import("../sim/tick.zig").clearHolds(gs);
        // The first position with an opposition: a standing need's, with no
        // named threat, would see no fighting.
        if (!posture.isCompanyDeployed(gs, co)) for (gs.contract_offers.items) |*o| if (o.hasOpfor()) {
            _ = commands.execute(gs, .{ .accept_contract = .{ .offer = o.id, .company = co } }) catch {};
            break;
        };
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
    // The digest includes the service checkpoint and typed bay targets. Shared
    // service requires available, physically local technicians and local pool
    // teams (docs/p2-artillery-operations-design.md,
    // Condition, maintenance, repairs and shared hours).
    try std.testing.expectEqual(@as(u64, 2724787529299733336), digest.nonArtilleryReferenceHash(&gs));
    try std.testing.expectEqual(@as(u64, 13963650456936231268), digest.stateHash(&gs));

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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
            .to_day = null,
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
    gs.next_contract_id = 2;
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    gs.next_contract_id = 2;
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
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

test "v41-shaped TEXT version metadata is corrupt and remains unchanged" {
    // Exact metadata storage classes are required even for recognizable old versions.
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
    try expectStoreRefusedUnchanged(store_v41, error.CorruptStore);
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

test "a v38 fixture is refused without changing schema or rows" {
    // Preserve the historical table shapes and rows; adoption must not repair them.
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
        \\INSERT INTO battle_report (cid, ord, id, day, contract, company, outcome, roe) VALUES (1, 0, 1, 0, 1, 0, 'defeat', 'standard');
    );
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "a v37 fixture is refused without changing schema or rows" {
    // Preserve the historical table shapes and rows; adoption must not repair them.
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
    // Unsupported adoption must not create the absent operation table.
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "non-default op.intent and non-null operation_intent round-trip through save/load" {
    // Rule 47: the non-default save branch (@tagName(op.intent)) and the
    // non-empty load branch (stringToEnum orelse CorruptSave) for both
    // operation.intent and battle_report.operation_intent are exercised here.
    // The default value for both columns is 'secure_objective' / ''; this test
    // stores '.break_enemy' and '.preserve_force' to reach the non-default paths.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 4301 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
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

test "v40 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 55007 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
        .score_delta = 2,
        .score_after = 2,
        .command_rights = "independent",
        .acknowledged = true,
    });
    gs.next_battle_id = 2;

    const raw = try sqlite.Db.open(":memory:");
    const s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);
    try raw.exec("DROP TABLE IF EXISTS operation_task");
    try raw.exec("DROP TABLE IF EXISTS battle_report_task");
    try raw.exec("UPDATE setting SET value = 40 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 40");

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
            _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v42 historical fixture is refused without mutation" {
    var store_v42 = try sqlite.Db.open(":memory:");
    defer store_v42.close();
    try store_v42.exec(
        \\CREATE TABLE setting (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
        \\INSERT INTO setting VALUES ('schema_version', 42);
        \\CREATE TABLE campaign (id INTEGER PRIMARY KEY, name TEXT NOT NULL, commander TEXT, day INTEGER NOT NULL, date TEXT NOT NULL, schema_version INTEGER NOT NULL CHECK (schema_version > 0), save_seq INTEGER NOT NULL, player_id INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE contract (cid INTEGER NOT NULL, is_offer INTEGER NOT NULL CHECK (is_offer IN (0,1)), ord INTEGER NOT NULL, id INTEGER, kind TEXT, employer TEXT, enemy TEXT, planet TEXT, status TEXT, company INTEGER, start_day INTEGER, score INTEGER, dist_ly INTEGER, beachhead INTEGER, transit_days INTEGER, arrive_day INTEGER, end_day INTEGER, monthly_net INTEGER, next_battle INTEGER, battles INTEGER, casualties INTEGER, objective TEXT, committed_bv INTEGER, pool INTEGER, pool_remaining INTEGER, vp INTEGER, ineffective_since INTEGER, breach_day INTEGER, length_months INTEGER, base_pay INTEGER, advance_pct INTEGER, signing_bonus INTEGER, transport_pct INTEGER, overhead_pct INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, salvage_exchange INTEGER CHECK (salvage_exchange IN (0,1)), command_rights TEXT, negotiated INTEGER NOT NULL DEFAULT 0 CHECK (negotiated IN (0,1)), enemy_lances INTEGER NOT NULL DEFAULT 0, enemy_quality TEXT NOT NULL DEFAULT 'regular', enemy_lance_bv INTEGER NOT NULL DEFAULT 0, enemy_lance_tons INTEGER NOT NULL DEFAULT 0, offer_hq INTEGER NOT NULL DEFAULT 0, orders_day INTEGER, arc_key TEXT NOT NULL DEFAULT '', arc_beat INTEGER NOT NULL DEFAULT 0, escalation_clock INTEGER NOT NULL DEFAULT 0, arc_finale_key TEXT NOT NULL DEFAULT '', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\CREATE TABLE operation (cid INTEGER NOT NULL, contract_id INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, template_key TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT NOT NULL, opened_day INTEGER NOT NULL, resolved_day INTEGER, committed_day INTEGER, intent TEXT NOT NULL DEFAULT 'secure_objective', tempo TEXT NOT NULL DEFAULT 'advance', FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
        \\CREATE TABLE battle_report (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER, day INTEGER, contract INTEGER, company INTEGER, kind TEXT, enemy_key TEXT, scenario TEXT, terrain TEXT, weather TEXT, outcome TEXT, held_field INTEGER, withdrew INTEGER, roe TEXT, roe_overridden INTEGER, player_power INTEGER, enemy_power INTEGER, conditions_mod INTEGER, close_terrain INTEGER, air_grounded INTEGER, convoy_hit INTEGER, edge_spent_by TEXT, recon_quality INTEGER, avg_fatigue INTEGER, avg_morale INTEGER, hits_taken INTEGER, destroyed INTEGER, wounded INTEGER, kia INTEGER, lost_hulls INTEGER, missing INTEGER, enemy_destroyed_bv INTEGER, kills_credited INTEGER, prisoners INTEGER, battle_loss_comp INTEGER, score_after INTEGER, score_delta INTEGER, morale_delta INTEGER, fatigue_add INTEGER, battle_loss_pct INTEGER, salvage_pct INTEGER, command_rights TEXT, silenced_mounts INTEGER, armor_left INTEGER, salvage_claimed INTEGER, salvage_haulable INTEGER, salvage_cut INTEGER, salvage_cash INTEGER, salvage_items TEXT, conceded INTEGER, acknowledged INTEGER NOT NULL DEFAULT 1 CHECK (acknowledged IN (0,1)), salvage_unclaimed INTEGER NOT NULL DEFAULT 0, operation TEXT NOT NULL DEFAULT '', operation_intent TEXT NOT NULL DEFAULT '', operation_tempo TEXT NOT NULL DEFAULT '', UNIQUE (cid, ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);
    );
    try expectStoreRefusedUnchanged(store_v42, error.CorruptStore);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v43 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 20002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try raw.exec("DROP TABLE actor");
    try raw.exec("DELETE FROM meta WHERE key = 'next_actor_id'");
    try raw.exec("UPDATE setting SET value = 43 WHERE key = 'schema_version'");
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v44 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 30002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try raw.exec("DROP TABLE world_state");
    try raw.exec("UPDATE setting SET value = 44 WHERE key = 'schema_version'");
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v45 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 40002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try raw.exec("DROP TABLE rival");
    try raw.exec("DELETE FROM meta WHERE key = 'next_rival_id'");
    try raw.exec("UPDATE setting SET value = 45 WHERE key = 'schema_version'");
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v46 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try raw.exec("DROP TABLE officer_arc");
    try raw.exec("DELETE FROM meta WHERE key = 'next_officer_arc_id'");
    try raw.exec("UPDATE setting SET value = 46 WHERE key = 'schema_version'");
    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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

test "next_officer_arc_id below its owned IDs is corrupt" {
    // Rule 70 / P4i: next_officer_arc_id must be >= 1 and above every owned id after load.
    var gs = try buildOfficerGs(std.testing.allocator);
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);

    // Drive the durable counter below the maximum owned ID; no repair is permitted.
    try store.db.exec("UPDATE meta SET value = 0 WHERE key = 'next_officer_arc_id'");
    const before = try databaseFingerprintForTest(store.db);
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
}

// P3c.1 hull instance tests ------------------------------------------------

/// Build a GameState with two directly-added units and two crafted HullInstances,
/// isolated from generation seeding (P3c.5). Two named instances (id=1 and id=2)
/// are the owners of the two units. Returns the gs ready for save; caller must deinit.
fn buildHullGs(alloc: std.mem.Allocator) !GameState {
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(alloc, .{ .seed = 30001 });
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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

test "v47 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 30002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Gamma");
    const owned_count = gs.units.count();
    try std.testing.expect(owned_count > 0);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);

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

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
            "CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0, owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_merc_company_id INTEGER NOT NULL DEFAULT 0, catalogue TEXT NOT NULL DEFAULT 'chassis');" ++
            "INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id, catalogue FROM hull_instance_bak;" ++
            "INSERT INTO hull_instance SELECT cid, 999, id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id, catalogue FROM hull_instance_bak LIMIT 1;" ++
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
    try gs.battle_reports.record(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 0,
        .contract = .none,
        .company = .none,
        .kind = "raid",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "plains",
        .weather = "clear",
        .outcome = .victory,
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
    });
    gs.next_battle_id = 2;

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
    try gs.battle_reports.record(gs.allocator(), .{
        .id = @enumFromInt(1),
        .day = 0,
        .contract = .none,
        .company = .none,
        .kind = "raid",
        .enemy_key = "DC",
        .scenario = "probe",
        .terrain = "plains",
        .weather = "clear",
        .outcome = .victory,
        .held_field = true,
        .phases = battle_phases_rules.courseForTest(.victory),
    });
    gs.next_battle_id = 2;

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
        .to_day = null,
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
    try std.testing.expectEqual(@as(?u32, 50), r0.to_day);
    try std.testing.expectEqual(hull_inst_mod.AcquisitionType.purchase, r0.acquisition_type);
    try std.testing.expectEqualStrings("unknown", r0.prior_owner_key);

    const r1 = loaded.hull_ownership_history.items[1];
    try std.testing.expectEqual(hids[1], r1.hull_instance_id);
    try std.testing.expectEqual(@as(u32, 55), r1.from_day);
    try std.testing.expectEqual(@as(?u32, null), r1.to_day);
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
        .to_day = null,
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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
    try gs.merc_companies.put(a, mid, merc_company_mod.MercCompany{ .id = mid, .archetype_key = "enemy_raiders", .commander_first = "Ann", .commander_last = "Smith", .unit_name = "Smith Raiders", .faction_key = "DC", .side = .enemy, .doctrine = .aggressive, .band_key = "band_4", .home_planet_key = "luthien" });
    try gs.merc_company_rosters.put(a, mid, .empty);
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

test "v51 historical fixture is refused without mutation" {
    var gs = try buildHullGs(std.testing.allocator);
    defer gs.deinit();
    const hull_count = gs.hull_instances.count();
    try std.testing.expect(hull_count > 0);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);

    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("ALTER TABLE hull_instance RENAME TO hull_instance_v52;" ++
        "CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);" ++
        "INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign FROM hull_instance_v52;" ++
        "DROP TABLE hull_instance_v52");
    try raw.exec("UPDATE setting SET value = 51 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 51");
    try raw.exec("PRAGMA foreign_keys = ON");

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

// P3e.3: faction_roster + rival_roster persistence (rules 47, 67, 69).

fn buildRosterGs(alloc: std.mem.Allocator) !GameState {
    const hull_mod = @import("../domain/hull_instance.zig");
    var gs = GameState.init(alloc, .{ .seed = 50001 });
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .band_key = "band_4",
        .home_planet_key = "luthien",
    });
    gs.next_merc_company_id = 2;

    // Five hull instances, including replenishing conventional vehicle/fighter
    // purchases owned by the merc company.
    const hid1: types.HullInstanceId = @enumFromInt(1);
    const hid2: types.HullInstanceId = @enumFromInt(2);
    const hid3: types.HullInstanceId = @enumFromInt(3);
    const hid4: types.HullInstanceId = @enumFromInt(4);
    const hid5: types.HullInstanceId = @enumFromInt(5);
    try gs.hull_instances.put(a, hid1, .{ .id = hid1, .base_key = "LCT-1V", .status = .active, .owner = .{ .faction = "DC" } });
    try gs.hull_instances.put(a, hid2, .{ .id = hid2, .base_key = "JR7-D", .status = .active, .owner = .{ .faction = "DC" } });
    try gs.hull_instances.put(a, hid3, .{ .id = hid3, .base_key = "LCT-1V", .status = .active, .owner = .{ .merc_company = mcid1 } });
    for ([_]struct { id: types.HullInstanceId, key: []const u8 }{ .{ .id = hid4, .key = "SCP-1N" }, .{ .id = hid5, .key = "TR-7" } }) |entry| {
        const chassis = @import("../domain/chassis.zig").find(entry.key).?;
        var hull: hull_mod.HullInstance = .{ .id = entry.id, .base_key = chassis.key, .intro_year = chassis.intro_year, .owner = .{ .merc_company = mcid1 } };
        for (chassis.loadout) |slot| try hull.loadout.append(a, .{ .part_key = slot.part });
        try gs.hull_instances.put(a, entry.id, hull);
        try gs.hull_ownership_history.append(a, .{ .hull_instance_id = entry.id, .acquisition_type = .purchase, .prior_owner_key = "market" });
    }
    gs.next_hull_instance_id = 6;

    // Faction roster: DC owns hulls 1 and 2 (multi-element, tests order preservation).
    const fr_gop = try gs.faction_rosters.getOrPut(a, "DC");
    if (!fr_gop.found_existing) fr_gop.value_ptr.* = .empty;
    try fr_gop.value_ptr.append(a, hid1);
    try fr_gop.value_ptr.append(a, hid2);

    // Merc company roster: one mek plus minted vehicle and fighter.
    const mrit_gop = try gs.merc_company_rosters.getOrPut(a, mcid1);
    if (!mrit_gop.found_existing) mrit_gop.value_ptr.* = .empty;
    try mrit_gop.value_ptr.append(a, hid3);
    try mrit_gop.value_ptr.append(a, hid4);
    try mrit_gop.value_ptr.append(a, hid5);

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
    try std.testing.expectEqual(@as(usize, 3), mc_list.items.len);
    const hid3: types.HullInstanceId = @enumFromInt(3);
    try std.testing.expectEqual(hid3, mc_list.items[0]);
    const hid4: types.HullInstanceId = @enumFromInt(4);
    const hid5: types.HullInstanceId = @enumFromInt(5);
    try std.testing.expectEqual(hid4, mc_list.items[1]);
    try std.testing.expectEqual(hid5, mc_list.items[2]);
    try std.testing.expectEqual(@as(usize, @import("../domain/chassis.zig").find("SCP-1N").?.loadout.len), loaded.hull_instances.get(hid4).?.loadout.items.len);
    try std.testing.expectEqual(@as(usize, @import("../domain/chassis.zig").find("TR-7").?.loadout.len), loaded.hull_instances.get(hid5).?.loadout.items.len);
    try std.testing.expectEqual(@as(u32, 6), loaded.next_hull_instance_id);
    try @import("../sim/merc_lifecycle.zig").runMercLifecycle(&gs);
    try @import("../sim/merc_lifecycle.zig").runMercLifecycle(&loaded);
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
}

test "a dissolved merc company's empty roster survives a save/load round-trip" {
    // Rules 47, 53: every merc company keeps a roster entry, and an empty one
    // has no rows; the loader restores it, so the digest is unchanged.
    var gs = try buildRosterGs(std.testing.allocator);
    defer gs.deinit();
    const mcid1: types.MercCompanyId = @enumFromInt(1);
    try @import("../sim/merc_lifecycle.zig").liquidateMercCompany(&gs, gs.allocator(), mcid1, 1);
    try std.testing.expectEqual(@as(usize, 0), gs.merc_company_rosters.get(mcid1).?.items.len);
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(@as(usize, 0), loaded.merc_company_rosters.get(mcid1).?.items.len);
}

test "v52 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);

    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("DROP TABLE IF EXISTS faction_roster");
    try raw.exec("DROP TABLE IF EXISTS merc_company_roster");
    try raw.exec("DROP TABLE IF EXISTS merc_company");
    try raw.exec("UPDATE setting SET value = 52 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 52");
    try raw.exec("PRAGMA foreign_keys = ON");

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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

test "a merc_company_roster row keyed by no company id rejects the load as corrupt" {
    // Rule 47: zero rows are an empty roster, but a row keyed by `.none` is corruption.
    try std.testing.expectError(error.CorruptSave, loadRosterAfterTampering(
        "UPDATE merc_company_roster SET merc_company_id = 0 WHERE merc_company_id = 1",
    ));
}

test "a merc_company_roster row naming no hull instance rejects the load as corrupt" {
    // Rule 47: every merc_company_roster hull_instance_id must resolve to a live hull instance.
    try std.testing.expectError(error.CorruptSave, loadRosterAfterTampering(
        "UPDATE merc_company_roster SET hull_instance_id = 99999 WHERE hull_instance_id = 3",
    ));
}

test "a replacement company that bought nothing keeps its empty roster across save/load" {
    // Rules 47, 53: a spawn on an empty market holds an empty roster entry,
    // and the reloaded campaign has the same entry and digest.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50040 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    gs.market_listings.clearRetainingCapacity();
    var rng = gs.rng;
    const spawned = try @import("../sim/merc_lifecycle.zig").spawnReplacementCompany(&gs, gs.allocator(), 0, &rng);
    gs.rng = rng;
    try std.testing.expectEqual(@as(usize, 0), gs.merc_company_rosters.get(spawned).?.items.len);
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(@as(usize, 0), loaded.merc_company_rosters.get(spawned).?.items.len);
}

// P3e entity split: merc company save/load and migration tests.

test "merc companies survive a save/load round-trip with identical stateHash (P3e entity split)" {
    // Rules 45, 46, 53, 67 / P3e entity split: a campaign holding merc_companies survives
    // save → load with identical stateHash; firstStateDifference is empty; archetype/
    // side/doctrine/unit_name survive; rule 69 round-trip proof for the new collection.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50020 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .band_key = "band_4",
        .home_planet_key = "luthien",
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
        .band_key = "band_1_2",
        .home_planet_key = "tharkad",
    };
    try gs.merc_companies.put(a, mc1.id, mc1);
    try gs.merc_companies.put(a, mc2.id, mc2);
    try gs.merc_company_rosters.put(a, mc1.id, .empty);
    try gs.merc_company_rosters.put(a, mc2.id, .empty);
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

test "a suffixed merc company name and a logo-less merc company survive save and load" {
    // Seed 26 founds "Quintana Assault" and "Quintana Assault II" (merc_identity.unitName).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 26 });
    defer gs.deinit();
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const suffixed: types.MercCompanyId = @enumFromInt(11);
    try std.testing.expectEqualStrings("Quintana Assault II", gs.merc_companies.get(suffixed).?.unit_name);
    const logo_less: types.MercCompanyId = @enumFromInt(gs.next_merc_company_id);
    try gs.merc_companies.put(gs.allocator(), logo_less, .{
        .id = logo_less,
        .archetype_key = "enemy_raiders",
        .commander_first = "Bo",
        .commander_last = "Rex",
        .unit_name = "Rex Raiders",
        .faction_key = "DC",
        .band_key = "band_1_2",
        .home_planet_key = "luthien",
    });
    try gs.merc_company_rosters.put(gs.allocator(), logo_less, .empty);
    gs.next_merc_company_id += 1;
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();

    var diff_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqualStrings("Quintana Assault II", loaded.merc_companies.get(suffixed).?.unit_name);
    try std.testing.expectEqualStrings("", loaded.merc_companies.get(logo_less).?.logo_key);
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

test "v53 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 50030 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    const a = gs.allocator();

    const hid1: types.HullInstanceId = @enumFromInt(1);
    try gs.hull_instances.put(a, hid1, .{ .id = hid1, .base_key = "LCT-1V", .status = .active });
    gs.next_hull_instance_id = 2;

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);

    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("ALTER TABLE hull_instance RENAME TO hull_instance_v54;" ++
        "CREATE TABLE hull_instance (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, base_key TEXT, name TEXT, nickname TEXT, status TEXT NOT NULL DEFAULT 'active', intro_year INTEGER NOT NULL DEFAULT 0, pre_campaign INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), owner_type TEXT NOT NULL DEFAULT 'player', owner_faction_key TEXT NOT NULL DEFAULT '', owner_rival_id INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);" ++
        "INSERT INTO hull_instance SELECT cid, ord, id, base_key, name, nickname, status, intro_year, pre_campaign, owner_type, owner_faction_key, owner_merc_company_id FROM hull_instance_v54;" ++
        "DROP TABLE hull_instance_v54");
    try raw.exec("INSERT INTO hull_instance VALUES (1, 99, 777, 'LCT-1V', NULL, NULL, 'active', 2750, 0, 'rival', '', 7)");
    try raw.exec("ALTER TABLE rival RENAME TO rival_v54;" ++
        "CREATE TABLE rival (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, contract INTEGER NOT NULL DEFAULT 0, standing INTEGER NOT NULL DEFAULT 0, encounters INTEGER NOT NULL DEFAULT 1, last_cause TEXT NOT NULL DEFAULT '', last_cause_day INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)), PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED);" ++
        "INSERT INTO rival SELECT cid, ord, id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine, contract, standing, encounters, last_cause, last_cause_day, recurring FROM rival_v54;" ++
        "DROP TABLE rival_v54");
    try raw.exec("CREATE TABLE rival_roster (cid INTEGER NOT NULL, ord INTEGER NOT NULL, rival_id INTEGER NOT NULL, hull_instance_id INTEGER NOT NULL, FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED)");
    try raw.exec("DROP TABLE IF EXISTS merc_company");
    try raw.exec("DROP TABLE IF EXISTS merc_company_roster");
    try raw.exec("UPDATE setting SET value = 53 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 53");
    try raw.exec("PRAGMA foreign_keys = ON");

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

// P3f.4: merc company lifecycle — save/load and migration tests.

test "MercCompany save/load round-trip with all four new fields non-default (P3f.4)" {
    // Rules 45, 46, 53, 67 / P3f.4: a campaign with non-default cbills/founded_day/
    // dissolved_day/logo_key survives save → load with identical stateHash; the four
    // new fields round-trip exactly.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 58001 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .band_key = "band_5",
        .home_planet_key = "luthien",
        .ready_day = 42,
    };
    try gs.merc_companies.put(a, mc1.id, mc1);
    try gs.merc_company_rosters.put(a, mc1.id, .empty);
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
    try std.testing.expectEqualStrings("band_5", lmc.band_key);
}

test "merc company understrength_since round-trips null and set; a negative, non-integer or future day is CorruptSave" {
    // Rules 47, 53, 70; docs/p5d-conflict-world-design.md §J.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 69001 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    // Stay inside the campaign's first month, where its market offers are dated.
    for (0..20) |_| gs.clock.advance();
    const a = gs.allocator();
    for ([_]?u32{ null, 10 }, 1..) |since, i| {
        const id: types.MercCompanyId = @enumFromInt(@as(u32, @intCast(i)));
        try gs.merc_companies.put(a, id, .{
            .id = id,
            .archetype_key = "enemy_raiders",
            .unit_name = if (since == null) "Even Co" else "Short Co",
            .faction_key = "DC",
            .band_key = "band_3",
            .home_planet_key = "luthien",
            .understrength_since = since,
        });
        try gs.merc_company_rosters.put(a, id, .empty);
    }
    gs.next_merc_company_id = 3;
    const before = digest.stateHash(&gs);

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    {
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        var diff_buf: [128]u8 = undefined;
        try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
        try std.testing.expectEqual(before, digest.stateHash(&loaded));
        try std.testing.expectEqual(@as(?u32, null), loaded.merc_companies.get(@enumFromInt(1)).?.understrength_since);
        try std.testing.expectEqual(@as(?u32, 10), loaded.merc_companies.get(@enumFromInt(2)).?.understrength_since);
    }
    // The field is digest-covered: a different day is a different campaign.
    gs.merc_companies.getPtr(@enumFromInt(2)).?.understrength_since = 11;
    try std.testing.expect(digest.stateHash(&gs) != before);

    var sql: [160:0]u8 = undefined;
    // Today itself is valid; one day later is not.
    try store.db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE merc_company SET understrength_since = {d} WHERE cid = {d} AND id = 2", .{ gs.clock.day_index, gs.campaign_id }));
    {
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(?u32, gs.clock.day_index), loaded.merc_companies.get(@enumFromInt(2)).?.understrength_since);
    }
    try store.db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE merc_company SET understrength_since = {d} WHERE cid = {d} AND id = 2", .{ gs.clock.day_index + 1, gs.campaign_id }));
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    // Rule 50: the schema refuses an out-of-range or non-integer day; the
    // loader refuses the same values when CHECK is bypassed.
    for ([_][]const u8{ "-1", "'sixty'", "1.5", "4294967296" }) |value| {
        const tamper = try std.fmt.bufPrintZ(&sql, "UPDATE merc_company SET understrength_since = {s} WHERE cid = {d} AND id = 2", .{ value, gs.campaign_id });
        try std.testing.expectError(error.ConstraintViolation, store.db.exec(tamper));
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
}

/// A created campaign whose merc companies carry a non-default ready day,
/// a Periphery company, and one hull en route to its company's base; returns
/// that hull.
fn npcBaseCampaignForTest(gs: *GameState) !types.HullInstanceId {
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    // Ten days in, inside the first month where its market offers are dated,
    // so a day before today is a valid founding day.
    for (0..10) |_| gs.clock.advance();
    const companies = gs.merc_companies.values();
    // A Periphery company: seeded, or company 1 rebased as one.
    const periphery = for (companies) |*c| {
        if (std.mem.eql(u8, c.faction_key, "PER")) break c;
    } else blk: {
        companies[0].faction_key = "PER";
        companies[0].home_planet_key = "star_s_end";
        break :blk &companies[0];
    };
    periphery.ready_day = periphery.founded_day + 5;
    const carrier = companies[if (periphery == &companies[0]) 1 else 0].id;
    const hull = gs.merc_company_rosters.get(carrier).?.items[0];
    try gs.merc_hull_arrivals.put(gs.allocator(), hull, gs.clock.day_index + 20);
    return hull;
}

test "merc company bases, ready days and hull arrivals survive save and load, move the digest, and play on identically" {
    // Rules 45, 46, 53, 70; docs/p5d-conflict-world-design.md §L1.
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 76201 });
    defer gs.deinit();
    const hull = try npcBaseCampaignForTest(&gs);
    try npc_base.validate(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    for (gs.merc_companies.values(), loaded.merc_companies.values()) |c, l| {
        try std.testing.expectEqualStrings(c.home_planet_key, l.home_planet_key);
        // A loaded base is held in catalog memory.
        try std.testing.expectEqual(planet_mod.find(c.home_planet_key).?.key.ptr, l.home_planet_key.ptr);
        try std.testing.expectEqual(c.ready_day, l.ready_day);
    }
    try std.testing.expectEqual(gs.merc_hull_arrivals.get(hull).?, loaded.merc_hull_arrivals.get(hull).?);

    // Each new field moves the digest.
    const hash = digest.stateHash(&gs);
    const company = &gs.merc_companies.values()[0];
    try expectChangeMovesDigestForTest(&gs, hash, &company.home_planet_key, if (std.mem.eql(u8, company.home_planet_key, "tharkad")) "skye" else "tharkad");
    try expectChangeMovesDigestForTest(&gs, hash, &company.ready_day, company.ready_day + 1);
    try expectChangeMovesDigestForTest(&gs, hash, gs.merc_hull_arrivals.getPtr(hull).?, gs.merc_hull_arrivals.get(hull).? + 1);
    try std.testing.expectEqual(hash, digest.stateHash(&gs));
    try std.testing.expectEqual(GameState.Persistence.persisted, GameState.persistenceOf("merc_hull_arrivals"));

    // Both play on past the arrival and a month start identically; the
    // monthly pass drops the arrived hull's entry.
    for ([_]*GameState{ &gs, &loaded }) |g| {
        var firsts: usize = 0;
        while (firsts < 2) {
            try @import("../sim/tick.zig").clearHolds(g);
            _ = try commands.execute(g, .{ .advance_days = 1 });
            if (g.clock.date.day == 1) firsts += 1;
        }
        try std.testing.expect(!g.merc_hull_arrivals.contains(hull));
    }
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try store.save(&loaded);
    try expectCurrentRoundTripForTest(store, &loaded);
}

test "a broken merc company base, ready day or hull arrival is refused as corrupt" {
    // Rules 47, 50, 70; docs/p5d-conflict-world-design.md §L1 (evidence:
    // load refuses an unknown world).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 76202 });
    defer gs.deinit();
    const hull = try npcBaseCampaignForTest(&gs);
    const periphery = for (gs.merc_companies.values()) |c| {
        if (std.mem.eql(u8, c.faction_key, "PER")) break c.id;
    } else unreachable;
    const owner = gs.hull_instances.get(hull).?.owner.merc_company;
    const faction_hull = gs.faction_rosters.values()[0].items[0];
    const Case = struct { name: []const u8, sql: []const u8 };
    var sql: [4][256:0]u8 = undefined;
    const cases = [_]Case{
        .{ .name = "a base that is no world", .sql = "UPDATE merc_company SET home_planet_key = 'nowhere' WHERE ord = 0" },
        .{ .name = "an empty base", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_company SET home_planet_key = '' WHERE ord = 0" },
        .{ .name = "a Periphery company on Galatea, its faction's capital but an LC world", .sql = try std.fmt.bufPrintZ(&sql[0], "UPDATE merc_company SET home_planet_key = 'galatea' WHERE id = {d}", .{@intFromEnum(periphery)}) },
        .{ .name = "a ready day before the founding day", .sql = "UPDATE merc_company SET founded_day = 5, ready_day = 4 WHERE ord = 0" },
        .{ .name = "a negative ready day", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_company SET ready_day = -1 WHERE ord = 0" },
        .{ .name = "an arrival for no hull", .sql = "PRAGMA foreign_keys=OFF; UPDATE merc_hull_arrival SET hull_instance_id = 4000000" },
        .{ .name = "an arrival for a hull of none", .sql = "PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET hull_instance_id = 0" },
        .{ .name = "an arrival for a faction's hull", .sql = try std.fmt.bufPrintZ(&sql[1], "UPDATE merc_hull_arrival SET hull_instance_id = {d}", .{@intFromEnum(faction_hull)}) },
        .{ .name = "an arrival its owner's roster does not hold", .sql = try std.fmt.bufPrintZ(&sql[2], "DELETE FROM merc_company_roster WHERE hull_instance_id = {d}", .{@intFromEnum(hull)}) },
        .{ .name = "an arrival of a dissolved company", .sql = try std.fmt.bufPrintZ(&sql[3], "UPDATE merc_company SET dissolved_day = 1 WHERE id = {d}", .{@intFromEnum(owner)}) },
        .{ .name = "a negative arrival day", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET arrive_day = -1" },
        .{ .name = "an arrival out of its order", .sql = "UPDATE merc_hull_arrival SET ord = 5" },
        // Values SQLite's integer and text readers would coerce into a
        // valid-looking day, base, ordinal or hull (rule 47).
        .{ .name = "a text ready day", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_company SET founded_day = 0, ready_day = 'soon' WHERE ord = 0" },
        .{ .name = "a fractional ready day", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_company SET founded_day = 0, ready_day = 0.5 WHERE ord = 0" },
        .{ .name = "a base stored as a blob", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_company SET home_planet_key = CAST(home_planet_key AS BLOB) WHERE ord = 0" },
        .{ .name = "a text arrival ordinal", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET ord = 'first'" },
        .{ .name = "a fractional arrival ordinal", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET ord = 0.5" },
        .{ .name = "a fractional arrival hull", .sql = "PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET hull_instance_id = hull_instance_id + 0.5" },
        .{ .name = "a text arrival day", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET arrive_day = 'soon'" },
        .{ .name = "a fractional arrival day", .sql = "PRAGMA ignore_check_constraints=ON; UPDATE merc_hull_arrival SET arrive_day = arrive_day + 0.5" },
    };
    for (cases) |case| {
        errdefer std.debug.print("arrival or base case: {s}\n", .{case.name});
        const store = try Store.open(":memory:");
        defer store.close();
        try saveAsNewForTest(store, &gs);
        var tamper: [512:0]u8 = undefined;
        try store.db.exec(try std.fmt.bufPrintZ(&tamper, "{s}; PRAGMA ignore_check_constraints=OFF; PRAGMA foreign_keys=ON", .{case.sql}));
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    // The schema refuses a duplicate arrival, an empty base and an
    // out-of-range day outright (rule 50).
    const store = try Store.open(":memory:");
    defer store.close();
    try saveAsNewForTest(store, &gs);
    var tamper: [256:0]u8 = undefined;
    for ([_][:0]const u8{
        try std.fmt.bufPrintZ(&tamper, "INSERT INTO merc_hull_arrival SELECT cid, ord + 1, hull_instance_id, arrive_day FROM merc_hull_arrival", .{}),
        "UPDATE merc_company SET home_planet_key = '' WHERE ord = 0",
        "UPDATE merc_company SET ready_day = 4294967296 WHERE ord = 0",
        "UPDATE merc_hull_arrival SET arrive_day = 'soon'",
    }) |statement| try std.testing.expectError(error.ConstraintViolation, store.db.exec(statement));
    try expectCurrentRoundTripForTest(store, &gs);
}

test "v57 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 58002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .band_key = "band_4",
        .home_planet_key = "luthien",
    };
    try gs.merc_companies.put(a, mc1.id, mc1);
    try gs.merc_company_rosters.put(a, mc1.id, .empty);
    gs.next_merc_company_id = 2;

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);

    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("ALTER TABLE merc_company RENAME TO merc_company__bak");
    try raw.exec("CREATE TABLE merc_company (cid INTEGER NOT NULL, ord INTEGER NOT NULL, id INTEGER NOT NULL, archetype_key TEXT NOT NULL, commander_first TEXT NOT NULL, commander_last TEXT NOT NULL, unit_name TEXT NOT NULL, faction_key TEXT NOT NULL, side TEXT NOT NULL, doctrine TEXT NOT NULL, PRIMARY KEY (cid, id), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED)");
    try raw.exec("INSERT INTO merc_company SELECT cid, ord, id, archetype_key, commander_first, commander_last, unit_name, faction_key, side, doctrine FROM merc_company__bak");
    try raw.exec("DROP TABLE merc_company__bak");
    try raw.exec("UPDATE setting SET value = 57 WHERE key = 'schema_version'");
    try raw.exec("PRAGMA foreign_keys = ON");

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "v50 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 30003 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Delta");
    const owned_count = gs.units.count();
    try std.testing.expect(owned_count > 0);

    const raw = try sqlite.Db.open(":memory:");
    var s1 = try Store.fromDb(raw);
    try s1.save(&gs);
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);

    try raw.exec("PRAGMA foreign_keys = OFF");
    try raw.exec("DROP TABLE hull_ownership_history");
    try raw.exec("UPDATE setting SET value = 50 WHERE key = 'schema_version'");
    try raw.exec("UPDATE campaign SET schema_version = 50");
    try raw.exec("PRAGMA foreign_keys = ON");

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
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
    try std.testing.expectEqual(merc_band.seedTotal(), gs.merc_companies.count());

    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    {
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();

        var diff_buf: [128]u8 = undefined;
        try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &diff_buf) orelse "");
        try std.testing.expectEqual(before, digest.stateHash(&loaded));
        try std.testing.expectEqual(gs.merc_companies.count(), loaded.merc_companies.count());
        try std.testing.expectEqual(gs.merc_company_rosters.count(), loaded.merc_company_rosters.count());
        // Every company's band survives, resolved to its static table row.
        for (gs.merc_companies.values(), loaded.merc_companies.values()) |saved, restored| {
            try std.testing.expectEqualStrings(saved.band_key, restored.band_key);
            try std.testing.expectEqual(merc_band.find(saved.band_key).?.key.ptr, restored.band_key.ptr);
        }
    }

    // A band key no table row names is corruption, never a default band.
    var sql: [128:0]u8 = undefined;
    try store.db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE merc_company SET band_key = 'band_6' WHERE cid = {d} AND id = 1", .{gs.campaign_id}));
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "P3e.6: surplus listing hull_instance_id round-trips through save/load" {
    // Rules 45, 46, 53: a listing with hull_instance_id set saves and reloads
    // with the id preserved and the digest unchanged.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56001 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .to_day = null,
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

test "P3e.6: v55 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

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
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);

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

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "P3e.6: a listing with hull_instance_id naming no hull is rejected as corrupt" {
    // Rules 47/48/70: a listing row whose hull_instance_id names no hull instance
    // must be rejected with CorruptSave by validateReferences.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 56003 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

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
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
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
        .to_day = null,
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

test "P3f.1: v56 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 57002 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);

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
    try expectCurrentRoundTripForTest(s1, &gs);
    try removeArtilleryFromLegacyFixture(raw);

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

    defer raw.close();
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

fn removeArtilleryFromLegacyFixture(db: sqlite.Db) !void {
    try db.exec("DELETE FROM retired_hq; DELETE FROM meta WHERE key='retired_hq_count'");
    try db.exec("DELETE FROM artillery_offer; DELETE FROM artillery_formation; DELETE FROM meta WHERE key IN ('next_artillery_formation_id','next_artillery_offer_id','artillery_offer_count')");
}

fn artilleryCampaignForTest(gs: *GameState) !types.ArtilleryFormationId {
    const commands = @import("../sim/commands.zig");
    const home = try foundCampaignForTest(gs, "T", .LC, .quartermaster);
    gs.hqs.getPtr(home).?.funds = artillery.purchasePrice() * 10;
    return (try commands.execute(gs, .{ .buy_artillery = .{ .hq = home, .offer = gs.artillery_offers.items[0].id } })).artillery_formation;
}

test "artillery disposal followed by real HQ sale preserves save-load history" {
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .quartermaster);
    gs.funds = 500_000_000;
    const created = try commands.execute(&gs, .{ .found_hq = .{ .name = "Historical depot", .planet_key = gs.hqs.values()[0].planet_key } });
    const hq = created.created_hq;
    gs.hqs.getPtr(hq).?.funds = 500_000_000;
    _ = try commands.execute(&gs, .{ .upgrade_tier = hq });
    const done = gs.hqs.getPtr(hq).?.projects.items[0].construction_done_day;
    _ = try commands.execute(&gs, .{ .advance_days = done + 1 });
    try std.testing.expectEqual(hq_mod.HqTier.regional, gs.hqs.getPtr(hq).?.tier);
    const offer = for (gs.artillery_offers.items) |o| {
        if (o.hq == hq) break o.id;
    } else return error.TestExpectedEqual;
    const bought = try commands.execute(&gs, .{ .buy_artillery = .{ .hq = hq, .offer = offer } });
    _ = try commands.execute(&gs, .{ .sell_artillery = bought.artillery_formation });
    _ = try commands.execute(&gs, .{ .sell_hq = hq });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
    try std.testing.expectEqualStrings("Historical depot", loaded.retired_hqs.get(hq).?.name);
    try std.testing.expectEqual(bought.hull_instance, loaded.artillery_formations.get(bought.artillery_formation).?.hull);
    var intervals: usize = 0;
    for (loaded.hull_ownership_history.items) |h| if (h.hull_instance_id == bought.hull_instance) {
        intervals += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), intervals);
    for ([_]*GameState{ &gs, &loaded }) |g| _ = try commands.execute(g, .{ .advance_days = 10 });
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
    const created_again = try commands.execute(&loaded, .{ .found_hq = .{ .name = "New depot", .planet_key = loaded.hqs.values()[0].planet_key } });
    try std.testing.expect(@intFromEnum(created_again.created_hq) > @intFromEnum(hq));
    try std.testing.expect(loaded.retired_hqs.contains(hq));
}

test "artillery sold day-zero identity and freight round trip with continued evolution" {
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
    defer gs.deinit();
    const sold = try artilleryCampaignForTest(&gs);
    const sold_hull = gs.artillery_formations.get(sold).?.hull;
    _ = try commands.execute(&gs, .{ .sell_artillery = sold });
    try std.testing.expectEqual(@as(?u32, 0), gs.hull_ownership_history.items[0].to_day);
    const far = try founding.foundHq(&gs, "Far", .regional, "skye");
    try artillery.syncMarkets(&gs);
    gs.hqs.getPtr(far).?.funds = artillery.purchasePrice() * 4;
    const bought = try commands.execute(&gs, .{ .buy_artillery = .{ .hq = far, .offer = gs.artillery_offers.items[1].id } });
    try gs.hq_links.append(gs.allocator(), .{ .a = gs.seat(), .b = far, .level = 2, .established_day = 0 });
    _ = try commands.execute(&gs, .{ .transfer_artillery = .{ .formation = bought.artillery_formation, .to_hq = gs.seat() } });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
    try std.testing.expectEqual(sold_hull, loaded.artillery_formations.get(sold).?.hull);
    const queries = @import("../sim/queries.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try queries.hullOwnershipChain(arena.allocator(), &loaded, sold_hull);
    try std.testing.expect(std.mem.indexOf(u8, chain[0], "d0–d0") != null);
    for ([_]*GameState{ &gs, &loaded }) |g| _ = try commands.execute(g, .{ .advance_days = 40 });
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
    try std.testing.expect(loaded.artillery_formations.get(bought.artillery_formation).?.placement == .hq_pool);
    // The source's purchase and freight ledger remain tagged after its sale.
    for ([_]*GameState{ &gs, &loaded }) |g| _ = try commands.execute(g, .{ .sell_hq = far });
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &buf) orelse "");
    try store.save(&loaded);
    var retired_roundtrip = try store.load(std.testing.allocator, gs.campaign_id);
    defer retired_roundtrip.deinit();
    try std.testing.expectEqual(digest.stateHash(&loaded), digest.stateHash(&retired_roundtrip));
    try std.testing.expect(retired_roundtrip.retired_hqs.contains(far));
    try store.deleteCampaign(gs.campaign_id);
    for ([_][]const u8{ "artillery_formation", "artillery_offer", "retired_hq" }) |table| {
        var sql: [128:0]u8 = undefined;
        _ = try std.fmt.bufPrintZ(&sql, "SELECT count(*) FROM {s}", .{table});
        const query = try store.db.prepare(&sql);
        defer query.finalize();
        try std.testing.expect(try query.next());
        try std.testing.expectEqual(@as(i64, 0), query.int(0));
    }
}

test "artillery load rejects malformed payloads and every new counter without repair" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try artilleryCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    for ([_][*:0]const u8{
        "DELETE FROM meta WHERE key='next_artillery_formation_id'",
        "DELETE FROM meta WHERE key='next_artillery_offer_id'",
        "UPDATE meta SET value=1 WHERE key='next_artillery_formation_id'",
        "UPDATE meta SET value=1 WHERE key='next_artillery_offer_id'",
        "UPDATE meta SET value=-1 WHERE key='next_artillery_offer_id'",
        "UPDATE meta SET value=4294967296 WHERE key='next_artillery_formation_id'",
        "UPDATE artillery_formation SET id=0",
        "UPDATE artillery_formation SET hull=99999",
        "UPDATE artillery_formation SET acquisition_day=-1",
        "UPDATE artillery_formation SET acquisition_day=4294967296",
        "UPDATE artillery_formation SET paid_price=1",
        "UPDATE artillery_formation SET placement='invalid'",
        "UPDATE artillery_formation SET pool_hq=99999",
        "UPDATE artillery_formation SET company=99999",
        "UPDATE artillery_formation SET placement='sold',pool_hq=NULL",
        "UPDATE hull_instance SET catalogue='invalid' WHERE catalogue='artillery'",
        "UPDATE hull_instance SET catalogue='chassis' WHERE catalogue='artillery'",
        "UPDATE hull_instance SET base_key='WSP-1A' WHERE catalogue='artillery'",
        "UPDATE hull_instance SET owner_type='market' WHERE catalogue='artillery'",
        "DELETE FROM artillery_formation",
        "DELETE FROM hull_ownership_history",
        "UPDATE hull_ownership_history SET to_day=0",
        "UPDATE artillery_offer SET month=0",
        "UPDATE artillery_offer SET year=1",
        "UPDATE artillery_offer SET available=2",
        "UPDATE artillery_offer SET hq=99999",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
}

test "artillery carrier introduction year rejects fractional SQLite payload through load" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try artilleryCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("UPDATE hull_instance SET intro_year=intro_year+0.5 WHERE catalogue='artillery'");
    var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        return;
    };
    loaded.deinit();
    return error.TestExpectedError;
}

test "artillery ownership starting day rejects fractional SQLite payload through load" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try artilleryCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("UPDATE hull_ownership_history SET from_day=0.5");
    var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        return;
    };
    loaded.deinit();
    return error.TestExpectedError;
}

fn expectSharedHullPayloadRejected(store: Store, cid: i64, table: []const u8, column: []const u8, expression: []const u8) !void {
    const sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "UPDATE {s} SET {s}={s}", .{ table, column, expression }, 0);
    defer std.testing.allocator.free(sql);
    try store.db.exec("SAVEPOINT malformed_shared_hull");
    errdefer store.db.exec("ROLLBACK TO malformed_shared_hull; RELEASE malformed_shared_hull") catch {};
    try store.db.exec(sql);
    var loaded = store.load(std.testing.allocator, cid) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        try store.db.exec("ROLLBACK TO malformed_shared_hull; RELEASE malformed_shared_hull");
        return;
    };
    loaded.deinit();
    std.debug.print("accepted malformed shared hull payload: {s}\n", .{sql});
    return error.TestExpectedError;
}

test "shared carrier and ownership rows reject malformed storage classes through full load" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try artilleryCampaignForTest(&gs);
    const hid = gs.artillery_formations.get(id).?.hull;
    gs.hull_instances.getPtr(hid).?.name = "Carrier";
    gs.hull_instances.getPtr(hid).?.nickname = "";
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .sell_artillery = id });
    _ = try @import("../sim/starter_company.zig").generateInto(&gs, "Company");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var valid = try store.load(std.testing.allocator, gs.campaign_id);
    defer valid.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&valid));
    try std.testing.expectEqual(@as(?u32, 0), valid.hull_ownership_history.items[0].to_day);
    try std.testing.expect(valid.hull_ownership_history.items[1].isOpen());

    // Unconstrained, affinity-free copies expose raw payload classes even when
    // normal DDL would reject NULL or convert numeric text during insertion.
    try store.db.exec("PRAGMA foreign_keys=OFF");
    try store.db.exec(
        \\CREATE TABLE carrier_payload (cid,ord,id,base_key,name,nickname,status,intro_year,pre_campaign,owner_type,owner_faction_key,owner_merc_company_id,catalogue);
        \\INSERT INTO carrier_payload SELECT * FROM hull_instance;
        \\DROP TABLE hull_instance;
        \\ALTER TABLE carrier_payload RENAME TO hull_instance;
        \\CREATE TABLE ownership_payload (cid,hull_instance_id,ord,from_day,to_day,acquisition_type,prior_owner_key);
        \\INSERT INTO ownership_payload SELECT * FROM hull_ownership_history;
        \\DROP TABLE hull_ownership_history;
        \\ALTER TABLE ownership_payload RENAME TO hull_ownership_history;
    );
    var copied = try store.load(std.testing.allocator, gs.campaign_id);
    defer copied.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&copied));

    for ([_]struct { table: []const u8, integers: []const []const u8, texts: []const []const u8 }{
        .{ .table = "hull_instance", .integers = &.{ "cid", "ord", "id", "intro_year", "pre_campaign", "owner_merc_company_id" }, .texts = &.{ "base_key", "status", "owner_type", "owner_faction_key", "catalogue" } },
        .{ .table = "hull_ownership_history", .integers = &.{ "cid", "hull_instance_id", "ord", "from_day" }, .texts = &.{ "acquisition_type", "prior_owner_key" } },
    }) |row| {
        for (row.integers) |column| {
            for ([_][]const u8{ "0.5", "'0'", "X'30'", "NULL", "-1" }) |expression|
                try expectSharedHullPayloadRejected(store, gs.campaign_id, row.table, column, expression);
        }
        for (row.texts) |column| {
            const blob = try std.fmt.allocPrint(std.testing.allocator, "CAST({s} AS BLOB)", .{column});
            defer std.testing.allocator.free(blob);
            for ([_][]const u8{ "0.5", "0", blob, "NULL" }) |expression|
                try expectSharedHullPayloadRejected(store, gs.campaign_id, row.table, column, expression);
        }
    }
    for ([_][]const u8{ "0.5", "'0'", "X'30'", "-1", "4294967296" }) |expression|
        try expectSharedHullPayloadRejected(store, gs.campaign_id, "hull_ownership_history", "to_day", expression);
    for ([_][]const u8{ "name", "nickname" }) |column| {
        for ([_][]const u8{ "0.5", "0", "X'30'" }) |expression|
            try expectSharedHullPayloadRejected(store, gs.campaign_id, "hull_instance", column, expression);
    }
    for ([_][]const u8{ "status", "owner_type", "catalogue" }) |column| {
        const suffix = try std.fmt.allocPrint(std.testing.allocator, "{s}||char(0)||'invalid'", .{column});
        defer std.testing.allocator.free(suffix);
        try expectSharedHullPayloadRejected(store, gs.campaign_id, "hull_instance", column, suffix);
    }
    try expectSharedHullPayloadRejected(store, gs.campaign_id, "hull_ownership_history", "acquisition_type", "acquisition_type||char(0)||'invalid'");
    try expectSharedHullPayloadRejected(store, gs.campaign_id, "hull_instance", "pre_campaign", "2");
    try expectSharedHullPayloadRejected(store, gs.campaign_id, "hull_instance", "intro_year", "65536");
    try store.db.exec("PRAGMA foreign_keys=ON");
}

test "nullable ownership closing dates reject silent coercion and preserve closed day zero" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try artilleryCampaignForTest(&gs);
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .sell_artillery = id });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var valid = try store.load(std.testing.allocator, gs.campaign_id);
    defer valid.deinit();
    try std.testing.expectEqualDeep(gs.hull_ownership_history.items, valid.hull_ownership_history.items);
    try std.testing.expectEqual(@as(?u32, 0), valid.hull_ownership_history.items[0].to_day);
    try std.testing.expectEqual(@as(?u32, null), valid.hull_ownership_history.items[valid.hull_ownership_history.items.len - 1].to_day);
    for ([_][*:0]const u8{
        "UPDATE hull_ownership_history SET to_day=0.5 WHERE to_day IS NOT NULL",
        "UPDATE hull_ownership_history SET to_day='invalid' WHERE to_day IS NOT NULL",
        "UPDATE hull_ownership_history SET to_day=X'30' WHERE to_day IS NOT NULL",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        loaded.deinit();
        std.debug.print("accepted malformed ownership closing date: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
}

test "artillery first save and overwrite failure roll back every table and campaign identity" {
    const prior_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prior_log_level;
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try artilleryCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.db.exec("CREATE TRIGGER reject_artillery BEFORE INSERT ON artillery_formation BEGIN SELECT RAISE(ABORT,'injected'); END");
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
    try std.testing.expectEqual(@as(i64, 0), gs.campaign_id);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    try store.db.exec("DROP TRIGGER reject_artillery");
    try store.save(&gs);
    const saved = digest.stateHash(&gs);
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .sell_artillery = id });
    try store.db.exec("CREATE TRIGGER reject_artillery BEFORE INSERT ON artillery_formation BEGIN SELECT RAISE(ABORT,'injected'); END");
    const changed = digest.stateHash(&gs);
    try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
    try std.testing.expectEqual(changed, digest.stateHash(&gs));
    var still = try store.load(std.testing.allocator, gs.campaign_id);
    defer still.deinit();
    try std.testing.expectEqual(saved, digest.stateHash(&still));
    try store.db.exec("DROP TRIGGER reject_artillery");
    try store.save(&gs);
    var retried = try store.load(std.testing.allocator, gs.campaign_id);
    defer retried.deinit();
    try std.testing.expectEqual(changed, digest.stateHash(&retried));
}

fn downgradeToV59ForTest(db: sqlite.Db) !void {
    try db.exec("PRAGMA foreign_keys=OFF");
    try removeArtilleryFromLegacyFixture(db);
    try db.exec(
        \\DROP TABLE artillery_formation;
        \\DROP TABLE artillery_offer;
        \\ALTER TABLE hull_instance DROP COLUMN catalogue;
        \\ALTER TABLE hull_ownership_history RENAME TO ownership_v60;
        \\CREATE TABLE hull_ownership_history (cid INTEGER NOT NULL,hull_instance_id INTEGER NOT NULL,ord INTEGER NOT NULL,from_day INTEGER NOT NULL DEFAULT 0,to_day INTEGER NOT NULL DEFAULT 0,acquisition_type TEXT NOT NULL DEFAULT 'initial',prior_owner_key TEXT NOT NULL DEFAULT '');
        \\INSERT INTO hull_ownership_history SELECT cid,hull_instance_id,ord,from_day,coalesce(to_day,0),acquisition_type,prior_owner_key FROM ownership_v60;
        \\DROP TABLE ownership_v60;
        \\UPDATE setting SET value=59 WHERE key='schema_version';
        \\UPDATE campaign SET schema_version=59;
    );
}

test "real v59 fixture refuses open ordinary and repeated day-zero intervals" {
    for ([_][]const u32{ &.{0}, &.{ 0, 5 }, &.{ 0, 0 }, &.{ 0, 0, 0 } }) |starts| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
        defer gs.deinit();
        _ = try foundCampaignForTest(&gs, "T", .LC, .quartermaster);
        const uid = try gs.addUnit("WSP-1A");
        try gs.recordHullAcquisition(gs.unit(uid).?, .purchase, "market");
        const hid = gs.unit(uid).?.hull_instance_id;
        gs.hull_ownership_history.clearRetainingCapacity();
        for (starts, 0..) |day, i| try gs.hull_ownership_history.append(gs.allocator(), .{
            .hull_instance_id = hid,
            .from_day = day,
            .to_day = if (i + 1 < starts.len) starts[i + 1] else null,
            .acquisition_type = if (i == 0) .purchase else .transfer,
            .prior_owner_key = if (i == 0) "market" else "player",
        });
        gs.clock.day_index = 10;
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        const store = try Store.fromDb(raw);
        try store.save(&gs);
        try expectCurrentRoundTripForTest(store, &gs);
        try downgradeToV59ForTest(raw);
        try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    }
}

test "malformed v59 ownership fixture refuses and leaves schema and rows unchanged" {
    for ([_][*:0]const u8{
        "UPDATE hull_ownership_history SET to_day=0.5",
        "UPDATE hull_ownership_history SET to_day='invalid'",
        "UPDATE hull_ownership_history SET to_day=X'30'",
        "UPDATE hull_ownership_history SET from_day=0.5",
        "UPDATE hull_ownership_history SET from_day='invalid'",
        "UPDATE hull_ownership_history SET from_day=X'30'",
        "UPDATE hull_ownership_history SET ord=0.5",
        "UPDATE hull_ownership_history SET cid=1.5",
        "UPDATE hull_ownership_history SET hull_instance_id=hull_instance_id+0.5",
        "INSERT INTO hull_ownership_history SELECT cid,hull_instance_id,ord+1,0.5,0,acquisition_type,prior_owner_key FROM hull_ownership_history",
        "UPDATE hull_ownership_history SET from_day=-1",
        "UPDATE hull_ownership_history SET to_day=-1",
        "UPDATE hull_ownership_history SET from_day=4294967296",
        "UPDATE hull_ownership_history SET to_day=4294967296",
        "UPDATE hull_ownership_history SET ord=-1",
        "INSERT INTO hull_ownership_history SELECT cid,hull_instance_id,ord+1,-1,0,acquisition_type,prior_owner_key FROM hull_ownership_history",
        "UPDATE hull_ownership_history SET from_day=10,to_day=5",
    }) |tamper| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const uid = try gs.addUnit("WSP-1A");
        try gs.recordHullAcquisition(gs.unit(uid).?, .purchase, "market");
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        const store = try Store.fromDb(raw);
        try store.save(&gs);
        try downgradeToV59ForTest(raw);
        try raw.exec(tamper);
        try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
        try std.testing.expectEqual(@as(i64, 59), store.getSetting("schema_version", 0));
        try std.testing.expect(!try Store.hasColumnRt(raw, "hull_instance", "catalogue"));
    }
}

fn retiredCampaignForTest(gs: *GameState) !types.HqId {
    const commands = @import("../sim/commands.zig");
    _ = try foundCampaignForTest(gs, "T", .LC, .quartermaster);
    const other = try founding.foundHq(gs, "{g}Historical\x1b depot", .regional, "skye");
    try artillery.syncMarkets(gs);
    gs.hqs.getPtr(other).?.funds = artillery.purchasePrice() * 4;
    const bought = try commands.execute(gs, .{ .buy_artillery = .{ .hq = other, .offer = gs.artillery_offers.items[1].id } });
    _ = try commands.execute(gs, .{ .sell_artillery = bought.artillery_formation });
    _ = try commands.execute(gs, .{ .sell_hq = other });
    return other;
}

fn tamperEnumTextForTest(store: Store, cid: i64, table: []const u8, column: []const u8, key: []const u8, id: u32, value: []const u8) !void {
    var sql: [256]u8 = undefined;
    try store.db.exec("PRAGMA ignore_check_constraints=ON");
    const update = try store.db.prepare(try std.fmt.bufPrint(&sql, "UPDATE {s} SET {s}=?1 WHERE cid=?2 AND {s}=?3", .{ table, column, key }));
    defer update.finalize();
    try update.bindAll(.{ value, cid, id });
    try update.run();
    try std.testing.expectEqual(@as(i64, 1), store.db.changes());
    try store.db.exec("PRAGMA ignore_check_constraints=OFF");
    const check = try store.db.prepare(try std.fmt.bufPrint(&sql, "SELECT {s},typeof({s})='text' FROM {s} WHERE cid=?1 AND {s}=?2", .{ column, column, table, key }));
    defer check.finalize();
    try check.bindAll(.{ cid, id });
    try std.testing.expect(try check.next());
    try std.testing.expectEqual(@as(i64, 1), check.int(1));
    const bytes = try check.text(0, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, value, bytes);
}

fn expectEnumLoadRejectedForTest(store: Store, cid: i64) !void {
    var loaded = store.load(std.testing.allocator, cid) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        return;
    };
    loaded.deinit();
    return error.TestExpectedError;
}

test "shared hull enum TEXT controls reject incomplete carrier and ownership tags" {
    for ([_]bool{ false, true }) |sold| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const formation = try artilleryCampaignForTest(&gs);
        const carrier = gs.artillery_formations.get(formation).?.hull;
        if (sold) _ = try artillery.sell(&gs, formation);
        const unit_id = try gs.addUnit("WSP-1A");
        try gs.recordHullAcquisition(gs.unit(unit_id).?, .purchase, "market");
        const conventional = gs.unit(unit_id).?.hull_instance_id;
        const store = try Store.open(":memory:");
        defer store.close();
        try store.save(&gs);
        var valid = try store.load(std.testing.allocator, gs.campaign_id);
        defer valid.deinit();
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&valid));
        const fields = [_]struct { column: []const u8, id: types.HullInstanceId, tag: []const u8 }{
            .{ .column = "status", .id = carrier, .tag = "active" },
            .{ .column = "owner_type", .id = carrier, .tag = if (sold) "market" else "player" },
            .{ .column = "catalogue", .id = carrier, .tag = "artillery" },
            .{ .column = "catalogue", .id = conventional, .tag = "chassis" },
        };
        for (fields) |field| {
            const embedded = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00invalid", .{field.tag});
            defer std.testing.allocator.free(embedded);
            const trailing = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00", .{field.tag});
            defer std.testing.allocator.free(trailing);
            for ([_][]const u8{ embedded, trailing, "", "unknown" }) |value| {
                try store.save(&gs);
                try tamperEnumTextForTest(store, gs.campaign_id, "hull_instance", field.column, "id", @intFromEnum(field.id), value);
                try expectEnumLoadRejectedForTest(store, gs.campaign_id);
            }
        }
        for (gs.hull_ownership_history.items, 0..) |interval, ord| {
            if (interval.hull_instance_id != carrier) continue;
            const embedded = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00invalid", .{@tagName(interval.acquisition_type)});
            defer std.testing.allocator.free(embedded);
            const trailing = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00", .{@tagName(interval.acquisition_type)});
            defer std.testing.allocator.free(trailing);
            for ([_][]const u8{ embedded, trailing, "", "unknown" }) |value| {
                try store.save(&gs);
                try tamperEnumTextForTest(store, gs.campaign_id, "hull_ownership_history", "acquisition_type", "ord", @intCast(ord), value);
                try expectEnumLoadRejectedForTest(store, gs.campaign_id);
            }
        }
    }
}

test "archived HQ full campaign load rejects tier TEXT containing embedded NUL" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try retiredCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var valid = try store.load(std.testing.allocator, gs.campaign_id);
    defer valid.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&valid));
    const malformed = "regional\x00invalid";
    try store.db.exec("PRAGMA ignore_check_constraints=ON");
    const update = try store.db.prepare("UPDATE retired_hq SET tier=?1 WHERE cid=?2");
    defer update.finalize();
    try update.bindAll(.{ malformed, gs.campaign_id });
    try update.run();
    try store.db.exec("PRAGMA ignore_check_constraints=OFF");
    const check = try store.db.prepare("SELECT tier,typeof(tier)='text' FROM retired_hq WHERE cid=?1");
    defer check.finalize();
    try check.bindAll(.{gs.campaign_id});
    try std.testing.expect(try check.next());
    try std.testing.expectEqual(@as(i64, 1), check.int(1));
    const bytes = try check.text(0, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, malformed, bytes);
    var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        return;
    };
    loaded.deinit();
    return error.TestExpectedError;
}

test "every archived HQ tier round trips exact tags and rejects incomplete TEXT" {
    for (std.enums.values(hq_mod.HqTier)) |tier| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const retired = try retiredCampaignForTest(&gs);
        gs.retired_hqs.getPtr(retired).?.tier = tier;
        const store = try Store.open(":memory:");
        defer store.close();
        try store.save(&gs);
        var valid = try store.load(std.testing.allocator, gs.campaign_id);
        defer valid.deinit();
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&valid));
        const embedded = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00invalid", .{@tagName(tier)});
        defer std.testing.allocator.free(embedded);
        const trailing = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00", .{@tagName(tier)});
        defer std.testing.allocator.free(trailing);
        for ([_][]const u8{ embedded, trailing, "", "unknown" }) |value| {
            try store.save(&gs);
            try tamperEnumTextForTest(store, gs.campaign_id, "retired_hq", "tier", "id", @intFromEnum(retired), value);
            try expectEnumLoadRejectedForTest(store, gs.campaign_id);
        }
    }
}

test "archive tier codec rejects original nontext storage without affinity coercion" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE retired_hq(cid,ord,id,name,planet,tier,sold_day); CREATE TABLE meta(cid,key,value); INSERT INTO meta VALUES(1,'retired_hq_count',1); INSERT INTO meta VALUES(1,'next_hq_id',3)");
    const store: Store = .{ .db = db };
    for ([_][]const u8{ "1", "1.5", "X'726567696f6e616c'", "NULL" }) |value| {
        var sql: [256]u8 = undefined;
        try db.exec("DELETE FROM retired_hq; INSERT INTO retired_hq VALUES(1,0,2,'Historical','skye','regional',0)");
        try db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE retired_hq SET tier={s}", .{value}));
        var rows = GameState.init(std.testing.allocator, .{});
        defer rows.deinit();
        try std.testing.expectError(error.CorruptSave, store.loadRetiredHq(&rows, 1, 61));
    }
}

test "archive tier scratch propagates allocation failure and releases bytes on every outcome" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE retired_hq(cid,ord,id,name,planet,tier,sold_day); CREATE TABLE meta(cid,key,value); INSERT INTO meta VALUES(1,'retired_hq_count',1); INSERT INTO meta VALUES(1,'next_hq_id',3); INSERT INTO retired_hq VALUES(1,0,2,'Historical','skye','regional',0)");
    const store: Store = .{ .db = db };
    for ([_][]const u8{ "regional", "regional\x00invalid" }) |value| {
        const update = try db.prepare("UPDATE retired_hq SET tier=?1");
        defer update.finalize();
        try update.bindAll(.{value});
        try update.run();
        for ([_]usize{ 0, 1, std.math.maxInt(usize) }) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            {
                var rows = GameState.init(failing.allocator(), .{});
                defer rows.deinit();
                if (fail_index == 0 or (fail_index == 1 and std.mem.eql(u8, value, "regional"))) {
                    try std.testing.expectError(error.OutOfMemory, store.loadRetiredHq(&rows, 1, 61));
                    try std.testing.expect(failing.has_induced_failure);
                } else if (std.mem.eql(u8, value, "regional")) {
                    try store.loadRetiredHq(&rows, 1, 61);
                    // Retained name/world bytes belong to the campaign arena.
                    try std.testing.expectEqual(@as(usize, 1), failing.deallocations);
                } else {
                    try std.testing.expectError(error.CorruptSave, store.loadRetiredHq(&rows, 1, 61));
                    try std.testing.expectEqual(@as(usize, value.len), failing.freed_bytes);
                }
            }
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "multiple retired HQs preserve sale order independently of ID order" {
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .quartermaster);
    const first = try founding.foundHq(&gs, "First", .regional, "skye");
    const second = try founding.foundHq(&gs, "Second", .regional, "skye");
    _ = try commands.execute(&gs, .{ .sell_hq = second });
    _ = try commands.execute(&gs, .{ .sell_hq = first });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(types.HqId, gs.retired_hqs.keys(), loaded.retired_hqs.keys());
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
}

test "retired HQ archive and history reject incomplete malformed and operational-only references" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const retired = try retiredCampaignForTest(&gs);
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(retired));
    _ = try gs.createForce("Company", .company, .none);
    const store = try Store.open(":memory:");
    defer store.close();
    for ([_][*:0]const u8{
        "DELETE FROM retired_hq",
        "DELETE FROM meta WHERE key='retired_hq_count'",
        "UPDATE meta SET value=0 WHERE key='retired_hq_count'",
        "UPDATE meta SET value=-1 WHERE key='retired_hq_count'",
        "UPDATE meta SET value=1.5 WHERE key='retired_hq_count'",
        "UPDATE meta SET value='invalid' WHERE key='retired_hq_count'",
        "UPDATE meta SET value=X'31' WHERE key='retired_hq_count'",
        "DELETE FROM meta WHERE key='next_hq_id'",
        "UPDATE meta SET value=0 WHERE key='next_hq_id'",
        "UPDATE meta SET value=2 WHERE key='next_hq_id'",
        "UPDATE meta SET value=-1 WHERE key='next_hq_id'",
        "UPDATE meta SET value=4294967296 WHERE key='next_hq_id'",
        "UPDATE meta SET value=3.5 WHERE key='next_hq_id'",
        "UPDATE meta SET value='invalid' WHERE key='next_hq_id'",
        "UPDATE meta SET value=X'33' WHERE key='next_hq_id'",
        "UPDATE retired_hq SET id=0",
        "UPDATE retired_hq SET id=1",
        "UPDATE retired_hq SET id=4294967295",
        "UPDATE retired_hq SET id=4294967296",
        "UPDATE retired_hq SET id=-1",
        "UPDATE retired_hq SET id=2.5",
        "UPDATE retired_hq SET id='invalid'",
        "UPDATE retired_hq SET id=X'32'",
        "UPDATE retired_hq SET sold_day=1",
        "UPDATE retired_hq SET sold_day=-1",
        "UPDATE retired_hq SET sold_day=4294967296",
        "UPDATE retired_hq SET sold_day=0.5",
        "UPDATE retired_hq SET sold_day='invalid'",
        "UPDATE retired_hq SET sold_day=X'30'",
        "UPDATE retired_hq SET tier='unknown'",
        "UPDATE retired_hq SET tier=X'6669656c64'",
        "UPDATE retired_hq SET planet='unknown'",
        "UPDATE retired_hq SET planet=X'736b7965'",
        "UPDATE retired_hq SET name=X'4e616d65'",
        "UPDATE retired_hq SET ord=1",
        "UPDATE retired_hq SET ord=-1",
        "UPDATE retired_hq SET ord=4294967296",
        "UPDATE retired_hq SET ord=0.5",
        "UPDATE retired_hq SET ord='invalid'",
        "UPDATE retired_hq SET ord=X'30'",
        "UPDATE txn SET hq=999 WHERE hq=2",
        "UPDATE event_log SET hq=999 WHERE hq=2",
        "UPDATE force SET supplying_hq=2",
        "UPDATE person SET posted_hq=2",
        "UPDATE artillery_offer SET hq=2",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
        var loaded = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        loaded.deinit();
        std.debug.print("accepted malformed HQ archive: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
}

test "archive decoder rejects duplicate NULL and coercible original storage classes" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try retiredCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // No affinities/constraints: numeric text remains TEXT and NULL is possible.
    try store.db.exec("PRAGMA foreign_keys=OFF");
    try store.db.exec("ALTER TABLE retired_hq RENAME TO archive_original; CREATE TABLE retired_hq(cid,ord,id,name,planet,tier,sold_day)");
    for ([_][*:0]const u8{
        "INSERT INTO retired_hq SELECT * FROM archive_original",
        "UPDATE retired_hq SET id=NULL",
        "UPDATE retired_hq SET id='2'",
        "UPDATE retired_hq SET sold_day=NULL",
        "UPDATE retired_hq SET sold_day='0'",
        "UPDATE retired_hq SET name=NULL",
        "UPDATE retired_hq SET planet=NULL",
        "UPDATE retired_hq SET tier=NULL",
        "UPDATE retired_hq SET cid='1'",
        "UPDATE retired_hq SET ord=NULL",
        "UPDATE retired_hq SET ord='0'",
    }) |tamper| {
        try store.db.exec("DELETE FROM retired_hq; INSERT INTO retired_hq SELECT * FROM archive_original");
        try store.db.exec(tamper);
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    // Metadata is checked before coercion, including numeric text and NULL.
    try store.db.exec("DELETE FROM retired_hq; INSERT INTO retired_hq SELECT * FROM archive_original; ALTER TABLE meta RENAME TO meta_original; CREATE TABLE meta(cid,key,value)");
    for ([_][*:0]const u8{
        "UPDATE meta SET value=NULL WHERE key='next_hq_id'",
        "UPDATE meta SET value='3' WHERE key='next_hq_id'",
        "UPDATE meta SET value=NULL WHERE key='retired_hq_count'",
        "UPDATE meta SET value='1' WHERE key='retired_hq_count'",
        "INSERT INTO meta SELECT * FROM meta_original WHERE key='retired_hq_count'",
    }) |tamper| {
        try store.db.exec("DELETE FROM meta; INSERT INTO meta SELECT * FROM meta_original");
        try store.db.exec(tamper);
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
}

test "archive save first-write update overwrite and delete are one transaction per campaign" {
    const prior_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prior_log_level;
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try retiredCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    // Failure occurs after the archive table has been written in save order.
    try store.db.exec("CREATE TRIGGER reject_after_archive BEFORE INSERT ON txn BEGIN SELECT RAISE(ABORT,'injected'); END");
    const before = digest.stateHash(&gs);
    try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
    try std.testing.expectEqual(@as(i64, 0), gs.campaign_id);
    try std.testing.expectEqual(before, digest.stateHash(&gs));
    const rows = try store.db.prepare("SELECT count(*) FROM retired_hq");
    defer rows.finalize();
    try std.testing.expect(try rows.next());
    try std.testing.expectEqual(@as(i64, 0), rows.int(0));
    try store.db.exec("DROP TRIGGER reject_after_archive");
    try store.save(&gs);
    const original = digest.stateHash(&gs);
    gs.retired_hqs.getPtr(id).?.name = "Changed";
    const changed = digest.stateHash(&gs);
    try store.db.exec("CREATE TRIGGER reject_after_archive BEFORE INSERT ON txn BEGIN SELECT RAISE(ABORT,'injected'); END");
    try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
    try std.testing.expectEqual(changed, digest.stateHash(&gs));
    var old = try store.load(std.testing.allocator, gs.campaign_id);
    defer old.deinit();
    try std.testing.expectEqual(original, digest.stateHash(&old));
    try store.db.exec("DROP TRIGGER reject_after_archive");
    try store.save(&gs);
    var updated = try store.load(std.testing.allocator, gs.campaign_id);
    defer updated.deinit();
    try std.testing.expectEqual(changed, digest.stateHash(&updated));
    var independent = GameState.init(std.testing.allocator, .{});
    defer independent.deinit();
    _ = try retiredCampaignForTest(&independent);
    try store.save(&independent);
    try store.deleteCampaign(gs.campaign_id);
    var retained = try store.load(std.testing.allocator, independent.campaign_id);
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 1), retained.retired_hqs.count());
    try store.deleteCampaign(independent.campaign_id);
    rows.reset();
    try std.testing.expect(try rows.next());
    try std.testing.expectEqual(@as(i64, 0), rows.int(0));
}

test "real v60 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try artilleryCampaignForTest(&gs);
    const db = try sqlite.Db.open(":memory:");
    var initial = try Store.fromDb(db);
    try initial.save(&gs);
    try expectCurrentRoundTripForTest(initial, &gs);
    try db.exec("DROP TABLE retired_hq; DELETE FROM meta WHERE key='retired_hq_count'; UPDATE setting SET value=60 WHERE key='schema_version'; UPDATE campaign SET schema_version=60; UPDATE meta SET value=0 WHERE key='next_hq_id'");
    defer db.close();
    try expectStoreRefusedUnchanged(db, error.StoreOlderThanGame);
}

// Schema-61 fixture definitions are independently copied from the pre-P2g documented schema.
fn downgradeArtilleryToV61ForTest(db: sqlite.Db) !void {
    try db.exec("PRAGMA foreign_keys=OFF");
    try db.exec(
        \\CREATE TABLE artillery_formation__v61 (
        \\    cid INTEGER NOT NULL,
        \\    ord INTEGER NOT NULL CHECK (ord >= 0),
        \\    id INTEGER NOT NULL CHECK (id BETWEEN 1 AND 4294967295),
        \\    hull INTEGER NOT NULL CHECK (hull BETWEEN 1 AND 4294967295),
        \\    acquisition_day INTEGER NOT NULL CHECK (acquisition_day BETWEEN 0 AND 4294967295),
        \\    paid_price INTEGER NOT NULL CHECK (paid_price > 0),
        \\    placement TEXT NOT NULL CHECK (placement IN ('hq_pool','company','freight','sold')),
        \\    pool_hq INTEGER,
        \\    company INTEGER,
        \\    from_hq INTEGER,
        \\    to_hq INTEGER,
        \\    dispatch_day INTEGER,
        \\    eta_day INTEGER,
        \\    paid_cost INTEGER,
        \\    PRIMARY KEY (cid,id),
        \\    UNIQUE (cid,ord),
        \\    UNIQUE (cid,hull),
        \\    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
        \\    FOREIGN KEY (cid,hull) REFERENCES hull_instance(cid,id) DEFERRABLE INITIALLY DEFERRED,
        \\    FOREIGN KEY (cid,pool_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED,
        \\    FOREIGN KEY (cid,company) REFERENCES force(cid,id) DEFERRABLE INITIALLY DEFERRED,
        \\    FOREIGN KEY (cid,from_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED,
        \\    FOREIGN KEY (cid,to_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED,
        \\    CHECK ((pool_hq IS NOT NULL) = (placement='hq_pool')),
        \\    CHECK ((company IS NOT NULL) = (placement='company')),
        \\    CHECK ((from_hq IS NOT NULL) = (placement='freight')),
        \\    CHECK ((to_hq IS NOT NULL) = (placement='freight')),
        \\    CHECK ((dispatch_day IS NOT NULL) = (placement='freight')),
        \\    CHECK ((eta_day IS NOT NULL) = (placement='freight')),
        \\    CHECK ((paid_cost IS NOT NULL) = (placement='freight')),
        \\    CHECK (pool_hq IS NULL OR pool_hq BETWEEN 1 AND 4294967295),
        \\    CHECK (company IS NULL OR company BETWEEN 1 AND 4294967295),
        \\    CHECK (from_hq IS NULL OR from_hq BETWEEN 1 AND 4294967295),
        \\    CHECK (to_hq IS NULL OR to_hq BETWEEN 1 AND 4294967295),
        \\    CHECK (placement!='freight' OR (from_hq!=to_hq AND dispatch_day BETWEEN 0 AND 4294967295 AND eta_day > dispatch_day AND eta_day <= 4294967295 AND paid_cost >= 0))
        \\);
        \\CREATE TABLE bay_job__v61 (
        \\    cid             INTEGER NOT NULL,
        \\    ord             INTEGER NOT NULL,
        \\    hq              INTEGER,                         -- -> hq.id
        \\    kind            TEXT,                            -- depot_repair | reactivation | fabrication | refit
        \\    unit            INTEGER,                         -- -> unit.id; 0 for fabrication
        \\    item_key        TEXT,                            -- component being fabricated
        \\    duration        INTEGER,                         -- days
        \\    queued          INTEGER,                         -- day
        \\    started         INTEGER,                         -- day; null while waiting for a slot
        \\    done            INTEGER,                         -- day
        \\    cost            INTEGER,                         -- labor posted to the HQ at completion
        \\    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
        \\);
    );
    try db.exec(
        \\INSERT INTO artillery_formation__v61 SELECT cid,ord,id,hull,acquisition_day,paid_price,placement,pool_hq,company,from_hq,to_hq,dispatch_day,eta_day,paid_cost FROM artillery_formation;
        \\INSERT INTO bay_job__v61 SELECT cid,ord,hq,kind,COALESCE(unit,0),item_key,duration,queued,started,done,cost FROM bay_job;
        \\DROP TABLE artillery_crew;
        \\DROP TABLE artillery_slot;
        \\DROP TABLE artillery_formation;
        \\ALTER TABLE artillery_formation__v61 RENAME TO artillery_formation;
        \\DROP TABLE bay_job;
        \\ALTER TABLE bay_job__v61 RENAME TO bay_job;
        \\DELETE FROM meta WHERE key='last_artillery_service_day';
        \\UPDATE campaign SET schema_version=61;
        \\UPDATE setting SET value=61 WHERE key='schema_version';
    );
    try db.exec("PRAGMA foreign_keys=ON");
}

test "real schema 61 historical fixture is refused without mutation" {
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const home = try foundCampaignForTest(&gs, "T", .LC, .quartermaster);
    const far = try founding.foundHq(&gs, "Remote", .regional, "skye");
    const shipping = try founding.foundHq(&gs, "Shipping", .regional, "galatea");
    const sales = try founding.foundHq(&gs, "Sales", .regional, "galatea");
    const company = try gs.createForce("Alpha", .company, .none);
    try artillery.syncMarkets(&gs);
    const homes = [_]types.HqId{ home, far, shipping, sales };
    var ids: [4]types.ArtilleryFormationId = undefined;
    for (homes, &ids) |hq, *id| {
        gs.hqs.getPtr(hq).?.funds = artillery.purchasePrice() * 4;
        const offer = for (gs.artillery_offers.items) |o| {
            if (o.hq == hq) break o.id;
        } else return error.TestUnexpectedResult;
        id.* = (try artillery.buy(&gs, .{ .hq = hq, .offer = offer })).artillery_formation;
    }
    _ = try artillery.attach(&gs, .{ .formation = ids[0], .company = company });
    try gs.hq_links.append(gs.allocator(), .{ .a = shipping, .b = home, .level = 2, .established_day = 0 });
    _ = try artillery.transfer(&gs, .{ .formation = ids[2], .to_hq = home });
    _ = try artillery.sell(&gs, ids[3]);
    try gs.bay_jobs.append(gs.allocator(), .{ .hq = home, .kind = .fabrication, .item_key = "comp_chassis_h", .duration_days = 2, .queued_day = 0 });
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    const initial = try Store.fromDb(raw);
    try initial.save(&gs);
    try expectCurrentRoundTripForTest(initial, &gs);
    try downgradeArtilleryToV61ForTest(raw);
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
}

test "schema 63 operational corruption is never repaired on load" {
    const operations = @import("../sim/artillery_operations.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    _ = try operations.fixtureForTest(&gs, true);
    _ = try gs.addUnit("SCP-1N");
    const store = try Store.open(":memory:");
    defer store.close();
    const before = digest.stateHash(&gs);
    for ([_][*:0]const u8{
        "DELETE FROM artillery_crew WHERE seat='loader'",
        "DELETE FROM artillery_slot WHERE slot='hitch'",
        "UPDATE artillery_crew SET seat='unknown' WHERE seat='driver'",
        "UPDATE artillery_slot SET slot='unknown' WHERE slot='hitch'",
        "UPDATE artillery_slot SET condition='ok'||char(0)||'bad' WHERE slot='hitch'",
        "UPDATE artillery_crew SET seat='driver'||char(0) WHERE seat='driver'",
        "UPDATE artillery_formation SET quality='c'||char(0)",
        "UPDATE artillery_formation SET armor=100.5",
        "UPDATE artillery_formation SET armor=101",
        "UPDATE artillery_formation SET last_maintenance=1",
        "UPDATE artillery_formation SET last_maintenance=0.5",
        "UPDATE artillery_formation SET tech=99999",
        "UPDATE artillery_formation SET tech=tech+0.5",
        "UPDATE artillery_crew SET person=99999 WHERE seat='driver'",
        "UPDATE artillery_crew SET person=person+0.5 WHERE seat='driver'",
        "UPDATE unit SET pilot=(SELECT person FROM artillery_crew WHERE seat='gunner')",
        "UPDATE person SET assigned_force=0 WHERE role='vehicle_crew'",
        "UPDATE meta SET value=1 WHERE key='next_person_id'",
        "UPDATE artillery_slot SET rounds=6 WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_slot SET rounds=1.5 WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_slot SET rounds=1,condition='destroyed' WHERE slot='long_tom_bin_1'",
        "UPDATE artillery_slot SET rounds=0 WHERE slot='main_gun'",
        "UPDATE artillery_slot SET rounds=NULL WHERE slot='machine_gun_bin'",
        "UPDATE meta SET value=1 WHERE key='last_artillery_service_day'",
        "UPDATE meta SET value=-2 WHERE key='last_artillery_service_day'",
        "UPDATE meta SET value=0.5 WHERE key='last_artillery_service_day'",
        "DELETE FROM meta WHERE key='last_artillery_service_day'",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
        try std.testing.expectEqual(before, digest.stateHash(&gs));
    }
    try store.save(&gs);
    var newer: [64:0]u8 = undefined;
    try store.db.exec(try std.fmt.bufPrintZ(&newer, "UPDATE campaign SET schema_version={d}", .{schema_version + 1}));
    try std.testing.expectError(error.SaveNewerThanGame, store.load(std.testing.allocator, gs.campaign_id));
}

test "operational save continues through shared service injury repair reload and freight identically" {
    const commands = @import("../sim/commands.zig");
    const operations = @import("../sim/artillery_operations.zig");
    const maintenance = @import("../sim/maintenance.zig");
    const rules = @import("../domain/artillery_operations.zig");
    const artillery_crew = @import("../sim/artillery_crew.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    try personage_rules.seedForTest(&gs);
    const f = gs.artillery_formations.getPtr(id).?;
    f.slots[@intFromEnum(rules.Slot.communications)].condition = .missing;
    f.armor_pct = 80;
    try gs.addStock(.{ .hq = gs.seat() }, "artillery_spares", 2);
    try gs.addStock(.{ .hq = gs.seat() }, rules.packageKey(.long_tom), 5);
    try gs.addStock(.{ .hq = gs.seat() }, rules.packageKey(.machine_gun), 1);
    _ = try commands.execute(&gs, .{ .reload_artillery = .{ .formation = id, .family = .long_tom } });
    _ = try commands.execute(&gs, .{ .reload_artillery = .{ .formation = id, .family = .machine_gun } });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    for ([_]*GameState{ &gs, &loaded }) |g| {
        g.clock.day_index = 7;
        try maintenance.runWeeklyService(g);
        const carrier = g.artillery_formations.getPtr(id).?;
        try std.testing.expectEqual(@import("../domain/unit.zig").PartCondition.ok, carrier.slots[@intFromEnum(rules.Slot.communications)].condition);
        const tech = carrier.tech;
        try maintenance.injureTech(g, tech, 3, "continuation accident");
        try std.testing.expectEqual(types.PersonId.none, carrier.tech);
        const replacement = try g.hirePerson("Replacement", "Mechanic", .tech_mechanic);
        _ = try artillery_crew.assignTech(g, .{ .formation = id, .person = replacement });
        carrier.slots[@intFromEnum(rules.Slot.long_tom_bin_2)].rounds = 0;
        _ = try commands.execute(g, .{ .reload_artillery = .{ .formation = id, .family = .long_tom } });
        _ = try artillery.detach(g, id);
        const far = try founding.foundHq(g, "Remote", .regional, "skye");
        try artillery.syncMarkets(g);
        try g.hq_links.append(g.allocator(), .{ .a = g.seat(), .b = far, .level = 2, .established_day = 0 });
        const transfer_result = try commands.execute(g, .{ .transfer_artillery = .{ .formation = id, .to_hq = far } });
        try std.testing.expect(operations.operationSite(g, carrier) == null);
        g.clock.day_index = transfer_result.artillery_eta_day;
        try artillery.runArrivals(g);
        try artillery.validate(g);
        try std.testing.expectEqual(@as(u16, rules.long_tom_rounds_per_bin), carrier.slots[@intFromEnum(rules.Slot.long_tom_bin_2)].rounds);
    }
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try store.save(&loaded);
    var continued = try store.load(std.testing.allocator, loaded.campaign_id);
    defer continued.deinit();
    try std.testing.expectEqual(digest.stateHash(&loaded), digest.stateHash(&continued));
    // Pin the complete operational command script, including service and injury streams.
    try std.testing.expectEqual(@as(u64, 1972296283076275464), digest.stateHash(&continued));
}

test "artillery bay targets round trip and malformed mutually exclusive targets reject loading" {
    const operations = @import("../sim/artillery_operations.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, false);
    try personage_rules.seedForTest(&gs);
    _ = try gs.addUnit("SCP-1N");
    try gs.bay_jobs.append(gs.allocator(), .{ .hq = gs.seat(), .kind = .artillery_depot_repair, .artillery = id, .duration_days = 2, .queued_day = 0 });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expectEqual(id, loaded.bay_jobs.items[0].artillery);
    try std.testing.expectEqual(types.UnitId.none, loaded.bay_jobs.items[0].unit);
    for ([_][*:0]const u8{
        "UPDATE bay_job SET artillery=NULL",
        "UPDATE bay_job SET artillery=99999",
        "UPDATE bay_job SET artillery=1.5",
        "UPDATE bay_job SET unit=0",
        "UPDATE bay_job SET artillery=0",
        "UPDATE bay_job SET kind='fabrication',artillery=0,item_key='comp_chassis_h'",
        "UPDATE bay_job SET unit=1",
        "UPDATE bay_job SET kind='fabrication',item_key='comp_chassis_h'",
        "UPDATE bay_job SET kind='artillery_depot_repair'||char(0)",
        "UPDATE bay_job SET item_key='comp_chassis_h'",
        "UPDATE bay_job SET started=1,done=2",
        "UPDATE bay_job SET duration=0",
        "INSERT INTO bay_job SELECT cid,ord+1,hq,kind,unit,item_key,duration,queued,started,done,cost,artillery FROM bay_job",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
        var invalid = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        invalid.deinit();
        std.debug.print("accepted bay corruption: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
}

test "negative bay insertion order rejects loading with SQL constraints bypassed" {
    const operations = @import("../sim/artillery_operations.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, false);
    try gs.bay_jobs.append(gs.allocator(), .{ .hq = gs.seat(), .kind = .artillery_depot_repair, .artillery = id, .duration_days = 2, .queued_day = 0 });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec("PRAGMA ignore_check_constraints=ON; UPDATE bay_job SET ord=-1; PRAGMA ignore_check_constraints=OFF");
    var invalid = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        return;
    };
    invalid.deinit();
    return error.TestExpectedError;
}

test "attached artillery accident replacement preserves complete assignment through save and load" {
    const operations = @import("../sim/artillery_operations.zig");
    const maintenance = @import("../sim/maintenance.zig");
    var gs = GameState.init(std.testing.allocator, .{});
    defer gs.deinit();
    const id = try operations.fixtureForTest(&gs, true);
    try personage_rules.seedForTest(&gs);
    const original = gs.artillery_formations.get(id).?;
    const replacement = try gs.hirePerson("Spare", "Mechanic", .tech_mechanic);
    gs.person(replacement).?.weekly_hours = 100;
    try maintenance.injureTech(&gs, original.tech, 3, "shared accident");
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expectEqual(replacement, loaded.artillery_formations.get(id).?.tech);
    try std.testing.expectEqual(original.placement.company, loaded.person(replacement).?.assigned_force);
    try std.testing.expect(operations.serviceCapability(&loaded, loaded.artillery_formations.getPtr(id).?) != null);
}

test "absent pool mechanic and captive operating crew retain valid saved assignments without remote service" {
    const operations = @import("../sim/artillery_operations.zig");
    const artillery_crew = @import("../sim/artillery_crew.zig");
    for ([_]bool{ false, true }) |pooled| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const id = try operations.fixtureForTest(&gs, true);
        try personage_rules.seedForTest(&gs);
        const f = gs.artillery_formations.get(id).?;
        if (pooled) {
            _ = try artillery.detach(&gs, id);
            _ = try artillery_crew.assignTech(&gs, .{ .formation = id, .person = f.tech });
            gs.force(f.placement.company).?.location_planet = "galatea";
        } else {
            gs.person(f.crew[0]).?.status = .pow;
            gs.person(f.crew[1]).?.training = .{ .skill = .gunnery_vee, .done_day = 1 };
            gs.force(f.placement.company).?.return_eta_day = 10;
        }
        try artillery.validate(&gs);
        try std.testing.expect(operations.serviceCapability(&gs, gs.artillery_formations.getPtr(id).?) == null);
        const store = try Store.open(":memory:");
        defer store.close();
        try store.save(&gs);
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
        try std.testing.expect(operations.serviceCapability(&loaded, loaded.artillery_formations.getPtr(id).?) == null);
        try std.testing.expectEqual(gs.artillery_formations.get(id).?.tech, loaded.artillery_formations.get(id).?.tech);
        try std.testing.expectEqual(gs.artillery_formations.get(id).?.crew, loaded.artillery_formations.get(id).?.crew);
    }
}

test "operational row write failures preserve first-save and overwrite identity until successful retry" {
    const operations = @import("../sim/artillery_operations.zig");
    const rules = @import("../domain/artillery_operations.zig");
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_log_level;
    for ([_][]const u8{ "artillery_crew", "artillery_slot" }) |table| {
        var gs = GameState.init(std.testing.allocator, .{});
        defer gs.deinit();
        const id = try operations.fixtureForTest(&gs, true);
        try personage_rules.seedForTest(&gs);
        gs.artillery_formations.getPtr(id).?.slots[@intFromEnum(rules.Slot.long_tom_bin_1)].rounds = 3;
        const store = try Store.open(":memory:");
        defer store.close();
        var sql: [256]u8 = undefined;
        const trigger = try std.fmt.bufPrintZ(&sql, "CREATE TRIGGER reject_operations BEFORE INSERT ON {s} BEGIN SELECT RAISE(ABORT,'injected'); END", .{table});
        try store.db.exec(trigger);
        const before = digest.stateHash(&gs);
        try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
        try std.testing.expectEqual(@as(i64, 0), gs.campaign_id);
        try std.testing.expectEqual(before, digest.stateHash(&gs));
        try store.db.exec("DROP TRIGGER reject_operations");
        try store.save(&gs);
        const saved = digest.stateHash(&gs);
        gs.artillery_formations.getPtr(id).?.armor_pct = 90;
        gs.last_artillery_service_day = 0;
        const changed = digest.stateHash(&gs);
        try store.db.exec(trigger);
        try std.testing.expectError(error.ConstraintViolation, store.save(&gs));
        try std.testing.expectEqual(changed, digest.stateHash(&gs));
        var prior = try store.load(std.testing.allocator, gs.campaign_id);
        defer prior.deinit();
        try std.testing.expectEqual(saved, digest.stateHash(&prior));
        try store.db.exec("DROP TRIGGER reject_operations");
        try store.save(&gs);
        var retried = try store.load(std.testing.allocator, gs.campaign_id);
        defer retried.deinit();
        try std.testing.expectEqual(changed, digest.stateHash(&retried));
    }
}

test "queued and started artillery depot work survives normal departure station return and deterministic resumption" {
    const operations = @import("../sim/artillery_operations.zig");
    const service = @import("../sim/artillery_service.zig");
    const control = @import("../sim/contract_control.zig");
    const rules = @import("../domain/artillery_operations.zig");
    const part = @import("../domain/part.zig");
    const tick = @import("../sim/tick.zig");
    for ([_]bool{ false, true }) |started| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
        defer gs.deinit();
        const id = try operations.fixtureForTest(&gs, true);
        try personage_rules.seedForTest(&gs);
        const f = gs.artillery_formations.getPtr(id).?;
        const company = f.placement.company;
        const home = gs.seat();
        const hq = gs.hqs.getPtr(home).?;
        for (hq.facilities.items) |*facility| if (facility.kind == .mek_bay) {
            facility.level = part.find(rules.descriptor(.chassis).spare_key).?.fab_min_bay;
        };
        _ = try hq_ops.staffHqToRequirement(&gs, home);
        f.slots[@intFromEnum(rules.Slot.chassis)].condition = .destroyed;
        try gs.addStock(.{ .hq = home }, rules.descriptor(.chassis).spare_key, 1);
        _ = try service.queueRepair(&gs, id);
        if (started) try hq_ops.runDaily(&gs);
        try std.testing.expectEqual(started, gs.bay_jobs.items[0].started_day != null);
        const store = try Store.open(":memory:");
        defer store.close();
        try store.save(&gs);
        try expectCurrentRoundTripForTest(store, &gs);
        const offer: types.ContractId = @enumFromInt(gs.next_contract_id);
        gs.next_contract_id += 1;
        try gs.contract_offers.append(gs.allocator(), .{
            .id = offer,
            .kind = .recon_raid,
            .employer_key = "FS",
            .enemy_key = "CC",
            .planet_key = "caph",
            .offer_hq = home,
            .terms = .{ .length_months = 3, .base_pay_month = 400_000 },
        });
        try control.acceptContract(&gs, offer, company);
        try std.testing.expect(posture.companyPosture(&gs, company) == .en_route);
        try expectSuspendedDepotRoundTripForTest(store, &gs, home, started);
        gs.clock.day_index = gs.contracts.get(offer).?.arrive_day.? - 1;
        try tick.advanceDay(&gs);
        try std.testing.expect(posture.companyPosture(&gs, company) == .deployed);
        try expectSuspendedDepotRoundTripForTest(store, &gs, home, started);
        try control.fail(&gs, gs.contracts.getPtr(offer).?, "fixture term ended");
        try std.testing.expect(posture.companyPosture(&gs, company) == .idle_afield);
        try expectSuspendedDepotRoundTripForTest(store, &gs, home, started);
        _ = try control.recall(&gs, company);
        try std.testing.expect(posture.companyPosture(&gs, company) == .returning);
        try expectSuspendedDepotRoundTripForTest(store, &gs, home, started);
        gs.clock.day_index = gs.force(company).?.return_eta_day.?;
        try control.runReturns(&gs);
        try std.testing.expect(posture.companyPosture(&gs, company) == .home);
        try std.testing.expect(service.jobCanWork(&gs, &gs.bay_jobs.items[0]));
        try store.save(&gs);
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
        for ([_]*GameState{ &gs, &loaded }) |g| {
            try hq_ops.runDaily(g);
            if (g.bay_jobs.items.len > 0) {
                g.clock.day_index = g.bay_jobs.items[0].done_day.?;
                try hq_ops.runDaily(g);
            }
        }
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
        try std.testing.expectEqual(gs.rng, loaded.rng);
        try std.testing.expectEqualDeep(gs.bay_jobs.items, loaded.bay_jobs.items);
        try store.save(&loaded);
        try expectCurrentRoundTripForTest(store, &loaded);
        // Durable identity still rejects another HQ despite valid travel posture.
        if (loaded.bay_jobs.items.len == 0) {
            try loaded.bay_jobs.append(loaded.allocator(), .{ .hq = home, .kind = .artillery_depot_repair, .artillery = id, .duration_days = 2, .queued_day = loaded.clock.day_index });
        }
        try store.save(&loaded);
        try store.db.exec("PRAGMA foreign_keys=OFF; UPDATE bay_job SET hq=99999");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, loaded.campaign_id));
    }
}

fn expectSuspendedDepotRoundTripForTest(store: Store, gs: *GameState, home: types.HqId, started: bool) !void {
    const service = @import("../sim/artillery_service.zig");
    try store.save(gs);
    try expectCurrentRoundTripForTest(store, gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    const before = digest.stateHash(&loaded);
    try std.testing.expect(!service.jobCanWork(&loaded, &loaded.bay_jobs.items[0]));
    try std.testing.expect(!try service.completeJob(&loaded, 0));
    try hq_ops.runDaily(&loaded);
    try std.testing.expectEqual(before, digest.stateHash(&loaded));
    try std.testing.expectEqual(@as(u32, if (started) 1 else 0), hq_ops.bayLoad(&loaded, home).busy);
    try std.testing.expectEqual(@as(u32, if (started) 0 else 1), hq_ops.bayLoad(&loaded, home).queued);
    try std.testing.expectEqual(gs.rng, loaded.rng);
    try std.testing.expectEqualDeep(gs.bay_jobs.items, loaded.bay_jobs.items);
}

test "store versions require one exact positive integer and current structures are never healed" {
    for ([_][]const u8{ "0", "-1", "4294967296", "NULL", "66.5", "'66'", "X'3636'" }) |value| {
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try raw.exec("CREATE TABLE setting(key,value)");
        var sql: [256:0]u8 = undefined;
        try raw.exec(try std.fmt.bufPrintZ(&sql, "INSERT INTO setting VALUES('schema_version',{s})", .{value}));
        try expectStoreRefusedUnchanged(raw, error.CorruptStore);
    }
    // No version row, a duplicated current version, and a lone current version
    // with no tables: each is a nonempty unhealed store.
    for (0..3) |rows| {
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        var sql: [256:0]u8 = undefined;
        try raw.exec(switch (rows) {
            0 => "CREATE TABLE setting(key,value)",
            1 => try std.fmt.bufPrintZ(&sql, "CREATE TABLE setting(key,value); INSERT INTO setting VALUES('schema_version',{d})", .{schema_version}),
            else => try std.fmt.bufPrintZ(&sql, "CREATE TABLE setting(key,value); INSERT INTO setting VALUES('schema_version',{d}),('schema_version',{d})", .{ schema_version, schema_version }),
        });
        try expectStoreRefusedUnchanged(raw, error.CorruptStore);
    }
    for ([_][*:0]const u8{ "DROP TABLE artillery_slot", "PRAGMA foreign_keys=OFF; ALTER TABLE bay_job RENAME TO old_bay; CREATE TABLE bay_job(cid,ord,hq,kind); DROP TABLE old_bay" }) |sql| {
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        _ = try Store.fromDb(raw);
        try raw.exec(sql);
        try expectStoreRefusedUnchanged(raw, error.CorruptStore);
    }
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    const first = try Store.fromDb(raw);
    const before = try databaseFingerprintForTest(raw);
    _ = try Store.fromDb(raw);
    _ = try Store.fromDb(raw);
    try std.testing.expectEqual(before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(@as(i64, schema_version), first.getSetting("schema_version", 0));
}

test "empty schema initialization rolls back all DDL and version on storage failure" {
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    try raw.exec("PRAGMA max_page_count=1");
    const before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.StoreFull, Store.fromDb(raw));
    try std.testing.expectEqual(before, try databaseFingerprintForTest(raw));
    try raw.exec("PRAGMA max_page_count=10000");
    _ = try Store.fromDb(raw);
    _ = try Store.fromDb(raw);
}

test "old and future campaign load and overwrite refuse before gameplay decoding or replacement" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 625 });
    defer gs.deinit();
    _ = try artilleryCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    for ([_]struct { version: u32, expected: anyerror }{
        .{ .version = 1, .expected = error.SaveOlderThanGame },
        .{ .version = 36, .expected = error.SaveOlderThanGame },
        .{ .version = 59, .expected = error.SaveOlderThanGame },
        .{ .version = 60, .expected = error.SaveOlderThanGame },
        .{ .version = 61, .expected = error.SaveOlderThanGame },
        .{ .version = 62, .expected = error.SaveOlderThanGame },
        .{ .version = 63, .expected = error.SaveOlderThanGame },
        .{ .version = 64, .expected = error.SaveOlderThanGame },
        .{ .version = 65, .expected = error.SaveOlderThanGame },
        .{ .version = 66, .expected = error.SaveOlderThanGame },
        .{ .version = 67, .expected = error.SaveOlderThanGame },
        .{ .version = 68, .expected = error.SaveOlderThanGame },
        .{ .version = 69, .expected = error.SaveOlderThanGame },
        .{ .version = schema_version + 1, .expected = error.SaveNewerThanGame },
    }) |case| {
        var sql: [128:0]u8 = undefined;
        try store.db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE campaign SET schema_version={d}", .{schema_version}));
        try store.save(&gs);
        try store.db.exec(try std.fmt.bufPrintZ(&sql, "UPDATE campaign SET schema_version={d}; DELETE FROM rng_stream", .{case.version}));
        const storage_before = try databaseFingerprintForTest(store.db);
        const memory_before = digest.stateHash(&gs);
        for (0..2) |_| {
            try std.testing.expectError(case.expected, store.load(std.testing.allocator, gs.campaign_id));
            try std.testing.expectError(case.expected, store.save(&gs));
            try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(store.db));
            try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
        }
    }
}

test "current RNG requires a valid seed and exactly one fully typed row per stream" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6008 });
    defer gs.deinit();
    _ = try foundCampaignForTest(&gs, "T", .LC, .line_officer);
    stirRng(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    try store.db.exec("PRAGMA foreign_keys=OFF; ALTER TABLE rng_stream RENAME TO rng_original; CREATE TABLE rng_stream(cid,stream,format,state); DROP TABLE rng_original; ALTER TABLE meta RENAME TO meta_original; CREATE TABLE meta(cid,key,value); INSERT INTO meta SELECT * FROM meta_original; DROP TABLE meta_original");
    for ([_][*:0]const u8{
        "DELETE FROM meta WHERE key='rng_seed'",
        "UPDATE meta SET value=0.5 WHERE key='rng_seed'",
        "UPDATE meta SET value=CAST(value AS TEXT) WHERE key='rng_seed'",
        "UPDATE meta SET value=X'30' WHERE key='rng_seed'",
        "UPDATE meta SET value=NULL WHERE key='rng_seed'",
        "INSERT INTO meta SELECT * FROM meta WHERE key='rng_seed'",
        "DELETE FROM rng_stream WHERE stream='travel'",
        "INSERT INTO rng_stream SELECT * FROM rng_stream WHERE stream='travel'",
        "UPDATE rng_stream SET stream=stream||char(0) WHERE stream='travel'",
        "UPDATE rng_stream SET stream=CAST(stream AS BLOB) WHERE stream='travel'",
        "UPDATE rng_stream SET stream='unknown' WHERE stream='travel'",
        "UPDATE rng_stream SET format=0.5 WHERE stream='travel'",
        "UPDATE rng_stream SET format=CAST(format AS TEXT) WHERE stream='travel'",
        "UPDATE rng_stream SET format=NULL WHERE stream='travel'",
        "UPDATE rng_stream SET state=CAST(state AS TEXT) WHERE stream='travel'",
        "UPDATE rng_stream SET state=NULL WHERE stream='travel'",
        "UPDATE rng_stream SET state=X'00' WHERE stream='travel'",
    }) |sql| {
        try store.save(&gs);
        try store.db.exec(sql);
        const before = try databaseFingerprintForTest(store.db);
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
        try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
    }
}

test "pre-v37 bay jobs without artillery columns are refused intact before any rebuild" {
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    try raw.exec(
        \\CREATE TABLE setting(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
        \\INSERT INTO setting VALUES('schema_version',36);
        \\CREATE TABLE campaign(id INTEGER PRIMARY KEY,schema_version INTEGER);
        \\INSERT INTO campaign VALUES(1,36);
        \\CREATE TABLE bay_job(cid INTEGER NOT NULL,ord INTEGER NOT NULL,hq INTEGER,kind TEXT,unit INTEGER,item_key TEXT,duration INTEGER,queued INTEGER,started INTEGER,done INTEGER,cost INTEGER);
        \\INSERT INTO bay_job VALUES(1,0,1,'depot_repair',1,'',2,0,0,2,100);
        \\INSERT INTO bay_job VALUES(1,1,1,'fabrication',0,'comp_chassis_h',2,0,NULL,NULL,100);
    );
    try std.testing.expect(!try Store.hasColumnRt(raw, "bay_job", "artillery"));
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    try std.testing.expect(!try Store.hasColumnRt(raw, "bay_job", "artillery"));
}

/// A campaign whose due engagement is paused at the decisive phase after an
/// ROE change at the contact pause: every kind of battle row is present.
fn battleInProgressForTest(gs: *GameState) !types.ContractId {
    const battle = @import("../sim/battle.zig");
    const commands = @import("../sim/commands.zig");
    const id = try battle.dueEngagementForTest(gs, true, 30);
    try personage_rules.seedForTest(gs);
    for ([_]battle_phase_mod.Order{ .engage, .{ .roe = .cautious }, .press_on }) |order| {
        _ = try commands.execute(gs, .{ .battle_order = .{ .contract = id, .order = order } });
    }
    return id;
}

/// Gives the battle's next unattended order until it ends.
fn finishBattleForTest(gs: *GameState) !void {
    while (battle_phases_rules.inProgress(gs) != null) try @import("../sim/tick.zig").fightDueEngagement(gs);
}

test "a battle saved mid-fight loads, finishes and plays on exactly as one never saved, in memory and across a reopened file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/battle.db", .{temporary.sub_path}, 0);
    defer std.testing.allocator.free(path);
    for ([_]usize{ 1, 3 }) |orders_given| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer gs.deinit();
        const id = try @import("../sim/battle.zig").dueEngagementForTest(&gs, true, 30);
        try personage_rules.seedForTest(&gs);
        const given = [_]battle_phase_mod.Order{ .engage, .{ .roe = .cautious }, .press_on };
        for (given[0..orders_given]) |order| _ = try @import("../sim/commands.zig").execute(&gs, .{ .battle_order = .{ .contract = id, .order = order } });
        {
            const store = try Store.open(path);
            defer store.close();
            try store.save(&gs);
            try expectCurrentRoundTripForTest(store, &gs);
        }
        const reopened = try Store.open(path);
        defer reopened.close();
        var loaded = try reopened.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 1), loaded.battles_in_progress.items.len);
        try finishBattleForTest(&gs);
        try finishBattleForTest(&loaded);
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
        // And the campaigns keep playing identically after the battle.
        try @import("../sim/tick.zig").advanceReading(&gs, 20);
        try @import("../sim/tick.zig").advanceReading(&loaded, 20);
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    }
}

test "malformed battle-in-progress rows refuse to load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try battleInProgressForTest(&gs);
    const before = digest.stateHash(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    for ([_][*:0]const u8{
        "UPDATE battle_in_progress SET phase='pursuit'",
        "UPDATE battle_in_progress SET phase='contact'",
        "UPDATE battle_in_progress SET phase=''",
        "UPDATE battle_in_progress SET ord=1",
        "UPDATE battle_in_progress SET contract_id=contract_id+0.5",
        "UPDATE battle_in_progress SET contract_id=999; UPDATE battle_in_progress_order SET contract_id=999",
        "UPDATE battle_in_progress SET contract_id=-1; UPDATE battle_in_progress_order SET contract_id=-1",
        "UPDATE battle_in_progress SET contract_id=4294967296; UPDATE battle_in_progress_order SET contract_id=4294967296",
        "UPDATE contract SET status='completed' WHERE is_offer=0",
        "INSERT INTO battle_in_progress SELECT cid, ord+1, contract_id+1, phase, orders FROM battle_in_progress",
        "DELETE FROM battle_in_progress",
        "DELETE FROM battle_in_progress_order",
        "DELETE FROM battle_in_progress_order WHERE ord=2",
        "UPDATE battle_in_progress_order SET ord=5 WHERE ord=2",
        "UPDATE battle_in_progress_order SET ord=ord+0.5 WHERE ord=2",
        "UPDATE battle_in_progress_order SET order_kind='charge' WHERE ord=0",
        "UPDATE battle_in_progress_order SET order_kind='pursue', order_roe=NULL WHERE ord=1",
        "UPDATE battle_in_progress_order SET order_roe=NULL WHERE ord=1",
        "UPDATE battle_in_progress_order SET order_roe='bold' WHERE ord=1",
        "UPDATE battle_in_progress_order SET order_roe='hold' WHERE ord=0",
        "UPDATE battle_in_progress_order SET roe='standard' WHERE ord=1",
        "UPDATE battle_in_progress_order SET pause='decisive' WHERE ord=0",
        "UPDATE battle_in_progress_order SET pause='withdrawal' WHERE ord=2",
        "UPDATE battle_in_progress_order SET outcome='rout' WHERE ord=0",
        "UPDATE battle_in_progress_order SET outcome='triumph' WHERE ord=2",
        "UPDATE battle_in_progress_order SET held_field=2 WHERE ord=2",
        "UPDATE battle_in_progress_order SET held_field=1-held_field WHERE ord=2",
        "UPDATE battle_in_progress_order SET odds_next='decisive' WHERE ord=2",
        "UPDATE battle_in_progress_order SET odds_total=odds_total+1 WHERE ord=0",
        "UPDATE battle_in_progress_order SET odds_0=70000 WHERE ord=0",
        "UPDATE battle_in_progress_order SET odds_4=1, odds_total=odds_total+1 WHERE ord=2",
        "UPDATE battle_in_progress_order SET hits=-1 WHERE ord=0",
        "UPDATE battle_in_progress_order SET hits=1.5 WHERE ord=0",
        "UPDATE battle_in_progress_order SET margin=2147483648 WHERE ord=0",
        "UPDATE battle_in_progress_order SET momentum=-2147483649 WHERE ord=0",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
        var invalid = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            try std.testing.expectEqual(before, digest.stateHash(&gs));
            continue;
        };
        invalid.deinit();
        std.debug.print("accepted battle-in-progress corruption: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
    // A second record for the same contract, past the primary key.
    try store.save(&gs);
    try store.db.exec("PRAGMA foreign_keys=OFF; ALTER TABLE battle_in_progress RENAME TO bip_old; CREATE TABLE battle_in_progress(cid,ord,contract_id,phase,orders); INSERT INTO battle_in_progress SELECT * FROM bip_old; INSERT INTO battle_in_progress SELECT cid, ord+1, contract_id, phase, orders FROM bip_old; DROP TABLE bip_old; PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "a battle report's phases round trip, and malformed phase rows refuse to load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try battleInProgressForTest(&gs);
    try finishBattleForTest(&gs);
    const report = gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
    try std.testing.expectEqual(@as(usize, 3), report.phases.len);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    for ([_][*:0]const u8{
        "UPDATE battle_report_phase SET phase='charge' WHERE ord=0",
        "UPDATE battle_report_phase SET order_kind='charge' WHERE ord=0",
        "UPDATE battle_report_phase SET order_roe='hold' WHERE ord=0",
        "UPDATE battle_report_phase SET order_kind='roe' WHERE ord=0",
        "UPDATE battle_report_phase SET roe='bold' WHERE ord=0",
        "UPDATE battle_report_phase SET ord=5 WHERE ord=2",
        "UPDATE battle_report_phase SET ord=ord+0.5 WHERE ord=2",
        "UPDATE battle_report_phase SET report_ord=999",
        "UPDATE battle_report_phase SET hits=-1 WHERE ord=0",
        "UPDATE battle_report_phase SET hits=4294967296 WHERE ord=0",
        "UPDATE battle_report_phase SET margin=2147483648 WHERE ord=0",
        "UPDATE battle_report_phase SET ratio_bonus=0.5 WHERE ord=0",
        "INSERT INTO battle_report_phase SELECT cid,report_ord,3,phase,order_kind,order_roe,roe,ratio_bonus,scenario_mod,roe_roll,momentum,lever_mod,margin,hits FROM battle_report_phase WHERE ord=0",
    }) |tamper| {
        try store.save(&gs);
        try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
        try store.db.exec(tamper);
        try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
        var invalid = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
            try std.testing.expectEqual(error.CorruptSave, err);
            continue;
        };
        invalid.deinit();
        std.debug.print("accepted battle phase corruption: {s}\n", .{tamper});
        return error.TestExpectedError;
    }
}

/// Saves `gs`, applies `tamper` with every column constraint enforced, and
/// requires the load to refuse it as `CorruptSave` with the stored rows and
/// the source campaign unchanged.
fn expectBattleTamperRefusedForTest(store: Store, gs: *GameState, tamper: [*:0]const u8) !void {
    try store.save(gs);
    const source = digest.stateHash(gs);
    try store.db.exec(tamper);
    const stored = try databaseFingerprintForTest(store.db);
    var invalid = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        try std.testing.expectEqual(stored, try databaseFingerprintForTest(store.db));
        try std.testing.expectEqual(source, digest.stateHash(gs));
        return;
    };
    invalid.deinit();
    std.debug.print("accepted battle corruption: {s}\n", .{tamper});
    return error.TestExpectedError;
}

test "a battle in progress whose rows are removed refuses to load, the store and campaign unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try battleInProgressForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    for ([_][*:0]const u8{
        // Both tables' rows: the contact history and the battle lock gone.
        "DELETE FROM battle_in_progress_order; DELETE FROM battle_in_progress",
        // The last order, the pause rewound to the shorter course it leaves.
        "DELETE FROM battle_in_progress_order WHERE ord=2; UPDATE battle_in_progress SET phase='contact'",
        // The completeness counts themselves missing, malformed or wrong.
        "DELETE FROM meta WHERE key='battle_in_progress_count'",
        "UPDATE meta SET value=0 WHERE key='battle_in_progress_count'",
        "UPDATE meta SET value=2 WHERE key='battle_in_progress_count'",
        "UPDATE meta SET value=-1 WHERE key='battle_in_progress_count'",
        "UPDATE meta SET value=1.5 WHERE key='battle_in_progress_count'",
        "UPDATE battle_in_progress SET orders=orders+1",
        "UPDATE battle_in_progress SET orders=orders-1",
    }) |tamper| try expectBattleTamperRefusedForTest(store, &gs, tamper);
}

test "a due engagement not yet engaged, and a finished one, load with no battle in progress" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const id = try @import("../sim/battle.zig").dueEngagementForTest(&gs, true, 30);
    try personage_rules.seedForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    {
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 0), loaded.battles_in_progress.items.len);
        try std.testing.expectEqual(@as(?types.ContractId, id), @import("../sim/battle.zig").dueEngagement(&loaded));
    }
    // A count that claims a battle the rows do not hold.
    try expectBattleTamperRefusedForTest(store, &gs, "UPDATE meta SET value=1 WHERE key='battle_in_progress_count'");
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .battle_order = .{ .contract = id, .order = .engage } });
    try finishBattleForTest(&gs);
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
}

test "a battle report whose phase rows are removed refuses to load; a concession or a forfeit keeps none" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try battleInProgressForTest(&gs);
    try finishBattleForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    for ([_][*:0]const u8{
        // The terminal phase.
        "DELETE FROM battle_report_phase WHERE ord=(SELECT MAX(ord) FROM battle_report_phase)",
        // Every phase of a fought battle.
        "DELETE FROM battle_report_phase",
        // The decisive phase, the terminal one renumbered to close the gap.
        "DELETE FROM battle_report_phase WHERE ord=1; UPDATE battle_report_phase SET ord=1 WHERE ord=2",
        // The terminal phase, the count lowered to match: an unfinished course.
        "DELETE FROM battle_report_phase WHERE ord=2; UPDATE battle_report SET phase_count=2",
        // The count itself wrong.
        "UPDATE battle_report SET phase_count=phase_count-1",
        "UPDATE battle_report SET phase_count=0",
        // Every phase and the count with them: the fought verdict and its
        // consequences are left with no course, which no concession or
        // forfeit carries.
        "DELETE FROM battle_report_phase; UPDATE battle_report SET phase_count=0",
        // A fought verdict the phases do not carry.
        "UPDATE battle_report SET hits_taken=hits_taken+1",
        "UPDATE battle_report SET outcome=CASE outcome WHEN 'rout' THEN 'victory' ELSE 'rout' END",
        "UPDATE battle_report SET held_field=1-held_field",
        "UPDATE battle_report_phase SET momentum=momentum+1 WHERE ord=1",
        // Modifiers that leave every margin and band as they were but put
        // the contact and decisive dice outside 2d6.
        "UPDATE battle_report_phase SET ratio_bonus=ratio_bonus+100 WHERE ord<2",
        "UPDATE battle_report_phase SET ratio_bonus=ratio_bonus-100 WHERE ord<2",
    }) |tamper| try expectBattleTamperRefusedForTest(store, &gs, tamper);
    // The battle's terminal phase rewritten to a clean pursuit (held field)
    // or a clean covered recovery (lost field), which take no hits: on a die
    // 2d6 shows it loads, on a die of 200 it is refused.
    const held = gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1].held_field;
    const terminal = if (held) "order_kind='pursue'" else "order_kind='cover_recovery'";
    const tuning = @import("../domain/tuning.zig").t;
    const clean_margin: i32 = @as(i32, rng_mod.roll2d6_max) - tuning.battle.phases.par;
    const feasible = try std.fmt.allocPrintSentinel(std.testing.allocator, "UPDATE battle_report_phase SET {s}, margin={d} WHERE ord=2", .{ terminal, clean_margin }, 0);
    defer std.testing.allocator.free(feasible);
    try store.save(&gs);
    try store.db.exec(feasible);
    {
        var rewritten = try store.load(std.testing.allocator, gs.campaign_id);
        defer rewritten.deinit();
        try std.testing.expectEqual(clean_margin, rewritten.battle_reports.kept.items[rewritten.battle_reports.kept.items.len - 1].phases[2].margin);
    }
    const impossible = try std.fmt.allocPrintSentinel(std.testing.allocator, "UPDATE battle_report_phase SET {s}, margin={d} WHERE ord=2", .{ terminal, 200 - tuning.battle.phases.par }, 0);
    defer std.testing.allocator.free(impossible);
    try expectBattleTamperRefusedForTest(store, &gs, impossible);
    // A concession and a forfeit fight no phase: their empty reports load.
    for ([_]bool{ false, true }) |forfeited| {
        var one_step = GameState.init(std.testing.allocator, .{ .seed = 3007 });
        defer one_step.deinit();
        const id = try @import("../sim/battle.zig").dueEngagementForTest(&one_step, forfeited, 100);
        try personage_rules.seedForTest(&one_step);
        if (forfeited) {
            one_step.faction_rosters.getPtr("DC").?.clearRetainingCapacity();
        } else {
            for (one_step.units.values()) |*u| u.status = .destroyed;
        }
        _ = try @import("../sim/commands.zig").execute(&one_step, .{ .battle_order = .{ .contract = id, .order = .engage } });
        const report = one_step.battle_reports.kept.items[one_step.battle_reports.kept.items.len - 1];
        try std.testing.expectEqual(@as(usize, 0), report.phases.len);
        try std.testing.expectEqual(!forfeited, report.conceded);
        const one_step_store = try Store.open(":memory:");
        defer one_step_store.close();
        try one_step_store.save(&one_step);
        var loaded = try one_step_store.load(std.testing.allocator, one_step.campaign_id);
        defer loaded.deinit();
        const reloaded = loaded.battle_reports.kept.items[loaded.battle_reports.kept.items.len - 1];
        try std.testing.expectEqual(report.id, reloaded.id);
        try std.testing.expectEqual(@as(usize, 0), reloaded.phases.len);
        try std.testing.expectEqual(report.conceded, reloaded.conceded);
    }
}

test "a battle in progress whose stored pauses its replay does not reach refuses to load, the store and campaign unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    const id = try battleInProgressForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    // A forged decisive verdict that every column constraint and
    // `recordConsistent` accept: another outcome, with its field and odds.
    const record = battle_phases_rules.inProgress(&gs).?;
    const real = record.latest().*;
    const outcome: autoresolve_mod.Outcome = if (real.outcome.? == .victory) .defeat else .victory;
    const held = battle_phases_rules.heldField(outcome, real.roe);
    const next: battle_phase_mod.NextPhase = if (held) .pursuit else .cover;
    const steps = try std.testing.allocator.dupe(battle_phase_mod.Step, record.steps.items);
    defer std.testing.allocator.free(steps);
    steps[steps.len - 1].report.outcome = outcome;
    steps[steps.len - 1].report.held_field = held;
    steps[steps.len - 1].report.odds = .{ .next = next, .counts = .{ 36, 0, 0, 0, 0 }, .total = 36 };
    const forged: battle_phase_mod.BattleInProgress = .{ .contract = id, .phase = .decisive, .steps = .{ .items = steps, .capacity = steps.len } };
    try std.testing.expect(battle_phases_rules.recordConsistent(&forged));
    var sql: [320]u8 = undefined;
    try expectBattleTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&sql, "UPDATE battle_in_progress_order SET outcome='{s}', held_field={d}, odds_next='{s}', odds_0=36, odds_1=0, odds_2=0, odds_3=0, odds_4=0, odds_total=36 WHERE pause='decisive'", .{ @tagName(outcome), @intFromBool(held), @tagName(next) }));
    for ([_][*:0]const u8{
        // Impossible contact figures inside every column range.
        "UPDATE battle_in_progress_order SET hits=4294967295, margin=2147483647, momentum=2147483647 WHERE ord=0",
        "UPDATE battle_in_progress_order SET hits=hits+1 WHERE ord=0",
        "UPDATE battle_in_progress_order SET margin=margin+1 WHERE ord=0",
        "UPDATE battle_in_progress_order SET momentum=momentum+1 WHERE ord=0",
        "UPDATE battle_in_progress_order SET roe=CASE roe WHEN 'hold' THEN 'standard' ELSE 'hold' END WHERE ord=0",
        "UPDATE battle_in_progress_order SET odds_0=odds_total, odds_1=0, odds_2=0, odds_3=0, odds_4=0 WHERE ord=0",
        "UPDATE battle_in_progress_order SET hits=hits+1 WHERE pause='decisive'",
        "UPDATE battle_in_progress_order SET margin=margin-1 WHERE pause='decisive'",
        // Another ROE order, its report agreeing with it: the replay does not.
        "UPDATE battle_in_progress_order SET order_roe='hold', roe='hold' WHERE ord=1",
    }) |tamper| try expectBattleTamperRefusedForTest(store, &gs, tamper);
    // A contract whose engagement is not yet due: no battle could have started.
    try expectBattleTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&sql, "UPDATE contract SET next_battle=next_battle+5 WHERE is_offer=0 AND id={d}", .{@intFromEnum(id)}));

    // Under integrated command the employer holds the ROE: a saved record
    // holding an ROE order is one the command refuses.
    var locked = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer locked.deinit();
    const lid = try @import("../sim/battle.zig").dueEngagementForTest(&locked, true, 30);
    try personage_rules.seedForTest(&locked);
    for ([_]battle_phase_mod.Order{ .engage, .{ .roe = .cautious } }) |order| {
        _ = try @import("../sim/commands.zig").execute(&locked, .{ .battle_order = .{ .contract = lid, .order = order } });
    }
    const locked_store = try Store.open(":memory:");
    defer locked_store.close();
    try locked_store.save(&locked);
    try expectCurrentRoundTripForTest(locked_store, &locked);
    try expectBattleTamperRefusedForTest(locked_store, &locked, try std.fmt.bufPrintZ(&sql, "UPDATE contract SET command_rights='integrated' WHERE is_offer=0 AND id={d}", .{@intFromEnum(lid)}));
}

test "a store at format 64 is refused before any change, battle in progress or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer gs.deinit();
    _ = try battleInProgressForTest(&gs);
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 64 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    // A campaign row at 64 in a current store is refused the same way.
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 64", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

/// The orders `leverBattleInProgressForTest` gives: every lever row kind,
/// then the decisive phase.
const lever_course_for_test = [_]battle_phase_mod.Order{ .engage, .commit_reserve, .{ .intervene = .reinforce }, .{ .intervene = .emergency_recon }, .press_on };

/// A campaign at seed 3 whose engagement, on a committed combat operation
/// with a reserve lance, has the first `n` of `lever_course_for_test` given.
fn leverBattleInProgressForTest(gs: *GameState, n: usize) !types.ContractId {
    const id = try @import("../sim/battle.zig").leverEngagementForTest(gs, 30, 4);
    try personage_rules.seedForTest(gs);
    for (lever_course_for_test[0..n]) |order| {
        _ = try @import("../sim/commands.zig").execute(gs, .{ .battle_order = .{ .contract = id, .order = order } });
    }
    return id;
}

/// Saves `gs`, applies `tamper` with column constraints and foreign keys
/// off, and requires the load to refuse it as `CorruptSave` with the
/// source campaign unchanged.
fn expectUncheckedTamperRefusedForTest(store: Store, gs: *GameState, tamper: [*:0]const u8) !void {
    try store.save(gs);
    const source = digest.stateHash(gs);
    try store.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
    try store.db.exec(tamper);
    try store.db.exec("PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=OFF");
    var invalid = store.load(std.testing.allocator, gs.campaign_id) catch |err| {
        try std.testing.expectEqual(error.CorruptSave, err);
        try std.testing.expectEqual(source, digest.stateHash(gs));
        return;
    };
    invalid.deinit();
    std.debug.print("accepted lever corruption: {s}\n", .{tamper});
    return error.TestExpectedError;
}

test "a battle saved after its levers loads, finishes and plays on exactly as one never saved, in memory and across a reopened file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/levers.db", .{temporary.sub_path}, 0);
    defer std.testing.allocator.free(path);
    for ([_]usize{ 2, 4, 5 }) |orders_given| {
        var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
        defer gs.deinit();
        _ = try leverBattleInProgressForTest(&gs, orders_given);
        {
            const store = try Store.open(path);
            defer store.close();
            try store.save(&gs);
            try expectCurrentRoundTripForTest(store, &gs);
        }
        const reopened = try Store.open(path);
        defer reopened.close();
        var loaded = try reopened.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqualDeep(battle_phases_rules.inProgress(&gs).?.latest().*, battle_phases_rules.inProgress(&loaded).?.latest().*);
        try finishBattleForTest(&gs);
        try finishBattleForTest(&loaded);
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
        // The finished report keeps its levers, and the campaign plays on identically.
        try std.testing.expect(gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1].levers.len > 0);
        try @import("../sim/tick.zig").advanceReading(&gs, 20);
        try @import("../sim/tick.zig").advanceReading(&loaded, 20);
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    }
}

test "malformed lever rows in a battle in progress refuse to load, and so do levers the replay no longer allows" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    const id = try leverBattleInProgressForTest(&gs, lever_course_for_test.len);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    // Orders 1-3 are the levers; 4 presses on.
    for ([_][*:0]const u8{
        "UPDATE battle_in_progress_order SET order_kind='intervene', order_intervention=NULL WHERE ord=1",
        "UPDATE battle_in_progress_order SET order_intervention='artillery' WHERE ord=2",
        "UPDATE battle_in_progress_order SET order_intervention='reinforce' WHERE ord=1",
        "UPDATE battle_in_progress_order SET order_intervention=NULL WHERE ord=2",
        "UPDATE battle_in_progress_order SET order_kind='commit_reserve', order_intervention=NULL WHERE ord=2",
        "UPDATE battle_in_progress_order SET order_intervention='reinforce' WHERE ord=3",
        "UPDATE battle_in_progress_order SET order_kind='call' WHERE ord=1",
        "UPDATE battle_in_progress_order SET lever_mod=lever_mod+1 WHERE ord=2",
        "UPDATE battle_in_progress_order SET lever_mod=2147483648 WHERE ord=0",
        "UPDATE battle_in_progress_order SET lever_mod=0.5 WHERE ord=0",
        "UPDATE battle_in_progress_order SET capacity_spent=capacity_spent+1 WHERE ord=4",
        "UPDATE battle_in_progress_order SET capacity_spent=256 WHERE ord=0",
        "UPDATE battle_in_progress_order SET capacity_spent=-1 WHERE ord=0",
        "UPDATE battle_in_progress_order SET capacity_spent=1.5 WHERE ord=0",
        "UPDATE battle_in_progress_order SET reserve_committed=2 WHERE ord=0",
        "UPDATE battle_in_progress_order SET reserve_committed=0 WHERE ord=3",
        "UPDATE battle_in_progress_order SET reserve_committed=1 WHERE ord=0",
        "DELETE FROM battle_in_progress_order WHERE ord=1; UPDATE battle_in_progress_order SET ord=ord-1 WHERE ord>1; UPDATE battle_in_progress SET orders=orders-1",
    }) |tamper| try expectUncheckedTamperRefusedForTest(store, &gs, tamper);
    // Every row and constraint holds, and contact replays as it was, but the
    // replay from live state no longer allows a lever: the capacity is gone,
    // the reserve lance is untasked, or the operation is no longer committed.
    var sql: [256]u8 = undefined;
    try expectBattleTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&sql, "UPDATE contract SET command_capacity=0 WHERE is_offer=0 AND id={d}", .{@intFromEnum(id)}));
    try expectBattleTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&sql, "DELETE FROM operation_task WHERE contract_id={d}", .{@intFromEnum(id)}));
    try expectBattleTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&sql, "UPDATE operation SET state='available' WHERE contract_id={d}", .{@intFromEnum(id)}));
}

test "a battle report's levers round trip, and missing, malformed or forged lever rows refuse to load" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 3 });
    defer gs.deinit();
    _ = try leverBattleInProgressForTest(&gs, lever_course_for_test.len);
    try finishBattleForTest(&gs);
    const report = gs.battle_reports.kept.items[gs.battle_reports.kept.items.len - 1];
    try std.testing.expectEqual(@as(usize, 3), report.levers.len);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    for ([_][*:0]const u8{
        // A missing, extra or misnumbered row, or a count the rows do not match.
        "DELETE FROM battle_report_lever WHERE ord=2",
        "DELETE FROM battle_report_lever WHERE ord=1; UPDATE battle_report_lever SET ord=1 WHERE ord=2; UPDATE battle_report SET lever_count=lever_count-1",
        "UPDATE battle_report SET lever_count=lever_count+1",
        "UPDATE battle_report SET lever_count=6",
        "UPDATE battle_report SET lever_count=1.5",
        "UPDATE battle_report_lever SET ord=5 WHERE ord=2",
        "UPDATE battle_report_lever SET ord=ord+0.5 WHERE ord=2",
        "INSERT INTO battle_report_lever SELECT cid,report_ord,3,kind,cost,roll_mod FROM battle_report_lever WHERE ord=0; UPDATE battle_report SET lever_count=lever_count+1",
        "UPDATE battle_report_lever SET report_ord=999",
        // An unknown kind, or figures out of range or other than the owners give.
        "UPDATE battle_report_lever SET kind='artillery' WHERE ord=0",
        "UPDATE battle_report_lever SET cost=cost+1 WHERE ord=1",
        "UPDATE battle_report_lever SET cost=256 WHERE ord=1",
        "UPDATE battle_report_lever SET cost=-1 WHERE ord=0",
        "UPDATE battle_report_lever SET roll_mod=roll_mod+1 WHERE ord=0",
        "UPDATE battle_report_lever SET roll_mod=2147483648 WHERE ord=0",
        "UPDATE battle_report_lever SET roll_mod=0.5 WHERE ord=0",
        // A decisive lever modifier the levers do not sum to, its margin moved with it.
        "UPDATE battle_report_phase SET lever_mod=lever_mod+1, margin=margin+1 WHERE ord=1",
        "UPDATE battle_report_phase SET lever_mod=1 WHERE ord=0",
        "UPDATE battle_report_phase SET lever_mod=2147483648 WHERE ord=1",
        // A reserve commitment on a flag no boolean holds, or on a non-combat operation.
        "UPDATE operation SET reserve_committed=2",
        "UPDATE operation SET reserve_committed=0.5",
        "UPDATE operation SET template_key='negotiate_terms', reserve_committed=1",
    }) |tamper| try expectUncheckedTamperRefusedForTest(store, &gs, tamper);
    // The same template change without the flag loads: the flag alone was refused.
    try store.save(&gs);
    try store.db.exec("UPDATE operation SET template_key='negotiate_terms', reserve_committed=0");
    var control = try store.load(std.testing.allocator, gs.campaign_id);
    control.deinit();

    // A concession fights no phase and pulls no lever.
    var conceded = GameState.init(std.testing.allocator, .{ .seed = 3007 });
    defer conceded.deinit();
    const cid = try @import("../sim/battle.zig").dueEngagementForTest(&conceded, false, 100);
    try personage_rules.seedForTest(&conceded);
    for (conceded.units.values()) |*u| u.status = .destroyed;
    _ = try @import("../sim/commands.zig").execute(&conceded, .{ .battle_order = .{ .contract = cid, .order = .engage } });
    try std.testing.expect(conceded.battle_reports.kept.items[conceded.battle_reports.kept.items.len - 1].conceded);
    const conceded_store = try Store.open(":memory:");
    defer conceded_store.close();
    try conceded_store.save(&conceded);
    try expectCurrentRoundTripForTest(conceded_store, &conceded);
    try expectBattleTamperRefusedForTest(conceded_store, &conceded, "INSERT INTO battle_report_lever SELECT cid, ord, 0, 'commit_reserve', 0, 2 FROM battle_report; UPDATE battle_report SET lever_count=1");
}

/// A garrison contract whose black-market contact sold the company crates
/// (record answered, the contact and the world flagged) and whose militia
/// commander's drill is pending, with a notice decision beside it.
fn situationCampaignForTest(gs: *GameState) !*contract_mod.Contract {
    const situations = @import("../sim/situations.zig");
    const c = try situations.garrisonContractForTest(gs);
    try personage_rules.seedForTest(gs);
    try std.testing.expect(try situations.queueDue(gs, c));
    try contract_events.resolveChoice(gs, gs.event_queue.pending.items[0].id, 0);
    c.arc_beat = 1;
    try std.testing.expect(try situations.queueDue(gs, c));
    try contract_events.queueNotice(gs, gs.people.keys()[0]);
    return c;
}

fn pendingSituationForTest(gs: *GameState) types.EventId {
    for (gs.event_queue.pending.items) |ev| if (ev.kind == .situation) return ev.id;
    unreachable;
}

test "a pending situation, its records and the flags survive save, load and a reopened file, and play on identically" {
    const commands = @import("../sim/commands.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/situations.db", .{temporary.sub_path}, 0);
    defer std.testing.allocator.free(path);
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6201 });
    defer gs.deinit();
    const c = try situationCampaignForTest(&gs);
    try std.testing.expectEqual(@as(usize, 2), c.situations.items.len);
    {
        const store = try Store.open(path);
        defer store.close();
        try store.save(&gs);
        try expectCurrentRoundTripForTest(store, &gs);
    }
    const store = try Store.open(path);
    defer store.close();
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expect(loaded.actors.values()[0].flags.count() + loaded.worldState("galatea").?.flags.count() > 0);
    // Answering after the reload is answering without the save.
    for ([_]*GameState{ &gs, &loaded }) |g| {
        _ = try commands.execute(g, .{ .resolve_decision = .{ .event = pendingSituationForTest(g), .choice = 0 } });
        _ = try commands.execute(g, .advance_day);
    }
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expect(loaded.worldState("galatea").?.flags.contains(.militia_trained));
}

test "situation records, situation decisions and flags fail closed on every malformed form" {
    const situations = @import("../sim/situations.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6202 });
    defer gs.deinit();
    const c = try situationCampaignForTest(&gs);
    const liaison = @intFromEnum(situations.ownerOf(&gs, c, "liaison").?.id);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    var buf: [256:0]u8 = undefined;
    const tampers = [_][*:0]const u8{
        // Flags: an unknown bit, a negative or non-integer value, both of
        // an exclusive pair (did_business and informed_on; an open and a
        // closed black market).
        "UPDATE actor SET flags=16",
        "UPDATE actor SET flags=-1",
        "UPDATE actor SET flags='x'",
        "UPDATE actor SET flags=3",
        "UPDATE actor SET flags=11",
        "UPDATE world_state SET flags=8",
        "UPDATE world_state SET flags='y'",
        "UPDATE world_state SET flags=3",
        "UPDATE world_state SET flags=7",
        // Records: unknown key, another arc, out of range, duplicate, out of order, from the future.
        "UPDATE contract_situation SET situation='no_such_situation' WHERE ord=0",
        "UPDATE contract_situation SET situation=X'6162' WHERE ord=0",
        "UPDATE contract SET arc_key='aid_under_siege'",
        "UPDATE contract_situation SET choice=3 WHERE ord=0",
        "UPDATE contract_situation SET choice=-1 WHERE ord=0",
        "UPDATE contract_situation SET ord=5 WHERE ord=1",
        "UPDATE contract_situation SET day=4000000000 WHERE ord=0",
        "UPDATE contract_situation SET actor=999 WHERE ord=0",
        "UPDATE contract_situation SET contract=999 WHERE ord=0",
        // A pending situation and its record disagree.
        "DELETE FROM contract_situation WHERE ord=1",
        "UPDATE contract_situation SET choice=0 WHERE ord=1",
        "DELETE FROM pending_event WHERE kind='situation'",
        "UPDATE pending_event SET situation='crates_off_the_books' WHERE kind='situation'",
        "UPDATE pending_event SET situation=NULL WHERE kind='situation'",
        "UPDATE pending_event SET situation='no_such_situation' WHERE kind='situation'",
        "UPDATE pending_event SET actor=0 WHERE kind='situation'",
        // Owners that are not integers but convert to the record's actor.
        "UPDATE pending_event SET actor=actor+0.5 WHERE kind='situation'",
        "UPDATE pending_event SET actor=CAST(actor AS TEXT)||'x' WHERE kind='situation'",
        "UPDATE pending_event SET default_choice=0 WHERE kind='situation'",
        "UPDATE pending_event SET chosen=0 WHERE kind='situation'",
        "UPDATE pending_event SET contract=999 WHERE kind='situation'",
        "INSERT INTO pending_event SELECT cid, 9, kind, day, contract, company, default_choice, deadline, chosen, person, id + 1, battle, situation, actor FROM pending_event WHERE kind='situation'; UPDATE meta SET value=value+1 WHERE key='next_event_id'",
        // Another decision names no situation and no actor.
        "UPDATE pending_event SET situation='drill_the_militia' WHERE kind='notice_given'",
        "UPDATE pending_event SET actor=1 WHERE kind='notice_given'",
        // Non-integer actors that convert to no actor.
        "UPDATE pending_event SET actor='invalid' WHERE kind='notice_given'",
        "UPDATE pending_event SET actor=0.5 WHERE kind='notice_given'",
    };
    for (tampers) |tamper| try expectUncheckedTamperRefusedForTest(store, &gs, tamper);
    // An owner that is the contract's actor of another archetype.
    try expectUncheckedTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&buf, "UPDATE contract_situation SET actor={d} WHERE ord=0", .{liaison}));
    try expectUncheckedTamperRefusedForTest(store, &gs, try std.fmt.bufPrintZ(&buf, "UPDATE pending_event SET actor={d} WHERE kind='situation'", .{liaison}));
    // A situation raised twice on one contract, past the table's own
    // uniqueness (rebuilt without it, so the loader alone must refuse).
    try expectUncheckedTamperRefusedForTest(store, &gs, "CREATE TABLE cs AS SELECT * FROM contract_situation; DROP TABLE contract_situation; CREATE TABLE contract_situation AS SELECT * FROM cs; DROP TABLE cs; INSERT INTO contract_situation SELECT cid, contract, 2, situation, day, actor, choice FROM contract_situation WHERE ord=0");
    // A NULL actor, past the column's NOT NULL (rebuilt without it).
    try expectUncheckedTamperRefusedForTest(store, &gs, "CREATE TABLE pe AS SELECT * FROM pending_event; DROP TABLE pending_event; CREATE TABLE pending_event AS SELECT * FROM pe; DROP TABLE pe; UPDATE pending_event SET actor=NULL WHERE kind='notice_given'");
}

/// Run `tamper` in a transaction whose COMMIT the schema must refuse, and
/// show the store unchanged afterwards.
fn expectCommitRefusedForTest(store: Store, tamper: [*:0]const u8) !void {
    const before = try databaseFingerprintForTest(store.db);
    try store.db.exec("BEGIN");
    store.db.exec(tamper) catch |err| {
        try store.db.exec("ROLLBACK");
        try std.testing.expectEqual(error.ConstraintViolation, err);
        try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
        return;
    };
    try std.testing.expectError(error.ConstraintViolation, store.db.exec("COMMIT"));
    try store.db.exec("ROLLBACK");
    try std.testing.expectEqual(before, try databaseFingerprintForTest(store.db));
}

test "the schema refuses a situation record without its campaign's actor, and flags that exclude each other" {
    // The provoked constraint failures are expected; keep their warnings out of stderr.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6204 });
    defer gs.deinit();
    _ = try situationCampaignForTest(&gs);
    var other = GameState.init(std.testing.allocator, .{ .seed = 6205 });
    defer other.deinit();
    _ = try foundCampaignForTest(&other, "T", .LC, .line_officer);
    const store = try Store.open(":memory:");
    defer store.close();
    // A first save, an overwrite and a second campaign beside it commit.
    try store.save(&gs);
    try store.save(&gs);
    try store.save(&other);
    try expectCurrentRoundTripForTest(store, &gs);
    var buf: [512:0]u8 = undefined;
    // An actor that does not exist, one that exists only in the other
    // campaign, and the actor deleted from under its record.
    try expectCommitRefusedForTest(store, try std.fmt.bufPrintZ(&buf, "UPDATE contract_situation SET actor=999 WHERE cid={d}", .{gs.campaign_id}));
    try expectCommitRefusedForTest(store, try std.fmt.bufPrintZ(&buf, "INSERT INTO actor (cid, ord, id, archetype_key, first_name, last_name, faction_key, side, flags) VALUES ({d}, 0, 999, 'black_market', 'A', 'B', 'f', 'enemy', 0); UPDATE contract_situation SET actor=999 WHERE cid={d}", .{ other.campaign_id, gs.campaign_id }));
    try expectCommitRefusedForTest(store, try std.fmt.bufPrintZ(&buf, "DELETE FROM actor WHERE cid={d}", .{gs.campaign_id}));
    // Both of an exclusive pair, among other flags or alone.
    try expectCommitRefusedForTest(store, "UPDATE actor SET flags=3");
    try expectCommitRefusedForTest(store, "UPDATE actor SET flags=11");
    try expectCommitRefusedForTest(store, "UPDATE world_state SET flags=3");
    try expectCommitRefusedForTest(store, "UPDATE world_state SET flags=7");
    // A save retried after the refusals, and deleting the campaign, commit;
    // the other campaign still loads.
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    try store.deleteCampaign(gs.campaign_id);
    var loaded = try store.load(std.testing.allocator, other.campaign_id);
    loaded.deinit();
}

test "a store or a campaign at format 65 is refused before any change, situations pending or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6203 });
    defer gs.deinit();
    _ = try situationCampaignForTest(&gs);
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 65 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 65", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

test "a store or a campaign at format 66 is refused before any change, artillery pooled or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6604 });
    defer gs.deinit();
    _ = try artilleryCampaignForTest(&gs);
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 66 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 66", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

test "a store or a campaign at format 67 is refused before any change, merc companies seeded or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6705 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    try std.testing.expect(gs.merc_companies.count() > 0);
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 67 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 67", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

test "a store or a campaign at format 68 is refused before any change, an understrength record held or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6805 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    try std.testing.expect(gs.merc_companies.count() > 1);
    gs.merc_companies.values()[0].understrength_since = gs.clock.day_index;
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 68 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 68", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

test "a store or a campaign at format 69 is refused before any change, personages held or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 6905 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    try std.testing.expect(gs.personages.count() >= personage_rules.seed_count);
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 69 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 69", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

test "a store or a campaign at format 70 is refused before any change, relations held or not" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 7005 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    try std.testing.expect(gs.personage_relations.items.len > 0);
    try std.testing.expectEqual(@as(i64, 76), schema_version);
    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    var store = try Store.fromDb(raw);
    try store.save(&gs);
    try raw.exec("UPDATE setting SET value = 70 WHERE key = 'schema_version'");
    try expectStoreRefusedUnchanged(raw, error.StoreOlderThanGame);
    var sql: [128:0]u8 = undefined;
    try raw.exec(try std.fmt.bufPrintZ(&sql, "UPDATE setting SET value = {d} WHERE key = 'schema_version'; UPDATE campaign SET schema_version = 70", .{schema_version}));
    store = try Store.fromDb(raw);
    const memory_before = digest.stateHash(&gs);
    const storage_before = try databaseFingerprintForTest(raw);
    try std.testing.expectError(error.SaveOlderThanGame, store.load(std.testing.allocator, gs.campaign_id));
    try std.testing.expectError(error.SaveOlderThanGame, store.save(&gs));
    try std.testing.expectEqual(storage_before, try databaseFingerprintForTest(raw));
    try std.testing.expectEqual(memory_before, digest.stateHash(&gs));
}

test "a created campaign's personages and their counter survive save and load, and the campaign plays on identically" {
    // Rules 46, 53, 70; docs/p5d-conflict-world-design.md §J.
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70001 });
    defer gs.deinit();
    _ = try commands.execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer, .start_year = personage_data_for_test.reference_year } });
    try std.testing.expectEqual(personage_rules.seatedCount(personage_data_for_test.reference_year), gs.personages.count());
    var provenances = std.EnumSet(personage_mod.Provenance).initEmpty();
    for (gs.personages.values()) |p| provenances.insert(p.provenance);
    try std.testing.expect(provenances.eql(.initFull()));
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expectEqual(gs.next_personage_id, loaded.next_personage_id);
    for (gs.personages.values(), loaded.personages.values()) |p, q| {
        try std.testing.expectEqual(p.id, q.id);
        try std.testing.expectEqual(p.role, q.role);
        try std.testing.expectEqualStrings(p.first_name, q.first_name);
        try std.testing.expectEqualStrings(p.last_name, q.last_name);
        try std.testing.expectEqualStrings(p.faction_key, q.faction_key);
        try std.testing.expectEqualStrings(p.seat_planet_key, q.seat_planet_key);
        try std.testing.expect(p.motives.eql(q.motives));
        try std.testing.expectEqual(p.ambition, q.ambition);
        try std.testing.expectEqual(p.provenance, q.provenance);
        try std.testing.expectEqual(p.generator_version, q.generator_version);
        try std.testing.expectEqualStrings(p.key, q.key);
        try std.testing.expectEqualStrings(p.family_key, q.family_key);
    }
    // The relations come back in order, field for field.
    try std.testing.expect(gs.personage_relations.items.len > 0);
    try std.testing.expectEqualSlices(personage_mod.Relation, gs.personage_relations.items, loaded.personage_relations.items);
    // The personage fields, the relations and the counter are digest-covered.
    const hash = digest.stateHash(&gs);
    gs.personages.values()[0].ambition ^= 1;
    try std.testing.expect(digest.stateHash(&gs) != hash);
    gs.personages.values()[0].ambition ^= 1;
    for (gs.personages.values()) |*p| {
        if (p.key.len == 0 or p.family_key.len == 0) continue;
        const key = p.key;
        p.key = "other_key";
        try std.testing.expect(digest.stateHash(&gs) != hash);
        p.key = key;
        const family = p.family_key;
        p.family_key = "";
        try std.testing.expect(digest.stateHash(&gs) != hash);
        p.family_key = family;
        break;
    } else return error.TestFixtureLacksFamily;
    const rel = &gs.personage_relations.items[0];
    rel.weight ^= 1;
    try std.testing.expect(digest.stateHash(&gs) != hash);
    rel.weight ^= 1;
    const kind = rel.kind;
    rel.kind = if (kind == .grudge) .kin else .grudge;
    try std.testing.expect(digest.stateHash(&gs) != hash);
    rel.kind = kind;
    const to = rel.to;
    rel.to = rel.from;
    try std.testing.expect(digest.stateHash(&gs) != hash);
    rel.to = to;
    try std.testing.expectEqual(hash, digest.stateHash(&gs));
    gs.next_personage_id += 1;
    try std.testing.expect(digest.stateHash(&gs) != hash);
    gs.next_personage_id -= 1;
    // Continued evolution: the saved and the never-saved campaign play on alike.
    for ([_]*GameState{ &gs, &loaded }) |g| {
        try @import("../sim/tick.zig").clearHolds(g);
        _ = try commands.execute(g, .{ .advance_days = 7 });
    }
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
}

const personage_data_for_test = @import("../domain/personage_data.zig");

/// After rows leave `personage_relation`, its ordinals renumbered 0, 1, 2, …
/// in their former order, so a later refusal is not the ordinal check's.
const relation_ords_renumbered = "UPDATE personage_relation SET ord = -1 - ord; UPDATE personage_relation SET ord = (SELECT COUNT(*) FROM personage_relation AS q WHERE q.cid = personage_relation.cid AND q.ord > personage_relation.ord); ";

/// SQL that removes every conflict and leaves every offer and contract
/// without a backer, so a personage the conflicts name may be removed and
/// a refusal is the personages' own: a campaign need hold no conflict.
const conflicts_cleared = "UPDATE contract SET conflict_id = NULL, side = 'defender', on_station_by = NULL, close_day = NULL; DELETE FROM conflict; ";

/// `template` with `$R` (a ruler's id), `$L` (a leader's id), `$S` (a free
/// id), `$N` (the counter past it), `$C` (the last id), `$D` (a data
/// ruler's id) and `$K` (a data heir's, family member's or official's id)
/// filled in.
fn personageTamperSqlForTest(buf: *[1024:0]u8, template: []const u8, ids: [5]u32) ![:0]const u8 {
    var w = std.Io.Writer.fixed(buf[0..1023]);
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '$' and i + 1 < template.len) {
            const value: ?u32 = switch (template[i + 1]) {
                'R' => ids[0],
                'L' => ids[1],
                'S' => ids[2],
                'N' => ids[2] + 1,
                'C' => ids[2] - 1,
                'D' => ids[3],
                'K' => ids[4],
                else => null,
            };
            if (value) |v| {
                try w.print("{d}", .{v});
                i += 1;
                continue;
            }
        }
        try w.writeByte(template[i]);
    }
    const n = w.buffered().len;
    buf[n] = 0;
    return buf[0..n :0];
}

test "a tampered personage row, seat, counter or politics stream refuses to load" {
    // Rules 47, 48, 50, 70; docs/p5d-conflict-world-design.md §J "dangling refs".
    // A start year no data row's window holds: every personage is
    // procedural. `a tampered data personage refuses to load` covers keyed rows.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70002 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer, .start_year = 3020 } });
    for (gs.personages.values()) |p| try std.testing.expectEqual(personage_mod.Provenance.procedural, p.provenance);
    // A day's play first: a day-0 campaign of a non-3025 start holds an
    // artillery offer dated 3025, which `artillery.validate` refuses on load.
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .advance_days = 1 });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);

    const ruler = 1; // the first hiring world's ruler
    const leader = personage_rules.ruler_count + 1; // the first leader
    const spare = gs.next_personage_id; // an id an added row may take
    var buf: [1024:0]u8 = undefined;
    const Case = struct { []const u8, []const u8 };
    // A case that adds or deletes a row keeps the ordinals 0, 1, 2, …, so its
    // refusal is the named defect's, not the ordinal check's.
    const cases = [_]Case{
        .{ "unknown role", "UPDATE personage SET role = 'regent' WHERE id = $R" },
        .{ "a procedural heir", "UPDATE personage SET role = 'heir' WHERE id = $R" },
        .{ "unknown faction", "UPDATE personage SET faction_key = 'XX' WHERE id = $L" },
        .{ "unknown planet", "UPDATE personage SET seat_planet_key = 'nowhere' WHERE id = $R" },
        .{ "unknown provenance", "UPDATE personage SET provenance = 'forged' WHERE id = $R" },
        .{ "a canon provenance without a key", "UPDATE personage SET provenance = 'canon' WHERE id = $R" },
        .{ "unknown generator version", "UPDATE personage SET generator_version = 2 WHERE id = $R" },
        .{ "a procedural row with a data row's generator version", "UPDATE personage SET generator_version = 0 WHERE id = $R" },
        .{ "a procedural row with a family", "UPDATE personage SET family_key = 'davion' WHERE id = $R" },
        .{ "a key naming no data row", "UPDATE personage SET key = 'nosuchkey', provenance = 'authored', generator_version = 0 WHERE id = $R" },
        .{ "ruler on a world that does not hire", "INSERT INTO personage SELECT cid, (SELECT MAX(ord) + 1 FROM personage), $S, role, first_name, 'Extra', 'CS', 'terra', motives, ambition, provenance, generator_version, key, family_key FROM personage WHERE id = $R; UPDATE meta SET value = $N WHERE key = 'next_personage_id'" },
        .{ "ruler of another faction than its world's", "UPDATE personage SET faction_key = CASE WHEN faction_key = 'DC' THEN 'LC' ELSE 'DC' END WHERE id = $R" },
        .{ "two rulers on one world", "INSERT INTO personage SELECT cid, (SELECT MAX(ord) + 1 FROM personage), $S, role, first_name, 'Extra', faction_key, seat_planet_key, motives, ambition, provenance, generator_version, key, family_key FROM personage WHERE id = $R; UPDATE meta SET value = $N WHERE key = 'next_personage_id'" },
        .{ "a hiring world without a ruler", conflicts_cleared ++ "DELETE FROM personage_relation WHERE from_id = $R OR to_id = $R; " ++ relation_ords_renumbered ++ "DELETE FROM personage WHERE id = $R; UPDATE personage SET ord = -1 - ord; UPDATE personage SET ord = (SELECT COUNT(*) FROM personage AS q WHERE q.cid = personage.cid AND q.id < personage.id)" },
        .{ "a leader off its capital", "UPDATE personage SET seat_planet_key = 'skye' WHERE id = $L" },
        .{ "two leaders for one faction", "INSERT INTO personage SELECT cid, (SELECT MAX(ord) + 1 FROM personage), $S, role, first_name, 'Extra', faction_key, seat_planet_key, motives, ambition, provenance, generator_version, key, family_key FROM personage WHERE id = $L; UPDATE meta SET value = $N WHERE key = 'next_personage_id'" },
        .{ "a leader for the catch-all faction", "INSERT INTO personage SELECT cid, (SELECT MAX(ord) + 1 FROM personage), $S, role, first_name, 'Extra', 'PER', 'galatea', motives, ambition, provenance, generator_version, key, family_key FROM personage WHERE id = $L; UPDATE meta SET value = $N WHERE key = 'next_personage_id'" },
        .{ "a leader-bearing faction without a leader", "DELETE FROM personage_relation WHERE from_id = $L OR to_id = $L; " ++ relation_ords_renumbered ++ "DELETE FROM personage WHERE id = $L; UPDATE personage SET ord = -1 - ord; UPDATE personage SET ord = (SELECT COUNT(*) FROM personage AS q WHERE q.cid = personage.cid AND q.id < personage.id)" },
        .{ "personages without a commander", "DELETE FROM commander" },
        .{ "one motive", "UPDATE personage SET motives = 1 WHERE id = $R" },
        .{ "four motives", "UPDATE personage SET motives = 15 WHERE id = $R" },
        .{ "a bit that is no motive", "UPDATE personage SET motives = 515 WHERE id = $R" },
        .{ "a text motive set", "UPDATE personage SET motives = 'expansion' WHERE id = $R" },
        .{ "ambition below the scale", "UPDATE personage SET ambition = -1 WHERE id = $R" },
        .{ "ambition above the scale", "UPDATE personage SET ambition = 101 WHERE id = $R" },
        .{ "an empty name", "UPDATE personage SET first_name = '' WHERE id = $R" },
        .{ "a name that is markup", "UPDATE personage SET last_name = '{c}x' WHERE id = $R" },
        .{ "an id at the counter", "UPDATE meta SET value = $C WHERE key = 'next_personage_id'" },
        .{ "a counter of 0", "UPDATE meta SET value = 0 WHERE key = 'next_personage_id'" },
        .{ "a missing counter", "DELETE FROM meta WHERE key = 'next_personage_id'" },
        .{ "a negative ordinal", "UPDATE personage SET ord = -1 WHERE id = $R" },
        .{ "a fractional ordinal", "UPDATE personage SET ord = 0.5 WHERE id = $R" },
        .{ "an ordinal gap", "UPDATE personage SET ord = ord + 1 WHERE id = $C" },
        .{ "a missing politics stream", "DELETE FROM rng_stream WHERE stream = 'politics'" },
    };
    for (cases) |case| {
        errdefer std.debug.print("personage tamper case: {s}\n", .{case[0]});
        try store.save(&gs);
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(try personageTamperSqlForTest(&buf, case[1], .{ ruler, leader, spare, 0, 0 }));
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    // Controls: without its commander the campaign loads once its personages
    // and their relations go too, so the refusal above is the personages' own.
    try store.save(&gs);
    try store.db.exec(conflicts_cleared ++ "DELETE FROM commander; DELETE FROM personage_relation; DELETE FROM personage");
    var commanderless = try store.load(std.testing.allocator, gs.campaign_id);
    commanderless.deinit();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
}

test "a tampered data personage refuses to load" {
    // Rules 47, 50, 70: a keyed row is its personages.zon row exactly
    // (`personages.validate`).
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70006 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer, .start_year = personage_data_for_test.reference_year } });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);

    // A data ruler with a family, and a data heir with a family.
    var data_ruler: u32 = 0;
    var court: u32 = 0;
    for (gs.personages.values()) |p| {
        if (p.family_key.len == 0) continue;
        if (data_ruler == 0 and p.role == .planetary_ruler) data_ruler = @intFromEnum(p.id);
        if (court == 0 and p.role == .heir) court = @intFromEnum(p.id);
    }
    try std.testing.expect(data_ruler != 0 and court != 0);
    const spare = gs.next_personage_id;
    var buf: [1024:0]u8 = undefined;
    const Case = struct { []const u8, []const u8 };
    const cases = [_]Case{
        .{ "a key naming no data row", "UPDATE personage SET key = 'nosuchkey' WHERE id = $D" },
        .{ "a key with a NUL and more", "UPDATE personage SET key = key || char(0) || 'x' WHERE id = $D" },
        .{ "another data row's key", "DROP INDEX ux_personage_key; UPDATE personage SET key = (SELECT key FROM personage WHERE id = $K) WHERE id = $D" },
        .{ "a role other than its data row's", "UPDATE personage SET role = 'family' WHERE id = $K" },
        .{ "a first name other than its data row's", "UPDATE personage SET first_name = 'Other' WHERE id = $D" },
        .{ "a last name other than its data row's", "UPDATE personage SET last_name = 'Other' WHERE id = $K" },
        .{ "a faction other than its data row's", "UPDATE personage SET faction_key = 'DC' WHERE id = $K" },
        .{ "a seat other than its data row's", "UPDATE personage SET seat_planet_key = 'skye' WHERE id = $K" },
        .{ "a family other than its data row's", "UPDATE personage SET family_key = CASE WHEN family_key = 'kurita' THEN 'marik' ELSE 'kurita' END WHERE id = $K" },
        .{ "no family where its data row has one", "UPDATE personage SET family_key = '' WHERE id = $D" },
        .{ "motives other than its data row's", "UPDATE personage SET motives = CASE WHEN motives = 3 THEN 5 ELSE 3 END WHERE id = $D" },
        .{ "an ambition other than its data row's", "UPDATE personage SET ambition = CASE WHEN ambition = 0 THEN 1 ELSE ambition - 1 END WHERE id = $K" },
        .{ "a provenance other than its data row's", "UPDATE personage SET provenance = CASE WHEN provenance = 'canon' THEN 'authored' ELSE 'canon' END WHERE id = $D" },
        .{ "a keyed procedural row", "UPDATE personage SET provenance = 'procedural' WHERE id = $D" },
        .{ "a data row with the generator's version", "UPDATE personage SET generator_version = 1 WHERE id = $D" },
        .{ "a procedural heir", "UPDATE personage SET provenance = 'procedural', generator_version = 1, key = '', family_key = '' WHERE id = $K" },
        .{ "a duplicate key", "DROP INDEX ux_personage_key; INSERT INTO personage SELECT cid, (SELECT MAX(ord) + 1 FROM personage), $S, role, first_name, last_name, faction_key, seat_planet_key, motives, ambition, provenance, generator_version, key, family_key FROM personage WHERE id = $K; UPDATE meta SET value = $N WHERE key = 'next_personage_id'" },
    };
    for (cases) |case| {
        errdefer std.debug.print("data personage tamper case: {s}\n", .{case[0]});
        try store.save(&gs);
        try store.db.exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_personage_key ON personage(cid, key) WHERE key <> ''");
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(try personageTamperSqlForTest(&buf, case[1], .{ 0, 0, spare, data_ruler, court }));
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    // Control: the untampered save loads, with the schema's index restored.
    try store.save(&gs);
    try store.db.exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_personage_key ON personage(cid, key) WHERE key <> ''");
    try expectCurrentRoundTripForTest(store, &gs);
}

test "a personage role or provenance holding a valid tag, a NUL and more refuses to load" {
    // Rules 1, 47, 50, 70: the loader matches the column's full stored bytes,
    // not the text before its first NUL.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70005 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const store = try Store.open(":memory:");
    defer store.close();
    const Case = struct { column: []const u8, update: [:0]const u8, check: [:0]const u8, malformed: []const u8 };
    for ([_]Case{
        .{ .column = "role", .update = "UPDATE personage SET role = ?1 WHERE cid = ?2 AND id = 1", .check = "SELECT role, typeof(role) = 'text' FROM personage WHERE cid = ?1 AND id = 1", .malformed = "planetary_ruler\x00invalid" },
        .{ .column = "provenance", .update = "UPDATE personage SET provenance = ?1 WHERE cid = ?2 AND id = 1", .check = "SELECT provenance, typeof(provenance) = 'text' FROM personage WHERE cid = ?1 AND id = 1", .malformed = "procedural\x00invalid" },
    }) |case| {
        errdefer std.debug.print("personage embedded-NUL column: {s}\n", .{case.column});
        try store.save(&gs);
        try expectCurrentRoundTripForTest(store, &gs);
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        const update = try store.db.prepare(case.update);
        defer update.finalize();
        try update.bindAll(.{ case.malformed, gs.campaign_id });
        try update.run();
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        const check = try store.db.prepare(case.check);
        defer check.finalize();
        try check.bindAll(.{gs.campaign_id});
        try std.testing.expect(try check.next());
        try std.testing.expectEqual(@as(i64, 1), check.int(1));
        const bytes = try check.text(0, std.testing.allocator);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, case.malformed, bytes);
        if (store.load(std.testing.allocator, gs.campaign_id)) |loaded| {
            var truncated = loaded;
            truncated.deinit();
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.CorruptSave, err);
    }
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
}

test "the personage schema refuses out-of-range rows without the loader" {
    // Rule 50: the executable schema enforces what SQLite can check.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70003 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    // `P`: a procedural row; `D`: a data row.
    const P = "(SELECT MIN(id) FROM personage WHERE key = '')";
    const D = "(SELECT MIN(id) FROM personage WHERE key <> '')";
    for ([_][:0]const u8{
        "UPDATE personage SET role = 'regent' WHERE id = " ++ D,
        "UPDATE personage SET role = 'heir' WHERE id = " ++ P,
        "UPDATE personage SET motives = 1 WHERE id = " ++ P,
        "UPDATE personage SET motives = 15 WHERE id = " ++ P,
        "UPDATE personage SET motives = 512 WHERE id = " ++ P,
        "UPDATE personage SET ambition = 101 WHERE id = " ++ P,
        "UPDATE personage SET ambition = -1 WHERE id = " ++ P,
        "UPDATE personage SET provenance = 'forged' WHERE id = " ++ D,
        "UPDATE personage SET provenance = 'canon' WHERE id = " ++ P,
        "UPDATE personage SET provenance = 'procedural' WHERE id = " ++ D,
        "UPDATE personage SET generator_version = 2 WHERE id = " ++ P,
        "UPDATE personage SET generator_version = 0 WHERE id = " ++ P,
        "UPDATE personage SET generator_version = 1 WHERE id = " ++ D,
        "UPDATE personage SET key = 'x' WHERE id = " ++ P,
        "UPDATE personage SET key = '' WHERE id = " ++ D,
        "UPDATE personage SET key = x'61' WHERE id = " ++ D,
        "UPDATE personage SET family_key = 'davion' WHERE id = " ++ P,
        "UPDATE personage SET family_key = NULL WHERE id = " ++ D,
        "UPDATE personage SET key = (SELECT key FROM personage WHERE key <> '' AND id <> " ++ D ++ " LIMIT 1) WHERE id = " ++ D,
        "UPDATE personage SET first_name = '' WHERE id = " ++ P,
        "UPDATE personage SET id = 0 WHERE id = " ++ P,
        "UPDATE personage SET id = 2 WHERE id = 1",
        "UPDATE personage SET ord = -1 WHERE id = " ++ P,
        "UPDATE personage SET ord = 0.5 WHERE id = " ++ P,
    }) |tamper| {
        errdefer std.debug.print("personage schema case: {s}\n", .{tamper});
        try std.testing.expectError(error.ConstraintViolation, store.db.exec(tamper));
    }
    try expectCurrentRoundTripForTest(store, &gs);
}

test "a campaign without a commander holds no personages and loads" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 70004 });
    defer gs.deinit();
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.personages.count());
    try std.testing.expectEqual(@as(usize, 0), loaded.personage_relations.items.len);
    try std.testing.expectEqual(@as(u32, 1), loaded.next_personage_id);
}

// Rows of a saved campaign's `personage_relation` table that relation tamper
// cases name, as SQL subqueries.
const relation_sql = struct {
    const cid = "(SELECT cid FROM personage_relation LIMIT 1)";
    const next_ord = "(SELECT MAX(ord) + 1 FROM personage_relation)";
    const last_ord = "(SELECT MAX(ord) FROM personage_relation)";
    const first_liege = "(SELECT MIN(ord) FROM personage_relation WHERE kind = 'liege')";
    const first_kin = "(SELECT MIN(ord) FROM personage_relation WHERE kind = 'kin')";
    const first_rival = "(SELECT MIN(ord) FROM personage_relation WHERE kind = 'rival')";
    /// The first liege relation's vassal and liege.
    const vassal = "(SELECT from_id FROM personage_relation WHERE ord = " ++ first_liege ++ ")";
    const liege = "(SELECT to_id FROM personage_relation WHERE ord = " ++ first_liege ++ ")";
    /// A leader of another faction than `liege`'s, and a ruler other than `vassal`.
    const other_leader = "(SELECT id FROM personage WHERE role = 'faction_leader' AND id <> " ++ liege ++ " ORDER BY id LIMIT 1)";
    const other_ruler = "(SELECT id FROM personage WHERE role = 'planetary_ruler' AND id <> " ++ vassal ++ " ORDER BY id LIMIT 1)";
    const catch_all_ruler = "(SELECT id FROM personage WHERE role = 'planetary_ruler' AND faction_key = 'PER' ORDER BY id LIMIT 1)";
};

test "a tampered personage relation refuses to load" {
    // Rules 47, 50, 70; docs/p5d-conflict-world-design.md §J "dangling refs".
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71101 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    for ([_]personage_mod.RelationKind{ .liege, .kin, .rival }) |kind| {
        for (gs.personage_relations.items) |rel| {
            if (rel.kind == kind) break;
        } else return error.TestFixtureLacksRelationKind;
    }
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);

    const s = relation_sql;
    // `fk_off`: the executable schema's foreign keys would refuse the row,
    // so they are off and the refusal is the loader's.
    const Case = struct { name: []const u8, sql: [:0]const u8, fk_off: bool = false };
    // A case that adds or deletes a row keeps the ordinals 0, 1, 2, …, so its
    // refusal is the named defect's, not the ordinal check's.
    const cases = [_]Case{
        .{ .name = "a dangling from", .sql = "UPDATE personage_relation SET from_id = 4000000000 WHERE ord = " ++ s.first_liege, .fk_off = true },
        .{ .name = "a dangling to", .sql = "UPDATE personage_relation SET to_id = 4000000000 WHERE ord = " ++ s.first_liege, .fk_off = true },
        .{ .name = "a self-relation", .sql = "UPDATE personage_relation SET to_id = from_id WHERE ord = " ++ s.first_kin },
        .{ .name = "an unknown kind", .sql = "UPDATE personage_relation SET kind = 'feud' WHERE ord = " ++ s.first_kin },
        .{ .name = "weight 0", .sql = "UPDATE personage_relation SET weight = 0 WHERE ord = " ++ s.first_kin },
        .{ .name = "weight 101", .sql = "UPDATE personage_relation SET weight = 101 WHERE ord = " ++ s.first_kin },
        .{ .name = "a reversed symmetric row", .sql = "UPDATE personage_relation SET from_id = to_id, to_id = from_id WHERE ord = " ++ s.first_kin },
        .{ .name = "a liege from a leader", .sql = "INSERT INTO personage_relation VALUES (" ++ s.cid ++ ", " ++ s.next_ord ++ ", " ++ s.liege ++ ", " ++ s.other_leader ++ ", 'liege', 50)" },
        .{ .name = "a liege to a ruler", .sql = "UPDATE personage_relation SET to_id = " ++ s.other_ruler ++ " WHERE ord = " ++ s.first_liege },
        .{ .name = "a liege to another faction's leader", .sql = "UPDATE personage_relation SET to_id = " ++ s.other_leader ++ " WHERE ord = " ++ s.first_liege },
        .{ .name = "a missing liege", .sql = "DELETE FROM personage_relation WHERE ord = " ++ s.first_liege ++ "; " ++ relation_ords_renumbered },
        .{ .name = "two lieges", .sql = "INSERT INTO personage_relation VALUES (" ++ s.cid ++ ", " ++ s.next_ord ++ ", " ++ s.vassal ++ ", " ++ s.other_leader ++ ", 'liege', 50)" },
        .{ .name = "a catch-all ruler with a liege", .sql = "INSERT INTO personage_relation VALUES (" ++ s.cid ++ ", " ++ s.next_ord ++ ", " ++ s.catch_all_ruler ++ ", " ++ s.liege ++ ", 'liege', 50)" },
        .{ .name = "rival and ally on one pair", .sql = "INSERT INTO personage_relation SELECT cid, " ++ s.next_ord ++ ", from_id, to_id, 'ally', weight FROM personage_relation WHERE ord = " ++ s.first_rival },
        .{ .name = "a text weight", .sql = "UPDATE personage_relation SET weight = 'heavy' WHERE ord = " ++ s.first_kin },
        .{ .name = "a fractional endpoint", .sql = "UPDATE personage_relation SET to_id = to_id + 0.5 WHERE ord = " ++ s.first_liege, .fk_off = true },
        .{ .name = "an ordinal out of position", .sql = "UPDATE personage_relation SET ord = ord + 1 WHERE ord = " ++ s.last_ord },
        .{ .name = "relations without personages", .sql = "DELETE FROM commander; DELETE FROM personage", .fk_off = true },
    };
    for (cases) |case| {
        errdefer std.debug.print("personage relation tamper case: {s}\n", .{case.name});
        try store.save(&gs);
        if (case.fk_off) try store.db.exec("PRAGMA foreign_keys = OFF");
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(case.sql);
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        if (case.fk_off) try store.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
}

test "a duplicate personage relation refuses to load where the schema would let it in" {
    // Rules 47, 50: the schema's UNIQUE refuses the row; a table without it
    // still cannot hand the loader a duplicate.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71101 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    const duplicate = "INSERT INTO personage_relation SELECT cid, " ++ relation_sql.next_ord ++ ", from_id, to_id, kind, weight FROM personage_relation WHERE ord = 0";
    try std.testing.expectError(error.ConstraintViolation, store.db.exec(duplicate));
    try store.db.exec("CREATE TABLE loose AS SELECT * FROM personage_relation; DROP TABLE personage_relation; ALTER TABLE loose RENAME TO personage_relation; " ++ duplicate);
    try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
}

test "the personage relation schema refuses malformed rows without the loader" {
    // Rule 50: the executable schema enforces what SQLite can check.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 71101 });
    defer gs.deinit();
    _ = try @import("../sim/commands.zig").execute(&gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    const s = relation_sql;
    for ([_][:0]const u8{
        "UPDATE personage_relation SET kind = 'feud' WHERE ord = 0",
        "UPDATE personage_relation SET weight = 0 WHERE ord = 0",
        "UPDATE personage_relation SET weight = 101 WHERE ord = 0",
        "UPDATE personage_relation SET weight = 'heavy' WHERE ord = 0",
        "UPDATE personage_relation SET to_id = from_id WHERE ord = 0",
        "UPDATE personage_relation SET from_id = 0 WHERE ord = 0",
        "UPDATE personage_relation SET ord = -1 WHERE ord = 0",
        "UPDATE personage_relation SET from_id = 4000000000 WHERE ord = 0",
        "UPDATE personage_relation SET from_id = to_id, to_id = from_id WHERE ord = " ++ s.first_kin,
        "INSERT INTO personage_relation SELECT cid, " ++ s.next_ord ++ ", from_id, to_id, kind, weight FROM personage_relation WHERE ord = 0",
    }) |tamper| {
        errdefer std.debug.print("personage relation schema case: {s}\n", .{tamper});
        try std.testing.expectError(error.ConstraintViolation, store.db.exec(tamper));
    }
    try expectCurrentRoundTripForTest(store, &gs);
}

// ---- conflicts (rules 45–50, 53; docs/p5d-conflict-world-design.md §C, §J) ----

/// A 3025 campaign played day by day until it holds a threatened, an open
/// and a resolved conflict at once, standing needs, and on its board a
/// position a standing need posted; then, if no offensive conflict in the
/// board's reach has a position posted, one opened there
/// (`contract_market.worldForTest`).
fn conflictCampaignForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    for (0..730) |_| {
        try @import("../sim/tick.zig").clearHolds(gs);
        _ = try commands.execute(gs, .{ .advance_days = 1 });
        var seen = std.EnumSet(conflict_mod.Status).initEmpty();
        var open_offensive: usize = 0;
        for (gs.conflicts.values()) |*c| {
            seen.insert(conflict_mod.status(c, gs.clock.day_index));
            open_offensive += @intFromBool(c.family == .offensive and c.outcome == null);
        }
        var offensive_offer = false;
        var standing_offer = false;
        for (gs.contract_offers.items) |o| {
            offensive_offer = offensive_offer or o.close_day != null;
            standing_offer = standing_offer or (o.conflict_id != .none and o.close_day == null);
        }
        if (!(seen.contains(.threatened) and seen.contains(.open) and seen.contains(.resolved) and seen.contains(.standing) and standing_offer)) continue;
        if (offensive_offer) return;
        if (open_offensive < @import("../domain/tuning.zig").t.politics.max_open_conflicts) {
            _ = try @import("../sim/contract_market.zig").worldForTest(gs);
            return;
        }
    }
    return error.TestFixtureLacksConflictStatuses;
}

/// Swap `field` for `other`, require the digest to move from `hash`, and
/// put it back.
fn expectChangeMovesDigestForTest(gs: *GameState, hash: u64, field: anytype, other: @TypeOf(field.*)) !void {
    const saved = field.*;
    field.* = other;
    defer field.* = saved;
    try std.testing.expect(digest.stateHash(gs) != hash);
}

test "threatened, open and resolved conflicts and their counter survive save and load, every field is digest-covered, and the campaign plays on identically" {
    // Rules 45, 46, 53, 70; docs/p5d-conflict-world-design.md §J.
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73201 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expectEqual(gs.next_conflict_id, loaded.next_conflict_id);
    try std.testing.expectEqual(gs.conflicts.count(), loaded.conflicts.count());
    for (gs.conflicts.values(), loaded.conflicts.values()) |c, q| try std.testing.expectEqualDeep(c, q);

    // Each conflict field, and the counter, moves the digest: on an
    // offensive conflict and on a standing one.
    const hash = digest.stateHash(&gs);
    const c = for (gs.conflicts.values()) |*v| {
        if (v.family == .offensive) break v;
    } else unreachable;
    const standing = for (gs.conflicts.values()) |*v| {
        if (v.family == .standing) break v;
    } else unreachable;
    const o = conflict_mod.offense(c).?;
    try expectChangeMovesDigestForTest(&gs, hash, &c.id, @enumFromInt(999));
    try expectChangeMovesDigestForTest(&gs, hash, &c.family, .standing);
    try expectChangeMovesDigestForTest(&gs, hash, &standing.family, .offensive);
    try expectChangeMovesDigestForTest(&gs, hash, &c.template_key, if (std.mem.eql(u8, c.template_key, "rival_feud")) "border_grab" else "rival_feud");
    try expectChangeMovesDigestForTest(&gs, hash, &c.planet_key, if (std.mem.eql(u8, c.planet_key, "skye")) "tharkad" else "skye");
    try expectChangeMovesDigestForTest(&gs, hash, &c.aggressor.?.faction_key, "XX");
    try expectChangeMovesDigestForTest(&gs, hash, &c.aggressor.?.personage, c.defender.personage);
    try expectChangeMovesDigestForTest(&gs, hash, &c.aggressor, null);
    try expectChangeMovesDigestForTest(&gs, hash, &standing.aggressor, o.aggressor);
    try expectChangeMovesDigestForTest(&gs, hash, &c.defender.faction_key, "XX");
    try expectChangeMovesDigestForTest(&gs, hash, &c.defender.personage, o.aggressor.personage);
    try expectChangeMovesDigestForTest(&gs, hash, &c.instigator, @enumFromInt(@intFromEnum(c.instigator) + 1));
    try expectChangeMovesDigestForTest(&gs, hash, &c.staging_planet_key, "terra");
    try expectChangeMovesDigestForTest(&gs, hash, &c.staging_planet_key, null);
    try expectChangeMovesDigestForTest(&gs, hash, &c.opened_day, c.opened_day + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &c.discovery_day, c.discovery_day + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &c.strike_day, o.strike_day + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &c.strike_day, null);
    try expectChangeMovesDigestForTest(&gs, hash, &standing.strike_day, standing.opened_day + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &c.expires_day, o.expires_day + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &c.expires_day, null);
    try expectChangeMovesDigestForTest(&gs, hash, &standing.expires_day, standing.opened_day + 1);
    for ([_]*conflict_mod.Force{ &c.local_force, &c.strike_force.?, &standing.local_force }) |f| {
        try expectChangeMovesDigestForTest(&gs, hash, &f.lances, f.lances + 1);
        try expectChangeMovesDigestForTest(&gs, hash, &f.quality, if (f.quality == .elite) .green else .elite);
        try expectChangeMovesDigestForTest(&gs, hash, &f.lance_bv, f.lance_bv + 1);
        try expectChangeMovesDigestForTest(&gs, hash, &f.lance_tons, f.lance_tons + 1);
    }
    try expectChangeMovesDigestForTest(&gs, hash, &c.strike_force, null);
    try expectChangeMovesDigestForTest(&gs, hash, &standing.strike_force, standing.local_force);
    try expectChangeMovesDigestForTest(&gs, hash, &c.outcome, if (c.outcome == null) .aggressor_won else null);
    try expectChangeMovesDigestForTest(&gs, hash, &standing.outcome, if (standing.outcome == null) .stood_down else null);
    try expectChangeMovesDigestForTest(&gs, hash, &gs.next_conflict_id, gs.next_conflict_id + 1);
    // Each offer's backer fields move it too.
    const offer = for (gs.contract_offers.items) |*v| {
        if (v.close_day != null) break v;
    } else return error.TestFixtureLacksOffensiveOffer;
    try expectChangeMovesDigestForTest(&gs, hash, &offer.conflict_id, @enumFromInt(@intFromEnum(offer.conflict_id) + 1));
    try expectChangeMovesDigestForTest(&gs, hash, &offer.side, offer.side.other());
    try expectChangeMovesDigestForTest(&gs, hash, &offer.on_station_by, offer.on_station_by.? + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &offer.on_station_by, null);
    try expectChangeMovesDigestForTest(&gs, hash, &offer.close_day, offer.close_day.? + 1);
    try expectChangeMovesDigestForTest(&gs, hash, &offer.close_day, null);
    try std.testing.expectEqual(hash, digest.stateHash(&gs));

    // Continued evolution across a month start: the saved and the
    // never-saved campaign play on alike.
    for ([_]*GameState{ &gs, &loaded }) |g| {
        var crossed = false;
        while (!crossed) {
            try @import("../sim/tick.zig").clearHolds(g);
            _ = try commands.execute(g, .{ .advance_days = 1 });
            crossed = g.clock.date.day == 1;
        }
    }
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try store.save(&loaded);
    try expectCurrentRoundTripForTest(store, &loaded);
}

/// SQL naming rows of a saved campaign's `conflict` table for tamper cases.
const conflict_sql = struct {
    const today = "(SELECT value FROM meta WHERE key = 'day_index')";
    const offensive = "(SELECT MIN(ord) FROM conflict WHERE family = 'offensive')";
    const standing = "(SELECT MIN(ord) FROM conflict WHERE family = 'standing' AND outcome IS NULL)";
    const unresolved = "(SELECT MIN(ord) FROM conflict WHERE family = 'offensive' AND outcome IS NULL)";
    const threatened = "(SELECT MIN(ord) FROM conflict WHERE family = 'offensive' AND outcome IS NULL AND strike_day > " ++ today ++ ")";
    const resolved = "(SELECT MIN(ord) FROM conflict WHERE family = 'offensive' AND outcome IS NOT NULL)";
    /// A conflict whose template puts the instigator on the aggressor's side.
    const aggressor_side = "(SELECT MIN(ord) FROM conflict WHERE family = 'offensive' AND template_key <> 'secession_revolt')";
    const columns_after_id = "template_key, planet_key, aggressor_faction, aggressor_personage, defender_faction, defender_personage, instigator, staging_planet_key, opened_day, discovery_day, strike_day, expires_day, local_lances, local_quality, local_lance_bv, local_lance_tons, strike_lances, strike_quality, strike_lance_bv, strike_lance_tons, outcome, family";
    const counter_past_max = "UPDATE meta SET value = (SELECT MAX(id) + 1 FROM conflict) WHERE key = 'next_conflict_id'";
    /// The first offer a standing need backs, and the first an offensive
    /// conflict backs.
    const standing_offer = "(SELECT MIN(ord) FROM contract WHERE is_offer = 1 AND conflict_id IS NOT NULL AND close_day IS NULL)";
    const offensive_offer = "(SELECT MIN(ord) FROM contract WHERE is_offer = 1 AND close_day IS NOT NULL)";
    /// `n` more copies of the conflict at ordinal `at`, each with the next
    /// ordinal and id, and the counter past them.
    fn copiesOf(comptime n: u32, comptime at: []const u8) [:0]const u8 {
        return std.fmt.comptimePrint("INSERT INTO conflict SELECT c.cid, (SELECT MAX(ord) FROM conflict) + k.n, (SELECT MAX(id) FROM conflict) + k.n, {s} FROM conflict AS c, (WITH RECURSIVE k(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM k WHERE n < {d}) SELECT n FROM k) AS k WHERE c.ord = {s}; {s}", .{ columns_after_id, n, at, counter_past_max });
    }
    /// `n` more copies of the first unresolved offensive conflict.
    fn copies(comptime n: u32) [:0]const u8 {
        return copiesOf(n, unresolved);
    }
};

test "a tampered conflict refuses to load" {
    // Rules 47, 48, 50, 70; docs/p5d-conflict-world-design.md §J: every
    // `politics.validate` refusal and every decode refusal.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73202 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    // The fixture holds an offer of each family to tamper with.
    try std.testing.expect(try countForTest(store.db, "SELECT count(*) FROM contract WHERE is_offer = 1 AND close_day IS NOT NULL") > 0);
    try std.testing.expect(try countForTest(store.db, "SELECT count(*) FROM contract WHERE is_offer = 1 AND conflict_id IS NOT NULL AND close_day IS NULL") > 0);

    const s = conflict_sql;
    const pol = @import("../domain/tuning.zig").t.politics;
    // `fk_off`: the executable schema's foreign keys would refuse the row,
    // so they are off and the refusal is the loader's.
    const Case = struct { name: []const u8, sql: [:0]const u8, fk_off: bool = false };
    const cases = [_]Case{
        .{ .name = "an unknown template", .sql = "UPDATE conflict SET template_key = 'nosuchtemplate' WHERE ord = 0" },
        .{ .name = "an unknown world", .sql = "UPDATE conflict SET planet_key = 'nowhere' WHERE ord = 0" },
        .{ .name = "an unknown faction", .sql = "UPDATE conflict SET aggressor_faction = 'XX' WHERE ord = " ++ s.offensive },
        .{ .name = "a dangling aggressor personage", .sql = "UPDATE conflict SET aggressor_personage = 4000000000 WHERE ord = " ++ s.offensive, .fk_off = true },
        .{ .name = "a dangling defender personage", .sql = "UPDATE conflict SET defender_personage = 4000000000 WHERE ord = 0", .fk_off = true },
        .{ .name = "a dangling instigator", .sql = "UPDATE conflict SET instigator = 4000000000 WHERE ord = 0", .fk_off = true },
        .{ .name = "an instigator off its template's side", .sql = "UPDATE conflict SET instigator = defender_personage WHERE ord = " ++ s.aggressor_side },
        .{ .name = "a staging world that is not the nearest", .sql = "UPDATE conflict SET staging_planet_key = 'terra' WHERE ord = " ++ s.offensive },
        .{ .name = "discovery not after opening", .sql = "UPDATE conflict SET discovery_day = opened_day WHERE ord = " ++ s.offensive },
        .{ .name = "the strike not after discovery", .sql = "UPDATE conflict SET strike_day = discovery_day WHERE ord = " ++ s.offensive },
        .{ .name = "expiry not after the strike", .sql = "UPDATE conflict SET expires_day = strike_day WHERE ord = " ++ s.offensive },
        .{ .name = "an offensive conflict missing its staging world", .sql = "UPDATE conflict SET staging_planet_key = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "an offensive conflict missing its strike day", .sql = "UPDATE conflict SET strike_day = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "an offensive conflict missing its end day", .sql = "UPDATE conflict SET expires_day = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "an offensive conflict missing its aggressor", .sql = "UPDATE conflict SET aggressor_faction = NULL, aggressor_personage = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "an offensive conflict missing its strike force", .sql = "UPDATE conflict SET strike_lances = NULL, strike_quality = NULL, strike_lance_bv = NULL, strike_lance_tons = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "an aggressor faction without its personage", .sql = "UPDATE conflict SET aggressor_personage = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "half a strike force", .sql = "UPDATE conflict SET strike_quality = NULL WHERE ord = " ++ s.offensive },
        .{ .name = "an offensive conflict stood down", .sql = "UPDATE conflict SET outcome = 'stood_down' WHERE ord = " ++ s.resolved },
        .{ .name = "an offensive conflict on a standing template", .sql = "UPDATE conflict SET template_key = 'border_watch' WHERE ord = " ++ s.offensive },
        .{ .name = "an unknown family", .sql = "UPDATE conflict SET family = 'peaceful' WHERE ord = 0" },
        .{ .name = "a standing conflict on an opening template", .sql = "UPDATE conflict SET template_key = 'border_grab' WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict with an aggressor", .sql = "UPDATE conflict SET aggressor_faction = defender_faction, aggressor_personage = defender_personage WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict with a staging world", .sql = "UPDATE conflict SET staging_planet_key = planet_key WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict with a strike day", .sql = "UPDATE conflict SET strike_day = opened_day + 10 WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict with an end day", .sql = "UPDATE conflict SET expires_day = opened_day + 10 WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict with a strike force", .sql = "UPDATE conflict SET strike_lances = local_lances, strike_quality = local_quality, strike_lance_bv = local_lance_bv, strike_lance_tons = local_lance_tons WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict discovered after its opening", .sql = "UPDATE conflict SET discovery_day = opened_day + 1 WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict instigated by another personage", .sql = "UPDATE conflict SET instigator = (SELECT MIN(id) FROM personage WHERE id <> conflict.defender_personage) WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict of another faction than its world's", .sql = "UPDATE conflict SET defender_faction = CASE defender_faction WHEN 'LC' THEN 'FWL' ELSE 'LC' END WHERE ord = " ++ s.standing },
        .{ .name = "a standing conflict won by an aggressor", .sql = "UPDATE conflict SET outcome = 'aggressor_won' WHERE ord = " ++ s.standing },
        .{ .name = "two standing needs on one world", .sql = comptime s.copiesOf(1, s.standing) },
        .{ .name = "an offer naming no loaded conflict", .sql = "UPDATE contract SET conflict_id = 4000000000 WHERE is_offer = 1 AND ord = " ++ s.standing_offer, .fk_off = true },
        .{ .name = "an offer whose employer is not its side's faction", .sql = "UPDATE contract SET employer = CASE employer WHEN 'LC' THEN 'FWL' ELSE 'LC' END WHERE is_offer = 1 AND ord = " ++ s.offensive_offer },
        .{ .name = "an offer on the aggressor side of a standing need", .sql = "UPDATE contract SET side = 'aggressor' WHERE is_offer = 1 AND ord = " ++ s.standing_offer },
        .{ .name = "an offer on a side outside the enum", .sql = "UPDATE contract SET side = 'neutral' WHERE is_offer = 1 AND ord = " ++ s.standing_offer },
        // Each fraction truncates to the row's own valid value.
        .{ .name = "a fractional backer id", .sql = "UPDATE contract SET conflict_id = conflict_id + 0.5 WHERE is_offer = 1 AND ord = " ++ s.standing_offer, .fk_off = true },
        .{ .name = "a fractional on-station day", .sql = "UPDATE contract SET on_station_by = on_station_by + 0.5 WHERE is_offer = 1 AND ord = " ++ s.offensive_offer },
        .{ .name = "a fractional close day", .sql = "UPDATE contract SET close_day = close_day + 0.5 WHERE is_offer = 1 AND ord = " ++ s.offensive_offer },
        .{ .name = "an offer side holding a valid tag, a NUL and more", .sql = "UPDATE contract SET side = CAST(x'646566656e6465720078' AS TEXT) WHERE is_offer = 1 AND ord = " ++ s.standing_offer },
        .{ .name = "an offer side stored as a blob", .sql = "UPDATE contract SET side = CAST(side AS BLOB) WHERE is_offer = 1 AND ord = " ++ s.standing_offer },
        .{ .name = "an offer wanting the company on another day than its backer", .sql = "UPDATE contract SET on_station_by = on_station_by + 1 WHERE is_offer = 1 AND ord = " ++ s.offensive_offer },
        .{ .name = "an offer closing after its on-station day", .sql = "UPDATE contract SET close_day = on_station_by + 1 WHERE is_offer = 1 AND ord = " ++ s.offensive_offer },
        .{ .name = "an offer closing with no on-station day", .sql = "UPDATE contract SET close_day = 5 WHERE is_offer = 1 AND ord = " ++ s.standing_offer },
        .{ .name = "an offer without a backer holding a side", .sql = "UPDATE contract SET conflict_id = NULL, side = 'aggressor' WHERE is_offer = 1 AND ord = " ++ s.standing_offer },
        .{ .name = "an offer without a backer holding days", .sql = "UPDATE contract SET conflict_id = NULL WHERE is_offer = 1 AND ord = " ++ s.offensive_offer },
        .{ .name = "an offer backed by conflict id 0", .sql = "UPDATE contract SET conflict_id = 0 WHERE is_offer = 1 AND ord = " ++ s.standing_offer, .fk_off = true },
        .{ .name = "a preparation longer than the range", .sql = std.fmt.comptimePrint("UPDATE conflict SET strike_day = strike_day + {d}, expires_day = expires_day + {d} WHERE ord = {s}", .{ pol.scheme_prep_days_max + 1, pol.scheme_prep_days_max + 1, s.unresolved }) },
        .{ .name = "fighting longer than the range", .sql = std.fmt.comptimePrint("UPDATE conflict SET expires_day = strike_day + {d} WHERE ord = {s}", .{ pol.fight_days_max + 1, s.unresolved }) },
        .{ .name = "an unresolved conflict past its expiry", .sql = "UPDATE conflict SET outcome = NULL WHERE ord = " ++ s.resolved },
        .{ .name = "a resolved conflict before its expiry", .sql = "UPDATE conflict SET outcome = 'aggressor_won' WHERE ord = " ++ s.threatened },
        .{ .name = "an opening after today", .sql = "UPDATE conflict SET opened_day = opened_day + 1000, discovery_day = discovery_day + 1000, strike_day = strike_day + 1000, expires_day = expires_day + 1000 WHERE ord = " ++ s.threatened },
        .{ .name = "two unresolved conflicts on one world", .sql = comptime s.copies(1) },
        .{ .name = "more unresolved conflicts than the cap", .sql = comptime s.copies(pol.max_open_conflicts) },
        .{ .name = "an id at the counter", .sql = "UPDATE meta SET value = (SELECT MAX(id) FROM conflict) WHERE key = 'next_conflict_id'" },
        .{ .name = "a counter of 0", .sql = "UPDATE meta SET value = 0 WHERE key = 'next_conflict_id'" },
        .{ .name = "a missing counter", .sql = "DELETE FROM meta WHERE key = 'next_conflict_id'" },
        .{ .name = "a local force without a lance", .sql = "UPDATE conflict SET local_lances = 0 WHERE ord = 0" },
        .{ .name = "a strike force without a lance", .sql = "UPDATE conflict SET strike_lances = 0 WHERE ord = " ++ s.offensive },
        .{ .name = "an unknown quality", .sql = "UPDATE conflict SET local_quality = 'legendary' WHERE ord = 0" },
        .{ .name = "a negative lance BV", .sql = "UPDATE conflict SET strike_lance_bv = -1 WHERE ord = " ++ s.offensive },
        .{ .name = "an unknown outcome", .sql = "UPDATE conflict SET outcome = 'draw' WHERE ord = " ++ s.resolved },
        .{ .name = "an outcome holding a valid tag, a NUL and more", .sql = "UPDATE conflict SET outcome = CAST(x'616767726573736f725f776f6e0078' AS TEXT) WHERE ord = " ++ s.resolved },
        .{ .name = "a text day", .sql = "UPDATE conflict SET opened_day = 'spring' WHERE ord = 0" },
        .{ .name = "an id of 0", .sql = "UPDATE conflict SET id = 0 WHERE ord = 0" },
        .{ .name = "an ordinal out of position", .sql = "UPDATE conflict SET ord = ord + 100000 WHERE ord = 0" },
        // Ordinals 0, 1, 2, … in place, but the first two ids reversed.
        .{ .name = "contiguous ordinals over ids out of order", .sql = "UPDATE conflict SET ord = ord + 1000; UPDATE conflict SET ord = 1 WHERE ord = 1000; UPDATE conflict SET ord = 0 WHERE ord = 1001; UPDATE conflict SET ord = ord - 1000 WHERE ord >= 1000" },
    };
    for (cases) |case| {
        errdefer std.debug.print("conflict tamper case: {s}\n", .{case.name});
        try store.save(&gs);
        if (case.fk_off) try store.db.exec("PRAGMA foreign_keys = OFF");
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(case.sql);
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        if (case.fk_off) try store.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
}

test "a conflict holding the largest forces the schema admits loads and resolves" {
    // Rules 25, 47: the schema admits any lance BV from 0 to the i64
    // maximum, so loading accepts it and resolution draws against the
    // forces' ratio without overflowing.
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73204 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try store.db.exec(std.fmt.comptimePrint("UPDATE conflict SET strike_lances = {d}, strike_lance_bv = {d}, local_lances = {d}, local_lance_bv = {d} WHERE ord = {s}", .{ std.math.maxInt(u8), std.math.maxInt(i64), std.math.maxInt(u8), std.math.maxInt(i64), conflict_sql.unresolved }));
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var target: ?types.ConflictId = null;
    for (loaded.conflicts.values()) |c| {
        if (c.strike_force) |f| if (f.lance_bv == std.math.maxInt(i64)) {
            target = c.id;
        };
    }
    const id = target.?;
    const expires = loaded.conflicts.get(id).?.expires_day.?;
    while (loaded.clock.day_index < expires) {
        try @import("../sim/tick.zig").clearHolds(&loaded);
        _ = try commands.execute(&loaded, .{ .advance_days = 1 });
    }
    try std.testing.expect(loaded.conflicts.get(id).?.outcome != null);
}

test "the conflict schema refuses malformed rows without the loader" {
    // Rule 50: the executable schema enforces what SQLite can check.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73203 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    const s = conflict_sql;
    for ([_][:0]const u8{
        "UPDATE conflict SET discovery_day = opened_day WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET expires_day = strike_day WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET opened_day = -1 WHERE ord = 0",
        "UPDATE conflict SET opened_day = 'spring' WHERE ord = 0",
        "UPDATE conflict SET local_lances = 0 WHERE ord = 0",
        "UPDATE conflict SET strike_lances = 256 WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET local_quality = 'legendary' WHERE ord = 0",
        "UPDATE conflict SET strike_lance_bv = -1 WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET local_lance_tons = -1 WHERE ord = 0",
        "UPDATE conflict SET outcome = 'draw' WHERE ord = 0",
        "UPDATE conflict SET template_key = '' WHERE ord = 0",
        "UPDATE conflict SET id = 0 WHERE ord = 0",
        "UPDATE conflict SET ord = -1 WHERE ord = 0",
        // The families: each holds its own shape.
        "UPDATE conflict SET family = 'peaceful' WHERE ord = 0",
        "UPDATE conflict SET strike_day = NULL WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET aggressor_faction = NULL, aggressor_personage = NULL WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET outcome = 'stood_down' WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET aggressor_faction = defender_faction, aggressor_personage = defender_personage WHERE ord = " ++ s.standing,
        "UPDATE conflict SET strike_day = opened_day + 10 WHERE ord = " ++ s.standing,
        "UPDATE conflict SET strike_lances = 1, strike_quality = 'regular', strike_lance_bv = 0, strike_lance_tons = 0 WHERE ord = " ++ s.standing,
        "UPDATE conflict SET discovery_day = opened_day + 1 WHERE ord = " ++ s.standing,
        "UPDATE conflict SET instigator = (SELECT MIN(id) FROM personage WHERE id <> conflict.defender_personage) WHERE ord = " ++ s.standing,
        "UPDATE conflict SET outcome = 'defender_held' WHERE ord = " ++ s.standing,
        // Foreign keys: a personage the campaign does not hold.
        "UPDATE conflict SET aggressor_personage = 4000000000 WHERE ord = " ++ s.offensive,
        "UPDATE conflict SET defender_personage = 4000000000 WHERE ord = 0",
        "UPDATE conflict SET instigator = 4000000000 WHERE ord = 0",
        // Unique: a second row at an ordinal, and a second row with an id.
        "INSERT INTO conflict SELECT cid, 0, (SELECT MAX(id) + 1 FROM conflict), " ++ s.columns_after_id ++ " FROM conflict WHERE ord = 0",
        "INSERT INTO conflict SELECT cid, (SELECT MAX(ord) + 1 FROM conflict), id, " ++ s.columns_after_id ++ " FROM conflict WHERE ord = 0",
        // A position's backer: typed, the default when absent, days in
        // order, and a conflict the campaign holds.
        "UPDATE contract SET side = 'neutral' WHERE is_offer = 1 AND ord = " ++ s.standing_offer,
        "UPDATE contract SET conflict_id = 0 WHERE is_offer = 1 AND ord = " ++ s.standing_offer,
        "UPDATE contract SET conflict_id = 'one' WHERE is_offer = 1 AND ord = " ++ s.standing_offer,
        "UPDATE contract SET on_station_by = -1 WHERE is_offer = 1 AND ord = " ++ s.offensive_offer,
        "UPDATE contract SET close_day = on_station_by + 1 WHERE is_offer = 1 AND ord = " ++ s.offensive_offer,
        "UPDATE contract SET close_day = 5 WHERE is_offer = 1 AND ord = " ++ s.standing_offer,
        "UPDATE contract SET conflict_id = NULL, side = 'aggressor' WHERE is_offer = 1 AND ord = " ++ s.standing_offer,
        "UPDATE contract SET conflict_id = NULL WHERE is_offer = 1 AND ord = " ++ s.offensive_offer,
        "UPDATE contract SET conflict_id = 4000000000 WHERE is_offer = 1 AND ord = " ++ s.standing_offer,
    }) |tamper| {
        errdefer std.debug.print("conflict schema case: {s}\n", .{tamper});
        try std.testing.expectError(error.ConstraintViolation, store.db.exec(tamper));
    }
    try expectCurrentRoundTripForTest(store, &gs);
}

// ---- news items (rules 45–50, 53; docs/p5d-conflict-world-design.md §K) ----

test "news items and their counter survive save and load, every field is digest-covered, and the campaign plays on identically" {
    // Rules 45, 46, 53, 70; docs/p5d-conflict-world-design.md §K
    // "Persistence and digest".
    const commands = @import("../sim/commands.zig");
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73202 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    try std.testing.expect(gs.news_items.count() > 0);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    var loaded = try store.load(std.testing.allocator, gs.campaign_id);
    defer loaded.deinit();
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try std.testing.expectEqual(gs.next_news_id, loaded.next_news_id);
    try std.testing.expectEqual(gs.news_items.count(), loaded.news_items.count());
    for (gs.news_items.values(), loaded.news_items.values()) |n, l| try std.testing.expectEqualDeep(n, l);

    // Each item field, and the counter, moves the digest.
    const hash = digest.stateHash(&gs);
    const n = &gs.news_items.values()[0];
    try expectChangeMovesDigestForTest(&gs, hash, &n.id, @enumFromInt(@intFromEnum(n.id) + 1000));
    try expectChangeMovesDigestForTest(&gs, hash, &n.kind, if (n.kind == .strike) .discovery else .strike);
    try expectChangeMovesDigestForTest(&gs, hash, &n.conflict, @enumFromInt(@intFromEnum(n.conflict) + 1));
    try expectChangeMovesDigestForTest(&gs, hash, &n.reach_from, if (n.reach_from == .hq) .company else .hq);
    try expectChangeMovesDigestForTest(&gs, hash, &n.reach_from_planet_key, if (std.mem.eql(u8, n.reach_from_planet_key, "terra")) "skye" else "terra");
    try expectChangeMovesDigestForTest(&gs, hash, &n.text, "another sentence");
    try expectChangeMovesDigestForTest(&gs, hash, &gs.next_news_id, gs.next_news_id + 1);
    try std.testing.expectEqual(hash, digest.stateHash(&gs));

    // Continued evolution across a month start: the saved and the
    // never-saved campaign play on alike.
    for ([_]*GameState{ &gs, &loaded }) |g| {
        var crossed = false;
        while (!crossed) {
            try @import("../sim/tick.zig").clearHolds(g);
            _ = try commands.execute(g, .{ .advance_days = 1 });
            crossed = g.clock.date.day == 1;
        }
    }
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&gs, &loaded, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    try store.save(&loaded);
    try expectCurrentRoundTripForTest(store, &loaded);
}

/// SQL naming rows of a saved campaign for news tamper cases.
const news_sql = struct {
    const today = "(SELECT value FROM meta WHERE key = 'day_index')";
    /// An offensive conflict whose strike is still to come.
    const unstruck = "(SELECT MIN(id) FROM conflict WHERE family = 'offensive' AND outcome IS NULL AND strike_day > " ++ today ++ ")";
    const standing = "(SELECT MIN(id) FROM conflict WHERE family = 'standing')";
    const columns_after_id = "kind, conflict_id, reach_from, reach_from_planet_key, text";
};

test "a tampered news item refuses to load" {
    // Rules 47, 48, 50, 70; docs/p5d-conflict-world-design.md §K: every
    // `news.validate` refusal the schema lets through, and every decode
    // refusal.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73202 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    try std.testing.expect(gs.news_items.count() >= 2);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
    try std.testing.expect(try countForTest(store.db, "SELECT count(*) FROM conflict WHERE id = " ++ news_sql.unstruck) == 1);

    // A world beyond reach of the first item's conflict.
    const planet = @import("../domain/planet.zig");
    const first = gs.news_items.values()[0];
    const world = planet.find(gs.conflicts.get(first.conflict).?.planet_key).?;
    const beyond = for (planet.catalog) |*w| {
        if (!news.withinReach(planet.distanceLy(w, world))) break w.key;
    } else return error.TestNoWorldBeyondReach;
    var beyond_sql: [128]u8 = undefined;

    const s = news_sql;
    // `fk_off`: the executable schema's foreign keys would refuse the row,
    // so they are off and the refusal is the loader's.
    const Case = struct { name: []const u8, sql: [:0]const u8, fk_off: bool = false };
    const cases = [_]Case{
        .{ .name = "an id of 0", .sql = "UPDATE news_item SET id = 0 WHERE ord = 0" },
        .{ .name = "a text id", .sql = "UPDATE news_item SET id = 'one' WHERE ord = 0" },
        .{ .name = "an id beyond u32", .sql = "UPDATE news_item SET id = 4294967296 WHERE ord = 0" },
        .{ .name = "an id at the counter", .sql = "UPDATE meta SET value = (SELECT MAX(id) FROM news_item) WHERE key = 'next_news_id'" },
        .{ .name = "a counter of 0", .sql = "UPDATE meta SET value = 0 WHERE key = 'next_news_id'" },
        .{ .name = "a missing counter", .sql = "DELETE FROM meta WHERE key = 'next_news_id'" },
        .{ .name = "an ordinal out of position", .sql = "UPDATE news_item SET ord = ord + 100000 WHERE ord = 0" },
        // Ordinals 0, 1, 2, … in place, but the first two ids reversed.
        .{ .name = "contiguous ordinals over ids out of order", .sql = "UPDATE news_item SET ord = ord + 1000; UPDATE news_item SET ord = 1 WHERE ord = 1000; UPDATE news_item SET ord = 0 WHERE ord = 1001; UPDATE news_item SET ord = ord - 1000 WHERE ord >= 1000" },
        .{ .name = "an unknown kind", .sql = "UPDATE news_item SET kind = 'rumour' WHERE ord = 0" },
        .{ .name = "a kind holding a valid tag, a NUL and more", .sql = "UPDATE news_item SET kind = CAST(x'737472696b650078' AS TEXT) WHERE ord = 0" },
        .{ .name = "an unknown presence kind", .sql = "UPDATE news_item SET reach_from = 'rival' WHERE ord = 0" },
        .{ .name = "a dangling conflict", .sql = "UPDATE news_item SET conflict_id = 4000000000 WHERE ord = 0", .fk_off = true },
        .{ .name = "a standing conflict", .sql = "UPDATE news_item SET conflict_id = " ++ s.standing ++ ", reach_from_planet_key = (SELECT planet_key FROM conflict WHERE id = " ++ s.standing ++ ") WHERE ord = 0" },
        .{ .name = "a day after today", .sql = "UPDATE news_item SET kind = 'strike', conflict_id = " ++ s.unstruck ++ ", reach_from_planet_key = (SELECT planet_key FROM conflict WHERE id = " ++ s.unstruck ++ ") WHERE ord = 0" },
        .{ .name = "a resolution of an unresolved conflict", .sql = "UPDATE news_item SET kind = 'resolution', conflict_id = " ++ s.unstruck ++ ", reach_from_planet_key = (SELECT planet_key FROM conflict WHERE id = " ++ s.unstruck ++ ") WHERE ord = 0" },
        .{ .name = "an unknown presence world", .sql = "UPDATE news_item SET reach_from_planet_key = 'nowhere' WHERE ord = 0" },
        .{ .name = "a presence world beyond reach", .sql = try std.fmt.bufPrintZ(&beyond_sql, "UPDATE news_item SET reach_from_planet_key = '{s}' WHERE ord = 0", .{beyond}) },
        .{ .name = "empty text", .sql = "UPDATE news_item SET text = '' WHERE ord = 0" },
        .{ .name = "text that is not UTF-8", .sql = "UPDATE news_item SET text = CAST(x'ff' AS TEXT) WHERE ord = 0" },
        .{ .name = "text stored as a blob", .sql = "UPDATE news_item SET text = CAST(text AS BLOB) WHERE ord = 0" },
    };
    for (cases) |case| {
        errdefer std.debug.print("news tamper case: {s}\n", .{case.name});
        try store.save(&gs);
        if (case.fk_off) try store.db.exec("PRAGMA foreign_keys = OFF");
        try store.db.exec("PRAGMA ignore_check_constraints=ON");
        try store.db.exec(case.sql);
        try store.db.exec("PRAGMA ignore_check_constraints=OFF");
        if (case.fk_off) try store.db.exec("PRAGMA foreign_keys = ON");
        try std.testing.expectError(error.CorruptSave, store.load(std.testing.allocator, gs.campaign_id));
    }
    try store.save(&gs);
    try expectCurrentRoundTripForTest(store, &gs);
}

test "the news schema refuses malformed rows without the loader" {
    // Rule 50: the executable schema enforces what SQLite can check.
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73202 });
    defer gs.deinit();
    try conflictCampaignForTest(&gs);
    try std.testing.expect(gs.news_items.count() > 0);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.save(&gs);
    const s = news_sql;
    for ([_][:0]const u8{
        "UPDATE news_item SET id = 0 WHERE ord = 0",
        "UPDATE news_item SET id = 'one' WHERE ord = 0",
        "UPDATE news_item SET ord = -1 WHERE ord = 0",
        "UPDATE news_item SET kind = 'rumour' WHERE ord = 0",
        "UPDATE news_item SET reach_from = 'rival' WHERE ord = 0",
        "UPDATE news_item SET reach_from_planet_key = '' WHERE ord = 0",
        "UPDATE news_item SET text = '' WHERE ord = 0",
        "UPDATE news_item SET text = CAST(text AS BLOB) WHERE ord = 0",
        "UPDATE news_item SET conflict_id = 0 WHERE ord = 0",
        // Foreign keys: a conflict the campaign does not hold.
        "UPDATE news_item SET conflict_id = 4000000000 WHERE ord = 0",
        // Unique: a second row at an ordinal, a second row with an id, and
        // a second item of a kind for its conflict.
        "INSERT INTO news_item SELECT cid, 0, (SELECT MAX(id) + 1 FROM news_item), 'discovery', " ++ s.standing ++ ", reach_from, reach_from_planet_key, text FROM news_item WHERE ord = 0",
        "INSERT INTO news_item SELECT cid, (SELECT MAX(ord) + 1 FROM news_item), id, 'discovery', " ++ s.standing ++ ", reach_from, reach_from_planet_key, text FROM news_item WHERE ord = 0",
        "INSERT INTO news_item SELECT cid, (SELECT MAX(ord) + 1 FROM news_item), (SELECT MAX(id) + 1 FROM news_item), " ++ s.columns_after_id ++ " FROM news_item WHERE ord = 0",
    }) |tamper| {
        errdefer std.debug.print("news schema case: {s}\n", .{tamper});
        try std.testing.expectError(error.ConstraintViolation, store.db.exec(tamper));
    }
    try expectCurrentRoundTripForTest(store, &gs);
}

// ---- schema migrations v71 → v72 → v73 → v74 → v75 → v76 (rule 51; docs/p5d-conflict-world-design.md §J, §K, §L1) ----

/// A campaign as schema v71 held one: every personage procedural, its clock
/// at `year`, and, before its first month start, no conflict. A 3025 start
/// seats data rows today, so that campaign's personages are the procedural
/// set a year no window holds would seat.
fn v71CampaignForTest(gs: *GameState, year: u16) !void {
    const commands = @import("../sim/commands.zig");
    if (year == personage_data_for_test.reference_year) {
        _ = try founding.createCommander(gs, "T", .LC, .line_officer);
        gs.clock.date.year = year;
        const s = try personage_rules.prepareSeeding(gs, 3020);
        defer s.deinit(gs);
        personage_rules.commitSeeding(gs, &s);
    } else {
        _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer, .start_year = year } });
    }
    for (gs.personages.values()) |p| {
        try std.testing.expectEqual(personage_mod.Provenance.procedural, p.provenance);
        try std.testing.expectEqualStrings("", p.key);
    }
    try std.testing.expectEqual(year, gs.clock.date.year);
    _ = try commands.execute(gs, .{ .advance_days = 3 });
    stripToOlderShapeForTest(gs, false);
}

/// A campaign as schema v72 held one: a 3025 start with its data
/// personages, saved at day 20, before any month start, so it has no
/// conflict and `next_conflict_id` 1.
fn v72CampaignForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    while (gs.clock.day_index < 20) {
        try @import("../sim/tick.zig").clearHolds(gs);
        _ = try commands.execute(gs, .{ .advance_days = 20 - gs.clock.day_index });
    }
    try std.testing.expectEqual(@as(u32, 20), gs.clock.day_index);
    try std.testing.expect(gs.clock.date.day != 1 and gs.clock.date.month == 1);
    stripToOlderShapeForTest(gs, false);
}

/// A campaign as schema v73 held one: a 3025 start played past its first
/// month start, so it holds offensive conflicts, offers and an accepted
/// contract, saved on a day that is not a 1st; every offer and contract
/// has no backer and no conflict is a standing need.
fn v73CampaignForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const co = (try commands.execute(gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
    while (gs.clock.date.month == 1 or gs.clock.date.day < 5) {
        try @import("../sim/tick.zig").clearHolds(gs);
        _ = try commands.execute(gs, .{ .advance_days = 1 });
    }
    stripToOlderShapeForTest(gs, true);
    var offensive: usize = 0;
    for (gs.conflicts.values()) |c| offensive += @intFromBool(c.family == .offensive);
    try std.testing.expect(offensive > 0 and offensive == gs.conflicts.count());
    try std.testing.expect(gs.contract_offers.items.len > 0 and gs.contracts.count() > 0);
}

/// Make a campaign the shape a format before schema v74 held: no news item
/// and `next_news_id` 1 (`stripNewsForTest`), every offer and contract
/// without a backer, no standing need, and from before schema v73
/// (`keep_offensive` false) no conflict at all and `next_conflict_id` 1.
fn stripToOlderShapeForTest(gs: *GameState, keep_offensive: bool) void {
    stripNewsForTest(gs);
    for ([_][]contract_mod.Contract{ gs.contracts.values(), gs.contract_offers.items }) |list| for (list) |*c| {
        c.conflict_id = .none;
        c.side = .defender;
        c.on_station_by = null;
        c.close_day = null;
    };
    var i: usize = 0;
    while (i < gs.conflicts.count()) {
        if (keep_offensive and gs.conflicts.values()[i].family == .offensive) i += 1 else gs.conflicts.orderedRemoveAt(i);
    }
    if (!keep_offensive) gs.next_conflict_id = 1;
}

/// Make a campaign the shape schema v74 held: the shape schema v75 held
/// (`stripNpcBasesForTest`), no news item and `next_news_id` 1.
fn stripNewsForTest(gs: *GameState) void {
    stripNpcBasesForTest(gs);
    gs.news_items.clearRetainingCapacity();
    gs.next_news_id = 1;
}

/// Make a campaign the shape a format before schema v76 reconstructs: each
/// merc company based on its faction's `npc_base.compatibilityBase`, ready
/// from its founding day, and no hull en route.
fn stripNpcBasesForTest(gs: *GameState) void {
    for (gs.merc_companies.values()) |*company| {
        company.home_planet_key = npc_base.compatibilityBase(company.faction_key).?.key;
        company.ready_day = company.founded_day;
    }
    gs.merc_hull_arrivals.clearRetainingCapacity();
}

/// A campaign as schema v75 held one: a 3025 start played past its first
/// month start with a company on a contract, so it holds conflicts, offers,
/// a backed contract and merc companies' month of buying, saved on
/// a day that is not a 1st, in the v75 shape (`stripNpcBasesForTest`). It
/// holds a Periphery company, whose compatibility base is not its capital,
/// and a company of another faction: when the seed founds no Periphery
/// company, company 1 is written as one before the strip.
fn v75CampaignForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const co = (try commands.execute(gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
    while (gs.clock.date.month == 1 or gs.clock.date.day < 5) {
        try @import("../sim/tick.zig").clearHolds(gs);
        _ = try commands.execute(gs, .{ .advance_days = 1 });
    }
    const periphery = for (gs.merc_companies.values()) |c| {
        if (std.mem.eql(u8, c.faction_key, "PER")) break true;
    } else false;
    if (!periphery) gs.merc_companies.getPtr(@enumFromInt(1)).?.faction_key = "PER";
    stripNpcBasesForTest(gs);
    var others: usize = 0;
    for (gs.merc_companies.values()) |c| others += @intFromBool(!std.mem.eql(u8, c.faction_key, "PER"));
    try std.testing.expect(others > 0 and others < gs.merc_companies.count());
}

/// A campaign as schema v74 held one: a 3025 start played past its first
/// month start with a company on a contract, so it holds offensive
/// conflicts, standing needs and offers and a contract they back, saved on
/// a day that is not a 1st, with no news item.
fn v74CampaignForTest(gs: *GameState) !void {
    const commands = @import("../sim/commands.zig");
    _ = try commands.execute(gs, .{ .create_commander = .{ .name = "T", .origin = .LC, .profession = .line_officer } });
    const co = (try commands.execute(gs, .{ .new_company = "Alpha" })).created_force;
    _ = try commands.execute(gs, .{ .accept_contract = .{ .offer = gs.contract_offers.items[0].id, .company = co } });
    while (gs.clock.date.month == 1 or gs.clock.date.day < 5) {
        try @import("../sim/tick.zig").clearHolds(gs);
        _ = try commands.execute(gs, .{ .advance_days = 1 });
    }
    stripNewsForTest(gs);
    var offensive: usize = 0;
    for (gs.conflicts.values()) |c| offensive += @intFromBool(c.family == .offensive);
    try std.testing.expect(offensive > 0 and offensive < gs.conflicts.count());
    try std.testing.expect(gs.contract_offers.items.len > 0 and gs.contracts.count() > 0);
    for (gs.contracts.values()) |c| try std.testing.expect(c.conflict_id != .none);
}

/// Rewrite a current store whose campaigns hold no hull en route into the
/// genuine v75 format: `merc_company` as the frozen v75 DDL defines it, its
/// rows in stored order, no `merc_hull_arrival` table or index, and version
/// 75 on the store and every campaign.
fn downgradeToV75ForTest(db: sqlite.Db) !void {
    try std.testing.expectEqual(@as(i64, 0), try countForTest(db, "SELECT count(*) FROM merc_hull_arrival"));
    try db.exec("PRAGMA foreign_keys = OFF");
    defer db.exec("PRAGMA foreign_keys = ON") catch {}; // best-effort: test fixture cleanup.
    try db.exec("BEGIN; DROP TABLE merc_hull_arrival");
    try db.exec(comptime std.fmt.comptimePrint("CREATE TABLE merc_company__v75{s}", .{tableLine(ddl_v75, "merc_company")["CREATE TABLE IF NOT EXISTS merc_company".len..]}));
    try db.exec("INSERT INTO merc_company__v75 SELECT " ++ merc_company_v75_columns ++ " FROM merc_company ORDER BY rowid; DROP TABLE merc_company; ALTER TABLE merc_company__v75 RENAME TO merc_company; CREATE INDEX IF NOT EXISTS ix_merc_company_cid ON merc_company(cid)");
    try db.exec("UPDATE campaign SET schema_version = 75; UPDATE setting SET value = 75 WHERE key = 'schema_version'; COMMIT");
}

/// Rewrite a current store whose campaigns hold no news item or hull en
/// route into the genuine v74 format: the v75 format
/// (`downgradeToV75ForTest`) with no `news_item` table or index and no
/// `next_news_id` counter, and version 74 on the store and every campaign.
fn downgradeToV74ForTest(db: sqlite.Db) !void {
    try downgradeToV75ForTest(db);
    try std.testing.expectEqual(@as(i64, 0), try countForTest(db, "SELECT count(*) FROM news_item"));
    try db.exec("PRAGMA foreign_keys = OFF");
    defer db.exec("PRAGMA foreign_keys = ON") catch {}; // best-effort: test fixture cleanup.
    try db.exec("BEGIN; DROP TABLE news_item; DELETE FROM meta WHERE key = 'next_news_id'");
    try db.exec("UPDATE campaign SET schema_version = 74; UPDATE setting SET value = 74 WHERE key = 'schema_version'; COMMIT");
}

/// Rewrite a current store whose campaigns hold no news item, standing need
/// or backed offer or contract into the genuine v73 format: the v74 format
/// (`downgradeToV74ForTest`) with `contract` and `conflict` as the frozen
/// v73 DDL defines them, their rows in stored order, and version 73 on the
/// store and every campaign.
fn downgradeToV73ForTest(db: sqlite.Db) !void {
    try downgradeToV74ForTest(db);
    try std.testing.expectEqual(@as(i64, 0), try countForTest(db, "SELECT count(*) FROM conflict WHERE family <> 'offensive'"));
    try std.testing.expectEqual(@as(i64, 0), try countForTest(db, "SELECT count(*) FROM contract WHERE conflict_id IS NOT NULL OR side <> 'defender' OR on_station_by IS NOT NULL OR close_day IS NOT NULL"));
    try db.exec("PRAGMA foreign_keys = OFF");
    defer db.exec("PRAGMA foreign_keys = ON") catch {}; // best-effort: test fixture cleanup.
    try db.exec("BEGIN");
    try db.exec(comptime std.fmt.comptimePrint("CREATE TABLE contract__v73{s}", .{tableLine(ddl_v73, "contract")["CREATE TABLE IF NOT EXISTS contract".len..]}));
    try db.exec("INSERT INTO contract__v73 SELECT " ++ contract_v73_columns ++ " FROM contract ORDER BY rowid; DROP TABLE contract; ALTER TABLE contract__v73 RENAME TO contract; CREATE INDEX IF NOT EXISTS ix_contract_cid ON contract(cid)");
    try db.exec(comptime std.fmt.comptimePrint("CREATE TABLE conflict__v73{s}", .{conflict_v73_ddl["CREATE TABLE IF NOT EXISTS conflict".len..]}));
    try db.exec("INSERT INTO conflict__v73 SELECT " ++ conflict_v73_columns ++ " FROM conflict ORDER BY rowid; DROP TABLE conflict; ALTER TABLE conflict__v73 RENAME TO conflict; " ++ conflict_v73_index_ddl);
    try db.exec("UPDATE campaign SET schema_version = 73; UPDATE setting SET value = 73 WHERE key = 'schema_version'; COMMIT");
}

/// Rewrite a current store whose campaigns hold no conflict into the
/// genuine v72 format: the v73 format (`downgradeToV73ForTest`) with no
/// `conflict` table or index and no `next_conflict_id` counter, and version
/// 72 on the store and every campaign.
fn downgradeToV72ForTest(db: sqlite.Db) !void {
    try std.testing.expectEqual(@as(i64, 0), try countForTest(db, "SELECT count(*) FROM conflict"));
    try downgradeToV73ForTest(db);
    try db.exec("PRAGMA foreign_keys = OFF");
    defer db.exec("PRAGMA foreign_keys = ON") catch {}; // best-effort: test fixture cleanup.
    try db.exec("BEGIN; DROP TABLE conflict; DELETE FROM meta WHERE key = 'next_conflict_id'");
    try db.exec("UPDATE campaign SET schema_version = 72; UPDATE setting SET value = 72 WHERE key = 'schema_version'; COMMIT");
}

/// Rewrite a current store holding v71-shaped campaigns into the genuine v71
/// format: the v72 format (`downgradeToV72ForTest`) with the frozen v71
/// `personage` table, and version 71 on the store and every campaign.
fn downgradeToV71ForTest(db: sqlite.Db) !void {
    try downgradeToV72ForTest(db);
    try db.exec("PRAGMA foreign_keys = OFF");
    defer db.exec("PRAGMA foreign_keys = ON") catch {}; // best-effort: test fixture cleanup.
    try db.exec("BEGIN");
    try db.exec(comptime std.fmt.comptimePrint("CREATE TABLE personage__v71{s}", .{personage_v71_ddl["CREATE TABLE IF NOT EXISTS personage".len..]}));
    try db.exec("INSERT INTO personage__v71 SELECT " ++ personage_v71_columns ++ " FROM personage ORDER BY cid, ord; DROP TABLE personage; ALTER TABLE personage__v71 RENAME TO personage; CREATE INDEX IF NOT EXISTS ix_personage_cid ON personage(cid)");
    try db.exec("UPDATE campaign SET schema_version = 71; UPDATE setting SET value = 71 WHERE key = 'schema_version'; COMMIT");
}

/// A fingerprint of every row a migration from schema `from` must keep, in
/// stored order: every column of every table but `personage` and
/// `merc_company` (and, from before v74, but `contract` and `conflict`),
/// leaving out only the version marks a migration moves (`campaign`'s
/// `schema_version` and the `schema_version` setting) and the counters it
/// adds (from before v75 `next_news_id`, and from before v73
/// `next_conflict_id`); the schema v75 columns of every `merc_company` row;
/// from before v74 the schema v73 columns of every `contract` row and,
/// where the table exists, every `conflict` row; and `personage_columns` of
/// every personage row.
fn sourceRowsFingerprintForTest(db: sqlite.Db, comptime personage_columns: []const u8, comptime from: u32) !u64 {
    var hash = std.hash.Wyhash.init(0);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    try hashColumnsForTest(db, &hash, "merc_company", merc_company_v75_columns);
    if (from < 74) {
        try hashColumnsForTest(db, &hash, "contract", contract_v73_columns);
        if (try countForTest(db, "SELECT count(*) FROM sqlite_master WHERE name = 'conflict'") > 0) try hashColumnsForTest(db, &hash, "conflict", conflict_v73_columns);
    }
    const hashed_apart = if (from < 74) "('contract', 'conflict', 'personage', 'merc_company')" else "('personage', 'merc_company')";
    const tables_query = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN " ++ hashed_apart ++ " ORDER BY name");
    defer tables_query.finalize();
    while (try tables_query.next()) {
        const table = try tables_query.text(0, std.testing.allocator);
        defer std.testing.allocator.free(table);
        var sql: [16384]u8 = undefined;
        var writer = std.Io.Writer.fixed(&sql);
        try writer.writeAll("SELECT ");
        var pragma: [256]u8 = undefined;
        const columns = try db.prepare(try std.fmt.bufPrint(&pragma, "PRAGMA table_info(\"{s}\")", .{table}));
        defer columns.finalize();
        var count: c_int = 0;
        while (try columns.next()) {
            _ = scratch.reset(.retain_capacity);
            const name = try columns.text(1, scratch.allocator());
            if (std.mem.eql(u8, table, "campaign") and std.mem.eql(u8, name, "schema_version")) continue;
            if (count > 0) try writer.writeAll(",");
            try writer.print("typeof(\"{s}\")||':'||hex(\"{s}\")", .{ name, name });
            count += 1;
        }
        try writer.print(" FROM \"{s}\"", .{table});
        if (std.mem.eql(u8, table, "meta") and from < 75) try writer.writeAll(if (from < 73) " WHERE key NOT IN ('next_conflict_id', 'next_news_id')" else " WHERE key <> 'next_news_id'");
        if (std.mem.eql(u8, table, "setting")) try writer.writeAll(" WHERE key <> 'schema_version'");
        try writer.writeAll(" ORDER BY rowid");
        const rows = try db.prepare(writer.buffered());
        defer rows.finalize();
        while (try rows.next()) {
            var column: c_int = 0;
            while (column < count) : (column += 1) {
                _ = scratch.reset(.retain_capacity);
                const value = try rows.text(column, scratch.allocator());
                hash.update(std.mem.asBytes(&value.len));
                hash.update(value);
            }
        }
    }
    const personages_query = try db.prepare("SELECT " ++ personage_columns ++ " FROM personage ORDER BY cid, ord");
    defer personages_query.finalize();
    const personage_count = comptime std.mem.count(u8, personage_columns, ",") + 1;
    while (try personages_query.next()) {
        for (0..personage_count) |column| {
            _ = scratch.reset(.retain_capacity);
            const value = try personages_query.text(@intCast(column), scratch.allocator());
            hash.update(std.mem.asBytes(&value.len));
            hash.update(value);
        }
    }
    return hash.final();
}

/// Hash each of `columns` (a comma list) of every `table` row, typed and
/// in stored order, into `hash`.
fn hashColumnsForTest(db: sqlite.Db, hash: *std.hash.Wyhash, comptime table: []const u8, comptime columns: []const u8) !void {
    const select = comptime blk: {
        @setEvalBranchQuota(100_000);
        var s: []const u8 = "";
        var names = std.mem.tokenizeAny(u8, columns, ", ");
        while (names.next()) |name| s = s ++ (if (s.len == 0) "" else ",") ++ "typeof(" ++ name ++ ")||':'||hex(" ++ name ++ ")";
        break :blk std.fmt.comptimePrint("SELECT {s} FROM {s} ORDER BY rowid", .{ s, table });
    };
    const count = comptime std.mem.count(u8, columns, ",") + 1;
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const rows = try db.prepare(select);
    defer rows.finalize();
    while (try rows.next()) {
        for (0..count) |column| {
            _ = scratch.reset(.retain_capacity);
            const value = try rows.text(@intCast(column), scratch.allocator());
            hash.update(std.mem.asBytes(&value.len));
            hash.update(value);
        }
    }
}

/// Save `gs` into `store` as a new campaign: the store's row id is session
/// state, so the campaign may be filed in several stores.
fn saveAsNewForTest(store: Store, gs: *GameState) !void {
    gs.campaign_id = 0;
    try store.save(gs);
}

fn countForTest(db: sqlite.Db, sql: [:0]const u8) !i64 {
    const st = try db.prepare(sql);
    defer st.finalize();
    if (!try st.next()) return error.TestUnexpectedResult;
    return st.int(0);
}

/// Save `gs` (a campaign of the shape schema `from` held,
/// `stripToOlderShapeForTest` or `stripNewsForTest`) into a store, rewrite
/// it to schema `from`, open it, and prove rule 51's fixture obligations:
/// the versions read current; every source row survives
/// (`sourceRowsFingerprintForTest`); the reconstruction holds (every merc
/// company based on its faction's `npc_base.compatibilityBase`, ready from
/// its founding day, and no hull en route; from before v75 no news item and
/// `next_news_id` 1 for every campaign; from v71 and v72 no conflict and
/// `next_conflict_id` 1, from v71 every personage keyless, and from before
/// v74 every conflict offensive and every offer and contract without a
/// backer); foreign keys check clean, `merc_company_roster`'s naming the
/// rebuilt `merc_company`; the loaded campaign equals
/// the same state saved directly at the current format; it plays on across
/// two month starts as its never-migrated twin does, opening conflicts and
/// at the first holding no offer without a backer; it saves and loads as an
/// ordinary current campaign; and a reopen migrates nothing more.
fn expectMigratedFixtureForTest(gs: *GameState, comptime from: u32) !void {
    const commands = @import("../sim/commands.zig");
    const personage_columns = if (from == 71) personage_v71_columns else personage_v71_columns ++ ", key, family_key";

    // The same state saved directly at the current format, never migrated.
    const direct = try Store.open(":memory:");
    defer direct.close();
    try direct.save(gs);
    var direct_loaded = try direct.load(std.testing.allocator, gs.campaign_id);
    defer direct_loaded.deinit();

    const raw = try sqlite.Db.open(":memory:");
    defer raw.close();
    try saveAsNewForTest(try Store.fromDb(raw), gs);
    switch (from) {
        71 => try downgradeToV71ForTest(raw),
        72 => try downgradeToV72ForTest(raw),
        73 => try downgradeToV73ForTest(raw),
        74 => try downgradeToV74ForTest(raw),
        75 => try downgradeToV75ForTest(raw),
        else => comptime unreachable,
    }
    try std.testing.expectEqual(from >= 72, try Store.hasColumnRt(raw, "personage", "key"));
    try std.testing.expectEqual(@as(i64, @intFromBool(from >= 73)), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE name = 'conflict'"));
    try std.testing.expectEqual(from >= 74, try Store.hasColumnRt(raw, "contract", "conflict_id"));
    try std.testing.expectEqual(@as(i64, @intFromBool(from >= 75)), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE name = 'news_item'"));
    try std.testing.expect(!try Store.hasColumnRt(raw, "merc_company", "home_planet_key"));
    try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE name = 'merc_hull_arrival'"));
    const conflicts_before: i64 = @intCast(gs.conflicts.count());
    const news_before: i64 = @intCast(gs.news_items.count());
    const rows_before = try sourceRowsFingerprintForTest(raw, personage_columns, from);

    const store = try Store.fromDb(raw);
    try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
    try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, std.fmt.comptimePrint("SELECT count(*) FROM campaign WHERE schema_version <> {d}", .{schema_version})));
    try std.testing.expectEqual(rows_before, try sourceRowsFingerprintForTest(raw, personage_columns, from));
    try std.testing.expectEqual(conflicts_before, try countForTest(raw, "SELECT count(*) FROM conflict"));
    if (from < 74) {
        try std.testing.expectEqual(conflicts_before, try countForTest(raw, "SELECT count(*) FROM conflict WHERE family = 'offensive'"));
        try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, "SELECT count(*) FROM contract WHERE conflict_id IS NOT NULL OR side <> 'defender' OR on_station_by IS NOT NULL OR close_day IS NOT NULL"));
    }
    if (from < 73) try std.testing.expectEqual(try countForTest(raw, "SELECT count(*) FROM campaign"), try countForTest(raw, "SELECT count(*) FROM meta WHERE key = 'next_conflict_id' AND value = 1"));
    try std.testing.expectEqual(try countForTest(raw, "SELECT count(*) FROM campaign"), try countForTest(raw, "SELECT count(*) FROM meta WHERE key = 'next_conflict_id'"));
    try std.testing.expectEqual(@as(i64, if (from < 75) 0 else news_before), try countForTest(raw, "SELECT count(*) FROM news_item"));
    if (from < 75) try std.testing.expectEqual(try countForTest(raw, "SELECT count(*) FROM campaign"), try countForTest(raw, "SELECT count(*) FROM meta WHERE key = 'next_news_id' AND value = 1"));
    try std.testing.expectEqual(try countForTest(raw, "SELECT count(*) FROM campaign"), try countForTest(raw, "SELECT count(*) FROM meta WHERE key = 'next_news_id'"));
    // Every company's base is its faction's compatibility base, it is ready
    // from its founding day, and no hull is en route.
    try std.testing.expectEqual(@as(i64, @intCast(gs.merc_companies.count())), try countForTest(raw, "SELECT count(*) FROM merc_company"));
    for (gs.merc_companies.values()) |company| {
        var sql: [256:0]u8 = undefined;
        const query = try std.fmt.bufPrintZ(&sql, "SELECT count(*) FROM merc_company WHERE id = {d} AND home_planet_key = '{s}' AND ready_day = founded_day", .{ @intFromEnum(company.id), npc_base.compatibilityBase(company.faction_key).?.key });
        try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, query));
    }
    try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, "SELECT count(*) FROM merc_hull_arrival"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ix_merc_hull_arrival_cid'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ix_merc_company_cid'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(DISTINCT id) FROM pragma_foreign_key_list('merc_company_roster') WHERE \"table\" = 'merc_company'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ix_conflict_cid'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ix_contract_cid'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ix_news_item_cid'"));
    try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, "SELECT count(*) FROM pragma_foreign_key_check"));
    try std.testing.expectEqual(@as(i64, 3), try countForTest(raw, "SELECT count(DISTINCT id) FROM pragma_foreign_key_list('conflict') WHERE \"table\" = 'personage'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(DISTINCT id) FROM pragma_foreign_key_list('contract') WHERE \"table\" = 'conflict'"));
    try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(DISTINCT id) FROM pragma_foreign_key_list('news_item') WHERE \"table\" = 'conflict'"));
    if (from == 71) {
        try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, "SELECT count(*) FROM personage WHERE key <> '' OR family_key <> ''"));
        try std.testing.expectEqual(@as(i64, @intCast(gs.personages.count())), try countForTest(raw, "SELECT count(*) FROM personage"));
        try std.testing.expectEqual(@as(i64, 0), try countForTest(raw, "SELECT count(*) FROM pragma_foreign_key_list('personage_relation') WHERE \"table\" NOT IN ('campaign', 'personage')"));
        try std.testing.expectEqual(@as(i64, 2), try countForTest(raw, "SELECT count(DISTINCT id) FROM pragma_foreign_key_list('personage_relation') WHERE \"table\" = 'personage'"));
        try std.testing.expectEqual(@as(i64, 1), try countForTest(raw, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ux_personage_key'"));
    }

    var migrated = try store.load(std.testing.allocator, gs.campaign_id);
    defer migrated.deinit();
    var difference: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", digest.firstStateDifference(&direct_loaded, &migrated, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(&direct_loaded), digest.stateHash(&migrated));
    try std.testing.expectEqual(digest.stateHash(gs), digest.stateHash(&migrated));
    if (from < 73) try std.testing.expectEqual(@as(u32, 1), migrated.next_conflict_id);
    if (from < 75) try std.testing.expectEqual(@as(u32, 1), migrated.next_news_id);
    if (from < 75) try std.testing.expectEqual(@as(usize, 0), migrated.news_items.count());
    try std.testing.expectEqual(@as(usize, 0), migrated.merc_hull_arrivals.count());
    // An offer without a backer loads; it is not refused for lacking one.
    if (from == 73) try std.testing.expect(migrated.contract_offers.items.len > 0);
    if (from < 74) for (migrated.contract_offers.items) |o| try std.testing.expectEqual(types.ConflictId.none, o.conflict_id);

    // Continued evolution across two month starts: the migrated campaign
    // and its never-migrated twin. At the first, no offer without a backer
    // is on the board.
    for ([_]*GameState{ gs, &migrated }) |g| {
        var firsts: usize = 0;
        while (firsts < 2) {
            try @import("../sim/tick.zig").clearHolds(g);
            _ = try commands.execute(g, .{ .advance_days = 1 });
            if (g.clock.date.day == 1) {
                firsts += 1;
                for (g.contract_offers.items) |o| try std.testing.expect(o.conflict_id != .none);
            }
        }
    }
    try std.testing.expectEqualStrings("", digest.firstStateDifference(gs, &migrated, &difference) orelse "");
    try std.testing.expectEqual(digest.stateHash(gs), digest.stateHash(&migrated));
    try std.testing.expect(migrated.conflicts.count() > 0);
    // It saves and loads as an ordinary current campaign.
    try store.save(&migrated);
    try expectCurrentRoundTripForTest(store, &migrated);

    // Reopening a migrated store runs no second migration.
    const settled = try databaseFingerprintForTest(raw);
    const again = try Store.fromDb(raw);
    try std.testing.expectEqual(@as(i64, schema_version), again.getSetting("schema_version", 0));
    try std.testing.expectEqual(settled, try databaseFingerprintForTest(raw));
}

test "a v71 store reaches v76 through every migration, keeping every row, and its campaign plays on identically" {
    for ([_]u16{ 3020, personage_data_for_test.reference_year }) |year| {
        errdefer std.debug.print("v71 fixture from a {d} start\n", .{year});
        var gs = GameState.init(std.testing.allocator, .{ .seed = 72101 });
        defer gs.deinit();
        try v71CampaignForTest(&gs, year);
        try expectMigratedFixtureForTest(&gs, 71);
    }
}

test "a v72 store reaches v76 with no conflict and the counter at 1, keeping every row, and its campaign plays on identically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 73101 });
    defer gs.deinit();
    try v72CampaignForTest(&gs);
    try expectMigratedFixtureForTest(&gs, 72);
}

test "a v73 store reaches v76 with every conflict offensive and every position unbacked, keeping every row, and its campaign plays on identically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 74101 });
    defer gs.deinit();
    try v73CampaignForTest(&gs);
    try expectMigratedFixtureForTest(&gs, 73);
}

test "a v74 store reaches v76 with no news and the counter at 1, keeping every row, and its campaign plays on identically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 75101 });
    defer gs.deinit();
    try v74CampaignForTest(&gs);
    try expectMigratedFixtureForTest(&gs, 74);
}

test "a v75 store migrates to v76 with each company on its compatibility base, a Periphery company on Star's End, keeping every row, and its campaign plays on identically" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 76101 });
    defer gs.deinit();
    try v75CampaignForTest(&gs);
    // The reconstruction the migrated rows must equal: a Periphery company
    // on Star's End, never on its faction's capital, Galatea, an LC world
    // the v76 load refuses as its base; every other company on its
    // faction's capital.
    var periphery: usize = 0;
    for (gs.merc_companies.values()) |company| {
        const row = faction_mod.find(company.faction_key).?;
        if (std.mem.eql(u8, row.key, "PER")) {
            try std.testing.expectEqualStrings("star_s_end", company.home_planet_key);
            periphery += 1;
        } else try std.testing.expectEqualStrings(row.capital, company.home_planet_key);
    }
    try std.testing.expect(periphery > 0 and periphery < gs.merc_companies.count());
    // The migrated store loads through `npc_base.validate`, equals this
    // state, and plays on, saves and loads as an ordinary v76 campaign.
    try expectMigratedFixtureForTest(&gs, 75);
}

test "a migration failing at any step of the v71, v72, v73, v74 or v75 chain leaves the store byte-identical, and a clean reopen migrates it" {
    // The provoked failures are expected; keep their warnings out of stderr.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    inline for (.{ 71, 72, 73, 74, 75 }) |from| {
        errdefer std.debug.print("v{d} fixture\n", .{from});
        var gs = GameState.init(std.testing.allocator, .{ .seed = 72102 });
        defer gs.deinit();
        switch (from) {
            71 => try v71CampaignForTest(&gs, 3020),
            72 => try v72CampaignForTest(&gs),
            73 => try v73CampaignForTest(&gs),
            74 => try v74CampaignForTest(&gs),
            else => try v75CampaignForTest(&gs),
        }
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try saveAsNewForTest(try Store.fromDb(raw), &gs);
        switch (from) {
            71 => try downgradeToV71ForTest(raw),
            72 => try downgradeToV72ForTest(raw),
            73 => try downgradeToV73ForTest(raw),
            74 => try downgradeToV74ForTest(raw),
            else => try downgradeToV75ForTest(raw),
        }
        const fixture = try databaseFingerprintForTest(raw);
        const steps = Store.migrationStepCount(from);
        for (0..steps) |step| {
            errdefer std.debug.print("migration fault before step {d}\n", .{step});
            try std.testing.expectError(error.SqliteError, Store.fromDbFaulting(raw, step));
            try std.testing.expectEqual(fixture, try databaseFingerprintForTest(raw));
            try std.testing.expectEqual(@as(i64, from), try countForTest(raw, "SELECT value FROM setting WHERE key = 'schema_version'"));
        }
        // A fault past the last step faults nothing.
        const store = try Store.fromDbFaulting(raw, steps);
        try std.testing.expectEqual(@as(i64, schema_version), store.getSetting("schema_version", 0));
        var loaded = try store.load(std.testing.allocator, gs.campaign_id);
        defer loaded.deinit();
        try std.testing.expectEqual(digest.stateHash(&gs), digest.stateHash(&loaded));
    }
}

test "a malformed or mixed-version v72 store, and stores outside v71..v76, are refused unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 72104 });
    defer gs.deinit();
    try v72CampaignForTest(&gs);
    const Case = struct { name: []const u8, sql: [:0]const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .name = "a v72 store missing a table", .sql = "DROP TABLE world_state", .expected = error.CorruptStore },
        .{ .name = "a v72 store missing a column", .sql = "ALTER TABLE event_log DROP COLUMN contract", .expected = error.CorruptStore },
        .{ .name = "a v72 store with a conflict table already present", .sql = comptime std.fmt.comptimePrint("{s}", .{conflict_v73_ddl}), .expected = error.CorruptStore },
        .{ .name = "a v72 store with a conflict counter already present", .sql = "INSERT INTO meta (cid, key, value) SELECT id, 'next_conflict_id', 1 FROM campaign", .expected = error.CorruptStore },
        .{ .name = "a v72 store holding a v71 campaign", .sql = "UPDATE campaign SET schema_version = 71", .expected = error.CorruptStore },
        .{ .name = "a v72 store holding a v73 campaign", .sql = "UPDATE campaign SET schema_version = 73", .expected = error.CorruptStore },
        .{ .name = "a v70 store", .sql = "UPDATE setting SET value = 70 WHERE key = 'schema_version'", .expected = error.StoreOlderThanGame },
        .{ .name = "a v77 store", .sql = "UPDATE setting SET value = 77 WHERE key = 'schema_version'", .expected = error.StoreNewerThanGame },
    };
    for (cases) |case| {
        errdefer std.debug.print("v72 refusal case: {s}\n", .{case.name});
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try saveAsNewForTest(try Store.fromDb(raw), &gs);
        try downgradeToV72ForTest(raw);
        try raw.exec(case.sql);
        try expectStoreRefusedUnchanged(raw, case.expected);
    }
}

test "the frozen schema v72 to v75 definitions are byte for byte those formats' DDL, v74 changes only contract and conflict, v75 adds only news_item, and v76 changes only merc_company and adds merc_hull_arrival" {
    // SHA-256 and length of `ddl` and `index_ddl` as schemas v72, v74 and
    // v75 defined them, and of the `conflict` table schema v73 added.
    const Expected = struct { text: []const u8, len: usize, sha256: *const [64]u8 };
    for ([_]Expected{
        .{ .text = ddl_v72, .len = 45_900, .sha256 = "75c476ca4811c020e3920ce6cf102e85f90d27800c47c3b6e88bbb4e21756c78" },
        .{ .text = index_ddl_v72, .len = 5_229, .sha256 = "5c341fa7a3d67377f81bec4bb591ea593b5d797b32ef8ed7a3309b762e3cca18" },
        .{ .text = conflict_v73_ddl, .len = 3_047, .sha256 = "607aeea1c0595ee175f2193b4bb1ceca83e10e2b11c51e07ba23305638c13087" },
        .{ .text = ddl_v74, .len = 50_774, .sha256 = "c384b97f7679d1a7ba7f613c8813b0058ad7357176759930fd5b80b9e66b5c5a" },
        .{ .text = index_ddl_v74, .len = 5_290, .sha256 = "af07fc847ba13cdf1683e83c9470059020a055b3e08bea5b164b5f29421bc980" },
        .{ .text = ddl_v75, .len = 51_710, .sha256 = "f342bc0b5d625d7d158622440416884d91af1b288f5e618bc4d194dcebc48983" },
        .{ .text = index_ddl_v75, .len = 5_353, .sha256 = "55ad57a6929a5bf4659250628dea56aff61e58d2aea4b61b7fa9c23e3ec9fd9c" },
    }) |want| {
        var sum: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(want.text, &sum, .{});
        try std.testing.expectEqual(want.len, want.text.len);
        try std.testing.expectEqualStrings(want.sha256, &std.fmt.bytesToHex(sum, .lower));
    }
    // Schema v73 keeps every v72 table and index as it was and adds
    // `conflict`; schema v74 keeps every v73 index.
    try std.testing.expectEqualStrings(ddl_v72 ++ "\n" ++ conflict_v73_ddl, ddl_v73);
    try std.testing.expectEqualStrings(index_ddl_v72 ++ "\n" ++ conflict_v73_index_ddl, index_ddl_v74);
    // Schema v75 keeps every v74 table and index as it was and adds
    // `news_item` and its index.
    try std.testing.expectEqualStrings(ddl_v74 ++ "\n" ++ news_item_v75_ddl, ddl_v75);
    try std.testing.expectEqualStrings(index_ddl_v74 ++ "\n" ++ news_item_v75_index_ddl, index_ddl_v75);
    // Schema v76 is v75 line for line, but for `merc_company`, whose v76
    // definition is v75's with the base and ready day before its keys, and
    // adds `merc_hull_arrival` and its index.
    try std.testing.expectEqualStrings(index_ddl_v75 ++ "\n" ++ merc_hull_arrival_v76_index_ddl, index_ddl);
    var v75_lines = std.mem.splitScalar(u8, ddl_v75, '\n');
    var v76_lines = std.mem.splitScalar(u8, ddl, '\n');
    while (v75_lines.next()) |old| {
        const new = v76_lines.next().?;
        const changed = std.mem.startsWith(u8, old, "CREATE TABLE IF NOT EXISTS merc_company (");
        try std.testing.expectEqual(!changed, std.mem.eql(u8, old, new));
    }
    try std.testing.expectEqualStrings(merc_hull_arrival_v76_ddl, v76_lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), v76_lines.next());
    try std.testing.expectEqualStrings(merc_company_v76_ddl, comptime tableLine(ddl, "merc_company"));
    const v75_merc_company = comptime tableLine(ddl_v75, "merc_company");
    const keys = ", PRIMARY KEY (cid, id)";
    const at = comptime std.mem.indexOf(u8, v75_merc_company, keys).?;
    try std.testing.expect(std.mem.startsWith(u8, merc_company_v76_ddl, v75_merc_company[0..at] ++ ", home_planet_key "));
    try std.testing.expect(std.mem.endsWith(u8, merc_company_v76_ddl, v75_merc_company[at..]));
    // Schema v74 is v73 line for line, but for `contract` and `conflict`;
    // its `contract` is v73's with the backer columns before its foreign
    // keys.
    var v73_lines = std.mem.splitScalar(u8, ddl_v73, '\n');
    var v74_lines = std.mem.splitScalar(u8, ddl_v74, '\n');
    while (v73_lines.next()) |old| {
        const new = v74_lines.next().?;
        const changed = std.mem.startsWith(u8, old, "CREATE TABLE IF NOT EXISTS contract (") or std.mem.startsWith(u8, old, "CREATE TABLE IF NOT EXISTS conflict (");
        try std.testing.expectEqual(!changed, std.mem.eql(u8, old, new));
    }
    try std.testing.expectEqual(@as(?[]const u8, null), v74_lines.next());
    try std.testing.expectEqualStrings(contract_v74_ddl, comptime tableLine(ddl_v74, "contract"));
    try std.testing.expectEqualStrings(conflict_v74_ddl, comptime tableLine(ddl_v74, "conflict"));
    const v73_contract = comptime tableLine(ddl_v73, "contract");
    const campaign_fk = ", FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED";
    try std.testing.expect(std.mem.startsWith(u8, contract_v74_ddl, v73_contract[0 .. v73_contract.len - campaign_fk.len - 2]));
    // Schema v71 differs from v72 only in `personage`.
    try std.testing.expectEqual(std.mem.count(u8, ddl_v72, "\n"), std.mem.count(u8, ddl_v71, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, ddl_v71, personage_v71_ddl) != null);
}

test "a malformed or mixed-version v73 store, and stores outside v71..v76, are refused unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 74104 });
    defer gs.deinit();
    try v73CampaignForTest(&gs);
    const Case = struct { name: []const u8, sql: [:0]const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .name = "a v73 store missing a table", .sql = "DROP TABLE world_state", .expected = error.CorruptStore },
        .{ .name = "a v73 store missing a conflict column", .sql = "ALTER TABLE conflict DROP COLUMN outcome", .expected = error.CorruptStore },
        .{ .name = "a v73 store missing a contract column", .sql = "ALTER TABLE contract DROP COLUMN command_capacity", .expected = error.CorruptStore },
        .{ .name = "a v73 conflict table with a v74 column", .sql = "ALTER TABLE conflict ADD COLUMN family TEXT NOT NULL DEFAULT 'offensive'", .expected = error.CorruptStore },
        .{ .name = "a v73 conflict table with another column", .sql = "ALTER TABLE conflict ADD COLUMN notes TEXT", .expected = error.CorruptStore },
        .{ .name = "a v73 contract table with a v74 column", .sql = "ALTER TABLE contract ADD COLUMN close_day INTEGER", .expected = error.CorruptStore },
        .{ .name = "a v73 store holding a v72 campaign", .sql = "UPDATE campaign SET schema_version = 72", .expected = error.CorruptStore },
        .{ .name = "a v73 store holding a v74 campaign", .sql = "UPDATE campaign SET schema_version = 74", .expected = error.CorruptStore },
        .{ .name = "a v70 store", .sql = "UPDATE setting SET value = 70 WHERE key = 'schema_version'", .expected = error.StoreOlderThanGame },
        .{ .name = "a v77 store", .sql = "UPDATE setting SET value = 77 WHERE key = 'schema_version'", .expected = error.StoreNewerThanGame },
    };
    for (cases) |case| {
        errdefer std.debug.print("v73 refusal case: {s}\n", .{case.name});
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try saveAsNewForTest(try Store.fromDb(raw), &gs);
        try downgradeToV73ForTest(raw);
        try raw.exec(case.sql);
        try expectStoreRefusedUnchanged(raw, case.expected);
    }
}

test "a malformed or mixed-version v74 store, and stores outside v71..v76, are refused unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 75104 });
    defer gs.deinit();
    try v74CampaignForTest(&gs);
    const Case = struct { name: []const u8, sql: [:0]const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .name = "a v74 store missing a table", .sql = "DROP TABLE world_state", .expected = error.CorruptStore },
        .{ .name = "a v74 store missing a column", .sql = "ALTER TABLE event_log DROP COLUMN contract", .expected = error.CorruptStore },
        .{ .name = "a v74 store with a news table already present", .sql = comptime std.fmt.comptimePrint("{s}", .{news_item_v75_ddl}), .expected = error.CorruptStore },
        .{ .name = "a v74 store with a news counter already present", .sql = "INSERT INTO meta (cid, key, value) SELECT id, 'next_news_id', 1 FROM campaign", .expected = error.CorruptStore },
        .{ .name = "a v74 store holding a v73 campaign", .sql = "UPDATE campaign SET schema_version = 73", .expected = error.CorruptStore },
        .{ .name = "a v74 store holding a v75 campaign", .sql = "UPDATE campaign SET schema_version = 75", .expected = error.CorruptStore },
        .{ .name = "a v70 store", .sql = "UPDATE setting SET value = 70 WHERE key = 'schema_version'", .expected = error.StoreOlderThanGame },
        .{ .name = "a v77 store", .sql = "UPDATE setting SET value = 77 WHERE key = 'schema_version'", .expected = error.StoreNewerThanGame },
    };
    for (cases) |case| {
        errdefer std.debug.print("v74 refusal case: {s}\n", .{case.name});
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try saveAsNewForTest(try Store.fromDb(raw), &gs);
        try downgradeToV74ForTest(raw);
        try raw.exec(case.sql);
        try expectStoreRefusedUnchanged(raw, case.expected);
    }
}

test "a malformed or mixed-version v75 store, and stores outside v71..v76, are refused unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 76104 });
    defer gs.deinit();
    try v75CampaignForTest(&gs);
    const Case = struct { name: []const u8, sql: [:0]const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .name = "a v75 store missing a table", .sql = "DROP TABLE world_state", .expected = error.CorruptStore },
        .{ .name = "a v75 store missing a merc_company column", .sql = "ALTER TABLE merc_company DROP COLUMN understrength_since", .expected = error.CorruptStore },
        .{ .name = "a v75 merc_company table with a v76 column", .sql = "ALTER TABLE merc_company ADD COLUMN ready_day INTEGER NOT NULL DEFAULT 0", .expected = error.CorruptStore },
        .{ .name = "a v75 merc_company table with another column", .sql = "ALTER TABLE merc_company ADD COLUMN notes TEXT", .expected = error.CorruptStore },
        .{ .name = "a v75 store with an arrival table already present", .sql = comptime std.fmt.comptimePrint("{s}", .{merc_hull_arrival_v76_ddl}), .expected = error.CorruptStore },
        .{ .name = "a v75 company of an unknown faction", .sql = "UPDATE merc_company SET faction_key = 'XX' WHERE ord = 0", .expected = error.CorruptStore },
        .{ .name = "a v75 company founded on a negative day", .sql = "UPDATE merc_company SET founded_day = -1 WHERE ord = 0", .expected = error.CorruptStore },
        .{ .name = "a v75 company founded on a text day", .sql = "UPDATE merc_company SET founded_day = 'd0' WHERE ord = 0", .expected = error.CorruptStore },
        .{ .name = "a v75 store holding a v74 campaign", .sql = "UPDATE campaign SET schema_version = 74", .expected = error.CorruptStore },
        .{ .name = "a v75 store holding a v76 campaign", .sql = "UPDATE campaign SET schema_version = 76", .expected = error.CorruptStore },
        .{ .name = "a v70 store", .sql = "UPDATE setting SET value = 70 WHERE key = 'schema_version'", .expected = error.StoreOlderThanGame },
        .{ .name = "a v77 store", .sql = "UPDATE setting SET value = 77 WHERE key = 'schema_version'", .expected = error.StoreNewerThanGame },
    };
    for (cases) |case| {
        errdefer std.debug.print("v75 refusal case: {s}\n", .{case.name});
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try saveAsNewForTest(try Store.fromDb(raw), &gs);
        try downgradeToV75ForTest(raw);
        try raw.exec(case.sql);
        try expectStoreRefusedUnchanged(raw, case.expected);
    }
}

test "a malformed v71 store, a mixed-version v71 store, and stores outside v71..v76 are refused unchanged" {
    var gs = GameState.init(std.testing.allocator, .{ .seed = 72103 });
    defer gs.deinit();
    try v71CampaignForTest(&gs, 3020);
    const Case = struct { name: []const u8, sql: [:0]const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .name = "a v71 personage table missing a column", .sql = "PRAGMA foreign_keys = OFF; CREATE TABLE p2 AS SELECT cid, ord, id, role, first_name, last_name, faction_key, seat_planet_key, motives, ambition, provenance FROM personage; DROP TABLE personage; ALTER TABLE p2 RENAME TO personage; PRAGMA foreign_keys = ON", .expected = error.CorruptStore },
        .{ .name = "a v71 personage table with a v72 column", .sql = "ALTER TABLE personage ADD COLUMN key TEXT NOT NULL DEFAULT ''", .expected = error.CorruptStore },
        .{ .name = "a v71 store missing another table", .sql = "DROP TABLE world_state", .expected = error.CorruptStore },
        .{ .name = "a v71 store holding a v70 campaign", .sql = "UPDATE campaign SET schema_version = 70", .expected = error.CorruptStore },
        .{ .name = "a v71 store holding a v72 campaign", .sql = "UPDATE campaign SET schema_version = 72", .expected = error.CorruptStore },
        .{ .name = "a v70 store", .sql = "UPDATE setting SET value = 70 WHERE key = 'schema_version'", .expected = error.StoreOlderThanGame },
        .{ .name = "a v77 store", .sql = "UPDATE setting SET value = 77 WHERE key = 'schema_version'", .expected = error.StoreNewerThanGame },
    };
    for (cases) |case| {
        errdefer std.debug.print("v71 refusal case: {s}\n", .{case.name});
        const raw = try sqlite.Db.open(":memory:");
        defer raw.close();
        try saveAsNewForTest(try Store.fromDb(raw), &gs);
        try downgradeToV71ForTest(raw);
        try raw.exec(case.sql);
        try expectStoreRefusedUnchanged(raw, case.expected);
    }
}
