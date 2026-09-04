-- BattleTech Mercenary Command — SQLite campaign save schema (design document)
--
-- NOTE (Stage 11): the executable DDL lives in src/persist/store.zig. It
-- follows this design with one structural difference: one store file holds
-- MANY campaigns, so every table there carries a `cid` (campaign id) and a
-- `campaign` registry table lists playthroughs. This file remains the
-- readable reference for what each table means.
--
-- MekHQ persists campaigns as gzipped XML (.cpnx.gz); this schema is our
-- relational re-design of its object model plus our extensions (companies as
-- deployable objects, HQ network, shipments). One database file per campaign.
--
-- Conventions:
--   * All money is INTEGER C-bills. No floats in the ledger.
--   * All dates are INTEGER days since campaign epoch (day 0 = campaign start);
--     the calendar date lives in campaign.start_date.
--   * Static game data (chassis, part catalog, planets, tables) ships in data/
--     .zon files; saves reference it by stable TEXT keys (e.g. chassis_key).
--     Campaign-created custom variants are the exception: they live here.

PRAGMA foreign_keys = ON;

CREATE TABLE meta (
    schema_version  INTEGER NOT NULL,
    game_version    TEXT    NOT NULL,
    rng_state       BLOB    NOT NULL,          -- serialized RNG streams
    saved_at        TEXT    NOT NULL           -- wall-clock, informational only
);

CREATE TABLE campaign (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    name            TEXT    NOT NULL,
    start_date      TEXT    NOT NULL,          -- ISO date, e.g. '3025-01-01'
    current_day     INTEGER NOT NULL,          -- days since start
    funds           INTEGER NOT NULL,          -- outfit-level cash, C-bills
    reputation      INTEGER NOT NULL,          -- CamOps-style reputation score
    faction_key     TEXT    NOT NULL DEFAULT 'MERC'
);

---------------------------------------------------------------- organization

CREATE TABLE hq (
    id              INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    tier            TEXT    NOT NULL CHECK (tier IN ('brigade','regional','field')),
    planet_key      TEXT    NOT NULL,
    monthly_upkeep  INTEGER NOT NULL DEFAULT 0,
    funds           INTEGER NOT NULL DEFAULT 0,     -- HQ treasury (Stage 9A)
    -- Derived caches, recomputed on load (source of truth: tier + facilities;
    -- formulas in src/domain/hq.zig / ARCH §9.2, §9.4):
    influence_ly    INTEGER NOT NULL DEFAULT 0,
    staff_required  INTEGER NOT NULL DEFAULT 0
    -- staff assigned = COUNT(person WHERE hq_id = id AND status = 'active')
);

-- Supply-line edge in the HQ network graph (ARCH §9.5). Undirected; store
-- with hq_a < hq_b.
CREATE TABLE hq_link (
    id              INTEGER PRIMARY KEY,
    hq_a            INTEGER NOT NULL REFERENCES hq(id),
    hq_b            INTEGER NOT NULL REFERENCES hq(id),
    level           INTEGER NOT NULL DEFAULT 1,      -- 1 charter, 2 scheduled, 3+ dedicated jumpship
    throughput_week INTEGER NOT NULL,                -- supply units/week cap
    established_day INTEGER NOT NULL,
    monthly_cost    INTEGER NOT NULL DEFAULT 0,
    UNIQUE (hq_a, hq_b),
    CHECK (hq_a < hq_b)
);

-- HQ founding / facility upgrade projects: paperwork phase, then
-- construction (ARCH §9.4). Completed rows are kept as history.
CREATE TABLE hq_project (
    id                    INTEGER PRIMARY KEY,
    hq_id                 INTEGER NOT NULL REFERENCES hq(id),
    kind                  TEXT    NOT NULL CHECK (kind IN ('found','tier_upgrade','facility_upgrade')),
    facility              TEXT,                      -- null for found/tier_upgrade
    target_level          INTEGER,
    started_day           INTEGER NOT NULL,
    paperwork_done_day    INTEGER NOT NULL,
    construction_done_day INTEGER NOT NULL,
    cost                  INTEGER NOT NULL
);

CREATE TABLE hq_facility (
    hq_id           INTEGER NOT NULL REFERENCES hq(id),
    kind            TEXT    NOT NULL CHECK (kind IN
                     ('mek_bay','warehouse','hospital','mess','training_ground',
                      'hiring_hall','comms','spaceport')),
    level           INTEGER NOT NULL DEFAULT 1,      -- 1..5; gates refit class, stock depth, etc.
    PRIMARY KEY (hq_id, kind)
);

