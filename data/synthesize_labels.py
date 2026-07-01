#!/usr/bin/env python3
"""KNDB — synthesize epistemic-kind labels from Synthea CSVs.

Synthea emits everything as FHIR-style Observations; it does not
distinguish observations from inferences from derived aggregates. This
script takes the raw Synthea CSVs and produces three KNDB-shaped CSVs:

    data/synthea/kndb/observations.csv   raw labs we care about
    data/synthea/kndb/inferences.csv     synthesized is_diabetic prediction
    data/synthea/kndb/derived.csv        90-day per-patient aggregates

See data/README.md for the rationale (in particular why the split is
synthesized, why the noise model looks like it does, and which LOINC
codes we filter to).

Deterministic given seed=42.  No third-party dependencies — stdlib
only, so this runs in any Python 3.11+ environment without needing to
install anything.
"""

from __future__ import annotations

import argparse
import csv
import random
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable

# --- constants ----------------------------------------------------------------

SEED: int = 42

# LOINC codes we care about. Verified against Synthea 4.0.0's LabsMapper
# defaults. Documented here (not just in data/README.md) because reviewers
# will ask why we picked exactly these five.
#
# 4548-4  Hemoglobin A1c/Hemoglobin.total in Blood
# 8480-6  Systolic blood pressure
# 8462-4  Diastolic blood pressure
# 1558-6  Fasting glucose (serum/plasma)
# 2571-8  Triglyceride / LDL cholesterol (Synthea emits 18262-6 or 2571-8 for LDL,
#         depending on module — we accept both to be robust)
LAB_CODES: dict[str, str] = {
    "4548-4":  "hba1c",
    "8480-6":  "systolic_bp",
    "8462-4":  "diastolic_bp",
    "1558-6":  "fasting_glucose",
    "2571-8":  "ldl",
    "18262-6": "ldl",  # alt LDL LOINC — treat as same attribute
}

# ADA diagnostic threshold for HbA1c. Standard clinical cutoff.
HBA1C_DIABETES_THRESHOLD: float = 6.5

# Noise on the inference. Chosen so ~5-10% of borderline patients get
# their prediction flipped from ground truth — enough disagreement to
# make the obs-vs-inference queries interesting, not so much the
# "model" looks broken. Documented in data/README.md.
INFERENCE_NOISE_SIGMA: float = 0.35

# Confidence in [0.5, 0.95], monotonic in distance from threshold.
CONF_MIN: float = 0.5
CONF_MAX: float = 0.95
CONF_SLOPE: float = 0.9 / 3.0  # 3.0 percentage points -> full-range spread

# Constant confidence attached to raw observations. Represents "we
# trust the instrument modulo per-device noise" — not truth, but not
# nothing either.
OBS_CONFIDENCE: float = 0.95

# Window for 'derived' aggregates. 90 days ending at the patient's
# latest observation date (per-patient anchor, not calendar today —
# keeps regeneration reproducible across days).
DERIVED_WINDOW_DAYS: int = 90


# --- data shapes --------------------------------------------------------------


@dataclass(slots=True)
class Observation:
    """One row of stage.observations."""
    id: int
    patient_id: str
    code: str          # our short name: 'hba1c', 'systolic_bp', ...
    value: float
    unit: str
    effective_time: str  # ISO-8601, Synthea format
    confidence: float


@dataclass(slots=True)
class PatientState:
    """Per-patient scratch state as we sweep the observations CSV."""
    obs: list[Observation] = field(default_factory=list)

    def latest_hba1c(self) -> Observation | None:
        rows = [o for o in self.obs if o.code == "hba1c"]
        if not rows:
            return None
        return max(rows, key=lambda o: o.effective_time)

    def latest_obs_date(self) -> datetime | None:
        if not self.obs:
            return None
        return max(_parse_ts(o.effective_time) for o in self.obs)


# --- helpers ------------------------------------------------------------------


