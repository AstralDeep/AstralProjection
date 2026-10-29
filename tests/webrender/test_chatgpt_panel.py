"""Tests for the ChatGPT MCP panel target (backend/webrender/targets/chatgpt_panel.py):
strict host-authorized view-model validation, truthful states, escape-by-default output,
restricted artifact links, deterministic documents, and the graceful MCP text fallback.
"""

from __future__ import annotations

import hashlib
import json

import pytest

from webrender.registry import TARGET_RENDERERS, render_for_target
from webrender.targets.chatgpt_panel import (
    InvalidPanelView,
    PANEL_KIND,
    PANEL_RESOURCE_MIME,
    PANEL_RESOURCE_URI,
    PANEL_STATES,
    install,
    panel_document,
    panel_resource,
    panel_tool_metadata,
    render_chatgpt_panel,
    validate_panel_view,
)

_ARTIFACT = {
    "id": "a-1",
    "title": "Evidence pack",
    "media_type": "application/pdf",
    "url": "https://files.example.test/a-1",
    "size_bytes": 2048,
    "note": "signed",
}


def _view(**overrides: object) -> dict:
    view = {
        "kind": PANEL_KIND,
        "state": "succeeded",
        "title": "Quarterly compliance review",
        "artifacts": [dict(_ARTIFACT)],
    }
    view.update(overrides)
    return {key: value for key, value in view.items() if value is not None}


def test_target_registers_and_renders_through_the_registry() -> None:
    install()
    assert TARGET_RENDERERS["chatgpt"] is not None
    rendered = render_for_target("chatgpt", [_view()], profile=object())
    assert rendered["structuredContent"]["state"] == "succeeded"
    with pytest.raises(InvalidPanelView):
        render_for_target("chatgpt", [])
    with pytest.raises(InvalidPanelView):
        render_for_target("chatgpt", [_view(), _view()])
    with pytest.raises(InvalidPanelView):
        render_for_target("chatgpt", ["not a view model"])
    with pytest.raises(InvalidPanelView):
        render_for_target("chatgpt", _view())


@pytest.mark.parametrize(
    ("state", "label"),
    [
        ("waiting", "Waiting to start"),
        ("running", "Running"),
        ("input_required", "Input required"),
        ("failed", "Failed"),
        ("cancelled", "Cancelled"),
        ("succeeded", "Completed"),
    ],
)
def test_every_state_renders_truthfully(state: str, label: str) -> None:
    rendered = render_chatgpt_panel(_view(state=state, artifacts=None))
    assert rendered["structuredContent"]["state"] == state
    assert f"State: {label}" in rendered["content"][0]["text"]
    assert f'"{state}": "{label}"' in panel_document()
    assert rendered["structuredContent"]["kind"] == PANEL_KIND


def test_progress_is_rendered_only_while_running() -> None:
    running = render_chatgpt_panel(
        _view(state="running", artifacts=None, progress={"completed": 3, "total": 5})
    )
    assert "Progress: 3 of 5" in running["content"][0]["text"]
    assert running["structuredContent"]["progress"] == {"completed": 3, "total": 5}
    with pytest.raises(InvalidPanelView, match="only valid while running"):
        render_chatgpt_panel(
            _view(state="succeeded", artifacts=None, progress={"completed": 3, "total": 5})
        )


def test_hostile_text_is_carried_as_data_and_never_reaches_the_document() -> None:
    hostile = '<script>alert(1)</script>"><img src=x onerror=alert(1)> `b` ${x}'
    rendered = render_chatgpt_panel(_view(title=hostile, detail=hostile, artifacts=None))
    document = panel_document()
    assert hostile in rendered["structuredContent"]["title"]
    assert hostile in rendered["content"][0]["text"]
    assert hostile not in document
    assert "innerHTML" not in document
    assert "document.write" not in document
    assert "eval(" not in document
    assert "<script src=" not in document


