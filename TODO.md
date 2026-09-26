# TODO

Open work only, in the order it is done. One item per branch; it lands
before the next starts (CLAUDE.md). The branch that finishes an item deletes
its line and reports which docs it updated. Finished work lives in git
history, not here.

## Contract compliance (`docs/contract-exceptions.md`)

The contract (`docs/coding-contract.md`) governs all code. Each item below
closes one entry of the exceptions ledger, whose scope lists the verified
sites. A child checkbox is one branch and lands on `main` before the next;
its branch deletes that child line and any baseline, registry or layering
lines it makes stale. The last child also deletes the parent and its exception
entry. Behaviour changes start with a regression test; rule-owner moves add
an owner/consumer agreement test; persistence changes add round-trip and
corruption fixtures. Every branch runs rule 72's complete applicable gate,
including both smoke scripts when it touches their named frontend boundary.

The audit deliverables in `docs/audit-response.md` are folded in: D26 into
C10, D27 and D30 into C12, D28 into C7, D29 into C15, D31 into C8, D33 into
C18 (D23-D25 and D32-D34 are closed). The order below is authoritative and
supersedes the audit response's original delivery order: C4 lands first so
later fixes add responsibility only to the decomposed owner modules.

- [ ] C4 decomposition (rules 5, 14, 76, 77) — first, because the fixes after it add code to modules in the rule 76 registry. Behaviour-preserving, golden hash unchanged, one increment per branch:
  - [ ] C4a `GameState` keeps storage and primitives; subsystem behaviour moves to its owner and `state.zig` imports nothing above the state layer (the C4 layering record). Behaviour-preserving, one increment per branch, in this order; each branch deletes its own line:
    - [ ] C4a7 lift: `transportsBerthedAt`, `transportAvailable`, `ownsCrewedJumpshipAt` and `hasCrewedDropship` to a new `sim/lift.zig`; the unused `availableLift` and `Lift` are deleted.
    - [ ] C4a8 refit: `tryInstall`, `labItems` and `applyRefit` to a new `sim/refit.zig`.
    - [ ] C4a9 held hulls: `holdUnit` and `releaseHull` to a new `sim/held_hulls.zig`.
    - [ ] C4a10 hull condition: `applyHullCondition` to `econ/market.zig`, taking a `std.Random`.
    - [ ] C4a11 readiness: `unitOperational` and `forceOperational` to a new `sim/readiness.zig`.
    - [ ] C4a12 commander multiplier: one owner, `commander.costMultBp` over an optional commander, replacing `Commander.costMultBp` and `GameState.commanderMultBp`.
    - [ ] C4a13 clock: `Date` and `Clock` to `domain/clock.zig`; `DayPhase` to `sim/tick.zig`.
    - [ ] C4a14 events: `sim/events.zig` to `domain/events.zig`.
    - [ ] C4a15 battle report: `autoresolve.zig` to `domain/`; the report record types and `Journal` to `domain/battle_report.zig`; `render` stays in `sim/after_action.zig`.
    - [ ] C4a16 HQ link: `HqLink`, its methods and `linkCost` to `domain/hq_link.zig`; routing and throughput stay in `sim/network.zig`. This branch also deletes C4a.
  - [ ] C4b command facade, one owner family per branch: contracts/events/reports; HQ/network/market/supply; personnel/crew/medical/training; forces/assets/refit; finance/settings/time. Each moves handlers and their private helpers/tests to the existing subsystem owner (or one new owner named for the rule), leaves `Command`, `Result`, `Error` and one-call dispatch arms in `commands.zig`, and introduces the rule-14 prepare/reserve/commit operations needed by that family. The final branch removes `commands.zig` from the rule-76 registry.
  - [ ] C4c query facade, one owner family per branch in this order: finance; contracts/map; personnel/medical; forces/readiness; HQ/network/supply; market/lab; battle/AAR. Each owner builds display-ready values below the `queries.zig` leaf; `queries.zig` retains public re-exports/forwarders only. The final branch removes every moved query-function key and then `queries.zig` from the registry.
  - [ ] C4d TUI application, one controller per branch: session/lobby; campaign wizard; modal stack; command line and completion; settings/media; global tab/layout routing. Screen modules receive typed view/action inputs and do not gain session ownership. The final branch leaves `app.zig` as lifecycle and dispatch glue and removes its module/function/switch registry keys.
  - [ ] C4e persistence, fixtures before moves: schema/version/migration registry; SQLite row primitives; campaign/meta/RNG codecs; people/units/forces codecs; HQ/stock/network/market codecs; contracts/events/reports/log codecs. `store.zig` retains the transaction boundary and public save/load facade; each move preserves the round-trip digest and migration fixtures. The final branch removes `store.zig` from the registry.
  - [ ] C4f battle, one phase per branch: force assembly and estimates; opening/environment; opposed resolution; damage and casualties; salvage/recovery; report/stat commit. `resolveEngagement` becomes orchestration over typed phase results, the golden hash stays unchanged, and the final branch removes the battle module/function registry keys.
  - [ ] C4g contract events, one responsibility per branch: deck data; event selection/queueing; decision lifecycle; typed effect execution. `applyEffectsFor` becomes dispatch to effect owners, with pointer-lifetime and decision tests retained; the final branch removes the module/function/switch registry keys.
  - [ ] C4h remaining registry exits, one branch per semicolon group: `cli.parseVerb`; `checklist.turnWarnings`; REPL and demo loops; `contract_market.refreshBoard`/`refresh`; `tick.runFinances`; `rating.report`; `png.decode`; `meklab.validate`; each registered screen handler/draw function. Each branch decomposes by rule responsibility, preserves behaviour with focused tests, and deletes only the keys it brings below threshold. The last branch deletes C4 and its remaining registry.
