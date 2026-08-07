#!/usr/bin/env bash
#
# scripts/lock_exhaustion_ceiling.sh — probe the ADVISORY-LOCK ceiling.
#
# Companion to lock_exhaustion.sh, which stops at N=10000 (below the
# saturation point on default macOS PG18). This one sweeps higher N to
# find the exact ERROR 53200 threshold at max_locks_per_transaction=64
# and =1024. Emits result rows the paper can cite as the raw ceiling.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55499}"
DATADIR="${DATADIR:-/tmp/kndb_lockx_ceil_$$}"
LOG="${DATADIR}/server.log"
INITDB="${PGBIN}/initdb"; PG_CTL="${PGBIN}/pg_ctl"; PSQL="${PGBIN}/psql"

PSQL_CONN="-h ${DATADIR} -p ${PORT} -d postgres"

cleanup() {
    "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
    [ "${KEEP:-0}" = "1" ] || rm -rf "${DATADIR}"
}
trap cleanup EXIT

start_cluster() {
    local mlpt="$1"
    rm -rf "${DATADIR}"; mkdir -p "${DATADIR}"; chmod 700 "${DATADIR}"
    "${INITDB}" -D "${DATADIR}" -U "$(whoami)" --auth=trust --no-locale --encoding=UTF8 >/dev/null
    cat >> "${DATADIR}/postgresql.conf" <<CONF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${DATADIR}'
shared_preload_libraries = 'epistemic'
max_locks_per_transaction = ${mlpt}
log_min_messages = warning
CONF
    "${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 30 start >/dev/null
    "${PSQL}" ${PSQL_CONN} -Atq -c "CREATE EXTENSION epistemic;" >/dev/null
    "${PSQL}" ${PSQL_CONN} -Atq <<'SQL' >/dev/null
CREATE TABLE fact_ep (
    entity_id int NOT NULL, attribute text NOT NULL, value text,
    sources text[], valid_time tstzrange,
    sys_time tstzrange DEFAULT tstzrange(now(),'infinity'),
    ep_kind epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0
) USING epistemic;
SQL
}

try_batch() {
    local n="$1"
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE fact_ep;" >/dev/null 2>&1 || true
    local out
    out=$("${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq 2>&1 <<SQL
BEGIN;
INSERT INTO fact_ep (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence)
SELECT g, 'attr_'||g::text, 'v_'||g::text, tstzrange('2026-01-01','infinity'),
       'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real
  FROM generate_series(1, ${n}) g;
ROLLBACK;
SQL
)
    if echo "${out}" | grep -q "53200\|out of shared memory"; then
        # extract SQLSTATE and errmsg
        local emsg
        emsg=$(echo "${out}" | grep -m1 "ERROR" | head -1)
        printf 'FAIL|%s\n' "${emsg}"
    elif echo "${out}" | grep -qi "error"; then
        local emsg
        emsg=$(echo "${out}" | grep -m1 "ERROR" | head -1)
        printf 'OTHER|%s\n' "${emsg}"
    else
        printf 'OK|inserted %s rows\n' "${n}"
    fi
}

sweep() {
    local mlpt="$1"; shift
    echo ""
    echo "==============================================================="
    echo " max_locks_per_transaction = ${mlpt}"
    echo "==============================================================="
    start_cluster "${mlpt}"
    "${PSQL}" ${PSQL_CONN} -Atc "SHOW max_locks_per_transaction;" \
        | awk '{print "  SHOW: max_locks_per_transaction="$1}'
    "${PSQL}" ${PSQL_CONN} -Atc "SHOW max_connections;" \
        | awk '{print "  SHOW: max_connections="$1}'
    "${PSQL}" ${PSQL_CONN} -Atc "SELECT current_setting('max_locks_per_transaction')::int * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int);" \
        | awk '{print "  NLOCKENTS = mlpt*(max_conn+max_prep) = "$1}'
    printf "  %10s  %6s  %s\n" "N" "outcome" "msg"
    for N in "$@"; do
        r=$(try_batch "${N}")
        outcome="${r%%|*}"; msg="${r#*|}"
        printf "  %10s  %6s  %s\n" "${N}" "${outcome}" "${msg}"
    done
    "${PG_CTL}" -D "${DATADIR}" -m fast stop >/dev/null 2>&1 || true
}

sweep 64  10000 12000 14000 15000 16000 18000 20000 25000 30000
sweep 1024  100000 150000 200000 240000 250000 260000 300000

echo ""
echo "done"
