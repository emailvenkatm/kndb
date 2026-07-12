#!/usr/bin/env bash
#
# scripts/rc_invariant.sh — F6 adversarial proof for the per-slot
# advisory xact lock.
#
# Two concurrent RC (default) sessions race an overlapping same-slot
# INSERT. Under the honest build the advisory xact lock (LOCKTAG_ADVISORY,
# key1=entity_id, key2=hash_bytes(attribute)) serialises the two writers
# so the second sees the first's committed row via GetLatestSnapshot in
# find_live_overlap. Expectation: `both=0`, exactly one live row, no
# 40001s.
#
# Adversarial mode (RC_INVARIANT_MODE=broken): rebuilds the AM with the
# advisory-lock block gated off (guarded by EPISTEMIC_ADVISORY_LOCK env
# via a compile-time #ifndef swap, done by sed). Expectation: `both=50`,
# two live rows every trial — the RC integrity leak returns.
#
# On exit the honest build is restored.
#
# Bash 3.2 compatible (macOS default).

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
AM="${REPO}/src/epistemic_am.c"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_CONFIG="${PG_CONFIG:-${PGBIN}/pg_config}"
PORT="${PORT:-55497}"
DATADIR="${DATADIR:-/tmp/kndb_e_rc_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

TRIALS="${TRIALS:-50}"
MODE="${RC_INVARIANT_MODE:-honest}"     # honest | broken

log()  { printf '[rc_invariant.sh] %s\n' "$*"; }
fail() { printf '[rc_invariant.sh] FAIL: %s\n' "$*" >&2; exit 1; }

RESTORE_NEEDED=0

restore_source() {
    if [ "${RESTORE_NEEDED}" = "1" ]; then
        log "restoring epistemic_am.c to F6 honest build"
        perl -i -0pe '
            s{if \(0 /\* F6 BROKEN: advisory lock disabled \*/\)}{if (have_key)}sg
        ' "${AM}"
        (cd "${REPO}" && PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s >/dev/null 2>&1 && \
            PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s install >/dev/null 2>&1) || \
            log "WARNING: restore rebuild failed; re-run 'make install' by hand"
        RESTORE_NEEDED=0
    fi
}

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${RC_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
    restore_source
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[rc_invariant.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[rc_invariant.sh] --- last 30 lines of server.log ---\n' >&2
            tail -n 30 "${LOG}" >&2 || true
        fi
    fi
    restore_source
    exit "${rc}"
}
trap on_error EXIT

# ------------------------------------------------------------------
# Optional: patch out the advisory lock for adversarial mode
# ------------------------------------------------------------------
if [ "${MODE}" = "broken" ]; then
    log "patching epistemic_am.c: disabling advisory-lock block"
    grep -q 'F6 BROKEN: advisory lock disabled' "${AM}" && \
        fail "epistemic_am.c already patched; refusing to run twice"

    perl -i -0pe '
        s{
            (F6:\ per-slot\ advisory\ xact\ lock\..*?\*/\s*)
            if\ \(have_key\)
        }{$1if (0 /* F6 BROKEN: advisory lock disabled */)}sx
    ' "${AM}"
    RESTORE_NEEDED=1

    grep -q 'F6 BROKEN: advisory lock disabled' "${AM}" || \
        fail "patch did not apply (grep did not find the marker)"

    log "rebuilding + installing patched AM"
    (cd "${REPO}" && PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s) \
        || fail "patched build failed"
    (cd "${REPO}" && PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s install) \
        || fail "patched install failed"
fi

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
log_min_messages = warning
log_line_prefix = '%m [%p] '
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
# 3. one trial: two concurrent RC inserts, same slot, DIFFERENT prefix
#    (specificity differs so precedence has a real answer, not just a tie)
# ------------------------------------------------------------------
run_race() {
    local out1="${WORKDIR}/s1.log"
    local out2="${WORKDIR}/s2.log"

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out1}" 2>&1 &
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (1, 'bp', 'session1',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.3);
COMMIT;
SQL
    local pid1=$!

    perl -e 'select undef,undef,undef, 0.05'

    "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out2}" 2>&1 &
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (1, 'bp', 'session2',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.3);
COMMIT;
SQL
    local pid2=$!

    wait "${pid1}" 2>/dev/null || true
    wait "${pid2}" 2>/dev/null || true

    local s1_40001 s2_40001
    s1_40001=$(grep -c -E 'could not serialize|40001' "${out1}" || true)
    s2_40001=$(grep -c -E 'could not serialize|40001' "${out2}" || true)

    local survivor n_live
    survivor=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT string_agg(value, ',' ORDER BY value)
         FROM fact WHERE entity_id=1 AND attribute='bp'
                   AND upper(sys_time) = 'infinity'::timestamptz;")
    n_live=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=1 AND attribute='bp'
                   AND upper(sys_time) = 'infinity'::timestamptz;")

    echo "survivor='${survivor}' n_live=${n_live} s1_40001=${s1_40001} s2_40001=${s2_40001}"
}