-- TO&E tree: outfit -> battalion -> company -> lance. Companies are the unit
-- of contract assignment; lances are the unit of battle resolution.
CREATE TABLE force (
    id              INTEGER PRIMARY KEY,
    parent_id       INTEGER REFERENCES force(id),
    name            TEXT    NOT NULL,
    echelon         TEXT    NOT NULL CHECK (echelon IN
                     ('outfit','battalion','company','support_company',
                      'air_company','lance','air_lance','support_lance')),
    support_kind    TEXT    CHECK (support_kind IN
                     ('mash','security','mess','salvage','transport')),
                                                     -- non-null iff echelon = support_lance
    commander_id    INTEGER,                         -- person id, FK added below via trigger-free convention
    hq_id           INTEGER REFERENCES hq(id),       -- supplying HQ for companies
    -- Player-set identity (ARCH §9.8): emblem is an image blob (png/jpg),
    -- shown on rosters/AARs. Name column above is player-editable.
    emblem          BLOB,
    -- Local operating funds for deployed companies (ARCH §9.8): field
    -- purchases draw only from this; topped up by costed transfers.
    local_funds     INTEGER NOT NULL DEFAULT 0,
    -- Rotation tracking for companies (ARCH §9.7): fatigue accrues per
    -- contract completed without returning to a regional HQ.
    last_rotation_day        INTEGER,
    contracts_since_rotation INTEGER NOT NULL DEFAULT 0
);

-- Skill training programs: XP is earned anywhere, but converting it into
-- skill levels happens only at a regional/brigade HQ with a training ground
-- (ARCH §9.7).
CREATE TABLE training_assignment (
    id              INTEGER PRIMARY KEY,
    person_id       INTEGER NOT NULL REFERENCES person(id),
    hq_id           INTEGER NOT NULL REFERENCES hq(id),
    skill           TEXT    NOT NULL,                -- person_skill.skill key
    started_day     INTEGER NOT NULL,
    done_day        INTEGER NOT NULL,
    xp_cost         INTEGER NOT NULL
);

---------------------------------------------------------------- personnel

CREATE TABLE person (
    id              INTEGER PRIMARY KEY,
    first_name      TEXT    NOT NULL,
    last_name       TEXT    NOT NULL,
    callsign        TEXT,
    origin_key      TEXT,                            -- planet/faction of origin
    birth_day       INTEGER,                         -- negative = before campaign start
    recruited_day   INTEGER NOT NULL,
    primary_role    TEXT    NOT NULL CHECK (primary_role IN
                     ('mekwarrior','vehicle_crew','aero_pilot','ba_trooper','infantry',
                      'tech_mek','tech_mechanic','tech_aero','tech_ba','astech',
                      'doctor','medic','admin_command','admin_logistics',
                      'admin_transport','admin_hr','admin_finance',
                      'dropship_crew','jumpship_crew')),
    secondary_role  TEXT,
    rank_key        TEXT    NOT NULL DEFAULT 'recruit',
    xp              INTEGER NOT NULL DEFAULT 0,
    salary_override INTEGER,                         -- null = CamOps table
    status          TEXT    NOT NULL DEFAULT 'active' CHECK (status IN
                     ('active','wounded','mia','kia','retired','resigned','pow')),
    fatigue         INTEGER NOT NULL DEFAULT 0,
    morale          INTEGER NOT NULL DEFAULT 50,
    force_id        INTEGER REFERENCES force(id),    -- staff posting (techs/admins/doctors)
    hq_id           INTEGER REFERENCES hq(id),       -- or HQ posting
    -- Stage 9C.2: medbay & leave
    medbay_priority INTEGER NOT NULL DEFAULT 0,      -- higher heals first when beds/doctors are short
    leave_until_day INTEGER,                         -- R&R: unavailable, double fatigue decay
    weekly_hours    INTEGER NOT NULL DEFAULT 40      -- tech time budget (techs only)
);

CREATE TABLE person_skill (
    person_id       INTEGER NOT NULL REFERENCES person(id),
    skill           TEXT    NOT NULL,                -- 'gunnery_mek','piloting_mek','tech_mek',
                                                     -- 'doctor','admin','tactics','leadership',...
    level           INTEGER NOT NULL,                -- MekHQ convention: lower target = better
    bonus           INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (person_id, skill)
);

