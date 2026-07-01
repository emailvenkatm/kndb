# DECISIONS log

Running log of concrete decisions made during KNDB construction. Newest at the top.

---

## 2026-07-01 — G3 CI verified green on a real GitHub-hosted runner

- Private repo created: `emailvenkatm/kndb`.
- Workflow moved to `.github/workflows/ci.yml` (canonical location). Kept a
  copy at `ci/github_actions.yml` for reviewability.
- First run **GREEN**, 1m 57s: all 15 sub-tests pass (both smoke tests + the
  five primitive test files). Log link:
  https://github.com/emailvenkatm/kndb/actions/runs/28507827663
- Non-blocking annotation: `actions/checkout@v4` targets Node 20 (deprecated).
  Cosmetic — no functional impact.

## 2026-07-01 — G2 native benchmark COMPLETE (arm64, no emulation)

Absolute latency and throughput on native ARM64 Postgres 17.10 + ProvSQL
1.10.0 (built from source), Darwin 25.4.0, seed 42, 10k rows × 10 reps:

```
kndb                  p50= 68.3us  p95= 91.1us  p99=146.6us  thru=13,150 rps
pg_handrolled_triggers p50= 59.6us  p95= 80.7us  p99=157.0us  thru=14,912 rps
```

Comparison with previous OrbStack amd64-emulation numbers (same hardware,
docker):
```
                        p50     thru     native / emulated
kndb (emulated)          990us    853 rps
kndb (native)             68us  13,150 rps      14.5x faster
handrolled (emulated)    974us    865 rps
handrolled (native)       60us  14,912 rps      16.2x faster
```

Correctness identical to emulated (as expected — arch-independent):
kndb + handrolled both 70/100 caught, 100/100 exact Viterbi.

**Paper narrative on overhead:**
- KNDB is 14.6% slower (p50) than a hand-rolled trigger suite on native
  arm64. Not 40% — that was the low-rep emulated noise.
- KNDB's throughput deficit vs the steelman is 12% (13,150 vs 14,912 rps).
- Both are honest overhead for the primitives KNDB provides above what the
  steelman offers (Viterbi propagation across joins).

Full artifacts: `bench/results/native/{manifest.json,run_out.txt,confidence_out.txt,loc_out.txt}`.

## 2026-07-01 — G2 unblocked: native ProvSQL v1.10.0 on Apple Silicon (port 5434)

- Native ARM64 install SUCCESS via Homebrew Postgres 17 + boost + `make install`
  from ProvSQL v1.10.0 source. No sudo needed (Homebrew prefix is user-owned).
- DSN: `postgresql://kndb_native:kndb_native@localhost:5434/kndb_native`.
- Both smoke tests PASS natively (arm64), matching the emulated docker results.
- Docker container `kndb-postgres` on port 5433 remains untouched — the two
  installs are independent.
- `bench/run_native.sh` staged to re-run the full benchmark against port 5434
  once G1 data load completes.

## 2026-07-01 — M6 final numbers: KNDB and steelman tie on throughput (10-rep)

- Re-ran throughput at the spec's 10k rows × 10 seed reps (previous 500 × 2
  reps was too noisy). New numbers: kndb p50 ~990μs vs pg_handrolled_triggers
  p50 ~974μs — within noise. Earlier "40% slower" claim was a 2-rep artifact.
- **Paper narrative correction:** KNDB does NOT pay a meaningful throughput
  penalty vs a hand-rolled trigger suite that reimplements the same
  primitives. What KNDB gives you at the same cost is: (a) the primitives
  as a coherent, tested package, (b) Viterbi confidence propagation
  primitive 2 which the steelman does NOT implement, (c) the LOC-per-project
  savings.
- Correctness untouched: kndb + steelman both 70/70 caught + 100/100 exact
  Viterbi match on inner-join chains; naive and py_guards 0.21 mean drift.
