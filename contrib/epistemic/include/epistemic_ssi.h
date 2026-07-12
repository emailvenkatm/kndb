/*
 * epistemic_ssi.h
 *
 * SSI predicate-locking wrappers for the epistemic AM. These are the
 * hooks that close the READ COMMITTED write-write race the plpgsql
 * implementation cannot: on precedence conflict, the incoming
 * transaction takes a predicate lock on the slot before scanning
 * live overlaps, and CheckForSerializableConflictIn is called when
 * we detect that another serializable transaction has read the
 * value about to be evicted.
 *
 * Owner: Agent D (SSI concurrency).
 */
#ifndef EPISTEMIC_SSI_H
#define EPISTEMIC_SSI_H

#include "postgres.h"
#include "storage/itemptr.h"
#include "utils/rel.h"
#include "utils/snapshot.h"
#include "access/xact.h"

/*
 * Predicate-lock the "logical slot" identified by (entity_id, attribute,
 * valid_time). The PoC hashes this triple to a synthetic ItemPointer
 * under a dedicated relation so we can use the existing SSI machinery
 * without inventing a new lock manager.
 */
extern void epistemic_predicate_lock_slot(Relation rel,
										  int32 entity_id,
										  const char *attribute,
										  int64 valid_lower,
										  int64 valid_upper,
										  Snapshot snapshot);

/*
 * Predicate-lock a specific tuple we're about to evict. Wraps
 * PredicateLockTID directly; provided for uniformity with
 * epistemic_predicate_lock_slot() callers.
 */
extern void epistemic_predicate_lock_tid(Relation rel,
										 ItemPointer tid,
										 Snapshot snapshot,
										 TransactionId tuple_xid);

/*
 * Check for a serializable conflict against another transaction that
 * has locked the slot. Called immediately before the lattice-driven
 * UPDATE that closes the loser's sys_time.
 */
extern void epistemic_check_serializable_conflict(Relation rel,
												  ItemPointer tid,
												  BlockNumber blkno);

#endif   /* EPISTEMIC_SSI_H */
