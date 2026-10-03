# P3c Hull Lifecycle Design Approval

**Status:** Approved design (P3c hull-lifecycle design-approval increment).

Grounded in the code/data state at base commit `ba29d9a151b9d618a58380e1c1622607fbd3bf97`.
Commits no code. Widens the P3c boundary set in `docs/p3-meklab-design.md` §4 from
"persisted campaign-owned custom chassis" to the full hull-lifecycle subsystem described
here.

## Project-owner decisions (2026-10-03)

The following decisions were made by the project owner and are recorded here as
authoritative:

- **Hull lifecycle scope.** Every hull that enters the campaign becomes a persisted entity
  with its own combat history, maintenance log, and ownership chain. Kills are attributed
  to both the pilot and the hull. Custom variants differ only in weapon, equipment, ammo,
  heat-sink, and jump-jet loadout. Refit classes E and F and engine/structure editing are
  permanently out of scope for P3c. The static `chassis.zon` catalogue stays the template;
  a hull instance carries a `base_key` reference into it.

- **Decision A — HullLoadout vs unit_slot (APPROVED).** HullLoadout is the hull's DESIGN
  loadout (what parts are meant to be installed); `unit_slot` is the owned unit's LIVE
  repair/condition state. Both coexist. The recommended resolution in §7
  (HullLoadout-vs-unit_slot) is approved by the owner.

- **Decision B — OpFor hull persistence (APPROVED).** ALL hulls that participate in
  battle get a persisted HullInstance — not just owned hulls. Destroyed + salvaged →
  ownership transfers to the salvaging company and the hull keeps accumulating data.
  Destroyed + NOT salvaged → `status = permanently_destroyed` and no further data
  accumulates on that instance. Active (survived battle, still with OpFor or another
  company) → keeps accumulating data as that entity operates.

No BattleTech construction or balance value is invented in this document. Any field whose
value source is unverified at design time is marked `// TUNE` or "TBD — sourced at
implementation". Schema baseline: the current `schema_version` is **47** (store.zig:43);
P3a bumped no schema. P3c's migrations number forward from v47, and the exact version
numbers follow whatever has landed on local `main` when each branch starts — verify
`store.zig` at implementation time.

---

## §1 Entity model

Five new persisted entity families. Field types follow the established schema precedent:
TEXT for stable keys, INTEGER for day_index, typed-ID-as-INTEGER with 0 = none,
enum-tag TEXT for enum columns, bool as INTEGER CHECK(col IN (0,1)). Typed IDs follow
`src/domain/types.zig:70–101` (`pub const XId = enum(u32) { none = 0, _ }`). Top-level
entities follow the `actor`/`unit_slot` persistence precedent (typed-id PRIMARY KEY
`(cid, id)`; child rows keyed by `(cid, parent_id, ord)`).

**New typed id:** `HullInstanceId = enum(u32) { none = 0, _ }` — added to types.zig.
**New meta counter:** `next_hull_instance_id` — added to GameState meta scalars (actor
precedent).

### HullInstance

Top-level entity. PRIMARY KEY `(cid, id)`, FK to `campaign(id)` DEFERRABLE.

| Field | Type | Notes |
|-------|------|-------|
| `id` | HullInstanceId (INTEGER) | typed, 0 = none |
| `base_key` | TEXT | references chassis.zon stable key |
| `name` | TEXT, nullable | validateStoredStrings applies |
| `nickname` | TEXT, nullable | validateStoredStrings applies |
| `status` | TEXT (enum-tag) | must include `permanently_destroyed` (Decision B); the rest of the status set (e.g. active) is TBD — sourced at implementation |
| `intro_year` | INTEGER | TBD / `// TUNE` — sourced from the base chassis's intro_year at creation, not stored arbitrarily |
| `pre_campaign` | INTEGER, CHECK(0,1) | bool: true if seeded before campaign start |

### HullLoadout

Per-slot child of HullInstance. Records the hull's DESIGN loadout (what parts are meant
to be installed). Keyed `(cid, hull_instance_id, slot_index)`, FK to hull_instance
DEFERRABLE (unit_slot precedent).

| Field | Type | Notes |
|-------|------|-------|
| `hull_instance_id` | HullInstanceId (INTEGER) | FK to HullInstance |
| `slot_index` | INTEGER | ord, identifies the slot |
| `part_key` | TEXT | references parts.zon stable key |

### HullCombatRecord

