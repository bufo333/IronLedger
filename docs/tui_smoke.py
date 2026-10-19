#!/usr/bin/env python3
"""Drive the TUI through a pty: create a player, walk the wizard, begin a
campaign, end a turn, quit back to the lobby, and exit. Prints the last
screen and asserts on landmarks.

    python3 docs/tui_smoke.py zig-out/bin/game [store.db]

With no store path the script uses a private temporary directory. A given
path must end in `.db` and, if it exists, be a regular file: it is
replaced. Every client is reaped: a failed assertion or the overall
timeout kills whatever is still running, and a clean pass requires each
client to exit with status 0."""
import atexit, os, pty, shutil, sys, tempfile, time, select, re, struct, fcntl, termios, signal

# The whole script; a hung client fails instead of blocking CI.
TIMEOUT_S = int(os.environ.get("SMOKE_TIMEOUT_S", "600"))

exe = sys.argv[1]
if len(sys.argv) > 2:
    db = sys.argv[2]
    if not db.endswith(".db"):
        sys.exit(f"refusing store path {db!r}: it must end in .db")
    if os.path.lexists(db) and (os.path.islink(db) or not os.path.isfile(db)):
        sys.exit(f"refusing store path {db!r}: it exists and is not a regular file")
    if os.path.exists(db):
        os.remove(db)
else:
    tmp = tempfile.mkdtemp(prefix="iron-ledger-tui-smoke-")
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)
    db = os.path.join(tmp, "smoke.db")

children = []  # every client pid, reaped at exit whatever happened


def reap_all():
    for child in children:
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(child, 0)
        except ChildProcessError:
            pass


atexit.register(reap_all)


def on_timeout(signum, frame):
    raise TimeoutError(f"TUI smoke exceeded {TIMEOUT_S}s")


signal.signal(signal.SIGALRM, on_timeout)
signal.alarm(TIMEOUT_S)


def spawn(args):
    child, master = pty.fork()
    if child == 0:
        os.execv(exe, [exe, *args])
    children.append(child)
    return child, master


def finish(child, timeout=10.0):
    """Wait for a client that was told to quit; it must exit with status 0."""
    end = time.time() + timeout
    while time.time() < end:
        drain(0.2)
        done, status = os.waitpid(child, os.WNOHANG)
        if done:
            children.remove(child)
            assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, f"client exited abnormally: status {status}"
            return
    raise AssertionError(f"client {child} did not exit within {timeout}s of quitting")


pid, fd = spawn(["--tui", "--no-splash", "--no-music", "--seed", "3025", "--store", db])

# 200x50 terminal
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))

out = b""

# How long the client must be silent before we call a frame finished. The
# TUI paints in single-digit milliseconds, so this is the whole cost of a
# keystroke on a healthy machine; `t` is only the ceiling for a slow one.
IDLE = 0.08

def drain(t=0.6, idle=IDLE):
    """Read until the client goes quiet, or `t` elapses — whichever first.

    `t` is a **ceiling, not a sleep**. The old version burned the full `t`
    on every call, which cost ~160s of doing nothing across the script's
    210 keystrokes. Waiting for quiet keeps the same safety margin on a
    loaded CI runner while returning in ~`idle` when the frame is already
    painted."""
    global out
    end = time.time() + t
    last = time.time()
    saw_any = False
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if chunk:
                out += chunk
                last = time.time()
                saw_any = True
                continue
        # Quiet for `idle` after something arrived: the frame is done.
        if saw_any and time.time() - last >= idle:
            return

def send(s, wait=0.5):
    os.write(fd, s.encode() if isinstance(s, str) else s)
    drain(wait)

def plain():
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out).decode("utf-8", "replace")

def wait_for(text, timeout=6.0, tail=30000):
    """Drain until `text` shows in the recent screen text (fixed sleeps race
    the client under load; the emblem editor was the usual victim)."""
    end = time.time() + timeout
    while time.time() < end:
        if text in plain()[-tail:]:
            return True
        drain(0.2)
    return False

