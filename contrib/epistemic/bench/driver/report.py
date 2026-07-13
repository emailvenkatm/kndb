#!/usr/bin/env python3
"""
report.py — print the gate + primary grid as human-readable tables.

Usage:
    report.py --raw ../results/raw

Emits markdown tables that go straight into bench/results/summary/README.md
or the F9 report.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
from collections import defaultdict
from typing import Any, Dict, List, Tuple


def load(raw_dir: str) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for p in sorted(glob.glob(os.path.join(raw_dir, "*.json"))):
        with open(p) as f:
            d = json.load(f)
        d["_path"] = p
        rows.append(d)
    return rows


def med(xs: List[float]) -> float:
    return statistics.median(xs) if xs else float("nan")


def std(xs: List[float]) -> float:
    return statistics.stdev(xs) if len(xs) > 1 else 0.0


def collate(rows: List[Dict[str, Any]]) -> Dict[Tuple[Any, ...], List[Dict[str, Any]]]:
    g: Dict[Tuple[Any, ...], List[Dict[str, Any]]] = defaultdict(list)
    for r in rows:
        key = (r["system"], r["workload"], r["isolation"],
               r["zipfian_theta"], r["clients"])
        g[key].append(r)
    return g


def print_gate(rows: List[Dict[str, Any]]) -> None:
    scoped = [r for r in rows
              if r["workload"] == "ycsb_a" and r["isolation"] == "RC"
              and r["clients"] == 8
              and (
                  (r["system"] == "pg_heap"
                   and r["zipfian_theta"] in {0.0, 0.5, 0.9, 0.99})
                  or (r["system"] == "epistemic"
                      and r["zipfian_theta"] in {0.0, 0.5})
              )]
    cells = collate(scoped)

    print("### Gate 1 — pg_heap contention curve (8 clients, 3 runs)")
    print()
    print("| theta | tps median | tps std | abort rate | p50 (ms) | p99 (ms) | p99.9 (ms) |")
    print("|------:|-----------:|--------:|-----------:|---------:|---------:|-----------:|")
    for th in [0.0, 0.5, 0.9, 0.99]:
        k = ("pg_heap", "ycsb_a", "RC", th, 8)
        g = cells.get(k, [])
        if not g:
            print(f"| {th:.2f} | -- | -- | -- | -- | -- | -- |")
            continue
        tps = [x["metrics"]["throughput_txn_per_s"] for x in g]
        ab  = [x["metrics"]["abort_rate"] for x in g]
        p50 = [x["metrics"]["latency_ms"]["p50"] for x in g]
        p99 = [x["metrics"]["latency_ms"]["p99"] for x in g]
        p999 = [x["metrics"]["latency_ms"]["p99_9"] for x in g]
        print(f"| {th:.2f} | {med(tps):.0f} | {std(tps):.0f} | {med(ab):.3f}"
              f" | {med(p50):.2f} | {med(p99):.2f} | {med(p999):.2f} |")

    print()
    print("### Gate 2 — epistemic vs pg_heap overhead (8 clients, 3 runs)")
    print()
    print("| theta | system    | tps median | tps std | abort rate | p50 (ms) | p99 (ms) | overhead |")
    print("|------:|-----------|-----------:|--------:|-----------:|---------:|---------:|---------:|")
    for th in [0.0, 0.5]:
        pgh_k = ("pg_heap", "ycsb_a", "RC", th, 8)
        ep_k  = ("epistemic", "ycsb_a", "RC", th, 8)
        pgh = cells.get(pgh_k, [])
        ep  = cells.get(ep_k, [])
        if not pgh or not ep:
            continue
        pgh_tps = [x["metrics"]["throughput_txn_per_s"] for x in pgh]
        ep_tps  = [x["metrics"]["throughput_txn_per_s"] for x in ep]
        pgh_med = med(pgh_tps)
        ep_med = med(ep_tps)
        overhead = (pgh_med - ep_med) / pgh_med if pgh_med > 0 else 0.0
        # print pg_heap row
        pgh_ab = [x["metrics"]["abort_rate"] for x in pgh]
        pgh_p50 = [x["metrics"]["latency_ms"]["p50"] for x in pgh]
        pgh_p99 = [x["metrics"]["latency_ms"]["p99"] for x in pgh]
        ep_ab  = [x["metrics"]["abort_rate"] for x in ep]
        ep_p50 = [x["metrics"]["latency_ms"]["p50"] for x in ep]
        ep_p99 = [x["metrics"]["latency_ms"]["p99"] for x in ep]
        print(f"| {th:.2f} | pg_heap   | {pgh_med:.0f} | {std(pgh_tps):.0f} | "
              f"{med(pgh_ab):.3f} | {med(pgh_p50):.2f} | {med(pgh_p99):.2f} |    -- |")
        print(f"| {th:.2f} | epistemic | {ep_med:.0f} | {std(ep_tps):.0f} | "
              f"{med(ep_ab):.3f} | {med(ep_p50):.2f} | {med(ep_p99):.2f} | "
              f"{overhead*100:5.1f}% |")


def print_primary(rows: List[Dict[str, Any]]) -> None:
    scoped = [r for r in rows
              if r["workload"] == "ycsb_a" and r["isolation"] == "RC"]
    if not scoped:
        print("(no primary cells found)")
        return
    cells = collate(scoped)

    thetas   = sorted({r["zipfian_theta"] for r in scoped})
    clients  = sorted({r["clients"] for r in scoped})
    systems  = ["pg_heap", "epistemic", "pg_trigger"]

    print("### Primary grid — YCSB-A × RC")
    print()
    print("Throughput (median tps across 3 runs).")
    print()

    hdr = "| system | theta |"
    sep = "|--------|------:|"
    for c in clients:
        hdr += f" c={c} |"
        sep += "----:|"
    print(hdr)
    print(sep)
    for system in systems:
        for th in thetas:
            row = f"| {system} | {th:.2f} |"
            for c in clients:
                k = (system, "ycsb_a", "RC", th, c)
                g = cells.get(k, [])
                if not g:
                    row += "  -- |"
                    continue
                tps = [x["metrics"]["throughput_txn_per_s"] for x in g]
                row += f" {med(tps):.0f} |"
            print(row)

    print()
    print("Abort rate (median).")
    print()
    hdr = "| system | theta |"
    sep = "|--------|------:|"
    for c in clients:
        hdr += f" c={c} |"
        sep += "----:|"
    print(hdr)
    print(sep)
    for system in systems:
        for th in thetas:
            row = f"| {system} | {th:.2f} |"
            for c in clients:
                k = (system, "ycsb_a", "RC", th, c)
                g = cells.get(k, [])
                if not g:
                    row += "  -- |"
                    continue
                ab = [x["metrics"]["abort_rate"] for x in g]
                row += f" {med(ab):.3f} |"
            print(row)

    print()
    print("p99 latency ms (median).")
    print()
    hdr = "| system | theta |"
    sep = "|--------|------:|"
    for c in clients:
        hdr += f" c={c} |"
        sep += "----:|"
    print(hdr)
    print(sep)
    for system in systems:
        for th in thetas:
            row = f"| {system} | {th:.2f} |"
            for c in clients:
                k = (system, "ycsb_a", "RC", th, c)
                g = cells.get(k, [])
                if not g:
                    row += "  -- |"
                    continue
                p99 = [x["metrics"]["latency_ms"]["p99"] for x in g]
                row += f" {med(p99):.2f} |"
            print(row)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    args = ap.parse_args()

    rows = load(args.raw)
    if not rows:
        print("no data", file=sys.stderr)
        return 1

    hw = rows[0]["hardware"]
    pg = rows[0]["pg"]
    print(f"Hardware: {hw['os']} / {hw['cpu']} / {hw['cores']} cores / {hw['ram_gb']} GB")
    print(f"Postgres: {pg['version']} shared_buffers={pg['shared_buffers']} "
          f"synchronous_commit={pg['synchronous_commit']}")
    print(f"Cells:    {len(rows)}")
    print()

    print_gate(rows)
    print()
    print_primary(rows)

    return 0


if __name__ == "__main__":
    sys.exit(main())
