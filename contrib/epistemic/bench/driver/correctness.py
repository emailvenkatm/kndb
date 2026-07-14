#!/usr/bin/env python3
"""
Stage 2: correctness axis for the KNDB epistemic bench.

Runs one cell (system, workload, isolation, theta, clients, kind_mix)
and reports:
  * Throughput / abort rate / latency  (control axis, same as Stage 1)
  * Correctness rate: fraction of CONTESTED slots whose actual live
    survivor matches the lattice-predicted winner.
  * Goodput = throughput * (1 - abort_rate) * correctness_rate.

Lattice predicted winner: computed OFFLINE from the full write trace.
Every INSERT the workload attempts is logged deterministically (per
thread) to a per-client Python list; the driver merges them into a
single trace ordered by wall-clock timestamp, and walks slot-by-slot
applying the F1..F8 lattice:

  1. kind rank: MEASURED (3) > DERIVED (2) > INFERRED (1).
     Higher rank always beats lower.
  2. ep_specificity: higher wins on same rank.
  3. ep_confidence: higher wins on same rank + specificity.
  4. True tie (kind, specificity, confidence all equal):
     first-committer-wins (earliest arrival in the trace).

Contested slots are those with ≥2 distinct-content writes (either
distinct value, kind, spec, or conf). Uncontested slots are excluded
from the correctness numerator.

Every trigger baseline exposes disable-and-test via a GUC:
   bench.fact_conf_mode         'on' / 'off'
   bench.fact_mv_mode           'on' / 'off'
   bench.fact_llm_mode          'on' / 'off'
   bench.fact_llm_disable_test  '0' / '1'   (forces P_correct=0.5)
   bench.fact_llm_p_correct     e.g. '0.65'

For KNDB epistemic the disable-and-test is external: run pg_heap
against the same workload. pg_heap has no arbitration, so its
"survivor" for every slot is whichever heap row happens to be visible
last — effectively LWW. That is the meaningful lattice-off comparator.

USAGE:
    ./correctness.py --system pg_lww --kind-mix moderate \\
                     --theta 0.9 --clients 8 --isolation RC \\
                     --measurement-seconds 30 --seed 20260712 \\
                     --run-index 0 --out out.json
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
from psycopg import IsolationLevel

# Reuse the Stage 1 building blocks (Zipfian, kind mix, source registry,
# preseed, reset). We only extend, never rewrite.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from ycsb import (  # noqa: E402  — import order forced by sys.path insert
    ATTRIBUTES,
    ATTRS_PER_ENTITY,
    NUM_SLOTS,
    NUM_SOURCES,
    SOURCE_IDS,
    ZipfianGenerator,
    aggregate,
    classify_error,
    gather_hardware,
    gather_pg_meta,
    percentile,
    read_sql,
    register_sources,
    reset_workload_state as _stage1_reset,
    slot_to_pair,
)
from ycsb import WorkerStats as _Stage1WorkerStats  # noqa: E402


# -------------------------------------------------------------------------
# Extended system dispatch: adds pg_lww, pg_conf, pg_mv, pg_llm.
# -------------------------------------------------------------------------

SYSTEM_TABLE_EXT = {
    "epistemic":  "fact_ep",
    "pg_heap":    "fact_heap",
    "pg_trigger": "fact_trig",
    "pg_lww":     "fact_lww",
    "pg_conf":    "fact_conf",
    "pg_mv":      "fact_mv",
    "pg_llm":     "fact_llm",
}

# Additional tables that some baselines need to reset alongside the fact
# table. Kept in a dict-of-tuples to avoid asymmetric-case boilerplate.
AUX_TABLES = {
    "pg_mv": ("fact_mv_votes",),
}


def insert_sql_ext(system: str) -> str:
    """SQL to write one row. All baselines use plain INSERT; the
    trigger (or the AM) decides what to do with it."""
    table = SYSTEM_TABLE_EXT[system]
    return (
        f"INSERT INTO {table} "
        f"(entity_id, attribute, value, sources, valid_time, "
        f" ep_kind, ep_specificity, ep_confidence) "
        f"VALUES (%s, %s, %s, %s, "
        f"        tstzrange('2026-01-01'::timestamptz, 'infinity'::timestamptz), "
        f"        %s::epistemic.epistemic_kind, %s::int2, %s::real)"
    )


def read_sql_ext(system: str) -> str:
    return (
        f"SELECT value FROM {SYSTEM_TABLE_EXT[system]} "
        f"WHERE entity_id = %s AND attribute = %s "
        f"  AND upper(sys_time) = 'infinity'::timestamptz "
        f"LIMIT 1"
    )


# -------------------------------------------------------------------------
# Kind mix knob.
# -------------------------------------------------------------------------
#
# Stage 1 used a fixed 70/20/10 = INFERRED/MEASURED/DERIVED. Stage 2
# sweeps three mixes:
#   easy       INFERRED 90 MEASURED  9 DERIVED  1  (few conflicts)
#   moderate   INFERRED 70 MEASURED 20 DERIVED 10  (Stage 1 default)
#   adversarial INFERRED 33 MEASURED 33 DERIVED 33 (dense arbitration)
KIND_MIXES = {
    "easy":        [(0.90, "INFERRED"), (0.99, "MEASURED"), (1.00, "DERIVED")],
    "moderate":    [(0.70, "INFERRED"), (0.90, "MEASURED"), (1.00, "DERIVED")],
    "adversarial": [(0.34, "INFERRED"), (0.67, "MEASURED"), (1.00, "DERIVED")],
}


def pick_kind_from_mix(rng: random.Random, cdf: List[Tuple[float, str]]) -> str:
    u = rng.random()
    for cutoff, k in cdf:
        if u < cutoff:
            return k
    return cdf[-1][1]


def make_payload_ext(rng: random.Random, cdf: List[Tuple[float, str]]) -> Dict[str, Any]:
    kind = pick_kind_from_mix(rng, cdf)
    val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
    spec = rng.randint(0, 255)
    if kind == "INFERRED":
        conf = rng.random()
        sources = [SOURCE_IDS[rng.randrange(NUM_SOURCES)]]
    elif kind == "DERIVED":
        conf = 1.0
        sources = [SOURCE_IDS[rng.randrange(NUM_SOURCES)]]
    else:  # MEASURED
        conf = 1.0
        sources = None
    return {
        "value": val, "kind": kind, "specificity": spec,
        "confidence": conf, "sources": sources,
    }


# -------------------------------------------------------------------------
# Trace entry: what the correctness axis needs to reconstruct the
# lattice winner offline.
# -------------------------------------------------------------------------

class TraceEntry:
    __slots__ = ("t_ns", "slot", "kind", "spec", "conf", "value", "committed")

    def __init__(self, t_ns: int, slot: int, kind: str, spec: int, conf: float,
                 value: str, committed: bool):
        self.t_ns = t_ns
        self.slot = slot
        self.kind = kind
        self.spec = spec
        self.conf = conf
        self.value = value
        self.committed = committed


# -------------------------------------------------------------------------
# Reset the extended fact tables (superset of Stage 1 reset).
# -------------------------------------------------------------------------

def reset_all(conn: psycopg.Connection, system: str) -> None:
    table = SYSTEM_TABLE_EXT[system]
    # Reset the fact table with the same preseed-preserving logic Stage 1
    # uses: delete workload-added rows, reopen closed sys_time.
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
        for aux in AUX_TABLES.get(system, ()):  # e.g. fact_mv_votes
            cur.execute(f"TRUNCATE {aux}")
    conn.commit()
    was_autocommit = conn.autocommit
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(f"VACUUM {table}")
    finally:
        conn.autocommit = was_autocommit


# -------------------------------------------------------------------------
# Preseed for the extended set. We use the SAME shape as Stage 1 but the
# 4 new tables need loading. COPY works for pg_heap, pg_lww, pg_conf,
# pg_mv, pg_llm as long as we temporarily disable their trigger for
# preseed (rows are chosen to pass every rule anyway).
# -------------------------------------------------------------------------

def _preseed_rows(seed: int) -> List[Tuple[Any, ...]]:
    rng = random.Random(seed ^ 0xF0F0F0F0)
    rows: List[Tuple[Any, ...]] = []
    for slot in range(NUM_SLOTS):
        entity, attr = slot_to_pair(slot)
        val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
        rows.append((entity, attr, val, [SOURCE_IDS[0]], "INFERRED", 0, 0.5))
    return rows


def _copy_preseed(conn: psycopg.Connection, table: str,
                  rows: List[Tuple[Any, ...]]) -> None:
    valid_time_lit = "[\"2026-01-01\",infinity)"
    copy_sql = (
        f"COPY {table} (entity_id, attribute, value, sources, valid_time, "
        f"ep_kind, ep_specificity, ep_confidence) FROM STDIN"
    )
    with conn.cursor() as cur:
        with cur.copy(copy_sql) as cp:
            for entity, attr, val, sources, kind, spec, conf in rows:
                src_lit = "{" + ",".join(sources) + "}"
                cp.write_row((entity, attr, val, src_lit, valid_time_lit,
                              kind, spec, conf))
    conn.commit()


# For each baseline the trigger's name is deterministic. We disable it
# during preseed and re-enable after; the preseed rows would pass every
# rule anyway (kind=INFERRED, conf=0.5, spec=0, sources=['src_0']).
TRIGGER_NAMES = {
    "pg_trigger": "fact_trig_before_insert",
    "pg_conf":    "fact_conf_before_insert",
    "pg_mv":      "fact_mv_before_insert",
    "pg_llm":     "fact_llm_before_insert",
    "pg_lww":     "fact_lww_before_insert",
}


def preseed_system(conn: psycopg.Connection, system: str, seed: int) -> None:
    table = SYSTEM_TABLE_EXT[system]
    rows = _preseed_rows(seed)
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {table}")
        cur.execute("TRUNCATE epistemic.evicted_fact")
        for aux in AUX_TABLES.get(system, ()):
            cur.execute(f"TRUNCATE {aux}")
    conn.commit()

    trig = TRIGGER_NAMES.get(system)
    if trig is not None:
        with conn.cursor() as cur:
            cur.execute(f"ALTER TABLE {table} DISABLE TRIGGER {trig}")
        conn.commit()
    try:
        _copy_preseed(conn, table, rows)
    finally:
        if trig is not None:
            with conn.cursor() as cur:
                cur.execute(f"ALTER TABLE {table} ENABLE TRIGGER {trig}")
            conn.commit()

    with conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {table}")
        row = cur.fetchone()
        assert row is not None
        n = row[0]
    if n < NUM_SLOTS:
        raise RuntimeError(
            f"preseed short: {table} got {n} rows, expected >= {NUM_SLOTS}")
    conn.commit()


# -------------------------------------------------------------------------
# Worker.
# -------------------------------------------------------------------------

class WorkerStats:
    __slots__ = (
        "throughput_txns", "abort_40001", "abort_new_loses",
        "abort_check_violation", "abort_other", "latencies_ns",
        "trace",
    )

    def __init__(self) -> None:
        self.throughput_txns = 0
        self.abort_40001 = 0
        self.abort_new_loses = 0
        self.abort_check_violation = 0
        self.abort_other = 0
        self.latencies_ns: List[int] = []
        self.trace: List[TraceEntry] = []


def _open_conn(dsn: str, isolation: str, thread_id: int,
               llm_settings: Optional[Dict[str, str]] = None,
               conf_mode: str = "on",
               mv_mode: str = "on") -> psycopg.Connection:
    c = psycopg.connect(dsn, autocommit=False,
                        application_name=f"corr_{thread_id}")
    c.isolation_level = (IsolationLevel.SERIALIZABLE if isolation == "SR"
                         else IsolationLevel.READ_COMMITTED)
    c.autocommit = True
    c.execute("SET client_min_messages = WARNING")
    # SET does not accept bound parameters (PG parser rejects "$1"
    # in place of the SET target value). All these values are
    # sanitised at the caller by argparse's `default=str` allowlist
    # or the choices constraint, so f-string interpolation is safe.
    if llm_settings:
        for k, v in llm_settings.items():
            # quote_ident-style: use a single-quoted literal.
            v_q = str(v).replace("'", "''")
            c.execute(f"SET {k} = '{v_q}'")
    if conf_mode != "on":
        c.execute(f"SET bench.fact_conf_mode = '{conf_mode}'")
    if mv_mode != "on":
        c.execute(f"SET bench.fact_mv_mode = '{mv_mode}'")
    c.autocommit = False
    return c


def worker(
    dsn: str, system: str, workload: str, theta: float, isolation: str,
    kind_cdf: List[Tuple[float, str]],
    warmup_end_wall: float, measurement_end_wall: float,
    seed: int, thread_id: int, stats: WorkerStats,
    stop_flag: threading.Event,
    llm_settings: Optional[Dict[str, str]] = None,
    conf_mode: str = "on",
    mv_mode: str = "on",
) -> None:
    rng = random.Random(seed ^ (thread_id * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF)
    zipf = ZipfianGenerator(NUM_SLOTS, theta, seed ^ (thread_id * 0xDEADBEEF))
    write_prob = 0.5 if workload == "ycsb_a" else 0.05

    ins = insert_sql_ext(system)
    rd = read_sql_ext(system)

    conn = _open_conn(dsn, isolation, thread_id, llm_settings=llm_settings,
                      conf_mode=conf_mode, mv_mode=mv_mode)
    try:
        while not stop_flag.is_set():
            now = time.time()
            if now >= measurement_end_wall:
                break
            counted = now >= warmup_end_wall

            is_write = rng.random() < write_prob
            if is_write:
                slot = zipf.next()
                p = make_payload_ext(rng, kind_cdf)
            else:
                slot = rng.randrange(NUM_SLOTS)
                p = None

            entity, attr = slot_to_pair(slot)

            t0 = time.perf_counter_ns()
            attempt_ns = time.time_ns()
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
                # Trace every write attempt including during warmup:
                # warmup writes can still commit and change the live
                # table state, so the correctness replay must see them
                # or it will predict a stale winner. Only throughput /
                # latency counters are gated by `counted`.
                if is_write:
                    stats.trace.append(TraceEntry(
                        attempt_ns, slot, p["kind"], p["specificity"],
                        p["confidence"], p["value"], True))
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
                if is_write:
                    stats.trace.append(TraceEntry(
                        attempt_ns, slot, p["kind"], p["specificity"],
                        p["confidence"], p["value"], False))
    finally:
        with contextlib.suppress(Exception):
            conn.close()


# -------------------------------------------------------------------------
# Lattice-predicted winner from the trace.
# -------------------------------------------------------------------------

KIND_RANK = {"MEASURED": 3, "DERIVED": 2, "INFERRED": 1}

# For pg_lww's LWW path, the correct "actual survivor" is fully
# determined by the last committed write. For other systems, actual
# survivor is a query against the live table.

# Preseed baseline row (per Stage 1 semantics): kind=INFERRED, spec=0,
# conf=0.5, value=deterministic-per-seed. The correctness axis needs
# to include this initial row so that slots that never receive a
# workload write have a well-defined "expected" value.

def preseed_baseline_row(seed: int) -> Dict[int, Dict[str, Any]]:
    """
    Reconstruct the preseed rows the workload started against. Keyed
    by slot number, matches the (kind, spec, conf, value) each slot
    was primed with.
    """
    rng = random.Random(seed ^ 0xF0F0F0F0)
    out: Dict[int, Dict[str, Any]] = {}
    for slot in range(NUM_SLOTS):
        val = "".join(rng.choices(string.ascii_letters + string.digits, k=40))
        out[slot] = {
            "kind": "INFERRED", "spec": 0, "conf": 0.5, "value": val,
            "t_ns": 0,  # earlier than any workload write
        }
    return out


def compute_lattice_winners(
    trace: List[TraceEntry], seed: int,
) -> Tuple[Dict[int, Dict[str, Any]], set]:
    """
    Merge all workers' write attempts into one time-ordered stream.
    Compute two views of the lattice-maximal winner per slot:

    winners[slot] = {
        "kind": <lattice-max kind over ALL attempts (committed or not)>,
        "spec", "conf": lattice-max within that kind, over ALL attempts,
        "values": set of values that appeared at the lattice-max bucket
                  in ANY attempt (committed or not),
        "canonical_value": one deterministic pick (for reporting),
    }

    Why "all attempts": the lattice's job is to pick the epistemically
    strongest write from the pool of intents the workload SENT to the
    database. A system that discards a MEASURED write attempt (because
    e.g. the LLM randomly rejected it, or the confidence-only trigger
    couldn't compare it to an INFERRED conf=0.9 incumbent that ranked
    higher only on confidence) has failed to preserve the lattice-max
    winner from the intent set. That's the correctness question we're
    asking.

    A live row for a slot is CORRECT iff its (kind, spec, conf) equals
    the maximal bucket AND its value is one of the values that appeared
    at that bucket in the intent stream.

    Contested slot = >= 2 distinct-content writes among preseed + all
    attempts (committed or not).
    """
    preseed = preseed_baseline_row(seed)
    winners: Dict[int, Dict[str, Any]] = {}
    contested: set = set()
    seen_content: Dict[int, set] = {}

    for slot, row in preseed.items():
        winners[slot] = {
            "kind": row["kind"], "spec": row["spec"], "conf": row["conf"],
            "values": {row["value"]},
            "canonical_value": row["value"],
        }
        seen_content[slot] = {
            (row["kind"], row["spec"], row["conf"], row["value"])
        }

    ordered = sorted(trace, key=lambda e: e.t_ns)
    for e in ordered:
        sig = (e.kind, e.spec, round(e.conf, 6), e.value)
        seen_content[e.slot].add(sig)
        if len(seen_content[e.slot]) >= 2:
            contested.add(e.slot)

        # Consider EVERY write attempt (committed or not) as a candidate
        # for the lattice-max. Rejection by a mechanism is the point of
        # the correctness axis: did the system's rejection align with
        # what the lattice would have accepted?
        cur = winners[e.slot]
        cur_rank = KIND_RANK[cur["kind"]]
        new_rank = KIND_RANK[e.kind]
        if new_rank > cur_rank:
            beats = True
        elif new_rank < cur_rank:
            beats = False
        elif e.spec > cur["spec"]:
            beats = True
        elif e.spec < cur["spec"]:
            beats = False
        elif e.conf > cur["conf"]:
            beats = True
        elif e.conf < cur["conf"]:
            beats = False
        else:
            cur["values"].add(e.value)
            continue

        if beats:
            winners[e.slot] = {
                "kind": e.kind, "spec": e.spec, "conf": e.conf,
                "values": {e.value},
                "canonical_value": e.value,
            }

    return winners, contested


# -------------------------------------------------------------------------
# Correctness scoring against the live table.
# -------------------------------------------------------------------------

def measure_actual_survivors(
    conn: psycopg.Connection, system: str,
) -> Dict[int, Dict[str, Any]]:
    """
    Return {slot -> {"value": ..., "kind": ..., "spec": ..., "conf": ...,
                      "n_live": int}}. n_live==0 means no live row for
    the slot (integrity violation of 'exactly one live per slot').
    n_live>1 means multiple live rows.
    """
    table = SYSTEM_TABLE_EXT[system]
    counts: Dict[int, int] = {}
    rows: Dict[int, Dict[str, Any]] = {}
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT entity_id, attribute, value, "
            f"       ep_kind::text, ep_specificity, ep_confidence "
            f"FROM {table} "
            f"WHERE upper(sys_time) = 'infinity'::timestamptz")
        for entity, attr, value, kind, spec, conf in cur.fetchall():
            try:
                attr_idx = int(attr[1:])
            except ValueError:
                continue
            slot = entity * ATTRS_PER_ENTITY + attr_idx
            counts[slot] = counts.get(slot, 0) + 1
            # First seen row wins the record; later ones bump n_live.
            if slot not in rows:
                rows[slot] = {
                    "value": value, "kind": kind, "spec": int(spec),
                    "conf": float(conf),
                }
    for slot, n in counts.items():
        rows[slot]["n_live"] = n
    return rows


def _matches_expected(expected: Dict[str, Any], actual: Dict[str, Any],
                      tol_conf: float = 1e-4) -> bool:
    """
    A live row matches the expected lattice bucket iff its (kind, spec, conf)
    equals the expected bucket and its value is one of the tied-highest
    committed writes. Confidence uses a small tolerance because we round-
    trip through Postgres real -> float which loses precision beyond ~6
    decimal digits.
    """
    if actual["kind"] != expected["kind"]:
        return False
    if actual["spec"] != expected["spec"]:
        return False
    if abs(actual["conf"] - expected["conf"]) > tol_conf:
        return False
    return actual["value"] in expected["values"]


def score_correctness(
    winners: Dict[int, Dict[str, Any]],
    survivors: Dict[int, Dict[str, Any]],
    contested: set,
) -> Dict[str, Any]:
    n_contested = len(contested)
    n_correct = 0
    n_missing_live = 0
    n_multiple_live = 0
    n_uncontested_correct = 0
    n_uncontested_total = 0
    per_slot_misses: List[Dict[str, Any]] = []

    for slot in range(NUM_SLOTS):
        expected = winners[slot]
        actual = survivors.get(slot)
        if actual is None:
            n_missing_live += 1
            if slot in contested and len(per_slot_misses) < 20:
                per_slot_misses.append({
                    "slot": slot,
                    "expected_kind": expected["kind"],
                    "expected_spec": expected["spec"],
                    "expected_conf": expected["conf"],
                    "expected_n_tied_values": len(expected["values"]),
                    "actual": "MISSING",
                })
            continue
        if actual["n_live"] > 1:
            n_multiple_live += 1
            if slot in contested and len(per_slot_misses) < 20:
                per_slot_misses.append({
                    "slot": slot,
                    "expected_kind": expected["kind"],
                    "actual": "MULTIPLE_LIVE",
                    "n_live": actual["n_live"],
                })
            continue

        ok = _matches_expected(expected, actual)
        if slot in contested:
            if ok:
                n_correct += 1
            elif len(per_slot_misses) < 20:
                per_slot_misses.append({
                    "slot": slot,
                    "expected_kind": expected["kind"],
                    "expected_spec": expected["spec"],
                    "expected_conf": round(expected["conf"], 4),
                    "expected_n_tied_values": len(expected["values"]),
                    "actual_kind": actual["kind"],
                    "actual_spec": actual["spec"],
                    "actual_conf": round(actual["conf"], 4),
                    "actual_value_in_tied_set":
                        actual["value"] in expected["values"],
                })
        else:
            n_uncontested_total += 1
            if ok:
                n_uncontested_correct += 1

    return {
        "contested_slots": n_contested,
        "correct_on_contested": n_correct,
        "correctness_rate": (n_correct / n_contested) if n_contested else 1.0,
        "missing_live_rows": n_missing_live,
        "multiple_live_rows": n_multiple_live,
        "uncontested_slots": n_uncontested_total,
        "uncontested_correct": n_uncontested_correct,
        "sample_misses": per_slot_misses[:20],
    }


# -------------------------------------------------------------------------
# Main.
# -------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__ or "",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default=os.environ.get("YCSB_DSN"))
    ap.add_argument("--system", choices=sorted(SYSTEM_TABLE_EXT.keys()), required=True)
    ap.add_argument("--workload", choices=["ycsb_a", "ycsb_b"], default="ycsb_a")
    ap.add_argument("--isolation", choices=["RC", "SR"], default="RC")
    ap.add_argument("--theta", type=float, required=True)
    ap.add_argument("--clients", type=int, required=True)
    ap.add_argument("--kind-mix", choices=sorted(KIND_MIXES.keys()),
                    default="moderate")
    ap.add_argument("--measurement-seconds", type=float, required=True)
    ap.add_argument("--warmup-seconds", type=float, default=5.0)
    ap.add_argument("--seed", type=int, default=20260712)
    ap.add_argument("--run-index", type=int, default=0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--skip-preseed", action="store_true")
    ap.add_argument("--reset-between-cells", action="store_true")
    # Disable-and-test knobs.
    ap.add_argument("--llm-p-correct", default="0.65")
    ap.add_argument("--llm-latency-mean", default="300")
    ap.add_argument("--llm-latency-sigma", default="0.5")
    ap.add_argument("--llm-disable-test", default="0",
                    help="when '1' forces mock LLM P_correct=0.5 (disable test)")
    ap.add_argument("--conf-mode", choices=["on", "off"], default="on",
                    help="when 'off' fact_conf trigger becomes LWW")
    ap.add_argument("--mv-mode", choices=["on", "off"], default="on",
                    help="when 'off' fact_mv trigger becomes LWW")
    args = ap.parse_args()

    if args.dsn is None:
        print("--dsn or YCSB_DSN required", file=sys.stderr)
        return 2

    kind_cdf = KIND_MIXES[args.kind_mix]

    setup_conn = psycopg.connect(args.dsn, autocommit=True)
    try:
        pg_meta = gather_pg_meta(setup_conn, args.isolation)
        setup_conn.autocommit = False
        register_sources(setup_conn)
        if not args.skip_preseed:
            preseed_system(setup_conn, args.system, args.seed)
        elif args.reset_between_cells:
            reset_all(setup_conn, args.system)
        setup_conn.autocommit = True
    finally:
        setup_conn.close()

    stop_flag = threading.Event()
    stats_list = [WorkerStats() for _ in range(args.clients)]

    llm_settings = {
        "bench.fact_llm_p_correct":     args.llm_p_correct,
        "bench.fact_llm_latency_mean":  args.llm_latency_mean,
        "bench.fact_llm_latency_sigma": args.llm_latency_sigma,
        "bench.fact_llm_disable_test":  args.llm_disable_test,
        "bench.fact_llm_mode":          "on",
    }

    start_wall = time.time() + 0.5
    warmup_end = start_wall + args.warmup_seconds
    measurement_end = warmup_end + args.measurement_seconds

    with ThreadPoolExecutor(max_workers=args.clients) as pool:
        for tid in range(args.clients):
            pool.submit(
                worker,
                args.dsn, args.system, args.workload, args.theta,
                args.isolation, kind_cdf,
                warmup_end, measurement_end,
                args.seed, tid, stats_list[tid], stop_flag,
                llm_settings, args.conf_mode, args.mv_mode,
            )

        try:
            while time.time() < measurement_end:
                time.sleep(0.2)
        finally:
            stop_flag.set()

    # Correctness rollup: merge traces, replay lattice, query survivors.
    combined_trace: List[TraceEntry] = []
    for w in stats_list:
        combined_trace.extend(w.trace)
    winners, contested = compute_lattice_winners(combined_trace, args.seed)

    # Give background transactions a beat to drain (LLM sleeps
    # could stretch past measurement_end).
    time.sleep(2.0)

    survivor_conn = psycopg.connect(args.dsn, autocommit=True)
    try:
        survivors = measure_actual_survivors(survivor_conn, args.system)
    finally:
        survivor_conn.close()

    corr = score_correctness(winners, survivors, contested)

    # Reuse the Stage 1 aggregator by producing an adapter over
    # WorkerStats. The Stage-1 aggregator only reads fields we already
    # populate.
    metrics = aggregate(stats_list, args.measurement_seconds)  # type: ignore[arg-type]

    # Goodput = throughput * (1 - abort_rate) * correctness_rate.
    tput = metrics["throughput_txn_per_s"]
    ar = metrics["abort_rate"]
    cr = corr["correctness_rate"]
    goodput = tput * (1.0 - ar) * cr

    out = {
        "system": args.system,
        "workload": args.workload,
        "isolation": args.isolation,
        "zipfian_theta": args.theta,
        "clients": args.clients,
        "kind_mix": args.kind_mix,
        "measurement_seconds": args.measurement_seconds,
        "warmup_seconds": args.warmup_seconds,
        "seed": args.seed,
        "run_index": args.run_index,
        "hardware": gather_hardware(),
        "pg": pg_meta,
        "metrics": metrics,
        "correctness": corr,
        "goodput_txn_per_s": goodput,
        "llm_settings": {
            "p_correct": args.llm_p_correct,
            "latency_mean_ms": args.llm_latency_mean,
            "latency_sigma": args.llm_latency_sigma,
            "disable_test": args.llm_disable_test,
        },
        "conf_mode": args.conf_mode,
        "mv_mode": args.mv_mode,
        "notes": (
            "closed-loop; Stage 2 correctness axis. LLM baseline uses a "
            "calibrated mock (log-normal latency around 300ms mean, "
            "P_correct calibrated against Mem0/MemGPT LOCOMO 60-75%). "
            "Real API not called."
        ),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True, default=str)

    hint = {
        "tps": tput,
        "abort_rate": ar,
        "correctness_rate": cr,
        "goodput": goodput,
        "contested": corr["contested_slots"],
        "n_writes_traced": len(combined_trace),
    }
    print(json.dumps(hint, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
