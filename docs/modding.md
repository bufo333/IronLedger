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
| `tables/difficulty.zon` | `domain/difficulty.zig` `Table` | green / regular / veteran / elite: multipliers on pay, fabrication, purchases, opposition, turnover; scrap and field-recovery modifiers |
| `tables/meklab.zon` | `domain/meklab.zig` `Tables` | TechManual engine and internal-structure tables |
| `tables/names.zon` | `gen/person_gen.zig` | first names, last names, callsigns |
| `tables/ranks.zon` | `domain/rank.zig` `RankRow` | rank names, abbreviations, pay multipliers |
| `tables/awards.zon` | `domain/award.zig` `AwardRow` | decorations and the counters that earn them |
| `tables/abilities.zon` | `domain/ability.zig` `AbilityRow` | special pilot abilities |
| `tables/rat.zon` | `domain/rat.zig` `RatRow` | per-house design pools by weight class |
| `tables/factions.zon` | `domain/faction.zig` `FactionRow` | houses, colours, foes, pay, whether they hire |
| `tables/scenarios.zon` | `domain/scenario.zig` `Table` | scenario types and the d6 table per contract kind (with `recovery_mod` for a lost field) |
| `tables/opfor.zon` | `domain/opfor.zig` `Table` | the opposing force per contract kind: lances, quality roll, reinforcements |
| `tables/skulls.zon` | `domain/skulls.zig` `Table` | half-skull bands by power ratio (keep them aligned with `battle.ratioBonus`), the outmatched line, the checklist warning level |
| `tables/terrain.zon` | `domain/terrain.zig` `Table` | terrain classes, weather, the 2d6 weather table |

## Rules of the road

- The struct is the schema. A missing field with no default, a wrong
  type, or an unknown field fails the build with a line number. Fields
  with defaults may be omitted.
- Keys are referenced across files: every loadout `part` must exist in
  `parts.zon`, every RAT entry in `chassis.zon`, every faction key in
  `factions.zon`. `zig build test -Ddata=<dir>` runs the catalogue tests
  that check those links, plus the MekLab construction rules on every mek.
- Every string must be safe to show as it is: valid UTF-8, no `{`
  anywhere (braces start the screens' colour tags, and there is no escape
  for a literal one in data), and no control characters — no tabs,
  newlines or escape codes. `zig build test -Ddata=<dir>` walks every
  string in every data file and names the first one that breaks this.
- Money is integer C-bills; multipliers are basis points (`10_000` = ×1).
- `zig build test` checks every tuning knob: a `_bp` share stays within
  0..100000, an unsigned count is above zero (desk and slot tables may hold
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
