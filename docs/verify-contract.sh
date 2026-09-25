#!/usr/bin/env bash
# The mechanical checks of the coding contract (docs/coding-contract.md),
# run as one gate: every check prints nothing on a clean tree, and any
# output fails. Known violations are recorded in docs/contract-exceptions.md
# (the rule 76 registry and the C4 layering record) and
# docs/verify-contract.baseline (broad catches).
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

# §1 Layers
check "frontends touching GameState fields" \
    "$(grep -nE '\b(g|gs)\.(units|hqs|forces|people|clock|funds|loans|market_listings|contract_offers|supply_policies|unit_transfers|bankrupt|outfit_name|campaign_id)\b' $tui)"
check "frontends calling GameState methods" \
    "$(grep -nE '\b(g|gs)\.[a-zA-Z_]+\(' $tui | grep -vE '\.(allocator|diff)\(')"
check "frontends reaching sim, store or domain modules" \
    "$(grep -nE 'game\.(store|state|hq_ops|contract_market|contract_control|battle|maintenance|medical|tick|planet|faction|chassis|part|force|hq|person|unit|difficulty|dataProvenance)\b' $tui | grep -vE 'pub const (GameState|Treasury) = game\.state\.(GameState|Treasury);')"
# One rule 5 check (imports point down only): the layer map matches the
# contract table (coding-contract.md §1), "game" resolves to src/root.zig
# (build.zig:7), and every non-std/builtin import is resolved to a source
# path and compared against the layer of its importer. An upward edge to
# src/sim/queries.zig is allowed only from test code, citing rule 5's test
# clause ("A test may cross the boundary only to assert that a command and
# view agree"); every other upward edge must be a canonical
# `<source> -> <resolved module>` line in the C4 layering record
# (docs/contract-exceptions.md, rule 5). A recorded edge whose import no
# longer exists must be removed, so the record only shrinks. Import lines
# are matched across line breaks so reformatting a recorded import does not
# change its edge.
check "an import that does not point down (rule 5), or a stale layering-record edge" "$(python3 - <<'PY'
import os, re

def layer_of(p):
    if p.startswith("src/tui/") or p == "src/main.zig":
        return 0  # frontends
    if p in ("src/sim/cli.zig", "src/persist/lobby.zig", "src/root.zig"):
        return 1  # application
    if p in ("src/persist/store.zig", "src/persist/sqlite.zig"):
        return 2  # persistence
    if p == "src/sim/queries.zig":
        return 3  # views
    if p == "src/sim/rng.zig":
        return 7  # random, below rules despite its path (coding-contract.md §1)
    if p == "src/sim/state.zig":
        return 5  # state
    if p.startswith("src/sim/"):
        return 4  # simulation
    if p.startswith("src/domain/") or p.startswith("src/econ/") or p.startswith("src/gen/"):
        return 6  # rules
    return None

try:
    exc_text = open("docs/contract-exceptions.md", encoding="utf-8").read()
except OSError as e:
    print(f"docs/contract-exceptions.md unreadable: {e}")
    exc_text = ""
m = re.search(r"```layering\n(.*?)```", exc_text, re.S)
if m is None:
    print("docs/contract-exceptions.md has no ```layering block")
record = set(l.strip() for l in (m.group(1).splitlines() if m else []) if l.strip())

fails = []
seen_edges = set()
unmapped = set()
zig_files = []
for d, _, fs in os.walk("src"):
    for f in sorted(fs):
        if f.endswith(".zig"):
            zig_files.append(os.path.join(d, f))
zig_files.sort()

for p in zig_files:
    lf = layer_of(p)
    if lf is None:
        unmapped.add(p)
        continue
    text = open(p, encoding="utf-8").read()
    lines = text.split("\n")
    in_test = [False] * (len(lines) + 1)
    cur = False
    for i, ln in enumerate(lines):
        if re.match(r'^test "', ln) or re.match(r'^(pub )?fn (expect[A-Z][A-Za-z0-9_]*|[A-Za-z0-9_]+ForTest)\(', ln):
            cur = True
        in_test[i] = cur
        if cur and ln.startswith("}"):
            cur = False
    for mm in re.finditer(r'@import\(\s*"([^"]+)"\s*,?\s*\)', text, re.S):
        target = mm.group(1)
        if target in ("std", "builtin"):
            continue
        if target == "game":
            resolved = "src/root.zig"
        elif target.endswith(".zig"):
            resolved = os.path.normpath(os.path.join(os.path.dirname(p), target))
        else:
            continue  # data/*.zon or a build-system module, not a layer edge
        line_no = text.count("\n", 0, mm.start())
        lt = layer_of(resolved)
        if lt is None:
            unmapped.add(resolved)
            continue
        if lt >= lf:
            continue  # downward or same layer: allowed
        if resolved == "src/sim/queries.zig":
            if in_test[line_no]:
                continue  # rule 5 test clause
            fails.append(f"{p}:{line_no + 1}: production import of queries.zig from below views (rule 5)")
            continue
        edge = f"{p} -> {resolved}"
        seen_edges.add(edge)
        if edge not in record:
            fails.append(f"{p}:{line_no + 1}: upward import not in the C4 layering record: {edge}")

