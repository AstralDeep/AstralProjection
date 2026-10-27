# Render targets

Verified against the source tree on 2026-10-27. This page documents every
render target of [`webrender.registry`](../backend/webrender/registry.py), as
Constitution Principle II requires: how each is registered and selected, what
it produces, and which clients consume it.

## Registration and selection

- `TARGET_RENDERERS` holds three built-in targets: `web`, `voice` and `aom`.
  Other targets are added with `register_target(name, renderer)`, which stores
  the name exactly as given and replaces any earlier renderer of that name.
  The modules in [`webrender/targets/`](../backend/webrender/targets/) do this
  from an `install()` function.
- `render_for_target(target, components, profile)` lowercases the requested
  name, so a target must be registered in lowercase to be reachable. An unknown
  or missing name logs a warning and falls back to `web`.
- `target_for_profile(profile)` returns `web` unless `FF_NATIVE_TARGETS` is
  `1`, `true`, `yes` or `on`. With the flag on it uses the profile's
  `render_target` when that names a registered target, then `voice` for a
  profile whose `device_type` is `voice`, and otherwise `web`. The ROTE
  `DeviceProfile` ([`capabilities.py`](../backend/rote/capabilities.py)) has no
  `render_target` field, so only a caller-supplied object can name one.
- The host (AstralDeep) calls `render_for_target(target_for_profile(profile), ...)`
  for non-canvas UI frames and streamed chunks and puts the result in the
  frame's `html` field. Canvas frames use `render_workspace` from
  [`renderer.py`](../backend/webrender/renderer.py) instead.

## Targets at a glance

| Target | Registered by | Output | Consumed by |
| --- | --- | --- | --- |
| `web` | Built in; the default and the fallback | HTML string | The web shell ([`client.js`](../backend/webrender/static/client.js)) |
| `voice` | Built in | SSML string | No client in this repository registers a `voice` device; AstralDeep calls `render_voice` directly for watch speech |
| `aom` | Built in | Accessibility-object-model dict tree | No client consumes it |
| `mcp` | [`targets/mcp_renderer.py`](../backend/webrender/targets/mcp_renderer.py) `install()` | List of MCP text content blocks | AstralDeep's MCP server endpoint, for MCP clients |
| `chatgpt` | [`targets/chatgpt_panel.py`](../backend/webrender/targets/chatgpt_panel.py) `install()` | Bounded panel document, validated view model, and MCP text blocks | OpenAI MCP Extension (ChatGPT-style) hosts via AstralDeep's MCP server endpoint, and [`examples/chatgpt_mcp_panel/`](../examples/chatgpt_mcp_panel/README.md) |
| `stubtext` | [`targets/stub_renderer.py`](../backend/webrender/targets/stub_renderer.py) `install()` | Escaped plain text | Tests only |

The Windows, Android and Apple clients do not consume any target's output.
They render the structured `components` of each frame themselves
([`app.py`](../windows-client/astral_client/app.py),
[`Wire.kt`](../android-client/core/src/main/kotlin/com/personalailabs/astraldeep/core/protocol/Wire.kt),
[`Frames.swift`](../apple-clients/AstralCore/Sources/AstralCore/Protocol/Frames.swift)).

## `web`

- `render(components, profile)` wraps the rendered components in
  `<div class="dynamic-renderer space-y-3">`. It ignores `profile`; ROTE has
  already adapted the components for the device.
- Text is escaped first. Markdown goes through
  [`sanitize.py`](../backend/webrender/sanitize.py), which re-adds only a fixed
  markup subset. `safe_url` passes only `http(s)`, `mailto`, root-relative and
  scheme-less relative URLs plus `data:image/` and `data:audio/` sources, and
  replaces anything else with `#`. Attribute pass-through refuses author-set
  `data-ui-*` attributes.
- A type with no renderer becomes an `astral-unsupported` placeholder that
  names the type. A renderer that raises becomes an `astral-render-error`
  placeholder. Neither is silently dropped.
- The web shell inserts the `html` of UI frames and initializes charts from the
  rendered placeholders.

## `voice`

