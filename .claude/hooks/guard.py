#!/usr/bin/env python3
"""PreToolUse guard for Bash: blocks the commands an agent session must never
run, by matching the whole command text, so the forms a permission rule does
not see (`bash -c '...'`, `git -C . push`, `/usr/bin/gh`) are caught too
(docs/agent-workflow.md). Exit 2 blocks the call and shows stderr to Claude;
any error here also blocks, so the guard fails closed.
"""

import json
import re
import sys

# `git`, then any global options (`-C dir`, `-c key=value`, `--no-pager`),
# then the subcommand.
GIT = r"\bgit(?:\s+-[Cc]\s+\S+|\s+--[\w-]+(?:=\S+)?)*\s+"
# The rest of one command, up to a shell separator.
ARGS = r"[^;&|\n]*"

BLOCKED = [
    (r"\bgh\b.*\bpr\s+(merge|review)\b", "merging and approving pull requests are John's"),
    (r"\bgh\b.*\bauth\b", "the GitHub identity is set by John when he starts the session"),
    (r"\bgh\b.*\brepo\s+(edit|delete|rename|archive)\b", "repository settings are John's"),
    (r"\bgh\b.*\bproject\s+(item-edit|item-archive|item-delete|item-add|edit|delete|close|field-create|field-delete)\b",
     "John alone moves cards on the workflow board"),
    (r"\bgh\b.*\bapi\b.*(\s-X\s*(POST|PUT|PATCH|DELETE)|--method\s*(POST|PUT|PATCH|DELETE)|\s-[fF]\s|--field|--raw-field|--input)",
     "gh api writes are not allowed; use the gh subcommand John approved"),
    (r"\b(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN)\b", "the session's GitHub token is not to be read, set or unset"),
    (r"\bsecurity\s+(find|add|delete)-", "the keychain is not to be read or changed"),
    (GIT + r"push\b" + ARGS + r"((?<![\w/.-])(main|master)(?![\w/.-])|--force|\s-f\b|--delete|\s-d\b|--mirror|--all|\s\+|\s:\S)",
     "pushes to main, force pushes and remote branch deletion are not allowed"),
    (GIT + r"merge\b", "merging is John's; never merge locally"),
    (GIT + r"config\b(?!" + ARGS + r"--(get|get-all|list|show-origin)\b)" + ARGS + r"\b(credential|user\.name|user\.email|url\.|remote\.|core\.hooksPath)",
     "git identity, credentials and remotes are set by John"),
    (GIT + r"remote\s+(add|set-url|rename|remove)\b", "git remotes are set by John"),
    (r"git@github\.com", "pushes and fetches go through the HTTPS remote only"),
    (r"(^|[\s;&|(`'\"])sed\b", "never use sed; read with Read and edit with Edit or Write"),
]


def main() -> int:
    event = json.load(sys.stdin)
    if event.get("tool_name") != "Bash":
        return 0
    command = event.get("tool_input", {}).get("command", "")
    for pattern, reason in BLOCKED:
        if re.search(pattern, command):
            print(f"Blocked by .claude/hooks/guard.py: {reason}. Stop and report to John.", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # fail closed: an unreadable call is blocked
        print(f"Blocked by .claude/hooks/guard.py: could not inspect the call ({err}).", file=sys.stderr)
        sys.exit(2)
