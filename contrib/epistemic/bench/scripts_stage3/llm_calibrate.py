#!/usr/bin/env python3
"""
Stage 3 / Task 1 — real-LLM calibration of the pg_llm mock.

Selects ~200 representative (incumbent, candidate) conflict pairs from
the Stage 2 adversarial workload generator (same RNG streams as
driver/correctness.py at kind_mix=adversarial, theta=0.9, c=8), builds
the prompt that pg_llm.sql's trigger would issue, calls the real
Anthropic Messages API (claude-haiku-4-5) with JSON-mode instructions,
measures per-call end-to-end latency, and grades correctness against
the lattice ground truth (same rules as F10's `compute_lattice_winners`).

Writes:
  bench/results/stage3_llm_calibration.jsonl   — one line per call

Prints summary:
  N, mean/median/p50/p95/p99 latency ms, correctness rate.

Requires ANTHROPIC_API_KEY exported by the caller. See run_stage3.sh.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import string
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Tuple

import urllib.request
import urllib.error

# Reuse Stage 2 generator so pairs match the workload exactly.
_HERE = os.path.dirname(os.path.abspath(__file__))
_DRIVER = os.path.abspath(os.path.join(_HERE, "..", "driver"))
sys.path.insert(0, _DRIVER)
from ycsb import (  # noqa: E402
    ATTRS_PER_ENTITY, NUM_SLOTS, NUM_SOURCES, SOURCE_IDS,
    ZipfianGenerator, slot_to_pair,
)
from correctness import (  # noqa: E402
    KIND_MIXES, make_payload_ext, pick_kind_from_mix,
)

# --------------------------------------------------------------------
# Preseed reconstruction (matches driver/correctness.py preseed_baseline_row).
# --------------------------------------------------------------------

def preseed_row(seed: int, slot: int) -> Dict[str, Any]:
    rng = random.Random(seed ^ 0xF0F0F0F0)
    # Deterministic replay: walk to the slot's row.
    val = None
    for s in range(slot + 1):
        val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
    return {
        "kind": "INFERRED", "spec": 0, "conf": 0.5, "value": val,
    }


# Faster: precompute once.
def all_preseed(seed: int) -> Dict[int, Dict[str, Any]]:
    rng = random.Random(seed ^ 0xF0F0F0F0)
    out: Dict[int, Dict[str, Any]] = {}
    for slot in range(NUM_SLOTS):
        val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
        out[slot] = {"kind": "INFERRED", "spec": 0, "conf": 0.5, "value": val}
    return out


# --------------------------------------------------------------------
# Sampler: replay a small window of the adversarial workload, harvest
# every (incumbent, candidate) pair that collides on a hot slot.
# --------------------------------------------------------------------

def sample_conflicts(seed: int, theta: float, clients: int,
                     mix: str, n_target: int) -> List[Dict[str, Any]]:
    """
    Deterministically replay the workload generator for N synthetic
    'write attempts' per client and collect the first `n_target`
    conflicts (i.e., writes into a slot that already has an
    incumbent that differs on kind/spec/conf/value).
    """
    kind_cdf = KIND_MIXES[mix]
    live: Dict[int, Dict[str, Any]] = dict(all_preseed(seed))
    conflicts: List[Dict[str, Any]] = []

    # Interleave clients round-robin like the closed-loop bench does.
    rngs = []
    zipfs = []
    for tid in range(clients):
        rngs.append(random.Random(
            seed ^ (tid * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF))
        zipfs.append(ZipfianGenerator(NUM_SLOTS, theta,
                                      seed ^ (tid * 0xDEADBEEF)))

    steps = 0
    max_steps = 200_000  # cap; adversarial mix + zipf 0.9 should
                        # produce a conflict on almost every hot slot.
    while len(conflicts) < n_target and steps < max_steps:
        for tid in range(clients):
            slot = zipfs[tid].next()
            p = make_payload_ext(rngs[tid], kind_cdf)
            inc = live[slot]
            if (inc["kind"] != p["kind"]
                    or inc["spec"] != p["specificity"]
                    or abs(inc["conf"] - p["confidence"]) > 1e-6
                    or inc["value"] != p["value"]):
                entity, attr = slot_to_pair(slot)
                conflicts.append({
                    "slot": slot,
                    "entity_id": entity,
                    "attribute": attr,
                    "incumbent": dict(inc),
                    "candidate": {
                        "kind": p["kind"],
                        "spec": p["specificity"],
                        "conf": float(p["confidence"]),
                        "value": p["value"],
                        "sources": p["sources"],
                    },
                })
                if len(conflicts) >= n_target:
                    break
            # Update live table with the "lattice-max" so the next
            # conflict on the same slot reflects the running incumbent.
            if _lattice_beats(inc, p):
                live[slot] = {
                    "kind": p["kind"], "spec": p["specificity"],
                    "conf": float(p["confidence"]), "value": p["value"],
                }
            steps += 1
    return conflicts


KIND_RANK = {"MEASURED": 3, "DERIVED": 2, "INFERRED": 1}


def _lattice_beats(inc: Dict[str, Any], cand: Dict[str, Any]) -> bool:
    """True iff candidate strictly beats incumbent under KNDB lattice."""
    ir = KIND_RANK[inc["kind"]]
    cr = KIND_RANK[cand["kind"]]
    if cr > ir:
        return True
    if cr < ir:
        return False
    if cand["specificity"] > inc["spec"]:
        return True
    if cand["specificity"] < inc["spec"]:
        return False
    if cand["confidence"] > inc["conf"]:
        return True
    if cand["confidence"] < inc["conf"]:
        return False
    # True tie: KNDB is first-committer-wins -> incumbent stays.
    return False


def lattice_verdict(inc: Dict[str, Any], cand: Dict[str, Any]) -> str:
    return "new_wins" if _lattice_beats(inc, {
        "kind": cand["kind"], "specificity": cand["spec"],
        "confidence": cand["conf"], "value": cand["value"],
    }) else "incumbent_wins"


# --------------------------------------------------------------------
# Prompt (matches the intent of pg_llm.sql's trigger — the trigger
# hides the lattice-answer inside plpgsql; a real LLM sees only the
# structured records and is asked to pick the winner).
# --------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You are a database conflict-resolution assistant. Two records "
    "target the same slot (entity_id, attribute) in a bitemporal "
    "knowledge store and cannot both remain live. Choose which record "
    "should survive.\n\n"
    "The store uses an epistemic-kind ordering:\n"
    "  MEASURED (recorded from a sensor/human) > DERIVED (aggregated) > "
    "INFERRED (guessed).\n"
    "Within the same kind, higher specificity beats lower; within the "
    "same kind and specificity, higher confidence beats lower; on true "
    "ties the earlier-committed record wins.\n\n"
    "Respond with strict JSON only, no prose, no markdown, matching:\n"
    "  {\"winner\": \"incumbent\" | \"new\"}\n"
)

USER_TEMPLATE = (
    "Slot: entity_id={entity_id}, attribute={attribute!r}\n\n"
    "INCUMBENT (already in the table):\n"
    "  kind={inc_kind}\n"
    "  specificity={inc_spec}\n"
    "  confidence={inc_conf}\n"
    "  value={inc_value!r}\n\n"
    "NEW (incoming write):\n"
    "  kind={new_kind}\n"
    "  specificity={new_spec}\n"
    "  confidence={new_conf}\n"
    "  value={new_value!r}\n\n"
    "Choose the winner. Reply with JSON only."
)


def build_prompt(conflict: Dict[str, Any]) -> Tuple[str, str]:
    inc = conflict["incumbent"]
    cand = conflict["candidate"]
    user = USER_TEMPLATE.format(
        entity_id=conflict["entity_id"],
        attribute=conflict["attribute"],
        inc_kind=inc["kind"], inc_spec=inc["spec"],
        inc_conf=round(inc["conf"], 4), inc_value=inc["value"],
        new_kind=cand["kind"], new_spec=cand["spec"],
        new_conf=round(cand["conf"], 4), new_value=cand["value"],
    )
    return SYSTEM_PROMPT, user


# --------------------------------------------------------------------
# Anthropic Messages API call (stdlib urllib to avoid extra deps).
# --------------------------------------------------------------------

ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"


def call_anthropic(api_key: str, model: str, sys_prompt: str,
                    user_prompt: str, timeout_s: float = 30.0
                    ) -> Tuple[float, Optional[Dict[str, Any]], Optional[str]]:
    body = json.dumps({
        "model": model,
        "max_tokens": 64,
        "system": sys_prompt,
        "messages": [{"role": "user", "content": user_prompt}],
    }).encode("utf-8")
    req = urllib.request.Request(
        ANTHROPIC_URL, data=body, method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            raw = r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        latency_ms = (time.perf_counter() - t0) * 1000.0
        return latency_ms, None, f"http_{e.code}:{e.read()[:200]!r}"
    except Exception as e:  # noqa: BLE001
        latency_ms = (time.perf_counter() - t0) * 1000.0
        return latency_ms, None, f"exc:{type(e).__name__}:{e}"
    latency_ms = (time.perf_counter() - t0) * 1000.0
    try:
        j = json.loads(raw)
    except Exception:  # noqa: BLE001
        return latency_ms, None, f"non_json:{raw[:200]}"
    return latency_ms, j, None


def extract_verdict(resp: Dict[str, Any]) -> Optional[str]:
    """Pull the JSON-mode content out of Anthropic's message response."""
    try:
        parts = resp.get("content", [])
        text = "".join(
            p.get("text", "") for p in parts if p.get("type") == "text"
        ).strip()
    except Exception:  # noqa: BLE001
        return None
    if not text:
        return None
    # Trim ``` fences if the model wrapped anyway.
    if text.startswith("```"):
        text = text.strip("` \n")
        if text.startswith("json"):
            text = text[4:].strip()
    try:
        j = json.loads(text)
    except Exception:  # noqa: BLE001
        # Loose parse: find the first '{' ... '}' block.
        i, j0 = text.find("{"), text.rfind("}")
        if i < 0 or j0 < i:
            return None
        try:
            j = json.loads(text[i:j0 + 1])
        except Exception:  # noqa: BLE001
            return None
    w = j.get("winner")
    if isinstance(w, str) and w.lower() in ("incumbent", "new"):
        return w.lower()
    return None


