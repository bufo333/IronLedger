# Gameplay — how it actually plays

The design spec the simulation stages implement against. ARCHITECTURE.md says
what the systems are; this says what the *player does*. Core fantasy: you run
the whole mercenary command from behind a desk, and the desk matters.

## The three nested loops

**Daily — the turn (minutes of play):** the game is turn-based; a turn is a
day and time moves only when you end one. Between turns you work the desk:
read the AAR from last night's raid, approve an acquisition, answer the
inbox — an employer's off-contract request, a salvage dispute, a black-market
contact, a ransom demand — each with a deadline a few days out. Nothing stops
the clock for you: end turns past a deadline and the cautious default gets
chosen in your name, entered in the log. Skimming a quiet garrison month in
a dozen quick turns is fine; the inbox is what catches you when it isn't
quiet.

**Monthly (the heartbeat):** payday. Every company's P&L lands on your desk —
contract income vs. payroll, maintenance, supplies, freight, hardship pay.
The contract market refreshes with offers *inside your influence rings*.
Personnel market turns over. Loans tick. This is where you learn whether a
deployment is bleeding you and why: the ledger is itemized down to
"local supplies (3.0×, Deshler, 40 LY beyond ring)".

**Strategic (the campaign):** spend profit to grow reach and capacity. Found a
field HQ on a beachhead world. Upgrade it toward regional status. Link it into
the supply network. Raise a facility level so a company can grow from 3 lances
to 5, or an air company slot opens. Buy the dropship that makes a route cheap.
Hire the admin staff the paperwork now demands. Accept a bigger contract than
you could last year.

## Influence: where you can work

