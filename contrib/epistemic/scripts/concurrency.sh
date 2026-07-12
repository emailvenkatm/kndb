#!/usr/bin/env bash
#
# scripts/concurrency.sh — fair concurrency check under SERIALIZABLE.
#
# Both fact_native (USING epistemic) and fact_trigger (heap + BEFORE
# INSERT trigger) enforce R1/R3/R4 AND scan for a live overlap on the
# same (entity_id, attribute). Two SERIALIZABLE sessions each insert a
# MEASURED row for (1, 'bp') with overlapping valid_time. Expected: at
# least one 40001 on both sides. This isn't evidence of anything
# epistemic-specific — it just confirms both engines inherit heapam's
# predicate locking. The paper's actual differentiator is exercised by
# scripts/bypass.sh.
#
# Bash 3.2 compatible (macOS default). No GNU-only flags.

set -euo pipefail

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

log "creating extension, fact_native (USING epistemic), fact_trigger (heap)"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

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

-- Fair user-space equivalent: R1/R3/R4 plus the same overlap seqscan
-- the AM runs. The scan is what gives the trigger path a chance to
-- form the same rw-antidependency the native path forms via heapam.
CREATE OR REPLACE FUNCTION fact_trigger_rules()
RETURNS trigger AS $$
DECLARE
    k text;
    dummy int;
BEGIN
    k := NEW.ep_kind::text;

    IF k = 'DERIVED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R1 (DERIVED sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF k = 'MEASURED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R3 (MEASURED no sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF k = 'INFERRED' THEN
        IF NEW.ep_confidence IS NULL
           OR NEW.ep_confidence < 0.0
           OR NEW.ep_confidence >= 1.0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R4 (INFERRED confidence < 1.0)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- Same overlap probe the AM runs in find_live_overlap. Result is
    -- discarded; we only need the SIRead lock on the scan.
    SELECT 1 INTO dummy
    FROM fact_trigger
    WHERE entity_id = NEW.entity_id
      AND attribute = NEW.attribute
      AND upper(sys_time) = 'infinity'::timestamptz
      AND valid_time && NEW.valid_time
    LIMIT 1;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER fact_trigger_before_insert
    BEFORE INSERT ON fact_trigger
    FOR EACH ROW EXECUTE FUNCTION fact_trigger_rules();
SQL

ISO=$("${PSQL}" ${PSQL_CONN} -Atc "SHOW default_transaction_isolation;")
if [ "${ISO}" != "serializable" ]; then
    fail "default_transaction_isolation is '${ISO}', expected 'serializable'"
fi

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

    local hits1 hits2
    hits1=$(grep -c -E 'could not serialize|40001|serialization_failure' "${out1}" || true)
    hits2=$(grep -c -E 'could not serialize|40001|serialization_failure' "${out2}" || true)

    local rows
    rows=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM ${table} WHERE entity_id=1 AND attribute='bp';")

    printf '%s hits1=%s hits2=%s rows=%s\n' "${table}" "${hits1}" "${hits2}" "${rows}"

    printf '\n[concurrency.sh] --- %s session 1 transcript ---\n' "${table}"
    cat "${out1}" || true
    printf '\n[concurrency.sh] --- %s session 2 transcript ---\n' "${table}"
    cat "${out2}" || true
}

log "running race on fact_native"
NATIVE_LINE=$(run_race fact_native | tee /dev/stderr | grep -E '^fact_native ')

log "running race on fact_trigger"
TRIGGER_LINE=$(run_race fact_trigger | tee /dev/stderr | grep -E '^fact_trigger ')

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

# What this actually demonstrates: both AM.tuple_insert and the BEFORE
# INSERT trigger delegate their scan to heapam, so both acquire the
# SIRead lock heapam issues at heap_beginscan / heap_insert. Both
# abort. This is standard PG serializable behavior — not evidence of
# anything epistemic-specific. The engine-level difference the paper
# rests on is exercised in scripts/bypass.sh.
if [ "${NATIVE_TOTAL}" -ge 1 ] && [ "${TRIGGER_TOTAL}" -ge 1 ]; then
    log "PASS: both paths aborted under fair conditions (native>=1, trigger>=1). No epistemic-specific SSI claim implied."
    trap - EXIT
    cleanup
    exit 0
fi

log "UNEXPECTED: native=${NATIVE_TOTAL} trigger=${TRIGGER_TOTAL}. Under fair conditions both should abort at least one session."
trap - EXIT
cleanup
exit 1
