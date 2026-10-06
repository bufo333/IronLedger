# TODO

Open work only, in the order it is done. One cohesive package per branch; it
lands before the next starts (CLAUDE.md). A package has one primary invariant
or subsystem outcome. Its source identifiers below preserve the exception,
test, smoke, data, and product scope it closes. Finished work lives in git
history, not here.

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

- P3f-design Faction economic loop design approval (ROADMAP.md P3f): lost-field
  wreck flow; dispersed black-market listings (`planet_key` + `available_after`,
  faction-access flag); rival merc-company death and replacement from the
  `data/logos/` pool; pirate base replenishment and black-market competition;
  and the campaign-wizard logo picker (title-case name from the filename).
  Closes the P3e living-roster loop; one coherent stage; needs the design doc
  fixed before dispatch.
- Per-location armor data accuracy (lower priority, after P3f): pull the 8 front
  and 3 rear-torso armor values per mech from the MegaMek 3039u MTF files
  (https://github.com/MegaMek/mm-data/tree/main/data/mekfiles/meks/3039u) for
  all 64 `data/chassis.zon` mechs and cross-check ammo-slot placement; stored
  per-location on the P3c hull instance, so it needs schema/domain changes.
  Re-encode, not copy, the GPL source (as 12B.9). Design in ROADMAP.md first
  before scheduling.
- A mobile field base as a buyable Repair support lance, adding to the repair
  push beyond the Logistics lance's workshop.
- Contracts difficulty display — replace skull/half-skull glyphs (☠/◐) with filled circles (●), keep color coding, rename the column header from 'skulls' to 'difficulty'; touches `src/sim/queries.zig` and `src/tui/app.zig`, smokes required.
- Help overlay UX — screen-specific contextual help filtered to the current screen's active bindings (expand existing stub); design in ROADMAP.md first before scheduling.
