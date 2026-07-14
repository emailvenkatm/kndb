# YCSB-style microbenchmark for the epistemic PoC

Stages 1 and 2 of the paper #2 evaluation.

* Stage 1 measures throughput / abort rate / latency for a YCSB-A / -B
  mix on three targets (epistemic, pg_heap, pg_trigger). Harness in
  `driver/ycsb.py`, orchestrator `run.sh`, results under
  `results/raw/` + `results/summary/`. See F9's gate report at
  `results/summary/README.md`.
* Stage 2 adds a **correctness axis** plus four more baselines
  (pg_lww, pg_llm, pg_conf, pg_mv). Harness in `driver/correctness.py`,
  orchestrator `run_stage2.sh`, results under `results/stage2_raw/`
  + `results/summary/stage2_*.csv`. See `results/summary/stage2.md`
  for the F10 report.

The rest of this file is Stage 1 primary. Stage 2 details live in
`results/summary/stage2.md`.

## Scope, in one sentence

We measure throughput, abort rate, and latency for a YCSB-A / YCSB-B
mix on three targets: (a) the epistemic table AM, (b) plain heap with
no enforcement, and (c) plain heap plus a BEFORE INSERT trigger that
reimplements R1..R5 and the precedence lattice from plpgsql.

## Harness: self-contained Python + psycopg3

We attempted BenchBase first. Blockers: Maven not installed on the
box; BenchBase's stock YCSB templates don't cover our schema
(text[], tstzrange, custom types, no unique index); adapting the
loader takes more time than the wire-format cost of using psycopg3
directly. We built a self-contained driver in `driver/ycsb.py`.

The driver is closed-loop: each client thread holds one PG connection
and issues one txn at a time, waiting for the response before firing
the next. This is exactly what BenchBase's YCSB module does, and it
lets us mint deterministic per-client RNG streams. **Closed-loop
understates tail latency** vs an open-loop generator; the
`driver/openloop.py` probe schedules requests on a wall-clock ticker
to expose queueing delay.

Every result JSON stamps `"notes": "closed-loop; ..."` for
provenance.

## Schema

Three tables. Same columns everywhere. Same width, same types.

| system      | table       | AM                | enforcement path                     |
|-------------|-------------|-------------------|--------------------------------------|
| epistemic   | fact_ep     | USING epistemic   | AM tuple_insert callback (F1..F8)    |
| pg_heap     | fact_heap   | heap (default)    | NONE                                 |
| pg_trigger  | fact_trig   | heap (default)    | BEFORE INSERT trigger in plpgsql     |

The trigger reimplements R1..R5, the precedence lattice
(kind rank -> specificity -> confidence -> first-committer-wins),
and the audit / eviction bookkeeping (UPDATE sys_time upper bound
+ INSERT into `epistemic.evicted_fact`). See `schema/pg_trigger.sql`.

## What we do NOT put on any table

