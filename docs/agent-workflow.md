# Agent workflow

IRON LEDGER uses one thin long-lived dispatcher and six short-lived worker roles.
Tools share this process, `AGENTS.md`, and immutable artifacts, not session state.
John approves exact plans, amendments, and integration of exact accepted
commits. Agents never perform Git remote operations.

## Completed transitions

The scaffold-alignment migration (seven roles, `.ai/plans/`) and the
autonomous-delivery amendment are integrated into local `main` and active. Their
historical snapshots and consumed correction rounds stand as recorded; neither
grants retroactive rounds or acceptance. Ordinary project authorization and
runtime permission remain distinct: a tool, sandbox, or hook that blocks an
authorized operation is reported, not bypassed.

## Ordinary approval and continuous dispatch

Ordinary delivery has two user decisions: approval of the complete exact plan
hash, then approval to integrate the exact accepted commit. Exact-plan approval
authorizes freezing the unchanged draft, creating the named local branch from
the exact base, planned edits, required verification, staging only intended
paths, local commits and in-scope corrections through the designated roles.
Protected governance changes must be explicitly named in a governance plan;
an application plan never authorizes incidental policy edits. Plan approval
never authorizes integration in advance.

After approval, the coordinator verifies each handoff, dispatches the next
fresh authorized worker, waits for and monitors its task, relays findings and
dispositions verbatim, and continues the same approved delivery until accepted
and ready for the integration decision. It gives progress updates and does not
end its turn merely after dispatch or ask John to continue an already authorized
step. It remains read-only and does not inspect application code or write plans.
It cannot select unrelated work or start another branch.

A host suspension or runtime limit can stop continuous execution. Record the
exact artifact, base, branch, revision, findings, correction history, completed
checks and pending handoff so evidence-based resumption of unchanged scope does
not require renewed project approval. Do not promise execution after the host
stops the session.

## Roles

| Agent | Lifetime | Authority |
| --- | --- | --- |
| `coordinator` | one interactive session | Dispatches and verifies handoffs; never plans or writes |
| `bootstrapper` | one governance draft, freeze, or commit operation | Creates only the initial project-specific baseline under the bootstrap guide |
| `planner` | one draft or freeze operation | Inspects and writes only ignored plan artifacts |
| `branch-bootstrap` | one approved branch | Creates the branch from local `main`; never edits or commits |
| `implementer` | one approved task | Edits, verifies, commits, or corrects one approved plan |
| `reviewer` | one committed revision | Independently reviews; never writes |
| `integrator` | one accepted exact revision | Read-only checks and approved local fast-forward/delete; never edits |

`AGENTS.md`, `docs/engineering-contract.md`, and this workflow supply shared
project authority. Claude's project-local adapters are in `.claude/agents/`;
Codex role configurations are in `.codex/agents/`. Claude's tracked settings
supply permissions, and local overrides and hooks can affect enforcement.
Verify effective role selection and permissions before dispatch. Do not edit
user-level profiles, memory, local overrides or external hooks in this migration.

## Git remote  restrictions

Git remote operations remain John-owned and outside
agent authority. Agents must not fetch, pull, push, change Git remotes, or
perform other Git remote operations. Read-only web and source research
is permitted when it is within the dispatched task and role and
allowed by effective instructions and existing permissions. This grants
no external write, publishing, or messaging authority and does not bypass
sandbox or network restrictions. Research permission does not expand a
role's file-write or Git authority.

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
- `.ai/plans/approved/<original-name>-a<n>.md` is an immutable, approved
  amendment to that snapshot (see Scope, completion work, and amendments).

The coordinator hashes the draft before presenting it. Approval applies to that
exact SHA-256. A fresh planner freezes it byte-for-byte only after the
coordinator confirms the hash has not changed. The coordinator independently
checks the approved snapshot and gives its path and hash to every downstream
worker. A mutable draft, pasted plan, or conversation summary is not an
implementation handoff. Every complete plan states the outcome, the acceptance
criteria that prove it (behavior and tests), the boundaries that must not
change, the exact base revision, branch and creation command, ordered changes,
expected files, documentation, gate, risks and non-goals. Approval binds the
outcome and boundaries under the ordinary policy above; the expected file list
guides review and is not an allowlist.

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

Historical plans relocated from `.claude/plans/` keep their filenames and bytes;
relocation conferred no approval. New freezes include the short plan hash.

## Delivery

1. A fresh planner inspects the repository and writes one complete draft. The
   coordinator presents that plan and its SHA-256; John approves or revises it.
