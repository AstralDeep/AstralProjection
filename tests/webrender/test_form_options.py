"""Exercises saved select/checklist values and escaped option labels through both web renderers.
The fixtures use the same primitive fields delivered to native settings clients.
"""

from html.parser import HTMLParser

import pytest

from astralprojection.chrome._components import _render_component, field
from webrender.renderer import render_param_picker


class Options(HTMLParser):
    def __init__(self):
        super().__init__()
        self.options = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "option" or (tag == "button" and attributes.get("data-kind") == "checklist"):
            self.current = {"value": attributes.get("value", attributes.get("data-value")),
                            "selected": "selected" in attributes or attributes.get("aria-pressed") == "true",
                            "label": ""}

    def handle_data(self, data):
        if self.current is not None:
            self.current["label"] += data

    def handle_endtag(self, tag):
        if tag in {"option", "button"} and self.current is not None:
            self.options.append(self.current)
            self.current = None


@pytest.mark.parametrize("render", [render_param_picker, _render_component])
@pytest.mark.parametrize("kind,default", [("select", "custom"), ("checklist", ["custom"])])
def test_labeled_saved_options_display_labels_and_retain_wire_values(render, kind, default):
    component = {"type": "param_picker", "fields": [{"name": "provider", "kind": kind,
                 "default": default, "options": ["openai", {"value": "custom", "label": "Custom endpoint"}]}]}
    parser = Options()
    parser.feed(render(component))
    assert parser.options == [
        {"value": "openai", "selected": False, "label": "openai"},
        {"value": "custom", "selected": True, "label": "Custom endpoint"},
    ]


@pytest.mark.parametrize("render", [render_param_picker, _render_component])
def test_saved_selection_absent_from_catalog_stays_selected(render):
    component = {"type": "param_picker", "fields": [{"name": "model", "kind": "select",
                 "default": "saved-model", "options": ["new-model"]}]}
    parser = Options()
    parser.feed(render(component))
    assert parser.options[-1] == {"value": "saved-model", "selected": True, "label": "saved-model"}


@pytest.mark.parametrize("render", [render_param_picker, _render_component])
def test_option_labels_are_escaped_and_malformed_entries_do_not_become_values(render):
    component = {"type": "param_picker", "fields": [{"name": "model", "kind": "select",
                 "default": "stable", "options": [None, {"bad": "entry"},
                    {"value": "stable", "label": '<script>"unsafe"</script>'}]}]}
    html = render(component)
    assert "<script>" not in html
    parser = Options()
    parser.feed(html)
    assert parser.options == [{"value": "stable", "selected": True, "label": '<script>"unsafe"</script>'}]


def test_shared_field_constructor_preserves_labeled_options_without_aliasing():
    options = ["first", {"value": "custom", "label": "Custom endpoint"}]
    result = field("provider", "Provider", "select", default="custom", options=options)
    assert result["options"] == options
    options[1]["label"] = "changed"
    assert result["options"][1]["label"] == "Custom endpoint"
