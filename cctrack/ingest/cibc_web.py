"""Sign in to CIBC online banking, unattended.

Two things make this awkward, both established by measurement rather than
assumption (see STEALTH_NOTE below for the full matrix):

  1. CIBC's edge rejects automated browsers. Playwright's own Chromium and
     Firefox both get an error page on the card-number submit, while Firefox
     by hand on the same machine works. Camoufox -- a Firefox patched to spoof
     in C++ rather than via JS injection -- gets through.
  2. The flow is adaptive. A live session can skip the password screen and a
     trusted device can skip 2FA, so each stage races the possible next
     screens instead of assuming a fixed sequence.

Headless is not an option: the edge drops headless browsers during the h2
handshake, before any page code runs. Run under `cage` for no visible window.
"""

from __future__ import annotations

import asyncio
import re
from contextlib import asynccontextmanager
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import httpx
from camoufox.async_api import AsyncCamoufox
from playwright.async_api import Error as PlaywrightError

from cctrack.secrets.beeper import BeeperClient, BeeperError
from cctrack.secrets.bitwarden import Credential, get_login

SIGNON_URL = "https://www.cibconline.cibc.com/ebm-resources/public/client/web/index.html#/signon"

OTP_SENDER = "242227"
"""SMS shortcode for sign-on codes. 242226 is 3-D Secure purchase auth."""

OTP_MARKER = "to authorize sign on"
"""Distinguishes a sign-on code from a purchase-authorization code."""


class LoginError(RuntimeError):
    pass


ERROR_SELECTOR = (
    '[role="alert"], .error-message, .cibc-error, [class*="errorMessage"], '
    '[aria-live="assertive"]'
)
"""Where CIBC renders inline sign-on failures. Raced alongside the success paths
so a bad password reports itself instead of burning the whole timeout."""

ERROR_PAGE_MARKERS = (
    "there's been an error",
    "there\u2019s been an error",
    "unexpected error",
    "please try again later",
)
"""CIBC's full-page error interstitial ("We're sorry, there's been an error",
{Result #NNNN}). It carries no [role=alert], so the inline selector misses it
entirely -- match on the page text instead. Seen after several sign-ins in
quick succession without signing off, i.e. server-side session exhaustion."""

FATAL_PATTERNS = (
    "locked",
    "suspended",
    "temporarily unavailable",
    "too many",
    "contact us",
)
"""Errors where retrying makes things worse. Surfaced verbatim, never retried."""


def mask(text: str) -> str:
    """Replace digits, for printing page text that may hold account numbers."""
    return re.sub(r"\d", "N", text)


async def read_error(page) -> str | None:
    """Return visible error text: inline alert first, then the error page."""
    try:
        found = await page.evaluate(
            """(sel) => {
              const vis = el => { const r = el.getBoundingClientRect();
                                  return r.width > 0 && r.height > 0; };
              return [...document.querySelectorAll(sel)]
                .filter(vis)
                .map(el => (el.innerText || '').trim())
                .filter(Boolean)
                .join(' | ')
                .slice(0, 300);
            }""",
            ERROR_SELECTOR,
        )
        if found:
            return found

        # The full-page interstitial has no alert role; check the body text.
        body = await page.evaluate("() => (document.body.innerText || '').trim()")
    except PlaywrightError:
        # Mid-navigation the page can be gone; absence of an error is the answer.
        return None

    low = (body or "").lower()
    if any(marker in low for marker in ERROR_PAGE_MARKERS):
        # Keep the {Result #NNNN} code: it is the only diagnostic CIBC gives.
        lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
        return " | ".join(lines[:4])[:300]
    return None


async def first_of(candidates: dict, timeout_s: int = 45) -> str | None:
    """Name of whichever locator becomes visible first, or None on timeout."""

    async def watch(name: str, locator) -> str:
        await locator.wait_for(state="visible", timeout=timeout_s * 1000)
        return name

    tasks = [asyncio.create_task(watch(n, loc)) for n, loc in candidates.items()]
    try:
        done, pending = await asyncio.wait(
            tasks, timeout=timeout_s, return_when=asyncio.FIRST_COMPLETED
        )
        for task in pending:
            task.cancel()
        for task in done:
            if not task.cancelled() and task.exception() is None:
                return task.result()
        return None
    finally:
        for task in tasks:
            task.cancel()


