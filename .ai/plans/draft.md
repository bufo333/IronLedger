# Proposal: preserve IRON LEDGER governance while adopting scaffold structure

Status: draft mode, proposal only; NOT an executable implementation handoff.
Inspection base: local main and HEAD both `9b5d2532a5dfe1f10132ab0ff9c06c226a410c16`.
Proposed migration branch: `governance/scaffold-alignment`.
Initial worktree: clean; current branch main; only local branch main.
Reference scaffold: `/Users/john/Development/agent-scaffold`, inspected locally.
Authorized present action: inspect and overwrite only `.ai/plans/draft.md`.
Proposed work below requires explicit approval and resolution of the bootstrap prerequisite.

## Outcome and scope

Preserve all game contract rules, reviewer checks, checklist items, commands,
architecture ownership and game-specific workflow safeguards. Make shared
instructions and seven roles agree across Codex and Claude, and migrate local
planning artifacts to `.ai/plans/`. This is structural governance alignment,
not adoption of the scaffold application's contract or future permission target.
Standalone OpenCode and OpenRig installation are optional later work and are
excluded from this proposal. Codex TOMLs already exactly match the scaffold;
no Codex edits are presently needed. Architecture stays `ARCHITECTURE.md`.

## Binding prerequisite: the bootstrap mismatch

`.codex/agents/coordinator.toml` explicitly requires bootstrap only when
`docs/engineering-contract.md` is absent and prohibits an implementer until a
user-approved baseline is committed. Both that file and `AGENTS.md` are absent;
`docs/governance-bootstrap.md` is also absent. The existing binding game workflow
uses CLAUDE.md and coding-contract.md and its five-role delivery process. These
are migration evidence, not permission to bypass the Codex bootstrap restriction.

Recommended stages:

A. Coordinator reports this conflict and records the bootstrap questionnaire
answers using the inspected scaffold guide as a proposed external reference.
Existing documents supply verified answers; John confirms the preserved baseline
and resolves any genuinely unanswered policy. Explicitly establish which guide
is binding before invoking bootstrap; the absent local guide cannot be silently
invented. This draft does not authorize that step.

B. A separately authorized bootstrapper drafts ONLY `AGENTS.md` and
`docs/engineering-contract.md` (the allowed baseline deliverables). The latter
is initially a byte-identical COPY of docs/coding-contract.md. Leave the old
contract, CLAUDE.md, workflow, adapters, ignores, CI and build files unchanged.
AGENTS.md links the current binding game workflow and ARCHITECTURE.md, identifies
the two temporary contract paths as identical bytes with one eventual owning
path, and records that migration is pending. No new architecture document is
necessary. Exact path/hash approval and the binding local baseline commit
permission are prerequisites; this planner cannot perform them. The scaffold
bootstrap's direct baseline commit conflicts with the game's never-commit-main
rule: coordinator must report and obtain explicit narrowly bounded resolution,
not assume this proposal or questionnaire waives it. If John elects instead a
migration under the existing Claude workflow, its bounded role delegation and
current immutable artifact path must be independently established; this draft
is not such a handoff.

C. After that baseline is actually committed, a fresh planner MUST redraft this
migration against the resulting exact local main revision. The present base will
be stale. John approves the revised SHA-256, a fresh planner freezes it, then
branch-bootstrap creates the approved branch. Never substitute an unknown future
base, or execute this proposal unchanged after the baseline alters main.

## Proposed migration files (after prerequisite, exact list to reverify)

- AGENTS.md; CLAUDE.md; docs/engineering-contract.md; docs/coding-contract.md
  (remove old owning file only after preserved content and all references verify).
- docs/agent-workflow.md; new docs/governance-bootstrap.md.
- .gitignore; .claude/settings.json; .github/CODEOWNERS.
- README.md; ARCHITECTURE.md.
- New project-local Claude adapters: .claude/agents/bootstrapper.md,
  branch-bootstrap.md, coordinator.md, implementer.md, integrator.md, planner.md,
  reviewer.md. No local project roles currently exist; existing workflow describes
  user-level roles. Do not edit user-level agents or memory.
- Citation-only edits to the exact files below:
- build.zig.zon
- src/domain/artillery_calculators.zig
- src/persist/lobby.zig
- src/sim/table.zig
- src/tui/keys.zig
- src/tui/layout.zig
- src/tui/screens/contracts.zig
- src/tui/screens/desk.zig
- src/tui/screens/forces.zig
- src/tui/screens/hq.zig
- src/tui/screens/lab.zig
- src/tui/screens/ledger.zig
- src/tui/screens/map.zig
- src/tui/screens/market.zig
- src/tui/screens/people.zig
- src/tui/screens/supply.zig
- docs/audit.md
- docs/clean-package.sh
- docs/contract-exceptions.md
- docs/data-fixtures.py
- docs/tui.md
- docs/verify-contract.sh

- Local ignored plan move set: all 170 existing files below `.claude/plans/`,
  preserving relative names and bytes except collision handling described below.
  These files are not commit/staging scope. Keep the newly frozen migration
  artifact under `.ai/plans/approved/` unchanged throughout.

