# Agent workflow

IRON LEDGER uses one long-lived read-only coordinator and three short-lived
workers. John approves plans and local git writes. Claude never uses GitHub or
a remote.

## Roles

| Agent | Lifetime | Authority |
| --- | --- | --- |
| `coordinator` | one interactive session | Reads, brainstorms, plans, and delegates; never writes |
| `branch-bootstrap` | one approved branch | Creates the branch from local `main`; never edits or commits |
| `implementer` | one approved task | Edits, verifies, commits, or corrects on the prepared branch |
| `reviewer` | one committed revision | Independently reviews; never writes |

The four user-level agents are portable across repositories. IRON LEDGER's
`CLAUDE.md`, contract, and `.claude/settings.json` supply project-specific
rules and permissions.

## Start

From the repository root:

```sh
claude --agent coordinator
```

Describe work normally. The coordinator inspects the repository and scales its
process to the task. An exact edit gets a brief plan; normal work gets a focused
implementation plan; ambiguous work is brainstormed interactively before the
same coordinator writes the plan. There is no mandatory brainstorm or planning
subagent.

## Delivery

1. The coordinator presents one recommended plan. John approves or revises it.
2. A fresh `branch-bootstrap` creates the approved branch from local `main`
   through a permission prompt and reports its name and base commit.
3. A fresh `implementer` verifies that handoff, edits, runs the gate, and
   commits through a permission prompt.
4. A fresh `reviewer` checks the exact commit against the approved plan and
   project contract.
5. Confirmed findings inside approved scope go to an implementer in correction
   mode. A material behavior, architecture, contract, governance, or scope
   change requires a revised plan and John's approval. Every correction gets a
   fresh review.
6. After acceptance, the coordinator verifies the reviewed commit,
   fast-forwards local `main`, and deletes the local branch through permission
   prompts.
7. Claude stops. John pushes local `main` after closing Claude Code.

A partial implementer is resumed by task ID. If its session no longer exists,
continuation mode inspects the existing branch and diff before proceeding. It
never restarts ordinary implementation on a dirty branch.

## Boundaries

The coordinator asks John only for product or architectural-policy choices not
settled by durable project sources, plan approval, material plan revisions, and
git permission prompts. Technical choices belong to the coordinator. Historical
approval, remote refs, stale patches, imports, module ownership, helper shape,
test placement, tracker wording, and rule-76 registry treatment are not sent to
John as decision menus.

Normal implementation does not alter governance, contracts, gates, CI, agent
configuration, or memory. Governance mode may change only files named by an
explicitly approved governance plan.

Permissions reduce accidental authority but are not a sandbox against arbitrary
programs launched through Bash. Durable controls are the approved scope,
executable gates, fresh exact-commit review, fast-forward-only integration, and
John retaining all remote authority.
