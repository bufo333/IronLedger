# Artillery operations

These policies are IRON LEDGER project adaptations. They do not claim an
external crew complement, ammunition capacity, reload unit or repair material.
Physical LT-MOB-25 construction, identity, era, calculated BV and price remain
owned by the pinned P2e catalogue. Campaign maintenance, medical, payroll,
procurement and transport formulas retain their existing owners.

[Artillery battle effects](p2-artillery-battle-design.md) deliver P2h firing
expenditure, carrier damage, recovery/disposal and existing AAR participation. Dedicated artillery panels, parser verbs and TUI controls belong to
P2i. Existing personnel, assignment and shared bay views expose artillery
references through typed owners within P2g. Battle armor remains deferred beyond the current 3025 era.

## Crew and personnel policy

- One carrier has four distinct operating seats, in fixed order: `commander`,
  `gunner`, `driver`, `loader`. Each references one ordinary `PersonId` with
  primary role `vehicle_crew`. This is a four-person game abstraction; extra
  communications staff, historical battery complement and a dedicated
  artillery skill are not claimed or introduced.
- The driver requires a present `driving_vee` skill. The other seats require
  a present `gunnery_vee` skill. There is no new numerical qualification
  cutoff; absent skill is untrained and cannot fill that seat. These selections
  have one domain owner. Qualification does not depend on assumed default 7.
  Future combat receives the gunner's gunnery and driver's driving values;
  this branch adds no combat multiplier, commander bonus or loader bonus.
- Assignment requires `Person.isAvailable(today)` and `!Person.isUnfit()`,
  the required role/skill, and actual local presence. Wounds, training, leave,
  captivity or absence fail availability through existing personnel owners.
  Lower skill remains better. Salary, rank, XP, fatigue, morale, provisions,
  medical care, shares and departure payment remain ordinary Person behavior;
  count/pay/feed each person once. There is no formation wage surcharge.
- Operating seats exist only while company-attached. The candidate belongs to
  that company, or is wholly unassigned at that company's actual home HQ
  while it is home. Assignment sets `assigned_force` to the company. People
  from another company or a remote HQ are never silently moved.
- A person occupies at most one operating seat across artillery and ordinary
  Unit pilots. Reject an already seated person; require explicit unassignment
  before reassignment. Ordinary pilot-assignment/TO&E paths must enforce the
  same cross-asset occupancy rule. Operating crew cannot double as techs.
- One separately assigned `tech_mechanic` with present `tech_mechanic` skill
  serves the carrier. The technician may share ordinary vehicles and other
  artillery at the same actual site, subject to one shared workload. Company
  attachment requires its own company's mechanic (or an eligible unassigned
  mechanic joining it at home). A pooled carrier may use a mechanic posted
  to that exact HQ, unassigned at that HQ, or with a company physically home
  there. An HQ posting is not a free remote-work pass.
- Automatic assignment processes artillery by ascending formation ID and
  seats in the order above; choose the best required skill, then lowest
  PersonId. Fill empty seats only; preserve wounded/leave/training occupants.
  Mechanics are chosen by most spare shared hours, then skill, then ID.
  Accident replacement may replace the injured mechanic, with a prepared log.
  Empty, recovering and unavailable seats remain distinguishable to the owner.
- Existing `auto_assign` and `crew_company` behavior includes attached
  artillery. `crew_company` uses the same actual HQ hiring hall, existing
  candidate/signing-bonus and pooled-astech rules. No free generated vehicle
  crew or mechanic appears. The manning table adds four vehicle crew and one
  mechanic per attached carrier plus the existing full-team astech complement
  for that additional mechanic. Four new combat heads feed the existing
  medical/admin ratios. Existing conventional ratios stay unchanged. Hiring
  targets are staffing guidance; a shared mechanic can still operate within
  actual hours. Exclude pooled/freight/sold formations from company demand.
- Depart/fire/retire/resign/post/transfer clears relevant artillery seats
  through the same seat-vacating owner as ordinary hulls. Assignment and
  lifecycle mutations prepare all logs, financial effects and replacements
  before changing references. Changes affecting only availability preserve
  seats and make readiness false. A mechanic or crew member cannot teleport
  away from a deployed/transiting attached carrier through an HQ posting.

