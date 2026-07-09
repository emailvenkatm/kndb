"""S4 audit completeness under burst.

Per iteration: N=8 threads each attempt a differing-value MEASURED write
into the SAME (entity_id, attribute) with overlapping valid_time. The
harness records which writes it accepted (COMMIT returned) and checks:

    live rows for slot + evicted_fact rows for slot >= accepted commits

That is: nothing the client observed as committed can be silently
missing from the DB state. Missing rows would mean the engine lost a
write under contention.
"""
from __future__ import annotations

import csv
import json
import random
import sys
import threading
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

import psycopg

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from harness.db import open_connection, truncate_fact_state, query_server_provenance
from harness.invariants import audit_completeness, no_two_live_for_slot
from harness.metrics import hardware_provenance
from harness.payloads import (
    FactPayload,
    INSERT_SQL,
    default_valid_range,
    measured,
)


SCENARIO_LABEL = "s4_audit"
BURST_THREADS = 8


def _one_write(payload: FactPayload, isolation: str, barrier: threading.Barrier, results: dict, tid: int) -> None:
    try:
        conn = open_connection(isolation=isolation)
        with conn.cursor() as cur:
            barrier.wait(timeout=5.0)
            try:
                cur.execute(INSERT_SQL, payload.to_insert_params())
                conn.commit()
                results[tid] = {"committed": True}
            except psycopg.errors.CheckViolation as e:
                conn.rollback()
                results[tid] = {"committed": False, "error": f"CheckViolation: {e}"}
            except psycopg.errors.ExclusionViolation as e:
                conn.rollback()
                results[tid] = {"committed": False, "error": f"ExclusionViolation: {e}"}
            except psycopg.errors.SerializationFailure as e:
                conn.rollback()
                results[tid] = {"committed": False, "error": f"SerializationFailure: {e}"}
            except psycopg.errors.DeadlockDetected as e:
                conn.rollback()
                results[tid] = {"committed": False, "error": f"DeadlockDetected: {e}"}
        conn.close()
    except Exception:
        results[tid] = {"committed": False, "error": f"Harness exception: {traceback.format_exc()}"}


def _run_one_iteration(iteration: int, isolation: str, check_conn: psycopg.Connection) -> dict:
    entity_id = 34_000_000 + iteration
    attribute = "s4_slot"
    lower, upper = default_valid_range()

    payloads = [
        measured(
            entity_id=entity_id,
            attribute=attribute,
            value=f"val{iteration}_{i}",
            valid_range=(lower, upper),
        )
        for i in range(BURST_THREADS)
    ]

    barrier = threading.Barrier(BURST_THREADS)
    results: dict[int, dict] = {}
    threads = [
        threading.Thread(target=_one_write, args=(payloads[i], isolation, barrier, results, i))
        for i in range(BURST_THREADS)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)

    accepted = sum(1 for i in range(BURST_THREADS) if results.get(i, {}).get("committed"))
    check_ex = no_two_live_for_slot(check_conn, entity_id, attribute)
    check_ac = audit_completeness(check_conn, entity_id, attribute, accepted)

    return {
        "iteration": iteration,
        "accepted": accepted,
        "check_exclusion_ok": check_ex.ok,
        "check_audit_ok": check_ac.ok,
        "check_exclusion_detail": check_ex.detail,
        "check_audit_detail": check_ac.detail,
    }


def run(isolation: str, iterations: int, seed: int, out_dir: Path) -> dict:
    print(f"[{SCENARIO_LABEL}] isolation={isolation} iterations={iterations} burst={BURST_THREADS}", flush=True)

    setup_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    truncate_fact_state(setup_conn)
    provenance = query_server_provenance(setup_conn)
    setup_conn.close()

    check_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    started = time.time()
    per_iter = [_run_one_iteration(i, isolation, check_conn) for i in range(iterations)]
    wall = time.time() - started
    check_conn.close()

    n_iter = len(per_iter)
    n_ex_violations = sum(1 for r in per_iter if not r["check_exclusion_ok"])
    n_audit_violations = sum(1 for r in per_iter if not r["check_audit_ok"])
    n_violations = sum(
        1 for r in per_iter if (not r["check_exclusion_ok"]) or (not r["check_audit_ok"])
    )
    total_accepted = sum(r["accepted"] for r in per_iter)

    iso_slug = isolation.replace(" ", "_").lower()
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / f"{SCENARIO_LABEL}_{iso_slug}_iterations.csv"
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(
            [
                "iteration",
                "isolation",
                "burst_threads",
                "accepted",
                "check_exclusion_ok",
                "check_audit_ok",
                "check_exclusion_detail",
                "check_audit_detail",
            ]
        )
        for r in per_iter:
            w.writerow(
                [
                    r["iteration"],
                    isolation,
                    BURST_THREADS,
                    r["accepted"],
                    int(r["check_exclusion_ok"]),
                    int(r["check_audit_ok"]),
                    r["check_exclusion_detail"],
                    r["check_audit_detail"],
                ]
            )

    summary = {
        "scenario": SCENARIO_LABEL,
        "isolation": isolation,
        "burst_threads": BURST_THREADS,
        "iterations": n_iter,
        "violations": n_violations,
        "exclusion_violations": n_ex_violations,
        "audit_completeness_violations": n_audit_violations,
        "total_accepted_writes": total_accepted,
        "wall_clock_s": wall,
    }
    manifest = {
        "run_at": datetime.now(timezone.utc).isoformat(),
        "scenario": SCENARIO_LABEL,
        "isolation": isolation,
        "seed": seed,
        "burst_threads": BURST_THREADS,
        "iterations": n_iter,
        "summary": summary,
        "server_provenance": provenance,
        "hardware_provenance": hardware_provenance(),
    }
    with (out_dir / f"{SCENARIO_LABEL}_{iso_slug}_manifest.json").open("w") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"[{SCENARIO_LABEL}] {summary}", flush=True)
    return summary


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--isolation", default="READ COMMITTED", choices=["READ COMMITTED", "SERIALIZABLE"])
    parser.add_argument("--iterations", type=int, default=500)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out-dir", type=Path, default=HERE.parent / "results")
    args = parser.parse_args()
    s = run(args.isolation, args.iterations, args.seed, args.out_dir)
    sys.exit(0 if s["violations"] == 0 else 1)
