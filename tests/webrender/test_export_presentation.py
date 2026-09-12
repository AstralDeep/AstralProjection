"""Untrusted visible-capture boundaries; no application services are loaded."""
import base64
import copy
import json
import struct
import zlib
from pathlib import Path

import pytest

from webrender import export_presentation as ep
from webrender import renderer

THEME = {"bg": "#0F1221", "surface": "#1A1E2E", "surface2": "#1E2338", "border": "#FFFFFF14",
         "primary": "#6366F1", "secondary": "#8B5CF6", "accent": "#06B6D4", "text": "#F3F4F6",
         "muted": "#9CA3AF", "success": "#22C55E", "warning": "#EAB308", "error": "#EF4444", "info": "#3B82F6"}


def png(width=1, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    raw = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    raw += chunk(b"IDAT", zlib.compress(b"\0\x63\x66\xf1\xff")) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(raw).decode()


def capture(components=None, **updates):
    return {"version": ep.VERSION, "components": components if components is not None else [{"type": "text", "content": "Visible transient B"}],
            "viewport": {"width": 393, "height": 852, "window_width": 393, "window_height": 852}, "theme": dict(THEME),
            "display_state": [], "images": [], **updates}


def render(value):
    return ep.render_presentation(json.dumps(value).encode())


def test_contract_matches_closed_renderer_constants():
    contract = json.loads((Path(__file__).parents[2] / "contracts/canvas_export_v1.json").read_text())
    assert contract["version"] == ep.VERSION
    assert set(contract["theme_fields"]) == ep.THEME_KEYS
    assert set(contract["supported_components"]) == ep.SUPPORTED
    assert set(contract["omitted_components"]) == ep.OMITTED
    assert contract["limits"]["input_bytes"] == ep.MAX_INPUT_BYTES
    assert contract["limits"]["output_bytes"] == ep.MAX_OUTPUT_BYTES
    assert set(render(capture())) == set(contract["response_fields"])


def test_real_renderer_preserves_chart_marker_phone_grid_and_transient_without_provenance():
    item = capture([{"type": "grid", "columns": 1, "children": [
        {"type": "text", "content": "Committed A"},
        {"type": "card", "title": "**Transient B**", "provenance": "grounded", "content": [
            {"type": "plotly_chart", "title": "Alpha vs Beta", "data": [
                {"type": "bar", "x": ["Alpha", "Beta"], "y": [2, 5], "marker": {"color": "#6366F1"}}
            ]}] }]}], images=[{"path": "/components/0/children/1/content/0", "component_id": None, "data_url": png()}])
    before = copy.deepcopy(item)
    result = render(item)
    html = result["html"]
    assert "Committed A" in html and "Transient B" in html and "Alpha vs Beta" in html
    assert "grid-template-columns:repeat(1,minmax(0,1fr))" in html and "sm:grid-cols-2" not in html
    assert "data:image/png;base64," in html and "marker" not in html and "data-chart" not in html
    assert "provenance" not in html and "data-action" not in html and "<script" not in html
    assert item == before


def test_markup_text_and_metadata_never_become_effects_or_urls():
    value = capture([{"type": "card", "title": "[X](javascript:bad)", "attributes": {"data-ui-action": "save"},
                      "content": [{"type": "text", "variant": "markdown", "content": '<script>bad()</script> **hi** [site](https://example.com)',
                                   "token": "PRIVATE", "payload": {"secret": "PRIVATE"}}]}])
    html = render(value)["html"]
    assert "&lt;script&gt;bad()&lt;/script&gt;" in html and "<strong" in html
    assert "href=" not in html and "PRIVATE" not in html and "data-ui" not in html
    assert ep._clean({"type": "text", "_source_params": {"key": "PRIVATE"},
                      "content": "Visible", "rows": [[{"_source": "literal displayed value"}]]}) == {
        "type": "text", "content": "Visible", "rows": [[{"_source": "literal displayed value"}]]}


@pytest.mark.parametrize("child_key", ["content", "children"])
def test_explicit_disclosures_alias_paths_and_loaded_pixels(child_key):
    value = capture([{"type": "tabs", "component_id": "t", "tabs": [
        {"label": "A", "content": []}, {"label": "B", child_key: [
            {"type": "collapsible", "id": "d", "content": [
                {"type": "image", "component_id": "i", "url": "https://private/image?token=PRIVATE"}]}]}]}],
        display_state=[{"path": "/components/0", "component_id": "t", "kind": "tabs_open", "value": [1]},
                       {"path": f"/components/0/tabs/1/{child_key}/0", "component_id": "d",
                        "kind": "collapsible_open", "value": True}],
        images=[{"path": f"/components/0/tabs/1/{child_key}/0/content/0", "component_id": "i", "data_url": png()}])
    html = render(value)["html"]
    assert html.count('open=""') == 2
    assert 'class="astral-tab"><summary' in html
    assert "data:image/png;base64," in html and "PRIVATE" not in html
    assert "data-export-node" not in html


def test_paginated_visible_rows_survive_without_controls():
    html = render(capture([{"type": "table", "component_id": "wc_1", "headers": ["Name"],
                           "rows": [["Visible"]], "total_rows": 99, "page_size": 1, "page_offset": 2}]))["html"]
    assert "Visible" in html and "astral-pagination" not in html and "<button" not in html


@pytest.mark.parametrize("kind", sorted(ep.OMITTED))
def test_controls_are_declared_omissions(kind):
    html = render(capture([{"type": kind, "payload": {"token": "PRIVATE"}},
                           {"type": "text", "content": "Keep"}]))["html"]
    assert "Keep" in html and "PRIVATE" not in html


@pytest.mark.parametrize("kind", ["ref", "generative", "audio", "unknown"])
def test_unsupported_visible_content_fails_without_guessing(kind):
    with pytest.raises(ep.PresentationError, match="unsupported_component"):
        render(capture([{"type": kind}]))


@pytest.mark.parametrize("change,error", [
    ({"extra": 1}, "invalid_fields"), ({"version": "future"}, "unsupported_version"),
    ({"components": {}}, "invalid_components"), ({"components": [None]}, "invalid_component"),
    ({"components": []}, "empty_canvas"), ({"display_state": {}}, "invalid_records"),
    ({"theme": {"bg": "#fff"}}, "invalid_fields"),
    ({"theme": {**THEME, "bg": "url(private)"}}, "invalid_theme"),
    ({"viewport": {"width": True, "height": 300, "window_width": 5000, "window_height": 900}}, "invalid_viewport"),
    ({"viewport": {"width": 63, "height": 300, "window_width": 5000, "window_height": 900}}, "invalid_viewport"),
    ({"viewport": {"width": 4097, "height": 300, "window_width": 5000, "window_height": 900}}, "invalid_viewport"),
    ({"viewport": {"width": 390, "height": 16385, "window_width": 393, "window_height": 900}}, "invalid_viewport"),
])
def test_closed_envelope_rejects_invalid_capture(change, error):
    with pytest.raises(ep.PresentationError, match=error):
        render(capture(**change))


@pytest.mark.parametrize("field", ["content", "children"])
def test_child_wrappers_are_not_reinterpreted(field):
    with pytest.raises(ep.PresentationError, match="invalid_components"):
        render(capture([{"type": "card", field: {"type": "text", "content": "wrong"}}]))


def test_ambiguous_aliases_and_metadata_mismatch_refuse():
    for node in [{"type": "card", "content": [], "children": []},
                 {"type": "card", "id": "a", "component_id": "b"}]:
        with pytest.raises(ep.PresentationError):
            render(capture([node]))
    for state in [[], [{"path": "/components/0", "component_id": "wrong", "kind": "collapsible_open", "value": True}],
                  [{"path": "/components/0", "component_id": None, "kind": "collapsible_open", "value": 1}]]:
        with pytest.raises(ep.PresentationError):
            render(capture([{"type": "collapsible"}], display_state=state))


@pytest.mark.parametrize("raw", [b'{"a":1,"a":2}', b'\xff', b'{', b'{"x":NaN}', b'{"x":"\\ud800"}', b'{"__proto__":{}}'])
def test_invalid_json_has_no_payload_in_failure(raw):
    with pytest.raises(ep.PresentationError) as error:
        ep.render_presentation(raw)
    assert len(str(error.value)) < 40


def test_input_tree_and_output_budgets(monkeypatch):
    with pytest.raises(ep.PresentationError, match="input_limit"):
        ep.render_presentation(b" " * (ep.MAX_INPUT_BYTES + 1))
    with pytest.raises(ep.PresentationError, match="tree_limit"):
        render(capture([{"type": "text", "content": [0] * ep.MAX_NODES}]))
    nested = {}
    for _ in range(ep.MAX_DEPTH + 1):
        nested = {"child": nested}
    with pytest.raises(ep.PresentationError, match="tree_limit"):
        render(capture([{"type": "text", "value": nested}]))
    monkeypatch.setattr(ep, "MAX_OUTPUT_BYTES", 100)
    with pytest.raises(ep.PresentationError, match="output_limit"):
        render(capture())


@pytest.mark.parametrize("data", ["https://private", "data:image/svg+xml;base64,PHN2Zz4=", "data:image/png;base64,?", "data:image/png;base64,YQ==", png(4097)])
def test_missing_or_unsafe_pixels_fail(data):
    with pytest.raises(ep.PresentationError):
        render(capture([{"type": "image"}], images=[{"path": "/components/0", "component_id": None, "data_url": data}]))


def test_render_failure_has_no_log_and_context_is_restored(monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("ephemeral renderer logged submitted content")
    monkeypatch.setattr(renderer.logger, "exception", forbidden)
    monkeypatch.setattr(renderer.logger, "warning", forbidden)
    with pytest.raises(ep.PresentationError, match="render_failed"):
        render(capture([{"type": "card", "content": [{"type": "progress", "value": {"private": 1}}]}]))
    assert renderer._strict_rendering.get() is False


@pytest.mark.parametrize("kind", sorted(ep.CHARTS))
def test_every_chart_requires_current_pixels_and_never_replays_remote_data(kind):
    chart = {"type": kind, "id": "current", "title": "Current zoom", "data": "https://private/chart?token=PRIVATE"}
    with pytest.raises(ep.PresentationError, match="missing_or_stale_display_state"):
        render(capture([chart]))
    image = {"path": "/components/0", "component_id": "current", "data_url": png()}
    html = render(capture([chart], images=[image]))["html"]
    assert "Current zoom" in html and "data:image/png;base64," in html
    assert "PRIVATE" not in html and "data-chart" not in html
    image["component_id"] = "previous"
    with pytest.raises(ep.PresentationError, match="missing_or_stale_display_state"):
        render(capture([chart], images=[image]))


def test_corrupt_truncated_and_trailing_png_chunks_are_refused():
    original = base64.b64decode(png()[22:])
    corrupt = bytearray(original)
    corrupt[29] ^= 1
    for raw in (original[:33], original[:-1], bytes(corrupt), original + b"extra"):
        with pytest.raises(ep.PresentationError, match="invalid_image"):
            render(capture([{"type": "image"}], images=[{
                "path": "/components/0", "component_id": None,
                "data_url": "data:image/png;base64," + base64.b64encode(raw).decode(),
            }]))


def test_fractional_canvas_box_is_preserved_separately_from_window():
    viewport = {"width": 296.5, "height": 555.25, "window_width": 1200.5, "window_height": 800.5}
    assert render(capture(viewport=viewport))["viewport"] == viewport
    with pytest.raises(ep.PresentationError, match="invalid_viewport"):
        render(capture(viewport={**viewport, "window_width": 296}))


@pytest.mark.parametrize("field", ["css", "style"])
def test_authored_styles_refuse_but_literal_table_data_is_preserved(field):
    with pytest.raises(ep.PresentationError, match="unsupported_authored_style"):
        render(capture([{"type": "card", "content": [{"type": "text", "content": "Visible", field: {"color": "red"}}]}]))
    html = render(capture([{"type": "table", "headers": ["Metadata"],
                           "rows": [[{"action": "visible action", "source": "visible source", field: "visible style"}]]}]))["html"]
    assert "visible action" in html and "visible source" in html and "visible style" in html


@pytest.mark.parametrize("indices", [[True], [1, 1], [-1], [2], "1"])
def test_tab_capture_rejects_ambiguous_or_invalid_selected_panes(indices):
    with pytest.raises(ep.PresentationError, match="invalid_display_state"):
        render(capture([{"type": "tabs", "tabs": [{"label": "First"}, {"label": "Second"}]}],
                       display_state=[{"path": "/components/0", "component_id": None, "kind": "tabs_open", "value": indices}]))


def test_duplicate_and_unused_state_cannot_retarget_another_component():
    record = {"path": "/components/0", "component_id": None, "kind": "collapsible_open", "value": False}
    with pytest.raises(ep.PresentationError, match="duplicate_or_invalid_path"):
        render(capture([{"type": "collapsible"}], display_state=[record, record]))
    with pytest.raises(ep.PresentationError, match="unused_display_state"):
        render(capture(display_state=[record]))


def test_canonical_icon_subtree_omission_keeps_alert_and_rating_text():
    html = render(capture([{"type": "alert", "title": "Current warning", "message": "Visible details"},
                           {"type": "rating", "label": "Rating", "value": 3.5, "max_value": 5}]))["html"]
    assert "Current warning" in html and "Visible details" in html and "3.5" in html
    assert "<svg" not in html and "<path" not in html


@pytest.mark.parametrize("columns", [0, 65, True, 1.5, "2"])
def test_captured_grid_columns_are_bounded_integers(columns):
    with pytest.raises(ep.PresentationError, match="render_failed"):
        render(capture([{"type": "grid", "columns": columns, "content": []}]))


def test_measured_image_box_and_visible_caption_are_rendered_without_authored_replay():
    item = capture([{"type": "image", "width": 120.5, "height": 80, "caption": "Visible <caption>", "alt": "Loaded image"}],
                   images=[{"path": "/components/0", "component_id": None, "data_url": png()}])
    html = render(item)["html"]
    assert "width:120.5px;height:80px;object-fit:contain" in html
    assert "<figcaption" in html and "Visible &lt;caption&gt;" in html


@pytest.mark.parametrize("dimensions", [{"width": 2}, {"width": 0, "height": 2},
                                         {"width": 1, "height": 16385}, {"width": True, "height": 2},
                                         {"width": "10", "height": 2}, {"caption": {"private": "unused"}}])
def test_invalid_measured_image_boxes_and_caption_are_refused(dimensions):
    with pytest.raises(ep.PresentationError, match="render_failed"):
        render(capture([{"type": "image", **dimensions}],
                       images=[{"path": "/components/0", "component_id": None, "data_url": png()}]))
