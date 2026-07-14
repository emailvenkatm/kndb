#!/usr/bin/env bash
#
# scripts/verify_dylib.sh — guard against the "stale installed dylib"
# footgun that bit F3, F8, and F11.
#
# The failure mode: developer edits src/, runs `make` (rebuild only),
# forgets `make install`, then runs the test suite. Postgres keeps
# preloading the OLD installed .dylib because that's what `pg_config
# --pkglibdir` points at — the fresh object files at the tree root
# never get loaded. Every test passes against the STALE code. Three
# separate F-agents have chased ghosts because of this.
#
# The guard: `make install` writes the SHA-256 of the just-installed
# dylib into `.dylib.sha256`. This script checks TWO invariants:
#
#   1. installed  dylib hash == .dylib.sha256   (someone reinstalled
#                                                a different dylib
#                                                behind us — rare, but
#                                                catches concurrent
#                                                clobbers)
#   2. source-tree dylib hash == .dylib.sha256  (source was rebuilt
#                                                without `make install`
#                                                — the F3/F8/F11 case)
#
# If either fails, exit non-zero with a loud "REBUILD AND REINSTALL"
# message. Wired as a prerequisite of every `check-e2e*` target and
# every bench orchestrator in this contrib.
#
# Bash 3.2 compatible (macOS default).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

EXPECTED_FILE="${REPO_ROOT}/.dylib.sha256"

# Locate the installed dylib. Prefer the PG 18 keg if it's on disk;
# fall back to `pg_config --pkglibdir` if not, which mirrors the
# Makefile's own `pg_config` discovery.
if [ -z "${PG_PKGLIBDIR:-}" ]; then
    if [ -x /opt/homebrew/opt/postgresql@18/bin/pg_config ]; then
        PG_PKGLIBDIR="$(/opt/homebrew/opt/postgresql@18/bin/pg_config --pkglibdir)"
    else
        PG_PKGLIBDIR="$(pg_config --pkglibdir)"
    fi
fi

INSTALLED_DYLIB="${PG_PKGLIBDIR}/epistemic.dylib"
SOURCE_DYLIB="${REPO_ROOT}/epistemic.dylib"

# --------------------------------------------------------------------
# Complain-loudly helpers.
# --------------------------------------------------------------------

die() {
    printf '\n===> verify_dylib: FAIL\n'                                        >&2
    printf '     %s\n' "$1"                                                    >&2
    printf '\n'                                                                >&2
    printf '     To fix:  make -C contrib/epistemic clean install\n'           >&2
    printf '     Then retry your test / bench command.\n\n'                    >&2
    exit 1
}

# --------------------------------------------------------------------
# 1. Required inputs.
# --------------------------------------------------------------------

if [ ! -f "${EXPECTED_FILE}" ]; then
    die "no ${EXPECTED_FILE} on disk — this file is written by 'make install'. Run 'make -C contrib/epistemic install' at least once."
fi

if [ ! -f "${INSTALLED_DYLIB}" ]; then
    die "installed dylib not found at ${INSTALLED_DYLIB}. Check pg_config --pkglibdir (or export PG_PKGLIBDIR); run 'make install'."
fi

if [ ! -f "${SOURCE_DYLIB}" ]; then
    die "source-tree dylib not found at ${SOURCE_DYLIB}. Run 'make -C contrib/epistemic'."
fi

# --------------------------------------------------------------------
# 2. Compare hashes.
# --------------------------------------------------------------------

EXPECTED_HASH="$(awk '{print $1}' "${EXPECTED_FILE}")"
INSTALLED_HASH="$(shasum -a 256 "${INSTALLED_DYLIB}" | awk '{print $1}')"
SOURCE_HASH="$(shasum -a 256 "${SOURCE_DYLIB}" | awk '{print $1}')"

if [ "${EXPECTED_HASH}" != "${INSTALLED_HASH}" ]; then
    printf 'expected  (%s):  %s\n' "${EXPECTED_FILE}"   "${EXPECTED_HASH}"    >&2
    printf 'installed (%s):  %s\n' "${INSTALLED_DYLIB}" "${INSTALLED_HASH}"   >&2
    die "installed dylib SHA-256 does not match the last recorded install. Something clobbered ${INSTALLED_DYLIB} behind us."
fi

if [ "${EXPECTED_HASH}" != "${SOURCE_HASH}" ]; then
    printf 'expected  (%s):  %s\n' "${EXPECTED_FILE}"   "${EXPECTED_HASH}"    >&2
    printf 'source    (%s):  %s\n' "${SOURCE_DYLIB}"    "${SOURCE_HASH}"      >&2
    die "source-tree dylib SHA-256 does not match the last install. You rebuilt src/ without running 'make install' — Postgres is still preloading the STALE binary (this is the F3/F8/F11 recurring incident)."
fi

# --------------------------------------------------------------------
# 3. Success (quiet by default; verbose with V=1).
# --------------------------------------------------------------------

if [ "${V:-0}" != "0" ]; then
    printf '===> verify_dylib: OK (sha256=%s)\n' "${INSTALLED_HASH}"
fi
exit 0
