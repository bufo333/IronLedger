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

A brigade HQ (your home base, one only) carries roughly double. Field HQs
support a deployed company's *presence* but almost nothing else. **Want a
second company? You need a second regional HQ** — with the staff, upkeep, and
supply line that implies. Growth is infrastructure-first, always.

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
charter link and watch both starve. The fix is always a purchase order away,
and always costs more than you'd like.

## Rotation: why companies come home

The field keeps a company *running*; only a regional HQ keeps it *sharp*:

- **Field repair** covers armor patches, weapon/equipment swaps (if you have
  the parts), and ammo reloads. **Structural damage** — a cored torso, a
  blown-off leg or arm, a destroyed mek — waits for a regional HQ mek bay and
  takes real weeks in it. Deploy long enough and your roster fills with
  three-quarter-strength meks and hangar queens riding the dropship.
- **Fatigue** climbs with every contract finished without rotation — a
  little for a quiet garrison, a lot for a long bloody campaign — and only
  falls at a regional HQ (faster with a good mess). Tired companies fight
  worse, maintain worse, and grumble.
- **Training** converts XP into skill levels only at a regional/brigade HQ
  training ground. Your veterans earn XP in the field; they *become*
  veterans at home.

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
  experience are levers like any other.
- **Rosters are assignments, not lists**: every mek shows its pilot and its
  tech, every truck its driver and mechanic — and every empty slot is a hull
  that won't be repaired, reloaded, or fielded. Techs have hours in the
  week; a wounded tech (accidents happen in the bay) gets swapped, and the
  medbay shows who's out, for how long, and who you've triaged to the front.
- **The turn ends with a checklist**: before the day advances you see what
  you left undone — decisions near deadline, open slots, hungry companies,
  overdrawn treasuries, idle bays with demand — and choose to fix it or
  proceed anyway. Nothing you should have known slips past a turn boundary.

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

## A worked month (mid-game)

Marik border, 3027. Two regional HQs: **Zenith** (home region, mature) and
**Anchorage** (young, level-1 spaceport). Alpha Company (5 lances, veteran)
garrisons inside Zenith's ring — quiet, profitable, training XP ticking.
Bravo (3 lances, green) sits at Anchorage between contracts.

1. Market day: Anchorage's ring shows four offers. A fifth is flagged
   **beachhead** — an 8-month garrison on Talitha, 35 LY past the ring,
   paying 1.6× because nobody else will go. Penalty preview: ~2.5× supplies,
   hardship pay, one-jump-longer resupply.
2. You take it for Bravo, but first spend 400k chartering a second supply
   link and pre-shipping 8 weeks of provisions — cheaper than buying local
   later.
3. Week 3: Anchorage's link to Zenith is at throughput cap (Bravo's
   pre-shipments + Alpha's spare parts). Queue a warehouse upgrade at
   Anchorage: 2.1M, 3 weeks paperwork + 5 construction, and +6 permanent
   staff. Approve. HR flags you're now 2 clerks short — hiring hall fills it
   in a week.
4. Week 5: decision event on Talitha — the local governor offers cut-rate
   *local* provisions in exchange for escorting a food convoy (off-contract,
   small risk). Accept: local-supply multiplier drops to 2.0× and morale
   holds. The escort resolves as a minor skirmish; the AAR credits Bravo's
   security lance for zero prisoners lost.
5. Payday: Alpha +840k. Bravo −110k *this* month (freight-heavy), projected
   +300k/month once pre-shipments stop. Decision: when the Talitha contract
   ends, plant a field HQ there — the ring it will eventually project covers
   three fat industrial worlds.

Nobody piloted a mek. That's the game.
