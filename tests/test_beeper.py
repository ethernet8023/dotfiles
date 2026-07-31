"""Beeper client tests. No network: httpx.MockTransport stands in for the app.

Response shapes here are the ones the real Beeper Desktop 4.2.892 API returned
on 2026-07-31, not invented ones.
"""

from __future__ import annotations

import base64
import hashlib
import json

import httpx
import pytest

from cctrack.secrets import beeper
from cctrack.secrets.beeper import (
    BeeperClient,
    BeeperNotAuthorized,
    Message,
    _pkce_pair,
    load_token,
    token_path,
)


def client_with(handler) -> BeeperClient:
    c = BeeperClient(token="tok")
    c._http = httpx.Client(
        base_url=beeper.DEFAULT_BASE_URL,
        transport=httpx.MockTransport(handler),
        headers={"Authorization": "Bearer tok"},
    )
    return c


# --- PKCE ---------------------------------------------------------------


def test_pkce_challenge_is_s256_of_verifier():
    verifier, challenge = _pkce_pair()
    expect = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
    assert challenge == expect.rstrip(b"=").decode()


def test_pkce_is_unpadded_urlsafe():
    # A '+' or '=' in the challenge breaks the query string on some servers.
    for value in _pkce_pair():
        assert "=" not in value
        assert "+" not in value and "/" not in value


def test_pkce_pair_is_fresh_each_call():
    assert _pkce_pair()[0] != _pkce_pair()[0]


# --- token loading ------------------------------------------------------


def test_env_token_wins(monkeypatch):
    monkeypatch.setenv("BEEPER_ACCESS_TOKEN", "from-env")
    assert load_token() == "from-env"


def test_missing_token_is_actionable(monkeypatch, tmp_path):
    monkeypatch.delenv("BEEPER_ACCESS_TOKEN", raising=False)
    monkeypatch.setattr(beeper, "token_path", lambda: tmp_path / "nope.json")
    with pytest.raises(BeeperNotAuthorized, match="cctrack beeper auth"):
        load_token()


def test_token_read_from_file(monkeypatch, tmp_path):
    monkeypatch.delenv("BEEPER_ACCESS_TOKEN", raising=False)
    path = tmp_path / "beeper_token.json"
    path.write_text(json.dumps({"access_token": "from-file", "client_id": "x"}))
    monkeypatch.setattr(beeper, "token_path", lambda: path)
    assert load_token() == "from-file"


def test_token_path_is_not_inside_the_repo():
    # Credentials must never land somewhere git could pick them up.
    assert "credit-card-tracker" not in str(token_path())


# --- Message parsing ----------------------------------------------------


def test_message_from_api_maps_camelcase():
    m = Message.from_api({
        "id": "m1",
        "chatID": "c1",
        "accountID": "sms",
        "senderID": "242227",
        "senderName": "CIBC",
        "timestamp": "2026-07-31T14:02:00.000Z",
        "text": "Enter code: 123456 to authorize sign on to online banking",
    })
    assert (m.sender_id, m.account_id, m.chat_id) == ("242227", "sms", "c1")
    assert "123456" in m.text


def test_message_tolerates_null_text():
    # Attachment-only messages come back with text: null, not "".
    assert Message.from_api({"id": "m", "text": None}).text == ""


# --- search_messages ----------------------------------------------------


def test_search_passes_date_after_to_server():
    """Stale-OTP rejection leans on this param actually reaching Beeper."""
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(dict(request.url.params))
        return httpx.Response(200, json={"items": []})

    client_with(handler).search_messages(
        "CIBC", date_after="2026-07-31T14:00:00Z", sender="242227", limit=5,
    )
    assert seen["dateAfter"] == "2026-07-31T14:00:00Z"
    assert seen["sender"] == "242227"
    assert seen["limit"] == "5"


def test_search_omits_unset_filters():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(dict(request.url.params))
        return httpx.Response(200, json={"items": []})

    client_with(handler).search_messages()
    assert "dateAfter" not in seen and "sender" not in seen and "query" not in seen


def test_search_returns_parsed_messages():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"items": [
            {"id": "m1", "senderID": "242227", "text": "Enter code: 123456 to authorize"},
        ]})

    (msg,) = client_with(handler).search_messages("CIBC")
    assert isinstance(msg, Message)
    assert msg.sender_id == "242227"


def test_401_raises_actionable_error():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": "unauthorized"})

    with pytest.raises(BeeperNotAuthorized, match="cctrack beeper auth"):
        client_with(handler).accounts()


def test_500_is_not_swallowed():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="boom")

    with pytest.raises(httpx.HTTPStatusError):
        client_with(handler).accounts()


def test_accounts_accepts_bare_list_or_items_envelope():
    for payload in ([{"accountID": "sms"}], {"items": [{"accountID": "sms"}]}):
        def handler(_request: httpx.Request, p=payload) -> httpx.Response:
            return httpx.Response(200, json=p)

        assert client_with(handler).accounts() == [{"accountID": "sms"}]


def test_context_manager_closes_http():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"items": []})

    with client_with(handler) as c:
        assert c.search_messages() == []
    assert c._http.is_closed
