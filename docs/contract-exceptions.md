# Contract exceptions

Every place the code does not yet meet `docs/coding-contract.md`, as rule 87
requires: the rule, why it is not fixed yet, the scope, the deliverable in
`TODO.md` that removes it, and what stops it growing. The contract governs
all new code in full; nothing here licenses a new violation. The deliverable
that closes an entry deletes it (and its registry, layering-record or
baseline lines) in the same branch.

Scope lists name the sites a compliance sweep of every rule verified in the
code when the contract was adopted. A site found later joins its entry in
the branch that finds it.

Owner of every entry: the project owner.

### C17. Focused tests

- **Rules:** 67.
- **Why not yet:** 421 public functions in the sim and domain have no in-file test naming them. The rule functions among them need a test that the rule and its consumers agree.
- **Scope:**
  - Rule functions with no test:
    - `hq_ops`: `beyondEconomicalRepair`, `canFabricate`, `bayCanRebuild`, `upgradeBlock`, `rebuildEstimate`, `engineCharge`, `paperworkDaysFor`, `depotHqFor`, `staffHqToRequirement`
    - `maintenance`: `techHoursAvailable`
    - `crew`: `canReachPool`
    - `sites`: `siteCapacityTons`, `moveStock`
    - `treasury`: `transferFunds`, `isInsolvent`, `liquidationValue`, `creditLimit`, `courierEtaDays`
    - `battle`: `effectiveRoe`, `estimatePower`, `estimatedKills`, `inContactWindow`
    - `medical`: `healDays`, `careFor`, `turnoverRisk`
    - `personnel`: `severanceOwed`, `manningNeeds`, `readinessPenalty`
    - `field_supply.rushQuote`
    - `network`: `fitsThroughput`, `routeCostMultBp`
    - `offer_rating.rateOffer`
    - `commands.transferBlock`
    - `checklist.turnHold`
    - domain `clock`: `Date.isPayday`
    - domain `contract`: `gradeOf`, `objectivesMet`
    - domain `person`: `baseSalary`
    - domain `unit`: `carryCost`, `maintenanceHours`
    - domain `types`: `salaryMultBp`, `availabilityTarget`
  - 89 of the 157 query functions have no test.
  - Screen modules test one or two of their keys, and no empty states.
- **Removal:** C17.
- **Guard:** review (checklist question 13). No mechanical check.

### C20. Documentation and naming

- **Rules:** 61, 75, 81, 82, 84.
- **Why not yet:** Mechanical; batched once the module splits settle the file names.
- **Scope:**
  - **MekHQ map links (rule 61).** 35 module headers name a MekHQ counterpart without linking `docs/mekhq-map.md`.
  - **Misplaced comment (rule 82).** It sits at `state.zig:316`.
  - **Wrong citation (rule 84).** "ARCH §9.8 identity" should cite §5, at `state.zig:217`, `commands.zig:52` and `force.zig:144`.
  - **Formula lines too long (rule 75):** `maintenance.techHoursFor`, `maintenance.techHoursAvailable`.
  - **Missing unit in names (rule 81).** The weekly-hour functions don't say they are weekly.
- **Removal:** C20.
- **Guard:** the module-header and comment checks in `verify-contract.sh` for the parts they cover; review for the rest.

---

## Layering record

Rule 5 layering debt, one canonical edge per line as
`<source file> -> <resolved imported module>`, both paths relative to the
repository root. `docs/verify-contract.sh` resolves every upward import in
`src`, except a test's import of `queries.zig` (rule 5's test clause), and
fails on one missing from this record, and on a record edge whose import no
longer exists (remove it). The record only shrinks: reformatting a recorded
import line, without changing which module it names, still matches its edge
and passes. A line records existing debt and permits nothing; a new upward
import is a violation even beside a listed one.

```layering
```
