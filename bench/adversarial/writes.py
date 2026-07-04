"""Adversarial write generator for M6.

Emits exactly 100 adversarial payloads across five buckets of 20, seed 42.
Some buckets rely on pre-existing seed rows (a conflicting write needs a
prior row to conflict with); those seed rows are returned separately as
`generate_setup()` and are NOT counted toward the 100.

Each adversarial payload is a dict with:
  - id                 int    0..99
  - bucket             str    one of the five buckets
  - reason             str    machine-readable label for the attack
  - should_be_rejected bool   whether a compliant system MUST reject it
  - payload            dict   columns for the target `fact` table

The payload shape is uniform across KNDB, B0 (naive), B1 (py-guards),
B2 (hand-rolled). bench/run.py dispatches without per-baseline branching.
"""

from __future__ import annotations

import random
import uuid
from datetime import datetime, timedelta, timezone


SEED = 42

SLOTS = {
    "hba1c": "MEASURED",
    "is_diabetic": "INFERRED",
    "bp_systolic": "MEASURED",
}

# Attributes for which the harness pre-installs a `conflict_policy = reject`
# entry, so a contradicting overlap raises rather than silently invalidates.
REJECT_POLICY_ATTRS = ("bp_systolic", "temp_c")


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S%z")


def _range(a: datetime, b: datetime) -> str:
    return f"[{_iso(a)}, {_iso(b)})"


def _base_ts(day: int) -> datetime:
    return datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(days=day)


def _rand_uuid(rng: random.Random) -> str:
    return str(uuid.UUID(int=rng.getrandbits(128)))


# ---------------------------------------------------------------------------
# Setup rows (not counted in the 100). Used by the conflict + bitemporal
# adversarial rows to have something to collide with.
# ---------------------------------------------------------------------------

def generate_setup(seed: int = SEED) -> list[dict]:
    rng = random.Random(seed ^ 0xBEEF)  # separate RNG stream so main rng is stable
    out = []
    # Conflict seeds (20) — one per adversarial-conflict row.
    for i in range(20):
        eid = 2000 + i
        attr = REJECT_POLICY_ATTRS[0]  # bp_systolic; policy=reject installed by harness
        out.append(dict(
            reason=f"conflict_seed_{i}",
            payload=dict(
                entity_id=eid,
                attribute=attr,
                value=str(110 + i),
                epistemic_kind="MEASURED",
                confidence=0.95,
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(60)),
            ),
        ))
    # Bitemporal seeds (20) — one per adversarial-bitemporal row.
    for i in range(20):
        eid = 4000 + i
        out.append(dict(
            reason=f"bitemporal_seed_{i}",
            payload=dict(
                entity_id=eid,
                attribute="temp_c",  # policy=reject also installed for temp_c
                value=f"{36.5 + i * 0.05:.2f}",
                epistemic_kind="MEASURED",
                confidence=0.95,
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(60)),
            ),
        ))
    return out


# ---------------------------------------------------------------------------
# The five adversarial buckets (20 payloads each). Total = 100.
# ---------------------------------------------------------------------------

def _bucket_epistemic_kind(rng: random.Random) -> list[dict]:
    out: list[dict] = []
    # 5 x inference into obs-typed slot (hba1c)
    for i in range(5):
        out.append(dict(
            bucket="epistemic_kind",
            reason="inference_into_obs_slot",
            should_be_rejected=True,
            payload=dict(
                entity_id=1000 + i,
                attribute="hba1c",
                value=f"{rng.uniform(4.0, 9.0):.2f}",
                epistemic_kind="INFERRED",
                confidence=round(rng.uniform(0.3, 0.9), 3),
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(30)),
            ),
        ))
    # 4 x derived with no sources
    for i in range(4):
        out.append(dict(
            bucket="epistemic_kind",
            reason="derived_no_sources",
            should_be_rejected=True,
            payload=dict(
                entity_id=1100 + i,
                attribute=f"agg_metric_{i}",
                value=f"{rng.uniform(1, 100):.2f}",
                epistemic_kind="DERIVED",
                confidence=round(rng.uniform(0.5, 0.95), 3),
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(90)),
            ),
        ))
    # 4 x observation with sources
    for i in range(4):
        out.append(dict(
            bucket="epistemic_kind",
            reason="observation_with_sources",
            should_be_rejected=True,
            payload=dict(
                entity_id=1200 + i,
                attribute=f"ldl_{i}",
                value=str(rng.randint(80, 200)),
                epistemic_kind="MEASURED",
                confidence=round(rng.uniform(0.8, 0.99), 3),
                sources=[_rand_uuid(rng)],
                valid_time=_range(_base_ts(0), _base_ts(30)),
            ),
        ))
    # 4 x inference at confidence=1.0
    for i in range(4):
        out.append(dict(
            bucket="epistemic_kind",
            reason="inference_certain",
            should_be_rejected=True,
            payload=dict(
                entity_id=1300 + i,
                attribute=f"model_pred_{i}",
                value="true",
                epistemic_kind="INFERRED",
                confidence=1.0,
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(365)),
            ),
        ))
    # 3 x obs into inference-typed slot (is_diabetic)
    for i in range(3):
        out.append(dict(
            bucket="epistemic_kind",
            reason="obs_into_inference_slot",
            should_be_rejected=True,
            payload=dict(
                entity_id=1400 + i,
                attribute="is_diabetic",
                value="true",
                epistemic_kind="MEASURED",
                confidence=0.95,
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(365)),
            ),
        ))
    assert len(out) == 20
    return out


