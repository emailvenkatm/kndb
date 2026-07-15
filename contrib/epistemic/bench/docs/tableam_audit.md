# Exhaustive PG 18 REL_18_STABLE TableAmRoutine audit

**Cited from:** `paper-pvldb/main.tex`, Table 2 (§3.9 Exhaustive TAM audit).
The paper's in-body table (`paper-pvldb/figures/tableam_audit.tex`) is an
abbreviated 10-row summary; this file carries the full 42-callback
enumeration and is the completeness argument the paper cites.

Every callback in `src/include/access/tableam.h` (PG 18 REL_18_STABLE) is
classified as one of:

- **OVERRIDDEN** (7 after F21): our AM binds a wrapper.
- **READ-ONLY**: callback is a scan/fetch/estimate that cannot mutate
  epistemic state.
- **DELEGATED-STORAGE**: heap's semantics accepted; the AM does not
  introduce policy at this level, but any subsequent mutating path
  routes through our overridden write callbacks (e.g., rewrite path
  repopulates via `tuple_insert`).
- **DELEGATED-DECIDE**: heap decides on our behalf and we accept the
  answer (e.g., TOAST configuration).

Line numbers reference PG 18 REL_18_STABLE
`src/include/access/tableam.h`. Every "why" is checked against the
named citation in the source tree at
<https://git.postgresql.org/gitweb/?p=postgresql.git;a=blob;f=src/include/access/tableam.h;hb=REL_18_STABLE>.

See `contrib/epistemic/DECISIONS.md` (F9, F18, F20, F21) for the
classification methodology and the disable-and-test proofs behind the
seven OVERRIDDEN rows.

## Category counts (paper-cited)

| Class              | Count |
|--------------------|-------|
| OVERRIDDEN         | 7     |
| READ-ONLY          | 28    |
| DELEGATED-STORAGE  | 8     |
| DELEGATED-DECIDE   | 1     |
| **Total**          | **44** |

## Full enumeration

### Slot callbacks

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `slot_callbacks` | read-only | 302 | Returns the `TupleTableSlotOps` for tuples of this AM. Pure factory; no state mutation. |

### Table scan callbacks

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `scan_begin` | read-only | 326-330 | Starts a read-only scan with a snapshot. No mutation path. |
| `scan_end` | read-only | 336 | Releases scan resources. No mutation. |
| `scan_rescan` | read-only | 342-344 | Restarts scan with new params. No mutation. |
| `scan_getnextslot` | read-only | 349-351 | Returns next tuple into slot. No mutation. |
| `scan_set_tidrange` | read-only | 370-372 | Sets bounds for a TID-range scan. No mutation. |
| `scan_getnextslot_tidrange` | read-only | 378-380 | TID-range variant of `scan_getnextslot`. No mutation. |

### Parallel scan

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `parallelscan_estimate` | read-only | 391 | Sizes shared-mem DSM. No mutation. |
| `parallelscan_initialize` | read-only | 398-399 | Initialises a `ParallelTableScanDesc`. No user-visible state. |
| `parallelscan_reinitialize` | read-only | 405-406 | Re-initialises the DSM for a new scan. No mutation. |

### Index scan

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `index_fetch_begin` | read-only | 422 | Opens an index-scan fetch state. No mutation. |
| `index_fetch_reset` | read-only | 428 | Resets between index scans. No mutation. |
| `index_fetch_end` | read-only | 433 | Releases index-scan state. No mutation. |
| `index_fetch_tuple` | read-only | 455-459 | Fetches by TID after visibility test. No mutation. |

### Non-modifying tuple ops

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `tuple_fetch_row_version` | read-only | 472-475 | Fetches a tuple version. No mutation. |
| `tuple_tid_valid` | read-only | 480-481 | Predicate on tid. No mutation. |
| `tuple_get_latest_tid` | read-only | 487-488 | Walks the update chain to the newest visible tid. Reads only. |
| `tuple_satisfies_snapshot` | read-only | 494-496 | Visibility test. No mutation. |
| `index_delete_tuples` | delegated-storage | 499-500 | Bottom-up index-delete driver. In heap's implementation, no user-visible tuples are removed; dead line pointers are reclaimed. Our epistemic invariants live in *live* rows (`sys_time @> now()`); dead-line-pointer reclamation cannot affect them. |

