/*
 * epistemic_rules.c
 *
 * Write-time rules R1..R5 and the precedence lattice. Rules read the
 * incoming slot's user columns (EP_ATTR_ENTITY_ID..EP_ATTR_SYS_TIME
 * from epistemic.h) plus the three meta columns kind/specificity/
 * confidence at EP_ATTR_SYS_TIME + 1..3.
 *
 * Precedence tie policy on the serial-arrival path is
 * arrival-order-wins: a second insert with identical
 * (kind, specificity, confidence) supersedes the first
 * (EP_CMP_NEW_WINS with reason EP_REASON_CONTRADICTED_SAME_RANK,
 * cmp fn at bottom of file). Under concurrent inserts the tie
 * branch is unreachable; outcome is decided by isolation-level
 * plumbing (SSI abort under SERIALIZABLE, no protection under
 * READ COMMITTED). See DECISIONS.md (F4) for the audit.
 */
#include "postgres.h"
#include "fmgr.h"
#include "access/htup_details.h"
#include "access/tupdesc.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

#include "epistemic.h"
#include "epistemic_rules.h"
#include "epistemic_precedence.h"

/* Meta columns follow the six user columns; positions locked. */
#define EP_ATTR_KIND			(EP_ATTR_SYS_TIME + 1)	/* int1/char */
#define EP_ATTR_SPECIFICITY		(EP_ATTR_SYS_TIME + 2)	/* int2 */
#define EP_ATTR_CONFIDENCE		(EP_ATTR_SYS_TIME + 3)	/* float4 */

PG_FUNCTION_INFO_V1(epistemic_cmp_test);

/* -------------------------------------------------------------- */
/* Slot access helpers.                                            */
/* -------------------------------------------------------------- */

static bool
slot_has_attr(TupleTableSlot *slot, int attnum)
{
	return slot != NULL
		&& slot->tts_tupleDescriptor != NULL
		&& slot->tts_tupleDescriptor->natts >= attnum;
}

static EpistemicKind
slot_get_kind(TupleTableSlot *slot, bool *isnull)
{
	Datum		d = slot_getattr(slot, EP_ATTR_KIND, isnull);

	if (*isnull)
		return EK_INVALID;
	return epistemic_kind_from_byte((uint8) DatumGetChar(d));
}

static bool
sources_is_empty(TupleTableSlot *slot, bool *isnull)
{
	Datum		d;
	Form_pg_attribute att;

	d = slot_getattr(slot, EP_ATTR_SOURCES, isnull);
	if (*isnull)
		return true;

	att = TupleDescAttr(slot->tts_tupleDescriptor, EP_ATTR_SOURCES - 1);

	/* Array types: check element count. */
	if (att->attndims > 0 || type_is_array(att->atttypid))
	{
		ArrayType  *arr = DatumGetArrayTypeP(d);

		if (ARR_NDIM(arr) == 0)
			return true;
		return ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr)) == 0;
	}

	/* bytea and other varlena: check payload length. */
	if (att->attlen == -1)
	{
		struct varlena *v = PG_DETOAST_DATUM_PACKED(d);

		return VARSIZE_ANY_EXHDR(v) == 0;
	}

	return false;
}

/* -------------------------------------------------------------- */
/* Rules R1..R5.                                                  */
/* -------------------------------------------------------------- */

bool
epistemic_check_r1(TupleTableSlot *slot)
{
	bool		isnull;
	EpistemicKind k;

	if (!slot_has_attr(slot, EP_ATTR_KIND) ||
		!slot_has_attr(slot, EP_ATTR_SOURCES))
	{
		elog(DEBUG1, "R1 skipped: slot missing attribute %d", EP_ATTR_KIND);
		return true;
	}

	k = slot_get_kind(slot, &isnull);
	if (isnull || k != EK_DERIVED)
		return true;

	if (sources_is_empty(slot, &isnull))
		return false;
	return true;
}

/*
 * R2: every non-NULL element of `sources` must resolve against
 * epistemic.source_registry. MEASURED short-circuits to true (R3
 * owns the "no sources" side). NULL/empty sources fail for
 * INFERRED/DERIVED. A single SPI query counts registered matches
 * with `= ANY($1::text[])` and compares to the array's non-NULL
 * element count; NULL elements are treated as unregistered.
 */
