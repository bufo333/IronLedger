# Coding contract (proposed update)

The rules every change to IRON LEDGER must follow. This document is
normative: it says what the code must do, not what it does today. Where the
code falls short, the code is wrong, not the rule. `ARCHITECTURE.md`,
`docs/tui.md`, and the Zig guide explain the design; this document defines the
enforceable engineering contract.

Do not restate these rules elsewhere. Link to the owning rule. Every section
ends with reviewer checks. The repository's contract-verification script is
the executable source of truth for mechanical checks; prose snippets are
examples and must not become a second, drifting implementation.

---

## 0. Governing principles

### 1. No partial truth

A failed command changes nothing. A saved campaign preserves everything. A
loaded campaign is either valid or rejected. A game rule sees the actual site
and actual operational readiness. An actionable row carries its actual typed
identity. Untrusted text never becomes terminal control.

Convenience defaults, inferred identity, silent row skipping, partial
mutation, and best-effort persistence are prohibited at simulation,
application, persistence, and presentation boundaries.

### 2. Determinism is a compatibility promise

The same initial state and the same commands produce the same state. This
includes state reached after save/load, migration, and executable restart.
Random-stream identity, iteration order where it affects outcomes, arithmetic
rounding, and migration defaults are part of save compatibility.

### 3. One rule, one owner, one result

Every eligibility rule, predicate, cost, capacity, quote, shortfall,
ranking, threshold, posture, and identity decision has one named owner.
Commands, queries, ticks, persistence validation, and frontends consume that
result; they do not reconstruct it.

### 4. Failure is designed, not ignored

`OutOfMemory`, database errors, malformed saves, invalid UTF-8, unavailable
resources, and failed process or terminal operations are real failure modes.
An arena allocator, a local executable, or a supposedly unreachable UI path
does not exempt code from preserving invariants.

**Reviewer checks**

- Can any error leave money without an asset, stock without a job, a removed
  listing without a result, an advanced ID without an entity, or a chosen
  event without its effects?
- Can two materially different campaigns produce the same integrity digest?
- Can malformed external data silently become valid gameplay state?

---

## 1. Layers and dependency direction

```text
frontends     src/tui/*  ·  src/main.zig
application   src/sim/cli.zig  ·  src/persist/lobby.zig
persistence   src/persist/{store,sqlite}.zig
views         src/sim/queries.zig                    <- a leaf
simulation    src/sim/{commands,tick,checklist,hq_ops,battle,...}.zig
state         src/sim/state.zig
rules         src/domain/*  ·  src/econ/*  ·  src/gen/*
random        src/sim/rng.zig                        <- lower-level service
data          data/*.zon  ·  data/tables/*.zon
```

`src/sim/rng.zig` is deliberately shown below the rules layer despite its
path. It imports only `std` and exposes deterministic random sources. Domain,
economy, and generation rules may accept an `Rng` or narrower random-source
input; they may not own stream selection or simulation state.

### 5. Imports point down only

A module imports only modules in its own layer or a lower layer. Stateful
orchestration belongs in `src/sim`, even when the pure formula it invokes
belongs in `src/econ` or `src/gen`.

Nothing below `queries.zig` imports it. A test may cross the boundary only to
assert that a command and view agree on the same lower-level rule.

### 6. The simulation core is pure

`src/domain`, `src/sim`, `src/econ`, and `src/gen` contain no filesystem,
process, terminal, network, wall-clock, or environment access; no file-scope
mutable variables; no process-global allocator; and no PRNG construction
outside `sim/rng.zig`.

Every allocation comes from `GameState`, a per-operation scratch allocator,
or an allocator passed by the caller.

### 7. Commands are the only mutation boundary

Every mutation of `GameState` from outside `src/sim` goes through
`commands.execute`. Missing behavior becomes a command. A frontend,
persistence facade, or query never patches state, repairs a derived field,
advances an ID, consumes RNG, or invokes a mutating `GameState` method.

### 8. Queries are the only read boundary for frontends

Frontends read campaign state only through `queries`. They never walk a
`GameState` collection, call a `GameState` method, inspect a queue, or invoke a
domain lookup. Domain imports in frontends are limited to typed IDs and enums
needed for command payloads and view selection.

### 9. Persistence has one facade

Lobby, autosave, REPL, and TUI session lifecycle use one application facade.
Screens do not import `store`, `sqlite`, or persistence row types. Frontends
hold an application-owned session handle rather than concrete `GameState`
storage.

### 10. Verbs and refusal text exist once

`src/sim/cli.zig` parses every textual command for the REPL and TUI command
line. Each verb has one parser branch, one usage entry, and strict token
consumption. Closed choices reject unknown values. `cli.errorText` owns every
player-facing refusal sentence; raw error names are not UI text.

**Reviewer checks**