assert wait_for("MERCENARY COMMAND CONSOLE", timeout=20), "welcome screen missing: " + plain()[-2000:]   # a cold runner takes a while to first paint
send("s", 0.8)
assert "SETTINGS" in plain()[-30000:], plain()[-2000:]
send("\x1b")
send("p"); send("John\r")
assert wait_for("player \"John\" created"), plain()[-3000:]   # the status line can land after the send's pause on a slow runner
send("p"); send("{c}Evil\r")                 # a name that looks like markup draws literally
assert wait_for('player "{c}Evil" created'), plain()[-3000:]
send("D", 0.6); send("{c}Evil\r", 0.8)     # and deleting it compares the raw name
assert wait_for('deleted player "{c}Evil"'), plain()[-3000:]
send("D", 0.6); send("nobody\r", 0.8)     # delete player: the typed name must match
assert "name did not match" in plain()[-800:], plain()[-1200:]
send("n")                      # new campaign
assert "NEW CAMPAIGN" in plain()
send("\r")                      # commander → outfit (catalog grid renders immediately; thumbnails load lazily)
assert wait_for("CATALOG"), plain()[-3000:]   # catalog grid pane appeared
assert wait_for("Ashfall Lancers"), plain()[-3000:]   # auto-fill from first catalog logo
send("\t\t", 0.3)              # Tab×2: field 0 → 1 → 2 (grid navigation mode)
send("l", 1.5)                 # right: w_logo 0 → 1 (Balance Point Mercenaries)
assert wait_for("Balance Point Mercenaries"), plain()[-3000:]  # auto-fill from second logo
company_from = len(out)
send("\r", 3.0)                # outfit → company (generates)
assert wait_for("STARTING COMPANY"), plain()[-3000:]
# The company step never calls the player's company generated
# (docs/p5d-conflict-world-design.md §F).
company_step = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[company_from:]).decode("utf-8", "replace")
assert "generated" not in company_step.lower(), company_step[-3000:]
assert "BACK OFFICE" in plain(), plain()[-3000:]   # sizing pane, wide or narrow
send("\t", 0.4); send("+", 0.8)  # one more command admin …
assert "hired one admin_command" in plain()[-1200:], plain()[-1500:]
send("-", 0.8)                     # … and back
assert "released one admin_command" in plain()[-1200:], plain()[-1500:]
send("\t", 0.4)
send("\r")                     # → review
assert "REVIEW" in plain()
send("\r", 2.0)                # begin
p = plain()
assert "F1 Desk" in p and "END-TURN CHECKLIST" in p, p[-4000:]
if b"38;2;" in out:
    print("emblem: half-block colour cells emitted")
send("2"); send("+", 0.6)       # map: zoom in twice, then back out
assert "zoom ×2" in plain()[-30000:], plain()[-3000:]
send("+", 0.6); send("-", 0.6); send("-", 0.6)
assert "zoom ×1" in plain()[-30000:], plain()[-3000:]
send("4")                      # contracts tab
assert "CONTRACT BOARD" in plain() and "HISTORY" in plain(), plain()[-3000:]
send("b", 0.8)                 # bargain: negotiation term picker on the offer under the cursor
assert "NEGOTIATE" in plain()[-30000:] and "salvage" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
sheet_from = len(out)
send("w", 0.8)                 # who's who for the offer under the cursor
p = plain()[-30000:]
assert "WHO'S WHO" in p and "Governor of" in p, plain()[-3000:]
# Every present seat lists its relations, or says it has none.
assert re.search(r"liege  [A-Z]|fealty of \d+ governor|no relations|(kin|rival|ally|grudge against|grudge borne by)  [A-Z]", p), plain()[-3000:]
# The sheet says nothing of where anyone comes from (docs/p5d-conflict-world-design.md §F).
sheet = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[sheet_from:]).decode("utf-8", "replace")
origin = re.search(r"\b(procedural|generated|generator|authored|author|canon|sarna|project character|provenance|source|fictional|invented|real)\b", sheet, re.I)
assert origin is None, f"origin word {origin.group(0) if origin else ''!r} on the who's who sheet: " + sheet[-3000:]
send("\x1b", 0.6)
send("\t"); send("\t", 0.6)    # focus the history pane; read-only
send("j"); send("c", 0.6)
assert "no closed contracts yet" in plain()[-30000:], plain()[-2000:]
send("\t", 0.6)
send("5")
assert "TREASURIES" in plain()
send("3")
assert "TO&E" in plain()
send("+", 0.8)                 # raise a company: the only HQ already hosts one,
send("Bravo\r", 0.8)           # so the command refuses once it is named
assert wait_for("that HQ has no free company slot", tail=1200), plain()[-1500:]
send("j"); send("w", 0.8)      # air wing: the starter HQ has a level-1 spaceport
assert "no air wing slot" in plain()[-800:], plain()[-1000:]
send(":", 0.6); send("newlance co:1 air Sky Lance\r", 1.0)
assert "no air wing slot" in plain()[-800:], plain()[-1000:]
send("k")
send("r", 0.8)                 # readiness pane on the company row
assert "READINESS" in plain()[-30000:] and "banked" in plain()[-30000:], plain()[-3000:]
send("r", 0.8)                 # manning pane: every role's have/need/open
assert "MANNING" in plain()[-30000:] and "astech" in plain()[-30000:], plain()[-3000:]
send("r", 0.6)                 # back to damage
send("c", 1.0)                 # crew from halls: fills the manning table (12B.13)
assert "hired to fill the manning table" in plain()[-1200:], plain()[-1500:]
send(":"); send("readiness\r", 0.8)
assert "READINESS · every company" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
send(":"); send("music\r", 0.8)            # soundtrack browser (no music in the smoke: says so)
assert "SOUNDTRACK" in plain()[-30000:] and "music off (--no-music)" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
send(":"); send("summary\r", 0.8)          # 12C.8 campaign summary
assert "CAMPAIGN SUMMARY" in plain()[-30000:] and "BATTLES" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
send(":"); send("role 3 defense\r", 0.8)         # shared parser: lance role
assert "done." in plain()[-800:], plain()[-1000:]
send(":"); send("autoadmit off\r", 0.8)
assert "done." in plain()[-800:], plain()[-1000:]
send(":"); send("manning co:1\r", 0.8)   # crews table for the existing company
assert "CREWS" in plain()[-30000:] and "mekwarrior" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
send("]", 0.6)                 # forces: page to the first company
assert "(2/" in plain()[-30000:], plain()[-3000:]
send("[", 0.6)
assert "all forces" in plain()[-30000:], plain()[-3000:]
send("[", 0.6)                 # wraps to the artillery panel (new last view)
assert "ARTILLERY" in plain()[-30000:], plain()[-3000:]
# Artillery panel: no formations, actions produce "no formation selected" not a crash.
send("e", 0.3)                 # arty_attach with no formation
assert "no artillery formation selected" in plain()[-30000:], plain()[-3000:]
# Colon-line sellarty with unknown id: TUI command line routes to the artillery sell handler.
send(":"); send("sellarty 999\r", 0.5)
assert wait_for("no artillery formation has that id", tail=30000), plain()[-3000:]
send("[", 0.6)                 # one more back: the hangar ranking
assert "hangar: cost vs contribution" in plain()[-30000:] and "cost index" in plain()[-30000:], plain()[-3000:]
send("]", 0.6)                 # hangar → artillery panel
send("]", 0.6)                 # artillery → all forces
send("7")
assert "back office" in plain() and "HIRING HALL" in plain()
send("u", 0.8)                 # cursor on the header row → picker
assert "UPGRADE ·" in plain()[-30000:] and "paperwork + build" in plain()[-30000:], plain()[-3000:]
send("\x1b")
send("j"); send("j"); send("j"); send("u", 0.8)   # cursor on the first facility row (tier line, blank, header, then facilities) → starts (or says why not)
p = plain()[-600:]
assert "upgrade started" in p or "refused:" in p, plain()[-1500:]
send("T", 0.8)                 # tier: the starter HQ is already regional → says so (the key exists)
assert "already at the top" in plain()[-800:], plain()[-1200:]
send("$", 0.8)                 # sell-HQ confirm: opens, Esc keeps it
assert "SELL HQ?" in plain()[-30000:] and "40% of build cost" in plain()[-30000:], plain()[-2000:]
send("\x1b", 0.6)
send("f"); send("f")
assert "filter techs" in plain(), plain()[-3000:]
send("2")                      # map
assert "Lyran Commonwealth" in plain()[-30000:], plain()[-3000:]   # faction legend in the side pane
p = plain()
assert "STAR MAP" in p and "REACH" in p, p[-3000:]
send("l"); send("j"); send("h"); send("k")
send("9")                      # people
p = plain()
assert "PERSONNEL" in p and "RECORD" in p and "OPEN SEATS" in p, p[-3000:]
send("/"); send("/")
assert "filter techs" in plain(), plain()[-2000:]
for _ in range(12):                         # … other → wounded (empty), then it must still cycle
    send("/", 0.5)
    if "filter wounded" in plain()[-30000:]: break
