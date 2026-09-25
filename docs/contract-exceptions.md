# Contract exceptions

Every place the code does not yet meet `docs/coding-contract.md`, as rule 87
requires: the rule, why it is not fixed yet, the scope, the deliverable in
`TODO.md` that removes it, and what stops it growing. The contract governs
all new code in full; nothing here licenses a new violation. The deliverable
that closes an entry deletes it (and its ratchet or baseline lines) in the
same pull request.

Scope lists name the sites a compliance sweep of every rule verified in the
code when the contract was adopted. A site found later joins its entry in
the pull request that finds it.

Owner of every entry: the project owner.

---

### C2. Errors lose their meaning or are swallowed

- **Rules:** 4, 10, 18, 79.
- **Why not yet:** Each of the 40 sites needs to be either propagated or given a real best-effort reason, and that has to be decided one site at a time.
- **Scope:** every entry in `docs/verify-contract.baseline`. The ones that already change outcomes:
  - Rating and liquidation:
    - `rating.zig:157` (`planLift catch continue`)
    - `treasury.stripValue` (`stripParts catch return 0`)
  - Hidden warnings and results:
    - `checklist.zig:95`
    - `tick.zig:127` (`trim_stock catch Result{}`)
    - `queries.zig:2561`, `3400`
  - Frontend failures turned into zeros:
    - `app.zig:2436` (`hqSelId`)
    - the REPL's `parseInt catch 0` at `main.zig:568`, `602`, `629`, `669`
    - the REPL checklist gate `main.zig:431`
  - Errors under the wrong name:
    - `execDepot` maps `OutOfMemory` and `MissingComponents` to `NoBay` (`commands.zig:1343-1349`).
    - `png.zig:91` maps `OutOfMemory` to `Corrupt`.
  - Automation that swallows failures:
    - `tick.zig:139`, `229` (ship and stock-policy failures are logged only weekly)
    - `contract_events.zig:689` (`hire_candidate`)
  - `@errorName` written into player-visible log text: `tick.zig:140`, `230`, `contract_events.zig:690`, `medical.zig:333`.
- **Removal:** C2.
- **Guard:** `verify-contract.sh` fails on a broad catch missing from the baseline, and on a baseline entry that no longer exists, so the baseline can only shrink.

### C3. Money and assets change without a matching record

- **Rules:** 1, 13, 19, 44.
- **Why not yet:** Each fix changes a player-visible outcome and needs its own regression test.
- **Scope:**
  - Couriers to a sold HQ or disbanded company are never cancelled. On arrival the ledger says received and no balance moves (`commands.zig:1405-1506`, `tick.zig:295-301`, `state.zig:343-353`).
  - `addStock` and `postTreasury` silently skip an unknown site (`state.zig:1093`, `347-352`).
  - Selling an HQ drops its bay jobs, but the hulls stay repairing or refitting (`commands.zig:1415-1418`).
  - `queueDepotRepair` wrecks the hull before refusing (`hq_ops.zig:305-311`).
  - `execCreateCommander` sets the year before its refusal (`commands.zig:907-909`).
  - `orderPart` rolls the dice before the funds check (`commands.zig:2194` vs `2217`).
  - GAME OVER says "saved" after a failed final save (`app.zig:2463`, `1342`).
- **Removal:** C3.
- **Guard:** review (checklist questions 2 and 14). No mechanical check.

### C4. Module and function size; behaviour on GameState; layering

