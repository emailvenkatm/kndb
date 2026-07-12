/*
 * epistemic_wal.c
 *
 * Custom WAL resource manager for the epistemic AM. Registered at
 * RM_EPISTEMIC_ID (== RM_EXPERIMENTAL_ID = 128) from _PG_init via
 * epistemic_rmgr_register().
 *
 * Owner: Agent B.
 */
#include "postgres.h"

#include "access/xlog.h"
#include "access/xlog_internal.h"
#include "access/xloginsert.h"
#include "access/xlogreader.h"
#include "access/xlogrecord.h"
#include "access/xlogutils.h"
#include "lib/stringinfo.h"
#include "storage/buf.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/itemptr.h"
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
 * Redo INSERT: reconstruct the tuple and install it at (blkno, offnum) of
 * the target relation's buffer. The block reference registered at record
 * write time provides the RelFileLocator and BlockNumber.
 *
 * If block reference 0 is absent we cannot locate the target; log and
 * skip. This can happen when the caller used the log-only variant during
 * unit tests.
 */
static void
epistemic_redo_insert(XLogReaderState *record)
{
	xl_epistemic_insert *xlrec = (xl_epistemic_insert *) XLogRecGetData(record);
	Buffer		buffer;
	XLogRedoAction action;

	if (!XLogRecHasBlockRef(record, 0))
	{
		elog(DEBUG1, "epistemic redo INSERT: no block ref; skipping install");
		return;
	}

	action = XLogReadBufferForRedo(record, 0, &buffer);

	if (action == BLK_NEEDS_REDO)
	{
		Size		datalen = 0;
		char	   *tupdata;
		Page		page;
		OffsetNumber inserted;

		tupdata = XLogRecGetBlockData(record, 0, &datalen);
		if (tupdata == NULL || datalen != (Size) xlrec->tuple_len)
			elog(PANIC, "epistemic redo INSERT: block data mismatch (%zu vs %u)",
				 datalen, xlrec->tuple_len);

		page = BufferGetPage(buffer);

		inserted = PageAddItem(page, (Item) tupdata, xlrec->tuple_len,
							   xlrec->offnum, true, true);
		if (inserted == InvalidOffsetNumber)
			elog(PANIC, "epistemic redo INSERT: PageAddItem failed at %u",
				 xlrec->offnum);

		PageSetLSN(page, record->EndRecPtr);
		MarkBufferDirty(buffer);
	}

	if (BufferIsValid(buffer))
		UnlockReleaseBuffer(buffer);
}

/*
 * Redo EVICT: the loser sys_time close will be replayed via the heap-am
 * WAL record that Agent A rewires; the epistemic EVICT record is a
 * semantic marker (audit intent + reason code) and needs no page work
 * at redo time. Log it so wal_debug tracing shows the intent.
 */
static void
epistemic_redo_evict(XLogReaderState *record)
{
	xl_epistemic_evict *xlrec = (xl_epistemic_evict *) XLogRecGetData(record);

	elog(DEBUG1,
		 "epistemic redo EVICT: loser=(%u,%u) winner=(%u,%u) reason=%u",
		 ItemPointerGetBlockNumberNoCheck(&xlrec->loser_tid),
		 ItemPointerGetOffsetNumberNoCheck(&xlrec->loser_tid),
		 ItemPointerGetBlockNumberNoCheck(&xlrec->winner_tid),
		 ItemPointerGetOffsetNumberNoCheck(&xlrec->winner_tid),
		 xlrec->reason);
}

/*
 * Redo AUDIT: the audit row was appended to epistemic.evicted_fact via a
 * normal heap_insert path (which produces its own heap WAL record); the
 * AUDIT record here carries the reason code and payload for external
 * consumers and does not need to re-append the row.
 */
static void
epistemic_redo_audit(XLogReaderState *record)
{
	xl_epistemic_audit *xlrec = (xl_epistemic_audit *) XLogRecGetData(record);

	elog(DEBUG1,
		 "epistemic redo AUDIT: offnum=%u reason=%u payload_len=%u",
		 xlrec->offnum, xlrec->reason, xlrec->payload_len);
}

void
epistemic_rm_redo(XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & ~XLR_INFO_MASK;

	switch (info)
	{
		case XLOG_EPISTEMIC_INSERT:
			epistemic_redo_insert(record);
			break;
		case XLOG_EPISTEMIC_EVICT:
			epistemic_redo_evict(record);
			break;
		case XLOG_EPISTEMIC_AUDIT:
			epistemic_redo_audit(record);
			break;
		default:
			elog(PANIC, "epistemic_rm_redo: unknown info byte 0x%02x", info);
	}
}

