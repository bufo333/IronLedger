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

## D6. Numbers appear once (rule 9)

**Duplicated literals → one named constant.**
- [ ] `/25` depot labour: hq_ops.zig:182, :237 → `tuning.hq_ops.depot_labour_divisor`.
- [ ] `70` "shot up" condition: queries.zig:1170, :1191.
- [ ] morale bands `30`/`50`: queries.zig:3004, 3048, 4148 → `tuning.person`.
- [ ] effectiveness `50`/`75`: contract_control.zig:228 versus queries.zig:805-806; grade thresholds `50`/`25`: contract.zig:290-292 versus contract_control.zig:102,120.
- [ ] score→VP `× 5`: contract_control.zig:57, battle.zig:675, contract_events.zig:416.
- [ ] salvage haul: queries.zig:813-836 calls the battle.zig:534-540 function; drop the `// TUNE mirrors battle.zig` comment.
- [ ] repair-bill guess queries.zig:2383 → `hq_ops.rebuildEstimate` on the listing's condition.
- [ ] `/600` (contract_market.zig:657,663) and `/2_500` (maintenance.zig:128) → one maintenance-estimate function.
- [ ] `30` days per month: contract_control.zig:75,137; tick.zig:375; person.zig:234; commands.zig:2551 → `clock.days_per_month`.
- [ ] `365`: person.zig:251, state.zig:503, store.zig:1360, queries.zig:2489 → `clock.days_per_year`.
- [ ] full severance `10_000`: medical.zig:266, contract_events.zig:565, commands.zig:1091 → `tuning.person.fire_severance_bp` or a named "full".
- [ ] fatigue `60`, morale `45`, `50`, rested `10`: medical.zig:343,348,357,359,387 → `tuning.person`.
- [ ] `25` crew per doctor, `× 6` astechs, `× 4` medics, `/10` admins: company_gen.zig:47-54 → `tuning.staffing` shared with `manningNeeds`.
- [ ] iron_man `@max(3, days*3/4)`: medical.zig:216 → `tuning`.
- [ ] `2_000`-class market condition curve: market.zig:189,191.

**Tuning tables in code → `data/tables/tuning.zon`.**
- [ ] autoresolve.zig:56-74 (skill steps, supply penalties, fatigue and morale scales, support bonuses).
- [ ] battle.zig:401-422 outcome→loss tables, 461-477 severity thresholds, 499 wound cuts, 513 MASH, 665-686 score and morale.
- [ ] maintenance.zig:19-21 repair hours, 74-76 targets, 203/209 part-cost shares, 226-227 armour and flat cost.
- [ ] contract_market.zig:195-207 term rolls, :470 expiry.
- [ ] the 21 `// TUNE` values still in `src/domain/*` (hq.zig ×6, part.zig ×2, unit.zig, person.zig, force.zig, commander.zig, contract.zig ×2, and the rest listed by `grep -rn '// TUNE' src/domain`).

---

## D7. Formatting helpers (rule 12)

- [ ] `clock.dateText(alloc, date)`: main.zig:948, state.zig:900, queries.zig:160,2489, store.zig:310, app.zig:4004.
- [ ] One person-name helper family (`rankedName`, `shortName`), used by every log line: three helpers (person.zig:367, queries.zig:108, main.zig:649) plus inline `first last` at medical.zig:70,207,241,267,300,305; contract_events.zig:443,450,464,469,478,481,488,507,510,566,575,612,689; checklist.zig:348; queries.zig:248,3061,3063,3065.
- [ ] `types.bpText` (×1.47) and `types.bpPercent`: difficulty.zig:53-58 is the home; queries.zig:475-479, 2422-2426; app.zig:1180; `@divTrunc(bp,100)` at personnel.zig:75, queries.zig:2772,3137, app.zig:3616,3665,3682.
- [ ] fatigue/morale colour bands once in queries: queries.zig:3003-3004, 3043-3048, 4147-4148.

---

## D8. Commands leave state consistent; the store stores (rules 27, 3, 13)

