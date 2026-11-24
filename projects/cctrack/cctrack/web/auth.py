"""Local API token.

The web UI drives real bank logins, so its API is not open to anything that
can reach the port. Two guards, both cheap:

  - a bearer token, stored 0600 outside the repo
  - a Host header check (see cctrack/web/app.py)

The token matters more than it looks. Any web page your browser visits can
POST to 127.0.0.1, and DNS rebinding lets a remote site do so with its own
origin. An unauthenticated POST /api/sync would let a random page trigger a
login to your bank.
"""

from __future__ import annotations

import hmac
import os
import secrets
from pathlib import Path

from cctrack.config import data_dir

TOKEN_FILE = "api-token"


def token_path() -> Path:
    return data_dir() / TOKEN_FILE


def load_or_create_token() -> str:
    """Read the API token, generating one on first use."""
    env = os.environ.get("CCTRACK_API_TOKEN")
    if env:
        return env

    path = token_path()
    if path.exists():
        return path.read_text().strip()

    token = secrets.token_urlsafe(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(token)
    path.chmod(0o600)
    return token


def token_matches(supplied: str | None, expected: str) -> bool:
    """Constant-time comparison, so a wrong token leaks nothing by timing."""
    if not supplied:
        return False
    if supplied.lower().startswith("bearer "):
        supplied = supplied[7:].strip()
    return hmac.compare_digest(supplied, expected)
