# AstralSpeechHelper inherited-pipe protocol

`AstralSpeechHelper.exe --stdio` is a first-party, desktop-owned child process. It inherits only
anonymous stdin/stdout pipes and a scrubbed `SystemRoot`/`WINDIR` environment. It never owns a
microphone, opens a listener or outbound connection, launches a shell, reads credentials, or writes
audio to a file, cache, or temporary directory.

Every frame starts with the 12-byte little-endian header `ADSH`, version byte `1`, kind byte,
reserved `uint16=0`, and payload `uint32` length. The complete payload follows. Unknown versions,
kinds, nonzero reserved bits, truncation, ordering errors, and oversized lengths terminate the
helper with no recovery or resynchronization.

| Kind | Value | Direction | Payload and bound |
| --- | ---: | --- | --- |
| `ready` | 2 | helper → desktop | exact UTF-8 `{"locale":"en-US"}`, at most 4 KiB |
| `start` | 3 | desktop → helper | exact UTF-8 locale/48-kHz/mono contract, at most 4 KiB |
| `pcm` | 4 | desktop → helper | signed 16-bit little-endian 48-kHz mono PCM, 1–32 KiB |
| `stop` | 5 | desktop → helper | empty |
| `final` | 6 | helper → desktop | one UTF-8 recognition final, at most 64 KiB |
| `error` | 7 | helper → desktop | closed categorical JSON reason, at most 4 KiB |
| `shutdown` | 8 | desktop → helper | empty |

The helper queues at most 256 KiB of PCM in memory. `pcm` before `start`, a second final for the
same recognition, buffer overflow, malformed UTF-8, or any pipe/process failure fails closed. The
desktop canonicalizes and binds the one final to the current authenticated local voice turn; the
helper grants no network, conversation, tool, or agent authority.

The product project targets .NET Framework 4.8, is deterministic, treats warnings as errors, and
has no `PackageReference`. Only `AstralSpeechHelper.csproj`, `FrameProtocol.cs`,
`BoundedAudioStream.cs`, and `Program.cs` are hashed product sources. Microsoft test and coverage
packages remain private assets in `tests/`, use locked restore, and are excluded from publish and
the frozen application inputs.
