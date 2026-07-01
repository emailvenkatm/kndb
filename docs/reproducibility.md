# Reproducibility checklist

For reviewers running KNDB from scratch. All entries are pinned; if any pin
is stale by the time you read this, flag it as a reproducibility bug — do
not silently upgrade.

## Fixed environment

| Item | Value |
|---|---|
| Container image | `inriavalda/provsql:1.10.0` |
| Image digest | `sha256:902023e556a49583eb650665183f3ff48c6623284d601c40788cb8401e682e06` (pinned in `docker-compose.yml` after M0 smoke tests pass) |
| Postgres version | 17.x (whatever the pinned image ships) |
| ProvSQL version | 1.10.0 |
| Host platform | Linux amd64 preferred; ARM64 via Docker/OrbStack amd64 emulation supported (see caveat below) |
| Kernel | Logged into `bench/results/manifest.json` per run (`uname -a`) |
| CPU governor | `performance` on Linux; N/A on macOS. Logged into `manifest.json`. |
| Random seed | 42 (Python and Postgres) |
| Runs per config | ≥10, reported as p50 / p95 / p99 |
| Python version | 3.14.5, `uv.lock` committed |
| Synthea version | Pinned commit in `data/generate.sh` |

## One-command reproduction

```bash
make reproduce
```

This target:

1. Pulls the pinned image and verifies the digest matches
   `sha256:902023e556a49583eb650665183f3ff48c6623284d601c40788cb8401e682e06`. Aborts if it does not.
2. Starts the isolated stack on `kndb-net`, port 5433.
3. Applies `engine/*.sql`.
4. Regenerates 10k Synthea patients (seed 42) and loads them.
5. Runs the full test suite (`tests/`).
6. Runs the benchmark harness (`bench/run.py`) for ≥10 seeds per config.
7. Writes results to `bench/results/`:
   - `manifest.json` — kernel, CPU governor, image digest, seed, git SHA,
     wall-clock start/end.
   - `raw/*.csv` — per-run measurements.
   - `figures/*.pdf` — every plot in the paper, regenerated.
   - `tables/*.md` — every table in the paper, regenerated.

Every figure and table in the paper is regenerable from these files. If a
paper figure has no matching file, that is a reproducibility bug.

## ARM64 caveat (M-series Macs and similar)

Per `DECISIONS.md` (2026-07-01), the `inriavalda/provsql:1.10.0` image is
amd64-only. On ARM64 hosts, Docker Desktop and OrbStack run it under amd64
emulation. Absolute overhead numbers measured on M-series Macs are therefore
**not directly comparable to native amd64**. Expected slowdown is 1.5-3x for
CPU-bound workloads, less for I/O-bound ones. `manifest.json` records whether
the run was native or emulated. Paper tables report native amd64 numbers.
Relative comparisons (KNDB vs baselines B0/B1/B2) hold under emulation
because all four run in the same container.

If a reviewer runs on ARM64, they should expect their absolute numbers to be
higher than the paper's but their relative comparisons to match within noise.

## Where results land

- `bench/results/manifest.json` — one entry per `make reproduce` invocation.
- `bench/results/raw/` — CSV per (config, seed).
- `bench/results/figures/` — regenerated PDFs.
- `bench/results/tables/` — regenerated Markdown.
- Git tag `bench-final-YYYYMMDD` marks the exact commit whose numbers appear
  in the paper. Any commit past that tag may change numbers.

## What is not automated

- Screencast of the 60-second demo (`demo/demo.sh` runs; recording the
  screencast is manual).
- Confirming ProvSQL's Viterbi behavior on LEFT-JOIN edge cases — M0 smoke
  test A does a scripted check but the interpretation lives in
  `DECISIONS.md`, not in a passing test.
