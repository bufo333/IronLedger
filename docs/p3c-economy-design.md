# P3c Economy Design Approval — Living Rosters, Rival Pools, Market Throughput

**Status:** Approved design (mech-economy design-approval increment).

Grounded in the code and data state at base commit
`ba5e0f80f4a34aa380a19c4bd333f9027aa3302c`. Commits no code and changes no schema.
Extends the hull-lifecycle subsystem approved in `docs/p3c-hull-lifecycle-design.md`:
that document gives every hull a persisted identity, combat record, maintenance log and
ownership chain; this document gives the hulls a world to flow through — finite faction
and rival rosters, slow manufacturing, battlefield attrition and salvage, and a market
whose supply is governed by faction conflict.

No BattleTech construction, composition or balance value is invented here. Any value
whose source is unverified at design time is marked `// TUNE` or "TBD — sourced at
implementation". The owner has pointed to https://battletech.com/downloads/ (force
sheets) as a source for faction compositions; specific chassis weights, replenishment
rates, operational-need sizes and insolvency thresholds are TBD pending verification
from that source or TechManual/Field Manual references during the owning sub-increment.

---

## §1 Scope and owner decisions

The following decisions were made by the project owner and are recorded here as
authoritative. They are not re-opened by implementation.

1. **Living faction rosters.** Every major faction has a finite hull pool — persisted
   `HullInstance` records owned by that faction. Hulls flow from the faction roster to
   the open market only when the faction has a surplus. Hulls committed to battle are
   drawn from the pool; destroyed hulls are gone; salvaged hulls transfer ownership.
2. **Rival merc companies.** The world has a fixed, deterministically-seeded set of
   independent **merc companies**, each owning a hull pool under the same ownership model
   as a faction, subject to attrition and insolvency. A P4i "rival" is a *relationship
   status* an arc attaches to one of these merc companies, not a separate entity. The
   entity boundary this implies is recorded in §8 (design revision, supersedes the
   RivalRoster framing of §2 where they differ).
3. **Market throughput governed by faction conflict state.** Factions under pressure
   replenish their own roster first, so surplus flow to the market drops. World state —
   faction conflict intensity, already represented via P4i `world_state`
   (`src/domain/world_state.zig`) — governs the throttle.
4. **Slow, manufacturing-only replenishment.** Each faction can only manufacture the
   chassis it historically produces (the 3025 lostech era; many designs are near-lost
   tech). The replenishment rate is very slow. A chassis a faction does not manufacture
   can only enter its roster through battlefield salvage (which factions also perform).
5. **Mechs only.** Conventional vehicles (trucks, MASH, carriers, etc.) are out of scope
   for the economy. The roster model tracks battlemech `HullInstance` records only.

This document is the authoritative record of these decisions and of the entity-model
boundary in §2. Where it conflicts with an earlier phrasing of P3c.4's "market
integration", this document governs.

---

## §2 Entity model

> Revision (P3e.5 prerequisite): the pool owner named 'RivalRoster' below is a world
> **merc company**, not a P4i story rival. The collection and its key are renamed per §8.
> The FactionRoster model and the HullInstance current-owner model are unchanged except
> that the `.rival` owner kind is renamed to `.merc_company` (§8.F). Keep this section's
> numbering: downstream code cites §2.

The economy adds two persisted roster entity families and extends two existing records.
It introduces no new world-state dimension and reuses the existing RAT.

### FactionRoster

One roster per major faction. A faction is identified by its existing stable string key
(`src/domain/faction.zig` `FactionRow.key`, e.g. `"LC"`, `"DC"`), consistent with
`faction_standing` and `world_states`, which are already keyed by string. The roster
holds:

- the faction key it belongs to;
- the set of `HullInstance` records the faction owns (its hull pool);
- the chassis the faction can manufacture (stable `base_key` references into
  `data/chassis.zon`), sourced from faction data (§3);
- a replenishment rate (hulls per month — very slow; the specific number is TBD —
  sourced at implementation, `// TUNE`);
- a conflict sensitivity (how sharply conflict reduces surplus flow — TBD, `// TUNE`).