```sh
# Canonical checks must be recursive and live in docs/verify-contract.sh.
rg -n '\b(g|gs)\.(units|hqs|forces|people|clock|funds|loans|market_listings|contract_offers|supply_policies|unit_transfers|battle_reports)\b' src/tui src/main.zig
rg -n 'game\.(store|state|hq_ops|battle|maintenance|medical|tick|planet|faction|chassis|part)\b' src/tui src/main.zig
rg -n 'queries\.zig' src/sim src/econ src/domain src/gen
rg -n 'std\.(time|fs|Io|process|posix|os)\b|page_allocator|^var ' src/domain src/sim src/econ src/gen
```

- Does a module in `domain`, `econ`, or `gen` import `GameState` or a stateful
  simulation subsystem? Move the orchestration upward.
- Does a textual verb have more than one parser branch or accept trailing
  tokens? Reject the change.

---

## 2. Commands, ticks, and failure atomicity

### 11. Commands are failure-atomic

If `commands.execute` returns an error, gameplay state is observationally
identical to the state before the command. This includes balances, stock,
assignments, statuses, offers, queues, projects, throughput reservations,
ID counters, RNG state, logs, ledgers, reports, and derived fields.

`OutOfMemory` is an error and is not exempt. Arena allocation does not make
partial mutation acceptable.

Failure atomicity does not require a universal transaction framework or
command journal. It is achieved by preparation (rule 12), with shared atomic
helpers owned by each subsystem (rule 14). Rollback is the fallback where
preparation cannot remove every failure.

### 12. Mutations follow validate, prepare, commit

Every compound command follows this order:

1. **Validate:** check every rule without mutation or RNG consumption.
2. **Prepare:** allocate owned strings and records, reserve capacity in every
   destination, and compute the outcome. Random outcomes are drawn from a
   local copy of the relevant stream; the resulting stream state is staged
   with the outcome.
3. **Commit:** apply non-failing mutations in an order that cannot expose a
   partial result, including committing the staged RNG state.

After the first irreversible mutation, no allocation, formatting, lookup,
container growth, log construction, or other fallible operation is permitted
unless an explicit rollback guard restores every prior mutation. A rollback
guard is the fallback, not the design: prefer moving the fallible work into
preparation.

### 13. Expected refusals consume nothing

A command refused for insufficient funds, stock, capacity, staffing,
eligibility, location, or sourcing does not consume money, inventory,
throughput, RNG, an ID, or a market row. If an attempted roll has a gameplay
consequence, the command succeeds with a typed attempted outcome and commits
the staged roll rather than returning a refusal after mutation.

### 14. Compound mutations are subsystem-owned operations

Debit/credit, consume/queue, remove/create, reserve/dispatch, and
choose/apply pairs are one named atomic operation in the owning subsystem.
Callers do not manually implement one side of a compound mutation.

Examples include `transferFunds`, `consumeStockBatch`, `purchaseListing`,
`commitShipment`, `commitRefit`, and `resolveEvent`.

### 15. Batch demand is validated as a batch

When an operation needs multiple items, demand is aggregated by stable key,
validated in full, and consumed in one commit. Repeated single-item checks
against unchanged stock are prohibited. Ignoring the return value of a stock,
balance, or capacity mutation is prohibited.

### 16. Creation returns explicit identity

The operation that creates an entity returns its typed ID. A caller never
infers identity from `next_*_id - 1`, collection order, list length, rendered
text, or a subsequent global lookup. A non-creation outcome such as fraud,
withdrawal, or failed sourcing is a distinct typed result.

### 17. Ticks preserve phase invariants

Each daily phase either completes its documented unit of work or returns an
error with that unit unchanged. A phase may intentionally commit earlier
entities before a later entity fails only when restart and retry semantics are
defined, deterministic, and tested. Otherwise the phase prepares all fallible
work before mutation.

### 18. Automatic systems report failure

Automation such as stock policies, depot queueing, admission, transfers, and
standing orders does not swallow failures. Expected gameplay failures become
structured results and logs. Allocation and invariant failures propagate.

### 19. Derived state is refreshed inside the mutation

Commands refresh staffing, balances, committed strength, cached counts, and
other derived values before success is returned. Callers never repair state
after a command.

**Reviewer checks**

- Identify the first mutation in every changed command. What fallible work
  follows it?
- Where is all destination capacity reserved?
- If rollback is used, does it restore IDs, RNG, balances, collections,
  statuses, assignments, logs, and ledgers?
- Does a failed command produce the same complete gameplay digest as before?
- Does a successful command test primary and secondary effects?
- Search for ignored mutation results: `_ = .*take`, `_ = .*remove`, and
  `catch {}` in simulation code require explicit justification.

---

## 3. One rule, one place

### 20. A game rule is one named function

Eligibility, cost, capacity, quote, shortfall, ranking, threshold, posture,
and availability are each a public named function in the subsystem that owns
the rule. Its doc comment names the rule and its source: sourcebook,
architecture section, or dated play-feedback decision.

