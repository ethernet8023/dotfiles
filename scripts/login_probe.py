"""Sign in to CIBC end to end, unattended.

Bitwarden -> card number -> password -> 2FA -> signed in.

CIBC defaults 2FA to a push notification to their mobile app, which never
arrives unattended, so this drives the fallback: "Didn't receive the code?" ->
"Use a different contact method" -> the Text option -> "Send code", then reads
the code out of Beeper.

Deliberately conservative, because this is a real bank account:
  - ONE attempt. No retry loop: a wrong-password loop locks the account.
  - Screenshots every step to downloads/ (gitignored).
  - Any text printed has its digits masked.
  - Waits on page conditions, never on a clock.

Must run headed under a compositor -- see login_probe.sh. Akamai drops headless
chromium during the h2 handshake.
"""

from __future__ import annotations

import asyncio
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

from playwright.async_api import async_playwright

from cctrack.secrets.bitwarden import get_login

START_URL = "https://www.cibconline.cibc.com/ebm-resources/public/client/web/index.html#/signon"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "downloads"
PROFILE = Path.home() / ".local/share/cctrack/browser"


def mask(text: str) -> str:
    return "".join("N" if ch.isdigit() else ch for ch in text)


async def dump_form(page, label: str) -> None:
    """Print visible form structure only -- never page copy from an authed view."""
    fields = await page.evaluate("""() => {
      const vis = el => { const r = el.getBoundingClientRect();
                          return r.width > 0 && r.height > 0; };
      return {
        inputs: [...document.querySelectorAll('input')].filter(vis).map(el => ({
          type: el.type, name: el.name, id: el.id,
          label: el.getAttribute('aria-label'), maxlength: el.getAttribute('maxlength'),
        })),
        buttons: [...document.querySelectorAll('button')].filter(vis)
          .map(el => (el.innerText || '').trim().slice(0, 40)).filter(Boolean),
        headings: [...document.querySelectorAll('h1,h2,h3,legend')].filter(vis)
          .map(el => (el.innerText || '').trim().slice(0, 80)).filter(Boolean),
      };
    }""")
    print(f"  [{label}] inputs:   {fields['inputs']}", flush=True)
    print(f"  [{label}] buttons:  {fields['buttons']}", flush=True)
    print(f"  [{label}] headings: {[mask(h) for h in fields['headings']]}", flush=True)


async def dump_options(page, label: str) -> None:
    """Dump selectable delivery-method choices. Phone digits are masked."""
    opts = await page.evaluate("""() => {
      const vis = el => { const r = el.getBoundingClientRect();
                          return r.width > 0 && r.height > 0; };
      return {
        radios: [...document.querySelectorAll('input[type=radio]')].filter(vis).map(el => ({
          name: el.name, id: el.id, value: el.value,
          label: (document.querySelector(`label[for="${el.id}"]`) || {}).innerText || '',
        })),
        labels: [...document.querySelectorAll('label')].filter(vis)
          .map(el => (el.innerText || '').trim().slice(0, 70)).filter(Boolean),
        buttons: [...document.querySelectorAll('button, a[role=button]')].filter(vis)
          .map(el => (el.innerText || '').trim().slice(0, 50)).filter(Boolean),
        headings: [...document.querySelectorAll('h1,h2,h3,legend,fieldset')].filter(vis)
          .map(el => (el.innerText || '').trim().slice(0, 90)).filter(Boolean),
      };
    }""")
    for key in ("headings", "radios", "labels", "buttons"):
        printable = [mask(str(v)) for v in opts[key]]
        print(f"  [{label}] {key}: {printable}", flush=True)

    # The contact-method picker is a <select>, not radios or buttons.
    selects = await page.evaluate("""() => {
      const vis = el => { const r = el.getBoundingClientRect();
                          return r.width > 0 && r.height > 0; };
      return [...document.querySelectorAll('select')].filter(vis).map(sel => ({
        name: sel.name, id: sel.id, value: sel.value,
        options: [...sel.options].map(o => ({value: o.value, text: o.text.trim()})),
      }));
    }""")
    for s in selects:
        print(f"  [{label}] SELECT name={s['name']!r} id={s['id']!r} "
              f"value={mask(str(s['value']))!r}", flush=True)
        for o in s["options"]:
            print(f"      option value={mask(o['value'])!r} text={mask(o['text'])!r}", flush=True)


