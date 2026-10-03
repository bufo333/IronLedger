# P3 — MekLab depth: design and content boundary

Status: approved design (P3 design-approval increment). This is the approval
artifact for the P3 MekLab product line. It defines the content boundary, states
what each of P3a-P3d ships and does not ship, sketches the data-model and
integration decisions the implementation increments must settle, and names the
existing-architecture conflicts to resolve first. No behavior is implemented in
this increment.

This document is grounded in `docs/p3d-meklab-location-layout.md` (the
authoritative per-location layout design input) and the code/data state at the
base commit. `ROADMAP.md` "Product completion P3" and `ARCHITECTURE.md` §10 (the
complete P3 lab target) remain the stage-design references; this document is the
authoritative statement of scope, boundary, and delivery order. ARCHITECTURE.md,
GAMEPLAY.md, `docs/tui.md`, the TUI mockups, and `docs/mekhq-map.md` are updated
only when the corresponding behavior ships (the P4i.6 precedent), not in this
approval increment. No BattleTech construction value is invented here: only what
the data files already encode and what the layout note states are documented,
and any balance number an increment introduces is labelled `// TUNE` until
verified against TechManual/CamOps.

## 1. What already ships (the foundation P3 extends)

P3 adds no parallel lab, refit, or persistence path. It extends systems already
in the tree at the base commit:

- The pure MekLab validator (`src/domain/meklab.zig`, ARCHITECTURE.md §10):
  integer half-ton arithmetic; `fixedHalfTons` derives structure, engine, gyro,
  cockpit, armor, jump-jet and extra-heat-sink mass from `tonnage` and
  `walk_mp`; `freeCrits(loc)` returns *uniform* standard-rules free-slot counts
  per location (head 1, center torso 2, side torsos 12, arms 8, legs 2) after
  implicit fixed occupants; `validate` names the violated rule (overweight,
  crits, heat_sinks, ammo, location, unknown_part, armor); the jump-jet location
  rule is hardcoded by matching the part key `jump_jet` to torsos/legs; the
  `Location` enum has eight members (hd, ct, lt, rt, la, ra, ll, rl).
- The construction data: `data/chassis.zon` (`domain/chassis.zig` `Chassis`:
  tonnage, bv, cost, rarity, intro_year, kind, walk_mp, jump_mp, heat_sinks,
  armor_half_tons, transport facts, loadout) and `data/parts.zon`
  (`domain/part.zig` `PartDef`: mass_half_tons, crits, heat, `mount` type,
  availability, tech_base, intro_year, fab_min_bay, fab_regional). The
  `data/tables/meklab.zon` Master Engine Table and Internal Structure Table.
- The refit pipeline: `RefitClass` A-D with `classify`, `refitHours` and
  `asQuality`; `Hq.refitClassCeiling()` (bay level capped by tier via
  `tuning.hq.refit_class_cap`); `sim/refit.zig` staging edits into a committed
  bay job (`refit_remove`/`refit_clear`/`refit_commit`), with the facility
  ceiling, parts-on-the-shelf, hull-at-home and legal-fit gates; `refit_plan`/
  `refit_op` persistence.
- The frontends: `sim/queries.zig` `lab`/`labMeks` views (a leaf, rule 5);
  `cli.zig` verbs and refusal sentences; the Lab TUI screen
  (`src/tui/screens/lab.zig`) with MOUNTS install/remove/clear/commit/replace/
  depot. Structural components (`comp_*`, tonnage-rated) already buy, fabricate
  and install through the depot/bay pipeline.
- Persistence (ARCHITECTURE.md §12): forward-only migrations in
  `persist/store.zig` with the `docs/schema.sql` mirror (schema_version 47 at
  the base commit), a loader that fails closed, per-field persistence classes,
  `validateStoredStrings` for display copy, and the `sim/digest.zig`
  golden-master round trip.
- Determinism (ARCHITECTURE.md §2): the sim core is pure. MekLab construction and
  refit classification use no RNG and must stay that way.

## 2. The authoritative design input

`docs/p3d-meklab-location-layout.md` is the user-named design input for the P3d
construction editor. Its content boundary, restated here as the governing UX
design:

- The current Lab view (budget + uniform crits table + mounts list) cannot show
  *where* things sit or how a chassis's physical shape constrains a build; two
  very different chassis render identically.
- A per-location slot layout renders the chassis's actual structure: fixed
  occupants, installed weapons, free slots, arranged spatially across the eight
  locations (head; LT/CT/RT; LA/RA; LL/RL), with narrower arm boxes and
  annotations where a location lacks lower-arm/hand actuators.
- One row per critical slot, with a marker and TUI colour per kind (fixed,
  missile, energy, ballistic, equipment, free). Multi-slot items render as one
  named group with a part counter so removing the item frees all its slots.
