#!/usr/bin/env bash
#
# scripts/deadlock_detection.sh — F6 deadlock story.
#
# The F6 per-slot advisory xact lock in epistemic_tuple_insert_impl is
# taken per row inside the AM's tuple_insert callback. Two multi-row
# INSERT statements that target the same two slots in OPPOSITE orders
# can deadlock on the advisory locks:
#
#   session1: INSERT ... VALUES (slot X), (slot Y) — grabs lock(X), then Y
#   session2: INSERT ... VALUES (slot Y), (slot X) — grabs lock(Y), then X
#
# The chosen mitigation is (b) accept the deadlock possibility and rely
# on PG's built-in deadlock detector at src/backend/storage/lmgr/deadlock.c
# (DeadLockCheck, called from lock manager after deadlock_timeout). The
# guarantee this test asserts is:
#
#   1. NEVER hang (deadlock resolves within deadlock_timeout=1s + wall
#      clock slack).
#   2. Either both commit (races that don't actually interleave), or
#      exactly one session gets aborted with SQLSTATE 40P01 (deadlock
#      detected) OR 40001 (serialization failure — SSI path).
#
# The alternative — override multi_insert to sort rows by
# (entity_id, hash_bytes(attribute)) before per-row lock acquisition —
# would help only bulk paths (COPY, prepared multi-row INSERTs sharing
# a BulkInsertState). It does not eliminate the deadlock for
# statement-level races where each session inserts one row per
# statement in a different order. So (b) is the honest choice; the
# deadlock detector is PG's, not ours.
#
# Bash 3.2 compatible.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55494}"
DATADIR="${DATADIR:-/tmp/kndb_e_dl_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

TRIALS="${TRIALS:-20}"

log()  { printf '[deadlock_detection.sh] %s\n' "$*"; }
fail() { printf '[deadlock_detection.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${DL_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[deadlock_detection.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[deadlock_detection.sh] --- last 30 lines of server.log ---\n' >&2
            tail -n 30 "${LOG}" >&2 || true
        fi
    fi
    exit "${rc}"
}
trap on_error EXIT

# ------------------------------------------------------------------
# 1. fresh cluster with a tight deadlock_timeout so the test terminates
#    quickly
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
log_min_messages = warning
log_line_prefix = '%m [%p] '
deadlock_timeout = 1s
max_pred_locks_per_transaction = 128
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

# ------------------------------------------------------------------
# 2. schema
# ------------------------------------------------------------------
log "installing extension and fact table"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

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

WORKDIR="${DATADIR}/work"
mkdir -p "${WORKDIR}"

# ------------------------------------------------------------------
# 3. one deadlock race.
#
# Sessions use txn-wide holds via an initial INSERT + short sleep so
# lock(X) is held by session1 while session2 tries to acquire lock(Y),
# then session2 tries lock(X) (held) and session1 tries lock(Y) (held).
# Deadlock detector aborts one with 40P01.
# ------------------------------------------------------------------
run_deadlock() {
    local out1="${WORKDIR}/dl.s1.log"
    local out2="${WORKDIR}/dl.s2.log"
    local hard_deadline=$((SECONDS + 15))

    # Session1: hold X first via a single-row INSERT, then INSERT Y.
    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out1}" 2>&1 &
BEGIN;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (11, 'bpX', 's1x', tstzrange('2026-01-01', 'infinity'),
        'MEASURED', 5::int2, 0.8::real);
SELECT pg_sleep(0.5);
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (22, 'bpY', 's1y', tstzrange('2026-01-01', 'infinity'),
        'MEASURED', 5::int2, 0.8::real);
COMMIT;
SQL
    local pid1=$!

    # Session2: hold Y first, then INSERT X.
    perl -e 'select undef,undef,undef, 0.10'

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out2}" 2>&1 &
BEGIN;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (22, 'bpY', 's2y', tstzrange('2026-01-01', 'infinity'),
        'MEASURED', 5::int2, 0.8::real);
SELECT pg_sleep(0.5);
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (11, 'bpX', 's2x', tstzrange('2026-01-01', 'infinity'),
        'MEASURED', 5::int2, 0.8::real);
