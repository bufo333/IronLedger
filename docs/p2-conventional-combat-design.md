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

The implementation re-encodes facts from MegaMek mm-data; it does not copy its
`.blk` files. A candidate must declare `year <= 3025` in its source file.
Source directory names and TRO publication dates do not replace that test.

The initial catalogue is limited to these verified candidates:

| Asset | MegaMek path | Year |
|---|---|---:|
| Scorpion Light Tank | `data/mekfiles/vehicles/3039u/Scorpion Light Tank.blk` | 2807 |
| Manticore Heavy Tank | `data/mekfiles/vehicles/3039u/Manticore Heavy Tank.blk` | 2575 |
| SRM Carrier | `data/mekfiles/vehicles/3039u/SRM Carrier.blk` | 2470 |
| Thrush TR-7 | `data/mekfiles/fighters/TRO3039u/Thrush TR-7.blk` | 2798 |
| Sparrowhawk SPR-H5 | `data/mekfiles/fighters/TRO3039u/Sparrowhawk SPR-H5.blk` | 2520 |
| Slayer SL-15 | `data/mekfiles/fighters/TRO3039u/Slayer SL-15.blk` | 2770 |

P2a corrects their represented kind, tonnage, intro year, and loadout facts.
Existing chassis keys remain stable for saved campaigns even when a source file
has no model field. Each entry gains source-path provenance. BV, cost, rarity,
repair duration, and salvage values remain sourced separately or explicitly
`// TUNE`.

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

The ordered armor arrays in vehicle/fighter `.blk` files are not imported until
their location mapping is verified from MegaMek format authority. P2 therefore
does not infer per-location conventional armor. Aerospace field armor repair is
also deferred until that verified repair model exists.

## NPC Policy

NPC companies prefer mechs. A single named procurement selector first seeks an
affordable available mech; when none is available or affordable, it may buy an
available vehicle or fighter to fill an open combat-lance slot. Conventional
assets may also be stockpiled because their market supply is replenishing.

The later NPC economy increment owns the 16-mek readiness target. Vehicles and
fighters are reserve assets: they contribute their normal battle value when
committed but do not consume that preferred mek target. NPC combat, loss,
repair, salvage, and persistence call the same P2 rule owners as the player.

## Delivery Order

1. **P2a Data and provenance.** Correct verified initial chassis facts; add
   source-path provenance and data validation.
2. **P2b Replenishing market and player vehicle parity.** Add the named market
   owner, unique acquisition identity, vehicle readiness/repair/battle/salvage
   tests, and persistence round trips.
3. **P2c Aerospace combat parity.** Add fighter battle, damage, ammunition,
   salvage, AAR, and aerospace-repair behavior after verified repair facts.
4. **P2d NPC conventional procurement.** Add mech-first substitution and
   replenishing conventional reserves to the NPC lifecycle without changing the
   later 16-mek readiness target.

Every increment must preserve failure atomicity across listings, funds, units,
HullInstances, ownership history, RNG, logs, and persistence rows.
