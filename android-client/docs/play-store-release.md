# Play Store Release Runbook

How to build, sign, and publish the AstralDeep Android client to Google Play.
First written for the v0.1.0 (`versionCode 1`) initial upload.

## Signing model

New Play apps use **Play App Signing**: Google holds the *app signing key* and
re-signs every delivered APK; you keep only an **upload key** that authenticates
uploads. Losing the upload key is recoverable (Play Console → Test and release →
Setup → App signing → *Request upload key reset*); losing the app signing key is
impossible because you never have it.

Local signing material (**never committed** — `.gitignore` covers
`keystore.properties`, `*.jks`, `*.keystore`):

| What | Where |
|---|---|
| Upload keystore | `%USERPROFILE%\.android-keys\astral-upload.jks` (historically documented alias `astral-upload`; reconcile with Play Console before the first Projection release) |
| Keystore/key password | `%USERPROFILE%\.android-keys\astral-upload.pass.txt` |
| Gradle signing config | `android-client/keystore.properties` (points at the above) |

> **Back up `%USERPROFILE%\.android-keys\` somewhere safe** (password manager,
> encrypted drive). It lives outside the repo and outside any clone.

`app/build.gradle.kts` loads `keystore.properties` only if it exists — CI and fresh
clones without it still build/test normally; their release builds are simply
unsigned.

The retained local properties observed during repository migration did not
match the historical alias value. Their contents remain private and were not
rewritten. Verify the actual upload certificate against Play Console before
changing an alias or recreating this file. The following is the historical
template (note doubled backslashes), not authority over the retained key:

```properties
storeFile=C:\\Users\\<you>\\.android-keys\\astral-upload.jks
storePassword=<contents of astral-upload.pass.txt>
keyAlias=astral-upload
keyPassword=<same password>
```

## Building the release bundle

Play accepts only Android App Bundles (`.aab`), not APKs.

```powershell
cd android-client
.\gradlew.bat :app:bundleRelease
# → app\build\outputs\bundle\release\app-release.aab
```

Verify the bundle's upload-certificate fingerprint against the **Upload key
certificate SHA-256 fingerprint** shown in Play Console → App integrity. The
certificate subject or common name is descriptive metadata, not a unique
signing identity, and must not be used as the acceptance criterion:

```powershell
& "$env:JAVA_HOME\bin\keytool.exe" -printcert -jarfile app\build\outputs\bundle\release\app-release.aab
# Compare the printed SHA256 fingerprint exactly with Play Console.
```

Stop the release if the fingerprints differ. Do not change the alias or create
a replacement key until the mismatch has been reconciled through Play Console.

Optional local smoke test (installable release APK, same code as the bundle):

```powershell
.\gradlew.bat :app:assembleRelease
adb install -r app\build\outputs\apk\release\app-release.apk
```

The release build points at `wss://sandbox.ai.uky.edu` / Keycloak
`https://iam.ai.uky.edu/realms/Astral` (`AppConfig.kt`, switched on
`BuildConfig.DEBUG`). Minification is intentionally OFF for now, so the release
binary behaves identically to the CI-tested debug build apart from endpoints.

## Versioning rule

Every upload to Play — any track, even internal testing — must have a strictly
higher `versionCode` than any previous upload. Before each new upload, bump in
`app/build.gradle.kts`:

```kotlin
val currentVersionCode = <strictly greater than the highest Play Console upload>
// Keep versionCode = currentVersionCode in defaultConfig; do not edit that assignment.
versionName = "<approved marketing version>"
```

## Play Console: first-time setup

1. **Developer account** — <https://play.google.com/console>, one-time $25 fee,
   identity verification required. **Personal accounts** (as opposed to
   organization accounts) must additionally run a closed test with **at least 12
   testers for 14 continuous days** before they may apply for production access.
   Plan for this if not registering as an organization.
