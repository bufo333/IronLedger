#!/usr/bin/env python3
"""Generate docs/tui-mockup.html at the FULL tier (200x50 cells) by rendering
panes into a cell grid — the same arithmetic the real TUI uses, so nothing
can be a column off.

Markup inside pane lines: {a} amber  {g} good  {c} critical  {s} selected
{d} dim  {t} active tab  {p} purple  {/} reset. Widths are measured with the
markup removed; a line longer than its pane is clipped and reported on stderr.
"""
import re, html, os, sys, base64, math
import ascii_logo

COLS, ROWS = 200, 50
TABS = ["F1 Desk", "F2 Map", "F3 Forces", "F4 Contracts", "F5 Ledger", "F6 Supply", "F7 HQ", "F8 Lab"]
OUTFIT = "The Unforgiven"
HERE = os.path.dirname(os.path.abspath(__file__))
LOGO_BMP = os.path.join(HERE, "logos", "unforgiven_400.bmp")
LOGO_PNG = os.path.join(HERE, "..", "unforgiven.png")  # the original, embedded once as a CSS image
LOGO_URI = "data:image/png;base64," + base64.b64encode(open(LOGO_PNG, "rb").read()).decode()
GRAPHICS = True  # render emblems as the terminal's graphics protocol would (real picture over cells)
LOGO_X = COLS - 10  # corner mark column on in-game frames
STATUS = ("{a}3025-06-25{/}  day 176  ·  outfit {a}6,881,836{/} C  ·  rep {g}+3{/}  ·  2 companies · 2 HQs · 64 hulls · 336 people"
          "  ·  inbox {c}1{/}  ·  checklist {c}2{/}  ·  turn ready: {c}NO{/}")
HINT = "{d}? help · F1-F8 screens · Tab pane · j/k cursor · Enter act · : command · n end turn · N 7 turns · q welcome{/}"
TOKEN = re.compile(r"\{(a|g|c|s|d|t|p|/)\}")


def parse(s):
    out, cls, i = [], "", 0
    for m in TOKEN.finditer(s):
        for ch in s[i:m.start()]:
            out.append((ch, cls))
        cls = "" if m.group(1) == "/" else m.group(1)
        i = m.end()
    for ch in s[i:]:
        out.append((ch, cls))
    return out


def vis(s):
    return len(parse(s))


class Grid:
    def __init__(self, rows):
        self.rows = [[(" ", "") for _ in range(COLS)] for _ in range(rows)]
        self.shift = 0
        self.overlays = []

    def put(self, x, y, s, cls=None):
        cells = parse(s)
        for i, (ch, c) in enumerate(cells):
            if 0 <= x + i < COLS and 0 <= y < len(self.rows):
                self.rows[y][x + i] = (ch, cls if cls is not None else c)
        return len(cells)

    def text(self, x, y, s, width, cls=None):
        cells = parse(s)
        if len(cells) > width:
            print(f"clipped ({len(cells)}>{width}): {s[:70]}", file=sys.stderr)
            cells = cells[:width]
        for i in range(width):
            ch, c = cells[i] if i < len(cells) else (" ", "")
            if 0 <= x + i < COLS:
                self.rows[y][x + i] = (ch, cls if cls is not None else c)

    def pane(self, x, y, w, h, title="", lines=(), focused=False, double=False, right_title=""):
        y += self.shift
        H, V, TL, TR, BL, BR = ("═", "║", "╔", "╗", "╚", "╝") if double else ("─", "│", "┌", "┐", "└", "┘")
        tcls = "s" if focused else ""
        self.put(x, y, TL); self.put(x + w - 1, y, TR)
        for i in range(1, w - 1):
            self.put(x + i, y, H, tcls)
        if title:
            self.put(x + 1, y, f" {title} ", tcls)
        if right_title:
            self.put(x + w - 3 - len(right_title), y, f" {right_title} ", "d")
        if len(lines) > h - 2:
            print(f"pane '{title}' has {len(lines)} lines for {h - 2} rows", file=sys.stderr)
        for r in range(1, h - 1):
            self.put(x, y + r, V); self.put(x + w - 1, y + r, V)
            line = lines[r - 1] if r - 1 < len(lines) else ""
            self.text(x + 2, y + r, line, w - 4)
        self.put(x, y + h - 1, BL); self.put(x + w - 1, y + h - 1, BR)
        for i in range(1, w - 1):
            self.put(x + i, y + h - 1, H)

    def blit(self, x, y, cols, rows, raw=False):
        if GRAPHICS:
            return self.image(x, y, cols, rows, raw)
        if not raw:
            y += self.shift
        for r, row in enumerate(ascii_logo.pixels(LOGO_BMP, cols, rows)):
            for c, (top, bottom) in enumerate(row):
                if 0 <= x + c < COLS and 0 <= y + r < len(self.rows):
                    self.rows[y + r][x + c] = (" ", ("px", top, bottom))

    def image(self, x, y, w, h, raw=False):
        if not raw:
            y += self.shift
        for r in range(h):
            for c in range(w):
                self.rows[y + r][x + c] = (" ", "")
        self.overlays.append([x, y, w, h, False])

    def dim_all(self):
        def dim(cls):
            return ("px", shade(cls[1]), shade(cls[2])) if isinstance(cls, tuple) else "d"
        self.rows = [[(ch, dim(cls)) for ch, cls in row] for row in self.rows]
        for o in self.overlays:
            o[4] = True

    def chrome(self, active):
        x = 0
        for i, t in enumerate(TABS):
            self.put(x, 0, f" {t} ", "t" if i == active else "d")
            x += len(t) + 2
        self.put(LOGO_X - 2 - len(OUTFIT), 0, OUTFIT, "d")
        self.blit(LOGO_X, 0, 8, 3, raw=True)
        self.put(0, 1, STATUS)

    def html(self):
        out = []
        for row in self.rows:
            parts, cur, buf = [], None, []
            for ch, cls in row:
                if cls != cur or isinstance(cls, tuple):
                    if buf:
                        parts.append(wrap("".join(buf), cur))
                    cur, buf = cls, []
                buf.append(ch)
            if buf:
                parts.append(wrap("".join(buf), cur))
            out.append("".join(parts).rstrip() if not row[-1][1] else "".join(parts))
        body = "\n".join(out)
        imgs = "".join(
            f'<div class="ovl{" dim" if d else ""}" role="img" aria-label="outfit emblem" style="left:{x}ch;top:calc({y} * 1.32em);width:{w}ch;height:calc({h} * 1.32em)"></div>'
            for x, y, w, h, d in self.overlays)
        return f'<div class="term"><pre>{body}</pre>{imgs}</div>'


