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

1. `make check` green (six regression suites).
2. `scripts/recovery.sh` round-trips a crash under
   `wal_consistency_checking = all` with no PANIC and exact row count.
3. `scripts/concurrency.sh` runs a two-session overlap under
   SERIALIZABLE against both fact_native and a scan-equipped
   fact_trigger; both paths abort at least one session. This is
   standard heapam SSI, inherited by both engines; it is not evidence
   of any epistemic-specific serialization mechanism.
4. `scripts/bypass.sh` runs an R3-violating insert under
   `ALTER TABLE ... DISABLE TRIGGER ALL` and under
   `SET session_replication_role = 'replica'`. The bad row lands on
   fact_trigger and is rejected on fact_native. This is the paper's
   load-bearing engine-in-storage claim: an AM's `tuple_insert`
   callback is not reachable from user-space trigger controls.

## Threat model for the bypass claim

The bypass claim assumes the attacker is a writer with INSERT and
ALTER TABLE on the target relation, or a role that can toggle
`session_replication_role`. It does not hold against the table owner,
who can `ALTER TABLE ... SET ACCESS METHOD heap` and rewrite the
table off the epistemic AM entirely. That is a schema-change threat,
distinct from the write-path bypass we demonstrate here; the paper
should state both scopes explicitly.

## What is load-bearing

The write-path claim depends on `epistemic_check_rules` being called
from inside `epistemic_tuple_insert_impl` before the heap insert. If
that call is removed, `scripts/bypass.sh` flips 4/4 fact_native
assertions from OK to FAIL — the R3-violating row lands on both
tables. Everything else in the AM (WAL markers, precedence eviction,
audit) is either delegated to heapam or exists for downstream
consumers, and is not what the bypass claim rides on.
