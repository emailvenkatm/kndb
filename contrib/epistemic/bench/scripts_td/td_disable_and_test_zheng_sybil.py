"""
F17 Item 1 disable-and-test: mirror F16's TD-mechanism disable-and-test,
but on Zheng d_sentiment F17-Sybil traces at every N (01/03/05/10/20).

Method (same as F16): replace each TD algorithm's iterative
trust/weight loop with the frozen equivalent — plain majority vote
(no per-source weighting at all). If MV Precision > TD Precision on
the same trace, the agreement loop was actively amplifying the Sybil
attack.

Output: bench/results/td_raw/zheng_sybil_disable_and_test.json with
per-N per-algorithm Precision + MV Precision comparison.
"""
from __future__ import annotations

import collections
import json
import os
import random
import sys

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
sys.path.insert(0, os.path.join(_THIS_DIR, "..", "driver"))

from td_algorithms import truthfinder, crh, catd, accu  # type: ignore
from replay_dataset import load_trace, score_correctness  # type: ignore
from run_td_offline import build_claims_from_trace, truth_dict_to_survivors


def majority_vote_predict(claims, seed=0):
    """Frozen-trust equivalent: no agreement-driven update at all."""
    item_to_sv = collections.defaultdict(list)
    for it, s, v in claims:
        item_to_sv[it].append((s, v))
    rng = random.Random(seed)
    truth = {}
    for it, svs in item_to_sv.items():
        c = collections.Counter(v for _s, v in svs)
        top = max(c.values())
        winners = sorted([v for v, n in c.items() if n == top], key=str)
        truth[it] = winners[0] if len(winners) == 1 else rng.choice(winners)
    return truth


def score_run(trace_path, dataset, run_fn):
    trace = load_trace(trace_path)
    claims = build_claims_from_trace(trace)
    truth = run_fn(claims)
    survivors = truth_dict_to_survivors(truth)
    corr = score_correctness(dataset, trace, survivors)
    return corr.get("Precision", corr.get("AA", 0.0))


def main():
    ds_root = os.path.join(_THIS_DIR, "..", "datasets", "zheng_sentiment")
    out_path = os.path.join(_THIS_DIR, "..", "results", "td_raw",
                            "zheng_sybil_disable_and_test.json")
    Ns = ["01", "03", "05", "10", "20"]
    results = {}
    for N in Ns:
        trace = os.path.join(ds_root, f"normalized_f17_K45_sybil_N{N}.jsonl")
        assert os.path.isfile(trace), trace
        row = {}
        print(f"\n=== Zheng Sybil N={N} disable-and-test ===")
        for name, fn in [("truthfinder", truthfinder),
                         ("crh", crh),
                         ("catd", catd),
                         ("accu", accu)]:
            p = score_run(trace, "zheng_sentiment",
                          lambda c, fn=fn: fn(c, seed=0)[0])
            row[f"{name}_on"] = round(p, 4)
            print(f"  {name:12s} mechanism ON  Precision={p:.4f}")
        p_mv = score_run(trace, "zheng_sentiment", majority_vote_predict)
        row["mv_off"] = round(p_mv, 4)
        print(f"  {'majority_vote':12s} mechanism OFF Precision={p_mv:.4f}")
        for algo in ("truthfinder", "crh", "catd", "accu"):
            delta = row[f"{algo}_on"] - row["mv_off"]
            flag = ("AMPLIFIED" if delta < -0.005 else
                    ("neutral " if abs(delta) <= 0.005 else "helped "))
            print(f"    delta {algo}_on - mv_off = {delta:+.4f}  {flag}")
        results[f"N{N}"] = row

    with open(out_path, "w") as f:
        json.dump({"kind": "td_disable_and_test",
                   "dataset": "zheng_sentiment",
                   "attack": "F17_sybil",
                   "K": 45,
                   "results": results}, f, indent=2)
    print(f"\nsaved: {out_path}")


if __name__ == "__main__":
    main()
