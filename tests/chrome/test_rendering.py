from __future__ import annotations

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome._components import (
    _render_component,
    alert,
    badge,
    build_view,
    bullet_list,
    button,
    card,
    clean_text,
    container,
    denied_view,
    field,
    form,
    key_value,
    text,
    unavailable_view,
)
from astralprojection.models import ComponentView, DegradationView, LayoutView, ThemeView


def test_safe_html_renderer_covers_shared_component_vocabulary() -> None:
    picker = form(
        [
            field("plain", "Plain", default='"><script>alert(1)</script>'),
            field("secret", "Secret", "password", default="must-not-render"),
            field("notes", "Notes", "textarea", default="line 1\nline 2", help_text="Help"),
            field("count", "Count", "number", default=4),
            field("enabled", "Enabled", "boolean", default=True),
            field("choice", "Choice", "select", default="b", options=("a", "b")),
            field("many", "Many", "checklist", options=("one", "two")),
            field(
                "conditional",
                "Conditional",
                visible_when={"field": "enabled", "equals": True, "default": True},
            ),
        ],
        title="Settings",
        description="Safe form",
        submit_action="chrome_profile_save",
        submit_label="Save now",
        submit_payload={"scope": "profile"},
    )
    view = build_view(
        "demo",
        "Demo <surface>",
        [
            text("Heading", "h1"),
            text("Subheading", "h2"),
            text("Section", "h3"),
            text("Caption", "caption"),
            text("Body"),
            alert("Informational"),
            alert("Careful", "warning", "Warning"),
            badge("Ready", "success"),
            button(
                "Open <now>",
                "chrome_open",
                {"surface": 'x" onmouseover="evil'},
                disabled=True,
            ),
            card(
                "Facts <unsafe>",
                [
                    key_value([("Label", "<script>bad</script>")], title="Details"),
                    key_value([("Other", "value")]),
                    bullet_list(["one", "<two>"], ordered=True),
                    bullet_list(["plain"]),
                    container([text("Nested")], direction="row"),
                ],
            ),
            picker,
            ComponentView("tabs", {"tabs": []}),
        ],
        theme=ThemeView("ocean"),
        layout=LayoutView("wide", 2),
    )
    html = render_html(view)
    assert 'aria-labelledby="chrome-demo-title"' in html
    assert 'data-theme="ocean"' in html
    assert 'data-layout="wide"' in html
    assert "Demo &lt;surface&gt;" in html
    assert "<script>" not in html
    assert "&lt;script&gt;bad&lt;/script&gt;" in html
    assert "must-not-render" not in html
    assert 'type="password" name="secret"' in html
    assert 'role="alert"' in html
    assert 'role="status"' in html
    assert 'aria-disabled="true"' in html
    assert 'data-ui-collect="true"' in html
    assert "The tabs component is not available" in html
    assert "<ol>" in html and "<ul>" in html and "<dl>" in html


def test_multi_action_form_and_malformed_fields_degrade_safely() -> None:
    picker = form(
        [field("model", "Model")],
        actions=[
            {"label": "Load", "action": "chrome_llm_models"},
            {"label": "Save", "action": "chrome_llm_save", "payload": {"keep": True}},
        ],
    )
    malformed = ComponentView(
        "param_picker",
        {
            "fields": ["bad", {"name": "okay", "label": "Okay", "kind": "text"}],
            "actions": [],
        },
    )
    html = render_html(build_view("llm", "LLM", [picker, malformed]))
    assert html.count('data-ui-collect="true"') == 2
    assert 'data-ui-action="chrome_llm_models"' in html
    assert 'name="okay"' in html


def test_degradation_and_unknown_or_sparse_components_are_visible() -> None:
    view = build_view("watch", "Watch", [ComponentView("mystery", {})])
    degraded = type(view)(
        view.surface,
        view.title,
        view.components,
        view.theme,
        view.layout,
        DegradationView(True, "The watch uses a text fallback.", ("mystery",)),
    )
    html = render_html(degraded)
    assert "Adapted presentation" in html
    assert "text fallback" in html
    assert "unknown" not in html
    assert "mystery component is not available" in html
    assert "unknown component is not available" in _render_component({})
    assert _render_component({"type": "keyvalue", "items": ["bad"]}).endswith("</section>")
    assert _render_component({"type": "list", "items": [{"bad": True}]}) == "<ul></ul>"


def test_component_constructor_validation_and_optional_fields() -> None:
    assert clean_text("a\x00b\x7fc") == "abc"
    assert clean_text(0) == "0"
    assert clean_text(False) == "False"
    assert alert("message", title=None).to_dict() == {
        "type": "alert",
        "message": "message",
        "variant": "info",
    }
    assert field("simple", "Simple") == {"name": "simple", "label": "Simple", "kind": "text"}
    assert field("secret", "Secret", "password", default="hidden") == {
        "name": "secret",
        "label": "Secret",
        "kind": "password",
    }
    assert form([], description="").to_dict()["type"] == "param_picker"
    assert button("Attach", "attach_existing", local=True).to_dict()["local"] is True
    assert denied_view("admin", "Admin", "Denied").components[0].to_dict()["variant"] == "error"
    assert (
        unavailable_view("audit", "Audit", "Offline").components[0].to_dict()["title"]
        == "Unavailable"
    )
    with pytest.raises(ValueError, match="action"):
        button("Bad", "Bad Action")
    with pytest.raises(ValueError, match="field name"):
        field("bad field", "Bad")
    with pytest.raises(ValueError, match="field kind"):
        field("okay", "Bad", "date")
    with pytest.raises(ValueError, match="action"):
        form([], actions=[{"label": "Bad", "action": "Bad Action"}])


def test_renderer_handles_empty_form_and_unselected_controls() -> None:
    raw = ComponentView(
        "param_picker",
        {
            "title": "Raw",
            "description": "Raw controls",
            "fields": [
                {"name": "flag", "label": "Flag", "kind": "boolean", "default": False},
                {"name": "choice", "label": "Choice", "kind": "select", "options": [{"bad": 1}]},
                {"name": "password", "label": "Password", "kind": "password", "default": "secret"},
            ],
        },
    )
    html = render_html(build_view("raw", "Raw", [raw]))
    assert " checked" not in html
    assert "secret" not in html
    assert "<select" in html
    assert "<option" not in html
