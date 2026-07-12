#!/usr/bin/env bash
#
# scripts/crash_atomicity_broken.sh — adversarial atomicity harness.
#
# Purpose. Deliberately break the eviction-audit atomicity by making
# the audit row commit in a SEPARATE top-level transaction (via
# dblink), then run the same crash race as crash_atomicity.sh and
# show the invariant fails. This is the negative-control that proves
# crash_atomicity.sh's passing verdict is not vacuous — the invariant
# CAN be broken, and PG's per-statement transaction model is what
# holds it in the honest run.
#
# Mechanism. We install a BEFORE INSERT trigger on
# epistemic.evicted_fact that opens a dblink connection to the same
# database and executes an INSERT into a mirror relation
# epistemic.evicted_fact_shadow. dblink_exec runs the INSERT on a
# fresh backend that opens its OWN top-level transaction, commits it
# on function return, and closes. So the shadow row is durable the
# instant the trigger returns — even if the AM's own SPI-driven
# INSERT into evicted_fact rolls back with the outer statement's
# transaction. The two writes are no longer atomic.
#
# We measure `audit` from evicted_fact_shadow. The invariant becomes:
#   live == 1  AND  audit == closed  (i.e., every audit row corresponds
#                                     to an actual closed incumbent)
# On the broken variant, we expect trials with audit > closed (an audit
# row exists for an eviction whose main-txn changes were discarded by
# recovery).
#
# We do NOT rebuild the AM. The break lives entirely in SQL: a
# BEFORE INSERT trigger + a plpgsql wrapper around dblink_exec. This
# is the honest form of the artificial break — no C changes, just a
# demonstration that IF the audit path were rerouted through an
# out-of-band commit, the invariant would fail.
#
# Bash 3.2 compatible (macOS default). No GNU-only flags.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55494}"
DATADIR="${DATADIR:-/tmp/kndb_e_crashbroken_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

TRIALS="${TRIALS:-25}"
EVICTIONS_PER_TRIAL="${EVICTIONS_PER_TRIAL:-400}"
CRASH_DELAY_MS="${CRASH_DELAY_MS:-20}"

log()  { printf '[crash_atomicity_broken.sh] %s\n' "$*"; }
fail() { printf '[crash_atomicity_broken.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${CRASH_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[crash_atomicity_broken.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[crash_atomicity_broken.sh] --- last 40 lines of server.log ---\n' >&2
            tail -n 40 "${LOG}" >&2 || true
        fi
    fi
    exit "${rc}"
}
trap on_error EXIT

# ------------------------------------------------------------------
# 1. fresh cluster
# ------------------------------------------------------------------
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
fsync = on
synchronous_commit = on
full_page_writes = on
log_min_messages = warning
log_line_prefix = '%m [%p] '
CONF

start_cluster() {
    "${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 30 start >/dev/null \
        || fail "postmaster failed to start"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q; then
            return 0
        fi
        sleep 1
    done
    fail "pg_isready never returned success"
}

log "starting postmaster"
start_cluster

# ------------------------------------------------------------------
# 2. schema + break
# ------------------------------------------------------------------
log "installing extension, dblink, and the trigger-based break"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;
CREATE EXTENSION IF NOT EXISTS dblink;

INSERT INTO epistemic.source_registry (source_id, source_type)
VALUES ('s1', 'device')
ON CONFLICT (source_id) DO NOTHING;

