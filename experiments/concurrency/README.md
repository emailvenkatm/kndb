# experiments/concurrency

Concurrency-safety experiment for the PVLDB extension of the KNDB paper.
Answers empirically: do KNDB's engine-enforced trust guarantees (R1-R5, the
precedence lattice, the single-live-fact GiST exclusion) hold under concurrent
multi-client writes, and what does throughput look like under contention?

## Quotable numbers vs reproducibility

**Native install is the paper-quotable target.** Docker is reproducibility-only.
The amd64 emulation on Apple Silicon adds variable per-syscall overhead that
confounds latency and, critically, corrupts the SERIALIZABLE retry-cost
measurement because retries amplify syscall traffic non-linearly.

Native setup used for this experiment:
- **Hardware:** Apple M5 Pro, 18 cores (6 performance + 12 efficiency), 48 GB
- **macOS:** 26.4.1 (BuildVersion 25E253)
- **Kernel:** Darwin 25.4.0 arm64 T6050
- **PostgreSQL:** 17.10 (Homebrew), aarch64-apple-darwin25.4.0, Apple clang 21.0.0
- **ProvSQL:** 1.10.0 built from `v1.10.0` source
- **Database:** `kndb_concur` (isolated from `kndb_native`, main-branch dev DB)
- **max_connections:** 200 (raised from Homebrew default 100 for this DB)
- **Seed:** 42

Every result CSV carries the full provenance dict in its manifest so a
reviewer can verify what produced each number.

## How to reproduce

```bash
git checkout pvldb-extension
cd experiments/concurrency
make -f Makefile bootstrap   # creates kndb_concur DB, applies engine, sets max_connections=200
make -f Makefile correctness # runs the four paired-race scenarios; writes to results/
make -f Makefile throughput  # runs the client-count x contention x isolation x retry sweep
make -f Makefile results     # regenerates RESULTS.md
```

Or from repo root: `make concurrency`.

## Design

Full spec in `SPEC.md`. Short version:

- **Correctness** = 4 scenarios, each 1 000 paired-race iterations, deterministic
  50 / 50 commit-order flip. Any invariant violation is a PVLDB-worthy negative
  finding and gets a minimal reproducing case in RESULTS.md.
- **Throughput sweep** = 6 client counts (1, 2, 4, 8, 16, 32) x 2 contention
  levels (1 % and 100 % hotspot) x 2 isolation levels (READ COMMITTED,
  SERIALIZABLE) x 2 retry modes (no-retry = raw enforcement cost;
  bounded-backoff = application-observed cost) = 48 cells.
- **Post-run invariant checks** on every throughput cell. A hotspot run that
  fails an invariant is treated with the same severity as a paired-race
  failure; that is exactly the regime where a race would hide.

## Files

- `SPEC.md` — full experiment spec.
- `bootstrap.sql` — creates `kndb_concur` DB, applies engine files, seeds slot registry.
- `harness/` — Python modules: `db.py` (connection factory + isolation ctx),
  `payloads.py` (fact generators), `paired.py` (2-thread race framework),
  `hotspot.py` (N-client workload), `invariants.py` (post-run SQL checks),
  `metrics.py` (percentile aggregation + retry counters).
- `scenarios/` — the four correctness scenarios plus the throughput driver.
- `results/` — CSV + JSON output. `manifest.json` at each run captures seed,
  hardware, versions, isolation level, contention, retry mode.
- `RESULTS.md` — summary written after each full run.
