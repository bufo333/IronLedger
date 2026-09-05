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
- ⬜ 12.14 iTerm2 inline images; emblem cell editor.
(CLI remains as the scripting/debug interface.)

## Stage 13 — Graphical client
Architected after the TUI ships, reusing the same command/query boundary.

## Later / icebox
SPAs & edge, era progression + tech intro dates, black market, faction
standing beyond breach cooling, retirement/turnover rolls (AtB),
audio, mod support (all data already external in `data/`).
