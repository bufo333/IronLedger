# TODO

Authorized Features lists explicitly authorized work: checked entries are delivered;
unchecked entries remain pending. Not scheduled lists unapproved or deferred work.
One cohesive package per branch; it lands before the next starts (CLAUDE.md).
A package has one primary invariant or subsystem outcome.

## Authorized Features

- [x] P2v-a conventional data and provenance: replace the static catalogue with
  verified source facts and pinned source-path provenance.
- [ ] P2v-b conventional market and vehicle parity: replenishing vehicle/fighter
  offers, player acquisition, ownership persistence, and vehicle
  readiness/repair/battle/salvage parity.
- [ ] P2v-c aerospace combat parity: fighter battle, damage, ammunition, salvage,
  AAR, and verified aerospace repair behavior.
- [ ] P2v-d NPC conventional procurement: mek-first vehicle substitution for line
  lances, aerospace procurement for air lances, and replenishing conventional
  reserves without changing the later 16-mek readiness target.
- [ ] P2-design battle-armor/artillery design approval (P2a).
- [ ] P2-battle-armor (P2b-P2d): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- [ ] P2-artillery (P2e-P2g): verified domain facts, acquisition/attachment,
  crewing, readiness, and persistence.
- [ ] P2-battle-ui (P2h-P2i): both battle effects and REPL/TUI surfaces.
- [ ] NPC world-contract design: shared world conflicts and typed opposing forces
  (faction, pirate, or named merc company); player offers, NPC commitments,
  location/transit, pay, readiness, withdrawal, breach, and completion.
- [ ] NPC merc-company identity: unique company names across the campaign; assign
  each unused logo once before creating any logo-less company, then leave
  logo_key empty and continue with collision-free generated names. NPC logo
  display remains deferred.
- [ ] NPC merc-company economy: owner-approved new-campaign target of 12 companies
  with 16 active mechs and 50M C-bills; shared mech-market replacement,
  player-equivalent operating costs, 12-month understrength runway, contract
  income, and liquidation only after no-cash, understrength, and no active
  contract.
- [ ] NPC contract and battle parity: committed companies fight their real roster,
  choose doctrine-based withdrawals, concede or breach when unable to field,
  and never produce zero-vs-zero victories.
- [ ] Desk quarterly P&L report: outfit-wide calendar-quarter index and drill-down
  modal using the ledger's authoritative income, expense, and net totals.
- [ ] Per-location armor data accuracy (lower priority, after P3f): pull the 8 front
  and 3 rear-torso armor values per mech from the MegaMek 3039u MTF files
  (https://github.com/MegaMek/mm-data/tree/main/data/mekfiles/meks/3039u) for
  all 64 `data/chassis.zon` mechs and cross-check ammo-slot placement; stored
  per-location on the P3c hull instance, so it needs schema/domain changes.
  Re-encode, not copy, the GPL source (as 12B.9). Design in ROADMAP.md first
  before scheduling.

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

Deferred indefinitely — uncommitted features. Their ROADMAP.md designs stand;
reschedule only on explicit dispatch.