Every consumer calls it. A comment saying “mirrors”, “same as”, “keep in sync
with”, or “equivalent to” identifies a duplicate that must be removed.

### 21. Predicates are complete and named for their scope

Entity predicates replace inline status combinations. A broad capability such
as `canFight`, `canProvideMedical`, or `canRecoverWrecks` includes every
required condition: entity status, damage, physical location, assignment,
crew, crew availability, supplies, and facility requirements.

A partial predicate is named narrowly, such as `hullMechanicallyOperable` or
`hasNonDestroyedUnit`. A partial predicate may not stand in for operational
readiness.

### 22. Location-sensitive rules take a location

Rules involving facilities, staff, stock, markets, training, recovery,
medical care, freight, influence, or intelligence take an explicit `Site`,
`HqId`, `ForceId`, or other location context.

They do not select `hqs.values()[0]`, the first HQ, or the best facility
outfit-wide unless the documented rule is explicitly outfit-wide. Compatibility
values such as `.none` have one named resolution rule.

### 23. Asymmetric worlds are the locality test

Every location-sensitive subsystem has a test with two deliberately
asymmetric sites: only one has the facility, stock, staff, route, or person.
The test proves the other site receives no benefit.

### 24. A number appears once

A gameplay number lives as a named domain constant or a row in
`data/tables/*.zon`. A literal never recurs at another rule site. `// TUNE`
marks a placeholder awaiting data migration and is not permission to copy it.

### 25. Arithmetic conventions are fixed per quantity

Rounding, saturation, signedness, overflow behavior, and accounting window are
defined once beside the owning quantity. Consumers call the helper.

Capacities name their units and period: `tons_per_week`,
`tons_reserved_this_week`, `days_per_jump`. A weekly capacity cannot be
multiplied by an unexplained number of weeks and still reset weekly.

### 26. Quotes are pure; reservations mutate

A quote function consumes no funds, stock, throughput, RNG, IDs, or rows. A
reservation or commit function mutates explicitly. A caller can quote,
validate all other requirements, prepare storage, then commit.

### 27. A ledger is one function

“Need, on hand, coming, short” for each stock kind is computed by one owning
function that defines scope and which order statuses count as coming. Screens
print its rows; commands consume its result.

### 28. Formatting exists once

Money, dates, names, percentages, basis points, fatigue bands, morale bands,
and similar representations have one helper in the query or owning domain
module. Frontends and logs do not recreate formatting arithmetic.

**Reviewer checks**

- How many files changed for one rule? More than the owner plus consumers and
  tests suggests duplication.
- Does a site-sensitive function receive the site it decides for?
- Does any call use a partial mechanical predicate where crewed operational
  readiness is required?
- Does a quote mutate anything?
- Does a repeated literal have one named owner and source citation?

---

## 4. Queries and typed view models

### 29. Queries format; they do not decide

Queries may filter, sort, group, pad, color, and phrase. They may not be the
only home of a rule used by a command, tick, checklist, or another frontend.
The rule moves down; the query calls it.

### 30. One query serves every frontend

REPL and TUI render the same query result. `src/main.zig` does not walk
`GameState`, reimplement calculations, or maintain a second report model.

### 31. Queries are pure and allocator-parameterized

Queries allocate only from the allocator passed by the caller, consume no RNG,
and propagate allocation and invariant errors. They do not translate an
unexpected error into empty output, partial rows, or a plausible default.

### 32. Every actionable display row carries identity

Every rendered actionable row carries a typed entity ID and action kind. This
remains true after wrapping, expansion into multiple lines, grouping,
filtering, and sorting.

A frontend never recovers identity by parsing text, counting rendered lines,
recomputing row spans, subtracting from `next_id`, or relying on map order.
Flattened display lines carry the identity of the item and sub-action they
represent.

### 33. Markup is trusted presentation data

Markup tags are emitted only by `queries.zig`, `table.zig`, and trusted TUI
presentation code. Domain enums, command results, log text, player input,
save data, and mod strings contain no presentation markup.

Interpolated untrusted values are escaped or emitted as typed plain-text
segments; concatenating them into trusted markup strings is prohibited.

### 34. View eligibility is informative, not authoritative

Queries may show why an action is likely unavailable. On activation, the
frontend still sends the command and displays its canonical refusal. A query
pre-check never suppresses a command or invents refusal text.

**Reviewer checks**

```sh
rg -n 'gs\.(units|hqs|forces|people)\.' src/main.zig src/tui
rg -n 'indexOf\([^\n]*"\{|tokenize[^\n]*(line|text)|parse[^\n]*(row|text)' src/tui src/sim/queries.zig
```

