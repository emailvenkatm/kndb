# Stage 3 Adversarial (F14): kind-vs-confidence disagreement

**Ground-truth policy** (stated up front, does not adapt): a MEASURED value beats an INFERRED value regardless of the INFERRED value's asserted confidence. Confidence is a self-report; kind reflects the epistemic act. Under this policy the correct survivor on every gold ISBN is a Tier-A MEASURED writer (top-K/2 by n_listings AND canon_rate >= 0.5) if one exists.

**Threat model**: N hostile/miscalibrated writers per gold ISBN assert INFERRED with confidence uniform in [0.95, 1.0] on a scrambled-real-answer (an author string lifted from a DIFFERENT gold ISBN). Real-world analogue: LLM-generated content that hallucinates values but self-reports as certain; malicious agent poisoning a knowledge store.

**F14 mapping** (revised from F13 to make kind vs. confidence genuinely disagree):
  * Tier A (top-K/2 by n_listings AND canon_rate >= 0.5): MEASURED, conf uniform [0.5, 0.9]
  * Tier B (rest of top-K by n_listings): INFERRED, conf uniform [0.4, 0.7]
  * Tier C (else): DERIVED, conf uniform [0.2, 0.5]
  * Adversarial injection: INFERRED, conf uniform [0.95, 1.0]

Confidence draws use a deterministic seeded RNG (seed=20260714) so the workload is bit-for-bit reproducible.

**Independence from ground truth**: the tier assignment (kind + conf RANGE) depends only on (n_listings, canon_rate) — structural properties of `book.txt`. Only the specific conf sample within the range depends on the seeded RNG. Adversarial injections do not read `book_golden.txt` to decide who to attack — every gold ISBN gets N injections.


## N = 1 adversarial writes per gold ISBN

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 2961 | 1620.6 | 0.835 | 0.630 | PASS | 169.0 | 0.30 |
| pg_conf | 1 | 2961 | 1137.2 | 0.897 | 0.000 | PASS | 0.0 | 0.27 |
| pg_heap | 1 | 2961 | 14964.2 | 0.000 | INTEGRITY FAIL | FAIL (max=115, mean=29.6) | 4938.2 | 0.20 |
| pg_lww | 1 | 2961 | 5586.0 | 0.000 | 0.210 | PASS | 1173.1 | 0.53 |
| pg_mv | 1 | 2961 | 1168.6 | 0.870 | 0.460 | PASS | 70.1 | 0.33 |
| pg_trigger | 1 | 2961 | 1226.2 | 0.863 | 0.620 | PASS | 104.2 | 0.33 |
| epistemic | 8 | 2961 | 890.1 | 0.869 | 0.540 | PASS | 63.0 | 0.44 |
| pg_conf | 8 | 2961 | 710.4 | 0.893 | 0.150 | PASS | 11.4 | 0.45 |
| pg_heap | 8 | 2961 | 6924.3 | 0.000 | INTEGRITY FAIL | FAIL (max=115, mean=29.6) | 2008.1 | 0.43 |
| pg_lww | 8 | 2961 | 2000.1 | 0.726 | 0.460 | PASS | 252.3 | 0.41 |
| pg_mv | 8 | 2961 | 734.4 | 0.891 | 0.460 | PASS | 37.0 | 0.44 |
| pg_trigger | 8 | 2961 | 693.9 | 0.890 | 0.580 | PASS | 44.2 | 0.47 |

## N = 3 adversarial writes per gold ISBN

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 3161 | 1841.1 | 0.828 | 0.630 | PASS | 200.0 | 0.30 |
| pg_conf | 1 | 3161 | 968.4 | 0.907 | 0.000 | PASS | 0.0 | 0.30 |
| pg_heap | 1 | 3161 | 14402.2 | 0.000 | INTEGRITY FAIL | FAIL (max=117, mean=31.6) | 2448.4 | 0.22 |
| pg_lww | 1 | 3161 | 5824.0 | 0.000 | 0.130 | PASS | 757.1 | 0.54 |
| pg_mv | 1 | 3161 | 1175.8 | 0.870 | 0.400 | PASS | 61.0 | 0.35 |
| pg_trigger | 1 | 3161 | 1225.4 | 0.857 | 0.620 | PASS | 108.6 | 0.37 |
| epistemic | 8 | 3161 | 1011.3 | 0.862 | 0.610 | PASS | 84.9 | 0.43 |
| pg_conf | 8 | 3161 | 570.9 | 0.915 | 0.000 | PASS | 0.0 | 0.47 |
| pg_heap | 8 | 3161 | 6834.2 | 0.000 | INTEGRITY FAIL | FAIL (max=117, mean=31.6) | 1298.5 | 0.46 |
| pg_lww | 8 | 3161 | 2157.7 | 0.710 | 0.230 | PASS | 144.1 | 0.42 |
| pg_mv | 8 | 3161 | 748.1 | 0.891 | 0.340 | PASS | 27.7 | 0.46 |
| pg_trigger | 8 | 3161 | 827.5 | 0.880 | 0.550 | PASS | 54.6 | 0.46 |

