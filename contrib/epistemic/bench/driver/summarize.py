#!/usr/bin/env python3
"""
Roll up bench/results/raw/*.json into CSV per scope.

Usage:
    ./summarize.py --raw ../results/raw --out ../results/summary --scope primary
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
from typing import Dict, List, Any, Tuple


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


CELL_KEY = ("system", "workload", "isolation", "zipfian_theta", "clients")


def cell_key(row: Dict[str, Any]) -> Tuple[Any, ...]:
    return tuple(row[k] for k in CELL_KEY)


def group_cells(rows: List[Dict[str, Any]]) -> Dict[Tuple[Any, ...], List[Dict[str, Any]]]:
    g: Dict[Tuple[Any, ...], List[Dict[str, Any]]] = defaultdict(list)
    for r in rows:
        g[cell_key(r)].append(r)
    return g


def median(xs: List[float]) -> float:
    return statistics.median(xs) if xs else float("nan")


def std(xs: List[float]) -> float:
    if len(xs) < 2:
        return 0.0
    return statistics.stdev(xs)


def write_csv(out_path: str, cells: Dict[Tuple[Any, ...], List[Dict[str, Any]]]) -> int:
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "system", "workload", "isolation", "theta", "clients", "runs",
            "tps_median", "tps_std",
            "abort_rate_median",
            "p50_ms_median", "p95_ms_median", "p99_ms_median",
            "p99_9_ms_median", "mean_ms_median",
            "commits_total", "aborts_total",
            "abort_40001_total", "abort_new_loses_total",
            "abort_check_violation_total", "abort_other_total",
        ])
        n = 0
        for key in sorted(cells.keys()):
            group = cells[key]
            tps    = [g["metrics"]["throughput_txn_per_s"] for g in group]
            abr    = [g["metrics"]["abort_rate"] for g in group]
            p50    = [g["metrics"]["latency_ms"]["p50"] for g in group]
            p95    = [g["metrics"]["latency_ms"]["p95"] for g in group]
            p99    = [g["metrics"]["latency_ms"]["p99"] for g in group]
            p999   = [g["metrics"]["latency_ms"]["p99_9"] for g in group]
            mean   = [g["metrics"]["latency_ms"]["mean"] for g in group]
            commits = sum(g["metrics"].get("committed_txns", 0) for g in group)
            aborts  = sum(g["metrics"].get("aborted_txns", 0) for g in group)
            b40001  = sum(g["metrics"]["abort_breakdown"]["40001"] for g in group)
            bnew    = sum(g["metrics"]["abort_breakdown"]["NEW_LOSES"] for g in group)
            bcv     = sum(g["metrics"]["abort_breakdown"]["check_violation"] for g in group)
            both    = sum(g["metrics"]["abort_breakdown"]["other"] for g in group)

            w.writerow([
                key[0], key[1], key[2], key[3], key[4], len(group),
                f"{median(tps):.2f}", f"{std(tps):.2f}",
                f"{median(abr):.4f}",
                f"{median(p50):.3f}", f"{median(p95):.3f}",
                f"{median(p99):.3f}", f"{median(p999):.3f}",
                f"{median(mean):.3f}",
                commits, aborts,
                b40001, bnew, bcv, both,
            ])
            n += 1
    return n


def filter_scope(rows: List[Dict[str, Any]], scope: str) -> List[Dict[str, Any]]:
    if scope == "primary":
        return [r for r in rows
                if r["workload"] == "ycsb_a" and r["isolation"] == "RC"
                and r["clients"] in {1, 2, 4, 8, 16, 32, 64}
                and r["zipfian_theta"] in {0.0, 0.5, 0.6, 0.8, 0.9, 0.99}]
    if scope == "secondary_b":
        return [r for r in rows if r["workload"] == "ycsb_b"]
    if scope == "secondary_sr":
        return [r for r in rows
                if r["workload"] == "ycsb_a" and r["isolation"] == "SR"]
    if scope == "gate":
        # gate cells are the ones we ran under run_gate — theta ∈
        # {0,0.5,0.9,0.99} pg_heap 8c AND theta ∈ {0,0.5} epistemic 8c.
        return [r for r in rows
                if r["workload"] == "ycsb_a" and r["isolation"] == "RC"
                and r["clients"] == 8
                and (
                    (r["system"] == "pg_heap"
                     and r["zipfian_theta"] in {0.0, 0.5, 0.9, 0.99})
                    or (r["system"] == "epistemic"
                        and r["zipfian_theta"] in {0.0, 0.5})
                )]
    if scope == "all":
        return rows
    raise ValueError(f"unknown scope {scope}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scope",
                    choices=["primary", "secondary_b", "secondary_sr",
                             "gate", "all"],
                    default="all")
    args = ap.parse_args()

    all_rows = load(args.raw)
    scoped = filter_scope(all_rows, args.scope)
    if not scoped:
        print(f"no rows in scope {args.scope}", file=sys.stderr)

    cells = group_cells(scoped)
    os.makedirs(args.out, exist_ok=True)

    fname = {
        "primary": "ycsb_a_rc.csv",
        "secondary_b": "ycsb_b_rc.csv",
        "secondary_sr": "ycsb_a_sr.csv",
        "gate": "gate.csv",
        "all": "all.csv",
    }[args.scope]

    out_path = os.path.join(args.out, fname)
    n = write_csv(out_path, cells)
    print(f"wrote {n} cells to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
