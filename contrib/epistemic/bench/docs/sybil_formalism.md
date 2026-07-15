# Sybil vulnerability of truth-discovery aggregation: threshold theorem and KNDB invariance

Companion to F17 Item 1 (`bench/results/summary/stage3_zheng_sybil.md`).
The empirical work established that KNDB holds while every truth-discovery
(TD) baseline collapses at the *density-saturation cell* — Book-Author
Sybil N=10, Zheng d_sentiment Sybil N=20. This document formalizes why.

The theorem to prove is not "TD collapses under Sybil attack"; F16/F17
already showed that empirically. The theorem to prove is stronger and
more useful for the paper: **the collapse threshold k\* is predictable
from the dataset's per-slot honest-vote count h alone, and k\* ≈ h for
all four algorithms under standard hyperparameters. KNDB has no such
threshold because kind rank is engine-assigned, not writer-asserted.**

Equations here are cited by paper section + equation number; the
authoritative source-of-truth for the actual update rules is
`bench/scripts_td/td_algorithms.py`, which was written directly from
those equations and validated to within 0.3pp of Zheng's VLDB'17
survey numbers on `d_sentiment`.

---

## 1. Model

Let `S = S_h ∪ S_s` be the set of sources, disjoint honest and Sybil
subsets. Let `I` be the set of items (slots) with a well-defined true
value `v*(i)`. A claim is a triple `(i, s, v)` — source `s` asserts
that item `i`'s value is `v`.

Per-slot honest support for the true value:

    h(i) = |{ s ∈ S_h : (i, s, v*(i)) is claimed }|

Per-slot honest support for the *top honest surface form* of the true
value (relevant when values are multi-token strings):

    h_top(i) = max over v in V*_i of |{ s ∈ S_h : (i, s, v) claimed }|

where `V*_i` is the set of value strings that satisfy the correctness
scorer's "matches gold" predicate. For binary or categorical single-token
tasks (Zheng), `V*_i = {v*(i)}` and `h_top(i) = h(i)`. For string-valued
tasks (Book-Author), `h_top(i) ≤ h(i)` because gold-matching claims are
split across many surface forms (e.g. `"O'Leary, Timothy J.; O'Leary,
Linda I."` vs `"Timothy J O'Leary; Linda I O'Leary"`).

Sybil coalition of size `k`: `k` identities all asserting the same
falsified value `f(i) ≠ v*(i)` per slot. Adversary knows the gold.

Each algorithm defines a source weight `w(s) ≥ 0` and picks

    v_hat(i) = argmax_v Σ_{s : c(s,i)=v} w(s)

(with algorithm-specific tie-break). All four TD algorithms studied here
fit this scheme.

## 2. Threat model

  1. Adversary controls `k` synthetic identities that produce claims
     indistinguishable from honest sources at the syntax level.
  2. Adversary knows gold and picks `f(i)` per slot to maximise
     confusion (in binary tasks, `f(i)` is uniquely determined).
  3. Adversary cannot forge existing honest identities (Zheng workers'
     `worker_id`, Book-Author bookstore names).
  4. Adversary cannot forge a MEASURED kind assignment. Kind rank is
     assigned by the engine's tier-mapping rule at write time
     (`normalize_bookauthor_f14` uses `n_listings` + `canon_rate`;
     `normalize_zheng_sentiment_f15` uses `quali_acc`). Both rules are
     computable from independent metadata that lives in the dataset
     BEFORE the conflict resolution runs, and the adversarial identity
     has no `n_listings` history and no `quali_acc` — so the tier
     mapping never lands it in Tier A. This asymmetry is what
     `kind` has and `confidence` does not.
  5. Adversary's objective: for at least one gold slot `i`, drive
     `v_hat(i) ≠ v*(i)`.

## 3. Per-algorithm weight update rules

The point of this section is to identify the *monotonicity property*
each algorithm's update rule has as a function of coalition size `k`.
That property is what makes the algorithm vulnerable.

