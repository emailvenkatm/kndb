contrib/epistemic
=================

Native PostgreSQL 18 table access method that runs the KNDB epistemic
write-time rules and precedence lattice from inside heapam's
tuple_insert callback, then delegates storage to heap. Rows on disk
are plain heap tuples. Every TableAmRoutine callback except
tuple_insert, multi_insert, and relation_toast_am is heap's,
unmodified.


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

The AM's multi_insert wrapper (F18) covers COPY FROM's CIM_MULTI
batch path: it iterates over the batched slots and invokes the
tuple_insert wrapper per row, giving byte-for-byte identical
enforcement to a single-row INSERT of the same rows. Correctness
over throughput — COPY into an epistemic table runs at roughly the
throughput of an equivalent INSERT ... SELECT, not of a plain-heap
COPY. See DECISIONS.md (F18) for the F9-audit that surfaced this
bypass and the tradeoff analysis.


What is load-bearing
--------------------

The bypass-survival claim rides on the tuple_insert AND multi_insert
wrappers being reachable from every write path that a user-space
trigger control cannot turn off. Concretely: the epistemic_check_rules
call at epistemic_am.c step 1 is what rejects an R3-violating
MEASURED insert. scripts/bypass.sh runs that insert under three bypass
mechanisms — ALTER TABLE ... DISABLE TRIGGER ALL,
SET session_replication_role = 'replica', and COPY FROM (F18) —
against fact_native (this AM) and fact_trigger (heap + BEFORE INSERT
trigger). The bad row lands on fact_trigger under DISABLE / replica
(and is caught by fact_trigger's BEFORE trigger under COPY, because
having a BEFORE trigger forces copyfrom.c:1005 to insertMethod =
CIM_SINGLE, which routes through table_tuple_insert). fact_native
rejects the row under all three. With the multi_insert wiring
commented out at src/epistemic_am.c line ~751 and rebuilt, the COPY
scenario's fact_native assertions flip from OK to FAIL, and a
plain-heap-shaped COPY silently lands the bad row (COPY 1 for the
single-row cell, COPY 5 for the mixed batch). That is the F18
adversarial control. See DECISIONS.md (F2, F18).

The single-live-row-per-slot claim rides on three mechanisms inside
epistemic_tuple_insert_impl (F6 for the first two, F8 for the third):

  * per-slot advisory xact lock (LOCKTAG_ADVISORY, key1=entity_id,
    key2=hash_bytes(attribute)) taken between the rule check and the
    overlap scan. scripts/rc_invariant.sh flips it off, rebuilds, and
    the RC leak (both writers commit, two live rows land) returns on
    every trial. See DECISIONS.md (F6.A).
  * GetLatestSnapshot in find_live_overlap and epistemic_close_sys_time
    so the scan and the incumbent-fetch see the peer that committed
    while we waited on the advisory lock. Without this the "eviction
    could not fetch incumbent tuple" ERROR fires and RC integrity
    still leaks.
  * xmin (first-committer-wins) tiebreak in the tuple_insert path: on
    a (kind, specificity, confidence) tie the AM reads the incumbent's
    raw xmin from the HeapTupleHeader and compares against the current
    backend's xid via TransactionIdPrecedes. Under the F6 advisory
    lock the incumbent is committed before we see it, so its xmin
    logically precedes our xid on every race and the incumbent keeps
    the slot. scripts/hash_grind.sh flips the tiebreak off, rebuilds,
    and an attacker with SELECT+INSERT immediately displaces the
    incumbent on the first content grind attempt. Under the honest
    build the attacker wins 0 of 20000 grind attempts. See DECISIONS.md
    (F8).

Everything else in the wrapper — WAL annotation, audit, sys_time
close — is either delegated to heap for durability or exists for
downstream consumers. It is not what the bypass claim rides on.


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
that sql/am_eviction.sql asserts holds under READ COMMITTED and
SERIALIZABLE with concurrent same-slot writers, as of F6.

Under READ COMMITTED, the per-slot advisory xact lock taken in
epistemic_tuple_insert_impl serialises the writers on their shared
(entity_id, hash_bytes(attribute)) tag; the loser's find_live_overlap
runs against GetLatestSnapshot so it sees the winner's just-committed
row. scripts/rc_invariant.sh runs 50 trials and reports both=0,
aborted=0, exactly one live row per trial. With the advisory lock
patched out, both=50 — the leak returns. See DECISIONS.md (F6.A).

