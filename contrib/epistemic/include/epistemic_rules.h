/*
 * epistemic_rules.h
 *
 * R1..R5 as C predicates over an in-memory slot. Each returns true on
 * success (rule holds) and false on violation; the caller emits the
 * ereport with SQLSTATE.
 */
#ifndef EPISTEMIC_RULES_H
#define EPISTEMIC_RULES_H

#include "postgres.h"
#include "executor/tuptable.h"
#include "utils/rel.h"

#include "epistemic.h"

typedef enum EpistemicRule
{
	EP_RULE_NONE = 0,
	EP_RULE_R1,		/* DERIVED must have sources */
	EP_RULE_R2,		/* sources must resolve */
	EP_RULE_R3,		/* MEASURED must not have sources */
	EP_RULE_R4,		/* INFERRED confidence < 1.0 */
	EP_RULE_R5		/* slot-registered kind must match */
} EpistemicRule;

/*
 * Check all rules against a slot that has already been populated with
 * the incoming row's user attributes and epistemic prefix. Returns
 * EP_RULE_NONE on success, or the first failing rule; the caller
 * emits ereport(ERROR, ...) with an appropriate SQLSTATE.
 *
 * `rel` is the target relation; used by R2 (source resolution) and R5
 * (slot registry lookup).
 */
extern EpistemicRule epistemic_check_rules(Relation rel, TupleTableSlot *slot);

/* Individual rule entry points, mostly for unit tests. */
extern bool epistemic_check_r1(TupleTableSlot *slot);
extern bool epistemic_check_r2(Relation rel, TupleTableSlot *slot);
extern bool epistemic_check_r3(TupleTableSlot *slot);
extern bool epistemic_check_r4(TupleTableSlot *slot);
extern bool epistemic_check_r5(Relation rel, TupleTableSlot *slot);

/* Human-readable rule label used in RAISE messages. */
extern const char *epistemic_rule_label(EpistemicRule r);

#endif   /* EPISTEMIC_RULES_H */
