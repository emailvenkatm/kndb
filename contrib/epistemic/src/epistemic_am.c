/*
 * epistemic_am.c
 *
 * Table access method handler. Copies heapam's TableAmRoutine at first
 * handler call and overrides three entries:
 *
 *   tuple_insert       -> epistemic_tuple_insert_impl (this file)
 *   multi_insert       -> epistemic_multi_insert       (this file, F18)
 *   relation_toast_am  -> epistemic_relation_toast_am_impl
 *
 * Every other callback (~37 of them: scan, index-fetch, tuple_update,
 * tuple_delete, tuple_lock, vacuum_rel, relation_size, freeze_lp,
 * TOAST helpers, parallel scan, sampling, ...) is heap's. Rows on
 * disk are plain heap tuples.
 *
 * The multi_insert override is the F18 fix for F9's COPY bypass. PG 18's
 * CopyFrom (copyfrom.c:554-559 REL_18_STABLE) routes CIM_MULTI batches
 * through table_multi_insert, which dispatches on the AM's `multi_insert`
 * callback. Without the override, CopyFrom would call heap_multi_insert
 * directly and skip every enforcement step. See the epistemic_multi_insert
 * comment block for the tradeoff analysis.
 *
 * tuple_insert_impl runs four steps in order and then delegates:
 *   1. R1..R5 rule check              (epistemic_check_rules)
 *   2. overlap probe on the same slot (find_live_overlap: seqscan)
 *   3. precedence lattice cmp         (epistemic_precedence_cmp)
 *   4. heap_insert of the winner      (heapam->tuple_insert)
 *   5. post-insert eviction bookkeeping if the incumbent lost:
 *      audit row into epistemic.evicted_fact (SPI),
 *      close incumbent's sys_time upper bound (simple_heap_update)
 *   6. annotation record on rmgr 128 (see epistemic_wal.c)
 *
 * SSI is heap's. find_live_overlap opens a seqscan through
 * heap_beginscan -> PredicateLockRelation, and heap_insert itself
 * calls CheckForSerializableConflictIn. The AM adds no lock target
 * of its own. See DECISIONS.md (F1 audit).
 *
 * User schema contract enforced in epistemic_rules.c:
 *   1  entity_id     int4
 *   2  attribute     text
 *   3  value         text
 *   4  sources       array or bytea
 *   5  valid_time    tstzrange
 *   6  sys_time      tstzrange DEFAULT tstzrange(now(), 'infinity')
 *   7  ep_kind       epistemic.epistemic_kind
 *   8  ep_specificity int2
 *   9  ep_confidence float4
 */
#include "postgres.h"
#include "fmgr.h"

#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/relscan.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_type.h"
#include "common/hashfn.h"
#include "executor/spi.h"
#include "executor/tuptable.h"
#include "miscadmin.h"
#include "nodes/nodes.h"
#include "storage/bufmgr.h"
#include "storage/itemptr.h"
#include "storage/lmgr.h"
#include "storage/lock.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/rangetypes.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include "utils/typcache.h"

#include "epistemic.h"
#include "epistemic_am.h"
#include "epistemic_precedence.h"
#include "epistemic_rules.h"
#include "epistemic_wal.h"

/* Meta-column attnums; must match epistemic_rules.c. */
#define EP_ATTR_KIND			(EP_ATTR_SYS_TIME + 1)
#define EP_ATTR_SPECIFICITY		(EP_ATTR_SYS_TIME + 2)
#define EP_ATTR_CONFIDENCE		(EP_ATTR_SYS_TIME + 3)

PG_FUNCTION_INFO_V1(epistemic_am_handler);

/* File-static overlay of the heapam routine with tuple_insert replaced. */
static TableAmRoutine epistemic_am_methods;
static bool epistemic_am_methods_initialized = false;

static void epistemic_tuple_insert_impl(Relation rel, TupleTableSlot *slot,
										CommandId cid, int options,
										struct BulkInsertStateData *bistate);

static void epistemic_multi_insert(Relation rel, TupleTableSlot **slots,
								   int nslots, CommandId cid, int options,
								   struct BulkInsertStateData *bistate);

static void epistemic_audit_evicted(Relation rel, ItemPointer loser_tid,
									ItemPointer winner_tid,
									EpistemicPrecedenceReason reason);
