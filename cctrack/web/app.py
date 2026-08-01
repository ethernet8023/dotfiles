"""cctrack web UI.

The primary interface: review and reporting live here, and cron drives sync
through POST /api/sync rather than through the CLI.

Bound to loopback only. See auth.py for why the API needs a token even so.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime

from fasthtml.common import (
    H2,
    A,
    Div,
    Form,
    Input,
    Option,
    P,
    Script,
    Select,
    Span,
    Style,
    Table,
    Tbody,
    Td,
    Th,
    Thead,
    Titled,
    Tr,
    fast_app,
    serve,
)
from starlette.responses import JSONResponse, PlainTextResponse

from cctrack.config import db_path, downloads_dir
from cctrack.db import connect
from cctrack.sync import import_files, sync_window
from cctrack.web.auth import load_or_create_token, token_matches
from cctrack.web.jobs import Job, runner
from cctrack.web.queries import (
    account_names,
    account_summaries,
    count_transactions,
    current_month,
    month_spend,
    recent_transactions,
    uncategorized_count,
)

ALLOWED_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}

CSS = """
:root { color-scheme: dark; --bg:#14161a; --fg:#e7e9ee; --dim:#8b93a7;
        --line:#272b33; --accent:#7aa2f7; --out:#f7768e; --in:#9ece6a; }
* { box-sizing: border-box; }
body { background:var(--bg); color:var(--fg); font:15px/1.5 ui-sans-serif,system-ui,sans-serif;
       margin:0; padding:2rem; max-width:1100px; margin-inline:auto; }
h1 { font-size:1.4rem; margin:0 0 .25rem; }
h2 { font-size:1rem; color:var(--dim); font-weight:600; margin:2rem 0 .75rem;
     text-transform:uppercase; letter-spacing:.06em; }
nav { display:flex; gap:1.25rem; margin:0 0 1.5rem; padding-bottom:1rem;
      border-bottom:1px solid var(--line); }
nav a { color:var(--dim); text-decoration:none; }
nav a:hover, nav a.on { color:var(--accent); }
table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
th { text-align:left; color:var(--dim); font-weight:600; font-size:.8rem;
     text-transform:uppercase; letter-spacing:.05em; padding:.4rem .6rem;
     border-bottom:1px solid var(--line); }
td { padding:.45rem .6rem; border-bottom:1px solid var(--line); }
tr:hover td { background:#191c22; }
.num { text-align:right; font-variant-numeric:tabular-nums; }
.out { color:var(--out); } .in { color:var(--in); }
.dim { color:var(--dim); }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:1rem; }
.card { border:1px solid var(--line); border-radius:8px; padding:1rem; }
.card .big { font-size:1.5rem; font-variant-numeric:tabular-nums; }
button, .btn { background:var(--accent); color:#0b0d12; border:0; border-radius:6px;
    padding:.5rem .9rem; font:inherit; font-weight:600; cursor:pointer; }
button:disabled { background:var(--line); color:var(--dim); cursor:not-allowed; }
button.ghost { background:transparent; color:var(--fg); border:1px solid var(--line); }
input, select { background:#0f1116; color:var(--fg); border:1px solid var(--line);
    border-radius:6px; padding:.45rem .6rem; font:inherit; }
pre { background:#0f1116; border:1px solid var(--line); border-radius:6px;
      padding:.75rem; overflow:auto; max-height:18rem; font-size:.85rem; margin:0; }
.bar { height:8px; background:var(--line); border-radius:4px; overflow:hidden; }
.bar > i { display:block; height:100%; background:var(--accent); }
.row { display:flex; gap:.6rem; align-items:center; flex-wrap:wrap; }
.spacer { flex:1; }
"""


def money(cents: int) -> str:
    return f"{cents / 100:,.2f}"


def money_cell(cents: int):
    return Td(money(cents), cls=f"num {'out' if cents < 0 else 'in'}")


def nav(active: str):
    items = [("/", "dashboard"), ("/transactions", "transactions"), ("/review", "review")]
    return Div(*[
        A(label, href=href, cls="on" if label == active else "")
        for href, label in items
    ], cls="", style="display:flex;gap:1.25rem;margin:0 0 1.5rem;"
       "padding-bottom:1rem;border-bottom:1px solid var(--line);")


def page(title: str, active: str, *content):
    return Titled(title, Style(CSS), nav(active), *content)


def build_app(db=None):
    app, rt = fast_app(pico=False, hdrs=(Script(src="https://unpkg.com/htmx.org@2.0.4"),))
    token = load_or_create_token()
    database = db or db_path()

    def con():
        return connect(database)

    def require_local(request) -> None:
        """Refuse requests whose Host is not loopback.

        Guards against DNS rebinding: a remote page can resolve its own name to
        127.0.0.1 and reach this server, but its requests carry that hostname.
        """
        host = (request.headers.get("host") or "").rsplit(":", 1)[0]
        if host not in ALLOWED_HOSTS:
            raise PermissionError(f"non-local Host header {host!r}")

    def require_token(request) -> None:
        require_local(request)
        supplied = request.headers.get("authorization") or request.query_params.get("token")
        if not token_matches(supplied, token):
            raise PermissionError("bad or missing API token")

    # ---------------------------------------------------------------- views

    @rt("/")
    def dashboard():
        c = con()
        summaries = account_summaries(c)
        pending = uncategorized_count(c)
        month = current_month()
        by_month = dict(month_spend(c, months=24))

        # A month with no rows yet is "no data", not "$0.00 spent". Early in a
        # month -- or before a sync -- a zero here reads as a claim about
        # spending rather than an absence of it.
        if month in by_month:
            headline = Div(f"${money(by_month[month])}", cls="big")
            caption = month
        else:
            latest = max(by_month) if by_month else None
            headline = Div("—", cls="big dim")
            caption = f"{month}: nothing imported yet"
            if latest:
                caption += f" (latest: {latest}, ${money(by_month[latest])})"

        cards = Div(
            Div(H2("this month"), headline, P(caption, cls="dim"), cls="card"),
            Div(H2("uncategorized"), Div(f"{pending:,}", cls="big"),
                P(A("review them", href="/review") if pending else "all tagged",
                  cls="dim"), cls="card"),
            Div(H2("transactions"), Div(f"{sum(s.rows for s in summaries):,}", cls="big"),
                P("across all accounts", cls="dim"), cls="card"),
            cls="cards",
        )

        rows = [
            Tr(Td(s.name), Td(f"{s.rows:,}", cls="num"),
               Td(f"{s.first} .. {s.last}", cls="dim"), money_cell(s.net_cents))
            for s in summaries
        ]
        table = Table(
            Thead(Tr(Th("account"), Th("rows", cls="num"), Th("range"), Th("net", cls="num"))),
            Tbody(*rows),
        )

        return page("cctrack", "dashboard",
                    cards,
                    H2("spend by month"), spend_chart(c),
                    H2("accounts"), table,
                    H2("actions"), actions_panel())

    def spend_chart(c):
        """Inline SVG-free bars. No image files, no matplotlib in the request path."""
        data = month_spend(c, months=12)
        if not data:
            return P("no data yet", cls="dim")

        peak = max(cents for _, cents in data) or 1
        return Div(*[
            Div(
                Span(month, style="width:5rem;display:inline-block", cls="dim"),
                Div(Div(style=f"height:100%;background:var(--accent);"
                              f"width:{cents / peak * 100:.1f}%"),
                    cls="bar", style="flex:1"),
                Span(f"${money(cents)}", style="width:7rem;text-align:right"),
                cls="row", style="margin:.3rem 0",
            )
            for month, cents in data
        ])

    def actions_panel():
        return Div(
            Div(
                _button("sync", "/api/sync", "download new transactions and import"),
                _button("import", "/api/import", "import CSVs already downloaded"),
                cls="row",
            ),
            Div(id="job", hx_get="/job", hx_trigger="load, every 2s",
                style="margin-top:1rem"),
        )

    def _button(label: str, endpoint: str, hint: str):
        return Div(
            Form(
                Input(type="hidden", name="token", value=token),
                Input(type="submit", value=label, cls=""),
                hx_post=endpoint, hx_target="#job", hx_swap="innerHTML",
            ),
            P(hint, cls="dim", style="margin:.25rem 0 0;font-size:.85rem"),
        )

    @rt("/job")
    def job_panel():
        job = runner.last
        if job is None:
            return P("no jobs run yet", cls="dim")

        colour = {"running": "var(--accent)", "done": "var(--in)", "failed": "var(--out)"}
        head = Div(
            Span(job.name, style="font-weight:600"),
            Span(job.status, style=f"color:{colour[job.status]}"),
            Span(job.result or job.error or "", cls="dim"),
            cls="row",
        )
        body = Div(*[P(line, style="margin:0;font-family:ui-monospace,monospace;"
                                   "font-size:.8rem") for line in job.lines[-14:]],
                   cls="") if job.lines else None
        return Div(head, Div(body, cls="") if body else "",
                   style="border:1px solid var(--line);border-radius:8px;padding:.75rem")

    @rt("/transactions")
    def transactions(account: str = "", q: str = "", page_no: int = 1):
        c = con()
        per = 100
        offset = max(0, (page_no - 1) * per)
        total = count_transactions(c, account=account or None, search=q or None)
        rows = recent_transactions(
            c, limit=per, offset=offset, account=account or None, search=q or None
        )

        controls = Form(
            Select(Option("all accounts", value=""),
                   *[Option(n, value=n, selected=(n == account))
                     for n in account_names(c)],
                   name="account"),
            Input(name="q", value=q, placeholder="search description"),
            Input(type="submit", value="filter"),
            method="get", action="/transactions", cls="row",
        )

        body = Tbody(*[
            Tr(Td(r["posted_on"], cls="dim"),
               Td(r["description"]),
               Td(r["account"], cls="dim"),
               Td(r["category"] or "—", cls="dim"),
               money_cell(r["amount_cents"]))
            for r in rows
        ])
        table = Table(
            Thead(Tr(Th("date"), Th("description"), Th("account"),
                     Th("category"), Th("amount", cls="num"))),
            body,
        )

        pages = Div(
            A("← newer", href=f"/transactions?account={account}&q={q}&page_no={page_no - 1}")
            if page_no > 1 else Span("", cls="dim"),
            Span(f"{offset + 1}–{min(offset + per, total)} of {total:,}", cls="dim"),
            A("older →", href=f"/transactions?account={account}&q={q}&page_no={page_no + 1}")
            if offset + per < total else Span("", cls="dim"),
            cls="row", style="margin-top:1rem",
        )

        return page("transactions", "transactions", controls, table, pages)

    @rt("/review")
    def review():
        c = con()
        pending = uncategorized_count(c)
        if not pending:
            return page("review", "review",
                        P("nothing to review — every transaction is categorized.",
                          cls="dim"))

        rows = recent_transactions(c, limit=50, uncategorized_only=True)
        table = Table(
            Thead(Tr(Th("date"), Th("description"), Th("account"), Th("amount", cls="num"))),
            Tbody(*[
                Tr(Td(r["posted_on"], cls="dim"), Td(r["description"]),
                   Td(r["account"], cls="dim"), money_cell(r["amount_cents"]))
                for r in rows
            ]),
        )
        return page("review", "review",
                    P(f"{pending:,} uncategorized. Categories and one-tap tagging "
                      f"arrive with the rules engine; this is the queue they will "
                      f"work through.", cls="dim"),
                    table)

    # ----------------------------------------------------------------- api

    @rt("/api/sync", methods=["POST"])
    async def api_sync(request):
        try:
            require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)

        try:
            runner.start("sync", _sync_job(database))
        except RuntimeError as exc:
            return JSONResponse({"error": str(exc)}, status_code=409)
        return job_panel()

    @rt("/api/import", methods=["POST"])
    async def api_import(request):
        try:
            require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)

        try:
            runner.start("import", _import_job(database))
        except RuntimeError as exc:
            return JSONResponse({"error": str(exc)}, status_code=409)
        return job_panel()

    @rt("/api/status")
    def api_status(request):
        try:
            require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)

        c = con()
        job = runner.last
        return JSONResponse({
            "accounts": [
                {"name": s.name, "rows": s.rows, "first": s.first,
                 "last": s.last, "net_cents": s.net_cents}
                for s in account_summaries(c)
            ],
            "uncategorized": uncategorized_count(c),
            "job": job.as_dict() if job else None,
        })

    @rt("/api/token")
    def api_token(request):
        """The token itself, readable only from loopback. For cron setup."""
        try:
            require_local(request)
        except PermissionError as exc:
            return PlainTextResponse(str(exc), status_code=403)
        return PlainTextResponse(token)

    return app


def _sync_job(database):
    def work(job: Job) -> str:
        from cctrack.ingest.cibc_web import download_range, list_accounts, mask, session

        async def run() -> str:
            c = connect(database)
            downloaded = []
            problems = []
            today = datetime.now(UTC).date()

            async with session(on_step=job.log) as page:
                available = await list_accounts(page)
                job.log(f"accounts: {[mask(a) for a in available]}")

                for target in ("Chequing", "Savings", "VISA"):
                    if not any(target.lower() in a.lower() for a in available):
                        problems.append(f"no account matching {target!r}")
                        continue
                    start, end = sync_window(c, target, today=today)
                    job.log(f"{target}: {start} to {end}")
                    saved, failed = await download_range(
                        page, target, downloads_dir(),
                        since=start, until=end, on_step=job.log,
                    )
                    downloaded.extend(saved)
                    problems.extend(f"{target} {s}..{e}: {w}" for s, e, w in failed)

            added, errors = import_files(c, downloaded)
            problems.extend(errors)
            total = sum(added.values())
            job.log(f"imported {total} new transaction(s)")
            if problems:
                raise RuntimeError("; ".join(problems[:3]))
            return f"{total} new"

        return asyncio.run(run())

    return work


def _import_job(database):
    def work(job: Job) -> str:
        c = connect(database)
        files = sorted(downloads_dir().glob("*.csv"))
        job.log(f"importing {len(files)} file(s)")
        added, errors = import_files(c, files)
        total = sum(added.values())
        for name in sorted(added):
            job.log(f"{name}: {added[name]} new")
        if errors:
            raise RuntimeError("; ".join(errors[:3]))
        return f"{total} new"

    return work


app = build_app()


def main(host: str = "127.0.0.1", port: int = 5001) -> None:
    if host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit(
            f"refusing to bind {host}: this serves real bank transactions "
            f"with no login. Use 127.0.0.1."
        )
    print(f"cctrack -> http://{host}:{port}")
    print(f"api token: {load_or_create_token()}")
    serve(appname="cctrack.web.app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()