def _bucket_conflict(rng: random.Random) -> list[dict]:
    out: list[dict] = []
    for i in range(20):
        eid = 2000 + i  # matches conflict-seed rows in generate_setup
        vt = _range(_base_ts(30), _base_ts(120))  # overlaps seed's [0,60)
        out.append(dict(
            bucket="conflict",
            reason="contradicting_overlap_reject_policy",
            should_be_rejected=True,
            payload=dict(
                entity_id=eid,
                attribute=REJECT_POLICY_ATTRS[0],  # bp_systolic
                value=str(180 + i),  # different from seed's 110+i
                epistemic_kind="MEASURED",
                confidence=0.95,
                sources=[],
                valid_time=vt,
            ),
        ))
    assert len(out) == 20
    return out


def _bucket_confidence(rng: random.Random) -> list[dict]:
    """Legal writes whose joint-confidence a naive scheme miscomputes.

    These land; bench/confidence_correctness.py evaluates the joint
    confidence downstream. should_be_rejected=False.
    """
    out: list[dict] = []
    for i in range(20):
        eid = 3000 + i
        c = round(rng.uniform(0.4, 0.95), 3)
        out.append(dict(
            bucket="confidence",
            reason="joint_confidence_target",
            should_be_rejected=False,
            payload=dict(
                entity_id=eid,
                attribute=f"cognitive_score_{i}",
                value=str(round(rng.uniform(0, 100), 2)),
                epistemic_kind="MEASURED",
                confidence=c,
                sources=[],
                valid_time=_range(_base_ts(0), _base_ts(30)),
            ),
        ))
    assert len(out) == 20
    return out


def _bucket_bitemporal(rng: random.Random) -> list[dict]:
    """Overlapping valid_time on same (entity, attribute) with different value.

    The seed row is emitted by generate_setup(). This adversarial write
    overlaps and contradicts. Under 'reject' policy on temp_c → reject.
    """
    out: list[dict] = []
    for i in range(20):
        eid = 4000 + i
        vt = _range(_base_ts(30), _base_ts(120))
        out.append(dict(
            bucket="bitemporal",
            reason="overlap_diff_value_same_entity_attr",
            should_be_rejected=True,
            payload=dict(
                entity_id=eid,
                attribute="temp_c",
                value=f"{38.5 + i * 0.05:.2f}",
                epistemic_kind="MEASURED",
                confidence=0.95,
                sources=[],
                valid_time=vt,
            ),
        ))
    assert len(out) == 20
    return out


def _bucket_progressive(rng: random.Random) -> list[dict]:
    """Depth-classification adversarials.

    10 legal derived rows (should_be_rejected=False, they LAND; used to
    verify the runner counts them correctly), and 10 "derived
    masquerading as observation" rows (obs kind with sources — violates R3,
    should_be_rejected=True).
    """
    out: list[dict] = []
    for i in range(10):
        out.append(dict(
            bucket="progressive",
            reason="legal_derived_with_source",
            should_be_rejected=False,
            payload=dict(
                entity_id=5000 + i,
                attribute=f"agg_90d_{i}",
                value=str(round(rng.uniform(1, 100), 2)),
                epistemic_kind="DERIVED",
                confidence=round(rng.uniform(0.5, 0.9), 3),
                # Sentinel; run.py substitutes a real fact_id at replay time.
                sources=["__SEED_FACT__"],
                valid_time=_range(_base_ts(0), _base_ts(90)),
            ),
        ))
    for i in range(10):
        out.append(dict(
            bucket="progressive",
            reason="derived_masquerading_as_obs",
            should_be_rejected=True,
            payload=dict(
                entity_id=5100 + i,
                attribute=f"agg_masquerade_{i}",
                value=str(round(rng.uniform(1, 100), 2)),
                epistemic_kind="MEASURED",
                confidence=0.99,
                sources=["__SEED_FACT__"],  # obs + sources → R3 violation
                valid_time=_range(_base_ts(0), _base_ts(90)),
            ),
        ))
    assert len(out) == 20
    return out


def generate(seed: int = SEED) -> list[dict]:
    """Return exactly 100 adversarial payloads, deterministic under seed."""
    rng = random.Random(seed)
    out: list[dict] = []
    out += _bucket_epistemic_kind(rng)
    out += _bucket_conflict(rng)
    out += _bucket_confidence(rng)
    out += _bucket_bitemporal(rng)
    out += _bucket_progressive(rng)
    assert len(out) == 100, f"expected 100 payloads, got {len(out)}"
    return [{**p, "id": i} for i, p in enumerate(out)]


if __name__ == "__main__":
    import json, sys
    setup = generate_setup()
    adv = generate()
    if len(sys.argv) > 1 and sys.argv[1] == "dump":
        print(json.dumps({"setup": setup, "adversarial": adv}, indent=2, default=str))
    else:
        print(f"setup rows: {len(setup)}")
        print(f"adversarial rows: {len(adv)}")
        from collections import Counter
        print("bucket counts:", Counter(p["bucket"] for p in adv))
        print("should_be_rejected counts:", Counter(p["should_be_rejected"] for p in adv))
