# contrib/epistemic

Native C implementation of KNDB epistemic typing for PostgreSQL 18.4.
Proof-of-concept sufficient to answer "isn't this just a schema template
with triggers?" — no; the enforcement lives in the storage AM, the WAL
resource manager, and the SSI predicate-lock path.

## Layout

    include/
      epistemic.h              cross-module contract (frozen)
      epistemic_am.h           TAM handler prototype
      epistemic_wal.h          WAL record layout + rmgr entry points
      epistemic_rules.h        R1..R5 predicates
      epistemic_precedence.h   kind > specificity > confidence lattice
    src/
      epistemic_init.c         _PG_init (registers rmgr)
      epistemic_am.c           TAM callbacks
      epistemic_tuple.c        on-disk tuple format
      epistemic_wal.c          rmgr callbacks + builders
      epistemic_type.c         epistemic_kind C I/O
      epistemic_rules.c        R1..R5 + precedence lattice
    sql/ expected/ t/ bench/   regression + TAP

## Build

Assumes `pg_config` on `PATH` resolves to a PostgreSQL 18 install with
development headers.

    make
    make install
    make installcheck            # regression tests
    PROVE_TESTS='t/*.pl' make prove_installcheck   # TAP tests

`shared_preload_libraries = 'epistemic'` is required for the WAL rmgr
to be registered before recovery. This is set automatically by the TAP
tests via the `PostgreSQL::Test::Cluster` framework.

## Scope

Frozen for the PoC: the 8-byte `EpistemicPrefix` layout, the three WAL
record types (INSERT, EVICT, AUDIT), and the reason-code numbering.
Out of scope: vacuum semantics beyond delegated-to-heap, parallel
scan, TOAST, logical replication.

## Success metrics

1. `make check` green.
2. TAP recovery test round-trips a crash under
   `wal_consistency_checking = all`.
3. TAP concurrency test shows the native path rejects an interleaving
   the trigger-based version admits.