- [ ] C2 errors keep their meaning (rules 4, 10, 18, 79), in this order:
  - [ ] C2a arithmetic and pure-query fallbacks: replace impossible `divCeil` catches with checked invariants; propagate allocation/query failures in domain, field-supply, checklist, rating and market code; delete the corresponding baseline lines.
  - [ ] C2b REPL and TUI parsing/results: typed parse refusals replace zero/null sentinels; query failures reach the application error presenter; no successful fallback text is printed after a failed query.
  - [ ] C2c automation and media/path best effort: tick/event automation propagates or records typed failures every time; `execDepot` and PNG preserve their real errors; each genuinely optional music/path/terminal cleanup catch gets a specific `// best-effort:` reason.
  - [ ] C2d player-visible errors: replace every logged `@errorName` with the owning typed sentence, classify every remaining baseline entry, and delete the empty baseline file and C2 entry.
- [ ] C16 scratch memory is scratch (rule 78), after C2 so each allocator is chosen once:
  - [ ] C16a child arenas in tick, commands and field load-out are rooted in operation scratch and reset at the operation boundary.
  - [ ] C16b local battle, personnel, contract-control and command lists use operation scratch or an actually reclaiming allocator; an allocator-growth test proves repeated operations do not grow the campaign arena. Delete C16.
- [ ] C3 money and assets always move with their record (rules 1, 13, 19, 44), one regression-first branch per line:
  - [ ] C3a destination removal defines and tests cancellation/refund for couriers to a sold HQ or disbanded company; no arrival can log receipt without moving funds.
  - [ ] C3b `addStock` and `postTreasury` return typed unknown-site/treasury errors and every caller handles them.
  - [ ] C3c selling an HQ releases or cancels every bay job and leaves each affected hull in the matching stable status.
  - [ ] C3d depot, commander creation and part ordering validate/refuse before hull mutation, clock mutation, money movement or RNG consumption.
  - [ ] C3e GAME OVER derives its wording from final-save success and offers a retry after failure. Delete C3 when every ledger site has its regression.
- [ ] C5 failure atomicity (rules 11-15, 17, 69), each branch adding a `FailingAllocator` digest test for its mutation pattern:
  - [ ] C5a reserve-first primitives: treasury transfer, force creation, unit assignment/move/placement, held-hull release, stock movement and depot queueing expose validate/prepare/reserve/commit operations.
  - [ ] C5b founding: `founding.createCommander` stages RNG and every allocation before committing commander/HQ/staff/funds/policies/stock; `execFoundHq` prepares its log before debit and commit.
  - [ ] C5c compound asset commands: sell/trim stock, hire candidate, link, train ability, tier upgrade, part order and company disband leave state and RNG unchanged on every refusal/failure.
  - [ ] C5d `acceptContract` prepares the contract, lift, load-out, transactions and logs before removing the offer; `commitLift` is all-or-nothing.
  - [ ] C5e `replaceGear` validates and reserves the complete slot batch before changing stock or mounts.
  - [ ] C5f `advance` returns the number of days actually advanced and cannot report failure after a committed day; courier, order, bay-job and weekly-repair phases are idempotent when retried.
  - [ ] C5g every stock mutation result is checked, the CLI may truthfully guarantee refusal changes nothing, and ARCHITECTURE §4 names each reserved resource. Delete C5.
