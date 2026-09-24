-- IRON LEDGER — SQLite save store schema (design document)
--
-- Matches schema_version 33. The executable DDL and its column migrations
-- live in src/persist/store.zig; this file is the readable reference for
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
--   * No foreign keys are declared. "-> table.id" in a comment names the
--     relationship; the loader is the integrity check and rejects a save
--     whose rows do not resolve.

---------------------------------------------------------------- store

CREATE TABLE player (
    id              INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL UNIQUE,
    created_seq     INTEGER NOT NULL                 -- lobby order
);

-- Store-wide integer settings: schema_version, and the client's music,
-- music_volume and music_set.
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
    schema_version  INTEGER NOT NULL,                -- version that wrote it; newer than the game refuses to load
    save_seq        INTEGER NOT NULL,                -- store-wide save counter, orders "most recent"
    player_id       INTEGER NOT NULL DEFAULT 0       -- -> player.id; 0 = none
);

---------------------------------------------------------------- campaign scalars

-- Integer scalars by key: day_index, year, month, day, funds, reputation,
-- bankrupt, auto_admit, difficulty, share_profit_bp, the stat_* counters
-- (battles won/drawn/lost, hulls lost/salvaged, people_kia, enemy_bv),
-- next_person_id, next_unit_id, next_force_id, next_hq_id,
-- next_contract_id, next_battle_id, rng_seed.
CREATE TABLE meta (
    cid             INTEGER NOT NULL,
    key             TEXT    NOT NULL,
    value           INTEGER NOT NULL,
    PRIMARY KEY (cid, key)
);

-- Text scalars by key: outfit_name.
CREATE TABLE meta_text (
    cid             INTEGER NOT NULL,
    key             TEXT    NOT NULL,
    value           TEXT    NOT NULL,
    PRIMARY KEY (cid, key)
);

-- One row per named RNG stream (sim/rng.zig Stream). A stream with no row
-- starts fresh from meta rng_seed, so adding a stream never reseeds the
-- others. A malformed row or unknown stream name is a corrupt save.
CREATE TABLE rng_stream (
    cid             INTEGER NOT NULL,
    stream          TEXT    NOT NULL,                -- 'generation','market','battle',...
    format          INTEGER NOT NULL,                -- 1: four u64 words, little-endian
    state           BLOB    NOT NULL,                -- 32 bytes in format 1
    UNIQUE (cid, stream)
);

-- Single-blob RNG state of older saves: every stream's native-endian state
-- in a fixed order. Read only when a campaign has no rng_stream rows;
-- saving writes none.
CREATE TABLE rng (
    cid             INTEGER PRIMARY KEY,
    state           BLOB    NOT NULL
);

-- The player character.
CREATE TABLE commander (
    cid             INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    origin          TEXT    NOT NULL,                -- commander.Faction
    profession      TEXT    NOT NULL                 -- commander.Profession
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
    admitted        INTEGER NOT NULL DEFAULT 0,      -- bool: in the medbay
    rank            TEXT    NOT NULL DEFAULT 'private', -- rank.Rank
    rank_pinned     INTEGER NOT NULL DEFAULT 0,      -- bool: rank set by hand, not by merit
    kills           INTEGER NOT NULL DEFAULT 0,
    kill_bv         INTEGER NOT NULL DEFAULT 0,
    battles         INTEGER NOT NULL DEFAULT 0,
    tours           INTEGER NOT NULL DEFAULT 0,
    outstanding_tours INTEGER NOT NULL DEFAULT 0,
    edge_spent      INTEGER NOT NULL DEFAULT 0,      -- bool
    faction         TEXT    NOT NULL DEFAULT '',     -- faction of origin
    shares          INTEGER NOT NULL DEFAULT 0,
    born_day        INTEGER,                         -- negative = before campaign start
    last_raise_day  INTEGER,
    last_award_day  INTEGER,
    departed_day    INTEGER,                         -- set once they leave the outfit
    PRIMARY KEY (cid, id)
);

CREATE TABLE award (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    key             TEXT    NOT NULL                 -- data/tables/awards.zon key
);

CREATE TABLE ability (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    key             TEXT    NOT NULL                 -- data/tables/abilities.zon key
);

CREATE TABLE person_skill (
    cid             INTEGER NOT NULL,
    person_id       INTEGER NOT NULL,                -- -> person.id
    skill           TEXT    NOT NULL,                -- types.SkillType
    level           INTEGER NOT NULL                 -- MekHQ convention: lower target = better
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
    permanent       INTEGER NOT NULL DEFAULT 0,      -- bool
    healed          INTEGER NOT NULL DEFAULT 0       -- bool
);

