"""cctrack web UI.

The primary interface: review and reporting live here, and cron drives sync
through POST /api/sync rather than through the CLI.

Bound to loopback only. See auth.py for why the API needs a token even so.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta

from fasthtml.common import (
    H2,
    A,
    Div,
    Form,
    Input,
    Nav,
    Option,
    P,
    Pre,
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

from cctrack.categories import all_categories, seed
from cctrack.categorize import tag_and_learn
from cctrack.config import db_path, downloads_dir
from cctrack.db import connect
from cctrack.sync import import_files, sync_window
from cctrack.web.auth import load_or_create_token, token_matches
from cctrack.web.jobs import Job, runner
from cctrack.web.queries import (
    account_names,
    account_summaries,
    channel_counts,
    channel_label,
    count_transactions,
    current_month,
    month_spend,
    recent_transactions,
    uncategorized_count,
)
from cctrack.web.scheduler import Scheduler

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


NAV = (("/", "dashboard"), ("/transactions", "transactions"), ("/review", "review"))


def nav(active: str):
    return Nav(*[
        A(label, href=href, cls="on" if label == active else None)
        for href, label in NAV
    ])


def page(title: str, active: str, *content):
    return Titled(title, Style(CSS), nav(active), *content)


def build_app(db=None, *, auto_sync: bool = False, interval_minutes: int = 60):
    app, rt = fast_app(pico=False, hdrs=(Script(src="https://unpkg.com/htmx.org@2.0.4"),))
    token = load_or_create_token()
    database = db or db_path()

    def con():
        return connect(database)

    def run_sync_now() -> str:
        """Body of a scheduled sync: same work the button does, run inline."""
        job = runner.start("sync (scheduled)", _sync_job(database))
        runner.join(timeout=60 * 30)
        if job.status == "failed":
            raise RuntimeError(job.error or "sync failed")
        return job.result or "done"

    scheduler = Scheduler(
        run_sync_now,
        interval=timedelta(minutes=interval_minutes),
        is_busy=runner.is_running,
    )
    if auto_sync:
        scheduler.start()

    def require_local(request) -> None:
        """Refuse requests whose Host is not loopback.

        Guards against DNS rebinding: a remote page can resolve its own name to
        127.0.0.1 and reach this server, but its requests carry that hostname.
        """
        host = (request.headers.get("host") or "").rsplit(":", 1)[0]
        if host not in ALLOWED_HOSTS:
            raise PermissionError(f"non-local Host header {host!r}")

    async def require_token(request) -> None:
        """Authorize an API call.

        The token may arrive three ways, because three kinds of caller use
        this: an Authorization header (curl, cron), a query parameter (easy
        to paste), or a form field (the UI's htmx posts, which cannot set
        headers without extra wiring).
        """
        require_local(request)
        supplied = (
            request.headers.get("authorization")
            or request.query_params.get("token")
        )
        if not supplied and request.method == "POST":
            try:
                form = await request.form()
                supplied = form.get("token")
            except Exception:  # noqa: BLE001 - a bodyless post is just unauthorized
                supplied = None
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
                action("sync", "/api/sync", "download new transactions and import"),
                action("import", "/api/import", "import CSVs already downloaded"),
                cls="row",
            ),
            Div(id="job", hx_get="/job", hx_trigger="load, every 2s",
                style="margin-top:1rem"),
            Div(id="schedule", hx_get="/schedule", hx_trigger="load, every 10s",
                style="margin-top:1rem"),
        )

    @rt("/schedule")
    def schedule_panel():
        s = scheduler.state
        mins = int(s.interval.total_seconds() // 60)

        if s.paused_reason:
            status = Span(s.paused_reason, style="color:var(--out)")
        elif s.enabled and s.next_run:
            status = Span(f"on — next run {s.next_run:%H:%M}", style="color:var(--in)")
        elif s.enabled:
            status = Span("on", style="color:var(--in)")
        else:
            status = Span("off", cls="dim")

        toggle = Form(
            Input(type="hidden", name="token", value=token),
            Input(type="hidden", name="minutes", value=str(mins)),
            Input(type="submit", value="turn off" if s.enabled else "turn on"),
            hx_post="/api/schedule/" + ("stop" if s.enabled else "start"),
            hx_target="#schedule", hx_swap="outerHTML",
        )

        return Div(
            Div(Span("auto-sync", style="font-weight:600"), status,
                Span(f"every {mins} min", cls="dim"), Span(cls="spacer"), toggle,
                cls="row"),
            Pre("\n".join(s.history[-6:])) if s.history else "",
            id="schedule", cls="card",
        )

    @rt("/api/schedule/start", methods=["POST"])
    async def api_schedule_start(request):
        try:
            await require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)

        form = await request.form()
        try:
            minutes = max(5, int(form.get("minutes", 60)))
        except ValueError:
            minutes = 60
        scheduler.state.interval = timedelta(minutes=minutes)
        scheduler.start()
        return schedule_panel()

    @rt("/api/schedule/stop", methods=["POST"])
    async def api_schedule_stop(request):
        try:
            await require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)
        scheduler.stop()
        return schedule_panel()

    def action(label: str, endpoint: str, hint: str):
        """A button that starts a background job and swaps in its live log."""
        return Div(
            Form(
                Input(type="hidden", name="token", value=token),
                Input(type="submit", value=label),
                hx_post=endpoint, hx_target="#job", hx_swap="innerHTML",
            ),
            P(hint, cls="dim", style="margin:.25rem 0 0;font-size:.85rem"),
        )

    STATUS_COLOUR = {"running": "var(--accent)", "done": "var(--in)", "failed": "var(--out)"}

    @rt("/job")
    def job_panel():
        job = runner.last
        if job is None:
            return P("no jobs run yet", cls="dim")

        return Div(
            Div(
                Span(job.name, style="font-weight:600"),
                Span(job.status, style=f"color:{STATUS_COLOUR[job.status]}"),
                Span(job.result or job.error or "", cls="dim"),
                cls="row",
            ),
            Pre("\n".join(job.lines[-14:])) if job.lines else "",
            cls="card",
        )

    @rt("/transactions")
    def transactions(account: str = "", q: str = "", channel: str = "",
                     page_no: int = 1):
        c = con()
        per = 100
        offset = max(0, (page_no - 1) * per)
        total = count_transactions(
            c, account=account or None, search=q or None, channel=channel or None
        )
        rows = recent_transactions(
            c, limit=per, offset=offset, account=account or None,
            search=q or None, channel=channel or None,
        )

        # Offered channels come from the data, not the label map, so a channel
        # CIBC starts emitting is filterable before anyone names it.
        present = [ch for ch, _ in channel_counts(c) if ch is not None]

        controls = Form(
            Select(Option("all accounts", value=""),
                   *[Option(n, value=n, selected=(n == account))
                     for n in account_names(c)],
                   name="account"),
            Select(Option("any channel", value=""),
                   *[Option(channel_label(ch), value=ch, selected=(ch == channel))
                     for ch in present],
                   name="channel"),
            Input(name="q", value=q, placeholder="search description"),
            Input(type="submit", value="filter"),
            method="get", action="/transactions", cls="row",
        )

        body = Tbody(*[
            Tr(Td(r["posted_on"], cls="dim"),
               Td(r["description"]),
               Td(r["account"], cls="dim"),
               Td(channel_label(r["channel"]), cls="dim"),
               Td(r["category"] or "—", cls="dim"),
               money_cell(r["amount_cents"]))
            for r in rows
        ])
        table = Table(
            Thead(Tr(Th("date"), Th("description"), Th("account"),
                     Th("channel"), Th("category"), Th("amount", cls="num"))),
            body,
        )

        query = f"account={account}&q={q}&channel={channel}"
        pages = Div(
            A("← newer", href=f"/transactions?{query}&page_no={page_no - 1}")
            if page_no > 1 else Span("", cls="dim"),
            Span(f"{offset + 1}–{min(offset + per, total)} of {total:,}", cls="dim"),
            A("older →", href=f"/transactions?{query}&page_no={page_no + 1}")
            if offset + per < total else Span("", cls="dim"),
            cls="row", style="margin-top:1rem",
        )

        return page("transactions", "transactions", controls, table, pages)

    @rt("/review")
    def review():
        c = con()
        cats = all_categories(c)
        if not cats:
            seed(c)
            cats = all_categories(c)
        return page("review", "review", review_queue(c, cats))

    def review_queue(c, cats=None, note: str | None = None):
        """The queue itself, swapped in place after each tag."""
        cats = cats or all_categories(c)
        pending = uncategorized_count(c)
        banner = P(note, cls="dim") if note else ""

        if not pending:
            return Div(banner,
                       P("nothing to review — every transaction is categorized.",
                         cls="dim"), id="queue")

        rows = recent_transactions(c, limit=25, uncategorized_only=True)
        return Div(
            banner,
            P(f"{pending:,} uncategorized. Tagging one also learns a rule, "
              f"so charges from the same merchant clear together.", cls="dim"),
            Table(
                Thead(Tr(Th("date"), Th("description"), Th("amount", cls="num"),
                         Th("category"))),
                Tbody(*[review_row(r, cats) for r in rows]),
            ),
            id="queue",
        )

    def review_row(r, cats):
        return Tr(
            Td(r["posted_on"], cls="dim"),
            Td(r["description"]),
            money_cell(r["amount_cents"]),
            Td(Form(
                Select(Option("pick…", value="", selected=True),
                       *[Option(cat.name, value=str(cat.id)) for cat in cats],
                       name="category_id"),
                Input(type="hidden", name="tx_id", value=str(r["id"])),
                Input(type="hidden", name="token", value=token),
                hx_post="/api/tag", hx_target="#queue", hx_swap="outerHTML",
                hx_trigger="change from:select",
            )),
        )

    @rt("/api/tag", methods=["POST"])
    async def api_tag(request):
        try:
            await require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)

        form = await request.form()
        try:
            tx_id = int(form["tx_id"])
            category_id = int(form["category_id"])
        except (KeyError, ValueError):
            return JSONResponse({"error": "tx_id and category_id required"},
                                status_code=400)

        c = con()
        cleared, proposal = tag_and_learn(c, tx_id, category_id)
        note = (f"tagged 1, and {cleared - 1} more cleared by the learned rule "
                f"{proposal.pattern}" if proposal and cleared > 1 else "tagged 1")
        # One #queue in the response: the note lives inside it, not wrapped
        # around it, or the swap leaves two elements with the same id.
        return review_queue(c, note=note)

    # ----------------------------------------------------------------- api

    async def start_job(request, name: str, work):
        """Shared body of the job endpoints: authorize, start, show the log."""
        try:
            await require_token(request)
        except PermissionError as exc:
            return JSONResponse({"error": str(exc)}, status_code=403)
        try:
            runner.start(name, work)
        except RuntimeError as exc:
            return JSONResponse({"error": str(exc)}, status_code=409)
        return job_panel()

    @rt("/api/sync", methods=["POST"])
    async def api_sync(request):
        return await start_job(request, "sync", _sync_job(database))

    @rt("/api/import", methods=["POST"])
    async def api_import(request):
        return await start_job(request, "import", _import_job(database))

    @rt("/api/status")
    async def api_status(request):
        try:
            await require_token(request)
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
            "schedule": scheduler.state.as_dict(),
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


def main(
    host: str = "127.0.0.1",
    port: int = 5001,
    *,
    auto_sync: bool = False,
    interval_minutes: int = 60,
) -> None:
    if host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit(
            f"refusing to bind {host}: this serves real bank transactions "
            f"with no login. Use 127.0.0.1."
        )

    global app
    app = build_app(auto_sync=auto_sync, interval_minutes=interval_minutes)

    print(f"cctrack -> http://{host}:{port}")
    print(f"api token: {load_or_create_token()}")
    if auto_sync:
        print(f"auto-sync every {interval_minutes} min")
        print("  a sync opens a browser window; run under `cage` to hide it "
              "(see scripts/serve.sh)")
    serve(appname="cctrack.web.app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()