else:
    raise AssertionError(plain()[-2000:])
send("/", 0.6)                              # back to all — must not be stuck on the empty filter
assert "filter all" in plain()[-30000:], plain()[-2000:]
send("a", 0.8)                 # seat picker
assert "ASSIGN" in plain()[-30000:], plain()[-2000:]
send("\x1b")
send("D", 0.8)                 # fire confirm
assert "FIRE?" in plain()[-30000:], plain()[-2000:]
send("\x1b")
send("m", 0.8)                 # admit: refusal if healthy, admission if wounded
p = plain()[-400:]
assert "not wounded" in p or "admitted to the medbay" in p, plain()[-800:]
send("0")                      # market
p = plain()
assert "MARKET BOARD" in p and "pays from its treasury" in p and "ORDER CATALOG" in p and "DEMAND" in p, p[-3000:]
send("/", 0.8)                 # market filter cycles
assert "filter mechs" in plain()[-30000:], plain()[-3000:]
send(",", 0.8)
send("\t"); send("\r", 0.8)    # catalog → order prefill
assert ":order " in plain()[-300:], plain()[-600:]
send("\x1b"); send("K", 0.8)   # catalog → keep-stocked amount form (min 5, target 10)
assert " STOCKED" in plain()[-30000:] and "minimum" in plain()[-30000:], plain()[-3000:]
send("\r", 1.0)                 # set it
assert "KEEP STOCKED" in plain()[-30000:], plain()[-3000:]
send("\t"); send("\t", 0.6)    # focus the keep-stocked pane
send("x", 0.8)
assert "keep-stocked line for" in plain()[-600:], plain()[-800:]
send("\t", 0.6); send("K", 0.8); send("\r", 1.0)   # back to the catalogue: set it again for the Supply check
send("6")
assert "keep stocked" in plain()[-30000:], plain()[-3000:]
send("K", 0.8)                  # on the HQ row: the part picker, then the amount form
assert "KEEP WHICH PART STOCKED" in plain()[-30000:], plain()[-3000:]
send("\r", 0.8)
assert "minimum" in plain()[-30000:] and "target" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("$", 0.8)   # on the HQ row: the part picker (fullest shelf first), then the amount form
assert "SELL WHICH PART" in plain()[-30000:], plain()[-3000:]
send("\r", 0.8)
assert "quantity" in plain()[-30000:], plain()[-3000:]
send("\r", 1.0)
assert wait_for("done.", tail=2500) or "keep-stocked minimum" in plain()[-2500:], plain()[-800:]  # the footer redraw can push the message past a short window
send("\x1b")
send("3"); send("j", 0.6); send("j", 0.4); send("j", 0.4)  # forces: cursor onto a hull row (past company and lance header)
send("h", 0.8)                 # P3c.6: open the mech-detail modal on the hull
assert "MECH" in plain()[-30000:], plain()[-3000:]
send("c", 0.6)                 # switch to the combat sub-view
assert "MECH" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.5)              # Esc: step back to summary
send("\x1b", 0.5)              # Esc: close the modal
send("k", 0.3); send("k", 0.3)  # move back to the company row (2 up from hull)
send("j", 0.6)                 # cursor on the company → damage pane
assert "DAMAGE ·" in plain()[-30000:] or "every hull is whole" in plain()[-30000:], plain()[-3000:]
send("b", 0.8)
assert "needs no structural components" in plain()[-400:] or "FABRICATE" in plain()[-30000:], plain()[-800:]
send("\x1b")
send(":"); send("settings\r", 0.8)   # settings in-game: medbay auto-admit toggle
assert "auto-admit the wounded" in plain()[-30000:], plain()[-2000:]
send("a", 0.8)
assert "medbay auto-admit on" in plain()[-600:], plain()[-800:]
send("\x1b")
send("6")                      # supply: cash and provisions to a company
p = plain()
assert "STOCK ·" in p and "INBOUND" in p and "capacity" in p, p[-3000:]
send("j"); send("j"); send("j")                     # onto the company block
send("t", 0.8)                                        # cash to the company: amount form
assert "SEND CASH TO" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("p", 0.8)                          # cash policy: amount form (floor, cap)
assert "CASH POLICY" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("s", 0.8)                          # ship: the part picker (home shelf), then the amount form to this company
assert "SHIP WHICH PART" in plain()[-30000:], plain()[-3000:]
send("\r", 0.8)
assert "SHIP " in plain()[-30000:] and "quantity" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("R", 0.8)                          # trim field stores to the plan (company at home: nothing or something, never an error)
assert "match the field plan" in plain()[-600:] or "to the home HQ" in plain()[-600:], plain()[-800:]
send("P", 0.8)                                        # resupply policy: amount form (days, tons, battles)
assert "RESUPPLY POLICY" in plain()[-30000:], plain()[-3000:]
send("\r", 1.0)                                       # set it: 14 safety days
assert "resupply plan on (14 safety days, ammo auto)" in plain()[-30000:], plain()[-2000:]
assert "field plan" in plain()[-30000:], plain()[-2000:]
send("5"); send("j", 0.6); send("j", 0.6); send("p", 0.8)   # ledger: cash policy form for the selected company
assert "CASH POLICY" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("x", 0.8)                          # clears the resupply policy set above (no cash policy yet)
assert "policy for" in plain()[-600:] and "cleared" in plain()[-600:], plain()[-800:]
send("5"); send("L", 0.8)      # ledger → loan form (principal, months)
assert "TAKE A LOAN" in plain()[-30000:], plain()[-3000:]
send("\x1b")
send("3"); send("j"); send("j"); send("$", 0.8)   # sell hull confirm
assert "SELL OR STRIP HULL?" in plain()[-30000:], plain()[-3000:]
send("\x1b")
send("k"); send("X", 0.8)      # disband confirm on the company row: opens, Esc keeps it
assert "DISBAND COMPANY?" in plain()[-30000:] and "cannot be undone" in plain()[-30000:], plain()[-2000:]
send("\x1b", 0.6)
mark = len(out)
send("4", 1.0)                 # contracts board at 200 wide: droppable tail columns leave before anything scrolls
board = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark:]).decode("utf-8", "replace")
assert "CONTRACT BOARD" in board and "▶" not in board and "◀" not in board, board[-3000:]
send("1"); send("b", 0.8)      # Desk: the after-action reports
assert "AFTER-ACTION REPORTS" in plain()[-30000:], plain()[-3000:]
send("\r", 0.8)               # Enter reads one (or does nothing when none are on record)
send("\x1b", 0.5); send("\x1b", 0.5)
send("1"); send("\t", 0.4); send("\t", 0.4); send("\r", 1.0)   # Desk LOG pane: Enter opens the whole entry, wrapped
assert "LOG ENTRY" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
send("e", 1.5)                 # emblem picker on the Desk
p = plain()
assert "EMBLEM ·" in p and "preset   Wolf's Head" in p, p[-2000:]
send("j"); send("\r", 1.0)     # pick the second preset
assert "emblem set to preset" in plain(), plain()[-2000:]
send("e", 1.0)                 # 12.14: the cell editor is the last row of the picker
for _ in range(100): send("j", 0.05)  # overshoot; the list clamps to the editor row
send("\r", 1.0)
assert wait_for("EMBLEM EDITOR"), plain()[-3000:]
send("X"); send("Y", 0.5)      # paint two cells, then save
send("\r", 1.0)
assert wait_for("emblem set to your own crest", tail=2000), plain()[-2000:]
send("8")                      # lab
p = plain()
assert "HD" in p and "CT" in p and "RULES: legal fit" in p, p[-3000:]
send("-", 0.8)                 # stage a removal
assert "remove" in plain(), plain()[-2000:]
send("+", 0.8)                 # install picker: part, then location
assert "INSTALL · pick a part" in plain()[-30000:], plain()[-3000:]
send("\r", 0.8)
assert "pick a location" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("\x1b")
send("c", 0.8)                 # clear the plan
send("1")
send(".", 1.5)                 # end the turn: one day (y confirms past the checklist)
p = plain()
if "END TURN?" in p:
    send("y", 1.5)
