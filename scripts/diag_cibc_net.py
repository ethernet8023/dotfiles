"""Diagnostic: why does chromium stall on cibc.com when curl gets a 200?

Run: nix develop -c python3 scripts/diag_cibc_net.py
"""

from __future__ import annotations

import asyncio

from playwright.async_api import async_playwright

URL = "https://www.cibc.com/en/personal-banking.html"
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)


async def attempt(label: str, launch_args: list[str], goto_kwargs: dict) -> None:
    print(f"\n=== {label} (args={launch_args}) ===")
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True, args=launch_args)
        ctx = await browser.new_context(user_agent=UA, locale="en-CA")
        page = await ctx.new_page()

        page.on("request", lambda r: print(f"  -> {r.method} {r.url[:100]}")
                if r.is_navigation_request() else None)
        page.on("response", lambda r: print(f"  <- {r.status} {r.url[:100]}"))
        page.on("requestfailed",
                lambda r: print(f"  XX {r.failure} {r.url[:100]}"))

        try:
            resp = await page.goto(URL, **goto_kwargs)
            print(f"  RESULT: status={resp.status if resp else None} url={page.url}")
            print(f"  title: {await page.title()}")
        except Exception as exc:
            print(f"  RESULT: {type(exc).__name__}: {str(exc)[:200]}")
        await browser.close()


async def main() -> None:
    await attempt("baseline http2", [], {"wait_until": "commit", "timeout": 25_000})
    await attempt("disable-http2", ["--disable-http2"],
                  {"wait_until": "commit", "timeout": 25_000})
    await attempt("disable-http2 + no-sandbox",
                  ["--disable-http2", "--no-sandbox", "--disable-dev-shm-usage"],
                  {"wait_until": "commit", "timeout": 25_000})


if __name__ == "__main__":
    asyncio.run(main())