static void epistemic_close_sys_time(Relation rel, ItemPointer loser_tid);

/*
 * TOAST tables for epistemic relations are plain heap. Otherwise the TOAST
 * table inherits our AM OID, and PG's index build then trips heapam.c's
 * "rd_tableam == GetHeapamTableAmRoutine()" assertion in heap_getnext.
 */
static Oid
epistemic_relation_toast_am_impl(Relation rel)
{
	(void) rel;
	return HEAP_TABLE_AM_OID;
}

/*
 * Extract the incoming row's logical key for SSI + overlap detection.
 * Returns true only if all three fields are present and well-typed.
 */
static bool
extract_logical_key(TupleTableSlot *slot, int32 *entity_id,
					const char **attribute, RangeType **valid_time,
					int64 *valid_lower_secs, int64 *valid_upper_secs)
{
	bool		isnull;
	Datum		d;
	Form_pg_attribute att;

	if (slot->tts_tupleDescriptor == NULL ||
		slot->tts_tupleDescriptor->natts < EP_ATTR_VALID_TIME)
	{
		elog(DEBUG1, "epistemic: slot missing logical-key attributes");
		return false;
	}

	att = TupleDescAttr(slot->tts_tupleDescriptor, EP_ATTR_ENTITY_ID - 1);
	if (att->atttypid != INT4OID)
	{
		elog(DEBUG1, "epistemic: entity_id not int4 (typoid=%u)", att->atttypid);
		return false;
	}
	d = slot_getattr(slot, EP_ATTR_ENTITY_ID, &isnull);
	if (isnull)
		return false;
	*entity_id = DatumGetInt32(d);

	att = TupleDescAttr(slot->tts_tupleDescriptor, EP_ATTR_ATTRIBUTE - 1);
	if (att->atttypid != TEXTOID)
	{
		elog(DEBUG1, "epistemic: attribute not text (typoid=%u)", att->atttypid);
		return false;
	}
	d = slot_getattr(slot, EP_ATTR_ATTRIBUTE, &isnull);
	if (isnull)
		return false;
	*attribute = text_to_cstring(DatumGetTextPP(d));

	d = slot_getattr(slot, EP_ATTR_VALID_TIME, &isnull);
	if (isnull)
		return false;
	*valid_time = DatumGetRangeTypeP(d);

	/*
	 * Coarse bound extraction for the SSI key. We only need stable integers
	 * that reproduce across the same range; use RANGE_LB_INF/RANGE_UB_INF as
	 * sentinels and cast timestamptz to int64 microseconds.
	 */
	{
		TypeCacheEntry *tc;
		RangeBound	lb,
					ub;
		bool		empty;

		tc = lookup_type_cache(RangeTypeGetOid(*valid_time),
							   TYPECACHE_RANGE_INFO);
		range_deserialize(tc, *valid_time, &lb, &ub, &empty);
		*valid_lower_secs = lb.infinite ? INT64_MIN : (int64) DatumGetTimestampTz(lb.val);
		*valid_upper_secs = ub.infinite ? INT64_MAX : (int64) DatumGetTimestampTz(ub.val);
	}

	return true;
}

/* Populate EpistemicMeta from the three trailing slot attributes. */
static bool
extract_prefix(TupleTableSlot *slot, EpistemicMeta *out)
{
	bool		isnull;
	Datum		d;

	if (slot->tts_tupleDescriptor == NULL ||
		slot->tts_tupleDescriptor->natts < EP_ATTR_CONFIDENCE)
		return false;

	d = slot_getattr(slot, EP_ATTR_KIND, &isnull);
	if (isnull)
		return false;
	out->ep_kind = (uint8) DatumGetChar(d);
	out->ep_flags = 0;

	d = slot_getattr(slot, EP_ATTR_SPECIFICITY, &isnull);
	out->ep_specificity = isnull ? 0 : (uint16) DatumGetInt16(d);

	d = slot_getattr(slot, EP_ATTR_CONFIDENCE, &isnull);
	out->ep_confidence = isnull ? 1.0f : DatumGetFloat4(d);

	return true;
}

/*
 * True if the tuple's sys_time upper bound is unbounded ('live' row).
 * Accepts either an unbounded range upper or a literal timestamptz
 * 'infinity' value, since the user DDL defaults to
 *   tstzrange(now(), 'infinity')
 * which encodes the upper as the sentinel PG_INT64_MAX timestamptz.
 */
