#!/usr/bin/env bash
# The contract checks live in docs/verify-contract.sh; this name stays until
# CLAUDE.md and the docs point there (the citation-renumbering PR).
exec "$(dirname "$0")/verify-contract.sh" "$@"