async def shot(page, name: str) -> None:
    OUT.mkdir(exist_ok=True)
    path = OUT / f"login-{name}.png"
    await page.screenshot(path=str(path))
    print(f"  shot: {path}", flush=True)


async def main() -> None:
    cred = get_login()
    print(f"credential: {cred!r}", flush=True)

    PROFILE.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as pw:
        ctx = await pw.chromium.launch_persistent_context(
            user_data_dir=str(PROFILE),
            headless=False,  # Akamai drops headless during the h2 handshake
            viewport={"width": 1400, "height": 1000},
            locale="en-CA",
            timezone_id="America/Toronto",
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()

        print("\n== step 0: load sign-on ==", flush=True)
        await page.goto(START_URL, wait_until="domcontentloaded", timeout=60_000)
        card = page.locator('input[name="Card"]')
        await card.wait_for(state="visible", timeout=30_000)
        print(f"  url: {page.url[:90]}...", flush=True)

        # OneTrust overlays the page and swallows clicks until dismissed.
        try:
            await page.click("#onetrust-accept-btn-handler", timeout=3000)
            print("  dismissed cookie banner", flush=True)
        except Exception:
            print("  no cookie banner (already accepted)", flush=True)

        await dump_form(page, "step1")
        await shot(page, "1-card")

        print("\n== step 1: card number ==", flush=True)
        await card.fill(cred.username)
        print(f"  filled card ending {cred.username[-4:]}", flush=True)
        await page.click('button:has-text("Continue")')

        print("\n== step 2: password screen ==", flush=True)
        password = page.locator('input[type="password"]')
        try:
            await password.wait_for(state="visible", timeout=20_000)
        except Exception:
            print("  !! no password field appeared", flush=True)
            await dump_form(page, "step2-unexpected")
            await shot(page, "2-unexpected")
            await ctx.close()
            sys.exit(1)

        await dump_form(page, "step2")
        await shot(page, "2-password")

        await password.fill(cred.password)
        print("  filled password", flush=True)
        await page.click('button:has-text("Sign on"), button:has-text("Continue")')

        print("\n== step 3: 2FA, or straight in? ==", flush=True)
        # A trusted device (persistent profile + RememberCard) skips 2FA entirely
        # and lands on the accounts page, so race the two outcomes rather than
        # assuming the OTP prompt.
        otvc = page.locator('input[name="OTVC"]')
        signed_in_marker = page.get_by_role("button", name="Sign off")
        which = await first_of(
            {"otp": otvc, "signed_in": signed_in_marker}, timeout_s=45
        )
        if which is None:
            print("  !! neither the OTP prompt nor the accounts page appeared", flush=True)
            await shot(page, "3-unexpected")
            await ctx.close()
            sys.exit(1)

        print(f"  -> {which}", flush=True)
        await shot(page, "3-after-password")

        if which == "otp":
            await two_factor_over_sms(page, ctx, otvc)
        else:
            print("  device already trusted, 2FA skipped", flush=True)

        print(f"  url: {page.url[:100]}", flush=True)
        print(f"  title: {await page.title()!r}", flush=True)
        await dump_options(page, "step9")
        await shot(page, "9-after-otp")

        signed_in = "signon" not in page.url.lower()
        print(f"\n>>> SIGNED IN: {signed_in} <<<", flush=True)

        await ctx.close()


async def first_of(candidates: dict, timeout_s: int = 45) -> str | None:
    """Return the name of whichever locator becomes visible first.

    CIBC's post-password page depends on whether the device is trusted, so
    waiting on one specific element burns the full timeout half the time.
    """
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


async def two_factor_over_sms(page, ctx, otvc) -> None:
    """Drive CIBC's 2FA from its push-notification default over to SMS.

    Push is the default and never arrives unattended. The escape hatch is
    "Didn't receive the code?" -> "Use a different contact method" -> Text.
    """
    print("\n== step 4: switch delivery to SMS ==", flush=True)
    try:
        await page.click(
            'button:has-text("Didn\u2019t receive the code?"), '
            'button:has-text("Didn\'t receive the code?")',
            timeout=10_000,
        )
        await page.get_by_role("button", name="Resend code").wait_for(
            state="visible", timeout=10_000
        )
    except Exception as exc:
        print(f"  !! fallback menu did not open: {type(exc).__name__}", flush=True)
        await shot(page, "4-no-fallback")
        await ctx.close()
        sys.exit(1)

    await shot(page, "4-delivery-options")

    print("\n== step 5: use a different contact method ==", flush=True)
    picker = page.locator('select[name="ContactMethod"]')
    try:
        await page.click('button:has-text("Use a different contact method")', timeout=10_000)
        await picker.wait_for(state="visible", timeout=10_000)
    except Exception as exc:
        print(f"  !! no contact-method picker: {type(exc).__name__}", flush=True)
        await shot(page, "5-no-contact-method")
        await ctx.close()
        sys.exit(1)

    await shot(page, "5-contact-methods")

    print("\n== step 6: pick the text/SMS option ==", flush=True)
    # Match on option text: the value is an opaque id, the text says "Text: ...".
    options = await picker.evaluate(
        "sel => [...sel.options].map(o => ({value: o.value, text: o.text.trim()}))"
    )
    sms = next(
        (o for o in options if "text" in o["text"].lower() or "sms" in o["text"].lower()), None
    )
    if sms is None:
        print("  !! no text/SMS option in the picker", flush=True)
        await dump_options(page, "step6-unmatched")
        await shot(page, "6-unmatched")
        await ctx.close()
        sys.exit(1)

    await picker.select_option(value=sms["value"])
    print(f"  selected: {mask(sms['text'])!r}", flush=True)

    print("\n== step 7: send the code ==", flush=True)
    t_sent = datetime.now(UTC)
    await page.click('button:has-text("Send code")', timeout=10_000)
    await otvc.wait_for(state="visible", timeout=20_000)
    print("  code requested", flush=True)

    print("\n== step 8: read the code out of Beeper ==", flush=True)
    # Poll from when the SMS was requested, not process start: tightest honest window.
    code = await wait_for_otp(t_sent)
    if not code:
        print("  !! no OTP arrived", flush=True)
        await ctx.close()
        sys.exit(1)
    print(f"  got a {len(code)}-digit code", flush=True)

    print("\n== step 9: submit it ==", flush=True)
    await otvc.fill(code)
    await page.click('button:has-text("Continue")')
    await otvc.wait_for(state="detached", timeout=30_000)
    await page.wait_for_load_state("domcontentloaded")


async def wait_for_otp(since, timeout_s: int = 120, poll_s: int = 4) -> str | None:
    """Poll Beeper for a fresh CIBC sign-on code.

    Only accepts messages after `since` (no replaying an old code), from shortcode
    242227, whose body says "to authorize sign on" -- 242226 sends 3-D Secure
    purchase codes that look identical otherwise.
    """
    from cctrack.secrets.beeper import BeeperClient

    deadline = asyncio.get_event_loop().time() + timeout_s
    with BeeperClient() as bc:
        while asyncio.get_event_loop().time() < deadline:
            try:
                msgs = bc.search_messages(date_after=since.isoformat(), limit=20)
            except Exception as exc:
                print(f"  beeper query failed: {type(exc).__name__}", flush=True)
                await asyncio.sleep(poll_s)
                continue

            for m in msgs:
                text = m.text or ""
                if m.sender_name != "242227" or "to authorize sign on" not in text:
                    continue
                found = re.search(r"Enter code:\s*(\d{6})\b", text)
                if found:
                    print(f"  OTP from {m.sender_name} at {m.timestamp}", flush=True)
                    return found.group(1)

            await asyncio.sleep(poll_s)
    return None


if __name__ == "__main__":
    asyncio.run(main())
