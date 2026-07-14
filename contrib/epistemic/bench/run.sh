#!/usr/bin/env bash
#
# bench/run.sh — orchestrator for the YCSB microbenchmark.
#
# Loads the three schemas onto the cluster referenced by ${PGHOST}/${PGPORT}
# (or the default at /tmp/kndb_pg18_test:55480), runs the validation gate,
# and — if the gate passes — sweeps the primary grid. Each cell writes one
# JSON to bench/results/raw/. Summaries roll up in bench/results/summary/.
#
# The driver is bench/driver/ycsb.py; see its module docstring for what
# each metric means and how the workload is shaped.
#
# Environment:
#   YCSB_DSN                psycopg DSN string (default: unix socket at
#                           /tmp/kndb_pg18_test, port 55480, db postgres)
#   YCSB_VENV               Python venv with psycopg installed
#                           (default: /tmp/kndb_bench_venv)
#   YCSB_SEED               PRNG seed (default: 20260712)
#   YCSB_MEAS               measurement seconds per cell (default: 30)
#   YCSB_WARMUP             warmup seconds per cell (default: 5)
#   YCSB_RUNS               runs per cell (default: 3)
#   YCSB_MODE               "gate" | "primary" | "secondary_b" |
#                           "secondary_sr" | "openloop" | "all"
#                           (default: "all")
#
# Bash 3.2 compatible (macOS default). No GNU-only flags.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="${BENCH_DIR}/driver/ycsb.py"
SCHEMA_DIR="${BENCH_DIR}/schema"
RAW_DIR="${BENCH_DIR}/results/raw"
SUMMARY_DIR="${BENCH_DIR}/results/summary"

YCSB_DSN="${YCSB_DSN:-host=/tmp/kndb_pg18_test port=55480 dbname=postgres}"
YCSB_VENV="${YCSB_VENV:-/tmp/kndb_bench_venv}"
YCSB_SEED="${YCSB_SEED:-20260712}"
YCSB_MEAS="${YCSB_MEAS:-30}"
YCSB_WARMUP="${YCSB_WARMUP:-5}"
YCSB_RUNS="${YCSB_RUNS:-3}"
YCSB_MODE="${YCSB_MODE:-all}"

PY="${YCSB_VENV}/bin/python3"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PSQL="${PGBIN}/psql"

mkdir -p "${RAW_DIR}" "${SUMMARY_DIR}"

log() { printf '[bench] %s\n' "$*"; }
fail() { printf '[bench] FAIL: %s\n' "$*" >&2; exit 1; }

# Refuse to run if the installed dylib has diverged from the source
# tree (F13 automation of the F3/F8/F11 recurring incident).
bash "${BENCH_DIR}/../scripts/verify_dylib.sh"

# ---------------------------------------------------------------------
# Setup: install extension, create three tables, register sources.
# ---------------------------------------------------------------------
load_schemas() {
    log "loading schemas from ${SCHEMA_DIR}"
    for name in epistemic pg_heap pg_trigger; do
        log "  ${name}"
        "${PSQL}" "${YCSB_DSN}" -v ON_ERROR_STOP=1 -q \
            -f "${SCHEMA_DIR}/${name}.sql" >/dev/null
    done
    log "schemas loaded"
}

# Preseed is expensive (esp. for pg_trigger and epistemic); we preseed
# once per system per grid and reset workload state between cells with
# a cheap DELETE + UPDATE + VACUUM path (tuple_delete and tuple_update
# are heap's on the epistemic AM, so this path bypasses R1..R5).
#
# preseed_once tracks whether the target table already has the preseed
# rows loaded for this system. If not, the first call primes it.
declare -a PRESEEDED
preseed_if_needed() {
    local system="$1"
    local flag
    case "${system}" in
        epistemic)  flag="PRESEEDED_epistemic"  ;;
        pg_heap)    flag="PRESEEDED_pg_heap"    ;;
        pg_trigger) flag="PRESEEDED_pg_trigger" ;;
        *)          fail "unknown system ${system}" ;;
    esac
    if [ "${!flag:-0}" = "1" ]; then
        return
    fi
    log "  preseeding ${system} (once)"
    local t0 t1
    t0=$(date +%s)
    "${PY}" "${DRIVER}" \
        --dsn "${YCSB_DSN}" \
        --system "${system}" \
        --workload ycsb_a --isolation RC \
        --theta 0.0 --clients 1 \
        --measurement-seconds 1 --warmup-seconds 0 \
        --seed "${YCSB_SEED}" --run-index -1 \
        --out "/tmp/kndb_preseed_probe.json" \
        --preseed-only \
        2>&1 | tail -3
    t1=$(date +%s)
    log "  preseed ${system} done in $((t1 - t0)) s"
    eval "${flag}=1"
}

