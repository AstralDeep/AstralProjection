"""Welcome container metadata survives the actual mobile HTML rendering path."""
import json
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from webrender import render_for_target, render_workspace
from webrender.renderer import render_container

ROOT = Path(__file__).resolve().parents[2]
SOURCE = json.loads((ROOT / "contracts/fixtures/workspace_088/welcome.json").read_text())
GOLDEN = ROOT / "tooling/web-ci/fixtures/welcome-rendering-088.json"


@pytest.mark.parametrize("role", ["intro", "permission", "examples", "example", "more"])
@pytest.mark.parametrize("identity", [{}, {"id": "wel_example"}, {"component_id": "wel_example"},
                                      {"component_id": "wel_\"<&>"}])
def test_valid_welcome_container_keeps_one_escaped_wrapper(role, identity):
    component = {"type": "container", "data-welcome": role,
                 "aria-label": 'Choices " & < >', **identity,
                 "children": [{"type": "text", "content": "Visible child"}]}
    html = render_container(component)
    assert html.startswith("<div")
    assert f'data-welcome="{role}"' in html
    assert 'aria-label="Choices &quot; &amp; &lt; &gt;"' in html
    assert html.endswith("</div>")
    assert "Visible child" in html


def test_welcome_wrapper_refuses_event_dispatch_attributes_and_escapes_identity():
    html = render_container({
        "type": "container", "id": 'wel_"<&>', "data-welcome": "examples",
        "onclick": "evil()", "attributes": {"data-ui-action": "evil", "onload": "evil()"},
        "children": [{"type": "text", "content": "Visible child"}],
    })
    assert 'id="wel_&quot;&lt;&amp;&gt;"' in html
    assert 'data-welcome="examples"' in html
    assert "onclick" not in html and "onload" not in html and "data-ui-action" not in html


@pytest.mark.parametrize("change", [
    {}, {"data-welcome": "unknown"}, {"data-welcome": []}, {"data-welcome": {}},
    {"data-welcome": 'examples" onclick="evil()'},
    {"data-welcome": "examples", "id": "real_result"},
    {"data-welcome": "examples", "id": None},
    {"data-welcome": "examples", "id": "wel_example", "component_id": "real_result"},
    {"data-welcome": "examples", "id": "real_result", "component_id": None},
    *({"data-welcome": "examples", "component_id": "wel_examples", "id": identity}
      for identity in ["real_result", None, 3, False]),
    *({"data-welcome": "examples", "component_id": identity}
      for identity in ["real_result", "", None, False, 3, [], {}]),
    {"data-welcome": "examples", "attributes": {"data-welcome": "unknown"}},
])
def test_ordinary_or_invalid_container_still_emits_only_its_children(change):
    children = [{"type": "text", "content": "Ordinary result"}]
    expected = render_container({"type": "container", "children": children})
    assert render_container({"type": "container", "children": children, **change}) == expected
    assert 'data-welcome=' not in expected


@pytest.mark.parametrize("device,width", [("mobile", 390), ("tablet", 694)])
def test_real_adapted_welcome_matches_browser_frames_and_retains_every_slot(device, width, monkeypatch):
    monkeypatch.setenv("FF_ARTIFACT_EXPORT", "true")
    monkeypatch.setenv("FF_ARTIFACT_SHARING", "false")
    profile = DeviceProfile.from_dict({"device_type": device, "viewport_width": width})
    adapted = ComponentAdapter.adapt(SOURCE["components"], profile)
    if device == "mobile":
        assert next(c for c in adapted if c.get("data-welcome") == "examples")["type"] == "container"
    frames = {"workspace": render_workspace(adapted, profile),
              "legacy": render_for_target("web", adapted, profile)}
    for html in frames.values():
        for role in SOURCE["expected_roles"]:
            assert f'data-welcome="{role}"' in html
        assert html.count('data-welcome="example"') == 6
    assert json.loads(GOLDEN.read_text())[device] == frames
