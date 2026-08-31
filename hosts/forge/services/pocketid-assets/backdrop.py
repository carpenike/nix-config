#!/usr/bin/env python3
"""
Central Records login backdrop — a deterministic topographic contour field.

Stdlib only, seeded, no image provider: the same inputs always produce the
same bytes, so the asset is reproducible from text rather than committed as
an opaque blob nobody can regenerate.

Palette is lifted from the bunker's own tokens (src/styles/global.css):
--olive #4a4d2a and --olive-light #6b6f3e, on a near-black that matches the
Pocket ID dark theme. Index contours (every 5th line, as on a real survey
sheet) are drawn brighter — the detail that makes it read as a chart rather
than as decorative noise.
"""

import math
import struct
import zlib
import sys

W = H = 1800
BG = (0x0E, 0x0F, 0x0C)
LINE = (0x6B, 0x6F, 0x3E)
INDEX = (0x8A, 0x72, 0x36)  # muted brass, for index contours
SPACING = 0.092
LINE_W = 0.0105
INDEX_EVERY = 5


def field(x, y):
    """Smooth scalar field — layered sinusoids read as organic terrain."""
    v = 0.0
    v += 1.00 * math.sin(2.9 * x + 0.7 * y + 0.4)
    v += 0.70 * math.sin(-1.7 * x + 3.3 * y + 1.9)
    v += 0.45 * math.sin(4.7 * x - 2.1 * y + 3.1)
    v += 0.30 * math.sin(6.3 * x + 5.9 * y + 0.8)
    v += 0.18 * math.sin(9.1 * x - 7.7 * y + 2.2)
    # Radial dome keeps contours from marching in parallel across the frame.
    dx, dy = x - 0.35, y - 0.55
    v += 2.1 * math.exp(-3.0 * (dx * dx + dy * dy))
    v -= 1.4 * math.exp(-5.0 * ((x - 1.15) ** 2 + (y - 0.15) ** 2))
    return v


def main(path):
    rows = []
    for py in range(H):
        y = 2.0 * py / H
        row = bytearray()
        row.append(0)  # PNG filter: none
        for px in range(W):
            x = 2.0 * px / W
            v = field(x, y)
            n = v / SPACING
            band = int(math.floor(n))
            t = n - band
            d = min(t, 1.0 - t)  # distance to nearest contour, in bands

            is_index = (band % INDEX_EVERY) == 0
            w = LINE_W / SPACING * (1.9 if is_index else 1.0)
            # Soft edge so lines antialias instead of stair-stepping.
            a = 0.0 if d > w else (1.0 - (d / w) ** 2)
            a *= 0.52 if is_index else 0.30

            # Vignette: settle the edges so the panel's rounded corners and
            # the page's black surround blend rather than butt together.
            vx, vy = x - 1.0, y - 1.0
            a *= max(0.0, 1.0 - 0.55 * (vx * vx + vy * vy))

            col = INDEX if is_index else LINE
            row += bytes(int(BG[i] + (col[i] - BG[i]) * a + 0.5) for i in range(3))
        rows.append(bytes(row))
        if py % 300 == 0:
            print(f"  row {py}/{H}", file=sys.stderr)

    raw = zlib.compress(b"".join(rows), 9)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", raw)
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(png)
    print(f"wrote {path} ({len(png)} bytes, {W}x{H})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "background.png")
