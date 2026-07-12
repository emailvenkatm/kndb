# contrib/epistemic/Makefile
#
# Standard PGXS build for the epistemic table AM PoC. Targets PostgreSQL 18.
# Requires `pg_config` on PATH for the target install.

MODULE_big	= epistemic

OBJS = \
	src/epistemic_init.o \
	src/epistemic_am.o \
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

.PHONY: check-e2e check-e2e-recovery check-e2e-concurrency check-e2e-bypass \
        check-e2e-crash check-e2e-tie check-e2e-rc check-e2e-det \
        check-e2e-dl

check-e2e-recovery:
	@echo "===> recovery.sh"
	@bash $(srcdir)/scripts/recovery.sh

check-e2e-concurrency:
	@echo "===> concurrency.sh"
	@bash $(srcdir)/scripts/concurrency.sh

check-e2e-bypass:
	@echo "===> bypass.sh"
	@bash $(srcdir)/scripts/bypass.sh

check-e2e-crash:
	@echo "===> crash_atomicity.sh"
	@bash $(srcdir)/scripts/crash_atomicity.sh

check-e2e-tie:
	@echo "===> tie_concurrency.sh"
	@bash $(srcdir)/scripts/tie_concurrency.sh

check-e2e-rc:
	@echo "===> rc_invariant.sh"
	@bash $(srcdir)/scripts/rc_invariant.sh

check-e2e-det:
	@echo "===> tie_determinism.sh"
	@bash $(srcdir)/scripts/tie_determinism.sh

check-e2e-dl:
	@echo "===> deadlock_detection.sh"
	@bash $(srcdir)/scripts/deadlock_detection.sh

check-e2e:
	@set -e; \
	rc_recovery=0; rc_concurrency=0; rc_bypass=0; rc_crash=0; rc_tie=0; \
	rc_rc=0; rc_det=0; rc_dl=0; \
	echo "===> recovery.sh"; \
	bash $(srcdir)/scripts/recovery.sh || rc_recovery=$$?; \
	echo "===> concurrency.sh"; \
	bash $(srcdir)/scripts/concurrency.sh || rc_concurrency=$$?; \
	echo "===> bypass.sh"; \
	bash $(srcdir)/scripts/bypass.sh || rc_bypass=$$?; \
	echo "===> crash_atomicity.sh"; \
	bash $(srcdir)/scripts/crash_atomicity.sh || rc_crash=$$?; \
	echo "===> tie_concurrency.sh"; \
	bash $(srcdir)/scripts/tie_concurrency.sh || rc_tie=$$?; \
	echo "===> rc_invariant.sh"; \
	bash $(srcdir)/scripts/rc_invariant.sh || rc_rc=$$?; \
	echo "===> tie_determinism.sh"; \
	bash $(srcdir)/scripts/tie_determinism.sh || rc_det=$$?; \
	echo "===> deadlock_detection.sh"; \
	bash $(srcdir)/scripts/deadlock_detection.sh || rc_dl=$$?; \
	echo "===> check-e2e summary: recovery=$$rc_recovery concurrency=$$rc_concurrency bypass=$$rc_bypass crash=$$rc_crash tie=$$rc_tie rc=$$rc_rc det=$$rc_det dl=$$rc_dl"; \
	if [ $$rc_recovery -eq 0 ] && [ $$rc_concurrency -eq 0 ] && [ $$rc_bypass -eq 0 ] && [ $$rc_crash -eq 0 ] && [ $$rc_tie -eq 0 ] && [ $$rc_rc -eq 0 ] && [ $$rc_det -eq 0 ] && [ $$rc_dl -eq 0 ]; then \
	    echo "check-e2e: PASS (8/8)"; exit 0; \
	else \
	    echo "check-e2e: FAIL"; \
	    [ $$rc_recovery -ne 0 ]    && exit $$rc_recovery; \
	    [ $$rc_concurrency -ne 0 ] && exit $$rc_concurrency; \
	    [ $$rc_bypass -ne 0 ]      && exit $$rc_bypass; \
	    [ $$rc_crash -ne 0 ]       && exit $$rc_crash; \
	    [ $$rc_tie -ne 0 ]         && exit $$rc_tie; \
	    [ $$rc_rc -ne 0 ]          && exit $$rc_rc; \
	    [ $$rc_det -ne 0 ]         && exit $$rc_det; \
	    exit $$rc_dl; \
	fi
