"""Beeper Desktop API client.

The Beeper Desktop app runs a local HTTP server (default 127.0.0.1:23373) with an
OAuth 2.0 authorization-code + PKCE flow and dynamic client registration. We use it
read-only, to find the 2FA code CIBC texts us.

Discovered against Beeper Desktop 4.2.892 on 2026-07-31; see docs/beeper-api.md.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import threading
import urllib.parse
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import httpx
from platformdirs import user_config_dir

DEFAULT_BASE_URL = "http://127.0.0.1:23373"
REDIRECT_PORT = 8765
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"
CLIENT_NAME = "cctrack"


def token_path() -> Path:
    return Path(user_config_dir("cctrack")) / "beeper_token.json"


class BeeperError(RuntimeError):
    pass


class BeeperNotRunning(BeeperError):
    pass


class BeeperNotAuthorized(BeeperError):
    pass


@dataclass(frozen=True)
class Message:
    """One message from /v1/messages/search."""

    id: str
    chat_id: str
    account_id: str
    sender_id: str
    sender_name: str
    timestamp: str  # ISO 8601
    text: str

    @classmethod
    def from_api(cls, d: dict) -> Message:
        return cls(
            id=d.get("id", ""),
            chat_id=d.get("chatID", ""),
            account_id=d.get("accountID", ""),
            sender_id=d.get("senderID", ""),
            sender_name=d.get("senderName", ""),
            timestamp=d.get("timestamp", ""),
            text=d.get("text") or "",
        )


# --------------------------------------------------------------------------
# OAuth (authorization code + PKCE, public client, no secret)
# --------------------------------------------------------------------------


def _pkce_pair() -> tuple[str, str]:
    verifier = base64.urlsafe_b64encode(os.urandom(64)).rstrip(b"=").decode()
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


class _CallbackHandler(BaseHTTPRequestHandler):
    result: dict = {}

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return
        params = urllib.parse.parse_qs(parsed.query)
        type(self).result = {k: v[0] for k, v in params.items()}
        body = b"<html><body><h2>cctrack: authorized. you can close this tab.</h2></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        """Silence the default stderr access log."""


def authorize(base_url: str = DEFAULT_BASE_URL, timeout_s: int = 180) -> str:
    """Run the full OAuth dance and persist the access token. Returns the token.

    Beeper Desktop shows an in-app approval prompt; the user must click Allow.
    """
    with httpx.Client(base_url=base_url, timeout=10) as client:
        try:
            client.get("/v1/info")
        except httpx.ConnectError as exc:
            raise BeeperNotRunning(
                f"no Beeper Desktop API at {base_url} - is the app running?"
            ) from exc

        reg = client.post(
            "/oauth/register",
            json={
                "client_name": CLIENT_NAME,
                "redirect_uris": [REDIRECT_URI],
                "grant_types": ["authorization_code"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
                "scope": "read",
            },
        )
        reg.raise_for_status()
        client_id = reg.json()["client_id"]

        verifier, challenge = _pkce_pair()
        state = secrets.token_urlsafe(16)
        auth_url = f"{base_url}/oauth/authorize?" + urllib.parse.urlencode(
            {
                "client_id": client_id,
                "redirect_uri": REDIRECT_URI,
                "response_type": "code",
                "scope": "read",
                "state": state,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )

        _CallbackHandler.result = {}
        server = HTTPServer(("127.0.0.1", REDIRECT_PORT), _CallbackHandler)
        server.timeout = timeout_s
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()

        print("cctrack: approve the request in Beeper Desktop.")
        print(f"  if no window opens, visit:\n  {auth_url}")
        webbrowser.open(auth_url)

        thread.join(timeout=timeout_s)
        server.server_close()

        result = _CallbackHandler.result
        if not result:
            raise BeeperNotAuthorized("timed out waiting for approval")
        if "error" in result:
            raise BeeperNotAuthorized(f"authorization denied: {result['error']}")
        if result.get("state") != state:
            raise BeeperNotAuthorized("state mismatch - possible CSRF, aborting")

        tok = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": result["code"],
                "redirect_uri": REDIRECT_URI,
                "client_id": client_id,
                "code_verifier": verifier,
            },
        )
        tok.raise_for_status()
        payload = tok.json()

    path = token_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"client_id": client_id, **payload}, indent=2))
    path.chmod(0o600)
    return payload["access_token"]


def load_token() -> str:
    """Read the saved access token. $BEEPER_ACCESS_TOKEN wins if set."""
    env = os.environ.get("BEEPER_ACCESS_TOKEN")
    if env:
        return env
    path = token_path()
    if not path.exists():
        raise BeeperNotAuthorized("no saved token - run: cctrack beeper auth")
    return json.loads(path.read_text())["access_token"]


# --------------------------------------------------------------------------
# Read API
# --------------------------------------------------------------------------


class BeeperClient:
    def __init__(self, token: str | None = None, base_url: str = DEFAULT_BASE_URL) -> None:
        self._token = token or load_token()
        self._http = httpx.Client(
            base_url=base_url,
            timeout=15,
            headers={"Authorization": f"Bearer {self._token}"},
        )

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> BeeperClient:
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def _get(self, path: str, params: dict | None = None) -> dict:
        resp = self._http.get(path, params=params)
        if resp.status_code == 401:
            raise BeeperNotAuthorized("token rejected - run: cctrack beeper auth")
        resp.raise_for_status()
        return resp.json()

    def accounts(self) -> list[dict]:
        data = self._get("/v1/accounts")
        return data if isinstance(data, list) else data.get("items", [])

    def search_messages(
        self,
        query: str | None = None,
        *,
        date_after: str | None = None,
        sender: str | None = None,
        account_ids: list[str] | None = None,
        limit: int = 20,
    ) -> list[Message]:
        """Search local message history.

        `date_after` is an ISO 8601 datetime; Beeper filters server-side to messages
        strictly after it. That is what makes stale-OTP rejection cheap and reliable.
        """
        params: dict[str, object] = {"limit": limit}
        if query:
            params["query"] = query
        if date_after:
            params["dateAfter"] = date_after
        if sender:
            params["sender"] = sender
        if account_ids:
            params["accountIDs"] = account_ids
        data = self._get("/v1/messages/search", params=params)
        return [Message.from_api(m) for m in data.get("items", [])]
