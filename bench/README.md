# KNDB Benchmark Harness (M6)

Honest measurements for the CIDR 2027 submission. **No fabricated numbers.**
Any missing measurement is reported as missing, not extrapolated.

## What this measures

Four systems are compared:

| Key                       | What it is                                                     |
|---------------------------|----------------------------------------------------------------|
| `kndb`                    | The engine we built. Postgres 17 + ProvSQL 1.10.0 + triggers. |
| `pg_naive`                | Plain Postgres. No CHECK, no triggers, no exclusion.           |
| `py_guards`               | Plain Postgres + a Python module in front of every write.      |
| `pg_handrolled_triggers`  | **Steelman.** Plain Postgres with a hand-rolled trigger suite mirroring KNDB primitives 1, 3, 4, 5. Does not attempt primitive 2 (Viterbi propagation). |

Metrics reported:

1. **Adversarial write catch rate** (`bench/adversarial/writes.py`) — 100
   payloads across five buckets of 20 (epistemic-kind, conflict,
   confidence, bitemporal, progressive-depth). Deterministic under seed 42.
   Each payload has a `should_be_rejected` flag; the runner tallies
   `caught_at_write_time`, `missed_silently`, `crashed`.
2. **Confidence-propagation correctness** (`bench/confidence_correctness.py`)
   — 100 chain patterns of length 2–4, closed-form Viterbi
   (product-of-confidences) as ground truth, per-baseline drift.
3. **Guard LOC** (`bench/loc.py`) — non-blank, non-comment lines of
   guard code (triggers, guard functions, Python guards). Excludes schema
   DDL, extension setup, and type declarations.
4. **Write throughput** (`bench/run.py`) — 10 000 legal-observation
   inserts per repetition, ≥10 seed repetitions, p50/p95/p99 per-row
   latency + aggregate throughput. Measured only on `kndb` and
   `pg_handrolled_triggers` — the two systems whose apples-to-apples
   comparison is what the paper cares about.

## How to run

Prereqs: the KNDB docker-compose stack must already be up and healthy.

```bash
make up            # from repo root — starts kndb-postgres on port 5433
make engine        # apply engine/*.sql (only needed if fresh volume)
```

Set up Python once:

```bash
python3 -m venv bench/.venv
bench/.venv/bin/pip install -r bench/requirements.txt
```

Run the full harness:

```bash
bench/.venv/bin/python3 bench/run.py                     # adversarial + throughput
bench/.venv/bin/python3 bench/confidence_correctness.py  # 100-chain confidence drift
bench/.venv/bin/python3 bench/loc.py                     # guard LOC table
bench/.venv/bin/python3 bench/plots.py                   # regenerate figures
```

Environment variables:

- `KNDB_DSN` — override the DSN. Default `postgresql://kndb:kndb@localhost:5433/kndb`.
- `KNDB_TP_ROWS` — throughput rows per rep. Default 10 000.
- `KNDB_TP_REPS` — throughput seed reps. Default 10.

## How to read results

CSVs land in `bench/results/`:

```
results/
  summary_totals.csv                  # one row per system: caught / missed / crashed
  summary_per_row.csv                 # every adversarial write's outcome
  loc.csv                             # LOC per system
  confidence_summary.csv              # drift per system
  confidence_per_pattern.csv          # per-chain closed-form vs. observed
  manifest.json                       # seed, DSN, run timestamp
  {system}/adversarial_totals.csv
  {system}/adversarial_per_row.csv
  {system}/throughput.csv             # kndb and pg_handrolled_triggers only
  figures/                            # publication PNG + PDF pairs
```

## Honest limitations

- **amd64 emulation on ARM64 hosts inflates absolute latencies by an
  estimated 1.5-3x** versus native amd64. The ProvSQL 1.10.0 image ships
  amd64 only; on Apple-silicon dev boxes (this one included) it runs
  under Docker Desktop / OrbStack emulation. **The paper should report
  RELATIVE overhead — KNDB vs. steelman — not absolute numbers.**
- **10 seed reps is the low end of statistical honesty.** For the paper's
  final numbers we recommend `KNDB_TP_REPS=30` on a native amd64 host and
  reporting per-rep-mean quantiles. The CSV keeps every rep so you can
  re-compute without re-running.
