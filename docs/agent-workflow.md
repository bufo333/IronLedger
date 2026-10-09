# Agent workflow

IRON LEDGER uses one thin long-lived dispatcher and six short-lived worker roles.
Tools share this process, `AGENTS.md`, and immutable artifacts, not session state.
John approves plans and local Git writes. Agents never use GitHub or a remote.

## Migration transition

The seven roles and `.ai/plans/` activate for subsequent tasks only after this
migration is accepted and integrated into local `main`. The scaffold-alignment
migration itself uses both byte-identical immutable snapshots named in its
approved artifact and the previous five-role workflow. Its integration belongs
to a fresh implementer with current integration-mode authority, or to John if
that worker is unavailable. Do not activate the new integrator early. Preserve
the legacy transition snapshot at its original ignored path through review and
integration; it may remain as a historical compatibility copy afterward.

## Roles

| Agent | Lifetime | Authority |
| --- | --- | --- |
| `coordinator` | one interactive session | Dispatches and verifies handoffs; never plans or writes |
| `bootstrapper` | one governance draft, freeze, or commit operation | Creates only the initial project-specific baseline under the bootstrap guide |
| `planner` | one draft or freeze operation | Inspects and writes only ignored plan artifacts |
| `branch-bootstrap` | one approved branch | Creates the branch from local `main`; never edits or commits |
| `implementer` | one approved task | Edits, verifies, commits, or corrects one approved plan |
| `reviewer` | one committed revision | Independently reviews; never writes |
| `integrator` | one accepted exact revision | Read-only checks and prompted local fast-forward/delete; never edits |

`AGENTS.md`, `docs/engineering-contract.md`, and this workflow supply shared
project authority. Claude's project-local adapters are in `.claude/agents/`;
Codex role configurations are in `.codex/agents/`. Claude's tracked settings
supply permissions, and local overrides and hooks can affect enforcement.
Verify effective role selection and permissions before dispatch. Do not edit
user-level profiles, memory, local overrides or external hooks in this migration.

## Governance bootstrap

When `docs/engineering-contract.md` is absent, run only the questionnaire and
bounded baseline procedure in `docs/governance-bootstrap.md`. Dispatch a fresh
bootstrapper with recorded answers in draft, freeze, or commit mode. Exact path
and SHA-256 approval is required for every deliverable. Do not dispatch ordinary
implementation until the approved baseline is locally committed. Existing game
history and contract protections must not be reset; unresolved commit authority
requires an explicitly approved procedure. The baseline for this migration is
already integrated and must not be repeated.

## Start

From the repository root:

```sh
claude --agent coordinator
```

Describe work normally. The coordinator verifies the repository handoff and
dispatches a fresh planner. It does not inspect application code or accumulate
planning context itself.

## Plan artifacts

Planning state is local and ignored by Git under `.ai/plans/`:

- `.ai/plans/draft.md` is mutable. Each fresh draft planner may overwrite
  it after independently inspecting the current repository.
- `.ai/plans/approved/<branch-slug>-<base-short-sha>-<plan-short-sha>.md` is the immutable
  snapshot of exactly what John approved. An approved path is never overwritten
  or reused.

The coordinator hashes the draft before presenting it. Approval applies to that
exact SHA-256. A fresh planner freezes it byte-for-byte only after the
coordinator confirms the hash has not changed. The coordinator independently
checks the approved snapshot and gives its path and hash to every downstream
worker. A mutable draft, pasted plan, or conversation summary is not an
implementation handoff.

For TODO-backed tracker reconciliation, the planner inspects current local
`main`, identifies the exact completed item or group and its reachable commit
evidence, and drafts only the corresponding deletion or wording repair. The
plan names that exact item or group and declares every required TODO, registry,
or baseline deletion. Uncommitted work, another branch, remote state, and a
conversation claim are not completion evidence. Reconciliation is an explicit
approved repair for stale entries, not unrelated-scope cleanup.

Before dispatching tracker-reconciliation planning or presenting its hash, the
coordinator verifies the draft artifact is present, its base is current local
`main`, its cited commits are reachable from that base, and its proposed TODO
removal is limited to work completed by those commits. The coordinator does not
plan or inspect application code for this verification. If the evidence, tracker
state, or approved scope does not agree, it requests a revised draft rather
than dispatching implementation.

