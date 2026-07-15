#!/usr/bin/env bash
#
# scripts/speculative_forgery.sh — F21 attack reproduction (INSERT ... ON CONFLICT bypass).
#
# The F20 audit closed the UPDATE / DELETE bypass (heapam_tuple_update /
# heapam_tuple_delete no longer inherited from heapam verbatim).  But
# INSERT ... ON CONFLICT does NOT go through the plain tuple_insert
# callback: it goes through the two-phase speculative-insertion protocol.
#
# PG 18 REL_18_STABLE, src/include/access/tableam.h:687-695 declares
# two separate callbacks:
#
#     void (*tuple_insert_speculative) (Relation rel,
#                                       TupleTableSlot *slot,
#                                       CommandId cid,
#                                       int options,
#                                       struct BulkInsertStateData *bistate,
#                                       uint32 specToken);
#     void (*tuple_complete_speculative) (Relation rel,
#                                          TupleTableSlot *slot,
#                                          uint32 specToken,
#                                          bool succeeded);
#
# ExecInsert (src/backend/executor/nodeModifyTable.c:1379-1439) routes
# ON CONFLICT inserts to table_tuple_insert_speculative + then
# table_tuple_complete_speculative (lines 1410 and 1414), NOT to
# table_tuple_insert (line 1439, the "no ON CONFLICT" branch).
#
# heapam_handler.c binds .tuple_insert_speculative = heapam_tuple_insert_speculative
# and .tuple_complete_speculative = heapam_tuple_complete_speculative
# (lines ~2163-2164 in the heapam_methods block near line 2161).
#
# Our epistemic_am_methods block (contrib/epistemic/src/epistemic_am.c:1035-1046)
# overrides tuple_insert, multi_insert, tuple_update, tuple_delete,
# relation_toast_am.  It inherits tuple_insert_speculative and
# tuple_complete_speculative verbatim from heapam.  So an
# INSERT ... ON CONFLICT DO UPDATE (or DO NOTHING) is expected to
# bypass R1..R5, the advisory precedence lock, and the eviction-audit
# row, exactly the same class of bug as F18 (COPY -> heap_multi_insert)
# and F20 (UPDATE/DELETE -> heap_update/heap_delete).
#
# This script reproduces the attack against a fresh cluster and writes
# a verbatim transcript to /tmp/speculative_forgery_reproduced_$$.log.
# It exits 0 whether the forgery landed or was rejected -- this is a
# pre-fix reproduction, its job is to record ground truth. A Step-2
# script (post-fix) can wrap it with an EXPECT_REJECTED gate.
#
# Companion of scripts/update_forgery.sh and scripts/delete_forgery.sh.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55495}"
DATADIR="${DATADIR:-/tmp/kndb_e_specforge_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"
TRANSCRIPT="/tmp/speculative_forgery_reproduced_$$.log"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[speculative_forgery.sh] %s\n' "$*"; }
fail() { printf '[speculative_forgery.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${SPECULATIVE_FORGERY_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}
trap cleanup EXIT

# --- dylib guard (F15b rule: verify before every reproduction run) -----------
log "verifying epistemic.dylib hash"
if ! bash "$(dirname "$0")/verify_dylib.sh"; then
    fail "verify_dylib.sh failed -- rebuild + install before running this script"
fi

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
echo "F21 INSERT ... ON CONFLICT (speculative) forgery reproduction"
echo "=================================================================="
echo

echo "--- Step 1: create extension, register source, create fact_native ---"
echo "    Note: we add a UNIQUE constraint on (entity_id, attribute) so"
echo "    ON CONFLICT has an arbiter to bind. Unique constraints on"
echo "    epistemic tables are a real deployment pattern: users want a"
echo "    single canonical row per (entity, attribute) key and expect"
echo "    UPSERT semantics for periodic re-ingestion."
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION epistemic;
INSERT INTO epistemic.source_registry (source_id, source_type)
    VALUES ('s1', 'llm-inference');
-- Note: MEASURED rows must have empty sources (R3), so no s0 registered.

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

-- Real deployment pattern: unique key so upsert has an arbiter.
-- NOTE: this is expected to FAIL under the current epistemic AM with
--   ERROR: only heap AM is supported
-- because heap_getnext (heapam.c:1352 REL_18_STABLE) checks
-- rd_tableam identity and refuses non-heap AMs, so btree's ambuild
-- scan phase cannot run. We keep the CREATE UNIQUE INDEX here to
-- prove the failure mode.
SQL

echo
echo "--- Attempt CREATE UNIQUE INDEX (expected to fail on epistemic AM) ---"
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL' 2>&1
CREATE UNIQUE INDEX fact_native_key ON fact_native (entity_id, attribute);
SQL
INDEX_RC=$?
set -e
echo "    (psql exit code: ${INDEX_RC})"

# Whether the index exists determines whether ON CONFLICT has an arbiter.
HAS_INDEX=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT count(*) FROM pg_indexes WHERE tablename='fact_native' AND indexname='fact_native_key';")
echo "    fact_native_key present after CREATE attempt: ${HAS_INDEX}"

echo
echo "--- Step 2: INSERT a legitimate MEASURED incumbent (kind=MEASURED, conf=1.0) ---"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'bp', 'measured-120/80', NULL,
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real);
SQL