## Physical location and complete capabilities

Keep one formation plus one HullInstance, outside Unit and ordinary lance
rosters. Never manufacture a temporary Unit surrogate. Placement remains the
P2f tagged union; attached position derives from company posture.

`operationSite`, `crewEligibility`, `serviceCapability`, `reloadQuote`,
`repairQuote` and `operationalReadiness` own their named capabilities;
queries, commands, ticks and validators consume those answers.

- Pool: actual pool HQ stock and facilities; mechanic-only maintenance,
  reload and repairs are permitted, but no operating seats or firing readiness.
- Attached and physically home: actual home HQ stock/facilities. Attached and
  deployed/idle afield: that company's field stores and local people, never
  the supplying HQ's stock or an unrelated home facility.
- Company transit/return transit or artillery freight: no service, reload,
  repair or readiness. Loaded rounds and condition travel intact; no weekly
  maintenance roll or consumption occurs while in transit. Maintenance age
  continues advancing. No duplicate persisted planet/ETA for company travel.
- Sold: historical condition and magazines retained, no crew/tech references,
  job, maintenance, payroll, supply or readiness contribution.
- Destroyed: permanent typed history, zero armor/magazines, destroyed chassis,
  empty operating seats/tech and no depot job. It contributes no service, carry,
  consumables, supply, manning, lift, resale or liquidation credit. Recoverable
  wrecks remain active carried assets and use existing field/depot repair rules;
  restoring condition never restores ammunition.
- Complete primary-artillery readiness requires a player-owned active hull,
  company attachment physically present outside transit, no queued/active
  depot job, armor above zero, intact chassis, intact Long Tom and communications
  slots, all four qualified available fit crew, a qualified locally available
  assigned mechanic, covered maintenance within the last **14 campaign days**,
  and at least one round in an intact Long Tom bin. Missing maintenance means
  not ready. The MGs and hitch are independent equipment: their failure is
  exposed in condition but does not pretend the primary gun cannot fire.
  This readiness owner is delivered for P2h consumption; it grants no battle
  strength or bonus now and does not change ordinary force readiness.
- Service/reload need the locally available assigned mechanic but do not
  require combat crew, fresh maintenance, loaded ammo, or firing readiness.
  Reload requires no depot job and intact destination bin. Field repair may
  restore a non-operational carrier. Structural repair requires its actual
  regional/brigade HQ and effective bay capability. Thus repair eligibility
  never depends circularly on firing readiness.

## Condition, maintenance, repairs and shared hours

Formations persist quality using `types.Quality`, armor percentage, optional last-covered
maintenance day, a fixed condition per canonical equipment slot, and magazines.
The domain owns a canonical ordered slot descriptor for the chassis plus each individual
pinned catalogue mount, expanding count into stable slots: main gun, each of
four MGs, each of four Long Tom bins, the MG bin, communications and hitch.
All start intact. Slot order is canonical current-format identity; loading rejects any
missing/duplicate/unknown slot. Chassis is structure; weapons, equipment and
ammo bins use existing `SlotClass` and `PartCondition` meanings.

- Reuse `unit.maintenanceHours(.vehicle, catalogue_tons)`, maintenance quality
  and technician-skill multipliers, `Person.weekly_hours`, existing astech
  throughput, `qualityDrift`, target/field/uncovered modifiers, 2d6 and existing
  accident/medical rules through parameterized helpers in the existing
  maintenance owner. Its pure `maintenanceTarget(quality, afield, covered)`
  owns the quality, field and uncovered target for both ordinary units and
  artillery; callers retain skill, RNG and mutation responsibilities. Existing
  constants retain their current owner.
- `techWeeklyLoadHours` includes ordinary hulls and serviceable-location
  artillery. Shared maintenance and field-repair passes each use one HourBook
  across both populations; no second artillery budget. Ordinary maintenance
  keeps its existing iteration order, artillery follows in ascending ID.
  Repairs reserve the combined ordinary/artillery base service load, then
  consume each mechanic's remaining hours across ordinary work followed by
  artillery work. Existing field `repairBudget` subtracts this combined load.
  Astech contribution is computed for the actual company or exact pool HQ;
  never merge unrelated `.none` companies into a global pool team. Apply this
  local team owner to consumers that can share artillery mechanics.
