#!/usr/bin/env bash
#
# bench/run_stage3.sh — F12 orchestrator for Stage 3.
#
# Task 3a: 500 real-LLM non-determinism probe calls.
#          scripts_stage3/llm_nondeterminism.py.
# Task 3b: dataset fetch + normalization for MemoryAgentBench /
#          LongMemEval / MQuAKE (datasets/normalize.py).
# Task 3c: replay each dataset against 7 systems at c={1,8,32} SR.
#
# Environment:
#   YCSB_DSN                default host=/tmp/kndb_pg18_test port=55480 dbname=postgres
#   YCSB_VENV               default /tmp/kndb_bench_venv
#   ANTHROPIC_API_KEY       required for Task 3a and pg_llm cells
#   YCSB_STAGE3_MODE        default all; also: nondet | datasets | replay
#   YCSB_MAX_WRITES         cap the trace size uniformly (default: no cap)
#   YCSB_MAX_WRITES_PG_LLM  cap trace size for pg_llm cells (default 300)
#
# Bash 3.2 compatible.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_DIR="${BENCH_DIR}/results/stage3_raw"
SUMMARY_DIR="${BENCH_DIR}/results/summary"

YCSB_DSN="${YCSB_DSN:-host=/tmp/kndb_pg18_test port=55480 dbname=postgres}"
YCSB_VENV="${YCSB_VENV:-/tmp/kndb_bench_venv}"
YCSB_STAGE3_MODE="${YCSB_STAGE3_MODE:-all}"
YCSB_MAX_WRITES="${YCSB_MAX_WRITES:-}"
YCSB_MAX_WRITES_PG_LLM="${YCSB_MAX_WRITES_PG_LLM:-300}"

PY="${YCSB_VENV}/bin/python3"

mkdir -p "${RAW_DIR}" "${SUMMARY_DIR}"