CREATE TABLE injury (
    id              INTEGER PRIMARY KEY,
    person_id       INTEGER NOT NULL REFERENCES person(id),
    location        TEXT    NOT NULL,                -- 'head','torso','left_arm',...
    severity        INTEGER NOT NULL,
    incurred_day    INTEGER NOT NULL,
    heal_done_day   INTEGER,                         -- null until doctor assigned
    doctor_id       INTEGER REFERENCES person(id),
    permanent       INTEGER NOT NULL DEFAULT 0
);

---------------------------------------------------------------- materiel

-- Campaign-local chassis rows exist only for custom/refit variants; stock
-- variants resolve from data/ by chassis_key.
CREATE TABLE custom_chassis (
    chassis_key     TEXT    PRIMARY KEY,             -- e.g. 'SHD-2H-JohnnyK'
    base_key        TEXT    NOT NULL,                -- stock variant it derives from
    spec_zon        TEXT    NOT NULL                 -- full loadout, zon-encoded
);

CREATE TABLE unit (
    id              INTEGER PRIMARY KEY,
    chassis_key     TEXT    NOT NULL,
    name            TEXT,                            -- nickname, e.g. 'Old Reliable'
    kind            TEXT    NOT NULL CHECK (kind IN
                     ('mek','vehicle','aerospace','battle_armor','infantry',
                      'mash','mobile_field_base','cargo','dropship','jumpship')),
    force_id        INTEGER REFERENCES force(id),
    armor_pct       INTEGER NOT NULL DEFAULT 100,
    quality         TEXT    NOT NULL DEFAULT 'C' CHECK (quality IN ('A','B','C','D','E','F')),
    status          TEXT    NOT NULL DEFAULT 'ready' CHECK (status IN
                     ('ready','damaged','repairing','refitting','mothballed','destroyed','in_transit')),
    last_maint_day  INTEGER,
    acquired_day    INTEGER NOT NULL,
    purchase_price  INTEGER NOT NULL DEFAULT 0
);

-- Crew AND tech slots (Stage 9C.2): a hull with no 'tech' slot filled gets
-- no maintenance, repairs, or reloads; no 'pilot'/'driver' → it doesn't
-- fight. One person holds at most one slot; a tech may hold 'tech' on
-- several hulls within their weekly hours.
CREATE TABLE unit_crew (
    unit_id         INTEGER NOT NULL REFERENCES unit(id),
    person_id       INTEGER NOT NULL REFERENCES person(id),
    slot            TEXT    NOT NULL DEFAULT 'pilot' CHECK (slot IN
                     ('pilot','driver','gunner','crew','leader','tech')),
    PRIMARY KEY (unit_id, person_id)
);

-- Hiring hall candidates (Stage 9C.2): generated weekly per HQ by hiring
-- hall level + HR staff; hired by the player or expire.
CREATE TABLE hiring_candidate (
    id              INTEGER PRIMARY KEY,
    hq_id           INTEGER NOT NULL REFERENCES hq(id),
    role            TEXT    NOT NULL,
    experience      TEXT    NOT NULL CHECK (experience IN ('green','regular','veteran','elite')),
    asking_bonus    INTEGER NOT NULL DEFAULT 0,
    listed_day      INTEGER NOT NULL,
    expires_day     INTEGER NOT NULL
);

-- Damaged/destroyed/missing slots on a unit; repair work queue derives from
-- this. slot_class decides the repair echelon (ARCH §9.7): armor/weapon/
-- equipment/ammo are field-repairable by company techs given parts;
-- structure requires a regional/brigade HQ mek bay over bay time.
CREATE TABLE unit_part_state (
    unit_id         INTEGER NOT NULL REFERENCES unit(id),
    slot_key        TEXT    NOT NULL,                -- e.g. 'right_torso.medium_laser.1'
    part_key        TEXT    NOT NULL,                -- catalog key of installed/needed part
    slot_class      TEXT    NOT NULL DEFAULT 'equipment' CHECK (slot_class IN
                     ('armor','structure','weapon','equipment','ammo')),
    condition       TEXT    NOT NULL CHECK (condition IN ('ok','damaged','destroyed','missing')),
    PRIMARY KEY (unit_id, slot_key)
);

