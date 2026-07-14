#!/usr/bin/env bash
#
# bench/run_stage2.sh — Stage 2 orchestrator for the correctness axis.
#
# Adds four baselines to Stage 1's (epistemic, pg_heap, pg_trigger):
#   * pg_lww   — last-write-wins via partial unique + ON CONFLICT DO UPDATE
#   * pg_llm   — LLM-gated conflict resolver (mock; calibrated latency)
#   * pg_conf  — evidence-weighted / confidence-only merge
#   * pg_mv    — streaming majority-vote / truth-discovery
#
# For each cell the driver reports throughput / latency / abort rate AND
# a correctness rate (fraction of contested slots whose actual survivor
# matches the lattice-predicted maximum), plus goodput.
#
# The primary sweep is (system) × (kind_mix) × (theta) × (clients).
# LLM-gated is capped at 8 clients — the trigger's per-conflict pg_sleep
# collapses higher-concurrency cells.
#
# Environment overrides (all optional):
#   YCSB_DSN                 psycopg DSN
#   YCSB_VENV                Python venv path
#   YCSB_SEED                fixed seed (default 20260712)
#   YCSB_MEAS                measurement seconds per cell (default 30)
#   YCSB_WARMUP              warmup seconds per cell (default 5)
#   YCSB_STAGE2_MODE         "correctness" | "disable_and_test" |
#                            "control" | "all" (default "all")
#   YCSB_LLM_P_CORRECT       calibrated mock LLM correctness rate
#                            (default 0.65)
#   YCSB_LLM_LATENCY_MEAN    mock LLM latency mean in ms (default 300)
#   YCSB_LLM_LATENCY_SIGMA   log-normal sigma (default 0.5)
#
# Bash 3.2 compatible.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="${BENCH_DIR}/driver/correctness.py"
SCHEMA_DIR="${BENCH_DIR}/schema"
RAW_DIR="${BENCH_DIR}/results/stage2_raw"
SUMMARY_DIR="${BENCH_DIR}/results/summary"

YCSB_DSN="${YCSB_DSN:-host=/tmp/kndb_pg18_test port=55480 dbname=postgres}"
YCSB_VENV="${YCSB_VENV:-/tmp/kndb_bench_venv}"
YCSB_SEED="${YCSB_SEED:-20260712}"
YCSB_MEAS="${YCSB_MEAS:-30}"
YCSB_WARMUP="${YCSB_WARMUP:-5}"
YCSB_STAGE2_MODE="${YCSB_STAGE2_MODE:-all}"
YCSB_LLM_P_CORRECT="${YCSB_LLM_P_CORRECT:-0.65}"
YCSB_LLM_LATENCY_MEAN="${YCSB_LLM_LATENCY_MEAN:-300}"
YCSB_LLM_LATENCY_SIGMA="${YCSB_LLM_LATENCY_SIGMA:-0.5}"

PY="${YCSB_VENV}/bin/python3"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@18/bin}"
PSQL="${PGBIN}/psql"

mkdir -p "${RAW_DIR}" "${SUMMARY_DIR}"

log() { printf '[stage2] %s\n' "$*"; }
fail() { printf '[stage2] FAIL: %s\n' "$*" >&2; exit 1; }

# Refuse to run if the installed dylib has diverged from the source
# tree (F13 automation of the F3/F8/F11 recurring incident).
bash "${BENCH_DIR}/../scripts/verify_dylib.sh"

# ---------------------------------------------------------------------
# Load the four new schemas (Stage 1 loads its three from run.sh).
# ---------------------------------------------------------------------
load_stage2_schemas() {
    log "loading Stage 1 schemas (idempotent)"
    for name in epistemic pg_heap pg_trigger; do
        "${PSQL}" "${YCSB_DSN}" -v ON_ERROR_STOP=1 -q \
            -f "${SCHEMA_DIR}/${name}.sql" >/dev/null
    done
    log "loading Stage 2 schemas"
    for name in pg_lww pg_conf pg_mv pg_llm; do
        log "  ${name}"
        "${PSQL}" "${YCSB_DSN}" -v ON_ERROR_STOP=1 -q \
            -f "${SCHEMA_DIR}/${name}.sql" >/dev/null
    done
    log "all schemas loaded"
}

# One-time preseed per system, tracked via SYS_PRESEEDED_<name> shell vars.
preseed_if_needed() {
    local system="$1"
    local flag_var="SYS_PRESEEDED_${system}"
    if [ "${!flag_var:-0}" = "1" ]; then
        return
    fi
    log "  preseeding ${system} (once)"
    local t0 t1
    t0=$(date +%s)
    "${PY}" "${DRIVER}" \
        --dsn "${YCSB_DSN}" \
        --system "${system}" \
        --theta 0.0 --clients 1 \
        --kind-mix moderate \
        --measurement-seconds 0.5 --warmup-seconds 0 \
        --seed "${YCSB_SEED}" --run-index -1 \
        --out "/tmp/kndb_stage2_preseed_${system}.json" \
        >/dev/null 2>&1 || true
    t1=$(date +%s)
    log "  preseed ${system} done in $((t1 - t0)) s"
    eval "${flag_var}=1"
}

