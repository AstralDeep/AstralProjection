# AstralProjection Constitution

## Core Principles

### I. Presentation Boundary

AstralProjection is the presentation and client release unit of the Astral platform:
AstralPrimitives defines → AstralProjection renders and adapts → AstralDeep orchestrates. It
owns server-side rendering and sanitization (`backend/webrender/`), device capabilities and
adaptation (`backend/rote/`), the UI protocol manifest (`contracts/ui_protocol.json`), web
assets, reusable chrome, and the Windows, Android, and Apple clients.

- Projection MUST NOT authenticate, authorize, orchestrate, own product policy, or hold
  durable server state. Chrome builders render state the host has already authorized; the
  host (AstralDeep) owns surface discovery, authorization, and dispatch.
- Server-side Python MUST NOT import AstralDeep packages;
  `tests/architecture/test_dependency_direction.py` enforces this and MUST stay green.
- Approved languages per surface are Python compatible with 3.11 (server code and the PySide6
  Windows client), vanilla JavaScript and CSS (web), Kotlin with Compose (Android), Swift with
  SwiftUI (Apple), and C# on .NET (the Windows speech helper). Another language requires an
  amendment.
- No standalone single-page application framework may become a source of truth for UI.

**Rationale**: Keeping authority in the host and presentation here lets every client share
one renderer and one contract without any of them becoming a policy decision point.

### II. Deterministic, Escape-by-Default Rendering

- `backend/webrender/sanitize.py` is the renderer's only formatting path: model- and
  user-supplied text is escaped first and only a fixed markup subset is re-added; links are
  limited to `http(s)`, `mailto`, and root-relative URLs.
- Attributes MUST be escaped. Pass-through is limited to `data-*` and `aria-*` attributes and
  a closed role set, and `data-ui-*` attributes are never author-set.
- No authored styling or raw HTML may reach rendered or exported output; authored `css` or
  `style` on export is rejected.
- A component type that a target cannot render MUST degrade to a declared fallback, a labeled
  placeholder, or a disposition declared in the manifest, never be silently omitted.
- New render targets register through `webrender.registry.register_target`, and each target's
  supported clients and rendering behavior MUST be documented in `docs/`.

### III. Capability-Keyed Adaptation

- Every per-device difference MUST derive from the declared ROTE device profile and its
  capabilities (`backend/rote/capabilities.py`), measured geometry, and the fallback ladders
  (`backend/rote/fallback.py`), never from which client codebase is connecting.
- Devices of a comparable form-factor class MUST receive equivalent layout for the same
  content; any divergence traces to a declared capability difference.
- A new component type reaches clients that cannot render it only as a declared fallback.

### IV. The UI Protocol Manifest Is the Contract

- `contracts/ui_protocol.json` is the authoritative cross-client vocabulary: push types,
  actions, component types, additive fields, per-client dispositions, and presentation
  contracts.
- The manifest evolves additively and is versioned. Every change MUST land together with its
  fixtures, its dispositions, and every client's drift guards, which read the manifest and
  MUST NOT be skipped.
- AstralDeep pins the manifest version and SHA-256 digest; a manifest change is a contract
  change for every consumer.

### V. Cross-Client Parity Through Server-Owned Definitions

Every client MUST present the same user-facing capabilities, menu and settings structure, and
visual design language.

- Chrome comes from the server-owned chrome model (`backend/webrender/chrome/menu_model.py`
  and its companions). No client may add, omit, rename, reorder, or otherwise diverge from
  it; per-client adaptation to the form factor is expected.
- A client MAY append one clearly separated entry for capabilities that exist only on that
  machine (for example Windows "Agents on this PC"), and it MUST NOT alter the server-owned
  groups.
- Divergence is allowed only through a disposition declared in the manifest or a documented
  web-only omission that the server enforces (the tour and the admin group are omitted from
  native serialization), never by hiding items in a client.
- Every client MUST render the shared palette roles from one theme definition; stylesheet
  colors are `:root` tokens, and no client may fork a divergent palette.

**Rationale**: Divergent clients erode trust and multiply maintenance. Anchoring every client
to one server-owned definition makes parity a machine-checked property.

### VI. Thin, Trustworthy Native Clients

- Native clients are thin consumers of server-owned structured UI and chrome; they keep no
  parallel product catalog.
