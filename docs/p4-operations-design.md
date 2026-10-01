# P4 — Campaign operations and stories: design and content boundary

Status: approved design (P4a). This is the approval artifact for the P4
product line. It defines terms, states the content boundary, sketches the
design decisions P4b-P4j must settle, and names the existing-architecture
conflicts to resolve before implementation. No behavior is implemented in P4a.

ROADMAP.md "Product completion P4" (the per-package prompts) remains the
detailed design reference. This document is the authoritative statement of
scope, terms, boundary, and delivery order; where ROADMAP's prompt lettering
differs it is reconciled below. ARCHITECTURE.md and GAMEPLAY.md are updated only
when the corresponding behavior ships (ROADMAP P4i.6).

## 1. What already exists (the foundation P4 extends)

P4 adds no parallel command, event, battle, or report path. It extends, through
shared rule owners, systems that already ship (ARCHITECTURE.md §§5-9):

- Contracts: the 12 AtB types, terms, command rights, a generated scenario and
  event schedule, score/success state, victory conditions (duration vs. enemy
  attrition), the breach clause, and redeploy/recall/close-out
  (`domain/contract.zig`, `sim/contract_control.zig`, `sim/contract_events.zig`).
- The turn pipeline (§6), whose phase 7 (contract events, scenario generation)
  and phase 8 (battle resolution) are the integration points for operations.
- The decision inbox, notices, and after-action reports (§8), with
  `checklist.turnHold` as the one owner of whether a turn holds and
  `EventKind.blocksTurn` naming which decisions qualify.
- Battle setup and autoresolution (§7): combat power plus campaign modifiers,
  rules of engagement, lance roles, the opposition as a real force
  (`sim/battle.zig`, `domain/autoresolve.zig`, `domain/opfor.zig`,
  `domain/scenario.zig`, `sim/offer_rating.zig`), and the AAR.
- Support assets, recon, air cover, readiness, and the HQ/supply network (§9),
  all gated by `readiness.unitOperational` / `forceOperational`.
- Faction/employer standing, local markets, local operating funds, and the
  structured, tagged campaign log (§§9.8, 11).
- Persistence (§12): forward-only migrations, a loader that fails closed, the
  per-field persistence class, and the golden-master digest.
- RNG discipline (§4): one seed, named salt-stable streams.

## 2. What a "campaign operation" is

A campaign operation is the player-facing unit of deployment play within a
single accepted contract: a bounded undertaking the commander chooses, plans,
resources, and resolves, with its own objective, force-role needs, risks,
rewards, and follow-up branches. It is coarser than a calendar day or a single
random event and finer than a whole contract.

It is distinct from the two things it sits between:

- Not a contract. A contract is the employment: one employer, planet, term,
  financial terms, command rights, and win condition. A contract now hosts a
  short arc of several operations that together produce its result.
- Not a battle/scenario. A battle is one engagement's autoresolution. An
  operation may contain zero, one, or several engagements, and non-combat
  operations exist. Winning an engagement and accomplishing an operation are
  separate results: a force can preserve its hulls and still fail the
  operation, or take losses while securing a contract-altering outcome.

Lifecycle (one owner per transition, consumed by commands, tick, battle setup,
queries, and persistence validation):

    briefing -> available -> committed -> resolved -> escalation -> finale -> aftermath

Every turn-hold an operation can cause routes through the existing
`checklist.turnHold` / `EventKind.blocksTurn` owners; operations do not add a
new hold path.

## 3. What "stories" means

Stories here are authored, data-driven campaign content instantiated
procedurally against a live campaign — not free-text narrative and not a
second simulation. A "story" is a contract arc: arrival, complication,
escalation, climax, and aftermath, assembled from authored templates and
resolved by the sim's existing rules.

Stories comprise:

- Authored content (game data, in `data/` `.zon` with build validation, like
  chassis/parts/tables): arc archetypes, operation templates, intents,
  complications, escalation and finale templates, actor archetypes, rival
  archetypes, and world-state effects. Authored prose is game content; a
  sourcebook citation is never invented for it, and new balance values are
  `// TUNE` until verified or deliberately retained as play-tuning values.
- Procedural instantiation (runtime state): which arc a given contract drew,
  the current beat, available/committed/resolved operations, escalation clocks,
  attached actors and relationship state, command-capacity state, and per-world
  state. This is campaign state, persisted and digested like any other.
- Named characters and persistent world: contract-local actors (liaisons,
  officials, militia leaders, quartermasters, enemy officers, rival commanders)
  with deterministic generated identity and a narrow relationship model;
  bounded per-world state; persistent rival companies; and compact officer arcs
  for commanders and selected lance leaders using the personnel system.

The line between authored and procedural content is the content boundary's
spine: content expansion changes data, never the operation engine.

## 4. Content boundary

