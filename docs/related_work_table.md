# Related work — per-primitive comparison

Legend:
- **engine** = enforced by the storage engine at write time or by the query
  evaluator at read time; app cannot bypass without SUPERUSER.
- **read-time** = enforced only when a specific query is run; silent
  violations possible at write time.
- **app-layer** = enforced by a library, runtime, or application above the
  storage engine; bypassable by writing directly to the store.
- **no** = not addressed by the system.

| System | Epistemic kind (obs/inf/derived) | Confidence propagation | Write-time conflict resolution | Bitemporal validity | Progressive depth |
|---|---|---|---|---|---|
| **KNDB** (this work) | engine | engine (ProvSQL Viterbi) | engine | engine | engine |
| TypeDB | engine (`entity`/`relation`/`attribute` kinds, not obs/inf/derived) | no | no | app-layer | no |
| XTDB | no | no | app-layer | engine | no |
| Datomic | no | no | app-layer (upsert semantics) | engine (tx-time + valid-time in v2) | no |
| Zep | no | app-layer | app-layer | engine (edges) | no |
| Graphiti | no | app-layer | app-layer | engine (edges) | read-time |
| ProvSQL | no | engine (semiring choice at query time) | no | no | no |
| MemIR (arXiv:2605.25869) | app-layer (typed atoms in runtime) | app-layer | app-layer | app-layer | app-layer |
| ATCH (arXiv:2603.13603) | engine (theoretical; Postgres prototype partial) | engine (theoretical) | engine (theoretical) | engine | no |
| Materialize | no | no | no | no (system-time only) | no |
| RisingWave | no | no | no | no (system-time only) | no |

## The gap KNDB fills

The engine column is empty across all five primitives for every existing
production or research system except ATCH, and ATCH is a theorem plus an
unbenchmarked prototype. KNDB's contribution is not that the primitives are
novel in isolation — TypeDB has had kinds for years, ProvSQL has had
semiring propagation since VLDB 2018, XTDB has had bitemporal validity from
day one — but that no engine ships all five together with write-time
enforcement and honest overhead measurements against a realistic workload.

The two closest recent papers deserve a careful distinction because a
hostile reviewer will pattern-match to them.

**MemIR (Jin et al., arXiv:2605.25869, May 2026)** enforces typed atoms and
provenance-scoped retrieval in an agent-memory *runtime*. The typing lives
in the retrieval layer, not the storage engine. If a second agent, a manual
psql session, or a bulk import bypasses the runtime, the typing is gone.
KNDB puts the check in a BEFORE trigger — every write path is intercepted,
including SUPERUSER-less DBA sessions and LLM-generated SQL that reaches the
socket directly.

**ATCH (Alford, arXiv:2603.13603, Feb 2026)** proves an equivalence theorem
that any structurally complete knowledge representation must simultaneously
support n-ary attributed relationships, temporal validity, uncertainty, and
causal relationships. The paper includes a PostgreSQL extension prototype but
does not report Synthea-scale benchmarks, does not commit to a specific
engine-enforcement mechanism per primitive, and does not distinguish
observation from inference from derived (its uncertainty axis is scalar).
KNDB is a narrower, empirical follow-through: pick one engine (Postgres +
ProvSQL), pick one epistemic ternary, ship the triggers, measure the
overhead.

The remaining systems either miss the trust primitives entirely (Materialize,
RisingWave — both stream-processing engines optimized for freshness, not
epistemic distinction) or address a strict subset without engine enforcement
(Zep, Graphiti, Datomic, XTDB).
