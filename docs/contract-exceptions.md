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

---

### C10. Location, posture and the seat

- **Rules:** 21, 22, 23, 71.
- **Why not yet:** It changes gameplay balance. Named posture predicates and two-HQ tests come first.
- **Scope:**
  - **"Not deployed" used as "home".** These sites treat a company without a deployment contract as home:
    - `medical.zig`: `87`, `108` (`careFor`), `353-381` (rest), `395` (rotation reset)
    - `maintenance.zig:113`
    - `checklist.zig:270`
    - `commands.zig`: `866`, `882`, `934`, `1054`, `1216`, `1342`, `1377`, `1389`, `1624`, `1634`, `1799`
    - The checklist's `isCompanyHome` count disagrees with `careFor` (`499`).
  - **Rules reading the first HQ instead of the one involved:**
    - negotiation uses the first HQ's command office (`commands.zig:2315-2317`)
    - the freight discount comes from the first HQ (`2030-2032`)
  - **Medical pooled across the outfit:** beds, hospital bonus, doctors and medics (`medical.zig:122-166`).
  - **Seat and `.outfit` resolution** is re-derived at about 13 sites.
  - **Lab stock double-counted:** `installCandidates` adds the seat's stock on top of the home HQ's (`queries.zig:3372`).
  - **Two-HQ tests missing** for medical, maintenance, the hiring hall, negotiation, `hq_ops`, the checklist and field supply.
- **Removal:** C10.
- **Guard:** review (checklist question 5). No mechanical check.

### C13. Numbers, arithmetic and formatting

- **Rules:** 24, 25, 28, 54, 55, 59.
- **Why not yet:** Mechanical, but it touches many rule sites. 331 tuning rows need a citation or `// TUNE`.
- **Scope:**
  - **Repeated and bare literals:**
    - day floors
    - negotiation caps
    - the field-plan shape
    - listing expiry
    - standing gain
    - hours per bay day
  - **Limits only the frontend enforces:** fabricate at most 20, loan term at most 60.
  - **Arithmetic:**
    - Loan interest has no helper, and the pay day is stale (`commands.zig:1680-1686`, `tick.zig:566`).
    - Week and month conversions are bare literals.
    - Money is multiplied by raw percentages, not basis points (`contract.zig:213`, `commands.zig:2379`, `2393`, `battle.zig:946`, `state.zig:1849`, `tick.zig:542`, `field_supply.zig:80-106`).
  - **Calendar:** fixed 30- and 365-day units (`tick.zig:372`, `contract_control.zig:75`, `135`, `person.zig:267`, `284`, `454`, `queries.zig:2632`).
  - **Formatting:**
    - Raw C-bills appear in log text (the money formatter is in the queries leaf).
    - Event effects are formatted twice (`contract_events.zig:293`, `queries.zig:535`).
    - Helpers are duplicated: `bpMultText`, half-tons, day and ETA text.
  - **Citations:**
    - 331 tuning rows carry neither a source nor `// TUNE`.
    - Provenance labels are missing (factions, awards, difficulty, ranks).
    - `// TUNE` markers disagree between the struct and the data.
- **Removal:** C13.
- **Guard:** review (checklist question 10). No mechanical check.

### C14. Randomness

- **Rules:** 57.
- **Why not yet:** Passing streams changes generator signatures, and the uncited dice need their sources found.
- **Scope:**
  - **Shared generators hard-code their stream:**
    - `econ/market.zig:167`, `241-269`
    - `gen/company_gen.zig:98`
    - `sim/personnel.zig:359`
  - **About 20 uncited non-2d6 dice:**
    - `market.zig:245-269`
    - `contract_market.zig:46`, `63`, `153`, `159`, `300-323`, `376`, `422`
    - `battle.zig:373`, `1205-1208`
- **Removal:** C14.
- **Guard:** the stream-salt tests in `rng.zig`, and review.

### C15. Routing, truck capacity, beachhead price

- **Rules:** 20, 22, 24.
- **Why not yet:** Changes gameplay balance. The rounding decision is recorded in `docs/audit-response.md` (A17).
- **Scope:**
  - **Routing.** It is a hop-count BFS that ignores capacity (`network.zig:63-144`). The charter fallback has no cap.
  - **Truck capacity:**
    - Capacity counts any truck that isn't destroyed (`sites.siteCapacityTons`, `battle.zig:24-33`).
    - Queries recount trucks with hard-coded 20t and 5t (`queries.zig:1825-1835`).
    - The support-lance bonus is applied when `units.len > 0` (`queries.zig:940`, `medical.zig:361`).
  - **Beachhead pricing:**
    - The distance is the literal 30 (`field_supply.zig:164`).
    - The Map multiplier text is hard-coded and wrong in ring (`queries.zig:6214-6216`).
    - The field-HQ recovery that ARCHITECTURE §9.6 describes is not implemented.
- **Removal:** C15.
- **Guard:** review. No mechanical check.

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

### C18. External input bounds

- **Rules:** 41, 64.
- **Why not yet:** Needs a width table and bounded decoders.
- **Scope:**
  - **Text width.** Width is counted per code point, not per cell (`screen.zig:149-177`). `queries.padCells` is a second counter, and it uses `initUnchecked` (`queries.zig:76-92`).
  - **PNG decoding:**
    - CRCs are not checked (`png.zig:69`).
    - IHDR order is not checked (`56-68`).
    - The pixel limit is 64M (`82`).
    - The inflated length may exceed the expected length by one byte (`88-89`).
    - Alpha is dropped in the fallback (`133`).
  - **Database blobs** are copied with no size limit (`sqlite.zig:167-172`).
  - **Terminal input.** A CSI parameter can overflow (`term.zig:258`).
  - **Music:**
    - `waitpid` blocks (`music.zig:256-266`), and `-1` is read as "finished" (`224-226`).
    - Each playlist rebuild allocates in the long-lived arena (`161-176`).
- **Removal:** C18.
- **Guard:** review. No mechanical check.

### C19. Platform support

- **Rules:** 65.
- **Why not yet:** Needs a target-gated terminal, resize, child process, paths and audio for Windows.
- **Scope:**
  - `term.zig` uses POSIX termios and SIGWINCH unconditionally.
  - `music.zig` uses `waitpid`, `getpid`, `kill` and a PATH scan split on `:`.
  - `build.zig` rejects no target.
- **Removal:** C19.
- **Guard:** review. No mechanical check.

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
