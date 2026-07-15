#!/usr/bin/env python3
"""
F15 — roll up Zheng d_sentiment replication cells (baseline + adversarial)
into a Markdown table.

Reads:
  bench/results/stage3_raw/baseline_zheng_<sys>_c<NNN>_K<KKK>.json
  bench/results/stage3_raw/adversarial_zheng_<sys>_c<NNN>_N<NN>.json
Writes:
  bench/results/summary/stage3_zheng_sentiment.md
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys


BASE_RE = re.compile(
    r"baseline_zheng_(?P<sys>[a-z_]+)_c(?P<c>\d{3})_K(?P<K>\d{3})\.json$"
)
ADV_RE = re.compile(
    r"adversarial_zheng_(?P<sys>[a-z_]+)_c(?P<c>\d{3})_N(?P<N>\d{2})\.json$"
)


def parse_cell(path: str, pattern: re.Pattern):
    m = pattern.match(os.path.basename(path))
    if not m:
        return None
    with open(path) as f:
        d = json.load(f)
    corr = d["correctness"]
    integ = corr.get("integrity") or {}
    out = {
        "system": m["sys"],
        "c": int(m["c"]),
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
    if "K" in m.groupdict():
        out["K"] = int(m["K"])
    if "N" in m.groupdict():
        out["N"] = int(m["N"])
    return out


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
                             "summary", "stage3_zheng_sentiment.md"))

    baseline_rows = []
    for p in sorted(glob.glob(os.path.join(raw_dir, "baseline_zheng_*.json"))):
        r = parse_cell(p, BASE_RE)
        if r is not None:
            baseline_rows.append(r)

    adv_rows = []
    for p in sorted(glob.glob(os.path.join(raw_dir,
                                           "adversarial_zheng_*.json"))):
        r = parse_cell(p, ADV_RE)
        if r is not None:
            adv_rows.append(r)

    if not baseline_rows and not adv_rows:
        print("no zheng cells found", file=sys.stderr)
        return 1

    Ks = sorted({r["K"] for r in baseline_rows})
    Ns = sorted({r["N"] for r in adv_rows})
    Cs = sorted({r["c"] for r in baseline_rows + adv_rows})
    systems = sorted({r["system"] for r in baseline_rows + adv_rows})

    out_lines = []
    out_lines.append(
        "# Stage 3 F15: Zheng VLDB'17 d_sentiment replication of "
        "confidence-forgery attack\n")
    out_lines.append(
        "**Second-dataset replication of the F14 kind-vs-confidence result.** "
        "F14 established KNDB beats pg_conf by 63 pp on Book-Author under "
        "adversarial INFERRED conf~1.0 writes, and proved the kind axis "
        "is load-bearing via source-rebuild disable-and-test. Single-dataset "
        "results don't survive review — F15 runs the same construction on "
        "a second, independent, authority-shaped dataset.\n")
    out_lines.append(
        "**Dataset**: Zheng et al. VLDB 2017 truth-inference benchmark, "
        "`d_sentiment` sub-dataset. 1,000 sentiment-classification items, "
        "85 crowd workers, 20,000 labels, 999/1000 items contested. Full "
        "provenance: `bench/datasets/zheng_sentiment/README.md`. "
        "The primary target (CytoCrowd, arXiv:2602.06674) was pivoted away "
        "from because (a) no downloadable dataset artefact was published "
        "with the paper, and (b) all four pathologists are peer-level "
        "board-certified, so no independent-of-gold credential-tier signal "
        "exists in the paper's data even if we could obtain it.\n")
    out_lines.append(
        "**Independent per-worker signal** (KNDB tier mapping input, "
        "computed BEFORE any main-task label arbitration): each worker's "
        "accuracy on a disjoint 20-item qualification test. Workers are "
        "sorted by quali_acc; top K/3 -> MEASURED conf [0.5,0.9], middle "
        "K/3 -> INFERRED conf [0.4,0.7], bottom third + workers outside "
        "top-K -> DERIVED conf [0.2,0.5]. Adversarial writes: INFERRED "
        "conf [0.95,1.0], flipped-gold value, inserted at random "
        "positions (adv_seed=20260715).\n")
    out_lines.append(
        "**Independence self-audit**: the qualification items (question "
        "IDs 2000..2019) are disjoint from the main-task items (0..999). "
        "`quali_acc(w)` is computed from `quali.csv` + `quali_truth.csv` "
        "only; never touches `answer.csv` or `truth.csv`. Tier assignment "
        "and confidence RANGE are gold-independent; only the exact "
        "confidence sample within the range depends on the seeded RNG. "
        "Adversarial payloads DO know the gold (flipping requires it) — "
        "that's F14's threat model: real attackers have gold.\n")

    if baseline_rows:
        out_lines.append(
            "\n## Baseline sensitivity to K (no adversarial writes, N=0)\n")
        out_lines.append(
            "Sanity-check baseline: does KNDB's Precision on the honest "
            "dataset track a reasonable ceiling? Zheng's Table 4 reports "
            "Majority Voting = 0.928, Dawid-Skene = 0.893 on this dataset. "
            "KNDB's mechanism ranks by (kind, spec, conf, xmin); with "
            "Tier-A conf uniform [0.5,0.9] and multiple Tier-A votes per "
            "slot, the highest-conf-draw among the top-quali workers wins.\n")
        for c in Cs:
            out_lines.append(f"\n### c = {c}\n")
            out_lines.append(
                "| system | " + " | ".join(f"K={k}" for k in Ks) + " |")
            out_lines.append("|" + "---|" * (len(Ks) + 1))
            for s in systems:
                cells = []
                for K in Ks:
                    match = [r for r in baseline_rows
                             if r["system"] == s and r["c"] == c
                             and r["K"] == K]
                    if match:
                        cells.append(prec_cell(match[0]))
                    else:
                        cells.append("-")
                out_lines.append(f"| {s} | " + " | ".join(cells) + " |")

    if adv_rows:
        out_lines.append(
            "\n## Adversarial sweep (K=45, N in {1, 3, 5, 10})\n")
        for N in Ns:
            out_lines.append(f"\n### N = {N} adversarial writes per gold "
                             f"slot\n")
            out_lines.append(
                "| system | c | n_writes | tps | abort_rate | Precision "
                "| integrity | goodput | elapsed_s |")
            out_lines.append(
                "|---|---|---|---|---|---|---|---|---|")
            for c in Cs:
                for s in systems:
                    match = [r for r in adv_rows
                             if r["system"] == s and r["c"] == c
                             and r["N"] == N]
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

        # Decisive pivot: Precision by (system, N) at c=1.
        out_lines.append(
            "\n## Scaling of adversarial pressure (c=1, Precision)\n\n"
            "The core F15 question: does the F14 result reproduce on a "
            "second, independent, authority-shaped dataset?\n")
        out_lines.append(
            "| system | N=1 | N=3 | N=5 | N=10 |")
        out_lines.append("|" + "---|" * (len(Ns) + 1))
        for s in systems:
            cells = []
            for N in Ns:
                match = [r for r in adv_rows
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
                match = [r for r in adv_rows
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
