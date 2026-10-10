# P2 Battle-Armor and Artillery Design Approval

## Status and scope

This is the sole durable approval authority for P2a. It is a design-only
approval that identifies the delivery boundaries for P2b through P2i. It does
not approve candidates, source facts, values, schemas, or gameplay behavior.

The campaign era is 3025. Inner Sphere battle armor is unavailable in that era,
so P2b through P2d are deferred until an explicitly approved campaign-era
expansion beyond 3025. This is an era gate, not approval for a battle-armor
candidate, source fact, identity model, schema, command, or behavior.

Battle armor and artillery are separate asset tracks. They are also separate
from the approved conventional vehicle and aerospace foundation in
`docs/p2-conventional-combat-design.md`; P2a neither changes nor renumbers
that track.

## Source and data policy

Later increments must re-encode verified source facts rather than copy source
data, following the repository licensing approach. Before any candidate is
added, its owning P2 design or tracker record must externally verify and pin:

- Durable source authority, edition or revision, stable upstream path or
  publication locator, and licensing or re-encoding status.
- Era availability and exact identity or variant, including its source-defined
  category.
- Catalogue facts used by the game: kind or category, source-defined capacity
  unit where applicable, BV, cost, rarity or availability policy, introduction
  year, loadout, ammunition dependencies, represented armor or structure, and
  transport or bay requirements.
- Crew complement, roles, skills, technician responsibility, formation or crew
  size, and whether the existing one-person `Unit.pilot` representation fits.
- Repair, maintenance, field or depot, ammunition or reload, destruction,
  salvage, and recovery rules.
- Battle mechanics: contribution condition, abstraction, objective behavior,
  stacking limits, force or attachment eligibility, and every numeric modifier.

