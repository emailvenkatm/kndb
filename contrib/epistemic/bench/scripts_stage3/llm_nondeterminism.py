#!/usr/bin/env python3
"""
Stage 3 / Task 3a — LLM non-determinism probe.

Sample 50 representative conflicts from F11's calibration set
(bench/results/stage3_llm_calibration.jsonl), replay each conflict
N=10 times against the same claude-haiku-4-5 model with the SAME
prompt template pg_llm.sql's trigger conceptually issues, and record
whether the LLM's decision flips across identical inputs.

Output:
  bench/results/stage3_llm_nondeterminism_raw.jsonl   one line per API call
  bench/results/stage3_llm_nondeterminism_summary.json

Metrics:
  * flip rate: fraction of conflicts where at least one of the N replies
    disagrees with the modal answer.
  * per-conflict entropy: Shannon entropy over {incumbent, new} across
    the N replies. Range [0, log2(2)] = [0, 1] bits.
  * ambiguity buckets: unanimous / 9-1 / 8-2 / 7-3 / 6-4 / 5-5(tie).
  * worst-case conflict (largest disagreement).
  * latency stats: mean, median, p95, p99.

Requires ANTHROPIC_API_KEY. Reuses the exact call_anthropic / prompt
scaffolding from llm_calibrate.py so the observed behaviour is
apples-to-apples with the calibration.

Writes every raw response to disk as it arrives. If the process dies
mid-run, whatever survived is still analysable.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import statistics
import sys
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Tuple

# Reuse F11's API caller + prompt template verbatim.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from llm_calibrate import (  # noqa: E402
    SYSTEM_PROMPT,
    build_prompt,
    call_anthropic,
    extract_verdict,
    lattice_verdict,
)


def load_conflicts(path: str, n: int, seed: int) -> List[Dict[str, Any]]:
    """
    Sample `n` conflicts from the JSONL calibration set. We stratify by
    ground truth (new_wins vs incumbent_wins) so the sample isn't all
    one class, which is important because the calibration set is
    heavily biased toward "new_wins" (MEASURED writes on INFERRED
    preseed dominate the adversarial mix).
    """
    with open(path) as f:
        recs = [json.loads(l) for l in f if l.strip()]
    # Only keep records that were graded (no API errors).
    graded = [r for r in recs if r.get("error") is None]
    news = [r for r in graded if r.get("ground_truth_lattice") == "new_wins"]
    incs = [r for r in graded if r.get("ground_truth_lattice") == "incumbent_wins"]

    rng = random.Random(seed)
    # Try to sample 60/40 new/incumbent when possible; fall back to
    # whatever is available. Preserves representativeness while still
    # exposing us to both branches of the lattice.
    n_new_target = min(len(news), max(1, int(round(n * 0.6))))
    n_inc_target = min(len(incs), n - n_new_target)
    # Fill remainder from majority class if the minority is thin.
    n_new_target = min(len(news), n - n_inc_target)

    rng.shuffle(news)
    rng.shuffle(incs)
    sample = news[:n_new_target] + incs[:n_inc_target]
    rng.shuffle(sample)
    if len(sample) < n:
        # Top up from whatever remains.
        extras = [r for r in graded if r not in sample]
        rng.shuffle(extras)
        sample.extend(extras[: n - len(sample)])
    return sample[:n]


def rebuild_conflict(rec: Dict[str, Any]) -> Dict[str, Any]:
    """Map a calibration JSONL record back to build_prompt()'s expected
    shape (which is what llm_calibrate.one_call constructs)."""
    return {
        "slot": rec["slot"],
        "entity_id": rec["entity_id"],
        "attribute": rec["attribute"],
        "incumbent": rec["incumbent"],
        "candidate": rec["candidate"],
    }


def one_probe(idx: int, replay_idx: int, conflict: Dict[str, Any],
              api_key: str, model: str,
              raw_lock: threading.Lock,
              raw_fh) -> Dict[str, Any]:
    """One API call. Writes its record to `raw_fh` immediately so a
    crash mid-batch loses only in-flight calls."""
    sys_p, user_p = build_prompt(conflict)
    gt = lattice_verdict(conflict["incumbent"], conflict["candidate"])
    latency_ms, resp, err = call_anthropic(api_key, model, sys_p, user_p)
    verdict = extract_verdict(resp) if resp is not None else None
    rec = {
        "conflict_idx": idx,
        "replay_idx": replay_idx,
        "slot": conflict["slot"],
        "entity_id": conflict["entity_id"],
        "attribute": conflict["attribute"],
        "incumbent": conflict["incumbent"],
        "candidate": conflict["candidate"],
        "ground_truth_lattice": gt,
        "model_verdict": verdict,
        "correct_vs_lattice": (
            verdict == ("new" if gt == "new_wins" else "incumbent")
            if verdict is not None else None
        ),
        "latency_ms": round(latency_ms, 2),
        "raw_response": resp,
        "error": err,
    }
    with raw_lock:
        raw_fh.write(json.dumps(rec, sort_keys=True) + "\n")
        raw_fh.flush()
    return rec


def shannon_entropy_bits(counts: Dict[str, int]) -> float:
    total = sum(counts.values())
    if total == 0:
        return 0.0
    ent = 0.0
    for k, v in counts.items():
        if v == 0:
            continue
        p = v / total
        ent -= p * math.log2(p)
    return ent


def bucket_label(counts: Dict[str, int], N: int) -> str:
    """Categorise a conflict's N=10 replies into an ambiguity bucket."""
    hi = max(counts.values()) if counts else 0
    lo = min(counts.values()) if len(counts) > 1 else 0
    if hi == N:
        return "unanimous"
    if hi == N - 1:
        return f"{N - 1}-1"
    if hi == N - 2:
        return f"{N - 2}-2"
    if hi == N - 3:
        return f"{N - 3}-3"
    return f"{hi}-{N - hi}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--calibration", required=True,
        help="path to F11's stage3_llm_calibration.jsonl")
    ap.add_argument("--n-conflicts", type=int, default=50)
    ap.add_argument("--n-replays", type=int, default=10)
    ap.add_argument("--seed", type=int, default=20260712)
    ap.add_argument("--model", default="claude-haiku-4-5")
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--raw-out", required=True)
    ap.add_argument("--summary-out", required=True)
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 2

    conflicts = load_conflicts(args.calibration, args.n_conflicts, args.seed)
    print(f"[nondet] loaded {len(conflicts)} conflicts "
          f"(target={args.n_conflicts}) x {args.n_replays} replays "
          f"= {len(conflicts) * args.n_replays} calls",
          flush=True)

    os.makedirs(os.path.dirname(os.path.abspath(args.raw_out)) or ".",
                exist_ok=True)
    raw_lock = threading.Lock()
    raw_fh = open(args.raw_out, "w")

    tasks: List[Tuple[int, int, Dict[str, Any]]] = []
    for i, rec in enumerate(conflicts):
        c = rebuild_conflict(rec)
        for r in range(args.n_replays):
            tasks.append((i, r, c))

    results: List[Dict[str, Any]] = []
    t_wall_start = time.time()
    try:
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            futs = {
                pool.submit(one_probe, i, r, c, api_key, args.model,
                            raw_lock, raw_fh): (i, r)
                for (i, r, c) in tasks
            }
            done = 0
            for fut in as_completed(futs):
                results.append(fut.result())
                done += 1
                if done % 25 == 0 or done == len(tasks):
                    dt = time.time() - t_wall_start
                    print(f"[nondet] {done}/{len(tasks)} calls "
                          f"({dt:.0f}s elapsed, "
                          f"{dt/done*1000:.0f} ms/call amortized)",
                          flush=True)
    finally:
        raw_fh.close()

    # Roll up.
    per_conflict: Dict[int, List[Dict[str, Any]]] = {}
    for r in results:
        per_conflict.setdefault(r["conflict_idx"], []).append(r)

    conflict_summaries: List[Dict[str, Any]] = []
    flip_count = 0
    bucket_counter: Counter[str] = Counter()
    all_latencies: List[float] = []
    correct_vs_lattice_count = 0
    n_graded_calls = 0

    for idx in sorted(per_conflict.keys()):
        rows = per_conflict[idx]
        verdicts = [r["model_verdict"] for r in rows]
        errs = [r["error"] for r in rows if r["error"] is not None]
        # Filter to graded replies (verdict is not None).
        graded = [v for v in verdicts if v in ("incumbent", "new")]
        counts = Counter(graded)
        # Fill missing keys so bucketing / entropy have both bins.
        c_inc = counts.get("incumbent", 0)
        c_new = counts.get("new", 0)
        counts_dict = {"incumbent": c_inc, "new": c_new}
        N = c_inc + c_new
        ent = shannon_entropy_bits(counts_dict)
        modal = "new" if c_new >= c_inc else "incumbent"
        modal_count = max(c_inc, c_new)
        flipped = (N > 0 and modal_count < N)
        if flipped:
            flip_count += 1
        bucket = bucket_label(counts_dict, N) if N else "no_graded_replies"
        bucket_counter[bucket] += 1
        first_row = rows[0]
        gt = first_row["ground_truth_lattice"]
        n_correct_this = sum(
            1 for r in rows if r.get("correct_vs_lattice") is True)
        correct_vs_lattice_count += n_correct_this
        n_graded_calls += N
        all_latencies.extend(r["latency_ms"] for r in rows
                             if r["error"] is None)

        conflict_summaries.append({
            "conflict_idx": idx,
            "slot": first_row["slot"],
            "entity_id": first_row["entity_id"],
            "attribute": first_row["attribute"],
            "incumbent": first_row["incumbent"],
            "candidate": first_row["candidate"],
            "ground_truth_lattice": gt,
            "n_replays": len(rows),
            "n_graded": N,
            "n_errors": len(errs),
            "counts": counts_dict,
            "modal_verdict": modal if N else None,
            "modal_count": modal_count,
            "entropy_bits": round(ent, 6),
            "flipped": flipped,
            "bucket": bucket,
            "correct_vs_lattice_out_of_replays": n_correct_this,
        })

    def pct(xs: List[float], p: float) -> Optional[float]:
        if not xs:
            return None
        s = sorted(xs)
        k = max(0, min(len(s) - 1, int(round(p * (len(s) - 1)))))
        return s[k]

    entropies = [c["entropy_bits"] for c in conflict_summaries
                 if c["n_graded"] > 0]
    worst = sorted(conflict_summaries,
                   key=lambda c: (-c["entropy_bits"], c["conflict_idx"]))[:5]

    summary = {
        "model": args.model,
        "n_conflicts": len(conflict_summaries),
        "n_replays_per_conflict": args.n_replays,
        "n_calls_total": len(results),
        "n_calls_ok": len(all_latencies),
        "n_calls_errors": len(results) - len(all_latencies),
        "n_conflicts_that_flipped": flip_count,
        "flip_rate": (flip_count / len(conflict_summaries)
                      if conflict_summaries else 0.0),
        "buckets": dict(bucket_counter),
        "mean_entropy_bits": (statistics.mean(entropies) if entropies
                              else 0.0),
        "median_entropy_bits": (statistics.median(entropies) if entropies
                                else 0.0),
        "max_entropy_bits": max(entropies) if entropies else 0.0,
        "latency_ms": {
            "mean": statistics.mean(all_latencies) if all_latencies else None,
            "median": statistics.median(all_latencies) if all_latencies else None,
            "p95": pct(all_latencies, 0.95),
            "p99": pct(all_latencies, 0.99),
            "min": min(all_latencies) if all_latencies else None,
            "max": max(all_latencies) if all_latencies else None,
        },
        "aggregate_correct_vs_lattice_rate": (
            correct_vs_lattice_count / n_graded_calls
            if n_graded_calls else None
        ),
        "worst_case_conflicts": worst,
        "seed": args.seed,
        "elapsed_s": round(time.time() - t_wall_start, 1),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.summary_out)) or ".",
                exist_ok=True)
    with open(args.summary_out, "w") as f:
        json.dump({
            "summary": summary,
            "per_conflict": conflict_summaries,
        }, f, indent=2, sort_keys=True, default=str)

    print(json.dumps(summary, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