# One cell: (system, workload, isolation, theta, clients, run_index).
run_cell() {
    local system="$1"
    local workload="$2"
    local isolation="$3"
    local theta="$4"
    local clients="$5"
    local run_index="$6"

    preseed_if_needed "${system}"

    local out
    out=$(printf '%s/%s_%s_%s_theta%.2f_c%03d_r%d.json' \
        "${RAW_DIR}" "${system}" "${workload}" "${isolation}" \
        "${theta}" "${clients}" "${run_index}")

    log "  cell system=${system} workload=${workload} isolation=${isolation} theta=${theta} clients=${clients} run=${run_index}"

    "${PY}" "${DRIVER}" \
        --dsn "${YCSB_DSN}" \
        --system "${system}" \
        --workload "${workload}" \
        --isolation "${isolation}" \
        --theta "${theta}" \
        --clients "${clients}" \
        --measurement-seconds "${YCSB_MEAS}" \
        --warmup-seconds "${YCSB_WARMUP}" \
        --seed "${YCSB_SEED}" \
        --run-index "${run_index}" \
        --out "${out}" \
        --skip-preseed --reset-between-cells >/dev/null || {
            log "    cell FAILED — see ${out}.log"
            return 1
        }

    # Extract headline throughput for the console log.
    "${PY}" -c "
import json, sys
d = json.load(open('${out}'))
m = d['metrics']
print(f'    tps={m[\"throughput_txn_per_s\"]:.1f}  abort={m[\"abort_rate\"]:.3f}  p99={m[\"latency_ms\"][\"p99\"]:.2f}ms  n={m[\"latency_ms\"][\"count\"]}')" || true
}

# ---------------------------------------------------------------------
# Validation gate. Two probes; both must pass before we run the sweep.
# ---------------------------------------------------------------------
run_gate() {
    log "=== VALIDATION GATE ==="
    log "gate 1: pg_heap Zipfian contention curve at 8 clients, ${YCSB_RUNS} runs"

    local gate_theta run
    for gate_theta in 0.0 0.5 0.9 0.99; do
        for run in $(seq 0 $(( YCSB_RUNS - 1 ))); do
            run_cell pg_heap ycsb_a RC "${gate_theta}" 8 "${run}"
        done
    done

    log "gate 2: epistemic vs pg_heap overhead at theta ∈ {0.0, 0.5}, 8 clients, ${YCSB_RUNS} runs"
    for gate_theta in 0.0 0.5; do
        for run in $(seq 0 $(( YCSB_RUNS - 1 ))); do
            run_cell epistemic ycsb_a RC "${gate_theta}" 8 "${run}"
        done
    done

    log "gate summary — check bench/results/summary/gate.csv after run"
    "${PY}" "${BENCH_DIR}/driver/summarize.py" \
        --raw "${RAW_DIR}" --out "${SUMMARY_DIR}" --scope gate
}

# ---------------------------------------------------------------------
# Primary grid: YCSB-A × RC × 6 thetas × 7 concurrencies × 3 systems ×
#               YCSB_RUNS runs.
# ---------------------------------------------------------------------
run_primary() {
    log "=== PRIMARY GRID: YCSB-A × RC ==="
    local theta clients system run
    for theta in 0.0 0.5 0.6 0.8 0.9 0.99; do
        for clients in 1 2 4 8 16 32 64; do
            for system in pg_heap epistemic pg_trigger; do
                for run in $(seq 0 $(( YCSB_RUNS - 1 ))); do
                    run_cell "${system}" ycsb_a RC "${theta}" "${clients}" "${run}"
                done
            done
        done
    done
    "${PY}" "${BENCH_DIR}/driver/summarize.py" \
        --raw "${RAW_DIR}" --out "${SUMMARY_DIR}" --scope primary
}

# ---------------------------------------------------------------------
# Secondary grids.
# ---------------------------------------------------------------------
run_secondary_b() {
    log "=== SECONDARY GRID: YCSB-B × RC ==="
    local theta clients system
    for theta in 0.0 0.8 0.99; do
        for clients in 8 32; do
            for system in pg_heap epistemic pg_trigger; do
                run_cell "${system}" ycsb_b RC "${theta}" "${clients}" 0
            done
        done
    done
    "${PY}" "${BENCH_DIR}/driver/summarize.py" \
        --raw "${RAW_DIR}" --out "${SUMMARY_DIR}" --scope secondary_b
}

run_secondary_sr() {
    log "=== SECONDARY GRID: YCSB-A × SR ==="
    local theta clients system
    for theta in 0.0 0.8 0.99; do
        for clients in 8 32; do
            for system in pg_heap epistemic pg_trigger; do
                run_cell "${system}" ycsb_a SR "${theta}" "${clients}" 0
            done
        done
    done
    "${PY}" "${BENCH_DIR}/driver/summarize.py" \
        --raw "${RAW_DIR}" --out "${SUMMARY_DIR}" --scope secondary_sr
}

# ---------------------------------------------------------------------
# Open-loop probe: one cell, closed-loop is closed-loop even under the
# YCSB spec, so we hand this off to a dedicated driver.
# ---------------------------------------------------------------------
run_openloop() {
    log "=== OPEN-LOOP PROBE ==="
    local out="${RAW_DIR}/openloop_epistemic_theta0.99_c32.json"
    "${PY}" "${BENCH_DIR}/driver/openloop.py" \
        --dsn "${YCSB_DSN}" \
        --system epistemic --theta 0.99 --clients 32 \
        --target-rate 1000 --isolation RC \
        --measurement-seconds "${YCSB_MEAS}" \
        --warmup-seconds "${YCSB_WARMUP}" \
        --seed "${YCSB_SEED}" \
        --out "${out}" || log "openloop probe failed — see log"
}

# ---------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------
load_schemas

case "${YCSB_MODE}" in
    gate)          run_gate ;;
    primary)       run_primary ;;
    secondary_b)   run_secondary_b ;;
    secondary_sr)  run_secondary_sr ;;
    openloop)      run_openloop ;;
    all)
        run_gate
        run_primary
        run_secondary_b
        run_secondary_sr
        run_openloop
        ;;
    *) fail "unknown YCSB_MODE=${YCSB_MODE}" ;;
esac

log "DONE"