static bool
sys_time_is_open(TupleTableSlot *slot)
{
	bool		isnull;
	Datum		d;
	RangeType  *r;
	char		flags;
	TypeCacheEntry *tc;
	RangeBound	lb,
				ub;
	bool		empty;

	d = slot_getattr(slot, EP_ATTR_SYS_TIME, &isnull);
	if (isnull)
		return false;
	r = DatumGetRangeTypeP(d);
	flags = range_get_flags(r);
	if (flags & RANGE_EMPTY)
		return false;
	if (flags & RANGE_UB_INF)
		return true;

	tc = lookup_type_cache(RangeTypeGetOid(r), TYPECACHE_RANGE_INFO);
	range_deserialize(tc, r, &lb, &ub, &empty);
	(void) lb;
	if (empty || ub.infinite)
		return true;
	return TIMESTAMP_IS_NOEND(DatumGetTimestampTz(ub.val));
}

/*
 * Scan the relation for a live tuple that (a) has the same (entity_id,
 * attribute), (b) has an open sys_time upper bound, and (c) overlaps the
 * incoming valid_time. Uses the heapam scan callbacks directly to avoid
 * recursion. Returns true and fills *found_tid, *found_prefix, and (if
 * non-NULL) *found_xmin_out (the incumbent's raw xmin, for the F8
 * first-committer-wins tiebreak) on match.
 *
 * Snapshot: GetLatestSnapshot() rather than GetActiveSnapshot(). Under
 * READ COMMITTED, after epistemic_tuple_insert_impl takes the per-slot
 * advisory xact lock the statement snapshot is stale — a peer that
 * committed while we waited on the lock is invisible to the active
 * snapshot. GetLatestSnapshot (snapmgr.c:353-376 REL_18_STABLE) refreshes
 * SecondarySnapshot so the scan sees the just-committed peer.
 */
static bool
find_live_overlap(Relation rel, int32 want_entity, const char *want_attr,
				  RangeType *want_valid, ItemPointer found_tid,
				  EpistemicMeta *found_prefix, TransactionId *found_xmin_out)
{
	const TableAmRoutine *heapam;
	TableScanDesc scan;
	TupleTableSlot *scan_slot;
	TypeCacheEntry *rangetc;
	bool		found = false;

	heapam = GetHeapamTableAmRoutine();

	scan_slot = table_slot_create(rel, NULL);

	scan = heapam->scan_begin(rel, GetLatestSnapshot(), 0, NULL, NULL,
							  SO_TYPE_SEQSCAN | SO_ALLOW_STRAT |
							  SO_ALLOW_SYNC | SO_ALLOW_PAGEMODE);

	rangetc = lookup_type_cache(RangeTypeGetOid(want_valid),
								TYPECACHE_RANGE_INFO);

	while (heapam->scan_getnextslot(scan, ForwardScanDirection, scan_slot))
	{
		bool		isnull;
		Datum		d;
		int32		cand_entity;
		text	   *cand_attr_text;
		RangeType  *cand_valid;

		d = slot_getattr(scan_slot, EP_ATTR_ENTITY_ID, &isnull);
		if (isnull)
			continue;
		cand_entity = DatumGetInt32(d);
		if (cand_entity != want_entity)
			continue;

		d = slot_getattr(scan_slot, EP_ATTR_ATTRIBUTE, &isnull);
		if (isnull)
			continue;
		cand_attr_text = DatumGetTextPP(d);
		if (VARSIZE_ANY_EXHDR(cand_attr_text) != (Size) strlen(want_attr) ||
			memcmp(VARDATA_ANY(cand_attr_text), want_attr, strlen(want_attr)) != 0)
			continue;

		if (!sys_time_is_open(scan_slot))
			continue;

		d = slot_getattr(scan_slot, EP_ATTR_VALID_TIME, &isnull);
		if (isnull)
			continue;
		cand_valid = DatumGetRangeTypeP(d);

		if (!range_overlaps_internal(rangetc, cand_valid, want_valid))
			continue;

		if (!extract_prefix(scan_slot, found_prefix))
			continue;

		ItemPointerCopy(&scan_slot->tts_tid, found_tid);

		/*
		 * F8: capture the incumbent's raw xmin for the first-committer-wins
		 * tiebreak. HeapTupleHeaderGetRawXmin at htup_details.h:322-326
		 * REL_18_STABLE reads t_choice.t_heap.t_xmin — the xid that
		 * heap_insert stamped when the incumbent was originally written
		 * (heapam.c:2288 HeapTupleHeaderSetXmin, called from heap_insert
		 * at heapam.c:2083 with xid = GetCurrentTransactionId()).
		 *
		 * ExecFetchSlotHeapTuple with materialize=false gives us the
		 * scan's live HeapTuple without copying (tuptable.h:343
		 * REL_18_STABLE). The returned pointer is valid only while the
		 * scan slot still holds this row; we read t_data->t_choice
		 * inline and stash the TransactionId value, so lifetime is fine.
		 */
		if (found_xmin_out != NULL)
		{
			HeapTuple	htup;
			bool		should_free = false;

			htup = ExecFetchSlotHeapTuple(scan_slot, false, &should_free);
			*found_xmin_out = HeapTupleHeaderGetRawXmin(htup->t_data);
			if (should_free)
				heap_freetuple(htup);
		}

		found = true;
		break;
	}

	heapam->scan_end(scan);
	ExecDropSingleTupleTableSlot(scan_slot);

	return found;
}

