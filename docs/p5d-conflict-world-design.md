# P5d — Conflict-first world and NPC company operations: design and delivery order

**Status:** approved design for P5d.1a–p and P5d.4a–l; documentation only. No
behaviour, schema, data or test is implemented by this document.
**Prerequisites:** P3e/P3f merc companies, P4i actors and rivals, P5a stops and
digest, P5c situations and inbox — all on `main`.
**Replaces:** the earlier, unmerged P5d.1 direction (counter-hire at
acceptance, presence from the hire day). None of its content is carried
forward.
**Adaptation note:** BattleTech canon (people, titles, dates) enters only as
facts restated in project words from Sarna, never as copied prose (D8);
ARCHITECTURE.md "Licensing note" applies. Everything else here — scheme
templates, project characters, the NPC operating model and every number — is
project-authored. The game UI never says which is which (direction 4 of the
P5d.1d decisions below). Every new number is `// TUNE` with its unit
in its name (contract rules 24, 81).

The existing P5d.2, P5d.3 and P5d.5–P5d.7 entries keep their scope. This
document redistributes the P5d.1 and P5d.4 work into small increments in
dependency order (see "Increments"). Each increment is its own approved plan
and branch; each has one bounded outcome, named prerequisites and named
acceptance evidence.

## Product direction

1. Every mercenary company maintains its own roster.
2. A player contract is created from an underlying, employer-backed conflict
   before it is offered. Mercenaries do not fight random people: a Great House,
   minor house or other named power hires them.
3. Cadre and garrison are the exception. Their later threat may be a mercenary
   company or pirate organization that chooses to attack after the contract
   exists.
4. Opposition comes from conflict and narrative causality, not from
   post-acceptance counter-hiring.
5. A character and political-conflict model: at least a local governor or
   equivalent per planet, plus faction leaders, family, generals and other
   named actors, each with a grounded backstory, motives and machinations that
   can cause contracts. Canon comes from scoped Sarna research with exact
   pages, kept apart from project-created characters. The design scales to a
   corpus supporting a few thousand scenarios without authoring it all at once.
6. Political stories progress without the player. News surfaces within 100 ly
   of any player HQ or deployed company. Informational news is kept apart from
   decisions that need a modal.
7. NPC travel is modelled because it has a real cost. Timing is solved
   causally before an offer reaches the player:
   - a political conflict begins first, and its parties hire and dispatch
     mercenaries before a player-facing offer is posted;
   - no defensive contract is offered without a real looming or arriving
     threat; discovery, preparation and offer timing are explicit;
   - for player attacks and raids, the opposing force is built from the
     defender, its existing garrison/local forces and any merc companies
     already committed or committed later with a cause. The player taking an
     offensive contract never implies an NPC contract;
   - each merc company keeps its own roster and a named employer and mandate.
     Narrative cause, timeline, travel, readiness and offer visibility are
     coherent and deterministic.
8. Later coding work is split into small, tightly scoped, independently correct
   branches in dependency order.
9. NPC companies are run as companies: an operating base, maintenance and
   repair of damaged hulls, parts procurement, post-contract repair and
   recovery, loss replacement and market upgrades, asset sales and liquidation
   under cash pressure, solvency safeguards, and roster-band archetypes from
   1–2 skull through 5 skull with four fighting lances and earned, optional
   air/artillery growth. A company that can afford to recover does recover; no
   durable passive decay.
10. Intended eventual scale: at least a governor or local leader per planet,
    faction leaders, families and generals, several hundred named people and
    roughly a few thousand scenarios. Canon is restated in project words from
    read-only research done during planning; the game needs no external-source
    validation or citation, and no step depends on web access (John's
    directions for P5d.1d). No player-facing label, word, marker, filter,
    count or lookup says whether a character or company is generated,
    authored, canon or Sarna-derived.

## What exists today

Read at `main` 08a4894; line numbers are at that revision.

- **Offers have no cause.** `contract_market.refresh`
  (`src/sim/contract_market.zig` 104–224) clears the board (105). It then picks
  a uniform random world per attempt (128, `.market`), sets
  `employer_key = world.faction` (192), and takes `enemy_key` from `pickEnemy`
  (75–82). In `pickEnemy`, a garrison-class kind is PER half the time;
  otherwise it is a uniform pick from the employer's `foes`. Opposition size
  comes from `opfor.roll` (186) on `.market`. It runs only on the 1st of the
  month (`tick.runMarkets`, `src/sim/tick.zig` 554–566). Offers have no posted
  or close day.
- **Opposition is decided after acceptance.** At acceptance,
  `rivals.instantiateRivals` (`src/sim/rivals.zig` 222) draws a merc company
  from `mercCompanyEligibleAsOpFor` (111–124: active, solvent, mek target). The
  draw ignores the company's `faction_key` and `side`. `battle.opforPool`
  (`src/sim/battle.zig` 611) routes on it. This is the counter-hire that
  direction 4 rejects.
- **Merc companies.** `GameState.merc_company_rosters` (`src/sim/state.zig`
  384) maps a company to its hull instances. `MercCompany`
  (`src/domain/merc_company.zig` 18–41) has `archetype_key`, `commander_first`
  and `commander_last`, `unit_name`, `faction_key`, `side`, `doctrine`,
  `cbills`, `founded_day`, `dissolved_day` and `logo_key`. It has no location,
  commitment or income.
- **Player travel is the one travel rule.** `logistics.daysForJumps`
  (`src/econ/logistics.zig` 31) floors a zero-jump route to `same_world_days`
  (3). Any other route uses `transitDays` (18–21): `burn_days` (5) +
  (jumps − 1) × `recharge_days` (7) + `burn_days`. Jumps come from
  `planet.jumpsBetween` / `jumpsForLy` (`src/domain/planet.zig` 42–49), using
  `ly_per_jump` (30). The tuning values are in `data/tables/tuning.zon` 46–49.
  `contract_control.acceptContract` sets `transit_days` and `arrive_day`
  (`src/sim/contract_control.zig` 901–906). `tick.runContracts` activates a
  contract on arrival (`src/sim/tick.zig` 574–581). `queries.offerTransitDays`
  (`src/sim/queries.zig` 1044) shows the best player ETA on the board.
- **Quiet contracts.** `ContractKind.isGarrisonClass`
  (`src/domain/contract.zig` 45–50) covers garrison, cadre, security and riot.
  `battle.zig` 129 skips battles for a garrison-class contract without
  `hasOpfor`.
- **Named people exist only inside a contract** (`Actor` in
  `src/domain/actor.zig`, with `contract: ContractId`). No persistent ruler,
  leader or family exists.
- **Worlds.** `GameState.world_states` is keyed by planet. `data/planets.zon`
  has 234 rows. `data/tables/factions.zon` has 13 factions; 12 hire, and
  ComStar has `hires = false`. The campaign starts 3025-01-01
  (`src/domain/clock.zig` 12).
- **Visibility.** `market.visibilityFor` (`src/econ/market.zig` 35) gives
  `in_ring` / `beachhead` / `hidden` from distance and `Hq.influenceLy`.
- **Positions and inbox.** `queries.companyPlanetKey` (`src/sim/queries.zig`
  5966) is private. `posture.companyPosture` is in `src/sim/posture.zig` 22.
  The `EventQueue` decision inbox, the P5a stop owner (`checklist.zig`) and the
  digest exist and are reused.
- **RNG and schema.** The streams are in `src/sim/rng.zig` 9–20 (no
  `.politics`). `store.schema_version = 67` (`src/persist/store.zig` 55).
- **Licensing.** The repo is GPLv3. ARCHITECTURE.md "Licensing note" applies.

### NPC mercenary-company capability check

Scope of the search: `grep` for `merc_compan` / `MercCompany` over `src/`
lists exactly `domain/{hull_instance,merc_company,rival,tuning,types}.zig`,
`gen/roster_gen.zig`, `persist/store.zig`, `root.zig`,
`sim/{artillery,battle_prepared_storage,battle,black_market,campaign_backup,merc_lifecycle,queries,rivals,roster_seed,state}.zig`
and `tui/app.zig`. "Absent" below means not represented in those files or in
the fields cited; it is a scoped absence, not a proof about unrelated code.
This table is the "today" baseline for §L.

| Capability | Status | Evidence |
| --- | --- | --- |
| Identity record | Present | `MercCompany` (`src/domain/merc_company.zig` 18–41): `archetype_key`, commander names, `unit_name`, `faction_key`, `side`, `doctrine`, `cbills`, `founded_day`, `dissolved_day`, `logo_key`. |
| Operating HQ / base / location | **Absent** | No location, base or facility field on `MercCompany` (18–41). Procurement filters listings by kind, price, `available_after`, black-market eligibility and chassis kind only — no planet or reach test (`src/sim/merc_lifecycle.zig` 396–406). |
| Hull damage state | **Absent** | `HullStatus = enum { active, permanently_destroyed }` (`src/domain/hull_instance.zig` 35). An NPC hull carries no armor or slot condition; `market.HullCondition` (`src/econ/market.zig` 202–207) exists only as a price input. |
| Maintenance and repair of damaged hulls | **Absent** | No merc-company reference in `src/sim/maintenance.zig` (outside the grep list). Lost-field wrecks within `enemy_recovery_capacity` (2, `data/tables/tuning.zon` 136) are re-homed to the company roster with `status = .active` at no cost or time (`src/sim/black_market.zig` 227–240); the rest go to dispersed black-market listings (140–143). |
| Parts procurement | **Absent** | `selectNpcProcurement` skips `listing.kind != .unit` (`merc_lifecycle.zig` 398); the NPC black-market draw also takes only `.unit` listings (`black_market.zig` 369). |
| Market purchase / loss replacement | Present (fill-to-target only) | Monthly `runMercLifecycle` (`merc_lifecycle.zig` 237–307), called last in `tick.runMarkets` (`src/sim/tick.zig` 565), buys toward a mek target of `merc_company_hulls_each` (8, `tuning.zon` 506), substitutes vehicles inside that line target, then a bounded aerospace reserve (`selectNpcProcurement` 389–436). Price is debited (`stageBuy`, 585). **Changed by P5d.4b:** the mek and line target is the company's band `merc_band.lineTarget` (16), and vehicles substitute only in bands below `band_4` (§L8). |
| Upgrade | **Absent** | The selector returns `null` once targets are met (393); no path sells or swaps a weaker hull for a better one. |
| Sales / liquidation | Whole-company only | `planLiquidation` lists every roster hull at a fixed pristine condition (`armor_pct = 100`, `.quality = .f`, no damage) regardless of state (309–344) on dissolution. No partial or cash-pressure sale exists. |
| Cash / solvency | Partial | Seed and replacement capital is `merc_replacement_cbill_floor` (5,000,000, `tuning.zon` 511; `src/sim/roster_seed.zig` 252; `merc_lifecycle.zig` 374). The field comment says "no income" (`merc_company.zig` 33). No operating cost, payroll or contract income on the grep surface. Insolvency is fieldable BV below `merc_company_insolvency_bv` (2000, `tuning.zon` 508; `src/sim/rivals.zig` 101–104); insolvent or negative-cash companies are dissolved and replaced in the same monthly pass (`merc_lifecycle.zig` 270–289). **Changed by P5d.4b:** seed capital is the company's band `capital_cbills` (20M–75M, `data/tables/merc_bands.zon`); a replacement is founded at `band_1_2` with its capital, and `merc_replacement_cbill_floor` is gone. **Changed by P5d.4c:** insolvency gates OpFor selection only; a company dissolves only on cash below zero **and** `npc_understrength_runway_months` (12) whole months below its band's line since its persisted `understrength_since` (schema v69) **and** no active commitment (C1), with that cause in its log line (§L7). With no NPC cost yet, no company dissolves in ordinary play (C2). |
| Unpaid acquisition (defect candidate) | Observed | `runNpcBlackMarketDraw` gives active merc companies up to `npc_black_market_draws_per_month` (2, `tuning.zon` 137) unit listings per month (`black_market.zig` 315–382) and `black_market.zig` contains no `cbills` reference, so this owner does not debit the buyer and does not check a roster target. Whether another owner charges it is unverified; P5d.4a proves it with a regression first. **Fixed by P5d.4a:** its regression confirmed the draw left cash unchanged; merc draws now pay the listing price and take only hulls the company needs and can afford. |
| Roster composition at seed | Present (flat) | 12 companies (`merc_company_count`, `tuning.zon` 505), each 8 hulls rolled from the faction pool on `.rosters` (`seedMercCompanies`, `roster_seed.zig` 175–283; `roster_gen.rollFactionPoolOne` returns a mek chassis per its test, `src/gen/roster_gen.zig` 116). Archetypes (11 rows, `data/tables/rival_archetypes.zon`) carry key, name, doctrine, faction side, unit noun and arcs — no size, quality or skull band. **Changed by P5d.4b:** every company has a `band_key`; the 12 companies are seeded in the band table's fixed mix (3/4/3/2), each with 16 hulls (`seedMercCompanies`). |
| Roster progression | **Absent** | No band, experience, quality or growth field on `MercCompany`; strength changes only by the fill-to-target buy, battle loss/recovery and dissolution. |
| Readiness to fight | Present | `mercCompanyEligibleAsOpFor` (`rivals.zig` 111–124): active, solvent, active meks ≥ `merc_company_hulls_each`. **Changed by P5d.4b:** active meks ≥ the band's `merc_band.lineTarget` (16). |
| Air | Partial | A reserve of `merc_company_air_reserve_lances` (1) × `force.lance_size` (4, `src/domain/force.zig` 191) aerospace hulls is bought automatically once the line is full (`merc_lifecycle.zig` 392–393). Not earned; whether NPC aerospace takes part in battles is unverified. |
| Artillery | **Absent and refused** | Loading refuses any artillery-catalogue hull in a merc-company roster (`src/sim/artillery.zig` 345–347, 381). |
| Design intent vs code | Mismatch noted | `docs/p2-conventional-combat-design.md` §NPC Policy (95–109) says NPC "combat, loss, repair, salvage, and persistence call the same P2 rule owners as the player" and assigns the 16-mek target to the later NPC economy increment. The code above has no NPC repair owner. ROADMAP P5d.4 records the owner-approved target: 12 companies, 16 active mechs, 50M C-bills. |