async def wait_for_otp(since: datetime, timeout_s: int = 120, poll_s: int = 4) -> str | None:
    """Poll Beeper for a sign-on code newer than `since`.

    Three filters, each load-bearing: newer than the attempt (no replaying an
    old code), from the sign-on shortcode, and carrying the sign-on wording --
    3-D Secure purchase codes are otherwise identical in shape.
    """
    deadline = asyncio.get_event_loop().time() + timeout_s
    with BeeperClient() as bc:
        while asyncio.get_event_loop().time() < deadline:
            try:
                msgs = bc.search_messages(date_after=since.isoformat(), limit=20)
            except (httpx.HTTPError, BeeperError):
                # Beeper Desktop may be busy or restarting; keep polling.
                await asyncio.sleep(poll_s)
                continue

            for m in msgs:
                text = m.text or ""
                if m.sender_name != OTP_SENDER or OTP_MARKER not in text:
                    continue
                found = re.search(r"Enter code:\s*(\d{6})\b", text)
                if found:
                    return found.group(1)

            await asyncio.sleep(poll_s)
    return None


async def _two_factor_over_sms(page, otvc, on_step=None) -> None:
    """Switch 2FA from its push-notification default to SMS, then submit.

    Push never arrives unattended. The escape hatch is "Didn't receive the
    code?" -> "Use a different contact method" -> the Text option.
    """
    say = on_step or (lambda _msg: None)

    say("opening the fallback menu")
    await page.click(
        'button:has-text("Didn\u2019t receive the code?"), '
        'button:has-text("Didn\'t receive the code?")',
        timeout=10_000,
    )
    await page.get_by_role("button", name="Resend code").wait_for(
        state="visible", timeout=10_000
    )

    say("choosing a different contact method")
    picker = page.locator('select[name="ContactMethod"]')
    await page.click('button:has-text("Use a different contact method")', timeout=10_000)
    await picker.wait_for(state="visible", timeout=10_000)

    # Match on option text: the value is an opaque id, the text says "Text: ...".
    options = await picker.evaluate(
        "sel => [...sel.options].map(o => ({value: o.value, text: o.text.trim()}))"
    )
    sms = next(
        (o for o in options if "text" in o["text"].lower() or "sms" in o["text"].lower()), None
    )
    if sms is None:
        raise LoginError(f"no SMS option offered; saw {[mask(o['text']) for o in options]}")

    await picker.select_option(value=sms["value"])
    say(f"selected {mask(sms['text'])}")

    # Timestamp before the request so the OTP window starts as late as honestly possible.
    requested_at = datetime.now(UTC)
    await page.click('button:has-text("Send code")', timeout=10_000)
    await otvc.wait_for(state="visible", timeout=20_000)

    say("waiting for the code")
    code = await wait_for_otp(requested_at)
    if not code:
        raise LoginError("no sign-on code arrived within the timeout")

    say("submitting the code")
    await otvc.click()
    await page.keyboard.type(code, delay=90)
    await page.get_by_role("button", name="Continue").click()
    await otvc.wait_for(state="detached", timeout=30_000)
    await page.wait_for_load_state("domcontentloaded")


async def sign_in(page, cred: Credential | None = None, on_step=None) -> None:
    """Get `page` to the signed-in accounts view.

    Raises LoginError if the flow reaches a screen it does not recognise; never
    retries a password, because a retry loop locks the account.
    """
    say = on_step or (lambda _msg: None)
    cred = cred or get_login()

    signed_in = page.get_by_role("button", name="Sign off")
    otvc = page.locator('input[name="OTVC"]')
    card = page.locator('input[name="Card"]')
    password = page.locator('input[type="password"]')
    error = page.locator(ERROR_SELECTOR).first

    async def stop_on_error(context: str) -> None:
        message = await read_error(page)
        if not message:
            raise LoginError(f"{context}: unrecognised screen at {page.url[:90]}")
        low = message.lower()
        if any(m in low for m in ERROR_PAGE_MARKERS):
            raise LoginError(
                f"CIBC returned its error page ({message}). Usually transient: "
                "too many sign-ins without signing off. Wait a few minutes."
            )
        fatal = any(p in low for p in FATAL_PATTERNS)
        raise LoginError(
            f"{'account may be locked -- ' if fatal else ''}CIBC says: {message}"
        )

    say("loading the sign-on page")
    await page.goto(SIGNON_URL, wait_until="domcontentloaded", timeout=60_000)

    # A live session can land straight on the accounts page.
    stage = await first_of(
        {"card": card, "signed_in": signed_in, "error": error}, timeout_s=30
    )
    if stage == "signed_in":
        say("already signed in")
        return
    if stage in (None, "error"):
        await stop_on_error("loading sign-on")

    # OneTrust overlays the page and swallows clicks. Absent once accepted.
    try:
        await page.click("#onetrust-accept-btn-handler", timeout=3000)
    except PlaywrightError:
        say("no cookie banner")

    say(f"entering card ending {cred.username[-4:]}")
    await card.click()
    await page.keyboard.type(cred.username, delay=90)
    await page.get_by_role("button", name="Continue").click()

    # A remembered card can skip the password screen entirely.
    stage = await first_of(
        {"password": password, "otp": otvc, "signed_in": signed_in, "error": error},
        timeout_s=30,
    )
    if stage in (None, "error"):
        await stop_on_error("after card number")

    if stage == "password":
        say("entering password")
        await password.click()
        await page.keyboard.type(cred.password, delay=90)
        await page.get_by_role("button", name=re.compile("Sign on|Continue")).first.click()
        stage = await first_of(
            {"otp": otvc, "signed_in": signed_in, "error": error}, timeout_s=45
        )
        if stage in (None, "error"):
            await stop_on_error("after password")

    if stage == "otp":
        say("2FA required")
        await _two_factor_over_sms(page, otvc, on_step=on_step)
        if await read_error(page):
            await stop_on_error("after submitting the code")
    else:
        say("device trusted, 2FA skipped")

    await signed_in.wait_for(state="visible", timeout=30_000)
    say("signed in")


