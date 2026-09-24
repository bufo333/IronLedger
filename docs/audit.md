# IRON LEDGER structural and architecture audit

Date: 2026-09-24

## Scope and method

This audit reviewed the repository's structure, architecture, and engineering
practices against `ARCHITECTURE.md`, `docs/coding-contract.md`, and the behavior
described in `ROADMAP.md`. The review covered:

- `src/domain`, `src/econ`, `src/gen`, and the simulation modules under
  `src/sim`.
- The command/query boundary, REPL, and terminal client.
- SQLite schema management, migrations, save/load integrity, and ownership.
- Build configuration, data overlays, CI, smoke tests, and package contents.

The review was static and read-only. No Git commands, builds, tests, smoke
scripts, or filesystem-changing verification commands were run. Line numbers
identify the reviewed revision and may drift; symbols and behaviors are the
stable references.

## Executive summary

The codebase has a strong intended architecture: a deterministic simulation
core, typed identities, named RNG streams, integer financial arithmetic, a
command/query boundary, structured state hashing, compile-time data tables, and
substantial persistence and frontend tests. Those decisions are sound and
should be preserved.

The highest risks are implementation violations of state ownership and failure
atomicity. Event resolution and battle resolution retain pointers into
collections that can reallocate or shift during the same operation. Several
compound mutations modify one representation before validating or reserving
the other representations. The save loader also accepts several malformed
relationships and unchecked identifiers despite the documented fail-closed
policy. These defects can corrupt a campaign rather than merely display an
incorrect value.

The next tier of issues is boundary drift: some frontend-only commands parse or
report results differently from the shared CLI path, some rules use "not on a
contract" where the model requires "physically home," and data-overlay
validation does not cover all assumptions required for safe runtime indexing.

## Priority order

1. Remove collection-pointer invalidation in decisions and battle resolution.
2. Make compound simulation mutations failure-atomic.
3. Make save loading fully fail closed and validate every ID counter.
4. Correct physical-location rules and turn-advance safety behavior.
5. Unify frontend parsing and result presentation.
6. Close data-validation and database-lifecycle gaps.
7. Split oversized implementation modules behind their existing facades.

## Critical findings

### A1. Decision resolution retains invalid pointers into a mutable event list

**Evidence:** `resolveChoice` retains `ev`, a pointer into
`event_queue.pending`, at `src/sim/contract_events.zig:341-358`.
`expireDue` does the same at `src/sim/contract_events.zig:362-371`.
`applyEffectsFor` can remove pending prisoner decisions at
`src/sim/contract_events.zig:497-512`, and engagement effects can add decisions
through battle resolution at `src/sim/contract_events.zig:520-523`.

**Failure mode:** An append can reallocate the pending-event list. A removal can
shift its elements. The retained pointer can then reference freed storage or a
different event. Logging may read the wrong event, and the final
`orderedRemove` may delete an unrelated decision. `resolveChoice` also sets
`chosen` and updates standing-order memory before fallible effects finish, so a
failed effect can leave an answered but unapplied decision.

**Required fix:** Never retain a pointer or index into a collection across a
call that may mutate that collection. Copy the event ID and immutable data
needed for the effect and message. Validate and prepare all effects first.
Apply the effects, then locate the original event again by `EventId` and remove
that exact event. Standing-order memory and `chosen` must be committed only
after the effects can no longer fail.

**Best-practice design:** Give decision resolution a prepare/commit shape:

```text
prepareDecision(event_id, choice) -> PreparedDecision
commitDecision(gs, prepared)      -> no allocation or validation failure
```

`PreparedDecision` should own or reference stable immutable definitions, never
pointers into `GameState` collections.

**Regression tests:** Resolve and expire an event whose effect removes an
earlier pending event. Resolve an event whose effect appends another event.
Inject allocation failure at each preparation allocation and assert the full
state digest is unchanged.

### A2. Battle resolution retains a person pointer across person-map insertion

**Evidence:** The opening phase stores `edge_used_by` as `?*Person` at
`src/sim/battle.zig:657-709`. `takePrisoners` inserts generated people into the
same hash map at `src/sim/battle.zig:818-833`. The retained pointer is later
dereferenced for the battle report at `src/sim/battle.zig:992`.

**Failure mode:** Inserting prisoners can reallocate the person map and
invalidate every pointer into it. A battle in which Edge is spent and prisoners
are captured can read invalid memory while constructing the after-action
report.

**Required fix:** Store `PersonId`, not `*Person`, in `Opening`. Re-fetch the
person by ID only at the point of use, or copy the ranked display name before
any operation that can insert people.

