/*
 * epistemic_wal.c
 *
 * Stub — Agent B (WAL rmgr) will replace this file. The prototypes in
 * include/epistemic_wal.h are frozen; do not modify signatures without
 * coordinating on postgres-experiment.
 *
 * These no-op bodies exist only so the skeleton links; every function
 * that would touch WAL ereports so accidental runtime use is obvious.
 */
#include "postgres.h"
#include "access/xlog.h"
#include "utils/elog.h"

#include "epistemic_wal.h"

void
epistemic_rmgr_register(void)
{
	elog(LOG, "epistemic: rmgr registration is a stub");
}

void
epistemic_rm_redo(XLogReaderState *record)
{
	elog(ERROR, "epistemic_rm_redo not implemented");
}

void
epistemic_rm_desc(StringInfo buf, XLogReaderState *record)
{
	appendStringInfoString(buf, "epistemic rmgr (stub)");
}

const char *
epistemic_rm_identify(uint8 info)
{
	return NULL;
}

void
epistemic_rm_mask(char *pagedata, BlockNumber blkno)
{
	/* no-op */
}

XLogRecPtr
epistemic_wal_log_insert(Relation rel, Buffer buffer, ItemPointer tid,
						 const EpistemicPrefix *prefix,
						 const char *tuple, uint16 tuple_len)
{
	elog(ERROR, "epistemic_wal_log_insert not implemented");
	return InvalidXLogRecPtr;
}

XLogRecPtr
epistemic_wal_log_evict(Relation rel, ItemPointer loser, ItemPointer winner,
						TimestampTz close_ts, uint8 reason)
{
	elog(ERROR, "epistemic_wal_log_evict not implemented");
	return InvalidXLogRecPtr;
}

XLogRecPtr
epistemic_wal_log_audit(Relation audit_rel, ItemPointer new_tid, uint8 reason,
						const char *payload, uint16 payload_len)
{
	elog(ERROR, "epistemic_wal_log_audit not implemented");
	return InvalidXLogRecPtr;
}