For the bounded operational adaptation, see [P2g project operational policy](#p2g-project-operational-policy).

The repository's existing `.ba_trooper`, `.tech_ba`, `has_artillery`, and
`artillery_bp` names or values do not verify any of these domain facts. In
particular, the unused `artillery_bp = 1_000` is not an approved artillery
rule. Each later fact table must cite its authority as required by the coding
contract. Unknown page references remain unknown; no candidate, value, role,
capacity, or formula may be invented.

For the bounded operational adaptation, see [P2g project operational policy](#p2g-project-operational-policy).

Any future battle-armor return requires a later era-expansion plan to source
and pin MegaMek GitHub records for each proposed candidate and verify its
actual introduction date is later than 3025. Current research gaps,
source-directory labels, and project placeholders are not availability rules.

## P2g project operational policy

P2g operational gameplay is project-designed under
docs/p2-artillery-operations-design.md. Its approved crew complement,
seat roles and qualifications, ammunition loading units and capacities,
supply prices and availability, maintenance, repair, readiness and
new-purchase defaults are IRON LEDGER adaptations, not external source
facts. For these P2g policies only, that durable project design replaces
this document's external-verification and no-invention requirements.
P2e physical catalogue facts, identity, provenance, era, calculated BV
and construction cost remain pinned. This exception does not approve
P2h battle effects, P2i interfaces, battle armor or an era expansion.

P2i owns dedicated artillery panels, parser verbs and TUI controls. P2g keeps
existing personnel, assignment and shared bay views truthful as ordinary
people and bay jobs gain artillery references. This compatibility boundary
does not activate P2h or P2i.

## P2h project combat policy

[Artillery battle design](p2-artillery-battle-design.md) is the approved authority
for P2h firing, temporary power attrition, exposure, casualties, recovery and
terminal disposal, operating rewards and reports. For these bounded P2h policies,
that complete project design replaces external-verification and no-invention
requirements. Its numerical adaptations do not claim an external counterpart.
P2e source facts, P2g operational policy, era gates and all battle-armor research
requirements remain effective. P2i dedicated controls remain deferred.

## Ownership and acquisition

Before P2b or P2e begins, the selected source-backed model must decide whether
each acquired asset uses the existing `Unit` plus `HullInstance` and ownership
history lifecycle, or requires another persisted entity for a verified
non-hull formation. No purchase, salvage, transfer, or destruction path may
create an untracked physical asset.

The model must name the acquisition or market owner and specify whether supply
is finite, replenishing, or governed by another verified rule. It must not
inherit conventional replenishing-market or mech faction-pool policy by
analogy. One atomic acquisition operation must cover funds, listing or
reservation, typed identity, unit or formation, provenance and ownership
history, force placement or transfer, logs, RNG, and persistence-visible state.

## Attachment and location

Before P2b or P2e begins, the model must choose an explicit topology for each
asset: line-lance element, support-company attachment, company-level
attachment, independent force echelon, or another explicit topology. Existing
line, air, and support-lance placement rules do not decide this.

One eligibility owner must govern attachment, capacity, location, transport,
transfer, deployment, and detachment, taking the actual force, site, and HQ
context for site-sensitive decisions. The model must state whether an asset can
be committed, supplied, repaired, or provide a modifier while pooled, in
transit, in a shop, mothballed, destroyed, or detached. Parent deployment
cannot grant an implicit benefit.

## Crewing and readiness

Before P2b or P2e begins, the model must define its source-backed crew and
technician complement, including seats, roles, required skills, combat inputs,
and how hiring, auto-assignment, and manpower reporting account for it.

For the bounded operational adaptation, see [P2g project operational policy](#p2g-project-operational-policy).

Each capability used by battle, objectives, maintenance, reloads, repair,
transport, and supply must have one complete operational predicate. It must
cover applicable status, physical location, attachment, required crew
availability, relevant technician or maintenance conditions, and supplies. A
narrower predicate is not readiness. Unless the approved model establishes
otherwise, readiness owns capability; crew owns eligibility and seats;
maintenance owns technician workload; and battle consumes their results.

## Persistence and integrity

Each eventual state field must be classified beside its owner as persisted,
derived, session-only, or scratch. This includes IDs, provenance, ownership,
attachment and location, crew references, ammunition and damage,
readiness-relevant state, reports, histories, and any queues or listings.

Existing `Unit`, `HullInstance`, `HullOwnershipHistory`, `HullCombatRecord`,
`force_unit`, market listings, battle reports, and the store facade may be
reused only where the approved model fits; no parallel save path is allowed.
If an increment needs persisted fields or tables, its support boundary follows
[contract rule 51](engineering-contract.md#51-save-format-support-is-explicit).
It must validate current-format references and next IDs, cover the digest, fail
closed, and test unsupported-format refusal without mutation, exact save-load,
and continued evolution. Migration fixtures apply only when a migration is
explicitly supported. P2a adds no state or save-format change.

## Ordered delivery

Battle armor and artillery are separate delivery tracks. Battle armor remains
deferred at P2b through P2d while the 3025 scope is unchanged. Artillery
continues in order from P2e through P2i.

### Deferred battle-armor track

1. `P2b`: Battle-armor verified catalogue and domain facts and provenance,
   including its chosen identity and persistence classification boundary.
2. `P2c`: Battle-armor acquisition and attachment through the approved
   ownership, market, force, transport, and command owners.
3. `P2d`: Battle-armor crewing, maintenance and readiness, repair and supply
    behavior, persistence completion, and required focused coverage.

Before this track may resume, a separately approved campaign-era expansion
must verify and pin MegaMek GitHub records for each candidate's actual later
introduction date, complete the P2a-required candidate research, and approve a
separate implementation plan.

### Active artillery track

1. `P2e`: Artillery verified catalogue and domain facts and provenance,
    including its distinct identity or category and persistence classification
    boundary.
2. `P2f`: Artillery acquisition and attachment through the approved ownership,
    market, force, transport, and command owners.
3. `P2g`: Artillery crewing, maintenance and readiness, repair, ammunition,
    and supply behavior, persistence completion, and required focused coverage.
4. `P2h`: Project-designed artillery battle effects under
    `docs/p2-artillery-battle-design.md`, with atomic engagement preparation,
    deterministic RNG, typed persistent reports and truthful existing AAR panes.
    Dedicated controls remain P2i; battle armor remains deferred with P2b-P2d.
5. `P2i`: Artillery REPL, TUI, and query surfaces for already-delivered
    commands and reports, using the command and query boundary and both smoke
    scripts. Its battle-armor portion remains deferred with P2b through P2d.

Each active increment has one cohesive primary outcome and must describe
interfaces and acceptance boundaries without unsourced values.

## Later acceptance evidence

- Every factual data addition records a pinned external authority and locator,
  is re-encoded rather than copied, and passes normal-build semantic validation.
- Each new rule has one named owner, source citation, focused owner and
  consumer tests, and an asymmetric locality test when location matters.
- Compound commands validate, prepare allocations and logs, then commit;
  refusal and injected-failure coverage preserve the complete digest.
- Battle effects use only approved complete readiness and attachment predicates,
  with deterministic stream selection in the initiating simulation subsystem.
- Created entities and actionable query rows carry typed IDs; CLI verbs, usage,
  and refusal text remain singular in `src/sim/cli.zig`.
- Persistence increments cover fail-closed current-format load, save-load digest,
  unsupported-format refusal without mutation, and continued evolution under
  [contract rule 51](engineering-contract.md#51-save-format-support-is-explicit);
  migration fixtures apply only to explicitly supported migrations.
- Applicable implementation branches run the required formatting, test, and
  contract checks; P2i and changes to the prescribed frontend boundary also
  run both smoke scripts. Final delivery runs the applicable clean-package and
  target builds.
