"""Download CIBC transaction history as CSV.

By default pulls the full available history for every account (the one-time
backfill). Pass --since to request a date range instead.

    nix develop -c python3 scripts/download_csv.py
    nix develop -c python3 scripts/download_csv.py --since 2026-07-01
    nix develop -c python3 scripts/download_csv.py --account VISA

Files land in downloads/ (gitignored -- they hold real transactions).
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import date
from pathlib import Path

from cctrack.ingest.cibc_web import (
    DownloadError,
    LoginError,
    download_transactions,
    list_accounts,
    mask,
    session,
)

DEST = Path(__file__).resolve().parent.parent / "downloads"


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--since", type=date.fromisoformat, metavar="YYYY-MM-DD",
                    help="start of a date range; omit for the full history")
    ap.add_argument("--until", type=date.fromisoformat, metavar="YYYY-MM-DD",
                    help="end of a date range (default: today)")
    ap.add_argument("--account", action="append", metavar="NAME",
                    help="substring of an account name; repeatable "
                         "(default: every account)")
    return ap.parse_args()


async def main() -> int:
    args = parse_args()

    def say(message: str) -> None:
        print(f"  {message}", flush=True)

    try:
        async with session(on_step=say) as page:
            available = await list_accounts(page)
            print(f"\naccounts: {[mask(a) for a in available]}\n", flush=True)

            wanted = args.account or ["Chequing", "Savings", "VISA"]
            saved = []
            for name in wanted:
                if not any(name.lower() in a.lower() for a in available):
                    print(f"!! no account matching {name!r}, skipping", flush=True)
                    continue
                print(f"downloading {name}...", flush=True)
                try:
                    saved.append(await download_transactions(
                        page, name, DEST,
                        since=args.since, until=args.until, on_step=say,
                    ))
                except DownloadError as exc:
                    print(f"!! {name}: {exc}", flush=True)

            print(f"\n{len(saved)} file(s) saved to {DEST}", flush=True)
            for path in saved:
                print(f"  {path.name}  {path.stat().st_size} bytes", flush=True)
            return 0 if saved else 1
    except LoginError as exc:
        print(f"!! {exc}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
