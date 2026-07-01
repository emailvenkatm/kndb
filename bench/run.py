"""M6 benchmark driver.

For each of {kndb, pg_naive, py_guards, pg_handrolled_triggers}:
  1. Load its schema into a fresh Postgres namespace.
  2. Install the slot registry + conflict policy the adversarial suite
     expects.
  3. Emit setup rows (conflict seeds + bitemporal seeds).
  4. Replay the 100 adversarial writes, tallying
       caught_at_write_time / missed_silently / crashed.
  5. On systems that don't crash outright, run a 10k-row valid-write
     throughput micro-benchmark, ≥10 seed repetitions, p50/p95/p99.

All CSVs land in bench/results/{system}/.

Absolute numbers reported here are HONEST but should be read as
RELATIVE overhead (see bench/README.md). The ProvSQL image runs under
amd64 emulation on ARM64 hosts and inflates absolute p50/p95/p99 by an
estimated 1.5-3x versus native amd64.
"""

from __future__ import annotations

import csv
import json
import os
import random
import statistics
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg

# make bench/ importable regardless of cwd
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from adversarial.writes import (  # noqa: E402
    SEED,
    SLOTS,
    REJECT_POLICY_ATTRS,
    generate,
    generate_setup,
)

DSN = os.environ.get("KNDB_DSN", "postgresql://kndb:kndb@localhost:5433/kndb")

REPO = HERE.parent
BASELINES = REPO / "baselines"
RESULTS = HERE / "results"

SYSTEMS = ("kndb", "pg_naive", "py_guards", "pg_handrolled_triggers")

# Per-system dispatch table. Each entry describes how to load the
# schema, where the fact table lives, and how a write is issued.
SYS_META = {
    "kndb": dict(
        schema="kndb",
        fact_table="kndb.fact",
        audit_table="kndb_audit.evicted_fact",
        slot_table="kndb.slot_kind",
        policy_table="kndb.conflict_policy",
        schema_file=None,        # already installed by engine/*.sql
    ),
    "pg_naive": dict(
        schema="baseline_naive",
        fact_table="baseline_naive.fact",
        audit_table=None,
        slot_table=None,
        policy_table=None,
        schema_file=BASELINES / "pg_naive/schema.sql",
    ),
    "py_guards": dict(
        schema="baseline_pyguards",
        fact_table="baseline_pyguards.fact",
        audit_table=None,
        slot_table="baseline_pyguards.slot_kind",
        policy_table=None,
        schema_file=BASELINES / "py_guards/schema.sql",
    ),
    "pg_handrolled_triggers": dict(
        schema="baseline_handrolled",
        fact_table="baseline_handrolled.fact",
        audit_table="baseline_handrolled_audit.evicted_fact",
        slot_table="baseline_handrolled.slot_kind",
        policy_table="baseline_handrolled.conflict_policy",
        schema_file=BASELINES / "pg_handrolled_triggers/schema.sql",
    ),
}

# ---------------------------------------------------------------------------
# Bring each system to a known, empty state.
# ---------------------------------------------------------------------------

def _reset_kndb(conn: psycopg.Connection) -> None:
    # KNDB_PRESERVE_FACTS=1 keeps whatever is already in kndb.fact (used by
    # bench/run_synthea.sh to measure adversarial catch + throughput against
    # the Synthea-preloaded 565k-row DB, closing G2.3 in the task spec).
    if os.environ.get("KNDB_PRESERVE_FACTS") == "1":
        # Still reset the registries so slot_kind and conflict_policy are known.
        with conn.cursor() as cur:
            cur.execute("TRUNCATE kndb.slot_kind, kndb.conflict_policy CASCADE")
        conn.commit()
        return
    with conn.cursor() as cur:
        cur.execute("TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.slot_kind, kndb.conflict_policy CASCADE")
    conn.commit()


def _reset_baseline(conn: psycopg.Connection, name: str) -> None:
    m = SYS_META[name]
    schema_sql = m["schema_file"].read_text()
    with conn.cursor() as cur:
        # DROP SCHEMA CASCADE for a clean slate, then re-apply schema.
        cur.execute(f"DROP SCHEMA IF EXISTS {m['schema']} CASCADE")
        if name == "pg_handrolled_triggers":
            cur.execute("DROP SCHEMA IF EXISTS baseline_handrolled_audit CASCADE")
        cur.execute(schema_sql)
    conn.commit()