-- Depot work queue: structural repairs & rebuilds occupying a mek bay.
CREATE TABLE depot_repair_job (
    id              INTEGER PRIMARY KEY,
    unit_id         INTEGER NOT NULL REFERENCES unit(id),
    hq_id           INTEGER NOT NULL REFERENCES hq(id),
    started_day     INTEGER NOT NULL,
    done_day        INTEGER NOT NULL,
    cost            INTEGER NOT NULL
);

-- Physical stocks per site (Stage 9B): spare parts, per-location structural
-- components (comp_arm/leg/torso/head/ct), munition family pools
-- (ammo_ac5/ac20/lrm/srm/mg), provisions, medical supplies. Tonnage derives
-- from the catalog's pallet_tons column (data/parts.zon); HQ storage
-- capacity derives from the warehouse level; a deployed company's cap
-- derives from its logistics lance's truck tonnage.
CREATE TABLE inventory (
    owner_kind      TEXT    NOT NULL CHECK (owner_kind IN ('hq','company')),
    owner_id        INTEGER NOT NULL,                -- hq.id or force.id (company)
    part_key        TEXT    NOT NULL,                -- catalog key (part/component/munition/supply)
    quantity        INTEGER NOT NULL,
    PRIMARY KEY (owner_kind, owner_id, part_key)
);

CREATE TABLE acquisition_order (
    id              INTEGER PRIMARY KEY,
    part_key        TEXT    NOT NULL,
    quantity        INTEGER NOT NULL,
    dest_kind       TEXT    NOT NULL,
    dest_id         INTEGER NOT NULL,
    ordered_day     INTEGER NOT NULL,
    eta_day         INTEGER,                         -- null while sourcing roll pending
    cost            INTEGER NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'sourcing' CHECK (status IN
                     ('sourcing','in_transit','delivered','failed','cancelled'))
);

-- Money moves by courier (Stage 9A): outfit <-> HQ <-> deployed company.
-- Entity addressing: kind+id ('outfit' uses id 0).
CREATE TABLE fund_transfer (
    id              INTEGER PRIMARY KEY,
    from_kind       TEXT    NOT NULL CHECK (from_kind IN ('outfit','hq','company')),
    from_id         INTEGER NOT NULL DEFAULT 0,
    to_kind         TEXT    NOT NULL CHECK (to_kind IN ('outfit','hq','company')),
    to_id           INTEGER NOT NULL DEFAULT 0,
    amount          INTEGER NOT NULL,
    sent_day        INTEGER NOT NULL,
    eta_day         INTEGER NOT NULL,                -- courier delay from map distance, min 3
    delivered       INTEGER NOT NULL DEFAULT 0       -- bool
);

-- Standing money policies (Stage 9A), executed on payday via fund_transfer.
CREATE TABLE standing_policy (
    id              INTEGER PRIMARY KEY,
    entity_kind     TEXT    NOT NULL CHECK (entity_kind IN ('hq','company')),
    entity_id       INTEGER NOT NULL,
    floor_amount    INTEGER NOT NULL,                -- top up to this level
    monthly_cap     INTEGER NOT NULL                 -- max moved per month
);

