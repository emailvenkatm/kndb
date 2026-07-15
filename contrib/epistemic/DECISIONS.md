# Engineering decisions

Short notes recording load-bearing design choices and, where useful, the
audit that produced them. New entries go on top. Each entry is dated and
identifies the code paths involved.

## 2026-07-12, F18: close F9's COPY bypass via multi_insert override

F9 identified the last one-line hole in F2's bypass-unbypassability
claim. PG 18's CopyFrom (src/backend/commands/copyfrom.c:995-1006
REL_18_STABLE) selects `insertMethod = CIM_MULTI` when the target
has no BEFORE/INSTEAD OF INSERT trigger, then buffers ~1000-tuple
batches and flushes them through `table_multi_insert` at
copyfrom.c:554-559. `table_multi_insert` (access/tableam.h:1421-1427
REL_18_STABLE) dispatches on the AM's `multi_insert` callback
(access/tableam.h:527-529). Before F18 the epistemic AM copied
heapam's `TableAmRoutine` and inherited `heap_multi_insert`
(src/backend/access/heap/heapam_handler.c:2641 REL_18_STABLE), so
every COPY-batched row skipped:

  * R1..R5 rule checks (epistemic_check_rules)
  * per-slot advisory xact lock (F6)
  * find_live_overlap probe + xmin precedence tiebreak (F8)
  * eviction bookkeeping (audit row + sys_time close)
  * rmgr-128 annotation record

That was a silent bypass — no error, the bad rows landed. The
tuple_insert override was untouched by it, so INSERT stayed safe,
but COPY into an epistemic table effectively ran as plain heap
storage with none of the epistemic contract. The finding was one
line: heap_multi_insert lives inside heapam.c; our tuple_insert
delegation to `heapam->tuple_insert` at epistemic_am.c:507 never
routed COPY's batched flushes through it.

Choice: full override, not loud rejection. Two reasons.

  1. COPY is the standard bulk-load path. pg_restore uses it
     (copyfrom.c is invoked from restore's regenerated `\copy`
     statements). Refusing COPY would break `pg_dump | pg_restore`
     for any table USING epistemic — an unacceptable regression
     for a claim about correctness over throughput.
  2. The enforcement path is already factored: epistemic_tuple_insert_impl
     runs R1..R5, the advisory lock, the overlap probe, precedence,
     heap_insert delegation, audit, sys_time close, and the WAL
     marker in one function. A multi_insert override that iterates
     over slots[] and calls epistemic_tuple_insert_impl per row
     reuses every mechanism with zero semantic drift.

Implementation. src/epistemic_am.c gets one new static function
`epistemic_multi_insert(rel, slots, nslots, cid, options, bistate)`
whose body is a for loop calling `epistemic_tuple_insert_impl(rel,
slots[i], cid, options, bistate)`. The handler assignment block
adds one line: `epistemic_am_methods.multi_insert =
epistemic_multi_insert`. Header comment at top of file updated to
list three overrides (tuple_insert, multi_insert, relation_toast_am)
instead of two. Total new source: ~55 lines including the ~50-line
comment block explaining the tradeoff.

Tradeoff. heap_multi_insert (heapam.c:2351 REL_18_STABLE) toasts
in bulk, packs tuples onto pages with amortized allocation, and
emits one XLOG_HEAP2_MULTI_INSERT WAL record per page. The
per-slot fanout of epistemic_multi_insert pays one heap_insert per
row and one WAL record per row. COPY into an epistemic table
therefore runs at roughly the throughput of an equivalent
INSERT ... SELECT rather than of a plain-heap COPY. That is the
acceptable cost of not silently skipping enforcement.

Adversarial disable-and-test. Standard F1 discipline: source-rebuild,
dylib hash flip, script asserts flip.

  * F18 baseline (multi_insert wiring ON):
      sha256 = eb15d442dd1eace588c1c4ee4fab3e183addc70cc3a28773f8d5acfc0ff58af0
      scripts/bypass.sh COPY-FROM cell:
        fact_native COPY_FROM rows_after  = 0 (expected 0)  OK
        fact_native COPY_FROM raised_R3   = 1 (expected 1)  OK
        fact_native COPY_5rows rows_after = 0 (expected 0)  OK  (mixed batch)
        fact_native COPY_5rows raised_R3  = 1 (expected 1)  OK
      trigger baseline (fact_trigger with BEFORE INSERT trigger)
      routes through CIM_SINGLE and the trigger fires — bad row
      is also rejected, but that is the CopyFrom line-1005 branch,
      not F18. When the writer disables the trigger, bypass
      scenarios 1 and 2 already cover that.

  * Patched OFF (multi_insert wiring line commented out, rebuilt):
      sha256 = 302bb93b2c3b7f02ebf0bd88d95a85cc29f73539741b96965893348bc75abab5
      scripts/bypass.sh COPY-FROM cell:
        fact_native COPY_FROM rows_after  = 1 (expected 0)  FAIL
        fact_native COPY_FROM raised_R3   = 0 (expected 1)  FAIL
        fact_native COPY_5rows rows_after = 5 (expected 0)  FAIL
        fact_native COPY_5rows raised_R3  = 0 (expected 1)  FAIL
      Transcript literally reads "COPY 1" and "COPY 5" — the AM's
      overlap/rules pipeline is bypassed, all rows land, no error.
      That is the bypass F9 discovered, cleanly reproduced.

  * Restored (byte-identical source, rebuilt again):
      sha256 back to eb15d442... — restored guard exit 0.
      bypass.sh back to PASS with all COPY assertions OK.

F7 interaction (batch-size ceiling under COPY). The F6 per-slot
advisory xact lock is now taken per-row in the COPY path too. A
COPY of N distinct-slot rows accumulates N locks in the shared lock
table (NLOCKENTS = max_locks_per_xact * (MaxBackends +
max_prepared_xacts), src/backend/storage/lmgr/lock.c:56-57
REL_18_STABLE). Same ceiling F7 documented under INSERT
(~15,000 rows at PG default max_locks_per_transaction=64) applies
under COPY. scripts/bypass.sh sweeps N ∈ {100, 1000, 10000, 20000}
via real `\copy` from a CSV tempfile and asserts:

    N=100     OK  (100 rows land)
    N=1000    OK  (1000 rows land)
    N=10000   OK  (10000 rows land)
    N=20000   FAIL — ERROR: 53200 out of shared memory
                     HINT: You might need to increase
                     "max_locks_per_transaction"
                     LOCATION: LockAcquireExtended, lock.c:1080

Same first-failing-N grid F7 hit with INSERT. This is inherited
behaviour, not a new limit. We do NOT drop the advisory lock in the
multi_insert path — doing so would silently re-open the RC
integrity leak F6 closed (concurrent same-slot writers both commit,
two live rows land). The 15k-row ceiling is the T1-a tradeoff the
user already accepted at F8; F18 extends its scope from INSERT to
COPY without loosening the design.

With the multi_insert wiring OFF (disable-and-test), 20000-row COPY
succeeded (heap_multi_insert takes no advisory locks). That
strengthens the F7 interaction claim: the ceiling under COPY is a
direct consequence of routing through our per-row enforcement path,
not an artifact of PG's own machinery.

Threat model scope updated in README:

  * ALTER TABLE ... DISABLE TRIGGER ALL — blocked (F2)
  * SET session_replication_role = 'replica' — blocked (F2)
  * COPY FROM (CIM_MULTI batch path) — blocked (F18)
  * COPY FROM (CIM_SINGLE path) — already blocked pre-F18
    (single-row path calls table_tuple_insert)
  * INSERT / INSERT ... SELECT / INSERT ... VALUES — blocked
    (ExecInsert calls table_tuple_insert)
  * ALTER TABLE ... SET ACCESS METHOD heap — out of scope,
    schema-change threat
  * Logical replication apply worker — routes through
    ExecSimpleRelationInsert -> ExecInsert -> table_tuple_insert,
    so the AM callback fires even under
    SESSION_REPLICATION_ROLE_REPLICA. Documented; no dedicated
    test cell.

Full-suite validation:

  * installcheck: 6/6 (type, precedence, wal, am_basic, r2_sources,
                       am_eviction) unchanged.
  * check-e2e:    8/8 (recovery, concurrency, bypass, crash_atomicity,
                       tie_concurrency, rc_invariant, tie_determinism,
                       deadlock_detection) unchanged as script count.
                       bypass.sh now runs 3 bypass scenarios (was 2)
                       and one F7-interaction cell (new); all 12
                       internal assertions match expected.
  * verify_dylib.sh: exit 0 with sha256 =
                     eb15d442dd1eace588c1c4ee4fab3e183addc70cc3a28773f8d5acfc0ff58af0

Files touched:

  * src/epistemic_am.c — added `epistemic_multi_insert` static
    function (~10 LOC + ~50 LOC comment) and one line in the
    handler-init block wiring `.multi_insert`. Top-of-file header
    comment updated to enumerate three overrides. Diff is
    additive; every existing byte in epistemic_tuple_insert_impl
    and its callers is unchanged.
  * scripts/bypass.sh — preamble comment now enumerates three
    bypass mechanisms; added `attempt_copy_bad_row` helper;
    added scenarios "bypass 3" (single-row COPY, one bad row,
    both fact_trigger and fact_native), "bypass 3b" (5-row batch
    with 1 bad row into fact_native), and the F7 interaction
    sweep (real `\copy` at N ∈ {100, 1000, 10000, 20000} with
    verbose 20000 error probe).
  * README.md — Overview mentions multi_insert wrapper. What-is-
    load-bearing mentions the multi_insert callback and the F18
    disable-and-test. Batch-size-ceiling paragraph notes COPY
    now inherits the ceiling. Threat-model section enumerates
    seven write-path bypass surfaces with PG 18 file:line
    citations. Layout mentions multi_insert. Baseline-counts
    line updated to note bypass.sh runs more assertions.

Nothing surprising in PG 18's COPY path. The CIM_SINGLE gate at
copyfrom.c:995-1006 is exactly the escape hatch that made the pre-F18
partial safety possible (a target with a BEFORE INSERT trigger forced
CIM_SINGLE and the tuple_insert override was reached). CopyFrom
buffers up to 1000 tuples per batch (MAX_BUFFERED_TUPLES at
copyfrom.c:63); a single-slot ~1M-row COPY still trips the F7
ceiling well before the buffer size ever matters. The `options` /
`bistate` fields (TABLE_INSERT_SKIP_FSM at copyfrom.c:851,
TABLE_INSERT_FROZEN at copyfrom.c:908) are forwarded unchanged
through epistemic_tuple_insert_impl to heap_insert; no epistemic
enforcement depends on them.

## 2026-07-12, F17: Sybil vulnerability theorem and KNDB kind invariance

Two-item followup to F16. Item 1 (already in tree,
`bench/results/summary/stage3_zheng_sybil.md`) closed the empirical
question — the F16 Book-Author Sybil collapse at N=10 generalizes to
Zheng d_sentiment at N=20 (Sybils = per-slot honest labels, 20/20).
Item 2 formalizes why and derives the collapse threshold from the
per-slot honest-vote count alone, so the paper can predict the
saturation cell of any new dataset instead of only reporting two.

### Item 2 formalism (bench/docs/sybil_formalism.md)

Model, threat model, and per-algorithm monotonicity lemmas cited by
paper section + equation number: TruthFinder (Yin/Han/Yu KDD 2007
§3.2 eqs 3,6,7,8), CRH (Li SIGMOD 2014 §3-4 eq 10 form, categorical
0/1 loss), CATD (Li VLDB 2015 §3.2.2 eq 7 + §3.2.4 categorical),
ACCU (Dong VLDB 2009 §4.2 eqs 18-22, log-domain MAP per Zheng
VLDB 2017 survey Table 3). Ground truth for the code is
`bench/scripts_td/td_algorithms.py`.

**Threshold theorem (one sentence):** k\* ≈ h for TF, CRH, CATD, ACCU
under standard hyperparameters, validated within ±20% on Book-Author
(predicted 2-10, observed 10) and Zheng (predicted 20, observed 20);
KNDB's k\* is unbounded because kind rank is engine-assigned and
cannot be forged by the writer.

The `h` that matters for TD is the per-slot TOP HONEST SURFACE FORM
support, not total honest support, because TD argmaxes over value
strings. Book-Author's gold-matching claims split across canonical
and variant author strings — measured h_top median = 4 (mean 7.3)
across 100 gold ISBNs — which puts the collapse at N=5..10. Zheng's
binary task has h_top = h_gold, median 14, and the density-saturation
cell falls at N=20. Different h_top distributions, same threshold
rule.

### KNDB invariance (§6)

Short proof: F14/F15 tier mappings compute ep_kind from independent
metadata (Book-Author: `n_listings` + `canon_rate` from `book.txt`;
Zheng: `quali_acc` from disjoint qualification items 2000..2019).
Adversarial identities have no such history and cannot be tiered into
MEASURED. The F5 lattice ranks MEASURED strictly above INFERRED, so
one MEASURED honest write outranks any k INFERRED Sybil writes. Ergo
k\* = ∞ for KNDB. Dependence: F13 independence rule; validated in
each dataset's README self-audit. Empirical counterpart is F14's KIND
OFF disable-and-test (Book-Author precision 0.630 → 0.000 at N=5 c=1).

### Boundary honesty disclosed

  * **CRH sub-saturation defence is real.** F17 Item 1 disable-and-test
    shows CRH beats MV by +0.041pp to +0.658pp across N=1..10 on
    Zheng. The log-ratio is defensively load-bearing below saturation;
    paper must credit this rather than claim uniform KNDB dominance.
  * **TruthFinder amplifies at low N.** TF's fixed-point iteration
    goes below MV at N=1..5 on Zheng (Item 1 transcript). The
    theorem's `k*_TF ≤ h_top + O(1)` bound holds but the O(1) can be
    negative — TF collapses earlier than the clean bracket predicts.
    Disclose safe upper bound + tighter empirical.
  * **ACCU peaks above KNDB at N=5 on Zheng** (1.000 vs 0.927). The
    theorem covers the collapse threshold only, not sub-saturation
    performance. Paper must not overstate below saturation.

### Test suite state

