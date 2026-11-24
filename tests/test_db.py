"""Schema and migration tests."""

from __future__ import annotations

import sqlite3

import pytest

from cctrack.db import connect, migrations, schema_version
from cctrack.ingest.cibc_csv import channel_of

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


# --- 002, the channel backfill --------------------------------------------


def _v1_db(path):
    """A database at schema 001, before the channel column existed."""
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript(
        next(p for v, p in migrations() if v == 1).read_text()
    )
    con.execute("PRAGMA user_version = 1")
    con.execute("INSERT INTO accounts (id, name, kind) VALUES (1, 'Chequing', 'debit')")
    con.commit()
    return con


def _insert_v1(con, description, n=[0]):  # noqa: B006 - a counter, deliberately
    n[0] += 1
    con.execute(
        "INSERT INTO transactions (account_id, posted_on, description, "
        "amount_cents, fingerprint, imported_at) "
        "VALUES (1, '2026-01-01', ?, -100, ?, '2026-01-01T00:00:00Z')",
        (description, f"fp{n[0]}"),
    )
    con.commit()


def test_the_backfill_matches_what_the_parser_would_say(tmp_path):
    """The SQL and the Python must classify a description identically.

    Old rows are labelled by the migration and new ones by the parser. If the
    two ever disagree the same charge reads as a tap or as nothing depending
    on when it was imported, and no error is ever raised.
    """
    descriptions = [
        "Point of Sale - Interac RETAIL PURCHASE 621000521008 DAYALI BEIJING",
        "Point of Sale - Visa Debit INTL VISA DEB RETAIL PURCHASE DL",
        "Automated Banking Machine ATM WITHDRAWAL COLLEGE and GRACE 4C96",
        "Electronic Funds Transfer PREAUTHORIZED DEBIT ROGERS",
        "Internet Banking INTERNET TRANSFER 000000111577 TO CARD",
        "Branch Transaction SERVICE CHARGE",
        "TIM HORTONS #1234 TORONTO ON",          # a VISA row: no prefix
        "BRANCH TRANSACTION SERVICE CHARGE",     # wrong case: not a match
    ]

    path = tmp_path / "t.db"
    con = _v1_db(path)
    for description in descriptions:
        _insert_v1(con, description)
    con.close()

    con = connect(path)  # applies 002
    backfilled = {
        r["description"]: r["channel"]
        for r in con.execute("SELECT description, channel FROM transactions")
    }
    assert backfilled == {d: channel_of(d) for d in descriptions}


def test_the_backfill_leaves_descriptions_alone(tmp_path):
    """Rewriting a description would change its fingerprint and re-import it."""
    path = tmp_path / "t.db"
    con = _v1_db(path)
    _insert_v1(con, "Branch Transaction SERVICE CHARGE")
    before = con.execute("SELECT description, fingerprint FROM transactions").fetchone()
    con.close()

    con = connect(path)
    after = con.execute("SELECT description, fingerprint FROM transactions").fetchone()
    assert tuple(after) == tuple(before)


def test_migrating_an_empty_v1_database_is_fine(tmp_path):
    path = tmp_path / "t.db"
    _v1_db(path).close()
    con = connect(path)
    assert schema_version(con) == max(v for v, _ in migrations())
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 0
