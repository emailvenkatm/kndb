#!/usr/bin/env bash
#
# scripts/bypass.sh — engine-in-storage differentiator.
#
# A BEFORE INSERT trigger enforces write-time rules from user space.
# The AM enforces them from inside heapam's tuple_insert callback. If a
# writer can turn the trigger off, the trigger-based enforcement is
# bypassable; the AM callback is not.
#
# Attacker model: a role with INSERT + ALTER TABLE (owner-in-part) on
# the target table, but no privileges to swap the table's access method
# or drop the extension. ALTER TABLE ... SET ACCESS METHOD is a
# schema-change threat, not a write-path threat; it's out of scope.
#
# Three bypass mechanisms:
#   1. ALTER TABLE fact_trigger DISABLE TRIGGER ALL
#      Sets pg_trigger.tgenabled = 'D'. Confirmed in PG 18 at
#      src/backend/commands/tablecmds.c:5588-5592 (REL_18_STABLE) and
#      src/backend/commands/trigger.c:3491-3499 (TriggerEnabled skips
#      TRIGGER_DISABLED under any SessionReplicationRole).
#
#   2. SET session_replication_role = 'replica'
#      In PG 18, TriggerEnabled at trigger.c:3489-3499 skips
#      TRIGGER_FIRES_ON_ORIGIN (the default for user CREATE TRIGGER)
#      whenever SessionReplicationRole == SESSION_REPLICATION_ROLE_REPLICA.
#      The GUC itself is PGC_SUSET (guc_tables.c:5166), so the writer
#      needs SUPERUSER or a GRANT SET ON PARAMETER — but that's exactly
#      the profile of a replication/CDC operator, a migration tool,
#      or a connection-pool operator who flips the role for a whole
#      pool. The claim is that even those roles can't bypass the AM.
#
#   3. COPY FROM into a table with no BEFORE-INSERT trigger
#      In PG 18, CopyFrom (src/backend/commands/copyfrom.c:995-1006
#      REL_18_STABLE) selects insertMethod = CIM_MULTI when the target
#      has no BEFORE/INSTEAD OF INSERT trigger, then flushes batches
#      through table_multi_insert at copyfrom.c:554-559, which
#      dispatches on the AM's `multi_insert` callback
#      (access/tableam.h:527-529 REL_18_STABLE). Before F18 the
#      epistemic AM inherited heap_multi_insert (heapam_handler.c:2641
#      REL_18_STABLE), so every COPY-batched row skipped R1..R5, the
#      advisory lock, precedence, eviction, and the rmgr-128 record.
#      F18 overrides multi_insert to iterate over slots[] and invoke
#      epistemic_tuple_insert_impl per row, closing this write path.
#      (F9 was the audit that surfaced this; see DECISIONS.md F18.)
#
# For each mechanism we perform an R3-violating insert (MEASURED row
# with sources set) and assert:
#   * on fact_trigger, the row lands (bypass succeeds);
#   * on fact_native,  the AM raises the R3 violation (bypass blocked).
#
# The adversarial validation lives in scripts/bypass_off_mode.sh: it
# rebuilds the AM with the rule-check block commented out and reruns
# this script; the fact_native assertion must then FAIL. See DECISIONS.md.
#
# Bash 3.2 compatible (macOS default). No GNU-only flags.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55492}"
DATADIR="${DATADIR:-/tmp/kndb_e_bypass_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[bypass.sh] %s\n' "$*"; }
fail() { printf '[bypass.sh] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${BYPASS_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[bypass.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
    fi
    exit "${rc}"
}
trap on_error EXIT

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

log "creating extension, fact_native (USING epistemic), fact_trigger (heap)"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

CREATE TABLE fact_native (
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

CREATE TABLE fact_trigger (
    entity_id     int NOT NULL,
    attribute     text NOT NULL,
    value         text,
    sources       text[],
    valid_time    tstzrange,
    sys_time      tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind       epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0
);

CREATE OR REPLACE FUNCTION fact_trigger_rules()
RETURNS trigger AS $$
BEGIN
    IF NEW.ep_kind::text = 'MEASURED' THEN
        IF NEW.sources IS NOT NULL AND array_length(NEW.sources, 1) > 0 THEN
            RAISE EXCEPTION 'epistemic write-time rule violation: R3 (MEASURED no sources)'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER fact_trigger_before_insert
    BEFORE INSERT ON fact_trigger
    FOR EACH ROW EXECUTE FUNCTION fact_trigger_rules();
SQL

# The insert we attempt in every scenario: a MEASURED row that carries
# sources, i.e. a direct R3 violation.
BAD_ROW_VALUES="(1, 'bp', '120/80',
                 ARRAY['s3:pt/vitals.csv'],
                 tstzrange('2026-01-01', 'infinity'),
                 'MEASURED'::epistemic.epistemic_kind, 0::int2, 1.0::real)"

