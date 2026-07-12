contrib/epistemic
=================

Native PostgreSQL 18 table access method that runs the KNDB epistemic
write-time rules and precedence lattice from inside heapam's
tuple_insert callback, then delegates storage to heap. Rows on disk
are plain heap tuples. Every TableAmRoutine callback except
tuple_insert and relation_toast_am is heap's, unmodified.


Overview
--------

The extension registers one access method (CREATE ACCESS METHOD
epistemic ... HANDLER epistemic_am_handler) and one base type
(epistemic_kind, a pass-by-value byte). On CREATE TABLE ... USING
epistemic the resulting relation has heap's on-disk layout; the AM's
tuple_insert wrapper runs R1..R5 (epistemic_rules.c), probes for a
live overlapping row via seqscan (epistemic_am.c: find_live_overlap),
runs the precedence lattice (epistemic_precedence_cmp), then calls
heap's tuple_insert. If the incumbent lost, the wrapper writes one
audit row to epistemic.evicted_fact via SPI and closes the
incumbent's sys_time upper bound via simple_heap_update. Finally it
emits one annotation record on custom rmgr 128 (epistemic_wal.c).


What is load-bearing
--------------------

The bypass-survival claim rides on the tuple_insert wrapper being
reachable from every write path that a user-space trigger control
cannot turn off. Concretely: the epistemic_check_rules call at
epistemic_am.c step 1 is what rejects an R3-violating MEASURED insert.
scripts/bypass.sh runs that insert under two bypass mechanisms
(ALTER TABLE ... DISABLE TRIGGER ALL and
SET session_replication_role = 'replica') against fact_native (this
AM) and fact_trigger (heap + BEFORE INSERT trigger). The bad row
lands on fact_trigger under both mechanisms and is rejected on
fact_native under both. With the epistemic_check_rules call replaced
by rule = EP_RULE_NONE, rebuilt, all four fact_native assertions in
bypass.sh flip from OK to FAIL. That is the adversarial control. See
DECISIONS.md (F2).

Everything else in the wrapper — WAL annotation, precedence eviction,
audit, sys_time close — is either delegated to heap for durability or
exists for downstream consumers. It is not what the bypass claim
rides on.


What delegates to heap
----------------------

The AM copies heapam's TableAmRoutine at first handler call
(epistemic_am_handler at epistemic_am.c) and overrides two entries:
tuple_insert and relation_toast_am. The remaining ~38 callbacks
(scan_begin, scan_getnextslot, tuple_fetch_row_version,
tuple_update, tuple_delete, tuple_lock, index_fetch_*,
relation_set_new_filelocator, relation_nontransactional_truncate,
relation_copy_data, relation_copy_for_cluster, relation_vacuum,
scan_analyze_next_block, scan_analyze_next_tuple,
index_build_range_scan, index_validate_scan, relation_size,
relation_needs_toast_table, relation_estimate_size, ...) are heap's.

Durability of the row is heap's. The AM's custom rmgr writes a
buffer-less annotation record after the insert; disabling it leaves
recovery under wal_consistency_checking=all indistinguishable. The
disable-and-retest transcript is in DECISIONS.md (F3): recovery.sh
runs 110 inserts, crashes, recovers 110/110 rows with the marker
disabled and with the marker plus the (now-deleted) evict logger
disabled. Heap's XLOG_HEAP_INSERT (heapam.c:2222-2226 in
REL_18_STABLE) carries every column, ep_kind and ep_specificity and
ep_confidence included; heap_xlog_insert (heapam_xlog.c:482-503)
reconstructs it at redo.


Correctness envelope
--------------------

The "at most one live row per (entity_id, attribute) slot" invariant
that sql/am_eviction.sql asserts holds under SERIALIZABLE isolation
on a serial-arrival path. It does NOT hold under READ COMMITTED and
concurrent same-slot writers: each session's find_live_overlap
seqscan uses its own snapshot and cannot see the other session's
uncommitted insert; both hit the empty-overlap branch, both
heap_insert, both commit, two live rows land. This is not resolved
by the epistemic rules and is not a bug in the rules — it is a
consequence of MVCC visibility under weaker isolation. See
DECISIONS.md (F4, section B) for the 50-trial transcript.

Under SERIALIZABLE and two overlapping same-slot writers, one
session aborts with SQLSTATE 40001; the survivor is whichever
transaction PG did not choose to pivot-abort, which is
commit-order-dependent, not content-dependent. The tie policy
(EP_REASON_CONTRADICTED_SAME_RANK -> NEW_WINS) is exercised only on
the serial path within a single session, where it is deterministic
given a fixed arrival order.

Fix 6 attempts to close both edges of this envelope
(RC integrity leak; SR concurrent survivor non-determinism). See
DECISIONS.md when it lands.


Threat model
------------

The engine-in-storage bypass claim holds against a writer with
INSERT + ALTER TABLE on the target relation, or a role that can
toggle session_replication_role (PGC_SUSET; the profile of a
replication/CDC operator, a migration tool, or a pool operator
setting the GUC pool-wide). It does not hold against the table
owner, who can ALTER TABLE ... SET ACCESS METHOD heap and rewrite
the relation onto plain heap, at which point the AM callback is out
of the write path entirely. That is a schema-change threat, not a
write-path threat, and is out of scope. See DECISIONS.md (F2) for
the PG 18 source citations on both bypass mechanisms
(commands/tablecmds.c:5588-5592, commands/trigger.c:3489-3499).


Build / test / run
------------------

Assumes pg_config on PATH resolves to a PG 18 install with headers.

    make
    make install
    make installcheck                              # 6 regression suites
    PROVE_TESTS='t/*.pl' make prove_installcheck   # TAP (empty today)
    make check-e2e                                 # 5 e2e scripts

The extension requires shared_preload_libraries = 'epistemic' so the
custom rmgr is registered before recovery. The e2e scripts and TAP
harness set this automatically on their isolated clusters. For
manual installcheck against a pre-existing cluster, add it to
postgresql.conf and restart.

check-e2e runs, on isolated clusters spun up in /tmp:

    scripts/recovery.sh          crash + recovery, 110 rows round-trip
    scripts/concurrency.sh       fair SSI check on native and trigger
    scripts/bypass.sh            trigger-disable + replica-role bypass
    scripts/crash_atomicity.sh   25 trials, eviction atomicity
    scripts/tie_concurrency.sh   50 trials each at RC and SR, tie probe

Baseline counts after F4: installcheck 6/6, check-e2e 5/5.


Layout
------

    include/
      epistemic.h              cross-module contract, EpistemicMeta
      epistemic_am.h           TAM handler prototype
      epistemic_wal.h          rmgr entry points + record layout
      epistemic_rules.h        R1..R5 predicate prototypes
      epistemic_precedence.h   precedence lattice + reason codes
    src/
      epistemic_init.c         _PG_init, registers rmgr 128
      epistemic_am.c           tuple_insert wrapper, delegation
      epistemic_wal.c          rmgr callbacks + marker builder
      epistemic_type.c         epistemic_kind C I/O
      epistemic_rules.c        R1..R5 + precedence cmp
    sql/  expected/            6 regression suites
    scripts/                   5 end-to-end shell tests
    t/                         TAP harness (empty)
    epistemic--1.0.sql         extension SQL
    epistemic.control          extension control
    DECISIONS.md               F1..F4 engineering audits
