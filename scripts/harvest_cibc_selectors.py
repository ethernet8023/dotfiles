"""One-off: dump the real CIBC sign-on form structure so we stop guessing selectors.

Must run headed under a compositor -- see scripts/harvest_cibc_selectors.sh.
CIBC's Akamai edge drops headless chromium during the h2 handshake.

Writes docs/cibc-selectors.md and downloads/cibc-signon.png
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from playwright.async_api import async_playwright

SIGNON_URL = "https://www.cibconline.cibc.com/ebm-resources/public/client/web/index.html#/signon"
ROOT = Path(__file__).resolve().parent.parent

DUMP_JS = """() => {
  const vis = el => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const out = {inputs: [], buttons: [], forms: [], labels: []};
  for (const el of document.querySelectorAll('input')) {
    if (!vis(el)) continue;
    out.inputs.push({
      type: el.type, id: el.id, name: el.name,
      placeholder: el.placeholder,
      ariaLabel: el.getAttribute('aria-label'),
      autocomplete: el.getAttribute('autocomplete'),
      maxlength: el.getAttribute('maxlength'),
      testid: el.getAttribute('data-testid') || el.getAttribute('data-test'),
    });
  }
  for (const el of document.querySelectorAll('button, input[type=submit], a[role=button]')) {
    if (!vis(el)) continue;
    out.buttons.push({
      tag: el.tagName, id: el.id, name: el.name,
      text: (el.innerText || el.value || '').trim().slice(0, 60),
      ariaLabel: el.getAttribute('aria-label'),
      testid: el.getAttribute('data-testid') || el.getAttribute('data-test'),
    });
  }
  for (const f of document.querySelectorAll('form')) {
    out.forms.push({id: f.id, name: f.name, action: f.action});
  }
  for (const l of document.querySelectorAll('label')) {
    if (!vis(l)) continue;
    out.labels.push({for: l.htmlFor, text: (l.innerText || '').trim().slice(0, 50)});
  }
  return out;
}"""


async def main() -> None:
    out_dir = ROOT / "downloads"
    out_dir.mkdir(exist_ok=True)

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=False)
        ctx = await browser.new_context(
            viewport={"width": 1400, "height": 1000},
            locale="en-CA",
            timezone_id="America/Toronto",
        )
        page = await ctx.new_page()
        await page.goto(SIGNON_URL, wait_until="domcontentloaded", timeout=60_000)
        # Angular SPA: the form is rendered client-side after the shell loads.
        await page.wait_for_selector("input", timeout=30_000)
        await page.wait_for_timeout(3000)

        print(f"final url: {page.url}")
        print(f"title:     {await page.title()}")
        await page.screenshot(path=str(out_dir / "cibc-signon.png"), full_page=True)

        fields = await page.evaluate(DUMP_JS)

        lines = ["# CIBC sign-on selectors", ""]
        lines.append(f"Harvested from `{page.url}`")
        lines.append("")
        lines.append("Captured with a headed chromium under `cage` "
                     "(`WLR_BACKENDS=headless`). Headless chromium never reaches "
                     "this page: Akamai drops the h2 handshake.")
        lines.append("")
        for section in ("inputs", "buttons", "forms", "labels"):
            lines.append(f"## {section.title()}")
            for item in fields[section]:
                print(section.upper(), item)
                lines.append(f"- `{item}`")
            lines.append("")

        (ROOT / "docs").mkdir(exist_ok=True)
        (ROOT / "docs" / "cibc-selectors.md").write_text("\n".join(lines) + "\n")
        print(f"\nwrote docs/cibc-selectors.md ({len(fields['inputs'])} inputs, "
              f"{len(fields['buttons'])} buttons)")
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
