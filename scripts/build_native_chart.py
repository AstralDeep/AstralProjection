#!/usr/bin/env python3
"""Build a network-free native chart shell from the authoritative web options.

No runtime dependency is added. Native builds bundle this template and the
already-pinned Plotly asset separately, then substitute only exact vendor bytes
and a base64-encoded JSON envelope. Run with --check in drift verification.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "contracts/assets/charts/chart.html"


def digest(value: str) -> str:
    return base64.b64encode(hashlib.sha256(value.encode()).digest()).decode()


def build() -> str:
    client = (ROOT / "backend/webrender/static/client.js").read_text()
    start = client.index("      var layout = {", client.index("  function initCharts(root)"))
    end = client.index("      try {\n        el._astralPlotReady", start)
    options = client[start:end].replace("window.innerWidth", "viewportWidth")
    # The copied block is normally inside a loop; this shell renders one chart.
    options = options.replace("else continue;", "else throw new Error('Unsupported chart type');")
    vendor = (ROOT / "backend/webrender/static/vendor/plotly.min.js").read_text()
    if "</script" in vendor.lower():
        raise ValueError("Plotly cannot be embedded without changing its exact bytes")
    fonts = []
    for family, filename, weight in (
        ("Inter", "inter-latin.woff2", "400 700"),
        ("JetBrains Mono", "jetbrains-mono-latin.woff2", "400"),
    ):
        encoded_font = base64.b64encode(
            (ROOT / "backend/webrender/static/fonts" / filename).read_bytes()
        ).decode()
        fonts.append(
            f"@font-face{{font-family:'{family}';font-style:normal;font-weight:{weight};"
            f"src:url(data:font/woff2;base64,{encoded_font}) format('woff2')}}"
        )
    script = r'''(function () {
  "use strict";
  var el = document.getElementById("chart");
  var status = document.getElementById("status");
  function fail() {
    document.documentElement.dataset.chartState = "error";
    status.textContent = "This chart could not be displayed. Open it in the web client.";
    status.hidden = false;
  }
  // Same defanging rules as webrender.renderer._scrub_plotly_html. The native
  // shell also denies network, navigation, frames, and privileged action bridges.
  function scrub(value) {
    if (Array.isArray(value)) return value.map(scrub);
    if (value && typeof value === "object") {
      var out = Object.create(null);
      Object.keys(value).forEach(function (key) { out[key] = scrub(value[key]); });
      return out;
    }
    if (typeof value !== "string") return value;
    return value.replace(/<\s*script[\s\S]*?>[\s\S]*?<\s*\/\s*script\s*>/gi, "")
      .replace(/<\s*\/?\s*(script|iframe|object|embed|svg|img|link|meta|style)\b[^>]*>/gi, "")
      .replace(/\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "")
      .replace(/javascript:/gi, "");
  }
  try {
    var encoded = document.getElementById("payload").content;
    if (encoded.length > 12 * 1024 * 1024) throw new Error("Chart too large");
    var envelope = JSON.parse(new TextDecoder("utf-8", {fatal:true}).decode(
      Uint8Array.from(atob(encoded), function (character) { return character.charCodeAt(0); })));
    var c = envelope.component;
    if (!c || typeof c !== "object" || Array.isArray(c)) throw new Error("Missing chart");
    var viewportWidth = Number(envelope.viewport_width) || window.innerWidth;
    var kind = {bar_chart:"bar",line_chart:"line",pie_chart:"pie",plotly_chart:"plotly"}[c.type];
    if (!kind) throw new Error("Unsupported chart type");
    var spec;
    if (kind === "plotly") spec = {data:scrub(c.data || []),layout:scrub(c.layout || {}),config:c.config || {}};
    else if (kind === "pie") spec = {labels:c.labels || [],data:c.data || [],colors:c.colors || []};
    else spec = {labels:c.labels || [],data:((c.datasets || [])[0] || {}).data || []};
    if (!spec.data.length) {
      document.documentElement.dataset.chartState = "empty";
      status.textContent = "No chart data.";
      return;
    }
    el.setAttribute("aria-label", c.title ? String(c.title) : "Chart");
__WEB_OPTIONS__
    // The surrounding native component owns the maximum visible rectangle.
    // No remote data or token is exposed to this isolated document.
    layout.height = Math.min(1200, Math.max(160, Number(layout.height) || 320));
    Promise.resolve(Plotly.newPlot(el, traces, layout, cfg)).then(function () {
      document.documentElement.dataset.chartState = "ready";
      status.hidden = true;
      if (typeof ResizeObserver !== "undefined") new ResizeObserver(function () {
        Promise.resolve(Plotly.Plots.resize(el)).catch(fail);
      }).observe(el);
    }).catch(fail);
  } catch (error) { fail(); }
})();'''.replace("__WEB_OPTIONS__", options)
    csp = (
        "default-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; "
        "base-uri 'none'; form-action 'none'; worker-src blob:; "
        "img-src data: blob:; font-src data:; style-src 'unsafe-inline'; "
        f"script-src 'sha256-{digest(vendor)}' 'sha256-{digest(script)}'"
    )
    return f'''<!doctype html>
<!-- Generated by scripts/build_native_chart.py; do not edit by hand. -->
<html lang="en" data-chart-state="loading"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="{csp}">
<meta id="payload" content="__ASTRAL_CHART_PAYLOAD_BASE64__">
<style>{''.join(fonts)}html,body{{margin:0;padding:0;background:transparent;width:100%;overflow:hidden}}#chart{{width:100%;min-height:160px}}#status{{font:14px Inter,system-ui;color:#9CA3AF;padding:12px}}</style>
</head><body><div id="chart" role="img"></div><p id="status" role="status">Loading chart…</p>
<script>__ASTRAL_PLOTLY_VENDOR__</script><script>{script}</script></body></html>
'''


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    expected = build()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != expected:
            raise SystemExit("Native chart template drifted; run scripts/build_native_chart.py")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(expected)


if __name__ == "__main__":
    main()
