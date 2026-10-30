"""Planova app icon (python tools/make_icon.py android/app/src/main/res resources): one geometry, rendered as Android vector drawables and as anti-aliased PNGs.

The mark: the brand's location pin (white) with a marigold centre -- the live colour -- and a dotted route leading
into it, on harbour 900. Geometry lives in Android's 108 x 108 adaptive-icon canvas; the launcher shows the middle
72 x 72 and masks it to the device's shape, so everything sits inside the central safe circle (radius 33).

usage: python make_icon.py <android res dir> <preview dir>
"""
import math
import os
import struct
import sys
import zlib

BG = (0x0B, 0x3D, 0x35)
WHITE = (0xFF, 0xFF, 0xFF)
MARIGOLD = (0xF2, 0xA5, 0x41)

C = (54.0, 44.5)  # pin head centre
R = 15.5  # pin head radius
TIP = (54.0, 72.5)  # pin tip
HOLE = 6.4  # marigold centre radius
DOTS = [((36.6, 79.4), 2.2), ((42.6, 77.9), 2.2), ((48.3, 75.6), 2.2)]  # the route into the pin
DOT_ALPHA = 0.72


def tangents():
    """Points where the lines from the tip touch the pin's head (left, right)."""
    dx, dy = C[0] - TIP[0], C[1] - TIP[1]
    d = math.hypot(dx, dy)
    a = math.atan2(dy, dx)
    b = math.acos(R / d)
    # angles of the tangent points seen from the centre
    p = [(C[0] + R * math.cos(a + math.pi + s * b), C[1] + R * math.sin(a + math.pi + s * b)) for s in (1, -1)]
    return sorted(p)


TL, TR = tangents()


def in_pin(x, y):
    if (x - C[0]) ** 2 + (y - C[1]) ** 2 <= R * R:
        return True
    # triangle TL - TIP - TR
    def side(ax, ay, bx, by):
        return (bx - ax) * (y - ay) - (by - ay) * (x - ax)
    s1 = side(TL[0], TL[1], TIP[0], TIP[1])
    s2 = side(TIP[0], TIP[1], TR[0], TR[1])
    s3 = side(TR[0], TR[1], TL[0], TL[1])
    return (s1 >= 0 and s2 >= 0 and s3 >= 0) or (s1 <= 0 and s2 <= 0 and s3 <= 0)


def colour_at(x, y):
    """Colour of the artwork at a point in the 108 canvas, as (rgb, alpha) over the background."""
    if (x - C[0]) ** 2 + (y - C[1]) ** 2 <= HOLE * HOLE:
        return MARIGOLD, 1.0
    if in_pin(x, y):
        return WHITE, 1.0
    for (cx, cy), r in DOTS:
        if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
            return WHITE, DOT_ALPHA
    return None, 0.0


ART_BOX = (32.0, 27.0, 72.0, 83.0)  # x0, y0, x1, y1 of everything drawn, in the 108 canvas


def png(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)


def render(w, h, scale, ox, oy, mask=None, ss=4):
    """Pixel rows (RGBA). Canvas point (u, v) lands at pixel (ox + u * scale, oy + v * scale).
    mask(px, py) -> coverage 0..1 of the icon's own outline (rounded square, circle) or None for full bleed."""
    x0 = max(0, int(ox + ART_BOX[0] * scale) - 2)
    x1 = min(w, int(ox + ART_BOX[2] * scale) + 3)
    y0 = max(0, int(oy + ART_BOX[1] * scale) - 2)
    y1 = min(h, int(oy + ART_BOX[3] * scale) + 3)
    rows = []
    for py in range(h):
        row = bytearray()
        for px in range(w):
            cov = 1.0 if mask is None else mask(px, py)
            if cov <= 0:
                row += b'\x00\x00\x00\x00'
                continue
            r, g, b = BG
            if x0 <= px < x1 and y0 <= py < y1:
                acc = [0.0, 0.0, 0.0]
                for sy in range(ss):
                    for sx in range(ss):
                        u = (px + (sx + 0.5) / ss - ox) / scale
                        v = (py + (sy + 0.5) / ss - oy) / scale
                        c, a = colour_at(u, v)
                        if c is None:
                            c, a = BG, 1.0
                        for i in range(3):
                            acc[i] += c[i] * a + BG[i] * (1 - a)
                n = ss * ss
                r, g, b = (int(round(acc[0] / n)), int(round(acc[1] / n)), int(round(acc[2] / n)))
            row += bytes((r, g, b, int(round(255 * cov))))
        rows.append(row)
    return rows


def rounded_mask(size, radius):
    def m(px, py):
        x, y = px + 0.5, py + 0.5
        cx = min(max(x, radius), size - radius)
        cy = min(max(y, radius), size - radius)
        d = math.hypot(x - cx, y - cy)
        return max(0.0, min(1.0, radius - d + 0.5))
    return m


def circle_mask(size):
    def m(px, py):
        d = math.hypot(px + 0.5 - size / 2, py + 0.5 - size / 2)
        return max(0.0, min(1.0, size / 2 - d + 0.5))
    return m