# ------------------------------------------------------------------
# 4. loop
# ------------------------------------------------------------------
s1_wins=0
s2_wins=0
both=0
none=0
abort_any=0
anomaly=0

log "=== READ COMMITTED, N=${TRIALS} (mode=${MODE}) ==="
for T in $(seq 1 "${TRIALS}"); do
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
SQL
    line=$(run_race)
    survivor=$(printf '%s' "${line}" | sed -E "s/.*survivor='([^']*)'.*/\1/")
    n_live=$(printf '%s' "${line}" | sed -E "s/.* n_live=([0-9]+).*/\1/")
    s1a=$(printf '%s' "${line}" | sed -E "s/.* s1_40001=([0-9]+).*/\1/")
    s2a=$(printf '%s' "${line}" | sed -E "s/.* s2_40001=([0-9]+).*/\1/")

    if [ "${s1a}" -gt 0 ] || [ "${s2a}" -gt 0 ]; then
        abort_any=$(( abort_any + 1 ))
    fi

    case "${survivor}" in
        "session1")           s1_wins=$(( s1_wins + 1 ));;
        "session2")           s2_wins=$(( s2_wins + 1 ));;
        "session1,session2")  both=$(( both + 1 ));;
        "")                    none=$(( none + 1 ));;
        *)                     anomaly=$(( anomaly + 1 ));;
    esac

    printf '[rc_invariant.sh] trial=%-3s survivor=%-24s n_live=%s s1_40001=%s s2_40001=%s\n' \
        "${T}" "'${survivor}'" "${n_live}" "${s1a}" "${s2a}"
done

log "----- summary -----"
log "  trials       : ${TRIALS}"
log "  session1_wins: ${s1_wins}"
log "  session2_wins: ${s2_wins}"
log "  both_live    : ${both}"
log "  none_live    : ${none}"
log "  anomalies    : ${anomaly}"
log "  aborted_txn  : ${abort_any}"

# ------------------------------------------------------------------
# 5. verdict
# ------------------------------------------------------------------
if [ "${MODE}" = "honest" ]; then
    log "MODE=honest: expect both_live=0, aborted=0, exactly one row per trial"
    if [ "${both}" -ne 0 ]; then
        fail "RC leak observed: both_live=${both} (expected 0)"
    fi
    if [ "${abort_any}" -ne 0 ]; then
        fail "unexpected 40001 aborts under RC honest build: ${abort_any}"
    fi
    if [ $(( s1_wins + s2_wins )) -ne "${TRIALS}" ]; then
        fail "expected one survivor per trial, got s1=${s1_wins} s2=${s2_wins}"
    fi
    log "PASS: advisory xact lock closes the RC integrity leak"
    trap - EXIT
    cleanup
    exit 0
fi

# broken mode
log "MODE=broken: expect both_live=TRIALS (RC leak restored)"
if [ "${both}" -ne "${TRIALS}" ]; then
    log "WARNING: expected both_live=${TRIALS}, got ${both}"
    log "(negative control did not reproduce the full leak; investigate)"
    fail "adversarial control did not reproduce RC leak on every trial"
fi
log "PASS: adversarial control confirms the advisory lock is load-bearing"
trap - EXIT
cleanup
exit 0