Per-engagement child of HullInstance. Records kills credited to this hull and a damage
summary for one engagement. Keyed `(cid, hull_instance_id, ord)` with a battle backlink;
FK to hull_instance.

| Field | Type | Notes |
|-------|------|-------|
| `hull_instance_id` | HullInstanceId (INTEGER) | FK to HullInstance |
| `battle_id` | INTEGER | BattleId backlink |
| `contract_id` | INTEGER | ContractId backlink |
| `kills` | INTEGER | kills credited to this hull in this engagement |
| `damage_summary` | TBD | exact columns sourced from what battle.zig's aftermath already computes, mirroring battle_report fields — not invented here |

### MaintenanceEntry

Per-maintenance-event child of HullInstance. Keyed `(cid, hull_instance_id, ord)`.

| Field | Type | Notes |
|-------|------|-------|
| `hull_instance_id` | HullInstanceId (INTEGER) | FK to HullInstance |
| `day` | INTEGER | day_index |
| `tech` | INTEGER | PersonId; 0 = none |
| `description` | TEXT | validateStoredStrings |
| `parts_replaced` | TBD | TEXT key list or child rows — resolved at P3c.3 implementation |
| `battle_id` | INTEGER | BattleId backlink; 0 = none (optional) |

### HullOwnershipHistory

Per-ownership-event child of HullInstance. Tracks the ownership chain. Keyed
`(cid, hull_instance_id, ord)`.

| Field | Type | Notes |
|-------|------|-------|
| `hull_instance_id` | HullInstanceId (INTEGER) | FK to HullInstance |
| `from_day` | INTEGER | day_index |
| `to_day` | INTEGER | day_index; 0 = current owner (open interval) |
| `owner_key` | TEXT | encoding scheme resolved at P3c.4, following the `stock.owner_kind`/`owner_id` precedent rather than overloading one TEXT column if that proves cleaner |
| `acquisition_type` | TEXT (enum-tag) | purchase / salvage / captured / company_start / market |

### Persistence requirements

These are *persisted* GameState collections. Each lands in `GameState` as an
`AutoArrayHashMapUnmanaged` (top-level, keyed by HullInstanceId) or an
`ArrayListUnmanaged` (child rows), is added to the `field_persistence` registry as
`.persisted`, and is added to the digest's hashed set with golden-master round-trip proof
(state.zig + digest.zig precedents). The digest grows and the golden hash changes with
each schema-bearing sub-increment — expected, not a regression.

---

## §2 Lifecycle triggers

A HullInstance is created when a hull enters the campaign:

**(a) Company-generation start.** Every starting unit (`src/gen/company_gen.zig`,
`src/sim/starter_company.zig`) gets an instance with `pre_campaign = true` and
deterministically seeded history (P3c.5).

**(b) Market appearance.** A listed hull becomes an instance at listing time so its
identity predates purchase (P3c.4, market integration).

**(c) Company purchase.** Buying a listed/market hull records an ownership-history row
(`acquisition_type = purchase`), not a new instance (the instance was created at
listing).

**(d) Enemy hull captured/salvaged.** A wreck taken off a held field becomes an owned
instance with `acquisition_type = salvage` or `captured`.

**(e) Battle participation (owner Decision B).** ALL hulls that participate in a battle
get a persisted HullInstance at that point, not just owned hulls. The question of whether
to persist enemy/OpFor hull combat records is resolved: yes, all participating hulls. If
such a hull is destroyed without being salvaged, the aftermath writes
`status = permanently_destroyed` immediately and no further data accumulates on that
instance. If destroyed and salvaged, ownership transfers to the salvaging company and the
hull keeps accumulating data. If it survives and stays with the OpFor or another company,
it keeps accumulating data as that entity operates.

---

## §3 Market integration and the Unit migration path

`Unit` gains `hull_instance_id: HullInstanceId` (the hull a unit embodies). The hull
instance carries `base_key`.

### The Unit.chassis_key tension

This is the increment's largest integration conflict. The blast radius measured at base
commit ba29d9a: **~128 `chassis_key` references across 24 source files** (queries 29,
store 14, hq_ops 15, starter_company 8, unit 7, market 6, battle 6, battle_report 4,
refit/sites/state/after_action 3 each, maintenance 5, lift 2, held_hulls 2, toe 2,
checklist 2, part 2, and one each in app/founding/tick/personnel/contract_control/
contract_events).

Two resolutions:

