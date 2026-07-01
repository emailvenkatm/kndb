# CI sample dataset

A 100-patient Synthea run, KNDB-labelled. Used by the test suite so
CI doesn't have to pull ~200 MB of Synthea JAR and generate 10k
patients on every push.

## Files (populated by regenerate step, not by hand)

- `observations.csv`
- `inferences.csv`
- `derived.csv`

Same schemas as the full-size CSVs under `data/synthea/kndb/`.

## How to (re)generate

```bash
# from repo root
POPULATION=100 \
OUTPUT_DIR="$(pwd)/data/ci_sample_raw" \
  ./data/generate.sh --force

python3 data/synthesize_labels.py \
  --input  data/ci_sample_raw \
  --output data/ci_sample

# tidy the raw Synthea CSVs — we only keep the three KNDB-shaped files
rm -rf data/ci_sample_raw
```

## Commit policy

- Commit the three CSVs **only if their combined size stays under
  5 MB**. 100 patients × ~5 labs/yr × ~10 yrs ≈ 5000 obs rows, so
  this should comfortably fit.
- If they blow past 5 MB, delete them and switch CI to regenerate on
  every job (adds ~1 min for the 100-patient run).

## How CI uses this

```bash
KNDB_DATA_DIR="$(pwd)/data/ci_sample" ./data/load_postgres.sh
```

`load_postgres.sh` reads `KNDB_DATA_DIR`; the default points at
`data/synthea/kndb/` (the 10k dataset). Overriding to
`data/ci_sample/` runs the same load path against the small
fixture. Nothing else in the harness needs to change.

## Determinism

`generate.sh` runs Synthea with `-s 42` (seed pinned in the script)
and `synthesize_labels.py` uses `--seed 42` (default), so the same
100-patient sample is byte-identical across regenerations on the
same Synthea version.