def shade(hex_, k=0.35):
    r, g, b = (int(hex_[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02x%02x%02x" % (int(r * k), int(g * k), int(b * k))


def wrap(s, cls):
    if isinstance(cls, tuple):
        _, top, bottom = cls
        return f'<span class="px" style="background:linear-gradient({top} 50%,{bottom} 50%)"> </span>' * len(s)
    s = html.escape(s)
    return f'<span class="{cls}">{s}</span>' if cls else s


def frame(active, cmd=""):
    """In-game frame: chrome rows 0-2, panes from literal y=2 (shifted by 1), command line on the last row."""
    g = Grid(ROWS)
    g.shift = 1
    g.chrome(active)
    g.put(0, ROWS - 1, "{d}:{/}" + cmd)
    g.put(COLS - vis(HINT), ROWS - 1, HINT)
    return g


def shell(title, hint, right=""):
    g = Grid(ROWS)
    g.put(0, 0, f" {title} ", "t")
    if right:
        g.put(COLS - len(right), 0, right, "d")
    g.put(0, ROWS - 1, hint)
    return g


def bar(frac, width):
    n = round(frac * width)
    return "#" * n + "-" * (width - n)


def pad(lines, n):
    return list(lines) + [""] * (n - len(lines))


BODY_H = ROWS - 4  # rows available to panes on an in-game frame (literal y=2 .. 45 → h=44) plus one


# --------------------------------------------------------------- data

PLANETS = [  # from data/planets.zon
    ("Galatea", "LC", 0, 0, 3), ("Solaris VII", "LC", -28, 22, 5), ("Skye", "LC", -55, 8, 4),
    ("Zebebelgenubi", "LC", 24, 14, 2), ("Lyons", "LC", 38, -18, 2), ("Atria", "LC", -12, -42, 2),
    ("Summer", "LC", -40, -15, 3), ("Alkaid", "LC", -70, 35, 1), ("Dyev", "DC", 52, 12, 2),
    ("Imbros III", "DC", 66, -12, 2), ("Sabik", "DC", 44, 38, 3), ("Moore", "DC", 60, 45, 2),
    ("Vega", "DC", 105, 28, 3), ("Konstance", "DC", 90, -30, 1), ("Caph", "FS", 15, -25, 3),
    ("Errai", "FS", 35, -35, 2), ("Quentin", "FS", 48, -28, 3), ("Komephoros", "CC", 20, -70, 2),
    ("Sheratan", "CC", 30, -55, 1), ("Epsilon Eridani", "CC", 5, -95, 3), ("Terra Firma", "CC", -25, -90, 2),
    ("New Home", "CC", -55, -75, 3), ("Carver V", "FWL", -85, -40, 2), ("Outreach", "FWL", -75, -60, 3),
    ("Oliver", "FWL", -95, -10, 3), ("Graham IV", "FWL", -110, 15, 2), ("Callison", "FWL", -120, -25, 2),
]
EMBLEMS = [
    ("Wolf's Head", [" /\\  /\\", " \\ \\/ /", "  \\__/ "]),
    ("Death's Head", [" .---. ", " |o o| ", " \\_^_/ "]),
    ("Hammer", [" [===] ", "   ||  ", "   ||  "]),
    ("Star", ["   *   ", " * * * ", "   *   "]),
]
COMPANY_ROWS = [
    "co   name             hq               posture                 contract            location        fatigue  morale  hulls   ready  supply      local funds   next",
    "1    Alpha Company    Komephoros       {g}at home, rested{/}         —                   Komephoros            0      52  32/32      29  {g}60t / 100t{/}    2,876,722   training cycle day 180",
    "11   Bravo Company    Firebase Kalmar  {a}DEPLOYED{/} recon_raid     [1] pirate_hunting  Sheratan             13      48  32/32      31  {a}18t / 100t{/}      340,000   engagement ~day 181",
]
LOG_ROWS = [
    "06-25 {a}[rotation]{/}  Alpha Company is rested and reset (fatigue 0, morale +4)",
    "06-25 {c}[finance]{/}   Komephoros Regional HQ treasury overdrawn (−192,880) — upkeep 310,000 due day 182",
    "06-25 [payroll]   paid 742,000 to 336 people · 12 XP awards",
    "06-24 {g}[delivery]{/}  ammo_lrm x3 (3t) received at Komephoros warehouse (order #41, 12 days)",
    "06-24 [market]    Komephoros board: 2 new listings (SHD-2H {a}damaged{/} 3.1M · PPC staple)",
    "06-23 [training]  Rafael Jankowski gunnery 5 → 4 (training ground lv1, 8 days)",
    "06-22 [bay]       SHD-2H #14 structural repair complete (comp_torso consumed) · bay 1 free",
    "06-22 [medical]   Adam Davion returns to duty (wound healed, 11 days)",
    "06-21 [contract]  pirate_hunting: monthly payment 343,848 · VP 100 · pool 57% destroyed",
    "06-20 [decision]  civil_disturbance raised on Sheratan · deadline day 180 · default: Measured response",
    "06-19 {a}[AAR]{/}       pirate_hunting vs PER: {g}victory{/} — 14,102 vs 9,418 · 2 damaged · 0 lost · ammo 4.2t · salvage 858,750",
    "06-18 [travel]    fund courier 200,000 → co:11 departed Komephoros, ETA day 178",
    "06-17 [hq]        warehouse → lv2 project entered paperwork (6 days, admin_finance 7/9: +2)",
    "06-16 [hiring]    hiring hall churn: 2 new candidates (tech_mek veteran, mekwarrior green)",
]


# --------------------------------------------------------------- in-game screens

def desk():
    g = frame(0)
    g.pane(0, 2, 44, 22, "EMBLEM")
    g.blit(2, 3, 40, 20)
    g.pane(45, 2, 60, 22, "END-TURN CHECKLIST", [
        "{c}!{/} Komephoros Regional HQ understaffed 28/30",
        "  facilities run one level below built     {d}→ F7 HQ{/}",
        "{c}!{/} Komephoros Regional HQ treasury overdrawn −192,880",
        "  upkeep 310,000 due day 182               {d}→ F5 Ledger{/}",
        "{a}·{/} #4 WHM-6R has no tech assigned            {d}→ F3 Forces{/}",
        "{a}·{/} Bravo Company: 9 days of provisions       {d}→ F6 Supply{/}",
        "{a}·{/} lrm15 short by 1 (no order placed)        {d}→ F6 Supply{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}2 warnings block · 3 notices · [n] end turn anyway{/}",
    ], focused=True)
    g.pane(106, 2, 94, 22, "INBOX", [
        "{a}>{/} civil_disturbance                                     {c}4 days left{/}",
        "  Alpha Company · Sheratan · raised day 176",
        "",
        "  Unrest spreads through the capital district. The garrison commander",
        "  asks the company to show force in the streets.",
        "",
        "    1  Suppress it firmly      {g}+100,000{/} C · rep {c}−2{/} · morale −3",
        "    2  Measured response       rep {g}+2{/} · fatigue +5              {d}default{/}",
        "    3  Stay in barracks        rep {c}−1{/}",
        "",
        "",
        "{d}resolved recently{/}",
        "  06-15  supply_convoy_raided   chose: escort with Recon Lance   {g}convoy saved{/}",
        "  06-03  employer_inspection    chose: full parade               rep +1",
        "",
        "",
        "",
        "",
        "{d}1 pending · deadlines resolve to the default automatically{/}",
    ])
    g.pane(0, 24, 200, 6, "COMPANIES", COMPANY_ROWS)
    g.pane(0, 30, 121, 16, "LOG", LOG_ROWS, right_title="since last turn · [l] full log")
    g.pane(122, 30, 78, 16, "HQs", [
        "hq:1 {a}Komephoros Regional HQ{/}     regional · ring 75 LY · CC space",
        "     funds {c}−192,880{/} · staff 28/30 · companies 1/1 · bays 2/2 busy",
        "     warehouse 62t/200t · beds 3/10 · project: warehouse → lv2 (paperwork)",
        "",
        "hq:2 {a}Firebase Kalmar{/}            field HQ · ring 60 LY · Sheratan",
        "     funds 460,000 · staff 28/28 · companies 1/1 · bays 0/2 busy",
        "     field stores 18t / 100t · beds 1/4 · link → hq:1 24 days · 40t/week",
        "",
        "network   1 link · throughput 12t / 40t used this week",
        "couriers  200,000 → co:11 arrives day 178",
        "",
        "",
        "",
        "{d}[Enter] open HQ  [f] found  [k] link{/}",
    ])
    return g


def star_map():
    g = frame(1)
    MX, MY, MW, MH = 0, 2, 150, 44
    g.pane(MX, MY, MW, MH, "STAR MAP", right_title="250 LY around Galatea · 1.75 LY per column", focused=True)
    ox, oy = MX + 2, MY + 1 + g.shift
    W, H = MW - 4, MH - 2
    sx, sy = 1.75, 3.5  # LY per column / row (2:1 cell aspect)

    def cell(x, y):
        return ox + int((x + 125) / sx), oy + int((47 - y) / sy)

    def ring(cx, cy, r, ch, cls):
        for k in range(720):
            a = k * math.pi / 360
            c, rr = cell(cx + r * math.cos(a), cy + r * math.sin(a))
            if ox <= c < ox + W and oy <= rr < oy + H:
                g.put(c, rr, ch, cls)

    ring(20, -70, 75, ".", "d")
    ring(20, -70, 110, ",", "d")
    ring(30, -55, 60, ".", "d")
    for name, fac, x, y, ind in PLANETS:
        c, r = cell(x, y)
        mark, cls = "o", ""
        if name == "Komephoros" or name == "Sheratan":
            mark, cls = "@", "a"
        if name == "Galatea":
            mark, cls = "*", "s"
        g.put(c, r, mark, cls)
        g.put(c + 2, r, name, "d" if fac in ("FWL",) or x > 95 else "")
        if name in ("Galatea", "Zebebelgenubi"):
            g.put(c + 2 + len(name) + 1, r, "^", "a")
    g.put(ox + 1, oy + H - 1, "{d}@ HQ   * cursor   ^ offer   . influence ring   , beachhead band   o world (dim = out of reach)   [r] rings  [b] beachhead{/}")

    g.pane(151, 2, 49, 23, "WORLD", [
        "{a}Galatea{/}                    LC · industry 5",
        "the mercenary hiring hub",
        "",
        "from Komephoros HQ   73 LY  · {g}inside ring{/}",
        "from Firebase Kalmar 63 LY  · {g}inside ring{/}",
        "jumps                3  ·  ~14 days transit",
        "",
        "HQ here      none        [f] found HQ (3.2M)",
        "companies    none",
        "market       hub board · 14 listings",
        "             hulls ×1.0 · parts ×0.95",
        "local supply ×1.0",
        "",
        "offers here",
        "  {a}^{/} garrison_duty   18 mo   205,137 / mo",
        "      LC ×1.05 · PER · salvage 15% · liaison",
        "",
        "",
        "",
        "",
        "{d}[Enter] open [o] offers [f] found [m] market{/}",
    ])
    g.pane(151, 25, 49, 21, "REACH", [
        "in ring (both HQs)      11 worlds",
        "beachhead band           9 worlds  {a}×1.3 pay{/}",
        "dark (out of reach)      7 worlds",
        "",
        "ring grows with comms level:",
        "  hq:1 comms lv1 → 75 LY · lv2 → 100 LY",
        "  hq:2 field HQ  → 60 LY fixed",
        "",
        "deployed",
        "  co:11 Bravo  Sheratan  day 181 next battle",
        "",
        "in transit",
        "  courier 200,000 → Sheratan  day 178",
        "  shipment 18t → Sheratan     day 189",
        "",
        "",
        "",
        "{d}[h j k l] move  [Tab] pane{/}",
    ])
    return g


def forces():
    g = frame(2, cmd="assign 4 tech 67")
    g.pane(0, 2, 72, 24, "TO&E", pad([
        "{a}v [1] Alpha Company{/}          at home · 168 people · 13,052 BV",
        "  v [2] 1st Lance                   4 hulls · 265t · {g}ready{/}",
        "      #1  MAD-3R  Marauder      75t  Quintana 3/4   Marlowe    {g}ok{/}",
        "      #2  WVR-6R  Wolverine     55t  Mbeki 4/5      Eriksson   {g}ok{/}",
        "    {s}> #3  TDR-5S  Thunderbolt   65t  Jankowski 4/5  Ulmer      {a}dmg{/}{/}",
        "      #4  WHM-6R  Warhammer     70t  Ulmer 3/5      {c}— no tech{/}",
        "  v [3] 2nd Lance                   4 hulls · 230t · {g}ready{/}",
        "      #5  SHD-2H  Shadow Hawk   55t  Ferreira 4/5   Osei       {g}ok{/}",
        "      #6  GRF-1N  Griffin       55t  Halvorsen 4/4  Osei       {g}ok{/}",
        "      #7  PXH-1   Phoenix Hawk  45t  Nakamura 3/4   Reyes      {g}ok{/}",
        "      #8  AS7-D   Atlas        100t  Duval 4/5      Reyes      {a}depot{/}",
        "  > [4] 3rd Lance                   4 hulls · 105t · {g}ready{/}",
        "  > [5] Recon Lance      scouting   4 hulls · 100t · {g}ready{/}",
        "  v [6] Omega Company    support",
        "      [7]  Salvage Lance      4 SVT-1     300 BV each · 20t free",
        "      [8]  MASH Lance         4 MASH-27   4 medics · 8 beds",
        "      [9]  Logistics Lance    4 CGT-3     100t cargo",
        "      [10] Security Lance     4 SEC-PLT   28 infantry",
        "{a}> [11] Bravo Company{/}          DEPLOYED · Sheratan · 168 people",
        "",
        "unassigned people   3   {a}1 hull without a tech{/}   0 without a pilot",
    ], 21) + ["{d}[Enter] open [a] assign [u] unassign [A] auto [x] transfer{/}"], focused=True)
    g.pane(0, 26, 72, 20, "PERSON · Rafael Jankowski", pad([
        "mekwarrior · regular · age 29 · LC origin",
        "gunnery {g}4{/} · piloting 5 · XP 14 ({a}12 to next{/})",
        "assigned    #3 TDR-5S Thunderbolt (1st Lance) · Komephoros HQ",
        "fatigue     0 · morale 55 · wounds none",
        "pay         1,500 / mo · hazard +15% when deployed",
        "training    gunnery 4 → 3   14 days · 18 XP",
        "            {d}needs training_ground at home HQ{/}",
        "record      battles 11 · kills 4 · injuries 1 · 3 contracts",
        "            joined 3024-11-02",
    ], 17) + ["{d}[t] train  [L] leave  [x] transfer  [f] fire{/}"])
    g.pane(73, 2, 127, 24, "HULL #3 TDR-5S Thunderbolt", pad([
        "65t heavy · quality {g}D{/} · armor {a}85%{/} · status ready · BV 1,335 · value 4.7M",
        "pilot   {g}Rafael Jankowski{/}   mekwarrior  regular  gunnery 4 · piloting 5 · fatigue 0",
        "tech    {g}Sergei Ulmer{/}       tech_mek    regular  tech 6 · 8 / 36 h this week",
        "",
        "mount            part     state     ammo         mount            part     state",
        "ra.llas.1        llas     {g}ok{/}        —            rt.mlas.1        mlas     {g}ok{/}",
        "lt.lrm15.1       lrm15    {c}damaged{/}   —            rt.mlas.2        mlas     {g}ok{/}",
        "lt.ammo_lrm.1    ammo     {g}ok{/}        {g}8/8{/}          rt.mlas.3        mlas     {g}ok{/}",
        "lt.ammo_lrm.2    ammo     {g}ok{/}        {a}5/8{/}          lt.srm2.1        srm2     {g}ok{/}",
        "rt.ammo_srm.1    ammo     {g}ok{/}        {g}50/50{/}        rl.hs.1  ll.hs.1  heat sinks (implicit)",
        "",
        "structure   hd ok · ct ok · lt ok · rt ok · la ok · ra ok · ll ok · rl ok",
        "armor       hd 9/9 · ct 30/35 · lt 22/24 · rt 24/24 · la 20/20 · ra 20/20 · ll 26/26 · rl 26/26",
        "",
        "repair      field: lrm15 (6h, needs lrm15 part — {c}0 on hand, 0 on order{/})",
        "            depot: not needed",
        "monthly     upkeep 2,000 · maintenance 3.5h/week · quality check tn 7",
        "",
        "history     3 battles this contract · 1 damaged · salvage recovered 0",
    ], 21) + ["{d}[a] assign  [u] unassign  [x] transfer  [l] open in Lab  [o] order lrm15{/}"])
    g.pane(73, 26, 80, 20, "UNASSIGNED POOL", pad([
        "id    name            role        exp      skill   hours  notes",
        "{s}> 67    Adam Davion     tech_mek    regular  tech 6  0/36   back from medbay{/}",
        "  91    Zara Novak      astech      green    tech 8  0/36   hired day 170",
        "  102   Oren Whitlock   mekwarrior  veteran  3/4     —      {a}reserve pilot{/}",
        "",
        "hulls needing crew",
        "  #4 WHM-6R   tech slot open · {d}auto-swap: no free tech_mek here{/}",
    ], 17) + ["{d}[Enter] assign the selected person to the selected hull{/}"])
    g.pane(154, 26, 46, 20, "MEDBAY · Komephoros", pad([
        "beds 3 / 10 · 4 medics · hospital lv1",
        "",
        "  Duval, M.      wound     day 183  {a}pri 1{/}",
        "  Nakamura, K.   fatigue   day 179",
        "  Ulmer, S.      {c}injured{/}   day 188 · #4",
        "",
        "leave   2 people until day 180",
    ], 17) + ["{d}[m] triage  [L] leave{/}"])
    return g


def contracts():
    g = frame(3)
    g.pane(0, 2, 200, 14, "CONTRACT BOARD", [
        "  kind               world              faction  LY    band        months   pay/month   total       employer    enemy   salvage  rights       transport  maint. est.   fieldable",
        "{s}> garrison_duty      Galatea            LC       73    in ring        18     205,137   3,692,466   LC ×1.05    PER       15%  liaison      charter     41,000/mo    {g}yes{/}{/}",
        "  objective_raid     Zebebelgenubi      LC       84    {a}beachhead{/}       3     174,720     524,160   LC          FWL       15%  house        charter     38,000/mo    {g}yes{/}",
        "  security_duty      Zebebelgenubi      LC       84    {a}beachhead{/}       9     131,040   1,179,360   LC          DC        35%  independent  own         38,000/mo    {g}yes{/}",
        "  pirate_hunting     Caph               FS       46    in ring         6     168,000   1,008,000   FS          PER       50%  independent  own         44,000/mo    {g}yes{/}",
        "  cadre_duty         Sheratan           CC       15    in ring        12      98,400   1,180,800   CC ×0.95    —          0%  house        —           36,000/mo    {g}yes{/}",
        "  recon_raid         Dyev               DC       88    {a}beachhead{/}       2     221,000     442,000   DC          DC        10%  liaison      charter     40,000/mo    {c}no — Alpha only{/}",
        "",
        "{d}beachhead: ×1.3 pay · +15% hardship pay · local supplies ×2.5 · resupply via link only  ·  board refreshes on the 1st · faction cooling: none  ·  reputation +3 → ×1.03{/}",
        "",
        "{d}[Enter] accept with company…   [d] details & terms   [e] estimate (supply burn, transit, expected attrition){/}",
    ], focused=True, right_title="refreshes on the 1st")
    g.pane(0, 16, 121, 30, "ACTIVE", [
        "[1] pirate_hunting     {a}active{/}    co:11 Bravo on Sheratan    employer CC · vs PER    attrition objective",
        "",
        "    opposition   {a}" + bar(0.57, 40) + "{/}  57% destroyed   30,434 / 53,315 BV",
        "    duration     {d}" + bar(0.48, 40) + "{/}  day 86 of 180 · 94 days left",
        "    victory pts  {g}100{/} · score {g}+11{/} · objectives met at 75% (needs 9,552 more BV)",
        "",
        "    committed    16,108 BV · fieldable 13,254 BV {g}(82%){/} · ineffective below 8,054 · grace: not triggered",
        "    paid so far  1,031,544 of 2,062,000 · advance 412,000 · breach exposure {c}−618,000{/}",
        "    supplies     18t on hand · 9 days provisions · ammo lrm {c}dry{/} srm 3t ac5 1t",
        "",
        "    battle   day   result    power (us / them)   losses  dmg   ammo   salvage",
        "    1        112   {g}victory{/}   12,880 / 8,102       0       1     3.1t   402,000",
        "    2        131   {g}victory{/}   13,410 / 9,006       0       2     3.8t   610,500",
        "    3        152   {a}draw{/}      12,050 / 11,900      1       3     4.0t   0",
        "    4        170   {g}victory{/}   14,102 / 9,418       0       2     4.2t   858,750",
        "    next     ~181  {d}enemy remaining 22,881 BV · expected strength ×0.85{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[c] complete (objectives met)   [R] recall now = breach clause   [v] AARs   [s] supply this company{/}",
    ])
    g.pane(122, 16, 78, 30, "AFTER-ACTION · battle 4 · day 170", [
        "pirate_hunting · Sheratan · {g}victory{/}",
        "",
        "power        us 14,102   them 9,418   ratio 1.50",
        "modifiers    training +6% · supply −4% (ammo) · fatigue −3%",
        "             support +5% (MASH, salvage) · morale +2%",
        "",
        "engaged      12 hulls · Recon Lance screened",
        "damaged      #3 TDR-5S (lrm15) · #8 AS7-D (ct armor)",
        "lost         none",
        "casualties   1 wounded (Duval, heals day 183)",
        "",
        "ammo         lrm 2.0t · srm 1.4t · ac5 0.8t = 4.2t",
        "             {c}lrm family now dry{/}",
        "",
        "salvage      858,750 C (capped by 4 trucks · 1,200 BV)",
        "             recovered: 1 LCT-1V hull (damaged)",
        "",
        "enemy        3 lights, 2 mediums destroyed · 4,010 BV",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[j/k] previous / next battle{/}",
    ])
    return g


def ledger():
    g = frame(4, cmd="transfer outfit hq:1 500000")
    g.pane(0, 2, 46, 44, "TREASURIES", [
        "  outfit                    {a}6,881,836{/}",
        "  hq:1 Komephoros            {c}−192,880{/}",
        "  hq:2 Firebase Kalmar        460,000",
        "{s}> co:1  Alpha Company       2,876,722{/}",
        "  co:11 Bravo Company         340,000",
        "  ────────────────────────────────────",
        "  total                    {a}10,365,678{/}",
        "",
        "in transit",
        "  200,000  outfit → co:11   arrives 178",
        "",
        "standing policies",
        "  co:1   top up to 200k · cap 400k/mo",
        "  co:11  top up to 300k · cap 300k/mo",
        "  hq:2   top up to 250k · cap 500k/mo",
        "",
        "loans",
        "  none",
        "",
        "next 30 days",
        "  payroll          −742,000",
        "  HQ upkeep        −310,000",
        "  hull upkeep      −128,000",
        "  link upkeep       −40,000",
        "  contract pay     +343,848",
        "  policies         −500,000 (est.)",
        "  net             {c}−1,376,152{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[t] transfer  [p] policy  [L] loan{/}",
    ], focused=True)
    g.pane(47, 2, 56, 44, "P&L · Alpha Company", [
        "category               31 days      campaign",
        "contract_payment      +343,848    +1,375,392",
        "salvage               +858,750    +1,871,250",
        "event                 +100,000      +100,000",
        "fund_transfer         +200,000      +800,000",
        "────────────────────────────────────────────",
        "hardship_pay           −15,707       −62,828",
        "local_supplies         −38,400      −153,600",
        "transport_charter       −9,800       −39,200",
        "field_repairs           −6,200       −24,800",
        "────────────────────────────────────────────",
        "NET                 {g}+1,432,491{/}  {g}+3,866,214{/}",
        "",
        "{d}outfit-level costs not charged here:{/}",
        "{d}payroll 742,000 · hull upkeep 128,000{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[ ] period  [j/k] entity{/}",
    ], right_title="[ ] period")
    g.pane(104, 2, 96, 44, "LEDGER · Alpha Company", [
        "day   date        category           amount      counterparty      note",
        "174   06-23       fund_transfer     +200,000     outfit            standing policy top-up",
        "171   06-20       salvage           +858,750     field             battle 4 · truck-capped",
        "170   06-19       local_supplies     −12,000     Sheratan market   provisions 6t ×2.0",
        "168   06-17       field_repairs       −6,200     —                 #8 AS7-D armor patch",
        "165   06-14       event             +100,000     employer          civil_disturbance choice",
        "161   06-10       hardship_pay       −15,707     crew              deployed 30 days",
        "158   06-07       contract_payment  +343,848     CC                pirate_hunting monthly",
        "152   06-01       local_supplies     −12,000     Sheratan market   provisions 6t ×2.0",
        "147   05-27       fund_transfer     +200,000     outfit            standing policy top-up",
        "143   05-23       transport_charter   −9,800     Sheratan port     resupply drop",
        "141   05-21       salvage           +610,500     field             battle 2",
        "131   05-11       hardship_pay       −15,707     crew              deployed 30 days",
        "128   05-08       contract_payment  +343,848     CC                pirate_hunting monthly",
        "122   05-02       local_supplies     −14,400     Sheratan market   prov. 6t · medical 1t",
        "117   04-27       fund_transfer     +200,000     outfit            standing policy top-up",
        "112   04-22       salvage           +402,000     field             battle 1",
        "98    04-08       contract_payment  +343,848     CC                pirate_hunting monthly",
        "92    04-02       transport_charter  −19,600     Komephoros port   deployment lift",
        "90    03-31       contract_payment  +412,000     CC                advance",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}↓ 192 more · [/] filter category · [Enter] open entry{/}",
    ])
    return g


def supply():
    g = frame(5)
    g.pane(0, 2, 119, 30, "SITES", [
        "hq:1 {a}Komephoros warehouse{/}  lv1     {g}" + bar(0.31, 44) + "{/}   62t / 200t   free 138t",
        "   provisions 34t · armor 10t · ammo_lrm 8t · ammo_srm 8t · ammo_ac5 2t · medical 4t · comp_torso 2 (12t) · lrm15 0",
        "   burn at home  0.8t/day provisions → 42 days of supply",
        "",
        "hq:2 {a}Firebase Kalmar{/}  field HQ  {g}" + bar(0.22, 44) + "{/}   22t / 100t   free 78t",
        "   provisions 12t · ammo_srm 4t · ammo_lrm 2t · medical 2t · armor 2t",
        "",
        "co:11 {a}Bravo field stores{/}          {a}" + bar(0.18, 44) + "{/}   18t / 100t   4 CGT-3 trucks",
        "   provisions 9t · ammo_lrm 2t · ammo_srm 3t · ammo_ac5 1t · medical 2t · armor 1t",
        "   burn 1.0t/day → {c}9 days of supply{/}  ·  ammo: lrm {c}dry after next battle{/} · srm ok · ac5 low",
        "",
        "co:1 {a}Alpha field stores{/}           {g}" + bar(0.60, 44) + "{/}   60t / 100t   loaded for deployment",
        "",
        "inbound",
        "  #41  ammo_lrm x3 (3t)        hq:1 → co:11    departed day 177   eta day 189   via link, 24 days",
        "  #42  provisions x15 (15t)    hq:1 → co:11    departed day 177   eta day 189",
        "  #40  comp_torso x1 (6t)      market → hq:1   ordered day 170    eta day 178   {d}logistics roll 3 · industry 2{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[o] order to site  [s] ship between sites  [b] shop markets  [Enter] open site{/}",
    ], focused=True)
    g.pane(120, 2, 80, 30, "DEMAND", [
        "part          need  on hand  on order  short  source          est. cost",
        "{c}lrm15{/}            1        0         0    {c}1{/}   order (rare)     120,000",
        "{c}comp_torso{/}       2        2         1    {g}0{/}   fabricate/buy    —",
        "{c}ammo_lrm{/}         6        3         3    {g}0{/}   order            —",
        "{a}armor{/}           4t       3t         0   {a}1t{/}   staple           10,000",
        "{a}provisions{/}     30t       9t       15t   {a}6t{/}   local ×2.5/ship  12,000",
        "",
        "{d}need = damaged slots + 30-day burn for deployed companies{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[Enter] order the shortfall  [f] fabricate  [m] shop{/}",
    ])
    g.pane(0, 32, 119, 14, "ORDERS", [
        "id    part           qty   dest      status        placed   eta    cost       roll",
        "#42   provisions      15   co:11     in transit    177      189    36,000     —",
        "#41   ammo_lrm         3   co:11     in transit    177      189    132,000    —",
        "#40   comp_torso       1   hq:1      sourcing      170      178    180,000    log 3 · ind 2 · {g}found{/}",
        "#39   ammo_srm         4   hq:1      {g}delivered{/}     158      170    96,000     —",
        "#38   lrm15            1   hq:1      {c}not found{/}     150      —      —          log 3 · ind 2 · rare · retry day 180",
        "",
        "",
        "",
        "",
        "",
        "{d}[Enter] open  [x] cancel (not yet shipped){/}",
    ])
    g.pane(120, 32, 80, 14, "ORDER", [
        "part        {s}ammo_lrm{/}",
        "quantity    4          {d}(4t · 4 pallets){/}",
        "to          co:11 Bravo Company (field, Sheratan)",
        "source      hq:1 Komephoros → link → Sheratan",
        "roll        logistics 3 · industry 2 · staple: {g}auto{/}",
        "cost        132,000 + 8,000 freight",
        "eta         24 days · arrives day 201",
        "room        {g}ok{/} · dest 82t free · link 28t/week free",
        "pays        {a}hq:1 (−192,880){/}  {c}insufficient — transfer first{/}",
        "",
        "",
        "{d}[Enter] place  [Esc] cancel{/}",
    ])
    return g


def hq():
    g = frame(6)
    g.pane(0, 2, 112, 20, "hq:1 Komephoros Regional HQ", pad([
        "facility           built   effective   staff   next level     cost         days   effect of next level",
        "mek_bay              1         1        4/4    → 2         3,200,000       35   4 bays · refit class C",
        "warehouse            1         1        3/3    {a}PROJECT → 2   paperwork · day 37{/}   400t storage",
        "hospital             1         1        4/4    → 2         2,000,000       35   20 beds · heal ×1.25",
        "mess                 1         1        3/3    → 2           600,000       35   morale +2 · provisions −5%",
        "comms                1         1        4/4    → 2         2,400,000       35   ring 100 LY · offers +2",
        "spaceport            1         1        {c}2/4{/}    → 2         4,800,000       35   2 berths · transit −10%",
        "hiring_hall          1         1        4/4    → 2           800,000       35   8 candidates · churn daily",
        "training_ground      1         1        4/4    → 2         1,200,000       35   2 lanes · training −20% days",
        "",
        "capacity     1 company · ≤4 lances · 1 support company · 1 dropship berth · 200t storage · 10 beds",
        "ceilings     refit class {a}B{/} · paperwork 6 days (+2 finance short) · structural repair {g}yes{/} · training {g}yes{/}",
        "upkeep       310,000 / month · due day 182 · treasury {c}−192,880{/}",
    ], 17) + ["{d}[u] upgrade facility  [T] upgrade tier (regional → major, 12M)  [f] fabricate  [ ] switch HQ{/}"],
        focused=True, right_title="regional · ring 75 LY · funds −192,880 · staff 28/30")
    g.pane(113, 2, 87, 20, "BACK OFFICE  28/30", pad([
        "role               have  need  best exp   effect",
        "admin_command        5     5    veteran    orders, morale",
        "admin_logistics      4     4    veteran    order rolls +1",
        "admin_transport      4     4    regular    shipping ETAs −5%",
        "admin_hr             8     8    elite      hiring bonus +1, training −10% days",
        "admin_finance        {c}7     9{/}    elite      paperwork {c}+2 days{/}",
        "",
        "understaffed → facilities run one level below built and paperwork slows",
        "hiring hall has 2 admin_finance candidates today",
    ], 17) + ["{d}[P] post person  [h] hiring hall{/}"])
    g.pane(0, 22, 60, 12, "BAYS  2/2 busy", pad([
        "bay  job           hull / part   done      tech hours",
        "1    depot_repair  AS7-D #8      day 178   24h Reyes",
        "2    fabrication   comp_torso    day 181   12h Osei",
        "queued",
        "  depot_repair  JR7-D #12      17 days   waits bay",
        "  fabrication   comp_torso      9 days   waits bay",
        "  refit         TDR-5S #3       3 days   {c}plan illegal{/}",
        "{d}mek_bay lv2 → 4 bays{/}",
    ], 9) + ["{d}[Enter] open job  [x] cancel queued{/}"])
    g.pane(61, 22, 139, 12, "PROJECTS", pad([
        "project                   phase          started   done     cost        blocked by",
        "warehouse → lv2           paperwork      day 171   day 177  1,600,000   {c}HQ funds −192,880 — construction cannot start unpaid{/}",
        "                          construction   day 177   day 212",
        "",
        "history",
        "  hiring_hall lv1           built day 0",
        "  hq:2 Firebase Kalmar      founded day 120 · field HQ · 3,200,000",
    ], 9) + ["{d}[Enter] open  [x] cancel (refund 50%){/}"])
    g.pane(0, 34, 200, 12, "HIRING HALL · 7 candidates · churns daily", pad([
        "name                 role           exp        skill    ask / mo   bonus     notes",
        "{s}> Ilse Brandt          tech_mek       veteran    tech 4   2,400      12,000    {g}fills #4 WHM-6R{/}{/}",
        "  Tomas Reyes Jr.      mekwarrior     green      5/6      1,000       2,000    scout-rated",
        "  Priya Anand          admin_finance  regular    —        1,200       4,000    {g}fills finance 7→8{/}",
        "  Wen Zhao             admin_finance  green      —          900       2,000    {g}fills finance 8→9{/}",
        "  Hugo Ferrante        medic          regular    med 5    1,300       3,000",
        "  Dara Okonkwo         astech         regular    tech 7     800       1,500",
        "  Lena Sørensen        mekwarrior     regular    4/5      1,500       6,000    ex-LC regular",
    ], 9) + ["{d}hr 8/8 · hall lv1 · recruit bonus +1 · listings expire in 3–9 days   ·   [Enter] hire  [r] recruit (generate, 30 days){/}"])
    return g


def lab():
    g = frame(7)
    g.pane(0, 2, 66, 44, "#3 TDR-5S Thunderbolt", [
        "chassis    structure 6.5 · engine 260 13.5 · gyro 3.0",
        "           cockpit 3.0 · armor 13.0 · sinks 15 (+5) 5.0",
        "           = {a}44.0t{/}",
        "mounts     {a}21.0t{/}    total {a}65.0t{/}    free {g}0.0t{/}",
        "",
        "location   crits used  free   contents",
        "hd            0/1       1",
        "ct            0/2       2",
        "lt            8/12      4     lrm15 ×3, ammo ×2, srm2, HS ×2",
        "rt            6/12      6     mlas ×3, ammo, HS ×2",
        "la            0/8       8",
        "ra            2/8       6     llas ×2",
        "ll            2/2       0     HS ×2",
        "rl            2/2       0     HS ×2",
        "",
        "heat       alpha strike 26 · sinks 15 · {a}+11 net{/}",
        "walk 4 · run 6 · jump 0 · armor 224 / 224",
        "",
        "refit ceiling here   class {a}B{/} (mek_bay lv1)",
        "class A  swap same-size part        ×1.0 hours",
        "class B  swap within slot class     ×1.5",
        "class C  change slot class / ammo   ×2.0   {c}needs lv2{/}",
        "class D  engine / structure         ×3.0   {c}needs lv3{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[ ] switch hull{/}",
    ])
    g.pane(67, 2, 70, 44, "MOUNTS", [
        "  slot             part      class    tons   crits  heat  state",
        "{s}> ra.llas.1        llas      energy    5.0     2      8   ok{/}",
        "  ra.llas.2        llas      energy    5.0     2      8   ok",
        "  lt.lrm15.1       lrm15     missile   7.0     3      5   {c}damaged{/}",
        "  lt.ammo_lrm.1    ammo_lrm  ammo      1.0     1      —   8/8",
        "  lt.ammo_lrm.2    ammo_lrm  ammo      1.0     1      —   5/8",
        "  lt.srm2.1        srm2      missile   1.0     1      2   ok",
        "  rt.mlas.1        mlas      energy    1.0     1      3   ok",
        "  rt.mlas.2        mlas      energy    1.0     1      3   ok",
        "  rt.mlas.3        mlas      energy    1.0     1      3   ok",
        "  rt.ammo_srm.1    ammo_srm  ammo      1.0     1      —   50/50",
        "  {d}implicit{/}         hs ×4     sink      —       4      —   ll/rl",
        "",
        "structure    8/8 locations ok",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[-] remove  [+] install…  [j/k] select{/}",
    ], focused=True)
    g.pane(138, 2, 62, 24, "PLAN · class C · 34 tech-hours", pad([
        "  op        slot / location    part     tons   crits",
        "  − remove  ra.llas.1          llas     −5.0   −2",
        "  + install ra                 ppc      +7.0   +3",
        "",
        "after        mass {c}67.0t / 65t{/} · crits ra 3/8",
        "             heat 26 → 28 (+13 net)",
        "hours        34 · Ulmer 8/36 this week · ~2 weeks in bay",
        "parts        ppc: {c}0 on hand{/} · on board 280,000",
        "",
        "{c}RULES: ILLEGAL{/}",
        "{c}! overweight by 2.0 tons (67.0 / 65.0){/}",
        "{c}! class C exceeds bay ceiling B — needs mek_bay lv2{/}",
    ], 21) + ["{d}[c] clear  [Enter] commit (disabled: illegal){/}"])
    g.pane(138, 26, 62, 20, "PARTS AVAILABLE · Komephoros", pad([
        "part     class      tons  crits  heat  hand  board",
        "ppc      energy     7.0   3      10    0     280,000 stpl",
        "llas     energy     5.0   2      8     1     —",
        "mlas     energy     1.0   1      3     2     40,000 staple",
        "lrm10    missile    5.0   2      4     0     {a}rare{/}",
        "srm6     missile    3.0   2      4     1     80,000 staple",
        "ac5      ballistic  8.0   4      1     0     —",
        "hs       sink       1.0   1      —     6     6,000 staple",
    ], 17) + ["{d}[Enter] stage install of the selected part{/}"])
    return g


def end_turn():
    g = contracts()
    g.dim_all()
    g.pane(52, 14, 96, 18, "END TURN?", [
        "",
        "  5 things on your desk before day 177:",
        "",
        "  {c}!{/} civil_disturbance defaults tomorrow: \"Measured response\"        {d}→ [1] open decision{/}",
        "  {c}!{/} Komephoros Regional HQ understaffed 28/30                        {d}→ [2] hiring hall{/}",
        "  {c}!{/} Komephoros Regional HQ treasury overdrawn (−192,880)             {d}→ [3] transfer funds{/}",
        "  {a}·{/} #4 WHM-6R has no tech assigned                                   {d}→ [4] forces{/}",
        "  {a}·{/} Bravo Company has 9 days of provisions                           {d}→ [5] supply{/}",
        "",
        "",
        "",
        "",
        "",
        "  {s} [n] end the turn anyway {/}    {d}[N] end 7 turns · [Esc] back{/}",
        "",
    ], double=True)
    g.chrome(3)
    return g


def desk_fallback():
    global GRAPHICS
    GRAPHICS = False
    try:
        return desk()
    finally:
        GRAPHICS = True


def quit_modal():
    g = desk()
    g.dim_all()
    g.pane(70, 18, 60, 11, "RETURN TO WELCOME?", [
        "",
        "  unsaved progress: {a}3 turns{/} since the save on day 173",
        "",
        "  {s} [s] save and return {/}",
        "    [r] return without saving",
        "    [Esc] stay in the campaign",
        "",
        "",
    ], double=True)
    g.chrome(0)
    return g


# --------------------------------------------------------------- lobby

def welcome():
    g = shell("MERCENARY COMMAND CONSOLE",
              "{d}[Enter] continue  [n] new campaign  [d] delete campaign  [p] new player  [D] delete player  [j/k] select  [Tab] pane  [q] quit{/}",
              right="saves: ~/.merc/campaigns.db · 2 players · 3 campaigns · schema v4")
    g.pane(0, 2, 30, 30, "PLAYERS", pad([
        "{s}> John{/}",
        "    2 campaigns",
        "  Guest",
        "    1 campaign",
    ], 27) + ["{d}[p] new  [D] delete{/}"], focused=True)
    wolf = [row.ljust(10) for row in EMBLEMS[0][1]]
    g.pane(31, 2, 100, 30, "CAMPAIGNS · John", pad([
        "            {s}> The Unforgiven{/}",
        "              Erik Kalmar · Lyran Commonwealth · Quartermaster",
        "              day 176 · 3025-06-25 · 2 companies · 2 HQs · outfit 6,881,836 C",
        "              saved today 14:02 · seed 0x9f3a2c",
        "",
        "",
        "",
        f"{wolf[0]}    Kalmar's Free Legion",
        f"{wolf[1]}    Mira Blackwater · Federated Suns · Line Officer",
        f"{wolf[2]}    day 31 · 3025-02-01 · 1 company · 1 HQ · outfit 9,120,000 C",
        "              saved 3 days ago",
    ], 27) + ["{d}[Enter] continue  [n] new  [d] delete{/}"])
    g.blit(33, 3, 10, 5)
    g.pane(132, 2, 68, 30, "EMBLEM · The Unforgiven")
    g.blit(138, 3, 56, 28)
    g.pane(0, 32, 200, 16, "SNAPSHOT · The Unforgiven", [
        "companies   Alpha Company at Komephoros, rested · Bravo Company deployed on Sheratan (pirate_hunting, 94 days left, pool 57% destroyed)",
        "HQs         Komephoros Regional HQ (ring 75 LY, staff 28/30, {c}treasury −192,880{/}) · Firebase Kalmar (field HQ, Sheratan)",
        "forces      64 hulls · 336 people · 13,052 + 12,890 BV · 3 hulls in depot · 2 in medbay",
        "money       outfit {a}6,881,836{/} C · total across treasuries 10,365,678 C · reputation {g}+3{/}",
        "waiting     inbox {c}1{/} decision (civil_disturbance, 4 days) · checklist {c}2{/} warnings · 2 shipments inbound",
        "",
        "{d}saved at day 176 · 3025-06-25 · schema v4 · seed 0x9f3a2c · 41 saves in history{/}",
        "",
        "",
        "",
        "",
        "",
        "",
        "{d}[Enter] continue this campaign{/}",
    ])
    return g


def wizard_commander():
    g = shell("NEW CAMPAIGN · step 1 of 4 · Commander",
              "{d}[Tab] next field  [j/k] choose  [Enter] next step  [Esc] back to welcome{/}", right="player: John")
    g.pane(0, 2, 80, 46, "COMMANDER", pad([
        "name        {s}Erik Kalmar_{/}",
        "callsign    Kalmar",
        "",
        "faction of origin",
        "  {s}> Lyran Commonwealth      LC{/}",
        "    Draconis Combine        DC",
        "    Federated Suns          FS",
        "    Capellan Confederation  CC",
        "    Free Worlds League      FWL",
        "",
        "profession",
        "  {s}> Quartermaster{/}        orders and supplies −2% cost",
        "    Paymaster              payroll −2%",
        "    Chief Tech             repair and refit hours −2%",
        "    Line Officer           fatigue −2% per contract",
        "",
        "background",
        "    {d}rolled at step 4 from faction and profession:{/}",
        "    {d}starting world, first contacts, one starting trait{/}",
    ], 43) + ["{d}[Enter] continue to outfit{/}"], focused=True)
    g.pane(81, 2, 119, 46, "WHAT THIS MEANS", pad([
        "{a}Lyran Commonwealth{/}",
        "Your starter HQ is placed on a Lyran-adjacent world, weighted toward the Capellan and Draconis",
        "marches where the work is. Your first contract board leans to LC employers (×1.05 pay) and",
        "LC-origin recruits arrive slightly more often at the hiring hall.",
        "",
        "starting worlds (weighted)",
        "  Komephoros 30% · Skye 20% · Alkaid 15% · Summer 15% · Solaris VII 10% · others 10%",
        "",
        "{a}Quartermaster{/}",
        "Every part, munition and provisions order costs 2% less for the life of the campaign.",
        "The edge is small by design: it tilts, it never carries.",
        "",
        "{d}the faction and profession are permanent; names can be changed later{/}",
    ], 44))
    return g


def wizard_outfit():
    g = shell("NEW CAMPAIGN · step 2 of 4 · Outfit & emblem",
              "{d}[Tab] next field  [1/2/3] emblem source  [-/+] size  [Enter] next step  [Esc] back{/}", right="player: John")
    presets = "  ".join(("{d}" + name + "{/}") for name, _ in EMBLEMS)
    g.pane(0, 2, 90, 46, "OUTFIT", pad([
        "outfit name      {s}The Unforgiven_{/}",
        "first company    Alpha Company",
        "support company  Omega Company",
        "",
        "emblem source    [1] presets     [2] draw     {s}[3] import{/}",
        "",
        "~/.merc/logos/",
        "  {s}> unforgiven.png        1254 × 1254   RGB   2.2 MB{/}",
        "    wolfshead.png          800 × 800    RGBA  310 KB",
        "",
        "display on this terminal",
        "  graphics protocol    {g}kitty · detected{/}         the picture itself, placed over cells",
        "  colour               truecolour                 half-block fallback, 2 px per cell",
        "  fit                  contain · keep picture background",
        "  sizes                corner 8×3 · desk 40×20 · welcome 56×28 · preview 88×44",
        "",
        "presets          " + presets,
        "draw             {d}a cell editor: block characters and 16 colours, same sizes{/}",
    ], 43) + ["{d}[Enter] use this emblem and continue to company{/}"], focused=True)
    g.pane(91, 2, 109, 46, "PREVIEW · 88×44 cells · half-block colour")
    g.blit(101, 3, 88, 44)
    return g


def wizard_company():
    g = shell("NEW CAMPAIGN · step 3 of 4 · Company & back office",
              "{d}[j/k] row  [-/+] adjust  [r] reroll company  [Enter] next step  [Esc] back{/}", right="player: John")
    g.pane(0, 2, 100, 46, "GENERATED COMPANY", pad([
        "{a}Alpha Company{/} · home: Komephoros (LC-weighted roll) · seed 0x9f3a2c · 13,052 BV · 168 people",
        "",
        "lance           hull     name           tons   pilot                 exp       tech",
        "1st Lance       MAD-3R   Marauder        75    Sofia Quintana        veteran   Jan Marlowe",
        "                WVR-6R   Wolverine       55    Thabo Mbeki           regular   Ida Eriksson",
        "                TDR-5S   Thunderbolt     65    Rafael Jankowski      regular   Sergei Ulmer",
        "                WHM-6R   Warhammer       70    Anna Ulmer            veteran   Sergei Ulmer",
        "2nd Lance       SHD-2H   Shadow Hawk     55    Luís Ferreira         regular   Kofi Osei",
        "                GRF-1N   Griffin         55    Nils Halvorsen        regular   Kofi Osei",
        "                PXH-1    Phoenix Hawk    45    Kei Nakamura          regular   Mateo Reyes",
        "                AS7-D    Atlas          100    Marc Duval            green     Mateo Reyes",
        "3rd Lance       JR7-D    Jenner          35    Ines Baptista         green     Ola Nystrøm",
        "                LCT-1V   Locust          20    Yusuf Demir           regular   Ola Nystrøm",
        "                CDA-2A   Cicada          40    Hana Sato             green     Petra Vogel",
        "                COM-2D   Commando        25    Bram de Vries         regular   Petra Vogel",
        "Recon Lance     LCT-1V   Locust          20    Aiko Tanaka           regular   Sam Okoro",
        "                STG-3R   Stinger         20    Diego Alonso          regular   Sam Okoro",
        "                WSP-1A   Wasp            20    Maya Lindqvist        green     Ravi Menon",
        "                LCT-1V   Locust          20    Tomas Kral            regular   Ravi Menon",
        "Omega Company   4 SVT-1 · 4 MASH-27 (4 medics) · 4 CGT-3 · 4 SEC-PLT (28 infantry)",
        "",
        "crew            16 mekwarriors (3 veteran · 9 regular · 4 green) · 16 techs · 20 astechs",
        "                4 medics · 12 drivers · 28 infantry",
        "readiness       {g}92%{/} after signing · armor {g}100%{/} · ammo {g}10t per family{/} · provisions 34t",
    ], 43) + ["{d}[r] reroll (new seed)  [Enter] continue{/}"])
    g.pane(101, 2, 99, 24, "BACK OFFICE", pad([
        "role               hire   need   payroll / mo   effect",
        "{s}> admin_command        5      5       12,500     orders, morale{/}",
        "  admin_logistics      4      4       10,000     order rolls +1 per 4",
        "  admin_transport      4      4       10,000     shipping ETAs −5% per 4",
        "  admin_hr             8      8       20,000     hiring bonus, training days",
        "  admin_finance        {c}7      9{/}       17,500     paperwork days · {c}2 short: +2 days per project{/}",
        "",
        "  hospital beds        10                          from hospital lv1",
        "  bay slots            2                           from mek_bay lv1",
        "",
        "{d}under-hiring is allowed; the penalty is shown, not hidden{/}",
    ], 21) + ["{d}[-] fewer  [+] more{/}"], focused=True)
    g.pane(101, 26, 99, 22, "STARTING TREASURY", pad([
        "starting funds                 {a}12,000,000{/}",
        "  signing bonuses                −480,000",
        "  first month payroll            −742,000",
        "  HQ seed (Komephoros)         −1,000,000",
        "  company local funds            −250,000",
        "  stock (provisions, ammo)       −312,000",
        "  ───────────────────────────────────────",
        "  outfit after founding        {a}9,216,000{/}",
        "",
        "monthly run-rate               {c}−1,180,000{/}  before contracts",
        "runway                         ~7 months idle",
    ], 20))
    return g


def wizard_review():
    g = shell("NEW CAMPAIGN · step 4 of 4 · Review",
              "{d}[Enter] begin campaign  [1-3] back to a step  [Esc] discard{/}", right="player: John")
    text = [
        "",
        "{a}The Unforgiven{/}",
        "Erik Kalmar · Lyran Commonwealth · Quartermaster (orders −2%)",
        "{d}3025-01-01 · day 0{/}",
        "",
        "starter HQ     {a}Komephoros Regional HQ{/} · CC space, 20 LY from Sheratan · all facilities lv1 · ring 75 LY · 200t storage · 10 beds · 2 bays",
        "company        Alpha Company: 3 line lances + Recon Lance + Omega Company · 13,052 BV · 168 people · readiness 92%",
        "back office    28 of 30 required · {c}finance 7/9 (+2 paperwork days){/}",
        "treasury       outfit {a}9,216,000{/} C · HQ 1,000,000 C · company local funds 250,000 C",
        "stock          provisions 34t · armor 10t · ammo 10t per family · medical 4t · comp_torso 2",
        "first board    3 offers within the ring on day 1 (LC employers favoured) · hiring hall 6 candidates",
        "background     {d}rolled:{/} \"Left the Lyran Guards after Sheratan\" · trait: {g}Known on Sheratan{/} (CC offers ×1.05)",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "{s} [Enter] begin campaign {/}   {d}saves as a new campaign under player John and opens the Desk on day 0{/}",
    ]
    g.pane(0, 2, 200, 46, "REVIEW", [f"{' ' * 40}   {t}" for t in text], focused=True)
    g.blit(2, 3, 40, 20)
    return g


def delete_confirm():
    g = welcome()
    g.dim_all()
    g.pane(66, 16, 68, 13, "DELETE CAMPAIGN?", [
        "",
        "  {c}The Unforgiven{/} — Erik Kalmar, day 176, 41 saves",
        "",
        "  This removes the campaign and every save of it from the",
        "  database. It cannot be undone.",
        "",
        "  type the outfit name to confirm:   {s}The Unfo_{/}",
        "",
        "  {d}[Enter] delete   [Esc] keep{/}",
        "",
    ], double=True)
    g.put(0, 0, " MERCENARY COMMAND CONSOLE ", "t")
    return g


# --------------------------------------------------------------- page

LOBBY = [
    ("Welcome", welcome,
     "The lobby, before any campaign is loaded. Players on the left, that player's campaigns with their emblem, commander and state in the middle, the selected outfit's emblem at 56×28 on the right, and a snapshot underneath so you know what you are walking back into. Everything the database can do lives here: continue, create, delete a campaign; create or delete a player.",
     "<b>Enter</b> continue · <b>n</b> new campaign · <b>d</b> delete campaign · <b>p</b> new player · <b>D</b> delete player · <b>q</b> quit"),
    ("New campaign · 1 Commander", wizard_commander,
     "Character creation. Name and callsign, the faction of origin that decides where your starter HQ lands and which employers favour you, and the profession that grants its permanent 2% edge. The right pane explains each choice as the cursor moves.",
     "<b>Tab</b> next field · <b>j/k</b> choose · <b>Enter</b> next step · <b>Esc</b> back"),
    ("New campaign · 2 Outfit & emblem", wizard_outfit,
     "Name the outfit and its companies, then make the emblem: a preset, a cell-by-cell drawing, or a picture from the logos directory. Import reports how this terminal will display it — the picture itself where a graphics protocol exists, half-block colour otherwise — and previews it at 88×44 cells, the largest it is ever drawn.",
     "<b>1/2/3</b> source · <b>-/+</b> size · <b>Enter</b> use this emblem"),
    ("New campaign · 3 Company & back office", wizard_company,
     "The generated company hull by hull with its pilots and techs (rerollable), the back office sized by hand against the HQ's requirement with payroll and effect per role, and the starting treasury updating as you adjust. Under-hiring is allowed; the cost is shown as the penalty you will live with.",
     "<b>j/k</b> row · <b>-/+</b> adjust headcount · <b>r</b> reroll company · <b>Enter</b> next step"),
    ("New campaign · 4 Review", wizard_review,
     "Everything about to be committed, on one screen with the emblem. Any step can be revisited; Enter creates the campaign in the database under the current player and opens the Desk on day 0.",
     "<b>Enter</b> begin · <b>1–3</b> back to a step · <b>Esc</b> discard"),
    ("Deleting a campaign", delete_confirm,
     "Deletion asks for the outfit name typed back — the one destructive action in the lobby is never a single keypress.",
     "type the name · <b>Enter</b> delete · <b>Esc</b> keep"),
]

SCREENS = [
    ("F1 · Desk", desk,
     "Where a turn starts and ends. The emblem, the checklist and the inbox across the top; every company's posture in one strip; the log since last turn with fourteen rows instead of five; the HQ network on the right.",
     "<b>Enter</b> on an inbox row opens the decision · <b>Enter</b> on a checklist row jumps to the screen that fixes it · <b>n</b> end turn · <b>N</b> end 7 turns"),
    ("F1 · Desk without a graphics protocol", desk_fallback,
     "The same Desk on a terminal that cannot show pictures (Terminal.app, a plain xterm): the emblem cells are drawn as half-block colour instead, two pixels per cell. Every other cell is identical.",
     "fallback: half-block colour · then an ASCII ramp on monochrome terminals"),
    ("F2 · Map", star_map,
     "The star map drawn from the real planet table at 1.7 light-years per column: influence rings around both HQs, the beachhead band, offers pinned to worlds, HQs and the cursor. The side panes explain the world under the cursor and what your reach currently covers.",
     "<b>h j k l</b> move cursor · <b>Enter</b> open world · <b>o</b> offers here · <b>f</b> found HQ · <b>r</b> rings on/off"),
    ("F3 · Forces", forces,
     "The TO&E as a tree with pilot, tech and state per hull; the selected hull's mounts, ammo, armor and repair needs; the unassigned pool; the selected person; and the medbay. Open slots are red, and the same facts drive the checklist.",
     "<b>Enter</b> expand/select · <b>a</b> assign · <b>u</b> unassign · <b>A</b> auto-assign · <b>t</b> train · <b>x</b> transfer · <b>m</b> medbay"),
    ("F4 · Contracts", contracts,
     "The board with every column that matters to the decision, including the maintenance estimate and whether the force can field it. Below, the active contract with its opposition pool, duration, victory points, breach exposure and battle history, and the latest after-action report beside it.",
     "<b>Enter</b> accept with company… · <b>c</b> complete · <b>R</b> recall · <b>v</b> AARs"),
    ("F5 · Ledger", ledger,
     "Money lives in places. Treasuries, couriers, policies and a 30-day forecast on the left; the P&L for the selected entity in two periods; that entity's transactions with counterparties and notes on the right.",
     "<b>j/k</b> pick entity · <b>t</b> transfer… · <b>p</b> policy… · <b>[ ]</b> period · <b>L</b> loan"),
    ("F6 · Supply", supply,
     "Every site as a tonnage bar with its contents, burn and days of supply; the demand list built from damaged slots and deployed burn; open orders with their sourcing rolls; and the order form with cost, ETA, room and who pays.",
     "<b>o</b> order · <b>s</b> ship · <b>b</b> shop · <b>Enter</b> on a demand row orders the shortfall"),
    ("F7 · HQ", hq,
     "One HQ at a time: facilities with built and effective level and what the next level buys, bays and their queue, the back office against requirement, projects with what blocks them, and the hiring hall with who fills which gap.",
     "<b>[ ]</b> switch HQ · <b>u</b> upgrade · <b>T</b> tier · <b>f</b> fabricate · <b>h</b> hire · <b>P</b> post"),
    ("F8 · Lab", lab,
     "The MekLab: the hull's budget, crits per location and heat on the left; every mount in the middle; the staged plan with the rules' verdict, and the parts on hand or on the board that would fit. Illegal fits name the violated rule before you can commit.",
     "<b>j/k</b> pick mount · <b>-</b> remove · <b>+</b> install… · <b>c</b> clear · <b>Enter</b> commit · <b>[ ]</b> switch hull"),
    ("Ending a turn", end_turn,
     "Pressing <code>n</code> anywhere opens the checklist as a modal over the current screen. Each row jumps to the screen that fixes it, or you proceed anyway.",
     "<b>1–5</b> jump to the fix · <b>n</b> proceed · <b>Esc</b> back"),
    ("Leaving a campaign", quit_modal,
     "<code>q</code> from any screen offers the way back to the welcome screen, with the unsaved turns counted.",
     "<b>s</b> save and return · <b>r</b> return without saving · <b>Esc</b> stay"),
]

HEAD = """<title>Mercenary Command Console</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>
  :root { --ground:#0b0f0d; --bezel:#131a16; --rule:#22302a; --ink:#c8d3c5; --dim:#6f7d73; --amber:#e0a33a; --good:#7fc97f; --crit:#e05a4f; --sel:#6fc3c3; --selbg:#0f2a2a;
          --mono:"IBM Plex Mono","JetBrains Mono",Menlo,Consolas,monospace; --sans:"IBM Plex Sans","Helvetica Neue",Arial,sans-serif; }
  body { background:var(--ground); color:var(--ink); font-family:var(--sans); margin:0; }
  main { max-width:1720px; margin:0 auto; padding:40px 24px 80px; display:grid; gap:40px; }
  header h1 { font-family:var(--mono); font-weight:600; font-size:22px; letter-spacing:.02em; margin:0 0 8px; color:var(--amber); text-wrap:balance; }
  header p, .cap p { max-width:78ch; line-height:1.55; margin:0; color:var(--ink); }
  .cap { display:grid; gap:8px; }
  .cap h2 { font-family:var(--mono); font-size:14px; font-weight:600; letter-spacing:.08em; text-transform:uppercase; color:var(--amber); margin:0; }
  .cap .keys { font-family:var(--mono); font-size:12px; color:var(--dim); }
  .cap .keys b { color:var(--sel); font-weight:600; }
  .screen { background:var(--bezel); border:1px solid var(--rule); border-radius:6px; padding:12px 14px; overflow-x:auto; }
  .term, pre { font-family:var(--mono); font-size:12.5px; line-height:1.32; font-variant-numeric:tabular-nums; font-variant-ligatures:none; }
  pre { margin:0; color:var(--ink); white-space:pre; }
  .a { color:var(--amber); } .g { color:var(--good); } .c { color:var(--crit); } .d { color:var(--dim); } .p { color:#a98ad8; }
  .s { color:var(--sel); background:var(--selbg); } .t { color:var(--ground); background:var(--amber); font-weight:600; }
  .term { position:relative; display:inline-block; min-width:100%; vertical-align:top; }
  .px { display:inline-block; width:1ch; height:1.32em; vertical-align:top; }
  .ovl { position:absolute; margin:0; display:block; background:#000 url(__LOGO_URI__) center / contain no-repeat; }
  .ovl.dim { filter:brightness(.35); }
  .anat { display:grid; grid-template-columns:1fr 1fr 1fr 1fr; gap:20px 32px; max-width:1200px; }
  .anat div { border-left:2px solid var(--rule); padding-left:12px; }
  .anat h3 { font-family:var(--mono); font-size:12px; letter-spacing:.08em; text-transform:uppercase; color:var(--sel); margin:0 0 4px; }
  .anat p { font-size:14px; line-height:1.5; margin:0; color:var(--ink); }
  @media (max-width:900px) { .anat { grid-template-columns:1fr 1fr; } }
  .legend { font-family:var(--mono); font-size:12px; color:var(--dim); display:flex; gap:18px; flex-wrap:wrap; }
  table.tiers { border-collapse:collapse; font-family:var(--mono); font-size:12.5px; }
  table.tiers td, table.tiers th { padding:4px 14px 4px 0; text-align:left; color:var(--ink); border-bottom:1px solid var(--rule); }
  table.tiers th { color:var(--dim); font-weight:400; }
</style>
<main>
<header>
  <h1>Mercenary Command Console — TUI mockup, full tier (200×50)</h1>
  <p>A lobby (welcome, new-campaign wizard, delete) and eight in-game screens in one frame, laid out for a maximised terminal on a 1080p screen at a 14–16 px font, rendered as a terminal with a graphics protocol shows it (kitty, Ghostty, WezTerm, iTerm2): the outfit's crest is the real picture placed over cells. Every pane is placed on a 200-column cell grid by arithmetic, text is padded or clipped to its pane, borders land on computed columns. Every number is from the demo campaign; every verb on the command line is one the CLI already runs.</p>
</header>
<section class="cap">
  <h2>Size tiers</h2>
  <p>The client measures the terminal at startup and on resize and picks the largest tier that fits. This page shows the full tier; the compact tier is the same screens with side panes narrowed or dropped.</p>
  <table class="tiers">
    <tr><th>tier</th><th>cells</th><th>fits</th><th>what changes</th></tr>
    <tr><td>full</td><td>200 × 50</td><td>maximised at 14–16 px on 1080p</td><td>three-column screens, 14-row log, emblem 40×20 on the Desk, real-data star map</td></tr>
    <tr><td>wide</td><td>160 × 45</td><td>large window at 16 px, maximised at 18 px</td><td>same layouts, side panes narrower</td></tr>
    <tr><td>compact</td><td>118 × 36</td><td>half-screen window</td><td>two columns, 5-row log, emblem 18×9</td></tr>
    <tr><td>minimum</td><td>80 × 24</td><td>any terminal</td><td>one column, side panes hidden, no emblem</td></tr>
  </table>
</section>
<section class="cap">
  <h2>The lobby</h2>
  <p>Before the game frame there is a lobby: choose a player, then continue, create or delete a campaign. Creating one walks a four-step wizard — commander, outfit and emblem, company and back office, review — and drops you on the Desk at day 0. From inside the game, <code>q</code> brings you back here.</p>
</section>
"""

FRAME = """<section class="cap">
  <h2>The frame</h2>
  <p>Persistent chrome: a <b>tab bar</b> naming the eight screens with the outfit name and emblem mark at the right, a one-line <b>status strip</b>, the screen's <b>panes</b>, and a <b>command line</b> that opens on <code>:</code>. Panes cycle with Tab; the focused pane has a bright title. Ending the turn (<code>n</code>) always runs the checklist first.</p>
  <div class="anat">
    <div><h3>Tabs</h3><p>F1–F8 or 1–8. Desk · Map · Forces · Contracts · Ledger · Supply · HQ · Lab. The active tab is inverted amber.</p></div>
    <div><h3>Panes</h3><p>Each screen is 3–6 panes at this tier. Tab / Shift-Tab moves focus; j/k or arrows move the cursor inside a list; Enter acts on the cursor row.</p></div>
    <div><h3>Command line</h3><p><code>:</code> opens it with completion over the existing verbs (<code>:order ammo_lrm 4 co:11</code>). Esc closes. Results land in the Desk log.</p></div>
    <div><h3>Status strip</h3><p>Always visible: date and day, outfit funds, reputation, force size, pending decisions, and whether the checklist would block the turn.</p></div>
  </div>
</section>
"""

TAIL = """<section class="cap">
  <h2>Reading the mockups</h2>
  <div class="legend">
    <span><span class="a">amber</span> — attention, the active tab, values that matter</span>
    <span><span class="g">green</span> — good / in ring / ok</span>
    <span><span class="c">red</span> — critical / open slot / rule violated</span>
    <span><span class="s"> cyan </span> — cursor and focused pane</span>
    <span><span class="d">dim</span> — hints and inactive chrome</span>
  </div>
  <p>The emblem is <code>unforgiven.png</code> from the project root, shown as a graphics-protocol terminal places it: the picture itself over a rectangle of cells, sized to the pane. On a terminal without a protocol the same cells are drawn as half-block colour (the second Desk frame), and on a monochrome terminal as an ASCII ramp. Frames are generated by <code>docs/tui_mockup_gen.py</code>; the glyph set is ASCII plus box-drawing only, with an <code>--ascii</code> fallback in the client.</p>
</section>
</main>
"""

if __name__ == "__main__":
    parts = [HEAD.replace("__LOGO_URI__", LOGO_URI)]
    for group, lead in ((LOBBY, ""), (SCREENS, FRAME)):
        parts.append(lead)
        for title, fn, blurb, keys in group:
            parts.append(f'<section class="cap">\n  <h2>{title}</h2>\n  <p>{blurb}</p>\n  <p class="keys">{keys}</p>\n</section>\n')
            parts.append(f'<div class="screen">{fn().html()}</div>\n')
    parts.append(TAIL)
    print("".join(parts))
