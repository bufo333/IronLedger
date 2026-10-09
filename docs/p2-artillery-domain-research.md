# P2e Artillery Domain Research

## Scope

P2e records source-backed construction facts and pure calculated BV/cost for
the Mobile Long Tom LT-MOB-25. It creates no campaign asset, availability,
market, acquisition, attachment, crew, maintenance, ammunition, supply,
battle, persistence, command, query, or UI behavior.

## Authorities

- mm-data `2a62993f8da306f489116233d489d1f6222945e3`,
  `data/mekfiles/vehicles/3039u/Mobile Long Tom LT-MOB-25.blk`: identity,
  75 tons, tracked movement, cruise MP 3, ICE engine, armor and loadout.
- MegaMek `4d747103e1cf6d632be8dd50e0ed8b0d804b3311`,
  `CombatVehicleBVCalculator.java` and `BVCalculator.java`: the supported
  conventional-vehicle BV calculation.
- MegaMek `6b8fcf623397e9f4d2f95ad83aa871fc65ab177b`,
  `CombatVehicleCostCalculator.java`: non-support vehicle cost calculation
  and `BigDecimal.setScale(2, RoundingMode.UP)`.
- The same MegaMek revision's `LongTom.java`, `ISMG.java`, `Engine.java`, and
  `ArmorType.java`: re-encoded equipment, engine, and armor constants.

The upstream records are locators only; project data and formulas are original
re-encodings.

## Integer Money Boundary

MegaMek first rounds its calculated vehicle cost upward to whole cents. The
LT-MOB-25 result is `177,931,250` cents (`1,779,312.50` C-bills). Project
money remains integer `types.CBills`, so
`ceilMegaMekCostCentsToCBills` is the one conversion owner and returns
`1,779,313` C-bills. Cents are calculator-local arithmetic only: they are not
a project money type, catalogue price field, ledger balance, query value, or
persisted representation.

## Deferred Boundaries

The BLK supports calculation of this carrier but does not define this game's
availability, market policy, asset topology, crew, technician responsibility,
formation size, transport, lifecycle, destruction, salvage, recovery, supply,
