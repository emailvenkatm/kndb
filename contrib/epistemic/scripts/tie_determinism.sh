#!/usr/bin/env bash
#
# scripts/tie_determinism.sh — F8 adversarial proof for the xmin
# (first-committer-wins) tiebreak.
#
# History. F6 broke true precedence ties by hash_bytes over the content
# columns and let lower-hash win. That was content-deterministic (same
# content wins under any commit order) but attacker-grindable: the
# attacker controls `value` and the server's hash is deterministic per
# build (see F7 hash_grind.sh, ~30 attempts to find a winning value on
# the mean). F8 swaps that mechanism for a server-controlled xmin
# comparison in src/epistemic_am.c:
#
#   on a true (kind, specificity, confidence) tie,
#   TransactionIdPrecedes(incumbent_xmin, current_xid) -> incumbent wins.
#
# The AM reads the raw xmin from the HeapTupleHeader
# (HeapTupleHeaderGetRawXmin, htup_details.h:322-326 REL_18_STABLE) and
# gets the current xid via GetCurrentTransactionId (xact.c:454
# REL_18_STABLE). TransactionIdPrecedes (transam.c:279-292 REL_18_STABLE)
# handles xid-wraparound via a modulo-2^32 comparison. F6's advisory
# lock guarantees the incumbent is committed before we see it, so
# incumbent_xmin < new_xid on every race — the incumbent always wins.
#
# Semantics change. F6 was content-deterministic: the same value won
# under both start orders. F8 is start-order-dependent: whichever
# session commits first wins. Both are deterministic given a fixed
# workload; the difference is what the workload can be. Under F6 an
# attacker who controls content and can retry can win any tie by
# grinding; under F8 no content the attacker can send changes the
# outcome — only who committed first.
#
# Test shape:
#   Two concurrent RC sessions insert overlapping same-slot rows with
#   IDENTICAL (kind, specificity, confidence) but DIFFERENT `value`
#   ("A_lo" from session1, "Z_hi" from session2). A 50ms stagger
#   ensures the first-started session gets its xid first and commits
#   first (both sessions sleep 300ms inside the txn to allow the second
#   to block on the advisory lock; the F6 lock ensures the second
#   observes the first's committed row on unblock).
#
# Expectation (honest, xmin tiebreak in place):
#   s1first  -> A_lo wins every trial  (session1's xmin precedes session2's xid)
#   s2first  -> Z_hi wins every trial  (session2's xmin precedes session1's xid)
#
# Adversarial mode (TIE_DET_MODE=broken): patches out the xmin tiebreak
# so the tie branch reverts to unconditional NEW_WINS. Under advisory-lock
# serialisation the second-to-arrive session always wins (last-writer-wins):
#   s1first  -> Z_hi wins every trial
#   s2first  -> A_lo wins every trial
#
# The flip in the honest column (A vs Z depending on which session
# starts first) is the "first-committer-wins" property. The flip in
# the broken column (last-writer-wins) is what we get when the
# mechanism is off. Both are stable across trials; that stability is
# the load-bearing observation.
#
# Bash 3.2 compatible.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
AM="${REPO}/src/epistemic_am.c"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_CONFIG="${PG_CONFIG:-${PGBIN}/pg_config}"
PORT="${PORT:-55498}"
DATADIR="${DATADIR:-/tmp/kndb_e_det_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

TRIALS="${TRIALS:-50}"
MODE="${TIE_DET_MODE:-honest}"     # honest | broken

log()  { printf '[tie_determinism.sh] %s\n' "$*"; }
fail() { printf '[tie_determinism.sh] FAIL: %s\n' "$*" >&2; exit 1; }

RESTORE_NEEDED=0