- Weekly maintenance uses staged `.maintenance` RNG after ordinary units.
  No assigned/available mechanic or exhausted hours means an uncovered check,
  not covered service. Covered service sets last-maintenance day and charges
  `purchasePrice()/tuning.maintenance.consumables_divisor`, with the existing
  repair-cost commander multiplier. The monthly consumables estimate includes
  these carriers once; existing vehicle carry cost remains separately once.
- Quality change follows `qualityDrift`. On its existing snake-eyes failure
  condition, select uniformly among canonical non-structure slots in stable
  order and advance `ok→damaged→destroyed`, leaving missing/destroyed unchanged.
  A destroyed ammo bin loses its remaining rounds with a structured loss log;
  a damaged bin retains inaccessible rounds until repaired. Maintenance never
  damages structure or creates a permanently destroyed hull.
- Weekly field repairs use `unit.repairTier`. Damaged equipment consumes the
  existing damaged-slot hours/labor rule, no replacement stock; destroyed or
  missing equipment consumes one matching spare plus destroyed-slot hours/
  labor. MG replacement uses the existing `mg` stock key. The main gun,
  communications, hitch and ammo-bin repairs consume a common
  `artillery_spares` service kit. This kit is an abstract rebuilding material
  unit, not an externally specified replacement weapon or equipment mass.
  Repairing a bin never refills it. Process canonical slot order, then one
  armor patch per weekly pass with existing armor stock, patch percentage,
  hours and labor. Use actual-site batch demand; no duplicate-key overdraw.
- Chassis damage is depot-only. Reuse the heavy vehicle chassis component
  selected through `part.componentForSlotClass` and the verified 75-ton class,
  existing depot duration/labor/repair-result rules, and the actual HQ's bay
  queue. BayJob carries an artillery target and `artillery_depot_repair`
  kind; existing kinds retain Unit semantics. Artillery jobs compete in the
  same queue/slot capacity. Never create parallel free bays.
- Depot work restores the chassis through the existing clean/fault/redo/botch
  model; use generalized repair-check owners instead of a copied table. Fault
  damages one intact non-structure slot; botch additionally drops quality one
  grade bounded at A; redo retains the job and extends time by the existing
  redo rule. Prepare/stage RNG, accident, stock, maintenance-history and logs
  together. A queued job requires a local assigned mechanic; start/completion
  waits without rolling while that mechanic is unavailable or absent. A job
  occupies its existing shared bay while started and waiting. Durable job
  validation checks the live home HQ of its pool or attached company separately
  from actual work capability. Normal departure, deployed or idle-afield posture,
  and return travel preserve the job; unavailable physical service suspends start
  and completion without rolls, charges or condition changes. Bay time is the
  existing separate depot capacity, not a second weekly field-work budget.
- P2g provides and validates chassis/equipment/armor damage state and repair
  paths. It adds no player damage command or battle damage generation. Existing
  field repair-push/AAR participation is P2h; only the shared ordinary push
  budget's maintenance reservation changes now. No mothballing, artillery
  salvage, total destruction or rebuild of a permanently destroyed carrier.

## Ammunition and supply policy

The following capacities and market units are project game abstractions;
P2e proves mount count, not rounds per bin or these supply rules.

| Project policy | Exact value |
|---|---|
| Long Tom capacity | 5 rounds per bin, four bins, total 20 |
| MG capacity | 100 rounds in its one bin |
| `ammo_long_tom` stock unit | sealed 5-round reload; 1 shipping/storage ton; 20,000 C-bills; rarity rare; availability E |
| `ammo_artillery_mg` stock unit | sealed 100-round reload; 1 shipping/storage ton; 500 C-bills; rarity common; availability B |
| `artillery_spares` stock unit | one rebuilding kit; 1 shipping/storage ton; 25,000 C-bills; rarity uncommon; availability D |

All three parts are Inner Sphere, introduced in the catalogue's
verified 2602 year, and `mount=.none` (not MekLab equipment). Their metadata is
project market policy, not a new physical catalogue fact. Their cost literals
live only in their data rows; capacity, crew count, maintenance-age limit and
other new policy values live once as named domain constants. Reuse existing
MG/armor/component costs via `part.cost`, never copy their values.