BAD_COLS="entity_id, attribute, value, sources, valid_time, ep_kind,
          ep_specificity, ep_confidence"

# Helper: run one insert, capture the psql exit code and combined stdio.
attempt_insert() {
    local table="$1"
    local preamble="$2"    # SQL prefix (turn off triggers, etc.)
    local outfile="$3"

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${outfile}" 2>&1
${preamble}
INSERT INTO ${table} (${BAD_COLS}) VALUES ${BAD_ROW_VALUES};
SQL
}

# Helper: run one COPY FROM STDIN of a single R3-violating row (the
# fields must match BAD_COLS order). Used by bypass scenario 3 (F18).
# COPY selects insertMethod at copyfrom.c:995-1006 REL_18_STABLE: if
# the target has a BEFORE INSERT trigger, insertMethod = CIM_SINGLE
# and rows route through table_tuple_insert (which the AM already
# overrides). If not, insertMethod = CIM_MULTI and rows route through
# table_multi_insert. F18 covers the latter path.
attempt_copy_bad_row() {
    local table="$1"
    local outfile="$2"

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${outfile}" 2>&1
COPY ${table} (entity_id, attribute, value, sources, valid_time,
               ep_kind, ep_specificity, ep_confidence)
FROM STDIN WITH (FORMAT csv, QUOTE '"');
1,bp,120/80,"{s3:pt/vitals.csv}","[""2026-01-01"",infinity)",MEASURED,0,1.0
\.
SQL
}

count_rows() {
    local table="$1"
    "${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM ${table} WHERE entity_id=1 AND attribute='bp';"
}

truncate_both() {
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact_trigger;
TRUNCATE fact_native;
ALTER TABLE fact_trigger ENABLE TRIGGER ALL;
SQL
}

WORKDIR="${DATADIR}/work"
mkdir -p "${WORKDIR}"

# Report accumulator: 4 scenarios × pass/fail.
FAILURES=0
record() {
    local tag="$1"; local expect="$2"; local actual="$3"
    if [ "${expect}" = "${actual}" ]; then
        log "  ${tag}: OK (expected=${expect} actual=${actual})"
    else
        log "  ${tag}: FAIL (expected=${expect} actual=${actual})"
        FAILURES=$(( FAILURES + 1 ))
    fi
}

# ------------------------------------------------------------------
# Bypass 1: ALTER TABLE ... DISABLE TRIGGER ALL
# ------------------------------------------------------------------
log "bypass 1: ALTER TABLE ... DISABLE TRIGGER ALL"
truncate_both

OUT="${WORKDIR}/b1_trigger.log"
attempt_insert fact_trigger \
    "ALTER TABLE fact_trigger DISABLE TRIGGER ALL;" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_trigger DISABLE TRIGGER ALL transcript ---\n'
cat "${OUT}"
TRIGGER_ROWS=$(count_rows fact_trigger)
# Expected: 1 (bypass succeeded, bad row landed).
record "fact_trigger DISABLE_TRIGGER_ALL rows_after" 1 "${TRIGGER_ROWS}"

# Native path: DISABLE TRIGGER ALL is a no-op for a table that has no
# user triggers, but issue it anyway to make the scenario mechanically
# identical from the writer's perspective.
OUT="${WORKDIR}/b1_native.log"
attempt_insert fact_native \
    "ALTER TABLE fact_native DISABLE TRIGGER ALL;" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_native DISABLE TRIGGER ALL transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$(count_rows fact_native)
# Expected: 0 (AM blocked).
record "fact_native  DISABLE_TRIGGER_ALL rows_after" 0 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'epistemic write-time rule violation' "${OUT}" || true)
record "fact_native  DISABLE_TRIGGER_ALL raised_R3" 1 "${NATIVE_ERR}"

