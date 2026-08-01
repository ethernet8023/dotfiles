"""Import downloaded CIBC CSVs into the database.

    nix develop -c python3 scripts/import_csv.py
    nix develop -c python3 scripts/import_csv.py --db /tmp/test.db

Safe to rerun: transactions are deduplicated on a fingerprint, so importing
overlapping files twice adds nothing the second time.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from cctrack.db import connect, default_db_path
from cctrack.ingest.cibc_csv import ParseError, parse_csv
from cctrack.ingest.importer import ensure_account, import_transactions

DOWNLOADS = Path(__file__).resolve().parent.parent / "downloads"

# Account name in the CSV filename -> (display name, kind)
ACCOUNTS = {
    "visa": ("CIBC VISA", "credit"),
    "chequing": ("Chequing", "debit"),
    "savings": ("Savings", "debit"),
}


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", type=Path, default=None,
                    help=f"database path (default: {default_db_path()})")
    ap.add_argument("--downloads", type=Path, default=DOWNLOADS,
                    help="directory of CSVs to import")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    con = connect(args.db)

    files = sorted(args.downloads.glob("*.csv"))
    if not files:
        print(f"no CSVs in {args.downloads}", flush=True)
        return 1

    # Import file by file. Files overlap by design (chunked downloads share
    # boundaries, and re-runs cover old ground), so the true number of copies
    # of a repeated charge is the most any single file shows -- never the sum
    # across files. import_transactions reconciles each file against what is
    # already stored, so this converges; concatenating everything first would
    # instead add up the overlaps.
    print(f"\nimporting {len(files)} file(s)", flush=True)

    bad: list[tuple[Path, str]] = []
    added: dict[str, int] = {}
    seen: dict[str, int] = {}

    for path in files:
        slug = path.name.rsplit("-", 2)[0]
        if slug not in ACCOUNTS:
            print(f"  skipping {path.name}: unknown account {slug!r}", flush=True)
            continue
        try:
            txs = parse_csv(path.read_text())
        except ParseError as exc:
            bad.append((path, str(exc)))
            continue

        name, kind = ACCOUNTS[slug]
        account_id = ensure_account(con, name, kind)
        added[name] = added.get(name, 0) + import_transactions(con, account_id, txs)
        seen[name] = seen.get(name, 0) + len(txs)

    if bad:
        print(f"\n{len(bad)} file(s) failed to parse:", flush=True)
        for path, reason in bad:
            print(f"  {path.name}: {reason}", flush=True)
        return 1

    total = sum(added.values())
    for name in sorted(added):
        print(f"  {name:12} {seen[name]:>6} rows read  {added[name]:>6} new", flush=True)

    print(f"\n{total} transaction(s) added", flush=True)
    rows = con.execute(
        "SELECT a.name, count(*) n, min(t.posted_on) lo, max(t.posted_on) hi, "
        "       sum(t.amount_cents) net "
        "FROM transactions t JOIN accounts a ON a.id = t.account_id "
        "GROUP BY a.name ORDER BY a.name"
    ).fetchall()
    print("\nin the database:")
    for r in rows:
        print(f"  {r['name']:12} {r['n']:>6} rows  {r['lo']} .. {r['hi']}  "
              f"net {r['net'] / 100:>12,.2f}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
