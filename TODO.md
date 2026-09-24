# TODO

Open work only, in the order it is done. One item per branch; it lands
before the next starts (CLAUDE.md). The PR that finishes an item deletes
its line and says in its description which docs it updated. Finished work
lives in git history and the merged PRs, not here.

## Contract compliance (`docs/contract-exceptions.md`)

The contract (`docs/coding-contract.md`) governs all code. Each item below
closes one entry of the exceptions ledger, whose scope lists the verified
sites; the pull request that closes an item deletes its ledger entry and any
ratchet or baseline lines, and a large item lands as the increments listed,
each on `main` before the next. Regression test first, then the change. The
audit deliverables in `docs/audit-response.md` are folded in: D26 into C10,
D27 and D30 into C12, D28 into C7, D29 into C15, D31 into C8, D32 into C1,
D33 into C18.

- [ ] C1 the gate is complete (rules 58, 66, 72, 73): data step validates the rank ladder, name pools, Mek legality, skull bands and tuning threshold order/ranges, with an invalid-overlay fixture per family in CI; `-Ddata` fails on a missing directory or zero overlaid files and warns on unknown names; `build.zig.zon` lists its inputs and leaves `data/music` out; CI builds a clean package tree in ReleaseFast and a macOS job; actions pinned by SHA, read-only permissions, no persisted credentials, timeouts, concurrency; smoke scripts own a temp path, refuse a non-`.db` target, reap children, time out; `verify-contract.sh` gains the switch-arm check (rule 76) and a duplicated-pattern check.
- [ ] C4 decomposition (rules 5, 14, 76, 77) — first, because the ratchet holds every oversized module at its size and the fixes after it add code. Behaviour-preserving, golden hash unchanged, one increment per PR:
  - [ ] C4a `GameState` keeps storage and primitives; hashing to `digest.zig`, treasury and pricing/liquidation to econ, hiring to personnel, staffing and founding to `hq_ops`, posture to a posture module, TO&E and crew, tech time to maintenance, lift, supply, refit, aftermath and readiness to their owners (the grouping is in the ledger); `state.zig` stops importing `rating.zig` and `field_supply.zig`.
  - [ ] C4b `commands.zig` keeps the union, dispatch and error set; handlers move to subsystem command modules; the named atomic operations of rule 14 exist.
  - [ ] C4c `queries.zig` keeps the public namespace; view builders move to finance, contracts, personnel, forces, HQ, market and battle query modules.
  - [ ] C4d `tui/app.zig` splits into session/lobby, wizard, modal controllers, command line and settings.
  - [ ] C4e `persist/store.zig` splits into schema and migrations and per-subsystem codecs.
  - [ ] C4f `battle.zig` and C4g `contract_events.zig` split by phase and by deck/effects.
  - [ ] C4h the remaining functions over 100 lines and the eight non-dispatch switches (ledger C4), including `cli.parseVerb`, `checklist.turnWarnings`, the REPL and demo loops, `contract_market.refreshBoard`/`refresh`, `tick.runFinances`, `rating.report`, `png.decode`, `meklab.validate` and the screen handlers.
