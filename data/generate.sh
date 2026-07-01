#!/usr/bin/env bash
# KNDB — Synthea data generation.
#
# Downloads the pinned Synthea JAR (verified by SHA256) and generates
# a synthetic patient population as CSV under data/synthea/output/csv/.
#
# Idempotent: skips generation if output/csv/patients.csv already
# exists, unless --force is passed.
#
# Env overrides:
#   POPULATION=10000     # patient count
#   STATE="Massachusetts"
#   SEED=42
#   OUTPUT_DIR=data/synthea/output
#
# See data/README.md for the full rationale and licence.

set -euo pipefail

# --- config ------------------------------------------------------------------

# Pinned to the last tagged release (v4.0.0, 2026-03-05). We deliberately
# do NOT track master-branch-latest — reproducibility over recency.
readonly SYNTHEA_VERSION="v4.0.0"
readonly SYNTHEA_JAR_URL="https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar"
readonly SYNTHEA_JAR_SHA256="ed43c20ad40ba5c3bc724503a5af032715fe3c491620b766148e7c2361e6ecc1"

POPULATION="${POPULATION:-10000}"
STATE="${STATE:-Massachusetts}"
SEED="${SEED:-42}"

# Resolve script dir → absolute paths so this script works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/synthea/output}"
JAR_DIR="${SCRIPT_DIR}/synthea/bin"
JAR_PATH="${JAR_DIR}/synthea-${SYNTHEA_VERSION}.jar"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--force]

Downloads Synthea ${SYNTHEA_VERSION} (verified by SHA256) and generates
POPULATION=${POPULATION} patients from STATE=${STATE} under ${OUTPUT_DIR}/csv/.

Skips if output/csv/patients.csv already exists; pass --force to override.
EOF
      exit 0 ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2 ;;
  esac
done

# --- helpers -----------------------------------------------------------------

# Portable sha256 — Linux has sha256sum, macOS has shasum -a 256.
sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "need sha256sum or shasum on PATH" >&2
    exit 1
  fi
}

log() { printf "[generate.sh] %s\n" "$*"; }

# --- idempotency check -------------------------------------------------------

CSV_DIR="${OUTPUT_DIR}/csv"
SENTINEL="${CSV_DIR}/patients.csv"

if [[ -f "$SENTINEL" && $FORCE -eq 0 ]]; then
  log "found existing output at $SENTINEL — skipping generation. Pass --force to override."
  exit 0
fi

# --- download Synthea JAR ----------------------------------------------------

mkdir -p "$JAR_DIR"

if [[ -f "$JAR_PATH" ]]; then
  log "Synthea JAR already present at $JAR_PATH; verifying SHA256..."
else
  log "downloading Synthea ${SYNTHEA_VERSION} → $JAR_PATH"
  # -L follow redirects (GitHub redirects to S3), -f fail on HTTP error,
  # --retry to survive transient network hiccups.
  curl -fL --retry 3 --retry-delay 2 -o "$JAR_PATH" "$SYNTHEA_JAR_URL"
fi

got="$(sha256_of "$JAR_PATH")"
if [[ "$got" != "$SYNTHEA_JAR_SHA256" ]]; then
  log "SHA256 mismatch:"
  log "  expected: $SYNTHEA_JAR_SHA256"
  log "  actual:   $got"
  log "refusing to run an unverified JAR. Delete $JAR_PATH and re-run to redownload."
  exit 3
fi
log "SHA256 verified."

# --- pre-flight --------------------------------------------------------------

if ! command -v java >/dev/null 2>&1; then
  log "java not found on PATH; Synthea needs Java 17+."
  exit 4
fi

# --- run Synthea -------------------------------------------------------------

# Clean output dir if forcing, to avoid CSV rows from a previous run leaking
# into a fresh generation.
if [[ $FORCE -eq 1 ]]; then
  log "--force: wiping $OUTPUT_DIR"
  rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

log "generating $POPULATION patients from $STATE (seed=$SEED)..."
# Synthea CLI:
#   -p N            population size
#   -s SEED         random seed for people (deterministic)
#   -cs SEED        random seed for clinician assignment
#   --exporter.*    per-format exporters; we want CSV only, no FHIR bloat
#   --exporter.baseDirectory
# See https://github.com/synthetichealth/synthea/wiki/Basic-Setup-and-Running
java -jar "$JAR_PATH" \
  -p "$POPULATION" \
  -s "$SEED" \
  -cs "$SEED" \
  --exporter.csv.export=true \
  --exporter.fhir.export=false \
  --exporter.hospital.fhir.export=false \
  --exporter.practitioner.fhir.export=false \
  --exporter.baseDirectory="$OUTPUT_DIR" \
  "$STATE"

# Synthea writes to $OUTPUT_DIR/csv/*.csv when csv.export=true. Sanity-check:
if [[ ! -f "$SENTINEL" ]]; then
  log "expected $SENTINEL after Synthea run; not found. Check Synthea output above."
  exit 5
fi

# Row count for a quick smell test.
patients=$(($(wc -l < "$SENTINEL") - 1))
observations=$(( $(wc -l < "${CSV_DIR}/observations.csv" 2>/dev/null || echo 1) - 1 ))
log "generation complete."
log "  patients:     $patients"
log "  observations: $observations"
log "  csv dir:      $CSV_DIR"
log "next: python3 $SCRIPT_DIR/synthesize_labels.py"
