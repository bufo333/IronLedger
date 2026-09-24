#!/usr/bin/env bash
# The mechanical checks of the coding contract (docs/coding-contract.md and
# the proposal it is growing into), run as one gate: every check prints
# nothing on a clean tree, and any output fails.
#   docs/verify-contract.sh
# Frontend checks walk src/tui recursively (screens/ included). Checks the
# contract scopes to non-test code skip `test "…" { … }` blocks and test
# support: top-level functions named `expect…` or `…ForTest`.
set -u
cd "$(dirname "$0")/.."
failed=0

# Print file:line:text for lines matching an extended regex, outside test
# code (a block from a column-0 `test "` or test-support `fn` to the next
# column-0 `}`).
outside_tests() {
    local re="$1"; shift
    awk -v re="$re" '
        FNR == 1 { in_test = 0 }
        /^test "/ || /^(pub )?fn (expect[A-Z][A-Za-z0-9_]*|[A-Za-z0-9_]+ForTest)\(/ { in_test = 1 }
        !in_test && $0 ~ re { print FILENAME ":" FNR ":" $0 }
        in_test && /^}/ { in_test = 0 }
    ' "$@"
}

check() {
    local what="$1" out="$2"
    if [ -n "$out" ]; then
        printf 'FAIL: %s\n%s\n\n' "$what" "$out"
        failed=1
    fi
}

tui=$(find src/tui -name '*.zig' | sort)
core=$(ls src/domain/*.zig src/sim/*.zig src/econ/*.zig src/gen/*.zig)

# §1 Layers
check "frontends touching GameState fields" \
    "$(grep -nE '\b(g|gs)\.(units|hqs|forces|people|clock|funds|loans|market_listings|contract_offers|supply_policies|unit_transfers|bankrupt|outfit_name|campaign_id)\b' $tui)"
check "frontends calling GameState methods" \
    "$(grep -nE '\b(g|gs)\.[a-zA-Z_]+\(' $tui | grep -vE '\.(allocator|diff)\(')"
check "frontends reaching sim, store or domain modules" \
    "$(grep -nE 'game\.(store|state|hq_ops|contract_market|contract_control|battle|maintenance|medical|tick|planet|faction|chassis|part|force|hq|person|unit|difficulty|dataProvenance)\b' $tui | grep -vE 'pub const (GameState|Treasury) = game\.state\.(GameState|Treasury);')"
check "the sim, econ or domain importing the view layer (outside tests)" \
    "$(outside_tests 'queries\.zig' $(ls src/sim/*.zig | grep -v -e '/queries.zig$' -e '/cli.zig$') src/econ/*.zig src/domain/*.zig src/gen/*.zig)"
check "domain, econ or gen importing the sim (rng.zig is the one leaf)" \
    "$(grep -n '"\.\./sim/' src/domain/*.zig src/econ/*.zig src/gen/*.zig | grep -v '"\.\./sim/rng\.zig"')"
check "impurity in the core (outside tests)" \
    "$(outside_tests 'std\.(time|fs|Io|process|posix|os)([^a-zA-Z_]|$)|page_allocator|std\.debug\.print|^var ' $core | grep -v 'std\.Io\.Writer')"

# §2–3 Presentation
# The tag set comes from table.marks. {c}, {s} and {d} are also Zig format
# specifiers, so only the other tags are grepped (they cannot be anything else).
marks=$(sed -n 's/^pub const marks = "\(.*\)";$/\1/p' src/sim/table.zig)
[ -n "$marks" ] || check "table.marks not found" "src/sim/table.zig has no pub const marks"
tags=$(printf '%s' "$marks" | tr -d 'csd')
check "markup tags (from table.marks) below the queries" \
    "$(grep -nE "\\{[$tags]\\}" src/domain/*.zig src/sim/*.zig src/econ/*.zig src/gen/*.zig | grep -v -e '/queries.zig:' -e '/table.zig:')"
check "the REPL walking GameState collections" \
    "$(grep -nE 'gs\.(units|hqs|forces|people)\.' src/main.zig)"
check "a screen searching rendered text for markup" \
    "$(grep -n 'std.mem.indexOf(u8, .*"{' $tui)"

# §4 The terminal client
tabs=$(grep -c 'switch (self.tab)' $tui | awk -F: '{ n += $2 } END { print n + 0 }')
[ "$tabs" = 1 ] || check "one switch on the tab (found $tabs)" "$(grep -n 'switch (self.tab)' $tui)"
# awk -v unescapes once, so four backslashes reach the regex as a literal `\x1b`.
check "escape sequences outside term.zig and emblem.zig" \
    "$(outside_tests '\\\\x1b' $(echo "$tui" | grep -v -e 'src/tui/term.zig' -e 'src/tui/emblem.zig'))"
# A command runs through App.execResult / exec / execSay, which report a
# refusal the one way. A direct call says why: `// direct: …` on its line,
# or on a comment line covering the block below it up to a blank line.
check "commands.execute( in the client without a // direct: reason" \
    "$(for f in $tui; do awk '
        /^[ \t]*\/\/ direct:/ { cover = 1; next }
        /^[ \t]*$/ { cover = 0 }
        /commands\.execute\(/ && !cover && $0 !~ /\/\/ direct:/ { print FILENAME ":" FNR ":" $0 }
    ' "$f"; done)"

# A raw player-chosen name leaves its table.Raw only for a command payload or
# an exact comparison, and says so: `// raw: …` on the line or the one above.
check ".raw on a player-chosen name in a frontend without a // raw: reason" \
    "$(for f in $tui src/main.zig; do awk '/\.(name|outfit_name|commander)\.raw([^A-Za-z_]|$)/ && prev !~ /\/\/ raw:/ && $0 !~ /\/\/ raw:/ { print FILENAME ":" FNR ":" $0 } { prev = $0 }' "$f"; done)"

# §10 Comments (rules 82-84): present truth, durable citations.
code_and_data=$(find src data build.zig -name '*.zig' -o -name '*.zon' | sort)
check "comments carrying history, attribution or conversation" \
    "$(grep -niE '//.*\b(play feedback|user asked|we decided|previously|used to|formerly|after the audit|after review|conversation|LLM|Claude|ChatGPT)\b' $code_and_data)"
check "roadmap stage tags outside a //! module header" \
    "$(grep -nE '^\s*//[/ ].*\b(Stage [0-9]|1[0-9][A-G]?\.[0-9])' $code_and_data | grep -v '%')"
check "TODO / FIXME / HACK / XXX (open work lives in TODO.md)" \
    "$(grep -nE '\b(TODO|FIXME|HACK|XXX)\b' $code_and_data)"
check "test names led by a roadmap stage" \
    "$(grep -nE '^test "(Stage )?[0-9]+[A-G]?(\.[0-9]+)*[a-z]?:' $code_and_data)"

# Refusal text comes from cli.errorText (rule 10): a frontend never shows an
# error's name.
check "an error name shown in a frontend (use cli.errorText)" \
    "$(grep -n '@errorName' $tui src/main.zig)"

# §10 Errors keep their meaning (rule 79): a broad catch is best-effort
# cleanup with a `// best-effort:` reason, or a known case recorded in
# docs/verify-contract.baseline until its fix lands. A new one fails, and so
# does a baseline entry that no longer exists, so the baseline only shrinks.
broad=$(for f in $(find src -name '*.zig' | sort); do awk '
    FNR == 1 { in_test = 0 }
    /^test "/ || /^(pub )?fn (expect[A-Z][A-Za-z0-9_]*|[A-Za-z0-9_]+ForTest)\(/ { in_test = 1 }
    !in_test && /catch (\{\}|false|""|return[;)])/ && prev !~ /\/\/ best-effort:/ && $0 !~ /\/\/ best-effort:/ { line = $0; sub(/^[ \t]+/, "", line); print FILENAME ": " line }
    in_test && /^}/ { in_test = 0 }
    { prev = $0 }' "$f"; done)
