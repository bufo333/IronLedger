# Roadmap — staged build-out

Each stage ends with: `zig build test` green, a runnable CLI demo of the new
capability, and updated docs. Stages are ordered so something is *playable*
early (a single company on a garrison contract) and the extensions (multi-
company, HQ network) land on a proven core.

## Stage 0 — Scaffolding ✅
Project skeleton, module layout, typed IDs, money/date/RNG primitives,
architecture docs, SQLite schema draft.

## Stage 1 — Time & state core ✅
`GameState`, campaign clock, the daily tick pipeline (empty phases), command
tagged-union + dispatcher, event queue, deterministic RNG streams,
golden-master test harness (seed + commands → state hash), CLI REPL
(`zig build run -- --repl`).

## Stage 2 — Personnel & payroll ✅
Person entity, skills/XP/experience levels, roles, CamOps salary table,
hiring/firing/recruiting commands, name+person generators (AtB 2d6
experience rolls), XP progression machinery (`spendXpToImprove`, doubling
costs — the Stage 8 training system gates it by HQ), monthly service XP,
per-category P&L summaries (`finance.summarize`). Demo: generate 30 people,
run 3 months, print P&L.

## Stage 3 — Units, forces & company generation ✅
Chassis catalog (curated 3025 set in `data/chassis.zon`, comptime-imported),
Unit instantiation with structure + loadout part slots, TO&E tree in
GameState (company→lances, crew assignment kept consistent across unit/
force/person), the **AtB-style company generator** (`new_company` command:
3 line lances via RAT weight-class rolls + a Recon Lance of ≤40t scouts,
plus an attached **Omega Company** support echelon — salvage, MASH w/
medics, logistics, and security lances — and the tech/mechanic/medical/
admin tail), hull upkeep billed monthly, and player identity (rename
outfit/force, emblem bytes). Demo: `newco` in the REPL stands up the full
starter force.

## Stage 4 — Contracts, finances & the starter ring ✅
**Character creation** (`create_commander`): origin faction places the
starter regional HQ on a weighted-random world in the commander's space;
profession grants one 2% edge (quartermaster/paymaster/chief_engineer/
line_officer — freight, payroll, repair, fatigue recovery). Minimal star
map (`data/planets.zon`, 27 worlds, all five houses), influence-ring
contract market with beachhead premiums & hardship pay, offers priced off
the outfit's operating cost × market margin × employer/reputation
multipliers, contract lifecycle (accept → transit → active → completed,
monthly payments net of the 25% advance, transit freight with employer
transport share), reputation gain on completion, loans with monthly
service. Demo: garrison contract run to profit; REPL: `start`, `offers`,
`accept`, `loan`, `hqs`. (Deferred to Stage 7: battle-loss comp, score-based
completion outcomes.)

## Stage 5 — Maintenance, parts & acquisition ✅
Part catalog (`data/parts.zon`, every loadout key resolves — tested),
weekly maintenance checks (tech pool coverage, TN from quality + deployment,
quality drift both ways, snake-eyes part breakage), weekly repair pass with
the field-vs-depot split (destroyed parts consume spares; structural work
only at home with a capable mek bay), acquisition orders (logistics-admin
roll vs. rarity, industry-eased, delivery ETAs; **structural-parts
guarantee** at 1.5×/7 days), site-market board at the HQ (rarity-rolled unit
& part listings, `shop`/`buy`), cold storage (`mothball`/`reactivate`,
20% upkeep, quality-scaled wake-up time), supply consumption on deployment
(provisions per head + ammo, local prices beyond the ring), and offers now
priced off true ops cost incl. maintenance. Attrition on garrison duty is
real: quality slides on long deployments unless your techs are better than
your contracts are long. Chief-engineer 2% now live on all repair costs.

## Stage 6 — Contract events & decisions ✅
**Turn-based restructure**: time moves only via end-turn; nothing blocks an
advance. Decision events land in the **inbox** with a 7-day deadline and a
cautious default that applies automatically (and is logged) if unanswered.
Per-contract-class event decks (garrison: pirate raids, disease, civil
disturbance, supply failures, caches, off-contract requests; combat:
betrayal, interdiction, heavy fighting, intel, salvage, militia offers)
rolled monthly per active contract; typed effects (cash, reputation, morale,
fatigue, XP, contract score, unit damage, parts windfalls) applied to real
state; campaign log. REPL: `inbox`, `resolve`, `log`. Garrison gameplay is
now complete.

## Stage 7 — Battle autoresolution ✅
`sim/battle.zig`: combat-class contracts schedule engagements (~2/month);
each resolves from campaign state — per-lance element power (BV × crew
skill × condition × quality) with campaign modifiers (spares on hand,
beachhead provisions strain, fatigue, morale, recon lance, and the support
echelon: MASH turns KIA rolls survivable, mess softens post-defeat morale,
security takes ransom-worthy prisoners, salvage lance strips 25% more).
Opposed 2d6 + power-ratio bonus → outcome bands; damage lands on armor and
real part slots (feeding Stage 5 repair), pilots wound/die, **salvage only
if you held the field**, battle-loss comp per terms, XP to engaged pilots,
and score accumulates into completion outcomes (reputation scales with
score; ≤ −5 fails the contract outright). Two-line AARs in the campaign log
name the causes. Demo: beachhead objective raid vs. house regulars.

## Stage 8 — Medical, morale, training & rotation ✅
`sim/medical.zig`: wounds triaged and healed on doctor/facility timelines
(1 doctor per 25 patients; MASH speeds field recovery, the home hospital
beats both; understaffed infirmaries run 1.5× slower). The **rotation
loop** (ARCH §9.7): completed tours bank fatigue scaled by length, battles
fought and casualties — compounding per contract since last rotation;
fatigue decays only at home (mess-boosted, line-officer +2% live), morale
grinds down in the field past fatigue 60 and drifts up with rest; a rested
undeployed company resets its rotation debt (logged). Skill training:
`train` command gated on a regional/brigade HQ training ground and
non-deployment, validated up front, 30-day programs completing via the tick
(XP spent on completion). Per-company **readiness report** (`readiness`)
beside the P&L. (Deferred: per-location injuries — schema is ready.)

Stage 9 is split into 9A–9E after the pre-Stage-9 oversight audit
(2026-09-03): drillable logs, decentralized treasuries, physical supply
depth, HQ operations queues, network/TO&E tools, and formal contract
control. Together they are the game's thesis stages.

## Stage 9A — Treasuries, ledgers & the structured log ✅
Structured log entries (`LogEntry{day, category, company, hq, contract,
text}`) replacing the flat strings — filterable in the REPL (`log battles`,
`log company 1`, ...). Decentralized treasuries: `Hq.funds` + live
`force.local_funds`; spending resolves by location (field purchases draw
company local funds — the "treasury cannot teleport" rule enforced; HQ
construction/markets draw HQ funds). `Transaction.hq` tag; per-company AND
per-HQ P&L (`pnl <entity>`) and browsable ledgers (`ledger <entity>`).
Money movement: `transfer` command creating couriered transfers with
map-distance ETAs (min 3 days), arrival events; **standing policies**
(`policy <entity> topup <floor> <cap>`) executed automatically on payday
through the same delayed couriers.

