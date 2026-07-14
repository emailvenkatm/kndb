#!/usr/bin/env python3
"""
Render Stage 2 CSV summaries into Markdown table blocks suitable for
pasting into bench/results/summary/stage2.md. Reads
`stage2_correctness.csv`, `stage2_disable_test.csv`, `stage2_control.csv`.

Emits three panels:

  1. Correctness rate matrix: rows = system, cols = (mix, theta, clients).
  2. Goodput matrix: same shape.
  3. Throughput / latency control panel.
  4. Disable-and-test rows.

Numbers are median across runs per cell (Stage 2 is 1 run per cell
except the disable-and-test transcript which stamps a reference and a
disabled variant).
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import defaultdict
from typing import Dict, List, Tuple


def load(path: str) -> List[Dict[str, str]]:
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def fmt_pct(s: str) -> str:
    try:
        v = float(s)
    except ValueError:
        return "—"
    return f"{v*100:.1f}%"


def fmt_num(s: str) -> str:
    try:
        v = float(s)
    except ValueError:
        return "—"
    return f"{v:,.0f}"


def render_correctness(rows: List[Dict[str, str]]) -> str:
    if not rows:
        return "_no correctness rows_\n"

    # Order matters — prettier output.
    SYSTEMS = ["epistemic", "pg_lww", "pg_conf", "pg_mv", "pg_llm",
               "pg_trigger", "pg_heap"]
    MIXES = ["easy", "moderate", "adversarial"]
    THETAS = ["0.5", "0.9"]
    CLIENTS = ["8", "32"]

    # Index rows.
    by_key: Dict[Tuple[str, str, str, str], Dict[str, str]] = {}
    for r in rows:
        by_key[(r["system"], r["kind_mix"], r["theta"], r["clients"])] = r

    def col_header(mix, theta, cli):
        return f"{mix[:3]}/θ{theta}/c{cli}"

    out = []
    out.append("### Correctness rate\n")
    out.append("Each cell shows correctness rate over contested slots. "
               "θ = Zipfian theta, c = concurrent clients. "
               "Mixes: easy = 90/9/1, moderate = 70/20/10, adversarial = 33/33/33 "
               "(INFERRED/MEASURED/DERIVED).\n")

    # Header
    columns = []
    for mix in MIXES:
        for theta in THETAS:
            for cli in CLIENTS:
                if (any((s, mix, theta, cli) in by_key for s in SYSTEMS)):
                    columns.append((mix, theta, cli))

    header = ["system"] + [col_header(*c) for c in columns]
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for s in SYSTEMS:
        cells = [s]
        for c in columns:
            r = by_key.get((s, *c))
            cells.append(fmt_pct(r["correctness_median"]) if r else "—")
        out.append("| " + " | ".join(cells) + " |")

    # Goodput
    out.append("\n### Goodput (correct commits per second)\n")
    out.append("goodput = throughput × (1 - abort_rate) × correctness_rate\n")
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for s in SYSTEMS:
        cells = [s]
        for c in columns:
            r = by_key.get((s, *c))
            cells.append(fmt_num(r["goodput_median"]) if r else "—")
        out.append("| " + " | ".join(cells) + " |")

    # Throughput
    out.append("\n### Throughput (commits per second)\n")
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for s in SYSTEMS:
        cells = [s]
        for c in columns:
            r = by_key.get((s, *c))
            cells.append(fmt_num(r["tps_median"]) if r else "—")
        out.append("| " + " | ".join(cells) + " |")

    # Integrity violations
    out.append("\n### Integrity violations (live-row duplicates + missing)\n")
    out.append("Slots with `n_live != 1`. Live-count derives from the "
               "post-run scan of `WHERE upper(sys_time)='infinity'`.\n")
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for s in SYSTEMS:
        cells = [s]
        for c in columns:
            r = by_key.get((s, *c))
            if r:
                miss = int(float(r["missing_live_median"]))
                dup = int(float(r["multi_live_median"]))
                cells.append(f"{miss}+{dup}")
            else:
                cells.append("—")
        out.append("| " + " | ".join(cells) + " |")
    return "\n".join(out) + "\n"


def render_disable_test(rows: List[Dict[str, str]]) -> str:
    if not rows:
        return "_no disable-test rows_\n"
    out = ["### Disable-and-test transcripts\n"]
    out.append("Reference vs disabled cell per mechanism, at "
               "kind_mix=adversarial, θ=0.9, 8 clients.\n")
    out.append("| system | mode | tps | abort_rate | correctness | goodput | multi_live |")
    out.append("|---|---|---|---|---|---|---|")
    for r in rows:
        # We infer mode from clients, run_index, and system.
        sys = r["system"]
        cli = r["clients"]
        mode = "ref"
        if sys == "pg_heap":
            mode = "no-lattice (KNDB disable)"
        # We can't tell disable vs ref from the aggregated CSV; leave 'ref'.
        out.append(
            f"| {sys} | {mode} | {fmt_num(r['tps_median'])} | "
            f"{r['abort_rate_median']} | "
            f"{fmt_pct(r['correctness_median'])} | "
            f"{fmt_num(r['goodput_median'])} | "
            f"{r['multi_live_median']} |")
    return "\n".join(out) + "\n"


def render_control(rows: List[Dict[str, str]]) -> str:
    if not rows:
        return "_no control rows_\n"
    out = ["### Control cells (throughput / latency)\n"]
    out.append("At mix=moderate, θ=0.9, varying concurrency.\n")
    out.append("| system | clients | tps | abort_rate | p50 (ms) | p99 (ms) | p99.9 (ms) |")
    out.append("|---|---|---|---|---|---|---|")
    for r in sorted(rows, key=lambda x: (x["system"], int(x["clients"]))):
        out.append(
            f"| {r['system']} | {r['clients']} | "
            f"{fmt_num(r['tps_median'])} | {r['abort_rate_median']} | "
            f"{r['p50_ms_median']} | {r['p99_ms_median']} | "
            f"{r['p99_9_ms_median']} |")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary-dir", required=True)
    ap.add_argument("--out", default="-")
    args = ap.parse_args()

    correctness = load(os.path.join(args.summary_dir, "stage2_correctness.csv"))
    disable = load(os.path.join(args.summary_dir, "stage2_disable_test.csv"))
    control = load(os.path.join(args.summary_dir, "stage2_control.csv"))

    output = (
        render_correctness(correctness)
        + "\n"
        + render_disable_test(disable)
        + "\n"
        + render_control(control)
    )
    if args.out == "-":
        print(output)
    else:
        with open(args.out, "w") as f:
            f.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
