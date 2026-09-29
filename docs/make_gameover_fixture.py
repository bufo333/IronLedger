#!/usr/bin/env python3
"""Generate a bankrupt GAME OVER fixture for tui_smoke.py.

Runs the game binary in REPL mode to create a real campaign at the current
schema, then sets the persisted `bankrupt` meta int so the TUI shows the
GAME OVER modal on the first advance.

The fixture is regenerated from the current binary on every run, so it is
always at the current schema.  The only schema coupling is the `bankrupt`
key in the `meta` table (store.zig saveMeta; loaded at store.zig loadMeta).
Exactly one campaign's bankrupt flag is flipped; if the key is renamed or
removed the assertion below fails immediately (rule 44 / persist-store-lifecycle
plan).

Usage:
    python3 docs/make_gameover_fixture.py <game-bin> <out.db>
"""
import os, subprocess, sys, sqlite3

if len(sys.argv) != 3:
    sys.exit(f"usage: {sys.argv[0]} <game-bin> <out.db>")

exe = sys.argv[1]
out_db = sys.argv[2]

if not out_db.endswith(".db"):
    sys.exit(f"refusing path {out_db!r}: must end in .db")
if os.path.lexists(out_db) and (os.path.islink(out_db) or not os.path.isfile(out_db)):
    sys.exit(f"refusing path {out_db!r}: exists and is not a regular file")
if os.path.exists(out_db):
    os.remove(out_db)

# Run the REPL to create a real, loadable campaign at the current schema.
# Token order: start <faction> <profession> <commander-name> (src/sim/cli.zig).
repl_input = b"new\nstart FS paymaster Ada\nsave\nquit\n"
result = subprocess.run(
    [exe, "--repl", "--store", out_db],
    input=repl_input,
    capture_output=True,
)
if result.returncode != 0:
    sys.exit(f"REPL exited {result.returncode}:\n{result.stderr.decode()}")
combined = result.stdout.decode() + result.stderr.decode()
if "saved campaign" not in combined:
    sys.exit(f"save confirmation not found in REPL output:\n{combined}")

# Set the persisted bankrupt flag on the one campaign in the store.
con = sqlite3.connect(out_db)
cur = con.cursor()
cur.execute("UPDATE meta SET value = 1 WHERE key = 'bankrupt'")
assert cur.rowcount == 1, f"expected exactly one bankrupt row, got {cur.rowcount}"
con.commit()
con.close()

print("GAMEOVER FIXTURE OK")
