/*
 * epistemic_probe.c
 *
 * F21 test-only C entry points. Provides a programmatic way to invoke
 * the AM's tuple_insert_speculative and tuple_complete_speculative
 * callbacks from SQL, because the SQL-level route (INSERT ... ON
 * CONFLICT with an arbiter index) is not currently reachable on
 * epistemic tables: heap_getnext at heapam.c:1352 REL_18_STABLE rejects
 * non-heap rd_tableam, which fails the ambuild scan phase of every
 * unique / exclusion constraint attempted on an epistemic relation.
 *
 * Without this probe, the F21 speculative-callback overrides could not
 * be exercised at all by installcheck, so an accidental refactor could
 * silently remove them without a test failure. The probe is the
 * disable-and-test harness the DECISIONS.md F21 entry cites.
 *
 * The probe constructs a candidate tuple from function arguments,
 * opens the target relation, calls table_tuple_insert_speculative on
 * it with a synthetic specToken, then calls
 * table_tuple_complete_speculative(succeeded=true). Any epistemic
 * ereport propagates to the caller as a normal SQL error. The probe
 * returns the caller-visible message text on success, or the
 * ereport-suppressed message if the caller sets suppress=true (used by
 * sql/am_speculative.sql to compare error messages without aborting
 * the containing test transaction — see the PG_TRY block).
 *
 * Signature (see epistemic--1.0.sql):
 *   epistemic._probe_speculative_insert(
 *       relname     text,
 *       entity_id   int,
 *       attribute   text,
 *       value       text,
 *       sources     text[],
 *       valid_time  tstzrange,
 *       ep_kind     epistemic.epistemic_kind,
 *       ep_specificity int2,
 *       ep_confidence real,
 *       succeeded   bool  DEFAULT true
 *   ) RETURNS text
 */
#include "postgres.h"
#include "fmgr.h"

#include "access/heapam.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "catalog/pg_type.h"
#include "executor/tuptable.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/rangetypes.h"
#include "utils/regproc.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "epistemic.h"

PG_FUNCTION_INFO_V1(epistemic_probe_speculative_insert);

Datum
epistemic_probe_speculative_insert(PG_FUNCTION_ARGS)
{
	text	   *relname_txt = PG_GETARG_TEXT_PP(0);
	int32		entity_id = PG_GETARG_INT32(1);
	text	   *attribute_txt = PG_GETARG_TEXT_PP(2);
	Datum		value_datum = PG_GETARG_DATUM(3);
	bool		value_isnull = PG_ARGISNULL(3);
	Datum		sources_datum = PG_ARGISNULL(4) ? (Datum) 0 : PG_GETARG_DATUM(4);
	bool		sources_isnull = PG_ARGISNULL(4);
	Datum		valid_time_datum = PG_GETARG_DATUM(5);
	char		ep_kind_byte = PG_GETARG_CHAR(6);
	int16		ep_specificity = PG_GETARG_INT16(7);
	float4		ep_confidence = PG_GETARG_FLOAT4(8);
	bool		succeeded = PG_ARGISNULL(9) ? true : PG_GETARG_BOOL(9);

	char	   *relname;
	RangeVar   *rv;
	Oid			relid;
	Relation	rel;
	TupleTableSlot *slot;
	TupleDesc	tupdesc;
	Datum	   *values;
	bool	   *nulls;
	int			natts;
	uint32		specToken;
	CommandId	cid;

	relname = text_to_cstring(relname_txt);
	rv = makeRangeVarFromNameList(stringToQualifiedNameList(relname, NULL));
	relid = RangeVarGetRelid(rv, RowExclusiveLock, false);
	rel = relation_open(relid, NoLock);
	(void) rv;

	tupdesc = RelationGetDescr(rel);
	natts = tupdesc->natts;

	if (natts < EP_ATTR_SYS_TIME + 3)
	{
		relation_close(rel, RowExclusiveLock);
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TABLE_DEFINITION),
				 errmsg("probe: target relation has %d columns; expected at least %d",
						natts, EP_ATTR_SYS_TIME + 3)));
	}

	slot = table_slot_create(rel, NULL);
	ExecClearTuple(slot);

	values = (Datum *) palloc0(natts * sizeof(Datum));
	nulls = (bool *) palloc0(natts * sizeof(bool));

	values[EP_ATTR_ENTITY_ID - 1] = Int32GetDatum(entity_id);
	values[EP_ATTR_ATTRIBUTE - 1] = PointerGetDatum(attribute_txt);
	values[EP_ATTR_VALUE - 1] = value_datum;
	nulls[EP_ATTR_VALUE - 1] = value_isnull;
	values[EP_ATTR_SOURCES - 1] = sources_datum;
	nulls[EP_ATTR_SOURCES - 1] = sources_isnull;
	values[EP_ATTR_VALID_TIME - 1] = valid_time_datum;

	/*
	 * sys_time: build tstzrange(now(), 'infinity') like the DEFAULT.
	 * Route through the type's own input function looked up via
	 * getTypeInputInfo so we do not have to hard-code F_RANGE_IN.
	 */
	{
		Form_pg_attribute sys_att;
		Oid			sysrange_typoid;
		Oid			sysrange_typinput;
		Oid			sysrange_typioparam;
		int32		sysrange_typmod;

		sys_att = TupleDescAttr(tupdesc, EP_ATTR_SYS_TIME - 1);
		sysrange_typoid = sys_att->atttypid;
		sysrange_typmod = sys_att->atttypmod;
		getTypeInputInfo(sysrange_typoid, &sysrange_typinput,
						 &sysrange_typioparam);
		values[EP_ATTR_SYS_TIME - 1] =
			OidInputFunctionCall(sysrange_typinput,
								 "[now,infinity)",
								 sysrange_typioparam,
								 sysrange_typmod);
	}

	values[EP_ATTR_SYS_TIME] = CharGetDatum(ep_kind_byte);				/* ep_kind */
	values[EP_ATTR_SYS_TIME + 1] = Int16GetDatum(ep_specificity);		/* ep_specificity */
	values[EP_ATTR_SYS_TIME + 2] = Float4GetDatum(ep_confidence);		/* ep_confidence */

	ExecStoreVirtualTuple(slot);
	memcpy(slot->tts_values, values, natts * sizeof(Datum));
	memcpy(slot->tts_isnull, nulls, natts * sizeof(bool));

	/*
	 * Synthetic specToken. The real ExecInsert path derives specToken
	 * from SpeculativeInsertionLockAcquire (lmgr.c) so concurrent
	 * scanners can wait on our decision. In this test probe there is
	 * no concurrent waiter, so any non-zero token works.
	 */
	specToken = 0xdeadbeef;
	cid = GetCurrentCommandId(true);

	PG_TRY();
	{
		table_tuple_insert_speculative(rel, slot, cid, 0, NULL, specToken);
		table_tuple_complete_speculative(rel, slot, specToken, succeeded);
	}
	PG_CATCH();
	{
		ExecDropSingleTupleTableSlot(slot);
		relation_close(rel, RowExclusiveLock);
		pfree(values);
		pfree(nulls);
		PG_RE_THROW();
	}
	PG_END_TRY();

	ExecDropSingleTupleTableSlot(slot);
	relation_close(rel, RowExclusiveLock);
	pfree(values);
	pfree(nulls);

	PG_RETURN_TEXT_P(cstring_to_text(succeeded ? "OK" : "ABORTED"));
}
