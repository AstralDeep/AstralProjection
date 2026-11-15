# Native Apple CI coverage

Native Apple coverage is source-bound: execution comes from `xccov`, and the structural mapping comes from the platform LLVM export. The LLVM function file-index table can repeat a source path for separate region references; the collector validates each index and maps all references to their tracked source rather than treating repeated paths as duplicate files.

On 2026-11-15, the product owner waived app-unit checks that require local hardware or a signed host. The collector accepts only these exact waived XCTest identities and skip reasons:

- `MeshDeviceKeysTests/testKeychainStoreRoundTrip()` — `Keychain needs a signed host; unsigned simulator test builds have none`
- `OnDeviceFallbackModelTests/testRealVerifiedTextFallbackWhenExplicitlyRequested()` — `Set ASTRAL_VERIFIED_MODEL_TEST_ROOT to a verified installed model root for this local hardware check.`

The Keychain check is iOS-only; the verified-model check may appear in iOS or macOS unit results. Existing macOS dispositions remain limited to `AppModelChromeSurfaceTests/testEvidenceHostedSurfaceRetiresItsActualTimerAndRejectsLateReplay()` with `Hosted SwiftUI evidence coverage uses the isolated iOS test destination`, and `Accessibility060UITests/testMainComposerUsesSystemKeyboardWithoutApplicationDrawnDoneAccessory()` with `The system-IME contract (on-screen keyboard, keyboard-anchored send, interactive dismissal) has no macOS analogue — macOS input is a hardware keyboard with no Keyboard element in the AX tree.`

Each result must report only the exact lane-specific skipped cases, all remaining cases passed, and zero failed or expected-failure tests. Other skips remain failures. Collection preserves the result counts, and retry diagnostics still report failed attempts even when a retry passes. No live service, product assertion, security check, or other required CI gate is waived.
