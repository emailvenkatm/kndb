#!/usr/bin/env python3
"""
YCSB-style closed-loop microbenchmark driver for the KNDB epistemic PoC.

Three target systems, same schema shape, same client mix:
  * epistemic — fact_ep, USING epistemic (F1..F8 AM path)
  * pg_heap   — fact_heap, plain heap, no enforcement
  * pg_trigger — fact_trig, plain heap + BEFORE INSERT trigger
                 reimplementing R1..R5 + precedence + audit

Closed-loop: each client thread waits for its previous txn to complete
(commit or abort) before firing the next. This UNDERSTATES tail latency
vs an open-loop generator; that caveat is stamped into every JSON's
`notes` field. See the report for the open-loop probe.

Workload:
  * Population = 100k slots, keyed (entity_id, attribute).
    Slots are numbered 0..99999; entity_id = slot // 32,
    attribute = 'a' || (slot % 32). This makes the 100k slots span
    ~3125 entities × 32 attributes, matching the AM's per-slot
    advisory-lock tag (LOCKTAG_ADVISORY with key1=entity_id,
    key2=hash_bytes(attribute)).
  * Reads pick a slot UNIFORMLY (per YCSB core spec).
  * Writes pick a slot via a seeded Zipfian generator; theta=0 is
    uniform, theta=0.99 is the classic YCSB hot-spot.
  * Write payload: value = 40-char printable ASCII, kind chosen from
    {INFERRED 70%, MEASURED 20%, DERIVED 10%}, specificity uniform in
    [0, 255], confidence uniform in [0.0, 1.0) for INFERRED else 1.0.
  * Warm-up window then a fixed measurement window.

Metrics:
  * Throughput (successful txns/s over the measurement window).
  * Abort rate + breakdown (40001 / NEW_LOSES / check_violation / other).
  * Latency histogram (p50, p95, p99, p99.9, mean, count).

Fixed seed by default so the workload trace is reproducible.

Usage:
    ./ycsb.py --system epistemic --workload ycsb_a --theta 0.99 \\
              --clients 32 --isolation RC --measurement-seconds 30 \\
              --warmup-seconds 5 --seed 20260712 --run-index 0 \\
              --out results/raw/foo.json
"""

from __future__ import annotations

import argparse
import bisect
import contextlib
import json
import math
import os
import platform
import random
import string
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional, Tuple

import psycopg
from psycopg import errors as psycopg_errors


# -------------------------------------------------------------------------
# Zipfian generator (YCSB-compatible)
# -------------------------------------------------------------------------
#
# YCSB uses the classic Gray et al. 1994 "Quickly Generating Billion-Record
# Synthetic Databases" rejection sampler. We reimplement it below rather
# than pull in scipy for a benchmark that has to run in a venv.
#
# Reference: cornerstones/YCSB core/src/main/java/site/ycsb/generator/
#            ZipfianGenerator.java. Same constants (ZETAN, zeta2theta,
#            eta, alpha) are computed here.

class ZipfianGenerator:
    """
    Zipfian generator matching YCSB's core ZipfianGenerator.
    Draws integers in [0, n) with P(k) proportional to 1/(k+1)^theta.

    theta = 0.0 -> uniform.
    theta = 0.99 -> classic YCSB hot-spot workload.
    theta > 1.0 not supported (harmonic diverges).
    """

    ZETAN_CACHE: Dict[Tuple[int, float], float] = {}

    def __init__(self, n: int, theta: float, seed: int):
        if n <= 0:
            raise ValueError("n must be positive")
        if theta < 0.0:
            raise ValueError("theta must be non-negative")
        self.n = n
        self.theta = theta
        self.rng = random.Random(seed)

        if theta == 0.0:
            # Degenerate: uniform sampling. Skip the expensive zeta.
            self.uniform = True
            return
        self.uniform = False

        # Precompute normalisation constants. YCSB uses zeta(n, theta),
        # zeta(2, theta), and derived eta and alpha.
        key = (n, round(theta, 12))
        if key in self.ZETAN_CACHE:
            self.zetan = self.ZETAN_CACHE[key]
        else:
            self.zetan = _compute_zeta(n, theta)
            self.ZETAN_CACHE[key] = self.zetan
        self.zeta2 = _compute_zeta(2, theta)
        self.alpha = 1.0 / (1.0 - theta)
        self.eta = (
            (1.0 - (2.0 / n) ** (1.0 - theta))
            / (1.0 - self.zeta2 / self.zetan)
        )

    def next(self) -> int:
        if self.uniform:
            return self.rng.randrange(self.n)
        u = self.rng.random()
        uz = u * self.zetan
        if uz < 1.0:
            return 0
        if uz < 1.0 + 0.5 ** self.theta:
            return 1
        return min(
            self.n - 1,
            int(self.n * (self.eta * u - self.eta + 1.0) ** self.alpha),
        )


