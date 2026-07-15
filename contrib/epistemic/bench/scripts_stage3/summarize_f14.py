#!/usr/bin/env python3
"""
F14 Item 2 — roll up adversarial (kind-vs-confidence) cell results
into a Markdown table.

Reads bench/results/stage3_raw/adversarial_<system>_c<NNN>_N<NN>.json
and writes bench/results/summary/stage3_adversarial.md.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys


CELL_RE = re.compile(
    r"adversarial_(?P<sys>[a-z_]+)_c(?P<c>\d{3})_N(?P<N>\d{2})\.json$"
)


def parse_cell(path: str):
    m = CELL_RE.match(os.path.basename(path))
    if not m:
        return None
    with open(path) as f:
        d = json.load(f)
    corr = d["correctness"]
    integ = corr.get("integrity") or {}
    return {
        "system": m["sys"],
        "c": int(m["c"]),
        "N": int(m["N"]),
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


def prec_cell(r) -> str:
    if r["integrity_status"] == "FAIL":
        return "INTEGRITY FAIL"
    return f"{r['Precision']:.3f}"


def main() -> int:
    raw_dir = (sys.argv[1] if len(sys.argv) > 1 else
               os.path.join(os.path.dirname(__file__), "..", "results",
                            "stage3_raw"))
    out_path = (sys.argv[2] if len(sys.argv) > 2 else
                os.path.join(os.path.dirname(__file__), "..", "results",
                             "summary", "stage3_adversarial.md"))
    rows = []
    for p in sorted(glob.glob(os.path.join(raw_dir, "adversarial_*.json"))):
        r = parse_cell(p)
        if r is not None:
            rows.append(r)
    if not rows:
        print("no adversarial cells found", file=sys.stderr)
        return 1

    Ns = sorted({r["N"] for r in rows})
    Cs = sorted({r["c"] for r in rows})
    systems = sorted({r["system"] for r in rows})

    out_lines = []
    out_lines.append(
        "# Stage 3 Adversarial (F14): kind-vs-confidence disagreement\n")
    out_lines.append(
        "**Ground-truth policy** (stated up front, does not adapt): a "
        "MEASURED value beats an INFERRED value regardless of the INFERRED "
        "value's asserted confidence. Confidence is a self-report; kind "
        "reflects the epistemic act. Under this policy the correct survivor "
        "on every gold ISBN is a Tier-A MEASURED writer (top-K/2 by "
        "n_listings AND canon_rate >= 0.5) if one exists.\n")
    out_lines.append(
        "**Threat model**: N hostile/miscalibrated writers per gold ISBN "
        "assert INFERRED with confidence uniform in [0.95, 1.0] on a "
        "scrambled-real-answer (an author string lifted from a DIFFERENT "
        "gold ISBN). Real-world analogue: LLM-generated content that "
        "hallucinates values but self-reports as certain; malicious agent "
        "poisoning a knowledge store.\n")
    out_lines.append(
        "**F14 mapping** (revised from F13 to make kind vs. confidence "
        "genuinely disagree):\n"
        "  * Tier A (top-K/2 by n_listings AND canon_rate >= 0.5): "
        "MEASURED, conf uniform [0.5, 0.9]\n"
        "  * Tier B (rest of top-K by n_listings): "
        "INFERRED, conf uniform [0.4, 0.7]\n"
        "  * Tier C (else): DERIVED, conf uniform [0.2, 0.5]\n"
        "  * Adversarial injection: INFERRED, conf uniform [0.95, 1.0]\n\n"
        "Confidence draws use a deterministic seeded RNG "
        "(seed=20260714) so the workload is bit-for-bit reproducible.\n")
    out_lines.append(
        "**Independence from ground truth**: the tier assignment "
        "(kind + conf RANGE) depends only on (n_listings, canon_rate) — "
        "structural properties of `book.txt`. Only the specific conf "
        "sample within the range depends on the seeded RNG. Adversarial "
        "injections do not read `book_golden.txt` to decide who to "
        "attack — every gold ISBN gets N injections.\n")

    for N in Ns:
        out_lines.append(f"\n## N = {N} adversarial writes per gold ISBN\n")
        out_lines.append(
            "| system | c | n_writes | tps | abort_rate | Precision "
            "| integrity | goodput | elapsed_s |")
        out_lines.append(
            "|---|---|---|---|---|---|---|---|---|")
        for c in Cs:
            for s in systems:
                match = [r for r in rows
                         if r["system"] == s and r["c"] == c and r["N"] == N]
                if not match:
                    continue
                r = match[0]
                integ_txt = r["integrity_status"]
                if integ_txt == "FAIL":
                    integ_txt = (
                        f"FAIL (max={r['max_live_per_slot']}, "
                        f"mean={r['mean_live_per_slot']:.1f})")
                out_lines.append(
                    f"| {r['system']} | {r['c']} | {r['n_writes']} | "
                    f"{r['tps']:.1f} | {r['abort_rate']:.3f} | "
                    f"{prec_cell(r)} | {integ_txt} | "
                    f"{r['goodput']:.1f} | {r['elapsed_s']:.2f} |")

    # Pivot: Precision by (system, N) at c=1. The decisive view.
    out_lines.append(
        "\n## Scaling of adversarial pressure (c=1, Precision)\n\n"
        "The core F14 question: does the kind axis remain load-bearing "
        "as adversarial pressure grows? If KNDB's Precision stays flat "
        "while pg_conf's collapses, the kind axis is doing real work. "
        "If they degrade together, the lattice's kind axis was not "
        "load-bearing and the paper's contribution reduces to "
        "\"confidence-sorting with an audit trail.\"\n")
    out_lines.append(
        "| system | N=1 | N=3 | N=5 | N=10 |")
    out_lines.append("|" + "---|" * (len(Ns) + 1))
    for s in systems:
        cells = []
        for N in Ns:
            match = [r for r in rows
                     if r["system"] == s and r["c"] == 1 and r["N"] == N]
            if match:
                cells.append(prec_cell(match[0]))
            else:
                cells.append("-")
        out_lines.append(f"| {s} | " + " | ".join(cells) + " |")

    out_lines.append(
        "\n## Scaling of adversarial pressure (c=8, Precision)\n")
    out_lines.append("| system | N=1 | N=3 | N=5 | N=10 |")
    out_lines.append("|" + "---|" * (len(Ns) + 1))
    for s in systems:
        cells = []
        for N in Ns:
            match = [r for r in rows
                     if r["system"] == s and r["c"] == 8 and r["N"] == N]
            if match:
                cells.append(prec_cell(match[0]))
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