## Stage 9B — Supplies & munitions ✅
Per-munition ammo as family pools (`ammo_ac5/ac20/lrm/srm/mg` stock items;
energy weapons need none) plus `provisions`/`medical_supplies`; stocks held
per site (each HQ, each deployed company). Consumption: provisions daily by
headcount, medical per wound, **ammo expended per battle by engaged weapon
slots** — itemized in AARs; an empty family pool silences that weapon
family in the power model. Resupply: `order` extended to munitions &
supplies, destination-aware, with delivery log/inbox events; contract
`overhead_pct` becomes monthly employer supply deliveries (with events).
**Physical storage**: every item has `pallet_tons`; HQ capacity =
f(warehouse level) — the reason to expand warehouses; deployed field stock
capped by the logistics lance's truck tonnage; overflowing orders refused
with the shortfall named; shipment tonnage consumes route throughput.
Reports: `supplies` (per-site stocks, tons used/capacity, burn, days left),
`demand` (parts needed from damage: on hand / on order / shortfall).

## Stage 9C — HQ operations: bays, construction queues, components ✅
(Also: the back office made real — starter HQ staff recruited and posted;
command admins shorten paperwork, logistics admins work acquisition rolls
and shave lead times, transport admins cut freight, HR staff + hiring hall
improve recruit rolls, training length, and home morale.) Mek bay occupancy (level × 2 slots): depot repairs, reactivations,
fabrication (and later refits) become queued jobs holding a bay for a day
range; `bays <hq>` view. Construction queues: `build`/`upgrade` commands →
paperwork (admin-scaled `paperworkDays`) then construction, paid from HQ
funds, permanently raising `staffRequired`; `projects <hq>` view.
**Structural components** replace generic structure: `comp_arm/leg/torso/
head/ct`, matched to slot locations — bought (market, rarity-gated,
cheaper) or fabricated (regional-HQ guarantee, ×1.5, occupies a bay).

## Stage 9C.2 — Assignments, tech time, medbay & the end-turn checklist ✅
(Added 2026-09-03 from the personnel audit; precedes 9D because transfers
need real assignments underneath.)
- **Crew & tech slots per unit**, MekHQ-style: a mek needs a pilot AND an
  assigned mek tech; a vehicle a driver AND a mechanic; an aerofighter a
  pilot AND an aero tech; infantry a leader; MASH/cargo trucks a driver and
  a mechanic. **No assigned tech → no maintenance roll, no repairs, no
  reloads** for that hull; no pilot → it doesn't fight. Company generation
  fills slots; `assign`/`unassign`/`assign auto` manage them afterward.
- **Tech time is a budget**: each tech has weekly hours; every assigned
  hull costs maintenance hours by weight class (astech teams multiply a
  tech's throughput; short teams halve it); field repairs, armor patching,
  and reloading cost additional hours; bay jobs draw on the HQ's techs.
  Over-budget work queues, and missed maintenance rolls with the uncovered
  penalty. Techs pulled for training or wounded leave their hulls uncovered
  until swapped.
- **Roster reviews**: `roster co:<id>` lists every hull with pilot/tech and
  every open slot; `roster hq:<id>` lists posted staff vs. required and the
  unassigned pool; hire/fire/train/leave/assign from the same view.
- **Hiring halls**: candidates appear weekly at each HQ (count/quality by
  hiring-hall level + HR staff), with asking bonuses; `hire <candidate>`
  replaces instant recruiting (kept as a debug command).
- **Tech injuries**: weekly maintenance and large repairs (depot/bay jobs)
  roll for accidents; severity scales with job size. A wounded tech is
  swapped for a free one automatically (logged, surfaced in the checklist).
- **Medbay**: beds = hospital level × 10 (+4 per MASH truck in the field);
  `medbay` lists patients, days remaining, doctor and bed coverage; over
  capacity, low-priority patients' timers pause — `triage <person> high`
  puts someone at the front. `leave <person> <days>` sends the healthy but
  exhausted to R&R (double fatigue decay, unavailable).
- **End-turn checklist**: `day` first runs `turnWarnings` — unanswered
  decisions near deadline, hulls with open pilot/tech slots, understaffed
  HQs, hungry or dry companies, overdrawn treasuries, idle bays with demand,
  untriaged wounded — and refuses to advance until acknowledged (`day
  force`). The TUI will render the same list as a modal.

## Stage 9C.3 — Market dynamics & damaged hulls ✅
(Added 2026-09-03.)
- **Hiring halls churn daily**: each turn rolls arrivals and departures on
  every board (people move fast — days, not weeks); the weekly refresh
  becomes a daily trickle with a 2d6 "who walked in / who left" roll scaled
  by hiring-hall level and HR staff.
- **Hull listings persist**: meks, aerofighters, and dropships stay on a
  system's board until bought or until they age out (2–4 months, rolled at
  listing), then vanish — other buyers exist — and new hulls arrive on the
  monthly refresh. Listings carry `listed_day`/`expires_day` (schema has
  them); refresh no longer wipes the board.
- **Staples vs. rare slots**: weapons, armor, and every munition family are
  always on the board (staples, priced by industry); a few **rare slots**
  per board roll for uncommon/rare items — structural components (legs,
  heads, torsos), heavy weapons, jump jets, engines. No guarantee they're
  there when needed: the fallback is fabrication at a regional HQ (more
  cost, bay time) before the bay can install.
- **Condition-priced hulls**: a listed mek carries a rolled condition —
  armor %, quality grade, damaged/destroyed slots, missing structural
  components — and its price reflects loadout value and condition: a
  brand-new fully loaded hull at a premium, a burned-out wreck missing a
  leg and its weapons for a fraction. Buying a wreck creates the unit in
  that state; the player repairs it with parts on hand, fabricates missing
  components, and buys weapons/heat sinks/jump jets/engine parts to bring
  it to a working hull — through the normal repair/bay pipeline.

## Stage 9D — Multi-company, the network & TO&E tools ✅
`assign <company> <hq>` (supplying_hq live; capacity slots enforced via
`hq.capacity()`); supply-line routes live (Hop/route math from
`logistics.zig`: multi-hop via intermediary HQs, tons/week throughput);
founding HQs — beachhead → field HQ → regional upgrade via 9C projects;
second regional HQ playable end-to-end; `transfer_unit`/`transfer_person`
between forces (instant when co-located at home, shipment with ETA
otherwise); dropship/jumpship ownership vs. charter.

## Stage 9E — Contract objectives, lifecycle control & breach ✅
Victory model: duration objectives (garrison-class) vs. enemy-attrition
objectives (combat-class) with `enemy_pool_bv` rolled at acceptance and
depleted across battles; **victory points** from score + pool destruction;
attrition contracts complete early when the pool breaks. Commands:
`complete` (close out when objectives met), `recall` (early return →
breach), redeploy (`accept` from the field, transit from current system).
**Combat-ineffectiveness**: fieldable BV under 50% of committed force opens
a grace window to buy local replacements with company local funds; expired
unfilled → contract failed with the **full breach clause**: pro-rated
advance clawback, forfeit remaining payments, reputation −2, and employer-
faction cooling (~12 months of worse offers from them).

## Stage 10 — MekLab & refits (rules-aware) ✅
Built: `domain/meklab.zig` (engine table, fixed mass, per-location crits with
implicit jump jets/heat sinks, validator naming the rule, CamOps class
A–D, tech hours), chassis/parts construction facts in the data files (every
canonical design validates legal), refit plans as staged edits →
`refit_commit` (legal fit, class ≤ bay ceiling, parts on the shelf, hull at
home) → bay job → mounts change and removed parts return to stock;
persisted; REPL `lab`/`refit`. Original spec:
The MekLab knows BattleTech construction rules per hull (TechManual):
- **Chassis data grows** (`data/chassis.zon`): engine rating & weight, gyro,
  cockpit, internal structure weight, heat sinks (min 10, engine-integral
  count), jump jets, armor tonnage; and **per-location crit slots** (head 6,
  center torso 12, side torsos 12, arms 12 less actuators, legs 6 less
  actuators) with fixed occupants. **Free tonnage** and **free crits per
  location** derive from that — the "how much it can hold and where".
