#!/usr/bin/env python3
"""
F14 Item 1 — retroactive integrity sweep.

F13 shipped its stage3 raw JSONs before the integrity axis existed;
they carry a numeric Precision but no per-slot live-row count. F14
requires every cell to carry `integrity_status` so pg_heap's
"spuriously high correctness" cannot masquerade as a correctness win.

For cells where integrity is proved-by-construction we FILL IN the
integrity fields directly (no replay). For cells where the raw
outcome depends on concurrency & trigger races (pg_heap always,
pg_lww at c>1) we REPLAY the workload against a fresh cluster and
measure `SELECT entity_id, attribute, count(*) FROM <table>
WHERE upper(sys_time)='infinity' GROUP BY 1,2` at end-of-trace.

Backfilled cells are written back to the same
`bench/results/stage3_raw/bookauthor_*.json` files, augmented with:

    correctness.integrity = {
        "n_live_slots": <int>,
        "max_live_rows_per_slot": <int>,
        "mean_live_rows_per_slot": <float>,
        "n_slots_with_gt_1_live": <int>,
        "sum_excess_live_rows": <int>,
        "integrity_status": "PASS" | "FAIL",
        "measured_via": "by_construction" | "replay_backfill",
    }
    correctness.integrity_status = "PASS" | "FAIL"
    correctness.Precision_ignoring_integrity = <original Precision>

Existing numeric fields are LEFT ALONE (so the F13 rollup remains
comparable). The summary renderers read integrity_status and print
"INTEGRITY FAIL" in place of the number where appropriate.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import time
from typing import Any, Dict, Optional, Tuple

import psycopg


_HERE = os.path.dirname(os.path.abspath(__file__))
_DRIVER = os.path.normpath(os.path.join(_HERE, "..", "driver"))
sys.path.insert(0, _DRIVER)
from replay_dataset import (  # noqa: E402
    _integrity_summary,
    full_reset,
    load_trace,
    measure_survivors,
    register_trace_sources,
)
from correctness import SYSTEM_TABLE_EXT  # noqa: E402
from ycsb import register_sources  # noqa: E402


# ---- By-construction integrity: cells whose n_gt_1_live is 0 by design ----
#
# KNDB epistemic: F6 advisory xact lock + F8 xmin tiebreak guarantee at
#                  most one live row per (entity, attribute) at every
#                  isolation level. See DECISIONS.md F6/F8/F13.
# pg_trigger:      same lattice as KNDB but through a plpgsql trigger.
#                  Under SR isolation the SELECT FOR UPDATE + heap SSI
#                  aborts one of the racing writers (documented in F4).
# pg_lww at c=1:   single writer, strict trace-order arrival; the RC
#                  atomicity gap requires two concurrent writers.
# pg_conf at c=1:  same reason as pg_lww at c=1.
# pg_mv at c=1:    same.
# pg_llm at c=1:   same.
#
# Everything else (pg_heap always, pg_lww/pg_conf/pg_mv/pg_llm at c>1)
# needs a replay to know the true live-row count.

def integrity_by_construction(system: str, concurrency: int) -> Optional[bool]:
    """
    Returns True if we can PROVE integrity by design (no replay
    needed), False if we CANNOT (must replay), or None to indicate
    "must replay" (kept explicit for readability).
    """
    if system in ("epistemic", "pg_trigger"):
        return True
    if system == "pg_heap":
        # No arbitration ever. n_gt_1_live is always > 0 on a contested
        # workload — but we still WANT the exact count for the paper.
        # So we treat this as "not by construction, replay".
        return None
    if concurrency == 1:
        # Trigger-based baselines are safe with a single writer.
        return True
    return None


# ---- Replay backfill: rerun a cell to measure integrity ----

def replay_cell_integrity(
    dsn: str, system: str, isolation: str, trace_path: str,
    concurrency: int, max_writes_pg_llm: int = 300,
) -> Dict[str, Any]:
    """
    Replay a cell against a fresh cluster and return the integrity
    summary (live_counts distribution over slots at end-of-trace).
    Uses the SAME insert path as replay_dataset.py so numbers are
    directly comparable.
    """
    from concurrent.futures import ThreadPoolExecutor
    import queue
    import threading  # noqa: F401
    from replay_dataset import worker as replay_worker, WorkerStats

    trace = load_trace(trace_path)

    # pg_llm cap.
    if system == "pg_llm" and len(trace) > max_writes_pg_llm:
        # Slot-based subsample matching the driver's own logic.
        import random
        from collections import defaultdict
        rng = random.Random(20260712)
        by_slot: Dict[Tuple[int, str], list] = defaultdict(list)
        for rec in trace:
            by_slot[(rec["entity_id"], rec["attribute"])].append(rec)
        slot_keys = list(by_slot.keys())
        rng.shuffle(slot_keys)
        sampled = []
        for k in slot_keys:
            if len(sampled) >= max_writes_pg_llm:
                break
            sampled.extend(by_slot[k])
        sample_ids = set(id(r) for r in sampled)
        trace = [r for r in trace if id(r) in sample_ids]

    setup = psycopg.connect(dsn, autocommit=True)
    try:
        setup.autocommit = False
        register_sources(setup)
        register_trace_sources(setup, trace)
        full_reset(setup, system)
        setup.autocommit = True
    finally:
        setup.close()

    q: "queue.Queue[Optional[Dict[str, Any]]]" = queue.Queue()
    for rec in trace:
        q.put(rec)
    for _ in range(concurrency):
        q.put(None)

    stats_list = [WorkerStats() for _ in range(concurrency)]

    llm_settings = {
        "bench.fact_llm_p_correct":     "0.925",
        "bench.fact_llm_latency_mean":  "1120",
        "bench.fact_llm_latency_sigma": "0.3662",
        "bench.fact_llm_disable_test":  "0",
        "bench.fact_llm_mode":          "on",
    }

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futs = [
            pool.submit(replay_worker, dsn, system, isolation,
                        q, stats_list[i], i, llm_settings, "on", "on")
            for i in range(concurrency)
        ]
        for f in futs:
            f.result()
    time.sleep(1.0)

    survivor_conn = psycopg.connect(dsn, autocommit=True)
    try:
        _survivors, live_counts = measure_survivors(
            survivor_conn, system, trace)
    finally:
        survivor_conn.close()

    return _integrity_summary(live_counts)


# ---- File pattern ----

CELL_RE = re.compile(
    r"^bookauthor_(?P<sys>[a-z_]+)_c(?P<c>\d{3})_K(?P<K>\d{3})\.json$"
)


def parse_cell_name(name: str) -> Optional[Dict[str, Any]]:
    m = CELL_RE.match(name)
    if not m:
        return None
    return {"system": m.group("sys"), "c": int(m.group("c")),
            "K": int(m.group("K"))}


# ---- Backfill loop ----

def backfill(raw_dir: str, dsn: str, isolation: str, dataset_root: str,
             replay: bool, systems_filter: Optional[list] = None
             ) -> int:
    files = sorted(os.listdir(raw_dir))
    n_updated = 0
    for fname in files:
        info = parse_cell_name(fname)
        if not info:
            continue
        if systems_filter and info["system"] not in systems_filter:
            continue
        path = os.path.join(raw_dir, fname)
        with open(path) as f:
            d = json.load(f)

        corr = d.get("correctness") or {}
        if "integrity_status" in corr and "integrity" in corr:
            # Already backfilled and up-to-date.
            existing = corr.get("integrity") or {}
            if existing.get("measured_via"):
                continue

        system = info["system"]
        c = info["c"]
        K = info["K"]

        by_ctor = integrity_by_construction(system, c)
        if by_ctor:
            integrity = {
                "n_live_slots": corr.get("all_slots", 100),
                "max_live_rows_per_slot": 1,
                "mean_live_rows_per_slot": 1.0,
                "n_slots_with_gt_1_live": 0,
                "sum_excess_live_rows": 0,
                "integrity_status": "PASS",
                "measured_via": "by_construction",
                "construction_reason": (
                    "KNDB F6 advisory xact lock + F8 xmin tiebreak"
                    if system == "epistemic"
                    else "pg_trigger lattice + SR isolation SSI aborts"
                    if system == "pg_trigger"
                    else "single writer, no concurrent race"
                ),
            }
        elif replay:
            trace_path = os.path.join(
                dataset_root, f"normalized_K{K:03d}.jsonl")
            if not os.path.exists(trace_path):
                print(f"[skip] no trace at {trace_path}", file=sys.stderr)
                continue
            print(f"[replay] {fname}", flush=True)
            try:
                integrity = replay_cell_integrity(
                    dsn, system, isolation, trace_path, c)
                integrity["measured_via"] = "replay_backfill"
            except Exception as e:  # noqa: BLE001
                print(f"[error] {fname}: {e}", file=sys.stderr)
                continue
        else:
            print(f"[skip-replay] {fname} needs replay; --replay not set",
                  file=sys.stderr)
            continue

        # Retain the original Precision under the "_ignoring_integrity"
        # name; do not clobber the numeric field so downstream diffs
        # against F13 remain readable.
        if "Precision" in corr and "Precision_ignoring_integrity" not in corr:
            corr["Precision_ignoring_integrity"] = corr["Precision"]
        if "AA" in corr and "AA_ignoring_integrity" not in corr:
            corr["AA_ignoring_integrity"] = corr["AA"]
        corr["integrity"] = integrity
        corr["integrity_status"] = integrity["integrity_status"]
        d["correctness"] = corr
        with open(path, "w") as f:
            json.dump(d, f, indent=2, sort_keys=True, default=str)
        n_updated += 1
    return n_updated


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=os.path.join(
        _HERE, "..", "results", "stage3_raw"))
    ap.add_argument("--dsn",
                    default=os.environ.get(
                        "YCSB_DSN",
                        "host=/tmp/kndb_pg18_test port=55480 dbname=postgres"))
    ap.add_argument("--isolation", default="SR")
    ap.add_argument("--dataset-root",
                    default=os.path.join(
                        _HERE, "..", "datasets", "bookauthor"))
    ap.add_argument("--replay", action="store_true",
                    help="actually replay cells needing measurement")
    ap.add_argument("--systems", default=None,
                    help="comma-separated system filter (e.g. pg_heap,pg_lww)")
    args = ap.parse_args()

    systems_filter = args.systems.split(",") if args.systems else None
    n = backfill(os.path.abspath(args.raw), args.dsn, args.isolation,
                 os.path.abspath(args.dataset_root),
                 args.replay, systems_filter)
    print(f"wrote integrity metadata into {n} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