## N = 5 adversarial writes per gold ISBN

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 3361 | 1702.1 | 0.827 | 0.630 | PASS | 186.0 | 0.34 |
| pg_conf | 1 | 3361 | 1047.6 | 0.910 | 0.000 | PASS | 0.0 | 0.29 |
| pg_heap | 1 | 3361 | 14969.1 | 0.000 | INTEGRITY FAIL | FAIL (max=119, mean=33.6) | 1646.6 | 0.23 |
| pg_llm | 1 | 310 | 0.3 | 0.706 | 0.111 | PASS | 0.0 | 329.75 |
| pg_lww | 1 | 3361 | 5648.4 | 0.000 | 0.090 | PASS | 508.4 | 0.59 |
| pg_mv | 1 | 3361 | 1163.5 | 0.876 | 0.320 | PASS | 46.3 | 0.36 |
| pg_trigger | 1 | 3361 | 1242.7 | 0.857 | 0.620 | PASS | 110.0 | 0.39 |
| epistemic | 8 | 3361 | 1001.8 | 0.862 | 0.600 | PASS | 83.0 | 0.46 |
| pg_conf | 8 | 3361 | 590.4 | 0.911 | 0.000 | PASS | 0.0 | 0.51 |
| pg_heap | 8 | 3361 | 6755.5 | 0.000 | INTEGRITY FAIL | FAIL (max=119, mean=33.6) | 878.2 | 0.50 |
| pg_lww | 8 | 3361 | 2275.7 | 0.692 | 0.140 | PASS | 98.0 | 0.45 |
| pg_mv | 8 | 3361 | 748.4 | 0.888 | 0.350 | PASS | 29.3 | 0.50 |
| pg_trigger | 8 | 3361 | 808.9 | 0.881 | 0.580 | PASS | 55.7 | 0.49 |

## N = 10 adversarial writes per gold ISBN

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 3861 | 1470.5 | 0.837 | 0.630 | PASS | 151.4 | 0.43 |
| pg_conf | 1 | 3861 | 931.0 | 0.913 | 0.000 | PASS | 0.0 | 0.36 |
| pg_heap | 1 | 3861 | 12857.9 | 0.000 | INTEGRITY FAIL | FAIL (max=124, mean=38.6) | 771.5 | 0.30 |
| pg_lww | 1 | 3861 | 4621.9 | 0.000 | 0.040 | PASS | 184.9 | 0.83 |
| pg_mv | 1 | 3861 | 971.3 | 0.893 | 0.170 | PASS | 17.7 | 0.42 |
| pg_trigger | 1 | 3861 | 1058.8 | 0.864 | 0.620 | PASS | 89.6 | 0.50 |
| epistemic | 8 | 3861 | 927.3 | 0.866 | 0.640 | PASS | 79.5 | 0.56 |
| pg_conf | 8 | 3861 | 612.0 | 0.909 | 0.000 | PASS | 0.0 | 0.57 |
| pg_heap | 8 | 3861 | 6654.4 | 0.000 | INTEGRITY FAIL | FAIL (max=124, mean=38.6) | 665.4 | 0.58 |
| pg_lww | 8 | 3861 | 2014.6 | 0.724 | 0.190 | PASS | 105.8 | 0.53 |
| pg_mv | 8 | 3861 | 625.6 | 0.905 | 0.180 | PASS | 10.7 | 0.59 |
| pg_trigger | 8 | 3861 | 776.1 | 0.883 | 0.600 | PASS | 54.6 | 0.58 |