assert "day 1" in plain(), plain()[-2000:]
# n advances to the next stop and opens the stop screen, titled with the day
# it stopped on; Enter leaves it for the screen it names.
mark_n = len(out)
send("n", 5.0)
after_n = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark_n:]).decode("utf-8", "replace")
stop = re.search(r"STOPPED · day (\d+)", after_n)
assert stop and int(stop.group(1)) > 1, "n did not reach the stop screen: " + after_n[-1000:]
stopped_on = int(stop.group(1))
send("\r", 1.0)
send(":"); send("day 3\r", 2.0)
assert f"day {stopped_on + 3}" in plain()[-30000:], plain()[-2000:]
# A position that fights: an arc contract whose backer names an opposition
# (docs/p5d-conflict-world-design.md §A; a standing need's garrison names
# none). The board is read week by week until one is posted on the seat's
# board; its id is the row's first cell.
ARC_COMBAT = r"(relief duty|diversionary raid|objective raid|guerrilla warfare)"
fought = None
for _ in range(20):
    mark_board = len(out)
    send("4", 1.0)
    frame = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark_board:]).decode("utf-8", "replace")
    for row in re.finditer(r"│\s*(\d+)\s+" + ARC_COMBAT + r"\s[^│]*●", frame):
        fought = row.group(1)
        break
    if fought:
        break
    send(":"); send("day 7\r", 2.0)
    send("\x1b", 0.5)