static void
epistemic_tuple_insert_impl(Relation rel, TupleTableSlot *slot,
							CommandId cid, int options,
							struct BulkInsertStateData *bistate)
{
	EpistemicRule rule;
	int32		entity_id = 0;
	const char *attribute = NULL;
	RangeType  *valid_time = NULL;
	int64		valid_lower_secs = 0;
	int64		valid_upper_secs = 0;
	bool		have_key;
	EpistemicMeta new_prefix;
	bool		have_new_prefix;
	const TableAmRoutine *heapam;
	bool		have_eviction = false;
	ItemPointerData loser_tid;
	EpistemicCmpResult cmp = { EP_CMP_NEW_WINS, EP_REASON_NONE };

	/* Step 1: R1..R5. */
	rule = epistemic_check_rules(rel, slot);
	if (rule != EP_RULE_NONE)
		ereport(ERROR,
				(errcode(ERRCODE_CHECK_VIOLATION),
				 errmsg("epistemic write-time rule violation: %s",
						epistemic_rule_label(rule))));

	have_key = extract_logical_key(slot, &entity_id, &attribute, &valid_time,
								   &valid_lower_secs, &valid_upper_secs);
	have_new_prefix = extract_prefix(slot, &new_prefix);

	/*
	 * F6: per-slot advisory xact lock. Serialises concurrent same-slot
	 * writers, so the find_live_overlap seqscan below (and heap_insert
	 * after it) run on a fresh view of the winner: the loser waits for
	 * the winner's COMMIT to release the lock, then sees the committed
	 * peer via GetLatestSnapshot in find_live_overlap.
	 *
	 * Two int4 keys: (entity_id, hash_bytes(attribute)). Matches the
	 * shape of pg_advisory_xact_lock(int4, int4) at
	 * src/backend/utils/adt/lockfuncs.c:826-837 REL_18_STABLE (which
	 * calls SET_LOCKTAG_INT32 then LockAcquire(&tag, ExclusiveLock,
	 * false, false)). We construct the LOCKTAG inline rather than
	 * DirectFunctionCall2'ing pg_advisory_xact_lock_int4 — one fewer
	 * fmgr hop, and the ExclusiveLock/xact-scope semantics are the
	 * whole point.
	 *
	 * Collision caveat. The (entity_id, hash_bytes(attribute)) key
	 * space is 2^32 x 2^32 but effectively 2^32 (attributes) x #entities.
	 * Two slots that hash to the same key1/key2 will false-serialise
	 * on writes; that is a benign perf issue (correctness holds
	 * because find_live_overlap still filters by full entity+attribute
	 * equality), not a correctness bug.
	 */
	if (have_key)
	{
		LOCKTAG		tag;
		int32		attr_hash;

		attr_hash = (int32) hash_bytes((const unsigned char *) attribute,
									   (int) strlen(attribute));
		SET_LOCKTAG_ADVISORY(tag, MyDatabaseId, (uint32) entity_id,
							 (uint32) attr_hash, 2);
		(void) LockAcquire(&tag, ExclusiveLock, false, false);
	}

