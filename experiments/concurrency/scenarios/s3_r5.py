"""S3 R5 race.

Slot `hba1c` is registered as MEASURED at bootstrap. Two threads race:
  Thread A INSERTs MEASURED into hba1c (allowed).
  Thread B INSERTs INFERRED into hba1c (R5 must reject regardless of order).

Same entity, overlapping valid_time. Vary commit order. Invariant:
no INFERRED row ever lands in the hba1c slot, in any iteration, at any
isolation level. If we ever see one, R5 does not hold under concurrency.
"""
from __future__ import annotations

import csv
import json
import random
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from harness.db import open_connection, truncate_fact_state, query_server_provenance
from harness.invariants import InvariantResult, r5_holds, no_two_live_for_slot
from harness.metrics import hardware_provenance
from harness.paired import run_paired_scenario
from harness.payloads import FactPayload, default_valid_range, inferred, measured


SCENARIO_LABEL = "s3_r5"
R5_SLOT = "hba1c"                  # pre-registered as MEASURED in bootstrap


def make_payloads(iteration: int, rng: random.Random) -> tuple[FactPayload, FactPayload]:
    entity_id = 33_000_000 + iteration
    lower, upper = default_valid_range()
    payload_a = measured(
        entity_id=entity_id,
        attribute=R5_SLOT,
        value=f"7.1_{iteration}",
        confidence=0.95,
        valid_range=(lower, upper),
    )
    payload_b = inferred(
        entity_id=entity_id,
        attribute=R5_SLOT,
        value=f"7.4_{iteration}",
        confidence=0.65,
        valid_range=(lower, upper),
    )
    return payload_a, payload_b


def _r5_invariants(conn, payload_a: FactPayload, payload_b: FactPayload) -> list[InvariantResult]:
    return [
        r5_holds(conn, payload_a.entity_id, payload_a.attribute, "INFERRED"),
        no_two_live_for_slot(conn, payload_a.entity_id, payload_a.attribute),
    ]


def run(isolation: str, iterations: int, seed: int, out_dir: Path) -> dict:
    print(f"[{SCENARIO_LABEL}] isolation={isolation} iterations={iterations}", flush=True)

    truncate_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    truncate_fact_state(truncate_conn)
    with truncate_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO kndb.slot_kind (attribute, required_kind) VALUES (%s, %s) "
            "ON CONFLICT (attribute) DO UPDATE SET required_kind = EXCLUDED.required_kind",
            (R5_SLOT, "MEASURED"),
        )
    provenance = query_server_provenance(truncate_conn)
    truncate_conn.close()

    started = time.time()
    results = run_paired_scenario(
        label=SCENARIO_LABEL,
        make_payloads=make_payloads,
        invariant_fn=_r5_invariants,
        isolation=isolation,
        iterations=iterations,
        seed=seed,
        stop_after_first_violation=False,
    )
    wall = time.time() - started

    n_iter = len(results)
    n_violations = sum(1 for r in results if not r.ok)
    n_inferred_rejected = sum(
        1 for r in results
        if not r.thread_b_committed and r.thread_b_error and "CheckViolation" in r.thread_b_error
    )
    n_measured_landed = sum(1 for r in results if r.thread_a_committed)

    iso_slug = isolation.replace(" ", "_").lower()
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / f"{SCENARIO_LABEL}_{iso_slug}_iterations.csv"
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(
            [
                "iteration",
                "isolation",
                "commit_hint_first",
                "thread_a_committed",   # MEASURED
                "thread_b_committed",   # INFERRED (must be False every row)
                "thread_a_error",
                "thread_b_error",
                "invariant_ok",
                "invariant_detail",
            ]
        )
        for r in results:
            w.writerow(
                [
                    r.iteration,
                    isolation,
                    r.commit_hint_first,
                    int(r.thread_a_committed),
                    int(r.thread_b_committed),
                    r.thread_a_error or "",
                    r.thread_b_error or "",
                    int(r.ok),
                    "; ".join(inv.detail for inv in r.invariants if not inv.ok) or "",
                ]
            )

    summary = {
        "scenario": SCENARIO_LABEL,
        "isolation": isolation,
        "iterations": n_iter,
        "violations": n_violations,
        "measured_landed_iters": n_measured_landed,
        "inferred_rejected_by_r5_iters": n_inferred_rejected,
        "wall_clock_s": wall,
    }
    manifest = {
        "run_at": datetime.now(timezone.utc).isoformat(),
        "scenario": SCENARIO_LABEL,
        "isolation": isolation,
        "seed": seed,
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
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out-dir", type=Path, default=HERE.parent / "results")
    args = parser.parse_args()
    s = run(args.isolation, args.iterations, args.seed, args.out_dir)
    sys.exit(0 if s["violations"] == 0 else 1)
