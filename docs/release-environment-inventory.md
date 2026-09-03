# Projection release environment inventory

This is a names-only inventory for the repository-ownership transition. It
contains no credential value, certificate, token, private key, profile bytes,
or local signing path. It authorizes no release or store action.

## Observed repository state

Read-only GitHub API queries on 2026-08-14 reported that
`AstralDeep/AstralProjection` is private, has default branch `main`, and has:

- zero GitHub environments;
- zero repository Actions secrets;
- zero repository Actions variables;
- zero GitHub releases.

That empty state is expected for the extraction checkpoint. GitHub
environments, approvals, secrets, variables, OIDC trust, and store records do
not follow copied source files. The YAML remains inert in
`workflows-disabled/`, and its deliberately blank credential expressions must
not be treated as configured values.

## Required GitHub environments and approvals

| Environment | Intended authority | Required protection before activation |
|---|---|---|
| `release-publisher` | Windows tag/release publication only | At least one designated release lead; prevent self-review; restrict deployments to the protected default branch and the exact reviewed tag workflow; no administrator bypass; built-in short-lived `GITHUB_TOKEN` only |
| `apple-release` | App Store archive/upload only | At least one designated Apple store owner; prevent self-review; restrict to protected `main` and reviewed `apple-v<strict-version>` tags; no administrator bypass |

The unsigned Windows candidate, client CI, and read-only evidence normalizer do
not need write-authority environments. If an organization policy adds a
read-only approval environment, record that change here before activation.

Required-reviewer identities are external operator state and have not been
selected in this checkpoint. Activation is blocked until the repository owner
records the exact reviewers and verifies the live protection response through
the GitHub API.

## Required Actions variables

| Name | Scope | Purpose |
|---|---|---|
| `RELEASE_TRUSTED_BUILDER_SHA` | Repository or protected release environments | Exact owner-reviewed commit containing release verification policy |
| `RELEASE_BRIDGE_WORKFLOW_SHA256` | `release-publisher` and controller | Exact digest of the reviewed one-time Windows bridge workflow |
| `ASTRAL_APPLE_LAST_SUBMITTED_BUILD` | `apple-release` | Highest build confirmed in App Store Connect immediately before cutover |
| `ASTRAL_APPLE_BUILD_NUMBER_BASE` | `apple-release` | First reserved Projection build; strictly greater than the confirmed store build |

All four are currently absent. They are identities or monotonic counters, not
secret values, but they remain environment-protected release inputs.

## Required Actions secrets

The extracted workflows contain blank placeholders by design. Before review,
wire only these named inputs to environment/repository secrets as appropriate:

| Name | Consumer | Notes |
|---|---|---|
| `ASTRAL_WINDOWS_SMOKE_TOKEN` | unsigned Windows candidate | Optional pre-minted staging token; never an artifact or output |
| `ASTRAL_STAGING_USERNAME` | unsigned Windows candidate | Alternative token-mint credential |
| `ASTRAL_STAGING_PASSWORD` | unsigned Windows candidate | Alternative token-mint credential |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64` | `apple-release` | Apple Distribution identity including private key |
| `APPLE_INSTALLER_CERT_P12_BASE64` | `apple-release` | Separate Mac App Store installer identity when not in the first P12 |
| `APPLE_CERT_PASSWORD` | `apple-release` | Distribution P12 password |
| `APPLE_INSTALLER_CERT_PASSWORD` | `apple-release` | Optional distinct installer P12 password |
| `APPLE_PROVISION_PROFILE_BASE64` | `apple-release` | Container holding iOS, macOS, and watchOS store profiles |
| `ASC_KEY_P8_BASE64` | `apple-release` | App Store Connect API private key |

These identifiers may be non-secret variables, subject to the organization's
policy, but their names must also be provided to the Apple job:
`APPLE_TEAM_ID`, `APPLE_PROFILE_IOS`, `APPLE_PROFILE_MACOS`,
`APPLE_PROFILE_WATCH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`.

Windows keyless signing must use GitHub OIDC and the built-in job token. Do not
add a repository-scoped GitHub App, installation token, personal token, or
custom token broker. Android upload signing remains outside Actions for this
checkpoint: the ignored `android-client/keystore.properties`, external
keystore, and Play operator session are not repository secrets.

## Stable product and store identities

| Surface | Identity that must not change |
|---|---|
| Windows executable/product | `AstralDeep.exe`; product `AstralDeep`; AppUserModelID `AstralDeep.WindowsClient` |
| Windows settings/state | `QSettings("AstralDeep", "WindowsClient")`; `%APPDATA%/AstralDeep`; `%LOCALAPPDATA%/AstralDeep` |
| Android Play application | `com.personalailabs.astraldeep` |
| Android OIDC redirect | `com.personalailabs.astraldeep:/oauth2redirect` |
| Android documented upload alias | `astral-upload` (must be reconciled against the retained real upload certificate) |
| Apple Universal Purchase app | `com.personalailabs.astraldeep` |
| Apple watch app | `com.personalailabs.astraldeep.watch` |
| Apple test bundles | Existing `com.personalailabs.astraldeep.*tests` identifiers |

The Play Console application, App Store Connect Universal Purchase record,
provisioning profiles, certificates, and Keycloak registrations stay attached
to these identities. A repository rename or redirect proves none of them.

## Build-number observations and required live checks

| Platform | Repository observation | Store-authoritative value |
|---|---|---|
| Android | Candidate `versionCode` is `7`; `versionName` is `1.4`; `targetSdk`/`compileSdk` 36 | Play refused the `6 (1.4)` targetSdk-35 bundle on 2026-09-03 (target API 36 required), consuming code `6`; recheck the all-app-bundles inventory before upload |
| Apple | Candidate source is `MARKETING_VERSION 1.5` / `CURRENT_PROJECT_VERSION 61` | Authenticated App Store Connect on 2026-08-30 confirmed iOS and macOS `1.4 (60)`; reserve `ASTRAL_APPLE_LAST_SUBMITTED_BUILD=60` and a base of at least `61`, then recheck immediately before upload |
| Windows | Candidate source is `0.5.1`; live legacy baseline is `v0.4.0`; the `v0.5.0` tag (2026-09-03) is immutable and unpublished because its release lane never initialized the Projection submodule | The bridge version is deliberately unselected in `contracts/windows-release-trust.json` |

GitHub run numbers and checked-in project defaults are evidence leads, not
store truth. Store maxima must be rechecked immediately before publication;
they are never guessed from source history.