echo
echo "--- verify: the MEASURED incumbent is live ---"
"${PSQL}" ${PSQL_CONN} <<'SQL'
SELECT entity_id, attribute, value, ep_kind, ep_confidence
  FROM fact_native
 WHERE entity_id = 42 AND attribute = 'bp';
SQL

echo
echo "=================================================================="
echo "--- Step 3a: THE ATTACK -- INSERT ... ON CONFLICT DO UPDATE ---"
echo "=================================================================="
echo "    An INFERRED forgery at conf=0.99 tries to overwrite the"
echo "    MEASURED/1.0 incumbent via the speculative-insertion path."
echo "    Any correct precedence lattice (MEASURED beats INFERRED at"
echo "    equal specificity) should reject this. Plain UPDATE was closed"
echo "    in F20. This tests whether the ON CONFLICT DO UPDATE path also"
echo "    routes through our AM overrides."
echo
echo "    Statement:"
echo "      INSERT INTO fact_native (...)"
echo "      VALUES (42, 'bp', 'forged', ARRAY['s1'], ..., 'INFERRED', 10, 0.99)"
echo "      ON CONFLICT (entity_id, attribute) DO UPDATE"
echo "        SET ep_kind = EXCLUDED.ep_kind,"
echo "            ep_confidence = EXCLUDED.ep_confidence,"
echo "            value = EXCLUDED.value;"
echo
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL'
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'bp', 'forged', ARRAY['s1']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.99::real)
ON CONFLICT (entity_id, attribute) DO UPDATE
SET ep_kind = EXCLUDED.ep_kind,
    ep_confidence = EXCLUDED.ep_confidence,
    value = EXCLUDED.value;
SQL
UPSERT_RC=$?
set -e
echo "    (psql exit code: ${UPSERT_RC})"

echo
echo "--- verify: what is now live after ON CONFLICT DO UPDATE? ---"
LIVE_A=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT ep_kind::text || '|' || ep_confidence::text || '|' || value FROM fact_native WHERE entity_id = 42 AND attribute = 'bp';")
echo "    live row: ${LIVE_A}"
echo

OUTCOME_A=""
if echo "${LIVE_A}" | grep -q '^INFERRED|0.99|forged$'; then
    echo "==>  FORGERY SUCCEEDED (ON CONFLICT DO UPDATE)"
    echo "     INSERT..ON CONFLICT DO UPDATE swapped MEASURED/1.0/measured"
    echo "     for INFERRED/0.99/forged.  The AM callback never ran on the"
    echo "     ON CONFLICT UPDATE path (it flowed through heap_update via"
    echo "     inherited heapam.tuple_update? or the DO UPDATE re-route?)."
    echo "     Bug class matches F18/F20."
    OUTCOME_A="succeeded"
elif echo "${LIVE_A}" | grep -q '^MEASURED|1|measured-120/80$'; then
    OUTCOME_A="incumbent_survived"
    echo "==>  FORGERY REJECTED (ON CONFLICT DO UPDATE)"
    echo "     The incumbent MEASURED/1.0 survives.  Either the AM"
    echo "     overrides caught it or the statement errored above."
    OUTCOME_A="rejected"
else
    echo "==>  UNEXPECTED STATE for DO UPDATE: live row = '${LIVE_A}'"
    OUTCOME_A="unexpected"
fi

echo
echo "--- audit-row check after DO UPDATE (epistemic.evicted_fact) ---"
"${PSQL}" ${PSQL_CONN} <<'SQL'
SELECT count(*) AS eviction_audit_rows FROM epistemic.evicted_fact;
SELECT reason, original_kind FROM epistemic.evicted_fact LIMIT 5;
SQL

echo
echo "=================================================================="
echo "--- Step 3b: THE OTHER ATTACK -- INSERT ... ON CONFLICT DO NOTHING ---"
echo "=================================================================="
echo "    Reset to a clean-key scenario: DELETE the incumbent so"
echo "    (entity_id=99, attribute='hr') has no conflict, then INSERT"
echo "    an INFERRED forgery with ON CONFLICT DO NOTHING."
echo "    The question: does the DO NOTHING path (no arbiter conflict)"
echo "    still route the initial insert through table_tuple_insert_speculative,"
echo "    and does that bypass our tuple_insert override?"
echo
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL'
-- Fresh key with no incumbent.  This will not conflict, so
-- speculative-complete(succeeded=true) confirms the row.
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (99, 'hr', 'forged-nothing', ARRAY['s1']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.99::real)
ON CONFLICT (entity_id, attribute) DO NOTHING;
SQL
DO_NOTHING_RC=$?
echo "    (psql exit code: ${DO_NOTHING_RC})"

