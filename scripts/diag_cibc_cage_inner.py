"""Inner half of diag_cibc_cage.sh -- runs headed inside the cage compositor.

Must be launched by diag_cibc_cage.sh, which supplies the compositor. Running
this directly on a normal desktop just opens a visible window.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

from playwright.async_api import async_playwright

FRONT_DOOR = "https://www.cibc.com/en/personal-banking.html"
SIGNON = "https://www.cibconline.cibc.com/ebm-resources/public/client/web/index.html#/signon"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "downloads"


async def main() -> None:
    OUT.mkdir(exist_ok=True)
    results = []

    async with async_playwright() as pw:
        # headless=False is the whole point: a real headed chromium, hidden only
        # because the compositor around it is itself headless.
        browser = await pw.chromium.launch(headless=False)
        ctx = await browser.new_context(
            viewport={"width": 1400, "height": 1000},
            locale="en-CA",
            timezone_id="America/Toronto",
        )
        page = await ctx.new_page()

        for label, url in (("frontdoor", FRONT_DOOR), ("signon", SIGNON)):
            entry = {"label": label, "ok": False}
            try:
                resp = await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
                status = resp.status if resp else None
                entry["status"] = status
                entry["title"] = await page.title()
                entry["url"] = page.url
                entry["ok"] = bool(status and status < 400)
                print(f"[{label}] status={status} title={entry['title']!r}", flush=True)
                if entry["ok"]:
                    await page.wait_for_timeout(3000)
                    shot = OUT / f"cibc-cage-{label}.png"
                    await page.screenshot(path=str(shot))
                    entry["screenshot"] = str(shot)
                    print(f"[{label}] shot: {shot}", flush=True)
            except Exception as exc:  # noqa: BLE001 - diagnostic
                entry["error"] = f"{type(exc).__name__}: {str(exc)[:140]}"
                print(f"[{label}] {entry['error']}", flush=True)
            results.append(entry)

        await browser.close()

    (OUT / "cage-matrix.json").write_text(json.dumps(results, indent=2))
    print("\nVERDICT: " + ", ".join(
        f"{r['label']}={'PASS' if r['ok'] else 'FAIL'}" for r in results
    ), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