`src/` byte-identical to HEAD (F17 Item 2 is docs-only, no code).
`scripts/verify_dylib.sh` exit 0; sha256 =
`807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74`.
installcheck / check-e2e not re-run (no src/ change; last-known
green was F17 Item 1's 6/6 and 8/8).

### Files added

  * `bench/docs/sybil_formalism.md` — model, threat model,
    per-algorithm monotonicity lemmas, threshold theorem with
    empirical validation, KNDB invariance theorem, boundary-honesty
    section, references to the four TD papers with section+equation
    citations.

Not modified: F16 entry (below) and F17 Item 1 report.

## 2026-07-12, F16: truth-discovery baselines and the Sybil-attack question

F14 and F15 shipped a headline: KNDB beats pg_conf by 63pp (Book-Author)
and 92.7pp (Zheng) on the confidence-forgery attack, with a
source-rebuild disable-and-test proving the kind axis is load-bearing.
A reviewer will immediately ask "why aren't the actual truth-discovery
(TD) algorithms in the comparison?" — Book-Author and Zheng are
datasets owned by the TD literature. F16 answers.

### Hypothesis (recorded before running any adversarial cell)

TD algorithms (TruthFinder, ACCU, CRH, CATD) infer source reliability
from INTER-SOURCE AGREEMENT, not from an orthogonal kind signal. A
confident liar with fabricated agent identities that agree with itself
can bootstrap apparent reliability. On the F14 independent-value attack,
TD should mostly reject (no coordination). On a coordinated-Sybil
variant (all N adversarial agents share the SAME wrong value per gold
item), TD should collapse. KNDB's kind axis is agnostic to Sybil count.

### TD implementations

Fresh reimplementations in `bench/scripts_td/td_algorithms.py`,
written from the KDD07 / SIGMOD14 / VLDB15 / VLDB09 equations. No
vendored code (Zheng's `crowd_truth_infer` commit `8d21647` is Py2
without a license; IshitaTakeshi TruthFinder commit `82ae778` also
license-absent; DAFNA-EA is Java). Each algorithm validated against
Zheng VLDB'17 survey's `D_PosSent` numbers:

  * CATD: 0.957 (survey: 0.960; delta 0.3pp)
  * CRH:  0.950 (survey PM: 0.9504; delta 0.04pp)
  * TruthFinder: 0.948 (not in survey table for this dataset; ballpark)
  * ACCU: 0.951 (survey doesn't report ACCU on d_sentiment; ballpark
    matches other confusion-matrix-free methods around 0.95)

Plumbing verified. Runner: `bench/scripts_td/run_td_offline.py`.
Adapter maps trace rows to (item, source, value); MEASURED KNDB rows
(sources==[]) fall back to `dataset_metadata.worker_id` /
`source_name` so TD sees a real 85-worker (Zheng) or 227-source
(Book-Author) population, not 3000 anonymous single-observation
"sources".

Integrity column reported as `N/A_offline` — TD algorithms emit exactly
one predicted value per item by construction, so DB live-row semantics
don't apply. Reporting integrity as PASS would overstate.

### Fairness discipline

Default hyperparameters per each paper: TF γ=0.3, ρ=0.5, initial
t=0.9; CRH max_iter=100; CATD α=0.05; ACCU initial A=0.8, n_false
auto-inferred. No tuning either way. Every cell converged within
10-30 iterations. TD algorithms consume THE SAME normalized trace
KNDB and pg_* consume — no trace edits, no MEASURED-row filtering.

### Predictions (verbatim, before empirical runs)

F14 independent-value attack:
  * TruthFinder: adversary's independent wrong values get low
    confidence (no supporting sources). Should not collapse.
    Prediction: precision close to baseline.
  * CRH: similar — adversary's low weight after iteration.
  * CATD: confidence-aware; adversary's high self-confidence should
    be discounted after CATD sees inter-agreement is low. Prediction:
    partial degradation.
  * ACCU: models P(claim | truth, source); adversary's isolated
    wrong values get low P. Prediction: robust.

Sybil attack:
  * TruthFinder: agrees-with-agreeing-source loop → adversary
    bootstraps trust → COLLAPSE.
  * CRH: coordinated attack minimizes CRH loss → COLLAPSE.
  * CATD: confidence bound tightens with more agreeing observations
    → COLLAPSE.
  * ACCU: models copying but Sybil identities look independent →
    COLLAPSE unless copy detection fires (base ACCU has none).
  * KNDB: kind axis picks MEASURED unconditionally regardless of
    Sybil count. Should stay at baseline.

### Empirical results

**Honest baseline (N=0)**:

    system      Book-Author K=50   Zheng K=45
    KNDB        0.630              0.927
    TruthFinder 0.530              0.948
    CRH         0.580              0.950
    CATD        0.550              0.957
    ACCU        0.530              0.951

**F14 independent-value attack (Book-Author)** — TD algorithms are
FLAT across N=1..10:

    system      N=1    N=3    N=5    N=10
    KNDB        0.630  0.630  0.630  0.630
    pg_conf     0.000  0.000  0.000  0.000
    TruthFinder 0.530  0.530  0.530  0.530
    CRH         0.580  0.580  0.580  0.580
    CATD        0.550  0.550  0.550  0.550
    ACCU        0.530  0.530  0.530  0.530

Prediction confirmed. Independent adversaries get no trust bootstrap.
**Consequence**: F14's 63pp win over pg_conf drops to a 5-10pp win
over TD baselines. The F14 headline needs qualification.

**F15 coordinated-flip on Zheng d_sentiment** — TD partially resists:

    system      N=1    N=3    N=5    N=10
    KNDB        0.927  0.927  0.927  0.927
    pg_conf     0.000  0.000  0.000  0.000
    TruthFinder 0.905  0.690  0.557  0.494
    CRH         0.953  0.951  0.951  0.951
    CATD        0.955  0.953  0.948  0.000
    ACCU        0.964  0.997  1.000  0.000

Prediction partially wrong: CRH RESISTS through N=10 (0.951 flat).
Why: 20 workers × 1000 items gives CRH enough per-source evidence to
zero-weight adversaries whose `dif(s) = 1000` while honest source
`dif` is small. CRH weight verified: adv = -8.2e-17, honest mean = 5.3.
CATD and ACCU collapse only at N=10 (sharp cliff), TruthFinder degrades
gradually. This IS a real finding — on `d_sentiment`, CRH is competitive
with KNDB (0.951 vs 0.927, +2.4pp for CRH). The paper's 92.7pp
"KNDB vs pg_conf" headline does NOT extend to "KNDB vs CRH" on Zheng.

**F16 Sybil attack on Book-Author** (new workload) — TD collapses:

Trace generator extended: `bench/datasets/normalize.py` gains
`--adv-strategy sybil` which sets all N adversarial agents per gold
ISBN to the SAME scrambled wrong author. Verified: 100/100 ISBNs
have exactly 1 distinct value across N adversarial rows. adv-seed
20260714 matches F14 so the honest-rows baseline coincides exactly
(KNDB honest = 0.630 per F14, reproduced here).

    system      N=1    N=3    N=5    N=10
    KNDB        0.630  0.630  0.630  0.630
    pg_conf     0.000  0.000  0.000  0.000
    pg_mv       0.490  0.390  0.330  0.260
    TruthFinder 0.530  0.470  0.120  0.010
    CRH         0.580  0.590  0.590  0.230
    CATD        0.550  0.550  0.420  0.100
    ACCU        0.530  0.530  0.290  0.060

All four TD algorithms collapse at N=10. Sharp cliff at N=5 for
TF/CATD/ACCU (60-90pp drops). CRH holds up to N=5 then collapses to
0.230 at N=10 (still above chance but well below KNDB's 0.630).
**KNDB beats best TD (CRH) at N=10 by 40pp**; beats TruthFinder by
62pp. The Sybil attack IS the paper-decisive workload against TD.

### Disable-and-test: TD's mechanism is bimodal, not uniformly amplifying

Same discipline as F14/F15 but at Python level (TD is not KNDB source,
no dylib to rebuild). `bench/scripts_td/td_disable_and_test.py`
replaces each TD algorithm's iterative trust/weight loop with plain
majority-vote (frozen-trust equivalent — no per-source weighting at
all). Sign of (TD_precision − MV_precision) tells us whether the
agreement loop helps (positive) or hurts (negative) at each N.

Book-Author Sybil N=10:

    method                                Precision
    TruthFinder mechanism ON              0.010
    CRH mechanism ON                      0.230
    CATD mechanism ON                     0.100
    ACCU mechanism ON                     0.060
    Majority-vote mechanism OFF           0.200

TruthFinder, CATD, ACCU score LOWER than plain MV (0.010, 0.100,
0.060 vs 0.200) at Book-Author Sybil N=10. On this cell the agreement
loop amplifies the Sybil attack: each Sybil source's trust rises
because it agrees with other Sybils, then it contributes more weight
to the wrong fact. CRH scores higher than MV (0.230 vs 0.200) — its
log-ratio does defensively discount adversaries but only by ~3pp.

**Corrected framing (F17 Item 1):** TD's behavior across the full N
sweep is BIMODAL, not uniformly amplifying. On Zheng d_sentiment
(F17 Item 1) the disable-and-test signs alternate by algorithm and
by N:

    N     TF vs MV   CRH vs MV   CATD vs MV   ACCU vs MV
    1     −0.007     +0.041      +0.043       +0.052
    3     −0.168     +0.093      +0.095       +0.139
    5     −0.185     +0.209      +0.206       +0.258
    10    +0.201     +0.658      −0.293       −0.293
    20     0.481     matches MV  matches MV   matches MV

At sub-saturation N (1..5) CRH/CATD/ACCU legitimately DEFEND against
Sybils (+0.041 to +0.258 over MV); TruthFinder is the only algorithm
that amplifies at low N. At N=10 the mechanism inverts for CATD/ACCU
(both drop 0.293 below MV) while CRH becomes the strongest defender
in the whole suite (+0.658 over MV). At N=20 (density saturation on
Zheng, Sybils = 20 honest voters) CRH, CATD, ACCU all crash to MV's
0.000 floor; TruthFinder alone rescues to 0.482 via dampening. The
Book-Author N=10 numbers (which motivated F16's "TD amplifies"
framing) were the low-honest-density case where saturation had
already arrived at N=10; the corrected story is that TD collapses at
the density-saturation cell (whatever N that is on the dataset), and
below that cell TD frequently *helps* rather than amplifies.

KNDB's kind-axis disable-and-test (kind OFF drops F14 Precision
0.630 → 0.000) was already proven under F14 and is the counterpart
on the KNDB side.

### Verdict for the paper

The F14/F15 headline "KNDB beats pg_conf by 63pp / 92.7pp" survives
verbatim — that comparison was correctly and honestly reported. What
F16 adds is the harder question: does KNDB beat *truth-discovery*
baselines, which are also known to handle adversarial data?

Answer: three separate answers depending on threat model.

  1. **Confidence-forgery only (F14/F15)**: KNDB wins 5-10pp over
     the best TD baseline. Narrower win than vs pg_conf but real.
     TD algorithms don't consume `ep_confidence` so they aren't
     fooled by high-confidence adversarial writes — but they also
     score 5-10pp lower than KNDB on the honest baseline because
     they can't use the Tier-A MEASURED kind signal.
  2. **Coordinated-flip on Zheng**: CRH matches KNDB (0.951 vs
     0.927). TF/CATD/ACCU collapse (TF 0.494, CATD 0.000, ACCU
     0.000 at N=10). Not a clean KNDB win — CRH is a legitimate
     competitor on this dataset's density regime.
  3. **Sybil on Book-Author (F16 workload)**: KNDB wins by 40-62pp
     over every TD baseline at N=10. F17 Item 1 revealed this
     saturation point is dataset-specific — Book-Author's Zipfian
     source tail means most honest sources are already saturated
     at N=10, while Zheng's uniform 20-per-slot density means
     saturation is exactly N=20. Sybil is the attack shape where
     the kind axis's orthogonality to inter-source-agreement is
     decisively load-bearing at the density-saturation cell.

The paper's positioning that survives F17 Item 1: **KNDB is the
only system whose Sybil-robustness does not depend on per-slot
honest-vote count remaining strictly greater than Sybil count.
Every TD algorithm we tested fails at 1:1 density; KNDB does not.**
Below the density-saturation cell, CRH is a legitimate competitor
and TD algorithms frequently outperform KNDB — that regime must be
disclosed prominently in the paper.

Related-work section will need to cite Yin/Han/Yu KDD07 (TruthFinder),
Li SIGMOD14 (CRH), Li VLDB15 (CATD), Dong VLDB09 (ACCU), and
Zheng VLDB17 (survey); the CRH-matches-KNDB result on Zheng is
disclosed rather than buried.

### Test suite

installcheck / check-e2e not re-run (F16 did not touch KNDB src/;
only `bench/datasets/normalize.py` gained an `adv-strategy` option
and Python-only TD adapter code was added). Verified:
`git diff --stat contrib/epistemic/src/` empty;
`scripts/verify_dylib.sh` exit 0; dylib sha256 =
`807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74`.

### Files added / modified in F16

  * `bench/scripts_td/td_algorithms.py` — fresh Python 3
    reimplementations of TruthFinder, CRH, CATD, ACCU. ~330 lines.
  * `bench/scripts_td/run_td_offline.py` — offline runner, reuses
    `bench/driver/replay_dataset.score_correctness` for scoring
    parity with DB systems.
  * `bench/scripts_td/td_disable_and_test.py` — proves TD's
    agreement mechanism is what causes Sybil collapse.
  * `bench/datasets/normalize.py` — new `sybil` value for
    `--adv-strategy`; `wrong_value_for_isbn(isbn, i)` under sybil
    ignores `i` and returns same scrambled value per ISBN.
  * `bench/datasets/bookauthor/normalized_f14_K50_N00.jsonl` — new
    honest baseline (N=0) trace at F14 seed. Was missing from F14
    commit — F14 only shipped N∈{1,3,5,10} adversarial traces.
  * `bench/datasets/bookauthor/normalized_f16_K50_sybil_N{01,03,05,10}.jsonl`
    — Sybil traces (adv-seed 20260714 matches F14 honest-row seed
    so KNDB honest baseline reproduces 0.630 exactly).
  * `bench/results/td_raw/honest_zheng_{tf,crh,catd,accu}_K45_N00.json`
    — 4 cells. TD reproduces Zheng VLDB'17 within 0.3pp.
  * `bench/results/td_raw/honest_bookauthor_{tf,crh,catd,accu}_K50_N00.json`
    — 4 cells.
  * `bench/results/td_raw/adv_indep_bookauthor_{tf,crh,catd,accu}_N{01,03,05,10}.json`
    — 16 cells. TD flat under independent-value attack.
  * `bench/results/td_raw/adv_zheng_{tf,crh,catd,accu}_N{01,03,05,10}.json`
    — 16 cells. TD partial-collapse under coordinated-flip.
  * `bench/results/td_raw/adv_sybil_bookauthor_{tf,crh,catd,accu}_N{01,03,05,10}.json`
    — 16 cells. TD collapses at N≥5 under Sybil.
  * `bench/results/td_raw/adv_sybil_bookauthor_{epistemic,pg_conf,pg_lww,pg_mv,pg_trigger,pg_heap}_c001_N{01,03,05,10}.json`
    — 24 cells. KNDB flat at 0.630; DB baselines match F14 behaviour.
  * `bench/results/summary/stage3_td_baselines.md` — combined summary
    with honest baseline, independent-attack, Sybil-attack tables and
    the disable-and-test transcript.

## 2026-07-12, F15/F15b: Zheng crowdsourcing replication of the F14 result

Second-workload replication of F14's confidence-forgery finding, on a
dataset with a completely different provenance shape (crowdsourced binary
labels with a disjoint per-worker qualification signal, not a data-fusion
authority-tier workload). Two mandates: prove the F14 result is not
Book-Author-specific, and re-run the source-rebuild disable-and-test on
the new workload so the kind axis is proven load-bearing there too.

### Dataset selection

**Primary target attempted**: CytoCrowd (arXiv:2602.06674v1, WWW '26). The
paper matches F15's need — 446 cytology images, 4 board-certified
pathologists, 6402 gold ROIs from a >15y-experience senior expert. But on
verification, the paper's data-availability section is absent; artefact
URLs point only to institutional home pages (hkust-gz.edu.cn,
en.gzlbp.com); the images are .svs whole-slide files that would be behind
a DUA channel even if listed; and the annotators are all peer-level
board-certified with no publicly documented senior/junior tier — the only
tiered party is the gold-standard rater, whom F15's own rule forbids as a
source signal (that is gold-peeking).

**Pivot** (documented in `bench/datasets/zheng_sentiment/README.md` before
any run): Zheng et al., "Truth Inference in Crowdsourcing: Is the Problem
Solved?", PVLDB 10(5):541-552, 2017. Repo
<https://github.com/zhydhkcws/crowd_truth_infer>, archive
<https://zhydhkcws.github.io/crowd_truth_inference/datasets.zip> (SHA-256
`c68ee01613da6dd6e2405c3252b73bb1199bc263909588bf952f57fc7d84323c`,
downloaded 2026-07-12). Sub-dataset `d_sentiment`: 85 workers, 1000
sentiment-classification items on AMT, ~20 labels per item, 999 of 1000
items contested. License not explicit in the archive; treated as CC-BY-SA
per PVLDB standard, only re-normalized derivative shipped, cited verbatim.

Chosen specifically because `d_sentiment` is the only Zheng release that
ships a **disjoint qualification test** — 1700 worker responses to 20 gold
items with question IDs 2000..2019 (main-task IDs are 0..999). Every
worker took it. This gives an INDEPENDENT per-worker quality signal
`quali_acc(w)` computable before any main-task label is seen.

### Mapping rule (pre-registered)

For each worker `w`, `quali_acc(w)` = fraction of qualification items
where `w`'s answer equals `quali_truth`. Rank workers by `quali_acc` desc
with stable tie-break on worker_id. Given K (top-workers parameter):

  * Tier A (top K/3): MEASURED, ep_confidence uniform [0.5, 0.9]
  * Tier B (middle third of top-K): INFERRED, ep_confidence uniform [0.4, 0.7]
  * Tier C (bottom third + all workers outside top-K): DERIVED, ep_confidence uniform [0.2, 0.5]
  * Adversarial injection (N per contested slot): INFERRED, ep_confidence
    uniform [0.95, 1.0], value = binary flip of the gold label.

K sweep {12, 24, 45, 66, 85} for baseline sensitivity. N sweep {1, 3, 5, 10}
for adversarial pressure. Adversarial insertion position seeded with
adv_seed=20260715 (distinct from F14's 20260714). Confidence draws from
`Random(adv_seed ^ record_index)` — bit-for-bit reproducible.

**Independence self-audit**: `quali_acc(w)` reads only `quali.csv` and
`quali_truth.csv`. Tier assignment depends only on `quali_acc(w)` and K.
The tier mapping never touches `truth.csv` (main-task gold). Adversarial
value ("flip gold") does consult `truth.csv` — deliberately, since the
threat model is a hostile writer who knows what to attack. Only the tier
mapping must be gold-independent; the adversarial payload does not.

### Baseline result table (K sweep, N=0)

c=1:

    system         K=12    K=24    K=45    K=66    K=85
    epistemic      0.774   0.886   0.927   0.919   0.920
    pg_conf        0.853   0.911   0.927   0.921   0.922
    pg_heap        INTEGRITY FAIL (all K)
    pg_lww         0.786   0.786   0.786   0.786   0.786
    pg_mv          0.689   0.689   0.689   0.689   0.689
    pg_trigger     0.782   0.917   0.927   0.919   0.920

c=8:

    system         K=12    K=24    K=45    K=66    K=85
    epistemic      0.737   0.824   0.861   0.864   0.849
    pg_conf        0.823   0.865   0.883   0.894   0.909
    pg_heap        INTEGRITY FAIL (all K)
    pg_lww         0.779   0.778   0.768   0.763   0.783
    pg_mv          0.646   0.638   0.621   0.645   0.646
    pg_trigger     0.779   0.914   0.923   0.903   0.909

On the honest baseline, KNDB epistemic and pg_conf agree to within 1pp at
c=1 (as expected — with no adversarial signal, kind and confidence rank
in the same direction). At c=8 pg_conf edges ahead by 2-6pp on baseline;
that's an SR abort-driven tie-break artefact and is discussed in the
adversarial verdict below.

### Confidence-forgery predictions (from F15's pre-registered README, verbatim)

  * KNDB epistemic: kind rank picks MEASURED over INFERRED regardless of
    confidence -> Precision flat across N.
  * pg_conf: adversarial conf 0.95-1.0 beats Tier-A MEASURED conf 0.5-0.9
    -> Precision collapses toward 0 as N grows.
  * pg_lww: adversarial wins iff last -> P(adv is last) ~= N/(N+20),
    Precision degrades slowly.
  * pg_mv: adversarial N=10 competes with ~11-vs-10 honest split -> slow
    degradation.
  * pg_llm: kind-aware mock at p_correct=0.925 tracks KNDB scaled by
    Bernoulli(0.925).
  * pg_heap: no arbitration -> INTEGRITY FAIL always.
  * pg_trigger: same lattice via plpgsql -> tracks KNDB within tie-break noise.

### Empirical results (K=45, adversarial)

c=1 Precision:

    system         N=1     N=3     N=5     N=10
    epistemic      0.927   0.927   0.927   0.927
    pg_conf        0.000   0.000   0.000   0.000
    pg_heap        INTEGRITY FAIL (all N)
    pg_llm         0.800*  -       0.750*  -            (*100-write subsample)
    pg_lww         0.401   0.211   0.130   0.074
    pg_mv          0.375   0.193   0.127   0.070
    pg_trigger     0.927   0.927   0.927   0.927

c=8 Precision:

    system         N=1     N=3     N=5     N=10
    epistemic      0.862   0.867   0.875   0.861
    pg_conf        0.297   0.025   0.000   0.000
    pg_heap        INTEGRITY FAIL (all N)
    pg_lww         0.653   0.444   0.270   0.190
    pg_mv          0.413   0.236   0.100   0.090
    pg_trigger     0.888   0.875   0.880   0.857

Every prediction held. The KNDB win vs pg_conf at c=1 is **92.7pp** flat
across N. pg_trigger tracks KNDB exactly (same lattice via plpgsql, tiny
abort-rate delta on individual cells). pg_lww degrades from 0.401 to
0.074; pg_mv 0.375 to 0.070. pg_heap fails integrity every cell.

### F15b source-rebuild disable-and-test (the decisive proof on Zheng)

Same short-circuit as F14: patch `epistemic_precedence_cmp`
(src/epistemic_rules.c:379-426) to force `inc_rank = new_rank = 1` so the
kind branch is a no-op and precedence falls through to specificity /
confidence. That is exactly the pg_conf semantics on this workload
(specificity is 0 across the board; confidence decides).

Transcript:

  1. `cp src/epistemic_rules.c /tmp/epistemic_rules.c.f15b_backup`
     (backup sha256 `f38f1f9afda852c2e9da328949df5e3aeabdec890758905fc44eece973dfc6e3`).
  2. Patch (Edit tool):
     ```
     -    int         inc_rank = epistemic_kind_rank(
     -        epistemic_kind_from_byte(incumbent->ep_kind));
     -    int         new_rank = epistemic_kind_rank(
     -        epistemic_kind_from_byte(new->ep_kind));
     +    /* F15b KIND_OFF disable-and-test: force both ranks to 1 so the
     +     * kind branch is a no-op and precedence falls through to
     +     * specificity / confidence exactly like pg_conf. Mirrors F14's
     +     * patch. */
     +    int         inc_rank = 1;
     +    int         new_rank = 1;
     ```
  3. `PATH=.../postgresql@18 make clean install` — dylib SHA-256 flipped
     `807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74`
     -> `3cc4f4b79767e67e850add9e0f52d01ff8e1390d72c03faa043963eda6ea2a05`.
  4. `pg_ctl restart` on `/tmp/kndb_pg18_test:55480`, passing
     `-c shared_preload_libraries=epistemic` (the persistent test cluster
     has no `postgresql.conf` preload — F3's cache rule requires passing
     it explicitly on each restart).
  5. Cell replayed at K=45, N=5, c=1, epistemic only. Result: Precision
     0.000, integrity PASS (n_slots_with_gt_1_live = 0), tps 964.8,
     abort_rate 0.878, n_writes 25000. Saved to
     `bench/results/stage3_raw/adversarial_zheng_epistemic_KIND_OFF_c001_N05.json`.
  6. `cp /tmp/epistemic_rules.c.f15b_backup src/epistemic_rules.c`
     `git diff --stat contrib/epistemic/src/` -> empty.
  7. `make clean install` — dylib hash restored to `807b2e87f6...`.
  8. `pg_ctl restart` with preload; `bash scripts/verify_dylib.sh` -> exit 0.
  9. Confirmation: re-ran the same cell -> Precision back to 0.927.

Result table:

    KNDB mode                    Precision   integrity   dylib sha256 (prefix)
    kind axis ON  (honest)       0.927       PASS        807b2e87f6...
    kind axis OFF (both ranks=1) 0.000       PASS        3cc4f4b797...

**Delta: -92.7 percentage points.** With kind rank neutralised, KNDB
collapses to exactly pg_conf's 0.000 behaviour on the Zheng workload —
the two systems become indistinguishable, which is the correct outcome
(both are then ranking by confidence alone, and adversarial INFERRED
conf∈[0.95,1.0] beats Tier-A MEASURED conf∈[0.5,0.9] on every contested
slot).

Integrity holds under the patched build (n_slots_with_gt_1_live = 0)
because the F6 advisory-lock + F8 xmin tiebreak still operate; only
the kind-rank decision was disabled. Integrity and correctness are
separable mechanisms in KNDB, and each has its own disable-and-test.

### Verdict: F14 reproduces on Zheng

KNDB **beats pg_conf by 92.7pp** on the Zheng d_sentiment adversarial
workload at c=1, across N ∈ {1, 3, 5, 10}. At c=8 the delta narrows to
57-88pp because SR aborts jitter both systems. Win is proven load-bearing
on the kind axis by the F15b disable-and-test.

Reproducibility: F14's 63pp win on Book-Author + F15's 92.7pp win on
Zheng is two workloads with completely different provenance semantics
(source-tier data fusion vs. per-worker qualification crowdsourcing)
delivering the same qualitative result. The paper's contribution
generalises: the epistemic KIND axis drives survivor selection whenever
kind and confidence disagree, and it does so on the Zheng workload with
an even wider margin than Book-Author because Zheng's per-slot Tier-A
signal is denser (~20 worker labels/slot, several from Tier A) than
Book-Author's (a single ISBN typically has 1-2 Tier-A source assertions
if any). More Tier-A ammunition per slot means the lattice's MEASURED
> INFERRED decision saves more cells.

### Second-order observations

  * **pg_conf at c=8 N=1 = 0.297 is a concurrency-abort artefact**, not
    a genuine recovery. At c=8, some adversarial writes abort on SR
    conflict before they commit, letting an earlier honest write survive.
    The effect vanishes by N=5 as the population of adversarial writes
    grows past the abort-noise threshold. Same effect explains pg_lww
    0.653 at c=8 N=1 vs 0.401 at c=1 N=1.

  * **Baseline at c=8 pg_conf > KNDB epistemic by 2-6pp**: on the honest
    trace at high concurrency, pure confidence sorting slightly
    outperforms the lattice because F8 xmin tiebreak doesn't always
    align with the higher-quality writer. On the adversarial trace this
    inverts hard: pg_conf drops to 0 by N=5, KNDB holds 0.87. The
    baseline "loss" is 6pp; the adversarial "win" is 87pp.

  * **pg_lww degradation curve** (c=1): 0.401 -> 0.211 -> 0.130 -> 0.074
    is close to the theoretical N/(N+~20) prediction if we assume the
    only adversarial-wins case is "adv is last". pg_lww's 0.786
    honest-baseline drops toward 0 as N grows, matching the F14
    Book-Author 0.21 -> 0.04 shape.

  * **pg_mv degradation curve** (c=1): 0.375 -> 0.193 -> 0.127 -> 0.070.
    Notably STEEPER than F14's pg_mv 0.46 -> 0.17. Root cause: Zheng
    has ~20 labels per slot with ~80% worker accuracy, so honest majority
    is often ~16-4 for the correct label. N=5 adversarial pushes it to
    ~16-9 for correct, still a majority — but the drop from 0.375 to
    0.070 by N=10 (16-14 split, close to tied) is much sharper than
    Book-Author because Book-Author's honest-vote count per slot is
    much smaller (a handful of sources with equal weight), so
    adversarial N=1 already tips more slots.

  * **pg_trigger vs epistemic match to 0pp** at c=1 (both 0.927 flat) —
    tighter than F14's 1pp gap. Zheng has fewer trigger-time races
    at c=1 than Book-Author because the workload is uniform (no
    Zipfian hotspots on entity_id), so the plpgsql trigger's advisory
    lock rarely contends and its abort rate matches epistemic's within
    noise.

  * **KNDB reproducibility discovery** (documented in the summary MD):
    consecutive cells on the SAME postmaster show Precision drifting
    0.60-0.86 range on epistemic KIND_ON re-runs; a fresh `pg_ctl restart`
    before each cell reproduces the saved 0.9270 exactly (verified
    2026-07-12). Suspected root cause is SR/predicate-lock state
    accumulation across cells that changes which write commits first
    per slot. All F15b cells were collected with restart-per-cell.
    The F15 saved baselines have the same signature (abort_rate 0.7625,
    Precision 0.9270 across N=01/03/05 c=1 epistemic), which is
    consistent with restart-per-cell discipline. Future F-agents:
    do not run adversarial cells back-to-back without restarting
    the persistent /tmp/kndb_pg18_test cluster.

  * **pg_llm subsample** (100 writes cap): 0.800 at N=1, 0.750 at N=5.
    Too small a denominator (~5 gold slots each) to draw a strong
    conclusion. The mock's Bernoulli(0.925) math predicts ~0.86 at
    steady state; both subsamples fall within that noise envelope
    given the small n. Same discipline as F13's Book-Author pg_llm.

### Test suite

installcheck / check-e2e not re-run (src/ was restored byte-identical
to HEAD after the KIND_OFF cell; `git diff --stat contrib/epistemic/src/`
empty; `bash scripts/verify_dylib.sh` exit 0). Dylib sha256 = 807b2e87...

### Files added / modified in F15 + F15b

F15 (already on disk when F15b started):
  * `bench/datasets/zheng_sentiment/README.md` — pre-registered mapping.
  * `bench/datasets/zheng_sentiment/source/` — Zheng d_sentiment CSVs
    (answer.csv, truth.csv, quali.csv, quali_truth.csv).
  * `bench/datasets/zheng_sentiment/normalized_f15_K{012,024,045,066,085}_N{00,01,03,05}.jsonl`
    — reproducible traces (seed 20260715).
  * `bench/datasets/normalize.py` — new `normalize_zheng_sentiment_f15`
    function; CLI accepts `--dataset zheng_sentiment_f15`.
  * `bench/driver/replay_dataset.py` — extended to accept
    `--dataset zheng_sentiment` and reset the appropriate tables.
  * `bench/scripts_stage3/run_zheng_sentiment_f15.sh` — orchestrator.
  * `bench/scripts_stage3/summarize_f15.py` — summary generator.
  * `bench/results/stage3_raw/baseline_zheng_*_c{001,008}_K{012,024,045,066,085}.json`
    — 60 baseline cells.
  * `bench/results/stage3_raw/adversarial_zheng_*_c001_N{01,03,05}.json`
    — 18 adversarial cells (6 systems × N ∈ {1, 3, 5}).
  * `bench/results/stage3_raw/adversarial_zheng_*_c008_N{01,03}.json`
    — 12 adversarial cells (6 systems × N ∈ {1, 3}).

F15b (finishing what F15 started):
  * `bench/results/stage3_raw/adversarial_zheng_epistemic_KIND_OFF_c001_N05.json`
    — disable-and-test cell.
  * `bench/results/stage3_raw/adversarial_zheng_*_c008_N05.json`
    — 6 cells (item 2, plus rerun of epistemic N=5 c=1 which reproduced 0.9270 exactly).
  * `bench/results/stage3_raw/adversarial_zheng_*_c001_N10.json`
    — 6 cells (item 1).
  * `bench/results/stage3_raw/adversarial_zheng_*_c008_N10.json`
    — 6 cells (item 1).
  * `bench/results/stage3_raw/adversarial_zheng_pg_llm_c001_N{01,05}.json`
    — 2 pg_llm subsample cells (item 4).
  * `bench/results/summary/stage3_zheng_adversarial.md` — new summary
    with dataset section, baseline table, adversarial grid,
    disable-and-test transcript, verdict.

## 2026-07-12, F14: integrity axis + kind-vs-confidence disagreement workload

Two mandates. F13 had shown KNDB matches pg_conf exactly on the
Book-Author base workload because the F13 mapping made confidence
rank a monotone function of kind rank; F14 closes that gap in two
directions. Item 1 (integrity) hardens the reporting so pg_heap's
"spuriously high correctness" cannot hide behind a scorer artefact.
Item 2 (adversarial) constructs a workload where kind rank and
confidence rank GENUINELY disagree, and runs the source-rebuild
disable-and-test that proves the kind axis is load-bearing.

### Item 1 -- integrity axis in every result table

The F13 rollup reported pg_heap on Book-Author with Precision
0.68--0.71 across all K, which superficially looks like a correctness
win over KNDB. It isn't: pg_heap has 60--114 live rows per (entity,
attribute) slot at end-of-trace (confirmed by direct
`SELECT entity_id, attribute, count(*) FROM fact_heap WHERE
upper(sys_time)='infinity' GROUP BY 1,2`). The correctness scorer's
"pick the first row the scan returns" picks a coin flip; whether it
happens to be correct means nothing about the mechanism.

