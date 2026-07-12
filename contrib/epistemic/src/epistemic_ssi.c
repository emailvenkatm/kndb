/*
 * epistemic_ssi.c
 *
 * SSI predicate-lock wrappers. Real bodies exist only when the current
 * transaction is at SERIALIZABLE isolation; otherwise every entry point
 * is a no-op so callers can invoke them unconditionally.
 *
 * The slot wrapper hashes the logical key (entity_id, attribute,
 * valid_lower, valid_upper) to a synthetic ItemPointer and locks that
 * TID against the caller's relation. Hash collisions produce false
 * conflicts, which is conservative (we may abort a serializable
 * transaction that would in fact have committed) and never unsafe.
 */
#include "postgres.h"

#include "access/xact.h"
#include "common/hashfn.h"
#include "lib/stringinfo.h"
#include "storage/block.h"
#include "storage/itemptr.h"
#include "storage/predicate.h"

#include "epistemic_ssi.h"

void
epistemic_predicate_lock_tid(Relation rel, ItemPointer tid,
							 Snapshot snapshot, TransactionId tuple_xid)
{
	if (!IsolationIsSerializable())
		return;

	PredicateLockTID(rel, tid, snapshot, tuple_xid);
}

void
epistemic_predicate_lock_slot(Relation rel, int32 entity_id,
							  const char *attribute,
							  int64 valid_lower, int64 valid_upper,
							  Snapshot snapshot)
{
	StringInfoData buf;
	uint32		h;
	BlockNumber blkno;
	OffsetNumber offnum;
	ItemPointerData tid;

	if (!IsolationIsSerializable())
		return;

	initStringInfo(&buf);
	appendBinaryStringInfo(&buf, (const char *) &entity_id, sizeof(entity_id));
	if (attribute != NULL)
		appendBinaryStringInfo(&buf, attribute, strlen(attribute));
	appendBinaryStringInfo(&buf, (const char *) &valid_lower, sizeof(valid_lower));
	appendBinaryStringInfo(&buf, (const char *) &valid_upper, sizeof(valid_upper));

	h = hash_bytes((const unsigned char *) buf.data, buf.len);
	pfree(buf.data);

	blkno = (BlockNumber) ((h >> 16) & 0xFFFF);
	offnum = (OffsetNumber) (h & 0xFFFF);

	if (blkno == 0)
		blkno = 1;
	if (offnum == 0)
		offnum = 1;

	ItemPointerSet(&tid, blkno, offnum);

	PredicateLockTID(rel, &tid, snapshot, InvalidTransactionId);
}

void
epistemic_check_serializable_conflict(Relation rel, ItemPointer tid,
									  BlockNumber blkno)
{
	if (!IsolationIsSerializable())
		return;

	CheckForSerializableConflictIn(rel, tid, blkno);
}