**(Recommended) Keep `chassis_key` as a cached base_key.** `Unit` keeps `chassis_key` as
the *resolved base_key* of its hull instance (a cached denormalization) and gains
`hull_instance_id`. The ~128 read sites that do `chassis_mod.find(u.chassis_key)` are
unchanged, and only the writers that create units learn to create/link an instance. This
keeps queries a leaf (rule 5) and bounds the diff.

**(Alternative) Remove `chassis_key` from `Unit`.** Every consumer reads `base_key`
through the hull instance via one owner accessor. Architecturally purer (one owner,
rule 3) but rewrites all 24 files and risks a layering inversion if the accessor needs
GameState.

The owner's choice between these resolutions is deferred to P3c.1-approval time. It is
not a blocker for this design approval.

### Migration path: v47 → v48

The migration creates one HullInstance per existing owned `unit` row: `base_key` = the
unit's current `chassis_key`; loadout mirrored from the existing `unit_slot` rows;
`pre_campaign` derived from whether the unit predates the migration (TBD — sourced at
implementation); links `unit.hull_instance_id`; seeds a single ownership-history row with
`from_day = acquired_day`. Older saves load whole or are rejected (rule 1, loader fails
closed). The exact migration version number is verified in store.zig at implementation
time, not asserted here.

---

## §4 Kill attribution

`Person.kills`, `kill_bv`, and `battles` stay exactly as today (person.zig:195–197). The
single kill-attribution owner `personnel.creditKills` in battle.zig:863 is unchanged in
its person effect.

Additionally, a `HullCombatRecord` row is written for each hull that participates in an
engagement, recording the kills credited to that hull in that engagement. Both the person
record and the hull record are written in the same failure-atomic aftermath path
(battle.zig `aftermath`).

**Rule:** Pilot kills and hull kills are two views of the same engagement event, written
together; neither is derived from the other at read time.

---

## §5 P3d dependency fix

P3d (the per-location layout construction editor, `docs/p3d-meklab-location-layout.md`)
previously depended on "P3c persisted custom chassis." In the hull-lifecycle model a
custom variant is simply a HullInstance whose HullLoadout differs from its base_key
template.

P3d therefore depends on **P3c.1** (the HullInstance entity + HullLoadout persistence +
the Unit link) and on the **loadout-edit (modify) command** that P3c ships (P3c.3).

ROADMAP §P3d's existing prerequisite line "P3a, P3c" remains correct at the coarse grain
and needs no edit in this increment.

---

## §6 Sub-increment delivery order (P3c.1–P3c.6)

Each sub-increment is independently correct, one branch, green on rule 72's applicable
gate, reaching local `main` before the next begins.

**Re-ordering rationale:** The dispatch's straw-man placed `Unit.hull_instance_id` and
the create-instances migration in P3c.4. However, P3c.2 (combat records) and P3c.3
(maintenance) must reference the hull a unit points at. Therefore the Unit link and its
migration move into P3c.1.

### P3c.1 — Hull instance entity, loadout, and the Unit link

New `HullInstanceId`; `HullInstance` + `HullLoadout` GameState collections;
`Unit.hull_instance_id`; the v47→v48 forward-only migration creating one instance per
existing owned unit and mirroring its loadout; `docs/schema.sql` mirror; loader
range-checks; `validateStoredStrings` for nickname/description copy; FK where containment
applies; `field_persistence` + digest coverage proven by the golden round trip.

No commands, no TUI.

Gate: `zig fmt --check build.zig src`, `zig build test --summary all`,
`docs/verify-contract.sh`. No smokes — no TUI/cli/queries/main surface.

### P3c.2 — Combat records and dual kill attribution

