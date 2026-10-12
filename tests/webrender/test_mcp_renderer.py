"""Tests for the MCP render target (backend/webrender/targets/mcp_renderer.py,
backend/webrender/registry.py): text/alert/fallback projection, depth bounding, and
serialization of lists, scalars, and nulls, plus the UTF-8 byte, block-count,
whole-result, and traversal-node budgets that bound every rendered result.
"""

from __future__ import annotations

from decimal import Decimal
import json

import pytest

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


def test_renderer_caps_blocks_by_utf8_bytes_not_characters() -> None:
    emoji = render_mcp([{"type": "text", "content": "🌧" * 65536}])[0]["text"]
    assert len(emoji.encode("utf-8")) == 64 * 1024
    assert emoji.endswith("\n[truncated]")
    assert emoji.startswith("🌧🌧")

    ascii_block = render_mcp(
        [{"type": "text", "content": "a" * (64 * 1024 + 1)}]
    )[0]["text"]
    assert len(ascii_block.encode("utf-8")) == 64 * 1024
    assert ascii_block.endswith("\n[truncated]")

    fitting = render_mcp([{"type": "text", "content": "a" * (64 * 1024 - 12)}])[0]["text"]
    assert len(fitting.encode("utf-8")) == 64 * 1024 - 12
    assert "[truncated]" not in fitting


def test_renderer_replaces_lone_surrogates_with_valid_scalars() -> None:
    block = render_mcp([{"type": "text", "content": "ok \ud800 end"}])[0]["text"]
    assert block == "ok \ufffd end"
    rows = render_mcp([{"type": "table", "rows": [["bad \udfff seat"]]}])[0]["text"]
    assert "bad \ufffd seat" in rows


def test_renderer_caps_total_blocks_and_whole_result_bytes() -> None:
    many = render_mcp(
        [{"type": "text", "content": f"item {index}"} for index in range(300)]
    )
    assert len(many) == 257
    assert many[256] == {"type": "text", "text": "[result truncated: 44 component(s) omitted]"}

    oversized = render_mcp([{"type": "text", "content": "x" * 70000} for _ in range(40)])
    assert len(oversized) == 4
    assert sum(len(block["text"].encode("utf-8")) for block in oversized) == 256 * 1024
    assert all(block["text"].endswith("\n[truncated]") for block in oversized)


def test_renderer_bounds_json_lists_with_depth_budget_and_private_keys() -> None:
    deep: object = [1]
    for _ in range(2000):
        deep = [deep]
    blocks = render_mcp(
        [
            {"type": "table", "rows": deep},
            {"type": "table", "rows": [{"token": "secret", "ok": 1}]},
            {"type": "table", "rows": [["🌧" * 40000]]},
            {"type": "table", "rows": [list(range(100000))]},
        ]
    )
    assert "nested content omitted" in blocks[0]["text"]
    assert '"ok": 1' in blocks[1]["text"] and "secret" not in blocks[1]["text"]
    assert blocks[2]["text"].endswith('[truncated]"]]')
    assert len(blocks[2]["text"].encode("utf-8")) <= 64 * 1024
    assert blocks[3]["text"].endswith("]]\n[truncated]")
    assert len(blocks[3]["text"].encode("utf-8")) <= 64 * 1024


def test_renderer_bounds_traversal_nodes_and_marks_the_cut() -> None:
    wide = {"type": "panel", "children": [{"token": index} for index in range(30000)]}
    block = render_mcp([wide])[0]["text"]
    assert block.endswith("\n[truncated]")
    assert len(block.encode("utf-8")) <= 64 * 1024

    repeated = render_mcp([wide] * 300)
    assert len(repeated) == 2
    assert repeated[1]["text"] == "[result truncated: 299 component(s) omitted]"


