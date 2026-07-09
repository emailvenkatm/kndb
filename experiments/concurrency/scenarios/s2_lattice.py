"""S2 lattice race.

Thread A INSERTs INFERRED (confidence 0.97). Thread B INSERTs MEASURED
(confidence 0.90). Same (entity_id, attribute), overlapping valid_time.
Commit-order coin flip covers both orderings across the 1 000 iterations.

Invariant: the live winner is the MEASURED row regardless of commit
order. The lattice must not be order-dependent under concurrency. If the
INFERRED write happens to land alone (because the MEASURED write races
into an exclusion violation and fails), we consider that a violation
too, since it means the lattice's kind-rank guarantee is not durable
against a losing commit race.
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
from harness.invariants import (
    InvariantResult,
    live_kind_is,
    no_two_live_for_slot,
)
from harness.metrics import hardware_provenance
from harness.paired import run_paired_scenario
from harness.payloads import FactPayload, default_valid_range, inferred, measured


SCENARIO_LABEL = "s2_lattice"


def make_payloads(iteration: int, rng: random.Random) -> tuple[FactPayload, FactPayload]:
    entity_id = 32_000_000 + iteration
    attribute = "s2_slot"
    lower, upper = default_valid_range()
    payload_a = inferred(
        entity_id=entity_id,
        attribute=attribute,
        value=f"INFERRED_iter{iteration}",
        confidence=0.97,
        valid_range=(lower, upper),
    )
    payload_b = measured(
        entity_id=entity_id,
        attribute=attribute,
        value=f"MEASURED_iter{iteration}",
        confidence=0.90,
        valid_range=(lower, upper),
    )
    return payload_a, payload_b


def _lattice_invariants(conn, payload_a: FactPayload, payload_b: FactPayload) -> list[InvariantResult]:
    """Two checks per iteration.

    1. There is at most one live row for the slot (no double-write leak).
    2. If one live row exists, its epistemic_kind is MEASURED (lattice
       guarantee holds under concurrency). The zero-live case is treated
       as a violation because it would mean both writes lost, which is
       not what the lattice promises: MEASURED should have landed.
    """
    ex = no_two_live_for_slot(conn, payload_a.entity_id, payload_a.attribute)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT count(*) FROM kndb.fact
             WHERE entity_id = %s AND attribute = %s AND upper(sys_time) = 'infinity'
            """,
            (payload_a.entity_id, payload_a.attribute),
        )
        live_n = cur.fetchone()[0]
    if not ex.ok:
        return [ex]
    if live_n == 0:
        return [
            ex,
            InvariantResult(
                ok=False,
                label="lattice_landed_measured",
                detail="no live row survived; MEASURED should have won",
            ),
        ]
    return [ex, live_kind_is(conn, payload_a.entity_id, payload_a.attribute, "MEASURED")]


def run(isolation: str, iterations: int, seed: int, out_dir: Path) -> dict:
    print(f"[{SCENARIO_LABEL}] isolation={isolation} iterations={iterations}", flush=True)

    truncate_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    truncate_fact_state(truncate_conn)
    provenance = query_server_provenance(truncate_conn)
    truncate_conn.close()

    started = time.time()
    results = run_paired_scenario(
        label=SCENARIO_LABEL,
        make_payloads=make_payloads,
        invariant_fn=_lattice_invariants,
        isolation=isolation,
        iterations=iterations,
        seed=seed,
        stop_after_first_violation=False,
    )
    wall = time.time() - started

    n_iter = len(results)
    n_violations = sum(1 for r in results if not r.ok)
    n_a_first = sum(1 for r in results if r.commit_hint_first == "A")
    n_b_first = sum(1 for r in results if r.commit_hint_first == "B")
    n_a_first_violation = sum(1 for r in results if r.commit_hint_first == "A" and not r.ok)
    n_b_first_violation = sum(1 for r in results if r.commit_hint_first == "B" and not r.ok)

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
                "thread_a_committed",  # INFERRED
                "thread_b_committed",  # MEASURED
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
        "hint_A_first_iters": n_a_first,
        "hint_B_first_iters": n_b_first,
        "hint_A_first_violations": n_a_first_violation,
        "hint_B_first_violations": n_b_first_violation,
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
