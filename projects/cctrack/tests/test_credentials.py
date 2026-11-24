"""The CIBC login source: a file on bellona, Bitwarden on a laptop."""

from __future__ import annotations

import pytest

from cctrack.secrets import credentials
from cctrack.secrets.bitwarden import Credential
from cctrack.secrets.credentials import LoginFileError


def test_reads_username_and_password(tmp_path, monkeypatch):
    path = tmp_path / "login"
    path.write_text("username=4500********1234\npassword=hunter2\n")
    monkeypatch.setenv("CCTRACK_LOGIN_FILE", str(path))

    cred = credentials.get_login()
    assert cred.username == "4500********1234"
    assert cred.password == "hunter2"


def test_ignores_comments_and_blank_lines(tmp_path, monkeypatch):
    path = tmp_path / "login"
    path.write_text("# agenix\n\nusername=1234\npassword=pw\n")
    monkeypatch.setenv("CCTRACK_LOGIN_FILE", str(path))

    assert credentials.get_login().password == "pw"


def test_missing_password_names_the_keys_not_the_values(tmp_path, monkeypatch):
    path = tmp_path / "login"
    path.write_text("username=1234\n")
    monkeypatch.setenv("CCTRACK_LOGIN_FILE", str(path))

    with pytest.raises(LoginFileError) as err:
        credentials.get_login()
    assert "password=" in str(err.value)
    # keys, not values: the password must never reach a traceback
    assert "username" in str(err.value)


def test_a_line_without_equals_is_rejected(tmp_path, monkeypatch):
    path = tmp_path / "login"
    path.write_text("username=1234\npassword\n")
    monkeypatch.setenv("CCTRACK_LOGIN_FILE", str(path))

    with pytest.raises(LoginFileError):
        credentials.get_login()


def test_unreadable_file_says_so(tmp_path, monkeypatch):
    monkeypatch.setenv("CCTRACK_LOGIN_FILE", str(tmp_path / "nope"))

    with pytest.raises(LoginFileError) as err:
        credentials.get_login()
    assert "cannot read" in str(err.value)


def test_no_file_falls_back_to_bitwarden(monkeypatch):
    monkeypatch.delenv("CCTRACK_LOGIN_FILE", raising=False)
    sentinel = Credential(username="u", password="p")
    monkeypatch.setattr(credentials, "_from_bitwarden", lambda name=None: sentinel)

    assert credentials.get_login() is sentinel


def test_the_file_wins_when_it_is_set(tmp_path, monkeypatch):
    path = tmp_path / "login"
    path.write_text("username=file-user\npassword=file-pw\n")
    monkeypatch.setenv("CCTRACK_LOGIN_FILE", str(path))
    monkeypatch.setattr(
        credentials,
        "_from_bitwarden",
        lambda name=None: pytest.fail("bitwarden must not be consulted"),
    )

    assert credentials.get_login().username == "file-user"
