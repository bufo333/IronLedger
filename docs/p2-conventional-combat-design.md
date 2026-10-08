# P2 Conventional Vehicles and Aerospace Design Approval

**Status:** Approved design. This document defines the P2 delivery order; it
does not add chassis, schema, or simulation behavior.

## Scope

P2 completes conventional combat vehicles and aerospace fighters as physical
campaign assets. Each purchased asset is a unique `HullInstance` with the same
ownership, provenance, destruction, salvage, and persistence rules as a mek.
They are Lab-less: P2 adds no MekLab construction or refit path.

The finite faction-manufacturing rule remains mek-only. Conventional vehicles
and aerospace fighters use replenishing market supply and are never constrained
by a faction roster or manufacturing rate.

## Source Policy

The implementation re-encodes facts from MegaMek mm-data revision
`2a62993f8da306f489116233d489d1f6222945e3`; it does not copy its `.blk`
files. A candidate must declare `year <= 3025` in its source file. Source
directory names and TRO publication dates do not replace that test.

The initial replenishing-market catalogue is limited to these verified
candidates:

| Asset | MegaMek path | Year |
|---|---|---:|
| Scorpion Light Tank | `data/mekfiles/vehicles/3039u/Scorpion Light Tank.blk` | 2807 |
| Manticore Heavy Tank | `data/mekfiles/vehicles/3039u/Manticore Heavy Tank.blk` | 2575 |
| SRM Carrier | `data/mekfiles/vehicles/3039u/SRM Carrier.blk` | 2470 |
| Thrush TR-7 | `data/mekfiles/fighters/TRO3039u/Thrush TR-7.blk` | 2798 |
| Sparrowhawk SPR-H5 | `data/mekfiles/fighters/TRO3039u/Sparrowhawk SPR-H5.blk` | 2520 |
| Slayer SL-15 | `data/mekfiles/fighters/TRO3039u/Slayer SL-15.blk` | 2770 |

P2v-a replaces the static facts for these entries: represented kind, tonnage,
intro year, and loadout. It also audits every remaining current conventional
catalogue entry before that entry becomes market-eligible. Every market entry
records its source path and the pinned revision. BV, cost, rarity, repair
duration, and salvage values remain sourced separately or explicitly `// TUNE`.

The game is unreleased and has no saved campaigns. P2v-a therefore provides no
legacy campaign migration: it replaces the static catalogue directly, and does
not preserve obsolete live loadouts or hull-instance snapshots.

## Ownership And Markets

`GameState.recordHullAcquisition`, ownership-history writers, market purchase,
salvage, destruction, and persistence remain the only P2 ownership path.
Every market purchase mints a distinct player-owned `HullInstance`; finite
faction/merc roster market listings continue to transfer their existing
instance instead.

One named conventional-market owner generates replenishing vehicle and fighter
offers from the verified catalogue. It does not read or consume faction
manufacturing throughput. Availability, price, condition, purchase, and local
delivery use the existing market rule owners.

## Readiness, Repair, And Battle

Vehicles retain existing `vehicle_crew` / `tech_mechanic` mapping; fighters
retain `aero_pilot` / `tech_aero`. Their existing maintenance-hour and generic
destruction/salvage paths are extended through their current owners rather than
parallel systems.

P2b makes vehicle combat, ammo, damage, crew outcome, salvage, and AAR coverage
explicitly parity-tested. P2c gives fighters direct battle participation,
including BV, ammunition, losses, crew outcomes, salvage, and AAR records;
air-cover remains a separate environmental modifier and grounded aircraft do
not contribute.

MegaMek mm-data revision `2a62993f8da306f489116233d489d1f6222945e3`
authorizes the following static aerospace armor arrays for the approved fighter
catalogue entries:

| Asset | MegaMek path | Armor array |
|---|---|---|
| Thrush TR-7 | `data/mekfiles/fighters/TRO3039u/Thrush TR-7.blk` | `7, 6, 6, 5` |
| Sparrowhawk SPR-H5 | `data/mekfiles/fighters/TRO3039u/Sparrowhawk SPR-H5.blk` | `38, 24, 24, 34` |
| Slayer SL-15 | `data/mekfiles/fighters/TRO3039u/Slayer SL-15.blk` | `84, 50, 50, 48` |

MegaMek `BLKAeroSpaceFighterFile.java` commit
`16a45e09583d0832938d7f80163994f16329f35f` is the format authority: its
required four-value `<armor>` array maps index `0` to nose, index `1` to right
wing, index `2` to left wing, and index `3` to aft. This authorization is
limited to static fighter catalogue data. It does not authorize live
per-location armor state, source-point conversion to `Unit.armor_pct`, armor
tonnage, repair cost, repair duration, or another repair rule.

Fighters use generic field armor and field-tier slot repair through `tech_aero`;
internal structure remains depot work. This aerospace-specific mapping does not
establish a conventional-vehicle armor-array mapping or authorize importing
vehicle armor locations.

## NPC Policy

NPC procurement uses a single named selector per eligible force slot. For an
open line lance, it first seeks an affordable available mek and then falls back
to a vehicle. Aerospace fighters are eligible only for open air-lance slots;
they never occupy a line lance. Conventional assets may also be stockpiled
because their market supply is replenishing.

The later NPC economy increment owns the 16-mek readiness target. Vehicles and
fighters are reserve assets: they contribute their normal battle value when
committed but do not consume that preferred mek target. NPC combat, loss,
repair, salvage, and persistence call the same P2 rule owners as the player.

## Delivery Order

1. **P2v-a Data and provenance.** Replace verified chassis facts; audit every
   conventional entry before market use; add pinned source provenance and data
   validation.
2. **P2v-b Replenishing market and player vehicle parity.** Add the named market
   owner, unique acquisition identity, vehicle readiness/repair/battle/salvage
   tests, and persistence round trips.
3. **P2v-c Aerospace combat parity.** Add fighter battle, damage, ammunition,
   salvage, AAR, and aerospace-repair behavior after verified repair facts.
4. **P2v-d NPC conventional procurement.** Add mek-first vehicle substitution
   for line lances and aerospace procurement for air lances, plus replenishing
   conventional reserves, without changing the later 16-mek readiness target.

Every increment must preserve failure atomicity across listings, funds, units,
HullInstances, ownership history, RNG, logs, and persistence rows.
