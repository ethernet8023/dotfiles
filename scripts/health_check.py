"""Is the sign-on page healthy? No credentials, so no lockout risk.

Loads the sign-on page twice -- once with a throwaway profile, once with the
real one -- and reports which renders the card field and which shows CIBC's
error page. That separates a server-side block from poisoned local cookies.
"""

from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path

from playwright.async_api import async_playwright

from cctrack.ingest.cibc_web import PROFILE_DIR, SIGNON_URL, read_error

OUT = Path(__file__).resolve().parent.parent / "downloads"


async def check(profile: Path, label: str) -> None:
    async with async_playwright() as pw:
        ctx = await pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=False,
            viewport={"width": 1400, "height": 900},
            locale="en-CA",
            timezone_id="America/Toronto",
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        try:
            resp = await page.goto(SIGNON_URL, wait_until="domcontentloaded", timeout=45_000)
            status = resp.status if resp else None
            await page.wait_for_timeout(4000)

            card = page.locator('input[name="Card"]')
            has_card = await card.count() > 0 and await card.first.is_visible()
            error = await read_error(page)
            title = await page.title()

            print(f"\n[{label}]", flush=True)
            print(f"  status:     {status}", flush=True)
            print(f"  title:      {title!r}", flush=True)
            print(f"  card field: {has_card}", flush=True)
            print(f"  error text: {error!r}", flush=True)
            print(f"  url:        {page.url[:100]}", flush=True)

            OUT.mkdir(exist_ok=True)
            await page.screenshot(path=str(OUT / f"health-{label}.png"))
        finally:
            await ctx.close()


async def main() -> None:
    with tempfile.TemporaryDirectory(prefix="cctrack-health-") as tmp:
        await check(Path(tmp), "fresh-profile")
    await check(PROFILE_DIR, "real-profile")


if __name__ == "__main__":
    asyncio.run(main())
