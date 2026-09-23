# Project guide

**IRON LEDGER** — BattleTech mercenary-company management sim in Zig 0.16.
No external deps (SQLite via the system library; music via the system
command-line player as a child process).
Read ARCHITECTURE.md before changing sim behavior; ROADMAP.md defines stage
order — implement stages in order unless told otherwise.
`TODO.md` is the one list of open work, in order: finish Stage 12
features first, then code quality (contract and audit deliverables).

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
  terminal client (Stage 12); `docs/tui_smoke.py zig-out/bin/game /tmp/x.db`
  drives it through a pty; `docs/repl_smoke.sh zig-out/bin/game /tmp/r.db`
  scripts the REPL

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
# …work; the gate in rule 10 must be green…
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
- Answer the section 9 checklist in the PR description.

If a change is genuinely too big for one PR, split it into increments
that each land on `main` before the next begins — sequentially, not as a
stack of open branches.

## Hard rules

The full contract is `docs/coding-contract.md`; read it before touching
the sim, the queries or a screen. The ten rules that matter most:

1. Sim core (`src/domain`, `src/sim`, `src/econ`, `src/gen`) is pure and
   deterministic: no I/O, no wall clock, no global mutable state, no
   global allocator, all randomness through `sim/rng.zig` named streams.
2. Imports point down only; `sim/queries.zig` is a leaf that nothing in
   the sim, econ or domain layers imports.
3. Every mutation from outside the sim goes through `commands.execute`;
   a missing effect becomes a new command, never a patch from a screen.
4. Frontends (`src/tui`, `src/main.zig`) read only through `queries`,
   parse verbs through `cli.zig`, and never touch `GameState` fields,
   methods or domain lookups. Verbs and error sentences live once, in
   `cli.zig`.
5. One rule, one place: eligibility, cost, capacity, shortfall, ranking,
   posture and every entity predicate is one named function every
   consumer calls. Two loops computing the same thing is a defect.
6. A number appears once: a named constant or a `data/tables/*.zon` row,
   cited to its sourcebook; `// TUNE` marks a placeholder awaiting data.
7. Queries format, they do not decide; a rule the tick or a command also
   needs lives below the queries. Markup tags are presentation and never
   appear in domain enums or log text.
8. Money is integer C-bills with basis-point multipliers; time is
   `day_index: u32`; IDs are typed; skills follow MekHQ (lower is better).
9. Every module carries in-file tests and names its MekHQ counterpart; a
   rule function's test asserts that screen and command agree.
10. `zig build test --summary all` green is the gate; both smoke scripts
    run for any change under `src/tui`, `cli.zig`, `queries.zig` or
    `src/main.zig`.