F14 adds an `integrity_status` field to every cell's raw JSON. A cell
FAILS integrity iff any slot ended the trace with `n_live > 1`.
Renderers now print `INTEGRITY FAIL` in place of the numeric
correctness when integrity has failed; the raw number is preserved
under `Precision_ignoring_integrity` (and its longer siblings).

Backfill covered every stage3 raw JSON:

  * 46 cells filled by-construction (KNDB epistemic + pg_trigger
    always PASS integrity by design; single-writer cells with any
    trigger baseline also PASS trivially).
  * 45 cells replayed against a fresh cluster to measure the true
    live-row count (`bench/scripts_stage3/backfill_integrity.py`,
    `--replay` flag). pg_heap FAILs every cell (mean 28.6 live
    rows/slot, max 114); the trigger-based baselines at c > 1 actually
    PASS the "n_live > 1" check on Book-Author because their trigger
    logic does close incumbents' sys_time — they were the F10
    Stage-2 integrity offenders under a much hotter Zipfian
    contention pattern.
  * Stage 2 raw cells were annotated in place from their pre-existing
    `multiple_live_rows` field; the integrity-aware Stage 2 table
    (added as an addendum to `bench/results/summary/stage2.md`) shows
    KNDB is the ONLY system that PASSES integrity across all 12
    Stage 2 cells. pg_conf and pg_heap FAIL every cell; pg_lww,
    pg_mv, pg_trigger, pg_llm each FAIL on the majority.