P4 will add:

- A typed, data-driven campaign-content model with build-time validation of
  keys, references, legal contract kinds, legal effects, and branch targets.
- Operation state on the contract, with persistence classes, migration, and
  digest coverage.
- Owner modules for operation eligibility, quotes, resolution outcome bands,
  escalation-clock changes, and finale selection.
- Operation-scoped intents, lance tasking, intelligence-versus-tempo choices,
  and a capped command-capacity intervention economy — each through the
  existing command/query/battle/report surfaces.
- Contract-local actors, a narrow relationship model, bounded per-world state,
  persistent rivals, and compact officer arcs.
- Enough arcs and variants to prove replayability, plus reports, deterministic
  balance scripts, and documentation updated as behavior ships.

P4 will NOT add:

- Pilot-level or hex-map combat, a MegaMek/MegaMek-style battle handoff, or
  per-weapon resolution (ARCHITECTURE.md §3 keeps these dropped).
- A parallel command, event, battle, report, inbox, or turn-hold path. Every
  operation effect enters through an existing owner.
- A second currency or any intervention that negates a permanent loss or
  overrides a command-refusal rule.
- A universal hidden "doom meter"; only named, arc-scoped clocks where needed.
- A fully simulated population; per-world state is bounded and legible.
- Invented sourcebook citations for authored content or balance values.
- Actors as payroll `Person` records, unless a named conversion rule turns an
  actor into a prisoner, recruit, or employee.

## 5. Data model sketch (for P4b)

Two layers, mirroring §3.

Authored content (new `data/` `.zon` families, each with a comptime-typed row
struct in `domain/` and build validation, and each requiring a broken-overlay
fixture in `docs/data-fixtures.py`):

- arc archetypes; operation templates; intents; complications; escalation
  templates; finale templates; actor archetypes; rival archetypes; world-state
  effects. Validation checks stable keys, cross-references, legal contract
  kinds, legal effect references, and branch targets.

Runtime operation state (added to the `Contract` entity, ARCHITECTURE.md §5
line 223): selected arc, current beat, typed available/committed/resolved
operation identities, operation history, escalation clocks, attached actors,
relationship state, command-capacity state, and counters. Typed IDs follow the
existing non-exhaustive `enum(u32)` convention. Every new persisted field takes
a `GameState.field_persistence` class, is covered by `sim/digest.zig`, and is
exercised by the golden-master round trip.

New persisted structures beyond the contract (actors, relationships, per-world
state, rivals, officer arcs) require: a forward-only schema migration (schema
version bump in `persist/store.zig` with its `docs/schema.sql` mirror), loader
range-checks and `validateStoredStrings` for any display copy, enforceable
foreign keys where containment applies, and digest coverage. Actors stay
distinct from `Person` unless a named conversion rule applies.

## 6. How operations relate to existing systems

- Commands: new planning verbs (select operation, set intent, assign tasking,
  choose recon/advance/prepare/delay, spend command capacity, post-operation
  choices) are commands, defined once in `cli.zig` with their refusal
  sentences, failure-atomic per contract rule 7/11-13.
- Tick: escalation-clock advancement and operation beat progression fold into
  the existing phase 7 (contract events / scenario generation); battle
  resolution stays phase 8. A P4b decision records whether clock advancement is
  an explicit named sub-step of phase 7 or a distinct, documented phase; it must
  not re-derive rules a named owner already owns, and it must preserve the
  fixed, spec'd phase order (§6).
- Battle: committed operation context (intent, lance tasking, intel posture)
  feeds `sim/battle.zig` setup and the §7 combat-power/campaign-modifier
  pipeline through named owners; the AAR names the operation, the selected
  intent, and whether it succeeded. The opposition remains a real force
  (`opfor`), not a mirror.
- Inbox/holds: operation decisions surface through the existing decision inbox,
  notices, after-action reports, and battle-orders surfaces. Any operation
  turn-hold is named in `EventKind.blocksTurn` and routed through
  `checklist.turnHold`; view eligibility informs, the command decides (rule 34).
- Command rights: intent and tasking constraints go through the existing
  `CommandRights` owner (integrated may mandate, house/liaison may limit or
  penalize, independent is wider). ROE remains a distinct risk posture.
- Queries: operation briefings, available operations, committed plans, arc
  progress, clocks, prior consequences, actor/rival/world state, and
  command-capacity are read-only views in `queries.zig` (a leaf, rule 5),
  reading the operation owners; actionable rows carry typed operation IDs.
- RNG: arc/operation instantiation, complication selection, actor/rival
  generation, intel resolution, and finale selection each draw from a named,
  salt-stable stream; shared generators (`opfor`, person generation) take the
  caller's stream. No new roll perturbs an existing stream.
