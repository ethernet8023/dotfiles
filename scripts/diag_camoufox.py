"""Can Camoufox get past the CIBC card-number submit?

Everything else has failed identically: Chromium and Playwright-Firefox, fresh
and persistent profiles, with and without JS stealth patches, instant and
human-paced timing. Meanwhile Firefox-by-hand on this same machine works.

Camoufox is a patched Firefox that spoofs at the C++ level rather than by JS
injection, so its lies survive `Object.getOwnPropertyDescriptor(...).toString()`
checks that ours do not.

Card number only -- the public first step, no password, no lockout risk.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from camoufox.async_api import AsyncCamoufox

from cctrack.ingest.cibc_web import SIGNON_URL, read_error
from cctrack.secrets.bitwarden import get_login

OUT = Path(__file__).resolve().parent.parent / "downloads"
PROFILE = Path.home() / ".local/share/cctrack/camoufox"


async def main() -> None:
    card = get_login().username
    PROFILE.mkdir(parents=True, exist_ok=True)

    async with AsyncCamoufox(
        headless=False,
        persistent_context=True,
        user_data_dir=str(PROFILE),
        os="linux",
        locale="en-CA",
        geoip=True,
        humanize=True,  # human-like cursor movement between targets
    ) as ctx:
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()

        print("loading sign-on...", flush=True)
        await page.goto(SIGNON_URL, wait_until="domcontentloaded", timeout=60_000)

        field = page.locator('input[name="Card"]')
        await field.wait_for(state="visible", timeout=30_000)
        print(f"  card field visible; title={await page.title()!r}", flush=True)

        try:
            await page.click("#onetrust-accept-btn-handler", timeout=3000)
            print("  dismissed cookie banner", flush=True)
        except Exception:
            print("  no cookie banner", flush=True)

        print(f"submitting card ending {card[-4:]}...", flush=True)
        await field.click()
        await page.keyboard.type(card, delay=90)
        await page.get_by_role("button", name="Continue").click()

        password = page.locator('input[type="password"]')
        verdict = None
        for _ in range(30):
            if await password.count() and await password.first.is_visible():
                verdict = "PASSWORD SCREEN -- CAMOUFOX WORKS"
                break
            err = await read_error(page)
            if err:
                verdict = f"ERROR: {err[:120]}"
                break
            await page.wait_for_timeout(1000)
        verdict = verdict or f"TIMEOUT at {page.url[:70]}"

        OUT.mkdir(exist_ok=True)
        await page.screenshot(path=str(OUT / "camoufox-submit.png"))
        print(f"\n>>> {verdict}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
