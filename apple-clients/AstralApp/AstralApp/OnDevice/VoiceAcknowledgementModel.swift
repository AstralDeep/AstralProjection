// Adapts the local text generator to the kernel's on-device model interface so the fast path can draft its acknowledgments through it.
// VoiceSessionParts builds it over the shared LFM2.5 generator, and it refuses structured requests and reports cancellation honestly.

import Foundation

nonisolated struct VoiceAcknowledgementModel: AstralOnDeviceModel {
    let generator: any VoiceTextGenerating

    func available() -> Bool { true }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        guard request.schemaJSON == nil else { return .failed(.schemaUnsupported) }
        guard !request.messages.isEmpty else { return .failed(.emptyRequest) }
        do {
            try Task.checkCancellation()
            let text = try await generator.generate(request).collected()
            try Task.checkCancellation()
            return .text(text)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.generationFailed)
        }
    }
}
