#!/usr/bin/env bash
#
# scripts/lock_exhaustion.sh — F7 characterization.
#
# Purpose: measure the batch-INSERT ceiling for the epistemic AM caused by
# the per-slot advisory xact lock in epistemic_tuple_insert_impl. The lock
# is xact-scoped (LockAcquire with sessionLock=false at lock.h:555-558
# REL_18_STABLE via pg_advisory_xact_lock's inline sibling); PG's shared
# lock hashtable is sized by
#     NLOCKENTS() = max_locks_per_xact * (MaxBackends + max_prepared_xacts)
# at src/backend/storage/lmgr/lock.c:56-57 REL_18_STABLE. When one txn
# inserts N distinct-slot rows, it accumulates N advisory LOCK entries
# before commit; once the shared table saturates, LockAcquire's
# SetupLockInTable path fails and reports ERRCODE_OUT_OF_MEMORY
# (lock.c:1076-1082) with errmsg "out of shared memory" / errhint
# "You might need to increase max_locks_per_transaction".
#
# This script does not fix anything. It spins a private cluster with
# DEFAULT max_locks_per_transaction=64, sweeps N over a grid, and reports:
#   - the exact N at which the epistemic-AM batch insert fails
#   - the SQLSTATE and errmsg
#   - the pg_locks growth curve
#   - the same sweep against a plain-heap table for control
#   - the same sweep at max_locks_per_transaction={1024, 4096}
#     to verify the sizing formula's linearity
#
# Bash 3.2 compatible (macOS default).

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_CONFIG="${PG_CONFIG:-${PGBIN}/pg_config}"
PORT="${PORT:-55498}"
DATADIR="${DATADIR:-/tmp/kndb_f7_lockx_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[lock_exhaustion.sh] %s\n' "$*"; }
fail() { printf '[lock_exhaustion.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        else
            log "datadir kept: ${DATADIR}"
        fi
    fi
}
trap cleanup EXIT

start_cluster() {
    local mlpt="$1"
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
max_locks_per_transaction = ${mlpt}
log_min_messages = warning
log_line_prefix = '%m [%p] '
CONF
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

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

CREATE TABLE fact_ep (
    entity_id      int NOT NULL,
    attribute      text NOT NULL,
    value          text,
    sources        text[],
    valid_time     tstzrange,
    sys_time       tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind        epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence  real NOT NULL DEFAULT 1.0
) USING epistemic;

CREATE TABLE fact_heap (
    entity_id      int NOT NULL,
    attribute      text NOT NULL,
    value          text,
    sources        text[],
    valid_time     tstzrange,
    sys_time       tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind        epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence  real NOT NULL DEFAULT 1.0
);
SQL
}

stop_cluster() {
    "${PG_CTL}" -D "${DATADIR}" -m fast stop >/dev/null 2>&1 || true
}

# Insert N distinct-slot rows into `tbl` in one txn. Emits three columns:
# outcome (OK|FAIL), sqlstate, errmsg (trimmed).
try_batch() {
    local tbl="$1"
    local n="$2"
    local outfile
    outfile=$(mktemp)

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE ${tbl};" \
        >/dev/null 2>&1 || true

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X <<SQL >"${outfile}" 2>&1
BEGIN;
INSERT INTO ${tbl} (entity_id, attribute, value, valid_time,
                    ep_kind, ep_specificity, ep_confidence)
SELECT g,
       'attr_' || g::text,
       'v_' || g::text,
       tstzrange('2026-01-01', 'infinity'),
       'MEASURED'::epistemic.epistemic_kind,
       5::int2,
       0.8::real
  FROM generate_series(1, ${n}) g;
COMMIT;
SQL
    local rc=$?

    if grep -qE 'ERROR|FATAL' "${outfile}"; then
        # Extract SQLSTATE if psql printed it (we did not set VERBOSITY,
        # so we get errmsg only; that's fine, we caption it separately).
        local msg
        msg=$(grep -m1 -E 'ERROR|FATAL' "${outfile}" | head -c 200 | tr -d '\r')
        printf 'FAIL|%s\n' "${msg}"
    else
        printf 'OK|%d rows\n' "${n}"
    fi
    rm -f "${outfile}"
    return 0
}

# Same as try_batch but also asks for VERBOSITY verbose so SQLSTATE is
# visible in psql's error output. Useful once we've found the failing N.
try_batch_verbose() {
    local tbl="$1"
    local n="$2"
    local outfile
    outfile=$(mktemp)

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE ${tbl};" \
        >/dev/null 2>&1 || true

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X <<SQL >"${outfile}" 2>&1
\set VERBOSITY verbose
BEGIN;
INSERT INTO ${tbl} (entity_id, attribute, value, valid_time,
                    ep_kind, ep_specificity, ep_confidence)
SELECT g,
       'attr_' || g::text,
       'v_' || g::text,
       tstzrange('2026-01-01', 'infinity'),
       'MEASURED'::epistemic.epistemic_kind,
       5::int2,
       0.8::real
  FROM generate_series(1, ${n}) g;
COMMIT;
SQL
    cat "${outfile}"
    rm -f "${outfile}"
}

