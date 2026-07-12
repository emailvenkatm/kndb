#!/usr/bin/env bash
#
# scripts/concurrency.sh — Metric 2 validation.
#
# Demonstrates the differentiator between the native table AM (which
# calls PredicateLockTID inside its tuple_insert) and a trigger-based
# user-space equivalent that runs only R1..R5 write-time rules but does
# NOT scan for overlaps, and therefore acquires no SIRead lock.
#
# Setup:
#   fact_native  — USING epistemic
#   fact_trigger — plain heap + BEFORE INSERT trigger that mirrors R1/R3/R4
#
# Test:
#   Two concurrent SERIALIZABLE transactions each insert a MEASURED row
#   for (entity_id=1, attribute='bp') with overlapping valid_time.
#
# Expected native  : at least one 40001 (serialization_failure).
# Expected trigger : zero 40001 (trigger did no read, so no SIRead).
#
# If native admits both, that is reported as a HONEST NEGATIVE RESULT.
# The script exits 0 only if the differentiator is observed.

set -euo pipefail

# ------------------------- config -----------------------------------

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55491}"
DATADIR="${DATADIR:-/tmp/kndb_e_concurrency_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

# ------------------------- helpers ----------------------------------

log()  { printf '[concurrency.sh] %s\n' "$*"; }
fail() { printf '[concurrency.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${CONCURRENCY_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[concurrency.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
    fi
    exit "${rc}"
}
trap on_error EXIT

# ------------------------- 1. fresh cluster -------------------------

log "creating fresh cluster at ${DATADIR}"
rm -rf "${DATADIR}"
mkdir -p "${DATADIR}"
chmod 700 "${DATADIR}"

"${INITDB}" -D "${DATADIR}" -U "$(whoami)" --auth=trust --no-locale \
    --encoding=UTF8 >/dev/null

cat >> "${DATADIR}/postgresql.conf" <<CONF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${SOCKDIR}'
shared_preload_libraries = 'epistemic'
default_transaction_isolation = 'serializable'
log_min_messages = warning
log_line_prefix = '%m [%p] '
max_pred_locks_per_transaction = 128
CONF

log "starting postmaster"
"${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 30 start >/dev/null \
    || fail "postmaster failed to start"

for i in 1 2 3 4 5 6 7 8 9 10; do
    if "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q; then
        break
    fi
    sleep 1
    if [ "${i}" = "10" ]; then
        fail "pg_isready never returned success"
    fi
done

# ------------------------- 2. schemas -------------------------------

log "creating extension, fact_native (USING epistemic), fact_trigger (heap)"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

-- Native path.
CREATE TABLE fact_native (
    entity_id     int NOT NULL,
    attribute     text NOT NULL,
    value         text,
    sources       text[],
    valid_time    tstzrange,
    sys_time      tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind       epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0
) USING epistemic;

-- Trigger path: plain heap.
CREATE TABLE fact_trigger (
    entity_id     int NOT NULL,
    attribute     text NOT NULL,
    value         text,
    sources       text[],
    valid_time    tstzrange,
    sys_time      tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind       epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0
);

-- The user-space equivalent: R1, R3, R4 mirrored on NEW. Deliberately
-- does NOT read fact_trigger for overlap, so it acquires no SIRead
-- lock and cannot participate in an SSI conflict cycle.
CREATE OR REPLACE FUNCTION fact_trigger_rules()
RETURNS trigger AS $$
DECLARE
    k text;
BEGIN
    k := NEW.ep_kind::text;

    -- R1: DERIVED must have empty/null sources.
    IF k = 'DERIVED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R1 (DERIVED sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- R3: MEASURED must have empty/null sources.
    IF k = 'MEASURED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R3 (MEASURED no sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- R4: INFERRED must have confidence in [0, 1).
    IF k = 'INFERRED' THEN
        IF NEW.ep_confidence IS NULL
           OR NEW.ep_confidence < 0.0
           OR NEW.ep_confidence >= 1.0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R4 (INFERRED confidence < 1.0)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER fact_trigger_before_insert
    BEFORE INSERT ON fact_trigger
    FOR EACH ROW EXECUTE FUNCTION fact_trigger_rules();
SQL

# Sanity: confirm SERIALIZABLE is the default.
ISO=$("${PSQL}" ${PSQL_CONN} -Atc "SHOW default_transaction_isolation;")
if [ "${ISO}" != "serializable" ]; then
    fail "default_transaction_isolation is '${ISO}', expected 'serializable'"
fi

# ------------------------- 3. run one table -------------------------

# Two overlapping MEASURED inserts for (entity_id=1, attribute='bp').
# Both use tstzrange('2026-01-01', 'infinity') to guarantee overlap.
#
# The `pg_sleep(0.5)` in the middle of each transaction interleaves the
# reads and writes so that (a) both snapshots are taken before either
# commits, and (b) both physical inserts happen before either commit.
#
# For the native path, the AM does a find_live_overlap scan, which
# takes a SIRead lock; the second inserter's write hits
# CheckForSerializableConflictIn on the losing side, producing 40001
# for at least one session at COMMIT time.
#
# For the trigger path, neither session reads the other; both commits
# should succeed and the table should contain 2 rows.

WORKDIR="${DATADIR}/work"
mkdir -p "${WORKDIR}"

run_race() {
    local table="$1"

    local out1="${WORKDIR}/${table}_s1.log"
    local out2="${WORKDIR}/${table}_s2.log"

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out1}" 2>&1 &
BEGIN ISOLATION LEVEL SERIALIZABLE;
INSERT INTO ${table} (entity_id, attribute, value, valid_time, ep_kind,
                     ep_specificity, ep_confidence)
