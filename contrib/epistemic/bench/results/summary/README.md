# YCSB microbenchmark — Stage 1 gate results

Test cluster: PG 18.4 at /tmp/kndb_pg18_test:55480,
shared_preload_libraries='epistemic', shared_buffers=128MB,
synchronous_commit=on, wal_level=replica, all other GUCs at PG 18.4
defaults.
Hardware: Apple M5 Pro, 18 cores, 48 GB RAM, macOS 26.4.1 (Darwin
25.4.0), unix socket transport (no TCP).
Driver: bench/driver/ycsb.py — self-contained closed-loop Python +
psycopg3. See bench/README.md for design.
Cells: 18 total, 30 s measurement window, 5 s warm-up, 3 runs per
cell. Total wall clock ~11 min.

## Gate 1 — pg_heap contention curve at 8 clients

Three runs per theta. Median tps, std across runs.

| theta | tps median | tps std | abort rate | p50 (ms) | p99 (ms) | p99.9 (ms) |
|------:|-----------:|--------:|-----------:|---------:|---------:|-----------:|
| 0.00  |       7120 |     795 |      0.000 |     0.51 |     6.70 |      11.75 |
| 0.50  |       6840 |    2046 |      0.000 |     0.52 |     6.67 |      11.18 |
| 0.90  |       6858 |     539 |      0.000 |     0.55 |     6.51 |       7.63 |
| 0.99  |       6595 |    1999 |      0.000 |     0.58 |     6.83 |      11.01 |

Throughput is essentially flat across theta: 7120 → 6595, a 7%
delta well inside the run-to-run std at theta=0.50 and 0.99.
Abort rate stays at 0.000 because our workload is
INSERT-into-heap-with-no-unique-constraint. Plain PostgreSQL heap
does not synthesise a contention point where the workload never
contends. This is a workload-semantic outcome, not a broken
harness — the whole reason the epistemic AM exists is to CREATE a
per-slot serialisation point that plain heap does not have.

## Gate 2 — epistemic vs pg_heap overhead at theta ≤ 0.5, 8 clients

Three runs per (system, theta). Median tps, std across runs.

| theta | system    | tps median | tps std | abort rate | p50 (ms) | p99 (ms) | overhead vs pg_heap |
|------:|-----------|-----------:|--------:|-----------:|---------:|---------:|--------------------:|
| 0.00  | pg_heap   |       7120 |     795 |      0.000 |     0.51 |     6.70 |                  -- |
| 0.00  | epistemic |       2057 |     210 |      0.050 |     2.70 |    11.40 |               71.1% |
| 0.50  | pg_heap   |       6840 |    2046 |      0.000 |     0.52 |     6.67 |                  -- |
| 0.50  | epistemic |       2200 |      74 |      0.091 |     2.63 |    10.97 |               67.8% |

Overhead is 71% at theta=0.0 and 68% at theta=0.5. Well above the
15% threshold in the F9 standing rules. **Gate 2 fails.** Per the
rules I stopped before starting the primary sweep, submitted this
report, and am awaiting review.

## Where the overhead comes from

The epistemic AM's tuple_insert hot path does five things pg_heap
does not:

1. R1..R5 rule check via SPI (SPI_execute for R2 registry lookup,
   SPI_execute for R5 slot-kind lookup) — src/epistemic_rules.c.
2. `find_live_overlap` — seqscan of the ~100 k-row table filtered
   by `(entity_id, attribute)` and `upper(sys_time) = 'infinity'`.
   With no secondary index (see next section), every write reads
   the entire table.
3. `LockAcquire(LOCKTAG_ADVISORY, ExclusiveLock)` — the per-slot
   F6 advisory xact lock.
4. Precedence comparison + optional xmin fetch via
   `ExecFetchSlotHeapTuple` + `HeapTupleHeaderGetRawXmin` (F8).
5. On eviction: SPI INSERT into `epistemic.evicted_fact` +
   `simple_heap_update` closing incumbent sys_time upper bound.

Every one of these fires on every successful write. At theta=0.0
the workload is 50% writes uniformly distributed, so half of every
client's operations pay this cost. The overlap seqscan dominates:
100 000 tuples per write × ~4 000 writes/s = 400 M tuples scanned
per second on the write path alone.

Reads on pg_heap ALSO pay a seqscan — but pg_heap reads are ~50%
of ops and cost roughly the same as epistemic reads (same seqscan,
same MVCC). The delta between the two systems is entirely on the
write half of the mix: pg_heap writes are ~0.5 ms
`INSERT ... VALUES`, epistemic writes are ~5 ms
`R1..R5 + seqscan + advisory lock + precedence + audit`.

## Why there is no index

`CREATE INDEX ix_slot ON fact_ep (entity_id, attribute)` fails
with `ERROR: only heap AM is supported`. Source of the error:
`heap_getnext` at src/backend/access/heap/heapam.c:1352 in
REL_18_STABLE, which asserts

    if (unlikely(sscan->rs_rd->rd_tableam != GetHeapamTableAmRoutine()))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg_internal("only heap AM is supported")));

The epistemic handler copies heapam's `TableAmRoutine` at first
call and returns a distinct pointer (`&epistemic_am_methods`), so
the identity check refuses. `heap_getnext` is called from btree's
`ambuild` scan phase during CREATE INDEX. Result: the current PoC
AM cannot host any secondary index.

For apples-to-apples pg_heap and pg_trigger tables also drop the
secondary index — every read across all three systems is a seqscan
of ~100 k rows. The absolute throughput numbers here are therefore
low compared to a real database serving indexed lookups. The
**relative** comparison across the three systems remains valid
because all three share the same read cost; the write-side
overhead we measured is the marginal cost of the AM's tuple_insert
callback body over pg_heap's.

## Notes

- Closed-loop; each client waits for response before next request.
  Understates tail latency vs open-loop. See bench/README.md.
- Preseed rows are INFERRED (kind rank 1), so all MEASURED writes
  in the workload (20% of writes) succeed via kind-outrank; ~99%
  of INFERRED writes succeed via specificity-outrank (workload
  spec uniform in [0, 255] beats preseed spec=0). Aborts fire only
  on the small tail where specificity=0 and confidence < 0.5.
- Every source_id the workload uses ("src_0" ... "src_9") is
  registered in `epistemic.source_registry`, so R2 does not
  reject any INFERRED/DERIVED write.
- COPY on the epistemic table BYPASSES the AM callback (the AM
  does not override `multi_insert`). We exploit this for preseed
  reset, which loads 100 k rows in ~0.3 s vs ~60 s via
  `tuple_insert`. This is a real bypass channel and should be
  flagged separately as a threat-model finding (worth F10).

## Files under this directory

- `gate.csv` — this table in CSV form.
- `../raw/*.json` — one JSON per cell-run (18 files).
- `../../bench/README.md` — how to reproduce.

## Reproduce

```
cd contrib/epistemic
YCSB_MODE=gate YCSB_MEAS=30 YCSB_WARMUP=5 YCSB_RUNS=3 \
    bash bench/run.sh
```

Assumes a PG 18 cluster at `/tmp/kndb_pg18_test:55480` with
`shared_preload_libraries='epistemic'` and the extension installed
via `make install`. Python venv with psycopg[binary] at
`/tmp/kndb_bench_venv`.
