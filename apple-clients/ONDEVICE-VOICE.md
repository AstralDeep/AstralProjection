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
The bundled manifest pins the bytes and license attribution. Its repository
revision remains `main` until the owner publishes the quantized artifact; release
qualification must bind the uploaded commit and verify all manifest digests.
This lane neither uploads weights nor modifies the owner's model directory.

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

LFM3 provides no word-to-audio alignment. The graph reports no guessed partial
sentence as heard, and completed sentences are recorded normally. Accurate
interrupted sentence prefixes remain an alignment qualification gap. The watch's
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
