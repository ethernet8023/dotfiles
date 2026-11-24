"""Read CIBC credentials out of the Bitwarden CLI.

Credentials are held in memory only. Nothing here writes a secret to disk, and
Credential is built so a stray log line or traceback cannot print the password.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field

DEFAULT_ITEM = "17312ca2-4632-4fb2-b1bb-af400111ce0d"
"""UUID of the user's personal `cibc.com` login.

A UUID, not a name, on purpose: `bw get item cibc.com` does a substring match and
the vault holds four items containing "cibc" (`cibc business`, `cibc.com`,
`secure-email.cibc.com`, `www.cibconline.cibc.com`), so a name lookup fails as
ambiguous. A UUID also cannot silently start resolving to a different account if
an item is renamed. Override with CCTRACK_BW_ITEM.
"""


class BitwardenError(RuntimeError):
    pass


class BitwardenLocked(BitwardenError):
    pass


class ItemNotFound(BitwardenError):
    pass


class AmbiguousItem(BitwardenError):
    """The search term matched several vault items. Use a UUID instead."""


@dataclass(frozen=True)
class Credential:
    """A username/password pair that refuses to print its own password."""

    username: str
    password: str = field(repr=False)

    def __repr__(self) -> str:
        return f"Credential(username={self.username!r}, password=***)"

    __str__ = __repr__


def item_name() -> str:
    return os.environ.get("CCTRACK_BW_ITEM") or DEFAULT_ITEM


def _run_bw(args: list[str], session: str) -> str:
    """Run `bw` with the session passed through the environment.

    The session key never goes on the argv: /proc/<pid>/cmdline is world-readable,
    so an argv secret is visible to every process on the box for the call's lifetime.
    """
    exe = shutil.which("bw")
    if exe is None:
        raise BitwardenError("bw not found on PATH - run inside `nix develop`")

    # Fixed executable, no shell, args are ours -- not attacker-controlled.
    proc = subprocess.run(
        [exe, *args],
        capture_output=True,
        text=True,
        env={**os.environ, "BW_SESSION": session},
        check=False,
        timeout=60,
    )
    if proc.returncode != 0:
        err = (proc.stderr or "").strip()
        low = err.lower()
        if "locked" in low or "session key" in low or "not logged in" in low:
            raise BitwardenLocked(
                "bitwarden is locked - run: export BW_SESSION=$(bw unlock --raw)"
            )
        if "more than one result" in low:
            raise AmbiguousItem(
                f"{args[-2]!r} matched several vault items - use the item UUID "
                "(bw list items --search <term> | jq -r '.[] | \"\\(.id) \\(.name)\"')"
            )
        if "not found" in low:
            raise ItemNotFound(err)
        # Truncated: bw echoes context on failure and we do not want a secret in a log.
        raise BitwardenError(f"bw {args[0]} failed: {err[:200]}")
    return proc.stdout


def get_login(name: str | None = None) -> Credential:
    """Fetch one login item. Raises rather than returning a half-empty Credential."""
    session = os.environ.get("BW_SESSION")
    if not session:
        raise BitwardenLocked("BW_SESSION is unset - run: export BW_SESSION=$(bw unlock --raw)")

    name = name or item_name()
    raw = _run_bw(["get", "item", name, "--raw"], session)

    try:
        item = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BitwardenError(f"bw returned non-JSON for {name!r}") from exc

    login = item.get("login") or {}
    username, password = login.get("username"), login.get("password")
    if not username or not password:
        raise BitwardenError(
            f"item {name!r} is missing a username or password "
            f"(has_username={bool(username)}, has_password={bool(password)})"
        )
    return Credential(username=username, password=password)
