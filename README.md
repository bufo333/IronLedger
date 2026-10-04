# IRON LEDGER

*A BattleTech mercenary company in the Succession Wars.*

![Title screen](docs/screenshots/splash.svg)

IRON LEDGER is a terminal strategy game about running a mercenary outfit in
the BattleTech universe, in the scarcity years of the 3025 Succession Wars.
You are the commander of the whole command — not a pilot. You chase contracts
across the Inner Sphere, keep the 'Mechs running, the troops paid and the
supply lines open, and send your companies into battles that resolve on their
own from everything you set up beforehand: training, maintenance, ammunition,
provisions, morale and the support echelons behind them. You win through
logistics, people and money; the tabletop is deliberately skipped, and the
campaign around it is the game.

Everything is turn-based. A turn is a day, and nothing happens while you think.

## What you do

You run several companies at once from a network of headquarters. Between
turns you work the desk: read last night's after-action report, answer the
inbox — an employer's off-contract request, a salvage dispute, a ransom demand,
each with a deadline — approve an order, move money. Every month, payday lands
a profit-and-loss statement on each company, so you learn which deployments are
carrying themselves and which are bleeding you.

Over a campaign you spend profit to grow your reach: found a forward base on a
frontier world, upgrade it toward a full regional headquarters, link it into
your supply network, hire the back-office staff the paperwork now demands, and
take on bigger contracts than you could last year. Growth is
infrastructure-first — a second company at full service means a second regional
HQ, with the payroll and supply line that implies.

Each deployment plays out as an operational story. You pick the operations, set
each one's intent, task your lances, decide whether to scout, strike, prepare
or wait, and live with the local consequences. When battle comes it is
hands-off: the after-action report tells you what your preparation was worth.

## Key systems

- **Campaign operations.** A contract opens with a briefing and runs as an arc
  of beats — arrival, complication, escalation, climax, aftermath — with
  materially different endings. An operations board offers combat and
  non-combat operations; committing one sets a mission intent (preserve force,
  secure an objective, break the enemy, protect assets, secure intelligence, or
  recover people or equipment), tasks each lance a job, and spends a capped pool
  of command attention on interventions. Winning the fight and accomplishing
  the operation are separate results.
- **Contracts and hands-off combat.** Twelve contract types from garrison duty
  to planetary assault, with terms that matter — command rights, salvage share,
  negotiation. Each offer is rated in skulls for the company that would go.
  Battles autoresolve from campaign state and produce a detailed after-action
  report — every hit, every casualty, ammunition burned, salvage hauled — kept
  in a journal, with a full contract history and a kill record for every pilot.
- **Your company and its people.** Everyone is an individual: role, skills on
  the MekHQ scale, rank, experience, kills and awards, fatigue, morale, shares
  in the outfit, and per-location injuries. The young learn faster and the old
  retire; a restless crew hands in notice on payday unless you keep them. A
  Dragoons rating, F to A*, decides which offers reach your board and what you
  are paid.
- **Logistics and the HQ network.** Headquarters project influence rings that
  gate the contract market; supply lines carry real tonnage between them on
  routes with throughput limits; treasuries sit per outfit, HQ and deployed
  company, with cash moving by courier over real transit time. Supplies are
  physical pallets — munitions, armor, components, provisions, medical — and a
  company in the field spends only the funds and stock it physically holds.
- **The MekLab and the hangar.** Edit a BattleMech's weapon, equipment and
  ammunition mounts; the lab validates tonnage, per-location criticals, heat and
  ammunition and refuses an illegal fit by name, then quotes the refit class
  (A-D) and gates it on the mek bay. Hulls take weekly maintenance against a
  target set by quality and tech skill, repair in field and depot tiers, and can
  be mothballed in cold storage to stop the bills. The hangar ranks every
  machine by what it costs against what it contributes.
- **The open market.** Every HQ posts boards for hulls, parts and ammunition —
  staples always on hand, rarer gear in slots that may or may not hold it this
  month, damaged hulls priced by condition, and transports at the bigger
  spaceports. At a wired HQ a black-market fence may surface a rare machine —
  which might be a fraud.
- **A deployment with memory.** Named liaisons, enemy officers and rival
  mercenary companies persist in your records, carrying their relationships and
  standing from one contract to the next; your officers accumulate their own
  track record; and every world keeps its own state — security, civilian
  support, employer control, enemy influence — that later contracts, markets
  and intelligence read. It all sits on a 234-system star map of the Inner
  Sphere and near Periphery, where the market and the designs in service move
  with the campaign year.

## Getting it running

You need [Zig 0.16](https://ziglang.org/download/) and the system SQLite
library (present on macOS; `libsqlite3-dev` on Debian/Ubuntu). For the
soundtrack, an optional command-line audio player on `PATH` — `afplay`
(macOS), `mpv`, `ffplay` or `aplay`.

```sh
zig build run -- --tui                            # play
zig build run -- --tui --store path/to/save.db    # play, saving to a chosen file
zig build -Doptimize=ReleaseFast --prefix dist    # build a standalone binary at dist/bin/game
```

One SQLite file holds every player and campaign; without `--store` the game
keeps it in a per-user data directory. A maximised terminal gives the fullest
layout and everything degrades to 80×24; pass `--ascii` for terminals that draw
box glyphs double-width.

Design and contributor notes live in `ARCHITECTURE.md`, `GAMEPLAY.md`,
`ROADMAP.md` and `docs/`.

## Attribution

IRON LEDGER is inspired by [MekHQ](https://megamek.org/) and the wider
[MegaMek](https://github.com/MegaMek) project, whose campaign systems shaped
what this game absorbs and what it leaves out. The rules it follows come from
the BattleTech *Campaign Operations* and *TechManual* sourcebooks. It shares no
code with MegaMek.

BattleTech and 'Mech are trademarks of The Topps Company, Inc. This is a fan
project, unaffiliated with Topps, Catalyst Game Labs or MegaMek.

## License

The code is under the GNU General Public License v3.0; see
[LICENSE](LICENSE). The soundtrack and the Unforgiven crest are not under the
GPL: they belong to the project owner and may be redistributed only as part of
IRON LEDGER. See [ASSETS.md](ASSETS.md).