bool
epistemic_check_r2(Relation rel, TupleTableSlot *slot)
{
	bool		isnull;
	EpistemicKind k;
	Datum		sources_datum;
	Form_pg_attribute att;
	ArrayType  *arr;
	Datum	   *elems;
	bool	   *elem_nulls;
	int			nelems;
	int			non_null_count = 0;
	int			i;
	Oid			argtypes[1] = { TEXTARRAYOID };
	Datum		values[1];
	int			ret;
	int64		matched = 0;
	bool		ok;

	(void) rel;

	if (!slot_has_attr(slot, EP_ATTR_KIND) ||
		!slot_has_attr(slot, EP_ATTR_SOURCES))
	{
		elog(DEBUG1, "R2 skipped: slot missing attribute %d", EP_ATTR_KIND);
		return true;
	}

	k = slot_get_kind(slot, &isnull);
	if (isnull || k == EK_MEASURED)
		return true;

	sources_datum = slot_getattr(slot, EP_ATTR_SOURCES, &isnull);
	if (isnull)
		return false;

	att = TupleDescAttr(slot->tts_tupleDescriptor, EP_ATTR_SOURCES - 1);
	if (!(att->attndims > 0 || type_is_array(att->atttypid)))
	{
		elog(DEBUG1, "R2 skipped: sources attribute is not an array type");
		return true;
	}

	arr = DatumGetArrayTypeP(sources_datum);
	if (ARR_NDIM(arr) == 0 ||
		ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr)) == 0)
		return false;

	deconstruct_array(arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &elems, &elem_nulls, &nelems);

	for (i = 0; i < nelems; i++)
	{
		if (!elem_nulls[i])
			non_null_count++;
	}

	/*
	 * NULL elements are conservatively treated as unregistered: a NULL
	 * source cannot resolve to any registry row, so it fails R2.
	 */
	if (non_null_count < nelems)
		return false;

	values[0] = sources_datum;

	if ((ret = SPI_connect()) < 0)
		elog(ERROR, "SPI_connect failed: %d", ret);

	ret = SPI_execute_with_args(
		"SELECT count(*) FROM epistemic.source_registry "
		"WHERE source_id = ANY($1::text[])",
		1, argtypes, values, NULL, true, 1);

	if (ret != SPI_OK_SELECT)
	{
		SPI_finish();
		elog(ERROR, "R2 SPI_execute failed: %d", ret);
	}

	if (SPI_processed == 1)
	{
		bool		cnt_isnull;
		Datum		cnt_d;

		cnt_d = SPI_getbinval(SPI_tuptable->vals[0],
							  SPI_tuptable->tupdesc, 1, &cnt_isnull);
		if (!cnt_isnull)
			matched = DatumGetInt64(cnt_d);
	}

	SPI_finish();

	ok = (matched >= (int64) non_null_count);
	return ok;
}

bool
epistemic_check_r3(TupleTableSlot *slot)
{
	bool		isnull;
	EpistemicKind k;

	if (!slot_has_attr(slot, EP_ATTR_KIND) ||
		!slot_has_attr(slot, EP_ATTR_SOURCES))
	{
		elog(DEBUG1, "R3 skipped: slot missing attribute %d", EP_ATTR_KIND);
		return true;
	}

	k = slot_get_kind(slot, &isnull);
	if (isnull || k != EK_MEASURED)
		return true;

	return sources_is_empty(slot, &isnull);
}

bool
epistemic_check_r4(TupleTableSlot *slot)
{
	bool		isnull;
	EpistemicKind k;
	Datum		d;
	float4		conf;

	if (!slot_has_attr(slot, EP_ATTR_KIND) ||
		!slot_has_attr(slot, EP_ATTR_CONFIDENCE))
	{
		elog(DEBUG1, "R4 skipped: slot missing attribute %d", EP_ATTR_CONFIDENCE);
		return true;
	}

	k = slot_get_kind(slot, &isnull);
	if (isnull || k != EK_INFERRED)
		return true;

	d = slot_getattr(slot, EP_ATTR_CONFIDENCE, &isnull);
	if (isnull)
		return false;
	conf = DatumGetFloat4(d);
	return conf >= 0.0f && conf < 1.0f;
}

bool
epistemic_check_r5(Relation rel, TupleTableSlot *slot)
{
	bool		isnull;
	EpistemicKind slot_kind;
	Datum		attr_datum;
	Oid			argtypes[1] = { TEXTOID };
	Datum		values[1];
	int			ret;
	bool		ok = true;

	(void) rel;

	if (!slot_has_attr(slot, EP_ATTR_ATTRIBUTE) ||
		!slot_has_attr(slot, EP_ATTR_KIND))
	{
		elog(DEBUG1, "R5 skipped: slot missing attribute %d", EP_ATTR_ATTRIBUTE);
		return true;
	}

	attr_datum = slot_getattr(slot, EP_ATTR_ATTRIBUTE, &isnull);
	if (isnull)
		return true;

	slot_kind = slot_get_kind(slot, &isnull);
	if (isnull)
		return true;

	values[0] = attr_datum;

	if ((ret = SPI_connect()) < 0)
		elog(ERROR, "SPI_connect failed: %d", ret);

	ret = SPI_execute_with_args(
		"SELECT required_kind FROM epistemic.slot_kind WHERE attribute = $1",
		1, argtypes, values, NULL, true, 1);

	if (ret != SPI_OK_SELECT)
	{
		SPI_finish();
		elog(ERROR, "R5 SPI_execute failed: %d", ret);
	}

	if (SPI_processed == 1)
	{
		bool		req_isnull;
		Datum		req_d;
		EpistemicKind required;

		req_d = SPI_getbinval(SPI_tuptable->vals[0],
							  SPI_tuptable->tupdesc, 1, &req_isnull);
		if (!req_isnull)
		{
			required = epistemic_kind_from_byte((uint8) DatumGetChar(req_d));
			ok = (required == slot_kind);
		}
	}

	SPI_finish();
	return ok;
}