### Mutating tuple ops

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `tuple_insert` | **OVERRIDDEN** | 508-511 | F1-F16: R1-R5, F6 advisory lock, precedence + F8 xmin tiebreak, eviction audit, sys_time close, rmgr-128 marker. |
| `tuple_insert_speculative` | **OVERRIDDEN** | 513-519 | **F21**: R1-R5, advisory lock, precedence; heap does the speculative write; deferred eviction stashed for confirm. |
| `tuple_complete_speculative` | **OVERRIDDEN** | 521-525 | **F21**: on succeeded=true, drain the pending eviction (audit + sys_time close + rmgr-128); on succeeded=false, discard. |
| `multi_insert` | **OVERRIDDEN** | 527-529 | F18: fan out to `epistemic_tuple_insert_impl` per slot; closes the COPY CIM_MULTI bypass F9 identified. |
| `tuple_delete` | **OVERRIDDEN** | 531-539 | F20: refuse `DELETE` outright with `ERRCODE_FEATURE_NOT_SUPPORTED`. |
| `tuple_update` | **OVERRIDDEN** | 541-551 | F20: refuse any `UPDATE` whose new `(ep_kind, ep_specificity, ep_confidence)` differs from the incumbent's. |
| `tuple_lock` | delegated-storage | 553-562 | Row-level lock acquisition (`SELECT FOR UPDATE`, replica-apply conflict resolution). Sets `xmax` to lock the tuple but does not mutate user columns; any subsequent modification routes back through `tuple_update` or `tuple_delete`, both overridden. |
| `finish_bulk_insert` | delegated-storage | 576 | Optional per-bulk-insert flush. In-tree AMs no longer use it; heap's binding is `NULL` (`heapam_handler.c:2661`). Any prior mutation went through `tuple_insert` or `multi_insert`. |

### DDL

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `relation_set_new_filelocator` | delegated-storage | 600-604 | Allocates a new physical file for TRUNCATE/CLUSTER/REINDEX-style rewrites (`heapam_handler.c:583-622`: `RelationCreateStorage` + optional init-fork). Storage is empty on return; any subsequent rewrite repopulates via `tuple_insert` or `multi_insert`. |
| `relation_nontransactional_truncate` | delegated-storage | 614 | Truncates the file to zero size (heap: `RelationTruncate`, no WAL). Removes all rows including epistemic incumbents. This IS a policy-relevant bypass surface for the eviction audit — but it is `TRUNCATE` DDL, guarded by `TRUNCATE` privilege, and out of scope for the write-path threat (paper §2.3). Flagged as a schema-change bypass alongside `ALTER TABLE ... SET ACCESS METHOD heap` (paper §9). |
| `relation_copy_data` | delegated-storage | 622-623 | Copies the physical file to a new tablespace (`ALTER TABLE ... SET TABLESPACE`). Rows are copied byte-for-byte; no epistemic-level policy applies. |
| `relation_copy_for_cluster` | delegated-storage | 626-635 | Copies rows during `CLUSTER` / `VACUUM FULL`. Heap re-inserts via `raw_heap_insert`, not `table_tuple_insert`, so the epistemic checks do NOT re-fire during the rewrite. Accepted because CLUSTER/VACUUM FULL is a DDL-privileged operation that preserves the current visible rows; **it cannot introduce a forgery, only reorder existing rows.** Flagged as an in-scope limitation on par with the schema-change threat. |
| `relation_vacuum` | delegated-storage | 652-654 | Standard VACUUM (dead-tuple reclamation, freeze). Cannot resurrect a dead row or invent a live one; the "live row per slot" invariant is preserved. |
| `scan_analyze_next_block` | read-only | 673-674 | ANALYZE block sampling. Read-only. |
| `scan_analyze_next_tuple` | read-only | 684-688 | ANALYZE tuple sampling. Read-only. |
| `index_build_range_scan` | read-only | 691-701 | Feeds tuples to `IndexBuildCallback` during index build. Read-only from the AM's perspective; the index AM writes to its own relation. |
| `index_validate_scan` | read-only | 704-708 | Concurrent-index-build validation phase. Read-only against the table. |

### Misc

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `relation_size` | read-only | 724 | Returns bytes for a fork. Pure metadata. |
| `relation_needs_toast_table` | delegated-decide | 734 | Heap's decision, whether a TOAST table is needed. We accept it. |
| `relation_toast_am` | **OVERRIDDEN** | 741 | Return `HEAP_TABLE_AM_OID` so the TOAST table is plain heap; otherwise PG's index build for the TOAST table trips `heap_getnext`'s `rd_tableam == GetHeapamTableAmRoutine()` identity check (`heapam.c:1352`). |
| `relation_fetch_toast_slice` | read-only | 748-752 | Fetches a slice of a TOAST'd value. Read-only. |

### Planner

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `relation_estimate_size` | read-only | 770-772 | Row-count / page-count estimate for the planner. Pure. |

### Executor

| Callback | Class | tableam.h | Why safe / role |
|----------|-------|-----------|-----------------|
| `scan_bitmap_next_tuple` | read-only | 792-796 | Fetch next visible tuple from a bitmap scan. Read-only. |
| `scan_sample_next_block` | read-only | 823-824 | Sample-scan block selection. Read-only. |
| `scan_sample_next_tuple` | read-only | 839-841 | Sample-scan tuple selection. Read-only. |

## Load-bearing nuances (paper §3.9 and §9)

Two rows above encode nuances the paper explicitly flags for reviewers:

1. **`relation_copy_for_cluster` cannot introduce forgery, only reorders.**
   Heap's `raw_heap_insert` skips `table_tuple_insert`, so the epistemic
   checks do not re-fire during CLUSTER/VACUUM FULL. This is DDL-privileged
   and preserves the current visible rows; it is not a write-path threat.
2. **`relation_nontransactional_truncate`** is a DDL-privileged bypass of
   the eviction audit, flagged alongside `SET ACCESS METHOD heap` in the
   schema-change threat category.
