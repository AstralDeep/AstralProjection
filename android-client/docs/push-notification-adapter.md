# Android notification adapter

The independently testable adapter consists of the Android-free
`core.push.NotificationPushAdapter` and `app.push.AndroidNotificationAdapter`.
The shipping Activity does not instantiate it. Product push availability requires
the coordinated Android/Apple/server integration and real-provider qualification.
No UI protocol vocabulary, navigation catalog, provider dependency, manifest
service, authentication flow or deployment configuration changes here.

## Owner and callback lifetime

Construct one adapter with the current authenticated `ownerSessionId` and
`PushIdentity.deviceId`. The host supplies that opaque owner scope; it must never
reuse it across different owners or servers. A cold start may recover the same
scope only after authenticating its owner. Call `close()` synchronously before
logout, account/server changes or retiring that scope. Closed instances cannot
restart. Close clears local registration and notices, detaches the provider
listener, unregisters the dismissal receiver and emits a revoke effect without
waiting for REST. A failing integration callback remains a visible failure;
receiver cleanup still runs.

The provider supplies support, token request completion and message listeners.
Request callbacks capture their request incarnation; callbacks arriving after a
new token, retry or close are ignored. Enrollment callbacks must call
`adapter.onEnrollmentAccepted(effect, serverTokenGeneration)` or
`adapter.onEnrollmentRejected(effect, transient, code)` with the original effect.
Repeated provider tokens cannot accept an outstanding enrollment. Stale owner,
device and local token-generation callbacks cannot register a new session.

`PushBinding` separates local `tokenGeneration` from the authoritative
`serverTokenGeneration` returned by enrollment. Only a successful, positive server
generation permits delivery. A message listener captures the accepted binding;
rotation, permission loss and session retirement reject deliveries from previous
bindings. Late enrollment success after retirement emits a conditional revoke for
that returned server generation, preserving a newer destination.

The `revokeListener` receives `PushEffect.RevokeDestination(binding)`. Integration
must retain its captured owner's authentication and use
`DELETE /api/push/destinations/{device_id}?expected_token_generation=N`, with
`N = binding.serverTokenGeneration`. A 409 is a stale-generation refusal; it must
never fall back to an unconditional delete. Failed revokes require explicit
integration failure/retry handling and cannot restore local presentation.

## Permission and presentation

Startup/resume calls `refreshPermission()` without treating an unrequested OS
permission as an explicit denial. After the Activity's permission launcher
returns, call `onPermissionResult(granted)`; an explicit OS recheck may use
`refreshPermission(requestCompleted = true)`. Android versions
before API 33 need no runtime POST_NOTIFICATIONS request. Notification permission
loss retires registration, cancels notices and emits revoke; restoration requests
a fresh provider token and enrollment. Unsupported providers and token loss also
retire the registered destination.

Payloads carry an opaque bounded `notification_id`; legacy optional text/level/
chat fields are validated but cannot authorize navigation. OS notices always use
generic application text. Only `MessageReceipt.Accepted.effects` execute;
malformed, duplicate, denied and unsupported receipts produce no presentation or
acknowledgment. Foreground deliveries use the integration's in-app listener;
background/terminated deliveries use the two Android channels. The bounded
receipt ledger is seeded only from the same owner/device's active notices.

Each notice has its own immutable content/delete PendingIntent data URI, even
when integer display IDs collide. The content intent contains the opaque
notification ID and authoritative server token generation. After authenticating
and enrolling the current owner, pass the incoming Activity intent to
`notificationIdFromTap()`. This validates scope and generation and returns only
the opaque ID. Integration must then GET
`/api/notifications/inbox/{notification_id}` through the authenticated server
boundary and open only the authorized source returned for that current owner.
A generic landing page or a provider-supplied chat ID does not complete source
navigation. Two concurrent notices and cold-start delivery need this same path.

The acknowledgment listener receives its captured `PushBinding` and opaque ID;
its existing HTTP body remains `{device_id, notification_id}`. The coordinated
runtime adds foreground presence using the server's accepted UI connection and
its monotonic sequence; the adapter introduces no alternate protocol frame.

## Verification and remaining integration gates

The committed Gradle wrapper runs `ktlintCheck`, `:app:lintDebug`, `:core:test`,
`:app:testDebugUnitTest`, `:core:koverVerify` and `:app:assembleDebug`. Core Kover
retains the 90% module floor. Instrumented tests exercise actual Android
notification manager presentation, permission-result revocation, dismissal, two
PendingIntents, cold-start seeding, callback retirement and provider failures.
A separate run revokes permission before instrumentation starts, because an
Android runtime revoke terminates the app process; it verifies actual OS denial
and the initial request/explicit denial distinction. The tests use deterministic provider seams and do not establish actual background
provider delivery or a live authenticated navigation outcome.

Coordinated acceptance still requires a locked shipping provider bridge, actual
OS permission launcher interaction, foreground/background/terminated delivery
on a physical Android device, notification taps to authorized sources against
the live backend, and logout/account-switch/revocation failure cases with real
Keycloak sessions. No provider credentials, sign-in bypass or fake enrollment is
included. Local repair evidence is reported separately from CI/device/provider
acceptance.
