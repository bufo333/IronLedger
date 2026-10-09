# Claude project entry point

Read and follow `AGENTS.md`, `docs/agent-workflow.md`, and
`docs/engineering-contract.md` freshly. `ARCHITECTURE.md` remains the architectural
authority. Project-local role adapters are in `.claude/agents/`; they refer to the
same shared workflow as `.codex/agents/`.

The migration transition in `AGENTS.md` applies until scaffold alignment is
accepted and integrated into local `main`. Agent selection and effective local
permissions must be verified before subsequent dispatch; static files do not
prove runtime enforcement. John owns all Git remote operations and GitHub
access. Scoped read-only web and source research outside GitHub follows
`docs/agent-workflow.md`.