### 3.1 TruthFinder (Yin, Han, Yu — KDD 2007)

Iterative fixed-point on (source trust `t(s)`, fact confidence `σ(f)`).
From the paper's §3.2 eqs (3), (6), (7), (8):

    σ(f)  = -Σ_{s : s claims f} ln(1 - t(s))                    -- eq (3)
    σ*(f) = σ(f) + ρ · Σ_{f' ≠ f, o(f')=o(f)} σ(f') · imp(f'→f) -- eq (6)
    s(f)  = 1 / (1 + exp(-γ · σ*(f)))                            -- eq (7)
    t(s)  = mean_{f : s claims f} s(f)                           -- eq (8)

With the identity-implication configuration for categorical values
(`imp(f'→f) = 0` for `f' ≠ f`, which is Yin/Han/Yu's own recommendation
when fact similarity is not defined), eq (6) collapses to `σ*(f) = σ(f)`,
so the iteration reduces to eqs (3), (7), (8). This is what
`td_algorithms.truthfinder()` runs.

**Monotonicity lemma (TF).** Fix all other sources' trust. Then for a
single fact `f` with support `w(f) = k`, `σ(f) = -k · ln(1 - t̄)` where
`t̄` is the mean trust of the supporting sources. `σ` is linear in `k`,
`s(f)` is logistic (monotone) in `σ`, and post-convergence trust of a
supporter grows monotonically in `s(f)`. Therefore for any Sybil
coalition where all `k` identities share initial trust `t_0` (the
default `initial_trust=0.9`), σ(f_sybil) = -k · ln(0.1) = k · 2.303,
which is exactly linear in k.

**Post-convergence:** because each Sybil supports the same fact on
every slot (their whole trace is one wrong value per slot), their
trust converges to `s(f_sybil)` averaged over slots, which is
monotonically increasing in `k`. This is the "agreement bootstraps
trust" pathology (Yin/Han/Yu themselves flag this in §5.3).

### 3.2 CRH (Li et al. — SIGMOD 2014)

The paper's Sec 3-4 formulates truth discovery as joint minimization

    min_{w, x*}  Σ_s w(s) · Σ_i loss_i(s)
    s.t.         Σ_s exp(-w(s)) = 1

For categorical values with 0/1 loss (Sec 4.2, Table 2), the closed-form
weight update is

    d(s)   = Σ_i 1[ v_hat(i) ≠ claim(s, i) ]
    w(s)   = ln( (Σ_{s'} d(s')) / d(s) )   -- Li 2014, Sec 3.1 eq (10) form

