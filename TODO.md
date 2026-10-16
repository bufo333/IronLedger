# TODO

Authorized Features lists explicitly authorized work: checked entries are delivered;
unchecked entries remain pending. Not scheduled lists unapproved or deferred work.
One cohesive package per branch; it lands before the next starts (CLAUDE.md).
A package has one primary invariant or subsystem outcome.

## Authorized Features

- [x] P2v-a conventional data and provenance: replace the static catalogue with
  verified source facts and pinned source-path provenance.
- [x] P2v-b conventional market and vehicle parity: replenishing vehicle/fighter
  offers, player acquisition, ownership persistence, and vehicle
  readiness/repair/battle/salvage parity.
- [x] P2v-c aerospace combat parity: fighter battle, damage, ammunition, salvage,
  AAR, and verified aerospace repair behavior.
- [x] P2v-d NPC conventional procurement: mek-first vehicle substitution for line
  lances, aerospace procurement for air lances, and replenishing conventional
  reserves without changing the later 16-mek readiness target.
- [x] P2-design battle-armor/artillery design approval (P2a).
- [ ] P2-battle-armor (P2b-P2d): deferred because Inner Sphere battle armor is
  unavailable in the 3025 campaign era. It requires an explicitly approved
  campaign-era expansion beyond 3025, pinned MegaMek GitHub records verifying
  each candidate's actual later introduction date, and full P2a research before
  a separately approved implementation plan; verified domain facts,
  acquisition/attachment, crewing, readiness, and persistence.
- [x] P2e artillery domain catalogue: verified Mobile Long Tom construction
  facts, provenance, calculated BV/cost, and static artillery category.
- [x] P2f artillery acquisition and attachment: Mobile Long Tom ownership,
  market acquisition, placement, transport, and persisted formation identity.
- [x] P2g artillery operations: crewing, readiness, reloads, repairs, supply,
  operational persistence, and truthful existing personnel/shared-bay views.
- [x] P2h artillery battle effects: atomic engagements, firing/ammunition,
  carrier casualties/recovery/disposal, persistent reports and existing AAR panes.
- [x] P2i artillery REPL/TUI/query surfaces: dedicated controls and panels;
  battle-armor UI remains deferred with P2b-P2d.
- [x] P5a time, the turn is the next stop (ROADMAP P5a): advance-until-stop
  command with a day cap beside the unchanged `advance_days`; one stop owner in
  `checklist.zig`; stops inside and outside a contract as listed; notices batch
  into the digest; the stop screen names the reason and opens the screen; `n`
  binds to it; an auto advance never crosses a decision deadline.
- [x] Phase-atomic daily tick (rule 17): `advance` and `advance_until_stop`
  return an error only with the campaign exactly as before the command (a
  campaign backup taken at the start and restored on error, with rule 17
  retry semantics: a retry reruns the command from that campaign);
  `advance`'s zero-day fold is a typed `.bankrupt` success. Closed
  docs/contract-exceptions.md "Advance commits partial days".
- [x] P5b.1 the battle you can touch (ROADMAP P5b): phased autoresolve (contact,
  decisive, pursuit or withdrawal) under one seed; a pause between phases with
  recomputed odds and the existing interventions (ROE, tactical withdrawal);
  AAR names each phase; fixed-seed and refusal tests.
- [x] P5b.2 the battle you can touch (ROADMAP P5b): the existing interventions
  (reserve commit, air cover, command capacity); AAR and operation record name
  each intervention; fixed-seed and refusal tests.
- [x] P5c situations slice (ROADMAP P5c.1–P5c.4): actor-owned situations with
  typed flags on relationship and world state; three situations on the garrison
  arc with one callback inside the contract; the matching event deck retired.
- [ ] Playtest gate: John plays the P5a–P5c slice on one garrison contract before
  P5d is dispatched. If it is not fun, P5d onward is redesigned in ROADMAP.md
  before scheduling. P5a's stop cadence measures one to four stops per garrison
  month on seed 4200 against ROADMAP P5a's four to six, for John to judge in
  play; ROADMAP P5a.2's operation-available or arc-beat stop is not yet
  implemented.
- [x] P5d.1 conflict-world design: `docs/p5d-conflict-world-design.md` designs
  the conflict-first world (§A–§K) and NPC company operations (§L), maps every
  clause of the former P5d.1 and P5d.4 entries to an increment below, and
  records decisions D1–D29.
- [ ] P5d.2 NPC merc-company identity: unique company names across the campaign;
  assign each unused logo once before creating any logo-less company, then
  leave logo_key empty and continue with collision-free generated names. NPC
  logo display remains deferred.
- [x] P5d.3 NPC merc-company lifecycle visibility and hull disposition: every
  merc company founding and dissolution (with its cause) is a `[merc]`
  campaign-log line; a held field with no salvage claim strikes the destroyed
  drawn hulls off (`finalizeDestroyedWreck`), the stale-active-hull defect its
  regression reproduced; every merc company holds a roster entry from creation,
  durable when empty, so `mercCompanyInsolvent` judges a replacement that
  bought nothing. Lost-field recovery is unchanged; player financing is out of
  scope.
