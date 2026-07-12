# Engineering decisions

Short notes recording load-bearing design choices and, where useful, the
audit that produced them. New entries go on top. Each entry is dated and
identifies the code paths involved.

## 2026-07-12, F2: the differentiator is bypass survival, not SSI

F1 established that both fact_native and a scan-equipped
fact_trigger reach the same SIRead-based abort under SERIALIZABLE:
the AM inherits heapam's predicate locking, and a plpgsql trigger
that runs the same overlap probe inherits the same lock. Under fair
conditions there is no concurrency-level difference to demonstrate.
`scripts/concurrency.sh` now asserts exactly that — both paths abort
at least one session — and exits 0 on that basis, with no
epistemic-specific SSI claim.

The engine-level difference the paper actually rests on is bypass
survival. A BEFORE INSERT trigger is a catalog object a writer can
turn off; an AM callback runs from inside heapam's tuple_insert path
and no user-space GUC or ALTER TABLE reaches it.

Two bypass mechanisms verified against PG 18 source:

  1. `ALTER TABLE ... DISABLE TRIGGER ALL` flips
     pg_trigger.tgenabled to 'D'
     (src/backend/commands/tablecmds.c:5588-5592, REL_18_STABLE).
     `TriggerEnabled` at trigger.c:3491-3499 then returns false
     regardless of SessionReplicationRole.

  2. `SET session_replication_role = 'replica'`. Under
     SESSION_REPLICATION_ROLE_REPLICA, `TriggerEnabled` at
     trigger.c:3489-3499 skips both TRIGGER_FIRES_ON_ORIGIN (the
     default for `CREATE TRIGGER`) and TRIGGER_DISABLED. Only
     TRIGGER_FIRES_ON_REPLICA and TRIGGER_FIRES_ALWAYS fire.

`scripts/bypass.sh` runs an R3-violating MEASURED insert under each
bypass against both tables. The bad row lands on fact_trigger and
is rejected on fact_native. The AM's `epistemic_check_rules` block
in `epistemic_tuple_insert_impl` is what does the rejecting; with
that block replaced by `rule = EP_RULE_NONE`, rebuilt, and
reinstalled, all four `fact_native` assertions in bypass.sh flip
from OK to FAIL and the bad row lands on both tables. Restoring the
source verbatim restores the OKs. Transcript in the F2 report.

Attacker model. This differentiator holds for a writer with INSERT
+ ALTER TABLE on the target relation, a role that can toggle
`session_replication_role`, or a connection-pool operator setting
that GUC globally. It does not hold against the table owner, who
can `ALTER TABLE ... SET ACCESS METHOD heap` and rewrite the table
onto plain heap, at which point the AM callback is out of the
write path. That is a schema-change threat, not a write-path threat,
and is out of scope for this claim. Documented in the bypass.sh
preamble and in the README's threat-model paragraph.

## 2026-07-12, F1: predicate locking is delegated to heapam

`src/epistemic_ssi.c` and `include/epistemic_ssi.h` used to hold three
wrappers around `PredicateLockTID`, `PredicateLockRelation`, and
`CheckForSerializableConflictIn`. Only one, `epistemic_predicate_lock_slot`,
was ever called (from `epistemic_tuple_insert_impl`). It hashed the logical
key `(entity_id, attribute, valid_lower, valid_upper)` into a synthetic
`ItemPointer` and called `PredicateLockTID` on that TID.

A hostile-review audit isolated the source of the SQLSTATE 40001 that
scripts/concurrency.sh observes on the native path. Four probes, each on
a fresh cluster, all SERIALIZABLE:

1. Baseline (both AM helpers enabled), two overlapping inserts on
   `(entity=1, attribute='bp')`: one session got 40001 at commit as
   "canceled on identification as a pivot".
2. Same setup but with two non-overlapping keys, `(1,'bp')` vs
   `(42,'temperature')`, whose hashes are almost certainly distinct:
   still one 40001. The synthetic hash cannot be the mechanism.
3. `epistemic_predicate_lock_slot` disabled, overlapping keys: still one
   40001. The wrapper is not load-bearing.
4. Wrapper disabled *and* the `find_live_overlap` seqscan skipped:
   both sessions commit, two rows land. The mechanism was entirely
   `heap_beginscan → PredicateLockRelation` plus `heap_insert →
   CheckForSerializableConflictIn`, both of which fire automatically
   inside the heapam callbacks we delegate to.
5. Wrapper re-enabled, seqscan still skipped, same-key writers: no
   40001. The wrapper cannot produce a conflict on its own either.
   `PredicateLockTID` is a read-side SIRead; two writers hashing to the
   same synthetic TID never form an rw-antidependency because neither
   scans the other's synthetic TID.

The wrapper was decorative. It has been deleted rather than left as a
dead function. The AM now relies on heapam's own predicate locking,
which is coarser (relation-level, not slot-level) but real. This is
worth being honest about in the paper: KNDB's serialization behaviour
in the current PoC is the standard PostgreSQL table-AM serializable
behaviour, not a novel slot-level SSI. A slot-level SIRead lock would
require touching predicate.c directly to add a new lock target type,
which is out of scope for the PoC.

The `ssi` regression test file was a one-line probe of `pg_extension`;
it has been removed along with the wrapper. Test coverage of the write
path lives in `precedence`, `am_basic`, `r2_sources`, and `am_eviction`.