# ------------------------------------------------------------------
# Bypass 2: session_replication_role = 'replica'
# ------------------------------------------------------------------
log "bypass 2: SET session_replication_role = 'replica'"
truncate_both

OUT="${WORKDIR}/b2_trigger.log"
attempt_insert fact_trigger \
    "SET session_replication_role = 'replica';" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_trigger replica-role transcript ---\n'
cat "${OUT}"
TRIGGER_ROWS=$(count_rows fact_trigger)
record "fact_trigger replica_role rows_after" 1 "${TRIGGER_ROWS}"

OUT="${WORKDIR}/b2_native.log"
attempt_insert fact_native \
    "SET session_replication_role = 'replica';" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_native replica-role transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$(count_rows fact_native)
record "fact_native  replica_role rows_after" 0 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'epistemic write-time rule violation' "${OUT}" || true)
record "fact_native  replica_role raised_R3" 1 "${NATIVE_ERR}"

# ------------------------------------------------------------------
# Bypass 3: COPY FROM (F18)
#
# F9 identified this write path: with no BEFORE-INSERT trigger on the
# target, CopyFrom (copyfrom.c:995-1006 REL_18_STABLE) sets
# insertMethod = CIM_MULTI and later flushes buffered rows through
# table_multi_insert (copyfrom.c:554-559), which dispatches on the
# AM's `multi_insert` callback (tableam.h:527-529). Before F18 the
# epistemic AM inherited heap_multi_insert (heapam_handler.c:2641),
# so every batched row skipped R1..R5, the advisory lock, precedence,
# eviction, and the rmgr-128 record — a silent bypass.
#
# For the trigger baseline we intentionally do NOT disable the
# trigger here: with the trigger active, COPY into fact_trigger
# routes through CIM_SINGLE (copyfrom.c:1005), fires the BEFORE
# INSERT trigger via ExecBRInsertTriggers (copyfrom.c:1329), and
# rejects the row. That behaviour is unchanged by F18. What F18
# changes is the fact_native path: COPY into it must now be rejected
# too. Scenario 1 (DISABLE TRIGGER ALL) already covers the case of a
# trigger writer who turns their protection off — no need to repeat
# it with COPY.
# ------------------------------------------------------------------
log "bypass 3: COPY FROM STDIN (F18: multi_insert override)"
truncate_both

OUT="${WORKDIR}/b3_trigger.log"
attempt_copy_bad_row fact_trigger "${OUT}"
printf '\n[bypass.sh] --- fact_trigger COPY-FROM transcript ---\n'
cat "${OUT}"
TRIGGER_ROWS=$(count_rows fact_trigger)
# With trigger active, COPY takes CIM_SINGLE and fires the BEFORE
# INSERT trigger; expect 0 rows and the trigger's R3 error.
record "fact_trigger COPY_FROM rows_after"   0 "${TRIGGER_ROWS}"
TRIGGER_ERR=$(grep -c 'epistemic write-time rule violation' "${OUT}" || true)
record "fact_trigger COPY_FROM raised_R3"    1 "${TRIGGER_ERR}"

OUT="${WORKDIR}/b3_native.log"
attempt_copy_bad_row fact_native "${OUT}"
printf '\n[bypass.sh] --- fact_native COPY-FROM transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$(count_rows fact_native)
# With F18 the AM's multi_insert override rejects the batched row.
# Without F18 (i.e. after the source-rebuild patch that removes the
# .multi_insert wiring — see Task 3 disable-and-test) this row would
# land on fact_native, proving the bypass returns.
record "fact_native  COPY_FROM rows_after"   0 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'epistemic write-time rule violation' "${OUT}" || true)
record "fact_native  COPY_FROM raised_R3"    1 "${NATIVE_ERR}"

