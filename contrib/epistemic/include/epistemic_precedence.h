/*
 * epistemic_precedence.h
 *
 * The precedence lattice: kind > specificity > confidence, with an
 * arrival tie-breaker for a true tie. Pure C over EpistemicPrefix.
 *
 * Owner: Agent C (type + rules).
 */
#ifndef EPISTEMIC_PRECEDENCE_H
#define EPISTEMIC_PRECEDENCE_H

#include "postgres.h"

#include "epistemic.h"

/*
 * Reason codes match the plpgsql implementation's audit-row labels
 * so tests written for the user-space engine port cleanly.
 */
typedef enum EpistemicPrecedenceReason
{
	EP_REASON_NONE = 0,
	EP_REASON_KIND_OUTRANKED = 1,
	EP_REASON_SPECIFICITY    = 2,
	EP_REASON_CONFIDENCE     = 3,
	EP_REASON_CONTRADICTED_SAME_RANK = 4
} EpistemicPrecedenceReason;

/*
 * Outcome of comparing an incoming write against an incumbent.
 * NEW_WINS -> caller evicts incumbent (close its sys_time) and inserts NEW.
 * NEW_LOSES -> caller refuses NEW with a check_violation error.
 */
typedef enum EpistemicCmpOutcome
{
	EP_CMP_NEW_WINS = 0,
	EP_CMP_NEW_LOSES = 1
} EpistemicCmpOutcome;

typedef struct EpistemicCmpResult
{
	EpistemicCmpOutcome		outcome;
	EpistemicPrecedenceReason reason;
} EpistemicCmpResult;

/*
 * Compare incumbent vs new epistemic prefixes; ties are broken by
 * arrival order (new wins on true tie, matching plpgsql).
 */
extern EpistemicCmpResult
epistemic_precedence_cmp(const EpistemicPrefix *incumbent,
						 const EpistemicPrefix *new);

/*
 * kind_rank(k): MEASURED=3, DERIVED=2, INFERRED=1. Exposed so tests
 * can assert the rank ordering without reproducing it.
 */
extern int epistemic_kind_rank(EpistemicKind k);

/* Reason label for audit rows / RAISE messages. */
extern const char *epistemic_precedence_reason_label(EpistemicPrecedenceReason r);

#endif   /* EPISTEMIC_PRECEDENCE_H */