	(void) valid_lower_secs;
	(void) valid_upper_secs;

	/*
	 * SSI is handled by heapam itself: the seqscan below runs through
	 * heap_beginscan, which calls PredicateLockRelation, and the delegated
	 * heap_insert calls CheckForSerializableConflictIn. Both take effect
	 * automatically. See DECISIONS.md ("F1: predicate locking") for the
	 * audit that showed why an AM-level hook is neither needed nor useful.
	 */

	/* Steps 4/5: overlap scan + precedence. */
	if (have_key && have_new_prefix)
	{
		EpistemicMeta incumbent;
		TransactionId incumbent_xmin = InvalidTransactionId;

		if (find_live_overlap(rel, entity_id, attribute, valid_time,
							  &loser_tid, &incumbent, &incumbent_xmin))
		{
			cmp = epistemic_precedence_cmp(&incumbent, &new_prefix);

			/*
			 * F8: first-committer-wins tiebreak. epistemic_precedence_cmp
			 * returns NEW_WINS/CONTRADICTED_SAME_RANK on a true tie
			 * (equal kind, specificity, confidence). We break that tie by
			 * comparing xids: the incumbent's raw xmin (stamped by
			 * heap_insert at heapam.c:2288 HeapTupleHeaderSetXmin from
			 * xid = GetCurrentTransactionId() at heapam.c:2083) against
			 * the current backend's xid (xact.c:454 GetCurrentTransactionId,
			 * REL_18_STABLE). TransactionIdPrecedes at transam.c:279-292
			 * handles xid-wraparound via a modulo-2^32 comparison for two
			 * normal xids and a straight unsigned comparison when either
			 * side is a permanent xid (FrozenTransactionId etc).
			 *
			 * Under the F6 advisory lock the incumbent is always committed
			 * by the time find_live_overlap sees it (its writer released
			 * the lock at COMMIT), and GetCurrentTransactionId assigns the
			 * new row's xid on demand — so incumbent_xmin < new_xid on
			 * every normal race and the incumbent wins the tie. The
			 * defensive follows-branch keeps NEW_WINS in the pathological
			 * case where an incumbent's xid somehow follows ours (can
			 * happen with FrozenTransactionId as the "permanent" xmin
			 * sentinel, which is logically -infinity; TransactionIdPrecedes
			 * correctly reports incumbent_xmin < new_xid there too, so
			 * "follows" is only reachable if the semantics are inverted
			 * by callers not covered here).
			 *
			 * xids are reassigned on pg_dump / pg_restore (restore reloads
			 * via COPY FROM at copyfrom.c:1427 which routes through
			 * table_tuple_insert → heap_insert → GetCurrentTransactionId,
			 * assigning a fresh xid to every reloaded row). So the
			 * specific survivor of a historical tie is NOT stable across
			 * dump/restore. What IS stable across dump/restore is the
			 * "exactly one live row per slot" invariant that sql/am_eviction.sql
			 * asserts.
			 */
			if (cmp.outcome == EP_CMP_NEW_WINS &&
				cmp.reason == EP_REASON_CONTRADICTED_SAME_RANK)
			{
				TransactionId new_xid = GetCurrentTransactionId();

				if (TransactionIdIsValid(incumbent_xmin) &&
					TransactionIdPrecedes(incumbent_xmin, new_xid))
				{
					/* incumbent committed first — it keeps the slot. */
					cmp.outcome = EP_CMP_NEW_LOSES;
					/* reason stays CONTRADICTED_SAME_RANK for audit label */
				}
				/*
				 * Otherwise (incumbent_xmin follows or equals new_xid, or
				 * is invalid): defensively keep NEW_WINS. In the current
				 * design this branch is unreachable because the incumbent
				 * is a committed row visible to GetLatestSnapshot before
				 * the current xact even acquired its xid; kept as an
				 * explicit no-op so a future refactor that inverts commit
				 * order does not silently flip the tie policy.
				 */
			}

			if (cmp.outcome == EP_CMP_NEW_LOSES)
				ereport(ERROR,
						(errcode(ERRCODE_CHECK_VIOLATION),
						 errmsg("epistemic precedence: NEW_LOSES (reason=%s)",
								epistemic_precedence_reason_label(cmp.reason))));

			have_eviction = true;
		}
	}