echo
echo "--- verify: what is now live for (99,'hr') after ON CONFLICT DO NOTHING? ---"
LIVE_B=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT COALESCE(ep_kind::text || '|' || ep_confidence::text || '|' || value, 'NO_ROW') FROM fact_native WHERE entity_id = 99 AND attribute = 'hr';")
echo "    live row: ${LIVE_B:-NO_ROW}"
echo

OUTCOME_B=""
if echo "${LIVE_B}" | grep -q '^INFERRED|0.99|forged-nothing$'; then
    echo "==>  FORGERY LANDED (ON CONFLICT DO NOTHING)"
    echo "     The INFERRED/0.99 row was written.  If our tuple_insert"
    echo "     override was routed through, it would still have written"
    echo "     this row (no incumbent to compare against, so R1..R5 pass"
    echo "     if the source is registered).  So landing alone is not"
    echo "     conclusive -- we look below at the R1..R5 trace."
    OUTCOME_B="landed"
elif [ -z "${LIVE_B}" ] || [ "${LIVE_B}" = "NO_ROW" ]; then
    echo "==>  NO ROW after ON CONFLICT DO NOTHING"
    echo "     The insert was refused (likely by our tuple_insert override)."
    OUTCOME_B="rejected"
else
    echo "==>  UNEXPECTED STATE for DO NOTHING: live row = '${LIVE_B}'"
    OUTCOME_B="unexpected"
fi

echo
echo "--- distinguishing test for DO NOTHING: attack an INCUMBENT ---"
echo "    A cleaner DO NOTHING test: try to write an INFERRED forgery"
echo "    against the MEASURED (42,'bp') incumbent with DO NOTHING."
echo "    Correct behavior: nothing happens (arbiter conflict).  If our"
echo "    tuple_insert override runs, it would REJECT with an R-violation"
echo "    (MEASURED-beats-INFERRED at equal specificity, precedence guard)."
echo "    If our override does NOT run, PG will silently no-op."
echo
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL'
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'bp', 'forged-again', ARRAY['s1']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.99::real)
ON CONFLICT (entity_id, attribute) DO NOTHING;
SQL
DO_NOTHING_INCUMBENT_RC=$?
set -e
echo "    (psql exit code: ${DO_NOTHING_INCUMBENT_RC})"
LIVE_C=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT ep_kind::text || '|' || ep_confidence::text || '|' || value FROM fact_native WHERE entity_id = 42 AND attribute = 'bp';")
echo "    live row after DO NOTHING against incumbent: ${LIVE_C}"

echo
echo "=================================================================="
echo "--- Step 3c: BARE ON CONFLICT DO NOTHING (no target column list) ---"
echo "=================================================================="
echo "    With no arbiter index existing, ON CONFLICT DO NOTHING (no"
echo "    (col) target) is essentially a no-op modifier: PG's ExecInsert"
echo "    has no arbiter to check against, so it routes through the plain"
echo "    tuple_insert path.  This should hit our override and reject."
echo "    (This variant is the closest thing to a 'speculative attack'"
echo "    that is REACHABLE on the epistemic AM today, because unique/"
echo "    exclusion constraints on epistemic tables all fail with"
echo "    'only heap AM is supported'.)"
echo
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL' 2>&1
INSERT INTO fact_native (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'bp', 'forged-bare', ARRAY['s1']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.99::real)
ON CONFLICT DO NOTHING;
SQL
BARE_RC=$?
set -e
echo "    (psql exit code: ${BARE_RC})"
LIVE_D=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT ep_kind::text || '|' || ep_confidence::text || '|' || value FROM fact_native WHERE entity_id = 42 AND attribute = 'bp';")
echo "    live row: ${LIVE_D}"

OUTCOME_D=""
if echo "${LIVE_D}" | grep -q '^MEASURED|1|measured-120/80$'; then
    echo "==>  BARE DO NOTHING REJECTED by tuple_insert override"
    OUTCOME_D="rejected"
elif echo "${LIVE_D}" | grep -q '^INFERRED|0.99|forged-bare$'; then
    echo "==>  BARE DO NOTHING FORGERY LANDED"
    OUTCOME_D="landed"
else
    echo "==>  UNEXPECTED bare DO NOTHING state: '${LIVE_D}'"
    OUTCOME_D="unexpected"
fi

