"""Web UI tests: auth guards, queries, and the job runner.

No browser and no network -- Starlette's TestClient drives the app directly.
"""

from __future__ import annotations

import time

import pytest
from starlette.testclient import TestClient

from cctrack.db import connect
from cctrack.ingest.importer import ensure_account, import_csv
from cctrack.web.auth import token_matches
from cctrack.web.jobs import JobRunner
from cctrack.web.queries import (
    account_summaries,
    daily_cumulative,
    month_spend,
    recent_transactions,
    uncategorized_count,
)

SAMPLE = (
    "2026-06-01,COFFEE SHOP,4.50,\n"
    "2026-06-02,GROCERY STORE,89.12,\n"
    "2026-06-15,PAYMENT THANK YOU,,200.00\n"
    "2026-07-03,BOOKSHOP,25.00,\n"
)


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "t.db"
    con = connect(path)
    import_csv(con, ensure_account(con, "CIBC VISA", "credit"), SAMPLE)
    con.commit()
    return path


@pytest.fixture
def client(db, monkeypatch):
    monkeypatch.setenv("CCTRACK_API_TOKEN", "test-token")
    from cctrack.web.app import build_app

    return TestClient(build_app(db=db), base_url="http://localhost")


# --- queries --------------------------------------------------------------


def test_month_spend_excludes_incoming_money(db):
    """A card payment is not negative spending; netting it hides a month."""
    con = connect(db)
    assert dict(month_spend(con)) == {"2026-06": 9362, "2026-07": 2500}


def test_daily_cumulative_runs_forward(db):
    """A payment day appears but adds nothing: it is income, not spend."""
    con = connect(db)
    assert daily_cumulative(con, "2026-06") == [
        ("2026-06-01", 450), ("2026-06-02", 9362), ("2026-06-15", 9362),
    ]


def test_daily_cumulative_stops_at_the_last_day_with_data(db):
    """Drawing a flat line to month end would read as 'spent nothing'."""
    con = connect(db)
    series = daily_cumulative(con, "2026-06")
    assert series[-1][0] == "2026-06-15"
    assert not any(day > "2026-06-15" for day, _ in series)


def test_account_summary_totals(db):
    con = connect(db)
    (summary,) = account_summaries(con)
    assert summary.name == "CIBC VISA"
    assert summary.rows == 4
    assert summary.net_cents == 20000 - 450 - 8912 - 2500


def test_everything_starts_uncategorized(db):
    assert uncategorized_count(connect(db)) == 4


def test_search_filters_descriptions(db):
    rows = recent_transactions(connect(db), search="COFFEE")
    assert len(rows) == 1
    assert "COFFEE" in rows[0]["description"]


# --- pages ----------------------------------------------------------------


