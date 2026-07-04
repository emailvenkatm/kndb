# KNDB. Design

Status: living document. Line numbers in code pointers reference the placeholder
headers in `engine/*.sql` at the time of writing and will move as files fill
out. If a pointer looks stale, check the file header comment rather than the
line number.

## Overview

KNDB is a Postgres + ProvSQL prototype that pushes six "trust" primitives
down into the database engine instead of leaving them to the application. The
narrowed thesis: no relational or graph database engine ships a first-class
epistemic-kind system (`MEASURED | INFERRED | DERIVED`) with confidence
propagation semantics baked into query evaluation. A low-confidence inference
should not be able to silently emerge from a join looking like a ground
measurement, and an app should not be able to write a model guess into a
MEASURED slot by mistake. KNDB makes both of those write-time and
read-time errors, enforced by the storage engine, and measures the honest
overhead of doing so.

## The primitives

**1. Epistemic typing and specificity.** Every fact carries a
`kndb.epistemic_kind` value (`MEASURED`, `INFERRED`, `DERIVED`) and a
`specificity smallint` in `[0, 255]` (default `100`; batch loaders write `0`;
adjudicated corrections write higher). The kind is an ENUM domain and
tables typed `MEASURED` reject rows whose `kind` column is anything else
via a BEFORE-INSERT/UPDATE trigger. Rows typed `DERIVED` must carry a
non-empty `sources uuid[]` and each source UUID must resolve to an existing
fact. A second trigger enforces referential integrity across the array. The
type distinction is engine-visible so downstream primitives can branch on it.
See `engine/01_types.sql`, `engine/02_facts_schema.sql`, and
`engine/03_triggers_epistemic.sql`.

**2. Confidence propagation.** Rows are annotated in ProvSQL's Viterbi
m-semiring. A join between a 0.95-confidence MEASURED and a 0.7-confidence
INFERRED emerges as 0.665, computed by the engine's query evaluator via
provenance multiplication, not by app code walking the result set. The
`kndb.confidence(row)` view exposes the propagated value. The choice of Viterbi
(as opposed to product-t-norm or Lukasiewicz) is a decision, not a fact: it
picks the highest-probability derivation path, which matches the "one canonical
answer" semantics users of a database expect. See `engine/06_provsql_setup.sql`.
Note: ProvSQL's `probability_evaluate` on LEFT JOIN materializes possible-worlds
tuples; KNDB surfaces the per-row `confidence` column for regular queries and
uses `sr_viterbi(provenance(), weights_tbl)` in explicit propagation queries. See
`DECISIONS.md` (2026-07-01 M0 semantics finding).

**3. Write-time precedence lattice.** When a new fact overlaps an existing
live fact on the same `(entity_id, attribute, valid_time)` and the values
differ, the engine picks a survivor by an explicit four-step lattice, stopping
at the first decisive step:

```
kind rank       MEASURED (3) > DERIVED (2) > INFERRED (1)
specificity     higher wins
confidence      higher wins
arrival         NEW wins the true tie
```

Same-value overlap is treated as absorption (extend the survivor's
`valid_time`, skip the insert). If the incoming row is outranked, the write is
refused and the payload is interpolated into the RAISE for the Postgres log. If
the incoming row outranks the existing row, the existing row's `sys_time` upper
closes at `clock_timestamp()`, the new row lands, and the loser is copied into
`kndb_audit.evicted_fact` with a reason code: `kind_outranked`, `specificity`,
`confidence`, or `contradicted_same_rank`. Silent overwrites are not possible
under any policy. The optional per-attribute `kndb.conflict_policy` table is
kept as an advisory override for callers that want a hard `reject` regardless
of the lattice. See `engine/04_triggers_conflict.sql`. Reject-policy audit
persistence needs an autonomous transaction; scoped-out with a documented
limitation.

