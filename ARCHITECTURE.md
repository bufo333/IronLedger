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
inventory; incremental saves; migrations). The full DDL lives in
[`docs/schema.sql`](docs/schema.sql); the MekHQ→ours mapping in
[`docs/mekhq-map.md`](docs/mekhq-map.md).

Borrowed subsystems (see the map doc for class-level detail):

| MekHQ subsystem | What we keep |
|---|---|
| `campaign.Campaign` + new-day loop | The daily tick pipeline: healing, acquisition delivery, maintenance checks, market refresh, contract events, payday |
| `personnel.Person` | Roles (MekWarrior, vehicle crew, aero pilot, Mek/Mechanic/Aero techs, doctor, admins: Command/Logistics/Transport/HR), skills + XP, ranks, injuries, salary tables, SPAs (later) |
| `unit.Unit` + `parts.*` | Unit = chassis + armor + equipment + crew + part slots; part quality grades A–F; weekly maintenance checks by tech skill vs. target number |
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
2. **HQ network.** Player builds/upgrades HQs at three tiers —
   **Brigade HQ** (home base), **Regional HQ** (per region of space),
   **Company/Field HQ** (per deployment). HQs project **influence rings**
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
   A company in the field consumes supply daily; shortages degrade combat
   power, morale, healing, and maintenance rolls.
4. **Support echelon matters.** Mess halls, MASH trucks, mobile field bases,
   repair depots, and cargo assets are units the player buys and attaches;
   each contributes a concrete modifier (fatigue recovery, wounded survival,
   field repair capacity, supply buffer).
5. **Attached combat support.** Tank lances, aerospace flights, battle armor,
   artillery — purchasable, attachable per company, and factored into battle
   resolution as force multipliers.
6. **Hands-off battle resolution** rich enough to reward all of the above (§7).

## 4. High-level architecture

Layered, with a strict rule: **the simulation core is pure and deterministic**
— no I/O, no wall clock, no global state. UI and persistence sit outside.

```
┌─────────────────────────────────────────────────────┐
│  Frontends: CLI (stage 1) → TUI → graphical (later) │
└──────────────────────┬──────────────────────────────┘
                       │ Commands in / Reports+Queries out
┌──────────────────────▼──────────────────────────────┐
│  Application layer: command validation, save/load,  │
│  autosave, report formatting                        │
├──────────────────────┬──────────────────────────────┤
│  Simulation core (pure, deterministic)              │
│   sim/    clock, daily pipeline, events, autoresolve│
│   domain/ person, unit, part, force, contract, hq   │
│   econ/   finance, markets, logistics network       │
│   gen/    company/person/name generation            │
├─────────────────────────────────────────────────────┤
│  data/   static game data (chassis, weapons, tables,│
│          factions, planets) loaded from .zon files  │
├─────────────────────────────────────────────────────┤
│  persist/  SQLite save files, schema migrations     │
└─────────────────────────────────────────────────────┘
```

- **Player actions are commands** (`HireePerson`, `AcceptContract`,
  `AssignLance`, `OrderParts`, `BeginRefit`, `UpgradeHq`, `ResolveEventChoice`,
  `AdvanceDay`) — a tagged union. This gives us one choke point for
  validation, an audit log, replayability, and trivially scriptable tests.
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
- **RNG discipline:** one seeded root PRNG; every subsystem draws from a
  named child stream (`rng.stream(.maintenance)`) so that adding a roll in one
  system never perturbs another. All dice are 2d6 unless CamOps says otherwise.

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
  Covers meks, vehicles, aerospace, battle armor, infantry, and support
  vehicles (MASH, mobile field base, cargo trucks) with one struct + kind enum.
- **Part** — static part type (catalog) + instances in inventories with
  condition; acquisition orders with ETA (transit from wherever sourced).
- **Force** — TO&E tree node (outfit/battalion/company/lance), commander,
  attached support assets; a Company aggregates readiness from its lances.
  Companies (and the outfit) carry player-set **identity**: a name and an
  emblem image (stored in the save, shown on rosters, AARs, and reports).
  Deployed companies also hold **local operating funds** (§9.8).