- [ ] C6 identity is typed and returned (rules 16, 32, 56), persistence migrations before frontend adoption:
  - [ ] C6a add persisted typed IDs and monotonic counters for offers, listings, candidates and loans; migrate old rows deterministically and address commands by ID, never collection position.
  - [ ] C6b `Result` returns created HQ, contract, order and loan IDs plus explicit fraud/sourcing outcomes; remove accepted/last-order/last-log and `next_person_id - 1` lookups.
  - [ ] C6c define one persisted/named seat HQ and replace every `hqs.keys()[0]` rule read with the seat or the location actually involved.
  - [ ] C6d checklist rows, pickers, HQ selection and log selection carry typed targets/IDs across query and frontend boundaries; reordering rows cannot change the selected entity. Delete C6.
- [ ] C7 loading fails closed (rules 2, 7, 45-48), in this order:
  - [ ] C7a write the five-class reference-policy table (required live, optional live, historical, derived, sentinel-capable) and drive a post-decode graph validation pass from it; add one orphan/cycle corruption fixture per relationship family.
  - [ ] C7b strict scalar decoding: NULL, booleans, enums, dates, domain ranges, checked integer casts and pending choices either decode exactly or return `CorruptSave`.
  - [ ] C7c strict collections: duplicate keys and overflowing stock sums are refused; counters exceed every loaded ID without overflow; every order-sensitive load has `ORDER BY`; persist and round-trip `Person.secondary_role`.
  - [ ] C7d compatibility repairs become source-version migrations; load neither draws RNG nor synthesizes state; meta rows are required and digest/map ordering is canonical. Update ARCHITECTURE §12 and delete C7.
- [ ] C8 store lifecycle (rules 44, 49, 62, 63), in this order:
  - [ ] C8a open reads and validates the stored version before DDL, closes every failed handle, and runs schema/migrations in one transaction without clamping/defaulting version errors.
  - [ ] C8b SQLite maps actionable result codes, installs a busy timeout, makes `Stmt.run` reject ROW, and adds measured `(cid)` indexes without changing query results.
  - [ ] C8c player deletion and campaign creation/load/save update the live `Session` only after the store transaction succeeds; registry/settings failures get typed application sentences.
  - [ ] C8d emblem, preview, campaign and music replacements acquire the new resource before freeing the old one, with injected-failure tests. Delete C8.
- [ ] C9 schema integrity (rules 50, 51, 70), in this order:
  - [ ] C9a add load-and-migrate fixtures at four representative historical schema boundaries; order migrations by explicit source version and test missing/repeated versions.
  - [ ] C9b table-rebuild migration adds foreign keys, unique `(cid, ord)`/identity keys, domain `CHECK`s and required `ON DELETE CASCADE`; enable and assert `PRAGMA foreign_keys` on every connection.
  - [ ] C9c add adversarial counter/meta tests, keep C7 loader checks for old/damaged stores, update `docs/schema.sql`, and delete C9.
- [ ] C10 location, posture and the seat (rules 21-23, 71), behaviour changes isolated by rule family:
  - [ ] C10a named `CompanyPosture` predicates govern care, rest, rotation, training, leave, mothball/sale, hall crew, returning transfers, field maintenance and checklist counts; idling afield gets no home benefit.
  - [ ] C10b negotiation, freight and every back-office effect read staff at the HQ involved, with two-HQ agreement tests.
  - [ ] C10c medical beds, hospital effects, doctors and medics are site-local; tests cover home, second HQ, deployed and idle-afield care.
  - [ ] C10d one seat/`.outfit` resolver owns fallback location; Lab stock includes only stock the refit can consume; complete two-HQ tests and update ARCHITECTURE §9.7. Delete C10.
