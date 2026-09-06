#!/usr/bin/env python3
"""Capture every IRON LEDGER screen through a pty and write coloured SVG
screenshots to docs/screenshots/ (GitHub renders SVG inline, and text
stays crisp at any zoom). The script answers the app's kitty graphics
probe, so the crest is placed as a real picture (as on Ghostty, kitty,
WezTerm, Konsole) and embedded in the SVG at the placed cells instead of
being rendered as half-block cells. Usage: screenshots.py <exe> <scratch db>"""
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

KITTY_QUERY = b"\x1b_Gi=31"
KITTY_OK = b"\x1b_Gi=31;OK\x1b\\"

def spawn(args, cols=COLS, rows=ROWS):
    global fd, out
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(exe, [exe] + args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    out = b""
    # The app probes for the kitty graphics protocol once at startup and
    # waits a quarter second for the answer: say yes, quickly.
    end = time.time() + 3.0
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.01)
        if r:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
            if KITTY_QUERY in out:
                os.write(fd, KITTY_OK)
                break

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

APC = re.compile(rb"\x1b_G([^\x1b]*)\x1b\\")                       # any kitty graphics command
PLACE = re.compile(rb"\x1b\[(\d+);(\d+)H\x1b_Ga=p,i=(\d+),c=(\d+),r=(\d+),q=2\x1b\\")

images = {}   # kitty id → PNG bytes, assembled from the transmit chunks

def harvest_images():
    """Kitty transmits a PNG once per id as base64 chunks (m=1 … m=0)."""
    cur_id, chunks = None, []
    for m in APC.finditer(out):
        body = m.group(1)
        head, _, payload = body.partition(b";")
        keys = dict(kv.split(b"=", 1) for kv in head.split(b",") if b"=" in kv)
        if keys.get(b"a") == b"t":
            cur_id, chunks = int(keys[b"i"]), [payload]
        elif b"a" not in keys and cur_id is not None:   # continuation chunk
            chunks.append(payload)
        else:
            continue
        if keys.get(b"m", b"0") == b"0" and cur_id is not None:
            import base64
            images[cur_id] = base64.b64decode(b"".join(chunks))
            cur_id, chunks = None, []

def last_frame():
    """The last complete frame's text, plus the picture placements that
    followed it (the app places after the text flush every frame)."""
    frames = out.split(b"\x1b[H")
    for f in reversed(frames):
        # A frame is complete once the delete-all that precedes its
        # placements has arrived; a read can otherwise stop between the text
        # and its pictures. The screens are static, so the previous complete
        # frame is the same picture.
        if b"_Ga=d,d=a" not in f:
            continue
        places = [(int(r) - 1, int(c) - 1, int(i), int(w), int(h)) for r, c, i, w, h in PLACE.findall(f)]
        text = APC.sub(b"", PLACE.sub(b"", f))
        if text.rstrip().endswith(b"\x1b[0m"):
            return text, places
    return APC.sub(b"", frames[-1]), []

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

def svg(rows, path, places=()):
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
    parts.append("</g>")
    # The crest as the terminal would show it: the real picture over the cells.
    import base64
    # A big placement (the wizard preview, the review) gets the 800 px file
    # of the same crest so it stays sharp at that size; small ones embed
    # exactly what the app transmitted.
    hires = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "logos", "unforgiven_800.png")
    hires_png = open(hires, "rb").read() if os.path.exists(hires) else None
    for (y, x, img_id, w, h) in places:
        png = images.get(img_id)
        if not png:
            continue
        if hires_png and w * cw > 320:
            png = hires_png
        b64 = base64.b64encode(png).decode()
        parts.append(f'<image x="{8 + x * cw:.1f}" y="{8 + y * ch:.1f}" width="{w * cw:.1f}" height="{h * ch:.1f}" preserveAspectRatio="xMidYMid meet" href="data:image/png;base64,{b64}"/>')
    parts.append("</svg>")
    open(path, "w").write("\n".join(parts))

def shot(name, wait=0.8):
    drain(wait)
    harvest_images()
    text, places = last_frame()
    svg(parse(text), os.path.join(OUT, name + ".svg"), places)
    print("wrote", name, f"({len(places)} picture placement{'s' if len(places) != 1 else ''})")

# ---- title screen ----
spawn(["--tui", "--no-music", "--store", db])
drain(1.5)
shot("splash")
os.write(fd, b" "); drain(1.0)
# ---- lobby ----
send("p"); send("John\r"); shot("welcome")
send("s"); shot("settings"); send("\x1b")
send("n"); shot("wizard-commander")
send("\r"); send("\t"); send("\t"); send("l", 3.0)
send("j", 2.5)                 # the 240 px logo (docs/logos): the picture the campaign stores, small enough to embed
shot("wizard-emblem")
send("\r", 3.0); shot("wizard-company")
send("\r"); shot("wizard-review")
send("\r", 2.0)
# A contract, then six weeks so the screens carry battles, AARs, wear and money.
send(":"); send("accept 0 1\r", 2.0)
send(":"); send("day 45\r", 6.0)
shot("desk")
send("2"); shot("map")                       # coloured by faction
send("c", 1.0); shot("map-industry"); send("c"); send("c"); send("c")
send("3"); send("j"); shot("forces")         # cursor on the company: DAMAGE pane
send("r", 1.0); shot("forces-readiness")
send("r", 1.0); shot("forces-manning"); send("r")
send("[", 1.0); shot("hangar"); send("]")
send("4"); shot("contracts")
send("b", 1.0); shot("negotiate"); send("\x1b")
send("5"); shot("ledger")
send("6"); shot("supply")
send("7"); shot("hq")
send("\t", 1.0); shot("hall"); send("\t")
send("8"); shot("lab")
send("9"); shot("people")
send("r", 1.0); shot("record"); send("\x1b")
send("0"); shot("market")
send(":"); send("summary\r", 1.5); shot("summary"); send("\x1b")
send(":"); send("readiness\r", 1.5); shot("readiness"); send("\x1b")
send("1"); send("e", 1.0)
for _ in range(12): send("j", 0.1)
send("\r", 1.0); shot("emblem-editor"); send("\x1b")
send("n", 1.5); shot("end-turn")
send("\x1b"); send("?"); shot("help"); send("\x1b")
send("q"); send("r"); send("q")
drain(0.5)
print("done")
