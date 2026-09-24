# TODO

Open work only, in the order it is done. One item per branch; it lands
before the next starts (CLAUDE.md). The PR that finishes an item deletes
its line and says in its description which docs it updated. Finished work
lives in git history and the merged PRs, not here.

## Audit fixes (`docs/audit-response.md`, 2026-09-24)

Each item names its deliverable and findings in `docs/audit.md`; the
response gives the evidence and the corrections. Regression test first, then
the change; no module split rides along.

- [ ] D23 pointer lifetimes (A1, A2): `resolveChoice` and `expireDue` copy kind/company/contract/label/effects before any effect and find the event again by id after (the recovery-push walk-out currently logs the wrong event); `chosen` and standing-order memory written after the effects; `queueDecision`'s `mem.value_ptr` not held across `applyEffects`; `Opening.edge_used_by` becomes a `PersonId`.
- [ ] D24 errors after a mutation propagate (A3) — this stops failures being concealed or mislabelled; integrity after an allocation failure is the failure-atomicity item's: `runPolicies` and ship-components-home `shipStock` catch only `InsufficientTreasury`; `commands.zig` purchase paths (`placeUnitInCompany`/`moveUnitToForce` `catch return UnknownForce`, `postToHq catch return UnknownHq`) return the real error.
- [ ] D25 turn safety and strict verbs (A9, A10, A12): one `cli` parser for `day <n> [force]` (range-checked, nothing trailing) used by both frontends; TUI `:day` goes through `endTurnRequest`; every advance length opens the checklist; `:save`/`:quit`/`:manning` refuse trailing words; `stockpolicy` keeps an explicit 0 target (removes). Decide whether blocking checklist warnings refuse an unforced advance or are advisory, and make `WarningKind.blocking`, `docs/tui.md` and GAMEPLAY say the same.
- [ ] D26 posture-owned location rules (A8): named predicates switching over `CompanyPosture` (care, rest, rotation reset, training, leave, mothball, sell, crew from the halls, transfers while returning, maintenance penalty afield); checklist wounded count uses the same rule; posture × rule matrix test; fix ARCHITECTURE:568 ("sat undeployed") to match §9.7. Balance change: idling afield loses home benefits.
- [ ] D27 one result presenter (A11): `Command` + `Result` → sentence below the frontends, used by the REPL, the TUI command line, the amount forms and screen keys; order form reports a failed sourcing; `buy_listing` reports fraud (REPL and Market `b` say so).
- [ ] Full failure atomicity (rules 11-14, 69; A1, A3): reserve-first `transferFunds`, `createForce`, `assignUnit` (validate ids first), `moveUnitToForce`, `placeUnitInCompany`, `holdUnit` (reserve for the whole loop), `releaseHull`; decisions as prepare/commit; log lines and effects prepared before the first mutation; staged RNG; one `FailingAllocator` test per mutation pattern comparing `GameState.hash()`; ARCHITECTURE §4 describes what is actually reserved.
- [ ] D28 loading fails closed (A4-A7): an explicit reference-policy table classifies every reference column — required live, optional live, historical, derived, sentinel-capable — and the post-decode graph pass and the tests read it; strict stock loader instead of `addStock`, duplicate keys and NULLs refused, stock sums checked; exhaustive discriminators, `bool01`, bounded domain decoders, unknown optional enums refused; one counter manifest — every counter row required and above the highest id (units include held hulls), 0 and max refused, v5 fixture given its counters; pending `default_choice` in range and `chosen` null; one corruption test per relationship family; ARCHITECTURE §12 matches.
- [ ] D29 routing, trucks, beachhead price (A15-A17): quote by tonnage that skips full hops, minimises days then cost then HQ id, commits the quoted path, capped charter fallback (ARCHITECTURE §9.5 states the policy); one truck-capacity rule per purpose (salvage operational, storage present) used by battle, field supply and queries, no hard-coded 20t/5t, salvage and mess lance bonuses by `forceOperational`; beachhead distance from contract `dist_ly` and offering HQ in one rule with the rounding decided, Map multiplier text from it, field-HQ recovery per §9.6.
- [ ] D30 frontend boundary (A13, A18, A19, A37, A36): eligibility dims rows but activation always submits the command; `execResultWith` sentences move into `cli.errorText`; wizard names, logo filenames, echoed verbs and ledger notes escaped, hostile-name test covers them; Forces declares one narrow pane and a test maps every focus index to a drawn pane at 80, 119, 120 and 121 columns; `queries.completionCandidates` replaces `cli.completionPool`'s state walk; demo's `gs.hash()` behind a query.
- [ ] D31 store lifecycle (A23-A26, A28): version read strictly before any DDL, DDL and migrations in one transaction, version < 1 refused; handle closed on open failure, `errdefer` in `Store.open`; player deletion in one transaction and the open session reset; extended SQLite codes mapped to `StoreBusy`/`StoreReadOnly`/`StoreFull`/`CorruptStore`/`ConstraintViolation` with sentences, busy timeout; non-unique `(cid)`/`(cid, parent, ord)` indexes.
- [ ] D32 build, data and CI (A14, A29-A32, A34; rule 66): rank ladder, name pools, weights, canonical legality and skull bands validated by the data step, with an invalid-overlay fixture per family in CI; `-Ddata` fails on a missing directory or zero overlaid files and warns on unknown names; `build.zig.zon` lists its inputs and leaves `data/music` out; CI builds a clean package tree (only the `.paths`) in ReleaseFast and adds a macOS job; actions pinned by SHA, read-only permissions, no persisted credentials, timeouts, concurrency; smoke scripts own a temp path, refuse a non-`.db` target, reap children and time out.

