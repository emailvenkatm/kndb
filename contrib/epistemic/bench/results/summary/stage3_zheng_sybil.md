# Stage 3 F17 Item 1: Zheng d_sentiment Sybil-N sweep (density-saturation test)

**Gate question**: F16 showed that on Book-Author under a Sybil attack
(all N adversarial agents share the same wrong value per gold ISBN)
KNDB stays flat at 0.630 while every TD baseline collapses at N=10
(TruthFinder 0.010, CATD 0.100, ACCU 0.060, CRH 0.230 — the most
robust and still 35pp below its honest baseline). On F15's Zheng
coordinated-flip (which is Sybil-by-binary-construction) CRH held
at 0.951 through N=10 — essentially matching KNDB (0.927).

The paper-shaping question F17 Item 1 asks: does the Book-Author
Sybil result generalize to Zheng, or is it a Zipfian/sparse-source
artifact? Specifically, is CRH's flat 0.951-on-Zheng a
**density-dominance** effect (20 honest votes always outnumber any N
Sybils) or a **density-limited** effect (holds until Sybils saturate
the per-slot label pool)?

Zheng d_sentiment has exactly 20 honest labels per slot (verified:
1000 questions, 85 workers, mean 20.0 labels/q). The density-saturating
test is therefore N=20 — Sybils equal honest voters, one-for-one.
F17 Item 1 adds this cell.

## 1. Preconditions

**Dylib guard**: `bash contrib/epistemic/scripts/verify_dylib.sh`
exit 0. SHA-256 = `807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74`
(matches DECISIONS.md F13 pin).

**Working tree state at start of F17 Item 1**:

  * Branch `postgres-experiment`, HEAD `f70ad2f` (F15 pushed).
  * F16 uncommitted on disk:
    - `contrib/epistemic/bench/scripts_td/{td_algorithms,run_td_offline,td_disable_and_test}.py`
    - `contrib/epistemic/bench/datasets/normalize.py` (Book-Author
      `--adv-strategy sybil`, K=50 F16 traces, td_raw/ Book-Author
      Sybil grid + F14 independent-value grid + Zheng flip grid)
    - `contrib/epistemic/bench/results/summary/stage3_td_baselines.md`
  * `src/` byte-identical to HEAD.

**Sybil trace generation for Zheng** (Item 1a):

Added `--adv-strategy` flow-through to `normalize_zheng_sentiment_f15`
in `bench/datasets/normalize.py`. On binary d_sentiment the F17
"sybil" strategy is by construction identical to F15's
"flip_binary" strategy — the wrong label is unique. The addition
tags the trace records with `dataset_metadata.strategy=="sybil"` so
F17 outputs are distinguishable from F15 outputs in downstream
tooling, and lets the F16-parity grid share the CLI shape.

Traces written to
`bench/datasets/zheng_sentiment/normalized_f17_K45_sybil_N{01,03,05,10,20}.jsonl`
(seed 20260715, matching F15). Line counts: 21000 / 23000 / 25000 /
30000 / 40000 (20000 honest + 1000*N adversarial).

**Sybil property verification** (Item 1a, per-N property that all N
adversarial rows on any slot share one value):

    N=01: n_adv_rows=1000  n_slots=1000  slots_with_ne_1_distinct=0  strategy_tag={'sybil'}
    N=03: n_adv_rows=3000  n_slots=1000  slots_with_ne_1_distinct=0  strategy_tag={'sybil'}
    N=05: n_adv_rows=5000  n_slots=1000  slots_with_ne_1_distinct=0  strategy_tag={'sybil'}
    N=10: n_adv_rows=10000 n_slots=1000  slots_with_ne_1_distinct=0  strategy_tag={'sybil'}
    N=20: n_adv_rows=20000 n_slots=1000  slots_with_ne_1_distinct=0  strategy_tag={'sybil'}

Property holds at every N. Also verified: F17 sybil trace files are
bit-identical to F15 flip trace files after stripping the
`strategy` tag, for the four shared N values (N=01/03/05/10).
This is the expected outcome on a binary task and confirms the
generator is deterministic under the shared seed.

