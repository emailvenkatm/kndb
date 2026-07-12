#!/usr/bin/env bash
#
# scripts/tie_concurrency_invert.sh — adversarial control for the tie
# policy. Rebuilds the AM with epistemic_precedence_cmp's same-rank
# tie branch flipped to EP_CMP_NEW_LOSES, reruns the sequential tie
# probe, then restores the source and rebuilds.
#
# This is NOT part of make check-e2e. It mutates the installed
# extension in-place and is destructive to any concurrent test
# clusters. Run it standalone. It leaves the extension in its
# original state (or aborts with the datadir kept).
#
# Bash 3.2 compatible. No GNU-only flags.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
RULES="${REPO}/src/epistemic_rules.c"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_CONFIG="${PG_CONFIG:-${PGBIN}/pg_config}"
PORT="${PORT:-55496}"
DATADIR="${DATADIR:-/tmp/kndb_e_tie_invert_$$}"
LOG="${DATADIR}/server.log"
SOCKDIR="${DATADIR}"

INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PSQL="${PGBIN}/psql"
PG_ISREADY="${PGBIN}/pg_isready"

PSQL_CONN="-h ${SOCKDIR} -p ${PORT} -d postgres"

log()  { printf '[tie_invert.sh] %s\n' "$*"; }
fail() { printf '[tie_invert.sh] FAIL: %s\n' "$*" >&2; exit 1; }

RESTORE_NEEDED=0

restore_source() {
    if [ "${RESTORE_NEEDED}" = "1" ]; then
        log "restoring epistemic_rules.c to original NEW_WINS branch"
        sed -i.bak \
            -e 's|r.outcome = EP_CMP_NEW_LOSES;   /\* F4 INVERT \*/|r.outcome = EP_CMP_NEW_WINS;|' \
            "${RULES}"
        rm -f "${RULES}.bak"
        (cd "${REPO}" && PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s >/dev/null 2>&1 && \
            PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s install >/dev/null 2>&1) || \
            log "WARNING: restore rebuild failed; re-run 'make install' by hand"
        RESTORE_NEEDED=0
    fi
}

cleanup() {
    if [ -d "${DATADIR}" ]; then
        "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true
        if [ "${TIE_INVERT_KEEP:-0}" != "1" ]; then
            rm -rf "${DATADIR}"
        fi
    fi
    restore_source
}

on_error() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '[tie_invert.sh] datadir kept for inspection: %s\n' "${DATADIR}" >&2
        if [ -f "${LOG}" ]; then
            printf '[tie_invert.sh] --- last 30 lines of server.log ---\n' >&2
            tail -n 30 "${LOG}" >&2 || true
        fi
    fi
    restore_source
    exit "${rc}"
}
trap on_error EXIT

# ------------------------------------------------------------------
# 1. flip the tie branch
# ------------------------------------------------------------------
log "patching epistemic_rules.c: tie branch NEW_WINS -> NEW_LOSES"
grep -q 'EP_CMP_NEW_LOSES;   /\* F4 INVERT \*/' "${RULES}" && \
    fail "epistemic_rules.c already patched; refusing to run twice"

