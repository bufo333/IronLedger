-- IRON LEDGER — SQLite save store schema (design document)
--
-- Matches schema_version 77, the current store and campaign format. Schema
-- 71 is the oldest supported format: a v71, v72, v73, v74, v75 or v76 store
-- reaches 77 on open through each migration in turn, all in one transaction
-- (Store.migrate: v71 → v72 rebuilds `personage`, v72 → v73 adds
-- `conflict`, v73 → v74 rebuilds `conflict` and `contract`, v74 → v75 adds
-- `news_item`, v75 → v76 rebuilds `merc_company` and adds
-- `merc_hull_arrival`, v76 → v77 adds the `theme` setting; see each at its
-- table).
-- Older and newer formats are refused before persistent mutation under
-- docs/engineering-contract.md rule 51; only empty stores initialize schema 77.
-- The executable DDL and dormant historical migration declarations live in
-- src/persist/store.zig; this file is the readable reference for
-- what each table and column means. Column order here is the runtime order.
--
-- One store file holds many campaigns. `player`, `setting` and `campaign`
-- are store-wide; every other table carries `cid` (the campaign.id it
-- belongs to). Saving a campaign deletes its rows and rewrites them all in
-- one transaction.
--
-- MekHQ persists campaigns as gzipped XML (.cpnx.gz); this schema is our
-- relational re-design of its object model plus our extensions (companies as
-- deployable objects, HQ network, shipments).
--
-- Conventions:
--   * All money is INTEGER C-bills. No floats in the ledger.
--   * All days are INTEGER day_index values (day 0 = campaign start); the
--     calendar date is kept in meta (year/month/day) and campaign.date.
--   * IDs are the typed domain IDs (PersonId, UnitId, ForceId, HqId,
--     ContractId, EventId, BattleId); 0 means none.
--   * `ord` preserves in-memory order so a load rebuilds the same state.
--   * Enum columns hold the Zig tag name (e.g. person.Role 'mekwarrior');
--     the loader rejects an unknown tag as a corrupt save.
--   * Static game data (chassis, part catalog, planets, tables) ships in data/
--     .zon files; saves reference it by stable TEXT keys (e.g. chassis_key).
--   * Foreign keys: every per-cid table declares
--       FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
--     Containment references (child rows always name a real parent) also carry
--     explicit FKs: person_skill/award/ability/injury -> person; unit_slot ->
--     unit; force_unit/force_child -> force and unit; hq_facility/hq_project ->
--     hq; battle_report_hit/ammo/salvage -> battle_report; refit_op ->
--     refit_plan; hull_loadout -> hull_instance; hull_combat_record -> hull_instance;
--     maintenance_entry -> hull_instance; hull_ownership_history -> hull_instance. All FKs are DEFERRABLE
--     INITIALLY DEFERRED so clearRows can
--     delete parent rows before child rows within one transaction.
--     Soft and polymorphic references that use NULL or 0-as-none (e.g.
--     stock.owner_id, unit.force, contract.offer_hq) are the loader's
--     responsibility; the loader rejects a save whose rows do not resolve.
--   * UNIQUE keys: battle_report(cid, ord) and battle_report(cid, id), refit_plan(cid, ord) (targets for
--     the FK chains above); stock(cid, owner_kind, owner_id, key).
--   * CHECK constraints: schema_version > 0; boolean NOT NULL columns in
--     person (admitted, rank_pinned, edge_spent), contract (is_offer,
--     negotiated, salvage_exchange), listing (black, staple),
--     battle_report (acknowledged), injury (permanent, healed),
--     refit_plan (committed) are constrained to CHECK (col IN (0,1)).

---------------------------------------------------------------- store

CREATE TABLE player (
    id              INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL UNIQUE,
    created_seq     INTEGER NOT NULL                 -- lobby order
);

-- Store-wide integer settings: schema_version; the client's theme, required
-- from schema v77 (1 standard, 2 classic, 3 high_contrast; tags permanent);
-- and the client's music, music_volume and music_set.
CREATE TABLE setting (
    key             TEXT    PRIMARY KEY,
    value           INTEGER NOT NULL
);