- Use ordinary sourcing, era checks, local market price modifiers, procurement,
  storage/transport capacity, order arrival and supply-policy owners. No
  guaranteed special artillery market or free procurement. The two ammunition
  packages are explicitly marked as ammunition by one named classification
  owner while remaining non-mountable. Do not add them to the generic
  conventional `munition_keys` loop: doing so would give employer-convoy stock
  and mounts-per-battle semantics without authority. `ammo_artillery_mg` is a
  sealed carrier package; generic `ammo_mg` cannot be converted in P2g.
- Reload a selected family through a pure quote and atomic command. In stable
  bin order, refill every intact **empty** bin, one full package each. Require
  enough local stock for the whole quoted batch or refuse unchanged. Partial
  bins are deliberately left alone: e.g. `[3,0,5,0]` needs two packages and
  becomes `[3,5,5,5]`; no remainder is discarded or minted. A damaged empty bin
  is skipped; if there is no eligible empty bin, refuse `nothing to reload`.
  No partial package, conversion or hidden residue field exists. This exact
  whole-bin rule avoids fractional warehouse inventory. Loaded rounds are
  persistent exact integers and cannot exceed their own bin capacity.
- Reload needs the mechanic, costs no hours or additional labor (architecture
  §9.9), and consumes no RNG. Purchasing stock already bears its cost. No
  automatic free reload, daily ammo drain or firing command is added. P2h
  will own combat expenditure, depletion order and effects in its own plan.
- Field supply adds a reserve floor of **one complete reload** and target of
  **two complete reloads** per attached carrier: Long Tom packages 4/8, MG
  packages 1/2. Derive these from bin count and named reserve-load constants.
  Loaded magazines are not warehouse reserves and do not count toward these
  thresholds. Existing `ammo_battles` affects conventional ammo only until P2h
  defines artillery expenditure; artillery rows are described as reloads.
- Share the existing ammunition percentage of field-storage capacity with
  conventional ammo. The one allocation owner computes all requested tons,
  assigns proportional integer targets, then distributes leftover whole tons
  in stable part-key order without exceeding capacity; floors clamp to the
  resulting targets. If no ammo budget exists, all such targets are zero.
  It never invents a one-package minimum that exceeds the hold. Existing
  shipment/load-out/reorder owners consume these lines. Repair demand includes
  the exact local spare/component/armor shortfall through shared demand owners.

## Acquisition, placement, sale and defaults

- A new purchase initializes intact slots, armor 100%, quality C, all seats
  and tech empty, no last-maintenance day, no job, and every bin empty. The
  construction purchase price and stock offer policy remain unchanged; price
  is not a grant of crew or consumable ammunition.
- Attaching/detaching still requires the P2f physical-home conditions. Attach
  clears any pool mechanic reference before assignment at the new company;
  detach clears all crew and mechanic references, leaving ordinary people on
  their existing company books. No automatic firing, severance or person
  travel. Any queued/active depot job blocks either operation.
- Pool freight requires no crew but no bay job; it clears the mechanic during
  the atomic dispatch. Damage and magazines travel with the carrier. P2f
  catalogue mass, route, ETA, price and vehicle-bay policy remain unchanged;
  onboard ammunition is included in carrier transport, not counted again as
  warehouse cargo. Stored reload packages use their declared shipping tons.
- Sale remains pool-only and refuses a queued/active job. It clears technician
  references, retains operational history in the sold formation and closes
  provenance atomically. No ammo extraction, free stock or separate ammo sale
  proceeds occur. Use the existing shared hull resale owner with actual
  artillery quality and condition: armor percentage, capped at **50%** when
  chassis is non-intact, with the existing pricing semantics. This cap is a
  named project valuation constant; intact C-grade equals P2f price.
  Optional equipment/bin condition does not create another sale discount.
  Liquidation-backed credit calls that same sale-value owner once.
- HQ sale is blocked by pooled/freight carriers and artillery bay jobs through
  existing physical-use checks. Company disband/home reassignment stays
  blocked by attachment. Person bookkeeping is never an alternate location.

## Commands, orchestration and atomicity

