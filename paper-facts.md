# paper-facts.md

Single reference of every number the paper is allowed to quote. All numbers
come from the actual artifacts in this repo. Paths to the raw CSV / JSON /
SQL are listed alongside each figure so any reviewer can verify.

Last regenerated 2026-07-04 against commit `a0a2aa7` (post P4A benchmark
run + T3.10-T3.12 specificity tests + CI green on hosted runner).

No em-dashes in this file.

---

## 1. BENCHMARK

### 1.1 Final results, native ARM64, no emulation

Hardware: MacBook Pro (Apple silicon T6050), Darwin 25.4.0.
Postgres 17.10 (Homebrew), ProvSQL 1.10.0 built from `v1.10.0` source.
Seed 42. Adversarial suite: 100 payloads, 70 rejection targets + 30 legal.

**v2 engine (current), empty DB, 10 000 rows x 10 seed reps:**

| System                   | caught / 70 | missed | crashed | p50 (us) | p95 (us) | p99 (us) | throughput (rps) |
|--------------------------|------------:|-------:|--------:|---------:|---------:|---------:|-----------------:|
| kndb                     | 70          | 0      | 0       | 84.9     | 183.4    | 243.6    | 9 958.0          |
| pg_naive                 | 0           | 70     | 0       | n/a      | n/a      | n/a      | n/a              |
| py_guards                | 30          | 40     | 0       | n/a      | n/a      | n/a      | n/a              |
| pg_handrolled_triggers   | 70          | 0      | 0       | 69.8     | 163.2    | 221.7    | 12 036.2         |

Source: `bench/results/native_v2/manifest.json`, `bench/results/native_v2/summary_totals.csv`,
`bench/results/native_v2/kndb/throughput.csv`, `bench/results/native_v2/pg_handrolled_triggers/throughput.csv`.

**v2 engine, Synthea-preloaded (615 658 rows in kndb.fact before the run), 5 000 rows x 10 seed reps:**

| System                   | caught / 70 | missed | crashed | p50 (us) | p95 (us) | p99 (us) | throughput (rps) |
|--------------------------|------------:|-------:|--------:|---------:|---------:|---------:|-----------------:|
| kndb                     | 70          | 0      | 0       | 113.3    | 227.1    | 383.9    | 7 574.3          |
| pg_naive                 | 0           | 70     | 0       | n/a      | n/a      | n/a      | n/a              |
| py_guards                | 30          | 40     | 0       | n/a      | n/a      | n/a      | n/a              |
| pg_handrolled_triggers   | 70          | 0      | 0       | 70.2     | 171.9    | 246.7    | 11 667.7         |

Source: `bench/results/native_synthea_v2/manifest.json`, `bench/results/native_synthea_v2/kndb/throughput.csv`,
`bench/results/native_synthea_v2/pg_handrolled_triggers/throughput.csv`.

### 1.2 Precedence-trigger overhead: old (confidence-wins) vs new (lattice)

Same hardware, seed, native install. v1 numbers taken from
`bench/results/native/` and `bench/results/native_synthea/`.

| Config              | System                 | v1 rps | v2 rps  | Delta   |
|---------------------|------------------------|-------:|--------:|--------:|
| Empty DB            | kndb                   | 13 150 |  9 958  | -24.3 % |
| Empty DB            | pg_handrolled_triggers | 14 912 | 12 036  | -19.3 % |
| Synthea 565 k       | kndb                   |  5 598 |  7 574  | +35.3 % |
| Synthea 565 k       | pg_handrolled_triggers | 15 560 | 11 668  | -25.0 % |

Reading. On empty DB, both engines dropped by comparable proportions
(-24.3 % kndb vs -19.3 % steelman). The steelman had no code change, so
part of that spread is background noise on the runner; the residual is
the honest cost of the new precedence-lattice branches on kndb.
At 565 k Synthea rows the moves are opposite-direction (kndb +35 %,
steelman -25 %) which cannot be a lattice signal. Per-insert cost at
that DB size is ProvSQL-bound, not lattice-bound. `bench/README.md`
documents this without dressing it up.

Adversarial catch rate did not change between v1 and v2.

Correctness (100 inner-join chains, product-of-confidences ground truth):

| System                 | mean drift | max drift | exact matches |
|------------------------|-----------:|----------:|--------------:|
| kndb                   | 0.000000   | 0.000000  | 100 / 100     |
| pg_handrolled_triggers | 0.000000   | 0.000000  | 100 / 100     |
| pg_naive               | 0.210291   | 0.426117  |   0 / 100     |
| py_guards              | 0.210291   | 0.426117  |   0 / 100     |

