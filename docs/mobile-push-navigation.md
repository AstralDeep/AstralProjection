# Owner-bound mobile push navigation

Both phone clients run the same destination runtime against Deep's push REST boundary
(`/api/push/destinations`, `/api/push/ack`, `/api/push/destinations/{device_id}`), bound by the
`push_navigation` presentation contract in `contracts/ui_protocol.json`. This page records how the
runtime is wired, what is verified where, and what remains a coordinated release-lane step.

## Shared behavior

- Enrollment: the runtime enrolls the device push token with `platform` `android` or `ios`, rotates
  the destination when the provider token changes, treats a repeated token as idempotent, and
  classifies enrollment denials into the contract's transient and permanent vocabulary
  (400/403/409 permanent, 429/503 and transport failures transient, 401 unauthenticated).
- Acknowledgment: presented or tapped notification identities are acknowledged once through the
  bounded receipt ledger; the ledger also suppresses duplicate OS presentation and re-acknowledgment
  across surfaces and process restarts, and dismissal removes the entry so a genuine redelivery
  presents again.
- Revocation: sign-out, account change, permission revocation, and a permanently unavailable
  provider token clear the destination and reset the runtime.
- Presentation: the server's `level` selects importance (`error` to the high-importance channel on
  Android, system alerts on iOS); while the owner's socket is connected, the ws `notification` frame
  owns the single in-app banner slot and OS duplicates of the same text cannot stack a second banner.
- Navigation: a tap first completes the ordinary Keycloak authentication, then the client
  acknowledges the identity and lands on the owner's authenticated surfaces through the ordinary
  resume flow. Taps never approve actions, execute tools, replay queued commands, or carry component
  verbs, and the client never navigates from a URL inside the provider message. A ws
  `notification` frame naming a conversation other than the active one points at the authorized
  conversation surfaces ("open it from History") without opening or executing anything on its own.

## Android wiring

The pure decision machine lives in `:core`
(`core/src/main/kotlin/com/personalailabs/astraldeep/core/push/`) and the OS binding in `:app`
(`app/src/main/kotlin/com/personalailabs/astraldeep/app/push/`). `PushRuntime` owns the adapter
instance, performs the enrollment, acknowledgment and revocation calls through `PushDestinationRest`,
resolves authentication-gated taps from `MainActivity` intents (both the adapter's content intent and
the system-tray tap extra), and rebuilds the machine on sign-out or account change. The
`POST_NOTIFICATIONS` permission is requested once per process after sign-in; runtime revocation
cancels presented notifications and clears the ledger.

The `PushProvider` seam is the single integration point for a provider bridge (FCM). No provider
bridge ships yet: the supply chain for the FCM SDK dependency is locked and cannot be extended
offline, so the runtime starts with `AbsentPushProviderBackend`, the machine's designed fail-closed
unsupported-provider state. Every other behavior — permission, enrollment denials, ledger,
presentation decisions, tap acknowledgment, revocation — is live and exercised; the bridge lands
with its locked dependency and provider credentials in the release lane.

## Apple wiring

The machine and REST boundary live in AstralCore (`Sources/AstralCore/Push/PushMachine.swift`,
`Sources/AstralCore/API/PushRest.swift`); `PushNotificationService` binds them to
UserNotifications in the iOS app target: authorization state, APNs registration
(`AstralApp-iOS.entitlements`), foreground suppression in favor of the in-app slot, delivered-
notification seeding, tap acknowledgment, and sign-out/account-change revocation from `AppModel`.
macOS and watchOS keep the in-app banner only, per the manifest disposition. Enabling the APNs
capability for the registered App id in the developer portal is a portal-side step that precedes
device builds.

## Verification

- Contract and drift guards: `tests/test_push_navigation_contract.py` (Python lane) reads the
  manifest and both clients' sources, pins the payload bounds, the denial vocabulary, the
  server-selected level mapping, foreground deduplication, tap semantics, and the in-app-only
  fallback for web, Windows, macOS and watchOS.
- Android JVM: `:core` push tests join the Kover gate; `PushDestinationRestTest` covers the REST
  classification on the JVM with MockWebServer in `:app:testDebugUnitTest`.
- Android device: `NotificationPushAdapterInstrumentedTest` runs in the required emulator lane.
- Apple: `PushMachineTests` and `PushRestTests` run in the AstralCore macOS and iOS lanes.
- Staging: registration, background and terminated delivery, tapping and cleanup against a real
  provider backend on physical devices remain coordinated release-lane verification; provider
  credentials and the FCM bridge dependency are outside this repository's offline reach.
