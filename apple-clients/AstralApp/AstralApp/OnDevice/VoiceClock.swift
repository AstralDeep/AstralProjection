// Supplies monotonic time to the voice logic so timing rules can be tested with a controlled clock.
// BargeInController, VoiceEndOfTurnDetector, VoiceFastPath and VoicePipeline read it and never call the system clock directly.

import Foundation

nonisolated protocol VoiceClock: Sendable {
    var now: TimeInterval { get }
}

nonisolated struct SystemVoiceClock: VoiceClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