The roster's identity key, whether a numeric `FactionId` typed id is introduced, and the
exact persisted shape are an implementation decision. **Recommended:** key the roster by
the existing faction string key (the `StringArrayHashMapUnmanaged` precedent of
`faction_standing`/`world_states`), deferring a numeric `FactionId` unless persistence or
performance later requires one. No `FactionId` exists today. This recommendation is
carried to implementation-approval time and is not a blocker for this design approval.

### RivalRoster

One roster per rival company, foreign-keyed to the existing `RivalId`
(`src/domain/rival.zig`, `GameState.rivals`). It holds:

- the rival company id it belongs to;
- the set of `HullInstance` records the rival owns (its hull pool);
- an insolvency threshold — the minimum battle value the rival must field to take a
  contract (the specific value is TBD — sourced at implementation, `// TUNE`).

A rival company and a faction share one ownership model: both own `HullInstance` records,
both draw from their pool for battle, both lose destroyed hulls, both gain salvage.

### HullInstance ownership extension

The economy needs to answer "who owns this hull right now?" for every persisted hull —
owned units, market listings, faction pools, rival pools, and destroyed wrecks. The
current owner is modelled as two fields on `HullInstance`:

- `owner_type` — one of `player`, `faction`, `rival`, `market`, `destroyed`;
- `owner_id` — the owning entity's identity under that type (the player outfit, a faction
  key, a `RivalId`, a market listing, or none for destroyed). Whether this is a typed
  union or a type-tag plus an id column is an implementation decision following the
  established `stock.owner_kind`/`owner_id` precedent; this design fixes only the owner
  types above and their meaning.

This current-owner pair is distinct from and complements the `HullOwnershipHistory`
provenance chain delivered by P3c.4: `HullOwnershipHistory` is the append-only event log
of past owners (from_day/to_day/acquisition_type), while `owner_type`/`owner_id` is the
single current owner that the economy reads and writes each time a hull changes hands.
P3c.4 remains the owner of the provenance chain; the economy (P3e) adds the current-owner
fields and keeps the two consistent (a change to the current owner appends a provenance
row).

### Market integration

The market already lists hulls (`GameState.market_listings`, 9C.3 persisted listings;
the hull-lifecycle design makes a listed hull a `HullInstance` at listing time). The
economy extends the **source** of those listings: a faction with surplus places hulls
from its roster onto the open market (ownership moves faction → market). It does not add
a second market or listing path; it feeds the existing one. The monthly surplus
calculation and its conflict throttle are §4.

---

## §3 Faction data

Faction manufacturing and economy tuning live by extending the existing single owner of
faction identity, `data/tables/factions.zon` (`src/domain/faction.zig` `FactionRow`),
rather than a new data family. `factions.zon` is overlay-moddable under
`zig build -Ddata=<dir>` (which covers `data/*.zon` and `data/tables/*.zon`); a new
`data/factions/*.zon` directory would duplicate faction identity and fall outside the
overlay set, so it is rejected. The new `FactionRow` fields are:

- `manufacturing_chassis` — the list of chassis `base_key`s this faction produces
  (references into `data/chassis.zon`); specific lists are TBD — sourced from the owner's
  cited force sheets / TechManual at implementation;
- `base_replenishment_rate` — hulls per month, very slow (`// TUNE`, TBD);
- `conflict_sensitivity` — how much faction conflict reduces surplus flow (`// TUNE`,
  TBD).

### The Random Assignment Table (RAT)

A RAT defines which designs a faction fields, by weight class, as a weighted
distribution. **It already exists**: `data/tables/rat.zon` (`src/domain/rat.zig`
`RatRow`), one row per faction with `light`/`medium`/`heavy`/`assault` lists of chassis
`base_key`s where repetition weights a design. The economy reuses this table to seed
faction rosters at campaign start (§4). No new RAT file is created. If per-era brackets
beyond the current single-era table are needed, that extension is a data-only change to
`rat.zon` with values TBD — sourced at implementation.