- [x] P5d.4a paid NPC black-market buys: merc black-market draws debit the
  listing price in the hull-transfer commit and take only a known chassis the
  company still needs (`rivals.mercCompanyNeedsHull`, shared with the lifecycle
  buy) within its remaining cash, the unpaid-draw defect its regression
  reproduced; pirates are unchanged.
- [ ] P5d.4b NPC roster bands: a band on every company from a validated
  `merc_bands.zon`; band-scaled seed of 12 companies with four lances (16
  active mechs) and capital per D25 (50M at `band_4`); shared mech-market
  replacement and readiness read band targets instead of the flat 8. Needs
  P5d.4a and D23–D25.
- [ ] P5d.4c NPC dissolution safeguard: dissolution only on cash below zero, a
  12-month understrength runway and no active commitment; `understrength_since`
  persisted; the cause is logged. Needs P5d.4b.
- [ ] P5d.1a personage record: every hiring world has a procedural planetary
  ruler and every hiring faction a leader, persisted; a `.politics` stream;
  REPL `who`. Needs D6 and D7.
- [ ] P5d.1b who's-who surface: TUI who's-who modal and query rows with the
  provenance label. Needs P5d.1a.
- [ ] P5d.1c personage relations: kin, liege, rival, ally and grudge relations
  generated and shown. Needs P5d.1a.
- [ ] P5d.1d canon and authored personages: `personages.zon` with provenance,
  validator, fixtures and a corpus report; Sarna facts re-verified against
  their pages; Sarna credit. Needs P5d.1a and D6–D8.
- [ ] P5d.1e conflict record: monthly schemes open conflicts from about 12
  templates with the timeline and local and strike forces; NPC-only
  resolution; REPL `conflicts`; log lines; the board is unchanged. Needs
  P5d.1a and P5d.1c.
- [ ] P5d.1f board from conflicts: offers come only from conflicts, with side,
  on-station and close days and a cause line; `TooLateToArrive` and
  `OppositeSide` refusals; the opposition is the local or strike force. Needs
  P5d.1e.
- [ ] P5d.1g news reach and Newswire: one reach owner (absorbing the
  company-position rule), news items, the Newswire pane and REPL `news` for
  conflict open, discovery and resolution. Needs P5d.1e.
- [ ] P5d.1h NPC operating base and location: every NPC company has a base and
  current world and a flat ready day; purchases limited to base market reach;
  shown in the company list; no movement yet. Needs P5d.2, P5d.3 and P5d.4b.
- [ ] P5d.4d NPC hull condition and base repair: a persisted condition per NPC
  hull written by battle and lost-field recovery; repair at base priced by the
  player's maintenance owners; fieldable BV and readiness read condition.
  Needs P5d.1h.
- [ ] P5d.4e NPC parts procurement: a spares stock bought within base reach;
  repair consumes spares; "awaiting parts" deferral. Needs P5d.4d.
- [ ] P5d.1i NPC movement: one movement per company under the shared travel
  rule; status derived by one owner; return home. Needs P5d.1h.
- [ ] P5d.1j aggressor hires: commitments with employer and mandate made while
  a conflict prepares, with the arrival-by test; pay, transport fee and share;
  release and break. Needs P5d.1e and P5d.1i.
- [ ] P5d.4f NPC operating ledger: commitment pay and transport share in;
  player-equivalent upkeep, payroll and transport fees out; reserve floor of
  months × burn. Needs P5d.1j and P5d.4e.
- [ ] P5d.4g NPC cash-pressure ladder and sales: one sale owner at real
  condition price; ladder steps in order; dissolution liquidates through it.
  Needs P5d.4c and P5d.4f.
- [ ] P5d.4h NPC post-contract recovery: release, travel home and refit; ready
  day derived from the projected repair backlog; the no-passive-decay recovery
  invariant. Needs P5d.1j, P5d.4d and P5d.4e.
- [ ] P5d.1k present forces are the opposition: committed companies present on
  the battle day feed the opposition pool and the briefing; the counter-hire
  is deleted; late-arrival notice. Needs P5d.1f and P5d.1j.
- [ ] P5d.5 NPC contract and battle parity, minus the opposition route met by
  P5d.1k: committed companies fight their real roster, choose doctrine-based
  withdrawals, concede or breach when unable to field, and never produce
  zero-vs-zero victories; a rival met as opposing force is named in the
  briefing and AAR and its standing moves. Needs P5d.1k.
- [ ] P5d.1l defender reaction and late hiring: discovery alerts, defender hires
  and escalation hires, each with a cause. Needs P5d.1k.