- `render_voice(components, profile)` in
  [`voice.py`](../backend/webrender/voice.py) returns
  `<speak>...</speak>`: one `<s>` sentence per spoken item, joined by 400 ms
  breaks. It ignores `profile`.
- Text is escaped with `html.escape(quote=False)`, and the markdown characters
  `` * _ ` # ~ [ ] `` are stripped before speaking.
- It speaks structure rather than flattening it. Lists and key-value items stop
  at 12 (lists add "and N more"), tables at 8 rows (adding "and N more rows"),
  and timelines at 10 items. Charts and code blocks are announced rather than
  read out, dividers, skeletons and images are silent, and any other type
  speaks its title and content.
- Selection needs `FF_NATIVE_TARGETS` and a `voice` device profile. The web,
  Windows, Android and Apple clients register other device types. AstralDeep's
  watch speech calls `render_voice` directly, outside the registry, and the
  watchOS app plays the SSML with `AVSpeechUtterance`
  ([`Speaker.swift`](../apple-clients/AstralWatch/Speaker.swift)), falling back
  to the plain text.

## `aom`

- `render_aom(components, device)` in [`aom.py`](../backend/webrender/aom.py)
  returns `{"role": "document", "name": ..., "children": [...]}`. The name is
  `device` when that is a non-empty string, otherwise `canvas`, so a profile
  object yields `canvas`.
- Each node carries a role, name and state. Unknown types get the role
  `generic`, names are capped at 120 characters, and depth is capped at 12,
  below which a subtree becomes a single leaf. Tables become a row-and-column
  summary, and tabs contribute their labels.
- The output is data, not markup, so nothing is escaped.
- It is selected only by name: `render_for_target("aom", ...)`, or a
  `render_target` of `aom` with `FF_NATIVE_TARGETS` on. `aom_enabled()` reads
  `FF_AOM_RENDERER`, but `render_aom` does not consult it.

## `mcp`

- `install()` registers `render_mcp`. AstralDeep's MCP server endpoint calls
  `install()` when it mounts and calls `render_mcp` directly for tool results.
- `render_mcp(components, profile)` returns one `{"type": "text", "text": ...}`
  block per component dict and ignores `profile`. Text components use their
  `content`, alerts become `variant: message`, and other types become
  `key: value` lines, recursing into `content` and `children`.
- Keys in `_PRIVATE_KEYS` (`action`, `attributes`, `component_id`, `css`,
  `events`, `handler`, `html`, `onclick`, `owner_user_id`, `payload`,
  `script`, `token`) are dropped, compared case-insensitively.
- Lists are kept only under `headers`, `rows` and `items`, serialized as JSON
  by the same bounded walk: nesting deeper than 12 becomes
  `"[nested content omitted]"`, private keys are dropped at every level, and a
  list that stops early closes its brackets and carries a `"[truncated]"`
  element. Other nested lists and objects, such as chart data, are not serialized.
- Output is bounded in UTF-8 bytes while it is built, never by serializing an
  unbounded intermediate: each block is at most 64 KiB including its
  `\n[truncated]` marker, one render emits at most 256 component blocks whose
  text totals at most 256 KiB, the traversal visits at most 20000 nodes per
  render, and truncation only ever cuts between whole Unicode scalars (lone
  surrogates become U+FFFD). When limits drop components, one trailing
  `[result truncated: N component(s) omitted]` block is appended when it fits
  the remaining result budget. A component with nothing portable becomes
  `[<type> component has no portable text representation]`.

## `chatgpt`

- `install()` registers `render_chatgpt_panel_target` under the lowercase name
  `chatgpt`. The target renders the Astral Work status/artifact panel for OpenAI MCP
  Extension hosts: a static vanilla HTML/CSS/JS panel document served as a
  `text/html` resource (`ui://astralprojection/astral-work-status`), the validated view
  model for the host's widget bridge, and bounded MCP text content blocks for every
  other surface.