restore_source() {
    if [ "${RESTORE_NEEDED}" = "1" ]; then
        log "restoring epistemic_am.c to F8 honest build"
        perl -i -0pe '
            s{if \(0 /\* F8 BROKEN: xmin tiebreak disabled \*/\)}
             {if (cmp.outcome == EP_CMP_NEW_WINS &&\n\t\t\t\tcmp.reason == EP_REASON_CONTRADICTED_SAME_RANK)}sg
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
        if [ "${TIE_DET_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
    restore_source
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[tie_determinism.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[tie_determinism.sh] --- last 30 lines of server.log ---\n' >&2
            tail -n 30 "${LOG}" >&2 || true
        fi
    fi
    restore_source
    exit "${rc}"
}
trap on_error EXIT

# ------------------------------------------------------------------
# adversarial patch: disable the xmin tiebreak
# ------------------------------------------------------------------
if [ "${MODE}" = "broken" ]; then
    log "patching epistemic_am.c: disabling xmin tiebreak"
    grep -q 'F8 BROKEN: xmin tiebreak disabled' "${AM}" && \
        fail "epistemic_am.c already patched; refusing to run twice"

    perl -i -0pe '
        s{
            if\ \(cmp\.outcome\ ==\ EP_CMP_NEW_WINS\ &&\s*
                 cmp\.reason\ ==\ EP_REASON_CONTRADICTED_SAME_RANK\)
        }{if (0 /* F8 BROKEN: xmin tiebreak disabled */)}sx
    ' "${AM}"
    RESTORE_NEEDED=1

    grep -q 'F8 BROKEN: xmin tiebreak disabled' "${AM}" || \
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
# 2. one race: two concurrent RC inserts, IDENTICAL prefix, DIFFERENT
#    value. Only value differs so the tie branch is reached.
# ------------------------------------------------------------------
run_race() {
    local first="$1"  # "s1first" or "s2first"
    local out1="${WORKDIR}/s1.log"
    local out2="${WORKDIR}/s2.log"

    if [ "${first}" = "s1first" ]; then
        "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out1}" 2>&1 &
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (1, 'bp', 'A_lo',
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
VALUES (1, 'bp', 'Z_hi',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.3);
COMMIT;
SQL
        local pid2=$!
    else
        "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out2}" 2>&1 &
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (1, 'bp', 'Z_hi',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.3);
COMMIT;
SQL
        local pid2=$!
        perl -e 'select undef,undef,undef, 0.05'
        "${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<SQL >"${out1}" 2>&1 &
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind,
                  ep_specificity, ep_confidence)
VALUES (1, 'bp', 'A_lo',
        tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.3);
COMMIT;
SQL
        local pid1=$!
    fi

    wait "${pid1}" 2>/dev/null || true
    wait "${pid2}" 2>/dev/null || true

    local s1_rule s2_rule
    s1_rule=$(grep -c 'epistemic precedence: NEW_LOSES' "${out1}" || true)
    s2_rule=$(grep -c 'epistemic precedence: NEW_LOSES' "${out2}" || true)

    local survivor n_live
    survivor=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT string_agg(value, ',' ORDER BY value)
         FROM fact WHERE entity_id=1 AND attribute='bp'
                   AND upper(sys_time) = 'infinity'::timestamptz;")
    n_live=$("${PSQL}" ${PSQL_CONN} -Atc \
        "SELECT count(*) FROM fact WHERE entity_id=1 AND attribute='bp'
                   AND upper(sys_time) = 'infinity'::timestamptz;")

    echo "survivor='${survivor}' n_live=${n_live} s1_rule=${s1_rule} s2_rule=${s2_rule}"
}

# ------------------------------------------------------------------
# 3. loop, TRIALS trials for each start order
# ------------------------------------------------------------------
run_suite() {
    local order="$1"

    local A_wins=0 Z_wins=0 both=0 none=0 anomaly=0 rule_any=0

    log "=== order=${order} (mode=${MODE}) ==="
    for T in $(seq 1 "${TRIALS}"); do
        "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
SQL
        line=$(run_race "${order}")
        survivor=$(printf '%s' "${line}" | sed -E "s/.*survivor='([^']*)'.*/\1/")
        n_live=$(printf '%s' "${line}" | sed -E "s/.* n_live=([0-9]+).*/\1/")
        s1r=$(printf '%s' "${line}" | sed -E "s/.* s1_rule=([0-9]+).*/\1/")
        s2r=$(printf '%s' "${line}" | sed -E "s/.* s2_rule=([0-9]+).*/\1/")

        if [ "${s1r}" -gt 0 ] || [ "${s2r}" -gt 0 ]; then
            rule_any=$(( rule_any + 1 ))
        fi

        case "${survivor}" in
            "A_lo")       A_wins=$(( A_wins + 1 ));;
            "Z_hi")       Z_wins=$(( Z_wins + 1 ));;
            "A_lo,Z_hi")  both=$(( both + 1 ));;
            "")            none=$(( none + 1 ));;
            *)             anomaly=$(( anomaly + 1 ));;
        esac

        printf '[tie_determinism.sh] %-8s trial=%-3s survivor=%-16s n_live=%s s1_rule=%s s2_rule=%s\n' \
            "${order}" "${T}" "'${survivor}'" "${n_live}" "${s1r}" "${s2r}"
    done

    log "----- ${order} summary -----"
    log "  A_lo_wins  : ${A_wins}"
    log "  Z_hi_wins  : ${Z_wins}"
    log "  both_live  : ${both}"
    log "  none_live  : ${none}"
    log "  anomalies  : ${anomaly}"
    log "  rule_err   : ${rule_any}"

    printf '%s A=%s Z=%s both=%s rule=%s\n' \
        "${order}" "${A_wins}" "${Z_wins}" "${both}" "${rule_any}" \
        >>"${SUMMARY_FILE}"
}

