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
  'sellstock hq:1 ammo_lrm 1' \
  'stockpolicy hq:1 ammo_lrm 4 8' \
  'autoadmit off' \
  'hire mekwarrior Grayson Carlyle' \
  'fabricate comp_arm 1' \
  'loan 500000' \
  'accept 0 1' \
  'day 3 force' \
  'help' \
  'save' \
  'quit' | "$exe" --repl --store "$db" 2>&1)
check() { echo "$out" | grep -q -- "$1" || { echo "MISSING: $1"; echo "$out" | tail -40; exit 1; }; }
check 'no air wing slot'
check 'CapacityFull'
check 'role              have  need'
check 'banked XP'
check 'done.'
check 'hired #'
check 'fabricate'
check 'drew 500000 c-bills over 12 months'
check 'under contract:'
check 'advanced 3 day'
check 'saved campaign'
echo "REPL SMOKE OK"
