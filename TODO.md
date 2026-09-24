# TODO — the one list of open work

Every piece of work not yet on `main`, in the order it is done. One item
(or one deliverable) per branch; it lands before the next starts
(CLAUDE.md). Tick items as the PR that closes them merges; delete a
section when it is empty.

**Order (decided 2026-09-23):** finish Stage 12 first, so the game is
fully implemented; code-quality work comes after. Deep changes to how
the code works wait until nothing is mid-implementation.

- **Part 1, Stage 12 features.** The design for each lives in its
  `ROADMAP.md` entry; this list tracks it.
- **Part 2, code quality.** Deviations from `docs/coding-contract.md`
  (D12–D13, from the internal contract audit of 2026-09-22) and the
  external audit of 2026-09-23 (D14–D22; `docs/audit.md`, and
  `docs/audit-response.md` for what we accepted and why). Each item names
  its contract rule; each audit deliverable names its finding numbers.
- **Part 3, adopting the revised contract.** The infrastructure the
  proposed contract's gate needs, then the adoption itself.

Line numbers are as of the day an item was filed and drift as PRs land;
the rule and the symbol are the stable key.

---

# Part 1 — Finish Stage 12

Every Stage 12 feature (12, 12B–12G) has shipped.

---

# Part 2 — Code quality

## D12. TUI structure (contract rules 18-25)

- [ ] `drawWizard` into per-step functions.
- [ ] **One key table per screen** (rule 22): the footers are in `screen_table`; pane right-titles, modal titles, help rows and in-pane hints still carry their own key text; `docs/tui.md` key table generated or checked by the smoke.

## D13. Tests and CI (contract rules 37-40)

- [ ] Still uncovered by the smoke: the GAME OVER modal (a fresh campaign starts solvent, so reaching it needs a saved campaign already past all credit as a test fixture; bankruptcy itself stays terminal by design), the exact 120-column layout boundary, and the refusal branch of each confirm once run (they open and close only).

## D19. Terminal safety (audit #15, #16; rule 24)

D19a, D19b-1, D19b-2a and D19b-2b are done (see Done); the typed endpoint is left.


- [ ] Endpoint for untrusted text (decided in review): a type that makes unsafe composition fail to compile (e.g. an `Untrusted` wrapper on stored names, or `MarkupBuilder` as the only way a query composes markup), plus the Part 3 verify-script check. Until then the convention holds: query `text`/`cells`/`lines`/titles are escaped markup, query `name` fields are raw values, and whoever composes a raw name into markup calls `table.plain`.

## D22a. Comments and citations (contract rule 43)

- [ ] Rewrite existing comments to rule 43 (proposal rules 82–84), using the reviewer greps in proposal rule 84. As of 2026-09-23: 42 history or attribution lines, 708 stage tags outside `//!` headers, 133 stage-prefixed test names, one `TODO(stage-4)` (domain/contract.zig). Also trim narrative doc comments to the caller-visible contract, and replace "mirrors" with precise counterpart or adaptation labels. One PR per layer (domain/econ/gen, sim, persist, tui). Until the sweep lands, `verify-contract.sh` checks against a recorded baseline so only new violations fail.

## D22. Build, data and tests (audit #20, #24, #25, #26, #28; rules 6, 9)

- [ ] `build.zig.zon` `.paths` adds `docs/logos` and `LICENSE`.
- [ ] `commands.freightQuote` literals into `tuning.logistics`: 2,000 C-bills per ton per jump (both legs), 500 bp off per transport admin up to 4, the 3-day floor (rule 6).
- [ ] `tuning.zig:743` validation keyed on field type (`Bp` → 0..100_000, `CBills` ≥ 0) with an explicit allow-list for signed deltas; today the bp bound runs on no field at all.
- [ ] `validate-data` build step running the cross-file checks; install with `-Ddata` depends on it (an empty `rat.zon` fails the build, not the run); it includes the markup-safety test over every data string (`table.unsafeString`).
- [ ] In-file tests for `app.zig` and each `screens/*.zig`: row identity (after D21), cursor clamp on resize, key handlers against a generated campaign.
- [ ] `commands.execute` becomes a dispatch switch into per-subsystem functions; `Store.load` becomes per-table decoders. Last, because it moves every cited line.

---

## Design backlog (not defects, not scheduled)