SUMMARY_FILE="${DATADIR}/summary.txt"
: > "${SUMMARY_FILE}"

run_suite "s1first"
run_suite "s2first"

# ------------------------------------------------------------------
# 4. verdict
# ------------------------------------------------------------------
log "----- overall -----"
cat "${SUMMARY_FILE}" | while read -r line; do
    log "  ${line}"
done

s1f_A=$(grep '^s1first' "${SUMMARY_FILE}" | sed -E 's/.*A=([0-9]+).*/\1/')
s1f_Z=$(grep '^s1first' "${SUMMARY_FILE}" | sed -E 's/.*Z=([0-9]+).*/\1/')
s2f_A=$(grep '^s2first' "${SUMMARY_FILE}" | sed -E 's/.*A=([0-9]+).*/\1/')
s2f_Z=$(grep '^s2first' "${SUMMARY_FILE}" | sed -E 's/.*Z=([0-9]+).*/\1/')

if [ "${MODE}" = "honest" ]; then
    log "MODE=honest: expect first-committer-wins under both orders"
    log "  s1first: session1's xmin precedes session2's xid -> A_lo wins"
    log "  s2first: session2's xmin precedes session1's xid -> Z_hi wins"
    if [ "${s1f_A}" -eq "${TRIALS}" ] && [ "${s2f_Z}" -eq "${TRIALS}" ]; then
        log "PASS: xmin tiebreak = first-committer-wins under both orders"
        trap - EXIT
        cleanup
        exit 0
    fi
    fail "not first-committer-wins: s1first(A=${s1f_A} Z=${s1f_Z}) s2first(A=${s2f_A} Z=${s2f_Z})"
fi

log "MODE=broken: expect last-writer-wins under both orders"
log "  without the tiebreak, second-to-arrive session's tie insert commits"
log "  s1first: session2 arrives second -> Z_hi wins"
log "  s2first: session1 arrives second -> A_lo wins"
if [ "${s1f_Z}" -eq "${TRIALS}" ] && [ "${s2f_A}" -eq "${TRIALS}" ]; then
    log "PASS: without tiebreak, survivor is last-writer-wins"
    log "      that is exactly the property the xmin tiebreak reverses"
    trap - EXIT
    cleanup
    exit 0
fi

fail "broken mode did not reproduce last-writer-wins: s1first(A=${s1f_A} Z=${s1f_Z}) s2first(A=${s2f_A} Z=${s2f_Z})"