for f in sorted(unmapped):
    fails.append(f"{f}: outside the rule 5 layer table")
for edge in sorted(record - seen_edges):
    fails.append(f"{edge}: layering record edge no longer exists; remove it")
for f in fails:
    print(f)
PY
)"
# The lobby's Session owns the open campaign (rule 9): no frontend creates,
# frees or loads a GameState itself.
check "a frontend owning a GameState (use lobby.Session)" \
    "$(grep -nE 'GameState\.init\(|\bgs\.deinit\(|\.store\.load\(|lobby\.load\(' $tui src/main.zig)"
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
# Duplicated patterns (rules 20, 73, 80): a comment saying code "mirrors",
# is the "same as", "equivalent to" or kept "in sync with" other code marks
# a copy; replace it with a call, generated data or a comparing test.
check "a comment marking copied code (mirrors / same as / equivalent to / in sync)" \
    "$(grep -niE '//.*\b(mirrors|same as|equivalent to|keep in sync|kept in sync|in sync with)\b' $code_and_data)"

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

# §10 Review thresholds (rule 76), held by the registry (rule 87): a module
# over 1,000 lines, a function over 100, or a switch with more than ten
# substantive arms is a violation unless docs/contract-exceptions.md lists
# it in the rule 76 registry. The registry names code; it does not record a
# size, so growth past the threshold is not measured here — rule 76 governs
# what listed code may gain, and review checks it (delivery checklist
# question 16). A key whose code no longer exists in src, or has dropped
# under its threshold, fails until the key is removed. An arm is
# substantive when its body runs past three lines; a dispatch switch (a
# call or a few lines per arm) has none, so it never counts. A switch is
# keyed `path:function#switch`.
check "a module, function or switch over its review threshold and not in the rule 76 registry, or a registry key to remove" "$(python3 - <<'PY'
import os, re
keys = set()
try:
    text = open("docs/contract-exceptions.md", encoding="utf-8").read()
except OSError as e:
    print(f"docs/contract-exceptions.md unreadable: {e}")
    text = ""
m = re.search(r"```oversized\n(.*?)```", text, re.S)
if m is None:
    print("docs/contract-exceptions.md has no ```oversized block")
for line in (m.group(1).splitlines() if m else []):
    if not line.strip(): continue
    parts = line.split()
    if len(parts) != 1:
        print(f"registry line carries more than its name: {line}")
        continue
    key = parts[0]
    if key in keys:
        print(f"{key}: duplicate registry key")
        continue
    keys.add(key)
FN = re.compile(r'^(\s*)(?:pub\s+)?(?:inline\s+|export\s+)?fn\s+([A-Za-z0-9_]+)\s*\(')
found = {}
exists = set()
for d, _, fs in os.walk("src"):
    for f in sorted(fs):
        if not f.endswith(".zig"): continue
        p = os.path.join(d, f)
        lines = open(p, encoding="utf-8").read().split("\n")
        exists.add(p)
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
                exists.add(p + ":" + fm.group(2))
                if j - i + 1 > 100: found[p + ":" + fm.group(2)] = j - i + 1
                i = j + 1 if ind == "" else i + 1
                continue
            i += 1
        # Switch arms: walk each non-test switch body at its own depth.
        in_test, fn_name = False, "?"
        for i, ln in enumerate(lines):
            if re.match(r'^test\s+"', ln): in_test = True
            if in_test:
                if ln.startswith("}"): in_test = False
                continue
            fm = FN.match(ln)
            if fm: fn_name = fm.group(2)
            if not re.search(r'\bswitch\s*\(.*\)\s*\{\s*$', ln): continue
            depth, j, arms = 1, i + 1, []
            while j < len(lines) and depth > 0:
                body = re.sub(r'"(\\.|[^"\\])*"', '""', lines[j])
                body = re.sub(r"'(\\.|[^'\\])*'", "''", body).split("//")[0]
                if depth == 1 and re.match(r'^\s*[^/\s].*=>', lines[j]): arms.append(j)
                depth += body.count("{") - body.count("}")
                j += 1
            substantive = sum(1 for a, b in zip(arms, arms[1:] + [j - 1]) if b - a > 3)
            key = f"{p}:{fn_name}#switch"
            exists.add(key)
            if substantive > 10: found[key] = max(found.get(key, 0), substantive)
for key, n in sorted(found.items()):
    if key not in keys:
        unit = "substantive arms" if key.endswith("#switch") else "lines"
        print(f"{key}: {n} {unit}, over the threshold and not in the rule 76 registry")
for key in sorted(keys - set(found)):
    if key not in exists:
        print(f"{key}: names no module, function or switch in src; remove it")
    else:
        print(f"{key}: under its threshold now; remove it from the rule 76 registry")
PY
)"

if [ "$failed" = 0 ]; then echo "CONTRACT CHECKS OK"; else exit 1; fi
