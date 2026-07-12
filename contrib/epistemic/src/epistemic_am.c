/*
 * epistemic_am.c
 *
 * Stub — Agent A (TAM storage layer) will replace this file. Prototypes
 * in include/epistemic_am.h are frozen.
 */
#include "postgres.h"
#include "fmgr.h"
#include "access/tableam.h"

#include "epistemic_am.h"

PG_FUNCTION_INFO_V1(epistemic_am_handler);

Datum
epistemic_am_handler(PG_FUNCTION_ARGS)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("epistemic table AM not implemented"),
			 errhint("Agent A owns src/epistemic_am.c.")));
	PG_RETURN_POINTER(NULL);
}

ItemPointerData
epistemic_insert_tuple(Relation rel, TupleTableSlot *slot,
					   CommandId cid, int options)
{
	ItemPointerData tid;

	ItemPointerSetInvalid(&tid);
	elog(ERROR, "epistemic_insert_tuple not implemented");
	return tid;
}