def test_renderer_preserves_json_escaping_and_scalar_coercion() -> None:
    blocks = render_mcp(
        [
            {"type": "table", "rows": [['he said "hi"\n\t\\ ok\x01']]},
            {"type": "table", "rows": [Decimal("1.5")]},
            {"type": "table", "rows": [{"a": 1, "b": 2}]},
        ]
    )
    assert '\\"hi\\"' in blocks[0]["text"] and "\\u0001" in blocks[0]["text"]
    assert "\\\\ ok" in blocks[0]["text"] and "\\n" in blocks[0]["text"] and "\\t" in blocks[0]["text"]
    assert '"1.5"' in blocks[1]["text"]
    assert '"a": 1, "b": 2' in blocks[2]["text"]


def test_renderer_drops_incomplete_json_fragments_atomically() -> None:
    blocks = render_mcp(
        [
            {"type": "table", "rows": [{"a": "X" * 65600, "b": 1}]},
            {"type": "table", "rows": ["X" * 65600, {"b": 1}]},
            {"type": "table", "rows": ["X" * 65600, [1], [2]]},
            {"type": "table", "rows": ["X" * 65600, "y" * 20]},
            {"type": "table", "rows": [{"n": 1} for _ in range(20000)]},
        ]
    )
    for block in blocks:
        assert block["text"].endswith("\n[truncated]")
        assert len(block["text"].encode("utf-8")) <= 64 * 1024
    assert blocks[0]["text"].endswith('[truncated]"}]\n[truncated]') and '"b"' not in blocks[0]["text"]
    assert '"b"' not in blocks[1]["text"] and "{}" not in blocks[1]["text"]
    assert "[1]" not in blocks[2]["text"] and "[2]" not in blocks[2]["text"]
    assert '"[truncated]"' not in blocks[3]["text"]
    assert blocks[4]["text"].endswith('{"n": 1}]\n[truncated]')


def test_renderer_cuts_multibyte_sequences_only_at_scalar_boundaries() -> None:
    block = render_mcp([{"type": "text", "content": "ab" + "🌧" * 20000}])[0]["text"]
    assert len(block.encode("utf-8")) <= 64 * 1024
    assert block.endswith("\n[truncated]")
    assert block.startswith("ab")
    body = block[: -len("\n[truncated]")].encode("utf-8")
    assert (len(body) - 2) % 4 == 0


def test_renderer_writes_readable_children_from_nested_lists() -> None:
    block = render_mcp([{"type": "x", "children": [[1, "two"]]}])[0]["text"]
    assert block == "type: x\n1\ntwo"


def test_renderer_spends_the_whole_result_budget_at_the_tail() -> None:
    components = [{"type": "text", "content": "x" * 70000} for _ in range(3)]
    components.append({"type": "text", "content": "x" * 65506})
    components.append({"type": "t", "rows": [[1]]})
    blocks = render_mcp(components)
    assert len(blocks) == 5
    assert [len(block["text"].encode("utf-8")) for block in blocks] == [
        65536,
        65536,
        65536,
        65506,
        26,
    ]
    assert blocks[-1]["text"] == "type: t\nrows: \n[truncated]"
    assert sum(len(block["text"].encode("utf-8")) for block in blocks) <= 256 * 1024


@pytest.mark.parametrize("remaining", range(12, 181))
@pytest.mark.parametrize(
    "rows",
    [
        [["", [], [1]]],
        [["", {}]],
        [{"a": {"b": [1]}}],
        [["\\\"\n🌧" * 100]],
        [[], [], []],
    ],
)
def test_renderer_keeps_nested_json_valid_at_every_result_tail(remaining, rows) -> None:
    components = [{"type": "text", "content": "x" * 70000} for _ in range(3)]
    components.append({"type": "text", "content": "x" * (65536 - remaining)})
    components.append({"type": "table", "rows": rows})
    blocks = render_mcp(components)

    assert sum(len(block["text"].encode("utf-8")) for block in blocks) <= 256 * 1024
    tail = blocks[-1]["text"].removesuffix("\n[truncated]")
    if "rows: " in tail:
        encoded_rows = tail.partition("rows: ")[2]
        if encoded_rows:
            assert isinstance(json.loads(encoded_rows), list)
