# Shared project guide

## Authority and migration transition

`ARCHITECTURE.md` is the architectural authority. The sole normative contract is
`docs/engineering-contract.md`; `docs/agent-workflow.md` owns role boundaries and
local delivery. `CLAUDE.md` is the Claude entry point to this shared guide.

The seven-role workflow and `.ai/plans/` apply to subsequent tasks after the
scaffold-alignment migration is accepted and integrated into local `main`.
This migration itself retains its dual immutable snapshots and the previous
five-role integration authority until integration completes. Its integrator is
the current workflow's implementer in integration mode, or John if no authorized
worker is available; the new integrator must not activate early.

## Project

**IRON LEDGER** — BattleTech mercenary-company management sim in Zig 0.16.
No external deps (SQLite via the system library; music via the system
command-line player as a child process).
Read ARCHITECTURE.md before changing sim behavior; ROADMAP.md defines stage
order — implement stages in order unless told otherwise.
`TODO.md` is the one list of open work, in order: closing the contract's
open exceptions (`docs/contract-exceptions.md`) comes first.

## System constraints

- NEVER guess or assume file contents from memory.
- ALWAYS read a file fresh with an available file-reading tool if it is the
  target of a modification or analysis.
- Do not optimize by relying on previous turn details if files are
  subject to external changes.

## Standing instruction

The coordinator workflow and role boundaries are in `docs/agent-workflow.md`.
Implementation begins only from a user-approved plan. A fresh reviewer checks
the committed branch before a separate integration task may fast-forward it
into local `main`. The user owns every Git remote operation and all GitHub
access. Scoped read-only web and source research outside GitHub follows
`docs/agent-workflow.md`.

Never optimize for a mechanical metric at the expense of its architectural
purpose. Do not use formatting, inline imports, aliases, compressed code,
test relocation, comment deletion, or similar techniques to remain below a
size threshold.

If the approved change would cross a contract threshold or require an
exception, stop before continuing. Report the conflict and present the
architecturally correct options.

Never invent or infer names, values, URLs, citations, quotations, schema facts,
or external behavior. Verify them from a source read during the current task,
or mark them unverified and stop.

Do not modify contracts, gates, exception registries, project instructions,
agent configuration, memory, CI policy, or repository protections without
explicit approval.

### Stop conditions

- If the approved implementation conflicts with a contract rule, gate,
  architectural boundary, or module threshold, stop before editing further
  and report the conflict. Never satisfy a limit through formatting,
  compressed declarations, inline imports, aliases, test relocation, comment
  deletion, or other changes that do not reduce architectural complexity.
- Never introduce a name, value, URL, quotation, citation, schema fact, or
  external claim unless it was verified from a source read during the
  current task. If it cannot be verified, stop and label it unverified.
- Work comes only from a plan John explicitly approved and dispatched. Never
  select the next item or start another branch.

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
- `docs/verify-contract.sh` — the engineering contract's mechanical checks;
  prints `CONTRACT CHECKS OK` or the violations (CI runs it)
- `docs/clean-package.sh` — builds a ReleaseFast release from a tree
  holding only the `build.zig.zon` paths; prints `CLEAN PACKAGE OK`
  (CI runs it)

## Git workflow

**One branch in flight at a time.** Start it, review it, fast-forward it into
local `main`, and delete it before starting the next. Never stack work on an
unintegrated branch.

The loop, every time:

```sh
git checkout main
# A fresh branch-bootstrap agent runs the approved branch creation command.
git checkout -b <area>/<short-name>         # tui/after-action, docs/git-workflow
# …work; the gate (contract rule 72) must be green…
# commit, then obtain a fresh read-only review of the exact commit
git checkout main && git merge --ff-only <branch>
git branch -d <branch>
```

- Never commit directly to `main`.
- Agents never push, fetch, pull, change Git remotes, or access GitHub. John
  pushes local `main` himself after closing the agent session.
- Branch creation belongs to the `branch-bootstrap` agent, commits belong to
  the implementer, and fast-forward merge plus branch deletion belong to the
  integrator. Each requires John's approval through the
  permission prompt showing the exact command.
- The reviewer must be a fresh invocation that did not plan or implement the
  branch.
- **Never verify a change with a file borrowed from another branch.** If
  the gate needs a fix from another branch, that fix must reach local `main`
  first.
- The reviewed commit must be exactly the commit that passed the gate and was
  fast-forwarded into `main`.
- Answer the contract's delivery checklist before integration.

If a change is too big for one branch, split it into independently correct
increments that each reach local `main` before the next begins.

## Hard rules

The contract is `docs/engineering-contract.md`; read it before touching the
sim, the queries, the store or a screen. Where the code falls short, the
code is wrong, not the rule. Known violations are listed, one entry each,
in `docs/contract-exceptions.md` (rule 87): new code never adds to one,
and the deliverable that fixes an entry deletes it. The key owning rule references are:

1. [No partial truth — rule 1](docs/engineering-contract.md#1-no-partial-truth).
2. [Determinism — rule 2](docs/engineering-contract.md#2-determinism-is-a-compatibility-promise)
   and [core purity — rule 6](docs/engineering-contract.md#6-the-simulation-core-is-pure).
3. [Import direction — rule 5](docs/engineering-contract.md#5-imports-point-down-only).
4. [Mutation boundary — rule 7](docs/engineering-contract.md#7-commands-are-the-only-mutation-boundary)
   and [failure atomicity — rules 11–13](docs/engineering-contract.md#11-commands-are-failure-atomic).
5. [Frontend/query/parser boundaries — rules 8–10](docs/engineering-contract.md#8-queries-are-the-only-read-boundary-for-frontends)
   and [view eligibility — rule 34](docs/engineering-contract.md#34-view-eligibility-is-informative-not-authoritative).
6. [Rule ownership — rule 3](docs/engineering-contract.md#3-one-rule-one-owner-one-result)
   and [location context — rules 20–22](docs/engineering-contract.md#20-a-game-rule-is-one-named-function).
7. [Named numbers — rule 24](docs/engineering-contract.md#24-a-number-appears-once),
   [money, time and IDs — rules 54–56](docs/engineering-contract.md#54-money-and-multipliers-are-integer-quantities),
   [citations — rule 59](docs/engineering-contract.md#59-rule-data-cites-its-source)
   and [skills — rule 60](docs/engineering-contract.md#60-skills-follow-mekhq-semantics).
8. [Persistence, loading, saves and migrations — rules 45–51](docs/engineering-contract.md#45-every-state-field-has-a-persistence-classification).
9. [Focused tests, regressions and failure injection — rules 67–69](docs/engineering-contract.md#67-every-rule-module-carries-focused-tests).
10. [The exact gate and smoke triggers — rule 72](docs/engineering-contract.md#72-the-gate-is-complete).

## Unresolved project policy

No additional project policy is chosen by this migration. Questionnaire matters
not settled by existing project documents remain unresolved, including any
additional privacy, secret-handling, security, or performance requirements.
Existing contract requirements continue to apply; absence of an additional
policy is not an exemption. John resolves open product or architectural-policy
choices through the workflow. The approved baseline is already integrated; do
not repeat bootstrap or infer authority to commit directly to `main`.