# ------------------------------------------------------------------
# F18 additional check: multi-row COPY. A single-row COPY still hits
# heap_multi_insert with nslots=1, so it exercises multi_insert. Also
# run a small multi-row COPY (5 rows, 4 clean + 1 R3-violating) to
# assert that ONE bad row in a batch aborts the whole COPY under the
# AM's multi_insert. The clean rows never commit.
# ------------------------------------------------------------------
log "bypass 3b: multi-row COPY, 1 bad row in a batch of 5 (F18)"
truncate_both
OUT="${WORKDIR}/b3b_native.log"
"${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${OUT}" 2>&1
COPY fact_native (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
FROM STDIN WITH (FORMAT csv, QUOTE '"');
2,hr,72,,"[""2026-01-01"",infinity)",MEASURED,0,1.0
3,rr,16,,"[""2026-01-01"",infinity)",MEASURED,0,1.0
4,spo2,98,,"[""2026-01-01"",infinity)",MEASURED,0,1.0
5,temp,37.1,,"[""2026-01-01"",infinity)",MEASURED,0,1.0
6,bp,120/80,"{s3:pt/vitals.csv}","[""2026-01-01"",infinity)",MEASURED,0,1.0
\.
SQL
printf '\n[bypass.sh] --- fact_native COPY-FROM 5-row batch transcript ---\n'
cat "${OUT}"
BATCH_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_native WHERE entity_id IN (2,3,4,5,6);")
# Whole COPY aborts on the R3 raise; no rows commit.
record "fact_native  COPY_5rows rows_after"  0 "${BATCH_ROWS}"
BATCH_ERR=$(grep -c 'epistemic write-time rule violation' "${OUT}" || true)
record "fact_native  COPY_5rows raised_R3"   1 "${BATCH_ERR}"

# ------------------------------------------------------------------
# Bypass 4: UPDATE that rewrites the epistemic prefix (F20)
#
# Attack: INSERT (kind=INFERRED, conf=0.4), then UPDATE SET
# kind='MEASURED', conf=1.0, value='forged'. Before F20 the AM
# inherited heapam_tuple_update (heapam_handler.c:1385 REL_18_STABLE),
# so heap_update ran without R1..R5, without the advisory lock, and
# without the precedence lattice. The forged MEASURED row landed
# with no eviction audit. F20 rejects the prefix change with
# ERRCODE_CHECK_VIOLATION at epistemic_am.c epistemic_tuple_update.
#
# The trigger baseline uses a BEFORE UPDATE trigger that raises on
# any change to ep_kind, ep_specificity, or ep_confidence — so that
# scenario relies on the trigger not being disabled, which is the
# same class of vulnerability bypass 1 already characterised.
# ------------------------------------------------------------------
log "bypass 4: UPDATE that rewrites the epistemic prefix (F20)"
truncate_both
# Register the source once so the R1/R2 preflight passes for the
# INFERRED incumbent.
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
INSERT INTO epistemic.source_registry (source_id, source_type)
    VALUES ('s1', 'llm-inference')
    ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION fact_trigger_update_rules()
RETURNS trigger AS $$
BEGIN
    -- Cast the enum to text: the base epistemic_kind type has no
    -- built-in equality operator, and IS DISTINCT FROM needs one.
    IF NEW.ep_kind::text IS DISTINCT FROM OLD.ep_kind::text OR
       NEW.ep_specificity IS DISTINCT FROM OLD.ep_specificity OR
       NEW.ep_confidence IS DISTINCT FROM OLD.ep_confidence THEN
        RAISE EXCEPTION 'epistemic write-time rule violation: F20 prefix immutable'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS fact_trigger_before_update ON fact_trigger;
CREATE TRIGGER fact_trigger_before_update
    BEFORE UPDATE ON fact_trigger
    FOR EACH ROW EXECUTE FUNCTION fact_trigger_update_rules();
SQL

# Seed both tables with a legitimate INFERRED incumbent.
SEED_ROW="(1, 'bp', 'benign', ARRAY['s1'],
           tstzrange('2026-01-01', 'infinity'),
           'INFERRED'::epistemic.epistemic_kind, 10::int2, 0.4::real)"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO fact_native  (${BAD_COLS}) VALUES ${SEED_ROW};
INSERT INTO fact_trigger (${BAD_COLS}) VALUES ${SEED_ROW};
SQL

# The forgery UPDATE. Same SQL against both tables; expect both to
# reject (trigger baseline via BEFORE UPDATE, native via AM callback).
attempt_update_forgery() {
    local table="$1"
    local preamble="$2"
    local outfile="$3"

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${outfile}" 2>&1
${preamble}
UPDATE ${table}
   SET ep_kind = 'MEASURED'::epistemic.epistemic_kind,
       ep_confidence = 1.0::real,
       value = 'forged'
 WHERE entity_id = 1 AND attribute = 'bp';
SQL
}

