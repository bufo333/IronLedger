# Contract compliance: deviations and deliverables

Every known deviation from `docs/coding-contract.md`, as of the audit of
2026-09-22, broken into pull-request-sized deliverables. Each deliverable
names the contract rule it serves, lists every site with `file:line` at
audit time, and says where the fix lives. Tick items as the PR that
fixes them merges; delete the deliverable when it is empty; delete this
file when it is empty.

Line numbers are from the audit day and drift as PRs land; the rule name
and the symbol are the stable key.

Order matters: each deliverable is a branch stacked on the previous one,
so line numbers in later deliverables assume earlier ones are merged.

---

## D0. One rule for structural needs (PR #3)

- [x] `hq_ops.depotNeeds` / `depotShortfall` / `componentDemand`; Lab lists wrecks; depot, Market, Forces, pool, Lab and REPL `demand` call the one rule.

## D1. Contract and this list (docs only)

- [x] `docs/coding-contract.md`, `CLAUDE.md` summary, pointers in `ARCHITECTURE.md`, `docs/tui.md`, `docs/iron-ledger-zig-guide.md`, this file (PR #4).

---

## D2. Layering inversions and core purity (rules 1, 2, 15, 16) — PR #5

**Sim modules importing the view leaf.** Move the rules down; `queries` calls them.
- [x] `ratingScore` / `ratingIndex` / `ratingPayBp` / `ratingLetter` (queries.zig:2642-2683) → new `src/sim/rating.zig`; callers tick.zig:449, state.zig:680, commands.zig:1838, contract_market.zig:104,152,787 import `rating`. `ratingScore` must take an allocator and propagate errors (today: own arena, `catch return 0`, queries.zig:2653).
- [x] `rateOffer` (queries.zig:565) and its helpers (`bestRating` 631, `boardSkulls` 642, `skullText`) → `src/sim/offer_rating.zig` (battle odds are combat math); checklist.zig:122-131 imports it; `queries` formats its result.
- [x] `manning` (queries.zig:2295) → `personnel.zig` beside `manningNeeds`; checklist.zig:204 imports it.
- [x] hq_ops.zig:714 test import of queries: kept; a test that asserts the screen and the command agree is the contract's own rule 37, so the grep excepts test blocks.

**Global allocator in the core.** Every site takes `gs.allocator()` or a caller arena.
- [x] maintenance.zig:50, :184 (`HourBook.alloc`)
- [x] medical.zig:160, :165 (`patients`)
- [x] commands.zig:1421 (`commitRefit`), :1536 (`freightBetween`)

**Markup below the view layer.**
- [x] person.zig:486-493 `FatigueBand.markup` → a `queries` helper keyed on the band.
- [x] hq_ops.zig:439, :452 repair log strings → plain text; `queries` colours the outcome.
- [x] field_supply.zig:128 plan note → plain text; the Supply query colours it.

**Rules math in floats.**
- [x] planet.zig:29-31 `distanceLy` uses `f64`; store coordinates and distances as integer tenths of a light-year, `jumpsBetween` from the integer.

---

## D3. Entity predicates (rule 8) — PR #6

One predicate each; every listed site calls it.

- [x] `Person.isOnBooks()` (`active or wounded`): personnel.zig:21,56,68,163,184,217; medical.zig:327; battle.zig:580,695; tick.zig:405; contract_control.zig:108; state.zig:882,1669; commands.zig:1090; queries.zig:151,2976,4424; person.zig:282. Decide once whether `.pow` counts (state.zig:1170 says yes, everyone else no).
- [x] `Person.isGone()` (`kia|retired|resigned|released`): queries.zig:2871 and every roster filter.
- [x] `Role.isTech()` used at state.zig:1412, checklist.zig:371, queries.zig:1897; a `Role.isSeatRole()` for checklist.zig:207; `Role.isHallFloorRole()` for contract_market.zig:576-579 (today a third combat-role set that includes astech).
- [x] `Unit.isParked()` (`destroyed or mothballed`): checklist.zig:60,162,187; field_supply.zig:90; battle.zig:133; state.zig:1361,1447; queries.zig:379,2307,3177; contract_events.zig:737; commands.zig:1775; unit.zig:222.
- [x] `Unit.inShop()` (`repairing or refitting`) and `Unit.canFight()` (one definition, decided once for `refitting` and `in_transit`): maintenance.zig:57,191; battle.zig:170; contract_control.zig:29; queries.zig:1145-1176 hangar; contract_events.zig:524 (today misses `destroyed`); commands.zig:1379,1414,1775,1789; queries.zig:2358.
- [x] `GameState.isCompanyHome` everywhere "home" is meant: maintenance.zig:73,194 (live bug: the weekly pass queues depot work for a company afield); medical.zig:84,331,369; checklist.zig:358; commands.zig:724,1603 (redundant `or`), commands.zig:1075 (ignores `return_eta_day`).
- [x] `GameState.companyPosture(force)` returning an enum (`home | deployed | in_transit_out | idle_afield | returning`) with one text helper in queries: queries.zig:395-402, 4279-4298 (`companyStands`, `daysBetweenCompanies`, `daysFromWorld`), 4111-4135, 846-855, 3008, 3050, 1289; main.zig:406-412; app.zig:3305-3310.
- [x] `GameState.personInCompany(person, company)`: the parent-chain walk at battle.zig:249-254, 861-866; medical.zig:377-381; tick.zig:406-410; contract_events.zig:700-705 versus `companyOf(p.assigned_force) == company` at queries.zig:2977, personnel.zig:164, medical.zig:133. One answer.
- [x] `GameState.supportLance(company, kind)`: battle.zig:282-293; medical.zig:338-340; state.zig:1600; queries.zig:826; commands.zig:2109,3551; app.zig:1694.
- [x] `Force.isCombatLance()` (`lance or air_lance`): battle.zig:130,157; personnel.zig:268; state.zig:740; contract_events.zig:722; commands.zig:726,967; app.zig:3264,3958.
- [x] `PartOrder.inFlight()` (`sourcing or in_transit`): field_supply.zig:144,154; hq_ops.zig:147; tick.zig:219; commands.zig:1666; queries.zig:2079,2256,3563; and the three sites that count only `in_transit` and so disagree: main.zig:583,639; commands.zig:1503.
- [x] `Contract.isRunning()` (`active or transit`): contract_control.zig:136; contract_events.zig:516; state.zig:1157; commands.zig:1879; decide whether `.transit` counts at contract_control.zig:74,171,226; tick.zig:371; battle.zig:37; contract_events.zig:210,322.
- [x] `Outcome.isLoss()` / `Outcome.heldField()`: battle.zig:410,530,661,678.
- [x] transport-crewed predicate: contract_events.zig:238, battle.zig:554.

---
- Left as deliberate single-site filters: queries.zig raise candidates (`destroyed or in_transit`: mothballed hulls are wanted there) and the AAR casualty count in battle.zig (`wounded or kia`).

## D4. One computation, one function (rules 7, 10, 12) — PR #7

- [x] `logistics.daysBetween(a, b)` with one same-world floor: today 3 days at contract_control.zig:212, battle.zig:796, commands.zig:1897, queries.zig:497,503,4143; 0 days at commands.zig:846, queries.zig:2380; `@max(3,…)` at state.zig:1135; no floor at queries.zig:4291,4298, commands.zig:1369. `offerTransitDays` (queries.zig:488) becomes a call.
- [x] `logistics.ly_per_jump` used instead of literal `30`: planet.zig:36, commands.zig:1893, queries.zig:502,4139.
- [x] `companyMunitionFamilies(gs, company)` in field_supply.zig; battle.zig:128-143, field_supply.zig:88-97, checklist.zig:56-68 (`companyFires`), queries.zig:1528-1547 (`neededMunitions`) call it.
- [x] `companyCrewStats(gs, company)` (headcount, average fatigue, average morale, one membership test): battle.zig:242-262; medical.zig:371-387; queries.zig:385-392, 2971-2991; state.zig:1164-1180.
- [x] `Person.addMorale(delta)` and `Person.applyFatigue` used everywhere: personnel.zig:22,71; battle.zig:639,868,870; contract_events.zig:441,448,476,603,708; medical.zig:342,350,355.
- [x] Cool-Under-Fire halving once: personnel.zig:22 and battle.zig:868.
- [x] `hullUpkeep(gs)` once: tick.zig:476-477, contract_market.zig:651-655, main.zig:869-874, queries.zig:1231-1233; and the 30-day forecast (queries.zig:966-979) includes it (live omission).
- [x] `hq_ops.activeJobs` used by queries.zig:271-274, 1849-1852, 3529-3533 (decide once whether "started but undated" counts).
- [x] `field_supply.inboundTons` once: commands.zig:1500-1505 calls it (live bug: resupply sizes a load the room check rejects).
- [x] `part.provisionsPerDay(heads)` (divCeil, floor 1) used at field_supply.zig:59, tick.zig:328,553, queries.zig:1491, main.zig:571-573.
- [x] Ransom table once: contract_events.zig:456-461 calls `ransomPrice` (583-591); `missingRansom` (queries.zig:1107) calls it.
- [x] Kill estimate once: personnel.zig:199 and battle.zig:630.
- [x] `finance.isInsolvent(gs)`: checklist.zig:113-114 and commands.zig:1989.
- [x] HQ admin-desk table once (`hq.zig`): checklist.zig:267-272, contract_market.zig:489-494, state.zig:651-657.
- [x] `company_gen` staffing ratios call `personnel.manningNeeds`: company_gen.zig:152-158 versus personnel.zig:139-154; drop the "mirrors" comments at personnel.zig:107-109 and queries.zig:2293.
- [x] Hiring-hall candidate creation once with one expiry: contract_market.zig:551-560, 586-595, 624-632.
- [x] `market.HullCondition.label()` is the only cascade: queries.zig:2384.
- [x] Hangar "why" cascade once: queries.zig:1145-1172 and 1190-1191.
- [x] Checklist restlessness warning calls the medical turnover rule: checklist.zig:149-153 versus medical.zig:272-281.
- [x] Stock-policy "restock under way" once: tick.zig:213-224 and queries.zig:2077-2084.
- [x] Dead mirrors deleted or wired: market.zig:12-18 `RefreshCadence` (tick.zig:43,51,361 inline instead), logistics.zig:122-128 `daily_consumption`.

---

## D5. Ledgers (rule 11) — PR #8

- [x] `hq_ops.spareDemand(gs, site)` mirroring `componentDemand` for field spares: one need definition (destroyed or missing, field tier), one stock scope (the hull's site), `PartOrder.inFlight()` for coming. Callers: Market DEMAND gear rows (queries.zig:2236-2266, today counts damaged and sums every HQ), Lab mount notes (queries.zig:3556-3568), `replaceGear` (commands.zig:1657-1670), maintenance.zig:205, REPL `demand` (main.zig:611-650).

---

## D6. Numbers appear once (rule 9) — D6a literals PR #9, D6b tables PR #10, D6c residue pending

**Duplicated literals → one named constant.**
- [x] `/25` depot labour: hq_ops.zig:182, :237 → `tuning.hq_ops.depot_labour_divisor`.
- [x] `70` "shot up" condition: queries.zig:1170, :1191.
- [x] morale bands `30`/`50`: queries.zig:3004, 3048, 4148 → `tuning.person`.
- [x] effectiveness `50`/`75`: contract_control.zig:228 versus queries.zig:805-806; grade thresholds `50`/`25`: contract.zig:290-292 versus contract_control.zig:102,120.
- [x] score→VP `× 5`: contract_control.zig:57, battle.zig:675, contract_events.zig:416.
- [x] salvage haul: queries.zig:813-836 calls the battle.zig:534-540 function; drop the `// TUNE mirrors battle.zig` comment.
- [x] repair-bill guess queries.zig:2383 → `hq_ops.rebuildEstimate` on the listing's condition.
- [x] `/600` (contract_market.zig:657,663) and `/2_500` (maintenance.zig:128) → one maintenance-estimate function.
- [x] `30` days per month: contract_control.zig:75,137; tick.zig:375; person.zig:234; commands.zig:2551 → `clock.days_per_month`.
- [x] `365`: person.zig:251, state.zig:503, store.zig:1360, queries.zig:2489 → `clock.days_per_year`.
- [x] full severance `10_000`: medical.zig:266, contract_events.zig:565, commands.zig:1091 → `tuning.person.fire_severance_bp` or a named "full".
- [x] fatigue `60`, morale `45`, `50`, rested `10`: medical.zig:343,348,357,359,387 → `tuning.person`.
- [x] `25` crew per doctor, `× 6` astechs, `× 4` medics, `/10` admins: company_gen.zig:47-54 → `tuning.staffing` shared with `manningNeeds`.
- [x] iron_man `@max(3, days*3/4)`: medical.zig:216 → `tuning`.
- [x] `2_000`-class market condition curve: market.zig:189,191.

**Tuning tables in code → `data/tables/tuning.zon`.**
- [x] autoresolve.zig:56-74 (skill steps, supply penalties, fatigue and morale scales, support bonuses).
- [x] battle.zig:401-422 outcome→loss tables, 461-477 severity thresholds, 499 wound cuts, 513 MASH, 665-686 score and morale.
- [x] maintenance.zig:19-21 repair hours, 74-76 targets, 203/209 part-cost shares, 226-227 armour and flat cost.
- [x] contract_market.zig:195-207 term rolls, :470 expiry.
- [x] domain values moved: contract enemy strength and pool, person permanent penalty, force air lances, unit maintenance hours, part fabrication days and provisions; commander marker was stale
- [x] **D6c (PR #20):** the `hq.zig` tables — staff base per tier, staff per facility level, finance share, understaffing steps, lance and support-lance caps, per-tier capacity rows, support-lance facility needs, refit class caps — live in `tuning.hq` (`StaffRow`/`CapacityRow` tables may hold zeros; the positivity check skips `.staff_base.` and `.capacity_` paths). Formula constants moved: bay accident base days and injury severity days (`tuning.maintenance`), HR morale bonus, recruit HR threshold and the astech team rate (`tuning.person`), reputation-by-VP and standing-by-VP (`tuning.contract`), RAT weight bands (`tuning.generation`), staple keys, hull-condition roll bands and the hall asking bonus (`tuning.market`). Markers that named no number (autoresolve flags, training drill, load-out, heal scaling, wound placement) became plain comments. `grep -rn '// TUNE' src` now finds only the tuning.zig doc line.

---

## D7. Formatting helpers (rule 12) — PR #11

- [x] `clock.dateText(alloc, date)`: main.zig:948, state.zig:900, queries.zig:160,2489, store.zig:310, app.zig:4004.
- [x] One person-name helper family (`rankedName`, `shortName`), used by every log line: three helpers (person.zig:367, queries.zig:108, main.zig:649) plus inline `first last` at medical.zig:70,207,241,267,300,305; contract_events.zig:443,450,464,469,478,481,488,507,510,566,575,612,689; checklist.zig:348; queries.zig:248,3061,3063,3065.
- [x] `types.bpText` (×1.47) and `types.bpPercent`: difficulty.zig:53-58 is the home; queries.zig:475-479, 2422-2426; app.zig:1180; `@divTrunc(bp,100)` at personnel.zig:75, queries.zig:2772,3137, app.zig:3616,3665,3682.
- [x] fatigue/morale colour bands once in queries: queries.zig:3003-3004, 3043-3048, 4147-4148.

---
- The REPL printers in `src/main.zig` still spell `first last` in six `debug.print` lines; D10 replaces those printers with query loops.

## D8. Commands leave state consistent; the store stores (rules 27, 3, 13) — PR #12

- [x] `.fire` (commands.zig:374-380) and `.transfer_person` (:538-554): clear `posted_hq`, call `refreshHqStaffing`; drop the TUI patch at app.zig:2497.
- [x] `.hire`, `.recruit`, `.hire_candidate` (commands.zig:366-373, 1178-1192): refresh staffing for symmetry with `staffHqToRequirement` (state.zig:667).
- [x] `.disband_company` (commands.zig:1072-1103): remove its `supply_policies` and `policies` rows, cancel `part_orders` with `dest = company`, drop `unit_transfers` to it, refresh staffing.
- [x] `.sell_hq` (commands.zig:1039-1071): remove `stock_policies` and `policies` for the HQ, cancel or re-home in-flight `part_orders`, re-home units with `berth_hq` and forces with `supplying_hq`; tick.zig:212 stops hiding orphans with `orelse continue`.
- [x] `committed_bv` after `.sell_unit`, `.strip_unit`, `.transfer_unit`, `.mothball`: either refuse mid-tour or warn; decide and document at contract_control.zig:222-245.
- [x] Stats book maintained at the source, not rebuilt by parsing `[AAR]` log text: state.zig:305-340 `rebuildStatsFromLog`, store.zig:1343-1344.
- [x] Turnover tracked in a field, not by scanning log text: checklist.zig:281-288.
- [x] Migrations call the sim's rule functions instead of re-encoding them: store.zig:1363-1371 (light wound stand-in, versus medical.zig:219), 1353-1361 (birthday, versus state.zig:503).
- [x] Unreadable enum columns fail the load instead of inventing state: store.zig:823,825,837,912,948,1043,1079,1274.
- [x] Derived `hq.staff_assigned` not read back (store.zig:49,504,989; recomputed at 1339 anyway).

---
- Notes: the departed keep their posting on the record (`departed_day` is the new fact, schema v25); `tick.runStockPolicies` keeps a defensive skip for rows from older saves; the hire paths do not post, so `postToHq` is the one refresh on that side; the staffing column is still written for older readers but never read back.

## D9. Rules that live only in queries move down (rule 13) — PR #13

- [x] `intelLevel` / `lanceIntel` (D2: `sim/offer_rating.zig`) (queries.zig:508,521) → `opfor.zig` or `battle.zig`.
- [x] `offerCandidates` readiness score (`personnel.readinessPenalty`, weights in tuning.person) and `readiness` bands (D6a/D7 helpers) (queries.zig:4143) and `readiness` bands (2947) → `personnel.zig`.
- [x] `upgrades` eligibility (`hq_ops.upgradeBlock`, checked by the command before it debits; "next level buys" from tuning) and what each level buys (queries.zig:1991) → `hq_ops.zig` / `hq.zig`.
- [x] `severanceOwed` (`personnel.severanceOwed`, the function `depart` pays from) (queries.zig:2827) → the same function `.fire` pays from.
- [x] `isBlocking` (`checklist.WarningKind.blocking`); `jumpFor` stays in queries as the screen mapping it is (queries.zig:175,212) → `checklist.zig` as fields on the warning.
- [x] `installLocations` (`GameState.tryInstall` is the trial validation); `installCandidates` is a catalogue listing (queries.zig:3386,3416) → `meklab.zig`; `refit_install` validates with the same function.
- [x] `raiseCandidates`: its filters (mek listings, pool meks) are the wizard's presentation choice; the purchase rule stays in `buy_hull_for` (queries.zig:2352) → `commands` eligibility shared with `.raise_*`.
- [x] `berths` / `liftText` already read `commands.planLift`; display only (queries.zig:2396,2416) → `logistics.zig`.
- [x] `isStaple` (`market.isStaple`) (queries.zig:2275) → `market.zig`.
- [x] `holdsPrisonerOf`, `contractsWorkedAt`, `isUnassigned` on `GameState`; `crewChoices` dims on `GameState.assignBlock` and `companyChoices` on `commands.transferBlock`, the same answers the commands refuse with; `partChoices` and `hqChoices` are listings (queries.zig:1118,3348,2835,4529,4410,4305,4380): the eligibility half moves beside the command that consumes the choice; the query keeps the text.
- [x] `companyDamage` structure text (queries.zig:1353) already calls `depotNeeds`; keep, but its gear half calls `spareDemand` (D5).

---

## D10. REPL printers become query loops (rule 14) — PR #14

Every `print*` in `src/main.zig` that walks `GameState` (59 sites) is a loop over the query named here; the four already on queries stay.
- [x] `printLab` :326 → `queries.lab`
- [x] `printContracts` :387 → `queries.contracts`; its inline warnings (:398-414) → `checklist.turnWarnings`
- [x] `printHqs` :417 → `queries.hqDetail` + `upgrades`
- [x] `printOffers` :444 → `queries.contracts` board rows
- [x] `printToe` :467, `printForce` :488, `forceBv` :514 → `queries.toe` / `toeFiltered`
- [x] `printSupplies` :552, `printStockLines` :588 → `queries.supply` / `stockTable`; provisions math (:565-578) gone
- [x] `printDemand` :599 → `componentDemand` + `spareDemand` (D5)
- [x] `personName` :649 (leaks) → D7 helper
- [x] `printCompanyRoster` :656 → `queries.manning` + `toeFiltered` + `crewChoices`
- [x] `printHqRoster` :704, `printBays` :777, `printProjects` :797, `printStaff` :816 → `queries.hqDetail`
- [x] `printMedbay` :732 → `queries.people(.wounded)`
- [x] `printChecklist` :766 → `queries.desk`
- [x] `printInbox` :839 → `queries.desk` inbox rows
- [x] `printLog` :874 → `queries.logRow`
- [x] `printTreasuries` :888, `treasuryName` :908 → `queries.allTreasuries` / `treasuryLabel`
- [x] `printPnl` :930 → `queries.ledger`
- [x] `printStatus` :945 → `queries.status`
- [x] `printRoster` :953 → `queries.people`
- [x] `printCampaigns` :59, `printResult` :1275, `runDemo` :76, `runRepl` :972: keep as application code, but their state reads move to queries or `Result` fields: runDemo :105-126 (offers, contracts), :238 (listings), :301-311 (units, spares); printResult :1281 (contracts), :1288 (person), :1300-1305 (orders, log).
- [x] `parseTreasury` (~925) and `parseSite` (~833) are a second token parser → `cli.parseSite` / `cli.parseTreasury` (rule 6).
- [x] `page_allocator` in main.zig printers (:60, :337, :527, :541, :602, :651, :859) → one REPL arena.
- [x] `totalHullUpkeep` :867 → `state.monthlyHullUpkeep()` surfaced on `queries.status` (D4).
- [x] `printMedbay` :742 `doctors * 25` → `medical.doctorCover()`.
- [x] New queries the REPL needs and the TUI will share: `hqList`, `bays`, `projects`, `backOffice`, `companyRoster`, `medbay`, `log(n, filter)`, `hqLinks`.
- [x] 11 raw `{d} c-bills` prints → `queries.money`.

---
- Notes: every console view is a loop over a query (`hqList`, `hqCompanies`, `hqLinks`, `bays`, `projects`, `backOffice`, `companyRoster`, `hqRoster`, `medbay`, `logLines`, `listings`, `spareLines`, `orders`, `ledgerLines`, `pnlLines`, `contractLines`, `demandLines`, `inboxLines`, `hallAll`, plus one-line echoes); the demo script reads offers, decisions, mounts and listings through queries too. `printResult` reads only `Result` fields and echo queries. The only state reads left in `main.zig` are the save/load messages and the fresh-campaign seed. The demo runs to its golden-master hash again (it had been failing on a courier the treasury could not cover; the transfer is now reported, not fatal, and resupply orders only while on station).

## D11. TUI boundary (rules 3, 4, 5, 26) — done (PR #15)

Baseline was 61 field reads, 70 method calls, 41 module imports in
`src/tui/app.zig`. After D11 the Section 1 greps print nothing: the client
reads through `queries`, parses through `cli`, mutates through
`commands.execute`, and reaches persistence through `persist/lobby.zig`.
Whitelisted type imports (command payloads and the session handle):
`game.types`, `game.state.GameState` (opaque handle), `game.state.Treasury`,
`game.commander.Faction`/`Profession`, `game.force.SupportLanceKind`,
`game.force.Roe`, `game.force.LanceRole`, `game.contract.NegotiableTerm`.

**D11a. Display reads → query fields.**
- [x] `Status` gains `outfit_name`, `funds_cbills`, `payroll`, `bankrupt`, `saved`, `offers`.
- [x] `backOffice` rows gain `pay` and `effect`; the wizard's office pane and review line read them; `office_roles` deleted.
- [x] `hqList` drives the HQ screen title, `[ ]` counts and `hqSelId`; `firstHq` for the wizard.
- [x] `World.standing`; `worldDetail(view, world)` renders the WORLD pane; `factionRows`, `factionKeyLine`, `factionColour`; `App.factionLegend` deleted.
- [x] `supportTrain(company)` (rows carry `kind`, `key`, `name`, `owned`, `price`, `note`, `text`, plus `capacity_tons`); the note text lives on `SupportLanceKind.describe()`, the hull key on `SupportLanceKind.hullKey()`.
- [x] `raiseLances(company)` rows `{id, name, used, cap, full}`.
- [x] `lanceChoices(unit)`; `App.lanceChoices`/`lancesOf` deleted.
- [x] `ToeRow` gains `company`, `name`, `is_company`, `is_lance`, `mothballed`.
- [x] `ListingRow.transport`, `OfferRow.negotiated`, `PickRow.on_hand`, `PersonRow.primary_skill`, `RaiseCand.key`, `MountRow.part_key`.
- [x] `sellQuote`, `hqSaleQuote`, `disbandQuote` for the confirm bodies.
- [x] `TreasuryRow.balance`, `balance(treasury)`, `creditRemaining`, `oldestLoanBalance`, `supplyPolicyFor`.
- [x] `settings()` `{auto_admit, difficulty_name, difficulty_blurb, multipliers, shares_pct}`.
- [x] `cli.completionPool(gs)` replaces the TUI's own pool.
- [x] one-offs: `outfitEmblem`, `offerTerms`, `defaultSite`, `homeHq`, `stockCount`, `companyStanding`, `hqWithCompanySlot`.

**D11b. Rule decisions → commands (the TUI stops pre-checking).**
- [x] lance-full pre-check deleted (`move_unit`/`buy_hull_for` refuse).
- [x] recall pre-checks deleted: `recall_idle` returns `AlreadyHome` / `UnderContract`.
- [x] market till pre-check deleted: `buy_listing` returns `HqTreasuryShort` / `CompanyFundsShort` before debiting.
- [x] tier pre-check deleted: `upgrade_tier` returns `MaxLevel` for a regional HQ (no separate `NotAFieldHq`).
- [x] new commands: `buy_support_hull`, `set_outfit_emblem`, `set_office_staff`, `ship_components_home`, `replace_mount`, `cover_shortfall` (returns `fabricated`), `toggle_mothball`, `cycle_roe`, `cycle_role`, `cycle_difficulty`, `adjust_shares_pct`, `toggle_auto_admit`, `recall_idle`. The "which HQ hosts a new company" rule is `hq_ops.hqWithCompanySlot`, shared by `new_company` and the Forces `+` key (no `raise_company` change needed).
- [x] `advance` reports through `Result.days_advanced`; bankruptcy through `Status.bankrupt`. `transfer_unit` returns `in_transit`; `depot` and `replace_mount` return the HQ.
- [x] every new command has its `cli.zig` verb, help line and error sentence.

**D11c. Persistence facade.**
- [x] `src/persist/lobby.zig` (`Lobby`: `open/close/players/campaigns/allCampaigns/createPlayer/deletePlayer/deleteCampaign/getSetting/setSetting/save/load`; `newSession`, `discard`, `schema_version`, `dataProvenance`); `app.zig` and the REPL use it; `game.store` is gone from both frontends.

Leftover for D12: `game.state.Treasury` and the `GameState` handle stay as
whitelisted imports; the help modal indexes its legend row by number
(`contracts_row`) instead of sniffing markup.

## D12. TUI structure (rules 18-25)

**D12a — done (PR #16).**
- [x] **`execSay`** (rule 20): `exec` returns whether the command ran; `execSay(cmd, style, fmt, args)` says the refusal or the success line. Every `exec` site uses one or the other; no caller reads `msg_style`. The `msg.len == 0` at the music "now playing" line is not an exec guard (it yields to whatever the status line already says).
- [x] **shared confirm** (rule 19): `Modal.confirm = {kind, id}` with `confirmSpec` (title, rows, size, command, past-tense line, optional second verb) and `afterConfirm`; covers fire, sell/strip hull, sell HQ, disband, and the new breach-recall confirm on the Contracts screen. The three flow dialogs (end turn, quit, game over) draw through `dialog(title, rows, w, h)`.
- [x] **`clampIdx` and `openModal`** (rule 23): every cursor and `_sel` clamp goes through `clampIdx` (past the end lands on the last row, as the helpers always did; the `_sel` fields no longer jump to 0); `openModal` resets the cursor at every modal opening. `supply_ship_to` folded into the `pick_part` payload; `focus_scroll` is a pane index, not a pointer. `raise.passed` stays: it is the player's own "passed on" list, revalidated against `RaiseCand.key` each frame.
- [x] **`layout.zig`** (rule 21): `narrow_cols`/`wide_cols`/`emblem_cols` with `narrow/wide/extraWide`, rational `Ratio` splits (`major`, `minor`, `list`, `half`, `quarter`, `two_thirds`, `three_quarters`, and the per-screen shares), and `layout.modal.*` sizes for all 30 modals. Contracts' wide threshold moved from 140 to `wide_cols` (150). `modalRect` keeps the 2-column margin once.
- [x] `term.zig` and `layout.zig` are in the test block (D13 item).

**D12b — done (PR #17).**
- [x] **shared list widget** (rule 19): `ListView` (title, head, rows or table, foot, pick count, offset, read-only, scroll, empty text, size) built by `listView` per modal kind; `drawList` draws every one; `listKey` handles the shared keys (cursor, column scroll, Enter, Esc, any-key-closes for sheets) and defers to `listEnter`, `listEscape` and `listExtra` for the kind-specific parts. Twenty draw arms and seventeen key arms became one arm each: `raise_hulls`, `raise_support`, `seat`, `emblem`, `install_part`, `install_loc`, `upgrade`, `lance_pick`, `accept_pick`, `negotiate`, `music`, `decision`, the five generic pickers, and the sheets `hull`, `record`, `summary`, `readiness`, `raise_crews`, `contract_log`, `help`. `drawPick` folded in. The negotiation terms live in one table ordered like `NegotiableTerm`.
- [x] **text form**: `input` was already one arm for every prompt kind and stays the shared form. `settings` keeps its own list-with-adjust arm (←/→ adjust a row, Enter acts); it is one arm, not a copy.
- [x] **markup tag set once** (rule 16): `table.marks` is the declaration, `table.isMark` the test; `screen.visibleLen` is `table.cells`; `Style.fromMarkup` is checked against `table.marks` by a test.
- [x] **escape sequences in `term.zig`** (rule 24): `term.sgr.*`, `cursorHome`, `cursorTo`, `resetStyle`, `paintPair` (24-bit or the 256 cube); `screen.zig` carries no `\x1b`.

**D12c — table done (PR #19); file split pending.**
- [x] **screens table** (rule 18): `ScreenSpec {tab, draw, move, enter, key, panes, narrow_panes, footer}` and `screen_table` in `Tab` order (checked at comptime). `drawGame`, `paneCount`, `screenMove`, `screenEnter` and `screenKey` read the table; the six `switch (self.tab)` are gone (`grep -c 'switch (self.tab)' src/tui/app.zig` → 0). Each screen's move/enter/key body is its own function (`deskMove`, `deskEnter`, `deskKey`, …); `mapMove(dx, dy)` became `mapPan`.
- [ ] move each screen's five functions and its private helpers into `src/tui/screens/<tab>.zig` (the App helpers they call become `pub`); `drawWizard` into per-step functions.
- [ ] **one key table per screen** (rule 22): the footers are in `screen_table`; pane right-titles, modal titles, help rows and in-pane hints still carry their own key text; `docs/tui.md` key table generated or checked by the smoke.

## D13. Tests and CI (rules 37-40)

- [x] `term.zig` (and `layout.zig`) added to the test block in `src/main.zig` (PR #16).
- [x] The emblem-editor smoke step (tui_smoke.py ~236-242) was timing-flaky: it now waits for text (`wait_for`) instead of sleeping (PR #8).
- [ ] Smoke coverage: delete-player and delete-campaign confirms, disband and sell-HQ confirms, game-over path, music modal, resize, the 80-120 column boundary, `←/→` column scrolling on each table screen, every refusal branch of a confirm.
- [ ] `.github/workflows/ci.yml`: `zig build test --summary all` plus both smokes on push and pull request.
- [ ] Golden-master hash test (rule 40) if not already present.