def test_document_is_static_and_deterministic() -> None:
    first = render_chatgpt_panel(_view())
    second = render_chatgpt_panel(_view())
    assert first == second
    assert first["resource"]["text"] == panel_document()
    digest = hashlib.sha256(panel_document().encode("utf-8")).hexdigest()
    assert len(digest) == 64
    assert panel_document() == panel_document()
    json.dumps(first["structuredContent"])


def test_fallback_text_blocks_carry_the_full_usable_status() -> None:
    rendered = render_chatgpt_panel(_view())
    text = rendered["content"][0]["text"]
    assert rendered["content"][0]["type"] == "text"
    assert "Astral Work status: Quarterly compliance review" in text
    assert "State: Completed" in text
    assert "- Evidence pack (application/pdf, 2048 bytes): https://files.example.test/a-1" in text
    assert "  signed" in text
    assert len(text.encode("utf-8")) <= 64 * 1024


def test_fallback_text_stays_bounded_for_largest_valid_views() -> None:
    artifacts = [
        {
            "id": f"a-{index}",
            "title": "t" * 200,
            "media_type": "text/plain",
            "url": "https://files.example.test/" + "p" * 2000,
            "size_bytes": 1 << 40,
            "note": "n" * 200,
        }
        for index in range(8)
    ]
    rendered = render_chatgpt_panel(
        _view(detail="d" * 2000, status_message="m" * 500, artifacts=artifacts)
    )
    for block in rendered["content"]:
        assert len(block["text"].encode("utf-8")) <= 64 * 1024


def test_structured_content_stays_bounded_and_json_safe() -> None:
    rendered = render_chatgpt_panel(
        _view(detail="d" * 2000, status_message="m" * 500, artifacts=[dict(_ARTIFACT)])
    )
    encoded = json.dumps(rendered["structuredContent"], ensure_ascii=False)
    assert len(encoded.encode("utf-8")) < 16 * 1024
    assert "\\ud800" not in encoded


@pytest.mark.parametrize(
    "url",
    [
        "https://files.example.test/a",
        "http://files.example.test/a",
        "mailto:owner@example.test",
        "/owner/114/artifacts/a-1",
    ],
)
def test_allowed_artifact_url_schemes_pass_through(url: str) -> None:
    rendered = render_chatgpt_panel(
        _view(artifacts=[{**_ARTIFACT, "url": url}])
    )
    assert rendered["structuredContent"]["artifacts"][0]["url"] == url


@pytest.mark.parametrize(
    "url",
    [
        "javascript:alert(1)",
        "JAVASCRIPT:alert(1)",
        " javascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "data:image/png;base64,AAAA",
        "vbscript:msgbox(1)",
        "foo/bar",
        "../escape",
        "https://files.example.test/a b",
        "https://files.example.test/\nalert(1)",
        "https://files.example.test/" + "p" * 2048,
        "",
    ],
)
def test_disallowed_artifact_urls_are_denied(url: str) -> None:
    with pytest.raises(InvalidPanelView, match="artifact url"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "url": url}]))


@pytest.mark.parametrize(
    "media_type",
    [
        "text/plain",
        "text/markdown",
        "text/csv",
        "text/html",
        "application/json",
        "application/pdf",
        "image/png",
        "image/jpeg",
        "image/webp",
    ],
)
def test_allowed_artifact_media_types_pass_through(media_type: str) -> None:
    rendered = render_chatgpt_panel(
        _view(artifacts=[{**_ARTIFACT, "media_type": media_type}])
    )
    assert rendered["structuredContent"]["artifacts"][0]["media_type"] == media_type


