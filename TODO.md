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

- [ ] C20 residual documentation, naming, and coverage inventory (C20a-C20b;
  rules 61, 75, 81, 82, 84): module links, corrected comments/citations,
  unit-bearing names, legible formulas, and the final C17 scope inventory.
  Delete C20 and C17.

C17 focused coverage (rule 67) is required within its owner packages, not a
separate branch: C17a1/b5, C17a2/a4/b3, C17a5-a6/b2/b5-b6 delivered; C17a3/b1 with C5;
C17a7/b7 with C20; and C17c's
Desk, Contracts, Ledger, Forces, People, Supply, HQ, Market, Lab, and Map
coverage with the two C12 packages. C20's final inventory must show no scoped
omission before it deletes C17.

## Data verification (needs the sourcebooks)

- [ ] DATA-CAMOPS `contract.operationsMultBp`: transcribe the verified CamOps
  table into a fixture, compare every contract kind, correct only verified
  mismatches, and cite edition/page. Stop if the table cannot be verified.
- [ ] DATA-RATING Dragoons rating bands: identify the governing source table,
  compare every threshold in a fixture, correct only verified mismatches, and
  cite edition/page. Do not assume a sourcebook.

## Product completion

These product packages begin only after all compliance, focused-test, and data
verification work above is complete.

- [ ] P1-design Brigade HQ design approval (P1a): price/duration, permanent
  staffing/upkeep, capacity/facility effects, eligibility, and one-brigade rule.
- [ ] P1-brigade (P1b-P1d): regional-to-brigade project, shared rules,
  persistence, queries, REPL/TUI, and current-behavior docs.
- [ ] P2-design battle-armor/artillery design approval (P2a).
- [ ] P2-battle-armor (P2b-P2d): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- [ ] P2-artillery (P2e-P2g): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- [ ] P2-battle-ui (P2h-P2i): both battle effects and REPL/TUI surfaces.
- [ ] P3-construction (P3a-P3b): editable construction parts and A-F quotes.
- [ ] P3-variants (P3c): persisted campaign-owned custom chassis.
- [ ] P3-client (P3d): construction editor and variant lifecycle.
- [ ] P4 Campaign operations and stories:
  - [ ] P4a approve the operations-and-stories design and content boundary.
  - [ ] P4b operation content/state foundation.
  - [ ] P4c operations board and garrison/security vertical slice.
  - [ ] P4d mission intent, quote/commit planning, and operation-aware battles.
  - [ ] P4e per-operation lance tasking and reports.
  - [ ] P4f intelligence versus tempo.
  - [ ] P4g command capacity and interventions.
  - [ ] P4h escalation, consolidation, withdrawal, and finales.
  - [ ] P4i persistent actors, relationships, world state, rivals, and officers.
  - [ ] P4j additional arcs, variants, reports, balance scripts, and docs.

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

- A mobile field base as a buyable Repair support lance, adding to the repair
  push beyond the Logistics lance's workshop.
- Help overlay UX: design a scrollable overlay or contextual help filtered to
  the current screen's active bindings; this touches C12's key infrastructure.