Markup tags are declared once, in `table.marks` (`{a} {g} {c} {s} {d} {t} {p}
{/}`); the renderer mapping and the contract-verification script derive their
set from it, never from a separate hard-coded list. The script checks the
unambiguous tags (`{a}`, `{g}`, `{t}`, `{p}`, `{/}`) directly. `{c}`, `{s}`
and `{d}` are also Zig format specifiers, so they are checked contextually or
through an explicit allowlist, never by a plain grep. A test built on
`table.marks` fails when a tag is added without updating the check.

- Does the highlighted row carry the exact ID used by Enter?
- Would adding a wrapped description line change which entity is activated?
- Does a query catch an allocation error and return an empty string or list?

---

## 5. Frontend structure and trust boundaries

### 35. One registration table owns screens

A screen module exports `draw`, movement, activation, key handling, and footer
metadata and is registered once by `Tab`. Adding a screen touches the registry
and the module, not parallel switches.

### 36. Shared widgets are singular

Picker, confirmation, number form, text form, list pane, table pane, cursor
clamp, and modal framing exist once. Screens do not implement private variants.

### 37. Command execution has one feedback path

`execResult` executes a command and owns canonical refusal text, status style,
and reset behavior while returning a successful typed `Result` when needed.
`exec` and `execSay` build on it. No screen calls `commands.execute` directly
or catches command errors itself.

### 38. Layout is named and focus follows visibility

Split ratios, size thresholds, minimum pane sizes, and pane counts live in one
layout model. On resize or tab change, focus is clamped to panes actually
rendered at the new size. Hidden panes cannot receive movement or activation.

### 39. Keys have one structured source

Each screen has one key metadata table. Footer, pane titles, help, and the key
table in `docs/tui.md` derive from or are verified against it. A smoke or unit
test rejects documentation drift.

### 40. The client keeps only client state

Cursors, focus, modal state, and current tab live in `App`. Selections are IDs
or indices revalidated against fresh query results each frame. No copied game
entity survives across frames. A modal captures an ID; the command revalidates
it on confirmation.

### 41. All external text is untrusted

Player input, save content, mod data, filenames, database strings, child
process output, and environment values use a plain-text rendering path that:

- validates UTF-8 and replaces invalid sequences;
- replaces C0/C1 controls, ESC, DEL, newlines, and tabs with safe glyphs;
- never interprets markup;
- never writes uninitialized fallback bytes.

Only trusted presentation strings use markup parsing.

### 42. Escape sequences have one owner

Terminal escape sequences live in `term.zig` and image-protocol escapes in
`emblem.zig`. No query, screen, log string, or domain value emits raw terminal
control sequences.

### 43. Colors are semantic

Amber means attention, green means healthy, red means critical, cyan means
focus, and dim means chrome, on the terminal's existing background. Political
map colors use one mapping function.

### 44. User-visible persistence failures are never swallowed

Autosave, bankruptcy save, settings save, and explicit save failures are shown
truthfully. The UI never says “saved” after a caught persistence error and
keeps enough session state to retry or safely exit.

**Reviewer checks**

```sh
rg -n 'commands\.execute\(' src/tui
rg -n '\\x1b' src/tui --glob '!term.zig' --glob '!emblem.zig'
rg -n 'catch \{\}' src/tui src/main.zig
```

- Does every wide-only focus value map to a visible narrow pane after resize?
- Can an externally sourced string reach markup parsing?
- Can a failed save still produce a success message?

---

## 6. Persistence, schema, and integrity

### 45. Every state field has a persistence classification

Every `GameState` field is classified beside its declaration or in one
machine-checkable manifest as:

- **persisted:** serialized and restored exactly;
- **derived:** rebuilt from persisted owners and verified after load;
- **session-only:** cannot affect simulation outcomes;
- **scratch:** cannot survive an operation boundary.

Adding a field without a classification is a test failure.

### 46. Persistence covers gameplay state, not the current schema

Round-trip verification compares every gameplay-relevant `GameState` field,
including fields accidentally omitted from the store. Tests and digests are
not derived only from the list of fields persistence already writes.

RNG streams, statistics, reports, queues, typed references, and every
`next_*_id` counter are persisted gameplay state unless explicitly proven
derived.

### 47. Loading fails closed

A missing campaign, required row, parent entity, RNG stream, unknown enum,
invalid range, duplicate identity, malformed blob, or broken reference returns
`NoSuchCampaign`, `SaveNewerThanGame`, or `CorruptSave` as appropriate.

Loaders do not skip malformed rows, retain initialization defaults, silently
truncate, or use unchecked integer casts. Compatibility defaults exist only in
an explicit versioned migration.

### 48. IDs are validated globally

After load, each next-ID counter is greater than every owned ID and every
reference to that ID. Migration backfills inspect all owners and references,
handle overflow, and reject impossible maxima.

### 49. Saves are transactionally atomic in memory and storage

Database transactions and in-memory identity commit together. A new campaign
ID remains local until `COMMIT` succeeds. An update that affects no campaign
row is an error. A failed save leaves both the database and `GameState`
unchanged and can be retried safely.

