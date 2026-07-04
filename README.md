# KNDB — Knowledge-Native Database

**Status: prototype in active construction (2026-07). CIDR 2027 submission deadline 2026-08-04. Not for production use.**

A Postgres + ProvSQL prototype exploring one claim: **trust primitives — epistemic type, confidence propagation, temporal validity, provenance, conflict resolution — belong in the storage engine, not reconstructed in every application layer.**

## Thesis (narrow, defensible)

> No relational or graph database engine ships a first-class **epistemic-kind system** — `MEASURED | INFERRED | DERIVED` as a distinguished, engine-checked property of every fact — with **propagation semantics baked into query evaluation** (i.e. a low-confidence inference cannot silently emerge from a join looking like a ground measurement).
>
> KNDB is a minimal prototype that does — on Postgres + ProvSQL, enforced by the engine, tested against Synthea-derived clinical-trial-eligibility data, with honest overhead numbers.

We are careful to differentiate from adjacent recent work:
- **MemIR** (arXiv:2605.25869) enforces typed atoms in an *agent-memory runtime*, not a storage engine.
- **ATCH / Equivalence Theorem** (arXiv:2603.13603) is *theory*; no working DB.
- **Zep / Graphiti** stores provenance and bi-temporal edges but has no epistemic kind.
- **ProvSQL** (VLDB 2018; arXiv:2504.12058) gives us Viterbi confidence propagation but has no epistemic-kind primitive.

## The five primitives (see [DESIGN.md](DESIGN.md))

1. **Epistemic typing** — `epistemic_kind` DOMAIN + triggers. Writing an inference into an observation-typed column is rejected at write time; `derived` rows must reference ≥1 source.
2. **Confidence propagation** — ProvSQL Viterbi semiring. `0.9 obs ⋈ 0.6 inference = 0.54`, computed by the engine's join, not the app.
3. **Write-time conflict** — contradicting claim closes the loser's valid-time and preserves it in the audit table (never a silent overwrite).
4. **Bitemporal validity** — `valid_time tstzrange` + `sys_time tstzrange`, GiST exclusion for no-overlap. "What did we believe on date X" is a stock query.
5. **Progressive depth** — `kndb.expand(entity, depth)`: shallow returns only high-confidence observations; deeper widens to inferences and derived aggregates.

## Quickstart

```bash
git clone <this repo>
cd kndb
make up           # start isolated Postgres + ProvSQL on port 5433
make smoke        # run M0 empirical smoke tests
make engine       # apply engine/*.sql
make test         # run test suite
make demo         # 60-second demo
```

Requires: Docker (with amd64 emulation on ARM64 hosts — the ProvSQL image is amd64-only). Postgres 17 + ProvSQL 1.10.0 pinned in `docker-compose.yml`.

## Demo (60 seconds)

`make demo` walks through:
1. Plain Postgres schema silently accepts a model's guess written into `labs.hba1c`.
2. KNDB schema rejects the same write at write time with an explicit error naming the epistemic-kind violation.
3. A 3-table join across observation + inference + derived shows engine-computed confidence decaying from 0.95 to 0.57 via Viterbi.

## Benchmark

`make bench` — see [bench/README.md](bench/README.md). Baselines include a **hand-rolled trigger suite** (steelman) plus plain-Postgres and Python-app-layer guards. Metrics reported honestly with ≥10 seeds, pinned config, no cherry-picking. If KNDB loses on a workload, we say so.

## Reproducibility

`make reproduce` re-runs every figure and table from a clean state. Image digests, seeds, and CPU-governor state are logged into `bench/results/manifest.json`. See [docs/reproducibility.md](docs/reproducibility.md).

## Related work

See [docs/related_work_table.md](docs/related_work_table.md) for a per-primitive comparison against TypeDB, XTDB, Datomic, Zep, Graphiti, ProvSQL, MemIR, ATCH, and Materialize/RisingWave.

## AI-assistance disclosure

This prototype and paper draft were built with substantial AI-assistance (Claude). See [docs/ai_disclosure.md](docs/ai_disclosure.md) for scope of assistance and human-verified components.

## License

Apache 2.0 — see [LICENSE](LICENSE).
