"""Latency percentiles + retry counters for the throughput sweep.

Everything is per-cell and per-thread. The driver aggregates across
threads before writing to CSV.
"""
from __future__ import annotations

import json
import platform
import subprocess
from dataclasses import dataclass, field, asdict
from statistics import quantiles
from typing import Any


@dataclass
class WriteOutcome:
    """One committed or dropped write attempt."""

    latency_us: float | None      # None on drop / failure
    attempts: int                 # 1 for a first-try success; >1 if retried
    committed: bool
    is_hotspot: bool = False      # True if the target slot was the shared hotspot
    failure_kind: str | None = None    # 'serialization', 'deadlock', 'other', or None


@dataclass
class ThreadResult:
    thread_id: int
    outcomes: list[WriteOutcome] = field(default_factory=list)


@dataclass
class CellResult:
    """Aggregate for one (client_count, contention, isolation, retry_mode)
    cell. All timings in microseconds.
    """

    cell_id: str
    client_count: int
    contention: float
    isolation: str
    retry_mode: str
    seed: int
    writes_attempted: int
    writes_committed: int
    writes_dropped: int
    serialization_failures: int
    deadlock_failures: int
    retries_total: int
    retries_p50: float
    retries_p95: float
    retries_p99: float
    latency_p50_us: float | None
    latency_p95_us: float | None
    latency_p99_us: float | None
    wall_clock_s: float
    throughput_rps: float
    invariant_violations: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    if len(values) < 2:
        return values[0]
    # quantiles uses n=100 to give per-percent buckets
    return quantiles(values, n=100, method="inclusive")[int(q) - 1]


def aggregate_cell(
    cell_id: str,
    client_count: int,
    contention: float,
    isolation: str,
    retry_mode: str,
    seed: int,
    thread_results: list[ThreadResult],
    wall_clock_s: float,
    invariant_violations: list[dict],
) -> CellResult:
    all_outcomes = [o for tr in thread_results for o in tr.outcomes]
    committed_latencies = [
        o.latency_us for o in all_outcomes if o.committed and o.latency_us is not None
    ]
    attempts_committed = [o.attempts for o in all_outcomes if o.committed]

    n_attempted = len(all_outcomes)
    n_committed = sum(1 for o in all_outcomes if o.committed)
    n_dropped = n_attempted - n_committed
    n_serialization = sum(
        1 for o in all_outcomes if o.failure_kind == "serialization"
    )
    n_deadlock = sum(1 for o in all_outcomes if o.failure_kind == "deadlock")
    retries_total = sum(max(a - 1, 0) for a in attempts_committed)

    return CellResult(
        cell_id=cell_id,
        client_count=client_count,
        contention=contention,
        isolation=isolation,
        retry_mode=retry_mode,
        seed=seed,
        writes_attempted=n_attempted,
        writes_committed=n_committed,
        writes_dropped=n_dropped,
        serialization_failures=n_serialization,
        deadlock_failures=n_deadlock,
        retries_total=retries_total,
        retries_p50=_percentile([float(a - 1) for a in attempts_committed], 50) or 0.0,
        retries_p95=_percentile([float(a - 1) for a in attempts_committed], 95) or 0.0,
        retries_p99=_percentile([float(a - 1) for a in attempts_committed], 99) or 0.0,
        latency_p50_us=_percentile(committed_latencies, 50),
        latency_p95_us=_percentile(committed_latencies, 95),
        latency_p99_us=_percentile(committed_latencies, 99),
        wall_clock_s=wall_clock_s,
        throughput_rps=(n_committed / wall_clock_s) if wall_clock_s > 0 else 0.0,
        invariant_violations=invariant_violations,
    )


def hardware_provenance() -> dict[str, Any]:
    """Machine-and-OS fingerprint written into every manifest.json."""
    prov: dict[str, Any] = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }
    try:
        prov["uname"] = subprocess.check_output(["uname", "-a"], text=True).strip()
    except Exception:
        prov["uname"] = None
    try:
        prov["sw_vers"] = subprocess.check_output(["sw_vers"], text=True).strip()
    except Exception:
        prov["sw_vers"] = None
    try:
        prov["chip_and_cores"] = subprocess.check_output(
            [
                "sh",
                "-c",
                "system_profiler SPHardwareDataType | grep -E 'Chip|Cores|Memory' | tr -s ' '",
            ],
            text=True,
        ).strip()
    except Exception:
        prov["chip_and_cores"] = None
    return prov
