"""Paired-race framework for the four correctness scenarios.

Each iteration spawns two threads sharing a `threading.Barrier(2)`. The
threads open their own connections, prepare their INSERTs, hit the barrier,
then race to INSERT and COMMIT. A seed-deterministic coin flip decides
which side gets a 2 ms head-start on the COMMIT to bias commit order in
the OS scheduler.

The barrier alone does not fix commit order. The head-start hint sways
it in ~90 % of iterations, which is enough to cover both orderings across
1 000 runs.
"""
from __future__ import annotations

import random
import threading
import time
import traceback
from dataclasses import dataclass, field
from typing import Callable, Optional

import psycopg

from .db import open_connection, IsolationLevel
from .payloads import FactPayload, INSERT_SQL
from .invariants import InvariantResult


@dataclass
class PairedRaceResult:
    iteration: int
    thread_a_committed: bool
    thread_b_committed: bool
    thread_a_error: str | None = None
    thread_b_error: str | None = None
    commit_hint_first: str = ""              # 'A', 'B', or ''
    accepted_count: int = 0                  # committed writes on this iteration
    invariants: list[InvariantResult] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return all(inv.ok for inv in self.invariants)


def _do_write(
    payload: FactPayload,
    isolation: IsolationLevel,
    head_start_ms: float,
    barrier: threading.Barrier,
    result_container: dict,
    thread_label: str,
) -> None:
    """One thread of a paired race. Records success/failure in
    `result_container[thread_label]`.
    """
    try:
        conn = open_connection(isolation=isolation)
        conn.autocommit = False
        with conn.cursor() as cur:
            barrier.wait(timeout=5.0)
            if head_start_ms > 0:
                pass  # this thread gets the head-start
            else:
                # tiny sleep so the other side (with head-start) hits COMMIT first
                time.sleep(0.002)
            try:
                cur.execute(INSERT_SQL, payload.to_insert_params())
                conn.commit()
                result_container[thread_label] = {"committed": True}
            except psycopg.errors.CheckViolation as e:
                # engine rejection (R1-R5 / lattice / conflict_policy)
                conn.rollback()
                result_container[thread_label] = {
                    "committed": False,
                    "error": f"CheckViolation: {e}",
                }
            except psycopg.errors.ExclusionViolation as e:
                # GiST EXCLUDE from 02_facts_schema
                conn.rollback()
                result_container[thread_label] = {
                    "committed": False,
                    "error": f"ExclusionViolation: {e}",
                }
            except psycopg.errors.SerializationFailure as e:
                conn.rollback()
                result_container[thread_label] = {
                    "committed": False,
                    "error": f"SerializationFailure: {e}",
                }
            except psycopg.errors.DeadlockDetected as e:
                conn.rollback()
                result_container[thread_label] = {
                    "committed": False,
                    "error": f"DeadlockDetected: {e}",
                }
        conn.close()
    except Exception:
        result_container[thread_label] = {
            "committed": False,
            "error": f"Harness exception: {traceback.format_exc()}",
        }


def run_paired_iteration(
    payload_a: FactPayload,
    payload_b: FactPayload,
    isolation: IsolationLevel,
    coin: float,
    iteration: int,
    check_conn: psycopg.Connection,
    invariant_fn: Callable[[psycopg.Connection, FactPayload, FactPayload], list[InvariantResult]],
) -> PairedRaceResult:
    """Run one paired race. `invariant_fn` returns the scenario-specific
    list of invariant results to attach.
    """
    barrier = threading.Barrier(2)
    results: dict[str, dict] = {}

    if coin < 0.5:
        # A first
        head_start_a = 0.002
        head_start_b = 0.0
        hint = "A"
    else:
        head_start_a = 0.0
        head_start_b = 0.002
        hint = "B"

    t_a = threading.Thread(
        target=_do_write,
        args=(payload_a, isolation, head_start_a, barrier, results, "A"),
    )
    t_b = threading.Thread(
        target=_do_write,
        args=(payload_b, isolation, head_start_b, barrier, results, "B"),
    )
    t_a.start()
    t_b.start()
    t_a.join(timeout=30)
    t_b.join(timeout=30)

    a_res = results.get("A", {"committed": False, "error": "no result"})
    b_res = results.get("B", {"committed": False, "error": "no result"})

    committed_count = int(a_res.get("committed", False)) + int(
        b_res.get("committed", False)
    )

    invariants = invariant_fn(check_conn, payload_a, payload_b)

    return PairedRaceResult(
        iteration=iteration,
        thread_a_committed=a_res.get("committed", False),
        thread_b_committed=b_res.get("committed", False),
        thread_a_error=a_res.get("error"),
        thread_b_error=b_res.get("error"),
        commit_hint_first=hint,
        accepted_count=committed_count,
        invariants=invariants,
    )


def run_paired_scenario(
    label: str,
    make_payloads: Callable[[int, random.Random], tuple[FactPayload, FactPayload]],
    invariant_fn: Callable[[psycopg.Connection, FactPayload, FactPayload], list[InvariantResult]],
    isolation: IsolationLevel,
    iterations: int = 1000,
    seed: int = 42,
    stop_after_first_violation: bool = False,
) -> list[PairedRaceResult]:
    """Run a paired-race scenario N times. Each iteration uses a fresh
    (entity_id, attribute) so runs do not pollute each other.

    Returns the per-iteration result list. Use `stop_after_first_violation`
    when you want a minimal reproducing case; leave it False to characterize
    frequency.
    """
    rng = random.Random(seed)
    check_conn = open_connection(isolation="READ COMMITTED", autocommit=True)

    results: list[PairedRaceResult] = []
    for i in range(iterations):
        payload_a, payload_b = make_payloads(i, rng)
        coin = rng.random()
        r = run_paired_iteration(
            payload_a=payload_a,
            payload_b=payload_b,
            isolation=isolation,
            coin=coin,
            iteration=i,
            check_conn=check_conn,
            invariant_fn=invariant_fn,
        )
        results.append(r)
        if not r.ok:
            print(
                f"[{label}] VIOLATION @ iter={i} hint={r.commit_hint_first}: "
                f"{'; '.join(inv.detail for inv in r.invariants if not inv.ok)}"
            )
            if stop_after_first_violation:
                break

    check_conn.close()
    return results
