# Render targets

Verified against the source tree on 2026-09-28. This page documents every
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
- Lists are kept only under `headers`, `rows` and `items`, serialized as JSON.
  Other nested lists and objects, such as chart data, are not serialized.
- Each block is capped at 64 KiB with a `[truncated]` marker, and nesting
  deeper than 12 becomes `[nested content omitted]`. A component with nothing
  portable becomes `[<type> component has no portable text representation]`.

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