async def sign_off(page, on_step=None) -> None:
    """End the CIBC session server-side.

    Abandoning a session by closing the browser leaves it open on CIBC's side.
    Enough of those in a short window and sign-on starts returning the
    "We're sorry, there's been an error" interstitial, which looks like a block
    but is self-inflicted. Always sign off.
    """
    say = on_step or (lambda _msg: None)
    button = page.get_by_role("button", name="Sign off")
    try:
        if await button.count() and await button.first.is_visible():
            await button.first.click(timeout=10_000)
            await button.first.wait_for(state="detached", timeout=15_000)
            say("signed off")
    except PlaywrightError as exc:
        # Never mask the caller's real error with a cleanup failure.
        say(f"sign off failed, session may linger: {type(exc).__name__}")


@asynccontextmanager
async def session(cred: Credential | None = None, on_step=None, headless: bool = False):
    """Signed-in CIBC page that always signs off, even when the body raises.

    This is the entry point callers should use.
    """
    async with browser(headless=headless) as ctx:
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await sign_in(page, cred=cred, on_step=on_step)
        try:
            yield page
        finally:
            await sign_off(page, on_step=on_step)


STEALTH_NOTE = """Why Camoufox and not Playwright's own browsers.

Measured against the live CIBC sign-on, submitting the card number:

  Chromium, persistent profile            error page
  Chromium, fresh profile                 error page
  Chromium + navigator.webdriver patches  error page
  Chromium, human-paced typing            error page
  Chromium, instant fill                  error page
  Playwright Firefox, fresh profile       error page
  Firefox by hand, same machine and IP    works
  Camoufox                                works

JS-injected stealth cannot win here: patching a getter leaves the tampering
visible to `Object.getOwnPropertyDescriptor(navigator, 'webdriver').get
.toString()`, and Playwright's own instrumentation is detectable besides.
Camoufox is a patched Firefox that spoofs below JS, in C++, so there is no
JS-visible seam to find.
"""

PROFILE_DIR = Path.home() / ".local/share/cctrack/camoufox"


@asynccontextmanager
async def browser(headless: bool = False):
    """A persistent, non-detectable CIBC browser context.

    Persistence carries cookies and the trusted-device marker, so repeat runs
    skip 2FA and often the password screen too -- which is exactly why sign_in
    races outcomes instead of assuming a fixed sequence.

    headless stays False: CIBC's edge drops headless browsers during the h2
    handshake, before any page code runs. Use `cage` for no visible window.
    """
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    async with AsyncCamoufox(
        headless=headless,
        persistent_context=True,
        user_data_dir=str(PROFILE_DIR),
        os="linux",
        locale="en-CA",
        geoip=True,
        humanize=True,  # human-like cursor paths between click targets
    ) as ctx:
        yield ctx


# --------------------------------------------------------------------------
# Transaction download
# --------------------------------------------------------------------------

DOWNLOAD_URL = (
    "https://www.cibconline.cibc.com/ebm-resources/public/banking/cibc/"
    "client/web/index.html#/accounts/download"
)

MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)

CSV_OPTION = "Spreadsheet (CSV)"

HISTORY_DAYS = 400
"""How far back a backfill reaches.

CIBC's own note on the page: "Credit transactions dating back 13 months from
today's date." 400 days covers that with a little slack; the server clamps
anything longer rather than erroring.

Note ALL_AVAILABLE is *not* used, despite existing on the form: for a credit
card it fails server-side with {Result #0001}. Measured, see docs/cibc-download.md.
"""


class DownloadError(RuntimeError):
    pass