Source: `bench/results/confidence_summary.csv`.

---

## 2. CONFIDENCE COST (the "loss with DB size" finding)

The paper's "confidence propagation is not free" claim comes from these
per-configuration throughput numbers:

**v1 (M6 benchmark, empty vs 565 k Synthea):**

| System                 | empty rps | Synthea rps | delta from empty |
|------------------------|----------:|------------:|-----------------:|
| kndb (Viterbi enabled) |    13 150 |       5 598 |          -57.4 % |
| pg_handrolled          |    14 912 |      15 560 |           +4.3 % |

Interpretation. KNDB's per-write cost scales with `log(|kndb.fact|)` because
the AFTER-INSERT trigger `kndb.sync_provsql_prob` calls
`provsql.set_prob(token, confidence)` on every row and ProvSQL's
token to probability map grows with the table. The steelman does not
implement Viterbi propagation and therefore does not call `set_prob`,
so its per-write cost is size invariant.

The v1 finding was quoted throughout the summer as "roughly a 58 percent
throughput loss at 565 k rows".

**v2 (P4A benchmark, empty vs 615 658 Synthea):**

| System                 | empty rps | Synthea rps | delta from empty |
|------------------------|----------:|------------:|-----------------:|
| kndb (Viterbi enabled) |     9 958 |       7 574 |          -23.9 % |
| pg_handrolled          |    12 036 |      11 668 |           -3.1 % |

The v2 empty-DB kndb number dropped from v1 by 24 percent for reasons
covered in section 1.2. The delta between empty and Synthea inside v2
is -23.9 percent for kndb and roughly flat for the steelman, matching
the v1 shape at a smaller magnitude. `bench/README.md` and DECISIONS.md
(2026-07-04 entry) say the safest paper claim is qualitative: "size
dependence exists in kndb because ProvSQL bookkeeping grows with the
table; the steelman is size invariant because it does not do Viterbi".

Sources: `bench/results/native/manifest.json`, `bench/results/native_synthea/manifest.json`,
`bench/results/native_v2/manifest.json`, `bench/results/native_synthea_v2/manifest.json`,
and their `kndb/throughput.csv` files.

What scales with what:

- **kndb write cost:** `O(1) + O(log |kndb.fact|)` per row. Two BEFORE
  triggers (kind check, precedence lattice) plus one AFTER trigger
  (`set_prob` into ProvSQL's map, which is the log term).
- **pg_handrolled write cost:** `O(1)` per row. Same shape triggers minus
  the ProvSQL call.
- **pg_naive write cost:** `O(1)` per row. No trigger overhead. No trust
  enforcement of any kind either.

---

## 3. SCHEMA

### 3.1 `kndb.fact` (source: `engine/02_facts_schema.sql`)

```sql
CREATE TABLE kndb.fact (
  fact_id         uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id       int                 NOT NULL,
  attribute       text                NOT NULL,
  value           text                NOT NULL,
  epistemic_kind  kndb.epistemic_kind NOT NULL,
  confidence      kndb.confidence     NOT NULL,
  sources         uuid[]              NOT NULL DEFAULT '{}',
  specificity     smallint            NOT NULL DEFAULT 100
                                      CHECK (specificity BETWEEN 0 AND 255),
  valid_time      tstzrange           NOT NULL,
  sys_time        tstzrange           NOT NULL DEFAULT
                                        tstzrange(clock_timestamp(), 'infinity', '[)'),
  writer          text                NOT NULL DEFAULT current_user,
  EXCLUDE USING gist (
    entity_id  WITH =,
    attribute  WITH =,
    valid_time WITH &&
  ) WHERE (upper(sys_time) = 'infinity')
);
```

`specificity` convention. 0 = batch or general default (nightly loader,
imputation job). 100 = normal per-entity write. Above 100 = adjudicated
correction or human override.

### 3.2 Epistemic ENUM (source: `engine/01_types.sql`)

```sql
CREATE TYPE kndb.epistemic_kind AS ENUM (
  'MEASURED',   -- directly measured (lab result, sensor, user-declared)
  'INFERRED',   -- output of a model or rule
  'DERIVED'     -- deterministic aggregate of other facts (sources REQUIRED)
);

CREATE DOMAIN kndb.confidence AS numeric(6,5) CHECK (VALUE >= 0.0 AND VALUE <= 1.0);
```

### 3.3 `kndb_audit.evicted_fact` (source: `engine/02_facts_schema.sql`)

```sql
CREATE TABLE kndb_audit.evicted_fact (
  audit_id       bigserial   PRIMARY KEY,
  audit_time     timestamptz NOT NULL DEFAULT now(),
  reason         text        NOT NULL,
  winner_fact_id uuid,
  original_row   jsonb       NOT NULL
);
```

`reason` values written by the v2 precedence lattice:

- `kind_outranked`
- `specificity`
- `confidence`
- `contradicted_same_rank`

### 3.4 Write-time rules R1 through R5 (source: `engine/03_triggers_epistemic.sql`)

Enforced by BEFORE INSERT or UPDATE trigger `kndb.enforce_epistemic_kind()`.

| Rule | Meaning                                                                                     |
|------|---------------------------------------------------------------------------------------------|
| R1   | `DERIVED` fact must reference at least one source fact_id in `sources[]`.                    |
| R2   | Every source in `sources[]` must resolve to an existing fact row (referential integrity).    |
| R3   | `MEASURED` fact must not have upstream sources (empty `sources[]`).                          |
| R4   | `INFERRED` fact must have confidence strictly less than 1.0.                                 |
| R5   | If `kndb.slot_kind` registers an attribute as required-kind K, the row's `epistemic_kind` must equal K. |

---

## 4. FUNCTIONS

Exact signatures. Semicolons and comment lines omitted for width.

```sql
kndb.expand(
  p_entity_id  int,
  p_depth      int,
  p_min_conf   numeric DEFAULT 0.0
) RETURNS SETOF kndb.fact
```
Source: `engine/07_progressive_depth.sql:10`.

```sql
kndb.as_of_valid(
  p_entity_id  int,
  p_attribute  text,
  p_valid_at   timestamptz
) RETURNS SETOF kndb.fact
```
Source: `engine/05_bitemporal.sql:16`.

```sql
kndb.as_of_believed(
  p_entity_id  int,
  p_attribute  text,
  p_valid_at   timestamptz,
  p_sys_at     timestamptz
) RETURNS SETOF kndb.fact
```
Source: `engine/05_bitemporal.sql:30`.

Supporting engine functions:

```sql
kndb.enforce_epistemic_kind()  RETURNS trigger   -- 03_triggers_epistemic.sql
kndb.resolve_conflict()        RETURNS trigger   -- 04_triggers_conflict.sql
kndb.kind_rank(k kndb.epistemic_kind) RETURNS smallint  -- helper for the lattice
kndb.sync_provsql_prob()       RETURNS trigger   -- 06_provsql_setup.sql, syncs set_prob
kndb.refresh_weights()         RETURNS void      -- 06_provsql_setup.sql
```

Use-permission views (source: `engine/08_use_permissions.sql`):

```sql
kndb.fact_compliance      -- MEASURED + DERIVED, live rows only (excludes INFERRED)
kndb.fact_analytics       -- all kinds, live rows only
kndb.fact_training_safe   -- MEASURED only, live rows only
```

All three restricted to `upper(sys_time) = 'infinity'`.

---

## 5. DEPTH NUMBERS

### 5.1 Synthetic (source: `tests/progressive_depth.sql`, T5.1)

One synthetic patient (entity 30) with three MEASURED labs, two INFERRED
predictions, one DERIVED aggregate.

| Depth | Meaning                       | Rows | Avg confidence     |
|-------|-------------------------------|-----:|-------------------:|
| 0     | MEASURED only                 | 3    | 0.95               |
| 1     | + INFERRED                    | 5    | 0.834              |
| 2     | + DERIVED                     | 6    | 0.82833...         |

Both invariants hold. Recall goes up. Average confidence goes down.

### 5.2 Real Synthea (source: `demo/expected_clinical_output.txt`, run 2026-07-01)

11 637 patients loaded from Synthea v4.0.0 (SHA256 verified).

| Depth | Kinds included                    | Live row count |
|-------|-----------------------------------|---------------:|
| 0     | MEASURED                          | 544 349        |
| 1     | MEASURED + INFERRED               | 549 348        |
| 2     | MEASURED + INFERRED + DERIVED     | 565 587        |

By kind:
- MEASURED (real Synthea labs on 5 LOINC codes: HbA1c, systolic BP,
  diastolic BP, LDL, fasting glucose): 544 349
- INFERRED (synthesized `is_diabetic` predictions, mean confidence 0.7047,
  min 0.5001): 4 999
- DERIVED (90-day per-patient averages, sources reference obs fact_ids):
  16 239

---

## 6. SMOKE

The reviewer artifact reproducibility gate is 11 stages total, made up of
`make verify-extensions` (2 M0 empirical checks) plus `make smoke` (9
end-to-end steps against the running engine). Runs in under 30 seconds
warm on the local docker stack; 2 seconds observed for the 9-step
end-to-end alone.

**make verify-extensions (M0 ProvSQL semantics):**

1. Smoke A: ProvSQL Viterbi over LEFT JOIN with monus. (`tests/smoke_a_viterbi_leftjoin.sql`.)
2. Smoke B: `tstzrange` GiST EXCLUDE constraint plays cleanly with ProvSQL's hidden `provsql` column. (`tests/smoke_b_gist_provsql.sql`.)

**make smoke (end-to-end self-validation, `smoke.sh`):**

3. MEASURED write accepted.
4. R5 rejects INFERRED into a MEASURED-typed slot.
5. Precedence: high-confidence INFERRED cannot displace lower-confidence MEASURED.
6. Same-value overlap is absorbed; `valid_time` widens.
7. Viterbi join: `sr_viterbi(provenance(), 'kndb.fact_weights')` returns 0.6650 for 0.95 * 0.70 within 0.001.
8. Bitemporal `as_of_valid(2021-06-15)` returns the correct historical value.
9. Progressive depth: `expand(0/1/2)` recall monotone up, avg confidence monotone down.
10. Use-permission views: INFERRED absent from `fact_compliance` and `fact_training_safe`, present in `fact_analytics`.
11. Conflict + audit: eviction records `reason = 'kind_outranked'` on lattice-driven displacement.

Runtime: 2 seconds warm (measured local, docker compose), 1 minute 5 seconds cold on a hosted Ubuntu runner (full CI including image pull and bootstrap). Cold-start reproducibility check from a fresh git clone into `/tmp/kndb-repro`: 9.6 seconds wall clock for `make up && make engine && make smoke`.

Source: `smoke.sh`, `.github/workflows/ci.yml`, `Makefile:smoke` target.

---

## 7. TESTS

30 assertion checks. 29 PASS notice lines (T-A1 and T-A2 share one
NOTICE). 0 fail. 0 error. Across 8 test files.

| Primitive                | File                                         | Sub-tests | IDs                              |
|--------------------------|----------------------------------------------|----------:|----------------------------------|
| 1 Epistemic typing       | `tests/engine_enforces_epistemic_type.sql`   | 5         | T1.2, T1.3, T1.4, T1.5, T1.6     |
| 2 Confidence propagation | `tests/confidence_propagation.sql`           | 1         | T2.1                             |
| 3 Conflict / lattice     | `tests/engine_enforces_conflict.sql`         | 12        | T3.1 through T3.12               |
| 4 Bitemporal             | `tests/bitemporal_asof.sql`                  | 2         | T4.1, T4.2                       |
| 5 Progressive depth      | `tests/progressive_depth.sql`                | 1         | T5.1                             |
| 6 Use permissions        | `tests/use_permissions.sql`                  | 3         | T6.1, T6.2, T6.3                 |
| M0 ProvSQL semantics     | `tests/smoke_a_viterbi_leftjoin.sql`         | 2         | T-A1, T-A2 (bundled in 1 NOTICE) |
| M0 GiST + ProvSQL        | `tests/smoke_b_gist_provsql.sql`             | 4         | T-B1, T-B2, T-B3, T-B4           |
| **Total**                |                                              | **30**    |                                  |

T3 breakdown (v2 lattice coverage):

- T3.1 same-value absorption
- T3.2 differing-value overlap on tied lattice invalidates prior
- T3.3 conflict_policy = 'reject' short-circuit
- T3.4 kind rank refuses high-conf INFERRED against lower-conf MEASURED
- T3.5 arrival order irrelevant: MEASURED evicts prior INFERRED
- T3.6 audit reason `kind_outranked` on T3.5 eviction
- T3.7 specificity breaks kind tie on DERIVED (arbitrary values 50 vs 150)
- T3.8 confidence breaks kind + specificity tie
- T3.9 true tie: NEW lands by arrival, reason `contradicted_same_rank`
- T3.10 entity-specific (100) beats batch-default (0) same kind INFERRED
- T3.11 arrival order irrelevant on the specificity axis (batch 0 rejected)
- T3.12 adjudicated override (200) beats entity-specific (100) same kind MEASURED

Verify locally:

```bash
docker compose exec -T kndb-postgres psql -U kndb -d kndb \
  -c "DROP SCHEMA IF EXISTS kndb CASCADE; DROP SCHEMA IF EXISTS kndb_audit CASCADE;"
make engine
make test
```

---

## 8. STACK

### 8.1 Runtime dependencies

| Component  | Version                                       | Role                                                  |
|------------|-----------------------------------------------|-------------------------------------------------------|
| PostgreSQL | 17.10                                         | Substrate. Docker image and Homebrew native both used.|
| ProvSQL    | 1.10.0                                        | Semiring provenance, Viterbi propagation.             |
| btree_gist | ships with Postgres                           | GiST EXCLUDE on `(int, tstzrange)`.                   |
| uuid-ossp  | ships with Postgres                           | UUID generation.                                      |
| Docker     | 29.4+                                         | Reproducible dev stack, image pinned by SHA256.       |
| Python     | 3.11+                                         | Benchmark harness and demo scaffolding only.          |

Docker image pin (source: `docker-compose.yml`):

```
inriavalda/provsql:1.10.0@sha256:902023e556a49583eb650665183f3ff48c6623284d601c40788cb8401e682e06
```

### 8.2 LOC by component

Total engine SQL and PL/pgSQL: **508 lines** across 9 files.

| Path                                             | LOC | Role                                                             |
|--------------------------------------------------|----:|------------------------------------------------------------------|
| engine/00_extensions.sql                         |  12 | provsql, btree_gist, uuid-ossp                                   |
| engine/01_types.sql                              |  17 | `epistemic_kind` ENUM, `confidence` DOMAIN                       |
| engine/02_facts_schema.sql                       |  62 | `kndb.fact`, `kndb_audit.evicted_fact`, GiST EXCLUDE, indexes    |
| engine/03_triggers_epistemic.sql                 |  80 | R1 through R5, `kndb.slot_kind`, `enforce_epistemic_kind()`      |
| engine/04_triggers_conflict.sql                  | 169 | `kind_rank`, precedence lattice, `resolve_conflict()`, audit     |
| engine/05_bitemporal.sql                         |  46 | `as_of_valid`, `as_of_believed`                                  |
| engine/06_provsql_setup.sql                      |  50 | `add_provenance` bind, `sync_provsql_prob`, `refresh_weights`    |
| engine/07_progressive_depth.sql                  |  29 | `expand(entity, depth)`                                          |
| engine/08_use_permissions.sql                    |  27 | `fact_compliance`, `fact_analytics`, `fact_training_safe`        |
| engine/bootstrap.sql                             |  16 | Idempotent role and DB creation for the docker image             |

Tests (all `.sql`) total: **842 lines** across 8 files.
Baselines total: **392 lines** (`baselines/*/schema.sql` and `baselines/py_guards/guards.py`).
Bench harness Python total: **1 129 lines** (`bench/*.py`).
`smoke.sh`: 305 lines including the `KNDB_PSQL_DIRECT` switch and comments.

### 8.3 Guard LOC comparison (paper's steelman claim)

Source: `bench/results/loc.csv`. Note this file was written before
`engine/08_use_permissions.sql` was added; the kndb figure below is v1
scope (5 files, everything except use-permission views).

| System                   | Guard LOC | Files                                                                          |
|--------------------------|----------:|--------------------------------------------------------------------------------|
| kndb                     | 187       | engine/03 (39) + 04 (88) + 05 (27) + 06 (16) + 07 (17)                         |
| pg_naive                 | 0         | none                                                                           |
| py_guards                | 41        | baselines/py_guards/guards.py                                                  |
| pg_handrolled_triggers   | 124       | baselines/pg_handrolled_triggers/schema.sql                                    |

Including `engine/08_use_permissions.sql` (27 lines) and the v2 lattice
delta already captured inside `04` (88 lines), the current kndb guard
total is **214 lines**. The paper's LOC comparison should quote 214
against the steelman's 124 or note both.

---

## Appendix: what is NOT in this file, on purpose

- Absolute latency numbers on OrbStack amd64 emulation are excluded.
  Everything here is native ARM64.
- Concurrent-write race behavior is not measured; scoped as future work.
- The autonomous-transaction audit path for rejected writes is scoped out
  (documented limitation).

For live status of what is quotable versus in progress see `STATUS.md`
at the repo root.