- **Contract** — type (one of the 12 AtB types below), employer, enemy,
  planet, dates, financial terms, assigned company, required force size,
  score/success state, generated scenario & event schedule.
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
  markets, pending events, RNG state.

Contract types (matching MekHQ/AtB): **Garrison Duty, Cadre Duty, Security
Duty, Riot Duty, Planetary Assault, Relief Duty, Guerrilla Warfare, Pirate
Hunting, Diversionary Raid, Objective Raid, Recon Raid, Extraction Raid.**
Garrison-class contracts (Garrison/Cadre/Security/Riot) are long, low-combat,
event-driven; Raid/Assault classes are short and battle-heavy.

## 6. The simulation loop (turn-based)

The game is **turn-based**: a turn is one campaign day, and time moves only
when the player ends a turn (multi-day advance = several turns back to
back). Nothing ever blocks or interrupts an advance — events that need the
player land in the **decision inbox** with a deadline, and an unanswered
decision applies its (safe) default option at that deadline, noted in the
log. Ignoring the inbox is a choice with consequences, not an impossibility.
Each turn runs a fixed pipeline over the whole state — order matters and is
part of the spec:

1. **Travel** — jumpship/dropship legs progress; shipments and unit transfers
   arrive.
2. **Supply consumption** — each deployed company consumes provisions/ammo/
   medical; shortage flags update.
3. **Medical** — doctors heal the wounded (MASH/hospital modifiers).
4. **Acquisition & markets** — ordered parts arrive; weekly/monthly market
   refreshes (contract market monthly, personnel weekly, units monthly).
5. **Maintenance** *(weekly per unit)* — tech rolls vs. target number
   (modified by part quality, supply state, facility, tech workload);
   failures degrade quality/parts, MekHQ-style.
6. **Training** — unassigned-to-combat lances train; XP trickle, cadre duties.
7. **Contract events** — per active contract, roll on the event table for its
   type (see §8); scenario generation for combat-class contracts.
8. **Battle resolution** — any scenario due today resolves (§7); AAR emitted.
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
   tactics skill, terrain & scenario type, attached support (air cover
   negates enemy air; artillery adds pre-round attrition; battle armor holds
   objectives).
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

Garrison-class contracts mostly skip step 3: their risk shows up as §8 events
(raids, sabotage, riots) that *occasionally* spawn a small engagement.

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

### 9.3 Capacity slots

HQ tier + facilities cap the fielded force; growth is infrastructure-first:

| Slot | Field | Regional (base → maxed) | Brigade (base → maxed) |
|---|---|---|---|
| Combat companies | 0 (hosts 1 deployed) | 1 (3 → 5 lances) | 2 (3 → 5 lances each) |
| Support company | — | 1 (lance slots unlock w/ facilities) | 1–2 |
| Air company | — | 0 → 1 (spaceport ≥3) | 1 → 2 |
| Dropship berths | 0 | 1 → 3 (spaceport) | 2 → 5 |
| Jumpship berths | 0 | 0 → 1 (spaceport ≥4 + comms ≥3) | 1 → 2 |

Support company lance kinds: **MASH, security/prisoner, mess, salvage,
logistics transport** — each feeds a concrete autoresolve/campaign modifier
(§7): wounded survival, prisoner handling & ransom events, fatigue/morale
recovery, post-battle salvage yield, supply buffer.

### 9.4 Facility upgrade paths, bays & the back office

Every facility (mek_bay, warehouse/parts_depot, hospital, mess,
training_ground, hiring_hall, comms, spaceport/drop_port) has levels 1–5.
An upgrade is a **project** in the HQ's construction queue (Stage 9C):
a paperwork phase (duration shrinks with admin capacity), then
construction. Each level costs C-bills *and permanently raises the HQ's
staffing requirement* (admins, HR, finance, quartermasters — the
`hqStaffFor` formula). An HQ staffed below requirement runs facilities at
reduced effective level. C-bills are the cheap part; the payroll tail is
the real price.

