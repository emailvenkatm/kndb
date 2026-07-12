# Engineering decisions

Short notes recording load-bearing design choices and, where useful, the
audit that produced them. New entries go on top. Each entry is dated and
identifies the code paths involved.

## 2026-07-12, F3: rmgr 128 is an annotation channel, not a durability channel

Heap's XLOG_HEAP_INSERT already carries every byte of every column
we care about. In PG 18 REL_18_STABLE, heap_insert at
src/backend/access/heap/heapam.c:2222-2226 does
    XLogRegisterBufData(0, &xlhdr, SizeOfHeapHeader);
    XLogRegisterBufData(0, (char *) heaptup->t_data + SizeofHeapTupleHeader,
                        heaptup->t_len - SizeofHeapTupleHeader);
so the entire user tuple — ep_kind, ep_specificity, ep_confidence,
sources, valid_time, sys_time, all of it — is in heap's WAL record.
heap_xlog_insert at heapam_xlog.c:417-503 reconstructs the page via
XLogRecGetBlockData + PageAddItem. Our rows are plain heap tuples;
there is no epistemic-only state to persist. There is no scenario
where the epistemic record adds durability that heap doesn't
already provide, and I did not manufacture one.

Grep of every .c file for the four loggers declared in epistemic_wal.h:
  - epistemic_wal_log_insert        0 callers (dead)
  - epistemic_wal_log_insert_marker 1 caller  (epistemic_am.c:388)
  - epistemic_wal_log_evict         1 caller  (epistemic_am.c:375)
  - epistemic_wal_log_audit         0 callers (dead)

Empirical test 1 (marker): comment out the marker call in
epistemic_am.c step 8, rebuild, make install, run scripts/recovery.sh
on a fresh cluster with wal_consistency_checking = all.
  pre-crash lsn=0/1BBA568 count=110
  post-recovery row count=110
  PASS: recovery round-tripped 110 rows
No PANIC, no "inconsistent page", no non-benign FATAL. The marker is
not load-bearing for durability.

Empirical test 2 (evict): comment out the evict call in step 7 as
well. Recovery.sh only exercises non-overlapping inserts, so evict
never fires there; add an eviction-inducing crash test (50 INFERRED
rows, checkpoint, 50 evicting MEASURED inserts post-checkpoint,
immediate stop, restart).
  pre-crash:    total=100 live=50 closed=50 audit=50
  post-recovery: total=100 live=50 closed=50 audit=50
  PANIC/inconsistent hits: 0
  PASS: eviction state fully recovered by heap WAL alone
The three real state changes on the eviction path — winner INSERT,
loser sys_time UPDATE, audit-row INSERT into epistemic.evicted_fact —
are each already covered by heap's own XLOG_HEAP_INSERT and
XLOG_HEAP_UPDATE. The EVICT record adds nothing.

Empirical test 3 (both off): with both loggers disabled — i.e., the
extension writes ZERO records on rmgr 128 — recovery.sh still passes
110/110 rows and the eviction crash test still passes 100 rows with
50 closed and 50 audit rows. That is the strongest form of the
proof: the rmgr is inert for durability.

Chose demotion (b). Changes:

  * Deleted the dead loggers `epistemic_wal_log_insert` (full tuple
    logger, was never called) and `epistemic_wal_log_audit` (was
    never called).
  * Deleted the evict logger `epistemic_wal_log_evict` and its call
    site in epistemic_am.c (proved decorative above; evict path's
    durability lives in heap_update's WAL and heap_insert's WAL for
    the audit relation).
  * Deleted the record structs `xl_epistemic_evict` and
    `xl_epistemic_audit` and their info bytes XLOG_EPISTEMIC_EVICT
    and XLOG_EPISTEMIC_AUDIT.
  * Kept `epistemic_wal_log_insert_marker` and XLOG_EPISTEMIC_INSERT
    as the sole annotation channel. It writes tuple_len=0 and no
    buffer reference; recovery.sh with it removed proves it is not
    load-bearing. It is retained so sql/wal.sql's rm_id=128 probe
    reflects a real emitted record and so a future logical decoding
    consumer has a named channel to hook.

Reservations. rm_decode is NULL, so logical decoding
(src/backend/replication/logical/decode.c:115-117) skips epistemic
records. PG 18's stock pg_waldump does not load custom rmgrs, so it
renders the record as "custom128 UNKNOWN (10) rmid: 128" — verified
locally on a WAL segment containing an emitted marker. In-server
wal_debug is the only path today that reaches rm_desc. That is the
honest scope of the "annotation channel" phrase.

README and code comments that said the rmgr provides durability, or
implied a working logical-decoding consumer, have been rewritten to
match the demoted role. sql/wal.sql keeps its rm_id=128 probe; only
the header comment was updated.

Attacker model, unchanged from F2. The AM-in-storage differentiator
still holds. This audit narrows what durability the paper can claim
comes from the extension: durability comes from heap. What the AM
provides is the write-time enforcement point and, as a byproduct, a
named annotation channel that is currently unused.

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
