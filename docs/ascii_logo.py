#!/usr/bin/env python3
"""Picture -> ASCII emblem, the way the TUI's emblem studio will do it.

Reads a 24-bit BMP (sips can produce one from any PNG/JPG), samples luminance
into a cols x rows character grid using a 2:1 cell aspect, and tags purple-
hued cells with the {p} colour so the terminal can paint them magenta.
Usage: ascii_logo.py <bmp> <cols> <rows>
"""
import struct, sys

RAMP = " .:-=+*#%@"


def load_bmp(path):
    data = open(path, "rb").read()
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    assert bpp == 24, "24-bit BMP expected"
    topdown = h < 0
    h = abs(h)
    stride = (w * 3 + 3) & ~3
    px = []
    for row in range(h):
        src = row if topdown else h - 1 - row
        base = off + src * stride
        line = []
        for x in range(w):
            b, g, r = data[base + x * 3: base + x * 3 + 3]
            line.append((r, g, b))
        px.append(line)
    return w, h, px


def sample(path, cols, rows):
    """Average (lum, r, g, b) per cell."""
    w, h, px = load_bmp(path)
    cells = []
    for r in range(rows):
        y0, y1 = int(r * h / rows), max(int((r + 1) * h / rows), int(r * h / rows) + 1)
        row = []
        for c in range(cols):
            x0, x1 = int(c * w / cols), max(int((c + 1) * w / cols), int(c * w / cols) + 1)
            n = lum = rr = gg = bb = 0
            for y in range(y0, y1):
                for x in range(x0, x1):
                    R, G, B = px[y][x]
                    lum += 0.2126 * R + 0.7152 * G + 0.0722 * B
                    rr += R; gg += G; bb += B; n += 1
            row.append((lum / (n * 255), rr / n, gg / n, bb / n))
        cells.append(row)
    return cells


def render(path, cols, rows, ramp=RAMP, gamma=0.55, floor=0.05):
    """Auto-levelled: the brightest cell maps to the top of the ramp, cells
    darker than `floor` become background. Tunable in the emblem studio."""
    cells = sample(path, cols, rows)
    hi = max(l for row in cells for (l, _, _, _) in row) or 1.0
    out = []
    for row in cells:
        line, cur = [], ""
        for lum, rr, gg, bb in row:
            lum = lum / hi
            if lum < floor:
                ch = " "
            else:
                lum = ((lum - floor) / (1 - floor)) ** gamma
                ch = ramp[min(len(ramp) - 1, int(lum * len(ramp)))]
            purple = bb > gg * 1.25 and rr > gg * 1.1 and ch != " "
            cls = "p" if purple else ""
            if cls != cur:
                line.append("{/}" if cls == "" else "{" + cls + "}")
                cur = cls
            line.append(ch)
        if cur:
            line.append("{/}")
        out.append("".join(line))
    return out


def pixels(path, cols, rows):
    """Half-block rendering: two vertical pixels per cell. Returns rows of
    (top_hex, bottom_hex) — the client emits `▀` with fg=top, bg=bottom."""
    cells = sample(path, cols, rows * 2)
    hexes = [["#%02x%02x%02x" % (int(r), int(g), int(b)) for (_, r, g, b) in row] for row in cells]
    return [list(zip(hexes[2 * i], hexes[2 * i + 1])) for i in range(rows)]


if __name__ == "__main__":
    path, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    for line in render(path, cols, rows):
        print(line.replace("{p}", "").replace("{/}", ""))
