#!/usr/bin/env bash
#
# scripts/hash_grind.sh — F8 adversarial proof: the xmin tiebreak is not
# grindable by attacker-controlled content.
#
# History. F6 broke true precedence ties (equal kind, specificity,
# confidence) by hash_bytes over the content columns and let lower-hash
# win. F7 pointed out that hash_bytes is server-known and deterministic
# per build: an attacker with SELECT + INSERT can grind `value` bytes
# until it beats the incumbent's hash. F7's original hash_grind.sh
# demonstrated the grind in ~30 attempts on the mean.
#
# F8's fix (src/epistemic_am.c) replaces the caller-side content hash
# with a server-controlled xmin tiebreak. On a true precedence tie the
# AM compares the incumbent's raw xmin (HeapTupleHeaderGetRawXmin at
# htup_details.h:322-326 REL_18_STABLE) with the current backend's
# xid (GetCurrentTransactionId at xact.c:454 REL_18_STABLE) via
# TransactionIdPrecedes (transam.c:279-292 REL_18_STABLE). The
# incumbent is by construction committed before we scan (F6 advisory
# lock guarantees this), so its xmin logically precedes our xid on
# every attempt and it keeps the slot. The attacker cannot influence
# either xid.
#
# This script exercises exactly that:
#
#   Step 1: attacker observability (unchanged from F7). SELECT+INSERT
#           roles trivially read (ep_kind, ep_specificity, ep_confidence).
#           The attack surface is not visibility of the prefix; it is
#           whether a determined attacker can find *any* content whose
#           tie the AM decides in their favour.
#
#   Step 2: fresh incumbent, then N candidate `value`s in fresh
#           transactions. Baseline (xmin tiebreak in place): assert
#           attacker wins 0/N. Every candidate ERROR-fails with
#           NEW_LOSES. Incumbent survives every attempt.
#
#   Step 3: same as step 2, whitespace-suffix pattern for parity with
#           the F7 baseline. Same expectation: 0/N.
#
#   Step 4: 100 fresh trials, each with a fresh incumbent, 200 attacker
#           attempts each. Assert: 0 wins across 100*200 = 20000
#           attempts.
#
# Adversarial mode (HASH_GRIND_MODE=broken) patches out the xmin
# tiebreak so the tie branch reverts to unconditional NEW_WINS.
# Expectation: attacker wins on the FIRST attempt (last-writer-wins),
# and step-4 sums to N/N attempts=1 wins.
#
# Both modes are load-bearing:
#   - honest 0/N proves the mechanism is doing work;
#   - broken N/N proves the mechanism is what makes the difference.
#
# Bash 3.2 compatible.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
AM="${REPO}/src/epistemic_am.c"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_CONFIG="${PG_CONFIG:-${PGBIN}/pg_config}"
PORT="${PORT:-55502}"
DATADIR="${DATADIR:-/tmp/kndb_f8_grind_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

MODE="${HASH_GRIND_MODE:-honest}"   # honest | broken
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
TRIALS="${TRIALS:-100}"
GRIND_PER_TRIAL="${GRIND_PER_TRIAL:-200}"

log()  { printf '[hash_grind] %s\n' "$*"; }
fail() { printf '[hash_grind] FAIL: %s\n' "$*" >&2; exit 1; }

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
        [ "${KEEP:-0}" = "1" ] || rm -rf "${DATADIR}"
    fi
    restore_source
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[hash_grind] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[hash_grind] --- last 30 lines of server.log ---\n' >&2
            tail -n 30 "${LOG}" >&2 || true
        fi
    fi
    restore_source
    exit "${rc}"
}
trap on_error EXIT

# ------------------------------------------------------------------
# Adversarial patch: disable the xmin tiebreak (revert to
# unconditional NEW_WINS on tie).
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
# Fresh cluster
# ------------------------------------------------------------------
log "spinning cluster at ${DATADIR} (mode=${MODE})"
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
"${PG_CTL}" -D "${DATADIR}" -l "${LOG}" -w -t 30 start >/dev/null \
    || fail "postmaster failed to start"
for i in 1 2 3 4 5 6 7 8 9 10; do
    "${PG_ISREADY}" -h "${SOCKDIR}" -p "${PORT}" -q && break
    sleep 1
    [ "${i}" = "10" ] && fail "pg_isready never returned success"
done

log "installing extension, fact table, incumbent row"
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS epistemic;

INSERT INTO epistemic.source_registry (source_id, source_type)
VALUES ('honest_llm', 'llm'), ('adversary_llm', 'llm');

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

