# KNDB. Knowledge-Native Database

**Status: prototype in active construction (2026-07). CIDR 2027 submission deadline 2026-08-04. Not for production use.**

## Why KNDB exists

AI agents and enrichment pipelines now write model-generated data into operational databases at scale, next to verified facts, with no origin distinction at the storage layer. Four independent evidence lines say this is the shape of the problem.

1. Validity's *State of CRM Data Management in 2025* survey reports that 76% of CRM users say less than half of their organization's CRM data is accurate and complete ([press release, PR Newswire](https://www.prnewswire.com/news-releases/validity-releases-state-of-crm-data-management-in-2025-report-revealing-disconnect-between-data-quality-and-ai-implementation-302499899.html)).
2. Validity's earlier 2022 audit found that more than half of surveyed CRM admins rated their CRM accuracy and completeness below 80% ([Validity, 2022](https://www.validity.com/blog/poor-data-quality-is-sabotaging-businesses-in-2022/)).
3. CFPB Circular 2023-03 requires that lenders using AI or complex algorithms give the specific, accurate reasons behind an adverse credit action, with no exemption for AI ([CFPB, Sep 19 2023](https://www.consumerfinance.gov/about-us/newsroom/cfpb-issues-guidance-on-credit-denials-by-lenders-using-artificial-intelligence/)).
4. Shumailov et al. (*Nature* 631, 2024) show that training generative models on their own recursively generated output leads to irreversible model collapse; keeping model output out of the training corpus is now a real engineering task ([Nature 2024](https://www.nature.com/articles/s41586-024-07566-y)).

KNDB makes origin a first-class, engine-enforced property of every row.

## Thesis (narrow, defensible)

> No relational or graph database engine ships a first-class **epistemic-kind system**, `MEASURED | INFERRED | DERIVED` as a distinguished, engine-checked property of every fact, with **propagation semantics baked into query evaluation** (i.e. a low-confidence inference cannot silently emerge from a join looking like a ground measurement).
>
> KNDB is a minimal prototype that does. Postgres + ProvSQL, enforced by the engine, tested against Synthea-derived data, with honest overhead numbers.

We are careful to differentiate from adjacent recent work:
- **MemIR** (arXiv:2605.25869) enforces typed atoms in an *agent-memory runtime*, not a storage engine.
- **ATCH / Equivalence Theorem** (arXiv:2603.13603) is *theory*; no working DB.
- **Zep / Graphiti** stores provenance and bi-temporal edges but has no epistemic kind.
- **ProvSQL** (VLDB 2018; arXiv:2504.12058) gives us Viterbi confidence propagation but has no epistemic-kind primitive.

## The primitives (see [DESIGN.md](DESIGN.md))

1. **Epistemic typing.** `epistemic_kind` ENUM (`MEASURED`, `INFERRED`, `DERIVED`) plus a `specificity smallint` column, both enforced by triggers. Writing an inference into a MEASURED-typed slot is rejected at write time; `DERIVED` rows must reference at least one source.
2. **Confidence propagation.** ProvSQL Viterbi semiring. `0.95 MEASURED join 0.70 INFERRED = 0.665`, computed by the engine's join, not the app.
3. **Write-time precedence lattice.** When two rows overlap on the same entity, attribute, and valid-time and their values differ, the engine picks a survivor by kind rank (MEASURED > DERIVED > INFERRED), then specificity, then confidence, then arrival. The loser is copied to the audit table with one of four reason codes (`kind_outranked`, `specificity`, `confidence`, `contradicted_same_rank`). Silent overwrite is not possible.
4. **Bitemporal validity.** `valid_time tstzrange` + `sys_time tstzrange`, GiST exclusion for no-overlap. "What did we believe on date X" is a stock query.
5. **Progressive depth.** `kndb.expand(entity, depth)`. Depth 0 returns MEASURED, depth 1 adds INFERRED, depth 2 adds DERIVED.
6. **Use-permission views.** Three engine-provided views on `kndb.fact`: `kndb.fact_compliance` (MEASURED and DERIVED only), `kndb.fact_analytics` (all kinds), `kndb.fact_training_safe` (MEASURED only). The scope of a query is the shape of the object you select from, not a WHERE clause someone can forget.

## Quickstart

```bash
git clone <this repo>
cd kndb
make up           # start isolated Postgres + ProvSQL on port 5433
make engine       # apply engine/*.sql
make test         # run test suite (26 sub-tests)
make smoke        # 9-step end-to-end proof of all primitives
make demo         # 60-second demo
```

Requires: Docker (with amd64 emulation on ARM64 hosts. The ProvSQL image is amd64-only). Postgres 17 + ProvSQL 1.10.0 pinned in `docker-compose.yml`.

## Demo (60 seconds)

`make demo` walks through:
1. A CRM sync attempts to overwrite a postal-verified address with a fresher but unverified value. In plain Postgres the overwrite lands. In KNDB the fresher row is typed INFERRED, the lattice keeps the MEASURED (postal) row alive, and the INFERRED row goes to the audit table with reason `kind_outranked`.
2. A vendor enrichment job writes model-guessed values into `accounts.employees` for unknown companies. The engine accepts them as INFERRED with the vendor's confidence. Verified counts stay MEASURED. Marketing can select from `kndb.fact_analytics` to include both, or from `kndb.fact_compliance` to exclude the model guesses on purpose.
3. A 3-table join across MEASURED + INFERRED + DERIVED shows engine-computed confidence decaying from 0.95 to 0.665 via Viterbi.

## Benchmark

`make bench`, see [bench/README.md](bench/README.md). Baselines include a **hand-rolled trigger suite** (steelman) plus plain-Postgres and Python-app-layer guards. Metrics reported honestly with at least 10 seeds, pinned config, no cherry-picking. If KNDB loses on a workload, we say so.

## Reproducibility

`make reproduce` re-runs every figure and table from a clean state. Image digests, seeds, and CPU-governor state are logged into `bench/results/manifest.json`. See [docs/reproducibility.md](docs/reproducibility.md).

## Related work

See [docs/related_work_table.md](docs/related_work_table.md) for a per-primitive comparison against TypeDB, XTDB, Datomic, Zep, Graphiti, ProvSQL, MemIR, ATCH, and Materialize/RisingWave.

## AI-assistance disclosure

This prototype and paper draft were built with substantial AI-assistance (Claude). See [docs/ai_disclosure.md](docs/ai_disclosure.md) for scope of assistance and human-verified components.

## License

Apache 2.0. See [LICENSE](LICENSE).