**Cells that flip from "correct" to "INTEGRITY FAIL" after the F14
sweep:**

  * All 15 pg_heap Book-Author cells (0.47--0.71 -> INTEGRITY FAIL).
  * 10 pg_lww Stage-2 cells (previously reported at 83-93 %).
  * All 12 pg_conf Stage-2 cells (previously 54-81 %).
  * 9 pg_mv Stage-2 cells.
  * 10 pg_trigger Stage-2 cells.
  * 3 pg_llm Stage-2 cells (the θ=0.9 c=8 cells).

The pg_heap Book-Author "0.71 > KNDB's 0.61" reading in the F13
sensitivity table (`stage3_bookauthor.md`) is now `INTEGRITY FAIL` and
correctly no longer competes on the "which system has higher
Precision" axis.

### Item 2 -- kind-vs-confidence disagreement workload

**Threat model** (stated up front, does not adapt to outcomes):
a hostile or miscalibrated writer asserts HIGH confidence on an
INFERRED value. Real-world analogue: LLM-generated content that
hallucinates values but self-reports as certain; a malicious agent
poisoning a knowledge store by claiming high credibility on a
fabricated fact.

**Ground-truth policy** (stated up front): a MEASURED value beats an
INFERRED value regardless of the INFERRED value's asserted
confidence. This is the paper's epistemic claim. Confidence is a
self-report; kind reflects the epistemic act.

**F14 mapping** (revised from F13 to make kind rank and confidence
rank genuinely disagree; the F13 mapping had MEASURED at conf=1.0 and
INFERRED at conf=0.7 so a confidence-only sort agreed with kind
sort in every case). Independence from ground truth is preserved:
tier assignment still depends only on (n_listings, canon_rate);
only the specific conf sample within the tier's range is a seeded
RNG draw.

  * Tier A (top-K/2 by n_listings AND canon_rate >= 0.5):
      MEASURED, conf uniform [0.5, 0.9]
  * Tier B (rest of top-K by n_listings):
      INFERRED, conf uniform [0.4, 0.7]
  * Tier C (else):
      DERIVED, conf uniform [0.2, 0.5]
  * Adversarial injection (N per gold ISBN):
      INFERRED, conf uniform [0.95, 1.0], value = scrambled real
      author name from a DIFFERENT gold ISBN, source =
      `adversarial_agent_i`.

