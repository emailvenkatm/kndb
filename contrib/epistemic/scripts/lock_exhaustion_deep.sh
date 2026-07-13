#!/usr/bin/env bash
#
# scripts/lock_exhaustion_deep.sh — F7 follow-on. The first-pass sweep in
# lock_exhaustion.sh climbed to N=10000 without triggering "out of shared
# memory" at max_locks_per_transaction=64. That is not a bug in the AM;
# it is a direct consequence of PG's shared-lock-table sizing at
# src/backend/storage/lmgr/lock.c:56-57 REL_18_STABLE:
#
#   NLOCKENTS() = max_locks_per_xact * (MaxBackends + max_prepared_xacts)
#
# and the note at src/backend/utils/misc/postgresql.conf.sample /
# postgresql.org/docs/18/runtime-config-locks.html that
# max_locks_per_transaction is the *average* per-backend budget, not a
# per-transaction hard cap. A single backend can consume the pool if
# other backends are idle.
#
# This script pushes N far past 10k on a single connection to characterise
# the actual ceiling, and then re-runs the sweep with many concurrent
# lock-holding backends to force the shared table to saturate.
#
# Bash 3.2 compatible.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55499}"
DATADIR="${DATADIR:-/tmp/kndb_f7_lockxdeep_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[lockx_deep] %s\n' "$*"; }
fail() { printf '[lockx_deep] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        [ "${KEEP:-0}" = "1" ] || rm -rf "${DATADIR}"
    fi
    # kill any lingering hog backends
    for pid in ${HOG_PIDS:-}; do
        kill "${pid}" 2>/dev/null || true
    done
}
trap cleanup EXIT

start_cluster() {
    local mlpt="$1"
    local mconn="$2"
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
max_connections = ${mconn}
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

try_batch_verbose() {
    local tbl="$1"
    local n="$2"
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE ${tbl};" \
        >/dev/null 2>&1 || true
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X 2>&1 <<SQL
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
}

# ---------------- Case A: single-backend deep sweep at mlpt=64 ----------------
log "==== Case A: single backend, max_locks_per_transaction=64, max_connections=100 ===="
start_cluster 64 100
"${PSQL}" ${PSQL_CONN} -Atc "SELECT current_setting('max_locks_per_transaction')::int * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int) AS nlockents_estimate;" | awk '{print "[lockx_deep]   NLOCKENTS estimate = "$1}'

DEEP="10000 20000 50000 100000 200000 500000 1000000"
for N in ${DEEP}; do
    log "  attempting N=${N} on fact_ep ..."
    out=$(try_batch_verbose fact_ep "${N}" 2>&1)
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        err=$(printf '%s\n' "${out}" | grep -m3 -E 'ERROR|FATAL|DETAIL|HINT' | tr '\n' ' | ')
        log "  N=${N}: FAILED. ${err}"
        FIRST_FAIL="${N}"
        break
    else
        log "  N=${N}: OK"
    fi
done

if [ -z "${FIRST_FAIL:-}" ]; then
    log "  single-backend deep sweep completed to N=${N} without failure."
fi

stop_cluster

# ---------------- Case B: many concurrent hoggers vs one AM writer ----------------
log ""
log "==== Case B: concurrent hoggers saturate the shared table ===="
log "  cluster: mlpt=64, max_connections=100, so NLOCKENTS ~= 6400 slots"
start_cluster 64 100

# Spawn K hog sessions, each holding H advisory locks under an open txn.
# We drive that from psql using pg_advisory_xact_lock() so no AM code is
# involved: this is the pure PG behaviour.
K_HOGS=90    # 90 hog sessions, leaves ~10 headroom for our victim + system
H_PER=60     # each holds 60 advisory locks

HOG_PIDS=""
for k in $(seq 1 ${K_HOGS}); do
    (
        "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq <<SQL >"${DATADIR}/hog_${k}.log" 2>&1
BEGIN;
SELECT pg_advisory_xact_lock(${k}::int, g::int)
  FROM generate_series(1, ${H_PER}) g;
SELECT pg_sleep(120);
ROLLBACK;
SQL
    ) &
    HOG_PIDS="${HOG_PIDS} $!"
done

# Give hogs a moment to acquire.
sleep 4

used=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM pg_locks WHERE locktype='advisory';")
log "  hogs alive; shared pg_locks advisory count = ${used}"

# Victim: try INSERTs into fact_ep under this loaded table.
log "  victim (AM writer) sweep under load:"
for N in 10 32 64 100 200 500 1000; do
    out=$(try_batch_verbose fact_ep "${N}" 2>&1)
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        err=$(printf '%s\n' "${out}" | grep -m3 -E 'ERROR|FATAL|DETAIL|HINT' | tr '\n' ' | ')
        log "  N=${N}: FAILED. ${err}"
    else
        log "  N=${N}: OK"
    fi
done

# Also try a pure pg_advisory_xact_lock victim to isolate AM from PG behavior.
log ""
log "  pure pg_advisory_xact_lock() victim under same load:"
for N in 10 32 64 100 200 500; do
    out=$("${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq 2>&1 <<SQL
\set VERBOSITY verbose
BEGIN;
SELECT pg_advisory_xact_lock(99::int, g::int)
  FROM generate_series(1, ${N}) g;
COMMIT;
SQL
)
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        err=$(printf '%s\n' "${out}" | grep -m3 -E 'ERROR|FATAL|DETAIL|HINT' | tr '\n' ' | ')
        log "  N=${N}: FAILED. ${err}"
    else
        log "  N=${N}: OK"
    fi
done

# Kill hogs.
for pid in ${HOG_PIDS}; do kill "${pid}" 2>/dev/null || true; done
HOG_PIDS=""
wait 2>/dev/null || true

stop_cluster
log "done"
