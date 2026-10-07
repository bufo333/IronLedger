# IRON LEDGER

*A BattleTech mercenary company in the Succession Wars.*

![Title screen](docs/screenshots/splash.svg)

IRON LEDGER is a terminal strategy game about running a mercenary outfit in
the BattleTech universe during the scarcity years of the 3025 Succession Wars.
You are the commander of the whole operation — not a pilot. You chase contracts
across the Inner Sphere, keep the 'Mechs running, the troops paid, and the
supply lines open, then send your companies into battles that resolve on their
own from everything you set up beforehand: training, maintenance, ammunition,
provisions, morale, and the support echelons behind them. You win through
logistics, people, and money; the tabletop is deliberately skipped, and the
campaign around it is the game.

Everything is turn-based. A turn is a day, and nothing happens while you think.

---

## What it is

<img align="left" width="110" src="data/logos/ashfall_lancers.png" alt="">

You command an entire mercenary outfit — from a single company up to a brigade.
Every screen is a ledger, roster, map, or report. Battles produce after-action
reports, not hex maps. The game's design pillars: you are the commander, not
the pilot; logistics wins battles; multi-company concurrent operations on a live
star map; faithful rules where they count; and a deterministic simulation with
the same seed giving the same outcome every time.

<br clear="all">

<img align="right" width="110" src="data/logos/balance_point_mercenaries.png" alt="">

Over a campaign you grow from a small regional operation into a multi-HQ
enterprise. You spend profit to found forward bases on frontier worlds, upgrade
them toward full regional headquarters, link them into your supply network, hire
the back-office staff the paperwork demands, and take on bigger contracts than
you could the year before. Growth is infrastructure-first — a second company at
full service means a second regional HQ, with the payroll and supply line that
implies.

Each deployment plays out as an operational story. You set each operation's
intent, task your lances, decide whether to scout, strike, prepare, or wait,
and live with the local consequences. When battle comes it is hands-off: the
after-action report tells you what your preparation was worth.

<br clear="all">

---

## Getting it running