assert fought, "no fought arc position reached the seat's board: " + plain()[-3000:]
assert "why " in plain()[-30000:], plain()[-3000:]   # the selected offer's cause line
# Battle orders: the advance stops short of contact and opens the box;
# → changes the ROE, confirm clears the warning, and the next advance
# runs on to the fight instead of stopping again.
send(":"); send(f"accept {fought} 1\r", 1.5)
# Operations board and tempo picker: P4f.
# has_ops tracks whether the ops board was shown so the P4g block can skip
# safely when the garrison arc is not available.
send("4", 0.6)                   # contracts tab
send("\t", 0.6)                  # focus the active-contracts pane (pane 1)
mark_ops = len(out)
send("g", 0.8)                   # request operations board for the active contract
ops_frame = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark_ops:]).decode("utf-8", "replace")
has_ops = "OPERATIONS" in ops_frame
if has_ops:
    if "no operations on this contract" not in ops_frame:
        send("r", 0.8)           # open tempo posture picker (op is still available)
        assert "TEMPO POSTURE" in plain()[-30000:], plain()[-3000:]
        send("\r", 0.8)          # confirm: select the first posture (advance)
    send("\x1b", 0.5)            # close operations modal
else:
    send("\x1b", 0.5)            # close any modal that opened
for _ in range(8):
    send(":"); send("day 30\r", 2.5)
    if "BATTLE ORDERS" in plain()[-20000:]:
        break
    send("\x1b", 0.5)
assert "contact ahead: battle orders" in plain()[-2000:], plain()[-3000:]
send("\x1b[C", 1.0)
assert "ROE → cautious" in plain()[-2000:], plain()[-3000:]
send("k", 0.5)                 # the cursor wraps: up from the ROE is confirm
send("\r", 1.0)
assert wait_for("battle orders given", tail=2000), plain()[-3000:]
mark = len(out)
send(":"); send("day 30\r", 2.5)
after = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark:]).decode("utf-8", "replace")
assert "contact ahead" not in after and "BATTLE ORDERS" not in after, after[-3000:]


