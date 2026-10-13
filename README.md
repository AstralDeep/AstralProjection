# AstralProjection

AstralProjection is the independent presentation and client release unit for
the Astral system. It owns deterministic server rendering, ROTE capability
adaptation, the shared UI protocol, web assets, and the Windows, Android, and
Apple clients. Authentication, authorization, orchestration, policy, and
durable state remain outside this repository.

The package preserves the public Python import names `webrender` and `rote`
while exposing stable metadata, resources, view models, and pure chrome
builders through `astralprojection`.

## Current web experience: UI v2

[UI v2](docs/UI_V2.md) documents the current web console, its source ownership,
the desktop and responsive control placement, native-client scope, and the
local verification results. UI v2 names the web design checkpoint; it does not
rename the Python package version or the shared wire protocol.

[Render targets](docs/render-targets.md) documents each target registered with
`webrender.registry`, how it is selected, what it renders, and which clients
consume it.

## Consuming Projection from an installed wheel

[examples/mcp_a2a_host/](examples/mcp_a2a_host/) is a minimal executable example for a
developer outside this repository: it consumes only the published `astralprojection`
wheel, adapts owner-authorized astralprims primitives with ROTE, and maps the portable
output into pinned MCP (`mcp==2.3.0`, schema revision 2026-07-28) and A2A
(`a2a-sdk==1.2.2`, protocol revision 1.0) envelopes. Its
[README](examples/mcp_a2a_host/README.md) documents the public imports, resource
accessors, upgrade compatibility, and the host's security responsibilities;
`tests/interop/` keeps the example deterministic and schema-checked.

## Repository layout

- `src/astralprojection/` — stable contracts, packaged-resource access, and
  host-neutral presentation models/builders.
- `backend/webrender/` — deterministic renderers, sanitization, accessibility,
  templates, and static assets.
- `backend/rote/` — device capability and level-of-detail adaptation.
- `contracts/` — authoritative UI protocol and cross-client fixtures.
- `windows-client/`, `android-client/`, `apple-clients/` — thin native clients
  retaining their registered AstralDeep product/store identities.
- `tooling/web-ci/` and `tests/` — browser tooling and standalone verification.
- `provenance/` — immutable extraction manifest and reviewed transformation
  ledger for the AstralDeep decomposition.
- `.github/workflows/ci.yml`, `.github/workflows/android-ci.yml`, and
  `.github/workflows/apple-ci.yml` — active read-only, secret-free owner CI for
  core Python/web/Windows, Android, and Apple qualification respectively.
- `workflows-disabled/` — six release workflows whose eight jobs remain
  unconditionally disabled pending a separately authorized activation change.

Three owner CI workflows are active and read-only/secret-free. They qualify the
core Python/web/Windows, Android, and Apple owner surfaces; they do not sign,
publish, deploy, or submit artifacts. Six release workflows remain disabled under `workflows-disabled/`.
The community points bot credits the author of a linked bounty PR after it
merges into `main` and closes the bounty. Contributors can open a PR directly;
see the [contribution and points guide](https://astraldeep.github.io/contribute.html).
Those release workflows intentionally preserve
some references to legacy protected-policy and release-evidence tooling that
was not extracted into this repository. They are historical design inputs, not
runnable release automation. Release activation requires an explicit follow-up
that inventories and rebuilds every missing protected input in
AstralProjection, re-runs local and provider-native qualification, and receives
separate release authorization.

## Local verification

Use Python 3.11:

```powershell
python -m pip install -e ".[dev]"
python -m pytest -q
ruff check src backend tests scripts
python -m build
```

All three owner workflows report on every PR and main push. Native applicability
uses the immutable event base and head, including deleted paths. Shared contracts,
server-owned chrome, ROTE, tooling, workflow, and coverage-script changes require both native lanes.
Unrelated web or Windows edits record native lanes as not applicable; unexpected
skips, failed classification, cancellations, and missing results fail closed.
Main rules require `required`, `Required · Android aggregate`, and
`Required · Apple aggregate`, with the branch up to date before merge.
The immutable review receipt flags removed tests, added skips, swallowed test errors,
and qualification-policy changes for maintainer scrutiny.

Platform-specific client gates remain documented in each client directory.
Apple compilation and signing require macOS/Xcode; Android release signing and
all store submissions require operator-owned credentials and external store
checks. Nothing in this repository authorizes a release or store upload.

## Integration boundary

### Public offline document (088)

After an online visit installs the service worker, an unavailable network at `/`
shows a separate public disconnected page with a keyboard-accessible retry link.
It does not provide offline conversation, file, draft, or account access. Online
authentication redirects and server errors retain their normal behavior.

The packaged `static/service-worker.js` only caches the six exact public
resources listed in `scripts/build_offline_assets.py`. Anonymous, no-store fetches
must match the packaged MIME type, size, and SHA-256 before caching; cached reads
repeat these checks and discard corrupt entries before anonymous refetch. Shell HTML,
API/auth routes, query-bearing URLs, executable application scripts, user state,
and third-party responses are excluded. Cache upgrades remove only this worker's
own old public namespace. Offline HTML has no script or form and a restrictive CSP.

The host must serve that worker with `Service-Worker-Allowed: /`, `Cache-Control:
no-cache`, and `Content-Security-Policy: default-src 'none'; connect-src 'self'`.
Deep applies these headers only to this worker. HTTPS or a browser-trusted loopback
origin is required; worker failure leaves the normal online application usable.

After changing an allowlisted resource, regenerate its content pins with
`python scripts/build_offline_assets.py`; `--check` verifies without writing.
Package tests enforce byte freshness, and the worker unit/real Chromium tests
cover privacy exclusions, failure, update cleanup, narrow layout, and reconnect.

### Authorized state

AstralDeep supplies already-authorized, owner-scoped plain state to the pure
view builders and consumes their immutable models. AstralProjection does not
import AstralDeep implementation packages. The authoritative protocol version
and digest are available as `astralprojection.UI_PROTOCOL_VERSION` and
`astralprojection.UI_PROTOCOL_SHA256`.

[Mesh device controls](docs/mesh-enrollment.md) describes the shared management
actions, joining-device key custody, two-device confirmation and client scope.

Canonical repository: <https://github.com/AstralDeep/AstralProjection>
