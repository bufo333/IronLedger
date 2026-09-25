# Agent workflow

IRON LEDGER uses one interactive coordinator and short-lived specialist
subagents. John makes every scope decision and approves each git write. The
agents never use GitHub or a remote.

## Roles

| Agent | Scope | Writes? | Output |
| --- | --- | --- | --- |
| `coordinator` | user-level | no | Routes handoffs and asks John for decisions |
| `brainstormer` | user-level | no | Options, tradeoffs, and a decision brief |
| `planner` | user-level | no | An implementation plan or fresh committed-diff review |
| `implementer` | project | source, tests, local git | One committed branch or an approved local integration |

The user-level configuration also provides a generic `implementer`, making the
workflow portable to other repositories. This project's closer definition
overrides it with IRON LEDGER's contract and gate requirements.

Each subagent starts with its own context. The coordinator passes only the
selected direction, approved plan, accepted findings, or reviewed commit that
the next phase needs. It never passes an entire transcript by default.

## Start

From the repository root, start one interactive session:

```sh
claude --agent coordinator
```

Describe the idea normally. The coordinator invokes the specialists and keeps
the handoffs in the same conversation; John does not copy text between Claude
Code sessions.

## Workflow

1. **Brainstorm.** A fresh `brainstormer` reads relevant code and presents
   verified facts, options, tradeoffs, and decisions. John chooses the
   direction.
2. **Plan.** A fresh `planner` receives only the chosen direction and verifies
   the repository independently. John reviews and explicitly approves the
   detailed plan.
3. **Implement.** A fresh `implementer` receives the exact approved plan. It
   proposes a branch through the `git checkout -b` permission prompt, edits
   only approved scope, runs the gate, and proposes its commit through the
   `git commit` permission prompt.
4. **Review.** A new `planner` invocation reviews the complete committed diff
   against the approved plan, architecture, and coding contract. It is never
   the planning invocation reused with old context.
5. **Correct.** John accepts or rejects each finding. A fresh `implementer`
   receives only accepted findings, commits corrections after approval, and
   returns to a fresh review.
6. **Integrate.** A fresh `implementer` receives the accepted review and exact
   reviewed commit. It confirms a clean worktree and fast-forward ancestry,
   then requests approval for the local fast-forward merge and local branch
   deletion.
7. **Stop.** Claude performs no remote operation. John pushes local `main`
   after closing Claude Code for the day.

Permission denial stops the current phase. An agent does not rename a branch,
rewrite a commit message, use another command form, or broaden scope to evade
a denial.

## Controls

- `CLAUDE.md` and `docs/coding-contract.md` define project behavior and the
  delivery rules.
- `.claude/settings.json` denies remote and GitHub commands, disables bypass
  mode, and asks for branch creation, commits, local fast-forward merges, and
  branch deletion.
- `.claude/agents/implementer.md` limits implementation and integration work.
- `docs/verify-contract.sh`, tests, smoke scripts, and packaging checks enforce
  the executable contract.
- A fresh planner review catches plan drift, wrong ownership, guessed facts,
  and attempts to satisfy metrics without reducing architectural complexity.

Permissions and prompts reduce accidental authority; they are not a sandbox
against arbitrary programs launched through Bash. The durable controls are a
small approved scope, executable gates, exact-commit review, fast-forward-only
integration, and John retaining all remote authority.

## Governance

Normal implementation agents do not change `CLAUDE.md`, architecture,
contracts, exception registries, contract checks, CI, `.claude/`, or memory.
John must explicitly dispatch governance work, and review it like any other
change.
