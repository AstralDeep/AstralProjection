# Installed-wheel MCP Apps status panel

The `chatgpt` rendering target produces a bounded Astral Work view, a self-contained
HTML resource, and complete MCP text content. Projection renders already-authorized
state; the integrating host owns authentication, owner binding, PHI filtering,
permissions, resource admission, cancellation, and current result delivery.

```bash
python -m pip install "astralprojection==0.1.0"
python examples/chatgpt_mcp_panel/example.py
```

The deterministic example covers all six work states, denial, recovery and text
fallback. It imports the installed wheel, without an AstralDeep or sibling source import.

## Protocol binding

The implementation follows [MCP Apps 2026-01-26 at the official SDK release source](https://github.com/modelcontextprotocol/ext-apps/blob/7af9a75da720b8a81be0f9aff47b25f75e9530ad/specification/2026-01-26/apps.mdx).
The base MCP envelope revision is `2025-11-25`. The [OpenAI reference](https://developers.openai.com/plugins/reference)
and [official migration guide](https://apps.extensions.modelcontextprotocol.io/api/documents/migrate-openai-app.html)
were checked on 2026-10-28. The owning test manifest and lock are
`tooling/web-ci/package.json` and `package-lock.json`: exact `@modelcontextprotocol/ext-apps@2.0.4`,
`@modelcontextprotocol/client@2.4.0`, `@modelcontextprotocol/core@2.4.0`, and `zod@4.6.7`.
These are development dependencies; the shipped renderer uses the standard library
and vanilla JavaScript, with no SDK or external subresource at runtime.

- Tool metadata declares `_meta.ui.resourceUri` and model-only visibility. The
  optional `openai/outputTemplate` alias is a URI string; `openai/widgetAccessible`
  is false. The panel issues no tool calls or product actions.
- `resources/read` returns `text/html;profile=mcp-app` at
  `ui://astralprojection/astral-work-status`, with `_meta.ui.csp` declaring empty
  connection, resource, frame and base-URI allowlists and no requested permissions.
- The view sends `ui/initialize`, validates the correlated response and exact UI
  revision, and emits `ui/notifications/initialized`. It accepts complete tool input
  once, followed by `ui/notifications/tool-result` notifications. Initial results
  and later deliveries use the same validated path. Transport success never implies
  work completion: only the explicit six-state view model determines the work state.
- The bridge requires `event.source === window.parent`, the exact parent origin
  derived from the browser-provided referrer, valid JSON-RPC envelopes, initialization
  correlation, and current input/lifecycle state. Missing/opaque referrers or unsupported
  initialization retain the static fallback. Integrators must preserve the sandbox
  origin referrer. There is no raw view-model message or legacy injected-global path.
- A malformed result or tool error clears displayed private content. A later valid
  result can recover. Tool cancellation, page retirement, duplicate tool input and
  `ui/resource-teardown` retire the channel, clear state and reject late updates.
  Teardown receives the matching JSON-RPC acknowledgement.

The host must advertise the `io.modelcontextprotocol/ui` extension with this MIME
before opting into resource UI. With no negotiated support, return the existing
`content` text blocks and omit UI tool metadata. Metadata alone is not negotiation.
The example's descriptor shows the UI-enabled case; the fallback scenario shows the
complete result for a host without resource UI.

## Isolation and presentation

A web host uses a sandbox proxy on a different origin, with `allow-scripts` and
`allow-same-origin`, and relays only the current view's messages. The inner view can
use the stricter `sandbox="allow-scripts allow-popups"` profile. `allow-popups` is
needed only to follow explicitly clicked artifact links. The browser test implements
the proxy-ready/resource-ready sequence and executes the actual resource HTML.

The document requires its reviewed inline script and style, but no network,
subresources, nested frames, forms or storage. A suitable additional serving CSP is:

```text
default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline';
connect-src 'none'; img-src 'none'; frame-src 'none'; object-src 'none';
base-uri 'none'; form-action 'none'
```

A stricter host CSP can block scripts; the document's static notice and complete
conversation text remain usable. Resource metadata carries the standard host CSP
allowlists. The host applies the policy in its sandbox; Projection does not bypass it.

Both server and browser validate the closed view model, bounds, MIME allowlist,
progress integers and artifact links. Dynamic text uses `textContent`; artifacts are
links rather than inline content. Links allow valid HTTP(S), mail recipients and
root-relative paths, rejecting credentials, backslashes, protocol-relative URLs,
whitespace and empty/malformed authorities. Links use `noopener noreferrer`.
The panel provides status/live semantics, progress labels, reduced motion, keyboard
focus, and Escape focus return. It does not claim native-client support or change
shared protocol vocabulary.

## Qualification and limits

`tests/webrender/test_chatgpt_panel.py` and `tests/interop/test_chatgpt_mcp_panel_example.py`
validate Python behavior and the freshly built installed-wheel example.
`synthetic_host.py` serves HTTP/envelope fixtures; its `exercise()` checks HTTP bytes
and fallback envelopes only. Its static `/embed` scaffold does not execute a host bridge.

`tooling/web-ci/tests/chatgpt-panel.spec.js` executes an installed-wheel document in
Chromium with the official pinned AppBridge, real iframe `postMessage`, two loopback
origins and an opaque inner sandbox. It checks initialization, initial/delayed and
multiple results, all states, XSS, artifact clicks, malformed/foreign/raw messages,
input binding, revocation, cancellation, teardown, CSP isolation and no-host fallback.
The test does not authenticate a user or impersonate ChatGPT.

Actual ChatGPT connector acceptance remains pending and is not performed by CI.
It requires the user's real host connection, the integrating server's authorized
resource route, and current synthetic-backend/identity qualification. This component
must qualify at its exact revision before Deep adopts its pin. No deployment, release,
schema migration, default change or issue-acceptance claim is implied.