- **Rules:** 5, 14, 76, 77.
- **Why not yet:** Decomposition is behaviour-preserving work spread over several pull requests, one module at a time, with the golden hash unchanged.
- **Scope:**
  - Every module and function listed in the ratchet below.
  - Three switches with more than ten substantive arms (an arm body past three lines), measured by the check that guards them: `contract_events.applyEffectsFor` (21), `app.listView` (19), `forces.handle` (19). Five more sit at the threshold without crossing it: `app.listEnter` and `app.handleModalKey` (10 each), `market.handle` (10), `app.drawModal` (9), `supply.handle` (7).
  - `GameState` methods with subsystem behaviour: posture, TO&E, crew, tech time, lift, supply, refit, aftermath, `commanderMultBp`, and `hirePerson`'s default skill table (it leaves with C11's single role-to-skill rule; the creation itself is a storage primitive). (Hashing has moved to `digest.zig`; transfers, couriers, purchase debits, payroll, upkeep, sale values, liquidation and credit to `treasury.zig`; recruiting, spec hiring, posting and the recruit bonus to `personnel.zig`; the back-office counts, staffing refresh and autostaffing to `hq_ops.zig`; founding HQs and assigning companies within capacity to `hq_network.zig`.)
  - One layering violation: `state.zig` imports `field_supply.zig` (in `loadOutCompany`). The `rating.zig` import left with `recruitBonus`.
  - The named atomic operations that rule 14 cites do not exist.
- **Removal:** C4.
- **Guard:** the rule 76 ratchet in `verify-contract.sh`. A listed module, function or switch may not grow past its ceiling, and an unlisted one may not cross the threshold.

### C5. Commands and ticks are not failure-atomic

- **Rules:** 11, 12, 13, 15, 17, 69.
- **Why not yet:** It needs reserve-first helpers and a failure-injection test per mutation pattern, landed in increments.
- **Scope:**
  - **Primitives.** `transferFunds`, `createForce`, `assignUnit`, `moveUnitToForce`, `placeUnitInCompany`, `holdUnit` and `releaseHull` (`state.zig`) are not reserve-first. Only four commands call `reserveLedger`.
  - **`acceptContract`.** It removes the offer before its fallible steps (`commands.zig:2351-2419`).
  - **Assets split by a fallible step after a mutation:**
    - `commands.zig`: `execSellStock:1179`, `execTrimStock:1276`, `execHireCandidate:1605`, `execLink:624`, `execTrainAbility:939`, `execUpgradeTier:604`, `orderPart:2210-2230`, `execDisbandCompany:1472`
    - `state.moveStock:1156`
    - `hq_ops.queueDepotRepair:323`
  - **Partial loops.**
    - `replaceGear` (`commands.zig:2118-2156`) runs a per-slot loop with no batch validation.
    - `commitLift` (`commands.zig:2296-2301`) keeps moved ships after a failure.
  - **`advance`.** It refuses after days have ticked and loses the count (`commands.zig:2477-2487`).
  - **Tick phases retried after a failure apply twice:**
    - couriers (`tick.zig:296-301`)
    - part orders (`tick.zig:262-266`)
    - `completeJob` (`hq_ops.zig:651-718`)
    - weekly repairs (`maintenance.zig:237-276`)
  - **Stock-mutation results ignored:** `battle.zig:943`, `maintenance.zig:247`, `271`.
  - **Tests.** There are no failure-injection tests in the sim.
  - **Refusal text.** The fallback "nothing was changed" (`cli.zig:621`) is not yet true.
- **Removal:** C5.
- **Guard:** review (checklist questions 2, 3 and 14). No mechanical check.

### C6. Identity is inferred or positional

- **Rules:** 16, 32, 56.
- **Why not yet:** Typed IDs for offers, listings, candidates and loans change command payloads, the save format and every frontend that uses them.
- **Scope:**
  - **Commands take list positions:** `accept_contract`, `negotiate`, `buy_listing`, `hire_candidate`, `repay_loan` (`commands.zig:65`, `72`, `82`, `114`, `166`). `negotiate` removes an offer, which shifts every later index (`2327`).
  - **Results carry no created ID:** `found_hq`, `accept_contract`, `order_part`, `take_loan`.
  - **"Last" lookups:**
    - `acceptedLine`, `lastOrderLine`, `lastLogLine` (`queries.zig:5757`, `5683`, `5637`)
    - `battle.lastWound:1105`
    - `queries.zig:2747` (`next_person_id - 1`)
  - **The seat HQ by collection order:** about 100 `hqs.keys()[0]` sites.
  - **Untyped rows and pickers:**
    - Checklist rows carry a tab number, not a target.
    - `PickRow.id` is an untyped `u32`.
    - `hq_sel` and the log modal keep row positions.
