# contrib/epistemic/Makefile
#
# Standard PGXS build for the epistemic table AM PoC. Targets PostgreSQL 18.
# Requires `pg_config` on PATH for the target install.

MODULE_big	= epistemic

OBJS = \
	src/epistemic_init.o \
	src/epistemic_am.o \
	src/epistemic_tuple.o \
	src/epistemic_wal.o \
	src/epistemic_type.o \
	src/epistemic_rules.o \
	src/epistemic_ssi.o

EXTENSION	= epistemic
DATA		= epistemic--1.0.sql
PGFILEDESC	= "epistemic - native epistemic typing table AM (PoC)"

REGRESS			= type precedence wal ssi am_basic
REGRESS_OPTS	= --load-extension=epistemic

TAP_TESTS = 1

PG_CPPFLAGS = -I$(srcdir)/include

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
