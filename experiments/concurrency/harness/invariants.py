"""Post-run invariant checks on the concurrency-experiment DB.

Each check is a pure SQL query. Any invariant violation is a first-class
correctness finding and must be surfaced in RESULTS.md with the exact
slot / entity_id involved.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

import psycopg


def _int_scalar(row_val) -> int:
    """ProvSQL wraps aggregate results as text like '8 (*)'. Strip the
    provenance marker and return an int either way.
    """
    if isinstance(row_val, int):
        return row_val
    s = str(row_val).strip()
    m = re.match(r"-?\d+", s)
    if not m:
        raise ValueError(f"cannot parse int from {s!r}")
    return int(m.group(0))


@dataclass
class InvariantResult:
    ok: bool
    label: str
    detail: str = ""
    offending_rows: list = field(default_factory=list)


def no_two_live_for_slot(
    conn: psycopg.Connection,
    entity_id: int,
    attribute: str,
) -> InvariantResult:
    """Exclusion invariant: at most one live row exists for any
    (entity_id, attribute) at a time in current sys_time.

    A tighter check would look at valid_time overlap; this loose form
    detects the common failure mode (two live rows for the same slot)
    which is the specific race the paper cares about.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT fact_id, value, epistemic_kind, confidence, valid_time
              FROM kndb.fact
             WHERE entity_id = %s
               AND attribute = %s
               AND upper(sys_time) = 'infinity'
            """,
            (entity_id, attribute),
        )
        rows = cur.fetchall()
    # rows[N][K] where the fetched row may contain ProvSQL-wrapped scalars
    # is fine here because we only compare len(rows) to constants, but keep the
    # detail-string safe by stringifying rather than arithmetic.
    if len(rows) > 1:
        return InvariantResult(
            ok=False,
            label="no_two_live_for_slot",
            detail=(
                f"entity_id={entity_id} attribute={attribute!r} has "
                f"{len(rows)} live rows; expected <= 1"
            ),
            offending_rows=rows,
        )
    return InvariantResult(ok=True, label="no_two_live_for_slot")


def live_kind_is(
    conn: psycopg.Connection,
    entity_id: int,
    attribute: str,
    expected_kind: str,
) -> InvariantResult:
    """Assert the live winner is of a specific epistemic kind. Used by
    the lattice-race scenario to check that MEASURED always beats
    INFERRED regardless of commit order.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT fact_id, value, epistemic_kind
              FROM kndb.fact
             WHERE entity_id = %s
               AND attribute = %s
               AND upper(sys_time) = 'infinity'
            """,
            (entity_id, attribute),
        )
        rows = cur.fetchall()
    if len(rows) != 1:
        return InvariantResult(
            ok=False,
            label="live_kind_is",
            detail=(
                f"expected exactly one live row for entity_id={entity_id} "
                f"attribute={attribute!r}, got {len(rows)}"
            ),
            offending_rows=rows,
        )
    kind = rows[0][2]
    if kind != expected_kind:
        return InvariantResult(
            ok=False,
            label="live_kind_is",
            detail=(
                f"live kind for entity_id={entity_id} attribute={attribute!r} "
                f"is {kind}, expected {expected_kind}"
            ),
            offending_rows=rows,
        )
    return InvariantResult(ok=True, label="live_kind_is")


def r5_holds(
    conn: psycopg.Connection,
    entity_id: int,
    attribute: str,
    forbidden_kind: str,
) -> InvariantResult:
    """Assert no fact with `forbidden_kind` ever landed for the given
    slot. Used by scenario S3 to prove R5 fires under contention.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT fact_id, value, epistemic_kind
              FROM kndb.fact
             WHERE entity_id = %s
               AND attribute = %s
               AND epistemic_kind = %s
            """,
            (entity_id, attribute, forbidden_kind),
        )
        rows = cur.fetchall()
    if rows:
        return InvariantResult(
            ok=False,
            label="r5_holds",
            detail=(
                f"forbidden kind {forbidden_kind} landed for "
                f"entity_id={entity_id} attribute={attribute!r} "
                f"({len(rows)} row(s))"
            ),
            offending_rows=rows,
        )
    return InvariantResult(ok=True, label="r5_holds")


def audit_completeness(
    conn: psycopg.Connection,
    entity_id: int,
    attribute: str,
    accepted_commits: int,
) -> InvariantResult:
    """Assert (live rows + evicted_fact rows referring to this slot)
    covers every write the harness reports as accepted.

    Live rows include all sys_time epochs for the slot. `evicted_fact`
    rows are filtered by the original_row payload's entity_id and
    attribute.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT count(*) FROM kndb.fact
             WHERE entity_id = %s AND attribute = %s
            """,
            (entity_id, attribute),
        )
        fact_count = _int_scalar(cur.fetchone()[0])
        cur.execute(
            """
            SELECT count(*) FROM kndb_audit.evicted_fact
             WHERE (original_row->>'entity_id')::int = %s
               AND (original_row->>'attribute') = %s
            """,
            (entity_id, attribute),
        )
        audit_count = _int_scalar(cur.fetchone()[0])
    total = fact_count + audit_count
    if total < accepted_commits:
        return InvariantResult(
            ok=False,
            label="audit_completeness",
            detail=(
                f"accepted={accepted_commits} but fact+audit={total} "
                f"(fact={fact_count} audit={audit_count}) for "
                f"entity_id={entity_id} attribute={attribute!r}. "
                f"Missing writes = accepted - covered = "
                f"{accepted_commits - total}."
            ),
        )
    return InvariantResult(
        ok=True,
        label="audit_completeness",
        detail=f"fact={fact_count} audit={audit_count} accepted={accepted_commits}",
    )


def hotspot_slot_invariants(
    conn: psycopg.Connection,
    entity_id: int,
    attribute: str,
    accepted_commits: int,
    forbidden_kind: Optional[str] = None,
) -> list[InvariantResult]:
    """Bundle the invariants used by hotspot post-run checks. Returns
    ALL results (not just the first failure) so RESULTS.md can list
    every violated invariant per cell.
    """
    out = [no_two_live_for_slot(conn, entity_id, attribute)]
    if forbidden_kind is not None:
        out.append(r5_holds(conn, entity_id, attribute, forbidden_kind))
    out.append(audit_completeness(conn, entity_id, attribute, accepted_commits))
    return out