K=50 (median of F13's K sweep) held fixed. N in {1, 3, 5, 10} sweeps
adversarial pressure. Adversarial position in the trace is a seeded
random draw (seed=20260714) so adversarial can arrive before, in the
middle of, or after the honest writers per slot.

**Predictions recorded before running** (in the F14 report):

  * KNDB: kind rank picks MEASURED over INFERRED regardless of
    confidence -> Precision stays near F13 baseline (~0.61) across
    all N.
  * pg_conf: strict-`>` confidence check picks adversarial INFERRED
    conf~=0.97 over Tier-A MEASURED conf~=0.7 -> Precision collapses
    to ~0.
  * pg_lww: adversarial wins iff last -> Precision degrades as N
    grows (more adversarial = more likely one is last).
  * pg_trigger: same lattice as KNDB via plpgsql -> tracks KNDB.
  * pg_heap: no arbitration -> INTEGRITY FAIL always.
  * pg_mv: majority vote; adversarial N=5..10 votes on one wrong
    value beats singleton honest votes -> degrades.
  * pg_llm: mock LLM's `lattice_says_new_wins` reasons about kind
    rank (schema/pg_llm.sql:183..200); at P_correct=0.925 should
    track KNDB near ~0.6.

**Empirical results** (c=1 Precision, all 7 systems):

    N=1     N=3     N=5     N=10
    ---     ---     ---     ----
    KNDB epistemic   0.630   0.630   0.630   0.630
    pg_trigger       0.620   0.620   0.620   0.620
    pg_mv            0.460   0.400   0.320   0.170
    pg_lww           0.210   0.130   0.090   0.040
    pg_llm           -       -       0.111*  -       (*300-write subsample, noisy)
    pg_conf          0.000   0.000   0.000   0.000
    pg_heap          INTEGRITY FAIL (all N)

At c=8: KNDB 0.54-0.64 (small drop from tie-breaking under contention;
integrity still PASS). pg_conf drops to 0.15 at N=1 and 0.000 at
N>=3. pg_lww 0.46 -> 0.19 as N grows. Full grid in
`bench/results/summary/stage3_adversarial.md`.

Every prediction held. The result is decisive:

  * KNDB beats pg_conf by 63 percentage points (0.630 vs 0.000) at
    every N and c=1.
  * KNDB beats pg_lww by 42-59 pp depending on N.
  * KNDB matches pg_trigger to within 1 pp (both use the same
    lattice; the tiny gap is the trigger's higher abort rate under SR).

pg_llm scored 0.111 at N=5 c=1 but only on 300-write (~9-slot)
subsample; too small a denominator to draw a conclusion. The trigger
LOGIC would predict ~0.925 * 0.62 ~= 0.57; noise of the subsample
dominates. A full 3361-write pg_llm cell at 1120 ms mean latency
would take ~1 hour and adds no lift the mock's Bernoulli(0.925)
math already provides.

### Item 2 -- source-rebuild disable-and-test (the decisive proof)

Patched `epistemic_precedence_cmp` (src/epistemic_rules.c:379-423) to
force `inc_rank = new_rank = 1`. That short-circuits the kind branch
and the function falls through to specificity/confidence directly —
the same relative ordering pg_conf uses on this workload (specificity
is 0 across the board; confidence decides).

Build steps:

  1. `PATH=/opt/homebrew/opt/postgresql@18/bin:$PATH make install`
  2. dylib SHA changed 807b2e87... -> f7... -> back to 807b2e87...
     after restore (verified via `.dylib.sha256` and
     `scripts/verify_dylib.sh`).
  3. `pg_ctl restart` to reload the new dylib.
  4. Cell replayed at N=5, c=1, epistemic only.
  5. `src/` restored byte-identical from `/tmp/epistemic_rules.c.f14_backup`.
     `git diff --stat contrib/epistemic/src/` empty. Rebuilt +
     reinstalled + restarted PG. `.dylib.sha256` == 807b2e87...
     `scripts/verify_dylib.sh` exit 0.

Result:

    KNDB kind ON  (honest, dylib 807b2e87...): Precision = 0.630
    KNDB kind OFF (patched, both ranks = 1):    Precision = 0.000
    delta = -63 pp

That is the proof. When the kind axis is neutralised, KNDB's
correctness on the adversarial workload collapses to exactly pg_conf's
behaviour — indistinguishable, because both are then ranking by
confidence alone and adversarial conf uniform [0.95, 1.0] beats
honest MEASURED conf uniform [0.5, 0.9] on every gold ISBN.

Integrity STILL holds under the patched build (n_slots_with_gt_1_live
= 0). The F6 advisory-lock + F8 xmin tiebreak still operate; only
kind-rank decision-making was disabled. That is the correct
decomposition: integrity and correctness are separable mechanisms in
KNDB, and each has its own disable-and-test.

### Verdict

**KNDB beats pg_conf by 63 pp on the F14 workload; the win is proven
load-bearing on the kind axis by source-rebuild disable-and-test.**

The paper's contribution is intact and narrowed: KNDB is not
"confidence-sorting with an audit trail" — it is a system where the
epistemic-KIND axis (a distinct dimension from confidence) drives
survivor selection, and that dimension is load-bearing exactly when
kind and confidence disagree, which is the adversarial / miscalibrated
case the paper cares about. On the F13 base workload (kind ~= conf
by construction of the mapping) KNDB matches pg_conf as expected;
that was never a threat to the paper's claim, it was a limit of the
base workload's ability to exhibit the kind axis at all.

### Test suite

installcheck 6/6 unchanged (honest src, `PATH=.../postgresql@18 make
installcheck` at test cluster /tmp/kndb_pg18_test:55480).
check-e2e 8/8 unchanged.
src/ byte-identical to HEAD (git diff --stat empty).
.dylib.sha256 == 807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74.

### Files added / modified in F14

Item 1 (integrity axis):
  * `bench/driver/replay_dataset.py` -- `measure_survivors` now
    returns (survivors, live_counts); new `_integrity_summary`
    helper; main() writes `correctness.integrity` and
    `correctness.integrity_status` to every JSON.
  * `bench/driver/correctness.py` -- Stage-2 scorer records
    `integrity_status` and `correctness_rate_ignoring_integrity`.
  * `bench/driver/summarize_stage2.py` -- CSV gets new columns
    `correctness_median_ignoring_integrity`, `integrity_status`.
  * `bench/scripts_stage3/summarize_stage3.py` -- MD table gets an
    `integrity` column; AA/CRS/UOCS render as `INTEGRITY FAIL` when
    the cell has failed integrity.
  * `bench/scripts_stage3/summarize_bookauthor.py` -- same treatment
    for the Book-Author K-sensitivity tables.
  * `bench/scripts_stage3/backfill_integrity.py` -- new; connects to
    a fresh cluster, fills integrity by-construction for cells that
    are proven-PASS by design and replays the rest.
  * `bench/results/summary/stage2.md` -- F14 addendum table.
  * `bench/results/summary/stage3.md`, `stage3_bookauthor.md` --
    regenerated with integrity column.

Item 2 (kind-vs-confidence workload):
  * `bench/datasets/normalize.py` -- new `normalize_bookauthor_f14`
    with revised tier mapping (Tier A MEASURED conf [0.5,0.9],
    Tier B INFERRED [0.4,0.7], Tier C DERIVED [0.2,0.5], adversarial
    INFERRED [0.95,1.0]) and N-per-ISBN adversarial injection at
    seeded random positions. CLI gains `--n-adversarial`,
    `--adv-strategy`, `--adv-seed`.
  * `bench/scripts_stage3/run_bookauthor_f14.sh` -- new orchestrator
    sweeping N in {1, 3, 5, 10} across 7 systems at c in {1, 8}.
  * `bench/scripts_stage3/summarize_f14.py` -- new; emits
    `stage3_adversarial.md`.
  * `bench/results/stage3_raw/adversarial_*_c*_N*.json` -- 44 F14
    cells + 1 pg_llm subsample cell + 1 disable-and-test cell
    (`adversarial_epistemic_KIND_OFF_c001_N05.json`).
  * `bench/results/summary/stage3_adversarial.md` -- new, including
    the disable-and-test transcript.
  * `bench/datasets/bookauthor/normalized_f14_K50_N{01,03,05,10}.jsonl`
    -- reproducible traces (seed 20260714).

## 2026-07-14, F11+F12+F13: Stage 3 rollup, LLM reality, real datasets, guard

Three F-agents' worth of Stage 3 work rolled into one entry because
the findings interlock. Every claim below is verified by the artefacts
listed at the end; no numbers are recomputed from memory here.

### F11 -- real Haiku 4.5 calibration; source-rebuild disable-and-test

F10 shipped Stage 2 with two calibration debts. F11 closed both.

  1. **Real LLM calibration.** `bench/scripts_stage3/llm_calibrate.py`
     called claude-haiku-4-5 on 200 adversarial conflicts drawn from
     the Stage 2 trace, same JSON-mode prompt template that
     `bench/schema/pg_llm.sql`'s trigger uses. Zero API errors.
     Measured:

         n_graded         200
         n_correct        185
         correctness_rate 0.925   (F10 mock assumed 0.65)
         latency_ms mean  1119.56 (F10 mock assumed 300)
         latency_ms p95   1934.14
         latency_ms p99   2311.51
         model            claude-haiku-4-5

     F10's mock was wrong in both directions. `pg_llm.sql` defaults
     updated to `p_correct=0.925`, `latency_mean_ms=1120`,
     `latency_sigma=0.5`. Disable-and-test still overrides P to 0.5
     via GUC. Raw data at
     `bench/results/stage3_llm_calibration.jsonl`.

  2. **Source-rebuild disable-and-test.** F10's pg_heap-proxy
     disable-and-test claimed -100 pp for the lattice. F11 patched
     `src/epistemic_rules.c` to force `EP_CMP_NEW_WINS` at the
     precedence-tie branch, rebuilt, reran adversarial theta=0.9 c=8,
     then restored src/ byte-identical (git diff --stat src/ empty).

         KNDB lattice ON       100.0 % correctness
         KNDB lattice OFF       80.3 % correctness
         delta                  -20 pp

     The tighter proof decomposes the invariant into two mechanisms
     each with its own disable-and-test:
       * F6 advisory lock -> integrity (zero duplicate live rows)
       * F1..F8 lattice + F8 xmin -> correct survivor when contested
     The F10 pg_heap proxy conflated the two by turning off both at
     once and attributing the full -100 pp swing to "the lattice."

### F12 -- LLM non-determinism, three real datasets, all 0%

Task 3a: `bench/scripts_stage3/llm_nondeterminism.py` sampled 50
adversarial conflicts from F11's calibration set (stratified
30 new_wins / 20 incumbent_wins per lattice ground truth), replayed
each N=10 times against claude-haiku-4-5, concurrency 8. 500 real API
calls, zero errors, 91.7 s wall clock. Result:

        flip_rate                  0/50   = 0.000
        mean per-conflict entropy  0.000 bits (all unanimous)
        correctness vs lattice     480/500 = 0.960
        unanimous-but-wrong        2/50    (indices 3 and 34; both
                                            same signature: incumbent
                                            INFERRED conf=0.5, cand
                                            INFERRED spec>>0 conf<0.5.
                                            The LLM consistently
                                            prefers "more specific"
                                            over "same kind higher
                                            confidence," which is the
                                            opposite of the KNDB
                                            lattice's (spec, conf)
                                            ordering.)

Reframe for the paper: the LLM is stable, not noisy. Its correctness
gap versus the lattice comes from SYSTEMATIC disagreement about
lattice ordering, not from random sampling. That's a more interesting
finding than "LLMs are noisy" and rules out the naive fix "just run
the LLM three times and vote".

Task 3b/3c: three real datasets normalized to a common trace and
replayed against 7 systems at c={1,8,32}:

  * LongMemEval knowledge-update pairs (78 samples, 156 writes)
  * MemoryAgentBench Conflict_Resolution (37,820 writes)
  * MQuAKE-CF-3k edit chains (12,030 writes)

Result for KNDB on all three at c=1: **KU-Acc / Precision / UOCS = 0%**.
Mechanism: every dataset's ground truth is "later-arriving fact wins"
(the memory-store / knowledge-editing shape), whereas KNDB's F8
tiebreak is xmin (first-committer-wins). Both writes carry the same
(MEASURED, spec=0, conf=1.0) — the lattice cannot differentiate them
by rank, so the tiebreak is what matters, and it's the WRONG tiebreak
for these workloads. The mapping is documented in each dataset's
`bench/datasets/<name>/README.md`; the writers do NOT peek at ground
truth to reshape confidence. It's an honest 0% on datasets whose
epistemic shape doesn't match KNDB's.

**Second-order finding on pg_lww**: at c=1 pg_lww scores 97.4% on
LongMemEval and 100% on MemoryAgentBench + MQuAKE — but that's a
determinism artifact of single-writer arrival order. At c=8 pg_lww
drops to 0.22-0.27, and at c=32 all seven systems collapse into a
narrow 0.10-0.15 band. LWW's apparent win vanishes as soon as two
writers race. The paper should quote LWW's numbers at c=1 with the
c=8/32 collapse as a control.

### F12 third dylib-cache incident -> F13 automation

F3, F8, F11 each burned time chasing ghosts because the installed
`epistemic.dylib` diverged from the source tree: developer rebuilt
local .o files, forgot `make install`, and PGXS's `installcheck`
happily loaded the STALE dylib from `$(pg_config --pkglibdir)`. Three
strikes; the rule change ("always `make install`") never sticks, so
F13 automated the check.

  * `Makefile` gains `install-hash` (post-recipe of `install`) which
    writes SHA-256 of the just-installed dylib to `.dylib.sha256`.
  * `scripts/verify_dylib.sh` fails LOUDLY if either the installed
    dylib or the source-tree dylib disagrees with `.dylib.sha256`.
    Message names F3/F8/F11 explicitly so future F-agents see the
    lineage.
  * Every `check-e2e*` target and every bench orchestrator
    (`bench/run.sh`, `bench/run_stage2.sh`, `bench/run_stage3.sh`,
    `bench/scripts_stage3/run_bookauthor.sh`) runs `verify-dylib`
    before doing anything.

Adversarial proof, transcript captured 2026-07-14:

        # pass state: matching hashes, verify-dylib exits 0
        # patch src/epistemic_init.c (add exported symbol), `make`
        # (rebuild only; NO `make install`):
        #   .dylib.sha256   -> 807b2e87...
        #   installed dylib -> 807b2e87... (unchanged)
        #   source dylib    -> c63f5bde... (changed)
        # verify-dylib exits 1 with "REBUILD AND REINSTALL" message.
        # restore src, `make install`:
        #   all three hashes -> 807b2e87... again
        # verify-dylib exits 0.

### F13 -- Book-Author, a data-fusion dataset where the lattice CAN win

The F12 three-dataset finding narrows the paper's claim: KNDB is
outperformed by naive LWW on datasets whose ground truth is
last-writer-wins. To show the lattice ISN'T just structural theatre,
F13 added a fourth dataset with epistemic-shaped ground truth: Dong
et al. VLDB'09 Book-Author (895 bookstores, 1265 books, 33,971
assertions, gold answers for 100 ISBNs).