**Best-practice design:** Persistent simulation values may contain typed IDs or
owned values, not pointers into growable collections. Restrict entity pointers
to short local scopes that contain no allocation, insertion, removal, or call
into code that may perform those operations.

**Regression test:** Force a losing roll that spends Edge, force prisoner
capture, and verify the report identifies the correct pilot under an allocator
configuration that causes the people map to grow.

## High-severity findings

### A3. Compound state mutations are not failure-atomic

**Evidence:** `transferFunds` posts the debit before appending a courier or
posting an immediate credit at `src/sim/state.zig:378-398`. `runPolicies`
suppresses any resulting error at `src/sim/tick.zig:68-84`.
`createForce` inserts a force before appending it to its parent, and
`assignUnit` changes the unit and appends it before validating the pilot at
`src/sim/state.zig:1363-1394`. `moveUnitToForce` and `placeUnitInCompany`
remove the old roster entry before the destination append at
`src/sim/state.zig:1673-1752`. `holdUnit` removes a unit before appending the
held hull, while `releaseHull` removes the held hull before restoring all live
indexes at `src/sim/state.zig:1936-1967`.

**Failure mode:** Allocation failure can lose money, units, or relationships.
`assignUnit` can also return `UnknownPerson` after changing the unit and force
roster. The state then contains contradictory views of the same entity.

**Required fix:** Validate all identities and business rules before mutation.
Reserve capacity in every target list, map, ledger, and log before the first
mutation. Commit all linked representations only after preparation succeeds.
Do not catch and continue after an error that may have followed a mutation.

**Best-practice design:** Define a small number of mutation patterns and apply
them consistently:

- Validate -> reserve -> commit for list/map relationship changes.
- Quote -> reserve capacity -> debit -> commit shipment for economic changes.
- Prepare log text and ledger entries before changing balances or stock.
- Stage RNG state when a command can fail after drawing randomness.

This work is broadly scheduled in `TODO.md` under full failure atomicity, but
the paths above are current concrete defects and should be fixed first.

**Regression tests:** Use a failing allocator at every allocation point in each
mutation pattern. Compare `GameState.hash()` before and after every failed
operation. Add ordinary-error tests for unknown pilots and destinations, not
only out-of-memory tests.

### A4. The save loader silently drops malformed relational rows

**Evidence:** An orphan `unit_slot` is skipped at
`src/persist/store.zig:1217-1221`. `force_unit` and `force_child` validate the
owning force but not the referenced unit or child at
`src/persist/store.zig:1258-1271`. Stock for a nonexistent site is silently
dropped because `GameState.addStock` returns success when no stock map exists
at `src/sim/state.zig:1092-1096`. An orphan refit operation is skipped at
`src/persist/store.zig:1815-1818`.

**Failure mode:** A malformed save loads successfully after losing slots,
inventory, force members, or refit operations. The next save permanently
rewrites the degraded state. This contradicts the fail-closed policy in
`ARCHITECTURE.md`.

**Required fix:** Every relationship decoder must validate both ends of every
nonzero reference. Missing parents and children must return `CorruptSave`.
Persistence loading must not call permissive runtime helpers such as
`addStock`; use a strict loader helper that distinguishes an invalid site from
a valid mutation.

**Best-practice design:** Add a post-decode integrity pass that validates the
entire object graph after all tables are loaded and before migration or derived
field refresh. Keep per-row checks for precise failures, but use the graph pass
as defense in depth.

**Regression tests:** Corrupt each relationship family independently: unit
slots, force units, force children, assignments, stock sites, refit plans,
projects, policies, transfers, contracts, events, and battle reports. Every
case must return `CorruptSave` without producing a usable `GameState`.

### A5. Unknown persistence discriminator values are reinterpreted as valid data

**Evidence:** Any listing kind other than `"unit"` becomes `.part` at
`src/persist/store.zig:1567-1569`. Any refit operation kind other than
`"remove"` becomes `.install` at `src/persist/store.zig:1818-1825`. Numerous
boolean fields accept every nonzero integer, for example
`src/persist/store.zig:1040-1041` and `src/persist/store.zig:1573-1577`.

**Failure mode:** Corrupt or future data changes meaning instead of being
rejected. Values such as `2` become true, and unknown tagged variants become a
different valid variant.

**Required fix:** Decode every textual discriminator with an exhaustive parser
that returns `CorruptSave` for unknown values. Decode booleans with a strict
`0|1` helper. Add bounded decoders for percentages, morale, fatigue, armor,
facility levels, and other domain-limited integers rather than checking only
storage width.

