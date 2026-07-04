# KNDB — Design

Status: living document. Line numbers in code pointers reference the placeholder
headers in `engine/*.sql` at the time of writing and will move as files fill
out. If a pointer looks stale, check the file header comment rather than the
line number.

## Overview

KNDB is a Postgres + ProvSQL prototype that pushes five "trust" primitives
down into the database engine instead of leaving them to the application. The
narrowed thesis: no relational or graph database engine ships a first-class
epistemic-kind system (`MEASURED | INFERRED | DERIVED`) with confidence
propagation semantics baked into query evaluation. A low-confidence inference
should not be able to silently emerge from a join looking like a ground
observation, and an app should not be able to write a model guess into an
observation column by mistake. KNDB makes both of those write-time and
read-time errors, enforced by the storage engine, and measures the honest
overhead of doing so.

## The five primitives

**1. Epistemic typing.** Every fact carries a `kndb.epistemic_kind` value:
`MEASURED`, `INFERRED`, or `DERIVED`. The kind is an ENUM domain and
tables typed `MEASURED` reject rows whose `kind` column is anything else
via a BEFORE-INSERT/UPDATE trigger. Rows typed `DERIVED` must carry a
non-empty `sources uuid[]` and each source UUID must resolve to an existing
fact — a second trigger enforces referential integrity across the array. The
type distinction is engine-visible so downstream primitives (2, 5) can branch
on it. See `engine/01_types.sql`, `engine/02_facts_schema.sql`, and `engine/03_triggers_epistemic.sql`.

**2. Confidence propagation.** Rows are annotated in ProvSQL's Viterbi
m-semiring. A join between a 0.9-confidence observation and a 0.6-confidence
inference emerges as 0.54, computed by the engine's query evaluator via
provenance multiplication, not by app code walking the result set. The
`kndb.confidence(row)` view exposes the propagated value. The choice of Viterbi
(as opposed to product-t-norm or Łukasiewicz) is a decision, not a fact — it
picks the highest-probability derivation path, which matches the "one canonical
answer" semantics users of a database expect. See `engine/06_provsql_setup.sql`. Note: ProvSQL's `probability_evaluate` on LEFT JOIN materializes possible-worlds tuples; KNDB surfaces the per-row `confidence` column for regular queries and uses `sr_viterbi(provenance(), weights_tbl)` in explicit propagation queries. See `DECISIONS.md` (2026-07-01 M0 semantics finding).

**3. Write-time conflict resolution.** When a new fact contradicts an existing
fact on the same entity with overlapping valid-time, a BEFORE-INSERT trigger
either (a) trims the incumbent's `valid_time` and inserts the new row, or
(b) rejects the new row, depending on a per-table `conflict_policy` setting.
The loser is copied into `kndb_audit` with a reason string. Silent
overwrites are not possible under any policy — that is the invariant. See
`engine/04_triggers_conflict.sql`. Reject-policy audit persistence needs an autonomous transaction; scoped-out with a documented limitation.

**4. Bitemporal validity.** Every fact carries `valid_time tstzrange` (when
the world was in that state) and `sys_time tstzrange` (when we recorded it).
A GiST `EXCLUDE` constraint on `(entity_id WITH =, valid_time WITH &&)` blocks
overlapping-time facts at write time. "As of date X" queries are stock SQL.
An empirical smoke test (M0) will confirm ProvSQL's hidden `provsql` column
does not interfere with the GiST index; if it does, the fallback is an app-side
two-stage insert. Smoke test B (2026-07-01) confirmed no interference. See `engine/02_facts_schema.sql` (storage) and `engine/05_bitemporal.sql` (as-of query surface).

**5. Progressive depth.** A stored function `kndb.expand(entity_id, depth)`
returns observations only at depth 0, adds inferences at depth 1, and adds
derived aggregates at depth 2. Recall is monotonically non-decreasing in
depth, and average confidence is monotonically non-increasing — these are
tested invariants, not aspirations. Callers can trade recall for confidence
without hand-rolling the join. See `engine/07_progressive_depth.sql`.

## Why enforcement in the engine, not the app

The threat model treats the application as untrusted or unreliable. Concrete
cases: multi-tenant SaaS where tenants share a database and one tenant's
buggy code cannot be allowed to corrupt the shared trust invariants; LLM-generated
SQL that reaches the database directly (via MCP servers, function-calling agents,
or code-interpreter tools) with no human review; long-lived agents whose
memory-write code is itself synthesized. In all three, the app layer is either
absent, adversarial, or unstable across deployments. Any invariant that lives
only in Python is one refactor away from being wrong. Putting the check in a
BEFORE trigger means every write path — psql, ORM, agent, DBA console — goes
through the same enforcement.

## Failure modes

KNDB catches: writing an inference into an observation column; writing a
derived row with no sources; silent overwrite of a contradictory claim;
overlapping valid-time on the same entity; a confidence value falling outside
[0,1]; a join that would drop provenance annotation. It does not catch: a
malicious DBA with `SUPERUSER` (they can `ALTER TABLE DISABLE TRIGGER`);
kernel or hardware compromise; a Postgres extension that hooks the executor
below the trigger layer; side-channel timing attacks; adversarial input at
label-synthesis time (if the Synthea labels are poisoned before load, KNDB
faithfully stores the poison). The full list is in `THREAT_MODEL.md`.

## Related work

The comparison table in `docs/related_work_table.md` is the authoritative
source. In short: TypeDB has kinds but no confidence propagation; ProvSQL has
propagation but no epistemic kinds; Zep and Graphiti have bitemporal edges
and provenance but no engine-enforced epistemic type. The two closest recent
papers are MemIR (arXiv:2605.25869) and ATCH (arXiv:2603.13603). MemIR
enforces typed atoms in an agent-memory runtime that sits above the database
— pull the runtime and the guarantee is gone. ATCH is a theorem and a
prototype PostgreSQL extension; the theorem does not commit to an engine
enforcement mechanism, and the prototype is not benchmarked at Synthea scale.
KNDB's contribution is the engine mechanism, the honest overhead numbers, and
the failing-test-first evidence that the mechanism actually catches the bugs
it claims to catch.
