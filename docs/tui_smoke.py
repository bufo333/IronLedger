#!/usr/bin/env python3
"""Drive the TUI through a pty: create a player, walk the wizard, begin a
campaign, end a turn, quit back to the lobby, and exit. Prints the last
screen and asserts on landmarks."""
import os, pty, sys, time, select, re, struct, fcntl, termios, signal

exe = sys.argv[1]
db = sys.argv[2]
if os.path.exists(db):
    os.remove(db)

pid, fd = pty.fork()
if pid == 0:
    os.execv(exe, [exe, "--tui", "--no-splash", "--no-music", "--store", db])

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
send("\r")                     # commander → outfit (defaults)
send("\t"); send("\t")         # emblem field
send("l", 3.0)                 # import: lists PNGs and previews the first
p = plain()
assert "PNG files in" in p, p[-3000:]
if "loaded" in p:
    # The display line names the render path: half-blocks (truecolor or 256-colour
    # under a bare pty), the kitty protocol or iTerm2 images.
    assert "half-block" in p or "graphics protocol" in p or "inline images" in p, p[-3000:]
send("\r", 3.0)                # outfit → company (generates)
assert "GENERATED COMPANY" in plain()
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
send("\t"); send("\t", 0.6)    # focus the history pane; read-only
send("j"); send("c", 0.6)
assert "no closed contracts yet" in plain()[-30000:], plain()[-2000:]
send("\t", 0.6)
send("5")
assert "TREASURIES" in plain()
send("3")
assert "TO&E" in plain()
send("+", 0.8)                 # raise a company: the only HQ already hosts one
assert "no HQ has a free company slot" in plain()[-600:], plain()[-800:]
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
assert "done: role" in plain()[-800:], plain()[-1000:]
send(":"); send("autoadmit off\r", 0.8)
assert "done: autoadmit" in plain()[-800:], plain()[-1000:]
send(":"); send("manning co:1\r", 0.8)   # crews table for the existing company
assert "CREWS" in plain()[-30000:] and "mekwarrior" in plain()[-30000:], plain()[-3000:]
send("\x1b", 0.6)
send("]", 0.6)                 # forces: page to the first company
assert "(2/" in plain()[-30000:], plain()[-3000:]
send("[", 0.6)
assert "all forces" in plain()[-30000:], plain()[-3000:]
send("[", 0.6)                 # wraps to the last view: the hangar ranking
assert "hangar: cost vs contribution" in plain()[-30000:] and "cost index" in plain()[-30000:], plain()[-3000:]
send("]", 0.6)
send("7")
assert "back office" in plain() and "HIRING HALL" in plain()
send("u", 0.8)                 # cursor on the header row → picker
assert "UPGRADE ·" in plain()[-30000:] and "paperwork + build" in plain()[-30000:], plain()[-3000:]
send("\x1b")
send("j"); send("j"); send("j"); send("u", 0.8)   # cursor on the first facility row (tier line, blank, header, then facilities) → starts (or says why not)
p = plain()[-600:]
assert "upgrade started" in p or "HQ funds short" in p or "project running" in p, plain()[-1500:]
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
assert wait_for("done: sellstock", tail=2500) or "keep-stocked minimum" in plain()[-2500:], plain()[-800:]  # the footer redraw can push the message past a short window
send("\x1b")
send("3"); send("j", 0.6)       # forces: cursor on the company → damage pane
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
for _ in range(12): send("j", 0.15)
send("\r", 1.0)
assert wait_for("EMBLEM EDITOR"), plain()[-3000:]
send("X"); send("Y", 0.5)      # paint two cells, then save
send("\r", 1.0)
assert wait_for("emblem set to your own crest", tail=2000), plain()[-2000:]
send("8")                      # lab
p = plain()
assert "MOUNTS" in p and "RULES: legal fit" in p, p[-3000:]
send("-", 0.8)                 # stage a removal
assert "remove" in plain(), plain()[-2000:]
send("+", 0.8)                 # install picker: part, then location
assert "INSTALL · pick a part" in plain()[-30000:], plain()[-3000:]
send("\r", 0.8)
assert "pick a location" in plain()[-30000:], plain()[-3000:]
send("\x1b"); send("\x1b")
send("c", 0.8)                 # clear the plan
send("1")
send("n", 1.5)                 # end turn (modal or advance)
p = plain()
if "END TURN?" in p:
    send("n", 1.5)
assert "day 1" in plain(), plain()[-2000:]
send(":"); send("day 3\r", 2.0)
assert "day 4" in plain(), plain()[-2000:]
# Battle orders: the advance stops short of contact and opens the box;
# → changes the ROE, confirm clears the warning, and the next advance
# runs on to the fight instead of stopping again.
send(":"); send("accept 0 1\r", 1.5)
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
send("\x1b", 0.5); send("\x1b", 0.5)
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
print(plain()[-6000:])

# ---- second pass: the minimum tier (80x24) and --ascii, every screen ----
pid, fd = pty.fork()
if pid == 0:
    os.execv(exe, [exe, "--tui", "--ascii", "--no-splash", "--no-music", "--store", db])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
out = b""
assert wait_for("MERCENARY", timeout=20), plain()[-2000:]
send("\t"); send("\r", 3.0)
assert wait_for("F1 Desk", timeout=20) and "+-" in plain(), plain()[-2000:]          # ascii borders
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
send("n", 2.0)
if "END TURN?" in plain(): send("n", 2.0)
send("q"); send("r"); send("q")
drain(0.5)
print("80x24 + --ascii pass OK")
print("SMOKE OK")
