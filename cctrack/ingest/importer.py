"""Import parsed transactions into SQLite, idempotently.

CIBC's CSV carries no transaction id, so re-importing an overlapping window
must not duplicate rows -- and two genuinely separate identical charges on the
same day must both survive. See fingerprint() for how those are reconciled.
"""

from __future__ import annotations

import hashlib
import sqlite3
from collections import Counter
from datetime import UTC, datetime

from cctrack.ingest.cibc_csv import ParsedTx, parse_csv


def fingerprint(account_id: int, tx: ParsedTx, ordinal: int) -> str:
    """Stable identity for a transaction.

    There is no transaction id in the export, so identity is the natural key
    plus an ordinal: the 0-based index of this row among identical rows for the
    same account and day.

    The ordinal is what makes two real $4.50 coffees on one day distinct while
    keeping a re-import idempotent -- a repeated window reproduces the same
    ordinals, so the same fingerprints, so INSERT OR IGNORE drops them. A third
    coffee appears as ordinal 2 and lands.

    Card is excluded deliberately: the same charge can be reported under a
    different card number after a reissue, and including it would duplicate.
    """
    key = "\x1f".join([
        str(account_id),
        tx.posted_on,
        tx.description,
        str(tx.amount_cents),
        str(ordinal),
    ])
    return hashlib.sha256(key.encode()).hexdigest()


def ensure_account(
    con: sqlite3.Connection, name: str, kind: str, card_last4: str | None = None
) -> int:
    """Return the id of an account, creating it if needed."""
    row = con.execute("SELECT id FROM accounts WHERE name = ?", (name,)).fetchone()
    if row:
        return row[0]
    with con:
        cur = con.execute(
            "INSERT INTO accounts (name, kind, card_last4) VALUES (?, ?, ?)",
            (name, kind, card_last4),
        )
    if cur.lastrowid is None:  # pragma: no cover - sqlite always sets this
        raise RuntimeError(f"insert of account {name!r} returned no rowid")
    return cur.lastrowid


def assign_ordinals(txs: list[ParsedTx]) -> list[int]:
    """Ordinal per transaction: its index among identical siblings in this list."""
    seen: Counter[tuple[str, str, int]] = Counter()
    ordinals = []
    for tx in txs:
        key = (tx.posted_on, tx.description, tx.amount_cents)
        ordinals.append(seen[key])
        seen[key] += 1
    return ordinals


def import_transactions(
    con: sqlite3.Connection, account_id: int, txs: list[ParsedTx]
) -> int:
    """Insert transactions, skipping ones already present. Returns rows added.

    Ordinals are counted *per (day, description, amount) group* and compared
    against what the database already holds for that group, so importing
    overlapping windows converges on the true multiplicity instead of adding a
    fresh copy each time.

    Getting this wrong is expensive and quiet: an earlier version numbered
    ordinals per batch, which let overlapping downloads insert the same charge
    repeatedly -- 8,733 rows stored where the files held 6,211.
    """
    if not txs:
        return 0

    # How many copies of each identical charge does this batch have?
    wanted = Counter(
        (tx.posted_on, tx.description, tx.amount_cents) for tx in txs
    )

    # And how many does the database already hold?
    have: Counter[tuple[str, str, int]] = Counter()
    for row in con.execute(
        "SELECT posted_on, description, amount_cents, count(*) n "
        "FROM transactions WHERE account_id = ? "
        "GROUP BY posted_on, description, amount_cents",
        (account_id,),
    ):
        have[(row["posted_on"], row["description"], row["amount_cents"])] = row["n"]

    # Keep one sample per group, for the fields not in the key (the card).
    sample = {}
    for tx in txs:
        sample.setdefault((tx.posted_on, tx.description, tx.amount_cents), tx)

    # Insert only the shortfall for each group, numbering on from what exists.
    now = datetime.now(UTC).isoformat()
    rows = [
        (
            account_id, key[0], key[1], key[2], sample[key].card_last4,
            fingerprint(account_id, sample[key], ordinal), now,
        )
        for key, needed in wanted.items()
        for ordinal in range(have[key], max(have[key], needed))
    ]

    if not rows:
        return 0

    with con:
        before = con.total_changes
        con.executemany(
            "INSERT OR IGNORE INTO transactions "
            "(account_id, posted_on, description, amount_cents, card_last4, "
            " fingerprint, imported_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            rows,
        )
        return con.total_changes - before


def import_csv(con: sqlite3.Connection, account_id: int, text: str) -> int:
    """Parse CSV text and import it. Returns the number of rows added."""
    return import_transactions(con, account_id, parse_csv(text))
