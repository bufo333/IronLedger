#!/usr/bin/env bash
# The mechanical checks of the coding contract (docs/coding-contract.md),
# run as one gate: every check prints nothing on a clean tree, and any
# output fails. Known violations are recorded in docs/contract-exceptions.md
# (the rule 76 ratchet) and docs/verify-contract.baseline (broad catches).
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
# Recursive (rule 73): a module split into a subdirectory stays checked.
core=$(find src/domain src/sim src/econ src/gen -name '*.zig' | sort)
below_sim=$(find src/domain src/econ src/gen -name '*.zig' | sort)

# §1 Layers
check "frontends touching GameState fields" \
    "$(grep -nE '\b(g|gs)\.(units|hqs|forces|people|clock|funds|loans|market_listings|contract_offers|supply_policies|unit_transfers|bankrupt|outfit_name|campaign_id)\b' $tui)"
check "frontends calling GameState methods" \
    "$(grep -nE '\b(g|gs)\.[a-zA-Z_]+\(' $tui | grep -vE '\.(allocator|diff)\(')"
check "frontends reaching sim, store or domain modules" \
    "$(grep -nE 'game\.(store|state|hq_ops|contract_market|contract_control|battle|maintenance|medical|tick|planet|faction|chassis|part|force|hq|person|unit|difficulty|dataProvenance)\b' $tui | grep -vE 'pub const (GameState|Treasury) = game\.state\.(GameState|Treasury);')"
check "the sim, econ or domain importing the view layer (outside tests)" \
    "$(outside_tests 'queries\.zig' $(echo "$core" | grep -v -e '^src/sim/queries.zig$' -e '^src/sim/cli.zig$'))"
# The lobby's Session owns the open campaign (rule 9): no frontend creates,
# frees or loads a GameState itself.
check "a frontend owning a GameState (use lobby.Session)" \
    "$(grep -nE 'GameState\.init\(|\bgs\.deinit\(|\.store\.load\(|lobby\.load\(' $tui src/main.zig)"
check "domain, econ or gen importing the sim (rng.zig is the one leaf)" \
    "$(grep -nE '"(\.\./)+sim/' $below_sim | grep -vE '"(\.\./)+sim/rng\.zig"')"
check "impurity in the core (outside tests)" \
    "$(outside_tests 'std\.(time|fs|Io|process|posix|os)([^a-zA-Z_]|$)|page_allocator|std\.debug\.print|^var ' $core | grep -v 'std\.Io\.Writer')"

# §4 Presentation
# The tag set comes from table.marks. {c}, {s} and {d} are also Zig format
# specifiers, so only the other tags are grepped (they cannot be anything else).
marks=$(sed -n 's/^pub const marks = "\(.*\)";$/\1/p' src/sim/table.zig)
[ -n "$marks" ] || check "table.marks not found" "src/sim/table.zig has no pub const marks"
tags=$(printf '%s' "$marks" | tr -d 'csd')
check "markup tags (from table.marks) below the queries" \
    "$(grep -nE "\\{[$tags]\\}" $core | grep -v -e '^src/sim/queries.zig:' -e '^src/sim/table.zig:')"
check "the REPL walking GameState collections" \
    "$(grep -nE 'gs\.(units|hqs|forces|people)\.' src/main.zig)"
