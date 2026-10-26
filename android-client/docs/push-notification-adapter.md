# Android push notification adapter

The Android client ships a complete, independently testable OS notification
adapter in two halves. The pure decision machine lives in
`:core` (`core/src/main/kotlin/com/personalailabs/astraldeep/core/push/`) and the
OS binding lives in `:app`
(`app/src/main/kotlin/com/personalailabs/astraldeep/app/push/`). The adapter is
**not yet wired into the app runtime**: product push availability waits for
coordinated integration. Nothing in the current UI requests the permission,
registers a provider, or presents OS notifications until that integration lands.

## Ownership and scope

This contribution owns the adapter only. It adds exactly one manifest change
(the `POST_NOTIFICATIONS` permission), two channel-name string resources, one
notification icon drawable, and the push packages with their tests. No Gradle
dependencies, no manifest services or receivers, and no workflow changes are
included: the provider bridge (for example FCM) and its dependency lock changes
belong to the coordinated integration step.

## Decision machine (`:core`, JVM-tested, Kover-gated)

`NotificationPushAdapter` holds every decision and no Android imports:

- **Permission.** `onPermissionReport(granted, notificationsEnabled)` derives
  `NotDetermined / Granted / Denied / Revoked`. Granting while the provider is
  supported and registration is idle requests a token; grant-then-revocation
  (runtime toggle or `POST_NOTIFICATIONS` loss) cancels every presented
  notification and clears the receipt ledger.
- **Provider token callbacks.** `onToken` normalizes and validates the token
  against the destination contract (1–4096 chars, no control characters),
  fingerprints it with SHA-256, enrolls changed tokens with an incrementing
  `tokenGeneration`, treats a repeated token as idempotent, and classifies
  blanks/oversized/control-character tokens as permanent failures. `onToken(null)`
  and `onTokenRequestFailed` / `onEnrollmentRejected` classify transient versus
  permanent provider failures; `retryRegistration` re-requests a token or
  re-enrolls the retained token only from the retryable state.
- **Minimal payload receipt.** `onMessage` decodes the flattened minimal payload
  (`notification_id`, `title`, `body`, optional `level`, `chat_id`) with the
  delivery pipeline's bounds: the identity matches `^[A-Za-z0-9._:-]{8,128}$`,
  titles are at most 128 characters, bodies at most 256, control characters are
  rejected, at least one of title/body must be non-blank, and `level` must be
  `info`, `warning`, or `error`. Malformed payloads return a typed
  `Malformed` receipt and are never presented or acknowledged.
- **Duplicates.** A bounded receipt ledger (64 entries, FIFO) suppresses
  duplicates across surfaces and process restarts (the OS binding seeds it from
  live notifications at start). Dismissal removes the entry, so a genuine
  redelivery after user dismissal presents again.
- **Lifecycle.** `Foreground` messages become in-app effects only; `Background`
  and `Terminated` messages become OS presentation specs plus an acknowledgment,
  and are presented only while permission is granted — otherwise the receipt is
  `NotPermitted`. Error-level payloads target the high-importance alert channel.
- **Unsupported devices.** `onAvailability(false, reason)` — reported by the
  provider seam, for example on devices without a push provider backend — makes
  the adapter explicitly unsupported: no token requests, no enrollment, and
  `Unsupported` receipts for every message, until availability returns.

## OS binding (`:app`) and integration seams

`AndroidNotificationAdapter` creates the `astral_push` (default) and
`astral_push_alerts` (high) channels, maps `POST_NOTIFICATIONS` and
`areNotificationsEnabled()` facts into the machine, executes presentation
(`NotificationCompat`, small icon `ic_notification`, auto-cancel, content intent
to `MainActivity`, delete-intent receiver), cancellation, and dismissal, and
exposes the seams a provider bridge must implement:

- implement `PushProvider` (`isSupported`, `requestToken`, `setMessageListener`);
- deliver provider token rotations through `onProviderToken`;
- perform the destination enrollment HTTP call from `enrollListener` and report
  the outcome with `machine.onEnrollmentAccepted()` / `onEnrollmentRejected`;
- perform the `/push/ack` call from `acknowledgeListener` (device id, notification id);
- surface `ShowInApp` payloads from `inAppListener` in the UI;
- request `POST_NOTIFICATIONS` from an Activity launcher when
  `shouldRequestPermission()` is true, and call `refreshPermission()` on resume.

All callbacks must run on one thread (the machine is not synchronized); the
integration wires provider callbacks onto the main thread.

## Verification

- JVM: `:core` push tests under `core/src/test/kotlin/.../push/` cover golden
  paths, bounds, denials, rotation, failures and recovery; they join the Kover
  ≥ 90 % module gate.
- Device: `NotificationPushAdapterInstrumentedTest` runs in the required
  emulator lane and exercises the real notification manager with grant and
  revoke via the instrumentation shell, presentation attributes, delete-intent
  dismissal, cold-start seeding, rotation, retry recovery, malformed and
  duplicate payloads, and the unsupported-device path.
- Real-device push dispatch (physical device with the production provider) and
  product push availability remain part of coordinated integration.
