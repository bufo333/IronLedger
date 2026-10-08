# P2 Battle-Armor Era Deferral Record

## Status

The campaign era is 3025. The owner decision is that Inner Sphere battle armor
is unavailable in that era, so P2b through P2d are deferred until an explicitly
approved campaign-era expansion beyond 3025. P2a,
`docs/p2-battle-armor-artillery-design.md`, remains the governing approval:
source facts must be verified and then re-encoded, never copied from source
data. This era gate authorizes no candidate, data, domain code, persistence
work, schema, acquisition, attachment, crewing, readiness, repair, supply,
battle behavior, UI, test, or migration work.

## Inspected locators

- MegaMek mm-data revision
  [`2a62993f8da306f489116233d489d1f6222945e3`](https://github.com/MegaMek/mm-data/tree/2a62993f8da306f489116233d489d1f6222945e3).
  Its inspected file header states CC BY-NC-SA 4.0.
- Rhino `(Sqd5)` file:
  [`data/mekfiles/battlearmor/Golden%20Century/Rhino%20BA%20%28Sqd5%29.blk`](https://github.com/MegaMek/mm-data/blob/2a62993f8da306f489116233d489d1f6222945e3/data/mekfiles/battlearmor/Golden%20Century/Rhino%20BA%20%28Sqd5%29.blk).
- Elemental 3060 ER-micro-laser `(Sqd5)` file:
  [`data/mekfiles/battlearmor/3058Uu/Elemental%20BA%20%5BER%20Laser%5D%20%28Sqd5%29.blk`](https://github.com/MegaMek/mm-data/blob/2a62993f8da306f489116233d489d1f6222945e3/data/mekfiles/battlearmor/3058Uu/Elemental%20BA%20%5BER%20Laser%5D%20%28Sqd5%29.blk).
- MegaMek battle-armor loader:
  [`BLKBattleArmorFile.java`](https://github.com/MegaMek/megamek/blob/30e52c534b401422513249d36e2a71eb69c08c42/megamek/src/megamek/common/loaders/BLKBattleArmorFile.java).
- Sarna permanent revisions already inspected:
  [Rhino](https://www.sarna.net/wiki/index.php?title=Rhino_(Battle_Armor)&oldid=1424384)
  and
  [Elemental](https://www.sarna.net/wiki/index.php?title=Elemental_(Battle_Armor)&oldid=1402125).

## Directly Verified Observations

The mm-data revision and its inspected files are source-defined material under
the stated CC BY-NC-SA 4.0 header. The Rhino and Elemental files are locators
for the named battle-armor configurations; they are not a project catalogue.
The inspected Elemental file identifies a 3060 ER-micro-laser `(Sqd5)`
configuration.

The inspected MegaMek loader requires a trooper count, saves it as squad size,
and loads equipment by point and trooper location. The inspected
[3058Uu](https://github.com/MegaMek/mm-data/tree/2a62993f8da306f489116233d489d1f6222945e3/data/mekfiles/battlearmor/3058Uu)
and
[Golden Century](https://github.com/MegaMek/mm-data/tree/2a62993f8da306f489116233d489d1f6222945e3/data/mekfiles/battlearmor/Golden%20Century)
directories include Sqd4, Sqd5, and Sqd6 file labels. That is evidence against
inferring a universal lance size or a one-person representation. It is not an
approved game formation size, capacity, attachment, or transport rule.

The current project model has one `pilot` and one `tech` on `Unit`. This does
not fit the loader observation without an identity decision. The mismatch must
be resolved by a later approved, source-backed identity decision; it is not
authority to introduce a replacement entity.

The permanent Sarna revisions are source locators only in this blocker record.
No project policy is derived from them.

## Project Decisions

The owner decision is that the game is pre-release and has no released
campaigns. Future battle-armor schema or state work requires neither a
migration nor a compatibility path. It must still persist every
gameplay-relevant field in a fresh save, reject incomplete or malformed saves,
and prove deterministic save/load and continued evolution from that fresh-save
state.

This is project policy, not a source-defined battle-armor fact.

## Historical Observations And Deferred Facts

Rhino and Elemental remain previously inspected historical observations and
locators, not active 3025 catalogue candidates. The model-mismatch observations
and unresolved P2a-required facts are not actionable while the era gate is
closed. For a later eligible candidate, research must establish:

- Exact configuration, BV, C-bill cost, availability policy, and actual later
  introduction date.
- Complete loadout and ammunition representation, and transport or bay
  requirements.
- Crew and technician responsibility.
- Repair, reload, destruction, salvage, and recovery behavior.
- Battle behavior.

No existing `.ba_trooper`, `.tech_ba`, `UnitKind.battle_armor`, or tuning value
verifies any required fact above.

## Era-Expansion Prerequisite

Before the battle-armor track can resume, an approved campaign-era expansion
past 3025 must source and pin MegaMek GitHub records for each proposed
candidate's actual later introduction date. It must then complete the full
P2a-required candidate research. A separately approved implementation plan is
required before any domain, data, or persistence implementation begins.
