#!/usr/bin/env python3
"""
Stage 3 rollup: read every JSON in bench/results/stage3_raw/, emit
stage3.md and stage3_correctness.csv into bench/results/summary/.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from typing import Any, Dict, List


CELL_PATTERN = re.compile(
    r"^(?P<dataset>memoryagentbench|longmemeval|mquake)_"
    r"(?P<system>epistemic|pg_heap|pg_trigger|pg_lww|pg_conf|pg_mv|pg_llm)_"
    r"c(?P<clients>\d+)\.json$"
)


def load_cells(raw_dir: str) -> List[Dict[str, Any]]:
    cells: List[Dict[str, Any]] = []
    for fname in sorted(os.listdir(raw_dir)):
        m = CELL_PATTERN.match(fname)
        if not m:
            continue
        with open(os.path.join(raw_dir, fname)) as f:
            d = json.load(f)
        d["_cell_dataset"] = m.group("dataset")
        d["_cell_system"] = m.group("system")
        d["_cell_clients"] = int(m.group("clients"))
        cells.append(d)
    return cells


def write_csv(cells: List[Dict[str, Any]], out_path: str) -> None:
    fields = [
        "dataset", "system", "clients", "isolation",
        "n_writes_attempted", "was_subsampled",
        "throughput_writes_per_s", "abort_rate",
        "abort_40001", "abort_new_loses", "abort_check_violation",
        "abort_other",
        "latency_p50_ms", "latency_p95_ms", "latency_p99_ms", "latency_mean_ms",
        "contested_slots", "correct_on_contested", "AA",
        "CRS_KU_Acc", "UOCS", "Edit_Acc",
        "n_cases", "n_cases_full_correct",
        "goodput_correct_writes_per_s",
        "elapsed_s",
        # F14: integrity axis alongside correctness numbers.
        "integrity_status",
        "n_slots_with_gt_1_live",
        "max_live_rows_per_slot",
    ]
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for c in cells:
            m = c.get("metrics", {})
            lat = m.get("latency_ms", {}) or {}
            ab = m.get("abort_breakdown", {}) or {}
            cor = c.get("correctness", {}) or {}
            row = {
                "dataset": c["_cell_dataset"],
                "system": c["_cell_system"],
                "clients": c["_cell_clients"],
                "isolation": c.get("isolation", "?"),
                "n_writes_attempted": c.get("n_writes_attempted"),
                "was_subsampled": c.get("was_subsampled"),
                "throughput_writes_per_s":
                    round(m.get("throughput_writes_per_s", 0.0), 2),
                "abort_rate": round(m.get("abort_rate", 0.0), 6),
                "abort_40001": ab.get("40001", 0),
                "abort_new_loses": ab.get("NEW_LOSES", 0),
                "abort_check_violation": ab.get("check_violation", 0),
                "abort_other": ab.get("other", 0),
                "latency_p50_ms": lat.get("p50"),
                "latency_p95_ms": lat.get("p95"),
                "latency_p99_ms": lat.get("p99"),
                "latency_mean_ms": lat.get("mean"),
                "contested_slots": cor.get("contested_slots"),
                "correct_on_contested": cor.get("correct_on_contested"),
                "AA": round(cor.get("AA", 0.0), 6),
                "CRS_KU_Acc": cor.get("CRS_KU_Acc"),
                "UOCS": cor.get("UOCS"),
                "Edit_Acc": cor.get("Edit_Acc"),
                "n_cases": cor.get("n_cases"),
                "n_cases_full_correct": cor.get("n_cases_full_correct"),
                "goodput_correct_writes_per_s":
                    round(c.get("goodput_correct_writes_per_s", 0.0), 2),
                "elapsed_s": c.get("elapsed_s"),
                "integrity_status": cor.get("integrity_status",
                                            "NOT_MEASURED"),
                "n_slots_with_gt_1_live": (cor.get("integrity") or {}).get(
                    "n_slots_with_gt_1_live"),
                "max_live_rows_per_slot": (cor.get("integrity") or {}).get(
                    "max_live_rows_per_slot"),
            }
            w.writerow(row)


def write_md(cells: List[Dict[str, Any]], out_path: str) -> None:
    # Group by dataset for readability.
    by_ds: Dict[str, List[Dict[str, Any]]] = {}
    for c in cells:
        by_ds.setdefault(c["_cell_dataset"], []).append(c)

    lines = [
        "# Stage 3 results (F12)",
        "",
        "Real dataset replay across 7 systems × 3 concurrency levels.",
        "See DECISIONS.md for design notes and honest-scope caveats.",
        "",
    ]
    for ds in sorted(by_ds.keys()):
        cells_ds = by_ds[ds]
        cells_ds.sort(key=lambda c: (c["_cell_system"], c["_cell_clients"]))
        lines.append(f"## {ds}")
        lines.append("")
        # First-line context.
        any_c = cells_ds[0]
        n_full = any_c.get("n_writes_in_full_trace")
        lines.append(
            f"Full trace: {n_full} writes. See "
            f"`bench/datasets/{ds}/README.md` for provenance and mapping.")
        lines.append("")
        header = ["system", "c", "n_writes", "tps", "abort_rate",
                  "AA", "integrity", "goodput", "elapsed_s"]
        if ds == "longmemeval":
            header.append("CRS")
        if ds == "mquake":
            header.append("UOCS")
            header.append("cases_ok")
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "|".join("---" for _ in header) + "|")
        for c in cells_ds:
            m = c.get("metrics", {})
            cor = c.get("correctness", {})
            integ_status = cor.get("integrity_status", "NOT_MEASURED")
            aa_cell = ("INTEGRITY FAIL" if integ_status == "FAIL"
                       else f"{cor.get('AA', 0.0):.3f}")
            row = [
                c["_cell_system"],
                str(c["_cell_clients"]),
                str(c.get("n_writes_attempted", "?")),
                f"{m.get('throughput_writes_per_s', 0.0):.1f}",
                f"{m.get('abort_rate', 0.0):.3f}",
                aa_cell,
                integ_status,
                f"{c.get('goodput_correct_writes_per_s', 0.0):.1f}",
                f"{c.get('elapsed_s', 0.0):.2f}",
            ]
            if ds == "longmemeval":
                crs = cor.get('CRS_KU_Acc', 0.0)
                row.append("INTEGRITY FAIL" if integ_status == "FAIL"
                           else f"{crs:.3f}")
            if ds == "mquake":
                uocs = cor.get('UOCS', 0.0)
                row.append("INTEGRITY FAIL" if integ_status == "FAIL"
                           else f"{uocs:.3f}")
                row.append(f"{cor.get('n_cases_full_correct', 0)}/{cor.get('n_cases', 0)}")
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    cells = load_cells(args.raw)
    if not cells:
        print("no cells found", file=sys.stderr); return 1
    os.makedirs(args.out, exist_ok=True)
    write_csv(cells, os.path.join(args.out, "stage3_correctness.csv"))
    write_md(cells, os.path.join(args.out, "stage3.md"))
    print(f"wrote {len(cells)} cells to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
