# Engineering response to the codebase audit

Date: 2026-09-23 · Responds to: `docs/audit.md` (same date) · Checked at: `1f02f72`

Thank you for the review. We checked every finding against the code as it
stands, including the callers, the guards, the tests and the design documents
each one depends on. The audit was written a few commits before this response,
so the line numbers below are current ones and may differ from the audit's.

**Summary.** None of the 28 findings is wrong outright.

- **Accepted (16).** Several are worse than the audit states: #3, #4, #16 and
  #25.
- **Accepted with corrections (12).** The underlying problem is real, but the
  mechanism, severity or cited rule is off, and we set out our case below.

We also found two defects the audit missed:

- The MASH healing bonus is granted to every deployed patient, not only those
  whose company fields a MASH lance (#7).
- Adding any RNG stream silently reseeds every existing save (#18).

Each accepted item is filed as a checkbox in `TODO.md` (Part 2) under
deliverables **D14–D22**. The deliverable is named below against each finding.

Verdicts: **Accepted**: the finding stands as written. **Accepted with
correction**: the defect is real but part of the finding is not, and we say
which part.

---

## Critical findings

### 1. Black-market fraud can move an unrelated hull: Accepted → D14

**Confirmed.** On a fraud roll, `buy_listing` pays, removes the listing and
returns success without creating a unit (`src/sim/commands.zig:864-871`).
`buy_hull_for` then takes `next_unit_id - 1` as the purchased hull
(`commands.zig:1041-1042`). Black-market hull listings reach this path,
because `contract_market.zig:311-321` creates `.unit` listings with
`company = .none`, which passes the only guard.

The audit understates the consequences. The effect depends on the state at the
time of the fraud:

- **Same world.** Whatever hull was created last is moved into the destination
  company, possibly out of a company that is deployed.
- **Different world.** That hull is marked `in_transit` instead.
- **Last hull already sold.** The same-world branch returns `UnknownForce`
  after the money is gone, and the transit branch panics on `gs.unit(uid).?`.

**Fix:**

- `buy_listing` returns the created `UnitId` in `Result`, null on fraud.
- `buy_hull_for` returns early on fraud.
- Add a test for a black-market hull fraud with an existing hull in another
  company.

### 2. Refits can duplicate parts: Accepted → D14

**Confirmed.** The refit commit checks each install separately with
`stockCount(...) == 0`, then discards the result of `takeStock`
(`commands.zig:1687-1693`). `refit_install` accepts duplicate installs, and
`applyRefit` installs every one of them. With one part in stock and two
identical installs, one part is created from nothing.

There is a second leak: `refit_clear` on the orphaned plan then refunds two
parts for the one that was actually taken.

**Fix:**

- Add up the demand per part key and check each total against stock before
  consuming anything.
- A failed take is an error.

### 3. Battle report IDs are reused after loading: Accepted → D14

**Confirmed, and more serious than stated.** `next_battle_id`
(`src/sim/state.zig:253`) is neither saved (`src/persist/store.zig:366-371`)
nor rebuilt on load, so after a load it restarts at 1 while the old reports
keep their IDs.

The IDs are lookup keys throughout: `Journal.find/markRead`, `read_report`,
salvage-decision events, `HeldHull.battle`, `recoveryPush` and several queries.
All of them match the first report with that ID. After a load, then:

- `read_report 1` marks the old, already-read report as read.
- The new report stays unread for good, so every multi-day advance stops on it.
- The salvage decision and the after-action screen resolve to the wrong battle.

**Fix:**

- Save the counter with the others.
- On load, backfill it to `max(saved, max(report.id, held.battle, event.battle) + 1)`.
- Bump the schema version and test save → load → fight.

### 4. A failed first save corrupts the in-memory save identity: Accepted → D15

**Confirmed, and worse.** `gs.campaign_id` is set right after the INSERT
(`store.zig:336-345`), well before the COMMIT at `store.zig:806`.

If the first save fails and is retried, the retry takes the UPDATE branch. That
branch matches no row, raises no error, and writes every child row under a
campaign ID with no campaign row. The REPL reports "saved", but the campaign
never appears in the lobby.

The `campaign` key is `INTEGER PRIMARY KEY` without `AUTOINCREMENT`, so the
rolled-back ID can later be given to a new campaign, and the two sessions then
overwrite each other's rows.

**Fix:**

- Keep the new ID in a local variable and assign it after COMMIT.
- The UPDATE path fails when no row changed.

### 5. Loading an unknown campaign returns a blank campaign: Accepted with correction → D15

**The defect is real, but it is reachable only from the REPL.** The TUI lobby
loads only IDs it has just listed (`src/tui/app.zig:1408`). The REPL's
`load <n>` accepts any integer (`src/main.zig:509-520`). With an unknown ID it
builds an empty state with no HQs, which then indexes `hqs.keys()[0]` out of
bounds in several commands.

**Fix:** return `error.NoSuchCampaign` when the campaign row is missing.

### 6. Commands are not transactionally atomic: Accepted with correction → D17

**Overstated.** We traced every cited site. The only error any of them can
raise after mutating is `OutOfMemory`, from the campaign arena behind
`gs.allocator()`:

- **HQ founding.** `foundHq` re-runs a planet lookup that has already passed.
- **Facility upgrades.** `startUpgrade` repeats the `upgradeBlock` checks, which
  already ran before the debit.
- **Fabrication.** `queueFabrication` repeats the bay check.
- **Transfers, refit commitment and event resolution.** After the mutation, only
  appends and log writes can fail.

The rule cited as violated does not exist. Rule 27 of the contract requires
derived fields to be refreshed inside the command. It says nothing about
rolling back after a failure.

The only commands that fail for a reason other than allocation after they have
mutated state are #1 (`UnknownForce` after payment) and #2 (an ignored failed
take). Both are fixed under D14.

**Our position:** we will not add a transaction or command-journal framework to
cover the arena running out of memory. At the cited sites we will reserve list
capacity (`ensureUnusedCapacity`) before any debit, as a low-cost precaution.
We will not add failing-allocator tests for every command.

## High severity

### 7. Medical rules ignore physical location: Accepted with correction → D16

**Partly a design question, not a defect, plus a real bug the audit missed.**

ARCHITECTURE.md specifies "beds (hospital level, plus MASH trucks in the field)
and doctor coverage". It never says care is calculated per site. Counting
doctors and taking the best hospital outfit-wide is a deliberate
simplification, so it does not break any written rule. Whether hospitals should
be per-site is a fair design question, and we have added it to the design
backlog under D16.

The real bug is at `src/sim/medical.zig:213-214`: `healDays(gs, deployed)`
passes "is deployed" as the `deployed_with_mash` parameter. Every deployed
patient therefore gets the MASH healing multiplier whether or not their company
fields a MASH lance, contradicting the comment two lines above it. As a result,
a field company with no MASH heals faster than a home base with no hospital.

**Fix:** pass whether the company has a MASH lance that is ready, and add a test.

### 8. Equal-priority field patients can all be denied beds: Accepted → D16

**Confirmed.** For each patient, `medical.zig:181-188` counts the peers with
equal or higher priority. With five equal-priority patients and four beds, each
patient counts four others ahead of it, so all five wait. The `heal_day`
tie-break the list is already sorted by is never consulted.

**Fix:** allocate in one pass over the sorted list, keeping a count of used beds
per company.

### 9. Unit-type combat skills are ignored: Accepted with correction → D16

**Correct for vehicles, wrong for aerospace.**

- **Vehicles.** Vehicle hulls sit in ordinary lances and are crewed by
  `vehicle_crew` pilots. Those pilots have no mek skills, so `battle.zig:209-210`
  gives every vehicle the default 4/5, however good its crew.
- **Aerospace.** Air lances hang under the company's air wing, and the
  engagement loop walks only `company.children`. Fighters never reach the skill
  code. They count only as the air-cover modifier, which already checks
  readiness correctly.

**Fix:** one skill selector keyed on unit kind, reusing the kind-to-skill mapping
at `src/domain/person.zig:378-380`.

### 10. Unavailable support assets still grant modifiers: Accepted → D16

**Confirmed.**

- **Battle.** `companyMods` (`battle.zig:258-283`) grants the recon, MASH, mess,
  security, salvage and transport modifiers whenever the lance is non-empty.
  Mothballing leaves a hull in its lance, so a mothballed or destroyed MASH truck
  still grants its modifiers.
- **Medical.** `medical.zig:127` excludes only destroyed trucks from the bed
  count.

Two pieces of the fix already exist and go unused here. The air-cover branch of
the same function checks readiness correctly. `Unit.canFight()` is documented
as the one readiness definition.

**Fix:** one `Force.hasReadyUnit` predicate built on `canFight()`, used by
battle, medical and salvage.

### 11. Conceded engagements do not produce blocking AARs: Accepted with correction → D16

**The rationale is overstated, but we accept the fix.**

The architecture blocks the turn on a battle report because a battle "disposes
of hulls and people permanently". A concession disposes of nothing, so skipping
the block has a defensible reading.

Step 8 of the pipeline says "AAR emitted", though, and today a concession
reaches the player only as a log line, never counts in the stats book, and
applies hard-coded penalties (`battle.zig:808-814`).

**Fix:**

- Emit a minimal conceded `BattleReport`, run the normal bookkeeping and move
  the penalties into tuning.
- The report blocks the turn like any other, for consistency.

### 12. Freight throughput is both overprovisioned and consumed on failures: Accepted with correction → D17

**There is no overprovisioning.** The ×4 in `src/sim/network.zig:27-28` is
`tuning.network.weeks_of_capacity` (`data/tables/tuning.zon:61`). It is
deliberate, and a test pins it ("the charter link moves 40t/week"). The reset in
`tick.zig:35` is weekly, so the multiplier and the reset interval agree.

What is wrong:

- **The knob name.** It misreads as a time multiplier.
- **Two functions disagree.** `logistics.routeThroughputPerWeek` returns the
  unscaled figure. Only a test uses it, but the two functions give contradictory
  answers.
- **Capacity reserved too early.** `shipStock` reserves throughput in
  `freightBetween` before `debitPurchase`, so an order refused for lack of funds
  still uses capacity.

The claim about sourcing does not apply. `orderPart` always ships from the
destination's own home HQ and never reserves link capacity.

**Fix:**

- Split `freightBetween` into a quote step and a commit step, and reserve after
  the debit.
- Rename the knob to what it measures.
- Delete `routeThroughputPerWeek` or make it agree.

### 13. Persistence silently accepts corruption: Accepted → D15

**Confirmed.** Our own earlier fix (contract deliverable D8) covered only the enum
columns it listed. The rest is as described:

- A missing or wrong-length RNG blob silently keeps the default seed
  (`store.zig:893-900`).
- There are 61 unchecked `@intCast` reads. These panic in safe builds and are
  undefined behaviour in the ReleaseFast builds we ship.
- Several enum columns, and every missing parent row, are skipped with
  `orelse continue`.

**Fix:**

- Checked integer readers that return `CorruptSave`.
- A missing or wrong-size RNG blob is `CorruptSave`.
- A missing parent row or an unknown enum rejects the load.

### 14. Runtime SQLite schema lacks integrity enforcement: Accepted with correction → D15

**The remedy as stated would do nothing.**

- **The FK pragma.** `docs/schema.sql` says in its own header that it is a
  design document and that the executable DDL lives in the store. The runtime
  DDL (`store.zig:32-79`) declares no foreign keys, so enabling
  `PRAGMA foreign_keys` would enforce nothing.
- **The table list.** We compared `tables` (`store.zig:81-87`) against the DDL
  and they match exactly, so no table is currently missed.

The point underneath stands: the database enforces no relationships, and the
loader skips orphaned rows instead of rejecting them. We enforce integrity in
the loader, under #13. Declaring constraints in SQL needs table-rebuild
migrations and is deferred until a schema change calls for a rebuild anyway.

### 15. Terminal text is not safely escaped: Accepted → D19

**Confirmed.**

- **Invalid UTF-8.** `Screen.text` decodes with `Utf8View.initUnchecked`, so
  invalid UTF-8 panics in safe builds and is undefined behaviour in ReleaseFast.
- **Untrusted text.** TUI text input always produces valid UTF-8, but the
  following reach the renderer unfiltered:
  - C1 control bytes that the key reader passes through
  - raw lines from REPL stdin
  - anything loaded from a save
- **Markup.** Literal markup in a name restyles it, for example a company named
  `{r}Alpha`, and there is no escape for it.

**Fix:**

- Validated decoding with U+FFFD for invalid bytes, and control characters shown
  as `?`, at the `Screen.text` boundary.
- A plain-text path that never reads markup, for user text.
- Fix the `utf8Encode(...) catch 1` fallback, which writes one uninitialised byte.

### 16. Terminal and screen initialization have unsafe failure paths: Accepted → D19

**Confirmed, and worse.**

- **Resize.** `Screen.resize` frees the cell buffer before allocating the new
  one. On OOM, the error travels up to `run`, whose `defer app.deinit()` frees
  the stale slice a second time. That is a double free, not merely a dangling
  pointer.
- **Terminal init.** `Term.init` switches to raw mode before two fallible writes.
  The caller registers its `defer term.deinit()` only after `init` succeeds, so
  a failed write leaves the terminal raw.

**Fix:**

- In `Screen.resize`, allocate the new buffer, then free the old one and swap.
- In `Term.init`, add `errdefer tcsetattr(orig)` right after entering raw mode.

### 17. The deterministic state hash is incomplete: Accepted → D20

**Confirmed, with one mitigation the audit missed.** `stateHash` hashes
counts and totals for many collections. It omits these entirely:

- RNG state
- skills and unit slots
- battle reports
- the event queue
- `next_*_id` counters
- stats
- contract score and victory points

The store round-trip test partly compensates. It checks fields by hand and runs
both worlds 30 days forward before comparing hashes, which catches most
divergence that surfaces within a month. #3 slipped through that gap all the
same.

**Fix:**

- A digest over every saved field, RNG bytes included.
- Pin one golden constant for a fixed seed and script.

### 18. Named RNG streams remain cross-coupled: Accepted with correction → D15, D20

**The coupling is real. The compatibility argument is wrong, and the real
problem is worse.**

- **The coupling.** `person_gen` and `company_gen.rollWeightClass` always draw
  from `.generation`. Hiring-hall candidates, market hulls, battle prisoners,
  salvage weight classes and contract events all feed through them, so one
  extra prisoner changes the next recruit. Battle never touches `.market`, as
  the audit says it does.
- **The ordinal derivation.** It matters only when a campaign is seeded, because
  the whole stream array is saved as one blob. That array is also the real
  problem: adding any stream changes the blob's size, the load's length check
  fails, and (per #13) every old save is silently reseeded to the same default,
  3025.

**Fix:**

- Explicit, stable salt per stream.
- Save one row per named stream, plus the campaign seed, so a new stream is
  seeded from the campaign seed (D15).
- Callers pass their own stream into the generators (D20).

## Architecture and structure

### 19. Dependency direction is already inverted: Accepted with correction → D21

**Half right.**

- **The RNG imports.** `src/sim/rng.zig` imports only `std`. It is a leaf, and
  the contract makes it the one allowed PRNG. The domain modules take a `*Rng`
  as a narrow input, which is what the audit recommends. The contract's layer
  diagram simply never placed `rng.zig`, and we will list it below domain.
- **`econ/market.zig`** imports only the RNG, not simulation state.
- **The real inversions.** `econ/contract_market.zig` imports `GameState`,
  `autoresolve`, `rating`, `personnel` and `maintenance`. `gen/company_gen.zig`
  imports `GameState` and `personnel`. Both are simulation orchestration in the
  wrong directory.

**Fix:** move `contract_market` and `company_gen.generateInto` into `src/sim/`.

### 20. Central modules have become subsystem aggregators: Accepted → D22

**Confirmed, and larger than stated.**

| File | Lines | Longest function |
|---|---|---|
| `src/sim/queries.zig` | 5,873 | |
| `src/sim/commands.zig` | 4,447 | `execute`, 1,097 lines |
| `src/tui/app.zig` | 3,385 | |
| `src/persist/store.zig` | 2,242 | `load`, 767 lines |
| `src/sim/state.zig` | 2,155 | |

We keep the single facades. `execute` becomes a dispatch switch into
per-subsystem functions, and `load` becomes per-table decoders. This work comes
last, because it moves every line number the other deliverables cite.

### 21. HQ locality is repeatedly bypassed: Accepted with correction → D18

**Mostly confirmed, and one item is a design gap rather than a bypass.**

- **Training.** "Training happens at home … at a regional/brigade HQ with a
  training ground" (ARCHITECTURE.md), but three separate loops
  (`commands.zig:782`, `1448`, `1849`) accept any HQ with a ground. The copies
  also break rule 5.
- **Mess and HR.** Weekly fatigue recovery uses the best mess across all HQs,
  and HR uses the first HQ. The design says both are local.
- **Recruiting.** The recruit bonus reads `hqs.values()[0]`, which is arbitrary
  rather than a rule.
- **Comms.** Global intel was an explicit design decision (12D.5, "how well the
  outfit reads"). It became inconsistent when 12E.4 made contract boards
  per-HQ. We resolve it per-board: `intelLevel(gs, offer_hq)`.

**Fix:** one site-aware rule function each, plus asymmetric two-HQ tests.

### 22. Query and frontend boundaries have concrete violations: Accepted with correction → D21

**One of the four examples is already fixed.** The TUI no longer reads
`battle_reports` directly. It goes through `queries.turnHold` (`app.zig:2214`).

The rest are confirmed:

- `hqFacilityAtRow` recovers a facility by parsing rendered text
  (`queries.zig:1757-1772`).
- Inbox selection counts rows (`app.zig:1825-1840`).
- The Forces screen checks company-slot availability itself instead of letting
  the command refuse.

**Fix:**

- Typed row identities on `hqDetail` and the inbox rows.
- Remove the Forces pre-check.

### 23. CLI parser has unreachable and permissive branches: Accepted → D21

**Confirmed.**

- **Shadowed branches.** The early `shares` and `autoadmit` branches
  (`src/sim/cli.zig:147-155`) shadow the later ones, so `shares +/-` and the
  bare toggle can never be reached.
- **Permissive tokens.** `xfer` treats any token other than `unit` as a person,
  and `office` treats any token other than `-` as `+`.

This affects only the REPL and the TUI `:` line. The TUI keys issue the
commands directly.

**Fix:**

- One branch per verb.
- Strict enum parsing.
- Reject trailing tokens.

## Build, data and tests

### 24. Published package omits an unconditional build input: Accepted → D22

**Confirmed.** It matters only when the project is fetched as a Zig package,
which is rare for an executable, but it is a one-line fix: add `docs/logos` and
`LICENSE` to `.paths`.

### 25. Tuning validation skips signed economic fields: Accepted → D22

**Confirmed, and worse.** The early return for signed types
(`src/domain/tuning.zig:743`) runs before the basis-point bound. All 115
`Bp`/`CBills` knobs are signed, and no unsigned `_bp` field exists, so the check
has never run on a single field.

**Fix:** validation keyed on the field's type (`Bp`, `CBills`), with an explicit
allow-list for knobs that are genuinely signed deltas.

### 26. Mod semantic validation is not part of ordinary mod builds: Accepted → D22

**Confirmed.** `docs/modding.md` does tell modders to run
`zig build test -Ddata=…`, so the gap is documented rather than hidden. The
default is still wrong: a mod with an empty `rat.zon` builds cleanly and then
indexes out of bounds at runtime.

**Fix:** a `validate-data` build step that overlay installs depend on.

### 27. Reviewer checks do not recursively inspect screens: Accepted with correction → D21

**The glob gap is real, but it hides nothing the greps look for.** We ran every
`src/tui/*.zig` check against `src/tui/screens/*.zig` and none prints anything.

The command-feedback issue the audit points at is real, but it is a pattern no
grep checks for: 11 direct `commands.execute(` calls in screens bypass
`execSay`. Some of them legitimately need the command's result.

**Fix:**

- Recursive globs.
- A new check for `commands.execute(` outside `exec`/`execSay`.
- Move the checks into a script that CI runs.

### 28. TUI modules mostly lack focused tests: Accepted → D22

**Confirmed.** `app.zig` and all ten screen modules have no in-file tests,
contrary to rule 9. The other TUI modules do have them.

**Fix:** pure tests for row identity (#22), cursor clamping on resize, and each
screen's key handler against a generated campaign.

---

## Positive observations

We agree, and we keep them as invariants. The explicit architecture is what
made most of these findings cheap to confirm or refute.

## Revised priority order

**Scheduling (decided 2026-09-23):** this work starts only after Stage 12
is finished (`TODO.md` Part 1), so deep changes to how the code works do
not land mid-implementation. Within the audit work, the order is:

1. **D14** gameplay corruption (#1, #2, #3)
2. **D15** save identity, corruption and per-stream RNG persistence (#4, #5, #13, #14, #18)
3. **D16** battle and medical rule bugs (#7 MASH, #8, #9, #10, #11)
4. **D17** logistics accounting and pre-debit capacity reservation (#6, #12)
5. **D18** HQ locality (#21)
6. **D19** terminal safety (#15, #16)
7. **D20** complete state digest and RNG stream ownership (#17, #18)
8. **D21** layering, boundaries, CLI and reviewer checks (#19, #22, #23, #27)
9. **D22** build, data validation, TUI tests and the module split (#20, #24, #25, #26, #28)

The terminal fixes (D19) are small and independent of the save format, so if
the ReleaseFast undefined behaviour is judged more urgent than the rule bugs,
they may move ahead of D16.