- **Removal:** C6.
- **Guard:** review (checklist questions 7 and 8). No mechanical check.

### C7. Loading does not fail closed

- **Rules:** 2, 7, 45, 46, 47, 48.
- **Why not yet:** It needs an explicit reference-policy table and one corruption test per relationship family.
- **Scope:**
  - **Orphan rows skipped:**
    - `unit_slot` (`store.zig:1218-1220`)
    - `refit_op` (`1817`)
    - stock (`state.zig:1093`)
    - report children (`store.zig:1736-1802`)
  - **Unchecked links:** `force_unit` and `force_child` (`1263`, `1270`). No cross-entity reference is validated.
  - **Discriminators.** An unknown value becomes a valid one (`1568`, `1819-1821`). Booleans are decoded as `!= 0`. An unknown optional enum becomes null (`1128`, `1248`, `1306`).
  - **Counters.** They are never checked against the highest loaded ID. The v5 fixture reuses ID 1 (`2250-2262`).
  - **Pending events.** Choice indices are unchecked (`1642-1644`).
  - **Duplicate keys** overwrite silently (`1131`, `1202`, `1256`, `1290`, `1382`, `1536`, `1547`).
  - **NULL values** are read as 0 or an empty string (`sqlite.zig:153`, `163`).
  - **Meta rows.** Missing ones fall back to defaults (`store.zig:1031-1069`).
  - **Range checks.** Dates and domain values are checked only against their storage width. Month 13 reaches `unreachable` (`1036`, `clock.zig:34`).
  - **Stock sums** can overflow (`state.zig:1096`).
  - **Compatibility repairs** run on every load instead of in versioned migrations: RNG reseed, stats rebuilt from the log, event-ID stamping (`958-960`, `1005`, `1653`).
  - **Load writes state and draws dice.** It runs `refreshHqStaffing`, `upgradeCampaign` age rolls and `resumeBattleIds` (`1001-1008`).
  - **Integer casts:**
    - `sqlite.zig:103`: `bind` does an unchecked `@intCast`.
    - `store.zig:430`: `@intCast` of the stats counter.
    - `store.zig:1654`: `@enumFromInt(i + 1)` when stamping event IDs.
  - **ID overflow.** `resumeBattleIds` and `resumeIds` overflow at the u32 maximum.
  - **Unsaved field.** `Person.secondary_role` is not persisted.
  - **Unordered loads.** Award and ability rows load without `ORDER BY` (`1133`, `1141`, `1148`).
  - **Digest.** It folds maps in any order, while play depends on map order (`digest.zig:57-67`).
- **Removal:** C7.
- **Guard:** review (checklist question 4). No mechanical check.

### C8. Store lifecycle

- **Rules:** 44, 49, 62, 63.
- **Why not yet:** It needs SQLite error-code mapping and a strict version read ahead of any DDL.
- **Scope:**
  - **Opening a store:**
    - DDL runs before the version check (`store.zig:174-177`).
    - `getSetting` returns the default on any error (`267-273`).
    - The stored version is clamped (`176`, `1021`).
    - The handle leaks when open fails (`sqlite.zig:46-49`, `store.zig:168-170`).
  - **Deleting a player:** `deletePlayer` is not atomic and leaves the live session pointing at the deleted player (`306-315`, `lobby.zig:55`).
  - **SQLite behaviour:**
    - Errors are coarse (`sqlite.zig:39`).
    - There is no busy timeout.
    - `Stmt.run` treats ROW as success (`133`).
    - There are no indexes.
  - **Failures shown the wrong way:**
    - Registry-read errors (`main.zig:78`) and settings writes (`app.zig:1514`, `1524`, `3130-3142`) surface as generic lines.
    - `lobby.zig:78` sets `player_id` before the save that can fail.
  - **Old resource freed before its replacement succeeds (rule 63):**
    - `refreshEmblem` (`app.zig:566-576`)
    - `loadPreview` (`1752-1761`)
    - `generateCampaign`, which closes the session first (`1790-1792`)
    - the music playlist on out-of-memory (`music.zig:175`)
