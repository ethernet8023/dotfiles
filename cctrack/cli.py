"""cctrack command line.

    cctrack sync                 download what is new and import it
    cctrack import <csv>...      import CSVs already on disk
    cctrack status               what is in the database
"""

from __future__ import annotations

import asyncio
import sys
from datetime import UTC, date, datetime
from pathlib import Path

import typer

from cctrack.config import ACCOUNTS, db_path, downloads_dir
from cctrack.db import connect
from cctrack.sync import SyncResult, import_files, sync_window

app = typer.Typer(
    add_completion=False,
    help="Track CIBC card spending.",
    no_args_is_help=True,
)


def _echo(message: str) -> None:
    typer.echo(f"  {message}")


@app.command("import")
def import_cmd(
    paths: list[Path] = typer.Argument(None, help="CSV files (default: all downloads)"),
    db: Path = typer.Option(None, "--db", help="database path"),
) -> None:
    """Import CIBC CSVs that are already downloaded."""
    files = list(paths) if paths else sorted(downloads_dir().glob("*.csv"))
    if not files:
        typer.echo("no CSVs to import")
        raise typer.Exit(1)

    con = connect(db or db_path())
    added, errors = import_files(con, files)

    for name in sorted(added):
        typer.echo(f"  {name:12} {added[name]:>6} new")
    typer.echo(f"\n{sum(added.values())} transaction(s) added from {len(files)} file(s)")

    if errors:
        typer.echo(f"\n{len(errors)} file(s) failed:")
        for error in errors:
            typer.echo(f"  {error}")
        raise typer.Exit(1)


@app.command()
def sync(
    since: datetime = typer.Option(
        None, "--since", formats=["%Y-%m-%d"],
        help="start date (default: a few days before the newest stored transaction)",
    ),
    until: datetime = typer.Option(None, "--until", formats=["%Y-%m-%d"]),
    account: list[str] = typer.Option(
        None, "--account", help="account name substring; repeatable"
    ),
    db: Path = typer.Option(None, "--db", help="database path"),
    keep_csv: bool = typer.Option(
        True, "--keep-csv/--no-keep-csv", help="leave downloaded CSVs on disk"
    ),
) -> None:
    """Download new transactions from CIBC and import them."""
    con = connect(db or db_path())
    result = asyncio.run(_run_sync(
        con,
        since=since.date() if since else None,
        until=until.date() if until else None,
        wanted=account or None,
        keep_csv=keep_csv,
    ))

    typer.echo("")
    for name in sorted(result.imported):
        typer.echo(f"  {name:12} {result.imported[name]:>6} new")
    typer.echo(f"\nimported {result.total_imported} new transaction(s)")
    if result.empty:
        typer.echo(f"({result.empty} window(s) had no transactions)")
    if result.failed:
        typer.echo(f"\n{len(result.failed)} problem(s):")
        for problem in result.failed:
            typer.echo(f"  {problem}")
        raise typer.Exit(1)


async def _run_sync(
    con,
    *,
    since: date | None,
    until: date | None,
    wanted: list[str] | None,
    keep_csv: bool,
) -> SyncResult:
    # Imported here so `cctrack import` and `status` do not pay for playwright.
    from cctrack.ingest.cibc_web import (
        LoginError,
        download_range,
        list_accounts,
        mask,
        session,
    )

    result = SyncResult()
    dest = downloads_dir()
    today = until or datetime.now(UTC).date()

    try:
        async with session(on_step=_echo) as page:
            available = await list_accounts(page)
            typer.echo(f"\naccounts: {[mask(a) for a in available]}")

            targets = wanted or [name for name, _ in ACCOUNTS.values()]
            for target in targets:
                if not any(target.lower() in a.lower() for a in available):
                    result.failed.append(f"no account matching {target!r}")
                    continue

                start = since or sync_window(con, target, today=today)[0]
                typer.echo(f"\n=== {target}: {start} to {today} ===")
                saved, failed = await download_range(
                    page, target, dest, since=start, until=today, on_step=_echo,
                )
                result.downloaded.extend(saved)
                result.failed.extend(
                    f"{target} {s}..{e}: {why}" for s, e, why in failed
                )
    except LoginError as exc:
        result.failed.append(str(exc))
        return result

    added, errors = import_files(con, result.downloaded)
    result.imported = added
    result.failed.extend(errors)

    if not keep_csv:
        for path in result.downloaded:
            path.unlink(missing_ok=True)

    return result


@app.command()
def serve(
    port: int = typer.Option(5001, "--port"),
    host: str = typer.Option("127.0.0.1", "--host"),
) -> None:
    """Start the web UI -- the primary interface for review and reporting."""
    from cctrack.web.app import main

    main(host=host, port=port)


@app.command()
def status(db: Path = typer.Option(None, "--db", help="database path")) -> None:
    """Show what is in the database."""
    con = connect(db or db_path())
    rows = con.execute(
        "SELECT a.name, count(*) n, min(t.posted_on) lo, max(t.posted_on) hi, "
        "       sum(t.amount_cents) net "
        "FROM transactions t JOIN accounts a ON a.id = t.account_id "
        "GROUP BY a.name ORDER BY a.name"
    ).fetchall()

    if not rows:
        typer.echo("no transactions yet -- run `cctrack sync`")
        return

    typer.echo(f"{'account':12} {'rows':>6}  {'range':<26} {'net':>12}")
    for r in rows:
        typer.echo(
            f"{r['name']:12} {r['n']:>6}  {r['lo']} .. {r['hi']}  "
            f"{r['net'] / 100:>12,.2f}"
        )

    uncategorized = con.execute(
        "SELECT count(*) n FROM transactions WHERE category_id IS NULL"
    ).fetchone()["n"]
    if uncategorized:
        typer.echo(f"\n{uncategorized} uncategorized")


if __name__ == "__main__":
    sys.exit(app())