Historical plans moved from `.claude/plans/` retain their filenames, bytes and
old citations. The 152 approved and 17 named root drafts map to matching relative
paths under `.ai/plans/`; the former root `draft.md` is `legacy-draft.md` to preserve
both drafts. A per-file SHA-256 manifest and independent ignored backup record
the migration mapping. Historical approved filenames are grandfathered; new
freezes include the short plan hash. Relocation confers no new task approval or
review acceptance. Both ignore rules remain for transition safety.

## Delivery

1. A fresh planner inspects the repository and writes one complete draft. The
   coordinator presents that plan and its SHA-256; John approves or revises it.
2. After approval, a fresh planner verifies the approved draft hash and freezes
   a byte-identical snapshot under `.ai/plans/approved/`.
3. The coordinator and a fresh `branch-bootstrap` verify a clean worktree,
   current local `main`, exact approved base, and no other local implementation
   branch. A branch/name collision stops delivery. Branch-bootstrap creates only
   the snapshot's approved branch through the exact-command permission prompt.
4. Dispatch names implementation, correction, or continuation mode and provides
   the immutable artifact path, full SHA-256, branch and exact base revision.
   A fresh `implementer` verifies the snapshot path, hash, metadata and branch,
   then confirms a clean worktree and exact expected branch/base before editing,
   runs the applicable full gate, inspects the full diff, stages only intended
   files, and commits through a permission prompt. A failed gate stops delivery;
   never weaken a rule or borrow a file from another branch to pass. For an
   approved tracker-reconciliation artifact, it also re-verifies the approved
   base, cited commits, and current TODO wording; changes only approved
   tracker/governance files; removes only the verified completed item or group;
   and makes the approved TODO completion update. It stops for a new draft if
   the TODO has moved, the evidence is not on local `main`, or the change would
   alter contract, gate, CI, or agent-configuration policy.
5. A fresh `reviewer` verifies the same snapshot and checks the exact committed
   revision against it and the current project contract. For tracker
   reconciliation, it confirms every TODO deletion has its cited reachable
   local-main completion commit, no unfinished sibling item or group was
   removed or reordered, and the exact commit is limited to approved
   governance/tracker files. A material scope or policy finding follows the
   new-draft path.

   For a committed change to a decomposition module, the fresh reviewer inspects
   every new inline import, identifies any duplicate of a file-scope import, and
   assesses whether it supports substantive decomposition. Inline imports remain
   permitted when justified by the code; this review is evidence-based, not a
   categorical prohibition. For each changed function over approximately 100
   lines, the review records whether it remains cohesive and legible or needs
   decomposition by responsibility.

   The reviewer report gives every finding concrete evidence and exactly one
   explicit disposition: `blocking`, `approved follow-up`, or `non-issue`. A
   `blocking` finding prevents acceptance and follows the correction or
   new-draft path. An `approved follow-up` finding identifies the approved
   artifact or subsequent approved work that owns it; it is not silently
   accepted as resolved. A `non-issue` finding states the inspected evidence
   that refutes the concern. Only an empty finding list may report no findings.
6. Confirmed findings inside approved scope go to an implementer in correction
   mode with the same snapshot. A material behavior, architecture, contract,
   governance, or scope change requires a new draft, hash, approval and frozen
   snapshot. Allow at most three in-scope correction rounds with a fresh
   implementer and a fresh exact-commit reviewer each round. Every changed commit
   must pass the applicable gate and receive fresh review; previous acceptance
   does not transfer. After three rounds, stop and escalate to John rather than
   continue corrections. Material expansion always requires a new approved plan.

   **Bounded P2f escalation resolution.** For
   `sim/p2f-artillery-acquisition`, preserve the three consumed correction rounds
   ending at `69242f5bd766e030a7af75afbb9995eed55e2673` and original main base
   `3c9db755f764b42534d146451f67ded4c839c463`. An agent-applied governance-only
   amendment on that branch may be reviewed separately without accepting or
   integrating its blocked application changes. After that amendment is
   committed and its exact governance delta passes fresh review, fresh roles
   may activate its explicitly approved authority on the existing branch.
   Verify actual effective instructions; a tracked configuration edit alone
   does not activate authority.

   A subsequently approved and frozen complete P2f plan may authorize one
   additional correction confined to the complete-text enum decoders in
   `src/persist/artillery_store.zig` and `src/persist/store.zig`, their owning
   regressions, and the full gate. That plan must name the exact governance
   commit as its correction starting revision, retain the original main base,
   all prior feature requirements, and the exhausted correction history.
   This allowance is used at most once, is not a reset, and does not renew on
   another plan, session, interruption, or branch name. An interrupted worker
   resumes the same bounded task. Any blocking finding after its resulting
   commit stops delivery and is escalated again; no further correction is
   authorized here. Material expansion requires a new approved plan.

   Final acceptance requires a fresh exact-commit review of the entire branch,
   including governance and P2f, with all findings explicitly disposed and no
   blocking finding. The full applicable gate, unchanged original main base,
   delivery checklist, and separate prompted integration remain mandatory.
   This resolution permits no early merge, automatic retry loop, remote access,
   role substitution, or override of higher-priority runtime instructions.