# Probe pg_locks mid-txn: BEGIN; INSERT half; count advisory; ROLLBACK.
count_advisory_locks_at() {
    local tbl="$1"
    local n="$2"

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE ${tbl};" \
        >/dev/null 2>&1 || true

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq <<SQL 2>&1
BEGIN;
INSERT INTO ${tbl} (entity_id, attribute, value, valid_time,
                    ep_kind, ep_specificity, ep_confidence)
SELECT g,
       'attr_' || g::text,
       'v_' || g::text,
       tstzrange('2026-01-01', 'infinity'),
       'MEASURED'::epistemic.epistemic_kind,
       5::int2,
       0.8::real
  FROM generate_series(1, ${n}) g;
SELECT count(*) FROM pg_locks
 WHERE locktype = 'advisory' AND pid = pg_backend_pid();
ROLLBACK;
SQL
}

# ------------------------------------------------------------------
# Main sweep at each max_locks_per_transaction
# ------------------------------------------------------------------
SWEEP="10 32 50 60 63 64 65 70 100 200 500 1000 2000 5000 10000"

for MLPT in 64 1024 4096; do
    log ""
    log "==============================================================="
    log " max_locks_per_transaction = ${MLPT}"
    log "==============================================================="

    start_cluster "${MLPT}"

    "${PSQL}" ${PSQL_CONN} -Atc "SHOW max_locks_per_transaction;" \
        | awk '{print "[lock_exhaustion.sh]   SHOW: max_locks_per_transaction="$1}'
    "${PSQL}" ${PSQL_CONN} -Atc "SHOW max_connections;" \
        | awk '{print "[lock_exhaustion.sh]   SHOW: max_connections="$1}'
    "${PSQL}" ${PSQL_CONN} -Atc "SHOW max_prepared_transactions;" \
        | awk '{print "[lock_exhaustion.sh]   SHOW: max_prepared_transactions="$1}'

    log ""
    log "  sweep on fact_ep (USING epistemic):"
    printf '[lock_exhaustion.sh]   %8s %8s %s\n' "N" "outcome" "errmsg"
    FIRST_FAIL_EP=""
    for N in ${SWEEP}; do
        res=$(try_batch fact_ep "${N}")
        outcome="${res%%|*}"
        rest="${res#*|}"
        printf '[lock_exhaustion.sh]   %8s %8s %s\n' "${N}" "${outcome}" "${rest}"
        if [ "${outcome}" = "FAIL" ] && [ -z "${FIRST_FAIL_EP}" ]; then
            FIRST_FAIL_EP="${N}"
        fi
    done

    log ""
    log "  sweep on fact_heap (plain heap, no advisory locks):"
    printf '[lock_exhaustion.sh]   %8s %8s %s\n' "N" "outcome" "errmsg"
    FIRST_FAIL_HEAP=""
    for N in ${SWEEP}; do
        res=$(try_batch fact_heap "${N}")
        outcome="${res%%|*}"
        rest="${res#*|}"
        printf '[lock_exhaustion.sh]   %8s %8s %s\n' "${N}" "${outcome}" "${rest}"
        if [ "${outcome}" = "FAIL" ] && [ -z "${FIRST_FAIL_HEAP}" ]; then
            FIRST_FAIL_HEAP="${N}"
        fi
    done

    log ""
    log "  advisory-lock growth curve at N=32,64,100,500 (mid-txn count on fact_ep):"
    for N in 32 64 100 500; do
        out=$(count_advisory_locks_at fact_ep "${N}" 2>&1)
        # last non-empty line (before ROLLBACK) that is a bare integer is the count
        cnt=$(printf '%s\n' "${out}" | grep -E '^[0-9]+$' | tail -1)
        if [ -z "${cnt}" ]; then
            cnt="(insert failed before probe: $(printf '%s\n' "${out}" | grep -m1 -E 'ERROR' | head -c 120))"
        fi
        printf '[lock_exhaustion.sh]   N=%-6s advisory locks held mid-txn = %s\n' "${N}" "${cnt}"
    done

    log ""
    if [ -n "${FIRST_FAIL_EP}" ]; then
        log "  first failing N on fact_ep at mlpt=${MLPT}: ${FIRST_FAIL_EP}"
        log "  verbose reproduction at N=${FIRST_FAIL_EP}:"
        try_batch_verbose fact_ep "${FIRST_FAIL_EP}" \
            | sed 's/^/[lock_exhaustion.sh]     /'
    else
        log "  no failure on fact_ep across sweep at mlpt=${MLPT}"
    fi
    if [ -n "${FIRST_FAIL_HEAP}" ]; then
        log "  first failing N on fact_heap at mlpt=${MLPT}: ${FIRST_FAIL_HEAP}"
    else
        log "  no failure on fact_heap across sweep at mlpt=${MLPT}"
    fi

    stop_cluster
done

log ""
log "done"
