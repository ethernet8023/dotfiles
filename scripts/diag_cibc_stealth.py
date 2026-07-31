"""Diagnostic: which chromium mode does CIBC's Akamai edge actually serve?

Proven so far: headless=True -> ERR_HTTP2_PROTOCOL_ERROR, headed -> 200.
CIBC runs Akamai Bot Manager (we saw /public/<hash>/ah + /collect sensor calls),
which fingerprints below the HTML layer. The question is which of the cheaper
non-headed modes it will accept, since a cron job can't own a visible window.

Modes tested:
  1. headless_shell   - playwright's default headless (the known-bad baseline)
  2. new-headless     - full chromium binary in headless mode (channel="chromium")
  3. new-headless+stealth - same, with the navigator.webdriver giveaway patched

A headed-under-cage run is tested separately by diag_cibc_cage.sh, since it
needs a compositor wrapped around the whole process.

Run: nix develop -c python3 scripts/diag_cibc_stealth.py
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

from playwright.async_api import async_playwright

URL = "https://www.cibc.com/en/personal-banking.html"
ROOT = Path(__file__).resolve().parent.parent

# Removes the single loudest automation tell. Akamai reads far more than this,
# so treat it as one variable in the matrix, not a silver bullet.
STEALTH_JS = """
Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
Object.defineProperty(navigator, 'languages', {get: () => ['en-CA', 'en']});
window.chrome = {runtime: {}};
"""


async def probe(pw, label: str, *, channel: str | None, stealth: bool) -> dict:
    print(f"\n=== {label}", flush=True)
    kwargs: dict = {"headless": True}
    if channel:
        kwargs["channel"] = channel

    result = {"label": label, "channel": channel, "stealth": stealth, "ok": False}
    try:
        browser = await pw.chromium.launch(**kwargs)
    except Exception as exc:
        result["error"] = f"launch failed: {type(exc).__name__}: {str(exc)[:120]}"
        print(f"  {result['error']}", flush=True)
        return result

    ctx = await browser.new_context(
        viewport={"width": 1400, "height": 1000},
        locale="en-CA",
        timezone_id="America/Toronto",
    )
    if stealth:
        await ctx.add_init_script(STEALTH_JS)

    page = await ctx.new_page()
    try:
        resp = await page.goto(URL, wait_until="domcontentloaded", timeout=40_000)
        status = resp.status if resp else None
        title = await page.title()
        result["status"] = status
        result["title"] = title
        result["ok"] = bool(status and status < 400)
        print(f"  status={status} title={title!r}", flush=True)
    except Exception as exc:
        result["error"] = f"{type(exc).__name__}: {str(exc)[:120]}"
        print(f"  {result['error']}", flush=True)

    await browser.close()
    return result


async def main() -> None:
    results = []
    async with async_playwright() as pw:
        results.append(await probe(pw, "1. headless_shell (baseline)", channel=None, stealth=False))
        results.append(await probe(pw, "2. new-headless", channel="chromium", stealth=False))
        results.append(await probe(pw, "3. new-headless + stealth", channel="chromium", stealth=True))

    print("\n" + "=" * 60)
    for r in results:
        mark = "PASS" if r["ok"] else "FAIL"
        print(f"  [{mark}] {r['label']}: {r.get('status') or r.get('error', '')}")

    (ROOT / "downloads").mkdir(exist_ok=True)
    (ROOT / "downloads" / "stealth-matrix.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