## Adopting the revised contract

`docs/coding-contract-proposed-updated.md` becomes the contract when its full
gate passes; until then `docs/coding-contract.md` governs.

- [ ] Migration fixtures at four schema boundaries (A27) — contracts, listings, pending events, battle reports — checking schema, idempotence, rollback and newer-store refusal without mutation; then SQL foreign keys, unique `(cid, ord)` keys, `CHECK`s mirroring D28's decoders and `ON DELETE CASCADE` through a table-rebuild migration, with `PRAGMA foreign_keys` on every connection (rule 50). Loader checks stay.
- [ ] Subsystem behaviour off `GameState` (rule 77): the hash into `digest.zig`, pricing, staffing and the rest into their owning modules.
- [ ] Windows: target-gated terminal (console API, raw mode), resize without SIGWINCH, a music player without `afplay`, paths; CI builds macOS, Linux and Windows (rule 65).
- [ ] Rule citations renumbered to the new contract in one PR: `src/`, docs, CLAUDE.md (hard rules; the "section 9 checklist" becomes section 11), test names.
- [ ] Adoption PR: the proposal replaces `docs/coding-contract.md` as "Coding contract", every gate command passes on that commit, and the remaining violations are listed as rule-87 exceptions: the seven modules over 1,000 lines (queries, commands, app, store, battle, state, contract_events), each tied to a split scheduled after adoption (A35), and the wizard's pre-session `commands.execute`.

## After adoption

- [ ] D33 terminal text and media inputs (A20-A22): one `wcwidth`-style width for draw/measure/clip/pad/wrap, `queries.padCells` removed; music stop polls with `WNOHANG` then SIGKILL, one reused order buffer; PNG CRCs, chunk order, exact inflate length, an emblem pixel limit, alpha blended in the half-block fallback, malformed/oversized/transparent fixtures.
- [ ] D34 asset rights (A33): `ASSETS.md` with source, owner, licence and redistribution terms for `data/music` (OST, OST Part 2, Supplimental Music), `docs/logos`, test fixtures and screenshots; `unforgiven.png` at the root removed or used. Needs the owner's rights statement for every music set first.

## Tests

- [ ] Smoke coverage still missing: the GAME OVER modal (needs a saved campaign already past all credit as a fixture), the exact 120-column layout boundary, and the refusal branch of each confirm.

## Data verification (needs the sourcebooks)

- [ ] `contract.operationsMultBp`: check each contract kind's multiplier against the CamOps contract payment table and cite the page (rule 6).
- [ ] Dragoons rating bands (`tuning.zon` `rating`): confirm the source (FM: Mercenaries rather than CamOps?) and cite the page.

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

- Per-site hospital and doctor capacity (audit #7).
- A mobile field base as a buyable Repair support lance, adding to the repair push beyond the Logistics lance's workshop.
