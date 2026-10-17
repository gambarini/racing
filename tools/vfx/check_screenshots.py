#!/usr/bin/env python3
"""Image checks for the 5 per-surface VFX screenshots (#128): size >= 640x360, not identical,
and the fixed crop behind the car differs in mean colour by > 8/255 in at least one channel
between any two surfaces. Usage: check_screenshots.py [dir]  (default docs/vfx)"""
import itertools, os, sys
from PIL import Image, ImageStat

d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../../docs/vfx")
ids = ["tarmac", "dirt", "gravel", "mud", "grass"]
CROP = (0.18, 0.72, 0.82, 1.0)  # fractions of w/h: the region behind the car
imgs, means, ok = {}, {}, True
for i in ids:
    im = Image.open(os.path.join(d, i + ".png")).convert("RGB")
    imgs[i] = im
    if im.width < 640 or im.height < 360:
        print("FAIL size", i, im.size); ok = False
    w, h = im.size
    means[i] = ImageStat.Stat(im.crop((int(CROP[0]*w), int(CROP[1]*h), int(CROP[2]*w), int(CROP[3]*h)))).mean
    print(i, im.size, "crop mean", [round(m, 1) for m in means[i]])
for a, b in itertools.combinations(ids, 2):
    if imgs[a].tobytes() == imgs[b].tobytes():
        print("FAIL identical", a, b); ok = False
    dm = max(abs(x - y) for x, y in zip(means[a], means[b]))
    print(f"{a} vs {b}: max channel diff {dm:.1f}", "" if dm > 8 else "FAIL")
    ok &= dm > 8
print("RESULT:", "OK" if ok else "FAILED")
sys.exit(0 if ok else 1)
