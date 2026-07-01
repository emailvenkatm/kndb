# Threat model

What KNDB defends against, and what it does not. If you are choosing whether
to build on KNDB, read the "out of scope" list first — it is the more
important one.

## In scope

KNDB's engine enforcement is designed to hold against the following
adversaries and failure modes.

- **Untrusted application code.** The app connects as a role without
  `SUPERUSER` and without `ALTER TABLE` privilege on `engine/` tables. Any
  write it issues goes through the BEFORE triggers. Buggy app code cannot
  silently corrupt epistemic-kind invariants; contradictory writes cannot
  silently overwrite prior claims.
- **LLM-generated SQL.** SQL synthesized by a language model and executed
  against KNDB (via MCP servers, function-calling agents, code-interpreter
  tools) is treated identically to untrusted app code. The threat is not
  malice but drift: the model may hallucinate columns, invent join
  conditions, or misclassify inferences as observations. The engine catches
  the misclassification at write time.
- **Multi-tenant applications sharing a database.** One tenant's buggy
  code cannot violate invariants seen by another tenant. Row-level security
  handles tenant isolation on the read path; engine triggers handle
  invariant enforcement on the write path.
- **Human operator error.** A DBA connecting via `psql` under a
  non-`SUPERUSER` role cannot silently violate the invariants either. Bulk
  imports through `COPY` still fire the BEFORE triggers unless the operator
  explicitly disables them.
- **Confidence-value corruption.** Writes that would place a `confidence`
  outside [0, 1] are rejected by the domain check.
- **Silent overwrite of a contradictory claim.** No policy setting allows a
  contradicting fact to overwrite an incumbent without an audit-table
  record. `conflict_policy = 'invalidate'` trims the incumbent's valid-time
  and logs the trim; `conflict_policy = 'reject'` refuses the new fact and
  logs the rejection. Silent overwrite is not a policy.

## Out of scope

The following are explicitly *not* defended against. If your threat model
includes any of these, KNDB alone is not sufficient.

- **Malicious DBA with `SUPERUSER`.** A `SUPERUSER` can `ALTER TABLE ...
  DISABLE TRIGGER ALL`, drop the ProvSQL extension, `TRUNCATE` the audit
  table, or replace `engine/` files on disk. Mitigation is operational
  (role separation, `SUPERUSER` audit logging, immutable backups) and lives
  outside KNDB's engine.
- **Kernel or hardware compromise.** If the OS kernel, hypervisor, or
  hardware is compromised, Postgres itself is compromised and KNDB's
  guarantees are void. There is no in-engine defense.
- **Adversarial Postgres extension code.** A malicious extension loaded via
  `CREATE EXTENSION` can hook the executor below the trigger layer, rewrite
  the parse tree, or bypass RLS. KNDB assumes the extension set is trusted
  and pinned (currently: `provsql`, `btree_gist`).
- **Side-channel timing attacks.** Confidence values, trigger dispatch
  timing, and provenance annotations may leak information through query
  latency. KNDB does not defend against this and no attempt is made to
  measure the leak.
- **Adversarial input at label-synthesis time.** If the upstream Synthea
  data (or the label-synthesis code that assigns obs/inf/derived tags to
  Synthea rows) is poisoned before load, KNDB faithfully stores the poison.
  The engine enforces that the labels are consistent with the write, not
  that the labels are true.
- **Prompt-injection attacks against LLMs that read from KNDB.** If an
  attacker plants a prompt-injection payload as an observation value, KNDB
  stores it. Downstream LLM consumers must sanitize.
- **Denial of service via trigger cost.** A high-volume adversarial write
  workload can exhaust CPU on the trigger dispatch path. Mitigation is
  rate-limiting at the connection layer, not in the engine.
- **Recovery from a compromised audit table.** If `kndb_audit` is itself
  corrupted, KNDB cannot reconstruct the history. Audit-table integrity is
  the operator's responsibility (append-only mode, off-site log shipping).
