"""Applying categories: by rule in bulk, or by hand one at a time.

The hand path is the interesting one. Tagging a transaction also proposes a
rule derived from its description, so tagging one Amazon charge can clear
every other Amazon charge in the queue.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass

from cctrack.rules import Rule, add_rule, all_rules, compile_rule, derive_pattern


@dataclass
class CategorizeResult:
    categorized: int
    remaining: int
    by_rule: dict[int, int]


def categorize(con: sqlite3.Connection, rules: list[Rule] | None = None) -> CategorizeResult:
    """Apply rules to every uncategorized transaction.

    Only touches rows where category_id IS NULL, so a manual decision is never
    overwritten by a pattern. A human who tagged something meant it; a regex
    that disagrees is the thing that is wrong.
    """
    rules = rules if rules is not None else all_rules(con)
    ordered = sorted(rules, key=lambda r: (r.priority, r.id))
    compiled = [(r, c) for r in ordered if (c := compile_rule(r)) is not None]

    pending = con.execute(
        "SELECT id, description FROM transactions WHERE category_id IS NULL"
    ).fetchall()

    updates = []
    hits: dict[int, int] = {}
    for row in pending:
        for rule, pattern in compiled:
            if pattern.search(row["description"]):
                updates.append((rule.category_id, row["id"]))
                hits[rule.id] = hits.get(rule.id, 0) + 1
                break

    if updates:
        with con:
            con.executemany(
                "UPDATE transactions SET category_id = ?, category_source = 'rule' "
                "WHERE id = ? AND category_id IS NULL",
                updates,
            )

    remaining = con.execute(
        "SELECT count(*) n FROM transactions WHERE category_id IS NULL"
    ).fetchone()["n"]
    return CategorizeResult(len(updates), remaining, hits)


def set_category(
    con: sqlite3.Connection, tx_id: int, category_id: int, *, source: str = "manual"
) -> None:
    """Assign a category to one transaction, overriding any rule guess."""
    with con:
        con.execute(
            "UPDATE transactions SET category_id = ?, category_source = ? WHERE id = ?",
            (category_id, source, tx_id),
        )


@dataclass
class RuleProposal:
    pattern: str
    matches_pending: int
    matches_all: int

    @property
    def clears_others(self) -> int:
        """Pending transactions beyond the one just tagged."""
        return max(0, self.matches_pending - 1)


def propose_rule(con: sqlite3.Connection, description: str) -> RuleProposal | None:
    """Derive a rule from a description and count what it would claim.

    Returns None when no safe pattern can be derived. The counts are the point:
    they are shown before saving so a too-greedy pattern is visible as a number
    rather than discovered later as a wrongly categorized month.
    """
    pattern = derive_pattern(description)
    if pattern is None:
        return None

    compiled = re.compile(pattern, re.IGNORECASE)
    pending = all_rows = 0
    for row in con.execute("SELECT description, category_id FROM transactions"):
        if compiled.search(row["description"]):
            all_rows += 1
            if row["category_id"] is None:
                pending += 1
    return RuleProposal(pattern, pending, all_rows)


def tag_and_learn(
    con: sqlite3.Connection,
    tx_id: int,
    category_id: int,
    *,
    save_rule: bool = True,
) -> tuple[int, RuleProposal | None]:
    """Tag one transaction and optionally learn a rule from it.

    Returns (transactions categorized, the proposal). The count includes the
    tagged transaction itself plus everything the new rule then cleared.
    """
    row = con.execute(
        "SELECT description FROM transactions WHERE id = ?", (tx_id,)
    ).fetchone()
    if row is None:
        raise ValueError(f"no transaction {tx_id}")

    proposal = propose_rule(con, row["description"])
    set_category(con, tx_id, category_id)

    if not (save_rule and proposal):
        return 1, proposal

    add_rule(con, proposal.pattern, category_id, origin="learned")
    # Apply immediately: the value of learning is that the queue shrinks now,
    # not on some later run.
    result = categorize(con)
    return 1 + result.categorized, proposal