- **Confidence-correctness is scoped to inner-join chains.** ProvSQL's
  possible-worlds semantics on outer/mixed-kind joins (DECISIONS.md M0
  smoke A) is surfaced honestly in the demo but not in this correctness
  bench — the paper should present it as a separate qualitative claim.
- **`py_guards` is deliberately incomplete.** See its module docstring;
  the paper's point is that app-layer guards are loose by nature.
  Do not "fix" the gaps.
- **`pg_naive` catch = 0.** By construction — no CHECK, no triggers.
  This is the floor, not a bug in the harness.
- **The `crashed` bucket** counts non-KNDB errors AND over-rejection of
  legal writes (a compliant write refused by an over-eager trigger).
  All four systems report 0 for this bucket on the current run.

## Observed numbers on this host

Recorded 2026-07-01 on Apple-silicon under OrbStack amd64 emulation with
`KNDB_TP_ROWS=10000 KNDB_TP_REPS=10`. Reproducible on the same host by
re-running the commands above.

### Adversarial writes (n = 100)

| System                     | caught | missed | crashed |
|----------------------------|-------:|-------:|--------:|
| kndb                       |     70 |      0 |       0 |
| pg_naive                   |      0 |     70 |       0 |
| py_guards                  |     30 |     40 |       0 |
| pg_handrolled_triggers     |     70 |      0 |       0 |

Of the 100 payloads, 70 are `should_be_rejected=True` and 30 are legal
targets (the `confidence` bucket + 10 legal `progressive` rows). A
"perfect" system therefore lands 30 and rejects 70.

The `py_guards` 30/40 split is the deliberate incompleteness: the
guard layer catches epistemic-kind violations (20 rows) and R3-shaped
progressive-depth violations (10 rows) but by design does not check
for valid-time overlap on contradicting values (misses the 20 conflict
+ 20 bitemporal adversarials).

### Confidence-propagation drift (100 chain patterns, length 2-4)

| System                     | mean abs drift | max abs drift | exact matches |
|----------------------------|---------------:|--------------:|--------------:|
| kndb                       |       0.000000 |      0.000000 |       100/100 |
| pg_naive                   |       0.210291 |      0.426117 |         0/100 |
| py_guards                  |       0.210291 |      0.426117 |         0/100 |
| pg_handrolled_triggers     |       0.000000 |      0.000000 |       100/100 |

On this scope (inner-join chains, product-of-confidences ground truth)
the steelman baseline matches KNDB exactly because the SQL in both
systems is doing the same multiplication. The paper's claim on
primitive 2 shifts to _mechanism_ (ProvSQL vs. a bespoke SQL join every
app must write for itself, with correctness re-derived each time) rather
than _numerical difference_ — and to the outer/mixed-kind case that this
bench does not attempt to score.

The two naive baselines' 0.21 mean drift comes from the common ad-hoc
proxy `MIN(confidence)`, which is what app code typically writes when
there is no propagation primitive available.

### Guard LOC

| System                     | LOC |
|----------------------------|----:|
| kndb                       | 150 |
| pg_naive                   |   0 |
| py_guards                  |  41 |
| pg_handrolled_triggers     | 124 |

The steelman is only 26 LOC lighter than KNDB. That is honest — the
paper's argument is not "KNDB uses fewer lines", it is "those lines live
in one enforced place instead of being reproduced in every app". The
`py_guards` number (41) is misleading small: the guard file is small
only because it is deliberately incomplete.

### Write throughput (10 000 rows / rep, 10 seed reps, means over reps)

| System                     | p50 (us) | p95 (us) | p99 (us) | throughput (rows/s) |
|----------------------------|---------:|---------:|---------:|--------------------:|
| kndb                       |    990.4 |   2079.5 |   3092.4 |               853.2 |
| pg_handrolled_triggers     |    974.3 |   2359.9 |   3236.7 |               864.5 |

KNDB is within noise of the steelman on this host (both are limited by
amd64 emulation, single-threaded client, per-row autocommit). The paper
should report this as "engine-enforced primitives cost roughly the same
as hand-rolled triggers doing the same job", and cite RELATIVE overhead,
not the absolute microsecond numbers, which are inflated by emulation.
