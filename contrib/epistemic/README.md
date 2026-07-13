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
    make check-e2e                                 # 8 e2e scripts

The extension requires shared_preload_libraries = 'epistemic' so the
custom rmgr is registered before recovery. The e2e scripts and TAP
harness set this automatically on their isolated clusters. For
manual installcheck against a pre-existing cluster, add it to
postgresql.conf and restart.

check-e2e runs, on isolated clusters spun up in /tmp:

    scripts/recovery.sh            crash + recovery, 110 rows round-trip
    scripts/concurrency.sh         fair SSI check on native and trigger
    scripts/bypass.sh              trigger-disable + replica-role bypass
    scripts/crash_atomicity.sh     25 trials, eviction atomicity
    scripts/tie_concurrency.sh     50 trials each at RC and SR, tie probe
                                   (historical F4 baseline; post-F6
                                    reports RC/SR both=0 rule=50)
    scripts/rc_invariant.sh        F6: advisory lock closes RC leak
    scripts/tie_determinism.sh     F6: content hash breaks the tie
    scripts/deadlock_detection.sh  F6: deadlock detector resolves

Baseline counts after F6: installcheck 6/6, check-e2e 8/8.


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
    scripts/                   8 end-to-end shell tests
    t/                         TAP harness (empty)
    epistemic--1.0.sql         extension SQL
    epistemic.control          extension control
    DECISIONS.md               F1..F8 engineering audits