## 2. Predictions (recorded verbatim before running any grid cell)

  * **KNDB**: kind axis picks MEASURED regardless of Sybil count.
    Stays flat at ~0.927 (F15 baseline) across N∈{1,3,5,10,20}.
  * **CRH**: on Zheng CRH held under F15 coordinated-flip (0.951
    across N=1..10). On Sybil (harder attack because voters agree
    not just on class but on identity), CRH's log-ratio may still
    hold because 20 honest workers × 500 items give it enough
    per-worker evidence. **Prediction: CRH holds through N=10,
    degrades at N=20 (saturation).**
  * **TruthFinder**: on Zheng at F15 collapsed at N=10 (0.494). On
    Sybil (harder) should collapse earlier — **prediction: collapse
    at N=5**.
  * **CATD**: at F15 collapsed at N=10 (0.000). On Sybil should
    collapse earlier — **prediction: collapse at N=5**.
  * **ACCU**: at F15 collapsed at N=10 (0.000). Same as CATD —
    **prediction: collapse at N=5**.
  * **pg_conf**: 0.000 across all N (unchanged).
  * **pg_lww**: degrades from F15 baseline (0.401 at N=1)
    proportional to Sybil count.
  * **pg_mv**: majority-vote — Sybil trivially defeats it at N >
    honest coverage. Collapse at N=5-10.
  * **pg_heap**: INTEGRITY FAIL (unchanged).

**Meta-prediction** (paper-shaping): does CRH resist Sybil on Zheng
at some threshold and then collapse (density-saturation), OR does
CRH resist all N because 20 honest votes always outnumber N Sybils
(density-dominance)? If density-dominant, the Book-Author Sybil
result is a Zipfian/sparse-source artifact and the paper must
scope its Sybil claim to that regime.

## 3. Empirical grid (K=45, c=1, 9 systems × 5 N = 45 cells)

Each DB cell was run with restart-per-cell discipline (F15b rule):
`pg_ctl -o "-c shared_preload_libraries=epistemic -c port=55480 -c
unix_socket_directories=/tmp/kndb_pg18_test" restart -w -s` before
every DB replay. TD cells are offline and require no PG restart.
Orchestrator: `bench/scripts_stage3/run_zheng_sybil_f17.sh`.

### Precision at c=1

| system      | N=1   | N=3   | N=5   | N=10  | **N=20** |
|-------------|-------|-------|-------|-------|----------|
| KNDB (epistemic) | **0.927** | **0.927** | **0.927** | **0.927** | **0.927** |
| pg_conf     | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| pg_lww      | 0.401 | 0.211 | 0.130 | 0.074 | 0.024 |
| pg_mv       | 0.375 | 0.193 | 0.127 | 0.070 | 0.025 |
| pg_heap     | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| TruthFinder | 0.905 | 0.690 | 0.557 | 0.494 | 0.482 |
| CRH         | 0.953 | 0.951 | 0.951 | 0.951 | **0.000** |
| CATD        | 0.955 | 0.953 | 0.948 | 0.000 | 0.000 |
| ACCU        | 0.964 | 0.997 | 1.000 | 0.000 | 0.000 |

pg_heap Precision values at N=1..20 (all with n_slots_with_gt_1_live=1000
— multi-row live state, integrity FAIL): 0.288, 0.161, 0.101, 0.052,
0.028. Reported here for transparency; excluded from Precision
comparisons because integrity is not satisfied.

### KNDB vs best-TD margin

| N   | KNDB  | best-TD (algo) | KNDB - best_TD |
|-----|-------|----------------|-----------------|
| 1   | 0.927 | 0.964 (ACCU)   | -3.7pp          |
| 3   | 0.927 | 0.997 (ACCU)   | -7.0pp          |
| 5   | 0.927 | 1.000 (ACCU)   | -7.3pp          |
| 10  | 0.927 | 0.951 (CRH)    | -2.4pp          |
| **20**  | **0.927** | **0.482 (TruthFinder)** | **+44.5pp** |

