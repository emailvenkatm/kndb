#!/usr/bin/env python3
"""
Stage 3 / Task 3c — replay a normalized dataset trace against one
target system.

Reads bench/datasets/<name>/normalized.jsonl, replays every write
attempt against the requested system's fact table, then queries the
live survivor per slot and scores it against the dataset's
`ground_truth_survivor` (the benchmark's answer, NOT the KNDB lattice).

Emits one JSON file per cell to `bench/results/stage3_raw/`.

Metrics reported:
  * throughput_writes_per_s (measurement window ~= total replay time)
  * abort_rate + abort_breakdown
  * latency percentiles
  * correctness (dataset-specific):
      - AA (attempt-accuracy):  correct-survivor slots /
                                 contested-slots (all datasets)
      - CRS (LongMemEval only): plain KU-Acc as above
      - UOCS / Edit-Acc (MQuAKE only): case-level and per-slot
      - goodput_correct_writes_per_s

Concurrency: `--clients` threads pull writes from a shared work-queue
FIFO in trace order. Order preservation across clients is NOT
guaranteed (that's the point of a concurrent replay — we see what the
system does under contention). For c=1 the order is strictly the
trace's order.

For pg_llm cells at high concurrency, we cap latency: with the
calibrated 1120 ms mean, running 12k writes at c=8 with pg_sleep in
the trigger takes ~30 min per cell. To keep the run tractable we
cap the pg_llm replay to a random subset of --max-writes-pg-llm
writes (default 300) — enough to converge the correctness rate for a
Bernoulli(P=0.925) with a ~3% CI half-width.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import queue
import random
import sys
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional, Tuple

import psycopg
from psycopg import IsolationLevel

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from ycsb import (  # noqa: E402
    aggregate,
    classify_error,
    gather_hardware,
    gather_pg_meta,
    percentile,
    register_sources,
    NUM_SOURCES,
    SOURCE_IDS,
)
from correctness import (  # noqa: E402
    SYSTEM_TABLE_EXT, insert_sql_ext, read_sql_ext,
)


# --------------------------------------------------------------------
# Trace loader.
# --------------------------------------------------------------------

def load_trace(path: str) -> List[Dict[str, Any]]:
    trace: List[Dict[str, Any]] = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            trace.append(json.loads(line))
    return trace


# --------------------------------------------------------------------
# Reset: TRUNCATE every fact table and the audit + votes tables so
# each cell starts clean.
# --------------------------------------------------------------------

def full_reset(conn: psycopg.Connection, system: str) -> None:
    table = SYSTEM_TABLE_EXT[system]
    aux = []
    if system == "pg_mv":
        aux.append("fact_mv_votes")
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {table}")
        cur.execute("TRUNCATE epistemic.evicted_fact")
        for a in aux:
            cur.execute(f"TRUNCATE {a}")
    conn.commit()
    was_ac = conn.autocommit
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(f"VACUUM {table}")
    finally:
        conn.autocommit = was_ac


# --------------------------------------------------------------------
# Register every source that appears in the trace.
# --------------------------------------------------------------------

def register_trace_sources(conn: psycopg.Connection,
                           trace: List[Dict[str, Any]]) -> None:
    """
    Every INFERRED/DERIVED source_id string appearing in the trace has
    to be in epistemic.source_registry, else R2 rejects. Also register
    the SOURCE_IDS the YCSB workload uses, for consistency.
    """
    seen: set = set(SOURCE_IDS)
    for rec in trace:
        for s in rec.get("sources") or []:
            seen.add(s)
    with conn.cursor() as cur:
        # Bulk-safe INSERT ON CONFLICT.
        for s in sorted(seen):
            cur.execute(
                "INSERT INTO epistemic.source_registry (source_id, source_type) "
                "VALUES (%s, 'bench_dataset') ON CONFLICT DO NOTHING",
                (s,))
    conn.commit()


# --------------------------------------------------------------------
# Worker.
# --------------------------------------------------------------------

class WorkerStats:
    __slots__ = (
        "throughput_txns", "abort_40001", "abort_new_loses",
        "abort_check_violation", "abort_other", "latencies_ns",
    )

    def __init__(self) -> None:
        self.throughput_txns = 0
        self.abort_40001 = 0
        self.abort_new_loses = 0
        self.abort_check_violation = 0
        self.abort_other = 0
        self.latencies_ns: List[int] = []


def _open_conn(dsn: str, isolation: str, thread_id: int,
               llm_settings: Optional[Dict[str, str]] = None,
               conf_mode: str = "on",
               mv_mode: str = "on") -> psycopg.Connection:
    c = psycopg.connect(dsn, autocommit=False,
                        application_name=f"replay_{thread_id}")
    c.isolation_level = (IsolationLevel.SERIALIZABLE if isolation == "SR"
                         else IsolationLevel.READ_COMMITTED)
    c.autocommit = True
    c.execute("SET client_min_messages = WARNING")
    if llm_settings:
        for k, v in llm_settings.items():
            vq = str(v).replace("'", "''")
            c.execute(f"SET {k} = '{vq}'")
    if conf_mode != "on":
        c.execute(f"SET bench.fact_conf_mode = '{conf_mode}'")
    if mv_mode != "on":
        c.execute(f"SET bench.fact_mv_mode = '{mv_mode}'")
    c.autocommit = False
    return c


def worker(
    dsn: str, system: str, isolation: str,
    q: "queue.Queue[Optional[Dict[str, Any]]]",
    stats: WorkerStats, thread_id: int,
    llm_settings: Optional[Dict[str, str]] = None,
    conf_mode: str = "on", mv_mode: str = "on",
) -> None:
    ins = insert_sql_ext(system)
    conn = _open_conn(dsn, isolation, thread_id, llm_settings=llm_settings,
                      conf_mode=conf_mode, mv_mode=mv_mode)
    try:
        while True:
            rec = q.get()
            if rec is None:
                return
            valid_lower = rec["valid_time_lower_epoch"] or 0
            # Build the tstzrange literal via to_timestamp() -> tstzrange
            # We compose it in SQL so Python doesn't have to serialise
            # a timestamptz string.
            entity = rec["entity_id"]
            attr = rec["attribute"]
            val = rec["value"]
            sources = rec["sources"]  # list[str] or None
            # ep_kind in the trace is MEASURED for our normalized set;
            # if a future normalizer emits INFERRED/DERIVED sources
            # would be needed even for those.
            kind = rec["ep_kind"]
            spec = int(rec["ep_specificity"])
            conf = float(rec["ep_confidence"])
            if kind == "MEASURED":
                # R3 rejects MEASURED with sources; drop the sources
                # field for MEASURED. That matches how the YCSB
                # workload's make_payload does it.
                sources_arg = None
            else:
                sources_arg = sources

            # Use a custom insert that composes valid_time from epoch.
            ins_epoch = (
                f"INSERT INTO {SYSTEM_TABLE_EXT[system]} "
                f"(entity_id, attribute, value, sources, valid_time, "
                f" ep_kind, ep_specificity, ep_confidence) "
                f"VALUES (%s, %s, %s, %s, "
                f"        tstzrange(to_timestamp(%s), 'infinity'::timestamptz), "
                f"        %s::epistemic.epistemic_kind, %s::int2, %s::real)"
            )

            t0 = time.perf_counter_ns()
            try:
                conn.execute(ins_epoch, (entity, attr, val, sources_arg,
                                         valid_lower, kind, spec, conf))
                conn.commit()
                t1 = time.perf_counter_ns()
                stats.throughput_txns += 1
                stats.latencies_ns.append(t1 - t0)
            except Exception as e:  # noqa: BLE001
                try:
                    conn.rollback()
                except Exception:
                    try:
                        conn.close()
                    except Exception:
                        pass
                    conn = _open_conn(dsn, isolation, thread_id,
                                      llm_settings=llm_settings,
                                      conf_mode=conf_mode, mv_mode=mv_mode)
                cls = classify_error(e)
                if cls == "40001":
                    stats.abort_40001 += 1
                elif cls == "NEW_LOSES":
                    stats.abort_new_loses += 1
                elif cls == "check_violation":
                    stats.abort_check_violation += 1
                else:
                    stats.abort_other += 1
    finally:
        with contextlib.suppress(Exception):
            conn.close()


# --------------------------------------------------------------------
# Survivor scoring.
# --------------------------------------------------------------------

def measure_survivors(conn: psycopg.Connection, system: str,
                      trace: List[Dict[str, Any]]) -> Dict[Tuple[int, str], str]:
    """
    Return {(entity_id, attribute) -> live value}. Live = one row with
    upper(sys_time) = 'infinity'. If more than one, keep the first
    returned by the scan (we count integrity violations separately).
    """
    table = SYSTEM_TABLE_EXT[system]
    survivors: Dict[Tuple[int, str], str] = {}
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT entity_id, attribute, value FROM {table} "
            f"WHERE upper(sys_time) = 'infinity'::timestamptz")
        for eid, attr, val in cur.fetchall():
            key = (int(eid), attr)
            if key not in survivors:
                survivors[key] = val
    return survivors


def score_correctness(dataset: str, trace: List[Dict[str, Any]],
                      survivors: Dict[Tuple[int, str], str]
                      ) -> Dict[str, Any]:
    """
    Dataset-aware correctness. Every trace row has
    `ground_truth_survivor`; a slot's expected survivor is that value.
    """
    per_slot_gt: Dict[Tuple[int, str], str] = {}
    per_slot_arrivals: Dict[Tuple[int, str], int] = defaultdict(int)
    # For MQuAKE: aggregate per-case correctness.
    per_case_slots: Dict[Any, List[Tuple[int, str]]] = defaultdict(list)

    for rec in trace:
        key = (int(rec["entity_id"]), rec["attribute"])
        gt = rec.get("ground_truth_survivor")
        if gt is not None:
            per_slot_gt[key] = gt
        per_slot_arrivals[key] += 1
        meta = rec.get("dataset_metadata", {})
        if "case_id" in meta:
            per_case_slots[meta["case_id"]].append(key)

    n_slots = len(per_slot_gt)
    contested = [k for k, n in per_slot_arrivals.items() if n >= 2]
    n_contested = len(contested)
    n_correct_all = 0
    n_correct_contested = 0
    n_missing = 0

    for key, gt in per_slot_gt.items():
        sur = survivors.get(key)
        if sur is None:
            n_missing += 1
            continue
        if sur == gt:
            n_correct_all += 1
            if key in per_slot_arrivals and per_slot_arrivals[key] >= 2:
                n_correct_contested += 1

    corr: Dict[str, Any] = {
        "contested_slots": n_contested,
        "correct_on_contested": n_correct_contested,
        "AA": (n_correct_contested / n_contested if n_contested else 0.0),
        "all_slots_correct": n_correct_all,
        "all_slots": n_slots,
        "all_slot_accuracy": (n_correct_all / n_slots if n_slots else 0.0),
        "missing_live_rows": n_missing,
    }

    if dataset == "longmemeval":
        # KU-Acc == AA on this dataset since every slot is contested.
        corr["CRS_KU_Acc"] = corr["AA"]

    if dataset == "mquake":
        # UOCS: fraction of cases where every rewrite's survivor == target_new.
        n_cases = len(per_case_slots)
        n_cases_full_correct = 0
        for case_id, keys in per_case_slots.items():
            all_ok = True
            for key in keys:
                gt = per_slot_gt.get(key)
                sur = survivors.get(key)
                if gt is None or sur is None or sur != gt:
                    all_ok = False; break
            if all_ok:
                n_cases_full_correct += 1
        corr["UOCS"] = n_cases_full_correct / n_cases if n_cases else 0.0
        corr["Edit_Acc"] = corr["AA"]  # per-slot accuracy alias
        corr["n_cases"] = n_cases
        corr["n_cases_full_correct"] = n_cases_full_correct

    return corr


# --------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=os.environ.get("YCSB_DSN"))
    ap.add_argument("--dataset",
                    choices=["memoryagentbench", "longmemeval", "mquake"],
                    required=True)
    ap.add_argument("--trace", required=True,
                    help="path to normalized.jsonl")
    ap.add_argument("--system", choices=sorted(SYSTEM_TABLE_EXT.keys()),
                    required=True)
    ap.add_argument("--clients", type=int, required=True)
    ap.add_argument("--isolation", choices=["RC", "SR"], default="SR")
    ap.add_argument("--seed", type=int, default=20260712)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-writes", type=int, default=None,
                    help="cap number of trace records replayed (perf)")
    ap.add_argument("--max-writes-pg-llm", type=int, default=300,
                    help="separate cap that applies only when system==pg_llm")
    ap.add_argument("--llm-p-correct", default="0.925")
    ap.add_argument("--llm-latency-mean", default="1120")
    ap.add_argument("--llm-latency-sigma", default="0.3662")
    ap.add_argument("--llm-disable-test", default="0")
    ap.add_argument("--conf-mode", choices=["on", "off"], default="on")
    ap.add_argument("--mv-mode", choices=["on", "off"], default="on")
    args = ap.parse_args()

    if args.dsn is None:
        print("--dsn or YCSB_DSN required", file=sys.stderr); return 2

    trace = load_trace(args.trace)
    orig_n = len(trace)

    # Apply the trace cap. For pg_llm we sample a subset so we still get
    # a mix of the dataset's contested slots. RNG is seeded so the
    # subset is stable across cells.
    cap = args.max_writes
    if args.system == "pg_llm":
        pg_llm_cap = args.max_writes_pg_llm
        # Enforce whichever cap is tighter.
        cap = pg_llm_cap if cap is None else min(cap, pg_llm_cap)
    if cap is not None and cap < len(trace):
        # Sample by slot: pick slots first, then keep every write for
        # each chosen slot, until we hit ~cap. That preserves the
        # before/after pair structure.
        rng = random.Random(args.seed)
        by_slot: Dict[Tuple[int, str], List[Dict[str, Any]]] = defaultdict(list)
        for rec in trace:
            by_slot[(rec["entity_id"], rec["attribute"])].append(rec)
        slot_keys = list(by_slot.keys())
        rng.shuffle(slot_keys)
        sampled: List[Dict[str, Any]] = []
        for k in slot_keys:
            if len(sampled) >= cap:
                break
            sampled.extend(by_slot[k])
        # Preserve original trace order within the sample.
        sample_ids = set(id(r) for r in sampled)
        trace = [r for r in trace if id(r) in sample_ids]
        # (id-based filter preserves original order.)

    n_writes = len(trace)
    print(f"[replay] dataset={args.dataset} system={args.system} "
          f"c={args.clients} n_writes={n_writes}/{orig_n}", flush=True)

    # Setup: reset + register sources.
    setup = psycopg.connect(args.dsn, autocommit=True)
    try:
        pg_meta = gather_pg_meta(setup, args.isolation)
        setup.autocommit = False
        register_sources(setup)
        register_trace_sources(setup, trace)
        full_reset(setup, args.system)
        setup.autocommit = True
    finally:
        setup.close()

    llm_settings = {
        "bench.fact_llm_p_correct":     args.llm_p_correct,
        "bench.fact_llm_latency_mean":  args.llm_latency_mean,
        "bench.fact_llm_latency_sigma": args.llm_latency_sigma,
        "bench.fact_llm_disable_test":  args.llm_disable_test,
        "bench.fact_llm_mode":          "on",
    }

    # Enqueue every write. Workers consume FIFO.
    q: "queue.Queue[Optional[Dict[str, Any]]]" = queue.Queue()
    for rec in trace:
        q.put(rec)
    for _ in range(args.clients):
        q.put(None)  # sentinel per worker

    stats_list = [WorkerStats() for _ in range(args.clients)]

    t_start = time.time()
    with ThreadPoolExecutor(max_workers=args.clients) as pool:
        futs = [
            pool.submit(worker, args.dsn, args.system, args.isolation,
                        q, stats_list[i], i, llm_settings,
                        args.conf_mode, args.mv_mode)
            for i in range(args.clients)
        ]
        for f in futs:
            f.result()
    t_end = time.time()

    # Give pg_llm's pending pg_sleeps a moment to complete (they can
    # outlast the enqueue drain).
    time.sleep(1.0)

    # Score survivors.
    survivor_conn = psycopg.connect(args.dsn, autocommit=True)
    try:
        survivors = measure_survivors(survivor_conn, args.system, trace)
    finally:
        survivor_conn.close()

    corr = score_correctness(args.dataset, trace, survivors)

    # Aggregate metrics using stage-1 aggregator's math.
    meas_seconds = max(1e-3, t_end - t_start)
    metrics = aggregate(stats_list, meas_seconds)  # type: ignore[arg-type]

    tput = metrics["throughput_txn_per_s"]
    ar = metrics["abort_rate"]
    aa = corr["AA"]
    goodput = tput * (1.0 - ar) * aa

    out = {
        "dataset": args.dataset,
        "system": args.system,
        "concurrency": args.clients,
        "isolation": args.isolation,
        "seed": args.seed,
        "n_writes_attempted": n_writes,
        "n_writes_in_full_trace": orig_n,
        "was_subsampled": n_writes < orig_n,
        "elapsed_s": round(meas_seconds, 3),
        "hardware": gather_hardware(),
        "pg": pg_meta,
        "metrics": {
            "throughput_writes_per_s": tput,
            "abort_rate": ar,
            "abort_breakdown": {
                "40001": sum(s.abort_40001 for s in stats_list),
                "NEW_LOSES": sum(s.abort_new_loses for s in stats_list),
                "check_violation": sum(
                    s.abort_check_violation for s in stats_list),
                "other": sum(s.abort_other for s in stats_list),
            },
            "latency_ms": metrics["latency_ms"],
        },
        "correctness": corr,
        "goodput_correct_writes_per_s": goodput,
        "llm_settings": {
            "p_correct": args.llm_p_correct,
            "latency_mean_ms": args.llm_latency_mean,
            "latency_sigma": args.llm_latency_sigma,
            "disable_test": args.llm_disable_test,
        },
        "conf_mode": args.conf_mode,
        "mv_mode": args.mv_mode,
        "notes": (
            "Real dataset replay. Every write is MEASURED "
            "(spec=0, conf=1.0) per each dataset's mapping README; "
            "the datasets' ground truth is later-wins-per-slot, while "
            "KNDB's F8 tiebreak is first-committer-wins. That mismatch "
            "is the finding, not a bug — see stage3_correctness.csv."
        ),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True, default=str)

    hint = {
        "tps": tput,
        "abort_rate": ar,
        "AA": aa,
        "goodput": goodput,
        "contested": corr["contested_slots"],
        "elapsed_s": meas_seconds,
    }
    if "UOCS" in corr:
        hint["UOCS"] = corr["UOCS"]
    if "CRS_KU_Acc" in corr:
        hint["CRS_KU_Acc"] = corr["CRS_KU_Acc"]
    print(json.dumps(hint, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
