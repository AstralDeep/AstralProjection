# Whole-source OS conditional verifier

`scripts/swift_inactive_input.py` is a standalone compiler-input verifier. It combines the lossless parser in `scripts/WholeOSInputProof.swift`, a native-derived target, and independent typechecked AST/SIL checks. It does not change coverage ownership, add synthetic line observations, or authorize a release.

The only accepted source form is one complete file containing one top-level `#if os(iOS)`, `#if os(macOS)`, or `#if os(watchOS)` clause. Comments and trivia are preserved. Sibling declarations/imports, alternative clauses, custom flags, import/version/environment conditions, boolean expressions and syntax recovery are refused. The predicate must be false for the target derived from the retained native inputs. Active-platform code still needs its actual execution counters.

## Required inputs

- The exact immutable candidate source and its independently established SHA-256.
- A registered native producer binary and that source's primary MH_OBJECT file. Their thin CPU, platform and SDK must match. The primary object's minimum cannot exceed the native binary's minimum.
- The selected Xcode developer directory. Collection requires Xcode 26.6, build 17F113, and Apple LLVM 21.0.0. Local Xcode 27 results cannot be relabeled through an option or environment setting.
- An absent canonical absolute output directory under an operator-owned 0700 parent with protected ancestry. Shared writable parents are refused. A root-owned sticky temporary ancestor is allowed only through existing protected directory entries. The verifier holds and rechecks directory identities and permissions throughout collection.

```text
python3 scripts/swift_inactive_input.py \
  --source /absolute/candidate/Source.swift \
  --source-sha256 <candidate-blob-sha256> \
  --native-binary /absolute/retained/native-binary \
  --primary-object /absolute/retained/Source.o \
  --developer /Applications/Xcode_26.6.app/Contents/Developer \
  --output /absolute/private-parent/new-proof
```

Output files are created exclusively through the held directory descriptor with no symlink following; pre-existing leaves are refused. Compiler and helper execution use a held working-directory capability with relative generated input, binary and cache names, so replacing the visible namespace cannot redirect writes. Cache identities and the compiler-produced executable are checked before use; a changed namespace cannot finalize a receipt.

Source and native reads use nonblocking nofollow opens and check the opened regular descriptor against the prior identity before reading any bytes, then recheck afterward. Each command runs below a live supervisor that reports the worker's actual exit status through a private pipe. On success, failure or deadline, the verifier terminates the owned process group before reaping that supervisor, preventing PID reuse and cleaning descendants even when the worker has exited or closed its output pipes. The supervisor implementation is ordinary source in the Python module and its bytes are bound with the other tool identities.

The verifier derives iOS Simulator (Mach-O platform 7), macOS (1), or Watch Simulator (9) target facts from the actual native bytes. It selects the exact matching SDK version and binds the SDK settings/system-build identities. A standard versioned SDK alias may resolve only to its matching versioned or unversioned SDK directory inside that selected platform's SDK namespace; alias, target, namespace and metadata identities must remain stable. It rejects foreign/fat/ambiguous native headers and unknown SDK identities. Registered tool symlinks must resolve inside the selected developer directory; source/native input symlinks are refused.

The helper uses SwiftParser, SwiftSyntax and SwiftIfConfig bundled with Xcode. No external package or application runtime dependency is added. Collection owns its compiler arguments and developer environment. It never executes candidate code or launches an app, tests, UI, permission API or hardware event.

## Independent compiler checks

Before checking the actual source, collection qualifies positive and negative control sources under the same native-derived target. The positive OS guard must produce a typed function and a SIL function; the negative OS guard must produce the closed empty forms. The complete candidate source must then produce the same empty forms. `-dump-parse` is never used as evidence: it can appear empty for active conditional declarations.

All original source, native inputs, tool identities and SDK metadata are checked again after collection. Unknown AST/SIL grammar, diagnostics, active declarations/functions/tables, malformed output, failed tools, changed inputs and expired/output bounds refuse the proof. Verification failures print only `swift_inactive_input_invalid`; partial private outputs remain available for diagnosis, and no successful `proof.json` is written.

The LLVM version check accepts only the exact known LLVM 21 version line and its optional exact `  Optimized build.` line; additional or unknown banner text is refused.

The current empty grammar is explicitly limited to the pinned frontend's empty source-file AST and raw SIL preamble, fixed imports and controlled one-file mapping. It is not a generic parser that drops unknown compiler output. Canonical qualification on 17F113 is still required; the local 27 grammar exercises do not replace it.

## Receipt authority

The result format is `astral.swift-whole-os-inactive/v1` with `scope=source-conditional-only` and `build_provenance=unverified`. It attests the intrinsic compiler/source/target facts only. It does not prove that an OutputFileMap/SwiftFileList belongs to the shipping build, that an archive came from an authorized provider job, or that a source is exempt from a producer's coverage gate.

A future separately reviewed v2 producer must verify compile membership, source/build/archive identities, provider trust, registered native product identity and every required platform/lane union, then regenerate and bind this receipt. Until that integration exists, a missing whole source in existing iOS/Mac/Watch coverage remains a blocker. Existing iOS and Mac v1 formats and byte goldens are unchanged.

## Verification

```text
python -m pytest tests/test_swift_inactive_input.py -q
python -m pytest tests/test_swift_inactive_input_native.py -q --basetemp=/absolute/new-native-evidence
```

The native suite compiles the real standalone helper with instrumentation, executes its adversarial inputs, and retains the actual binary, profraw, merged profdata, LCOV, commands, source/binary digests and receipt under its private test directory. It enforces at least 90% measured helper-line coverage. This is host-tool evidence, separate from App/native/provider coverage. The native suite requires macOS; Python decision and denial tests run without the Apple host libraries.

The suite also builds a real primary object and linked dylib from one complete iOS-only source for the selected Mac SDK and host architecture, derives their target facts from both Mach-O files, and invokes the standalone collector without substituted tools. Exact 26.6/17F113 must produce a complete source-only receipt with unverified build provenance; another installed Xcode must refuse collection and leave no proof. The raw build commands and observed Xcode identity are retained with the native evidence.
