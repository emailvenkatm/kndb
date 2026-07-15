"""
F16 disable-and-test: prove that TD algorithms' collapse under Sybil
attack is CAUSED by the inter-source-agreement mechanism, not by some
incidental scoring artefact. Mirrors F14/F15 source-rebuild
disable-and-test discipline.

Method: patch each TD algorithm to freeze source trust / weight at a
constant (disabling the agreement-driven update loop) and re-run the
Sybil-N=10 cell. If the "mechanism-off" precision is HIGHER than the
"mechanism-on" precision, the collapse is caused by the mechanism —
which is what we want to prove.

We instrument the algorithms by wrapping them, not modifying the
committed source (parallel to F14/F15's dylib-rebuild but at Python
level — no source-tree edits, no bench-lib rebuild required).
"""
from __future__ import annotations

import collections
import random
import sys
import os

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
sys.path.insert(0, os.path.join(_THIS_DIR, "..", "driver"))

from td_algorithms import truthfinder, crh, catd, accu, _group_by_item  # type: ignore
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


def run_one(name, trace_path, dataset, run_fn):
    trace = load_trace(trace_path)
    claims = build_claims_from_trace(trace)
    truth = run_fn(claims)
    survivors = truth_dict_to_survivors(truth)
    corr = score_correctness(dataset, trace, survivors)
    p = corr.get("Precision", corr.get("AA", 0.0))
    print(f"  {name:40s} Precision={p:.3f}")
    return p


if __name__ == "__main__":
    # Book-Author Sybil N=10.
    ba_trace = os.path.join(_THIS_DIR, "..", "datasets", "bookauthor",
                            "normalized_f16_K50_sybil_N10.jsonl")
    print("=== Book-Author Sybil N=10 disable-and-test ===")
    print("(if 'mechanism OFF' > 'mechanism ON', the agreement loop is "
          "actively AMPLIFYING the Sybil attack)")
    print()
    for algo_name, algo_fn in [("truthfinder", truthfinder),
                               ("crh", crh),
                               ("catd", catd),
                               ("accu", accu)]:
        run_one(f"{algo_name:12s} mechanism ON (default)",
                ba_trace, "bookauthor",
                lambda c, fn=algo_fn: fn(c, seed=0)[0])
    run_one("mechanism OFF: plain majority-vote",
            ba_trace, "bookauthor", majority_vote_predict)
    print()

    # Zheng Sybil-by-construction N=10.
    zh_trace = os.path.join(_THIS_DIR, "..", "datasets", "zheng_sentiment",
                            "normalized_f15_K045_N10.jsonl")
    print("=== Zheng d_sentiment coordinated-flip N=10 (Sybil by binary "
          "construction) ===")
    for algo_name, algo_fn in [("truthfinder", truthfinder),
                               ("crh", crh),
                               ("catd", catd),
                               ("accu", accu)]:
        run_one(f"{algo_name:12s} mechanism ON (default)",
                zh_trace, "zheng_sentiment",
                lambda c, fn=algo_fn: fn(c, seed=0)[0])
    run_one("mechanism OFF: plain majority-vote",
            zh_trace, "zheng_sentiment", majority_vote_predict)