-- Mek bay work queue (Stage 9C): repairs, reactivations, fabrication,
-- refits occupy bay slots (mek_bay level x 2) for a span of days.
CREATE TABLE bay_job (
    id              INTEGER PRIMARY KEY,
    hq_id           INTEGER NOT NULL REFERENCES hq(id),
    unit_id         INTEGER REFERENCES unit(id),     -- null for fabrication jobs
    kind            TEXT    NOT NULL CHECK (kind IN
                     ('depot_repair','reactivation','fabrication','refit')),
    item_key        TEXT,                            -- component being fabricated
    queued_day      INTEGER NOT NULL,
    started_day     INTEGER,                         -- null while waiting for a slot
    done_day        INTEGER,
    cost            INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE shipment (
    id              INTEGER PRIMARY KEY,
    origin_hq_id    INTEGER NOT NULL REFERENCES hq(id),
    dest_force_id   INTEGER NOT NULL REFERENCES force(id),  -- deployed company
    supply_class    TEXT    NOT NULL CHECK (supply_class IN ('parts','ammo','medical','provisions','personnel')),
    quantity        INTEGER NOT NULL,
    depart_day      INTEGER NOT NULL,
    eta_day         INTEGER NOT NULL,
    freight_cost    INTEGER NOT NULL
);

-- Site markets (ARCH §9.8): a market is a place — at an HQ or on a contract
-- planet. Listings appear per rarity roll at each refresh.
CREATE TABLE market (
    id              INTEGER PRIMARY KEY,
    site_kind       TEXT    NOT NULL CHECK (site_kind IN
                     ('regional_hq','field_hq','contract_planet')),
    hq_id           INTEGER REFERENCES hq(id),       -- set for HQ markets
    planet_key      TEXT    NOT NULL,
    next_refresh_day INTEGER NOT NULL
);

-- Listings persist until bought or aged out (Stage 9C.3): hulls linger for
-- months, people churn daily (see hiring_candidate). Staple parts are
-- always present; rare slots may hold components/heavy gear this month.
CREATE TABLE market_listing (
    id              INTEGER PRIMARY KEY,
    market_id       INTEGER NOT NULL REFERENCES market(id),
    kind            TEXT    NOT NULL CHECK (kind IN ('unit','part')),
    item_key        TEXT    NOT NULL,                -- chassis_key or part_key
    rarity          TEXT    NOT NULL CHECK (rarity IN
                     ('common','uncommon','rare','very_rare')),
    staple          INTEGER NOT NULL DEFAULT 0,      -- bool: always-stocked part line
    quantity        INTEGER NOT NULL DEFAULT 1,
    price           INTEGER NOT NULL,                -- for units: loadout value x condition
    listed_day      INTEGER NOT NULL,
    expires_day     INTEGER NOT NULL,
    -- Condition of a listed hull (units only): what you'd be buying.
    armor_pct       INTEGER,
    quality         TEXT    CHECK (quality IN ('A','B','C','D','E','F')),
    damaged_slots   INTEGER NOT NULL DEFAULT 0,
    destroyed_slots INTEGER NOT NULL DEFAULT 0,
    missing_components TEXT                          -- comma-separated component keys absent
);

-- Cold storage & reactivation (ARCH §9.8): mothballed units live in unit.status;
-- a non-null reactivation row means a tech crew is waking the hull up.
CREATE TABLE reactivation_job (
    id              INTEGER PRIMARY KEY,
    unit_id         INTEGER NOT NULL REFERENCES unit(id),
    hq_id           INTEGER NOT NULL REFERENCES hq(id),
    started_day     INTEGER NOT NULL,
    done_day        INTEGER NOT NULL
);

CREATE TABLE refit_job (
    id              INTEGER PRIMARY KEY,
    unit_id         INTEGER NOT NULL REFERENCES unit(id),
    target_chassis_key TEXT NOT NULL,
    refit_class     TEXT    NOT NULL CHECK (refit_class IN ('A','B','C','D','E','F')),
    started_day     INTEGER NOT NULL,
    done_day        INTEGER NOT NULL,
    tech_id         INTEGER REFERENCES person(id)
);

---------------------------------------------------------------- contracts

CREATE TABLE contract (
    id              INTEGER PRIMARY KEY,
    kind            TEXT    NOT NULL CHECK (kind IN
                     ('garrison_duty','cadre_duty','security_duty','riot_duty',
                      'planetary_assault','relief_duty','guerrilla_warfare',
                      'pirate_hunting','diversionary_raid','objective_raid',
                      'recon_raid','extraction_raid')),
    employer_key    TEXT    NOT NULL,
    enemy_key       TEXT    NOT NULL,
    planet_key      TEXT    NOT NULL,
    company_id      INTEGER REFERENCES force(id),    -- assigned company, null = offer
    status          TEXT    NOT NULL DEFAULT 'offer' CHECK (status IN
                     ('offer','accepted','transit','active','completed','breached','failed')),
    start_day       INTEGER,
    length_months   INTEGER NOT NULL,
    -- CamOps terms
    base_pay_month  INTEGER NOT NULL,
    advance_pct     INTEGER NOT NULL DEFAULT 25,
    signing_bonus   INTEGER NOT NULL DEFAULT 0,
    transport_pct   INTEGER NOT NULL DEFAULT 0,
    overhead_pct    INTEGER NOT NULL DEFAULT 0,      -- straight support / overhead comp
    battle_loss_pct INTEGER NOT NULL DEFAULT 0,
    salvage_pct     INTEGER NOT NULL DEFAULT 0,
    salvage_exchange INTEGER NOT NULL DEFAULT 0,     -- bool
    command_rights  TEXT    NOT NULL DEFAULT 'independent' CHECK (command_rights IN
                     ('integrated','house','liaison','independent')),
    score           INTEGER NOT NULL DEFAULT 0,      -- running success score
    -- Influence context at offer time (ARCH §9.2/§9.6):
    dist_ly         INTEGER NOT NULL DEFAULT 0,      -- distance from nearest own HQ
    beachhead       INTEGER NOT NULL DEFAULT 0,      -- bool: in the beachhead band when offered
    -- Victory model (Stage 9E, ARCH §7):
    objective_kind  TEXT    NOT NULL DEFAULT 'duration' CHECK (objective_kind IN
                     ('duration','attrition')),
    enemy_pool_bv   INTEGER NOT NULL DEFAULT 0,      -- opposition force, depleted by battles
    victory_points  INTEGER NOT NULL DEFAULT 0,
    -- Breach bookkeeping (Stage 9E): clawback owed if breached, cooling
    -- applied to the employer faction on failure.
    breach_day      INTEGER
);

CREATE TABLE scenario (
    id              INTEGER PRIMARY KEY,
    contract_id     INTEGER NOT NULL REFERENCES contract(id),
    kind            TEXT    NOT NULL,                -- 'base_defense','ambush','recon','extraction',...
    due_day         INTEGER NOT NULL,
    resolved_day    INTEGER,
    outcome         TEXT,                            -- 'decisive_victory'..'rout', null = pending
    aar             TEXT                             -- narrated after-action report
);

CREATE TABLE contract_event (
    id              INTEGER PRIMARY KEY,
    contract_id     INTEGER NOT NULL REFERENCES contract(id),
    day             INTEGER NOT NULL,
    kind            TEXT    NOT NULL,
    decision_json   TEXT,                            -- pending decision payload, null = auto
    resolution      TEXT
);

---------------------------------------------------------------- finances

CREATE TABLE txn (
    id              INTEGER PRIMARY KEY,
    day             INTEGER NOT NULL,
    amount          INTEGER NOT NULL,                -- signed C-bills
    category        TEXT    NOT NULL CHECK (category IN
                     ('contract_payment','advance','salvage','battle_loss_comp',
                      'payroll','hardship_pay','maintenance','hull_upkeep',
                      'parts','supplies','local_supplies','freight',
                      'unit_purchase','unit_sale','fabrication',
                      'fund_transfer','hq_construction','hq_upkeep',
                      'transport_charter','loan_principal','loan_interest',
                      'breach_clawback','event','misc')),
    company_id      INTEGER REFERENCES force(id),    -- cost/profit center, null = outfit-level
    hq_id           INTEGER REFERENCES hq(id),       -- HQ cost center (Stage 9A)
    contract_id     INTEGER REFERENCES contract(id),
    note            TEXT
);

CREATE TABLE loan (
    id              INTEGER PRIMARY KEY,
    principal       INTEGER NOT NULL,
    balance         INTEGER NOT NULL,
    rate_bp         INTEGER NOT NULL,                -- basis points, integer math
    term_months     INTEGER NOT NULL,
    next_pay_day    INTEGER NOT NULL,
    payment         INTEGER NOT NULL
);

---------------------------------------------------------------- log

-- Structured campaign log (Stage 9A): every entry tagged so any entity's
-- full history — battles, decisions & outcomes, deliveries, construction,
-- medical, finance — is a WHERE clause.
CREATE TABLE event_log (
    id              INTEGER PRIMARY KEY,
    day             INTEGER NOT NULL,
    category        TEXT    NOT NULL CHECK (category IN
                     ('battle','decision','delivery','contract','medical',
                      'training','rotation','finance','construction','market','misc')),
    company_id      INTEGER REFERENCES force(id),
    hq_id           INTEGER REFERENCES hq(id),
    contract_id     INTEGER REFERENCES contract(id),
    message         TEXT    NOT NULL
);
CREATE INDEX idx_log_company   ON event_log(company_id, day);
CREATE INDEX idx_log_category  ON event_log(category, day);

CREATE INDEX idx_txn_day        ON txn(day);
CREATE INDEX idx_txn_company    ON txn(company_id, day);
CREATE INDEX idx_person_force   ON person(force_id);
CREATE INDEX idx_unit_force     ON unit(force_id);
CREATE INDEX idx_scenario_due   ON scenario(contract_id, due_day);
CREATE INDEX idx_log_day        ON event_log(day);