# --------------------------------------------------------------------
# Driver.
# --------------------------------------------------------------------

def one_call(idx: int, conflict: Dict[str, Any], api_key: str,
             model: str) -> Dict[str, Any]:
    sys_p, user_p = build_prompt(conflict)
    ground_truth = lattice_verdict(conflict["incumbent"], conflict["candidate"])
    latency_ms, resp, err = call_anthropic(api_key, model, sys_p, user_p)
    verdict = extract_verdict(resp) if resp is not None else None
    correct = (verdict == ("new" if ground_truth == "new_wins" else "incumbent")
               if verdict is not None else None)
    return {
        "idx": idx,
        "slot": conflict["slot"],
        "entity_id": conflict["entity_id"],
        "attribute": conflict["attribute"],
        "incumbent": conflict["incumbent"],
        "candidate": conflict["candidate"],
        "prompt_system": sys_p,
        "prompt_user": user_p,
        "ground_truth_lattice": ground_truth,
        "model_verdict": verdict,
        "correct": correct,
        "latency_ms": round(latency_ms, 2),
        "raw_response": resp,
        "error": err,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200,
                    help="target number of conflicts to grade")
    ap.add_argument("--seed", type=int, default=20260712)
    ap.add_argument("--theta", type=float, default=0.9)
    ap.add_argument("--clients", type=int, default=8)
    ap.add_argument("--mix", default="adversarial")
    ap.add_argument("--model", default="claude-haiku-4-5")
    ap.add_argument("--out", required=True,
                    help="path to write JSONL of per-call records")
    ap.add_argument("--summary-out", default=None,
                    help="optional JSON summary file")
    ap.add_argument("--concurrency", type=int, default=8,
                    help="parallel API calls")
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 2

    print(f"[calibrate] sampling {args.n} conflicts ...", flush=True)
    conflicts = sample_conflicts(args.seed, args.theta, args.clients,
                                 args.mix, args.n)
    print(f"[calibrate] got {len(conflicts)} conflicts", flush=True)
    if len(conflicts) < args.n:
        print(f"[calibrate] WARNING: wanted {args.n} conflicts, "
              f"only harvested {len(conflicts)}", flush=True)

    results: List[Dict[str, Any]] = [None] * len(conflicts)  # type: ignore
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futs = {
            pool.submit(one_call, i, c, api_key, args.model): i
            for i, c in enumerate(conflicts)
        }
        done = 0
        for fut in as_completed(futs):
            r = fut.result()
            results[r["idx"]] = r
            done += 1
            if done % 20 == 0:
                print(f"[calibrate] {done}/{len(conflicts)} calls done",
                      flush=True)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".",
                exist_ok=True)
    with open(args.out, "w") as f:
        for r in results:
            if r is None:
                continue
            f.write(json.dumps(r, sort_keys=True) + "\n")

    # Summarise.
    lats = [r["latency_ms"] for r in results if r and r["error"] is None]
    correct = [1 for r in results if r and r.get("correct") is True]
    graded = [r for r in results if r and r.get("correct") is not None]
    errors = [r for r in results if r and r["error"] is not None]
    n_graded = len(graded)
    n_correct = sum(correct)
    correctness_rate = (n_correct / n_graded) if n_graded else 0.0

    def pct(xs, p):
        if not xs:
            return None
        s = sorted(xs)
        k = max(0, min(len(s) - 1, int(round(p * (len(s) - 1)))))
        return s[k]

    summary = {
        "n_total": len(results),
        "n_ok_calls": len(lats),
        "n_errors": len(errors),
        "n_graded": n_graded,
        "n_correct": n_correct,
        "correctness_rate": correctness_rate,
        "latency_ms": {
            "mean": statistics.mean(lats) if lats else None,
            "median": statistics.median(lats) if lats else None,
            "p95": pct(lats, 0.95),
            "p99": pct(lats, 0.99),
            "min": min(lats) if lats else None,
            "max": max(lats) if lats else None,
        },
        "model": args.model,
        "seed": args.seed,
        "mix": args.mix,
        "theta": args.theta,
        "clients": args.clients,
    }
    print(json.dumps(summary, indent=2))
    if args.summary_out:
        with open(args.summary_out, "w") as f:
            json.dump(summary, f, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
