"""Download CIBC transaction history as CSV, in month-sized chunks.

By default pulls the last 400 days for every account. Pass --since to go
further back -- retention is deeper than CIBC's "13 months" note suggests.

    nix develop -c python3 scripts/download_csv.py
    nix develop -c python3 scripts/download_csv.py --since 2024-01-01
    nix develop -c python3 scripts/download_csv.py --account VISA

Chunking is not optional: a single request wider than about two years never
returns, and wider still kills the browser. One file per account per month
lands in downloads/ (gitignored -- these hold real transactions).
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import date
from pathlib import Path

from cctrack.ingest.cibc_web import (
    LoginError,
    download_range,
    list_accounts,
    mask,
    session,
)

DEST = Path(__file__).resolve().parent.parent / "downloads"


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--since", type=date.fromisoformat, metavar="YYYY-MM-DD",
                    help="start date (default: 400 days ago)")
    ap.add_argument("--until", type=date.fromisoformat, metavar="YYYY-MM-DD",
                    help="end date (default: today)")
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
            all_saved, all_failed = [], []
            for name in wanted:
                if not any(name.lower() in a.lower() for a in available):
                    print(f"!! no account matching {name!r}, skipping", flush=True)
                    continue
                print(f"\n=== {name} ===", flush=True)
                saved, failed = await download_range(
                    page, name, DEST,
                    since=args.since, until=args.until, on_step=say,
                )
                all_saved.extend(saved)
                all_failed.extend((name, *f) for f in failed)

            total = sum(p.stat().st_size for p in all_saved)
            print(f"\n{len(all_saved)} file(s), {total:,} bytes total, in {DEST}",
                  flush=True)
            if all_failed:
                print(f"\n{len(all_failed)} chunk(s) failed:", flush=True)
                for account, start, end, reason in all_failed:
                    print(f"  {account} {start}..{end}: {reason}", flush=True)
                print("Rerun with --since/--until to retry just those.", flush=True)
                return 1
            # No files is fine when every window was genuinely empty; only an
            # actual failure is worth a non-zero exit.
            return 0
    except LoginError as exc:
        print(f"!! {exc}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
