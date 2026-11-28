# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
# Original pixel-art loop: sunrise over calm water, same palette as the app icon.
# Usage: python3 harbor.py <out.gif>
import math, random, sys
from PIL import Image, ImageDraw

W, H, FPS, N = 480, 270, 12, 48
HY = 150
random.seed(3)
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
def ramp(stops, t):
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if a <= t <= b: return lerp(ca, cb, (t - a) / (b - a))
    return stops[-1][1]
SKY = [(0, (0x14, 0x16, 0x2C)), (0.48, (0x3A, 0x2C, 0x56)), (0.82, (0x9C, 0x5C, 0x68)), (1, (0xF0, 0xA4, 0x70))]
SEA = [(0, (0x7A, 0x4E, 0x5E)), (0.15, (0x34, 0x26, 0x42)), (0.6, (0x18, 0x16, 0x2A)), (1, (0x0C, 0x0C, 0x16))]
stars = [(random.randrange(W), random.randrange(70), random.random() * 6.28) for _ in range(50)]
clouds = [(random.randrange(W), random.randrange(40, 110), random.randint(30, 70)) for _ in range(6)]
INK, AMBER = (255, 246, 232), (255, 190, 110)

def frame(f):
    ph = f / N * 6.28
    im = Image.new("RGB", (W, H)); d = ImageDraw.Draw(im)
    for y in range(HY): d.line([(0, y), (W, y)], fill=ramp(SKY, y / HY))
    for y in range(HY, H): d.line([(0, y), (W, y)], fill=ramp(SEA, (y - HY) / (H - HY)))
    for sx, sy, p in stars:
        if math.sin(p + ph * 2) > 0: d.point((sx, sy), fill=(255, 236, 220))
    for cx, cy, cw in clouds:
        x = int((cx + f * 0.5 * (cw / 50)) % (W + cw * 2)) - cw
        d.rectangle([x, cy, x + cw, cy + 3], fill=(120, 74, 96)); d.rectangle([x + 6, cy - 3, x + cw - 10, cy], fill=(150, 90, 104))
    # rays: seven rounded bars fanning from the sun, pulsing in length
    lens = [14, 25, 20, 34, 20, 25, 14]
    for i, L in enumerate(lens):
        a = math.pi * (0.17 + 0.66 * i / 6)
        L2 = L + 3 * math.sin(ph + i)
        for r in range(32, int(32 + L2)):
            t = (r - 32) / max(1, L2)
            x, y = 240 + math.cos(a) * r, HY - math.sin(a) * r
            d.ellipse([x - 3, y - 3, x + 3, y + 3], fill=lerp(INK, AMBER, t))
    # horizon bar
    d.rounded_rectangle([200, HY - 4, 280, HY + 4], radius=3, fill=INK)
    # reflection: rows of key-shaped dashes that ripple
    rows = [(4, 18, HY + 22, 0.85), (3, 16, HY + 40, 0.65), (2, 14, HY + 58, 0.5), (5, 10, HY + 76, 0.3)]
    for ri, (n, w, y, a) in enumerate(rows):
        gap = 4; total = n * w + (n - 1) * gap
        for i in range(n):
            x0 = 240 - total / 2 + i * (w + gap) + 2 * math.sin(ph + ri + i)
            dy = 1.5 * math.sin(ph * 2 + i * 1.6 + ri)
            c = lerp((0x18, 0x16, 0x2A), (255, 214, 160), a)
            d.rounded_rectangle([x0, y + dy - 3, x0 + w, y + dy + 3], radius=2, fill=c)
    # glints on the water
    for k in range(18):
        gx = (k * 53 + f * (1 + k % 3)) % W; gy = HY + 8 + (k * 37) % (H - HY - 10)
        if math.sin(ph * 3 + k) > 0.5: d.line([(gx, gy), (gx + 3, gy)], fill=(160, 110, 120))
    # boat silhouette drifting across
    bx = int(-40 + (f / N) * 0) + 360
    d.polygon([(bx, HY + 6), (bx + 26, HY + 6), (bx + 22, HY + 10), (bx + 4, HY + 10)], fill=(12, 10, 20))
    d.line([(bx + 12, HY + 6), (bx + 12, HY - 14)], fill=(12, 10, 20)); d.polygon([(bx + 13, HY - 13), (bx + 13, HY + 4), (bx + 24, HY + 4)], fill=(12, 10, 20))
    return im

frames = [frame(f) for f in range(N)]
pal = frames[0].quantize(colors=64, method=Image.Quantize.MEDIANCUT)
q = [fr.quantize(palette=pal, dither=Image.Dither.NONE) for fr in frames]
q[0].save(sys.argv[1], save_all=True, append_images=q[1:], duration=int(1000 / FPS), loop=0, disposal=1)
