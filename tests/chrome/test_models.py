from __future__ import annotations

from types import MappingProxyType

import pytest

from astralprojection.models import (
    ChromeViewModel,
    ComponentView,
    DegradationView,
    DeviceCapabilities,
    FrameView,
    LayoutView,
    ThemeView,
    thaw_json,
)


def test_component_and_frame_are_immutable_detached_json_values() -> None:
    source = {"label": "Open", "payload": {"ids": [1, 2]}}
    component = ComponentView("button", source)
    source["label"] = "Changed"
    source["payload"]["ids"].append(3)  # type: ignore[index,union-attr]
    assert component.to_dict() == {
        "type": "button",
        "label": "Open",
        "payload": {"ids": [1, 2]},
    }
    frame = FrameView("chrome_surface", {"surface": "audit", "items": [component.to_dict()]})
    encoded = frame.to_dict()
    assert encoded["type"] == "chrome_surface"
    assert encoded["schema_version"] == 1
    encoded["surface"] = "mutated"
    assert frame.to_dict()["surface"] == "audit"


@pytest.mark.parametrize(
    ("factory", "message"),
    [
        (lambda: ComponentView("Bad Type", {}), "lowercase protocol token"),
        (lambda: ComponentView("text", {"type": "button"}), "must not override"),
        (lambda: ComponentView("text", {1: "bad"}), "non-string key"),
        (lambda: ComponentView("text", {"value": object()}), "unsupported value type"),
        (lambda: ComponentView("text", {"value": float("inf")}), "non-finite"),
        (lambda: FrameView("bad type", {}), "lowercase protocol token"),
        (lambda: FrameView("event", {}, 0), "must be positive"),
        (lambda: FrameView("event", {"type": "other"}), "must not override"),
        (lambda: FrameView("event", {"schema_version": 2}), "must not override"),
    ],
)
def test_invalid_component_and_frame_values_fail_closed(factory, message: str) -> None:
    with pytest.raises((TypeError, ValueError), match=message):
        factory()


def test_theme_layout_and_degradation_serialization() -> None:
    theme = ThemeView(
        "Ocean",
        {"Primary": "#AABBCC"},
        color_scheme="LIGHT",
        contrast="HIGH",
    )
    assert theme.to_dict() == {
        "name": "ocean",
        "colors": {"primary": "#aabbcc"},
        "color_scheme": "light",
        "contrast": "high",
    }
    layout = LayoutView("WIDE", 3, "COMPACT", ("main", "rail"))
    assert layout.to_dict() == {
        "mode": "wide",
        "columns": 3,
        "density": "compact",
        "areas": ["main", "rail"],
    }
    degradation = DegradationView(
        True, "Forms unavailable", ("tabs", "param_picker", "tabs"), "text"
    )
    assert degradation.to_dict() == {
        "active": True,
        "reason": "Forms unavailable",
        "unsupported_components": ["param_picker", "tabs"],
        "fallback": "text",
    }


@pytest.mark.parametrize(
    "factory",
    [
        lambda: ThemeView(color_scheme="sepia"),
        lambda: ThemeView(contrast="extreme"),
        lambda: ThemeView(colors={"primary": "red"}),
        lambda: ThemeView(colors={"Bad Key": "#000000"}),
        lambda: LayoutView(mode="diagonal"),
        lambda: LayoutView(density="dense"),
        lambda: LayoutView(columns=0),
        lambda: LayoutView(columns=5),
        lambda: LayoutView(areas=("main", "main")),
        lambda: DegradationView(True),
        lambda: DegradationView(fallback="blank"),
    ],
)
def test_invalid_theme_layout_and_degradation_fail_closed(factory) -> None:
    with pytest.raises(ValueError):
        factory()


def test_device_capabilities_and_view_adaptation() -> None:
    text_component = ComponentView("text", {"content": "hello"})
    form_component = ComponentView("param_picker", {"fields": []})
    view = ChromeViewModel(
        "Preferences",
        "Preferences",
        (text_component, form_component),
        layout=LayoutView("wide", 3),
    )
    full = DeviceCapabilities("Desktop", frozenset({"text", "param_picker"}))
    assert full.supports("text") is True
    assert view.for_device(full) is view
    limited = DeviceCapabilities(
        "Watch",
        frozenset({"text", "param_picker", "alert"}),
        supports_forms=False,
        supports_html=False,
        supports_local_actions=False,
        max_columns=1,
    )
    assert limited.supports("param_picker") is False
    assert limited.to_dict() == {
        "profile": "watch",
        "component_types": ["alert", "param_picker", "text"],
        "supports_forms": False,
        "supports_html": False,
        "supports_local_actions": False,
        "max_columns": 1,
    }
    adapted = view.for_device(limited)
    assert adapted.layout.columns == 1
    assert adapted.degradation.active is True
    assert adapted.degradation.unsupported_components == ("param_picker",)
    assert adapted.components[1].component_type == "alert"
    assert "watch client" in adapted.components[1].to_dict()["message"]


def test_layout_only_adaptation_and_chrome_frame() -> None:
    view = ChromeViewModel(
        "workspace",
        "Workspace",
        (ComponentView("text", {"content": "ready"}),),
        layout=LayoutView("wide", 4),
    )
    limited = DeviceCapabilities("tablet", frozenset({"text"}), max_columns=2)
    adapted = view.for_device(limited)
    assert adapted.layout.columns == 2
    assert adapted.degradation.unsupported_components == ()
    payload = adapted.to_dict()
    assert payload["surface"] == "workspace"
    assert payload["components"] == [{"type": "text", "content": "ready"}]
    assert adapted.to_frame().to_dict()["type"] == "chrome_surface"


def test_model_validation_and_thaw_helpers() -> None:
    with pytest.raises(ValueError, match="title"):
        ChromeViewModel("audit", " ", ())
    with pytest.raises(TypeError, match="ComponentView"):
        ChromeViewModel("audit", "Audit", ({"type": "text"},))  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="max_columns"):
        DeviceCapabilities("watch", frozenset(), max_columns=0)
    with pytest.raises(ValueError, match="protocol token"):
        DeviceCapabilities("bad profile", frozenset())
    frozen = MappingProxyType({"nested": (1, MappingProxyType({"ok": True}))})
    assert thaw_json(frozen) == {"nested": [1, {"ok": True}]}
