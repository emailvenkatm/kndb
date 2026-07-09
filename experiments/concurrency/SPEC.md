# Concurrency experiment spec

Frozen at commit time so a reviewer can see exactly what we intended to
measure. Any deviation from this spec must be documented in RESULTS.md
under "deviations from SPEC".

## Setup

- Database `kndb_concur` on the native Homebrew Postgres 17.10, port 5434,
  isolated from `kndb_native`. `max_connections = 200`. All eight engine
  files applied (00 extensions through 08 use permissions).
- Slot registry seeded at bootstrap:
  - `hba1c` -> MEASURED
  - `ldl` -> MEASURED
  - `is_diabetic` -> INFERRED
- The concurrency harness never disables or bypasses any engine trigger.

## Provenance recorded per run

Every result CSV has a sibling `manifest.json` with:
- `run_at` (ISO 8601)
- `git_commit`, `git_branch`
- `hardware` (Apple M5 Pro, 18 cores 6P+12E, 48 GB)
- `os` (macOS 26.4.1 Build 25E253)
- `kernel` (uname -a)
- `postgres` (server_version + build)
- `provsql` (extension version)
- `max_connections`
- `seed = 42`
- `scenario` or `sweep_cell`

## Correctness scenarios (paired race)

Four scenarios, each executed 1 000 iterations. Each iteration:

1. Two threads T_A and T_B are created for that iteration, targeting a
   fresh `(entity_id, attribute)` pair unique to the iteration.
2. Both threads open a fresh psycopg connection at the scenario's isolation
   level. Each thread prepares its INSERT statement inside a transaction.
3. A `threading.Barrier(2)` releases both threads simultaneously.
4. Both threads execute their INSERT.
5. Both threads COMMIT. Commit-order coin flip is deterministic from seed 42:
   iterations where `random.random() < 0.5` get a 2 ms head-start for T_A
   before COMMIT; the other half give T_B the head-start. **This ensures
   both commit orderings are tested; the barrier alone does not fix commit
   order but does not guarantee both orderings are exercised.**
6. After both threads complete, an invariant check runs on that iteration's
   `(entity_id, attribute)`. Any invariant violation stops the scenario and
   is recorded as a minimal reproducing case.

### Scenario S1: exclusion race

Both threads INSERT a MEASURED fact for the same `(entity_id, attribute)`
with overlapping `valid_time`. Invariant: exactly one live row survives;
the other is either rejected by the exclusion constraint or evicted to
`kndb_audit.evicted_fact`. **Two live rows for the same slot is a bug.**

### Scenario S2: lattice race

T_A INSERTs INFERRED (confidence 0.97). T_B INSERTs MEASURED (confidence
0.90). Same slot, overlapping `valid_time`. Vary commit order across the
1 000 iterations.

Invariant: the live row is the MEASURED fact regardless of commit order.
The INFERRED write is either rejected (never lands) or evicted to audit
with `reason = 'kind_outranked'`. **The lattice must not be order-dependent
under concurrency.**

### Scenario S3: R5 race

Slot `hba1c` is pre-registered as MEASURED. T_A INSERTs MEASURED into
`hba1c`. T_B INSERTs INFERRED into `hba1c`. Same entity, overlapping
`valid_time`. Invariant: T_B's write is always rejected by R5. T_A's
write is accepted at most once (S1 semantics apply if both are MEASURED
racing on the same slot). **A wrong-kind write landing in the DB is a
bug regardless of ordering.**

### Scenario S4: audit completeness under burst

For each iteration: N threads (N = 8) each attempt a write into the same
slot with overlapping `valid_time`. Values differ across threads. Isolation
levels tested: READ COMMITTED, SERIALIZABLE. Invariant: `|live rows for
slot| + |audit rows referring to this iteration's writes| = |accepted
COMMITs from the harness| for that iteration. **Accepted writes that are
neither live nor audited would mean the engine silently lost data under
contention.**

## Throughput sweep

Client counts: 1, 2, 4, 8, 16, 32.
Contention: low = 1 % of writes target a shared hotspot slot; high = 100 %
of writes target the shared hotspot slot.
Isolation: READ COMMITTED, SERIALIZABLE.
Retry mode:
- **`raw`** (no retry): every `serialization_failure` (SQLSTATE 40001) or
  `deadlock_detected` (40P01) is counted and the write is dropped. Reports
  the raw enforcement cost of contention.
- **`app`** (bounded backoff): each retryable error triggers a retry with
  exponential backoff (starting 5 ms, cap 200 ms, max 10 retries). Reports
  the application-observed cost.

Framing to keep the paper reading right: **SERIALIZABLE under `raw` looks
worse than READ COMMITTED under `raw` and that is expected and correct.**
The stronger guarantee has a real cost. `app` amortizes this cost by
retrying, which is what a production application actually does.

Per cell: each client issues 1 000 writes; the workload is deterministic
per seed. Metrics captured per cell:
- `writes_attempted`, `writes_committed`, `writes_dropped`
- `serialization_failures`, `deadlock_failures`
- `retries_total`, `retries_p50`, `retries_p95`, `retries_p99` (across writes)
- Latency percentiles p50/p95/p99 across the 1 000 x N committed writes
- Wall-clock throughput (rows/sec)

After every throughput cell finishes, a post-run invariant check runs on
the DB state. **A hotspot run whose post-run invariants fail is a
correctness bug and gets logged as such in RESULTS.md, same severity as a
paired-race scenario failure.** The hotspot regime is exactly where a
race would hide from the deterministic 2-thread test.

## Retry policy (bounded backoff)

```
attempt = 0
while attempt < 10:
    try:
        do_write()
        break
    except (SerializationFailure, DeadlockDetected):
        attempt += 1
        sleep(min(0.005 * 2**attempt, 0.200))
```

Retry counter is per-write. If a write exhausts 10 attempts it is counted
as `dropped` in `app` mode.

## Determinism knobs

- Random seed 42 for entity ID generation, contention decisions, commit-order
  coin flips.
- Scenario iteration count fixed at 1 000.
- Client count list fixed.
- Contention values fixed at 0.01 and 1.00.

Thread interleaving is inherently non-deterministic. The paired-race
framework only guarantees "both threads reach the barrier before either
COMMITs"; it explicitly does not attempt to fix commit ordering (the
2 ms head-start is a hint to the OS scheduler, not a guarantee, which is
the honest concurrency semantics we want to test).
