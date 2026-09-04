#!/usr/bin/env python3
"""Drive the TUI through a pty: create a player, walk the wizard, begin a
campaign, end a turn, quit back to the lobby, and exit. Prints the last
screen and asserts on landmarks."""
import os, pty, sys, time, select, re, struct, fcntl, termios

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
def drain(t=0.6):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return

def send(s, wait=0.5):
    os.write(fd, s.encode() if isinstance(s, str) else s)
    drain(wait)

def plain():
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out).decode("utf-8", "replace")

drain(1.0)
assert "MERCENARY COMMAND CONSOLE" in plain(), "welcome screen missing"
send("s", 0.8)
assert "SETTINGS" in plain()[-30000:], plain()[-2000:]
send("\x1b")
send("p"); send("John\r")
assert "player \"John\" created" in plain(), plain()[-3000:]
send("n")                      # new campaign
assert "NEW CAMPAIGN" in plain()
send("\r")                     # commander → outfit (defaults)
send("\t"); send("\t")         # emblem field
send("l", 3.0)                 # import: lists PNGs and previews the first
p = plain()
assert "PNG files in" in p, p[-3000:]
if "loaded" in p:
    assert "half-block colour" in p or "graphics protocol" in p, p[-3000:]
send("\r", 3.0)                # outfit → company (generates)
assert "GENERATED COMPANY" in plain()
send("\r")                     # → review
assert "REVIEW" in plain()
send("\r", 2.0)                # begin
p = plain()
assert "F1 Desk" in p and "END-TURN CHECKLIST" in p, p[-4000:]
if b"38;2;" in out:
    print("emblem: half-block colour cells emitted")
send("4")                      # contracts tab
assert "CONTRACT BOARD" in plain()
send("5")
assert "TREASURIES" in plain()
send("3")
assert "TO&E" in plain()
send("7")
assert "back office" in plain() and "HIRING HALL" in plain()
send("u", 0.8)                 # cursor on the header row → picker
assert "UPGRADE ·" in plain()[-30000:] and "paperwork + build" in plain()[-30000:], plain()[-3000:]
send("\x1b")
send("j"); send("u", 0.8)      # cursor on the first facility → starts (or says why not)
p = plain()[-600:]
assert "upgrade started" in p or "HQ funds short" in p or "project running" in p, plain()[-1500:]
send("f"); send("f")
assert "filter techs" in plain(), plain()[-3000:]
send("2")                      # map
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
assert "MARKET BOARDS" in p and "ORDER CATALOG" in p and "DEMAND" in p, p[-3000:]
send("/", 0.8)                 # market filter cycles
assert "filter mechs" in plain()[-30000:], plain()[-3000:]
send(",", 0.8)
send("\t"); send("\r", 0.8)    # catalog → order prefill
assert ":order " in plain()[-300:], plain()[-600:]
send("\x1b")
send("6")                      # supply: cash and provisions to a company
p = plain()
assert "STOCK ·" in p and "INBOUND" in p and "capacity" in p, p[-3000:]
send("j"); send("j"); send("j")                     # onto the company block
send("t", 0.8)
assert ":transfer outfit co:" in plain()[-400:], plain()[-800:]
send("\x1b"); send("p", 0.8)
assert ":policy co:" in plain()[-400:], plain()[-800:]
send("\x1b"); send("s", 0.8)
assert ":ship provisions 10 hq:" in plain()[-400:], plain()[-800:]
send("\x1b")
send("5"); send("j", 0.6); send("j", 0.6); send("p", 0.8)   # ledger: policy for the selected company
assert ":policy co:" in plain()[-400:], plain()[-800:]
send("\x1b")
send("5"); send("L", 0.8)      # ledger → loan prefill
assert ":loan " in plain()[-300:], plain()[-600:]
send("\x1b")
send("3"); send("j"); send("j"); send("$", 0.8)   # sell hull confirm
assert "SELL HULL?" in plain()[-30000:], plain()[-3000:]
send("\x1b")
send("1"); send("e", 1.5)      # emblem picker on the Desk
p = plain()
assert "EMBLEM ·" in p and "preset   Wolf's Head" in p, p[-2000:]
send("j"); send("\r", 1.0)     # pick the second preset
assert "emblem set to preset" in plain(), plain()[-2000:]
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
send("q"); send("s", 1.5)      # save and return
p = plain()
assert "back at the welcome screen" in p, p[-3000:]
send("q", 0.5)
drain(0.5)
print(plain()[-6000:])

# ---- second pass: the minimum tier (80x24) and --ascii, every screen ----
pid, fd = pty.fork()
if pid == 0:
    os.execv(exe, [exe, "--tui", "--ascii", "--no-splash", "--no-music", "--store", db])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
out = b""
drain(1.0)
assert "MERCENARY" in plain(), plain()[-2000:]
send("\t"); send("\r", 3.0)
p = plain()
assert "F1 Desk" in p and "+-" in p, p[-2000:]          # ascii borders
for k in "234567891":
    send(k, 0.6)
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