- [ ] P5d.1m quiet-contract threats: garrison and cadre threats as travelling
  child conflicts; a stop on discovery. Needs P5d.1k.
- [ ] P5d.4i NPC replacement reach and upgrades: replacement within base reach
  and the reserve floor; one-for-one upgrades sold through the sale owner.
  Needs P5d.4g.
- [ ] P5d.4j NPC earned growth and air: band promotion and demotion with a
  logged cause; the automatic aerospace reserve replaced by an earned optional
  air lance. Needs P5d.4i and D26.
- [ ] P5d.4k co-located recruiting: a rival based on or present at the player's
  world recruits a discontented person through the existing retention rules;
  the departure names the rival. Needs P5d.1h.
- [ ] P5d.1n intrigue and beats: beat and intrigue event families; scheduled
  beats. Needs P5d.1c and P5d.1g.
- [ ] P5d.1o competition: NPC bids fill positions (`PositionFilled`, causes
  including arrival); a fill becomes a commitment. Needs P5d.1f and P5d.1j.
- [ ] P5d.1p political decisions: in-reach, stake-bearing happenings raise
  personage-owned inbox decisions with a deadline and default. Needs P5d.1g
  and P5d.1n.
- [ ] P5d.4l NPC artillery: only if John chooses NPC artillery (D29); an
  architecture plan for NPC artillery ownership, then earned artillery growth.
  Needs P5d.4j.
- [ ] P5d content expansion: personage and scenario corpus growth toward the
  design's target; data only. Needs P5d.1d and P5d.1n.
- [ ] P5d.6–P5d.7 employer patience and Desk runway: a house can drop the outfit
  from its board for a shown period with the reason; months of runway from the
  ledger on the Desk, red below a `// TUNE` threshold.
- [ ] P5c content expansion: situations for every arc family with callbacks
  across contracts; remaining event decks retired.
- [ ] P5e people as a cast (ROADMAP P5e): active officer proposals, one bounded
  want per person, named-loss situations, recruits with a strength, a flaw and
  a want.
- [ ] P5f negotiation as play (ROADMAP P5f): bounded multi-round haggle with the
  employer actor; rival bids set the clock (after P5d.1o); signed terms show
  their consequences.
- [ ] P5g reach, not capacity (ROADMAP P5g.1–P5g.3): HQ tier gates employers,
  contract tier and rare markets; field-HQ charters granted by the planetary
  ruler (after P5d.1a) with obligations; raidable HQs fought with the P5b
  battle, the raid a conflict with a travelling aggressor (after P5d.1m).
- [ ] P5g.4 Forward-depot stocking (ROADMAP "Forward-depot stocking"):
  keep-stocked lines at any HQ source from another HQ's shelf before the
  catalogue, the sender paying freight; failed keep-stocked and resupply lines
  log the day they fail and show on the F6 inbound pane with the reason; a
  level-0 warehouse refusal names the staffing cause; HQ links and the charter
  cap show on F6/F7; the found flow warns that a new field HQ is empty,
  unfunded and unstaffed. Updates ARCHITECTURE.md §9.5 and docs/tui.md.
- [ ] P5h ambition and ending (ROADMAP P5h): one ambition chosen at founding with
  Desk milestones (a named grudge is a personage relation, after P5d.1c), a
  final contract or finale, a scored campaign summary.
- [ ] P5i.1 Desk quarterly P&L report: outfit-wide calendar-quarter index and
  drill-down modal using the ledger's authoritative income, expense, and net
  totals, beside the runway number.
- [ ] P5i.2 TUI command parity (ROADMAP "TUI command parity"): first a verb→key
  coverage matrix in docs/tui.md over every `cli.verbs` entry, including the
  P5a stop screen and P5b phase report; then the F6 ship form offers HQ
  destinations, F2 `f` opens a name modal for `found`, and `link`/`assignco`
  gain F7 keys.
- [ ] P5i.3 Per-location armor data accuracy (lowest priority): pull the 8 front
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

- [ ] Const view read path: give the frontend/view read path a `*const
  GameState` so view code cannot mutate campaign state through the pointer it
  reads; mutation stays reachable only through `commands.execute` (contract
  rules 7, 8, 31). Because Zig `const` coercion is one-directional, this reaches
  the whole `src/sim/queries.zig` read path, the sim read-helpers it calls
  (`posture`, `readiness`, `battle`, `contract_control`, `operations`, `lift`,
  `maintenance`, `toe`), and the shared `GameState` interior-pointer accessors
  (`person`, `unit`, `force`, `deploymentContract`, `actor`, `rival`,
  `officerArc`, `refitPlanFor`), so the end state changes the `GameState`
  accessor surface (a public API) and spans more than one cohesive branch
  (rule 86). The accessor API strategy — additive const read variants,
  const-canonical accessors with explicit mutation paths, or a read-only view
  wrapper — is unresolved. Design in ROADMAP.md first before scheduling; needs
  its own approved plan(s).