**Best-practice design:** Centralize strict persistence primitives such as
`bool01`, `boundedInt`, `requiredId`, and exact tagged-union decoders. Mirror
the same invariants with SQLite `CHECK` constraints when the planned table
rebuild lands.

### A6. Missing or stale next-ID metadata can overwrite loaded entities

**Evidence:** Entity counters retain their initial values unless matching meta
rows happen to exist at `src/persist/store.zig:1025-1057`. Only battle IDs and
event IDs are reconstructed after load at `src/persist/store.zig:1006-1008`
and `src/persist/store.zig:1650-1656`.

**Failure mode:** If `next_person_id`, `next_unit_id`, `next_force_id`,
`next_hq_id`, or `next_contract_id` is missing or not greater than the highest
loaded ID, the next generated entity can reuse an occupied key. Map insertion
can overwrite an entity while lists still reference the old meaning of that
ID.

**Required fix:** For the current schema, require every counter row. After all
entities and references are loaded, require each counter to be strictly greater
than the highest ID in its namespace. For historical schemas that legitimately
lack a counter, reconstruct `max + 1` with overflow checking.

**Best-practice design:** Put all identity namespaces behind one validated
metadata manifest used by save, load, digest, and tests. Do not maintain a
special one-off recovery path for each newly discovered counter.

**Regression tests:** Delete and lower every counter row in turn, load the
campaign, and attempt to create the corresponding entity. Current-schema saves
must fail closed; supported historical saves must reconstruct without
collision.

### A7. Pending-event choice indices are not validated on load

**Evidence:** `default_choice` and `chosen` are converted to `usize` at
`src/persist/store.zig:1628-1648` without checking them against the options
rebuilt from the event kind. `expireDue` indexes
`ev.options[ev.default_choice]` directly at
`src/sim/contract_events.zig:365-370`.

**Failure mode:** An out-of-range default can panic when the deadline arrives.
An out-of-range non-null chosen value can make an event appear answered without
applying a valid choice.

**Required fix:** Require `options.len > 0`, `default_choice < options.len`, and
`chosen == null or chosen < options.len` during loading. Validate referenced
person, contract, company, and battle IDs against the event kind's requirements.

**Regression tests:** Tamper each index and reference independently, load, and
advance through the deadline. The load must return `CorruptSave`; turn
processing must never be the first integrity check.

### A8. "Not deployed" is incorrectly used as "physically home"

**Evidence:** `companyPosture` explicitly distinguishes `.home`, `.en_route`,
`.deployed`, `.returning`, and `.idle_afield` at
`src/sim/state.zig:938-966`. Medical care classifies every company without a
deployment contract as home at `src/sim/medical.zig:85-109`. Weekly rest and
rotation reset do the same at `src/sim/medical.zig:343-403`. Commands use
`isCompanyDeployed` rather than `isCompanyHome` for personnel and hull actions,
including `src/sim/commands.zig:872-887`,
`src/sim/commands.zig:1045-1050`, and
`src/sim/commands.zig:1615-1636`.

**Failure mode:** Returning or idle-afield companies can receive home-hospital,
rest, and training benefits. Personnel can take HQ-local actions, and hulls can
be mothballed or sold, while physically away from the HQ.

**Required fix:** Use `isCompanyHome` for every HQ-local action and benefit.
Use an explicit posture switch where returning and idle-afield behavior differs
from active deployment. Reserve `isCompanyDeployed` for rules specifically
about having a deployment contract.

**Best-practice design:** Make location eligibility named predicates owned by
the relevant subsystem, for example `canTrainAtHome`, `canEnterColdStorage`,
and `careForPosture`. Each predicate should switch exhaustively over
`CompanyPosture` so adding a posture forces a compile-time review.

**Regression tests:** Exercise all five postures against medical care, weekly
rest, training, leave, transfers, selling, mothballing, and rotation reset.

### A9. Malformed TUI `day` input can advance the campaign

**Evidence:** The TUI parses `:day` with `catch 1` at
`src/tui/app.zig:3784-3787` and does not require complete token consumption.

**Failure mode:** `:day nonsense`, `:day -1`, and `:day 1 unexpected` can
advance time instead of reporting a parse error. Time advancement can trigger
battles, payroll, events, and irreversible losses.

**Required fix:** Parse frontend actions through a strict shared parser. Reject
bad numbers and trailing tokens. No parser should replace malformed player
input with an action-producing default.

**Best-practice design:** Extend `sim/cli.zig` with an application-level action
union for frontend actions such as day, save, help, settings, and quit. Both
frontends should parse the same input into the same action value.

