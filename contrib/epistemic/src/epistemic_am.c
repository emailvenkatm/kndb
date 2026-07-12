/*
 * epistemic_am.c
 *
 * Table access method handler for the epistemic AM. Wraps heapam's
 * TableAmRoutine: all callbacks delegate to heap except tuple_insert,
 * which runs the write-time rule/precedence/SSI/WAL machinery before
 * handing the row to heap for actual storage.
 *
 * User schema contract (frozen by Agent C's rules module):
 *   1  entity_id     int4
 *   2  attribute     text
 *   3  value         text
 *   4  sources       array or bytea
 *   5  valid_time    tstzrange
 *   6  sys_time      tstzrange DEFAULT tstzrange(now(), 'infinity')
 *   7  ep_kind       epistemic.epistemic_kind
 *   8  ep_specificity int2
 *   9  ep_confidence float4
 *
 * Owner: Agent A (TAM storage layer).
 */
#include "postgres.h"
#include "fmgr.h"

#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/relscan.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_type.h"
#include "executor/tuptable.h"
#include "nodes/nodes.h"
#include "storage/bufmgr.h"
#include "storage/itemptr.h"
#include "utils/builtins.h"
#include "utils/rangetypes.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include "utils/typcache.h"

#include "epistemic.h"
#include "epistemic_am.h"
#include "epistemic_precedence.h"
#include "epistemic_rules.h"
#include "epistemic_ssi.h"
#include "epistemic_wal.h"

/* Hidden-prefix slot columns; must match epistemic_rules.c. */
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

/* Build the EpistemicPrefix from three trailing slot attributes. */
static bool
extract_prefix(TupleTableSlot *slot, EpistemicPrefix *out)
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

/* True if the tuple's sys_time upper bound is +infinity (row still live). */
static bool
sys_time_is_open(TupleTableSlot *slot)
{
	bool		isnull;
	Datum		d;
	RangeType  *r;
	char		flags;

	d = slot_getattr(slot, EP_ATTR_SYS_TIME, &isnull);
	if (isnull)
		return false;
	r = DatumGetRangeTypeP(d);
	flags = range_get_flags(r);
	if (flags & RANGE_EMPTY)
		return false;
	return (flags & RANGE_UB_INF) != 0;
}

/*
 * Scan the relation for a live tuple that (a) has the same (entity_id,
 * attribute), (b) has an open sys_time upper bound, and (c) overlaps the
 * incoming valid_time. Uses the heapam scan callbacks directly to avoid
 * recursion.  Returns true and fills *found_tid and *found_prefix on match.
 */
static bool
find_live_overlap(Relation rel, int32 want_entity, const char *want_attr,
				  RangeType *want_valid, ItemPointer found_tid,
				  EpistemicPrefix *found_prefix)
{
	const TableAmRoutine *heapam;
	TableScanDesc scan;
	TupleTableSlot *scan_slot;
	TypeCacheEntry *rangetc;
	bool		found = false;

	heapam = GetHeapamTableAmRoutine();

	scan_slot = table_slot_create(rel, NULL);

	scan = heapam->scan_begin(rel, GetActiveSnapshot(), 0, NULL, NULL,
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
	EpistemicPrefix new_prefix;
	bool		have_new_prefix;
	const TableAmRoutine *heapam;

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

	/* Step 3: SSI slot predicate lock (no-op outside SERIALIZABLE). */
	if (have_key)
		epistemic_predicate_lock_slot(rel, entity_id, attribute,
									  valid_lower_secs, valid_upper_secs,
									  GetActiveSnapshot());

	/* Steps 4/5: overlap scan + precedence. */
	if (have_key && have_new_prefix)
	{
		ItemPointerData loser_tid;
		EpistemicPrefix incumbent;

		if (find_live_overlap(rel, entity_id, attribute, valid_time,
							  &loser_tid, &incumbent))
		{
			EpistemicCmpResult cmp;

			cmp = epistemic_precedence_cmp(&incumbent, &new_prefix);

			if (cmp.outcome == EP_CMP_NEW_LOSES)
				ereport(ERROR,
						(errcode(ERRCODE_CHECK_VIOLATION),
						 errmsg("epistemic precedence: NEW_LOSES (reason=%s)",
								epistemic_precedence_reason_label(cmp.reason))));

			/*
			 * NEW_WINS. PoC simplification: emit the EVICT WAL record for
			 * audit, but do not physically close the incumbent's sys_time
			 * or append an audit row. Doing so requires a heap_update
			 * against the loser TID with a modified tstzrange, plus SPI
			 * into epistemic.evicted_fact; both are non-trivial and out of
			 * scope for the PoC. Consequence: two live overlapping rows
			 * co-exist until a subsequent write triggers eviction.
			 */
			(void) epistemic_wal_log_evict(rel, &loser_tid, &loser_tid,
										   GetCurrentTimestamp(),
										   (uint8) cmp.reason);
		}
	}

	/* Step 6: delegate storage to heap. */
	heapam = GetHeapamTableAmRoutine();
	heapam->tuple_insert(rel, slot, cid, options, bistate);

	/*
	 * Step 7: skipped. heap's tuple_insert has already written its own
	 * XLOG_HEAP_INSERT record for durability. Emitting a matching
	 * XLOG_EPISTEMIC_INSERT here would require re-registering the buffer
	 * that heap_insert already released; Agent B's redo tolerates the
	 * absence of a block ref, but the PoC forgoes epistemic-audit-in-WAL
	 * on the insert path entirely.
	 */
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
		epistemic_am_methods.relation_toast_am = epistemic_relation_toast_am_impl;
		epistemic_am_methods_initialized = true;
	}

	PG_RETURN_POINTER(&epistemic_am_methods);
}

/*
 * Legacy prototype kept alive because the header (frozen contract with
 * Agent B/C/D) still exposes it. Not used by the AM routine; the actual
 * insert path is epistemic_tuple_insert_impl above.
 */
ItemPointerData
epistemic_insert_tuple(Relation rel, TupleTableSlot *slot,
					   CommandId cid, int options)
{
	ItemPointerData tid;

	(void) rel;
	(void) slot;
	(void) cid;
	(void) options;
	ItemPointerSetInvalid(&tid);
	return tid;
}