baseline=$(grep -v '^#' docs/verify-contract.baseline 2>/dev/null)
check "a broad catch with no best-effort reason and no baseline entry" \
    "$(printf '%s\n' "$broad" | grep -vxF -f <(printf '%s\n' "$baseline") | grep -v '^$')"
check "a baseline entry that no longer exists (remove it)" \
    "$(printf '%s\n' "$baseline" | grep -vxF -f <(printf '%s\n' "$broad") | grep -v '^$')"

# §9 Every source file is reachable (rule 74): from src/root.zig and
# src/main.zig through @import, so nothing sits outside the build.
check "a source file no import reaches" "$(python3 - <<'PY'
import os, re, collections
seen, queue = set(), collections.deque(["src/root.zig", "src/main.zig"])
while queue:
    f = queue.popleft()
    if f in seen or not os.path.exists(f): continue
    seen.add(f)
    for imp in re.findall(r'@import\("([^"]+\.zig)"\)', open(f).read()):
        queue.append(os.path.normpath(os.path.join(os.path.dirname(f), imp)))
for dirpath, _, files in os.walk("src"):
    for name in sorted(files):
        p = os.path.join(dirpath, name)
        if name.endswith(".zig") and p not in seen: print(p)
PY
)"

if [ "$failed" = 0 ]; then echo "CONTRACT CHECKS OK"; else exit 1; fi
