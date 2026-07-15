"""
F16 offline TD adapter: run a truth-discovery algorithm on an
already-normalized F14/F15 trace, emit predictions, score against gold
using the same `score_correctness` KNDB and pg_conf use.

The trace file is NEVER MODIFIED. TD algorithms consume the same trace
that the DB systems consume (so they see the same adversarial writes,
same set of honest writes).

Integrity is marked "N/A" — TD algorithms are OFFLINE and emit exactly
one predicted value per item by construction. There are no "live rows"
in a DB sense. Reporting integrity as PASS would overstate.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys
import time
from typing import Any, Dict, List, Tuple

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
# Reuse the driver's dataset-aware scorer.
sys.path.insert(0, os.path.join(_THIS_DIR, "..", "driver"))

from td_algorithms import ALGORITHMS  # noqa: E402
from replay_dataset import (  # noqa: E402
    load_trace, score_correctness,
)


def build_claims_from_trace(trace: List[Dict[str, Any]]
                            ) -> List[Tuple[Any, Any, Any]]:
    """
    Convert (entity_id, attribute, source, value) rows into
    (item_id, source_id, value) claims. Each trace row is one claim.

    - item_id  = (entity_id, attribute)
    - source_id: prefer `sources[0]`; if the KNDB row is MEASURED and
      has `sources==[]`, fall back to the dataset-metadata worker id
      (Zheng: `dataset_metadata.worker_id`; Book-Author:
      `dataset_metadata.source_name`). We do NOT synthesise per-row
      anonymous sources — that would give TD a bogus 3000-source
      "population" of single-observation sources that dilutes the
      trust-agreement signal TD is built to exploit.
    - value    = value string.

    This gives TD algorithms a HONEST source identifier for every
    claim, mirroring what they'd see if fed the raw Zheng /
    Dong-Book-Author CSVs directly (which is how the literature
    reports their numbers).
    """
    claims = []
    for i, rec in enumerate(trace):
        item = (int(rec["entity_id"]), rec["attribute"])
        srcs = rec.get("sources") or []
        if srcs:
            src = srcs[0]
        else:
            meta = rec.get("dataset_metadata") or {}
            wid = (meta.get("worker_id")
                   or meta.get("source_name")
                   or f"anon_{i}")
            # Reuse the same namespace the KNDB-format sources use
            # so a worker's MEASURED and (in another dataset) INFERRED
            # rows map to the same TD source id.
            if "worker_id" in meta:
                src = f"zheng_worker::{wid}"
            elif "source_name" in meta:
                src = f"bookstore::{wid}"
            else:
                src = f"anon_{i}"
        val = rec["value"]
        claims.append((item, src, val))
    return claims


def truth_dict_to_survivors(truth: Dict[Any, Any]
                            ) -> Dict[Tuple[int, str], str]:
    """Match the survivors-dict shape score_correctness expects."""
    out: Dict[Tuple[int, str], str] = {}
    for item, val in truth.items():
        # item is (entity_id, attribute); ensure it's a tuple.
        if isinstance(item, tuple) and len(item) == 2:
            out[item] = val
        else:
            raise ValueError(f"unexpected item shape: {item!r}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--dataset", required=True,
                    choices=["bookauthor", "zheng_sentiment"])
    ap.add_argument("--algorithm", required=True, choices=list(ALGORITHMS))
    ap.add_argument("--out", required=True)
    ap.add_argument("--tf-dampening", type=float, default=0.3)
    ap.add_argument("--tf-influence", type=float, default=0.5)
    ap.add_argument("--tf-initial-trust", type=float, default=0.9)
    ap.add_argument("--catd-alpha", type=float, default=0.05)
    ap.add_argument("--accu-initial-accuracy", type=float, default=0.8)
    ap.add_argument("--accu-n-false", type=int, default=None)
    ap.add_argument("--max-iter", type=int, default=100)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    trace = load_trace(args.trace)
    claims = build_claims_from_trace(trace)

    n_items = len(set(c[0] for c in claims))
    n_sources = len(set(c[1] for c in claims))
    n_claims = len(claims)

    fn = ALGORITHMS[args.algorithm]
    kwargs: Dict[str, Any] = {"max_iter": args.max_iter, "seed": args.seed}
    if args.algorithm == "truthfinder":
        kwargs.update(dict(dampening_factor=args.tf_dampening,
                           influence_related=args.tf_influence,
                           initial_trust=args.tf_initial_trust))
    elif args.algorithm == "catd":
        kwargs.update(dict(alpha=args.catd_alpha))
    elif args.algorithm == "accu":
        kwargs.update(dict(initial_accuracy=args.accu_initial_accuracy,
                           n_false=args.accu_n_false))

    t0 = time.perf_counter()
    truth, weights = fn(claims, **kwargs)
    elapsed = time.perf_counter() - t0

    survivors = truth_dict_to_survivors(truth)
    corr = score_correctness(args.dataset, trace, survivors)

    # Integrity field is N/A for offline TD baselines.
    corr["integrity"] = {
        "integrity_status": "N/A_offline",
        "note": ("offline algorithm emits exactly one predicted value "
                 "per item by construction; no DB live-row semantics "
                 "apply."),
    }

    result = {
        "algorithm": args.algorithm,
        "algorithm_kwargs": {k: v for k, v in kwargs.items()
                             if not callable(v)},
        "trace": os.path.abspath(args.trace),
        "dataset": args.dataset,
        "n_writes_attempted": n_claims,
        "n_items": n_items,
        "n_sources": n_sources,
        "correctness": corr,
        "metrics": {
            "elapsed_s": round(elapsed, 3),
            "throughput_writes_per_s": round(n_claims / elapsed, 1)
                if elapsed > 0 else 0.0,
            "abort_rate": 0.0,   # offline algorithm — no aborts
        },
        "kind": "td_offline",
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2, default=str)

    print(f"[td] algo={args.algorithm:12s} trace={os.path.basename(args.trace)} "
          f"n_items={n_items} n_sources={n_sources} n_claims={n_claims} "
          f"elapsed={elapsed:.2f}s "
          f"Precision={corr.get('Precision', corr.get('AA', 0)):.3f} "
          f"integ=N/A_offline")

    return 0


if __name__ == "__main__":
    sys.exit(main())
