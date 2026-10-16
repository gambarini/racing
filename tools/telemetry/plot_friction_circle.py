#!/usr/bin/env python3
"""Plot Fx vs Fy per wheel from a telemetry CSV (#15). Usage: plot_friction_circle.py in.csv out.png"""
import argparse
import csv


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("csv")
    ap.add_argument("png")
    args = ap.parse_args()
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    with open(args.csv, newline="") as f:
        rows = list(csv.DictReader(f))
    fig, axes = plt.subplots(2, 2, figsize=(8, 8), sharex=True, sharey=True)
    for ax, w in zip(axes.flat, ["fl", "fr", "rl", "rr"]):
        pts = [(float(r[w + "_fy"]), float(r[w + "_fx"]))
               for r in rows if r[w + "_fx"] != "" and r[w + "_fy"] != ""]
        # Channels not yet modelled are empty in the CSV (Fy until the lateral tire model lands).
        ax.scatter([p[0] for p in pts], [p[1] for p in pts], s=2)
        ax.set_title(w.upper() + ("" if pts else " (no Fx/Fy data)"))
        ax.set_xlabel("Fy [N]")
        ax.set_ylabel("Fx [N]")
        ax.grid(True)
    fig.tight_layout()
    fig.savefig(args.png, dpi=120)


if __name__ == "__main__":
    main()
