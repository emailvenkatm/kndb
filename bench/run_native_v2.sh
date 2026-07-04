#!/usr/bin/env bash
# Re-run the KNDB benchmark on NATIVE Postgres (no amd64 emulation) — v2 engine.
#
# Assumes:
#   - The native install agent has provisioned Postgres 17 + ProvSQL 1.10.0
#     natively at postgresql://kndb_native:kndb_native@localhost:5434/kndb_native
#     (verified by both smoke tests passing natively on 2026-07-01).
#   - `bench/.venv` exists (created by the M6 agent).
#   - Synthea CSVs are already generated at data/synthea/kndb/*.csv.
#
# What this does:
#   1. Applies engine/00..08.sql (v2 lattice + use-permission views) to
#      the native kndb_native DB (fresh — DROP+recreate the kndb schema).
#   2. Loads Synthea stage.* into native (same CSVs the docker demo uses).
#   3. Runs the adversarial suite on the native DB.
#   4. Runs confidence-correctness on the native DB.
#   5. Runs the throughput benchmark on the native DB.
#   6. Writes all results into bench/results/native_v2/ so v1 numbers at
#      bench/results/native/ stay untouched for the comparison table.
#   7. Emits a manifest with the exact hardware/OS/arch string.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DSN="${KNDB_DSN_NATIVE:-postgresql://kndb_native:kndb_native@localhost:5434/kndb_native}"
NATIVE_HOST_PORT="localhost:5434"
NATIVE_DB="kndb_native"
NATIVE_USER="kndb_native"

RESULTS_DIR="${REPO}/bench/results/native_v2"
mkdir -p "$RESULTS_DIR"

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql -h localhost -p 5434 -U kndb_native -d kndb_native -X -v ON_ERROR_STOP=1 -v search_path=\"\$user\",public,provsql"

log() { printf "[run_native_v2] %s\n" "$*"; }

# --- pre-flight -------------------------------------------------------------

if ! $PSQL -c "SELECT 1" >/dev/null 2>&1; then
  log "cannot reach native Postgres at $NATIVE_DSN"
  log "expected the native install (agent report 2026-07-01) to be running"
  exit 1
fi
log "native Postgres reachable."

# --- 1) apply engine (fresh) -------------------------------------------------

log "== applying engine/*.sql to native (fresh) =="
$PSQL <<'SQL'
DROP SCHEMA IF EXISTS kndb CASCADE;
DROP SCHEMA IF EXISTS kndb_audit CASCADE;
DROP SCHEMA IF EXISTS stage CASCADE;
-- Match the docker bootstrap: put provsql on the DB search_path so
-- engine/06_provsql_setup.sql's unqualified add_provenance() resolves.
ALTER DATABASE kndb_native SET search_path = "$user", public, provsql;
SQL

for f in engine/00_extensions.sql engine/01_types.sql engine/02_facts_schema.sql \
         engine/03_triggers_epistemic.sql engine/04_triggers_conflict.sql \
         engine/05_bitemporal.sql engine/06_provsql_setup.sql engine/07_progressive_depth.sql \
         engine/08_use_permissions.sql; do
  log "  apply $f"
  $PSQL -f "${REPO}/${f}"
done

# --- 2) load Synthea stage tables -------------------------------------------

log "== loading Synthea into stage.* on native =="
$PSQL <<'SQL'
CREATE SCHEMA IF NOT EXISTS stage;
CREATE TABLE IF NOT EXISTS stage.observations (
  id             integer PRIMARY KEY,
  patient_id     text NOT NULL,
  code           text NOT NULL,
  value          double precision NOT NULL,
  unit           text,
  effective_time text NOT NULL,
  confidence     double precision NOT NULL
);
CREATE TABLE IF NOT EXISTS stage.inferences (
  id              integer PRIMARY KEY,
  patient_id      text NOT NULL,
  attribute       text NOT NULL,
  value           double precision NOT NULL,
  confidence      double precision NOT NULL,
  source_lab_ids  integer[] NOT NULL
);
CREATE TABLE IF NOT EXISTS stage.derived (
  id          integer PRIMARY KEY,
  patient_id  text NOT NULL,
  attribute   text NOT NULL,
  value       double precision NOT NULL,
  sources     integer[] NOT NULL
);
TRUNCATE stage.observations, stage.inferences, stage.derived;
SQL