def _parse_ts(s: str) -> datetime:
    """Parse Synthea timestamps. Synthea emits ISO-8601 with 'Z' or
    an offset; we normalize to naive UTC for arithmetic simplicity —
    all timestamps are on the same clock, so drift doesn't matter."""
    # Handle common forms: "2024-01-05T12:34:56Z", "2024-01-05T12:34:56",
    # "2024-01-05T12:34:56.000Z", "2024-01-05T12:34:56+00:00".
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        # Fallback for microsecond weirdness in a couple of Synthea rows.
        dt = datetime.fromisoformat(s.split(".")[0])
    if dt.tzinfo is not None:
        dt = dt.replace(tzinfo=None)
    return dt


def _confidence_from_distance(hba1c: float) -> float:
    """Bounded, monotonic-in-distance confidence for the inference."""
    dist = abs(hba1c - HBA1C_DIABETES_THRESHOLD)
    conf = CONF_MIN + CONF_SLOPE * dist
    return max(CONF_MIN, min(CONF_MAX, conf))


# --- pipeline -----------------------------------------------------------------


def read_observations(synthea_csv: Path) -> Iterable[Observation]:
    """Stream + filter Synthea's observations.csv.

    We assign a sequential integer `id` to every filtered lab. That
    id is what `inferences.source_lab_ids` and `derived.sources`
    reference — M1 will preserve it when copying stage → kndb.

    Synthea's observations.csv columns (Synthea 4.0.0):
        DATE, PATIENT, ENCOUNTER, CATEGORY, CODE, DESCRIPTION,
        VALUE, UNITS, TYPE
    """
    next_id = 1
    with synthea_csv.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            code = row.get("CODE", "").strip()
            if code not in LAB_CODES:
                continue
            raw_val = row.get("VALUE", "").strip()
            if not raw_val:
                continue
            try:
                value = float(raw_val)
            except ValueError:
                # Synthea occasionally emits categorical VALUES for lab
                # codes (e.g. "Present"). Skip — we only want numerics.
                continue
            yield Observation(
                id=next_id,
                patient_id=row["PATIENT"].strip(),
                code=LAB_CODES[code],
                value=value,
                unit=row.get("UNITS", "").strip(),
                effective_time=row["DATE"].strip(),
                confidence=OBS_CONFIDENCE,
            )
            next_id += 1


def synthesize_inferences(
    per_patient: dict[str, PatientState],
    rng: random.Random,
) -> list[dict[str, object]]:
    """One is_diabetic prediction per patient with an HbA1c reading.

    Rule: threshold HbA1c + Gaussian noise. Source is the specific
    HbA1c observation used, recorded so ProvSQL / KNDB can trace
    lineage through the join.
    """
    rows: list[dict[str, object]] = []
    inf_id = 1
    # Deterministic patient order (sort by id) so RNG draws line up
    # across runs regardless of dict iteration order.
    for patient_id in sorted(per_patient.keys()):
        state = per_patient[patient_id]
        latest = state.latest_hba1c()
        if latest is None:
            continue  # no HbA1c reading, nothing to predict from
        noise = rng.gauss(0.0, INFERENCE_NOISE_SIGMA)
        noisy = latest.value + noise
        predicted = 1 if noisy >= HBA1C_DIABETES_THRESHOLD else 0
        confidence = _confidence_from_distance(noisy)
        rows.append({
            "id": inf_id,
            "patient_id": patient_id,
            "attribute": "is_diabetic",
            "value": predicted,
            "confidence": round(confidence, 4),
            # PostgreSQL array literal syntax: {1,2,3}. This CSV feeds
            # directly into a COPY into an int[] column in load_postgres.sh.
            "source_lab_ids": "{" + str(latest.id) + "}",
        })
        inf_id += 1
    return rows


