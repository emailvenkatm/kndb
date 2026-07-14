#!/usr/bin/env python3
"""
Quick per-cell view of the Stage 2 raw JSON files.
Usage: quick_view.py <raw_dir> [--sort-by tps|correctness|goodput]
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_dir")
    ap.add_argument("--sort-by", default="path",
                    choices=["path", "system", "tps", "correctness", "goodput"])
    args = ap.parse_args()

    rows = []
    for p in sorted(glob.glob(os.path.join(args.raw_dir, "*.json"))):
        try:
            with open(p) as f:
                d = json.load(f)
        except Exception as e:
            print(f"SKIP {p}: {e}", file=sys.stderr)
            continue
        m = d.get("metrics", {})
        c = d.get("correctness", {})
        rows.append({
            "path": os.path.basename(p),
            "system": d.get("system"),
            "mix": d.get("kind_mix"),
            "theta": d.get("zipfian_theta"),
            "clients": d.get("clients"),
            "tps": m.get("throughput_txn_per_s", 0),
            "abort_rate": m.get("abort_rate", 0),
            "correctness": c.get("correctness_rate", 0),
            "goodput": d.get("goodput_txn_per_s", 0),
            "contested": c.get("contested_slots", 0),
            "n_dup": c.get("multiple_live_rows", 0),
            "n_miss": c.get("missing_live_rows", 0),
            "p99_ms": m.get("latency_ms", {}).get("p99", float("nan")),
        })

    if args.sort_by == "tps":
        rows.sort(key=lambda r: -r["tps"])
    elif args.sort_by == "correctness":
        rows.sort(key=lambda r: -r["correctness"])
    elif args.sort_by == "goodput":
        rows.sort(key=lambda r: -r["goodput"])
    elif args.sort_by == "system":
        rows.sort(key=lambda r: (r["system"] or "", r["mix"] or "",
                                 float(r["theta"] or 0), int(r["clients"] or 0)))

    print(f"{'system':<10} {'mix':<12} {'theta':>5} {'c':>3} "
          f"{'tps':>8} {'abort':>6} {'corr':>6} {'goodput':>8} "
          f"{'contested':>9} {'dup':>5} {'miss':>5} {'p99ms':>7}")
    for r in rows:
        print(f"{r['system'] or '?':<10} {r['mix'] or '?':<12} "
              f"{float(r['theta'] or 0):>5.2f} {int(r['clients'] or 0):>3d} "
              f"{r['tps']:>8.1f} {r['abort_rate']:>6.3f} "
              f"{r['correctness']:>6.3f} {r['goodput']:>8.1f} "
              f"{r['contested']:>9} {r['n_dup']:>5} {r['n_miss']:>5} "
              f"{r['p99_ms']:>7.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
