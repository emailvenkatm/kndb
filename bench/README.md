# KNDB benchmark harness

Honest measurements of what engine-enforced trust primitives cost, and what
happens without them. Every number here is regenerable from a fresh `make up`
via `python3 bench/run.py` — no fabricated results.

## What is measured

Four systems, one adversarial workload, three lenses.

### Systems

| System | Semantics | Guard code (LOC) |
|---|---|---|
| `kndb` | five engine-enforced primitives (obs/inf/derived typing, Viterbi propagation, write-time conflict, bitemporal, progressive depth) | 150 (`engine/03-07_*.sql`) |
| `pg_naive` | plain Postgres, no enforcement | 0 |
| `py_guards` | plain Postgres + Python-side validation before every write | 41 (`baselines/py_guards/guards.py`) |
| `pg_handrolled_triggers` | plain Postgres + hand-rolled PL/pgSQL triggers reimplementing KNDB's guarantees (the steelman) | 124 (`baselines/pg_handrolled_triggers/schema.sql`) |

### Workload

`bench/adversarial/writes.py` generates 100 payloads across five 20-payload buckets, seed 42:

- epistemic-kind violations (inference into obs slot, derived with no sources, observation with sources, inference at conf=1.0, slot-kind mismatch)
- conflict violations (contradicting facts, overlapping valid_time)
- confidence-propagation targets (join patterns whose naive product diverges from closed-form Viterbi)
- bitemporal violations (overlapping valid_time on same entity+attribute)
- progressive-depth targets

Each payload carries `should_be_rejected: bool`. A compliant system rejects every payload flagged `True` at write time. Non-adversarial (legitimate) writes are folded in as the complement of "adversarial" so all four systems land at the same total row count.

### Lenses

1. **Correctness — violations caught vs missed** (`bench/run.py`, table `summary_totals.csv`).
2. **Confidence-propagation drift** — engine output vs closed-form on 100 join patterns (`bench/confidence_correctness.py`, table `confidence_summary.csv`).
3. **LOC to match the guarantee** — non-blank, non-comment lines of each guard layer (`bench/loc.py`, table `loc.csv`).
4. **Write throughput** — p50 / p95 / p99 latency and rows/sec on a 500-row valid-write workload, per seed (`bench/run.py`, per-system `throughput.csv`).

## Observed numbers (2026-07-01, first run)

| System | caught | missed_silently | crashed | LOC | mean confidence drift | exact matches |
|---|---:|---:|---:|---:|---:|---:|
| kndb | 70 | 0 | 0 | 150 | 1.7e-17 (fp noise) | 100/100 |
| pg_naive | 0 | 70 | 0 | 0 | 0.21 | 0/100 |
| py_guards | 30 | 40 | 0 | 41 | 0.21 | 0/100 |
| pg_handrolled_triggers | 70 | 0 | 0 | 124 | 1.7e-17 (fp noise) | 100/100 |

Throughput (mean over 2 reps of 500 rows on amd64-emulated OrbStack on Apple Silicon; **relative**, not absolute):

| System | p50 (μs) | p95 (μs) | p99 (μs) | rows/sec |
|---|---:|---:|---:|---:|
| kndb | 1462 | 2865 | 4675 | 587 |
| pg_handrolled_triggers | 795 | 1517 | 3653 | 985 |

## What the numbers say (honest reading)

- **The engine catches what apps miss.** `pg_naive` accepts every attack. `py_guards` catches 30/70 because the Python layer can enforce type-tag checks but cannot atomically enforce write-time conflict resolution or bitemporal no-overlap. This is the "app-layer is not tight" evidence.
- **Confidence propagation cannot be reconstructed in the app.** `pg_naive` and `py_guards` both report `MIN(confidence)` as a naive proxy — the industry-standard ad-hoc heuristic — and drift 0.21 on average from closed-form Viterbi. Zero exact matches. This is the paper's headline: reconstructing "confidence" in the app silently produces different numbers depending on which team wrote it.
- **The steelman ties on correctness.** `pg_handrolled_triggers` catches 70/70 and drifts by floating-point noise only. This is *expected and honest*: you can hand-roll KNDB's guarantees on top of ProvSQL in 124 LOC of PL/pgSQL. The paper's story is not "no one else can do this" — it is "here is what those primitives look like as a coherent, tested package once, so you don't reimplement them per project."
- **KNDB pays ~40% latency vs. steelman.** 1462μs p50 vs 795μs. The overhead comes from the sync-provsql-prob AFTER trigger plus the more-general slot_kind registry lookup. The p99 gap is smaller. This is honestly reported; the paper will not claim KNDB is the fastest.
- **Absolute latency numbers are amd64-emulated.** These numbers are on OrbStack running the ProvSQL amd64 image under emulation on ARM64. Native amd64 will be faster; the ratio between KNDB and the steelman should hold. See `DECISIONS.md` (2026-07-01).

## How to run

Assumes `make up` has brought the container up and `make engine` has applied engine SQL.

```bash
python3 bench/run.py                       # correctness + throughput
python3 bench/confidence_correctness.py    # drift vs closed-form Viterbi
python3 bench/loc.py                       # guard-code LOC per baseline
python3 bench/plots.py                     # PDFs + PNGs into results/figures/
```

Results:
- `bench/results/manifest.json` — seed, DSN, run timestamp, list of systems.
- `bench/results/summary_totals.csv` — one row per system.
- `bench/results/summary_per_row.csv` — one row per adversarial payload per system.
- `bench/results/confidence_summary.csv` / `confidence_per_pattern.csv`.
- `bench/results/loc.csv`.
- `bench/results/<system>/adversarial_totals.csv`, `adversarial_per_row.csv`, `throughput.csv` (KNDB + steelman only for throughput).
- `bench/results/figures/*.pdf` — paper-ready figures.

## Reproducibility

- Seed 42 hard-coded in `bench/adversarial/writes.py`.
- Docker image pinned by SHA256 in `docker-compose.yml`.
- Postgres 17.10, ProvSQL 1.10.0.
- Python 3.11+; deps in `bench/requirements.txt`.
- `bench/results/manifest.json` records seed, DSN, and run timestamp per invocation.

## Known limitations

- **Only 2 throughput reps** at first run — the ≥10-reps target from `plan.md` is set as the `--reps` flag in `run.py`; the numbers above will be re-measured with 10 reps before the paper's final revision.
- **amd64 emulation on ARM64 hosts** inflates absolute latency. Paper tables will note whether numbers are native or emulated; the relative ratio is what matters.
- **The steelman baseline uses ProvSQL** as the semiring engine and computes Viterbi via multiplied per-row confidence on inner joins. This is legitimate — it means "assume ProvSQL exists, hand-roll the rest." The paper is careful to state this so the LOC comparison is honest.
- **Autonomous-transaction audit persistence** is out of scope for the reject policy; conflict-invalidate audit works as expected.
