# KNDB v2 upgrade plan (2026-07-02, awaiting approval)

Precedence-lattice conflict resolution, use-permission enforcement, kind rename, motive statement, self-validation suite. No code changes yet; every change below is scoped and reversible.

Prose here contains no em-dashes.

---

## 0. What is changing at a glance

| Area | Today | v2 target |
|---|---|---|
| Kind enum values | `observation`, `inference`, `derived` (lowercase) | `MEASURED`, `INFERRED`, `DERIVED` (uppercase) |
| Conflict resolution | Same-value absorb, then per-attribute policy (`reject` or `invalidate`); confidence not consulted | Same-value absorb, then ordered lattice: kind rank, then specificity, then confidence, always audit loser |
| Specificity | Not tracked | New column `kndb.fact.specificity smallint NOT NULL DEFAULT 100` |
| Use permissions | Convention only (any query can read any kind) | Two engine-provided views: `kndb.fact_compliance` (excludes INFERRED) and `kndb.fact_analytics` (all kinds) |
| Motive | Sentence in the docs | Concrete "Why KNDB exists" block at the top of README with numbers |
| Smoke test | `make smoke` runs the M0 ProvSQL empirical checks | `make smoke` becomes an end-to-end proof of all five primitives, under two minutes, wired into CI as the final gate |
| Old M0 checks | Under `make smoke` | Moved to `make verify-extensions` (still runnable, no longer the alias) |

Nothing about the passing 15 sub-tests changes except (a) kind names get renamed in-place and (b) the conflict-primitive tests grow to cover the new lattice.

---

## 1. Precedence lattice (Change 1, the core change)

### 1.1 The lattice, explicit

At write time, when a new row overlaps an existing live row on `(entity_id, attribute, valid_time)` and the values differ, compare NEW to EXISTING in this order and stop at the first tie-breaker:

```
kind rank      MEASURED (3) > DERIVED (2) > INFERRED (1)
specificity    higher wins    (per-row column; batch loaders write 0, targeted writes default 100)
confidence     higher wins    (only consulted when kind and specificity tie)
same-value     absorbed as today (idempotent; not treated as a conflict at all)
```

Same-value overlap continues to widen the survivor's `valid_time` and skip the insert. That is orthogonal to the lattice and stays.

### 1.2 What "loser" means in v2

- If the incoming row is outranked, the write is refused with `KNDB precedence: NEW outranked by fact_id=<uuid>, reason=<code>` and the payload is interpolated into the RAISE for the Postgres log. This matches the current reject-policy behavior; the same autonomous-transaction audit limitation applies and stays documented.
- If the incoming row outranks the existing row, the existing row's `sys_time` upper closes at `clock_timestamp()`, the NEW row lands, and the loser is copied into `kndb_audit.evicted_fact` with the precedence reason.

Reason codes stored in the audit table:
- `kind_outranked` (kind rank decided)
- `specificity` (kind tied, specificity decided)
- `confidence` (kind and specificity tied, confidence decided)
- `contradicted_same_rank` (all three tied and values still differ; NEW wins by arrival, prior audited; reserved for the "true tie" case)

### 1.3 Schema change required

Add one column to `kndb.fact`:

```sql
ALTER TABLE kndb.fact
  ADD COLUMN specificity smallint NOT NULL DEFAULT 100
  CHECK (specificity BETWEEN 0 AND 255);
```

Convention: 0 = batch/general default (nightly loader, imputation job), 100 = normal per-entity write, higher = more specific (adjudicated correction, human override). Numeric so future callers can slot new levels without an ENUM migration.

### 1.4 conflict_policy table: kept but demoted

The current `kndb.conflict_policy` table becomes advisory rather than authoritative. When set to `reject` for an attribute, the trigger rejects any conflict regardless of the lattice, matching current behavior. When absent or set to `invalidate`, the lattice runs. This preserves the tests that already register `bp_systolic` as reject-policy.

### 1.5 Trigger sketch (not code yet, just the shape)