	/* Step 6: delegate storage to heap and obtain the winner's tid. */
	heapam = GetHeapamTableAmRoutine();
	heapam->tuple_insert(rel, slot, cid, options, bistate);

	/*
	 * Step 7: post-insert epistemic eviction bookkeeping.
	 *   a) audit the incumbent to epistemic.evicted_fact, tagging the
	 *      winner's ctid (now known). Durable via the SPI-driven
	 *      heap_insert into the audit relation (heap's own WAL).
	 *   b) physically close the incumbent's sys_time upper bound via
	 *      simple_heap_update. Durable via heap_update's XLOG_HEAP_UPDATE.
	 * valid_time is preserved throughout (bitemporal semantics).
	 * No epistemic WAL record is written on the eviction path: the F3
	 * audit showed that a dedicated EVICT rmgr record added nothing to
	 * recovery (heap's two records above already carry every byte).
	 */
	if (have_eviction)
	{
		epistemic_audit_evicted(rel, &loser_tid, &slot->tts_tid, cmp.reason);
		epistemic_close_sys_time(rel, &loser_tid);
		CommandCounterIncrement();
	}

	/*
	 * Step 8: emit the epistemic INSERT annotation record. Durability of
	 * the row itself is provided entirely by heap's XLOG_HEAP_INSERT
	 * (heapam.c:2209-2231 in REL_18_STABLE registers the full tuple body
	 * via XLogRegisterBufData and heap_xlog_insert reconstructs it at
	 * redo). The epistemic record carries only the (kind, specificity,
	 * confidence) prefix as a named annotation on rmgr 128; rm_decode is
	 * NULL, so logical decoding (decode.c:115-117) skips it, and PG 18's
	 * standalone pg_waldump cannot load custom rmgrs, so it renders our
	 * records as "custom128 UNKNOWN (10)" — the rm_desc callback is only
	 * reached in-process, via wal_debug tracing on this same postmaster.
	 * The record is kept for two reasons: (1) it exercises the registered
	 * rmgr so sql/wal.sql's rm_id=128 probe reflects a real emitted
	 * record; (2) it reserves the annotation channel for a future logical
	 * decoding consumer (which will require also wiring rm_decode). See
	 * DECISIONS.md (F3 audit) for the disable-and-retest proof.
	 */
	if (have_new_prefix && ItemPointerIsValid(&slot->tts_tid))
		(void) epistemic_wal_log_insert_marker(rel, &slot->tts_tid, &new_prefix);
}

/*
 * multi_insert callback. F18 closes the COPY bypass F9 discovered: PG 18's
 * CopyFrom (src/backend/commands/copyfrom.c:554-559 REL_18_STABLE) routes
 * batched inserts through table_multi_insert, which dispatches on the AM's
 * `multi_insert` callback (access/tableam.h:527-529 REL_18_STABLE). Before
 * F18, epistemic_am_methods inherited heapam's heap_multi_insert (bound at
 * src/backend/access/heap/heapam_handler.c:2641 REL_18_STABLE), so every
 * row in a COPY batch skipped R1..R5, the advisory lock, precedence, the
 * eviction bookkeeping, and the rmgr-128 annotation record.
 *
 * COPY selects the insertion method in copyfrom.c:995-1006: if the target
 * has a BEFORE/INSTEAD OF INSERT trigger, insertMethod = CIM_SINGLE and
 * CopyFrom calls table_tuple_insert per row (which routed through our
 * override and was safe). If not, insertMethod = CIM_MULTI and the batch
 * flows into heap_multi_insert. That is the write path this callback covers.
 *
 * Implementation: iterate over slots[] and call epistemic_tuple_insert_impl
 * on each. This is deliberately the same enforcement path as single-row
 * INSERT — R1..R5, per-slot advisory xact lock, GetLatestSnapshot overlap
 * probe, precedence compare, heap_insert, audit + sys_time close, WAL
 * annotation — invoked N times. Correctness is byte-for-byte identical to
 * a plain INSERT of the same N rows.
 *
 * Tradeoff. heap_multi_insert (heapam.c:2351 REL_18_STABLE) batches the
 * WAL record per page and toasts in bulk; per-row epistemic_tuple_insert_impl
 * pays one heap_insert per row and one WAL record per row. COPY into an
 * epistemic table is therefore roughly at the throughput of an equivalent
 * INSERT ... SELECT rather than of a plain-heap COPY. That is the acceptable
 * cost of not silently skipping enforcement.
 *
 * F7 interaction. epistemic_tuple_insert_impl takes one advisory xact lock
 * per row. A COPY of N rows now accumulates N locks in the shared lock
 * table. At the PG default max_locks_per_transaction=64 the ceiling is
 * ~15k rows per transaction (F7 characterization in
 * scripts/lock_exhaustion.sh). COPY inherits that ceiling. Raising
 * max_locks_per_transaction moves it linearly. We do NOT drop the lock in
 * this path — doing so would silently re-open the RC integrity leak F6
 * closed.
 *
 * The `options` and `bistate` arguments are forwarded to each per-row
 * heap_insert via epistemic_tuple_insert_impl's delegation to the heapam
 * tuple_insert callback (epistemic_am.c line ~507). Any HEAP_INSERT flags
 * COPY sets (TABLE_INSERT_SKIP_FSM at copyfrom.c:851 and TABLE_INSERT_FROZEN
 * at copyfrom.c:908) reach heap_insert unchanged.
 */
