// Decides whether this device can run the on-device voice model: Apple silicon Macs, and iPhones or iPads with enough memory, never the simulator and never Intel.
// The mic flow asks it before offering a download, and when it says no the mic only explains why and offers nothing else.

import Foundation

nonisolated enum VoiceUnsupportedReason: Equatable, Sendable {
    case notAppleSilicon
    case simulator
    case insufficientMemory(physicalBytes: UInt64, requiredBytes: UInt64)

    var message: String {
        switch self {
        case .notAppleSilicon:
            return "Voice needs a Mac with Apple silicon. This Mac cannot run the voice model."
        case .simulator:
            return "Voice does not run in the simulator. Use a real device."
        case .insufficientMemory(_, let required):
            let size = ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .memory)
            return "This device does not have enough memory for the voice model. It needs about \(size) of RAM."
        }
    }
}

nonisolated struct VoiceDeviceProfile: Equatable, Sendable {
    enum Platform: Equatable, Sendable { case mac, phone }

    let platform: Platform
    let isAppleSilicon: Bool
    let isSimulator: Bool
    let physicalMemoryBytes: UInt64

    static var current: VoiceDeviceProfile {
        #if os(macOS)
            let platform = Platform.mac
        #else
            let platform = Platform.phone
        #endif
        #if arch(arm64)
            let silicon = true
        #else
            let silicon = false
        #endif
        #if targetEnvironment(simulator)
            let simulator = true
        #else
            let simulator = false
        #endif
        return VoiceDeviceProfile(
            platform: platform, isAppleSilicon: silicon, isSimulator: simulator,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

nonisolated enum VoiceDeviceSupport {
    static let minimumPhoneMemoryBytes: UInt64 = 5_500_000_000

    static func unsupportedReason(for profile: VoiceDeviceProfile = .current) -> VoiceUnsupportedReason? {
        if profile.isSimulator { return .simulator }
        if !profile.isAppleSilicon { return .notAppleSilicon }
        if profile.platform == .phone, profile.physicalMemoryBytes < minimumPhoneMemoryBytes {
            return .insufficientMemory(
                physicalBytes: profile.physicalMemoryBytes, requiredBytes: minimumPhoneMemoryBytes)
        }
        return nil
    }
}
