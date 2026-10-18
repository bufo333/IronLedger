#!/bin/sh
# Drive the REPL through a script and grep for landmarks (Stage 12.18):
# the command verbs both frontends share, plus the print views.
#   docs/repl_smoke.sh zig-out/bin/game [store.db]
# With no store path the script uses a private temporary directory. A given
# path must end in .db and, if it exists, be a regular file: it is
# replaced. The REPL runs under a watchdog (SMOKE_TIMEOUT_S, default 300)
# and must exit with status 0.
set -e
exe="$1"; db="${2:-}"
work=$(mktemp -d "${TMPDIR:-/tmp}/iron-ledger-repl-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [ -z "$db" ]; then
  db="$work/smoke.db"
else
  case "$db" in *.db) ;; *) echo "refusing store path '$db': it must end in .db" >&2; exit 1 ;; esac
  if [ -L "$db" ] || { [ -e "$db" ] && [ ! -f "$db" ]; }; then
    echo "refusing store path '$db': it exists and is not a regular file" >&2; exit 1
  fi
  rm -f "$db"
fi
printf '%s\n' \
  'start LC quartermaster Erik Kalmar' \
  'newco Alpha' \
  'newlance co:1 air Sky Lance' \
  'wing co:1' \
  'raise hq:1 Bravo' \
  'manning co:1' \
  'readiness' \
  'rating' \
  'summary' \
  'who' \
  'who LC' \
  'who skye' \
  'who nosuchkey' \
  'sellstock hq:1 ammo_lrm 1' \
  'stockpolicy hq:1 ammo_lrm 4 8' \
  'autoadmit off' \
  'hire mekwarrior Grayson Carlyle' \
  'hire vehicle_crew Ace Pilot' \
  'hire tech_mechanic Local Mech' \
  'fabricate comp_arm 1' \
  'strip 3' \
  'roe co:1 cautious' \
  'loan 500000' \
  'artillery' \
  'loan 1500000 36' \
  'transfer outfit hq:1 1900000' \
  'day 4 force' \
  'next 1' \
  'next 1 trailing' \
  'offers' \
  'buyarty 1 hq:1' \
  'artillery' \
  'artillery 1' \
  'attacharty 1 co:1' \
  'seat 1 commander 198' \
  'detacharty 1' \
  'seat 1 gunner clear' \
  'artytech 1 1' \
  'artytech 1 199' \
  'artytech 1 clear' \
  'reloadarty 1 badname' \
  'artytech 1 199' \
  'reloadarty 1 long_tom' \
  'artytech 1 clear' \
  'repairarty badid' \
  'repairarty 1' \
  'shiparty 1 hq:1' \
  'shiparty 1 co:1' \
  'shiparty 1' \
  'sellarty 1' \
  'candidates 9' \
  'who 9' \
  'who 99999' \
  'accept 9 1' \
  'day 3 force' \
  'inbox' \
  'resolve 999 1' \
  'battles' \
  'battles 999' \
  'read 999' \
  'help' \
  'load 999' \
  'briefing 999' \
  'confirm 999' \
  'rush 999' \
  'sell 3 4' \
  'xfer hull 3 co:1' \
  'autoadmit maybe' \
  'commit 999 999 break_enemy' \
  'commit 999 999 notanintent' \
  'tempo 9 1 advance' \
  'tempo 999 999 notaposture' \
  'intervene 9 1 emergency_recon' \
  'intervene 999 999 notakind' \
  'mech 3' \
  'mech 999' \
  'artillery' \
  'artillery 999 trailing' \
  'artillery 999' \
  'seat 999 badname 1' \
  'seat 999 commander 1' \
  'day 23 force' \
  'inbox' \
  'resolve 1 3' \
  'log 3' \
  'day 7 force' \
  'day 30 force' \
  'day 30 force' \
  'day 30 force' \
  'day 30 force' \
  'battle 9' \
  'battle 9 pursue' \
  'battle 9 reserve' \
  'commit 9 2 secure_objective' \
  'task 9 2 3 reserve' \
  'battle 9 engage' \
  'sell 3' \
  'battle 9 reserve' \
  'battle 9 call recon' \
  'battle 9 call air' \
  'battle 9 call recon' \
  'battle 9' \
  'battle 9 roe hold' \
  'battle 9 on' \
  'battle 9 consolidate' \
  'battle 9 withdraw' \
  'save' \
  'quit' > "$work/input"
# A watchdog kills a hung REPL (macOS has no `timeout`); the exit status
# is checked either way.
"$exe" --repl --store "$db" < "$work/input" > "$work/output" 2>&1 &
repl=$!
# The watchdog's sleep is its own child, killed with it, so none outlives
# the run.
(
  sleep "${SMOKE_TIMEOUT_S:-300}" &
  nap=$!
  trap 'kill "$nap" 2>/dev/null; exit 0' TERM
  wait "$nap" && kill -9 "$repl" 2>/dev/null
) &
watchdog=$!
status=0
wait "$repl" || status=$?
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
out=$(cat "$work/output")
if [ "$status" -ne 0 ]; then
  echo "REPL exited with status $status (killed after ${SMOKE_TIMEOUT_S:-300}s if 137)"
  echo "$out" | tail -40
  exit 1