- [ ] `.fire` (commands.zig:374-380) and `.transfer_person` (:538-554): clear `posted_hq`, call `refreshHqStaffing`; drop the TUI patch at app.zig:2497.
- [ ] `.hire`, `.recruit`, `.hire_candidate` (commands.zig:366-373, 1178-1192): refresh staffing for symmetry with `staffHqToRequirement` (state.zig:667).
- [ ] `.disband_company` (commands.zig:1072-1103): remove its `supply_policies` and `policies` rows, cancel `part_orders` with `dest = company`, drop `unit_transfers` to it, refresh staffing.
- [ ] `.sell_hq` (commands.zig:1039-1071): remove `stock_policies` and `policies` for the HQ, cancel or re-home in-flight `part_orders`, re-home units with `berth_hq` and forces with `supplying_hq`; tick.zig:212 stops hiding orphans with `orelse continue`.
- [ ] `committed_bv` after `.sell_unit`, `.strip_unit`, `.transfer_unit`, `.mothball`: either refuse mid-tour or warn; decide and document at contract_control.zig:222-245.
- [ ] Stats book maintained at the source, not rebuilt by parsing `[AAR]` log text: state.zig:305-340 `rebuildStatsFromLog`, store.zig:1343-1344.
- [ ] Turnover tracked in a field, not by scanning log text: checklist.zig:281-288.
- [ ] Migrations call the sim's rule functions instead of re-encoding them: store.zig:1363-1371 (light wound stand-in, versus medical.zig:219), 1353-1361 (birthday, versus state.zig:503).
- [ ] Unreadable enum columns fail the load instead of inventing state: store.zig:823,825,837,912,948,1043,1079,1274.
- [ ] Derived `hq.staff_assigned` not persisted (store.zig:49,504,989; recomputed at 1339 anyway).

---

## D9. Rules that live only in queries move down (rule 13)

- [ ] `intelLevel` / `lanceIntel` (queries.zig:508,521) → `opfor.zig` or `battle.zig`.
- [ ] `offerCandidates` readiness score (queries.zig:4143) and `readiness` bands (2947) → `personnel.zig`.
- [ ] `upgrades` eligibility and what each level buys (queries.zig:1991) → `hq_ops.zig` / `hq.zig`.
- [ ] `severanceOwed` (queries.zig:2827) → the same function `.fire` pays from.
- [ ] `isBlocking` / `jumpFor` (queries.zig:175,212) → `checklist.zig` as fields on the warning.
- [ ] `installCandidates` / `installLocations` (queries.zig:3386,3416) → `meklab.zig`; `refit_install` validates with the same function.
- [ ] `raiseCandidates` (queries.zig:2352) → `commands` eligibility shared with `.raise_*`.
- [ ] `berths` / `liftText` (queries.zig:2396,2416) → `logistics.zig`.
- [ ] `isStaple` (queries.zig:2275) → `market.zig`.
- [ ] `holdsPrisonerOf`, `contractsWorkedAt`, `isUnassigned`, `partChoices`, `crewChoices`, `companyChoices`, `hqChoices` (queries.zig:1118,3348,2835,4529,4410,4305,4380): the eligibility half moves beside the command that consumes the choice; the query keeps the text.
- [ ] `companyDamage` structure text (queries.zig:1353) already calls `depotNeeds`; keep, but its gear half calls `spareDemand` (D5).

---

## D10. REPL printers become query loops (rule 14)