OUT="${WORKDIR}/b4_trigger.log"
attempt_update_forgery fact_trigger "" "${OUT}"
printf '\n[bypass.sh] --- fact_trigger UPDATE-forgery transcript ---\n'
cat "${OUT}"
TRIGGER_KIND=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT ep_kind::text FROM fact_trigger WHERE entity_id=1 AND attribute='bp';")
# Trigger rejects: incumbent INFERRED survives.
record "fact_trigger UPDATE_forgery kind_after" "INFERRED" "${TRIGGER_KIND}"
TRIGGER_ERR=$(grep -c 'epistemic write-time rule violation\|F20 prefix immutable' "${OUT}" || true)
record "fact_trigger UPDATE_forgery raised"     1 "${TRIGGER_ERR}"

OUT="${WORKDIR}/b4_native.log"
attempt_update_forgery fact_native "" "${OUT}"
printf '\n[bypass.sh] --- fact_native UPDATE-forgery transcript ---\n'
cat "${OUT}"
NATIVE_KIND=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT ep_kind::text FROM fact_native WHERE entity_id=1 AND attribute='bp';")
# F20 rejects: incumbent INFERRED survives on native too.
record "fact_native  UPDATE_forgery kind_after" "INFERRED" "${NATIVE_KIND}"
NATIVE_ERR=$(grep -c 'refusing to alter the epistemic prefix' "${OUT}" || true)
record "fact_native  UPDATE_forgery raised_F20" 1 "${NATIVE_ERR}"

# Adversarial extension: DISABLE the BEFORE UPDATE trigger on the
# trigger table and re-run — this MUST land on fact_trigger (bypass
# succeeds) and MUST STILL be rejected on fact_native (AM callback
# defeats the disable-trigger bypass, the F2 argument). Keeps the
# trigger baseline honest and the F20+F2 differentiator visible.
truncate_both
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO fact_native  (${BAD_COLS}) VALUES ${SEED_ROW};
INSERT INTO fact_trigger (${BAD_COLS}) VALUES ${SEED_ROW};
SQL

OUT="${WORKDIR}/b4_trigger_disabled.log"
attempt_update_forgery fact_trigger \
    "ALTER TABLE fact_trigger DISABLE TRIGGER ALL;" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_trigger UPDATE-forgery + DISABLE TRIGGER transcript ---\n'
cat "${OUT}"
TRIGGER_KIND=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT ep_kind::text FROM fact_trigger WHERE entity_id=1 AND attribute='bp';")
# With trigger disabled, forgery lands: MEASURED overwrites INFERRED.
record "fact_trigger UPDATE_disabled kind_after" "MEASURED" "${TRIGGER_KIND}"

OUT="${WORKDIR}/b4_native_disabled.log"
attempt_update_forgery fact_native \
    "ALTER TABLE fact_native DISABLE TRIGGER ALL;" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_native UPDATE-forgery + DISABLE TRIGGER transcript ---\n'
cat "${OUT}"
NATIVE_KIND=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT ep_kind::text FROM fact_native WHERE entity_id=1 AND attribute='bp';")
# AM callback still fires even after DISABLE TRIGGER ALL.
record "fact_native  UPDATE_disabled kind_after" "INFERRED" "${NATIVE_KIND}"
NATIVE_ERR=$(grep -c 'refusing to alter the epistemic prefix' "${OUT}" || true)
record "fact_native  UPDATE_disabled raised_F20" 1 "${NATIVE_ERR}"

# ------------------------------------------------------------------
# Bypass 5: DELETE that removes the incumbent (F20)
#
# Attack: INSERT (kind=MEASURED), DELETE the row, INSERT
# (kind=INFERRED). Before F20 the AM inherited heapam_tuple_delete
# (heapam_handler.c:1384 REL_18_STABLE); heap_delete ran unchecked;
# the MEASURED incumbent vanished; the subsequent INFERRED landed
# unopposed. F20 refuses DELETE outright with ERRCODE_FEATURE_NOT_SUPPORTED.
#
# The trigger baseline uses a BEFORE DELETE trigger that raises;
# same DISABLE-TRIGGER extension applies as in bypass 4.
# ------------------------------------------------------------------
log "bypass 5: DELETE that removes the incumbent (F20)"
truncate_both
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE OR REPLACE FUNCTION fact_trigger_delete_rules()
RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'epistemic write-time rule violation: F20 DELETE not supported'
        USING ERRCODE = 'feature_not_supported';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS fact_trigger_before_delete ON fact_trigger;
