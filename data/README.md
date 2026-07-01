# KNDB — Data pipeline (Synthea → KNDB staging)

Milestone: **M5, data prep only.** The engine-side load into
epistemic-typed tables is M1's job; this directory ends at Postgres
`stage.*` tables.

---

## 1. What Synthea is, and why

[Synthea](https://github.com/synthetichealth/synthea) (SyntheticMass)
is an open-source synthetic patient generator maintained by The MITRE
Corporation. It runs a set of Markov modules over disease progression
to emit fully synthetic patient records, formatted as FHIR bundles or
flat CSVs. **No real PHI is ever involved** — the population is
generated from published prevalence statistics, so it's safe to
commit, ship, and screenshot.

Licence: **Apache 2.0** (matches KNDB's licence — see the top-level
`LICENSE`). We do not vendor the Synthea JAR into the repo; the
generator script downloads it at runtime by pinned version + SHA256.
That keeps the repo small and avoids re-distributing a 197 MB binary
under someone else's copyright header.

### Version pinned

- **Synthea `v4.0.0`** (released 2026-03-05).
- Asset: `synthea-with-dependencies.jar`
- SHA256: `ed43c20ad40ba5c3bc724503a5af032715fe3c491620b766148e7c2361e6ecc1`

We deliberately pin the last **tagged** release rather than the
rolling `master-branch-latest` tag (also updated 2026-06-30). Tagged
releases are the only ones we can reliably rebuild a paper artifact
against 6 months from now.

### Why 10,000 patients

- Small enough to generate in ~15 minutes on a laptop and fit under
  ~2 GB of CSV.
- Large enough that:
  - the demo's aggregate (avg BP over 90 days) has ≥30 patients per
    stratum for a plausible clinical-trial-eligibility filter,
  - the benchmark harness (M6) has enough rows to distinguish p50 /
    p95 / p99 on write latency,
  - Viterbi confidence propagation joins produce ≥10⁴-row result
    sets, exercising ProvSQL's per-row provenance UUID overhead.
- For CI we ship a 100-patient sample (see §5 below).

---

## 2. The epistemic-kind labels are **synthesized**

Synthea emits everything as FHIR `Observation` resources — labs,
vitals, procedures, diagnoses, all in one shape. It does **not**
distinguish observations from inferences from derived aggregates.

**This is fine and disclosable.** KNDB's paper claim is about
**engine enforcement** of the three-way kind, not about detecting the
kind post-hoc from raw EHR data. So we assign labels ourselves,
deterministically, from the Synthea CSVs.

The three labels, precisely:

### `observation`
Raw Synthea labs — HbA1c, systolic BP, diastolic BP, fasting glucose,
LDL cholesterol — as they appear in `observations.csv`. One CSV row
per lab draw. `confidence` is a constant **0.95** representing "we
trust the lab's measurement modulo per-instrument noise". This lives
in `data/synthea/kndb/observations.csv` after
`synthesize_labels.py`.

### `inference`
A **synthesized model prediction** of `is_diabetic`, per patient.
The rule is simple and disclosed in the code:

- take the patient's most-recent HbA1c reading,
- draw Gaussian noise `N(0, 0.35)` on the standard 6.5% threshold
  (seeded, so runs are reproducible),
- predict `is_diabetic = 1` if `HbA1c + noise ≥ 6.5`, else 0,
- assign a per-row `confidence` in `[0.5, 0.95]` derived from the
  distance to the noisy threshold (further from threshold = more
  confident).

Because the noise term can flip the prediction on the boundary, this
"model" will disagree with the observation-truth (`HbA1c ≥ 6.5`) on
some patients. That disagreement is exactly what makes the
downstream `observation | inference` mismatch queries interesting.

Each inference row records `source_lab_ids` — the observation-row
IDs it depended on. This is what M1's `derived`-kind trigger will
actually check: `derived.sources` must resolve, and inferences must
declare provenance too so Viterbi propagation can multiply their
confidences through joins.

### `derived`
Per-patient aggregates over a 90-day window ending at the patient's
latest observation date:

- `avg_systolic_bp_90d` — mean systolic BP.
- `avg_hba1c_90d` — mean HbA1c.

Each derived row has a `sources` column listing the observation IDs
that fed the aggregate. **KNDB's M1 trigger will reject any derived
insert with empty or dangling `sources`**, so getting these arrays
right at data-prep time matters.

---

## 3. Pipeline overview

```
generate.sh              synthesize_labels.py         load_postgres.sh
  ↓                         ↓                            ↓
Synthea JAR             data/synthea/kndb/*.csv       stage.observations
  ↓                       observations.csv            stage.inferences
data/synthea/output/      inferences.csv              stage.derived
  csv/*.csv               derived.csv                 (in kndb-postgres)
```

The staging tables are named `stage.*` so M1 can `SELECT ... FROM
stage.observations` and copy into the real epistemic-typed schema
under `kndb.*`. That two-step keeps the "engine enforces the
invariant" story clean: nothing in `stage.*` claims to be typed.

---

## 4. How to (re)generate

```bash
# 1. Full 10k-patient dataset (~15 min on M-series laptop, ~2 GB CSV)
./data/generate.sh

# 2. Synthesize KNDB obs/inference/derived labels (seed 42, deterministic)
python3 data/synthesize_labels.py

# 3. Load into staging tables in the running kndb-postgres container
./data/load_postgres.sh

# Force regeneration (skips the idempotency check)
./data/generate.sh --force
```

`generate.sh` is idempotent — if `data/synthea/output/csv/patients.csv`
already exists it will not re-run Synthea unless `--force` is
supplied. `synthesize_labels.py` and `load_postgres.sh` always
recompute / truncate before reload.

Prerequisites:
- Java 17+ (for Synthea).
- Python 3.11+ (only the standard library — no third-party deps).
- `curl`, `sha256sum` (or `shasum -a 256` on macOS).
- For `load_postgres.sh`: `docker compose up -d` has been run and
  the `kndb-postgres` container is healthy.

---

## 5. CI sample (`data/ci_sample/`)

The three KNDB CSVs from a **100-patient** Synthea run are checked
into `data/ci_sample/` so tests can run against a fixed, tiny
dataset without pulling Synthea in every CI job.

- Committed if the three files together stay under 5 MB (they
  should — 100 patients × ~5 labs/yr × ~10 yrs ≈ 5000 obs rows).
- Regeneratable with `POPULATION=100 OUTPUT_DIR=data/ci_sample_raw
  ./data/generate.sh --force && python3 data/synthesize_labels.py
  --input data/ci_sample_raw --output data/ci_sample`.

The CI harness (`.github/workflows/*`, M8) will point
`load_postgres.sh` at `data/ci_sample/` instead of
`data/synthea/kndb/` via the `KNDB_DATA_DIR` env var.

---

## 6. Judgement calls, documented

Chosen inline in `synthesize_labels.py` — repeating here so they're
easy to review:

- **Lab codes we care about** (LOINC): HbA1c `4548-4`, systolic BP
  `8480-6`, diastolic BP `8462-4`, fasting glucose `1558-6`, LDL
  `2571-8` (Synthea's LOINCs — verified against Synthea 4.0.0's
  `LabsMapper`).
- **HbA1c diabetes threshold**: 6.5 %, standard ADA cutoff.
- **Noise `sigma` on inference**: 0.35 percentage points. Chosen so
  ~5–10 % of borderline patients get a flipped prediction — enough
  disagreement for the demo to be interesting, not so much that the
  "model" looks broken.
- **Confidence formula**: `clip(0.5 + 0.9 · |HbA1c − 6.5| / 3.0,
  0.5, 0.95)`. Monotonic in distance-from-threshold, bounded per
  spec.
- **90-day window** anchors on the patient's *latest observation
  date* per patient, not calendar today. That way regenerating on a
  different day doesn't shift the derived aggregates.

---

## 7. Known TODOs for later milestones

- M1 will add real `kndb.observations` / `kndb.inferences` /
  `kndb.derived` tables with `epistemic_kind` DOMAIN + triggers, and
  a `COPY FROM stage.*` step.
- M2 will `SELECT add_provenance('kndb.observations')` etc. so the
  Viterbi semiring picks up per-row `confidence` values.
- M5 demo (`demo/demo.sh`) will select from the M1 tables, not from
  `stage.*` directly.
- CI job to auto-regenerate `data/ci_sample/` when
  `synthesize_labels.py` changes.