Reading:

  * At **N=1..10 KNDB LOSES vs the best-TD-of-the-moment by
    2-7pp**. This confirms and extends the F16 finding: on Zheng
    d_sentiment's dense 20-labels/slot regime, TD algorithms
    actually beat KNDB slightly on the honest and low-adversary
    cases. ACCU peaks at 1.000 at N=5 (as F16 observed — Sybils
    are so uniformly wrong that ACCU identifies them precisely and
    re-ranks confidently).
  * At **N=20 KNDB WINS vs every TD algorithm by ≥44.5pp**. Three
    TD algorithms collapse to 0.000 (CRH, CATD, ACCU); TruthFinder
    hangs at 0.482 (essentially random on a binary task). KNDB is
    unchanged at 0.927.

### Elapsed / throughput (DB cells)

    epistemic N=01  n_w=21000  tps=1341.9  ab=0.763
    epistemic N=03  n_w=23000  tps=1369.2  ab=0.759
    epistemic N=05  n_w=25000  tps=1310.5  ab=0.763
    epistemic N=10  n_w=30000  tps=1147.2  ab=0.782
    epistemic N=20  n_w=40000  tps= 953.1  ab=0.822

Throughput drops ~30% from N=01 to N=20 (1342 -> 953 writes/s)
because abort_rate climbs from 0.763 to 0.822 — more Sybil writes
lose the F8 kind-tiebreak race and burn a transaction to no-op.
Correct-write goodput remains high because KNDB is picking the
Tier-A MEASURED write regardless. Expected.

## 4. Disable-and-test (mirror F16 discipline)

Runs `bench/scripts_td/td_disable_and_test_zheng_sybil.py` — replaces
each TD algorithm's iterative trust/weight loop with plain
majority-vote (no per-source weighting at all). If MV Precision > TD
Precision on the same trace, the agreement loop is actively
amplifying the Sybil attack.

Full transcript (each row is one N; deltas = mechanism_ON minus MV_OFF):

    === Zheng Sybil N=01 ===
      truthfinder ON=0.9050   MV OFF=0.9120   delta=-0.0070  AMPLIFIED
      crh         ON=0.9530   MV OFF=0.9120   delta=+0.0410  helped
      catd        ON=0.9550   MV OFF=0.9120   delta=+0.0430  helped
      accu        ON=0.9640   MV OFF=0.9120   delta=+0.0520  helped

    === Zheng Sybil N=03 ===
      truthfinder ON=0.6900   MV OFF=0.8580   delta=-0.1680  AMPLIFIED
      crh         ON=0.9510   MV OFF=0.8580   delta=+0.0930  helped
      catd        ON=0.9530   MV OFF=0.8580   delta=+0.0950  helped
      accu        ON=0.9970   MV OFF=0.8580   delta=+0.1390  helped

    === Zheng Sybil N=05 ===
      truthfinder ON=0.5570   MV OFF=0.7420   delta=-0.1850  AMPLIFIED
      crh         ON=0.9510   MV OFF=0.7420   delta=+0.2090  helped
      catd        ON=0.9480   MV OFF=0.7420   delta=+0.2060  helped
      accu        ON=1.0000   MV OFF=0.7420   delta=+0.2580  helped

    === Zheng Sybil N=10 ===
      truthfinder ON=0.4940   MV OFF=0.2930   delta=+0.2010  helped
      crh         ON=0.9510   MV OFF=0.2930   delta=+0.6580  helped
      catd        ON=0.0000   MV OFF=0.2930   delta=-0.2930  AMPLIFIED
      accu        ON=0.0000   MV OFF=0.2930   delta=-0.2930  AMPLIFIED

    === Zheng Sybil N=20 ===
      truthfinder ON=0.4820   MV OFF=0.0010   delta=+0.4810  helped
      crh         ON=0.0000   MV OFF=0.0010   delta=-0.0010  neutral
      catd        ON=0.0000   MV OFF=0.0010   delta=-0.0010  neutral
      accu        ON=0.0000   MV OFF=0.0010   delta=-0.0010  neutral

