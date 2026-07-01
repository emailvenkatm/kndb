# STATUS — What's quotable vs. what's still toy

Updated: 2026-07-01. **Read this before quoting any KNDB number in the paper.**

## Quotable now (real, tested, reproducible)

- **Engine implementation** — 5 primitives in `engine/*.sql`, ~600 LOC of SQL/PL-pgSQL.
- **Test suite** — 15 sub-tests across 7 files. All PASS live on Postgres 17.10 + ProvSQL 1.10.0 inside the pinned Docker image.
- **Semantic findings** — ProvSQL v1.10.0 API surface (`add_provenance` needs `::regclass`, `sr_viterbi(token, weights_tbl)`, LEFT-JOIN materializes possible-worlds tuples) — documented in `DECISIONS.md` and verified by `smoke_a_viterbi_leftjoin.sql`.
- **Correctness numbers** — adversarial catch rate (kndb 70/70, pg_naive 0/70, py_guards 30/70, pg_handrolled 70/70) and confidence drift (kndb + steelman 0.000; naive/py 0.21) come from actual runs of the adversarial suite, seed 42.
- **LOC comparison** — 150 (kndb engine) vs 124 (steelman) vs 41 (py_guards, incomplete) vs 0 (naive) — counted programmatically, not eyeballed.

## Not yet quotable (in progress or known gap)

- **Absolute latency numbers** — everything so far ran under **OrbStack amd64 emulation** on Apple Silicon. Native install underway (background agent). Until that lands, only RELATIVE latency comparisons (KNDB vs steelman) should appear in the paper.
- **Synthea demo numbers** — the 10k-patient generation is running now. Until it completes and the clinical scenario runs, the demo shows only the 5 inline toy rows in `demo/demo.sh`.
- ~~CI green on a real runner~~ — **RESOLVED 2026-07-01**. Workflow moved to `.github/workflows/ci.yml`, private repo `emailvenkatm/kndb` created, first run GREEN in 1m57s. All 15 sub-tests pass on a hosted Ubuntu runner. Run: https://github.com/emailvenkatm/kndb/actions/runs/28507827663
- **Concurrent-write safety** — no test hits the triggers from two sessions at once. Cannot claim race-free behavior for the reject policy.
- **Autonomous-transaction audit** — rejected writes disappear on rollback per DECISIONS.md 2026-07-01. Documented limitation, not fixed.

## Deliberately out of scope for CIDR 2027

- Malicious DBA with `SUPERUSER` (per `THREAT_MODEL.md`).
- Kernel/hardware compromise.
- Prompt injection at label-synthesis time.
- Formal TLA+ model of the trigger invariants (future work).

## The paper should say — and only say

**Safe to write:**
- "KNDB catches every one of the 70 adversarial writes; naive Postgres catches zero; application-layer guards catch 30."
- "A hand-rolled trigger suite (steelman baseline) matches KNDB's write-time correctness in 124 lines of PL/pgSQL vs 150 in KNDB. The steelman does not implement Viterbi propagation; KNDB does."
- "KNDB and the steelman achieve identical joined confidence on 100 inner-join chains (drift ~ floating-point noise). Naive Postgres and Python guards drift 0.21 on average using the industry-standard `MIN(confidence)` proxy."
- Once the Synthea run completes: "Loaded N Synthea patients producing M_obs observations, M_inf inferences, M_der derived aggregates. Trial T2DM-06 screening yields K candidates."

**Do NOT write, yet:**
- Absolute latency in μs (emulation caveat until native run).
- "CI is green" without evidence of a real runner pass.
- Any Synthea patient/row count until the running generation completes.

## Update log

- 2026-07-01 — file created; Synthea 10k generation in progress; native install agent in progress.
