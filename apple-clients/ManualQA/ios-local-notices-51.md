# iOS local mesh notices (#51): physical iPhone checklist

Automated tests use fake notification-center and registrar seams. They do not show that APNs delivers a wake on a real device, that iOS shows the notice, or that a tap reaches the mesh. Run this checklist on a physical iPhone before turning the feature on for users.

## Setup

1. Use a Debug build signed for the registered App ID, with the Push Notifications capability enabled in the developer portal. Debug resolves `ASTRAL_APS_ENVIRONMENT` to `development`, which means the APNs sandbox.
2. In `apple-clients/AstralApp/Info.plist`, set `ASTRALLocalMeshNotifications` to `<true/>` on a local branch only. Never commit it as `true`; it stays off until the #52 integration is qualified.
3. Open or join a personal mesh on the phone so that `MeshRuntime.isReady` and `hasMesh` are both true.
4. Stream device logs filtered to the `local-notice` category: Console.app, or `log stream --predicate 'category == "local-notice"'`.

## Steps

| # | Step | Expected |
|---|------|----------|
| 1 | Do a fresh install, then launch. | iOS shows the notification permission prompt once. Allow it. The log shows `local notice permission authorized`. |
| 2 | Watch the log right after launch. | You see `APNs token registered sha256:XXXXXXXX…`. The full token never appears in any log. |
| 3 | Background the app. Send a content-free sandbox wake (see below). | The device syncs. If the sync observed a change, one notice appears: "AstralDeep — New activity in your mesh. Open AstralDeep to view it." It contains no chat text, title or name. |
| 4 | Send the same wake again with no new mesh change. | No new notice appears. A notice appears only when the sync actually observed a change. |
| 5 | Tap the notice. | The app opens on the changed mesh chat, or on the mesh root if the process was restarted, and the notice leaves Notification Center. |
| 6 | Post another notice, then swipe it away. | The notice is removed and nothing opens. |
| 7 | Force-quit the app, send a wake that changes the mesh, then tap the notice. | Cold launch: the route waits until the mesh is open, then opens. iOS does not deliver silent pushes to a force-quit app, so expect no notice until the user opens the app again. Record what you observe. |
| 8 | Turn off notifications in Settings › AstralDeep › Notifications, then return to the app. | The log shows `revoked`. The notices this adapter posted are removed, and later wakes post nothing. |
| 9 | Turn notifications back on in Settings, then return to the app. | The log shows `authorized`, and the next wake that changes the mesh posts a notice. |
| 10 | Turn on airplane mode at first launch, so registration fails. | The log shows `APNs registration failed; retry 1 in 5s` and capped retries. Returning to the app after the retries run out requests registration again. |

### Sending a test wake

APNs sandbox, using a provider token. Replace the placeholders:

```sh
curl -v --http2 \
  -H "apns-topic: <bundle id>" -H "apns-push-type: background" -H "apns-priority: 5" \
  -H "authorization: bearer <provider JWT>" \
  -d '{"aps":{"content-available":1}}' \
  https://api.sandbox.push.apple.com/3/device/<device token hex>
```

Simulator, which only exercises the payload path and not real APNs:

```sh
echo '{"aps":{"content-available":1}}' > wake.apns
xcrun simctl push booted <bundle id> wake.apns
```

A wake with any extra field, for example an `alert` or a `body`, must be rejected and complete with no data.

## Not verified by the contributor

None of these steps have been run on a physical iPhone. The contributor had no provisioned device or APNs provider credentials. Steps 1–10, actual APNs sandbox delivery and production APNs delivery all remain open. Record your device model, iOS version, build and observations against each step.