**Mek bays are slots, not abstractions** (Stage 9C): a bay level grants
work slots; depot repairs, cold-storage reactivations, component
fabrication and refits are queued jobs occupying a slot for a span of days.
A full bay queue is a visible bottleneck with a visible fix.

**The back office is people, not a number** (Stage 9A/9C, MekHQ's admin
roles made consequential): real personnel posted to HQ staff slots —
command, logistics, transport, HR, finance admins — and their *count and
experience levels* scale the machinery: logistics admins speed acquisition
rolls and shave delivery ETAs; transport admins improve route throughput;
HR admins (with the hiring hall) widen and improve the recruit pipeline,
speed training programs, and slow morale decay; command admins shorten
project paperwork; finance staff keep per-entity books timely. Company
generation already recruits this tail; hiring halls restock it.

### 9.5 Supply-line graph

HQs are nodes; **links** are player-established edges (to each other or to
the brigade HQ): charter (1) → scheduled service (2) → dedicated jumpship
(3+, requires owning one). Each link has a **throughput cap** (supply
units/week) and per-hop multipliers; a route's totals multiply across hops:

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

### 9.6 Out-of-influence operation (expensive but viable)

A company deployed beyond every ring suffers, with all effects plateauing
(no death spiral) and every effect a visible P&L line item:

- **Local supplies valve:** missing supply classes can be bought locally at
  `2.0× + 0.5× per 30 LY beyond the ring` (cap 4.0×), modified by planet
  industry rating — its own transaction category so the ledger teaches.
- **Hardship pay:** payroll bonus for remote deployment (own category).
- **Morale/HR decay** and **training XP slowdown**, recovering once back in
  a ring (or once a field HQ is planted).
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

**Fatigue accrues on contract, decays only at home.** Each contract completed
without rotating through a regional HQ adds fatigue to every person attached
to the company — scaled by contract length, battles fought, and casualties
taken (a quiet garrison wears lightly; a bloody raid campaign wears hard).
Fatigue never decays in the field; at a regional HQ it decays weekly, faster
with a better mess. Effects: morale decay, the autoresolve fatigue penalty
(§7), slower maintenance and healing. Capped at 100 — degraded, never
spiraling (§9.6 philosophy).

**Training happens at home.** XP is *earned* anywhere (combat, garrison
duty, tech work), but *converting* XP into skill levels — mekwarrior
gunnery/piloting, mek tech, mechanic — requires a training program at a
regional/brigade HQ with a training ground. A green company that never
rotates stays green, no matter how many battles it survives.

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
*new*; it never soft-locks repairing what you already field.

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
armor patching, reloading and bay jobs consume more. A full astech team
multiplies a tech's throughput; a short team halves it. Over-budget work
queues, and a hull whose maintenance didn't happen rolls with the uncovered
penalty. This is the lever behind "hire better techs or rotate home."

**Techs get hurt.** Weekly maintenance and large repairs roll for accidents,
scaled by job size; a wounded tech is swapped for a free one automatically
and the swap is logged and surfaced in the checklist. The **medbay** has
beds (hospital level, plus MASH trucks in the field) and doctor coverage;
over capacity, low-priority patients wait while triage priorities decide
who heals first. Leave sends the exhausted to R&R at double recovery.

**The end-turn checklist.** Ending a turn first runs `turnWarnings`:
decisions near deadline, open pilot/tech slots, understaffed HQs, hungry or
dry companies, overdrawn treasuries, idle bays with demand, untriaged
wounded. The CLI refuses to advance until acknowledged; the TUI renders the
same list as a modal. Nothing the player should have known slips past a
turn boundary unannounced.

## 10. MekLab / refits

Borrow MegaMekLab's model in data terms: a refit = diff between current
loadout and target loadout → parts list + tech-time + refit class (A–F per
CamOps) → validated against facility ceiling → queued as bay work (§9.4);
the unit is out of action for the duration. Custom variants are saved as
new Chassis entries in the campaign DB.

