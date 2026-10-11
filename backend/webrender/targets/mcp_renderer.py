"""Renders astralprims components into bounded, deterministic MCP content blocks for
mcp_server_endpoint; registered into webrender/registry.py as the 'mcp' target.
"""

from __future__ import annotations

import json
from typing import Any

from ..registry import register_target


TARGET_NAME = "mcp"
_MAX_BLOCK_BYTES = 64 * 1024
_MAX_RESULT_BYTES = 256 * 1024
_MAX_BLOCKS = 256
_MAX_DEPTH = 12
_MAX_NODES = 20_000
_CHUNK = 512
_MARKER = "\n[truncated]"
_MARKER_BYTES = len(_MARKER.encode("utf-8"))
_NESTED = "[nested content omitted]"
_JSON_NESTED = json.dumps(_NESTED, ensure_ascii=False)
_JSON_TRUNCATED = json.dumps("[truncated]", ensure_ascii=False)
_SHORT_MARKER = "[truncated]"
_LIST_RESERVE = len(", " + _JSON_TRUNCATED)
_RECURSIVE_KEYS = frozenset({"content", "children"})
_READABLE_LIST_KEYS = frozenset({"headers", "rows", "items"})
_PRIVATE_KEYS = frozenset(
    {
        "action",
        "attributes",
        "component_id",
        "css",
        "events",
        "handler",
        "html",
        "onclick",
        "owner_user_id",
        "payload",
        "script",
        "token",
    }
)


_SURROGATE_REPLACEMENTS = {codepoint: "\ufffd" for codepoint in range(0xD800, 0xE000)}


def _scalar_bytes(text: str) -> bytes:
    return text.translate(_SURROGATE_REPLACEMENTS).encode("utf-8")


def _cut(data: bytes, limit: int) -> bytes:
    edge = limit
    while edge > 0 and (data[edge] & 0xC0) == 0x80:
        edge -= 1
    return data[:edge]


def _escaped_size(char: str) -> int:
    if char in {'"', "\\"}:
        return 2
    if char < " ":
        return 2 if char in "\b\t\n\f\r" else 6
    return len(_scalar_bytes(char))


class _Budget:
    def __init__(self, bytes_left: int, nodes_left: int) -> None:
        self.parts: list[str] = []
        self.bytes_left = bytes_left
        self.nodes_left = nodes_left
        self.opened = 0
        self.reserved = 0
        self.exhausted = False
        self.starved = False

    @property
    def stopped(self) -> bool:
        return self.exhausted or self.starved

    def _cap(self) -> int:
        return self.bytes_left - self.opened - self.reserved

    def visit(self) -> bool:
        if self.nodes_left <= 0:
            self.starved = True
            return False
        self.nodes_left -= 1
        return True

    def write(self, text: str, *, newline: bool = False) -> None:
        if not text or self.exhausted:
            return
        pending = f"\n{text}" if newline and self.parts else text
        start = 0
        while start < len(pending) and not self.exhausted:
            chunk = pending[start : start + _CHUNK]
            data = _scalar_bytes(chunk)
            cap = self._cap()
            if len(data) > cap:
                data = _cut(data, cap) if cap > 0 else b""
                if data:
                    self.parts.append(data.decode("utf-8"))
                    self.bytes_left -= len(data)
                self.exhausted = True
                return
            self.parts.append(data.decode("utf-8"))
            self.bytes_left -= len(data)
            start += _CHUNK

    def raw(self, text: str) -> None:
        if not text or self.exhausted:
            return
        data = _scalar_bytes(text)
        if len(data) > self._cap():
            self.exhausted = True
            return
        self.parts.append(data.decode("utf-8"))
        self.bytes_left -= len(data)

    def open(self, bracket: str) -> None:
        self.raw(bracket)
        if not self.exhausted:
            self.opened += 1

    def close(self, bracket: str) -> None:
        if not self.opened:
            return
        self.opened -= 1
        self.parts.append(bracket)
        self.bytes_left -= 1

    def drop(self, mark: int) -> None:
        for part in self.parts[mark:]:
            self.bytes_left += len(part.encode("utf-8"))
        del self.parts[mark:]


def _string_json(text: str, budget: _Budget) -> None:
    limit = budget._cap() - 2
    total = 0
    count = 0
    for char in text:
        size = _escaped_size(char)
        if total + size > limit:
            break
        total += size
        count += 1
    if count < len(text):
        while count and total + len(_SHORT_MARKER) > limit:
            count -= 1
            total -= _escaped_size(text[count])
        if not count:
            budget.exhausted = True
            return
        text = text[:count] + _SHORT_MARKER
    budget.raw(json.dumps(text, ensure_ascii=False))


