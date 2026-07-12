/*
 * epistemic_wal.c
 *
 * Annotation channel, not durability. Heap's XLOG_HEAP_INSERT
 * (heapam.c:2222-2226, REL_18_STABLE) already carries every byte of
 * the row, and heap_xlog_insert reconstructs it at redo
 * (heapam_xlog.c:482-503). Disabling the marker below leaves recovery
 * under wal_consistency_checking=all indistinguishable; see
 * DECISIONS.md (F3) for the disable-and-retest transcript.
 *
 * rm_decode is NULL, so logical decoding
 * (decode.c:LogicalDecodingProcessRecord, 115-117) skips these
 * records. PG 18's standalone pg_waldump does not load custom rmgrs,
 * so external decoding is unavailable; rm_desc runs only under
 * in-process wal_debug tracing.
 */
#include "postgres.h"

#include "access/xlog.h"
#include "access/xlog_internal.h"
#include "access/xloginsert.h"
#include "access/xlogreader.h"
#include "access/xlogrecord.h"
#include "lib/stringinfo.h"
#include "utils/elog.h"
#include "utils/rel.h"

#include "epistemic.h"
#include "epistemic_wal.h"

static const RmgrData epistemic_rmgr = {
	.rm_name = "epistemic",
	.rm_redo = epistemic_rm_redo,
	.rm_desc = epistemic_rm_desc,
	.rm_identify = epistemic_rm_identify,
	.rm_startup = NULL,
	.rm_cleanup = NULL,
	.rm_mask = epistemic_rm_mask,
	.rm_decode = NULL,
};

void
epistemic_rmgr_register(void)
{
	RegisterCustomRmgr(RM_EPISTEMIC_ID, &epistemic_rmgr);
}

/*
 * Redo an annotation marker. There is no page state to update: the
 * marker's tuple_len is always 0, no buffer is registered, the row
 * itself has already been replayed by heap's redo. We log the record
 * at DEBUG1 so wal_debug tracing can confirm the record was seen.
 */
void
epistemic_rm_redo(XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & ~XLR_INFO_MASK;

	if (info == XLOG_EPISTEMIC_INSERT)
	{
		xl_epistemic_insert *xlrec = (xl_epistemic_insert *) XLogRecGetData(record);

		elog(DEBUG1,
			 "epistemic redo INSERT annotation: offnum=%u kind=%u confidence=%.4f",
			 xlrec->offnum, xlrec->prefix.ep_kind, xlrec->prefix.ep_confidence);
	}
	else
		elog(PANIC, "epistemic_rm_redo: unknown info byte 0x%02x", info);
}

void
epistemic_rm_desc(StringInfo buf, XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & ~XLR_INFO_MASK;

	if (info == XLOG_EPISTEMIC_INSERT)
	{
		xl_epistemic_insert *xlrec = (xl_epistemic_insert *) XLogRecGetData(record);

		appendStringInfo(buf,
						 "insert offnum=%u kind=%s confidence=%.4f specificity=%u",
						 xlrec->offnum,
						 epistemic_kind_label(epistemic_kind_from_byte(xlrec->prefix.ep_kind)),
						 xlrec->prefix.ep_confidence,
						 xlrec->prefix.ep_specificity);
	}
	else
		appendStringInfo(buf, "unknown info 0x%02x", info);
}

const char *
epistemic_rm_identify(uint8 info)
{
	if ((info & ~XLR_INFO_MASK) == XLOG_EPISTEMIC_INSERT)
		return "INSERT";
	return NULL;
}

/*
 * The annotation records touch no page data (buffer 0 is never
 * registered by epistemic_wal_log_insert_marker), so
 * wal_consistency_checking has nothing to mask. No-op.
 */
void
epistemic_rm_mask(char *pagedata, BlockNumber blkno)
{
	(void) pagedata;
	(void) blkno;
}

XLogRecPtr
epistemic_wal_log_insert_marker(Relation rel, ItemPointer tid,
								const EpistemicMeta *prefix)
{
	xl_epistemic_insert xlrec;

	xlrec.rlocator = rel->rd_locator;
	xlrec.offnum = ItemPointerGetOffsetNumber(tid);
	xlrec.tuple_len = 0;
	xlrec.prefix = *prefix;

	XLogBeginInsert();
	XLogRegisterData(&xlrec, SizeOfEpistemicInsert);

	return XLogInsert(RM_EPISTEMIC_ID, XLOG_EPISTEMIC_INSERT);
}