`.claude/settings.local.json` remains a local inspection surface, not an automatic
edit target: it contains broad `Bash(git *)` allowance and an external
`$HOME/.claude/hooks/block-main-edits.py` hook. No secret, machine setting, hook,
or home-directory file enters the commit. Validate effective permissions before
claiming adapter operation; stop if local overrides or the hook defeat the
approved roles or block baseline operations. A required local policy repair gets
separate explicit scope and freshly inspected ownership.

## Ordered changes

1. Reverify branch/base, clean tracked worktree, current artifact hash and complete
   source plan inventory. Refuse symlinks, unexpected files, collisions or changed
   hashes. Capture a before manifest of relative names plus per-file SHA-256 as
   handoff evidence outside approved artifacts. Never rewrite historical plans.
2. Establish `docs/engineering-contract.md` as the sole normative owner. Retain
   every numbered rule 1–87, every reviewer check, all sections and the delivery
   checklist. Only title/citation terminology changes are allowed; reverse these
   explicit replacements in a preservation comparison to require original bytes.
   Remove coding-contract.md only when the comparison succeeds. Do not copy the
   scaffold's framework contract, open questions, unattended-Git target or gate gap.
3. Transfer project-wide CLAUDE.md instructions to AGENTS.md. Preserve project
   purpose, Zig 0.16, dependencies, stage ordering, TODO/exception precedence,
   commands, verified-facts rules, fresh-reading requirement, stop conditions,
   prohibitions on metric gaming, all Git restrictions and checklist reference.
   Replace the tool-specific Read instruction with fresh file reading applicable
   to each tool. Preserve hard-rule summaries as links with their rule numbers,
   avoiding a new independent normative copy. Replace only the integration actor
   with integrator. Thin CLAUDE.md points to AGENTS.md and project-local adapters.
   Maintain a paragraph-by-paragraph mapping from the original guide to its new
   authority/reference so deletion cannot silently lose a requirement.
4. Reconcile agent-workflow.md with seven scaffold roles and .ai paths. Preserve
   tracker completion evidence/reachable-main checks, exact approved tracker
   deletion scope, decomposition/inline-import review, approximately-100-line
   cohesion review, every finding's explicit disposition and verbatim relaying,
   continuation by task ID, no-material-expansion correction policy, clean exact
   branch/base handoffs, failed-gate stops, and one branch in flight. Separate
   integrator has only read-only checks and prompted fast-forward/delete actions.
   Add at most three in-scope correction rounds with fresh implementer/reviewer
   each round, then escalation. Existing per-plan approval and Git prompts remain.
   Preserve acceptance with no blocking findings and explicit dispositions;
   ensure adapter text permits approved follow-ups/non-issues rather than silently
   redefining acceptance as an empty report. Bootstrap guide uses questionnaire
   and allowed deliverables but explicitly respects existing project contract and
   baseline protections; new-project behavior must not reset this migrated game.
5. Add seven project-local Claude adapters based on inspected scaffold roles,
   with game safeguards linked to the shared workflow. Do not silently select
   new models merely because scaffold adapters specify them: preserve inherited
   defaults unless current verified project policy supplies a selection. Add the
   three-correction limit consistently. Validate static role boundaries against
   unchanged Codex role text. Codex reviewer permits acceptance with no findings;
   workflow must retain the existing distinction between findings and blocking
   findings and require any policy conflict to stop, not reinterpret a report.
6. Merge .claude/settings.json rather than replacing it. Preserve existing home
   memory/agent protection and sed/destructive denies. Explicitly deny fetch/pull
   as well as push/gh; retain user-owned remote/config operations. Add AGENTS.md
   and .ai artifact edit paths as needed. Make staging and local-main checkout
   permissions agree with binding prompted delivery; remove their competing allow
   entries rather than adding ineffective ask duplicates. Keep project-specific
   executable checks. No bypass mode or unattended Git authority is introduced.
7. Add `.ai/plans/` ignore before migrations; retain `.claude/plans/` ignore as
   legacy safety during the transition. Move all 152 approved artifacts with
   unchanged filenames and bytes to the matching .ai/plans/approved paths. Move
   17 named historical root drafts unchanged. `.claude/plans/draft.md` collides
   with this proposal's new `.ai/plans/draft.md`: archive old bytes at
   `.ai/plans/legacy-draft.md` only if nonexistent and uniquely designated in the
   refreshed approved plan. Never overwrite the active draft or approved snapshot.
   If that archive name collides, stop for revised explicit mapping. Verify every
   copied destination before removing its old counterpart. Record relocation
   mapping externally to historical artifacts. Current .ai approved migration
   snapshot and draft retain hashes. New freezes use branch/base/plan short hashes;
   historical filenames are explicitly grandfathered. No historical approval or
   review becomes approval of a new task by relocation.
