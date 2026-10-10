# AstralDeep — Native Android Client

A native **Kotlin + Jetpack Compose** Android app that renders the AstralDeep
orchestrator's **server-driven UI (SDUI)** as native Compose widgets — **no web
view**. It is the Android twin of the native Windows client: a real
ROTE/webrender *target* that consumes the structured `components` the
orchestrator places on every `ui_render` / `ui_upsert` / `ui_stream_data` (the
non-web wire layer) and draws native UI for the SDUI primitive vocabulary, with
unknown types degrading to a labeled placeholder. Phones, tablets, and foldables
are served by one adaptive layout.

The original feature-041 design history remains attributable through
[`provenance/extraction.json`](../provenance/extraction.json). The standalone
client contract is now defined by this tree, especially
[`../contracts/ui_protocol.json`](../contracts/ui_protocol.json), the shared
voice fixtures under `../contracts/fixtures/`, and the tests below.

## Component actions

Top-level canvas footers consume the server's versioned `component_chrome`
metadata. Missing, unknown, or malformed metadata exposes no inferred actions;
older servers therefore need the matching server update to offer these controls.
Refine and version history require the current live component. CSV and component
sharing remain available for an owned historical component when the server
supplies those descriptors. History shows only the bounded server version rows.
Actions appear inline in server order, with wrapping and accessible touch targets.

Refine/restore use the ordinary authenticated UI-event protocol on the current
registered connection and are never replayed from the offline queue. Repeated
Refine/Restore decisions stay disabled through their exact submission's accepted
and running states, until its terminal/refusal or the captured context retires. CSV uses
the authenticated component export endpoint and a bounded private staging file;
Share creates one revocable link per explicit attempt and presents it privately
until Copy is selected. Owner, session, chat, component replacement, and descriptor
removal invalidate open decisions and late results. The descriptors themselves
do not grant server authority.

## Modules

```
android-client/
├── core/   # PURE Kotlin (no Android) — JVM-unit-tested:
│           #   protocol/ (WS message models + JSON), sdui/ (Component + canvas),
│           #   streaming/ (push consumer), rest/ (audit REST shaping)
└── app/    # Android/Compose:
            #   transport/ (OkHttp WS), auth/ (AppAuth OIDC PKCE), render/
            #   (type→@Composable registry), stream/, ui/ (adaptive scaffold +
            #   chat/agents/history/audit screens)
```

The pure logic lives in `:core` so it is testable on the JVM without an emulator
(the bulk of the verification surface). `:core` ports the *verified* logic of the
Windows client (`windows-client/astral_client/streaming.py`, `rest.py`).

## Prerequisites

- JDK 17+ (21 recommended), Android SDK (Android Studio Ladybug+), an emulator or device (Android 8.0+ / API 26).
- The **Gradle wrapper is committed** (`gradlew`, `gradlew.bat`, the wrapper
  jar + properties) — use it directly; no first-time generation step. CI
  resolves its Gradle version from the committed
  `gradle/wrapper/gradle-wrapper.properties`.

## Build & test (no device — the bulk of logic)

```bash
./gradlew :core:test                 # JVM unit tests: protocol, sdui, streaming, rest
./gradlew :app:testDebugUnitTest     # app-level JVM unit tests
./gradlew :core:koverVerify          # changed-code/module coverage ≥ 90%
./gradlew ktlintCheck :app:lintDebug # Kotlin + Android lint
./gradlew :app:assembleDebug         # → app/build/outputs/apk/debug/app-debug.apk
```

(On Windows use `.\gradlew.bat …`.)

## Run

**Real Keycloak (the product auth).** The `astral-mobile` public client is
provisioned and allow-listed (`KEYCLOAK_ALLOWED_AZP`). Its Valid Redirect URIs
include the Android scheme `com.personalailabs.astraldeep:/oauth2redirect` (matching
the app's `appAuthRedirectScheme` manifest placeholder). Point the app at the
orchestrator (`wss://<host>/ws`) and sign in via the system browser (OIDC
Authorization-Code + PKCE), registering as `device_type=android`. See
[`docs/keycloak-android-client-setup.md`](../docs/keycloak-android-client-setup.md).

The app authenticates **only** via Keycloak OIDC (AppAuth PKCE) — there is no
dev-token or mock-auth shortcut (the unused `DevAuth` path was removed in feature
044).

An explicit deployment build retains the registered `astral-mobile` public client
and `com.personalailabs.astraldeep:/oauth2redirect` callback. Supply all three
endpoint properties together:

```bash
./gradlew :app:assembleDebug \
  -PastralApiBase=https://backend.example.invalid \
  -PastralWebSocketUrl=wss://backend.example.invalid/ws \
  -PastralKeycloakAuthority=https://iam.example.invalid/realms/Astral
```

REST and WebSocket must use the same TLS origin, with the REST origin at `/` and
the WebSocket path at `/ws`. Keycloak must be a canonical HTTPS realm authority.
Credentials, query strings, fragments, insecure schemes and partial profiles are
rejected during Gradle configuration and by the Android-free runtime validator.
Optional `astralOidcClientId` and `astralOidcRedirectUri` properties may only
restate the registered identities. The backend must allow the mobile client and
provision its public PKCE/S256 callback; the normal server session and AppAuth
flows remain required. A secure staging build uses the same stock application
code and certificate verification as a release build, with its compiled endpoint
profile bound to the retained APK digest.

Without an explicit profile, the existing debug loopback and release deployment
values are preserved. This does not make insecure debug endpoints eligible for
secure sign-in. `:app:verifyDeploymentBuildProfile` exercises accepted and denied
build profiles and runs before every APK build; `:core:test` and the app JVM tests
also verify runtime validation and generated configuration consumption.

## Instrumented / UI tests (emulator)

```bash
./gradlew :app:connectedDebugAndroidTest   # Compose UI tests on a running emulator/device
```

## CI

[`.github/workflows/android-ci.yml`](../.github/workflows/android-ci.yml) runs on
pushes to `main` and pull requests that touch `android-client/` or the shared
contracts, assets and scripts it consumes, nightly, and on demand: ktlint +
Android Lint, `:core` + `:app` JVM unit tests, Kover coverage (at least 90% on
`:core`), `:app:assembleDebug` (uploads the debug APK), and the emulator suite.
Its `build-test`, `instrumented` and `android-required` jobs are required gates
under Projection Constitution Principle X, and the coverage and lint floors are
Principle IX; `next-major-readiness` is advisory.

## Notes

- **No web view.** Every surface is native Compose; chrome that the web shell
  receives as HTML (`chrome_render`) is acknowledged, not embedded — native
  screens (Agents/History/Audit) are driven by the existing data actions/REST.
- **Dependencies** (Compose/AndroidX, OkHttp, kotlinx.serialization, AppAuth,
  Coil) are declared in `gradle/libs.versions.toml` and pinned by the Gradle
  lockfiles and `gradle/verification-metadata.xml`; any dependency may be added
  that way (Projection Constitution Principle XI).
- Per the Projection constitution's Development Workflow, final correctness is
  verified on a real device/emulator against the live backend — unit tests + the
  CI build are necessary but not sufficient.
