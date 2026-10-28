// Renders the bounded external Work panel and receives MCP Apps lifecycle messages from its source-bound parent.
// chatgpt_panel.py embeds this script into the self-contained resource document.

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

  function setText(id, text) {
    var node = el(id);
    node.textContent = text;
    node.hidden = !text;
  }

  function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
  function keys(value, allowed) { return object(value) && Object.keys(value).every(key => allowed.includes(key)); }
  function text(value, limit) {
    return typeof value === "string" && value.length > 0 && value.length <= limit * 2
      && Array.from(value).length <= limit && Array.from(value).every(char => char >= " " || char === "\n" || char === "\t");
  }
  function safeHref(url) {
    if (!/^(https?:\/\/[^/]|mailto:|\/)/i.test(url) || !text(url, 2048) || url !== url.trim() || /[\s\\]/.test(url)) return null;
    if (url.startsWith("/") && !url.startsWith("//")) return url;
    try {
      const parsed = new URL(url);
      if (["http:", "https:"].includes(parsed.protocol) && parsed.hostname && !parsed.username && !parsed.password) return url;
      if (parsed.protocol === "mailto:" && parsed.pathname) return url;
    } catch { return null; }
    return null;
  }
  function validView(view) {
    if (!keys(view, ["kind", "state", "title", "detail", "status_message", "progress", "artifacts"])
      || view.kind !== PANEL_KIND || typeof view.state !== "string" || !Object.hasOwn(LABELS, view.state) || !text(view.title, 200)) return false;
    for (const [key, limit] of [["detail", 2000], ["status_message", 500]]) {
      if (view[key] != null && !text(view[key], limit)) return false;
    }
    if (view.progress != null) {
      const p = view.progress;
      if (view.state !== "running" || !keys(p, ["completed", "total"])
        || !Number.isInteger(p.completed) || !Number.isInteger(p.total)
        || p.completed < 0 || p.total < 1 || p.completed > p.total || p.total > 1000000000) return false;
    }
    if (view.artifacts != null) {
      if (!Array.isArray(view.artifacts) || view.artifacts.length > MAX_ARTIFACTS) return false;
      for (const a of view.artifacts) {
        if (!keys(a, ["id", "title", "media_type", "url", "size_bytes", "note"])
          || !text(a.id, 128) || !text(a.title, 200) || !safeHref(a.url)
          || !["text/plain", "text/markdown", "text/csv", "text/html", "application/json", "application/pdf", "image/png", "image/jpeg", "image/webp"].includes(a.media_type)
          || (a.note != null && !text(a.note, 200))
          || (Object.hasOwn(a, "size_bytes") && (!Number.isInteger(a.size_bytes) || a.size_bytes < 0 || a.size_bytes > 1099511627776))) return false;
      }
    }
    return true;
  }
  function validResult(result) {
    if (!keys(result, ["content", "structuredContent", "isError", "_meta"])
      || !Array.isArray(result.content) || result.content.length > 256
      || (result.isError !== undefined && typeof result.isError !== "boolean")) return false;
    let bytes = 0;
    for (const block of result.content) {
      if (!keys(block, ["type", "text", "annotations", "_meta"]) || block.type !== "text"
        || typeof block.text !== "string" || block.text.length > 65536) return false;
      const blockBytes = new TextEncoder().encode(block.text).length;
      if (blockBytes > 65536) return false;
      bytes += blockBytes;
      if (bytes > 262144) return false;
    }
    return !result.isError && validView(result.structuredContent);
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

  let ready = false;
  let active = true;
  let inputReceived = false;
  let parentOrigin;
  try { parentOrigin = new URL(document.referrer).origin; } catch { parentOrigin = null; }
  const parentWindow = window.parent;
  const initializeId = "astral-" + Array.from(crypto.getRandomValues(new Uint32Array(4))).join("-");

  function clear() {
    el("ap-title").textContent = "Astral Work";
    el("ap-state").removeAttribute("data-state");
    el("ap-state-text").textContent = "Status unavailable in this view";
    el("ap-spin").hidden = true;
    el("ap-progress").setAttribute("aria-hidden", "true");
    el("ap-progress").removeAttribute("aria-valuenow");
    el("ap-progress-fill").style.width = "0";
    setText("ap-message", ""); setText("ap-detail", "");
    el("ap-artifacts").textContent = ""; el("ap-artifacts").hidden = true;
    el("ap-off").hidden = false;
  }
  function send(message) { parentWindow.postMessage(message, parentOrigin); }
  function retire() { active = false; clear(); window.removeEventListener("message", receive); }
  function requestId(value) { return typeof value === "string" || Number.isSafeInteger(value); }
  function receive(event) {
    if (!active || event.source !== parentWindow || event.origin !== parentOrigin) return;
    const data = event.data;
    if (!object(data) || data.jsonrpc !== "2.0") return;
    if (!ready) {
      if (!keys(data, ["jsonrpc", "id", "result", "error"]) || data.id !== initializeId) return;
      const result = data.result;
      if (Object.hasOwn(data, "error") || !object(result) || result.protocolVersion !== "2026-01-26"
        || !object(result.hostCapabilities) || !object(result.hostInfo)
        || !text(result.hostInfo.name, 200) || !text(result.hostInfo.version, 200)
        || !object(result.hostContext)) { retire(); return; }
      ready = true;
      send({ jsonrpc: "2.0", method: "ui/notifications/initialized" });
      return;
    }
    if (!keys(data, ["jsonrpc", "method", "params", "id"]) || typeof data.method !== "string") return;
    if (Object.hasOwn(data, "id")) {
      if (!requestId(data.id)) return;
      if (data.method === "ui/resource-teardown" && (data.params === undefined || object(data.params))) {
        send({ jsonrpc: "2.0", id: data.id, result: {} }); retire();
      } else if (data.method === "ping") send({ jsonrpc: "2.0", id: data.id, result: {} });
      return;
    }
    const params = data.params;
    if (data.method === "ui/notifications/tool-input") {
      if (inputReceived || !keys(params, ["arguments", "_meta"]) || !keys(params.arguments, ["work_id"])
        || !text(params.arguments.work_id, 128)) { retire(); return; }
      inputReceived = true;
    } else if (data.method === "ui/notifications/tool-result" && inputReceived) {
      if (validResult(params)) render(params.structuredContent); else clear();
    } else if (data.method === "ui/notifications/tool-cancelled" && object(params)) retire();
  }

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Escape") return;
    el("ap-panel").focus();
  });
  window.addEventListener("pagehide", retire, { once: true });
  if (parentWindow !== window && parentOrigin && /^https?:\/\//.test(parentOrigin)) {
    window.addEventListener("message", receive);
    send({ jsonrpc: "2.0", id: initializeId, method: "ui/initialize", params: {
      protocolVersion: "2026-01-26", appInfo: { name: "Astral Work status", version: "1.0.0" }, appCapabilities: {}
    } });
  }
})();