Typed commands are `assign_artillery_crew {formation,seat,person}`,
`unassign_artillery_crew {formation,seat}`,
`assign_artillery_tech {formation,person}`,
`unassign_artillery_tech {formation}`,
`reload_artillery {formation,family}` and
`repair_artillery {formation}` (request actual-HQ chassis depot work).
Existing typed auto-assignment/hiring and acquisition/placement commands are reused.
Results return the exact formation/person/site identity and actual loaded-package
counts/job outcome as appropriate. Expected reasons have canonical
`cli.errorText` sentences; this is error presentation only. Dedicated artillery parser verbs, panels and TUI controls remain P2i;
existing personnel, assignment and shared bay views remain truthful within P2g.

`artillery_crew` owns seat/location/exclusivity and assignment preparation;
`artillery_operations` owns capabilities, reloads and condition queries;
`artillery_service` adapts artillery to maintenance/repair/bay work. Existing
maintenance owns formulas, hours, weekly scheduling and accidents; hq_ops owns
shared bay scheduling; artillery owns acquisition/topology; personnel owns
hiring/lifecycle; sites/field_supply own stock movement and supply planning.
State contains storage/primitive access only. Domain modules import no sim.

All new or changed compound operations validate, prepare and commit. Scratch
records hold stock batches, row reservations, copies of affected formation/
person fields, staged streams and owned log/posting payloads. Commit cannot
allocate. Cross-asset assignment/auto-assignment and crew-company hiring must
prepare the entire requested command, including conventional effects, before
mutation; do not append artillery calls after an already-mutating command
that can still fail. Scope includes the necessary bounded preparation split
in crew/personnel/hall hiring owners, not a generic transaction framework.

Weekly artillery maintenance plus its automatic field repairs is prepared
for the entire artillery population from the post-conventional state, in
stable ID order, before committing any artillery item. The weekly entry point
prepares shared ordinary/artillery maintenance and repair allocations in their
stated order; commit the artillery portion only after its full preparation.
The shared HourBooks carry actual ordinary-unit spending/reservations into
artillery preparation; never reset them at the subsystem boundary. Stage
all accident/availability/replacement effects and streams in that pass.
Use one day-stamped persisted artillery service checkpoint so re-entry after
an already-completed artillery pass cannot repeat rolls, stock or charges;
set it only with the completed batch. A refused automatic job is a structured
waiting reason; OOM/invariant failures propagate. Depot completion is atomic
per job; earlier completed jobs may remain committed, with existing removed-job
retry semantics and tests. No unrelated tick retry redesign is authorized.

## Current-format persistence

