# Engineering response to the structural and architecture audit

Date: 2026-09-24 · Responds to: `docs/audit.md` (same date) · Checked at: `6be5310`

Thank you for the review. We checked every finding against the code at
`6be5310`, including the callers, the guards, the allocator and the design
documents each one depends on. Where the audit makes a claim about behaviour,
we traced the path end to end, and we reproduced the build findings (A14, A29)
with real builds. Line numbers below are current ones. Most still match the
audit's.

**Summary.** No finding is wrong outright. One is already fixed, and two
critical findings are overstated.

| Verdict | Count | Findings |
|---|---|---|
| Accepted | 15 | A5, A10, A12, A18, A19, A20, A23, A24, A25, A26, A27, A29, A30, A32, A33 |
| Accepted, already scheduled | 1 | A35 |
| Accepted with correction | 20 | A1, A2, A3, A4, A6, A7, A8, A9, A11, A13, A14, A15, A16, A17, A21, A22, A28, A31, A34, A37 |
| Already fixed | 1 | A36 (`f1d6887`, PR #101) |

Where we disagree, it is mostly about severity or scope, not about whether
there is a defect:

- **A1 and A2 are not memory corruption today.** `GameState` lives in an
  `ArenaAllocator`, which frees only its most recent allocation. A growing
  list allocates its new buffer before it frees the old one, so the old buffer
  is never reclaimed, and a stale pointer reads an intact copy from before the
  change. A1 does have a visible defect, a mislabelled persisted log line, but
  it comes from a different mechanism than the one the audit names.
- **A3 is reachable only through `OutOfMemory`**, except for one ordinary-error
  claim that no production caller can reach.
- **A4's fix as written would reject valid saves.** Historical records
  legitimately point at entities that no longer exist.
- **A17's impact is mostly wrong.** Because of the band width, the fixed
  30 LY is in effect a rounding rule.

The verification also found defects the audit missed, several of them worse
than the finding they sit next to:

- The TUI `:day` skips the end-turn checklist entirely (A9).
- The TUI order form tells the player an order succeeded when sourcing failed
  (A11).
- A capacity-capped supply link can refuse a shipment that an unlinked,
  uncapped charter would have carried (A15).
- A mod with a truncated rank table passes the build and is undefined
  behaviour in ReleaseFast (A14).
- Several `catch` sites report `OutOfMemory` as an unrelated error after money
  has moved (A3).
- Our own v5 migration fixture loads with a live ID collision (A6).

Each correction is set out below, and the missed defects are listed with the
finding they belong to.

Our design documents also overstate the code in four places the audit touches.
These corrections ship with the matching fixes:

- `ARCHITECTURE.md` §4 says every command reserves ledger and list slots
  before its first mutation. Four do.
- `ARCHITECTURE.md` §12 says nothing on load is skipped or defaulted. Three
  loaders skip rows.
- `docs/tui.md` calls several checklist warnings "blocking". Only insolvency
  and the battle holds are enforced.
- `ARCHITECTURE.md` §9.3 counts storage by truck tonnage but does not say
  which trucks count.

Verdicts: **Accepted**: the finding stands as written. **Accepted with
correction**: the defect is real, but part of the finding is not, and we say
which part. **Already fixed**: the code at `6be5310` no longer has the defect.

Every accepted item is assigned to a deliverable, **D23–D34**, listed in
[Delivery plan](#delivery-plan) at the end.

---

## Critical findings

### A1. Decision resolution retains pointers into the event list: Accepted with correction → D23

**The defect is real. The failure mode is a different one, and the severity
is High, not Critical.**

`resolveChoice` holds `ev = event_queue.find(id)`, a pointer into an
`ArrayListUnmanaged` (`src/sim/contract_events.zig:342`), and dereferences it
after `applyEffectsFor` for the log line (`:355`). Three effects change the
list while `ev` is held:

- `.engagement` appends events through `battle.resolveEngagement`.
- `.recovery_push` removes rows through `walkOut` (`:640-648`).
- `.exchange_mia` removes rows (`:510-511`).

Three corrections:

1. **"`orderedRemove` may delete an unrelated decision" does not hold for
   `resolveChoice`.** It finds the event again by ID before removing it
   (`:358`, `indexOf(event_id)`).
2. **The visible failure is a shift, not a reallocation.** After a lost field,
   the queue holds `[mia_held…, recovery_push, field_repair]`, because
   `recoverWrecks` queues the missing pilots before
   `battle.zig:1049-1057` queues the push. Answer the push with "Go back" and
   have a pilot walk out: `walkOut` removes an earlier `mia_held` row, and `ev`
   now points at the next event. The persisted log then records, for example,
   `[decision] field_repair: chose "Worst-hit first"`, under the wrong
   event's company and contract. This is reachable in ordinary play.
3. **The reallocation case is latent.** Under the campaign arena, a dangling
   `ev` reads an intact old copy (see the summary), and `chosen` is written
   before the effects run, so that copy is correct. It becomes a
   use-after-free only if the backing allocator changes. We fix it anyway.

**`expireDue` is hazardous but cannot trigger today.** It removes by the stale
index `i` (`:371`), which would delete the wrong row. But no `default_choice`
in any deck currently reaches an effect that changes `pending`. We checked all
ten decision kinds.

**Atomicity: confirmed, and only `OutOfMemory` can trigger it.** `chosen` and
the standing-order memory are committed before the effects run
(`:346-353`). No effect path returns an error other than an allocation
failure. If one does fail, the event is left in an odd state: it is marked
answered, it cannot be answered again or expire, and it no longer holds the
turn.

**Fix (D23):**

- Copy the event's kind, company, contract, option label and effects into
  locals before any effect runs.
- `expireDue` keeps the ID and finds the row again after the effects.
- `chosen` and the standing-order memory are written after the effects.
  Capacity is already reserved at `:345`.
- Regression tests: the recovery-push/walk-out case asserts the log line; an
  effect that appends; an effect that removes an earlier row.

The prepare/commit shape and the failure-injection tests the audit asks for
belong to the scheduled failure-atomicity item (see A3).

**Missed:** `queueDecision` holds `mem.value_ptr` across `applyEffects`
(`:266-271`). It is not dereferenced afterwards, so it is safe, but fragile.
It is fixed in the same pass.

### A2. Battle resolution retains a person pointer across insertion: Accepted with correction → D23

**The rule violation is real. There is no invalid read today, and the severity
is Medium (latent), not Critical.**

`Opening.edge_used_by` is a `?*Person` (`src/sim/battle.zig:657-665`, `:726`).
It is held across `takePrisoners`, which inserts into `people` through
`hireFromSpec` (`:818-835`). It is dereferenced once, at `:992`, for
`rankedName`. Under the arena, the old entries buffer stays intact. Nothing
in the engagement changes rank or name after the opening, so the after-action
report names the right pilot. It would stop doing so under any other
allocator.

**Fix (D23):** store the `PersonId` and look it up again at `:992`. This is
the rule the audit states: persistent values hold IDs, not pointers into
growable collections. We found no other retained pointer of this kind in
`resolveEngagement`.

---

## High-severity findings

### A3. Compound state mutations are not failure-atomic: Accepted with correction → D24 and the failure-atomicity item

**Every site except one is real, but only on allocation failure.** Under the
campaign arena, that means the process is out of memory. The ordinary-error
claim does not hold:

| Site | Verdict |
|---|---|
| `transferFunds` (`state.zig:378-398`) | Real on OOM: a failed credit or courier append after the debit loses money. No caller reserves anything. |
| `runPolicies` swallowing errors (`tick.zig:81`) | Real, narrower than stated. `catch continue` is meant for `InsufficientTreasury`, which fails before any change. It also swallows OOM after the debit. |
| `createForce` (`state.zig:1363-1374`) | Real on OOM: an orphaned child, and a gap in the ID sequence. |
| `assignUnit` → `UnknownPerson` (`state.zig:1384-1394`) | The ordering is as described, but the only production caller, `starter_company.generateInto`, always passes a person it has just created. **Not reachable outside tests.** It will validate first anyway. |
| `moveUnitToForce`, `placeUnitInCompany` (`state.zig:1676-1752`) | Real on OOM. |
| `holdUnit`, `releaseHull` (`state.zig:1936-1967`) | Real on OOM. `holdUnit` runs in a loop (`battle.zig:1037`), so a failure also leaves the loop partly done. |

**Missed, and not OOM-only in effect:**

- `commands.zig:971` and `:1196` call `placeUnitInCompany(...)` and
  `moveUnitToForce(...)` with `catch return Error.UnknownForce`, after the
  purchase has been debited, the listing removed and the unit added. The
  player is told the company does not exist, and the money is already gone.
- `commands.zig:772` swallows a `shipStock` failure with `catch continue`,
  after freight is paid and stock is taken. This is the `runPolicies` pattern
  again.

**On the recommended design.** We agree with the four mutation patterns the
audit lists (validate → reserve → commit; quote → reserve → debit → commit;
prepare log and ledger lines first; stage RNG). We will meet them with
reserve-first helpers and **one failure-injection test per mutation
pattern**, using `std.testing.FailingAllocator` behind the campaign arena and
comparing `GameState.hash()` before and after. We are not building a
transaction or undo framework: a management sim with an arena-owned state tree
does not need one, and the reserve-first pattern is sufficient.

**Fix:**

- **D24** (now, small). It stops a failure from being hidden or
  mislabelled; it does not restore integrity after an allocation failure.
  That comes only with the failure-atomicity item below.
  - The `runPolicies` catch propagates everything except
    `InsufficientTreasury`, the pattern already used at `state.zig:568-573`.
  - The `shipStock` catch does the same.
  - The three mislabelled catches propagate the real error.
- **Failure atomicity** (the item already scheduled in `TODO.md`, now ordered
  earlier):
  - Reserve-first versions of the eight sites above.
  - A1's prepare/commit.
  - The failure-injection tests.
  - `ARCHITECTURE.md` §4 corrected to describe what is actually reserved.

### A4. The save loader silently drops malformed relational rows: Accepted with correction → D28

**All four cited sites are real, and nothing later in the load catches
them:**

- the orphan `unit_slot` (`store.zig:1216-1221`)
- the unchecked `force_unit` and `force_child` targets (`:1262-1270`)
- stock for a missing site, through `addStock`'s `orelse return`
  (`state.zig:1092-1093`)
- the orphan `refit_op` (`:1817`)

`ARCHITECTURE.md` §12 claims the opposite.

**The correction is to the fix.** "Validate both ends of every nonzero
reference", applied to transactions, events and battle reports, would reject
valid saves. Units, HQs and companies really are removed during play
(`removeUnit`, `commands.zig:1439`, `:1478`), so history can legitimately point
at entities that no longer exist:

- `txn.company` and `txn.hq`
- `event_log` tags
- `battle_report_hit.unit` and `.pilot`
- the assigned company of a finished contract

The integrity pass must therefore separate the two kinds of reference:

- **Live references must resolve:**
  - unit force, pilot, tech and berth
  - person assignment and posting
  - force parent, children, units, commander and supplying HQ
  - bay jobs, refit plans, transfers, supply and stock policies, links
  - courier and policy treasuries, part-order destinations
  - pending-event contract, person and battle
- **Historical references may dangle:** everything else.

**Missed (same class):**

- **Duplicate keys overwrite silently:** `contracts.put` (the `contract` table
  has no primary key), `person_skill`, `faction_standing` and `event_memory`.
  Duplicate nonzero `pending_event` IDs are accepted, which makes
  `resolveChoice` ambiguous.
- **Duplicate stock rows are summed as `u32`**, which panics in safe builds and
  wraps in ReleaseFast.
- **`sqlite.int()` reads NULL as 0**, so a NULL `unit.force` loads as `.none`.
- **`loadMeta` defaults missing** `funds`, `day_index` and date rows.

**Fix (D28):**

- A strict stock loader instead of `addStock`.
- Both ends checked for every live reference, with duplicate-key and NULL
  checks.
- A post-decode graph pass driven by an explicit **reference-policy table**
  (added after the auditors' reply). Every reference column is listed in
  it with one class, and the graph pass and the tests read the table
  rather than comments in each loader:
  - **Required live**: must resolve to a loaded entity (a unit's force, a
    bay job's hull).
  - **Optional live**: none, or it resolves (a unit's pilot, a force's
    commander).
  - **Historical**: may point at a removed entity (ledger and log tags,
    battle-report hits).
  - **Derived**: rebuilt after load and never trusted from the row (an
    HQ's `staff_assigned`, recomputed by `refreshHqStaffing`).
  - **Sentinel-capable**: a documented sentinel such as `.none` or the
    outfit treasury is valid, and anything else must resolve (courier and
    policy treasuries, stock owners, order destinations).
- One corruption test per relationship family.

### A5. Unknown discriminators become valid data: Accepted → D28

**Confirmed:**

- The listing kind (`store.zig:1568`) and the refit-op kind (`:1819-1826`)
  default to a valid variant.
- Every boolean is decoded as `!= 0`, at `store.zig:1040-1041`, `1112`,
  `1114`, `1120`, `1167-1168`, `1347`, `1362`, `1378`, `1573`, `1577`,
  `1685-1694`, `1729-1730`, `1752`, `1760`, `1765` and `1810`.

**Missed:** optional enums that decode an unknown value as null:

- `force.support_kind` (`:1248`)
- `hq_project.facility` (`:1306`)
- `person.training_skill` (`:1128-1129`); an unknown skill silently drops the
  training.
- `battle_report.command_rights`, stored as free text.

**Fix:**

- **D28**: exhaustive discriminator parsers, `bool01`, and bounded decoders
  for percentages, morale, fatigue and facility levels, as named in the audit.
- **The foreign-key migration item**: the matching `CHECK` constraints.

### A6. Missing or stale next-ID counters can overwrite entities: Accepted with correction → D28

**Confirmed, and our own test suite already shows it.** The v5 migration
fixture (`store.zig:2250-2256`) loads person 1 and unit 1 with no counter
rows. The loaded state has `next_person_id == 1`, a live collision the test
never notices.

**The correction:** the historical-schema branch is not needed for these five
counters:

- `saveMeta` has always written all seven (`store.zig:430-434`), and so did the
  first commit.
- Only `next_battle_id` and `next_event_id` were added later, and both are
  already rebuilt on load.

The fix is therefore just to require every row and to require each counter to
be greater than the highest ID loaded. The fixture gets its counter rows.

**Missed:**

- A stored counter of 0 hands out `.none`.
- A counter of `maxInt(u32)` overflows on the next `+= 1`.
- The unit namespace must include held-hull IDs as well as live units.

**Fix (D28):** one counter manifest, used by save, load and the tests, as the
audit recommends.

### A7. Pending-event choice indices are not validated on load: Accepted with correction → D28

**Confirmed:**

- `default_choice` and `chosen` are range-checked only against the width of
  their storage type (`store.zig:1642-1644`).
- `expireDue` indexes `options[default_choice]` unchecked
  (`contract_events.zig:367`). That is a panic in safe builds and undefined
  behaviour in ReleaseFast.

Two corrections:

- **"Require `options.len > 0`" is too strict.** An event kind with no options
  is a notice, not a decision (`needsDecision`, `events.zig:173`), and nothing
  indexes its options.
- **A non-null `chosen` can never appear in a genuine save.**
  `resolveChoice` removes the event right after setting it. So any stored
  `chosen` is corruption. It does not make an answered event apply an invalid
  choice; the event stays in the queue, unanswerable.

**Fix (D28):**

- On load: `default_choice < options.len` whenever the kind is a decision, and
  `chosen` must be null.
- References are validated as live references under A4.

### A8. "Not deployed" is used as "home": Accepted with correction → D26

**The core claim holds, and it is an exploit that undercuts the rotation
design.**

`companyPosture` has five states, and `isCompanyDeployed`'s own doc comment
says it is "not the opposite of home". Both of the in-between states occur
routinely, with people and hulls aboard:

- `finishTour` leaves every company `idle_afield` at the end of a tour.
- `recall` sets `returning`.

Yet the following treat any company without a contract as home:

- `careFor` (`medical.zig:106-110`)
- weekly rest (`:353-381`)
- the rotation reset (`:388-401`)

A company idling on a contract world therefore gets:

- full hospital care, without a MASH truck
- home rest, **better** than a garrison company receives
- a free rotation reset, without coming home

`ARCHITECTURE.md` §9.7 ("decays only at home") and `GAMEPLAY.md` ("pay the
transit … to rotate home") say otherwise.

Three corrections:

1. **Transfers from an idle-afield company are designed** to ship with travel
   time. The **returning** case is the bug: `sitePlanetKey` falls back to the
   home planet (`commands.zig:1917-1920`), so a person or hull transfers off a
   DropShip in flight with zero travel days.
2. **The rotation reset follows the literal wording of `ARCHITECTURE.md:568`**
   ("sat undeployed"). That sentence is ours to fix. It contradicts §9.7.
3. **Some commands are already correct.** `sell` and `mothball` are wrong, but
   `depot`, `strip`, `refit`, `disband` and `move_unit` already require
   `isCompanyHome`, and they are the pattern the rest will follow.

**Missed:**

- `train` and `train_ability` check "not deployed" while `trainCompany`
  requires home: two eligibility rules for one action.
- `leave` is allowed afield, and doubles the home rest rate.
- `crew_company` hires from the halls straight into an afield company.
- Maintenance skips the deployed penalty for afield hulls
  (`maintenance.zig:113`).
- The checklist's wounded-at-home count uses `isCompanyHome` while the sim
  uses "not deployed", so the screen and the sim disagree.

**Fix (D26):**

- Named posture predicates owned by their subsystems (`careForPosture`,
  `restsAtHome`, `canActAtHq`), each switching exhaustively over
  `CompanyPosture`, as the audit recommends.
- A posture × rule matrix test.
- This is a deliberate balance change: idling afield loses its free benefits.

### A9. Malformed TUI `day` input advances the campaign: Accepted with correction → D25

**Confirmed, and worse than stated.**

- `app.zig:3784-3787` reads `parseInt(...) catch 1` and ignores trailing
  tokens.
- It also calls `advance` directly, so **`:day` never opens the end-turn
  checklist**, even for one day.
- There is no upper bound: `:day 100000` runs until a hold stops it.

**The REPL is lenient too, in a different way.** `n = parseInt(...) catch n`
keeps the last good count (`main.zig:703-723`), so `day 3 junk` advances 3
days. `day` is parsed by hand in both frontends, and they differ.

**Fix (D25):**

- One strict `cli.parseDay`: a count with a range and an optional `force`,
  with nothing trailing. Both frontends use it.
- The TUI `:day` goes through `endTurnRequest`.
- `:save`, `:quit` and `:manning` refuse trailing words.
- We will take the audit's application-level action union for frontend verbs
  if it stays small. Otherwise one parser per verb in `cli.zig` meets the same
  rule.

### A10. The seven-day advance bypasses the checklist: Accepted → D25

**Confirmed.**

- `endTurnRequest` opens the modal only when `days == 1`
  (`app.zig:2443-2452`).
- The REPL gates `day 7` unless `force` is given, so the two frontends differ.

**Missed:** "blocking" is not enforced anywhere. `advance` refuses only for:

- an unread after-action
- a pending battle decision
- insolvency
- bankruptcy

The other seven blocking kinds are display-only: the `!` mark and "turn ready:
NO". `WarningKind.blocking`'s doc comment and `docs/tui.md` both overstate
this.

**Fix (D25):**

- Every advance length opens the checklist; the modal already offers the
  week.
- We will decide whether blocking warnings should refuse an unforced advance,
  or whether the docs should call them advisory, and make the docs and the
  code agree either way.

---

## Medium-severity findings

### A11. Typed TUI commands discard their results: Accepted with correction → D27

**Confirmed, and wider than stated.** `app.zig:3831-3838` always says
`done: <verb>`.

The TUI **amount forms** (order, ship, sell, loan, transfer, policies) also
build a command line and run it through the same path (`app.zig:2261-2281`).
So the main order form says "done: order" when `order_part` returned
`.sourced = false` (`commands.zig:2191-2204`). This is a keyed path, not only a
typed one.

**The correction:** the hull-fraud example does not reach typed input.

- `buy_hull_for` has no verb in `cli.zig`.
- A black-market fraud through `buy_listing` returns `{}`, and the REPL prints
  a generic "done." for it. So the REPL hides the fraud too.

**Missed:** the Market screen's buy key says "bought listing [n]" on a fraud
(`screens/market.zig:79-81`).

**Fix (D27):**

- One result presenter, `Command` + `Result` → sentence, below the frontends.
  Both frontends and the amount forms use it.
- `buy_listing`'s `Result` reports fraud.

### A12. `stockpolicy` explicit zero becomes a positive target: Accepted → D25

**Confirmed.**

- `cli.zig:162-163` turns an omitted target and an explicit `0` into the same
  value, then doubles `min`.
- The TUI "KEEP … STOCKED" form builds exactly this command line, so a target
  of 0 with any minimum above 0 gives min×2, the opposite of what the usage
  line promises.

**Fix (D25):**

- Keep track of whether the target was given.
- Parser tests for an omitted target, an explicit zero and a positive target.

### A13. Frontend prevalidation duplicates command rules: Accepted with correction → D30

**Confirmed for prevalidation.** Six sites suppress the command and show query
text instead. The audit cites three of them. The other three:

- the HQ upgrade (`app.zig:3180-3183`)
- the Lab install location (`:3196-3199`)
- fabricate (`screens/market.zig:127-130`)

Two of the six carry hand-written rule sentences.

**The correction:** `execResultWith` is not prevalidation. It always runs the
command, and rewords only named errors after a refusal. It is still a second
source of refusal sentences, which proposed rule 10 forbids, so we accept that
half. The "already scheduled" note is out of date: the `execResult` item
landed as `execResultWith` in PR #99.

**Fix (D30):**

- Eligibility only dims or annotates a row; activation always submits the
  command.
- The four caller-worded sentences move into `cli.errorText`. We add error
  variants where a sentence needs context.

### A14. Data-overlay validation omits runtime preconditions: Accepted with correction → D32

**The rank half is confirmed by experiment.**

- A `ranks.zon` with 7 rows passes `zig build validate-data -Ddata=…` and a
  full `zig build -Ddata=…`.
- `promote <id> major` then indexes out of bounds: a panic in Debug, and
  **undefined behaviour in the documented ReleaseFast build**.
- A reordered ladder builds and silently mispays ranks.
- The Mek legality test and the skulls band test also lack the `data:` prefix.

**The empty-pool half is wrong for a full build.** An empty `first`, `last` or
`callsigns` list fails `zig build -Ddata=` at compile time, because Zig refuses
to index a comptime-known empty slice (`person_gen.zig:76:29`). It passes only
the standalone `validate-data` step, which never compiles the executable, and
then fails with a raw compiler message rather than a data diagnostic.

**Fix (D32):**

- Named validation functions for rank cardinality and order, non-empty pools,
  positive weights and canonical legality, run by the validation step.
- One invalid-overlay fixture per family in CI.

### A15. Route selection ignores capacity and quality: Accepted with correction → D29

**Confirmed that capacity and quality play no part in choosing the path.**
`routeBetween` is a breadth-first search on hop count (`network.zig:63-144`).
A saturated hop refuses the shipment (`freightQuote`, `commands.zig:2006-2008`)
without trying another path, and players can link any pair of HQs, so
alternative paths exist.

**The correction:** equal-hop ties are fully deterministic. `hq_links` is saved
and loaded `ORDER BY ord` (`store.zig:706-708`, `:1502-1506`). What is missing
is a documented policy, not determinism.

**Missed, and sharper:** with no link at all, the fallback charter hop has no
cap (`network.zig:104-109`, `:154-161`). So buying a link can make a shipment
fail that an unlinked charter would have carried.

**Fix (D29):**

- A quote that takes the tonnage, skips hops without room, and minimises
  days, then cost, then HQ ID.
- The command commits exactly the quoted path, as the audit recommends.
- The charter becomes an explicit, capped fallback.
- `ARCHITECTURE.md` §9.5 gains the routing policy.

### A16. Support capacity bypasses the operational rule: Accepted with correction → D29

**Salvage is confirmed.** `salvageTrucks` (`battle.zig:24-33`) counts every
non-destroyed truck. `ARCHITECTURE.md` §9.3 names post-battle salvage yield as
a support modifier, and support modifiers count by `unitOperational`.

**Storage is the correction.**

- The design never makes field storage depend on crew fitness. A wounded
  driver should not push stock over the cap.
- "Damaged" in the failure mode is wrong: `unitOperational` counts damaged
  hulls.
- The right storage rule is "physically present": not destroyed, not
  mothballed and not in transit.

**Missed:**

- `queries.zig:1808-1820` recounts the trucks itself, with hard-coded "× 20t"
  and "× 5t" (rules 5 and 6).
- The salvage-lance bonus on screen uses `units.len > 0`, while the sim uses
  `forceOperational`.
- The mess-lance rest bonus uses `units.len > 0`.
- Both rules match chassis-key strings instead of a unit role.

**Fix (D29):**

- One truck-capacity function per purpose (salvage: operational; storage:
  present), which every query calls.
- A test that toggles each truck state and asserts that every consumer agrees.

### A17. Local beachhead pricing uses a fixed distance: Accepted with correction → D29

**The literal 30 is real** (`field_supply.zig:161-165`), uncommented, and
should at least be the `beachhead_band_ly` knob.

**The impact is mostly wrong.**

- Beachhead offers exist only inside a band 30 LY wide
  (`market.visibilityFor`; `beachhead_band_ly = 30`). So the distance beyond
  the ring is always 1–30 LY.
- `localPurchaseMultBp` rounds down.
- The fixed 30 therefore gives 2.5× everywhere, while the real distance would
  give 2.0× almost everywhere.
- The 4.0× cap can never be reached, so the proposed test ("two distances …
  distinct, correctly capped") would mostly see identical values.
- "Use the same quote for local purchases and emergency resupply" is already
  true: both call `localPriceMultBp`.

§9.6 does not say whether a partial 30 LY rounds up or down. Rounding up makes
today's value correct.

**Missed:**

- The Map screen hard-codes "×1.0 (in ring)" and "×4.0 (out of reach)"
  (`queries.zig:6162-6166`). The real in-ring value is 1.5×, and 4.0× is
  unreachable.
- §9.6 promises that the penalty ends once a field HQ is planted. Nothing
  implements that.

**Fix (D29):**

- The distance beyond the ring is computed from the contract's stored
  distance and offering HQ, in one rule.
- The rounding is an explicit, documented decision.
- The Map text comes from that rule.
- The field-HQ recovery is implemented.

### A18. User text enters markup unescaped: Accepted → D30

**Confirmed:**

- The wizard's name, outfit and company (`app.zig:710`, `:750-751`).
- Ledger notes (`queries.zig:1180`), fed by HQ names (`tick.zig:481`).

Terminal escapes are already neutralised, so this is presentation injection
only.

**Missed:**

- Logo filenames (`app.zig:757-763`).
- The typed verb echoed in "unknown verb '…'" and in the usage fallback.
- `ledgerLines` (`queries.zig:5646`).

**Fix (D30):** escape at each site, and extend the hostile-name test to the
wizard and the ledger. A distinct markup type is the proposed contract's
`table.Raw` direction, and we will extend it there.

### A19. Narrow Forces focus can move to an undrawn pane: Accepted → D30

**Confirmed.** It also covers exactly 120 columns: `narrow` is `< 120` and
`wide` is `> 120` (`layout.zig:16-22`), so at 120 the spec counts two panes
while the screen draws one.

**Fix (D30):**

- One narrow pane.
- A structural test that every focus index maps to a drawn pane at every
  tier.

### A20. Width assumes one cell per code point: Accepted → D33

**Confirmed.** Input accepts any printable code point, so wide characters can
be typed into names.

**Missed:** `queries.padCells` is a second width counter
(`queries.zig:76-91`), and it uses `Utf8View.initUnchecked` on text that may
be invalid UTF-8.

Severity is low: all game data is ASCII plus single-width symbols.

**Fix (D33):**

- One `wcwidth`-equivalent width function, used by drawing, measuring,
  clipping, padding and wrapping.
- `padCells` is deleted.

### A21. Music shutdown can block: Accepted with correction → D33

**The blocking `waitpid` is confirmed** (`music.zig:256-266`).

Two corrections:

- **Volume changes do not stop the player.** `setVolume` does not call
  `stop()`.
- **The playlist growth is about 8 bytes per track per rebuild**, a few
  kilobytes an hour.

Every supported player honours SIGTERM, so a hang needs a wedged child.

**Fix (D33):** poll with `WNOHANG`, escalate to SIGKILL after a bound, and
reuse one order buffer.

### A22. PNG validation: Accepted with correction → D33

**Confirmed:**

- CRCs are skipped.
- IHDR ordering is unchecked.
- The 64M-pixel limit allows about 450 MB of working memory.

**The correction on alpha:** kitty and iTerm2 receive the original file
bytes (`emblem.zig:14-26`), so transparency renders correctly on the primary
terminals. Alpha is lost only in the half-block fallback.

**Missed:** emblem bytes are stored in the save and decoded again on load, so
save content is an input path as well as the logos folder.

**Fix (D33):**

- CRC and chunk-order checks, and an exact inflated length.
- A practical emblem pixel limit.
- Alpha blended against the background in the fallback.
- Fixtures for malformed, oversized and transparent images.

---

## Persistence and lifecycle findings

### A23. Store initialisation mutates before rejecting a future schema: Accepted → D31

**Confirmed:**

- `fromDb` runs the DDL outside any transaction and before the version check
  (`store.zig:173-188`).
- `getSetting` turns prepare, bind and step errors into the caller's default
  (`:267-273`).
- `@max(1, …)` clamps a zero or negative version to 1, per store and per
  campaign.

The practical impact is small, because the DDL is `IF NOT EXISTS`. It still
breaks "refuse without mutating".

**Fix (D31):**

- Read the version strictly first.
- Distinguish a new store from missing or corrupt metadata.
- Run the DDL and the migrations in one transaction.
- Reject a version below 1.

### A24. SQLite handles leak on open failure: Accepted → D31

**Confirmed** (`sqlite.zig:44-47`; `Store.open` has no `errdefer`).

Both production callers exit when opening fails, so the leak cannot repeat
today.

**Fix (D31):** close the handle on failure, add `errdefer` in `open`, and
document that `fromDb` takes ownership only on success.

### A25. Player deletion is not atomic: Accepted → D31

**Confirmed.** Each campaign deletion commits separately, and the final
`DELETE FROM player` runs outside any transaction. SQLite rejects a nested
`BEGIN`, so the audit's shape is the right one: a non-transactional
`clearCampaignRows` inside one transaction.

**Missed, and reachable in normal play:**

- `Lobby.deletePlayer` does not reset the open session's campaign ID.
- The TUI can delete the current player while a campaign is open.
- The next save then fails with a sentence that sends the player to the REPL's
  `campaigns` command.

**Fix (D31):** one transaction for the whole deletion, the session reset, and
a test for each.

### A26. SQLite errors are too coarse: Accepted → D31

**Confirmed.** Every result code collapses into `SqliteError`, and the
fallback sentence says "nothing was changed". That is untrue after a partial
`deletePlayer` (A25) or a committed DDL (A23).

**Missed:**

- There is no busy timeout, so a second game instance on the same store fails
  at once with a generic error.
- `Stmt.run` treats `SQLITE_ROW` as success.

**Fix (D31):**

- Bind the extended error code.
- Add `StoreBusy`, `StoreReadOnly`, `StoreFull`, `CorruptStore` and
  `ConstraintViolation`, each with its `errorText` sentence.
- Set a busy timeout.

### A27. Migration tests miss most historical ALTER paths: Accepted → the foreign-key migration item

**Confirmed.** The one v5 fixture runs about 20 of the 40 migration steps. The
steps it never runs include:

- contract ×7
- `battle_report` ×2
- `pending_event` ×3
- listing, force, candidate and policy

The migration array is also out of version order (v34 comes before v9), which
is harmless only because each step filters on its own version.

**Fix:** fixtures at four schema boundaries, checking the resulting schema,
idempotence, rollback and the refusal of a newer store without mutating it.
They land **before** the table-rebuild migration, which needs them.

### A28. Campaign tables lack indexes: Accepted with correction (severity) → D31

**Confirmed:** there is no `CREATE INDEX` anywhere, and about 35 tables are
scanned in full on each save, delete and load.

**The severity is lower than implied.** Stores are single-user, and a campaign
keeps at most 40 battle reports (`tuning.zon:219`).

**Fix:**

- **D31**: the non-unique `(cid)` and `(cid, parent, ord)` indexes, as
  `CREATE INDEX IF NOT EXISTS`, since they need no table rebuild.
- **The foreign-key item**: the unique `(cid, ord)` indexes the foreign keys
  depend on.

---

## Build, packaging and CI findings

### A29. Overlay path mistakes silently compile stock data: Accepted → D32

**Reproduced:** `zig build validate-data -Ddata=/nonexistent/mod` exits 0
(`build.zig:45-54`). A misspelled file name is ignored as well.

The runtime banner ("mod X: 0 files overlaid", `root.zig:31-35`) shows it only
after the build.

**Fix (D32):**

- Fail when the directory is missing, or when zero files are overlaid.
- Warn on `.zon` files that match no known name.

### A30. The package manifest includes the whole soundtrack: Accepted → D32

**Confirmed, and larger than the audit's "hundreds of megabytes" implies.**
`data/music` is 46 tracked files, 258 MB, all included through the recursive
`"data"` entry in `build.zig.zon`.

**Fix (D32):** list the `.zon` inputs and `data/tables` explicitly, and leave
`data/music` out of `.paths`. It stays an opt-in install for
`-Dbundle-music` release trees. This is the second half of proposed rule 66,
which had no TODO line.

### A31. CI builds neither the release configuration nor the platforms: Accepted with correction → D32

**Confirmed:** there is one Debug job on Ubuntu, and no ReleaseFast build.
Given A14's ReleaseFast undefined behaviour, this matters.

**The correction:** the README does not claim Windows. It names macOS and
Debian/Ubuntu. The concrete gap is macOS, our primary platform, which CI never
compiles. Windows is already scheduled.

**Fix (D32):**

- A ReleaseFast package build.
- A `macos-latest` job.
- Windows stays in its own scheduled item.

### A32. CI actions and permissions are not hardened: Accepted → D32

**Confirmed.** The repository's default workflow token is already read-only,
which mitigates it, but, as the audit says, that depends on a setting outside
the repo.

**Fix (D32):**

- Actions pinned to SHAs.
- `permissions: contents: read`.
- `persist-credentials: false`.
- Job timeouts.
- Concurrency cancellation. Every PR currently runs CI twice (push and
  pull_request), so this saves real time.

### A33. Bundled media has no rights manifest: Accepted → D34

**Confirmed.** There is no ASSETS or NOTICE file, and with no statement
otherwise, the soundtrack and the crest fall under the repository's GPLv3,
which may not be what the owner intends.

**Fix (D34):** an `ASSETS.md` giving the source, owner, licence and
redistribution terms for each asset set:

- `data/music/OST`, `OST Part 2` and `Supplimental Music`
- `docs/logos`
- `unforgiven.png`, which nothing references and which will be removed or
  used
- the test fixtures
- the generated screenshots

Any asset whose rights are unresolved stays out of packages and releases until
they are resolved.

### A34. Smoke scripts delete caller paths and leak children: Accepted with correction → D32

**Confirmed:**

- Both scripts delete the path they are given, without checking it.
- The REPL smoke has no timeout.

**The leak is overstated.** `pty.fork` makes the child a session leader. When
the Python process dies, the pty master closes, and the child receives SIGHUP
and exits (the TUI does not handle SIGHUP, and music is off in the smoke). The
practical residue is a brief zombie, and an exit status nobody checks.

**Fix (D32):**

- Default to a temporary path, and refuse an existing file that is not a
  `.db`.
- `try/finally` with kill, and `waitpid` with the exit status checked.
- A timeout on the REPL run. macOS has no `timeout` binary by default, so it
  will be done in the script.

---

## Structural findings

### A35. Large central modules: Accepted, already scheduled

**Confirmed.** The same seven modules are the only ones over 1,000 lines:

| Module | Lines |
|---|---|
| `queries` | 6,202 |
| `commands` | 4,796 |
| `app` | 4,030 |
| `store` | 2,909 |
| `battle` | 2,259 |
| `state` | 2,245 |
| `contract_events` | 1,382 |

`TODO.md` already lists them as rule-87 exceptions in the adoption PR, each
tied to a split after adoption, with state behaviour moving first (rule 77).
We agree with the audit's constraints: one subsystem at a time, behind an
unchanged facade, the golden hash preserved, and no split combined with a
correctness change.

### A36. REPL session ownership bypasses the facade: Already fixed

**Fixed in `f1d6887` (PR #101).** Both frontends hold a `lobby.Session`, and
the REPL runs new, load, save and delete through it (`main.zig:515-556`).
`docs/verify-contract.sh` now rejects a frontend that owns a `GameState`.

**One leftover:** the demo run (not the REPL) calls `gs.hash()` at
`main.zig:355`. It moves behind a query in D30.

### A37. Completion is a second read boundary: Accepted with correction → D30

**Confirmed:** `cli.completionPool` walks `gs.hqs`, `gs.forces` and the
catalogues directly, and offers every planet and every ID regardless of
relevance.

**The correction:** both contracts place `cli.zig` in the application layer,
not the frontend layer, so this is not a literal breach of the query-only
rule. It is a second read path that a frontend consumes, and we agree it
should not exist.

**Fix (D30):** `queries.completionCandidates`; `cli.zig` keeps token context
and prefix matching only.

---

## Positive observations

We agree with them, and we keep them as invariants. The deterministic core,
the arena-owned state and the golden digest are what let us confirm or
correct each finding here by tracing a single path.

---

## Delivery plan

Each deliverable is one pull request. Each lands on `main` before the next
begins, and each adds its regression test before it changes behaviour, as the
audit asks. Deliverables D23–D34 are new. Work already in `TODO.md` is shown
where the audit's items join it.

| # | Deliverable | Findings | Size |
|---|---|---|---|
| D23 | Pointer lifetimes in decisions and battle | A1 (pointer and log), A2 | small |
| D24 | Errors that follow a mutation propagate | A3 (catch sites) | small |
| D25 | Turn-advance safety and strict frontend verbs | A9, A10, A12 | small |
| D26 | Posture-owned location rules | A8 | medium |
| D27 | One result presenter for both frontends | A11 | medium |
| — | **Failure atomicity** (scheduled; moved earlier) | A1 (prepare/commit), A3 (reserve-first), `ARCHITECTURE.md` §4 | medium |
| D28 | Save loading fails closed | A4, A5, A6, A7 | medium |
| D29 | Freight routing, truck capacity, beachhead pricing | A15, A16, A17 | medium |
| D30 | Frontend boundary hardening | A13, A18, A19, A37, A36 leftover | medium |
| D31 | Store lifecycle | A23, A24, A25, A26, A28 (non-unique) | medium |
| D32 | Build, data validation and CI | A14, A29, A30, A31, A32, A34 | medium |
| — | **Foreign keys and table rebuild** (scheduled) | A27 fixtures first; A5 `CHECK`s; A28 unique indexes; A25 cascade | large |
| — | **Behaviour off `GameState`**, then the adoption PR and module splits (scheduled) | A35 | large |
| D33 | Terminal text and media inputs | A20, A21, A22 | medium |
| D34 | Asset rights manifest | A33 | small; waits on the owner's rights statement |


**Why this order:**

- **The integrity fixes come first**, as the audit asks. D23 removes the
  pointer defects. D24 stops failures from being hidden or mislabelled;
  integrity after an allocation failure comes with failure atomicity. D25–D27 are the ones a player can
  hit today, each with one keystroke: a malformed `:day`, the week advance, a
  mis-parsed policy, and an order reported as successful when it failed.
- **The scheduled failure-atomicity work moves ahead of** the behaviour move
  off `GameState`, because A3's sites are in `state.zig` methods that the move
  would otherwise relocate before fixing them.
- **Loader hardening (D28) comes before the foreign-key migration**, because
  the loader stays the integrity check for old and damaged stores after
  constraints land, as the audit notes. The migration fixtures (A27) must
  exist before any table is rebuilt.
- **The terminal and media items come last.** They are low severity, and their
  inputs are the player's own.

We would welcome the auditors' view on four points:

1. Whether the live/historical split of references in A4 matches their intent.
2. Whether a reserve-first discipline with one failure-injection test per
   pattern meets A3's requirement, rather than a general transaction
   mechanism.
3. The A17 rounding question.
4. Whether they agree that A1 and A2 are High and Medium, given the arena
   allocator.

## Auditors' reply (2026-09-24)

The auditors had no substantive objection to the response or its order,
and it stands as the implementation plan. Two changes were adopted:

- **D24** is described as stopping failures from being concealed or
  mislabelled, not as restoring integrity. Integrity after an allocation
  failure comes only with the failure-atomicity item, which stays ahead of
  the behaviour move off `GameState`.
- **D28** validates the object graph against an explicit reference-policy
  table with five classes: required live, optional live, historical,
  derived and sentinel-capable. The table makes the distinction testable
  rather than a matter of comments in individual loaders.
