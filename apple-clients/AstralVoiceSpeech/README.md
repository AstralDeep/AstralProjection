# AstralVoiceSpeech

The on-device English voice for the Apple clients. It speaks one sentence at a time with the Phonon 31m English model through FluidAudio, streams 24 kHz mono Float32 buffers while the model is still generating, and never downloads anything.

The package declares iOS 17 and macOS 14, the same as the apps. Phonon needs iOS 18 or macOS 15, so on older systems `PhononSpeech.availability` reports `.unavailable` and `load` throws without touching the model.

## API

`SpeechSynthesizer` is the seam the voice pipeline calls. It has no engine types in it, so the system-voice implementation conforms to the same protocol.

- `availability`, `isLoaded`
- `load(from:)` takes the model folder the app supplies
- `synthesize(sentence:)` returns an `AsyncThrowingStream<SpeechAudioBuffer, Error>`
- `cancel()` ends the running sentence, and its stream finishes with `SpeechSynthesisError.cancelled`
- `unload()` cancels and releases the model

Starting a new sentence cancels the one still running. Streamed audio carries the same rumble filter and de-esser that FluidAudio's one-shot `synthesize` applies, run frame by frame with the filter state carried across frames.

## Pinned dependency

FluidAudio is pinned by commit, `e0c6103bc87a88d25276cad491c86e757f58c865` (tag `v0.18.4`), with only the `TTS` trait. That leaves out the NeMo text-processing binary and the diarizer, which the Phonon path never calls.

Phonon's path never reaches FluidAudio's downloaders. `PhononSpeech` calls only `PocketTtsSmallManager.load(from:)` and `makeSession`, and switches `ModelHub.offlineMode` on before the first load. The one downloader with no offline check, `AssetDownloader`, is reachable only from the 100M Pocket TTS and Kokoro resource code, which this package never calls.

## Model folder

The app supplies the `phonon-31m-en` folder, for example from Hugging Face `FluidInference/pocket-tts-coreml` under `phonon/phonon-31m-en/`. Only these files are read, and `load` fails with `modelFolderIncomplete` naming any that are missing:

```text
arch.json
pocket_state.json
pocket_state.mlmodelc/{coremldata.bin, model.mil, weights/weight.bin}
mimi_decoder.mlmodelc/{coremldata.bin, model.mil, weights/weight.bin}
constants_bin/{bos_emb.bin, text_embed_table.bin, tokenizer.model, default.safetensors}
```

Ship only those files. The other voices in the pack are not used. No model file is committed here.

## Tests

```text
swift test
xcodebuild test -scheme AstralVoiceSpeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The integration test needs the real pack and skips when `ASTRAL_VOICE_PHONON_DIR` is unset. For a simulator run, pass it as `TEST_RUNNER_ASTRAL_VOICE_PHONON_DIR`.

```text
ASTRAL_VOICE_PHONON_DIR=/path/to/phonon-31m-en swift test
```

The repository guard is `tests/test_apple_voice_speech_gpl_strip.py`.

## Licence duties

- FluidAudio is Apache 2.0, and the Phonon 31m English weights, tokenizer and default voice are Apache 2.0. Keep both notices in the app's acknowledgments, with Gradium for Phonon and FluidInference for FluidAudio and the Core ML conversion. The Phonon 40m models are non-commercial and must never be used.
- FluidAudio's text-to-speech build brings a `LuxTtsG2pResources` bundle with two data files derived from eSpeak NG under GPL-3.0-or-later. Astral must not ship it. Phonon does not read it. Every target that links this package runs `Scripts/strip-voice-gpl-resources.sh "$TARGET_BUILD_DIR"` in a build phase placed after the frameworks and resources phases and before code signing. The script deletes every `*LuxTtsG2pResources*.bundle` under the directory, prints what it removed, and exits non-zero if one remains. The repository guard fails when the Xcode project links the package without that phase.
