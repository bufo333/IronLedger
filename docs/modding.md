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
```

Build with the overlay:

```
zig build -Ddata=mymod
zig build test -Ddata=mymod     # the catalogue tests run against your data
zig build run -Ddata=mymod -- --tui
```

Files you leave out fall back to the stock ones in `data/`. The settings
screen (F12) and the REPL banner say which files are overlaid.

## What the files are

| file | typed against | what it holds |
|---|---|---|
| `chassis.zon` | `domain/chassis.zig` `Chassis` | every hull: tonnage, BV, cost, rarity, intro year, construction facts, loadout slots |
| `planets.zon` | `domain/planet.zig` `Planet` | the star map: position, faction, industry, optional terrain |
| `parts.zon` | `domain/part.zig` `PartDef` | weapons, ammo, components, supplies: cost, rarity, availability code, tech base, intro year, mount facts |
| `tables/tuning.zon` | `domain/tuning.zig` `Tuning` | every balance knob, by subsystem |
| `tables/meklab.zon` | `domain/meklab.zig` `Tables` | TechManual engine and internal-structure tables |
| `tables/names.zon` | `gen/person_gen.zig` | first names, last names, callsigns |
| `tables/ranks.zon` | `domain/rank.zig` `RankRow` | rank names, abbreviations, pay multipliers |
| `tables/awards.zon` | `domain/award.zig` `AwardRow` | decorations and the counters that earn them |
| `tables/abilities.zon` | `domain/ability.zig` `AbilityRow` | special pilot abilities |
| `tables/rat.zon` | `domain/rat.zig` `RatRow` | per-house design pools by weight class |
| `tables/factions.zon` | `domain/faction.zig` `FactionRow` | houses, colours, foes, pay, whether they hire |
| `tables/scenarios.zon` | `domain/scenario.zig` `Table` | scenario types and the d6 table per contract kind |
| `tables/terrain.zon` | `domain/terrain.zig` `Table` | terrain classes, weather, the 2d6 weather table |

## Rules of the road

- The struct is the schema. A missing field with no default, a wrong
  type, or an unknown field fails the build with a line number. Fields
  with defaults may be omitted.
- Keys are referenced across files: every loadout `part` must exist in
  `parts.zon`, every RAT entry in `chassis.zon`, every faction key in
  `factions.zon`. `zig build test -Ddata=<dir>` runs the catalogue tests
  that check those links, plus the MekLab construction rules on every mek.
- Money is integer C-bills; multipliers are basis points (`10_000` = ×1).
- Saves record no data provenance. A campaign saved under one mod and
  loaded under another keeps its people and hulls but looks designs and
  parts up by key; a key that no longer exists is treated as unknown.
- Cite the sourcebook next to any rule table you change, as the stock
  files do.
