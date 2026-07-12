#!/usr/bin/env bash
#
# scripts/crash_atomicity.sh — eviction atomicity crash test.
#
# Purpose. When the AM evicts an incumbent, three state changes happen:
#   (a) heap_insert of the winner
#   (b) SPI INSERT into epistemic.evicted_fact  (the audit row)
#   (c) simple_heap_update of the incumbent's sys_time upper bound
# All three run inside `epistemic_tuple_insert_impl`, which itself
# executes inside the per-statement transaction that PG's
# exec_simple_query wraps around every top-level statement
# (src/backend/tcop/postgres.c:1046,1349 REL_18_STABLE calls
# start_xact_command()/finish_xact_command() around every parsetree loop,
# and start_xact_command at postgres.c:2787-2794 issues
# StartTransactionCommand(), whose default-block arm at xact.c:3069-3072
# calls StartTransaction()). So the three changes are one atomic PG
# transaction, and this test asks: does an unclean shutdown mid-flight
# ever leave the invariant broken after recovery?
#
# Invariant (per (entity_id, attribute) that has ever been touched):
#   * live_count == 1  (exactly one row with upper(sys_time) = 'infinity')
#   * live_count + closed_count == total_count
#   * audit_count == number of eviction commits that landed
# A violation is: live=0, live>=2, or (audit=k but live+closed != k+1
# for k >= 1). We instrument for `live` and `audit` only, since the
# incumbent+closed constraint is a consequence.
#
# Design. Fresh isolated cluster on port 55493. Preload epistemic,
# fsync=on, wal_consistency_checking=all, synchronous_commit=on. Do N
# trials. Each trial:
#   1. TRUNCATE fact, TRUNCATE epistemic.evicted_fact.
#   2. Insert one INFERRED incumbent for (entity=7, attribute='bp'),
#      with a registered source.
#   3. CHECKPOINT so the incumbent is durable on disk.
#   4. Background psql fires N_EVICT INSERTs, each a MEASURED row for
#      the same (entity=7, attribute='bp') — each one supersedes the
#      previous winner. This gives us a long chain of eviction
#      transactions to race the crash against.
#   5. In the foreground, sleep briefly and then `pg_ctl stop -m
#      immediate` to crash the postmaster.
#   6. Restart, wait for recovery, count `live`, `audit`, `closed`.
# Assert `live == 1 AND (audit + 1) == (live + closed)` for every
# trial. Report the per-trial distribution.
#
# `pg_ctl stop -m immediate` sends SIGQUIT and skips the shutdown
# checkpoint (src/backend/access/transam/xlog.c around StartupXLOG at
# xlog.c:5467; recovery re-enters via "database system was not properly
# shut down" at xlog.c:5545 and redo replays every WAL record from the
# last checkpoint forward). Any in-flight transaction whose COMMIT
# record was not yet flushed to disk is discarded at redo end — PG 18
# with synchronous_commit=on flushes the WAL through XLogFlush
# (xlog.c:2780-2801) before the commit returns to the client, so a
# committed statement's three heap changes are all durable together.
#
# Bash 3.2 compatible (macOS default). No GNU-only flags.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55493}"
DATADIR="${DATADIR:-/tmp/kndb_e_crash_$$}"
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

log()  { printf '[crash_atomicity.sh] %s\n' "$*"; }
fail() { printf '[crash_atomicity.sh] FAIL: %s\n' "$*" >&2; exit 1; }

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
        printf '[crash_atomicity.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[crash_atomicity.sh] --- last 40 lines of server.log ---\n' >&2
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
wal_consistency_checking = 'all'
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
# 2. schema
# ------------------------------------------------------------------
log "installing extension and schema"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

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
SQL

# Prepare an eviction workload as ${EVICTIONS_PER_TRIAL} separate
# top-level INSERTs, each one a self-contained per-statement
# transaction. Each successive row evicts the current live winner. The
# background psql session pipes them one at a time so that a crash
# lands between two of them, catching the AM at every possible mid-
# chain state.
#
# Why not one INSERT ... SELECT with generate_series(): the AM's audit
# SPI probes the incumbent via WHERE ctid = $3 using SPI's snapshot,
# which lags the current statement's in-flight modifications; a
# SET-based multi-row eviction chain would abort at the second row
# with "expected 1 row inserted, got 0". That's a known scope
# limitation of the current AM (per-row STMT vs SET-based STMT) and
# not what this test is checking.
EVICT_SQL_FILE="${DATADIR}/evict_batch.sql"
: > "${EVICT_SQL_FILE}"
for i in $(seq 1 "${EVICTIONS_PER_TRIAL}"); do
    printf "INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence) VALUES (7, 'bp', 'v_%s', tstzrange('2026-01-01', 'infinity'), 'MEASURED'::epistemic.epistemic_kind, 0::int2, 1.0::real);\n" "${i}" >> "${EVICT_SQL_FILE}"
done

# ------------------------------------------------------------------
# 3. trials
# ------------------------------------------------------------------
VIOLATIONS=0
NO_EVICT=0        # trial where the crash beat the batch and nothing changed
PARTIAL=0         # trial where audit >= 1 (at least one eviction committed)
COMPLETE=0        # trial where the full batch committed (${EVICTIONS_PER_TRIAL} audits)

