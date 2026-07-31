"""Diagnostic: does CIBC serve a headed chromium but stonewall a headless one?

curl gets HTTP 200 from cibc.com over h2, chromium-headless gets
ERR_HTTP2_PROTOCOL_ERROR (and a silent hang with --disable-http2). That smells
like edge-side bot fingerprinting rather than a transport bug. This runs the
same navigation headless and headed and prints both outcomes so we can tell.

Leaves the headed window open (HOLD_SECONDS) so a human can watch it.

Run: nix develop -c python3 scripts/diag_cibc_headed.py
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

from playwright.async_api import async_playwright

FRONT_DOOR = "https://www.cibc.com/en/personal-banking.html"
SIGNON = "https://www.cibconline.cibc.com/ebm-resources/public/client/web/index.html#/signon"

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "downloads"
HOLD_SECONDS = int(os.environ.get("HOLD_SECONDS", "150"))


async def probe(pw, *, headless: bool, url: str, label: str) -> bool:
    print(f"\n=== {label} | headless={headless} | {url}", flush=True)
    browser = await pw.chromium.launch(headless=headless)
    ctx = await browser.new_context(
        viewport={"width": 1400, "height": 1000},
        locale="en-CA",
        timezone_id="America/Toronto",
    )
    page = await ctx.new_page()
    page.on("requestfailed", lambda r: print(f"  XX {r.failure} {r.url[:90]}", flush=True))

    ok = False
    try:
        resp = await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
        status = resp.status if resp else None
        title = await page.title()
        print(f"  RESULT: status={status}", flush=True)
        print(f"  url:    {page.url}", flush=True)
        print(f"  title:  {title!r}", flush=True)
        ok = bool(status and status < 400)
    except Exception as exc:  # noqa: BLE001 - diagnostic
        print(f"  RESULT: {type(exc).__name__}: {str(exc)[:160]}", flush=True)

    if ok:
        OUT.mkdir(exist_ok=True)
        shot = OUT / f"cibc-{label.replace(' ', '-')}.png"
        await page.screenshot(path=str(shot), full_page=False)
        print(f"  shot:   {shot}", flush=True)

    if ok and headless is False:
        print(f"\n  >>> holding window open {HOLD_SECONDS}s, go look <<<\n", flush=True)
        await page.wait_for_timeout(HOLD_SECONDS * 1000)

    await browser.close()
    return ok


async def main() -> None:
    async with async_playwright() as pw:
        await probe(pw, headless=True, url=FRONT_DOOR, label="headless frontdoor")
        headed_ok = await probe(pw, headless=False, url=FRONT_DOOR, label="headed frontdoor")
        if headed_ok:
            await probe(pw, headless=False, url=SIGNON, label="headed signon")


if __name__ == "__main__":
    asyncio.run(main())
