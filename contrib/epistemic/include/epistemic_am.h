/*
 * epistemic_am.h
 *
 * Table AM handler for the epistemic AM. Registered via the SQL
 * CREATE ACCESS METHOD declaration in epistemic--1.0.sql.
 *
 * Owner: Agent A (TAM storage layer).
 */
#ifndef EPISTEMIC_AM_H
#define EPISTEMIC_AM_H

#include "postgres.h"
#include "fmgr.h"
#include "access/tableam.h"

/*
 * SQL entry point. Returns a TableAmRoutine constructed by
 * BuildEpistemicAmRoutine(). The TableAmRoutine itself has static
 * storage in epistemic_am.c.
 */
extern Datum epistemic_am_handler(PG_FUNCTION_ARGS);

/*
 * Shared insert path used by both tuple_insert and multi_insert. It
 * runs R1-R5 (via epistemic_rules.c), acquires an SSI predicate lock
 * (via epistemic_ssi.c), takes the buffer lock, runs the precedence
 * lattice against overlapping live tuples, emits either an insert or
 * an evict WAL record (via epistemic_wal.c), and returns the resulting
 * ItemPointer.
 *
 * Returns InvalidBlockNumber/InvalidOffsetNumber on rejection; the
 * caller is expected to ereport().
 */
extern ItemPointerData epistemic_insert_tuple(Relation rel,
											  TupleTableSlot *slot,
											  CommandId cid,
											  int options);

#endif   /* EPISTEMIC_AM_H */
