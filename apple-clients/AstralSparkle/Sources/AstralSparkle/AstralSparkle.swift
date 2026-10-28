// Re-exports Sparkle so macOS code reaches the updater API by importing AstralSparkle.
// The manifest drops the Sparkle dependency on iOS, where this module compiles empty.
// AstralApp links this module on every platform, keeping the macOS-only binary out of iOS builds.

#if canImport(Sparkle)
    @_exported import Sparkle
#endif