- [ ] C11 one rule, one owner (rules 20, 21, 26, 27, 29, 60), one agreement-tested family per branch:
  - [ ] C11a reconcile the copies that already disagree: admin desks; disband quote; medbay cover; effectiveness percentage; incoming-goods ledgers; skill selection and untrained fallbacks.
  - [ ] C11b own finance/travel rules once: HQ sale proceeds, transit/company travel days and reorder wait.
  - [ ] C11c own eligibility/capacity once: offer acceptance, companies at HQ, tier upgrade, lance placement, manning shortfall and `post_person` seat vacating.
  - [ ] C11d own maintenance/supply/support once: medical iteration, needs-part, salvage claim and armor demand.
  - [ ] C11e replace reason-text comparisons and incomplete predicates; split lift quote from commit; rename `canFight` to its actual contract; centralize great-house and crew/medic availability. Delete C11.
- [ ] C12 frontend boundary and results (rules 9, 10, 30, 33-43), in this order:
  - [ ] C12a one typed result presenter serves REPL and TUI; success includes sourcing/fraud details, all refusals come from `cli.errorText`, and eligibility views inform without blocking command execution.
  - [ ] C12b one markup-escaping boundary covers names, paths, music, typed input, echoed verbs, ledger notes and REPL output; hostile-name tests exercise every listed sink.
  - [ ] C12c layout owns all dimensions; resize clamps focus to drawn panes and tests 80-, 119-, 120- and 121-column layouts including absent Forces/Desk panes.
  - [ ] C12d refresh client caches after mutations; separate lobby/tab cursors; move map pan, tab metadata, widgets and cursor behavior to their owners.
  - [ ] C12e every shown key hint and semantic map color comes from its binding/style table, with table-to-screen agreement tests.
  - [ ] C12f REPL client/view verbs parse strictly through `cli.zig`; queries own completion candidates and presentation windows; remove direct catalogue/hash/state reads and duplicate back-office/transfer wording.
  - [ ] C12g create the wizard through `lobby.Session` without a pre-session direct command call; delete all boundary exceptions and C12.
- [ ] C13 numbers, arithmetic, formatting and citations (rules 24, 25, 28, 54, 55, 59), in this order:
  - [ ] C13a move every copied display number, repeated literal and frontend-only limit in the ledger to one named rule owner; fix the false paperwork help line and add owner/consumer tests.
  - [ ] C13b centralize loan interest, payday, week/month/calendar and basis-point money arithmetic; replace fixed 30/365 conversions only through the named calendar rules.
  - [ ] C13c move money/effect/day/ETA/half-ton formatting below queries and make every consumer call it once.
  - [ ] C13d audit all tuning rows and provenance labels: cite a verified source or mark `// TUNE`; make struct/data markers agree. No source or page is inferred. Delete C13.
- [ ] C14 randomness (rule 57):
  - [ ] C14a shared market, company and personnel generators accept a caller-supplied named stream; stream-salt tests prove unrelated streams do not move.
  - [ ] C14b verify and cite every non-2d6 die listed in the exception from a source read during the branch; if a source cannot be verified, stop and report it rather than inventing a citation. Delete C14.
- [ ] C15 routing, trucks, beachhead price (rules 20, 22, 24), one balance change per branch:
  - [ ] C15a one tonnage-aware route quote skips saturated hops, minimizes days then cost then HQ ID, and caps charter fallback; manual and automatic resupply use the same feasible stocked-origin quote.
  - [ ] C15b one passive truck-capacity rule and canonical operational-readiness rule replace hard-coded recounts and `units.len > 0`; storage and active support tests cover destroyed, mothballed, in-transit, in-shop and uncrewed hulls.
  - [ ] C15c one beachhead-distance/rounding rule prices rush supply and renders Map text; implement and test ARCHITECTURE §9.6 field-HQ recovery. Delete C15.
- [ ] C17 focused tests (rule 67), generated inventories refreshed on each branch:
  - [ ] C17a add in-owner rule/consumer agreement tests for every named domain/econ/sim function in the exception; remove each name only when its focused test passes.
  - [ ] C17b cover every public query with normal, empty and refusal/error fixtures, prioritizing values shared by both frontends.
  - [ ] C17c cover every screen binding and empty state from the key tables; regenerate the untested-function counts and delete C17 only at zero scoped omissions.
- [ ] C18 external input bounds (rules 41, 64), one decoder/resource family per branch:
  - [ ] C18a one terminal-cell-width function owns clipping/padding; remove `padCells` and test combining, wide and invalid UTF-8 input.
  - [ ] C18b PNG checks CRC, chunk order, exact inflate length, bounded dimensions/allocation and alpha-preserving fallback, with one fixture per rejection.
  - [ ] C18c database blob and CSI decoders enforce named byte/value caps before allocation or arithmetic.
  - [ ] C18d music stop has a bounded nonblocking reap path and playlist rebuild reuses reclaimable storage. Delete C18.