Every `print*` in `src/main.zig` that walks `GameState` (59 sites) is a loop over the query named here; the four already on queries stay.
- [ ] `printLab` :326 → `queries.lab`
- [ ] `printContracts` :387 → `queries.contracts`; its inline warnings (:398-414) → `checklist.turnWarnings`
- [ ] `printHqs` :417 → `queries.hqDetail` + `upgrades`
- [ ] `printOffers` :444 → `queries.contracts` board rows
- [ ] `printToe` :467, `printForce` :488, `forceBv` :514 → `queries.toe` / `toeFiltered`
- [ ] `printSupplies` :552, `printStockLines` :588 → `queries.supply` / `stockTable`; provisions math (:565-578) gone
- [ ] `printDemand` :599 → `componentDemand` + `spareDemand` (D5)
- [ ] `personName` :649 (leaks) → D7 helper
- [ ] `printCompanyRoster` :656 → `queries.manning` + `toeFiltered` + `crewChoices`
- [ ] `printHqRoster` :704, `printBays` :777, `printProjects` :797, `printStaff` :816 → `queries.hqDetail`
- [ ] `printMedbay` :732 → `queries.people(.wounded)`
- [ ] `printChecklist` :766 → `queries.desk`
- [ ] `printInbox` :839 → `queries.desk` inbox rows
- [ ] `printLog` :874 → `queries.logRow`
- [ ] `printTreasuries` :888, `treasuryName` :908 → `queries.allTreasuries` / `treasuryLabel`
- [ ] `printPnl` :930 → `queries.ledger`
- [ ] `printStatus` :945 → `queries.status`
- [ ] `printRoster` :953 → `queries.people`
- [ ] `printCampaigns` :59, `printResult` :1275, `runDemo` :76, `runRepl` :972: keep as application code, but their state reads move to queries or `Result` fields: runDemo :105-126 (offers, contracts), :238 (listings), :301-311 (units, spares); printResult :1281 (contracts), :1288 (person), :1300-1305 (orders, log).
- [ ] `parseTreasury` (~925) and `parseSite` (~833) are a second token parser → `cli.parseSite` / `cli.parseTreasury` (rule 6).
- [ ] `page_allocator` in main.zig printers (:60, :337, :527, :541, :602, :651, :859) → one REPL arena.
- [ ] `totalHullUpkeep` :867 → `state.monthlyHullUpkeep()` surfaced on `queries.status` (D4).
- [ ] `printMedbay` :742 `doctors * 25` → `medical.doctorCover()`.
- [ ] New queries the REPL needs and the TUI will share: `hqList`, `bays`, `projects`, `backOffice`, `companyRoster`, `medbay`, `log(n, filter)`, `hqLinks`.
- [ ] 11 raw `{d} c-bills` prints → `queries.money`.

---

## D11. TUI boundary (rules 3, 4, 5, 26)

Baseline: 61 field reads, 70 method calls, 41 module imports in `src/tui/app.zig`. Every site below is replaced by a query field, a command, or the persistence facade. Whitelisted type imports (command payloads): `game.types`, `game.state.Treasury` (:29), `game.commander.Faction`/`Profession` (:181-182), `game.force.SupportLanceKind` (:1689,1699), `game.force.Roe` (:3255), `game.force.LanceRole` (:3268-3269), `game.contract.NegotiableTerm` (:4201).

**D11a. Display reads → query fields.**
- [ ] `queries.status` gains `outfit_name`, `funds_cbills`, `payroll`, `bankrupt`, `next_day`, `offers`, `hull_upkeep`: app.zig:879, 1336, 1830, 2118, 1815, 849, 3046, 3345, 3997, 4004, 803.
- [ ] new `queries.backOffice(hq)` rows `{role, have, need, pay, effect, short}`: app.zig:770, 775, 803, 827, 840; delete the `office_roles` list at app.zig:167 (duplicate of main.zig:823).
- [ ] new `queries.hqList()` rows `{id, name, tier, world, ring_ly, funds, staff, required, companies, cap, title_line}`: app.zig:1725, 1730, 1735, 2461, 2983, 2992, 3442, 3972.
- [ ] `queries.World` gains `standing`, `standing_band`, `pay_mult_text`, `faction_name`, `capital_line`; new `worldReach(key)` and `factionTable()`; `factionColour(key)`: app.zig:1128, 1174, 1176-1187, 1219, 1236; delete `App.factionLegend` 1248-1260 (duplicate of queries.zig:671).
- [ ] new `queries.supportTrain(company)` rows `{key, name, owned, price, note, capacity_tons}`; the `support_lines` table (app.zig:1699) moves to data: app.zig:1884, 1888, 1890, 1891, 1895, 1901.
- [ ] new `queries.raiseLances(company)` rows `{id, name, used, cap, full}`: app.zig:1625-1626, 1871, 1872, 1647, 1653, 1661.
- [ ] new `queries.lanceChoices(unit)` as picker rows; delete `App.lanceChoices`/`lancesOf` 3937-3970 and the `game.unit.Unit` parameter at 3952.
- [ ] `queries.ToeRow` gains `company`, `home_hq`, `echelon`, `roe`, `role`, `mothballed`: app.zig:1558-1559, 3121, 3128, 3139, 3166, 3218, 3283, 3303, 1716, 3247, 3252.
- [ ] `queries.ListingRow.transport`: app.zig:2822. `queries.OfferRow.negotiated`: 3002. `queries.PickRow.on_hand`: 3856, 3883. `queries.PersonRow.primary_skill`: 2905. `queries.RaiseCand` carries hq/item/day/price: 4137.
- [ ] new `sellQuote(unit)`, `hqSaleQuote(hq)`, `disbandQuote(company)` for confirm bodies: app.zig:2064, 2068, 2075, 2085, 2088, 2100-2102.
- [ ] `queries.TreasuryRow.balance`, new `credit()`, `loans()`, `supplyPolicyFor(company)`, `Supply` row `balance`: app.zig:3049, 3084, 3088, 3092, 3094, 3075, 3367, 3433-3434.
- [ ] new `queries.settings()` `{auto_admit, difficulty_name, blurb, mult_line, shares_pct}`: app.zig:3605, 3606, 3608, 3616, 3662, 3682, 3693.
- [ ] new `queries.completionPool()` (or move into `cli.zig`): app.zig:4666, 4668, 4670, 4671, 4673, 4674.
- [ ] one-offs: `outfitEmblem()` (524, 1405); `offerTerms(offer)` (1972-1973); `Upgrades.hq_funds` (2023); `defaultSite()` (3325, 3332, 3380, 3384); `companyStanding(co)` (4174-4178).