## Scaling of adversarial pressure (c=1, Precision)

The core F14 question: does the kind axis remain load-bearing as adversarial pressure grows? If KNDB's Precision stays flat while pg_conf's collapses, the kind axis is doing real work. If they degrade together, the lattice's kind axis was not load-bearing and the paper's contribution reduces to "confidence-sorting with an audit trail."

| system | N=1 | N=3 | N=5 | N=10 |
|---|---|---|---|---|
| epistemic | 0.630 | 0.630 | 0.630 | 0.630 |
| pg_conf | 0.000 | 0.000 | 0.000 | 0.000 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_llm | - | - | 0.111 | - |
| pg_lww | 0.210 | 0.130 | 0.090 | 0.040 |
| pg_mv | 0.460 | 0.400 | 0.320 | 0.170 |
| pg_trigger | 0.620 | 0.620 | 0.620 | 0.620 |

## Scaling of adversarial pressure (c=8, Precision)

| system | N=1 | N=3 | N=5 | N=10 |
|---|---|---|---|---|
| epistemic | 0.540 | 0.610 | 0.600 | 0.640 |
| pg_conf | 0.150 | 0.000 | 0.000 | 0.000 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_llm | - | - | - | - |
| pg_lww | 0.460 | 0.230 | 0.140 | 0.190 |
| pg_mv | 0.460 | 0.340 | 0.350 | 0.180 |
| pg_trigger | 0.580 | 0.550 | 0.580 | 0.600 |

## F14 disable-and-test: kind axis load-bearing proof

Source-rebuild disable-and-test on `epistemic_precedence_cmp`
(src/epistemic_rules.c:379-423). Patched both `inc_rank` and
`new_rank` to the constant `1` so the kind branch is a no-op and the
function falls through to specificity/confidence. `PATH=postgresql@18
make install` regenerated `.dylib.sha256`; PG18 test cluster
restarted; F14 workload re-run at N=5, c=1. After capture, `src/`
restored byte-identical (git diff --stat empty), rebuilt, reinstalled,
`.dylib.sha256` back to `807b2e87f64e9cb257d568313b5bc74d1eb946d96b2abc6de85b65d5f251fd74`,
`scripts/verify_dylib.sh` exit 0.

| KNDB mode | Precision | integrity | tps | abort_rate | notes |
|---|---|---|---|---|---|
| **kind axis ON** (honest) | **0.630** | PASS | 1702 | 0.827 | dylib 807b2e87... |
| **kind axis OFF** (both ranks=1) | **0.000** | PASS | 908 | 0.910 | patched build; every gold ISBN wrong |

**Delta: -63 percentage points.** The kind axis is proven load-bearing
on the F14 workload. With kind rank neutralised, KNDB collapses to
exactly pg_conf's 0.000 behaviour — the two systems become
indistinguishable, which is the correct outcome (both are then ranking
by confidence alone, and adversarial INFERRED conf∈[0.95,1.0] beats
Tier-A MEASURED conf∈[0.5,0.9] on every ISBN).

Integrity holds under the patched build (n_slots_with_gt_1_live=0)
because the F6 advisory-lock + F8 xmin tiebreak still operate; only
the kind-rank decision was disabled. That is the correct decomposition:
integrity and correctness are separable mechanisms in KNDB.

## Verdict

KNDB **beats pg_conf by 63 pp on the F14 workload** (0.630 vs 0.000
at N=1, N=3, N=5, and N=10 for c=1; similar spread at c=8). The
lattice's kind axis is doing real work — it is not "confidence-sorting
with an audit trail." The paper's contribution is intact.

The disagreement between kind rank and confidence rank is what makes
the workload adversarial in the paper's threat model: an INFERRED
writer that self-reports high confidence still loses to a MEASURED
writer that self-reports honest uncertainty. Confidence-only baselines
(pg_conf) get fooled every time; last-writer-wins baselines (pg_lww)
degrade as adversarial pressure grows (0.21 at N=1 -> 0.04 at N=10);
majority-vote (pg_mv) degrades too but more gracefully. Only KNDB
(and pg_trigger, which uses the same lattice via a plpgsql trigger)
holds Precision constant across N.

The win vanishes ONLY when the kind axis itself is neutralised —
proven by the disable-and-test above.