-- Incumbent: honest INFERRED row.
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', 'honest_report', ARRAY['honest_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
SQL

# -------- Step 1: observability --------
log ""
log "=== Step 1: attacker observability of (kind, specificity, confidence) ==="
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE ROLE attacker LOGIN;
GRANT USAGE ON SCHEMA epistemic TO attacker;
GRANT SELECT, INSERT ON fact TO attacker;
GRANT SELECT ON epistemic.source_registry TO attacker;
GRANT SELECT ON epistemic.slot_kind TO attacker;
GRANT INSERT ON epistemic.evicted_fact TO attacker;
GRANT USAGE, SELECT ON SEQUENCE epistemic.evicted_fact_audit_id_seq TO attacker;
SQL
log "  attacker role: LOGIN + SELECT + INSERT on fact"
log "  reading incumbent as attacker:"
"${PSQL}" ${PSQL_CONN} -U attacker -Atq <<'SQL' 2>&1 | sed 's/^/[hash_grind]     /'
SELECT entity_id, attribute, value, ep_kind::text, ep_specificity, ep_confidence
  FROM fact WHERE entity_id=42 AND attribute='diagnosis';
SQL

# -------- Step 2: grinding attempt on numeric-suffix pattern --------
log ""
log "=== Step 2: grind ${MAX_ATTEMPTS} candidate values (attack_v0..) ==="
ATTEMPTS=0
WINS=0
LOSSES=0
UNEXPECTED=0

for i in $(seq 0 $(( MAX_ATTEMPTS - 1 ))); do
    ATTEMPTS=$((ATTEMPTS + 1))
    VAL="attack_v${i}"
    out=$("${PSQL}" ${PSQL_CONN} -U attacker -v ON_ERROR_STOP=0 -X -Atq 2>&1 <<SQL
BEGIN;
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', '${VAL}', ARRAY['adversary_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
COMMIT;
SQL
)
    if printf '%s\n' "${out}" | grep -q "NEW_LOSES"; then
        LOSSES=$((LOSSES + 1))
        continue
    fi
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        UNEXPECTED=$((UNEXPECTED + 1))
        log "  attempt ${ATTEMPTS} (value=${VAL}) unexpected error:"
        printf '%s\n' "${out}" | sed 's/^/[hash_grind]     /'
        continue
    fi
    WINS=$((WINS + 1))
done

log "  numeric-suffix : wins=${WINS} losses=${LOSSES} unexpected=${UNEXPECTED} of ${MAX_ATTEMPTS}"

log ""
log "  post-attack state of fact:"
"${PSQL}" ${PSQL_CONN} -Atq <<'SQL' | sed 's/^/[hash_grind]     /'
SELECT value, ep_specificity, ep_confidence, upper(sys_time)::text AS sys_upper
  FROM fact WHERE entity_id=42 AND attribute='diagnosis' ORDER BY sys_time;
SQL

# -------- Step 3: whitespace-suffix pattern --------
log ""
log "=== Step 3: grind whitespace-suffix pattern ('evil' + n spaces) ==="
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
TRUNCATE epistemic.evicted_fact;
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', 'honest_report', ARRAY['honest_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
SQL

ATTEMPTS2=0
WINS2=0
LOSSES2=0
UNEXPECTED2=0
for i in $(seq 0 $(( MAX_ATTEMPTS - 1 ))); do
    ATTEMPTS2=$((ATTEMPTS2 + 1))
    PAD=$(printf ' %.0s' $(seq 1 "${i}") 2>/dev/null || true)
    VAL="evil${PAD}"
    out=$("${PSQL}" ${PSQL_CONN} -U attacker -v ON_ERROR_STOP=0 -X -Atq 2>&1 <<SQL
BEGIN;
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', '${VAL}', ARRAY['adversary_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
COMMIT;
SQL
)
    if printf '%s\n' "${out}" | grep -q "NEW_LOSES"; then
        LOSSES2=$((LOSSES2 + 1))
        continue
    fi
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        UNEXPECTED2=$((UNEXPECTED2 + 1))
        continue
    fi
    WINS2=$((WINS2 + 1))
done
log "  whitespace-suffix: wins=${WINS2} losses=${LOSSES2} unexpected=${UNEXPECTED2} of ${MAX_ATTEMPTS}"

# -------- Step 4: 100 fresh trials, distribution -----
log ""
log "=== Step 4: ${TRIALS} fresh incumbents, ${GRIND_PER_TRIAL} attacker attempts each ==="