**D11b. Rule decisions → commands (the TUI stops pre-checking).**
- [ ] delete the lance-full pre-check at 1637-1638; `move_unit`/`buy_hull_for` return `Error.LanceFull`.
- [ ] delete the recall pre-checks at 3305, 3309; `recall_company` returns `Error.AlreadyHome` / `Error.UnderContract`; the breach recall (3024) gets a confirm.
- [ ] delete the market till pre-check 2824-2836; `buy_listing` returns `Error.HqTreasuryShort` / `Error.CompanyFundsShort` with the sentence in `cli.errorText`.
- [ ] delete the tier pre-check 3479; `upgrade_tier` returns `Error.NotAFieldHq`.
- [ ] new commands: `buy_support_hull{company, kind}` (1673, 1675, 1689, 1694); `set_outfit_emblem{image}` (1028-1030); `set_office_staff{hq, role, delta}` (2487-2497, removes the direct `refreshHqStaffing` call); `raise_company{name, hq}` with `Error.NoCompanySlot` plus `queries.raiseHqChoices` (3190-3205); `ship_components_home{company}` (3409-3414); `replace_mount{unit, slot_key}` (3548-3555); `cover_shortfall{hq, part, qty}` (2865); `toggle_mothball{unit}` (3232); `cycle_roe{company}` (3255); `cycle_role{force}` (3268-3269); `cycle_difficulty{dir}` (3659, 3692); `adjust_shares_pct{delta}` (3665); `toggle_auto_admit` (3699).
- [ ] `advance_day` returns `days_advanced` and `bankrupt` in its `Result`; delete the state compare at 3995-4003. `transfer_unit` returns `in_transit` (3864). `depot` returns the HQ (3247).
- [ ] every new command gets its `cli.zig` verb, help line and error sentences (rule 28).

**D11c. Persistence facade.**
- [ ] new `src/persist/lobby.zig` (`Players`, `Campaigns`, `open`, `save`, `load`, `createPlayer`, `deletePlayer`, `deleteCampaign`, `setSetting`, `schemaVersion`, `isSaved`, `SaveInfo`): app.zig:221, 314, 601, 2336, 4791, 4721, 1830; `GameState` handle at :28 becomes a session type; `deinit` calls at 329, 2348, 2443, 2570, 2573, 4580 become `session.close()`; `game.dataProvenance` (3625) via an `app_info` facade.

## D12. TUI structure (rules 18-25)

