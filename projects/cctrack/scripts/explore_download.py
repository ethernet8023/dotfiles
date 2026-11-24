"""Explore CIBC's transaction-download UI so the exporter isn't guesswork.

Signs in, opens the credit card, and reports what the download control offers:
formats, date-range options, how far back history goes. Downloads nothing.

Must run headed under a compositor. See explore_download.sh.
"""

from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path

from cctrack.ingest.cibc_web import LoginError, mask, session

OUT = Path(__file__).resolve().parent.parent / "downloads"


async def shot(page, name: str) -> None:
    OUT.mkdir(exist_ok=True)
    await page.screenshot(path=str(OUT / f"explore-{name}.png"))


async def describe(page, label: str) -> dict:
    """Snapshot the interactive controls on the current view."""
    data = await page.evaluate("""() => {
      const vis = el => { const r = el.getBoundingClientRect();
                          return r.width > 0 && r.height > 0; };
      return {
        links: [...document.querySelectorAll('a')].filter(vis)
          .map(a => ({text: (a.innerText||'').trim().slice(0,50), href: a.href}))
          .filter(a => a.text),
        buttons: [...document.querySelectorAll('button')].filter(vis)
          .map(b => (b.innerText||'').trim().slice(0,50)).filter(Boolean),
        selects: [...document.querySelectorAll('select')].filter(vis).map(s => ({
          name: s.name, options: [...s.options].map(o => o.text.trim()),
        })),
        radios: [...document.querySelectorAll('input[type=radio]')].filter(vis)
          .map(r => ({name: r.name, value: r.value})),
        headings: [...document.querySelectorAll('h1,h2,h3')].filter(vis)
          .map(h => (h.innerText||'').trim().slice(0,70)).filter(Boolean),
      };
    }""")
    print(f"\n--- {label} ---", flush=True)
    print(f"  url:      {page.url[:110]}", flush=True)
    print(f"  headings: {[mask(h) for h in data['headings']][:12]}", flush=True)
    print(f"  buttons:  {data['buttons'][:20]}", flush=True)
    for s in data["selects"]:
        print(f"  SELECT {s['name']!r}: {[mask(o) for o in s['options']][:14]}", flush=True)
    for r in data["radios"]:
        print(f"  RADIO  {r['name']!r} = {mask(r['value'])!r}", flush=True)
    for link in data["links"]:
        if any(w in link["text"].lower() for w in ("download", "export", "statement")):
            print(f"  LINK   {link['text']!r} -> {link['href'][:90]}", flush=True)
    return data


async def main() -> None:
    def say(message: str) -> None:
        print(f"  {message}", flush=True)

    try:
        async with session(on_step=say) as page:
            # "Sign off" renders before the account tiles do, so waiting on it
            # is not enough -- wait for an actual account link.
            await page.get_by_role("link", name=re.compile("VISA|Chequing")).first.wait_for(
                state="visible", timeout=30_000
            )
            home = await describe(page, "accounts home")
            await shot(page, "1-home")

            names = [
                link["text"] for link in home["links"]
                if any(w in link["text"].lower() for w in ("visa", "chequing", "savings"))
            ]
            print(f"\naccounts: {[mask(n) for n in names]}", flush=True)

            target = next((n for n in names if "visa" in n.lower()), None)
            if not target:
                print("!! no VISA account link", flush=True)
                return

            print(f"\nopening {mask(target)!r}", flush=True)
            await page.get_by_role("link", name=target).first.click()
            await page.wait_for_load_state("domcontentloaded")
            await page.get_by_role("button", name="Sign off").wait_for(timeout=20_000)
            await describe(page, "account detail")
            await shot(page, "2-account")

            # It is an <a>, not a <button> -- which is why a button-only search
            # found nothing here.
            link = page.get_by_role("link", name="Download Transactions").first
            if not await link.count():
                print("\n!! no Download Transactions link", flush=True)
                return

            print("\nopening Download Transactions", flush=True)
            await link.click()
            await page.wait_for_load_state("domcontentloaded")
            await page.wait_for_timeout(3000)
            await describe(page, "download page")
            await shot(page, "3-download")
    except LoginError as exc:
        print(f"!! {exc}", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
