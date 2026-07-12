/*
 * epistemic_rules.c
 *
 * Stub — Agent C (type + rules) will replace this file. Predicates
 * return true here so the skeleton links; every real rule must be
 * implemented before the AM is functional.
 */
#include "postgres.h"

#include "epistemic_rules.h"
#include "epistemic_precedence.h"

EpistemicRule
epistemic_check_rules(Relation rel, TupleTableSlot *slot)
{
	return EP_RULE_NONE;
}

bool epistemic_check_r1(TupleTableSlot *slot) { return true; }
bool epistemic_check_r2(Relation rel, TupleTableSlot *slot) { return true; }
bool epistemic_check_r3(TupleTableSlot *slot) { return true; }
bool epistemic_check_r4(TupleTableSlot *slot) { return true; }
bool epistemic_check_r5(Relation rel, TupleTableSlot *slot) { return true; }

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
epistemic_precedence_cmp(const EpistemicPrefix *incumbent,
						 const EpistemicPrefix *new)
{
	EpistemicCmpResult r = { EP_CMP_NEW_WINS, EP_REASON_NONE };
	(void) incumbent;
	(void) new;
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
