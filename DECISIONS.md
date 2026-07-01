# DECISIONS log

Running log of concrete decisions made during KNDB construction. Newest at the top.

---

## 2026-07-01 — M0 opened, ProvSQL image is amd64-only

- **Finding:** `inriavalda/provsql:1.10.0` on Docker Hub publishes **amd64 only** (verified via Docker Hub tags API). No ARM64 manifest.
- **Decision:** run under Docker Desktop / OrbStack amd64 emulation via `platform: linux/amd64` in `docker-compose.yml`. Acceptable for a research prototype; will document expected 1.5-3x slowdown vs native amd64 in `bench/README.md` so we don't mis-report absolute numbers.
- **Alternative considered:** build ProvSQL from source for ARM64. Rejected for M0 — burns time and gives us a non-standard build reviewers can't reproduce. If overhead becomes intolerable at bench time, revisit.

## 2026-07-01 — pin: Postgres 17 + ProvSQL 1.10.0

- Postgres 17 chosen over 18: PG 18 works per ProvSQL README but ecosystem (pgvector, extensions) is still catching up. 17 minimizes surprise. 16 would also work; 17 is the most-current mainstream.
- ProvSQL 1.10.0 pinned by tag; will pin by SHA in `docker-compose.yml` after M0 smoke tests pass to guarantee reproducibility.

## 2026-07-01 — TOKI dropped from related-work

- Original project brief listed TOKI as a comparison system. Landscape scan confirmed TOKI (toki.finance) is a Cosmos IBC bridge, not a database. Naming collision. Removed from related-work table before we could cite it wrong.

## 2026-07-01 — Narrowed novelty claim

- MemIR (arXiv:2605.25869, May 2026) and ATCH (arXiv:2603.13603, Feb 2026) publish adjacent framings. The defensible KNDB claim is narrower: "no *relational/graph engine* ships an epistemic-kind system with propagation semantics baked into query evaluation." Runtime typed-atoms (MemIR) and theory papers (ATCH) do not close the gap.

## 2026-07-01 — Isolation contract with voicelane

- `voicelane-falkordb` is a running container from a separate project. KNDB uses its own network `kndb-net`, port `5433` (not 5432), and only touches containers named `kndb-*`. No `docker system prune`. No shared volumes.
