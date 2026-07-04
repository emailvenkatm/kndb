# STATUS. What's quotable vs. what's still toy

Updated: 2026-07-02. **Read this before quoting any KNDB number in the paper.**

## Quotable now (real, tested, reproducible)

- **Engine implementation.** Six primitives in `engine/*.sql`, roughly 600 LOC of SQL / PL-pgSQL.
- **Test suite.** 26 sub-tests across the primitive files. All PASS live on Postgres 17.10 + ProvSQL 1.10.0 inside the pinned Docker image.
- **Semantic findings.** ProvSQL v1.10.0 API surface (`add_provenance` needs `::regclass`, `sr_viterbi(token, weights_tbl)`, LEFT-JOIN materializes possible-worlds tuples). Documented in `DECISIONS.md` and verified by `smoke_a_viterbi_leftjoin.sql`.
- **Correctness numbers.** Adversarial catch rate (kndb 70/70, pg_naive 0/70, py_guards 30/70, pg_handrolled 70/70) and confidence drift (kndb + steelman 0.000; naive/py 0.21) come from actual runs of the adversarial suite, seed 42.
- **LOC comparison.** 150 (kndb engine) vs 124 (steelman) vs 41 (py_guards, incomplete) vs 0 (naive). Counted programmatically, not eyeballed.

## v2 upgrade (2026-07-02)

- **Precedence lattice.** Kind rank (MEASURED > DERIVED > INFERRED), then specificity, then confidence, then arrival. Four audit reason codes: `kind_outranked`, `specificity`, `confidence`, `contradicted_same_rank`. Documented in DESIGN.md primitive 3 and plan_v2.md section 1.
- **Specificity column.** `kndb.fact.specificity smallint NOT NULL DEFAULT 100` with `CHECK (specificity BETWEEN 0 AND 255)`. Batch loaders write 0, adjudicated corrections write higher.
- **Use-permission views.** `kndb.fact_compliance` (MEASURED + DERIVED), `kndb.fact_analytics` (all kinds), `kndb.fact_training_safe` (MEASURED only).
- **UPPERCASE kind labels.** `MEASURED / INFERRED / DERIVED` throughout the engine and tests.
- **26 sub-tests pass.** Includes T3.4 through T3.9 (lattice tie-breakers and audit reason codes) and T6.1 (use-permission views).
- **9-step smoke gate.** `make smoke` runs an end-to-end proof of every primitive in under two minutes and is wired into CI as the final gate. The former M0 ProvSQL empirical checks moved under `make verify-extensions`.

## Clinical demo on real Synthea (2026-07-01, docker/emulation)

Ran end-to-end on `docker compose exec kndb-postgres`. Reproducible via `bash demo/demo_clinical.sh`.

- **Population loaded:** 11,637 distinct patients, filtered from Synthea 4.0.0 v4.0.0 (SHA256 verified).
- **kndb.fact row counts by kind:**
  - observation: **544,349** (real Synthea labs across 5 LOINC codes: HbA1c, systolic/diastolic BP, fasting glucose, LDL)
  - inference: **4,999** (synthesized `is_diabetic` predictions, seed 42, per-row confidence in [0.5, 0.95], mean 0.7047, min 0.5001)
  - derived: **16,239** (90-day per-patient averages, sources reference obs `fact_id`s)
- **Trial T2DM-06 screening (obs HbA1c ≥ 6.5):** 492 distinct eligible patients; 2,495 candidate join rows against model-inferred `is_diabetic=true`.
- **Top Viterbi joined confidence:** 0.9025 (= 0.95 × 0.95). Engine-computed via `sr_viterbi(provenance(), 'kndb.fact_weights')`.
- **Attack scenario:** picked `entity_id=-2147475695` (patient with no HbA1c observation), attempted to slot a 7.2 model-imputed value as `epistemic_kind='INFERRED'` into the `hba1c` slot registered as MEASURED-required. **KNDB rejected at write time with `R5`, payload NOT stored**. Plain Postgres would have accepted the same write silently (baseline in the old `demo/demo.sh`).
- **Progressive depth on 550k-row DB:** obs 544,349 → +inf 549,348 → +der 565,587 (monotone recall).

## Native benchmark on Synthea-preloaded DB (2026-07-01, ARM64, G2.3)

Adversarial catch rate unchanged from empty-DB (as expected, index lookups):
kndb 70/70, naive 0/70, py_guards 30/70, handrolled 70/70.

Throughput at 565,587 preloaded rows (5000 rows × 10 reps, no truncate):

| System | p50 (μs) | p99 (μs) | rows/sec | vs empty-DB throughput |
|---|---:|---:|---:|---|
| kndb | 70.4 | 155.6 | **5,597** | **58% loss** (from 13,150) |
| pg_handrolled_triggers | 57.1 | 149.5 | **15,559** | unchanged (from 14,912) |

**Finding:** KNDB's write cost scales with `log(|kndb.fact|)` because ProvSQL's `set_prob` traverses a token to probability map that grows with the table. The steelman doesn't implement Viterbi propagation and therefore doesn't call `set_prob`, so its throughput is size-invariant. This is the honest cost of engine-computed confidence propagation vs a bespoke schema that skips it.