CREATE TABLE fact (
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

-- The mirror relation the trigger writes to via dblink. It has no
-- primary key or generated columns so a raw INSERT via dblink_exec
-- can populate it directly.
CREATE TABLE epistemic.evicted_fact_shadow (
    reason         text NOT NULL,
    winner_ctid    text,
    original_kind  epistemic.epistemic_kind NOT NULL,
    original_row   jsonb NOT NULL,
    shadowed_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Break: BEFORE INSERT trigger on evicted_fact opens a fresh backend
-- via dblink and executes the shadow insert in that backend's own
-- top-level transaction. Because dblink_exec runs against a separate
-- connection, its work is committed on function return regardless of
-- whether our (outer) transaction commits or rolls back.
CREATE OR REPLACE FUNCTION epistemic._break_audit_via_dblink()
RETURNS trigger AS \$\$
DECLARE
    conn text := 'user=$(whoami) port=${PORT} host=${SOCKDIR} dbname=postgres';
    sqltxt text;
BEGIN
    sqltxt := format(
        'INSERT INTO epistemic.evicted_fact_shadow '
        '(reason, winner_ctid, original_kind, original_row) '
        'VALUES (%L, %L, %L::epistemic.epistemic_kind, %L::jsonb)',
        NEW.reason, NEW.winner_ctid,
        NEW.original_kind::text, NEW.original_row::text);
    PERFORM dblink_exec(conn, sqltxt);
    RETURN NEW;
END;
\$\$ LANGUAGE plpgsql;

CREATE TRIGGER _break_audit_trg
    BEFORE INSERT ON epistemic.evicted_fact
    FOR EACH ROW EXECUTE FUNCTION epistemic._break_audit_via_dblink();
SQL

# Sanity: confirm the trigger is installed.
TRG=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM pg_trigger WHERE tgname = '_break_audit_trg';")
if [ "${TRG}" != "1" ]; then
    fail "trigger installation failed (got ${TRG})"
fi

# Prepare eviction workload — per-row INSERTs, same pattern as the
# honest test.
EVICT_SQL_FILE="${DATADIR}/evict_batch.sql"
: > "${EVICT_SQL_FILE}"
for i in $(seq 1 "${EVICTIONS_PER_TRIAL}"); do
    printf "INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence) VALUES (7, 'bp', 'v_%s', tstzrange('2026-01-01', 'infinity'), 'MEASURED'::epistemic.epistemic_kind, 0::int2, 1.0::real);\n" "${i}" >> "${EVICT_SQL_FILE}"
done

# ------------------------------------------------------------------
# 3. trials
# ------------------------------------------------------------------
VIOLATIONS=0
NO_EVICT=0
PARTIAL=0
COMPLETE=0

log "running ${TRIALS} trial(s), ${EVICTIONS_PER_TRIAL} evictions per trial, crash_delay_ms=${CRASH_DELAY_MS}"
printf '[crash_atomicity_broken.sh] %-6s %-6s %-6s %-6s %-6s %-8s %s\n' \
    trial live audit_shadow closed total audit_real verdict

for T in $(seq 1 "${TRIALS}"); do
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
TRUNCATE epistemic.evicted_fact RESTART IDENTITY;
TRUNCATE epistemic.evicted_fact_shadow;
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (7, 'bp', 'incumbent', ARRAY['s1'],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED', 10, 0.5);
CHECKPOINT;
SQL

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 -f "${EVICT_SQL_FILE}" \
        >/dev/null 2>&1 &
    EVICT_PID=$!

    perl -e "select undef,undef,undef, ${CRASH_DELAY_MS}/1000"
    "${PG_CTL}" -D "${DATADIR}" -m immediate -w -t 30 stop >/dev/null 2>&1 \
        || fail "trial ${T}: immediate stop failed"

    wait "${EVICT_PID}" 2>/dev/null || true

    if ! "${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 60 start >/dev/null; then
        fail "trial ${T}: postmaster failed to start after crash"
    fi
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q; then
            break
        fi
        sleep 1
        if [ "${i}" = "10" ]; then
            fail "trial ${T}: pg_isready never returned success post-recovery"
        fi
    done

    LIVE=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=7 AND attribute='bp' AND upper(sys_time) = 'infinity'::timestamptz;")
    CLOSED=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=7 AND attribute='bp' AND upper(sys_time) < 'infinity'::timestamptz;")
    TOTAL=$(( LIVE + CLOSED ))
    # Shadow (dblink-committed) audit rows — these are the ones that
    # break the invariant.
    AUDIT_SHADOW=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM epistemic.evicted_fact_shadow WHERE original_row->>'entity_id' = '7';")
    # Real (in-txn) audit rows for reference — these DO obey the invariant.
    AUDIT_REAL=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM epistemic.evicted_fact WHERE original_row->>'entity_id' = '7';")

    VERDICT="OK"
    # Same invariant as the honest test but audit = shadow (the
    # externally-committed audit trail).
    if [ "${LIVE}" != "1" ]; then
        VERDICT="VIOLATION_live=${LIVE}"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
    elif [ "$(( AUDIT_SHADOW + LIVE ))" != "${TOTAL}" ]; then
        VERDICT="VIOLATION_shadow!=closed(${AUDIT_SHADOW}!=${CLOSED})"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
    else
        if [ "${AUDIT_SHADOW}" = "0" ]; then
            NO_EVICT=$(( NO_EVICT + 1 ))
        elif [ "${AUDIT_SHADOW}" = "${EVICTIONS_PER_TRIAL}" ]; then
            COMPLETE=$(( COMPLETE + 1 ))
        else
            PARTIAL=$(( PARTIAL + 1 ))
        fi
    fi

    printf '[crash_atomicity_broken.sh] %-6s %-6s %-12s %-6s %-6s %-10s %s\n' \
        "${T}" "${LIVE}" "${AUDIT_SHADOW}" "${CLOSED}" "${TOTAL}" "${AUDIT_REAL}" "${VERDICT}"
done

log "----- summary -----"
log "trials: ${TRIALS}"
log "  no_evict_before_crash : ${NO_EVICT}"
log "  fully_matched         : ${COMPLETE}"
log "  partial_ok            : ${PARTIAL}"
log "  invariant_violations  : ${VIOLATIONS}"

if [ "${VIOLATIONS}" -gt 0 ]; then
    log "EXPECTED-FAIL (this is the adversarial control):"
    log "  ${VIOLATIONS}/${TRIALS} trial(s) show audit_shadow > closed."
    log "  The shadow audit row committed on a separate backend (dblink)"
    log "  and survived the crash, but the main-txn winner + close_sys_time"
    log "  changes were rolled back by redo. This is what atomicity buys us,"
    log "  and this is what breaks when the audit is off-txn."
    trap - EXIT
    cleanup
    exit 0
fi

log "UNEXPECTED: the break did not produce any invariant violation."
log "The most likely cause is that every trial's crash either landed"
log "before ANY evictions fired, or after the whole workload finished."
log "Retune CRASH_DELAY_MS to catch the mid-batch state."
trap - EXIT
cleanup
exit 1
