# Coding contract

The rules every change to IRON LEDGER must follow. This document is
normative: it says what the code must do, not what it does today. Where
the code falls short, the code is wrong, not the rule. `CLAUDE.md` carries
the ten-line summary; `ARCHITECTURE.md`, `docs/tui.md` and the Zig guide
explain the *why* and point here for the *what*. Do not restate a rule
from this file elsewhere: link to it.

Every section ends with **Reviewer checks**: the grep or question that
finds a violation. Run them before opening a pull request.

---

## 1. Layers, and the direction of dependencies

```
frontends     src/tui/*  ·  src/main.zig (REPL / demo CLI)
application   src/sim/cli.zig (verbs → commands, errors → sentences)  ·  src/persist/*
sim           src/sim/queries.zig                    ← view models (a leaf)
              src/sim/{commands,tick,checklist,hq_ops,battle,…}.zig  ← rules and mutation
              src/sim/state.zig                      ← GameState
domain/econ   src/domain/*  ·  src/econ/*  ·  src/gen/*
data          data/*.zon  ·  data/tables/*.zon
```

1. **Imports point down only.** A module may import modules in its own
   layer or below. Nothing below `queries.zig` imports `queries.zig`:
   it is a leaf. A rule that both a screen and the tick need lives in a
   rules module, and `queries` calls it.
2. **The sim core is pure and deterministic.** `src/domain`, `src/sim`,
   `src/econ`, `src/gen` contain no I/O, no wall clock, no file-scope
   `var`, no PRNG outside `sim/rng.zig`, and no `std.heap.page_allocator`
   or other process-global allocator. Every allocation comes from the
   campaign arena (`gs.allocator()`) or an allocator the caller passed.
   Same seed and same commands must give the same state.
3. **Commands are the only way in.** Every mutation of `GameState` from
   outside `src/sim` goes through `commands.execute`. A frontend that
   needs an effect the commands lack adds the command; it never patches
   state, not even to repair a derived field.
4. **Queries are the only way out.** Frontends read only through
   `queries` (the checklist reaches them through `queries.desk`). They
   never walk `gs.units`, `gs.hqs`, `gs.forces`, `gs.people` or any other
   `GameState` field, never call a `GameState` method, and never call a
   domain lookup (`planet.find`, `chassis.find`, `part.catalog`,
   `faction.get`, …). What a screen needs to know is a field on a query
   result. The only domain imports a frontend may hold are the enum and
   ID types that command payloads require.
5. **Persistence is reached through one facade.** The lobby and the
   autosave call one application-layer module; no screen imports
   `game.store`.
6. **Verbs are parsed once.** `src/sim/cli.zig` parses every command verb
   for both the REPL and the TUI `:` line, and holds the one
   error → sentence table. No second parser, no second table.

**Reviewer checks**

```sh
# frontends touching the core directly: must print nothing
grep -nE '\b(g|gs)\.(units|hqs|forces|people|clock|funds|loans|market_listings|contract_offers|supply_policies|unit_transfers|bankrupt|outfit_name|campaign_id)\b' src/tui/*.zig
grep -nE '\b(g|gs)\.[a-zA-Z_]+\(' src/tui/*.zig | grep -vE '\.(allocator|diff)\('
grep -nE 'game\.(store|state|hq_ops|contract_market|contract_control|battle|maintenance|medical|tick|planet|faction|chassis|part|force|hq|person|unit|difficulty|dataProvenance)\b' src/tui/*.zig
# the sim importing the view layer: must print nothing outside test blocks (a test may cross-check a screen against a command)
grep -n 'queries.zig' src/sim/{state,tick,commands,checklist,hq_ops,battle,maintenance,medical,contract_control,contract_events,field_supply}.zig src/econ/*.zig src/domain/*.zig
# impurity in the core: must print nothing outside tests
grep -nE 'std\.(time|fs|Io|process|posix|os)\b|page_allocator|std\.debug\.print|^var ' src/domain/*.zig src/sim/*.zig src/econ/*.zig src/gen/*.zig
```

