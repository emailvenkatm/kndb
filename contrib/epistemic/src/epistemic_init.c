/*
 * epistemic_init.c
 *
 * Extension load hook. Registers the custom WAL resource manager and
 * (in the future) any GUCs the extension exposes.
 */
#include "postgres.h"
#include "fmgr.h"

#include "epistemic.h"
#include "epistemic_wal.h"

PG_MODULE_MAGIC;

void
_PG_init(void)
{
	epistemic_rmgr_register();
}
