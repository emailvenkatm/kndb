#!/usr/bin/env python3
"""
F13 Task 2 — roll up Book-Author cell results into a Markdown table.

Reads bench/results/stage3_raw/bookauthor_<system>_c<NNN>_K<NNN>.json
and writes bench/results/summary/stage3_bookauthor.md.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys


def parse_cell(path: str):
    m = re.match(
        r"bookauthor_(?P<sys>[^_]+(?:_[a-z]+)*)_c(?P<c>\d{3})_K(?P<K>\d{3})\.json$",
        os.path.basename(path))
    if not m:
        return None
    with open(path) as f:
        d = json.load(f)
    corr = d["correctness"]
    integ = corr.get("integrity") or {}
    return {
        "system": m["sys"],
        "c": int(m["c"]),
        "K": int(m["K"]),
        "n_writes": d["n_writes_attempted"],
        "tps": d["metrics"]["throughput_writes_per_s"],
        "abort_rate": d["metrics"]["abort_rate"],
        "AA": corr["AA"],
        "Precision": corr.get("Precision", corr["AA"]),
        "goodput": d["goodput_correct_writes_per_s"],
        "elapsed_s": d["elapsed_s"],
        "integrity_status": corr.get("integrity_status", "NOT_MEASURED"),
        "n_gt_1_live": integ.get("n_slots_with_gt_1_live"),
        "max_live_per_slot": integ.get("max_live_rows_per_slot"),
        "mean_live_per_slot": integ.get("mean_live_rows_per_slot"),
    }


def _prec_cell(r) -> str:
    """
    Render the Precision cell. If integrity FAILED for this cell, we
    print the F14-mandated 'INTEGRITY FAIL' string in place of the raw
    number — a numerically-high correctness score against a table with
    28+ live rows per slot is a scorer artefact, not a real signal.
    The raw value stays in the JSON under `Precision_ignoring_integrity`.
    """
    if r["integrity_status"] == "FAIL":
        return "INTEGRITY FAIL"
    return f"{r['Precision']:.3f}"


def main() -> int:
    raw_dir = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(__file__), "..", "results",
                     "stage3_raw")
    out_path = sys.argv[2] if len(sys.argv) > 2 else \
        os.path.join(os.path.dirname(__file__), "..", "results", "summary",
                     "stage3_bookauthor.md")
    rows = []
    for p in sorted(glob.glob(os.path.join(raw_dir,
                                           "bookauthor_*.json"))):
        r = parse_cell(p)
        if r is not None:
            rows.append(r)
    if not rows:
        print("no bookauthor cells found", file=sys.stderr)
        return 1

    # Group by K, then by (system, c).
    Ks = sorted({r["K"] for r in rows})
    systems = sorted({r["system"] for r in rows})
    Cs = sorted({r["c"] for r in rows})

    out_lines: list[str] = []
    out_lines.append("# Stage 3 Book-Author results (F13)\n")
    out_lines.append(
        "Dong VLDB'09 Book-Author dataset. Ground truth = cover-truth "
        "author lists (100 gold ISBN-10 books). Source-tier mapping "
        "computed from structural properties of `book.txt` "
        "(n_listings + canon_rate); see "
        "`bench/datasets/bookauthor/README.md`.\n")

    for K in Ks:
        out_lines.append(f"\n## K = {K}\n")
        out_lines.append(
            "| system | c | n_writes | tps | abort_rate | Precision | "
            "integrity | goodput | elapsed_s |")
        out_lines.append(
            "|---|---|---|---|---|---|---|---|---|")
        for s in systems:
            for c in Cs:
                match = [r for r in rows
                         if r["system"] == s and r["c"] == c
                         and r["K"] == K]
                if not match:
                    continue
                r = match[0]
                integ_txt = r["integrity_status"]
                if integ_txt == "FAIL":
                    integ_txt = f"FAIL (max={r['max_live_per_slot']}, "\
                        f"mean={r['mean_live_per_slot']:.1f})"
                out_lines.append(
                    f"| {r['system']} | {r['c']} | {r['n_writes']} | "
                    f"{r['tps']:.1f} | {r['abort_rate']:.3f} | "
                    f"{_prec_cell(r)} | {integ_txt} | "
                    f"{r['goodput']:.1f} | {r['elapsed_s']:.2f} |")

    # Sensitivity table: pivot Precision by (system, K) at c=1.
    # F14 note: cells with integrity_status=FAIL show "INTEGRITY FAIL"
    # instead of a number. pg_heap's "high correctness" was a scorer
    # artefact of picking the first-returned row when 28-114 live rows
    # co-existed per slot; F14 stops printing that number.
    out_lines.append(
        "\n## Sensitivity of Precision to K (c=1)\n\n"
        "Cells reading INTEGRITY FAIL had > 1 live row per (entity, "
        "attribute) slot at end-of-trace — the numeric \"Precision\" "
        "would only be a coin-flip on whichever duplicate the scanner "
        "returned first. Preserved under `Precision_ignoring_integrity` "
        "in the raw JSON.\n")
    out_lines.append("| system | " + " | ".join(f"K={K}" for K in Ks) +
                     " |")
    out_lines.append("|" + "---|" * (len(Ks) + 1))
    for s in systems:
        cells = []
        for K in Ks:
            match = [r for r in rows
                     if r["system"] == s and r["c"] == 1 and r["K"] == K]
            if match:
                cells.append(_prec_cell(match[0]))
            else:
                cells.append("-")
        out_lines.append(f"| {s} | " + " | ".join(cells) + " |")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        f.write("\n".join(out_lines) + "\n")

    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
