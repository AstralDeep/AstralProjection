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

For unsigned compile verification, add `CODE_SIGNING_ALLOWED=NO`. Use `build` for DirectDownload; its deliberate lack of testability makes `build-for-testing` inappropriate. Build unit tests with the Debug configuration shown below. Keep Store signing/export settings unchanged. Local build/signing is distinct from notarization, public distribution, store upload and release qualification; follow the owning AstralDeep release process for those actions.

## Enable this Mac

1. Install the complete candidate bundle, retaining the previous app recoverably. Do not overlay old bundle resources or remove existing Keychain/container data.
2. Sign in through the normal Keycloak flow. Provider credentials are configured in product.
3. Open **Computer controls…** from the Astral menu, the workspace toolbar, or the **This Mac** footer. The shortcut is Command–Shift–C.
4. Grant Accessibility, Screen Recording and Input Monitoring in macOS, then refresh permissions. Complete system dialogs yourself.
5. Physically click **Allow computer tasks on this Mac** from the active unlocked app. Injected input cannot enable access or press local Resume. The choice stays selected across app launches for this account and server. A fresh authenticated launch restores it only while this desktop is usable, the permissions remain granted and input monitoring starts successfully. Locking or permission loss pauses live access without erasing the choice; use **Resume computer access** locally to rearm it. Unchecking the option keeps it off after relaunch. Previous sessions, queued effects and Terminal grants are never restored.
6. Select dedicated workspace folders if file tools are needed. File verbs are advertised only while selected roots are available. Roots are bound to the signed-in account and server.

Each saved folder grant binds the original opened directory identity as well as its bookmark and account/server scope. Replacing or moving a selected root cannot silently grant its replacement. An unverifiable or older grant reports an error and requires selecting the intended folder again; removing another folder preserves the original open grants.

The server must run the matching qualified implementation with `FF_COMPUTER_USE=true`. Recreate the service after changing its environment. With the flag off, hosting does not become available merely because the local permissions are granted.

## Use and control

The agent observes screenshots and window inventories, then uses bounded native pointer and keyboard operations. Browser interaction uses the visible application; no semantic DOM/browser service is advertised. Verify each browser's actual workflows before treating it as qualified.

Commands use an explicitly reviewed visible Terminal workflow. Recognized standalone terminals are Terminal, iTerm, Ghostty, Warp, Kitty, Alacritty and WezTerm. Approval binds the application/window and exact text or key chord; a generic approval cannot grant shell access. File writes and deletes require their own server review. A reviewed Terminal command has broader computer access than selected-root file tools.

Physical input pauses an active computer task. A banner at the top of the main screen offers Pause, Resume and Stop (the persistent local panel when the overlay cannot be shown), and click-through screen overlays show the agent's pointer, clicks, drags, scrolls and key chords; screenshots and zooms never include either. On the same Mac, an approval may explicitly offer **Approve and resume** for its reviewed target; ordinary approval does not silently restore focus or old authority. Stop, lock, account/server changes and connection replacement invalidate outstanding work. An action already delivered when interrupted can have an unknown outcome: inspect the desktop before retrying.

The driver cannot operate Astral's own process or its visible controls. Screenshots and window listing can still include Astral. Secure fields, unknown focus, stale window geometry, missing permissions, symlinks, hard-linked file reads and paths outside selected roots fail closed. File tools support bounded UTF-8 files and files/empty-directory deletion, not recursive trees.

## Command sandbox

Every `run_command` job is wrapped in a generated macOS Seatbelt profile launched through the absolute system `/usr/bin/sandbox-exec` path. Before a job starts, the host compiles the profile with a `sandbox-exec` probe and starts a per-job loopback egress proxy; if the launcher is missing, the profile fails to compile, the proxy cannot start in enforce mode, or a requested environment value carries a placeholder secret, the job is refused with `sandbox_refused` and never spawns.

The enforce profile denies by default: writes are allowed only inside the selected roots and a per-job scratch directory (also set as the job's `TMPDIR`); Git hooks and `.git/config` inside a root, shell startup files, LaunchAgents, Astral's own bundle, support data and preferences stay read-only; excluded workspace patterns and the Keychain directories are unreadable; and network connects only to `127.0.0.1:<proxy port>`, with DNS to the system resolver. The shadow mode profile is fully permissive and exists so the same launcher path is compiled and validated without blocking.

The proxy speaks the standard forward-proxy contract (absolute-form HTTP and `CONNECT`). It applies the owner's egress domain list, refuses private, link-local, loopback and metadata destinations after resolving the listed host itself, and swaps owner-configured placeholder tokens for Keychain secrets only on egress to the binding's exact host. Children that ignore the standard proxy environment variables lose network in enforce mode and their refusals are recorded.

Results and audit:

- Each `run_command` and `read_output` result carries `job_id` and a `sandbox` object with the profile SHA-256 digest, the allowed domains, the sandbox mode, the proxy port and the violations recorded so far.
- The host emits `command.sandbox_violation` records (source, operation, target, detail, blocked) for Seatbelt denials parsed from the job's captured stderr and for egress decisions the policy would refuse, and `egress.decision` records (host, port, decision, rule, mode) for proxy connections. Records never contain request or response bodies. Placeholder tokens are scrubbed from captured output and never enter the job environment.

The owner configures the sandbox in Computer controls: the toggle switches between shadow (default) and enforce. The egress domain list and the placeholder-to-Keychain bindings are read from the `computer.sandbox.configuration` defaults key as JSON, for example `{"mode":"enforce","domains":["api.github.com"],"bindings":[{"placeholder":"ASTRAL_GITHUB_TOKEN","host":"api.github.com","secret":"astral.egress.github"}]}`. Placeholder names begin with `ASTRAL_` and the referenced secret is a generic-password Keychain item named by `secret`. Invalid configuration falls back to shadow mode with an empty list.

## Verify

```sh
swift test --package-path apple-clients/AstralCore --enable-code-coverage
xcodebuild \
  -project apple-clients/AstralApp/AstralApp.xcodeproj \
  -scheme AstralApp -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -enableCodeCoverage YES \
  -only-testing:AstralAppTests test
```

Unit tests supply raw native readings and record unposted events while exercising the actual authorization, input, observation, host and selected-root filesystem decisions. The shipped constructors retain immutable public-API defaults. These tests do not replace signed-app TCC, authenticated browser/native/Terminal/file workflows, physical takeover, lock/unlock or production verification. Record the exact client, server image and component identities with that evidence.
