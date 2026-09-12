"""Bounded, pure rendering of an untrusted client-visible canvas capture.

No authorization, persistence, logging, dispatch, ref resolution or URL fetching
occurs here. The HTTP host owns identity/revision checks; native isolated browser
hosts own the final script-free snapshot and account-safe file lifetime.
"""
from __future__ import annotations

import base64
import binascii
import html
import json
import math
import re
import struct
from html.parser import HTMLParser
from typing import Any

from .renderer import render_strict

VERSION = "astral.canvas-export/v1"
CHARTS = frozenset({"bar_chart", "line_chart", "pie_chart", "plotly_chart"})
MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_NODES = 12000
MAX_DEPTH = 32
THEME_KEYS = {"bg", "surface", "surface2", "border", "primary", "secondary", "text", "muted",
              "accent", "success", "warning", "error", "info"}
SUPPORTED = frozenset({
    "container", "text", "card", "table", "list", "alert", "progress", "metric", "code",
    "image", "grid", "tabs", "divider", "collapsible", "bar_chart", "line_chart", "pie_chart",
    "plotly_chart", "badge", "hero", "keyvalue", "timeline", "rating",
})
OMITTED = frozenset({
    "button", "input", "param_picker", "color_picker", "theme_apply", "file_upload",
    "file_download", "skeleton", "chat_history", "download_card",
})
_STRIPPED = frozenset({
    "action", "payload", "token", "authorization", "headers", "cookie", "cookies",
    "access_token", "refresh_token", "provenance", "versions", "owner", "user_id",
    "chat_id", "_presentation", "css", "style",
})
_ALLOWED_TAGS = frozenset("div span p h1 h2 h3 h4 h5 h6 ul ol li table thead tbody tfoot tr th td caption colgroup col dl dt dd pre code blockquote strong em b i u s del br hr a img details summary section article figure figcaption label small sup sub".split())
_VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())


class PresentationError(ValueError):
    """Closed, data-free failure suitable for an authenticated host response."""


def _fail(code: str) -> None:
    raise PresentationError(code)


def _object(value: Any, fields: set[str]) -> dict:
    if not isinstance(value, dict) or set(value) != fields:
        _fail("invalid_fields")
    return value


def _pairs(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate_key")
        result[key] = value
    return result


def _bound_tree(value: Any, depth: int = 0, budget: list[int] | None = None) -> None:
    budget = [MAX_NODES] if budget is None else budget
    budget[0] -= 1
    if budget[0] < 0 or depth > MAX_DEPTH:
        _fail("tree_limit")
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"__proto__", "constructor", "prototype"}:
                _fail("unsafe_key")
            _bound_tree(child, depth + 1, budget)
    elif isinstance(value, list):
        for child in value:
            _bound_tree(child, depth + 1, budget)
    elif isinstance(value, float) and not math.isfinite(value):
        _fail("invalid_number")


def _dimension(value: Any, low: int, high: int) -> int | float:
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        _fail("invalid_viewport")
    return value


def _png(value: Any) -> str:
    if not isinstance(value, str) or not value.startswith("data:image/png;base64,"):
        _fail("image_pixels_unavailable")
    try:
        raw = base64.b64decode(value[22:], validate=True)
    except (ValueError, binascii.Error):
        _fail("invalid_image")
    if len(raw) < 33 or raw[:8] != b"\x89PNG\r\n\x1a\n" or raw[8:16] != b"\0\0\0\rIHDR":
        _fail("invalid_image")
    width, height = struct.unpack(">II", raw[16:24])
    if not 1 <= width <= 4096 or not 1 <= height <= 4096:
        _fail("image_dimension_limit")
    # A few browser decoders tolerate damaged ancillary chunks. Refuse corrupt
    # captures deterministically before returning them; the isolated browser
    # additionally decodes the pixels, including their compressed image data.
    offset, image_data = 8, False
    while offset + 12 <= len(raw):
        size = struct.unpack(">I", raw[offset:offset + 4])[0]
        end = offset + 12 + size
        if end > len(raw):
            _fail("invalid_image")
        kind = raw[offset + 4:offset + 8]
        checksum = struct.unpack(">I", raw[end - 4:end])[0]
        if binascii.crc32(raw[offset + 4:end - 4]) != checksum:
            _fail("invalid_image")
        image_data = image_data or kind == b"IDAT" and size > 0
        if kind == b"IEND":
            if size or end != len(raw) or not image_data:
                _fail("invalid_image")
            return value
        offset = end
    _fail("invalid_image")