- Sign-in uses Keycloak through PKCE (Apple, Android via AppAuth, and Windows via a loopback
  redirect) or the device-authorization grant (watchOS). Apple and Android have no
  development-token or mock-auth path; the Windows development-token fallback is limited to
  developer profiles on loopback and is disabled whenever an effective deployment profile is
  present.
- Clients MUST keep credentials only in memory or platform-protected storage (the Apple
  Keychain, Android EncryptedSharedPreferences), and resume state MUST NOT persist
  credentials, transcripts, or canvas content.
- Client-hosted execution (bring-your-own agents on Windows) MUST stay fenced by explicit
  Allow and Deny confirmation, the PHI pre-filter, and LETS receipt verification.

### VII. Web, Privacy, and Supply-Chain Security

- The web shell runs under a nonce-based Content Security Policy whose nonce the host issues.
  The offline page allows no scripts or network (`default-src 'none'`), and the chart document
  allows only hash-pinned scripts with no network, frames, or forms.
- The service worker caches only SHA-256-pinned public assets; the web token lives in
  `sessionStorage` and is cleared when the principal changes.
- Vendored third-party assets carry their notices. The Windows updater and speech helper are
  verified before use (a Sigstore identity pin, and SHA-256 plus Authenticode).
- CI MUST scan the full history with the pinned Gitleaks, and secrets and signing material
  MUST NOT be committed.

### VIII. Accessibility as a Gate

- Web output MUST carry accessible semantics, stay keyboard-reachable in DOM order, support
  Escape with focus return, and remain usable at 320 px with 200% text and no horizontal
  scrolling.
- The web accessibility checks and each native client's accessibility suite MUST stay in the
  test stack and MUST NOT be skipped.

### IX. Coverage and Lint per Language

These gates MUST NOT be weakened:

- Python (server code, scripts, and the Windows client) and C#: at least 90% coverage of
  changed lines through `diff-cover`.
- JavaScript: at least 90% statement coverage for the gated web modules (`service-worker.js`,
  `offline-registration.js`, `canvas-export.js`, and `canvas-export-host.js`).
- Kotlin: at least 90% coverage of Android `:core` through Kover. Android app, instrumented,
  and Swift coverage are measured and reported.
- A change with no measurable executable lines makes changed-line coverage not applicable, and
  that outcome MUST be recorded explicitly.
- Lint runs per language: ruff (Python), ESLint with `--max-warnings=0` (JavaScript), ktlint
  and Android Lint (Kotlin), `swift-format --strict` (Swift), and `dotnet format` (C#).
  Exceptions use the narrowest rule-specific directive, with the justification in the pull
  request.
- Tests MUST cover golden paths, edge cases, denials, and failures, and shipped code MUST NOT
  contain work-in-progress, stubbed, mocked, hard-coded, or debug-only paths.

### X. Fair, Bounded, Deterministic CI

- `ci.yml` (`python`, `web`, `windows-tests`, `windows-package`, and the `required` aggregate),
  `android-ci.yml` (`build-test`, `instrumented`, and `android-required`), and `apple-ci.yml`
  (`swift-lint`, `core-tests`, `core-ios-tests`, `app-unit-tests`, `first-login-ui`,
  `watch-continuity`, and `apple-required`) are the required gates. The network-touching
  `next-major-readiness` canary is advisory and MUST NOT become required.
- Workflows MUST stay read-only with no secrets or `id-token`, pin every action to a full
  commit SHA, and aggregate their jobs fail-closed; `tests/ci/test_workflows.py` pins these
  properties.
- Every job MUST declare exactly one `timeout-minutes` of at most 30 and finish within it.
- Soak tests are prohibited. Per-test retries are permitted; whole-suite reruns are not.
  Required gates MUST NOT depend on live third-party network services, exact clock-derived
  values, or wall-clock performance bounds, and a gate fails only for a defect the change
  introduced or can fix.

### XI. Locked Dependencies and Toolchains

- Any dependency MAY be added when declared in its owning manifest and lock: `pyproject.toml`
  and the hash-locked CI and Windows release locks, `package-lock.json` with the pinned npm,
  the Gradle version catalog with lockfiles and verification metadata, `Package.resolved`,
  and `packages.lock.json` with the pinned .NET SDK.
- Toolchains are pinned exactly (Xcode, Node and npm, the .NET SDK with roll-forward disabled,
  and the Gradle wrapper).
- The `astralprims` version pinned in `pyproject.toml`, the CI lock, and the Windows client
  requirements MUST agree.

### XII. Provenance and Evidence Integrity

- `provenance/transformations.json` MUST record every changed extracted file, with its
  current-byte digest, task, and reason, in the same change; `tests/test_protocol.py` checks
  that the ledger matches the changed set exactly.
- Generated artifacts (offline assets, protocol fixtures, manifest digests, and the Swift
  primitive mirror) change only together with their generators or evidence, and the Swift
  mirror MUST match the Python serialization byte for byte.
- `.gitattributes` keeps LF line endings and MUST stay exactly as tested.
- Documentation claims MUST match the code as merged.

### XIII. Inert Release Automation and Identity Continuity

- Release workflows in this repository stay inert (`workflows-disabled/`, guarded by
  `if: ${{ false }}`, read-only). Nothing here authorizes a release or a store upload; client
  releases run from AstralDeep's protected release lanes over the pinned revision.
- Registered identities MUST persist: bundle and application IDs, redirect URIs, monotonic
  build numbers and the Android versionCode floor, the `apple-v*` tag namespace, and the
  Windows Sigstore identity.

### XIV. Self-Documenting Source

- Every source and test file MUST begin with a header of at most three sentences stating what
  it does and how it connects to other files, using the language's comment syntax (a module
  docstring in Python).
