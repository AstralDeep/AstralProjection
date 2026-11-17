"""Verifies the Windows client opens one not-available window, makes no network request and holds no sign-in code.
Source guards read the client tree so a returning dev-token path or identity-server field fails here.
"""

import socket
from pathlib import Path

import pytest

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication, QLabel  # noqa: E402

from astral_client import app as appmod  # noqa: E402
from astral_client import not_available  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = ("dev-token", "keycloak", "oidc_login", "oauth2redirect", "protocol/openid-connect")


def test_main_shows_only_the_not_available_window_and_never_touches_the_network(monkeypatch):
    def refuse(*_args, **_kwargs):
        raise AssertionError("the not-available window made a network request")

    seen = {}

    def inspect_then_return(_app=None):
        seen["visible"] = [w for w in QApplication.topLevelWidgets() if w.isVisible()]
        seen["texts"] = [label.text() for w in seen["visible"] for label in w.findChildren(QLabel)]
        return 0

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(QApplication, "exec", inspect_then_return)
    assert appmod.main([]) == 0
    assert len(seen["visible"]) == 1
    assert isinstance(seen["visible"][0], not_available.NotAvailableWindow)
    assert seen["texts"] == ["Astral for Windows is not available yet. Use the Mac or iPhone app."]


def test_no_source_names_a_dev_token_or_an_identity_server_field():
    offenders = []
    files = [*(ROOT / "astral_client").glob("*.py"), *(ROOT / "deployment").glob("*.json"), ROOT / "main.py"]
    for path in files:
        text = path.read_text(encoding="utf-8").lower()
        offenders += [f"{path.name}: {word}" for word in FORBIDDEN if word in text]
    assert offenders == []


def test_stored_token_files_are_not_opened_by_the_entry_point():
    source = (ROOT / "astral_client" / "not_available.py").read_text(encoding="utf-8")
    assert "open(" not in source and "QSettings" not in source and "mesh" not in source