- **Parts data grows** (`data/parts.zon`): every mountable item gets
  tonnage, crit slots, mount type (energy / ballistic / missile /
  equipment), heat, and a location rule (jump jets torso/legs, ammo
  anywhere, CASE side torso, etc.). Engines, heat sinks, jump jets, gyros,
  cockpits, actuators become parts you can buy, salvage, and install.
- **Validation**: a target loadout is legal iff total weight ≤ tonnage,
  each location's crits ≤ capacity, heat sinks ≥ 10, ammo present for
  every ammo weapon, and location rules hold. Illegal fits are refused
  with the violated rule named. Multi-crit weapons may split across
  adjacent locations only where the rules allow.
- **Refits**: loadout diff → parts to remove/install, tech hours, and the
  CamOps refit class (A–F) from what moved; facility ceiling
  (`refitClassCeiling`) gates it; the job occupies a 9C bay; custom
  variants are saved to the campaign (`custom_chassis`) and appear as
  buildable/orderable designs thereafter. Damaged hulls bought off the
  market (9C.3) are completed through the same screen: what's missing,
  what's on hand, what to fabricate or buy.

## Stage 11 — SQLite persistence ✅
`src/persist/`: hand-bound SQLite (system library, no translate-c), and a
**save store** holding many campaigns in one file — every table keyed by
campaign id, a `campaign` registry (name, commander, date, save sequence),
`save`/`load`/`delete`/`list`. Full GameState mapping (people & skills,
units & slots, forces & orderings, stocks at every site, HQs/facilities/
projects, contracts & offers, ledger, loans, couriers, policies, bay jobs,
candidates, links, transfers, faction cooling, listings, orders, the
structured log, pending decisions rebuilt from their decks, RNG streams).
Golden test: save → load → identical hash, and both worlds evolve
identically afterwards. REPL: `save`, `campaigns`, `load <id>`,
`delete <id>`, `new`; `--store <path>` (default `campaigns.db`).
(Deferred: schema migrations — `schema_version` is recorded per campaign.)

## Stage 12 — TUI frontend (in progress)
`docs/tui.md` (architecture) and `docs/tui-mockup.html` (200×50 mockups,
generated by `docs/tui_mockup_gen.py`) came first. Built so far
(`zig build run -- --tui`):
- ✅ 12.1 `sim/queries.zig` — display-ready views shared by CLI and TUI.
- ✅ 12.2 terminal layer (`tui/term.zig`: raw mode, alt screen, keys,
  resize) + cell buffer and panes (`tui/screen.zig`), semantic styles.
- ✅ 12.3 lobby: players table (schema v2), Welcome, four-step wizard
  (commander → outfit & preset emblem → generated company → review),
  typed-name delete, quit-to-welcome with save/discard.
- ✅ 12.4 Desk (checklist/inbox/companies/log/HQs), Contracts (board with
  accept, active with complete/recall, contract log), Ledger (treasuries,
  P&L two periods, transactions), end-turn modal, decision modal, `:`
  command line running the CLI verbs.
- ✅ 12.5 (first cut) Forces (TO&E tree, hull detail, unassigned pool),
  Supply (sites), HQ (facilities, projects, back office, bays, hall).
- ✅ 12.6 Map screen (star map from `data/planets.zon`, influence rings and
  beachhead bands, offers and companies pinned, world/reach panes, found
  HQ here) and Lab screen (budget, crits, mounts with remove/install/clear/
  commit, rules verdict); hiring hall pane with a role filter (`f`/`F`,
  CLI `hall [filter]`).
