"""Where things live, and how the pieces find each other."""

from __future__ import annotations

import os
from pathlib import Path

APP_NAME = "cctrack"


def data_dir() -> Path:
    """Per-user data directory. Holds the database and browser profile."""
    root = os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share"
    return Path(root) / APP_NAME


def db_path() -> Path:
    """Database location. $CCTRACK_DB wins so tests and one-offs stay isolated."""
    override = os.environ.get("CCTRACK_DB")
    return Path(override) if override else data_dir() / "cctrack.db"


def downloads_dir() -> Path:
    """Where CSVs land. Gitignored: these hold real transactions."""
    override = os.environ.get("CCTRACK_DOWNLOADS")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "downloads"


# CSV filename prefix -> (display name, kind). The prefix is what
# cibc_web.download_transactions slugs the account label into.
ACCOUNTS: dict[str, tuple[str, str]] = {
    "visa": ("CIBC VISA", "credit"),
    "chequing": ("Chequing", "debit"),
    "savings": ("Savings", "debit"),
}

SYNC_OVERLAP_DAYS = 5
"""How far before the newest stored transaction a sync re-requests.

Transactions can post a few days after they occur, so a window starting
exactly at the newest stored date would miss late arrivals. Overlap is free --
the importer deduplicates -- while a gap silently loses money.
"""