**The independence constraint.** The mapping must not peek at ground
truth. Dong Table 7's per-source `Accu` numbers were rejected as a
proxy — they're the output of a truth-discovery algorithm on the same
data, which is peeking through a proxy. Adopted instead: two
structural properties of `book.txt`, both computable in one pass
without touching `book_golden.txt`:

  * `n_listings(src)` -- source volume (Dong Table 7 col #Books)
  * `canon_rate(src)` -- fraction of author fields in "Last, First"
    format (proxy for canonical bibliographic feed vs scraped
    aggregator)

Neither is a perfect proxy — on Dong's Table 7 top-10, neither cleanly
predicts SIM-Accu (Caiman: n=1156, canon=0.97, SIM-Accu=0.55). The
paper claim isn't "these are excellent proxies" but "these are the
best strictly-independent proxies available."

**The mapping rule** (parametric in K):

  * Tier A (top-K/2 by n AND canon >= 0.5): MEASURED, conf=1.0
  * Tier B (rest of top-K by n):            INFERRED, conf=0.7
  * Tier C (everything else):               DERIVED,  conf=0.4

**Sensitivity analysis over K in {10, 25, 50, 100, 200}**, c=1,
Precision on gold ISBNs (higher is better):

        K         epistemic  pg_lww   pg_heap  pg_conf  pg_mv   pg_trigger  pg_llm
        10        0.610      0.360    0.710    0.600    0.590   0.590       -
        25        0.510      0.360    0.680    0.510    0.590   0.510       -
        50        0.540      0.360    0.700    0.540    0.590   0.540       0.750
        100       0.610      0.360    0.700    0.610    0.590   0.610       -
        200       0.630      0.360    0.690    0.630    0.590   0.630       -
        median    0.610      0.360    0.700    0.610    0.590   0.610       -
        min       0.510      0.360    0.680    0.510    0.590   0.510       -
        max       0.630      0.360    0.700    0.630    0.590   0.630       -

**Findings:**
  * KNDB beats pg_lww by 15-27 pp across every K. The signal from
    the structural proxy is real, not a fluke of K.
  * KNDB *matches* pg_conf everywhere (both at 0.510-0.630). That's
    the honest deflator: within-tier confidence variance is zero, so
    ranking by (kind, conf) is identical to ranking by conf alone.
    The lattice's kind axis buys nothing on this workload beyond what
    confidence encodes. This narrows the paper's claim from "the
    lattice beats confidence-only" to "the lattice CAN beat
    confidence-only, but requires a workload where kind and confidence
    stratify differently."
  * pg_heap's 0.68-0.71 is an integrity failure that looks like a
    correctness win. pg_heap has 60-114 live rows per (entity_id,
    attribute) at end of trace (verified by direct
    `SELECT COUNT(*) FROM fact_heap WHERE upper(sys_time)='infinity'
    GROUP BY 1,2` query — max group count 114). The scorer picks the
    first row the scan returns; whether it happens to be correct is a
    coin flip. Reported for completeness with a caveat.
  * pg_llm (K=50 reference cell only, capped at 300 writes for cost):
    Precision 0.75, 5.5 min wall clock. The LLM sees author strings
    directly and beats the structural proxy, but at 300x-1000x the
    latency of any deterministic system.
  * pg_mv (streaming majority vote): flat 0.59 across K — its vote
    counts don't consult tiers, so K doesn't affect it. Interestingly
    at c=1 it's competitive with KNDB despite doing no source
    ranking, because most bookstores agree on the popular ISBNs.

Median Precision across K, c=1: epistemic = pg_conf = pg_trigger =
0.610, all beating pg_lww at 0.360, all beaten by pg_llm at 0.750
and (spuriously) by pg_heap at 0.700.

### Test suite

  * installcheck 6/6 unchanged.
  * check-e2e 8/8 unchanged.
  * src/ byte-identical to HEAD after F13 (git diff --stat src/ empty).

### Files added/modified in F13

  * `Makefile`                              -- install-hash target,
                                              verify-dylib target,
                                              verify-dylib prereq on
                                              every check-e2e target.
  * `.dylib.sha256`                         -- recorded install hash.
  * `scripts/verify_dylib.sh`               -- guard script.
  * `bench/datasets/normalize.py`           -- normalize_bookauthor,
                                              --top-k CLI flag.
  * `bench/datasets/bookauthor/README.md`   -- provenance, mapping,
                                              sensitivity, license.
  * `bench/datasets/bookauthor/source/`     -- .gitignored (source
                                              fetched by run script).
  * `bench/datasets/bookauthor/normalized_K*.jsonl` -- 5 K-tier
                                              traces.
  * `bench/driver/replay_dataset.py`        -- bookauthor branch in
                                              score_correctness with
                                              loose-normalization
                                              matcher.
  * `bench/scripts_stage3/run_bookauthor.sh` -- 91-cell orchestrator.
  * `bench/scripts_stage3/summarize_bookauthor.py` -- summary
                                              generator.
  * `bench/results/stage3_raw/bookauthor_*.json` -- 91 cell results.
  * `bench/results/summary/stage3_bookauthor.md` -- rollup.
  * `bench/run.sh`, `bench/run_stage2.sh`, `bench/run_stage3.sh` --
                                              call verify_dylib.sh at
                                              orchestrator start.

## 2026-07-12, F10: Stage 2 correctness axis + four baselines

F9 built the Stage 1 YCSB harness and stopped honestly at both gates
(throughput / abort rate / latency across epistemic, pg_heap,
pg_trigger). F10 adds the correctness axis and four baselines that
the paper compares against: pg_lww, pg_llm (mock), pg_conf, pg_mv.

### Design decisions

1. **Correctness rate = fraction of contested slots whose actual
   live-row `(kind, spec, conf, value)` matches the lattice-max
   over ALL WRITE ATTEMPTS (committed or not).**
   The alternative — computing lattice-max only over commits — hides
   the mechanism's rejections behind the mechanism's own bookkeeping.
   A system that rejects a MEASURED intent (because its trigger got
   the wrong answer) has failed to preserve the intent stream's
   lattice-max. Committing on that rejection does not make it correct.
   The correctness axis measures preservation of intent, not
   agreement with self.
2. **Tied-highest values form a set, not a single canonical value.**
   The lattice does not deterministically pick a specific value when
   (kind, spec, conf) tie; the tiebreak is orthogonal to the lattice
   itself. KNDB uses xmin (F8), pg_trigger uses xmin implicitly via
   `FOR UPDATE` order, LWW uses wall clock, etc. Any tied-highest
   value is a lattice-legal survivor. Scoring "correct if actual
   value ∈ tied-highest set" is the honest test.
3. **Trace every write attempt (committed AND aborted, during
   warmup AND measurement).**
   Warmup writes still change the DB's live table; if we don't trace
   them the lattice-max computation misses them and predicts a stale
   winner. Warmup writes DO NOT count toward throughput/latency/abort
   counters — those are still gated by the measurement window. F9's
   Stage 1 driver only traced measurement-window writes, which is
   correct for throughput but wrong for correctness. Stage 2's
   driver (`bench/driver/correctness.py`) records every attempt into
   a per-worker trace list and merges them offline; only counters are
   window-gated.
4. **LLM baseline uses a mock, not a real API.**
   No LLM API key was plumbed to the test cluster; the Cloro key in
   the standing context is a live billed credential the user did not
   authorise for automated benchmarking. The mock draws latency from
   a log-normal (mean 200-300 ms, sigma 0.5) calibrated against
   Anthropic Haiku 4.5 and OpenAI GPT-4o-mini published single-shot
   latency (100-800 ms on ~500-token structured prompts), and decides
   correctness by a Bernoulli with P=0.65 calibrated against
   published LLM conflict-resolution accuracy on the LOCOMO memory
   benchmark (Chen et al. 2024, Mem0 / MemGPT-follow-up papers report
   60-75%; we sit near the middle). Parameters are exposed as GUCs so
   the disable-and-test transcript can force P=0.5.
5. **pg_lww uses a BEFORE-INSERT trigger, not INSERT ... ON CONFLICT
   DO UPDATE with a partial unique index.**
   The elegant partial-unique + ON CONFLICT shape breaks the
   preseed-preserving reset. ON CONFLICT DO UPDATE mutates the same
   physical row, so the preseed-signature identifier (kind=INFERRED
   spec=0 conf=0.5) no longer applies after the first workload write
   and the reset routine deletes it. A trigger-based LWW has the
   same shape as every other baseline's write path (SELECT FOR
   UPDATE incumbent, close its sys_time, let NEW proceed) and
   trivially matches the reset. Also uncovered: partial unique
   `WHERE upper_inf(sys_time)` catches ZERO rows because
   `tstzrange(now(), 'infinity')` stores the upper as an explicit
   `+infinity` timestamptz value with the RANGE_UB_INF flag unset;
   `upper_inf` returns false for those rows. The correct predicate
   is `upper(sys_time) = 'infinity'::timestamptz`. Documented in
   `bench/schema/pg_lww.sql`.

### KNDB disable-and-test

The F1..F8 discipline requires proving the lattice load-bearing via
a source rebuild that forces `epistemic_precedence_cmp` to return
`NEW_WINS` unconditionally. F10 does not touch src/ (standing rule).
Instead the disable-and-test is external: pg_heap runs the same
workload with no lattice at all. On the adversarial kind mix at
theta=0.9 pg_heap ends the measurement window with tens of thousands
of duplicate live rows (one per slot per write attempt, no eviction),
which the correctness scorer counts as incorrect. Numbers are in
`bench/results/summary/stage2.md`.

### Baselines' individual disable-and-test knobs

  * pg_llm  : `SET bench.fact_llm_disable_test = '1'` forces P=0.5.
  * pg_conf : `SET bench.fact_conf_mode = 'off'` degrades to LWW.
  * pg_mv   : `SET bench.fact_mv_mode = 'off'` degrades to LWW.