**Regression tests:** Assert that malformed, negative, overflowing, and
trailing-token forms do not change the state digest or campaign day.

### A10. Seven-day TUI advancement bypasses the end-turn checklist modal

**Evidence:** Global week advance calls `endTurnRequest(7)` at
`src/tui/app.zig:1947-1949`. `endTurnRequest` opens the checklist only when
`days == 1` at `src/tui/app.zig:2443-2451`.

**Failure mode:** A player can skip a week of visible warnings without being
shown the checklist that gates an ordinary one-day advance. This makes `n` and
`N` materially different safety operations without presenting `N` as a forced
advance.

**Required fix:** Apply the checklist policy to every advance duration. If a
force operation is intentionally supported, name and confirm it explicitly and
make the same distinction available in both frontends.

**Regression test:** Populate each checklist warning, press the one-day and
seven-day bindings, and assert both open the checklist before executing the
command.

## Medium-severity findings

### A11. Typed TUI commands discard command-specific results

**Evidence:** The TUI executes a parsed command and always reports
`done: <verb>` at `src/tui/app.zig:3832-3838`. The REPL interprets meaningful
result fields at `src/main.zig:785-807`, including failed sourcing, hull fraud,
created IDs, transit days, moved tonnage, and emergency resupply.

**Failure mode:** A typed `:order` can report success when sourcing failed. A
typed purchase can conceal fraud or delivery timing. Shortcut, TUI command
line, and REPL behavior disagree despite invoking the same command.

**Required fix:** Add one application-layer result presenter that maps
`Command + Result` to structured feedback. Both frontends should consume that
view. Do not flatten every successful `commands.execute` call into a generic
success sentence.

### A12. `stockpolicy` explicit-zero removal is parsed as a positive target

**Evidence:** `parseCommand` changes `target == 0 and min > 0` into `min * 2`
at `src/sim/cli.zig:157-164`. Usage says `0 target removes` at
`src/sim/cli.zig:686`. The command uses `target == 0` as the removal operation
at `src/sim/commands.zig:1141-1160`.

**Failure mode:** `stockpolicy hq:1 armor 5 0` creates or updates a target of
10 instead of removing the policy.

**Required fix:** Preserve whether the optional target token was absent. Apply
the `min * 2` default only when absent; preserve an explicitly supplied zero.

**Regression tests:** Cover omitted target, explicit zero, and a positive
target in parser and command integration tests.

### A13. Frontend prevalidation duplicates command rules and refusal messages

**Evidence:** The TUI suppresses command execution based on query or client
checks in `src/tui/app.zig:2333-2338`, `src/tui/app.zig:3145-3190`, and
`src/tui/screens/market.zig:100-139`. `execResultWith` provides caller-owned
error text at `src/tui/app.zig:2485-2500` instead of the canonical
`cli.errorText` path.

**Failure mode:** Query eligibility, frontend checks, command validation, and
custom messages can drift. A row may look actionable but be suppressed for a
different reason than the command would report.

**Required fix:** Eligibility fields may dim or annotate controls, but
activation must submit the command and let it revalidate. Replace custom
refusal tables with typed errors and one canonical error-to-sentence mapping.
This direction is already scheduled in `TODO.md` for `execResult`.

### A14. Data-overlay validation omits runtime safety preconditions

**Evidence:** `build.zig:136-149` runs only tests whose names begin with
`data: `. The rank-table cardinality and ordering test at
`src/domain/rank.zig:58-66` is not selected, while `Rank.row` indexes the table
directly at `src/domain/rank.zig:21-23`. Name generation indexes first, last,
and callsign arrays at `src/gen/person_gen.zig:70-80` without a selected data
test requiring them to be nonempty. Canonical Mek legality is likewise outside
the filtered validation set.

**Failure mode:** A mod can pass `zig build -Ddata=<dir>` and later panic from
an undersized enum-indexed table or empty random-selection pool. This
contradicts `docs/modding.md:17-29`.

**Required fix:** Put all runtime table preconditions in named validation
functions and invoke them from the filtered validation step. Cover enum-table
cardinality/order, nonempty random pools, positive weights, cross-file keys,
and canonical construction legality.

**Best-practice design:** Prefer a dedicated data-validation executable or
single registry-driven test over relying on test-name prefixes. Add invalid
overlay fixtures to CI so each validation family is proven to fail the build.

### A15. Route selection ignores capacity and quality until after path choice

**Evidence:** `routeBetween` uses insertion-order breadth-first search at
`src/sim/network.zig:63-144`. Throughput is checked only after a route is
selected at `src/sim/network.zig:154-179`.

