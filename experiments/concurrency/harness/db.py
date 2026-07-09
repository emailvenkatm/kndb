"""Connection factory and isolation context for the concurrency harness.

Every scenario opens its own psycopg 3 connection. Never share a connection
across threads: psycopg 3 documents this as unsafe, and the harness is
explicitly measuring what happens when N distinct sessions hit the same
slot.
"""
from __future__ import annotations

import os
import sys
from contextlib import contextmanager
from typing import Iterator, Literal

import psycopg


DEFAULT_DSN = os.environ.get(
    "KNDB_CONCUR_DSN",
    "postgresql://kndb_native@localhost:5434/kndb_concur",
)


IsolationLevel = Literal["READ COMMITTED", "SERIALIZABLE"]


def open_connection(
    isolation: IsolationLevel = "READ COMMITTED",
    dsn: str = DEFAULT_DSN,
    autocommit: bool = False,
) -> psycopg.Connection:
    """Open a new connection at the requested isolation level.

    We use SET SESSION CHARACTERISTICS so every transaction on this
    connection inherits the target isolation without per-transaction
    boilerplate.
    """
    conn = psycopg.connect(dsn, autocommit=autocommit)
    with conn.cursor() as cur:
        cur.execute(
            f"SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL {isolation}"
        )
    if not autocommit:
        conn.commit()
    return conn


@contextmanager
def transaction(conn: psycopg.Connection) -> Iterator[psycopg.Cursor]:
    """Yield a cursor inside a fresh transaction. Commits on clean exit,
    rolls back on exception. Errors are re-raised.
    """
    with conn.cursor() as cur:
        try:
            yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise


def truncate_fact_state(conn: psycopg.Connection) -> None:
    """Clear kndb.fact + audit + policy tables. Preserves slot_kind so R5
    stays registered across scenarios.
    """
    with conn.cursor() as cur:
        cur.execute(
            "TRUNCATE kndb.fact, kndb_audit.evicted_fact, kndb.conflict_policy CASCADE"
        )
    conn.commit()


def query_server_provenance(conn: psycopg.Connection) -> dict:
    """Return a dict with the strings we want to write into every result
    manifest for reviewer verification.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT version()")
        server_version = cur.fetchone()[0]
        cur.execute(
            "SELECT extversion FROM pg_extension WHERE extname = 'provsql'"
        )
        row = cur.fetchone()
        provsql_version = row[0] if row else None
        cur.execute("SHOW max_connections")
        max_conn = cur.fetchone()[0]
        cur.execute(
            "SELECT current_database(), current_setting('server_encoding')"
        )
        dbname, encoding = cur.fetchone()
    return {
        "server_version": server_version,
        "provsql_version": provsql_version,
        "max_connections": int(max_conn),
        "database": dbname,
        "server_encoding": encoding,
    }


def _print_ok(label: str) -> None:
    print(f"[db.py] {label}", file=sys.stderr, flush=True)
