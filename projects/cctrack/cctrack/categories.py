"""Categories: the small fixed vocabulary transactions get sorted into."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path

SEED_FILE = Path(__file__).parent / "data" / "seed_categories.json"


@dataclass(frozen=True)
class Category:
    id: int
    name: str


def seed_names() -> list[str]:
    data = json.loads(SEED_FILE.read_text())
    return [c["name"] for c in data["categories"]]


def add(con: sqlite3.Connection, name: str) -> int:
    """Create a category, or return the existing one's id.

    Names are compared case-insensitively so 'Fun' and 'fun' cannot both exist
    and quietly split a category's totals in two.
    """
    name = name.strip()
    if not name:
        raise ValueError("category name cannot be empty")

    row = con.execute(
        "SELECT id FROM categories WHERE lower(name) = lower(?)", (name,)
    ).fetchone()
    if row:
        return row[0]

    with con:
        cur = con.execute("INSERT INTO categories (name) VALUES (?)", (name,))
    return cur.lastrowid


def seed(con: sqlite3.Connection) -> int:
    """Ensure the starter categories exist. Returns how many were created."""
    before = count(con)
    for name in seed_names():
        add(con, name)
    return count(con) - before


def all_categories(con: sqlite3.Connection) -> list[Category]:
    return [
        Category(r["id"], r["name"])
        for r in con.execute("SELECT id, name FROM categories ORDER BY name")
    ]


def by_name(con: sqlite3.Connection, name: str) -> Category | None:
    row = con.execute(
        "SELECT id, name FROM categories WHERE lower(name) = lower(?)", (name,)
    ).fetchone()
    return Category(row["id"], row["name"]) if row else None


def count(con: sqlite3.Connection) -> int:
    return con.execute("SELECT count(*) n FROM categories").fetchone()["n"]


def usage(con: sqlite3.Connection) -> list[tuple[str, int, int]]:
    """(category, transaction count, total cents) for every category in use."""
    return [
        (r["name"], r["n"], r["total"])
        for r in con.execute(
            "SELECT c.name, count(t.id) n, "
            "       coalesce(sum(t.amount_cents), 0) total "
            "FROM categories c LEFT JOIN transactions t ON t.category_id = c.id "
            "GROUP BY c.id ORDER BY c.name"
        )
    ]
