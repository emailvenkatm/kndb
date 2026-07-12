/*
 * epistemic_type.c
 *
 * Stub — Agent C (type + rules) will replace this file. The SQL DDL
 * in epistemic--1.0.sql references these entry points.
 */
#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"

#include "epistemic.h"

PG_FUNCTION_INFO_V1(epistemic_kind_in);
PG_FUNCTION_INFO_V1(epistemic_kind_out);

Datum
epistemic_kind_in(PG_FUNCTION_ARGS)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("epistemic_kind input not implemented"),
			 errhint("Agent C owns src/epistemic_type.c.")));
	PG_RETURN_CHAR(EK_INVALID);
}

Datum
epistemic_kind_out(PG_FUNCTION_ARGS)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("epistemic_kind output not implemented"),
			 errhint("Agent C owns src/epistemic_type.c.")));
	PG_RETURN_CSTRING(pstrdup("INVALID"));
}
