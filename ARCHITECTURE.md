# Architecture — BattleTech Mercenary Command (working title)

A single-player mercenary *organization* simulator set in the BattleTech universe,
written in Zig. The player is the commander of an entire mercenary outfit — from a
single company up to a brigade — and wins through **logistics, HR, finance, and
command decisions**, never by piloting a mek. Combat happens, but it is resolved
automatically by the simulation; the player's influence on outcomes is exerted
*before* the battle: training, maintenance, supply, equipment, support assets,
and the HQ network that feeds them.

This document borrows heavily from [MekHQ](https://github.com/MegaMek/mekhq)
(the MegaMek suite's campaign manager) for its domain model, campaign rules,
contract system, and company generation — while deliberately dropping the
tabletop/MegaMek battle handoff that MekHQ is built around.

---

## 1. Design pillars

1. **You are the commander, not the pilot.** Every screen is a ledger, roster,
   map, or report. Battles produce after-action reports, not hex maps.
2. **Logistics wins battles.** Supply state, maintenance quality, crew training,
   fatigue, morale, and attached support assets are first-class inputs into
   battle resolution — not flavor text.
3. **Multi-company operations.** Unlike MekHQ (one force, one contract at a
   time in practice), the player runs *several companies concurrently*, each
   deployable to its own contract, fed by a shared HQ/logistics network.
4. **Faithful where it counts.** Contract types, payment math, salary tables,
   maintenance/repair rules, skill levels, and company generation follow MekHQ /
   Campaign Operations (CamOps) as closely as practical.
5. **Deterministic simulation.** Same seed + same decisions = same outcome.
   Everything downstream (testing, replays, save integrity) depends on this.

## 2. What we take from MekHQ — and one correction

**Correction first:** MekHQ does **not** use SQL. It persists campaigns as
gzipped XML files (`.cpnx.gz`) and loads static unit/equipment data from
MegaMek's flat data files (`.mtf`/`.blk` unit definitions). What MekHQ has is a
rich *object model*, and that is what we absorb — then persist it properly in
**SQLite**, which suits this game far better (queries over rosters, ledgers,
inventory; incremental saves; current-schema persistence). The executable DDL
and retained historical migration declarations live in `src/persist/store.zig`;
save-format support is owned by
[contract rule 51](docs/engineering-contract.md#51-save-format-support-is-explicit).
[`docs/schema.sql`](docs/schema.sql)
is the human-readable schema reference. The MekHQ→ours mapping is in
[`docs/mekhq-map.md`](docs/mekhq-map.md).

Borrowed subsystems (see the map doc for class-level detail):

| MekHQ subsystem | What we keep |
|---|---|
| `campaign.Campaign` + new-day loop | The daily tick pipeline: healing, acquisition delivery, maintenance checks, market refresh, contract events, payday |
| `personnel.Person` | Roles (MekWarrior, vehicle crew, aero pilot, Mek/Mechanic/Aero techs, doctor, admins: Command/Logistics/Transport/HR), skills + XP, ranks, injuries, salary tables, SPAs (later) |
| `unit.Unit` + `parts.*` | Unit = chassis + armor + equipment + crew + conditioned mount slots; hull quality grades A–F; fungible spare stock; weekly maintenance checks by tech skill vs. target number |
| `mission.AtBContract` | All 12 AtB contract types, contract terms (length, command rights, salvage %, transport %, straight support %, battle-loss comp, signing bonus, advance), payment multipliers by employer & reputation |
| `market.ContractMarket` / `PersonnelMarket` / `UnitMarket` | Monthly market refreshes, offers scaled by reputation and location |
| AtB / CamOps **CompanyGenerator** | Autogenerate a company: 3 mek lances (12 meks) + officers + support staff sized to tech-team needs, experience-weighted (Green/Regular/Veteran/Elite) |
| `finances.Finances` | Double-entry-ish transaction ledger, loans, peacetime operating costs (salaries + maintenance + food/housing per CamOps) |
| Unit rating (FMMR / CamOps reputation) | Reputation score drives contract quality, pay multipliers, hiring pool |
| ACAR (MekHQ's abstract auto-resolve) | The *concept*: resolve scenarios without a tabletop, from unit stats + crew skill — we extend it heavily (§7) |
| StratCon (light) | Contract-as-campaign: a contract generates scenarios/events over its duration rather than being one battle |

Explicitly **dropped**: MegaMek battle handoff, hex-map anything, princess bot
config, GUI scenario editing, multiplayer.

## 3. Where we go beyond MekHQ

1. **Companies as deployable objects.** The TO&E is
   `Outfit → Battalion? → Company → Lance → Unit`. A *company* (with its
   attached support lance) is the unit of contract assignment. Several
   companies work several contracts at once, possibly on different planets.
2. **HQ network.** The model has three tiers — **Brigade HQ** (the planned
   unique home-base tier), **Regional HQ** (per region of space), and
   **Company/Field HQ** (per deployment). Current progression runs from field
   to regional; the brigade promotion is Product completion P1. HQs project
   **influence rings**
   that gate the contract market, carry **capacity slots** that cap how many
   companies the outfit can field, and have facilities (parts depot,
   mek bays, hospital, mess/quartermaster, training grounds, hiring hall,
   comms, spaceport) that determine: parts availability & prices, upgrade
   paths (refit class ceiling), shipping delay to deployed companies, medical
   throughput, recruit pipeline. Facility upgrades permanently raise staffing
   requirements — expansion commits payroll, not just cash. See §9 and
   GAMEPLAY.md.
3. **Supply lines are simulated.** Four supply classes — **parts, ammo,
   medical, provisions** — flow from HQs to deployed companies via
   dropship/jumpship legs with real transit times (jump routes on a star map).
   Consumption belongs to the event that uses the stock: provisions daily,
   ammunition in battle, medical supplies when treatment begins, and parts or
   components during repair or refit; fabrication produces structural stock.
   Shortages degrade combat
   power, morale, healing, and maintenance.
4. **Support echelon matters.** Support lances — MASH, mess, security,
   salvage, logistics transport — are raised and attached per company;
   each contributes a concrete modifier (wounded survival, fatigue
   recovery, prisoner handling, salvage yield, supply buffer and the field
   workshop's repair hours), and only while it is operational (§9.3).
5. **Attached combat support.** Tank lances and aerospace flights are
   purchasable, attachable per company, and factored into battle resolution as
   force multipliers. Complete battle-armor and artillery flows are Product
   completion P2.
6. **Hands-off battle resolution** rich enough to reward all of the above (§7).

## 4. High-level architecture

Layered, with a strict rule: **the simulation core is pure and deterministic**
— no I/O, no wall clock, no global state. UI and persistence sit outside.
The layer rules, the command/query boundary and the reviewer's greps are
normative in [`docs/engineering-contract.md`](docs/engineering-contract.md); this
section explains the shape, the contract states the rules.

```
┌─────────────────────────────────────────────────────┐
│  Frontends: REPL/CLI → TUI → graphical (later)      │
└──────────────────────┬──────────────────────────────┘
                       │ Commands in / Reports+Queries out
┌──────────────────────▼──────────────────────────────┐
│  Application layer: command validation, save/load,  │
│  autosave, report formatting                        │
├──────────────────────┬──────────────────────────────┤
│  Simulation core (pure, deterministic)              │
│   sim/    daily pipeline, battle, tick               │
│   domain/ person, unit, part, force, contract, hq,  │
│           clock, events, autoresolve, battle_report, hq_link│
│   econ/   finance, markets, logistics network       │
│   gen/    company/person/name generation            │
├─────────────────────────────────────────────────────┤
│  data/   static game data (chassis, weapons, tables,│
│          factions, planets) loaded from .zon files  │
├─────────────────────────────────────────────────────┤
│  persist/  SQLite saves, current-schema persistence │
└─────────────────────────────────────────────────────┘
```

- **Player actions are commands** (`HireePerson`, `AcceptContract`,
  `AssignLance`, `OrderParts`, `BeginRefit`, `UpgradeHq`, `ResolveEventChoice`,
  `AdvanceDay`) — a tagged union. This gives us one choke point for
  validation, an audit log, replayability, and trivially scriptable tests.
  A command reserves every ledger and list slot it needs
  (`GameState.reserveLedger`, `ensureUnusedCapacity`, `founding.prepareHq` before
  `GameState.commitHq`) and pre-formats owned log strings ahead of its first
  mutation, so no allocation can fail after money or stock has moved (rule 12).
  Batch demand is aggregated by stable key and reserved as a whole before any
  item commits, so a short stock or an OOM leaves nothing partially ordered
  (rule 15).  Daily-tick phases — courier credit, part-order delivery,
  `completeJob`, `runWeeklyRepairs`, `applyRefit` — prepare all fallible work
  (list capacity, string buffers) before the first mutation or RNG draw, so a
  retried tick applies each unit of work exactly once (rule 17). No
  preparation can undo a day already committed, so the multi-day advance
  commands take a whole-campaign backup (`campaign_backup`) at their start
  and restore it on any error (rule 11's rollback fallback). `create_commander`
  does the same once its validation and preparation are done, because the
  boards and rosters it opens cannot be prepared before the commander and HQ
  exist.
- **The campaign log is structured** (Stage 9A): every entry carries day,
  category, and company/HQ/contract tags, so any entity's complete history —
  battles, decisions and their outcomes, deliveries, construction, medical —
  is a filter, not an archaeology dig.
- **Frontend path** (decided 2026-09-03): CLI (debug/scripting, permanent) →
  **TUI (Stage 12, architecture doc first)** → graphical client (Stage 13).
  All frontends sit above the command/query boundary; none touch sim state
  directly.
- **The state is one big tree** (`GameState`) owned by an arena-backed
  allocator; systems are free functions `fn tick(state, rng) !Reports`.
  No ECS — this is a management sim; plain structs + ArrayLists +
  AutoHashMaps keyed by typed integer IDs are simpler and faster to iterate on.
- **RNG discipline:** one campaign seed; every subsystem draws from a
  named stream (`gs.rng.roll2d6(.maintenance)`) so that adding a roll in one
  system never perturbs another. A stream's identity is its permanent
  literal salt (`rng.Stream.salt`), not its place in the enum, so adding or
  reordering streams changes no existing draw. Shared generators
  (`person_gen`, `company_gen`, `personnel.recruitGenerated`,
  `planet.weightedPickByFaction`, `market.priceRollBp`, `market.listingAppears`,
  `market.rollHullCondition`, `personnel.creditKills`) take the caller's stream:
  hall, market and hiring draw on `.market`, prisoners and salvage on `.battle`,
  event recruits on `.events`, the starter company on `.generation`, and the
  world's personages (`personage_gen`), then their relations
  (`personage_relations.generate`, after the last personage), the standing
  needs `politics.maintainStanding` keeps, and the conflicts
  `politics.runSchemes` opens and `politics.advanceWorld` resolves, on
  `.politics`; the board's position kinds and terms (`contract_market.refresh`)
  on `.market`. All dice are
  2d6 unless the cited source or design rule says otherwise (`// TUNE`).
- **Presentation markup is escaped at the source.** Screen text carries
  inline tags (`{a}` … `{/}`); `table.Tokenizer` is the one reader of it
  (drawing, width, padding, wrapping, plain CLI text) and `{{` is a literal
  brace. Untrusted text — player, company and HQ names, callsigns, log
  lines, filenames — enters markup only through `MarkupBuilder.appendPlain`
  or `table.plain`, which sanitize and escape it; `appendMarkup` is for
  literals in the code. Query text and cells are escaped markup; a query's
  player-chosen names cross the boundary as `table.Raw`, which cannot be
  formatted with `{s}`: a frontend draws one through `markup` or prints it
  on a plain terminal through `terminal`, and reads `.raw` only for a
  command payload or an exact comparison, with a `// raw:` reason.
  Data-file strings and a save's display copies must be
  `table.markupSafe`.
  **Display width** is owned by `sim/wcwidth.zig` (Unicode 16.0 Option A,
  pinned to `EastAsianWidth-16.0.0.txt`): `table.cells` and `table.pad`
  measure code points as 2 (East Asian W/F), 0 (combining/ignorable), or 1
  (everything else). `queries.padCells` is gone; all width-sensitive
  formatting goes through `table.pad`.
- **Keys are data.** The TUI maps keys to semantic actions through binding
  tables (`tui/keys.zig`): one for the keys every screen shares and one per
  screen, modal, welcome step and wizard step. A binding carries its
  footer group and every word shown about it, and a handler switches on
  actions, so a key cannot work without being listed or be listed without
  working. The footer, pane titles, help modal and the key reference in
  `docs/tui.md` are generated from the tables (`game --keys-markdown`; a
  test compares the doc block).

## 5. Domain model (core entities)

Typed IDs (`PersonId`, `UnitId`, …) are non-exhaustive enums over `u32` —
cheap, copyable, and impossible to mix up.

- **Person** — name, origin, role(s), rank, skills (map of `SkillType` →
  level+bonus), XP, experience level derived (Green/Regular/Veteran/Elite),
  salary (CamOps table × role × experience), status (active/wounded/MIA/KIA/
  retired), injuries (advanced-medical style: per-location, healing time,
  doctor assignment), fatigue, morale, hire date, contract-end date.
- **Unit** — reference to static **Chassis** (variant), per-unit state: armor
  %, internal damage, destroyed/damaged part slots, quality grade A–F,
  maintenance state, crew assignment, ammo state, customization delta (refits).
  Covers meks, vehicles, aerospace, infantry, support vehicles (MASH and cargo
  trucks) and DropShips/JumpShips with one struct + kind enum; the enum also
  reserves battle armor for Product completion P2.
- **Artillery formation** — one organizational identity and one physical
  Mobile Long Tom `HullInstance`, with an explicit artillery catalogue and
  nullable ownership closing days. It is separate from `Unit`: acquisition,
  direct company attachment, HQ pools/freight and carrying/resale accounting
  are live. P2g adds individual crew, condition/magazines, local service,
  reloads and shared maintenance/depot repair. P2h adds real loaded salvos,
  temporary opening-power suppression, carrier/crew losses and immutable reports
  in schema 63. Terminal formations retain the physical hull and closed ownership
  interval while leaving all live accounting/capability paths.
  [Artillery operations policy](docs/p2-artillery-operations-design.md) and
  [combat policy](docs/p2-artillery-battle-design.md) own those project adaptations. Existing personnel,
  assignment and shared bay views consume typed owners. Dedicated artillery
  panels, parser verbs and TUI controls shipped in P2i: `artilleryFormationRows`,
  `artilleryDetailLines`, and `artilleryOfferRows` in
  `queries.zig`; nine REPL verbs (`buyarty`, `attacharty`, `detacharty`,
  `shiparty`, `sellarty`, `seat`, `artytech`, `reloadarty`, `repairarty`) in
  `cli.zig`; an artillery panel as the last F3 Forces view (`]`/`[` wraps to
  it); and each HQ's offer as the last row of its F10 Market board, bought
  with Enter.
  A pooled carrier can be crewed at its HQ (crew stay off company books) and
  either attached at home or sent by field freight to a company in the field
  (`ship_artillery_to_company`, `shiparty <id> co:<id>`; `artillery_field`
  owns its quote, dispatch, arrival and diversion). Seated crew and the
  mechanic travel with it, attach and join the company on arrival, or turn
  back to the source pool with it when the company leaves the field or
  disbands. On the artillery panel every Forces key acts on the carrier
  through typed pickers (crew, mechanic, clear, send) or says why it does not.
  [Artillery acquisition policy](docs/p2-artillery-acquisition-design.md) defines
  the monthly local offers, field delivery and declared transport/accounting
  abstractions. The founding board is stamped with the campaign's start date,
  so a day-0 save loads and its offer can be bought on day 0.
- **Part** — static part definition (catalog) plus fungible quantities in site
  inventories; mounted unit slots carry condition, hulls carry maintenance
  quality A–F, and catalogue availability A–F controls sourcing. Acquisition
  orders carry an ETA from wherever sourced.
- **Force** — TO&E tree node (outfit/battalion/company/lance), commander,
  attached support assets; a Company aggregates readiness from its lances.
  Companies carry player-set **identity**: a name and an emblem image (stored
  in the save, shown on rosters, AARs, and reports); the outfit name is
  campaign state and its displayed crest comes from the company emblems.
  Deployed companies also hold **local operating funds** (§9.8).
- **Contract** — type (one of the 12 AtB types below), employer, enemy,
  planet, dates, financial terms, assigned company, required force size,
  score/success state, generated scenario & event schedule. Every offer and
  contract has a backer (docs/p5d-conflict-world-design.md §C "No contract
  without a backer"): the **Conflict** that posted it (`conflict_id`), the
  `side` it serves (`ConflictSide`: aggressor or defender, a standing need's
  employer being its defender), the day the backer wants the company on the
  world (`on_station_by`, the strike day; none for a standing need) and the
  last day it may be accepted (`close_day`; none when it closes at the month
  start). Only a row a schema v73 store held has no backer.
- **Hq** — tier, planet, facility levels (each with an upgrade path),
  influence radius (derived), capacity slots (derived), staffing requirement
  (derived, grows with facility levels), assigned staff, inventory, project
  queue (foundings & upgrades, each with paperwork + construction phases),
  monthly upkeep.
- **HqLink** — supply-line edge between two HQs: level (charter → scheduled →
  dedicated jumpship), throughput cap, per-hop delay/cost multipliers.
- **Shipment** — supply class, quantity, route (jump legs), ETA.
- **Finances** — transaction ledger (every c-bill has a category and date),
  loans, monthly close-out report per company (the *profit center* view).
- **GameState** — campaign date, player outfit, reputation, all of the above,
  markets, pending events, RNG state, persistent actors map, rivals map,
  officer arcs map, world-state map, personages map.
- **Personage** — a persisted figure of the political world
  (`domain/personage.zig`, docs/p5d-conflict-world-design.md §B), keyed by
  `PersonageId`. Every campaign seats a `planetary_ruler` for every world
  whose faction hires (`personage.worldHasRuler`) and a `faction_leader` on
  the capital of every hiring faction except the `PER` catch-all bucket
  (`personage.factionHasLeader`); data rows add `heir`, `family` and
  `intelligence_chief` figures. Each carries a name, two or three motives
  from §B's closed set, an ambition (0–100), a provenance, a `key` and a
  `family_key`. A seat goes to the `data/tables/personages.zon` row
  (`domain/personage_data.zig`) whose era window holds the start year, else
  to a `procedural` row drawn by `personage_gen` (`key` and `family_key`
  empty, `generator_version` naming the generator); every other in-window
  data row is seated after the seats (`personages.prepareSeeding(gs,
  start_year)`). Data rows are `canon` (setting facts restated) or
  `authored` (project fiction), with `generator_version` 0. Provenance is
  internal metadata for tests and save validation; no display shows it,
  and no row says where a personage comes from. The title is derived by
  `personage.titleText`, never stored: a data row's own title, or "Governor
  of …" / "Leader, …" for a procedural row. Unlike the contract-scoped
  **Actor**, a personage exists from campaign creation whether or not any
  contract names it; the political schemes read personages (**Conflict**,
  below). Seeding and the load
  check are `sim/personages.zig` (`prepareSeeding`, `commitSeeding`,
  `validate`): `create_commander` prepares the seeding before its first
  mutation and commits it once the commander exists, before the standing
  needs and the boards are drawn; any later failure restores the campaign
  from the command's backup, so a seeding failure leaves it unchanged. `who` lists them through
  `queries.personageRows` (`who <faction>`: the leader, then its heirs,
  family and officials, then its rulers); `who <contract id>` and the F4
  `w` who's-who sheet read `queries.contractWhosWho` (the contract's world
  governor, employer leader and enemy leader, a dim line for an empty seat).
- **Personage relation** — `personage.Relation { from, to, kind, weight }`
  in `GameState.personage_relations`, in generation order; `(from, to, kind)`
  is its identity. Kinds (§B): `liege` (vassal → liege), `kin`, `rival`,
  `ally` and `grudge` (holder → target); kin, rival and ally are symmetric
  (`RelationKind.symmetric`) and stored once with `from < to`. Weights run
  1–100 (`tuning.politics`); a liege's weight is the vassal's loyalty, so
  loyalty exists exactly where a liege does. `sim/personage_relations.zig`
  draws them inside `prepareSeeding`, after every personage: each ruler of a
  leader-bearing faction owes its leader fealty; two data rows sharing a
  non-empty `family_key` are kin (decision K2), two procedural rows of one
  faction sharing a last name are kin (decision K1), and a data row and a
  procedural row never are (`personage.kinAtCreation`); and
  each ruler may draw one rival (same faction), ally (neither faction lists
  the other as a foe) and grudge (one does) toward a ruler within
  `relation_reach_ly` (`personage.inRelationReach`,
  `drawnRelationFactionsAllowed`, `factionsHostile`; decision R1 (relations)).
  Leaders hold only kin and receive lieges; heirs, family and officials hold
  only kin. `personage_relations.validate`
  is the load check. `queries.personageRelationRows` lists one personage's
  relations (a leader's lieges collapse into one "fealty of N governors"
  row); `who <world>`, `who <contract id>` and the F4 sheet print them under
  each personage's row. The political schemes read lieges, grudges, rivals
  and allies (**Conflict**, below).
- **Conflict** — `conflict.Conflict` in `GameState.conflicts`, keyed by
  `ConflictId` from `next_conflict_id`, in id order, resolved ones kept
  (docs/p5d-conflict-world-design.md §C, §E). Its `family` is `offensive`
  (a war) or `standing` (a ruler's standing garrison or training need, §E
  "stability"). It holds its opening template's
  key, the world fought over, the aggressor and defender (each a
  `conflict.Power`: a faction key and the personage acting for it), the
  instigator, the staging world, the §A days (`opened_day < discovery_day <
  strike_day < expires_day`, all fixed at opening), the defender's rolled
  `local_force` and the aggressor's `strike_force` (`opfor.Force`), and an
  `outcome` once resolved. A standing need has no aggressor, staging world,
  strike or end day or strike force (`conflict.offense` reads them
  together); it is known from its opening (`discovery_day = opened_day`),
  its ruler is its defender and instigator, and it ends only `stood_down`.
  Its status (`preparing`, `threatened`, `open`, `standing`,
  `resolved`) is derived by one owner, `conflict.status(c, day)`, never
  stored. The posting rules are `conflict.postsFrom` (the aggressor's
  positions from `opened_day`, the defender's from `discovery_day`; D15),
  `onStationBy` (the strike day), `sideFaction` and `opposition` (an
  aggressor's position faces the `local_force`, a defender's the
  `strike_force`, a standing need's no named threat; decision F4). The pure rules are `domain/conflict.zig`: `aggressorWinChanceBp`
  (strike BV over both forces' BV; decision E4), `discoveryDay` (the earlier
  of the intelligence day, `opened + lag − chief cut`, and the detection
  day, `strike − detection_lead_days`; D12, E6) and `localForceLances`
  (rolled lances plus one per `local_force_security_per_lance` of world
  security, at least one). Conflicts open from the `opening` templates of
  `data/tables/political_events.zon` (`domain/political_event.zig`, validated
  every build): each names the instigator's roles and motives, whether it
  is a pirate's, its `TargetRule` (`hostile_world`, `recent_victor_world`,
  `grudge_seat`, `rival_seat`, `ally_foe_world`, `own_seat`, one owner each
  in `sim/politics.zig`), the instigator's side, the strike force's
  contract kind, the kinds of position its aggressor posts
  (`position_kinds`; its defender posts `political_event.defender_kinds`,
  decision D3), a weight and a cause sentence; the `standing` templates post
  garrison and cadre duty on the ruler's own seat. `sim/politics.zig` owns
  opening (`runSchemes`), progression and NPC-only resolution
  (`advanceWorld`, §6), the standing needs (`maintainStanding`: one on every
  hiring world with a ruler, drawn at campaign creation and kept on each
  1st; one stands down once `standing_lifetime_days` have passed and no
  contract it backs holds its position, `standDownDue`), the staging world
  (`stagingWorld`: the aggressor faction's nearest world, never the
  target), the one cause formatter (`causeText`) and the load check
  (`validate`, which also checks every offer's and contract's backer).
  `queries.conflictRows` lists, for REPL `conflicts`, every discovered
  offensive conflict and every standing need with a position posted or
  holding the outfit's contract, with its positions and the side the outfit
  holds; a `preparing` conflict shows nowhere. Every contract position is
  posted from a conflict (§9.2); battles and rivals read no conflict yet.
- **News item** — `news_item.NewsItem` (`domain/news.zig`) in
  `GameState.news_items`, keyed by `NewsId` from `next_news_id`, in id
  (emission) order, all kept (docs/p5d-conflict-world-design.md §K "News").
  One is made for each discovery, strike and resolution of an offensive
  conflict that a presence hears (`politics.advanceWorld`, §6); a standing
  need makes none. It stores its kind (`discovery`, `strike`,
  `resolution`), its conflict, the presence that heard it (`hq` or
  `company`) and that presence's world, and its text: the plain sentence of
  its `[politics]` log line, rendered once. Its day (the conflict's day for
  the kind), distance (`reachLy`) and severity (`severity`: a discovery or a
  strike notable, a resolution major) are derived, never stored. Reach is
  one owner, `news.newsReach(gs, planet_key)`: the nearest HQ or company
  world (`posture.companyWorld`, §9.7) within `tuning.politics.news_reach_ly`
  (100 ly, inclusive; separate from influence rings), an HQ before a company
  at equal distance, then the lower id; it draws nothing. Reach is fixed on
  the day the news breaks and never back-filled. `news.validate` is the load
  check. `queries.newsRows` lists the newest items, newest first, for the
  Desk's NEWSWIRE pane and REPL `news [n]`; it formats and never decides
  reach.
- **Actor** — a contract-introduced NPC (liaison, official, enemy commander,
  etc.) that persists across contracts. Each actor carries four relationship
  dimensions (trust, debt, respect, hostility; −100…100) and typed **flags**
  (`ActorFlag`: did business, informed on, drilled together, cut ties) that
  remember the company's answers to its situations. Actors are keyed by
  `ActorId`; the same faction/archetype pair recurring in a later contract
  surfaces the prior relationship and flags. Owned by `sim/actors.zig`
  (P4i); `actors.setFlags` and `actors.flagsConflict` decide which flags
  exclude each other, so the build refuses an answer setting both and the
  loader a save holding both.
- **Rival** — a persistent opposing or allied mercenary company introduced by a
  contract arc. Each rival carries a single standing dimension (−100…100) that
  shifts on operation outcomes and the finale. Rivals are keyed by `RivalId`.
  Recurring rivals (same archetype key + faction key, already closed contract)
  carry their standing into the new contract. Doctrine shapes future narrative
  hooks. Owned by `sim/rivals.zig` (P4i).
- **OfficerArc** — a bounded task-performance arc for the deployed company
  commander and each combat-lance leader introduced when an arc contract is
  accepted. Each arc rides on an existing payroll `Person` (referenced by
  `PersonId`) and owns only its performance standing (−100…100) for one
  contract's span. Performance shifts on operation outcomes and the finale
  via the `prepareAdjustOfficer`/`commitAdjustOfficer` owner in
  `sim/officers.zig`. Officers never alter loyalty, rank, retention, or any
  other `Person` field; those remain owned by the personnel system (P4i).
- **WorldState** — five bounded numeric dimensions (security, civilian support,
  infrastructure strain, employer control, enemy influence; −100…100) and
  typed **flags** (`WorldFlag`: black market open, black market closed,
  militia trained) keyed by `planet_key` in `GameState.world_states`. Changed
  only by `operation_control.resolveDueOperations`,
  `operation_control.resolveFinale` and `situations.resolve` via
  `sim/world_state.zig` owners (`world_state.setFlags` and
  `world_state.flagsConflict` decide which flags exclude each other; the
  build refuses an answer setting both and the loader a save holding both).
  The flags stay on the planet across contracts; local pricing (§9.6) and the
  arc finale read them. Surfaced read-only on the Map and Contracts screens
  (P4h.4).
- **Situation** — a `data/tables/situations.zon` row: an actor-owned decision
  on an arc contract (owner archetype, arc, earliest beat, optional actor-flag
  requirement for a callback, 2–3 options each naming its costs, deltas and
  the flags it leaves). Each contract keeps a `SituationRecord` (key, day,
  owning actor, answer) for every situation it raised; a pending one rides the
  decision inbox as an `Event` of kind `situation` naming its row and actor
  (§8 "Situations").

Contract types (matching MekHQ/AtB): **Garrison Duty, Cadre Duty, Security
Duty, Riot Duty, Planetary Assault, Relief Duty, Guerrilla Warfare, Pirate
Hunting, Diversionary Raid, Objective Raid, Recon Raid, Extraction Raid.**
Garrison-class contracts (Garrison/Cadre/Security/Riot) are long, low-combat,
event-driven; Raid/Assault classes are short and battle-heavy.

## 6. The simulation loop (turn-based)

The game is **turn-based**: a turn is one campaign day, and time moves only
when the player ends a turn (multi-day advance = several turns back to
back).

**What may stop a turn.** A decision that only moves the dials — money,
fatigue, morale, reputation, employer standing, score, the contract bonus
— never blocks or interrupts an advance. It lands in the **decision
inbox** with a deadline, and an unanswered one applies its (safe) default
option at that deadline, noted in the log. Ignoring that inbox is a choice
with consequences, not an impossibility: every option is a trade the
campaign can absorb, and the cautious default is always a real answer.

**Battle decisions block.** An engagement disposes of hulls and people
permanently — which wrecks the trucks lift, whether the company goes back
for what it left, whether it presses or consolidates — and there is no
safe default to lapse to, because every option forfeits something that
does not come back. So an unanswered after-action report holds the turn,
and so does an unanswered battle decision, and so does an engagement whose
day has come: it waits on the commander's battle orders (§7, "The phased
engagement"; `battle.dueEngagement`), garrison probes included. A
multi-day advance stops on the day any of them lands rather than resolving
the rest of the week around it. Solvency is the other stop (§11): a
negative treasury holds the turn until it is covered.

`checklist.turnHold` is the one place that decides whether the turn is
held (unread report, then battle decision, then due engagement);
`commands.advance` turns its answer into the refusal, the checklist turns
it into a warning, and `queries.turnHold` carries the id a client needs to
put the right sheet, decision or battle screen on screen; an
`advance_until_stop` held by an engagement names its contract.
`EventKind.blocksTurn` names which decisions qualify — the test below,
written as a switch.

**The battle lock.** From the first battle order until the order that ends
the battle, only battle orders run: `battle_phases.commandAllowedDuringBattle`
is the one owner and `commands.execute` refuses every other command with
`error.BattleInProgress`, consuming nothing. Each order replays the
engagement from live state, so live state must not move between orders;
the lock is what makes the persisted battle record small and the replay
exact. Before the first order the pre-battle levers (ROE, lance roles,
battle orders, emergency resupply, tasks, interventions) stay open; only
the advance is held. The contact-pause levers (committing the reserve, a
mid-battle intervention) are battle orders, so the lock is unchanged: they
change nothing live until the order that ends the battle publishes them. A
battle starts only when no report or decision holds the turn.

The test for a new blocking rule is *what it disposes of*, not how big it
feels. If the worst outcome is a worse bonus, it waits in the inbox.

**The stop model.** The player's unit of time is the next stop:
`advance_until_stop` (the `n` key, `next [cap]`) runs day by day, up to
`tuning.battle.auto_advance_cap_days`, until the commander is needed.
`checklist.advanceStop` is the one owner of what stops it, beside
`turnHold` and `contactOpenedToday`; the command reports exactly the
`checklist.StopReason` it returns and decides no priority of its own.
Before each day `checklist.watchDay` records, by identity, what the tick
consumes — couriers, part orders, returning companies, unit transfers,
artillery freight, running contracts, structural bay jobs, projects, and
each person's status — so a stop is a transition that actually happened,
never a due date that may slip or a count another change can mask.

In priority order, inside a contract (a contract in transit or active) or
between contracts: a turn hold; the contact window; a decision queued that
day or one that would default tomorrow; the employer's combat-ineffective
breach notice (`contract_control.breachNoticeServed`); payday; a running
contract closing; a company arriving on its contract world; a company
coming home, a unit transfer or artillery formation landing (HQ freight in
its pool, field freight attaching to its company, or a diverted carrier back
in its source pool; a diversion itself keeps the carrier on the road). Between
contracts only: a fund courier or part order landing; a structural bay
job (hull or artillery depot repair) leaving the bench finished; a
construction project landing; a rare hull new on an HQ board; someone
recovering, retiring or resigning. Everything else is a notice: it is in
the campaign log, and the stop screen shows the log since the advance
began (`queries.logSpan`), with one quiet sentence when no contract runs
and nothing is building (`checklist.nothingComing`, `queries.quietOutlook`).

An auto advance never crosses a decision deadline. Before its first day
`advanceStop` asks only whether a decision defaults tomorrow
(`Event.defaultsBy`, the rule `contract_events.expireDue` applies), so a
repeated `next` waits with zero days; the default lands only when the
player advances past it with `advance_days`. Money stops share
`tick.settleSolvency` with `advance`: an outfit that folds before the
first day is a typed `.bankrupt` success with zero days for both
commands, the bankruptcy committed; an outfit already bankrupt is refused
with `Bankrupt`. An error anywhere in an advance (before, inside or
between days) leaves the campaign exactly as it was before the command,
restored from the campaign backup taken at its start (`campaign_backup`),
so retrying the command reruns it from that campaign. The outcomes that
change nothing — a turn hold, `Bankrupt`, a zero-day `Insolvent` and the
zero-day decision stop — are answered before that backup is taken.

Before an engagement's day there is no hold, only a **stop**. When a scheduled
engagement comes within `tuning.battle.contact_warning_days`, a multi-day
advance stops once on that day and the next advance goes ahead. The
checklist carries a contact warning and the client opens the **battle
orders**: the odds, fieldable strength and ammunition, and every lever
that can still change the fight (rules of engagement, lance roles,
emergency resupply through the local supplies valve of §9.6, recall).
The resupply (`emergency_resupply`, quoted by `field_supply.rushQuote`)
is priced by the same `localPriceMultBp` as the provisions purchase.
Confirming the orders (`confirm_orders`, which sets `Contract.orders_day`
to the engagement's day; `battle.ordersConfirmed`) clears the warning;
skipping them leaves the settings as they are. Nothing is disposed of
that the commander has not already chosen, so time may move without an
answer.

Each turn runs a fixed pipeline over the whole state — order matters and is
part of the spec:

1. **Travel** — jumpship/dropship legs progress; shipments and unit transfers
   arrive.
2. **Supply consumption** — deployed companies consume daily provisions;
   shortage flags update. Battles consume ammunition, treatment consumes
   medical supplies, and repair or refit consumes parts in its own phase;
   fabrication adds completed structural components to stock.
3. **Medical** — doctors heal the wounded (MASH/hospital modifiers).
4. **Acquisition & markets** — ordered parts arrive; market refreshes
   (contract positions daily, personnel weekly, units monthly).
   After the hiring halls churn and before the contract board posts, the
   political world moves (`politics.advanceWorld`; docs/p5d-conflict-world-design.md
   §K steps 2–3): first today's due conflict days by (day, `ConflictId`) —
   discovery, the strike, and at `expires_day` the resolution: one
   `.politics` draw against `aggressorWinChanceBp` resolves the conflict and
   moves its world by `world_state.conflictWorldDelta`, which writes its
   `[world]` line at any distance. A due day that a presence hears
   (`news.newsReach`: an HQ or a company within `news_reach_ly`, at the
   day's start) is news: one `[politics]` line and one **News item** (§5)
   carrying the same sentence. A day no presence hears logs no `[politics]`
   line and makes no item, and still happens. Then on the 1st
   `maintainStanding` stands down the lapsed standing needs and draws new
   ones, and `runSchemes` opens up to `schemes_per_month` conflicts,
   unlogged because an opening is secret. Every fallible step is prepared
   before the first mutation, and a later step's failure rolls the earlier
   ones back, news included. Player state, presence and visibility are never
   inputs to progression — presence decides only what is news — but a
   standing need stands on while a contract it backs holds its position.
   News never stops time. Then the contract board posts the day's positions
   from the conflicts and retires the closed ones (§9.2).
5. **Maintenance** *(weekly per unit)* — tech rolls vs. target number
   (modified by part quality, supply state, facility, tech workload);
   failures degrade quality/parts, MekHQ-style.
6. **Training** — unassigned-to-combat lances train; XP trickle, cadre duties.
7. **Contract events** — per active contract, roll on the event table for its
   type (see §8); scenario generation for combat-class contracts. On the 1st,
   a contract whose arc has situations raises its next due situation in place
   of the monthly roll, drawing no dice (§8 "Situations").
8. **Battle resolution** — engagements are scheduled; one whose day has come
   does not resolve here, it **comes due** and holds the turn. The
   commander fights it after the day's tick and before the next turn, so
   that day's phases 9–11 run before the fight; the order that ends it
   publishes the engagement, its AAR and the next schedule (§7).
9. **Morale/fatigue update.**
10. **Finances** — daily accruals; on the 1st: payroll, overhead, HQ upkeep,
    contract payments, loan payments, monthly per-company P&L report.
11. **Decisions** — expired inbox deadlines apply their default options;
    the refreshed inbox is presented to the player between turns.

## 7. Battle autoresolution (the heart of the extension)

Goal: outcomes that are *legible* — the AAR should let the player trace a loss
back to "C-grade maintenance and two green lances," not to a die roll.

Model: an engagement is resolved in **rounds** (abstracted ~turns). Each side
has a set of **elements** (lance/flight/platoon). Per round:

1. Compute each element's **combat power** from BattleTech-faithful inputs:
   base BV2-derived strength of its units × crew skill multiplier (gunnery/
   piloting → the classic 2d6 to-hit curve gives us the multiplier table) ×
   condition (armor %, open maintenance issues) × ammo state.
2. Apply **campaign modifiers** — this is where the player's real decisions
   live: supply state (each missing supply class is a penalty), fatigue,
   morale, days-since-hot-food (mess), scouting/recon quality, commander
   tactics skill, terrain & scenario type, attached support and air cover.
   P2h artillery applies one ready, physically present loaded salvo before the
   phase rolls (the contact phase): a hit temporarily suppresses enemy power, without permanent BV
   destruction or kill credit. Battle armor holding objectives remains deferred.
3. Exchange fire: opposed 2d6 rolls per element pair vs. target numbers built
   from the ratio of effective power; margins map to a **damage table**
   (armor loss → crits → unit destroyed/crew wounded/killed), borrowing the
   spirit of the BT damage/crit tables without per-weapon resolution.
4. Check **withdrawal thresholds** (forced withdrawal rules): a side breaks
   when losses exceed its morale-adjusted threshold; contracts define victory
   conditions per scenario type.
5. Output: casualties, unit damage (mapped onto real part slots so repair
   work is generated), salvage pool (filtered by contract salvage rights),
   prisoners, XP awards, reputation delta, and a narrated AAR.

Post-battle flows straight into the existing systems: wounded → medical,
damage → tech queues + parts demand, salvage → inventory/market, XP → skills.

As built (Stage 7 → P5b.1) the rounds collapse into **named phases**
(below); step 4 survives as a company standing order — **rules of
engagement** (12D.4: hold / standard / cautious), which trade roll odds
against losses on a lost fight and recovery of wrecks. The opposition is a
**force of its own** (12D.5): lances off the enemy house's RAT at a rolled
skill, posted with the offer and shown by intel, not a mirror of the
player's BV — so a worn-down company meets the same enemy as a fresh one.
Intel is one HQ's reading (`offer_rating.intelLevel`: its comms level,
plus one for a B-or-better rating); `intelHq` picks the HQ whose board
offered the contract, else the company's home HQ.

Crew skill is the role's pair — `Role.primarySkill` (gunnery) beside
`Role.pilotingSkill` — read for the crew of each hull kind: a mek fights
on gunnery/piloting, a vehicle on gunnery_vee/driving_vee. Escape,
recovery, `experience()` and the roster text use the same pair. Only
operational hulls (`GameState.unitOperational`, §9.3) stand in the line or
count toward fieldable BV.

**The phased engagement** (P5b.1; rules in `src/sim/battle_phases.zig`,
records in `src/domain/battle_phase.zig`). A due engagement is fought in
phases, **contact → decisive → pursuit or withdrawal**, each a slice of the
one battle model — the power ratio, the scenario and conditions, the ROE
roll and `tuning.battle.outcome_at`; there is no second engine.

- **Fixed dice.** Preparation is unchanged (player side, OpFor pool draw,
  weather, the artillery snapshot, the scenario and the salvo). At a fixed
  position of the `.battle` stream, before any draw that depends on
  orders, the engagement draws its phase dice once: contact, decisive, the
  decisive Edge re-roll and pursuit, four 2d6 (`Dice.draw`). Every course
  of orders consumes exactly that prefix; OpFor hull outcomes, hits,
  recovery, salvage and prisoners follow in their existing order. An
  earlier phase is never re-rolled.
- **Contact** (`contactVerdict`): contact die + ratio + conditions + the ROE
  roll in force; its margin over `tuning.battle.phases.par` bands into won,
  even or lost, which sets the contact hits (a share of the line) and the
  momentum carried into the decisive roll.
- **Decisive** (`decisiveVerdict`, `decisiveHits`): decisive die + ratio +
  conditions + the ROE roll in force + momentum + the contact-pause levers'
  modifier (`decisiveMod`), banded by `outcome_at`; a losing roll is
  re-rolled on the Edge die when a pilot can spend Edge. The line takes the
  larger of the contact hits and the outcome's share (`hit_pct`, ROE, and
  the reserve's clamp unless the reserve was committed). A cautious draw
  gives up the field (`cautiousWithdrawal`).
- **Pursuit or withdrawal.** A held field may be pursued (the pursuit die
  adds an enemy-loss bonus, widening the pool path's destroyed band, at the
  risk of hits) or consolidated; a lost field may be covered (wrecks roll
  `phases.cover.recovery_mod` better in `battle_recovery.situation`, at the
  risk of hits) or left now under the usual recovery rolls.
- **Tactical withdrawal after contact**: the battle ends as a draw with the
  field given up (`withdrew`), only the contact hits land,
  `loss.roe.withdrawal_score` applies and the wrecks roll under cautious
  recovery.

Between phases the turn pauses on a **phase report**: the margin, the hits
taken so far (nothing lands until the battle ends), the momentum, the ROE
for the next phase and the exact odds of each band of the next phase
(`nextPhaseOdds`, every 2d6 result enumerated, Edge included; no RNG). The
screen shows those exact counts as whole percentages totalling 100
(`queries.oddsPercents`: each band rounded down, the points left to the
largest remainders). The legal orders at each pause are `battle_phases.legalOrders`: engage; press on,
withdraw, an ROE change or a lever at contact; pursue or consolidate after a held
field, cover the recovery or withdraw after a lost one. An ROE change is
recorded on the battle, never written to the company's standing ROE, and is
refused (`RoeReservedByEmployer`) when integrated command holds the ROE. An
engagement's outcome is a pure function of the campaign state at engagement
start, its fixed dice and its ordered orders (`battle_phases.run`).

**Contact-pause levers.** At the contact pause, alongside an ROE change, the
commander may pull each lever once, in any order, before pressing on or
withdrawing; a lever keeps the battle at the contact pause, consumes no die
and changes only the decisive phase (`Order.commit_reserve`,
`Order.intervene`; `battle_phase.Lever`).

- **Commit the reserve.** The reserve-tasked lance already fights in the
  line (P4e). Committing it adds `tuning.battle.phases.reserve.commit_roll`
  to the decisive roll and gives up its clamp: a lost fight lands its full
  share of hits. It costs no command capacity.
- **Call an intervention** (`emergency recon`, `reinforce`, `air cover`,
  `field repair`). The decisive roll gains exactly what the intervention's
  profile adds before battle (`operations.interventionProfile`), here to the
  decisive phase alone, for `operations.interventionCost` command capacity.
- **Bounded modifiers.** Every lever adds `0..battle_phases.max_lever_mod`
  decisive-roll points, the 2d6 span; a `data:` check refuses a
  `commit_roll` outside it on every build, so the summed decisive roll is
  defined (rules 25, 58).
- **Owners.** `battle_phases.leverCost`, `leverMod` and `decisiveMod` own the
  cost and modifiers; `battle_phases.leverAllowed` owns availability.
  `battle.leverAvailability` reads it from live state at engagement start
  (which the battle lock keeps fixed) and the engagement's weather: an
  operational reserve-tasked lance of the committed combat operation
  (`readiness.forceOperational`), each intervention's gate
  (`interventionGate`), prior application (`interventionApplied`), the
  employer lock (`operations.interventionReservedByEmployer`: integrated
  command reserves `reinforce` and `air_cover` mid-battle; pre-battle
  `apply_intervention` does not consult it) and the capacity the commander
  may spend (`commandCapacityAvailable`, less earlier calls in this battle).
  `battle.inProgressAvailability` gives the battle screen the same
  availability, weather included, by replaying the battle in progress in a
  discarded workspace; it consumes no live RNG and changes nothing live.
- **Refusals**, each consuming nothing, with one `cli.errorText` sentence:
  no operational reserve (`ReserveUnavailable`), the reserve already
  committed (`OrderNotLegal`), the employer's lock
  (`InterventionReservedByEmployer`), air cover in weather that grounds
  aircraft (`AirCoverGrounded`), an intervention applied before battle or
  already called (`InterventionAlreadyApplied`), an unmet gate
  (`InterventionGateUnmet`) and capacity short (`InsufficientCommandCapacity`),
  checked in that order. A lever at the decisive pause or before contact is
  `OrderNotLegal`: the decisive pause leads to a pursuit or a rearguard on the
  bare pursuit die, which no lever reaches.
- **Report and odds.** The contact pause's report carries the levers'
  modifier, the reserve commitment and the capacity spent, and its odds are
  `nextPhaseOdds` under the levers' modifier. The decisive `PhaseRecord`
  carries `lever_mod`; `BattleReport.levers` lists each lever with its cost
  and modifier; the loader refuses figures other than the owners give.
- **Publication.** The order that ends the battle publishes the levers with
  it: the interventions' capacity is deducted from the contract, each
  intervention joins the committed operation's `interventions` (logged with
  the same `[arc] intervention applied` line a pre-battle one leaves), a
  committed reserve sets `Operation.reserve_committed`, and the AAR and the
  campaign log name each lever and its effect. A withdrawal after a lever
  still pays for it: the capacity was spent at the pause, and the lever added
  nothing. Unattended and decision-started engagements give no levers.

The battle record (`GameState.battles_in_progress`, at most one) keeps the
contract, the pause and each order with the report it reached; it holds no
RNG state and no input snapshot. Each order replays the engagement from
live state in a discarded workspace; only the order that ends the battle
publishes it through the isolated `Engagement` workspace with its next
schedule, then removes the record. Concession and forfeit finish on the
first order as one-step battles. The AAR and the campaign log name each
phase and the order given at it (`BattleReport.phases`,
`after_action.phaseText`). Engagements a decision's "fight" option starts
(`.engagement`) fight through the same phases with the unattended orders
(`battle_phases.defaultOrder`) in one publication. Levers pulled at the
contact pause, each with its cost and effect, are on the record too
(`BattleReport.levers`, `after_action.leverText`).

An engagement with nobody fit to put in the line is **conceded**
(`battle.concede`): a defeat `BattleReport` that holds the turn like any
other, a lost battle and a battle fought in the stats, and
`tuning.battle.score.concede` scored through `recordBattle` (victory
points at the usual rate). The after-action sheet shows what was given
up.

**Who holds the field keeps the wrecks** (12D.3, CamOps salvage): on a lost
field every hull wrecked there must be dragged off (salvage lance, trucks,
an own DropShip, your own ground) or it is the enemy's, and its pilot walks
out or goes missing — a ransom/trade/write-off decision. How a hull died
(12D.2, TechManual: cored CT, engine kill, ammunition explosion) decides
what its rebuild needs; some wrecks are scrap, only worth stripping.

**Per-operation lance tasking** (P4e): before a committed combat operation
resolves each combat lance may be assigned a role — main effort, screen,
reserve, escort, objective/security, recovery, or recon — through the `task`
and `untask` CLI verbs or the TUI 't' key on the active-contracts pane.
`operations.legalTasks`, `taskEligible`, `taskProfile`, and
`operationTaskMods` are the single rule owners; battle, queries and TUI
consume only through those functions.  Each tasked lance appears in the AAR.
The reserve-tasked lance can be committed at the battle's contact pause
(see the contact-pause levers above); the operation records it
(`reserve_committed`) and the AAR says it was committed.

**Operation report** (P4i.3): the Contracts screen's `G` key opens a read-only
report (`queries.operationReport`) over an arc contract's decided and terminal
operations. Each row carries the operation's intent, tempo, outcome, command
capacity spent, interventions applied (before battle or at its contact
pause), whether its battle's reserve was committed, tempo delay, and the campaign-state
consequence its resolution applied — world-state, relationship, rival and
officer deltas for a resolved non-combat operation. Every value is read from
the operation rule owners, never re-derived (rule 86); the report adds no
command path.

Garrison-class contracts see §8 events (raids, sabotage, riots) and, since
12D.6, a one-lance **probe** every six weeks or so.

**Ammunition is physical** (Stage 9B): munition-family pools (AC/5, AC/20,
LRM, SRM, MG rounds; energy weapons need none) are stocked per site and
expended per battle by the engaged weapon slots — itemized in the AAR. An
empty pool silences that weapon family in the power model: running out of
LRM reloads mid-contract is a logistics failure you watch happen.

**Victory conditions & contract control** (Stage 9E): each contract carries
an objective — *duration* (garrison-class: hold until the end date) or
*enemy attrition* (combat-class: an opposition force pool in BV, rolled at
acceptance and depleted across however many battles it takes). Victory
points accrue from battle score and pool destruction; attrition contracts
can complete early when the pool breaks. The player can close out a
completed objective, redeploy the company to a new contract straight from
the field, or recall it early — recall and combat-ineffectiveness (fieldable
BV under half the committed force, with a grace window to buy local
replacements from local funds) trigger the **breach clause**: pro-rated
advance clawback, forfeited remainder, reputation loss, and a cooling
period with that employer's faction.

Each engagement resolves in an isolated operation workspace, including concession,
forfeit, casualties, salvage, prisoners, completion, reports, decisions, automatic
field repair and combat history. Explicit nested-copy and promotion owners prepare
all retained payloads and live capacities before infallible publication. Failure
preserves complete gameplay state, RNG and identities. The order that ends a
battle stages the next-gap draw with that engagement and publishes both
together; an order that pauses changes only the battle record, its capacity
reserved before the append. Artillery details
use typed fixed seat/slot snapshots and normalized report tables with a required
parent presence marker; existing AAR/query panes render captured names and rounds.

## 8. Contract events & decisions

Each contract type has an event deck (weighted, MekHQ AtB-style: e.g.
*Big Battle, Special Mission, Civil Disturbance, Sports Riot, Bonus Payment,
Logistics Failure, Reinforcements, Betrayal, Star League Cache*). Events either
(a) auto-apply modifiers, or (b) surface a **decision** with 2–3 options
trading money vs. risk vs. reputation ("Local governor requests riot
suppression outside contract terms: accept for +2M and militia goodwill,
risk collateral-damage reputation hit?"). Turn-based rules (§6): decisions
sit in the inbox with a deadline days out; the default option — always the
cautious one — applies automatically if the deadline passes. Decisions are
the moment-to-moment gameplay of garrison contracts and the profitability
lever the player pulls.

Not every inbox item is one of these. A **notice** is information with an
expiry and no options — contact expected in three days — and simply
lapses. An **after-action report** is answered through its own commands
rather than by picking an option, never defaults, and holds the turn
until its calls are made (§6, §7): it disposes of hulls and people, not
of the contract bonus.

### Situations

On a contract whose arc has rows in `data/tables/situations.zon` (today the
Fracturing Garrison arc of garrison and security duty), the monthly deck
retires: on the 1st, `situations.queueDue` raises the next due situation
instead, or logs a quiet month. The weekly deck, the combat deck and every
contract without such an arc are unchanged.

- **Selection.** `situations.nextDue` is the one owner: the first row, in
  table order, of the contract's arc that the contract has not raised, whose
  earliest beat the arc has reached, whose owner archetype is one of the
  contract's attached actors, and whose actor-flag requirement that actor
  carries. It reads campaign state alone and draws no dice, so at most one
  situation comes up a month and each at most once per contract.
- **Ownership.** Every situation is brought by one of the contract's actors;
  the inbox row, its log line and the contract's record name that actor and
  archetype. A callback (a row requiring an actor flag) also says why it came
  back.
- **Costs.** Every option names a concrete cost drawn from a closed subset of
  `events.Effect` — cash, supply loss, fatigue, morale, employer standing,
  score, escalation — and at least one of them takes something from the
  company; the build refuses a free option. `contract_events.prepareCosts` /
  `commitCosts` is the one applier of that subset, for situations and for the
  event decks alike.
- **Answering.** `situations.resolve` answers through the existing `resolve`
  command and the inbox's decision modal; an unanswered situation applies its
  cautious default at the deadline through `contract_events.expireDue`. It
  validates, prepares every cost, relationship and world change and every log
  line, then commits: the costs, the owner's relationship (`actors`), the
  world's state (`world_state`), the flags each option sets, the record's
  answer, and the event leaves the inbox (rules 11–14). Situations do not
  become standing orders and never hold the turn: they dispose of no hulls.
- **Flags.** Options leave typed flags on the owning actor and the contract
  world. Three readers consume them through their owners: later situations
  (`nextDue`'s flag requirement), the local supplies valve
  (`world_state.localPriceAdjustBp`, §9.6), and the arc finale
  (`operations.selectFinale`: a finale gated on a world flag, such as the
  Fracturing Garrison's *Garrison Holds — the Town Stands With It* on a
  trained militia, outranks the unconditional fallback at an equal clock and
  is never a collapse). Actor flags recur with the actor; world flags stay on
  the planet.

## 9. HQ network, influence & supply lines (the game's centerpiece)

The player-facing loop this section defines is walked through in GAMEPLAY.md.
All constants below are initial tuning values (`// TUNE` in code), destined
for `data/tables/`.

### 9.1 Star map

Planets with (x,y) coords, faction ownership by era, tech/industry ratings
(drives local parts availability & prices — CamOps acquisition modifiers).
Jump routes computed by 30-LY hops; transit time = jump legs × recharge time
+ in-system burn.

### 9.2 Influence rings

Each HQ projects influence as a radius in LY from its planet:

    influence_ly = base(tier) + 10 × comms_level + 5 × spaceport_level
    base: field 15 LY · regional 60 LY · brigade 90 LY

The **contract market only shows offers within a ring** — reputation travels
by HPG and word of mouth, and yours only reaches so far. Offers in the
**beachhead band** (up to 30 LY past a ring) appear flagged with a penalty
preview. Beyond that: invisible. Completing a beachhead contract earns the
right to found a **field HQ** on-site — the expansion toehold that upgrades,
over time and money, into a regional HQ with a ring of its own.

**Every position comes from a conflict** (docs/p5d-conflict-world-design.md
§A "Player offers per side", §C "Offers come from conflicts"; decisions
F2–F4). `contract_market.refresh` runs daily: it retires every offer past
its `close_day`, and on the 1st every offer without one
(`offerRetires`); then each HQ's board, in HQ id order, takes each
unresolved conflict in id order and each side whose posting day has come
(`conflict.postsFrom`), whose faction hires (a Great House only an outfit
rated `house_min_index` or above), whose world the HQ sees, which it has not
posted for already (an offer on its board or a contract taken from it), and
whose `on_station_by` it can still reach: `closeDay` is `on_station_by −
bestTransitDays − position_close_grace_days`, the ETA of the company best
placed to go on the posting day (the nearest one not under contract or in
transit, from where it stands, else the seat), the same ETA the board
shows. It posts
up to `positions_per_side` positions while the board holds fewer than its
offer count, each kind drawn on `.market` among the side's kinds that keep
the board under its kind cap (a third) and garrison-class cap (half), never
a planetary assault for an outfit below `assault_min_index`; the terms keep
their owners and order (pay by kind, employer, rating, beachhead premium,
cooling and standing, command rights, the opposition's price). The
opposition is the backer's force facing the side (`conflict.opposition`):
none for a standing need, whose garrison faces no named threat and fights
no engagement until a threat emerges. Everything is prepared before the
first mutation. Accepting refuses a position past its `close_day`
(`TooLateToArrive`) or on the other side of a conflict the outfit holds a
position in (`OppositeSide`; `contract_control.requireOpenPosition`), both
before any change. Between contracts a day that posts new positions stops
an advance (`positions_posted`).

### 9.3 Capacity slots

HQ tier + facilities cap the fielded force; growth is infrastructure-first:

| Slot | Field | Regional (base → maxed) | Brigade (base → maxed) |
|---|---|---|---|
| Combat companies | 0 (hosts 1 deployed) | 1 (3 → 5 lances) | 2 (3 → 5 lances each) |
| Support company | — | 1 (lance slots unlock w/ facilities) | 1–2 |
| Air company | — | 0 → 1 (spaceport ≥3) | 1 → 2 |
| Dropship berths | 0 | 1 → 3 (spaceport) | 2 → 5 |
| Jumpship berths | 0 | 0 → 1 (spaceport ≥4 + comms ≥3) | 1 → 2 |

The Brigade column is the P1 target. Current campaigns begin with a regional
home HQ and can promote field HQs only as far as regional.

Support company lance kinds: **MASH, security/prisoner, mess, salvage,
logistics transport** — each feeds a concrete autoresolve/campaign modifier
(§7): wounded survival, prisoner handling & ransom events, fatigue/morale
recovery, post-battle salvage yield, supply buffer and the field workshop
(§9.7).

A hull is operational when it can take the field and its crew is fit for duty
(`readiness.unitOperational`); a force is operational when one of its own hulls
is (`readiness.forceOperational`). Support modifiers, recon, air cover, MASH
care and beds, the battle line and fieldable BV all count by it, so a MASH
truck with no driver, or one in the shop, helps nobody. Passive storage is a
different capability: a cargo truck must be physically present and usable
(`unit.standsInLine`), but a temporarily empty driver seat does not make its
hold disappear. Destroyed, mothballed, in-transit, and in-shop trucks provide
neither capability. `sites.companyTruckCounts` is the single owner of the
present-and-usable count.

### 9.4 Facility upgrade paths, bays & the back office

Every facility (mek_bay, warehouse/parts_depot, hospital, mess,
training_ground, hiring_hall, comms, spaceport/drop_port) has levels 1–5.
An upgrade is a **project** in the HQ's construction queue (Stage 9C):
a paperwork phase (duration shrinks with admin capacity), then
construction. Each level costs C-bills *and permanently raises the HQ's
staffing requirement* (admins, HR, finance, quartermasters — the
`Hq.staffRequired`). An HQ staffed below requirement runs facilities at
reduced effective level. C-bills are the cheap part; the payroll tail is
the real price.

**Mek bays are slots, not abstractions** (Stage 9C): a bay level grants
work slots; depot repairs, cold-storage reactivations, component
fabrication and refits are queued jobs occupying a slot for a span of days.
A full bay queue is a visible bottleneck with a visible fix. Facility presence
does not erase the HQ-tier ceiling: field HQs provide forward logistics, rest,
markets, and permitted field work, but structural depot repair and XP training
activate only after promotion to regional.

**The back office is people, not a number** (Stage 9A/9C, MekHQ's admin
roles made consequential): real personnel posted to HQ staff slots —
command, logistics, transport, HR, finance admins — and their *count and
experience levels* scale the machinery: logistics admins speed acquisition
rolls and shave delivery ETAs; transport admins improve route throughput;
HR admins (with the hiring hall) widen and improve the recruit pipeline,
speed training programs, and slow morale decay; command admins shorten
project paperwork; finance staff keep per-entity books timely. Company
generation already recruits this tail; hiring halls restock it.

**The back office works where it sits.** A person's home HQ is the HQ
they are posted to, else their company's home HQ (`GameState.homeHqOf`).
Weekly rest at home reads that HQ's mess and HR; training days read the
training HQ's HR (§9.7). A recruit's quality reads the recruiting HQ's
hiring hall and HR (`personnel.recruitBonus(hq)`, `personnel.recruitGenerated(role, hq)`):
hall boards and office staffing at their own HQ, company crews at the
company's home HQ, and the bare `recruit` verb at the outfit's seat.
Negotiation reads the offer HQ's command staff; freight reads
transport staff at the shipment's involved HQ. No office applies globally
merely because its HQ was created first.

### 9.5 Supply-line graph

HQs are nodes; **links** are player-established edges (to each other or to
the brigade HQ): charter (1) → scheduled service (2) → dedicated jumpship
(3+, requires owning one). Each link has a **throughput cap** in tons/week
(`logistics.linkTonsPerWeek`: level × `throughput_per_level` supply units ×
`tons_per_supply_unit`, the one answer for every link and route) and
per-hop multipliers; a route's totals multiply across hops:

    hop_delay_mult = 1.5 − 0.1 × link_level        (min 1.0)
    hop_cost_mult  = 1.4 − 0.05 × (warehouse + spaceport level of pass-through HQ)
    route_throughput = min over hops

So a shipment routed through an un-upgraded intermediary HQ is slower and
dearer — upgrading that HQ's warehouse/spaceport turns it into a hub and
makes every route through it better. Route quality is a strategic asset;
old HQs graduate from frontier bases into backbone.

Owned dropships/jumpships are capital: they raise link levels, cut freight,
and carry upkeep. Manpower is a supply class too — replacements flow from
hiring halls through the same network with the same delays. **Money moves
the same way** (Stage 9A): treasury transfers between outfit, HQs, and
deployed companies travel by courier with map-distance ETAs; **standing
policies** ("top this company up to 500k monthly") execute automatically on
payday through the same delayed couriers. Route throughput is measured in
**tons/week** (Stage 9B): munition pallets and spare parts have real
weight, so heavy resupply competes with everything else on the line.
Freight is quoted, then committed: `freightQuote` is pure — it refuses a
full route (`network.fitsThroughput`) but books nothing — and
`commitFreight` books the tonnage on the route once the payment has
cleared, so a refused payment never eats capacity.

Route selection enumerates all simple paths, excludes saturated hops, and then
minimizes delivery days, freight cost, and HQ id in that order
(`network.routeBetween`). A capped direct charter (capped at level-1 weekly
throughput, D2) is the fallback only when no linked route is feasible.
Automatic resupply chooses a stocked origin through this same quote
(`tick.bestSupplyHq`): prefer an HQ that can fill the line, otherwise the best
partial source, rather than always drawing from the company's home HQ.

### 9.6 Out-of-influence operation (expensive but viable)

A company deployed beyond every current ring suffers, with all effects
plateauing (no death spiral) and every effect a visible P&L line item:

- **Local supplies valve:** missing supply classes can be bought locally at
  normal field markup (×1.5) inside any current ring. Beyond the ring the
  multiplier is `2.0× + 0.5× per 30 LY band beyond the nearest ring` (cap
  4.0×), with partial bands rounded up (D1, ARCH §9.6 C15 decision), and eased
  by the planet's industry rating. It is its own transaction category so the
  ledger teaches. `field_supply.beachheadActive` gates the penalty: it is false
  once the contract world falls inside any current ring (including a newly
  planted field HQ, which has a 15 LY base ring). `field_supply.localPriceMultBp`
  and `econ/logistics.localPurchaseMultBp` are the single owners. The
  contract world's situation flags (§8 "Situations") then adjust the
  valve's price through `world_state.localPriceAdjustBp`: an open black
  market undercuts it (`tuning.situations.black_market_price_bp`), one turned
  in leaves it dearer (`informant_price_bp`). Only that world's price moves.
- **Hardship pay:** payroll bonus for remote deployment (own category), also
  gated by `beachheadActive`.
- **Morale/HR decay** and **training XP slowdown**, recovering once back in
  a ring (or once a field HQ is planted) — these penalties are not yet
  implemented; when added they must use the same `beachheadActive` gate.
- **Logistics:** no link = every shipment is ad-hoc charter at worst-hop
  rates.

A rich beachhead contract can still profit — that is the intended aggressive
play, and the ledger shows exactly what the reach cost.

### 9.7 Rotation: repair, fatigue & training tiers

Three rules give the regional HQ gravitational pull — a company *can* chain
contracts in the field indefinitely, but degrades in ways only home fixes:

**Repair echelons.** What a company's own techs (plus its salvage/transport
lances) can do in the field, given spare parts: patch **armor**, swap
**destroyed weapons and equipment** into intact mounts, **reload ammo**.
What requires a regional/brigade HQ mek bay, over real bay time:
**internal-structure damage** (torso, legs, arms), **destroyed-unit
rebuilds**, and refits. A shot-up mek keeps fighting at reduced condition;
a structurally wrecked one is deadweight until it ships home. Battle damage
therefore lands on part slots *classed* (armor / structure / weapon /
equipment / ammo) so every hit is unambiguously field-fixable or depot work.
What depot work *consumes* — one `comp_*` per destroyed or missing structure
slot, at the hull's home HQ, nothing for damaged structure or scrap — is one
rule in `sim/hq_ops.zig` (`depotNeeds`, `depotShortfall`, `componentDemand`);
the depot queue, the Market demand pane, the Forces damage pane, the pool
row, the Lab and the REPL `demand` verb all call it rather than re-deriving
it, so no screen can disagree with the bay about what is missing.

The night after a fight the company's techs make a **repair push** on the
field-fixable damage. Its budget (`maintenance.repairBudget`) is
`push_hours_bp` of the spare weekly hours of every fit tech on the
company's hulls, plus `tuning.maintenance.push_workshop_hours` when an
operational Logistics lance brings its workshop, against the field armour
and spares on hand.

**Fatigue accrues on contract, decays only at home.** Each completed contract
adds fatigue to every person attached to the company — scaled by contract
length, battles fought, and casualties taken (a quiet garrison wears
lightly; a bloody raid campaign wears hard), and compounding for every
contract since the company last rotated: sat undeployed until its people
were rested.
Fatigue never decays on a combat tour; garrison duty recovers at a share
of the home rate, the mess lance standing in for the hall. Off contract and
physically at home, fatigue decays weekly at the person's home HQ (§9.4),
faster with a better mess; returning and idle-afield companies receive no
home benefits. Effects: morale decay, the autoresolve fatigue penalty
(§7), slower maintenance and healing. Capped at 100 — degraded, never
spiraling (§9.6 philosophy).

Where a company is comes from one cascade, `posture.companyPosture`: its
contract (en route, then on station), then the road home, then a world it
idles on, else home. The world it stands on is `posture.companyWorld`: the
contract's world (en route, the destination), else the world it idles on,
else its home HQ's — also while returning, since starting home clears its
world. Transfer days (`queries.companyChoices`) and news reach
(`news.newsReach`, §6) read it.

**Training happens at home.** XP is *earned* anywhere (combat, garrison
duty, tech work), but *converting* XP into skill levels — mekwarrior
gunnery/piloting, mek tech, mechanic — requires a training program at the
person's home HQ (§9.4), which must be a regional or brigade HQ with a
training ground (`GameState.trainingHqFor`); that HQ's HR sets the
training days. A green company that never rotates stays green, no matter
how many battles it survives.

Net effect: contract profit far from a ring is real, but every month out
there quietly spends readiness — repairs deferred, fatigue banked, skills
frozen — and the P&L's companion readiness report shows the bill.

### 9.8 Site markets, the hangar ledger & cold storage

**Markets are places, not menus.** A market exists at every regional HQ
(deep stock, monthly refresh, quality scaled by warehouse/spaceport/comms
levels), every field HQ (shallow), and on the contract planet of every
deployed company (local stock set by the planet's tech/industry rating and
faction). Meks and parts *appear* in a market by **rarity tier** (common /
uncommon / rare / very rare): each refresh rolls 2d6 availability per
listing slot against the tier's target, modified by planet industry and
site facilities. Browsing the boards for a rare chassis that finally
surfaced two rings away is intended gameplay.

**Boards have other buyers** (Stage 9C.3). Hull listings — meks,
aerofighters, dropships — persist on a system's board until bought or until
they age out over a few months (someone else took it); new hulls arrive on
the monthly refresh. People move faster: hiring halls churn daily. Parts
boards split into **staples** (weapons, armor, every munition family —
always there, priced by local industry) and a few **rare slots** that may
or may not hold uncommon items — structural components, heavy weapons,
jump jets, engines — this month.

**Faction surplus flow (P3e.6).** Each month, every manufacturing faction
mints new hulls from its annual replenishment rate and adds them to its hull
pool. When the pool exceeds the faction's operational need, surplus hulls
flow onto the market board as listings backed by real `HullInstance` records
(`hull_instance_id` != `.none`). The flow is throttled by the faction's
world-conflict pressure (`enemy_influence + infrastructure_strain −
employer_control` across the faction's owned planets, scaled by
`conflict_sensitivity_bp`). Ownership moves faction → market when listed;
buying transfers the same instance to the player (faction → market → player);
an unsold listing that ages out returns its hull to the faction pool (market
→ faction). `src/sim/faction_surplus.zig` is the single rule owner
(`runMonthly`); abstraction-path listings (house board, black market,
contract world) are unaffected and keep minting at buy time unchanged.

**Black-market dispersed listings (P3f.1–P3f.3).** `domain.Planet` carries a
static `black_market: bool` flag; eight known trading hubs are flagged in
`data/planets.zon`. `econ/market.Listing` carries two fields: `planet_key`
(the surfacing world for a dispersed offer; empty for HQ-board and
contract-world listings) and `available_after` (the `day_index` from which the
listing is visible; 0 = already available; fail-closed migration default).
`src/sim/black_market.zig` is the single rule owner for the "can buyer X take
listing Y" predicate (`buyerEligible`), for lost-field wreck dispersal
(`disperseEnemyWrecks`), for monthly NPC black-market consumption
(`runNpcBlackMarketDraw`), and for monthly pirate-pool trickle
(`runPirateReplenishment`). When the battle field is lost on the pool path,
`disperseEnemyWrecks` gives every drawn destroyed enemy hull a terminal
disposition: up to `tuning.market.enemy_recovery_capacity` hulls re-home into
their source faction or merc-company roster; the remainder transfer to `.market`
and surface as dispersed black-market listings on black-market worlds other than the battle
world. `buyerEligible` applies per-buyer reach gating: pirate buyers reach
only PER-faction worlds; merc companies reach only non-PER worlds; the player
reaches a world where it has an HQ or a company deployed on an active contract.
An empty or unknown `planet_key` is unreachable by any buyer. On the first day
of each month, `runNpcBlackMarketDraw` (called from `tick.runMarkets` after
`faction_surplus.runMonthly`) evaluates each NPC buyer with its own
`BuyerKind`, so pirates consume only PER-world listings and mercs consume only
non-PER listings. A merc company pays the listing price, debited in the same
commit as the hull transfer, and takes only a hull it still needs and can
afford, so the draw never spends it below zero; pirates pay nothing.
`rivals.mercCompanyNeedsHull` owns that need test for both the draw and the
lifecycle buy, against the company's band (below). `runPirateReplenishment` then mints a monthly hull trickle
into the PER roster independently of the market. Schema v57 adds both
`planet_key` and `available_after` columns to the `listing` table with `ADD
COLUMN NOT NULL DEFAULT` migrations (docs/p3f-faction-loop-design.md §2.3, §3).
Those historical upgrades do not establish supported save formats; support is
governed by [contract rule 51](docs/engineering-contract.md#51-save-format-support-is-explicit).

**Merc-company insolvency (P3e.7).** A world merc company whose fieldable
battle value — the sum of chassis BV across all `.active` hulls in its pool
— falls below `tuning.generation.merc_company_insolvency_bv` is inactive and
can no longer be selected as the OpFor for a new arc contract. The predicate
is derived, not persisted (no schema change); it is re-evaluated on each read
and prevents selection for a new arc contract. It is not permanent: the monthly
merc lifecycle buys eligible market hulls toward full strength, and the paid
black-market draw can add further hulls the company still needs. Insolvency
gates OpFor selection only; it never dissolves a company. Every merc company,
active or dissolved, holds exactly one roster entry from its creation on, and an
empty list is a real, durable state (saved as no rows, restored on load), so a
company with no hulls — including a replacement that bought nothing — is
insolvent and ineligible until it buys back. The two single rule owners are
`mercCompanyFieldableBv` and `mercCompanyInsolvent` in `src/sim/rivals.zig`.
The insolvency filter is enforced in `instantiateRivals`
and surfaced read-only on the Operations rivals block via `RivalRow.insolvent`
(docs/p3c-economy-design.md §4, §8.G). Each founding (campaign creation or
replacement spawn) and each dissolution, with its cause, writes one `[merc]`
line to the campaign log under the market category, committed with the
lifecycle change it records.

**Merc-company dissolution (P5d.4c).** `merc_lifecycle.dissolutionCause` owns
the dissolution rule (docs/p5d-conflict-world-design.md §L7 "Dissolution"): a
company dissolves only when all three hold together on the monthly pass — its
C-bills are below zero; it has been below its band's line since its recorded
`understrength_since` for at least `tuning.generation.npc_understrength_runway_months`
(12) whole calendar months (`clock.Date.wholeMonthsBack`); and it holds no
active commitment. Low fieldable BV or lost hulls alone never dissolve a company
that can pay. `rivals.mercCompanyUnderstrength` owns "below the line" (active
meks under `merc_band.lineTarget`; vehicles and aerospace never count) and is
also the mek purchase target and the OpFor readiness test.
`rivals.mercCompanyCommitted` owns "active commitment": a rival naming the
company on a contract that `isRunning()` (decision C1; the rival overlay stands
for §D commitment records). After each surviving company's buy,
`runMercLifecycle` sets `MercCompany.understrength_since` to the pass day when
the company is first found below its line, keeps it while it stays below, and
clears it at the line; a replacement carries its founding day when its founding
buy leaves it short. Only that monthly pass writes the field, so losses between
passes are recorded at the next pass. The change commits with the rest of the
pass, even when it is the pass's only change. A dissolution liquidates and
spawns one replacement as before, and its line reads `dissolved: bankrupt,
understrength N months, no commitment`; the direct `liquidateMercCompany` call
logs `dissolved: liquidated` when the rule does not hold. Nothing yet takes a
company's cash below zero (its buys and paid draws spend only within cash, and
no upkeep exists), so no company dissolves in ordinary play until NPC costs
arrive (decision C2). `understrength_since` persists in `merc_company` from
schema v69 (NULL while at the line); a negative, non-integer or future value is
refused as `CorruptSave`. `src/sim/merc_identity.zig` owns merc-company
identity: names are campaign-unique (a collision takes a Roman-numeral suffix)
and each catalog logo goes to at most one company, after which new companies
are logo-less (docs/p3f-faction-loop-design.md §5.3).

**Merc-company bands (P5d.4b).** Every merc company has a band, its intrinsic
tier — distinct from the per-contract skull rating — from the validated
`data/tables/merc_bands.zon` (`band_1_2`, `band_3`, `band_4`, `band_5`),
owned by `src/domain/merc_band.zig` (docs/p5d-conflict-world-design.md §L8,
decisions D23–D25). A band row gives the companies of that band seeded at
campaign creation, the line target in lances (`merc_band.lineTarget`: four
lances of `force.lance_size`, 16 meks, for every band), the founding capital,
and whether vehicles may fill line positions meks leave open (only below
`band_4`). `roster_seed.seedMercCompanies` seeds the table's total (12) in its
fixed mix: each company draws its band without replacement on `.rivals` right
after its logo, then rolls its band's line target in mek hulls on `.rosters`
and starts with its band's capital. `rivals.mercCompanyNeedsHull` wants a mek
below the band's line target, a vehicle only where the band lets vehicles fill
the line, and aerospace below the unchanged air reserve;
`rivals.mercCompanyEligibleAsOpFor` requires the band's line target in active
meks. A replacement company is founded at the first, lowest band
(`merc_band.replacementBand`) with that band's capital. The company's
`band_key` persists in the `merc_company` table from schema v68, and a save
naming a band no row has is refused as `CorruptSave`.

**Hulls are priced by what they are.** A listed mek carries a rolled
condition — armor, quality grade, damaged and destroyed slots, missing
structural components — and its price reflects loadout value and that
condition: a brand-new fully loaded hull at a premium, a burned-out wreck
missing a leg and its weapons for a fraction. Buy the wreck and you own a
project: parts on hand, components fabricated, weapons and engine parts
bought, all through the same repair and bay pipeline.

**The structural-parts guarantee.** Replacement structure (internal
structure, limb/torso assemblies) for any chassis the outfit *owns* is
always available at a regional HQ by **fabrication** — at a cost multiplier
and bay time, never subject to rarity rolls. The market's rare slots may
offer them cheaper and sooner; fabrication is the floor. Rarity gates what's
*new*; it never soft-locks repairing what you already field. What *does*
gate it (12D.8) is the facility: assemblies are rated by weight class, and
a heavy one needs a level-2 mek bay, an assault one a level-3 bay at a
regional or brigade HQ. A hull the enemy kept, or one reduced to scrap, is
beyond any guarantee.

**Local operating funds.** A deployed company spends only what it physically
holds on-planet: an operating fund allotted at deployment and topped up by
(slow, costed) transfers along the supply line. Local market purchases —
including buying a local mek to replace a loss mid-contract — draw from this
fund. The brigade treasury cannot teleport; a fat wallet at home won't save
a broke company in the field this month.

**Every hull costs money, running or not.** Each unit owned carries a
monthly per-hull cost (hangar space, transport allocation, insurance, tech
attention) whether it's front-line, damaged, or a wreck awaiting depot time.
Hauling dead hulls around is a choice with a price tag — salvage, sell, or
store.

**Cold storage.** Regional HQs can mothball hulls: per-hull cost drops to a
fraction, but a stored mek needs *reactivation* (tech-days, scaled by
quality) before it can transfer to a company or fight. Cold storage is how
you keep a strategic reserve without bleeding upkeep — and why a surprise
contract can catch your reserve force six weeks from ready.

**Warehouses hold real tonnage** (Stage 9B). Every part, component, and
munition pallet has weight; an HQ's storage capacity derives from its
warehouse level (steeply — this is *the* reason to expand warehouses), and
a deployed company's field stock is capped by its logistics lance's truck
tonnage. Orders that would overflow the destination are refused with the
shortfall named. Structural work consumes **per-location components**
(arms, legs, torsos, heads — Stage 9C): buy them cheap when the market has
them, or fabricate them at a regional HQ — guaranteed, at a premium, and
occupying a mek bay while the work runs.

**Deliveries are events.** Every arrival — ordered parts, munitions,
employer-provided contract supplies (the `overhead_pct` terms deliver goods
monthly, not invisible cash), courier funds, transfers — lands in the log
and, where action may be wanted, the inbox. Nothing material happens
silently.

### 9.9 Assignments, tech time, medbay & the end-turn checklist

**Every hull has slots, and empty slots are consequences** (Stage 9C.2,
straight from MekHQ): a mek needs a pilot *and* an assigned mek tech; a
vehicle a driver and a mechanic; an aerofighter a pilot and an aero tech;
infantry a leader. A hull with no tech gets no maintenance roll, no repairs,
and no reloads; a hull with no pilot doesn't fight. Assignment is a player
verb (`assign`, `unassign`, `assign auto`), and pulling someone for
training, leave, or a transfer leaves a visible hole.

**Tech time is a budget, not a flag.** Each tech has weekly hours; each
assigned hull consumes maintenance hours by weight class; field repairs,
armor patching and bay jobs consume more, and reloading needs an assigned
tech but no hours. A full astech team multiplies a tech's throughput; a
short team halves it. Work the week's hours cannot cover waits for the
next weekly pass, and a hull whose maintenance didn't happen rolls with
the uncovered penalty. This is the lever behind "hire better techs or rotate home."

**Techs get hurt.** Weekly maintenance and large repairs roll for accidents,
scaled by job size; a wounded tech is swapped for a free one automatically
and the swap is logged and surfaced in the checklist. The **medbay** has
beds (hospital level, plus operational MASH trucks and medics in the
field) and doctor coverage. Where a wound is treated is one
`medical.Care`: home, field with an operational MASH truck (the MASH
healing multiplier), or field without. Beds go out in one pass over the wounded sorted by triage priority, then
soonest discharge, with one count per home HQ's beds (`medical.homeBedCapacity`)
and one per deployed company's field beds; a patient waits only when their
own HQ's beds are full. Leave sends the exhausted to R&R at double recovery.

**The end-turn checklist.** Ending a turn first runs `turnWarnings`:
decisions near deadline, open pilot/tech slots, understaffed HQs, hungry or
dry companies, overdrawn treasuries, idle bays with demand, untriaged
wounded. Every advance, a day or a week, asks first: the REPL prints the
list and waits for `day n force`, the TUI opens it as a modal. The asking
is advisory — urgent warnings (`WarningKind.urgent`) are marked red, and
the turn ends anyway once the player says so; only the turn holds
(`checklist.turnHold`) and an insolvent outfit refuse. Nothing the player
should have known slips past a turn boundary unannounced. A warning the player can do nothing about this
turn stays on the Desk and does not stop the turn (`WarningKind.prompts`):
a hull whose pilot or tech is wounded or on leave keeps the seat for them
(`Person.seatState`) and sits out until they are back, marked on the TO&E
with the day; only an empty seat is an open slot. Restless crew remain a
Desk and People advisory before their payday turnover roll, but do not open
an end-turn prompt.

## 10. MekLab / refits

The shipped first cut edits weapon, equipment, and ammunition mounts on the
curated chassis catalogue. A refit = diff between current
loadout and target loadout → parts list + tech-time + refit class (A–D in the
current cut, extending through F in P3 per CamOps) → validated against facility
ceiling → queued as bay work (§9.4);
the unit is out of action for the duration. Campaign-owned custom chassis and
full construction-component editing are Product completion P3.

**P3d lab (2026-10-06).** Each chassis carries its per-location crit-slot
count (`Chassis.crit_slots[8]`, TechManual standard-IS values) and an arm
actuator flag (`ArmActuators`: full / no\_hand / no\_lower\_arm) that drives
`fixedOccupants` — the pure derivation of cockpit, sensors, life-support,
engine, gyro, leg and arm actuator slots for every location. The Lab screen
renders these as a per-location construction grid (LAYOUT pane): fixed
occupants, mounted equipment, and remaining free slots. The variant marker
(`variantMarker` in queries) flags a hull whose loadout differs from the
catalogue baseline. The install path now includes a location-scoped part
picker (`install_at` modal opened by Enter on a free slot), while `m`
commits the plan as a bay job. Engines, gyros, cockpits, and actuators are
fixed derived facts at this stage; full part-level edit of those components
remains a future target.

## 11. Economy

All money is `i64` C-bills (no floats in the ledger, ever). Income: contract
base pay from average operating cost per combat company, then operation,
opposition, employer, reputation, and term multipliers; candidate-company
strength changes its skull rating, not the posted pay. Other income: advances,
salvage sales, battle-loss comp. Costs:
payroll (CamOps salary table), unit maintenance & spares, supply purchases,
freight, HQ construction/upkeep, dropship/jumpship charter or upkeep, loan
service, event outcomes. The monthly **per-company P&L** is a headline screen:
the game is about making each company profitable.

**Money lives in places** (Stage 9A). Three treasury tiers — the outfit,
each HQ, each deployed company's operating fund — and spending resolves
where the spender stands: a company in the field buys only with what it
physically holds; HQ construction and markets draw HQ funds. Transfers
travel by courier (§9.5) manually or via standing policies. Every
transaction is tagged (company, HQ, contract), so **every entity has its
own browsable ledger and P&L**, and the structured campaign log (battles,
decisions, deliveries, construction, medical — all tagged the same way) can
be filtered to any company or HQ's full history.
Sold HQs retain their exact ID, name, planet, tier and sale day in a separate
persisted historical archive. Live HQs alone provide treasuries, facilities,
markets, influence and transport capacity. Ledger/log tags, retained contract
board provenance and terminal order destinations keep their original identities;
active destinations require live HQs. See the
[HQ retirement policy](docs/p2-artillery-acquisition-design.md).

**Cost attribution and profit shares.** A company's own operating costs carry
its tag, and also its contract's tag while it is out on one (in transit or on
station). These are its payroll and hardship pay, hull upkeep (with its attached
artillery's carry), weekly maintenance consumables and repair labour, the
service of its attached artillery, freight shipped to it (or from it to an HQ),
orders for its site, charter and local supplies. Staff and hulls in no company
are outfit overhead. Shared costs never carry a contract tag: HQ upkeep, HQ
depot bay work, supply-link upkeep, and loan interest and principal. Neither do
fund transfers, severance, retirement payouts or ransoms, which keep only their
company tag. A contract's net is the sum of every row tagged with it, from
signing through completion. Profit shares (`shares`, AtB) are `shares%` of that
net plus any early-completion bonus, paid at completion and floored at zero. A
contract that lost money pays nothing, and the log says what it netted. When a
company is disbanded, its ledger rows become outfit overhead. They keep their
HQ and contract tags, and its closed contracts keep their records with no
company.

**Breach clause** (Stage 9E). Failing or abandoning a contract — recall, or
combat-ineffectiveness with no affordable local replacements — costs a
pro-rated slice of the advance back, forfeits remaining payments, −2
reputation, and a cooling period with the employer's faction (their offers
run thinner and cheaper for about a year).

**Faction hull pools** (P3e.4). At `create_commander`, every manufacturing
faction (nonzero `replenishment_hulls_per_year`) receives a seeded pool of
`replenishment_hulls_per_year × generation.faction_roster_seed_years` hull
instances drawn deterministically from the RAT via `gen/roster_gen.zig` on
the dedicated `.rosters` RNG stream. Each hull is a `HullInstance` with
`owner = .{ .faction = key }` and one open `.initial` provenance interval;
membership is written to `faction_rosters` in the same atomic commit as the
hull record. P3e.5 subsequently seeds the PER pool and world merc companies at
campaign creation.

## 12. Persistence

SQLite: **one store file, many campaigns** (Stage 11). Every table carries a
campaign id and a `campaign` registry lists playthroughs (name, commander,
in-game date, save sequence); the player saves, lists, loads, and deletes
campaigns from one place. The open campaign is a `lobby.Session`: the
lobby creates, loads, saves and closes it, and the TUI and REPL hold the
session and reach the campaign only through `state()` for queries and
commands. The sim core never touches SQL: `src/persist/`
maps `GameState` ↔ rows (the executable DDL lives in `persist/store.zig`;
`docs/schema.sql` is a commented mirror of it; its header names the
schema version it matches). Static data (chassis,
weapons, planets, name tables, salary/price tables) ships as `.zon` files in
`data/` — versioned separately from saves; saves reference static data by
stable string keys. Each campaign records its `schema_version`; support and
rejection follow
[contract rule 51](docs/engineering-contract.md#51-save-format-support-is-explicit).
The golden-master hash proves exact current-format round trips: save → load →
identical hash, and identical evolution after load and executable restart;
a test that differs names the first value that did not survive
(`digest.firstStateDifference`).

**Current format boundary.** New empty stores
initialize schema 74 transactionally. Existing store and campaign versions
must both be 74 once the store is open; a schema 71, 72 or 73 store is
migrated on open (below), older formats (70 included) are refused intact and newer
formats retain their distinct refusal before persistent mutation. A nonempty unversioned
database is not a new store, and a current store is validated without healing
missing tables or rows. Outside a supported migration, no automatic reset,
deletion, rewrite, backfill or reseeding is allowed. Store adoption, campaign
loading and overwriting enforce the format boundary before decoding or
replacing gameplay rows.

**Loading fails closed.** The schema declares enforceable foreign keys
(containment references); the historical v37 table-rebuild declaration does not
grant upgrade support under rule 51. The loader
remains the integrity check for soft and polymorphic references that use
NULL/0-as-none: every stored integer and id is range-checked, and a
missing parent row, an unknown enum value,
treasury or site kind, a bad difficulty, an unresolved chassis, part,
planet or faction key, or a battle-report display copy that is not
markup-safe (`validateStoredStrings`) returns `CorruptSave` — nothing is
skipped or defaulted. Loading an unknown campaign id, or saving over a
deleted one, is `NoSuchCampaign`; a first save takes its `campaign_id`
only after COMMIT.

**A battle in progress is saved** (schema 65): `battle_in_progress` (the
contract and its pause) and `battle_in_progress_order` (each order, with the
intervention an `intervene` order calls, and the pause report it reached:
odds, lever modifier, reserve commitment and capacity spent included), each
report's fought phases in `battle_report_phase` (the decisive phase's
`lever_mod` included) and its levers in `battle_report_lever` (kind, cost and
decisive-roll modifier); `operation.reserve_committed` keeps a committed
reserve. The record count (meta `battle_in_progress_count`),
each record's order count and each report's phase and lever counts are saved as
completeness checks, so a removed record, a truncated course of orders or a
report missing phases or levers is corruption, never a battle not yet engaged, an
earlier pause or a concession. The loader refuses an unknown phase, order,
intervention or lever kind,
a record for a missing or inactive contract, more than one record, orders out
of sequence or orphaned, a malformed integer, a count the rows do not match,
a course of orders that `battle_phases.recordConsistent` rejects (a lever
pulled twice, or lever figures other than the owners' sums), report
phases that are not a whole course agreeing with the report's verdict
(`battle_phases.reportPhasesConsistent`): every rolled phase's margin must
need a die 2d6 can show under its recorded modifiers, levers must carry
their owners' cost and modifier, at most once each, summing to the decisive
`lever_mod`, and a report with no
phases must be a concession or a forfeit as those write it, with no measured
power, losses, kills, prisoners, hits or levers; and a reserve commitment on
a non-combat operation. Once the campaign is loaded,
`battle.validateInProgress` replays every prefix of the orders from live
state and requires exactly the pause stored for it, with the engagement
due, nothing else holding the turn, no ROE order the employer reserves and
every lever still allowed (`leverAllowed`).
A forged pause is refused, never repaired. Saving mid-battle, loading and
finishing gives the same digest as finishing without the save.

**Situations are saved** (schema 66): each contract's records in
`contract_situation` (key, day, owning actor, answer or NULL while it
awaits one), a pending situation's key and owner on its `pending_event`
row, and the flag sets as bitmasks in `actor.flags` and `world_state.flags`
(bit = the flag's declared value). The loader refuses an unknown flag bit,
an unknown situation key or one of another arc, an owner that is not the
contract's actor of that archetype, a situation raised twice on a contract,
records out of order or dated after today, an answer that is not an option,
and a pending situation and record that disagree (a pending situation with
no open record, an open record with no pending situation, or an answered
record still pending). A situation's options are rebuilt from its row.

**Artillery field freight is saved** (schema 67): `artillery_formation` adds
the `field_freight` (source HQ, company, dispatch day, ETA, paid cost) and
`field_return` (target HQ, dispatch day, ETA, paid cost) placements in the
existing nullable payload columns; SQL checks and the loader both require
exactly each tag's own columns. Pool and travelling crew rows reload; the
loader refuses a company member on a pool or travelling seat, field freight to
a non-company force, inbound plus attached carriers over the company's cap,
and a return leg to a missing HQ.

**Personages are saved** (schema 70 and later; `key` and `family_key` from
schema 72): one `personage` row each (role, names,
faction and seat keys, the motive set as a bitmask with bit = the motive's
declared value, ambition, provenance, generator version, data key and
family key) and the meta counter `next_personage_id`. The title is not
saved: it is read from the data row by key. SQL checks bound the ordinal,
role, motive count (two or three), ambition (0–100), provenance and
generator version, and tie them together: a `procedural` row has an empty
key and family, generator version 1 and a ruler or leader role; a `canon`
or `authored` row has a key and generator version 0. A partial unique
index keeps each non-empty key once per campaign. The loader refuses an
ordinal that is not an integer equal to the row's position (0, 1, 2, … as
saved), and `personages.validate` refuses an
unknown key, seat, enum or motive bit, a ruler on a world that does not hire or of another faction than its world's,
two rulers on one world, a leader for a faction that gets none, off its
capital or doubled, a campaign with a commander missing any ruler or leader,
personages in a campaign without one, and an id at or above the counter; a
key naming no `personages.zon` row, a keyed row whose role, names, faction,
seat, family, motives, ambition or provenance differ from its data row, a
duplicate key, a procedural heir, family member or official, and a
generator version that does not match the provenance. Which data rows a
campaign holds is not checked: the start year is not saved.

**Older stores migrate on open** through a chain of migrations, each from
one version to the next (`Store.migrate`; schema 71 is the oldest
supported format, `oldest_supported_schema_version`). A v71 store runs v71
→ v72, v72 → v73, v73 → v74 and v74 → v75; a v72 store the last three; a
v73 store the last two; a v74 store only v74 → v75. The whole chain
is one transaction with foreign keys off, ending with an empty `PRAGMA
foreign_key_check` (else `CorruptStore`) and the current schema check
before COMMIT; any failure rolls back with the file at its original
version. Each migration keeps a frozen definition of its source format and
validates it before its own statements: a malformed or mixed-version store
is `CorruptStore`, untouched. `ddl_v72` and `index_ddl_v72` are schema
v72's DDL byte for byte, and `conflict_v73_ddl` is the `conflict` table
v73 added, and `ddl_v74` and `index_ddl_v74` are schema v74's (a test pins
their SHA-256); `ddl_v71` is derived from `ddl_v72`, `ddl_v73` is v72's plus
`conflict_v73_ddl`, `ddl_v74` is v73's with `contract` and `conflict` in
their v74 definitions, and the current `ddl` is v74's plus `news_item`.

- **v71 → v72** (`migrateV71ToV72`). The source check: every v71 table and
  column (the frozen v71 `personage` definition, every other table as v72
  defines it), exactly the v71 `personage` columns, and only v71
  campaigns. It creates `personage__v72` from the v72 DDL, copies every row
  with `key = ''` and `family_key = ''` and every other column as stored,
  drops `personage`, renames the new table to `personage`
  (create–copy–drop–rename, so `personage_relation`'s foreign keys keep
  naming `personage`), recreates its indexes and sets every campaign and the
  store to 72. A migrated campaign keeps every procedural personage,
  relation, id, counter and stream exactly and gains no data row (decision
  M1).
- **v72 → v73** (`migrateV72ToV73`). The source check: every v72 table and
  column, no `conflict` table, no `next_conflict_id` counter, and only v72
  campaigns. It creates `conflict` and `ix_conflict_cid`, gives every
  campaign `next_conflict_id = 1`, and sets every campaign and the store to
  73. A v72 campaign has no conflict, so it migrates with none; every other
  value, id, counter and stream is unchanged.
- **v73 → v74** (`migrateV73ToV74`). The source check: every v73 table and
  column (`ddl_v73`), exactly the v73 `conflict` columns, no `family` or
  backer column, and only v73 campaigns. It rebuilds `conflict` and then
  `contract` from the v74 DDL (create–copy–drop–rename, rows in stored
  order, indexes recreated): every v73 conflict is offensive, so each gains
  `family = 'offensive'`; every v73 contract and offer has no backer, so
  each gains `conflict_id` NULL, `side = 'defender'` and no `on_station_by`
  or `close_day`. It sets every campaign and the store to 74; every other
  value, id, counter and stream is unchanged. An offer without a backer
  loads (only offers posted at v74 come from conflicts) and leaves the board
  at the next month start.
- **v74 → v75** (`migrateV74ToV75`). The source check: every v74 table and
  column (`ddl_v74`), no `news_item` table, no `next_news_id` counter, and
  only v74 campaigns. It creates `news_item` and `ix_news_item_cid`, gives
  every campaign `next_news_id = 1`, and sets every campaign and the store
  to 75. A v74 campaign has no news item, and reach is never back-filled, so
  it migrates with none; every other value, id, counter and stream is
  unchanged.

A migrated campaign loads with the digest of the same state saved directly
at v75 and plays on as it would have.

**Conflicts are saved** (schema 74): one `conflict` row each (ordinal, id,
template key, world, aggressor and defender factions and personages,
instigator, staging world, the four days, each force's lances, quality, lance
BV and lance tons, the outcome or NULL, and the family) and the meta counter
`next_conflict_id`. SQL checks bound every integer and text column, lances
(1–255), quality, outcome and family tags, and each family's shape: an
offensive row holds every aggressor-side column, the day order and no
`stood_down`; a standing row holds none of them, `discovery_day =
opened_day`, its defender as instigator and only `stood_down`. `(cid, id)`
and `(cid, ord)` are unique, and the aggressor, defender and instigator are
tied to `personage` rows by foreign key. The loader decodes each row
exactly (tags on their full bytes, checked integers, each aggressor-side
part whole or absent, the ordinal equal to the row's position), and
`politics.validate` refuses an unknown template, world or faction, a
template of the other family, a dangling personage, an instigator that is
not the side personage its template names, a staging world other than
`stagingWorld`'s, a broken day order, a strike day whose preparation (less
the travel) or fighting days fall outside their tuned ranges, an opening
after today, an unresolved conflict at or past its expiry or a resolved one
before it, two unresolved offensive conflicts on one world, more than
`max_open_conflicts` unresolved, a force without a lance or with negative
BV or tonnage, an id not above the previous row's (ordinal order must be id
order), and an id at or above the counter; a standing need with any
aggressor-side part, a discovery other than its opening, an instigator
other than its defender, a defender faction other than its world's, an
outcome other than `stood_down`, or a second unresolved need on its world;
and an offensive conflict missing an aggressor-side part or stood down. Any
lance BV the schema admits resolves exactly: the win chance is computed in
i128. A save made under a `political_events.zon` without a template a
conflict uses is refused.

**News items are saved** (schema 75): one `news_item` row each (ordinal,
id, kind, conflict id, presence kind, the presence's world and the text)
and the meta counter `next_news_id`. SQL checks bound the ordinal, id and
conflict id, the kind and presence tags, and require a non-empty world and
text; `(cid, id)`, `(cid, ord)` and `(cid, conflict_id, kind)` are unique,
and the conflict is tied to a `conflict` row by foreign key. The loader
decodes each row exactly (tags on their full bytes, checked integers, the
ordinal equal to the row's position), and `news.validate` refuses a counter
of 0, an id not above the previous row's or at or above the counter, a
conflict the campaign does not hold or a standing need, an item whose day is
after today, a resolution of an unresolved conflict, an unknown presence
world or one beyond `news_reach_ly` of the conflict's world, empty text or
text that is not UTF-8, and two items of one kind for one conflict. Stored
text is reloaded, never regenerated.

**Each position's backer is saved** (schema 74) on its `contract` row:
`conflict_id` (NULL without a backer), `side`, `on_station_by` and
`close_day`. SQL checks bound them, keep a row without a backer at the
default side with neither day, keep both days set or both NULL with the
close no later than the station day, and tie `conflict_id` to a `conflict`
row by foreign key. `politics.validate` refuses a backer the campaign does
not hold, an employer other than the backer's faction on that side (a
standing need has no aggressor side), an `on_station_by` other than the
backer's (`conflict.onStationBy`), a close day without a station day or
after it, and a row without a backer holding a side or a day.

**Personage relations are saved** (schema 71): one `personage_relation` row
each (ordinal, from and to personage ids, kind tag, weight). SQL checks bound
the kind, the weight (1–100) and both ids, refuse a self-relation and a
symmetric row without `from_id < to_id`, keep `(from_id, to_id, kind)`
unique, and tie both ids to `personage` rows by foreign key. The loader
decodes each row exactly (kind on its full bytes, checked integers, the
ordinal equal to the row's position), and `personage_relations.validate`
refuses a dangling endpoint, a self-relation, a reversed symmetric row, a
duplicate, a weight off the tuned scale, a liege from anyone but a ruler or
to anyone but its own faction's leader, a second liege, a ruler of a
leader-bearing faction without one, rival and ally on one pair, and
relations without personages.

**RNG state is saved per stream**: the campaign seed plus one
`rng_stream` row per named stream (format 1: the generator's words,
little-endian). The approved current-format boundary requires the seed and
exactly one valid row for every required named stream. Missing or malformed
state, duplicate rows and unknown streams are `CorruptSave`; current rows never
default to fresh streams, so a current-format save without its `politics` row is
refused. Unsupported old stream blobs are not loaded. Adding
an unused stream preserves existing stream identity and state; deterministic
initialization in an older save would require an explicitly supported migration
under rule 51. Current-format loading enforces these requirements without
legacy-blob or fresh-stream fallbacks.

**Licensing note:** MekHQ/MegaMek code is GPLv2+ and their data files carry
their own terms; BattleTech IP belongs to Topps/CGL, with Microsoft rights over
video game usage. We re-implement rules and keep our own data format. Don't
bulk-copy MegaMek data files into the repo without deciding on licensing.
The `canon` rows of `data/tables/personages.zon` restate BattleTech setting
facts (names, offices, seats, family ties) as summarized by Sarna
(BattleTechWiki) in project words; no text is copied.

## 13. Zig specifics

- **Zig 0.16**, no external dependencies for the core (SQLite is the system
  library through `@cImport` in `persist/sqlite.zig`; music is the system
  player as a child process; the TUI is hand-rolled ANSI).
- Allocators: `GameState` lives in an arena per campaign; per-tick scratch
  arena reset daily; frontends own their own.
- Errors: sim-core functions return typed error sets; player-command
  validation returns `CommandError` values (not exceptions) so the UI can
  explain refusals.
- Testing: every module carries unit tests (`zig build test`); golden-master
  sim tests: fixed seed + scripted commands → hashed state snapshot.
  `digest.stateHash` digests every persisted field (`sim/digest.zig`: each
  element in order, each map order-independently, RNG words and ID
  counters included). Every field carries a persistence class in
  `GameState.field_persistence` (persisted, derived, session, scratch),
  checked at compile time both ways, and the digest hashes the persisted and
  derived ones. A played year is pinned to one constant. The
  determinism pillar makes regression testing nearly free.
- The gate: `zig build test --summary all`, `zig fmt --check`, and
  `docs/verify-contract.sh`, which runs the contract's mechanical checks
  (layering, frontend boundary, core purity, broad catches, module headers)
  and prints `CONTRACT CHECKS OK` or each
  violation. CI runs the gate and both smokes on Linux and macOS, and
  builds a ReleaseFast release from a tree holding only the package's
  declared paths (`docs/clean-package.sh`), on every change. The build
  rejects any target outside the supported set {macOS, Linux, Windows}
  (rule 65); CI also compiles for each supported target to verify the
  target-gated terminal and process code compiles on all three.
- Style and every other coding rule: [`docs/engineering-contract.md`](docs/engineering-contract.md).

## 14. Directory layout

```
build.zig, build.zig.zon
ARCHITECTURE.md, GAMEPLAY.md, ROADMAP.md, TODO.md
docs/            schema.sql, engineering-contract.md, contract-exceptions.md,
                 tui.md, modding.md, verify-contract.sh, smoke scripts
data/            static game data (.zon): chassis, parts, planets, factions,
                 tuning; data/tables/ for rule tables
src/
  main.zig       demo CLI and REPL entry (frontends layer)
  root.zig       module root, re-exports
  domain/        entities and rule tables: types person unit part chassis
                 force contract hq planet faction tuning skulls scenario …;
                 clock events autoresolve battle_report hq_link actor rival officer world_state
  sim/           state plus focused personnel/posture/treasury owners;
                  crew tick commands battle
                  medical maintenance field_supply sites network
                  rng contract_market starter_company toe actors rivals officers world_state …;
                  queries.zig (read-only views),
                  cli.zig (verbs), table.zig (markup), digest.zig (hash)
  econ/          finance logistics market
  gen/           company_gen person_gen
  persist/       sqlite.zig (C wrapper), store.zig (campaign saves), lobby.zig
  tui/           terminal client: app.zig, screens/, keys (bindings), term,
                 screen, emblem, music
```

## 15. Current catalogue decisions

- Era/start date: scaffolding defaults to **3025** (Succession Wars — scarcity
  makes logistics shine). Late-era tech (Clan invasion) later.
- Star-map scope: the checked-in curated catalogue is the v1 map and remains a
  normal data/mod-overlay input rather than generated source.
- Unit scope: the checked-in curated chassis catalogue is the v1 set and can be
  replaced by the same data/mod-overlay mechanism.
- Catalogue scans remain deterministic and linear at the current scale. A
  spatial index is warranted only if measured campaign-scale use requires one.