- **Removal:** C8.
- **Guard:** review (checklist question 15). No mechanical check.

### C9. Schema integrity and migrations

- **Rules:** 50, 51, 70.
- **Why not yet:** The foreign keys need a table-rebuild migration, and fixtures at the old schema boundaries must exist first.
- **Scope:**
  - The schema has no `REFERENCES`, unique keys, `CHECK`s or `PRAGMA foreign_keys`.
  - The only migration fixture is v5.
  - The migrations array is out of version order (`store.zig:126-132`, `158-159`).
  - A `Migration` names no source version (`107`).
  - Next-ID counters and required meta rows have no adversarial tests.
- **Removal:** C9.
- **Guard:** the DDL-to-registry test (`store.zig:2883`) and review.

### C10. Location, posture and the seat

- **Rules:** 21, 22, 23, 71.
- **Why not yet:** It changes gameplay balance. Named posture predicates and two-HQ tests come first.
- **Scope:**
  - **"Not deployed" used as "home".** These sites treat a company without a deployment contract as home:
    - `medical.zig`: `87`, `108` (`careFor`), `353-381` (rest), `395` (rotation reset)
    - `maintenance.zig:113`
    - `checklist.zig:270`
    - `commands.zig`: `866`, `882`, `934`, `1054`, `1216`, `1342`, `1377`, `1389`, `1624`, `1634`, `1799`
    - The checklist's `isCompanyHome` count disagrees with `careFor` (`499`).
  - **Rules reading the first HQ instead of the one involved:**
    - negotiation uses the first HQ's command office (`commands.zig:2315-2317`)
    - the freight discount comes from the first HQ (`2030-2032`)
  - **Medical pooled across the outfit:** beds, hospital bonus, doctors and medics (`medical.zig:122-166`).
  - **Seat and `.outfit` resolution** is re-derived at about 13 sites.
  - **Lab stock double-counted:** `installCandidates` adds the seat's stock on top of the home HQ's (`queries.zig:3372`).
  - **Two-HQ tests missing** for medical, maintenance, the hiring hall, negotiation, `hq_ops`, the checklist and field supply.
- **Removal:** C10.
- **Guard:** review (checklist question 5). No mechanical check.

### C11. One rule, one owner

- **Rules:** 20, 21, 26, 27, 29, 60.
- **Why not yet:** Each duplicate has to be collapsed into one owning function, with a test that the owner and its consumers agree.
- **Scope, copies that already disagree:**
  - **Admin desk requirement,** defined three ways (`hq.zig:84`, `state.zig:626-632`, `queries.zig:5204-5210`, `2012-2017`).
  - **Disband quote** leaves out company funds (`queries.zig:6028` vs `commands.zig:1461`).
  - **Medbay cover** leaves out medics (`queries.zig:5302-5309` vs `medical.zig:119-129`).
  - **Effectiveness %** reads 100 in one place and 0 in another (`queries.zig:364`, `925`; `checklist.zig:126`).
  - **Two "coming" ledgers** disagree (`hq_ops.zig:44`, `163`; `field_supply.zig:256`).
  - **Skill selection and untrained fallbacks** differ:
    - selection: `battle.zig:246`, `personnel.zig:275`, `rating.zig:84`
    - fallbacks: `state.zig:428-495`, `queries.zig:4724`