CREATE TRIGGER fact_trigger_before_delete
    BEFORE DELETE ON fact_trigger
    FOR EACH ROW EXECUTE FUNCTION fact_trigger_delete_rules();
SQL

MEASURED_SEED="(2, 'diagnosis', 'sepsis', NULL,
                tstzrange('2026-01-01', 'infinity'),
                'MEASURED'::epistemic.epistemic_kind, 10::int2, 1.0::real)"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO fact_native  (${BAD_COLS}) VALUES ${MEASURED_SEED};
INSERT INTO fact_trigger (${BAD_COLS}) VALUES ${MEASURED_SEED};
SQL

attempt_delete_forgery() {
    local table="$1"
    local preamble="$2"
    local outfile="$3"

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${outfile}" 2>&1
${preamble}
DELETE FROM ${table} WHERE entity_id=2 AND attribute='diagnosis';
SQL
}

OUT="${WORKDIR}/b5_trigger.log"
attempt_delete_forgery fact_trigger "" "${OUT}"
printf '\n[bypass.sh] --- fact_trigger DELETE-forgery transcript ---\n'
cat "${OUT}"
TRIGGER_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_trigger WHERE entity_id=2 AND attribute='diagnosis';")
record "fact_trigger DELETE_forgery rows_after" 1 "${TRIGGER_ROWS}"
TRIGGER_ERR=$(grep -c 'epistemic write-time rule violation\|F20 DELETE not supported' "${OUT}" || true)
record "fact_trigger DELETE_forgery raised"     1 "${TRIGGER_ERR}"

OUT="${WORKDIR}/b5_native.log"
attempt_delete_forgery fact_native "" "${OUT}"
printf '\n[bypass.sh] --- fact_native DELETE-forgery transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_native WHERE entity_id=2 AND attribute='diagnosis';")
record "fact_native  DELETE_forgery rows_after" 1 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'DELETE from an epistemic table is not supported' "${OUT}" || true)
record "fact_native  DELETE_forgery raised_F20" 1 "${NATIVE_ERR}"

# Adversarial extension: DISABLE TRIGGER ALL + DELETE. Trigger baseline
# loses (row vanishes); native still refuses.
truncate_both
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO fact_native  (${BAD_COLS}) VALUES ${MEASURED_SEED};
INSERT INTO fact_trigger (${BAD_COLS}) VALUES ${MEASURED_SEED};
SQL

OUT="${WORKDIR}/b5_trigger_disabled.log"
attempt_delete_forgery fact_trigger \
    "ALTER TABLE fact_trigger DISABLE TRIGGER ALL;" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_trigger DELETE + DISABLE TRIGGER transcript ---\n'
cat "${OUT}"
TRIGGER_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_trigger WHERE entity_id=2 AND attribute='diagnosis';")
# With BEFORE DELETE trigger disabled, DELETE lands: row vanishes.
record "fact_trigger DELETE_disabled rows_after" 0 "${TRIGGER_ROWS}"

OUT="${WORKDIR}/b5_native_disabled.log"
attempt_delete_forgery fact_native \
    "ALTER TABLE fact_native DISABLE TRIGGER ALL;" \
    "${OUT}"
printf '\n[bypass.sh] --- fact_native DELETE + DISABLE TRIGGER transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_native WHERE entity_id=2 AND attribute='diagnosis';")
# AM callback fires regardless of trigger state.
record "fact_native  DELETE_disabled rows_after" 1 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'DELETE from an epistemic table is not supported' "${OUT}" || true)
record "fact_native  DELETE_disabled raised_F20" 1 "${NATIVE_ERR}"