@pytest.mark.parametrize(
    "media_type",
    ["image/svg+xml", "application/xhtml+xml", "text/html;charset=utf-8", "TEXT/PLAIN", ""],
)
def test_disallowed_artifact_media_types_are_denied(media_type: str) -> None:
    with pytest.raises(InvalidPanelView, match="media_type"):
        render_chatgpt_panel(
            _view(artifacts=[{**_ARTIFACT, "media_type": media_type}])
        )


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("title", "t" * 201, "title"),
        ("title", 7, "title must be a string"),
        ("title", None, "title"),
        ("detail", "d" * 2001, "detail"),
        ("status_message", "m" * 501, "status_message"),
    ],
)
def test_oversized_or_mistyped_fields_are_denied(field: str, value: object, message: str) -> None:
    with pytest.raises(InvalidPanelView, match=message):
        render_chatgpt_panel(_view(**{field: value}))


def test_artifact_bounds_are_enforced() -> None:
    with pytest.raises(InvalidPanelView, match="at most 8"):
        render_chatgpt_panel(_view(artifacts=[dict(_ARTIFACT)] * 9))
    with pytest.raises(InvalidPanelView, match="artifact title"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "title": "t" * 201}]))
    with pytest.raises(InvalidPanelView, match="artifact id"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "id": "i" * 129}]))
    with pytest.raises(InvalidPanelView, match="artifact note"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "note": "n" * 201}]))
    with pytest.raises(InvalidPanelView, match="size_bytes must be an integer"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "size_bytes": "2"}]))
    with pytest.raises(InvalidPanelView, match="size_bytes"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "size_bytes": True}]))
    with pytest.raises(InvalidPanelView, match="size_bytes is out of range"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "size_bytes": -1}]))
    with pytest.raises(InvalidPanelView, match="out of range"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "size_bytes": (1 << 40) + 1}]))
    with pytest.raises(InvalidPanelView, match="onclick"):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "onclick": "alert(1)"}]))
    with pytest.raises(InvalidPanelView, match="must be an object"):
        render_chatgpt_panel(_view(artifacts=["not an artifact"]))


@pytest.mark.parametrize(
    ("progress", "message"),
    [
        ({"completed": 5, "total": 3}, "0 <= completed <= total"),
        ({"completed": -1, "total": 3}, "0 <= completed <= total"),
        ({"completed": 1, "total": 0}, "0 <= completed <= total"),
        ({"completed": True, "total": 3}, "must be an integer"),
        ({"completed": 1, "total": "3"}, "must be an integer"),
        ({"completed": 1, "total": 3, "extra": 1}, "completed and total only"),
        ({}, "progress must carry"),
        ({"completed": 1, "total": 1_000_000_001}, "0 <= completed <= total"),
    ],
)
def test_invalid_progress_is_denied(progress: object, message: str) -> None:
    with pytest.raises(InvalidPanelView, match=message):
        render_chatgpt_panel(
            _view(state="running", artifacts=None, progress=progress)
        )


def test_view_model_shape_is_closed_and_explicitly_denies_authored_markup() -> None:
    for key in ("html", "script", "css", "style", "token", "payload", "onclick"):
        with pytest.raises(InvalidPanelView, match=key):
            render_chatgpt_panel({**_view(artifacts=None), key: "<script>alert(1)</script>"})
    with pytest.raises(InvalidPanelView, match="kind"):
        render_chatgpt_panel({"state": "succeeded", "title": "t"})
    with pytest.raises(InvalidPanelView, match="kind"):
        render_chatgpt_panel({**_view(artifacts=None), "kind": "other_panel"})
    with pytest.raises(InvalidPanelView, match="state must be one of"):
        render_chatgpt_panel(_view(state="done", artifacts=None))
    with pytest.raises(InvalidPanelView, match="state must be one of"):
        render_chatgpt_panel(_view(state=None, artifacts=None))
    with pytest.raises(InvalidPanelView, match="must be an object"):
        render_chatgpt_panel([_view()])
    with pytest.raises(InvalidPanelView, match="must be an object"):
        render_chatgpt_panel(None)
    with pytest.raises(InvalidPanelView, match="control characters"):
        render_chatgpt_panel(_view(title="bad\x00title", artifacts=None))
    with pytest.raises(InvalidPanelView, match="control characters"):
        render_chatgpt_panel(_view(title="bad\x1btitle", artifacts=None))


