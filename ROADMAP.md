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
- ⬜ 12.14 iTerm2 inline images; emblem cell editor.
(CLI remains as the scripting/debug interface.)

## Stage 13 — Graphical client
Architected after the TUI ships, reusing the same command/query boundary.

## Later / icebox
SPAs & edge, era progression + tech intro dates, black market, faction
standing beyond breach cooling, retirement/turnover rolls (AtB),
audio, mod support (all data already external in `data/`).