7. After acceptance, the coordinator invokes a fresh integrator. It verifies the
   artifact, accepted exact commit, expected branch, clean worktree, unchanged base and fast-forward ancestry.
   It makes no edits, stages nothing and runs only prompted `git checkout main`,
   `git merge --ff-only <branch>` and `git branch -d <branch>` mutations. A stale
   review/base or branch collision stops the handoff. Answer the contract's
   delivery checklist before integration; integrate only the exact gated and
   reviewed commit.
8. Agents stop. John pushes local `main` after closing the agent session.

At handoff, the coordinator records and relays the reviewer's findings and
stated dispositions verbatim. It may verify that every finding has a
disposition, but cannot reinterpret, collapse, omit, downgrade, or report a
finding as no findings. It cannot independently report no findings. Acceptance
requires a reviewer report with no blocking findings and an explicit disposition
for every finding.

For this migration only, acceptance requires a fresh report with no findings,
satisfying the configured Codex reviewer's stricter acceptance wording. An
approved follow-up remains a finding and must never be downgraded to no findings.
A future conflict between adapter acceptance policies requires a new approved
plan; it does not silently alter the preserved disposition policy above.

A partial implementer is resumed by task ID. If its session no longer exists,
continuation mode verifies the same approved artifact and inspects the existing
branch and diff before proceeding. It never restarts ordinary implementation on
a dirty branch.

## Agent-applied local work

Authorized agents perform all approved local file edits and fixes, including
amendments to governance files explicitly named in an approved immutable plan.
John supplies product and policy decisions, exact-hash approvals, and required
command permission approvals. No plan or handoff may require John to edit files,
apply a patch, or stage changes by hand. An agent that lacks authority reports
the specific boundary and obtains an authorized role; it does not transfer file
application to John.

A fresh implementer applies named-file governance amendments using existing
effective governance authority. The coordinator remains read-only, planners
write only plan artifacts, and reviewers and integrators never implement. A
worker must not treat edits to tracked role configuration as a change to its
own loaded authority or use the proposed authority during that invocation.
The governance amendment receives a prompted commit and fresh review before
amended authority is used. Effective role activation is verified separately
from file contents. If an available role or launcher cannot activate the
approved instructions, stop and report that runtime prerequisite; do not ask
John to apply the files, modify a global profile, or bypass the restriction.

The ordinary correction limit remains in force. A governance-only amendment
after escalation may proceed only under already-effective authority and an
explicitly approved named-file plan. It changes no application code, grants
no implicit extra correction, and neither consumes nor resets the exhausted
application correction count. Its review certifies only the governance delta;
known blocking application findings remain blocking. Do not integrate an
incomplete branch to activate its governance amendment.

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

Branch creation belongs only to branch-bootstrap; commits only to implementer;
local integration and branch deletion only to integrator after the transition.
Never commit directly to `main`. Every Git mutation above needs John's explicit
permission prompt showing the exact command. Integrator has no implementation,
correction, bootstrap or remote authority. Governance mode is bounded by the
explicitly approved named-file scope; ordinary implementation cannot change
contracts, gates, registries, CI, agent configuration, project instructions or
memory. No role may fetch, pull, push, change remotes, or use GitHub.
