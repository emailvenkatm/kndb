# KNDB — Plan (v0.1, awaiting approval)

Knowledge-Native Database prototype backing a **CIDR 2027** submission.
Deadline: **2026-08-04** (~5 weeks from today, 2026-06-30).
This document is a *plan for your review*. No code has been written; no
containers started. Stop points for your approval are marked **[STOP]**.

---

## 0. Executive summary

**Refined thesis (narrowed after landscape scan):**
> No relational or graph database engine ships a first-class **epistemic-kind
> system** (observation | inference | derived) with **propagation semantics
> baked into query evaluation**. KNDB is a minimal prototype that does — on
> Postgres + ProvSQL, enforced by the engine, tested against a real Synthea
> clinical-trial-eligibility workload, with honest overhead numbers.

**What changed from your original brief:**
| Original | Revised | Why |
|---|---|---|
| Cite TOKI as related work | Drop TOKI | TOKI is a Cosmos IBC bridge (toki.finance), not a DB. Naming collision. |
| "No system enforces trust in the engine" | Narrowed: no engine ships epistemic-kind + propagation | MemIR (arXiv:2605.25869) and ATCH (arXiv:2603.13603) already publish adjacent claims; reviewers will pattern-match. |
| Postgres version unspecified | Pin **PG 17 + ProvSQL 1.10.0** via `inriavalda/provsql:1.10.0` | ProvSQL v1.10.0 released 12 days ago. PG 18 works but ecosystem still catching up. |
| ProvSQL capability assumed | 2 empirical smoke tests **required in week 1** | LEFT-JOIN monus semantics and tstzrange+GiST+ProvSQL interaction are not documented; must verify before milestones 2–4 depend on them. |
| Agent 3 (research pitfalls) reused as-is | Flagged as scaffold-only, must re-run with live WebSearch (M8) | Agent 3 explicitly stated it had no WebSearch and returned only inferred content. |

---

## 1. Environment (verified 2026-06-30)

- **Working dir:** `/Users/venky/Development/papers/kndb` — currently empty, not a git repo.
- **Docker:** OrbStack, Docker 29.4.0, Compose v5.1.2. `voicelane-falkordb` is running on port 6380 — **isolated from KNDB. Not touched.**
- **Host tools:** psql, pg_config (Homebrew), Python 3.14.5. `uv` not installed — we'll install for reproducible Python env, or fall back to pip+venv.
- **Isolation contract:** KNDB uses its own Docker network `kndb-net`, containers prefixed `kndb-*`, Postgres on **port 5433** (not 5432), volumes under project directory only. No `docker system prune`, no touching non-`kndb-*` containers.

---

## 2. The five primitives — implementation strategy

| # | Primitive | Mechanism | Enforcement site | Confidence |
|---|---|---|---|---|
| 1 | Epistemic typing | `epistemic_kind` DOMAIN/ENUM + PL/pgSQL BEFORE-INSERT/UPDATE triggers per typed column; `derived` rows have `sources UUID[] NOT NULL` with FK checks | Engine (triggers + constraints) | High |
| 2 | Confidence propagation | ProvSQL Viterbi m-semiring on annotated tables; query wrapper `SELECT provenance(*)` for join propagation | Engine (ProvSQL) | Medium — pending M0 smoke test |
| 3 | Write-time conflict | BEFORE-INSERT trigger: detect overlapping-valid-time contradiction, insert loser into `kndb_audit`, close valid-time window on loser, allow winner | Engine (triggers + tstzrange) | High |
| 4 | Bitemporal | `valid_time tstzrange` + `sys_time tstzrange` + GiST EXCLUDE on (entity_id WITH =, valid_time WITH &&); alternative: ProvSQL temporal semiring | Engine | Medium — GiST + ProvSQL interaction unverified |
| 5 | Progressive depth | SQL function `kndb.expand(entity, depth)` returning obs-only at depth=0, +inference at depth=1, +derived at depth=2; monotonic recall, monotonic-decreasing avg confidence | Engine (SQL function over Viterbi-annotated join) | Medium |

Primitives **1 and 3 are the strongest story** for the paper — they are what a hostile reviewer will attack least. Primitive 2 is the *novel-mechanism* story. 4 and 5 are supporting.

---

## 3. Milestones (5-week critical path)

Each milestone has: a **failing test** written first, an **acceptance check** run end-to-end, and a **DECISIONS.md entry** logging what worked / didn't. Every primitive's engine-enforcement claim gets a matching test in `tests/engine_enforces_*.sql`.