- The layout is data-driven and requires two additions not present today:
  per-location critical slot counts and per-chassis actuator/fixed-occupant
  configuration (cockpit, engine, gyro, actuators). No per-chassis artwork is
  needed; structure renders itself once the data exists.
- Placement rules are visualised and refused inline with the violated rule
  named: the note proposes CASE (side torso only) and AMS (head/torso only) in
  addition to the existing jump-jet rule, following the same one-owner pattern.
- The interaction model: a cursor navigates location by location; Enter on a
  free slot opens a parts picker filtered to what fits (weight remaining, crits
  remaining, location rules); a conflict is refused inline, never a silent
  no-op.
- Classic BattleTech (CamOps) rules only: any weapon may go in any location
  within crit/tonnage limits. The note explicitly rejects inventing a hardpoint
  type gate; the Catapult's restricted arms are fixed actuators consuming slots,
  not a hardpoint rule.
- Dependency: the read-only layout (current loadout in location boxes) can ship
  earlier as a pure TUI improvement, but chassis-specific slot arrangements need
  the new `chassis.zon` fields; the interactive, editable version (P3d) depends
  on P3a (editable construction parts), P3b (full A-F class support), and P3c
  (persisted custom chassis).

## 3. Content boundary (global)

P3 will add:

- Per-location construction data: per-location critical slot counts and
  fixed-occupant / actuator configuration on each `chassis.zon` mek, so free
  crits per location derive from data instead of meklab.zig's uniform
  `freeCrits`; construction facts sufficient to edit engines, gyros, cockpits
  and actuators (TRO/TechManual values only where a verifiable source exists,
  else `// TUNE`).
- A data-driven location-rule field on mountable parts, replacing the hardcoded
  jump-jet check with one owner consumed by the validator and the picker; CASE
  (side torso) and AMS (head/torso) placement rules per the layout note.
- The full CamOps refit class range A-F (E = engine, F = structure/chassis)
  extending the current A-D `classify`/`refitHours`/ceiling, so construction
  edits beyond weapons quote a class and tech-time.
- Campaign-owned custom chassis: persisted player-designed variants (new schema
  migration, digest coverage, per-field persistence class, loader that fails
  closed), surfaced as buildable/orderable designs.
- A per-location slot-layout construction editor in the TUI (the P3d UX) with
  variant lifecycle commands, reading through queries and mutating through
  commands.

P3 will NOT add:

- Hardpoint type gates or any rule not in classic BattleTech/CamOps (the layout
  note's explicit statement).
- A parallel lab/refit/persistence path, a second mutation boundary, or any
  GameState ownership in a frontend (contract rules 7-10).
- Pilot-level or hex-map combat, or any change to battle autoresolution.
- RNG in construction or refit classification (the sim core stays deterministic).
- Invented TechManual/CamOps construction or balance values; unverifiable
  numbers are `// TUNE`.
- Per-chassis artwork (the note: structure renders itself from data).

## 4. Per-increment boundary

The increments keep their existing `TODO.md` source identifiers so the scope
each closes is preserved.

### P3-construction (P3a-P3b): editable construction parts and A-F quotes

P3a — editable construction parts and per-location construction data. Ships:
- `chassis.zon` growth: per-location critical slot counts and fixed-occupant /
  actuator configuration (cockpit, engine, gyro, actuators) per mek, so free
  crits per location are derived from data (the layout note's two required
  additions). Free tonnage and free crits stop using meklab.zig's uniform
  `freeCrits`.
- `parts.zon` growth: engines, gyros, cockpits and actuators become mountable/
  installable construction parts (heat sinks and jump jets already are), each
  with mass/crit/heat and a data-driven location rule; a location-rule field on
  `PartDef` replacing the hardcoded jump-jet check (one owner). CASE and AMS
  parts with their placement rules per the note.
- `domain/meklab.zig`: the validator reads per-location capacity and the
  data-driven location rule from the new fields; the jump-jet special-case is
  removed in favour of the one owner. Behavior-preserving for existing
  catalogue designs (the "every catalogue mek's own loadout is legal" test must
  still pass).

P3b — the full A-F refit class range and quotes. Ships:
- `RefitClass` extended to E (engine touched) and F (structure/chassis touched),
  with `classify`, `refitHours` and the `asQuality`→ceiling mapping covering all
  six classes; `Hq.refitClassCeiling()` and `tuning.hq.refit_class_cap` extended
  to gate E/F.
- The refit quote for construction edits (engine/structure changes) through the
  same one owner the Lab and `refit_commit` already consume.

Does NOT ship: persisted custom variants (P3c) or the editor UX (P3d). The
validator and quote owners are extended but still consumed only by the existing
refit pipeline and Lab mounts view.

### P3-variants (P3c): persisted campaign-owned custom chassis

Ships:
- Campaign-owned custom chassis state on `GameState`, persisted via a new
  forward-only schema migration (the next version after the current v47) with
  its `docs/schema.sql` mirror, loader range-checks, `validateStoredStrings` for
  any display copy, enforceable foreign keys where containment applies, and
  `sim/digest.zig` coverage proven by the golden-master round trip.
- Custom designs resolve alongside the static `chassis.zon` catalogue where a
  design is looked up by key, and appear as buildable/orderable designs
  (ROADMAP Stage 10 target).

Does NOT ship: the editor UX (P3d). Prerequisite: P3a construction data (a
variant records a legal construction state).

### P3-client (P3d): construction editor and variant lifecycle

Ships (the `docs/p3d-meklab-location-layout.md` UX):
- The per-location slot layout in the Lab screen: eight location boxes with one
  row per critical slot, markers/colours per slot kind, multi-slot weapon
  grouping with a part counter, narrower arm boxes and no-actuator annotations.
  The read-only layout may ship first as a pure TUI improvement; chassis-specific
  arrangements consume the P3a data.
- Cursor navigation location by location; Enter on a free slot opens the parts
  picker filtered by weight remaining, crits remaining and location rules;
  conflicts refused inline with the rule named (never a silent no-op).
- Variant lifecycle: create/name/save/delete a campaign-owned custom variant
  through commands defined once in `cli.zig` with their refusal sentences,
  failure-atomic per rules 7/11-13; new read-only views in `queries.zig`.

Does NOT ship: any rule beyond classic BT/CamOps (no hardpoints).

## 5. Integration with existing systems

- Rule ownership (rules 3, 20-22): per-location capacity, the location rule, the
  refit class and the construction quote are each one named owner in
  `domain/meklab.zig` consumed by the validator, the refit pipeline, queries and
  the editor. The location rule stops being a hardcoded `jump_jet` branch.
- Mutation boundary (rules 7-13): variant create/save/delete and any
  construction edit are commands, failure-atomic; an expected refusal consumes
  nothing.
- Frontend boundary (rules 5, 8-10, 34): the editor reads only through
  `queries.zig` (a leaf) and mutates through commands; verbs and refusal
  sentences live once in `cli.zig`; view eligibility informs, the command
  decides. The Lab screen touches the gate's smoke boundary (`src/tui`,
  `cli.zig`, `queries.zig`); P3d runs both smoke scripts.
