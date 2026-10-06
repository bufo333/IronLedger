# TODO

Open work only, in the order it is done. One cohesive package per branch; it
lands before the next starts (CLAUDE.md). A package has one primary invariant
or subsystem outcome. Its source identifiers below preserve the exception,
test, smoke, data, and product scope it closes. Finished work lives in git
history, not here.

## Product completion

These product packages begin only after all compliance and focused-test work
is complete.

- [ ] P3 MekLab depth — data-driven crit capacity/location rules and custom variants:
  - P3 design approval and content boundary: approved
    (`docs/p3-meklab-design.md`), grounded in
    `docs/p3d-meklab-location-layout.md`.
  - [ ] P3-construction (P3a): data-driven crit capacity and location rules.
  - P3c hull-lifecycle design approval: approved (`docs/p3c-hull-lifecycle-design.md`).
    - [ ] P3c.4: ownership chain and provenance (hull ownership history; current owner on the hull). Market supply and the living economy move to P3e.
    - [ ] P3c.6: mech detail modal, queries, and verbs (queries.zig, TUI modal, cli.zig verbs).
  - [ ] P3-client (P3d): construction editor and variant lifecycle.

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
- Contracts difficulty display — replace skull/half-skull glyphs (☠/◐) with filled circles (●), keep color coding, rename the column header from 'skulls' to 'difficulty'; touches `src/sim/queries.zig` and `src/tui/app.zig`, smokes required.
- Help overlay UX — screen-specific contextual help filtered to the current screen's active bindings (expand existing stub); design in ROADMAP.md first before scheduling.
