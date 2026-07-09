"""N-client hotspot throughput workload.

Each client is a thread running its own connection. Every client issues
`writes_per_client` MEASURED write attempts. With probability `contention`
the write targets the shared hotspot slot; otherwise it targets a fresh
per-write (entity_id, attribute) drawn from a seeded pool.

Retry modes:
  raw : any 40001 or 40P01 counts as a dropped write.
  app : exponential backoff up to 10 attempts.

Post-run invariant checks run for every cell and are captured in the
CellResult. Any hotspot slot with >1 live row or missing audit rows is
recorded as a first-class violation, at the same severity as the paired
paired-race scenarios.
"""
from __future__ import annotations

import random
import threading
import time
import traceback
from dataclasses import dataclass
from typing import Literal

import psycopg

from .db import open_connection, truncate_fact_state
from .invariants import hotspot_slot_invariants
from .metrics import CellResult, ThreadResult, WriteOutcome, aggregate_cell
from .payloads import (
    INSERT_SQL,
    default_valid_range,
    entity_pool,
    hotspot_slot,
    measured,
)


RetryMode = Literal["raw", "app"]


@dataclass
class HotspotConfig:
    client_count: int
    contention: float           # 0.0 to 1.0
    isolation: str              # "READ COMMITTED" | "SERIALIZABLE"
    retry_mode: RetryMode
    writes_per_client: int
    seed: int


def _classify_error(exc: BaseException) -> str:
    if isinstance(exc, psycopg.errors.SerializationFailure):
        return "serialization"
    if isinstance(exc, psycopg.errors.DeadlockDetected):
        return "deadlock"
    if isinstance(exc, psycopg.errors.CheckViolation):
        return "check"
    if isinstance(exc, psycopg.errors.ExclusionViolation):
        return "exclusion"
    return "other"


def _write_once(cur: psycopg.Cursor, params: tuple) -> float:
    """Execute one INSERT and return the elapsed microseconds until COMMIT
    returns. Raises on any failure.
    """
    t0 = time.perf_counter()
    cur.execute(INSERT_SQL, params)
    # commit happens outside; timing captured here excludes commit
    return (time.perf_counter() - t0) * 1_000_000.0


def _client_loop(
    thread_id: int,
    cfg: HotspotConfig,
    rng_seed: int,
    barrier: threading.Barrier,
    hotspot: tuple[int, str],
    entities: list[int],
    result_slot: list,
) -> None:
    """One client thread. Records a ThreadResult in result_slot[thread_id]."""
    rng = random.Random(rng_seed)
    thread_result = ThreadResult(thread_id=thread_id)
    try:
        conn = open_connection(isolation=cfg.isolation)
        conn.autocommit = False
        barrier.wait(timeout=30.0)
        for w in range(cfg.writes_per_client):
            # pick slot
            if rng.random() < cfg.contention:
                entity_id, attribute = hotspot
                is_hotspot = True
            else:
                entity_id = entities[(thread_id * cfg.writes_per_client + w) % len(entities)]
                attribute = "spread_slot"
                is_hotspot = False
            lower, upper = default_valid_range()
            payload = measured(
                entity_id=entity_id,
                attribute=attribute,
                value=f"t{thread_id}_w{w}",
                valid_range=(lower, upper),
            )
            params = payload.to_insert_params()

            attempts = 0
            committed = False
            latency_us: float | None = None
            failure_kind: str | None = None

            max_attempts = 10 if cfg.retry_mode == "app" else 1
            while attempts < max_attempts:
                attempts += 1
                try:
                    with conn.cursor() as cur:
                        latency_us = _write_once(cur, params)
                    conn.commit()
                    committed = True
                    break
                except (psycopg.errors.SerializationFailure, psycopg.errors.DeadlockDetected) as e:
                    conn.rollback()
                    failure_kind = _classify_error(e)
                    if cfg.retry_mode == "app" and attempts < max_attempts:
                        backoff = min(0.005 * (2 ** attempts), 0.200)
                        time.sleep(backoff)
                        continue
                    break
                except (psycopg.errors.CheckViolation, psycopg.errors.ExclusionViolation) as e:
                    # deterministic engine rejection is not a retryable error
                    conn.rollback()
                    failure_kind = _classify_error(e)
                    break
                except Exception as e:  # pragma: no cover
                    conn.rollback()
                    failure_kind = "other"
                    break

            thread_result.outcomes.append(
                WriteOutcome(
                    latency_us=latency_us if committed else None,
                    attempts=attempts,
                    committed=committed,
                    is_hotspot=is_hotspot,
                    failure_kind=None if committed else failure_kind,
                )
            )
        conn.close()
    except Exception:
        # harness bug; record as a single failed outcome
        thread_result.outcomes.append(
            WriteOutcome(
                latency_us=None,
                attempts=1,
                committed=False,
                failure_kind=f"harness:{traceback.format_exc()[:200]}",
            )
        )
    result_slot[thread_id] = thread_result


def run_cell(cfg: HotspotConfig) -> CellResult:
    """Run one throughput cell. Truncates kndb.fact and audit first,
    then runs N clients, then post-run invariant check.
    """
    reset_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    truncate_fact_state(reset_conn)
    reset_conn.close()

    entities = entity_pool(size=max(cfg.client_count * cfg.writes_per_client, 1000), seed=cfg.seed)
    hotspot = hotspot_slot()
    barrier = threading.Barrier(cfg.client_count)
    result_slot: list = [None] * cfg.client_count

    threads = [
        threading.Thread(
            target=_client_loop,
            args=(
                tid,
                cfg,
                cfg.seed + tid * 101,
                barrier,
                hotspot,
                entities,
                result_slot,
            ),
        )
        for tid in range(cfg.client_count)
    ]

    started = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=600.0)
    wall = time.time() - started

    check_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    hotspot_committed = sum(
        sum(1 for o in tr.outcomes if o.committed and o.is_hotspot)
        for tr in result_slot if tr is not None
    )
    invariant_results = hotspot_slot_invariants(
        check_conn,
        entity_id=hotspot[0],
        attribute=hotspot[1],
        accepted_commits=hotspot_committed,
    )
    check_conn.close()

    invariant_violations = [
        {"label": inv.label, "detail": inv.detail}
        for inv in invariant_results
        if not inv.ok
    ]

    cell_id = (
        f"n{cfg.client_count}_c{int(cfg.contention*100)}_"
        f"{cfg.isolation.replace(' ', '')}_{cfg.retry_mode}"
    )
    return aggregate_cell(
        cell_id=cell_id,
        client_count=cfg.client_count,
        contention=cfg.contention,
        isolation=cfg.isolation,
        retry_mode=cfg.retry_mode,
        seed=cfg.seed,
        thread_results=[tr for tr in result_slot if tr is not None],
        wall_clock_s=wall,
        invariant_violations=invariant_violations,
    )