# ------------------------------------------------------------------
# Bypass 6: speculative-insertion callback (F21)
#
# INSERT ... ON CONFLICT routes through table_tuple_insert_speculative
# + table_tuple_complete_speculative (tableam.h:513-525 REL_18_STABLE;
# ExecInsert dispatch at nodeModifyTable.c:1189-1216). Before F21 the
# AM inherited heapam_tuple_insert_speculative and
# heapam_tuple_complete_speculative verbatim (heapam_handler.c:2639-2640),
# so ON CONFLICT DO UPDATE / DO NOTHING would skip R1..R5, the
# advisory lock, precedence, and the eviction audit.
#
# The SQL surface for this attack is currently unreachable on the
# epistemic AM: CREATE UNIQUE INDEX / ADD PRIMARY KEY / ADD UNIQUE /
# ADD EXCLUDE all fail at heap_getnext's rd_tableam identity check
# (heapam.c:1352), which the btree/gist ambuild scan depends on.
# scripts/speculative_forgery.sh confirms that empirically. So the
# SQL-level scenario for this bypass is "not currently reachable" —
# but the overrides are defensive and load-bearing, so we exercise
# them via the epistemic._probe_speculative_insert C entry point.
#
# For each cell we run one R3 forgery (MEASURED + sources[]) via the
# speculative path; the AM must reject it. The adversarial disable-
# and-test lives in the F21 DECISIONS entry: comment out the two
# wiring lines in epistemic_am_handler, rebuild, rerun this scenario;
# both cells then LAND, proving the wiring is load-bearing.
# ------------------------------------------------------------------
log "bypass 6: speculative INSERT (F21 tuple_insert_speculative / complete_speculative)"
truncate_both

OUT="${WORKDIR}/b6_native_probe.log"
"${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<'SQL' >"${OUT}" 2>&1
INSERT INTO epistemic.source_registry (source_id, source_type)
    VALUES ('s1', 'llm-inference') ON CONFLICT DO NOTHING;
SELECT epistemic._probe_speculative_insert(
    'fact_native', 999, 'bp_spec', 'forged-measured',
    ARRAY['s1']::text[],
    tstzrange('2026-01-01', 'infinity'),
    'MEASURED'::epistemic.epistemic_kind, 0::int2, 1.0::real);
SQL
printf '\n[bypass.sh] --- fact_native speculative-probe R3 transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_native WHERE entity_id=999 AND attribute='bp_spec';")
# With F21 the AM's speculative override rejects the R3 forgery.
# Without F21 (wiring commented out, rebuild) this row would land on
# fact_native, proving the bypass returns — see F21 DECISIONS entry
# for the transcript.
record "fact_native  SPEC_probe_R3 rows_after"    0 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'epistemic write-time rule violation' "${OUT}" || true)
record "fact_native  SPEC_probe_R3 raised_R3"     1 "${NATIVE_ERR}"

# Also exercise the R4 rejection on the speculative path.
OUT="${WORKDIR}/b6_native_probe_r4.log"
"${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<'SQL' >"${OUT}" 2>&1
SELECT epistemic._probe_speculative_insert(
    'fact_native', 998, 'hr_spec', 'forged-inferred',
    ARRAY['s1']::text[],
    tstzrange('2026-01-01', 'infinity'),
    'INFERRED'::epistemic.epistemic_kind, 0::int2, 1.0::real);
SQL
printf '\n[bypass.sh] --- fact_native speculative-probe R4 transcript ---\n'
cat "${OUT}"
NATIVE_ROWS=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT count(*) FROM fact_native WHERE entity_id=998 AND attribute='hr_spec';")
record "fact_native  SPEC_probe_R4 rows_after"    0 "${NATIVE_ROWS}"
NATIVE_ERR=$(grep -c 'R4 (INFERRED confidence' "${OUT}" || true)
record "fact_native  SPEC_probe_R4 raised_R4"     1 "${NATIVE_ERR}"

# ------------------------------------------------------------------
# F7 interaction characterization: per-slot advisory locks accumulate
# under COPY just like under INSERT. F7's ~15k ceiling at the PG
# default max_locks_per_transaction=64 applies to COPY too. Sweep
# 100 / 1000 / 10000 / 20000 rows and assert the first three land,
# 20000 hits ERRCODE_OUT_OF_MEMORY 53200. Run this BEFORE we tear
# down the cluster so we reuse the postmaster and its default
# max_locks_per_transaction.
# ------------------------------------------------------------------
log "F7 interaction: COPY of {100, 1000, 10000, 20000} clean rows into fact_native"
"${PSQL}" ${PSQL_CONN} -Atc "SHOW max_locks_per_transaction;" \
    | awk '{print "[bypass.sh]   SHOW: max_locks_per_transaction="$1}'