```
kndb.resolve_conflict(NEW):
  if upper(NEW.sys_time) is not infinity: return NEW              -- historical writes exempt
  for each overlapping row in current sys_time:
    if same value:  extend survivor.valid_time, return NULL       -- as today
    if policy = 'reject' for this attribute:  RAISE                -- as today
    if lattice(NEW) > lattice(overlapping):
      close overlapping.sys_time, audit overlapping with reason, let NEW land
    elif lattice(NEW) < lattice(overlapping):
      RAISE with the precedence reason interpolated                -- NEW never lands
    else:  -- true tie, values differ
      close overlapping.sys_time, audit with reason='contradicted_same_rank', let NEW land
  return NEW
```

### 1.6 New tests to add

Three tests requested by the spec:

- `T3.4` A high-confidence INFERRED (0.97) that arrives after a lower-confidence MEASURED (0.90) is refused. Prior MEASURED stays live.
- `T3.5` Arrival order does not matter: MEASURED arriving after INFERRED still evicts the INFERRED, not the other way round.
- `T3.6` Audit row records reason=`kind_outranked` when the lattice fires on kind rank.

Plus additional tests to cover the new lattice tie-breakers:

- `T3.7` Kind tied on DERIVED, higher specificity wins, reason=`specificity`.
- `T3.8` Kind and specificity tied, higher confidence wins, reason=`confidence`.
- `T3.9` All three tied, values differ, NEW lands, prior audited with reason=`contradicted_same_rank`.

Existing `T3.1` (same-value absorption), `T3.2` (invalidate policy), `T3.3` (reject policy) stay green with the renamed kinds.

---

## 2. Use-permission enforcement (Change 2)

### 2.1 Design

Two engine-provided views on top of `kndb.fact`:

- `kndb.fact_compliance`  --  `WHERE epistemic_kind <> 'INFERRED' AND upper(sys_time) = 'infinity'`
- `kndb.fact_analytics`   --  `WHERE upper(sys_time) = 'infinity'`

Compliance-scoped code paths select from `kndb.fact_compliance`. Analytics paths select from `kndb.fact_analytics`. The difference is not a convention or a WHERE-clause someone can forget; it is the shape of the object you are querying.

### 2.2 Optional: registry pattern for future extensibility

If we ever need more than two scopes (e.g. add `training_data_safe` that excludes DERIVED too), a registry pattern would be cleaner:

```sql
CREATE TABLE kndb.query_scope (
  scope_name text PRIMARY KEY,
  allowed_kinds kndb.epistemic_kind[] NOT NULL
);
```

Plus a function `kndb.facts(scope_name text)` that returns the filtered set. For v2 the two hard-coded views suffice; the registry pattern can wait unless review says otherwise.

### 2.3 Test

`T6.1` A row inserted with kind INFERRED (confidence 0.95, specificity 100) does not appear in `kndb.fact_compliance` but does appear in `kndb.fact_analytics`. The same MEASURED companion row appears in both.

---

## 3. Rename the kinds (Change 3)

`observation` -> `MEASURED`, `inference` -> `INFERRED`, `derived` -> `DERIVED`.

### 3.1 Migration approach

Postgres ENUMs cannot be renamed in place while preserving column data if the enum labels change. We rebuild the type:

1. `ALTER TYPE kndb.epistemic_kind RENAME TO epistemic_kind_v1;`
2. `CREATE TYPE kndb.epistemic_kind AS ENUM ('MEASURED', 'INFERRED', 'DERIVED');`
3. Add a temporary column, populate by mapping, swap columns, drop the old.

Simpler for a research prototype where we can regenerate the schema: drop the type after DROP-and-recreate of the tables that use it. `make reset` already handles that.

### 3.2 Files touched by the rename

Grep-based sweep:

- `engine/01_types.sql` (the ENUM definition)
- `engine/02_facts_schema.sql` (comments and defaults)
- `engine/03_triggers_epistemic.sql` (rule R5, error text)
- `engine/04_triggers_conflict.sql` (kind comparisons in the new lattice)
- `engine/05_bitemporal.sql` (comments)
- `engine/07_progressive_depth.sql` (depth 0/1/2 kind mapping)
- `tests/*.sql` (every VALUES row)
- `baselines/*/schema.sql` (parallel schemas for the benchmark)
- `baselines/py_guards/guards.py` (Python side of the guard baseline)
- `bench/adversarial/writes.py` (adversarial payloads reference the old kinds)
- `demo/demo.sh`, `demo/clinical/*.sql`
- `README.md`, `DESIGN.md`, `docs/*.html`, `docs/related_work_table.md`
- `STATUS.md`, `DECISIONS.md` (log entries about the rename)