Ideas that would change the game rather than fix it; each needs its design written in ROADMAP.md before it is scheduled.

- Per-site hospital and doctor capacity (audit #7): ARCHITECTURE.md never specified per-site care.
- A mobile field base as a buyable support asset (ARCHITECTURE §3.4 "field repair capacity"): a Repair support lance with a chassis cited to its sourcebook, sold through the support train, adding to the repair push beyond the Logistics lance's workshop.

---

# Done

Contract deliverables closed before this list merged, all from the 2026-09-22 contract audit. The full item lists are in git history (`docs/contract-todo.md` at `7441a14`).

- D0 one rule for structural needs (PR #3) · D1 the contract itself (PR #4) · D2 layering and core purity (PR #5) · D3 entity predicates (PR #6) · D4 one computation, one function (PR #7) · D5 ledgers (PR #8) · D6 numbers appear once (PRs #9, #10, #20) · D7 formatting helpers (PR #11) · D8 commands leave state consistent (PR #12) · D9 rules move out of queries (PR #13) · D10 REPL printers as query loops (PR #14) · D11 TUI boundary (PR #15) · D12a–c TUI structure (PRs #16, #17, #19, #22) · D13 tests and CI (PR #21, one item left above)
- D14 gameplay corruption, audit #1–#3 (PR #53): black-market fraud returns no hull instead of `next_unit_id - 1`; refit demand is counted per part before any is taken; `next_battle_id` is saved and resumed past every referenced battle
- D15a save identity, audit #4–#5 (PR #54): a first save sets `campaign_id` only after COMMIT; saving over a missing campaign row and loading an unknown id both return `NoSuchCampaign`; the TUI and REPL print `cli.errorText` for save errors
- D15b loading fails closed, audit #13 (PR #55): every stored integer and id is range-checked (`Stmt.intAs`, `fit`, `toId`); missing parent rows, unknown enum values, unknown treasury/site kinds and a bad difficulty return `CorruptSave` instead of being skipped or defaulted
- D15c RNG persisted per stream, audit #18 (PR #56): schema v32 saves one `rng_stream` row per named stream (format 1, little-endian words) plus the seed; a stream missing from a save starts fresh from the seed, so adding one no longer reseeds old saves; v31 blobs still load; malformed or unknown rows are `CorruptSave`. Audit #14 closed with it: SQL foreign keys wait for a schema change that rebuilds tables, and the loader is the integrity check
- D16a support readiness, audit #10 and #7's MASH bug (PR #57): `GameState.unitOperational` (can take the field, crew fit for duty) and `forceOperational` are the one readiness test for support modifiers, recon, air cover, MASH beds, the battle line and fieldable BV; wounds get `medical.Care` (home, field with a ready MASH, field without), so the MASH multiplier needs an operational MASH truck
- D16b field bed ties, audit #8 (PR #58): field beds are handed out in one pass over the priority-sorted patients with a beds-left count per company; ROADMAP 9C.2 corrected (decided 2026-09-23): reloads need a tech but no hours, and uncovered work waits for the next weekly pass
- D16c vehicle skills, audit #9 (PR #59): `Role.pilotingSkill` beside `Role.primarySkill` is the one role-to-skill pair; the battle reads the hull kind's crew skills (a vehicle fights on gunnery_vee/driving_vee), and escape, recovery, `experience()` and the roster text use the same pair
- D16d conceded engagements, audit #11 (PR #60): `battle.concede` records a conceded `BattleReport` (defeat) that holds the turn, counts a lost battle and a battle fought, and scores `tuning.battle.score.concede` through `recordBattle` (VP at the usual rate); the after-action sheet shows what was given up instead of an empty fight
- D16e the field workshop (PR #61, decided 2026-09-23): a ready Logistics lance adds `tuning.maintenance.push_workshop_hours` to the repair push budget; the unread `CampaignMods.has_field_repair` flag and the orphan `mobile_field_base` unit kind (no chassis could field one) are gone
- D17a freight accounting, audit #12 (PR #62): `freightQuote` is pure (checks `network.fitsThroughput`, books nothing) and `commitFreight` books the tonnage after the payment clears, in `shipStock` and `orderPart`; one `logistics.linkTonsPerWeek` (`throughput_per_level` × `tons_per_supply_unit`, the renamed `weeks_of_capacity`) answers every link and route
- D17b slots before money, audit #6 (PR #63): HQ founding (`prepareHq`/`commitHq`), fabrication, facility upgrade, unit transfer, refit commit and `resolveChoice` reserve their ledger and list slots (`GameState.reserveLedger`, `ensureUnusedCapacity`) before the first mutation, so no list growth fails after money or stock moves
- D18a home-HQ training and rest, audit #21 (PR #64): `GameState.homeHqOf` (posting, else company home) and `trainingHqFor` replace the three any-HQ training loops; training days use that HQ's HR; weekly rest uses the home HQ's mess and HR per person
- D18b recruiting and intel locality, audit #21 (PR #65): `recruitBonus(hq)` and `recruitGenerated(role, hq)` read the recruiting HQ's hiring hall and HR (hall boards, office staffing, company crews at the company's home HQ; the bare `recruit` verb hires at the seat); `offer_rating.intelLevel(gs, hq)` reads one HQ's comms and `intelHq` picks the board that offered the contract, else the company's home HQ
- D19a renderer safety, audit #15/#16 (PR #66): `table.nextGlyph` is the one decoder for drawing and measuring (invalid or truncated UTF-8 is U+FFFD, C0/C1 controls and DEL are `?`); the encode fallback writes U+FFFD; `Screen.resize` allocates before it frees; `Term.init` restores raw mode, the resize handler and the main screen if it fails part way
- D19b-1 one markup tokenizer, audit #15 (PR #67): `table.Tokenizer` is the one reader of screen markup (drawing, width, padding, wrapping, plain CLI text); `{{` is a literal brace; `MarkupBuilder` (`appendPlain` sanitizes and escapes, `appendMarkup` for trusted literals) and `table.plain`; `queries.stripMarks` is `table.plainText`, which knows every tag and sanitizes controls
- D19b-2a free-text names escaped, audit #15 (PR #68): the name helpers (`forceName`, `hqName`, `personName`, `personText`) return escaped markup; every query and client site that composes a person, company, HQ, outfit, commander, player or campaign name, a callsign, a log line, battle-report prose, a filename or a music track into markup escapes it; `clip` reads whole tokens; the REPL prints raw names through `terminalText`. Tests: the hostile-name view test across desk, forces, people, contracts, HQ, roster, log, summary and commander views, and a lobby smoke step with a player named `{c}Evil`
- D19b-2b strings trusted by construction, audit #15 (PR #69): `table.markupSafe` and a generic `unsafeString` walker; a test that every data-file string (all catalogues, tuning, name tables) is markup-safe; the loader's `validateStoredStrings` requires every stored chassis, part, planet and faction key to resolve and every battle-report display copy to be markup-safe (`CorruptSave` otherwise); `part.structure_key`/`isKnownKey` name the structure placeholder once; hall candidate names escaped
- D20a stream identity and ownership, audit #18 (PR #70): `rng.Stream.salt` gives each stream a permanent literal salt (equal to the old ordinal values, so no existing draw changed); `person_gen`, `company_gen.rollExperience*`/`rollWeightClass`, `recruitGenerated` and `planet.weightedPickByFaction` take the caller's stream: hall, market and hiring on `.market`, prisoners and salvage on `.battle`, event recruits on `.events`, the starter company on `.generation`
- 12G.9 battle orders, PR 1 (PR #71): `Contract.orders_day` (schema v33), `confirm_orders` and `emergency_resupply` commands, `field_supply.rushQuote` and `localPriceMultBp` (the §9.6 valve, now shared with the provisions purchase), `battle.ordersConfirmed`, the `battleOrders` query, the contact warning carrying its contract and clearing once orders are in; REPL `briefing`, `confirm`, `rush`
- 12G.9 battle orders, PR 2 (PR #72): the terminal box, opened by Enter on the contact warning and by the advance that stops for it; ←/→ step the ROE and lance roles (`Roe.next/prev`, `LanceRole.next/prev`, shared with the cycle commands), Enter buys the resupply, recalls behind a confirm, or confirms; smoke step
- Design docs caught up (PR #73): ARCHITECTURE, GAMEPLAY, tui.md and modding.md describe the post-audit behaviour; schema.sql is a commented mirror of the runtime DDL
- D20b full-state digest, audit #17: `GameState.hash` digests every persisted field through `sim/digest.zig` (elements in order, maps order-independently, RNG words and ID counters included; `unhashed_fields` checked at compile time); `firstHashDifference` names the first value a round trip lost; a played year is pinned to one golden constant and plays on identically after a save. It found two round-trip losses, both fixed: the decision queue's `next_id` (meta `next_event_id`) and a hall candidate's age (schema v34)
- D21a layering, audit #19: the contract diagram lists `sim/rng.zig` as a leaf below the domain, with a reviewer grep for any other upward import; `contract_market.zig` moves to `src/sim/`, and the starter company (`generateInto`) to `sim/starter_company.zig`, leaving `gen/company_gen.zig` pure rolls and the manning table
- D21b row identity, audit #22: `queries.hqDetailView` returns each row's facility beside its text (the HQ screen's `u` reads it; the text-parsing `hqFacilityAtRow` is gone); the Desk's `inboxPane` builds the inbox lines with the decision each belongs to, used by drawing, the cursor range and Enter (the row-counting app helpers are gone); the Forces `+` no longer pre-checks company slots: `raise_company` refuses and `cli.errorText` says why
- D21c strict command parsing, audit #23: `parseCommand` refuses any token left after a complete command (name verbs consume the rest through `takeRest`); `shares` and `autoadmit` each parse in one branch (bare `autoadmit` toggles); `xfer unit|person`, `office +|-`, `promote … [unpin]` and `cycledifficulty [+|-]` refuse any other word; duplicate verb and usage entries gone; the TUI `:` line prints the usage on a parse error like the REPL; REPL smoke steps for each kind of refusal
- D21d reviewer checks in CI, audit #27: `docs/reviewer_checks.sh` runs every mechanical check of the contract (frontends over `src/tui` recursively; core checks outside `test` blocks and `expect…`/`…ForTest` helpers) and fails on output; CI runs it first; each check was proven to fire on an injected violation (the escape-sequence grep had been blind to its own pattern). `App.execResult` returns a command's result or reports the refusal the one way; 17 direct `commands.execute` calls moved onto it, the six call sites that remain (and the wrapper) say why with `// direct:`. The REPL `new` seeds from `queries.status` instead of reading `GameState`

---

# Part 3 — Adopting the revised contract

`docs/coding-contract-proposed-updated.md` becomes normative only when its
full gate runs and passes. Until then `docs/coding-contract.md` and its gate
govern. Order (decided 2026-09-23): after Part 1 and after the D14–D20 fixes.

- [ ] `docs/verify-contract.sh`: recursive layer, impurity, frontend-boundary, direct `commands.execute`, escape-sequence, markup, comment and module-registry checks, narrow documented allowlists. The markup check derives its tag set from `table.marks`.
- [ ] CI installs ripgrep explicitly and runs the script.
- [ ] One mechanical PR makes `zig fmt --check build.zig src` clean repo-wide.
- [ ] CI clean-package build: a tree holding only the `build.zig.zon` paths builds (overlaps D22 `.paths`).
- [ ] Windows support: target-gated terminal (console API and raw mode), resize without SIGWINCH, child-process music player (no `afplay`), paths. Then CI compiles macOS, Linux and Windows (proposal rule 65).
- [ ] Every rule citation updated to the new numbering in one PR: `src/` (33), docs (14), CLAUDE.md (hard rules, "section 9 checklist" becomes section 11), TODO.md, test names. Optionally switch to stable IDs (`ATOMIC-01`, `VIEW-04`).
- [ ] Full failure atomicity (proposal rules 11-14, 69), beyond D17b's slot reservations: log lines formatted before the first mutation, `resolveChoice` effects prepared as a unit, `placeUnitInCompany` reserving the target lance slot before it removes the hull, and a failure-injection strategy that works under the campaign arena (it allocates in chunks, so a failing child allocator fires unpredictably).
- [ ] `docs/audit-response.md` gets a policy addendum, and the historical analysis stays as written: the contract review adopted failure atomicity as a forward requirement; D17 uses prepare/commit atomic helpers and one failure-injection test per shared mutation pattern, not a transaction framework. D17 expands to match.
- [ ] Adoption PR: title becomes "Coding contract", replaces `docs/coding-contract.md`, every gate command passes on that commit, and remaining violations are listed as bounded exceptions (proposal rule 86) tied to D21/D22. The new PR checklist applies from that commit on.