Save support is governed by
[contract rule 51](engineering-contract.md#51-save-format-support-is-explicit).
The current P2h boundary supports schema **63** for both store and campaign;
version numbering is retained. Store adoption, campaign loading and overwriting
enforce this boundary before decoding or replacing gameplay rows.
Older formats are preserved but refused, with typed `StoreOlderThanGame` or
`SaveOlderThanGame` errors; future versions retain distinct
`StoreNewerThanGame`/`SaveNewerThanGame` refusals. A missing campaign remains
`NoSuchCampaign`.

`cli.errorText` owns the shared old-format refusal sentence: `that save uses an
older unsupported development format; start a new campaign in a new save file`.
Existing error-display paths consume it without a reset, replacement save, new
campaign or parser verb; corruption, system and newer-format errors remain distinct.

Store adoption classifies the database with read-only queries before DDL,
version stamping, rebuilding or any persistent mutation. Only a truly empty
database initializes complete current DDL, indexes and version in one transaction.
A nonempty database with missing setting table or version is refused intact;
version metadata requires one exact integer record with a positive bounded value.
Current opening validates required structures without creating missing tables,
healing rows or resetting versions. FK enforcement precedes supported schema use.
Old migration and campaign-upgrade paths are unreachable through adoption or
load. Historical declarations confer no support; repository-wide removal or
repair of those declarations is outside P2g.

Campaign version is validated before gameplay decoding or upgrades. Overwriting
an existing campaign checks its version before clearing or replacing rows;
failed or unsupported overwrites preserve storage and memory. No automatic
delete, reset, rewrite, backfill, replacement or reseeding is permitted. Explicit
player-owned deletion of supported campaigns retains its existing semantics.
Current saves preserve all gameplay state, identities, counters and named RNG
streams exactly and continue deterministically after load and executable restart.
The seed and exactly one valid format/state row per required named RNG stream
are mandatory; missing current state is corruption, never legacy-blob loading
or fresh-stream fallback. Stable stream salts and sequences are retained.

Retain existing acquisition fields and identities. The artillery representation persists:
quality, armor, nullable last-covered maintenance day, nullable technician;
normalized crew rows keyed by formation+seat; normalized canonical slot rows
with condition and an ammo count only for ammo slots. BayJob carries a nullable artillery
target with the new kind, enforcing mutually exclusive targets for
all job kinds. No additional formation/person/slot ID allocator is needed;
slots/seats have stable enum identity, people use the existing counter.
GameState persists the nullable global last-artillery-service-day checkpoint,
encoded in integer metadata as -1 for absence; day zero is a real checkpoint.

Every formation, including sold history, has exactly the canonical crew and
slot row set; unfilled Person references are SQL NULL, not fabricated IDs.
New tables have campaign/formation/Person FKs, primary/unique keys, enum,
integer-type and range checks; fresh schema 63 directly creates the bay table
with the appropriate target constraints. The store clear/delete/overwrite registry and DDL parity test include these
tables. The store facade
owns transactions; existing artillery_store encodes/decodes its subsystem.
No second save path or new persistence-module gate exception.

Current stores require exact row completeness even for empty crews/magazines
and sold formations. New-purchase defaults apply only to a real new asset,
never to repair a loaded row. No schema-61 upgrade, old-row defaulting or upgrade
retry is supported. Unsupported-format tests assert unchanged schema, rows and
versions; current-format tests retain constraint, corruption, identity, digest,
failure/retry and continued-evolution coverage.

Persist/classify all fields and job targets, include them in digest, check
Person next-ID references as well as owners, and reject unknown enums/full
TEXT including NUL suffixes, wrong SQLite storage types, negative/overflow
values, overcapacity magazines, rounds in destroyed/missing bins, duplicate
cross-asset seats, invalid company-seat membership, sold references/jobs, impossible
maintenance/checkpoint future days and missing parents. Recovering occupants
are valid saves even though unavailable; locality changes during a company's
normal transit are valid and suppress capability. A queued or started artillery
bay job retains its valid live HQ and formation while the attached company is
outward, returning, deployed or idle afield. Persistent topology validates the
pool HQ or attached home-HQ relationship independently of present work capability;
freight/sold targets, missing or wrong HQs, duplicate targets, invalid kind/timing
and mixed Unit/artillery payloads remain invalid. Physical absence suspends work
through `jobCanWork` and the actual local mechanic/facility owners. A started job
keeps its shared bay and waits without RNG, labor, charges or repair; returning
home permits deterministic resumption. This does not add a company-departure
prohibition or bypass ordinary travel command rules. A pool mechanic whose
company subsequently departs remains a valid unavailable assignment, never
remote service; saved physical absence alone is not corruption. Static descriptors/capacity,
readiness/location/quotes are derived; preparation and HourBooks are scratch.


## Existing-view compatibility

`crew.operatingAssignment` distinguishes an ordinary Unit pilot from an
artillery formation and named operating seat. `crew.technicianTargets` lists
ordinary Unit targets followed by artillery formation targets in ascending
identity order; equal numeric IDs across the two kinds remain distinct. Retained
wounded, captive, training or absent assignments remain assignments. The whole
outfit unassigned pool excludes every live asset reference; a company's combat
pool excludes operating seats while retaining its own membership semantics.

Existing People and person records format those answers. Ordinary crew pickers
consume the same `crew.assignBlock` as the command, so artillery occupants are
ineligible until explicitly unassigned. Personnel company/HQ pickers and person
actions consume the departure owner for deployed, idle-afield and return-transit
artillery occupants. These are advisory views; commands revalidate before mutation.

`hq_ops.bayTarget` identifies Unit, formation or fabricated item by BayJob kind.
HQ detail and bay listings share one formatter, displaying the actual target,
queue timing and service-owner waiting reason at the job HQ. Facility rows keep
their typed facility identities; all other rows retain null action entries.
Dynamic names, catalogue and item labels pass through validated plain-text
rendering. Queries propagate allocation/invariant failures and consume no RNG.
These existing views add no artillery action, parser verb or dedicated panel.
