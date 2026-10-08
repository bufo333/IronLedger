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
- P2a conventional data and provenance: correct the approved initial chassis
  catalogue with verified source facts and source-path provenance.
- P2b conventional market and vehicle parity: replenishing vehicle/fighter
  offers, player acquisition, ownership persistence, and vehicle
  readiness/repair/battle/salvage parity.
- P2c aerospace combat parity: fighter battle, damage, ammunition, salvage,
  AAR, and verified aerospace repair behavior.
- P2d NPC conventional procurement: mek-first vehicle substitution for line
  lances, aerospace procurement for air lances, and replenishing conventional
  reserves without changing the later 16-mek readiness target.
- P2-design battle-armor/artillery design approval (P2a).
- P2-battle-armor (P2b-P2d): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- P2-artillery (P2e-P2g): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- P2-battle-ui (P2h-P2i): both battle effects and REPL/TUI surfaces.

- NPC world-contract design: shared world conflicts and typed opposing forces
  (faction, pirate, or named merc company); player offers, NPC commitments,
  location/transit, pay, readiness, withdrawal, breach, and completion.
- NPC merc-company identity: unique company names across the campaign; assign
  each unused logo once before creating any logo-less company, then leave
  logo_key empty and continue with collision-free generated names. NPC logo
  display remains deferred.
- NPC merc-company economy: owner-approved new-campaign target of 12 companies
  with 16 active mechs and 50M C-bills; shared mech-market replacement,
  player-equivalent operating costs, 12-month understrength runway, contract
  income, and liquidation only after no-cash, understrength, and no active
  contract.
- NPC contract and battle parity: committed companies fight their real roster,
  choose doctrine-based withdrawals, concede or breach when unable to field,
  and never produce zero-vs-zero victories.
- Desk quarterly P&L report: outfit-wide calendar-quarter index and drill-down
  modal using the ledger's authoritative income, expense, and net totals.
- Per-location armor data accuracy (lower priority, after P3f): pull the 8 front
  and 3 rear-torso armor values per mech from the MegaMek 3039u MTF files
  (https://github.com/MegaMek/mm-data/tree/main/data/mekfiles/meks/3039u) for
  all 64 `data/chassis.zon` mechs and cross-check ammo-slot placement; stored
  per-location on the P3c hull instance, so it needs schema/domain changes.
  Re-encode, not copy, the GPL source (as 12B.9). Design in ROADMAP.md first
  before scheduling.
- A mobile field base as a buyable Repair support lance, adding to the repair
  push beyond the Logistics lance's workshop.
