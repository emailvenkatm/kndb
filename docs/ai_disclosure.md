# AI-assistance disclosure

Per ACM's 2023 policy on generative-AI tools in authorship (and subsequent
clarifications through 2025), generative-AI assistance is permitted in the
preparation of a submission provided that (a) the human authors take full
responsibility for the content, including correctness of all technical
claims, and (b) the assistance is disclosed. This document is that disclosure.

**Assistant used:** Claude Opus 4.7 (Anthropic), 1M-context configuration,
via the Claude Code CLI harness. Sessions took place between 2026-06-30 and
the submission deadline of 2026-08-04.

**Human author's obligation:** every technical claim in the paper, every
SQL trigger in `engine/*.sql`, every benchmark number in `bench/results/`,
and every conclusion drawn from those numbers is the author's responsibility.
AI assistance is not a defense against a wrong claim.

## What was AI-assisted and how

| Artifact | Human-written | AI-assisted (author steered, AI drafted, author edited) | AI-generated then human-reviewed (AI drafted, author checked line-by-line) |
|---|---|---|---|
| Thesis, contributions, limitations sections of paper | yes | no | no |
| Intro and abstract | yes | no | no |
| Related-work prose | yes | comparison table AI-drafted from citations author supplied | no |
| `engine/01_types.sql` through `engine/06_provsql_setup.sql` | schema shape decided by author | AI drafted SQL, author edited | trigger bodies |
| `tests/engine_enforces_*.sql` | failing-test-first workflow: author wrote the failing test intent, AI produced the SQL, author confirmed it failed against a no-op schema before writing the trigger | yes | no |
| Benchmark harness `bench/run.py`, `bench/metrics.py` | measurement protocol (seed, run count, config-hash logging) decided by author | AI drafted Python, author edited | yes |
| Baselines (`baselines/py_guards`, `baselines/pg_handrolled_triggers`) | steelman scope decided by author | AI drafted | author reviewed and adversarially probed |
| Synthea data generation and label synthesis | author designed the obs/inf/derived split | AI drafted the Bash and Python glue | yes |
| Docker Compose, Makefile, CI | author specified isolation contract, port choices, image pins | AI drafted files | yes |
| DECISIONS.md entries | author authored decisions; AI drafted the prose | yes | no |
| This disclosure file | yes | AI drafted a first pass, author edited | no |

## Research assistance

**ProvSQL semantics and version history.** AI-mediated web search
(WebSearch, WebFetch) was used to locate the ProvSQL 1.10.0 release notes,
the VLDB 2018 paper, and the 2025 ProvenanceWeek update. The author read the
primary sources directly; the AI's role was retrieval, not summarization.

**Synthea workload design.** AI-mediated web search located the OHDSI
ETL-Synthea documentation and confirmed CSV export was supported. The
obs/inf/derived label synthesis (a KNDB-specific transformation on top of
Synthea's FHIR observations) was designed by the author.

**Related-work landscape scan.** AI-mediated web search located MemIR
(arXiv:2605.25869), ATCH (arXiv:2603.13603), Zep (arXiv:2501.13956), and the
ProvSQL update-provenance paper. Author verified each arXiv ID by direct
fetch. TOKI was flagged by the AI as a naming collision (Cosmos IBC bridge,
not a database) and removed from the citation list before it could be cited
in error.

## Human-verified components

Every one of the following is human-verified, meaning the author has
independently reasoned about correctness and, where applicable, produced a
failing test that the mechanism must pass:

- Every BEFORE-INSERT and BEFORE-UPDATE trigger in `engine/`.
- Every Viterbi semiring evaluation reported in the paper (10 hand-computed
  closed-form cases against ProvSQL output).
- Every benchmark number in the paper's tables (author reran with a clean
  container from `sha256:__TO_FILL__` and confirmed match within noise band).
- The threat model in `THREAT_MODEL.md`.
- The claim that the primitive-per-primitive comparison in
  `docs/related_work_table.md` is accurate for the version of each system
  cited (verified by reading each system's docs, not by trusting an AI
  summary).

If a reviewer identifies a discrepancy between AI-drafted content and
observed behavior, the resolution defaults to observed behavior and the
author corrects the artifact.
