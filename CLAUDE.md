# Project guide

**IRON LEDGER** — BattleTech mercenary-company management sim in Zig 0.16.
No external deps (SQLite via the system library; music via the system
command-line player as a child process).
Read ARCHITECTURE.md before changing sim behavior; ROADMAP.md defines stage
order — implement stages in order unless told otherwise.
`TODO.md` is the one list of open work, in order: closing the contract's
open exceptions (`docs/contract-exceptions.md`) comes first.

## System constraints

- NEVER guess or assume file contents from memory.
- ALWAYS use the `Read` tool to inspect a file fresh if it is the target
  of a modification or analysis.
- Do not optimize by relying on previous turn details if files are
  subject to external changes.

## Commands

- `zig build test --summary all` — run all tests (must stay green); it also
  builds and installs `zig-out/bin/game`, so a green run means the client
  compiles and the binary is current
- `zig build -Ddata=<dir>` — build with a mod directory overlaying any
  `data/*.zon` / `data/tables/*.zon` file (docs/modding.md)
- `zig build -Doptimize=ReleaseFast [-Dbundle-music] --prefix dist` — a
  shippable tree (`dist/bin/game` + `dist/share/iron-ledger/{music,logos}`);
  the loose runtime files are found through `src/tui/paths.zig`, never the
  working directory
- `zig build run` — demo CLI; `zig build run -- --repl` command console;
  `zig build run -- --tui [--store path] [--ascii] [--no-splash] [--no-music]`
  terminal client (Stage 12); `docs/tui_smoke.py zig-out/bin/game [x.db]`
  drives it through a pty; `docs/repl_smoke.sh zig-out/bin/game [r.db]`
  scripts the REPL. With no path each uses a private temporary store; a
  given path must end in `.db`. Both reap their clients, require exit
  status 0, and time out (`SMOKE_TIMEOUT_S`)
- `docs/data-fixtures.py` — builds a broken mod overlay of each data family
  and requires every one to fail; prints `DATA FIXTURES OK` (CI runs it)
- `docs/verify-contract.sh` — the coding contract's mechanical checks;
  prints `CONTRACT CHECKS OK` or the violations (CI runs it)
- `docs/clean-package.sh` — builds a ReleaseFast release from a tree
  holding only the `build.zig.zon` paths; prints `CLEAN PACKAGE OK`
  (CI runs it)

## Git workflow

**One branch in flight at a time.** Start it, land it, delete it, pull
`main` — then start the next. Never begin a second change while the first
is unmerged, however small or unrelated it looks: parallel branches cut
from `main` cannot see each other, so two of them editing one line is
invisible until a merge conflict, and every branch after the first is
verified against a `main` that does not exist yet.

The loop, every time:

```sh
git checkout main && git pull --ff-only     # never branch from a stale main
git checkout -b <area>/<short-name>         # tui/after-action, docs/git-workflow
# …work; the gate (contract rule 72) must be green…
git push -u origin <branch> && gh pr create # push and PR in the same step
gh pr merge <n> --merge --delete-branch     # then: git checkout main && git pull
```

- Never commit to `main`, never push to `main`, never merge locally.
- **Never push a branch without opening its PR in the same step.** A
  pushed branch with no PR is invisible work: nobody can review it, it
  rots behind `main`, and it is how dead branches happen.
- **Never verify a change with a file borrowed from another branch.** If
  the gate needs a fix that lives on a different branch, that fix must
  land on `main` first — otherwise the gate is not one anybody else can
  reproduce.
- Finish the loop. A merged PR is not done until its branch is deleted
  both sides and `main` is pulled; `git branch -a` should show `main`
  alone before the next change starts.
- Use the `gh` CLI for every GitHub interaction — opening pull requests,
  reading review comments, checking CI, listing issues.
- CI runs on every pull request, prose included; its four jobs are
  required checks on `main`.
- Answer the contract's pull request checklist (section 11) in the PR
  description.

If a change is genuinely too big for one PR, split it into increments
that each land on `main` before the next begins — sequentially, not as a
stack of open branches.

## Hard rules

The contract is `docs/coding-contract.md`; read it before touching the
sim, the queries, the store or a screen. Where the code falls short, the
code is wrong, not the rule. Known violations are listed, one entry each,
in `docs/contract-exceptions.md` (rule 87): new code never adds to one,
and the deliverable that fixes an entry deletes it. The rules that matter
most:

1. No partial truth (1): a failed command changes nothing; a campaign
   loads whole or is rejected; nothing is skipped, defaulted or inferred.
2. The sim core (`src/domain`, `src/sim`, `src/econ`, `src/gen`) is pure
   and deterministic (2, 6): no I/O, no wall clock, no global state or
   allocator, all randomness through `sim/rng.zig` named streams.
3. Imports point down only; `sim/queries.zig` is a leaf nothing below it
   imports (5).
4. Commands are the only mutation boundary and are failure-atomic
   (7, 11-13): validate, prepare every allocation and log line, then
   commit; an expected refusal consumes nothing.
5. Frontends read only through queries, parse through `cli.zig`, and own
   no `GameState` (8-10); verbs and refusal sentences live once, in
   `cli.zig`; view eligibility informs, the command decides (34).
6. One rule, one owner, one result (3, 20-22): every eligibility,
   predicate, cost, capacity, quote and shortfall is one named function
   every consumer calls; location-sensitive rules take a location.
7. A number appears once, named, cited to its source (24, 59); money is
   integer C-bills with basis points, time is `day_index`, IDs are typed
   and never inferred, skills follow MekHQ (54-56, 60).
8. Persistence: every field has a class, loading fails closed, saves are
   atomic, migrations are explicit (45-51).
9. Tests: every rule module has focused tests asserting rule and consumer
   agree; a bug fix starts with its regression test; atomicity is tested
   with injected failure (67-69).
10. The gate (72): `zig fmt --check build.zig src`,
    `zig build test --summary all`, `docs/verify-contract.sh`, and both
    smoke scripts for any change under `src/tui`, `cli.zig`,
    `queries.zig` or `src/main.zig`.