def test_lone_surrogates_become_replacement_scalars_and_stay_json_safe() -> None:
    rendered = render_chatgpt_panel(_view(title="ok \ud800 end", artifacts=None))
    assert rendered["structuredContent"]["title"] == "ok \ufffd end"
    assert json.dumps(rendered["structuredContent"])


def test_newline_and_tab_are_allowed_in_multi_line_fields() -> None:
    rendered = render_chatgpt_panel(_view(detail="line one\nline two\tindented"))
    assert rendered["structuredContent"]["detail"] == "line one\nline two\tindented"


def test_transport_responses_are_never_accepted_as_state() -> None:
    with pytest.raises(InvalidPanelView):
        render_chatgpt_panel({"content": [{"type": "text", "text": "done"}], "isError": False})
    with pytest.raises(InvalidPanelView):
        render_chatgpt_panel({"structuredContent": {"state": "succeeded"}})
    document = panel_document()
    assert 'data-state="waiting"' in document
    assert "Status unavailable in this view" in document
    assert PANEL_STATES == (
        "waiting",
        "running",
        "input_required",
        "failed",
        "cancelled",
        "succeeded",
    )


def test_resource_descriptor_and_tool_metadata_shapes() -> None:
    resource = panel_resource()
    assert set(resource) == {"uri", "mimeType", "title", "text", "_meta"}
    assert resource["uri"] == PANEL_RESOURCE_URI
    assert resource["mimeType"] == PANEL_RESOURCE_MIME == "text/html;profile=mcp-app"
    assert resource["text"] == panel_document()
    assert resource["_meta"]["ui"] == {
        "csp": {"connectDomains": [], "resourceDomains": [], "frameDomains": [], "baseUriDomains": []},
        "permissions": {},
    }
    metadata = panel_tool_metadata()
    assert metadata["ui"] == {"resourceUri": PANEL_RESOURCE_URI, "visibility": ["model"]}
    assert metadata["openai/outputTemplate"] == PANEL_RESOURCE_URI
    assert metadata["openai/widgetAccessible"] is False


def test_document_carries_accessibility_and_keyboard_semantics() -> None:
    document = panel_document()
    assert 'role="status"' in document and 'aria-live="polite"' in document
    assert 'role="progressbar"' in document
    assert 'aria-label="Astral Work status"' in document
    assert ":focus-visible" in document
    assert "prefers-reduced-motion" in document
    assert 'event.key !== "Escape"' in document
    assert 'rel = "noopener noreferrer"' in document
    assert 'anchor.target = "_blank"' in document
    assert "ui/initialize" in document
    assert "addEventListener(\"message\"" in document


def test_validate_panel_view_normalizes_without_mutating_the_input() -> None:
    view = _view()
    frozen = json.dumps(view)
    validated = validate_panel_view(view)
    assert json.dumps(view) == frozen
    assert validated == view
    minimal = validate_panel_view({"kind": PANEL_KIND, "state": "waiting", "title": "t"})
    assert set(minimal) == {"kind", "state", "title"}


@pytest.mark.parametrize("url", ["//evil.test/a", "/\\evil.test/a", "https://", "https://a@evil.test/x", "mailto:"])
def test_ambiguous_artifact_urls_are_rejected(url: str) -> None:
    with pytest.raises(InvalidPanelView):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "url": url}]))


@pytest.mark.parametrize("media_type", [[], {}, None, 3])
def test_non_string_artifact_media_types_are_rejected(media_type: object) -> None:
    with pytest.raises(InvalidPanelView):
        render_chatgpt_panel(_view(artifacts=[{**_ARTIFACT, "media_type": media_type}]))
