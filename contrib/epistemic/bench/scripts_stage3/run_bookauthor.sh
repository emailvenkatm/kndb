#!/usr/bin/env bash
#
# scripts_stage3/run_bookauthor.sh — F13 Task 2 orchestrator.
#
# Sweeps the Dong Book-Author dataset across:
#   * K in {10, 25, 50, 100, 200}          (top-K by n_listings — the
#                                            documented, pre-truth
#                                            source-tier proxy)
#   * system in {epistemic, pg_heap, pg_trigger, pg_lww, pg_conf,
#                pg_mv, pg_llm}
#   * clients in {1, 8, 32}                (SR isolation)
#
# Writes one JSON per cell to bench/results/stage3_raw/
# bookauthor_<system>_c<NNN>_K<NNN>.json. pg_llm is capped at 300
# writes and c=1 only (cost).
#
# Bash 3.2 compatible.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="${BENCH_DIR}/results/stage3_raw"
DS_ROOT="${BENCH_DIR}/datasets/bookauthor"
SRC_DIR="${DS_ROOT}/source"
YCSB_DSN="${YCSB_DSN:-host=/tmp/kndb_pg18_test port=55480 dbname=postgres}"
YCSB_VENV="${YCSB_VENV:-/tmp/kndb_bench_venv}"
PY="${YCSB_VENV}/bin/python3"

mkdir -p "${RAW_DIR}"

# Refuse to run if the installed dylib has diverged from the source
# tree (F13 automation of the F3/F8/F11 recurring incident).
bash "${BENCH_DIR}/../scripts/verify_dylib.sh"

log() { printf '[ba] %s\n' "$*"; }

K_VALUES="10 25 50 100 200"
SYSTEMS="epistemic pg_heap pg_trigger pg_lww pg_conf pg_mv"
CLIENTS="1 8 32"

for K in ${K_VALUES}; do
    trace="${DS_ROOT}/normalized_K$(printf '%03d' ${K}).jsonl"
    log "normalize K=${K} -> ${trace}"
    "${PY}" "${BENCH_DIR}/datasets/normalize.py" \
        --dataset bookauthor --source "${SRC_DIR}" \
        --out "${trace}" --top-k ${K} >/dev/null

    for C in ${CLIENTS}; do
        for S in ${SYSTEMS}; do
            out=$(printf '%s/bookauthor_%s_c%03d_K%03d.json' \
                "${RAW_DIR}" "${S}" "${C}" "${K}")
            log "cell K=${K} sys=${S} c=${C}"
            "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
                --dsn "${YCSB_DSN}" \
                --dataset bookauthor \
                --trace "${trace}" \
                --system "${S}" --clients "${C}" \
                --isolation SR \
                --out "${out}" >/dev/null 2>&1 || {
                    log "  FAILED cell K=${K} sys=${S} c=${C}"
                    continue
                }
            "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']; c = d['correctness']
print(f\"  n_w={d['n_writes_attempted']:5d}  tps={m['throughput_writes_per_s']:8.1f}  ab={m['abort_rate']:.3f}  AA={c['AA']:.3f}  prec={c.get('Precision',0):.3f}\")
"
        done

        # pg_llm only at c=1 AND K=50 (the reference / median K).
        # Full K sweep for pg_llm would be ~30 min just for LLM cells
        # and adds no lift to the sensitivity story — the LLM's
        # correctness is Bernoulli(0.925) and doesn't consult the
        # source tiering. One reference cell suffices.
        if [ "${C}" = "1" ] && [ "${K}" = "50" ]; then
            out=$(printf '%s/bookauthor_pg_llm_c%03d_K%03d.json' \
                "${RAW_DIR}" "${C}" "${K}")
            log "cell K=${K} sys=pg_llm c=${C} (capped 300)"
            "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
                --dsn "${YCSB_DSN}" \
                --dataset bookauthor \
                --trace "${trace}" \
                --system pg_llm --clients 1 \
                --isolation SR \
                --max-writes-pg-llm 300 \
                --out "${out}" >/dev/null 2>&1 || {
                    log "  FAILED cell K=${K} sys=pg_llm c=${C}"
                    continue
                }
            "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']; c = d['correctness']
print(f\"  n_w={d['n_writes_attempted']:5d}  tps={m['throughput_writes_per_s']:8.1f}  ab={m['abort_rate']:.3f}  AA={c['AA']:.3f}  prec={c.get('Precision',0):.3f}\")
"
        fi
    done
done

log "DONE"
