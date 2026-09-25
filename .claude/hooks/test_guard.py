#!/usr/bin/env python3
"""Regression cases for guard.py: every command in BLOCK must exit 2 and every
command in ALLOW must exit 0. Run: python3 .claude/hooks/test_guard.py
"""

import json
import pathlib
import subprocess
import sys

GUARD = pathlib.Path(__file__).with_name("guard.py")

BLOCK = [
    # merging and approving
    "gh pr merge 5 --merge",
    "bash -c 'gh pr merge 5'",
    "/opt/homebrew/bin/gh pr review 5 --approve",
    "gh -R bufo333/IronLedger pr merge 5",
    # identity, repository, board, API writes
    "gh auth status",
    "gh repo edit --visibility private",
    "gh project item-edit --id x",
    "gh api -X PUT repos/x",
    "gh api repos/x/issues -f title=t",
    # tokens and keychain
    "set -e GH_TOKEN; gh pr list",
    "env -u GH_TOKEN gh pr list",
    "security find-generic-password -s x -w",
    # pushes
    "git push origin main",
    "git -C . push origin main",
    "git push origin HEAD:main",
    "git push --force origin b",
    "git push origin :feature",
    "git push origin +b",
    "git push -d origin b",
    # local merges
    "git merge feature",
    "git merge topic",
    "git -C . merge topic",
    "git -c x=y merge feature",
    "git merge",
    "git merge --abort",
    # identity, credentials, remotes
    "git config user.email a@b",
    "git config --global credential.helper x",
    "git remote set-url origin x",
    "git clone git@github.com:bufo333/IronLedger.git",
    # sed
    "sed -n 1p f",
    "cat f | sed s/a/b/",
    "cd x && sed -i '' s/a/b/ f",
]

ALLOW = [
    "zig build test --summary all",
    "git status",
    "git push -u origin sim/founding",
    "git push -u origin tui/main-menu-keys",
    "gh pr create --title t --body b",
    "gh pr view 5",
    "gh pr diff 5",
    "gh api repos/bufo333/IronLedger/pulls/5",
    "git commit -m 'founding: merge the HQ helpers into hq_network.zig'",
    "git log --merges",
    "git diff main...HEAD",
    "git merge-base db239fa main",
    "git -C . merge-base HEAD origin/main",
    "git merge-file a b c",
    "git merge-tree a b",
    "docs/verify-contract.sh",
    "grep -n based src/x.zig",
    "git config --get user.name",
    "git checkout main && git pull --ff-only",
]


def verdict(command: str) -> int:
    event = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    return subprocess.run([sys.executable, str(GUARD)], input=event, capture_output=True, text=True).returncode


def main() -> int:
    wrong = [(c, 2) for c in BLOCK if verdict(c) != 2] + [(c, 0) for c in ALLOW if verdict(c) != 0]
    malformed = subprocess.run([sys.executable, str(GUARD)], input="not json", capture_output=True, text=True).returncode
    if malformed != 2:
        wrong.append(("<non-JSON input>", 2))
    for command, want in wrong:
        print(f"WRONG (want exit {want}): {command}")
    total = len(BLOCK) + len(ALLOW) + 1
    print(f"GUARD TESTS {'OK' if not wrong else 'FAILED'}: {total - len(wrong)}/{total}")
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main())
