#!/usr/bin/env bash
#
# scripts/r2_microbench.sh — measure R2 (source-resolution) per-row overhead.
#
# Method: insert 5000 rows of MEASURED (R2 skipped) and 5000 rows of INFERRED
# (R2 runs SPI per row) into a fresh epistemic table on a private cluster.
# Report mean per-row insert wall-clock in μs, and the derived R2 overhead.
# Repeat R replicates and report the median across replicates for both.

set -euo pipefail
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PORT="${PORT:-55501}"
DATADIR="${DATADIR:-/tmp/kndb_r2_bench_$$}"
INITDB="${PGBIN}/initdb"; PG_CTL="${PGBIN}/pg_ctl"; PSQL="${PGBIN}/psql"
PSQL_CONN="-h ${DATADIR} -p ${PORT} -d postgres"
N="${N:-5000}"
REPS="${REPS:-5}"

cleanup() { "${PG_CTL}" -D "${DATADIR}" -m immediate stop >/dev/null 2>&1 || true; rm -rf "${DATADIR}"; }
trap cleanup EXIT

rm -rf "${DATADIR}"; mkdir -p "${DATADIR}"; chmod 700 "${DATADIR}"
"${INITDB}" -D "${DATADIR}" -U "$(whoami)" --auth=trust --no-locale --encoding=UTF8 >/dev/null
cat >> "${DATADIR}/postgresql.conf" <<CONF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${DATADIR}'
shared_preload_libraries = 'epistemic'
max_locks_per_transaction = 4096
CONF
"${PG_CTL}" -D "${DATADIR}" -l "${DATADIR}/server.log" -w -t 30 start >/dev/null
"${PSQL}" ${PSQL_CONN} -Atq -c "CREATE EXTENSION epistemic;" >/dev/null
"${PSQL}" ${PSQL_CONN} -Atq <<'SQL' >/dev/null
CREATE TABLE fact_meas (entity_id int NOT NULL, attribute text NOT NULL, value text,
    sources text[], valid_time tstzrange, sys_time tstzrange DEFAULT tstzrange(now(),'infinity'),
    ep_kind epistemic.epistemic_kind NOT NULL, ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0) USING epistemic;
CREATE TABLE fact_inf (entity_id int NOT NULL, attribute text NOT NULL, value text,
    sources text[], valid_time tstzrange, sys_time tstzrange DEFAULT tstzrange(now(),'infinity'),
    ep_kind epistemic.epistemic_kind NOT NULL, ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence real NOT NULL DEFAULT 1.0) USING epistemic;
-- Register a source so INFERRED rows can pass R2.
INSERT INTO epistemic.source_registry (source_id, source_type)
VALUES ('r2_bench_src', 'model_inference');
SQL

run_one() {
    local table="$1"
    local kind="$2"
    local n="$3"
    "${PSQL}" ${PSQL_CONN} -v ON_ERROR_STOP=0 -X -Atq -c "TRUNCATE ${table};" >/dev/null 2>&1
    # Time a single-txn insert of N rows. Use \timing on so we get ms with 3 decimals.
    local t
    t=$("${PSQL}" ${PSQL_CONN} -X -Atq 2>&1 <<SQL
\timing on
BEGIN;
INSERT INTO ${table} (entity_id, attribute, value, sources, valid_time,
                     ep_kind, ep_specificity, ep_confidence)
SELECT g,
       'attr_'||g::text,
       'v_'||g::text,
       CASE WHEN '${kind}' = 'INFERRED' THEN ARRAY['r2_bench_src']::text[] ELSE NULL END,
       tstzrange('2026-01-01','infinity'),
       '${kind}'::epistemic.epistemic_kind,
       5::int2,
       CASE WHEN '${kind}' = 'INFERRED' THEN 0.9 ELSE 1.0 END::real
  FROM generate_series(1, ${n}) g;
ROLLBACK;
SQL
)
    # Extract time from "Time: 1234.567 ms" line (the INSERT's timing)
    # The last "Time:" belongs to ROLLBACK; the one before is the INSERT.
    echo "${t}" | awk '/^Time:/ {print $2}' | sed -n '2p'
}

median() {
    python3 -c "import sys, statistics; vs=sorted(float(x) for x in sys.argv[1:]); print(statistics.median(vs))" "$@"
}

echo "R2 microbenchmark: N=${N} rows per replicate, REPS=${REPS} replicates"
echo "dylib_sha256_installed: $(shasum -a 256 /opt/homebrew/lib/postgresql@18/epistemic.dylib | awk '{print $1}')"
echo ""

# Warmup: one throwaway run of each so caches settle.
run_one fact_meas MEASURED "${N}" >/dev/null
run_one fact_inf INFERRED "${N}" >/dev/null

MEAS_TIMES=()
INF_TIMES=()
for r in $(seq 1 ${REPS}); do
    m=$(run_one fact_meas MEASURED "${N}")
    i=$(run_one fact_inf  INFERRED "${N}")
    MEAS_TIMES+=("${m}")
    INF_TIMES+=("${i}")
    echo "rep=${r}  MEASURED_ms=${m}  INFERRED_ms=${i}"
done

echo ""
MEAS_MED_MS=$(median "${MEAS_TIMES[@]}")
INF_MED_MS=$(median "${INF_TIMES[@]}")
echo "MEASURED  median per-INSERT wall-clock (ms) = ${MEAS_MED_MS}"
echo "INFERRED  median per-INSERT wall-clock (ms) = ${INF_MED_MS}"

python3 - <<PY
n = ${N}
meas_ms = ${MEAS_MED_MS}
inf_ms  = ${INF_MED_MS}
meas_us = meas_ms * 1000 / n
inf_us  = inf_ms  * 1000 / n
overhead_us = inf_us - meas_us
overhead_pct = 100.0 * overhead_us / meas_us
print(f"MEASURED per-row = {meas_us:.2f} μs   (paper claim: ~19 μs)")
print(f"INFERRED per-row = {inf_us:.2f} μs")
print(f"R2 overhead      = {overhead_us:.2f} μs   ({overhead_pct:.1f}% of baseline)   (paper claim: ~7 μs, ~35%)")
PY

"${PG_CTL}" -D "${DATADIR}" -m fast stop >/dev/null 2>&1 || true
echo ""
echo "done"
