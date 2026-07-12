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
	src/epistemic_rules.o

EXTENSION	= epistemic
DATA		= epistemic--1.0.sql
PGFILEDESC	= "epistemic - native epistemic typing table AM (PoC)"

REGRESS			= type precedence wal am_basic r2_sources am_eviction
REGRESS_OPTS	= --load-extension=epistemic

TAP_TESTS = 1

PG_CPPFLAGS = -I$(srcdir)/include

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# ------------------------------------------------------------------
# Metric-1 (recovery) and Metric-2 (concurrency) end-to-end scripts.
#
# Not wired into `check` / `installcheck` on purpose: they spin their
# own isolated clusters (initdb into /tmp/kndb_e_*), so they don't need
# `--enable-tap-tests` or any of the PGXS test scaffolding — but they
# also should not run every time someone runs `make check` on a build
# machine that doesn't have `initdb` on PATH.
#
# Run explicitly with:  make -C contrib/epistemic check-e2e
# ------------------------------------------------------------------

.PHONY: check-e2e check-e2e-recovery check-e2e-concurrency

check-e2e-recovery:
	@echo "===> Metric 1: recovery.sh"
	@bash $(srcdir)/scripts/recovery.sh

check-e2e-concurrency:
	@echo "===> Metric 2: concurrency.sh"
	@bash $(srcdir)/scripts/concurrency.sh

check-e2e:
	@set -e; \
	rc_recovery=0; rc_concurrency=0; \
	echo "===> Metric 1: recovery.sh"; \
	bash $(srcdir)/scripts/recovery.sh || rc_recovery=$$?; \
	echo "===> Metric 2: concurrency.sh"; \
	bash $(srcdir)/scripts/concurrency.sh || rc_concurrency=$$?; \
	echo "===> check-e2e summary: recovery=$$rc_recovery concurrency=$$rc_concurrency"; \
	if [ $$rc_recovery -eq 0 ] && [ $$rc_concurrency -eq 0 ]; then \
	    echo "check-e2e: PASS"; exit 0; \
	elif [ $$rc_concurrency -eq 2 ]; then \
	    echo "check-e2e: PARTIAL (concurrency reported honest negative result, exit 2)"; \
	    exit $$rc_concurrency; \
	else \
	    echo "check-e2e: FAIL"; \
	    [ $$rc_recovery -ne 0 ] && exit $$rc_recovery; \
	    exit $$rc_concurrency; \
	fi