---

## 2. One rule, one place

7. **A game rule is one named function.** Eligibility, cost, capacity,
   shortfall, ranking, threshold, posture: each is a `pub fn` in the
   module that owns the subsystem, with a doc comment naming the rule
   and its source (CamOps chapter, ARCHITECTURE section, play feedback).
   Every consumer calls it. Two loops that compute the same thing are a
   defect even while they agree, because they will not stay agreeing.
8. **Predicates are methods, never inline status combos.** "This hull can
   fight", "this hull is parked", "this company is home", "this person is
   a tech", "this person is available today" are each one predicate on
   the entity or on `GameState`. A call site never spells
   `status == .a or status == .b` itself. Adding a status or a role
   changes one function.
9. **A number appears once.** A constant lives as a named declaration in
   the domain module, or as a row in `data/tables/*.zon`; a literal never
   recurs at a second site. `// TUNE` marks a placeholder awaiting
   migration to data and is not a licence to copy it.
10. **Arithmetic conventions are fixed per quantity.** Whether a quantity
    rounds up, down or to nearest (provisions burn, transit days, labour
    charges) is decided once, next to its constant, as a helper every
    consumer calls. Never `a / b` at one site and `divCeil(a, b)` at
    another.
11. **A ledger is one function.** "Need, on hand, coming, short" for any
    kind of stock is computed by one function per stock kind (structural
    components, field spares, provisions, munitions) that fixes the scope
    of "on hand" and the order statuses that count as "coming". Screens
    print its rows; commands consume what it lists.
12. **Formatting helpers are single too.** Money, dates, person names,
    basis points to `×1.47` or `%`, fatigue and morale colour bands: one
    helper each, in `queries.zig` or the domain module, used by every
    frontend and every log line.

**Reviewer checks**

- When a rule changed, how many files changed? More than the rule's home
  plus its tests means the rule was duplicated. Fix the duplication in
  the same pull request.
- `grep -nE 'status == \.[a-z_]+ or .*status == \.'` across `src/` should
  only hit the predicate definitions.
- A new literal: `grep -rn '<the number>' src/ data/` finds exactly one
  declaration.
- A comment saying "mirrors", "same as", "keep in sync with" is a
  duplicate rule waiting to drift. Replace it with a call.

---

## 3. Queries are view models, not rule homes

13. **A query formats; it does not decide.** It may filter, sort, pad,
    colour and phrase. It may not be the only place a rule is computed.
    If the tick, a command or the checklist needs the same answer, the
    rule moves down and the query calls it.
14. **One query serves every frontend.** A REPL printer is a loop over a
    query result. No `print*` in `src/main.zig` walks `GameState` or
    reimplements a query's arithmetic.
15. **Queries are pure and allocator-parameterised.** They allocate from
    the allocator they were given, never from a global one, and they
    propagate allocation errors rather than swallowing them into a
    default value.
16. **Markup is presentation.** The `{c}` `{a}` `{g}` `{d}` `{s}` `{/}`
    tags are emitted only by `queries.zig`, `table.zig` and `src/tui`.
    Domain enums, command results and campaign-log text carry none. The
    tag set is declared once, in `sim/table.zig`; `tui/screen.zig` maps
    from that declaration.
17. **Row meaning comes from the query.** A key handler that needs to
    know what the highlighted row is asks the query for the ID or kind
    beside the text. It never counts rows or matches on rendered text.

**Reviewer checks**

```sh
grep -nE '\{[acg]\}|\{/\}' src/domain/*.zig src/sim/*.zig | grep -v -e queries.zig -e table.zig   # must be empty ({d}/{s} are also std.fmt specifiers, so they are not grepped)
grep -nE 'gs\.(units|hqs|forces|people)\.' src/main.zig                                    # must be empty
grep -n 'std.mem.indexOf(u8, .*"{' src/tui/*.zig                                           # must be empty
```

---

## 4. Frontend structure

