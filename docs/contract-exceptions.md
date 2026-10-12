# Contract exceptions

Every place the code does not yet meet `docs/engineering-contract.md`, as rule 87
requires: the rule, why it is not fixed yet, the scope, the deliverable in
`TODO.md` that removes it, and what stops it growing. The contract governs
all new code in full; nothing here licenses a new violation. The deliverable
that closes an entry deletes it (and its registry, layering-record or
baseline lines) in the same branch.

Scope lists name the sites a compliance sweep of every rule verified in the
code when the contract was adopted. A site found later joins its entry in
the branch that finds it.

Owner of every entry: the project owner.

## Advance commits partial days

- **Rule:** [rule 11](engineering-contract.md#11-commands-are-failure-atomic)
  (with rules 12 and 17).
- **Reason:** `tick.advanceDay` advances the clock and refreshes staffing,
  then runs fallible phases with no prepare-before-mutate split, and no
  whole-campaign rollback exists. An allocation or invariant error inside
  day k therefore leaves days 1..k-1 and day k's earlier phases committed.
  The next day's solvency check and watch run after the previous day
  commits, and no cross-day rollback exists.
- **Scope:** `tick.advance` (the `advance_day` and `advance_days` commands)
  and `tick.advanceUntilStop` (`advance_until_stop`) propagating such an
  `advanceDay` error; and `advance`'s zero-day `Bankrupt` error, returned
  after `tick.settleSolvency` commits the bankruptcy flag and its log entry;
  and an error from the preparation between committed days —
  `tick.settleSolvency` in either command and `checklist.watchDay` in
  `advanceUntilStop` — returned with days 1..k committed and nothing of day
  k+1. Apart from `advance`'s zero-day `Bankrupt` above, every error either
  command returns before its first `advanceDay` leaves the campaign
  unchanged.
- **Removal:** `TODO.md` "Phase-atomic daily tick".
- **Expansion check:** `advanceDay` has no production caller besides these two
  commands. The tick tests "advance_until_stop: a refusal before the first day
  leaves the complete digest unchanged", "advance_until_stop: an allocation
  failure before the first day changes nothing", "advance_until_stop: an error
  inside day k returns with days 1..k-1 committed", "advance_until_stop: an
  allocation failure between days leaves exactly the earlier days committed"
  and "advance keeps its zero-day bankruptcy: the error, after the flag and
  the entry commit" pin the boundary.

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
