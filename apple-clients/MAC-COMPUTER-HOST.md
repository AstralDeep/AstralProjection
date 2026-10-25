# Computer tasks on macOS

The DirectDownload build can observe and operate the local desktop through the existing authenticated computer-host transport. The Store build remains a controller. Both render the same server-owned generated UI, menus and theme.

## Build

Use the committed project and the compiler pinned in `.github/workflows/apple-ci.yml`. From the Projection repository root:

```sh
xcodebuild \
  -project apple-clients/AstralApp/AstralApp.xcodeproj \
  -scheme AstralAppDirectDownload \
  -configuration DirectDownload \
  -destination 'platform=macOS' \
  -derivedDataPath build/mac-direct \
  ASTRAL_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Manual \
  'CODE_SIGN_IDENTITY=Developer ID Application: Your Organization (YOUR_TEAM_ID)' \
  build
```

The app is under `build/mac-direct/Build/Products/DirectDownload/AstralDeep.app`. Preserve the registered bundle identifier and inspect the complete bundle's signature and entitlements before installation:

```sh
codesign --verify --deep --strict --verbose=2 build/mac-direct/Build/Products/DirectDownload/AstralDeep.app
codesign --display --verbose=4 --entitlements :- build/mac-direct/Build/Products/DirectDownload/AstralDeep.app
```

Hardened runtime must be enabled, App Sandbox must be absent, and `com.apple.security.get-task-allow` must not be true. DirectDownload disables Xcode's base-entitlement injection and testability so the signed app receives only its declared audio-input entitlement. The runtime checks the distribution marker, valid sealed signature, bundle identity, runtime flags, sandbox state and debugger entitlement before offering execution. A marker or an ordinary unsigned CI build does not enable hosting. These checks are local distribution checks, not server-side remote attestation.

For unsigned compile verification, add `CODE_SIGNING_ALLOWED=NO`. Keep Store signing/export settings unchanged. Local build/signing is distinct from notarization, public distribution, store upload and release qualification; follow the owning AstralDeep release process for those actions.

## Enable this Mac

1. Install the complete candidate bundle, retaining the previous app recoverably. Do not overlay old bundle resources or remove existing Keychain/container data.
2. Sign in through the normal Keycloak flow. Provider credentials are configured in product.
3. Open **Computer controls…** from the Astral menu, the workspace toolbar, or the **This Mac** footer. The shortcut is Command–Shift–C.
4. Grant Accessibility, Screen Recording and Input Monitoring in macOS, then refresh permissions. Complete system dialogs yourself.
5. Physically click **Allow computer tasks on this Mac** from the active unlocked app. Injected input cannot enable access or press local Resume. After locking or changing the active desktop, explicitly enable access again.
6. Select dedicated workspace folders if file tools are needed. File verbs are advertised only while selected roots are available. Roots are bound to the signed-in account and server.

The server must run the matching qualified implementation with `FF_COMPUTER_USE=true`. Recreate the service after changing its environment. With the flag off, hosting does not become available merely because the local permissions are granted.

## Use and control

The agent observes screenshots and window inventories, then uses bounded native pointer and keyboard operations. Browser interaction uses the visible application; no semantic DOM/browser service is advertised. Verify each browser's actual workflows before treating it as qualified.

Commands use an explicitly reviewed visible Terminal workflow. Recognized standalone terminals are Terminal, iTerm, Ghostty, Warp, Kitty, Alacritty and WezTerm. Approval binds the application/window and exact text or key chord; a generic approval cannot grant shell access. File writes and deletes require their own server review. A reviewed Terminal command has broader computer access than selected-root file tools.

Physical input pauses an active computer task. The persistent local panel offers Pause, Resume and Stop. On the same Mac, an approval may explicitly offer **Approve and resume** for its reviewed target; ordinary approval does not silently restore focus or old authority. Stop, lock, account/server changes and connection replacement invalidate outstanding work. An action already delivered when interrupted can have an unknown outcome: inspect the desktop before retrying.

The driver cannot operate Astral's own process or its visible controls. Screenshots and window listing can still include Astral. Secure fields, unknown focus, stale window geometry, missing permissions, symlinks, hard-linked file reads and paths outside selected roots fail closed. File tools support bounded UTF-8 files and files/empty-directory deletion, not recursive trees.

## Verify

```sh
swift test --package-path apple-clients/AstralCore --enable-code-coverage
xcodebuild \
  -project apple-clients/AstralApp/AstralApp.xcodeproj \
  -scheme AstralApp -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -enableCodeCoverage YES \
  -only-testing:AstralAppTests test
```

Unit tests use injected native boundaries and temporary files. They do not replace signed-app TCC, authenticated browser/native/Terminal/file workflows, physical takeover, lock/unlock or production verification. Record the exact client, server image and component identities with that evidence.
