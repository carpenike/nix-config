#!/usr/bin/env python3
"""
Central Records identity mark — emits logo.svg and favicon.ico.

One script for both so the geometry cannot drift: the vector logo and the
rasterised favicon are the same shape, defined once in RINGS below.

The mark is a contour summit — offset, non-concentric rings, echoing the
login backdrop (backdrop.py) so the page reads as one system. The offsets
are the whole design: perfectly concentric rings read as a target or a
vinyl record, and a target is exactly the military note this instance is
meant to avoid in front of Grafana and Actual Budget. Nudging each ring
off-centre turns a bullseye into terrain.

The rounded-square tile is deliberate too. Pocket ID uses this one file on
a dark login page and potentially on light chrome, so the mark carries its
own ground rather than depending on what is behind it.

Stdlib only, deterministic: same input, same bytes.
"""

import math
import struct
import sys
import zlib

SIZE = 64  # design grid; the SVG viewBox
RADIUS = 14  # tile corner radius
TILE = (0x20, 0x22, 0x1A)  # dark olive ground
RING = (0xA8, 0x8A, 0x45)  # brass, lifted brighter than --gold for 16px legibility
CORE = (0xEC, 0xE1, 0xC7)  # --paper, the summit

# (cx, cy, rx, ry, rot_deg, stroke).
#
# Three levers keep this off the bullseye it wants to become, and all three
# are needed: strong offset toward the upper-left (a summit is not centred),
# UNEVEN spacing (contours crowd on the steep face and spread on the gentle
# one), and per-ring ROTATION (concentric circles read as a target; tilted,
# unaligned ellipses read as land). An earlier version had all three too
# subtle and came out looking like an eye.
RINGS = [
    (34.0, 35.4, 23.5, 19.8, -20.0, 2.3),
    (31.0, 31.4, 14.2, 11.6, -5.0, 2.3),
    (28.6, 28.2, 6.6, 5.4, 10.0, 2.3),
]
# The innermost ring is FILLED — the summit cap. An earlier version put a
# cream dot at the centre instead (the survey convention for a spot
# height), but a pale disc ringed by ellipses reads unmistakably as an eye.
# A solid cap reads as land, and it is the one element guaranteed legible
# at 16px, where a 1px ring is mush.


def svg() -> str:
    brass = f"#{RING[0]:02X}{RING[1]:02X}{RING[2]:02X}"
    parts = []
    for i, (cx, cy, rx, ry, rot, w) in enumerate(RINGS):
        fill = brass if i == len(RINGS) - 1 else "none"
        parts.append(
            f'  <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{fill}" '
            f'stroke="{brass}" stroke-width="{w}" '
            f'transform="rotate({rot} {cx} {cy})"/>'
        )
    ellipses = "\n".join(parts)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" '
        f'width="{SIZE}" height="{SIZE}" role="img" aria-label="Central Records">\n'
        f'  <rect width="{SIZE}" height="{SIZE}" rx="{RADIUS}" '
        f'fill="#{TILE[0]:02X}{TILE[1]:02X}{TILE[2]:02X}"/>\n'
        f"{ellipses}\n"
        f"</svg>\n"
    )


def _rings_for(n):
    """Geometry simplified for small rasters.

    The full three-ring mark turns to mush at 16px — the strokes land
    sub-pixel and the rings smear into a blob. Icon sets have always solved
    this by drawing FEWER, HEAVIER elements as the grid shrinks, so at
    favicon sizes this drops the middle contour and keeps the outer ring
    plus the summit cap: still terrain, still legible at a tab's worth of
    pixels. The SVG is untouched by any of this — it is a vector and is
    always rendered large.
    """
    return [RINGS[0], RINGS[2]] if n <= 20 else RINGS


def _stroke_for(w, n):
    """Never let a contour fall below ~1.7 device pixels."""
    return max(w, 1.7 * SIZE / n)


def _coverage(px, py, n, ss):
    """Supersampled colour for one output pixel. Returns (r,g,b,a)."""
    acc = [0.0, 0.0, 0.0, 0.0]
    for sy in range(ss):
        for sx in range(ss):
            # sample point in design-grid coordinates
            x = (px + (sx + 0.5) / ss) / n * SIZE
            y = (py + (sy + 0.5) / ss) / n * SIZE

            # rounded-square tile membership
            inset_x = min(x, SIZE - x)
            inset_y = min(y, SIZE - y)
            inside = True
            if inset_x < RADIUS and inset_y < RADIUS:
                dx, dy = RADIUS - inset_x, RADIUS - inset_y
                inside = (dx * dx + dy * dy) <= RADIUS * RADIUS
            if not inside:
                continue

            col = TILE
            # rings, outer to inner so inner wins
            rings = _rings_for(n)
            for i, (cx, cy, rx, ry, rot, w) in enumerate(rings):
                # rotate the sample into the ring's own frame
                a = math.radians(-rot)
                ox, oy = x - cx, y - cy
                lx = ox * math.cos(a) - oy * math.sin(a)
                ly = ox * math.sin(a) + oy * math.cos(a)
                d = math.hypot(lx / rx, ly / ry)
                # distance from the ellipse edge, roughly in design units
                edge = abs(d - 1.0) * ((rx + ry) / 2.0)
                filled = i == len(rings) - 1
                if edge <= _stroke_for(w, n) / 2.0 or (filled and d <= 1.0):
                    col = RING

            acc[0] += col[0]
            acc[1] += col[1]
            acc[2] += col[2]
            acc[3] += 255.0
    total = ss * ss
    if acc[3] == 0:
        return (0, 0, 0, 0)
    hits = acc[3] / 255.0
    return (
        int(acc[0] / hits + 0.5),
        int(acc[1] / hits + 0.5),
        int(acc[2] / hits + 0.5),
        int(acc[3] / total + 0.5),
    )


def png(n, ss=4) -> bytes:
    rows = []
    for py in range(n):
        row = bytearray([0])
        for px in range(n):
            r, g, b, a = _coverage(px, py, n, ss)
            row += bytes((r, g, b, a))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", raw)
        + chunk(b"IEND", b"")
    )


def ico(sizes=(16, 32, 48)) -> bytes:
    """PNG-compressed ICO — supported everywhere since IE11."""
    images = [(n, png(n)) for n in sizes]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, blobs = b"", b""
    for n, data in images:
        entries += struct.pack(
            "<BBBBHHII",
            n if n < 256 else 0,
            n if n < 256 else 0,
            0,
            0,
            1,
            32,
            len(data),
            offset,
        )
        blobs += data
        offset += len(data)
    return header + entries + blobs


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    open(f"{out}/logo.svg", "w").write(svg())
    open(f"{out}/favicon.ico", "wb").write(ico())
    if "--preview" in sys.argv:
        open(f"{out}/preview.png", "wb").write(png(256, ss=3))
    print(f"wrote logo.svg, favicon.ico in {out}")