### 50. Schema integrity is defense in depth

The loader validates every relationship, and the executable schema declares
foreign keys, unique keys, and checks where SQLite can enforce them. Foreign
keys are enabled on every connection before schema use. Existing tables gain
constraints through planned table-rebuild migrations; new tables do not defer
constraints merely because old ones lack them.

The runtime table registry is tested against executable DDL so campaign clear,
delete, and overwrite cannot omit a table.

### 51. Migrations are explicit and deterministic

Each migration names source and target versions, runs transactionally, and
defines deterministic defaults or reconstruction rules. It is idempotent when
guarded for partially upgraded historical stores and has a fixture test.

Unknown future store or campaign versions are refused before mutation.

### 52. RNG serialization is stable and named

RNG state is serialized per stable stream name with an explicit format
version, not as raw memory or one array blob. The campaign retains the seed or
another documented compatibility seed so newly introduced streams can be
initialized deterministically for old saves.

Adding an unused stream does not invalidate or reseed existing streams.

### 53. The integrity digest is canonical and complete

The digest covers every gameplay-relevant field, including fields not yet
persisted. Maps and unordered collections are hashed in canonical key order.
Pointer values, allocator layout, and incidental hash-map insertion order are
excluded.

A fixed seed and command script assert a pinned digest. Save, load, and
continued evolution preserve it.

**Reviewer checks**

- What persistence classification does each new state field have?
- Does a nonexistent campaign fail before assigning its ID?
- Does every database integer use a checked conversion?
- Can a missing RNG row or parent row silently retain a default?
- Does the digest change when each representative field changes?
- Can adding a stream load an old save without reseeding existing streams?

---

## 7. Data, money, time, randomness, and identity

### 54. Money and multipliers are integer quantities

Money is `types.CBills`; rule multipliers are basis points through
`types.applyBp`. Financial and rule math uses no floating point.

If `CBills` and `Bp` remain aliases of `i64`, semantic validation uses explicit
field metadata or field paths; reflection must not pretend aliases are nominal
types. Converting them to wrapper types is permitted when ergonomics remain
clear.

### 55. Time is campaign time

Simulation time is `day_index: u32`. Calendar rendering occurs only through
the date helper. Wall-clock time never affects simulation state.

### 56. IDs are typed and never inferred

Raw integers do not cross module boundaries as entity identity. Parsing turns
numbers into typed IDs at the boundary. Creation returns identity as required
by rule 16; display rows carry it as required by rule 32.

### 57. Random streams have stable salts

Each named stream has a permanent explicit salt or stable key. Enum ordinal is
not seed material. Reordering or adding enum fields does not alter an existing
stream.

The subsystem that initiates random behavior selects the stream and passes the
random source into lower-level generators. A shared generator does not
hard-code `.generation`, `.market`, or `.battle`.

All dice are 2d6 unless the cited source or design rule says otherwise.

### 58. Static data is validated during every build

Typed ZON parsing is necessary but not sufficient. Every normal build,
including `-Ddata`, performs semantic validation before producing an
executable.

Validation covers:

- required fallback and sentinel rows;
- stable-key uniqueness;
- cross-file references;
- nonempty weighted tables and positive total weight;
- sorted ranges, bands, and thresholds;
- min/max and capacity relationships;
- basis-point, probability, and monetary bounds;
- era availability and supported pool sizes.

Tests may add deeper coverage, but semantic validity is not test-only.

### 59. Rule data cites its source

Every rule table cites sourcebook edition and chapter/page when known. Derived,
abridged, invented, or play-feedback values are labeled accurately. Unknown
page references are not represented as sourcebook precision.

### 60. Skills follow MekHQ semantics

Lower skill values are better. Unit-kind and role-to-skill selection has one
owner and is reused by combat, escape, recovery, assignment, and views.

### 61. Every module names its counterpart

When a MekHQ counterpart exists, the module doc comment names it and links to
`docs/mekhq-map.md`. Reimplementation remains original code and respects the
repository's licensing rules.

**Reviewer checks**

- Does adding an unused RNG stream preserve pinned values for every old stream?
- Does a generator select a global stream internally rather than accepting one?
- Does `zig build -Ddata=<fixture>` reject semantically invalid data?
- Can reflection distinguish the quantity it claims to validate?

---

## 8. Resource and external-input safety

### 62. Acquire, guard, then proceed

Immediately after changing terminal mode, opening a database, beginning a
transaction, spawning a process, or acquiring another external resource,
install `errdefer` cleanup. Cleanup ownership transfers only when the returned
object is fully initialized.

### 63. Allocate before replacing

For resize, reload, buffer replacement, and configuration updates, allocate and
initialize the replacement first. Free or detach the old resource only after
the new one is ready. On error, the original object remains valid.

### 64. External binary formats are bounded and validated

