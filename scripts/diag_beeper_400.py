"""Find what actually makes /v1/messages/search return 400.

Observed: limit=2 succeeded, limit=25 failed, same dateAfter. Test the axes
separately instead of guessing.
"""

import httpx

from cctrack.secrets.beeper import DEFAULT_BASE_URL, load_token

H = {"Authorization": f"Bearer {load_token()}"}
T0 = "2026-07-31T20:16:53Z"


def probe(label: str, params: dict) -> None:
    r = httpx.get(
        f"{DEFAULT_BASE_URL}/v1/messages/search", params=params, headers=H, timeout=15
    )
    detail = ""
    if r.status_code != 200:
        try:
            detail = str(r.json())[:160]
        except Exception:
            detail = r.text[:160]
    else:
        detail = f"{len(r.json().get('items', []))} items"
    print(f"  {r.status_code}  {label:<34} {detail}")


print("=== vary limit, with dateAfter ===")
for n in (1, 2, 5, 10, 20, 21, 25, 50, 100):
    probe(f"limit={n}", {"limit": n, "dateAfter": T0})

print("\n=== vary limit, no dateAfter ===")
for n in (2, 25, 50):
    probe(f"limit={n} (no dateAfter)", {"limit": n})
