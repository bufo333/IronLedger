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
2. **Rival merc companies.** Each rival company (already persisted, `src/domain/rival.zig`,
   P4i) has a hull pool under the same ownership model as a faction, subject to attrition
   and insolvency. A rival that loses too many hulls cannot meet contract battle-value
   requirements and eventually goes insolvent.
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
  parallel battle or salvage path.
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
- **P3e.3 — FactionRoster + RivalRoster persistence.** The two roster collections,
  `field_persistence` entries, digest coverage, and golden round-trip proof; schema
  change.
- **P3e.4 — Campaign-start roster seeding.** Deterministic `src/gen/` seeding from the
  campaign seed, the RAT (`rat.zon`) and the faction manufacturing data; named RNG
  stream; pure core.
- **P3e.5 — Battle aftermath integration.** OpFor force drawn from the faction/rival
  roster; post-battle destroyed/salvaged/surviving ownership and status updates in the
  existing failure-atomic aftermath path.
- **P3e.6 — Market surplus throughput.** Monthly surplus calculation flowing faction
  surplus to market listings, throttled by `world_state` conflict intensity.
- **P3e.7 — Rival insolvency.** The fieldable-BV-below-threshold inactive trigger and its
  surfaced read-only state.

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
- [ ] Entity model (§2): FactionRoster, RivalRoster, the HullInstance current-owner
      extension (distinct from P3c.4 provenance), and market-source integration.
- [ ] Faction data (§3): manufacturing data extends `factions.zon`; the RAT is the
      existing `rat.zon`; all specific values TBD pending source verification.
- [ ] Lifecycle triggers (§4): campaign-start seeding, battle draw/attrition/salvage,
      monthly conflict-throttled market surplus, rival insolvency.
- [ ] Delivery order (§5): P3e.0 design approval first, then P3e.1–P3e.7, each
      independently correct, prerequisite P3c.
- [ ] Hull-lifecycle increments (§6): P3c.3/P3c.5/P3c.6 unblocked; P3c.4 re-scoped to the
      ownership chain.

Approval authorizes P3e.1 to begin; it commits no code.
