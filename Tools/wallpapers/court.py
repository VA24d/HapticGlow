# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
# Original pixel-art loop: outdoor basketball court at dusk. No logos, teams or real people.
# Usage: python3 court.py <out.gif>
import math, random, sys
from PIL import Image, ImageDraw

W, H, FPS, N = 480, 270, 12, 48
random.seed(7)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

SKY = [(0, (24, 20, 52)), (0.45, (74, 42, 92)), (0.75, (196, 92, 88)), (1.0, (252, 168, 92))]
def sky(y):
    t = y / 150
    for (a, ca), (b, cb) in zip(SKY, SKY[1:]):
        if a <= t <= b: return lerp(ca, cb, (t - a) / (b - a))
    return SKY[-1][1]

stars = [(random.randrange(W), random.randrange(70), random.random() * 6.28) for _ in range(40)]
buildings = []
x = 0
while x < W:
    w = random.randint(18, 44); h = random.randint(30, 85)
    buildings.append((x, 150 - h, w, h, [(random.random() < 0.45, random.random() * 6.28) for _ in range((w // 6) * (h // 7))]))
    x += w + random.randint(0, 3)

HOOP_X, RIM_Y = 360, 118
def ball_pos(f):
    # 48-frame loop: dribble (0-15), shot arc (16-35), swish and bounce (36-47)
    if f < 16:
        bx = 140 + f * 2; by = 214 - abs(math.sin(f / 16 * math.pi * 2)) * 26
    elif f < 36:
        t = (f - 16) / 20
        x0, y0, x1, y1 = 172, 188, HOOP_X, RIM_Y - 4
        bx = x0 + (x1 - x0) * t; by = y0 + (y1 - y0) * t - math.sin(t * math.pi) * 95
    else:
        t = (f - 36) / 12
        bx = HOOP_X + 2; by = RIM_Y + t * 100
        if by > 214: by = 214 - (by - 214) * 0.4
    return int(bx), int(by)

def frame(f):
    im = Image.new("RGB", (W, H)); d = ImageDraw.Draw(im)
    for y in range(150): d.line([(0, y), (W, y)], fill=sky(y))
    d.ellipse([200, 128, 280, 208], fill=(255, 196, 120)); d.rectangle([0, 150, W, H], fill=(40, 30, 54))
    for sx, sy, ph in stars:
        if math.sin(ph + f / N * 6.28 * 2) > -0.2: d.point((sx, sy), fill=(255, 240, 220))
    for bx, by, bw, bh, wins in buildings:
        d.rectangle([bx, by, bx + bw, 150], fill=(30, 22, 46))
        i = 0
        for wy in range(by + 4, 146, 7):
            for wx in range(bx + 3, bx + bw - 3, 6):
                if i < len(wins):
                    lit, ph = wins[i]
                    if lit and math.sin(ph + f / N * 6.28) > -0.85: d.rectangle([wx, wy, wx + 2, wy + 3], fill=(255, 206, 120))
                i += 1
    for fx in range(0, W, 6):
        d.line([(fx, 132), (fx + 18, 150)], fill=(70, 60, 86)); d.line([(fx + 18, 132), (fx, 150)], fill=(70, 60, 86))
    d.line([(0, 132), (W, 132)], fill=(96, 84, 110))
    d.polygon([(0, 270), (W, 270), (W, 160), (0, 160)], fill=(46, 64, 108))
    d.polygon([(40, 270), (440, 270), (410, 168), (70, 168)], fill=(198, 96, 56))
    line = (240, 236, 226)
    d.line([(70, 168), (410, 168)], fill=line, width=2); d.line([(40, 270), (70, 168)], fill=line, width=2); d.line([(440, 270), (410, 168)], fill=line, width=2)
    d.polygon([(300, 172), (400, 172), (420, 230), (310, 230)], outline=line)
    d.arc([272, 170, 496, 262], 90, 270, fill=line, width=2)
    cone = Image.new("RGBA", (W, H), (0, 0, 0, 0)); cd = ImageDraw.Draw(cone)
    cd.polygon([(96, 60), (40, 270), (170, 270)], fill=(255, 220, 160, 34))
    im = Image.alpha_composite(im.convert("RGBA"), cone).convert("RGB"); d = ImageDraw.Draw(im)
    d.rectangle([94, 58, 98, 230], fill=(24, 20, 34)); d.rectangle([90, 56, 104, 60], fill=(255, 236, 190))
    d.rectangle([392, 96, 397, 232], fill=(24, 20, 34))
    d.rectangle([346, 88, 396, 116], fill=(232, 232, 236), outline=(30, 26, 40)); d.rectangle([362, 100, 380, 112], outline=(214, 64, 52))
    sway = int(round(math.sin((f - 36) * 1.2) * 2)) if f >= 36 else 0
    for k in range(5):
        x0 = HOOP_X - 9 + k * 4
        d.line([(x0, RIM_Y + 1), (x0 - (k - 2) + sway, RIM_Y + 14)], fill=(244, 244, 244))
    d.line([(HOOP_X - 10, RIM_Y), (HOOP_X + 10, RIM_Y)], fill=(234, 94, 40), width=2)
    bx, by = ball_pos(f)
    d.ellipse([bx - 6, 222, bx + 6, 225], fill=(150, 70, 44))
    d.ellipse([bx - 5, by - 5, bx + 5, by + 5], fill=(232, 112, 40), outline=(60, 28, 16))
    d.line([(bx - 5, by), (bx + 5, by)], fill=(60, 28, 16)); d.line([(bx, by - 5), (bx, by + 5)], fill=(60, 28, 16))
    return im

frames = [frame(f) for f in range(N)]
pal = frames[0].quantize(colors=48, method=Image.Quantize.MEDIANCUT)
q = [fr.quantize(palette=pal, dither=Image.Dither.NONE) for fr in frames]
q[0].save(sys.argv[1], save_all=True, append_images=q[1:], duration=int(1000 / FPS), loop=0, disposal=1)