On a true precedence tie (equal kind, specificity, confidence) the
survivor is decided by xmin (first-committer-wins), server-controlled
and not attacker-grindable. The AM reads the incumbent's raw xmin
via HeapTupleHeaderGetRawXmin (access/htup_details.h:322-326
REL_18_STABLE) and fetches the current backend's xid via
GetCurrentTransactionId (backend/access/transam/xact.c:454
REL_18_STABLE). TransactionIdPrecedes
(backend/access/transam/transam.c:279-292 REL_18_STABLE) handles
xid-wraparound. Under the advisory lock the incumbent is committed
before we scan it, so incumbent_xmin < new_xid on every race — the
incumbent wins. scripts/tie_determinism.sh runs 50 RC trials in each
of two commit orders: with s1 starting first, A_lo (s1) wins every
trial; with s2 starting first, Z_hi (s2) wins every trial. That
flip is first-committer-wins. With the tiebreak patched out the
survivor flips to last-writer-wins (s1first→Z_hi 50/50, s2first→A_lo
50/50). scripts/hash_grind.sh confirms an attacker with SELECT+INSERT
wins 0 of 20000 content-grind attempts under the honest build; with
the tiebreak patched out the attacker wins on the first attempt of
every trial. See DECISIONS.md (F8).

Caveat: xids are reassigned on pg_dump / pg_restore (restore reloads
rows via COPY FROM at src/backend/commands/copyfrom.c:1427 REL_18_STABLE,
which calls table_tuple_insert → heap_insert →
GetCurrentTransactionId). The specific survivor of a historical tie
is NOT stable across dump/restore. What IS stable is the
"exactly one live row per slot" invariant that sql/am_eviction.sql
asserts.

Under SERIALIZABLE the advisory lock still serialises the writers,
and one of them additionally hits the SIRead relation lock inherited
from heapam's seqscan or the F8 xmin-tiebreak's NEW_LOSES on
identical-prefix rows. scripts/concurrency.sh confirms one aborted
session per race (native>=1, trigger>=1), where an "abort" is
either 40001 (SSI) or NEW_LOSES (AM precedence tiebreak) — both are
loss-of-write signals. The paper's actual differentiator is bypass
survival, exercised in scripts/bypass.sh.

Batch-size ceiling. The advisory lock is per-row (taken inside
per-row tuple_insert) and lives in the per-transaction fastpath lock
table (backend/storage/lmgr/lock.c). At the PG default
`max_locks_per_transaction = 64`, a single transaction that inserts
into ~15,000 distinct slots hits `ERROR 53200: out of shared memory`
with the hint to raise `max_locks_per_transaction`. Scales linearly
with the GUC. Larger batches require operators to raise the setting.
This is an accepted design tradeoff (T1-a in DECISIONS.md F8); the
F7 characterization scripts (`scripts/lock_exhaustion.sh`,
`lock_exhaustion_scan.sh`, `lock_exhaustion_deep.sh`,
`lock_exhaustion_linearity.sh`) document the threshold and its
linearity.

F18 update. COPY FROM inherits the same ceiling. The AM's
multi_insert override iterates over the batched slots and calls the
per-slot tuple_insert enforcement path — so each COPY-batched row
takes one advisory lock, and a COPY of N distinct-slot rows
accumulates N locks in one transaction just like an INSERT of the
same N rows. scripts/bypass.sh sweeps N ∈ {100, 1000, 10000, 20000}
via real \copy at max_locks_per_transaction=64 and asserts the first
three land while 20000 hits the same 53200 error at lock.c:1080
LockAcquireExtended. This is the same ceiling F7 documented under
INSERT, not a new one; we do NOT drop the advisory lock in the
multi_insert path (doing so would silently re-open the RC integrity
leak F6 closed). See DECISIONS.md (F18).

The advisory lock is per-row, so two multi-row INSERT statements that
touch two slots in opposite orders can deadlock on the advisory
locks. PG's built-in deadlock detector (deadlock.c) resolves within
`deadlock_timeout = 1s`. scripts/deadlock_detection.sh stages 20
deadlock races and confirms 20/20 resolve with SQLSTATE 40P01, 0
hangs. See DECISIONS.md (F6.C).


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
write-path threat, and is out of scope.

