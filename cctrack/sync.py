"""One command's worth of work: download what is new, import it.

Kept separate from the CLI so the interesting decisions -- which window to
request, what counts as success -- can be tested without a browser.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from cctrack.config import ACCOUNTS, SYNC_OVERLAP_DAYS
from cctrack.ingest.cibc_csv import ParseError, parse_csv
from cctrack.ingest.importer import ensure_account, import_transactions


@dataclass
class SyncResult:
    downloaded: list[Path] = field(default_factory=list)
    imported: dict[str, int] = field(default_factory=dict)
    empty: int = 0
    failed: list[str] = field(default_factory=list)

    @property
    def total_imported(self) -> int:
        return sum(self.imported.values())

    @property
    def ok(self) -> bool:
        return not self.failed


def newest_transaction(con: sqlite3.Connection, account_name: str) -> date | None:
    """Date of the most recent stored transaction for an account."""
    row = con.execute(
        "SELECT max(t.posted_on) AS newest FROM transactions t "
        "JOIN accounts a ON a.id = t.account_id WHERE a.name = ?",
        (account_name,),
    ).fetchone()
    if not row or not row["newest"]:
        return None
    return date.fromisoformat(row["newest"])


def sync_window(
    con: sqlite3.Connection,
    account_name: str,
    *,
    today: date | None = None,
    overlap_days: int = SYNC_OVERLAP_DAYS,
    default_days: int = 400,
) -> tuple[date, date]:
    """The date range a sync should request for one account.

    Starts `overlap_days` before the newest stored transaction rather than at
    it: purchases can post days after they happen, so an exact-boundary window
    would skip late arrivals. Re-requesting a few days costs nothing because
    the importer deduplicates, whereas a gap loses transactions silently.

    An empty account falls back to `default_days`, which is a routine backfill
    rather than the full retention depth -- pass an explicit start for that.
    """
    today = today or datetime.now(UTC).date()
    newest = newest_transaction(con, account_name)
    start = (
        newest - timedelta(days=overlap_days)
        if newest
        else today - timedelta(days=default_days)
    )
    # A clock skew or a future-dated transaction must not invert the range.
    return min(start, today), today


def import_files(
    con: sqlite3.Connection, paths: Iterable[Path]
) -> tuple[dict[str, int], list[str]]:
    """Import downloaded CSVs. Returns (rows added per account, errors).

    One file at a time, deliberately. Downloaded windows overlap, so the true
    number of copies of a repeated charge is the most any single file shows,
    never the sum across files -- concatenating first would inflate it.
    """
    added: dict[str, int] = {}
    errors: list[str] = []

    for path in sorted(paths):
        slug = path.name.rsplit("-", 2)[0]
        if slug not in ACCOUNTS:
            errors.append(f"{path.name}: unknown account {slug!r}")
            continue

        name, kind = ACCOUNTS[slug]
        try:
            txs = parse_csv(path.read_text())
        except (ParseError, OSError) as exc:
            errors.append(f"{path.name}: {exc}")
            continue

        account_id = ensure_account(con, name, kind)
        added[name] = added.get(name, 0) + import_transactions(con, account_id, txs)

    return added, errors
