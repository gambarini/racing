#!/usr/bin/env python3
"""Procedural placeholder tire/surface audio (#21). Pure stdlib (wave, math, random): licence-free.

Writes project/audio/surfaces/<id>_roll.wav (loop), <id>_slip.wav (loop), <id>_impact.wav.
Loops are seamless: grains wrap around the buffer, filters run two circular passes, and tones/AM
use whole cycles per loop. Deterministic (fixed seeds).
Usage: python3 tools/audio/gen_surface_sounds.py
Final samples replace the wavs (same names) or the streams in project/audio/profiles/*.tres.
"""
import math
import os
import random
import struct
import wave

SR = 22050
LOOP_S = 1.0
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "project", "audio", "surfaces")

# id -> (roll params, slip params, impact params)
# density: grains/s, lp/hp: filter cutoffs Hz, decay: grain decay s, am: (cycles per loop, depth),
# tone: (Hz, level) squeal, wobble: slow pitch wobble cycles per loop, gain: peak
SURF = {
    "tarmac": (
        dict(density=4000, lp=700, decay=0.0005, hp=60, am=(0, 0), gain=0.5),
        dict(density=300, lp=3000, decay=0.001, hp=200, tone=(880, 0.5), wobble=6, gain=0.6),
        dict(kind="thud", freq=90, decay=0.12, gain=0.8)),
    "tarmac_wet": (
        dict(density=9000, lp=5000, decay=0.0003, hp=1500, am=(0, 0), gain=0.45),
        dict(density=1500, lp=5000, decay=0.001, hp=800, tone=(620, 0.25), wobble=5, gain=0.5),
        dict(kind="splash", freq=120, decay=0.15, gain=0.7)),
    "gravel": (
        dict(density=900, lp=3500, decay=0.0012, hp=400, am=(0, 0), gain=0.9),
        dict(density=1800, lp=4500, decay=0.0015, hp=300, am=(7, 0.3), gain=1.0),
        dict(kind="crunch", freq=140, decay=0.2, gain=0.9)),
    "dirt": (
        dict(density=500, lp=1400, decay=0.002, hp=150, am=(0, 0), gain=0.75),
        dict(density=900, lp=2200, decay=0.002, hp=150, am=(5, 0.3), gain=0.9),
        dict(kind="thud", freq=70, decay=0.18, gain=0.8)),
    "grass": (
        dict(density=1500, lp=1100, decay=0.003, hp=300, am=(3, 0.25), gain=0.4),
        dict(density=2500, lp=1800, decay=0.003, hp=300, am=(4, 0.4), gain=0.6),
        dict(kind="thud", freq=55, decay=0.1, gain=0.5)),
    "mud": (
        dict(density=160, lp=350, decay=0.012, hp=40, am=(4, 0.5), gain=1.0),
        dict(density=260, lp=600, decay=0.014, hp=40, am=(6, 0.6), gain=1.0),
        dict(kind="squelch", freq=60, decay=0.25, gain=0.9)),
    "deep_mud": (
        dict(density=70, lp=200, decay=0.03, hp=30, am=(2, 0.6), gain=1.0),
        dict(density=110, lp=320, decay=0.03, hp=30, am=(3, 0.7), gain=1.0),
        dict(kind="squelch", freq=45, decay=0.4, gain=1.0)),
}


def one_pole_lp(x, fc):
    a = 1.0 - math.exp(-2 * math.pi * fc / SR)
    y = [0.0] * len(x)
    s = 0.0
    for _ in range(2):  # two circular passes, keep the second
        for i, v in enumerate(x):
            s += a * (v - s)
            y[i] = s
    return y


def highpass(x, fc):
    lo = one_pole_lp(x, fc)
    return [v - lo_v for v, lo_v in zip(x, lo)]


def normalise(x, peak):
    m = max(abs(v) for v in x) or 1.0
    return [v / m * peak * 0.8 for v in x]


def loop_buf(p, seed):
    rng = random.Random(seed)
    n = int(SR * LOOP_S)
    x = [0.0] * n
    tail = max(1, int(p["decay"] * SR * 5))
    for _ in range(int(p["density"] * LOOP_S)):
        pos = rng.randrange(n)
        amp = rng.uniform(0.3, 1.0) * rng.choice((-1, 1))
        for k in range(tail):  # decaying grain, wraps around the loop end
            x[(pos + k) % n] += amp * math.exp(-k / (p["decay"] * SR))
    x = normalise(highpass(one_pole_lp(x, p["lp"]), p["hp"]), 1.0)
    if "tone" in p:
        f, lvl = p["tone"]
        cyc = p["wobble"]
        for i in range(n):
            t = i / n
            ph = 2 * math.pi * round(f * LOOP_S) * t + 0.8 * math.sin(2 * math.pi * cyc * t)
            x[i] += lvl * (math.sin(ph) + 0.4 * math.sin(2 * ph) + 0.2 * math.sin(3 * ph))
    cyc, depth = p.get("am", (0, 0))
    if cyc:
        for i in range(n):
            x[i] *= 1.0 - depth + depth * (0.5 + 0.5 * math.sin(2 * math.pi * cyc * i / n))
    return normalise(x, p["gain"])


def impact_buf(p, seed):
    rng = random.Random(seed)
    n = int(SR * 0.4)
    kind, f, dec = p["kind"], p["freq"], p["decay"]
    x = []
    ph = 0.0
    for i in range(n):
        t = i / SR
        ph += 2 * math.pi * (f * (1.0 + 1.5 * math.exp(-t / 0.03))) / SR  # pitch-drop thump
        v = math.sin(ph) * math.exp(-t / dec)
        if kind in ("crunch", "splash", "squelch"):
            v += rng.uniform(-1, 1) * math.exp(-t / (dec * 0.4)) * 0.5
        x.append(v)
    if kind == "crunch":
        x = highpass(x, 300)
    if kind == "squelch":
        x = one_pole_lp(x, 500)
    for i in range(64):  # fade-in avoids a click on the first sample
        x[i] *= i / 64
    return normalise(x, p["gain"])


def write(name, x):
    path = os.path.normpath(os.path.join(OUT, name))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in x))
    print("wrote", path)


def main():
    os.makedirs(OUT, exist_ok=True)
    for i, (sid, (roll, slip, imp)) in enumerate(SURF.items()):
        write(f"{sid}_roll.wav", loop_buf(roll, 100 + i))
        write(f"{sid}_slip.wav", loop_buf(slip, 200 + i))
        write(f"{sid}_impact.wav", impact_buf(imp, 300 + i))


if __name__ == "__main__":
    main()