Enumerated write-path bypass surfaces (all verified against
REL_18_STABLE):

  1. ALTER TABLE ... DISABLE TRIGGER ALL — BLOCKED (F2).
     Flips pg_trigger.tgenabled to 'D' at
     src/backend/commands/tablecmds.c:5588-5592; TriggerEnabled
     at src/backend/commands/trigger.c:3491-3499 then returns
     false. Trigger-based enforcement is bypassable; the AM's
     tuple_insert callback is not.

  2. SET session_replication_role = 'replica' — BLOCKED (F2).
     TriggerEnabled at src/backend/commands/trigger.c:3489-3499
     skips TRIGGER_FIRES_ON_ORIGIN and TRIGGER_DISABLED under
     SESSION_REPLICATION_ROLE_REPLICA. The GUC is PGC_SUSET
     (src/backend/utils/misc/guc_tables.c:5166). Again the
     trigger is bypassable, the AM callback is not.

  3. COPY FROM (CIM_MULTI batch path) — BLOCKED (F18).
     CopyFrom at src/backend/commands/copyfrom.c:995-1006 sets
     insertMethod = CIM_MULTI when the target has no
     BEFORE/INSTEAD OF INSERT trigger; batched rows then flow
     through table_multi_insert at copyfrom.c:554-559, which
     dispatches on the AM's `multi_insert` callback
     (src/include/access/tableam.h:527-529). Before F18 this
     inherited heap_multi_insert (heapam_handler.c:2641) and
     silently skipped R1..R5, the per-slot advisory lock,
     precedence, eviction, and the rmgr-128 annotation record.
     F18 overrides multi_insert to iterate over slots[] and
     invoke epistemic_tuple_insert_impl per row, closing this
     write path with byte-for-byte identical semantics to
     single-row INSERT. Tradeoff: COPY throughput drops to
     INSERT-loop speed (per-row heap_insert, per-row WAL
     record, per-row advisory lock). See DECISIONS.md (F18).

  4. COPY FROM (CIM_SINGLE path) — ALREADY BLOCKED (pre-F18).
     Same CopyFrom logic at copyfrom.c:995-1006 forces
     CIM_SINGLE when the target has a BEFORE/INSTEAD OF INSERT
     trigger, or an FDW that doesn't batch, or partitioned
     tables with statement-level triggers, or volatile default
     expressions. The single-row path at copyfrom.c:1427 calls
     table_tuple_insert, which routes through the AM's
     tuple_insert override.

  5. INSERT ... SELECT / INSERT ... VALUES — BLOCKED.
     Standard ModifyTable path lands in ExecInsert
     (src/backend/executor/nodeModifyTable.c) which calls
     table_tuple_insert. The tuple_insert override runs.

  6. ALTER TABLE ... SET ACCESS METHOD heap — OUT OF SCOPE.
     Table-owner-only, schema-change threat. Rewrites the
     relation onto plain heap; at that point every subsequent
     write bypasses the AM callback because the callback is
     no longer bound to the relation. Documented as a
     schema-change threat, not a write-path threat.

  7. Logical replication apply worker — OUT OF SCOPE for the
     bypass claim; the apply worker runs as SESSION_REPLICATION_ROLE
     _REPLICA by default (see src/backend/replication/logical/worker.c)
     and reaches the AM's tuple_insert / multi_insert via
     ExecSimpleRelationInsert -> ExecInsert -> table_tuple_insert,
     so the enforcement path fires. Documented for completeness;
     no dedicated test.

The core standing rule: an AM callback runs from inside heapam and
no user-space GUC or ALTER TABLE reaches it. That covers every
write path listed above except SET ACCESS METHOD heap (schema
change) and logical replication apply (which routes through the
callback anyway).


Build / test / run
------------------

Assumes pg_config on PATH resolves to a PG 18 install with headers.

    make
    make install
    make installcheck                              # 6 regression suites
    PROVE_TESTS='t/*.pl' make prove_installcheck   # TAP (empty today)
    make check-e2e                                 # 8 e2e scripts

The extension requires shared_preload_libraries = 'epistemic' so the
custom rmgr is registered before recovery. The e2e scripts and TAP
harness set this automatically on their isolated clusters. For
manual installcheck against a pre-existing cluster, add it to
postgresql.conf and restart.

check-e2e runs, on isolated clusters spun up in /tmp:

    scripts/recovery.sh            crash + recovery, 110 rows round-trip
    scripts/concurrency.sh         fair SSI check on native and trigger
    scripts/bypass.sh              trigger-disable + replica-role +
                                   COPY-FROM bypasses (F2 + F18); also
                                   F7-interaction batch-size sweep
                                   under COPY (100/1k/10k/20k)
    scripts/crash_atomicity.sh     25 trials, eviction atomicity
    scripts/tie_concurrency.sh     50 trials each at RC and SR, tie probe
                                   (historical F4 baseline; post-F6
                                    reports RC/SR both=0 rule=50)
    scripts/rc_invariant.sh        F6: advisory lock closes RC leak
    scripts/tie_determinism.sh     F6: content hash breaks the tie
    scripts/deadlock_detection.sh  F6: deadlock detector resolves

Baseline counts after F18: installcheck 6/6, check-e2e 8/8 (bypass.sh
now runs 3 bypass scenarios and 1 batch-size interaction cell — all
inside the same script; script count is unchanged).


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
      epistemic_am.c           tuple_insert + multi_insert wrappers,
                               delegation to heapam
      epistemic_wal.c          rmgr callbacks + marker builder
      epistemic_type.c         epistemic_kind C I/O
      epistemic_rules.c        R1..R5 + precedence cmp
    sql/  expected/            6 regression suites
    scripts/                   8 end-to-end shell tests
    t/                         TAP harness (empty)
    epistemic--1.0.sql         extension SQL
    epistemic.control          extension control
    DECISIONS.md               F1..F18 engineering audits
