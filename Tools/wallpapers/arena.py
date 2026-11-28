# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
# Original pixel-art loop: indoor arena at tip-off. Generic colours, no logos, teams or real people.
# Usage: python3 arena.py <out.gif>
import math, random, sys
from PIL import Image, ImageDraw

W, H, FPS, N = 480, 270, 12, 48
random.seed(11)
WOOD = [(214, 158, 96), (200, 144, 84), (222, 168, 104)]
LINE = (250, 248, 240)
PAINT = (36, 72, 160)
ACCENT = (250, 196, 40)

crowd = [(x, y, random.choice([(60, 52, 80), (90, 70, 110), (120, 60, 70), (50, 80, 120), (150, 120, 90)]), random.random() * 6.28)
         for y in range(52, 118, 5) for x in range(0, W, 4)]
flashes = [(random.randrange(W), random.randrange(56, 116), random.randrange(N)) for _ in range(30)]

def frame(f):
    im = Image.new("RGB", (W, H), (14, 12, 24)); d = ImageDraw.Draw(im)
    # rafters and spotlights
    for k in range(6):
        cx = 40 + k * 80 + int(math.sin(f / N * 6.28 + k) * 6)
        d.polygon([(cx - 3, 0), (cx + 3, 0), (cx + 22, 50), (cx - 22, 50)], fill=(30, 28, 48))
    # jumbotron: scoreboard with a clock that counts down across the loop
    d.rectangle([180, 6, 300, 44], fill=(20, 20, 30), outline=(80, 80, 96))
    d.rectangle([186, 11, 294, 39], fill=(8, 8, 14))
    secs = 24 - (f * 24 // N)
    for i, ch in enumerate(f"{secs:02d}"):
        draw_digit(d, 222 + i * 20, 15, int(ch), (255, 80, 60))
    d.rectangle([190, 15, 204, 35], fill=PAINT); d.rectangle([276, 15, 290, 35], fill=ACCENT)
    # crowd: rows of 3x4 heads that bob, plus camera flashes
    for x, y, c, ph in crowd:
        dy = 1 if math.sin(ph + f / N * 6.28 * 2) > 0.6 else 0
        d.rectangle([x, y - dy, x + 2, y + 3 - dy], fill=c)
    for fx, fy, ff in flashes:
        if f % N == ff or (f + 1) % N == ff: d.rectangle([fx - 1, fy - 1, fx + 1, fy + 1], fill=(255, 255, 255))
    # LED ad board ribbon, scrolling stripes
    d.rectangle([0, 118, W, 128], fill=(12, 12, 20))
    for sx in range(-40, W + 40, 40):
        x0 = sx + (f * 5) % 40
        d.rectangle([x0, 120, x0 + 18, 126], fill=PAINT); d.rectangle([x0 + 20, 120, x0 + 38, 126], fill=ACCENT)
    # hardwood floor with planks
    for y in range(128, H):
        d.line([(0, y), (W, y)], fill=WOOD[(y // 3) % 3])
    for y in range(130, H, 9):
        off = (y * 37) % 60
        for x in range(-off, W, 60): d.line([(x, y), (x, y + 8)], fill=(184, 130, 76))
    # spotlight pools that sweep slowly
    pool = Image.new("RGBA", (W, H), (0, 0, 0, 0)); pd = ImageDraw.Draw(pool)
    for k in range(2):
        cx = 240 + int(math.sin(f / N * 6.28 + k * 3.14) * 140)
        pd.ellipse([cx - 60, 170, cx + 60, 230], fill=(255, 250, 230, 40))
    im = Image.alpha_composite(im.convert("RGBA"), pool).convert("RGB"); d = ImageDraw.Draw(im)
    # court markings, side-on perspective: half-court line, centre circle, both keys and arcs
    d.line([(0, 136), (W, 136)], fill=LINE, width=2)
    d.line([(240, 136), (240, H)], fill=LINE, width=2)
    d.ellipse([200, 176, 280, 236], outline=LINE, width=2); d.ellipse([224, 194, 256, 218], fill=PAINT, outline=LINE)
    for side in (0, 1):
        x0, x1 = (0, 70) if side == 0 else (410, 480)
        d.rectangle([x0, 168, x1, 244], fill=PAINT, outline=LINE, width=2)
        arc = [-110, 140, 160, 272] if side == 0 else [320, 140, 590, 272]
        d.arc(arc, -80 if side == 0 else 100, 80 if side == 0 else 260, fill=LINE, width=2)
    d.rectangle([0, 262, W, H], fill=PAINT); d.line([(0, 262), (W, 262)], fill=ACCENT, width=2)
    # ball at centre: tip-off toss, rising and falling over the loop
    t = (f % N) / N
    by = 200 - int(math.sin(t * math.pi) * 120)
    d.ellipse([234, 210, 246, 213], fill=(150, 100, 60))
    d.ellipse([234, by - 6, 246, by + 6], fill=(232, 112, 40), outline=(60, 28, 16))
    d.line([(234, by), (246, by)], fill=(60, 28, 16)); d.line([(240, by - 6), (240, by + 6)], fill=(60, 28, 16))
    return im

SEG = {0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc", 5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abcdfg"}
def draw_digit(d, x, y, n, c):
    w, h, t = 14, 20, 3
    segs = {"a": (x, y, x + w, y + t), "b": (x + w - t, y, x + w, y + h // 2), "c": (x + w - t, y + h // 2, x + w, y + h),
            "d": (x, y + h - t, x + w, y + h), "e": (x, y + h // 2, x + t, y + h), "f": (x, y, x + t, y + h // 2),
            "g": (x, y + h // 2 - 1, x + w, y + h // 2 + 1)}
    for s in SEG[n]: d.rectangle(segs[s], fill=c)

frames = [frame(f) for f in range(N)]
pal = frames[0].quantize(colors=64, method=Image.Quantize.MEDIANCUT)
q = [fr.quantize(palette=pal, dither=Image.Dither.NONE) for fr in frames]
q[0].save(sys.argv[1], save_all=True, append_images=q[1:], duration=int(1000 / FPS), loop=0, disposal=1)
