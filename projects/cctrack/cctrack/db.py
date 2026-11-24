"""SQLite connection and schema migrations.

Migrations are plain .sql files named NNN_description.sql. connect() applies
every file numbered above the database's current user_version, in order, each
inside its own transaction.
"""

from __future__ import annotations

import re
import sqlite3
from pathlib import Path

MIGRATIONS_DIR = Path(__file__).parent / "migrations"
MIGRATION_RE = re.compile(r"^(\d+)_.*\.sql$")


def default_db_path() -> Path:
    """Where the database lives unless a caller says otherwise."""
    return Path.home() / ".local/share/cctrack/cctrack.db"


def migrations() -> list[tuple[int, Path]]:
    """Every migration on disk, oldest first."""
    found = []
    for path in MIGRATIONS_DIR.glob("*.sql"):
        match = MIGRATION_RE.match(path.name)
        if match:
            found.append((int(match.group(1)), path))
    return sorted(found)


def schema_version(con: sqlite3.Connection) -> int:
    return con.execute("PRAGMA user_version").fetchone()[0]


def connect(path: Path | str | None = None) -> sqlite3.Connection:
    """Open the database, applying any pending migrations.

    Idempotent: opening an up-to-date database applies nothing.
    """
    path = Path(path) if path is not None else default_db_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    # Foreign keys are off by default in SQLite, which would silently allow
    # orphaned splits.
    con.execute("PRAGMA foreign_keys = ON")
    con.execute("PRAGMA journal_mode = WAL")

    current = schema_version(con)
    for version, sql_path in migrations():
        if version <= current:
            continue
        with con:  # commits on success, rolls back on error
            con.executescript(sql_path.read_text())
            # executescript commits any open transaction, so set the version
            # after it rather than relying on the enclosing one.
            con.execute(f"PRAGMA user_version = {version}")
    return con