PNG, database blobs, image payloads, and child-process output have practical
size limits before allocation. Parsers validate checksums and structure where
the format supplies them and require exact expected output sizes.

### 65. Platform support is explicit

The supported platforms are macOS, Linux and Windows. Terminal, resize
signalling, child-process, path and audio code has a target-gated
implementation for each; the build rejects any other target. POSIX process,
signal, path, and terminal assumptions are not compiled unconditionally for
targets that do not provide them.

### 66. Package contents are build truth

Every unconditional build input, runtime asset, license, and generated source
is included in `build.zig.zon` package paths. CI constructs a clean package
containing only declared paths and runs the build from it.

Large optional assets are not included in the package hash merely because
their parent data directory is included; they are distributed separately or
declared explicitly.

**Reviewer checks**

- If initialization fails after changing external state, what restores it?
- If replacement allocation fails, is the old buffer still owned exactly once?
- Can an input request an allocation inappropriate for its purpose?
- Does a clean package build have every path referenced by `build.zig`?

---

## 9. Tests and executable verification

### 67. Every rule module carries focused tests

Every public rule function has an in-file test. The test asserts the owning
rule and at least one consumer agree, not merely that each returns a value.
Frontend modules test row identity, key dispatch, empty states, narrow layout,
and cursor/focus clamping where applicable.

### 68. Bug fixes begin with the regression

A bug fix first adds a test reproducing the failure in the owning module. The
test must fail for the reported reason before the implementation changes.

### 69. Atomicity is tested at failure boundaries

Every distinct compound-mutation pattern has a representative failing-allocator
or injected-failure test. The test captures the complete gameplay digest,
forces failure after preparation or during the formerly unsafe boundary, and
asserts exact state equality.

The requirement is one test per distinct pattern, not one per command.
Patterns include:

- debit plus asset creation;
- batch stock consumption plus queue insertion;
- removal from a roster plus transfer creation;
- event selection plus its effects;
- database transaction plus in-memory ID assignment.

A caller shares a helper's test only when it delegates the entire mutation to
that helper.

### 70. Persistence tests are adversarial

Persistence tests cover:

- first-save failure and retry;
- nonexistent campaign IDs;
- missing and malformed required rows;
- negative and overflowing database integers;
- unknown enum values and missing parents;
- every next-ID counter;
- RNG format upgrades and newly added streams;
- save, load, and continued deterministic evolution.

### 71. Locality tests are asymmetric

Medical, training, recruitment, recovery, market, intelligence, and freight
tests use at least two sites with unequal facilities and staff. Symmetric
fixtures cannot prove locality.

### 72. The gate is complete

The required gate is:

```sh
zig fmt --check build.zig src
zig build test --summary all
python3 docs/tui_smoke.py zig-out/bin/game /tmp/x.db
bash docs/repl_smoke.sh zig-out/bin/game /tmp/r.db
./docs/verify-contract.sh
```

Changes under `src/tui`, `src/sim/cli.zig`, `src/sim/queries.zig`, or
`src/main.zig` require both smoke scripts. CI installs ripgrep explicitly
rather than assuming it, and additionally performs a clean package build and
a compile for every supported platform (rule 65).

### 73. Contract checks are recursive and executable

`docs/verify-contract.sh` owns layer, impurity, frontend-boundary, direct
command-execution, escape-sequence, module-registry, and duplicated-pattern
checks. It recursively scans subdirectories and carries narrow documented
allowlists. Reviewer snippets in this document do not replace it.

### 74. Module reachability is checked

Every Zig source file belongs to a production or test import graph. CI compares
the source tree to the module registry or another explicit reachability list.
`refAllDecls` is used where useful, while the production executable itself is
built to catch lazily analyzed frontend code.

**Reviewer checks**

- Which test fails if the changed rule is duplicated?
- Which test fails if an allocation occurs one step later?
- Does the locality fixture contain two unequal sites?
- Does a new source file appear in the reachability check?
- Do the smokes exercise every new textual verb and its refusal path?

---

## 10. Style and maintainability

### 75. Legible over clever

Formulas read like the rulebook line they implement. Comments explain the rule,
source, invariant, or non-obvious tradeoff, not syntax.

### 76. Functions and modules have review thresholds

A function over approximately 100 lines, a switch with more than ten
substantive arms, or a module over 1,000 lines requires one of:

- decomposition in the same change; or
- a documented temporary exception with owner, reason, and removal
  deliverable.

Facades may remain centralized, but they dispatch to subsystem-owned functions
rather than implementing every subsystem inline.

### 77. State owns storage, subsystems own behavior

`GameState` owns campaign storage and primitive invariant-preserving access.
Pricing, medical policy, battle assembly, staffing, market refresh, hashing,
and similar subsystem behavior live in their owning modules rather than
accumulating as unrelated `GameState` methods.

### 78. Temporary memory is actually temporary

