# AstralProjection

AstralProjection is the independent presentation and client release unit for
the Astral system. It owns deterministic server rendering, ROTE capability
adaptation, the shared UI protocol, web assets, and the Windows, Android, and
Apple clients. Authentication, authorization, orchestration, policy, and
durable state remain outside this repository.

The package preserves the public Python import names `webrender` and `rote`
while exposing stable metadata, resources, view models, and pure chrome
builders through `astralprojection`.

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
- `.github/workflows/ci.yml` — active read-only CI for the Python package,
  web tooling, and Windows client.
- `workflows-disabled/` — Android, Apple, candidate, and release workflows
  held inert until final local qualification and an explicit activation change.

Core Python, web, and Windows CI is active. The disabled release workflows
intentionally preserve some references to
legacy protected-policy and release-evidence tooling that was not extracted
into this repository. They are historical design inputs, not runnable release
automation; Android and Apple workflows also remain inert. Activation requires
an explicit follow-up that inventories and
rebuilds every missing protected input in AstralProjection, re-runs local and
provider-native qualification, and receives separate release authorization.

## Local verification

Use Python 3.11:

```powershell
python -m pip install -e ".[dev]"
python -m pytest -q
ruff check src backend tests scripts
python -m build
```

Platform-specific client gates remain documented in each client directory.
Apple compilation and signing require macOS/Xcode; Android release signing and
all store submissions require operator-owned credentials and external store
checks. Nothing in this repository authorizes a release or store upload.

## Integration boundary

AstralDeep supplies already-authorized, owner-scoped plain state to the pure
view builders and consumes their immutable models. AstralProjection does not
import AstralDeep implementation packages. The authoritative protocol version
and digest are available as `astralprojection.UI_PROTOCOL_VERSION` and
`astralprojection.UI_PROTOCOL_SHA256`.

Canonical repository: <https://github.com/AstralDeep/AstralProjection>
