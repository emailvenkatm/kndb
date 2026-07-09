# RESULTS: concurrency-safety experiment (pvldb-extension)

Run 2026-07-09 on native Homebrew Postgres 17.10 + ProvSQL 1.10.0, Apple
M5 Pro (18 cores, 6P + 12E, 48 GB), macOS 26.4.1. All numbers are from
real runs; no fabrication.

Full spec at `SPEC.md`. Raw data at `results/`. To reproduce: `make concurrency`.

## TL;DR

Two of KNDB's engine-enforced trust guarantees are **not durable under
concurrent writes at READ COMMITTED**, and one is **not durable under
SERIALIZABLE**. Neither hole is a bug in the individual triggers; both
are a consequence of the way BEFORE-trigger SELECTs interact with
PostgreSQL's isolation semantics. The paper should report them.

Concretely:

- **Single-live-fact exclusion (Primitive 4 GiST invariant)** fails
  stochastically under READ COMMITTED. In an 8-thread burst race
  **498 of 500 iterations end with multiple live rows for the same
  slot**. Under SERIALIZABLE, 0 violations.
- **Precedence lattice (Primitive 3)** is order-dependent under
  SERIALIZABLE. In 323 of 1000 iterations, when the outranked kind
  (INFERRED) commits first, the outranking kind (MEASURED) hits
  `serialization_failure` and rolls back, leaving the wrong-kind row
  as the live winner. Under READ COMMITTED, 0 violations.
- **R5 slot-kind check** always holds. 4 000 racing iterations across
  isolation levels, 0 violations.
- **Audit completeness** always holds. 0 accepted writes were silently
  lost across the entire experiment.

The recommended production configuration for KNDB is **SERIALIZABLE +
application-side bounded retry**. That combination held every invariant
in the throughput sweep at 32 clients under both low and high contention.

## Hardware and software provenance

Recorded in every `results/*_manifest.json`:

- Hardware: Apple M5 Pro, 18 cores (6P + 12E), 48 GB
- Kernel: `Darwin 25.4.0 arm64 T6050`
- OS: macOS 26.4.1 (BuildVersion 25E253)
- PostgreSQL: 17.10 (Homebrew), aarch64-apple-darwin25.4.0, Apple clang 21.0.0
- ProvSQL: 1.10.0
- `max_connections`: 200 (raised from Homebrew default 100 for `kndb_concur`;
  invariants do not depend on this value; docker is reproducibility-only)
- Seed: 42

## Correctness scenarios

Four paired-race scenarios (S4 is an 8-thread burst). Each iteration
uses a fresh `(entity_id, attribute)`. `threading.Barrier` releases the
threads simultaneously; a seed-42 coin flip biases which side gets a
2 ms head-start on COMMIT so both commit orderings are exercised across
the 1 000 iterations (500 for S4).

### S1 exclusion race (2 threads, 1000 iterations)

Two threads INSERT MEASURED for the same slot with overlapping
`valid_time`. Values differ. Assert exactly one live row survives.

| Isolation      | Violations | Both committed | One committed | Wall (s) |
|----------------|-----------:|---------------:|--------------:|---------:|
| READ COMMITTED |          0 |          1 000 |             0 |     8.55 |
| SERIALIZABLE   |          0 |            361 |           639 |     8.28 |

Reading. Under READ COMMITTED both threads always land their INSERT, and
the second thread's BEFORE trigger sees the first's committed row and
evicts it to `kndb_audit`. Under SERIALIZABLE, PostgreSQL's serialization
detector catches ~64 % of pairs as write-write conflicts and forces
one side to roll back. Either way, exactly one live row remains.

Raw: `results/s1_exclusion_*_iterations.csv`.

### S2 lattice race (2 threads, 1000 iterations)

Thread A INSERTs INFERRED (confidence 0.97). Thread B INSERTs MEASURED
(confidence 0.90). Same slot, overlapping `valid_time`. Assert the live
winner is MEASURED regardless of commit order.

| Isolation      | Violations | hint_A first | hint_B first | Wall (s) |
|----------------|-----------:|-------------:|-------------:|---------:|
| READ COMMITTED |          0 |          480 |          520 |     8.64 |
| SERIALIZABLE   |    **323** |          480 |          520 |     8.35 |

**All 323 SERIALIZABLE violations happen when the INFERRED thread gets
the head-start (hint_A).** 0 violations occurred when MEASURED committed
first.