Persistent objects allocate from the campaign arena. Per-command, per-query,
and per-tick work allocates from reclaimable scratch memory owned by that
operation. Calling `deinit` on memory allocated from a long-lived arena is not
treated as reclamation.

### 79. Errors preserve meaning

Expected player refusals are typed command errors. Corruption, allocation,
database, and invariant failures remain distinguishable and propagate to the
application boundary. Broad `catch {}`, `catch false`, and `catch ""` are
prohibited outside best-effort cleanup.

### 80. No dead mirrors

A comment saying “mirrors”, “same as”, “equivalent to”, or “keep in sync” is a
defect report. Replace the copied implementation with a call, generated data,
or a test that compares an external document to the single code source.

### 81. Names describe rules and units

Modules and functions are named for the entity or rule, not the screen that
first needed them. Quantities include units and accounting windows when
ambiguity is possible.

### 82. Comments explain present truth

Code comments explain present invariants, hazards, interfaces, or durable
compatibility facts. They never record conversations, authorship, development
history, roadmap chronology, review findings, or work status. Git and planning
documents remember how the code arrived; comments explain why the code must
remain correct.

A comment answers at least one of:

- What invariant must remain true?
- Why is this implementation non-obvious?
- What external rule, protocol, or sourcebook requirement governs it?
- What ownership, lifetime, concurrency, or failure constraint is easy to
  violate?
- What compatibility behavior must remain for persisted or external data?

Comments are written in the present tense about the current code. If deleting
a comment would not make the current implementation harder to understand
safely, it is omitted.

- **Doc comments state contracts.** A public declaration's doc comment states
  what callers can rely on: inputs and units, returned meaning, mutation and
  ownership, failure behavior, determinism and RNG use, relevant invariants,
  and the governing source. It does not narrate implementation steps.
- **Inline comments explain hazards, not syntax.** `// Loop over the units.`
  is rejected; `// Iterate in stable ID order because RNG consumption is part
  of replay state.` is accepted.
- **Tests follow the same rules.** A test comment explains the invariant or
  the fixture's shape. A test name describes behavior, such as `"battle report
  IDs remain unique after save and load"`, never a roadmap stage or a fix.
- **Comments change with the code.** A change that invalidates a nearby
  comment updates or removes it in the same PR; a stale comment is a
  correctness defect. When a refactor makes code self-explanatory, the comment
  is deleted rather than rewritten.

```zig
// Rejected:
// 12G.6: This used to lose the battle ID, so now we save it here.
// Play feedback said a week was too short.

// Accepted:
// A pending recovery decision must retain its battle ID across save/load.
// The cooldown prevents the same weekly decision from recurring back-to-back.
```

### 83. Comments hold no history, conversation, or work status

Source comments, test comments, and test names do not contain:

- conversation summaries or quotations, or references to prompts, users,
  developers, reviewers, agents, or language models;
- attribution such as "we decided", "the user asked", or "feedback said";
- previous behavior or change language: "used to", "now", "formerly",
  "changed from", "after the fix", or when a field, case, or column was added;
- audit findings, review discussions, PR narratives, commit history, or dates
  describing when a decision was made;
- rejected alternatives, unless the alternative remains an immediate and
  plausible maintenance hazard;
- work status: "not implemented yet", "will be fixed later", or "temporary"
  without a tracked removal condition;
- operational metadata: names, assignments, review status, priority,
  deadlines, branch names, commit IDs, test-run status, or drifting
  measurements such as line counts;
- credentials, tokens, keys, internal URLs, personal information, proprietary
  conversation content, machine-specific paths, local environment details, or
  diagnostic output.

**Compatibility boundaries are the only place for history.** Database
migrations, save-format upgrades, protocol versions, legacy data import,
platform or ABI compatibility, and workarounds for a specific external
implementation may describe old representations. Such a comment states the
exact version boundary, the old representation that can still arrive, the
deterministic transformation, and, when applicable, the condition for removing
the path. Schema versions are durable data facts; roadmap stages and
development dates are not.

```zig
// Allowed: Saves before schema v31 have no salvage remainder. Reconstruct it
// from the unresolved report so loading preserves the original allocation total.
```

**TODO, FIXME, HACK, and XXX are prohibited.** Open work lives in `TODO.md`. A
comment may carry a stable tracker reference only when the current
implementation is intentionally incomplete but still correct, for example
`// Tracked by TODO.md D22: split table decoding without changing row
semantics.` Removing the tracker item removes the comment in the same change. A
TODO comment never excuses incorrect behavior. `// TUNE` (rule 24) is not a
TODO; it marks a placeholder value and names the data that would settle it.

### 84. Citations name durable authorities