-- Hiring-hall candidates: generated per HQ, hired with a signing bonus or
-- expire.
CREATE TABLE candidate (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
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
    expires         INTEGER                          -- day
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
    PRIMARY KEY (cid, id)
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
    condition       TEXT                             -- unit.PartCondition: ok | damaged | destroyed | missing
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
    qty             INTEGER NOT NULL
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
    status          TEXT                             -- part.OrderStatus: sourcing | in_transit | delivered | failed | cancelled
);

-- Mek bay work: jobs hold a bay slot for a span of days and queue when the
-- bays are full.
CREATE TABLE bay_job (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    hq              INTEGER,                         -- -> hq.id
    kind            TEXT,                            -- depot_repair | reactivation | fabrication | refit
    unit            INTEGER,                         -- -> unit.id; 0 for fabrication
    item_key        TEXT,                            -- component being fabricated
    duration        INTEGER,                         -- days
    queued          INTEGER,                         -- day
    started         INTEGER,                         -- day; null while waiting for a slot
    done            INTEGER,                         -- day
    cost            INTEGER                          -- labor posted to the HQ at completion
);

-- MekLab refit plans: edits staged against a hull, committed into a bay job.
CREATE TABLE refit_plan (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    unit            INTEGER,                         -- -> unit.id
    committed       INTEGER                          -- bool
);

CREATE TABLE refit_op (
    cid             INTEGER NOT NULL,
    plan_ord        INTEGER NOT NULL,                -- -> refit_plan.ord
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- 'remove' | 'install'
    slot_key        TEXT,                            -- remove: the slot emptied
    location        TEXT,                            -- install: where
    part_key        TEXT                             -- install: what
);

-- A hull on its way to another company.
CREATE TABLE unit_transfer (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    unit            INTEGER,                         -- -> unit.id
    to_company      INTEGER,                         -- -> force.id
    eta             INTEGER                          -- day
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
    PRIMARY KEY (cid, id)
);

CREATE TABLE force_unit (
    cid             INTEGER NOT NULL,
    force_id        INTEGER NOT NULL,                -- -> force.id
    ord             INTEGER NOT NULL,
    unit_id         INTEGER NOT NULL                 -- -> unit.id
);

CREATE TABLE force_child (
    cid             INTEGER NOT NULL,
    force_id        INTEGER NOT NULL,                -- -> force.id
    ord             INTEGER NOT NULL,
    child_id        INTEGER NOT NULL                 -- -> force.id
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
    PRIMARY KEY (cid, id)
);

CREATE TABLE hq_facility (
    cid             INTEGER NOT NULL,
    hq_id           INTEGER NOT NULL,                -- -> hq.id
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- hq.FacilityKind
    level           INTEGER
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
    cost            INTEGER
);

-- Supply-line edge in the HQ network graph.
CREATE TABLE hq_link (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    a               INTEGER,                         -- -> hq.id
    b               INTEGER,                         -- -> hq.id
    level           INTEGER,
    tons            INTEGER,                         -- tonnage moved this week
    established     INTEGER                          -- day
);

---------------------------------------------------------------- contracts

-- Contracts and the current offers (is_offer = 1) share this table.
CREATE TABLE contract (
    cid             INTEGER NOT NULL,
    is_offer        INTEGER NOT NULL,                -- bool
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
    salvage_exchange INTEGER,                        -- bool
    command_rights  TEXT,                            -- contract.CommandRights
    negotiated      INTEGER NOT NULL DEFAULT 0,      -- bool: terms already negotiated
    -- The opposing force as briefed
    enemy_lances    INTEGER NOT NULL DEFAULT 0,
    enemy_quality   TEXT    NOT NULL DEFAULT 'regular', -- types.ExperienceLevel
    enemy_lance_bv  INTEGER NOT NULL DEFAULT 0,
    enemy_lance_tons INTEGER NOT NULL DEFAULT 0,
    offer_hq        INTEGER NOT NULL DEFAULT 0,      -- -> hq.id whose board carries the offer
    orders_day      INTEGER                          -- engagement day battle orders were confirmed for;
                                                     -- the contact warning stands until it equals next_battle
);

-- Employers cooling on the outfit after a failure.
CREATE TABLE faction_cooling (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    faction         TEXT,
    until_day       INTEGER
);

-- Standing with each faction; an absent row reads as 0.
CREATE TABLE faction_standing (
    cid             INTEGER NOT NULL,
    faction         TEXT    NOT NULL,
    value           INTEGER NOT NULL
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
    note            TEXT
);