- Persistence (rules 45-51): the custom-chassis entity takes a forward-only
  migration, a per-field persistence class, loader-fails-closed range checks,
  and digest coverage; saves stay atomic.
- Determinism (rules 2, 6): construction and classification add no RNG and no
  I/O.
- Data loading: every new `chassis.zon`/`parts.zon` field is comptime-typed
  against its `domain/` struct, so a malformed mod fails the build; the
  `docs/data-fixtures.py` broken-overlay family coverage extends to the new
  fields.

## 6. Conflicts to resolve before implementation

- `freeCrits` migration: making per-location capacity data-driven must keep
  every existing catalogue design legal (the meklab.zig catalogue-legality and
  "abridged by at most seven tons" tests). Resolve in P3a before adding fields.
- Location-rule ownership: the hardcoded jump-jet check and the new CASE/AMS
  rules must collapse into one data-driven owner, not three branches.
- Refit class identity: extending `RefitClass` past D and mapping E/F onto the
  `types.Quality` ceiling must not change the A-D classification of existing
  plans (the refit-class test). Resolve in P3b.
- Custom-chassis vs. static catalogue: a design lookup by key must resolve both
  static and custom designs without a second lookup path or a layering
  inversion (queries stays a leaf). Resolve in P3c.
- Schema/digest growth: the custom-chassis entity must get its migration,
  digest coverage and golden-master survival, or the persistence/determinism
  contract breaks. Resolve in P3c before adding fields.
- Provenance: construction and balance values carry no invented citations;
  `// TUNE` until verified against TechManual/CamOps.

## 7. Delivery order and reconciliation

`TODO.md` owns the canonical order. This approval increment schedules P3 after
the now-closed P4 work:

1. P3 design approval and content boundary — this document.
2. P3-construction (P3a-P3b): editable construction parts and A-F quotes.
3. P3-variants (P3c): persisted campaign-owned custom chassis.
4. P3-client (P3d): construction editor and variant lifecycle.

Each implementation increment lands as one independently correct branch that
reaches local `main` before the next begins (CLAUDE.md), ends green on rule
72's applicable gate (both smoke scripts for P3d's Lab/queries/cli surfaces),
and updates ARCHITECTURE.md/GAMEPLAY.md/`docs/tui.md`/`docs/mekhq-map.md` and the
TUI mockups only when its behavior ships.

## 8. Approval checklist

This document is approved when the user confirms: the grounding in the layout
note (§2), the global content boundary (§3), the per-increment boundaries (§4),
the integration and conflict points (§§5-6), and the delivery order (§7).
Approval authorizes P3-construction (P3a) to begin against this design; it
commits no code.
