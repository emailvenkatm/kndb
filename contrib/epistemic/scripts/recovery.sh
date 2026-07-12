#!/usr/bin/env bash
#
# scripts/recovery.sh — Metric 1 validation.
#
# Spins a fresh, isolated PG18 cluster with the epistemic extension
# preloaded and `wal_consistency_checking = all`, inserts 100 MEASURED
# rows through the native AM, kills the postmaster with -m immediate to
# force WAL replay on restart, and asserts:
#   (a) recovery completes (postmaster comes back up),
#   (b) no PANIC / FATAL / "inconsistent" strings appear in the log,
#   (c) SELECT count(*) FROM fact returns exactly 100.
#
# If wal_consistency_checking is doing its job, any mismatch between the
# rmgr's rm_mask output and the replayed page will surface as
# FATAL: inconsistent pages during WAL replay in the log — that is the
# failure mode this test is designed to catch.
#
# Bash 3.2 compatible (macOS default). No GNU-only flags.

set -euo pipefail

# ------------------------- config -----------------------------------

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55490}"
DATADIR="${DATADIR:-/tmp/kndb_e_recovery_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

# ------------------------- helpers ----------------------------------

log()  { printf '[recovery.sh] %s\n' "$*"; }
fail() { printf '[recovery.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        # keep the log on failure; nuke on success
        if [ "${RECOVERY_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}

# We install a trap only for unexpected exits. On explicit fail we still
# want the datadir to persist for post-mortem.
on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[recovery.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[recovery.sh] --- last 30 lines of server.log ---\n' >&2
            tail -n 30 "${LOG}" >&2 || true
        fi
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

# Pin config: preload epistemic, enable consistency checking, keep fsync
# on so the crash actually loses only what wasn't flushed.
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
log_error_verbosity = default
log_line_prefix = '%m [%p] '
CONF

log "starting postmaster"
"${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 30 start >/dev/null \
    || fail "postmaster failed to start (pre-crash)"

# Wait until accepting connections.
for i in 1 2 3 4 5 6 7 8 9 10; do
    if "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q; then
        break
    fi
    sleep 1
    if [ "${i}" = "10" ]; then
        fail "pg_isready never returned success"
    fi
done

# ------------------------- 2. schema + data -------------------------

log "creating extension and fact table"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

CREATE TABLE fact (
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
SQL

log "confirming rmgr is registered"
RMGR_NAME=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT rm_name FROM pg_get_wal_resource_managers() WHERE rm_id = 128;")
if [ "${RMGR_NAME}" != "epistemic" ]; then
    fail "expected rm_id=128 to be 'epistemic', got: '${RMGR_NAME}'"
fi

log "inserting 100 non-overlapping MEASURED rows"
# Non-overlapping to keep the AM out of the precedence / eviction path.
# Each (entity_id, attribute) is unique, so no live-overlap lookup fires.
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
SELECT
    i,
    'attr_' || i,
    'v_' || i,
    tstzrange(timestamptz '2026-01-01' + (i || ' days')::interval,
              timestamptz '2026-01-01' + ((i + 1) || ' days')::interval),
    'MEASURED'::epistemic.epistemic_kind,
    (i % 100)::int2,
    1.0::real
FROM generate_series(1, 100) AS s(i);
SQL

# Confirm the AM accepted all 100.
INSERTED=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM fact;")
if [ "${INSERTED}" != "100" ]; then
    fail "pre-crash row count wrong: expected 100, got ${INSERTED}"
fi

log "forcing WAL flush and reading LSN"
"${PSQL}" ${PSQL_CONN} -Atc "CHECKPOINT; SELECT pg_current_wal_lsn();" >/dev/null

# We want to make sure the committed inserts are durable enough to be
# replayed on restart. The checkpoint above ensures the pages hit disk;
# additional WAL activity after the checkpoint will exercise the redo path.
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
-- A few more inserts AFTER the checkpoint so recovery actually replays
-- some records rather than starting from a clean shutdown checkpoint.
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
SELECT
    i,
    'post_ckpt_' || i,
    'v_post_' || i,
    tstzrange(timestamptz '2027-01-01' + (i || ' days')::interval,
              timestamptz '2027-01-01' + ((i + 1) || ' days')::interval),
    'MEASURED'::epistemic.epistemic_kind,
    (i % 100)::int2,
    1.0::real
FROM generate_series(1, 10) AS s(i);
SQL

PRE_CRASH_LSN=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT pg_current_wal_lsn();")
PRE_CRASH_COUNT=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM fact;")
log "pre-crash lsn=${PRE_CRASH_LSN} count=${PRE_CRASH_COUNT}"
if [ "${PRE_CRASH_COUNT}" != "110" ]; then
    fail "pre-crash post-checkpoint row count wrong: expected 110, got ${PRE_CRASH_COUNT}"
fi

# ------------------------- 3. immediate stop ------------------------

log "simulating crash: pg_ctl stop -m immediate"
"${PG_CTL}" -D "${DATADIR}" -m immediate -w -t 30 stop >/dev/null \
    || fail "immediate stop failed"

# ------------------------- 4. restart + replay ---------------------

# Mark the log so we can grep just the redo section.
REDO_MARKER="$(date +%s)-redo-marker"
printf '\n--- %s ---\n' "${REDO_MARKER}" >> "${LOG}"

log "restarting postmaster (WAL replay under wal_consistency_checking=all)"
if ! "${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 60 start >/dev/null; then
    fail "postmaster failed to start after crash (recovery did not complete)"
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
    if "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q; then
        break
    fi
    sleep 1
    if [ "${i}" = "10" ]; then
        fail "pg_isready never returned success post-recovery"
    fi
done

# ------------------------- 5. assertions ---------------------------

POST_COUNT=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM fact;")
log "post-recovery row count=${POST_COUNT}"
if [ "${POST_COUNT}" != "110" ]; then
    fail "post-recovery row count wrong: expected 110, got ${POST_COUNT}"
fi

# Check that the rmgr is *still* registered after restart.
RMGR_NAME_POST=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT rm_name FROM pg_get_wal_resource_managers() WHERE rm_id = 128;")
if [ "${RMGR_NAME_POST}" != "epistemic" ]; then
    fail "rm_id=128 no longer 'epistemic' after recovery: '${RMGR_NAME_POST}'"
fi

# Scan the log for the failure signatures. wal_consistency_checking=all
# reports mismatches via PANIC or "inconsistent page" messages.
#
# We deliberately exclude the "database ... does not exist" FATAL that
# pg_isready produces when it tries to authenticate to a non-existent
# default database (that comes from our own probing, not from replay).
BAD_PATTERN='PANIC|inconsistent page|WAL contains references to invalid pages|incorrect resource manager data|record with incorrect prev-link|invalid magic number|invalid contrecord'
BAD=$(grep -c -E "${BAD_PATTERN}" "${LOG}" || true)
if [ "${BAD}" != "0" ]; then
    log "grep hits for PANIC/inconsistent in server.log:"
    grep -n -E "${BAD_PATTERN}" "${LOG}" >&2 || true
    fail "server.log has ${BAD} PANIC/inconsistent-page lines"
fi

# Additionally, look for FATALs that are NOT the benign pg_isready
# probe (which errors with 'database "…" does not exist'). Under
# `pipefail`, an inner `grep -v` that matches everything exits 1; guard
# with `|| true` and count via a two-step form.
FATAL_ALL=$(grep -c 'FATAL' "${LOG}" || true)
FATAL_BENIGN=$(grep 'FATAL' "${LOG}" | { grep -c 'database ".*" does not exist' || true; })
FATAL_BAD=$(( FATAL_ALL - FATAL_BENIGN ))
if [ "${FATAL_BAD}" -ne 0 ]; then
    log "unexpected FATAL lines in server.log:"
    grep -n 'FATAL' "${LOG}" | grep -v 'database ".*" does not exist' >&2 || true
    fail "server.log has ${FATAL_BAD} non-probe FATAL lines"
fi

# The redo section should have actually run (i.e. crash recovery
# happened, not a clean shutdown). Look for the standard message.
if ! grep -q -E 'database system was not properly shut down|redo starts at|starting archive recovery|entering standby mode' "${LOG}"; then
    log "WARNING: no explicit 'redo starts at' line found; recovery may have been trivial."
fi

log "PASS: recovery round-tripped ${POST_COUNT} rows with wal_consistency_checking=all"

# ------------------------- 6. teardown -----------------------------

# Print the last 20 lines of the server log for the caller.
printf '\n[recovery.sh] --- last 20 lines of server.log ---\n'
tail -n 20 "${LOG}" || true

# Success — allow cleanup.
trap - EXIT
cleanup
exit 0
