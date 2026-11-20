# AstralVoiceRuntime

This package wraps llama.cpp with `libmtmd` for the Apple clients. It runs on-device speech recognition (a Qwen3-ASR style model plus its audio encoder) and chat text generation, and nothing else. It targets iOS 17 and macOS 14. The watch targets do not link it.

llama.cpp is pinned to revision `8af68d486a9473820d24d00af8f33334ca80124d`.

## Build the native artifacts

The package commits no build products. From `apple-clients/`:

```text
Scripts/build-voice-runtime.sh
```

The script fetches that exact revision, stops if the checkout is at any other commit, builds static libraries for three arm64 slices and writes `AstralVoiceRuntime/Artifacts/LlamaRuntime.xcframework`. Git ignores `Artifacts/`. Reruns reuse the cached source and build directories under `Artifacts/work`.

| Slice | Deployment target | GPU |
| --- | --- | --- |
| iPhone | iOS 17.0 | Metal, shaders embedded |
| iPhone simulator | iOS 17.0 | none, CPU only |
| macOS | macOS 14.0 | Metal, shaders embedded |

There are no shared libraries, no curl, no OpenMP and no server or examples. It needs `git`, `cmake`, `ninja` and Xcode.

## Use

```swift
let scheduler = RuntimeScheduler.shared
let recognizer = try await SpeechRecognizer.load(model: gguf, audioEncoder: mmproj)
let heard = try await recognizer.transcribe(samples16kMono, language: .english) { delta in print(delta) }

let generator = try await TextGenerator.load(model: chatGguf)
for try await delta in generator.stream([ChatMessage(.user, "Hello")]) { print(delta) }
```

- `transcribe` and `generate` throw `CancellationError` when their task is cancelled, and the decode loop stops at the next token. A pipeline that retranscribes a growing segment cancels the stale task and starts a new one.
- Recognition pads every clip with zeros to `16000*k - 160` samples (`AudioPadding`), because the pinned llama.cpp feeds padded mel frames to the encoder as sound.
- Both engines take a slot from one `RuntimeScheduler` before touching a model, so they never run at the same instant. Waiting recognition is served before waiting generation.
- `RuntimeConfiguration(compute: .cpuOnly)` selects no GPU device and keeps the audio encoder off the GPU. Zero GPU layers alone is not enough at this revision. The simulator slice and the tests use it.
- If Metal work fails after the app is backgrounded, the call throws `VoiceRuntimeError.decodeFailed`. Unload and reload the model, on CPU if needed.

## Tests

The tests run real inference on tiny random-weight models in `Tests/AstralVoiceRuntimeTests/Fixtures` (about 0.7 MB in total), on CPU, with no download. `generate_fixtures.py` rebuilds them (`pip install gguf numpy`).

```text
swift test
xcodebuild test -scheme AstralVoiceRuntime -destination 'platform=iOS Simulator,name=<iPhone simulator>'
```

Run both from this directory after building the artifacts. Set `ASTRAL_VOICE_RUNTIME_LOG=1` to see llama.cpp's own log.