def _clean(value: Any) -> Any:
    # Component metadata is separate from visible cell/list data. Do not walk
    # arbitrary data dictionaries and erase literal fields such as "source" or
    # "action" from a displayed table cell. Child components are cleaned by the
    # structural walker; all emitted attributes pass through _InertMarkup.
    return {key: child for key, child in value.items()
            if key.lower() not in _STRIPPED and not key.startswith(("data-", "_"))}


class _InertMarkup(HTMLParser):
    """Strip renderer dispatch metadata/URLs; apply only validated tab state."""
    def __init__(self, tabs: dict[str, list[int]]):
        super().__init__(convert_charrefs=True)
        self.tabs = tabs
        self.stack: list[tuple[str, bool, list[int] | None]] = []
        self.tab_indices: dict[str, int] = {}
        self.out: list[str] = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        classes = (values.get("class") or "").split()
        if (tag == "svg" or self.stack and not self.stack[-1][1] or any(name in classes for name in
                ("astral-pagination", "astral-component-chrome", "astral-skeleton"))):
            if tag not in _VOID:
                self.stack.append((tag, False, None))
            return
        if tag not in _ALLOWED_TAGS:
            _fail("unsupported_markup")
        state = self.tabs.get(values.get("data-export-node", "")) if "astral-tabs" in classes else None
        if tag == "details" and "astral-tab" in classes:
            parent = next((entry[2] for entry in reversed(self.stack) if entry[2] is not None), None)
            if parent is None:
                _fail("invalid_display_state")
            key = str(id(parent))
            index = self.tab_indices.get(key, 0)
            self.tab_indices[key] = index + 1
            values.pop("open", None)
            if index in parent:
                values["open"] = ""
        kept = []
        for key, value in values.items():
            if (key in {"class", "style", "role", "colspan", "rowspan", "scope", "open", "start",
                        "reversed", "dir", "lang", "alt", "width", "height"}
                    or re.fullmatch(r"aria-[a-z-]+", key)
                    or key == "src" and tag == "img"):
                if key == "src":
                    value = _png(value)
                if key == "style" and re.search(r"url\s*\(|expression|@import", value or "", re.I):
                    _fail("unsafe_style")
                kept.append(f' {key}="{html.escape(value or "", quote=True)}"')
        self.out.append(f"<{tag}{''.join(kept)}>")
        if tag not in _VOID:
            self.stack.append((tag, True, state))

    def handle_endtag(self, tag):
        if tag in _VOID:
            return
        if not self.stack:
            _fail("invalid_markup")
        name, emitted, _ = self.stack.pop()
        if name != tag:
            _fail("invalid_markup")
        if emitted:
            self.out.append(f"</{tag}>")

    def handle_data(self, data):
        if not self.stack or self.stack[-1][1]:
            self.out.append(html.escape(data))


