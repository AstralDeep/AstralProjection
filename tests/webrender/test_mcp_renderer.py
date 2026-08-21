from __future__ import annotations

from webrender.registry import TARGET_RENDERERS
from webrender.targets.mcp_renderer import install, render_mcp


def test_renderer_registers_and_projects_text_alert_and_portable_fallbacks() -> None:
    install()
    assert TARGET_RENDERERS["mcp"] is render_mcp

    blocks = render_mcp(
        [
            {"type": "text", "content": "hello", "html": "<script>secret</script>"},
            {"type": "alert", "variant": "warning", "message": "careful"},
            {
                "type": "table",
                "title": "Totals",
                "headers": ["A"],
                "rows": [[1]],
                "children": [{"type": "text", "content": "nested"}],
                "token": "private",
            },
            {"type": "future_widget", "title": "Portable"},
            {"type": "", "action": "private"},
        ]
    )

    assert blocks[0] == {"type": "text", "text": "hello"}
    assert blocks[1] == {"type": "text", "text": "warning: careful"}
    assert "Totals" in blocks[2]["text"] and "nested" in blocks[2]["text"]
    assert "private" not in repr(blocks)
    assert "Portable" in blocks[3]["text"]
    assert "no portable text representation" in blocks[4]["text"]


def test_renderer_bounds_text_depth_and_filters_non_components() -> None:
    nested: object = {"label": "bottom"}
    for _ in range(14):
        nested = {"children": [nested]}

    blocks = render_mcp(
        [
            {"type": "text", "content": "x" * (64 * 1024 + 1)},
            nested,
            "ignored",
        ],
        profile=object(),
    )
    assert blocks[0]["text"].endswith("\n[truncated]")
    assert "nested content omitted" in blocks[1]["text"]
    assert len(blocks) == 2
    assert render_mcp([]) == []


def test_renderer_serializes_readable_lists_scalars_and_nulls() -> None:
    blocks = render_mcp(
        [
            {
                "type": "collection",
                "headers": ["A", "B"],
                "rows": [[1, None]],
                "items": [True, 2.5],
                "count": 0,
                "enabled": False,
                "empty": "",
            },
            {"type": "unknown", "children": [None, 1, "child"]},
        ]
    )
    assert "headers" in blocks[0]["text"]
    assert "rows" in blocks[0]["text"]
    assert "items" in blocks[0]["text"]
    assert "enabled: False" in blocks[0]["text"]
    assert "child" in blocks[1]["text"]
