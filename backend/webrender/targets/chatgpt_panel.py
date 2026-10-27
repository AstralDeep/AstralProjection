"""Renders a bounded Astral Work status/artifact panel for OpenAI MCP Extension hosts:
a static vanilla HTML/CSS/JS panel document, a strict host-authorized view model, and a
graceful MCP text fallback; registered into webrender/registry.py as the 'chatgpt' target.
"""

from __future__ import annotations

import re
from typing import Any

from ..registry import register_target
from .mcp_renderer import render_mcp

TARGET_NAME = "chatgpt"
PANEL_KIND = "astral_work_status"
PANEL_RESOURCE_URI = "ui://astralprojection/astral-work-status"
PANEL_RESOURCE_MIME = "text/html"
PANEL_RESOURCE_TITLE = "Astral Work status"

STATE_WAITING = "waiting"
STATE_RUNNING = "running"
STATE_INPUT_REQUIRED = "input_required"
STATE_FAILED = "failed"
STATE_CANCELLED = "cancelled"
STATE_SUCCEEDED = "succeeded"
PANEL_STATES = (
    STATE_WAITING,
    STATE_RUNNING,
    STATE_INPUT_REQUIRED,
    STATE_FAILED,
    STATE_CANCELLED,
    STATE_SUCCEEDED,
)
_STATE_LABELS = {
    STATE_WAITING: "Waiting to start",
    STATE_RUNNING: "Running",
    STATE_INPUT_REQUIRED: "Input required",
    STATE_FAILED: "Failed",
    STATE_CANCELLED: "Cancelled",
    STATE_SUCCEEDED: "Completed",
}

_MAX_TITLE = 200
_MAX_DETAIL = 2000
_MAX_MESSAGE = 500
_MAX_ARTIFACTS = 8
_MAX_ARTIFACT_ID = 128
_MAX_ARTIFACT_TITLE = 200
_MAX_ARTIFACT_NOTE = 200
_MAX_URL = 2048
_MAX_SIZE_BYTES = 1 << 40
_MAX_PROGRESS_TOTAL = 1_000_000_000
_ARTIFACT_MEDIA_TYPES = frozenset(
    {
        "text/plain",
        "text/markdown",
        "text/csv",
        "text/html",
        "application/json",
        "application/pdf",
        "image/png",
        "image/jpeg",
        "image/webp",
    }
)
_PANEL_URL = re.compile(r"^(https?://|mailto:|/)", re.IGNORECASE)
_SURROGATE_REPLACEMENTS = {codepoint: "\ufffd" for codepoint in range(0xD800, 0xE000)}
_TOP_LEVEL_KEYS = frozenset(
    {"kind", "state", "title", "detail", "status_message", "progress", "artifacts"}
)
_ARTIFACT_KEYS = frozenset(
    {"id", "title", "media_type", "url", "size_bytes", "note"}
)
_PROGRESS_KEYS = frozenset({"completed", "total"})


class InvalidPanelView(ValueError):
    pass