`HullCombatRecord` table + GameState collection; battle.zig's aftermath writes one record
per participating hull (ALL participating hulls, OpFor included — owner Decision B) with
its per-engagement kills and damage summary; a participating hull destroyed without
salvage has its instance set to `status = permanently_destroyed` in the same aftermath
path; `Person.kills` unchanged; next migration (v48→v49 relative to P3c.1's landing).

Gate adds smokes only if this touches queries/cli/tui (first cut: sim + persist only, so
likely no smokes — confirm at implementation time).

### P3c.3 — Maintenance log and repair/modify commands

`MaintenanceEntry` table + GameState collection; commands defined once in `cli.zig` with
refusal sentences, failure-atomic (rules 7, 11–13) for repair and loadout *modify* (the
custom-variant edit) with tech and optional battle backlinks; next migration.

Gate includes both smoke scripts (cli.zig surface).

### P3c.4 — Ownership history and market integration

`HullOwnershipHistory` table + GameState collection; market appearances create instances;
purchase/salvage/capture record ownership rows (salvage of a destroyed hull transfers
ownership to the salvaging company); ownership chain surfaced read-only; next migration.

Gate per touched surface.

### P3c.5 — Company-generation seeded history

`src/gen/` seeds deterministic (named RNG stream, rules 2 and 6) pre-campaign
combat/maintenance/ownership history for starting hulls at campaign creation. No new
table; writes the P3c.1–P3c.4 entities.

Gate: tests + the campaign-creation path.

### P3c.6 — Mech detail modal, queries, and verbs

`queries.zig` hull-detail / combat-history / maintenance / ownership views (leaf,
rule 5); TUI mech-detail modal with browsable sub-modals (person-detail modal precedent,
app.zig); `cli.zig` verbs.

Gate includes both smoke scripts (src/tui, cli.zig, queries.zig surface).

---

## §7 Integration conflicts to resolve

### Unit.chassis_key → hull_instance_id (P3c.1)

The ~128-reference / 24-file blast radius. Recommended resolution: keep `chassis_key` as
a cached `base_key`, add `hull_instance_id` (see §3). One remaining choice carried into
P3c.1-approval time, not a blocker for this design approval.

### HullLoadout vs unit_slot (P3c.1) — RESOLVED

`unit_slot` already persists per-slot `part_key`/`class`/`condition` for owned units.
HullLoadout would duplicate it for owned hulls while being the only loadout store for
not-yet-owned (market/enemy) instances.

**Resolved by owner (2026-10-03): approved recommended resolution.** HullLoadout records
the hull's *design* loadout (part_key per slot); `unit_slot` remains the owned unit's
live repair/condition state. Both coexist.

### Digest/schema growth (every schema-bearing sub-increment)

Each sub-increment adds a migration, a `field_persistence` entry, a hashed collection,
and shifts the golden hash. Expected — not a regression.

### Determinism (P3c.5)

Seeded history uses a named RNG stream; the sim core stays pure (rules 2, 6).

### Frontend boundary (P3c.3, P3c.6)

Reads through queries (leaf), mutations through `cli.zig` commands with single-owner
refusal text (rules 5, 8–10, 34).

### Provenance

`intro_year` and any balance figure carry no invented citation. `// TUNE` / "TBD —
sourced at implementation" until verified from a source read during that sub-increment.

### Residual drift in docs/p3-meklab-design.md

After this increment, §3 (lines 112–114), §6 (lines 222–226), and §7 (line 237) of
`docs/p3-meklab-design.md` still describe P3c as "persisted custom chassis," which is
now narrower than the §4 restatement. This is a low-severity internal inconsistency
flagged for a possible owner-dispatched follow-up. Not fixed here (outside the authorized
scope of this increment). This document supersedes those phrasings where they conflict.

---

## §8 Approval checklist

This design-approval increment is approved when the owner confirms:

- [ ] Entity model (§1): five entity families with typed fields, no invented values,
      unverified fields marked `// TUNE` or TBD.
- [ ] Lifecycle triggers (§2): all five triggers, including confirmed persistence of all
      participating hulls (owner Decision B).
- [ ] Unit migration path (§3): migrations numbered forward from the verified v47
      baseline; no invented version numbers; the Unit.chassis_key resolution deferred to
      P3c.1-approval time (not a blocker).
- [ ] Kill attribution (§4): pilot kills and hull kills are two views of the same event;
      `Person.kills` unchanged.
- [ ] P3d dependency (§5): P3d depends on P3c.1 + the P3c.3 modify command; ROADMAP
      §P3d "Prerequisites: P3a, P3c" stays correct.
- [ ] Sub-increment order P3c.1–P3c.6 and the re-ordering rationale (§6): Unit link
      moves into P3c.1 because P3c.2 and P3c.3 reference it.

The two formerly-open items — HullLoadout-vs-unit_slot and whether enemy/OpFor hulls are
persisted — are already decided by owner Decisions A and B (2026-10-03) and are no longer
checklist items.

One choice remains deferred to P3c.1-approval time, not blocking this design approval:
the `Unit.chassis_key` resolution (recommended option: keep `chassis_key` as a cached
`base_key` and add `hull_instance_id`).

Approval authorizes P3c.1 to begin; it commits no code.
