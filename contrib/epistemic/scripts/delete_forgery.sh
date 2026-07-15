#!/usr/bin/env bash
#
# scripts/delete_forgery.sh — F20 attack reproduction (DELETE bypass).
#
# Companion of scripts/update_forgery.sh. Before F20, the AM did not
# override tuple_delete, so heap_delete ran unchecked. The attack:
#
#   INSERT (kind=MEASURED, sources=empty, conf=1.0)  -> honest row lands
#   DELETE FROM fact_native WHERE entity_id=...      -> heap_delete
#   INSERT (kind=INFERRED, conf=0.99)                -> no incumbent
#                                                       -> forgery is live
#
# The MEASURED incumbent that the precedence lattice would have used to
# reject the INFERRED forgery has been silently removed. The forger's
# INFERRED row lands unopposed. No eviction audit row is written.
#
# Writes the transcript to /tmp/delete_forgery_reproduced_$$.log.
# Expected: "FORGERY SUCCEEDED" before F20, "FORGERY REJECTED" after.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55495}"
DATADIR="${DATADIR:-/tmp/kndb_e_delforge_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"
TRANSCRIPT="/tmp/delete_forgery_reproduced_$$.log"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[delete_forgery.sh] %s\n' "$*"; }
fail() { printf '[delete_forgery.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${DELETE_FORGERY_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}
trap cleanup EXIT

log "creating fresh cluster at ${DATADIR}"
log "transcript at ${TRANSCRIPT}"
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
CONF

log "starting postmaster"
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

exec > >(tee -a "${TRANSCRIPT}") 2>&1

echo "=================================================================="
echo "F20 DELETE forgery reproduction"
echo "=================================================================="
echo

echo "--- Step 1: create extension, register source, create fact_native ---"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION epistemic;
INSERT INTO epistemic.source_registry (source_id, source_type)
    VALUES ('s1', 'llm-inference');

CREATE TABLE fact_native (
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

echo
echo "--- Step 2: INSERT honest MEASURED incumbent ---"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (99, 'diagnosis', 'sepsis', NULL,
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real);
SQL

echo
echo "--- verify: honest MEASURED row is live ---"
"${PSQL}" ${PSQL_CONN} <<'SQL'
SELECT entity_id, attribute, value, ep_kind, ep_confidence
  FROM fact_native
 WHERE entity_id = 99 AND attribute = 'diagnosis';
SQL

echo
echo "--- Step 3a: THE ATTACK, part 1. DELETE the MEASURED incumbent ---"
echo "    DELETE FROM fact_native WHERE entity_id=99 AND attribute='diagnosis';"
echo
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL'
DELETE FROM fact_native WHERE entity_id = 99 AND attribute = 'diagnosis';
SQL
DELETE_RC=$?
set -e
echo "    (psql exit code: ${DELETE_RC})"

REMAINING_LIVE=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM fact_native WHERE entity_id=99 AND attribute='diagnosis';")
echo "    live rows after DELETE: ${REMAINING_LIVE}"

echo
echo "--- Step 3b: THE ATTACK, part 2. INSERT an INFERRED forgery ---"
echo "    (with no incumbent to compete against, this lands unopposed)"
echo
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL'
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (99, 'diagnosis', 'benign', ARRAY['s1'],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.99::real);
SQL
INSERT_RC=$?
set -e
echo "    (psql exit code: ${INSERT_RC})"

echo
echo "--- verify: what is now live? ---"
LIVE=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT ep_kind::text || '|' || ep_confidence::text || '|' || coalesce(value,'<null>') FROM fact_native WHERE entity_id = 99 AND attribute = 'diagnosis';")
echo "    live row: ${LIVE}"
echo

FORGERY_OUTCOME=""
if [ "${REMAINING_LIVE}" = "0" ] && echo "${LIVE}" | grep -q '^INFERRED|0.99|benign$'; then
    echo "==>  FORGERY SUCCEEDED"
    echo "     DELETE removed the MEASURED incumbent unchecked."
    echo "     A subsequent INFERRED 'benign' now stands in for the sepsis diagnosis."
    echo "     No eviction audit row was ever written for the MEASURED loss."
    echo "     This is the F20 DELETE bypass reproduction."
    FORGERY_OUTCOME="succeeded"
elif [ "${REMAINING_LIVE}" = "1" ]; then
    echo "==>  FORGERY REJECTED"
    echo "     DELETE was refused; the MEASURED incumbent survives."
    echo "     Either the F20 fix is in place, or the attack did not trigger."
    FORGERY_OUTCOME="rejected"
else
    echo "==>  UNEXPECTED STATE: remaining=${REMAINING_LIVE} live='${LIVE}'"
    FORGERY_OUTCOME="unexpected"
fi

echo
echo "--- Step 4: audit-row check (epistemic.evicted_fact) ---"
"${PSQL}" ${PSQL_CONN} <<'SQL'
SELECT count(*) AS eviction_audit_rows FROM epistemic.evicted_fact;
SELECT reason, original_kind FROM epistemic.evicted_fact LIMIT 5;
SQL

echo
echo "=================================================================="
echo "End of transcript. Cluster will be dropped."
echo "=================================================================="

# Exit non-zero when the F20 fix is expected to be in place but the
# attack landed. Set F20_EXPECT_REJECTED=0 for the disable-and-test
# rebuild that intentionally weakens the AM.
EXPECT="${F20_EXPECT_REJECTED:-1}"
if [ "${EXPECT}" = "1" ] && [ "${FORGERY_OUTCOME}" != "rejected" ]; then
    echo "[delete_forgery.sh] FAIL: expected FORGERY REJECTED, got ${FORGERY_OUTCOME}"
    exit 1
fi
if [ "${EXPECT}" = "0" ] && [ "${FORGERY_OUTCOME}" != "succeeded" ]; then
    echo "[delete_forgery.sh] FAIL: expected FORGERY SUCCEEDED (disable pass), got ${FORGERY_OUTCOME}"
    exit 1
fi
exit 0