18. **One place per concept.** A screen is a module under `src/tui/`
    exporting `draw`, `move`, `enter`, `key` and `footer`, registered in
    one table indexed by `Tab`. Adding a screen touches that table and
    the new module; it never adds an arm to several parallel switches.
19. **Widgets are shared.** Picker, confirm dialog, number form, list
    pane, table pane and cursor clamp exist once each. A screen or modal
    never re-implements one. A confirm dialog is `confirm(command, verb)`
    so its refusal handling lives once.
20. **Command feedback goes through one helper.** `execSay` runs the
    command, shows the refusal sentence on failure and the success line
    on success, and resets the status style on the way. No caller
    inspects `msg_style` or `msg.len` by hand.
21. **Layout is named.** Split ratios, minimum pane heights and the
    "narrow terminal" threshold are constants in one `layout` module.
22. **Key legends have one source.** The footer, pane right-titles, the
    `?` help screen and the key table in `docs/tui.md` all derive from
    one table per screen, and the smoke test checks the doc table
    against it.
23. **The client keeps only client state.** Cursors, focus, the open modal
    and the current tab live in `App`. Selections are indices or IDs
    revalidated against the query result every frame through the one
    clamp helper; nothing copied from `GameState` survives across frames.
    A modal captures an ID, and the command revalidates it on confirm.
24. **Escape sequences live in `term.zig`** (and `emblem.zig` for the
    image protocols). No other module writes `\x1b`.
25. **Colours are semantic.** Amber for attention, green for ok, red for
    critical, cyan for focus, dim for chrome, on the terminal's own
    background. Political map colours are chosen through one function.

**Reviewer checks**

```sh
grep -c 'switch (self.tab)' src/tui/*.zig          # one
grep -n 'msg_style != .crit\|msg.len == 0' src/tui/*.zig   # only inside execSay
grep -n '\\x1b' src/tui/*.zig | grep -v -e term.zig -e emblem.zig   # empty
grep -nE 'b\.w \* [0-9]+ / 100|b\.w > 1[0-9]0' src/tui/app.zig       # only in layout
```

---

## 5. Commands and errors

26. **Commands validate everything.** A frontend never pre-checks a rule
    to decide whether to send a command or which message to show. It
    sends the command; the refusal is an `Error.*` value; `cli.errorText`
    turns it into the one sentence the player reads.
27. **A command leaves the state consistent.** Derived fields (HQ
    staffing, treasury balances, committed BV, cached counts) are
    refreshed inside the command before it returns, never by the caller
    afterwards.
28. **Every command has a verb; every verb has a command.** A new
    `Command` arm lands with its `cli.zig` parse, its help line, its
    error sentences and a REPL smoke step in the same pull request.
29. **Refusals are values, not exceptions.** Sim-core functions return
    typed error sets; `commands.execute` maps them onto `Error` so a
    caller can explain the refusal without inspecting internals.

**Reviewer checks**

- Does the TUI branch on `isCompanyHome`, `deploymentContract`,
  `status`, treasury balance or stock before calling `exec`? Move the
  check into the command.
- Does the new command's test assert the derived fields, not just the
  primary mutation?

---

## 6. Data, money, time, randomness, identity

30. **Money is integer C-bills** (`types.CBills`); multipliers are basis
    points through `types.applyBp`. No floats in financial or rules math.
31. **Time is `day_index: u32`.** Calendar rendering happens only in
    queries and frontends, through the one date helper.
32. **IDs are typed** (`types.PersonId`, `types.UnitId`, …). A raw integer
    never crosses a module boundary.
33. **Randomness comes from `sim/rng.zig` named streams.** Pick the stream
    that matches the subsystem; never construct a PRNG elsewhere. All
    dice are 2d6 unless CamOps says otherwise.
34. **Static game data lives in `data/*.zon`.** Rule tables cite their
    sourcebook (CamOps chapter, TechManual page) in a comment beside the
    table. Placeholder tuning values are marked `// TUNE` and migrate to
    `data/tables/tuning.zon`; the struct in `src/domain/tuning.zig` is
    the schema.
