"""Tests for the CIBC sign-on flow helpers. No browser, no network."""

from __future__ import annotations

import asyncio
from datetime import UTC, date, datetime, timedelta
from itertools import pairwise

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
            "Enter code: 999888 for CAD 734.49 at Amazon on card ending 1234",
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
        "Enter code: 123456 to authorize sign on to online banking. oj8q54qM2Vm"
    )
    fake = FakeBeeper([msg(text, t=T0 + timedelta(seconds=3))])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    assert asyncio.run(wait_for_otp(T0, timeout_s=5)) == "123456"


def test_polls_with_the_requested_timestamp(monkeypatch):
    fake = FakeBeeper([msg("Enter code: 121212 to authorize sign on", t=T0 + timedelta(seconds=1))])
    monkeypatch.setattr(cibc_web, "BeeperClient", lambda: fake)
    asyncio.run(wait_for_otp(T0, timeout_s=5))
    assert fake.queries[0] == T0.isoformat()


# --- misc ----------------------------------------------------------------


# --- type_into ------------------------------------------------------------


class FakeField:
    """A field whose bounding box settles after `moves` polls."""

    def __init__(self, moves: int = 0):
        self.moves = moves
        self.polls = 0
        self.clicked = False
        self.waited = False

    async def wait_for(self, state="visible", timeout=30_000):
        self.waited = True

    async def scroll_into_view_if_needed(self):
        pass

    async def bounding_box(self):
        self.polls += 1
        # Simulate an animation: the box shifts until `moves` polls have passed.
        y = max(0, self.moves - self.polls)
        return {"x": 0, "y": y, "width": 100, "height": 20}

    async def click(self, timeout=None):
        self.clicked = True

    async def dispatch_event(self, name):
        self.dispatched = name


class TypingPage:
    """Page double for type_into: records what got typed."""

    def __init__(self):
        self.typed = []
        self.keyboard = self

    async def wait_for_timeout(self, ms):
        pass

    async def type(self, text, delay=None):
        self.typed.append(text)


def test_type_into_waits_for_the_element_to_settle():
    """Regression: clicking mid-animation fails with 'element is not stable'."""
    page, field = TypingPage(), FakeField(moves=4)
    asyncio.run(cibc_web.type_into(page, field, "1234"))
    assert field.waited
    assert field.clicked
    assert page.typed == ["1234"]
    # It polled until the box stopped moving rather than clicking immediately.
    assert field.polls > 4


def test_type_into_is_fast_when_already_stable():
    page, field = TypingPage(), FakeField(moves=0)
    asyncio.run(cibc_web.type_into(page, field, "abc"))
    assert field.polls <= 3
    assert page.typed == ["abc"]


def test_type_into_gives_up_rather_than_hanging():
    """A perpetually animating element must not block forever."""
    class NeverSettles(FakeField):
        async def bounding_box(self):
            self.polls += 1
            return {"x": 0, "y": self.polls, "width": 10, "height": 10}

    page, field = TypingPage(), NeverSettles()
    asyncio.run(cibc_web.type_into(page, field, "x"))
    assert field.clicked
    # Bounded: 25 polls per attempt, and the click succeeds on the first try.
    assert field.polls <= 26


def test_click_settled_retries_once_then_succeeds():
    """A click that hangs on a moving control is retried from a settled position."""
    from playwright.async_api import Error as PlaywrightError

    class FailsOnce(FakeField):
        def __init__(self):
            super().__init__()
            self.attempts = 0

        async def click(self, timeout=None):
            self.attempts += 1
            if self.attempts == 1:
                raise PlaywrightError("Timeout: performing click action")
            self.clicked = True

    page, field = TypingPage(), FailsOnce()
    asyncio.run(cibc_web.click_settled(page, field))
    assert field.attempts == 2
    assert field.clicked


def test_click_settled_raises_rather_than_faking_a_click():
    """A synthetic DOM event would bypass the framework handler and stall later."""
    from playwright.async_api import Error as PlaywrightError

    class AlwaysFails(FakeField):
        async def click(self, timeout=None):
            raise PlaywrightError("Timeout: performing click action")

    page, field = TypingPage(), AlwaysFails()
    with pytest.raises(PlaywrightError):
        asyncio.run(cibc_web.click_settled(page, field))
    assert getattr(field, "dispatched", None) is None


# --- month_chunks ---------------------------------------------------------


def test_chunks_cover_the_whole_span_with_no_gaps_or_overlaps():
    """A gap loses transactions silently -- the worst possible failure here."""
    start, end = date(2024, 1, 1), date(2024, 12, 31)
    chunks = cibc_web.month_chunks(start, end)

    assert chunks[0][0] == start
    assert chunks[-1][1] == end
    for (_, prev_end), (next_start, _) in pairwise(chunks):
        assert next_start == prev_end + timedelta(days=1)


def test_chunks_are_inclusive_and_do_not_exceed_the_size():
    chunks = cibc_web.month_chunks(date(2024, 1, 1), date(2024, 6, 30), size=31)
    for chunk_start, chunk_end in chunks:
        assert chunk_start <= chunk_end
        assert (chunk_end - chunk_start).days < 31


def test_a_single_day_is_one_chunk():
    day = date(2026, 7, 31)
    assert cibc_web.month_chunks(day, day) == [(day, day)]


def test_span_shorter_than_a_chunk_is_not_padded():
    """Requesting beyond `until` could pull rows the caller did not ask for."""
    start, end = date(2026, 7, 1), date(2026, 7, 10)
    assert cibc_web.month_chunks(start, end) == [(start, end)]


def test_reversed_range_is_rejected():
    with pytest.raises(ValueError, match="after"):
        cibc_web.month_chunks(date(2026, 7, 31), date(2026, 7, 1))


def test_two_years_splits_into_manageable_chunks():
    """A single 730-day request works but 1100 does not; chunks dodge the limit."""
    chunks = cibc_web.month_chunks(date(2024, 8, 1), date(2026, 7, 31))
    assert len(chunks) > 20
    assert all((e - s).days < 31 for s, e in chunks)


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