**Failure mode:** A saturated shortest-hop path rejects a shipment even when
another linked path has capacity. Equal-hop choices depend on link insertion
order rather than an explicit deterministic policy. The selected route also
does not optimize delay or cost.

**Required fix:** Route with shipment constraints included. Exclude links that
cannot carry the requested tonnage, then minimize the declared objective such
as delivery days followed by cost. Use stable HQ IDs as the final tie-breaker.

**Best-practice design:** Replace `routeBetween` with a quote function whose
inputs include tonnage and whose result contains path, capacity, days, and
cost. The command should commit exactly the quoted path after revalidating its
capacity.

### A16. Support capacity bypasses the canonical operational-unit rule

**Evidence:** `siteCapacityTons` counts every company truck except those with
`status == .destroyed` at `src/sim/state.zig:1122-1137`. Battle salvage capacity
uses a similar truck count rather than `unitOperational`.

**Failure mode:** Uncrewed, mothballed, damaged, or repairing trucks can provide
field storage and salvage capacity despite the architecture's rule that
support modifiers require an operational hull and fit crew.

**Required fix:** Create one named operational truck-capacity rule and use it
for field storage, salvage hauling, resupply planning, and every corresponding
query.

**Regression test:** Toggle crew, damage, mothball, transit, and bay-job state
on a truck and assert every consumer reports the same capacity.

### A17. Local beachhead pricing uses a fixed distance instead of actual reach

**Evidence:** `localPriceMultBp` always passes 30 LY to the logistics rule at
`src/sim/field_supply.zig:158-165`. Contracts retain actual distance and the
offering HQ needed to determine distance beyond the influence ring.

**Failure mode:** Every beachhead receives the same distance component even
though the architecture specifies a surcharge per 30 LY beyond the ring.

**Required fix:** Compute `max(0, contract distance - offering HQ influence)`
in one lower-level rule. Use the same quote for ordinary local purchases and
emergency resupply.

**Regression test:** Compare otherwise identical contracts at two distances
beyond the ring and assert distinct, correctly capped multipliers.

### A18. User-controlled text still enters presentation markup unescaped

**Evidence:** Wizard names are interpolated into markup at
`src/tui/app.zig:706-715` and `src/tui/app.zig:750-754`. Ledger transaction
notes are passed directly into table rows at `src/sim/queries.zig:1172-1181`.
HQ names become transaction notes at `src/sim/tick.zig:470-482`.

**Failure mode:** A name containing valid markup tags can alter styles, hide
delimiters, and make measured widths disagree with intended text. The tokenizer
prevents raw terminal escape injection, but presentation injection remains.

**Required fix:** Route every player name, filename, log line, transaction
note, and prompt value through `table.plain`, `MarkupBuilder.appendPlain`, or a
typed `table.Raw` endpoint before composing markup.

**Best-practice design:** Make markup-bearing strings a distinct type rather
than `[]const u8`. Restrict `appendMarkup` to literals or values already proven
safe. Extend the existing hostile-name test across the wizard and ledger.

### A19. Narrow Forces focus can move to a pane that is not rendered

**Evidence:** The Forces screen renders its side panes only when
`layout.wide(b.w)` is true at `src/tui/screens/forces.zig:23-60`. Its screen
spec declares two narrow panes at `src/tui/app.zig:2003`. Movement uses the
unassigned pool whenever focus is not zero at
`src/tui/screens/forces.zig:63-72`.

**Failure mode:** At supported narrow sizes, Tab can move focus to an invisible
pane. Cursor movement then changes an unseen list and appears unresponsive.

**Required fix:** Declare one narrow pane, or render the second pane in a
stacked narrow layout. Add a structural client test asserting every focus index
maps to a visible pane at every layout tier.

### A20. Terminal width assumes every Unicode code point occupies one cell

**Evidence:** Drawing advances one cell per decoded code point at
`src/tui/screen.zig:149-177`. Query width calculations count code points at
`src/sim/queries.zig:76-91`. Text entry accepts general Unicode.

**Failure mode:** Wide CJK characters occupy two terminal cells and combining
marks occupy zero. Borders, clipping, padding, cursor highlighting, and repaint
positions become incorrect.

**Required fix:** Implement one terminal-width function equivalent to
`wcwidth` and use it for drawing, measuring, clipping, padding, and wrapping.
Define and test behavior for combining marks, variation selectors, emoji, and
unsupported wide glyphs.

### A21. Music child shutdown can block the TUI indefinitely