Reading:

  * **TruthFinder AMPLIFIES its own error at every N=1..5**. This
    mirrors F16 Book-Author: TF's fixed-point iteration is
    especially sensitive to bootstrapped Sybil agreement.
  * **CRH, CATD, ACCU HELP at N=1..5** (they beat MV by 4-26pp).
    Their weighting mechanism is actively identifying and
    down-weighting the perfectly-wrong Sybils on the sparse-Sybil
    regime.
  * **At N=10 CATD and ACCU CATASTROPHICALLY AMPLIFY** (29pp below
    MV, both go to 0.000). Their algorithms flip source trust
    entirely — Sybils become "reliable", honest workers become
    "wrong". CRH still helps massively at N=10 (+66pp over MV).
  * **At N=20 all three former helpers (CRH/CATD/ACCU) collapse to
    exactly the MV floor 0.001**. MV itself is dead on this cell
    because Sybils tie or majority the honest side (20/20 or 20/21
    per slot). CRH's weighting mechanism no longer has any
    corrective signal — Sybils are as consistent as honest
    workers, only wrong. TruthFinder's mechanism actually rescues
    ~48% because TF's dampening keeps some slots ambiguous.

**Verdict on the mechanism**: TD algorithms' agreement-loop is
DENSITY-LIMITED, not density-dominant. On Zheng it survives all N
where honest voters outnumber Sybils (N=1..10 with 20 honest per
slot). It collapses catastrophically once Sybil count matches
honest count (N=20). This is precisely the collapse F16 saw on
Book-Author at N=10 (where honest per-ISBN count is a Zipfian
distribution and adversaries at 100 items each match/exceed most
honest sources at N=10). Same mechanism, different saturation
threshold.

Saved JSON:
`bench/results/td_raw/zheng_sybil_disable_and_test.json`.

## 5. Verdict — does the Sybil result generalize?

**Answer: Yes, at the density-saturation cell (N=20).** At N=1..10
the Zheng result matches F15/F16 exactly (KNDB and CRH both hold
around 0.93-0.95; CATD/ACCU collapse at N=10, TruthFinder slides
gradually). At N=20 every TD algorithm collapses and KNDB is
alone in holding 0.927 — a 44.5pp margin over the best-surviving
TD (TruthFinder).

The Book-Author Sybil result is NOT a Zipfian artifact. The
mechanism at work is the same in both datasets: once Sybil-count
matches or exceeds the per-slot honest-vote count, the
agreement-driven trust loop has no corrective signal and TD
algorithms lose to (or match) plain MV. The datasets differ only
in WHERE the saturation threshold lies:

  * Book-Author: adversaries at 100 items each match a large
    fraction of honest sources (Zipfian tail), so saturation at
    N=10 already puts adversaries in the density range of most
    honest sources. TD collapses at N=10.
  * Zheng d_sentiment: uniform 20 labels/slot from 85 workers,
    so adversaries need to match that 20 to saturate. TD holds
    until N=20 and then collapses simultaneously.

Same mechanism, both datasets. KNDB's kind axis is unaffected in
both because it doesn't consume inter-source agreement at all.

## 6. Meta-verdict — is the paper's Sybil claim general or density-scoped?

