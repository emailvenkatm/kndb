#!/usr/bin/env bash
# KNDB clinical demo — runs the trust story on REAL Synthea data.
# Prerequisites:
#   - `make up` container running (kndb-postgres on port 5433).
#   - `make engine` applied.
#   - Synthea data generated: `bash data/generate.sh` (10k patients).
#   - Labels synthesized: `python3 data/synthesize_labels.py`.
#   - Stage loaded: `bash data/load_postgres.sh`.
#
# Then run: `bash demo/demo_clinical.sh`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PSQL() { docker compose exec -T kndb-postgres psql -U kndb -d kndb -X -q -v ON_ERROR_STOP=1 "$@"; }
PSQL_LOUD() { docker compose exec -T kndb-postgres psql -U kndb -d kndb -X -v ON_ERROR_STOP=1 "$@"; }

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
say()     { printf '  %s\n' "$1"; }

cd "$REPO"

section "Sanity check: stage tables loaded with real Synthea data"
PSQL_LOUD -c "SELECT
  (SELECT count(*) FROM stage.observations) AS observations,
  (SELECT count(*) FROM stage.inferences)   AS inferences,
  (SELECT count(*) FROM stage.derived)      AS derived,
  (SELECT count(DISTINCT patient_id) FROM stage.observations) AS patients;"

section "Copy stage.* into typed kndb.fact + register trial slot kinds"
PSQL -f /dev/stdin < demo/clinical/01_setup.sql

section "The attack + the screening query"
PSQL_LOUD -f /dev/stdin < demo/clinical/02_attack_and_screen.sql

echo
say "clinical demo complete."
