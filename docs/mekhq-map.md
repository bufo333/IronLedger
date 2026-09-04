# MekHQ → this project: feature & code map

Reference for "where do I look in MekHQ when implementing X." MekHQ is Java,
GPLv2+, at https://github.com/MegaMek/mekhq — we borrow *rules and structure*,
re-implemented in Zig. Paths below are under `MekHQ/src/mekhq/campaign/`.

| MekHQ (Java) | Purpose | Ours (Zig) | Stage |
|---|---|---|---|
| `Campaign.java` (`newDay()`) | God object + daily tick: healing, acquisitions, maintenance, markets, payday | `src/sim/clock.zig` daily pipeline over `GameState` (no god object; ordered system fns) | 1 |
| `personnel/Person.java` | Roles, skills, XP, ranks, status, salary | `src/domain/person.zig` | 2 |
| `personnel/SkillType.java` | Skill catalog, target numbers, XP costs | `src/domain/types.zig` `SkillType` + `data/tables/skills.zon` | 2 |
| `personnel/ranks/*` | Rank systems | rank keys + `data/tables/ranks.zon` | 2 |
| `personnel/medical/*` (advanced medical) | Injuries per location, healing | `src/domain/person.zig` `Injury` | 8 |
| `randomEvents/` + AtB monthly events | Random campaign events | `src/sim/events.zig` decks + decisions | 6 |
| `unit/Unit.java` | Entity wrapper + crew + repair state | `src/domain/unit.zig` | 3 |
| `parts/*` (Part, Armor, MekLocation, ...) | Part instances, quality A–F, repair TNs | `src/domain/part.zig` + catalog `data/parts/*.zon` | 5 |
| `Quartermaster.java`, `procurement/*` | Acquisition rolls, shopping list, delivery ETA | `src/econ/logistics.zig` | 5 |
| `market/ContractMarket` | Monthly offers, CamOps terms | `src/econ/market.zig` | 4 |
| `market/PersonnelMarket`, `UnitMarket` | Hiring pool, unit purchases | `src/econ/market.zig` | 4/9 |
| `mission/Mission,Contract,AtBContract` | 12 AtB contract types, payment math, command rights | `src/domain/contract.zig` | 4 |
| `mission/AtBScenario*`, StratCon (`stratcon/*`) | Scenario generation over a contract's life | `src/sim/events.zig` + `src/sim/autoresolve.zig` | 7 |
| `autoresolve/` (ACAR) | Abstract combat auto resolution | `src/sim/autoresolve.zig` — extended with supply/morale/support modifiers (ARCH §7) | 7 |
| `finances/Finances.java`, `Loan.java` | Ledger, categories, loans | `src/econ/finance.zig` | 2/4 |
| `rating/*` (FMMR, CamOps reputation) | Unit rating → pay & offer quality | reputation in `GameState`, formulas in `src/domain/contract.zig` | 4 |
| `universe/generators/companyGenerators/*` | **AtB company autogeneration** | `src/gen/company_gen.zig` | 3 |
| `universe/Planet,Systems` (`planets.xml`) | Star map, jump distances, planet socio-industrial codes | `data/planets.zon` (curated) + `src/econ/logistics.zig` routes | 9 |
| `universe/RandomNameGenerator` | Names by faction/origin | `src/gen/company_gen.zig` name tables | 2 |
| `CampaignXmlParser`, `.cpnx.gz` saves | Persistence (XML, **not SQL**) | `src/persist/` + `docs/schema.sql` (SQLite) | 11 |
| MegaMek `.mtf`/`.blk` data files | Unit/equipment catalog | curated `data/chassis/*.zon` (licensing: re-encode, don't copy) | 3 |
| MegaMekLab | Loadout editing, refit kits, refit classes A–F | `src/domain/unit.zig` refits + meklab commands | 10 |

## No MekHQ equivalent (our extensions)

| Feature | Ours | Stage |
|---|---|---|
| Companies as concurrent deployable profit centers | `src/domain/force.zig`, per-company P&L in `src/econ/finance.zig` | 9 |
| Brigade/Regional/Field HQ tiers with facility upgrade paths & staffing overhead | `src/domain/hq.zig` (`hqStaffFor`, `Project`) | 9 |
| Influence rings gating the contract market + beachhead expansion | `src/domain/hq.zig` (`influenceLy`) + `src/econ/market.zig` (`visibilityFor`) | 4/9 |
| HQ capacity slots (companies, air company, dropship/jumpship berths) | `src/domain/hq.zig` (`Capacity`) | 9 |
| Supply-line graph: links, throughput caps, multi-hop delay/cost | `src/econ/logistics.zig` (`Route`) | 9 |
| Supply classes (parts/ammo/medical/provisions) with shipments & delays | `src/econ/logistics.zig` | 5/9 |
| Out-of-influence penalties + local-purchase valve + hardship pay | `src/econ/logistics.zig` (`localPurchaseMultBp`) | 9 |
| Support-company lance kinds (MASH/security/mess/salvage/transport) in battle math | `src/domain/force.zig` + `src/sim/autoresolve.zig` modifiers | 7/8 |
| Owned dropships/jumpships as logistics capacity | `src/domain/unit.zig` kinds + `src/econ/logistics.zig` | 9 |
| Field-vs-depot repair split (armor/weapons/ammo in field; structure at HQ mek bays) | `src/domain/unit.zig` (`SlotClass`, `repairTier`, `needsDepot`) + `hq.supportsStructuralRepair` | 5 |
| Rotation fatigue (accrues per contract, decays only at regional HQ) | `src/domain/person.zig` (`contractFatigueGain`, `fatigueDecayPerWeek`) + `force.zig` rotation tracking | 8 |
| HQ-only skill training (XP earned anywhere, converted at home) | `hq.supportsTraining` + `training_assignment` table | 8 |
| Site markets w/ rarity rolls (MekHQ's UnitMarket is global; ours are per-place) | `src/econ/market.zig` (`SiteKind`, `Rarity`, `listingAppears`) | 5 |
| Structural-parts guarantee for owned chassis at regional HQs | `market.SiteKind.guaranteesStructural` + fabrication consts | 5 |
| Per-hull carry cost + cold storage (extends MekHQ mothballing w/ reactivation time) | `src/domain/unit.zig` (`monthlyBill`, `reactivationDays`) | 5 |
| Local operating funds for deployed companies | `force.local_funds` + `fund_transfer` txn category | 9 |
| Player identity: named companies + emblem images | `force.name`/`force.emblem` | 3 |
| Commander character creation (origin faction → HQ placement, profession → 2% edge) | `src/domain/commander.zig` + `state.createCommander` | 4 |
| Beachhead premium pricing + hardship pay on remote contracts | `src/econ/contract_market.zig` + tick finances phase | 4 |
| Decentralized treasuries + fund couriers + standing policies (extends MekHQ Finances) | Stage 9A: `Hq.funds`, live `local_funds`, `fund_transfer`/`standing_policy` | 9A |
| Structured, filterable campaign log (MekHQ has per-person logs only) | Stage 9A: `LogEntry` with company/hq/contract tags | 9A |
| Per-munition stocks w/ pallet tonnage vs. warehouse capacity (MekHQ tracks ammo bins per unit, no site storage) | Stage 9B: `inventory` + `pallet_tons`, `supplies`/`demand` reports | 9B |
| Mek bay slots & construction queues (MekHQ techs have minutes, no bays) | Stage 9C: `bay_job`, `hq_project` live | 9C |
| Back-office staff effects (MekHQ admin roles made consequential: logistics/HR/command experience scale ETAs, hiring, training, morale, paperwork) | Stage 9A/9C: HQ staff postings | 9C |
| Victory points & objective kinds (cf. StratCon VP) + close-out/recall/redeploy | Stage 9E: `objective_kind`, `enemy_pool_bv`, `victory_points` | 9E |
| Full breach clause w/ employer-faction cooling (extends AtB breach) | Stage 9E: `breach_clawback` category, `breach_day` | 9E |
| Pilot + tech assignment per hull, tech minutes budget (`Unit.tech`, `Person.minutesLeft`), astech teams | Stage 9C.2: `unit_crew` 'tech' slot, `weekly_hours`, `assign`/`assign auto` | 9C.2 |
| Personnel market (MekHQ `PersonnelMarket`) → hiring hall candidates per HQ | Stage 9C.2: `hiring_candidate`, `hire <candidate>` | 9C.2 |
| Tech accidents, medbay beds/priority, leave (MekHQ has injuries; no bed capacity) | Stage 9C.2: `medbay_priority`, `leave_until_day`, `medbay`/`triage`/`leave` | 9C.2 |
| End-turn checklist (no MekHQ analog; MekHQ's day-advance warnings are partial) | Stage 9C.2: `turnWarnings` query + `day force` | 9C.2 |
| Persistent, condition-priced hull listings; staple vs. rare-slot parts; daily hiring churn (MekHQ UnitMarket/PersonnelMarket regenerate wholesale) | Stage 9C.3: `market_listing` condition columns, `staple` | 9C.3 |
| MegaMekLab construction rules: per-location crits, tonnage, heat sinks, location rules; engines/gyros/actuators as parts | Stage 10: chassis + parts data growth, loadout validator | 10 |

## Useful MekHQ rule references while implementing

- AtB rules doc bundled with MekHQ (`docs/` in their repo) — event tables,
  scenario odds, lance roles (fight/defend/scout/training).
- Campaign Operations (CamOps) sourcebook — salaries, peacetime operating
  costs, contract payment multipliers, reputation, refit classes, maintenance
  target numbers. Our tables in `data/tables/` cite chapter names.
- BattleTech TechManual — part/equipment catalog structure, tech ratings.
