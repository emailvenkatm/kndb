/*
 * epistemic_type.c
 *
 * I/O functions for the epistemic_kind base type. Storage is a single
 * pass-by-value byte matching EpistemicKind values. Text form is
 * case-insensitive on input and upper-case on output.
 */
#include "postgres.h"
#include "fmgr.h"
#include "port.h"
#include "utils/builtins.h"

#include "epistemic.h"

PG_FUNCTION_INFO_V1(epistemic_kind_in);
PG_FUNCTION_INFO_V1(epistemic_kind_out);

static bool
kind_equals_ci(const char *s, const char *lit)
{
	while (*s && *lit)
	{
		if (pg_ascii_toupper((unsigned char) *s) !=
			pg_ascii_toupper((unsigned char) *lit))
			return false;
		s++;
		lit++;
	}
	return *s == '\0' && *lit == '\0';
}

Datum
epistemic_kind_in(PG_FUNCTION_ARGS)
{
	char	   *str = PG_GETARG_CSTRING(0);
	EpistemicKind k;

	if (kind_equals_ci(str, "MEASURED"))
		k = EK_MEASURED;
	else if (kind_equals_ci(str, "INFERRED"))
		k = EK_INFERRED;
	else if (kind_equals_ci(str, "DERIVED"))
		k = EK_DERIVED;
	else
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("invalid epistemic_kind: \"%s\"", str)));

	PG_RETURN_CHAR((char) k);
}

Datum
epistemic_kind_out(PG_FUNCTION_ARGS)
{
	uint8		b = (uint8) PG_GETARG_CHAR(0);
	EpistemicKind k = epistemic_kind_from_byte(b);

	PG_RETURN_CSTRING(pstrdup(epistemic_kind_label(k)));
}