### M0 — Environment + empirical smoke tests (Week 1, ~3 days) **[STOP for your review after M0 report]**
- `docker-compose.yml` on `kndb-net`, port 5433, `inriavalda/provsql:1.10.0` pinned by SHA.
- `Makefile`: `make up`, `make down`, `make psql`, `make test`, `make demo`, `make bench`, `make reproduce`.
- **Smoke test A:** `LEFT JOIN` with Viterbi active — verify monus semantics on non-matching rows.
- **Smoke test B:** table with `EXCLUDE USING GIST (id WITH =, valid_time WITH &&)`, run `SELECT add_provenance('t')`, insert overlapping rows — confirm exclusion still fires and `provsql` UUID assigned.
- Deliverable: `DECISIONS.md` entry with smoke-test results. If either fails, revised plan before M1.

### M1 — Engine-enforced epistemic typing (Week 1–2)
- Schema: `kndb_fact` (base), `kndb_observation`, `kndb_inference`, `kndb_derived` via table inheritance OR single-table with `epistemic_kind` DOMAIN.
- BEFORE-INSERT trigger rejects: inference into obs-typed column; derived row with empty `sources`; source references that don't resolve.
- Failing tests first (`tests/engine_enforces_epistemic_type.sql`), then triggers.
- Acceptance: `make test` green; parallel plain-Postgres schema in `baselines/pg_naive/` silently accepts the same writes.

### M2 — Viterbi confidence propagation (Week 2)
- Annotate tables with `SELECT add_provenance(...)` in ProvSQL's Viterbi semiring.
- 3-table join demo where a 0.6-confidence inference joined with 0.9 obs emerges as 0.54 (Viterbi = multiply).
- Compare to app-layer confidence-propagation in `baselines/py_confidence/`: silent drift on 2 of 5 join patterns.
- Acceptance: numerical output matches closed-form on 10 hand-verified cases; app baseline provably differs.

### M3 — Write-time conflict + audit (Week 2–3)
- Contradicting claim on same entity + overlapping valid-time → loser goes to `kndb_audit` with reason; winner's valid-time trimmed.
- Policy hook: table-level `conflict_policy` = 'invalidate' | 'reject'.
- Acceptance: 100-row adversarial test (writes designed to violate) — 100% caught.

### M4 — Bitemporal + progressive depth (Week 3)
- `tstzrange` valid + sys time, GiST EXCLUDE, "as of date X" query.
- `kndb.expand(entity, depth)` function returning progressively broader result sets.
- Acceptance: recall(depth=2) ≥ recall(depth=1) ≥ recall(depth=0); avg_conf decreases monotonically.