CREATE TABLE loan (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    principal       INTEGER,
    balance         INTEGER,
    rate_bp         INTEGER,                         -- basis points
    term            INTEGER,                         -- months
    next_pay        INTEGER,                         -- day
    payment         INTEGER
);

-- Money in transit by courier to a treasury.
CREATE TABLE courier (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    to_kind         TEXT,                            -- 'outfit' | 'hq' | 'company'
    to_id           INTEGER,                         -- 0 for outfit
    amount          INTEGER,
    sent            INTEGER,                         -- day
    eta             INTEGER                          -- day
);

-- Standing money policies, executed on payday by courier.
CREATE TABLE policy (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    entity_kind     TEXT,                            -- 'outfit' | 'hq' | 'company'
    entity_id       INTEGER,
    floor           INTEGER,                         -- top up to this level
    cap             INTEGER,                         -- max moved per month
    sent            INTEGER NOT NULL DEFAULT 0       -- moved so far this month
);

-- Standing supply orders for a deployed company.
CREATE TABLE supply_policy (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    company         INTEGER,                         -- -> force.id
    min_days        INTEGER,
    tons            INTEGER,
    ammo_battles    INTEGER NOT NULL DEFAULT 0
);

-- Standing restock orders for an HQ warehouse.
CREATE TABLE stock_policy (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    hq              INTEGER,                         -- -> hq.id
    part_key        TEXT,
    min_qty         INTEGER,
    target          INTEGER
);

-- Yearly company rating history.
CREATE TABLE rating_snapshot (
    cid             INTEGER NOT NULL,
    year            INTEGER NOT NULL,
    score           INTEGER NOT NULL
);

---------------------------------------------------------------- markets

-- A listing on an HQ's board; persists until bought or aged out.
CREATE TABLE listing (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    kind            TEXT,                            -- 'unit' | 'part'
    item_key        TEXT,                            -- chassis_key or part_key
    rarity          TEXT,                            -- types.Rarity
    price           INTEGER,
    qty             INTEGER,
    staple          INTEGER,                         -- bool: always-stocked part line
    listed          INTEGER,                         -- day
    expires         INTEGER,                         -- day
    hq              INTEGER,                         -- -> hq.id whose board this is
    -- Condition of a listed hull (units only; null for parts)
    c_armor         INTEGER,
    c_quality       TEXT,                            -- types.Quality
    c_damaged       INTEGER,                         -- damaged slots
    c_destroyed     INTEGER,                         -- destroyed slots
    c_missing       INTEGER,                         -- missing components
    black           INTEGER NOT NULL DEFAULT 0,      -- bool: black-market offer
    company         INTEGER NOT NULL DEFAULT 0       -- -> force.id: a contract-world hull for this deployed company
);

---------------------------------------------------------------- events

-- Structured campaign log: every entry tagged so any entity's history is a
-- WHERE clause.
CREATE TABLE event_log (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    day             INTEGER,
    category        TEXT,                            -- battle | decision | delivery | contract | medical |
                                                     -- training | rotation | finance | construction | market | misc
    company         INTEGER,                         -- -> force.id
    hq              INTEGER,                         -- -> hq.id
    contract        INTEGER,                         -- -> contract.id
    text            TEXT
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
    battle          INTEGER NOT NULL DEFAULT 0       -- BattleId the decision answers
);

-- One row per decision kind: when it last fired and how it was answered.
CREATE TABLE event_memory (
    cid             INTEGER NOT NULL,
    kind            TEXT    NOT NULL,                -- events.EventKind
    last_day        INTEGER NOT NULL,
    last_choice     INTEGER NOT NULL,
    streak          INTEGER NOT NULL                 -- times running the same answer was given
);

---------------------------------------------------------------- battles

-- Resolved engagements as records: what the after-action screens read. The
-- permanent account of a battle is its [AAR] lines in event_log, which are
-- never pruned; these are bounded by tuning.battle.reports_kept and age out
-- oldest-first.
CREATE TABLE battle_report (
    cid             INTEGER NOT NULL,
    ord             INTEGER NOT NULL,
    id              INTEGER,                         -- BattleId, campaign-unique (meta next_battle_id)
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
    acknowledged    INTEGER NOT NULL DEFAULT 1,      -- bool: the player has read it
    salvage_unclaimed INTEGER NOT NULL DEFAULT 0     -- BV of the haul still to be divided; 0 once taken
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
    lost            INTEGER                          -- bool: left to the enemy
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
    reserve         INTEGER
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
    missing         INTEGER                          -- missing components
);
