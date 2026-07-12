/*
 * epistemic.h
 *
 * Shared types for the epistemic table AM PoC. This header is the frozen
 * cross-module contract: EpistemicKind values, the fixed 8-byte on-disk
 * prefix, and the accessor macros.
 */
#ifndef EPISTEMIC_H
#define EPISTEMIC_H

#include "postgres.h"
#include "access/htup.h"
#include "access/htup_details.h"
#include "storage/itemptr.h"

/*
 * Epistemic kind. Encoded as a single byte on disk. Values match the
 * user-facing text produced by epistemic_kind_out().
 */
typedef enum EpistemicKind
{
	EK_MEASURED = 0,
	EK_INFERRED = 1,
	EK_DERIVED  = 2,
	EK_INVALID  = 0xFF
} EpistemicKind;

/*
 * Fixed 8-byte epistemic prefix stored at the start of the user data
 * area of every epistemic tuple, immediately after HeapTupleHeaderData.
 * Alignment must be 4-byte to satisfy float4 access.
 */
typedef struct EpistemicPrefix
{
	uint8		ep_kind;			/* EpistemicKind cast to uint8 */
	uint8		ep_flags;			/* reserved: use 0 */
	uint16		ep_specificity;		/* 0-255 (uint16 for alignment) */
	float4		ep_confidence;		/* [0.0, 1.0] */
} EpistemicPrefix;

StaticAssertDecl(sizeof(EpistemicPrefix) == 8,
				 "EpistemicPrefix must be 8 bytes; format is frozen");

/*
 * Byte offset of the epistemic prefix within a heap-formatted tuple.
 * Callers must ensure the tuple was written by the epistemic AM.
 */
#define EPISTEMIC_PREFIX_OFF(tup)	\
	(((char *) (tup)) + ((HeapTupleHeader) (tup))->t_hoff)

#define EPISTEMIC_PREFIX(tup)		\
	((EpistemicPrefix *) EPISTEMIC_PREFIX_OFF(tup))

/*
 * User-visible column layout in the epistemic AM. The DDL for an
 * epistemic relation must declare these columns in this order after
 * the hidden prefix.
 */
#define EP_ATTR_ENTITY_ID	1
#define EP_ATTR_ATTRIBUTE	2
#define EP_ATTR_VALUE		3
#define EP_ATTR_SOURCES		4			/* uuid[] or bytea, AM-defined */
#define EP_ATTR_VALID_TIME	5			/* tstzrange */
#define EP_ATTR_SYS_TIME	6			/* tstzrange */

/* Convenience: safe kind cast from raw byte. */
static inline EpistemicKind
epistemic_kind_from_byte(uint8 b)
{
	return (b <= EK_DERIVED) ? (EpistemicKind) b : EK_INVALID;
}

/* Convenience: human-readable label for logs/errors. */
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
