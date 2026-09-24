"""Tests for level-of-detail resolution wired into ComponentAdapter.adapt
(backend/rote/adapter.py, backend/rote/capabilities.py): the FF_LOD_LADDER flag,
per-device rung selection, ladder fallback, and nested-container handling.
"""

from __future__ import annotations

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from rote.adapter import ComponentAdapter  # noqa: E402
from rote.capabilities import DeviceCapabilities, DeviceProfile  # noqa: E402


def _profile(device_type: str) -> DeviceProfile:
    return DeviceProfile._derive(DeviceCapabilities(device_type=device_type))


BROWSER = _profile("browser")
MOBILE = _profile("mobile")
WATCH = _profile("watch")
TABLET = _profile("tablet")

_LADDER_TEXT = {
    "type": "text",
    "variant": "body",
    "content": "fallback plain",
    "lod": {
        "l1": "Sales up",
        "l2": "Sales up 12% MoM",
        "l3": "Sales up 12% month-over-month across all regions.",
    },
}


def _only(result):
    assert len(result) == 1, f"expected one component, got {len(result)}: {result}"
    return result[0]


def test_flag_default_off_passes_through(monkeypatch):
    monkeypatch.delenv("FF_LOD_LADDER", raising=False)
    out = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], BROWSER))
    assert out["content"] == "fallback plain"
    assert "lod" in out


def test_flag_off_on_small_screen_keeps_plain_content(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "false")
    out = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], MOBILE))
    assert out["content"] == "fallback plain"
    assert "lod" in out


def test_browser_gets_full_detail_l3(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    out = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], BROWSER))
    assert out["content"] == "Sales up 12% month-over-month across all regions."
    assert "lod" not in out


def test_mobile_gets_summary_l2(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    out = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], MOBILE))
    assert out["content"] == "Sales up 12% MoM"
    assert "lod" not in out


def test_watch_gets_index_l1(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    out = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], WATCH))
    assert out["content"] == "Sales up"
    assert "lod" not in out


def test_small_screen_content_differs_from_browser(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    phone = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], MOBILE))["content"]
    watch = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], WATCH))["content"]
    browser = _only(ComponentAdapter.adapt([dict(_LADDER_TEXT)], BROWSER))["content"]
    assert len(watch) < len(phone) < len(browser)
    assert watch != browser


def test_ladder_falls_down_when_rung_missing(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    comp = {"type": "text", "variant": "body", "content": "plain",
            "lod": {"l1": "idx", "l2": "summary only"}}
    out = _only(ComponentAdapter.adapt([comp], BROWSER))
    assert out["content"] == "summary only"


def test_lod_applies_inside_container(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    card = {"type": "card", "title": "Report", "content": [dict(_LADDER_TEXT)]}
    out = _only(ComponentAdapter.adapt([card], MOBILE))
    assert out["type"] == "card"
    assert isinstance(out["content"], list)
    child = out["content"][0]
    assert child["content"] == "Sales up 12% MoM"
    assert "lod" not in child


def test_component_without_ladder_unchanged(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    comp = {"type": "text", "variant": "body", "content": "no ladder here"}
    out = _only(ComponentAdapter.adapt([comp], MOBILE))
    assert out["content"] == "no ladder here"


def test_metric_ladder_resolves_on_small(monkeypatch):
    monkeypatch.setenv("FF_LOD_LADDER", "true")
    metric = {"type": "metric", "title": "Revenue", "value": "$5M",
              "lod": {"l1": "up", "l3": "up sharply this quarter"}}
    out = _only(ComponentAdapter.adapt([metric], WATCH))
    assert out["content"] == "up"
    assert out["value"] == "$5M"
    assert "lod" not in out
