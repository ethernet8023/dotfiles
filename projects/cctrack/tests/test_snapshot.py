"""`cctrack snapshot` -- the dev loop's copy of production."""

from __future__ import annotations

import sqlite3

from typer.testing import CliRunner

from cctrack.cli import app
from cctrack.db import connect

runner = CliRunner()


def _seeded(path):
    con = connect(path)
    con.execute("INSERT INTO accounts (name, kind) VALUES ('CIBC VISA', 'credit')")
    con.execute(
        "INSERT INTO transactions "
        "(account_id, posted_on, description, amount_cents, fingerprint, imported_at) "
        "VALUES (1, '2026-07-30', 'AMZN Mktp CA', -1234, 'fp1', '2026-07-31T00:00:00Z')"
    )
    con.commit()
    return con


def test_snapshot_copies_the_rows(tmp_path):
    src = tmp_path / "prod.db"
    _seeded(src).close()
    dest = tmp_path / "out" / "copy.db"

    result = runner.invoke(app, ["snapshot", str(dest), "--db", str(src)])
    assert result.exit_code == 0, result.output

    copy = sqlite3.connect(dest)
    assert copy.execute("SELECT count(*) FROM transactions").fetchone()[0] == 1
    assert copy.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    copy.close()


def test_snapshot_is_safe_while_the_source_is_open(tmp_path):
    src = tmp_path / "prod.db"
    live = _seeded(src)
    dest = tmp_path / "copy.db"

    result = runner.invoke(app, ["snapshot", str(dest), "--db", str(src)])
    assert result.exit_code == 0, result.output

    # The source is still usable afterwards, which is the whole point: the
    # server holds it open while the dev loop copies it.
    live.execute(
        "INSERT INTO transactions "
        "(account_id, posted_on, description, amount_cents, fingerprint, imported_at) "
        "VALUES (1, '2026-07-31', 'later', -100, 'fp2', '2026-07-31T00:00:00Z')"
    )
    live.commit()
    assert live.execute("SELECT count(*) FROM transactions").fetchone()[0] == 2
    live.close()


def test_snapshot_overwrites_an_existing_copy(tmp_path):
    src = tmp_path / "prod.db"
    _seeded(src).close()
    dest = tmp_path / "copy.db"
    dest.write_bytes(b"not a database")

    result = runner.invoke(app, ["snapshot", str(dest), "--db", str(src)])
    assert result.exit_code == 0, result.output
    assert sqlite3.connect(dest).execute(
        "SELECT count(*) FROM transactions"
    ).fetchone()[0] == 1


def test_snapshot_without_a_database_exits_nonzero(tmp_path):
    result = runner.invoke(
        app, ["snapshot", str(tmp_path / "copy.db"), "--db", str(tmp_path / "missing.db")]
    )
    assert result.exit_code == 1
    assert "no database" in result.output