def _clean_text(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise InvalidPanelView(f"{field} must be a string")
    text = value.translate(_SURROGATE_REPLACEMENTS)
    if any(ord(character) < 32 and character not in "\n\t" for character in text):
        raise InvalidPanelView(f"{field} contains control characters")
    return text


def _bounded_text(value: Any, field: str, limit: int) -> str:
    text = _clean_text(value, field)
    if not text or len(text) > limit:
        raise InvalidPanelView(f"{field} must be 1..{limit} characters")
    return text


def _panel_url(value: Any, field: str) -> str:
    url = _clean_text(value, field).strip()
    if not url or len(url) > _MAX_URL or re.search(r"\s", url):
        raise InvalidPanelView(f"{field} must be a bounded whitespace-free URL")
    if not _PANEL_URL.match(url):
        raise InvalidPanelView(f"{field} must be http(s), mailto, or root-relative")
    return url


def _validated_progress(value: Any, state: str) -> dict[str, int] | None:
    if value is None:
        return None
    if state != STATE_RUNNING:
        raise InvalidPanelView("progress is only valid while running")
    if not isinstance(value, dict) or not value or set(value) - _PROGRESS_KEYS:
        raise InvalidPanelView("progress must carry completed and total only")
    completed, total = value.get("completed"), value.get("total")
    for name, number in (("completed", completed), ("total", total)):
        if isinstance(number, bool) or not isinstance(number, int):
            raise InvalidPanelView(f"progress {name} must be an integer")
    if not 0 <= completed <= total or not 1 <= total <= _MAX_PROGRESS_TOTAL:
        raise InvalidPanelView("progress must satisfy 0 <= completed <= total")
    return {"completed": completed, "total": total}


def _validated_artifact(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InvalidPanelView("each artifact must be an object")
    unknown = set(value) - _ARTIFACT_KEYS
    if unknown:
        raise InvalidPanelView(f"artifact has unsupported keys: {sorted(unknown)}")
    artifact: dict[str, Any] = {
        "id": _bounded_text(value.get("id"), "artifact id", _MAX_ARTIFACT_ID),
        "title": _bounded_text(value.get("title"), "artifact title", _MAX_ARTIFACT_TITLE),
        "media_type": value.get("media_type"),
        "url": _panel_url(value.get("url"), "artifact url"),
    }
    if artifact["media_type"] not in _ARTIFACT_MEDIA_TYPES:
        raise InvalidPanelView("artifact media_type is not in the allowed set")
    if "size_bytes" in value:
        size = value["size_bytes"]
        if isinstance(size, bool) or not isinstance(size, int):
            raise InvalidPanelView("artifact size_bytes must be an integer")
        if not 0 <= size <= _MAX_SIZE_BYTES:
            raise InvalidPanelView("artifact size_bytes is out of range")
        artifact["size_bytes"] = size
    if value.get("note") is not None:
        artifact["note"] = _bounded_text(value["note"], "artifact note", _MAX_ARTIFACT_NOTE)
    return artifact


def validate_panel_view(view_model: Any) -> dict[str, Any]:
    if not isinstance(view_model, dict):
        raise InvalidPanelView("panel view must be an object")
    unknown = set(view_model) - _TOP_LEVEL_KEYS
    if unknown:
        raise InvalidPanelView(f"panel view has unsupported keys: {sorted(unknown)}")
    if view_model.get("kind") != PANEL_KIND:
        raise InvalidPanelView(f"panel view kind must be {PANEL_KIND!r}")
    state = view_model.get("state")
    if state not in PANEL_STATES:
        raise InvalidPanelView(f"panel view state must be one of {sorted(PANEL_STATES)}")
    validated: dict[str, Any] = {
        "kind": PANEL_KIND,
        "state": state,
        "title": _bounded_text(view_model.get("title"), "title", _MAX_TITLE),
    }
    if view_model.get("detail") is not None:
        validated["detail"] = _bounded_text(
            view_model["detail"], "detail", _MAX_DETAIL
        )
    if view_model.get("status_message") is not None:
        validated["status_message"] = _bounded_text(
            view_model["status_message"], "status_message", _MAX_MESSAGE
        )
    progress = _validated_progress(view_model.get("progress"), state)
    if progress is not None:
        validated["progress"] = progress
    if view_model.get("artifacts") is not None:
        artifacts = view_model["artifacts"]
        if not isinstance(artifacts, list) or len(artifacts) > _MAX_ARTIFACTS:
            raise InvalidPanelView(f"artifacts must be a list of at most {_MAX_ARTIFACTS}")
        validated["artifacts"] = [_validated_artifact(artifact) for artifact in artifacts]
    return validated


def _artifact_line(artifact: dict[str, Any]) -> str:
    parts = [artifact["media_type"]]
    if "size_bytes" in artifact:
        parts.append(f"{artifact['size_bytes']} bytes")
    summary = f"- {artifact['title']} ({', '.join(parts)}): {artifact['url']}"
    note = artifact.get("note")
    return f"{summary}\n  {note}" if note else summary


def _fallback_text(view: dict[str, Any]) -> str:
    lines = [
        f"Astral Work status: {view['title']}",
        f"State: {_STATE_LABELS[view['state']]}",
    ]
    if view.get("status_message"):
        lines.append(f"Message: {view['status_message']}")
    if view.get("detail"):
        lines.append(view["detail"])
    if view.get("progress"):
        lines.append(
            f"Progress: {view['progress']['completed']} of {view['progress']['total']}"
        )
    artifacts = view.get("artifacts") or []
    if artifacts:
        lines.append("Artifacts:")
        lines.extend(_artifact_line(artifact) for artifact in artifacts)
    return "\n".join(lines)


def render_chatgpt_panel(view_model: Any, profile: Any = None) -> dict[str, Any]:
    del profile
    view = validate_panel_view(view_model)
    blocks = render_mcp([{"type": "text", "content": _fallback_text(view)}])
    return {
        "kind": PANEL_KIND,
        "resource": panel_resource(),
        "structuredContent": view,
        "content": blocks,
        "metadata": panel_tool_metadata(),
    }


def render_chatgpt_panel_target(components: Any, profile: Any = None) -> dict[str, Any]:
    if isinstance(components, list) and len(components) == 1 and isinstance(components[0], dict):
        return render_chatgpt_panel(components[0], profile)
    raise InvalidPanelView(
        "the chatgpt target renders exactly one panel view-model object per call"
    )


_DOCUMENT = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Astral Work status</title>
<style>
:root { color-scheme: light dark; --fg: #16181d; --muted: #5b6472; --line: #d9dee7;
  --card: #ffffff; --bg: #f5f7fa; --accent: #4356ff; --ok: #0c7a43; --warn: #9a6700;
  --err: #b3261e; --info: #0b5cad; }
@media (prefers-color-scheme: dark) { :root { --fg: #e8eaf0; --muted: #9aa4b5;
  --line: #2c3340; --card: #1b2029; --bg: #12151b; --accent: #8f9dff; --ok: #4cc38a;
  --warn: #e2b93b; --err: #ff8a80; --info: #79b8ff; } }
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
.ap-panel { max-width: 560px; margin: 0 auto; background: var(--card);
  border: 1px solid var(--line); border-radius: 12px; padding: 16px; }
.ap-title { font-size: 16px; font-weight: 600; margin: 0 0 8px; }
.ap-state { display: inline-flex; align-items: center; gap: 6px; font-weight: 600;
  font-size: 13px; border: 1px solid var(--line); border-radius: 999px;
  padding: 2px 10px; margin: 0 0 8px; }
.ap-state[data-state="running"] { color: var(--info); }
.ap-state[data-state="succeeded"] { color: var(--ok); }
.ap-state[data-state="failed"] { color: var(--err); }
.ap-state[data-state="cancelled"], .ap-state[data-state="input_required"] { color: var(--warn); }
.ap-spinner { width: 10px; height: 10px; border: 2px solid currentColor;
  border-right-color: transparent; border-radius: 50%; animation: ap-spin 0.9s linear infinite; }
@keyframes ap-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .ap-spinner { animation: none; } }
.ap-progress { height: 6px; background: var(--line); border-radius: 999px;
  overflow: hidden; margin: 0 0 8px; }
.ap-progress > span { display: block; height: 100%; width: 0; background: var(--accent); }
.ap-message { margin: 0 0 8px; }
.ap-detail { margin: 0 0 8px; white-space: pre-line; color: var(--muted); }
.ap-artifacts { list-style: none; margin: 0; padding: 0; }
.ap-artifacts li { border-top: 1px solid var(--line); padding: 8px 0; }
.ap-artifacts a { color: var(--accent); word-break: break-all; }
.ap-artifacts .ap-meta { color: var(--muted); font-size: 12px; }
.ap-off { color: var(--muted); margin: 8px 0 0; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
</style>
</head>
<body>
<main class="ap-panel" id="ap-panel" role="region" aria-label="Astral Work status" tabindex="-1">
  <h1 class="ap-title" id="ap-title">Astral Work</h1>
  <p class="ap-state" id="ap-state" role="status" aria-live="polite" data-state="waiting"><span class="ap-spinner" id="ap-spin" aria-hidden="true" hidden></span><span id="ap-state-text">Status unavailable in this view</span></p>
  <div class="ap-progress" id="ap-progress" role="progressbar" aria-hidden="true"><span id="ap-progress-fill"></span></div>
  <p class="ap-message" id="ap-message" hidden></p>
  <p class="ap-detail" id="ap-detail" hidden></p>
  <ul class="ap-artifacts" id="ap-artifacts" hidden></ul>
  <p class="ap-off" id="ap-off">This panel shows the live Astral Work status when the chat host supports resource panels. The full status is always available in the assistant messages.</p>
</main>
<script>
(function () {
  "use strict";
  var PANEL_KIND = "astral_work_status";
  var LABELS = {
    "waiting": "Waiting to start",
    "running": "Running",
    "input_required": "Input required",
    "failed": "Failed",
    "cancelled": "Cancelled",
    "succeeded": "Completed"
  };
  var MAX_ARTIFACTS = 8;

  function el(id) { return document.getElementById(id); }

  function readBridge() {
    var host = null;
    try { host = window.openai || null; } catch (error) { host = null; }
    if (!host || typeof host !== "object") return null;
    var candidates = [host.toolOutput, host.toolResponseMetadata];
    for (var i = 0; i < candidates.length; i++) {
      var value = candidates[i];
      if (value && typeof value === "object" && value.kind === PANEL_KIND
        && typeof value.state === "string" && LABELS[value.state]) return value;
    }
    return null;
  }

  function setText(id, text) {
    var node = el(id);
    node.textContent = text;
    node.hidden = !text;
  }

  function safeHref(url) {
    if (typeof url !== "string") return null;
    var candidate = url.trim();
    if (!candidate || candidate.length > 2048 || /\\s/.test(candidate)) return null;
    if (/^(https?:\\/\\/|mailto:|\\/)/i.test(candidate)) return candidate;
    return null;
  }

  function formatBytes(size) {
    if (size < 1024) return size + " B";
    var units = ["KB", "MB", "GB", "TB"];
    var value = size;
    for (var i = 0; i < units.length; i++) {
      value = value / 1024;
      if (value < 1024 || i === units.length - 1) {
        return (Math.round(value * 10) / 10) + " " + units[i];
      }
    }
    return size + " B";
  }

  function render(view) {
    var pill = el("ap-state");
    pill.setAttribute("data-state", view.state);
    el("ap-state-text").textContent = LABELS[view.state] || view.state;
    var spin = el("ap-spin");
    if (spin) spin.hidden = view.state !== "running";
    var bar = el("ap-progress");
    var fill = el("ap-progress-fill");
    var progress = view.progress;
    if (view.state === "running" && progress && typeof progress.completed === "number"
      && typeof progress.total === "number" && progress.total > 0) {
      bar.removeAttribute("aria-hidden");
      var percent = Math.round((progress.completed / progress.total) * 100);
      percent = Math.max(0, Math.min(100, percent));
      fill.style.width = percent + "%";
      bar.setAttribute("aria-valuemin", "0");
      bar.setAttribute("aria-valuemax", "100");
      bar.setAttribute("aria-valuenow", String(percent));
    } else {
      bar.setAttribute("aria-hidden", "true");
      fill.style.width = "0";
    }
    el("ap-title").textContent =
      typeof view.title === "string" && view.title ? view.title : "Astral Work";
    setText("ap-message", typeof view.status_message === "string" ? view.status_message : "");
    setText("ap-detail", typeof view.detail === "string" ? view.detail : "");
    var list = el("ap-artifacts");
    list.textContent = "";
    var artifacts = Array.isArray(view.artifacts) ? view.artifacts : [];
    for (var i = 0; i < artifacts.length && i < MAX_ARTIFACTS; i++) {
      var artifact = artifacts[i];
      if (!artifact || typeof artifact !== "object") continue;
      var title = typeof artifact.title === "string" && artifact.title
        ? artifact.title : "Artifact";
      var link = document.createElement("li");
      var href = safeHref(artifact.url);
      if (href) {
        var anchor = document.createElement("a");
        anchor.href = href;
        anchor.target = "_blank";
        anchor.rel = "noopener noreferrer";
        anchor.textContent = title;
        link.appendChild(anchor);
      } else {
        var plain = document.createElement("span");
        plain.textContent = title;
        link.appendChild(plain);
      }
      var meta = [];
      if (typeof artifact.media_type === "string" && artifact.media_type) {
        meta.push(artifact.media_type);
      }
      if (typeof artifact.size_bytes === "number" && artifact.size_bytes >= 0) {
        meta.push(formatBytes(artifact.size_bytes));
      }
      if (typeof artifact.note === "string" && artifact.note) meta.push(artifact.note);
      if (meta.length) {
        var line = document.createElement("div");
        line.className = "ap-meta";
        line.textContent = meta.join(" \\u00b7 ");
        link.appendChild(line);
      }
      list.appendChild(link);
    }
    list.hidden = !list.childElementCount;
    el("ap-off").hidden = true;
  }

  var initial = readBridge();
  if (initial) render(initial);

  window.addEventListener("message", function (event) {
    var data = event.data;
    if (data && typeof data === "object" && data.kind === PANEL_KIND
      && typeof data.state === "string" && LABELS[data.state]) render(data);
  });

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Escape") return;
    var host = null;
    try { host = window.openai || null; } catch (error) { host = null; }
    if (host && typeof host.requestClose === "function") {
      try { host.requestClose(); return; } catch (error) { }
    }
    el("ap-panel").focus();
  });
})();
</script>
</body>
</html>
"""


def panel_document() -> str:
    return _DOCUMENT


def panel_resource() -> dict[str, Any]:
    return {
        "uri": PANEL_RESOURCE_URI,
        "mimeType": PANEL_RESOURCE_MIME,
        "title": PANEL_RESOURCE_TITLE,
        "text": _DOCUMENT,
    }


def panel_tool_metadata() -> dict[str, Any]:
    return {
        "openai/outputTemplate": {
            "type": "resource",
            "uri": PANEL_RESOURCE_URI,
            "mimeType": PANEL_RESOURCE_MIME,
            "title": PANEL_RESOURCE_TITLE,
        },
        "openai/toolInvocation/invoking": "Loading Astral Work status",
        "openai/toolInvocation/invoked": "Loaded Astral Work status",
        "openai/widgetAccessible": False,
        "openai/resultCanProduceUI": True,
    }


def install() -> None:
    register_target(TARGET_NAME, render_chatgpt_panel_target)


__all__ = [
    "InvalidPanelView",
    "PANEL_KIND",
    "PANEL_RESOURCE_MIME",
    "PANEL_RESOURCE_TITLE",
    "PANEL_RESOURCE_URI",
    "PANEL_STATES",
    "TARGET_NAME",
    "install",
    "panel_document",
    "panel_resource",
    "panel_tool_metadata",
    "render_chatgpt_panel",
    "render_chatgpt_panel_target",
    "validate_panel_view",
]