# One cell of the correctness axis.
run_cell() {
    local system="$1"
    local kind_mix="$2"
    local theta="$3"
    local clients="$4"
    local run_index="${5:-0}"
    local extra_args="${6:-}"

    preseed_if_needed "${system}"

    local out
    out=$(printf '%s/%s_%s_theta%.2f_c%03d_r%d.json' \
        "${RAW_DIR}" "${system}" "${kind_mix}" \
        "${theta}" "${clients}" "${run_index}")

    log "  cell system=${system} mix=${kind_mix} theta=${theta} c=${clients} run=${run_index} extra=${extra_args}"

    # LLM defaults get overridden by extra_args if present.
    "${PY}" "${DRIVER}" \
        --dsn "${YCSB_DSN}" \
        --system "${system}" \
        --workload ycsb_a \
        --isolation RC \
        --theta "${theta}" \
        --clients "${clients}" \
        --kind-mix "${kind_mix}" \
        --measurement-seconds "${YCSB_MEAS}" \
        --warmup-seconds "${YCSB_WARMUP}" \
        --seed "${YCSB_SEED}" \
        --run-index "${run_index}" \
        --llm-p-correct "${YCSB_LLM_P_CORRECT}" \
        --llm-latency-mean "${YCSB_LLM_LATENCY_MEAN}" \
        --llm-latency-sigma "${YCSB_LLM_LATENCY_SIGMA}" \
        --skip-preseed --reset-between-cells \
        ${extra_args} \
        --out "${out}" >/dev/null 2>&1 || {
            log "    cell FAILED — ${out}"
            return 1
        }

    "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']
c = d['correctness']
print(f'    tps={m[\"throughput_txn_per_s\"]:.1f}  ab={m[\"abort_rate\"]:.3f}  corr={c[\"correctness_rate\"]:.3f}  goodput={d[\"goodput_txn_per_s\"]:.1f}  contested={c[\"contested_slots\"]}  n_live_missing={c[\"missing_live_rows\"]}  n_live_dup={c[\"multiple_live_rows\"]}')
" || true
}

# ---------------------------------------------------------------------
# Correctness centrepiece grid.
# ---------------------------------------------------------------------
# 5 lattice systems (KNDB, LWW, LLM, evidence-weighted, majority-vote).
# 3 kind mixes. 2 concurrency levels (LLM capped at 8).
# 2 thetas (0.5, 0.9). Add pg_heap and pg_trigger for reference.
#
# Grid: 7 systems × 3 mixes × 2 thetas × 2 concurrencies = 84 cells.
# LLM at 32 clients skipped (would collapse). Effective ~78 cells.
run_correctness_grid() {
    log "=== CORRECTNESS GRID ==="
    local system mix theta clients
    for mix in easy moderate adversarial; do
        for theta in 0.5 0.9; do
            for clients in 8 32; do
                for system in epistemic pg_lww pg_conf pg_mv pg_trigger pg_heap; do
                    run_cell "${system}" "${mix}" "${theta}" "${clients}" 0
                done
                if [ "${clients}" -le 8 ]; then
                    run_cell pg_llm "${mix}" "${theta}" "${clients}" 0
                else
                    log "  SKIP pg_llm at clients=${clients} (mock pg_sleep collapses cell)"
                fi
            done
        done
    done
}

# ---------------------------------------------------------------------
# Disable-and-test transcript grid.
# ---------------------------------------------------------------------
run_disable_and_test() {
    log "=== DISABLE-AND-TEST TRANSCRIPTS ==="
    local mix theta clients
    mix=adversarial
    theta=0.9
    clients=8

    log "  KNDB epistemic: reference cell (mechanism on)"
    run_cell epistemic "${mix}" "${theta}" "${clients}" 1

    log "  KNDB epistemic: disable = run pg_heap (no lattice at all)"
    run_cell pg_heap "${mix}" "${theta}" "${clients}" 1

    log "  LLM: reference at P_correct=0.65"
    run_cell pg_llm "${mix}" "${theta}" "${clients}" 1

    log "  LLM: disabled at P_correct=0.5 (random)"
    run_cell pg_llm "${mix}" "${theta}" "${clients}" 2 "--llm-disable-test 1"

    log "  Evidence-weighted: reference (confidence check on)"
    run_cell pg_conf "${mix}" "${theta}" "${clients}" 1

    log "  Evidence-weighted: disable (confidence check off = LWW)"
    run_cell pg_conf "${mix}" "${theta}" "${clients}" 2 "--conf-mode off"

    log "  Majority-vote: reference"
    run_cell pg_mv "${mix}" "${theta}" "${clients}" 1

    log "  Majority-vote: disable (pin vote to 1 = LWW)"
    run_cell pg_mv "${mix}" "${theta}" "${clients}" 2 "--mv-mode off"
}

# ---------------------------------------------------------------------
# Reduced control grid: throughput/latency only, no correctness fuss.
# ---------------------------------------------------------------------
run_control_grid() {
    log "=== CONTROL GRID (throughput/latency, one theta each system) ==="
    local system clients
    for clients in 1 8 32; do
        for system in epistemic pg_lww pg_heap pg_trigger pg_conf pg_mv; do
            run_cell "${system}" moderate 0.9 "${clients}" 3
        done
        if [ "${clients}" -le 8 ]; then
            run_cell pg_llm moderate 0.9 "${clients}" 3
        fi
    done
}

# ---------------------------------------------------------------------
# Summarise Stage 2 results into CSV.
# ---------------------------------------------------------------------
summarise() {
    "${PY}" "${BENCH_DIR}/driver/summarize_stage2.py" \
        --raw "${RAW_DIR}" --out "${SUMMARY_DIR}"
}

# ---------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------
load_stage2_schemas

case "${YCSB_STAGE2_MODE}" in
    correctness)       run_correctness_grid ;;
    disable_and_test)  run_disable_and_test ;;
    control)           run_control_grid ;;
    all)
        run_correctness_grid
        run_disable_and_test
        run_control_grid
        ;;
    *) fail "unknown YCSB_STAGE2_MODE=${YCSB_STAGE2_MODE}" ;;
esac

summarise
log "DONE"