- Economy/standing/log: operation outcomes and interventions use existing
  money, standing, stock, fatigue, and the tagged structured log; every result
  is recorded in contract history and the campaign log.

## 7. Key design decisions P4b-P4j must settle

1. The exact `Contract` operation-state shape and each field's persistence
   class, migration, and digest coverage (P4b).
2. Whether escalation-clock advancement is a named sub-step of tick phase 7 or
   a distinct phase, and its deterministic ordering (P4b).
3. The authored-content `.zon` schema for each new family and its validation,
   plus the matching `data-fixtures.py` broken-overlay fixtures (P4b, P4j).
4. The operation-eligibility, quote, outcome-band, clock-change, and
   finale-selection owner interfaces consumed by commands/tick/battle/queries
   (P4b).
5. The intent set, intent effects on battle/score/salvage/follow-up, and the
   command-rights-constrained legal set (P4d).
6. The lance-task set, task eligibility (operational, co-located, command-rights
   and capability gated), and task effects, each with one owner (P4e).
7. The intelligence state model (known vs. uncertain, never revealing an
   unrolled outcome) and the tempo choices with their clock consequences (P4f).
8. The `CommandCapacity` resource (cadence, cap, carry-over, employer
   reservation) and the intervention set, each gated by real personnel/assets
   (P4g).
9. Withdrawal taxonomy (tactical vs. operational vs. contract recall via the
   breach clause) and finale selection/resolution from arc state (P4h).
10. The actor/relationship/world-state/rival/officer persistence model and its
    consumers in generation, markets, intel, and finales (P4i).
11. Content inventory: the P4c vertical-slice arc plus the four further arcs,
    variants per contract family, reports, and deterministic balance scripts
    (P4j).

## 8. Conflicts with existing architecture to resolve before implementation

- Contract struct growth vs. persistence/digest: every new operation field must
  get a persistence class, digest coverage, a forward-only migration, and
  golden-master survival, or the determinism/persistence contract (rules
  45-51; ARCHITECTURE.md §12) breaks. Resolve in P4b before adding fields.
- Turn-hold ownership: operation holds must not create a second hold path;
  `checklist.turnHold` and `EventKind.blocksTurn` stay the sole owners (§6).
- Tick phase order: clock/beat advancement must fit the fixed phase pipeline
  without re-deriving owned rules or reordering phases (§6).
- Battle-setup coupling: intent/tasking/intel effects must enter the §7
  pipeline through named owners, not ad hoc modifiers, and must not duplicate
  `CommandRights`, ROE, `offer_rating`, or `opfor` logic.
- Layering: operation views live in `queries.zig` (a leaf); verbs and refusal
  sentences live once in `cli.zig`; nothing below queries imports it (rule 5).
- New `.zon` content families: each must have build validation and a
  `data-fixtures.py` fixture, or data loading no longer fails closed for them.
- Actor vs. Person identity: actors must stay distinct from payroll `Person`
  unless a named conversion rule exists (avoids polluting the personnel system).
- Content provenance and licensing: authored content and balance values carry
  no invented citations; `// TUNE` until verified; BattleTech IP and MekHQ data
  licensing constraints (ARCHITECTURE.md §12) stand.

## 9. Delivery order (authoritative) and reconciliation with ROADMAP

`TODO.md` owns the canonical P4a-P4j order. ROADMAP's "Product completion P4"
prompts use P4a-P4i, folding design approval into its P4a. The mapping is a
clean shift-by-one after the split of approval from foundation:

| TODO (authoritative) | ROADMAP prompt |
|---|---|
| P4a approve design and content boundary | ROADMAP P4a (its "write and approve the design" sentence) — this document |
| P4b operation content/state foundation | ROADMAP P4a.1-P4a.4 |
| P4c operations board and garrison/security vertical slice | ROADMAP P4b |
| P4d mission intent, quote/commit planning, operation-aware battles | ROADMAP P4c |
| P4e per-operation lance tasking and reports | ROADMAP P4d |
| P4f intelligence versus tempo | ROADMAP P4e |
| P4g command capacity and interventions | ROADMAP P4f |
| P4h escalation, consolidation, withdrawal, and finales | ROADMAP P4g |
| P4i persistent actors, relationships, world state, rivals, officers | ROADMAP P4h |
| P4j additional arcs, variants, reports, balance scripts, and docs | ROADMAP P4i |

When P4b begins, ROADMAP's prompt lettering should be reconciled to this
mapping (or ROADMAP's prompts re-cited as references under these labels).

## 10. Approval checklist

This document is approved when the user confirms: the operation/story
definitions (§§2-3), the content boundary (§4), the data-model and integration
sketches (§§5-6), the decisions deferred to P4b-P4j (§7), the named
architecture conflicts (§8), and the delivery order (§9). Approval authorizes
P4b to begin against this design; it commits no code.
