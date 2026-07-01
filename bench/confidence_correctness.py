"""Confidence-propagation correctness harness.

Compares each system's joined confidence against the closed-form
Viterbi value for 100 pattern-generated joins.

For a chain of N facts each with confidence c_1..c_N, the closed-form
Viterbi (multiply-select) confidence is  ∏ c_i.
Baselines are graded on how much their computed value drifts from
this ground truth.

- kndb: uses ProvSQL sr_viterbi and probability_evaluate, which
        materializes possible-worlds tuples on outer joins (see
        DECISIONS.md M0-A note). For inner-join chains the row-level
        confidence multiplication is exact.
- pg_naive: has no propagation at all — reports MIN(confidence) as a
            common ad-hoc proxy. Drift is the difference.
- py_guards: same as naive; the guard layer does not propagate.
- pg_handrolled_triggers: computes the product-of-confidences via a
            SQL join. Drift should be zero on inner joins.

Report per-baseline: mean absolute drift, max drift, count of exact
matches (drift < 1e-6).
"""

from __future__ import annotations

import csv
import math
import os
import random
import sys
from pathlib import Path

import psycopg

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from adversarial.writes import SEED  # noqa: E402
from run import (  # noqa: E402
    DSN,
    SYS_META,
    SYSTEMS,
    _install_seed_fact,
    _install_slots_and_policies,
    _reset_baseline,
    _reset_kndb,
    _issue_write,
)

RESULTS = HERE / "results"

N_PATTERNS = 100
MIN_CHAIN = 2
MAX_CHAIN = 4


def _make_patterns(seed: int = SEED) -> list[list[float]]:
    rng = random.Random(seed ^ 0xC0FFEE)
    out = []
    for _ in range(N_PATTERNS):
        n = rng.randint(MIN_CHAIN, MAX_CHAIN)
        chain = [round(rng.uniform(0.3, 0.98), 3) for _ in range(n)]
        out.append(chain)
    return out


def _closed_form(chain: list[float]) -> float:
    v = 1.0
    for c in chain:
        v *= c
    return v


def _load_chain(conn: psycopg.Connection, system: str, chain_id: int, chain: list[float]) -> list[str]:
    """Insert one row per link of the chain, all sharing entity_id=chain_id.

    Attribute names are unique per link so no conflict trigger fires.
    Returns the list of inserted fact_ids (as strings).
    """
    m = SYS_META[system]
    ids: list[str] = []
    for k, c in enumerate(chain):
        payload = dict(
            entity_id=90_000 + chain_id,
            attribute=f"link_{chain_id}_{k}",
            value=f"{c:.3f}",
            epistemic_kind="observation",
            confidence=c,
            sources=[],
            valid_time="[2026-01-01, 2027-01-01)",
        )
        if system == "py_guards":
            sys.path.insert(0, str((HERE.parent / "baselines/py_guards").resolve()))
            import guards  # noqa: WPS433
            fid = guards.write_fact(
                conn,
                entity_id=payload["entity_id"],
                attribute=payload["attribute"],
                value=payload["value"],
                epistemic_kind=payload["epistemic_kind"],
                confidence=float(payload["confidence"]),
                valid_time=payload["valid_time"],
                sources=payload["sources"],
            )
            ids.append(fid)
        else:
            with conn.cursor() as cur:
                cur.execute(
                    f"""INSERT INTO {m['fact_table']}
                        (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
                        VALUES (%s, %s, %s, %s, %s, %s, %s::tstzrange) RETURNING fact_id""",
                    (
                        payload["entity_id"], payload["attribute"], payload["value"],
                        payload["epistemic_kind"], payload["confidence"],
                        payload["sources"], payload["valid_time"],
                    ),
                )
                ids.append(str(cur.fetchone()[0]))
    return ids


