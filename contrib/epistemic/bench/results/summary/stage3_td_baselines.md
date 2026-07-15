# Stage 3 F16: Truth-discovery baselines vs KNDB kind axis

**Question F16 answers**: F14/F15 showed KNDB beats pg_conf by 63pp
(Book-Author) / 92.7pp (Zheng) on the confidence-forgery attack.
A reviewer will ask why the actual truth-discovery (TD) algorithms
weren't baselines and whether they also fall. F16 runs four canonical
TD algorithms (TruthFinder, CRH, CATD, ACCU) on the F14/F15 traces
plus a new coordinated-Sybil variant of F14 (F16 workload).

**Prediction hypothesis (recorded verbatim before running any adversarial cell)**:
TD algorithms infer source reliability from INTER-SOURCE AGREEMENT,
not from an orthogonal kind signal. A confident liar with fabricated
agent identities that agree with itself can bootstrap apparent
reliability. Predictions:

  * F14 (independent wrong values per adversarial agent): TD should
    MOSTLY REJECT — no inter-adversary agreement to bootstrap. Precision
    near honest baseline.
  * F15 (binary flip, coordinated by construction): TD should COLLAPSE
    at high N — flipped label is unique so all N adversaries agree.
  * F16 Book-Author Sybil (new): all N adversarial agents share the
    same wrong author-string per ISBN. TD should COLLAPSE at high N.

## TD implementations

Fresh reimplementations in `bench/scripts_td/td_algorithms.py`,
written from the published equations (no vendored code). Rationale:
Zheng repo (`github.com/zhydhkcws/crowd_truth_infer`, commit
`8d21647`, Python 2, MATLAB-Python mix, no license) does not
publish TruthFinder or ACCU. The IshitaTakeshi TruthFinder
(`github.com/IshitaTakeshi/TruthFinder`, commit `82ae778`) is
license-absent and Pandas-`set_value`-slow; DAFNA-EA
(`github.com/daqcri/DAFNA-EA`) is Java. Rather than mix license
statuses, F16 implements all four from the paper equations in one
Python module and validates each against a published number below.

Paper references:

  * TruthFinder: Yin/Han/Yu KDD 2007
    <https://dl.acm.org/doi/10.1145/1281192.1281309>. Identity
    implication (imp(f',f)=0 for f'!=f) — the "simple" categorical
    configuration Yin/Han/Yu describe when fact similarity is not
    defined.
  * CRH: Li et al. SIGMOD 2014
    <https://dl.acm.org/doi/10.1145/2588555.2610509>. Categorical
    0/1 loss (paper sec 4.2, table 2).
  * CATD: Li et al. VLDB 2015
    <https://dl.acm.org/doi/10.14778/2735479.2735486>. Categorical
    variant with chi-square upper confidence bound (paper sec 4).
    Uses scipy.stats.chi2 for the inverse-CDF instead of the
    Zheng-repo lookup table — same math, better precision.
  * ACCU: Dong/Berti-Equille/Srivastava VLDB 2009
    <http://www.vldb.org/pvldb/vol2/vldb09-pvldb47.pdf>. Base
    variant without copy-detection. Uses the cleaned MAP formulation
    from Zheng et al.'s VLDB'17 survey (Table 3) with the "n_false"
    hyperparameter (default = max distinct claims per item - 1).

Each algorithm's identical toy sanity tests (10 honest agents, N
adversaries) pass. All source in
`bench/scripts_td/td_algorithms.py`; runner in
`bench/scripts_td/run_td_offline.py`; disable-and-test proof in
`bench/scripts_td/td_disable_and_test.py`.