35. **Skills follow MekHQ:** lower level is better (gunnery 3 beats 4).
36. **Every module names its MekHQ counterpart** in its doc comment when
    one exists (`docs/mekhq-map.md`).

---

## 7. Tests and verification

37. **Every module carries in-file unit tests.** A new `pub fn` that
    encodes a rule ships with a test that would fail if a second copy of
    the rule drifted: assert that the screen and the command agree, not
    just that each returns something.
38. **Bug fixes start with the regression test,** in the module that owns
    the rule, reproducing the report before the fix lands.
39. **The gate is `zig build test --summary all`,** green, plus both smoke
    scripts (`docs/tui_smoke.py`, `docs/repl_smoke.sh`) for any change
    under `src/tui`, `src/sim/cli.zig`, `src/sim/queries.zig` or
    `src/main.zig`. Every `src/tui/*.zig` module is listed in the test
    block at the top of `src/main.zig` so it compile-checks.
40. **Determinism is a test.** Golden-master runs (fixed seed, scripted
    commands, hashed state) stay green; a change that moves the hash
    explains why in its message.

**Reviewer checks**

```sh
zig build test --summary all
python3 docs/tui_smoke.py zig-out/bin/game /tmp/x.db
bash docs/repl_smoke.sh zig-out/bin/game /tmp/r.db
grep -n '@import("tui/' src/main.zig      # one line per src/tui module
```

---

## 8. Style

41. **Legible over clever.** Formulas read like the rulebook line they
    implement; the comment names the rule, not the loop.
42. **Functions stay short.** Around a hundred lines is the ceiling; a
    `switch` with more than about ten arms of case-specific code becomes
    a table or a module split.
43. **Doc comments state the rule.** Every `pub fn` says what it decides
    and where the rule comes from. Play-feedback notes are welcome and
    name the rule's home, not the screen that surfaced the bug.
44. **No dead mirrors.** A comment such as "mirrors X", "keep in sync
    with Y" or "same as Z" is a defect report; replace the copy with a
    call to X.
45. **Naming.** Modules and functions are named for the rule or the
    entity (`depotNeeds`, `isCompanyHome`), never for the screen that
    first wanted them.

---

## 9. Pull requests

### 46. One branch in flight at a time

A change lands on `main` before the next one starts. Branches are
sequential, never a stack of open PRs, because two branches cut from the
same `main` cannot see each other: they edit the same line without
conflict until merge time, and every branch after the first is verified
against a `main` that does not yet exist. A branch is finished when its
PR is merged, the branch is deleted both sides, and `main` is pulled.

Corollaries, each of which has bitten:

- **A pushed branch always has a PR.** Pushing work with no PR makes it
  unreviewable and lets it rot behind `main`.
- **The gate runs on the branch as it stands.** Never borrow a file from
  another branch to make a check pass; if the gate needs a fix that lives
  elsewhere, land that fix on `main` first.
- **Big changes split into increments that each land**, not into
  increments that each open a branch.

**Reviewer checks**

```sh
gh pr list --state open        # more than one open PR is the smell
git branch -a                  # between changes: `main` alone
git log --oneline origin/main..HEAD   # a branch should be a short series
```

- Does this branch touch a line another open branch also touches? If you
  cannot answer, there is more than one branch open.

### The checklist

Before requesting review, answer each in the description:

1. Which rule functions did this change touch, and how many files
   changed for each? (Section 2)
2. Does every new screen string come from a query, and does the REPL
   print the same query? (Sections 3, 4)
3. Do the Section 1, 3 and 4 greps print nothing new?
4. Is every new number declared once, in a domain module or a `.zon`
   table, with its source cited? (Section 6)
5. Did every new command get its verb, help line, error sentences and
   smoke step? (Section 5)
6. Which test would fail if the rule were duplicated? (Section 7)
7. Are `zig build test` and both smokes green?