def _install_slots_and_policies(conn: psycopg.Connection, name: str) -> None:
    m = SYS_META[name]
    with conn.cursor() as cur:
        if m["slot_table"]:
            for attr, kind in SLOTS.items():
                cur.execute(
                    f"INSERT INTO {m['slot_table']} (attribute, required_kind) VALUES (%s, %s) "
                    "ON CONFLICT (attribute) DO UPDATE SET required_kind = EXCLUDED.required_kind",
                    (attr, kind),
                )
        if m["policy_table"]:
            for attr in REJECT_POLICY_ATTRS:
                cur.execute(
                    f"INSERT INTO {m['policy_table']} (attribute, policy) VALUES (%s, 'reject') "
                    "ON CONFLICT (attribute) DO UPDATE SET policy = EXCLUDED.policy",
                    (attr,),
                )
    conn.commit()


# ---------------------------------------------------------------------------
# Write dispatch: each system has slightly different behavior.
#   - kndb / handrolled / naive: raw INSERT into fact_table.
#   - py_guards: goes through guards.py.
# ---------------------------------------------------------------------------

def _raw_insert(cur, fact_table: str, payload: dict) -> None:
    cur.execute(
        f"""
        INSERT INTO {fact_table}
          (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
        VALUES (%s, %s, %s, %s, %s, %s, %s::tstzrange)
        RETURNING fact_id
        """,
        (
            payload["entity_id"],
            payload["attribute"],
            payload["value"],
            payload["epistemic_kind"],
            payload["confidence"],
            payload["sources"],
            payload["valid_time"],
        ),
    )
    _ = cur.fetchone()


def _pyguards_insert(conn: psycopg.Connection, payload: dict) -> None:
    # Import here to avoid slowing the CLI when py_guards not used.
    sys.path.insert(0, str(BASELINES / "py_guards"))
    import guards  # noqa: WPS433
    guards.write_fact(
        conn,
        entity_id=payload["entity_id"],
        attribute=payload["attribute"],
        value=payload["value"],
        epistemic_kind=payload["epistemic_kind"],
        confidence=float(payload["confidence"]),
        valid_time=payload["valid_time"],
        sources=payload["sources"],
    )


def _issue_write(conn: psycopg.Connection, name: str, payload: dict) -> None:
    m = SYS_META[name]
    if name == "py_guards":
        _pyguards_insert(conn, payload)
    else:
        with conn.cursor() as cur:
            _raw_insert(cur, m["fact_table"], payload)


# ---------------------------------------------------------------------------
# Sentinel substitution: some payloads refer to `__SEED_FACT__` for a source
# UUID. Replace with a real fact_id we insert up front.
# ---------------------------------------------------------------------------

def _install_seed_fact(conn: psycopg.Connection, name: str) -> str:
    """Insert a single observation and return its UUID as a source anchor."""
    m = SYS_META[name]
    payload = dict(
        entity_id=99999,
        attribute=f"seed_anchor_{name}",
        value="1.0",
        epistemic_kind="observation",
        confidence=0.99,
        sources=[],
        valid_time="[2026-01-01, 2027-01-01)",
    )
    if name == "py_guards":
        # guards.py returns UUID string
        sys.path.insert(0, str(BASELINES / "py_guards"))
        import guards  # noqa: WPS433
        return guards.write_fact(
            conn,
            entity_id=payload["entity_id"],
            attribute=payload["attribute"],
            value=payload["value"],
            epistemic_kind=payload["epistemic_kind"],
            confidence=float(payload["confidence"]),
            valid_time=payload["valid_time"],
            sources=payload["sources"],
        )
    with conn.cursor() as cur:
        cur.execute(
            f"""INSERT INTO {m['fact_table']}
                (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
                VALUES (%s, %s, %s, %s, %s, %s, %s::tstzrange)
                RETURNING fact_id""",
            (99999, f"seed_anchor_{name}", "1.0", "observation", 0.99, [], "[2026-01-01, 2027-01-01)"),
        )
        return str(cur.fetchone()[0])


def _resolve_sentinels(payload: dict, seed_uuid: str) -> dict:
    if payload["sources"] and "__SEED_FACT__" in payload["sources"]:
        payload = {**payload, "sources": [seed_uuid if s == "__SEED_FACT__" else s for s in payload["sources"]]}
    return payload


# ---------------------------------------------------------------------------
# Adversarial replay.
# ---------------------------------------------------------------------------

