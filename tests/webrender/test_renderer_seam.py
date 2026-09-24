"""Tests proving the multi-target renderer seam
(backend/webrender/targets/stub_renderer.py, backend/webrender/__init__.py):
registering a new target needs no change to astralprims primitive definitions.
"""

import astralprims as ap
import webrender
from webrender import register_target, render_for_target, TARGET_RENDERERS


def test_stub_target_installs_and_renders_same_structured_form():
    from webrender.targets import stub_renderer
    stub_renderer.install()
    assert "stubtext" in TARGET_RENDERERS

    comps = [ap.Text(content="hello").to_dict(), ap.Card(title="ignored", content=[]).to_dict()]
    out = render_for_target("stubtext", comps, None)
    assert out == "hello"
    web = render_for_target("web", comps, None)
    assert "hello" in web and "dynamic-renderer" in web


def test_registering_target_does_not_touch_primitive_definitions():
    before = ap.Text(content="x").to_dict()
    register_target("ephemeral", lambda comps, profile: "ok")
    after = ap.Text(content="x").to_dict()
    assert before == after
    assert render_for_target("ephemeral", [], None) == "ok"


def test_primitive_renderer_lookup():
    assert webrender.get_renderer("text") is not None
    assert webrender.get_renderer("does-not-exist") is None