def _compute_zeta(n: int, theta: float) -> float:
    """Sum 1/i^theta for i=1..n. Cache in caller for reuse."""
    z = 0.0
    for i in range(1, n + 1):
        z += 1.0 / (i ** theta)
    return z


# -------------------------------------------------------------------------
# Workload configuration
# -------------------------------------------------------------------------

# 100k slots laid out over ~3125 entities × 32 attributes each.
NUM_SLOTS = 100_000
ATTRS_PER_ENTITY = 32

ATTRIBUTES = [f"a{i}" for i in range(ATTRS_PER_ENTITY)]


def slot_to_pair(slot: int) -> Tuple[int, str]:
    return (slot // ATTRS_PER_ENTITY, ATTRIBUTES[slot % ATTRS_PER_ENTITY])


# Kind distribution: 70% INFERRED, 20% MEASURED, 10% DERIVED.
KIND_CDF: List[Tuple[float, str]] = [
    (0.70, "INFERRED"),
    (0.90, "MEASURED"),
    (1.00, "DERIVED"),
]


def pick_kind(rng: random.Random) -> str:
    u = rng.random()
    for cutoff, k in KIND_CDF:
        if u < cutoff:
            return k
    return "DERIVED"


# Sources registered by the runner in epistemic.source_registry. R2
# requires INFERRED/DERIVED writes to provide at least one registered
# source; MEASURED short-circuits R2 to true (per src/epistemic_rules.c:157).
NUM_SOURCES = 10
SOURCE_IDS = [f"src_{i}" for i in range(NUM_SOURCES)]


def make_payload(rng: random.Random) -> Dict[str, Any]:
    kind = pick_kind(rng)
    val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
    spec = rng.randint(0, 255)
    if kind == "INFERRED":
        conf = rng.random()  # [0, 1)
        sources = [SOURCE_IDS[rng.randrange(NUM_SOURCES)]]
    elif kind == "DERIVED":
        conf = 1.0
        sources = [SOURCE_IDS[rng.randrange(NUM_SOURCES)]]
    else:  # MEASURED
        conf = 1.0
        sources = None  # R3 requires MEASURED to have no sources.
    return {
        "value": val,
        "kind": kind,
        "specificity": spec,
        "confidence": conf,
        "sources": sources,
    }


# -------------------------------------------------------------------------
# System dispatch: table name + insert SQL per target system
# -------------------------------------------------------------------------

SYSTEM_TABLE = {
    "epistemic": "fact_ep",
    "pg_heap":   "fact_heap",
    "pg_trigger": "fact_trig",
}


def insert_sql(table: str) -> str:
    # 'sources' is either NULL (MEASURED) or a text[] literal — psycopg
    # adapts Python `list` -> text[] automatically.
    return (
        f"INSERT INTO {table} "
        f"(entity_id, attribute, value, sources, valid_time, "
        f" ep_kind, ep_specificity, ep_confidence) "
        f"VALUES (%s, %s, %s, %s, "
        f"        tstzrange('2026-01-01'::timestamptz, 'infinity'::timestamptz), "
        f"        %s::epistemic.epistemic_kind, %s::int2, %s::real)"
    )


def read_sql(table: str) -> str:
    return (
        f"SELECT value FROM {table} "
        f"WHERE entity_id = %s AND attribute = %s "
        f"  AND upper(sys_time) = 'infinity'::timestamptz "
        f"LIMIT 1"
    )


# -------------------------------------------------------------------------
# Preseed
# -------------------------------------------------------------------------

def register_sources(conn: psycopg.Connection) -> None:
    """Ensure every source_id the workload uses is registered (R2)."""
    with conn.cursor() as cur:
        for sid in SOURCE_IDS:
            cur.execute(
                "INSERT INTO epistemic.source_registry (source_id, source_type) "
                "VALUES (%s, 'bench') ON CONFLICT DO NOTHING",
                (sid,))
    conn.commit()


def reset_workload_state(conn: psycopg.Connection, system: str) -> None:
    """
    Cheap reset between cells: keep the preseeded rows and only remove
    the workload-added state (newer rows + closed sys_time bounds).
    Idempotent identification: preseed rows have specificity=0 AND
    confidence=0.5 AND kind=INFERRED. Workload writes never match all
    three (specificity is uniform in [0,255], INFERRED confidence is
    uniform in [0,1) so equal-to-0.5 has measure zero).

    * DELETE all rows that don't match the preseed signature.
    * UPDATE any closed sys_time back to (lower, infinity).
    * TRUNCATE epistemic.evicted_fact.

    tuple_delete and tuple_update are heap's on the epistemic AM
    (README, "What delegates to heap"), so this reset does not go
    through the R1..R5 code path.
    """
    table = SYSTEM_TABLE[system]
    with conn.cursor() as cur:
        cur.execute(
            f"DELETE FROM {table} "
            f"WHERE NOT (ep_kind::text = 'INFERRED' "
            f"           AND ep_specificity = 0 "
            f"           AND ep_confidence = 0.5)")
        cur.execute(
            f"UPDATE {table} SET sys_time = tstzrange(lower(sys_time), 'infinity') "
            f"WHERE upper(sys_time) <> 'infinity'::timestamptz")
        cur.execute("TRUNCATE epistemic.evicted_fact")
    conn.commit()
    # VACUUM cannot run inside a transaction.
    was_autocommit = conn.autocommit
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(f"VACUUM {table}")
    finally:
        conn.autocommit = was_autocommit


def _preseed_row(rng: random.Random, slot: int) -> Tuple[Any, ...]:
    entity, attr = slot_to_pair(slot)
    val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
    # (entity, attr, value, sources, kind, specificity, confidence)
    return (entity, attr, val, [SOURCE_IDS[0]], "INFERRED", 0, 0.5)


def preseed(conn: psycopg.Connection, system: str, seed: int) -> None:
    """
    Load NUM_SLOTS rows, one per slot. Preseed uses kind=INFERRED
    (sources=['src_0'], confidence=0.5, specificity=0) — the LOWEST
    rank in the precedence lattice, so subsequent workload writes
    always have a chance to compete:

      * MEASURED writes (rank 3) always outrank an INFERRED incumbent
        -> evict.
      * DERIVED writes (rank 2) always outrank INFERRED -> evict.
      * INFERRED writes (rank 1) tie at kind, then specificity (0..255
        vs 0 -> mostly outranks), then confidence -> mixed evict /
        NEW_LOSES.

    Uses `COPY FROM STDIN` for speed. Note: COPY on the epistemic table
    BYPASSES the AM's tuple_insert callback because the AM does not
    override `multi_insert` (it delegates to heap's). This is a known
    finding — COPY is a bypass channel we deliberately exploit here to
    reset table state cheaply between cells. Preseed rows are chosen
    to pass R1..R5 anyway, so no correctness envelope is crossed by
    this bench-only bypass.

    For the trigger baseline the trigger runs per-row inside COPY (PG's
    BEFORE INSERT trigger fires from within multi_insert), so that path
    is NOT bypassed — trigger preseed is fully rule-checked and thus
    slow. This asymmetry is a real cost of the trigger approach and
    it's the same asymmetry the bench measures during the workload.
    """
    table = SYSTEM_TABLE[system]
    rng = random.Random(seed ^ 0xF0F0F0F0)

    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {table}")
        cur.execute("TRUNCATE epistemic.evicted_fact")
    conn.commit()

    # Rebuild the row list once — reproducible per seed.
    rows = [_preseed_row(rng, slot) for slot in range(NUM_SLOTS)]

    valid_time_lit = "[\"2026-01-01\",infinity)"
    sys_time_lit = None  # let DEFAULT tstzrange(now(), 'infinity') fire

    if system == "pg_trigger":
        # COPY runs BEFORE INSERT triggers, so this pays the full
        # per-row plpgsql cost. There's no way around it short of
        # temporarily dropping the trigger, which would be a different
        # test. We accept the slow preseed.
        _preseed_trigger_copy(conn, table, rows, valid_time_lit)
    else:
        _preseed_copy(conn, table, rows, valid_time_lit)

    with conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {table}")
        row = cur.fetchone()
        assert row is not None
        n = row[0]
    if n < NUM_SLOTS:
        raise RuntimeError(
            f"preseed short: expected {NUM_SLOTS} rows in {table}, got {n}."
        )
    conn.commit()


def _preseed_copy(conn: psycopg.Connection, table: str,
                  rows: List[Tuple[Any, ...]], valid_time_lit: str) -> None:
    """
    COPY-based preseed. On epistemic tables this bypasses the AM
    callback via heap's multi_insert; the resulting rows are heap
    tuples equivalent to what the AM would have written for the
    same content.
    """
    # We write: entity_id, attribute, value, sources, valid_time,
    # ep_kind, ep_specificity, ep_confidence. sys_time is DEFAULT so
    # we omit it from the column list and PG fills it.
    copy_sql = (
        f"COPY {table} (entity_id, attribute, value, sources, valid_time, "
        f"ep_kind, ep_specificity, ep_confidence) FROM STDIN"
    )
    with conn.cursor() as cur:
        with cur.copy(copy_sql) as cp:
            for entity, attr, val, sources, kind, spec, conf in rows:
                # sources -> Postgres text[] literal
                src_lit = "{" + ",".join(
                    s.replace('"', '\\"') for s in sources
                ) + "}"
                cp.write_row((entity, attr, val, src_lit, valid_time_lit,
                              kind, spec, conf))
    conn.commit()


def _preseed_trigger_copy(conn: psycopg.Connection, table: str,
                          rows: List[Tuple[Any, ...]],
                          valid_time_lit: str) -> None:
    """
    For pg_trigger, temporarily DISABLE the trigger, load via COPY,
    re-enable. The rows we load are chosen to pass all rule checks
    anyway (INFERRED, sources=['src_0'], conf=0.5) — the trigger
    would accept every one. Disabling for preseed keeps setup cost
    from bloating quadratically as the table fills (the trigger's
    overlap seqscan is O(N) per row -> O(N^2) preseed).

    This is a bench-setup convenience; the workload measurement window
    always runs with the trigger enabled and firing.
    """
    with conn.cursor() as cur:
        cur.execute(f"ALTER TABLE {table} DISABLE TRIGGER fact_trig_before_insert")
    conn.commit()
    try:
        _preseed_copy(conn, table, rows, valid_time_lit)
    finally:
        with conn.cursor() as cur:
            cur.execute(f"ALTER TABLE {table} ENABLE TRIGGER fact_trig_before_insert")
        conn.commit()


# -------------------------------------------------------------------------
# Client worker
# -------------------------------------------------------------------------

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


def classify_error(e: Exception) -> str:
    msg = str(e)
    sqlstate = getattr(e, "sqlstate", None)
    if sqlstate == "40001":
        return "40001"
    if "NEW_LOSES" in msg:
        return "NEW_LOSES"
    if sqlstate == "23514":  # check_violation
        return "check_violation"
    if "check_violation" in msg.lower():
        return "check_violation"
    return "other"


def worker(
    dsn: str,
    system: str,
    workload: str,
    theta: float,
    isolation: str,
    warmup_end_wall: float,
    measurement_end_wall: float,
    seed: int,
    thread_id: int,
    stats: WorkerStats,
    stop_flag: threading.Event,
) -> None:
    """
    Closed-loop client. Loops from now until measurement_end_wall.
    Requests fired between now and warmup_end_wall are NOT counted.
    """
    # Each thread has its own RNG (deterministic given seed + thread_id)
    # and its own Zipfian generator over the write population.
    rng = random.Random(seed ^ (thread_id * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF)
    zipf = ZipfianGenerator(NUM_SLOTS, theta, seed ^ (thread_id * 0xDEADBEEF))
    if workload == "ycsb_a":
        write_prob = 0.5
    elif workload == "ycsb_b":
        write_prob = 0.05
    else:
        raise ValueError(f"unknown workload {workload}")

    table = SYSTEM_TABLE[system]
    ins = insert_sql(table)
    rd = read_sql(table)

    # Persistent connection. Isolation level is set on the connection
    # object rather than via a per-txn BEGIN — psycopg3 with
    # autocommit=False starts an implicit txn on the first execute,
    # which makes an explicit BEGIN either warn ("already in txn") or
    # silently apply the connection default. Setting the property on
    # the connection tells psycopg3 to include ISOLATION LEVEL in the
    # BEGIN it emits.
    from psycopg import IsolationLevel  # noqa: WPS433 — one-time import

    def _open() -> psycopg.Connection:
        c = psycopg.connect(dsn, autocommit=False,
                            application_name=f"ycsb_{thread_id}")
        c.isolation_level = (IsolationLevel.SERIALIZABLE if isolation == "SR"
                             else IsolationLevel.READ_COMMITTED)
        c.autocommit = True
        c.execute("SET client_min_messages = WARNING")
        c.autocommit = False
        return c

    conn = _open()
    try:
        while not stop_flag.is_set():
            now = time.time()
            if now >= measurement_end_wall:
                break
            counted = now >= warmup_end_wall

            is_write = rng.random() < write_prob
            if is_write:
                slot = zipf.next()
                p = make_payload(rng)
            else:
                slot = rng.randrange(NUM_SLOTS)
                p = None

            entity, attr = slot_to_pair(slot)

            t0 = time.perf_counter_ns()
            try:
                if is_write:
                    conn.execute(
                        ins,
                        (entity, attr, p["value"], p["sources"],
                         p["kind"], p["specificity"], p["confidence"]),
                    )
                else:
                    cur = conn.execute(rd, (entity, attr))
                    cur.fetchall()
                conn.commit()
                t1 = time.perf_counter_ns()
                if counted:
                    stats.throughput_txns += 1
                    stats.latencies_ns.append(t1 - t0)
            except Exception as e:  # noqa: BLE001 — we classify below
                # Roll back and classify. Aborted txns count against
                # abort_rate but do NOT contribute a latency sample:
                # measurement-side, an aborted txn is loss-of-work.
                try:
                    conn.rollback()
                except Exception:
                    # Connection may be broken; reconnect.
                    try:
                        conn.close()
                    except Exception:
                        pass
                    conn = _open()

                if counted:
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


# -------------------------------------------------------------------------
# Aggregation
# -------------------------------------------------------------------------

def percentile(sorted_vals: List[int], p: float) -> float:
    if not sorted_vals:
        return float("nan")
    if p <= 0:
        return float(sorted_vals[0])
    if p >= 100:
        return float(sorted_vals[-1])
    idx = (p / 100.0) * (len(sorted_vals) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return float(sorted_vals[lo])
    frac = idx - lo
    return sorted_vals[lo] + frac * (sorted_vals[hi] - sorted_vals[lo])


def aggregate(
    per_worker: List[WorkerStats],
    measurement_seconds: float,
) -> Dict[str, Any]:
    total_success = sum(w.throughput_txns for w in per_worker)
    total_40001 = sum(w.abort_40001 for w in per_worker)
    total_nl    = sum(w.abort_new_loses for w in per_worker)
    total_cv    = sum(w.abort_check_violation for w in per_worker)
    total_oth   = sum(w.abort_other for w in per_worker)
    total_abort = total_40001 + total_nl + total_cv + total_oth
    total_txns  = total_success + total_abort
    abort_rate  = (total_abort / total_txns) if total_txns > 0 else 0.0

    all_lat_ns: List[int] = []
    for w in per_worker:
        all_lat_ns.extend(w.latencies_ns)
    all_lat_ns.sort()

    if all_lat_ns:
        mean_ns = sum(all_lat_ns) / len(all_lat_ns)
    else:
        mean_ns = float("nan")

    def _ms(ns: float) -> float:
        return float("nan") if math.isnan(ns) else ns / 1_000_000.0

    return {
        "throughput_txn_per_s": total_success / measurement_seconds,
        "abort_rate": abort_rate,
        "abort_breakdown": {
            "40001": total_40001,
            "NEW_LOSES": total_nl,
            "check_violation": total_cv,
            "other": total_oth,
        },
        "committed_txns": total_success,
        "aborted_txns": total_abort,
        "latency_ms": {
            "p50":   _ms(percentile(all_lat_ns, 50)),
            "p95":   _ms(percentile(all_lat_ns, 95)),
            "p99":   _ms(percentile(all_lat_ns, 99)),
            "p99_9": _ms(percentile(all_lat_ns, 99.9)),
            "mean":  _ms(mean_ns),
            "count": len(all_lat_ns),
        },
    }


# -------------------------------------------------------------------------
# GUC + hardware inspection
# -------------------------------------------------------------------------

def gather_pg_meta(conn: psycopg.Connection, isolation: str) -> Dict[str, Any]:
    def _show(name: str) -> str:
        cur = conn.execute(f"SHOW {name}")
        row = cur.fetchone()
        return "" if row is None else str(row[0])
    return {
        "version": _show("server_version"),
        "shared_buffers": _show("shared_buffers"),
        "max_connections": int(_show("max_connections")),
        "max_locks_per_transaction": int(_show("max_locks_per_transaction")),
        "synchronous_commit": _show("synchronous_commit"),
        "wal_level": _show("wal_level"),
        "isolation": isolation,
    }


def gather_hardware() -> Dict[str, Any]:
    ram_gb = 0
    try:
        import subprocess
        out = subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip()
        ram_gb = int(out) // (1024 ** 3)
    except Exception:
        pass
    return {
        "os": f"{platform.system()} {platform.release()}",
        "cpu": platform.processor() or platform.machine(),
        "cores": os.cpu_count() or -1,
        "ram_gb": ram_gb,
    }


# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__ or "",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default=os.environ.get("YCSB_DSN"))
    ap.add_argument("--system", choices=sorted(SYSTEM_TABLE.keys()), required=True)
    ap.add_argument("--workload", choices=["ycsb_a", "ycsb_b"], required=True)
    ap.add_argument("--isolation", choices=["RC", "SR"], required=True)
    ap.add_argument("--theta", type=float, required=True)
    ap.add_argument("--clients", type=int, required=True)
    ap.add_argument("--measurement-seconds", type=float, required=True)
    ap.add_argument("--warmup-seconds", type=float, default=5.0)
    ap.add_argument("--seed", type=int, default=20260712)
    ap.add_argument("--run-index", type=int, default=0)
    ap.add_argument("--out", required=True,
                    help="path to write metrics JSON (parent dir must exist)")
    ap.add_argument("--skip-preseed", action="store_true",
                    help="assume the target table is already loaded")
    ap.add_argument("--reset-between-cells", action="store_true",
                    help="DELETE workload-added rows + un-close sys_time "
                         "before running (cheap; keeps preseed rows)")
    ap.add_argument("--preseed-only", action="store_true",
                    help="preseed the target table and exit; do not run "
                         "the workload")
    args = ap.parse_args()

    if args.dsn is None:
        print("--dsn or YCSB_DSN required", file=sys.stderr)
        return 2

    setup_conn = psycopg.connect(args.dsn, autocommit=True)
    try:
        pg_meta = gather_pg_meta(setup_conn, args.isolation)
        # Source registry must exist before preseed *or* first workload
        # write. Register unconditionally — ON CONFLICT DO NOTHING makes
        # it a no-op if already registered.
        setup_conn.autocommit = False
        register_sources(setup_conn)
        if not args.skip_preseed:
            preseed(setup_conn, args.system, args.seed)
        elif args.reset_between_cells:
            reset_workload_state(setup_conn, args.system)
        setup_conn.autocommit = True
    finally:
        setup_conn.close()

    if args.preseed_only:
        print(f"preseed-only: {args.system} loaded", file=sys.stderr)
        return 0

    stop_flag = threading.Event()
    stats_list = [WorkerStats() for _ in range(args.clients)]

    start_wall = time.time() + 0.5  # small takeoff slack
    warmup_end = start_wall + args.warmup_seconds
    measurement_end = warmup_end + args.measurement_seconds

    with ThreadPoolExecutor(max_workers=args.clients) as pool:
        for tid in range(args.clients):
            pool.submit(
                worker,
                args.dsn, args.system, args.workload, args.theta,
                args.isolation, warmup_end, measurement_end,
                args.seed, tid, stats_list[tid], stop_flag,
            )

        # Wait until measurement_end + a small grace before shutting down.
        try:
            while time.time() < measurement_end:
                time.sleep(0.2)
        finally:
            stop_flag.set()

    metrics = aggregate(stats_list, args.measurement_seconds)

    out = {
        "system": args.system,
        "workload": args.workload,
        "isolation": args.isolation,
        "zipfian_theta": args.theta,
        "clients": args.clients,
        "measurement_seconds": args.measurement_seconds,
        "warmup_seconds": args.warmup_seconds,
        "seed": args.seed,
        "run_index": args.run_index,
        "hardware": gather_hardware(),
        "pg": pg_meta,
        "metrics": metrics,
        "notes": (
            "closed-loop; each client waits for response before next request. "
            "Understates tail latency vs open-loop; see bench/README.md."
        ),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)

    print(json.dumps(out["metrics"], indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