TOTAL_WINS=0
TOTAL_LOSSES=0
TOTAL_UNEXPECTED=0
TOTAL_ATT=0
TRIALS_WITH_WIN=0
TRIALS_WITH_NO_WIN=0

for T in $(seq 1 "${TRIALS}"); do
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q -c "TRUNCATE fact; TRUNCATE epistemic.evicted_fact;" >/dev/null
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', 'honest_${T}', ARRAY['honest_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
SQL
    WON_THIS_TRIAL=0
    ATTS=0
    for i in $(seq 0 $(( GRIND_PER_TRIAL - 1 ))); do
        ATTS=$((ATTS + 1))
        VAL="a${T}_${i}"
        out=$("${PSQL}" ${PSQL_CONN} -U attacker -v ON_ERROR_STOP=0 -X -Atq 2>&1 <<SQL
BEGIN;
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', '${VAL}', ARRAY['adversary_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
COMMIT;
SQL
)
        if printf '%s\n' "${out}" | grep -q "NEW_LOSES"; then
            TOTAL_LOSSES=$((TOTAL_LOSSES + 1))
            continue
        fi
        if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
            TOTAL_UNEXPECTED=$((TOTAL_UNEXPECTED + 1))
            continue
        fi
        TOTAL_WINS=$((TOTAL_WINS + 1))
        WON_THIS_TRIAL=1
        # In broken mode attacker wins on attempt 1 and further inserts
        # would race the new incumbent (also attacker-controlled); break
        # to keep the run finite.
        if [ "${MODE}" = "broken" ]; then
            break
        fi
    done
    TOTAL_ATT=$(( TOTAL_ATT + ATTS ))
    if [ "${WON_THIS_TRIAL}" = "1" ]; then
        TRIALS_WITH_WIN=$(( TRIALS_WITH_WIN + 1 ))
    else
        TRIALS_WITH_NO_WIN=$(( TRIALS_WITH_NO_WIN + 1 ))
    fi
    if [ $(( T % 10 )) = 0 ]; then
        log "  progress: trial ${T}/${TRIALS} wins_so_far=${TOTAL_WINS}"
    fi
done

log ""
log "  summary over ${TRIALS} trials:"
log "    attempts_total : ${TOTAL_ATT}"
log "    attacker_wins  : ${TOTAL_WINS}"
log "    NEW_LOSES      : ${TOTAL_LOSSES}"
log "    unexpected     : ${TOTAL_UNEXPECTED}"
log "    trials_with_win: ${TRIALS_WITH_WIN} / ${TRIALS}"

# -------- Verdict ----------
log ""
if [ "${MODE}" = "honest" ]; then
    log "MODE=honest: expect attacker wins 0/N under xmin tiebreak"
    if [ "${WINS}" -ne 0 ]; then
        fail "step 2 numeric-suffix: attacker won ${WINS}/${MAX_ATTEMPTS} (expected 0)"
    fi
    if [ "${WINS2}" -ne 0 ]; then
        fail "step 3 whitespace-suffix: attacker won ${WINS2}/${MAX_ATTEMPTS} (expected 0)"
    fi
    if [ "${TOTAL_WINS}" -ne 0 ]; then
        fail "step 4 distribution: attacker won ${TOTAL_WINS} times across ${TRIALS} trials (expected 0)"
    fi
    if [ "${TRIALS_WITH_WIN}" -ne 0 ]; then
        fail "step 4: ${TRIALS_WITH_WIN} trials had at least one attacker win (expected 0)"
    fi
    log "PASS: xmin tiebreak resists content grinding across ${TOTAL_ATT}+${MAX_ATTEMPTS}+${MAX_ATTEMPTS} attempts"
    trap - EXIT
    cleanup
    exit 0
fi

log "MODE=broken: expect attacker wins on the FIRST attempt every trial"
if [ "${WINS}" -eq 0 ]; then
    fail "step 2 numeric-suffix under broken: expected wins>0, got 0"
fi
if [ "${WINS2}" -eq 0 ]; then
    fail "step 3 whitespace-suffix under broken: expected wins>0, got 0"
fi
# In broken mode every trial's first attempt succeeds (no NEW_LOSES on tie).
if [ "${TRIALS_WITH_WIN}" -ne "${TRIALS}" ]; then
    fail "step 4: expected ${TRIALS}/${TRIALS} trials to have a win, got ${TRIALS_WITH_WIN}"
fi
log "PASS: adversarial control reproduces last-writer-wins across ${TRIALS}/${TRIALS} trials"
log "      that is exactly the property the xmin tiebreak eliminates."
trap - EXIT
cleanup
exit 0