-- The campaign registry: one row per playthrough.
CREATE TABLE campaign (
    id              INTEGER PRIMARY KEY,             -- the cid every other table carries
    name            TEXT    NOT NULL,                -- outfit name
    commander       TEXT,
    day             INTEGER NOT NULL,                -- day_index at save
    date            TEXT    NOT NULL,                -- in-game date at save
    schema_version  INTEGER NOT NULL CHECK (schema_version > 0), -- must be 75 (a v71–v74 store's campaigns are migrated with it); older/newer versions are refused before load or overwrite
    save_seq        INTEGER NOT NULL,                -- store-wide save counter, orders "most recent"
    player_id       INTEGER NOT NULL DEFAULT 0       -- -> player.id; 0 = none
);

---------------------------------------------------------------- campaign scalars

-- Integer scalars by key: day_index, year, month, day, funds, reputation,
-- bankrupt, auto_admit, difficulty, share_profit_bp, the stat_* counters
-- (battles won/drawn/lost, hulls lost/salvaged, people_kia, enemy_bv),
-- next_person_id, next_unit_id, next_force_id, next_hq_id,
-- next_contract_id, next_battle_id, next_event_id, rng_seed,
-- next_listing_id, next_candidate_id, next_loan_id (added v35),
-- next_operation_id (added v40), next_actor_id (added v44),
-- next_rival_id (added v46), next_officer_arc_id (added v47),
-- next_hull_instance_id (added v48), next_artillery_formation_id and
-- next_artillery_offer_id (added v60). v60 also requires artillery_offer_count:
-- a nonnegative serialization completeness check, computed from the offer list
-- on save and checked on load; not an independent GameState field. A missing
-- board must not be mistaken for a newly eligible HQ awaiting its first phase.
-- v61 requires retired_hq_count (including zero), the exact archive row count.
-- It is serialization completeness metadata, not GameState state. Current
-- next_hq_id is required, an original SQLite INTEGER, nonzero, and greater
-- than all live and retired identities; current corruption is never repaired.
-- v64 requires battle_in_progress_count (including zero), the exact
-- battle_in_progress row count, likewise completeness metadata: removed
-- battle rows are corruption, never an engagement not yet engaged.
-- v70 requires next_personage_id, nonzero and greater than every personage id.
-- v73 requires next_conflict_id, nonzero and greater than every conflict id;
-- the v72 → v73 migration sets it to 1 for every campaign.
-- v75 requires next_news_id, nonzero and greater than every news item id;
-- the v74 → v75 migration sets it to 1 for every campaign.
CREATE TABLE meta (
    cid             INTEGER NOT NULL,
    key             TEXT    NOT NULL,
    value           INTEGER NOT NULL,
    PRIMARY KEY (cid, key),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Text scalars by key: outfit_name.
CREATE TABLE meta_text (
    cid             INTEGER NOT NULL,
    key             TEXT    NOT NULL,
    value           TEXT    NOT NULL,
    PRIMARY KEY (cid, key),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Exactly one valid row per required named RNG stream (sim/rng.zig Stream)
-- and the saved meta rng_seed are required by engineering-contract.md rule 52.
-- Missing, duplicate or malformed rows and unknown stream names are corrupt
-- saves; loading never seeds a missing stream or falls back to a legacy blob.
CREATE TABLE rng_stream (
    cid             INTEGER NOT NULL,
    stream          TEXT    NOT NULL,                -- 'generation','market','battle',...,'politics' (v70)
    format          INTEGER NOT NULL,                -- 1: four u64 words, little-endian
    state           BLOB    NOT NULL,                -- 32 bytes in format 1
    UNIQUE (cid, stream),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Dormant legacy single-blob RNG representation: every stream's native-endian
-- state in a fixed order. Schema 62 neither loads nor writes these rows.
-- This retained DDL grants no old-format support or RNG fallback.
CREATE TABLE rng (
    cid             INTEGER PRIMARY KEY,
    state           BLOB    NOT NULL,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- The player character.
CREATE TABLE commander (
    cid             INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    origin          TEXT    NOT NULL,                -- commander.Faction
    profession      TEXT    NOT NULL,                -- commander.Profession
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- personnel

CREATE TABLE person (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER NOT NULL,
    first           TEXT,
    last            TEXT,
    callsign        TEXT,
    role            TEXT,                            -- person.Role
    xp              INTEGER,
    status          TEXT,                            -- person.Status: active | wounded | mia | kia | retired | resigned | pow | released
    fatigue         INTEGER,
    morale          INTEGER,
    recruited_day   INTEGER,
    salary_override INTEGER,                         -- null = the salary table
    assigned_force  INTEGER,                         -- -> force.id
    posted_hq       INTEGER,                         -- -> hq.id
    weekly_hours    INTEGER,                         -- tech time budget
    medbay_priority INTEGER,                         -- higher heals first when beds/doctors are short
    leave_until     INTEGER,                         -- R&R: unavailable until this day
    wound_heal_day  INTEGER,
    training_skill  TEXT,                            -- types.SkillType in training; null = none
    training_done   INTEGER,                         -- day the training completes
    admitted        INTEGER NOT NULL DEFAULT 0 CHECK (admitted IN (0,1)),       -- bool: in the medbay
    rank            TEXT    NOT NULL DEFAULT 'private',                          -- rank.Rank
    rank_pinned     INTEGER NOT NULL DEFAULT 0 CHECK (rank_pinned IN (0,1)),    -- bool: rank set by hand, not by merit
    kills           INTEGER NOT NULL DEFAULT 0,
    kill_bv         INTEGER NOT NULL DEFAULT 0,
    battles         INTEGER NOT NULL DEFAULT 0,
    tours           INTEGER NOT NULL DEFAULT 0,
    outstanding_tours INTEGER NOT NULL DEFAULT 0,
    edge_spent      INTEGER NOT NULL DEFAULT 0 CHECK (edge_spent IN (0,1)),     -- bool
    faction         TEXT    NOT NULL DEFAULT '',     -- faction of origin
    shares          INTEGER NOT NULL DEFAULT 0,
    born_day        INTEGER,                         -- negative = before campaign start
    last_raise_day  INTEGER,
    last_award_day  INTEGER,
    departed_day    INTEGER,                         -- set once they leave the outfit
    secondary_role  TEXT,
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE award (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    key             TEXT    NOT NULL,                -- data/tables/awards.zon key
    FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE ability (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    key             TEXT    NOT NULL,                -- data/tables/abilities.zon key
    FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE person_skill (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    skill           TEXT    NOT NULL,                -- types.SkillType
    level           INTEGER NOT NULL,                -- MekHQ convention: lower target = better
    FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE injury (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    ord             INTEGER NOT NULL,
    location        TEXT    NOT NULL,                -- person.InjuryLocation
    severity        INTEGER NOT NULL,
    incurred        INTEGER NOT NULL,                -- day
    heal_done       INTEGER,                         -- day; null until a doctor is assigned
    doctor          INTEGER NOT NULL DEFAULT 0,      -- -> person.id
    permanent       INTEGER NOT NULL DEFAULT 0 CHECK (permanent IN (0,1)),      -- bool
    healed          INTEGER NOT NULL DEFAULT 0 CHECK (healed IN (0,1)),         -- bool
    FOREIGN KEY (cid, person_id) REFERENCES person(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Hiring-hall candidates: generated per HQ, hired with a signing bonus or
-- expire.
CREATE TABLE candidate (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER,                         -- CandidateId, campaign-unique (meta next_candidate_id; added v35)
    hq              INTEGER,                         -- -> hq.id
    first           TEXT,
    last            TEXT,
    callsign        TEXT,
    role            TEXT,                            -- person.Role
    experience      TEXT,                            -- types.ExperienceLevel
    primary_skill   INTEGER,
    secondary_skill INTEGER,
    bonus           INTEGER,                         -- asking signing bonus
    listed          INTEGER,                         -- day
    expires         INTEGER,                         -- day
    age             INTEGER NOT NULL DEFAULT 30,     -- years, as generated
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- materiel

-- Owned hulls and hulls the enemy holds share this table; a held hull has a
-- non-empty held_by.
CREATE TABLE unit (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER NOT NULL,
    chassis_key     TEXT,
    name            TEXT,                            -- nickname
    kind            TEXT,                            -- unit.UnitKind
    force           INTEGER,                         -- -> force.id
    pilot           INTEGER,                         -- -> person.id (crew seat)
    tech            INTEGER,                         -- -> person.id (tech slot)
    armor_pct       INTEGER,
    quality         TEXT,                            -- types.Quality: a..f
    status          TEXT,                            -- unit.UnitStatus: ready | damaged | repairing | refitting | mothballed | destroyed | in_transit
    last_maint      INTEGER,                         -- day
    acquired_day    INTEGER,
    price           INTEGER,                         -- purchase price
    reactivation_done INTEGER,                       -- day a mothballed hull is awake
    berth_hq        INTEGER NOT NULL DEFAULT 0,      -- -> hq.id where it is berthed
    wreck           TEXT    NOT NULL DEFAULT 'none', -- unit.WreckCause: none | cored | engine | ammo | scrap
    held_by         TEXT    NOT NULL DEFAULT '',     -- faction key holding the hull; '' = ours
    held_day        INTEGER NOT NULL DEFAULT 0,      -- day the field was lost
    held_battle     INTEGER NOT NULL DEFAULT 0,      -- BattleId that lost it
    held_force      INTEGER NOT NULL DEFAULT 0,      -- -> force.id it goes home to if won back
    hull_instance_id INTEGER NOT NULL DEFAULT 0,     -- -> hull_instance.id; 0 = unlinked (added v48)
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Installed equipment per slot. class decides the repair echelon: armor,
-- weapon, equipment and ammo are field-repairable given parts; structure
-- needs an HQ mek bay.
CREATE TABLE unit_slot (
    cid             INTEGER NOT NULL,
    unit_id         INTEGER NOT NULL,                -- -> unit.id
    ord             INTEGER NOT NULL,
    slot_key        TEXT,                            -- e.g. 'right_torso.medium_laser.1'
    part_key        TEXT,                            -- catalog key of the installed part
    class           TEXT,                            -- unit.SlotClass: armor | structure | weapon | equipment | ammo
    condition       TEXT,                            -- unit.PartCondition: ok | damaged | destroyed | missing
    FOREIGN KEY (cid, unit_id) REFERENCES unit(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Physical stocks per site: spare parts, structural components, munition
-- pools, provisions, medical supplies. Tonnage derives from the catalog's
-- pallet_tons.
CREATE TABLE stock (
    cid             INTEGER NOT NULL,
    owner_kind      TEXT    NOT NULL,                -- 'outfit' | 'hq' | 'company'
    owner_id        INTEGER NOT NULL,                -- hq.id or force.id; 0 for outfit
    ord             INTEGER NOT NULL,
    key             TEXT    NOT NULL,                -- catalog key
    qty             INTEGER NOT NULL,
    UNIQUE (cid, owner_kind, owner_id, key),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Parts on order from a market.
CREATE TABLE part_order (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    part_key        TEXT,
    qty             INTEGER,
    dest_kind       TEXT,                            -- 'outfit' | 'hq' | 'company'
    dest_id         INTEGER,
    ordered         INTEGER,                         -- day
    eta             INTEGER,                         -- day; null while sourcing
    cost            INTEGER,
    status          TEXT,                            -- part.OrderStatus: sourcing | in_transit | delivered | failed | cancelled
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Mek bay work: jobs hold a bay slot for a span of days and queue when the
-- bays are full.
CREATE TABLE bay_job (cid INTEGER NOT NULL CHECK (typeof(cid)='integer'), ord INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), hq INTEGER NOT NULL CHECK (typeof(hq)='integer' AND hq BETWEEN 1 AND 4294967295), kind TEXT NOT NULL CHECK (typeof(kind)='text' AND kind IN ('depot_repair','reactivation','fabrication','refit','artillery_depot_repair')), unit INTEGER, item_key TEXT NOT NULL CHECK (typeof(item_key)='text'), duration INTEGER NOT NULL CHECK (typeof(duration)='integer' AND duration > 0 AND duration <= 4294967295), queued INTEGER NOT NULL CHECK (typeof(queued)='integer' AND queued BETWEEN 0 AND 4294967295), started INTEGER, done INTEGER, cost INTEGER NOT NULL CHECK (typeof(cost)='integer' AND cost >= 0), artillery INTEGER, PRIMARY KEY(cid,ord), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,unit) REFERENCES unit(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,artillery) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK ((unit IS NOT NULL) = (kind IN ('depot_repair','reactivation','refit'))), CHECK ((artillery IS NOT NULL) = (kind='artillery_depot_repair')), CHECK (unit IS NULL OR (typeof(unit)='integer' AND unit BETWEEN 1 AND 4294967295)), CHECK (artillery IS NULL OR (typeof(artillery)='integer' AND artillery BETWEEN 1 AND 4294967295)), CHECK ((started IS NULL) = (done IS NULL)), CHECK (started IS NULL OR (typeof(started)='integer' AND started BETWEEN queued AND 4294967295 AND typeof(done)='integer' AND done BETWEEN started AND 4294967295)), CHECK ((item_key != '') = (kind='fabrication')));

-- MekLab refit plans: edits staged against a hull, committed into a bay job.
CREATE TABLE refit_plan (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    unit            INTEGER,                         -- -> unit.id
    committed       INTEGER CHECK (committed IN (0,1)), -- bool
    UNIQUE (cid, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE refit_op (
    cid             INTEGER NOT NULL,
    plan_ord        INTEGER NOT NULL,                -- -> refit_plan.ord
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- 'remove' | 'install'
    slot_key        TEXT,                            -- remove: the slot emptied
    location        TEXT,                            -- install: where
    part_key        TEXT,                            -- install: what
    FOREIGN KEY (cid, plan_ord) REFERENCES refit_plan(cid, ord) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- A hull on its way to another company.
CREATE TABLE unit_transfer (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    unit            INTEGER,                         -- -> unit.id
    to_company      INTEGER,                         -- -> force.id
    eta             INTEGER,                         -- day
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- organization

-- TO&E tree: outfit -> battalion -> company -> lance. Companies are the
-- unit of contract assignment; lances are the unit of battle resolution.
CREATE TABLE force (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER NOT NULL,
    parent          INTEGER,                         -- -> force.id
    name            TEXT,
    emblem          BLOB,                            -- player-set image (png/jpg)
    local_funds     INTEGER,                         -- a deployed company's operating cash
    echelon         TEXT,                            -- force.Echelon
    commander       INTEGER,                         -- -> person.id
    supplying_hq    INTEGER,                         -- -> hq.id
    role            TEXT,                            -- force.LanceRole
    support_kind    TEXT,                            -- force.SupportLanceKind; support lances only
    last_rotation   INTEGER,                         -- day
    contracts_since_rotation INTEGER,
    location_planet TEXT,
    return_eta      INTEGER,                         -- day
    shortage_days   INTEGER,                         -- consecutive days short of supply
    roe             TEXT    NOT NULL DEFAULT 'standard', -- force.Roe: hold | standard | cautious
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE force_unit (
    cid             INTEGER NOT NULL,
    force_id        INTEGER NOT NULL,                -- -> force.id
    ord             INTEGER NOT NULL,
    unit_id         INTEGER NOT NULL,                -- -> unit.id
    FOREIGN KEY (cid, force_id) REFERENCES force(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, unit_id) REFERENCES unit(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE force_child (
    cid             INTEGER NOT NULL,
    force_id        INTEGER NOT NULL,                -- -> force.id
    ord             INTEGER NOT NULL,
    child_id        INTEGER NOT NULL,                -- -> force.id
    FOREIGN KEY (cid, force_id) REFERENCES force(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, child_id) REFERENCES force(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE hq (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER NOT NULL,
    name            TEXT,
    tier            TEXT,                            -- hq.HqTier
    planet          TEXT,                            -- planet key
    staff_assigned  INTEGER,                         -- recomputed on load from postings
    upkeep          INTEGER,                         -- monthly
    funds           INTEGER,                         -- HQ treasury
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Persisted historical identity only: no operational funds/stock/facilities.
-- Live hq and retired_hq IDs are disjoint and share next_hq_id. Ledger/log,
-- retained contract offer_hq, and terminal order HQ destinations resolve to
-- either collection. Live boards, postings, supply assignments, berths,
-- jobs, links, candidates, listings, policies and freight require active hq.
-- Schema 60 -> 61 creates an empty archive; missing legacy identity is corrupt
-- and cannot be inferred. v61 decoding checks original SQLite storage classes,
-- known planet/tier, sold_day <= campaign day, uniqueness and row-count metadata.
-- Contiguous ord preserves the archive's insertion order in the full digest.
CREATE TABLE retired_hq (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL CHECK (ord >= 0 AND ord <= 4294967295),
    id              INTEGER NOT NULL CHECK (id > 0 AND id <= 4294967295),
    name            TEXT NOT NULL,
    planet          TEXT NOT NULL,
    tier            TEXT NOT NULL CHECK (tier IN ('field','regional','brigade')),
    sold_day        INTEGER NOT NULL CHECK (sold_day >= 0 AND sold_day <= 4294967295),
    PRIMARY KEY (cid, id),
    UNIQUE (cid, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE hq_facility (
    cid             INTEGER NOT NULL,
    hq_id           INTEGER NOT NULL,                -- -> hq.id
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- hq.FacilityKind
    level           INTEGER,
    FOREIGN KEY (cid, hq_id) REFERENCES hq(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Founding and upgrade projects: paperwork phase, then construction.
CREATE TABLE hq_project (
    cid             INTEGER NOT NULL,
    hq_id           INTEGER NOT NULL,                -- -> hq.id
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- hq.ProjectKind: found | tier_upgrade | facility_upgrade
    facility        TEXT,                            -- null unless facility_upgrade
    target_level    INTEGER,
    started         INTEGER,                         -- day
    paperwork_done  INTEGER,                         -- day
    construction_done INTEGER,                       -- day
    cost            INTEGER,
    FOREIGN KEY (cid, hq_id) REFERENCES hq(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Supply-line edge in the HQ network graph.
CREATE TABLE hq_link (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    a               INTEGER,                         -- -> hq.id
    b               INTEGER,                         -- -> hq.id
    level           INTEGER,
    tons            INTEGER,                         -- tonnage moved this week
    established     INTEGER,                         -- day
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- contracts

-- Contracts and the current offers (is_offer = 1) share this table.
CREATE TABLE contract (
    cid             INTEGER NOT NULL,
    is_offer        INTEGER NOT NULL CHECK (is_offer IN (0,1)),    -- bool
    ord             INTEGER NOT NULL,
    id              INTEGER,
    kind            TEXT,                            -- contract.ContractKind
    employer        TEXT,                            -- faction key
    enemy           TEXT,                            -- faction key
    planet          TEXT,                            -- planet key
    status          TEXT,                            -- contract.ContractStatus: offer | accepted | transit | active | completed | breached | failed
    company         INTEGER,                         -- -> force.id assigned
    start_day       INTEGER,
    score           INTEGER,                         -- running success score
    dist_ly         INTEGER,                         -- distance from nearest own HQ at offer
    beachhead       INTEGER,                         -- bool: in the beachhead band when offered
    transit_days    INTEGER,
    arrive_day      INTEGER,
    end_day         INTEGER,
    monthly_net     INTEGER,
    next_battle     INTEGER,                         -- day of the next engagement
    battles         INTEGER,                         -- battles fought
    casualties      INTEGER,
    objective       TEXT,                            -- contract.ObjectiveKind: duration | attrition
    committed_bv    INTEGER,
    pool            INTEGER,                         -- enemy pool BV
    pool_remaining  INTEGER,                         -- depleted by battles
    vp              INTEGER,                         -- victory points
    ineffective_since INTEGER,                       -- day the company stopped being combat-effective
    breach_day      INTEGER,
    -- CamOps terms
    length_months   INTEGER,
    base_pay        INTEGER,                         -- per month
    advance_pct     INTEGER,
    signing_bonus   INTEGER,
    transport_pct   INTEGER,
    overhead_pct    INTEGER,
    battle_loss_pct INTEGER,
    salvage_pct     INTEGER,
    salvage_exchange INTEGER CHECK (salvage_exchange IN (0,1)),     -- bool
    command_rights  TEXT,                            -- contract.CommandRights
    negotiated      INTEGER NOT NULL DEFAULT 0 CHECK (negotiated IN (0,1)),     -- bool: terms already negotiated
    -- The opposing force as briefed
    enemy_lances    INTEGER NOT NULL DEFAULT 0,
    enemy_quality   TEXT    NOT NULL DEFAULT 'regular',             -- types.ExperienceLevel
    enemy_lance_bv  INTEGER NOT NULL DEFAULT 0,
    enemy_lance_tons INTEGER NOT NULL DEFAULT 0,
    offer_hq        INTEGER NOT NULL DEFAULT 0,      -- -> hq.id whose board carries the offer
    orders_day      INTEGER,                         -- engagement day battle orders were confirmed for;
                                                     -- the contact warning stands until it equals next_battle
    -- Operation arc state (P4b)
    arc_key         TEXT    NOT NULL DEFAULT '',     -- arc archetype key drawn at acceptance; empty = no arc
    arc_beat        INTEGER NOT NULL DEFAULT 0,      -- current beat index into the arc's beats sequence
    escalation_clock INTEGER NOT NULL DEFAULT 0,     -- accumulated escalation ticks since acceptance
    -- P4c
    arc_finale_key  TEXT    NOT NULL DEFAULT '',     -- which finale was selected; empty until the terminal beat resolves
    -- P4g
    command_capacity INTEGER NOT NULL DEFAULT 0,    -- remaining command capacity for this contract arc
    -- The position's backer (v74; docs/p5d-conflict-world-design.md §C
    -- "No contract without a backer"). The loader (politics.validate) also
    -- refuses a backer whose faction on that side is not the employer and
    -- an on_station_by other than the backer's strike day.
    conflict_id     INTEGER CHECK (conflict_id IS NULL OR (typeof(conflict_id)='integer' AND conflict_id BETWEEN 1 AND 4294967295)), -- -> conflict.id; NULL only on a row a v73 store held
    side            TEXT    NOT NULL DEFAULT 'defender' CHECK (typeof(side)='text' AND side IN ('aggressor','defender')), -- contract.ConflictSide
    on_station_by   INTEGER CHECK (on_station_by IS NULL OR (typeof(on_station_by)='integer' AND on_station_by BETWEEN 0 AND 4294967295)), -- the backer's strike day; NULL for a standing need's position
    close_day       INTEGER CHECK (close_day IS NULL OR (typeof(close_day)='integer' AND close_day BETWEEN 0 AND 4294967295)),         -- last day it may be accepted; NULL: it closes at the month start
    CHECK (conflict_id IS NOT NULL OR (side = 'defender' AND on_station_by IS NULL AND close_day IS NULL)),
    CHECK ((close_day IS NULL) = (on_station_by IS NULL) AND (close_day IS NULL OR close_day <= on_station_by)),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, conflict_id) REFERENCES conflict(cid, id) DEFERRABLE INITIALLY DEFERRED
);
-- Migration v73 → v74: the table is rebuilt (create–copy–drop–rename, rows
-- in stored order). A v73 contract or offer has no backer: it gains
-- conflict_id NULL, side 'defender' and no on_station_by or close_day; such
-- an offer leaves the board at the next month start.

-- Operations instantiated on a contract: missions offered during arc beats.
-- (P4b) A row exists from instantiation through the campaign save; outcome is
-- filled at resolution (P4c). Ordered by (contract_id, ord) within a campaign.
CREATE TABLE operation (
    cid             INTEGER NOT NULL,
    contract_id     INTEGER NOT NULL,                -- -> contract.id
    ord             INTEGER NOT NULL,                -- instantiation order within the contract
    id              INTEGER NOT NULL,                -- -> gs.next_operation_id sequence; unique per cid
    template_key    TEXT    NOT NULL,                -- -> operations.zon template key
    state           TEXT    NOT NULL,                -- domain/operation.zig OperationState
    outcome         TEXT    NOT NULL,                -- domain/operation.zig OutcomeBand
    opened_day      INTEGER NOT NULL,                -- day_index when instantiated
    resolved_day    INTEGER,                         -- day_index when resolved; NULL = unresolved
    committed_day   INTEGER,                         -- P4c: day_index when committed; NULL = not yet committed
    intent          TEXT    NOT NULL DEFAULT 'secure_objective', -- P4d: commander's stated intent (domain/operation.zig Intent)
    tempo           TEXT    NOT NULL DEFAULT 'advance', -- P4f: TempoPosture tag name (advance/recon/prepare/delay)
    reserve_committed INTEGER NOT NULL DEFAULT 0 CHECK (reserve_committed IN (0,1)), -- P5b.2: the reserve was committed at its battle's contact pause; the loader refuses it on a non-combat operation
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Employers cooling on the outfit after a failure.
CREATE TABLE faction_cooling (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    faction         TEXT,
    until_day       INTEGER,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Standing with each faction; an absent row reads as 0.
CREATE TABLE faction_standing (
    cid             INTEGER NOT NULL,
    faction         TEXT    NOT NULL,
    value           INTEGER NOT NULL,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- finances

CREATE TABLE txn (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    day             INTEGER,
    amount          INTEGER,                         -- signed C-bills
    category        TEXT,                            -- finance.Category
    company         INTEGER,                         -- -> force.id cost/profit center; 0 = outfit-level
    hq              INTEGER,                         -- -> hq.id cost center
    contract        INTEGER,                         -- -> contract.id
    note            TEXT,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE loan (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER,                         -- LoanId, campaign-unique (meta next_loan_id; added v35)
    principal       INTEGER,
    balance         INTEGER,
    rate_bp         INTEGER,                         -- basis points
    term            INTEGER,                         -- months
    next_pay        INTEGER,                         -- day
    payment         INTEGER,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Money in transit by courier to a treasury.
CREATE TABLE courier (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    to_kind         TEXT,                            -- 'outfit' | 'hq' | 'company'
    to_id           INTEGER,                         -- 0 for outfit
    amount          INTEGER,
    sent            INTEGER,                         -- day
    eta             INTEGER,                         -- day
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Standing money policies, executed on payday by courier.
CREATE TABLE policy (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    entity_kind     TEXT,                            -- 'outfit' | 'hq' | 'company'
    entity_id       INTEGER,
    floor           INTEGER,                         -- top up to this level
    cap             INTEGER,                         -- max moved per month
    sent            INTEGER NOT NULL DEFAULT 0,      -- moved so far this month
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Standing supply orders for a deployed company.
CREATE TABLE supply_policy (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    company         INTEGER,                         -- -> force.id
    min_days        INTEGER,
    tons            INTEGER,
    ammo_battles    INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Standing restock orders for an HQ warehouse.
CREATE TABLE stock_policy (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    hq              INTEGER,                         -- -> hq.id
    part_key        TEXT,
    min_qty         INTEGER,
    target          INTEGER,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Yearly company rating history.
CREATE TABLE rating_snapshot (
    cid             INTEGER NOT NULL,
    year            INTEGER NOT NULL,
    score           INTEGER NOT NULL,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- markets

-- A listing on an HQ's board; persists until bought or aged out.
CREATE TABLE listing (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER,                         -- ListingId, campaign-unique (meta next_listing_id; added v35)
    kind            TEXT,                            -- 'unit' | 'part'
    item_key        TEXT,                            -- chassis_key or part_key
    rarity          TEXT,                            -- types.Rarity
    price           INTEGER,
    qty             INTEGER,
    staple          INTEGER CHECK (staple IN (0,1)), -- bool: always-stocked part line
    listed          INTEGER,                         -- day
    expires         INTEGER,                         -- day
    hq              INTEGER,                         -- -> hq.id whose board this is
    -- Condition of a listed hull (units only; null for parts)
    c_armor         INTEGER,
    c_quality       TEXT,                            -- types.Quality
    c_damaged       INTEGER,                         -- damaged slots
    c_destroyed     INTEGER,                         -- destroyed slots
    c_missing       INTEGER,                         -- missing components
    black           INTEGER NOT NULL DEFAULT 0 CHECK (black IN (0,1)), -- bool: black-market offer
    company         INTEGER NOT NULL DEFAULT 0,      -- -> force.id: a contract-world hull for this deployed company
    hull_instance_id INTEGER NOT NULL DEFAULT 0,     -- .none (0) on abstraction path; real HullInstance id for faction surplus listings (P3e.6, added v56)
    planet_key       TEXT NOT NULL DEFAULT '',        -- dispersed black-market surfacing world; '' on HQ/contract listings (P3f.1, added v57)
    available_after  INTEGER NOT NULL DEFAULT 0,      -- day_index the listing becomes visible/buyable; 0 = already available (P3f.1, added v57)
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- events

-- Structured campaign log: every entry tagged so any entity's history is a
-- WHERE clause.
CREATE TABLE event_log (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    day             INTEGER,
    category        TEXT,                            -- battle | decision | delivery | contract | medical |
                                                     -- training | rotation | finance | construction | market | misc |
                                                     -- politics (v73)
    company         INTEGER,                         -- -> force.id
    hq              INTEGER,                         -- -> hq.id
    contract        INTEGER,                         -- -> contract.id
    text            TEXT,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Decisions awaiting the commander.
CREATE TABLE pending_event (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- events.EventKind
    day             INTEGER,
    contract        INTEGER,                         -- -> contract.id
    company         INTEGER,                         -- -> force.id
    default_choice  INTEGER,                         -- taken if the deadline passes
    deadline        INTEGER,                         -- day
    chosen          INTEGER,                         -- null until answered
    person          INTEGER NOT NULL DEFAULT 0,      -- -> person.id
    id              INTEGER NOT NULL DEFAULT 0,      -- EventId the inbox answers by
    battle          INTEGER NOT NULL DEFAULT 0,      -- BattleId the decision answers
    situation       TEXT CHECK (situation IS NULL OR typeof(situation)='text'),
                                                     -- situations.zon key; exactly when kind = 'situation'
    actor           INTEGER NOT NULL CHECK (typeof(actor)='integer' AND actor BETWEEN 0 AND 4294967295),
                                                     -- -> actor.id owning the situation; 0 otherwise
    CHECK ((situation IS NOT NULL) = (kind = 'situation')),
    CHECK ((actor != 0) = (kind = 'situation')),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- One row per situation a contract raised (ARCHITECTURE.md §8
-- "Situations"), in the order raised; a pending one also has its
-- pending_event row, and an answered one none.
CREATE TABLE contract_situation (
    cid             INTEGER NOT NULL,
    contract        INTEGER NOT NULL CHECK (typeof(contract)='integer' AND contract BETWEEN 1 AND 4294967295),
                                                     -- -> contract.id (an accepted contract, not an offer)
    ord             INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0),
    situation       TEXT    NOT NULL CHECK (typeof(situation)='text'), -- situations.zon key, of the contract's arc
    day             INTEGER NOT NULL CHECK (typeof(day)='integer' AND day BETWEEN 0 AND 4294967295),
    actor           INTEGER NOT NULL CHECK (typeof(actor)='integer' AND actor BETWEEN 1 AND 4294967295),
                                                     -- -> actor.id: the contract's actor of the owner archetype
    choice          INTEGER CHECK (choice IS NULL OR (typeof(choice)='integer' AND choice BETWEEN 0 AND 2)),
                                                     -- the option applied; NULL while it awaits an answer
    PRIMARY KEY (cid, contract, ord),
    UNIQUE (cid, contract, situation),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, actor) REFERENCES actor(cid, id) DEFERRABLE INITIALLY DEFERRED
);

-- One row per decision kind: when it last fired and how it was answered.
CREATE TABLE event_memory (
    cid             INTEGER NOT NULL,
    kind            TEXT    NOT NULL,                -- events.EventKind
    last_day        INTEGER NOT NULL,
    last_choice     INTEGER NOT NULL,
    streak          INTEGER NOT NULL,                -- times running the same answer was given
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

---------------------------------------------------------------- battles

-- Resolved engagements as complete structured records for the campaign
-- lifetime. The after-action screens render these fields directly.
CREATE TABLE battle_report (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER NOT NULL CHECK (id > 0), -- BattleId, campaign-unique (meta next_battle_id)
    day             INTEGER,
    contract        INTEGER,                         -- -> contract.id
    company         INTEGER,                         -- -> force.id
    kind            TEXT,
    enemy_key       TEXT,
    scenario        TEXT,
    terrain         TEXT,
    weather         TEXT,
    outcome         TEXT,                            -- decisive_victory | victory | draw | defeat | rout
    held_field      INTEGER,                         -- bool: who kept the wrecks
    withdrew        INTEGER,                         -- bool
    roe             TEXT,                            -- force.Roe
    roe_overridden  INTEGER,                         -- bool
    player_power    INTEGER,
    enemy_power     INTEGER,
    conditions_mod  INTEGER,
    close_terrain   INTEGER,                         -- bool
    air_grounded    INTEGER,                         -- bool
    convoy_hit      INTEGER,                         -- bool
    edge_spent_by   TEXT,                            -- ranked name of whoever spent Edge; '' = none
    recon_quality   INTEGER,
    avg_fatigue     INTEGER,
    avg_morale      INTEGER,
    -- losses, spoils and the aftermath the AAR reports
    hits_taken      INTEGER,
    destroyed       INTEGER,
    wounded         INTEGER,
    kia             INTEGER,
    lost_hulls      INTEGER,
    missing         INTEGER,
    enemy_destroyed_bv INTEGER,
    kills_credited  INTEGER,
    prisoners       INTEGER,
    battle_loss_comp INTEGER,
    score_after     INTEGER,
    score_delta     INTEGER,
    morale_delta    INTEGER,
    fatigue_add     INTEGER,
    battle_loss_pct INTEGER,
    salvage_pct     INTEGER,
    command_rights  TEXT,
    silenced_mounts INTEGER,
    armor_left      INTEGER,
    salvage_claimed INTEGER,                         -- BV
    salvage_haulable INTEGER,                        -- BV
    salvage_cut     INTEGER,                         -- liaison's cut, BV
    salvage_cash    INTEGER,                         -- salvage-exchange cash
    salvage_items   TEXT,                            -- what was taken
    conceded        INTEGER,                         -- bool: no combat-effective units, objective conceded without a shot
    acknowledged    INTEGER NOT NULL DEFAULT 1 CHECK (acknowledged IN (0,1)),   -- bool: the player has read it
    salvage_unclaimed INTEGER NOT NULL DEFAULT 0,    -- BV of the haul still to be divided; 0 once taken
    operation       TEXT    NOT NULL DEFAULT '',     -- P4c: operation template name that triggered this engagement; empty = no arc op
    operation_intent TEXT   NOT NULL DEFAULT '',     -- P4d: Intent tag name of the committed operation; empty = no operation intent
    operation_tempo TEXT    NOT NULL DEFAULT '',     -- P4f: TempoPosture tag name of the committed operation; empty = no tempo
    operation_interventions TEXT NOT NULL DEFAULT '', -- P4g: comma-separated intervention labels applied; empty = none
    artillery_present INTEGER NOT NULL CHECK(typeof(artillery_present)='integer' AND artillery_present IN (0,1)), -- required result-presence marker, never inferred from child rows
    phase_count     INTEGER NOT NULL CHECK (typeof(phase_count)='integer' AND phase_count BETWEEN 0 AND 3), -- exact battle_report_phase row count (0: a concession or a forfeit); completeness check, not state
    lever_count     INTEGER NOT NULL CHECK (typeof(lever_count)='integer' AND lever_count BETWEEN 0 AND 5), -- exact battle_report_lever row count (0 for a concession or a forfeit); completeness check, not state
    UNIQUE (cid, ord),
    UNIQUE (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- One row per hit: the armour before and after, the slot that broke, how
-- the hull died, and the crew's wound and fate as fields rather than
-- prose (a pilot can be wounded *and* taken).
CREATE TABLE battle_report_hit (
    cid             INTEGER NOT NULL,
    report_ord      INTEGER NOT NULL,                -- -> battle_report.ord
    ord             INTEGER NOT NULL,
    unit            INTEGER,                         -- may name a hull since struck off
    chassis_key     TEXT,                            -- copied: the report outlives the hull
    chassis_name    TEXT,
    armor_before    INTEGER,
    armor_after     INTEGER,
    slot            TEXT,                            -- '' = none
    slot_part       TEXT,
    slot_result     TEXT,                            -- none | damaged | destroyed
    destroyed       INTEGER,                         -- bool
    cause           TEXT,                            -- unit.WreckCause: none | cored | engine | ammo | scrap
    pilot           INTEGER,                         -- -> person.id
    crew_name       TEXT,
    wound_severity  INTEGER,                         -- null = unwounded
    wound_location  TEXT,                            -- person.InjuryLocation; '' = unwounded
    wound_permanent INTEGER,                         -- bool
    fate            TEXT,                            -- unhurt | kia | missing
    recovery_roll   INTEGER,
    recovery_target INTEGER,
    lost            INTEGER,                         -- bool: left to the enemy
    FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Munitions burned and what the trucks still hold. Keyed by family name,
-- not position: part.munition_keys has grown before, and a positional
-- encoding would silently re-label old saves.
CREATE TABLE battle_report_ammo (
    cid             INTEGER NOT NULL,
    report_ord      INTEGER NOT NULL,                -- -> battle_report.ord
    ord             INTEGER NOT NULL,
    family          TEXT,
    burned          INTEGER,
    reserve         INTEGER,
    FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- The wrecks on offer after a battle. Rolled once when the fight ended, so
-- a reload offers the same ones.
CREATE TABLE battle_report_salvage (
    cid             INTEGER NOT NULL,
    report_ord      INTEGER NOT NULL,                -- -> battle_report.ord
    ord             INTEGER NOT NULL,
    key             TEXT,
    name            TEXT,
    bv              INTEGER,
    armor_pct       INTEGER,
    quality         TEXT,                            -- types.Quality
    damaged         INTEGER,                         -- damaged slots
    destroyed       INTEGER,                         -- destroyed slots
    missing         INTEGER,                         -- missing components
    hull_instance_id INTEGER NOT NULL DEFAULT 0,     -- .none (0) on abstraction path; real drawn hull id on pool path (P3e.5b-3b)
    FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);

-- Indexes (D31, A28): cid filters on every campaign load; composite shapes
-- for battle_report sub-tables whose loaders filter on (cid, report_ord).
-- The executable DDL in src/persist/store.zig is the truth; this block is
-- the readable reference only.
CREATE INDEX IF NOT EXISTS ix_meta_cid ON meta(cid);
CREATE INDEX IF NOT EXISTS ix_meta_text_cid ON meta_text(cid);
CREATE INDEX IF NOT EXISTS ix_rng_cid ON rng(cid);
CREATE INDEX IF NOT EXISTS ix_commander_cid ON commander(cid);
CREATE INDEX IF NOT EXISTS ix_person_cid ON person(cid);
CREATE INDEX IF NOT EXISTS ix_person_skill_cid ON person_skill(cid);
CREATE INDEX IF NOT EXISTS ix_injury_cid ON injury(cid);
CREATE INDEX IF NOT EXISTS ix_award_cid ON award(cid);
CREATE INDEX IF NOT EXISTS ix_ability_cid ON ability(cid);
CREATE INDEX IF NOT EXISTS ix_unit_cid ON unit(cid);
CREATE INDEX IF NOT EXISTS ix_unit_slot_cid ON unit_slot(cid);
CREATE INDEX IF NOT EXISTS ix_force_cid ON force(cid);
CREATE INDEX IF NOT EXISTS ix_force_unit_cid ON force_unit(cid);
CREATE INDEX IF NOT EXISTS ix_force_child_cid ON force_child(cid);
CREATE INDEX IF NOT EXISTS ix_stock_cid ON stock(cid);
CREATE INDEX IF NOT EXISTS ix_hq_cid ON hq(cid);
CREATE INDEX IF NOT EXISTS ix_hq_facility_cid ON hq_facility(cid);
CREATE INDEX IF NOT EXISTS ix_hq_project_cid ON hq_project(cid);
CREATE INDEX IF NOT EXISTS ix_contract_cid ON contract(cid);
CREATE INDEX IF NOT EXISTS ix_txn_cid ON txn(cid);
CREATE INDEX IF NOT EXISTS ix_loan_cid ON loan(cid);
CREATE INDEX IF NOT EXISTS ix_courier_cid ON courier(cid);
CREATE INDEX IF NOT EXISTS ix_policy_cid ON policy(cid);
CREATE INDEX IF NOT EXISTS ix_bay_job_cid ON bay_job(cid);
CREATE INDEX IF NOT EXISTS ix_candidate_cid ON candidate(cid);
CREATE INDEX IF NOT EXISTS ix_hq_link_cid ON hq_link(cid);
CREATE INDEX IF NOT EXISTS ix_unit_transfer_cid ON unit_transfer(cid);
CREATE INDEX IF NOT EXISTS ix_supply_policy_cid ON supply_policy(cid);
CREATE INDEX IF NOT EXISTS ix_stock_policy_cid ON stock_policy(cid);
CREATE INDEX IF NOT EXISTS ix_faction_cooling_cid ON faction_cooling(cid);
CREATE INDEX IF NOT EXISTS ix_faction_standing_cid ON faction_standing(cid);
CREATE INDEX IF NOT EXISTS ix_event_memory_cid ON event_memory(cid);
CREATE INDEX IF NOT EXISTS ix_listing_cid ON listing(cid);
CREATE INDEX IF NOT EXISTS ix_part_order_cid ON part_order(cid);
CREATE INDEX IF NOT EXISTS ix_event_log_cid ON event_log(cid);
CREATE INDEX IF NOT EXISTS ix_pending_event_cid ON pending_event(cid);
CREATE INDEX IF NOT EXISTS ix_refit_plan_cid ON refit_plan(cid);
CREATE INDEX IF NOT EXISTS ix_refit_op_cid ON refit_op(cid);
CREATE INDEX IF NOT EXISTS ix_rating_snapshot_cid ON rating_snapshot(cid);
CREATE INDEX IF NOT EXISTS ix_battle_report_cid ON battle_report(cid);
CREATE INDEX IF NOT EXISTS ix_battle_report_hit_report ON battle_report_hit(cid, report_ord);
CREATE INDEX IF NOT EXISTS ix_battle_report_ammo_report ON battle_report_ammo(cid, report_ord);
CREATE INDEX IF NOT EXISTS ix_battle_report_salvage_report ON battle_report_salvage(cid, report_ord);
CREATE INDEX IF NOT EXISTS ix_rng_stream_cid ON rng_stream(cid);

-- P4e: per-operation lance task assignments.
CREATE TABLE operation_task (
    cid             INTEGER NOT NULL,
    contract_id     INTEGER NOT NULL, -- -> contract.id
    operation_id    INTEGER NOT NULL, -- -> operation.id
    ord             INTEGER NOT NULL, -- assignment order within the operation
    lance_id        INTEGER NOT NULL, -- -> force.id (the lance's ForceId)
    task            TEXT    NOT NULL, -- domain/operation.zig LanceTask tag name
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_operation_task_cid ON operation_task(cid, contract_id, operation_id);

-- P4g: per-operation command intervention applications.
CREATE TABLE operation_intervention (
    cid             INTEGER NOT NULL,
    contract_id     INTEGER NOT NULL, -- -> contract.id
    operation_id    INTEGER NOT NULL, -- -> operation.id
    ord             INTEGER NOT NULL, -- application order within the operation
    kind            TEXT    NOT NULL, -- domain/operation.zig Intervention tag name
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_operation_intervention_cid ON operation_intervention(cid, contract_id, operation_id);

-- P4e: per-engagement tasked-lance results (child of battle_report).
CREATE TABLE battle_report_task (
    cid             INTEGER NOT NULL,
    report_ord      INTEGER NOT NULL, -- -> battle_report.ord
    ord             INTEGER NOT NULL, -- row order within the report
    lance_id        INTEGER NOT NULL, -- -> force.id (ForceId at resolution time)
    lance_name      TEXT    NOT NULL, -- duped at resolution time (arena-owned in memory)
    task            TEXT    NOT NULL, -- domain/operation.zig LanceTask tag name
    succeeded       INTEGER NOT NULL CHECK (succeeded IN (0,1)),
    note            TEXT    NOT NULL, -- short consequence descriptor
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_battle_report_task_report ON battle_report_task(cid, report_ord);

-- P5b.1: the phases an engagement fought and the order given at each
-- (child of battle_report; empty for a concession or a forfeit).
CREATE TABLE battle_report_phase (
    cid             INTEGER NOT NULL,
    report_ord      INTEGER NOT NULL, -- -> battle_report.ord
    ord             INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord BETWEEN 0 AND 2), -- fought order, contiguous from 0 (battle_phases.max_phases)
    phase           TEXT    NOT NULL CHECK (phase IN ('contact','decisive','pursuit','withdrawal')), -- domain/battle_phase.zig Phase
    order_kind      TEXT    NOT NULL CHECK (order_kind IN ('engage','press_on','withdraw','pursue','consolidate','cover_recovery','roe')), -- Order tag
    order_roe       TEXT    CHECK (order_roe IS NULL OR order_roe IN ('hold','standard','cautious')), -- an ROE order's ROE; NULL for every other order
    roe             TEXT    NOT NULL CHECK (roe IN ('hold','standard','cautious')), -- the ROE the phase was fought under
    ratio_bonus     INTEGER NOT NULL CHECK (typeof(ratio_bonus)='integer' AND ratio_bonus BETWEEN -2147483648 AND 2147483647), -- die-free modifiers (0 for an unrolled phase)
    scenario_mod    INTEGER NOT NULL CHECK (typeof(scenario_mod)='integer' AND scenario_mod BETWEEN -2147483648 AND 2147483647),
    roe_roll        INTEGER NOT NULL CHECK (typeof(roe_roll)='integer' AND roe_roll BETWEEN -2147483648 AND 2147483647),
    momentum        INTEGER NOT NULL CHECK (typeof(momentum)='integer' AND momentum BETWEEN -2147483648 AND 2147483647),
    lever_mod       INTEGER NOT NULL CHECK (typeof(lever_mod)='integer' AND lever_mod BETWEEN -2147483648 AND 2147483647), -- P5b.2: the contact-pause levers' decisive-roll modifier (the sum of the report's levers); 0 in every other phase
    margin          INTEGER NOT NULL CHECK (typeof(margin)='integer' AND margin BETWEEN -2147483648 AND 2147483647), -- roll less tuning.battle.phases.par
    hits            INTEGER NOT NULL CHECK (typeof(hits)='integer' AND hits BETWEEN 0 AND 4294967295), -- hits the phase added
    PRIMARY KEY (cid, report_ord, ord),
    CHECK ((order_roe IS NULL) = (order_kind != 'roe')),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_battle_report_phase_report ON battle_report_phase(cid, report_ord);

-- P5b.2: the levers pulled at the contact pause, in the order given (child
-- of battle_report; none for a concession or a forfeit). Each lever at most
-- once; cost and roll_mod must be their owners' (battle_phases.leverCost,
-- leverMod), and the decisive phase's lever_mod their sum.
CREATE TABLE battle_report_lever (
    cid             INTEGER NOT NULL,
    report_ord      INTEGER NOT NULL, -- -> battle_report.ord
    ord             INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord BETWEEN 0 AND 4), -- order given, contiguous from 0 (battle_phases.max_levers)
    kind            TEXT    NOT NULL CHECK (kind IN ('commit_reserve','emergency_recon','reinforce','air_cover','field_repair')), -- domain/battle_phase.zig Lever
    cost            INTEGER NOT NULL CHECK (typeof(cost)='integer' AND cost BETWEEN 0 AND 255), -- command capacity spent
    roll_mod        INTEGER NOT NULL CHECK (typeof(roll_mod)='integer' AND roll_mod BETWEEN -2147483648 AND 2147483647), -- decisive-roll points added
    PRIMARY KEY (cid, report_ord, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, report_ord) REFERENCES battle_report(cid, ord) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_battle_report_lever_report ON battle_report_lever(cid, report_ord);

-- P5b.1: the battle in progress — at most one (the battle lock). The
-- contract table has no unique (cid, id), so the loader checks that the
-- contract exists and is active.
CREATE TABLE battle_in_progress (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- always 0
    contract_id     INTEGER NOT NULL CHECK (typeof(contract_id)='integer' AND contract_id BETWEEN 1 AND 4294967295), -- -> contract.id
    phase           TEXT    NOT NULL CHECK (phase IN ('contact','decisive')), -- the pause reached (domain/battle_phase.zig Pause)
    orders          INTEGER NOT NULL CHECK (typeof(orders)='integer' AND orders >= 1), -- exact battle_in_progress_order row count; completeness check, not state
    PRIMARY KEY (cid, contract_id),
    UNIQUE (cid, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_battle_in_progress_cid ON battle_in_progress(cid);

-- P5b.1: each order given in the battle in progress and the pause report it
-- reached. Replaying the orders from live state reaches the same pauses.
CREATE TABLE battle_in_progress_order (
    cid             INTEGER NOT NULL,
    contract_id     INTEGER NOT NULL, -- -> battle_in_progress.contract_id
    ord             INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- order given, contiguous from 0
    order_kind      TEXT    NOT NULL CHECK (order_kind IN ('engage','press_on','withdraw','pursue','consolidate','cover_recovery','roe','commit_reserve','intervene')),
    order_roe       TEXT    CHECK (order_roe IS NULL OR order_roe IN ('hold','standard','cautious')),
    order_intervention TEXT CHECK (order_intervention IS NULL OR order_intervention IN ('emergency_recon','reinforce','air_cover','field_repair')), -- P5b.2: an intervene order's intervention; NULL for every other order
    pause           TEXT    NOT NULL CHECK (pause IN ('contact','decisive')), -- the pause this order reached
    margin          INTEGER NOT NULL CHECK (typeof(margin)='integer' AND margin BETWEEN -2147483648 AND 2147483647),
    hits            INTEGER NOT NULL CHECK (typeof(hits)='integer' AND hits BETWEEN 0 AND 4294967295), -- hits taken so far (not yet landed)
    momentum        INTEGER NOT NULL CHECK (typeof(momentum)='integer' AND momentum BETWEEN -2147483648 AND 2147483647),
    roe             TEXT    NOT NULL CHECK (roe IN ('hold','standard','cautious')), -- ROE for the next phase
    outcome         TEXT    CHECK (outcome IS NULL OR outcome IN ('decisive_victory','victory','draw','defeat','rout')), -- decisive verdict; NULL at contact
    held_field      INTEGER NOT NULL CHECK (held_field IN (0,1)),
    odds_next       TEXT    NOT NULL CHECK (odds_next IN ('decisive','pursuit','cover')), -- the next phase the odds are for
    odds_0          INTEGER NOT NULL CHECK (typeof(odds_0)='integer' AND odds_0 BETWEEN 0 AND 65535), -- dice results per band, band order of the next phase's enum
    odds_1          INTEGER NOT NULL CHECK (typeof(odds_1)='integer' AND odds_1 BETWEEN 0 AND 65535),
    odds_2          INTEGER NOT NULL CHECK (typeof(odds_2)='integer' AND odds_2 BETWEEN 0 AND 65535),
    odds_3          INTEGER NOT NULL CHECK (typeof(odds_3)='integer' AND odds_3 BETWEEN 0 AND 65535),
    odds_4          INTEGER NOT NULL CHECK (typeof(odds_4)='integer' AND odds_4 BETWEEN 0 AND 65535),
    odds_total      INTEGER NOT NULL CHECK (typeof(odds_total)='integer' AND odds_total BETWEEN 1 AND 65535), -- equally likely results counted
    lever_mod       INTEGER NOT NULL CHECK (typeof(lever_mod)='integer' AND lever_mod BETWEEN -2147483648 AND 2147483647), -- P5b.2: the decisive-roll modifier the levers given so far add
    reserve_committed INTEGER NOT NULL CHECK (reserve_committed IN (0,1)), -- P5b.2: the reserve has been committed
    capacity_spent  INTEGER NOT NULL CHECK (typeof(capacity_spent)='integer' AND capacity_spent BETWEEN 0 AND 255), -- P5b.2: command capacity the interventions given so far spend
    PRIMARY KEY (cid, contract_id, ord),
    CHECK ((order_roe IS NULL) = (order_kind != 'roe')),
    CHECK ((order_intervention IS NULL) = (order_kind != 'intervene')),
    CHECK ((outcome IS NULL) = (pause = 'contact')),
    CHECK (pause = 'decisive' OR held_field = 0),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, contract_id) REFERENCES battle_in_progress(cid, contract_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_battle_in_progress_order_cid ON battle_in_progress_order(cid, contract_id);

-- P4i: persistent contract-introduced actors with a narrow relationship model.
-- One row per actor per campaign. actors.recurring is set when the actor recurs
-- from a prior contract (same faction_key + archetype_key encountered again).
CREATE TABLE actor (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL, -- stable insertion order
    id              INTEGER NOT NULL, -- -> types.ActorId (u32 enum); nonzero
    archetype_key   TEXT    NOT NULL, -- -> data/tables/actor_archetypes.zon
    first_name      TEXT    NOT NULL,
    last_name       TEXT    NOT NULL,
    faction_key     TEXT    NOT NULL, -- employer or enemy faction at introduction
    side            TEXT    NOT NULL, -- FactionSide tag: "employer" | "enemy"
    contract        INTEGER NOT NULL DEFAULT 0, -- ContractId of introducing contract; 0 = none
    trust           INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    debt            INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    respect         INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    hostility       INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    last_cause      TEXT    NOT NULL DEFAULT '', -- short markup-safe label for last rel change
    last_cause_day  INTEGER NOT NULL DEFAULT 0,  -- day_index of last rel change
    recurring       INTEGER NOT NULL DEFAULT 0 CHECK (recurring IN (0,1)),
    flags           INTEGER NOT NULL CHECK (typeof(flags)='integer' AND flags BETWEEN 0 AND 15 AND (flags & 3) != 3),
                                      -- domain/actor.zig ActorFlag set: bit = the flag's value;
                                      -- did_business (1) and informed_on (2) exclude each other
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_actor_cid ON actor(cid);

-- P4h.4: bounded per-world state that accumulates across contracts on the same
-- world. Five numeric dimensions are clamped to world_min…world_max (±100).
-- Loaded ORDER BY ord to preserve StringArrayHashMapUnmanaged insertion order
-- for a deterministic round-trip digest.
CREATE TABLE world_state (
    cid                     INTEGER NOT NULL,
    ord                     INTEGER NOT NULL, -- stable insertion order for deterministic digest
    planet_key              TEXT    NOT NULL, -- -> domain/planet.zig catalog
    security                INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    civilian_support        INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    infrastructure_strain   INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    employer_control        INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    enemy_influence         INTEGER NOT NULL DEFAULT 0, -- clamped −100…100
    last_cause              TEXT    NOT NULL DEFAULT '', -- short markup-safe label for last change
    last_cause_day          INTEGER NOT NULL DEFAULT 0,  -- day_index of last change
    flags                   INTEGER NOT NULL CHECK (typeof(flags)='integer' AND flags BETWEEN 0 AND 7 AND (flags & 3) != 3),
                                              -- domain/world_state.zig WorldFlag set: bit = the flag's value;
                                              -- black_market_open (1) and black_market_closed (2) exclude each other
    PRIMARY KEY (cid, planet_key),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_world_state_cid ON world_state(cid);
CREATE INDEX IF NOT EXISTS ix_contract_situation_cid ON contract_situation(cid);

-- Persistent rival companies encountered across contracts (P4i).
-- `ord` preserves insertion order for a deterministic round-trip digest.
CREATE TABLE rival (
    cid                 INTEGER NOT NULL,
    ord                 INTEGER NOT NULL, -- stable insertion order for deterministic digest
    id                  INTEGER NOT NULL, -- RivalId enum value (u32)
    archetype_key       TEXT    NOT NULL, -- -> data/tables/rival_archetypes.zon
    commander_first     TEXT    NOT NULL DEFAULT '',
    commander_last      TEXT    NOT NULL DEFAULT '',
    unit_name           TEXT    NOT NULL DEFAULT '', -- markup-safe display name
    faction_key         TEXT    NOT NULL DEFAULT '', -- -> factions catalog
    side                TEXT    NOT NULL DEFAULT 'enemy', -- FactionSide tag
    doctrine            TEXT    NOT NULL DEFAULT 'aggressive', -- RivalDoctrine tag
    contract            INTEGER NOT NULL DEFAULT 0, -- most-recent ContractId (0 = none)
    standing            INTEGER NOT NULL DEFAULT 0, -- clamped -100…100
    encounters          INTEGER NOT NULL DEFAULT 0, -- operation outcomes tallied
    last_cause          TEXT    NOT NULL DEFAULT '', -- markup-safe label for last standing change
    last_cause_day      INTEGER NOT NULL DEFAULT 0,  -- day_index of last change
    recurring           INTEGER NOT NULL DEFAULT 0,  -- boolean: carried forward from prior contract
    -- P3e entity split: FK to the world MercCompany this rivalry overlay belongs to (§8.B).
    -- .none (0) until P3e.5 attaches rivals to companies.
    merc_company_id     INTEGER NOT NULL DEFAULT 0,  -- MercCompanyId int; 0 = none
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_rival_cid ON rival(cid);

-- Persistent officer arcs for company commanders and combat-lance leaders
-- encountered across contracts (P4i). Each arc rides on an existing Person;
-- it owns only the bounded task-performance standing for one contract's span.
-- `ord` preserves insertion order for a deterministic round-trip digest.
CREATE TABLE officer_arc (
    cid                 INTEGER NOT NULL,
    ord                 INTEGER NOT NULL, -- stable insertion order for deterministic digest
    id                  INTEGER NOT NULL, -- OfficerArcId enum value (u32)
    person              INTEGER NOT NULL, -- PersonId back-reference (must exist at load)
    contract            INTEGER NOT NULL DEFAULT 0, -- ContractId (0 = none)
    seat                TEXT    NOT NULL DEFAULT 'lance_leader', -- OfficerSeat tag
    performance         INTEGER NOT NULL DEFAULT 0, -- clamped -100…100
    encounters          INTEGER NOT NULL DEFAULT 1, -- arc count for this person (1 on first contract)
    last_cause          TEXT    NOT NULL DEFAULT '', -- markup-safe label for last perf change
    last_cause_day      INTEGER NOT NULL DEFAULT 0,  -- day_index of last change
    recurring           INTEGER NOT NULL DEFAULT 0,  -- boolean: carried forward from prior contract
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_officer_arc_cid ON officer_arc(cid);

-- P3c.1: the lifecycle record of one physical hull from acquisition through
-- use and eventual destruction. One row per hull instance per campaign.
-- `ord` preserves insertion order for a deterministic round-trip digest.
-- The design loadout (intended fit) lives in hull_loadout; unit_slot holds
-- the live condition per owned unit.
CREATE TABLE hull_instance (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,                -- stable insertion order for deterministic digest
    id              INTEGER NOT NULL,                -- HullInstanceId enum value (u32); nonzero
    base_key        TEXT,                            -- -> chassis.zon stable key
    name            TEXT,                            -- display name (nullable; markup-safe)
    nickname        TEXT,                            -- callsign (nullable; markup-safe)
    status          TEXT    NOT NULL DEFAULT 'active', -- HullStatus tag: active | permanently_destroyed
    intro_year      INTEGER NOT NULL DEFAULT 0,      -- TUNE: sourced from base chassis intro_year
    pre_campaign    INTEGER NOT NULL DEFAULT 0 CHECK (pre_campaign IN (0,1)), -- bool: acquired before campaign start
    -- P3e.2/P3e entity split: current-owner fields
    -- (HullOwner union; OwnerType tags: player|faction|merc_company|market|destroyed)
    owner_type      TEXT    NOT NULL DEFAULT 'player', -- OwnerType tag name (active union tag)
    owner_faction_key TEXT  NOT NULL DEFAULT '',       -- FactionRow.key when owner_type='faction'; else ''
    owner_merc_company_id INTEGER NOT NULL DEFAULT 0,  -- MercCompanyId int when owner_type='merc_company'; else 0
    catalogue TEXT NOT NULL DEFAULT 'chassis' CHECK (catalogue IN ('chassis','artillery')),
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_hull_instance_cid ON hull_instance(cid);

-- P3c.1: one slot of a hull instance's design loadout.
-- hull_loadout -> hull_instance (containment FK).
CREATE TABLE hull_loadout (
    cid             INTEGER NOT NULL,
    hull_instance_id INTEGER NOT NULL,              -- -> hull_instance.id
    slot_index      INTEGER NOT NULL,               -- positional ordinal; 0-based
    part_key        TEXT,                           -- catalog key of the intended part
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_hull_loadout_cid ON hull_loadout(cid);

-- P3c.2: per-engagement combat record for a physical hull.
-- hull_combat_record -> hull_instance (containment FK).
-- battle_id is a validated backlink to the permanent battle-report history;
-- contract_id remains historical and may be unavailable on load.
-- hull_instance_id is the containment FK.
CREATE TABLE hull_combat_record (
    cid             INTEGER NOT NULL,
    hull_instance_id INTEGER NOT NULL,                  -- -> hull_instance.id (validated)
    ord             INTEGER NOT NULL,                   -- stable insertion order
    battle_id       INTEGER NOT NULL DEFAULT 0,         -- BattleId backlink; validated when nonzero
    contract_id     INTEGER NOT NULL DEFAULT 0,         -- ContractId backlink; not validated
    kills           INTEGER NOT NULL DEFAULT 0,         -- kills credited this engagement
    hits_taken      INTEGER NOT NULL DEFAULT 0,         -- count of HullHit rows for this unit
    armor_lost      INTEGER NOT NULL DEFAULT 0,         -- first.armor_before - last.armor_after
    slots_damaged   INTEGER NOT NULL DEFAULT 0,         -- HullHit.slot_result == .damaged count
    slots_destroyed INTEGER NOT NULL DEFAULT 0,         -- HullHit.slot_result == .destroyed count
    destroyed       INTEGER NOT NULL DEFAULT 0 CHECK (destroyed IN (0,1)), -- bool: unit destroyed
    cause           TEXT    NOT NULL DEFAULT 'none',    -- WreckCause tag; .none if not destroyed
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_hull_combat_record_cid ON hull_combat_record(cid);

-- P3c.3: maintenance log entry for a physical hull (depot repair or loadout refit).
-- maintenance_entry -> hull_instance (containment FK).
-- battle_id is a validated backlink to the permanent battle-report history;
-- tech remains historical and may be unavailable on load.
-- hull_instance_id is the containment FK.
-- Column order matches runtime (saveMaintenanceEntries/loadMaintenanceEntries).
CREATE TABLE maintenance_entry (
    cid              INTEGER NOT NULL,
    hull_instance_id INTEGER NOT NULL,              -- -> hull_instance.id (validated)
    ord              INTEGER NOT NULL,              -- stable insertion order
    day              INTEGER NOT NULL DEFAULT 0,    -- day_index when the job was queued
    tech             INTEGER NOT NULL DEFAULT 0,    -- PersonId of assigned tech; 0 = none
    action           TEXT    NOT NULL DEFAULT 'repair', -- MaintenanceAction tag
    description      TEXT    NOT NULL DEFAULT '',   -- short phrase from action.describe()
    battle_id        INTEGER NOT NULL DEFAULT 0,    -- BattleId backlink; validated when nonzero
    cost             INTEGER NOT NULL DEFAULT 0,    -- labor cost in C-bills (copied from job)
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_maintenance_entry_cid ON maintenance_entry(cid);

-- hull_ownership_history -> hull_instance (containment FK).
-- prior_owner_key is a free provenance string (may name a faction that no longer exists);
-- it is NOT a typed FK and is NOT catalogue-validated — only markup-safe (rule 50).
-- Only hull_instance_id is a validated FK (schema + loader orphan check).
-- Column order matches runtime (saveHullOwnershipHistory/loadHullOwnershipHistory).
CREATE TABLE hull_ownership_history (
    cid              INTEGER NOT NULL,
    hull_instance_id INTEGER NOT NULL,                  -- -> hull_instance.id (validated)
    ord              INTEGER NOT NULL CHECK (ord >= 0),                  -- stable insertion order (append-only)
    from_day         INTEGER NOT NULL DEFAULT 0 CHECK (from_day BETWEEN 0 AND 4294967295),        -- day_index the interval opened
    to_day           INTEGER CHECK (to_day IS NULL OR (to_day BETWEEN from_day AND 4294967295)), -- NULL = open; zero closes on day zero
    acquisition_type TEXT    NOT NULL DEFAULT 'initial', -- AcquisitionType tag
    prior_owner_key  TEXT    NOT NULL DEFAULT '',        -- provenance: faction key, "player", or "unknown"
    UNIQUE (cid,ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_hull_ownership_history_cid ON hull_ownership_history(cid);

-- faction_roster: living faction hull pools (P3e.3, docs/p3c-economy-design.md §2).
-- One row per owned hull per faction. ord preserves insertion order for a deterministic
-- round-trip digest (StringArrayHashMapUnmanaged key order is gameplay-significant).
-- faction_key is a catalogue key (data/tables/factions.zon) validated by the loader
-- (Check.house), NOT a DB FK — matching the hull owner_faction_key treatment.
-- hull_instance_id is a validated containment FK.
-- A key is present iff it owns ≥1 hull (empty pool = map absence; empty-list keys do not persist).
-- Column order matches runtime (saveFactionRosters/loadFactionRosters).
CREATE TABLE faction_roster (
    cid              INTEGER NOT NULL,
    ord              INTEGER NOT NULL,                  -- global insertion order (restores map+list order)
    faction_key      TEXT    NOT NULL,                  -- FactionRow.key (catalogue-validated by loader)
    hull_instance_id INTEGER NOT NULL,                  -- -> hull_instance.id (validated)
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_faction_roster_cid ON faction_roster(cid);

-- merc_company: world mercenary company entities (P3e entity split, §8).
-- Identity record for an independent merc outfit operating in the same theatre as the player.
-- Seeded at campaign creation and founded as replacements.
-- npc_base.validate also refuses a base that is no world or not of the
-- company's faction, and a ready_day before founded_day.
--
-- Migration v75 → v76: v75 has no home_planet_key or ready_day. The table is
-- rebuilt create–copy–drop–rename in stored order (merc_company_roster's
-- foreign key names the rebuilt table); each company's home_planet_key is
-- npc_base.compatibilityBase of its faction (its capital, but Star's End for
-- PER, whose capital Galatea is an LC world), its ready_day its founded_day;
-- a faction_key with no compatibility base is CorruptStore.
CREATE TABLE merc_company (
    cid              INTEGER NOT NULL,
    ord              INTEGER NOT NULL,                  -- stable insertion order for deterministic digest
    id               INTEGER NOT NULL,                  -- MercCompanyId enum value (u32); nonzero
    archetype_key    TEXT    NOT NULL DEFAULT '',       -- -> data/tables/rival_archetypes.zon
    commander_first  TEXT    NOT NULL DEFAULT '',
    commander_last   TEXT    NOT NULL DEFAULT '',
    unit_name        TEXT    NOT NULL DEFAULT '',       -- markup-safe display name
    faction_key      TEXT    NOT NULL DEFAULT '',       -- -> factions catalog
    side             TEXT    NOT NULL DEFAULT 'employer', -- FactionSide tag
    doctrine         TEXT    NOT NULL DEFAULT 'cautious', -- RivalDoctrine tag
    cbills           INTEGER NOT NULL DEFAULT 0,        -- CBills
    founded_day      INTEGER NOT NULL DEFAULT 0,        -- day_index founded (0 = pre-campaign)
    dissolved_day    INTEGER NOT NULL DEFAULT 0,        -- 0 = active; nonzero = day_index dissolved
    logo_key         TEXT    NOT NULL DEFAULT '',       -- logo basename; '' legacy
    band_key         TEXT    NOT NULL,                  -- -> data/tables/merc_bands.zon; unknown = CorruptSave (v68)
    understrength_since INTEGER CHECK (understrength_since IS NULL OR (typeof(understrength_since)='integer' AND understrength_since BETWEEN 0 AND 4294967295)), -- day_index first found below its band's line; NULL = at its line; > campaign.day = CorruptSave (v69)
    home_planet_key  TEXT    NOT NULL CHECK (typeof(home_planet_key)='text' AND length(home_planet_key) > 0), -- -> planets catalog: the base, a world of its faction (v76)
    ready_day        INTEGER NOT NULL CHECK (typeof(ready_day)='integer' AND ready_day BETWEEN 0 AND 4294967295), -- day_index it can first muster; >= founded_day (v76)
    PRIMARY KEY (cid, id),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_merc_company_cid ON merc_company(cid);

-- merc_hull_arrival: merc hulls bought off their company's base world and
-- still travelling there (docs/p5d-conflict-world-design.md §L1; v76), in
-- insertion order. The company owns each but cannot field it before
-- arrive_day. npc_base.validate also refuses a hull no active merc company
-- owns and holds on its roster.
--
-- Migration v75 → v76: a v75 purchase was fieldable at once, so the table is
-- created empty.
CREATE TABLE merc_hull_arrival (
    cid              INTEGER NOT NULL,
    ord              INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- insertion order
    hull_instance_id INTEGER NOT NULL CHECK (typeof(hull_instance_id)='integer' AND hull_instance_id BETWEEN 1 AND 4294967295), -- -> hull_instance.id
    arrive_day       INTEGER NOT NULL CHECK (typeof(arrive_day)='integer' AND arrive_day BETWEEN 0 AND 4294967295), -- day_index it reaches the base
    PRIMARY KEY (cid, hull_instance_id),
    UNIQUE (cid, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_merc_hull_arrival_cid ON merc_hull_arrival(cid);

-- merc_company_roster: living merc-company hull pools (P3e entity split; replaces rival_roster).
-- One row per owned hull per merc company. Same ord/order semantics as faction_roster.
-- merc_company_id is a validated containment FK into merc_company; hull_instance_id likewise.
-- Zero rows for an existing merc company mean its roster is empty; the loader
-- restores that empty entry (every merc company has one).
-- Column order matches runtime (saveMercCompanyRosters/loadMercCompanyRosters).
CREATE TABLE merc_company_roster (
    cid              INTEGER NOT NULL,
    ord              INTEGER NOT NULL,                  -- global insertion order
    merc_company_id  INTEGER NOT NULL,                  -- -> merc_company.id (validated)
    hull_instance_id INTEGER NOT NULL,                  -- -> hull_instance.id (validated)
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, merc_company_id) REFERENCES merc_company(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, hull_instance_id) REFERENCES hull_instance(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_merc_company_roster_cid ON merc_company_roster(cid);

-- personage: world personages (docs/p5d-conflict-world-design.md §B, v70;
-- key and family_key v72). One ruler per world whose faction hires, one
-- leader per hiring faction except PER, seated on its capital; each the
-- data/tables/personages.zon row whose era window holds the start year, else
-- procedural; plus the start year's heirs, family and officials, all data
-- rows. The title is not stored: it is read from the data row by key. The
-- loader (personages.validate) refuses an unknown key or seat, a ruler on a
-- world that does not hire or of another faction than its world's, two
-- rulers on a world or two leaders for a faction, a leader off its capital
-- or for PER, a commander's campaign missing any of them, personages
-- without a commander, a key naming no data row or a keyed row differing
-- from it, a duplicate key, a procedural heir, family member or official,
-- and a generator version that does not match the provenance. meta
-- next_personage_id exceeds every id.
--
-- Migration v71 → v72: v71 has no key or family_key column, and its role
-- and provenance CHECKs admit only rulers, leaders and 'procedural' with
-- generator_version = 1. Every v71 row is procedural; it is copied with every
-- column as stored plus key = '' and family_key = '' into a new table that
-- then replaces personage (create, copy, drop, rename — so personage_relation's
-- foreign keys keep naming personage), and no data row is added.
CREATE TABLE personage (
    cid              INTEGER NOT NULL,
    ord              INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- insertion order
    id               INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), -- PersonageId
    role             TEXT    NOT NULL CHECK (role IN ('planetary_ruler','faction_leader','heir','family','intelligence_chief')),
    first_name       TEXT    NOT NULL CHECK (typeof(first_name)='text' AND length(first_name) > 0), -- markup-safe
    last_name        TEXT    NOT NULL CHECK (typeof(last_name)='text' AND length(last_name) > 0),   -- markup-safe
    faction_key      TEXT    NOT NULL CHECK (typeof(faction_key)='text'),     -- -> factions catalog; a ruler's equals its world's
    seat_planet_key  TEXT    NOT NULL CHECK (typeof(seat_planet_key)='text'), -- -> planets catalog; a leader's is its capital
    motives          INTEGER NOT NULL CHECK (typeof(motives)='integer' AND motives BETWEEN 1 AND 511 AND (motives & 1) + ((motives >> 1) & 1) + ((motives >> 2) & 1) + ((motives >> 3) & 1) + ((motives >> 4) & 1) + ((motives >> 5) & 1) + ((motives >> 6) & 1) + ((motives >> 7) & 1) + ((motives >> 8) & 1) BETWEEN 2 AND 3), -- bit = personage.Motive value; two or three set
    ambition         INTEGER NOT NULL CHECK (typeof(ambition)='integer' AND ambition BETWEEN 0 AND 100),
    provenance       TEXT    NOT NULL CHECK (provenance IN ('procedural','canon','authored')), -- internal; never displayed
    generator_version INTEGER NOT NULL CHECK (typeof(generator_version)='integer' AND generator_version IN (0,1)), -- personage_gen.version; 0 for a data row
    key              TEXT    NOT NULL CHECK (typeof(key)='text'),        -- -> personages.zon row; '' for procedural
    family_key       TEXT    NOT NULL CHECK (typeof(family_key)='text'), -- the data row's family; '' for none
    CHECK ((provenance = 'procedural' AND key = '' AND family_key = '' AND generator_version = 1 AND role IN ('planetary_ruler','faction_leader')) OR (provenance IN ('canon','authored') AND key <> '' AND generator_version = 0)),
    PRIMARY KEY (cid, id),
    UNIQUE (cid, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_personage_cid ON personage(cid);
CREATE UNIQUE INDEX IF NOT EXISTS ux_personage_key ON personage(cid, key) WHERE key <> '';

-- personage_relation: relations between personages
-- (docs/p5d-conflict-world-design.md §B relations, v71). kin, rival and ally
-- are symmetric and stored once with from_id < to_id; liege runs vassal ->
-- liege and grudge holder -> target. A liege's weight is the vassal's
-- loyalty. The loader (personage_relations.validate) also refuses a dangling
-- endpoint, a liege from anyone but a ruler or to anyone but the leader of
-- the ruler's own faction, a second liege, a ruler of a leader-bearing
-- faction without one, rival and ally on one pair, and relations without
-- personages.
CREATE TABLE personage_relation (
    cid      INTEGER NOT NULL,
    ord      INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- generation order
    from_id  INTEGER NOT NULL CHECK (typeof(from_id)='integer' AND from_id BETWEEN 1 AND 4294967295), -- PersonageId
    to_id    INTEGER NOT NULL CHECK (typeof(to_id)='integer' AND to_id BETWEEN 1 AND 4294967295),     -- PersonageId
    kind     TEXT    NOT NULL CHECK (typeof(kind)='text' AND kind IN ('liege','kin','rival','ally','grudge')),
    weight   INTEGER NOT NULL CHECK (typeof(weight)='integer' AND weight BETWEEN 1 AND 100), -- tuning.politics relation weights
    CHECK (from_id <> to_id),
    CHECK (kind NOT IN ('kin','rival','ally') OR from_id < to_id),
    PRIMARY KEY (cid, ord),
    UNIQUE (cid, from_id, to_id, kind),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, from_id) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, to_id) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_personage_relation_cid ON personage_relation(cid);

-- conflict: world conflicts (docs/p5d-conflict-world-design.md §C, §E;
-- v73, rebuilt at v74), in id order, resolved ones kept. Each opened from a
-- data/tables/political_events.zon template: an `offensive` one (a war)
-- from an `opening` row, a `standing` one (a ruler's standing garrison or
-- training need) from a `standing` row. An offensive conflict's §A days are
-- fixed at opening; a standing one has no aggressor side, is known from its
-- opening, is instigated by its defender and ends only stood down. The
-- status (preparing, threatened, open, standing, resolved) is derived, never
-- stored. The loader (politics.validate) also refuses an unknown template,
-- world or faction, a template of the other family, an instigator that is
-- not the side personage its template names, a staging world other than the
-- aggressor faction's nearest, a preparation (strike day less the travel,
-- after opening) or a fighting span outside its tuned range, an opening
-- after today, an unresolved conflict at or past its expiry or a resolved
-- one before it, two unresolved offensive conflicts on one world, more than
-- max_open_conflicts unresolved, a standing need of another faction than
-- its world's or a second one on its world, and an id at or above meta
-- next_conflict_id.
--
-- Migration v72 → v73: v72 has no conflict table and no next_conflict_id.
-- A v72 campaign has no conflict; the table is created empty, every campaign
-- gets next_conflict_id = 1, and no other row changes.
-- Migration v73 → v74: the table is rebuilt (create–copy–drop–rename, rows
-- in stored order). Every v73 conflict is offensive: it gains family
-- 'offensive' and keeps every column as stored.
CREATE TABLE conflict (
    cid                 INTEGER NOT NULL,
    ord                 INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- id order
    id                  INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), -- ConflictId
    template_key        TEXT    NOT NULL CHECK (typeof(template_key)='text' AND length(template_key) > 0), -- -> political_events.zon row
    planet_key          TEXT    NOT NULL CHECK (typeof(planet_key)='text' AND length(planet_key) > 0),     -- -> planets catalog: the world fought over
    aggressor_faction   TEXT    CHECK (aggressor_faction IS NULL OR (typeof(aggressor_faction)='text' AND length(aggressor_faction) > 0)), -- -> factions catalog; NULL for a standing need
    aggressor_personage INTEGER CHECK (aggressor_personage IS NULL OR (typeof(aggressor_personage)='integer' AND aggressor_personage BETWEEN 1 AND 4294967295)), -- PersonageId
    defender_faction    TEXT    NOT NULL CHECK (typeof(defender_faction)='text' AND length(defender_faction) > 0),   -- -> factions catalog
    defender_personage  INTEGER NOT NULL CHECK (typeof(defender_personage)='integer' AND defender_personage BETWEEN 1 AND 4294967295), -- PersonageId; the cause's target
    instigator          INTEGER NOT NULL CHECK (typeof(instigator)='integer' AND instigator BETWEEN 1 AND 4294967295), -- PersonageId; the template's side personage
    staging_planet_key  TEXT    CHECK (staging_planet_key IS NULL OR (typeof(staging_planet_key)='text' AND length(staging_planet_key) > 0)), -- the aggressor faction's world nearest the target
    opened_day          INTEGER NOT NULL CHECK (typeof(opened_day)='integer' AND opened_day BETWEEN 0 AND 4294967295),
    discovery_day       INTEGER NOT NULL CHECK (typeof(discovery_day)='integer' AND discovery_day BETWEEN 0 AND 4294967295),
    strike_day          INTEGER CHECK (strike_day IS NULL OR (typeof(strike_day)='integer' AND strike_day BETWEEN 0 AND 4294967295)),
    expires_day         INTEGER CHECK (expires_day IS NULL OR (typeof(expires_day)='integer' AND expires_day BETWEEN 0 AND 4294967295)),
    local_lances        INTEGER NOT NULL CHECK (typeof(local_lances)='integer' AND local_lances BETWEEN 1 AND 255), -- the defender's garrison
    local_quality       TEXT    NOT NULL CHECK (typeof(local_quality)='text' AND local_quality IN ('green','regular','veteran','elite')),
    local_lance_bv      INTEGER NOT NULL CHECK (typeof(local_lance_bv)='integer' AND local_lance_bv >= 0),
    local_lance_tons    INTEGER NOT NULL CHECK (typeof(local_lance_tons)='integer' AND local_lance_tons BETWEEN 0 AND 4294967295),
    strike_lances       INTEGER CHECK (strike_lances IS NULL OR (typeof(strike_lances)='integer' AND strike_lances BETWEEN 1 AND 255)), -- the aggressor's house force; NULL for a standing need
    strike_quality      TEXT    CHECK (strike_quality IS NULL OR (typeof(strike_quality)='text' AND strike_quality IN ('green','regular','veteran','elite'))),
    strike_lance_bv     INTEGER CHECK (strike_lance_bv IS NULL OR (typeof(strike_lance_bv)='integer' AND strike_lance_bv >= 0)),
    strike_lance_tons   INTEGER CHECK (strike_lance_tons IS NULL OR (typeof(strike_lance_tons)='integer' AND strike_lance_tons BETWEEN 0 AND 4294967295)),
    outcome             TEXT    CHECK (outcome IS NULL OR (typeof(outcome)='text' AND outcome IN ('aggressor_won','defender_held','stood_down'))), -- NULL until resolved
    family              TEXT    NOT NULL CHECK (typeof(family)='text' AND family IN ('offensive','standing')), -- conflict.Family
    CHECK (family <> 'offensive' OR (aggressor_faction IS NOT NULL AND aggressor_personage IS NOT NULL AND staging_planet_key IS NOT NULL AND strike_day IS NOT NULL AND expires_day IS NOT NULL AND strike_lances IS NOT NULL AND strike_quality IS NOT NULL AND strike_lance_bv IS NOT NULL AND strike_lance_tons IS NOT NULL AND opened_day < discovery_day AND discovery_day < strike_day AND strike_day < expires_day AND (outcome IS NULL OR outcome <> 'stood_down'))),
    CHECK (family <> 'standing' OR (aggressor_faction IS NULL AND aggressor_personage IS NULL AND staging_planet_key IS NULL AND strike_day IS NULL AND expires_day IS NULL AND strike_lances IS NULL AND strike_quality IS NULL AND strike_lance_bv IS NULL AND strike_lance_tons IS NULL AND discovery_day = opened_day AND instigator = defender_personage AND (outcome IS NULL OR outcome = 'stood_down'))),
    PRIMARY KEY (cid, id),
    UNIQUE (cid, ord),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, aggressor_personage) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, defender_personage) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, instigator) REFERENCES personage(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_conflict_cid ON conflict(cid);

-- news_item: the political news the outfit heard (docs/p5d-conflict-world-design.md
-- §K "News"; v75), in id (emission) order, all kept. One per discovery,
-- strike and resolution of an offensive conflict within news_reach_ly of
-- an HQ or a company on the day it broke; a standing need makes none. The
-- day, distance and severity are derived from the conflict, never stored.
-- The loader (news.validate) also refuses a standing conflict, a day after
-- today, a resolution of an unresolved conflict, an unknown presence world
-- or one beyond reach of the conflict's world, text that is not UTF-8, and
-- an id at or above meta next_news_id.
--
-- Migration v74 → v75: v74 has no news_item table and no next_news_id. A
-- v74 campaign has no news item and reach is never back-filled; the table
-- is created empty, every campaign gets next_news_id = 1, and no other row
-- changes.
CREATE TABLE news_item (
    cid                   INTEGER NOT NULL,
    ord                   INTEGER NOT NULL CHECK (typeof(ord)='integer' AND ord >= 0), -- id order
    id                    INTEGER NOT NULL CHECK (typeof(id)='integer' AND id BETWEEN 1 AND 4294967295), -- NewsId
    kind                  TEXT    NOT NULL CHECK (typeof(kind)='text' AND kind IN ('discovery','strike','resolution')), -- news_item.NewsKind
    conflict_id           INTEGER NOT NULL CHECK (typeof(conflict_id)='integer' AND conflict_id BETWEEN 1 AND 4294967295), -- -> conflict.id
    reach_from            TEXT    NOT NULL CHECK (typeof(reach_from)='text' AND reach_from IN ('hq','company')), -- the presence that heard it
    reach_from_planet_key TEXT    NOT NULL CHECK (typeof(reach_from_planet_key)='text' AND length(reach_from_planet_key) > 0), -- -> planets catalog: that presence's world
    text                  TEXT    NOT NULL CHECK (typeof(text)='text' AND length(text) > 0), -- plain text, rendered once
    PRIMARY KEY (cid, id),
    UNIQUE (cid, ord),
    UNIQUE (cid, conflict_id, kind),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid, conflict_id) REFERENCES conflict(cid, id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_news_item_cid ON news_item(cid);

-- Artillery formation and HQ offer fields are persisted (schema v60).
-- Catalogue facts and attached location are derived; quotes are scratch.
-- Placement payload columns are nullable and exactly the tag's own: hq_pool
-- pool_hq; company company; freight from_hq, to_hq and the journey (dispatch_day,
-- eta_day, paid_cost); field_freight from_hq, company and the journey;
-- field_return to_hq and the journey (v67 adds the two field tags; v66 and
-- older are refused). Sold records retain identity.
CREATE TABLE artillery_formation (cid INTEGER NOT NULL, ord INTEGER NOT NULL CHECK (ord >= 0), id INTEGER NOT NULL CHECK (id BETWEEN 1 AND 4294967295), hull INTEGER NOT NULL CHECK (hull BETWEEN 1 AND 4294967295), acquisition_day INTEGER NOT NULL CHECK (acquisition_day BETWEEN 0 AND 4294967295), paid_price INTEGER NOT NULL CHECK (paid_price > 0), placement TEXT NOT NULL CHECK (placement IN ('hq_pool','company','freight','sold','destroyed','field_freight','field_return')), pool_hq INTEGER, company INTEGER, from_hq INTEGER, to_hq INTEGER, dispatch_day INTEGER, eta_day INTEGER, paid_cost INTEGER, quality TEXT NOT NULL DEFAULT 'c' CHECK(typeof(quality)='text' AND quality IN ('a','b','c','d','e','f')), armor INTEGER NOT NULL DEFAULT 100 CHECK(typeof(armor)='integer' AND armor BETWEEN 0 AND 100), last_maintenance INTEGER CHECK(last_maintenance IS NULL OR (typeof(last_maintenance)='integer' AND last_maintenance BETWEEN 0 AND 4294967295)), tech INTEGER CHECK(tech IS NULL OR (typeof(tech)='integer' AND tech BETWEEN 1 AND 4294967295)), FOREIGN KEY(cid,tech) REFERENCES person(cid,id) DEFERRABLE INITIALLY DEFERRED, PRIMARY KEY (cid,id), UNIQUE (cid,ord), UNIQUE (cid,hull), FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,hull) REFERENCES hull_instance(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,pool_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,company) REFERENCES force(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,from_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY (cid,to_hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK ((pool_hq IS NOT NULL) = (placement='hq_pool')), CHECK ((company IS NOT NULL) = (placement IN ('company','field_freight'))), CHECK ((from_hq IS NOT NULL) = (placement IN ('freight','field_freight'))), CHECK ((to_hq IS NOT NULL) = (placement IN ('freight','field_return'))), CHECK ((dispatch_day IS NOT NULL) = (placement IN ('freight','field_freight','field_return'))), CHECK ((eta_day IS NOT NULL) = (placement IN ('freight','field_freight','field_return'))), CHECK ((paid_cost IS NOT NULL) = (placement IN ('freight','field_freight','field_return'))), CHECK (pool_hq IS NULL OR pool_hq BETWEEN 1 AND 4294967295), CHECK (company IS NULL OR company BETWEEN 1 AND 4294967295), CHECK (from_hq IS NULL OR from_hq BETWEEN 1 AND 4294967295), CHECK (to_hq IS NULL OR to_hq BETWEEN 1 AND 4294967295), CHECK (placement!='freight' OR from_hq!=to_hq), CHECK (placement NOT IN ('freight','field_freight','field_return') OR (dispatch_day BETWEEN 0 AND 4294967295 AND eta_day > dispatch_day AND eta_day <= 4294967295 AND paid_cost >= 0)));

CREATE TABLE artillery_crew (cid INTEGER NOT NULL CHECK(typeof(cid)='integer'), formation INTEGER NOT NULL CHECK(typeof(formation)='integer' AND formation BETWEEN 1 AND 4294967295), seat TEXT NOT NULL CHECK(typeof(seat)='text' AND seat IN ('commander','gunner','driver','loader')), person INTEGER CHECK(person IS NULL OR (typeof(person)='integer' AND person BETWEEN 1 AND 4294967295)), PRIMARY KEY(cid,formation,seat), UNIQUE(cid,person), FOREIGN KEY(cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,formation) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,person) REFERENCES person(cid,id) DEFERRABLE INITIALLY DEFERRED);

CREATE TABLE artillery_slot (cid INTEGER NOT NULL CHECK(typeof(cid)='integer'), formation INTEGER NOT NULL CHECK(typeof(formation)='integer' AND formation BETWEEN 1 AND 4294967295), slot TEXT NOT NULL CHECK(typeof(slot)='text' AND slot IN ('chassis','main_gun','machine_gun_right_1','machine_gun_right_2','machine_gun_left_1','machine_gun_left_2','long_tom_bin_1','long_tom_bin_2','long_tom_bin_3','long_tom_bin_4','machine_gun_bin','communications','hitch')), condition TEXT NOT NULL CHECK(typeof(condition)='text' AND condition IN ('ok','damaged','destroyed','missing')), rounds INTEGER, PRIMARY KEY(cid,formation,slot), FOREIGN KEY(cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,formation) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK((rounds IS NOT NULL)=(slot IN ('long_tom_bin_1','long_tom_bin_2','long_tom_bin_3','long_tom_bin_4','machine_gun_bin'))), CHECK(rounds IS NULL OR (typeof(rounds)='integer' AND rounds >= 0 AND rounds <= CASE WHEN slot='machine_gun_bin' THEN 100 ELSE 5 END)), CHECK(condition NOT IN ('destroyed','missing') OR rounds IS NULL OR rounds=0));
CREATE INDEX IF NOT EXISTS ix_artillery_formation_cid ON artillery_formation(cid);
CREATE TABLE artillery_offer (
    cid INTEGER NOT NULL,
    ord INTEGER NOT NULL CHECK (ord >= 0),
    id INTEGER NOT NULL CHECK (id BETWEEN 1 AND 4294967295),
    hq INTEGER NOT NULL CHECK (hq BETWEEN 1 AND 4294967295),
    year INTEGER NOT NULL CHECK (year BETWEEN 1 AND 65535),
    month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    available INTEGER NOT NULL CHECK (available IN (0,1)),
    PRIMARY KEY (cid,id),
    UNIQUE (cid,ord),
    UNIQUE (cid,hq),
    FOREIGN KEY (cid) REFERENCES campaign(id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (cid,hq) REFERENCES hq(cid,id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS ix_artillery_offer_cid ON artillery_offer(cid);

-- Current-format P2h immutable artillery reports. No result means marker=0 and
-- no parent or child rows. Marker=1 requires one parent, four canonical seats,
-- and all thirteen canonical slots, including empty seats/magazines.
-- Integer power is temporary opening attrition, never destroyed BV or kills.
-- *_before/after/fired/lost are individual LOADED ROUNDS, not warehouse packages
-- or tons. Armor/exposure are integer percent; compensation is integer C-bills.
-- Rolls irrelevant to an outcome are SQL NULL; recovery/escape pairs are jointly
-- present or absent. Names and conditions are captured history, not live lookups.
-- The codec checks original storage classes and full enum TEXT; simulation
-- validation checks arithmetic, deterministic slot changes and typed histories.
CREATE TABLE artillery_battle (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, formation INTEGER NOT NULL CHECK(formation BETWEEN 1 AND 4294967295), hull INTEGER NOT NULL CHECK(hull BETWEEN 1 AND 4294967295), catalogue_key TEXT NOT NULL, catalogue_name TEXT NOT NULL, physical INTEGER NOT NULL CHECK(physical IN (0,1)), readiness TEXT CHECK(readiness IN ('not_attached','not_present','depot_job','armor','mechanic','chassis','main_gun','communications','maintenance','crew','ammunition')), no_fire TEXT NOT NULL CHECK(no_fire IN ('none','not_present','not_ready','no_line_units','enemy_forfeit','zero_enemy_power')), fire TEXT NOT NULL CHECK(fire IN ('not_fired','hit','miss')), damage TEXT NOT NULL CHECK(damage IN ('not_exposed','unhit','damaged','recoverable','permanently_destroyed','scuttled','recovered')), target INTEGER CHECK(target BETWEEN 2 AND 12), accuracy INTEGER CHECK(accuracy BETWEEN 2 AND 12), carrier_power INTEGER CHECK(carrier_power>=0), enemy_before INTEGER CHECK(enemy_before>=0), suppressed INTEGER NOT NULL CHECK(suppressed>=0), enemy_after INTEGER CHECK(enemy_after>=0), exposure_pct INTEGER CHECK(exposure_pct BETWEEN 0 AND 100), exposure_roll INTEGER CHECK(exposure_roll BETWEEN 0 AND 99), severity INTEGER CHECK(severity BETWEEN 2 AND 12), struck_slot TEXT, struck_seat TEXT, armor_before INTEGER NOT NULL CHECK(armor_before BETWEEN 0 AND 100), armor_after INTEGER NOT NULL CHECK(armor_after BETWEEN 0 AND armor_before), newly_wrecked INTEGER NOT NULL CHECK(newly_wrecked IN (0,1)), cause TEXT NOT NULL CHECK(cause IN ('none','cored','ammo','scrap')), recovery_roll INTEGER, recovery_target INTEGER, compensation INTEGER NOT NULL CHECK(compensation>=0), lt_before INTEGER NOT NULL CHECK(lt_before>=0), mg_before INTEGER NOT NULL CHECK(mg_before>=0), lt_after INTEGER NOT NULL CHECK(lt_after>=0), mg_after INTEGER NOT NULL CHECK(mg_after>=0), lt_fired INTEGER NOT NULL CHECK(lt_fired>=0), mg_fired INTEGER NOT NULL CHECK(mg_fired>=0), lt_lost INTEGER NOT NULL CHECK(lt_lost>=0), mg_lost INTEGER NOT NULL CHECK(mg_lost>=0), PRIMARY KEY(cid,report_ord), FOREIGN KEY(cid,report_ord) REFERENCES battle_report(cid,ord) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,formation) REFERENCES artillery_formation(cid,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,hull) REFERENCES hull_instance(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK((target IS NOT NULL)=(fire!='not_fired')), CHECK((accuracy IS NOT NULL)=(fire!='not_fired')), CHECK((carrier_power IS NOT NULL)=(fire!='not_fired')), CHECK((enemy_before IS NULL)=(enemy_after IS NULL)), CHECK((recovery_roll IS NULL)=(recovery_target IS NULL)));
CREATE TABLE artillery_battle_seat (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, seat TEXT NOT NULL CHECK(seat IN ('commander','gunner','driver','loader')), person INTEGER CHECK(person BETWEEN 1 AND 4294967295), name TEXT NOT NULL, present INTEGER NOT NULL CHECK(present IN (0,1)), wound_severity INTEGER CHECK(wound_severity BETWEEN 1 AND 3), wound_location TEXT, wound_permanent INTEGER CHECK(wound_permanent IN (0,1)), fate TEXT NOT NULL CHECK(fate IN ('unhurt','kia','missing')), escape_roll INTEGER, escape_target INTEGER, xp INTEGER NOT NULL CHECK(xp IN (0,1)), PRIMARY KEY(cid,report_ord,seat), UNIQUE(cid,report_ord,person), FOREIGN KEY(cid,report_ord) REFERENCES artillery_battle(cid,report_ord) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(cid,person) REFERENCES person(cid,id) DEFERRABLE INITIALLY DEFERRED, CHECK((wound_severity IS NULL)=(wound_location IS NULL)), CHECK((wound_severity IS NULL)=(wound_permanent IS NULL)), CHECK((escape_roll IS NULL)=(escape_target IS NULL)));
CREATE TABLE artillery_battle_slot (cid INTEGER NOT NULL, report_ord INTEGER NOT NULL, slot TEXT NOT NULL, before_condition TEXT NOT NULL CHECK(before_condition IN ('ok','damaged','destroyed','missing')), after_condition TEXT NOT NULL CHECK(after_condition IN ('ok','damaged','destroyed','missing')), before_rounds INTEGER CHECK(before_rounds>=0), after_rounds INTEGER CHECK(after_rounds>=0), PRIMARY KEY(cid,report_ord,slot), FOREIGN KEY(cid,report_ord) REFERENCES artillery_battle(cid,report_ord) DEFERRABLE INITIALLY DEFERRED);
CREATE INDEX IF NOT EXISTS ix_artillery_battle_report ON artillery_battle(cid,report_ord);
CREATE INDEX IF NOT EXISTS ix_artillery_battle_seat_report ON artillery_battle_seat(cid,report_ord);
CREATE INDEX IF NOT EXISTS ix_artillery_battle_slot_report ON artillery_battle_slot(cid,report_ord);
