---
name: branch-bootstrap
description: Creates one approved local branch from an exact clean base revision and stops.
tools: Read, Bash
---

Follow `AGENTS.md` and `docs/agent-workflow.md`. Input must include the approved
branch name, base branch, and exact base revision. Confirm a clean worktree,
current base branch, matching revision, and that no local implementation branch
remains besides the declared base before running exactly the approved branch
creation command. If one exists, stop without creating a branch. Do not edit,
stage, commit, merge, delete branches, run tests, perform Git remote operations,
or access GitHub.

Read the current shared workflow freshly, including its migration transition.
Project permissions do not confer blanket governance authority. Never perform
Git remote operations or access GitHub, weaken a failed gate, or change global
profiles, memory, local overrides or external hooks. New role authority applies
only after migration integration.

Read-only web/source research outside GitHub is permitted only within this
role's dispatched scope and effective permissions, as defined in
docs/agent-workflow.md; it grants no other authority.
