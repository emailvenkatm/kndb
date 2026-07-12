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
# Two bypass mechanisms:
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
log "----- summary -----"
if [ "${FAILURES}" -eq 0 ]; then
    log "PASS: 4/4 scenarios matched expectation. AM survives both bypasses; trigger survives neither."
    trap - EXIT
    cleanup
    exit 0
fi

log "FAIL: ${FAILURES} scenario(s) did not match expectation."
trap - EXIT
cleanup
exit 1