$PSQL -c "\copy stage.observations FROM '${REPO}/data/synthea/kndb/observations.csv' WITH (FORMAT csv, HEADER true)"
$PSQL -c "\copy stage.inferences   FROM '${REPO}/data/synthea/kndb/inferences.csv'   WITH (FORMAT csv, HEADER true)"
$PSQL -c "\copy stage.derived      FROM '${REPO}/data/synthea/kndb/derived.csv'      WITH (FORMAT csv, HEADER true)"

$PSQL -tAc "SELECT 'obs=' || (SELECT count(*) FROM stage.observations)
                    || ' inf=' || (SELECT count(*) FROM stage.inferences)
                    || ' der=' || (SELECT count(*) FROM stage.derived);"

# --- 3) copy stage → typed kndb.fact ----------------------------------------
# Runs the SAME clinical setup script the docker demo uses.
log "== copying stage.* → kndb.fact via clinical/01_setup.sql =="
$PSQL -f "${REPO}/demo/clinical/01_setup.sql" > "${RESULTS_DIR}/01_setup_out.txt" 2>&1
tail -20 "${RESULTS_DIR}/01_setup_out.txt"

# --- 4) benchmark: adversarial + confidence + throughput --------------------

log "== running adversarial + throughput benchmark on native =="
cd "$REPO/bench"
KNDB_DSN="$NATIVE_DSN" \
  KNDB_TP_ROWS="${KNDB_TP_ROWS:-10000}" \
  KNDB_TP_REPS="${KNDB_TP_REPS:-10}" \
  ./.venv/bin/python3 run.py > "${RESULTS_DIR}/run_out.txt" 2>&1 || true
tail -20 "${RESULTS_DIR}/run_out.txt"

log "== running confidence-correctness benchmark on native =="
KNDB_DSN="$NATIVE_DSN" ./.venv/bin/python3 confidence_correctness.py > "${RESULTS_DIR}/confidence_out.txt" 2>&1 || true
tail -20 "${RESULTS_DIR}/confidence_out.txt"

log "== running loc counter =="
KNDB_DSN="$NATIVE_DSN" ./.venv/bin/python3 loc.py > "${RESULTS_DIR}/loc_out.txt" 2>&1 || true

# --- 5) snapshot per-system CSVs into RESULTS_DIR ---------------------------
# run.py writes CSVs to bench/results/{system}/ each run. Copy them into the
# v2 results dir so this snapshot is self-contained side by side with v1.
for sys in kndb pg_naive py_guards pg_handrolled_triggers; do
  if [[ -d "${REPO}/bench/results/${sys}" ]]; then
    mkdir -p "${RESULTS_DIR}/${sys}"
    cp "${REPO}/bench/results/${sys}/"*.csv "${RESULTS_DIR}/${sys}/" 2>/dev/null || true
  fi
done
cp "${REPO}/bench/results/summary_totals.csv" "${RESULTS_DIR}/" 2>/dev/null || true
cp "${REPO}/bench/results/summary_per_row.csv" "${RESULTS_DIR}/" 2>/dev/null || true
cp "${REPO}/bench/results/loc.csv" "${RESULTS_DIR}/" 2>/dev/null || true

# --- 6) manifest -------------------------------------------------------------

cat > "$RESULTS_DIR/manifest.json" <<EOF
{
  "run_at":     "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')",
  "arch":       "$(uname -m)",
  "kernel":     "$(uname -a | tr -d '\n')",
  "postgres":   "$($PSQL -tAc 'SHOW server_version' | tr -d '\n')",
  "provsql":    "$($PSQL -tAc "SELECT extversion FROM pg_extension WHERE extname='provsql'" | tr -d '\n')",
  "dsn":        "postgresql://kndb_native:***@localhost:5434/kndb_native",
  "tp_rows":    ${KNDB_TP_ROWS:-10000},
  "tp_reps":    ${KNDB_TP_REPS:-10},
  "seed":       42,
  "emulation":  false,
  "engine":     "v2",
  "note":       "Native Homebrew Postgres 17 + ProvSQL 1.10.0 built from source. No amd64 emulation. v2 engine (precedence lattice + use-permissions + specificity column)."
}
EOF

log "manifest written to $RESULTS_DIR/manifest.json"
log "done."