2. After approval, a fresh planner verifies the approved draft hash and freezes
   a byte-identical snapshot under `.ai/plans/approved/`.
3. The coordinator and a fresh `branch-bootstrap` verify a clean worktree,
   current local `main`, exact approved base, and no other local implementation
   branch. A branch/name collision stops delivery. Branch-bootstrap creates only
   the snapshot's approved branch with its exact creation command under plan
   authorization; honor any required effective runtime permission.
4. Dispatch names implementation, correction, or continuation mode and provides
   the immutable artifact path, full SHA-256, branch and exact base revision.
   A fresh `implementer` verifies the snapshot path, hash, metadata and branch,
   then confirms a clean worktree and exact expected branch/base before editing,
   runs the applicable full gate, inspects the full diff, stages only intended
   files, and commits under exact-plan authorization, subject to required runtime
   permissions. A failed gate blocks review acceptance and integration; repair
   of an in-scope implementation defect remains authorized. Never weaken a rule
   or borrow a file from another branch to pass. For an
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
   governance/tracker files. A material finding follows the amendment or
   new-draft path in Scope, completion work, and amendments.

   For a committed change to a decomposition module, the fresh reviewer inspects
   every new inline import, identifies any duplicate of a file-scope import, and
   assesses whether it supports substantive decomposition. Inline imports remain
   permitted when justified by the code; this review is evidence-based, not a
   categorical prohibition. For each changed function over approximately 100
   lines, the review records whether it remains cohesive and legible or needs
   decomposition by responsibility.

   The reviewer report gives every finding concrete evidence and exactly one
   explicit disposition: `blocking`, `approved follow-up`, or `non-issue`. A
   `blocking` finding prevents acceptance and names its path: in-scope
   correction (including missing completion work), amendment, or new draft. An `approved follow-up` finding identifies the approved
   artifact or subsequent approved work that owns it; it is not silently
   accepted as resolved. A `non-issue` finding states the inspected evidence
   that refutes the concern. Only an empty finding list may report no findings.
6. An in-scope blocking finding automatically returns to a fresh implementer
   in correction mode with the same snapshot, followed by a fresh exact-commit
   reviewer. Repeat as many rounds as needed with no fixed numerical limit or
   renewed approval solely because of the round number. Every changed revision
   must pass the applicable gate and receive fresh review; prior acceptance
   never transfers. Track all findings, dispositions, revisions and correction
   history truthfully. Repairing implementation to meet an already approved
   requirement is not itself a scope expansion.

   A bounded material gap takes an amendment; only a change to the outcome,
   behavior, or architecture itself requires a revised complete draft. Report
   real blockers, including unavailable effective authority, unresolved policy
   choices and unresolvable external prerequisites. Never replace a blocker
   with an arbitrary retry cap, waived finding, weakened gate or silently
   expanded scope.

7. After acceptance and completion of the contract delivery checklist, the
   coordinator presents the immutable artifact path and full hash, original
   main base, branch, accepted full commit hash, gate evidence, all findings and
   dispositions, and the exact local checkout/fast-forward/delete sequence.
   John's explicit approval covers that one integration operation, including
   deletion of the successfully integrated branch. Acceptance, passing tests,
   silence and plan approval cannot substitute for integration approval.

   A fresh integrator receives that approval record and verifies the artifact,
   accepted exact commit, unchanged approved base and branch, clean worktree
   and fast-forward ancestry before mutation. It edits and stages nothing;
   it runs only the approved `git checkout main`, `git merge --ff-only <branch>`
   and `git branch -d <branch>` sequence. Verify main at the accepted commit
   before deletion. Stop on mismatch, failed command or unexpected state.
   Changing the accepted commit or integration target invalidates approval.
   Do not create separate project approvals for unchanged steps of this one
   operation; honor any required runtime permissions.

   If interrupted, first verify which steps actually completed and perform only
   the still-authorized remainder. Never repeat blindly, reset state or infer
   approval for another commit or branch. Integrate only the exact gated and
   reviewed commit.
8. Agents stop. John pushes local `main` after closing the agent session.

## Scope, completion work, and amendments

Approval binds an outcome, not a file list. A change is material only when it
alters approved behavior, architecture, a public API or save format, a contract
rule, governance, or product policy, or adds a dependency or external service.
Nothing else is material.

Completion work is in scope by default: whatever the approved outcome needs to
pass the gate and satisfy the contract, including tests for changed code (rules
67-69), fixtures, documentation lines, build or lint repairs, and mechanical
registration of plan-named files in `docs/verify-contract.sh` layer tables,
`docs/verify-contract.baseline`, or `docs/contract-exceptions.md` where the
contract already requires the entry. The implementer does it without asking and
lists each item under "Incidental changes" in its handoff. The reviewer confirms
each item is necessary and not material. Missing completion work is a blocking
in-scope finding, never a new plan. Mechanical registration is not a governance
change; altering what a gate checks still is.

