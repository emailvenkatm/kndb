#!/usr/bin/env python3
"""
Roll up bench/results/stage2_raw/*.json into per-scope CSVs.

Produces:
  * correctness.csv — per-cell (system, mix, theta, clients) with
                      throughput, abort rate, correctness rate,
                      goodput, contested-slot count, latency p50/p99,
                      integrity violations.
  * disable_test.csv — the disable-and-test transcript cells.
  * control.csv     — throughput/latency-only control cells.

Cells are keyed by (system, kind_mix, theta, clients, run_index).
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import statistics
import sys
from collections import defaultdict
from typing import Any, Dict, List, Tuple


CELL_KEY = ("system", "kind_mix", "zipfian_theta", "clients")


def load(raw_dir: str) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for path in sorted(glob.glob(os.path.join(raw_dir, "*.json"))):
        try:
            with open(path) as f:
                d = json.load(f)
            d["_path"] = path
            rows.append(d)
        except Exception as e:
            print(f"WARN: could not read {path}: {e}", file=sys.stderr)
    return rows


def cell_key(row: Dict[str, Any]) -> Tuple[Any, ...]:
    return tuple(row.get(k) for k in CELL_KEY)


def median(xs: List[float]) -> float:
    return statistics.median(xs) if xs else float("nan")


def std(xs: List[float]) -> float:
    if len(xs) < 2:
        return 0.0
    return statistics.stdev(xs)


def _emit_row(w, key, group):
    tps = [g["metrics"]["throughput_txn_per_s"] for g in group]
    ab = [g["metrics"]["abort_rate"] for g in group]
    cr = [g["correctness"]["correctness_rate"] for g in group]
    gp = [g.get("goodput_txn_per_s", 0.0) for g in group]
    p50 = [g["metrics"]["latency_ms"]["p50"] for g in group]
    p99 = [g["metrics"]["latency_ms"]["p99"] for g in group]
    p999 = [g["metrics"]["latency_ms"]["p99_9"] for g in group]
    contested = [g["correctness"]["contested_slots"] for g in group]
    missing = [g["correctness"]["missing_live_rows"] for g in group]
    multi = [g["correctness"]["multiple_live_rows"] for g in group]

    w.writerow([
        key[0], key[1], key[2], key[3],
        len(group),
        f"{median(tps):.2f}", f"{std(tps):.2f}",
        f"{median(ab):.4f}",
        f"{median(cr):.4f}",
        f"{median(gp):.2f}",
        f"{median(p50):.3f}", f"{median(p99):.3f}", f"{median(p999):.3f}",
        int(median(contested)),
        int(median(missing)), int(median(multi)),
    ])


def write_csv(out_path: str, rows: List[Dict[str, Any]]) -> int:
    groups: Dict[Tuple[Any, ...], List[Dict[str, Any]]] = defaultdict(list)
    for r in rows:
        groups[cell_key(r)].append(r)
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "system", "kind_mix", "theta", "clients", "runs",
            "tps_median", "tps_std",
            "abort_rate_median",
            "correctness_median",
            "goodput_median",
            "p50_ms_median", "p99_ms_median", "p99_9_ms_median",
            "contested_median",
            "missing_live_median", "multi_live_median",
        ])
        for key in sorted(groups.keys(), key=str):
            _emit_row(w, key, groups[key])
    return len(groups)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    all_rows = load(args.raw)
    if not all_rows:
        print("no Stage 2 raw rows found; nothing to summarise",
              file=sys.stderr)
        return 0

    # Split into three scopes by run_index convention:
    #   run_index=0  -> correctness grid
    #   run_index=1  -> disable-and-test reference
    #   run_index=2  -> disable-and-test disabled cell
    #   run_index=3  -> control grid
    correctness_rows = [r for r in all_rows if r.get("run_index") == 0]
    disable_rows = [r for r in all_rows if r.get("run_index") in (1, 2)]
    control_rows = [r for r in all_rows if r.get("run_index") == 3]

    os.makedirs(args.out, exist_ok=True)
    n1 = write_csv(os.path.join(args.out, "stage2_correctness.csv"),
                   correctness_rows) if correctness_rows else 0
    n2 = write_csv(os.path.join(args.out, "stage2_disable_test.csv"),
                   disable_rows) if disable_rows else 0
    n3 = write_csv(os.path.join(args.out, "stage2_control.csv"),
                   control_rows) if control_rows else 0
    print(f"wrote {n1} correctness cells, {n2} disable-test cells, "
          f"{n3} control cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