**4. Bitemporal validity.** Every fact carries `valid_time tstzrange` (when
the world was in that state) and `sys_time tstzrange` (when we recorded it).
A GiST `EXCLUDE` constraint on `(entity_id WITH =, valid_time WITH &&)` blocks
overlapping-time facts at write time. "As of date X" queries are stock SQL.
An empirical smoke test (M0) confirmed ProvSQL's hidden `provsql` column does
not interfere with the GiST index. See `engine/02_facts_schema.sql` (storage)
and `engine/05_bitemporal.sql` (as-of query surface).

**5. Progressive depth.** A stored function `kndb.expand(entity_id, depth)`
returns MEASURED at depth 0, adds INFERRED at depth 1, and adds DERIVED
aggregates at depth 2. Recall is monotonically non-decreasing in depth, and
average confidence is monotonically non-increasing. These are tested
invariants, not aspirations. Callers can trade recall for confidence without
hand-rolling the join. See `engine/07_progressive_depth.sql`.

**6. Use-permission views.** Three engine-provided views over `kndb.fact`
make the query scope the shape of the object you select from, not a WHERE
clause someone can forget:

- `kndb.fact_compliance` filters to `epistemic_kind IN ('MEASURED', 'DERIVED')`
  and live `sys_time`. Compliance and regulator-facing code paths select from
  this view. An adjudicator following an adverse-action letter sees only
  MEASURED and DERIVED evidence.
- `kndb.fact_analytics` filters to live `sys_time` only, all kinds included.
  Analytics and marketing queries that want the enriched picture select from
  this view.
- `kndb.fact_training_safe` filters to `epistemic_kind = 'MEASURED'` and live
  `sys_time`. A model developer building a training set selects from this view
  so the next model does not ingest another model's prior output as ground
  truth, which is the concrete storage-side answer to the model-collapse
  feedback loop.

The difference between the three views is not a convention. It is a schema
object.

## Why enforcement in the engine, not the app

The threat model treats the application as untrusted or unreliable. Concrete
cases: multi-tenant SaaS where tenants share a database and one tenant's
buggy code cannot be allowed to corrupt the shared trust invariants;
LLM-generated SQL that reaches the database directly (via MCP servers,
function-calling agents, or code-interpreter tools) with no human review;
long-lived agents whose memory-write code is itself synthesized. In all three,
the app layer is either absent, adversarial, or unstable across deployments.
Any invariant that lives only in Python is one refactor away from being wrong.
Putting the check in a BEFORE trigger means every write path (psql, ORM,
agent, DBA console) goes through the same enforcement.

## Failure modes

KNDB catches: writing an INFERRED value into a MEASURED slot; writing a
DERIVED row with no sources; silent overwrite of a contradictory claim;
overlapping valid-time on the same entity; a confidence value falling outside
`[0, 1]`; a join that would drop provenance annotation. It does not catch: a
malicious DBA with `SUPERUSER` (they can `ALTER TABLE DISABLE TRIGGER`);
kernel or hardware compromise; a Postgres extension that hooks the executor
below the trigger layer; side-channel timing attacks; adversarial input at
label-synthesis time (if the source labels are poisoned before load, KNDB
faithfully stores the poison). The full list is in `THREAT_MODEL.md`.

## Related work

The comparison table in `docs/related_work_table.md` is the authoritative
source. In short: TypeDB has kinds but no confidence propagation; ProvSQL has
propagation but no epistemic kinds; Zep and Graphiti have bitemporal edges
and provenance but no engine-enforced epistemic type. The two closest recent
papers are MemIR (arXiv:2605.25869) and ATCH (arXiv:2603.13603). MemIR
enforces typed atoms in an agent-memory runtime that sits above the database,
so pull the runtime and the guarantee is gone. ATCH is a theorem and a
prototype PostgreSQL extension; the theorem does not commit to an engine
enforcement mechanism, and the prototype is not benchmarked at scale.
KNDB's contribution is the engine mechanism, the honest overhead numbers, and
the failing-test-first evidence that the mechanism actually catches the bugs
it claims to catch.
