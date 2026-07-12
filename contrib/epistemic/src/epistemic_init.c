/*
 * epistemic_init.c
 *
 * Extension load hook. Registers the custom WAL resource manager
 * (rmgr id 128, annotation channel — see epistemic_wal.c). Must run
 * from shared_preload_libraries; RegisterCustomRmgr enforces this
 * via process_shared_preload_libraries_in_progress.
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
