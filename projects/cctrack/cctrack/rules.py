"""Rule engine: match a transaction description to a category.

Rules are regexes stored in the database, evaluated in priority order. They
come from two places: seeded defaults, and patterns learned when a human tags
something by hand.

The learning half is the risky half. A pattern derived too greedily from one
charge will silently recategorize hundreds of unrelated ones, so derivation is
deliberately conservative and every proposal is shown with its match count
before it is saved.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime

log = logging.getLogger(__name__)

MIN_PATTERN_LENGTH = 5
"""Shortest stem allowed as a learned rule.

Measured against the real history: the stem 'SQ' (from Square's 'SQ *MERCHANT'
prefix) matches 639 transactions across dozens of unrelated merchants, while
matching only 2 exactly. Anything this short is a category-wide accident
waiting to happen.
"""

# Bank-added prefixes on debit rows. The merchant sits after these, so a
# pattern anchored at the start of the string would never match.
BANK_PREFIX = re.compile(
    r"^(Point of Sale - (?:Interac|Visa Debit)|Internet Banking"
    r"|Branch Transaction|Electronic Funds Transfer"
    r"|Automated Banking Machine)\s+",
    re.IGNORECASE,
)

NOISE = (
    # Transaction-type boilerplate.
    (re.compile(r"\b(?:INTL )?(?:VISA DEB )?RETAIL PURCHASE\b\s*", re.IGNORECASE), ""),
    # Long digit runs are reference numbers, never part of a merchant name.
    (re.compile(r"\b\d{8,}\b\s*"), ""),
    # Foreign-currency tail: "12.34 EUR @ 1.4567".
    (re.compile(r"\s+\d+\.\d+\s+[A-Z]{3}\s+@\s*[\d.]+\s*$"), ""),
    # Store numbers: "#25339".
    (re.compile(r"\s*#\s*\d+"), ""),
    # Order refs like "*132DP4PV3". The digit requirement matters: without it
    # this eats "*AGENDA" from "SQ *AGENDA CAFE" and leaves the stem "SQ CAFE".
    (re.compile(r"\*(?=[A-Z0-9]*\d)[A-Z0-9]{6,}\b"), ""),
    # Trailing city and province.
    (re.compile(r",?\s*(?:TORONTO|VERDUN|MONTREAL|OTTAWA|VANCOUVER|CALGARY)"
                r"\s*,?\s*(?:ON|QC|AB|BC|MB|NS|SK)?\s*$", re.IGNORECASE), ""),
    (re.compile(r",\s*[A-Z]{2}\s*$"), ""),
    (re.compile(r"\s+WWW\.[A-Z0-9.\-]+", re.IGNORECASE), ""),
    # Phone numbers merchants append.
    (re.compile(r"\s+\d{3}-\d{3}-\d{4}\b"), ""),
)


@dataclass(frozen=True)
class Rule:
    id: int
    pattern: str
    category_id: int
    priority: int
    origin: str  # 'seed' | 'learned'


def derive_pattern(description: str) -> str | None:
    """Propose a regex matching this merchant but not the whole world.

    Strips the parts that vary between visits -- store number, city, order
    reference, FX tail -- and keeps what identifies the merchant. Returns None
    when the result is too short to be safe.

    Deliberately does not collapse further. 'UBER CANADA/UBEREATS' (505 rows,
    restaurants) and 'UBER CANADA/UBERTRIP' (403 rows, transit) share a prefix
    and belong to different categories; a stem of 'UBER' would merge them.
    """
    stem = BANK_PREFIX.sub("", description)
    for pattern, replacement in NOISE:
        stem = pattern.sub(replacement, stem)
    stem = re.sub(r"\s+", " ", stem).strip(" -*,")

    if len(stem) < MIN_PATTERN_LENGTH:
        return None
    return f"^{re.escape(stem)}"


def compile_rule(rule: Rule) -> re.Pattern | None:
    """Compile a rule's regex, or None if it is invalid.

    A hand-edited or malformed pattern must not take categorization down for
    every other rule.
    """
    try:
        return re.compile(rule.pattern, re.IGNORECASE)
    except re.error as exc:
        log.warning("skipping rule %s: bad regex %r (%s)", rule.id, rule.pattern, exc)
        return None


def match(description: str, rules: list[Rule]) -> Rule | None:
    """First rule whose pattern matches. Lowest priority wins, then oldest id."""
    for rule in sorted(rules, key=lambda r: (r.priority, r.id)):
        compiled = compile_rule(rule)
        if compiled and compiled.search(description):
            return rule
    return None


# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------


def all_rules(con: sqlite3.Connection) -> list[Rule]:
    return [
        Rule(r["id"], r["pattern"], r["category_id"], r["priority"], r["origin"])
        for r in con.execute(
            "SELECT id, pattern, category_id, priority, origin FROM rules "
            "ORDER BY priority, id"
        )
    ]


def add_rule(
    con: sqlite3.Connection,
    pattern: str,
    category_id: int,
    *,
    priority: int = 100,
    origin: str = "learned",
) -> int:
    """Store a rule. Rejects a pattern that does not compile."""
    try:
        re.compile(pattern)
    except re.error as exc:
        raise ValueError(f"invalid regex {pattern!r}: {exc}") from exc

    with con:
        cur = con.execute(
            "INSERT INTO rules (pattern, category_id, priority, origin, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (pattern, category_id, priority, origin, datetime.now(UTC).isoformat()),
        )
    return cur.lastrowid


def delete_rule(con: sqlite3.Connection, rule_id: int) -> None:
    with con:
        con.execute("DELETE FROM rules WHERE id = ?", (rule_id,))


def would_match(con: sqlite3.Connection, pattern: str, *, pending_only: bool = True) -> int:
    """How many transactions this pattern would claim.

    Shown before a rule is saved. The number is the whole safety mechanism:
    a stem like 'SQ' looks harmless until you see it would take 639 rows.
    """
    try:
        compiled = re.compile(pattern, re.IGNORECASE)
    except re.error as exc:
        raise ValueError(f"invalid regex {pattern!r}: {exc}") from exc

    sql = "SELECT description FROM transactions"
    if pending_only:
        sql += " WHERE category_id IS NULL"
    return sum(1 for r in con.execute(sql) if compiled.search(r["description"]))