8. Update every live old-contract citation in the named files, including source
   doc comments, contract verifier comments and build.zig.zon's asset comment.
   Source/build behavior, package `.paths`, verifier logic and baselines stay
   unchanged. Existing package paths do not include governance; no need to add
   agent configs or ignored plans to shipping packages. Update CODEOWNERS from
   coding-contract glob to engineering-contract ownership and add AGENTS.md,
   governance-bootstrap.md and .codex ownership while preserving existing owners.
   README describes shared authorities and existing Claude/Codex static placement,
   without inventing launch/runtime compatibility claims. Keep historical plans'
   old references unchanged and explain their relocation mapping in live workflow.
9. Run gate and preservation audits; inspect full diff and exact allowed-file set;
   answer applicable delivery checklist with non-applicable behavior questions
   stated explicitly. Commit via bound implementer/prompt; fresh exact-commit
   reviewer checks policy/content/manifest, followed by separate prompted integrator.
   Any required new behavior or policy outside this list requires a new plan.

## Verification and acceptance gate

No builds, smokes, formatting or migrations run during draft mode. Before any
implementation acceptance run, on the exact reviewed branch:

- `zig fmt --check build.zig src` (check only; never format to satisfy metrics).
- `zig build test --summary all`.
- `./docs/verify-contract.sh`; its logic, registry and baseline must not change.
- `python3 docs/tui_smoke.py zig-out/bin/game <fresh-private-temp-store>.db` and
  `bash docs/repl_smoke.sh zig-out/bin/game <different-private-temp-store>.db`.
  Both are required because citation edits touch src/tui.
- `bash docs/clean-package.sh` to verify package contents and rule 66 remains intact.
- `git diff --check`; JSON parse .claude/settings.json and TOML parse all .codex
  files using already available tooling. Inspect Claude adapter frontmatter and
  every role's paths/authority manually; do not install packages to parse them.
- Rule 65 platform/CI requirements remain unchanged. Local macOS results cannot
  establish Windows/Linux acceptance; existing CI commands remain owned by John
  for remote execution, report unavailable target evidence honestly.
- Confirm original normalized contract equals new normalized bytes; count exact
  numbered rules 1–87, preserve anchors/checks/gate/checklist and exception data.
- Confirm guide and workflow preservation maps cover all old obligations except
  explicitly approved role/path/correction-limit changes. No TODO deletion or
  contract-exception closure is authorized.
- Search tracked files for coding-contract/.claude/plans references: allow only
  explicitly explained compatibility/history text; all live links resolve.
- Confirm .ai plans are ignored, no local artifacts staged, complete migration
  manifest equals original via relative-path mapping and SHA-256, and frozen
  migration snapshot remains byte-identical. Missing files, extra overwrites or
  unexplained inventory changes block acceptance.
- Manual handoff walkthroughs: bootstrap missing/existing contract; draft freeze
  unchanged/mutated hash; branch collision; interrupted implementer continuation;
  finding dispositions/tracker evidence; three-round exhaustion; fresh review of
  correction; stale review/base refusal; integrator cannot edit; remote deny.
  These inspect documented/static boundaries, not proof of runtime enforcement.

## Preservation evidence recorded during this draft

Original coding-contract SHA-256:
`778f0d2162ad1c3869e515f3817d7ae80923003334d89701709c84b4a4cf53dd`.
Original CLAUDE.md SHA-256:
`ded7842b990e764c59a304442d5db297ec6b7032c0d9380637b894cdbe77d99d`.
Original workflow SHA-256:
`e65183ffc1514bf71b4578ceb70cd7b8384b2bbb1344933926d7c1886defdcbf`.
Inventory: 170 regular plan files, comprising 152 approved and 18 root drafts.
Sorted manifest algorithm: concatenate each relative path below .claude/plans,
TAB, file SHA-256, newline; SHA-256 that UTF-8 manifest.
Original aggregate manifest SHA-256:
`c63799fce27b9aeebed79938a0e16cbd34e70c06e5e062fdc917d2400dc784ee`.
Refresh these facts before approved migration; these hashes are evidence, not
approval. No original contract, guide, workflow or historical plan was edited.

## Risks and non-goals

Bootstrap authority conflict must be resolved before executable migration. Local
ignored artifact moves are not recoverable by reverting a Git commit; copy/verify
before removing and retain an independent verified local backup under separately
approved implementation handling. Draft collision must not destroy either draft.
Project-local Claude roles change role precedence relative to existing user roles;
verify effective selection, preserve safety and do not edit global profiles.
Local settings and external hooks can change effective behavior; static equality
is not runtime conformance. Runtime sessions must be restarted/reloaded according
to the relevant tool's verified instructions after configuration changes.

No gameplay behavior, persistence/schema, data, module layout, test semantics,
exception entries, gate weakening, CI workflow changes, new dependencies/providers,
model upgrades, unattended approvals, remote operations, OpenCode/OpenRig profiles,
architecture rename, historical plan rewriting or next-work selection. Optional
OpenCode can later add opencode.json plus .opencode roles/command; optional OpenRig
requires its own profile and runtime validation plan. Scaffold compliance here
means shared governance and existing Codex/Claude delivery, not all optional tools.
