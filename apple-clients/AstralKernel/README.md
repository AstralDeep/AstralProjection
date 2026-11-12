# AstralKernel (Swift wrapper)

This package wraps the shared Rust kernel for the Apple clients. It targets iOS 17 and macOS 14. The watch targets do not link it.

The package commits no build products. Before opening it in Xcode or running `swift test`, build the kernel from the `AstralKernel` repository:

```text
cd ../AstralKernel
scripts/build-apple.sh
```

The script writes `Artifacts/AstralKernelFFI.xcframework` and `Artifacts/Bindings/AstralKernelBindings.swift` in this directory. Both are ignored by Git. Without them, SwiftPM cannot resolve the package.

`Sources/AstralKernel` holds the thin Swift API (`KernelService`, `AstralKernelInfo`). It re-exports the generated bindings.

Tests run on macOS with `swift test` and on the iOS Simulator with `xcodebuild test -scheme AstralKernel -destination 'platform=iOS Simulator,name=<device>'`. They use local-only networking.
