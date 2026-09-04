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
    os.execv(exe, [exe, "--tui", "--store", db])

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
send("f"); send("f")
assert "filter techs" in plain(), plain()[-3000:]
send("2")                      # map
p = plain()
assert "STAR MAP" in p and "REACH" in p, p[-3000:]
send("l"); send("j"); send("h"); send("k")
send("8")                      # lab
p = plain()
assert "MOUNTS" in p and "RULES: legal fit" in p, p[-3000:]
send("-", 0.8)                 # stage a removal
assert "remove" in plain(), plain()[-2000:]
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
print("SMOKE OK")