**Evidence:** Music teardown sends `SIGTERM` and then performs blocking
`waitpid(..., 0)` at `src/tui/music.zig:257-265`. Playlist rebuilds allocate a
new order in a long-lived arena at `src/tui/music.zig:142-159` and
`src/tui/music.zig:212-216`.

**Failure mode:** A player process that ignores or delays termination can hang
exit, track skip, volume changes, or soundtrack changes. Long sessions also
accumulate obsolete playlist allocations.

**Required fix:** Poll nonblocking for a bounded interval, escalate termination
after the timeout, and always reap the child. Separate immutable scanned track
data from replaceable playlist storage and reclaim the previous order.

### A22. PNG validation ignores CRCs and permits excessive resource use

**Evidence:** PNG chunks are parsed without validating CRCs at
`src/tui/png.zig:49-71`. Accepted dimensions permit roughly 64 million pixels,
and the decoded representation allocates RGB plus inflation and row buffers.
RGBA input is accepted but alpha is discarded at `src/tui/png.zig:130-139`.

**Failure mode:** Corrupt local images may be accepted, large images can cause
substantial memory pressure, and transparent logos render hidden RGB values as
opaque boxes or halos.

**Required fix:** Validate CRCs and critical chunk ordering, require exact
decompressed length, set a practical emblem pixel limit, and preserve alpha or
blend it against an explicit background. Add malformed, oversized, transparent,
and partial-alpha fixtures.

## Persistence and lifecycle findings

### A23. Store initialization mutates before rejecting a future schema

**Evidence:** `Store.fromDb` executes current DDL before reading and rejecting a
newer schema at `src/persist/store.zig:168-187`. `getSetting` converts prepare,
bind, and step errors into a caller-supplied default at
`src/persist/store.zig:267-272`.

**Failure mode:** Opening a future store can create current tables before
returning `StoreNewerThanGame`. A malformed or unreadable settings table can be
misclassified as schema version 1 and sent through migrations.

**Required fix:** Read schema metadata strictly before mutating an existing
database. Distinguish a genuinely new store from missing or corrupt metadata.
Wrap bootstrap DDL and migrations in one transaction and roll back every
change when initialization fails. Reject nonpositive schema versions rather
than clamping them.

### A24. SQLite handles can leak on open and initialization failures

**Evidence:** `sqlite3_open` failure returns without closing a non-null handle
at `src/persist/sqlite.zig:44-47`. `Store.open` transfers the opened DB directly
to `fromDb` without an `errdefer` close at `src/persist/store.zig:168-187`.

**Failure mode:** Repeated failures opening malformed, locked, or unsupported
stores can leak native handles and file descriptors.

**Required fix:** Close any non-null SQLite handle returned alongside an open
error. Hold ownership in `Store.open` with `errdefer db.close()` until
`fromDb` succeeds. Document whether `fromDb` adopts ownership on entry or only
on success.

### A25. Player deletion is not atomic across all owned campaigns

**Evidence:** `deletePlayer` loops over campaigns and calls `deleteCampaign`
separately at `src/persist/store.zig:305-315`. Each campaign deletion commits
its own transaction at `src/persist/store.zig:317-327`.

**Failure mode:** If a later deletion fails, earlier campaigns remain deleted
while the player and remaining campaigns survive.

**Required fix:** Run the entire player cascade in one transaction. Extract an
internal non-transactional `clearCampaignRows` operation used by both campaign
deletion and player deletion. The planned foreign-key migration should add
`ON DELETE CASCADE` where ownership is unambiguous.

### A26. SQLite errors are too coarse for truthful recovery guidance

**Evidence:** The SQLite binding maps database failures to `SqliteError`, for
example `src/persist/sqlite.zig:39-76`. The frontend therefore falls back to a
generic unexpected-failure sentence.

**Failure mode:** Busy/locked, read-only, disk-full, malformed-database,
permission, and constraint failures are indistinguishable. A generic
"nothing was changed" message is not always truthful for currently non-atomic
operations.

**Required fix:** Map primary and extended SQLite result codes into a small
application error set such as `StoreBusy`, `StoreReadOnly`, `StoreFull`,
`CorruptStore`, and `ConstraintViolation`. Preserve detailed SQLite diagnostics
for logs while presenting stable recovery instructions to the player.

### A27. Migration tests do not exercise most historical ALTER paths

**Evidence:** The historical fixture around `src/persist/store.zig:2237-2253`
creates only a small subset of historical tables. Other tables are created
directly in their current shape before migrations run, so many `ALTER TABLE`
statements are never tested against their real previous layouts.

