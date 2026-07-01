# Reviewer FAQ

Pre-empting the objections a hostile-but-fair reviewer will raise. Each
answer concedes what is true before defending what is novel.

### Q1. This is just CHECK constraints, triggers, and RLS. Where is the novelty?

Conceded: the individual mechanisms (CHECK, BEFORE triggers, GiST EXCLUDE,
RLS) are all stock Postgres, and any competent DBA could write them. The
novelty is not in the mechanisms; it is in (a) picking the right five
primitives to enforce, (b) showing they compose without interfering with
each other (ProvSQL semiring propagation through a GiST-guarded bitemporal
table is not obviously going to work — M0 smoke test B is why we check),
and (c) shipping the honest overhead numbers so future systems can decide
whether the composition is worth adopting. If a reviewer wants to read the
paper as "a set of Postgres idioms with a benchmark," that is a fair reading;
we would still argue the benchmark is the contribution.

### Q2. App-layer validation achieves the same thing.

Conceded, if the app is trusted, single-owner, and never bypassed. Under
that assumption every trust check can live in Python. The threat model in
`THREAT_MODEL.md` is exactly the set of cases where the assumption fails:
multi-tenant SaaS (one tenant's bug corrupts shared invariants),
LLM-generated SQL reaching the socket without human review (the app *is*
the LLM), and long-lived agents whose write code is itself synthesized. In
those cases, engine enforcement is the only enforcement. Baseline B1 (Python
app-layer guards) makes this concrete: on the 100-row adversarial write
suite, B1 catches only what the app happens to route through the guard
functions, while KNDB catches everything.

### Q3. Your baseline is a strawman.

Conceded, if we shipped only B0 (plain Postgres). We ship four baselines:
B0 (plain PG), B1 (PG + Python guards), B2 (PG + hand-rolled trigger suite
matching KNDB's guarantees), and KNDB. B2 is the steelman — a competent DBA
sitting down to reproduce KNDB's guarantees without the engine primitives.
The comparison against B2 is where the paper lives or dies. If a reviewer
believes B2 is not the strongest hand-rolled trigger suite possible, we
would like a concrete pull request; the file is `baselines/pg_handrolled_triggers/`
and we will merge improvements.

### Q4. Where is the formal proof?

There isn't one, and we don't claim there is. The scoped claim is:
"under Postgres snapshot isolation with the triggers in `engine/` active
and no SUPERUSER intervention, the five invariants hold on the tested
workloads." A TLA+ or Coq mechanization is future work and is called out
in the limitations section. Reviewers who want a proof-first paper should
read ATCH (arXiv:2603.13603); reviewers who want a running system with
benchmark numbers should read this one.

### Q5. Overhead is prohibitive.

The overhead numbers are what they are and we report them honestly, including
the workloads where KNDB loses (write-heavy non-conflicting insert paths pay
for the trigger dispatch with no upside). Two responses. First, "prohibitive"
depends on the deployment: a clinical-trial-eligibility workload is not
insert-heavy in the hot path, so the trigger cost is amortized. Second,
absolute numbers on M-series Macs are under amd64 emulation and are not
comparable to native amd64 — see `docs/reproducibility.md`. Relative numbers
against baselines B0/B1/B2 hold under emulation.

### Q6. MemIR already did this.

MemIR (arXiv:2605.25869, May 2026) enforces typed atoms and provenance-scoped
retrieval in an agent-memory *runtime*, not a storage engine. The distinction
matters when a second agent, a psql session, a bulk import, or an ORM
migration bypasses the runtime — the MemIR guarantee is gone, silently. KNDB
puts the checks in BEFORE triggers, so every write path is intercepted at
the same enforcement layer. A fair reading is that KNDB and MemIR are
complementary: MemIR at the retrieval layer, KNDB at the storage layer.
We are not the same paper.

### Q7. ATCH already formalized this.

ATCH (Alford, arXiv:2603.13603, Feb 2026) proves an equivalence theorem
that structurally complete knowledge representation requires n-ary attributed
relationships, temporal validity, uncertainty, and causal relationships
simultaneously. The paper includes a PostgreSQL extension prototype but does
not commit to a specific engine-enforcement mechanism per primitive, does
not distinguish observation from inference from derived (its uncertainty
axis is scalar), and does not report benchmarks on a realistic workload.
KNDB is the empirical follow-through under a narrower scope: pick one
epistemic ternary, ship the triggers, measure against Synthea. If the
theorem is right and the mechanism is wrong, KNDB is still useful as a
counter-example workload.