check "a screen searching rendered text for markup" \
    "$(grep -n 'std.mem.indexOf(u8, .*"{' $tui)"

# §5 The terminal client
tabs=$(grep -c 'switch (self.tab)' $tui | awk -F: '{ n += $2 } END { print n + 0 }')
[ "$tabs" = 1 ] || check "one switch on the tab (found $tabs)" "$(grep -n 'switch (self.tab)' $tui)"
# awk -v unescapes once, so four backslashes reach the regex as a literal `\x1b`.
check "escape sequences outside term.zig and emblem.zig" \
    "$(outside_tests '\\\\x1b' $(echo "$tui" | grep -v -e 'src/tui/term.zig' -e 'src/tui/emblem.zig'))"
# Screens never call the command facade: execResult / execResultWith own
# refusal text (rule 37). Only app.zig holds the wrapper and the wizard's
# pre-session call, the one listed exception.
check "commands.execute( in a screen module" \
    "$(grep -n 'commands\.execute(' $(echo "$tui" | grep '/screens/'))"
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
    !in_test && /catch (\{\}|false|""|null|continue|[0-9]+[;,) ]|\.?[A-Za-z]*\{\}|return[;)]|return (false|""|null|[0-9]+|\.none)[;,) ])/ && prev !~ /\/\/ best-effort:/ && $0 !~ /\/\/ best-effort:/ { line = $0; sub(/^[ \t]+/, "", line); print FILENAME ": " line }
    in_test && /^}/ { in_test = 0 }
    { prev = $0 }' "$f"; done)
baseline=$(grep -v '^#' docs/verify-contract.baseline 2>/dev/null)
check "a broad catch with no best-effort reason and no baseline entry" \
    "$(printf '%s\n' "$broad" | grep -vxF -f <(printf '%s\n' "$baseline") | grep -v '^$')"
check "a baseline entry that no longer exists (remove it)" \
    "$(printf '%s\n' "$baseline" | grep -vxF -f <(printf '%s\n' "$broad") | grep -v '^$')"

# §7 Every module names its MekHQ counterpart, or says it has none (rule 61):
# the //! header at the top of the file mentions MekHQ.
check "a module header that names no MekHQ counterpart" \
    "$(for f in $(find src -name '*.zig' | sort); do awk 'NR == FNR && /^\/\/!/ { if (/MekHQ/) found = 1; next } { exit } END { if (!found) print FILENAME }' "$f"; done)"

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

# §10 Review thresholds (rule 76), held by ratchet (rule 87): a module over
# 1,000 lines or a function over 100 is a violation unless
# docs/contract-exceptions.md lists it under `ratchet`, and a listed one
# may not grow past its recorded size. A split lowers the ceiling.
check "a module or function over its review threshold or its recorded ceiling" "$(python3 - <<'PY'
import os, re
ceil = {}
try:
    text = open("docs/contract-exceptions.md", encoding="utf-8").read()
except OSError as e:
    print(f"docs/contract-exceptions.md unreadable: {e}")
    text = ""
m = re.search(r"```ratchet\n(.*?)```", text, re.S)
for line in (m.group(1).splitlines() if m else []):
    parts = line.split()
    if len(parts) == 2: ceil[parts[0]] = int(parts[1])
FN = re.compile(r'^(\s*)(?:pub\s+)?(?:inline\s+|export\s+)?fn\s+([A-Za-z0-9_]+)\s*\(')
found = {}
for d, _, fs in os.walk("src"):
    for f in sorted(fs):
        if not f.endswith(".zig"): continue
        p = os.path.join(d, f)
        lines = open(p, encoding="utf-8").read().split("\n")
        if len(lines) - 1 > 1000: found[p] = len(lines) - 1
        in_test, i = False, 0
        while i < len(lines):
            ln = lines[i]
            if re.match(r'^test\s+"', ln): in_test = True
            if in_test and ln.startswith("}"):
                in_test = False; i += 1; continue
            fm = FN.match(ln)
            if fm and not in_test and ln.rstrip().endswith("{"):
                ind, j = fm.group(1), i + 1
                while j < len(lines) and lines[j] != ind + "}": j += 1
                if j - i + 1 > 100: found[p + ":" + fm.group(2)] = j - i + 1
                i = j + 1 if ind == "" else i + 1
                continue
            i += 1
for key, n in sorted(found.items()):
    if key not in ceil: print(f"{key}: {n} lines, over the threshold and not in the ratchet")
    elif n > ceil[key]: print(f"{key}: {n} lines, over its ceiling of {ceil[key]}")
for key in sorted(set(ceil) - set(found)):
    print(f"{key}: under its threshold now; remove it from the ratchet")
PY
)"

if [ "$failed" = 0 ]; then echo "CONTRACT CHECKS OK"; else exit 1; fi