**Failure mode:** A typo, invalid default, incompatible historical shape, or
duplicate-column edge case can pass the suite and fail on a real old store.

**Required fix:** Add fixtures at meaningful schema boundaries, especially
before changes to contracts, listings, pending events, battle reports, and
candidates. Verify resulting schema, loaded behavior, idempotence, rollback,
and future-version refusal without mutation.

### A28. Campaign tables lack indexes for common campaign-scoped operations

**Evidence:** Many tables have no index beginning with `cid`, while every save
or deletion clears each table by `cid` and battle-report children are loaded by
`(cid, report_ord)`.

**Failure mode:** Multi-campaign stores perform repeated full-table scans during
save, delete, and report loading. Cost grows with the lifetime of the whole
store rather than the selected campaign.

**Required fix:** Add indexes such as `(cid)`, `(cid, ord)`, and
`(cid, parent_id, ord)`. Use unique indexes where row identity requires one.
Measure save/load plans with representative long-lived stores before choosing
the final set.

## Build, packaging, and CI findings

### A29. Overlay path mistakes silently compile stock data

**Evidence:** Candidate access failures in `build.zig:43-56` silently fall back
to stock data. A nonexistent `-Ddata` directory or an overlay with no recognized
files succeeds.

**Failure mode:** A developer or packager can believe a mod was compiled and
validated while the executable actually contains stock data.

**Required fix:** Require `-Ddata` to name an accessible directory. Fail, or at
minimum emit a prominent build warning, when it overlays zero recognized
files. Preserve per-file stock fallback for a valid partial overlay.

### A30. The package manifest includes the entire optional soundtrack

**Evidence:** `build.zig.zon:73-80` includes `data` recursively. `build.zig`
treats `data/music` as a large opt-in install at `build.zig:93-102`.

**Failure mode:** Package hashing, fetching, source distribution, and caching
include hundreds of megabytes that normal builds do not need.

**Required fix:** List required ZON files and directories explicitly, or move
the soundtrack outside the package path. Distribute music as a separate asset
archive consumed only by `-Dbundle-music` release builds.

### A31. CI does not compile the documented release configuration or supported platforms

**Evidence:** `.github/workflows/ci.yml:7-26` runs one Ubuntu default/debug
configuration. The documented `ReleaseFast` package and macOS behavior are not
compiled. Windows support is not implemented and is already scheduled in
`TODO.md`.

**Failure mode:** Release-only compilation, optimization-sensitive undefined
behavior, platform-specific terminal, path, SQLite, or player failures can
surface only during release preparation.

**Required fix:** Add a clean `ReleaseFast` package build. Add compile/test jobs
for every platform the README claims to support. Qualify user-facing platform
claims until Windows terminal, resize, process, path, music, and SQLite support
exists.

### A32. CI action versions and token permissions are not hardened

**Evidence:** `.github/workflows/ci.yml:11-16` uses mutable action tags and does
not declare top-level permissions. Checkout retains credentials by default.

**Failure mode:** Workflow privileges depend on repository defaults, and a
compromised or retagged action release has a larger impact than necessary.

**Required fix:** Pin actions to reviewed commit SHAs, declare
`permissions: { contents: read }`, set `persist-credentials: false`, add job
timeouts, and use concurrency cancellation for superseded runs.

### A33. Bundled media has no explicit rights and attribution manifest

**Evidence:** The repository and package contain soundtrack and logo assets,
while README attribution covers project inspiration rather than each asset's
author, source, license, or redistribution permission.

**Failure mode:** Release and redistribution due diligence cannot establish
that every bundled binary asset may be shipped under the repository's terms.

**Required fix:** Add `ASSETS.md` or `NOTICE` listing each asset set, its source,
author, license or ownership statement, and redistribution terms. Exclude any
asset with unresolved rights from package and release inputs.

### A34. Smoke scripts can delete arbitrary caller paths and leak child processes

**Evidence:** `docs/repl_smoke.sh` and `docs/tui_smoke.py` remove the supplied
database path. The PTY script does not consistently wrap child lifetime in
`try/finally` cleanup.

**Failure mode:** A mistaken argument can remove an unintended file. Failed
smoke assertions can leave a child process running.

**Required fix:** Create and own temporary paths by default, validate explicit
paths, reject dangerous locations, and terminate/reap children in `finally`.
Add bounded timeouts around every interaction phase.

## Structural findings

### A35. Large central modules obscure subsystem ownership