- **Scope, copies:**
  - HQ sale proceeds (`queries.zig:6024`, `commands.zig:1409`)
  - transit days (`commands.zig:2371`, `queries.zig:4431`, `722`)
  - company travel days (`queries.zig:4567`, `4583` vs `commands.zig:1919`, `1789`)
  - accept eligibility (`commands.zig:2356`, `queries.zig:4397`)
  - the reorder wait (`tick.zig:218`, `queries.zig:2261`)
  - medical loops (`medical.zig:97-165`)
  - great-house tests (`contract_market.zig:31`, `commander.zig:25`)
  - "needs a part" (`queries.zig:3541`, `maintenance.zig:488`, `554`)
  - the salvage claim (`queries.zig:943`)
  - manning shortfall (`forces.zig:44`, `app.zig:2808`)
  - companies at an HQ (`queries.zig:5128`)
  - tier-upgrade eligibility (`commands.zig:600`, `hq_ops.zig:445`, `queries.zig:1954`)
  - lance placement (`commands.zig:1199`)
  - `post_person`, which has no eligibility rule and does not vacate the person's seat (`commands.zig:1567`, `state.zig:505`)
  - `planLift`, which fuses quote and commit (`commands.zig:2250`)
- **Scope, predicates:**
  - errors chosen by comparing reason text (`state.zig:1417`, `commands.zig:1792`)
  - `hasCrewedDropship` is incomplete (`state.zig:1043`)
  - `canFight` is misnamed (`unit.zig:258`)
  - medics are counted by raw status (`medical.zig:125`)
  - two different armour-demand predicates (`field_supply.zig:88`, `196`)
- **Removal:** C11.
- **Guard:** review (checklist question 1). No mechanical check.

### C12. Frontend boundary and results

- **Rules:** 9, 10, 30, 33, 34, 35, 36, 37, 38, 39, 40, 41, 43.
- **Why not yet:** A result presenter shared by both frontends comes first; the fixes that follow build on it.
- **Scope:**
  - **Results and eligibility:**
    - The TUI says "done: verb" (`app.zig:3831`).
    - Order and buy flows hide failed sourcing and fraud (`market.zig:79-82`).
    - Screens pre-validate eligibility (`app.zig:2349`, `3165`, `3184`, `3201`; `hq.zig:92`; `market.zig:105`, `133`).
  - **Refusal wording.** `execResultWith` sentences are written by the caller (`app.zig:1186`, `1714`; `supply.zig:175`; `lab.zig:79`).
  - **Untrusted text reaching markup:**
    - wizard names (`711`, `755`, `756`)
    - logo and music names and paths (`412`, `456`, `649`, `761`, `765`, `1517`, `2129-2134`, `2768-2781`, `2885-2887`, `3882-3884`)
    - typed input and echoed verbs (`606`, `1389`, `3762`, `3795`, `3827-3833`)
    - ledger notes (`queries.zig:1179`)
    - other names (`queries.zig:5265`, `5291`, `5768`, `6021`)
    - the REPL printing markup raw (`main.zig:96`, `362-393`, `437`, `727`, `782-797`)
  - **Focus and layout:**
    - Focus is not clamped on resize (`app.zig:401-404`).
    - The Forces and Desk panes are declared but not drawn at some sizes (`app.zig:2003-2005`, `forces.zig:23`, `desk.zig:55-61`).
    - Layout numbers sit outside `layout.zig`.
  - **Client state:**
    - The emblem stays cached after `:crest` (`app.zig:565-579`).
    - Cursor slots are shared between the lobby and tabs (`465-481`).
    - Map panning lives in `runGlobal` (`1937`).
    - `tab_names` sits beside the screen table.
    - Widget and cursor code is duplicated (`2056-2167`, `ledger.zig:43-72`, `contracts.zig:24-76`).
  - **Key hints** are written by hand (`412`, `1107`, `1369`, `2139`, `2217`, `2304`, `2796`, `3206`).
  - **Map colours** are not semantic (`map.zig:53-78`, `desk.zig:31`).
  - **REPL parsing:**
    - The REPL parses the client verbs itself (`main.zig:511`, `519`, `590`, `594`, `729`).
    - Its view verbs are lax (`568`, `602`, `620-703`).
  - **Queries and reads:**
    - `cli.completionPool` walks the state directly (`cli.zig:627-642`).
    - `Session.state()` hands out a raw `GameState`.
    - The demo run hashes directly (`main.zig:355`) and reads a catalogue directly (`main.zig:218`).
    - The P&L window is a literal in four places.
    - The wizard and the REPL each format the back office themselves.
    - The transfer picker invents its own refusal text (`queries.zig:4622`, `4631`).
  - **Wizard.** It runs `commands.execute` directly before the session exists (`app.zig:1796-1801`).