static void
epistemic_multi_insert(Relation rel, TupleTableSlot **slots, int nslots,
					   CommandId cid, int options,
					   struct BulkInsertStateData *bistate)
{
	int			i;

	for (i = 0; i < nslots; i++)
		epistemic_tuple_insert_impl(rel, slots[i], cid, options, bistate);
}

/*
 * Insert one row into epistemic.evicted_fact describing the incumbent
 * that lost the precedence comparison. Uses SPI so the JSONB payload is
 * built by to_jsonb on the live server row rather than reconstructed
 * from slot values in C. The winner's ctid is captured as text so the
 * audit trail survives arbitrary later heap movement of the winner.
 */
static void
epistemic_audit_evicted(Relation rel, ItemPointer loser_tid,
						ItemPointer winner_tid,
						EpistemicPrecedenceReason reason)
{
	Oid			nspoid;
	const char *nspname;
	const char *relname;
	char	   *qualname;
	StringInfoData sql;
	Oid			argtypes[3] = { TEXTOID, TEXTOID, TIDOID };
	Datum		values[3];
	char		nulls[3] = { ' ', ' ', ' ' };
	char		winnerbuf[64];
	char		loserbuf[64];
	int			ret;

	nspoid = RelationGetNamespace(rel);
	nspname = get_namespace_name(nspoid);
	relname = RelationGetRelationName(rel);
	if (nspname == NULL || relname == NULL)
		elog(ERROR, "epistemic audit: could not resolve target name");
	qualname = quote_qualified_identifier(nspname, relname);

	initStringInfo(&sql);
	appendStringInfo(&sql,
		"INSERT INTO epistemic.evicted_fact "
		"(reason, winner_ctid, original_kind, original_row) "
		"SELECT $1::text, $2::text, f.ep_kind, to_jsonb(f) "
		"FROM ONLY %s f WHERE ctid = $3::tid",
		qualname);

	values[0] = CStringGetTextDatum(
		epistemic_precedence_reason_label(reason));

	if (winner_tid != NULL && ItemPointerIsValid(winner_tid))
	{
		snprintf(winnerbuf, sizeof(winnerbuf), "(%u,%u)",
				 ItemPointerGetBlockNumber(winner_tid),
				 ItemPointerGetOffsetNumber(winner_tid));
		values[1] = CStringGetTextDatum(winnerbuf);
	}
	else
	{
		values[1] = (Datum) 0;
		nulls[1] = 'n';
	}

	snprintf(loserbuf, sizeof(loserbuf), "(%u,%u)",
			 ItemPointerGetBlockNumber(loser_tid),
			 ItemPointerGetOffsetNumber(loser_tid));
	values[2] = DirectFunctionCall1(tidin, CStringGetDatum(loserbuf));

	if ((ret = SPI_connect()) < 0)
		elog(ERROR, "epistemic audit: SPI_connect failed: %d", ret);

	ret = SPI_execute_with_args(sql.data, 3, argtypes, values, nulls,
								false, 0);
	if (ret != SPI_OK_INSERT)
	{
		SPI_finish();
		elog(ERROR, "epistemic audit: SPI_execute_with_args returned %d", ret);
	}
	if (SPI_processed != 1)
	{
		int64		processed = (int64) SPI_processed;

		SPI_finish();
		elog(ERROR, "epistemic audit: expected 1 row inserted, got " INT64_FORMAT,
			 processed);
	}

	SPI_finish();
	pfree(sql.data);
}