Each HQ projects an **influence ring** — a radius in light-years on the star
map (ARCHITECTURE §9). Inside a ring: full contract market, normal logistics,
normal morale. In the **beachhead band** (one jump past the ring): offers are
still visible but flagged, with a penalty preview ("expect 2.5× supply costs,
hardship pay, slow training"). Beyond the band: dark — nobody out there has
heard of you.

Deploying past your rings is *expensive but viable*: supplies must be bought
locally at 2–4× price, payroll carries a remote-hardship bonus, morale and
training sag, shipments crawl. A rich beachhead contract can still profit —
and completing one lets you **plant a field HQ** on-site, your toehold. Field
HQ → regional HQ is an upgrade project, and when it completes, a new ring
appears on the map. That is the expansion loop:

```
profitable ring → beachhead contract at a premium → field HQ toehold
      ↑                                                  ↓
   new ring  ←  regional upgrade + supply link  ←  survive the costs
```

## Capacity: why you need more HQs

A regional HQ supports exactly:

| Slot | Base | Grown by |
|---|---|---|
| 1 combat company | 3 lances | mek_bay + barracks levels → up to 5 lances |
| 1 support company | MASH, security/prisoner, mess, salvage, logistics-transport lances | hospital/mess/warehouse levels unlock lance slots |
| 1 air company | locked | spaceport level unlocks aerofighter lances |
| Dropship berths | 1 | spaceport levels |
| Jumpship berths | 0 | spaceport + comms levels |

A brigade HQ (your home base, one only) carries roughly double. A field HQ
is a forward base: one company can be based there to rest, resupply and
stage, and any deployed company's convoys ship from whichever of your
warehouses is nearest with the line — so a stocked firebase beside the
fighting shortens every convoy. What a field HQ lacks is whatever needs a
facility it has not built: no training without a training ground, no
structural repair without a mek bay, no hiring without a hall. Build them
there or raise it to regional. **Want a second company at full service? You
need a second regional HQ** — with the staff, upkeep, and supply line that
implies. Growth is infrastructure-first, always.

A new company is raised empty: you name it, then take every hull from the
pool, cold storage and the boards, buy its support train and crew it. The
slot check is the order's, not the screen's — name a company where no HQ
has a free combat-company slot and the order is refused after the name,
with the reason.

## Upgrades: C-bills are the cheap part

Every facility (mek bay, logistics warehouse, hospital, mess, training ground,
hiring hall, comms, spaceport) has levels 1–5. An upgrade is a **project**:
a paperwork phase (admin capacity determines how long the permits and
procurement take), then construction. And each level *permanently raises the
HQ's staffing requirement* — more astechs, clerks, HR and finance staff on
payroll forever. An understaffed HQ runs its facilities below their built
level. Expansion therefore commits future payroll, not just cash: the classic
tail-to-teeth tradeoff, on purpose.

## Supply lines: the map is a graph

HQs are connected by **supply links** the player establishes: charter
(level 1) → scheduled service → dedicated jumpship (level 3+, requires owning
one). A link has a throughput cap (supply units/week) and per-hop delay/cost
multipliers. Shipments route through the network; every intermediate hop
multiplies delay and freight cost — *unless* the intermediary HQ's warehouse
and spaceport are upgraded, turning it into a proper hub. Throughput is
bottlenecked by the weakest hop: stack two deployed companies behind one
charter link and watch both starve. A shipment or part order that would
overfill a hop this week is refused before any money moves; paid freight
takes its tons out of every hop's week. The fix is always a purchase order
away, and always costs more than you'd like.

## Rotation: why companies come home

The field keeps a company *running*; only a regional HQ keeps it *sharp*:

- **Field repair** covers armor patches, weapon/equipment swaps (if you have
  the parts), and ammo reloads. **Structural damage** — a cored torso, a
  blown-off leg or arm, a destroyed mek — waits for a regional HQ mek bay and
  takes real weeks in it. Deploy long enough and your roster fills with
  three-quarter-strength meks and hangar queens riding the dropship.
- **Fatigue** climbs with every contract finished without rotation — a
  little for a quiet garrison, a lot for a long bloody campaign — and falls
  at home, as fast as the home HQ's mess allows, its HR staff keeping
  spirits up; garrison barracks give back only a share of that. Tired
  companies fight worse, maintain worse, and grumble.
- **Training** converts XP into skill levels only at a training ground,
  and only at a person's home HQ — where they are posted, else their
  company's home base — at the pace of that HQ's HR office. Your veterans
  earn XP in the field; they *become* veterans at home.
- **The field workshop**: each night's repair push pools the techs' spare
  hours, and a ready Logistics lance adds its workshop crews' shift.

So the deployment rhythm becomes a real decision: take the lucrative
back-to-back contract, or pay the transit and the idle month to rotate home
and reset? The readiness report beside the P&L shows fatigue, deferred
structural repairs, and banked XP per company — profit now vs. force quality
later, every quarter.

## Oversight: the desk between turns

Everything that happens leaves a record you can drill into, and everything
you own reports to you (Stages 9A–9C):

- **The log is a database, not a scroll**: filter the campaign history to
  any company or HQ — every battle AAR, every decision and what it cost,
  every delivery, every construction milestone, every recovery.
- **Every entity keeps books**: the outfit, each regional HQ, each deployed
  company has its own treasury, ledger, and P&L. Money moves by courier
  with real delays — manually, or by standing policy ("keep Bravo topped up
  to 500k, monthly"). A rich outfit with a broke forward company is a
  logistics failure you can see coming on two ledgers at once.
- **Supplies are pallets, not abstractions**: munitions by family, parts,
  provisions — stocked per site with real tonnage against warehouse
  capacity, burned by battles and daily life, itemized in AARs (\"expended:
  3t LRM reloads\"). The `supplies` and `demand` screens answer "what do we
  have, what are we burning, what must be ordered" at every level.
- **The HQ works in queues you can read**: mek bay slots (who's in, what
  for, done when), construction projects (paperwork → build), fabrication
  jobs for the torso assemblies nobody sells this month.
- **Contracts show their win condition**: victory points against a duration
  clock or an enemy force pool that battles grind down. Close out a met
  objective, redeploy straight to the next contract, or recall early and
  eat the breach clause — your call, priced on screen.
- **The back office is staff, not UI**: logistics admins speed orders and
  deliveries, HR staff and hiring halls feed recruits, morale, and training
  throughput, command admins shorten paperwork. Their headcount and
  experience are levers like any other — at the HQ where they sit: a
  recruit is as good as the hiring HQ's hall and HR office, and a company
  trains and rests on its home HQ's staff.
- **Support counts only when it can roll**: a MASH, mess, security,
  salvage or logistics lance helps only while one of its hulls can take
  the field with a crew fit for duty, and the same test decides recon (a
  scouting lance), air cover (a fighter) and the battle line. Field wounds heal at the MASH rate only with a
  ready MASH truck, and when field beds run short they go to patients by
  priority, the rest waiting a day.
- **Rosters are assignments, not lists**: every mek shows its pilot and its
  tech, every truck its driver and mechanic — and every empty slot is a hull
  that won't be repaired, reloaded, or fielded. Techs have hours in the
  week; a wounded tech (accidents happen in the bay) gets swapped, and the
  medbay shows who's out, for how long, and who you've triaged to the front.
- **The turn ends with a checklist**: before the day advances you see what
  you left undone — decisions near deadline, open slots, hungry companies,
  overdrawn treasuries, idle bays with demand — and choose to fix it or
  proceed anyway; a week's advance asks the same as a day's. Red marks
  what costs you if left, but nothing is forced: most of it is a bounded
  tax, and the one hard deadline is a contract left combat-ineffective,
  which breaches after two weeks. Nothing you should have known slips
  past a turn boundary.
  What you cannot act on stays on the Desk without stopping the turn: a
  mek whose pilot is in the medbay keeps the seat for them, and the TO&E
  shows it sitting out until the day they are back.
- **Contact is announced**: a few days before a scheduled engagement the
  checklist warns — skulls and odds under the ROE in force, fieldable
  strength against what was committed, fights of each munition on the
  trucks — and a multi-day advance stops once, the day that window opens.
  The warning opens the **battle orders**: rules of engagement (locked
  under the employer's integrated command), each lance's role, an
  emergency resupply bought on the contract world at local prices from
  the company's local funds and truck room (a fight of each short
  munition, armour for dented hulls, delivered the same day), and a
  recall that breaches the contract. The odds recompute as you change
  them. Confirming the orders clears the warning; skipping them leaves the
  current settings standing, and the next advance goes ahead either way.
- **Orders are exact**: the command line (and the console) takes every
  word you type or refuses the order with its usage — a stray word is
  never quietly dropped, a choice outside its list is never read as the
  default. Bare `autoadmit` flips the medbay's standing order to admit the
  wounded itself. A refused order says why in one sentence
  (`refused: …`), in the same words on every screen and in the console.

## Your outfit, your hangar

You name the outfit and every company in it, and give each an emblem —
identity shows up on rosters, contracts, and after-action reports.

The hangar is a portfolio, not a garage. Every hull you own bills you
monthly whether it fights or rusts, so the roster screen ranks meks by what
they cost against what they contribute. Markets are physical places — the
board at each regional HQ, the thin listings at a field HQ, whatever the
local contract planet's industry can offer — and good machines *appear* by
rarity: when a rare chassis surfaces on a market two rings away, getting it
home is a logistics exercise you'll feel. Structural parts for anything you
already own are always available at a regional HQ (fabricate or buy), so
repair is never rarity-locked. A company in the field that loses a mek can
buy a local replacement — if its **local operating funds** cover it; the
brigade treasury can't teleport. And when a company rotates home overweight,
cold storage turns spare hulls into a cheap strategic reserve that takes
weeks, not hours, to wake back up.

## Losing a lance

Hulls die in the field, and not every death is a depot job (Stage 12D).
A mek whose centre torso was cored comes home for a new assembly; one
whose engine was killed needs a new engine at TechManual prices; an
ammunition explosion guts the torsos too; some wrecks are scrap, worth
only what `strip` crates into the warehouse. The hangar prices each rebuild
against a new hull and says when it is not worth doing.

Losing the field is worse. Whoever holds it keeps the wrecks: without a
salvage lance, trucks or a DropShip on-world, a rout leaves hulls to the
enemy — gone — and their pilots may walk out or be taken, a ransom to pay
or a prisoner to trade. The enemy is a force of its own, posted with the
offer (the board says what the intel can read, `candidates` gives each
company's odds), and it does not shrink as your company wears down. A
company's **rules of engagement** decide how it takes a turning fight:
hold the ground for a better roll and heavier losses, or pull back early
and give up the field on a draw. Vehicles fight on their crews' vehicle
gunnery and driving, not on MechWarrior skills. A company with nothing
fit to field concedes the engagement: a defeat, scored and reported like
any other, and its after-action report holds the turn until read. A
mauled company can buy a local replacement off the contract world's board
with its local funds — the treasury still cannot teleport. Assault-class
structure needs a proper regional bay; the rest of the outfit's growth has
to catch up with its hulls.

## Reading a contract before you sign it

Every HQ posts its own board — work inside its ring and beachhead band —
and only the companies based there can take it. Each offer is rated in
**skulls**, half a skull at a time, for the company that would go: three
skulls is an even, hard fight; fewer is easier; five is outmatched. The
rating is the battle model's own arithmetic — your company's power as it
stands today (machines, pilots, fatigue, supply, recon) against the
enemy's lances and skill as the comms of the HQ that posted the offer can
read them — so a blurry intel picture shows as a range ("2–3½ skulls"),
and it sits beside the tonnage ("640t, L7 M9, vs ~660–825t") and the odds
of winning a fight or losing the field. `candidates` rates every company in range side by side. The
enemy does not shrink when you do: a mauled company's skulls climb on the
active contract, and the checklist says so. Harder jobs pay more — the
employer prices the opposition. A new outfit starts with lights and
mediums, which its founding mek bay can rebuild; heavies wait for a bigger
bay.

## A worked month (mid-game)

Marik border, 3027. Two regional HQs: **Zenith** (home region, mature) and
**Anchorage** (young). Alpha Company is experienced; Bravo is still growing.

1. Market day: the player compares the offers inside each HQ's reach with the
   beachhead work beyond it. Pay, terms, opposition, travel and supply exposure
   come from the same rules the command will enforce.
2. Before assigning Bravo, the player reviews its readiness and field plan.
   Any charter, local-purchase or resupply cost shown is the current quote, not
   a promise baked into this example.
3. Later, Anchorage's warehouse approaches its limit. The upgrade screen shows
   cost, paperwork, construction and added staffing before the player commits;
   understaffing lowers effective facility levels until corrected.
4. An event arrives in the inbox with explicit choices and a deadline. It can
   wait, but the turn cannot silently discard a decision whose deadline has
   arrived.
5. Payday posts the actual salaries, maintenance, food, housing and freight to
   their treasuries. The ledger and P&L show whether each operation is carrying
   itself; the player decides whether a forward HQ is worth the continuing
   payroll and construction commitment.

Nobody piloted a mek. That's the game.
