/*
 * epistemic_wal.h
 *
 * Custom WAL resource manager for the epistemic AM. Registered at
 * RM_EPISTEMIC_ID (== RM_EXPERIMENTAL_ID = 128) from _PG_init.
 *
 * Scope after F3 audit: this rmgr is an ANNOTATION CHANNEL, not a
 * durability channel. Heap's own XLOG_HEAP_INSERT record carries the
 * full tuple body (including ep_kind, ep_specificity, ep_confidence,
 * sources — every user column) via XLogRegisterBufData; heap's WAL
 * plus heap_xlog_insert already recovers every byte of the row. The
 * epistemic record adds nothing to recovery. See DECISIONS.md (F3
 * entry) for the disable-and-retest proof and the PG 18 source
 * citations (heapam.c:2222-2226 in REL_18_STABLE for the register
 * calls, heapam_xlog.c:482-503 for the redo path).
 *
 * The rmgr is registered so that (a) pg_get_wal_resource_managers()
 * reports id 128 as 'epistemic' (verified by sql/wal.sql), and (b) the
 * annotation channel is reserved for a future consumer. rm_decode is
 * NULL, so logical decoding (decode.c:LogicalDecodingProcessRecord
 * skips records with a null rm_decode at lines 115-117) does not
 * surface the record. PG 18's standalone pg_waldump does not load
 * custom rmgrs, so external decoding is unavailable today; rm_desc is
 * reached only via in-process wal_debug tracing. No downstream
 * consumer exists.
 */
#ifndef EPISTEMIC_WAL_H
#define EPISTEMIC_WAL_H

#include "postgres.h"
#include "access/xlog.h"
#include "access/xlogreader.h"
#include "access/xlog_internal.h"
#include "access/rmgr.h"
#include "storage/itemptr.h"
#include "storage/relfilelocator.h"
#include "utils/rel.h"

#include "epistemic.h"

/*
 * Rmgr id and record info bytes. RM_EPISTEMIC_ID is fixed at
 * RM_EXPERIMENTAL_ID (128) for the PoC.
 */
#define RM_EPISTEMIC_ID			RM_EXPERIMENTAL_ID

#define XLOG_EPISTEMIC_INSERT	0x10

/*
 * xl_epistemic_insert -- annotation marker written after a heap insert.
 * Carries only the logical location (relation + offset) and the
 * epistemic prefix. tuple_len is always 0; no buffer reference is
 * registered. The record does NOT participate in redo of the row
 * itself; heap's XLOG_HEAP_INSERT does that.
 */
typedef struct xl_epistemic_insert
{
	RelFileLocator	rlocator;
	OffsetNumber	offnum;
	uint16			tuple_len;			/* always 0 for the annotation marker */
	EpistemicPrefix	prefix;
} xl_epistemic_insert;

#define SizeOfEpistemicInsert	(offsetof(xl_epistemic_insert, prefix) + sizeof(EpistemicPrefix))

/*
 * Rmgr registration entry point. Called from _PG_init. Requires that
 * the extension be loaded via shared_preload_libraries so
 * RegisterCustomRmgr's process_shared_preload_libraries_in_progress
 * check (rmgr.c:RegisterCustomRmgr) succeeds.
 */
extern void epistemic_rmgr_register(void);

/* Rmgr callbacks. */
extern void epistemic_rm_redo(XLogReaderState *record);
extern void epistemic_rm_desc(StringInfo buf, XLogReaderState *record);
extern const char *epistemic_rm_identify(uint8 info);
extern void epistemic_rm_mask(char *pagedata, BlockNumber blkno);

/*
 * The only surviving logger. Writes an annotation record naming the
 * new tuple's (rlocator, offnum) and its EpistemicPrefix. Does NOT
 * carry tuple bytes and does NOT register a buffer; the row's
 * durability lives in heap's WAL. Return value is the XLogRecPtr of
 * the emitted record.
 */
extern XLogRecPtr epistemic_wal_log_insert_marker(Relation rel,
												  ItemPointer tid,
												  const EpistemicPrefix *prefix);

#endif   /* EPISTEMIC_WAL_H */