- **Removal:** C12.
- **Guard:** the frontend-boundary, `// direct:`, `// raw:` and escape checks in `verify-contract.sh` hold the existing boundaries. The items above rely on review.

### C13. Numbers, arithmetic and formatting

- **Rules:** 24, 25, 28, 54, 55, 59.
- **Why not yet:** Mechanical, but it touches many rule sites. 331 tuning rows need a citation or `// TUNE`.
- **Scope:**
  - **Rule numbers copied into display text:**
    - `queries.zig:976`, `6019`
    - `map.zig:102`
    - `app.zig:2562`, `2581`, `2681`, `2686`, `2820`, `3155`
    - `forces.zig:225`
    - `commands.zig:2338`
    - `personnel.zig:71`
  - **A false help line:** paperwork (`app.zig:2857`).
  - **Repeated and bare literals:**
    - skull cut-offs (`queries.zig:779`, `815`, `4446`, `4462`, `708`)
    - the `(5 − skill)` term, 8 times
    - the price roll, 5 times
    - link level 3, 4 times
    - day floors
    - negotiation caps
    - the field-plan shape
    - listing expiry
    - standing gain
    - hours per bay day
  - **Limits only the frontend enforces:** fabricate at most 20, loan term at most 60.
  - **Arithmetic:**
    - Loan interest has no helper, and the pay day is stale (`commands.zig:1680-1686`, `tick.zig:566`).
    - Week and month conversions are bare literals.
    - Money is multiplied by raw percentages, not basis points (`contract.zig:213`, `commands.zig:2379`, `2393`, `battle.zig:946`, `state.zig:1849`, `tick.zig:542`, `field_supply.zig:80-106`).
  - **Calendar:** fixed 30- and 365-day units (`tick.zig:372`, `contract_control.zig:75`, `135`, `person.zig:267`, `284`, `454`, `queries.zig:2632`).
  - **Formatting:**
    - Raw C-bills appear in log text (the money formatter is in the queries leaf).
    - Event effects are formatted twice (`contract_events.zig:293`, `queries.zig:535`).
    - Helpers are duplicated: `bpMultText`, half-tons, day and ETA text.
  - **Citations:**
    - 331 tuning rows carry neither a source nor `// TUNE`.
    - Provenance labels are missing (factions, awards, difficulty, ranks).
    - `// TUNE` markers disagree between the struct and the data.
- **Removal:** C13.
- **Guard:** review (checklist question 10). No mechanical check.

### C14. Randomness

- **Rules:** 57.
- **Why not yet:** Passing streams changes generator signatures, and the uncited dice need their sources found.
- **Scope:**
  - **Shared generators hard-code their stream:**
    - `econ/market.zig:89`, `163-191`
    - `gen/company_gen.zig:98`
    - `sim/personnel.zig:289`
  - **About 20 uncited non-2d6 dice:**
    - `market.zig:167-191`
    - `contract_market.zig:46`, `63`, `153`, `159`, `300-323`, `376`, `422`
    - `battle.zig:373`, `1205-1208`
- **Removal:** C14.
- **Guard:** the stream-salt tests in `rng.zig`, and review.

### C15. Routing, truck capacity, beachhead price