DECISIONS.md gets a new dated entry: what changed, why (paper's audience expects MEASURED / INFERRED / DERIVED as ALL CAPS taxonomy labels), and the pointer to this plan.

---

## 4. Re-run the benchmark with the new precedence trigger (Change 4)

Same adversarial suite (`bench/adversarial/writes.py`, seed 42), same native ARM64 arch. Confirm 70/70 catch still holds; report any throughput change from the added lattice checks vs the old confidence-not-consulted trigger.

Expected direction of change:

- The precedence branch does 1-2 extra column reads per conflict, plus a kind-rank case expression. On the empty-DB run this should be well below noise. On the 565k-Synthea run, per-row cost is dominated by ProvSQL `set_prob` anyway; precedence adds a small constant.
- No expectation of a catch-rate change. Every current adversarial payload is designed around kind and slot mismatches, not multi-row conflicts.

Result files land at `bench/results/native_v2/` and `bench/results/native_synthea_v2/` so v1 numbers stay auditable side by side.

Deliverable: updated `bench/README.md` table showing v1 vs v2 with the delta called out honestly.

---

## 5. Documentation refresh (Change 5)

### 5.1 Motive block at the top of README (this is Change 6 in the task; folded here)

New section right after the title, before the thesis:

> **Why KNDB exists.** AI agents and enrichment pipelines now write model-generated data into operational databases at scale, next to verified facts, with no origin distinction at the storage layer. Public data quality audits put third-party enrichment accuracy at 65 to 85 percent depending on field and vendor. API-written contact records show duplicate rates near 80 percent in surveyed CRMs. CFPB expects lenders to be able to explain algorithmic adverse actions on demand. Model developers now decontaminate training data from prior model output to avoid model collapse. All four problems have the same shape: the database does not know which values came from a measurement and which came from a model. KNDB makes origin a first-class, engine-enforced property of every row.

Numbers are placeholders pending citation; the spec asked for factual tone, so exact figures will land with sources in the same edit (I'll pull specific 2024-2026 sources for each stat before shipping).

### 5.2 Replace the HbA1c motivating story throughout

Wherever the current docs use `labs.hba1c` as the motivating example, replace with one of the four spec-approved examples:

- **MDM survivorship**: postal-verified address overwritten by a fresher but unverified address from a CRM sync. In v2 KNDB, the fresher row is typed INFERRED (source: CRM), lattice keeps the MEASURED (postal) row alive.
- **CRM enrichment accuracy**: Clearbit fills company employee count. In v2 KNDB, the enriched row is INFERRED with the vendor confidence; the verified count stays MEASURED.
- **CFPB explainability**: adverse-action letter must explain a model-derived denial. `kndb.fact_compliance` excludes INFERRED by default, so the adjudicator sees only MEASURED and DERIVED evidence; the letter can name the specific measured facts that drove the decision.
- **Training-data decontamination**: query at depth 0 (MEASURED only) via `kndb.expand(entity, 0)` to build a training set with no model-generated inputs.

### 5.3 Constraints

- No em-dashes anywhere in prose (README, DESIGN.md, HTML explainers, DECISIONS.md entries, this plan).
- No mention of Sanskrit or Panini anywhere.
- Every citation URL fetched and confirmed live before commit (the arXiv author-ban rule stays).

### 5.4 DESIGN.md updates

- Primitive 1 "Epistemic typing" section: rename to MEASURED / INFERRED / DERIVED and add the new specificity column.
- Primitive 3 "Write-time conflict" section: replace the "reject-vs-invalidate policy" paragraph with the precedence lattice.
- New Primitive 6 or new sub-section "Use permissions": the two views.
- The `docs/team_explainer.html` "5 primitives" section gets the same treatment.

### 5.5 STATUS.md update

Under "Still in progress or known gap" -> remove any lines the v2 upgrade closes. Add lines for anything v2 introduces as a new gap (e.g. specificity is populated by writers today; a future step could infer it from `writer` or session role).

---

## 6. Self-validation smoke suite (Change 7)

### 6.1 Rename the current `make smoke`

The current `make smoke` runs the M0 ProvSQL empirical checks (`smoke_a_viterbi_leftjoin.sql`, `smoke_b_gist_provsql.sql`). Rename that target to `make verify-extensions` (or keep it available under both names for one release). The new `make smoke` becomes the primitive-level end-to-end proof.

### 6.2 New `smoke.sh`

One bash script. Exits non-zero on any step failure. Steps and pass criteria:

```
[1] apply engine (idempotent)
[2] MEASURED write accepted        -> asserts row count = 1
[3] INFERRED into MEASURED slot    -> RAISE with R5, exit non-zero if not raised
[4] Precedence: high-conf INFERRED cannot displace lower-conf MEASURED
                                    -> asserts prior MEASURED still alive, INFERRED audited
[5] Same-value absorb                -> asserts valid_time widens, row count still 1
[6] Confidence propagation join     -> asserts 0.95 * 0.70 = 0.665 within 0.001
[7] as_of_valid at 2021-06-15      -> asserts value='false', two-fact bitemporal sanity
[8] progressive-depth expand(0/1/2) -> asserts recall monotone non-decreasing,
                                                avg_conf monotone non-increasing
[9] use-permission                  -> INFERRED row absent from fact_compliance,
                                                present in fact_analytics
```

Target runtime: under 30 seconds when the container is warm; the spec's two-minute cap has room for a cold start.

### 6.3 CI wiring

Add `smoke` as the last step in `.github/workflows/ci.yml`, running after the current `tests/` step. If the primitive tests pass but the E2E smoke fails, we still fail the build; that's the whole point.

### 6.4 Demo unification

`make demo` continues to exist as the 60-second narrative for humans watching. `make smoke` is the machine-readable version of the same story: same operations, no color, no `sleep`, PASS/FAIL per step.

---

## 7. Order of operations

1. **This plan approved.** No code yet.
2. Rename kinds (Change 3). Grep sweep. `make test` still green after rename.
3. Add `specificity` column and precedence-lattice trigger (Change 1). Add T3.4 through T3.9. `make test` green.
4. Add `fact_compliance` and `fact_analytics` views (Change 2). Add T6.1. `make test` green.
5. Rewrite `smoke.sh` (Change 7). Wire into `make smoke` and CI.
6. Re-run benchmark on both empty DB and Synthea-preloaded DB (Change 4). Update `bench/README.md`.
7. README motive block, replace HbA1c examples, DESIGN.md update, STATUS.md refresh (Change 5, Change 6).
8. DECISIONS.md entry describing the whole upgrade.
9. Commit + push. CI green on the new `smoke` gate.
10. Update `docs/team_explainer.html` to match the new lattice and use-permissions.

Each step ends with `make test && make smoke` green before proceeding to the next.

---

## 8. Open questions for your call

None of these block starting. All can be settled by the time we hit that step.

1. **Uppercase enum labels.** The spec asks for `MEASURED / INFERRED / DERIVED`. Postgres ENUM labels are case-sensitive text; uppercase works. Confirm.
2. **Specificity default (`100`) and range (0-255).** Reasonable? Or do we want a specific scale like 0/50/100/200 for clarity?
3. **"True tie" behavior.** Currently proposed: NEW lands, prior audited with reason `contradicted_same_rank`. Alternative: reject with a specific error because the caller should decide. Preference?
4. **`conflict_policy` table.** Keep as advisory override, or drop entirely and require callers to disambiguate with specificity? Keeping it preserves the existing reject-policy test with zero churn; dropping is cleaner going forward.
5. **`training_data_safe` scope.** Add now (as the third view) or wait for a user? The Motive block mentions training-data decontamination, so having it live at ship time is coherent.

---

## 9. What I need from you before writing code

- Approve or edit the lattice in Section 1.1.
- Approve the two-view design for use permissions (or ask for the registry pattern instead).
- Approve the specificity column and its default 100.
- Answer the five open questions in Section 8, or say "your call, proceed".

Once approved, I will start with the rename (Change 3, lowest-risk grep sweep) so the remaining changes land on the new names.
