#!/usr/bin/env bash
# KNDB — load KNDB-shaped CSVs into stage.* tables in kndb-postgres.
#
# STAGING ONLY. This does not create the epistemic-typed kndb.*
# tables — that's M1's job. Everything here lands in schema `stage`,
# where the engine agent will read from and copy into typed tables
# with triggers attached.
#
# Assumes `make up` has run and container `kndb-postgres` is healthy.
# Idempotent: TRUNCATEs staging tables before COPY, so re-runs are safe.
#
# Env overrides:
#   KNDB_DATA_DIR      # where to read the three KNDB CSVs from
#                      # (default: data/synthea/kndb; CI points at data/ci_sample)
#   KNDB_CONTAINER     # container name (default: kndb-postgres)
#   PGDATABASE         # default: kndb
#   PGUSER             # default: kndb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KNDB_DATA_DIR="${KNDB_DATA_DIR:-${SCRIPT_DIR}/synthea/kndb}"
KNDB_CONTAINER="${KNDB_CONTAINER:-kndb-postgres}"
PGDATABASE="${PGDATABASE:-kndb}"
PGUSER="${PGUSER:-kndb}"

log() { printf "[load_postgres.sh] %s\n" "$*"; }

# --- pre-flight --------------------------------------------------------------

for f in observations.csv inferences.csv derived.csv; do
  if [[ ! -f "${KNDB_DATA_DIR}/${f}" ]]; then
    log "missing input: ${KNDB_DATA_DIR}/${f}"
    log "hint: run generate.sh and synthesize_labels.py first"
    exit 1
  fi
done

if ! docker inspect -f '{{.State.Running}}' "$KNDB_CONTAINER" >/dev/null 2>&1; then
  log "container $KNDB_CONTAINER is not running. Run 'make up' first."
  exit 2
fi

running=$(docker inspect -f '{{.State.Running}}' "$KNDB_CONTAINER")
if [[ "$running" != "true" ]]; then
  log "container $KNDB_CONTAINER exists but is not running ($running). Run 'make up'."
  exit 2
fi

# Convenience wrapper around psql-in-container.
psql_exec() {
  docker exec -i "$KNDB_CONTAINER" psql \
    -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"
}

# --- create staging schema ---------------------------------------------------
#
# Deliberately plain, untriggered, unconstrained: staging is what the
# M1 engine agent reads from and (with its typed triggers attached)
# copies into the real kndb.* tables. If we constrained here, we'd
# be double-enforcing and hiding the "engine catches bad writes"
# story the paper wants to tell.

log "creating schema stage and staging tables (IF NOT EXISTS)"
psql_exec <<'SQL'
CREATE SCHEMA IF NOT EXISTS stage;

CREATE TABLE IF NOT EXISTS stage.observations (
  id             integer PRIMARY KEY,
  patient_id     text NOT NULL,
  code           text NOT NULL,
  value          double precision NOT NULL,
  unit           text,
  effective_time text NOT NULL,     -- ISO-8601 string; M1 will cast to timestamptz
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
SQL

# --- truncate + copy ---------------------------------------------------------
#
# Order matters only for readability — no FKs across staging.

log "truncating stage.* tables"
psql_exec -c "TRUNCATE stage.observations, stage.inferences, stage.derived;"

# COPY FROM STDIN so we don't need to bind-mount data/ into the container.
copy_csv() {
  local table="$1" file="$2"
  log "COPY ${table} FROM ${file}"
  docker exec -i "$KNDB_CONTAINER" psql \
    -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
    -c "\\copy ${table} FROM STDIN WITH (FORMAT csv, HEADER true)" \
    < "$file"
}

copy_csv stage.observations "${KNDB_DATA_DIR}/observations.csv"
copy_csv stage.inferences   "${KNDB_DATA_DIR}/inferences.csv"
copy_csv stage.derived      "${KNDB_DATA_DIR}/derived.csv"

# --- smell test --------------------------------------------------------------

log "row counts:"
psql_exec -At <<'SQL'
SELECT '  stage.observations: ' || count(*) FROM stage.observations
UNION ALL
SELECT '  stage.inferences:   ' || count(*) FROM stage.inferences
UNION ALL
SELECT '  stage.derived:      ' || count(*) FROM stage.derived;
SQL

log "done. next: M1 engine agent copies stage.* → kndb.* with triggers."