- ✅ 12.7 emblem: PNG decoder (`tui/png.zig`), picture import in the
  wizard from `.`, `logos/`, `docs/logos/` (stored with the campaign as
  the force's emblem blob), half-block truecolour/256-colour rendering,
  kitty graphics protocol probe + transmit-once/place-per-frame (Ghostty,
  kitty, WezTerm, Konsole); Desk pane, review, wizard preview and the
  tab-bar corner mark. ⬜ iTerm2 inline images, cell editor, back-office
  sizing in the wizard.
- ✅ 12.8 Personnel screen (F9): everyone on the payroll with status,
  assignment and location, role-group filter, full record (skills with
  XP costs, training, leave, pay), open-seat picker, train / post /
  transfer / leave / fire; in-game emblem change (`e` on the Desk or
  `:emblem`: presets or a PNG from the logo dirs, applied to every
  company and saved with the campaign).
- ✅ 12.9 command-line Tab completion (verbs, then sites, facilities,
  roles, skills, parts, worlds); size tiers with 80×24 degradation
  (side panes drop below 120 columns; hull and record open as modals;
  compact status strip); `--ascii` glyph fallback; wizard back-office
  sizing (hire/release admins per desk with payroll and treasury shown).
- ✅ 12.10 Money and medbay in the player's hands: wounded only heal once
  admitted (`admit`; a blocking checklist item); loans at 12%/yr simple
  interest with a credit line (half of liquidation value + a floor) and
  early repayment (`repay`); liquidation — `sell` hulls (half value ×
  condition), `sellhq` (40% of build cost), `disband` a company; a
  negative outfit treasury holds the turn (Error.Insolvent) and going past
  every loan and sale is bankruptcy = game over (persisted). F10 Market
  screen: site boards (buy hulls/parts/ammo), order catalog, fabrication
  of `comp_*` parts, and a demand pane that orders the shortfall from
  damaged slots. Personnel header row pinned. Store schema v3.
- ✅ 12.11 Tuning and texture from play: maintenance accidents cut to
  ≈0.5% per hull-week (snake-eyes and a second roll); pilot wounds on hard
  hits (8+ then 2d6 ≥ 8, 11+ always, MASH softens both); a weekly event
  deck per active contract (night raid, smuggler, inspection, festival,
  exercise, press, ambush warning, weather, cache, prisoner exchange,
  field promotion) on top of the monthly one; lance roles (`set_role`,
  Forces `o`): defense +10% on garrison work, scouting = recon, training
  held out of battle and drilling for XP at home; salvage capacity from
  SVT-1 trucks shown on the contract screen; `depot` command.
- ✅ 12.12 The game has a name — **IRON LEDGER** — and a title screen
  (`tui/splash.zig`: block-letter name, tagline, an ASCII BattleMech; five
  seconds or any key; `--no-splash`). Soundtrack (`tui/music.zig`): the
  tracks in `data/music/` play in a loop through the system player
  (`afplay` on macOS; `mpv`/`ffplay`/`aplay` elsewhere) as a child process;
  `M` toggles, `s` on the welcome screen opens Settings (music on/off,
  volume, next track; persisted in the store's `setting` table);
  `--no-music`.
- ✅ 12.13 Less busywork (play feedback, 2026-09-04): **keep-stocked
  lines** per HQ and part (`set_stock_policy` / `:stockpolicy hq:N part
  min [target]`, `K` on a Supply HQ row or a Market catalogue row) —
  checked daily, under min → order (components: fabricate when the HQ has
  a bay) up to target, one order in flight, a failed sourcing roll waits a
  week; listed under the HQ's stock and in the Ledger. **Auto-admit**
  (`set_auto_admit`, Settings `a`, `:autoadmit on|off`): the medbay admits
  casualties each morning and the untreated-wounded warning no longer
  blocks the turn. **Damage at a glance**: TO&E rows carry `struct
  lt,ra` (depot work, red) and `gear N` (field work, amber); the cursor on
  a company or lance shows a DAMAGE pane — every damaged hull, which
  component each location needs, and a need / at home / coming / short
  table for the home warehouse, with `b` fabricating the shortest line so
  the depot can start the day the company lands. Ammo expenditure halved
  (`battle.mounts_per_ammo_ton` 3 → 6; resupply sizing follows).
  **Selling stock** (`sell_stock` / `:sellstock hq:N part qty`, `$` on a
  Supply HQ row): resale at `market.stock_resale_bp` (components
  `component_resale_bp`) into the HQ treasury, refused under a
  keep-stocked minimum; warehouse stock now counts in liquidation value.
  **Contract history** (`queries.contractHistory`): a HISTORY pane on
  F4 lists every completed, breached or failed contract with employer,
  world, outcome, days served, VP and pay received; the contract log
  follows the cursor there too. The Map marks worked worlds (`=`) and the
  world detail says an HQ can be founded there.
  **Clearing policies**: `set_policy` with a zero floor or cap removes
  the line (Ledger `x` clears the selected treasury's cash policy, or a
  company's resupply policy); keep-stocked lines moved off the Ledger to
  a KEEP STOCKED pane on the Market (Enter edits, `x` removes).
  **Map zoom**: `+`/`-` step the star map ×1 (fit all) → ×2 → ×4 → ×8,
  centred on the cursor world so panning is moving the cursor; the legend
  counts worlds off screen.
  **Field plan** (`sim/field_supply.zig`, play feedback: "companies
  always out of supplies or ammo"): one plan per deployed company sizes
  every line — provisions from headcount × (transit + safety days, +14
  to top up), medical, armor from hull count, each munition family from
  its mounts × battles fought during the transit — with truck shares
  (ammo 40%, armor 10%, medical 5%, provisions the rest) so ammo cannot
  crowd the food out. The load-out at acceptance and the resupply policy
  both follow it; a line ships when on hand + inbound < floor, at most
  once a week per line; `supplypolicy co:N days [max_tons] [battles]`
  (0 days removes). The Supply stock table shows the plan; a 150-day
  regression on a 24-day line stays fed and armed.
  `trim_stock` / Supply `R` / `:trim co:N` returns anything over a
  line's target — and consumables the plan has no line for — to the home
  HQ on the empty convoys (free, map transit); weapon/equipment spares stay.
  **Raising a company by hand** (play feedback: "it should not just
  autogen a full company out of thin air"): `raise_company` makes an
  empty skeleton at an HQ with a free slot (the HQ's lance cap in line
  lances, an empty Omega Company); the Forces `+` wizard fills it —
  `queries.raiseCandidates` merges the unassigned pool, mothballed hulls
  and mek listings from every board (condition, ≈repair bill, delivery
  days; pass hides a listing), `buy_hull_for` buys into a lance (on hand
  at the home board, otherwise a unit transfer over the map transit),
  the support train buys staple trucks/rigs/ambulances/platoons (SEC-PLT
  joined the staple lines), and `queries.manning` lists have/need/open
  per role at the starter generator's ratios with `crew_company` hiring
  from the halls on request. Short boards leave lances open. The starter
  company at campaign creation still uses `company_gen`.
  **Support train in reserve**: event wear (`damage_random_units`) lands
  only on line-lance hulls; a new `damage_convoy_units` effect hits the
  support vehicles, used when a warned convoy ambush is ignored.
- ✅ 12.15 Air companies and transports (doc-vs-code audit, 2026-09-04:
  the capacity math existed, nothing used it). Five TRO:3025 aerofighters
  and six DropShips/JumpShips in `data/chassis.zon` (bays, collars, cargo);
  `raise_air_company` (Forces `w`, `:wing co:N`) stands up an Air Wing in
  the home HQ's air slot (spaceport ≥ 3), `new_lance` takes a kind
  (`:newlance co:N [air|mash|mess|salvage|security|transport] <name>`):
  air lances under the wing (max 3), support lances gated by
  `Hq.supportLanceAllowed` and the new `support_lances` cap (four staples,
  +1 mess hall ≥ 2, +1 hospital or warehouse ≥ 3). Hull kinds are enforced
  (fighters in air lances, meks in line lances, ships in berths). Ships
  are bought off the transport slot on spaceport ≥ 2 boards (fighter /
  dropship ≥ 3 / jumpship ≥ 4 + comms 3, at `market.transport_price_bp`)
  into a berth (`Unit.berth_hq`, `dropship_berths`/`jumpship_berths`
  enforced); crewed by a `dropship_crew`/`jumpship_crew` from the halls.
  A crewed berthed dropship lifts the company at acceptance
  (`commands.planLift`): the carried share pays half the charter (collar
  only), none with an owned jumpship (`logistics.transitFreightBp`); the
  ships sail with the company and return to their berths with it. Level-3
  supply links require a crewed jumpship at one end, cost no monthly
  upkeep and cut hop freight. Battle air cover needs a ready, piloted
  fighter. HQ screen shows berths and air/support capacity. Store v6.
- ✅ 12.16 Per-location injuries and the readiness screen (the Stage 8
  deferral). `person.Injury` is real: `medical.inflict` rolls a location
  (2d6, MekHQ `InjuryUtil` collapsed: head and internal on the extremes,
  limbs in the middle; bay accidents never hit the head) and a severity —
  battle hits 8–9 light, 10–11 serious, 12 crippling; tech accidents from
  the job size — and a crippling head/internal wound is permanent on 2d6 ≤
  4. Triage gives every open injury its own closing day (serious ×1.5,
  crippling ×2); the person returns when the last closes; permanent
  injuries stay on the record and cost a skill point in the cockpit
  (`permanentPenalty`, applied in battle). Wounds without a record (older
  saves, event effects) get one at triage. **Readiness** is a query
  (`queries.readiness`/`readinessLines`: heads, fatigue, morale, wounded,
  permanent, training, banked XP, hulls, depot, quality, rotation): CLI
  `readiness`, Forces `r` swaps the DAMAGE pane for READINESS on a company
  row, `:readiness` opens every company as a modal; the person record
  lists injuries. Store v7 (`injury` table).
- ✅ 12.17 Data debt paid. `data/tables/` is real: **`tuning.zon`** (typed
  against `domain/tuning.zig` `Tuning` at comptime — a misspelled knob is a
  build error) holds every balance number the sim reads: HQ influence,
  paperwork, upgrade costs, warehouse tons, upkeep, founding funds;
  logistics jump/recharge/burn days, hop multipliers, throughput, local
  purchase valve, collar charter, freight per LY; network capacity, upkeep,
  link cost; market band, slots, fabrication, resale, transport pricing,
  staple pricing, beachhead/cooling pay, margin, hall roll, procurement
  markup, rarity targets; medical training/heal/beds/permanent target;
  person hours, XP cost base, fatigue; hull carry costs, cold storage,
  reactivation, sale, truck tons; battle cadence, ammo per ton (one source
  now — the `field_supply` duplicate is gone), silence penalty, defense
  bonus, salvage haul; field-supply shares; loan rate, credit line,
  hardship, field markup; bay slots, depot and build days, tier upgrade,
  refit labor; grace/cooling/decision windows; starter stock; commander
  edge. Formulas stayed where they were; a golden-hash test (seed 5, 60
  days) proved the move behaviour-neutral and was then dropped.
  **`meklab.zon`**: the full TechManual Master Engine Table (rating 10–400
  by 5, no more interpolation) and Internal Structure Table (20–100 t);
  the lab now refuses armor over twice the structure (`maxArmorPoints`).
  **`names.zon`**: the name tables left `person_gen.zig`. **Schema
  migrations**: `store.zig` carries a `migrations` list (v2…v6, column-
  guarded), stamps the store's `schema_version` setting, refuses a store
  or save newer than the game, and `upgradeCampaign` fixes data on load
  (v7: wounded people without an injury record get one). A v5 fixture test
  opens, migrates, loads and backfills.
- ✅ 12.18 CLI parity. One parser for both frontends: `src/sim/cli.zig`
  (`parseCommand`, `verbs`, `usage`, `errorText`, `parseSite`), moved out
  of the TUI and taught the REPL's forms (`start`, `hire <role> <first>
  <last>`, `accept <offer#> <N|co:N>`, `loan <amount> [months]`,
  `fabricate [hq:N] <comp> [qty]` defaulting to the outfit's seat, `leave
  <person> [days]`). The REPL's thirty inline command branches became one
  tail through the parser plus `printResult`; it gained every stage
  12.10–12.13 verb (`raise`, `crew`, `sell`, `sellhq`, `disband`, `repay`,
  `admit`, `trim`, `supplypolicy`, `stockpolicy`, `sellstock`,
  `autoadmit`, `role`, `move`, `depot`, `newlance` kinds, `wing`) and
  `manning co:N`; `help` prints every verb with its usage; inbox options
  are numbered from 1 like the TUI. A table test asserts every listed verb
  has a parser branch. `docs/repl_smoke.sh` scripts the REPL end to end;
  the TUI smoke exercises the shared verbs too.
- ✅ 12.19 Play-tuning pass, first cut. A hands-off scripted year through
  the REPL (a 12-mek company on a 9-month beachhead security contract, no
  player input) exposed defaults, not formulas: the company starved for
  310 days with no resupply policy and no local funds, morale fell to 5,
  and the HQ treasury went negative on depot repairs with nothing topping
  it up. Defaults now set at acceptance unless the player already did
  (`deploymentDefaults`): a resupply policy on the field plan
  (`default_min_days`), 10% of the advance handed over as local operating
  funds (`field_float_bp`), and a standing top-up (`field_policy_floor`/
  `cap`); at campaign creation the starter HQ gets a top-up policy and a
  keep-stocked provisions line. All clearable with a zero. The same year
  now runs hungry 11 days in total, morale 36–50, contract months net
  +120k to +620k, and the HQ holds its float. A quiet six-month garrison
  had 8 of 32 hulls waiting on the depot: maintenance snake-eyes picked
  any slot and half a mek's slots are structure — neglect now breaks gear
  only (structure is battle damage), and that garrison ends at 0 depot. A
  raid closed at −8 VP still "raised" reputation: a tour in the red now
  earns none (−25 VP costs one).
- ✅ 12.20 Hangar and turnover. **The hangar as a portfolio** (GAMEPLAY
  "ranks meks by what they cost against what they contribute"):
  `queries.hangar` scores every hull by monthly bill per point of
  contribution (chassis BV × condition, zero without a fit pilot or in cold
  storage, transports and the support train count as one) and lists the
  worst value first with the reason (no pilot, depot, wreck, cold storage);
  CLI `units`, Forces view `[ ]` "hangar: cost vs contribution".
  **Turnover** (AtB retirement/defection, abstracted): on payday everyone
  with a year on the books who is restless — morale under 30 or fatigue
  over 70 — rolls 2d6 against a target that climbs per complaint; a miss
  is notice handed in (five years' service retires instead), seats are
  vacated and the checklist shows the hole. The checklist warns who is
  restless beforehand. Knobs in `tuning.person`.
- ✅ 12.21 Faction standing. `GameState.faction_standing` (−100…100 per
  house, persisted in `faction_standing`, store v8): a completed tour
  earns the employer +5 (+VP/10, +2 on a beachhead) and costs the house
  you fought −3; a breach costs the employer −20 on top of cooling; it
  drifts one point toward neutral each payday. Effects: offer pay ×(1 ±
  25 bp per point), and a house at −40 or below shuns you (half its
  offers, like cooling). Shown under HISTORY on the Contracts screen and
  by CLI `contracts`, logged as `[standing]` lines. Knobs in
  `tuning.contract`.
- ✅ 12.22 Events on the standing hook. Two new `Effect`s —
  `employer_standing` and `field_stock` (munitions landed in the trucks,
  capped by their room) — and two decisions: **black-market contact**
  (combat weekly deck): buy a load of LRM/SRM reloads off the books for
  local funds at −2 employer standing and −1 reputation, tip off the
  provost for +3, or decline; **salvage dispute** (combat monthly deck):
  hand the disputed hulls over (−100k, +3), split (−50k, +1), or stand on
  the contract (−4, score −1). Decision tags show the standing swing.
- ✅ 12.23 Detailed AARs and physical salvage (play feedback, 2026-09-04).
  Every engagement logs one line per hit — hull, armor before→after, the
  slot damaged or destroyed, DESTROYED, and the crew result with the wound
  (`Dana Petrov wounded (serious torso)`, KIA) — plus expenditure per
  munition family *and what is left in the trucks*, and an itemized
  salvage line. **Salvage is things, not money**: your share of the BV
  hauled off a held field (`salvage_bv_per_truck`, salvage-lance bonus)
  becomes wrecks first — an enemy hull off the RAT that fits the claim,
  created shot-up with guns destroyed and a limb or torso missing, shipped
  to the home HQ pool with the map transit (`unit_transfers` to `.none`)
  to strip, rebuild through the depot, or sell — then structural
  components, weapons and armor tons crated home. No salvage cash is
  posted any more. `log contract:<id>` (CLI) and the HISTORY pane's log
  follow give every past contract's AARs.
- ✅ 12.24 Meaningful events (play feedback: "too many festivals and
  meaningless events"). Same number of events, different split. **The
  inbox rule**: an event is a dice roll logged with its 2d6 and its
  result ("(2d6 = 11) A quiet week spent on live-fire drills — XP +1 all,
  fatigue +3") unless it meaningfully moves money or breaks hulls — cash,
  supply losses, salvage and stock windfalls, damage — and those are
  decisions: pirate and night raids (sortie/stand-to vs. trust the
  pickets), convoy losses and interdiction (buy, pay smugglers, or
  ration), caches and battlefield salvage (crate home vs. strip now),
  bonus payments (bank vs. share). Festivals, inspections, press, drills,
  intel and promotions resolve on their own. A test enforces the rule over
  every deck; `weekly_event_chance_bp` stays a knob. Damaged hulls in cold
  storage or the unassigned pool no longer count as depot backlog at turn
  end. Turnover waits for the tour to end (nobody resigns mid-contract).
  Bug fix: money couriered back to the outfit counts toward solvency, so
  the turn can end while it is on the road.
- ✅ 12.25 Notice, not disappearance (play feedback: "I didn't even know
  employees could quit"). A failed turnover roll now queues an inbox
  decision naming the person (role, experience, pay, morale, fatigue):
  a permanent raise (+25%), a retention bonus (three months' pay, once),
  let them go and hire a replacement in the same role from the hall if
  one is listed, or let them go (the cautious default). `Event.person`
  and four personnel effects; store v9 (`pending_event.person`). The
  checklist still warns who is restless before payday.
- ✅ 12.26 Seats on pool hulls (play feedback). The seat picker (People
  `a`) lists unassigned hulls; `assign <unit> <person>` needs no slot
  word — the person's role picks the pilot seat or the tech slot
  (`Slot.any`; `unassign <unit>` clears both); Forces `a` says so. A pool
  hull sits at the outfit's seat, so only a person whose company is home
  there (or who has no company) can take its seat (`PersonAway`).
- ✅ 12.27 Where the refit went (play feedback). The Lab's plan pane
  says what a committed plan became: in the bay at which HQ with days
  left, or queued with how many jobs ahead and how many slots, pointing
  at the HQ screen's bays list; a committed plan with no bay job is
  flagged as an orphan and `c` clears it, returning its parts to the
  warehouse. The Lab's commit message no longer masks a refusal.
- ✅ 12.28 Orders that fail say so (play feedback: "they never arrive"). A
  failed acquisition roll used to be recorded with no destination and the
  screen still said "ordered". Now `Result.sourced` reports it, the
  Market demand pane says "logistics could not source X — retry after the
  refresh", the failed record keeps its destination, is logged with the
  roll against the rarity target, and clears after two weeks. The demand
  pane fabricates structural components straight away when the HQ has a
  bay (the ARCH §9.8 guarantee) instead of rolling for them.
- ✅ 12.29 The contract verdict, spelled out (play feedback: "+20 VP, did
  I succeed or fail?"). `Contract.grade`: outstanding ≥ 50 VP (+3 rep),
  strong ≥ 25 (+2), satisfactory ≥ 0 (+1), poor < 0 (0). Failure is
  separate and was always the score: −5 or worse at end of term is a
  breach on performance (`Contract.fail_score`). The active contract pane
  shows the verdict so far and the breach line, the completion log names
  the grade and the reputation delta, and the HISTORY pane has a verdict
  column.
- ✅ 12.30 Garrison duty is nearly home (play feedback: two-year garrisons
  left everyone exhausted and ready to quit). On garrison-class contracts
  fatigue now recovers weekly in the field at 60% of the home rate
  (`garrison_rest_bp`; a crewed mess lance stands in for the mess hall)
  and morale drifts back toward content while people are rested; the
  tour's banked fatigue counts months ÷ 3 (`garrison_tour_months_divisor`).
  Combat-class tours are unchanged: no rest in a laager.
- ✅ 12B.10 The hall never runs dry (play feedback). Every HQ with a
  hiring hall keeps a floor of candidates per role — combat crews and
  techs two deep, everyone else one — topped up on the daily churn
  (`hall_floor`, `hall_floor_combat`), so a resignation can always be
  replaced the same week.
- ✅ 12B.11 Medics matter, and the manning table is a pane (play
  feedback). Each medic carries five patients toward the doctor ratio
  (`patients_per_medic`) and adds a field bed — one per medic staffing a
  MASH truck up to doubling it, one per two medics as an aid station
  without trucks. Forces `r` now cycles DAMAGE → READINESS → MANNING; the
  manning table lists every role's have/need/open per company, and the
  end-turn checklist warns when astechs, doctors, medics or the office
  run short (pilots and techs were already covered by the open-seat line).
- ✅ 12B.12 People `/` filter gains **unassigned** (play feedback): nobody's
  pilot or tech, no HQ posting, no company — exactly the rows whose
  assignment column reads "unassigned". Sits between `other` and
  `wounded` in the cycle.
- ✅ 12B.13 Crewing to complement (play feedback: "I can't take 100 turns
  to fill the roles"). `crew co:N` / Forces `c` / the wizard's `a` now fill
  the whole manning table: astechs and medics are hired to complement on
  the spot with no market and no signing bonus (MekHQ treats both as
  pools), every other short role is taken from the halls while candidates
  last, and the result says how many lines are still open. The halls draw
  one walk-in per hall level a day (a boxcars day adds one), half of them
  in whatever trade the companies supplied there are shortest of, and the
  combat/tech floor is three deep.
- ✅ 12B.14 Turnover odds eased (play feedback): 2d6 kept, target 5 → 3,
  so one restless flag fires on a 3 or less (8.3% a month) and both on a
  4 or less (16.7%) instead of 28% and 42%.
- ⬜ 12.14 iTerm2 inline images; emblem cell editor.
(CLI remains as the scripting/debug interface.)

## Stage 12B — Rulebook depth (planned 2026-09-05)

Closing the gaps against MekHQ, AtB and Campaign Operations that a
playthrough exposed. Order: the contract terms first (they change the
Contracts screen every game), then personnel, then data breadth, then the
map. Each item ends green with a ROADMAP tick, as before.

- ✅ 12B.1 **Command rights that matter** (AtB/CamOps). `Terms.command_rights`
  already rolls independent / liaison / house / integrated; wire it in:
  battle cadence (integrated and house employers pick more fights:
  `gap_base_days` −2/−1; independent picks fewer, +2), salvage share (the
  employer's liaison claims a cut: integrated ×0.5, house ×0.75, liaison
  ×0.9, independent full), lance-role freedom (integrated forbids the
  `training` role and overrides a `scouting` lance into `fighting` on
  combat work), score weight (integrated employers grade harder: defeats
  −2), and pay (integrated +10%, independent −5%, priced at offer time).
  Offer and active rows show the rights and their effects; the AAR names
  the liaison's salvage cut. Knobs in `tuning.contract.rights`.
- ✅ 12B.2 **Salvage exchange** (CamOps). When `salvage_exchange` is set the
  employer keeps every wreck and part and pays the claim in cash at
  `salvage_exchange_bp` (60%) of catalogue value — posted to the company's
  local funds with an AAR line. Offers say "salvage exchange" and the
  history verdict notes cash-for-salvage tours. Rolled on ~1 in 6 offers.
- ✅ 12B.3 **Contract negotiation** (CamOps negotiation). `negotiate
  <offer#> <term>` — one round per offer, 2d6 + reputation/10 + the best
  posted admin_command's skill against a target by employer standing
  (favoured houses bargain easier): success improves the chosen term one
  step (advance 25→50%, salvage +10, transport +20, support +25, or
  command rights one step toward independent); failure hardens the offer
  (pay −5%) or, on a 2, withdraws it. Contracts screen `b` (bargain) opens a term
  picker; the offer row shows "negotiated" and what changed. Persisted
  (`negotiated` flag on the offer, store bump).
- ✅ 12B.4 **Ranks** (MekHQ `personnel/ranks`; CamOps mercenary table).
  `data/tables/ranks.zon`: a mercenary rank ladder (Recruit → Private →
  Corporal → Sergeant → Lieutenant → Captain → Major → Colonel) with pay
  multipliers (CamOps officer pay) and slots: the commander is Colonel,
  company commanders Captain, lance leaders Lieutenant, everyone else by
  experience (green Private, regular Corporal, veteran Sergeant, elite
  Master Sergeant). `Person.rank`, `promote <person> <rank>` (and an
  automatic promotion when a seat opens), rank shown on rosters, AARs and
  the record. Store bump (`person.rank`).
- ✅ 12B.5 **Kill records and awards** (MekHQ kills + awards). Each
  engagement credits the enemy BV destroyed to engaged pilots weighted by
  their hull's BV and skill; a pilot's record keeps kills (BV and count),
  battles, and a per-contract line. Awards from `data/tables/awards.zon`
  earned automatically at thresholds (first kill, 10 kills, 25 battles,
  wounded in action, a tour with an outstanding verdict, long service)
  with a small morale bump and a log line; shown on the record and the
  roster. Store bump (`kill`/`award` tables).
- ✅ 12B.6 **Special pilot abilities and Edge** (AtB SPAs, abridged).
  `data/tables/abilities.zon`: eight SPAs a pilot can buy with XP at a
  training ground (Gunnery/Piloting specialist, Dodge, Tactical Genius,
  Toughness, Iron Man, Cool Under Fire, Lucky Edge). Each is one modifier
  the autoresolve already understands (gunnery/piloting points, wound
  survival, morale resistance, one re-roll per contract for Edge). `train
  <person> ability <key>`; shown on the record. Store bump.
- ✅ 12B.7 **Prisoners as people** (MekHQ prisoners). A held field with a
  security lance captures enemy crew as `Person` rows with `status = .pow`
  (generated from the enemy faction, experience by enemy quality), held at
  the company and moved home with it. They eat provisions, and the inbox
  offers ransom (by experience), release (standing with their house +2),
  or recruitment after a loyalty roll (a mekwarrior for your seats,
  morale −2 for the company). The flat 50k ransom goes away. Store: POW
  rows are people; a `captor` field.
- ✅ 12B.8 **Catalogue breadth** (TRO:3025 and 3026, re-encoded by hand,
  approximate BV/cost flagged // TUNE). Meks: the rest of the 3025 set —
  Wasp, Stinger, Valkyrie, Urbanmech, Spider, Firestarter, Javelin,
  Hermes II, Cicada, Whitworth, Vindicator, Clint, Hunchback, Blackjack,
  Centurion, Enforcer, Trebuchet, Dervish, Wolverine variants, Crab,
  Ostroc, Ostsol, Dragon, Quickdraw, JagerMech, Grasshopper, Orion,
  Crusader, Black Knight, Guillotine, Flashman, Zeus, Stalker, Cyclops,
  Banshee, Victor, Charger, Goliath, Longbow, plus common variants
  (~45 designs). Vehicles (TRO:3026, Lab-less): Scorpion, Vedette, Hetzer,
  Manticore, Demolisher, Schrek, LRM/SRM carriers, Ontos, Pegasus, Saracen
  — as line-lance vehicles with `vehicle` kind crewed by vehicle_crew /
  tech_mechanic, and a vehicle lance kind. Fighters: Thrush, Seydlitz,
  Lightning, Eagle, Riever, Chippewa. RAT weights per house and weight
  class in `data/tables/rat.zon` (AtB) so Lyran companies field Zeuses and
  Combine ones Dragons.
- ✅ 12B.9 **The full star map and factions** (234 systems in this cut) (MegaMek `planets.xml` is
  GPL data; we re-encode). `data/planets.zon` grows to the 3025 Inner
  Sphere at roughly 400 named systems: every house capital, regional
  capitals, the mercenary hubs, the border worlds that appear in the
  sourcebooks, and the near Periphery (Taurian Concordat, Magistracy of
  Canopus, Outworlds Alliance, Circinus, Marian Hegemony, Oberon) as
  factions with their own keys, colours and enemy tables; coordinates in
  SUCS-style LY from Terra, approximate and flagged. `data/tables/
  factions.zon`: name, colour, capital, foes, pay multiplier, hiring-hall
  presence. Map screen: `c` cycles colouring — by faction (house colours,
  border worlds outlined), by industry, by your standing (green to red),
  by contract activity; a legend pane; the world detail names the faction,
  the capital distance and the standing. Contract generation uses factions'
  foe tables; company generation's RAT uses the home faction. Star-map
  performance: a spatial grid for the 400-world neighbour queries.

## Stage 12C — Careers, rating & depth (planned 2026-09-05)

Everything left on the table after 12B, ordered so each block builds on
the one before: the personnel economy first (it settles the turnover
question for good), then the rating that drives the contract board, then
the campaign's memory, then combat variety, then the maintenance section
we skipped, then era/data plumbing, then the terminal cosmetics. Every
item: tests green, both smokes, ROADMAP tick, one commit.

### Block A — Personnel economy (CamOps fatigue, AtB shares & retention)

- ✅ 12C.1 **Fatigue penalties** (CamOps Fatigue rules, MekHQ `Fatigue` option).
  Bands on `Person.fatigue`: fresh, tired from 30 (+1 to gunnery and
  piloting in `battle.playerSide`), exhausted from 70 (+2, the turnover
  line), spent from 85 (+3 and unfit: the auto-assigner seats a fresher
  pilot when one is free and the checklist warns about spent pilots still
  seated). READINESS shows tired/spent counts; a person's record names
  the band and its cost. Knobs `fatigue_tired`, `exhausted_fatigue`,
  `fatigue_spent`. The company-average fatigue power modifier in
  autoresolve stays as the logistics-level effect.
- ✅ 12C.2 **Departure payout** (MekHQ retirement bonus / AtB "retirement
  payment"). Leaving owes one month's salary per full year served
  (`severance_months_per_year`, capped at `severance_cap_months` = 12),
  posted to the outfit as payroll "severance" / "retirement payout"; a
  plain `fire` pays `fire_severance_bp` (half) and now vacates the seat;
  disbanding a company pays everyone out. One `personnel.depart` does
  every exit. The notice inbox line and the fire modal both price it.
- ✅ 12C.3 **Shares** (AtB shares system). `Person.shares` refreshed each
  payday: a founder (on the books day 0) holds 2, every combat/tech hand 1
  after a year, +1 per rank above sergeant. `shares <pct>` (Settings shows
  it; default 30%) is the share of a contract's income paid out pro rata
  to every shareholder at completion as payroll "profit shares" (+3
  morale, log line with the split). Three shares cancel a restless flag;
  shareholders take half severance. Record shows the stake. Schema v15.
- ✅ 12C.4 **Ages and career arcs** (MekHQ `birthday`, AtB age-based
  retirement). `Person.born_day` (days relative to campaign start, null
  for bare test hires); the generator rolls an age by trade and
  experience (cockpits 19–48 by band, techs 20–50, desks 25–55, doctors
  30–60, astechs/medics 18–40). From `age_old` (50) the payday turnover
  roll carries an extra restless flag; at `age_retire` (65) they retire
  on the next payday at home with their payout; under `age_young` (25)
  XP awards are ×`xp_young_bp` (1.2, rounded up). Hall rows show age; the
  record names the age and what it means. Schema v16 with a birthday
  backfill for older saves.
- ✅ 12C.5 **Loyalty** (AtB founder/loyalty modifiers). Founders never roll
  turnover while morale ≥ `founder_morale_floor` (20); each modifier in
  play cancels a restless flag: founder, `veteran_tours` (5) served, a
  raise or bonus accepted within `raise_loyalty_days` (a year), an award
  within `award_loyalty_days` (six months). The notice log line and the
  inbox row name the modifiers in play ("despite: founder, veteran"); the
  record has a loyalty line. Schema v17 (`last_raise_day`,
  `last_award_day`).

### Block B — Unit rating & the board (AtB/CamOps Dragoons rating)

- ✅ 12C.6 **Dragoons rating** (CamOps "Mercenary Rating", MekHQ
  `UnitRating`). `queries.rating`: experience (average combat skill,
  0–40), command (desks staffed + officers, 0–20), combat record
  (contract outcomes by grade, breaches and failures, plus the event
  reputation, ±40), transport (own lift share, +10 own jumpship),
  support (tech/astech/medical posts filled, 0–20), finances (debt
  against payroll, overdrawn −20). Letters F/D/C/B/A/A* at
  `tuning.rating` thresholds. Desk checklist title and the Contracts
  notes line carry it; `rating` REPL verb prints the parts.
- ✅ 12C.7 **Rating drives the board**: offers on the board = letter index
  (F 0 … A* 5) + comms, never under one; an F-rated outfit hears only
  from periphery and pirate employers and is never handed a planetary
  assault; pay multiplier by letter (`pay_bp_f` 0.8 … `pay_bp_a_star`
  1.3) replaces the old reputation multiplier; the negotiation edge is
  the letter index − 2 (F −2 … A* +3); an A-rated outfit adds one to
  the hall's recruit roll. A fresh outfit starts C: the combat record
  carries `record_unproven` (−15) until the first contract closes, and
  the letter thresholds are D 0 / C 30 / B 60 / A 90 / A* 120.
- ✅ 12C.8 **Campaign summary** (`:summary` modal, REPL `summary`):
  contracts by grade and outcome with C-bills earned from employers,
  battles won/drawn/lost, kills credited and enemy BV destroyed, hulls
  lost and salvaged, people KIA, money in/out with the five biggest
  expense categories, people on the books/hired/KIA/resigned/retired,
  hulls bought/salvaged/lost, and the Dragoons rating every New Year's
  Day. `GameState.stats` counters (battle outcomes, losses, wrecks, KIA,
  enemy BV) ride in the meta ints; `rating_snapshot` table. Schema v18.

### Block C — Combat variety (AtB scenario types)

- ✅ 12C.9 **Scenario types** (AtB scenario table, `data/tables/scenarios.zon`
  + `domain/scenario.zig`): stand-up fight, hold the line, breakthrough,
  ambush, convoy escort, base defence, recon in force, extraction — a d6
  table per contract kind. Each scales the enemy (`enemy_bp`), tilts the
  engagement roll (`roll_mod`, an ambush −2) with a scouting lance giving
  some back (`scout_bonus`), sets the salvage share of a held field
  (raids strip nothing), weights the contract score (`score_mult` 2 for
  breakthroughs, base defence and extractions) and, for convoy escorts,
  puts the support train in the line of fire on a defeat. The AAR header
  names the scenario and its shift.
- ✅ 12C.10 **Terrain and weather** (`data/tables/terrain.zon` +
  `domain/terrain.zig`): every world has a terrain class (plains, hills,
  forest, urban, badlands, jungle, tundra — named in `planets.zon` for
  the famous worlds, a stable pick from the key for the rest) and every
  battle rolls 2d6 weather (clear, rain, snow, storm, night, dust; tundra
  turns rain to snow, badlands to dust). Close terrain (woods, streets,
  jungle) caps the power-ratio bonus at +2 and dents recon; night, storms
  and dust ground the fighters; storms and dust take −1 off the roll;
  harsh ground and weather each cost a fatigue point. The AAR header
  reads "… — ambush on city streets, night action: …".
- ✅ 12C.11 **Morale from the field**: battle morale stays per outcome
  (+5/+3/−1/−5/−10, a mess lance softens the bad days); a win on a
  weighted scenario (breakthrough, base defence, extraction) adds
  `morale_objective_bonus` (+1); a contract closed outstanding or strong
  lifts the whole outfit by `morale_contract_strong` (+5); a breach —
  including a performance failure at term — costs everyone
  `morale_contract_breached` (−10), halved for Cool Under Fire. Log lines
  under [morale].

### Block D — Maintenance & repair depth (the section left out of 12B)

- ✅ 12C.12 **Repair outcomes** (MekHQ repair roll). Depot repairs and
  refits roll at the end of the bay time: 2d6 + (5 − tech skill) against
  `repair_target_base` (6) + the hull's quality modifier (A worst … F
  best). Margin ≥ `repair_fault_margin` (2) is clean; 0–1 lands with a
  lingering fault (quality one step worse); a miss redoes half the bay
  time (`repair_redo_bp`) and the job stays on the bench; a natural 2
  botches (a piece of gear destroyed on the bench, order another). The
  tech is the hull's own, else the sharpest one at home. The refit
  commit log and the HQ bay queue rows show "tech skill 4 vs target 7 ·
  72% clean / 17% fault / 11% redo" before the work starts.
- ✅ 12C.13 **Quality drift** (MekHQ maintenance quality; A worst … F
  best). The weekly maintenance roll already moved the letter; the
  margins are now knobs (`quality_drop_margin` 2, `quality_rise_margin` 7
  — a skilled, covered tech lifts a hull roughly one week in six, an
  uncovered hull slips most weeks), every move is a [maintenance] log
  line, and quality now prices resale (`quality_sale_bp_per_step`, ±5%
  per step from C) on top of reactivation days, the maintenance target
  and the repair check (12C.12).
- ✅ 12C.14 **Part availability** (MekHQ acquisition target by tech base
  and TechManual availability code): `parts.zon` rows carry
  `availability` (A staple … F almost nowhere; PPCs, large lasers, AC/20s,
  big LRM racks, torso/head assemblies and MASH theatres are D, ship bays
  E) and `tech_base`. Every acquisition roll and every rare market slot
  adds `avail_mod` per letter, a `periphery_penalty` on a periphery world
  for Inner Sphere parts rated D or worse, and `comms_bonus_per_two_levels`
  from the HQ's comms. The failed-order log line and the inbound view's
  "not found" say why ("availability d −1, periphery market −2").
- ✅ Fix (play feedback 2026-09-05): the HQ screen's `T` key was never
  bound, though the footer and the tier line advertised it; a field HQ
  could only be raised with `:tier hq:N`. Bound now, with a plain message
  on an HQ that is already regional. The `tier` command also debited the
  HQ before checking it could start (a refusal kept the money); it now
  checks tier, project and funds first and pays once.
- ✅ 12C.15 **Tech target numbers**: `GameState.hullHours` scales the
  class table by quality (`hours_quality_bp`: an A-grade wreck wants ×1.5,
  an F-grade machine ×0.8) and by an exotic design (`hours_exotic_bp`,
  very rare on the market: Highlanders, King Crabs, Stukas, the big
  ships); `techHoursFor` then sets the pace by the tech's skill
  (`hours_skill_bp`: elite ×0.75 … untrained ×1.3). The weekly pass,
  the tech load, auto-assign and the hull view all read it, and the
  MANNING astech and mek-tech rows now say "N of M tech-hours/week
  covered" for the company (astech teams already scale the budget).

### Block E — Era & data plumbing

- ✅ 12C.16 **Era progression** (MekHQ `introYear`): `chassis.zon` and
  `parts.zon` carry `intro_year` (default 2400; the 3020s house refits —
  SHD-2D, GRF-1S, WHM-6D, MAD-3D, CPLT-K2, OSR-2C — are dated). The
  market pools, the house RATs, the starter generator and battle salvage
  only field what is in service in the campaign year. The new-campaign
  wizard has a start-year field (3015–3030; `start … <name> [year]` in
  the REPL, 3000–3060), and New Year's Day logs "[tech] new in 3020: …"
  for the designs entering service. Nothing is extinct yet.
- ⬜ 12C.17 **Black market** (AtB black market): an occasional listing at
  a hiring-hall world with comms ≥ 2 — rare designs or parts at 2–4×,
  with a 2d6 chance the seller is a fraud (money gone, log line, standing
  hit with the local faction) and a small pirate-standing effect for
  buying; the Market screen marks it.
- ⬜ 12C.18 **Mod support**: `--data <dir>` overlays any `data/*.zon` and
  `data/tables/*.zon` from a directory at startup (ZON parsed at runtime
  for the overlay, comptime tables stay the default); the settings screen
  says which files are overridden; `docs/modding.md`.

### Block F — Terminal cosmetics

- ⬜ 12.14 **iTerm2 inline images and the emblem cell editor** (carried
  from Stage 12): inline-image protocol detection for the splash and
  emblem where the terminal supports it, and a cell editor on the emblem
  screen (cursor, palette, undo, save to the campaign).

### Order & schema

A → B → C → D → E → F. Schema bumps: v15 (12C.4: `born_day`, `shares`),
v16 (12C.8: `rating_snapshot` table), v17 (12C.13: `unit.quality` history
not needed — letter already stored; 12C.14 part fields are data-only),
v18 (12C.16: campaign `start_year`). Every knob lands in
`data/tables/tuning.zon` from the start; rule tables cite the AtB /
CamOps / MekHQ source next to the table.

## Stage 13 — Graphical client
Architected after the TUI ships, reusing the same command/query boundary.

## Later / icebox
Edge points in play, audio beyond the music player, Stage 13 graphics.
(Era progression, black market, mod support and turnover moved into
Stage 12C.)