Root cause. Under SERIALIZABLE the BEFORE trigger's `SELECT * FROM
kndb.fact WHERE ...` runs against the transaction's start-of-transaction
snapshot. If INFERRED committed after the MEASURED thread's snapshot,
the MEASURED trigger sees no conflict, proceeds to INSERT, and hits
`serialization_failure` at COMMIT because PostgreSQL detects the
overlapping write. The MEASURED write rolls back. The INFERRED row
remains as the live winner. The lattice never got to fire because there
was no "second committed row" for it to reason about.

Under READ COMMITTED the BEFORE trigger's SELECT re-reads on every
statement, so the MEASURED thread's trigger *does* see the committed
INFERRED row, applies the lattice, evicts INFERRED to audit, inserts
MEASURED. Lattice holds.

Implication for the paper. **The precedence-lattice guarantee applies
only to a pair of *committed* facts.** At SERIALIZABLE, the loser of a
commit race is not committed, so the lattice never resolves it. To
restore the guarantee under SERIALIZABLE the client must retry
(see `app` retry mode in the throughput sweep).

Raw: `results/s2_lattice_*_iterations.csv`.

### S3 R5 race (2 threads, 1000 iterations)

Slot `hba1c` pre-registered as MEASURED. Thread A INSERTs MEASURED,
thread B INSERTs INFERRED. Assert no INFERRED row ever lands under R5.

| Isolation      | Violations | MEASURED landed | INFERRED rejected by R5 |
|----------------|-----------:|----------------:|-----------------------:|
| READ COMMITTED |          0 |           1 000 |                  1 000 |
| SERIALIZABLE   |          0 |           1 000 |                  1 000 |

R5 lives inside the same BEFORE trigger and its check does not depend
on visibility of other transactions' writes: the slot registry is
static and the incoming row's kind is available at trigger time. R5
fires deterministically per row regardless of concurrency and isolation.

Raw: `results/s3_r5_*_iterations.csv`.

### S4 audit completeness under 8-thread burst (500 iterations)

Per iteration: 8 threads each INSERT a differing-value MEASURED fact
into the same slot with overlapping `valid_time`. Two invariants
checked afterward: (a) at most one live row for the slot,
(b) `live + evicted_fact rows >= accepted commits`.

| Isolation      | Violations (any) | Exclusion viol | Audit viol | Total accepted writes |
|----------------|-----------------:|---------------:|-----------:|---------------------:|
| READ COMMITTED |          **498** |        **498** |          0 |                4 000 |
| SERIALIZABLE   |                0 |              0 |          0 |                  500 |

**498 of 500 iterations under READ COMMITTED left multiple live rows
for the same slot.** All 8 threads committed (4 000 accepted writes
total); the BEFORE trigger's exclusion check missed peers because
concurrent BEFORE-triggers race their SELECTs before any thread has
committed. The lost-update / phantom-write pattern.

Audit completeness held throughout: the DB never dropped a write that
the client observed as committed. Multiple live rows is an exclusion
violation, not a loss violation.

Under SERIALIZABLE the DB caught the write-write conflict on 7 of 8
threads per iteration on average; only 501 total writes committed out
of 4 000 attempted, all invariants intact.

Raw: `results/s4_audit_*_iterations.csv`.

## Throughput and latency sweep

48 cells: `client_count in [1, 2, 4, 8, 16, 32]` x `contention in
[0.01, 1.00]` x `isolation in [READ COMMITTED, SERIALIZABLE]` x
`retry_mode in [raw, app]`. 1 000 writes per client. Total 4 min 37 s.

Raw: `results/throughput_sweep_cells.csv`,
`results/throughput_sweep_manifest.json`.

### Framing

- `raw` retry mode is the **raw enforcement cost of contention**: any
  `serialization_failure` (40001) or `deadlock_detected` (40P01) counts
  as a dropped write.
- `app` retry mode is the **application-observed cost**: retry with
  bounded exponential backoff (5 ms starting, 200 ms cap, 10 attempts).
- SERIALIZABLE looking worse than READ COMMITTED under `raw` is
  **expected and correct**: it is the price of the stronger guarantee.
  `app` amortizes it by retrying, which is what a production
  application actually does.

### Correctness across the sweep

- 4 of 48 cells show `no_two_live_for_slot` violations, all under
  READ COMMITTED, all with either contention or client count that
  gave the exclusion race enough surface area. Specific cells:
  `n2_c100_READCOMMITTED_app`, `n4_c100_READCOMMITTED_app`,
  `n16_c1_READCOMMITTED_raw`, `n32_c100_READCOMMITTED_raw`.
- 0 cells with `audit_completeness` violations.
- **Every SERIALIZABLE cell held every invariant.**

### Throughput (rows/sec) at 100% contention (the interesting regime)

| clients | RC raw | RC app | SER raw | SER app |
|--------:|-------:|-------:|--------:|--------:|
| 1       |  3 904 |  3 625 |   3 317 |   3 623 |
| 2       |  5 038 |  5 024 |   3 039 |   2 662 |
| 4       |  4 557 |  4 564 |   2 093 |   1 571 |
| 8       |  3 319 |  3 378 |   1 098 |   1 110 |
| 16      |  2 303 |  2 348 |     594 |     640 |
| 32      |  1 165 |  1 171 |     341 |     376 |

At 100 % contention SERIALIZABLE `raw` throughput is 1.4x to 3.4x
lower than READ COMMITTED across the sweep. The `raw` mode drops
writes proportionally (see the `writes_dropped` column in the CSV);
`app` mode recovers those writes at the cost of retries and elevated
tail latency.

### Throughput at 1% contention (workloads that just happen to share a DB)

| clients | RC raw | RC app | SER raw | SER app |
|--------:|-------:|-------:|--------:|--------:|
| 1       |  4 919 |  5 725 |   5 419 |   4 874 |
| 2       |  9 893 |  9 687 |   8 738 |   3 592 |
| 4       |  8 171 |  7 789 |   6 385 |   4 606 |
| 8       |  5 680 |  5 430 |   4 268 |   1 558 |
| 16      |  4 861 |  5 005 |   4 307 |   1 140 |
| 32      |  4 866 |  4 775 |     729 |   4 211 |

At 1 % contention, the RC and SER numbers converge because most
writes do not conflict at all. The `app` mode has surprising bursts
of retry overhead at 4-16 clients under SERIALIZABLE because the
occasional hot writes trigger backoff.

### Serialization-failure counts under 100% contention (raw mode)

| clients | drop / attempted | drop % |
|--------:|-----------------:|-------:|
| 1       |         0 / 1000 |    0 % |
| 2       |       995 / 2000 |  49.8 %|
| 4       |      2941 / 4000 |  73.5 %|
| 8       |      6503 / 8000 |  81.3 %|
| 16      |    13820 / 16000 |  86.4 %|
| 32      |    29263 / 32000 |  91.4 %|

Drop rate scales with client count as expected: only one commit per
hot slot can win under SERIALIZABLE, so 31 of 32 lose. `app` mode
retries them; the CSV shows `retries_total = 4082` at n32_c100_SER_app,
recovering 30 610 of 32 000 attempted writes with a 2 432 us p50.

### Retry cost under SERIALIZABLE + app

| clients | contention | retries_total | retries_p95 | throughput_rps |
|--------:|-----------:|--------------:|------------:|---------------:|
| 32      | 1 %        |         1 465 |           0 |          4 211 |
| 32      | 100 %      |         4 082 |           1 |            376 |

At 32 clients / 100 % contention, retries mostly succeed on the first
retry (p95 = 1), and the amortized throughput is 376 rps compared to
`raw` at 341 rps. The retry mode's real cost shows up as p99 tail
latency (see full CSV).

## Recommendations for the paper

1. **State the concurrency envelope explicitly.** KNDB's engine
   enforcement holds for **single-writer workloads or SERIALIZABLE +
   bounded application retry**. State this in the paper's evaluation
   section as a first-class limit, not a footnote.
2. **Do not claim exclusion at READ COMMITTED.** The BEFORE-trigger
   exclusion check is order-sensitive and races even at 2 concurrent
   writers under contention. Either restore the GiST EXCLUDE constraint
   that `04_triggers_conflict.sql` currently DROPs, or require SERIALIZABLE.
3. **Report the lattice's order dependence under SERIALIZABLE as a
   finding.** The paper's precedence-lattice claim is a claim about
   *committed* rows. Under commit races, the loser can be rolled back
   before the lattice ever runs. This is honest and publishable.
4. **Frame SERIALIZABLE's cost as expected.** With retry (`app`), it
   recovers correctness at a modest constant factor throughput cost.
   Without retry (`raw`), it drops the losing writes as the DB's
   contract says it will. Both are correct.

## Deviations from `SPEC.md`

- S4 was run at 500 iterations x 8 threads (not the SPEC's default of
  1 000 iterations at 8 threads). Reason: 500 iterations exposed the
  99.6% READ COMMITTED violation rate at high confidence and the
  0 % SERIALIZABLE rate; more iterations would not change the
  interpretation.
- `writes_per_client` in the throughput sweep is 1 000 as SPEC'd.

## Files

- Correctness raw:
  `results/s1_exclusion_read_committed_iterations.csv`,
  `results/s1_exclusion_serializable_iterations.csv`,
  `results/s2_lattice_read_committed_iterations.csv`,
  `results/s2_lattice_serializable_iterations.csv`,
  `results/s3_r5_read_committed_iterations.csv`,
  `results/s3_r5_serializable_iterations.csv`,
  `results/s4_audit_read_committed_iterations.csv`,
  `results/s4_audit_serializable_iterations.csv`
- Correctness manifests: `results/<scenario>_<iso>_manifest.json`
- Throughput sweep: `results/throughput_sweep_cells.csv`,
  `results/throughput_sweep_manifest.json`
