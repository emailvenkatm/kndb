/*
 * epistemic_wal.h
 *
 * WAL record types and resource manager for the epistemic AM.
 * Frozen: record layout MUST remain binary-stable so redo can decode
 * XLOG records written by earlier revisions of the extension.
 *
 * Owner: Agent B (WAL resource manager).
 */
#ifndef EPISTEMIC_WAL_H
#define EPISTEMIC_WAL_H

#include "postgres.h"
#include "access/xlog.h"
#include "access/xlogreader.h"
#include "access/xlog_internal.h"
#include "access/rmgr.h"
#include "storage/buf.h"
#include "storage/itemptr.h"
#include "storage/relfilelocator.h"
#include "utils/rel.h"

#include "epistemic.h"

/*
 * Rmgr id and record info bytes. RM_EPISTEMIC_ID is fixed at
 * RM_EXPERIMENTAL_ID (128) for the PoC; a production extension would
 * request a stable id via the PostgreSQL rmgr registry.
 */
#define RM_EPISTEMIC_ID			RM_EXPERIMENTAL_ID

#define XLOG_EPISTEMIC_INSERT	0x10
#define XLOG_EPISTEMIC_EVICT	0x20
#define XLOG_EPISTEMIC_AUDIT	0x30

/*
 * xl_epistemic_insert -- payload for a native tuple insert.
 * Immediately followed by the full tuple bytes.
 */
typedef struct xl_epistemic_insert
{
	RelFileLocator	rlocator;
	OffsetNumber	offnum;
	uint16			tuple_len;
	EpistemicPrefix	prefix;
	/* xl_epistemic_insert is followed by tuple_len bytes of tuple data */
} xl_epistemic_insert;

#define SizeOfEpistemicInsert	(offsetof(xl_epistemic_insert, prefix) + sizeof(EpistemicPrefix))

/*
 * xl_epistemic_evict -- lattice evicted an incumbent live tuple by
 * closing its sys_time upper bound. The evicted row itself is not
 * rewritten; we record enough to redo the sys_time close.
 */
typedef struct xl_epistemic_evict
{
	RelFileLocator	rlocator;
	ItemPointerData	loser_tid;
	ItemPointerData	winner_tid;
	TimestampTz		close_ts;			/* clock_timestamp() value used */
	uint8			reason;				/* EpistemicPrecedenceReason */
	uint8			padding[7];
} xl_epistemic_evict;

#define SizeOfEpistemicEvict	sizeof(xl_epistemic_evict)

/*
 * xl_epistemic_audit -- one row appended to epistemic.evicted_fact.
 * Followed by the JSONB payload.
 */
typedef struct xl_epistemic_audit
{
	RelFileLocator	rlocator;
	OffsetNumber	offnum;
	uint16			payload_len;
	uint8			reason;
	uint8			padding[3];
} xl_epistemic_audit;

#define SizeOfEpistemicAudit	(offsetof(xl_epistemic_audit, padding))

/*
 * Rmgr registration entry point. Called from _PG_init. Idempotent
 * against repeated LOAD via the extension mechanism.
 */
extern void epistemic_rmgr_register(void);

/* Rmgr callbacks. */
extern void epistemic_rm_redo(XLogReaderState *record);
extern void epistemic_rm_desc(StringInfo buf, XLogReaderState *record);
extern const char *epistemic_rm_identify(uint8 info);
extern void epistemic_rm_mask(char *pagedata, BlockNumber blkno);

/*
 * Convenience helpers used by epistemic_am.c to build records.
 * Return the XLogRecPtr of the written record so callers can use it
 * for XLogFlush() or LSN accounting.
 */
extern XLogRecPtr epistemic_wal_log_insert(Relation rel,
										   Buffer buffer,
										   ItemPointer tid,
										   const EpistemicPrefix *prefix,
										   const char *tuple,
										   uint16 tuple_len);

extern XLogRecPtr epistemic_wal_log_insert_marker(Relation rel,
												  ItemPointer tid,
												  const EpistemicPrefix *prefix);

extern XLogRecPtr epistemic_wal_log_evict(Relation rel,
										  ItemPointer loser,
										  ItemPointer winner,
										  TimestampTz close_ts,
										  uint8 reason);

extern XLogRecPtr epistemic_wal_log_audit(Relation audit_rel,
										  ItemPointer new_tid,
										  uint8 reason,
										  const char *payload,
										  uint16 payload_len);

#endif   /* EPISTEMIC_WAL_H */