def _json_text(value: Any, budget: _Budget, depth: int) -> None:
    if depth > _MAX_DEPTH:
        budget.raw(_JSON_NESTED)
        return
    if not budget.visit():
        return
    if value is None or isinstance(value, (bool, int, float)):
        budget.raw(json.dumps(value))
        return
    if isinstance(value, str):
        _string_json(value, budget)
        return
    if isinstance(value, dict):
        opened_at = len(budget.parts)
        budget.open("{")
        kept = 0
        for key, item in value.items():
            if budget.stopped or not budget.visit():
                break
            if str(key).lower() in _PRIVATE_KEYS:
                continue
            staged = len(budget.parts)
            if kept:
                budget.raw(", ")
            _string_json(key if isinstance(key, str) else str(key), budget)
            budget.raw(": ")
            before = len(budget.parts)
            if not budget.stopped:
                _json_text(item, budget, depth + 1)
            if budget.stopped and len(budget.parts) == before:
                budget.drop(staged)
                break
            kept += 1
        budget.close("}")
        if budget.stopped and not kept:
            budget.drop(opened_at)
        return
    if isinstance(value, list):
        opened_at = len(budget.parts)
        budget.open("[")
        guard = min(_LIST_RESERVE, budget._cap())
        budget.reserved += guard
        total = len(value)
        index = 0
        for item in value:
            if budget.stopped:
                break
            staged = len(budget.parts)
            if index:
                budget.raw(", ")
            before = len(budget.parts)
            if not budget.stopped:
                _json_text(item, budget, depth + 1)
            if budget.stopped and len(budget.parts) == before:
                budget.drop(staged)
                break
            index += 1
        budget.reserved -= guard
        if index < total:
            if index:
                budget.raw(", ")
            budget.raw(_JSON_TRUNCATED)
        budget.close("]")
        if budget.stopped and not index:
            budget.drop(opened_at)
        return
    _string_json(str(value), budget)


def _readable(value: Any, budget: _Budget, depth: int = 0) -> None:
    if depth > _MAX_DEPTH:
        budget.write(_NESTED, newline=True)
        return
    if not budget.visit():
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if budget.stopped or not budget.visit():
                return
            if str(key).lower() in _PRIVATE_KEYS:
                continue
            if key in _RECURSIVE_KEYS and isinstance(item, list):
                for child in item:
                    if budget.stopped or not budget.visit():
                        return
                    _readable(child, budget, depth + 1)
            elif isinstance(item, (str, int, float, bool)) and item not in ("", None):
                budget.write(f"{key}: ", newline=True)
                budget.write(item if isinstance(item, str) else f"{item}")
            elif isinstance(item, list) and key in _READABLE_LIST_KEYS:
                budget.write(f"{key}: ", newline=True)
                _json_text(item, budget, depth + 1)
        return
    if isinstance(value, list):
        for item in value:
            if budget.stopped or not budget.visit():
                return
            _readable(item, budget, depth + 1)
        return
    budget.write(str("" if value is None else value), newline=True)


def _render_one(
    component: dict[str, Any],
    block_room: int,
    nodes_left: int,
) -> tuple[dict[str, Any], int, int]:
    budget = _Budget(block_room - _MARKER_BYTES, nodes_left)
    kind = str(component.get("type") or "unknown").lower()
    if kind == "text":
        content = component.get("content", "")
        budget.write(str("" if content is None else content))
    elif kind == "alert":
        variant = str(component.get("variant") or "info")
        message = component.get("message", "")
        budget.write(f"{variant}: ")
        budget.write(message if isinstance(message, str) else f"{message}")
    else:
        _readable(component, budget)
        if not budget.parts:
            budget.write(f"[{kind} component has no portable text representation]")
    text = "".join(budget.parts)
    if budget.stopped:
        text += _MARKER
    data = _scalar_bytes(text)
    return {"type": "text", "text": data.decode("utf-8")}, len(data), nodes_left - budget.nodes_left


def render_mcp(
    components: list[dict[str, Any]],
    profile: Any = None,
) -> list[dict[str, Any]]:
    del profile
    blocks: list[dict[str, Any]] = []
    result_left = _MAX_RESULT_BYTES
    nodes_left = _MAX_NODES
    omitted = 0
    for component in components or []:
        if not isinstance(component, dict):
            continue
        if len(blocks) >= _MAX_BLOCKS or nodes_left <= 0 or result_left <= _MARKER_BYTES:
            omitted += 1
            continue
        block, spent, used = _render_one(component, min(_MAX_BLOCK_BYTES, result_left), nodes_left)
        blocks.append(block)
        result_left -= spent
        nodes_left -= used
    if omitted:
        summary = f"[result truncated: {omitted} component(s) omitted]"
        data = _scalar_bytes(summary)
        if len(data) <= result_left:
            blocks.append({"type": "text", "text": data.decode("utf-8")})
    return blocks


def install() -> None:
    register_target(TARGET_NAME, render_mcp)


__all__ = ["TARGET_NAME", "install", "render_mcp"]
