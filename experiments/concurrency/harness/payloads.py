"""Canonical fact payloads for concurrency scenarios and the throughput
sweep. Every generator is seed-deterministic.
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterator, Literal

Kind = Literal["MEASURED", "INFERRED", "DERIVED"]


@dataclass(frozen=True)
class FactPayload:
    """Everything needed to INSERT one row into kndb.fact."""

    entity_id: int
    attribute: str
    value: str
    epistemic_kind: Kind
    confidence: float
    valid_time_lower: datetime
    valid_time_upper: datetime | None
    specificity: int = 100
    sources: tuple = ()

    def to_insert_params(self) -> tuple:
        """Return the parameter tuple for a psycopg INSERT with:

            INSERT INTO kndb.fact
              (entity_id, attribute, value, epistemic_kind, confidence,
               specificity, sources, valid_time)
            VALUES (%s,%s,%s,%s,%s,%s,%s,tstzrange(%s,%s,'[)'))
        """
        return (
            self.entity_id,
            self.attribute,
            self.value,
            self.epistemic_kind,
            self.confidence,
            self.specificity,
            list(self.sources),
            self.valid_time_lower,
            self.valid_time_upper,  # None -> infinity via tstzrange upper
        )


INSERT_SQL = """
INSERT INTO kndb.fact
  (entity_id, attribute, value, epistemic_kind, confidence,
   specificity, sources, valid_time)
VALUES (%s, %s, %s, %s, %s, %s, %s, tstzrange(%s, %s, '[)'))
"""


BASE_TIME = datetime(2026, 1, 1, tzinfo=timezone.utc)


def default_valid_range(offset_days: int = 0) -> tuple[datetime, datetime]:
    """Standard 180-day valid-time window for concurrency test writes.
    Offset the window by `offset_days` if a scenario wants clean-slate
    isolation across iterations. Returns (lower, upper).
    """
    lower = BASE_TIME + timedelta(days=offset_days)
    upper = lower + timedelta(days=180)
    return lower, upper


def measured(
    entity_id: int,
    attribute: str,
    value: str,
    confidence: float = 0.95,
    specificity: int = 100,
    valid_range: tuple[datetime, datetime] | None = None,
) -> FactPayload:
    lower, upper = valid_range or default_valid_range()
    return FactPayload(
        entity_id=entity_id,
        attribute=attribute,
        value=value,
        epistemic_kind="MEASURED",
        confidence=confidence,
        valid_time_lower=lower,
        valid_time_upper=upper,
        specificity=specificity,
    )


def inferred(
    entity_id: int,
    attribute: str,
    value: str,
    confidence: float = 0.85,
    specificity: int = 100,
    valid_range: tuple[datetime, datetime] | None = None,
) -> FactPayload:
    lower, upper = valid_range or default_valid_range()
    return FactPayload(
        entity_id=entity_id,
        attribute=attribute,
        value=value,
        epistemic_kind="INFERRED",
        confidence=confidence,
        valid_time_lower=lower,
        valid_time_upper=upper,
        specificity=specificity,
    )


def derived(
    entity_id: int,
    attribute: str,
    value: str,
    sources: tuple,
    confidence: float = 0.90,
    specificity: int = 100,
    valid_range: tuple[datetime, datetime] | None = None,
) -> FactPayload:
    lower, upper = valid_range or default_valid_range()
    return FactPayload(
        entity_id=entity_id,
        attribute=attribute,
        value=value,
        epistemic_kind="DERIVED",
        confidence=confidence,
        valid_time_lower=lower,
        valid_time_upper=upper,
        specificity=specificity,
        sources=sources,
    )


def entity_pool(size: int, seed: int = 42) -> list[int]:
    """Return `size` distinct entity IDs in [10_000_000, 20_000_000).
    Deterministic under seed. Kept away from the range used by tests/
    (entities 1 through 100_000) so a stray concurrency run does not
    trample test fixtures if pointed at the wrong DB.
    """
    rng = random.Random(seed)
    return rng.sample(range(10_000_000, 20_000_000), k=size)


def hotspot_slot() -> tuple[int, str]:
    """The one entity-attribute pair every hotspot workload contends on."""
    return (99_999_999, "concur_hotspot_slot")
