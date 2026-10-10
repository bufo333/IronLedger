# Artillery battle effects and atomic engagement resolution

This is the approved IRON LEDGER P2h project design. P2e catalogue facts,
calculated BV and construction price retain their pinned source owners; P2g
operations retain their existing policy. The combat coefficients below are
project adaptations with no asserted MegaMek or MekHQ numerical counterpart.
Battle armor remains deferred beyond 3025, and P2i owns dedicated artillery
panels, parser verbs and TUI controls.

## Research distinction

Public documentation checked on 2026-10-09 provides conceptual inspiration:
[ArtilleryTargetingControl (0.51.01 API)](https://megamek.org/megamek/megamek/client/bot/princess/ArtilleryTargetingControl.html)
describes indirect firing plans and possible area damage;
[ArtilleryAttackAction (0.51.01 API)](https://megamek.org/megamek/megamek/common/actions/ArtilleryAttackAction.html)
records shots in flight, spotters and time to impact.
[The official 0.50.05 release notes](https://megamek.org/2025/04/25/New-Development-Release-0.50.05.html)
provide release context. These sources establish no company-level
salvo count, suppression, exposure or recovery formula. No upstream implementation
was copied; hex targeting, flight time and counter-battery simulation are outside
this adaptation.

## Gameplay policy

### Participation and firing

1. The existing one-formation-per-company cap remains the stacking limit.
   `artillery_battle` selects that company's formation by typed identity. There
   is no Unit surrogate, extra lance, passive `has_artillery` bonus, addition to
   committed/fieldable BV, or change to enemy sizing. A ready battery alone cannot
   prevent the ordinary no-line-units concession. Concession and enemy forfeit
   expend no artillery ammunition, consume no artillery draws and cause no
   artillery damage; an attached formation is recorded with the corresponding
   no-fire reason, without a HullCombatRecord for that non-fight.
2. Physical participation requires player ownership, active hull, company
   attachment to the fighting company, actual presence at the contract planet,
   and no company/freight transit. Resolve actual position through posture/site
   owners, never the supplying HQ. Pool, remote, freight, sold and terminal
   formations provide neither fire nor battle exposure. A queued home-HQ job
   does not teleport a deployed attachment back home: it remains exposed at its
   actual location, although the job blocks firing through existing readiness.
3. Primary firing uses the complete existing `operationalReadiness` unchanged:
   crew, mechanic, condition, fresh maintenance, attachment/locality, job and
   loaded intact Long Tom bin all matter. Each normal engagement with at least
   one engaged ordinary unit and positive enemy power permits exactly one
   automatic salvo. A salvo expends **one loaded Long Tom round**, hit or miss,
   from the first intact nonempty Long Tom bin in canonical slot order. It never
   consumes a sealed supply package, reloads implicitly, or touches remote stock.
4. Use the gunner's present `gunnery_vee` value, plus the existing permanent-injury
   and fatigue penalties, less the existing gunnery-specialist adjustment, with
   saturating lower bound zero. The firing target is
   `clamp(effective_gunnery + 4 - recon_quality, 2, 12)`. Roll 2d6 from the staged
   `.battle` stream; meeting the target hits. Recon is the existing company's
   computed recon value. No additional terrain/weather/commander modifier or
   invented artillery skill is introduced. The commander and loader are required
   seats with no separate numerical bonus.
5. On a hit, calculate carrier effective power with the existing
   `autoresolve.Element.effectivePower`: pinned carrier BV, effective gunner skill,
   effective driver `driving_vee` with the existing piloting-specialist adjustment,
   current armor percentage and quality; use otherwise-neutral CampaignMods with
   the floor-averaged fatigue and morale of the four operating crew. The reduction
   is `min(floor(enemy_power_before / 4), floor(carrier_effective_power / 4))`.
   A miss reduces nothing. Subtract this once before the existing ratio bonus and
   opposed roll. Integer division rounds down; all intermediate arithmetic is
   checked/widened, and reduction cannot make enemy power negative.
6. This is **temporary pre-round power attrition**, recorded as suppressed power.
   It is not an independently destroyed hull/BV award. Existing outcome owners
   alone determine permanent enemy casualties, attrition-pool depletion, salvage,
   prisoners, score and kill credit. Do not subtract the reduction from enemy
   pools or count it again as destroyed BV. This keeps the real-pool and abstract
   opposition paths consistent without inventing partial enemy hull condition.
   Preview is pure: expose eligible/target/maximum reduction through the owning
   battle estimate result; existing odds continue to describe the unsuppressed
   opposition unless the view explicitly labels the maximum possible reduction.

### Carrier exposure, ammunition and damage

7. Each physically participating carrier is exposed even if it cannot fire.
   Use the ordinary opening's final hit percentage after ROE and reserve effects;
   extract that value from its existing owner rather than recalculate it.
   Base carrier hit probability is `clamp(floor(hit_pct / 2), 0, 100)` percent,
   at most one carrier hit per engagement. This is rear-area exposure, not
   modeled enemy artillery or a counter-battery capability.
8. Defensive MG fire is distinct from Long Tom readiness. It requires the same
   physically present active carrier, positive armor, intact chassis, four
   qualified available fit local operating crew, available local mechanic,
   maintenance within the existing 14-day window, and no depot job; it does not
   require the main gun, communications or Long Tom ammunition. It additionally
   requires at least one intact MG and an intact loaded MG bin. Refactor common
   readiness prerequisites in `artillery_operations` so both complete predicates
   share their owner without altering primary readiness.
   If base exposure probability is positive, fire one loaded MG round per intact
   MG in canonical mount order, stopping when the bin empties (at most four).
   Each fired round subtracts **one percentage point** from exposure, floored at
   zero. No MG round is spent when base exposure is zero. MG fire never increases
   opening power or consumes ordinary `ammo_mg` warehouse stock.
9. When resulting exposure is positive, make one uniform 0..99 draw and hit if
   it is below the percentage. When zero, make no exposure draw. On a hit, use
   the existing 2d6 severity, armor-per-severity, slot-hit and kill thresholds.
   Apply armor loss once. For a slot hit choose uniformly among all canonical
   artillery slots; intact becomes damaged, damaged becomes destroyed, and
   destroyed/missing stays as it is. Destroyed/missing ammo bins contain zero
   rounds; report lost rounds separately from fired rounds. Use the same named
   slot-deterioration owner for artillery maintenance damage and battle damage.
10. A kill-threshold result, an armorless kill-threshold result, or destruction
    of the chassis leaves a **recoverable wreck**: armor zero, chassis destroyed,
    same formation/hull/placement, firing disabled, ordinary P2g depot and field
    repair rules apply. A struck loaded ammo bin at the existing cookoff severity
    produces an irrecoverable wreck. Empty bins cannot cook off. All surviving
    loaded rounds are lost on irrecoverable destruction or scuttling. There is
    no new catastrophe roll or change to ordinary Unit wreck rules.
11. On a carrier hit, choose one present on-books operating-seat occupant
    uniformly in canonical seat order; absent/empty seats are not candidates.
    Apply the existing battle crew-casualty rule (severity, MASH, toughness,
    wound follow-up, medical injury and KIA) through one extracted shared owner,
    using the actual PersonId. The mechanic is not an operating casualty target.
    If no eligible occupant is present, consume no crew-choice draw. Capture
    names and seat identities before references can be cleared. Medical draws
    stay in `.medical`; departure clears cross-asset references normally.

### Recovery, terminal history, rewards and accounting

12. A recoverable carrier wreck is retained automatically on a held field. On a
    lost field it makes one existing recovery roll with the same scenario, ROE,
    difficulty, task, salvage-lance and DropShip context; extract the shared
    situation owner. Truck sufficiency counts ordinary wrecks plus the carrier
    wreck, so the same truck cannot be treated as sufficient for each population
    independently. Add no new recovery bonus. An unwrecked carrier retreats
    intact. Driver skill remains an input to effective power; recovery uses the
    existing shared situation formula, not an extra driver bonus.
13. Failed carrier recovery means the crew scuttles it; there is no artillery
    held-hull surrogate, enemy market listing, artillery salvage candidate or
    later carrier recovery raid. On lost-field destruction/scuttling, each
    surviving present operating crew member makes the existing vehicle-crew
    escape roll in seat order, including the ordinary role-skill fallback when
    that individual lacks a driving skill. A failed escape uses ordinary MIA,
    faction custody and missing-person decision owners. Crew evacuation does not
    restore a destroyed carrier. KIA people are not processed twice.
14. Add terminal `Placement.destroyed` to distinguish permanent destruction from
    sold history. Terminal disposal retains formation, hull, acquisition facts,
    final condition and normalized crew/slot rows; clears all operating and tech
    references, sets armor to zero and chassis destroyed, zeroes magazines, removes
    any artillery depot job, and delegates physical terminal status/owner and
    closing the nullable ownership interval to the existing hull lifecycle owner.
    No new ownership interval opens for destruction. Day zero remains valid.
    Historical records refer to the same permanent typed IDs, which are never
    reused. It frees the attachment cap and excludes upkeep, consumables, supply,
    service, manning, lift, resale and credit value. The surviving people remain
    on their normal company books. Active recoverable wrecks remain carried assets.
15. Record one HullCombatRecord per physically participating carrier in a real
    fight, with zero directly credited kills and its own damage summary. Permit
    artillery references in that history only through a matching typed artillery
    report. Its destroyed flag is true for a newly wrecked or terminal carrier,
    false otherwise; cause is cored for structural wrecking, ammo for cookoff,
    scrap for scuttling, and none without wrecking. These are project mappings
    to existing WreckCause identities. Continue rejecting artillery from Unit,
    held-hull, ordinary market,
    faction/merc rosters and salvage-candidate paths. Do not interpret a player's
    zero-kill record as an enemy-pool exclusion outside the existing pool filter.
16. When a salvo fires, each surviving on-books operating crew member present at
    the start receives one battle count and the existing fought/scored XP award
    through Person.xpGain, followed by the ordinary award owner. No duplicate
    pilot kill assignment and no free gunner kills. Company morale/fatigue is
    already applied to those people and must not be applied again. Techs get no
    operating battle XP. With no salvo they receive no extra artillery battle/XP
    award (ordinary company-wide effects still apply).
17. Carrier damage valuation uses existing severity damage value plus half the
    paid price for a newly wrecked carrier, and the remaining half when that
    carrier becomes terminal; cap this carrier's compensation basis at its paid
    price for this engagement. A previously recoverable wreck receives only new
    incremental damage/terminal-loss value, never another half-price wreck award.
    Add the result once to the battle-loss basis and use the existing contract
    percentage/posting owner. Wounded, KIA, newly wrecked and lost-carrier totals
    join campaign/contract/report totals once; typed carrier detail stays outside
    Unit-only HullHit rows. No refund of fired/lost ammunition or canceled-job cost.

All new constants (one salvo round, target offset/bounds, quarter-power factors,
half exposure, percent scale and one-point MG reduction) have one named owner in
`domain/artillery_combat.zig`, with units and citations to the new project design.
Reuse existing thresholds, catalog BV, costs and skill adjustments by calling
owners. Do not copy existing tuning values into a second rule table.

## Atomic engagement architecture

Engagement resolution computes RNG, Unit and crew hits, salvage, postings, AAR,
contract completion, decisions and combat history against isolated storage.
Failure at any of those stages discards the whole uncommitted engagement.
Focused subsystem tests complement full-engagement allocation-failure sweeps.

The **engagement-specific prepared workspace** follows the project's
existing ServiceBatch preparation principle, with these responsibilities:

- `battle_preparation.zig`: owns the engagement work unit, staged streams,
  preparation lifecycle, complete commit preparation and infallible publication.
- `battle_prepared_storage.zig`: explicit typed cloning/promotion helpers for the
  battle mutation footprint, including nested containers and owned strings.
  It is not a reflection-based universal GameState transaction/serializer.
- `battle.zig`: remains the public scheduling/estimate facade and existing rule
  orchestrator. Resolve the existing pipeline against the isolated workspace,
  not live campaign storage; artillery-specific logic stays in artillery_battle.
  Extract casualty/recovery helpers by responsibility only as required for shared
  conventional/artillery rules. Do not move unrelated tests to disguise size.

Use reclaimable operation storage from `gs.scratch()`. Copy every object that a
callee can mutate, including nested containers, before invoking that callee.
Read-only borrowing is allowed only when proven immutable for the whole operation;
a shallow GameState copy by itself is insufficient. Do not let temporary views
free, replace, reserve or mutate the campaign's lifecycle arenas or borrowed maps.
The concrete footprint to audit and cover includes:

- RNG state for every used stream, battle/person/unit/hull/listing/event IDs and
  any other changed counters; stats, outfit/company/HQ balances, reputation and
  faction standing; derived HQ staffing touched by personnel departure.
- People (skills for newly hired prisoners, injuries, awards, names and scalar
  career/status/location fields), ordinary Units and part slots, held hulls,
  artillery formations, forces and their membership/stock/travel/rotation data,
  HQ stock and staffing, outfit stock, supply deliveries and unit transfers.
- The resolving contract and mutable operation/task/intervention collections;
  completion, objective pool/VP, shares/tours and posture effects; next contact.
- Event queue including next event identity, event memory if a called owner
  changes it, report journal, battle IDs, retained structured reports and all
  nested names/hits/ammo/tasks/salvage/artillery payloads, event log and ledger.
- Physical hulls/loadouts, ownership intervals, combat/maintenance history,
  faction and merc-company roster lists, enemy-wreck market listings and listing
  identity, and bay jobs affected by terminal disposal.
- Existing automatic same-night field repair, medical treatment/awards, casualty
  departure, prisoner hiring and decisions, salvage shipment/creation, captured
  player hulls, contract completion and enemy-wreck recovery/dispersal. Retain
  the real subsystem owners; stage their effects rather than reimplement them.

Before publication, promote every retained staged payload into campaign-owned
storage and reserve every destination, ID and log/ledger/report capacity. Resolve
all lookups and check arithmetic before the first gameplay mutation. The final
commit has no allocation, formatting, fallible lookup, rule evaluation or RNG draw.
It publishes the already-computed scalars, mutations, arrays, IDs and stream states.
No report, casualty, ammo change, pool removal, score or next-contact update can
appear alone. Copy-on-prepare/promotion failures discard staged state and leave the
complete gameplay digest unchanged. Persistent allocation capacity is not gameplay,
but scratch is reclaimed; do not retain a whole campaign clone per engagement.

Public direct resolution commits one complete engagement. `runDaily` additionally
stages the existing nextBattleGap draw and next_battle_day assignment in the same
per-contract work unit; initial scheduling is also atomic. Preserve successful
iteration/draw order. Earlier completed contracts in that phase may remain committed
if a later contract fails: their scheduled next date makes same-day phase re-entry
skip them, and the failed contract retries from identical RNG/state. Cover this
explicitly in tests. This defines the battle phase's rule-17 retry unit; it does
not claim to redesign earlier daily phases or the entire multi-day command.
Keep public signatures and callers stable where possible; when a commit could
invalidate a pointer/iterator, retain typed IDs and re-resolve before continuing.

Concede and forfeit use the same atomic boundary, including operation resolution,
score, log/report and contract-completion paths. The direct API retains its
existing scheduling semantics; only the daily entry point includes rescheduling.
No artillery means the existing draws, selection order, outcomes and side effects
must match the base. New artillery draws occur in this documented order: salvo
accuracy after scenario/enemy power preparation but before opposed roll; after the
ordinary hit pass, MG spending, exposure, severity, slot choice, crew choice and
shared casualty draws; after ordinary recovery, carrier recovery/crew escape in
seat order. No new stream or salt is added. Medical/market suboperations retain
their established streams. No RNG is consumed merely to compute a preview.

## Records, persistence and existing-view boundary

Add a typed optional artillery result to BattleReport. It is present exactly when
the fighting company had an attached formation at engagement entry, including a
nonparticipating attachment or concession/forfeit; otherwise it is absent. Capture
a physical-participation flag separately from firing readiness. Use explicit outcomes for
not present/no fire, hit/miss, no hit/damaged/recoverable/permanently destroyed/
scuttled/recovered. Capture formation/hull IDs, catalogue display copy, readiness
reason, participating crew IDs/seat/name snapshots, fired and lost rounds by
family, ammunition before/after, target/roll, enemy power before/reduction/after,
exposure probability/roll, armor before/after, slot changes, crew outcomes,
recovery/escape rolls, XP participation and compensation basis. Fields irrelevant
to an outcome are nullable/absent, not sentinel values that fabricate a roll.
A fixed canonical slot snapshot and fixed four-seat snapshot may be used to keep
this bounded. Report storage is immutable history except existing acknowledgment/
salvage choices; later repair, reassignment, sale or destruction cannot rewrite it.
No new formation/person/slot/seat allocator is needed.

Bump supported store and campaign format from **62 to 63**. Only empty databases
initialize current schema 63; nonempty older stores/campaigns, including 62, are
refused before mutation, and future formats retain distinct refusals. No migration,
backfill, reseeding, reset, replacement save or legacy-row default is authorized.
Update only current-boundary declarations/tests/docs; do not clean up dormant
historical migrations. P2g operational semantics survive unchanged.

The store facade retains its sole transaction/adoption authority. Extend current
artillery placement constraints/decoding for terminal history. Use a dedicated
`persist/artillery_battle_store.zig` encoder/decoder within that transaction for
normalized report parent, slot and seat rows. Executable DDL remains owned by
store.zig; include all new tables/indexes in its required-structure and clear/
delete/overwrite registries and parity checks. Battle-report parent rows carry
an explicit required artillery-presence marker so deleting the child result is
corruption, not absence. Each present result requires exactly the canonical slot
and seat row set, even with empty seats. Absence requires no children.

Classify all new report payload and terminal formation fields as persisted;
operational eligibility/quotes/power previews are derived; the prepared workspace
and publication payloads are operation scratch. Existing reflection digest must
cover the new fields, with explicit perturbation tests. Validate original SQLite
storage classes, full TEXT enum bytes (including NUL suffixes), checked integer
ranges, known catalogue/seat/slot identities, canonical row counts, uniqueness,
nullable-state consistency, parents and every typed-ID counter. Historical crew
IDs may name departed retained people; current seats must obey P2g occupancy.
Validate report arithmetic and ammo accounting using captured values, not current
live condition. Report/hull-history references must agree; accept artillery combat
records only for the matching artillery report identity. Terminal history requires
owner destroyed/status permanently_destroyed, closed provenance, zero rounds,
empty seats/tech and no job; recoverable active wrecks remain valid current saves.

`after_action.render` adds ordinary plain-text artillery lines. Existing
`queries.afterAction` and `queries.battleReport` expose the same persisted result
in their existing panes/flat presentation, including rounds rather than tons and
unavailable/no-fire reasons. Use shared formatting and escaped captured names.
Add no new panel, menu, key, picker, parser verb, command or dedicated artillery
management surface. This is existing-AAR truthfulness within P2h; P2i remains the
owner of dedicated REPL/TUI/query controls. Existing power estimates must not
silently promise a successful salvo.

## Ownership and persistence classification

`domain/artillery_combat` owns the pure formulas and result enums;
`domain/artillery_operations` owns canonical slot deterioration.
`sim/artillery_operations` owns complete primary and defensive readiness;
`sim/artillery_battle` orchestrates snapshots, firing, exposure, recovery, rewards
and zero-kill hull history. `battle_casualties` and `battle_recovery` share the
existing conventional rules. `battle` keeps scheduling, estimates and orchestration.
`battle_preparation` owns the per-engagement workspace; `battle_prepared_storage`
owns explicit isolation and promotion. They do not serialize campaigns or provide
a general transaction framework. `persist/store` retains DDL, adoption and
transaction authority; `persist/artillery_battle_store` owns the normalized codec.

The optional artillery report and all its fixed seat/slot snapshots are persisted
inside the existing persisted battle journal. Terminal placement is persisted
inside the existing formation map. The reflection digest covers both recursively.
Eligibility, readiness and power previews are derived. Workspace containers,
promotion payloads and staged streams are operation scratch. Successful
non-artillery reference hashes exclude only the new optional report field when
comparing against the pre-P2h representation; the full current digest still covers
that field, every named stream and every identity counter.