**The lab knows the rules.** Each chassis carries its construction facts
(TechManual): engine rating and weight, gyro, cockpit, internal structure,
integral heat sinks, jump jets, armor tonnage, and per-location crit slots
with their fixed occupants — so free tonnage and free crits per location
are derived, not guessed. Every mountable part carries tonnage, crit count,
mount type (energy / ballistic / missile / equipment) and location rules.
A loadout is legal only if it fits by weight, by crits in each location, by
heat-sink minimum, by ammo for every ammo weapon, and by location rule; the
lab refuses illegal fits and names the rule. Engines, heat sinks, jump
jets, gyros, cockpits and actuators are parts — bought, salvaged, or
fabricated — so a wreck from the market becomes a working hull through the
same screen that customizes a healthy one.

## 11. Economy

All money is `i64` C-bills (no floats in the ledger, ever). Income: contract
base pay (CamOps formula: base × employer multiplier × reputation multiplier ×
contract-type multiplier), advances, salvage sales, battle-loss comp. Costs:
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

**Breach clause** (Stage 9E). Failing or abandoning a contract — recall, or
combat-ineffectiveness with no affordable local replacements — costs a
pro-rated slice of the advance back, forfeits remaining payments, −2
reputation, and a cooling period with the employer's faction (their offers
run thinner and cheaper for about a year).

## 12. Persistence

SQLite: **one store file, many campaigns** (Stage 11). Every table carries a
campaign id and a `campaign` registry lists playthroughs (name, commander,
in-game date, save sequence); the player saves, lists, loads, and deletes
campaigns from one place. The sim core never touches SQL: `src/persist/`
maps `GameState` ↔ rows (the executable DDL lives in `persist/store.zig`;
`docs/schema.sql` is the design document it tracks). Static data (chassis,
weapons, planets, name tables, salary/price tables) ships as `.zon` files in
`data/` — versioned separately from saves; saves reference static data by
stable string keys. Each campaign records its `schema_version`; migrations
are forward-only. The golden-master hash proves round trips: save → load →
identical hash, and identical evolution thereafter.

**Licensing note:** MekHQ/MegaMek code is GPLv2+ and their data files carry
their own terms; BattleTech IP belongs to Topps/CGL, with Microsoft rights over
video game usage. We re-implement rules and keep our own data format. Don't
bulk-copy MegaMek data files into the repo without deciding on licensing.

## 13. Zig specifics

- **Zig 0.16**, no external dependencies for the core (SQLite via C import
  when we get there; TUI/graphics deps only in frontend layer).
- Allocators: `GameState` lives in an arena per campaign; per-tick scratch
  arena reset daily; frontends own their own.
- Errors: sim-core functions return typed error sets; player-command
  validation returns `CommandError` values (not exceptions) so the UI can
  explain refusals.
- Testing: every module carries unit tests (`zig build test`); golden-master
  sim tests: fixed seed + scripted commands → hashed state snapshot. The
  determinism pillar makes regression testing nearly free.
- Style: typed-ID enums, tagged unions for commands/events, no global mutable
  state, `std.Random` streams as described in §4.

## 14. Directory layout

```
build.zig, build.zig.zon
ARCHITECTURE.md, ROADMAP.md
docs/            schema.sql, mekhq-map.md, design notes
data/            static game data (.zon): chassis, weapons, planets, tables
src/
  main.zig       CLI entry (application layer)
  root.zig       module root, re-exports
  domain/        types.zig person.zig unit.zig part.zig force.zig
                 contract.zig hq.zig
  sim/           clock.zig rng.zig events.zig autoresolve.zig
  econ/          finance.zig logistics.zig market.zig
  gen/           company_gen.zig (+ name_gen, person_gen later)
  persist/       (stage 9) sqlite mapping
```

## 15. Open questions (decide during the relevant stage)

- Era/start date: scaffolding defaults to **3025** (Succession Wars — scarcity
  makes logistics shine). Late-era tech (Clan invasion) later.
- Star-map scope: full Inner Sphere (~2000 systems) vs. curated ~200-system
  map. Leaning curated for v1.
- TUI library vs. hand-rolled ANSI for stage-10 frontend.
- How much of MegaMek's unit catalog to re-encode vs. a curated ~150-variant
  starter set. Leaning curated.