fi
check() { echo "$out" | grep -q -- "$1" || { echo "MISSING: $1"; echo "$out" | tail -40; exit 1; }; }
check 'no air wing slot'
check 'that HQ has no free company slot'
check 'role .*have  need'
check 'banked XP'
check 'Dragoons rating'
check 'RATING BY YEAR'
check 'done.'
check 'hired #'
# 12G.1: the inbox prints event ids and `resolve` takes one, so an id that
# is not in the queue is refused instead of hitting whatever sits in row 999.
check 'inbox'
check 'no pending decision'
# 12G.4: engagements are kept as records the screens read; an id that is
# not on record is refused rather than printing someone else's battle.
check 'AFTER-ACTION REPORTS\|no engagements on record'
check 'no engagement on record with that id'
# 12G.5: `read` clears the after-action that holds the turn; a bad id is refused.
check 'no engagement on record with that id'
check 'fabricate'
# A campaign id with no campaign row is refused, not loaded blank.
check 'load failed: no saved campaign has that id'
# Battle orders need an engagement in view; an unknown contract is refused.
check 'no engagement on that contract is close enough to give orders for'
check 'no contract has that id'
# A leftover token or a word outside the choices is refused with the usage.
check 'those arguments do not fit the verb — usage: sell <unit>'
check 'those arguments do not fit the verb — usage: xfer unit|person'
check 'those arguments do not fit the verb — usage: autoadmit'
# P4d: commit requires an intent; an unknown intent is refused with the usage.
check 'usage: commit'
# P4f: tempo verb exercises and its refusal path (bad posture string is BadArguments).
check 'usage: tempo'
# P4g: intervene verb exercises and its refusal path (bad kind string is BadArguments).
check 'usage: intervene'
check 'stripped for parts'
check 'drew 500,000 c-bills over 12 months'
check 'under contract:'
check 'readiest co.'
check 'skull'
check 'advanced 3 day'
# `next 1` advances one day to its cap; a trailing token is refused with the usage.
check 'advance limit reached'
check 'those arguments do not fit the verb — usage: next'
# P3c.6: mech <unit id> prints the lifecycle summary; unknown id prints the usage line.
check 'engagements'
check 'usage: mech'
check 'saved campaign'
# P2i: artillery REPL surface — list, bad seat name, unknown formation id, trailing token.
check 'no artillery formations'
check 'usage: seat'
check 'no artillery formation has that id'
check 'usage: artillery'
# P2i artillery arc: nine verbs exercised with funded HQ
check 'Mobile Long Tom'
check 'bought Mobile Long Tom #'
check 'attached to'
check 'seated'
check 'detached to HQ pool'
check 'seat cleared'
check 'tech cleared'
check 'lacks the artillery seat'
check 'usage: reloadarty'
check 'not enough of that part in stock'
check 'usage: repairarty'
check 'refused: the artillery carrier needs'
check 'required home HQ pool'
# Field freight to a company at home is refused with its remedy; the verb
# names both destinations.
check 'that company is home — attach the carrier at its home HQ instead'
check 'usage: shiparty <formation-id> hq:N|co:N'
check '#1 sold'
# P5b.1: a due engagement holds the turn and is fought in phases through
# `battle`: an order not legal at the pause and any other command under the
# battle lock are refused; the AAR names each phase and its order.
check 'an engagement waits on your orders'
check 'battle 9 engage'
check 'refused: that order cannot be given at this point of the battle'
check 'engage: contact fought — the battle pauses for orders'
check 'refused: a battle is being fought'
check 'ROE hold for the next phase — the odds are recomputed'
check 'press on: decisive fought'
check 'the battle is over — after-action #'
check 'AAR\]   contact — engage: margin'
# P5b.2: at the contact pause the reserve is committed and recon called on
# the committed Repel Probe; air cover without a fighter, recon a second
# time, and a lever before contact are refused; the AAR names each lever.
check 'battle 9 reserve  *commit the reserve'
check 'commit the reserve for the decisive phase — the odds are recomputed'
check 'call emergency recon for the decisive phase — the odds are recomputed'
check 'refused: the intervention gate is not met'
check 'refused: that intervention has already been applied to this operation'
check 'levers: decisive roll +4 · 1 command capacity spent · the reserve is committed'
check 'AAR\]   contact pause — commit the reserve: decisive roll +2'
check 'AAR\]   contact pause — call emergency recon: 1 capacity, decisive roll +2'
# P5c: on the 1st the garrison arc's contract raises a situation in the
# inbox instead of rolling the monthly deck; `resolve` answers it by id and
# the log names the owner, the answer and its cost.
check '\[1\] situation Alpha'
check '(Black Market Contact) offers crates of munitions'
check '3: Send them away   \[morale -2\]   nothing changes hands (default)'
check '\[situation\] .* (Black Market Contact): chose "Send them away" — morale -2 · nothing changes hands'
# P5d.1a: `who` lists the leaders, a faction's leader then its governors, and
# a world's governor, each labelled with its provenance; an unknown key is
# refused with the usage.
check 'Leader, Draconis Combine'
check 'Leader, Lyran Commonwealth .* LC '
check 'Governor of Tharkad'
check 'Governor of Skye'
check '\[procedural\]'
check 'those arguments do not fit the verb — usage: who'
# `who <contract id>` names the governor of the offer's world and its
# employer's and enemy's leaders; an id no contract has is refused.
check 'world  *#[0-9]*  Governor of'
check 'employer  #[0-9]*  Leader, '
check 'could not show that: no contract has that id'
echo "REPL SMOKE OK"
