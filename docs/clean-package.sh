#!/usr/bin/env bash
# The clean package build (docs/coding-contract.md rule 66): copy only the
# paths build.zig.zon declares into a fresh tree and build a release there,
# so an input the package leaves out fails here instead of for the first
# person who fetches it.
#   docs/clean-package.sh [optimize]     (default ReleaseFast)
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd)"
optimize="${1:-ReleaseFast}"
# A fixed tree path and the repository's own .zig-cache, so the cache CI
# restores for the workspace serves this build too.
tree="${TMPDIR:-/tmp}/iron-ledger-clean-package"
rm -rf "$tree"
mkdir -p "$tree"
trap 'rm -rf "$tree"' EXIT

# The .paths list: every quoted string inside `.paths = .{ … }`.
paths=$(python3 - <<'PY'
import re
zon = open("build.zig.zon", encoding="utf-8").read()
block = re.search(r"\.paths\s*=\s*\.\{(.*?)\}", zon, re.S)
if not block:
    raise SystemExit("build.zig.zon has no .paths")
body = re.sub(r"//[^\n]*", "", block.group(1))
for p in re.findall(r'"([^"]*)"', body):
    print(p)
PY
)
[ -n "$paths" ] || { echo "build.zig.zon declares no paths" >&2; exit 1; }

while IFS= read -r p; do
    [ -e "$p" ] || { echo "declared path missing from the repository: $p" >&2; exit 1; }
    mkdir -p "$tree/$(dirname "$p")"
    cp -R "$p" "$tree/$p"
done <<< "$paths"

(cd "$tree" && zig build -Doptimize="$optimize" --prefix "$tree/dist" --cache-dir "$repo/.zig-cache")
[ -x "$tree/dist/bin/game" ] || { echo "no dist/bin/game after the build" >&2; exit 1; }
echo "CLEAN PACKAGE OK ($optimize)"