- **No secondary indexes.** `CREATE INDEX` on the epistemic AM fails
  with `ERROR: only heap AM is supported` — the check is at
  `src/backend/access/heap/heapam.c:1352` in REL_18_STABLE
  (`heap_getnext` asserts `sscan->rs_rd->rd_tableam ==
  GetHeapamTableAmRoutine()`). The epistemic AM copies heapam's
  routine and returns a distinct pointer, so the identity check
  refuses. btree's ambuild uses heap_getnext during the scan phase.
  For apples-to-apples across all three targets, `fact_heap` and
  `fact_trig` also drop the secondary index. Every read is therefore
  a seqscan of ~100k rows plus a `sys_time` upper-bound filter.
  Every write is preceded by an overlap seqscan (in the AM's
  `find_live_overlap` or the trigger's `SELECT ... FOR UPDATE`).

This is a real limitation of the current PoC AM. It means the
absolute throughput numbers are LOW compared to a real database
serving an indexed lookup. What we care about is the **relative
comparison** across the three systems; that relative comparison is
still meaningful because all three share the same read cost.

## Workload

- **Population**: 100 000 slots, keyed `(entity_id, attribute)`,
  laid out as `entity = slot // 32, attribute = 'a' || (slot % 32)`.
  ~3125 entities × 32 attributes.
- **Preseed**: 100 000 rows, one per slot, kind=INFERRED (lowest
  rank), specificity=0, confidence=0.5, sources=['src_0']. Loaded
  via `COPY FROM STDIN` for speed.
- **Reads** (uniform): 40-column SELECT filtered by
  `(entity_id, attribute)` and `upper(sys_time) = 'infinity'`.
- **Writes** (Zipfian in slot): INSERT of a new row with value =
  40-char printable ASCII, kind in {INFERRED 70%, MEASURED 20%,
  DERIVED 10%}, specificity in [0, 255] uniform, confidence in
  [0, 1) uniform for INFERRED else 1.0, sources = one random entry
  from a 10-entry pool registered in `epistemic.source_registry`.
- **YCSB-A**: 50% read / 50% write.
- **YCSB-B**: 95% read / 5% write.
- **Zipfian**: reimplemented in `driver/ycsb.py` matching YCSB core
  Java's `ZipfianGenerator`. theta=0 is uniform; theta=0.99 is the
  classic YCSB hot-spot mix.
- **Warm-up** window (default 5s) before measurement starts.
- **Measurement** window (default 30s) counted per successful txn
  and per abort.

Kind mix is chosen so that most writes will actually contend against
the INFERRED preseed rather than trivially outrank them: 20%
MEASURED writes outrank INFERRED, 10% DERIVED writes outrank
INFERRED, and 70% INFERRED writes go through the tie / specificity /
confidence branches — exercising the precedence lattice.

Sources ARE registered in `epistemic.source_registry` so R2 does not
reject INFERRED/DERIVED writes.

## Bypass finding: COPY bypasses the AM callback

We noticed while building the driver that `COPY FROM STDIN` on the
epistemic table bypasses the tuple_insert callback: the AM only
overrides `tuple_insert` and `relation_toast_am`, not
`multi_insert`. COPY calls `table_multi_insert` -> heap's multi
insert, and R1..R5 / advisory-lock / precedence never run. Preseed
takes advantage of this to load 100 000 rows in ~0.3s. Preseed rows
are chosen to pass R1..R5 anyway.

This is an adversary path against the AM. If a role has `COPY` on
the target table it can bypass every write-time rule. In the current
threat model this is equivalent to `session_replication_role =
replica` (both require broad write access) and is worth documenting.
Filed as a bench-time observation; not addressed here.

## Reset between cells

Preseed on the epistemic AM through `tuple_insert` costs ~60s per
100 000 rows (advisory lock + overlap seqscan per row); on the
trigger baseline it is dominated by the trigger's overlap probe
scaling as O(N²) over the growing table. Neither is a per-cell
budget we can absorb.

Between cells we call `reset_workload_state`:

1. `DELETE FROM fact_* WHERE NOT (kind=INFERRED AND spec=0
   AND conf=0.5)` — removes workload-added rows.
2. `UPDATE fact_* SET sys_time = tstzrange(lower, 'infinity')
   WHERE upper(sys_time) <> 'infinity'` — reopens preseed rows that
   the workload evicted.
3. `TRUNCATE epistemic.evicted_fact`.
4. `VACUUM fact_*` to reclaim MVCC space.

`tuple_delete` and `tuple_update` are heap's on the epistemic AM
(README, "What delegates to heap"), so reset does not go through
R1..R5. It runs in a few hundred ms per cell.

Preseed rows are identified by an exact `(kind, spec, conf)`
signature; workload rows never match (kind mix ≠ INFERRED-only,
spec uniform in [0,255], conf uniform in [0,1) has probability 0 of
being exactly 0.5).

## How to run

Assumes:
- Python 3 venv with `psycopg[binary]` at `/tmp/kndb_bench_venv`.
- A running PG 18 cluster on `/tmp/kndb_pg18_test` port 55480 with
  `shared_preload_libraries = 'epistemic'`.
- The extension installed (`make install` from `contrib/epistemic`).

```bash
# venv (one-time)
python3 -m venv /tmp/kndb_bench_venv
/tmp/kndb_bench_venv/bin/pip install 'psycopg[binary]'

# from repo root
cd contrib/epistemic

# validation gate only
YCSB_MODE=gate    bash bench/run.sh

# full primary grid (long)
YCSB_MODE=primary bash bench/run.sh

# everything
YCSB_MODE=all     bash bench/run.sh
```

Environment overrides: `YCSB_DSN`, `YCSB_SEED`, `YCSB_MEAS`,
`YCSB_WARMUP`, `YCSB_RUNS`, `YCSB_MODE`. See `run.sh` for defaults.

Raw JSONs land in `bench/results/raw/`. Summaries roll up to
`bench/results/summary/`.

## Metrics

Every JSON includes:

```
{
  "system": "epistemic|pg_heap|pg_trigger",
  "workload": "ycsb_a|ycsb_b",
  "isolation": "RC|SR",
  "zipfian_theta": 0.99,
  "clients": 64,
  "measurement_seconds": 30,
  "warmup_seconds": 5,
  "seed": 20260712,
  "run_index": 0,
  "hardware": { "os": ..., "cpu": ..., "cores": ..., "ram_gb": ... },
  "pg":       { "version": ..., "shared_buffers": ..., ... },
  "metrics": {
    "throughput_txn_per_s": ...,
    "abort_rate": ...,
    "abort_breakdown": { "40001": ..., "NEW_LOSES": ...,
                         "check_violation": ..., "other": ... },
    "committed_txns": ...,
    "aborted_txns": ...,
    "latency_ms": { "p50": ..., "p95": ..., "p99": ...,
                    "p99_9": ..., "mean": ..., "count": ... }
  },
  "notes": "closed-loop; ..."
}
```

## Caveats to hold in mind while reading the numbers

- **Closed-loop.** Understates tail latency vs open-loop. The
  probe in `driver/openloop.py` runs one open-loop cell.
- **Seqscan-only.** No secondary indexes anywhere; every read /
  overlap probe walks ~100k rows. Absolute tps low; relative
  ratios still meaningful.
- **Synthetic workload.** Slot mix is uniform-in-entity /
  round-robin-in-attribute. Real workloads cluster.
- **macOS ARM hardware.** Apple M5 Pro laptop, 18 cores, 48 GB.
  Do not extrapolate to Linux server iron.
- **Seeded.** Fixed seed by default (`YCSB_SEED=20260712`).
  Different seeds will produce different absolute numbers but the
  relative shape should hold.
- **Postgres unix socket, no network.** psycopg over a unix socket
  avoids TCP overhead a real deployment would pay. Absolute
  throughput is an upper bound on what wire-connected clients
  would see.
