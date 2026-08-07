#!/usr/bin/env bash
# Fine-grained pinpoint of the advisory-lock ceiling. Also captures SQLSTATE.

set -euo pipefail
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55500}"
DATADIR="${DATADIR:-/tmp/kndb_lockx_pin_$$}"
INITDB="${PGBIN}/initdb"; PG_CTL="${PGBIN}/pg_ctl"; PSQL="${PGBIN}/psql"
PSQL_CONN="-h ${DATADIR} -p ${PORT} -d postgres"

cleanup() { "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true; rm -rf "${DATADIR}"; }
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
CONF
    "${PG_CTL}" -D "${DATADIR}" -l "${DATADIR}/server.log" -w -t 30 start >/dev/null
    "${PSQL}" ${PSQL_CONN} -Atq -c "CREATE EXTENSION epistemic;" >/dev/null
    "${PSQL}" ${PSQL_CONN} -Atq <<'SQL' >/dev/null
CREATE TABLE fact_ep (entity_id int NOT NULL, attribute text NOT NULL, value text,
    sources text[], valid_time tstzrange, sys_time tstzrange DEFAULT tstzrange(now(),'infinity'),
    ep_kind epistemic.epistemic_kind NOT NULL, ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0) USING epistemic;
SQL
}

try_batch() {
    local n="$1"
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE fact_ep;" >/dev/null 2>&1 || true
    # Use \echo directive to capture SQLSTATE via psql VERBOSE mode
    local out
    out=$("${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -v VERBOSITY=verbose 2>&1 <<SQL
BEGIN;
INSERT INTO fact_ep (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence)
SELECT g, 'attr_'||g::text, 'v_'||g::text, tstzrange('2026-01-01','infinity'),
       'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real
  FROM generate_series(1, ${n}) g;
ROLLBACK;
SQL
)
    if echo "${out}" | grep -qE "out of shared memory|53200"; then
        local sqlstate errmsg
        sqlstate=$(echo "${out}" | grep -m1 -oE "SQLSTATE:\s*[0-9A-Z]+" | awk '{print $2}')
        [ -z "${sqlstate}" ] && sqlstate=$(echo "${out}" | grep -m1 -oE "\b53[0-9]{3}\b" || echo "unknown")
        errmsg=$(echo "${out}" | grep -m1 "^ERROR" | head -1)
        printf 'FAIL|SQLSTATE=%s|%s\n' "${sqlstate}" "${errmsg}"
    elif echo "${out}" | grep -qi "error"; then
        printf 'OTHER|%s\n' "$(echo "${out}" | grep -m1 ERROR)"
    else
        printf 'OK|%s rows\n' "${n}"
    fi
}

sweep() {
    local mlpt="$1"; shift
    echo ""
    echo "==============================================================="
    echo " max_locks_per_transaction = ${mlpt}"
    echo "==============================================================="
    start_cluster "${mlpt}"
    "${PSQL}" ${PSQL_CONN} -Atc "SHOW max_locks_per_transaction;" | awk '{print "  SHOW: mlpt="$1}'
    "${PSQL}" ${PSQL_CONN} -Atc "SELECT current_setting('max_locks_per_transaction')::int * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int);" \
        | awk '{print "  NLOCKENTS = "$1}'
    printf "  %10s  %6s  %s\n" "N" "outcome" "detail"
    for N in "$@"; do
        r=$(try_batch "${N}")
        outcome="${r%%|*}"; detail="${r#*|}"
        printf "  %10s  %6s  %s\n" "${N}" "${outcome}" "${detail}"
    done
    "${PG_CTL}" -D "${DATADIR}" -m fast stop >/dev/null 2>&1 || true
}

# Fine sweep between 14000 and 15000 at mlpt=64
sweep 64 14200 14400 14600 14800 14900 14950 15000

# Fine sweep between 200000 and 240000 at mlpt=1024
sweep 1024 210000 220000 230000 235000 240000

echo ""
echo "done"