## Native benchmark (2026-07-01, ARM64, no emulation)

Ran on Apple Silicon (arm64) natively. Postgres 17.10 (Homebrew) + ProvSQL 1.10.0 built from v1.10.0 source on the same machine. Full manifest at `bench/results/native/manifest.json`.

| System | p50 (μs) | p95 (μs) | p99 (μs) | rows/sec |
|---|---:|---:|---:|---:|
| kndb (native) | **68.3** | 91.1 | 146.6 | **13,150** |
| pg_handrolled_triggers (native) | **59.6** | 80.7 | 157.0 | **14,912** |

- **Native is 14.5× faster than emulated** for kndb (68 μs vs 990 μs p50).
- **KNDB overhead vs steelman: 14.6% on p50, 12% on throughput** (both within noise on p99). This is the paper's honest overhead number.
- **Correctness numbers identical** to emulated (arch-independent): kndb + handrolled 100/100 exact Viterbi; kndb + handrolled catch 70/70 adversarial; naive 0/70; py_guards 30/70.

## Still in progress or known gap
- **Concurrent-write safety.** No test hits the triggers from two sessions at once. Cannot claim race-free behavior for the reject policy or for the precedence lattice under contention.
- **Autonomous-transaction audit.** Rejected writes disappear on rollback per DECISIONS.md 2026-07-01. Documented limitation, not fixed.
- **Specificity is caller-supplied.** The lattice reads `specificity` off the row as written; there is no engine mechanism today that infers specificity from the writer identity, session role, or connection origin. A future step could add a per-role default so a batch loader session cannot accidentally write `specificity = 200`.

## Deliberately out of scope for CIDR 2027

- Malicious DBA with `SUPERUSER` (per `THREAT_MODEL.md`).
- Kernel/hardware compromise.
- Prompt injection at label-synthesis time.
- Formal TLA+ model of the trigger invariants (future work).

## The paper should say, and only say

**Safe to write NOW:**
- "KNDB catches every one of the 70 adversarial writes; naive Postgres catches zero; application-layer guards catch 30."
- "A hand-rolled trigger suite (steelman baseline) matches KNDB's write-time correctness in 124 lines of PL/pgSQL vs 150 in KNDB. The steelman does not implement Viterbi propagation; KNDB does."
- "KNDB and the steelman achieve identical joined confidence on 100 inner-join chains (drift ~ floating-point noise). Naive Postgres and Python guards drift 0.21 on average using the industry-standard `MIN(confidence)` proxy."
- "On native ARM64 (Postgres 17.10 + ProvSQL 1.10.0 built from source, empty `kndb.fact`), KNDB p50 write latency is 68.3 μs and throughput 13,150 rows/sec. The hand-rolled steelman is 14.6% faster at p50 (59.6 μs, 14,912 rps). That is the honest overhead of generic engine-enforced primitives above bespoke triggers."
- "On the same native install with `kndb.fact` pre-loaded with 565,587 real Synthea rows, KNDB throughput drops to 5,597 rps while the steelman stays at 15,559 rps. Adversarial catch remains identical (70/70). The 2.8x write-throughput gap is the honest cost of ProvSQL's `set_prob` map growing with the table, a cost the steelman avoids by not implementing Viterbi propagation at all."
- "Loaded 11,637 Synthea patients producing 544,349 observations, 4,999 inferences, 16,239 derived aggregates. Trial T2DM-06 screening yields 492 obs-based eligible patients and rejects a model-output masquerading as a lab measurement at write time (R5)."
- "CI is green on a hosted GitHub Actions runner in 1m57s (see `.github/workflows/ci.yml`, run 28507827663)."

**Do NOT write, yet:**
- Concurrent-write race behavior (never measured under two-connection load; scoped as future work).

## Update log

- 2026-07-01 04:00. File created; Synthea 10k generation in progress; native install agent in progress.
- 2026-07-01 04:20. Synthea generated 11,637 patients / 8.86M raw obs; 544k kept after LOINC filter.
- 2026-07-01 04:32. Native ProvSQL install SUCCEEDED (port 5434, arm64, native).
- 2026-07-01 04:35. G3 CI verified GREEN on a hosted GitHub runner.
- 2026-07-01 04:50. Docker clinical demo runs end-to-end on real Synthea; 550k fact rows, attack rejected, screening returns 2,495 candidates.
- 2026-07-01 04:55. Native benchmark in progress (background); will land absolute-latency numbers.
- 2026-07-01 05:00. Native benchmark COMPLETE on empty DB. KNDB 68μs p50, 13,150 rps. Steelman 60μs / 14,912 rps.
- 2026-07-01 05:10. G2.3 benchmark on 565k Synthea-preloaded DB COMPLETE. Adversarial catch identical (70/70); KNDB throughput 5,597 rps (58% loss due to ProvSQL set_prob scaling). Steelman unchanged. All three goals closed.
- 2026-07-02. v2 upgrade landed. Precedence lattice, specificity column, three use-permission views, UPPERCASE kind labels, 26 sub-tests, 9-step smoke gate. STATUS refreshed to reflect the closed gap on epistemic-kind semantics and the new open gap on caller-supplied specificity.
