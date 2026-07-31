"""Verify the OTP that the login probe just triggered can be read and parsed."""

import re
import sys

from cctrack.secrets.beeper import BeeperClient

T0 = sys.argv[1] if len(sys.argv) > 1 else "2026-07-31T20:16:53Z"
SIGNON_MARKER = "to authorize sign on"

with BeeperClient() as c:
    msgs = c.search_messages(date_after=T0, limit=25)
    print(f"{len(msgs)} message(s) after {T0}")
    for m in msgs:
        text = m.text or ""
        redacted = re.sub(r"\d", "N", text)
        code = re.search(r"Enter code:\s*(\d{6})\b", text)
        print(f"  senderName={m.sender_name!r} senderID={m.sender_id!r}")
        print(f"  account={m.account_id!r} ts={m.timestamp}")
        print(f"  text={redacted[:130]!r}")
        print(f"  -> code extracted: {code is not None}")
        print(f"  -> is sign-on (not purchase auth): {SIGNON_MARKER in text}")