VALUES (1, 'bp', 's1_120/80',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 0::int2, 1.0::real);
SELECT pg_sleep(0.7);
COMMIT;
SQL
    local pid1=$!

    # tiny stagger so session 2 starts its BEGIN cleanly after session 1
    # has already inserted and gone to sleep
    sleep 0.2

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out2}" 2>&1 &
BEGIN ISOLATION LEVEL SERIALIZABLE;
INSERT INTO ${table} (entity_id, attribute, value, valid_time, ep_kind,
                     ep_specificity, ep_confidence)
VALUES (1, 'bp', 's2_130/85',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 0::int2, 1.0::real);
SELECT pg_sleep(0.7);
COMMIT;
SQL
    local pid2=$!

    wait "${pid1}" || true
    wait "${pid2}" || true

    # Count 40001 (serialization_failure) markers in each transcript.
    # psql prints "ERROR:  could not serialize access due to ..." for SSI
    # aborts. We also accept "SQLSTATE 40001".
    local hits1 hits2
    hits1=$(grep -c -E 'could not serialize|40001|serialization_failure' "${out1}" || true)
    hits2=$(grep -c -E 'could not serialize|40001|serialization_failure' "${out2}" || true)

    local rows
    rows=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM ${table} WHERE entity_id=1 AND attribute='bp';")

    # Emit machine-parseable line for the caller.
    printf '%s hits1=%s hits2=%s rows=%s\n' "${table}" "${hits1}" "${hits2}" "${rows}"

    # Also stash session logs into the parent output for the report.
    printf '\n[concurrency.sh] --- %s session 1 transcript ---\n' "${table}"
    cat "${out1}" || true
    printf '\n[concurrency.sh] --- %s session 2 transcript ---\n' "${table}"
    cat "${out2}" || true
}

log "running race on fact_native"
NATIVE_LINE=$(run_race fact_native | tee /dev/stderr | grep -E '^fact_native ')

log "running race on fact_trigger"
TRIGGER_LINE=$(run_race fact_trigger | tee /dev/stderr | grep -E '^fact_trigger ')

# Parse: "<table> hits1=X hits2=Y rows=Z"
NATIVE_H1=$(printf '%s' "${NATIVE_LINE}" | sed -E 's/.* hits1=([0-9]+).*/\1/')
NATIVE_H2=$(printf '%s' "${NATIVE_LINE}" | sed -E 's/.* hits2=([0-9]+).*/\1/')
NATIVE_ROWS=$(printf '%s' "${NATIVE_LINE}" | sed -E 's/.* rows=([0-9]+).*/\1/')
NATIVE_TOTAL=$(( NATIVE_H1 + NATIVE_H2 ))

TRIGGER_H1=$(printf '%s' "${TRIGGER_LINE}" | sed -E 's/.* hits1=([0-9]+).*/\1/')
TRIGGER_H2=$(printf '%s' "${TRIGGER_LINE}" | sed -E 's/.* hits2=([0-9]+).*/\1/')
TRIGGER_ROWS=$(printf '%s' "${TRIGGER_LINE}" | sed -E 's/.* rows=([0-9]+).*/\1/')
TRIGGER_TOTAL=$(( TRIGGER_H1 + TRIGGER_H2 ))

log "----- results -----"
log "fact_native  : 40001_sessions=${NATIVE_TOTAL}  rows_post=${NATIVE_ROWS}"
log "fact_trigger : 40001_sessions=${TRIGGER_TOTAL} rows_post=${TRIGGER_ROWS}"

# Verdicts.
NATIVE_VERDICT="undecided"
TRIGGER_VERDICT="undecided"

if [ "${NATIVE_TOTAL}" -ge 1 ]; then
    NATIVE_VERDICT="PASS: native path rejected at least one interleaving (${NATIVE_TOTAL} session(s) got 40001)"
else
    NATIVE_VERDICT="NEGATIVE: native path admitted both concurrent overlapping inserts; no 40001 raised. The AM's PredicateLockTID/CheckForSerializableConflictIn hookup is not producing a conflict cycle in this workload."
fi

if [ "${TRIGGER_TOTAL}" -eq 0 ]; then
    TRIGGER_VERDICT="PASS: trigger path admitted both interleavings (0 sessions got 40001), as designed."
else
    TRIGGER_VERDICT="UNEXPECTED: trigger path raised 40001 in ${TRIGGER_TOTAL} session(s); the trigger must have read the table."
fi

log "verdict native  : ${NATIVE_VERDICT}"
log "verdict trigger : ${TRIGGER_VERDICT}"

# Overall exit code: zero only if we can point at a clear differentiator.
# The differentiator is "native rejects, trigger admits".
if [ "${NATIVE_TOTAL}" -ge 1 ] && [ "${TRIGGER_TOTAL}" -eq 0 ]; then
    log "PASS: differentiator observed (native>=1 40001, trigger=0)"
    trap - EXIT
    cleanup
    exit 0
elif [ "${NATIVE_TOTAL}" -eq 0 ] && [ "${TRIGGER_TOTAL}" -eq 0 ]; then
    log "HONEST NEGATIVE: both paths admitted the interleaving. This is what the task brief anticipated: Agent A's PoC skipped physical eviction and does not fully wire CheckForSerializableConflictIn on the write side."
    trap - EXIT
    cleanup
    exit 2
else
    log "FAIL: unexpected combination (native=${NATIVE_TOTAL} trigger=${TRIGGER_TOTAL})"
    trap - EXIT
    cleanup
    exit 1
fi
