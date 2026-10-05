# TODO

Open work only, in the order it is done. One cohesive package per branch; it
lands before the next starts (CLAUDE.md). A package has one primary invariant
or subsystem outcome. Its source identifiers below preserve the exception,
test, smoke, data, and product scope it closes. Finished work lives in git
history, not here.

## Contract compliance (`docs/contract-exceptions.md`)

The contract (`docs/coding-contract.md`) governs all code. Each package below
closes its listed scope completely. Behaviour changes start with a regression
test; rule-owner moves add an owner/consumer agreement test; persistence work
adds round-trip and corruption fixtures. Each branch runs rule 72's complete
applicable gate, including both smoke scripts when it touches their named
frontend boundary. The final package for an exception deletes its parent and
the exception entry only after all of its listed scope is closed.

The audit deliverables in `docs/audit-response.md` remain folded in: D27 and
D30 into C12, D28 into C7, and D31 into C8. D33 (C18) is now closed.

- [x] C20 residual documentation, naming, and coverage inventory (C20a-C20b;
  rules 61, 75, 81, 82, 84): module links, corrected comments/citations,
  unit-bearing names, legible formulas, and the final C20 scope inventory.
  Delete C20.

## Product completion

These product packages begin only after all compliance and focused-test work
above is complete.

- [x] P4 Campaign operations and stories:
  - P4a operations-and-stories design and content boundary: approved
    (`docs/p4-operations-design.md`).
  - [x] P4b operation content/state foundation.
  - [x] P4c operations board and garrison/security vertical slice.
  - [x] P4d mission intent, quote/commit planning, and operation-aware battles.
  - [x] P4e per-operation lance tasking and reports.
  - [x] P4f intelligence versus tempo.
  - [x] P4g command capacity and interventions.
  - [x] P4h escalation, consolidation, withdrawal, and finales.
  - [x] P4i persistent actors, relationships, world state, rivals, and officers.
    *(increment sim/p4i-actors-relationships: actors + 4-dim relationships + recurrence + read-only display — merged)*
    *(increment sim/p4i-world-state: world state 5-dim deltas + Operations/Map display, schema v45 — merged)*
    *(increment sim/p4i-rivals: rival companies + standing + recurrence + Operations display, schema v46 — merged)*
    *(increment sim/p4i-officers: officer arcs + performance + recurrence + Operations display, schema v47 — merged)*
  - [x] P4j additional arcs, variants, reports, balance scripts, and docs.
    *(increment sim/p4j-arcs: four arcs — aid_under_siege, enemy_supply_network, political_evacuation, beachhead_and_breakthrough)*
    *(increment sim/p4j-variants: operation variants across all five arcs + actor/rival archetype coverage for the four P4i.1 arcs)*
    *(increment: operation report query (queries.operationReport) + Contracts 'G' binding and read-only report modal; commit 10dbb02)*
    *(increment sim/p4j-scripts: five-style deterministic campaign tests — aggressive, cautious, intelligence-heavy, logistics-heavy, force-preservation)*
    *(increment sim/p4j-verify: rule 67 sweep — nine untested operation rule owners)*
    *(increment docs/p4j-sync: ARCHITECTURE/GAMEPLAY/tui.md/ROADMAP/TODO doc sync — no behavior change)*
- [ ] P3 MekLab depth — data-driven crit capacity/location rules and custom variants:
  - P3 design approval and content boundary: approved
    (`docs/p3-meklab-design.md`), grounded in
    `docs/p3d-meklab-location-layout.md`.
  - [ ] P3-construction (P3a): data-driven crit capacity and location rules.
  - P3c hull-lifecycle design approval: approved (`docs/p3c-hull-lifecycle-design.md`).
    - [x] P3c.1: hull instance entity, loadout, and the Unit link (entity, migration, digest).
    - [x] P3c.2: combat records and dual kill attribution (battle aftermath, all participating hulls).
    - [x] P3c.3: maintenance log and repair/modify commands (cli.zig, failure-atomic).
    - [ ] P3c.4: ownership chain and provenance (hull ownership history; current owner on the hull). Market supply and the living economy move to P3e.
    - [x] P3c.5: company-generation seeded history (deterministic pre-campaign history). `sim/p3c-5`
    - [ ] P3c.6: mech detail modal, queries, and verbs (queries.zig, TUI modal, cli.zig verbs).
  - [ ] P3-client (P3d): construction editor and variant lifecycle.
  - [ ] P3e Mech economy — living faction rosters, rival hull pools, conflict-governed market throughput:
    - P3e design approval and content boundary: pending (`docs/p3c-economy-design.md`), grounded in `docs/p3c-hull-lifecycle-design.md`. Prerequisite for every P3e item below.
    - [x] P3e.1: faction manufacturing data (extend `data/tables/factions.zon`; FactionId decision). <!-- sim/p3e-1 -->
    - [x] P3e.2: HullInstance current-owner fields (owner_type/owner_id; schema change). <!-- sim/p3e-2 -->
    - [x] P3e.3: FactionRoster + RivalRoster persistence (new collections, digest, round-trip). <!-- sim/p3e-3 -->
    - [x] P3e.4: campaign-start roster seeding (deterministic gen/ from the RAT). <!-- sim/p3e-4 -->
    - [x] Pre-P3e.5 entity split: MercCompany/MercCompanyId, merc_company_rosters, schema v53→v54. <!-- sim/p3e-entity-split -->
    - [ ] P3e.5: battle aftermath integration (OpFor draw from roster; destroyed/salvaged/survivor updates).
    - [ ] P3e.6: market surplus throughput (monthly surplus to listings, throttled by world_state conflict).
    - [ ] P3e.7: rival insolvency (fieldable BV below threshold → inactive).

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

Deferred indefinitely — uncommitted features. Their ROADMAP.md designs stand;
reschedule only on explicit dispatch.

- P1-design Brigade HQ design approval (P1a): price/duration, permanent
  staffing/upkeep, capacity/facility effects, eligibility, and one-brigade rule.
- P1-brigade (P1b-P1d): regional-to-brigade project, shared rules,
  persistence, queries, REPL/TUI, and current-behavior docs.
- P2-design battle-armor/artillery design approval (P2a).
- P2-battle-armor (P2b-P2d): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- P2-artillery (P2e-P2g): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- P2-battle-ui (P2h-P2i): both battle effects and REPL/TUI surfaces.

- A mobile field base as a buyable Repair support lance, adding to the repair
  push beyond the Logistics lance's workshop.
- Help overlay UX: design a scrollable overlay or contextual help filtered to
  the current screen's active bindings; this touches C12's key infrastructure.
