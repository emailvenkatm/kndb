#!/usr/bin/env bash
#
# scripts/lock_exhaustion_scan.sh — F7 tight-scan across
# max_locks_per_transaction ∈ {64, 1024, 4096} to characterise the
# linearity of the exhaustion threshold vs the sizing formula
#     NLOCKENTS() = max_locks_per_xact * (MaxBackends + max_prepared_xacts)
# at src/backend/storage/lmgr/lock.c:56-57 REL_18_STABLE.
#
# Single-backend, single-txn, epistemic AM. We do an exponential
# doubling search on N, then bisect around the transition to find the
# exact failing N. Report: (mlpt, NLOCKENTS estimate, first failing N,
# ratio N / NLOCKENTS).
#
# Bash 3.2 compatible.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55501}"
DATADIR="${DATADIR:-/tmp/kndb_f7_scan_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log() { printf '[lockx_scan] %s\n' "$*"; }
fail() { printf '[lockx_scan] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        [ "${KEEP:-0}" = "1" ] || rm -rf "${DATADIR}"
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
max_connections = 100
log_min_messages = warning
log_line_prefix = '%m [%p] '
CONF
    "${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 30 start >/dev/null \
        || fail "postmaster failed to start"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q && break
        sleep 1
        [ "${i}" = "10" ] && fail "pg_isready never returned success"
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
SQL
}

stop_cluster() {
    "${PG_CTL}" -D "${DATADIR}" -m fast stop >/dev/null 2>&1 || true
}

# Returns 0 on success, 1 on failure.
insert_n() {
    local n="$1"
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE fact_ep;" \
        >/dev/null 2>&1
    local rc
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -X 2>/dev/null >/dev/null <<SQL
BEGIN;
INSERT INTO fact_ep (entity_id, attribute, value, valid_time,
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
    rc=$?
    return "${rc}"
}

# Exponential doubling then binary search. Prints "lo=X hi=Y" where lo
# is the max known good and hi is the min known bad.
find_threshold() {
    local lo=1
    local hi=""
    local N=1000
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if insert_n "${N}"; then
            lo="${N}"
            N=$(( N * 2 ))
        else
            hi="${N}"
            break
        fi
    done
    if [ -z "${hi}" ]; then
        printf 'lo=%d hi=UNBOUNDED_within_N<=%d\n' "${lo}" "${N}"
        return
    fi

    # Bisect.
    while [ $(( hi - lo )) -gt 100 ]; do
        local mid=$(( (lo + hi) / 2 ))
        if insert_n "${mid}"; then
            lo="${mid}"
        else
            hi="${mid}"
        fi
    done
    printf 'lo=%d hi=%d\n' "${lo}" "${hi}"
}

for MLPT in 64 1024 4096; do
    log ""
    log "==== max_locks_per_transaction = ${MLPT} ===="
    start_cluster "${MLPT}"
    nlockents=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT current_setting('max_locks_per_transaction')::int * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int);")
    log "  NLOCKENTS estimate = ${nlockents}"
    log "  bisecting single-backend threshold ..."
    result=$(find_threshold)
    log "  threshold : ${result}"
    stop_cluster
done

log "done"