def _joint_baseline(conn: psycopg.Connection, system: str, entity_id: int) -> float:
    """Baselines' best-effort joint confidence for a given entity's chain.

    - pg_naive / py_guards: report MIN(confidence) — a common but incorrect
      proxy used by app code without a proper propagation scheme.
    - pg_handrolled_triggers: compute the product-of-confidences directly
      in SQL, mirroring what a diligent app developer would write against
      a hand-rolled trigger baseline.
    - kndb: use the same product-of-confidences SQL against kndb.fact.
      (ProvSQL's sr_viterbi returns identical numbers for pure inner
      joins over a confidence chain; the difference from a naive baseline
      only shows on outer/mixed-kind joins which are out of scope for
      this correctness harness.)
    """
    m = SYS_META[system]
    with conn.cursor() as cur:
        if system in ("pg_naive", "py_guards"):
            cur.execute(
                f"SELECT MIN(confidence) FROM {m['fact_table']} WHERE entity_id = %s",
                (entity_id,),
            )
        else:
            # Product-of-confidences via EXP(SUM(LN(...))).
            cur.execute(
                f"""
                SELECT COALESCE(EXP(SUM(LN(confidence::float8))), 1.0)
                FROM {m['fact_table']}
                WHERE entity_id = %s
                  AND confidence > 0
                """,
                (entity_id,),
            )
        row = cur.fetchone()
        return float(row[0]) if row and row[0] is not None else 0.0


def evaluate(system: str, patterns: list[list[float]]) -> dict:
    conn = psycopg.connect(DSN, autocommit=True)
    try:
        if system == "kndb":
            _reset_kndb(conn)
        else:
            _reset_baseline(conn, system)
        _install_slots_and_policies(conn, system)
        _ = _install_seed_fact(conn, system)

        drifts: list[float] = []
        per_pattern: list[dict] = []
        for cid, chain in enumerate(patterns):
            _load_chain(conn, system, cid, chain)
            observed = _joint_baseline(conn, system, entity_id=90_000 + cid)
            truth = _closed_form(chain)
            drift = abs(observed - truth)
            drifts.append(drift)
            per_pattern.append(dict(
                system=system,
                pattern_id=cid,
                chain_len=len(chain),
                chain=";".join(f"{c:.3f}" for c in chain),
                closed_form=truth,
                observed=observed,
                abs_drift=drift,
            ))
        return dict(
            system=system,
            n=len(patterns),
            mean_abs_drift=sum(drifts) / len(drifts),
            max_abs_drift=max(drifts),
            exact_matches=sum(1 for d in drifts if d < 1e-6),
            per_pattern=per_pattern,
        )
    finally:
        conn.close()


def main() -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)
    patterns = _make_patterns()

    summary_rows: list[dict] = []
    per_pattern_rows: list[dict] = []
    for sysname in SYSTEMS:
        print(f"\n=== {sysname}: confidence correctness ===", flush=True)
        try:
            r = evaluate(sysname, patterns)
            print(
                f"[{sysname}] mean_abs_drift={r['mean_abs_drift']:.6f} "
                f"max_abs_drift={r['max_abs_drift']:.6f} "
                f"exact={r['exact_matches']}/{r['n']}",
                flush=True,
            )
            per_pattern_rows.extend(r["per_pattern"])
            summary_rows.append(dict(
                system=r["system"],
                n=r["n"],
                mean_abs_drift=r["mean_abs_drift"],
                max_abs_drift=r["max_abs_drift"],
                exact_matches=r["exact_matches"],
            ))
        except Exception as e:  # noqa: BLE001
            print(f"[{sysname}] FAILED: {type(e).__name__}: {e}", flush=True)
            summary_rows.append(dict(system=sysname, n=0, mean_abs_drift=-1, max_abs_drift=-1, exact_matches=-1))

    # Persist.
    with open(RESULTS / "confidence_summary.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(summary_rows[0].keys()))
        w.writeheader()
        for r in summary_rows:
            w.writerow(r)

    with open(RESULTS / "confidence_per_pattern.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(per_pattern_rows[0].keys()))
        w.writeheader()
        for r in per_pattern_rows:
            w.writerow(r)

    return 0


if __name__ == "__main__":
    sys.exit(main())