- [ ] C2 errors keep their meaning (rules 4, 10, 18, 79): every `docs/verify-contract.baseline` entry propagated or given a `// best-effort:` reason, baseline emptied; `execDepot` and `png` stop renaming errors; automation reports its failures; no `@errorName` in log text.
- [ ] C16 scratch memory is scratch (rule 78): child arenas and local lists on `gs.scratch()`, not the campaign arena.
- [ ] C3 money and assets always move with their record (rules 1, 13, 19, 44): couriers to a sold HQ or disbanded company redirected or refunded; `addStock`/`postTreasury` refuse an unknown site; selling an HQ resets its bay hulls; depot refusal leaves the hull untouched; commander creation and `orderPart` refuse before any change or roll; GAME OVER words the dialog from the save result and offers a retry.
- [ ] C5 failure atomicity (rules 11-15, 17, 69), in increments: reserve-first primitives; compound commands (`acceptContract`, asset splits, `replaceGear` as a validated batch, `commitLift`); `advance` reports days advanced and never errors after a tick; tick phases idempotent on retry; stock-mutation results checked; one `FailingAllocator` test per mutation pattern comparing `GameState.hash()`; ARCHITECTURE §4 describes what is reserved.
- [ ] C6 identity is typed and returned (rules 16, 32, 56): offers, listings, candidates and loans addressed by typed id; `Result` carries created ids (HQ, contract, order, loan) and fraud explicitly; no "last" lookups; one named seat HQ; checklist rows carry typed targets; typed picker ids.
- [ ] C7 loading fails closed (rules 2, 7, 45-48): the explicit reference-policy table (required live, optional live, historical, derived, sentinel-capable) drives a post-decode graph pass and the tests; strict stock loader; discriminators, `bool01`, bounded domain decoders including dates; duplicate keys and NULLs refused; counter manifest checked against the highest id; pending choices in range; compatibility repairs moved into versioned migrations; load draws no dice and writes nothing it did not read; checked casts; `ORDER BY` everywhere order matters; digest order policy decided; one corruption test per relationship family; ARCHITECTURE §12 matches.
- [ ] C8 store lifecycle (rules 44, 49, 62, 63): strict version read before DDL, DDL and migrations in one transaction; handle closed on open failure; player deletion atomic with the session reset; SQLite codes mapped to errors with sentences, busy timeout, `Stmt.run` strict; `(cid)` indexes; registry and settings failures worded; nothing freed before its replacement succeeds.
- [ ] C9 schema integrity (rules 50, 51, 70): migration fixtures at four schema boundaries first, migrations in version order naming their source version, then foreign keys, unique `(cid, ord)` keys, `CHECK`s and `ON DELETE CASCADE` through a table-rebuild migration with `PRAGMA foreign_keys` on every connection; counter and meta-row adversarial tests. Loader checks stay.
- [ ] C10 location, posture and the seat (rules 21-23, 71): named predicates switching over `CompanyPosture` for care, rest, rotation reset, training, leave, mothball, sell, crew from the halls, transfers while returning, maintenance afield, checklist counts; negotiation and freight discounts from the HQ involved; medical beds, hospital and doctors per site; one seat/`.outfit` resolution; the Lab counts only stock the refit can use; two-HQ tests for medical, maintenance, hall, negotiation, `hq_ops`, checklist, field supply; ARCHITECTURE §9.7 wording. Balance change: idling afield loses home benefits.
- [ ] C11 one rule, one owner (rules 20, 21, 26, 27, 29, 60): the disagreeing copies first (admin desks, disband quote, medbay cover, effectiveness %, coming ledgers, skill selection and fallbacks), then the other duplicates and incomplete predicates in the ledger; each owner tested against its consumers.
- [ ] C12 frontend boundary and results (rules 9, 10, 30, 33-43): one result presenter for both frontends; eligibility informs, the command decides; refusal sentences only in `cli.errorText`; every untrusted string escaped (names, paths, music, typed input, REPL output) with the hostile-name test covering them; focus clamped to drawn panes on resize and layout, layout numbers in `layout.zig`; client caches refreshed; widgets and cursor helpers single; key hints from the tables; semantic map colours; the REPL parses client and view verbs strictly through `cli.zig`; `queries.completionCandidates`; the wizard's direct execute resolved.
- [ ] C13 numbers, arithmetic, formatting and citations (rules 24, 25, 28, 54, 55, 59): no rule number copied into text; named constants for every repeated literal; money multipliers in basis points; loan, week, month and calendar helpers; the money formatter reachable below the queries; effects formatted once; every tuning row cited or `// TUNE`, provenance labels, struct and data markers agree.
- [ ] C14 randomness (rule 57): shared generators take their stream; every non-2d6 die cited.
- [ ] C15 routing, trucks, beachhead price (rules 20, 22, 24): quote by tonnage that skips full hops, minimises days then cost then HQ id, capped charter fallback; one truck-capacity rule per purpose used everywhere; beachhead distance in one rule with the rounding decided, Map text from it, field-HQ recovery per §9.6.
- [ ] C17 focused tests (rule 67): every rule function listed in the ledger tested against its consumers; the untested queries; each screen's keys and empty states.
- [ ] C18 external input bounds (rules 41, 64): one cell-width function, `padCells` removed; PNG CRCs, chunk order, exact length, pixel limit, alpha; database blob caps; CSI parameter bounds; music stop bounded and the playlist buffer reused.
- [ ] C19 platforms (rule 65): Windows terminal, resize, child process, paths and audio behind target gates; CI builds macOS, Linux and Windows.
- [ ] C20 documentation and naming (rules 61, 75, 81, 82, 84): module headers link `docs/mekhq-map.md`; misplaced comment, wrong §9.8 citations, long formula lines, weekly-hour names.

## Other work

- [ ] D34 asset rights (A33): `ASSETS.md` with source, owner, licence and redistribution terms for `data/music` (OST, OST Part 2, Supplimental Music: the owner's AI-generated tracks, watermarked to the owner's account, the owner holds the usage licence), `docs/logos`, test fixtures and screenshots; `unforgiven.png` at the root removed or used.

## Tests

- [ ] Smoke coverage still missing: the GAME OVER modal (needs a saved campaign already past all credit as a fixture), the exact 120-column layout boundary, and the refusal branch of each confirm.

## Data verification (needs the sourcebooks)

- [ ] `contract.operationsMultBp`: check each contract kind's multiplier against the CamOps contract payment table and cite the page (rule 59).
- [ ] Dragoons rating bands (`tuning.zon` `rating`): confirm the source (FM: Mercenaries rather than CamOps?) and cite the page.

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

- A mobile field base as a buyable Repair support lance, adding to the repair push beyond the Logistics lance's workshop.
