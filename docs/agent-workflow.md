# Agent workflow

IRON LEDGER uses one thin long-lived dispatcher and four short-lived workers.
John approves plans and local git writes. Claude never uses GitHub or a remote.

## Roles

| Agent | Lifetime | Authority |
| --- | --- | --- |
| `coordinator` | one interactive session | Dispatches and verifies handoffs; never plans or writes |
| `planner` | one draft or freeze operation | Inspects and writes only ignored plan artifacts |
| `branch-bootstrap` | one approved branch | Creates the branch from local `main`; never edits or commits |
| `implementer` | one approved task | Edits, verifies, commits, corrects, or locally integrates |
| `reviewer` | one committed revision | Independently reviews; never writes |

The five user-level agents are portable across repositories. IRON LEDGER's
`CLAUDE.md`, contract, and `.claude/settings.json` supply project-specific rules
and permissions.

## Start

From the repository root:

```sh
claude --agent coordinator
```

Describe work normally. The coordinator verifies the repository handoff and
dispatches a fresh planner. It does not inspect application code or accumulate
planning context itself.

## Plan artifacts

Planning state is local and ignored by Git under `.claude/plans/`:

- `.claude/plans/draft.md` is mutable. Each fresh draft planner may overwrite
  it after independently inspecting the current repository.
- `.claude/plans/approved/<branch-slug>-<base-short-sha>.md` is the immutable
  snapshot of exactly what John approved. An approved path is never overwritten
  or reused.

The coordinator hashes the draft before presenting it. Approval applies to that
exact SHA-256. A fresh planner freezes it byte-for-byte only after the
coordinator confirms the hash has not changed. The coordinator independently
checks the approved snapshot and gives its path and hash to every downstream
worker. A mutable draft, pasted plan, or conversation summary is not an
implementation handoff.

## Delivery

1. A fresh planner inspects the repository and writes one complete draft. The
   coordinator presents that plan and its SHA-256; John approves or revises it.
2. After approval, a fresh planner verifies the approved draft hash and freezes
   a byte-identical snapshot under `.claude/plans/approved/`.
3. A fresh `branch-bootstrap` creates the snapshot's branch from its exact local
   `main` base through a permission prompt.
4. A fresh `implementer` verifies the snapshot path, hash, metadata and branch,
   then edits, runs the gate, and commits through a permission prompt.
5. A fresh `reviewer` verifies the same snapshot and checks the exact commit
   against it and the current project contract.
6. Confirmed findings inside approved scope go to an implementer in correction
   mode with the same snapshot. A material behavior, architecture, contract,
   governance, or scope change requires a new draft, hash, approval and frozen
   snapshot. Every correction gets a fresh review.
7. After acceptance, the coordinator invokes an implementer in integration
   mode. It verifies the artifact and reviewed commit, fast-forwards local
   `main`, and deletes the local branch through permission prompts.
8. Claude stops. John pushes local `main` after closing Claude Code.

A partial implementer is resumed by task ID. If its session no longer exists,
continuation mode verifies the same approved artifact and inspects the existing
branch and diff before proceeding. It never restarts ordinary implementation on
a dirty branch.

## Boundaries

The coordinator asks John only for product or architectural-policy choices not
settled by durable project sources, approval of an exact plan hash, material
plan revisions, and git permission prompts. Technical choices belong to the
fresh planner. Historical approval, remote refs, stale patches, imports, module
ownership, helper shape, test placement, tracker wording, and rule-76 registry
treatment are not sent to John as decision menus.

Normal implementation does not alter governance, contracts, gates, CI, agent
configuration, or memory. Governance mode may change only files named by an
explicitly approved governance plan.

Permissions reduce accidental authority but are not a sandbox against arbitrary
programs launched through Bash. Durable controls are the hashed approved
artifact, executable gates, fresh exact-commit review, fast-forward-only local
integration, and John retaining all remote authority.
