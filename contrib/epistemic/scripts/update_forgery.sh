#!/usr/bin/env bash
#
# scripts/update_forgery.sh — F20 attack reproduction (UPDATE bypass).
#
# The paper's §2.3 enumeration and Table 6 both claim the AM callback
# defeats every write path a writer with INSERT + ALTER TABLE can reach.
# The enumeration missed UPDATE. Before F20, epistemic_am_methods
# inherited heapam's tuple_update callback verbatim, so:
#
#   INSERT (kind=INFERRED, confidence=0.4)  -> R1..R5 pass, row lands
#   UPDATE SET kind='MEASURED', confidence=1.0, value='forged'
#                                           -> heap_update (no epistemic hook)
#                                           -> the forged row is now live
#
# The AM's R1..R5 never fire on the update path; the precedence lattice
# never runs; no eviction audit row is written. The forger has swapped
# the epistemic prefix on a committed row without the engine noticing.
#
# This script reproduces the attack against a fresh cluster and writes
# a verbatim transcript to /tmp/update_forgery_reproduced_$$.log. It is
# expected to print "FORGERY SUCCEEDED" before F20 and "FORGERY REJECTED"
# after F20 with a message quoting the F20 CHECK_VIOLATION.
#
# Companion of scripts/delete_forgery.sh.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55494}"
DATADIR="${DATADIR:-/tmp/kndb_e_updforge_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"
TRANSCRIPT="/tmp/update_forgery_reproduced_$$.log"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[update_forgery.sh] %s\n' "$*"; }
fail() { printf '[update_forgery.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${UPDATE_FORGERY_KEEP:-0}" != "1" ]; then
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

# Redirect all further output to the transcript file (also to stdout).
exec > >(tee -a "${TRANSCRIPT}") 2>&1

echo "=================================================================="
echo "F20 UPDATE forgery reproduction"
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
echo "--- Step 2: INSERT a legitimate INFERRED row (kind=INFERRED, conf=0.4) ---"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'bp', 'benign', ARRAY['s1'],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.4::real);
SQL

echo
echo "--- verify: the INFERRED row is live ---"
"${PSQL}" ${PSQL_CONN} <<'SQL'
SELECT entity_id, attribute, value, ep_kind, ep_confidence
  FROM fact_native
 WHERE entity_id = 42 AND attribute = 'bp';
SQL

echo
echo "--- Step 3: THE ATTACK. UPDATE that row to forge MEASURED with conf=1.0 ---"
echo "    UPDATE fact_native SET ep_kind='MEASURED',"
echo "                           ep_confidence=1.0,"
echo "                           value='forged'"
echo "     WHERE entity_id=42 AND attribute='bp';"
echo
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL'
UPDATE fact_native
   SET ep_kind = 'MEASURED'::epistemic.epistemic_kind,
       ep_confidence = 1.0::real,
       value = 'forged'
 WHERE entity_id = 42 AND attribute = 'bp';
SQL
UPDATE_RC=$?
set -e
echo "    (psql exit code: ${UPDATE_RC})"

echo
echo "--- verify: what is now live? ---"
LIVE=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT ep_kind::text || '|' || ep_confidence::text || '|' || value FROM fact_native WHERE entity_id = 42 AND attribute = 'bp';")
echo "    live row: ${LIVE}"
echo

FORGERY_OUTCOME=""
if echo "${LIVE}" | grep -q '^MEASURED|1|forged$'; then
    echo "==>  FORGERY SUCCEEDED"
    echo "     UPDATE swapped INFERRED/0.4 -> MEASURED/1.0/forged."
    echo "     The AM callback never ran on the update path."
    echo "     This is the F20 bypass reproduction."
    FORGERY_OUTCOME="succeeded"
elif echo "${LIVE}" | grep -q '^INFERRED|0.4|benign$'; then
    echo "==>  FORGERY REJECTED"
    echo "     UPDATE was refused; the incumbent INFERRED/0.4/benign survives."
    echo "     Either the F20 fix is in place, or the attack did not trigger."
    FORGERY_OUTCOME="rejected"
else
    echo "==>  UNEXPECTED STATE: live row = '${LIVE}'"
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
# rebuild that intentionally weakens the AM (F20 disable pass).
EXPECT="${F20_EXPECT_REJECTED:-1}"
if [ "${EXPECT}" = "1" ] && [ "${FORGERY_OUTCOME}" != "rejected" ]; then
    echo "[update_forgery.sh] FAIL: expected FORGERY REJECTED, got ${FORGERY_OUTCOME}"
    exit 1
fi
if [ "${EXPECT}" = "0" ] && [ "${FORGERY_OUTCOME}" != "succeeded" ]; then
    echo "[update_forgery.sh] FAIL: expected FORGERY SUCCEEDED (disable pass), got ${FORGERY_OUTCOME}"
    exit 1
fi
exit 0
