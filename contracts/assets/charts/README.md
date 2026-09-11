# Offline native charts

Android, iOS, and macOS embed the existing Projection Plotly asset inside their
native chart component. The workspace, title, provenance, download controls, and
owner lifecycle stay native. watchOS retains its declared capability adaptation.

Run `python3 scripts/build_native_chart.py` after changing the web chart options,
vendored Plotly bytes, or web fonts. `--check` verifies the committed template.
The generator extracts the layout/traces/configuration block from `initCharts`
in `backend/webrender/static/client.js`; it does not maintain another option catalog.

Each native bundle contains `chart.html` plus the exact existing
`backend/webrender/static/vendor/plotly.min.js`. Replace
`__ASTRAL_PLOTLY_VENDOR__` with those literal UTF-8 bytes, then replace
`__ASTRAL_CHART_PAYLOAD_BASE64__` with base64-encoded UTF-8 JSON:

```json
{"component":{"type":"line_chart","labels":["A","B"],"datasets":[{"data":[1,2]}]},"viewport_width":1024}
```

The template hashes both executable scripts in CSP and prohibits network,
frames, objects, form submission, and base-URL changes. The native hosts also
deny navigation, network access, and persistent browser storage; neither exposes
a JavaScript-to-native action bridge or authentication credentials. Android
serves the document only for its exact synthetic main-document URL from memory.
Apple loads it into a nonpersistent WKWebView. Discarding a component stops and
clears its web view. Arbitrary component strings enter only through decoded JSON;
the normal Plotly HTML defanging rules still apply.

The host uses the actual chart slot width: below 500 logical pixels the height
is 260; otherwise the web viewport default is 240 below 640 or 320, with a Plotly
authored height bounded to 160–1200. The HTML applies the same bound. Remote-asset
charts fail visibly with a web-client handoff; a network failure is not success.

`html[data-chart-state]` exposes `loading`, `ready`, `empty`, or `error` for native
failure handling and tests. The real-browser regression suite is
`tooling/web-ci/tests/native-chart-088.spec.js`; native instrumentation additionally
checks each platform's actual WebView and lifecycle boundaries. Synthetic checks
do not replace authenticated client qualification against the live backend.
