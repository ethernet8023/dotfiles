"""Tests for the CIBC sign-on flow helpers. No browser, no network."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta

import pytest

from cctrack.ingest import cibc_web
from cctrack.ingest.cibc_web import FATAL_PATTERNS, first_of, mask, wait_for_otp

T0 = datetime(2026, 7, 31, 20, 0, 0, tzinfo=UTC)


class FakeLocator:
    """Becomes visible after `delay` seconds, or never if delay is None."""

    def __init__(self, delay: float | None):
        self.delay = delay

    async def wait_for(self, state="visible", timeout=30_000):
        if self.delay is None:
            await asyncio.sleep(timeout / 1000)
            raise TimeoutError("never appeared")
        await asyncio.sleep(self.delay)


def msg(text: str, *, t: datetime, sender: str = "242227"):
    return type(
        "M", (), {"text": text, "timestamp": t.isoformat(), "sender_name": sender}
    )()


class FakeBeeper:
    def __init__(self, messages):
        self.messages = messages
        self.queries: list[str] = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def search_messages(self, date_after=None, limit=20, **_):
        self.queries.append(date_after)
        cutoff = datetime.fromisoformat(date_after)
        return [m for m in self.messages if datetime.fromisoformat(m.timestamp) > cutoff]


# --- first_of ------------------------------------------------------------


def test_first_of_returns_the_winner():
    result = asyncio.run(
        first_of({"slow": FakeLocator(0.3), "fast": FakeLocator(0.01)}, timeout_s=2)
    )
    assert result == "fast"


def test_first_of_ignores_candidates_that_never_appear():
    """The whole point: a trusted device means the OTP prompt never shows."""
    result = asyncio.run(
        first_of({"otp": FakeLocator(None), "signed_in": FakeLocator(0.01)}, timeout_s=2)
    )
    assert result == "signed_in"


def test_first_of_returns_none_when_nothing_appears():
    result = asyncio.run(
        first_of({"a": FakeLocator(None), "b": FakeLocator(None)}, timeout_s=1)
    )
    assert result is None


def test_first_of_does_not_wait_for_the_slow_branch():
    """Regression: waiting on one fixed element burned the full timeout."""
    begin = datetime.now(UTC)
    asyncio.run(first_of({"never": FakeLocator(None), "quick": FakeLocator(0.01)}, timeout_s=5))
    assert (datetime.now(UTC) - begin).total_seconds() < 2


# --- OTP selection -------------------------------------------------------


def test_rejects_code_older_than_the_request(monkeypatch):
    fake = FakeBeeper([msg("Enter code: 111111 to authorize sign on", t=T0 - timedelta(minutes=1))])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    assert asyncio.run(wait_for_otp(T0, timeout_s=0)) is None


def test_accepts_a_fresh_signon_code(monkeypatch):
    fake = FakeBeeper([msg("Enter code: 654321 to authorize sign on", t=T0 + timedelta(seconds=5))])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    assert asyncio.run(wait_for_otp(T0, timeout_s=5)) == "654321"


def test_ignores_purchase_authorization_code(monkeypatch):
    """242226 sends 3-D Secure codes: fresh, six digits, still wrong."""
    fake = FakeBeeper([
        msg(
            "Enter code: 999888 for CAD 734.49 at Amazon on card ending 6602",
            t=T0 + timedelta(seconds=2),
            sender="242226",
        ),
    ])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    assert asyncio.run(wait_for_otp(T0, timeout_s=0)) is None


def test_ignores_right_shortcode_wrong_purpose(monkeypatch):
    """Shortcode alone is not enough -- CIBC US shares 242227."""
    fake = FakeBeeper([
        msg("Enter code: 555444 for your purchase", t=T0 + timedelta(seconds=2)),
    ])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    assert asyncio.run(wait_for_otp(T0, timeout_s=0)) is None


def test_autofill_hash_does_not_confuse_the_regex(monkeypatch):
    """Real messages end with an autofill hash that can contain digits."""
    text = (
        "Do not share this code with anyone. CIBC will never call you for this code. "
        "Enter code: 497492 to authorize sign on to online banking. oj8q54qM2Vm"
    )
    fake = FakeBeeper([msg(text, t=T0 + timedelta(seconds=3))])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    assert asyncio.run(wait_for_otp(T0, timeout_s=5)) == "497492"


def test_polls_with_the_requested_timestamp(monkeypatch):
    fake = FakeBeeper([msg("Enter code: 121212 to authorize sign on", t=T0 + timedelta(seconds=1))])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    asyncio.run(wait_for_otp(T0, timeout_s=5))
    assert fake.queries[0] == T0.isoformat()


# --- misc ----------------------------------------------------------------


def test_mask_hides_digits():
    assert mask("Text: 416-555-0199") == "Text: NNN-NNN-NNNN"


@pytest.mark.parametrize("phrase", FATAL_PATTERNS)
def test_fatal_patterns_are_lowercase(phrase):
    """They are matched against a lowercased message, so they must be lowercase."""
    assert phrase == phrase.lower()


# --- error page detection ------------------------------------------------


class FakePage:
    """Minimal page double for read_error: inline alerts, then body text."""

    def __init__(self, *, alert: str = "", body: str = ""):
        self.alert = alert
        self.body = body

    async def evaluate(self, script, *args):
        return self.alert if args else self.body


REAL_ERROR_PAGE = (
    "English | Français\n"
    "CIBC\n"
    "We're sorry, there's been an error\n"
    "{Result #0001}\n"
    "We've encountered an unexpected error. Please try again later.\n"
    "OK"
)


def test_detects_the_full_page_error_interstitial():
    """Regression: this page has no [role=alert], so the inline selector missed it."""
    found = asyncio.run(cibc_web.read_error(FakePage(body=REAL_ERROR_PAGE)))
    assert found is not None
    assert "there's been an error" in found.lower()


def test_error_page_keeps_the_result_code():
    """{Result #NNNN} is the only diagnostic CIBC offers -- do not discard it."""
    found = asyncio.run(cibc_web.read_error(FakePage(body=REAL_ERROR_PAGE)))
    assert "{Result #0001}" in found


def test_inline_alert_wins_over_body_text():
    page = FakePage(alert="Your password is incorrect.", body=REAL_ERROR_PAGE)
    assert asyncio.run(cibc_web.read_error(page)) == "Your password is incorrect."


def test_healthy_page_reports_no_error():
    page = FakePage(body="Sign on to CIBC Online Banking\nCard number\nContinue")
    assert asyncio.run(cibc_web.read_error(page)) is None


def test_error_markers_are_lowercase():
    for marker in cibc_web.ERROR_PAGE_MARKERS:
        assert marker == marker.lower()


def test_curly_and_straight_apostrophes_both_match():
    """CIBC renders a typographic apostrophe; a straight one must work too."""
    for text in ("There's been an error", "There\u2019s been an error"):
        assert asyncio.run(cibc_web.read_error(FakePage(body=text))) is not None