void
epistemic_rm_desc(StringInfo buf, XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & ~XLR_INFO_MASK;
	char	   *rec = XLogRecGetData(record);

	switch (info)
	{
		case XLOG_EPISTEMIC_INSERT:
		{
			xl_epistemic_insert *xlrec = (xl_epistemic_insert *) rec;

			appendStringInfo(buf,
							 "insert offnum=%u tuple_len=%u kind=%s confidence=%.4f specificity=%u",
							 xlrec->offnum,
							 xlrec->tuple_len,
							 epistemic_kind_label(epistemic_kind_from_byte(xlrec->prefix.ep_kind)),
							 xlrec->prefix.ep_confidence,
							 xlrec->prefix.ep_specificity);
			break;
		}
		case XLOG_EPISTEMIC_EVICT:
		{
			xl_epistemic_evict *xlrec = (xl_epistemic_evict *) rec;

			appendStringInfo(buf,
							 "evict loser=(%u,%u) winner=(%u,%u) reason=%u",
							 ItemPointerGetBlockNumberNoCheck(&xlrec->loser_tid),
							 ItemPointerGetOffsetNumberNoCheck(&xlrec->loser_tid),
							 ItemPointerGetBlockNumberNoCheck(&xlrec->winner_tid),
							 ItemPointerGetOffsetNumberNoCheck(&xlrec->winner_tid),
							 xlrec->reason);
			break;
		}
		case XLOG_EPISTEMIC_AUDIT:
		{
			xl_epistemic_audit *xlrec = (xl_epistemic_audit *) rec;

			appendStringInfo(buf,
							 "audit offnum=%u reason=%u payload_len=%u",
							 xlrec->offnum,
							 xlrec->reason,
							 xlrec->payload_len);
			break;
		}
		default:
			appendStringInfo(buf, "unknown info 0x%02x", info);
			break;
	}
}

const char *
epistemic_rm_identify(uint8 info)
{
	switch (info & ~XLR_INFO_MASK)
	{
		case XLOG_EPISTEMIC_INSERT:
			return "INSERT";
		case XLOG_EPISTEMIC_EVICT:
			return "EVICT";
		case XLOG_EPISTEMIC_AUDIT:
			return "AUDIT";
		default:
			return NULL;
	}
}

/*
 * The epistemic AM writes no hint bits and touches no volatile bookkeeping
 * during redo, so wal_consistency_checking has nothing to mask off.
 * Left as a no-op deliberately.
 */
void
epistemic_rm_mask(char *pagedata, BlockNumber blkno)
{
	(void) pagedata;
	(void) blkno;
}

XLogRecPtr
epistemic_wal_log_insert(Relation rel, Buffer buffer, ItemPointer tid,
						 const EpistemicPrefix *prefix,
						 const char *tuple, uint16 tuple_len)
{
	xl_epistemic_insert xlrec;

	xlrec.rlocator = rel->rd_locator;
	xlrec.offnum = ItemPointerGetOffsetNumber(tid);
	xlrec.tuple_len = tuple_len;
	xlrec.prefix = *prefix;

	XLogBeginInsert();
	XLogRegisterData(&xlrec, SizeOfEpistemicInsert);
	XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
	XLogRegisterBufData(0, tuple, tuple_len);

	return XLogInsert(RM_EPISTEMIC_ID, XLOG_EPISTEMIC_INSERT);
}

XLogRecPtr
epistemic_wal_log_evict(Relation rel, ItemPointer loser, ItemPointer winner,
						TimestampTz close_ts, uint8 reason)
{
	xl_epistemic_evict xlrec;

	memset(&xlrec, 0, sizeof(xlrec));
	xlrec.rlocator = rel->rd_locator;
	xlrec.loser_tid = *loser;
	xlrec.winner_tid = *winner;
	xlrec.close_ts = close_ts;
	xlrec.reason = reason;

	XLogBeginInsert();
	XLogRegisterData(&xlrec, SizeOfEpistemicEvict);

	return XLogInsert(RM_EPISTEMIC_ID, XLOG_EPISTEMIC_EVICT);
}

XLogRecPtr
epistemic_wal_log_audit(Relation audit_rel, ItemPointer new_tid, uint8 reason,
						const char *payload, uint16 payload_len)
{
	xl_epistemic_audit xlrec;

	memset(&xlrec, 0, sizeof(xlrec));
	xlrec.rlocator = audit_rel->rd_locator;
	xlrec.offnum = ItemPointerGetOffsetNumber(new_tid);
	xlrec.payload_len = payload_len;
	xlrec.reason = reason;

	XLogBeginInsert();
	XLogRegisterData(&xlrec, SizeOfEpistemicAudit);
	if (payload != NULL && payload_len > 0)
		XLogRegisterData(unconstify(char *, payload), payload_len);

	return XLogInsert(RM_EPISTEMIC_ID, XLOG_EPISTEMIC_AUDIT);
}
