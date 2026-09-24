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

## D13. Tests and CI (contract rules 37-40)

- [ ] Still uncovered by the smoke: the GAME OVER modal (a fresh campaign starts solvent, so reaching it needs a saved campaign already past all credit as a test fixture; bankruptcy itself stays terminal by design), the exact 120-column layout boundary, and the refusal branch of each confirm once run (they open and close only).

## Data verification

- [ ] `contract.operationsMultBp`: check each contract kind's multiplier against the CamOps contract payment table and cite the page (rule 6).
- [ ] Dragoons rating bands (`tuning.zon` `rating`): confirm the source (FM: Mercenaries rather than CamOps?) and cite the page.

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
- D22a-1 comments in domain, econ and gen (rule 43): stage tags only in `//!` headers, no history or play-feedback notes, behavioural test names, "mirrors" replaced by "MekHQ counterpart" or "Adaptation of", the one `TODO(stage-4)` moved to Data verification, misplaced doc comments moved onto the fields they describe; no code changed (checked line by line against main)
- D22a-2 comments in sim: commands, battle and state (rule 43): about 195 stage tags and every play-feedback or history note out, 64 test names made behavioural, nine doc comments moved onto the declarations they describe, and comments that disagreed with the code corrected (the MASH wound target, truck salvage capacity, payroll counting the wounded, liquidation selling stock); no code changed
- D22a-3 comments in sim: contract events and market, tick, events, after-action, contract control, medical, HQ ops, checklist, maintenance and personnel (rule 43): about 280 stage tags and the play-feedback notes out, 38 test names behavioural, seven doc comments moved onto their declarations, two wrong rule citations fixed (one rule, one place is rule 7), and comments that disagreed with the code corrected (vehicle bay ratings, hall floors and refresh cadence, turnover counts, what holds the turn); no code changed
- D22a-4 comments in the rest of sim: queries and the small modules (rule 43): about 55 stage tags and the play-feedback notes out, 16 test names behavioural, two rule citations fixed, two doc comments moved and one duplicate dropped, and comments that disagreed with the code corrected (`tonnageText`'s output, a wreck's upkeep at the cold-storage rate, autoresolve's strength source); `src/sim` is swept; no code changed
- D22a-5 comments in persist, the terminal client, `main.zig`, `root.zig`, `build.zig` and every `data/*.zon` (rule 43): about 110 stage tags and the history notes out; migration comments keep their schema versions (one split so v26 and v28 each describe their own column); nine test names behavioural; the stock `zig init` tutorial comments in build.zig replaced by short ones; comments that disagreed with the code corrected (a bad battle-report row is `CorruptSave`, not skipped; enum binding; where music is found; root.zig's scope); the D22a sweep is complete, and the repo-wide greps for stage tags, history words, stage-prefixed tests, TODO and "mirrors" return nothing; no code or data value changed
- D22-1 package paths, freight knobs and tuning checks, audit #24/#25: `build.zig.zon` `.paths` adds `docs/logos` and `LICENSE` (a tree holding only those paths builds and installs); `freightQuote`'s literals are `tuning.logistics.freight_per_ton_jump`, `transport_admin_discount_bp`, `transport_admin_max` and `freight_min_days`; the tuning check covers signed knobs (every `_bp` share in 0..100000, money never negative) with the 27 negative-by-design knobs named in `signed_knobs`, reports every failure in one run, and proves each listed name is a real field; the demo CLI's two stage-tagged strings are gone
- D22-2 validate-data, audit #26: the data-consistency tests are named `data: …` (tables against each other, markup-safe strings, tuning ranges); `zig build validate-data` runs them alone, and with `-Ddata` the install depends on them, so an overlay with an empty `rat.zon` fails `zig build` naming the check and installs nothing; docs/modding.md says so
- D22-3 client tests, audit #28: `app.clientForTest` runs the terminal client headless over a generated campaign (frames to a discarding writer, an in-memory store, 200x50), and `pressForTest` sends a key and draws a frame; `app.zig` tests draw every screen at full size and at 80x24 with the cursor run past every list, and end a turn through the checklist; each `screens/*.zig` tests one of its own keys, the HQ screen's `u` against the facility `hqDetailView` puts under the cursor
- D22-4 `execute` is a dispatch, audit #20: the 1,099-line switch is one line per command; each of the 76 multi-line arms is a named `exec…` function taking that command's payload (`@FieldType(Command, …)`), in the switch's order; the longest function in commands.zig is 94 lines; a mechanical move, so the golden master holds
- D22-5 `Store.load` is a sequence of decoders, audit #20: the 772-line function is 47 lines calling one `load<Table>` method per table (29 of them: `loadVersion` returns the saved schema version, `loadMeta` whether the seed is stored, the rest fill `GameState`), in the order it ran; a mechanical move: every round-trip test and the golden master hold, and a real v34 save loads, plays and reloads
- D22-6 `Store.save` is a sequence of encoders, audit #20: the 484-line function is 39 lines (the transaction, `saveCampaignRow`, one `save<Table>` per table, COMMIT, then `campaign_id`); `loadBattleReport` reads its hit, ammo and salvage rows through `loadReportHits`, `loadReportAmmo` and `loadReportSalvage`; no function in store.zig passes 83 lines; round trips, the golden master and a real save hold. D22 is done
- D12 wizard steps: `drawWizard` draws the title bar and dispatches to `drawWizardCommander`, `drawWizardOutfit`, `drawWizardCompany` and `drawWizardReview`, one per step
- D12 key tables for the game screens (rule 22): `src/tui/keys.zig` maps keys to semantic actions with every word shown about them (label, group, pane scope, title pane, help); one global table (screens, panes, cursor, command line, end turn, music, help, welcome) and one per screen, whose `handle` switches on the action; the footer, pane titles, help modal key section and the `docs/tui.md` key block (`game --keys-markdown`, compared exactly by a test) are generated from them; tests reject an unbound action, a key bound twice in one pane, and a screen binding that shadows a global key. Drift fixed on the way: help said F1-F8 for ten screens, HQ help said `h hire`, the People title offered `?` (global help) for the previous filter, and Forces `M` (manning) never fired under global `M` (music) and is gone (`r` cycles to MANNING)
- D12 key tables for the modals, welcome and wizard (rule 22): every modal (lists, sheets, the raise flow, soundtrack, decision, contract log, after-action, emblem editor, number form, battle orders and settings, end turn, leave, game over, confirm, text prompts), the welcome screen and each wizard step resolve keys through a table and switch on actions; `keys.Match.text` declares typed text as a fallback (a focused text field takes every character); confirm dialogs share one table (y / s / Esc) and name their verbs; every title, footer, button row and hint is generated (`keys.title`, `keyHint`, `listTitle`, `formTitle`), and the docs key reference lists all 23 tables. Found on the way: the after-action sheet's "[←/→] columns" hint was false (now it scrolls), and a raise-crews hint named other screens' keys
- D19 typed endpoint for untrusted text, audit #15: `table.Raw` carries a player-chosen name across the query boundary (campaign, player and commander names in the lobby; the outfit, force, HQ and lance names in the queries) and cannot be formatted with `{s}`; frontends draw it with `markup`, print it on the REPL with `terminal`, and read `.raw` only with a `// raw:` reason (a reviewer check, proven to fire). The type found four live gaps: the REPL's HQ title line printed an HQ name unsanitized, the wizard's review put the starter HQ's name and the typed outfit, commander and company names into markup unescaped, and the campaign-begins message did the same with the outfit name
- Part 3: `docs/verify-contract.sh` (rules 72-74), grown from the reviewer script, which now forwards to it: the markup check reads its tag set from `table.marks`; the comment checks (history, stage tags outside `//!`, TODO, stage-led test names) cover `src`, `data` and `build.zig`; a broad `catch {}`/`false`/`""` needs a `// best-effort:` reason (22 marked) or a line in `docs/verify-contract.baseline`, which fails when an entry goes stale so it only shrinks (9 entries, for the small-gaps PR); every source file must be reachable by `@import` from `root.zig` or `main.zig`; each check proven on an injected violation
- Part 3: `zig fmt --check build.zig src` is clean repo-wide (18 files reformatted, no behaviour change: the golden master holds) and CI runs it as a gate step (rule 72)

---

# Part 3 — Adopting the revised contract

`docs/coding-contract-proposed-updated.md` becomes normative only when its
full gate runs and passes. Until then `docs/coding-contract.md` and its gate
govern. Order decided 2026-09-24, after the proposal was reviewed against the
code; each item is one PR, in this order.

- [ ] Small gaps: the bankruptcy save's `catch {}` reports a failed save (rule 44); the TUI command line and the REPL show `cli.errorText`, never an error name (rule 10); the 11 broad catches in the core and persist are justified or removed (rule 79); `validate-data` runs on every build, not only `-Ddata` (rule 58); every module names its MekHQ counterpart and links `docs/mekhq-map.md` (rule 61); a test compares the runtime table registry with the executable DDL (rule 50).
- [ ] `execResult` takes a per-error message map, so the five `// direct:` calls that only customise refusal text go through it (rule 37); the wizard's pre-session campaign is the one remaining, listed exception.
- [ ] Every `GameState` field classified as persisted, derived, session-only or scratch in one manifest the digest and a test read (rule 45).
- [ ] A lobby-owned session handle that the TUI and REPL hold instead of a `GameState` value (rule 9).
- [ ] Subsystem behaviour off `GameState` (rule 77): the hash into `digest.zig`, pricing, staffing and the rest into their owning modules.
- [ ] Full failure atomicity (rules 11-14, 69): validate / prepare / commit in every compound command, log lines and effects prepared before the first mutation, staged RNG, and one failure-injection test per mutation pattern with a strategy that works under the campaign arena.
- [ ] SQL foreign keys, unique keys and checks through a table-rebuild migration, with `PRAGMA foreign_keys` on every connection (rule 50).
- [ ] CI clean-package build: a tree holding only the `build.zig.zon` paths builds (rule 66).
- [ ] Windows support: target-gated terminal (console API and raw mode), resize without SIGWINCH, a child-process music player without `afplay`, paths; CI compiles macOS, Linux and Windows (rule 65).
- [ ] `docs/audit-response.md` addendum: failure atomicity is a forward requirement met by prepare/commit helpers and one failure-injection test per pattern, not a transaction framework.
- [ ] Every rule citation renumbered to the new contract in one PR: `src/`, docs, CLAUDE.md (hard rules; "section 9 checklist" becomes section 11), TODO.md, test names.
- [ ] Adoption PR: the proposal replaces `docs/coding-contract.md` under the title "Coding contract", every gate command passes on that commit, and the remaining violations are listed as rule-87 exceptions: the seven modules over 1,000 lines (queries, commands, app, store, battle, state, contract_events), each tied to a split deliverable scheduled after adoption, and the wizard's pre-session `commands.execute`.