def fight_battle(refuse_first, levers=False):
    """P5b.1: the advance stops on the engagement's day and opens the battle
    screen. Engage, press on, then consolidate a held field — or, when that
    is refused on a lost one, withdraw; the after-action opens and Esc reads it.
    P5b.2 (levers): at the contact pause commit the reserve, call the first
    intervention from its row, and be refused air cover (no fighter)."""
    assert wait_for("BATTLE ·", tail=30000), plain()[-3000:]
    if refuse_first:
        send("p", 0.8)                 # press on before contact is joined: refused
        assert wait_for("cannot be given at this point of the battle", tail=2500), plain()[-3000:]
    send("e", 1.5)
    assert wait_for("contact fought", tail=30000), plain()[-3000:]
    if levers:
        send("R", 1.5)                 # commit the reserve
        assert wait_for("commit the reserve for the decisive phase", tail=4000), plain()[-3000:]
        send("i", 0.5)                 # the cursor to the first intervention: emergency recon
        send("\r", 1.5)
        assert wait_for("call emergency recon for the decisive phase", tail=4000), plain()[-3000:]
        send("i", 0.3); send("i", 0.3); send("i", 0.5)   # recon → reinforce → air cover
        send("\r", 1.5)
        # Refused for want of a fighter, or for weather that grounds one.
        assert wait_for("the intervention gate is not met", tail=4000) or "the weather has grounded the fighters" in plain()[-4000:], plain()[-3000:]
        assert wait_for("the reserve is committed", tail=30000), plain()[-3000:]
        print("battle levers OK")
    send("p", 1.5)
    assert wait_for("decisive phase fought", tail=30000), plain()[-3000:]
    send("c", 1.5)                     # an after-action ignores the w that follows
    send("w", 1.5)
    assert wait_for("the battle is over", tail=30000), plain()[-3000:]
    mark_read = len(out)
    send("\x1b", 0.8)                  # read the after-action
    # The decisions the fight raised open one after another: answer each.
    # A decision modal (its title, not a logged "DECISION:") keeps its key
    # hint in the foot; the first is also shrunk to 80x24, where a long one
    # scrolls. Returns how many decision modals were answered.
    modals = 0
    for _ in range(6):
        frame = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark_read:]).decode("utf-8", "replace")
        if "DECISION" not in frame[-6000:]:
            break
        screen = frame[-(200 * 50):]   # one whole 200x50 repaint
        if "DECISION · [" in screen:
            assert "decide later" in screen, screen[-3000:]
            modals += 1
            if modals == 1:
                mark_narrow = len(out)
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                os.kill(pid, signal.SIGWINCH)
                drain(1.0)
                narrow = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark_narrow:]).decode("utf-8", "replace")
                assert "DECISION · [" in narrow and "decide later" in narrow, narrow[-2000:]
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
                os.kill(pid, signal.SIGWINCH)
                drain(1.0)
                print("decision at 80x24 OK")
        mark_read = len(out)
        send("1", 1.0)
    return modals


assert fight_battle(True) > 0, "the first battle raised no decision modal: " + plain()[-3000:]
send("\x1b", 0.5); send("\x1b", 0.5)
# P4g: exercise the intervention picker on a committed combat op.  The
# contract's scheduled battle above has been resolved; the contract is still
# active; its arc's first operation, a combat one, is still in the
# .available state.  Commit it now — the contract is well past its transit
# window (the battle loop advanced ≥ 60 days) — then open the ops board and
# verify the picker. After the check, advance through the committed battle
# and read the after-action so the second client starts with no unresolved
# turn holds.
if has_ops:
    send(":"); send(f"commit {fought} 1 secure_objective\r", 1.0)
    send(":"); send(f"task {fought} 1 3 reserve\r", 1.0)   # the 2nd Lance stands as the reserve
    send("4", 0.6); send("\t", 0.6)   # contracts tab, active-contracts pane
    send("g", 0.8)                    # open operations board, cursor on the committed first op
    send("i", 0.8)                    # open intervention picker on the committed op
    assert "INTERVENTION" in plain()[-30000:], plain()[-3000:]
    send("\x1b", 0.5)                 # close intervention picker
    send("\x1b", 0.5)                 # close operations modal
    # Advance with force until the committed battle comes due and holds the
    # turn (within the longest engagement gap), then fight it.
    due = False
    for _ in range(8):
        mark_day = len(out)
        send(":"); send("day 3 force\r", 2.0)
        if "BATTLE ·" in re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark_day:]).decode("utf-8", "replace"):
            due = True
            break
        send("\x1b", 0.5)
    assert due, plain()[-3000:]
    fight_battle(False, levers=True)
    send("\x1b", 0.5)                 # close any decision modal that auto-opened
# Layout-boundary smoke: Forces focus must not wedge on a narrow resize.
# Switch to Forces, Tab to the pool pane (focus 1), shrink to 118 columns
# (below the 120-column boundary: only pane 0 draws), drain, assert the
# client is alive and TO&E shows (clampFocus sent focus back to 0); widen
# again and confirm the pool pane reappears; restore before continuing.
send("3")
assert wait_for("TO&E"), plain()[-2000:]
send("\t", 0.4)                # move focus to pool pane (focus 1 at 200 wide)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 118, 0, 0))
os.kill(pid, signal.SIGWINCH)
drain(1.0)
assert "TO&E" in plain()[-30000:], "Forces: TO&E missing after narrow resize: " + plain()[-2000:]
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 122, 0, 0))
os.kill(pid, signal.SIGWINCH)
drain(1.0)
assert "UNASSIGNED POOL" in plain()[-30000:], "Forces: UNASSIGNED POOL missing after wide resize: " + plain()[-2000:]
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
os.kill(pid, signal.SIGWINCH)
drain(1.0)
send("q"); send("s", 1.5)      # save and return
p = plain()
assert "back at the welcome screen" in p, p[-3000:]
send("\t", 0.5); send("d", 0.6); send("wrong name\r", 0.8)   # delete campaign: the typed name must match
assert "name did not match" in plain()[-800:], plain()[-1200:]
# Resize mid-session: the client redraws to the new size (SIGWINCH).
# Measure only the bytes the resize produced — a fixed tail of `out` reaches
# back into the 200-wide frames whenever an earlier step shifts the offsets.
mark = len(out)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 110, 0, 0))
os.kill(pid, signal.SIGWINCH)
runs = []
end = time.time() + 8
while time.time() < end:
    drain(0.3)
    redraw = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark:]).decode("utf-8", "replace")
    runs = [len(m) for m in re.findall(r"─+", redraw)]   # pane borders fit the new width, not the old 200
    if runs and max(runs) < 112:
        break
