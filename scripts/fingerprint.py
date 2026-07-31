"""What does our browser leak that a real one doesn't?

Dumps the automation-relevant fingerprint surface. No credentials, no sign-on,
so it is safe to run repeatedly. Compare `default` against `hardened` to see
what the launch flags actually change.
"""

from __future__ import annotations

import asyncio
import json
import tempfile
from pathlib import Path

from playwright.async_api import async_playwright

PROBE = """() => {
  const gl = (() => {
    try {
      const c = document.createElement('canvas').getContext('webgl');
      const dbg = c.getExtension('WEBGL_debug_renderer_info');
      return {
        vendor: c.getParameter(dbg.UNMASKED_VENDOR_WEBGL),
        renderer: c.getParameter(dbg.UNMASKED_RENDERER_WEBGL),
      };
    } catch (e) { return {error: String(e)}; }
  })();
  return {
    userAgent: navigator.userAgent,
    appVersion: navigator.appVersion,
    platform: navigator.platform,
    webdriver: navigator.webdriver,
    languages: navigator.languages,
    hardwareConcurrency: navigator.hardwareConcurrency,
    deviceMemory: navigator.deviceMemory,
    maxTouchPoints: navigator.maxTouchPoints,
    pluginCount: navigator.plugins.length,
    pluginNames: [...navigator.plugins].map(p => p.name),
    mimeTypeCount: navigator.mimeTypes.length,
    hasChromeObject: typeof window.chrome !== 'undefined',
    chromeKeys: window.chrome ? Object.keys(window.chrome) : [],
    hasChromeRuntime: !!(window.chrome && window.chrome.runtime),
    hasChromeLoadTimes: !!(window.chrome && window.chrome.loadTimes),
    permissionsQuery: typeof navigator.permissions?.query,
    vendor: navigator.vendor,
    productSub: navigator.productSub,
    // CDP / automation artefacts that scripts commonly probe for
    cdcProps: Object.keys(window).filter(k => /^[$_]{1,3}(cdc|selenium|webdriver|driver)/i.test(k)),
    docProps: Object.keys(document).filter(k => /(webdriver|selenium|driver)/i.test(k)),
    outerEqualsInner: window.outerWidth === window.innerWidth,
    outerHeight: window.outerHeight,
    innerHeight: window.innerHeight,
    screen: {w: screen.width, h: screen.height, availH: screen.availHeight,
             depth: screen.colorDepth},
    webgl: gl,
    notificationPermission: (typeof Notification !== 'undefined')
      ? Notification.permission : 'n/a',
  };
}"""

HARDENED_ARGS = [
    # The single loudest tell: without this Chromium advertises automation and
    # navigator.webdriver reports true.
    "--disable-blink-features=AutomationControlled",
]

STEALTH_JS = """
Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
"""


async def probe(label: str, *, harden: bool) -> dict:
    with tempfile.TemporaryDirectory(prefix=f"fp-{label}-") as tmp:
        async with async_playwright() as pw:
            kwargs: dict = {
                "user_data_dir": tmp,
                "headless": False,
                "viewport": None,  # let the real window size through
                "locale": "en-CA",
                "timezone_id": "America/Toronto",
            }
            if harden:
                kwargs["args"] = HARDENED_ARGS
                kwargs["ignore_default_args"] = ["--enable-automation"]

            ctx = await pw.chromium.launch_persistent_context(**kwargs)
            if harden:
                await ctx.add_init_script(STEALTH_JS)
            page = ctx.pages[0] if ctx.pages else await ctx.new_page()
            await page.goto("about:blank")
            data = await page.evaluate(PROBE)
            await ctx.close()
            return data


def report(label: str, data: dict) -> None:
    print(f"\n===== {label} =====")
    for key in (
        "userAgent", "webdriver", "vendor", "platform", "languages",
        "pluginCount", "mimeTypeCount", "hasChromeObject", "chromeKeys",
        "hasChromeRuntime", "hasChromeLoadTimes", "hardwareConcurrency",
        "deviceMemory", "cdcProps", "docProps", "outerEqualsInner",
        "notificationPermission", "webgl",
    ):
        print(f"  {key:24} {json.dumps(data.get(key))}")


async def probe_ours() -> dict:
    """Probe the context cctrack actually uses, not a synthetic one."""
    from cctrack.ingest.cibc_web import browser

    async with browser() as ctx:
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto("about:blank")
        return await page.evaluate(PROBE)


async def main() -> None:
    default = await probe("default", harden=False)
    ours = await probe_ours()

    report("PLAIN PLAYWRIGHT (what a naive script looks like)", default)
    report("CCTRACK (what we actually ship)", ours)

    print("\n===== what our hardening changes =====")
    for key in sorted(set(default) | set(ours)):
        if default.get(key) != ours.get(key):
            print(f"  {key}: {json.dumps(default.get(key))} -> {json.dumps(ours.get(key))}")

    print("\n===== automation tells remaining =====")
    tells = []
    if ours.get("webdriver"):
        tells.append(f"navigator.webdriver = {ours['webdriver']}")
    if not ours.get("hasChromeRuntime"):
        tells.append("window.chrome.runtime missing")
    if ours.get("cdcProps"):
        tells.append(f"CDP globals: {ours['cdcProps']}")
    if ours.get("docProps"):
        tells.append(f"document automation props: {ours['docProps']}")
    if ours.get("pluginCount", 0) == 0:
        tells.append("no plugins")
    if ours.get("deviceMemory") is None:
        tells.append("deviceMemory undefined")
    if len(ours.get("languages") or []) < 2:
        tells.append(f"languages too short: {ours.get('languages')}")
    print("  " + ("\n  ".join(tells) if tells else "none found"))

    out = Path(__file__).resolve().parent.parent / "downloads" / "fingerprint.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"plain": default, "cctrack": ours}, indent=2))
    print(f"\nwrote {out}")


if __name__ == "__main__":
    asyncio.run(main())
