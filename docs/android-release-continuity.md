# Android release continuity

Moving the Android client from the AstralDeep repository to AstralProjection
does not create a new Android product. The following registered identities are
preserved exactly:

| Identity | Preserved value |
|---|---|
| Play application ID | `com.personalailabs.astraldeep` |
| Kotlin namespace | `com.personalailabs.astraldeep.app` |
| AppAuth redirect URI | `com.personalailabs.astraldeep:/oauth2redirect` |
| Documented upload-key alias | `astral-upload` (must be reconciled with the retained local signing configuration before release) |
| Migration version-code floor | `5` |
| Current candidate version code | `6` |
| Current candidate version name | `1.4` |

Repository transfer does not reset Play Console version codes. Every upload to
any Play track must use a `versionCode` greater than every prior upload. The
checked-in floor prevents an accidental source regression below the migration
baseline. Authenticated Play Console's all-app-bundles inventory on 2026-08-29
confirmed that the highest upload on every track is `5 (1.3)`, making candidate
code `6` strictly monotonic. The release operator must repeat that check
immediately before building because another track could receive a newer upload.

## Signing continuity

The upload key remains external to Git. The historical runbook layout was:

- historically documented keystore: `%USERPROFILE%\.android-keys\astral-upload.jks`;
- historically documented alias: `astral-upload`;
- historically documented password file: `%USERPROFILE%\.android-keys\astral-upload.pass.txt`;
- Gradle configuration: ignored `android-client/keystore.properties`.

The migration copied the ignored `keystore.properties` and `local.properties`
files opaquely into the Projection worktree after verifying the destination
ignore rules. Their contents were not logged, hashed, or staged. The original
AstralDeep copies must remain in place until a signed Projection bundle has
been built and its upload certificate matches the Play Console registration.
An externally referenced keystore is not copied by the repository migration.
An initial configuration check showed that the retained local key alias does
not match the historical `astral-upload` runbook value. The build does not
rewrite or reject that private configuration. Before release, the operator must
resolve the discrepancy by checking the actual upload certificate against Play
Console; guessing or changing the alias from repository code is unsafe.

Before any release:

1. confirm the Projection checkout still ignores both local property files;
2. confirm `applicationId` and redirect scheme match the table, then reconcile
   the retained key alias with the upload certificate registered in Play;
3. choose a version code strictly above the highest Play Console upload;
4. build `:app:bundleRelease` locally and inspect the signing certificate;
5. retain the source checkout and old workflow until signed-build continuity is
   recorded.

This document authorizes no Play upload or store submission.
