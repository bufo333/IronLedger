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
