#!/usr/bin/env bash
#
# scripts/lock_exhaustion_linearity.sh — F7 point-probe to verify the
# threshold scales with max_locks_per_transaction. Rather than bisect
# (which is slow at mlpt=1024,4096), we probe a handful of Ns near the
# theoretically predicted threshold. The formula:
#
#     NLOCKENTS() = max_locks_per_xact * (MaxBackends + max_prepared_xacts)
#     max_table_size = NLOCKENTS                       (LOCK entries)
#     max_table_size = 2 * NLOCKENTS                   (PROCLOCK entries)
#     + 10% safety margin
#
# So the single-txn ceiling should scale linearly in max_locks_per_xact.
# At mlpt=64 our bisect landed at 14875..14937 (NLOCKENTS_est=6400, so
# ratio ~2.33 = the extensible-hashtable overprovision). Expect:
#   mlpt=1024 -> ceiling ~ 14900 * 16   ~= 238400
#   mlpt=4096 -> ceiling ~ 14900 * 64   ~= 953600
#
# We probe N ∈ {theoretical/2, theoretical, 2*theoretical} at each mlpt.
#
# Bash 3.2 compatible.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55503}"
DATADIR="${DATADIR:-/tmp/kndb_f7_lin_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log() { printf '[lockx_lin] %s\n' "$*"; }
fail() { printf '[lockx_lin] FAIL: %s\n' "$*" >&2; exit 1; }

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

try_batch() {
    local n="$1"
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE fact_ep;" \
        >/dev/null 2>&1 || true
    local outfile
    outfile=$(mktemp)
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X 2>&1 <<SQL >"${outfile}"
\set VERBOSITY verbose
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
    local outcome msg
    if grep -qE 'ERROR|FATAL' "${outfile}"; then
        msg=$(grep -m1 -E 'ERROR|FATAL' "${outfile}" | head -c 200 | tr -d '\r')
        outcome="FAIL"
    else
        msg="ok"
        outcome="OK"
    fi
    rm -f "${outfile}"
    printf '%s|%s\n' "${outcome}" "${msg}"
}

for MLPT in 64 1024 4096; do
    log ""
    log "==== max_locks_per_transaction = ${MLPT} ===="
    start_cluster "${MLPT}"
    nlockents=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT current_setting('max_locks_per_transaction')::int * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int);")
    log "  NLOCKENTS estimate = ${nlockents} (empirical single-txn ceiling should be ~2.33x this)"

    # Empirical ratio at mlpt=64 was ~14906/6400 = 2.33.
    THEO=$(( nlockents * 233 / 100 ))
    log "  theoretical ceiling from mlpt=64 baseline: ~${THEO}"

    # Probe: 40%, 80%, 100%, 120%, 160% of theoretical.
    for pct in 40 80 100 120 160; do
        N=$(( THEO * pct / 100 ))
        [ "${N}" -lt 100 ] && N=100
        res=$(try_batch "${N}")
        outcome="${res%%|*}"
        msg="${res#*|}"
        printf '[lockx_lin]   N=%-8s (%3s%% of theoretical) -> %s | %s\n' \
            "${N}" "${pct}" "${outcome}" "${msg}"
    done

    stop_cluster
done

log "done"
