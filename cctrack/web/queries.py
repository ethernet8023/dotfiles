"""Read queries for the web UI.

Separate from the views so the numbers can be tested without HTTP, and so the
CLI and the UI cannot disagree about what a total means.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, date, datetime

from cctrack.ingest.cibc_csv import CARD_PRESENT_CHANNELS

# Human wording for a stored channel. A channel absent from this map is shown
# by its stored value rather than hidden, so a new CIBC prefix is visible as
# soon as it lands instead of silently reading as unknown.
CHANNEL_LABELS = {
    "interac_pos": "Interac tap",
    "visa_debit_pos": "Visa Debit",
    "abm": "ATM",
    "eft": "Preauthorized",
    "online_banking": "Online",
    "branch": "Branch",
}


def channel_label(channel: str | None) -> str:
    """What to print for a channel. Unknown is shown, not blanked."""
    if channel is None:
        return "+?"
    return CHANNEL_LABELS.get(channel, channel)


@dataclass(frozen=True)
class AccountSummary:
    name: str
    rows: int
    first: str
    last: str
    net_cents: int


def account_summaries(con: sqlite3.Connection) -> list[AccountSummary]:
    return [
        AccountSummary(r["name"], r["n"], r["lo"], r["hi"], r["net"])
        for r in con.execute(
            "SELECT a.name, count(*) n, min(t.posted_on) lo, max(t.posted_on) hi, "
            "       sum(t.amount_cents) net "
            "FROM transactions t JOIN accounts a ON a.id = t.account_id "
            "GROUP BY a.name ORDER BY a.name"
        )
    ]


def uncategorized_count(con: sqlite3.Connection) -> int:
    return con.execute(
        "SELECT count(*) n FROM transactions WHERE category_id IS NULL"
    ).fetchone()["n"]


def month_spend(con: sqlite3.Connection, months: int = 12) -> list[tuple[str, int]]:
    """(YYYY-MM, cents spent) oldest first.

    Spend only: outgoing money, sign-flipped to positive. Payments and refunds
    are excluded rather than netted, because a big card payment would otherwise
    show up as a month where you spent nothing.
    """
    rows = con.execute(
        "SELECT substr(posted_on, 1, 7) AS month, "
        "       sum(CASE WHEN amount_cents < 0 THEN -amount_cents ELSE 0 END) AS spent "
        "FROM transactions GROUP BY month ORDER BY month DESC LIMIT ?",
        (months,),
    ).fetchall()
    return [(r["month"], r["spent"]) for r in reversed(rows)]


def daily_cumulative(
    con: sqlite3.Connection, month: str
) -> list[tuple[str, int]]:
    """Running total spent per day within one 'YYYY-MM'.

    Stops at the last day with data rather than running to month end: drawing
    a flat line across days that have not happened yet reads as "spent
    nothing", which is a lie about the future.
    """
    rows = con.execute(
        "SELECT posted_on, "
        "       sum(CASE WHEN amount_cents < 0 THEN -amount_cents ELSE 0 END) AS spent "
        "FROM transactions WHERE substr(posted_on, 1, 7) = ? "
        "GROUP BY posted_on ORDER BY posted_on",
        (month,),
    ).fetchall()

    running = 0
    out = []
    for r in rows:
        running += r["spent"]
        out.append((r["posted_on"], running))
    return out


def recent_transactions(
    con: sqlite3.Connection,
    *,
    limit: int = 100,
    offset: int = 0,
    account: str | None = None,
    search: str | None = None,
    uncategorized_only: bool = False,
    channel: str | None = None,
) -> list[sqlite3.Row]:
    where = []
    params: list[object] = []
    if account:
        where.append("a.name = ?")
        params.append(account)
    if search:
        where.append("t.description LIKE ?")
        params.append(f"%{search}%")
    if uncategorized_only:
        where.append("t.category_id IS NULL")
    if channel:
        where.append("t.channel = ?")
        params.append(channel)

    clause = f"WHERE {' AND '.join(where)}" if where else ""
    params.extend([limit, offset])
    return con.execute(
        f"SELECT t.id, t.posted_on, t.description, t.amount_cents, t.card_last4, "
        f"       t.channel, a.name AS account, c.name AS category "
        f"FROM transactions t "
        f"JOIN accounts a ON a.id = t.account_id "
        f"LEFT JOIN categories c ON c.id = t.category_id "
        f"{clause} ORDER BY t.posted_on DESC, t.id DESC LIMIT ? OFFSET ?",
        params,
    ).fetchall()


def count_transactions(
    con: sqlite3.Connection,
    *,
    account: str | None = None,
    search: str | None = None,
    uncategorized_only: bool = False,
    channel: str | None = None,
) -> int:
    where = []
    params: list[object] = []
    if account:
        where.append("a.name = ?")
        params.append(account)
    if search:
        where.append("t.description LIKE ?")
        params.append(f"%{search}%")
    if uncategorized_only:
        where.append("t.category_id IS NULL")
    if channel:
        where.append("t.channel = ?")
        params.append(channel)

    clause = f"WHERE {' AND '.join(where)}" if where else ""
    return con.execute(
        f"SELECT count(*) n FROM transactions t "
        f"JOIN accounts a ON a.id = t.account_id {clause}",
        params,
    ).fetchone()["n"]


def last_card_present(con: sqlite3.Connection) -> sqlite3.Row | None:
    """The most recent transaction that needed the physical card in hand.

    Only the channels that cannot happen without the card at a terminal count
    -- an Interac tap or an ATM. Visa Debit is left out because CIBC uses the
    one prefix for both a tap in a shop and a card number typed into a
    website, so counting it would overstate the answer.

    Returns None when nothing qualifies, which includes a database holding
    only VISA rows: those carry no channel at all.
    """
    placeholders = ", ".join("?" * len(CARD_PRESENT_CHANNELS))
    return con.execute(
        f"SELECT t.posted_on, t.description, t.amount_cents, t.channel, "
        f"       a.name AS account "
        f"FROM transactions t JOIN accounts a ON a.id = t.account_id "
        f"WHERE t.channel IN ({placeholders}) "
        f"ORDER BY t.posted_on DESC, t.id DESC LIMIT 1",
        sorted(CARD_PRESENT_CHANNELS),
    ).fetchone()


def channel_counts(con: sqlite3.Connection) -> list[tuple[str | None, int]]:
    """(channel, rows) most common first, including the unknown bucket."""
    return [
        (r["channel"], r["n"])
        for r in con.execute(
            "SELECT channel, count(*) n FROM transactions "
            "GROUP BY channel ORDER BY n DESC"
        )
    ]


def account_names(con: sqlite3.Connection) -> list[str]:
    return [r["name"] for r in con.execute("SELECT name FROM accounts ORDER BY name")]


def current_month(today: date | None = None) -> str:
    return f"{today or datetime.now(UTC).date():%Y-%m}"
