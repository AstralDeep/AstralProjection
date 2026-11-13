# On-device Apple voice

The iOS/macOS chat microphone opens the local voice model offer. It shows the
bundled manifest's total download size before any microphone permission request
or transfer. Supported devices use LFM3-Audio-2B at 3 bits with MLX Swift 0.33.0
for recognition, synthesis and short acknowledgements. The app uses no hosted
speech or system-speech fallback through this microphone flow. Intel Macs,
simulators and phones below the memory requirement explain their unavailability.

The model store verifies each file's exact byte count and SHA-256, stages the
download, and installs the complete directory atomically. Installation markers
bind the complete manifest; the controller rechecks installed digests away from
the main actor before loading weights. Explicit download consent survives an app
relaunch, while cancellation withdraws automatic resume. Expensive or constrained
connections require separate confirmation. Files live under Application Support
and are excluded from backup. Voice settings are available from the microphone's
context menu and include cancellation, retry and deletion.

The source of the weights is `Kentucky-Open-Science/LFM3-Audio-2B-MLX-3bit` on Hugging Face.
The bundled manifest pins revision `65619d48c5e4bc1552db24e07bc4a2ff2aa3cf49`, published by the
owner on 2026-11-12, with every file's size and SHA-256 taken from that commit's `SHA256SUMS` and
checked against Hugging Face's LFS hashes. The app refuses any file that does not match.

## Conversation integration

`AppModel.onDeviceVoice` owns the controller. The composition root supplies an
account/conversation-scoped `VoiceKernelLink` with
`onDeviceVoice.connect(link:)`, and calls `disconnect()` when that authority is
retired. Until a link is supplied, the app can install the model and honestly says
that voice is not ready in the conversation. It does not send recognition as a
typed chat message or open the former hosted voice session.

The link is isolated to the main actor and implements:

- `submit(turn: OwnerVoiceTurn)`: preserves transcript source, integrity and the
  pending-risk marker. `approvalEligible` is always false.
- `cancelTurn()` and `cancelTool(id:)`: handle confirmed interruption. The
  pipeline only requests cancellation of tools marked cancel-safe.
- `record(spoken: VoiceSpokenRecord)`: retains speech actually completed by the
  playback graph.

Feed answer and tool events into the controller through `answerDelta(_:)`,
`answerFinished()`, `toolStarted(id:cancelSafe:)`, `toolFinished(id:)`, and
`setRiskyActionPending(_:)`. Foreground loss, lock, interruption and sign-out stop
capture; returning to the foreground does not silently restart the microphone.

Each inference owns its generation cursor, caches, histories, random state and
streaming codec. The engine yields between generated slots so recognition and
cancellation can enter during synthesis. The duplex audio graph processes echo
cancellation and voice activity and copies microphone buffers before leaving the
audio callback. Silence does not continuously feed the model. Segment IDs fence
late recognition finals after a timeout or cancellation.

The graph negotiates a mono floating-point capture client before tapping voice
processing, including when macOS exposes a multichannel aggregate input. It
converts 24 kHz model speech to that same client format before output.
Audio-device startup errors remain distinct from a missing or corrupt download.

Recognition waits for the final transcript for up to eight seconds after the
end-of-turn signal. An expired or empty final never promotes an earlier partial
to an owner message. Speech buffers each sentence before playback so variable
model throughput does not insert gaps between codec chunks; cancellation drops
buffered, unplayed audio. The composer shows a disabled spinner while preparing,
then a filled microphone, Stop Voice and Listening while capture is active.

Voice resolves and pins its conversation before capture begins. Starting from
Settings reopens the explicitly selected chat or creates a new voice chat when
none was selected. Navigation returns to that conversation; leaving it stops
capture. Retired sessions cannot dispatch into a reopened mesh, and played
speech retains its original chat even if selection subsequently changes.

Kernel local answers prefer Foundation Models where available. Eligible devices
without it can use the installed LFM3 weights for plain text after all manifest
files pass digest verification. Voice and local answers share one lazy model
instance. This fallback rejects structured schemas, bounds input and output,
and never installs weights or changes the owner's configured provider. Removing
the model retires pending local answers; simulators remain unsupported.

LFM3 provides no word-to-audio alignment. The graph records completed sentences
only after their scheduled audio reports that it played. It omits an interrupted
sentence, even when its beginning was audible, and never guesses a prefix from
elapsed time or audio chunk lengths. This conservatively excludes unplayed words
from history; it does not preserve every audible word. The watch's
existing server bridge and server speech code remain for their current clients;
phone-satellite binding is separate integration work.

## Verification

Run the portable protocol package and the Metal-backed voice package on macOS:

```sh
swift test --package-path apple-clients/AstralCore
cd apple-clients/AstralVoiceModel
TEST_RUNNER_ASTRAL_LFM3_MODEL_DIR="$VOICE_MODEL_DIRECTORY" \
  xcodebuild -scheme AstralVoiceModel -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Without a local model directory, real-weight parity tests skip with an explicit
reason. Tiny-model generation, interleaving, recognition-during-synthesis and
cancellation tests require no download. `RealModelDiagnosticsTests` preserves the
optional local timing/memory experiment and runs only when
`ASTRAL_LFM3_DIAGNOSTICS=1`; it imposes no wall-clock performance gate.

Run `AstralAppTests` and `VoiceConversationUITests`, plus the unsigned macOS and
iOS Simulator builds described in [README.md](README.md). Real microphone,
speaker, interruption, route changes and the full conversation path still need
device verification with the integrated conversation link; fixtures do not
qualify that behavior.