def replay_adversarial(system: str) -> dict:
    conn = psycopg.connect(DSN, autocommit=False)
    conn.autocommit = False
    try:
        if system == "kndb":
            _reset_kndb(conn)
        else:
            _reset_baseline(conn, system)
        _install_slots_and_policies(conn, system)

        # Seed anchor for progressive-depth `__SEED_FACT__` sentinels.
        conn.autocommit = True
        seed_uuid = _install_seed_fact(conn, system)
        conn.autocommit = False

        # Setup rows (conflict + bitemporal seeds).
        setup = generate_setup(SEED)
        for row in setup:
            try:
                conn.autocommit = True
                _issue_write(conn, system, row["payload"])
            except Exception as exc:  # noqa: BLE001
                # Setup rows must land. If they don't, this system can't
                # even host the adversarial test — record and continue.
                print(f"[{system}] SETUP WARNING: {row['reason']}: {exc}", file=sys.stderr)
            finally:
                conn.autocommit = False

        # Replay adversarial writes, autocommit per row so a rejection
        # doesn't poison the transaction for the next row.
        conn.autocommit = True

        adv = generate(SEED)
        per_row: list[dict] = []
        caught = missed = crashed = 0
        # Postgres constraint / trigger errors we treat as a legitimate
        # "caught at write time" — the DB refused the write for a real
        # policy reason.
        CATCH_ERRORS = (
            psycopg.errors.CheckViolation,
            psycopg.errors.ForeignKeyViolation,
            psycopg.errors.ExclusionViolation,
            psycopg.errors.RaiseException,
            psycopg.errors.NumericValueOutOfRange,
            psycopg.errors.InvalidTextRepresentation,
        )
        for row in adv:
            payload = _resolve_sentinels(row["payload"], seed_uuid)
            outcome = None
            error_class = None
            error_msg = None
            landed = False
            try:
                _issue_write(conn, system, payload)
                landed = True
            except CATCH_ERRORS as e:
                outcome = "caught"
                error_class = type(e).__name__
                error_msg = str(e).splitlines()[0]
            except Exception as e:  # noqa: BLE001
                cname = type(e).__name__
                if cname == "GuardRejection":
                    outcome = "caught"
                else:
                    outcome = "crashed"
                error_class = cname
                error_msg = str(e).splitlines()[0]

            if landed:
                if row["should_be_rejected"]:
                    outcome = "missed"
                    missed += 1
                else:
                    outcome = "landed_ok"
            else:
                if outcome == "caught":
                    if row["should_be_rejected"]:
                        caught += 1
                    else:
                        # A compliant write got rejected — over-rejection
                        # counts as a fault, tallied under crashed.
                        outcome = "over_rejected"
                        crashed += 1
                elif outcome == "crashed":
                    crashed += 1

            per_row.append(dict(
                system=system,
                id=row["id"],
                bucket=row["bucket"],
                reason=row["reason"],
                should_be_rejected=row["should_be_rejected"],
                outcome=outcome,
                error_class=error_class or "",
                error_msg=(error_msg or "").replace("\n", " ")[:400],
            ))

        totals = dict(
            system=system,
            total=len(adv),
            caught_at_write_time=caught,
            missed_silently=missed,
            crashed=crashed,
        )
        return dict(per_row=per_row, totals=totals)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Throughput micro-benchmark (KNDB + hand-rolled only).
# ---------------------------------------------------------------------------

def throughput(system: str, rows: int = 10_000, seed_reps: int = 10) -> dict:
    """Insert `rows` legal observations, `seed_reps` seed repetitions.

    Returns per-seed p50/p95/p99 per-row latency and aggregate throughput.
    """
    m = SYS_META[system]
    all_p50, all_p95, all_p99, all_thru = [], [], [], []

    for rep in range(seed_reps):
        conn = psycopg.connect(DSN, autocommit=True)
        try:
            # Fresh state for each rep.
            if system == "kndb":
                _reset_kndb(conn)
            else:
                _reset_baseline(conn, system)
            _install_slots_and_policies(conn, system)

            rng = random.Random(SEED + rep)
            base = datetime(2026, 1, 1, tzinfo=timezone.utc)
            latencies_us: list[float] = []

            with conn.cursor() as cur:
                t0 = time.perf_counter()
                for i in range(rows):
                    payload_ts = base + timedelta(seconds=i)  # unique valid_time per row
                    vt = f"[{payload_ts.strftime('%Y-%m-%d %H:%M:%S%z')}, {(payload_ts + timedelta(seconds=1)).strftime('%Y-%m-%d %H:%M:%S%z')})"
                    ts = time.perf_counter()
                    cur.execute(
                        f"""INSERT INTO {m['fact_table']}
                            (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
                            VALUES (%s, %s, %s, %s, %s, %s, %s::tstzrange)""",
                        (
                            rng.randint(1, 10_000_000),  # unique-ish entity so no conflict
                            f"tp_{rep}_{i}",
                            f"{rng.uniform(0, 100):.2f}",
                            "observation",
                            round(rng.uniform(0.5, 0.99), 3),
                            [],
                            vt,
                        ),
                    )
                    latencies_us.append((time.perf_counter() - ts) * 1_000_000)
                dt = time.perf_counter() - t0

            all_p50.append(statistics.median(latencies_us))
            all_p95.append(statistics.quantiles(latencies_us, n=20)[18])
            all_p99.append(statistics.quantiles(latencies_us, n=100)[98])
            all_thru.append(rows / dt)
        finally:
            conn.close()

    return dict(
        system=system,
        rows=rows,
        seed_reps=seed_reps,
        latency_us_p50_mean=statistics.mean(all_p50),
        latency_us_p95_mean=statistics.mean(all_p95),
        latency_us_p99_mean=statistics.mean(all_p99),
        throughput_rps_mean=statistics.mean(all_thru),
        latency_us_p50_all=all_p50,
        latency_us_p95_all=all_p95,
        latency_us_p99_all=all_p99,
        throughput_rps_all=all_thru,
    )


