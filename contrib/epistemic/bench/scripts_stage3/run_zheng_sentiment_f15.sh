#!/usr/bin/env bash
#
# scripts_stage3/run_zheng_sentiment_f15.sh — F15 replication of F14's
# confidence-forgery result on Zheng VLDB'17 d_sentiment.
#
# Pre-registered mapping: bench/datasets/zheng_sentiment/README.md.
# Ground-truth policy (does NOT adapt): MEASURED beats INFERRED
# regardless of confidence — the paper's epistemic claim.
#
# Sweeps:
#   * K in {12, 24, 45, 66, 85}       (baseline sensitivity, N=0)
#   * N in {1, 3, 5, 10}                (adversarial, fixed K=45)
#   * system in {epistemic, pg_heap, pg_trigger, pg_lww, pg_conf,
#                pg_mv, pg_llm}    (pg_llm at c=1 N=5 only)
#   * clients in {1, 8}                 (SR isolation)
#
# Writes one JSON per cell to bench/results/stage3_raw/
# adversarial_zheng_<system>_c<NNN>_N<NN>.json
# baseline_zheng_<system>_c<NNN>_K<KKK>.json
#
# Bash 3.2 compatible.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="${BENCH_DIR}/results/stage3_raw"
DS_ROOT="${BENCH_DIR}/datasets/zheng_sentiment"
SRC_DIR="${DS_ROOT}/source"
YCSB_DSN="${YCSB_DSN:-host=/tmp/kndb_pg18_test port=55480 dbname=postgres}"
YCSB_VENV="${YCSB_VENV:-/tmp/kndb_bench_venv}"
PY="${YCSB_VENV}/bin/python3"

mkdir -p "${RAW_DIR}"

bash "${BENCH_DIR}/../scripts/verify_dylib.sh"

log() { printf '[f15] %s\n' "$*"; }

# --------------------------------------------------------------------
# Baseline sensitivity (N=0) across K.
# --------------------------------------------------------------------

K_VALUES="${K_VALUES:-12 24 45 66 85}"
K_ADV=45                                     # fixed K for adversarial sweep
N_VALUES="${N_VALUES:-1 3 5 10}"
SYSTEMS="${SYSTEMS:-epistemic pg_heap pg_trigger pg_lww pg_conf pg_mv}"
CLIENTS="${CLIENTS:-1 8}"

log "=== Baseline sensitivity (N=0) across K ==="
for K in ${K_VALUES}; do
    trace="${DS_ROOT}/normalized_f15_K$(printf '%03d' ${K})_N00.jsonl"
    log "normalize K=${K} N=0 -> ${trace}"
    "${PY}" "${BENCH_DIR}/datasets/normalize.py" \
        --dataset zheng_sentiment_f15 --source "${SRC_DIR}" \
        --out "${trace}" --top-k ${K} --n-adversarial 0 \
        --adv-seed 20260715 >/dev/null

    for C in ${CLIENTS}; do
        for S in ${SYSTEMS}; do
            out=$(printf '%s/baseline_zheng_%s_c%03d_K%03d.json' \
                "${RAW_DIR}" "${S}" "${C}" "${K}")
            log "baseline K=${K} sys=${S} c=${C}"
            "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
                --dsn "${YCSB_DSN}" \
                --dataset zheng_sentiment \
                --trace "${trace}" \
                --system "${S}" --clients "${C}" \
                --isolation SR \
                --out "${out}" >/dev/null 2>&1 || {
                    log "  FAILED baseline K=${K} sys=${S} c=${C}"
                    continue
                }
            "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']; c = d['correctness']; integ = c.get('integrity',{})
st = integ.get('integrity_status','?')
print(f\"  n_w={d['n_writes_attempted']:5d}  tps={m['throughput_writes_per_s']:8.1f}  ab={m['abort_rate']:.3f}  prec={c.get('Precision',c.get('AA',0)):.3f}  integ={st}  n_gt1={integ.get('n_slots_with_gt_1_live','?')}\")
"
        done
    done
done

# --------------------------------------------------------------------
# Adversarial sweep at fixed K.
# --------------------------------------------------------------------

log "=== Adversarial sweep at K=${K_ADV} across N ==="
for N in ${N_VALUES}; do
    trace="${DS_ROOT}/normalized_f15_K$(printf '%03d' ${K_ADV})_N$(printf '%02d' ${N}).jsonl"
    log "normalize K=${K_ADV} N=${N} -> ${trace}"
    "${PY}" "${BENCH_DIR}/datasets/normalize.py" \
        --dataset zheng_sentiment_f15 --source "${SRC_DIR}" \
        --out "${trace}" --top-k ${K_ADV} --n-adversarial ${N} \
        --adv-seed 20260715 >/dev/null

    for C in ${CLIENTS}; do
        for S in ${SYSTEMS}; do
            out=$(printf '%s/adversarial_zheng_%s_c%03d_N%02d.json' \
                "${RAW_DIR}" "${S}" "${C}" "${N}")
            log "adv N=${N} sys=${S} c=${C}"
            "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
                --dsn "${YCSB_DSN}" \
                --dataset zheng_sentiment \
                --trace "${trace}" \
                --system "${S}" --clients "${C}" \
                --isolation SR \
                --out "${out}" >/dev/null 2>&1 || {
                    log "  FAILED adv N=${N} sys=${S} c=${C}"
                    continue
                }
            "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']; c = d['correctness']; integ = c.get('integrity',{})
st = integ.get('integrity_status','?')
print(f\"  n_w={d['n_writes_attempted']:5d}  tps={m['throughput_writes_per_s']:8.1f}  ab={m['abort_rate']:.3f}  prec={c.get('Precision',c.get('AA',0)):.3f}  integ={st}  n_gt1={integ.get('n_slots_with_gt_1_live','?')}\")
"
        done

        # pg_llm only at N=5, c=1 (cost).
        if [ "${C}" = "1" ] && [ "${N}" = "5" ]; then
            out=$(printf '%s/adversarial_zheng_pg_llm_c%03d_N%02d.json' \
                "${RAW_DIR}" "${C}" "${N}")
            log "adv N=${N} sys=pg_llm c=${C} (capped 300)"
            "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
                --dsn "${YCSB_DSN}" \
                --dataset zheng_sentiment \
                --trace "${trace}" \
                --system pg_llm --clients 1 \
                --isolation SR \
                --max-writes-pg-llm 300 \
                --out "${out}" >/dev/null 2>&1 || {
                    log "  FAILED adv N=${N} sys=pg_llm c=${C}"
                    continue
                }
            "${PY}" -c "
import json
d = json.load(open('${out}'))
m = d['metrics']; c = d['correctness']; integ = c.get('integrity',{})
print(f\"  n_w={d['n_writes_attempted']:5d}  tps={m['throughput_writes_per_s']:8.1f}  ab={m['abort_rate']:.3f}  prec={c.get('Precision',c.get('AA',0)):.3f}  integ={integ.get('integrity_status','?')}\")
"
        fi
    done
done

log "DONE"
