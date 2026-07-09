"""S1 exclusion race.

Two threads INSERT a MEASURED fact for the SAME (entity_id, attribute)
with the SAME valid_time. Values differ so same-value absorption is not
triggered. Invariant: at most one live row survives the race for that
slot; the other side is either rejected outright or the loser lands in
kndb_audit.evicted_fact.

Two live rows for the same slot is a bug.
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
from harness.invariants import InvariantResult, no_two_live_for_slot
from harness.metrics import hardware_provenance
from harness.paired import run_paired_scenario
from harness.payloads import FactPayload, default_valid_range, measured


SCENARIO_LABEL = "s1_exclusion"


def make_payloads(iteration: int, rng: random.Random) -> tuple[FactPayload, FactPayload]:
    entity_id = 30_000_000 + iteration
    attribute = "s1_slot"
    lower, upper = default_valid_range()
    payload_a = measured(
        entity_id=entity_id,
        attribute=attribute,
        value=f"A_iter{iteration}",
        valid_range=(lower, upper),
    )
    payload_b = measured(
        entity_id=entity_id,
        attribute=attribute,
        value=f"B_iter{iteration}",
        valid_range=(lower, upper),
    )
    return payload_a, payload_b


def invariants(conn, payload_a: FactPayload, payload_b: FactPayload) -> list[InvariantResult]:
    return [no_two_live_for_slot(conn, payload_a.entity_id, payload_a.attribute)]


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
        invariant_fn=invariants,
        isolation=isolation,
        iterations=iterations,
        seed=seed,
        stop_after_first_violation=False,
    )
    wall = time.time() - started

    n_iter = len(results)
    n_violations = sum(1 for r in results if not r.ok)
    n_both_committed = sum(1 for r in results if r.thread_a_committed and r.thread_b_committed)
    n_one_committed = sum(1 for r in results if r.thread_a_committed != r.thread_b_committed)
    n_both_failed = sum(1 for r in results if not r.thread_a_committed and not r.thread_b_committed)

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
                "thread_a_committed",
                "thread_b_committed",
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
        "both_committed": n_both_committed,
        "one_committed": n_one_committed,
        "both_failed": n_both_failed,
        "wall_clock_s": wall,
        "iterations_per_s": n_iter / wall if wall > 0 else 0.0,
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
    manifest_path = out_dir / f"{SCENARIO_LABEL}_{iso_slug}_manifest.json"
    with manifest_path.open("w") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"[{SCENARIO_LABEL}] {summary}", flush=True)
    return summary


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--isolation", default="READ COMMITTED", choices=["READ COMMITTED", "SERIALIZABLE"])
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=HERE.parent / "results",
    )
    args = parser.parse_args()
    s = run(args.isolation, args.iterations, args.seed, args.out_dir)
    sys.exit(0 if s["violations"] == 0 else 1)