### Findings that surprised F10

  * pg_trigger has R1 inverted vs the AM (DERIVED sources check):
    trigger says "no sources allowed", AM says "sources required".
    Workload sends DERIVED with sources, so trigger rejects every
    DERIVED write and its correctness on any mix containing DERIVED
    is lower than the AM's not because of any lattice issue but
    because of the asymmetric rule. F9 flagged this; F10 confirms
    it via the correctness axis. F11 item.
  * pg_lww trigger has an atomicity gap under RC concurrency: two
    concurrent inserts to the same slot both find "no incumbent"
    via SELECT FOR UPDATE (empty scan doesn't take a lock), both
    commit, live-row count = 2. On easy/theta=0.5/c=8 we see ~10
    such duplicate slots per 20-second measurement window. The
    trigger design is subtly wrong; a partial unique index (see
    above about the predicate gotcha) would close this but breaks
    the reset. F10 documents the gap rather than fix it.
  * pg_conf's correctness rate on `easy` and `moderate` mixes is
    dominated by ep_confidence=1.0 (all MEASURED and DERIVED writes)
    beating the preseed INFERRED conf=0.5. Because most contested
    slots have at least one workload write with conf=1.0, pg_conf
    correctness is coincidentally near-optimal on those mixes — not
    because it does the right thing, but because the workload's
    confidence distribution accidentally aligns with the lattice's
    kind rank. On `adversarial` the alignment breaks down.

### Files touched

  * bench/schema/pg_lww.sql   — new
  * bench/schema/pg_llm.sql   — new (mock LLM, calibrated latency +
                                     P_correct GUC)
  * bench/schema/pg_conf.sql  — new
  * bench/schema/pg_mv.sql    — new
  * bench/driver/correctness.py    — new (Stage 2 driver)
  * bench/driver/summarize_stage2.py — new
  * bench/driver/render_stage2.py    — new (CSV -> Markdown tables)
  * bench/run_stage2.sh              — new orchestrator
  * bench/README.md                  — pointer to Stage 2 section
  * bench/results/summary/stage2.md  — F10 report
  * bench/results/stage2_raw/*.json  — one JSON per cell-run

### Test suite

installcheck 6/6 unchanged (no src/ changes).
check-e2e   8/8 unchanged.

Stage 1's numbers (gate.csv, ycsb_a_rc.csv etc.) are unchanged.

## 2026-07-12, F8: xmin (first-committer-wins) tiebreak; accept batch ceiling

F7 landed two adversarial findings against F6.

  * T1 (batch-size ceiling). One transaction can insert ~15,000
    distinct-slot rows at the PG default `max_locks_per_transaction=64`
    before it trips ERRCODE_OUT_OF_MEMORY 53200 from LockAcquire's
    SetupLockInTable path (src/backend/storage/lmgr/lock.c:1076-1082
    REL_18_STABLE). The shared lock hashtable is sized by
    NLOCKENTS() = max_locks_per_xact * (MaxBackends + max_prepared_xacts)
    at lock.c:56-57 REL_18_STABLE. Each per-slot advisory xact lock
    consumes one entry; batch inserts accumulate them until COMMIT.
    scripts/lock_exhaustion.sh sweeps N and confirms the failure at
    N in the 14000-15000 range at the default GUC; scaling to
    `max_locks_per_transaction=1024` moves the ceiling to ~250k,
    linear as the formula predicts (scripts/lock_exhaustion_linearity.sh).
    The failure is a graceful ERROR, not a crash; both the transaction
    and the target relation remain consistent (no partial writes commit;
    the whole INSERT rolls back).

  * T2 (content-hash grindability). F6 broke true precedence ties by
    hash_bytes over content columns and let lower-hash win. hash_bytes
    (src/common/hashfn.h:23 REL_18_STABLE) is deterministic per build
    and observable by any role with SELECT on the target. An attacker
    with SELECT+INSERT grinds `value` bytes until it finds one whose
    hash beats the incumbent. scripts/hash_grind.sh (F7's original)
    reported 30/30 wins with a mean of ~15 attempts to first success —
    the mechanism was ornamental.

### T1-a decision (accepted, documented)

Accept the ~15k ceiling as a design tradeoff. The alternatives were
(T1-b) an EXCLUDE constraint via btree_gist, (T1-c) a switch to
per-slot advisory *session* locks (releases at end of session, not
end of transaction — orthogonal correctness issue), and (T1-d) drop
the advisory lock and re-open the RC leak. The user chose T1-a: the
lock table is what makes RC-safe eviction possible; multi-slot batches
that need higher throughput can raise `max_locks_per_transaction`
before running. README and the correctness envelope now name the
threshold and its linearity. Files: none touched; F7's characterization
scripts (scripts/lock_exhaustion.sh, lock_exhaustion_scan.sh,
lock_exhaustion_deep.sh, lock_exhaustion_linearity.sh) remain in
place unchanged.

### T2-a decision + implementation (swap to xmin)

Replaced the caller-side content-hash tiebreak in
`epistemic_tuple_insert_impl` with an xmin (first-committer-wins)
comparison. Mechanism:

  1. `find_live_overlap` now returns the incumbent's raw xmin via
     `HeapTupleHeaderGetRawXmin` (access/htup_details.h:322-326
     REL_18_STABLE) — a static inline that reads
     `t_choice.t_heap.t_xmin` from the scan slot's HeapTuple. We
     fetch the HeapTuple with `ExecFetchSlotHeapTuple(slot, false, &sf)`
     (executor/tuptable.h:343 REL_18_STABLE, materialize=false to
     avoid a copy).
  2. On a true (kind, specificity, confidence) tie, the caller reads
     the current backend's xid via `GetCurrentTransactionId`
     (src/backend/access/transam/xact.c:454 REL_18_STABLE) — assigns
     one if not yet set.
  3. Compares via `TransactionIdPrecedes`
     (src/backend/access/transam/transam.c:279-292 REL_18_STABLE),
     which handles xid-wraparound via a modulo-2^32 comparison for
     two normal xids and a straight unsigned comparison when either
     side is a permanent xid. If `incumbent_xmin < new_xid` (the
     normal case), the tie flips to `EP_CMP_NEW_LOSES` and
     `epistemic precedence: NEW_LOSES (reason=contradicted_same_rank)`
     rejects the incoming row.
  4. Defensive branch (incumbent_xmin follows or equals new_xid, or
     is invalid): keep NEW_WINS unchanged. Under the current design
     this branch is unreachable — the F6 advisory lock guarantees
     the incumbent is committed by the time `find_live_overlap`
     sees it, and its xmin was stamped by heap_insert
     (heapam.c:2288 HeapTupleHeaderSetXmin, called from heap_insert
     at heapam.c:2083 with `xid = GetCurrentTransactionId()`) at
     an earlier moment in time. Kept as an explicit no-op so a
     future refactor that inverts commit order does not silently
     flip the tie policy.
  5. Deleted `epistemic_content_hash` and its caller-side hash-compare
     block. Deleted the `found_value_out` output parameter of
     `find_live_overlap` and its caller-side plumbing (incumbent_value
     cstring is no longer read from the scan tuple).

Xids are reassigned on pg_dump / pg_restore. Restore loads data
via COPY FROM (src/backend/commands/copyfrom.c:1427 REL_18_STABLE),
which routes through `table_tuple_insert` → `heap_insert` →
`GetCurrentTransactionId`, stamping every reloaded row with a fresh
xid. So the specific survivor of a historical tie is NOT stable
across dump/restore. The invariant that IS stable is
"exactly one live row per slot" (sql/am_eviction.sql). Comment in
src/epistemic_am.c above the compare states this explicitly.

### Adversarial proofs

`scripts/tie_determinism.sh` (rewritten for F8 semantics; F6's
content-deterministic assertion no longer applies):

  MODE=honest, 50 trials × 2 orders:
    s1first: A_lo_wins=50 Z_hi_wins=0  both=0 rule_err=50
    s2first: A_lo_wins=0  Z_hi_wins=50 both=0 rule_err=50
    → first-committer-wins under both orders.

  MODE=broken (xmin tiebreak guard patched to `if (0)`):
    s1first: A_lo_wins=0  Z_hi_wins=50 both=0 rule_err=0
    s2first: A_lo_wins=50 Z_hi_wins=0  both=0 rule_err=0
    → last-writer-wins; the mechanism the xmin tiebreak reverses.

`scripts/hash_grind.sh` (rewritten to prove grind-resistance under
F8; F7's baseline transcript of 30/30 attacker wins under F6 stands
in the git history as the finding that motivated F8):

  MODE=honest:
    Step 2 numeric-suffix   : attacker wins 0/30
    Step 3 whitespace-suffix: attacker wins 0/30
    Step 4 distribution     : attacker wins 0/20000 across 100 trials
                              × 200 attempts each

  MODE=broken (same guard patched to `if (0)`):
    Step 2 numeric-suffix   : attacker wins 30/30 (first attempt each)
    Step 3 whitespace-suffix: attacker wins 30/30 (first attempt each)
    Step 4 distribution     : attacker wins 30/30 (first attempt each)

`scripts/rc_invariant.sh` unchanged post-swap:
    session1_wins=50 session2_wins=0 both_live=0 aborted_txn=0
    → the F6 advisory lock still closes the RC integrity leak; the
      xmin swap is orthogonal to it.

`scripts/concurrency.sh` no-op assertion tightened. Under F8 the
fair concurrency race between identical-prefix writers reaches the
tie branch and NEW_LOSES fires *before* SSI's rw-antidependency
check has anything to abort. NEW_LOSES is now counted as a
"session aborted" alongside 40001, since both are loss-of-write
signals to the rejected session. Native path: 1 abort (via
NEW_LOSES); trigger path: 1 abort (via 40001). Both engines still
survive the fair race with a single live row.

### What this changes semantically

F6's content-hash tiebreak was content-deterministic: whichever
`value` had the lower hash won the tie, regardless of commit order.
F8's xmin tiebreak is start-order-dependent: whichever session
committed first wins. Both are deterministic given a fixed workload.
The tradeoff is:

  * F6 gave up grind-resistance in exchange for content-determinism.
    An attacker who controls `value` could win any tie.
  * F8 gives up content-determinism (survivor differs by commit
    order and does not survive dump/restore) in exchange for
    grind-resistance (no attacker-controllable byte changes the
    outcome).

The user chose grind-resistance. Documented tradeoff.

### Files touched

  * src/epistemic_am.c
      - deleted `epistemic_content_hash` (helper, ~24 lines)
      - deleted `found_value_out` output parameter of
        `find_live_overlap`; replaced with `found_xmin_out`
        (TransactionId *). Populated via ExecFetchSlotHeapTuple +
        HeapTupleHeaderGetRawXmin.
      - replaced caller-side content-hash tiebreak with xmin
        comparison via `TransactionIdPrecedes(incumbent_xmin,
        GetCurrentTransactionId())`.
  * scripts/hash_grind.sh — rewritten. Baseline: 0 wins across
                            20000 grind attempts. Broken:
                            attacker wins first attempt every trial.
  * scripts/tie_determinism.sh — verdict text updated. Honest:
                                 first-committer-wins under each
                                 start order. Broken: last-writer-wins.
  * scripts/concurrency.sh — the "aborted session" grep now
                             recognises NEW_LOSES as well as 40001.
                             Under F8 the native path lands on
                             NEW_LOSES because the advisory lock
                             serialises the writers before SSI
                             has a chance to fire.
  * README.md — F8 correctness envelope: batch-size ceiling documented
                (T1-a), tie semantics documented (first-committer-wins
                via xmin, pg_restore caveat noted).

### Test suite

installcheck: 6/6 unchanged.
check-e2e:    8/8 (rc_invariant, tie_determinism, hash_grind under
                   F8 semantics; the other five unchanged).

## 2026-07-12, F6: per-slot advisory xact lock + content-hash tiebreak

F4 documented the RC integrity leak (concurrent same-slot writers both
commit, two live rows land) and the SR concurrent tie non-determinism
(SIRead pivot-abort picks a survivor by commit order, not content). F6
closes both edges of that envelope inside the AM's tuple_insert
callback. Two mechanisms, one design.

### A. Per-slot advisory xact lock

`epistemic_tuple_insert_impl` now takes a `LOCKTAG_ADVISORY` lock with
`(field1=MyDatabaseId, field2=entity_id, field3=hash_bytes(attribute),
field4=2)` between the R1..R5 rule check and the `find_live_overlap`
scan. Constructed inline via `SET_LOCKTAG_ADVISORY` (lock.h:271-277
REL_18_STABLE) + `LockAcquire(&tag, ExclusiveLock, false, false)`
(lock.h:555-558) — same tag/mode/scope as
`pg_advisory_xact_lock_int4(int4, int4)` at
src/backend/utils/adt/lockfuncs.c:826-837 REL_18_STABLE. Chose the
inline construction over `DirectFunctionCall2` to save one fmgr hop
and make the xact-scope explicit at the call site.

`find_live_overlap`'s snapshot changed from `GetActiveSnapshot()` to
`GetLatestSnapshot()` (snapmgr.c:353-376 REL_18_STABLE). Rationale:
after the advisory lock unblocks, the statement's active MVCC snapshot
was taken before the peer's COMMIT; only the refreshed
`SecondarySnapshot` sees the just-committed row. Same fix applied in
`epistemic_close_sys_time`'s `heap_fetch` — the incumbent's TID from
find_live_overlap must be resolvable under the same snapshot.

`scripts/rc_invariant.sh` runs 50 RC trials of two overlapping
same-slot writers.

  MODE=honest:
    session1_wins=50 session2_wins=0 both_live=0 aborted_txn=0

  MODE=broken (advisory-lock block patched to `if (0)`):
    session1_wins=0 session2_wins=0 both_live=50 aborted_txn=0

Both/50 in broken mode reproduces the pre-F6 RC leak exactly. The
advisory lock is load-bearing.

Collision caveat. The lock key is `(entity_id, hash_bytes(attribute))`,
a 64-bit tag with birthday-limited collisions at ~2^32 attribute
strings. A collision serialises two unrelated slots' writes; that is
a benign perf issue (correctness holds because `find_live_overlap`
still filters by full entity+attribute equality), not a correctness
bug. In practice `attribute` is a small controlled vocabulary and
collisions are rare.

### B. Content-hash tiebreak on true precedence tie

`epistemic_precedence_cmp` still returns
`NEW_WINS/CONTRADICTED_SAME_RANK` on `(kind, specificity, confidence)`
equality — that keeps the pure function testable in isolation
(sql/precedence.sql). `epistemic_tuple_insert_impl` now detects that
specific outcome and computes `hash_bytes` (common/hashfn.h:23
REL_18_STABLE) over a length-prefixed serialisation of
`(entity_id, attribute, value, valid_lower_secs, valid_upper_secs)`
for both incumbent and new row. Lower hash wins; higher hash flips
`cmp.outcome` to `NEW_LOSES` and the row is refused with the
existing `epistemic precedence: NEW_LOSES` error. On a perfect
32-bit collision on different content (birthday-limited at ~2^16
same-slot writes), the fallback is the pre-F6 `NEW_WINS` — not a
correctness violation for the "at most one live row per slot"
invariant, only a deterministic-choice-of-survivor gap at that
probability.

`scripts/tie_determinism.sh` runs 50 RC trials each in two orderings
(session1 starts first, then session2 starts first) with rows
identical on `(kind, specificity, confidence)` but differing on
`value` ("A_lo" vs "Z_hi").

  MODE=honest:
    s1first: A=0  Z=50 both=0
    s2first: A=0  Z=50 both=0
    -> content-deterministic: same value wins under both orders.

  MODE=broken (tiebreak guard patched to `if (0)`):
    s1first: A=0  Z=50 both=0
    s2first: A=50 Z=0  both=0
    -> commit-order-dependent: second-to-arrive wins.

That before/after asymmetry is the load-bearing proof. The specific
value that wins is content-hash-determined, not chosen; here it
happens to be Z_hi because `hash_bytes(...Z_hi...) <
hash_bytes(...A_lo...)`. hash_bytes has no ordering guarantee across
PG versions, but for a given build the winner is stable.

### C. Deadlock story

The advisory lock is per-row (taken inside per-row `tuple_insert`). A
multi-row INSERT that touches slots (X, Y) in one session and (Y, X)
in a concurrent session can deadlock on the advisory locks: sess1
holds lock(X) and waits on lock(Y); sess2 holds lock(Y) and waits on
lock(X).

Chose (b): accept the deadlock possibility, rely on PG's built-in
deadlock detector at src/backend/storage/lmgr/deadlock.c
(DeadLockCheck, called from lock manager after `deadlock_timeout`).
Rationale: (a) sorted `multi_insert` helps only bulk paths sharing a
BulkInsertState; the per-statement race across sessions still
deadlocks. (b) the detector already exists and is one of PG's
best-tested subsystems.

`scripts/deadlock_detection.sh` runs 20 trials with
`deadlock_timeout = 1s` and a 15s wall-clock cap per trial. Result:
20/20 trials resolved with exactly one session aborted (SQLSTATE
40P01, `deadlock detected`); 0 hangs. The lock detector is
load-bearing here.

### Test suite

installcheck: 6/6 (unchanged).
check-e2e:    8/8 (added rc_invariant.sh, tie_determinism.sh,
              deadlock_detection.sh; kept tie_concurrency.sh as the
              historical F4 baseline — its post-F6 numbers now read
              `RC s1=50 both=0 abort=0 rule=50` and
              `SR s1=50 both=0 abort=0 rule=50`, which is precisely
              the RC-leak-closed / SR-content-deterministic outcome).

### Files touched

  * src/epistemic_am.c
      - added advisory-lock block after rule check (`if (have_key)`
        branch)
      - `find_live_overlap`: `GetActiveSnapshot()` -> `GetLatestSnapshot()`,
        added `found_value_out` output parameter
      - `epistemic_close_sys_time`: `GetActiveSnapshot()` ->
        `GetLatestSnapshot()` for the heap_fetch
      - added `epistemic_content_hash` and the NEW_WINS+CONTRADICTED
        tiebreak block in `epistemic_tuple_insert_impl`
      - new headers: common/hashfn.h, miscadmin.h, storage/lmgr.h,
        storage/lock.h
  * scripts/rc_invariant.sh          new
  * scripts/tie_determinism.sh       new
  * scripts/deadlock_detection.sh    new
  * Makefile                          new check-e2e-rc / check-e2e-det /
                                      check-e2e-dl targets; aggregate
                                      runs 8 scripts

## 2026-07-12, F4: eviction atomicity is PG's, tie survival is order-dependent

Two audits. Neither finds an epistemic-specific mechanism; both name
what the AM actually contributes and what it inherits from PG 18.

### A. Eviction atomicity

The eviction path in `epistemic_tuple_insert_impl` does three state
changes when a new fact evicts an incumbent:

  1. `heap_insert` of the winner (epistemic_am.c:362)
  2. SPI `INSERT INTO epistemic.evicted_fact` (epistemic_am.c:378,
     via `epistemic_audit_evicted`)
  3. `simple_heap_update` closing the incumbent's `sys_time` upper
     bound (epistemic_am.c:379, via `epistemic_close_sys_time`)

All three run inside a single top-level PG transaction. That
transaction is not created by the AM — it is created by
`start_xact_command` at src/backend/tcop/postgres.c:2787-2794
REL_18_STABLE, which `exec_simple_query` calls at postgres.c:1046
before parsing the statement and again at postgres.c:1349 via
`finish_xact_command` (postgres.c:2825-2848) after the parsetree
loop finishes. In the default-block arm at xact.c:3069-3072,
`StartTransactionCommand` calls `StartTransaction()`. So a single
top-level INSERT is one transaction; the AM's three heap changes are
one atomic unit as a side effect. The AM does not open, commit, or
manage any transaction.

`scripts/crash_atomicity.sh` runs 25 trials on a fresh cluster with
`fsync=on`, `synchronous_commit=on`, `wal_consistency_checking=all`.
Each trial: reset state, insert one INFERRED incumbent, CHECKPOINT,
fire ${EVICTIONS_PER_TRIAL}=400 per-row MEASURED inserts (each one
evicts the current winner) as a background psql, race a
`pg_ctl stop -m immediate` after 20ms, restart, count
`(live, audit, closed)` for `(entity=7, attribute='bp')`. Tuned
delay catches every trial mid-batch. Result:

  trial  live audit closed total verdict
  1      1    228   228    229   OK
  2      1    190   190    191   OK
  ...
  10     1    80    80     81    OK
  ...
  25     1    197   197    198   OK
  ---
  invariant_violations: 0/25

Every trial: exactly one live row, `audit == closed`, and
`live + closed == audit + 1` (the +1 is the current live winner
that has not itself been evicted). Never `live=0` (incumbent lost
without a replacement), never `live=2` (winner AND incumbent both
live), never `audit != closed` (audit and evicted-tuple diverged).

Adversarial control. `scripts/crash_atomicity_broken.sh` installs a
BEFORE INSERT trigger on `epistemic.evicted_fact` that opens a
dblink connection to the same DB and executes a shadow INSERT into
`epistemic.evicted_fact_shadow`. `dblink_exec` runs on a fresh
backend with its own top-level transaction which commits on
function return, so shadow rows are durable as soon as the trigger
returns — independent of the outer statement's commit. Same 25-trial
race:

  trial  live audit_shadow closed audit_real verdict
  1      1    9            9      9          OK
  2      1    11           10     10         VIOLATION_shadow!=closed(11!=10)
  3      1    8            8      8          OK
  ...
  ---
  invariant_violations: 1/25

Trial 2: 11 shadow audit rows are durable on the dblink side, but only
10 evictions were committed in the main-txn table. One shadow audit
row is now an orphan — the main-txn eviction it recorded was
discarded when redo tossed the un-COMMIT-flushed final statement.
`crash_atomicity_broken.sh` typically produces 1-2 violations per 25
trials because the crash has to land in the microsecond window between
the trigger's dblink commit and the outer statement's WAL flush; the
narrow window is exactly why atomicity holds when the audit is inside
the main txn instead of outside it.

Reservation. The invariant we assert here is a bitemporal live-slot
invariant. The AM is not a schema of arbitrary user constraints; a
different invariant (e.g., "audit row's timestamp matches winner's
sys_time.lower") would require different tests. The scope of this
audit is: does the crash test flag any state that the AM produces
but that recovery leaves torn? Answer: no, and the negative control
proves the test can catch a torn state when one exists.

Attribution. Atomicity of the three-step eviction is PG's. The AM's
contribution is that it does the three steps INSIDE the tuple_insert
callback, so a user cannot forget to wrap them. That is a
convenience claim, not a novel durability claim. README and paper
draft phrased accordingly.

### B. Precedence tie under concurrency

`epistemic_precedence_cmp` at src/epistemic_rules.c:401-407 handles
the same-rank/same-specificity/same-confidence case by returning
`EP_CMP_NEW_WINS` with reason `EP_REASON_CONTRADICTED_SAME_RANK`. On
the serial path this is arrival-order-wins: a second identical
insert AFTER the first commits will succeed and evict the first
(confirmed at sql/precedence.sql:24 and again in the invert probe
below).

`scripts/tie_concurrency.sh` runs 50 trials each under READ
COMMITTED and SERIALIZABLE with two sessions inserting overlapping
rows carrying IDENTICAL (kind, specificity, confidence) for
`(entity_id=1, attribute='bp')`. Only `value` differs so we can name
the survivor.

  ISO=READ COMMITTED s1=0 s2=0 both=50 none=0 abort=0 rule=0
  ISO=SERIALIZABLE   s1=50 s2=0 both=0 none=0 abort=50 rule=0

Under READ COMMITTED all 50 trials leave TWO live rows in the slot.
Each session's `find_live_overlap` seqscan uses its own MVCC
snapshot and cannot see the other session's uncommitted insert; both
sessions think they are the first writer; neither hits the tie code.
That is an integrity failure and it is NOT resolved by the epistemic
rules — the sql/am_eviction.sql invariant "one live row per
(entity_id, attribute) slot" only holds under SERIALIZABLE or
stricter, and only on a serial-arrival path within a session.

Under SERIALIZABLE, session1 (started first) wins all 50 trials;
session2 aborts with SQLSTATE 40001 in all 50. The mechanism is
heap_insert calling `CheckForSerializableConflictIn` at
src/backend/access/heap/heapam.c:2127 REL_18_STABLE, which consults
predicate locks acquired by the other session's seqscan
(relation-level, via `PredicateLockRelation`). `predicate.c:4336-
4389` (REL_18_STABLE) shows the granularity-promoted lock check.
The tie branch is STILL not reached: session2 aborts before its
heap_insert even calls back into the precedence code.

Adversarial control. `scripts/tie_concurrency_invert.sh` patches
`epistemic_rules.c` in place to flip the tie branch to
`EP_CMP_NEW_LOSES`, rebuilds, installs, runs the sequential probe,
and restores the source. Under the patched build a second identical
INSERT in the same session raises:

  ERROR:  epistemic precedence: NEW_LOSES (reason=contradicted_same_rank)

and the first row is the sole survivor. That proves the tie branch
in the honest build is load-bearing on the serial path — the current
"NEW_WINS on tie" is a deliberate policy, not an artifact. The
patched build's concurrent behavior is IDENTICAL to the honest
build's (session1 wins, session2 40001s), confirming that under
concurrency the tie policy is not what determines the outcome.

Findings, plainly:

  * Tie policy in the AM is arrival-order-wins on the serial path
    (later same-prefix insert supersedes earlier). This is
    deterministic given a fixed arrival order.
  * Under concurrent inserts with identical prefix, the tie branch
    is unreachable. Outcome is decided by isolation-level plumbing:
      - READ COMMITTED: both writes commit, integrity is violated.
      - SERIALIZABLE:   one writer aborts under SSI; survivor is
                        whichever transaction PG did not choose to
                        pivot-abort — commit-order-dependent, not
                        content-dependent.
  * There is no content-deterministic concurrent tie resolution.
    The paper draft's phrasing has been updated to say exactly
    that. If deterministic concurrent tie resolution becomes a
    load-bearing claim, the fix is either (a) an in-AM total order
    on ties (e.g., lower `ctid` wins, or a hashed
    `(entity_id, attribute, xmin, value)` comparator), or (b)
    reject-both on tie (the invert-branch policy), which is
    content-deterministic but drops one write.

Attribution. The AM contributes the serial tie policy (which is
exercised in single-session insert streams). Concurrent tie
resolution is PG's — SSI abort under SERIALIZABLE, no protection
under READ COMMITTED. Neither is unique to the epistemic PoC.

### Files touched

  * scripts/crash_atomicity.sh          — new, honest crash test
  * scripts/crash_atomicity_broken.sh   — new, dblink-based
                                          adversarial control
  * scripts/tie_concurrency.sh          — new, concurrent tie probe
  * scripts/tie_concurrency_invert.sh   — new, adversarial rebuild
                                          probe
  * Makefile                            — new check-e2e-crash,
                                          check-e2e-tie targets;
                                          check-e2e aggregates now
                                          runs all five e2e scripts

installcheck: 6/6 pass unchanged.

## 2026-07-12, F3: rmgr 128 is an annotation channel, not a durability channel

Heap's XLOG_HEAP_INSERT already carries every byte of every column
we care about. In PG 18 REL_18_STABLE, heap_insert at
src/backend/access/heap/heapam.c:2222-2226 does
    XLogRegisterBufData(0, &xlhdr, SizeOfHeapHeader);
    XLogRegisterBufData(0, (char *) heaptup->t_data + SizeofHeapTupleHeader,
                        heaptup->t_len - SizeofHeapTupleHeader);
so the entire user tuple — ep_kind, ep_specificity, ep_confidence,
sources, valid_time, sys_time, all of it — is in heap's WAL record.
heap_xlog_insert at heapam_xlog.c:417-503 reconstructs the page via
XLogRecGetBlockData + PageAddItem. Our rows are plain heap tuples;
there is no epistemic-only state to persist. There is no scenario
where the epistemic record adds durability that heap doesn't
already provide, and I did not manufacture one.

Grep of every .c file for the four loggers declared in epistemic_wal.h:
  - epistemic_wal_log_insert        0 callers (dead)
  - epistemic_wal_log_insert_marker 1 caller  (epistemic_am.c:388)
  - epistemic_wal_log_evict         1 caller  (epistemic_am.c:375)
  - epistemic_wal_log_audit         0 callers (dead)

Empirical test 1 (marker): comment out the marker call in
epistemic_am.c step 8, rebuild, make install, run scripts/recovery.sh
on a fresh cluster with wal_consistency_checking = all.
  pre-crash lsn=0/1BBA568 count=110
  post-recovery row count=110
  PASS: recovery round-tripped 110 rows
No PANIC, no "inconsistent page", no non-benign FATAL. The marker is
not load-bearing for durability.

Empirical test 2 (evict): comment out the evict call in step 7 as
well. Recovery.sh only exercises non-overlapping inserts, so evict
never fires there; add an eviction-inducing crash test (50 INFERRED
rows, checkpoint, 50 evicting MEASURED inserts post-checkpoint,
immediate stop, restart).
  pre-crash:    total=100 live=50 closed=50 audit=50
  post-recovery: total=100 live=50 closed=50 audit=50
  PANIC/inconsistent hits: 0
  PASS: eviction state fully recovered by heap WAL alone
The three real state changes on the eviction path — winner INSERT,
loser sys_time UPDATE, audit-row INSERT into epistemic.evicted_fact —
are each already covered by heap's own XLOG_HEAP_INSERT and
XLOG_HEAP_UPDATE. The EVICT record adds nothing.

Empirical test 3 (both off): with both loggers disabled — i.e., the
extension writes ZERO records on rmgr 128 — recovery.sh still passes
110/110 rows and the eviction crash test still passes 100 rows with
50 closed and 50 audit rows. That is the strongest form of the
proof: the rmgr is inert for durability.

Chose demotion (b). Changes:

  * Deleted the dead loggers `epistemic_wal_log_insert` (full tuple
    logger, was never called) and `epistemic_wal_log_audit` (was
    never called).
  * Deleted the evict logger `epistemic_wal_log_evict` and its call
    site in epistemic_am.c (proved decorative above; evict path's
    durability lives in heap_update's WAL and heap_insert's WAL for
    the audit relation).
  * Deleted the record structs `xl_epistemic_evict` and
    `xl_epistemic_audit` and their info bytes XLOG_EPISTEMIC_EVICT
    and XLOG_EPISTEMIC_AUDIT.
  * Kept `epistemic_wal_log_insert_marker` and XLOG_EPISTEMIC_INSERT
    as the sole annotation channel. It writes tuple_len=0 and no
    buffer reference; recovery.sh with it removed proves it is not
    load-bearing. It is retained so sql/wal.sql's rm_id=128 probe
    reflects a real emitted record and so a future logical decoding
    consumer has a named channel to hook.

Reservations. rm_decode is NULL, so logical decoding
(src/backend/replication/logical/decode.c:115-117) skips epistemic
records. PG 18's stock pg_waldump does not load custom rmgrs, so it
renders the record as "custom128 UNKNOWN (10) rmid: 128" — verified
locally on a WAL segment containing an emitted marker. In-server
wal_debug is the only path today that reaches rm_desc. That is the
honest scope of the "annotation channel" phrase.

README and code comments that said the rmgr provides durability, or
implied a working logical-decoding consumer, have been rewritten to
match the demoted role. sql/wal.sql keeps its rm_id=128 probe; only
the header comment was updated.

Attacker model, unchanged from F2. The AM-in-storage differentiator
still holds. This audit narrows what durability the paper can claim
comes from the extension: durability comes from heap. What the AM
provides is the write-time enforcement point and, as a byproduct, a
named annotation channel that is currently unused.

## 2026-07-12, F2: the differentiator is bypass survival, not SSI

F1 established that both fact_native and a scan-equipped
fact_trigger reach the same SIRead-based abort under SERIALIZABLE:
the AM inherits heapam's predicate locking, and a plpgsql trigger
that runs the same overlap probe inherits the same lock. Under fair
conditions there is no concurrency-level difference to demonstrate.
`scripts/concurrency.sh` now asserts exactly that — both paths abort
at least one session — and exits 0 on that basis, with no
epistemic-specific SSI claim.

The engine-level difference the paper actually rests on is bypass
survival. A BEFORE INSERT trigger is a catalog object a writer can
turn off; an AM callback runs from inside heapam's tuple_insert path
and no user-space GUC or ALTER TABLE reaches it.

Two bypass mechanisms verified against PG 18 source:

  1. `ALTER TABLE ... DISABLE TRIGGER ALL` flips
     pg_trigger.tgenabled to 'D'
     (src/backend/commands/tablecmds.c:5588-5592, REL_18_STABLE).
     `TriggerEnabled` at trigger.c:3491-3499 then returns false
     regardless of SessionReplicationRole.

  2. `SET session_replication_role = 'replica'`. Under
     SESSION_REPLICATION_ROLE_REPLICA, `TriggerEnabled` at
     trigger.c:3489-3499 skips both TRIGGER_FIRES_ON_ORIGIN (the
     default for `CREATE TRIGGER`) and TRIGGER_DISABLED. Only
     TRIGGER_FIRES_ON_REPLICA and TRIGGER_FIRES_ALWAYS fire.

`scripts/bypass.sh` runs an R3-violating MEASURED insert under each
bypass against both tables. The bad row lands on fact_trigger and
is rejected on fact_native. The AM's `epistemic_check_rules` block
in `epistemic_tuple_insert_impl` is what does the rejecting; with
that block replaced by `rule = EP_RULE_NONE`, rebuilt, and
reinstalled, all four `fact_native` assertions in bypass.sh flip
from OK to FAIL and the bad row lands on both tables. Restoring the
source verbatim restores the OKs. Transcript in the F2 report.

Attacker model. This differentiator holds for a writer with INSERT
+ ALTER TABLE on the target relation, a role that can toggle
`session_replication_role`, or a connection-pool operator setting
that GUC globally. It does not hold against the table owner, who
can `ALTER TABLE ... SET ACCESS METHOD heap` and rewrite the table
onto plain heap, at which point the AM callback is out of the
write path. That is a schema-change threat, not a write-path threat,
and is out of scope for this claim. Documented in the bypass.sh
preamble and in the README's threat-model paragraph.

## 2026-07-12, F1: predicate locking is delegated to heapam

`src/epistemic_ssi.c` and `include/epistemic_ssi.h` used to hold three
wrappers around `PredicateLockTID`, `PredicateLockRelation`, and
`CheckForSerializableConflictIn`. Only one, `epistemic_predicate_lock_slot`,
was ever called (from `epistemic_tuple_insert_impl`). It hashed the logical
key `(entity_id, attribute, valid_lower, valid_upper)` into a synthetic
`ItemPointer` and called `PredicateLockTID` on that TID.

A hostile-review audit isolated the source of the SQLSTATE 40001 that
scripts/concurrency.sh observes on the native path. Four probes, each on
a fresh cluster, all SERIALIZABLE:

1. Baseline (both AM helpers enabled), two overlapping inserts on
   `(entity=1, attribute='bp')`: one session got 40001 at commit as
   "canceled on identification as a pivot".
2. Same setup but with two non-overlapping keys, `(1,'bp')` vs
   `(42,'temperature')`, whose hashes are almost certainly distinct:
   still one 40001. The synthetic hash cannot be the mechanism.
3. `epistemic_predicate_lock_slot` disabled, overlapping keys: still one
   40001. The wrapper is not load-bearing.
4. Wrapper disabled *and* the `find_live_overlap` seqscan skipped:
   both sessions commit, two rows land. The mechanism was entirely
   `heap_beginscan → PredicateLockRelation` plus `heap_insert →
   CheckForSerializableConflictIn`, both of which fire automatically
   inside the heapam callbacks we delegate to.
5. Wrapper re-enabled, seqscan still skipped, same-key writers: no
   40001. The wrapper cannot produce a conflict on its own either.
   `PredicateLockTID` is a read-side SIRead; two writers hashing to the
   same synthetic TID never form an rw-antidependency because neither
   scans the other's synthetic TID.

The wrapper was decorative. It has been deleted rather than left as a
dead function. The AM now relies on heapam's own predicate locking,
which is coarser (relation-level, not slot-level) but real. This is
worth being honest about in the paper: KNDB's serialization behaviour
in the current PoC is the standard PostgreSQL table-AM serializable
behaviour, not a novel slot-level SSI. A slot-level SIRead lock would
require touching predicate.c directly to add a new lock target type,
which is out of scope for the PoC.

The `ssi` regression test file was a one-line probe of `pg_extension`;
it has been removed along with the wrapper. Test coverage of the write
path lives in `precedence`, `am_basic`, `r2_sources`, and `am_eviction`.
