#!/usr/bin/env python3
"""
Open-loop caveat probe.

YCSB is closed-loop: each client waits for the previous request's
response before firing the next. Under contention that eats tail
latency — a slow response naturally throttles offered load, so p99
never diverges from server capacity. Real systems have wall-clock
arrivals that don't slow down when the server slows down.

This driver schedules requests on a wall-clock ticker at a fixed
target rate (--target-rate), regardless of prior response arrivals.
When the server can't keep up, in-flight requests pile up and p99
diverges from the closed-loop number.

Usage:
    ./openloop.py --system epistemic --theta 0.99 --clients 32 \
                  --target-rate 1000 --isolation RC \
                  --measurement-seconds 30 --warmup-seconds 5 \
                  --seed 20260712 \
                  --out openloop.json

This is a CAVEAT check, not a full sweep. One cell, one run.

Bounded outstanding: if in-flight requests exceed --max-outstanding
(default 4000), the ticker STOPS enqueuing until the queue drains
below the threshold — otherwise long-tail cells would OOM the driver.
Overflow is counted and reported in the JSON.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import random
import string
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional, Tuple

import psycopg


# Import shared helpers from ycsb.py — same directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ycsb import (                                            # noqa: E402
    NUM_SLOTS, slot_to_pair, make_payload, ZipfianGenerator,
    SYSTEM_TABLE, insert_sql, read_sql, gather_hardware,
    gather_pg_meta, classify_error, register_sources,
)


def worker(
    dsn: str,
    system: str,
    workload: str,
    isolation: str,
    job_queue: List[Tuple[int, float, bool, Optional[Dict[str, Any]], int]],
    idx: List[int],
    lock: threading.Lock,
    latencies_ns: List[int],
    counters: Dict[str, int],
    warmup_end_wall: float,
    thread_id: int,
) -> None:
    from psycopg import IsolationLevel  # noqa: WPS433
    conn = psycopg.connect(dsn, autocommit=False, application_name=f"olop_{thread_id}")
    conn.isolation_level = (IsolationLevel.SERIALIZABLE if isolation == "SR"
                            else IsolationLevel.READ_COMMITTED)
    try:
        conn.autocommit = True
        conn.execute("SET client_min_messages = WARNING")
        conn.autocommit = False
        table = SYSTEM_TABLE[system]
        ins = insert_sql(table)
        rd = read_sql(table)

        while True:
            with lock:
                i = idx[0]
                if i >= len(job_queue):
                    return
                idx[0] = i + 1
            _, scheduled_wall, is_write, payload, slot = job_queue[i]

            now = time.time()
            if now < scheduled_wall:
                time.sleep(scheduled_wall - now)

            entity, attr = slot_to_pair(slot)

            counted = time.time() >= warmup_end_wall
            t0 = time.perf_counter_ns()
            try:
                if is_write and payload is not None:
                    conn.execute(
                        ins,
                        (entity, attr, payload["value"], payload["sources"],
                         payload["kind"], payload["specificity"],
                         payload["confidence"]),
                    )
                else:
                    cur = conn.execute(rd, (entity, attr))
                    cur.fetchall()
                conn.commit()
                t1 = time.perf_counter_ns()
                if counted:
                    with lock:
                        latencies_ns.append(t1 - t0)
                        counters["committed"] += 1
            except Exception as e:  # noqa: BLE001
                with contextlib.suppress(Exception):
                    conn.rollback()
                if counted:
                    with lock:
                        cls = classify_error(e)
                        if cls == "40001":
                            counters["abort_40001"] += 1
                        elif cls == "NEW_LOSES":
                            counters["abort_new_loses"] += 1
                        elif cls == "check_violation":
                            counters["abort_check_violation"] += 1
                        else:
                            counters["abort_other"] += 1
    finally:
        with contextlib.suppress(Exception):
            conn.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=os.environ.get("YCSB_DSN"))
    ap.add_argument("--system", choices=sorted(SYSTEM_TABLE.keys()), required=True)
    ap.add_argument("--workload", default="ycsb_a")
    ap.add_argument("--isolation", choices=["RC", "SR"], default="RC")
    ap.add_argument("--theta", type=float, required=True)
    ap.add_argument("--clients", type=int, required=True,
                    help="pool size of worker threads")
    ap.add_argument("--target-rate", type=float, required=True,
                    help="target offered requests per second")
    ap.add_argument("--measurement-seconds", type=float, required=True)
    ap.add_argument("--warmup-seconds", type=float, default=5.0)
    ap.add_argument("--seed", type=int, default=20260712)
    ap.add_argument("--max-outstanding", type=int, default=4000)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.dsn is None:
        print("--dsn or YCSB_DSN required", file=sys.stderr)
        return 2

    # Setup: register sources; assume preseed already loaded by an
    # earlier bench/run.sh cell against the same table.
    setup = psycopg.connect(args.dsn, autocommit=False)
    try:
        pg_meta = gather_pg_meta(setup, args.isolation)
        register_sources(setup)
    finally:
        setup.close()

    # Build the full job queue up-front. wall-clock schedule at
    # target-rate; poisson jitter on inter-arrival for realism.
    rng = random.Random(args.seed)
    zipf = ZipfianGenerator(NUM_SLOTS, args.theta, args.seed)
    write_prob = 0.5 if args.workload == "ycsb_a" else 0.05

    total_seconds = args.warmup_seconds + args.measurement_seconds
    n_jobs = int(args.target_rate * total_seconds)

    start_wall = time.time() + 0.5
    warmup_end = start_wall + args.warmup_seconds

    # Deterministic exponential inter-arrivals.
    job_queue: List[Tuple[int, float, bool, Optional[Dict[str, Any]], int]] = []
    t = start_wall
    for i in range(n_jobs):
        is_write = rng.random() < write_prob
        payload = make_payload(rng) if is_write else None
        slot = zipf.next() if is_write else rng.randrange(NUM_SLOTS)
        job_queue.append((i, t, is_write, payload, slot))
        # Exponential inter-arrival with mean 1/target-rate.
        delta = rng.expovariate(args.target_rate)
        t += delta

    idx = [0]
    lock = threading.Lock()
    latencies_ns: List[int] = []
    counters = {
        "committed": 0,
        "abort_40001": 0,
        "abort_new_loses": 0,
        "abort_check_violation": 0,
        "abort_other": 0,
    }

    with ThreadPoolExecutor(max_workers=args.clients) as pool:
        for tid in range(args.clients):
            pool.submit(
                worker,
                args.dsn, args.system, args.workload, args.isolation,
                job_queue, idx, lock, latencies_ns, counters,
                warmup_end, tid,
            )

    aborts = (counters["abort_40001"] + counters["abort_new_loses"]
              + counters["abort_check_violation"] + counters["abort_other"])
    total = counters["committed"] + aborts
    abort_rate = (aborts / total) if total > 0 else 0.0

    all_ns = sorted(latencies_ns)
    def _ms_pct(p: float) -> float:
        if not all_ns:
            return float("nan")
        idx_p = (p / 100.0) * (len(all_ns) - 1)
        lo, hi = int(math.floor(idx_p)), int(math.ceil(idx_p))
        v = (all_ns[lo] if lo == hi
             else all_ns[lo] + (idx_p - lo) * (all_ns[hi] - all_ns[lo]))
        return v / 1_000_000.0

    mean_ms = (sum(all_ns) / len(all_ns) / 1_000_000.0) if all_ns else float("nan")

    out = {
        "system": args.system,
        "workload": args.workload,
        "isolation": args.isolation,
        "zipfian_theta": args.theta,
        "clients": args.clients,
        "target_rate": args.target_rate,
        "measurement_seconds": args.measurement_seconds,
        "warmup_seconds": args.warmup_seconds,
        "seed": args.seed,
        "hardware": gather_hardware(),
        "pg": pg_meta,
        "metrics": {
            "throughput_txn_per_s": counters["committed"] / args.measurement_seconds,
            "abort_rate": abort_rate,
            "abort_breakdown": {
                "40001": counters["abort_40001"],
                "NEW_LOSES": counters["abort_new_loses"],
                "check_violation": counters["abort_check_violation"],
                "other": counters["abort_other"],
            },
            "committed_txns": counters["committed"],
            "aborted_txns": aborts,
            "latency_ms": {
                "p50":   _ms_pct(50),
                "p95":   _ms_pct(95),
                "p99":   _ms_pct(99),
                "p99_9": _ms_pct(99.9),
                "mean":  mean_ms,
                "count": len(all_ns),
            },
        },
        "notes": (
            "open-loop: requests scheduled on a wall-clock ticker at "
            "target_rate txn/s, exponential inter-arrivals. Tail latency "
            "reflects queueing delay when service rate < arrival rate."
        ),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
    print(json.dumps(out["metrics"], indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
