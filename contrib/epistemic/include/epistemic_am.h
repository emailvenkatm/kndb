/*
 * epistemic_am.h
 *
 * Table AM handler for the epistemic AM. Registered via the SQL
 * CREATE ACCESS METHOD declaration in epistemic--1.0.sql.
 */
#ifndef EPISTEMIC_AM_H
#define EPISTEMIC_AM_H

#include "postgres.h"
#include "fmgr.h"
#include "access/tableam.h"

extern Datum epistemic_am_handler(PG_FUNCTION_ARGS);

#endif   /* EPISTEMIC_AM_H */