Comments cite durable authorities: `ARCHITECTURE.md` headings, coding-contract
rules, sourcebook edition with page or chapter, protocol and technical
specifications (SQLite, POSIX, PNG), the MekHQ counterpart (rule 61), or a
durable decision record. A named rule or heading is preferred over a line
number. Comments never cite chat transcripts, private messages, prompt text,
branch names, a commit hash as the only explanation, or issue or PR discussion
as the only source of a permanent rule. A discussion that produced a lasting
decision is recorded in the owning document, and code cites that document.

Relationships are named precisely. "Mirrors" is ambiguous (rule 80); use
`//! MekHQ counterpart: personnel/Person.java.`, `//! Adaptation: companies
are independently deployable.`, or `/// CamOps, p. 42: lower gunnery is
better.` A source citation never excuses duplicated code.

Roadmap stage identifiers (`Stage 12`, `12G.6`) belong in `ROADMAP.md`, the
work tracker, and release notes. A module's top-of-file `//!` doc comment may
name the stage whose design it implements; no other comment or test name
carries one.

**Reviewer checks**

```sh
# Canonical versions live in docs/verify-contract.sh, which fails on new
# occurrences against a recorded baseline. Allowlists: migration comments
# naming schema versions, //! MekHQ counterpart and stage headers, and literal
# test data.
rg -n -i '//.*\b(play feedback|user asked|we decided|previously|used to|formerly|after the audit|after review|conversation|LLM|Claude|ChatGPT)\b' src
rg -n '^\s*//[/ ].*\b(Stage [0-9]|1[0-9][A-G]?\.[0-9])' src
rg -n '\b(TODO|FIXME|HACK|XXX)\b' src
rg -n '^test "[0-9]' src
```

- Does every new comment describe present behavior or a durable compatibility
  boundary?
- Does any comment reference a conversation, developer, language model, audit,
  PR narrative, roadmap stage, or previous implementation?
- Could the explanation move to `ARCHITECTURE.md`, the contract, or the work
  tracker?
- Does a migration comment name a real schema or version boundary rather than a
  development milestone?
- Does every public doc comment describe caller-visible behavior?
- Did changed code make a nearby comment stale, or can a comment be deleted
  because naming now makes the code self-explanatory?
- Did a facade grow new subsystem logic instead of one dispatch arm?
- Does temporary work allocate from the campaign arena?
- Does a catch collapse a system failure into plausible gameplay output?
- Does a name hide units, time window, or locality?

---

## 11. Pull requests and delivery

### 85. One branch in flight at a time

A change lands on `main` before the next starts. Branches are sequential,
never stacked. A branch is complete only when its PR is merged, the branch is
deleted locally and remotely, and local `main` is pulled.

- A pushed branch always has a PR.
- The gate runs on the branch exactly as reviewed.
- No file is borrowed from another branch to make verification pass.
- Large work is split into independently correct increments that each land.

### 86. Deliverables are cohesive

A deliverable has one primary invariant or subsystem outcome. Package fixes,
schema migrations, frontend tests, and major module decompositions do not
share a PR merely because they came from the same audit. Structural moves land
after behavior fixes that rely on existing line ownership, unless the move is
required to make the behavior fix safe.

### 87. Exceptions are explicit debt

An exception to this contract names:

- the exact rule;
- the concrete reason compliance is not yet practical;
- the bounded scope;
- the owner and removal deliverable;
- the test or check preventing the exception from expanding.

“Existing pattern”, “arena-backed”, and “unlikely OOM” are not exceptions.
Limited reach, such as a path only the REPL exercises, may lower remediation
priority, but it does not waive an invariant; a temporary exception is still
documented and bounded as above.

### Pull request checklist

Every PR answers:

1. Which rule functions changed, and how many files changed for each?
2. What is the first mutation in each changed compound operation, and how is
   failure atomicity guaranteed after it?
3. Which allocations and container capacities are prepared before commit?
4. Does any new or changed state field have a persistence classification,
   digest coverage, migration behavior, and next-ID impact?
5. Is every site-sensitive rule passed an explicit site, and which asymmetric
   test proves locality?
6. Is every capability predicate complete for status, location, crew, and
   supplies?
7. Does every created entity return its typed identity directly?
8. Does every actionable display line carry typed identity without parsing or
   row counting?
9. Does every new command have one verb branch, usage, error sentence, and
   smoke step?
10. Is every new number declared once with units, accounting window, and
    source?
11. Can every new external string reach only validated plain-text rendering?
12. Do new and edited comments state present truth only, with no history,
    conversation, work status, or roadmap chronology, and cite durable
    authorities (rules 82–84)?
13. Which regression test fails on the old behavior?
14. Which test proves refusal or injected failure leaves state unchanged?
15. Are the full gate, both smokes when required, contract script, clean
    package build, and relevant target builds green?

### Reviewer checks

```sh
gh pr list --state open
git branch -a
git log --oneline origin/main..HEAD
```

- Is more than one branch in flight?
- Does this change combine unrelated audit deliverables?
- Does a claimed exception satisfy rule 87?
- Is the reviewed commit exactly the commit that passed the gate?
