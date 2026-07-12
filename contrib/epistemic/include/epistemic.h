/*
 * epistemic.h
 *
 * Cross-module contract for the epistemic table AM PoC.
 *
 * On disk, an epistemic row is a plain heap tuple. Storage is heap's;
 * there is no hidden prefix, no reserved header bytes, and no
 * AM-private on-disk format. The AM's contribution at write time is
 * the tuple_insert callback (see src/epistemic_am.c): it runs R1..R5,
 * probes for an overlapping live row, applies the precedence lattice,
 * and delegates the actual insert to heapam. Every other TableAmRoutine
 * callback delegates verbatim to heapam. See DECISIONS.md (F3 audit)
 * for the disable-and-retest proof that durability comes from heap.
 *
 * The three "meta" columns kind/specificity/confidence live at fixed
 * user-attribute positions after sys_time (EP_ATTR_KIND et al. in
 * epistemic_am.c). EpistemicMeta below is an in-memory carrier for
 * those three values; it is not an on-disk struct.
 */
#ifndef EPISTEMIC_H
#define EPISTEMIC_H

#include "postgres.h"
#include "access/htup.h"
#include "access/htup_details.h"
#include "storage/itemptr.h"

/*
 * Epistemic kind. Stored on disk as a single pass-by-value byte (see
 * epistemic--1.0.sql for the base type). Byte values match the enum.
 */
typedef enum EpistemicKind
{
	EK_MEASURED = 0,
	EK_INFERRED = 1,
	EK_DERIVED  = 2,
	EK_INVALID  = 0xFF
} EpistemicKind;

/*
 * In-memory carrier for the (kind, specificity, confidence) triple that
 * the precedence lattice and the WAL annotation record operate on.
 * Constructed by extract_prefix() in epistemic_am.c from the incoming
 * slot's user columns; never read from disk directly.
 */
typedef struct EpistemicMeta
{
	uint8		ep_kind;			/* EpistemicKind cast to uint8 */
	uint8		ep_flags;			/* reserved: use 0 */
	uint16		ep_specificity;		/* 0-255 (uint16 for alignment) */
	float4		ep_confidence;		/* [0.0, 1.0] */
} EpistemicMeta;

/*
 * User-visible column positions in an epistemic relation. The DDL must
 * declare these columns in this order; the AM reads them by attnum.
 * The three meta columns (kind, specificity, confidence) follow at
 * EP_ATTR_SYS_TIME + 1..3 (defined locally in epistemic_am.c and
 * epistemic_rules.c because they are only referenced from those files).
 */
#define EP_ATTR_ENTITY_ID	1
#define EP_ATTR_ATTRIBUTE	2
#define EP_ATTR_VALUE		3
#define EP_ATTR_SOURCES		4			/* uuid[] or bytea, AM-defined */
#define EP_ATTR_VALID_TIME	5			/* tstzrange */
#define EP_ATTR_SYS_TIME	6			/* tstzrange */

/* Safe kind cast from raw byte. */
static inline EpistemicKind
epistemic_kind_from_byte(uint8 b)
{
	return (b <= EK_DERIVED) ? (EpistemicKind) b : EK_INVALID;
}

/* Human-readable label for logs / errors. */
static inline const char *
epistemic_kind_label(EpistemicKind k)
{
	switch (k)
	{
		case EK_MEASURED: return "MEASURED";
		case EK_INFERRED: return "INFERRED";
		case EK_DERIVED:  return "DERIVED";
		default:          return "INVALID";
	}
}

/* Extension init: called at load time by dlopen via PostgreSQL. */
extern void _PG_init(void);

#endif   /* EPISTEMIC_H */
