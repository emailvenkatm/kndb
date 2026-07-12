# Engineering decisions

Short notes recording load-bearing design choices and, where useful, the
audit that produced them. New entries go on top. Each entry is dated and
identifies the code paths involved.

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
