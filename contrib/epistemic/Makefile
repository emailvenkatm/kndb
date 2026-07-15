# contrib/epistemic/Makefile
#
# Standard PGXS build for the epistemic table AM PoC. Targets PostgreSQL 18.
#
# F20 gotcha: on macOS with multiple PG installs (postgresql@17 and
# postgresql@18 both on PATH), the bare `pg_config` resolves to whichever
# formula was installed first, and PGXS's install target then writes the
# dylib into the WRONG pkglibdir. `installcheck` and every C-linked
# extension load will then silently pick up the stale dylib from the
# other install and the tests either flake or pass against dead code.
#
# We pin PG_CONFIG to the PG 18 formula path by default. Users on a
# non-Homebrew install can override on the command line:
#   make PG_CONFIG=/path/to/pg18/bin/pg_config install
# The `?=` form still lets the override work.

PG_CONFIG	?= /opt/homebrew/opt/postgresql@18/bin/pg_config

MODULE_big	= epistemic

OBJS = \
	src/epistemic_init.o \
	src/epistemic_am.o \
	src/epistemic_wal.o \
	src/epistemic_type.o \
	src/epistemic_rules.o \
	src/epistemic_probe.o

EXTENSION	= epistemic
DATA		= epistemic--1.0.sql
PGFILEDESC	= "epistemic - native epistemic typing table AM (PoC)"

REGRESS			= type precedence wal am_basic r2_sources am_eviction am_update_delete am_speculative
REGRESS_OPTS	= --load-extension=epistemic

TAP_TESTS = 1

PG_CPPFLAGS = -I$(srcdir)/include

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# ------------------------------------------------------------------
# Dylib hash guard.
#
# Three separate F-agents (F3, F8, F11) burned time chasing ghosts
# because the installed `epistemic.dylib` diverged from the source
# tree: the developer rebuilt local .o files, forgot to `make install`,
# and PGXS's `installcheck` happily loaded the STALE dylib from
# `$(pg_config --pkglibdir)`. We now hash every install and refuse to
# run tests when the installed dylib doesn't match.
#
# * `install-hash` records the SHA-256 of the just-installed dylib
#   into `.dylib.sha256` at the top of contrib/epistemic.
# * `install` is extended (via a post-recipe hook) to also run
#   `install-hash`, so any `make install` refreshes the recorded
#   digest.
# * `verify-dylib` calls scripts/verify_dylib.sh, which fails loudly
#   if `.dylib.sha256` disagrees with the digest of the installed
#   dylib.
# * Every `check-e2e*` target and bench orchestrator depends on
#   `verify-dylib`.
# ------------------------------------------------------------------

.PHONY: install-hash verify-dylib

install-hash:
	@if [ -f epistemic.dylib ]; then \
	    HASH=$$(shasum -a 256 epistemic.dylib | awk '{print $$1}'); \
	    printf '%s  epistemic.dylib\n' "$$HASH" > .dylib.sha256; \
	    echo "install-hash: wrote .dylib.sha256 ($$HASH)"; \
	else \
	    echo "install-hash: epistemic.dylib not built yet — run 'make' first" >&2; \
	    exit 1; \
	fi

# PGXS defines `install` as a real target (not phony), so append a
# post-recipe hook rather than trying to redefine it. This runs
# install-hash after every successful `make install`.
install: install-hash-post
install-hash-post: install-hash

verify-dylib:
	@bash $(srcdir)/scripts/verify_dylib.sh

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
        check-e2e-dl check-e2e-updforge check-e2e-delforge

check-e2e-recovery: verify-dylib
	@echo "===> recovery.sh"
	@bash $(srcdir)/scripts/recovery.sh

check-e2e-concurrency: verify-dylib
	@echo "===> concurrency.sh"
	@bash $(srcdir)/scripts/concurrency.sh

check-e2e-bypass: verify-dylib
	@echo "===> bypass.sh"
	@bash $(srcdir)/scripts/bypass.sh

check-e2e-crash: verify-dylib
	@echo "===> crash_atomicity.sh"
	@bash $(srcdir)/scripts/crash_atomicity.sh

check-e2e-tie: verify-dylib
	@echo "===> tie_concurrency.sh"
	@bash $(srcdir)/scripts/tie_concurrency.sh

check-e2e-rc: verify-dylib
	@echo "===> rc_invariant.sh"
	@bash $(srcdir)/scripts/rc_invariant.sh

check-e2e-det: verify-dylib
	@echo "===> tie_determinism.sh"
	@bash $(srcdir)/scripts/tie_determinism.sh

check-e2e-dl: verify-dylib
	@echo "===> deadlock_detection.sh"
	@bash $(srcdir)/scripts/deadlock_detection.sh

check-e2e-updforge: verify-dylib
	@echo "===> update_forgery.sh (F20)"
	@bash $(srcdir)/scripts/update_forgery.sh

check-e2e-delforge: verify-dylib
	@echo "===> delete_forgery.sh (F20)"
	@bash $(srcdir)/scripts/delete_forgery.sh

check-e2e: verify-dylib
	@set -e; \
	rc_recovery=0; rc_concurrency=0; rc_bypass=0; rc_crash=0; rc_tie=0; \
	rc_rc=0; rc_det=0; rc_dl=0; rc_upd=0; rc_del=0; \
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
	echo "===> update_forgery.sh (F20)"; \
	bash $(srcdir)/scripts/update_forgery.sh || rc_upd=$$?; \
	echo "===> delete_forgery.sh (F20)"; \
	bash $(srcdir)/scripts/delete_forgery.sh || rc_del=$$?; \
	echo "===> check-e2e summary: recovery=$$rc_recovery concurrency=$$rc_concurrency bypass=$$rc_bypass crash=$$rc_crash tie=$$rc_tie rc=$$rc_rc det=$$rc_det dl=$$rc_dl updforge=$$rc_upd delforge=$$rc_del"; \
	if [ $$rc_recovery -eq 0 ] && [ $$rc_concurrency -eq 0 ] && [ $$rc_bypass -eq 0 ] && [ $$rc_crash -eq 0 ] && [ $$rc_tie -eq 0 ] && [ $$rc_rc -eq 0 ] && [ $$rc_det -eq 0 ] && [ $$rc_dl -eq 0 ] && [ $$rc_upd -eq 0 ] && [ $$rc_del -eq 0 ]; then \
	    echo "check-e2e: PASS (10/10)"; exit 0; \
	else \
	    echo "check-e2e: FAIL"; \
	    [ $$rc_recovery -ne 0 ]    && exit $$rc_recovery; \
	    [ $$rc_concurrency -ne 0 ] && exit $$rc_concurrency; \
	    [ $$rc_bypass -ne 0 ]      && exit $$rc_bypass; \
	    [ $$rc_crash -ne 0 ]       && exit $$rc_crash; \
	    [ $$rc_tie -ne 0 ]         && exit $$rc_tie; \
	    [ $$rc_rc -ne 0 ]          && exit $$rc_rc; \
	    [ $$rc_det -ne 0 ]         && exit $$rc_det; \
	    [ $$rc_dl -ne 0 ]          && exit $$rc_dl; \
	    [ $$rc_upd -ne 0 ]         && exit $$rc_upd; \
	    exit $$rc_del; \
	fi
