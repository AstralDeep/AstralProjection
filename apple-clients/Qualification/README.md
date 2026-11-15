# Manual on-device model qualification

`OnDeviceModelHost.swift` runs the production Foundation Models adapter over local standard-input/output pipes. It is a separate command-line host, not an app entry point or a CI test. It reads no account, credential or conversation store. The Kernel's optional `qualify-on-device` example supplies synthetic chats, in-memory tools and real authorization/journal handling, and writes its plan before making model requests.

Build the host from the Projection root with the selected Xcode:

```sh
xcrun swiftc -O -swift-version 6 -parse-as-library \
  apple-clients/AstralApp/AstralApp/OnDevice/OnDeviceModelAdapter.swift \
  apple-clients/AstralApp/AstralApp/OnDevice/OnDeviceJSONSchema.swift \
  apple-clients/Qualification/OnDeviceModelHost.swift \
  -o /absolute/evidence/directory/foundation-model-host
```

From a clean, committed Kernel checkout:

```sh
cargo build -p astral-kernel --example qualify-on-device --features testkit --locked
target/debug/examples/qualify-on-device \
  /absolute/evidence/directory/foundation-model-host \
  /absolute/evidence/directory/new-results smoke
```

Use `all` instead of `smoke` for 50 surface attempts, 32 fixed corpus baselines and up to two model-generated adaptive variants per baseline. Each defender trial has an eight-call bound. The tool effects are in-memory recorders; the bootstrap fetch is scripted through the real gates, and subsequent planner responses use the real model. Fixed mixed-corpus baselines and generated adaptive attempts have separate denominators. A failed model, missing exposure, refused attacker or failed allowed control is recorded and cannot become a passing result.

The host requires an available Apple on-device model. It reports unavailability rather than downloading a model or substituting a different one. Record `xcodebuild -version`, `swift --version` and the source revisions beside the results. The driver binds its source commit and host/driver hashes; Apple does not expose the installed weights revision through this interface. Results apply to that local model and toolchain, with no hardware-phone, voice latency, cloud-model or protected-CI claim.

Keep result stores, raw model outputs and binaries outside Git. These are manual model measurements and must not run in deterministic hosted gates.