- **Rules:** 20, 22, 24.
- **Why not yet:** Changes gameplay balance. The rounding decision is recorded in `docs/audit-response.md` (A17).
- **Scope:**
  - **Routing.** It is a hop-count BFS that ignores capacity (`network.zig:63-144`). The charter fallback has no cap.
  - **Truck capacity:**
    - Capacity counts any truck that isn't destroyed (`state.zig:1124-1140`, `battle.zig:24-33`).
    - Queries recount trucks with hard-coded 20t and 5t (`queries.zig:1825-1835`).
    - The support-lance bonus is applied when `units.len > 0` (`queries.zig:940`, `medical.zig:361`).
  - **Beachhead pricing:**
    - The distance is the literal 30 (`field_supply.zig:164`).
    - The Map multiplier text is hard-coded and wrong in ring (`queries.zig:6214-6216`).
    - The field-HQ recovery that ARCHITECTURE §9.6 describes is not implemented.
- **Removal:** C15.
- **Guard:** review. No mechanical check.

### C16. Scratch memory on the campaign arena

- **Rules:** 78.
- **Why not yet:** Small; scheduled after the error work so each site's allocator is chosen once.
- **Scope:**
  - Child arenas built on `gs.allocator()`: `tick.zig:107` (daily), `commands.zig:1247`, `state.zig:1171`.
  - `defer deinit(gs.allocator())` on local lists: `battle.zig:848`, `867`; `personnel.zig:265`, `267`, `323`; `contract_control.zig:103`; `commands.zig:761`, `763`, `1465`, `1481`, `2266`.
- **Removal:** C16.
- **Guard:** review. No mechanical check.

### C17. Focused tests

- **Rules:** 67.
- **Why not yet:** 421 public functions in the sim and domain have no in-file test naming them. The rule functions among them need a test that the rule and its consumers agree.
- **Scope:**
  - Rule functions with no test:
    - `hq_ops`: `beyondEconomicalRepair`, `canFabricate`, `bayCanRebuild`, `upgradeBlock`, `rebuildEstimate`, `engineCharge`, `paperworkDaysFor`, `depotHqFor`
    - `state`: `assignBlock`, `canReachPool`, `transferFunds`, `isInsolvent`, `liquidationValue`, `creditLimit`, `techHoursAvailable`, `findFreeTech`, `siteCapacityTons`, `moveStock`, `courierEtaDays`, `staffHqToRequirement`, `applyRefit`
    - `battle`: `effectiveRoe`, `estimatePower`, `estimatedKills`, `inContactWindow`
    - `medical`: `healDays`, `careFor`, `turnoverRisk`
    - `personnel`: `severanceOwed`, `manningNeeds`, `readinessPenalty`
    - `field_supply.rushQuote`
    - `network`: `fitsThroughput`, `routeCostMultBp`
    - `offer_rating.rateOffer`
    - `commands.transferBlock`
    - `checklist.turnHold`
    - `clock.isPayday`
    - domain `contract`: `gradeOf`, `objectivesMet`
    - domain `person`: `baseSalary`
    - domain `unit`: `carryCost`, `maintenanceHours`
    - domain `types`: `salaryMultBp`, `availabilityTarget`
  - 89 of the 157 query functions have no test.
  - Screen modules test one or two of their keys, and no empty states.
- **Removal:** C17.
- **Guard:** review (checklist question 13). No mechanical check.

### C18. External input bounds

- **Rules:** 41, 64.
- **Why not yet:** Needs a width table and bounded decoders.
- **Scope:**
  - **Text width.** Width is counted per code point, not per cell (`screen.zig:149-177`). `queries.padCells` is a second counter, and it uses `initUnchecked` (`queries.zig:76-92`).
  - **PNG decoding:**
    - CRCs are not checked (`png.zig:69`).
    - IHDR order is not checked (`56-68`).
    - The pixel limit is 64M (`82`).
    - The inflated length may exceed the expected length by one byte (`88-89`).
    - Alpha is dropped in the fallback (`133`).
  - **Database blobs** are copied with no size limit (`sqlite.zig:167-172`).
  - **Terminal input.** A CSI parameter can overflow (`term.zig:258`).
  - **Music:**
    - `waitpid` blocks (`music.zig:256-266`), and `-1` is read as "finished" (`224-226`).
    - Each playlist rebuild allocates in the long-lived arena (`161-176`).