A material gap that is small and bounded takes an amendment, not a new draft.
A fresh planner writes a delta-only amendment to `.ai/plans/draft.md`: what
changes, why, and which acceptance criteria or boundaries change, one page at
most. The coordinator presents its SHA-256, John approves, and a fresh planner
freezes it as `.ai/plans/approved/<original-name>-a<n>.md`. Work continues on
the same branch in continuation mode under the original artifact plus its
amendments. No repository re-inspection, restatement of the original, or new
branch. A full new draft is required only when the outcome, behavior, or
architecture itself changes.

A planner never writes a non-goal that contradicts a contract requirement, such
as excluding tests the contract requires for changed code or omitting gate
registration for a new file. Such a non-goal is a planning defect; completion
work overrides it and the reviewer reports it.

Historical P2f and P2g deliveries keep their recorded conditions, consumed
rounds, artifacts and acceptance evidence unchanged.

## Review acceptance and continuation

At handoff, the coordinator records and relays the reviewer's findings and
stated dispositions verbatim. It may verify that every finding has a
disposition, but cannot reinterpret, collapse, omit, downgrade, or report a
finding as no findings. It cannot independently report no findings. Acceptance
requires a reviewer report with no blocking findings and an explicit disposition
for every finding.

An approved follow-up remains a finding and is never downgraded to no findings.

A partial implementer is resumed by task ID. If its session no longer exists,
continuation mode verifies the same approved artifact and inspects the existing
branch and diff before proceeding. It never restarts ordinary implementation on
a dirty branch.

## Agent-applied local work

Authorized agents perform all approved local file edits and fixes, including
amendments to governance files explicitly named in an approved immutable plan.
John supplies product and policy decisions, exact-hash plan approval, exact
accepted-commit integration approval, and any required runtime permissions.
No plan or handoff may require John to edit files, apply a patch, or stage
changes by hand. An agent that lacks authority reports
the specific boundary and obtains an authorized role; it does not transfer file
application to John.

A fresh implementer applies named-file governance amendments using existing
effective governance authority. The coordinator remains read-only, planners
write only plan artifacts, and reviewers and integrators never implement. A
worker must not treat edits to tracked role configuration as a change to its
own loaded authority or use the proposed authority during that invocation.
A governance amendment uses already-effective authority for its local commit
and fresh review.

Effective role activation is verified separately from file contents. If an
available role or launcher cannot activate the approved instructions, stop and
report that runtime prerequisite; do not ask John to apply the files, modify a
global profile, or bypass the restriction.

A governance-only amendment changes no application code, grants no implicit
extra correction, and is reviewed as its own delta; known blocking application
findings remain blocking. Do not integrate an incomplete branch to activate a
governance amendment.

## Boundaries

The coordinator asks John only for product or architectural-policy choices not
settled by durable project sources, approval of an exact plan or amendment
hash, exact accepted-commit integration approval, and any actually required
runtime permissions. Completion work and in-scope corrections are never sent to
John as decisions. Technical choices belong to the
fresh planner. Historical approval, remote refs, stale patches, imports, module
ownership, helper shape, test placement, tracker wording, and rule-76 registry
treatment are not sent to John as decision menus.

Normal implementation does not alter governance, contracts, what gates check,
CI, agent configuration, or memory; mechanical registration of plan-named files
in gate tables and registries is completion work, not a governance change.
Governance mode may change only files named by an explicitly approved
governance plan.

Permissions reduce accidental authority but are not a sandbox against arbitrary
programs launched through Bash. Durable controls are the hashed approved
artifact, executable gates, fresh exact-commit review, fast-forward-only local
integration, and John retaining all Git remote authority.

Branch creation belongs only to branch-bootstrap; commits only to implementer;
local integration and branch deletion only to integrator.
Never commit directly to `main`. Ordinary branch creation, staging and commits
are authorized by exact-plan approval; integration and branch deletion require
the single exact integration approval. Any actually required runtime
permissions remain binding. Integrator has no implementation, correction,
bootstrap or Git remote authority. Governance mode is bounded by the explicitly
approved named-file scope; ordinary implementation cannot change what contracts
or gates require, CI, agent configuration, project instructions or memory,
though mechanical registration of plan-named files in gate tables and
registries is completion work. No role may fetch, pull, push, change Git
remotes.