EpistemicRule
epistemic_check_rules(Relation rel, TupleTableSlot *slot)
{
	if (!epistemic_check_r1(slot))
		return EP_RULE_R1;
	if (!epistemic_check_r2(rel, slot))
		return EP_RULE_R2;
	if (!epistemic_check_r3(slot))
		return EP_RULE_R3;
	if (!epistemic_check_r4(slot))
		return EP_RULE_R4;
	if (!epistemic_check_r5(rel, slot))
		return EP_RULE_R5;
	return EP_RULE_NONE;
}

const char *
epistemic_rule_label(EpistemicRule r)
{
	switch (r)
	{
		case EP_RULE_R1: return "R1 (DERIVED sources)";
		case EP_RULE_R2: return "R2 (source resolution)";
		case EP_RULE_R3: return "R3 (MEASURED no sources)";
		case EP_RULE_R4: return "R4 (INFERRED confidence < 1.0)";
		case EP_RULE_R5: return "R5 (slot kind)";
		default:         return "none";
	}
}

/* -------------------------------------------------------------- */
/* Precedence lattice.                                            */
/* -------------------------------------------------------------- */

int
epistemic_kind_rank(EpistemicKind k)
{
	switch (k)
	{
		case EK_MEASURED: return 3;
		case EK_DERIVED:  return 2;
		case EK_INFERRED: return 1;
		default:          return 0;
	}
}

EpistemicCmpResult
epistemic_precedence_cmp(const EpistemicMeta *incumbent,
						 const EpistemicMeta *new)
{
	EpistemicCmpResult r;
	int			inc_rank = epistemic_kind_rank(
		epistemic_kind_from_byte(incumbent->ep_kind));
	int			new_rank = epistemic_kind_rank(
		epistemic_kind_from_byte(new->ep_kind));

	if (new_rank < inc_rank)
	{
		r.outcome = EP_CMP_NEW_LOSES;
		r.reason = EP_REASON_KIND_OUTRANKED;
		return r;
	}

	if (new_rank == inc_rank)
	{
		if (new->ep_specificity < incumbent->ep_specificity)
		{
			r.outcome = EP_CMP_NEW_LOSES;
			r.reason = EP_REASON_SPECIFICITY;
			return r;
		}
		if (new->ep_specificity == incumbent->ep_specificity &&
			new->ep_confidence < incumbent->ep_confidence)
		{
			r.outcome = EP_CMP_NEW_LOSES;
			r.reason = EP_REASON_CONFIDENCE;
			return r;
		}
		if (new->ep_specificity == incumbent->ep_specificity &&
			new->ep_confidence == incumbent->ep_confidence)
		{
			r.outcome = EP_CMP_NEW_WINS;
			r.reason = EP_REASON_CONTRADICTED_SAME_RANK;
			return r;
		}
	}

	r.outcome = EP_CMP_NEW_WINS;
	r.reason = EP_REASON_NONE;
	return r;
}

const char *
epistemic_precedence_reason_label(EpistemicPrecedenceReason r)
{
	switch (r)
	{
		case EP_REASON_KIND_OUTRANKED: return "kind_outranked";
		case EP_REASON_SPECIFICITY:    return "specificity";
		case EP_REASON_CONFIDENCE:     return "confidence";
		case EP_REASON_CONTRADICTED_SAME_RANK: return "contradicted_same_rank";
		default:                        return "none";
	}
}

/* -------------------------------------------------------------- */
/* Test-only helper for sql/precedence.sql.                       */
/* -------------------------------------------------------------- */

Datum
epistemic_cmp_test(PG_FUNCTION_ARGS)
{
	EpistemicMeta incumbent;
	EpistemicMeta newp;
	EpistemicCmpResult res;
	char		buf[64];

	incumbent.ep_kind = (uint8) PG_GETARG_INT32(0);
	incumbent.ep_flags = 0;
	incumbent.ep_specificity = (uint16) PG_GETARG_INT32(1);
	incumbent.ep_confidence = PG_GETARG_FLOAT4(2);

	newp.ep_kind = (uint8) PG_GETARG_INT32(3);
	newp.ep_flags = 0;
	newp.ep_specificity = (uint16) PG_GETARG_INT32(4);
	newp.ep_confidence = PG_GETARG_FLOAT4(5);

	res = epistemic_precedence_cmp(&incumbent, &newp);

	snprintf(buf, sizeof(buf), "%s(%s)",
			 res.outcome == EP_CMP_NEW_WINS ? "NEW_WINS" : "NEW_LOSES",
			 epistemic_precedence_reason_label(res.reason));

	PG_RETURN_TEXT_P(cstring_to_text(buf));
}
