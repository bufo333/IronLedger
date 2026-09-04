#!/usr/bin/env python3
"""Capture every IRON LEDGER screen through a pty and write coloured SVG
screenshots to docs/screenshots/ (GitHub renders SVG inline, and text
stays crisp at any zoom). Usage: screenshots.py <exe> <scratch db>"""
import os, pty, sys, time, select, re, struct, fcntl, termios, html

exe, db = sys.argv[1], sys.argv[2]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screenshots")
os.makedirs(OUT, exist_ok=True)
COLS, ROWS = 170, 45
if os.path.exists(db):
    os.remove(db)

PALETTE = {  # SGR fg/bg codes → hex (a dark terminal theme)
    "30": "#0b0f0d", "31": "#e05a4f", "32": "#7fc97f", "33": "#e0a33a", "34": "#6f9ce0",
    "35": "#c48ae0", "36": "#6fc3c3", "37": "#c8d3c5", "90": "#6f7d73",
    "40": "#0b0f0d", "43": "#e0a33a", "46": "#0f5c5c",
}
FG_DEFAULT, BG_DEFAULT = "#c8d3c5", "#0b0f0d"

out = b""
fd = None

def spawn(args, cols=COLS, rows=ROWS):
    global fd, out
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(exe, [exe] + args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    out = b""

def drain(t):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return

def send(s, wait=0.7):
    os.write(fd, s.encode())
    drain(wait)

def last_frame():
    frames = out.split(b"\x1b[H")
    for f in reversed(frames):
        if f.rstrip().endswith(b"\x1b[0m"):
            return f
    return frames[-1]

SGR = re.compile(rb"\x1b\[([0-9;]*)m")
CUP = re.compile(rb"\x1b\[(\d+);1H")

def parse(frame):
    """→ rows of cells (ch, fg, bg, half) where half=(top,bottom) for pixel cells."""
    rows = [[] for _ in range(ROWS)]
    pos = 0
    y = -1
    fg, bg, px = FG_DEFAULT, BG_DEFAULT, None
    data = frame
    i = 0
    while i < len(data):
        m = CUP.match(data, i)
        if m:
            y = int(m.group(1)) - 1
            i = m.end()
            continue
        m = SGR.match(data, i)
        if m:
            codes = m.group(1).decode().split(";") if m.group(1) else ["0"]
            j = 0
            px = None
            fg, bg = FG_DEFAULT, BG_DEFAULT
            while j < len(codes):
                c = codes[j]
                if c == "0":
                    fg, bg = FG_DEFAULT, BG_DEFAULT
                elif c == "1":
                    pass
                elif c in ("38", "48") and j + 4 < len(codes) and codes[j + 1] == "2":
                    col = "#%02x%02x%02x" % tuple(int(v) for v in codes[j + 2:j + 5])
                    if c == "38":
                        fg = col
                    else:
                        bg = col
                    j += 4
                elif c in ("38", "48") and j + 2 < len(codes) and codes[j + 1] == "5":
                    j += 2
                elif c in PALETTE:
                    if int(c) >= 40 and c != "90":
                        bg = PALETTE[c]
                    else:
                        fg = PALETTE[c]
                j += 1
            i = m.end()
            continue
        if data[i] == 0x1b:  # any other escape: skip to its final byte
            k = i + 1
            while k < len(data) and not (0x40 <= data[k] <= 0x7e):
                k += 1
            i = k + 1
            continue
        # a UTF-8 character
        b = data[i]
        n = 1 if b < 0x80 else 2 if b < 0xe0 else 3 if b < 0xf0 else 4
        ch = data[i:i + n].decode("utf-8", "replace")
        i += n
        if 0 <= y < ROWS and len(rows[y]) < COLS:
            rows[y].append((ch, fg, bg))
    return rows

def svg(rows, path):
    cw, ch, fs = 7.2, 15, 12
    w, h = COLS * cw + 16, ROWS * ch + 16
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" viewBox="0 0 {w:.0f} {h:.0f}">',
             f'<rect width="100%" height="100%" fill="{BG_DEFAULT}"/>',
             f'<g font-family="Menlo, DejaVu Sans Mono, Consolas, monospace" font-size="{fs}" xml:space="preserve">']
    for y, row in enumerate(rows):
        # background runs first
        x = 0
        for (c, fg, bg) in row:
            if c == "▀":
                parts.append(f'<rect x="{8 + x * cw:.1f}" y="{8 + y * ch:.1f}" width="{cw:.1f}" height="{ch / 2:.1f}" fill="{fg}"/>')
                parts.append(f'<rect x="{8 + x * cw:.1f}" y="{8 + y * ch + ch / 2:.1f}" width="{cw:.1f}" height="{ch / 2:.1f}" fill="{bg}"/>')
            elif bg != BG_DEFAULT:
                parts.append(f'<rect x="{8 + x * cw:.1f}" y="{8 + y * ch:.1f}" width="{cw:.1f}" height="{ch}" fill="{bg}"/>')
            x += 1
        # then text: one element per run of a colour, every glyph placed at
        # its own column so alignment never depends on the viewer's font
        run, run_fg, xs = [], None, []
        def flush():
            if run:
                parts.append(f'<text y="{8 + y * ch + fs - 1}" fill="{run_fg}" x="{" ".join(xs)}">{html.escape("".join(run))}</text>')
        for x, (c, fg, bg) in enumerate(row):
            if c in ("▀", " "):
                flush(); run, run_fg, xs = [], None, []
                continue
            if fg != run_fg:
                flush(); run, run_fg, xs = [], fg, []
            run.append(c); xs.append(f"{8 + x * cw:.1f}")
        flush()
    parts.append("</g></svg>")
    open(path, "w").write("\n".join(parts))

def shot(name, wait=0.8):
    drain(wait)
    svg(parse(last_frame()), os.path.join(OUT, name + ".svg"))
    print("wrote", name)

# ---- title screen ----
spawn(["--tui", "--no-music", "--store", db])
drain(1.5)
shot("splash")
os.write(fd, b" "); drain(1.0)
# ---- lobby ----
send("p"); send("John\r"); shot("welcome")
send("s"); shot("settings"); send("\x1b")
send("n"); shot("wizard-commander")
send("\r"); send("\t"); send("\t"); send("l", 3.0); shot("wizard-emblem")
send("\r", 3.0); shot("wizard-company")
send("\r"); shot("wizard-review")
send("\r", 2.0)
# a few turns so the screens have history
send(":"); send("day 40\r", 4.0)
shot("desk")
send("2"); shot("map")
send("3"); send("j"); send("j"); shot("forces")
send("4"); shot("contracts")
send("5"); shot("ledger")
send("6"); shot("supply")
send("7"); shot("hq")
send("8"); shot("lab")
send("9"); shot("people")
send("0"); shot("market")
send("1"); send("n", 1.5); shot("end-turn")
send("\x1b"); send("?"); shot("help"); send("\x1b")
send("q"); send("r"); send("q")
drain(0.5)
print("done")
