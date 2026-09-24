#!/usr/bin/env bash
# The mechanical reviewer checks of docs/coding-contract.md, run as one
# gate: every check prints nothing on a clean tree, and any output fails.
#   docs/reviewer_checks.sh
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
check "markup tags below the queries" \
    "$(grep -nE '\{[acg]\}|\{/\}' src/domain/*.zig src/sim/*.zig | grep -v -e queries.zig -e table.zig)"
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

if [ "$failed" = 0 ]; then echo "REVIEWER CHECKS OK"; else exit 1; fi