Reusable player-side owners (not yet used for NPCs):
`maintenance.slotHours`, `maintenance.slotLabour(part_key, wrecked)`,
`maintenance.maintenanceHoursFor(kind, tons, quality, exotic)` and
`maintenance.weeklyConsumables` (`src/sim/maintenance.zig` 38, 42, 137, 80);
`market.hullPrice(base_cost, avg_weapon_cost, cond, price_roll_bp)`
(`src/econ/market.zig` 359). `HullCombatRecord` already records per-battle
`armor_lost`, `slots_damaged`, `slots_destroyed` and `destroyed` for any hull
(`src/domain/hull_instance.zig` 64–87).

## §A Travel and the conflict timeline (D1, D12–D15, D18–D19)

**One travel rule.** NPC movement uses
`logistics.daysForJumps(planet.jumpsBetween(from, to))` exactly as the player
does. There is no second travel model.

**NPC company location.** Each company has:

- `home_planet_key`, its operating base world (§L1);
- `location_planet_key`, where it is now;
- `ready_day`, the first day it can muster again. Until §L5 lands it is
  return day + a flat `// TUNE` refit; from §L5 it is derived from the
  company's actual repair backlog at its base.

At most one `Movement` is active per company:
`{from, to, depart_day, arrive_day, commitment}`. `arrive_day` is computed once
at dispatch and never changes. A company is in exactly one of these states:
`idle`, `mustering`, `en_route`, `on_station` or `returning`. One sim owner,
`npc_travel.status(gs, id, day)`, derives the state from the record. It is never
stored twice.

**What travel costs an NPC company (D18):**

- time: unavailable from hire to return plus `ready_day`;
- arriving late: it is not in any fight before `arrive_day`;
- money: a per-jump transport fee (`// TUNE`, C-bills), debited from `cbills` at
  departure by one owner. The employer reimburses a transport share fixed at
  hire, as `transport_pct` does for the player.

**The conflict timeline.** All days are fixed when the conflict opens and drawn
on `.politics`. Each is shown on the conflict record.

| Day | Meaning | How it is fixed |
| --- | --- | --- |
| `opened_day` (T0) | The instigator commits. The aggressor starts recruiting. State `preparing`; the defender does not know. | Scheme step (§C) |
| `strike_day` | Planned arrival of the aggressor's first element on the target world | T0 + preparation (`// TUNE` range) + travel of the aggressor's house force from its staging world (D19) |
| `muster_by` | Last day an aggressor hire may depart and still arrive by `strike_day` | Per candidate: `strike_day − daysForJumps(route)` |
| `discovery_day` | The defender learns of the threat. State `threatened`. | min(intelligence day, detection day) — D12 |
| `strike_day` reached | Fighting starts. State `open`. | — |
| `expires_day` / resolution | §C resolution | — |

**Discovery (D12):**

- intelligence day = T0 + an intelligence lag drawn on `.politics`, shortened by
  the defender's intelligence weight (faction `// TUNE` plus an
  `intelligence_chief` personage's standing);
- detection day = `strike_day − detection_lead_days` (`// TUNE`, the last-leg
  warning).

So the defender always gets at least the last-leg warning. Discovery depends
only on the conflict plan, never on whether the player accepted a position.
That keeps §K's position-independence: the same seed gives the same discovery
whatever the player does.

**Who knows what, and when:**

- Before `discovery_day`, only the aggressor's recruiting is visible: its
  posted positions in rings. Their cause line names the instigator and target,
  because the employer recruiting you tells you the job.
- News of the preparation (§K) is emitted on `discovery_day`, not on T0.
- An NPC aggressor hire is public on `discovery_day` or on its own
  `depart_day`, whichever is later.

**Player offers per side (D15, D16):**

- **Aggressor positions** (assault, raids, guerrilla where the template allows)
  post from T0. Each carries `on_station_by = strike_day` (raids: their own
  strike day).
- **Defender positions** (relief, security, riot per D3) post only from
  `discovery_day`. Each carries `on_station_by` = the strike day as the defender
  knows it.
- **Garrison and cadre** are the direction-3 exception. They come from a
  `stability` conflict (a standing need such as deterrence or training) and post
  without a threat. Their threat emerges later under §E.
- **Posting cadence.** A position posts on the day its rule allows, not only on
  the 1st, and closes on its own `close_day`. `close_day` is the last day the
  posting HQ's best ETA (`offerTransitDays`) still reaches `on_station_by`
  plus a grace (`// TUNE` days). The monthly refresh stops clearing the board.
  It keeps the existing per-HQ caps and kind/class caps.
- **Arriving late.** Accepting after the grace closes is a typed refusal,
  `TooLateToArrive`, with one sentence (rule 13). A player inside the grace
  arrives after the fighting has started, and the briefing says so.
- **Both sides.** A player holding a position on one side of a conflict is
  refused the other side's positions (`OppositeSide`).

**The opposing force is built from records, not invented (direction 7).**

- **Local forces.** At opening each conflict rolls the defender's garrison
  once: `local_force{lances, quality, lance_bv, lance_tons}`, from the
  defender's faction roster, scaled by `world_states` security, using the
  existing `opfor.roll` on `.politics`. It is persisted on the conflict. Both
  sides' offers read the same garrison.
- **Aggressor house force (D19).** `strike_force`, rolled the same way from the
  aggressor faction. Its staging world is the nearest world of that faction
  (`distanceLy`, ties in catalog order). Its travel sets `strike_day`.
- **Committed merc companies.** On each side, the commitments `on_station` on
  that world on the battle day, read by one owner,
  `world_contracts.forcesPresent(conflict, side, day)`.
- **Player defensive contract.** The opposition is the aggressor's
  `strike_force` plus aggressor commitments on station.
- **Player attack or raid.** The opposition is:
  - the defender's `local_force`;
  - plus any defender commitments already on station. This includes NPC
    companies on standing garrison commitments from an earlier `stability`
    conflict on that world, each with its own employer and mandate;
  - plus defender hires made at discovery (D13/D14) that have arrived.

  No NPC contract exists because the player took a raid.
- **Battle routing.** `battle.opforPool` reads `forcesPresent` on the battle
  day:
  - merc companies in arrival order (ties by `MercCompanyId`), rotated per
    battle, each fighting its own roster;
  - when none is present, the house force or local force from the faction
    roster;
  - a pirate organization uses the PER roster.
- **Briefing honesty.** The offer and briefing show the opposition known on the
  posting day (snapshot). A force arriving later is announced by a notice
  naming who, for whom and why (its hire cause). It is never a silent swap.

**What this resolves from the replaced direction.** A company in transit is
not in `forcesPresent`, so there is no rival-routing fallback while it travels.
`arrive_day` is known at hire, because travel is deterministic, so a
commitment's `end_day = arrive_day + term days` is fixed at hire by one rule
for every kind.

## §B Powers and personages (D6, D7)

- **Power.** A party that can back a conflict: a faction (`factions.zon` key),
  optionally narrowed to a named personage acting for it, for example a duke
  pursuing his own claim. A pirate organization is a power that hires no one
  and is hired by no one. A merc company is never a power; it is always hired
  (direction 2).
- **Personage** (new persisted entity, `domain/personage.zig`, `PersonageId`
  from a new `next_personage_id`). This is distinct from the contract-scoped
  `Actor`, and an `Actor` may point at one (`Actor.personage_id`).
  - Identity: `key` (a stable data key for authored rows; empty for procedural
    ones), names, `role` (`faction_leader`, `heir`, `family`, `general`,
    `intelligence_chief`, `planetary_ruler`, `noble`, `corporate`,
    `pirate_lord`, `merc_commander`), `faction_key`, `seat_planet_key`,
    `family_key` (house/dynasty), and `title` text.
  - Character: `motives`, a closed typed set of two or three of: `expansion`,
    `dynastic_security`, `secession`, `revenge`, `profit`, `honor`, `reform`,
    `survival`, `ambition`. Plus `ambition` and `loyalty` (to liege) on a 0–100
    `// TUNE` scale, and a backstory as a short authored or composed text.
  - Relations: `personage_relation(a, b, kind ∈ {kin, liege, rival, ally,
    grudge}, weight)`.
  - Provenance (internal metadata on every row, for tests and save
    validation; never displayed): `canon` (setting facts restated in project
    words), `authored` (project-created), or `procedural` (generated, with the
    generator version). No per-row URL, retrieval date or citation field.
  - State: `status` (`active`, `deposed`, `dead`, `exiled`),
    `standing_with_player`, and typed flags (as `ActorFlags`).
- **Coverage target (directions 5, 10).** Every `hires` world has exactly one
  `planetary_ruler`. Every faction has its leader. Canon heirs, family,
  generals and spymasters are added where Sarna names them for 3025. The
  eventual named-personage target is several hundred (`// TUNE`, for John to
  confirm); procedural rulers count toward it until promoted.
- **Static vs persisted.** Canon and authored rows live in
  `data/tables/personages.zon` (validated every build, rule 58: unique keys,
  faction/planet/family references, provenance fields present, era window
  covering 3025, relation endpoints exist). Their runtime state persists keyed
  by stable `key`. Procedural rulers are generated at `create_commander` for
  worlds with no data row, on a new `.politics` stream, and persisted in full.
- **Merc commanders.** A merc company's existing `commander_first` /
  `commander_last` are linked to one `merc_commander` personage, so the name
  is not stored twice.
- **Landed in P5d.1a.** The `personage` record holds the identity subset
  (names, `role` limited to `planetary_ruler` and `faction_leader`,
  `faction_key`, `seat_planet_key`), `motives`, `ambition` and a
  `procedural` provenance with its generator version; the title is derived
  ("Governor of …", "Leader, …"), not stored. Every hiring world has a ruler
  and every hiring faction except `PER` (P1) a leader on its capital, drawn
  on `.politics` at `create_commander` and persisted at schema v70.
  Relations and `loyalty` belong to 1c (S1); `key`, `family_key`, the other
  roles, stable keys, backstory, canon titles and the `canon`/`authored`
  layers to 1d, and `status`, `standing_with_player` and flags to later
  increments.