COMMIT;
SQL
    local pid2=$!

    # Wait with a hard wall-clock cap so a hang shows up as failure.
    while kill -0 "${pid1}" 2>/dev/null || kill -0 "${pid2}" 2>/dev/null; do
        if [ "${SECONDS}" -gt "${hard_deadline}" ]; then
            log "HANG DETECTED: killing both sessions"
            kill -9 "${pid1}" 2>/dev/null || true
            kill -9 "${pid2}" 2>/dev/null || true
            echo "hang=1" > "${WORKDIR}/dl.verdict"
            return 1
        fi
        sleep 0.5
    done
    wait "${pid1}" 2>/dev/null || true
    wait "${pid2}" 2>/dev/null || true

    local s1_dl s2_dl s1_ser s2_ser
    s1_dl=$(grep -c -E '40P01|deadlock detected' "${out1}" || true)
    s2_dl=$(grep -c -E '40P01|deadlock detected' "${out2}" || true)
    s1_ser=$(grep -c -E '40001|could not serialize' "${out1}" || true)
    s2_ser=$(grep -c -E '40001|could not serialize' "${out2}" || true)

    echo "s1_dl=${s1_dl} s2_dl=${s2_dl} s1_ser=${s1_ser} s2_ser=${s2_ser}"
}

# ------------------------------------------------------------------
# 4. loop
# ------------------------------------------------------------------
deadlock_resolved=0
both_committed=0
one_aborted=0
hang=0

log "=== deadlock races, N=${TRIALS}, deadlock_timeout=1s ==="
for T in $(seq 1 "${TRIALS}"); do
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
SQL

    if ! line=$(run_deadlock); then
        hang=1
        log "trial=${T} HANG"
        break
    fi

    s1_dl=$(printf '%s' "${line}" | sed -E "s/.*s1_dl=([0-9]+).*/\1/")
    s2_dl=$(printf '%s' "${line}" | sed -E "s/.*s2_dl=([0-9]+).*/\1/")
    s1_ser=$(printf '%s' "${line}" | sed -E "s/.*s1_ser=([0-9]+).*/\1/")
    s2_ser=$(printf '%s' "${line}" | sed -E "s/.*s2_ser=([0-9]+).*/\1/")

    aborted=$(( s1_dl + s2_dl + s1_ser + s2_ser ))

    if [ "${aborted}" -eq 0 ]; then
        both_committed=$(( both_committed + 1 ))
        printf '[deadlock_detection.sh] trial=%-3s both committed (no interleave)\n' "${T}"
    elif [ "${aborted}" -eq 1 ]; then
        one_aborted=$(( one_aborted + 1 ))
        deadlock_resolved=$(( deadlock_resolved + 1 ))
        if [ "${s1_dl}" -eq 1 ] || [ "${s2_dl}" -eq 1 ]; then
            reason="40P01_deadlock"
        else
            reason="40001_serialization"
        fi
        printf '[deadlock_detection.sh] trial=%-3s one_aborted reason=%s (s1_dl=%s s2_dl=%s s1_ser=%s s2_ser=%s)\n' \
            "${T}" "${reason}" "${s1_dl}" "${s2_dl}" "${s1_ser}" "${s2_ser}"
    else
        printf '[deadlock_detection.sh] trial=%-3s ANOMALY: aborted=%s (s1_dl=%s s2_dl=%s s1_ser=%s s2_ser=%s)\n' \
            "${T}" "${aborted}" "${s1_dl}" "${s2_dl}" "${s1_ser}" "${s2_ser}"
    fi
done

log "----- summary -----"
log "  trials             : ${TRIALS}"
log "  deadlock_resolved  : ${deadlock_resolved}"
log "  one_aborted        : ${one_aborted}"
log "  both_committed     : ${both_committed}"
log "  hang               : ${hang}"

if [ "${hang}" -ne 0 ]; then
    fail "at least one trial hung past deadlock_timeout + slack"
fi
if [ $(( one_aborted + both_committed )) -ne "${TRIALS}" ]; then
    fail "not all trials accounted for: one_aborted=${one_aborted} both_committed=${both_committed} trials=${TRIALS}"
fi

log "PASS: PG's deadlock detector resolves every advisory-lock deadlock"
log "      within deadlock_timeout; no trial hung."
trap - EXIT
cleanup
exit 0
