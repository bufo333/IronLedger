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

Done: every Stage 12 feature (12, 12B–12G) has shipped. Part 2 is next.

---

# Part 2 — Code quality

## D12. TUI structure (contract rules 18-25)

- [ ] `drawWizard` into per-step functions.
- [ ] **One key table per screen** (rule 22): the footers are in `screen_table`; pane right-titles, modal titles, help rows and in-pane hints still carry their own key text; `docs/tui.md` key table generated or checked by the smoke.

## D13. Tests and CI (contract rules 37-40)

- [ ] Still uncovered by the smoke: the GAME OVER modal (a fresh campaign starts solvent, so reaching it needs a saved campaign already past all credit as a test fixture; bankruptcy itself stays terminal by design), the exact 120-column layout boundary, and the refusal branch of each confirm once run (they open and close only).

## D15. Save integrity (audit #4, #5, #13, #14, #18; rules 1, 27)

Landing as three increments; D15a is done (see Done).

**D15b. Loading fails closed (#13).**
- [ ] Checked integer readers (`st.u32(col)` etc. returning `CorruptSave`) replace the 61 `@intCast(st.int(...))` sites and `toId` (store.zig:1700-1702).
- [ ] Missing parent rows and unknown enum values reject the load instead of `orelse continue` / `orelse .default` (store.zig ~866, ~909, 964-987, 1087-1095, 1120-1128, 1341, 1419-1455).

**D15c. RNG persisted per stream (#18).**
- [ ] RNG saved one row per named stream plus the campaign seed; a stream absent from an older save is seeded from the campaign seed; a malformed row is `CorruptSave` (store.zig:385, 893-900). Adding a stream no longer reseeds old saves to 3025.

- Note (#14): SQL-level foreign keys wait for a schema change that rebuilds tables anyway; the loader is the integrity check.

## D16. Battle and medical rule bugs (audit #7, #8, #9, #10, #11; rules 5, 6)

- [ ] `Force.hasReadyUnit` (one predicate on `Unit.canFight()`); `companyMods` recon and support lances (battle.zig:258-283) and MASH beds (medical.zig:127) call it.
- [ ] `healDays` gets "company fields a ready MASH lance", not "is deployed" (medical.zig:213-214). Test: deployed patient without MASH heals at the base rate.
- [ ] Field beds allocated in one pass over the sorted patient list with a used-bed count per company (medical.zig:181-188). Test: five equal-priority patients, four beds, exactly one waits.
- [ ] One combat-skill selector keyed on unit kind (reuse person.zig:378-380); battle.zig:209-210 calls it. Test: a vehicle crewed by a good `vehicle_crew` pilot fights at their vee skills.
- [ ] Conceded engagement (battle.zig:808-814) emits a minimal `BattleReport` (defeat, no hits) through the normal aftermath bookkeeping (stats, `battles_fought`); the report holds the turn like any other; the -2 score / -10 VP move into tuning.
- [ ] `autoresolve.CampaignMods.has_field_repair` is set by a transport support lance (battle.zig:283) and read nowhere; the mobile field base (`UnitKind.mobile_field_base`) has no repair effect. Either wire it (e.g. into the 12G.6 push budget) or delete the flag.
- [ ] ROADMAP 9C.2 says reloads cost tech hours; `runWeeklyRepairs` charges none. Implement or correct the roadmap.
- Design backlog (not a defect): per-site hospital and doctor capacity (#7). ARCHITECTURE.md never specified per-site care; decide there first.

## D17. Logistics accounting (audit #6, #12; rules 5, 6, 27)

- [ ] `freightBetween` split into quote and commit; `shipStock` reserves throughput after `debitPurchase` succeeds (commands.zig:1784, 1816-1825).
- [ ] Rename `tuning.network.weeks_of_capacity` (tuning.zon:61, network.zig:27-28) to what it measures (e.g. `tons_per_supply_unit`); delete or align `logistics.routeThroughputPerWeek` (logistics.zig:119-123) so one function answers "tons per week on this link".
- [ ] `ensureUnusedCapacity` before the debit at the audit #6 sites: HQ founding (commands.zig:461-474), facility upgrade (1365-1387), fabrication (1346-1363), unit transfer (1638-1655), refit commit (1694-1705), `resolveChoice` (contract_events.zig:337-348). No transaction framework; these fail only on arena OOM.

## D18. HQ locality (audit #21; rules 5, 8)

- [ ] One `canTrainAt(gs, hq)` against `homeHqFor(company)` replaces the three any-HQ loops (commands.zig:782-787, 1448-1453, 1849-1854).
- [ ] Weekly rest uses the company's home HQ mess and HR, not the best mess / `hqs.keys()[0]` (medical.zig:320-332).
- [ ] `recruitBonus` (state.zig:645-647) reads the recruiting HQ, not `hqs.values()[0]`.
- [ ] `intelLevel(gs, offer_hq)` (offer_rating.zig:22-27): per-board comms, matching 12E.4 per-HQ boards.
- [ ] Asymmetric two-HQ tests for each: the facility at one HQ does not serve a company homed at the other.

## D19. Terminal safety (audit #15, #16; rule 24)

- [ ] `Screen.text` (screen.zig:151) decodes with a validated view, draws U+FFFD for invalid bytes and `?` for C0/C1 controls; `utf8Encode(...) catch 1` (screen.zig:406) writes a replacement, not an uninitialised byte.
- [ ] A plain-text draw path that never interprets markup; names, filenames, mod and log strings go through it (a company named `{r}Alpha` draws literally).
- [ ] `Screen.resize` (screen.zig:120-126) allocates the new buffer before freeing the old (today: double free on OOM through `deinit`).
- [ ] `Term.init` (term.zig:108-135): `errdefer tcsetattr(orig)` and handler removal right after entering raw mode.

## D20. Determinism (audit #17, #18; rules 1, 40)

- [ ] `stateHash` (state.zig:1939-2040) digests every persisted field in canonical order, RNG bytes and `next_*_id` included; one golden constant pinned for a fixed seed and script.
- [ ] RNG streams carry explicit stable salts instead of the enum ordinal (rng.zig:7-28).
- [ ] `person_gen.generateWithBonus` and `company_gen.rollWeightClass` take the caller's stream; hall (contract_market.zig:501), market (245, 384), prisoners (battle.zig:787), salvage (1130) and events (contract_events.zig:1196) pass their own.

## D21. Layering and boundaries (audit #19, #22, #23, #27; rules 1, 4, 6, 17, 26)

- [ ] Contract layer diagram lists `sim/rng.zig` as a leaf below domain (it imports only `std`).
- [ ] `econ/contract_market.zig` and `gen/company_gen.zig` `generateInto` move into `src/sim/` (they import `GameState` and sim rules).
- [ ] `hqDetail` rows carry a typed facility identity; `hqFacilityAtRow` stops parsing rendered text (queries.zig:1757-1772).
- [ ] Inbox rows carry event identity; `inboxRowCount` / `inboxEventAtCursor` (app.zig:1825-1840) stop counting rows.
- [ ] Forces `+` pre-check on `hqWithCompanySlot` (screens/forces.zig:178-182) deleted; the command refuses.
- [ ] `cli.zig`: one branch per verb (delete the shadowing `shares`/`autoadmit` at 147-155), strict enum tokens for `xfer` and `office` (345-367), trailing tokens rejected. REPL smoke steps for each refusal.
- [ ] Reviewer checks use recursive globs (`src/tui/**/*.zig`), add a `commands.execute(` outside `exec`/`execSay` check, and run as a script in CI; the 11 direct calls in screens either go through `execSay` or are listed as result-reading exceptions.

## D22a. Comments and citations (contract rule 43)

- [ ] Rewrite existing comments to rule 43 (proposal rules 82–84), using the reviewer greps in proposal rule 84. As of 2026-09-23: 42 history or attribution lines, 708 stage tags outside `//!` headers, 133 stage-prefixed test names, one `TODO(stage-4)` (domain/contract.zig). Also trim narrative doc comments to the caller-visible contract, and replace "mirrors" with precise counterpart or adaptation labels. One PR per layer (domain/econ/gen, sim, persist, tui). Until the sweep lands, `verify-contract.sh` checks against a recorded baseline so only new violations fail.

## D22. Build, data and tests (audit #20, #24, #25, #26, #28; rules 6, 9)

- [ ] `build.zig.zon` `.paths` adds `docs/logos` and `LICENSE`.
- [ ] `tuning.zig:743` validation keyed on field type (`Bp` → 0..100_000, `CBills` ≥ 0) with an explicit allow-list for signed deltas; today the bp bound runs on no field at all.
- [ ] `validate-data` build step running the cross-file checks; install with `-Ddata` depends on it (an empty `rat.zon` fails the build, not the run).
- [ ] In-file tests for `app.zig` and each `screens/*.zig`: row identity (after D21), cursor clamp on resize, key handlers against a generated campaign.
- [ ] `commands.execute` becomes a dispatch switch into per-subsystem functions; `Store.load` becomes per-table decoders. Last, because it moves every cited line.

---

# Done

Contract deliverables closed before this list merged, all from the 2026-09-22 contract audit. The full item lists are in git history (`docs/contract-todo.md` at `7441a14`).

- D0 one rule for structural needs (PR #3) · D1 the contract itself (PR #4) · D2 layering and core purity (PR #5) · D3 entity predicates (PR #6) · D4 one computation, one function (PR #7) · D5 ledgers (PR #8) · D6 numbers appear once (PRs #9, #10, #20) · D7 formatting helpers (PR #11) · D8 commands leave state consistent (PR #12) · D9 rules move out of queries (PR #13) · D10 REPL printers as query loops (PR #14) · D11 TUI boundary (PR #15) · D12a–c TUI structure (PRs #16, #17, #19, #22) · D13 tests and CI (PR #21, one item left above)
- D14 gameplay corruption, audit #1–#3 (PR #53): black-market fraud returns no hull instead of `next_unit_id - 1`; refit demand is counted per part before any is taken; `next_battle_id` is saved and resumed past every referenced battle
- D15a save identity, audit #4–#5 (PR #54): a first save sets `campaign_id` only after COMMIT; saving over a missing campaign row and loading an unknown id both return `NoSuchCampaign`; the TUI and REPL print `cli.errorText` for save errors

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
- [ ] `docs/audit-response.md` gets a policy addendum, and the historical analysis stays as written: the contract review adopted failure atomicity as a forward requirement; D17 uses prepare/commit atomic helpers and one failure-injection test per shared mutation pattern, not a transaction framework. D17 expands to match.
- [ ] Adoption PR: title becomes "Coding contract", replaces `docs/coding-contract.md`, every gate command passes on that commit, and remaining violations are listed as bounded exceptions (proposal rule 86) tied to D21/D22. The new PR checklist applies from that commit on.

