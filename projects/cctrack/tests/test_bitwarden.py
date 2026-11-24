"""Bitwarden reader tests. subprocess is mocked; no real vault is touched."""

from __future__ import annotations

import json
import subprocess
import traceback

import pytest

from cctrack.secrets import bitwarden
from cctrack.secrets.bitwarden import (
    AmbiguousItem,
    BitwardenError,
    BitwardenLocked,
    Credential,
    ItemNotFound,
    get_login,
    item_name,
)

SECRET = "correct-horse-battery-staple"
ITEM = {"login": {"username": "4506000000001883", "password": SECRET}}


@pytest.fixture(autouse=True)
def _bw_on_path(monkeypatch):
    monkeypatch.setattr(bitwarden.shutil, "which", lambda _: "/usr/bin/bw")
    monkeypatch.setenv("BW_SESSION", "session-key")
    monkeypatch.delenv("CCTRACK_BW_ITEM", raising=False)


def fake_run(stdout="", stderr="", returncode=0, capture=None):
    def _run(args, **kwargs):
        if capture is not None:
            capture["args"] = args
            capture["env"] = kwargs.get("env", {})
        return subprocess.CompletedProcess(args, returncode, stdout, stderr)
    return _run


# --- leak prevention: the whole point of this module ---------------------


def test_repr_does_not_leak_password():
    c = Credential("me@example.com", "hunter2")
    assert "hunter2" not in repr(c)
    assert "hunter2" not in str(c)
    assert "hunter2" not in f"{c}"


def test_password_absent_from_traceback():
    """A raised error carrying a Credential must not print the password."""
    c = Credential("me@example.com", "hunter2")
    try:
        raise ValueError(f"boom with {c!r}")
    except ValueError:
        assert "hunter2" not in traceback.format_exc()


def test_password_still_readable_by_callers():
    # Masking is for display only; the scraper still needs the real value.
    assert Credential("u", "hunter2").password == "hunter2"


# --- session handling ----------------------------------------------------


def test_missing_session_is_actionable(monkeypatch):
    monkeypatch.delenv("BW_SESSION", raising=False)
    with pytest.raises(BitwardenLocked, match="bw unlock --raw"):
        get_login("cibc.com")


def test_session_goes_through_env_not_argv(monkeypatch):
    """argv is world-readable in /proc/<pid>/cmdline, so the key must not be there."""
    seen: dict = {}
    monkeypatch.setattr(subprocess, "run", fake_run(json.dumps(ITEM), capture=seen))
    get_login("cibc.com")
    assert "session-key" not in " ".join(seen["args"])
    assert seen["env"]["BW_SESSION"] == "session-key"


def test_locked_vault_detected_from_stderr(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        fake_run(stderr="Vault is locked.", returncode=1),
    )
    with pytest.raises(BitwardenLocked, match="bw unlock --raw"):
        get_login("cibc.com")


# --- item resolution -----------------------------------------------------


def test_defaults_to_personal_cibc_item(monkeypatch):
    seen: dict = {}
    monkeypatch.setattr(subprocess, "run", fake_run(json.dumps(ITEM), capture=seen))
    get_login()
    # A UUID, not a name: `bw get item cibc.com` substring-matches four vault
    # items and fails as ambiguous.
    assert "17312ca2-4632-4fb2-b1bb-af400111ce0d" in seen["args"]


def test_ambiguous_match_names_the_fix(monkeypatch):
    """Regression: `bw get item cibc.com` matches four items and must not be silent."""
    monkeypatch.setattr(
        subprocess, "run",
        fake_run(
            stderr="More than one result was found. Try getting a specific object by `id`",
            returncode=1,
        ),
    )
    with pytest.raises(AmbiguousItem, match="use the item UUID"):
        get_login("cibc.com")


def test_item_override_via_env(monkeypatch):
    monkeypatch.setenv("CCTRACK_BW_ITEM", "cibc business")
    assert item_name() == "cibc business"


def test_explicit_name_beats_env(monkeypatch):
    monkeypatch.setenv("CCTRACK_BW_ITEM", "cibc business")
    seen: dict = {}
    monkeypatch.setattr(subprocess, "run", fake_run(json.dumps(ITEM), capture=seen))
    get_login("cibc.com")
    assert "cibc.com" in seen["args"]


def test_missing_item_raises_not_found(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        fake_run(stderr="Not found.", returncode=1),
    )
    with pytest.raises(ItemNotFound):
        get_login("nope")


# --- parsing -------------------------------------------------------------


def test_parses_username_and_password(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run(json.dumps(ITEM)))
    cred = get_login("cibc.com")
    assert cred.username == "4506000000001883"
    assert cred.password == SECRET


def test_rejects_item_with_no_password(monkeypatch):
    """Better to fail loudly than hand the scraper an empty password."""
    payload = {"login": {"username": "u", "password": ""}}
    monkeypatch.setattr(subprocess, "run", fake_run(json.dumps(payload)))
    with pytest.raises(BitwardenError, match="has_password=False"):
        get_login("cibc.com")


def test_rejects_secure_note_with_no_login_block(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run(json.dumps({"notes": "hi"})))
    with pytest.raises(BitwardenError, match="missing a username or password"):
        get_login("cibc.com")


def test_non_json_output_is_reported(monkeypatch):
    monkeypatch.setattr(subprocess, "run", fake_run("not json at all"))
    with pytest.raises(BitwardenError, match="non-JSON"):
        get_login("cibc.com")


def test_missing_bw_binary_points_at_the_devshell(monkeypatch):
    monkeypatch.setattr(bitwarden.shutil, "which", lambda _: None)
    with pytest.raises(BitwardenError, match="nix develop"):
        get_login("cibc.com")


def test_bw_failure_output_is_truncated(monkeypatch):
    """bw echoes context on failure; a huge stderr must not land in a log intact."""
    monkeypatch.setattr(
        subprocess, "run",
        fake_run(stderr="x" * 5000, returncode=1),
    )
    with pytest.raises(BitwardenError) as exc:
        get_login("cibc.com")
    assert len(str(exc.value)) < 300