# ---------------------------------------------------------------------------
# Persistence.
# ---------------------------------------------------------------------------

def _write_totals_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        return
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)


def _write_per_row_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        return
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)


def _write_throughput_csv(path: Path, tp: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["seed_rep", "p50_us", "p95_us", "p99_us", "throughput_rps"])
        n = len(tp["latency_us_p50_all"])
        for i in range(n):
            w.writerow([
                i,
                tp["latency_us_p50_all"][i],
                tp["latency_us_p95_all"][i],
                tp["latency_us_p99_all"][i],
                tp["throughput_rps_all"][i],
            ])
        w.writerow([])
        w.writerow(["mean", tp["latency_us_p50_mean"], tp["latency_us_p95_mean"], tp["latency_us_p99_mean"], tp["throughput_rps_mean"]])


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)
    summary: list[dict] = []
    all_perrow: list[dict] = []

    for sysname in SYSTEMS:
        print(f"\n=== {sysname}: adversarial replay ===", flush=True)
        try:
            r = replay_adversarial(sysname)
            print(f"[{sysname}] totals: {r['totals']}", flush=True)
            _write_totals_csv(RESULTS / sysname / "adversarial_totals.csv", [r["totals"]])
            _write_per_row_csv(RESULTS / sysname / "adversarial_per_row.csv", r["per_row"])
            summary.append(r["totals"])
            all_perrow.extend(r["per_row"])
        except Exception as e:  # noqa: BLE001
            print(f"[{sysname}] FAILED: {type(e).__name__}: {e}", flush=True)
            summary.append(dict(system=sysname, total=0, caught_at_write_time=0, missed_silently=0, crashed=-1))

    _write_totals_csv(RESULTS / "summary_totals.csv", summary)
    _write_per_row_csv(RESULTS / "summary_per_row.csv", all_perrow)

    # Throughput on KNDB + hand-rolled only. Configurable via env var to
    # keep quick smoke runs fast; defaults per spec.
    rows_tp = int(os.environ.get("KNDB_TP_ROWS", "10000"))
    reps_tp = int(os.environ.get("KNDB_TP_REPS", "10"))

    for sysname in ("kndb", "pg_handrolled_triggers"):
        print(f"\n=== {sysname}: throughput ({rows_tp} rows x {reps_tp} reps) ===", flush=True)
        try:
            tp = throughput(sysname, rows=rows_tp, seed_reps=reps_tp)
            print(
                f"[{sysname}] p50={tp['latency_us_p50_mean']:.1f}us "
                f"p95={tp['latency_us_p95_mean']:.1f}us "
                f"p99={tp['latency_us_p99_mean']:.1f}us "
                f"thru={tp['throughput_rps_mean']:.1f} rps",
                flush=True,
            )
            _write_throughput_csv(RESULTS / sysname / "throughput.csv", tp)
        except Exception as e:  # noqa: BLE001
            print(f"[{sysname}] throughput FAILED: {type(e).__name__}: {e}", flush=True)

    # Manifest.
    manifest = dict(
        seed=SEED,
        dsn=DSN,
        systems=list(SYSTEMS),
        rows_tp=rows_tp,
        reps_tp=reps_tp,
        run_at=datetime.now(timezone.utc).isoformat(),
    )
    (RESULTS / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print("\nDone. See", RESULTS)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
