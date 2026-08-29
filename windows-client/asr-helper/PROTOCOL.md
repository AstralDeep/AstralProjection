# AstralSpeechHelper inherited-pipe protocol

`AstralSpeechHelper.exe --stdio` is a first-party, desktop-owned child process. It inherits only
anonymous stdin/stdout pipes and a scrubbed `SystemRoot`/`WINDIR` environment. It never owns a
microphone, opens a listener or outbound connection, launches a shell, reads credentials, or writes
audio to a file, cache, or temporary directory.

Every frame starts with the 12-byte little-endian header `ADSH`, version byte `2`, kind byte,
`uint16 recognition_id`, and payload `uint32` length. The complete payload follows. `ready`,
`shutdown`, and the reserved `hello` kind use recognition ID zero. Every cycle-scoped kind uses a
nonzero ID. Unknown versions or kinds, an invalid ID scope, truncation, ordering errors, and
oversized lengths terminate the helper with no recovery or resynchronization.

| Kind | Value | Direction | Recognition ID | Payload and bound |
| --- | ---: | --- | ---: | --- |
| `ready` | 2 | helper → desktop | `0` | exact UTF-8 `{"locale":"en-US"}`, at most 4 KiB |
| `start` | 3 | desktop → helper | nonzero | exact UTF-8 `{"locale":"en-US","sample_rate":16000,"channels":1}`, at most 4 KiB |
| `pcm` | 4 | desktop → helper | matching active cycle | signed 16-bit little-endian 16-kHz mono PCM, 1–32 KiB |
| `stop` | 5 | desktop → helper | matching active cycle | empty |
| `final` | 6 | helper → desktop | matching active cycle | one UTF-8 recognition final, at most 64 KiB |
| `error` | 7 | helper → desktop | matching active cycle | exact UTF-8 `{"reason":"local_recognition_failed"}`, at most 4 KiB |
| `shutdown` | 8 | desktop → helper | `0` | empty |
| `stopped` | 9 | helper → desktop | stopped cycle | empty |

Before writing `ready`, the helper deterministically selects an installed recognizer whose culture
name is exactly `en-US`, whose advertised formats include 16-kHz/16-bit/mono PCM, and whose native
recognition engine and dictation grammar can be constructed. Missing locale, missing format, and
construction failure are distinct host-capability classifications. Every such failure exits with
code 69 without writing `ready`; it is not a protocol or speech-success result.

The process supports serialized recognition cycles. The desktop must not reuse an ID (including
after the 16-bit counter wraps) or send the next `start` until it has received `stopped` for the
previous cycle. On `stop`, the helper invalidates the cycle under the same lock used for output,
completes and cancels recognition, unsubscribes and disposes native state, and crosses an output
barrier before writing `stopped`. Therefore no `final` or `error` for that cycle can follow its
`stopped` acknowledgement. `shutdown` cancels an active cycle and exits without a `stopped`
acknowledgement.

The helper queues at most 256 KiB of PCM in memory. `pcm` before `start`, a mismatched cycle ID,
buffer overflow, malformed input, or any pipe/process failure fails closed. Additional native
terminal callbacks for a completed or invalidated cycle are suppressed. Identical canonical text
remains valid in different acknowledged cycles. The desktop binds a matching one-cycle final to
the current authenticated local voice turn; the helper grants no network, conversation, tool, or
agent authority.

The product project targets .NET Framework 4.8, is deterministic, treats warnings as errors, and
has no `PackageReference`. Only `AstralSpeechHelper.csproj`, `FrameProtocol.cs`,
`BoundedAudioStream.cs`, and `Program.cs` are hashed product sources. Microsoft test and coverage
packages remain private assets in `tests/`, use locked restore, and are excluded from publish and
the frozen application inputs.

`helper-source-hashes.json` records those product-source digests. Publish writes
`helper-build-provenance.json` with the source-manifest and executable SHA-256 values; the freeze
validates both and embeds the exact executable digest inside the Python archive. Runtime launch then
requires the embedded digest before and after Windows `WinVerifyTrust` accepts the helper's
Authenticode signature. Local and ordinary CI publishes are unsigned and therefore intentionally
fail that runtime signature gate; only a protected release may sign the helper, regenerate
provenance for the signed bytes, and freeze it into the separately signed outer application.
