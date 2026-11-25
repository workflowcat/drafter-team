#!/usr/bin/env python3
"""Side-by-side sheet: concept next to build, same height, a small label over each.

  python3 scripts/look-sheet.py <out.png> <label>=<image.png> [<label>=<image.png> ...] [--h 900]
"""
import sys
from PIL import Image, ImageDraw, ImageFont

args = [a for a in sys.argv[2:] if not a.startswith("--")]
h = int(sys.argv[sys.argv.index("--h") + 1]) if "--h" in sys.argv else 900
args = [a for a in args if not a.isdigit()]
tiles = []
for a in args:
    label, path = a.split("=", 1)
    im = Image.open(path).convert("RGB")
    im = im.resize((round(im.width * h / im.height), h), Image.LANCZOS)
    tiles.append((label, im))
pad, top = 24, 44
W = sum(t.width for _, t in tiles) + pad * (len(tiles) + 1)
sheet = Image.new("RGB", (W, h + top + pad), (128, 128, 128))
d = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
except OSError:
    font = ImageFont.load_default()
x = pad
for label, im in tiles:
    d.text((x, 12), label, fill=(255, 255, 255), font=font)
    sheet.paste(im, (x, top))
    x += im.width + pad
sheet.save(sys.argv[1])
print(sys.argv[1], sheet.size)