def test_dashboard_renders(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "CIBC VISA" in r.text


def test_a_month_with_no_data_is_not_reported_as_zero_spent(client):
    """'$0.00' reads as a claim about spending; absence of data is not that.

    On the 1st of a month, or before the first sync, the current month has no
    rows -- the card must say so rather than implying nothing was spent.
    """
    r = client.get("/")
    assert "nothing imported yet" in r.text
    assert "$0.00" not in r.text


def test_transactions_page_lists_rows(client):
    r = client.get("/transactions")
    assert r.status_code == 200
    assert "GROCERY STORE" in r.text


def test_transactions_search(client):
    r = client.get("/transactions?q=BOOKSHOP")
    assert "BOOKSHOP" in r.text
    assert "GROCERY STORE" not in r.text


def test_review_page_shows_the_queue(client):
    r = client.get("/review")
    assert r.status_code == 200
    assert "uncategorized" in r.text.lower()


def test_review_page_offers_categories(client):
    """Categories are seeded on first visit so the queue is usable immediately."""
    r = client.get("/review")
    assert "restaurants" in r.text
    assert 'hx-post="/api/tag"' in r.text


def test_tagging_through_the_ui_clears_matching_charges(client, db):
    """The headline feature, exercised over HTTP rather than in the library."""
    from cctrack.db import connect
    from cctrack.ingest.importer import ensure_account, import_csv

    con = connect(db)
    acct = ensure_account(con, "CIBC VISA", "credit")
    import_csv(con, acct, "".join(
        f"2026-07-{d:02d},HAMER'S COFFEE TORONTO,4.50,\n" for d in range(1, 6)
    ))

    page = client.get("/review").text
    import re
    cats = {n: i for i, n in re.findall(r'<option value="(\d+)">([a-z]+)</option>', page)}
    row = next(r for r in page.split("<tr>") if "HAMER" in r)
    tx_id = re.search(r'name="tx_id" value="(\d+)"', row).group(1)

    before = client.get("/api/status?token=test-token").json()["uncategorized"]
    r = client.post("/api/tag", data={
        "tx_id": tx_id, "category_id": cats["restaurants"], "token": "test-token",
    })
    assert r.status_code == 200
    after = client.get("/api/status?token=test-token").json()["uncategorized"]

    assert before - after == 5, "one tag should clear all five coffee charges"
    assert r.text.count('id="queue"') == 1, "a duplicate id breaks the htmx swap"


def test_tagging_requires_a_token(client):
    r = client.post("/api/tag", data={"tx_id": "1", "category_id": "1"})
    assert r.status_code == 403


def test_tagging_rejects_a_malformed_request(client):
    r = client.post("/api/tag", data={"token": "test-token"})
    assert r.status_code == 400


# --- auth -----------------------------------------------------------------


def test_api_rejects_a_missing_token(client):
    assert client.post("/api/sync").status_code == 403


def test_api_rejects_a_wrong_token(client):
    r = client.post("/api/sync", headers={"Authorization": "Bearer nope"})
    assert r.status_code == 403


def test_api_accepts_the_token_as_a_header(client):
    r = client.get("/api/status", headers={"Authorization": "Bearer test-token"})
    assert r.status_code == 200
    assert r.json()["uncategorized"] == 4


def test_api_accepts_the_token_as_a_query_param(client):
    """Cron and curl are easier with a query param than a header."""
    assert client.get("/api/status?token=test-token").status_code == 200


def test_api_accepts_the_token_as_a_form_field(client):
    """The UI's htmx posts carry the token in the body, not a header.

    Regression: only header and query were checked, so every in-page button
    would have 403'd. A manual curl with -H hid this during live testing.
    """
    r = client.post("/api/import", data={"token": "test-token"})
    assert r.status_code in (200, 409), r.text


def test_api_rejects_a_non_local_host_header(client):
    """DNS rebinding: a remote page can reach 127.0.0.1 but carries its own Host."""
    r = client.get("/api/status?token=test-token",
                   headers={"Host": "evil.example.com"})
    assert r.status_code == 403


def test_token_comparison_handles_the_bearer_prefix():
    assert token_matches("Bearer abc", "abc")
    assert token_matches("abc", "abc")
    assert not token_matches("", "abc")
    assert not token_matches(None, "abc")


def test_refuses_to_bind_a_public_interface():
    """This serves real bank data with no login; 0.0.0.0 would publish it."""
    from cctrack.web.app import main

    with pytest.raises(SystemExit, match="refusing to bind"):
        main(host="0.0.0.0")


# --- job runner -----------------------------------------------------------


def test_job_runs_and_records_its_result():
    runner = JobRunner()
    runner.start("demo", lambda job: (job.log("working"), "done thing")[1])
    runner.join(timeout=5)
    job = runner.last
    assert job.status == "done"
    assert job.result == "done thing"
    assert any("working" in line for line in job.lines)


def test_job_failure_is_captured_not_raised():
    runner = JobRunner()

    def boom(job):
        raise ValueError("nope")

    runner.start("demo", boom)
    runner.join(timeout=5)
    assert runner.last.status == "failed"
    assert "nope" in runner.last.error


def test_only_one_job_runs_at_a_time():
    """Two syncs would fight over the browser profile and CIBC's session."""
    runner = JobRunner()
    runner.start("slow", lambda job: (time.sleep(0.3), "ok")[1])
    with pytest.raises(RuntimeError, match="already running"):
        runner.start("second", lambda job: "ok")
    runner.join(timeout=5)


def test_api_reports_a_conflict_when_a_job_is_running(client, monkeypatch):
    from cctrack.web import app as web_app

    monkeypatch.setattr(web_app.runner, "is_running", lambda: True)
    monkeypatch.setattr(
        web_app.runner, "start",
        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("sync is already running")),
    )
    r = client.post("/api/import", headers={"Authorization": "Bearer test-token"})
    assert r.status_code == 409