No specific chassis weight, faction composition, or roster size is invented in this
document. All such values are TBD pending verification against the owner's cited source
(https://battletech.com/downloads/) or TechManual/Field Manual references.

---

## §4 Lifecycle triggers

- **Campaign start — roster seeding.** Faction (and rival) rosters are seeded
  deterministically from the campaign seed through a pure `src/gen/` function reading the
  existing RAT (`rat.zon`) for weight-class distribution and the faction manufacturing
  data (§3). Determinism uses a named RNG stream (`src/sim/rng.zig`); the sim core stays
  pure (contract rules 2, 6). Starting roster sizes are TBD — sourced at implementation.
- **Battle.** The opposing force for a contract is drawn from the employing/enemy
  faction roster (or the rival roster for a rival contract) rather than mirrored from the
  player. Post-battle, in the same failure-atomic aftermath path that already writes hull
  status (hull-lifecycle P3c.2): a destroyed, unsalvaged hull becomes
  `status = permanently_destroyed` and `owner_type = destroyed`; a salvaged hull
  transfers ownership to the salvaging company (player or rival); a surviving hull
  returns to its owner's roster. This layers onto the existing OpFor model
  (`src/domain/opfor.zig`, 12D.5) and salvage recovery (12D.3); the design does not add a
  parallel battle or salvage path. On the pool path the salvage decision is mandatory
  (turn-blocking `salvage_priority`); a held-field win always defers salvage to the
  inbox so the player chooses which drawn wreck to take; the unchosen wrecks are
  finalised as permanently_destroyed. Lost-field destroyed hulls stay enemy-owned and
  active (pool-removed only). The exchange clause routes all destroyed drawn hulls to
  the employer faction immediately, with no inbox decision.
- **Market — monthly surplus.** Monthly, each faction computes its surplus: hulls owned
  beyond its operational need. Surplus hulls flow to the open market as listings (§2),
  ownership moving faction → market. The flow is throttled by the faction's conflict
  intensity, derived from the world state it is engaged on (`src/domain/world_state.zig`
  dimensions — e.g. `employer_control`, `enemy_influence`, `infrastructure_strain`); a
  faction under pressure replenishes its own roster first and sends little or nothing to
  market. Operational-need sizing, the surplus formula and the conflict-throttle curve
  are TBD — sourced at implementation (`// TUNE`).
- **Rival insolvency.** When a rival roster's fieldable battle value falls below its
  insolvency threshold, the rival can no longer meet contract battle-value requirements
  and goes inactive (cannot take contracts). The exact trigger — fieldable BV below the
  threshold for the rival's remaining pool — and whether insolvency is terminal or
  recoverable are TBD — sourced at implementation; the trigger condition is "fieldable
  roster BV < insolvency_threshold".

---

## §5 Delivery order (sub-increments)

Each sub-increment is independently correct, one branch, green on the applicable rule-72
gate, reaching local `main` before the next begins. The economy is delivered as ROADMAP
stage **P3e**, prerequisite **P3c** (the hull entity, P3c.1–P3c.2, plus the P3c.4
ownership chain that the current-owner fields extend). This design approval is the
prerequisite for all of it.

- **P3e.0 — Design approval (this document).** Prerequisite for every item below.
  Commits no code.
- **P3e.1 — Faction manufacturing data.** Extend `data/tables/factions.zon`
  (`FactionRow`) with `manufacturing_chassis`, `base_replenishment_rate`,
  `conflict_sensitivity`; values sourced and marked `// TUNE`/TBD. Data-only; whether to
  introduce a numeric `FactionId` typed id is decided here (recommended: keep the string
  key). No schema change if the roster is keyed by the string key.
- **P3e.2 — HullInstance current-owner fields.** `HullInstance` gains `owner_type` and
  `owner_id`; schema change and migration numbered forward from the version on local
  `main` at branch start; kept consistent with the P3c.4 provenance chain.
- **P3e.3 — Faction and merc-company roster persistence.** The roster collections,
  `field_persistence` entries, digest coverage, and golden round-trip proof; schema
  change. The world-actor entity split renamed the planned rival roster to
  `merc_company_rosters` before delivery.
- **P3e.4 — Campaign-start roster seeding.** Deterministic `src/gen/` seeding from the
  campaign seed, the RAT (`rat.zon`) and the faction manufacturing data; named RNG
  stream; pure core.
  World-actor revision (§8): before P3e.5, a dedicated increment introduces the
  `MercCompany` entity and `MercCompanyId`, renames `rival_rosters` →
  `merc_company_rosters` and rekeys it, and renames the HullInstance `.rival` owner kind
  to `.merc_company` (schema migration). P3e.5 then seeds merc companies at campaign
  start and draws OpFor from faction, merc-company, and pirate (PER) pools. Exact
  increment numbering is fixed when the owner dispatches it.
- **P3e.5 — Battle aftermath integration.** **Delivered:** OpFor force drawn from
  faction, world-merc-company, or PER pools; post-battle destroyed/salvaged/surviving
  ownership and status updates run in the existing failure-atomic aftermath path.
- **P3e.6 — Market surplus throughput.** Monthly surplus calculation flowing faction
  surplus to market listings, throttled by `world_state` conflict intensity.
  **Delivered** (schema v56; `src/sim/faction_surplus.zig`; `TODO.md` line 80 checked off).
- **P3e.7 — Rival insolvency.** The fieldable-BV-below-threshold inactive trigger and its
  surfaced read-only state.
  **Delivered** (derived predicate, no schema change; `tuning.generation.merc_company_insolvency_bv`;
  owners `mercCompanyFieldableBv`/`mercCompanyInsolvent` in `src/sim/rivals.zig`;
  `RivalRow.insolvent` read-only on Operations; branch `sim/p3e-7-rival-insolvency`).

Sub-increment boundaries, exact schema version numbers, and whether P3e.5/P3e.6 touch the
frontend boundary (and therefore require the smoke scripts) are fixed at each
sub-increment's own implementation-approval time, not asserted here.

---

## §6 Hull-lifecycle increments unchanged by the economy

The economy design does not block the remaining hull-lifecycle increments; they can ship
before any economy implementation:

- **P3c.3 (maintenance log and repair/modify commands)** — independent; unaffected.
- **P3c.5 (company-generation seeded history)** — independent; unaffected.
- **P3c.6 (mech detail modal, queries, verbs)** — independent; unaffected. It may later
  surface economy ownership read-only, but it is not blocked by the economy.

**P3c.4 (ownership chain)** is re-scoped: it owns the hull **ownership-history/provenance
chain** (a hull-lifecycle concern). The market-supply behaviour formerly bundled under
P3c.4's "market integration" is absorbed into the P3e economy (§2, §4). P3e.2's
current-owner fields build on P3c.4's provenance chain and keep the two consistent.

---

## §7 Approval checklist

This design-approval increment is approved when the owner confirms:

- [ ] Scope and owner decisions (§1): five decisions recorded, no value invented.
- [x] Entity model (§2): Faction and merc-company rosters, the HullInstance
      current-owner extension (distinct from P3c.4 provenance), and market-source integration.
- [ ] Faction data (§3): manufacturing data extends `factions.zon`; the RAT is the
      existing `rat.zon`; all specific values TBD pending source verification.
- [x] Lifecycle triggers (§4): campaign-start seeding (P3e.4/P3e.5 ✓), battle
      draw/attrition/salvage (P3e.5 ✓), monthly conflict-throttled market surplus
      (P3e.6 ✓), merc-company insolvency (P3e.7 ✓).
- [ ] Delivery order (§5): P3e.0 design approval first, then P3e.1–P3e.7, each
      independently correct, prerequisite P3c.
- [ ] Hull-lifecycle increments (§6): P3c.3/P3c.5/P3c.6 unblocked; P3c.4 re-scoped to the
      ownership chain.
- [ ] World-actor model (§8): design revision recorded; merc-company entity,
      rival-as-status boundary, PER pirate finding, campaign-start seeding, OpFor
      sourcing, rename/rekey inventory, and delivery-order impact.

Approval authorizes P3e.1 to begin; it commits no code.

---

## §8 World-actor model (design revision)

This section records owner decisions made after §1–§7 were approved and after P3e.1–P3e.4
shipped. Where it conflicts with the "Rival merc companies" framing of §1 decision 2 or the
"RivalRoster" naming of §2, this section governs. It changes no shipped behaviour by itself;
it defines the entity model the remaining increments (the pre-P3e.5 entity split, P3e.5,
P3e.7, and P3f) implement. The P4i arc, standing, and recurrence machinery
(`src/sim/rivals.zig`, `src/domain/rival.zig`) is unaffected in behaviour.

### §8.A The world merc-company entity

A "rival" is a *relationship status*, not an entity type. The persistent world actor is an
independent **merc company** that exists in the world whether or not any story has selected
it. The same company can be OpFor on one contract and an ally on another; becoming a "rival"
is the P4i arc system choosing it for story beats (§8.B).

**Decision: introduce a new entity `MercCompany` with its own typed id `MercCompanyId`**
(`enum(u32) { none = 0, _ }`, the established typed-ID pattern in `src/domain/types.zig`).
`MercCompany` owns the durable company identity: archetype key (into
`rival_archetypes.zon`), generated commander name, unit name, home/affiliation faction key,
and operational doctrine — the identity fields that today live on `Rival`
(`src/domain/rival.zig`). The existing `RivalId` is **not** reused as the company id,
because `RivalId` already names the P4i status overlay and its arc machinery; conflating the
two is exactly the misnomer this revision removes.

The hull-pool infrastructure delivered by P3e.3 is currently keyed by `RivalId`
(`GameState.rival_rosters`) and the HullInstance `.rival` owner kind carries a `RivalId`
(`src/domain/hull_instance.zig`, schema v52/v53). Under this model that keying moves to
`MercCompanyId`; the full rename/rekey inventory is §8.F. No numeric `FactionId` is
introduced — faction rosters stay keyed by the existing `FactionRow.key` string, as §2
already recommends.

One open sub-question, deferred to the entity-split implementation increment and marked
`// TBD`: whether the identity fields currently duplicated on `Rival` (commander name, unit
name, archetype, doctrine, faction key) are *removed from* `Rival` and read through the
`MercCompanyId` FK, or retained on `Rival` as a snapshot. This is a persistence/migration
shape decision, not a product-behaviour decision; it does not change the boundary in §8.B.

### §8.B The P4i "rival" as a status overlay

A P4i `Rival` record becomes a *relationship overlay* attached to a `MercCompany` that
already exists. Arc introduction (`instantiateRivals`/`introduceRivals` in
`src/sim/rivals.zig`) means "this world merc company has now been chosen for story beats",
not entity creation. The boundary:

- **On `MercCompany` (identity, world-persistent):** archetype key, commander name, unit
  name, affiliation faction key, doctrine, and the owned hull pool (§8.F). Exists from
  campaign start (§8.D).
- **On the `Rival` overlay (relationship, story-scoped):** `standing` (clamped
  `rival_min..rival_max`), derived `RivalStatus`, `encounters`,
  `last_cause`/`last_cause_day`, `recurring`, the introducing `contract`, and `side`
  (employer/enemy for that contract). It carries a `MercCompanyId` FK to the company it is
  a status for.

The standing/recurrence rules (`statusFor`, `priorRival`, `adjustRival`,
`outcomeRivalStandingDelta`, `finaleRivalStandingDelta`) are unchanged; their recurrence
lookup, today keyed by `(faction_key, archetype_key)`, is expressed against the merc company
the overlay points at. // TBD: whether recurrence keys directly on `MercCompanyId` is
settled at the entity-split increment.

### §8.C Pirates / bandits / non-aligned — verified: the `PER` faction key

Verified against `data/tables/factions.zon` and `data/tables/rat.zon` at the base commit:
pirates/bandits/near-Periphery are **already a thin faction**, key `"PER"` ("Periphery /
pirates"). It has:

- a `FactionRow` in `factions.zon` with an **empty** `manufacturing_chassis` (salvage-only
  per §1 decision 4) and `replenishment_hulls_per_year = 0`;
- a real RAT row in `rat.zon` (light/medium/heavy/assault pools);
- existing OpFor handling: `src/domain/opfor.zig` `roll(...)` special-cases
  `enemy_key == "PER"` with a pirate quality modifier.

No new faction key is invented and no separate pirate entity is needed. The third OpFor
category is drawn from the `PER` faction pool exactly like a house faction, with a different
*lifecycle*: because PER manufactures nothing, its pool is replenished only by salvage, never
by manufacturing. Because P3e.4 seeds only factions with nonzero
`replenishment_hulls_per_year`, PER was not seeded at campaign start until P3e.5b-1.

**Resolved — owner decision 3 (P3e.5b-1):** PER receives a flat-constant seeded starting
pool at campaign creation (`pirate_pool_hulls` in `tuning.generation`, currently 16 `// TUNE`),
seeded by `src/sim/roster_seed.zig` `seedPirateRoster` in the same `execCreateCommander`
founding path as faction and merc-company seeding.

**Resolved — owner decision 4 (P3e.5b minor-Periphery manufacturing):** TC, MOC, OA, MH,
CIR, and OBR now receive campaign-start faction pools via non-zero
`replenishment_hulls_per_year = 4` and provisional RAT rows (`// TUNE`; per-faction
composition TBD from force sheets). CS stays unseeded (`hires = false`, no open 3025
manufacturing). PER keeps its flat `seedPirateRoster` pool.

### §8.D Campaign-start merc-company seeding

A fixed set of independent merc companies is seeded deterministically at campaign creation
(`create_commander`), in the same founding path that P3e.4 uses to seed faction hull pools
(`src/sim/roster_seed.zig` orchestrating `src/gen/roster_gen.zig`). They are **not** created
by arc events; arcs select from this existing pool (§8.B).

- **Archetype source:** the existing `rival_archetypes.zon` (`src/domain/rival.zig`
  `table`). No new data family.
- **Count:** a fixed campaign-start company count — `// TBD`, sourced at implementation;
  not invented here.
- **RNG:** company identity is generated on the existing `.rivals` named stream (the stream
  `generateRival` already uses, so determinism and stream-isolation guarantees carry over);
  each seeded company's hull pool is rolled on the `.rosters` stream P3e.4 introduced. Draw
  order and whether a distinct stream is warranted are fixed at implementation and must
  preserve the pure-core / named-stream contract (rules 2, 6, 57).

**What changes relative to P3e.4:** P3e.4 seeds only faction pools and explicitly defers
rival/company seeding ("no rivals exist at campaign creation"). Under this model the founding
path additionally (a) instantiates the fixed set of `MercCompany` identities and (b) seeds
each company's hull pool into `merc_company_rosters` (the renamed collection, §8.F). The P4i
arc system then attaches `Rival` overlays to these pre-existing companies rather than minting
new ones.

### §8.E OpFor sourcing per contract type

OpFor has three sources; a contract draws from one per its kind and arc (`ContractKind`,
`src/domain/contract.zig`; current battle draw `src/domain/opfor.zig` `roll(...)`):

- **Faction house troops** — the default for faction-vs-faction kinds (`garrison_duty`,
  `cadre_duty`, `security_duty`, `riot_duty`, `planetary_assault`, `relief_duty`,
  `guerrilla_warfare`, `diversionary_raid`, `objective_raid`, `recon_raid`,
  `extraction_raid`): drawn from `faction_rosters[enemy_key]`.
- **Merc companies** — when an arc/story selects a world merc company as the OpFor (a
  "rival" contract, i.e. `arc_key`/`rival_ids` populated): drawn from that company's pool
  in `merc_company_rosters`.
- **Pirates / bandits / non-aligned** — `pirate_hunting`, and any contract whose
  `enemy_key == "PER"`: drawn from the `PER` faction pool in `faction_rosters["PER"]`, which
  is seeded at campaign creation by `seedPirateRoster` (P3e.5b-1, §8.C; the pool is persisted
  and will be drawn at battle-start in P3e.5b-3).

**P3e.5b-3a (sim/p3e-5b-opfor-draw, shipped):** `resolveEngagement` now routes through
`opforPool` to draw real `HullInstance`s from the enemy's pool (faction or PER). Each drawn
hull gets a per-hull outcome (destroyed / combat_ineffective / surviving) from `hullOutcome`.
Destroyed hulls are permanently marked, removed from the pool, and their BV is the
`enemy_destroyed_bv` in the report. Combat-ineffective hulls are excluded from subsequent
draws on the same contract via `HullCombatRecord`. An empty or absent pool for a would-be
faction is a bloodless forfeit win (score += forfeit, no hull mutations). State falls back to
abstract RAT-roll when no faction rosters are seeded (existing tests unaffected).

P3e.5b-3b (sim/p3e-5b-3b-salvage-link): `SalvageCandidate.hull_instance_id` links pool-path candidates to real drawn hulls; `takeSalvage` transfers the existing instance to the player (chosen) or finalises it as permanently_destroyed (unchosen); salvage decision is mandatory on the pool path (turn-blocking); exchange clause routes destroyed drawn hulls to employer faction immediately; contract-ending held-field salvage queues even when the contract completed in the same engagement. Shipped schema v55.

### §8.F What P3e.3's `rival_rosters` becomes (rename/rekey inventory)

**Rename target (proposed): `merc_company_rosters`, rekeyed `RivalId → MercCompanyId`.**
The exact field token is confirmed at the entity-split increment; the name must read as
"merc-company hull pools", not "rival rosters". This is a scope callout, not implementation
work; the following touchpoints will change in that future coded increment (schema migration
required):

- `src/sim/state.zig` — the `rival_rosters` field (line 351; rename + rekey to
  `MercCompanyId`); add the `rivals`→merc-company relationship (the `rivals` map at line 318
  and `next_rival_id` stay as the status overlay, gaining the `MercCompanyId` FK); add the
  new `merc_companies` collection and `next_merc_company_id`; the `field_persistence` table
  entries (lines 1030–1040).
- `src/domain/types.zig` — add `MercCompanyId`.
- `src/domain/rival.zig` — split identity fields out to the new `MercCompany` (new
  `src/domain/merc_company.zig`, proposed); `Rival` gains a `MercCompanyId` FK (see §8.A
  `// TBD` on field duplication).
- `src/domain/hull_instance.zig` — `OwnerType` `.rival` → `.merc_company`; `HullOwner`
  `.rival: RivalId` → `.merc_company: MercCompanyId`; persisted column `owner_rival_id` →
  `owner_merc_company_id` (schema migration from v52's shape).
- `src/persist/store.zig` — the v53 `rival_roster` table (line 322) renamed and rekeyed; a
  forward-numbered migration; digest coverage; golden round-trip proof.
- `src/sim/rivals.zig` — `generateRival`/`instantiateRivals`/`priorRival` expressed against
  merc companies (arcs attach overlays to seeded companies).
- `src/sim/roster_seed.zig`, `src/gen/roster_gen.zig` — extend to seed merc-company
  identities and pools (§8.D).
- Tests: the round-trip/digest tests for `rival_rosters`, and the `rivals.zig` tests, follow
  the rename with their owners (behaviour-preserving move — no new test is created by the
  rename itself).

### §8.G Delivery-order impact

- **New increment before P3e.5 (entity split):** introduce `MercCompany` /
  `MercCompanyId`, perform the §8.F rename/rekey and owner-kind rename, and the schema
  migration. Independently correct, green on the rule-72 gate, into local `main` before
  P3e.5.
- **P3e.5** gains campaign-start merc-company seeding (§8.D, formerly deferred here) and
  draws OpFor from the three sources (§8.E), including the PER seeding `// TBD` (§8.C).
- **P3e.6 (market surplus)** is unaffected by the entity model; it reads faction surplus and
  is keyed by faction string key either way.
- **P3e.7 (insolvency)** is **merc-company** insolvency (fieldable BV below threshold →
  the company cannot take contracts), not "rival" insolvency. **Delivered:** derived predicate
  (`mercCompanyInsolvent` in `src/sim/rivals.zig`), threshold constant
  `tuning.generation.merc_company_insolvency_bv = 2000` (// TUNE), no persisted flag,
  no schema migration; surfaced read-only via `RivalRow.insolvent` on the Operations view.
- **P3f (new-company formation and insolvency lifecycle)** later delivered market purchases
  toward full strength, liquidation, and replacement over this entity model. No entity added
  by P3f changes the §8 ownership model.
