#!/usr/bin/env bash
#
# scripts_stage3/run_zheng_sybil_f17.sh — F17 Item 1 orchestrator.
#
# Question F17-Item-1 answers: does the F16 Book-Author Sybil result
# (KNDB flat 0.630, all four TD baselines collapsed) generalize to
# Zheng d_sentiment, or is it density-dependent? On F15's coordinated-
# flip attack (which is Sybil-by-construction on binary d_sentiment)
# CRH already resisted at 0.951. F17 adds N=20 (density-saturating:
# 20 honest labels/slot, 20 Sybil labels/slot => 50/50) and re-runs
# under the F17 "sybil" strategy label.
#
# NB: on binary d_sentiment F17 "sybil" is bit-identical to F15
# "flip_binary" (the wrong label is unique), so N=1..10 numbers will
# reproduce F15/F16 exactly. That is the point: this run verifies
# reproducibility AND adds the missing N=20 saturation cell.
#
# Discipline (F15b, restart-per-cell):
#   pg_ctl restart -o "-c shared_preload_libraries=epistemic"
#   before every DB cell. TD cells (offline) do not need PG restarts.
#
# Sweeps:
#   * N in {01, 03, 05, 10, 20}
#   * DB system in {epistemic, pg_conf, pg_lww, pg_mv, pg_heap}  (c=1)
#   * TD system in {truthfinder, crh, catd, accu}
#   * 9 systems x 5 N = 45 cells total
#
# Writes:
#   bench/results/td_raw/zheng_sybil_<system>_c001_N<NN>.json  (DB)
#   bench/results/td_raw/zheng_sybil_<algo>_N<NN>.json         (TD)

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="${BENCH_DIR}/results/td_raw"
DS_ROOT="${BENCH_DIR}/datasets/zheng_sentiment"
SRC_DIR="${DS_ROOT}/source"
PG_DATA="${PG_DATA:-/tmp/kndb_pg18_test}"
PG_PORT="${PG_PORT:-55480}"
YCSB_DSN="${YCSB_DSN:-host=/tmp/kndb_pg18_test port=${PG_PORT} dbname=postgres}"
YCSB_VENV="${YCSB_VENV:-/tmp/kndb_bench_venv}"
PY="${YCSB_VENV}/bin/python3"
PG_CTL="${PG_CTL:-/opt/homebrew/opt/postgresql@18/bin/pg_ctl}"

mkdir -p "${RAW_DIR}"

bash "${BENCH_DIR}/../scripts/verify_dylib.sh"

log() { printf '[f17-item1] %s\n' "$*"; }

restart_pg() {
    # The persistent test cluster has no postgresql.conf preload, and
    # pg_ctl -o REPLACES argv, so we must repeat port and socket dir
    # here or the server comes up on the default port on a different
    # socket path.
    "${PG_CTL}" -D "${PG_DATA}" \
        -o "-c shared_preload_libraries=epistemic -c port=${PG_PORT} -c unix_socket_directories=${PG_DATA}" \
        restart -w -s >/dev/null 2>&1 || {
        log "  pg_ctl restart FAILED"
        return 1
    }
}

K=45
N_VALUES="${N_VALUES:-01 03 05 10 20}"
DB_SYSTEMS="${DB_SYSTEMS:-epistemic pg_conf pg_lww pg_mv pg_heap}"
TD_ALGOS="${TD_ALGOS:-truthfinder crh catd accu}"
C=1

# --------------------------------------------------------------------
# 1) DB systems (restart per cell)
# --------------------------------------------------------------------

log "=== DB grid: 5 systems x 5 N (restart-per-cell) ==="
for N in ${N_VALUES}; do
    trace="${DS_ROOT}/normalized_f17_K${K}_sybil_N${N}.jsonl"
    if [ ! -f "${trace}" ]; then
        log "MISSING trace ${trace}"; exit 2
    fi
    for S in ${DB_SYSTEMS}; do
        out="${RAW_DIR}/zheng_sybil_${S}_c$(printf '%03d' ${C})_N${N}.json"
        log "DB   N=${N} sys=${S}"
        restart_pg
        "${PY}" "${BENCH_DIR}/driver/replay_dataset.py" \
            --dsn "${YCSB_DSN}" \
            --dataset zheng_sentiment \
            --trace "${trace}" \
            --system "${S}" --clients ${C} \
            --isolation SR \
            --out "${out}" >/dev/null 2>&1 || {
                log "  FAILED DB N=${N} sys=${S}"
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

# --------------------------------------------------------------------
# 2) TD algorithms (offline, no PG restart needed)
# --------------------------------------------------------------------

log "=== TD grid: 4 algos x 5 N (offline) ==="
for N in ${N_VALUES}; do
    trace="${DS_ROOT}/normalized_f17_K${K}_sybil_N${N}.jsonl"
    for A in ${TD_ALGOS}; do
        out="${RAW_DIR}/zheng_sybil_${A}_N${N}.json"
        log "TD   N=${N} algo=${A}"
        "${PY}" "${BENCH_DIR}/scripts_td/run_td_offline.py" \
            --trace "${trace}" \
            --dataset zheng_sentiment \
            --algorithm "${A}" \
            --out "${out}" >/dev/null 2>&1 || {
                log "  FAILED TD N=${N} algo=${A}"
                continue
            }
        "${PY}" -c "
import json
d = json.load(open('${out}'))
c = d['correctness']
print(f\"  algo=${A}  prec={c.get('Precision',c.get('AA',0)):.3f}  n_items={d['n_items']}  n_sources={d['n_sources']}  elapsed={d['metrics']['elapsed_s']:.2f}s\")
"
    done
done

log "DONE"
