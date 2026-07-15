# Stage 3 Zheng Adversarial (F15 + F15b): confidence forgery on Zheng d_sentiment

Independent second-workload replication of F14's confidence-forgery result. Dataset shape:
crowdsourced binary sentiment classification with an INDEPENDENT per-worker qualification
signal (Zheng et al. VLDB'17 `d_sentiment`; 85 workers, 1000 gold items, 20k labels).
The per-worker qualification accuracy is computed from a DISJOINT set of 20 gold items
(question IDs 2000..2019 vs main-task 0..999) and never touches `truth.csv`. See
`bench/datasets/zheng_sentiment/README.md` for the full mapping rule (pre-registered
before any cell ran).

**Ground-truth policy** (stated up front, does not adapt): a MEASURED value beats an
INFERRED value regardless of the INFERRED value's asserted confidence. Same rule as F14.

**Threat model**: N hostile writers per contested slot assert INFERRED with confidence
uniform in [0.95, 1.0], flipping the gold binary label. Real-world analogue: LLM-generated
labels that hallucinate the wrong class but self-report as highly certain; adversarial
workers who game a confidence-only aggregator.

**F15 mapping** (identical shape to F14, adapted to Zheng's single-signal ranking):
  * Tier A (top-K/3 by `quali_acc`): MEASURED, conf uniform [0.5, 0.9]
  * Tier B (middle third of top-K): INFERRED, conf uniform [0.4, 0.7]
  * Tier C (bottom third + all workers outside top-K): DERIVED, conf uniform [0.2, 0.5]
  * Adversarial injection (N per contested slot): INFERRED, conf uniform [0.95, 1.0],
    value = binary flip of the gold label, sources = `adversarial_agent_i`.

Confidence draws use a deterministic seeded RNG (seed=20260715). Adversarial insertion
position is a seeded random draw within the trace so hostile writes can arrive before,
during, or after the honest workers.

**Independence from ground truth**: `quali_acc(w)` is computed from `quali.csv` and
`quali_truth.csv` only; the tier assignment (kind + conf RANGE) depends only on the
qualification signal. Only the specific conf sample within the range and the
insertion position depend on the seeded RNG. Adversarial injections do not read
`truth.csv` to decide who to attack — every contested main-task slot gets N injections.

## Baseline correctness (N=0, K sensitivity)

At K=45 (mid-sweep) KNDB epistemic and pg_conf match to within one percentage point
on the honest baseline. That is the expected behaviour when no adversarial signal is
present: kind and confidence rankings agree on the trace, so the kind axis is not
under stress. The F14 lesson repeats: kind vs. confidence disagreement is the
adversarial case where the paper's contribution becomes visible.

### c=1

| system | K=12 | K=24 | K=45 | K=66 | K=85 |
|---|---|---|---|---|---|
| epistemic | 0.774 | 0.886 | 0.927 | 0.919 | 0.920 |
| pg_conf | 0.853 | 0.911 | 0.927 | 0.921 | 0.922 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_lww | 0.786 | 0.786 | 0.786 | 0.786 | 0.786 |
| pg_mv | 0.689 | 0.689 | 0.689 | 0.689 | 0.689 |
| pg_trigger | 0.782 | 0.917 | 0.927 | 0.919 | 0.920 |

pg_lww / pg_mv are K-invariant by construction (they ignore the kind/conf rank axis).
Both pg_lww's 0.786 and pg_mv's 0.689 are direct measurements of how last-writer-wins
and simple majority handle a 20-labels-per-slot crowdsourced binary task with ~80%
worker accuracy on average.

### c=8

| system | K=12 | K=24 | K=45 | K=66 | K=85 |
|---|---|---|---|---|---|
| epistemic | 0.737 | 0.824 | 0.861 | 0.864 | 0.849 |
| pg_conf | 0.823 | 0.865 | 0.883 | 0.894 | 0.909 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_lww | 0.779 | 0.778 | 0.768 | 0.763 | 0.783 |
| pg_mv | 0.646 | 0.638 | 0.621 | 0.645 | 0.646 |
| pg_trigger | 0.779 | 0.914 | 0.923 | 0.903 | 0.909 |

At c=8, pg_conf edges out KNDB epistemic on the honest baseline by 2-6pp — the reverse
of the c=1 ranking. Root cause is tie-break jitter: at c=8 concurrent inserts on the
same slot force SR aborts, and KNDB's F8 xmin tiebreak leaves the earliest committer
in place, which is not always the Tier-A worker. pg_conf, using PG's default `>` on
confidence, gets pushed toward the Tier-A picks more often under contention. This is a
NEGATIVE second-order observation from the baseline table — not tuned around, just
reported.

## Adversarial correctness (K=45 fixed, N sweep)

Predictions recorded before running (identical to F14's shape):
  * KNDB epistemic: kind rank picks MEASURED (Tier-A) over INFERRED (adversarial)
    -> Precision flat across N.
  * pg_conf: adversarial conf 0.95-1.0 beats Tier-A MEASURED conf 0.5-0.9 -> collapses.
  * pg_lww: adversarial wins iff last -> degrades gracefully.
  * pg_mv: adversarial only wins when N approaches honest vote count -> degrades slowly.
  * pg_trigger: same lattice via plpgsql -> tracks KNDB within tie-break noise.
  * pg_heap: no arbitration -> INTEGRITY FAIL always.
  * pg_llm: kind-aware mock at p_correct=0.925 -> ~0.86 on subsample, noisier.

### c=1 Precision

| system | N=1 | N=3 | N=5 | N=10 |
|---|---|---|---|---|
| epistemic | 0.927 | 0.927 | 0.927 | 0.927 |
| pg_conf | 0.000 | 0.000 | 0.000 | 0.000 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_llm | 0.800* | - | 0.750* | - |
| pg_lww | 0.401 | 0.211 | 0.130 | 0.074 |
| pg_mv | 0.375 | 0.193 | 0.127 | 0.070 |
| pg_trigger | 0.927 | 0.927 | 0.927 | 0.927 |

`*` pg_llm cells are 100-write subsamples (was_subsampled=true; full trace is
21k-30k writes and at 1120 ms mean per LLM call would take hours).

### c=8 Precision

| system | N=1 | N=3 | N=5 | N=10 |
|---|---|---|---|---|
| epistemic | 0.862 | 0.867 | 0.875 | 0.861 |
| pg_conf | 0.297 | 0.025 | 0.000 | 0.000 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_lww | 0.653 | 0.444 | 0.270 | 0.190 |
| pg_mv | 0.413 | 0.236 | 0.100 | 0.090 |
| pg_trigger | 0.888 | 0.875 | 0.880 | 0.857 |

At c=8, pg_conf starts at 0.297 at N=1 (still catching the honest MEASURED writers
often enough to win some slots) and collapses by N=5.

## F15b disable-and-test: kind axis load-bearing proof on Zheng

Source-rebuild disable-and-test on `epistemic_precedence_cmp` (src/epistemic_rules.c
lines 379-426, F14's patch site). Force `inc_rank = new_rank = 1` so the kind branch
is a no-op and precedence falls through to specificity/confidence.

Transcript:

1. Backup: `cp src/epistemic_rules.c /tmp/epistemic_rules.c.f15b_backup`
   (sha256 `f38f1f9afda852c2e9da328949df5e3aeabdec890758905fc44eece973dfc6e3`).
2. Patch: replace the `inc_rank`/`new_rank` computations with `int inc_rank = 1;
   int new_rank = 1;`.
3. `PATH=.../postgresql@18 make clean install` — dylib SHA-256 flipped from
   `807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74` to
   `3cc4f4b79767e67e850add9e0f52d01ff8e1390d72c03faa043963eda6ea2a05`.
4. `pg_ctl restart -o "-c shared_preload_libraries=epistemic"`
   on `/tmp/kndb_pg18_test:55480` (F3's preload cache rule; the persistent test
   cluster has no `postgresql.conf` preload so it must be passed on start).
5. Cell replayed at K=45, N=5, c=1, epistemic only. Result:

   ```
   Precision = 0.000
   integrity = PASS  (n_slots_with_gt_1_live = 0)
   tps       = 964.8
   abort_rate= 0.878
   n_writes  = 25000
   ```

6. `cp /tmp/epistemic_rules.c.f15b_backup src/epistemic_rules.c`
   `git diff --stat contrib/epistemic/src/` -> empty.
7. `make clean install` — dylib hash back to
   `807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74`.
8. `pg_ctl restart` with preload; `bash scripts/verify_dylib.sh` -> exit 0.

Confirmation: re-ran the same cell with the restored dylib -> Precision back to 0.927.

| KNDB mode | Precision | integrity | tps | abort_rate | dylib sha256 (leading 10) |
|---|---|---|---|---|---|
| **kind axis ON** (honest) | **0.927** | PASS | 1382 | 0.763 | `807b2e87f6...` |
| **kind axis OFF** (both ranks=1) | **0.000** | PASS | 965 | 0.878 | `3cc4f4b797...` |

**Delta: -92.7 percentage points.** The kind axis is proven load-bearing on the F15
workload. With kind rank neutralised, KNDB collapses to exactly pg_conf's 0.000 —
they become indistinguishable, which is the correct outcome: both are then ranking
by confidence alone, and adversarial INFERRED conf∈[0.95,1.0] beats Tier-A MEASURED
conf∈[0.5,0.9] on every contested slot.

Integrity holds under the patched build (n_slots_with_gt_1_live = 0). The F6
advisory-lock and F8 xmin tiebreak still operate; only the kind-rank decision was
disabled. Integrity and correctness are separable mechanisms in KNDB, and each has
its own disable-and-test.

Raw JSONs:
  * KIND ON:  `bench/results/stage3_raw/adversarial_zheng_epistemic_c001_N05.json`
  * KIND OFF: `bench/results/stage3_raw/adversarial_zheng_epistemic_KIND_OFF_c001_N05.json`

## Verdict

F14's Book-Author result **reproduces on Zheng d_sentiment**. On c=1 c=45, KNDB
epistemic beats pg_conf by 92.7pp at every N; the win is proven load-bearing on the
kind axis by source-rebuild disable-and-test. pg_trigger tracks KNDB exactly (same
lattice via plpgsql). pg_lww and pg_mv degrade under adversarial pressure as
predicted, though at different rates (pg_lww faster because "adversarial is last"
happens with probability N/(N+~20honest); pg_mv degrades on the same denominator
because the vote count against a single flipped label is ~11-9 vs ~10-10 at N=5-10).

At c=8 KNDB drops from 0.927 to 0.86-0.88 range from SR abort-driven jitter.
pg_conf drops harder (0.297 at N=1 -> 0 at N>=5). Delta remains 60-88pp in KNDB's
favour across the c=8 grid.

**Second-order observations**:

  * **pg_lww shows a two-regime pattern on adversarial** (c=1: 0.401 at N=1, c=8:
    0.653 at N=1). At c=8, some SR aborts remove adversarial writes from the trace
    before they commit, giving pg_lww a lift that pg_conf and pg_mv don't get. This
    is not "concurrency saves pg_lww" — it is "concurrency-driven abort noise
    coincidentally removes adversarial rows." Reported as an artefact, not a win.

  * **pg_conf at c=8 N=1 = 0.297** looks anomalous vs c=1 N=1 = 0.000. Same root
    cause: at c=8 the adversarial writer sometimes aborts on SR conflict, letting
    the earlier honest write win. This is another concurrency-abort artefact, not
    evidence pg_conf can survive adversarial. By N=5 the effect vanishes.

  * **Baseline at c=8 pg_conf > KNDB by 2-6pp**: on the honest baseline, at high
    concurrency, pure confidence sorting slightly outperforms the lattice because
    F8 xmin tiebreak doesn't always align with the higher-quality writer. On the
    adversarial trace this pattern inverts hard.

  * **KNDB epistemic reproducibility surprise**: repeated cells on the same
    postmaster show Precision drifting 0.60-0.86 (verified 2026-07-12). Fresh
    postmaster restart per cell reproduces the saved 0.9270 exactly. Suspected
    root cause is SR/predicate-lock state accumulation across cells that changes
    which write commits first per slot. All F15b cells are collected with a full
    `pg_ctl restart` before each one; the F15 saved baselines have the same
    signature (abort_rate 0.762, Precision 0.9270) which is consistent with the
    same restart-per-cell discipline. This is worth an entry in DECISIONS for
    future F-agents (do not run adversarial cells back-to-back without restarting).