- No other comments or docstrings are permitted, except a single-line comment where one is
  absolutely necessary to explain a non-obvious *why*. Function and class docstrings, JSDoc,
  KDoc, and DocC blocks, narrating comments, section banners, commented-out code, TODO/FIXME
  notes, spec, task, and requirement IDs, feature numbers, and change history MUST NOT appear
  in source. Tool directives and generator markers are not comments and are preserved
  verbatim.
- Identifiers fixed by a published contract or evidence record (for example `voice_065`
  fixtures and `*_088` contracts) are data, not comments, and keep their names.
- Tests MUST verify behavior and MUST NOT assert on comments or docstrings.
- Vendored third-party assets and files generated and managed by Spec Kit (`.specify/`,
  `.agents/`, `.claude/`) are exempt from this principle.

## Consumers and Cross-Repository Changes

- AstralDeep embeds this repository at `components/AstralProjection`, pins its commit,
  contract version (`astralprojection.contract/v1`), and UI protocol version and digest,
  supplies roles, availability, CSP nonces, and host-authorized surfaces, and runs the client
  release lanes.
- This repository never edits AstralDeep. A new primitive starts in AstralPrimitives; a
  protocol, chrome, theme, or layout change lands here across every in-scope client in the
  same feature, and AstralDeep adopts it by moving its pin under its own constitution.

## Development Workflow

- Changes land through pull requests qualified by the required gates unless the owner
  explicitly authorizes a direct push; a directly pushed change runs the same gates on `main`.
- A UI change MUST be exercised on every affected client against a live backend before it is
  declared complete. Type checks and unit tests do not verify feature correctness, and
  verifying one client does not stand in for the others.
- A change to an extracted file updates the provenance ledger (Principle XII) in the same
  change.
- Reviewers MUST verify constitution compliance, including dispositions and drift guards
  (Principles IV and V), accessibility (Principle VIII), and headers and comments
  (Principle XIV).
- Spec, task, and feature IDs belong in pull request descriptions, never in source.

## Governance

- This constitution is the highest-authority engineering policy for AstralProjection and
  supersedes `README.md`, the client READMEs, `docs/`, and other guidance where they conflict.
  It replaces the AstralDeep constitution as this repository's governing document;
  AstralDeep's constitution governs only how AstralDeep consumes Projection.
- Amendments land by pull request unless the owner explicitly authorizes a direct push. Each
  amendment is approved by the owner or a lead developer and records its rationale, version
  change, and Sync Impact Report in the pull request or commit message.
- Versioning follows semantic versioning: MAJOR for principle removals or redefinitions,
  MINOR for new principles or materially expanded guidance, and PATCH for clarifications.
- Every pull request and review MUST verify compliance. Violations are resolved before merge,
  and known shortfalls are tracked as follow-up work until closed.
- References to numbered constitution principles in records written before 2026-09-28,
  including the client READMEs, refer to the AstralDeep constitution v5.0.0.

**Version**: 1.0.0 | **Ratified**: 2026-09-28 | **Last Amended**: 2026-09-28
