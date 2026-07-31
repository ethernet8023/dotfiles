"""Diagnostic: attempt a real CIBC sign-on and stop at the 2FA prompt.

Point of this run: make CIBC send a real OTP so we can see which shortcode it
actually comes from. The plan assumed 242227, but those messages say "CIBC US"
and belong to a different account, so the assumption needs testing.

Deliberately conservative, because this is a real bank account:
  - ONE attempt. No retry loop. A wrong-password loop locks the account.
  - Stops at the OTP screen. Never submits a code.
  - Screenshots every step to downloads/ (gitignored).
  - Any text printed has its digits masked.

Must run headed under a compositor -- see login_probe.sh.
"""

from __future__ import annotations

import asyncio
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

    t0 = datetime.now(UTC)
    print(f"T0 (OTP must be newer than this): {t0.isoformat()}", flush=True)

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
        await page.wait_for_selector("input", timeout=30_000)
        await page.wait_for_timeout(2500)
        print(f"  url: {page.url[:90]}...", flush=True)

        # OneTrust overlays the page and swallows clicks until dismissed.
        try:
            await page.click("#onetrust-accept-btn-handler", timeout=5000)
            print("  dismissed cookie banner", flush=True)
        except Exception:
            print("  no cookie banner (already accepted)", flush=True)

        await dump_form(page, "step1")
        await shot(page, "1-card")

        print("\n== step 1: card number ==", flush=True)
        await page.fill('input[name="Card"]', cred.username)
        print(f"  filled card ending {cred.username[-4:]}", flush=True)
        await page.click('button:has-text("Continue")')
        await page.wait_for_timeout(4000)

        print("\n== step 2: password screen ==", flush=True)
        try:
            await page.wait_for_selector('input[type="password"]', timeout=20_000)
        except Exception:
            print("  !! no password field appeared", flush=True)
            await dump_form(page, "step2-unexpected")
            await shot(page, "2-unexpected")
            await ctx.close()
            sys.exit(1)

        await dump_form(page, "step2")
        await shot(page, "2-password")

        await page.fill('input[type="password"]', cred.password)
        print("  filled password", flush=True)
        await page.click('button:has-text("Sign on"), button:has-text("Continue")')
        await page.wait_for_timeout(7000)

        print("\n== step 3: whatever came next ==", flush=True)
        print(f"  url: {page.url[:90]}...", flush=True)
        await dump_form(page, "step3")
        await shot(page, "3-after-password")

        # CIBC defaults to a push notification to their mobile app, which is no
        # good unattended. The escape hatch is "Didn't receive the code?" ->
        # pick another contact method -> text message.
        print("\n== step 4: switch delivery to SMS ==", flush=True)
        try:
            await page.click(
                'button:has-text("Didn\u2019t receive the code?"), '
                'button:has-text("Didn\'t receive the code?")',
                timeout=10_000,
            )
        except Exception as exc:
            print(f"  !! could not open the fallback menu: {type(exc).__name__}", flush=True)
            await shot(page, "4-no-fallback")
            await ctx.close()
            sys.exit(1)

        await page.wait_for_timeout(3000)
        await dump_options(page, "step4")
        await shot(page, "4-delivery-options")

        print("\n== step 5: use a different contact method ==", flush=True)
        try:
            await page.click('button:has-text("Use a different contact method")', timeout=10_000)
        except Exception as exc:
            print(f"  !! no contact-method button: {type(exc).__name__}", flush=True)
            await shot(page, "5-no-contact-method")
            await ctx.close()
            sys.exit(1)

        await page.wait_for_timeout(3500)
        await dump_options(page, "step5")
        await shot(page, "5-contact-methods")

        print("\n== step 6: pick the text/SMS option ==", flush=True)
        # The picker is a <select>. Match on option text, since the value is an
        # opaque id and the text is what says "Text message to ...".
        picked = None
        select = page.locator("select").first
        if await select.count():
            options = await select.evaluate(
                "sel => [...sel.options].map(o => ({value: o.value, text: o.text.trim()}))"
            )
            for opt in options:
                low = opt["text"].lower()
                if "text" in low or "sms" in low:
                    await select.select_option(value=opt["value"])
                    picked = mask(opt["text"])
                    break

        if not picked:
            print("  !! no text/SMS option in the picker -- dumping what is there", flush=True)
            await dump_options(page, "step6-unmatched")
            await shot(page, "6-unmatched")
            await ctx.close()
            sys.exit(1)

        print(f"  selected: {picked!r}", flush=True)
        await page.wait_for_timeout(1500)
        await dump_options(page, "step6")
        await shot(page, "6-after-pick")

        print("\n== step 7: send the code ==", flush=True)
        await page.click('button:has-text("Send code")', timeout=10_000)
        print("  clicked Send code", flush=True)

        await page.wait_for_timeout(6000)
        await dump_options(page, "step7")
        await shot(page, "7-code-requested")

        print("\n>>> STOPPING HERE. Not submitting any code. <<<", flush=True)
        print(f">>> T0 was {t0.isoformat()} <<<", flush=True)

        await watch_beeper(t0)

        await shot(page, "8-final")
        await ctx.close()


async def watch_beeper(t0, timeout_s: int = 90, poll_s: int = 5) -> None:
    """Poll Beeper for anything new after t0 and report the real sender.

    This is the whole point of the run: the plan assumed shortcode 242227, but
    those messages say "CIBC US" and belong to a different account. Report what
    actually arrives rather than what was assumed.
    """
    from cctrack.secrets.beeper import BeeperClient

    print(f"\n== watching Beeper for messages after {t0.isoformat()} ==", flush=True)
    deadline = asyncio.get_event_loop().time() + timeout_s
    seen: set[str] = set()

    with BeeperClient() as bc:
        while asyncio.get_event_loop().time() < deadline:
            try:
                msgs = bc.search_messages(date_after=t0.isoformat(), limit=25)
            except Exception as exc:
                print(f"  beeper query failed: {type(exc).__name__}: {exc}", flush=True)
                break

            for m in msgs:
                if m.id in seen:
                    continue
                seen.add(m.id)
                text = m.text or ""
                digits = "".join(ch for ch in text if ch.isdigit())
                flag = "  <-- LOOKS LIKE AN OTP" if len(digits) >= 6 else ""
                print(f"  NEW  sender_id={m.sender_id!r}", flush=True)
                print(f"       sender_name={m.sender_name!r} account={m.account_id!r}", flush=True)
                print(f"       ts={m.timestamp}", flush=True)
                print(f"       text={mask(text)[:120]!r}{flag}", flush=True)

            await asyncio.sleep(poll_s)

    if not seen:
        print("  nothing new arrived in Beeper", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
