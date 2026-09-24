"""Tests for astral_client/renderer.py: declarative visible_when on ParamPicker fields —
initial and reactive visibility against a controller select, and that hidden fields
still submit their values.
"""

from __future__ import annotations

import pytest

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QComboBox, QLineEdit, QPlainTextEdit  # noqa: E402

from astral_client.renderer import RenderContext, render  # noqa: E402

FORM = {
    "type": "param_picker",
    "title": "Add a machine",
    "submit_label": "Add & probe",
    "submit_action": "chrome_machine_add",
    "fields": [
        {"name": "cred_type", "label": "Credential type", "kind": "select",
         "options": ["ssh_key", "password"], "default": "ssh_key"},
        {"name": "private_key", "label": "Private key", "kind": "textarea",
         "visible_when": {"field": "cred_type", "equals": "ssh_key",
                          "default": "ssh_key"}},
        {"name": "passphrase", "label": "Key passphrase", "kind": "password",
         "visible_when": {"field": "cred_type", "equals": "ssh_key",
                          "default": "ssh_key"}},
        {"name": "password", "label": "Password", "kind": "password",
         "visible_when": {"field": "cred_type", "equals": "password",
                          "default": "ssh_key"}},
    ],
}


def _widgets(w):
    combo = w.findChildren(QComboBox)[0]
    textarea = w.findChildren(QPlainTextEdit)[0]
    secures = [e for e in w.findChildren(QLineEdit)
               if e.echoMode() == QLineEdit.EchoMode.Password]
    assert len(secures) == 2, "expected passphrase + password secure fields"
    return combo, textarea, secures


def test_initial_visibility_follows_controller_default(qapp):
    w = render(FORM, RenderContext(emit=lambda a, p: None))
    combo, textarea, secures = _widgets(w)
    assert combo.currentText() == "ssh_key"
    assert not textarea.isHidden(), "ssh_key fields start visible"
    hidden = [e.isHidden() for e in secures]
    assert hidden.count(True) == 1, "exactly the password field starts hidden"


def test_visibility_reacts_to_controller_change_both_ways(qapp):
    w = render(FORM, RenderContext(emit=lambda a, p: None))
    combo, textarea, secures = _widgets(w)
    combo.setCurrentText("password")
    assert textarea.isHidden(), "key textarea hides for password auth"
    assert [e.isHidden() for e in secures].count(False) == 1
    combo.setCurrentText("ssh_key")
    assert not textarea.isHidden(), "flipping back restores the key fields"
    assert [e.isHidden() for e in secures].count(True) == 1


def test_hidden_fields_still_submit_their_values(qapp):
    from PySide6.QtWidgets import QPushButton

    seen = []
    w = render(FORM, RenderContext(emit=lambda a, p: seen.append((a, p))))
    combo, textarea, _ = _widgets(w)
    textarea.setPlainText("KEYDATA")
    combo.setCurrentText("password")
    submit = next(b for b in w.findChildren(QPushButton)
                  if "probe" in b.text())
    submit.click()
    assert seen, "submit must emit the chrome action"
    action, payload = seen[-1]
    assert action == "chrome_machine_add"
    fields = payload.get("fields", payload)
    assert fields.get("private_key") == "KEYDATA", \
        "hidden fields keep submitting (server picks by cred_type)"


def test_payload_without_visible_when_renders_everything(qapp):
    legacy = {**FORM, "fields": [
        {k: v for k, v in f.items() if k != "visible_when"}
        for f in FORM["fields"]]}
    w = render(legacy, RenderContext(emit=lambda a, p: None))
    _, textarea, secures = _widgets(w)
    assert not textarea.isHidden()
    assert all(not e.isHidden() for e in secures)
