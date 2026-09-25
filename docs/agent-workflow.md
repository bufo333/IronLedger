# Agent workflow

How coding agents work on IRON LEDGER. The agent is an implementation
author; John dispatches, reviews and merges. CLAUDE.md's standing instruction
and stop conditions bind every session.

## Controls

| Control | Where | Enforces |
| --- | --- | --- |
| `main` ruleset | GitHub settings | PR with 1 approval, Code Owner review, last-push approval, the four CI checks; nobody pushes to `main` |
| `.github/CODEOWNERS` | repo | John reviews every change to the governance files |
| `.claude/settings.json` | repo | permission rules: `deny` never runs, `ask` needs John's approval (and is denied outright in `dontAsk` sessions), `allow` runs unprompted |
| `.claude/hooks/guard.py` | repo | blocks merge, approve, auth, token, keychain, push-to-`main`, local merge, git identity and `sed` commands by their full text, including `bash -c` and `git -C` forms a permission rule misses |
| `.claude/agents/*.md` | repo | the five roles below: tools, permission mode, model, turn limit, prompt |
| bot account | machine | agent sessions act on GitHub as `bufo333ironbot`, never as John |

Permission rules and the hook match what an agent types; a script that
opens files itself is not covered (Claude Code permissions docs, "What a
Bash rule doesn't match"). Branch protection is the control that holds
regardless.

## Roles

| Agent | Writes? | Mode | Output |
| --- | --- | --- | --- |
| `triage-planner` | no | plan | an implementation plan for one issue |
| `implementer` | source, tests, docs | dontAsk | one committed branch, gate results, the PR checklist |
| `verifier` | no | dontAsk | the gate's raw results |
| `contract-reviewer` | no | plan | findings: plan drift, metric gaming, guessed facts |
| `correctness-reviewer` | no | plan | findings: atomicity, memory, persistence, numbers, determinism |

There is no governance agent. Changes to CLAUDE.md, the contract, the
exception ledger, the contract checks, CI, `.claude/` and memory happen only
in a session John starts for that purpose, approving each edit.

## One issue, start to finish

The board is the GitHub Project "workflow": Inbox → Needs Specification →
Ready → In Progress → Review → Blocked → Done. In Progress and Review hold one
card each. Only John moves cards.

Each step is a fresh session started in the agent clone (see Setup), with
the role as the main agent:

```fish
cd ~/Development/zig/game-agent
env GH_TOKEN=(security find-generic-password -s ironledger-bot-gh -w) claude --agent triage-planner
```

1. **Plan.** John picks an issue from Inbox or Needs Specification and starts
   `triage-planner`: "Review issue #N and produce the required implementation
   plan. Do not edit files or change issue state." John edits the plan into
   the issue, marks it approved, and moves the card to Ready.
2. **Implement.** John moves the card to In Progress and starts
   `implementer`: "Implement issue #N exactly according to the approved plan
   in the issue. Stop before any unplanned architecture, contract, exception,
   CI, or governance change. Do not push or merge." Only one implementer runs
   at a time.
3. **Verify.** John starts `verifier` on the implementer's branch. A failure
   goes back to John, not straight to the implementer.
4. **Push.** John pushes the branch and opens the PR (or approves the `ask`
   prompts in an interactive bot session), then moves the card to Review.
5. **Review.** John starts `contract-reviewer` ("Review the complete diff of
   PR #P for issue #N against the approved plan and coding contract"), and
   `correctness-reviewer` too for high-risk work. Both are read-only and can
   run at the same time.
6. **Correct.** John decides which findings are valid and gives only those
   to a new `implementer` session. Then verify and review again.
7. **Merge.** John approves and merges the PR, deletes the branch, and moves
   the card to Done.

## Setup on a new machine

Everything under `.claude/` and this file travel with the repo. These do
not, and are set up once per machine:

- **Bot identity.** Store the bot's classic token (scopes `repo`,
  `read:project`) in the keychain:
  `security add-generic-password -s ironledger-bot-gh -a bufo333ironbot -w`.
- **Agent clone.** Clone over HTTPS and give it the bot's identity:
  ```fish
  git clone https://github.com/bufo333/IronLedger.git ~/Development/zig/game-agent
  cd ~/Development/zig/game-agent
  git config user.name bufo333ironbot
  git config user.email 333556451+bufo333ironbot@users.noreply.github.com
  git config credential.helper ''
  git config --add credential.helper '!f() { echo username=bufo333ironbot; echo "password=$(security find-generic-password -s ironledger-bot-gh -w)"; }; f'
  ```
  Check it: `gh api user -q .login` inside a session prints `bufo333ironbot`.
- **Personal instructions and memory.** `~/.claude/CLAUDE.md` and the auto
  memory under `~/.claude/projects/` stay on the machine that wrote them.
  Rules every session needs belong in this repo: CLAUDE.md, this file, and
  `.claude/`.