log()  { printf '[stage3] %s\n' "$*"; }
fail() { printf '[stage3] FAIL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# Task 3a: LLM non-determinism probe.
# ---------------------------------------------------------------------
run_nondet() {
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        fail "ANTHROPIC_API_KEY required for Task 3a"
    fi
    log "=== TASK 3a: LLM non-determinism probe ==="
    "${PY}" "${BENCH_DIR}/scripts_stage3/llm_nondeterminism.py" \
        --calibration "${BENCH_DIR}/results/stage3_llm_calibration.jsonl" \
        --n-conflicts 50 --n-replays 10 \
        --raw-out "${BENCH_DIR}/results/stage3_llm_nondeterminism_raw.jsonl" \
        --summary-out "${BENCH_DIR}/results/stage3_llm_nondeterminism_summary.json" \
        --concurrency 8
}

# ---------------------------------------------------------------------
# Task 3b: dataset fetch + normalization.
# ---------------------------------------------------------------------
run_datasets() {
    log "=== TASK 3b: dataset fetch + normalization ==="
    # Fetches (idempotent — clones only if missing).
    for d in memoryagentbench longmemeval mquake; do
        mkdir -p "${BENCH_DIR}/datasets/${d}/source"
    done
    if [ ! -d "${BENCH_DIR}/datasets/memoryagentbench/source/MemoryAgentBench" ]; then
        log "  cloning MemoryAgentBench ..."
        (cd "${BENCH_DIR}/datasets/memoryagentbench/source" && \
         git clone https://github.com/HUST-AI-HYZ/MemoryAgentBench.git)
    fi
    if [ ! -d "${BENCH_DIR}/datasets/longmemeval/source/LongMemEval" ]; then
        log "  cloning LongMemEval ..."
        (cd "${BENCH_DIR}/datasets/longmemeval/source" && \
         git clone https://github.com/xiaowu0162/LongMemEval.git)
    fi
    if [ ! -f "${BENCH_DIR}/datasets/longmemeval/source/longmemeval_oracle.json" ]; then
        log "  fetching LongMemEval oracle ..."
        curl -sL -o "${BENCH_DIR}/datasets/longmemeval/source/longmemeval_oracle.json" \
            'https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_oracle.json?download=true'
    fi
    if [ ! -d "${BENCH_DIR}/datasets/mquake/source/MQuAKE" ]; then
        log "  cloning MQuAKE ..."
        (cd "${BENCH_DIR}/datasets/mquake/source" && \
         git clone https://github.com/princeton-nlp/MQuAKE.git)
    fi

    log "  normalizing MemoryAgentBench ..."
    "${PY}" "${BENCH_DIR}/datasets/normalize.py" \
        --dataset memoryagentbench \
        --source "${BENCH_DIR}/datasets/memoryagentbench/source/MemoryAgentBench" \
        --out    "${BENCH_DIR}/datasets/memoryagentbench/normalized.jsonl" >/dev/null

    log "  normalizing LongMemEval ..."
    "${PY}" "${BENCH_DIR}/datasets/normalize.py" \
        --dataset longmemeval \
        --source "${BENCH_DIR}/datasets/longmemeval/source/longmemeval_oracle.json" \
        --out    "${BENCH_DIR}/datasets/longmemeval/normalized.jsonl" >/dev/null

    log "  normalizing MQuAKE ..."
    "${PY}" "${BENCH_DIR}/datasets/normalize.py" \
        --dataset mquake \
        --source "${BENCH_DIR}/datasets/mquake/source/MQuAKE/datasets/MQuAKE-CF-3k.json" \
        --out    "${BENCH_DIR}/datasets/mquake/normalized.jsonl" >/dev/null
    log "  datasets ready."
}

# ---------------------------------------------------------------------
# Task 3c: replay the 63 cells.
# ---------------------------------------------------------------------
run_replay_cell() {
    local dataset="$1"
    local system="$2"
    local clients="$3"

    local trace="${BENCH_DIR}/datasets/${dataset}/normalized.jsonl"
    if [ ! -f "${trace}" ]; then
        log "  MISSING TRACE ${trace} — skipping cell"
        return
    fi
    local out
    out=$(printf '%s/%s_%s_c%03d.json' "${RAW_DIR}" \
        "${dataset}" "${system}" "${clients}")

    log "  cell dataset=${dataset} system=${system} c=${clients}"
    local extra=""
    if [ -n "${YCSB_MAX_WRITES}" ]; then
        extra="--max-writes ${YCSB_MAX_WRITES}"
    fi

    "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
        --dsn "${YCSB_DSN}" \
        --dataset "${dataset}" \
        --trace "${trace}" \
        --system "${system}" \
        --clients "${clients}" \
        --isolation SR \
        --max-writes-pg-llm "${YCSB_MAX_WRITES_PG_LLM}" \
        ${extra} \
        --out "${out}" >/dev/null 2>&1 || {
            log "    cell FAILED — see ${out}"
            return 1
        }
    "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']; c = d['correctness']
extras = ''
if 'CRS_KU_Acc' in c: extras += f\"  CRS={c['CRS_KU_Acc']:.3f}\"
if 'UOCS'       in c: extras += f\"  UOCS={c['UOCS']:.3f}\"
print(f\"    n_w={d['n_writes_attempted']:6d}  tps={m['throughput_writes_per_s']:8.1f}  ab={m['abort_rate']:.3f}  AA={c['AA']:.3f}  goodput={d['goodput_correct_writes_per_s']:8.1f}\" + extras)
" || true
}

run_replay_grid() {
    log "=== TASK 3c: 63-cell dataset replay grid ==="
    for dataset in memoryagentbench longmemeval mquake; do
        for clients in 1 8 32; do
            for system in epistemic pg_heap pg_trigger pg_lww pg_conf pg_mv; do
                run_replay_cell "${dataset}" "${system}" "${clients}"
            done
            # pg_llm is expensive: use the subsample cap, always run
            # at every concurrency for completeness. The 300-write cap
            # keeps c=32 tractable (~30s per cell).
            run_replay_cell "${dataset}" pg_llm "${clients}"
        done
    done
}

# ---------------------------------------------------------------------
# Summariser.
# ---------------------------------------------------------------------
run_summary() {
    "${PY}" "${BENCH_DIR}/scripts_stage3/summarize_stage3.py" \
        --raw "${RAW_DIR}" --out "${SUMMARY_DIR}"
}

# ---------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------
case "${YCSB_STAGE3_MODE}" in
    nondet)    run_nondet ;;
    datasets)  run_datasets ;;
    replay)    run_replay_grid; run_summary ;;
    summary)   run_summary ;;
    all)
        run_nondet
        run_datasets
        run_replay_grid
        run_summary
        ;;
    *) fail "unknown YCSB_STAGE3_MODE=${YCSB_STAGE3_MODE}" ;;
esac
log "DONE"