You need [Zig 0.16](https://ziglang.org/download/) and the system SQLite
library (present on macOS; `libsqlite3-dev` on Debian/Ubuntu). For the
soundtrack, an optional command-line audio player on `PATH` — `afplay`
(macOS), `mpv`, `ffplay`, or `aplay`.

```sh
zig build run -- --tui                            # play
zig build run -- --tui --store path/to/save.db    # play, saving to a chosen file
zig build -Doptimize=ReleaseFast --prefix dist    # build a standalone binary at dist/bin/game
```

One SQLite file holds every player and campaign. Without `--store` the game
keeps it in a per-user data directory. A maximised terminal gives the fullest
layout and everything degrades gracefully to 80×24; pass `--ascii` for
terminals that render box-drawing glyphs double-width. The client measures the
terminal at startup and on resize — there are no fixed tiers, a bigger terminal
simply shows more rows and wider panes.

Design and contributor notes live in `ARCHITECTURE.md`, `GAMEPLAY.md`,
`ROADMAP.md`, and `docs/`.

## Release 1.0.0

Release downloads provide native x64 core ZIPs:

- `iron-ledger-1.0.0-macos-x64.zip`
- `iron-ledger-1.0.0-linux-x64.zip`
- `iron-ledger-1.0.0-windows-x64.zip`

Each archive contains `bin/game` (or `bin/game.exe`),
`share/iron-ledger/logos/`, `LICENSE`, `ASSETS.md`, and
`THIRD-PARTY-NOTICES.md`. Keep that layout intact when unpacking. macOS and
Linux use the host SQLite library; the Windows archive includes `bin/sqlite3.dll`.
Verify a release against its accompanying `SHA256SUMS` asset. Core ZIPs do not
include music. Build a local music-enabled tree only with
`zig build -Doptimize=ReleaseFast -Dbundle-music --prefix dist`; no music archive
is published without separate approval.

---

## The lobby and starting a campaign

<img align="left" width="110" src="data/logos/blackstar_company.png" alt="">

The game opens in a **lobby** outside any campaign. The Welcome screen has two
panes: **Players** and **Campaigns**. Tab switches pane focus; `j`/`k` moves
the cursor; Enter loads the selected campaign; `n` starts a new one; `p`
creates a new player account; `q` quits.

![Welcome screen](docs/screenshots/welcome.svg)

<br clear="all">

<img align="right" width="110" src="data/logos/broken_sky_company.png" alt="">

A new campaign walks through a **four-step wizard**:

**Step 1 — Commander.** Fill in your commander's name, faction of origin,
profession, and campaign start year. Tab cycles through the four fields; the
name field is required before you can advance.

![Commander step](docs/screenshots/wizard-commander.svg)

<br clear="all">

<img align="left" width="110" src="data/logos/cerberus_contracting.png" alt="">

**Step 2 — Outfit & emblem.** Choose your company crest from a 5-column
catalog grid of PNG thumbnails. The catalogs's logos are sorted alphabetically
by filename; selecting one auto-fills the outfit name (title-cased from the
filename stem). You can override the outfit name by typing directly into the
name field. Tab cycles through the outfit name field, company name field, and
grid-navigation mode; h/j/k/l navigate the grid. The chosen logo key is
reserved from rival mercenary companies for the life of the campaign.

![Outfit and emblem step](docs/screenshots/wizard-emblem.svg)

<br clear="all">

<img align="right" width="110" src="data/logos/dawnbreak_mercenaries.png" alt="">

**Step 3 — Company and back office.** Review the generated starting company —
three mek lances and an officer roster — and set the initial back-office
headcount per admin role. `r` rerolls with a new seed; `+`/`-` adjust
headcount.

![Company step](docs/screenshots/wizard-company.svg)

**Step 4 — Review.** Confirm the generated campaign summary and your crest.
Enter saves and opens the Desk on day 0; `1`–`3` jumps back to an earlier
step; Esc discards.

![Review step](docs/screenshots/wizard-review.svg)

<br clear="all">

The Settings screen is available from the lobby via `s` and from the campaign
via `:settings`.

![Settings](docs/screenshots/settings.svg)

---

## The frame and controls

<img align="left" width="110" src="data/logos/dead_reckoning.png" alt="">

Every in-game screen shares the same persistent frame:

```
tab bar:        F1 Desk  F2 Map  F3 Forces  …  <outfit>  ▒▒ emblem (8×3)
status strip:   <date> day N · outfit <funds> · rep · inbox N · checklist N
screen body:    2–4 panes; the focused pane has the bright border
command line:   : prompt (opens on :), hints on the right
```

**Tabs** are screens; `F1`–`F10` or `1`–`0` switch them. **Tab / Shift-Tab**
cycles pane focus except in F8, where it cycles the physical location headers;
each pane owns its own cursor. `j`/`k` and the arrow keys
move the cursor; PgUp/PgDn scroll ten rows; `←`/`→` scroll wide table columns.

<br clear="all">

<img align="right" width="110" src="data/logos/deep_reach_company.png" alt="">

The **`:` command line** and the REPL share one parser (`src/sim/cli.zig`):
simulation verbs (`accept`, `order`, `transfer`, `assign`, `refit`, `found`,
`link`, `raise`, `sellstock`, `roe`, `role`, `rush`, `confirm`, and more)
work in both, with Tab completion over verbs and entity IDs. Frontend-only
verbs (`day`, `save`, `quit`, `help`, `settings`, `emblem`, `manning`,
`readiness`, `summary`, `music`) are handled by the TUI directly. Every word
must be used; anything left over after a complete command is refused, and a
parse error shows the verb's usage line.

Screen keys are shortcuts for commands the command line can also run.
Refusing commands shows as `refused: <sentence>` in the status line with
plain language from `cli.errorText`; no error code reaches the screen.

`?` opens the full key reference; `q` returns to the Welcome screen (save /
discard / stay); `n` ends the turn; `N` advances seven turns.

Pass `--ascii` for terminals that render box-drawing glyphs double-width; the
client substitutes `+ - |` and `# .` throughout.

![Help screen](docs/screenshots/help.svg)

<br clear="all">

---

## The screens

### F1 Desk

<img align="left" width="110" src="data/logos/dust_dogs_mercenaries.png" alt="">

The Desk is the campaign's central hub. Panes: **Emblem** (company crest),
**Checklist** (urgent warnings), **Inbox** (decisions with deadlines),
**Companies** (posture summary), **Log** (campaign history), **HQs** (network
status), and **Reports** (P&L and readiness).

`Enter` on the checklist jumps to the warning's source; `Enter` on the inbox
opens the decision; `b` browses after-action reports; `e` opens the emblem
editor; `n` ends the turn (the end-turn checklist opens first).

![Desk](docs/screenshots/desk.svg)

<br clear="all">

### F2 Map

<img align="right" width="110" src="data/logos/emberguard_mercenary_company.png" alt="">

The star map of the Inner Sphere and near Periphery — 234 systems with faction
ownership, your HQ network, and deployed companies marked. `h`/`j`/`k`/`l` and
the arrows pan; `+`/`-` zoom (system names appear at ×2). `c` cycles the colour
mode: faction, industry, standing, or activity. `f` pre-fills a `found` command
for the world under the cursor; `o` opens the contract board.

![Map — faction colour](docs/screenshots/map.svg)

![Map — industry colour](docs/screenshots/map-industry.svg)

<br clear="all">

### F3 Forces

<img align="left" width="110" src="data/logos/frontier_bound_mercenaries.png" alt="">

The TO&E tree: outfit → companies → lances → hulls, with slot states and hull
condition at a glance. `[`/`]` cycles views (all forces, each company,
unassigned hulls, the hangar). `r` cycles the side pane between readiness,
manning, and damage. `Enter` assigns crew to the hull under the cursor; `a`
seats a specific person; `u` clears a seat; `l` moves a hull into a lance; `x`
sends it to another company.

![Forces — TO&E](docs/screenshots/forces.svg)

![Forces — readiness pane](docs/screenshots/forces-readiness.svg)

![Forces — manning pane](docs/screenshots/forces-manning.svg)

`h` opens the hull lifecycle: full combat history, maintenance log, and
ownership chain.

![Hull lifecycle record](docs/screenshots/record.svg)

`[`/`]` to the hangar view shows every machine ranked by what it costs against
what it contributes.

![Hangar](docs/screenshots/hangar.svg)

<br clear="all">

### F4 Contracts

<img align="right" width="110" src="data/logos/ghostline_mercenaries.png" alt="">

Three panes: **Board** (open offers at the current HQ), **Active** (running
contracts), and **History** (closed contracts with outcome, world, days served,
victory points, pay received). `[`/`]` switches HQ boards. Enter on the board
accepts an offer (you pick the company); `b` negotiates (one round per offer).

![Contracts](docs/screenshots/contracts.svg)

`b` on an offer opens the negotiation screen:

![Negotiate](docs/screenshots/negotiate.svg)

`g` on an active contract opens the arc **operations board** — the contract's
current beat briefing, all instantiated operations, tempo posture, and
intelligence confidence. Enter commits an operation; `r` sets tempo; `i` opens
the intervention picker; `x` declines; `G` opens the read-only operation
report.

<br clear="all">

### F5 Ledger

<img align="left" width="110" src="data/logos/glacial_reach_mercenaries.png" alt="">

Three treasury tiers in one view: the outfit, each HQ, and each deployed
company's operating fund. `L` takes a loan; `R` repays the oldest loan; `t`/`T`
move cash to/from the selected row; `p` sets a cash top-up policy (floor and
monthly cap); `x` clears a standing policy.

![Ledger](docs/screenshots/ledger.svg)

<br clear="all">

### F6 Supply

<img align="right" width="110" src="data/logos/hammerfall_mercenaries.png" alt="">

Physical supply flow: parts, ammunition, medical supplies, and provisions.
Panes show sites with tons/capacity/burn/days, demand lines, and the order
form. `o` orders a part; `s` ships from the home shelf; `R` returns excess
field stock home; `H` sends structural components home; `K` keeps a part
stocked at an HQ. `P` sets automatic resupply policy for a company.

![Supply](docs/screenshots/supply.svg)

<br clear="all">

### F7 HQ

<img align="left" width="110" src="data/logos/iron_vultures.png" alt="">

Each HQ's facilities, upgrade projects, mek bays, back-office staffing, and
supply inventory. `[`/`]` switches between HQs. `u` queues a facility upgrade;
`T` raises a field HQ to regional; `S` staffs the back office to requirement;
`b` fabricates a structural component at the bay; `$` sells the HQ.

![HQ](docs/screenshots/hq.svg)

`h` opens the hiring hall:

![Hiring hall](docs/screenshots/hall.svg)

<br clear="all">

### F8 Lab

<img align="right" width="110" src="data/logos/ironbear_company.png" alt="">

The MekLab. `[`/`]` steps through hulls; the construction grid shows all eight
locations (HD/CT/LT/RT/LA/RA/LL/RL) with fixed occupants, mounted equipment,
and free slots. The selected slot's detail pane shows its full identity and live
condition. Tab / Shift-Tab cycles location headers in physical order (HD, CT,
RT, LT, RA, LA, RL, LL). Enter on a free slot opens the location-scoped part picker;
`+` stages an install; `-` stages a removal; `m` commits the plan as a bay job;
`c` clears the staged plan. The lab validates tonnage, per-location criticals,
heat, and ammunition and quotes the refit class (A–D).

![Lab](docs/screenshots/lab.svg)

<br clear="all">

### F9 People

<img align="left" width="110" src="data/logos/jade_fang_company.png" alt="">

The full personnel roster with role filter. `/`/`,` cycles filters; `r` opens
a person's detail record (file, skills, status, assignment, eligible actions);
`a` assigns to an open seat; `x` transfers to another company; `P` posts to an
HQ; `t` trains the primary skill; `L` sends on leave; `T` sets triage priority;
`m` admits to the medbay; `D` dismisses.

![People](docs/screenshots/people.svg)

<br clear="all">

### F10 Market

<img align="right" width="110" src="data/logos/last_argument_mercenaries.png" alt="">

Boards at the current HQ: hull listings, parts catalogue, and demand lines
for damaged slots. `[`/`]` switches HQs; `/`/`,` cycles market filters. Enter
buys the listing under the cursor; `b` fabricates a structural component; `K`
adds a part to the keep-stocked list; `x` removes a standing order.

![Market](docs/screenshots/market.svg)

<br clear="all">

### Command-line views

<img align="left" width="110" src="data/logos/nightwarden_mercenaries.png" alt="">

Several read-only reports open from the command line or via screen keys:

**`:summary`** — a full campaign summary across all companies and HQs.

![Summary](docs/screenshots/summary.svg)

**`:readiness`** — the readiness report for all companies: operational strength,
fatigue, supply state, and pending maintenance.

![Readiness report](docs/screenshots/readiness.svg)

**`:settings`** or `F12` — global settings (music, difficulty, auto-admit).
`:settings campaign` opens campaign-specific settings.

![Settings — global](docs/screenshots/settings.svg)

![Settings — campaign](docs/screenshots/settings-campaign.svg)

**`:emblem`** — the in-campaign emblem studio: a cell editor for the outfit
crest. Arrows move; Backspace erases; type to paint; `u` undoes; Enter saves.

![Emblem editor](docs/screenshots/emblem-editor.svg)

**End-turn checklist** — opens before every advance while a warning prompts.
`n` ends the turn anyway; `1`–`9` jumps to the warning's source; Esc stays.

![End-turn checklist](docs/screenshots/end-turn.svg)

<br clear="all">

---

## Systems in depth

### Campaign operations and contract arcs

<img align="right" width="110" src="data/logos/northwind_mercenaries.png" alt="">

Arc contracts run as a sequence of **beats** — arrival, complication,
escalation, climax, aftermath — with materially different endings. Each beat
presents an **operations board** with combat and non-combat operations; each
operation carries a tempo posture (`advance`, `recon`, `prepare`, `delay`) and
an escalation clock. Committing an operation sets a mission intent (preserve
force, secure an objective, break the enemy, protect assets, secure
intelligence, recover people or equipment); committed combat operations can
receive command-capacity **interventions** (emergency recon, reinforce, air
cover, field repair) before they resolve.

Named liaisons, enemy officers, and rival mercenary companies persist across
contracts — each carrying its own relationship dimensions. Your officers
accumulate a performance standing over a contract's span. Five world-state
dimensions (security, civilian support, infrastructure strain, employer control,
enemy influence) change through operation outcomes and are visible on the Map
and Contracts screens.

*(Sources: ARCHITECTURE.md §7, §8; docs/tui.md "Operations board")*

<br clear="all">

### Contracts and hands-off battle resolution

<img align="left" width="110" src="data/logos/orbital_scar_mercenaries.png" alt="">

Twelve contract types from the AtB/CamOps rules: Garrison Duty, Cadre Duty,
Security Duty, Riot Duty, Planetary Assault, Relief Duty, Guerrilla Warfare,
Pirate Hunting, Diversionary Raid, Objective Raid, Recon Raid, Extraction
Raid. Each carries its own event deck, terms (command rights, salvage share,
transport percentage, signing bonus, advance), and opposition.

Combat resolution uses one opposed roll per engagement, modified by BV2-derived
hull strength × crew skill × condition × ammo state, plus campaign modifiers:
supply state, fatigue, morale, mess quality, recon, commander tactics, terrain,
attached support and air cover. The after-action report traces every hit,
casualty, ammunition burn, and salvage haul to the inputs behind them. Per-lance
tasking (main effort, screen, reserve, escort, recovery, recon) adjusts the
odds; each tasked lance appears in the AAR.

Post-battle flows directly into existing systems: wounded to medical, damage to
tech queues and parts demand, salvage to inventory and market, XP to skills.

*(Sources: ARCHITECTURE.md §5, §7)*

<br clear="all">

### Company and people

<img align="right" width="110" src="data/logos/praetor_company.png" alt="">

Everyone is an individual: role (MekWarrior, vehicle crew, aerospace pilot, mek
tech, mechanic, aero tech, doctor, and five admin specialties), skills on the
MekHQ four-level scale (Green / Regular / Veteran / Elite), rank, XP, kills and
awards, per-location injuries with healing time and doctor assignment, fatigue,
morale, hire date, and shares in the outfit.

Hull slots are consequences: a mek needs a pilot *and* an assigned mek tech; a
hull with no tech gets no maintenance roll, no repairs, and no reloads. Tech
time is a weekly budget — each hull consumes hours by weight class; a full
astech team multiplies a tech's throughput; a short team halves it. Techs roll
for accidents on large jobs; the wounded go to the medbay. A Dragoons rating
(F to A\*) decides which offers reach your board and what you are paid.

*(Sources: ARCHITECTURE.md §5, §9.9)*

<br clear="all">

### The HQ network, influence rings, and capacity

<img align="left" width="110" src="data/logos/ravenstrike_mercenaries.png" alt="">

HQs come in three tiers — field, regional, and brigade. Each projects an
**influence ring** (radius in light-years) that gates the contract market;
offers in a 30-LY beachhead band beyond the ring appear with a penalty preview,
and anything further is invisible. Completing a beachhead contract earns the
right to found a field HQ on-site — the toehold that grows, over time and
money, into a regional HQ with a ring of its own.

**Capacity slots** cap the fielded force. A regional HQ can host one to three
combat companies (depending on facilities), one support company, and — with a
high-enough spaceport — an air company and jumpship berths. Facility upgrades
permanently raise the HQ's staffing requirement; expansion commits payroll, not
just cash.

Each HQ has eight upgradable facilities (mek bay, warehouse, hospital, mess,
training ground, hiring hall, comms, spaceport). **Mek bays are slots, not
abstractions**: depot repairs, reactivations, fabrication, and refits queue as
jobs occupying a bay for days. A full bay queue is a visible bottleneck with a
visible fix. The **back office** is real people posted to HQ staff slots —
command, logistics, transport, HR, and finance admins — whose count and
experience scale the machinery: delivery ETAs, route throughput, recruit
quality, project paperwork, and training days.

*(Sources: ARCHITECTURE.md §9.2, §9.3, §9.4)*

<br clear="all">

### Supply lines and money as courier

<img align="right" width="110" src="data/logos/red_bull_company.png" alt="">

HQs are nodes; links are player-established edges at three levels (charter →
scheduled service → dedicated jumpship). Each link has a **throughput cap** in
tons per week; a route's throughput is the minimum over its hops; delay and
cost multiply across hops scaled by link level and intermediary warehouse and
spaceport levels. An un-upgraded pass-through HQ makes every route through it
slower and dearer; upgrading it turns it into a hub that benefits every route.

Supply travels as physical cargo: munition pallets and spare parts have real
weight, and a deployed company's field stock is capped by its logistics lance's
truck tonnage. Shortfall on any supply class (parts, ammunition, medical,
provisions) degrades combat power, morale, healing, or maintenance. A company
deployed beyond every influence ring suffers a local-supply price penalty
(capped at 4×) and hardship pay, visible as their own ledger categories.

**Money moves the same way.** Treasury transfers between outfit, HQs, and
deployed companies travel by courier with map-distance ETAs. Standing policies
("top this company up to 500k monthly") execute automatically on payday through
the same delayed couriers. A fat wallet at home does not save a broke company
in the field this month.

*(Sources: ARCHITECTURE.md §9.5, §9.6)*

<br clear="all">

### Rotation — repair, fatigue, and training

<img align="left" width="110" src="data/logos/redline_mercenaries.png" alt="">

Three rules give the regional HQ gravitational pull. **Field repair** covers
armor patching, swapping weapons into intact mounts, and reloading. **Depot
repair** — internal-structure damage, destroyed-unit rebuilds, and refits —
requires a regional or brigade HQ mek bay over real bay time. The night after a
fight the company's techs make a repair push against the field-fixable damage,
budgeted from spare weekly hours plus workshop hours when an operational
logistics lance is present.

**Fatigue accrues on contract, decays only at home.** Each completed contract
adds fatigue scaled by length, battles fought, and casualties. Fatigue never
decays on a combat tour; off contract and physically at home it decays weekly at
the person's home HQ, faster with a better mess. Effects: morale decay,
autoresolve penalty, slower maintenance and healing. Capped at 100 — degraded,
never spiraling.

**Training happens at home.** XP is earned anywhere, but converting it into
skill levels requires a training program at the person's home HQ — a regional
or brigade HQ with a training ground. A green company that never rotates stays
green, no matter how many battles it survives.

*(Sources: ARCHITECTURE.md §9.7)*

<br clear="all">

### Markets, the hangar ledger, and cold storage

<img align="right" width="110" src="data/logos/sable_claw_mercenaries.png" alt="">

Markets are places, not menus. Every regional HQ has deep stock refreshed
monthly; every field HQ has shallow stock; every contract planet has local stock
set by its tech and industry rating. Meks and parts appear by rarity tier —
common, uncommon, rare, very rare — each refresh rolling availability against
the tier's target modified by planet industry and site facilities.

**Boards have other buyers.** Hull listings persist until bought or they age
out; someone else may take the rare chassis you were saving for. Each
manufacturing faction runs a hull pool; surplus hulls flow onto the market as
listings backed by real instance records, throttled by the faction's conflict
pressure. A dispersed black market at eight known trading hubs surfaces rare
machines — which might be a fraud.

**Every hull costs money, running or not.** Monthly per-hull cost (hangar
space, transport, insurance, tech attention) runs whether the mek is front-line,
damaged, or a wreck awaiting depot time. **Cold storage** at a regional HQ
drops per-hull cost to a fraction, but a mothballed mek needs reactivation —
tech-days scaled by quality — before it can fight or transfer. Your strategic
reserve is six weeks from ready at best.

*(Sources: ARCHITECTURE.md §9.8)*

<br clear="all">

### The MekLab and refits

<img align="left" width="110" src="data/logos/scorched_earth_company.png" alt="">

The Lab lets you edit weapon, equipment, and ammunition mounts on any hull the
outfit fields. The spatial construction grid shows all eight locations with
fixed occupants (cockpit, engine, gyro, actuators — derived from standard
inner-sphere crit tables), mounted equipment, and remaining free slots. Staging
a diff generates a parts list, refit class (A–D), and tech-time estimate.
Committing queues the hull as a bay job; it is out of action for the duration.
Selecting a mounted crit reveals its full mount identity, location, slot key and
live sound, damaged, destroyed, or missing condition in the detail pane.

The lab validates tonnage, per-location criticals, heat budget, and ammunition
and refuses an illegal fit by name before anything is queued. A hull whose
loadout differs from the catalogue baseline carries a variant marker. **The
structural-parts guarantee:** replacement structure for any chassis the outfit
owns is always available at a regional HQ by fabrication — at a cost premium
and bay time, never subject to rarity rolls — so rarity gates what's new but
never soft-locks repairing what you already field.

*(Sources: ARCHITECTURE.md §10)*

<br clear="all">

### Economy and P&L

<img align="right" width="110" src="data/logos/shadow_blade_company.png" alt="">

All money is integer C-bills. Income: contract base pay scaled by operation,
opposition, employer, reputation, and term multipliers; advances; salvage
sales; battle-loss compensation. Costs: payroll (CamOps salary tables by role
and experience), unit maintenance and spares, supply purchases, freight, HQ
construction and upkeep, loan service, event outcomes.

The monthly **per-company P&L** is a headline screen: every line item is tagged
by company, HQ, and contract so each entity carries its own browsable ledger and
profit-center view. The game is about making each company profitable. Breach of
contract — recall or combat-ineffectiveness — costs a pro-rated advance
clawback, forfeited remainder, −2 reputation, and a cooling period with the
employer's faction.

*(Sources: ARCHITECTURE.md §11)*

<br clear="all">

---

## Design and contributor notes

<img align="left" width="110" src="data/logos/stonewolf_mercenaries.png" alt="">

The simulation core (`src/domain`, `src/sim`, `src/econ`, `src/gen`) is pure and
deterministic: no I/O, no wall clock, no global state, all randomness through
named RNG streams. Frontends read through query functions and issue commands;
they never mutate game state directly. Commands are the only mutation boundary
and are failure-atomic: validate, prepare every allocation and log line, then
commit.

The full design, rule citations, system contracts, and implementation status
live in:

- `ARCHITECTURE.md` — layers, domain model, simulation loop, battle resolution,
  HQ network, supply lines, economy
- `GAMEPLAY.md` — player-facing loops, what the screens do, progression
- `ROADMAP.md` — stage plan and completion status
- `docs/coding-contract.md` — the normative rule set for all contributors
- `docs/tui.md` — terminal client architecture, keyboard model, screen reference

<br clear="all">

---

## Attribution

<img align="right" width="110" src="data/logos/stormforge_company.png" alt="">

IRON LEDGER is inspired by [MekHQ](https://megamek.org/) and the wider
[MegaMek](https://github.com/MegaMek) project, whose campaign systems shaped
what this game absorbs and what it leaves out. The rules it follows come from
the BattleTech *Campaign Operations* and *TechManual* sourcebooks. It shares no
code with MegaMek.

BattleTech and 'Mech are trademarks of The Topps Company, Inc. This is a fan
project, unaffiliated with Topps, Catalyst Game Labs, or MegaMek.

<br clear="all">

---

## License

<img align="left" width="110" src="data/logos/three_spears_company.png" alt="">

The code is under the GNU General Public License v3.0; see
[LICENSE](LICENSE).

The soundtrack (`data/music/`) is not under the GPL. It belongs to the project
owner and may be redistributed only as part of IRON LEDGER. See
[ASSETS.md](ASSETS.md) for the full terms.

No license is asserted for `data/logos/`; see [ASSETS.md](ASSETS.md).

<br clear="all">
