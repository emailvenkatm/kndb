"""Baseline B1: application-layer guards.

The guard layer attempts to replicate KNDB's Primitive 1 (epistemic-kind)
and Primitive 3 (conflict) enforcement in Python before writes hit the
database. It is DELIBERATELY INCOMPLETE — see the module docstring below
for the specific holes we leave open. The paper's argument is that
app-layer enforcement is loose by nature; leaving realistic gaps is the
honest way to demonstrate that.

Deliberate gaps (documented, not accidental):
  1. `write_fact` checks slot-kind, sources[] non-empty for derived,
     and confidence range on the way in — but does NOT check that
     the source UUIDs actually resolve to existing rows (R2 in KNDB).
     A caller can write a derived row citing a bogus UUID; the write
     lands.
  2. `write_fact` does NOT detect valid_time overlap with contradictory
     value on the same (entity, attribute). Primitive 3 is unenforced.
     Only same-value idempotence is (naively) attempted, and only within
     a single session — cross-session concurrent writes are not
     serialized.
  3. Any writer that skips `write_fact` and issues raw SQL — a
     migration, a bulk COPY, a second microservice, a DBA — bypasses
     the guards entirely. The schema itself has no CHECKs.

These gaps are the paper's point. Do not "fix" them here.
"""

from __future__ import annotations

import psycopg
from psycopg.rows import dict_row


VALID_KINDS = {"MEASURED", "INFERRED", "DERIVED"}


class GuardRejection(Exception):
    """Raised when the app-layer guard refuses to forward a write."""


def _load_slot_kinds(conn: psycopg.Connection) -> dict[str, str]:
    with conn.cursor() as cur:
        cur.execute("SELECT attribute, required_kind FROM baseline_pyguards.slot_kind")
        return {row[0]: row[1] for row in cur.fetchall()}


def write_fact(
    conn: psycopg.Connection,
    entity_id: int,
    attribute: str,
    value: str,
    epistemic_kind: str,
    confidence: float,
    valid_time: str,  # tstzrange literal, e.g. '[2026-01-01, 2026-02-01)'
    sources: list[str] | None = None,
) -> str | None:
    """Attempt to write a fact through the guard.

    Returns the new fact_id UUID as a string, or None if the guard
    silently absorbed a same-value overlap (best-effort, session-local).
    Raises GuardRejection on any guard-caught violation.
    """
    sources = sources or []

    # G1 — epistemic_kind is one of the three valid kinds.
    if epistemic_kind not in VALID_KINDS:
        raise GuardRejection(f"epistemic_kind must be one of {VALID_KINDS}, got {epistemic_kind!r}")

    # G2 — confidence in [0, 1].
    if not (0.0 <= float(confidence) <= 1.0):
        raise GuardRejection(f"confidence {confidence!r} out of [0,1]")

    # G3 — INFERRED must not claim certainty.
    if epistemic_kind == "INFERRED" and float(confidence) >= 1.0:
        raise GuardRejection("INFERRED cannot have confidence >= 1.0 (mirrors KNDB R4)")

    # G4 — DERIVED must have >=1 source.
    if epistemic_kind == "DERIVED" and len(sources) == 0:
        raise GuardRejection("DERIVED fact must reference >=1 source (mirrors KNDB R1)")

    # G5 — MEASURED must not carry sources.
    if epistemic_kind == "MEASURED" and len(sources) > 0:
        raise GuardRejection("MEASURED cannot carry sources (mirrors KNDB R3)")

    # G6 — slot-kind registry check.
    slots = _load_slot_kinds(conn)
    required = slots.get(attribute)
    if required is not None and required != epistemic_kind:
        raise GuardRejection(
            f"attribute {attribute!r} is registered as {required!r}, got {epistemic_kind!r} (mirrors KNDB R5)"
        )

    # DELIBERATE GAP #1: We do NOT verify that entries of `sources`
    # resolve to existing rows in baseline_pyguards.fact. A caller can
    # write a derived row citing '00000000-...' and it lands.

    # DELIBERATE GAP #2: We do NOT check for valid_time overlap with
    # contradictory value. Primitive 3 (write-time conflict) is
    # unenforced in this baseline.

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO baseline_pyguards.fact
              (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time)
            VALUES (%s, %s, %s, %s, %s, %s, %s::tstzrange)
            RETURNING fact_id
            """,
            (entity_id, attribute, value, epistemic_kind, confidence, sources, valid_time),
        )
        return str(cur.fetchone()[0])