/*
 * Physically close the incumbent's sys_time upper bound to now(). The
 * incumbent lives at loser_tid; we deform, rewrite EP_ATTR_SYS_TIME, and
 * simple_heap_update in place. valid_time is preserved.
 */
static void
epistemic_close_sys_time(Relation rel, ItemPointer loser_tid)
{
	HeapTupleData tuple;
	Buffer		buffer;
	Snapshot	snap;
	TupleDesc	tupdesc;
	int			natts;
	Datum	   *values;
	bool	   *isnull;
	bool	   *replace;
	RangeType  *oldrange;
	RangeType  *newrange;
	RangeBound	oldlb;
	RangeBound	olduB;
	RangeBound	newlb;
	RangeBound	newub;
	bool		empty;
	TypeCacheEntry *tc;
	HeapTuple	newtup;
	TU_UpdateIndexes update_indexes;

	tupdesc = RelationGetDescr(rel);
	natts = tupdesc->natts;

	ItemPointerCopy(loser_tid, &tuple.t_self);

	/*
	 * F6: use GetLatestSnapshot for the fetch. Under RC the statement's
	 * active snapshot was taken before the F6 advisory lock and cannot
	 * see the incumbent that a concurrent writer committed while we
	 * held the lock. GetLatestSnapshot (snapmgr.c:353-376 REL_18_STABLE)
	 * refreshes SecondarySnapshot; the incumbent's TID resolves.
	 */
	snap = GetLatestSnapshot();
	if (!heap_fetch(rel, snap, &tuple, &buffer, false))
		elog(ERROR, "epistemic evict: could not fetch incumbent tuple");

	values = (Datum *) palloc0(natts * sizeof(Datum));
	isnull = (bool *) palloc0(natts * sizeof(bool));
	replace = (bool *) palloc0(natts * sizeof(bool));

	heap_deform_tuple(&tuple, tupdesc, values, isnull);

	if (isnull[EP_ATTR_SYS_TIME - 1])
	{
		ReleaseBuffer(buffer);
		elog(ERROR, "epistemic evict: incumbent sys_time is NULL");
	}

	oldrange = DatumGetRangeTypeP(values[EP_ATTR_SYS_TIME - 1]);
	tc = lookup_type_cache(RangeTypeGetOid(oldrange), TYPECACHE_RANGE_INFO);
	range_deserialize(tc, oldrange, &oldlb, &olduB, &empty);
	(void) olduB;

	newlb = oldlb;
	newub.val = TimestampTzGetDatum(GetCurrentTimestamp());
	newub.infinite = false;
	newub.inclusive = true;
	newub.lower = false;

	newrange = make_range(tc, &newlb, &newub, false, NULL);

	values[EP_ATTR_SYS_TIME - 1] = RangeTypePGetDatum(newrange);
	isnull[EP_ATTR_SYS_TIME - 1] = false;
	replace[EP_ATTR_SYS_TIME - 1] = true;

	newtup = heap_modify_tuple(&tuple, tupdesc, values, isnull, replace);
	ReleaseBuffer(buffer);

	ItemPointerCopy(loser_tid, &newtup->t_self);

	simple_heap_update(rel, &newtup->t_self, newtup, &update_indexes);

	heap_freetuple(newtup);
	pfree(values);
	pfree(isnull);
	pfree(replace);
}

/*
 * Handler entry point. Copies heapam's TableAmRoutine on first call and
 * overrides tuple_insert.
 */
Datum
epistemic_am_handler(PG_FUNCTION_ARGS)
{
	if (!epistemic_am_methods_initialized)
	{
		const TableAmRoutine *heapam = GetHeapamTableAmRoutine();

		epistemic_am_methods = *heapam;
		epistemic_am_methods.type = T_TableAmRoutine;
		epistemic_am_methods.tuple_insert = epistemic_tuple_insert_impl;
		epistemic_am_methods.multi_insert = epistemic_multi_insert;
		epistemic_am_methods.relation_toast_am = epistemic_relation_toast_am_impl;
		epistemic_am_methods_initialized = true;
	}

	PG_RETURN_POINTER(&epistemic_am_methods);
}

