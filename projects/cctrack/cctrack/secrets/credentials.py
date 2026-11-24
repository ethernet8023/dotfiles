"""Where the CIBC login comes from.

Two sources, checked in order:

  * ``CCTRACK_LOGIN_FILE`` -- a ``username=`` / ``password=`` file. On bellona
    that path is agenix's: systemd reads it, and the password never enters the
    nix store, the process argv, or a log line. The format is the same
    ``KEY=value`` shape the rest of that box's secrets already use.
  * the Bitwarden CLI, which is what a laptop dev run uses.

The file wins when it is set, so a host pins its source instead of inheriting
whatever ``bw`` happens to be unlocked as.
"""

from __future__ import annotations

import os
from pathlib import Path

from cctrack.secrets.bitwarden import BitwardenError, Credential, get_login as _from_bitwarden


class LoginFileError(RuntimeError):
    pass


def login_file() -> Path | None:
    raw = os.environ.get("CCTRACK_LOGIN_FILE")
    return Path(raw) if raw else None


def _read(path: Path) -> Credential:
    try:
        text = path.read_text()
    except OSError as exc:
        raise LoginFileError(f"cannot read {path}: {exc}") from exc

    fields: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise LoginFileError(f"{path}: line without '=': {key!r}")
        fields[key.strip().lower()] = value.strip()

    username, password = fields.get("username"), fields.get("password")
    if not username or not password:
        # Name the keys, never the values: a half-empty file is the usual
        # mistake and the password must not end up in a traceback.
        raise LoginFileError(
            f"{path}: needs username= and password= "
            f"(saw {sorted(fields)})"
        )
    return Credential(username=username, password=password)


def get_login(name: str | None = None) -> Credential:
    """The CIBC card number and password, from whichever source is configured."""
    path = login_file()
    if path is not None:
        return _read(path)
    try:
        return _from_bitwarden(name)
    except BitwardenError:
        # Let the caller see why bw failed, but say the file was an option too.
        raise