log "running ${TRIALS} trial(s), ${EVICTIONS_PER_TRIAL} evictions per trial, crash_delay_ms=${CRASH_DELAY_MS}"
printf '[crash_atomicity.sh] %-6s %-6s %-6s %-6s %-6s %s\n' \
    trial live audit closed total verdict

for T in $(seq 1 "${TRIALS}"); do
    # (a) reset state
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
TRUNCATE epistemic.evicted_fact RESTART IDENTITY;
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (7, 'bp', 'incumbent', ARRAY['s1'],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED', 10, 0.5);
CHECKPOINT;
SQL

    INCUMBENT_LIVE=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=7 AND attribute='bp' AND upper(sys_time) = 'infinity'::timestamptz;")
    if [ "${INCUMBENT_LIVE}" != "1" ]; then
        fail "trial ${T}: incumbent setup wrong: live=${INCUMBENT_LIVE}"
    fi

    # (b) fire the eviction batch in the background
    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 -f "${EVICT_SQL_FILE}" \
        >/dev/null 2>&1 &
    EVICT_PID=$!

    # (c) race the crash. CRASH_DELAY_MS is short enough that some
    # trials will catch the batch mid-execution (rollback) and some
    # will catch it just after commit (full landing).
    #
    # `perl -e "select undef,undef,undef, ${CRASH_DELAY_MS}/1000"` gives
    # sub-second sleep without GNU sleep.
    perl -e "select undef,undef,undef, ${CRASH_DELAY_MS}/1000"
    "${PG_CTL}" -D "${DATADIR}" -m immediate -w -t 30 stop >/dev/null 2>&1 \
        || fail "trial ${T}: immediate stop failed"

    wait "${EVICT_PID}" 2>/dev/null || true

    # (d) restart, wait for recovery
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

    # (e) count the state
    LIVE=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=7 AND attribute='bp' AND upper(sys_time) = 'infinity'::timestamptz;")
    CLOSED=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=7 AND attribute='bp' AND upper(sys_time) < 'infinity'::timestamptz;")
    TOTAL=$(( LIVE + CLOSED ))
    AUDIT=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM epistemic.evicted_fact WHERE original_row->>'entity_id' = '7';")

    VERDICT="OK"
    if [ "${LIVE}" != "1" ]; then
        VERDICT="VIOLATION_live=${LIVE}"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
    elif [ "$(( AUDIT + LIVE ))" != "${TOTAL}" ]; then
        # audit + 1(live winner) must equal total(live + closed).
        # Equivalently audit == closed.
        VERDICT="VIOLATION_audit!=closed(${AUDIT}!=${CLOSED})"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
    else
        if [ "${AUDIT}" = "0" ]; then
            NO_EVICT=$(( NO_EVICT + 1 ))
        elif [ "${AUDIT}" = "${EVICTIONS_PER_TRIAL}" ]; then
            COMPLETE=$(( COMPLETE + 1 ))
        else
            PARTIAL=$(( PARTIAL + 1 ))
        fi
    fi

    printf '[crash_atomicity.sh] %-6s %-6s %-6s %-6s %-6s %s\n' \
        "${T}" "${LIVE}" "${AUDIT}" "${CLOSED}" "${TOTAL}" "${VERDICT}"
done

# ------------------------------------------------------------------
# 4. summary + assertion
# ------------------------------------------------------------------
log "----- summary -----"
log "trials: ${TRIALS}"
log "  no_evict_before_crash : ${NO_EVICT}"
log "  partial_batch_landed  : ${PARTIAL}"
log "  complete_batch_landed : ${COMPLETE}"
log "  invariant_violations  : ${VIOLATIONS}"

# Scan the log for the redo signatures. wal_consistency_checking=all
# would surface a rmgr mismatch as PANIC or "inconsistent page". Note:
# "invalid magic number 0000" at the tail of a WAL segment is benign —
# it is the normal end-of-WAL indicator during redo after an immediate
# stop; PG treats it as end-of-log, not corruption. So we exclude that
# exact form from the search.
BAD_PATTERN='PANIC|inconsistent page|WAL contains references to invalid pages|incorrect resource manager data|record with incorrect prev-link'
BAD=$(grep -c -E "${BAD_PATTERN}" "${LOG}" || true)
if [ "${BAD}" != "0" ]; then
    log "server.log has ${BAD} PANIC/inconsistent-page lines"
    grep -n -E "${BAD_PATTERN}" "${LOG}" >&2 || true
    fail "recovery flagged inconsistent replay"
fi

if [ "${VIOLATIONS}" -eq 0 ]; then
    log "PASS: 0 invariant violations across ${TRIALS} trial(s)."
    log "      (atomicity provided by PG's per-statement transaction wrap;"
    log "       see start_xact_command / finish_xact_command in"
    log "       src/backend/tcop/postgres.c:2787-2794,2825-2848 REL_18_STABLE)"
    trap - EXIT
    cleanup
    exit 0
fi

log "FAIL: ${VIOLATIONS} trial(s) violated the eviction invariant."
trap - EXIT
cleanup
exit 1