- Unlike `mcp`, this target does not project arbitrary component trees: its registry
  callable accepts exactly one panel view-model object (a one-element list carrying a
  dict) and raises `InvalidPanelView` otherwise. The view model is a closed, bounded
  shape: `kind` must be `astral_work_status`, `state` must be one of `waiting`,
  `running`, `input_required`, `failed`, `cancelled` and `succeeded`, `title`, `detail`,
  `status_message`, `progress` (only while running, with `0 <= completed <= total`), and
  at most 8 `artifacts` are accepted; any other top-level or artifact key — including
  `html`, `script`, `css`, `style`, `token` and `onclick` — is rejected. Strings are
  bounded (title 200, detail 2000, message 500, artifact fields 128/200/200), lone
  surrogates become U+FFFD, and control characters other than newline and tab are
  rejected.
- Artifact links are restricted to `http(s)`, `mailto:` and root-relative URLs of at
  most 2048 characters without whitespace; `media_type` must match one allowlisted MIME
  type exactly (`text/plain`, `text/markdown`, `text/csv`, `text/html`,
  `application/json`, `application/pdf`, `image/png`, `image/jpeg`, `image/webp`), and
  `size_bytes` must be an integer within `0..2^40`. The panel only links artifacts; it
  never renders them inline. The document's JavaScript re-checks every URL against the
  same rule and renders all dynamic text with `textContent`, so authored HTML, scripts
  and untrusted styling cannot reach the widget even if a future host bridge changed.
- Every state is rendered truthfully from the view model alone. The renderer has no
  path that infers completion from a transport response: a `CallToolResult`-shaped
  payload is rejected like any other non-conforming input, and the document's static
  default is a neutral "status unavailable" notice, never a completion state.
- `render_chatgpt_panel(view_model)` returns `kind`, `resource` (the descriptor plus the
  full document text), `structuredContent` (the validated view model, JSON-safe),
  `content` (text blocks routed through the bounded `mcp` renderer), and `metadata`
  (the `_meta` fragment: `openai/outputTemplate`, `openai/toolInvocation/invoking`,
  `openai/toolInvocation/invoked`, `openai/widgetAccessible` set to false, and
  `openai/resultCanProduceUI`). Hosts without the extension ignore the metadata and
  bridge and surface the text blocks, which carry the complete status; a host serving
  the document under a stricter CSP that blocks inline scripts gets the document's
  static notice instead of the live widget. The recommended serving posture — a
  `default-src 'none'` CSP with no network or subresources and an
  `iframe sandbox="allow-scripts"` without `allow-same-origin` — is documented in
  [`examples/chatgpt_mcp_panel/README.md`](../examples/chatgpt_mcp_panel/README.md).
- The document carries `role="status"` with `aria-live="polite"`, a
  `role="progressbar"` when determinate progress exists, a labelled `region`, visible
  `:focus-visible` outlines, reduced-motion support, and Escape handling that returns
  focus to the panel (or calls a feature-detected host close hook).
- The Windows, Android and Apple clients do not consume this target, and no
  `contracts/ui_protocol.json` vocabulary changes: the panel input is a target-local
  view model, not a component type. The OpenAI metadata key names follow the MCP
  Extensions output-template pattern reviewed for this issue; the external ChatGPT host
  and platform acceptance run in pull-request CI, and the synthetic host in
  `examples/chatgpt_mcp_panel/` qualifies the serving posture over loopback HTTP.

## `stubtext`

- `install()` registers `render_stub`, a minimal second target that proves the
  registration seam without depending on the web renderer.
- It returns the escaped `content` of top-level `text` components joined by
  newlines and emits nothing for other types.
- Only [`test_renderer_seam.py`](../tests/webrender/test_renderer_seam.py)
  installs it; no client or host path does.

## Adding a target

Add a module under `webrender/targets/` whose `install()` calls
`register_target` with a lowercase name, degrade every type it cannot render
to a declared fallback or labeled placeholder, add tests beside the existing
ones, and document the target on this page.

## Tests

[`test_target_registry.py`](../tests/webrender/test_target_registry.py),
[`test_renderer_seam.py`](../tests/webrender/test_renderer_seam.py),
[`test_unsupported.py`](../tests/webrender/test_unsupported.py),
[`test_voice_renderer.py`](../tests/webrender/test_voice_renderer.py),
[`test_aom.py`](../tests/webrender/test_aom.py) and
[`test_mcp_renderer.py`](../tests/webrender/test_mcp_renderer.py) pin the
behavior described here.
