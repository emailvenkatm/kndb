"""LOC counter for guard code across baselines.

Counts non-blank, non-comment lines that constitute the guard logic
(triggers, guard functions, Python guards). DOES NOT count schema DDL
(CREATE TABLE, CREATE INDEX, CREATE SCHEMA), ProvSQL setup, or engine
files that only declare types.

The paper cites this as: 'to match KNDB's semantic guarantees, a plain
Postgres baseline needs N LOC of hand-written triggers'.
"""

from __future__ import annotations

import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
RESULTS = HERE / "results"


# ---------------------------------------------------------------------------
# What counts and what doesn't:
#
# SQL guard code =
#   CREATE (OR REPLACE) FUNCTION ... $$;
#   CREATE TRIGGER ...;
#   Any CHECK constraint body (crude approximation: lines with "CHECK (").
#
# SQL schema DDL (excluded) =
#   CREATE SCHEMA, CREATE TABLE, CREATE INDEX, CREATE EXTENSION, CREATE
#   DOMAIN, CREATE TYPE, ALTER TABLE for constraints (only the DROP-CONSTRAINT
#   which is engine plumbing).
#
# Python guard code = any non-blank, non-comment line in guards.py.
# ---------------------------------------------------------------------------

BLANK_RE = re.compile(r"^\s*$")
SQL_COMMENT_RE = re.compile(r"^\s*--")
PY_COMMENT_RE = re.compile(r"^\s*#")


def _sql_guard_loc(text: str) -> int:
    """Approximate guard-only LOC in a SQL file.

    Sums lines that are inside a CREATE FUNCTION ... $tag$ ... $tag$ body,
    inside a CREATE TRIGGER statement, or that contain an inline CHECK (.
    Anything else is treated as schema DDL and skipped.
    """
    n = 0
    in_func = False
    dollar_tag = None
    in_trigger = False
    for raw in text.splitlines():
        line = raw
        if BLANK_RE.match(line) or SQL_COMMENT_RE.match(line):
            # comment/blank lines never count, even inside a function
            continue

        stripped = line.strip()

        # Enter/exit CREATE FUNCTION dollar-quoted body.
        if not in_func and re.search(r"CREATE\s+(OR\s+REPLACE\s+)?FUNCTION", stripped, re.IGNORECASE):
            in_func = True
            n += 1
            m = re.search(r"AS\s+(\$[A-Za-z_]*\$)", stripped)
            if m:
                dollar_tag = m.group(1)
                if stripped.count(dollar_tag) >= 2:
                    in_func = False
                    dollar_tag = None
            continue

        if in_func:
            n += 1
            if dollar_tag and dollar_tag in stripped:
                in_func = False
                dollar_tag = None
            elif dollar_tag is None:
                # Rare — CREATE FUNCTION spanning lines before AS $$. Look
                # for it here.
                m = re.search(r"AS\s+(\$[A-Za-z_]*\$)", stripped)
                if m:
                    dollar_tag = m.group(1)
                    if stripped.count(dollar_tag) >= 2:
                        in_func = False
                        dollar_tag = None
            continue

        # CREATE TRIGGER … EXECUTE FUNCTION …;  usually multi-line.
        if not in_trigger and re.search(r"CREATE\s+TRIGGER", stripped, re.IGNORECASE):
            in_trigger = True
            n += 1
            if stripped.endswith(";"):
                in_trigger = False
            continue
        if in_trigger:
            n += 1
            if stripped.endswith(";"):
                in_trigger = False
            continue

        # Inline CHECK constraints in table definitions still count as guard.
        if "CHECK (" in stripped.upper():
            n += 1
            continue

        # Everything else (CREATE TABLE, INDEX, SCHEMA, EXTENSION, DOMAIN,
        # TYPE, ALTER, COMMENT ON, SELECT add_provenance, …) is treated as
        # schema/setup and skipped.
    return n


def _py_guard_loc(text: str) -> int:
    n = 0
    in_docstring = False
    doc_delim = None
    for raw in text.splitlines():
        s = raw.strip()
        if BLANK_RE.match(raw):
            continue
        if not in_docstring:
            if s.startswith(('"""', "'''")):
                delim = s[:3]
                if s.count(delim) >= 2 and len(s) > 3:
                    # single-line docstring
                    continue
                in_docstring = True
                doc_delim = delim
                continue
            if PY_COMMENT_RE.match(raw):
                continue
            n += 1
        else:
            if doc_delim and doc_delim in s:
                in_docstring = False
                doc_delim = None
            continue
    return n


TARGETS = [
    ("kndb", [
        REPO / "engine/03_triggers_epistemic.sql",
        REPO / "engine/04_triggers_conflict.sql",
        REPO / "engine/05_bitemporal.sql",
        REPO / "engine/06_provsql_setup.sql",
        REPO / "engine/07_progressive_depth.sql",
    ]),
    ("pg_naive", [
        # zero guard code by construction
    ]),
    ("py_guards", [
        REPO / "baselines/py_guards/guards.py",
    ]),
    ("pg_handrolled_triggers", [
        REPO / "baselines/pg_handrolled_triggers/schema.sql",
    ]),
]


def main() -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []
    for name, files in TARGETS:
        total = 0
        per_file: list[tuple[str, int]] = []
        for p in files:
            if not p.exists():
                continue
            text = p.read_text()
            if p.suffix == ".sql":
                loc = _sql_guard_loc(text)
            else:
                loc = _py_guard_loc(text)
            total += loc
            per_file.append((str(p.relative_to(REPO)), loc))
        rows.append(dict(system=name, guard_loc=total, files=" | ".join(f"{f}:{l}" for f, l in per_file)))

    with open(RESULTS / "loc.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["system", "guard_loc", "files"])
        w.writeheader()
        for r in rows:
            w.writerow(r)

    print(f"{'system':<30} {'guard_loc':>10}")
    print("-" * 42)
    for r in rows:
        print(f"{r['system']:<30} {r['guard_loc']:>10}")
        if r["files"]:
            for chunk in r["files"].split(" | "):
                print(f"    {chunk}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
