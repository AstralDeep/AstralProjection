# Voice audio focus and route ownership

Voice media on Android spans three owners. This document fixes the ownership boundaries and
describes the project-owned interruption lifecycle added so capture and playout stop immediately
on ineligible audio transitions and recover in a bounded, server-authorized way.

## Ownership

- **LiveKit room (SDK 2.27.0, `io.livekit:livekit-android`).** The room is created with
  `ConnectOptions(audio = true)`. The room's audio path is SDK-owned: the app treats the SDK as
  responsible for configuring and switching the communication audio path and devices for its own
  WebRTC capture and renderer output, and the app does not set audio modes, does not manage
  routing for room tracks, and does not acquire or manage audio focus on the SDK's behalf.
  Capture muting goes through the app's `VoiceMediaClient.setMicrophoneEnabled`, and the room's
  own output for announcement tracks is muted at `0.0` because the app renders announcements
  itself.
- **OS audio focus.** Android arbitrates exclusive audio (phone calls, prompts, other media). The
  app holds one `AudioFocusRequest` (`USAGE_ASSISTANT`, `CONTENT_TYPE_SPEECH`) only while a voice
  session is active. It is an observation and policy seam, not a second mixer: focus loss marks the
  environment ineligible, focus gain re-enables recovery.
- **App announcement playout.** Announcement PCM is rendered by the app's own `AudioTrack`
  (`USAGE_ASSISTANT`, `CONTENT_TYPE_SPEECH`) from the LiveKit data channel, not through the room
  renderer. This path is project-owned end to end, so its suspension policy is project-owned too.

## Policy (VoiceSessionController)

- **Triggers.** Audio-focus loss (call, prompt, other media) and audio-device removal
  (headset unplug, output-route loss) make the audio environment ineligible. Focus gain and a
  fresh device observation with a microphone and an output restore eligibility.
- **Immediate local suspension, before the network update.** On an ineligible transition the
  controller immediately interrupts playout (`interruptPlayout()`), mutes capture
  (`setMicrophoneEnabled(false)`), stops lease renewal, and shows the suspended state. The server
  update — `foreground_active=false` with `foreground_reason="audio_interrupted"` or
  `"route_unavailable"` and `microphone_enabled=false`, the values the voice session contract
  already defines — is sent afterwards under the session update mutex.
- **Announcement intake gate.** Announcements arriving while the environment is ineligible are not
  queued for playout; the session is suspended server-side, so no audio renders during a call or
  a route switch.
- **Bounded recovery.** Each eligibility-restore event runs one recovery attempt, never a retry
  loop. The attempt re-asserts `foreground_active=true, foreground_reason="foreground"` and
  restores `microphone_enabled` from the user's microphone intent, then re-enables capture and
  lease renewal only from the confirmed response.
- **Fences.** Every suspension and recovery step re-checks the session fence (lifecycle token,
  connection generation, session id, generation, media grant revision), the current interruption
  state, and the foreground flag inside the update mutex. Stale focus, route, or media callbacks
  from a superseded session or connection generation are dropped without state changes.
- **User microphone intent.** `microphoneDesired` records the user's last explicit microphone
  choice, separate from the session's server-mirrored `microphone_enabled`, which suspension
  forces to `false`. Recovery restores capture only when the confirmed server state authorizes it
  and the recorded intent is on; if the user muted, capture stays off.
- **Foreground interplay.** Returning to the foreground while an interruption is active re-asserts
  the audio suspension instead of resuming; focus gained while backgrounded defers recovery to the
  foreground return. Quick background/foreground flaps converge because every update re-reads the
  current state under the mutex.

The Apple client implements the same reasons (`audio_interrupted`, `route_unavailable`) against
the same session contract; this lifecycle keeps the Android client in parity.

## Real-device verification (required before release of this change)

Run on a physical phone signed in to a real backend, with an active voice conversation:

1. **Short interruption (call).** Place an outgoing call from another device while voice is
   listening. Expect: playout and capture stop immediately, the composer shows the suspended
   audio-interrupted state, and after the call ends the session resumes with the microphone
   restored (or stays muted if the user had muted).
2. **Headset removal.** Unplug the wired headset (or disconnect the Bluetooth headset) while an
   announcement is playing. Expect: playout cuts immediately instead of continuing through the
   dying route, then voice reconnects and continues on the built-in speaker.
3. **Route restore.** Re-plug the headset during an active session. Expect the session keeps
   working and new playout follows the selected route.

No required CI gate may depend on live third-party network services, exact clock values, or
wall-clock performance bounds; the deterministic coverage for this lifecycle lives in the JVM
unit tests around `VoiceSessionController`, and the steps above are the manual acceptance pass.