**The claim is GENERAL on the mechanism ("agreement-loop TD
algorithms are density-limited under Sybil attack"), and
GENERAL on the KNDB win ("kind-axis orthogonal to agreement is
Sybil-count-invariant").**

The paper does not need a density-scope qualifier. What it DOES
need to say honestly:

  1. On **datasets with sparse per-slot honest evidence**
     (Book-Author's Zipfian distribution puts many honest sources
     at 1-2 items on gold ISBNs), TD collapses at *low* Sybil counts
     (N=10 is enough).
  2. On **datasets with dense per-slot honest evidence** (Zheng's
     uniform 20 labels/slot), TD holds until Sybil count matches
     honest count (N=20), then collapses simultaneously to the MV
     floor.
  3. KNDB's kind axis wins at the *saturation cell* on both
     datasets — 40pp on Book-Author N=10, 44.5pp on Zheng N=20 —
     because the kind axis does not depend on agreement to grant
     trust.

This is a stronger and more honest paper claim than "KNDB beats
TD algorithms on Sybil". The correct claim is: **KNDB is the only
system whose Sybil-robustness does not depend on the per-slot
honest-vote count remaining strictly greater than the Sybil
count.** Every TD algorithm fails at 1:1 density; KNDB does not.

## 7. Files created / modified in F17 Item 1

Modified:
  * `contrib/epistemic/bench/datasets/normalize.py` — added
    `adversarial_strategy` parameter to
    `normalize_zheng_sentiment_f15` (default "flip_binary" keeps
    F15 behaviour byte-identical; "sybil" tag threaded through
    dataset_metadata).
  * `contrib/epistemic/bench/scripts_stage3/run_zheng_sybil_f17.sh`
    (new) — F17 orchestrator with F15b restart-per-cell.
  * `contrib/epistemic/bench/scripts_td/td_disable_and_test_zheng_sybil.py`
    (new) — F17 disable-and-test wrapper.

Created data:
  * `contrib/epistemic/bench/datasets/zheng_sentiment/normalized_f17_K45_sybil_N{01,03,05,10,20}.jsonl`
    — F17 Sybil traces.
  * `contrib/epistemic/bench/results/td_raw/zheng_sybil_{epistemic,pg_conf,pg_lww,pg_mv,pg_heap}_c001_N{01,03,05,10,20}.json`
    — 25 DB cells.
  * `contrib/epistemic/bench/results/td_raw/zheng_sybil_{truthfinder,crh,catd,accu}_N{01,03,05,10,20}.json`
    — 20 TD cells.
  * `contrib/epistemic/bench/results/td_raw/zheng_sybil_disable_and_test.json`
    — disable-and-test rollup.
  * `contrib/epistemic/bench/results/summary/stage3_zheng_sybil.md`
    (this file).

Not modified: `contrib/epistemic/src/**` (dylib guard still exit 0,
SHA-256 `807b2e87f6...`).

## 8. Prediction scorecard

| Prediction | Reality | Verdict |
|-----------|---------|---------|
| KNDB flat 0.927 across N | 0.927 flat N=1..20 | correct |
| CRH holds through N=10, degrades at N=20 | 0.951 flat N=1..10, 0.000 at N=20 | correct (degradation is total, not partial) |
| TruthFinder collapses at N=5 | 0.905->0.482 gradual across N; never < 0.482 | wrong — TF slides gradually, doesn't collapse |
| CATD collapses at N=5 | 0.955->0.948 through N=5, 0.000 at N=10 | wrong — collapses at N=10 not N=5 |
| ACCU collapses at N=5 | 1.000 at N=5, 0.000 at N=10 | wrong — collapses at N=10 not N=5 |
| pg_conf 0.000 across all N | 0.000 flat | correct |
| pg_lww degrades from 0.401 proportional to N | 0.401->0.024 | correct |
| pg_mv collapses at N=5-10 | 0.375->0.070 by N=10, 0.025 at N=20 | correct (gradual, not sharp) |
| pg_heap INTEGRITY FAIL | FAIL at every N | correct |
| **Meta**: CRH density-limited (not density-dominant) | Confirmed: CRH holds at 20-honest-vs-N-Sybil for N<20, collapses when N=20 | correct — density-limited |

Three predictions wrong (TF/CATD/ACCU collapse timing): I predicted
they'd collapse earlier under Sybil than under F15 flip, but on binary
d_sentiment F17 sybil ≡ F15 flip, so the collapse thresholds are
the same as F16 measured. My prediction implicitly assumed
"Sybil is harder than flip" is a distinct axis on binary tasks,
which it isn't. Correctly noting the equivalence would have avoided
these errors.

The meta-prediction was correct and load-bearing: CRH density-limited,
not density-dominant. The paper's Sybil claim generalizes cleanly.