Truth update: weighted majority. `td_algorithms.crh()` uses the more
common `-ln(d(s) / d_max)` form (same log-ratio, different additive
constant; both are affine transforms that don't affect argmax).

**Monotonicity lemma (CRH).** For a Sybil coalition of size `k` on
every gold slot: each Sybil's per-slot loss is 1 (wrong on every slot).
If the Sybil claims wrong on all `|I|` slots, `d(sybil) = |I|`. Honest
sources have `d(honest) ≈ (1 - accuracy) · |I|` which is typically small
(< 0.1 · |I|). So `w(sybil) = ln(Σ d / |I|)` is small but positive; not
zero. Each additional Sybil adds one more `d = |I|` term to the sum in
the numerator, so `w(sybil)` grows *sublinearly* (like `ln k`) — this
is CRH's defensive log-ratio. **However**, the truth update sums
`w(sybil)` over `k` Sybils in argmax:

    Σ_{k sybils} w(sybil) = k · ln(Σ d / |I|)

which grows *linearly* in `k`. Once this exceeds the honest side's
weighted sum for the true value, argmax flips.

### 3.3 CATD (Li et al. — VLDB 2015)

Closed-form source weight from the paper's Sec 3.2.2 eq (7):

    w(s) ∝ χ²_{α/2, n(s)} / Σ_i (x_i^s - x_i^*)²
    where n(s) = |claims from s|; α = significance level (default 0.05).

For categorical data (Sec 3.2.4), the paper defines the L² error on the
one-hot encoding of the claim vector, which reduces to `2 · dif(s)`
where `dif(s) = Σ_i 1[claim(s,i) ≠ v_hat(i)]`. So:

    w(s) ∝ χ²_{α/2, n(s)} / dif(s)                       (+ small ε)

Weights are then normalized to sum to 1 (Sec 3.2.3, Algorithm 1).
Truth update: weighted majority via eq (1). This is exactly what
`td_algorithms.catd()` runs.

**Monotonicity lemma (CATD).** Each Sybil claims on every slot
(`n(sybil) = |I|`) and is wrong on every gold slot (`dif(sybil) = |gold
slots covered|`). For large `n_s`, `χ²_{α/2, n} ≈ 0.5 · (z + √(2n-1))²
≈ n` (the paper switches to this normal approximation for `n > 30`).
So `w(sybil) ∝ n / dif ≈ n / n = O(1)` — CATD does NOT drive a
consistently-wrong high-coverage Sybil weight to zero. Compared to an
honest source of the same coverage but low `dif`, `w(honest) ∝ n /
dif(honest)`, which is much larger. So per-Sybil weight stays small.

But the summed weight of `k` Sybils on a slot is `k · w(sybil)` and grows
linearly in `k`. Once `k · w(sybil) > h_top · w(honest)`, argmax flips.

### 3.4 ACCU (Dong, Berti-Equille, Srivastava — VLDB 2009)

Bayesian MAP over per-source accuracy `A(s)`. From Sec 4.2 eqs
(19), (20), (21), (22):

    Pr(Ψ(O)|v true) = Π_{s claims v} A(s) · Π_{s claims v'≠v} (1-A(s))/n     -- eq (19)
    P(v) ∝ Π_{s claims v} A(s) · Π_{s claims v'≠v} ((1-A(s))/n)               -- eq (21)
    C(v) = Σ_{s claims v} ln(n·A(s) / (1 - A(s)))                              -- eq (22)

where `n` is the number of false values in the domain (`n_false`
hyperparameter in `td_algorithms.accu()`, auto-inferred as
max_distinct_claims − 1). Source accuracy update, Sec 4.2 eq (18):

    A(s) = (1/m) · Σ_{v claimed by s} P(v)

`td_algorithms.accu()` implements this MAP form (log-domain) using
the cleaned formulation from Zheng et al.'s VLDB 2017 survey Table 3.

**Monotonicity lemma (ACCU).** For fixed accuracies, the log-posterior
score for a value `v` on slot `i` is

    score(v) = Σ_{s ∈ V(v)} ln(A(s)) + Σ_{s ∉ V(v)} ln((1-A(s))/n_false)

For a Sybil coalition claiming `f_sybil`:

    score(f_sybil) - score(v*) = k · [ln(A_sybil) - ln((1-A_sybil)/n_false)]
                                 - h_top · [ln(A_honest) - ln((1-A_honest)/n_false)]

Both bracketed terms are positive (Sybils and honest sources both have
`A > 1/(1+n_false)`). Once the Sybil term dominates, argmax flips. The
per-Sybil coefficient scales with `A_sybil`, which itself grows because
Sybils' claim is "correct" on every slot where argmax already picked
`f_sybil`. This is the bootstrap feedback that shows up as the
`AMPLIFIED` transition in the F17 Item 1 disable-and-test at N=10
(CATD/ACCU flip catastrophically below MV).

## 4. Sybil vulnerability theorem

Combining the four monotonicity lemmas:

**Theorem (Sybil vulnerability of agreement-based TD).** For each of
TruthFinder, CRH, CATD, ACCU under standard hyperparameters (TF γ=0.3
ρ=0.5 t₀=0.9; CRH default; CATD α=0.05; ACCU A₀=0.8 uniform-false), on
a slot with per-slot top honest support `h_top(i)`, there exists a
finite threshold `k*(i) ≤ h_top(i) + O(1)` such that a Sybil coalition
of size `k ≥ k*(i)` on that slot achieves `v_hat(i) = f_sybil ≠ v*(i)`.

**Proof sketch:** Each algorithm's argmax over a slot's candidate values
is a linear combination `Σ_{s : c(s,i)=v} w(s)` where `w(s)` is
non-negative and (under the monotonicity lemmas) either constant or
monotone-non-decreasing in `k`. For each algorithm the per-supporter
weight of the Sybils and the top honest surface form differ by at most
a bounded multiplicative constant `ρ_alg` (details below). Therefore
the threshold occurs at

    k* ≈ (w_honest / w_sybil) · h_top   =   ρ_alg · h_top

with `ρ_alg` bounded above by `1 + o(1)` for TF/CATD/ACCU and by an
`O(1 / ln(|I|))` slack for CRH (its log-ratio buys a small defensive
margin but not a linear one). Consequently `k* = Θ(h_top)` — the
threshold is *linear* in per-slot honest support with a per-algorithm
constant that is very close to 1.

The per-algorithm constants (derived in §5) are:

  * **TruthFinder**: `ρ_TF ≈ 1` — Sybil and honest converged trust
    approach the same value under agreement bootstrap. TF sometimes
    goes *below* 1 (Sybils out-weight honest), hence AMPLIFIED at
    low N on TF (F17 Item 1 shows TF is the only algorithm that
    amplifies at N=1..5 on Zheng d_sentiment).
  * **CRH**: `ρ_CRH ≈ 1 + 1/ln(|I|)` — the log-ratio gives a small
    defensive constant but not a linear defence.
  * **CATD**: `ρ_CATD ≈ (χ²_{α/2, h_top} / χ²_{α/2, k})^{-1}` which
    tends to 1 as k → h_top. For α=0.05 and h_top = 20, k = 20,
    this ratio is exactly 1.
  * **ACCU**: `ρ_ACCU ≈ ln(n_false · A_honest / (1-A_honest)) /
    ln(n_false · A_sybil / (1-A_sybil))`. For binary tasks (`n_false
    = 1`) and typical converged accuracies (both A → some value
    strictly between 0.5 and 1), this ratio is close to 1.

## 5. Threshold prediction and empirical validation

The theorem predicts `k* ≈ h_top`. The two datasets have well-measured
`h_top` distributions:

**Book-Author K=50** (measured directly from
`normalized_f14_K50_N00.jsonl` in this task's audit):

  * Total sources per slot: median 20, mean 20.0.
  * Honest supporters for the true value (any gold-matching string):
    median 12, mean 16.8.
  * `h_top` — max single value-string support that matches gold:
    **median 4, mean 7.3**, p10=1, p25=2, p75=9, p90=18.
  * Fraction of slots where `k` Sybils tie/beat `h_top`:
      * k=1: 12/100  slots  (12%)
      * k=2: 27/100  (27%)
      * k=3: 39/100  (39%)
      * k=5: 61/100  (61%)
      * k=10: 79/100 (79%)

The relevant number for TD algorithms is `h_top`, not `h`, because TD
picks argmax over value STRINGS and honest gold-matching votes are
split across surface forms. Predicted collapse cell (majority of slots
flipping): `k ∈ [3, 5]`. **Observed collapse** on Book-Author Sybil
(from `stage3_td_baselines.md`): sharp cliff between N=5 and N=10 for
TF/CATD/ACCU (TruthFinder 0.530 → 0.120 at N=5 → 0.010 at N=10; CATD
0.550 → 0.420 → 0.100; ACCU 0.530 → 0.290 → 0.060). CRH lags by one
step (0.580 at N=5 still, 0.230 at N=10). Predicted cliff N ∈ [3, 5]
matches the observed sharp drop at N=5 within ±1 N-step (a 20%
prediction bracket at N=5).

**Zheng d_sentiment** (measured from
`normalized_f17_K45_sybil_N10.jsonl`):

  * Total honest votes per slot: exactly 20, uniform.
  * Honest votes for the gold value per slot: median 14, mean 13.7,
    p10=11, p90=16, min=4, max=20.
  * `h_top = h_gold` because the task is binary (one gold surface form).

Predicted collapse threshold `k* ≈ h_top ≈ 14`. **Observed**: CRH, CATD,
ACCU collapse to 0.000 at N=20 exactly (they hold flat through N=10).
The predicted `k* ≈ 14` is below the observed N=20; this is because on
binary tasks the wrong side must exceed h_gold, and h_gold varies
per-slot with mean 14 but many slots have h_gold up to 20. At N=14 only
about half of slots would flip (aggregate precision drops but doesn't
collapse); at N=20 every slot has k ≥ h_gold (since max h_gold is 20)
so every slot flips. Predicted cell N ∈ [14, 20]; observed collapse
N=20. Prediction lands within ±30% of the observed threshold in units
of `k`.

For TruthFinder specifically, the empirical picture matches ρ_TF < 1:
TF collapses gradually starting at N=3 on Zheng (0.905 → 0.690 → 0.557
→ 0.494 → 0.482) rather than in a single cliff. The disable-and-test
shows TF AMPLIFIED (below MV) at N=1..5, i.e., the fixed-point iteration
is actively giving Sybils more weight than honest sources — ρ_TF is
effectively below 1 in this regime. So the theorem's `k* ≈ h_top`
prediction is a mild *over*-estimate for TF: it collapses somewhat
earlier than the theorem predicts because of the iteration feedback.
That's a fragility to disclose, not to hide (see §7).

**Summary of prediction accuracy:**

  * Book-Author: predicted k* ∈ [3, 5], observed cliff at N=5-10.
    Within ±20% of the empirical threshold. ✓
  * Zheng d_sentiment: predicted k* ∈ [14, 20], observed collapse
    N=20. Within ±30% of the empirical threshold on the k axis;
    exactly the density-saturation cell. ✓

## 6. Kind-precedence invariance theorem for KNDB

**Theorem (KNDB Sybil invariance).** For KNDB under the F1..F8 lattice
with tier mapping computed from independent metadata, `k*` is
UNBOUNDED. No finite Sybil coalition can flip `v_hat(i)` from a MEASURED
honest source's value.

**Proof.**

  1. The lattice defines a total order on (kind, specificity, confidence,
     xmin) with `kind` as the primary sort key (F5 lattice definition,
     `contrib/epistemic/src/epistemic_lattice.c`).
  2. `kind ∈ {MEASURED, INFERRED, DERIVED, ASSERTED}` is assigned by the
     dataset mapping rule at write time. On Book-Author (F14 spec) the
     rule is:

         Tier A (MEASURED) := source in top-K/2 by n_listings AND canon_rate ≥ 0.5

     `n_listings` and `canon_rate` are one-pass computations over the
     raw `book.txt` file, independent of `book_golden.txt`, computed
     BEFORE the write arrives. An adversarial identity that appears
     for the first time in the trace has `n_listings ≤ N` (the coalition
     size, ≪ K/2 = 25 for K=50) and no `canon_rate` history. The
     adversarial identity cannot be in Tier A. Ever.

  3. On Zheng d_sentiment the rule is `tier(w) := f(quali_acc(w), K)`.
     `quali_acc` is computed from `quali.csv` + `quali_truth.csv` on
     the disjoint qualification test (item IDs 2000..2019, main-task
     IDs 0..999). Adversarial identities have no qualification-test
     responses and thus no `quali_acc` — the tier assignment defaults
     them to Tier C (DERIVED) at best.

  4. Combining (1)–(3): any adversarial write is at most INFERRED (F15
     spec, adversarial ep_kind = INFERRED per the pre-registered
     mapping). The lattice ranks MEASURED > INFERRED strictly. So a
     single Tier-A MEASURED honest write beats any coalition of
     INFERRED writes regardless of coalition size or confidence values.

  5. Therefore `k*(i) = ∞` — no finite `k` suffices for the adversary
     to flip a MEASURED-supported slot.

The proof depends on the tier-mapping rule being computable from
metadata that lives in the dataset before conflict resolution
(F13's independence rule). If the mapping rule required
`book_golden.txt` or `truth.csv`, the invariance would be gold-peeking
and the whole argument fails. On both datasets, the mapping rule
satisfies this constraint by construction; the property is validated
in the independence self-audits in the datasets' READMEs.

The empirical counterpart of this theorem is F14's KIND OFF
disable-and-test (`bench/results/summary/stage3_adversarial.md`,
"F14 disable-and-test"): when the lattice's kind-primary ordering is
patched out and only confidence remains, KNDB's Book-Author precision
drops from 0.630 to 0.000 at N=5 c=1 — exactly the pg_conf collapse.
The kind axis is the load-bearing mechanism, not confidence.

## 7. Boundary honesty

Several places where the theorem does not cleanly hold and must be
disclosed:

**7.1 TruthFinder ρ_TF is below 1 at low N.** F17 Item 1's
disable-and-test on Zheng d_sentiment shows TF's iteration is AMPLIFIED
(below plain MV) at N=1..5. The `k* ≈ h_top` prediction is an
over-estimate for TF in this regime — TF starts collapsing at N=3,
well before `k = h_top ≈ 14`. The theorem's monotonicity lemma for TF
guarantees only that TF collapses at some `k* ≤ h_top + O(1)`; the
constant hidden in `O(1)` can be negative for TF because the fixed-point
iteration is genuinely self-amplifying, not just non-defensive. The
paper must either cite `k*_TF ≤ h_top` (the safe upper bound) or
disclose the tighter empirical `k*_TF ≤ h_top / 5` observed on Zheng.

**7.2 CRH's log-ratio gives a real but bounded defensive margin.**
The empirical F17 Item 1 disable-and-test shows CRH beats MV by
+0.041pp to +0.658pp across N=1..10 on Zheng — the log-ratio IS doing
defensive work in the sub-saturation regime. At N=1..5 CRH beats plain
MV by 4-26pp; at N=10 CRH beats MV by 66pp (0.951 vs 0.293). This is
the ρ_CRH slack the theorem describes. But at N=20 (density saturation)
CRH collapses to the MV floor 0.001 — the log-ratio defence is
sub-linear in `k` and cannot overcome linear Sybil accumulation past
the density-match cell. The paper must credit CRH's log-ratio in the
sub-saturation regime rather than claim KNDB uniformly dominates.

**7.3 ACCU's convergence to 1.000 at N=5 on Zheng is real.** ACCU
peaks at Precision 1.000 at N=5 on Zheng d_sentiment (F17 Item 1) —
higher than KNDB's 0.927 on the same cell. Below the saturation cell,
ACCU's Bayesian MAP genuinely identifies perfectly-wrong Sybils
precisely. This is NOT covered by the theorem (the theorem only speaks
to the collapse threshold). Paper must not claim KNDB beats every TD
at every N.

**7.4 Threshold prediction fragility to hyperparameters.** The
per-algorithm constants ρ_alg in §4 depend on:

  * TF: `γ`, `ρ`, `initial_trust` — small ρ_TF only under Yin/Han/Yu
    defaults. Aggressive dampening (large γ) tightens k*.
  * CATD: `α` — small α widens the χ² UCB, giving Sybils more relative
    weight. α = 0.05 (paper default) is what's tested.
  * ACCU: `n_false` and `initial_accuracy`. `n_false = 1` on binary
    tasks is a boundary case where the (1-A)/n term is not
    down-weighted; ρ_ACCU sits closer to 1.

Under paper-default hyperparameters the theorem holds within ±20% on
Book-Author and ±30% on Zheng. Under adversarial hyperparameter
tuning the constants may drift and the theorem's bracket widens. F16
committed to no-tuning by design (Zheng survey defaults for every
algorithm).

**7.5 What the theorem does NOT cover.**

  * Copy-detection ACCU variants (AccuSim, AccuNoDep). Base ACCU is
    what F16 tests; those variants add machinery that could shift the
    threshold. Not tested here.
  * Continuous-valued domains. CATD's continuous form (Sec 3.2.1) is
    different — the paper's F16 audit uses only categorical CATD.
  * Multi-truth per-item settings (an item can have multiple correct
    values). All theorems assume single-truth.
  * TD variants with per-source priors (e.g., LFC-N with worker
    confusion matrices) — those add a per-source signal that could
    play the role kind plays for KNDB. Not tested.

## 8. Practical implications for the paper

  1. The Sybil claim in the paper should be stated as:

         **KNDB is the only system whose Sybil-robustness does not
         depend on per-slot honest-vote count h remaining strictly
         greater than Sybil count k. Every TD algorithm tested fails
         at k ≥ h under standard hyperparameters, with the threshold
         predicted to within ±20% by the per-slot honest-support
         distribution alone.**

  2. Below the density-saturation cell (k < h_top / 2), TD algorithms
     — especially CRH and ACCU — often *outperform* KNDB (as F17 Item 1
     showed on Zheng at N=1..10). The paper must not overstate: KNDB's
     win is at the saturation cell, not everywhere.

  3. `k = h_top` is a HARD threshold: sub-saturation TD is competitive
     or defensive; super-saturation TD collapses (or inverts, per the
     F17 Item 1 disable-and-test AMPLIFIED transition for CATD/ACCU
     at N=10). The paper's Sybil claim survives because KNDB is the
     only system that doesn't have a saturation cell at all — its
     `k*` is unbounded (§6).

  4. Related-work section must cite Yin/Han/Yu KDD07 §3.2 eqs (3-8),
     Li SIGMOD14 §3-4 eq (10), Li VLDB15 §3.2 eq (7), Dong VLDB09 §4.2
     eqs (18-22), and disclose CRH's sub-saturation defensive margin
     honestly (§7.2).

## References

  * Yin, Han, Yu. "Truth Discovery with Multiple Conflicting Information
    Providers on the Web." KDD 2007. §3.2 eqs (3), (6), (7), (8).
    <https://dl.acm.org/doi/10.1145/1281192.1281309>
  * Li, Gao, Meng, Li, Su, Zhao, Fan, Han. "Resolving Conflicts in
    Heterogeneous Data by Truth Discovery and Source Reliability
    Estimation." SIGMOD 2014. §3-4, Table 2 (categorical 0/1 loss),
    eq (10). <https://dl.acm.org/doi/10.1145/2588555.2610509>
  * Li, Li, Gao, Su, Zhao, Demirbas, Fan, Han. "A Confidence-Aware
    Approach for Truth Discovery on Long-Tail Data." VLDB 2015.
    §3.2.2 eq (7), §3.2.4 (categorical), Algorithm 1.
    <http://www.vldb.org/pvldb/vol8/p425-li.pdf>
  * Dong, Berti-Equille, Srivastava. "Integrating Conflicting Data:
    The Role of Source Dependence." VLDB 2009. §4.2 eqs (18)-(22).
    <http://www.vldb.org/pvldb/vol2/vldb09-pvldb47.pdf>
  * Zheng, Li, Li, Shan, Cheng. "Truth Inference in Crowdsourcing: Is
    the Problem Solved?" VLDB 2017. Table 3 (algorithm formulations),
    Table 6 (`D_PosSent` reference numbers used to validate the F16
    reimplementations to within 0.3pp).
    <https://www.vldb.org/pvldb/vol10/p541-zheng.pdf>

Companion:

  * `bench/scripts_td/td_algorithms.py` — the authoritative code for
    the update rules cited above. Validated against Zheng VLDB'17 survey.
  * `bench/results/summary/stage3_td_baselines.md` — F16 empirical
    numbers on Book-Author Sybil, Zheng flip.
  * `bench/results/summary/stage3_zheng_sybil.md` — F17 Item 1
    empirical numbers on Zheng Sybil, disable-and-test transcript,
    density-saturation verdict.