assert "MERCENARY" in plain()[-8000:] and runs and 60 < max(runs) < 112, (max(runs) if runs else None, plain()[-2000:])
send("q", 0.5)
drain(0.5)
finish(pid)
print(plain()[-6000:])

# ---- second pass: the minimum tier (80x24) and --ascii, every screen ----
pid, fd = spawn(["--tui", "--ascii", "--no-splash", "--no-music", "--seed", "3025", "--store", db])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
out = b""
assert wait_for("MERCENARY", timeout=20), plain()[-2000:]
send("\t"); send("\r", 3.0)
assert wait_for("F1 Desk", timeout=20) and "+-" in plain(), plain()[-2000:]          # ascii borders
# The seeded campaign is saved with a decision still in its inbox: the Desk
# opens it at 80x24 in --ascii, and its key hint stays in the foot. A
# resolved or missing decision has no "decide later", so this cannot pass
# without one.
send("1"); send("\t", 0.6)     # the INBOX pane, cursor on the first decision
mark = len(out)
send("\r", 1.0)
narrow = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[mark:]).decode("utf-8", "replace")
assert "DECISION · [" in narrow and "decide later" in narrow, narrow[-2000:]
send("\x1b", 0.6)              # decide later: the decision stays in the inbox
print("decision at 80x24 --ascii OK")
for k in "234567891":
    send(k, 0.6)
send("4"); send("\x1b[C", 0.6); send("\x1b[C", 0.6)        # contracts board at 80 wide: what cannot drop scrolls
assert re.search(r"< \d", plain()[-30000:]), plain()[-3000:]
send("\x1b[D", 0.6); send("\x1b[D", 0.6)
send("3"); send("j"); send("j"); send("\r", 0.8)            # hull modal at narrow width
assert "HULL" in plain(), plain()[-2000:]
send("\x1b")
send(":"); send("acc"); send("\t", 0.6)                     # completion: unique verb
assert ":accept _" in plain()[-300:], plain()[-800:]
send("\x1b")
send(":"); send("tra"); send("\t", 0.6)                     # ambiguous: candidates listed
p = plain()[-300:]
assert "transfer" in p and "train" in p, p
send("\x1b")
send(".", 2.0)
if "END TURN?" in plain(): send("y", 2.0)
send("q"); send("r"); send("q")
drain(0.5)
finish(pid)
print("80x24 + --ascii pass OK")


def last_style(raw, pattern):
    """The SGR parameters in force where `pattern` was last drawn: the last
    `ESC[...m` before its last match in the client's output."""
    found = list(re.finditer(pattern, raw))
    if not found:
        return None
    styles = re.findall(rb"\x1b\[([0-9;]*)m", raw[:found[-1].start()])
    return styles[-1].decode() if styles else None


