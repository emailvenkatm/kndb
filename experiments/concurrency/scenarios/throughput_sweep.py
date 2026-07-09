"""Throughput sweep driver.

Cells: {client_count} x {contention} x {isolation} x {retry_mode}
Values:
  client_count in [1, 2, 4, 8, 16, 32]
  contention   in [0.01, 1.00]
  isolation    in ["READ COMMITTED", "SERIALIZABLE"]
  retry_mode   in ["raw", "app"]

Total = 6 * 2 * 2 * 2 = 48 cells. Each client issues 1000 writes.
"""
from __future__ import annotations

import csv
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from harness.db import open_connection, query_server_provenance
from harness.hotspot import HotspotConfig, run_cell
from harness.metrics import hardware_provenance


CLIENT_COUNTS = [1, 2, 4, 8, 16, 32]
CONTENTION_VALUES = [0.01, 1.00]
ISOLATIONS = ["READ COMMITTED", "SERIALIZABLE"]
RETRY_MODES = ["raw", "app"]


def main(argv: list[str]) -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--writes-per-client", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out-dir", type=Path, default=HERE.parent / "results")
    parser.add_argument("--filter", default=None,
                        help="Substring to match against cell_id; runs only matching cells")
    args = parser.parse_args(argv)

    args.out_dir.mkdir(parents=True, exist_ok=True)

    prov_conn = open_connection(isolation="READ COMMITTED", autocommit=True)
    server_prov = query_server_provenance(prov_conn)
    prov_conn.close()

    manifest = {
        "run_at": datetime.now(timezone.utc).isoformat(),
        "seed": args.seed,
        "writes_per_client": args.writes_per_client,
        "cells": [],
        "server_provenance": server_prov,
        "hardware_provenance": hardware_provenance(),
        "isolation_levels": ISOLATIONS,
        "retry_modes": RETRY_MODES,
        "contention_values": CONTENTION_VALUES,
        "client_counts": CLIENT_COUNTS,
    }

    csv_path = args.out_dir / "throughput_sweep_cells.csv"
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(
            [
                "cell_id",
                "client_count",
                "contention",
                "isolation",
                "retry_mode",
                "writes_attempted",
                "writes_committed",
                "writes_dropped",
                "serialization_failures",
                "deadlock_failures",
                "retries_total",
                "retries_p50",
                "retries_p95",
                "retries_p99",
                "latency_p50_us",
                "latency_p95_us",
                "latency_p99_us",
                "wall_clock_s",
                "throughput_rps",
                "invariant_violations_count",
                "invariant_violations",
            ]
        )
        for cc in CLIENT_COUNTS:
            for ct in CONTENTION_VALUES:
                for iso in ISOLATIONS:
                    for rt in RETRY_MODES:
                        cell_id = (
                            f"n{cc}_c{int(ct*100)}_{iso.replace(' ', '')}_{rt}"
                        )
                        if args.filter and args.filter not in cell_id:
                            continue
                        cfg = HotspotConfig(
                            client_count=cc,
                            contention=ct,
                            isolation=iso,
                            retry_mode=rt,
                            writes_per_client=args.writes_per_client,
                            seed=args.seed,
                        )
                        t0 = time.time()
                        cr = run_cell(cfg)
                        dt = time.time() - t0
                        print(
                            f"{cr.cell_id} committed={cr.writes_committed}/{cr.writes_attempted} "
                            f"drop={cr.writes_dropped} ser_fail={cr.serialization_failures} "
                            f"retries={cr.retries_total} thru={cr.throughput_rps:.0f} rps "
                            f"p50={cr.latency_p50_us or 0:.1f}us "
                            f"inv_violations={len(cr.invariant_violations)} "
                            f"({dt:.1f}s)",
                            flush=True,
                        )
                        w.writerow(
                            [
                                cr.cell_id,
                                cr.client_count,
                                cr.contention,
                                cr.isolation,
                                cr.retry_mode,
                                cr.writes_attempted,
                                cr.writes_committed,
                                cr.writes_dropped,
                                cr.serialization_failures,
                                cr.deadlock_failures,
                                cr.retries_total,
                                cr.retries_p50,
                                cr.retries_p95,
                                cr.retries_p99,
                                cr.latency_p50_us or 0.0,
                                cr.latency_p95_us or 0.0,
                                cr.latency_p99_us or 0.0,
                                cr.wall_clock_s,
                                cr.throughput_rps,
                                len(cr.invariant_violations),
                                json.dumps(cr.invariant_violations)[:2000],
                            ]
                        )
                        fh.flush()
                        manifest["cells"].append(cr.to_dict())

    with (args.out_dir / "throughput_sweep_manifest.json").open("w") as fh:
        json.dump(manifest, fh, indent=2, default=str)

    total = len(manifest["cells"])
    total_violations = sum(
        1 for c in manifest["cells"] if c["invariant_violations"]
    )
    print(f"\nSWEEP DONE: {total} cells, {total_violations} with invariant violations", flush=True)
    return 0 if total_violations == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