- [ ] C19 platforms (rule 65), with target builds after each boundary:
  - [ ] C19a isolate terminal raw mode, input and resize behind POSIX and Windows implementations; noninteractive builds compile without POSIX symbols.
  - [ ] C19b isolate child-process lifecycle, executable search/path separators and audio player discovery behind target APIs; unsupported audio degrades through a typed no-player result.
  - [ ] C19c add macOS, Linux and Windows build jobs, reject unsupported targets explicitly, document platform capability, and delete C19.
- [ ] C20 documentation and naming (rules 61, 75, 81, 82, 84), after module splits settle names:
  - [ ] C20a link every MekHQ-counterpart module header to `docs/mekhq-map.md`; correct field-HQ capability and contract-pricing comments, the misplaced comment and wrong §9.8 citations.
  - [ ] C20b split long tech-time formulas and rename weekly-hour functions/callers with their unit; run the header/comment checks and delete C20.

## Tests

- [ ] Smoke coverage, one branch per reproducible path:
  - [ ] GAME OVER: add a deterministic saved campaign already beyond all credit/liquidation, drive the modal through save success and injected save failure/retry, and require clean client exit.
  - [ ] Layout boundary: run the same populated campaign at 119, exactly 120 and 121 columns and assert the documented pane transition, focus and no clipped key hints.
  - [ ] Confirm refusals: inventory every confirmation binding, drive its cancel/no path, and assert unchanged `digest.stateHash` plus the expected view/refusal text.

## Data verification (needs the sourcebooks)

- [ ] `contract.operationsMultBp`: with the CamOps sourcebook available, transcribe the contract-payment table into a test fixture, compare every contract kind, correct only verified mismatches, and cite edition/page on the owner and data row. Stop if the table cannot be verified.
- [ ] Dragoons rating bands (`tuning.zon` `rating`): with the candidate sourcebooks available, identify the governing table (do not assume CamOps or FM: Mercenaries), compare every threshold in a fixture, correct only verified mismatches, and cite edition/page.

## Product completion

These product-depth items begin only after the contract, test and data work
above is complete. Each child checkbox is one branch and lands in order.

- [ ] P1 Brigade HQ:
  - [ ] P1a define the priced/staffed regional-to-brigade project from the existing HQ project rules; only the named seat is eligible and the command enforces one brigade before mutation.
  - [ ] P1b implement the `ARCHITECTURE.md` §9.3 brigade capacity table and facility/staff/upkeep effects through shared owners, with regional-vs-brigade and two-HQ tests.
  - [ ] P1c persist/migrate the tier and project, expose eligibility/progress/capacity in shared queries, REPL and TUI, and update GAMEPLAY/ROADMAP from target to current behavior.
- [ ] P2 battle armor and artillery:
  - [ ] P2a write and approve the missing ROADMAP design first: canonical unit representation, attachment/echelon, crew roles, acquisition data source, maintenance/readiness, transport interaction, and exact battle rules. No catalogue values or rules are inferred.
  - [ ] P2b add the verified catalogue/domain facts and complete acquisition, force placement, crewing, readiness, maintenance and persistence flows for both kinds.
  - [ ] P2c make battle armor attachment affect objective holding and artillery affect pre-resolution attrition exactly as the approved design states; queries, REPL and TUI show attachment/readiness/effects and agreement tests bind battle consumers to the owners.
- [ ] P3 Full MekLab and custom variants:
  - [ ] P3a make engines, gyros, cockpits, actuators, integral heat sinks, jump jets and armor editable construction parts with verified TechManual weight, critical-slot and location rules; canonical designs remain legal.
  - [ ] P3b derive complete A-F refit class, parts and tech-time quotes from one owner and gate them by facility ceiling; illegal fits name the violated rule before stock or bay mutation.
  - [ ] P3c persist campaign-owned custom chassis through an explicit migration and digest coverage; saved variants are buildable, orderable and refittable through the same command/query paths as canonical designs.
  - [ ] P3d expose full construction editing and variant lifecycle through REPL and TUI, including damaged-market-hull completion, then update ARCHITECTURE/ROADMAP from target to current behavior.

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

- A mobile field base as a buyable Repair support lance, adding to the repair push beyond the Logistics lance's workshop.
