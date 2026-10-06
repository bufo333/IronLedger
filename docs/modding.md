# Modding IRON LEDGER

Every table the sim reads is a `.zon` file under `data/`, imported at
compile time into a typed Zig struct. A mod is a directory holding copies
of the files you want to change, at the same relative paths:

```
mymod/
  chassis.zon            # designs, loadouts, intro years
  tables/tuning.zon      # every knob: fatigue, turnover, rating, market …
  tables/rat.zon         # house random assignment tables
  tables/scenarios.zon   # scenario table per contract kind
  tables/opfor.zon       # opposing force per contract kind
  tables/skulls.zon      # contract difficulty bands in half skulls
```

Build with the overlay:

```
zig build -Ddata=mymod                  # validates the data first; a broken table fails the build
zig build validate-data -Ddata=mymod    # just the data checks
zig build test -Ddata=mymod             # every test, against your data
zig build run -Ddata=mymod -- --tui
```

The data checks are the tests named `data: …`: every table against the
others (RAT entries are catalogue meks, loadout parts exist, factions and
capitals line up), every string markup-safe, every tuning knob in range,
every 2d6 threshold reachable and in order, the rank ladder one row per
rank in order, skull bands descending to a catch-all, and every catalogue
mek's own loadout legal under the MekLab rules. A table a generator draws
from (the name pools, the rank ladder, the skull bands) that is empty or
the wrong length fails the compile with the file's name. Every build's
install waits on the checks, a mod's or not.

Files you leave out fall back to the stock ones in `data/`. The settings
screen (F12) and the REPL banner say which files are overlaid. A `-Ddata`
directory that does not exist, or that overlays no data file, fails the
build; a `.zon` file in it the build does not read (a misspelled name) is
named in a warning and ignored. `docs/data-fixtures.py` builds a broken
overlay of each family and checks that every one fails; CI runs it.

## What the files are

| file | typed against | what it holds |
|---|---|---|
| `chassis.zon` | `domain/chassis.zig` `Chassis` | every hull: tonnage, BV, cost, rarity, intro year, construction facts, loadout slots; optional `left_arm_actuators` / `right_arm_actuators` (`.full` / `.no_hand` / `.no_lower_arm`, default `.full`) drive the fixed-occupant derivation for arm crits |
| `planets.zon` | `domain/planet.zig` `Planet` | the star map: position, faction, industry, optional terrain |
| `parts.zon` | `domain/part.zig` `PartDef` | weapons, ammo, components, supplies: cost, rarity, availability code, tech base, intro year, mount facts |
| `tables/tuning.zon` | `domain/tuning.zig` `Tuning` | every balance knob, by subsystem |
| `tables/difficulty.zon` | `domain/difficulty.zig` `Table` | green / regular / veteran / elite: multipliers on pay, fabrication, purchases, opposition, turnover; scrap and field-recovery modifiers |
| `tables/meklab.zon` | `domain/meklab.zig` `Tables` | TechManual engine and internal-structure tables |
| `tables/names.zon` | `gen/person_gen.zig` | first names, last names, callsigns |
| `tables/ranks.zon` | `domain/rank.zig` `RankRow` | rank names, abbreviations, pay multipliers |
| `tables/awards.zon` | `domain/award.zig` `AwardRow` | decorations and the counters that earn them |
| `tables/abilities.zon` | `domain/ability.zig` `AbilityRow` | special pilot abilities |
| `tables/rat.zon` | `domain/rat.zig` `RatRow` | per-house design pools by weight class |
| `tables/factions.zon` | `domain/faction.zig` `FactionRow` | houses, colours, foes, pay, whether they hire, manufacturing chassis list (provisional), replenishment rate, and conflict sensitivity |
| `tables/scenarios.zon` | `domain/scenario.zig` `Table` | scenario types and the d6 table per contract kind (with `recovery_mod` for a lost field) |
| `tables/opfor.zon` | `domain/opfor.zig` `Table` | the opposing force per contract kind: lances, quality roll, reinforcements |
| `tables/skulls.zon` | `domain/skulls.zig` `Table` | half-skull bands by power ratio (keep them aligned with `battle.ratioBonus`), the outmatched line, the checklist warning level |
| `tables/terrain.zon` | `domain/terrain.zig` `Table` | terrain classes, weather, the 2d6 weather table |
| `tables/arcs.zon` | `domain/arc.zig` `Table` | operation arc archetypes: narrative beats, finale options, opening templates per contract kind |
| `tables/operations.zon` | `domain/operation.zig` `Table` | operation mission templates: arc ownership, combat flag, objectives, follow-up keys |
| `tables/actor_archetypes.zon` | `domain/actor.zig` `Table` | actor archetypes attached to arcs: NPC roles (liaison, official, militia leader …), faction side, agenda text, and the arc keys they appear in (P4i) |
| `tables/rival_archetypes.zon` | `domain/rival.zig` `ArchetypeTable` | rival company archetypes instantiated at contract accept: hostile/allied faction side, doctrine (aggressive/cautious/attritional/opportunist/honorable), and the arc keys they appear in (P4i) |

## Rules of the road

- The struct is the schema. A missing field with no default, a wrong
  type, or an unknown field fails the build with a line number. Fields
  with defaults may be omitted.
- Keys are referenced across files: every loadout `part` must exist in
  `parts.zon`, every RAT entry in `chassis.zon`, every faction key in
  `factions.zon`, every manufacturing chassis in `factions.zon` must exist in
  `chassis.zon`, every operation `arc_key` in `arcs.zon`, and every arc
  `kinds` entry must name a known `ContractKind`. Additionally, every arc
  defined in `arcs.zon` must have at least one actor archetype in
  `actor_archetypes.zon` and at least one rival archetype in
  `rival_archetypes.zon` whose `arcs` list includes that arc key; the build
  enforces this at compile time and fails with the first uncovered arc key.
  `zig build test -Ddata=<dir>` runs the catalogue tests that check those
  links, plus the MekLab construction rules on every mek.
- Every string must be safe to show as it is: valid UTF-8, no `{`
  anywhere (braces start the screens' colour tags, and there is no escape
  for a literal one in data), and no control characters — no tabs,
  newlines or escape codes. `zig build test -Ddata=<dir>` walks every
  string in every data file and names the first one that breaks this.
- Money is integer C-bills; multipliers are basis points (`10_000` = ×1).
- The build checks every tuning knob: a `_bp` share stays within
  0..100000, a `_pct` knob within 0..100 (−100..100 for a listed signed
  delta), an unsigned count is above zero (desk and slot tables may hold
  zeros), and a signed knob is never negative unless `domain/tuning.zig`
  lists it in `signed_knobs` (roll modifiers and penalties).
- Knobs are named by subsystem in `tuning.zon`. For example, an HQ supply
  link carries `logistics.throughput_per_level` supply units a week per
  link level, each `logistics.tons_per_supply_unit` tons.
- Saves record no data provenance. A campaign saved under one mod and
  loaded under another looks designs, parts, planets and factions up by
  key; if any key it holds is missing from the data it is loaded with,
  the game refuses to load it as a corrupt save.
- Cite the sourcebook next to any rule table you change, as the stock
  files do.