- **Landed in P5d.1c.** `personage_relation` holds the five kinds, each with a
  weight from 1 to 100: `liege` (vassal → liege) and `grudge` (holder →
  target) are directed, `kin`, `rival` and `ally` symmetric. `loyalty` is the
  weight of a ruler's liege relation, not a separate field, so it exists
  exactly where a liege does. At `create_commander`, after every personage,
  on `.politics`: every ruler of a leader-bearing faction owes fealty to its
  leader; every pair of same-faction personages sharing a last name is kin
  (K1); and each ruler may draw one rival (same faction), one ally (a faction
  neither side lists as a foe) and one grudge (a faction either side lists)
  toward a ruler within `relation_reach_ly` (60 ly, `// TUNE`; R1 (relations)).
  Leaders hold only kin and receive lieges. Persisted at schema v71; the
  loader refuses a dangling endpoint, a broken liege and rival plus ally on
  one pair. Which pairs creation draws is not a load check, because later
  increments relate others (§C resolution grudges, §K pacts and broken
  alliances).
- **Landed in P5d.1d.** `data/tables/personages.zon` (`domain/personage_data.zig`,
  validated every build) holds `families` and `rows` with `key`, `role`
  (adding `heir`, `family` and `intelligence_chief`), names, `title`,
  faction, seat, `family_key`, motives, ambition, an inclusive start-year era
  window and an internal `canon` or `authored` provenance. A campaign seats,
  in each ruler and leader seat, the row whose window holds its start year,
  else a procedural draw, and then every other in-window row (Y1); stock rows
  are 3025–3025, so other start years seat exactly the procedural world.
  Two data rows sharing a `family_key` are kin (K2), procedural pairs stay K1,
  and a data row and a procedural row are never kin; heirs, family and
  officials hold kin only. A data row shows its own title; a procedural row
  keeps "Governor of …" / "Leader, …" (T1). `personage` gains `key` and
  `family_key` at schema v72, with a transactional v71 → v72 migration that
  keeps every existing personage procedural and adds no data row (M1).
  `general`, `noble`, `corporate`, `pirate_lord` and `merc_commander`,
  backstory, `status`, standing and flags remain later work.

## §C World conflicts: the cause of every contract (D2)

- **Conflict** (new persisted entity, `ConflictId`, new `next_conflict_id`):
  - `planet_key`, `kind` (scheme template key);
  - `aggressor` and `defender`, each a power (`faction_key` plus optional
    `PersonageId`);
  - `instigator: PersonageId`;
  - `cause`: template key plus bound personages, rendered as one sentence;
  - `status ∈ {preparing, threatened, open, resolved}`;
  - the §A days;
  - `local_force` and `strike_force`;
  - `outcome` and `parent_conflict`.
- **Producer: the political step.** One owner, `politics.runSchemes(gs)`, runs
  monthly in the markets phase. For each active personage it scores the scheme
  templates whose preconditions hold (motive, role, relations, world state,
  liege's foes, recent conflicts). Then it draws at most `// TUNE` new
  conflicts per month on `.politics`, in stable personage-id order. A template
  binds an instigator, a target world and a target personage. It yields the
  sides, the position kinds each side may post and the cause sentence. Example
  templates:
  - border grab;
  - succession dispute;
  - secession plot;
  - punitive raid for an earlier defeat;
  - corporate seizure;
  - insurrection;
  - pirate predation;
  - `stability` (a standing garrison or training need).
- **Offers come from conflicts** under the §A posting rules. The aggressor
  posts assault and raids. The defender posts relief, security and riot (per
  D3). Either side may post guerrilla, by template. A `stability` conflict
  posts garrison and cadre. The posting faction is that side's faction. Pay,
  terms, rating gates, beachhead, cooling and the per-HQ caps keep their
  existing owners and order. `Contract` gains `conflict_id`, `side`,
  `on_station_by` and `close_day`.
- **No contract without a backer.** Every offer and contract has a
  `conflict_id` whose side faction is the employer. The loader refuses one
  without it (rule 47).
- **Resolution.** A conflict resolves at `expires_day` or when its contracts
  and commitments close. The inputs are the player's result plus a
  deterministic strength comparison of the NPC sides: faction weight
  (`// TUNE`) plus the present commitments' `mercCompanyFieldableBv`, with one
  `.politics` draw. Resolution:
  - writes `outcome`;
  - moves `world_states` through their existing owner;
  - sets personage consequences (deposed ruler, grudge relation, standing).

  These feed later scheme preconditions ("the Duke lost Galtor last spring,
  now he wants revenge").
- **Landed in P5d.1e.** `conflict` is persisted at schema v73 (with
  `next_conflict_id`; a v72 store migrates with no conflict and the counter
  at 1). It holds its template key, world, aggressor and defender (faction
  plus personage), instigator, staging world, the §A days, `local_force`,
  `strike_force` and `outcome`; `status` is derived from the days and the
  outcome by one owner, never stored, and `cause` is rendered from the
  template, never stored. `politics.runSchemes` opens at most
  `schemes_per_month` conflicts on each 1st, under `max_open_conflicts`,
  from 12 `opening` templates in `data/tables/political_events.zon`:
  `border_grab`, `industrial_seizure`, `supply_raid`, `probing_raid`,
  `punitive_raid`, `grudge_strike`, `rival_feud`, `secession_revolt`,
  `sponsored_unrest`, `pirate_predation`, `allied_reprisal` and
  `dynastic_claim` (E1: corporate seizure became `industrial_seizure` by a
  ruler, insurrection `sponsored_unrest` by a hostile power, and pirate
  predation is a `PER` world's ruler's). A candidate draws with weight
  template weight × (1 + ambition); each draw removes the candidates sharing
  its instigator or world, and no world or instigator holds two unresolved
  conflicts. `local_force` is `opfor.roll` for `garrison_duty` scaled by
  world security, `strike_force` `opfor.roll` for the template's strike
  kind, and the strike force stages from the aggressor faction's nearest
  other world. Resolution is NPC-only (E4): the aggressor wins with chance
  `strike BV / (strike BV + local BV)` on one `.politics` draw; it writes
  `outcome` and moves the world by `world_state.conflictWorldDelta` (E5).
  Deferred: `stability` conflicts and every offer to 1f, `parent_conflict`
  to 1m, personage consequences (deposition, grudges, standing) to 1n; the
  faction weight in resolution and discovery is dropped (E4, E6).
- **Landed in P5d.1f.** Every offer comes from a conflict, at schema v74
  (with a transactional v73 → v74 migration: every v73 conflict becomes
  offensive and every v73 offer and contract has no backer, such an offer
  leaving the board at the next month start). A conflict's `family` is
  `offensive` or `standing` (F1): a standing conflict is §E's `stability`
  need, drawn from four `standing` templates in `political_events.zon` for
  every hiring world with a ruler at campaign creation and kept on each 1st
  (`politics.maintainStanding`), with no aggressor, staging world, strike,
  end day or strike force; its ruler is defender and instigator; it stands
  down once `standing_lifetime_days` have passed and no contract it backs
  holds its position. `Contract` gains `conflict_id`, `side`,
  `on_station_by` (the strike day) and `close_day`. `contract_market.refresh`
  runs daily (F2): it retires a position past its `close_day` and, on the
  1st, every position without one (a standing need's), then posts each
  unresolved conflict's sides in id order on each board that sees the world
  — the aggressor's from `opened_day`, the defender's from `discovery_day`
  (D15) — up to `positions_per_side` positions each (F3), kinds drawn on
  `.market` from the aggressor's template `position_kinds` or the
  defender's relief, security and riot (D3), under the existing per-HQ
  offer count, kind and garrison-class caps. `close_day` is `on_station_by`
  less the travel from the posting HQ's world (`postingTransitDays`) less
  `position_close_grace_days`; a side whose close day has passed posts
  nothing. An offer's opposition is the backer's force facing its side
  (F4): the defender's `local_force` for the aggressor's positions, the
  `strike_force` for the defender's, none for a standing need's, whose
  garrison fights no engagement until §E's threats emerge (1m); the
  per-offer opposition roll, kind roll and enemy pick are gone. Accepting a
  position past its close day is refused `TooLateToArrive`, and the other
  side of a conflict the outfit holds a position in `OppositeSide`, both
  before any change. The board, the offer's brief and the active contract
  show the cause, side, on-station day and close day; `conflicts` lists the
  standing needs with positions posted and the side the outfit holds.
  Between contracts a day that posts new positions stops an advance
  (`positions_posted`); payday no longer names a board refresh. The
  opposition gap between 1f and 1k stands: forces present and opposition
  routing are 1k's, and the old counter-hire still runs until 1k deletes it.

## §D Commitments: hired companies with travel (D4, D13, D14)

- **Commitment record.** `{conflict, side, merc_company, employer (faction +
  PersonageId), mandate (kind + cause key), hired_day, depart_day, arrive_day,
  end_day, monthly_pay, transport_share, status ∈ {mustering, en_route,
  on_station, released, broken}}`. A merc company is never in a fight without
  one. "Named employer and mandate" is that record.
- **Aggressor hires** happen during `preparing`, through one owner,
  `world_contracts.hire(gs, conflict, side, by_day)`. A candidate must:
  - pass readiness (`mercCompanyEligibleAsOpFor`, renamed for its scope) with
    `ready_day ≤ today`;
  - be idle and not committed elsewhere;
  - not be affiliated with a foe of the hiring faction;
  - not be hired by the other side;
  - arrive in time: `today + muster_days + travel ≤ by_day`.

  Candidates are ordered by (arrival day, `MercCompanyId`). The draw is on
  `.politics`.
- **Defender reaction (D13)** on `discovery_day`, in one owner, in order:
  - the local force is alerted (the `local_force` lances fight from
    `strike_day`);
  - defender positions post for the player (§A);
  - the defender may hire NPC companies that can arrive by the known
    `strike_day`.
- **Emergency late hiring (D14).** During `open`, a monthly escalation chance
  (`// TUNE`) lets a losing side hire. Each hire carries a beat cause (§K),
  e.g. "the Duke, losing ground, hires …". It joins `forcesPresent` only from
  its `arrive_day`. The player's acceptance is never an input.
- **Release.** At `end_day` or resolution, whichever is first, a commitment
  becomes `released`. The company returns home from its `location`. A company
  released while `en_route` completes the leg and then returns; there is no
  mid-jump reversal. It is `broken` when its company dissolves. From that day
  `forcesPresent` drops it, logged with its cause.
- **Pay.** `monthly_pay` is credited on payday by one owner. Transport follows
  §A.
- **Rival overlay.** `instantiateRivals` stops drawing a company. It links
  companies from `forcesPresent` on the opposing side. The counter-hire is
  deleted (direction 4).

## §E Garrison and cadre: the threat that chooses to come (D3)

- A garrison or cadre offer belongs to a `stability` conflict. The defender is
  the employer (often the planetary ruler), and there is no aggressor yet. The
  opposition is "no named threat".
- **Threat emergence**, one owner `politics.threatEmerges(gs, contract)`, runs
  monthly while the contract is active. Either of these may decide to attack:
  - a pirate organization (motive `profit`, scored by world industry and
    security);
  - an NPC company hired by a personage with a grudge against the ruler (the
    hire has its own cause).

  Either opens a child conflict (`parent_conflict`) with that aggressor and
  cause, and its own §A timeline. The aggressor travels.
- The contract gets a P5a stop and an inbox notice on the child conflict's
  `discovery_day`. The notice names who, why and the expected arrival. The
  opposition joins on its `arrive_day`. Until then, probe battles keep today's
  garrison behaviour (`battle.zig` 129, `hasOpfor` false path).
- **Landed in P5d.1f.** Every hiring world with a ruler holds one standing
  need from the campaign's first day (`border_watch`, `militia_training`,
  `household_guard`, and `den_guard` for a pirate world), posting garrison
  and/or cadre duty for its world's faction with no named threat (enemy
  `PER`, no opposition lances); threat emergence and `parent_conflict` are
  1m's.

## §F Narrative surfaces

- **Cause sentence.** Every offer, briefing and conflict detail shows one
  sentence built from the template and its bound personages. Example (style
  only, project-authored, not canon): "Baron Ilse Varga of Zebebelgenubi has
  refused her levy; the Lyran Commonwealth's Duke of Skye hires you to enforce
  it."
- **Timing.** The board shows `on_station_by`, your ETA and the close day. The
  briefing shows the known opposition and each force's expected arrival.
- **Who's who.** A personage detail (REPL `who <id|key>`, and a modal from the
  Contracts detail and the conflict view in the TUI) shows:
  - title, seat, liege, kin, motives and backstory;
  - no provenance label: nothing says where the personage comes from
    (P5d.1d removed the `procedural` label P5d.1a had shown);
  - standing with you;
  - conflicts instigated or targeted;
  - for a merc commander, the company's location and commitment.

  P5d.1b landed the Contracts entry point: `w` on any F4 offer, active or
  closed contract opens a read-only sheet of the contract's world governor,
  employer leader and enemy leader, each the `who` row (since P5d.1d without
  any provenance label), and REPL `who <contract id>` prints the same rows. P5d.1c added
  liege and kin, with rivals, allies and grudges, as relation lines under each
  seat on that sheet and under each personage in `who <world>` and
  `who <contract id>`. The conflict-view entry comes with the conflict view;
  backstory, standing, conflicts and the merc commander come with the
  increments that create them.
