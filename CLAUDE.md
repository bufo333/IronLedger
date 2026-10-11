# Claude project entry point

Read and follow `AGENTS.md`, `docs/agent-workflow.md`, and
`docs/engineering-contract.md` freshly. `ARCHITECTURE.md` remains the architectural
authority. Project-local role adapters are in `.claude/agents/`; they refer to the
same shared workflow as `.codex/agents/`.

Agent selection and effective local permissions must be verified before
dispatch; static files do not prove runtime enforcement. John owns all Git
remote operations. Scoped read-only web and source research follows
`docs/agent-workflow.md`.

Approval of an exact plan authorizes its outcome, the completion work that
outcome needs, and continuous coordinator handoffs; a bounded material gap takes
an approved amendment; integration requires a separate approval of the exact
accepted commit and checkout/merge/delete sequence. Neither tracked settings nor
a delegation changes loaded authority. Honor and report any actual runtime
permission or hook restriction without bypassing it or changing global
settings.