def render_presentation(payload: bytes) -> dict[str, Any]:
    """Return bounded inert markup for a visible capture, or a data-free error.

    Args:
        payload: Exact closed UTF-8 JSON display capture, at most 8 MiB.

    Raises:
        PresentationError: Invalid, oversized, unsupported or unavailable input.
    """
    if not isinstance(payload, bytes) or len(payload) > MAX_INPUT_BYTES:
        _fail("input_limit")
    try:
        source = json.loads(payload.decode("utf-8"), object_pairs_hook=_pairs)
        _bound_tree(source)
        # Refuse unpaired surrogate escapes before they reach renderer output.
        json.dumps(source, ensure_ascii=False, allow_nan=False).encode("utf-8")
    except PresentationError:
        raise
    except (UnicodeError, ValueError, RecursionError):
        _fail("invalid_json")
    source = _object(source, {"version", "components", "viewport", "theme", "display_state", "images"})
    if source["version"] != VERSION:
        _fail("unsupported_version")
    viewport = _object(source["viewport"], {"width", "height", "window_width", "window_height"})
    _dimension(viewport["width"], 64, 4096)
    _dimension(viewport["height"], 32, 16384)
    _dimension(viewport["window_width"], 64, 16384)
    _dimension(viewport["window_height"], 32, 16384)
    if viewport["width"] > viewport["window_width"]:
        _fail("invalid_viewport")
    theme = _object(source["theme"], THEME_KEYS)
    if any(not isinstance(value, str) or not re.fullmatch(
            r"#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?" if key == "border" else r"#[0-9a-fA-F]{6}", value)
           for key, value in theme.items()):
        _fail("invalid_theme")
    records = {}
    for key, fields in (("display_state", {"path", "component_id", "kind", "value"}),
                        ("images", {"path", "component_id", "data_url"})):
        if not isinstance(source[key], list):
            _fail("invalid_records")
        for raw in source[key]:
            item = _object(raw, fields)
            path = item["path"]
            if not isinstance(path, str) or path in records:
                _fail("duplicate_or_invalid_path")
            records[path] = (key, item)
    tabs = {}
    chart_pixels = {}

    def nodes(items, path):
        if not isinstance(items, list):
            _fail("invalid_components")
        return [adapted for index, item in enumerate(items)
                if (adapted := node(item, f"{path}/{index}")) is not None]

    def children(item, path):
        keys = [key for key in ("content", "children") if key in item]
        if len(keys) > 1:
            _fail("ambiguous_children")
        key = keys[0] if keys else "content"
        return nodes(item.get(key, []), path + "/" + key)

    def node(item, path):
        if not isinstance(item, dict) or not isinstance(item.get("type"), str):
            _fail("invalid_component")
        kind = item["type"]
        if kind in OMITTED or item.get("data-welcome"):
            return None
        if kind not in SUPPORTED:
            _fail("unsupported_component")
        if any(item.get(key) not in (None, "", {}) for key in ("css", "style")):
            _fail("unsupported_authored_style")
        identity = item.get("component_id", item.get("id"))
        if identity is not None and (not isinstance(identity, str) or not identity or len(identity) > 256):
            _fail("invalid_identity")
        if "component_id" in item and "id" in item and item["component_id"] != item["id"]:
            _fail("invalid_identity")
        # Pixels are captured from the existing ready chart, preserving zoom,
        # pan and legend selection. Raw chart data/config is never replayed or
        # serialized into the response, and cannot become another authority.
        cleaned = ({"type": kind, "title": item.get("title")} if kind in CHARTS else _clean(item))
        if kind in {"collapsible", "tabs", "image"} | CHARTS:
            record = records.pop(path, None)
            if record is None or record[1]["component_id"] != identity:
                _fail("missing_or_stale_display_state")
            group, state = record
            if kind == "image" or kind in CHARTS:
                if group != "images":
                    _fail("invalid_display_state")
                pixels = _png(state["data_url"])
                if kind in CHARTS:
                    chart_pixels[id(cleaned)] = pixels
                else:
                    cleaned["url"] = pixels
            else:
                if group != "display_state" or state["kind"] != kind + "_open":
                    _fail("invalid_display_state")
                if kind == "collapsible":
                    if type(state["value"]) is not bool:
                        _fail("invalid_display_state")
                    cleaned["default_open"] = state["value"]
                else:
                    value = state["value"]
                    if (not isinstance(item.get("tabs"), list) or not isinstance(value, list)
                            or any(type(index) is not int or not 0 <= index < len(item["tabs"])
                                   for index in value) or len(set(value)) != len(value)):
                        _fail("invalid_display_state")
                    tabs[path] = value
                    cleaned["attributes"] = {"data-export-node": path}
        if kind in {"container", "card", "grid", "collapsible"}:
            cleaned.pop("children", None)
            cleaned["content"] = children(item, path)
        elif kind == "tabs":
            clean_tabs = []
            for index, tab in enumerate(item["tabs"]):
                if not isinstance(tab, dict) or not isinstance(tab.get("label", ""), str):
                    _fail("invalid_tabs")
                clean_tabs.append({"label": tab.get("label", f"Tab {index + 1}"),
                                   "content": children(tab, f"{path}/tabs/{index}")})
            cleaned["tabs"] = clean_tabs
        return cleaned

    components = nodes(source["components"], "/components")
    if records:
        _fail("unused_display_state")
    if not components:
        _fail("empty_canvas")
    try:
        raw_html = render_strict(components, chart_pixels=chart_pixels)
        scrubber = _InertMarkup(tabs)
        scrubber.feed(raw_html)
        scrubber.close()
        if scrubber.stack:
            _fail("invalid_markup")
        result = {"version": VERSION, "html": "".join(scrubber.out), "viewport": viewport, "theme": theme}
        if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > MAX_OUTPUT_BYTES:
            _fail("output_limit")
        return result
    except PresentationError:
        raise
    except Exception:
        _fail("render_failed")
