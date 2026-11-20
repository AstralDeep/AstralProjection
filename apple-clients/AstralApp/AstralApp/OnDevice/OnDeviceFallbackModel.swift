// Prefers Apple's model and falls back to the installed LFM2.5 model for plain local answers on eligible devices.
// The kernel's typed chat and the voice session share the one LFM2.5 instance that RumbleVoiceModels owns.

import Foundation

nonisolated struct PreferredOnDeviceModel: AstralOnDeviceModelWarmable {
    let preferred: any AstralOnDeviceModel
    let fallback: any AstralOnDeviceModel

    init(
        preferred: any AstralOnDeviceModel = FoundationModelsOnDeviceModel(),
        fallback: any AstralOnDeviceModel = RumbleVoiceModels.shared.onDeviceModel
    ) {
        self.preferred = preferred
        self.fallback = fallback
    }

    func available() -> Bool { preferred.available() || fallback.available() }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        if preferred.available() { return await preferred.complete(request) }
        return await fallback.complete(request)
    }

    func prewarm() async {
        if preferred.available(), let warmable = preferred as? any AstralOnDeviceModelWarmable {
            await warmable.prewarm()
        }
    }
}