- [ ] **`execSay`** (rule 20): all 51 `exec` sites (app.zig 1030, 1646, 1650, 1652, 2802, 2808, 2840, 2866, 2929, 2968, 3019, 3024, 3070, 3076, 3123, 3171, 3234, 3237, 3246, 3260, 3273, 3313, 3465, 3473, 3485, 3539, 3556, 3562, 3566, 3661, 3667, 3692, 3700, 3863, 3866, 3871, 3875, 3879, 3996, 4282, 4301, 4326, 4449, 4463, 4467, 4476, 4486, 4497, 4511, 4560, 4768). Nineteen are unguarded today, including the four liquidation confirms 4463, 4476, 4486, 4497 that report success after a refusal; two use the guard as control flow (1650, 3024); one compares state (3996). Esc at 2617 must reset `msg_style`.
- [ ] **shared `confirm(command, verb)`** (rule 19): `fire` 2128/4492, `sell_unit` 2062/4459 (two-verb), `sell_hq` 2083/4472, `disband` 2097/4482, `game_over` 2114/4408, `quit` 1826/4388, `end_turn` 1810/4365; add one for the breach recall (3024).
- [ ] **shared picker for every list modal**: `raise_hulls` 1863/4115, `raise_support` 1882/4154, `seat` 2142/4502, `emblem` 2153/4521, `install_part` 2042/4415, `install_loc` 2051/4433, `upgrade` 2018/4311, `lance_pick` 2008/4292, `accept_pick` 2000/4265, `negotiate` 1969/4196 (over a new `queries.negotiableTerms`), `music` 1907/4018 (rows carry `{kind, index}`; drop the index arithmetic at 4025-4040), `decision` 1839/4555.
- [ ] **shared read-only list** for `hull` 2188, `record` 2208, `summary` 1937, `readiness` 1944, `raise_crews` 1953, `contract_log` 2194, `help` 1759.
- [ ] **shared text form** for `input` 2214/4565; `settings` 2033/4336 folds into the list-with-adjust widget.
- [ ] **one `clamp` helper and one `resetCursor()`** (rule 23): `modal_cursor` clamps at 1866, 1875, 1902, 1932, 1981, 2003, 2013, 2026, 2046, 2057, 2148, 2159, 2205, 3829, 4198, 4216 and 33 resets; `_sel` fields at 1095, 1304, 1319, 1522, 1728, 3626 (which jump to 0 while the helpers keep the last row); `cursor` clamps at 588, 976, 985, 1436, 1482, 1486, 2255-2263; `focus_scroll` raw pointer (306); `supply_ship_to` (332) and `raise.passed` (45) stale-able state.
- [ ] **`layout.zig`** (rule 21): every constant in the fix map's table, including `narrow_cols = 120` (today 120 at 6 sites, 150 at 3, 140, 160), the recurring ratios 3/5 (12 sites), 55/100 (4), 2/5 (4), and one `modal_size` table for the 31 per-arm modal sizes at 1817-2230.
- [ ] **screens table** (rule 18): split app.zig into `src/tui/screens/{desk,map,forces,contracts,ledger,supply,hq,lab,people,market}.zig`, each exporting `draw`, `move`, `enter`, `key`, `footer`, `paneCount`; one table indexed by `Tab` replaces the six `switch (self.tab)` at 922, 2644, 2656, 2745, 2882 (702 lines) and the modal pair 1755 (491 lines) / 4015 (564 lines); `drawWizard` 642 (225 lines) becomes per-step functions.
- [ ] **one key table per screen** (rule 22): footer switch arms 923-932; lobby footers 639, 694, 754, 814, 859; pane right-titles 945, 949, 953, 956, 1000, 1097, 1441, 1487, 1503, 1526, 1735, 1742 and the modal ones 1934, 1941, 1948, 1983, 2005, 2015, 2028, 2048, 2150, 2161, 2185, 2203, 3831; modal titles 1823, 1860, 2039, 2059, 2080, 2094, 2111, 2139, 2191, 2211, 1876, 1904, 2202, 3777-3809; help rows 1760-1802; in-pane hints (26 sites); `docs/tui.md:85-116` generated or checked by the smoke.
- [ ] **markup tag set once** (rule 16): `table.zig:64-69` `isMark` is the declaration; `screen.zig:56-68` maps from it; `screen.zig:465-470` reuses `visibleLen`; app.zig:1800 stops matching on `"{a}contracts{/}"`.
- [ ] **escape sequences in `term.zig`** (rule 24): `screen.zig:36-53` SGR table and `:393-420` cursor and pixel writes move behind `term` functions.

## D13. Tests and CI (rules 37-40)

- [ ] `term.zig` added to the test block in `src/main.zig:6-14`.
- [x] The emblem-editor smoke step (tui_smoke.py ~236-242) was timing-flaky: it now waits for text (`wait_for`) instead of sleeping (PR #8).
- [ ] Smoke coverage: delete-player and delete-campaign confirms, disband and sell-HQ confirms, game-over path, music modal, resize, the 80-120 column boundary, `←/→` column scrolling on each table screen, every refusal branch of a confirm.
- [ ] `.github/workflows/ci.yml`: `zig build test --summary all` plus both smokes on push and pull request.
- [ ] Golden-master hash test (rule 40) if not already present.
