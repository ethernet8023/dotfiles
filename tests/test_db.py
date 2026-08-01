"""Schema and migration tests."""

from __future__ import annotations

import sqlite3

import pytest

from cctrack.db import connect, migrations, schema_version

TABLES = {"accounts", "categories", "transactions", "splits", "rules", "plan"}


def test_connect_creates_the_schema(tmp_path):
    con = connect(tmp_path / "t.db")
    assert schema_version(con) == max(v for v, _ in migrations())
    names = {r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    assert TABLES <= names


def test_connect_is_idempotent(tmp_path):
    path = tmp_path / "t.db"
    connect(path).close()
    con = connect(path)
    assert schema_version(con) == max(v for v, _ in migrations())
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 0


def test_reopening_preserves_data(tmp_path):
    path = tmp_path / "t.db"
    con = connect(path)
    con.execute("INSERT INTO accounts (name, kind) VALUES ('a', 'credit')")
    con.commit()
    con.close()

    con = connect(path)
    assert con.execute("SELECT count(*) FROM accounts").fetchone()[0] == 1


def test_foreign_keys_are_enforced(tmp_path):
    """Off by default in SQLite, which would allow orphaned splits."""
    con = connect(tmp_path / "t.db")
    with pytest.raises(sqlite3.IntegrityError):
        con.execute(
            "INSERT INTO splits (parent_tx_id, category_id, amount_cents) "
            "VALUES (9999, 9999, 100)"
        )
        con.commit()


def test_fingerprint_is_unique(tmp_path):
    """The dedup guarantee is enforced by the database, not just by code."""
    con = connect(tmp_path / "t.db")
    con.execute("INSERT INTO accounts (id, name, kind) VALUES (1, 'a', 'credit')")
    row = ("1, '2026-01-01', 'x', -100, 'fp', '2026-01-01T00:00:00Z'")
    sql = ("INSERT INTO transactions (account_id, posted_on, description, "
           "amount_cents, fingerprint, imported_at) VALUES (" + row + ")")
    con.execute(sql)
    with pytest.raises(sqlite3.IntegrityError):
        con.execute(sql)


def test_splits_cascade_on_delete(tmp_path):
    """Deleting a parent must not leave orphaned splits behind."""
    con = connect(tmp_path / "t.db")
    con.execute("INSERT INTO accounts (id, name, kind) VALUES (1, 'a', 'credit')")
    con.execute("INSERT INTO categories (id, name) VALUES (1, 'fun')")
    con.execute(
        "INSERT INTO transactions (id, account_id, posted_on, description, "
        "amount_cents, fingerprint, imported_at) "
        "VALUES (1, 1, '2026-01-01', 'x', -100, 'fp', '2026-01-01T00:00:00Z')"
    )
    con.execute(
        "INSERT INTO splits (parent_tx_id, category_id, amount_cents) "
        "VALUES (1, 1, -100)"
    )
    con.commit()

    con.execute("DELETE FROM transactions WHERE id = 1")
    con.commit()
    assert con.execute("SELECT count(*) FROM splits").fetchone()[0] == 0


def test_migrations_are_numbered_uniquely():
    versions = [v for v, _ in migrations()]
    assert versions == sorted(versions)
    assert len(versions) == len(set(versions))
