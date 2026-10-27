# Installed-wheel host example: ChatGPT MCP status and artifact panel

This directory is a minimal executable example for a developer who is **not** in this
repository: it consumes only the published `astralprojection` wheel from an installed
environment — no sibling checkout, no database, no provider credentials, and no
AstralDeep implementation import — and renders the bounded Astral Work status/artifact
panel for OpenAI MCP Extension ("ChatGPT") hosts. Projection renders and adapts; the host
owns authorization, the protocol envelope, task state, and security policy. This example
does not turn Projection into an orchestrator and does not move authorization into it.

It complements, and does not duplicate, `examples/mcp_a2a_host/` (Projection #34): that
example maps Projection's portable output into generic pinned MCP/A2A envelopes; this one
adds the specific resource-backed panel UI target declared in
[`docs/render-targets.md`](../../docs/render-targets.md) (the `chatgpt` render target).

## Pins

| What | Revision | Source of truth |
| --- | --- | --- |
| Projection wheel | `astralprojection==0.1.0` | `pyproject.toml` |
| Projection contract | `astralprojection.contract/v1` | `astralprojection.CONTRACT_VERSION` |
| UI protocol manifest | version and SHA-256 read from the installed wheel at runtime | `contracts/ui_protocol.json` |
| MCP SDK (validation only) | `mcp==2.3.0` | `envelopes.py` `MCP_SDK_PIN` |
| MCP schema/protocol revision | `2026-07-28` | `envelopes.py` `MCP_SCHEMA_REVISION` |

No new dependency is introduced: the panel renderer uses the Python standard library, the
existing `webrender` seams, and vanilla JavaScript/CSS embedded in the panel document.

## Run it

```bash
python -m pip install "astralprojection==0.1.0"
python examples/chatgpt_mcp_panel/example.py
```

The example prints one deterministic JSON document (fixed identifiers, sorted keys, no
clock, randomness, or network), so identical inputs produce byte-identical output. It
covers every panel state (waiting, running, input-required, failed, cancelled,
succeeded), host denials, a failed→running→succeeded recovery sequence, the no-panel-host
fallback, and the rejection of transport-shaped state.

## Target declaration and host capabilities

The `chatgpt` render target produces the pieces an OpenAI MCP Extensions host needs:

- `toolDescriptor` (`envelopes.tool_descriptor`) — a `tools/list` entry whose `_meta`
  carries the output-template metadata (`openai/outputTemplate` resource reference,
  `openai/toolInvocation/invoking` and `/invoked` strings, `openai/widgetAccessible`,
  `openai/resultCanProduceUI`).
- `resourcesReadResult` — the `resources/read` result for
  `ui://astralprojection/astral-work-status`: one `text/html` resource whose text is the
  static panel document (vanilla HTML/CSS/JS, no subresources, no network).
- `tool_result` — a `CallToolResult`-shaped envelope with bounded `content` text blocks
  and `structuredContent` holding the validated view model.

Required host capabilities, and what happens without them:

| Host capability | With support | Without support |
| --- | --- | --- |
| `openai/outputTemplate` metadata on tools | Host reads the template resource and renders the panel in a sandboxed iframe | Host ignores `_meta` and shows the `content` text blocks — full, usable status |
| `resources/read` for the template URI | Panel document is fetched once per tool declaration | Same fallback as above |
| `structuredContent` bridge to the widget (`window.openai.toolOutput` / `toolResponseMetadata`, or a postMessage carrying the view model) | Panel renders live status, progress and artifact links | Panel document shows its static notice and points to the assistant messages; text blocks remain complete |
| Inline scripts/styles allowed in the widget frame | Panel JS renders state with `textContent` only | Panel document degrades to the static notice; no partial state is invented |

The panel document never receives HTML from the view model: all dynamic text is set with
`textContent`, links are re-checked in JS against the same http(s)/mailto/root-relative
rule the server enforces, and Escape returns focus to the panel (or calls a
feature-detected host close hook when the bridge provides one).

## CSP and sandbox

The host should serve the panel resource (as `/panel` does in
`synthetic_host.py`) with:

```
Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline';
  style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; media-src 'none';
  connect-src 'none'; form-action 'none'; base-uri 'none'
```

The panel makes no network requests and loads no subresources, so `connect-src 'none'`
and `default-src 'none'` are safe. The document's own inline script and style are the
only inline code, source-reviewed in this repository. Embed the panel in an iframe with
`sandbox="allow-scripts"` and **without** `allow-same-origin` (as `/embed` shows), so the
widget cannot reach the host origin, cookies, or storage. If the host applies a stricter
CSP that blocks inline scripts, the document degrades to its static notice and the
conversation text blocks stay complete; nothing else changes.

## Security duties Projection deliberately does not own

- The host (AstralDeep or any integrating ChatGPT MCP host) authenticates the user,
  authorizes every surface and state field before building the view model, and scopes it
  per owner. Projection renders the state it is given and performs no authorization.
- The view model is accepted only in a closed, bounded shape (`kind`, `state`, `title`,
  `detail`, `status_message`, `progress`, `artifacts`); unknown keys — including
  `html`, `script`, `css`, `style`, `token`, `onclick` — are rejected
  (`InvalidPanelView`), artifact URLs are restricted to http(s), mailto and
  root-relative, media types to a closed allowlist, and every field is size-bounded.
- Task state comes only from the host's explicit view model. The renderer has no path
  that infers completion from a transport response; passing a `CallToolResult`-shaped
  payload as state is rejected (demonstrated in the report under
  `transportStateRejection`).
- Hosts must still redact secrets and bound output before emitting envelopes; the
  renderer's bounds are presentation limits, not a data-loss-prevention boundary.

## Verification status

- **Source review**: renderer, example, synthetic host and tests reviewed against the
  repository baseline named in the pull request; the OpenAI MCP Extensions spec was
  reviewed at the revision cited in the issue.
- **Offline tests**: `tests/webrender/test_chatgpt_panel.py` and
  `tests/interop/test_chatgpt_mcp_panel_example.py` are deterministic and offline; the
  interop suite builds the wheel from source and runs this example inside a venv holding
  only that installed wheel.
- **Live synthetic-host qualification**: `synthetic_host.py` serves the pinned document
  and envelopes over loopback HTTP under the declared CSP and sandbox posture, and
  `tests/interop` exercises it like the external host would, including the no-panel
  fallback and denial paths.
- **External-host and platform acceptance**: exercising the panel against the real
  ChatGPT host, and any platform/Docker acceptance, run in pull-request CI; the exact
  external bridge behavior (for example the close hook) is feature-detected at runtime so
  a mismatch degrades gracefully rather than failing.
- **Deployment**: none is performed or implied by this example; releases follow the
  owning repositories' protected release lanes.
