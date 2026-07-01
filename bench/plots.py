"""Publication-clean plots for M6 results.

Generates figures into bench/results/figures/ as PNG + PDF pairs:
  - violations_caught.{png,pdf}  — stacked bar, adversarial outcomes per system
  - loc.{png,pdf}                — guard LOC per system
  - throughput_cdf.{png,pdf}     — per-row latency CDF, kndb vs handrolled
  - confidence_drift.{png,pdf}   — mean absolute drift per system

Style: default matplotlib, no ggplot. Sans-serif, tight_layout, no
gridlines beyond y-axis.
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
FIG = RESULTS / "figures"


def _style() -> None:
    plt.rcParams.update({
        "font.family": "DejaVu Sans",
        "font.size": 10,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.grid.axis": "y",
        "grid.linewidth": 0.4,
        "grid.alpha": 0.5,
    })


def _save(fig, stem: str) -> None:
    FIG.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG / f"{stem}.png", dpi=180, bbox_inches="tight")
    fig.savefig(FIG / f"{stem}.pdf", bbox_inches="tight")
    plt.close(fig)


def plot_violations() -> None:
    with open(RESULTS / "summary_totals.csv") as fh:
        rows = list(csv.DictReader(fh))
    systems = [r["system"] for r in rows]
    caught = [int(r["caught_at_write_time"]) for r in rows]
    missed = [int(r["missed_silently"]) for r in rows]
    crashed = [int(r["crashed"]) for r in rows]
    landed_ok = [int(r["total"]) - c - m - max(0, cr) for r, c, m, cr in zip(rows, caught, missed, crashed)]

    fig, ax = plt.subplots(figsize=(6.5, 3.6))
    x = range(len(systems))
    ax.bar(x, caught, label="caught_at_write_time", color="#2b7bba")
    ax.bar(x, missed, bottom=caught, label="missed_silently", color="#c94f4f")
    bottom_next = [a + b for a, b in zip(caught, missed)]
    ax.bar(x, [max(0, c) for c in crashed], bottom=bottom_next, label="crashed", color="#8d8d8d")
    bottom_next = [a + max(0, c) for a, c in zip(bottom_next, crashed)]
    ax.bar(x, landed_ok, bottom=bottom_next, label="legal_write_landed", color="#7bb87e")
    ax.set_xticks(list(x))
    ax.set_xticklabels(systems, rotation=15, ha="right")
    ax.set_ylabel("adversarial writes (n=100)")
    ax.set_title("Adversarial write outcomes per system")
    ax.legend(loc="upper right", fontsize=8, frameon=False)
    _save(fig, "violations_caught")


def plot_loc() -> None:
    with open(RESULTS / "loc.csv") as fh:
        rows = list(csv.DictReader(fh))
    systems = [r["system"] for r in rows]
    locs = [int(r["guard_loc"]) for r in rows]
    fig, ax = plt.subplots(figsize=(5.5, 3.4))
    x = range(len(systems))
    bars = ax.bar(list(x), locs, color="#4b6ea8")
    ax.set_xticks(list(x))
    ax.set_ylabel("guard LOC (non-blank, non-comment)")
    ax.set_title("Lines of guard code by baseline")
    for b, v in zip(bars, locs):
        ax.text(b.get_x() + b.get_width() / 2, v + max(locs) * 0.02, str(v),
                ha="center", va="bottom", fontsize=9)
    ax.set_xticklabels(systems, rotation=15, ha="right")
    _save(fig, "loc")


def plot_throughput_cdf() -> None:
    fig, ax = plt.subplots(figsize=(5.5, 3.6))
    ok = False
    for name, color in (("kndb", "#2b7bba"), ("pg_handrolled_triggers", "#c96f2b")):
        p = RESULTS / name / "throughput.csv"
        if not p.exists():
            continue
        # Read per-seed p50s to form a light CDF proxy across reps.
        with open(p) as fh:
            reader = csv.DictReader(fh)
            per_rep = []
            for row in reader:
                if not row.get("p50_us") or row["seed_rep"] == "mean" or row["seed_rep"] == "":
                    continue
                per_rep.append(float(row["p50_us"]))
        if not per_rep:
            continue
        ok = True
        vals = sorted(per_rep)
        y = [(i + 1) / len(vals) for i in range(len(vals))]
        ax.plot(vals, y, marker="o", label=name, color=color)

    ax.set_xlabel("per-rep median write latency (us)")
    ax.set_ylabel("CDF over seeds")
    ax.set_title("Write-latency CDF (10k rows/rep, seed reps)")
    ax.legend(loc="lower right", fontsize=9, frameon=False)
    if not ok:
        ax.text(0.5, 0.5, "no throughput data", ha="center", va="center", transform=ax.transAxes)
    _save(fig, "throughput_cdf")


def plot_confidence() -> None:
    p = RESULTS / "confidence_summary.csv"
    if not p.exists():
        return
    with open(p) as fh:
        rows = list(csv.DictReader(fh))
    systems = [r["system"] for r in rows]
    drift = [float(r["mean_abs_drift"]) for r in rows]
    fig, ax = plt.subplots(figsize=(5.5, 3.4))
    x = range(len(systems))
    bars = ax.bar(list(x), drift, color="#a94ea8")
    ax.set_xticks(list(x))
    ax.set_ylabel("mean absolute drift from closed-form Viterbi")
    ax.set_title("Confidence propagation error per system")
    for b, v in zip(bars, drift):
        ax.text(b.get_x() + b.get_width() / 2, v + max(drift + [0.01]) * 0.02, f"{v:.3f}",
                ha="center", va="bottom", fontsize=9)
    ax.set_xticklabels(systems, rotation=15, ha="right")
    _save(fig, "confidence_drift")


def main() -> int:
    _style()
    if (RESULTS / "summary_totals.csv").exists():
        plot_violations()
    if (RESULTS / "loc.csv").exists():
        plot_loc()
    plot_throughput_cdf()
    if (RESULTS / "confidence_summary.csv").exists():
        plot_confidence()
    print(f"figures in {FIG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