- **Conflicts list.** REPL `conflicts` and a TUI pane list open conflicts in
  your rings, with sides, the timeline, known hires and the player's position.
- **Log.** Log lines for:
  - conflict opened (cause);
  - threat discovered;
  - hire made (who, for whom);
  - company departed and arrived;
  - threat emerged;
  - conflict resolved (outcome and consequence for named personages).
- Exact TUI keys and placement are fixed in each increment's plan against
  `docs/tui.md` and rule 39; this document fixes content, not keys.

## §G Competition for positions (D5)

- On a `// TUNE` share of positions, `world_contracts.rollBids` (on
  `.rivals`) sets an NPC bidder and a fill day. A bidder must be able to arrive
  by `on_station_by` (§A).
- The player keeps priority until the fill day. After it, the row stays
  visible as "filled by <company> at <pay>/mo — <cause>". Accepting it refuses
  with typed `PositionFilled` (rule 13, one sentence, one smoke step).
- Causes: `rating`, `standing`, `price`, `arrival` (the bidder's arrival day
  against the player's ETA). Fixed tie order: price, arrival, standing, rating.
- A fill becomes a §D commitment with travel, and can be the player's
  opposition on the other side.

## §H Corpus: size, provenance and composition (D6, D8)

- **Composition (three layers, each row's layer internal metadata, never
  shown to the player):**
  1. **Canon** — facts restated in project words from Sarna, 3025 state
     only; no per-row citation.
  2. **Authored** — project characters filling named gaps (rulers of notable
     worlds, pirate lords, merc commanders), written for this project.
  3. **Procedural** — rulers for remaining worlds and minor family, generated
     from names tables plus motive/trait tables. One can be promoted to
     authored by adding a data row with the same seat.
- **Scenario count.** A scenario is a reachable binding of (scheme template ×
  instigator role × target relation × position kind set), with its cause text.
  The target is about 3,000: roughly 60 templates × 5 roles × 10 kind/side
  combinations, filtered by preconditions. All counts are `// TUNE`, for John
  to confirm.
- **First corpus** (P5d.1a, 1d, 1e):
  - leaders for every hiring faction (12 at the base; canon where verified in
    §I, otherwise authored and labelled);
  - the §I canon figures;
  - about 20 authored rulers for notable worlds;
  - every other ruler slot procedural;
  - about 12 scheme templates.

  Growth after that is data-only ("P5d content expansion").
- **The corpus as built (P5d.1d):** 20 canon rows (the eight great and
  Periphery leaders, the rulers of New Syrtis, St. Ives and Summer, and nine
  heirs, family and officials), 24 authored rows (leaders of the Marian
  Hegemony, Circinus Federation and Oberon Confederation, and the rulers of
  the 21 hiring worlds of industry 4 or more with no canon ruler), and a
  procedural ruler for every other hiring world. The counts are asserted by
  tests over the table; no player-visible corpus report or count exists.
- Canon enters through `personages.zon` from the planning research in §I;
  the implementer encodes it from that record and needs no web access.

## §I Sarna research record (planning input, retrieved 2026-10-15 and 2026-10-17)

The facts below were read read-only during planning and are restated in
project words; no Sarna prose is copied. They are planning input only: the
game carries no citation, re-verification step or player-facing source
disclosure, and the implementer encodes the P5d.1d plan's restated list
without web access. The URLs below record where planning read; they enter no
data row and no screen.

- **P5d.1d research (2026-10-17).** The P5d.1d plan restates the 3025 figures
  it encodes: the eight faction leaders on their capitals; Michael
  Hasek-Davion (New Syrtis), Candace Liao (St. Ives) and Aldo Lestrade IV
  (Summer) as rulers; and Melissa Steiner, Theodore Kurita and Thomas Marik
  as heirs, Marie Davion-St. Claire, Romano, Tormano, Duggan and Duncan as
  family, and Quintus Allard as acting intelligence head. Thomas, Romano,
  Tormano, Duggan, Duncan and Quintus are placed on their faction's capital
  because the pages give no 3025 seat; placement is a model choice. Dropped
  because the pages read do not confirm a 3025 role, or only a
  disambiguation page was read: Morgan Hasek-Davion, Frederick Steiner, Ryan
  Steiner and Ardan Sortek. No `general` or `noble` row exists. The Concord
  of Kapteyn date (3022 or 3024) and the start of Liao's dealings with
  Michael (3020 or about 3027) remain recorded disagreements; neither is
  encoded.

- **Licence.** Sarna states its content is under the GNU FDL 1.2 unless
  otherwise noted, and that this licensing does not cover the original works or
  trademarked names (https://www.sarna.net/wiki/BattleTechWiki:Copyrights).
- **Era.** The Third Succession War is treated as ending in 3025 and the
  Fourth as breaking out in 3028 (https://www.sarna.net/wiki/Third_Succession_War).
  The Fourth War ran 20 August 3028 – 19 February 3030, Lyran Commonwealth and
  Federated Suns against the Combine, the League and the Confederation
  (https://www.sarna.net/wiki/Fourth_Succession_War). The FedCom alliance
  document was signed in 3022. The Concord of Kapteyn (DC/FWL/CC) is dated 3022
  on the war page and 3024 on the leader pages. This is a **source
  disagreement**, recorded rather than resolved.
- **FS.** Hanse Davion, First Prince from 3013, born 2983, nicknamed the Fox.
  Advisors include Quintus Allard (intelligence) and Ardan Sortek; half-sister
  Marie Davion-St. Claire. He was captured in, and escaped, Operation
  DOPPELGANGER in 3025 (https://www.sarna.net/wiki/Hanse_Davion). Michael
  Hasek-Davion was Duke of New Syrtis and Field Marshal of the Capellan March
  from 3013, married to Marie (3003), with son Morgan. He worked secretly with
  Liao from about 3027 and died on Sian on 14 February 3029
  (https://www.sarna.net/wiki/Michael_Hasek-Davion).
- **LC.** Katrina Steiner, Archon, took power in a 3007 coup against her uncle
  Alessandro. Her daughter Melissa was born in 3010; Katrina issued the Peace
  Proposal in 3020 (https://www.sarna.net/wiki/Katrina_Steiner). Aldo Lestrade
  IV (2981–3029) was Duke of Summer and led Skye separatism with Frederick and
  Ryan Steiner. He plotted against Katrina and Melissa
  (https://www.sarna.net/wiki/Aldo_Lestrade_(31st_c.)).
- **DC.** Takashi Kurita, Coordinator from 3004. His son Theodore was born in
  3000. He survived assassination attempts in 3021, 3023 and 3024, and Wolf's
  Dragoons served the Combine from 3022
  (https://www.sarna.net/wiki/Takashi_Kurita). Theodore was heir and commanded
  the Legion of Vega from the mid-3020s, after a falling-out with his father
  (https://www.sarna.net/wiki/Theodore_Kurita).
- **CC.** Maximilian Liao, Chancellor (2964–3036, nicknamed the Diablo), with
  children Candace, Romano and Tormano. He built up the Maskirovka and the
  Warrior Houses, and dealt secretly with Michael Hasek-Davion from 3020. The
  Liao page dates this 3020 and the Hasek-Davion page about 3027, another
  recorded disagreement. He ran DOPPELGANGER
  (https://www.sarna.net/wiki/Maximilian_Liao).
- **FWL.** Janos Marik, 48th Captain-General, with son and heir Thomas, son
  Duggan and nephew Duncan. Wolf's Dragoons left League service in spring 3020.
  He signed the Concord under Kurita pressure. The Andurien secession came in
  September 3030 (https://www.sarna.net/wiki/Janos_Marik).
- **Periphery.** Thomas Calderon, Protector of the Taurian Concordat, 3017–3055
  (https://www.sarna.net/wiki/Protector_of_the_Realm). Kyalla Centrella,
  Magestrix of Canopus, 3012–3040 (https://www.sarna.net/wiki/Magestrix).
  Neil Avellar II, President of the Outworlds Alliance, 3015–3056
  (https://www.sarna.net/wiki/President_of_the_Outworlds_Alliance).
- **Not researched or unverified:** leaders of the Marian Hegemony, Circinus
  Federation and Oberon Confederation; ComStar's Primus; Combine and Davion
  generals beyond those named; every planetary ruler name.
- **Planet pages generally lack 3025 rulers.**
  https://www.sarna.net/wiki/Hesperus_II gives a noble-ruler title (Duke of
  Hesperus II) with no name, and only an HPG precentor for 3025. So most of the
  234 rulers cannot be canon; this drives D6.

## §J Persistence, determinism, contract mapping

Per increment, never in this document: one schema step per increment that adds
state, taking the next number at its own base (not pre-assigned here). The
rule-51 refusal applies to older stores. The loader fails closed on:

- dangling refs;
- an offer without a conflict;
- a commitment whose company is not under it;
- a movement without a commitment;
- an `arrive_day` that disagrees with the travel rule for its route;
- an NPC hull condition row for a hull not owned by a merc company, or a
  condition outside `HullCondition`'s ranges;
- a company `band` not in `merc_bands.zon`, negative `spares_cbills`, or an
  `understrength_since` later than today.

Every field is classified (rule 45) and digest-covered (rule 53). `.politics`
is a new stream with a permanent salt (rule 57). §L's draws stay on the
existing `.rivals` (identity, base, band at seed) and `.market` (purchases,
upgrades) streams; repair, ledger and ladder draw nothing. Contract rules
mapped: 1, 2, 3, 7, 11–14, 17, 20–24, 29–34, 45–53, 55–59, 61, 67–71, 84, 86.

## §K The living world: progression, news and decisions (D10, D11)

**One event architecture.** Every political happening is an instance of a data
template in `data/tables/political_events.zon`. Scheme templates (§C) are one
family of it. The families are:

- `opening`: a conflict starts;
- `beat`: escalation, a hire, a setback, a betrayal;
- `resolution`: a conflict ends with consequences;
- `intrigue`: non-violent, for example an heir named, a marriage pact, a
  governor deposed, a grudge sworn, an alliance broken.

Each template declares:

- its preconditions over personages, relations, world state and conflict state;
- its effects through existing owners;
- one news sentence;
- optionally, decision options (the P5c option shape and closed cost subset).

Corpus growth is data-only.

**Progression is independent of the player.** One owner,
`politics.advanceWorld(gs)`, runs in the daily tick's markets phase. In order,
it handles:

1. due NPC movements, by (`arrive_day`, `MercCompanyId`);
2. due timeline days and beats, by (day, `ConflictId`): discovery, strike,
   escalation and resolution;
3. once per month, `opening` and `intrigue` templates, by `PersonageId`, then
   template-file order.

A conflict draws its beat schedule (`next_beat_day`, `// TUNE` day ranges) on
`.politics` when it opens.

**Landed in P5d.1e.** `politics.advanceWorld` runs in the markets phase after
the hiring halls churn and before the monthly refreshes. It implements steps
2 and 3 without beats or intrigue: discovery, the strike and NPC-only
resolution by (day, `ConflictId`), each with one `[politics]` log line (an
opening is secret and logs nothing, E3), then `opening` templates on the
1st. Step 1 (movements) belongs to 1i and beats to 1n.

- **Rule:** player presence and visibility are never inputs to progression.
- **Test (asymmetric, rule 71):** two campaigns on the same seed, with the HQ on
  different worlds, have byte-identical personage, conflict, commitment and
  movement state, while their news logs differ.
- **Exception:** the player's own contract results and decision answers do
  change progression, and that is the point of them. Accepting a position does
  not change discovery (§A).

**Reach: who hears about it.** One sim owner,
`politics.newsReach(gs, planet_key) ?Reach`, returns the nearest player
presence within the threshold (the distance and which presence), or null. A
presence is:

- every HQ world;
- every company's world, by `posture.companyPosture`:
  - `deployed` / `idle_afield`: its world;
  - `en_route`: its destination contract world;
  - `returning`: its home HQ world.

The position rule moves from the private `queries.companyPlanetKey` into this
sim owner. The query then delegates to it (rules 3, 29), so one rule serves
both.

- **Threshold:** `tuning.politics.news_reach_ly = 100` (`// TUNE`,
  light-years, inclusive, measured by `planet.distanceLy`). It is declared once
  in `data/tables/tuning.zon` with its unit in the name (rules 24, 81), and is
  separate from HQ influence rings, which still gate offers (D10).
- **Evaluation:** reach is evaluated once, on the day the happening becomes
  public, against presences at that day's start, and stored on the item. Public
  days are:
  - preparation: `discovery_day`;
  - a hire: its public day (§A);
  - an arrival: `arrive_day`;
  - anything else: its occurrence day.

  Moving an HQ later never back-fills history. Out-of-reach happenings stay
  queryable through conflict and personage records with no news item.

**News (informational, non-blocking).** A `NewsItem` record has:

- `id` (new `next_news_id`), `day`, `template_key`;
- `conflict` / `personage` refs, `planet_key`;
- `reach_ly` and `reach_from`;
- `severity ∈ {routine, notable, major}`;
- `text`, rendered once at emission and stored as plain validated text
  (rule 41).

Also:

- one campaign-log line per item, in a new `LogCategory.politics`;
- news never holds the turn and never stops advance-until-stop;
- notable and major items go to the P5a digest (D11);
- surfaces: a Desk "Newswire" pane and a REPL `news [n]` from one query,
  `queries.newsRows` (rule 30). It formats and filters but never decides reach
  (rule 29). Rows carry their `NewsId`, conflict and personage ids (rule 32);
- all items persist; the pane shows the newest `// TUNE` count.

**Decisions (modal).** A happening needs a modal only if all three hold:

1. its template has options;
2. it is in reach;
3. the player has a stake, from one owner `politics.playerStake(gs, ev)`. A
   stake is any of:
   - an HQ, deployed company or open contract on the world;
   - a relation or standing with an involved personage above a `// TUNE`
     magnitude;
   - a position or commitment in the conflict.

Otherwise it is news only.

- **Inbox.** The decision goes into the existing `EventQueue` as a
  `politics`-kind event owned by the personage, with `deadline_day` from the
  template (`// TUNE` days). It uses the existing decision modal and answer
  verb.
- **Timing.** It is a P5a stop when it arrives. P5a.7 holds: an auto advance
  stops the day before its deadline. It does not `blocksTurn`, so ordinary
  advancing past the deadline applies the template's named default.
- **Answers.** An answer applies through `politics.answer` (validate, prepare,
  commit; rules 11–13), and its effects feed progression.
- **Unanswerable.** A decision with no answerable option is downgraded to news
  at raise time (rule 1).

**Determinism.** All political draws use `.politics` in the order above. Text
rendering, reach and stake draw nothing. Same seed and same player inputs give
the same world.

**Persistence and digest.** New state:

- `news_item`, `next_news_id`, beat fields;
- `politics`-kind inbox rows;
- `LogCategory.politics`.

Each is classified (rule 45) and digest-covered (rule 53). An unknown template
or dangling ref is `CorruptSave` (rule 47). Stored news text is reloaded, not
regenerated.

## §L NPC company operations: base, upkeep, recovery and solvency (D20–D29)

Purpose: every NPC company is a business whose strength and cash change only
through named causes (battle, purchase, sale, repair, upkeep, pay), and which
returns to its band target whenever it can afford to. The baseline is the
capability check under "What exists today". All numbers are `// TUNE` with
units in their names (rules 24, 81) and live in `data/tables/tuning.zon` or a
band table. New behaviour lives in new subsystem modules (planned names
`src/sim/npc_upkeep.zig`, `src/sim/npc_finance.zig`); `merc_lifecycle.zig`
keeps buy, spawn and dissolution and calls them (rules 3, 76, 77).

**§L1 Operating base.** `home_planet_key` (§A) is the company's operating base:
a non-PER world of its `faction_key` drawn at seed on `.rivals`, ties in
catalog order. The base:

- is where repair happens (§L3) and where the company returns between
  commitments;
- defines market reach: NPC hull and parts purchases consider only listings on
  the base world or within `npc_market_reach_ly` of it (D21), using
  `planet.distanceLy`; a hull bought off-world arrives after the shared travel
  rule's days (§A) and is not fieldable before;
- has a repair capacity `npc_base_repair_hours_month` set by band (§L8), not by
  a player-style facility build (D20).

**§L2 Hull condition.** A new persisted record per NPC-owned hull reuses the
existing `market.HullCondition` fields (`armor_pct`, `quality`,
`damaged_slots`, `destroyed_slots`, `missing_components`), so one struct feeds
both repair cost and sale price (rule 3). Writers:

- battle: after a pool-path engagement, each surviving or recovered NPC hull's
  condition is reduced from that battle's `HullCombatRecord` (`armor_lost`,
  `slots_damaged`, `slots_destroyed`), one owner;
- recovery: the lost-field re-home (`black_market.zig` 227–240) re-homes the
  wreck **damaged** with its recorded condition instead of pristine `.active`;
- repair (§L3) and sale (§L6).

Fielding: a hull below `npc_fieldable_armor_pct` or with any destroyed slot
does not count toward fieldable BV or readiness (`rivals.zig` 85–124 read
condition through one predicate).

**§L3 Maintenance and repair.** One owner, `npc_upkeep.repairPass(gs)`, runs
monthly in the markets phase before the lifecycle buy:

- only companies at their base and not `en_route`/`on_station` repair;
- jobs are ordered: destroyed slots on line hulls, then armor on line hulls,
  then reserve assets; ties by `HullInstanceId`;
- each job's hours come from `maintenance.slotHours`, its labour cost from
  `maintenance.slotLabour(part_key, wrecked)` and its parts from §L4, so NPC
  and player repair price the same work identically (rule 3, P2 NPC policy);
- a job runs only if hours remain in the month's base capacity, its parts are
  in stock, and paying keeps cash at or above zero; a line-hull job may spend
  the reserve floor (§L7), a reserve-asset job keeps cash at or above it;
- routine upkeep (`maintenance.maintenanceHoursFor` /
  `weeklyConsumables`-equivalent cost per active hull) is charged by §L7's
  ledger, not here.

**§L4 Parts procurement.** NPC companies hold an abstract spares stock valued in
C-bills (`spares_cbills`), not per-part inventories (D22). One owner,
`npc_upkeep.buySpares`, tops it up monthly toward
`npc_spares_target_cbills_per_hull × active hulls` at the base-world price
(existing part/market pricing owner, named in the increment plan), only from
cash above the reserve floor. A repair job consumes spares equal to
`part_mod.cost` of the destroyed parts it replaces; a shortfall defers the job
with a logged cause ("awaiting parts").

**§L5 Post-contract repair and recovery.** When a commitment is released
(§D) the company travels home (§A). On arrival it is `refitting`: `ready_day`
is the day §L3 is projected to clear its line-hull backlog under current cash,
spares and capacity, capped at `npc_refit_max_days`. Salvage it took under its
commitment (if D27 allows) enters as damaged hulls. A company may accept a new
commitment while refitting only if its fieldable line meets the hire's
readiness test (§D).

**§L6 Loss replacement, upgrades and sales.** One sale owner,
`npc_finance.sellHull(gs, company, hull, cause)`, lists a hull on the market at
`market.hullPrice` with its **real** condition (replacing the pristine price at
`merc_lifecycle.zig` 326–332), records ownership history and logs the cause.
Every sale path uses it.

- **Replacement:** the existing fill-to-target selector (`selectNpcProcurement`)
  keeps its priority order but reads band targets (§L8), base reach (§L1) and
  the reserve floor (§L7).
- **Upgrade:** when a company is at target, has no line-hull repair backlog and
  holds cash above `reserve + npc_upgrade_margin_cbills`, it may replace its
  lowest-BV line mek with a reachable listing of strictly higher BV in a
  band-allowed weight class; the replaced hull is sold through `sellHull`. At
  most `npc_upgrades_per_month` per company; draws on `.market`.
- **Black-market purchases** pay the listing price and respect band targets and
  the reserve floor, like any purchase (fixes the unpaid draw in the
  capability check).

**§L7 Cash, solvency and the cash-pressure ladder.** One ledger owner,
`npc_finance.monthlyLedger(gs)`, per company in `MercCompanyId` order:

- income: commitment `monthly_pay` and transport share (§D), salvage cash;
- costs: upkeep per active hull and payroll per band, priced from the same
  owners as the player's equivalents (P5d.4 "player-equivalent operating
  costs"), plus §A transport fees;
- **reserve floor:** `npc_reserve_months × monthly burn`. Discretionary spending
  (spares top-up, upgrades, air/artillery growth) never takes cash below it;
  repairs of line hulls may use it; nothing voluntary takes cash below zero.

When mandatory costs would leave cash negative, the ladder runs in order and
stops as soon as cash is non-negative:

1. suspend discretionary spending (already implied by the floor);
2. sell reserve assets beyond band minimum (air, vehicles, artillery);
3. sell damaged hulls whose repair cost exceeds `npc_scrap_threshold_pct` of
   their sale value;
4. sell the lowest-value line hulls, never below `npc_min_viable_lances`;
5. record `understrength_since` when below band target.

**Dissolution** replaces the current BV/negative-cash rule
(`merc_lifecycle.zig` 270) with P5d.4's owner-approved condition, all three
together: cash below zero after the ladder, understrength for
`npc_understrength_runway_months` (12), and no active commitment. Dissolution
still liquidates through `sellHull` and spawns a replacement (§L8 band rules).
A company is never dissolved merely for being damaged while it can pay.

**§L8 Roster bands and growth.** A company has a `band` (D24 fixes the scale):
`band_1_2`, `band_3`, `band_4`, `band_5`, matching "1–2 skull through 5 skull".
A band row in a new `data/tables/merc_bands.zon` (rule 58 validated, rule 59
cited as project-tuned) gives:

- line target: **four fighting lances** (16 meks, `force.lance_size` × 4) for
  every band (D23), with vehicle substitution allowed only below `band_4`;
- weight-class mix and minimum hull quality for purchases;
- seed capital and payroll scale (P5d.4's 50M is the `band_4` reference, D25);
- repair capacity (§L1) and reserve months (§L7);
- whether air and artillery may be **earned** (D26).

Skull label: the band is the company's intrinsic tier shown in its detail. The
contract difficulty the player sees is still `skulls.fromRatioBp` on actual
power (`src/domain/skulls.zig`), so the two can differ and the UI says which
is which.

Growth is earned, never automatic:

- **promotion** one band up when for `npc_promotion_months` the company has
  held its band target, kept cash above its reserve, and completed at least
  `npc_promotion_commitments` commitments without breach;
- **demotion** one band down after `npc_understrength_runway_months / 2`
  below target; logged with cause;
- **air:** the automatic aerospace reserve (`merc_lifecycle.zig` 392–393) is
  replaced by an optional air lance bought only when the band allows it and
  cash exceeds `reserve + npc_air_margin_cbills`;
- **artillery:** refused today by the loader (`artillery.zig` 345–347, 381)
  and modelled through player-scoped formation records; NPC artillery waits
  for D26/D29 and a separate architecture increment.

**§L9 No durable passive decay (policy invariant).**

- Nothing degrades an NPC company with the passage of time alone: no
  condition loss, quality drift or BV loss without a battle, sale or named
  event.
- A company that can afford recovery recovers: if it is at base, has cash
  above the floor and reachable supply exists, its line backlog shrinks every
  month and its roster climbs back to band target.
- **Proof obligation (P5d.4h):** a fixed-seed run damages a solvent company,
  then shows it back at band target and fully repaired within a bounded number
  of months given supply. Its asymmetric twin (rule 71) with no reachable
  supply shows it waiting with the logged cause, not dissolving.

**§L10 Surfaces.** The NPC company detail (`queries` rows, REPL and TUI) shows
base world, band, line strength vs target, repair backlog and ETA, spares,
cash bucket (not exact C-bills unless D28 says so), commitment and
`understrength_since`. Log lines: repair completed, awaiting parts, hull sold
(cause), upgrade, band change, ladder step, dissolution cause. Keys and
placement are fixed in each increment's plan.

## Redistribution across P5d and later items

Existing items keep their stated scope. Only their position and dependency
notes change, except where marked.

- **P5d.1** becomes this design, followed by the increments P5d.1a–P5d.1p.
- **P5d.2 identity** and **P5d.3 lifecycle and hull disposition** move ahead of
  every increment where a merc company is hired or fights. P5d.3 has a
  regression-first bug (stale active hulls). It must land before a company's
  own roster is the player's opposition.
- **P5d.4 economy** is split into P5d.4a–P5d.4l. Every clause of its entry maps
  to one increment: 12 companies / 16 active mechs / 50M → 4b; shared
  mech-market replacement → 4b and 4i; player-equivalent operating costs → 4f;
  12-month understrength runway → 4c; contract income → 4f (commitment pay from
  P5d.1j); liquidation only after no-cash, understrength and no active contract
  → 4c and 4g; co-located recruiting → 4k (reads `location_planet_key`). The
  unpaid black-market draw is fixed first (4a). The cost-bearing increments
  (4f, 4g) come after P5d.1j so no company bleeds cash before it can earn.
- **P5d.5 parity** moves after P5d.1k (present forces are the opposition).
  Its "committed companies fight their real roster" is met for the opposition
  route by P5d.1k and remains for withdrawal, concession, breach and
  NPC-vs-NPC.
- **P5d.6–P5d.7** have no dependency and keep their place.
- **P5f.2** (rival bids set the clock) depends on P5d.1o.
- **P5g.2** (field-HQ charter from the local house): the charter's grantor is
  the world's `planetary_ruler` personage (P5d.1a). Wording only.
- **P5g.3** (raidable HQs): becomes a conflict against the player's HQ with a
  travelling aggressor and §A discovery. The raid warning stop fires on
  `discovery_day` (D17). Depends on P5d.1m.
- **P5h.1** "settle a named grudge": the grudge is a personage `grudge` relation
  (P5d.1c). Wording only.
- **P5c content expansion**: unchanged scope. Cross-contract callbacks may link
  an `Actor` to a personage after P5d.1a; noted, not required.
- **P5e, P5g.1, P5g.4, P5h.2–3, P5i**: no dependency on this work; unchanged.

## Increments

Each row is its own approved plan and branch, green on the rule-72 gate. Every
row:

- adds at most one schema step;
- owes owner tests (rule 67), fixed-seed tests, refusal tests that consume
  nothing (rule 13), one injected-failure test per new compound operation
  (rule 69), adversarial persistence for each new table or column (rule 70),
  rule-58 fixtures for each new data family, and both smokes when a surface
  changes;
- updates the affected ARCHITECTURE/GAMEPLAY/docs/tui.md/docs/schema.sql/
  docs/modding.md sections.

"Evidence" names the specific acceptance proof beyond that floor. A "D"
prerequisite is a product-policy decision the increment's plan settles with
John before approval.

| Id | One bounded outcome | Prerequisites | Evidence |
| --- | --- | --- | --- |
| **P5d.2** (existing) | Unique NPC company names and logos | — | as its entry |
| **P5d.3** (existing) | Founding/dissolution logged; cored enemy hulls leave the roster | — | regression test first, as its entry |
| **P5d.1a** personage record | Every hiring world has a procedural `planetary_ruler` and every hiring faction a leader, persisted; `.politics` stream; REPL `who` | this design, D6, D7 | same seed → same rulers; adding `.politics` leaves other streams' values unchanged; load refuses a dangling seat |
| **P5d.1b** who's-who surface | TUI who's-who modal and query rows with the provenance label | 1a | query test; TUI smoke step |
| **P5d.1c** personage relations | `kin/liege/rival/ally/grudge` relations generated and shown | 1a | fixed-seed relation set; dangling endpoint refused |
| **P5d.1d** canon and authored rows | `personages.zon` with internal provenance, rule-58 validator and fixtures; §I canon restated from planning research; no player-facing provenance; schema v72 with its v71 migration; Sarna credit (D8) | 1a, D6–D8 | data-fixtures fail on each broken row; test-asserted counts by layer |
| **P5d.1e** conflict record | Monthly `runSchemes` opens conflicts from about 12 templates with the §A timeline, local and strike forces; NPC-only resolution; REPL `conflicts`; log lines. **Board unchanged.** | 1a, 1c | same seed → same conflicts and days; strike/discovery invariants; resolution writes world state |
| **P5d.1f** board from conflicts | Offers come only from conflicts under the §A posting rules; `conflict_id`, `side`, `on_station_by`, `close_day`; cause line; `TooLateToArrive`, `OppositeSide`; opposition = local/strike force | 1e | no offer without a conflict; no defender offer before `discovery_day`; close-day boundary; both refusals |
| **P5d.1g** news reach and Newswire | `newsReach` (absorbs the company-position rule), `NewsItem`, Newswire pane and `news`, for conflict open/discover/resolve | 1e | 99/100/101 ly; position-independence test; out-of-reach conflict still resolves |
| **P5d.4a** paid NPC black-market buys | NPC black-market draws debit the listing price and respect roster target and cash | P5d.3 | rule-68 regression first (cash unchanged after a draw today); refusal of an unaffordable draw consumes no `.market` draw beyond today's order; digest re-pin explained |
| **P5d.4b** roster bands | `band` on every company; `merc_bands.zon` (validated, fixtures); band-scaled seed (four lances, 12 companies, capital per D25); fill-to-target and readiness read band targets instead of the flat 8 | P5d.4a, D23–D25 | seed composition per band by fixed seed; eligibility at band target; data-fixtures fail each broken band row |
| **P5d.4c** dissolution safeguard | Dissolution only on cash < 0 **and** 12-month understrength **and** no active commitment; `understrength_since` persisted; logged cause | P5d.4b | low-BV company with cash survives; runway 11/12/13-month boundary; replacement still spawns; load refuses a future `understrength_since` |
| **P5d.1h** NPC operating base and location | Every NPC company has a base (§L1) and current world and a flat `ready_day`; base market reach for purchases (D21); shown in the company list. No movement yet | P5d.2, P5d.3, P5d.4b | seeded base fixed by seed; asymmetric two-base purchase test (rule 71); off-world buy not fieldable before arrival; load refuses an unknown world |
| **P5d.4d** hull condition and base repair | NPC hull condition record (§L2) written by battle and lost-field recovery; `repairPass` at base pricing with the player's labour owners and paying cash directly under §L3's cash bounds, with a per-band cash floor (`merc_bands.zon`, replaced by §L7's months-of-burn floor in 4f) standing in for the reserve; fieldable BV and readiness read condition | P5d.1h | recovered wreck returns damaged, not pristine; repair cost equals player owner for the same slot; capacity limit; a line-hull job spends into the floor but never below zero; a reserve-asset job stops at the floor; no condition change without a cause |
| **P5d.4e** parts procurement | `spares_cbills` stock bought at base reach; repair consumes spares; "awaiting parts" deferral | P5d.4d | shortfall defers the job with its cause; top-up never crosses the reserve floor |
| **P5d.1i** NPC movement | One `Movement` per company under the shared travel rule; status derived by one owner; return home | 1h | `arrive_day` equals the player rule for the same route; tamper refused on load |
| **P5d.1j** aggressor hires | Commitments with employer and mandate made during `preparing` with the arrival-by test; pay, transport fee and share; release and break | 1e, 1i | ineligible-late candidate excluded; foe/other-side excluded; dissolution breaks |
| **P5d.4f** operating ledger | `monthlyLedger`: commitment pay and transport share in; player-equivalent upkeep, payroll and transport fees out; reserve floor = months × burn | P5d.1j, P5d.4e | ledger sums equal the sum of named entries; an idle company's burn matches the player owners for the same hulls; floor blocks discretionary spend; an affordable line-hull repair spends into the floor but never takes cash below zero |
| **P5d.4g** cash-pressure ladder and sales | `sellHull` at real condition price; ladder steps 1–5 in order; dissolution liquidates through `sellHull` | P5d.4c, P5d.4f | each step fires only when the previous one was insufficient; never below minimum viable lances; sale price matches `hullPrice` for the stored condition; injected failure mid-ladder leaves state unchanged (rule 69) |
| **P5d.4h** post-contract recovery | Release → travel home → `refitting`; `ready_day` derived from projected backlog; §L9 recovery invariant | P5d.1j, P5d.4d, P5d.4e | §L9 fixed-seed recovery and its no-supply asymmetric twin; `ready_day` within `npc_refit_max_days` |
| **P5d.1k** present forces are the opposition | `forcesPresent` feeds `opforPool` and the briefing; counter-hire deleted; rival overlay links; late-arrival notice | 1f, 1j | asymmetric two-world locality (rule 71); company in transit not fighting; no draw at acceptance |
| **P5d.1l** defender reaction and late hiring | Discovery alerts, defender hires and escalation hires per D13/D14, each with a cause | 1k | hire only if it can arrive; escalation independent of the player |
| **P5d.1m** quiet-contract threats | Garrison/cadre (D3) threats as travelling child conflicts; stop on discovery | 1k | stop the day of discovery; opposition joins on arrival |
| **P5d.1n** intrigue and beats | `political_events.zon` beat and intrigue families; scheduled beats | 1c, 1g | beat order by (day, id); stored text survives a template edit |
| **P5d.1o** competition | NPC bids fill positions (`PositionFilled`, causes incl. `arrival`); a fill becomes a commitment | 1f, 1j | close-day priority; tie order; refusal consumes nothing |
| **P5d.1p** political decisions | In-reach, stake-bearing happenings raise personage-owned inbox decisions with deadline and default | 1g, 1n | stake/no-stake; P5a.7 day-before stop; default on ordinary advance |
| **P5d.4i** replacement reach and upgrades | Replacement through base reach and floor; one-for-one upgrades sold through `sellHull` | P5d.4g | upgrade strictly raises BV and keeps hull count; none below `reserve + margin`; none with a line backlog |
| **P5d.4j** earned growth and air | Band promotion/demotion with logged cause; automatic aerospace reserve replaced by an earned optional air lance | P5d.4i, D26 | promotion only after all criteria; demotion boundary; no air purchase below the band or margin |
| **P5d.4k** co-located recruiting | A rival based on or present at the player's world recruits a discontented person through the existing retention rules; the departure names the rival (P5d.4's added rule) | P5d.1h | asymmetric two-world test (rule 71); departure log names the company |
| **P5d.4l** NPC artillery (policy-gated) | Only if D26/D29 choose it: an architecture plan for NPC artillery ownership, then earned artillery growth | P5d.4j, D29 | defined by its own plan |
| **P5d.5** (existing) | Parity as its entry, minus the opposition route met by 1k | 1k | as its entry |
| **P5d content expansion** | Corpus growth toward the §H target; data only | 1d, 1n | corpus report |

No increment needs another increment's unlanded state beyond its listed
prerequisites, and no increment adds a recurring cost before the increment
that provides the matching income (4f after 1j).

**Delivery order:** P5d.2, P5d.3, 4a, 4b, 4c, 1a, 1b, 1c, 1d, 1e, 1f, 1g, 1h,
4d, 4e, 1i, 1j, 4f, 4g, 4h, 1k, P5d.5, 1l, 1m, 4i, 4j, 4k, 1n, 1o, 1p, 4l (if
chosen), content expansion, P5d.6–P5d.7. Two chains run side by side: the
company chain (P5d.2–4c) needs no political state, and the political chain
(1a–1g) needs no company state; they join at 1h. Each row's prerequisites, not
this list, are binding: an independent row may move earlier if John asks.

**First increment.** P5d.3 is the recommended first increment: it is a known
regression-first roster bug, it is a prerequisite of every company increment,
and it needs no policy decision. Then 4a (a second suspected defect,
regression first). P5d.1a remains the first political increment and needs D6
and D7.

## Requirement mapping

Every product direction and every clause of the previous ROADMAP P5d.1 and
P5d.4 entries maps to the section and increment(s) that own it. Where a clause
spans two increments, the row says which part each delivers. No clause is
removed.

| Requirement | Section | Increment(s) |
| --- | --- | --- |
| Direction 1 — each company keeps its own roster | §D, §L8 | 4b (band roster target); 1k (a present company fights its own roster) |
| Direction 2 — contracts come from employer-backed conflicts | §B, §C | 1e (conflicts); 1f (offers only from conflicts) |
| Direction 3 — garrison/cadre exception | §E | 1f (`stability` postings); 1m (threat emerges later) |
| Direction 4 — no post-acceptance counter-hire | §A, §D "Rival overlay" | 1k (counter-hire deleted) |
| Direction 5 — characters and political conflict, canon kept apart | §B, §H, §I | 1a, 1b, 1c, 1d |
| Direction 6 — progression without the player; news within 100 ly; news vs decisions | §K | 1e (progression); 1g (reach and news); 1n (beats and intrigue); 1p (decisions) |
| Direction 7 — NPC travel with cost; causal timing | §A, §D | 1h (location); 1i (movement); 1j (hires, transport fee); 1l (defender and late hires) |
| Direction 8 — documentation first; small increments | this document | the increment table |
| Direction 9 — NPC companies run as companies | §L | 4a–4l; 1h (base) |
| Direction 10 — scale and provenance | §B coverage, §H, §I | 1a (procedural rulers); 1d (canon and authored rows); content expansion |
| P5d.1 — shared world conflicts | §C | 1e |
| P5d.1 — typed opposing forces (faction, pirate or named merc company) | §A "opposing force", §E | 1f (faction local/strike forces); 1m (pirate and merc threats to quiet contracts); 1k (named merc companies present) |
| P5d.1 — player offers | §A, §C | 1f |
| P5d.1 — NPC commitments | §D | 1j |
| P5d.1 — location and transit | §A | 1h (location); 1i (transit) |
| P5d.1 — pay | §D | 1j (pay terms); 4f (pay credited through the ledger) |
| P5d.1 — readiness | §D, §L5 | 1j (readiness test for a hire); 4h (refit-derived `ready_day`) |
| P5d.1 — withdrawal | §D "Release" | 1j (commitment released at end or resolution); P5d.5 (doctrine-based battle withdrawal) |
| P5d.1 — breach | §D "Release" | 1j (commitment `broken` on dissolution); P5d.5 (concede or breach when unable to field) |
| P5d.1 — completion | §D "Release", §C resolution | 1j |
| P5d.1 — NPC companies bid on the offers the player sees | §G | 1o |
| P5d.1 — the board says who took it and at what price | §G | 1o |
| P5d.1 — a lost bid names its cause (rating, standing, price, speed) | §G | 1o (speed is `arrival`, the bidder's arrival day against the player's ETA) |
| P5d.4 — 12 companies / 16 active mechs / 50M | §L8 | 4b (D23–D25 set how the 50M applies per band) |
| P5d.4 — shared mech-market replacement | §L6 | 4b (band targets); 4i (base reach and upgrades) |
| P5d.4 — player-equivalent operating costs | §L7 | 4f |
| P5d.4 — 12-month understrength runway | §L7 | 4c |
| P5d.4 — contract income | §D, §L7 | 1j (commitment pay); 4f (credited through the ledger) |
| P5d.4 — liquidation only after no cash, understrength and no active contract | §L7 | 4c (the three-part condition); 4g (liquidation through `sellHull`) |
| P5d.4 — a co-located rival recruits a discontented person | §L1 | 4k |

## Product-policy decisions

**D1 is John's choice.** For D2–D29 no separate choice by John is recorded.
This design is written to the recommendation shown for each; the alternatives
are recorded and are not adopted here. An increment that lists a decision as a
prerequisite settles it with John in that increment's plan, and an increment
whose design depends on a different choice is re-planned.

- **D1 — travel.** *John's choice:* NPC companies travel under the player's
  rule (§A). *Rejected:* presence from the hire day; no NPC location.
- **D2 — conflicts persisted and first.** *Recommended:* yes (§C).
  *Alternative:* conflicts derived from offers (the replaced model).
- **D3 — scope of the "threat comes later" exception.** "No defensive contract
  without a looming threat" interacts with direction 3.
  - *Recommended:* garrison and cadre are the only exception (standing need,
    §E). Security and relief require a discovered threat. Riot comes from an
    insurrection conflict with a named local instigator.
  - *Alternatives:* add security to the exception; or all four garrison-class
    kinds.
- **D4 — "its own roster".** *Recommended:* hull roster, quality and a named
  commander personage. *Alternative:* named NPC pilots.
- **D5 — competition.** *Recommended:* P5d.1o with causes rating, standing,
  price and arrival. *Alternatives:* drop bidding; move it to P5f.
- **D6 — corpus.** *Recommended:* three labelled layers. Procedural rulers come
  first (1a), and canon and authored rows follow (1d). The target is about
  3,000 scenarios from about 60 templates. *Alternatives:* authored-only;
  canon-only. **John's choice (P5d.1a plan):** the recommendation —
  procedural rows first, in 1a; canon and authored rows in 1d. Until 1d
  every faction leader is procedural too, labelled `procedural`; 1d
  replaces the procedural leaders.
- **D7 — era and canon.** *Recommended:* canon is the 3025-01-01 state only;
  history is the sim's own. *Alternatives:* scripted canon milestones;
  fictional leaders only. **John's choice (P5d.1a plan):** the
  recommendation. 1a generates no canon and reads no year; how 1d's 3025
  canon applies to another start year is left to 1d.
- **D8 — Sarna text.** *Recommended:* restate facts, cite the URL per row, copy
  no prose, credit Sarna in 1d. *Alternative:* adapt GFDL text after a
  licensing decision. **John's choice (P5d.1d plan):** restate facts in
  project words and copy no prose, with no per-row URL, retrieval date or
  citation field and no validator check on sources; `README.md`
  "Attribution" and the ARCHITECTURE.md "Licensing note" credit Sarna
  (BattleTechWiki) as the source of the restated setting facts.
- **P5d.1d decisions. John's choices (P5d.1d plan):**
  - *Directions.* The game needs no external-source validation or citation;
    Sarna research is read-only planning input restated in project words;
    no player-facing provenance anywhere in the game UI (the founding
    wizard's company pane is the "Starting company"); every schema change
    includes a migration (applied to 1d; standing policy in
    [contract rule 51](engineering-contract.md#51-save-format-support-is-explicit)).
  - *Y1 — start years.* Every data row has an era window; stock rows are
    3025–3025. A campaign seats a row only in a start year its window holds;
    other start years are seeded exactly as before.
  - *K2 — kin.* Two data rows sharing a non-empty `family_key` are kin;
    procedural pairs stay K1; a data row and a procedural row never are.
  - *A1 — authored layer.* Authored leaders for MH, CIR and OBR, and an
    authored ruler for each of the 21 hiring worlds of industry 4 or more
    with no canon ruler.
  - *T1 — titles.* A data row shows its own title, a procedural row the
    generic one; no label marks either, and authored rows use styled titles
    too, so a styled title does not mean canon.
  - *M1 — migrated campaigns.* The v71 → v72 migration keeps every existing
    personage procedural with empty `key` and `family_key` and adds no data
    row; a new 3025 campaign gets the canon figures.
- **P5d.1e decisions. John's choices (P5d.1e plan):**
  - *E1 — the first template set.* The 12 opening templates of the plan,
    each buildable from today's roles, motives, relations, factions and
    world data: corporate seizure becomes `industrial_seizure` by a ruler,
    insurrection becomes `sponsored_unrest` by a hostile neighbour, and
    pirate predation is instigated by a `PER` world's ruler. `stability`
    moves to 1f.
  - *E2 — what `conflicts` shows before news reach.* Every conflict whose
    `discovery_day` has come, at any distance: threatened, open and
    resolved. A `preparing` conflict is shown nowhere; 1g adds reach and 1f
    ring-gated positions.
  - *E3 — log lines.* In `LogCategory.politics`: on discovery, on fighting
    starting and on resolution. Opening is not logged.
  - *E4 — NPC-only resolution.* The aggressor wins with chance `strike BV /
    (strike BV + local BV)` in basis points, decided by one `.politics`
    draw; commitments join the sum in 1j, and no faction weight is added.
  - *E5 — consequences of resolution.* Resolution writes `outcome` and moves
    the target world's `world_states` through the existing owner; personage
    consequences go to 1n.
  - *E6 — defender intelligence.* One flat lag range, shortened by a fixed
    `intel_chief_cut_days` when the defender faction has an
    `intelligence_chief` personage.
- **P5d.1f decisions. John's choices (P5d.1f plan):**
  - *F1 — the `stability` backer.* One `Conflict` record with a defender-only
    `standing` family (optional aggressor side, a `family` column, a
    `standing` status), not a separate entity, so every contract keeps one
    `conflict_id`.
  - *F2 — board cadence.* Positions post on the day their rule allows and
    close on their own `close_day`; the monthly clear ends; payday no longer
    names a board refresh, and a between-contracts `positions_posted` stop
    restates it as "new positions posted".
  - *F3 — board density.* Each side posts up to `positions_per_side`
    (`// TUNE`) positions per board from its kinds, under the existing
    per-HQ, per-kind and garrison-class caps.
  - *F4 — the opposition before `forcesPresent`.* An offer's opposition is
    the backer's stored force at posting (the `local_force` for an
    aggressor's position, the `strike_force` for a defender's, none for a
    standing need's); offers no longer roll their own.
- **D9 — playtest gate.** The gate entry is unchecked on `main`, and no verdict
  from John is recorded on `main`. *Recommended:* check it, worded as John's
  verdict, once John confirms it. *Alternative:* leave it for separate
  reconciliation. Until John confirms, the gate stays unchecked.
- **D10 — news reach.** *Recommended:* a fixed 100 ly from every HQ and every
  company presence. *Alternatives:* `max(news_reach_ly, influenceLy)`; HQs
  only.
- **D11 — does news stop time?** *Recommended:* no; only decisions stop.
  *Alternative:* `major` news in reach stops.
- **D12 — threat intelligence and discovery.**
  - *Recommended:* discovery = the earlier of an intelligence lag after T0
    (shortened by defender intelligence) and a last-leg detection warning. It
    never depends on the player. The player sees aggressor recruiting in their
    rings and learns of the threat with the defender.
  - *Alternatives:* defender knows at T0 (no surprise); detection-only (always
    short notice); a player intelligence asset (HPG/spies) that reveals
    `preparing` conflicts early (a later item).
- **D13 — defender reaction on discovery.**
  - *Recommended:* alert the local force, post defender positions, and hire NPC
    companies that can arrive by the strike day.
  - *Alternatives:* positions only (no NPC defender hires); add a house
    reinforcement force that travels from the nearest own world (mirrors D19).
- **D14 — emergency late hiring.**
  - *Recommended:* a monthly escalation hire during `open` fighting, each with
    a cause beat, joining only on arrival.
  - *Alternatives:* none after discovery; or unlimited hiring until resolution
    (more volatile).
- **D15 — what posts when, and board cadence.**
  - *Recommended:* aggressor positions from T0, defender positions from
    discovery, and garrison/cadre any time. Positions post daily with their own
    close day (ETA + grace). The monthly clear ends. Late acceptance is refused
    `TooLateToArrive`.
  - *Alternatives:* keep the monthly board and require conflicts to plan at
    least 1 month + max travel ahead; or allow late arrival with reduced pay
    instead of a refusal.
- **D16 — one side per conflict.** *Recommended:* refuse the other side's
  positions while holding one (`OppositeSide`). *Alternative:* allow
  double-dealing with a standing penalty when found out.
- **D17 — HQ raids (P5g.3) use the conflict timeline.** *Recommended:* yes; the
  warning stop fires on discovery, and the raider travels. *Alternative:* keep
  P5g.3 as written (contact-window warning only).
- **D18 — NPC travel cost.** *Recommended:* time plus a per-jump fee, with the
  employer's transport share fixed at hire. *Alternative:* time only (money
  waits for P5d.4f).
- **D19 — the aggressor's own house force.** *Recommended:* yes, a
  `strike_force` from the aggressor faction travels from its nearest world and
  sets `strike_day`. *Alternative:* aggressors fight only through hired
  companies and the player (strike day then set by the first hire's arrival).
- **D20 — what an NPC base is.** *Recommended:* a base world with a band-set
  repair capacity; no facility construction. *Alternatives:* NPC companies
  build HQ facilities like the player (large scope); no base (repair
  anywhere, which loses the reason to go home).
- **D21 — NPC market reach.** *Recommended:* purchases only from listings on or
  within `npc_market_reach_ly` of the base, off-world buys arriving by the
  shared travel rule. *Alternatives:* keep today's galaxy-wide reach (no
  locality); the player's `Hq.influenceLy` rings.
- **D22 — parts model.** *Recommended:* an abstract spares stock in C-bills.
  *Alternative:* per-part inventories like the player (much larger state and
  test surface).
- **D23 — "four fighting lances" per band.** *Recommended:* every band targets
  four lances (16 meks, matching P5d.4's approved 16-mek target); bands differ
  by weight mix, quality, capital and growth rights; vehicles substitute only
  below `band_4`. *Alternative:* lances scale with band (1–2 skull = 1–2
  lances … 5 skull = 4 lances plus support), which conflicts with the approved
  flat 16-mek target unless John replaces it. **John's choice (P5d.4b plan):**
  the recommendation — four lances for every band, vehicles fill line positions
  only below `band_4`.
- **D24 — band scale.** *Recommended:* four bands `1–2`, `3`, `4`, `5` skulls as
  an intrinsic tier, distinct from the per-contract skull rating computed by
  `skulls.zig`. *Alternatives:* five whole-skull bands; half-skull bands
  matching `skulls.zon`. **John's choice (P5d.4b plan):** the recommendation —
  `band_1_2`, `band_3`, `band_4`, `band_5`.
- **D25 — seed capital and population.** *Recommended:* keep 12 companies;
  50M is the `band_4` capital, other bands scale (`// TUNE`), with a fixed
  seed band mix. *Alternative:* flat 50M for every band, as the P5d.4 entry
  literally says. **John's choice (P5d.4b plan):** the recommendation — 12
  companies seeded 3 / 4 / 3 / 2 across `band_1_2` / `band_3` / `band_4` /
  `band_5`, with capital 20M / 35M / 50M / 75M C-bills (`// TUNE`,
  project-tuned, `data/tables/merc_bands.zon`).
- **R1 — replacement companies.** A replacement forms at the lowest band,
  `band_1_2`, with that band's capital, and `merc_replacement_cbill_floor` is
  deleted (one capital number per band). *Alternative:* `band_1_2` with the 5M
  floor kept. **John's choice (P5d.4b plan):** the first. Promotion and demotion
  stay in P5d.4j.
- **C1 — "active commitment" before P5d.1j.** *Recommended:* a company has an
  active commitment when some rival naming it (`Rival.merc_company_id`) sits on
  a contract that `isRunning()`, the test `priorRival` already uses, owned by
  one predicate (`rivals.mercCompanyCommitted`) whose body P5d.1j replaces with
  commitment records. *Alternative:* no company has a commitment until P5d.1j.
  **John's choice (P5d.4c plan):** the recommendation.
- **C2 — no ordinary-play dissolution until NPC costs.** With nothing able to
  take NPC cash below zero before P5d.4f, the §L7 three-part rule means no
  company dissolves or is replaced in play until P5d.4f/4g add costs; a company
  that lost its hulls stays, keeps its cash and buys back toward its band
  target. *Alternative:* keep fieldable-BV insolvency as an interim fourth
  dissolution cause (contradicts §L7, needs a design amendment). **John's
  choice (P5d.4c plan):** the recommendation, as the design orders it.
- **P1 — a leader for `PER`.** `PER` ("Periphery / pirates") hires, but it is
  a catch-all bucket, not a polity, and §B models a pirate organization as
  its own power led by a `pirate_lord`. *Recommended:* the hiring factions
  other than `PER` each get one `faction_leader`; `PER` gets none, and its
  worlds still get planetary rulers. *Alternative:* every hiring faction,
  `PER` included, with a "Periphery / pirates" leader seated on Galatea.
  **John's choice (P5d.1a plan):** the recommendation.
- **S1 — what P5d.1c covers.** The §B "Landed in P5d.1a" note gave `key`,
  `family_key`, `loyalty`, relations and the other roles to 1c, while the
  increment row and `TODO.md` scope 1c to relations. *Recommended:* 1c is
  relations only; loyalty is the liege relation's weight; `key`,
  `family_key` and the other roles go to 1d. *Alternative:* 1c also
  generates procedural heirs and family members with new roles. **John's
  choice (P5d.1c plan):** the recommendation.
- **K1 — what makes two personages kin.** *Recommended:* two personages of
  the same faction who share a last name are kin, one relation per pair;
  kin never crosses factions. *Alternatives:* kin pairs drawn at random
  within a faction; no kin until 1d's canon dynasties. **John's choice
  (P5d.1c plan):** the recommendation.
- **R1 (relations) — who holds rivalries, alliances and grudges** (the
  P5d.1c plan's R1, distinct from the replacement-company R1 above).
  *Recommended:* only planetary rulers, toward another ruler within
  `relation_reach_ly` (60 ly, two jumps, `// TUNE`): a rival of the same
  faction, an ally of a faction neither side lists as a foe, a grudge
  against a ruler of a faction either side lists (`factions.zon` `foes`).
  Leaders hold only kin and receive lieges. *Alternative:* leaders also hold
  grudges against hostile leaders. **John's choice (P5d.1c plan):** the
  recommendation.
- **D26 — air and artillery growth.** *Recommended:* air is earned (band and
  cash margin) and replaces today's automatic aerospace reserve; artillery is
  deferred to D29. *Alternatives:* keep the automatic air reserve; allow both
  from `band_4`.
- **D27 — NPC salvage.** *Recommended:* a company on a commitment keeps its
  salvage share of NPC-side wrecks as damaged hulls (feeds §L5).
  *Alternative:* no NPC salvage; wrecks follow today's market dispersal only.
- **D28 — how much NPC finance the player sees.** *Recommended:* a cash bucket
  (healthy / stretched / in distress) and strength vs target, never exact
  C-bills. *Alternatives:* exact cash; nothing.
- **D29 — NPC artillery at all.** *Recommended:* not in P5d; revisit after 4j
  with a separate architecture plan, because NPC artillery would need
  ownership outside the player-scoped formation records the loader enforces.
  *Alternative:* an abstract artillery battery contributing BV only.

## Implementation choices (planner-owned; not decisions for John)

Each increment plan may refine these under the contract:

- new behaviour in new modules (`npc_upkeep.zig`, `npc_finance.zig`) called by
  `merc_lifecycle.zig`, not appended to it (rules 76, 77);
- NPC condition stored as `market.HullCondition` fields in one new table keyed
  by hull id; repair priced by the existing `maintenance` labour/hours owners
  (rule 3);
- markets-phase order: repair, spares, ledger and ladder, then the existing
  lifecycle buy, all monthly on the 1st, by `MercCompanyId` (rule 17);
- draws only on existing `.rivals` and `.market` for §L; `.politics` only for
  the political chain;
- one schema step per state-adding increment, numbered at its own base;
- exact TUI keys, query row shapes and log wording per increment against
  `docs/tui.md` and rule 39.

## Risks

- **Increment count.** There are 28 new increments (P5d.1a–p, P5d.4a–l) plus
  moved P5d.2/3/5/6/7. Each lands a visible, testable invariant. Optional
  surfaces (1b, 1n, 1p) can be reordered later without breaking prerequisites.
- **Board change in 1f.** Daily posting with close days changes the board's
  monthly rhythm and P5a's "board refresh" stop. The 1f plan restates the stop
  as "new positions posted", subject to D15.
- **Travel makes far conflicts unreachable.** With 30 ly jumps (7-day
  recharge), a distant conflict's positions close before far HQs can arrive.
  That is the intended cost. Board density is `// TUNE` in 1f.
- **Simulation cost.** Open conflicts and movements are capped
  (`tuning.politics.max_open_conflicts`, `// TUNE`). Due-movement and due-beat
  iteration is ordered and bounded.
- **Opposition gap between 1f and 1k.** From 1f until 1k, the opposition is
  local and house forces only, and the old counter-hire still runs. 1k deletes
  it. The 1f plan states this, and no increment re-adds it.
- **Canon drift.** Canon personages can meet non-canon fates after 3025 (D7).
  No label marks them as canon.
- **Licensing.** GFDL text is not copied into the GPLv3 tree (D8). The
  summarizing tool's extraction could be wrong; the game makes no claim of
  source accuracy and carries no citation.
- **News volume.** 100 ly around several HQs covers a large region. Severity
  and a per-day digest cap (`// TUNE`) keep it readable.
- **Stale reach.** Reach is fixed on the public day and never back-filled. This
  is intended and stated in the Newswire help.
- **Pinned digests** move in most increments. Each reviewer confirms there is
  no other cause.
- **NPC economy balance.** Costs (4f) and the ladder (4g) can make companies
  churn far more than today. Each plan includes a fixed-seed 24-month
  population run reporting dissolutions and band mix; a result far outside
  John's expectation is a tuning finding, not a reason to weaken §L9.
- **Market pressure.** 12 companies at 16 meks plus upgrades compete with the
  player for the same listings (shared market is P5d.4's approved rule). 4b's
  plan reports listing depletion on a fixed seed.
- **Suspected defect.** The unpaid NPC black-market draw is inferred from the
  absence of any `cbills` write in `black_market.zig`; 4a starts with a
  regression test, and if another owner already charges it, 4a reduces to the
  target check only.
- **Design-doc mismatch.** `docs/p2-conventional-combat-design.md` §NPC Policy
  claims NPC repair through P2 owners that do not exist; 4d updates that
  section when NPC repair lands.

## Non-goals

- Strategic map, territorial ownership change, or scripted canon timeline
  (unless D7 picks them).
- Desktop OS notifications.
- Named NPC pilots and NPC-vs-NPC tactical battles (P5d.5 scope).
- Mid-jump reversal of NPC movement; NPC interception en route.
- Per-part NPC inventories, NPC technicians as people, NPC HQ facility
  construction (unless D20/D22 choose them).
- NPC artillery before D29 and its own architecture plan.