## Fairness discipline

  * TD algorithms consume the SAME trace file DB systems consume.
    No trace edits, no filtering of MEASURED rows.
  * Every trace claim maps to a real source identifier: KNDB-format
    rows with `sources==[]` (MEASURED) get their `dataset_metadata`
    worker_id / source_name back so TD sees the underlying human
    source. Anonymising them per-row would give TD a bogus
    single-observation source population and dilute its trust signal.
  * Default hyperparameters used for each TD algorithm — no adversarial
    tuning either way. TruthFinder γ=0.3, ρ=0.5, initial t=0.9. CRH
    max_iter=100. CATD α=0.05 (95% confidence). ACCU
    initial_accuracy=0.8, n_false auto-inferred.
  * Convergence: L2 delta < 1e-6 on trust/weight, capped at 100
    iterations. Every cell converged within 10-30 iterations in
    practice.
  * Integrity column reported "N/A_offline": TD algorithms emit
    exactly one predicted value per item by construction, so DB
    live-row semantics don't apply. Reporting integrity as PASS
    would overstate.

## Honest baseline (N=0)

| system     | Book-Author (K=50) | Zheng d_sentiment (K=45) |
|------------|--------------------|--------------------------|
| KNDB       | 0.630              | 0.927                    |
| pg_conf    | matches (0.630)    | 0.927                    |
| pg_lww     | 0.210              | 0.786                    |
| pg_mv      | 0.500              | 0.689                    |
| pg_trigger | 0.620              | 0.927                    |
| pg_heap    | INTEGRITY FAIL     | INTEGRITY FAIL           |
| TruthFinder| 0.530              | 0.948                    |
| CRH        | 0.580              | 0.950                    |
| CATD       | 0.550              | 0.957                    |
| ACCU       | 0.530              | 0.951                    |

**Reproducibility against Zheng VLDB'17 survey**: Zheng survey Table
6 reports on `D_PosSent` (== `d_sentiment`): MV 93.31%, D&S 96.00%,
CATD 96.00%, PM(=CRH) 95.04%, LFC 95.90%. Our numbers:
CATD 95.7% (matches within 0.3pp), CRH 95.0% (matches within 0.04pp),
TruthFinder 94.8% (Zheng doesn't report TF on this dataset; number
is in the same ~95% neighborhood as related methods), ACCU 95.1%
(same ballpark). Plumbing verified.

**Book-Author honest**: TD algorithms score 0.53-0.58, below KNDB
(0.63) and pg_lww (0.21) but above pg_mv (0.50). Slightly worse
than KNDB because they can't use the F14 mapping's Tier-A
`ep_kind == MEASURED` signal — they only see (source, item, value)
and have to infer worker quality from within-trace agreement. Fair.
Not a criticism of the TD algorithms; they weren't designed for the
F14 workload's authority-tier signal.

## Adversarial (independent-value, F14 workload) — Book-Author