async def list_accounts(page) -> list[str]:
    """Option labels from the download page's account picker.

    Labels carry the masked number and balance, e.g.
    "CIBC VISA (1234 5678 9012 3456) $1,234.56".
    """
    await open_download_page(page)
    picker = page.locator("select").first
    options = await picker.evaluate(
        "sel => [...sel.options].map(o => o.text.trim())"
    )
    return [o for o in options if not o.lower().startswith("choose")]


async def open_download_page(page) -> None:
    """Navigate to the download form and wait for it to render."""
    if "#/accounts/download" not in page.url:
        link = page.get_by_role("link", name="Download Transactions").first
        if await link.count():
            await link.click()
        else:
            await page.goto(DOWNLOAD_URL, wait_until="domcontentloaded")

    # The form is Angular-rendered: eight selects and the criteria radios.
    await page.locator('input[name="criteria"]').first.wait_for(
        state="attached", timeout=30_000
    )
    await page.locator("select").first.wait_for(state="visible", timeout=30_000)


async def _set_date(page, selects: list, start: int, when: date) -> None:
    """Fill one month/day/year select triple."""
    await selects[start].select_option(label=MONTHS[when.month - 1])
    await selects[start + 1].select_option(label=str(when.day))
    await selects[start + 2].select_option(label=str(when.year))


async def _choose_criteria(page, value: str) -> None:
    """Select one of the criteria radios.

    The real <input type=radio> sits under a styled <div class="ui-wrapper">
    that intercepts pointer events, so a direct .check() times out. Click the
    associated <label> -- what a person actually clicks -- and fall back to
    .check(force=True) if the markup has no usable label.
    """
    radio = page.locator(f'input[name="criteria"][value="{value}"]')
    await radio.wait_for(state="attached", timeout=20_000)

    radio_id = await radio.get_attribute("id")
    if radio_id:
        label = page.locator(f'label[for="{radio_id}"]')
        if await label.count():
            await label.first.click()
            if await radio.is_checked():
                return

    await radio.check(force=True)
    if not await radio.is_checked():
        raise DownloadError(f"could not select criteria {value!r}")


async def download_transactions(
    page,
    account: str,
    dest_dir: Path,
    *,
    since: date | None = None,
    until: date | None = None,
    on_step=None,
) -> Path:
    """Download one account's transactions as CSV. Returns the saved path.

    With no dates, requests the full retained history (HISTORY_DAYS back).
    Otherwise requests exactly the window given.

    Always DATE_RANGE. The form also offers ALL_AVAILABLE and LAST_DOWNLOAD and
    neither is usable: ALL_AVAILABLE fails server-side for credit cards with
    {Result #0001}, and LAST_DOWNLOAD is stateful -- CIBC marks a window
    consumed whether or not our import succeeded, so a crash loses those
    transactions permanently. A caller-chosen range is idempotent and safe to
    overlap; the importer dedups.
    """
    say = on_step or (lambda _msg: None)
    await open_download_page(page)

    selects = await page.locator("select").all()
    if len(selects) < 8:
        raise DownloadError(f"expected 8 selects on the download form, found {len(selects)}")

    account_picker, software_picker = selects[0], selects[-1]

    matches = [
        label for label in await account_picker.evaluate(
            "sel => [...sel.options].map(o => o.text.trim())"
        )
        if account.lower() in label.lower()
    ]
    if not matches:
        raise DownloadError(f"no account matching {account!r} in the picker")
    await account_picker.select_option(label=matches[0])
    say(f"account: {mask(matches[0])}")

    today = datetime.now(UTC).date()
    start = since or today - timedelta(days=HISTORY_DAYS)
    end = until or today

    await _choose_criteria(page, "DATE_RANGE")
    await _set_date(page, selects, 1, start)
    await _set_date(page, selects, 4, end)
    say(f"range: {start} to {end}")

    await software_picker.select_option(label=CSV_OPTION)

    # CIBC's UI kit hides the real control under a styled <div class="ui-wrapper">
    # -- the <button type=submit> measures 0x0 and only the wrapper is clickable.
    # Same pattern as the criteria radios.
    submit = page.locator(
        'div.ui-wrapper:has-text("Download Transactions"), '
        'button[type=submit]:has-text("Download Transactions")'
    ).last

    dest_dir.mkdir(parents=True, exist_ok=True)
    async with page.expect_download(timeout=120_000) as info:
        await submit.click()
    download = await info.value

    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    slug = re.sub(r"[^a-z0-9]+", "-", account.lower()).strip("-")
    dest = dest_dir / f"{slug}-{stamp}.csv"
    await download.save_as(dest)
    say(f"saved {dest.name} ({dest.stat().st_size} bytes)")
    return dest