def svg_path_pin():
    """The pin outline as path data: tangent line, arc over the top, tangent line back to the tip."""
    return (f'M{TIP[0]:.3f},{TIP[1]:.3f} L{TL[0]:.3f},{TL[1]:.3f} '
            f'A{R:.3f},{R:.3f} 0 1,1 {TR[0]:.3f},{TR[1]:.3f} Z')


def circle_path(cx, cy, r):
    return f'M{cx - r:.3f},{cy:.3f} a{r:.3f},{r:.3f} 0 1,0 {2 * r:.3f},0 a{r:.3f},{r:.3f} 0 1,0 {-2 * r:.3f},0 Z'


def vectors(res):
    pin, hole = svg_path_pin(), circle_path(C[0], C[1], HOLE)
    dots = ''.join(circle_path(x, y, r) for (x, y), r in DOTS)
    head = ('<?xml version="1.0" encoding="utf-8"?>\n<!-- Planova app icon (tools: scratch make_icon.py). 108 x 108 adaptive canvas; '
            'art stays inside the central safe circle. -->\n<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:width="108dp"\n    android:height="108dp"\n    android:viewportWidth="108"\n    android:viewportHeight="108">\n')
    fg = (head +
          f'    <!-- the route into the pin -->\n    <path android:fillColor="#FFFFFF" android:fillAlpha="{DOT_ALPHA}" android:pathData="{dots}" />\n'
          f'    <!-- the brand pin -->\n    <path android:fillColor="#FFFFFF" android:pathData="{pin}" />\n'
          f'    <!-- its marigold centre: the live colour -->\n    <path android:fillColor="#F2A541" android:pathData="{hole}" />\n</vector>\n')
    bg = head + '    <path android:fillColor="#0B3D35" android:pathData="M0,0h108v108h-108z" />\n</vector>\n'
    mono = (head +
            f'    <path android:fillColor="#FFFFFF" android:fillType="evenOdd" android:pathData="{pin} {hole}" />\n'
            f'    <path android:fillColor="#FFFFFF" android:pathData="{dots}" />\n</vector>\n')
    for name, text in (('drawable-v24/ic_launcher_foreground.xml', fg), ('drawable/ic_launcher_background.xml', bg), ('drawable/ic_launcher_monochrome.xml', mono)):
        with open(os.path.join(res, name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
    adaptive = ('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
                '    <!-- Android 13+ themed icons -->\n    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n</adaptive-icon>\n')
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(res, 'mipmap-anydpi-v26', name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(adaptive)
    with open(os.path.join(res, 'values', 'ic_launcher_background.xml'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#0B3D35</color>\n</resources>\n')
    return pin, hole, dots


def main():
    res, preview = sys.argv[1], sys.argv[2]
    pin, hole, dots = vectors(res)
    # Legacy launcher icons (Android 7.x): the middle 72 of the canvas fills the icon
    for d, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
        s = size / 72.0
        png(os.path.join(res, f'mipmap-{d}', 'ic_launcher.png'), size, size, render(size, size, s, -18 * s, -18 * s, rounded_mask(size, size * 0.2)))
        png(os.path.join(res, f'mipmap-{d}', 'ic_launcher_round.png'), size, size, render(size, size, s, -18 * s, -18 * s, circle_mask(size)))
        fg_png = os.path.join(res, f'mipmap-{d}', 'ic_launcher_foreground.png')
        if os.path.exists(fg_png):
            os.remove(fg_png)  # the foreground is a vector now
    # Splash: the mark centred on harbour 900, about a fifth of the short side tall
    for name in os.listdir(res):
        p = os.path.join(res, name, 'splash.png')
        if name.startswith('drawable') and os.path.exists(p):
            with open(p, 'rb') as f:
                w, h = struct.unpack('>II', f.read(24)[16:24])
            s = min(w, h) * 0.24 / (ART_BOX[3] - ART_BOX[1])
            ox = w / 2 - 54 * s
            oy = h / 2 - 58 * s
            png(p, w, h, render(w, h, s, ox, oy, None, ss=3))
    # Previews
    os.makedirs(preview, exist_ok=True)
    s = 512 / 72.0
    png(os.path.join(preview, 'icon-512-rounded.png'), 512, 512, render(512, 512, s, -18 * s, -18 * s, rounded_mask(512, 512 * 0.22)))
    png(os.path.join(preview, 'icon-512-circle.png'), 512, 512, render(512, 512, s, -18 * s, -18 * s, circle_mask(512)))
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="18 18 72 72" width="512" height="512"><rect x="18" y="18" width="72" height="72" rx="16" fill="#0B3D35"/>'
           f'<path fill="#FFFFFF" fill-opacity="{DOT_ALPHA}" d="{dots}"/><path fill="#FFFFFF" d="{pin}"/><path fill="#F2A541" d="{hole}"/></svg>\n')
    with open(os.path.join(preview, 'planova-app-icon.svg'), 'w', encoding='utf-8') as f:
        f.write(svg)
    print('pin', pin)
    print('done')


if __name__ == '__main__':
    main()