- Adversarial catch reported honestly. `py_guards` catches 30/70 exactly as
  designed (epistemic-kind + progressive-R3-shaped, misses conflict + bitemporal
  because Python guards can't enforce atomicity).

## 2026-07-01 — M0 smoke tests PASS with API and semantic corrections

- **Smoke A PASS (with finding).** `probability_evaluate()` on a LEFT JOIN
  under ProvSQL v1.10.0 materializes *possible-worlds tuples*: patient 1's row
  becomes `(matched, 0.665)` AND `(unmatched, 0.285 = 0.95 * (1 - 0.7))`. This
  is semantically correct for a probabilistic database but not what a KNDB
  user-facing query wants ("give me the row's confidence, don't split it into
  possible worlds").
- **Decision:** KNDB user-facing queries surface the per-row `confidence`
  column directly. ProvSQL semiring evaluation (`sr_viterbi`, `probability_evaluate`)
  is used only in the explicit *confidence-propagation demo query* in M2 and
  M5, where the possible-worlds output is honestly presented as an option the
  engine offers — not as the default row shape. This matches the paper's
  narrower thesis (engine-level epistemic-kind + engine-computed propagation
  when explicitly asked, not global replacement of relational semantics).
- **Smoke B PASS.** `add_provenance('t'::regclass)` cooperates with
  `EXCLUDE USING gist (int WITH =, tstzrange WITH &&)` both before and after
  activation. `provsql` column is auto-populated on INSERT (no manual gate
  creation). Bitemporal primitive is unblocked.
- **API correction:** the ProvSQL API in v1.10.0 requires `add_provenance`'s
  argument to be `regclass` (either `'schema.tbl'::regclass` or an unquoted
  identifier), and uses `set_prob(uuid, float8)` + `sr_viterbi(token, weights_tbl)`,
  not the earlier `provenance_token`/`set_prob_semiring` names. Engine files
  and tests updated accordingly.

## 2026-07-01 — M5 data prep: pinned Synthea v4.0.0 (SHA256 verified)

- **Pin:** Synthea `v4.0.0`, released 2026-03-05. Asset `synthea-with-dependencies.jar`, SHA256 `ed43c20ad40ba5c3bc724503a5af032715fe3c491620b766148e7c2361e6ecc1`.
- **Deliberately not** tracking the rolling `master-branch-latest` tag (also updated 2026-06-30). Reproducibility over recency: a tagged release is the only build we can rebuild against in 6 months.
- **Licence:** Apache 2.0, matches ours. JAR downloaded at runtime by `data/generate.sh`, not vendored (avoids re-distributing a 197 MB binary).
- **Label synthesis:** Synthea emits everything as FHIR Observations. The `observation | inference | derived` split is synthesized by `data/synthesize_labels.py`, seed 42, deterministic. This is disclosed in `data/README.md` — the paper claim is about engine enforcement of the three-way kind, not about detecting the kind post-hoc from raw EHR data.
- **Staging-only load:** `data/load_postgres.sh` writes to `stage.*`, not `kndb.*`. Kept unconstrained so the M1 engine agent's typed triggers are the ones enforcing invariants, not the staging schema.

## 2026-07-01 — M0 opened, ProvSQL image is amd64-only

- **Finding:** `inriavalda/provsql:1.10.0` on Docker Hub publishes **amd64 only** (verified via Docker Hub tags API). No ARM64 manifest.
- **Decision:** run under Docker Desktop / OrbStack amd64 emulation via `platform: linux/amd64` in `docker-compose.yml`. Acceptable for a research prototype; will document expected 1.5-3x slowdown vs native amd64 in `bench/README.md` so we don't mis-report absolute numbers.
- **Alternative considered:** build ProvSQL from source for ARM64. Rejected for M0 — burns time and gives us a non-standard build reviewers can't reproduce. If overhead becomes intolerable at bench time, revisit.

## 2026-07-01 — pin: Postgres 17 + ProvSQL 1.10.0

- Postgres 17 chosen over 18: PG 18 works per ProvSQL README but ecosystem (pgvector, extensions) is still catching up. 17 minimizes surprise. 16 would also work; 17 is the most-current mainstream.
- ProvSQL 1.10.0 pinned by tag; will pin by SHA in `docker-compose.yml` after M0 smoke tests pass to guarantee reproducibility.

## 2026-07-01 — TOKI dropped from related-work

- Original project brief listed TOKI as a comparison system. Landscape scan confirmed TOKI (toki.finance) is a Cosmos IBC bridge, not a database. Naming collision. Removed from related-work table before we could cite it wrong.

## 2026-07-01 — Narrowed novelty claim

- MemIR (arXiv:2605.25869, May 2026) and ATCH (arXiv:2603.13603, Feb 2026) publish adjacent framings. The defensible KNDB claim is narrower: "no *relational/graph engine* ships an epistemic-kind system with propagation semantics baked into query evaluation." Runtime typed-atoms (MemIR) and theory papers (ATCH) do not close the gap.

## 2026-07-01 — Isolation contract with voicelane

- `voicelane-falkordb` is a running container from a separate project. KNDB uses its own network `kndb-net`, port `5433` (not 5432), and only touches containers named `kndb-*`. No `docker system prune`. No shared volumes.
