#!/usr/bin/env bash
# G2.3 — Adversarial + throughput on Synthea-preloaded kndb.fact (565k rows),
# so the paper's benchmark and demo agree on dataset.
#
# Assumes:
#   - Native ProvSQL install healthy at postgresql://kndb_native:kndb_native@localhost:5434/kndb_native
#   - Synthea CSVs at data/synthea/kndb/*.csv (from data/generate.sh + synthesize_labels.py)
#   - bench/.venv exists
# What happens:
#   1. RELOAD Synthea via demo/clinical/01_setup.sql — brings kndb.fact to 565k rows.
#   2. Run bench/run.py with KNDB_PRESERVE_FACTS=1 so the truncate is skipped
#      for the KNDB system (baselines still reset — they don't hold Synthea).
#   3. Results land in bench/results/native_synthea/ so paper can compare
#      native/empty vs native/synthea-loaded numbers side by side.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${REPO}/bench/results/native_synthea"
mkdir -p "$RESULTS_DIR"

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql -h localhost -p 5434 -U kndb_native -d kndb_native -X -v ON_ERROR_STOP=1"

log() { printf "[run_synthea] %s\n" "$*"; }

# --- pre-flight -------------------------------------------------------------

if ! $PSQL -c "SELECT 1" >/dev/null 2>&1; then
  log "cannot reach native Postgres at localhost:5434"
  exit 1
fi

# --- 1) reload Synthea into kndb.fact ---------------------------------------

log "== reloading Synthea into kndb.fact (real 565k rows) =="
# stage.* was populated by the previous run_native.sh execution; if that data
# is gone, reload from CSVs to be safe.
if [[ "$($PSQL -tAc 'SELECT count(*) FROM stage.observations' 2>/dev/null | tr -d ' ')" != "544349" ]]; then
  log "stage.observations is stale — reloading from CSV"
  $PSQL <<'SQL'
TRUNCATE stage.observations, stage.inferences, stage.derived;
SQL
  $PSQL -c "\copy stage.observations FROM '${REPO}/data/synthea/kndb/observations.csv' WITH (FORMAT csv, HEADER true)"
  $PSQL -c "\copy stage.inferences   FROM '${REPO}/data/synthea/kndb/inferences.csv'   WITH (FORMAT csv, HEADER true)"
  $PSQL -c "\copy stage.derived      FROM '${REPO}/data/synthea/kndb/derived.csv'      WITH (FORMAT csv, HEADER true)"
fi

# 01_setup.sql: TRUNCATEs kndb.fact then INSERT SELECT ~565k rows.
$PSQL -f "${REPO}/demo/clinical/01_setup.sql" > "${RESULTS_DIR}/preload_out.txt" 2>&1
tail -20 "${RESULTS_DIR}/preload_out.txt"
$PSQL -tAc "SELECT 'kndb.fact preloaded: ' || count(*) FROM kndb.fact"

# --- 2) benchmark with KNDB_PRESERVE_FACTS=1 --------------------------------

log "== adversarial + throughput WITHOUT truncating (kndb preserves Synthea rows) =="
cd "$REPO/bench"

KNDB_PRESERVE_FACTS=1 \
KNDB_DSN="postgresql://kndb_native:kndb_native@localhost:5434/kndb_native" \
KNDB_TP_ROWS="${KNDB_TP_ROWS:-5000}" \
KNDB_TP_REPS="${KNDB_TP_REPS:-10}" \
  ./.venv/bin/python3 run.py > "${RESULTS_DIR}/run_out.txt" 2>&1 || true
tail -30 "${RESULTS_DIR}/run_out.txt"

log "== confirming kndb.fact still holds Synthea after adversarial replay =="
$PSQL -tAc "SELECT 'final kndb.fact row count: ' || count(*) FROM kndb.fact"

# --- 3) copy benchmark result CSVs into the synthea directory ---------------

if [[ -d "${REPO}/bench/results/kndb" ]]; then
  mkdir -p "${RESULTS_DIR}/kndb"
  cp "${REPO}/bench/results/kndb/"*.csv "${RESULTS_DIR}/kndb/" 2>/dev/null || true
fi
if [[ -d "${REPO}/bench/results/pg_handrolled_triggers" ]]; then
  mkdir -p "${RESULTS_DIR}/pg_handrolled_triggers"
  cp "${REPO}/bench/results/pg_handrolled_triggers/"*.csv "${RESULTS_DIR}/pg_handrolled_triggers/" 2>/dev/null || true
fi
cp "${REPO}/bench/results/summary_totals.csv"  "${RESULTS_DIR}/" 2>/dev/null || true
cp "${REPO}/bench/results/loc.csv"             "${RESULTS_DIR}/" 2>/dev/null || true

# --- 4) manifest ------------------------------------------------------------

cat > "$RESULTS_DIR/manifest.json" <<EOF
{
  "run_at":                "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')",
  "arch":                  "$(uname -m)",
  "kernel":                "$(uname -a | tr -d '\n')",
  "postgres":              "$($PSQL -tAc 'SHOW server_version' | tr -d '\n')",
  "provsql":               "$($PSQL -tAc "SELECT extversion FROM pg_extension WHERE extname='provsql'" | tr -d '\n')",
  "dsn":                   "postgresql://kndb_native:***@localhost:5434/kndb_native",
  "tp_rows":               ${KNDB_TP_ROWS:-5000},
  "tp_reps":               ${KNDB_TP_REPS:-10},
  "seed":                  42,
  "emulation":             false,
  "preserve_facts":        true,
  "kndb_fact_rows_before": $($PSQL -tAc "SELECT count(*) FROM kndb.fact" | tr -d ' '),
  "note":                  "Native ARM64 + Synthea 565k-row preload for G2.3. Absolute numbers here are the ones the paper should quote for KNDB throughput at realistic table size."
}
EOF

log "manifest: $RESULTS_DIR/manifest.json"
log "done."
