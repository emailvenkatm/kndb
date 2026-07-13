# Engineering decisions

Short notes recording load-bearing design choices and, where useful, the
audit that produced them. New entries go on top. Each entry is dated and
identifies the code paths involved.

## 2026-07-12, F8: xmin (first-committer-wins) tiebreak; accept batch ceiling

F7 landed two adversarial findings against F6.

  * T1 (batch-size ceiling). One transaction can insert ~15,000
    distinct-slot rows at the PG default `max_locks_per_transaction=64`
    before it trips ERRCODE_OUT_OF_MEMORY 53200 from LockAcquire's
    SetupLockInTable path (src/backend/storage/lmgr/lock.c:1076-1082
    REL_18_STABLE). The shared lock hashtable is sized by
    NLOCKENTS() = max_locks_per_xact * (MaxBackends + max_prepared_xacts)
    at lock.c:56-57 REL_18_STABLE. Each per-slot advisory xact lock
    consumes one entry; batch inserts accumulate them until COMMIT.
    scripts/lock_exhaustion.sh sweeps N and confirms the failure at
    N in the 14000-15000 range at the default GUC; scaling to
    `max_locks_per_transaction=1024` moves the ceiling to ~250k,
    linear as the formula predicts (scripts/lock_exhaustion_linearity.sh).
    The failure is a graceful ERROR, not a crash; both the transaction
    and the target relation remain consistent (no partial writes commit;
    the whole INSERT rolls back).

  * T2 (content-hash grindability). F6 broke true precedence ties by
    hash_bytes over content columns and let lower-hash win. hash_bytes
    (src/common/hashfn.h:23 REL_18_STABLE) is deterministic per build
    and observable by any role with SELECT on the target. An attacker
    with SELECT+INSERT grinds `value` bytes until it finds one whose
    hash beats the incumbent. scripts/hash_grind.sh (F7's original)
    reported 30/30 wins with a mean of ~15 attempts to first success —
    the mechanism was ornamental.

### T1-a decision (accepted, documented)

Accept the ~15k ceiling as a design tradeoff. The alternatives were
(T1-b) an EXCLUDE constraint via btree_gist, (T1-c) a switch to
per-slot advisory *session* locks (releases at end of session, not
end of transaction — orthogonal correctness issue), and (T1-d) drop
the advisory lock and re-open the RC leak. The user chose T1-a: the
lock table is what makes RC-safe eviction possible; multi-slot batches
that need higher throughput can raise `max_locks_per_transaction`
before running. README and the correctness envelope now name the
threshold and its linearity. Files: none touched; F7's characterization
scripts (scripts/lock_exhaustion.sh, lock_exhaustion_scan.sh,
lock_exhaustion_deep.sh, lock_exhaustion_linearity.sh) remain in
place unchanged.

### T2-a decision + implementation (swap to xmin)

Replaced the caller-side content-hash tiebreak in
`epistemic_tuple_insert_impl` with an xmin (first-committer-wins)
comparison. Mechanism:

  1. `find_live_overlap` now returns the incumbent's raw xmin via
     `HeapTupleHeaderGetRawXmin` (access/htup_details.h:322-326
     REL_18_STABLE) — a static inline that reads
     `t_choice.t_heap.t_xmin` from the scan slot's HeapTuple. We
     fetch the HeapTuple with `ExecFetchSlotHeapTuple(slot, false, &sf)`
     (executor/tuptable.h:343 REL_18_STABLE, materialize=false to
     avoid a copy).
  2. On a true (kind, specificity, confidence) tie, the caller reads
     the current backend's xid via `GetCurrentTransactionId`
     (src/backend/access/transam/xact.c:454 REL_18_STABLE) — assigns
     one if not yet set.
  3. Compares via `TransactionIdPrecedes`
     (src/backend/access/transam/transam.c:279-292 REL_18_STABLE),
     which handles xid-wraparound via a modulo-2^32 comparison for
     two normal xids and a straight unsigned comparison when either
     side is a permanent xid. If `incumbent_xmin < new_xid` (the
     normal case), the tie flips to `EP_CMP_NEW_LOSES` and
     `epistemic precedence: NEW_LOSES (reason=contradicted_same_rank)`
     rejects the incoming row.
  4. Defensive branch (incumbent_xmin follows or equals new_xid, or
     is invalid): keep NEW_WINS unchanged. Under the current design
     this branch is unreachable — the F6 advisory lock guarantees
     the incumbent is committed by the time `find_live_overlap`
     sees it, and its xmin was stamped by heap_insert
     (heapam.c:2288 HeapTupleHeaderSetXmin, called from heap_insert
     at heapam.c:2083 with `xid = GetCurrentTransactionId()`) at
     an earlier moment in time. Kept as an explicit no-op so a
     future refactor that inverts commit order does not silently
     flip the tie policy.
  5. Deleted `epistemic_content_hash` and its caller-side hash-compare
     block. Deleted the `found_value_out` output parameter of
     `find_live_overlap` and its caller-side plumbing (incumbent_value
     cstring is no longer read from the scan tuple).

Xids are reassigned on pg_dump / pg_restore. Restore loads data
via COPY FROM (src/backend/commands/copyfrom.c:1427 REL_18_STABLE),
which routes through `table_tuple_insert` → `heap_insert` →
`GetCurrentTransactionId`, stamping every reloaded row with a fresh
xid. So the specific survivor of a historical tie is NOT stable
across dump/restore. The invariant that IS stable is
"exactly one live row per slot" (sql/am_eviction.sql). Comment in
src/epistemic_am.c above the compare states this explicitly.

### Adversarial proofs

`scripts/tie_determinism.sh` (rewritten for F8 semantics; F6's
content-deterministic assertion no longer applies):

  MODE=honest, 50 trials × 2 orders:
    s1first: A_lo_wins=50 Z_hi_wins=0  both=0 rule_err=50
    s2first: A_lo_wins=0  Z_hi_wins=50 both=0 rule_err=50
    → first-committer-wins under both orders.

  MODE=broken (xmin tiebreak guard patched to `if (0)`):
    s1first: A_lo_wins=0  Z_hi_wins=50 both=0 rule_err=0
    s2first: A_lo_wins=50 Z_hi_wins=0  both=0 rule_err=0
    → last-writer-wins; the mechanism the xmin tiebreak reverses.

`scripts/hash_grind.sh` (rewritten to prove grind-resistance under
F8; F7's baseline transcript of 30/30 attacker wins under F6 stands
in the git history as the finding that motivated F8):

  MODE=honest:
    Step 2 numeric-suffix   : attacker wins 0/30
    Step 3 whitespace-suffix: attacker wins 0/30
    Step 4 distribution     : attacker wins 0/20000 across 100 trials
                              × 200 attempts each

  MODE=broken (same guard patched to `if (0)`):
    Step 2 numeric-suffix   : attacker wins 30/30 (first attempt each)
    Step 3 whitespace-suffix: attacker wins 30/30 (first attempt each)
    Step 4 distribution     : attacker wins 30/30 (first attempt each)

`scripts/rc_invariant.sh` unchanged post-swap:
    session1_wins=50 session2_wins=0 both_live=0 aborted_txn=0
    → the F6 advisory lock still closes the RC integrity leak; the
      xmin swap is orthogonal to it.

`scripts/concurrency.sh` no-op assertion tightened. Under F8 the
fair concurrency race between identical-prefix writers reaches the
tie branch and NEW_LOSES fires *before* SSI's rw-antidependency
check has anything to abort. NEW_LOSES is now counted as a
"session aborted" alongside 40001, since both are loss-of-write
signals to the rejected session. Native path: 1 abort (via
NEW_LOSES); trigger path: 1 abort (via 40001). Both engines still
survive the fair race with a single live row.

### What this changes semantically

F6's content-hash tiebreak was content-deterministic: whichever
`value` had the lower hash won the tie, regardless of commit order.
F8's xmin tiebreak is start-order-dependent: whichever session
committed first wins. Both are deterministic given a fixed workload.
The tradeoff is:

  * F6 gave up grind-resistance in exchange for content-determinism.
    An attacker who controls `value` could win any tie.
  * F8 gives up content-determinism (survivor differs by commit
    order and does not survive dump/restore) in exchange for
    grind-resistance (no attacker-controllable byte changes the
    outcome).

The user chose grind-resistance. Documented tradeoff.

### Files touched

  * src/epistemic_am.c
      - deleted `epistemic_content_hash` (helper, ~24 lines)
      - deleted `found_value_out` output parameter of
        `find_live_overlap`; replaced with `found_xmin_out`
        (TransactionId *). Populated via ExecFetchSlotHeapTuple +
        HeapTupleHeaderGetRawXmin.
      - replaced caller-side content-hash tiebreak with xmin
        comparison via `TransactionIdPrecedes(incumbent_xmin,
        GetCurrentTransactionId())`.
  * scripts/hash_grind.sh — rewritten. Baseline: 0 wins across
                            20000 grind attempts. Broken:
                            attacker wins first attempt every trial.
  * scripts/tie_determinism.sh — verdict text updated. Honest:
                                 first-committer-wins under each
                                 start order. Broken: last-writer-wins.
  * scripts/concurrency.sh — the "aborted session" grep now
                             recognises NEW_LOSES as well as 40001.
                             Under F8 the native path lands on
                             NEW_LOSES because the advisory lock
                             serialises the writers before SSI
                             has a chance to fire.
  * README.md — F8 correctness envelope: batch-size ceiling documented
                (T1-a), tie semantics documented (first-committer-wins
                via xmin, pg_restore caveat noted).

### Test suite

installcheck: 6/6 unchanged.
check-e2e:    8/8 (rc_invariant, tie_determinism, hash_grind under
                   F8 semantics; the other five unchanged).

## 2026-07-12, F6: per-slot advisory xact lock + content-hash tiebreak

F4 documented the RC integrity leak (concurrent same-slot writers both
commit, two live rows land) and the SR concurrent tie non-determinism
(SIRead pivot-abort picks a survivor by commit order, not content). F6
closes both edges of that envelope inside the AM's tuple_insert
callback. Two mechanisms, one design.

### A. Per-slot advisory xact lock

`epistemic_tuple_insert_impl` now takes a `LOCKTAG_ADVISORY` lock with
`(field1=MyDatabaseId, field2=entity_id, field3=hash_bytes(attribute),
field4=2)` between the R1..R5 rule check and the `find_live_overlap`
scan. Constructed inline via `SET_LOCKTAG_ADVISORY` (lock.h:271-277
REL_18_STABLE) + `LockAcquire(&tag, ExclusiveLock, false, false)`
(lock.h:555-558) — same tag/mode/scope as
`pg_advisory_xact_lock_int4(int4, int4)` at
src/backend/utils/adt/lockfuncs.c:826-837 REL_18_STABLE. Chose the
inline construction over `DirectFunctionCall2` to save one fmgr hop
and make the xact-scope explicit at the call site.

`find_live_overlap`'s snapshot changed from `GetActiveSnapshot()` to
`GetLatestSnapshot()` (snapmgr.c:353-376 REL_18_STABLE). Rationale:
after the advisory lock unblocks, the statement's active MVCC snapshot
was taken before the peer's COMMIT; only the refreshed
`SecondarySnapshot` sees the just-committed row. Same fix applied in
`epistemic_close_sys_time`'s `heap_fetch` — the incumbent's TID from
find_live_overlap must be resolvable under the same snapshot.

`scripts/rc_invariant.sh` runs 50 RC trials of two overlapping
same-slot writers.

  MODE=honest:
    session1_wins=50 session2_wins=0 both_live=0 aborted_txn=0

  MODE=broken (advisory-lock block patched to `if (0)`):
    session1_wins=0 session2_wins=0 both_live=50 aborted_txn=0

Both/50 in broken mode reproduces the pre-F6 RC leak exactly. The
advisory lock is load-bearing.

Collision caveat. The lock key is `(entity_id, hash_bytes(attribute))`,
a 64-bit tag with birthday-limited collisions at ~2^32 attribute
strings. A collision serialises two unrelated slots' writes; that is
a benign perf issue (correctness holds because `find_live_overlap`
still filters by full entity+attribute equality), not a correctness
bug. In practice `attribute` is a small controlled vocabulary and
collisions are rare.

### B. Content-hash tiebreak on true precedence tie

`epistemic_precedence_cmp` still returns
`NEW_WINS/CONTRADICTED_SAME_RANK` on `(kind, specificity, confidence)`
equality — that keeps the pure function testable in isolation
(sql/precedence.sql). `epistemic_tuple_insert_impl` now detects that
specific outcome and computes `hash_bytes` (common/hashfn.h:23
REL_18_STABLE) over a length-prefixed serialisation of
`(entity_id, attribute, value, valid_lower_secs, valid_upper_secs)`
for both incumbent and new row. Lower hash wins; higher hash flips
`cmp.outcome` to `NEW_LOSES` and the row is refused with the
existing `epistemic precedence: NEW_LOSES` error. On a perfect
32-bit collision on different content (birthday-limited at ~2^16
same-slot writes), the fallback is the pre-F6 `NEW_WINS` — not a
correctness violation for the "at most one live row per slot"
invariant, only a deterministic-choice-of-survivor gap at that
probability.

`scripts/tie_determinism.sh` runs 50 RC trials each in two orderings
(session1 starts first, then session2 starts first) with rows
identical on `(kind, specificity, confidence)` but differing on
`value` ("A_lo" vs "Z_hi").

  MODE=honest:
    s1first: A=0  Z=50 both=0
    s2first: A=0  Z=50 both=0
    -> content-deterministic: same value wins under both orders.

  MODE=broken (tiebreak guard patched to `if (0)`):
    s1first: A=0  Z=50 both=0
    s2first: A=50 Z=0  both=0
    -> commit-order-dependent: second-to-arrive wins.

That before/after asymmetry is the load-bearing proof. The specific
value that wins is content-hash-determined, not chosen; here it
happens to be Z_hi because `hash_bytes(...Z_hi...) <
hash_bytes(...A_lo...)`. hash_bytes has no ordering guarantee across
PG versions, but for a given build the winner is stable.

### C. Deadlock story

The advisory lock is per-row (taken inside per-row `tuple_insert`). A
multi-row INSERT that touches slots (X, Y) in one session and (Y, X)
in a concurrent session can deadlock on the advisory locks: sess1
holds lock(X) and waits on lock(Y); sess2 holds lock(Y) and waits on
lock(X).

Chose (b): accept the deadlock possibility, rely on PG's built-in
deadlock detector at src/backend/storage/lmgr/deadlock.c
(DeadLockCheck, called from lock manager after `deadlock_timeout`).
Rationale: (a) sorted `multi_insert` helps only bulk paths sharing a
BulkInsertState; the per-statement race across sessions still
deadlocks. (b) the detector already exists and is one of PG's
best-tested subsystems.

`scripts/deadlock_detection.sh` runs 20 trials with
`deadlock_timeout = 1s` and a 15s wall-clock cap per trial. Result:
20/20 trials resolved with exactly one session aborted (SQLSTATE
40P01, `deadlock detected`); 0 hangs. The lock detector is
load-bearing here.

### Test suite

installcheck: 6/6 (unchanged).
check-e2e:    8/8 (added rc_invariant.sh, tie_determinism.sh,
              deadlock_detection.sh; kept tie_concurrency.sh as the
              historical F4 baseline — its post-F6 numbers now read
              `RC s1=50 both=0 abort=0 rule=50` and
              `SR s1=50 both=0 abort=0 rule=50`, which is precisely
              the RC-leak-closed / SR-content-deterministic outcome).

### Files touched

  * src/epistemic_am.c
      - added advisory-lock block after rule check (`if (have_key)`
        branch)
      - `find_live_overlap`: `GetActiveSnapshot()` -> `GetLatestSnapshot()`,
        added `found_value_out` output parameter
      - `epistemic_close_sys_time`: `GetActiveSnapshot()` ->
        `GetLatestSnapshot()` for the heap_fetch
      - added `epistemic_content_hash` and the NEW_WINS+CONTRADICTED
        tiebreak block in `epistemic_tuple_insert_impl`
      - new headers: common/hashfn.h, miscadmin.h, storage/lmgr.h,
        storage/lock.h
  * scripts/rc_invariant.sh          new
  * scripts/tie_determinism.sh       new
  * scripts/deadlock_detection.sh    new
  * Makefile                          new check-e2e-rc / check-e2e-det /
                                      check-e2e-dl targets; aggregate
                                      runs 8 scripts

## 2026-07-12, F4: eviction atomicity is PG's, tie survival is order-dependent

Two audits. Neither finds an epistemic-specific mechanism; both name
what the AM actually contributes and what it inherits from PG 18.

### A. Eviction atomicity

The eviction path in `epistemic_tuple_insert_impl` does three state
changes when a new fact evicts an incumbent:

  1. `heap_insert` of the winner (epistemic_am.c:362)
  2. SPI `INSERT INTO epistemic.evicted_fact` (epistemic_am.c:378,
     via `epistemic_audit_evicted`)
  3. `simple_heap_update` closing the incumbent's `sys_time` upper
     bound (epistemic_am.c:379, via `epistemic_close_sys_time`)

All three run inside a single top-level PG transaction. That
transaction is not created by the AM — it is created by
`start_xact_command` at src/backend/tcop/postgres.c:2787-2794
REL_18_STABLE, which `exec_simple_query` calls at postgres.c:1046
before parsing the statement and again at postgres.c:1349 via
`finish_xact_command` (postgres.c:2825-2848) after the parsetree
loop finishes. In the default-block arm at xact.c:3069-3072,
`StartTransactionCommand` calls `StartTransaction()`. So a single
top-level INSERT is one transaction; the AM's three heap changes are
one atomic unit as a side effect. The AM does not open, commit, or
manage any transaction.

`scripts/crash_atomicity.sh` runs 25 trials on a fresh cluster with
`fsync=on`, `synchronous_commit=on`, `wal_consistency_checking=all`.
Each trial: reset state, insert one INFERRED incumbent, CHECKPOINT,
fire ${EVICTIONS_PER_TRIAL}=400 per-row MEASURED inserts (each one
evicts the current winner) as a background psql, race a
`pg_ctl stop -m immediate` after 20ms, restart, count
`(live, audit, closed)` for `(entity=7, attribute='bp')`. Tuned
delay catches every trial mid-batch. Result:

  trial  live audit closed total verdict
  1      1    228   228    229   OK
  2      1    190   190    191   OK
  ...
  10     1    80    80     81    OK
  ...
  25     1    197   197    198   OK
  ---
  invariant_violations: 0/25

Every trial: exactly one live row, `audit == closed`, and
`live + closed == audit + 1` (the +1 is the current live winner
that has not itself been evicted). Never `live=0` (incumbent lost
without a replacement), never `live=2` (winner AND incumbent both
live), never `audit != closed` (audit and evicted-tuple diverged).

Adversarial control. `scripts/crash_atomicity_broken.sh` installs a
BEFORE INSERT trigger on `epistemic.evicted_fact` that opens a
dblink connection to the same DB and executes a shadow INSERT into
`epistemic.evicted_fact_shadow`. `dblink_exec` runs on a fresh
backend with its own top-level transaction which commits on
function return, so shadow rows are durable as soon as the trigger
returns — independent of the outer statement's commit. Same 25-trial
race:

  trial  live audit_shadow closed audit_real verdict
  1      1    9            9      9          OK
  2      1    11           10     10         VIOLATION_shadow!=closed(11!=10)
  3      1    8            8      8          OK
  ...
  ---
  invariant_violations: 1/25

Trial 2: 11 shadow audit rows are durable on the dblink side, but only
10 evictions were committed in the main-txn table. One shadow audit
row is now an orphan — the main-txn eviction it recorded was
discarded when redo tossed the un-COMMIT-flushed final statement.
`crash_atomicity_broken.sh` typically produces 1-2 violations per 25
trials because the crash has to land in the microsecond window between
the trigger's dblink commit and the outer statement's WAL flush; the
narrow window is exactly why atomicity holds when the audit is inside
the main txn instead of outside it.

Reservation. The invariant we assert here is a bitemporal live-slot
invariant. The AM is not a schema of arbitrary user constraints; a
different invariant (e.g., "audit row's timestamp matches winner's
sys_time.lower") would require different tests. The scope of this
audit is: does the crash test flag any state that the AM produces
but that recovery leaves torn? Answer: no, and the negative control
proves the test can catch a torn state when one exists.

Attribution. Atomicity of the three-step eviction is PG's. The AM's
contribution is that it does the three steps INSIDE the tuple_insert
callback, so a user cannot forget to wrap them. That is a
convenience claim, not a novel durability claim. README and paper
draft phrased accordingly.

### B. Precedence tie under concurrency

`epistemic_precedence_cmp` at src/epistemic_rules.c:401-407 handles
the same-rank/same-specificity/same-confidence case by returning
`EP_CMP_NEW_WINS` with reason `EP_REASON_CONTRADICTED_SAME_RANK`. On
the serial path this is arrival-order-wins: a second identical
insert AFTER the first commits will succeed and evict the first
(confirmed at sql/precedence.sql:24 and again in the invert probe
below).

`scripts/tie_concurrency.sh` runs 50 trials each under READ
COMMITTED and SERIALIZABLE with two sessions inserting overlapping
rows carrying IDENTICAL (kind, specificity, confidence) for
`(entity_id=1, attribute='bp')`. Only `value` differs so we can name
the survivor.

  ISO=READ COMMITTED s1=0 s2=0 both=50 none=0 abort=0 rule=0
  ISO=SERIALIZABLE   s1=50 s2=0 both=0 none=0 abort=50 rule=0

Under READ COMMITTED all 50 trials leave TWO live rows in the slot.
Each session's `find_live_overlap` seqscan uses its own MVCC
snapshot and cannot see the other session's uncommitted insert; both
sessions think they are the first writer; neither hits the tie code.
That is an integrity failure and it is NOT resolved by the epistemic
rules — the sql/am_eviction.sql invariant "one live row per
(entity_id, attribute) slot" only holds under SERIALIZABLE or
stricter, and only on a serial-arrival path within a session.

Under SERIALIZABLE, session1 (started first) wins all 50 trials;
session2 aborts with SQLSTATE 40001 in all 50. The mechanism is
heap_insert calling `CheckForSerializableConflictIn` at
src/backend/access/heap/heapam.c:2127 REL_18_STABLE, which consults
predicate locks acquired by the other session's seqscan
(relation-level, via `PredicateLockRelation`). `predicate.c:4336-
4389` (REL_18_STABLE) shows the granularity-promoted lock check.
The tie branch is STILL not reached: session2 aborts before its
heap_insert even calls back into the precedence code.

Adversarial control. `scripts/tie_concurrency_invert.sh` patches
`epistemic_rules.c` in place to flip the tie branch to
`EP_CMP_NEW_LOSES`, rebuilds, installs, runs the sequential probe,
and restores the source. Under the patched build a second identical
INSERT in the same session raises:

  ERROR:  epistemic precedence: NEW_LOSES (reason=contradicted_same_rank)

and the first row is the sole survivor. That proves the tie branch
in the honest build is load-bearing on the serial path — the current
"NEW_WINS on tie" is a deliberate policy, not an artifact. The
patched build's concurrent behavior is IDENTICAL to the honest
build's (session1 wins, session2 40001s), confirming that under
concurrency the tie policy is not what determines the outcome.

Findings, plainly:

  * Tie policy in the AM is arrival-order-wins on the serial path
    (later same-prefix insert supersedes earlier). This is
    deterministic given a fixed arrival order.
  * Under concurrent inserts with identical prefix, the tie branch
    is unreachable. Outcome is decided by isolation-level plumbing:
      - READ COMMITTED: both writes commit, integrity is violated.
      - SERIALIZABLE:   one writer aborts under SSI; survivor is
                        whichever transaction PG did not choose to
                        pivot-abort — commit-order-dependent, not
                        content-dependent.
  * There is no content-deterministic concurrent tie resolution.
    The paper draft's phrasing has been updated to say exactly
    that. If deterministic concurrent tie resolution becomes a
    load-bearing claim, the fix is either (a) an in-AM total order
    on ties (e.g., lower `ctid` wins, or a hashed
    `(entity_id, attribute, xmin, value)` comparator), or (b)
    reject-both on tie (the invert-branch policy), which is
    content-deterministic but drops one write.

Attribution. The AM contributes the serial tie policy (which is
exercised in single-session insert streams). Concurrent tie
resolution is PG's — SSI abort under SERIALIZABLE, no protection
under READ COMMITTED. Neither is unique to the epistemic PoC.

### Files touched

  * scripts/crash_atomicity.sh          — new, honest crash test
  * scripts/crash_atomicity_broken.sh   — new, dblink-based
                                          adversarial control
  * scripts/tie_concurrency.sh          — new, concurrent tie probe
  * scripts/tie_concurrency_invert.sh   — new, adversarial rebuild
                                          probe
  * Makefile                            — new check-e2e-crash,
                                          check-e2e-tie targets;
                                          check-e2e aggregates now
                                          runs all five e2e scripts

installcheck: 6/6 pass unchanged.

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