**Evidence:** `src/sim/queries.zig`, `src/sim/commands.zig`,
`src/tui/app.zig`, `src/persist/store.zig`, `src/sim/battle.zig`,
`src/sim/state.zig`, and `src/sim/contract_events.zig` substantially exceed the
project's preferred module and function sizes. This is acknowledged as a
post-adoption exception in `TODO.md`.

**Impact:** Review surfaces are too broad, subsystem ownership is less obvious,
focused testing is harder, and unrelated edits contend in the same files. The
duplicated parsing, prevalidation, and pointer-lifetime defects above are
symptoms of too much orchestration and implementation living together.

**Required fix:** Preserve stable public facades while moving implementation to
subsystem-owned modules:

- Keep `commands.zig` as the command union, dispatcher, and error mapping;
  move handlers into command modules by subsystem.
- Keep `queries.zig` as the public query namespace; move view builders into
  finance, contracts, personnel, forces, HQ, market, and battle query modules.
- Split `app.zig` into session/lobby, wizard, modal controllers, command line,
  settings, and shared application state.
- Split `store.zig` into schema/migration management and per-subsystem codecs.
- Move state methods that encode pricing, staffing, readiness, or ownership
  rules into their subsystem owners; keep `GameState` focused on storage and
  primitive lookup.

**Best-practice constraint:** A split must not create parallel public APIs or
duplicate rules. The facade remains the import boundary, and rule tests move
with the owning implementation.

### A36. REPL session ownership still bypasses the application facade

**Evidence:** `src/main.zig` directly constructs, destroys, hashes, and replaces
`GameState`, while the TUI uses the lobby/session facade.

**Impact:** The two frontends have different lifecycle knowledge. Future
changes to allocator ownership, persistence, or session replacement must be
implemented twice and can fail differently.

**Required fix:** Introduce the lobby-owned session handle already scheduled in
`TODO.md`. Both TUI and REPL should hold that handle and use facade operations
for new, load, save, discard, and replacement. Expose state hashes only through
a deliberate debug/query endpoint.

### A37. Completion is a second read boundary outside queries

**Evidence:** Completion in `src/sim/cli.zig` walks game-state collections and
domain catalogues, and the TUI invokes it directly.

**Impact:** Completion bypasses the declared query-only read path and combines
parser responsibilities with visibility and domain lookup rules.

**Required fix:** Have queries return structured completion candidates for the
current session. Keep `cli.zig` responsible for token context, lexical matching,
and command parsing, not state traversal.

## Positive architecture findings

- Core dependency direction generally follows the documented layers.
- The simulation core avoids filesystem, process, wall-clock, and global
  allocator access.
- Randomness is routed through named streams with stable salts.
- Money uses integer C-bills and basis-point multiplication.
- Typed IDs prevent accidental cross-entity identifier use.
- Command and query facades provide a sound boundary despite the exceptions
  identified above.
- The state digest, golden simulation tests, and deterministic continuation
  tests provide unusually strong regression infrastructure.
- Campaign saving is transactionally rewritten, and first-save campaign
  identity is assigned only after commit.
- Per-stream RNG persistence and historical compatibility are well designed.
- Query rows generally carry typed identity instead of relying on rendered text.
- Shared key tables, generated key documentation, cursor clamping, and terminal
  teardown demonstrate strong frontend discipline.
- Static data is compile-time typed and already has substantial cross-table
  validation.
- CI runs formatting, contract checks, unit tests, and both frontend smoke
  suites on every push and pull request.

## Recommended delivery sequence

### Phase 1: Campaign-integrity fixes

Fix A1 through A7 as small sequential changes. Each change should add the
specific corruption or failing-allocation regression before changing behavior.
Do not combine module splitting with these correctness changes.

### Phase 2: Location and frontend correctness

Fix A8 through A13 and A19. Add a posture matrix test and one shared frontend
action/result path before deleting duplicate parsing or messages.

### Phase 3: Rule consolidation

Fix A15 through A18. Each rule should gain one lower-level owner and tests that
assert commands and queries agree with it.

### Phase 4: Persistence hardening

Fix A23 through A28 together with the scheduled foreign-key/table-rebuild work.
Keep loader validation even after database constraints land; constraints guard
writes, while the loader guards old, external, and damaged stores.

### Phase 5: Build and operational hardening

Fix A14 and A29 through A34. Add intentionally invalid data fixtures, a clean
release-package build, explicit asset provenance, and hardened CI permissions.

### Phase 6: Structural decomposition

Address A35 through A37 only after the correctness and atomicity fixes are
green. Split one subsystem at a time behind an unchanged facade, preserve the
golden hash where behavior is intended to remain unchanged, and land each split
before beginning the next.
