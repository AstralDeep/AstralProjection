# Client release trust transition

AstralProjection now owns the Windows, Android, iOS, macOS, and watchOS client
source trees, but repository ownership does not change an installed product's
identity or authorize publication. This runbook records the non-publishing
transition design and the checks required before any release workflow is
activated.

## Current state

The Windows updater remains in `legacy_only` state. It trusts only:

```text
repository: AstralDeep/AstralDeep
issuer: https://token.actions.githubusercontent.com
workflow: https://github.com/AstralDeep/AstralDeep/.github/workflows/release-windows.yml
ref shape: refs/tags/v<strict-semver>
```

No runtime environment variable can replace that repository or signing
identity. AstralProjection is present in the code as a second exact channel,
but it remains untrusted until a bridge build pins a selected version in source
and candidate-bound release evidence binds the executable digest.

The live legacy release observed during migration was `v0.4.0`, with
`AstralDeep.exe` SHA-256
`e8c511d3951af53d6e5897b6ddeb179693541977b1e2e1bde22139476e6b5003`.
This is a baseline observation, not the bridge selection. The bridge version
must be chosen again from live release state during an authorized release
planning event.

## Bounded dual-signature bridge

1. Re-query the latest public Windows release and confirm its three canonical
   assets and old-workflow Sigstore identity.
2. Select one strictly newer bridge version. Change the updater policy in the
   bridge source to `dual_pinned` and set both `bridge_version` and
   `legacy_max_version` to that exact version. Do not use an organization
   wildcard or runtime override. A binary cannot embed its own final digest;
   retain that digest in candidate-bound release evidence instead.
3. Build the bridge executable once from an exact reviewed revision using the
   already trusted AstralDeep `release-windows.yml` tag workflow.
4. Verify its SHA-256 and legacy Sigstore bundle. Copy those exact executable
   bytes to the Projection release candidate; do not rebuild, repackage, or
   alter metadata embedded in the executable.
5. Sign the identical executable bytes from
   `AstralDeep/AstralProjection/.github/workflows/release-windows.yml` at the
   same tag and create a second Sigstore bundle.
6. Record and verify all of the following before publication: bridge version,
   executable SHA-256 in both channels, legacy bundle digest, Projection bundle
   digest, exact tag refs, workflow identities, release IDs, and asset IDs.
7. Publish the bridge as the final/latest Windows release in AstralDeep. Only
   then may the same bytes and Projection bundle become the initial Projection
   release.
8. Publish later versions only from Projection. The bridge rejects legacy
   releases above its exact maximum and Projection releases below the bridge;
   wrong repositories, workflows, tags, equal versions, and downgrades fail
   closed.
9. A later Projection-native build may move to `projection_primary` only after
   installed-client reachability and the bridge evidence are verified.

The two bundles are expected to differ because their certificate identities
differ. The executable SHA-256 must be identical.

The currently copied `workflows-disabled/release-windows.yml` is the normal
post-bridge builder: it always runs PyInstaller. It must **not** be used for the
one-time Projection bridge signature because a rebuild cannot satisfy the
identical-byte requirement. Before any workflow activation, release engineering
must add and review an import-only bridge job that accepts the exact public Deep
release ID/tag/asset IDs and expected SHA-256, downloads those bytes without
redirect or name ambiguity, verifies the legacy bundle and manifest, refuses
any rebuild, signs the same file under the exact Projection tag identity, and
re-downloads both channel assets to prove equality. That job remains future
release work; adding credentials or `id-token: write` to the presently inert
workflow set is outside this migration checkpoint.

## Stable product and store identities

Repository names are not product identifiers. Preserve these values through
the transition:

| Platform | Stable identity |
|---|---|
| Windows executable | `AstralDeep.exe` |
| Windows product/file description | `AstralDeep` / `AstralDeep native Windows client` |
| Windows AppUserModelID | `AstralDeep.WindowsClient` |
| Windows settings | `QSettings("AstralDeep", "WindowsClient")` |
| Windows local state | `%APPDATA%/AstralDeep` and `%LOCALAPPDATA%/AstralDeep` |
| Android Play application ID | `com.personalailabs.astraldeep` |
| Android OIDC redirect | `com.personalailabs.astraldeep:/oauth2redirect` |
| Apple app bundle ID | `com.personalailabs.astraldeep` |
| Apple watch bundle ID | `com.personalailabs.astraldeep.watch` |
| Apple test bundle IDs | Existing `com.personalailabs.astraldeep.*tests` values |
| Apple signing indirection | `ASTRAL_DEVELOPMENT_TEAM`, `ASTRAL_PROFILE_IOS`, `ASTRAL_PROFILE_MACOS`, `ASTRAL_PROFILE_WATCH` |

The Play Console app, Apple Universal Purchase/App Store Connect records,
certificates, provisioning profiles, Keycloak redirect registrations, Windows
settings, and local user data stay attached to those identities.

## Apple build-number cutover

The published `apple-v1.2` tag ran in the legacy workflow at GitHub run number
41. Later non-release executions of that workflow reached run 58 during this
migration. Neither observation proves the highest number in App Store Connect.

Before activating the Projection workflow, an authorized operator must inspect
App Store Connect and configure these values in the protected Apple release
environment:

```text
ASTRAL_APPLE_LAST_SUBMITTED_BUILD=<highest confirmed store build>
ASTRAL_APPLE_BUILD_NUMBER_BASE=<first reserved Projection build, greater than the above>
```

`scripts/apple_build_number.py` combines the protected base with the new
repository's `GITHUB_RUN_NUMBER`. It has no fallback and refuses a missing,
noncanonical, non-monotonic, or overflowing value. The release workflow must
pass its output as `CURRENT_PROJECT_VERSION` for every archive in the release.

## Android signing continuity

See `docs/android-release-continuity.md`. The ignored local property files and
external upload key remain outside Git, version code never resets, and a signed
Projection bundle must be verified before the AstralDeep copies are retired.

## Activation gate

Copied workflows remain under `workflows-disabled/`; no job in that directory
runs on GitHub. Environments, secrets, variables, approvals, branch/tag rules,
and store records are external state and are not transferred by copying YAML.
They must be inventoried and recreated explicitly near final qualification.

This feature and this document authorize no GitHub release, store upload, App
Store submission, Play submission, deployment, or workflow activation.