def synthesize_derived(
    per_patient: dict[str, PatientState],
) -> list[dict[str, object]]:
    """Per-patient 90-day-window averages for systolic BP and HbA1c.

    Sources listed as a Postgres int[] literal so COPY can push
    straight into an int[] column, letting the M1 engine trigger
    check that every source ID resolves in stage.observations.
    """
    rows: list[dict[str, object]] = []
    der_id = 1
    for patient_id in sorted(per_patient.keys()):
        state = per_patient[patient_id]
        anchor = state.latest_obs_date()
        if anchor is None:
            continue
        window_start = anchor - timedelta(days=DERIVED_WINDOW_DAYS)
        in_window = [o for o in state.obs if window_start <= _parse_ts(o.effective_time) <= anchor]

        for attr, code in (("avg_systolic_bp_90d", "systolic_bp"),
                            ("avg_hba1c_90d",       "hba1c")):
            sample = [o for o in in_window if o.code == code]
            if not sample:
                continue
            avg = statistics.fmean(o.value for o in sample)
            source_ids = sorted(o.id for o in sample)
            rows.append({
                "id": der_id,
                "patient_id": patient_id,
                "attribute": attr,
                "value": round(avg, 3),
                "sources": "{" + ",".join(str(i) for i in source_ids) + "}",
            })
            der_id += 1
    return rows


def write_observations_csv(path: Path, obs: list[Observation]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["id", "patient_id", "code", "value", "unit",
                    "effective_time", "confidence"])
        for o in obs:
            w.writerow([o.id, o.patient_id, o.code, o.value, o.unit,
                        o.effective_time, o.confidence])


def write_dict_csv(path: Path, rows: list[dict[str, object]],
                    header: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=header)
        w.writeheader()
        w.writerows(rows)


# --- entry point --------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--input", "-i",
        type=Path,
        default=Path(__file__).parent / "synthea" / "output",
        help="Directory containing Synthea CSV output (has a csv/ subdir).",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path(__file__).parent / "synthea" / "kndb",
        help="Directory to write KNDB-shaped CSVs into.",
    )
    parser.add_argument(
        "--seed", type=int, default=SEED,
        help="RNG seed for the inference noise draw. Default 42.",
    )
    args = parser.parse_args(argv)

    csv_dir: Path = args.input / "csv" if (args.input / "csv").exists() else args.input
    obs_csv = csv_dir / "observations.csv"
    if not obs_csv.exists():
        print(f"error: expected Synthea observations at {obs_csv}", file=sys.stderr)
        print("hint: run data/generate.sh first, or pass --input", file=sys.stderr)
        return 1

    args.output.mkdir(parents=True, exist_ok=True)

    # --- stream observations, build per-patient index ------------------------
    print(f"[synthesize_labels] reading {obs_csv}")
    all_obs: list[Observation] = []
    per_patient: dict[str, PatientState] = defaultdict(PatientState)
    for o in read_observations(obs_csv):
        all_obs.append(o)
        per_patient[o.patient_id].obs.append(o)

    print(f"[synthesize_labels]   observations kept: {len(all_obs)}")
    print(f"[synthesize_labels]   patients with labs: {len(per_patient)}")

    # --- write observations.csv ---------------------------------------------
    obs_out = args.output / "observations.csv"
    write_observations_csv(obs_out, all_obs)
    print(f"[synthesize_labels] wrote {obs_out}")

    # --- inferences ---------------------------------------------------------
    rng = random.Random(args.seed)
    inferences = synthesize_inferences(per_patient, rng)
    inf_out = args.output / "inferences.csv"
    write_dict_csv(inf_out, inferences,
                    header=["id", "patient_id", "attribute", "value",
                            "confidence", "source_lab_ids"])
    print(f"[synthesize_labels] wrote {inf_out} ({len(inferences)} rows)")

    # --- derived aggregates -------------------------------------------------
    derived = synthesize_derived(per_patient)
    der_out = args.output / "derived.csv"
    write_dict_csv(der_out, derived,
                    header=["id", "patient_id", "attribute", "value", "sources"])
    print(f"[synthesize_labels] wrote {der_out} ({len(derived)} rows)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
