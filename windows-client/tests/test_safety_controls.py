"""Exercises the shared owner stop and resume buttons in the actual Qt renderer.
The generic transport retains current owner and connection fencing.
"""

import json
from pathlib import Path

from PySide6.QtWidgets import QPushButton

from astral_client.renderer import RenderContext, render


ROOT = Path(__file__).resolve().parents[2]


def test_owner_safety_buttons_preserve_exact_offered_revision(qapp):
    fixture = json.loads((ROOT / "contracts/fixtures/safety/owner_stop.json").read_text(encoding="utf-8"))
    emitted = []
    widgets = []
    for component in fixture["buttons"]:
        widget = render(component, RenderContext(lambda action, payload: emitted.append((action, payload))))
        widgets.append(widget)
        button = widget if isinstance(widget, QPushButton) else widget.findChild(QPushButton)
        assert button.text() == component["label"]
        button.click()
    assert emitted == [(button["action"], button["payload"]) for button in fixture["buttons"]]