### M5 — Synthea data + 60-second demo (Week 3–4)
- Generate 10k Synthea patients (CSV via `exporter.csv.export=true`).
- Load via OHDSI ETL-Synthea pattern.
- Designate `obs = raw labs`, `inference = synthesized model predictions of diabetes risk`, `derived = 90-day avg BP`. (Synthea itself outputs everything as FHIR observations; the obs/inference/derived split is ours to synthesize, and that's fine — the paper is about the enforcement mechanism, not about detecting inferences post-hoc.)
- `demo.sh` runs the 60-second story: (a) plain PG accepts model guess written into `labs.hba1c`; (b) KNDB rejects same write with a specific error; (c) join across obs+inference shows confidence decay from 0.95 → 0.57.
- Acceptance: single command, screencast under 90s, both branches (accept + reject) shown.

### M6 — Honest benchmark (Week 4)
- Baselines (steelman — this pre-empts the "just triggers, not novel" attack):
  - **B0:** plain PG, no enforcement.
  - **B1:** plain PG + Python app-layer guards.
  - **B2:** plain PG + hand-rolled trigger suite matching KNDB's guarantees. (This is the steelman.)
  - **KNDB:** our engine.
- Metrics:
  - trust violations caught vs. missed (100 adversarial writes).
  - confidence-propagation correctness vs. closed-form (10 cases).
  - LOC to match guarantee.
  - write overhead p50 / p95 / p99.
  - query overhead by primitive.
- Pinned: seed 42, ≥10 runs per config, kernel/CPU-governor logged. **No fabricated numbers.**

### M7 — Docs (Week 4–5)
- `README.md` — thesis, one-command quickstart, demo GIF, benchmark table, license (Apache 2.0), AI-assistance disclosure.
- `DESIGN.md` — 5-primitives-to-implementation map with file:line references; related-work comparison table (TypeDB / XTDB / Datomic / Zep / Graphiti / ProvSQL / MemIR / ATCH).
- `DECISIONS.md` — running log per milestone.
- `THREAT_MODEL.md` — what KNDB defends against, what it does not (multi-tenant untrusted apps: yes; malicious DBA: no).

### M8 — Re-run pitfalls research with live WebSearch (Week 5, before benchmark freeze)
Agent 3 in the initial scan had no live search. Before M6 numbers are final, verify: SIGMOD ARI checklist, VLDB reproducibility, CIDR 2027 artifact policy, ACM AI-disclosure policy, any 2024–2026 retraction cases in DB/ML systems research.

---

## 4. File / folder structure

```
kndb/
├── README.md
├── DESIGN.md
├── DECISIONS.md
├── THREAT_MODEL.md
├── LICENSE                        # Apache 2.0
├── Makefile                       # up/down/test/demo/bench/reproduce
├── docker-compose.yml             # kndb-net, port 5433, provsql:1.10.0 pinned
├── plan.md                        # this file
├── engine/                        # THE PAPER'S CENTRAL CONTRIBUTION
│   ├── 01_types.sql               # epistemic_kind DOMAIN + tables
│   ├── 02_triggers_epistemic.sql
│   ├── 03_triggers_conflict.sql
│   ├── 04_bitemporal.sql
│   ├── 05_progressive_depth.sql
│   └── 06_provsql_setup.sql
├── tests/
│   ├── engine_enforces_epistemic_type.sql
│   ├── engine_enforces_conflict.sql
│   ├── confidence_propagation.sql
│   ├── bitemporal_asof.sql
│   ├── progressive_depth.sql
│   └── adversarial/               # 100 hostile writes
├── baselines/
│   ├── pg_naive/                  # plain PG, no enforcement
│   ├── py_guards/                 # app-layer Python guards
│   └── pg_handrolled_triggers/    # steelman baseline
├── data/
│   ├── synthea/                   # 10k patients CSV (gitignored, regeneratable)
│   ├── generate.sh                # synthea generation + label synthesis
│   └── load_postgres.sh
├── demo/
│   ├── demo.sh                    # 60s narrative
│   ├── screencast.md              # what viewer sees + timestamps
│   └── expected_output.txt
├── bench/
│   ├── run.py                     # ≥10 seeds, pinned config
│   ├── metrics.py
│   ├── results/                   # CSVs, committed
│   └── plots.py
├── docs/
│   ├── related_work_table.md
│   ├── ai_disclosure.md
│   └── reviewer_faq.md            # pre-empt hostile-reviewer objections
└── ci/
    └── github_actions.yml
```

---

## 5. Sub-agent workstream assignment

| Workstream | Agent type | Owns |
|---|---|---|
| Infra | fastapi-backend-architect or general-purpose | Docker, Postgres, ProvSQL, Makefile, CI. Must respect isolation contract. |
| Schema/engine | fastapi-backend-architect or project-architect | All `engine/*.sql`. **Owns the "enforcement in the engine" invariant** — has final say on any push to move logic into Python. |
| Confidence | general-purpose | `06_provsql_setup.sql`, Viterbi wrappers, correctness tests vs closed-form. Runs M0 smoke test A. |
| Data/demo | general-purpose | Synthea generation, label synthesis, `demo.sh` narrative. |
| Benchmark | general-purpose | `bench/`, baselines, honest measurements. Explicit contract: **no fabricated numbers**. |
| Docs | claude-code-guide (writing-only) or general-purpose | README, DESIGN.md, related-work table, disclosure. |
| Pitfalls survey (M8) | general-purpose with WebSearch confirmed | Re-run of Agent 3 with live search. |

Agents can run in parallel where dependencies allow: infra + docs can start day 1; engine blocks on infra M0 smoke tests; confidence blocks on infra + smoke test A; demo blocks on engine M1-M3; benchmark blocks on demo.

---

## 6. Related work — must-cite list (from landscape scan)

To be defended against explicitly in the related-work section:

1. Liu et al., *Supporting Our AI Overlords: Redesigning Data Systems to be Agent-First*, CIDR 2026 — arXiv:2509.00997
2. Rasmussen et al., *Zep: A Temporal Knowledge Graph Architecture for Agent Memory*, arXiv:2501.13956
3. Senellart et al., *ProvSQL Update Provenance through Temporal Databases*, ProvenanceWeek 2025 — DOI 10.1145/3736229.3736253
4. Original *ProvSQL*, VLDB 2018
5. Hu et al., *Memory in the Age of AI Agents: A Survey*, arXiv:2512.13564
6. Alford, *ATCH / Equivalence Theorem*, arXiv:2603.13603 — **direct theoretical competitor**
7. MemIR / *Provenance-Role Collapse*, arXiv:2605.25869 — **closest published typed-memory system**
8. Zhou et al., *Are We Ready For An Agent-Native Memory System?*, arXiv:2606.24775
9. Shute et al., *Semantic Data Modeling, Graph Query, and SQL, Together at Last?*, CIDR 2026 (Google)

**Do NOT cite:** TOKI (Cosmos bridge, not a database).

---

## 7. Open technical questions & risks

| # | Question | Impact | Mitigation |
|---|---|---|---|
| Q1 | Does ProvSQL Viterbi monus behave correctly on LEFT/OUTER JOIN? | Blocks M2 correctness claim | M0 smoke test A. Fallback: PL/pgSQL Viterbi UDA (~30 lines). |
| Q2 | Does ProvSQL's hidden `provsql` UUID column interfere with GiST EXCLUDE on `tstzrange`? | Blocks M4 bitemporal enforcement | M0 smoke test B. Fallback: two-stage insert with app-side pre-check. |
| Q3 | Is our narrowed novelty defensible vs. MemIR + ATCH? | Blocks acceptance | Read both papers cover-to-cover before writing intro; explicit differentiation paragraph. |
| Q4 | Does the "obs/inf/derived" ternary map cleanly onto real Synthea data? | Blocks demo credibility | Synthea outputs are all FHIR observations; we synthesize labels ourselves. That's honest and disclosable — matches the paper's mechanism claim, not a detection claim. |
| Q5 | Will CIDR 2027 require an artifact evaluation? | Determines reproducibility bar | Check CFP in M0; regardless, ship a Docker/Nix reproducible artifact. |
| Q6 | Are the pitfalls-agent recommendations reliable? | Affects benchmark protocol | M8: re-run with live WebSearch before final numbers. |
| Q7 | Can we afford 10k Synthea patients in CI? | CI runtime budget | Use 100 patients in CI, 10k for demo/bench. |

---

## 8. Anti-pitfall + credibility checklist

Applied to every commit / PR / paper draft. (Scaffold — some items derived from Agent 3's inferred-only content; will re-verify in M8.)

- [ ] **No fabricated numbers.** Every table cell has a source seed, a run count, and a config hash. Missing = "not measured" (say so).
- [ ] **Adversarial test suite** shipped in artifact (100 hostile writes per primitive).
- [ ] **Exact pins**: Postgres version, ProvSQL SHA, image digest, `uv.lock`, seed 42, kernel/CPU-governor logged.
- [ ] **Docker artifact** with `make reproduce` hitting every figure.
- [ ] **Ablation table**: what breaks with each primitive removed.
- [ ] **Threat model**: `THREAT_MODEL.md` lists what we don't defend against (malicious DBA, kernel compromise, prompt injection at label-synthesis time).
- [ ] **Human-written intro + contributions + limitations.** AI-assistance disclosure per ACM policy.
- [ ] **Negative results included** — one workload where KNDB loses (e.g., pure write-throughput on non-conflict data).
- [ ] **Pre-empt hostile reviewer** in `docs/reviewer_faq.md`:
  - "This is just CHECK + trigger + RLS — where's the novelty?" — answer: Viterbi propagation + epistemic-kind system, neither of which composes from CHECK/RLS.
  - "App-layer does the same thing" — answer: threat model where app is untrusted (multi-tenant, LLM-generated SQL).
  - "Strawman baseline" — answer: we ship B2, the hand-rolled trigger suite, explicitly as steelman.
  - "No formal proof" — answer: scope claim to "enforced under snapshot isolation; provable in TLA+ future work."
- [ ] **Pre-registered** benchmark protocol (git tag before final runs).

---

## 9. What I need from you before writing any code

1. **Approve the narrowed thesis** in §0. If you want to keep the broader "no engine enforces trust" claim, I need to know your rebuttal to MemIR/ATCH so I can pre-write it into the intro.
2. **Approve pin: Postgres 17 + ProvSQL 1.10.0.**
3. **Approve isolation contract** in §1 (own network, port 5433, `kndb-*` prefix only).
4. **Approve stop points**: I will stop after M0 (smoke-test report), after M3 (three primitives working end-to-end), and after M6 (before you approve benchmark numbers for the paper).
5. **Confirm: `git init` this directory** on approval? (Currently not a git repo.)
6. **Confirm: create paper draft directory** now (`paper/`) or leave until content stabilizes at M5?

Once you approve, I'll launch infra + docs agents in parallel to start M0. No code before your go-ahead.

---

## 10. Notes on what I did NOT do in this pass

- Did not save the `sk_live_...` key you pasted anywhere. Rotate it.
- Did not `git init` — waiting on your call.
- Did not start Docker containers, pull images, or write to Postgres.
- Did not touch `voicelane-falkordb` (verified: still running on port 6380, untouched).
- Did not lean on Agent 3's pitfalls output as ground truth — flagged as scaffold, M8 will re-verify.