def artillery_phase():
    """Artillery panel with a pooled carrier: fund the HQ and buy one with
    colon-line verbs (loan, transfer to the HQ, four days for the courier,
    buyarty), then record how the carrier row, the panel titles and the
    detail pane are drawn at 120x40 and 80x24 with focus on each pane. The
    focused list must draw the carrier row with the cursor, never as dim
    chrome; the send picker opens; a TO&E-only key says where it acts."""
    import tempfile, shutil
    arty_tmp = tempfile.mkdtemp(prefix="iron-ledger-arty-smoke-")
    atexit.register(shutil.rmtree, arty_tmp, ignore_errors=True)
    arty_pid, arty_fd = spawn(["--tui", "--no-splash", "--no-music", "--seed", "3025", "--store", os.path.join(arty_tmp, "arty.db")])
    fcntl.ioctl(arty_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    global fd, out
    saved_fd, saved_out = fd, out
    fd, out = arty_fd, b""

    def resize(rows, cols):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(arty_pid, signal.SIGWINCH)
        drain(1.0)

    def record(label):
        styles = {name: last_style(out, pattern) for name, pattern in (
            ("carrier row", rb"(?<!Artillery )#1  hull #\d+  quality"),
            ("list title", rb"ARTILLERY \("),
            ("detail title", rb"ARTILLERY DETAIL"),
            ("detail header", rb"Artillery #1  hull #\d+"),
        )}
        print(f"grey probe {label}: " + ", ".join(f"{k}={v}" for k, v in styles.items()))
        return styles

    try:
        assert wait_for("MERCENARY", timeout=20), "artillery: welcome screen missing: " + plain()[-2000:]
        send("p"); send("Gunner\r")
        assert wait_for('player "Gunner" created'), plain()[-3000:]
        send("n")
        assert wait_for("NEW CAMPAIGN"), plain()[-3000:]
        send("\r")
        assert wait_for("CATALOG"), plain()[-3000:]
        send("\r", 3.0)
        assert wait_for("STARTING COMPANY"), plain()[-3000:]
        send("\r")
        assert wait_for("REVIEW"), plain()[-3000:]
        send("\r", 2.0)
        assert wait_for("F1 Desk"), plain()[-3000:]
        send(":"); send("loan 800000\r", 0.8)
        send(":"); send("transfer outfit hq:1 800000\r", 0.8)
        send(":"); send("day 4 force\r", 2.0)
        send(":"); send("buyarty 1 hq:1\r", 1.0)
        assert wait_for("bought Mobile Long Tom #1", tail=3000), plain()[-3000:]
        send("3", 0.8)
        send("\t", 0.6)                # focus the TO&E's pool pane first
        send("[", 0.8)                 # all forces wraps back to the artillery panel
        assert wait_for("ARTILLERY (", tail=30000), plain()[-3000:]
        resize(40, 120)
        entered = record("120x40 entered from the pool pane")
        assert entered["carrier row"] == "0;30;46", f"entering the panel from another pane leaves the carrier without a cursor ({entered['carrier row']})"
        wide_list = record("120x40 focus list")
        send("\t", 0.8)                # focus the detail pane
        wide_detail = record("120x40 focus detail")
        send("\t", 0.8)                # back to the list
        resize(24, 80)
        narrow_list = record("80x24 focus list")
        for label, styles in (("120x40", wide_list), ("80x24", narrow_list)):
            row = styles["carrier row"]
            assert row is not None and row != "0;90", f"{label}: carrier row drawn as dim chrome ({row})"
            assert row == "0;30;46", f"{label}: focused list shows no cursor on the carrier ({row})"
        assert wide_detail["carrier row"] != "0;90", f"120x40 detail focus: carrier row drawn dim ({wide_detail['carrier row']})"
        resize(40, 120)
        send("x", 0.8)                 # the send picker for the carrier under the cursor
        assert wait_for("SEND ARTILLERY #1 TO", tail=30000), plain()[-3000:]
        send("\x1b", 0.6)
        send("l", 0.8)                 # a TO&E-only key says where it acts
        assert wait_for("that key acts on TO&E rows", tail=3000), plain()[-3000:]
        send("q", 0.8); send("r", 1.0)  # leave without saving
        assert wait_for("MERCENARY", tail=8000), plain()[-3000:]
        send("q", 0.5)
    finally:
        fd, out = saved_fd, saved_out

    finish(arty_pid, timeout=10)
    print("artillery panel phase OK")


def game_over_phase():
    """GAME OVER smoke: load a bankrupt fixture, advance one forced day,
    assert the modal.  Runs the fixture generator each time so the store
    is always at the current schema."""
    import tempfile, shutil, subprocess
    go_tmp = tempfile.mkdtemp(prefix="iron-ledger-gameover-smoke-")
    atexit.register(shutil.rmtree, go_tmp, ignore_errors=True)
    gameover_db = os.path.join(go_tmp, "gameover.db")

    # Generate the bankrupt fixture from the current binary.
    gen = subprocess.run(
        [sys.executable, "docs/make_gameover_fixture.py", exe, gameover_db],
        capture_output=True,
        text=True,
    )
    assert gen.returncode == 0, f"fixture generator failed:\n{gen.stdout}\n{gen.stderr}"
    assert "GAMEOVER FIXTURE OK" in gen.stdout, f"unexpected generator output:\n{gen.stdout}"

    # Spawn the TUI with the bankrupt store; no splash so we get the welcome screen fast.
    go_pid, go_fd = spawn(["--tui", "--no-splash", "--no-music", "--seed", "3025", "--store", gameover_db])
    fcntl.ioctl(go_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
    global fd, out
    saved_fd, saved_out = fd, out
    fd, out = go_fd, b""

    try:
        assert wait_for("MERCENARY", timeout=20), "game-over: welcome screen missing: " + plain()[-2000:]
        # Tab to the campaigns pane, Enter to load the bankrupt campaign.
        send("\t")
        send("\r", 2.0)
        assert wait_for("loaded", timeout=10), "game-over: 'loaded' not seen after opening campaign: " + plain()[-2000:]
        # Force one day: bypasses the checklist gate; the bankrupt flag triggers
        # handleGameOver immediately (tick.zig Bankrupt → app.zig handleGameOver).
        send(":"); send("day 1 force\r", 3.0)
        assert wait_for("BANKRUPT", timeout=10), "game-over: BANKRUPT modal missing: " + plain()[-3000:]
        p = plain()
        assert "BANKRUPT — GAME OVER" in p or "BANKRUPT" in p, "game-over: title missing: " + p[-2000:]
        assert "saved as it ended" in p, "game-over: save confirmation missing: " + p[-2000:]
        # Leave the modal and quit.
        send("\r", 1.0)
        send("q", 1.0)
    finally:
        fd, out = saved_fd, saved_out

    finish(go_pid, timeout=10)
    print("GAME OVER phase OK")


artillery_phase()
game_over_phase()
print("SMOKE OK")