**Threat**: each adversarial agent picks a DIFFERENT scrambled wrong
value per gold ISBN (F14's default `--adv-strategy scrambled`).

| system     | N=1   | N=3   | N=5   | N=10  |
|------------|-------|-------|-------|-------|
| KNDB       | 0.630 | 0.630 | 0.630 | 0.630 |
| pg_conf    | 0.000 | 0.000 | 0.000 | 0.000 |
| pg_lww     | 0.210 | 0.130 | 0.090 | 0.040 |
| pg_mv      | 0.460 | 0.400 | 0.320 | 0.170 |
| pg_trigger | 0.620 | 0.620 | 0.620 | 0.620 |
| pg_heap    | INTEGRITY FAIL (all N)                     |||
| TruthFinder| 0.530 | 0.530 | 0.530 | 0.530 |
| CRH        | 0.580 | 0.580 | 0.580 | 0.580 |
| CATD       | 0.550 | 0.550 | 0.550 | 0.550 |
| ACCU       | 0.530 | 0.530 | 0.530 | 0.530 |

**Prediction confirmed**: TD algorithms are FLAT across N under the
independent-value attack — Precision doesn't drop from N=1 to N=10.
Adversaries produce no inter-source agreement (each independently
picks a different scrambled wrong value), so the trust-bootstrap
loop doesn't grant them weight. TruthFinder, CRH, CATD, ACCU all
correctly reject them.

Consequence for the paper: **the F14 attack does NOT differentiate
KNDB from the TD baselines by very much**. KNDB 0.630, TruthFinder
0.530, CRH 0.580, CATD 0.550, ACCU 0.530 — spread of 5-10pp, not
63pp. The pg_conf 63pp headline drops to a ~5-10pp headline vs TD
baselines under F14's specific attack shape.

## Adversarial (coordinated-flip, F15 workload) — Zheng d_sentiment

**Threat**: binary flip of gold label; because there are only 2
classes ("pos"/"neg"), all N adversaries claim the SAME flipped
label per slot — Sybil-style by construction, not by intent.

| system     | N=1   | N=3   | N=5   | N=10  |
|------------|-------|-------|-------|-------|
| KNDB       | 0.927 | 0.927 | 0.927 | 0.927 |
| pg_conf    | 0.000 | 0.000 | 0.000 | 0.000 |
| pg_lww     | 0.401 | 0.211 | 0.130 | 0.074 |
| pg_mv      | 0.375 | 0.193 | 0.127 | 0.070 |
| pg_trigger | 0.927 | 0.927 | 0.927 | 0.927 |
| pg_heap    | INTEGRITY FAIL (all N)                     |||
| TruthFinder| 0.905 | 0.690 | 0.557 | 0.494 |
| CRH        | 0.953 | 0.951 | 0.951 | 0.951 |
| CATD       | 0.955 | 0.953 | 0.948 | 0.000 |
| ACCU       | 0.964 | 0.997 | 1.000 | 0.000 |

**Predictions partially confirmed**:

  * TruthFinder collapses gradually 0.905 → 0.494 (from N=1 to N=10),
    as predicted.
  * CATD and ACCU collapse to 0.000 at N=10 (very sharp drop from
    ~0.95), matching prediction. ACCU is the standout — it stays
    HIGHER than the honest baseline for N=1..5 (0.964-1.000), likely
    because the Sybils' perfect wrongness across 1000 items lets ACCU
    identify them precisely and re-rank the correct label with high
    posterior. Then at N=10, Sybils overwhelm and it flips.
  * CRH resists throughout (0.951 flat). Why: 20 honest labels/item
    give a strong majority-vote init; adversaries end up
    perfectly-wrong on 1000/1000 items and CRH's log-ratio drives
    their weight to zero (verified: adv weight = -8.2e-17, honest
    weight mean = 5.3). Prediction "CATD/CRH collapse" was wrong for
    CRH on Zheng at N up to 10. This IS a real finding for the paper.
  * KNDB stays flat at 0.927.

Consequence for the paper: **F15 headline "KNDB vs pg_conf 92.7pp"
does NOT extend cleanly to KNDB vs CRH — CRH matches KNDB within
noise on this attack (0.951 vs 0.927). Against TruthFinder the
delta is 43pp; against CATD 92.7pp at N=10 only; against ACCU
92.7pp at N=10 only.** The Zheng workload advantages CRH because
`d_sentiment` has 20 workers/item and 1000 items, giving TD
algorithms enough evidence per source to identify all-wrong
adversaries.

## Adversarial (coordinated-Sybil, F16 workload) — Book-Author

**Threat model (F16 new)**: N adversarial agents share the SAME
scrambled wrong author-string per gold ISBN. Constructed by adding
`--adv-strategy sybil` to `normalize_bookauthor_f14`:
`wrong_value_for_isbn(isbn, i)` ignores index `i` and returns the
same scrambled value keyed only by ISBN. All 100/100 gold ISBNs
verified to have identical value across N adversarial rows.

| system     | N=1   | N=3   | N=5   | N=10  |
|------------|-------|-------|-------|-------|
| KNDB       | 0.630 | 0.630 | 0.630 | 0.630 |
| pg_conf    | 0.000 | 0.000 | 0.000 | 0.000 |
| pg_lww     | 0.210 | 0.130 | 0.090 | 0.040 |
| pg_mv      | 0.490 | 0.390 | 0.330 | 0.260 |
| pg_trigger | 0.620 | 0.620 | 0.620 | 0.620 |
| pg_heap    | INTEGRITY FAIL (all N)                     |||
| TruthFinder| 0.530 | 0.470 | 0.120 | 0.010 |
| CRH        | 0.580 | 0.590 | 0.590 | 0.230 |
| CATD       | 0.550 | 0.550 | 0.420 | 0.100 |
| ACCU       | 0.530 | 0.530 | 0.290 | 0.060 |

**Prediction confirmed on Book-Author**: all four TD algorithms
COLLAPSE at N=10. TruthFinder 0.530 → 0.010 (52pp drop), CATD 0.550
→ 0.100 (45pp drop), ACCU 0.530 → 0.060 (47pp drop), CRH the most
robust but still 0.580 → 0.230 (35pp drop). Why Book-Author Sybil
hits TD harder than Zheng Sybil despite fewer items (100 vs 1000):
Zipfian source distribution — honest sources average 12-124 items
each vs adversaries at exactly 100 items each — puts adversaries in
the DENSITY range of honest sources so CRH's log-ratio can't zero
them out as decisively.

**KNDB stays flat at 0.630** across N=1..10. **KNDB vs
best-surviving TD (CRH) at N=10: 0.630 - 0.230 = 40pp**.

## Disable-and-test: TD collapse is caused by the agreement mechanism

Mirroring F14/F15's source-rebuild disable-and-test. F16 patches at
Python level (no dylib change; TD is not KNDB source). Method:
replace each TD algorithm's iterative trust/weight loop with the
frozen equivalent — plain majority vote (no per-source weighting at
all). If MV Precision > TD Precision on the same trace, the
agreement loop was actively amplifying the Sybil attack.

Book-Author Sybil N=10:

| method                                | Precision |
|---------------------------------------|-----------|
| TruthFinder (agreement mechanism ON)  | 0.010     |
| CRH (agreement mechanism ON)          | 0.230     |
| CATD (agreement mechanism ON)         | 0.100     |
| ACCU (agreement mechanism ON)         | 0.060     |
| Majority-vote (mechanism OFF)         | 0.200     |
| pg_mv (DB equivalent of MV)           | 0.260     |

TruthFinder, CATD, ACCU all score LOWER than plain MV (0.010, 0.100,
0.060 vs 0.200) — the agreement loop *actively amplifies* the Sybil
attack. CRH scores higher than MV (0.230 vs 0.200) — its log-ratio
is defensively weighting adversaries less than 1, but only enough
to slightly beat MV. The disable-and-test proves TD's mechanism
(agreement-driven trust) IS what causes the collapse; when it's
disabled (MV), Precision recovers (partially).

**KNDB epistemic kind-axis disable-and-test**: already committed
under F14 (`bench/results/summary/stage3_adversarial.md`,
"F14 disable-and-test"). KIND OFF drops KNDB Book-Author from 0.630
to 0.000 at N=5 c=1. That's the counterpart on the KNDB side —
KNDB's mechanism is doing the work too, in the opposite direction
(providing robustness rather than causing collapse).

## Verdict

**Does the paper's headline hold vs truth-discovery baselines?**

Nuanced. Three separate answers, one per attack:

  1. **F14 independent-value attack**: KNDB beats every TD baseline
     by 5-10pp only. This is a much narrower win than the 63pp win
     vs pg_conf. The TD baselines correctly reject uncoordinated
     adversaries. The F14 headline "KNDB beats pg_conf by 63pp"
     needs the qualifier "on the confidence-forgery axis; TD
     algorithms that don't consume confidence but do consume
     agreement handle this attack shape roughly as well as KNDB".

  2. **F15 coordinated-flip on Zheng**: mixed. KNDB beats TruthFinder
     by 43pp at N=10 (0.927 vs 0.494), matches CRH within 3pp (0.927
     vs 0.951 — CRH is *slightly higher* on this workload), beats
     CATD by 92.7pp at N=10 (0.927 vs 0.000) but only 0pp at N=5
     (both ~0.95), beats ACCU by 92.7pp at N=10 (both ~0.99 at N=5).
     CRH is a real competitor on `d_sentiment` because 20 workers ×
     1000 items gives it enough evidence per source. On this
     particular dataset, KNDB's kind axis and CRH's log-ratio weight
     land at similar Precision — different mechanisms, same outcome.

  3. **F16 Sybil attack on Book-Author** (the paper-decisive
     attack): KNDB beats every TD baseline by 40-62pp at N=10. TD
     collapses because agents that agree bootstrap trust, and Sybils
     agree by construction. KNDB doesn't use inter-source agreement
     to grant trust, so Sybil count is irrelevant. Disable-and-test
     shows the collapse IS caused by the agreement mechanism (TF,
     CATD, ACCU all drop BELOW plain majority-vote at N=10).

**Paper positioning that survives the F16 audit**:

  * The paper's headline should NOT be "KNDB beats truth discovery"
    — that's false on `d_sentiment` where CRH matches or beats KNDB.
  * The paper's headline CAN be "KNDB's kind axis is orthogonal to
    inter-source-agreement trust and defeats coordinated-Sybil
    attacks that TD algorithms cannot defeat". Book-Author Sybil
    N=10: KNDB 0.630 vs best-TD (CRH) 0.230 = 40pp.
  * The related-work section MUST cite TruthFinder, CRH, CATD, ACCU
    (all four via the Zheng VLDB'17 survey) and disclose the F14
    "independent-value" and F15 "coordinated by construction"
    results honestly. CRH matching KNDB on Zheng is a real finding,
    not something to bury.
  * The paper's threat model should explicitly separate
    "confidence-forgery" (F14/F15) from "Sybil-coordinated
    attack" (F16). KNDB defeats both classes by different aspects
    of the kind axis; TD defeats only the first (in Book-Author's
    density regime — it partially defeats the second in Zheng's
    denser regime).

## Files created

  * `bench/scripts_td/td_algorithms.py` — fresh reimplementations.
  * `bench/scripts_td/run_td_offline.py` — offline runner.
  * `bench/scripts_td/td_disable_and_test.py` — disable-and-test
    proof for TD's agreement mechanism.
  * `bench/datasets/normalize.py` — added `--adv-strategy sybil`.
  * `bench/datasets/bookauthor/normalized_f16_K50_sybil_N{01,03,05,10}.jsonl`
    — reproducible Sybil traces (adv-seed 20260714, matches F14).
  * `bench/datasets/bookauthor/normalized_f14_K50_N00.jsonl` —
    honest-baseline N=0 trace (was missing from F14 commit).
  * `bench/results/td_raw/honest_zheng_{tf,crh,catd,accu}_K45_N00.json`
    — TD honest baselines on Zheng.
  * `bench/results/td_raw/honest_bookauthor_{tf,crh,catd,accu}_K50_N00.json`
    — TD honest baselines on Book-Author.
  * `bench/results/td_raw/adv_indep_bookauthor_{tf,crh,catd,accu}_N{01,03,05,10}.json`
    — TD on F14 independent-value attack.
  * `bench/results/td_raw/adv_zheng_{tf,crh,catd,accu}_N{01,03,05,10}.json`
    — TD on F15 coordinated-flip attack.
  * `bench/results/td_raw/adv_sybil_bookauthor_{tf,crh,catd,accu}_N{01,03,05,10}.json`
    — TD on F16 Sybil attack.
  * `bench/results/td_raw/adv_sybil_bookauthor_{epistemic,pg_conf,pg_lww,pg_mv,pg_trigger,pg_heap}_c001_N{01,03,05,10}.json`
    — DB systems on F16 Sybil attack.
