# Installed-wheel host example: MCP and A2A presentation interoperability

This directory is a minimal executable example for a developer who is **not** in this
repository: it consumes only the published `astralprojection` wheel from an installed
environment — no sibling checkout, no database, no provider credentials, and no
AstralDeep implementation import — and maps Projection's portable output into pinned
MCP and A2A SDK envelopes. Projection renders and adapts; the host owns the protocol
envelope, task state, and security policy. This example does not turn Projection into
an orchestrator and does not move authorization into it.

## Pins

| What | Revision | Source of truth |
| --- | --- | --- |
| Projection wheel | `astralprojection==0.1.0` | `pyproject.toml` |
| Projection contract | `astralprojection.contract/v1` | `astralprojection.CONTRACT_VERSION` |
| UI protocol manifest | version and SHA-256 read from the installed wheel at runtime (`astralprojection.UI_PROTOCOL_VERSION`, `astralprojection.UI_PROTOCOL_SHA256`) | `contracts/ui_protocol.json` |
| Primitives | `astralprims==0.4.0` (Projection's own pinned dependency) | AstralPrimitives release train |
| MCP SDK | `mcp==2.3.0` | `envelopes.py` `MCP_SDK_PIN` |
| MCP schema/protocol revision | `2026-07-28` (`mcp_types.version.LATEST_PROTOCOL_VERSION`) | `envelopes.py` `MCP_SCHEMA_REVISION` |
| A2A SDK | `a2a-sdk==1.2.2` | `envelopes.py` `A2A_SDK_PIN` |
| A2A protocol revision | `1.0` (`a2a.utils.constants.PROTOCOL_VERSION_CURRENT`, wire namespace `lf.a2a.v1`) | `envelopes.py` `A2A_PROTOCOL_REVISION` |

## Run it

```bash
python -m pip install "astralprojection==0.1.0"
python examples/mcp_a2a_host/example.py
```

The example needs only the wheel and its declared dependencies. It prints one
deterministic JSON document (fixed identifiers, sorted keys, no clock, randomness, or
network), so identical inputs produce byte-identical output. To additionally validate
the generated envelopes with the official SDK types:

```bash
python -m pip install "mcp==2.3.0" "a2a-sdk==1.2.2"
python -m pytest tests/interop -q
```

`tests/interop/test_mcp_a2a_host_example.py` runs the example twice in a sanitized
environment (no `PYTHONPATH`, isolated working directory) and asserts byte-identical
output, rebuilds the wheel from source into a clean venv and runs the example against
that installed wheel only, validates every generated envelope against the pinned MCP
and A2A schema shapes, and — when the SDKs are installed — round-trips the same
envelopes through `mcp.types.CallToolResult` and `a2a.types` protobuf parsing.

## What the example demonstrates

1. **Owner-authorized state input** — `AUTHORIZED_STATE` stands in for state the host
   has already authorized and scoped to the owner. Projection never sees credentials or
   performs any authorization decision; it renders the state it is given.
2. **Primitive `to_dict` serialization** — `astralprims` models (`Alert`, `MetricCard`,
   `BarChart`, `Table`, `Text`) serialize to plain wire dicts, the format every
   Projection seam consumes.
3. **Capability adaptation** — `rote.capabilities.DeviceProfile.from_dict` builds a
   watch profile; `rote.adapter.ComponentAdapter.adapt` degrades content to what the
   device supports (the bar chart becomes a condensed metric).
4. **Portable fallback** — the registered `mcp` render target
   (`webrender.targets.mcp_renderer.install()` + `webrender.registry.render_for_target`)
   turns components it cannot natively express — including a hypothetical
   `timeline_widget` type from a newer primitives release — into readable portable text
   instead of dropping them, and the web `render()` path emits a labeled placeholder for
   unknown types.
5. **Error mapping** — a real Projection error (`astralprojection.InvalidResourcePath`
   from a traversal attempt), a missing-input error, and a host policy denial map to
   `isError` MCP results and `TASK_STATE_FAILED`, `TASK_STATE_INPUT_REQUIRED`, and
   `TASK_STATE_REJECTED` A2A states (`envelopes.map_exception_to_state`).
6. **Bounded and redacted output** — ROTE bounds text to the device profile
   (`max_text_chars` for watch); the host layer additionally redacts secret-shaped
   strings and secret-named keys (`envelopes.redact`), bounds oversized text with a
   SHA-256 marker (`envelopes.bound_text`), and replaces an oversized artifact data part
   with a deterministic truncated summary.

## Public imports the wheel guarantees

- `astralprojection` — `CONTRACT_VERSION`, `UI_PROTOCOL_VERSION`, `UI_PROTOCOL_SHA256`,
  `__version__`, and the resource accessors (`notice_path`, `resource_sha256`,
  `static_path`, `contract_root`, `fixture_path`, and companions; see
  `src/astralprojection/resources.py`).
- `astralprims` — the primitive models and `Primitive.to_dict` (defined upstream; this
  wheel pins the compatible revision).
- `rote` — `DeviceProfile`, `DeviceCapabilities`, `ComponentAdapter` (capability-keyed
  adaptation and the fallback ladders).
- `webrender` — `render`, `render_one`, `render_for_target`, `register_target`
  (deterministic, escape-by-default rendering and the render-target seam).

## Resource accessors

The example reads packaged resources through the accessors rather than filesystem
paths: `notice_path()` plus `resource_sha256()` pin the vendored notice, and
`static_path("../escape")` demonstrates that the accessors reject unsafe segments with
`InvalidResourcePath`. Resources resolve from the installed distribution, so they work
identically in a wheel-only environment.

## Upgrade compatibility

- Projection follows semantic versioning; `astralprojection.contract/v1` and the UI
  protocol version/digest are the stable compatibility markers. Pin the wheel revision
  and verify `UI_PROTOCOL_SHA256` after upgrades, exactly as AstralDeep does.
- The UI protocol manifest evolves additively: unknown component types from a newer
  primitives release degrade to the declared portable fallbacks shown in the example
  instead of failing.
- `envelopes.py` is host-side code: bump the `MCP_*`/`A2A_*` pins deliberately and
  re-run the schema conformance and SDK validation tests when you upgrade either SDK.

## Host security responsibilities

Projection deliberately does **not** do these things; the integrating host must:

- Authenticate the user, authorize every surface and state field before handing them to
  Projection, and scope state per owner (Projection holds no authorization and no
  durable state).
- Redact secrets and bound output before emitting protocol envelopes (the example's
  `envelopes.redact`/`bound_text` is a starting point, not a complete policy).
- Own task/agent lifecycle and A2A state transitions, artifact identifiers, and transport
  security; Projection output is presentation data, not a trust boundary.
- Serve rendered web HTML under its own nonce-based CSP and keep the web token handling
  on the host side, as the repository constitution requires for the first-party web
  shell.
