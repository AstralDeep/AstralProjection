"""Verifies shared form option labels, saved keys, pending controls and theme authority.
Exercises renderer widgets without touching account settings or network services.
"""

import pytest

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QComboBox, QLabel, QPushButton, QWidget  # noqa: E402

from astral_client.renderer import RenderContext, render  # noqa: E402


def provider_form():
    return {"type": "param_picker", "fields": [
        {"name": "provider", "kind": "select", "default": "custom", "options": [
            {"value": "openai", "label": "OpenAI"},
            {"value": "custom", "label": "Custom OpenAI-compatible endpoint"},
        ]},
        {"name": "base_url", "label": "Endpoint", "default": "https://example.test/v1",
         "visible_when": {"field": "provider", "equals": "custom"}},
    ], "actions": [{"label": "Load models", "action": "chrome_llm_models"}]}


def test_labeled_select_keeps_saved_value_and_condition(qapp):
    emitted = []
    widget = render(provider_form(), RenderContext(lambda a, p: emitted.append((a, p))))
    combo = widget.findChild(QComboBox)
    assert combo.currentText() == "Custom OpenAI-compatible endpoint"
    assert combo.currentData() == "custom"
    endpoint = next(label for label in widget.findChildren(QLabel) if label.text() == "Endpoint")
    assert not endpoint.isHidden()
    widget.findChild(QPushButton).click()
    assert emitted == [("chrome_llm_models", {"fields": {"provider": "custom", "base_url": "https://example.test/v1"}})]


def test_pending_form_prevents_repeated_action(qapp):
    emitted = []
    widget = render(provider_form(), RenderContext(lambda a, p: emitted.append((a, p))))
    button = widget.findChild(QPushButton)
    button.click()
    button.click()
    assert len(emitted) == 1
    assert not button.isEnabled()
    assert any("Load models" in label.text() for label in widget.findChildren(QLabel))


def test_missing_action_has_explicit_unavailable_state(qapp):
    emitted = []
    widget = render({"type": "param_picker", "fields": []}, RenderContext(lambda a, p: emitted.append((a, p))))
    assert any("unavailable" in label.text().lower() for label in widget.findChildren(QLabel))
    for button in widget.findChildren(QPushButton):
        button.click()
    assert emitted == []


def test_saved_scalar_and_array_choices_survive_a_refreshed_catalog(qapp):
    emitted = []
    component = {"type": "param_picker", "fields": [
        {"name": "provider", "kind": "select", "default": "saved", "options": ["openai"]},
        {"name": "tools", "kind": "checklist", "default": ["old", "write"], "options": ["read"]},
    ], "submit_action": "save_settings"}
    widget = render(component, RenderContext(lambda a, p: emitted.append((a, p))))
    assert widget.findChild(QComboBox).currentText() == "saved"
    next(button for button in widget.findChildren(QPushButton) if button.property("form_action")).click()
    assert emitted == [("save_settings", {"fields": {"provider": "saved", "tools": ["old", "write"]}})]


def test_color_change_waits_for_server_theme_acceptance(qapp, monkeypatch):
    from astral_client import renderer

    emitted, applied = [], []
    monkeypatch.setattr(renderer, "_choose_color", lambda *_: "#123456")
    widget = render({"type": "color_picker", "color_key": "accent", "value": "#06B6D4"},
                    RenderContext(lambda a, p: emitted.append((a, p)), apply_theme=applied.append))
    widget.findChild(QPushButton).click()
    assert emitted == [("save_theme", {"theme": {"color_key": "accent", "color_value": "#123456"}})]
    assert applied == []
    assert any(label.text() == "#06B6D4" for label in widget.findChildren(QLabel))


@pytest.mark.parametrize("outcome", [False, "exception"])
def test_explicit_send_failure_keeps_values_and_allows_retry(qapp, outcome):
    attempts = []

    def emit(action, payload):
        attempts.append((action, payload))
        if outcome == "exception":
            raise OSError("Connection unavailable")
        return outcome

    widget = render(provider_form(), RenderContext(emit))
    button = next(control for control in widget.findChildren(QPushButton) if control.property("form_action"))
    button.click()
    assert button.isEnabled()
    assert widget.findChild(QComboBox).currentData() == "custom"
    assert any("Couldn't send" in label.text() for label in widget.findChildren(QLabel))
    button.click()
    assert len(attempts) == 2


def test_option_catalog_ignores_invalid_and_duplicate_values(qapp):
    component = provider_form()
    component["fields"][0]["options"] = [None, True, {}, "custom", {"value": "custom", "label": "Duplicate"}]
    widget = render(component, RenderContext(lambda *_: None))
    combo = widget.findChild(QComboBox)
    assert combo.count() == 1 and combo.currentData() == "custom"


def test_timeout_reload_restores_field_values_by_key_after_labels_change(qapp, native_root):
    from astral_client.app import SurfaceDialog

    root = native_root(QWidget)
    dialog = native_root(SurfaceDialog, root, lambda *_: True, lambda *_: None)
    component = provider_form()
    component["component_id"] = "llm-form"
    dialog.begin_load("llm", {})
    dialog.set_surface("Providers", [component])
    dialog._on_timeout()
    changed = provider_form()
    changed["component_id"] = "llm-form"
    changed["fields"][0]["options"][1]["label"] = "Renamed custom provider"
    changed["fields"][0]["default"] = "openai"
    dialog.set_surface("Providers", [changed])
    combo = dialog._inner.findChild(QComboBox)
    assert combo.currentData() == "custom" and combo.currentText() == "Renamed custom provider"


@pytest.mark.parametrize("chosen", [None, "", "#123", "invalid"])
def test_cancelled_or_invalid_color_never_emits(qapp, monkeypatch, chosen):
    from astral_client import renderer

    sent = []
    monkeypatch.setattr(renderer, "_choose_color", lambda *_: chosen)
    widget = render({"type": "color_picker", "color_key": "accent", "value": "#06B6D4"}, RenderContext(lambda *args: sent.append(args)))
    widget.findChild(QPushButton).click()
    assert sent == []