- **Removal:** C18.
- **Guard:** review. No mechanical check.

### C19. Platform support

- **Rules:** 65.
- **Why not yet:** Needs a target-gated terminal, resize, child process, paths and audio for Windows.
- **Scope:**
  - `term.zig` uses POSIX termios and SIGWINCH unconditionally.
  - `music.zig` uses `waitpid`, `getpid`, `kill` and a PATH scan split on `:`.
  - `build.zig` rejects no target.
- **Removal:** C19.
- **Guard:** review. No mechanical check.

### C20. Documentation and naming

- **Rules:** 61, 75, 81, 82, 84.
- **Why not yet:** Mechanical; batched once the module splits settle the file names.
- **Scope:**
  - **MekHQ map links (rule 61).** 35 module headers name a MekHQ counterpart without linking `docs/mekhq-map.md`.
  - **Misplaced comment (rule 82).** It sits at `state.zig:316`.
  - **Wrong citation (rule 84).** "ARCH §9.8 identity" should cite §5, at `state.zig:217`, `commands.zig:52` and `force.zig:144`.
  - **Formula lines too long (rule 75):** `state.zig:1494`, `1513`.
  - **Missing unit in names (rule 81).** The weekly-hour functions don't say they are weekly.
- **Removal:** C20.
- **Guard:** the module-header and comment checks in `verify-contract.sh` for the parts they cover; review for the rest.

---

## Ratchet

The rule 76 ceilings: each module over 1,000 lines and each function over
100, at its size when the contract was adopted, and each non-dispatch
switch with more than ten substantive arms (`path:function#switch`, in
arms). `docs/verify-contract.sh`
fails on anything over its threshold that is not listed, on a listed entry
over its ceiling, and on a listed entry that has dropped under its threshold
(delete it). A split lowers the ceiling in the pull request that makes it.

```ratchet
src/domain/meklab.zig:validate 102
src/main.zig:runDemo 232
src/main.zig:runRepl 295
src/persist/store.zig 2909
src/sim/battle.zig 2261
src/sim/battle.zig:playerSideIn 101
src/sim/battle.zig:resolveEngagement 221
src/sim/checklist.zig:turnWarnings 320
src/sim/cli.zig:errorText 113
src/sim/cli.zig:parseVerb 385
src/sim/commands.zig 4813
src/sim/contract_events.zig 1459
src/sim/contract_events.zig:applyEffectsFor 210
src/sim/contract_events.zig:applyEffectsFor#switch 21
src/sim/contract_market.zig:refresh 121
src/sim/contract_market.zig:refreshBoard 203
src/sim/queries.zig 6252
src/sim/queries.zig:afterAction 116
src/sim/queries.zig:contracts 129
src/sim/queries.zig:hqDetailView 113
src/sim/queries.zig:lab 139
src/sim/queries.zig:ledger 102
src/sim/queries.zig:offerCandidates 108
src/sim/queries.zig:stockTable 102
src/sim/queries.zig:summary 141
src/sim/rating.zig:report 133
src/sim/state.zig 1764
src/sim/tick.zig:runFinances 147
src/tui/app.zig 4060
src/tui/app.zig:drawModal 136
src/tui/app.zig:handleModalKey 192
src/tui/app.zig:listEnter 127
src/tui/app.zig:listView 261
src/tui/app.zig:listView#switch 19
src/tui/png.zig:decode 116
src/tui/screens/forces.zig:handle 173
src/tui/screens/forces.zig:handle#switch 19
src/tui/screens/map.zig:draw 103
src/tui/screens/supply.zig:handle 113
```
