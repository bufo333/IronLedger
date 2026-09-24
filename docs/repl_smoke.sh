#!/bin/sh
# Drive the REPL through a script and grep for landmarks (Stage 12.18):
# the command verbs both frontends share, plus the print views.
#   docs/repl_smoke.sh zig-out/bin/game /tmp/repl.db
set -e
exe="$1"; db="$2"
rm -f "$db"
out=$(printf '%s\n' \
  'start LC quartermaster Erik Kalmar' \
  'newco Alpha' \
  'newlance co:1 air Sky Lance' \
  'wing co:1' \
  'raise hq:1 Bravo' \
  'manning co:1' \
  'readiness' \
  'rating' \
  'summary' \
  'sellstock hq:1 ammo_lrm 1' \
  'stockpolicy hq:1 ammo_lrm 4 8' \
  'autoadmit off' \
  'hire mekwarrior Grayson Carlyle' \
  'fabricate comp_arm 1' \
  'strip 3' \
  'roe co:1 cautious' \
  'loan 500000' \
  'candidates 0' \
  'accept 0 1' \
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
  'save' \
  'quit' | "$exe" --repl --store "$db" 2>&1)
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
check 'stripped for parts'
check 'drew 500000 c-bills over 12 months'
check 'under contract:'
check 'readiest co.'
check 'skull'
check 'advanced 3 day'
check 'saved campaign'
echo "REPL SMOKE OK"