echo
echo "=================================================================="
echo "--- Step 3d: PROBE constraint creation on epistemic AM ---"
echo "=================================================================="
echo "    Empirically confirm which arbiter constraints can be created"
echo "    on an epistemic-AM table.  If none work, the ON CONFLICT (col)"
echo "    and ON CONFLICT ON CONSTRAINT paths are unreachable, and the"
echo "    F21 speculative-insertion bypass has no attack surface today."
echo

echo "    PRIMARY KEY via ALTER TABLE:"
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL' 2>&1
ALTER TABLE fact_native ADD PRIMARY KEY (entity_id, attribute);
SQL
set -e

echo
echo "    UNIQUE constraint via ALTER TABLE:"
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL' 2>&1
ALTER TABLE fact_native ADD CONSTRAINT fn_u UNIQUE (entity_id, attribute);
SQL
set -e

echo
echo "    EXCLUDE constraint (btree_gist):"
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL' 2>&1
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE fact_native ADD CONSTRAINT fn_e EXCLUDE USING gist (entity_id WITH =);
SQL
set -e

echo
echo "    Indexes present on fact_native after all attempts:"
"${PSQL}" ${PSQL_CONN} -c "SELECT indexname FROM pg_indexes WHERE tablename='fact_native';"

echo
echo "=================================================================="
echo "--- Step 4: SANITY CHECK -- plain INSERT still hits our override ---"
echo "=================================================================="
echo "    A plain INSERT (no ON CONFLICT) of an INFERRED forgery against"
echo "    a MEASURED incumbent MUST be rejected by our tuple_insert override."
echo "    We do this against a fresh key first (setup a MEASURED incumbent"
echo "    at (77,'temp')), then attempt a plain INSERT forgery."
echo "    (Cannot use (42,'bp') because that has a UNIQUE index and would"
echo "    fail on the b-tree constraint rather than on R-precedence.)"
echo
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 <<'SQL'
-- Fresh table without a UNIQUE index, to isolate the R-precedence check
-- from the b-tree uniqueness constraint.
CREATE TABLE fact_sanity (
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

INSERT INTO fact_sanity (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (77, 'temp', 'measured-98.6', NULL,
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real);
SQL

echo
echo "    Now try plain INSERT of INFERRED forgery over MEASURED (77,'temp'):"
set +e
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 <<'SQL' 2>&1
INSERT INTO fact_sanity (entity_id, attribute, value, sources, valid_time,
                         ep_kind, ep_specificity, ep_confidence)
VALUES (77, 'temp', 'forged-inferred', ARRAY['s1']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.99::real);
SQL
PLAIN_RC=$?
set -e
echo "    (psql exit code: ${PLAIN_RC})"
LIVE_S=$("${PSQL}" ${PSQL_CONN} -Atc "SELECT ep_kind::text || '|' || ep_confidence::text || '|' || value FROM fact_sanity WHERE entity_id = 77 AND attribute = 'temp' ORDER BY sys_time DESC LIMIT 1;")
echo "    live row: ${LIVE_S}"

OUTCOME_S=""
if echo "${LIVE_S}" | grep -q '^MEASURED|1|measured-98\.6$'; then
    echo "==>  SANITY PASSED: plain INSERT was rejected by tuple_insert override."
    echo "     The MEASURED incumbent survives.  This proves the harness is"
    echo "     measuring speculative-path behavior specifically -- the plain"
    echo "     path DOES route through our AM."
    OUTCOME_S="rejected"
else
    echo "==>  SANITY FAILED: plain INSERT forgery landed too."
    echo "     Something is wrong with the AM install, not with the ON CONFLICT path."
    OUTCOME_S="landed"
fi

echo
echo "=================================================================="
echo "SUMMARY"
echo "=================================================================="
echo "  Step 3a (ON CONFLICT (col) DO UPDATE):            ${OUTCOME_A}"
echo "  Step 3b (ON CONFLICT (col) DO NOTHING no-inc.):   ${OUTCOME_B}"
echo "  Step 3b' (ON CONFLICT (col) DO NOTHING vs inc.):  see live_C above"
echo "  Step 3c (bare ON CONFLICT DO NOTHING):            ${OUTCOME_D}"
echo "  Step 4  (plain INSERT sanity check):              ${OUTCOME_S}"
echo
echo "  live_A (DO UPDATE @ 42,'bp'):             ${LIVE_A}"
echo "  live_B (DO NOTHING @ 99,'hr'):            ${LIVE_B:-NO_ROW}"
echo "  live_C (DO NOTHING vs incumbent @ 42):    ${LIVE_C}"
echo "  live_D (bare DO NOTHING @ 42):            ${LIVE_D}"
echo "  live_S (plain INSERT sanity @ 77,'temp'): ${LIVE_S}"
echo
echo "=================================================================="
echo "End of transcript. Cluster will be dropped."
echo "=================================================================="

exit 0
