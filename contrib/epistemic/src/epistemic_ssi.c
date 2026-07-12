/*
 * epistemic_ssi.c
 *
 * Stub — Agent D (SSI concurrency) will replace this file. No-op
 * bodies here would silently drop lock acquisitions, so every wrapper
 * elog(ERROR)s.
 */
#include "postgres.h"

#include "epistemic_ssi.h"

void
epistemic_predicate_lock_slot(Relation rel, int32 entity_id,
							  const char *attribute,
							  int64 valid_lower, int64 valid_upper,
							  Snapshot snapshot)
{
	elog(ERROR, "epistemic_predicate_lock_slot not implemented");
}

void
epistemic_predicate_lock_tid(Relation rel, ItemPointer tid,
							 Snapshot snapshot, TransactionId tuple_xid)
{
	elog(ERROR, "epistemic_predicate_lock_tid not implemented");
}

void
epistemic_check_serializable_conflict(Relation rel, ItemPointer tid,
									  BlockNumber blkno)
{
	elog(ERROR, "epistemic_check_serializable_conflict not implemented");
}