2. **Create app** — App (not game), Free. The application id
   `com.personalailabs.astraldeep` (registered 2026-07-07) is fixed forever at
   first upload. The AppAuth redirect scheme uses that registered ID; the
   Kotlin `namespace` and source packages intentionally append `.app` as
   `com.personalailabs.astraldeep.app` (fully renamed 2026-07-07 from the
   historical package). **Keycloak prerequisite**: the
   `astral-mobile` client's *Valid Redirect URIs* and *Valid post-logout
   redirect URIs* must include `com.personalailabs.astraldeep:/oauth2redirect`
   — login fails with a redirect_uri error until they do. (Keep the old
   `com.kyopenscience.astral:/oauth2redirect` entry only while sideloaded
   builds of the old package are still in use.)
3. **Play App Signing** — accepted by default on first `.aab` upload; the
   keystore above becomes the registered upload key.

### Dashboard "Set up your app" checklist (AstralDeep answers)

| Item | Answer |
|---|---|
| Privacy policy | `https://kyopenscience.com/astraldeep/privacy-policy/` |
| App access | **All or some functionality is restricted** — the app is login-only against a private Keycloak realm. Provide a working reviewer account (a Keycloak user in the `Astral` realm with the `user` role) with username + password and instructions ("Tap Sign in → enter credentials"). **Review will fail without this.** |
| Ads | No ads |
| Content rating | Complete the questionnaire; a utility/productivity chat client with no objectionable content → typically Everyone/PEGI 3. User-generated content is private (per-user chats, not shared publicly). |
| Target audience | 18+ (avoids child-safety/Families policy obligations) |
| News app | No |
| COVID-19 tracing/status | No |
| Data safety | See below |
| Government app | No |
| Financial features | None |
| Health apps | Declare only if distributing the medical-agent features to end users; the app itself is a general chat/dashboard client. |

### Data safety form

Declares what the app collects/shares. Truthful answers for this client:

- **Collected**: Personal info → *User IDs* and *Email address* (Keycloak OIDC
  sign-in); Messages → *Other in-app messages* (chat content sent to the
  AstralDeep backend); Files and docs (chat attachments, if the user attaches
  them).
- **Shared with third parties**: No (data goes only to the first-party backend).
- **Encrypted in transit**: Yes (WSS/HTTPS in release; tokens stored via
  `androidx.security-crypto` EncryptedSharedPreferences; `allowBackup=false`).
- **Deletion**: point at the account/data deletion story for the backend
  (chat deletion exists in-app; account deletion is handled by the operator via
  Keycloak — describe whatever process the privacy policy documents).

### Store listing assets (required before any public track)

- App icon **512×512 PNG** (export from the launcher vector
  `app/src/main/res/drawable/ic_launcher_foreground.xml` on its background
  color, e.g. via Android Studio's Asset Studio or any SVG/vector renderer).
- Feature graphic **1024×500 PNG**.
- **≥2 phone screenshots** (emulator screenshots are fine); 7"/10" tablet
  screenshots recommended since the app has tablet layouts.
- Short description (≤80 chars) and full description (≤4000 chars).

## Publishing flow

1. **Internal testing first**: Test and release → Testing → Internal testing →
   Create release → upload `app-release.aab` → add tester email list → roll out.
   Internal testing links go live within minutes and skip full review.
2. Install from the Play link on a real device, sign in against
   `sandbox.ai.uky.edu`, and verify chat + workspace render. (Play re-signs the
   app with the app-signing key — this validates the end-to-end delivered
   artifact.)
3. Promote the same release to **Closed testing** (this is the track that
   satisfies the 12-tester/14-day requirement for personal accounts), then
   **Production**. Production releases go through app review — typically hours
   to a few days for a new app; first-ever production review can take up to a
   week.
4. Each later upload: bump `versionCode`, rebuild `bundleRelease`, upload to a
   track, roll out.

## Known deferred items

- **R8/minify is off** by design (first release). If enabled later, revisit
  `proguard-rules.pro` — it covers kotlinx.serialization/AppAuth/OkHttp but has
  no Coil keeps — and smoke-test login + rendering on a minified build.
- **No CI release job** by design — bundles are built locally with the local
  keystore. If automated later: base64 the keystore + passwords into GitHub
  secrets and add a tag-triggered `bundleRelease` workflow.