run_batch_copy() {
    local n="$1"
    local out csv
    out=$(mktemp)
    csv=$(mktemp)
    # Generate the CSV rows to a file, then \copy from it — this makes
    # the AM route through table_multi_insert (CIM_MULTI, copyfrom.c:1039
    # REL_18_STABLE) so this cell measures the COPY path specifically.
    # Distinct entity_id per row means N distinct advisory-lock slots.
    awk -v n="${n}" 'BEGIN {
        for (i = 1; i <= n; i++)
            printf "%d,attr_%d,v_%d,\"[\"\"2026-01-01\"\",infinity)\",MEASURED,5,0.8\n", i, i, i
    }' >"${csv}"

    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X <<SQL >"${out}" 2>&1
TRUNCATE fact_native;
\copy fact_native (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence) FROM '${csv}' WITH (FORMAT csv, QUOTE '"')
SELECT 'rows_committed=' || count(*)::text FROM fact_native;
SQL
    # Report ok/fail + sqlstate hint by grep.
    if grep -qE 'ERROR|FATAL' "${out}"; then
        local msg
        msg=$(grep -m1 -E 'ERROR|FATAL' "${out}" | head -c 200 | tr -d '\r')
        printf 'FAIL|%s\n' "${msg}"
    else
        printf 'OK|%d rows\n' "${n}"
    fi
    rm -f "${out}" "${csv}"
}

# The batch here is a real COPY FROM (CIM_MULTI). Under F18 each of
# the N rows takes one per-slot advisory xact lock inside
# epistemic_multi_insert -> epistemic_tuple_insert_impl, so this cell
# also exercises F7's shared-lock-table ceiling under COPY. Expected
# at max_locks_per_transaction=64: 100 / 1000 / 10000 land; 20000
# hits ERRCODE_OUT_OF_MEMORY 53200 (lock.c:1076-1082 REL_18_STABLE).
FIRST_FAIL=""
for N in 100 1000 10000 20000; do
    res=$(run_batch_copy "${N}")
    outcome="${res%%|*}"
    rest="${res#*|}"
    printf '[bypass.sh]   N=%-6s %-4s  %s\n' "${N}" "${outcome}" "${rest}"
    if [ "${outcome}" = "FAIL" ] && [ -z "${FIRST_FAIL}" ]; then
        FIRST_FAIL="${N}"
    fi
done

# Assertions on the F7 characterization: 100/1000/10000 must land,
# 20000 must fail with out-of-shared-memory.
for N in 100 1000 10000; do
    res=$(run_batch_copy "${N}")
    outcome="${res%%|*}"
    record "F7-interaction N=${N} outcome"    "OK" "${outcome}"
done
res20k=$(run_batch_copy 20000)
outcome20k="${res20k%%|*}"
record "F7-interaction N=20000 outcome"       "FAIL" "${outcome20k}"
# The failure at 20000 must be shared-memory lock-table exhaustion,
# not some other error. F7 documented ERRCODE_OUT_OF_MEMORY 53200
# with errhint "You might need to increase max_locks_per_transaction"
# from lock.c:1076-1082 REL_18_STABLE.
outfile_20k=$(mktemp)
csv_20k=$(mktemp)
awk 'BEGIN {
    for (i = 1; i <= 20000; i++)
        printf "%d,attr_%d,v_%d,\"[\"\"2026-01-01\"\",infinity)\",MEASURED,5,0.8\n", i, i, i
}' >"${csv_20k}"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X <<SQL >"${outfile_20k}" 2>&1
TRUNCATE fact_native;
\set VERBOSITY verbose
\copy fact_native (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence) FROM '${csv_20k}' WITH (FORMAT csv, QUOTE '"')
SQL
printf '[bypass.sh]   verbose N=20000 error transcript:\n'
grep -E 'ERROR|SQLSTATE|HINT|DETAIL|LOCATION' "${outfile_20k}" \
    | sed 's/^/[bypass.sh]     /' || true
LOCK_ERR=$(grep -c '53200\|out of shared memory' "${outfile_20k}" || true)
record "F7-interaction N=20000 err_is_53200"  1 "${LOCK_ERR}"
rm -f "${outfile_20k}" "${csv_20k}"
truncate_both

# ------------------------------------------------------------------
log "----- summary -----"
if [ "${FAILURES}" -eq 0 ]; then
    log "PASS: all scenarios matched expectation. AM survives all bypasses; trigger survives DISABLE/replica but not COPY (because BEFORE trigger forces CIM_SINGLE)."
    trap - EXIT
    cleanup
    exit 0
fi

log "FAIL: ${FAILURES} scenario(s) did not match expectation."
trap - EXIT
cleanup
exit 1