perl -i -0pe '
    s{
        (\Qif (new->ep_specificity == incumbent->ep_specificity &&\E\s*
         \Qnew->ep_confidence == incumbent->ep_confidence)\E\s*
         \{\s*
        )r\.outcome\s*=\s*EP_CMP_NEW_WINS;
    }{$1r.outcome = EP_CMP_NEW_LOSES;   /* F4 INVERT */}sx
' "${RULES}"
RESTORE_NEEDED=1

grep -q 'EP_CMP_NEW_LOSES;   /\* F4 INVERT \*/' "${RULES}" || \
    fail "patch did not apply (grep did not find the marker)"

log "rebuilding + installing patched AM"
(cd "${REPO}" && PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s) \
    || fail "patched build failed"
(cd "${REPO}" && PATH="${PGBIN}:${PATH}" PG_CONFIG="${PG_CONFIG}" make -s install) \
    || fail "patched install failed"

# ------------------------------------------------------------------
# 2. fresh cluster
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
# 3. probe: sequential tie MUST error under patched build
# ------------------------------------------------------------------
log "sequential tie probe (patched build): 2nd identical INSERT should ERROR"
OUT="${DATADIR}/probe.log"
"${PSQL}" ${PSQL_CONN} -X -v ON_ERROR_STOP=0 <<'SQL' >"${OUT}" 2>&1
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
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence)
VALUES (1, 'bp', 'first',  tstzrange('2026-01-01', 'infinity'), 'MEASURED', 5::int2, 0.8::real);
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence)
VALUES (1, 'bp', 'second', tstzrange('2026-01-01', 'infinity'), 'MEASURED', 5::int2, 0.8::real);
SELECT count(*) AS rows_after,
       string_agg(value, ',' ORDER BY value) AS survivors
  FROM fact WHERE entity_id=1 AND attribute='bp'
                AND upper(sys_time) = 'infinity'::timestamptz;
SQL
cat "${OUT}"

if ! grep -q 'epistemic precedence: NEW_LOSES (reason=contradicted_same_rank)' "${OUT}"; then
    fail "patched build did not raise CONTRADICTED_SAME_RANK on 2nd identical INSERT"
fi

SURVIVOR=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT string_agg(value, ',' ORDER BY value)
     FROM fact WHERE entity_id=1 AND attribute='bp'
               AND upper(sys_time) = 'infinity'::timestamptz;")
log "patched-build survivor after error: '${SURVIVOR}'"
if [ "${SURVIVOR}" != "first" ]; then
    fail "expected survivor='first', got '${SURVIVOR}'"
fi

log "PASS: patched AM rejects the tie on the serial path"
log "      (first-wins content-deterministic policy demonstrated as the"
log "       alternative to the current arrival-order-wins semantics)."

# ------------------------------------------------------------------
# 4. concurrency probe under the patched build — expect the same
#    isolation-driven outcomes as tie_concurrency.sh, because the tie
#    branch is unreachable under concurrency in either direction.
# ------------------------------------------------------------------
log "sanity check: concurrent tie under patched build should look the"
log "              same as the unpatched concurrency case (tie branch"
log "              unreachable under either isolation level)."
"${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE fact;
SQL

WORKDIR="${DATADIR}/work"
mkdir -p "${WORKDIR}"

"${PSQL}" ${PSQL_CONN} -X <<SQL >"${WORKDIR}/s1.log" 2>&1 &
BEGIN ISOLATION LEVEL SERIALIZABLE;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence)
VALUES (1, 'bp', 'session1', tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.4);
COMMIT;
SQL
PID1=$!
perl -e 'select undef,undef,undef, 0.05'
"${PSQL}" ${PSQL_CONN} -X <<SQL >"${WORKDIR}/s2.log" 2>&1 &
BEGIN ISOLATION LEVEL SERIALIZABLE;
INSERT INTO fact (entity_id, attribute, value, valid_time, ep_kind, ep_specificity, ep_confidence)
VALUES (1, 'bp', 'session2', tstzrange('2026-01-01', 'infinity'),
        'MEASURED'::epistemic.epistemic_kind, 5::int2, 0.8::real);
SELECT pg_sleep(0.4);
COMMIT;
SQL
PID2=$!
wait "${PID1}" 2>/dev/null || true
wait "${PID2}" 2>/dev/null || true

log "session1 transcript:"; cat "${WORKDIR}/s1.log"
log "session2 transcript:"; cat "${WORKDIR}/s2.log"

SURV_CONC=$("${PSQL}" ${PSQL_CONN} -Atc \
    "SELECT string_agg(value, ',' ORDER BY value)
     FROM fact WHERE entity_id=1 AND attribute='bp'
               AND upper(sys_time) = 'infinity'::timestamptz;")
log "patched-build concurrent survivor: '${SURV_CONC}'"

log "PASS: adversarial control complete"
trap - EXIT
cleanup
exit 0
